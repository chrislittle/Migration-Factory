#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-2: for every wave created, a user must select the options. Defaults
# can be set, but they must be clicked and accepted.
#
# Defaults exist - one safe set - but a default nobody looked at is a decision
# nobody made. So acceptance is a first-class contract artifact bound by hash
# to the wave's exact levers AND membership, checked in the ENGINE (a
# wizard-only gate is bypassed by the API path, the IAC-2 lesson), and
# invalidated by any later edit.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:NewFixture {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $rp -Force | Out-Null
        $plan = [ordered]@{
            # EVAL-L4: this fixture invented a 'runId' property that no plan
            # writer creates, which is exactly how the writer reading
            # $plan.runId passed its tests while recording an empty string on
            # every real plan. The fixture is now the real plan shape.
            schemaVersion = 6; assessmentRunId = 'wo-test'
            entries = @(
                # ACCEPT-SET-1: an acceptance covers the machines that MOVE, so
                # the fixture's machines say they do - as every real plan's do.
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/s/vm/a'; wave = 'first-five'; path = 'A'
                            policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $false } }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/s/vm/b'; wave = 'first-five'; path = 'A'
                            policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $false } }
            )
        }
        $pp = Join-Path $rp 'plan.json'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $pp -Encoding utf8NoBOM
        @{ Run = $rp; Plan = $pp }
    }
    function Script:Entries($pp, $wave = 'first-five') {
        # ACCEPT-SET-1: the one rule for which entries an acceptance covers.
        InModuleScope VmMigrationFactory -Parameters @{ pp = $pp; w = $wave } {
            Get-VmfWaveOptionsEntries -Plan (Get-Content $pp -Raw | ConvertFrom-Json -Depth 12) -Wave $w
        }
    }
    function Script:Gate($rp, $pp, $wave = 'first-five') {
        $e = Script:Entries $pp $wave
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $e; w = $wave } {
            Test-VmfWaveOptionsAccepted -RunPath $rp -Entries $e -Wave $w
        }
    }
}

