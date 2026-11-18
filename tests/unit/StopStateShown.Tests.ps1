#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
STOP-STATE-SHOWN-1 (lab walk of DELETE-UNSTARTED-WAVE-1, 2026-11-17).

A migration with wave-1 done and wave-2 scheduled and not started. A person
selected Stop this migration with a note. Afterwards:
  1. nothing on the page said the migration was stopped: both waves read
     Complete, and What happens next said every wave had run;
  2. the Wave safety brake card turned red, "paused after repeated failures",
     and the activity said "The wave paused itself automatically after
     repeated failures" - nothing failed, a person stopped it;
  3. wave-2 still showed its scheduled start and Cancel the scheduled start;
  4. the activity line said "the migration of 1 machines ended".

The engine side, here: Stop records the stop where the page reads it
(stopped.json, schemas/run-stop.schema.json) - who, when, the note, the waves
that did not start, the machines it closed out, the schedules it removed. It
removes every scheduled start of the run, so no scheduled start begins a wave
of a stopped migration. It writes no HALTED line, which the page reads as the
brake. And the line counts one machine as one machine.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    # The lab case: wave-1 (st-a) migrated; wave-2 (st-b) not started, with a
    # scheduled start; wave-3 (st-c, st-d) part-way: st-c migrated, st-d not
    # started.
    function Global:SssRun([switch]$NoThird) {
        $run = Join-Path $TestDrive "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; s = $script:sub; third = -not $NoThird } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            $entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${s}st-a"; wave = 'wave-1'; path = 'A' },
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${s}st-b"; wave = 'wave-2'; path = 'A' })
            if ($third) {
                $entries += [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${s}st-c"; wave = 'wave-3'; path = 'A' }
                $entries += [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${s}st-d"; wave = 'wave-3'; path = 'A' }
            }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{ schemaVersion = 8; entries = $entries })
            foreach ($done in @("${s}st-a") + $(if ($third) { @("${s}st-c") } else { @() })) {
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $done -Wave 'w' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $done -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
            Set-VmfWaveSchedule -RunPath $rp -Wave 'wave-2' -RunAtUtc ((Get-Date).ToUniversalTime().AddHours(6)) -ScheduledBy 'lead@example.com' -Note 'change window' -Confirm:$false | Out-Null
        }
        $run
    }
}
AfterAll { Remove-Item 'function:\SssRun' -ErrorAction SilentlyContinue }

