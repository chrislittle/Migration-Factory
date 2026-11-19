#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
RESTORED-HOLD-1: a machine restored after a stop no longer holds the next wave.

Lab Session A, finding 69: after a restore that worked, the activity still said
"the run holds until somebody deals with 1 machine(s) waiting for a person",
and the summary of the migration still said its next wave waits for a
decision. A restore does not change the state - the machine stays
FAILED_NEEDS_ATTENTION or NEEDS_DECISION - and both readers asked the state
alone.

STATUS-WORDS-1 made the one rule for "a restore as new as the stop ends the
stop": Get-VmfMachineOutcome says putBack (held to
tests/fixtures/machine-status.json). These tests hold the plan's timer
(Get-VmfNextPlanWave / Get-VmfPlanRunDecision) and the summary
(Get-VmfRunSummary and its store reader, both paths) to that rule, and the
engine to writing the summary after a restore and a finish.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # Two waves of two, in plan order w1 then w2.
    $script:NewPlan = {
        [pscustomobject]@{ schemaVersion = 16; assessmentRunId = 'r1'; waveOrder = @('w1', 'w2'); entries = @(
            foreach ($w in 'w1', 'w2') { foreach ($n in 'a', 'b') {
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$w$n"; wave = $w; path = 'A'
                                   policy = [pscustomobject]@{ requireApproval = $true; throttle = 2 } } } }) }
    }

    # A run: wave 1 ran, w1a migrated and w1b stopped in -Stop.
    function Script:New-RhRun {
        param([string]$Stop = 'FAILED_NEEDS_ATTENTION', [switch]$SignOff)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'rh' | Out-Null }
        (& $script:NewPlan) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json') -Encoding utf8NoBOM
        if ($SignOff) {
            Approve-VmfPlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Note 'reviewed' `
                -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; st = $Stop } {
            New-VmfStateDoc -RunPath $rp -RunId 'rh' -VmId '/s/rg/vm/w1a' -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/w1a' -NewState 'MIGRATED' -Outcome ok | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rh' -VmId '/s/rg/vm/w1b' -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/w1b' -NewState $st -Outcome fail -Detail 'stopped for the test' -ReasonCode 'guestCheckFailed' | Out-Null
        }
        $rp
    }

    # A restore record on w1b, -Minutes after (or, negative, before) now -
    # the stop was written just now. -SwapLeft adds a data disk swap that is
    # left (swapPending), which Finish the restore still owes.
    function Script:Add-RhRestore {
        param([string]$RunPath, [int]$Minutes = 5, [switch]$SwapLeft)
        $file = InModuleScope VmMigrationFactory { (Get-VmfVmKey -VmId '/s/rg/vm/w1b') + '.json' }
        $docPath = Join-Path $RunPath 'state' $file
        $doc = Get-Content $docPath -Raw | ConvertFrom-Json -Depth 30
        $doc | Add-Member -Force -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{
                restoredUtc = (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString('o'); restoredBy = 'operator@example.com' })
        if ($SwapLeft) {
            $doc | Add-Member -Force -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{
                    kind = 'restore'; swaps = @([pscustomobject]@{ lun = 0 }) })
        }
        $doc | ConvertTo-Json -Depth 30 | Set-Content $docPath -Encoding utf8NoBOM
    }
    $script:Status = { param($rp) Get-Content (Join-Path $rp 'run-status.json') -Raw | ConvertFrom-Json -Depth 24 }
    $script:Decide = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Get-VmfPlanRunDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') } }
}

Describe 'RESTORED-HOLD-1: the next wave of a signed-off plan, as pure logic' {
    BeforeAll {
        $script:Next = { param([hashtable]$States, [string[]]$Settled)
            InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan); s = $States; d = $Settled } {
                Get-VmfNextPlanWave -Plan $p -States $s -SignedOff $true -Halted $false -Settled $d
            }
        }
    }

    It 'a machine whose stop a restore ended does not hold the run' {
        foreach ($stop in 'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION') {
            $s = @{ '/s/rg/vm/w1a' = 'MIGRATED'; '/s/rg/vm/w1b' = $stop }
            (& $script:Next $s @()).Reason | Should -Be 'held' -Because 'with no restore, the stop holds the run'
            $d = & $script:Next $s @('/s/rg/vm/w1b')
            $d.Reason | Should -Be 'start' -Because "a restore ended the $stop stop"
            $d.Wave | Should -Be 'w2'
        }
    }

    It 'the machine id is compared without regard to case' {
        $s = @{ '/s/rg/vm/w1a' = 'MIGRATED'; '/s/rg/vm/w1b' = 'FAILED_NEEDS_ATTENTION' }
        (& $script:Next $s @('/S/RG/VM/W1B')).Wave | Should -Be 'w2'
    }

    It 'another machine that still waits holds the run, and only it is named' {
        $s = @{ '/s/rg/vm/w1a' = 'NEEDS_DECISION'; '/s/rg/vm/w1b' = 'FAILED_NEEDS_ATTENTION' }
        $d = & $script:Next $s @('/s/rg/vm/w1b')
        $d.Reason | Should -Be 'held'
        $d.Detail | Should -Match 'The run holds until a person acts on 1 machine that waits: w1a$'
    }
}

Describe 'RESTORED-HOLD-1: the plan timer reads the restore from the store' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { @{ Pass = $true; Detail = 'acknowledged' } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { @{ Pass = $true; Detail = 'accepted' } }
        $script:rp = Script:New-RhRun -SignOff
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE REGRESSION: a restore newer than the stop lets the next wave start' {
        (& $script:Decide $script:rp).Reason | Should -Be 'held'
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        $d = & $script:Decide $script:rp
        $d.Reason | Should -Be 'start'
        $d.Wave | Should -Be 'w2'
    }

    It 'a restore older than the stop does not end it' {
        Script:Add-RhRestore -RunPath $script:rp -Minutes -60
        (& $script:Decide $script:rp).Reason | Should -Be 'held'
    }

    It 'a restore whose data disk swap is left still holds - Finish the restore waits for a person' {
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5 -SwapLeft
        (& $script:Decide $script:rp).Reason | Should -Be 'held'
    }
}

Describe 'RESTORED-HOLD-1: the summary of the migration' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'pure: a settled machine does not make the next wave wait for a decision, and keeps its state in the counts' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan) } {
            $st = @{ '/s/rg/vm/w1a' = 'MIGRATED'; '/s/rg/vm/w1b' = 'FAILED_NEEDS_ATTENTION' }
            @{
                Held    = Get-VmfRunSummary -Plan $p -States $st -GateOf { param($w) 'approval' } -Reason 'planSaved'
                Settled = Get-VmfRunSummary -Plan $p -States $st -GateOf { param($w) 'approval' } -Reason 'planSaved' -Settled @('/s/rg/vm/w1b')
            }
        }
        $s.Held.next.waitsFor | Should -Be 'decision'
        $s.Settled.next.waitsFor | Should -Be 'approval'
        $s.Settled.next.wave | Should -Be 'w2'
        $s.Settled.stateCounts['FAILED_NEEDS_ATTENTION'] | Should -Be 1 -Because 'no state is invented: the list page and the schema read these keys'
        @($s.Settled.stateCounts.Keys) -join ',' | Should -Be (@($s.Held.stateCounts.Keys) -join ',')
    }

    It 'pure: stored counts of a wave with a stopped machine still hold - the counts cannot say which machine' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan) } {
            Get-VmfRunSummary -Plan $p -States @{} -GateOf { param($w) 'approval' } -Reason 'planSaved' `
                -KnownCounts @{ w1 = @{ MIGRATED = 1; FAILED_NEEDS_ATTENTION = 1 } } -Settled @('/s/rg/vm/w1b')
        }
        $s.next.waitsFor | Should -Be 'decision'
    }

    It 'full read: the daily check finds the restore' {
        $script:rp = Script:New-RhRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        (& $script:Status $script:rp).summary.next.waitsFor | Should -Be 'decision'
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        $s = & $script:Status $script:rp
        $s.summary.next.waitsFor | Should -Be 'acknowledgement' -Because 'the next wave waits for its first start gate, not for a person'
        $s.summary.stateCounts.FAILED_NEEDS_ATTENTION | Should -Be 1
    }

    It 'quick path: a later write that changes no machine reads a wave with a stopped machine again' {
        $script:rp = Script:New-RhRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'planSaved'
        $s.summary.next.waitsFor | Should -Be 'acknowledgement' -Because 'the stored counts of wave 1 said a machine stopped, and only its record says a restore ended the stop'
    }

    It 'quick path: a wave with no stopped machine still keeps its counts' {
        $script:rp = Script:New-RhRun -Stop 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            if ([string]$RelPath -like 'state/*') { $script:reads++ }
            & (Get-Module VmMigrationFactory) { param($a, $b, $c) & (Get-Command Read-VmfStoreJson -CommandType Function) -RunPath $a -RelPath $b -Depth $c } $RunPath $RelPath $(if ($Depth) { $Depth } else { 24 })
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $script:reads | Should -Be 0 -Because 'a settled wave with nobody stopped costs no read'
    }

    It 'after a restore, the engine writes the summary and reads the machine''s wave again' {
        $script:rp = Script:New-RhRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        $ok = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId '/s/rg/vm/w1b' }
        $ok | Should -BeTrue
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'putBack' -Because 'v5 gives a machine put back its own reason'
        $s.summary.next.waitsFor | Should -Be 'acknowledgement'
        $s.summary.restoredStops | Should -Be 1
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId '/s/rg/vm/w1b' } | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 1 -Exactly -ParameterFilter { $Reason -eq 'putBack' -and @($Wave) -contains 'w1' }
    }

    It 'never throws: a machine with no record still writes the summary, reading every wave' {
        $script:rp = Script:New-RhRun
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId '/s/rg/vm/none' } } | Should -Not -Throw
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 1 -Exactly -ParameterFilter { @($Wave | Where-Object { $_ }).Count -eq 0 }
    }

    It 'never throws: a record that cannot be read still writes the summary, reading every wave' {
        $script:rp = Script:New-RhRun
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Read-VmfStateDoc { throw 'HTTP 503 the store is busy' }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId '/s/rg/vm/w1b' } } | Should -Not -Throw
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 1 -Exactly -ParameterFilter { @($Wave | Where-Object { $_ }).Count -eq 0 }
    }

    It 'the engine calls it after a restore and after a finish, inside a try' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        foreach ($pair in @(@('restore', 'Restore-VmfVm @restoreParams'), @('finish', 'Complete-VmfDataDiskSwap @finishParams'))) {
            $b = [regex]::Match($entry, "(?s)\n    '$($pair[0])' \{(.*?)\n    \}").Groups[1].Value
            $b | Should -Match "(?s)try \{\s*& \(Get-Module VmMigrationFactory\) \{ param\(\`$rp, \`$id\) Update-VmfRunSummaryAfterPutBack -RunPath \`$rp -VmId \`$id \} \`$runPath \`$env:VMF_VM_ID\s*\}\s*catch \{\s*Write-Host" -Because $pair[0]
            $b.IndexOf('Update-VmfRunSummaryAfterPutBack') | Should -BeGreaterThan $b.IndexOf($pair[1]) -Because $pair[0]
        }
    }
}