Describe 'WAVE-2: the acceptance gate' {
    BeforeEach { $script:fx = Script:NewFixture }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'an unaccepted wave REFUSES, and the message says what is missing and where to accept it' {
        # GATE-WORDS-1: why defaults are not enough is the rule's reason, kept
        # in the engine's comment. The screen says what is missing and names
        # the button that fixes it.
        $r = Script:Gate $script:fx.Run $script:fx.Plan
        $r.Pass | Should -BeFalse
        $r.Code | Should -Be 'notAccepted'
        $r.Detail | Should -Be 'Nobody accepted the settings of wave first-five. On wave first-five, select Review & accept options.'
    }

    It 'an accepted wave passes, and the record can be read back - who, when, and the levers themselves' {
        $doc = Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'first-five' -AcceptedBy 'operator' -Note 'reviewed' -Confirm:$false
        $doc.acceptedBy | Should -Be 'operator'
        $doc.machineCount | Should -Be 2
        @($doc.levers).Count | Should -Be 1 -Because 'both machines carry the same policy set'
        @($doc.levers)[0].capacityGate | Should -Be 'BestEffort'
        (Script:Gate $script:fx.Run $script:fx.Plan).Pass | Should -BeTrue
    }

    It 'editing a LEVER after acceptance invalidates it - accepting one thing must not authorise another' {
        Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'first-five' -AcceptedBy 'operator' -Confirm:$false | Out-Null
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        $plan.entries[0].policy.capacityGate = 'Reserved'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        $r = Script:Gate $script:fx.Run $script:fx.Plan
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'changed after operator accepted'
    }

    It 'WAVE-OPTIONS-DISKS-1: a change of a machine''s disk type choice after acceptance asks for a new acceptance' {
        # The dialog names each machine whose disk type the move changes, so
        # the acceptance must sign that choice. Each step below is a change a
        # person makes on the targets step and then plans again: none to
        # Standard SSD, Standard SSD to Premium SSD, OS disk to every disk,
        # and back to none.
        $setDisks = {
            param($value)
            $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
            if ($null -eq $value) { $plan.entries[0].policy.PSObject.Properties.Remove('diskUpgrade') }
            else { $plan.entries[0].policy | Add-Member -NotePropertyName diskUpgrade -NotePropertyValue $value -Force }
            $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        }
        $previous = $null
        foreach ($value in @('os-standard-ssd', 'os', 'all', $null)) {
            Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
                -Wave 'first-five' -AcceptedBy 'operator' -Confirm:$false | Out-Null
            (Script:Gate $script:fx.Run $script:fx.Plan).Pass | Should -BeTrue -Because "the wave was accepted with disks '$previous'"
            & $setDisks $value
            $r = Script:Gate $script:fx.Run $script:fx.Plan
            $r.Pass | Should -BeFalse -Because "the disk choice changed from '$previous' to '$value' after the acceptance"
            $r.Code | Should -Be 'changed'
            $previous = $value
        }
    }

    It 'changing the MEMBERSHIP after acceptance invalidates it too' {
        Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'first-five' -AcceptedBy 'operator' -Confirm:$false | Out-Null
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        $plan.entries = @($plan.entries[0])   # a machine left the wave
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        (Script:Gate $script:fx.Run $script:fx.Plan).Pass | Should -BeFalse
    }

    It 'accepting a wave with no entries throws - there is nothing to accept' {
        { Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'no-such-wave' -AcceptedBy 'operator' -Confirm:$false } |
            Should -Throw '*nothing to accept*'
    }

    It 'the hash is stable across entry ORDER - a re-sorted plan is not a changed wave' {
        $e = Script:Entries $script:fx.Plan
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $h1 = Get-VmfWaveOptionsHash -Entries $e
            $h2 = Get-VmfWaveOptionsHash -Entries @($e[1], $e[0])
            $h2 | Should -Be $h1
        }
    }
}

Describe 'WAVE-2: engine-enforced, wizard-independent' {
    It 'Start-VmfWave carries the gate, between the acknowledgement and the approval' {
        $sw = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $sw | Should -Match 'Test-VmfWaveOptionsAccepted'
        $idxAck = $sw.IndexOf('Test-VmfRunAcknowledged')
        $idxOpt = $sw.IndexOf('Test-VmfWaveOptionsAccepted')
        $idxAppr = $sw.IndexOf('Test-VmfWaveApproval')
        $idxAck | Should -BeLessThan $idxOpt
        $idxOpt | Should -BeLessThan $idxAppr -Because 'you accept what a wave IS before anyone signs off on running it'
    }

    It 'the facade accepts AS the signed-in person, never a typed name' {
        $fc = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $fn = [regex]::Match($fc, '(?s)function Invoke-VmfFacadeAcceptWaveOptions.*?\n\}').Value
        $fn | Should -Match '\$Principal\.Identity'
        $fn | Should -Match "Assert-VmfFacadeRole"
        $fn | Should -Not -Match 'AcceptedBy \$body' -Because 'an acceptance attributed to a typed name is not an audit trail'
    }

    # PUBLIC-SYNC-1: the lab drills do not ship to the public repository.
    It 'every lab drill accepts before it starts a wave - drills exercise the product, never bypass it' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' 'lab'))) {
        $offenders = @(Get-ChildItem (Join-Path $script:repoRoot 'tests' 'lab') -Filter 'Invoke-*.ps1' | ForEach-Object {
            $t = Get-Content $_.FullName -Raw
            # every non-WhatIf Start-VmfWave needs an acceptance somewhere before it
            if ($t -match '(?m)^\s*Start-VmfWave\b(?!.*-WhatIf)' -and $t -notmatch 'Confirm-VmfWaveOptions') { $_.Name }
        })
        $offenders -join ', ' | Should -BeNullOrEmpty
    }

    It 'the acceptance document has a schema and the sample conforms' {
        # SamplesConform covers this too; asserting here keeps the contract
        # near the behaviour it guards.
        $ok = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'wave-options-acceptance.sample.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json')
        $ok | Should -BeTrue
    }
}

