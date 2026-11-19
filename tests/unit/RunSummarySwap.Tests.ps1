#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
RUN-SUMMARY-SWAP-1: the overview and the migrations list count a machine that
Restore this machine left stopped, waiting for Finish the restore.

FINISH-COUNT-1 made the one definition (Get-VmfMachineOutcome and help.js's
machineOutcome) give such a machine `attention`: its record holds swapPending.
But the overview and the migrations list count run-status.json's summary, and
the summary counted machines by STATE. A restored machine keeps the state
MIGRATED, so the summary said no machine waits for a person while one was
stopped. And the restore that left the swap threw before the engine wrote the
summary again.

run-status v6 adds summary.waitsOnPerson (and one per wave): the machines whose
outcome waits for a person (Test-VmfOutcomeWaitsOnPerson - attention or
rolledBack, the rule of the Migrations page's Waiting on people card, twinned
in help.js and held to tests/fixtures/machine-outcomes.json).
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schema = Join-Path $script:repo 'schemas' 'run-status.schema.json'
    $script:fixture = Get-Content (Join-Path $script:repo 'tests' 'fixtures' 'machine-outcomes.json') -Raw | ConvertFrom-Json

    # Two waves of two, in plan order w1 then w2.
    $script:NewPlan = {
        [pscustomobject]@{ schemaVersion = 16; assessmentRunId = 'r1'; waveOrder = @('w1', 'w2'); entries = @(
            foreach ($w in 'w1', 'w2') { foreach ($n in 'a', 'b') {
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$w$n"; wave = $w; path = 'A'
                                   policy = [pscustomobject]@{ requireApproval = $true; throttle = 2 } } } }) }
    }

    # A run whose wave 1 ran: w1a MIGRATED, w1b in -Second.
    function Script:New-SwRun {
        param([string]$Second = 'MIGRATED')
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'sw' | Out-Null }
        (& $script:NewPlan) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json') -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; st = $Second } {
            New-VmfStateDoc -RunPath $rp -RunId 'sw' -VmId '/s/rg/vm/w1a' -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/w1a' -NewState 'MIGRATED' -Outcome ok | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'sw' -VmId '/s/rg/vm/w1b' -Wave 'w1' | Out-Null
            $outcome = if ($st -eq 'MIGRATED') { 'ok' } else { 'fail' }
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/w1b' -NewState $st -Outcome $outcome -Detail 'for the test' | Out-Null
        }
        $rp
    }

    # Change w1b's record: a restore newer than its last step, and with
    # -SwapLeft the swap Azure refused (swapPending). -Finish removes the swap
    # as Finish the restore does.
    function Script:Set-SwRecord {
        param([string]$RunPath, [switch]$Restore, [switch]$SwapLeft, [switch]$Finish)
        $file = InModuleScope VmMigrationFactory { (Get-VmfVmKey -VmId '/s/rg/vm/w1b') + '.json' }
        $docPath = Join-Path $RunPath 'state' $file
        $doc = Get-Content $docPath -Raw | ConvertFrom-Json -Depth 30
        if ($Restore) {
            $doc | Add-Member -Force -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{
                    restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o'); restoredBy = 'operator@example.com' })
        }
        if ($SwapLeft) {
            $doc | Add-Member -Force -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{
                    kind = 'restore'; swaps = @([pscustomobject]@{ lun = 0 }) })
        }
        if ($Finish -and $doc.PSObject.Properties['swapPending']) { $doc.PSObject.Properties.Remove('swapPending') }
        $doc | ConvertTo-Json -Depth 30 | Set-Content $docPath -Encoding utf8NoBOM
    }
    $script:Status = { param($rp) Get-Content (Join-Path $rp 'run-status.json') -Raw | ConvertFrom-Json -Depth 24 }
    $script:Write = { param($rp, $reason) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; why = $reason } { Update-VmfRunSummary -RunPath $rp -Reason $why | Out-Null } }
    $script:Wave1 = { param($s) @($s.summary.waves) | Where-Object { $_.wave -eq 'w1' } }
}

