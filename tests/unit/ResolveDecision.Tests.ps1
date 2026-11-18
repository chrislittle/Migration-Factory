#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # TEMP-LITTER-1: same as Orchestrator.Tests.ps1 - the run folder was taken
    # away and the claim folder beside it was not.
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'dec'
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
}

AfterAll {
    Remove-VmfTestTemp
}

# EVAL-H12: these fixtures used to pass 'onIacManaged' - a lever IAC-2 deleted
# and nothing reads. Three tests asserted it was written into the plan, so the
# suite certified the defect (any key accepted, unvalidated) as the
# specification. They now use a lever that exists; refusing an unknown one is
# covered in RetryHygiene.Tests.ps1.
Describe 'Resolve-VmfDecision (REH-2: NEEDS_DECISION is a workflow, not a dead end)' {
    BeforeEach {
        $script:runPath = Join-Path $script:temp "dec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/tf-vm'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'dec-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'dec-test' -VmId $vm -Wave 'prod-1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok `
                -Detail 'IaC-managed VM (Terraform): acknowledge the reconciliation workflow' | Out-Null
        }
        $script:planPath = Join-Path $script:runPath 'plan.json'
        @{
            schemaVersion = 1; assessmentRunId = 'dec-test'
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'prod-1'; ring = 'prod'
                   assessment = @{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                                   sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; iacManaged = $true }
                   target = @{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                   path = 'A'; policy = @{ onDDataFound = 'stop' } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/other'; wave = 'prod-1'; ring = 'prod'
                   assessment = @{ }; target = @{ size = 'Standard_D2s_v6' }; path = 'A'
                   policy = @{ onDDataFound = 'stop' } }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content $script:planPath
        # RETRY-GATE-1: a retry is refused while the wave cannot start.
        Open-VmfTestWaveGate -RunPath $script:runPath -PlanPath $script:planPath
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'applies the policy override to ONLY the target plan entry and re-arms the VM' {
        # WAVE-APPROVE-1 (rule, 2026-10-10): rewritten. This pinned
        # a decision from PowerShell re-arming the machine at once under the
        # plan sign-off. A call with no roles is never an approver's, so the
        # change is saved, the machine is not re-armed, and the wave asks
        # again for its approval. An approver approves it; the retry re-arms.
        { Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -PolicyOverride @{ onDDataFound = 'proceed' } -Note 'reconciliation workflow acknowledged' -ResolvedBy 'operator' } |
            Should -Throw '400:*wave prod-1 cannot start now*Nobody approved wave prod-1*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).state | Should -Be 'NEEDS_DECISION'
        }

        $plan = Get-Content $script:planPath -Raw | ConvertFrom-Json -Depth 10
        ($plan.entries | Where-Object vmId -EQ $script:vmId).policy.onDDataFound | Should -Be 'proceed'
        ($plan.entries | Where-Object vmId -EQ '/s/rg/vm/other').policy.onDDataFound | Should -Be 'stop' `
            -Because 'a resolution is per-VM, never a blanket policy change'

        Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' -Note 'read the change' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
        $r = Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -Note 'reconciliation workflow acknowledged' -ResolvedBy 'operator'
        $r.NewState | Should -Be 'PRECHECK'

        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.state | Should -Be 'PRECHECK'
            $last = @($doc.history)[-1]
            $last.detail | Should -Match 'operator'
            $last.detail | Should -Match 'reconciliation workflow acknowledged'
        }
    }

    It 'refuses to resolve a VM that is not waiting for a person' {
        # RETRY-1 widened what may be retried (FAILED_ROLLED_BACK joined the
        # list) and renamed the refusal accordingly - a migrated machine still
        # has nothing to retry.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
        }
        { Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -Note 'x' } | Should -Throw '*not waiting for a person*'
    }

    It 'throws when a parked VM has no plan entry' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            New-VmfStateDoc -RunPath $rp -RunId 'dec-test' -VmId '/s/rg/vm/ghost' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/ghost' -NewState 'NEEDS_DECISION' -Outcome ok | Out-Null
        }
        { Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId '/s/rg/vm/ghost' `
            -Note 'x' } | Should -Throw '*no plan entry*'
    }

    It 'resolves a FAILED_NEEDS_ATTENTION hold back to VALIDATING after remediation (REH-2)' {
        # A validation hold does not need a full re-conversion: after the
        # operator remediates (or the validation logic is fixed), the VM
        # re-enters at VALIDATING - which never mutates, so it is always safe.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'PRECHECK' -Outcome ok | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail `
                -Detail 'VALIDATING failed (policy=hold): fabric mismatch' | Out-Null
        }
        $r = Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -ReturnTo 'VALIDATING' -Note 'validation logic fixed - fabric-aware now' -ResolvedBy 'operator'
        $r.NewState | Should -Be 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).state | Should -Be 'VALIDATING'
        }
    }

    It 'refuses -ReturnTo VALIDATING for a NEEDS_DECISION park (must re-verify from PRECHECK)' {
        { Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -ReturnTo 'VALIDATING' -Note 'x' } | Should -Throw '*PRECHECK*'
    }

    It 'a resolved VM is leasable again by the wave orchestrator' {
        # WAVE-APPROVE-1: the decision asks again for the wave's approval (see
        # above), so the machine is leasable once the wave is approved again
        # and the machine is tried again - and not before.
        { Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId `
            -PolicyOverride @{ onDDataFound = 'proceed' } -Note 'ack' } | Should -Throw '400:*cannot start now*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).state | Should -Be 'NEEDS_DECISION' -Because 'a machine still waiting for a person is not leased'
        }
        Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' -Note 'read the change' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
        Resolve-VmfDecision -RunPath $script:runPath -PlanPath $script:planPath -VmId $script:vmId -Note 'ack' | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath; vm = $script:vmId } {
            $plan = Get-Content $pp -Raw | ConvertFrom-Json -Depth 10
            $claim = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'prod-1' -WorkerId 'w1'
            $claim | Should -Not -BeNullOrEmpty
            $claim.Entry.vmId | Should -Be $vm -Because 'the resolved VM must re-enter the wave'
        }
    }
}
