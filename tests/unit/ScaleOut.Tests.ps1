#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCALE-2: scale OUT - more than one engine container on one wave.
#
# Since 2026-09-05 workers scale out to more containers, not up to a larger
# one, and this file proves it. The facade splits "at once" over containers (FacadeCore.Tests);
# this file holds the orchestrator's side: worker ids unique across
# containers, the record carrying the wave's TOTAL, and the one new rule -
# a container whose workers are done leaves quietly while another
# container's workers still hold machines, instead of declaring the wave
# finished.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:wave = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
    $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
    $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
}

Describe 'SCALE-2: is another container still working?' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-so-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'so' | Out-Null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a live lease held by a worker that is not mine means yes, and names the machine' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            New-VmfLease -RunPath $rp -VmId "${vm}a" -WorkerId 'worker-c1-1' | Out-Null
            New-VmfLease -RunPath $rp -VmId "${vm}b" -WorkerId 'worker-c2-1' | Out-Null
            $r = Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('worker-c1-1', 'worker-c1-2')
            $r.Working | Should -BeTrue
            @($r.Machines) | Should -Be @("${vm}b")
        }
    }

    It 'only my own leases means no' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            New-VmfLease -RunPath $rp -VmId "${vm}a" -WorkerId 'worker-c1-1' | Out-Null
            (Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('worker-c1-1')).Working | Should -BeFalse
        }
    }

    It 'a lease whose heartbeat has expired is a dead worker, not a working container' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            New-VmfLease -RunPath $rp -VmId "${vm}b" -WorkerId 'worker-c2-1' | Out-Null
            $rel = Get-VmfLeaseRelPath -VmId "${vm}b"
            $lease = Read-VmfStoreJson -RunPath $rp -RelPath $rel -Depth 6
            $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath $rel -Document $lease
            (Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('worker-c1-1') -TimeoutSeconds 900).Working | Should -BeFalse
            (Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('worker-c1-1') -TimeoutSeconds 7200).Working | Should -BeTrue -Because 'within a longer timeout it still counts'
        }
    }

    It 'no leases at all means no' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            (Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @()).Working | Should -BeFalse
        }
    }
}

Describe 'SCALE-2: the record carries the wave, not one container' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-so-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'so' | Out-Null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    # APPROVE-GROUP-1 bumped the document to v3 (the summary of the whole
    # migration), WAVE-APPROVE-TIMER-WORDS-1 to v4 (signOffOutOfDate), RESTORED-HOLD-1 to v5 (restoredStops), and OLD-REBUILD-RESTORE-READERS-1 to v7 (no reason rebuilt);
    # the throttle fields this item added are unchanged.
    It 'run status says the TOTAL at once and how many containers, and is v7' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}a"; wave = 'w1'; path = 'A' }) }
            $s = Write-VmfRunStatus -RunPath $rp -Plan $plan -Wave 'w1' -RunId 'so' -ThrottleLimit 40 -Containers 3
            $s.schemaVersion | Should -Be 8
            $s.throttle.limit | Should -Be 40
            $s.throttle.containers | Should -Be 3
            $again = Write-VmfRunStatus -RunPath $rp -Plan $plan -Wave 'w1' -RunId 'so' -ThrottleLimit 3
            $again.throttle.containers | Should -Be 1 -Because 'alone is one, which is every wave before SCALE-2'
        }
    }

    It 'the sample carries the new field and the schema names it' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'run-status.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 8
        $sample.throttle.containers | Should -Be 3
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'run-status.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.throttle.properties.PSObject.Properties.Name | Should -Contain 'containers'
    }
}