Describe 'RUN-SUMMARY-SWAP-1: which outcome waits for a person, decided once' {
    It 'the fixture names every outcome, and the engine agrees with it' {
        $map = $script:fixture.waitsOnPerson
        $map | Should -Not -BeNullOrEmpty -Because 'machine-outcomes.json holds the rule both languages read'
        @($map.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should -Be 'attention,leftOut,migrated,notStarted,putBack,rolledBack,unknown,working'
        foreach ($prop in $map.PSObject.Properties) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ o = $prop.Name } { Test-VmfOutcomeWaitsOnPerson -Outcome $o }
            $got | Should -Be ([bool]$prop.Value) -Because $prop.Name
        }
    }

    It 'every shared case: the engine waits on a person exactly when the fixture says' {
        foreach ($c in @($script:fixture.cases)) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { Test-VmfOutcomeWaitsOnPerson -Outcome (Get-VmfMachineOutcome -StateDoc $d) }
            $got | Should -Be ([bool]$script:fixture.waitsOnPerson.($c.outcome)) -Because $c.why
        }
    }

    It 'an outcome this version does not know waits for nobody - unknown is not a yes' {
        InModuleScope VmMigrationFactory { Test-VmfOutcomeWaitsOnPerson -Outcome 'somethingNew' } | Should -BeFalse
    }
}

Describe 'RUN-SUMMARY-SWAP-1: the summary counts by the one definition' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'pure: the machines that wait, in their wave and in the whole migration' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan) } {
            $st = @{ '/s/rg/vm/w1a' = 'MIGRATED'; '/s/rg/vm/w1b' = 'MIGRATED' }
            @{
                None = Get-VmfRunSummary -Plan $p -States $st -GateOf { param($w) $null } -Reason 'planSaved'
                One  = Get-VmfRunSummary -Plan $p -States $st -GateOf { param($w) $null } -Reason 'planSaved' -Waiting @('/S/RG/VM/W1B')
            }
        }
        $s.None.waitsOnPerson | Should -Be 0
        $s.One.waitsOnPerson | Should -Be 1 -Because 'the id is compared without regard to case'
        ($s.One.waves | Where-Object { $_.wave -eq 'w1' }).waitsOnPerson | Should -Be 1
        ($s.One.waves | Where-Object { $_.wave -eq 'w2' }).waitsOnPerson | Should -Be 0
        $s.One.stateCounts['MIGRATED'] | Should -Be 2 -Because 'no state is invented'
    }

    It 'THE REGRESSION: a machine a restore left stopped is counted, though its state is MIGRATED' {
        $script:rp = Script:New-SwRun
        & $script:Write $script:rp 'dailyCheck'
        (& $script:Status $script:rp).summary.waitsOnPerson | Should -Be 0
        Script:Set-SwRecord -RunPath $script:rp -Restore -SwapLeft
        & $script:Write $script:rp 'dailyCheck'
        $s = & $script:Status $script:rp
        $s.schemaVersion | Should -Be 8
        $s.summary.waitsOnPerson | Should -Be 1 -Because 'a change in this count alone is a change to write'
        (& $script:Wave1 $s).waitsOnPerson | Should -Be 1
        $s.summary.stateCounts.MIGRATED | Should -Be 2
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'each stop is counted by its outcome' {
        foreach ($case in @(
                @{ st = 'FAILED_NEEDS_ATTENTION'; restore = $false; swap = $false; want = 1; why = 'a stop' }
                @{ st = 'FAILED_NEEDS_ATTENTION'; restore = $true;  swap = $false; want = 0; why = 'a stop a restore ended' }
                @{ st = 'FAILED_NEEDS_ATTENTION'; restore = $true;  swap = $true;  want = 1; why = 'a stop a restore ended with a swap left' }
                @{ st = 'FAILED_ROLLED_BACK';     restore = $false; swap = $false; want = 1; why = 'a rollback, which the card always counted' }
                @{ st = 'NEEDS_DECISION';         restore = $false; swap = $false; want = 1; why = 'a decision' }
                @{ st = 'SKIPPED';                restore = $false; swap = $false; want = 0; why = 'a machine left out' })) {
            $script:rp = Script:New-SwRun -Second $case.st
            Script:Set-SwRecord -RunPath $script:rp -Restore:$case.restore -SwapLeft:$case.swap
            & $script:Write $script:rp 'dailyCheck'
            (& $script:Status $script:rp).summary.waitsOnPerson | Should -Be $case.want -Because $case.why
            Remove-Item $script:rp -Recurse -Force
        }
    }

    It 'quick path: a wave that counts a machine waiting is read again, so Finish the restore takes it off' {
        $script:rp = Script:New-SwRun
        Script:Set-SwRecord -RunPath $script:rp -Restore -SwapLeft
        & $script:Write $script:rp 'dailyCheck'
        (& $script:Status $script:rp).summary.waitsOnPerson | Should -Be 1
        Script:Set-SwRecord -RunPath $script:rp -Finish
        & $script:Write $script:rp 'planSaved'
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'planSaved'
        $s.summary.waitsOnPerson | Should -Be 0 -Because 'every state in wave 1 is MIGRATED, and only the record says the swap is done'
    }

    It 'quick path: a later write that changes no machine still counts the machine that waits' {
        $script:rp = Script:New-SwRun
        Script:Set-SwRecord -RunPath $script:rp -Restore -SwapLeft
        & $script:Write $script:rp 'dailyCheck'
        & $script:Write $script:rp 'planSaved'
        # Nothing changed, so nothing is written - unless the write lost the
        # count, which is a change.
        (& $script:Status $script:rp).summary.waitsOnPerson | Should -Be 1 -Because 'the stored counts of wave 1 are all MIGRATED, and only reading the record finds the swap'
    }

    It 'quick path: a wave with nobody waiting still keeps its counts, at no read' {
        $script:rp = Script:New-SwRun
        & $script:Write $script:rp 'dailyCheck'
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            if ([string]$RelPath -like 'state/*') { $script:reads++ }
            & (Get-Module VmMigrationFactory) { param($a, $b, $c) & (Get-Command Read-VmfStoreJson -CommandType Function) -RunPath $a -RelPath $b -Depth $c } $RunPath $RelPath $(if ($Depth) { $Depth } else { 24 })
        }
        & $script:Write $script:rp 'planSaved'
        $script:reads | Should -Be 0
        (& $script:Status $script:rp).summary.waitsOnPerson | Should -Be 0
    }
}

