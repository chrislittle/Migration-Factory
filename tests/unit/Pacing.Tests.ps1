#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCALE-1, the half that was still open: shared pacing.
#
# At scale, the product needs tooling that handles throttling when quota or
# capacity is not available, to avoid failures.
#
# Per-call retry handles ONE 429. Capacity back-pressure halts a wave whose
# cells are exhausted. Neither spreads load - N workers hit ARM with no
# coordination, so a wave large enough to throttle throttles all at once and
# every worker burns its retry budget in parallel.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pace-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $rp } {
            Initialize-VmfRun -RunPath $runPath -RunId (Split-Path $runPath -Leaf) -Kind 'migration' | Out-Null
            Clear-VmfPacingCache
        }
        $rp
    }
}
AfterAll { Remove-Item 'function:\NewRun' -ErrorAction SilentlyContinue }

Describe 'SCALE-1: a worker tells the others it was throttled' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'no signal means no delay - pacing is free when nothing is throttling' {
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Get-VmfPacingWaitMs -RunPath $runPath | Should -Be 0
        }
    }

    It 'a published signal makes other workers wait' {
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfThrottleSignal -RunPath $runPath -Seconds 30
            Clear-VmfPacingCache          # a DIFFERENT worker, with a cold cache
            Get-VmfPacingWaitMs -RunPath $runPath | Should -BeGreaterThan 0
        }
    }

    It 'and the wait is JITTERED, so they do not all resume together' {
        # Every worker waiting the full cool-off just moves the stampede. The
        # jitter is the mechanism, not a detail - so it is asserted.
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfThrottleSignal -RunPath $runPath -Seconds 60
            $seen = foreach ($i in 1..25) { Clear-VmfPacingCache; Get-VmfPacingWaitMs -RunPath $runPath }
            (@($seen) | Sort-Object -Unique).Count | Should -BeGreaterThan 1 -Because 'identical waits would reschedule the stampede rather than spread it'
        }
    }

    It 'an expired signal is over - it clears itself, with no all-clear message' {
        # A worker that died holding a signal must not silence the run.
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfStoreJson -RunPath $runPath -RelPath 'pacing.json' -Depth 4 -Document ([ordered]@{
                schemaVersion = 1
                throttledUntilUtc = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
            })
            Clear-VmfPacingCache
            Get-VmfPacingWaitMs -RunPath $runPath | Should -Be 0
        }
    }

    It 'a corrupt or unreadable signal is ignored, never fatal' {
        # Pacing is an optimisation. It must never be the reason a migration
        # stalls or a healthy operation fails.
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfStoreJson -RunPath $runPath -RelPath 'pacing.json' -Depth 4 -Document ([ordered]@{
                schemaVersion = 1; throttledUntilUtc = 'not a date at all'
            })
            Clear-VmfPacingCache
            { Get-VmfPacingWaitMs -RunPath $runPath } | Should -Not -Throw
            Get-VmfPacingWaitMs -RunPath $runPath | Should -Be 0
        }
    }

    It 'publishing cannot fail the operation it was reporting on' {
        InModuleScope VmMigrationFactory {
            { Write-VmfThrottleSignal -RunPath 'X:\no\such\place\at\all' -Seconds 5 } | Should -Not -Throw
        }
    }
}

Describe 'SCALE-1: only a THROTTLE is broadcast' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a 429 publishes a signal for the other workers' {
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            $script:calls = 0
            Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -RunPath $runPath -Operation {
                $script:calls++
                if ($script:calls -lt 2) { throw 'Response status code 429 (TooManyRequests)' }
                'ok'
            } | Should -Be 'ok'
            (Test-VmfStoreItem -RunPath $runPath -RelPath 'pacing.json') | Should -BeTrue
        }
    }

    It 'a socket reset does NOT - that is about this call, not the subscription' {
        # Broadcasting every transient would have every worker pausing for one
        # machine's bad connection.
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            $script:calls = 0
            Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -RunPath $runPath -Operation {
                $script:calls++
                if ($script:calls -lt 2) {
                    throw ([System.Net.Http.HttpRequestException]::new(
                        'An error occurred while sending the request.',
                        [System.Net.Sockets.SocketException]::new(10054)))
                }
                'ok'
            } | Should -Be 'ok'
            (Test-VmfStoreItem -RunPath $runPath -RelPath 'pacing.json') | Should -BeFalse
        }
    }

    It 'and a call with no run path is never paced at all' {
        # Ad-hoc and library callers have no run to coordinate with.
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 2) { throw 'Response status code 429 (TooManyRequests)' }
                'ok'
            } | Should -Be 'ok'
        }
    }
}

Describe 'SCALE-1: it does not become its own load problem' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the signal is CACHED, so it is not a store read per ARM call' {
        # A coordination round trip per call would cost more than it saves.
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfThrottleSignal -RunPath $runPath -Seconds 30
            $before = (Get-Item (Join-Path $runPath 'pacing.json')).LastAccessTimeUtc
            foreach ($i in 1..50) { Get-VmfPacingWaitMs -RunPath $runPath -CacheTtlSeconds 300 | Out-Null }
            # Proven by behaviour rather than by counting file reads: with a long
            # TTL the answer is served from cache even after the file is deleted.
            Remove-Item (Join-Path $runPath 'pacing.json') -Force
            Get-VmfPacingWaitMs -RunPath $runPath -CacheTtlSeconds 300 | Should -BeGreaterThan 0
            $before | Should -Not -BeNullOrEmpty
        }
    }

    It 'and a stale cache is re-read once its TTL passes' {
        $script:rp = NewRun
        InModuleScope VmMigrationFactory -Parameters @{ runPath = $script:rp } {
            Write-VmfThrottleSignal -RunPath $runPath -Seconds 30
            Get-VmfPacingWaitMs -RunPath $runPath | Should -BeGreaterThan 0
            Remove-Item (Join-Path $runPath 'pacing.json') -Force
            # TTL 0 forces the re-read without the test waiting for one.
            Get-VmfPacingWaitMs -RunPath $runPath -CacheTtlSeconds 0 | Should -Be 0
        }
    }
}
