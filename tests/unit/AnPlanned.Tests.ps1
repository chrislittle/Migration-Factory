#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AN-PLAN-1: accelerated networking a target requires is turned on by accepting
# the wave's settings - decided once, at plan time.
#
# Found by the first end-to-end run of ADVISOR-1. Intel D v5 requires
# accelerated networking, and a Generation 1 machine with it off stopped in the
# middle of its move for an approver - after the first safety copy had already
# stopped and started it. The product knew this at plan time: the targets step
# even said "stops once, for an approver". The owner: a person should not have
# to approve the same thing twice.
#
# So the plan sets acceleratedNetworking = ensureOn for such a machine, the
# wave's settings name it where they are accepted, and the acceptance - which is
# bound by hash to every machine's settings - is the approval. The engine
# already moves an explicit ensureOn without stopping. A machine planned without
# it (an older plan, or a reading the scan could not make) still stops as before.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Script:Planned($vm, [string]$size) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm; s = $size } {
            Get-VmfPlannedAcceleratedNetworking -Vm $v -TargetSize $s
        }
    }
}

Describe 'AN-PLAN-1: which machines the plan turns it on for' {

    It '<Case>' -ForEach @(
        @{ Case = 'Intel D v5, no interface has it: turned on'; Vm = @{ acceleratedNicCount = 0 }; Size = 'Standard_D2s_v5'; Want = 'ensureOn' }
        @{ Case = 'Intel D v5, the primary interface has it off: turned on'; Vm = @{ primaryNicAccelerated = $false; acceleratedNicCount = 1 }; Size = 'Standard_D2s_v5'; Want = 'ensureOn' }
        @{ Case = 'Intel D v5, the primary interface has it on: nothing to do'; Vm = @{ primaryNicAccelerated = $true; acceleratedNicCount = 1 }; Size = 'Standard_D2s_v5'; Want = $null }
        @{ Case = 'Intel D v5, unknown: the engine decides live, as before'; Vm = @{ }; Size = 'Standard_D2s_v5'; Want = $null }
        @{ Case = 'AMD v5 does not require it'; Vm = @{ acceleratedNicCount = 0 }; Size = 'Standard_D2as_v5'; Want = $null }
        @{ Case = 'v6 requires it (DRIFT-11): turned on'; Vm = @{ acceleratedNicCount = 0 }; Size = 'Standard_D2s_v6'; Want = 'ensureOn' }
        @{ Case = 'v7 does not require it'; Vm = @{ acceleratedNicCount = 0 }; Size = 'Standard_D2s_v7'; Want = $null }
        @{ Case = 'no target: nothing'; Vm = @{ acceleratedNicCount = 0 }; Size = ''; Want = $null }
    ) {
        Script:Planned ([pscustomobject]$Vm) $Size | Should -Be $Want
    }

    It 'a multi-interface machine read only by count, with some on, is left to the engine - the primary may be the one that is off' {
        Script:Planned ([pscustomobject]@{ acceleratedNicCount = 1; nicCount = 2 }) 'Standard_D2s_v5' | Should -BeNullOrEmpty
    }
}

Describe 'AN-PLAN-1: the engine moves a planned machine without stopping' {

    It 'ensureOn in the plan, off on the machine, Intel D v5: no stop, turned on' {
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
                policy = [pscustomobject]@{ targetGeneration = 'v5'; acceleratedNetworking = 'ensureOn' }
                assessment = [pscustomobject]@{ os = 'Windows' } }
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics @([pscustomobject]@{ primary = $true; acceleratedNetworking = $false })
            $r.Stop | Should -BeFalse
            $r.Policy | Should -Be 'ensureOn'
        }
    }

    It 'without it, the same machine still stops, as before' {
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
                policy = [pscustomobject]@{ targetGeneration = 'v5' }
                assessment = [pscustomobject]@{ os = 'Windows' } }
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics @([pscustomobject]@{ primary = $true; acceleratedNetworking = $false })
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }
}

Describe 'AN-PLAN-1: every place that sets a target size applies it' {

    It '<Where>' -ForEach @(
        @{ Where = 'New-VmfPlan'; File = 'src/VmMigrationFactory/Public/New-VmfPlan.ps1' }
    ) {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $File) | Should -Match 'Get-VmfPlannedAcceleratedNetworking'
    }

    It 'the plan entry carries the readings it needs, so a later series change can apply it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1')
        $code | Should -Match 'acceleratedNicCount ='
        $code | Should -Match 'primaryNicAccelerated ='
    }
}

Describe 'AN-PLAN-1: accepting the settings is where a person sees it' {

    It 'both acceptance screens name the machines, and the targets step no longer calls it a stop' {
        $mig = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        $mig | Should -Match 'UX_LEVER\.anMachines, anTurnsOnNames\(entries\)'
        $wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match 'UX\.lvAn, anTurnsOnNames\(wave\)'
        $wiz | Should -Not -Match 'Stops once, for an approver'
    }
}