Describe 'RUN-SUMMARY-SWAP-1: the wave''s ten-second write' {
    BeforeAll {
        $script:Stored = {
            param([switch]$NoCount)
            $s = [pscustomobject]@{ reason = 'dailyCheck'; halted = $false; machines = 4; restoredStops = 0; waitsOnPerson = 2
                stateCounts = [pscustomobject]@{ MIGRATED = 2; NEEDS_DECISION = 1; PLANNED = 1 }
                waves = @([pscustomobject]@{ wave = 'w1'; machines = 2; members = ('a' * 64); restoredStops = 0; waitsOnPerson = 1; stateCounts = [pscustomobject]@{ MIGRATED = 2 } }
                          [pscustomobject]@{ wave = 'w2'; machines = 2; members = ('b' * 64); restoredStops = 0; waitsOnPerson = 1; stateCounts = [pscustomobject]@{ NEEDS_DECISION = 1; PLANNED = 1 } })
                next = [pscustomobject]@{ wave = 'w2'; waitsFor = 'running' } }
            if ($NoCount) {
                $s.PSObject.Properties.Remove('waitsOnPerson')
                foreach ($w in $s.waves) { $w.PSObject.Properties.Remove('waitsOnPerson') }
            }
            $s
        }
    }

    It 'the other waves keep their count; the running wave moves with its stops' {
        $patched = InModuleScope VmMigrationFactory -Parameters @{ s = (& $script:Stored) } {
            @{
                Same  = Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ NEEDS_DECISION = 1; CONVERTING = 1 } -Reason 'waveRunning'
                More  = Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ NEEDS_DECISION = 1; FAILED_ROLLED_BACK = 1 } -Reason 'waveRunning'
                Fewer = Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ MIGRATED = 1; CONVERTING = 1 } -Reason 'waveRunning'
            }
        }
        ($patched.Same.waves | Where-Object { $_.wave -eq 'w1' }).waitsOnPerson | Should -Be 1 -Because 'the machine a restore left stopped in wave 1 is still stopped'
        ($patched.Same.waves | Where-Object { $_.wave -eq 'w2' }).waitsOnPerson | Should -Be 1
        $patched.Same.waitsOnPerson | Should -Be 2
        ($patched.More.waves | Where-Object { $_.wave -eq 'w2' }).waitsOnPerson | Should -Be 2 -Because 'a new stop waits for a person'
        $patched.More.waitsOnPerson | Should -Be 3
        ($patched.Fewer.waves | Where-Object { $_.wave -eq 'w2' }).waitsOnPerson | Should -Be 0 -Because 'the decision was made and the machine moved on'
        $patched.Fewer.waitsOnPerson | Should -Be 1
    }

    It 'never below zero' {
        $patched = InModuleScope VmMigrationFactory -Parameters @{ s = (& $script:Stored) } {
            $s.waves[1].waitsOnPerson = 0
            Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ MIGRATED = 2 } -Reason 'waveRunning'
        }
        ($patched.waves | Where-Object { $_.wave -eq 'w2' }).waitsOnPerson | Should -Be 0
    }

}