Describe 'RESTORED-HOLD-1: run-status v5 counts the stops a restore ended' {
    BeforeAll { $script:schema = Join-Path $script:repo 'schemas' 'run-status.schema.json' }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'pure: a settled machine in any stop state is counted, in its wave and in the whole migration' {
        foreach ($stop in 'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK') {
            $s = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan); st = $stop } {
                $states = @{ '/s/rg/vm/w1a' = 'MIGRATED'; '/s/rg/vm/w1b' = $st }
                @{
                    No  = Get-VmfRunSummary -Plan $p -States $states -GateOf { param($w) $null } -Reason 'planSaved'
                    Yes = Get-VmfRunSummary -Plan $p -States $states -GateOf { param($w) $null } -Reason 'planSaved' -Settled @('/s/rg/vm/w1b', '/s/rg/vm/w1a')
                }
            }
            $s.No.restoredStops | Should -Be 0 -Because $stop
            $s.Yes.restoredStops | Should -Be 1 -Because "$stop - and a migrated machine put back is not a stop"
            ($s.Yes.waves | Where-Object { $_.wave -eq 'w1' }).restoredStops | Should -Be 1
            ($s.Yes.waves | Where-Object { $_.wave -eq 'w2' }).restoredStops | Should -Be 0
        }
    }

    It 'the daily check writes v5, with the count, and it validates' {
        $script:rp = Script:New-RhRun
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        $s = & $script:Status $script:rp
        $s.schemaVersion | Should -BeGreaterOrEqual 5 -Because 'v5 added the count; RUN-SUMMARY-SWAP-1 made it v6'
        $s.summary.restoredStops | Should -Be 1
        $s.summary.stateCounts.FAILED_NEEDS_ATTENTION | Should -Be 1 -Because 'each machine stays under its own state'
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'quick path: a wave with a machine rolled back is read again, so a restore of it is counted' {
        $script:rp = Script:New-RhRun -Stop 'FAILED_ROLLED_BACK'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        (& $script:Status $script:rp).summary.restoredStops | Should -Be 0
        Script:Add-RhRestore -RunPath $script:rp -Minutes 5
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        (& $script:Status $script:rp).summary.restoredStops | Should -Be 1
    }

    It 'the wave''s ten-second write keeps the other waves'' count, and the running wave counts none' {
        $patched = InModuleScope VmMigrationFactory {
            $stored = [pscustomobject]@{ reason = 'dailyCheck'; halted = $false; machines = 4; restoredStops = 1; waitsOnPerson = 0
                stateCounts = [pscustomobject]@{ MIGRATED = 1; FAILED_NEEDS_ATTENTION = 1; PLANNED = 2 }
                waves = @([pscustomobject]@{ wave = 'w1'; machines = 2; members = ('a' * 64); restoredStops = 1; waitsOnPerson = 0; stateCounts = [pscustomobject]@{ MIGRATED = 1; FAILED_NEEDS_ATTENTION = 1 } }
                          [pscustomobject]@{ wave = 'w2'; machines = 2; members = ('b' * 64); restoredStops = 0; waitsOnPerson = 0; stateCounts = [pscustomobject]@{ PLANNED = 2 } })
                next = [pscustomobject]@{ wave = 'w2'; waitsFor = 'start' } }
            Update-VmfRunSummaryWave -Summary $stored -Wave 'w2' -Counts @{ CONVERTING = 1; PLANNED = 1 } -Reason 'waveRunning'
        }
        $patched.restoredStops | Should -Be 1
        ($patched.waves | Where-Object { $_.wave -eq 'w1' }).restoredStops | Should -Be 1
        ($patched.waves | Where-Object { $_.wave -eq 'w2' }).restoredStops | Should -Be 0
    }

    It 'the contract sample is v5, carries the count, and validates' {
        $sample = Join-Path $script:repo 'schemas' 'samples' 'run-status.sample.json'
        $doc = Get-Content $sample -Raw | ConvertFrom-Json
        $doc.schemaVersion | Should -BeGreaterOrEqual 5
        $doc.summary.PSObject.Properties['restoredStops'] | Should -Not -BeNullOrEmpty
        Get-Content $sample -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'the migration note names v4 to v5' {
        (Get-Content (Join-Path $script:repo 'docs' 'schema-migrations.md') -Raw) | Should -Match '## run-status v4 -> v5 \(2026-11-06, RESTORED-HOLD-1\)'
    }
}