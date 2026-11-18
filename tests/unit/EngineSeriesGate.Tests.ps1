#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V5-GATE-1: the engine judges the scan against the plan's size series.
#
# Found by the V5-LAB-1 drill, 2026-09-26. A Generation 1 machine was planned
# for v5 (Path A, D2s_v4 to D2s_v5) and the engine then ended it SKIPPED:
# "Assessment classification is 'Blocked'". The planner had judged the machine
# against v5 and found it ready - that is why it chose Path A - but the plan
# keeps the scan's own classification, which was decided for every series, and
# the engine's gate read that as it stood.
#
# The unit tests stopped at the planner's judgement and never asked what the
# engine does with the entry. These do.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    # A size outside the scope of this tool stops the precheck at that check
    # (sizeOutOfScope), the first stop after the gate - so reaching it proves
    # the gate let the machine through, and no Azure call is made either way.
    # MANUAL-REVIEW-1: it was a policy that asked for a bootable clone, a stop
    # that is gone. OLD-VERSION-READERS-REMOVE-1: the path check it used
    # before (pathNotExecutable) is gone.
    function Global:GateContext([string]$Series, [string[]]$Blockers, [string]$Classification = 'Blocked',
                                [bool]$PlatformManaged = $false, [bool]$NoPolicy = $false) {
        $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/g1'
            path = 'A'
            assessment = [pscustomobject]@{ classification = $Classification; blockers = @($Blockers); prepNeeded = @()
                                            platformManaged = $PlatformManaged; gen = 'V1'; sourceSize = 'Standard_NC6s_v3' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
            policy = $(if ($NoPolicy) { [pscustomobject]@{} } else { [pscustomobject]@{ targetGeneration = $Series } })
        }
        @{ Plan = $plan; SubscriptionId = '00000000-0000-0000-0000-000000000000' }
    }
}

Describe 'V5-GATE-1: the engine gate asks about the plan''s series' {

    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    }

    It 'a Generation 1 machine the scan blocked is let through on a v5 plan' {
        $ctx = GateContext -Series 'v5' -Blockers @('gen1-requires-redeploy')
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }
        $r.Next | Should -Not -Be 'SKIPPED'
        $r.Reason | Should -Be 'sizeOutOfScope'
    }

    It 'and the same machine still stops on a v6 plan' {
        $ctx = GateContext -Series 'v6' -Blockers @('gen1-requires-redeploy')
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }
        $r.Next | Should -Be 'SKIPPED'
        $r.Detail | Should -Match 'v6'
        $r.Detail | Should -Match 'gen1-requires-redeploy'
    }

    It 'and on a v7 plan' {
        $ctx = GateContext -Series 'v7' -Blockers @('gen1-requires-redeploy')
        (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }).Next |
            Should -Be 'SKIPPED'
    }

    It 'a v5-only blocker stops a v5 plan' {
        # Windows Server 2012 R2 is held on v5 (2026-09-26).
        $ctx = GateContext -Series 'v5' -Blockers @('windows-version-not-proven')
        (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }).Next |
            Should -Be 'SKIPPED'
    }

    It 'a plan with no series recorded is judged as v6, the default it was built with' {
        $ctx = GateContext -Series '' -Blockers @('gen1-requires-redeploy') -NoPolicy $true
        (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }).Next |
            Should -Be 'SKIPPED'
    }

    It 'Excluded stays excluded on every series' {
        foreach ($s in 'v5', 'v6') {
            $ctx = GateContext -Series $s -Blockers @() -Classification 'Excluded'
            (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }).Next |
                Should -Be 'SKIPPED' -Because "Excluded on $s"
        }
    }

    It 'a machine the scan found ready passes on every series' {
        foreach ($s in 'v5', 'v6', 'v7') {
            $ctx = GateContext -Series $s -Blockers @() -Classification 'ReadyAfterPrep'
            (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }).Reason |
                Should -Be 'sizeOutOfScope' -Because "ready on $s"
        }
    }
}
