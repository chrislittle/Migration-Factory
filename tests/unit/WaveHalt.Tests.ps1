#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'Clear-VmfWaveHalt (REH-2: halt recovery is an operator workflow)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-halt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'halt-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'clears an active halt with an audited reason and re-arms lease granting' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Set-VmfWaveHalt -RunPath $rp -Reason 'circuit breaker: rate 40%'
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue
        }
        $r = Clear-VmfWaveHalt -RunPath $script:runPath -Note 'E-series fabric validation fixed; resuming wave' -ClearedBy 'operator'
        $r.WasHalted | Should -BeTrue
        $r.HaltReason | Should -Match 'circuit breaker'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeFalse
            $events = @(Read-VmfEvents -RunPath $rp -Step 'wave' | Where-Object { $_.detail -match 'HALT CLEARED' })
            $events.Count | Should -Be 1
            $events[0].detail | Should -Match 'operator'
        }
    }

    It 'is idempotent when no halt is active' {
        (Clear-VmfWaveHalt -RunPath $script:runPath -Note 'just checking').WasHalted | Should -BeFalse
    }
}