Describe 'SCALE-2: the orchestrator as one of N' {
    It 'takes its share, the total and its place, and names its workers so leases tell containers apart' {
        $script:wave | Should -Match '\[Parameter\(\)\]\[int\]\$ThrottleTotal = 0'
        $script:wave | Should -Match "\[Parameter\(\)\]\[string\]\`$Container = '1/1'"
        $script:wave | Should -Match "if \(\`$Container -match '\^\(\\d\+\)/\(\\d\+\)\$'\)"
        $script:wave | Should -Match "\`$workerPrefix = if \(\`$containerCount -gt 1\) \{ ""worker-c\`$containerIndex-"" \} else \{ 'worker-' \}"
        $script:wave | Should -Match "'-WorkerId', ""\`$workerPrefix\`$i"""
    }

    It 'writes the wave TOTAL to the record every pass and at the tally, with the container count' {
        ([regex]::Matches($script:wave, 'Write-VmfRunStatus [^\n]*-ThrottleLimit \$totalWorkers -Containers \$containerCount')).Count | Should -Be 2
        $script:wave | Should -Not -Match 'Write-VmfRunStatus [^\n]*-ThrottleLimit \$workerCount\b'
    }

    It 'when its workers are done but another container still holds machines, it leaves quietly - no tally, no "wave ok"' {
        $exit = [regex]::Match($script:wave, '(?s)if \(\$aliveWorkers\.Count -eq 0\) \{.*?if \(\$containerCount -gt 1\) \{(.*?)\n            \}').Groups[1].Value
        $exit | Should -Match 'Test-VmfOtherContainersWorking -RunPath \$RunPath -MyWorkerIds \$myIds -TimeoutSeconds \$LeaseTimeoutSeconds'
        $exit | Should -Match "has finished its share of wave \`$Wave\. The other engine containers still work on \`$\(\`$others\.Machines\.Count\)"
        $exit | Should -Match 'FinishedShare = \$true'
        $exit | Should -Not -Match "Outcome ok"
        # And the every-worker-failed diagnosis still comes AFTER, for a container that is alone or last.
        $script:wave.IndexOf('Test-VmfOtherContainersWorking') | Should -BeLessThan $script:wave.IndexOf('Every worker stopped without migrating anything')
    }

    It 'the memory lines say which container wrote them when there is more than one' {
        $script:wave | Should -Match "\`$containerTag = if \(\`$containerCount -gt 1\) \{ ""Container \`$containerIndex/\`$containerCount"" \} else \{ '' \}"
        ([regex]::Matches($script:wave, '\$\(if \(\$containerTag\) \{ "\$containerTag - " \} else \{ '''' \}\)')).Count | Should -Be 2
    }

    It 'a worker with nothing leasable WAITS while the wave is pending, and takes a machine the watchdog frees (found by the kill test)' {
        $worker = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1') -Raw
        $worker | Should -Match '\(Test-VmfWavePending -RunPath \$rp -Plan \$p -Wave \$w\) -and -not \(Test-VmfWaveHalted -RunPath \$rp\)'
        $worker | Should -Match "Get-VmfStoreNames -RunPath \`$rp -Folder 'leases' -Extension '\.lease'\)\.Count -gt 0" -Because 'no lease at all means nothing will ever free up'
        $worker | Should -Match 'if \(-not \$pending\) \{ break \}'
        # CI-SPEED-2 made the wait injectable so the multi-process test does not
        # pay 30 real seconds. What THIS test is about is unchanged: the worker
        # sleeps and CONTINUES rather than breaking out. The production default
        # is guarded separately, in Orchestrator.Tests.ps1.
        $worker | Should -Match 'Start-Sleep -Seconds \$IdleWaitSeconds\s*continue'
        $worker | Should -Match '\$IdleWaitSeconds = 30' -Because 'a real wave still waits 30 seconds'
        $worker | Should -Not -Match 'if \(-not \$claim\) \{ break \}' -Because 'exiting on "nothing leasable" is what orphaned three machines'
    }

    It 'the entrypoint hands the container its share, the total and its place' {
        $script:entry | Should -Match "if \(\`$env:VMF_THROTTLE_TOTAL\) \{ \`$waveParams\.ThrottleTotal = \[int\]\`$env:VMF_THROTTLE_TOTAL \}"
        $script:entry | Should -Match "if \(\`$env:VMF_CONTAINER\) \{ \`$waveParams\.Container = \[string\]\`$env:VMF_CONTAINER \}"
        $script:entry | Should -Match 'Start-VmfWave @waveParams'
    }
}