Describe 'RUN-SUMMARY-SWAP-1: the engine writes the summary when a restore leaves a swap' {
    It 'the restore operation writes the summary in a finally, so a restore that throws writes it too' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        $b = [regex]::Match($entry, "(?s)\n    'restore' \{(.*?)\n    \}").Groups[1].Value
        $b | Should -Not -BeNullOrEmpty
        $b | Should -Match '(?s)try \{\s*\$r = Restore-VmfVm @restoreParams\s*(\$restoreReturned = \$true\s*)?\}\s*finally \{\s*try \{\s*& \(Get-Module VmMigrationFactory\) \{ param\(\$rp, \$id\) Update-VmfRunSummaryAfterPutBack -RunPath \$rp -VmId \$id \} \$runPath \$env:VMF_VM_ID\s*\}\s*catch \{\s*Write-Host'
        ([regex]::Matches($b, 'Update-VmfRunSummaryAfterPutBack')).Count | Should -Be 1 -Because 'one write, not two'
    }

    It 'the finish operation still writes it after Finish the restore ends the swap' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        $b = [regex]::Match($entry, "(?s)\n    'finish' \{(.*?)\n    \}").Groups[1].Value
        $b.IndexOf('Update-VmfRunSummaryAfterPutBack') | Should -BeGreaterThan $b.IndexOf('Complete-VmfDataDiskSwap @finishParams')
    }
}

Describe 'RUN-SUMMARY-SWAP-1: run-status v6' {
    It 'the schema is v8 and requires the count in the summary and in each wave' {
        $j = Get-Content $script:schema -Raw | ConvertFrom-Json -AsHashtable
        $j.properties.schemaVersion.const | Should -Be 8
        $j.properties.summary.properties.waitsOnPerson.type | Should -Be 'integer'
        $j.properties.summary.properties.waves.items.properties.waitsOnPerson.type | Should -Be 'integer'
        $j.properties.summary.required | Should -Contain 'waitsOnPerson' -Because 'every summary this version writes holds it (RUN-STATUS-OLD-SUMMARY-1)'
        InModuleScope VmMigrationFactory { $script:VmfRunStatusSchemaVersion } | Should -Be 8
    }

    It 'the contract sample is v7, carries the count, and validates' {
        $sample = Join-Path $script:repo 'schemas' 'samples' 'run-status.sample.json'
        $doc = Get-Content $sample -Raw | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 8
        $doc.summary.PSObject.Properties['waitsOnPerson'] | Should -Not -BeNullOrEmpty
        Get-Content $sample -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'the migration note names v5 to v6' {
        (Get-Content (Join-Path $script:repo 'docs' 'schema-migrations.md') -Raw) | Should -Match '## run-status v5 -> v6 \(2026-11-07, RUN-SUMMARY-SWAP-1\)'
    }
}
