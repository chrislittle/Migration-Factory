#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app01/providers/Microsoft.Compute/virtualMachines/app01-web-03'
}

Describe 'VmfStateStore' {
BeforeEach {
    $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
        Initialize-VmfRun -RunPath $rp -RunId 'test-run' | Out-Null
    }
}

AfterEach {
    if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
}

Context 'Get-VmfVmKey' {
    It 'is filesystem-safe and stable' {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            $k1 = Get-VmfVmKey -VmId $id
            $k2 = Get-VmfVmKey -VmId $id
            $k1 | Should -Be $k2
            $k1 | Should -Match '^[A-Za-z0-9\-_.]+$'
            $k1 | Should -Match 'rg-app01--app01-web-03'
        }
    }
    It 'distinguishes same-named VMs in different subscriptions' {
        InModuleScope VmMigrationFactory {
            $a = Get-VmfVmKey -VmId '/subscriptions/aaa/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            $b = Get-VmfVmKey -VmId '/subscriptions/bbb/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            $a | Should -Not -Be $b
        }
    }
}

Context 'State documents' {
    It 'creates an initial PLANNED doc, idempotently' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $doc1 = New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id -Wave 'w1'
            $doc1.state | Should -Be 'PLANNED'
            $doc1.wave | Should -Be 'w1'
            $doc2 = New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id
            @($doc2.history).Count | Should -Be 1   # not duplicated
        }
    }

    It 'round-trips transitions with history' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -DurationSec 3.5 | Out-Null
            $doc = Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'GUEST_PREP' -Outcome ok -Detail 'stornvme fixed'
            $doc.state | Should -Be 'GUEST_PREP'
            @($doc.history).Count | Should -Be 3
            @($doc.history)[-1].detail | Should -Be 'stornvme fixed'
            # persisted, not just in memory
            (Read-VmfStateDoc -RunPath $rp -VmId $id).state | Should -Be 'GUEST_PREP'
        }
    }

    It 'refuses unknown schemaVersion' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id | Out-Null
            $path = Join-Path $rp 'state' ((Get-VmfVmKey -VmId $id) + '.json')
            $raw = Get-Content $path -Raw | ConvertFrom-Json
            $raw.schemaVersion = 99
            $raw | ConvertTo-Json -Depth 10 | Set-Content $path
            { Read-VmfStateDoc -RunPath $rp -VmId $id } | Should -Throw '*schemaVersion*'
        }
    }

    It 'refuses to write a doc missing required fields' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            { Write-VmfStateDoc -RunPath $rp -Document @{ schemaVersion = 1; vmId = 'x' } } |
                Should -Throw "*required field*"
        }
    }

    It 'atomic write leaves no temp files behind' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id | Out-Null
            Get-ChildItem (Join-Path $rp 'state') -Filter '*.tmp.*' | Should -BeNullOrEmpty
        }
    }

    It 'state docs written by the store validate against vm-state.schema.json required fields' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfStateDoc -RunPath $rp -RunId 'test-run' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            foreach ($f in @('schemaVersion', 'runId', 'vmId', 'state', 'history')) {
                $doc.$f | Should -Not -BeNullOrEmpty -Because "schema requires $f"
            }
        }
    }
}

Context 'Leases' {
    It 'exactly one worker can claim a VM' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $l1 = New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1'
            $l1 | Should -Not -BeNullOrEmpty
            $l1.workerId | Should -Be 'w1'
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w2' | Should -BeNullOrEmpty
        }
    }

    It 'release then re-claim works; wrong-owner release is refused' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1' | Out-Null
            { Remove-VmfLease -RunPath $rp -VmId $id -WorkerId 'w2' } | Should -Throw '*Refusing*'
            Remove-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1'
            (New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w2').workerId | Should -Be 'w2'
        }
    }

    It 'heartbeat renews only for the owner' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1' | Out-Null
            { Update-VmfLeaseHeartbeat -RunPath $rp -VmId $id -WorkerId 'w1' } | Should -Not -Throw
            { Update-VmfLeaseHeartbeat -RunPath $rp -VmId $id -WorkerId 'w2' } | Should -Throw '*abandon*'
        }
    }

    It 'watchdog finds expired leases and can reap them with -Force' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1' | Out-Null
            # age the heartbeat artificially
            $path = Get-VmfLeasePath -RunPath $rp -VmId $id
            $lease = Get-Content $path -Raw | ConvertFrom-Json
            $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
            Write-VmfJsonAtomic -Path $path -Document $lease

            $expired = Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 120
            @($expired).Count | Should -Be 1
            @($expired)[0].workerId | Should -Be 'w1'

            Remove-VmfLease -RunPath $rp -VmId $id -Force
            Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 120 | Should -BeNullOrEmpty
        }
    }

    It 'fresh leases are not reported expired' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1' | Out-Null
            Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 120 | Should -BeNullOrEmpty
        }
    }
}
}
