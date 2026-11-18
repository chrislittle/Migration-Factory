#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H10 and M3 - the two paths that reported success while doing nothing.
#
# H10: a schedule naming a wave that no longer has plan entries (the wave was
# renamed after being scheduled - the same sequence that orphaned capacity
# claims) makes Test-VmfWaveWindow throw on every timer pass. The timer's
# try/catch sat OUTSIDE its run loop, so that throw abandoned the pass for
# every run after it in enumeration order, every five minutes, for ever - and
# because the failure was swallowed, the invocation recorded as a SUCCESS, so
# the project's own support query (AppRequests where Success == false) could
# not find it either.
#
# M3: workers were spawned with no output capture and no exit-code check, so a
# systematic failure produced "wave ok PLANNED=12", a Container Apps Job
# reported Succeeded, and a maintenance window was burned on a wave that
# migrated nothing.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:timer = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Raw
    $script:startWave = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
}

Describe 'EVAL-H10: one bad run cannot silence the timer for every other run' {
    It 'each run is attempted inside its own try' {
        # Structural, not textual: the catch must be INSIDE the foreach body.
        $loopStart = $script:timer.IndexOf('foreach ($runId in $runIds)')
        $loopStart | Should -BeGreaterThan 0
        $depth = 0; $bodyStart = -1; $bodyEnd = -1
        for ($i = $loopStart; $i -lt $script:timer.Length; $i++) {
            $ch = $script:timer[$i]
            if ($ch -eq '{') { if ($depth -eq 0) { $bodyStart = $i }; $depth++ }
            elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $bodyEnd = $i; break } }
        }
        $body = $script:timer.Substring($bodyStart, $bodyEnd - $bodyStart)
        $body | Should -Match 'try \{'
        $body | Should -Match 'catch \{' -Because 'a failure in one run must not abandon the runs after it'
    }

    It 'a schedule failure is recorded where a person looks, not only in a platform log' {
        # STEP-LOG-6: through Write-VmfStepLine, so a lost line never stops the pass.
        $script:timer | Should -Match "Write-VmfStepLine"
        $script:timer | Should -Match "-Step 'schedule' -Outcome fail"
    }
}

Describe 'EVAL-H10: a renamed wave takes its schedule with it' {
    BeforeEach {
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'sch-test' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'sch-test'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'old-name'; path = 'A'
                    policy = [ordered]@{ onDDataFound = 'stop' } }) })
            Write-VmfStoreJson -RunPath $rp -RelPath 'schedules/old-name.json' -Depth 8 -Document ([ordered]@{
                schemaVersion = 1; wave = 'old-name'; runAtUtc = '2030-01-01T02:00:00Z'; scheduledBy = 'sam' })
        }
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'cancels a schedule whose wave no longer exists, and says so' {
        $r = Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') `
            -ChangedBy 'operator' -Confirm:$false -Layout @{ waves = @(@{ name = 'new-name'; vmIds = @($script:vm) }) }
        @($r.SchedulesCancelled) | Should -Contain 'old-name'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            @(Get-VmfStoreNames -RunPath $rp -Folder 'schedules' -Extension '.json').Count | Should -Be 0 `
                -Because 'an orphan schedule renders nowhere and cannot be cancelled from any screen'
        }
    }

    It 'leaves a schedule for a wave that still exists' {
        $r = Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') `
            -ChangedBy 'operator' -Confirm:$false -Layout @{ waves = @(@{ name = 'old-name'; vmIds = @($script:vm) }) }
        @($r.SchedulesCancelled).Count | Should -Be 0
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Test-VmfStoreItem -RunPath $rp -RelPath 'schedules/old-name.json' | Should -BeTrue
        }
    }
}

Describe 'EVAL-M3: a wave that migrated nothing does not report success' {
    It 'captures what the workers said' {
        $script:startWave | Should -Match 'RedirectStandardError'
        $script:startWave | Should -Match 'RedirectStandardOutput'
    }

    It 'checks their exit codes when they are all gone with work pending' {
        $script:startWave | Should -Match '\$_\.ExitCode -ne 0'
    }

    It 'throws, so the container job fails rather than reporting Succeeded' {
        $script:startWave | Should -Match "migrated nothing"
        $script:startWave | Should -Match "-Step 'wave' -Outcome fail"
    }

    It 'and does not fire when the run was deliberately halted' {
        # A halted wave has workers exit on purpose; that is not a failure.
        $script:startWave | Should -Match 'if \(-not \(Test-VmfWaveHalted -RunPath \$RunPath\) -and \$failed\.Count -eq \$workers\.Count'
    }
}
