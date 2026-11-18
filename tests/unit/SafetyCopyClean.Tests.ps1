#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETYCOPY-CLEAN-1 (decided 2026-10-04): a plan entry that does not
# ask for the first safety copy is REFUSED, never run without it.
#
# The planner has written `safetyCopy: pristine` on every entry since WAVE-2,
# and the wave editor shows the copy as "Always taken". But plan-entry still
# accepts `clean`, and SAFETY_PRISTINE skipped the copy for it - so a plan
# written by hand could run with no way back, and every rollback uses that
# copy. The value stays readable in the contract until the next plan-entry
# change removes it (old plans stay readable); until then every reader treats
# anything other than pristine as a refusal.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:CleanEntry {
        param([AllowNull()]$Copy = 'clean', [switch]$NoValue, [string]$Name = 'cleanvm')
        $policy = if ($NoValue) { [pscustomobject]@{ capacityGate = 'BestEffort' } }
                  else { [pscustomobject]@{ safetyCopy = $Copy; capacityGate = 'BestEffort' } }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = 'w1'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                                            blockers = @(); prepNeeded = @(); platformManaged = $false
                                            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = $policy
        }
    }
}
AfterAll { Remove-Item 'function:\CleanEntry' -ErrorAction SilentlyContinue }

# MANUAL-REVIEW-1: the refusal is the one guard for a value the contract does
# not list (Get-VmfPlanPolicyRefusal, policyNotKnown). Its own refusal and
# stop reason (safetyCopyNotPristine) are gone: one guard, not two.
Describe 'SAFETYCOPY-CLEAN-1: one rule says which safety copy setting the engine accepts' {
    It 'pristine is accepted' {
        InModuleScope VmMigrationFactory {
            Get-VmfPlanPolicyRefusal -PlanEntry (Global:CleanEntry -Copy 'pristine') | Should -BeNullOrEmpty
        }
    }

    It 'no value at all is the default, which is pristine' {
        InModuleScope VmMigrationFactory {
            Get-VmfPlanPolicyRefusal -PlanEntry (Global:CleanEntry -NoValue) | Should -BeNullOrEmpty
            Get-VmfPlanPolicyRefusal -PlanEntry (Global:CleanEntry -Copy $null) | Should -BeNullOrEmpty
        }
    }

    It 'clean is refused, and the refusal names the value it found' {
        InModuleScope VmMigrationFactory {
            $why = Get-VmfPlanPolicyRefusal -PlanEntry (Global:CleanEntry -Copy 'clean')
            $why | Should -Not -BeNullOrEmpty
            $why | Should -Match "'safetyCopy' to 'clean'"
        }
    }

    It 'anything else is refused too - never read as "skip the copy"' {
        InModuleScope VmMigrationFactory {
            foreach ($v in '', 'none', 'off', 'prepared', 'Pristine') {
                Get-VmfPlanPolicyRefusal -PlanEntry (Global:CleanEntry -Copy $v) |
                    Should -Not -BeNullOrEmpty -Because "'$v' is not the first copy"
            }
        }
    }
}