Describe 'WAVE-2 lever 3: a machine that stops to ask a question stops ALONE' {
    # Lever 3: the default is to stop, per machine, not the whole wave. The rest
    # of the wave must carry on - so NEEDS_DECISION is terminal for that one
    # machine and is NOT an execution failure. If it counted, a handful of
    # machines with files on the temporary disk would trip the breaker and halt a
    # wave that had failed at nothing.
    It 'NEEDS_DECISION never trips the circuit breaker, however many stop' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lev3-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Initialize-VmfRun -RunPath $rp -RunId 'lev3' | Out-Null
                $entries = 1..6 | ForEach-Object {
                    $id = "/subscriptions/s/rg/r/providers/Microsoft.Compute/virtualMachines/vm$_"
                    New-VmfStateDoc -RunPath $rp -RunId 'lev3' -VmId $id -Wave 'first-five' | Out-Null
                    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok `
                        -Detail 'customer files found on the temporary disk' | Out-Null
                    [pscustomobject]@{ vmId = $id; wave = 'first-five' }
                }
                $plan = [pscustomobject]@{ entries = @($entries) }
                $b = Test-VmfCircuitBreaker -RunPath $rp -Plan $plan -Wave 'first-five' -ConsecutiveLimit 3 -RateLimit 0.5
                $b.Tripped | Should -BeFalse -Because 'a machine that stopped to ask a question did not fail'
                $b.Consecutive | Should -Be 0
            }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'WAVE-2 lever 8: the target generation is a per-wave choice, not a hard-coded one' {
    BeforeAll {
        # A region that has BOTH generations, and one that has only v6.
        $script:bothGens = @{}
        foreach ($n in 'Standard_D2ds_v6', 'Standard_D2ds_v7', 'Standard_D4ds_v6', 'Standard_D4ds_v7') {
            $script:bothGens[$n] = [pscustomobject]@{ Name = $n; Capabilities = @(
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '2' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }) }
        }
        $script:v6Only = @{ 'Standard_D2ds_v6' = $script:bothGens['Standard_D2ds_v6'] }
    }

    It 'defaults to v6 - the decided answer' {
        InModuleScope VmMigrationFactory -Parameters @{ cat = $script:bothGens } {
            (Get-VmfDefaultWavePolicy).targetGeneration | Should -Be 'v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $cat).Target | Should -Be 'Standard_D2ds_v6'
        }
    }

    It 'a wave that chose v7 gets v7' {
        InModuleScope VmMigrationFactory -Parameters @{ cat = $script:bothGens } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $cat -TargetGeneration 'v7').Target |
                Should -Be 'Standard_D2ds_v7'
        }
    }

    It 'a v7 wave in a region without v7 is REFUSED, never quietly given v6' {
        # Silent substitution is the failure this tool argues against
        # everywhere else; the refusal names the size that would work instead.
        InModuleScope VmMigrationFactory -Parameters @{ cat = $script:v6Only } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $cat -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Standard_D2ds_v6'
            $r.Reason | Should -Match 'Choose v6 for this machine in the Choose each target step'
            $r.Reason | Should -Not -Match '(?i)the wave is set'
        }
    }

    It 'a v6 machine can move to v7 - the tool is not only a v4/v5 story' {
        InModuleScope VmMigrationFactory -Parameters @{ cat = $script:bothGens } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v6' -CatalogBySize $cat -TargetGeneration 'v7').Target |
                Should -Be 'Standard_D2ds_v7'
        }
    }

    It 'the size suggestions stay inside the chosen generation' {
        # NIC-1 suggests the smallest size that holds the machine's interfaces.
        # Suggesting a v6 size to a wave that chose v7 would be the same silent
        # substitution by another door.
        InModuleScope VmMigrationFactory -Parameters @{ cat = $script:bothGens } {
            $s = Get-VmfSmallestSizeForNics -SourceSize 'Standard_D2ds_v4' -RequiredNics 2 -CatalogBySize $cat -TargetGeneration 'v7'
            $s.Name | Should -Match '_v7$'
        }
    }
}

Describe 'CAPACITY-3: a quota check follows the waves it describes' {
    # Found live, and it stopped the first end-to-end lab run: the planner
    # left a machine 'unscheduled', capacity was checked under that name, a
    # user then moved the machine into a named wave - and the engine
    # refused with "no quota records found" long after the wave was accepted
    # and approved. The claim described a wave that no longer existed.
    BeforeEach {
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cap3-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'cap3' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'unscheduled'; path = 'A'
                                        assessment = [ordered]@{ location = 'centralus' }
                                        target = [ordered]@{ size = 'Standard_D2ds_v6' }
                                        policy = [ordered]@{ capacityGate = 'BestEffort' } }) })
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/unscheduled-centralus.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 2; wave = 'unscheduled'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1 })
        }
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'clears a quota check whose wave no longer exists, instead of leaving it to be wrong' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Layout @{
            waves = @(@{ name = 'testwave'; vmIds = @($script:vm) })
        } -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            @(Get-VmfStoreNames -RunPath $rp -Folder 'capacity' -Extension '.json').Count | Should -Be 0 `
                -Because 'a check filed under a wave nobody has any more describes nothing'
            $events = @(Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl' | ForEach-Object { $_ | ConvertFrom-Json })
            # PLAIN-LOG-1: the sentence says what happened and what to do, in
            # the product's words; "checked again" was the old engine wording.
            $said = ($events | Where-Object { $_.step -eq 'capacity' }).detail
            $said | Should -Match 'no longer matched them and was removed'
            $said | Should -Match 'Check the quota'
        }
    }
}

