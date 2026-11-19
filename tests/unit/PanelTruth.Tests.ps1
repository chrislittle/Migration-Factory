#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PANEL-TRUTH-1: a machine stopped for accelerated networking is untouched, and
# says so.
#
# Found in the ADVISOR-1 end-to-end run. A Generation 1 machine going to Intel D
# v5 with accelerated networking off stopped for an approver. Its panel read
# "Paused for a human decision before anything is changed" AND "This machine is
# NOT as it was - read this before trying again", and offered "Rebuild this
# machine". The stop came from Preparing, a step that CAN change a machine, and a
# step that does not say what it left behind is recorded as 'changed'. This one
# had changed nothing: the check runs before the preparation.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
}

Describe 'PANEL-TRUTH-1: the stop says what it left behind' {

    It 'the accelerated networking stop in Preparing records the machine as untouched' {
        $script:code | Should -Match "Reason = 'acceleratedNetworkingRequired'; Detail = \`$an\.Detail; MachineState = 'untouched'"
    }

    It 'and so does the driver stop beside it, which runs before the preparation too' {
        $script:code | Should -Match "Reason = 'driverBelowFloor'; Detail = \`$an\.Detail; MachineState = 'untouched'"
    }

    It 'the engine writes what a step says it left behind, before its own guess' {
        # PREP-ROLLBACK-1: what the step says wins, except an untouched GUEST_PREP
        # stop after a fix reported FIXED in this attempt (review 2, finding 6).
        $script:code | Should -Match 'if \(\$result\.MachineState\) \{'
        $script:code | Should -Match 'else \{ \[string\]\$result\.MachineState \}'
    }
}

Describe 'PANEL-TRUTH-1: the stop comes before the machine is stopped' {

    It 'Checking asks it, after the capture - before the first safety copy stops the machine' {
        $pre = [regex]::Match($script:code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $pre | Should -Match 'Resolve-VmfAcceleratedNetworkingForMove -PlanEntry \$plan -CapturedNics \$capturedConfig\.nics'
        $pre.IndexOf('Save-VmfCapturedFacts') | Should -BeLessThan $pre.IndexOf('Resolve-VmfAcceleratedNetworkingForMove')
    }

    It 'the rule answers without a reading from inside the machine, which Checking does not have' {
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
                policy = [pscustomobject]@{ targetGeneration = 'v5' }; assessment = [pscustomobject]@{ os = 'Windows' } }
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics @([pscustomobject]@{ primary = $true; acceleratedNetworking = $false })
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'a machine with it on is not stopped' {
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
                policy = [pscustomobject]@{ targetGeneration = 'v5' }; assessment = [pscustomobject]@{ os = 'Windows' } }
            (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics @([pscustomobject]@{ primary = $true; acceleratedNetworking = $true })).Stop |
                Should -BeFalse
        }
    }
}