Describe 'Stop-VmfRun records the stop where the page reads it' {
    BeforeEach { Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } } }

    It 'writes stopped.json: who, when, the note, the waves that did not start, the machines it closed, the schedules it removed' {
        $run = SssRun
        # A worker that took st-b and wrote PLANNED has not started it.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = "$($script:sub)st-b" } { New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $b -Wave 'wave-2' | Out-Null }
        Stop-VmfRun -RunPath $run -Reason 'The second wave is not needed.' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        $rec = InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfStoreJson -RunPath $rp -RelPath 'stopped.json' -Depth 4 }
        $rec.schemaVersion | Should -Be 1
        $rec.runId | Should -Be 'run-x'
        $rec.stoppedBy | Should -Be 'operator@example.com'
        $rec.note | Should -Be 'The second wave is not needed.'
        [string]$rec.stoppedUtc | Should -Not -BeNullOrEmpty
        @($rec.wavesNotStarted) | Should -Be @('wave-2') -Because 'wave-3 had a machine that migrated, so it started'
        @($rec.machines | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be @('st-b', 'st-d')
        @($rec.schedulesRemoved) | Should -Be @('wave-2')
    }

    It 'a second stop keeps the first record: who, when, the note and what the first stop ended' {
        # Review: the record was built from live state and written on every
        # stop. On a second stop the machines are SKIPPED already, so it said
        # no wave was left unstarted, and the page drew wave-2 Complete again.
        $run = SssRun
        Stop-VmfRun -RunPath $run -Reason 'first' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        $first = InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfStoreText -RunPath $rp -RelPath 'stopped.json' }
        Stop-VmfRun -RunPath $run -Reason 'second' -StoppedBy 'lead@example.com' -Confirm:$false | Out-Null
        $now = InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfStoreText -RunPath $rp -RelPath 'stopped.json' }
        $now | Should -BeExactly $first
        ($now | ConvertFrom-Json).wavesNotStarted | Should -Be @('wave-2')
    }

    It 'a stop that ended part way through its closing, run again, keeps the record of the first try' {
        # Hard rule 4: a step is safe to run again. The first try closes st-b,
        # then stops at st-d; the second try finishes.
        $run = SssRun
        $global:SssCrash = $true
        Mock -ModuleName VmMigrationFactory Add-VmfStateTransition -ParameterFilter { $VmId -like '*/st-d' -and $global:SssCrash } {
            $global:SssCrash = $false
            throw 'the engine stopped here'
        }
        try {
            { Stop-VmfRun -RunPath $run -Reason 'first' -StoppedBy 'operator@example.com' -Confirm:$false } | Should -Throw '*stopped here*'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = "$($script:sub)st-b" } {
                (Read-VmfStateDoc -RunPath $rp -VmId $b).state | Should -Be 'SKIPPED' -Because 'the first try closed st-b'
            }
            Stop-VmfRun -RunPath $run -Reason 'again' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        finally { Remove-Variable -Name SssCrash -Scope Global -ErrorAction SilentlyContinue }
        $rec = InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfStoreJson -RunPath $rp -RelPath 'stopped.json' -Depth 4 }
        $rec.note | Should -Be 'first'
        @($rec.wavesNotStarted) | Should -Be @('wave-2')
        @($rec.machines | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be @('st-b', 'st-d')
        @($rec.schedulesRemoved) | Should -Be @('wave-2')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Test-VmfStoreItem -RunPath $rp -RelPath 'schedules/wave-2.json' | Should -BeFalse }
    }
    It 'the record holds to its schema' {
        $run = SssRun
        Stop-VmfRun -RunPath $run -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        $text = InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfStoreText -RunPath $rp -RelPath 'stopped.json' }
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'run-stop.schema.json') -Raw
        Test-Json -Json $text -Schema $schema | Should -BeTrue
    }

    It 'removes every scheduled start of the run, so no scheduled start begins a wave of a stopped migration' {
        $run = SssRun
        Stop-VmfRun -RunPath $run -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            Test-VmfStoreItem -RunPath $rp -RelPath 'schedules/wave-2.json' | Should -BeFalse
            # The step the service's schedule pass takes: nothing is due, and nothing has a start on record.
            @(Get-VmfScheduleStep -RunPath $rp -AsOf ((Get-Date).ToUniversalTime().AddDays(2))).Count | Should -Be 0
            @(Read-VmfEvents -RunPath $rp -Step 'schedule' | Where-Object { $_.detail -eq 'Stop this migration removed the scheduled start of wave wave-2.' }).Count | Should -Be 1
        }
    }

    It 'a refused stop records nothing and keeps the schedule' {
        $run = SssRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = "$($script:sub)st-b" } {
            New-VmfLease -RunPath $rp -VmId $b -WorkerId 'worker-1' | Out-Null
        }
        { Stop-VmfRun -RunPath $run -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false } | Should -Throw '*still holds*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            Test-VmfStoreItem -RunPath $rp -RelPath 'stopped.json' | Should -BeFalse
            Test-VmfStoreItem -RunPath $rp -RelPath 'schedules/wave-2.json' | Should -BeTrue
        }
    }

    It 'writes no HALTED line: a stop is not the wave safety brake' {
        $run = SssRun
        Stop-VmfRun -RunPath $run -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match 'HALTED' }).Count | Should -Be 0
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue -Because 'the pause still stops any worker'
        }
    }

    It 'says one machine as one machine, and two as two' {
        $one = SssRun -NoThird
        Stop-VmfRun -RunPath $one -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        $two = SssRun
        Stop-VmfRun -RunPath $two -Reason 'n' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        $line = { param($rp) @(InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Read-VmfEvents -RunPath $rp -Step 'run' }) | Select-Object -Last 1 }
        (& $line $one).detail | Should -Be 'run stopped by operator@example.com: n (the migration of 1 machine ended)'
        (& $line $two).detail | Should -Be 'run stopped by operator@example.com: n (the migration of 2 machines ended)'
    }
}