Describe 'SAFETYCOPY-CLEAN-1: PRECHECK refuses the entry before anything touches the machine' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        # The first Azure call PRECHECK makes. Reaching it means the refusal
        # did not come first.
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'reached the permissions read' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'must not stop the machine' }
    }

    It 'clean stops the machine with policyNotKnown, untouched' {
        $ctx = @{ Plan = (CleanEntry -Copy 'clean'); SubscriptionId = $script:sub; VmId = (CleanEntry).vmId; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-scc-precheck') }
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'policyNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'clean'"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
    }

    It 'pristine, and no value, go on to the next check' {
        foreach ($entry in @((CleanEntry -Copy 'pristine'), (CleanEntry -NoValue))) {
            $ctx = @{ Plan = $entry; SubscriptionId = $script:sub; VmId = $entry.vmId; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-scc-precheck') }
            { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { Invoke-VmfStepPrecheck -Context $ctx } } |
                Should -Throw '*reached the permissions read*'
        }
    }

    It 'the whole state machine records the stop as untouched, with the reason' {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Initialize-VmfRun -RunPath $rp -RunId 'scc-test' | Out-Null
                $doc = Invoke-VmfStateMachine -PlanEntry (Global:CleanEntry -Copy 'clean') -RunPath $rp -RunId 'scc-test'
                $doc.state | Should -Be 'NEEDS_DECISION'
                $last = @($doc.history)[-1]
                $last.reasonCode | Should -Be 'policyNotKnown'
                $last.machineState | Should -Be 'untouched'
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
    }

    It 'the stop has guidance an operator can act on, says nothing was changed, and offers no retry' {
        InModuleScope VmMigrationFactory {
            Get-VmfStopGuidance -Code 'safetyCopyNotPristine' | Should -BeNullOrEmpty
            $g = Get-VmfStopGuidance -Code 'policyNotKnown'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.whatToDo | Should -Match '(?i)plan'
            # A retry re-reads the same plan entry and stops again, so the run
            # page must not offer one (review finding 1).
            $g.retry | Should -Be 'notSupported'
        }
    }
}
# The copy step itself - that a `clean` entry reaching SAFETY_PRISTINE still
# gets its copy - is SafetyCopy.Tests.ps1 'never skips the copy, even when a
# plan says clean'. One test of it, not two.

Describe 'SAFETYCOPY-CLEAN-1: a person cannot accept or decide their way to no copy' {
    It 'a decision cannot set the safety copy to clean' {
        InModuleScope VmMigrationFactory {
            $r = Test-VmfPolicyOverride -Override @{ safetyCopy = 'clean' }
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'pristine'
            (Test-VmfPolicyOverride -Override @{ safetyCopy = 'pristine' }).Ok | Should -BeTrue
        }
    }

    It 'a wave holding such an entry cannot be accepted, and nothing is written' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $plan = [pscustomobject]@{ schemaVersion = 5; assessmentRunId = 'scan-1'
                                       entries = @((CleanEntry -Copy 'pristine' -Name 'okvm'), (CleanEntry -Copy 'clean' -Name 'cleanvm')) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $plan } {
                Initialize-VmfRun -RunPath $rp -RunId 'scc-test' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
                $planPath = Join-Path $rp 'plan.json'
                { Confirm-VmfWaveOptions -RunPath $rp -PlanPath $planPath -Wave 'w1' -AcceptedBy 'operator@example.com' } |
                    Should -Throw '*cleanvm*'
                Read-VmfStoreJson -RunPath $rp -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave 'w1') | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the same wave with every entry on pristine is accepted' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $plan = [pscustomobject]@{ schemaVersion = 5; assessmentRunId = 'scan-1'
                                       entries = @((CleanEntry -Copy 'pristine' -Name 'okvm'), (CleanEntry -NoValue -Name 'defaultvm')) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $plan } {
                Initialize-VmfRun -RunPath $rp -RunId 'scc-test' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
                $planPath = Join-Path $rp 'plan.json'
                (Confirm-VmfWaveOptions -RunPath $rp -PlanPath $planPath -Wave 'w1' -AcceptedBy 'operator@example.com').machineCount |
                    Should -Be 2
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'SAFETYCOPY-CLEAN-1: the contract keeps the old value only until its next change' {
    # The ruling: do not bump plan-entry for this alone. Old plans stay
    # readable, and the next plan-entry change removes `clean` and the unread
    # `assessment.osDiskData`. This fails on THAT change if either is left in,
    # so the record in the work item cannot be forgotten.
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'a plan-entry version after 18 no longer offers clean' {
        if ([int]$script:schema.properties.schemaVersion.const -le 18) {
            @($script:schema.properties.policy.properties.safetyCopy.enum) | Should -Contain 'clean' -Because 'v18 plans stay readable'
        }
        else {
            @($script:schema.properties.policy.properties.safetyCopy.enum) | Should -Not -Contain 'clean'
        }
    }

    It 'a plan-entry version after 18 no longer carries osDiskData, which nothing reads' {
        if ([int]$script:schema.properties.schemaVersion.const -le 18) {
            $script:schema.properties.assessment.properties.Contains('osDiskData') | Should -BeTrue
        }
        else {
            $script:schema.properties.assessment.properties.Contains('osDiskData') | Should -BeFalse
        }
    }

    It 'nothing in the module reads osDiskData' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter *.ps1
        $readers = @($files | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'osDiskData' } | ForEach-Object Name)
        $readers -join ', ' | Should -BeNullOrEmpty
    }
}
