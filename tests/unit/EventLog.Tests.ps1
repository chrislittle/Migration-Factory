#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'VmfEventLog' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-log-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'writes one valid JSON line per event' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Write-VmfEvent -RunPath $rp -Step 'PRECHECK' -Outcome start -VmId 'vm1'
            Write-VmfEvent -RunPath $rp -Step 'PRECHECK' -Outcome ok -VmId 'vm1' -DurationSec 2.5 -Detail 'all good'
            $lines = Get-Content (Join-Path $rp 'logs' 'events.jsonl')
            @($lines).Count | Should -Be 2
            foreach ($line in $lines) { { $line | ConvertFrom-Json } | Should -Not -Throw }
            ($lines[1] | ConvertFrom-Json).durationSec | Should -Be 2.5
        }
    }

    It 'merges extra data without letting it clobber reserved keys' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Write-VmfEvent -RunPath $rp -Step 'azureops' -Outcome retry -Data @{
                requestId = 'abc-123'; attempt = 2; step = 'HACKED'; outcome = 'HACKED'
            }
            $evt = (Read-VmfEvents -RunPath $rp)[0]
            $evt.requestId | Should -Be 'abc-123'
            $evt.attempt | Should -Be 2
            $evt.step | Should -Be 'azureops'
            $evt.outcome | Should -Be 'retry'
        }
    }

    It 'reads back with vmId and step filters' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Write-VmfEvent -RunPath $rp -Step 'PRECHECK' -Outcome ok -VmId 'vm1'
            Write-VmfEvent -RunPath $rp -Step 'PRECHECK' -Outcome ok -VmId 'vm2'
            Write-VmfEvent -RunPath $rp -Step 'GUEST_PREP' -Outcome ok -VmId 'vm1'
            @(Read-VmfEvents -RunPath $rp).Count | Should -Be 3
            @(Read-VmfEvents -RunPath $rp -VmId 'vm1').Count | Should -Be 2
            @(Read-VmfEvents -RunPath $rp -VmId 'vm1' -Step 'GUEST_PREP').Count | Should -Be 1
        }
    }

    It 'returns empty (not error) for a run with no events' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfEvents -RunPath $rp | Should -BeNullOrEmpty
        }
    }

    It 'survives interleaved appends from concurrent writers' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            # simulate two writers alternating rapidly in-process
            1..50 | ForEach-Object {
                Write-VmfEvent -RunPath $rp -Step 'w1' -Outcome info -VmId "vm$_"
                Write-VmfEvent -RunPath $rp -Step 'w2' -Outcome info -VmId "vm$_"
            }
            $lines = Get-Content (Join-Path $rp 'logs' 'events.jsonl')
            @($lines).Count | Should -Be 100
            foreach ($line in $lines) { { $line | ConvertFrom-Json } | Should -Not -Throw }
        }
    }
}
