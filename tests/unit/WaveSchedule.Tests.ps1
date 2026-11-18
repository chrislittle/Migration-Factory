#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCHED-1: a scheduled wave is a recorded decision, not a hidden timer. These
# tests pin the properties that make it safe: it is visible, it is cancellable,
# and it never becomes a way around sign-off.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:NewSchedRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            Initialize-VmfRun -RunPath $rp -RunId 'sch-test' | Out-Null
        }
        $rp
    }
}

Describe 'Set-VmfWaveSchedule - starting a wave later' {
    BeforeEach { $script:run = Script:NewSchedRun }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'records who scheduled it, when it runs, and why' {
        $at = (Get-Date).ToUniversalTime().AddHours(8)
        $s = Set-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1' -RunAtUtc $at `
            -ScheduledBy 'lead@example.com' -Note 'friday change window'
        $s.wave | Should -Be 'prod-1'
        $s.scheduledBy | Should -Be 'lead@example.com'
        # MACHINES-AT-ONCE-RANGE-1: the wave starts at its own number, read when it starts.
        $s.PSObject.Properties['throttle'] | Should -BeNullOrEmpty
        $s.state | Should -Be 'pending'
        ([datetime]::Parse($s.runAtUtc)).ToUniversalTime().Hour | Should -Be $at.Hour
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.step -eq 'schedule' -and $_.detail -match 'friday change window' }) | Should -Not -BeNullOrEmpty
    }

    It 'refuses a time that has already passed' {
        { Set-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1' -RunAtUtc (Get-Date).AddHours(-1) -Note 'x' } |
            Should -Throw '*already in the past*'
    }

    It 'is visible to anything that reads the run' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'x' | Out-Null
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'prod-2' -RunAtUtc (Get-Date).AddHours(3) -Note 'y' | Out-Null
        @(Get-VmfWaveSchedule -RunPath $script:run).Count | Should -Be 2
        @(Get-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1').Count | Should -Be 1
    }

    It 'can be cancelled before it fires, and the cancellation is recorded too' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'x' | Out-Null
        $c = Remove-VmfWaveSchedule -RunPath $script:run -Wave 'prod-1' -CancelledBy 'lead@example.com' -Note 'window moved'
        $c.Cancelled | Should -BeTrue
        @(Get-VmfWaveSchedule -RunPath $script:run).Count | Should -Be 0
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.detail -match 'cancelled by lead@example.com' }) | Should -Not -BeNullOrEmpty
    }

    It 'cancelling something that was never scheduled says so' {
        { Remove-VmfWaveSchedule -RunPath $script:run -Wave 'ghost' } | Should -Throw '*No schedule*'
    }

    It 'only releases schedules whose time has actually come' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'soon' -RunAtUtc (Get-Date).AddMinutes(30) -Note 'x' | Out-Null
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'later' -RunAtUtc (Get-Date).AddHours(6) -Note 'y' | Out-Null
        # SCHEDULE-START-ONCE-1: the schedule pass reads the due schedules
        # through Get-VmfScheduleStep (Get-VmfDueWaveSchedule was used by
        # nothing after that, and was removed).
        $due = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { param($rp) @(Get-VmfScheduleStep -RunPath $rp -AsOf (Get-Date).ToUniversalTime().AddHours(1)) }
        @($due).Count | Should -Be 1
        @($due)[0].Wave | Should -Be 'soon'
        @($due)[0].Step | Should -Be 'due'
        # nothing is due yet at the moment of scheduling
        @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { param($rp) @(Get-VmfScheduleStep -RunPath $rp -AsOf (Get-Date).ToUniversalTime()) }).Count | Should -Be 0
    }

    It 'scheduling is NOT approving - the sign-off gate stays ahead of it' {
        # The engine refuses an unapproved wave whoever asks, so a schedule
        # cannot be used to slip past sign-off. Proven by the approval gate's
        # own tests; asserted here as the contract this feature relies on.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Set-VmfWaveSchedule -RunPath $rp -Wave 'prod-1' -RunAtUtc (Get-Date).AddHours(1) -Note 'x' | Out-Null
            # a schedule document must never carry anything approval-shaped
            $doc = Read-VmfStoreJson -RunPath $rp -RelPath 'schedules/prod-1.json' -Depth 8
            $doc.PSObject.Properties.Name | Should -Not -Contain 'approvedBy'
            $doc.PSObject.Properties.Name | Should -Not -Contain 'planHash'
            Test-VmfStoreItem -RunPath $rp -RelPath 'approvals/prod-1.json' | Should -BeFalse
        }
    }
}


Describe 'Maintenance windows (SCHED-1 / arch section 9)' {
    BeforeAll {
        function Global:Entry { param([string]$Path = 'A') [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/vm/$([guid]::NewGuid())"; wave = 'w'; path = $Path } }
    }
    AfterAll { Remove-Item 'function:\Entry' -ErrorAction SilentlyContinue }

    It 'estimates from published expectations when the run has no history yet' {
        InModuleScope VmMigrationFactory {
            # six resizes, three at a time -> two rounds of ~10 min, plus safety
            $e = Get-VmfWaveDurationEstimate -Entries @(1..6 | ForEach-Object { [pscustomobject]@{ path = 'A' } }) -Throttle 3
            $e.Machines | Should -Be 6
            $e.EstimateMinutes | Should -Be 25    # (6 * 10 / 3) * 1.25
            $e.BasedOn | Should -Match 'expected times'
        }
    }

    It 'rebuilds are estimated higher than resizes - a wave of one is not a wave of the other' {
        InModuleScope VmMigrationFactory {
            $a = Get-VmfWaveDurationEstimate -Entries @([pscustomobject]@{ path = 'A' }) -Throttle 1
            $b = Get-VmfWaveDurationEstimate -Entries @([pscustomobject]@{ path = 'B' }) -Throttle 1
            $b.EstimateMinutes | Should -BeGreaterThan $a.EstimateMinutes
        }
    }

    It 'prefers what THIS run has actually done over any table' {
        InModuleScope VmMigrationFactory {
            # a machine that really took 60 minutes should outweigh the 10-minute default
            $docs = @([pscustomobject]@{ state = 'MIGRATED'; path = 'A'; history = @(
                [pscustomobject]@{ durationSec = 3600 }) })
            $e = Get-VmfWaveDurationEstimate -Entries @([pscustomobject]@{ path = 'A' }) -StateDocs $docs -Throttle 1
            $e.EstimateMinutes | Should -Be 75    # 60 * 1.25
            $e.BasedOn | Should -Match 'already done'
        }
    }

    It 'refuses a wave that will not fit, and says why in numbers' {
        $rp = Script:NewSchedRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                    schemaVersion = 1
                    entries = @(1..10 | ForEach-Object { [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/vm/$_"; wave = 'prod-1'; path = 'A'; policy = [ordered]@{ throttle = 5 } } })
                })
            }
            $tight = Test-VmfWaveWindow -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'prod-1' -WindowMinutes 20
            $tight.Fits | Should -BeFalse
            $tight.Reason | Should -Match '20 minute window'
            $tight.Reason | Should -Match 'split the wave' -Because 'a refusal should say what to do about it'

            $roomy = Test-VmfWaveWindow -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'prod-1' -WindowMinutes 600
            $roomy.Fits | Should -BeTrue
            $roomy.EstimateMinutes | Should -BeLessOrEqual 600
        }
        finally { Remove-Item $rp -Recurse -Force }
    }
}