Describe 'ACCEPT-HASH-1: the acceptance signs the settings that were shown' {
    <#
        WAVE-2 made the acceptance a first-class record: who, when, and a hash
        over the wave's levers and membership. What it never had was a way to
        tell whether the person SAW those levers.

        Confirm-VmfWaveOptions reads the plan when the call ARRIVES. The dialog
        that lists the levers is drawn earlier - from a plan already as old as
        the last refresh tick - and a Vmf.Operator may rewrite the wave while
        it sits open. Either way the record names a person as having chosen
        settings they were never shown, which is the one thing it exists to
        prove they did.

        APPR-2 fixed exactly this for approval. Acceptance is the gate that
        matters more: approval is a lever a wave may or may not carry,
        acceptance is universal - every wave, always.
    #>
    # The facade module is imported at the top of the file, before the Azure
    # guard, so the guard's mocks reach it (TEST-AZURE-GUARD-2).
    BeforeEach {
        $script:fx = Script:NewFixture
        $script:planHashNow = {
            $bytes = [System.IO.File]::ReadAllBytes($script:fx.Plan)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
                    ForEach-Object { $_.ToString('x2') }) -join ''
            }
            finally { $sha.Dispose() }
        }
    }
    AfterEach {
        if (Test-Path $script:fx.Run) { Remove-Item -LiteralPath $script:fx.Run -Recurse -Force }
    }

    It 'accepts when the hash matches the plan it is about to record' {
        $hash = & $script:planHashNow
        $doc = Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'first-five' -AcceptedBy 'operator' -ExpectedPlanHash $hash -Confirm:$false
        $doc.acceptedBy | Should -Be 'operator'
        (Script:Gate $script:fx.Run $script:fx.Plan).Pass | Should -BeTrue
    }

    It 'REFUSES with 409 when the wave changed since it was shown, and records NOTHING' {
        $stale = & $script:planHashNow
        # The operator lowers snapshot retention while the dialog is open. This
        # is the example that matters: the safety copies would be deleted by
        # the next daily cleanup, recorded as somebody else's decision.
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 24
        foreach ($entry in $plan.entries) {
            $entry.policy | Add-Member -NotePropertyName keepSnapshotDays -NotePropertyValue 0 -Force
        }
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        (& $script:planHashNow) | Should -Not -Be $stale   # the fixture really did change

        $err = $null
        try {
            Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
                -Wave 'first-five' -AcceptedBy 'operator' -ExpectedPlanHash $stale -Confirm:$false
        }
        catch { $err = "$_" }

        # Read the message clause by clause: -Throw and -BeLike both match
        # case-insensitively, and a single wildcard passes on almost any
        # wording. A weak assertion of exactly that shape survived mutation in
        # this repository once already.
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '409:*'
        $err | Should -BeLike '*wave*'
        $err | Should -BeLike '*changed*'
        $err | Should -BeLike '*accepted*'

        # And the gate must still be CLOSED. A refusal that left a record
        # behind would be worse than no guard at all.
        (Script:Gate $script:fx.Run $script:fx.Plan).Pass | Should -BeFalse
    }

    It 'writes no event for a refused acceptance' {
        try {
            Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
                -Wave 'first-five' -AcceptedBy 'operator' -ExpectedPlanHash ('f' * 64) -Confirm:$false
        }
        catch { }
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            @(Read-VmfEvents -RunPath $rp)
        }
        @($events | Where-Object { "$($_.detail)" -like '*accept*' }).Count | Should -Be 0
    }

    It 'still accepts with no hash at all - the command line is not in this race' {
        # Somebody at a terminal accepting from a plan file they just read has
        # no gap to race in. Making it mandatory everywhere would break that
        # for nothing.
        $doc = Confirm-VmfWaveOptions -RunPath $script:fx.Run -PlanPath $script:fx.Plan `
            -Wave 'first-five' -AcceptedBy 'operator' -Confirm:$false
        $doc.acceptedBy | Should -Be 'operator'
    }

    It 'the facade REQUIRES the hash - the browser is where the race lives' {
        # Asserted on the PARAMETER, not by calling without it: a missing
        # mandatory parameter PROMPTS on an interactive host, so a call-and-
        # catch test hangs rather than fails. Found the hard way on APPR-2.
        $cmd = Get-Command Invoke-VmfFacadeAcceptWaveOptions -Module FacadeCore
        $planHashParam = $cmd.Parameters['PlanHash']
        $planHashParam | Should -Not -BeNullOrEmpty -Because 'the facade must take a plan hash'
        $attr = @($planHashParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })
        @($attr | Where-Object { $_.Mandatory }).Count | Should -BeGreaterThan 0 -Because 'the browser cannot be trusted to send it by choice'
    }

    It 'the facade hands the hash to the cmdlet rather than dropping it' {
        $fc = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $fn = [regex]::Match($fc, '(?s)function Invoke-VmfFacadeAcceptWaveOptions.*?\n\}').Value
        $fn | Should -Match '-ExpectedPlanHash \$PlanHash' -Because 'a hash the facade accepts and never passes on is a gate that does nothing'
    }

    It 'the endpoint refuses a request with no plan hash, and calls a stale one a CONFLICT' {
        $run = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostAcceptWaveOptions' 'run.ps1') -Raw
        # The guard, not the call line: a pattern that matches the call would be
        # satisfied by passing $body.planHash while never checking it.
        $run | Should -Match "if \(-not \`$body\.planHash\) \{ throw '400:"
        $run | Should -Match "'\^409'.*Conflict" -Because 'a stale plan is not a server fault, and 500 tells the page to say the wrong thing'
    }
}

