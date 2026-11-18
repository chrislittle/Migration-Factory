#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-ACCEPT-1: no acceptance exists for a rebuild any more.
#
# It was decided on 2026-11-07 to remove the rebuild around the same disks
# (Path B). REBUILD-REMOVE-PLAN-1 stopped every new plan from giving it. What
# stayed were the acceptances that existed only for the rebuild: the
# identity-loss acceptance (decisions[].principalId, the wave's identityLoss,
# Get-VmfIdentityLossGate), the rebuild acceptance (the wave's rebuild, the
# decision rebuild = accept), the wave setting onSystemAssignedIdentity, and
# their stop reasons, dialogs and sign-off rows.
#
# OLD-VERSION-READERS-REMOVE-1 (2026-11-11: no installation runs an earlier
# version): the refusals of a plan an earlier version wrote with Path B - in
# the acceptance, the approval, the sign-off and PRECHECK - are gone too, with
# the service's refusals of the fields only an earlier page sent. No writer of
# this version gives path B, and the contracts no longer hold it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rra'

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$($script:subId)/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/"

    function Global:RraEntry([string]$Name = 'app-01', [string]$Path = 'A', [string]$Method = '', [string]$Wave = 'w1') {
        $target = [pscustomobject]@{ size = 'Standard_D4ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' }
        if ($Method) { $target | Add-Member -NotePropertyName choice -NotePropertyValue ([pscustomobject]@{ series = 'v6'; size = 'Standard_D4ds_v6'; method = $Method }) }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = "$($script:sub)$Name"
            wave = $Wave
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Windows'
                blockers = @(); prepNeeded = @(); platformManaged = $false
                sourceSize = 'Standard_D4ds_v4'; sourceDiskArch = 'scsi-temp'; identityType = 'SystemAssigned' }
            target = $target
            path = $Path
            policy = [pscustomobject]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true }
        }
    }
    function Global:RraRun([object[]]$Entries) {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'rra' | Out-Null }
        @{ schemaVersion = 1; assessmentRunId = 'rra'; entries = @($Entries) } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $rp 'plan.json')
        $rp
    }
    function Global:RraStored([string]$RunPath, [string]$Rel) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; rel = $Rel } { param($rp, $rel) Read-VmfStoreJson -RunPath $rp -RelPath $rel }
    }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = 't' }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\RraEntry', 'function:\RraRun', 'function:\RraStored' -ErrorAction SilentlyContinue
}

Describe 'REBUILD-REMOVE-ACCEPT-1: PRECHECK has no gate for a rebuild' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        # The first Azure call PRECHECK makes. Reaching it means the refusal did not come first.
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'reached the permissions read' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'must not stop the machine' }
    }

    It 'a Path A entry goes on to the next check' {
        $e = RraEntry -Path 'A' -Method 'preview'
        $ctx = @{ Plan = $e; SubscriptionId = $script:subId; VmId = $e.vmId; RunPath = (Join-Path $script:temp 'precheck') }
        { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepPrecheck -Context $ctx } } | Should -Throw '*reached the permissions read*'
    }

    It 'PRECHECK has no rebuild gate, no SQL or association read and no reproducibility check left' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Not -Match 'Get-VmfIdentityLossGate|Read-VmfPrecheckSqlVirtualMachine|Read-VmfPrecheckDataCollectionRuleAssociations|Test-VmfCaptureReproducible'
        $code | Should -Not -Match "Reason = 'captureNotReproducible'"
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: the acceptance, the approval and the sign-off name no rebuild' {
    It 'no command takes a list of machines whose rebuild or identity loss a person accepts' {
        foreach ($c in 'Confirm-VmfWaveOptions', 'Approve-VmfWave', 'Approve-VmfPlan') {
            (Get-Command $c).Parameters.Keys | Should -Not -Contain 'IdentityLossNamed' -Because $c
            (Get-Command $c).Parameters.Keys | Should -Not -Contain 'RebuildNamed' -Because $c
        }
    }

    It 'a wave that moves in place is accepted, and the record (v9) names no identity loss and no rebuild' {
        $rp = RraRun @((RraEntry 'app-03' 'A' 'preview'))
        $a = Confirm-VmfWaveOptions -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false
        $a.schemaVersion | Should -Be 9
        $stored = RraStored $rp (InModuleScope VmMigrationFactory { Get-VmfWaveOptionsAcceptancePath -Wave 'w1' })
        $stored.PSObject.Properties['identityLoss'] | Should -BeNullOrEmpty
        $stored.PSObject.Properties['rebuild'] | Should -BeNullOrEmpty
        ($stored | ConvertTo-Json -Depth 12) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') | Should -BeTrue
    }

    It 'a wave that moves in place is approved, and the approval (v5) names no identity loss' {
        $rp = RraRun @((RraEntry 'app-03' 'A'))
        Approve-VmfWave -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -Note 'n' -OnBehalfOf $script:who | Out-Null
        $ap = RraStored $rp 'approvals/w1.json'
        $ap.schemaVersion | Should -Be 5
        $ap.PSObject.Properties['identityLoss'] | Should -BeNullOrEmpty
        ($ap | ConvertTo-Json -Depth 8) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-approval.schema.json') | Should -BeTrue
    }

    It 'the sign-off of a plan that moves in place writes each wave approval (v5) with no identity loss' {
        $rp = RraRun @((RraEntry 'app-03' 'A' '' 'w1'), (RraEntry 'app-04' 'A' 'preview' 'w2'))
        Approve-VmfPlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Note 'n' -OnBehalfOf $script:who | Out-Null
        foreach ($w in 'w1', 'w2') {
            $ap = RraStored $rp "approvals/$w.json"
            $ap.schemaVersion | Should -Be 5
            $ap.PSObject.Properties['identityLoss'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: a decision cannot accept a rebuild or an identity loss' {
    BeforeAll {
        function Global:RraParked([string]$Reason = 'safetyCopyNotPristine') {
            $e = RraEntry 'app-01' 'A'
            $rp = RraRun @($e)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $e.vmId; why = $Reason } {
                param($rp, $id, $why)
                New-VmfStateDoc -RunPath $rp -RunId 'rra' -VmId $id -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'parked' -ReasonCode $why | Out-Null
            }
            $rp
        }
    }
    AfterAll { Remove-Item 'function:\RraParked' -ErrorAction SilentlyContinue }

    It 'Resolve-VmfDecision takes no account and no list of extensions' {
        (Get-Command Resolve-VmfDecision).Parameters.Keys | Should -Not -Contain 'IdentityLossPrincipalId'
        (Get-Command Resolve-VmfDecision).Parameters.Keys | Should -Not -Contain 'RebuildExtensions'
    }

    It 'the change <k> = <v> is refused by name, and the plan is not written' -ForEach @(
        @{ k = 'rebuild'; v = 'accept' }
        @{ k = 'onSystemAssignedIdentity'; v = 'proceed' }
    ) {
        $rp = RraParked
        $before = Get-Content (Join-Path $rp 'plan.json') -Raw
        { Resolve-VmfDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -VmId "$($script:sub)app-01" -Note 'n' `
                -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') -PolicyOverride @{ $k = $v } } |
            Should -Throw "*'$k' is not a setting the product has*"
        Get-Content (Join-Path $rp 'plan.json') -Raw | Should -Be $before
    }

    It 'no stop offers an acceptance of a rebuild or of an identity loss' {
        $levers = InModuleScope VmMigrationFactory { Get-VmfDecisionLevers }
        $levers.ContainsKey('rebuild') | Should -BeFalse
        $levers.ContainsKey('onSystemAssignedIdentity') | Should -BeFalse
        $table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json -Depth 20
        @($table.reasons | Where-Object { $_.PSObject.Properties['decide'] -and ($_.decide.PSObject.Properties['namesAccount'] -or $_.decide.PSObject.Properties['namesRebuild']) }) | Should -BeNullOrEmpty
        $table.fields.decide | Should -Not -Match 'namesAccount|namesRebuild'
    }

    It 'the stop reasons only a rebuild gave are gone: <code>' -ForEach @(
        @{ code = 'systemIdentityCannotSurvive' }, @{ code = 'rebuildNotAccepted' }, @{ code = 'captureNotReproducible' }
        @{ code = 'sqlVirtualMachineNotRead' }, @{ code = 'dataCollectionRuleAssociationsNotRead' }
        @{ code = 'rebuildNotSupported' }, @{ code = 'oldRebuildNotResumed' }, @{ code = 'pathNotExecutable' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $code } { param($c) Get-VmfStopGuidance -Code $c | Should -BeNullOrEmpty }
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: the wave setting for a system-assigned identity is gone' {
    It 'no writer takes it: not a wave setting, not a setting a decision may change' {
        InModuleScope VmMigrationFactory {
            (Get-VmfPolicyLevers).Contains('onSystemAssignedIdentity') | Should -BeFalse
            @(Get-VmfWaveSettingFields) | Should -Not -Contain 'onSystemAssignedIdentity'
        }
    }
    It 'a wave save sends it nowhere: the wave editor command and the wave settings name it no more' {
        foreach ($f in @(
                @('src', 'VmMigrationFactory', 'Public', 'Set-VmfWavePlan.ps1'),

                @('src', 'VmMigrationFactory', 'Private', 'plan', 'WaveSettings.ps1'))) {
            Get-VmfCodeOnly -Path (Join-Path $script:repoRoot @f) | Should -Not -Match 'onSystemAssignedIdentity' -Because ($f -join '/')
        }
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: the acceptance functions are gone' {
    It '<f> no longer exists' -ForEach @(
        'Get-VmfIdentityLossGate', 'Find-VmfRebuildAcceptance', 'Get-VmfRebuildGateStop', 'Write-VmfAcceptanceLineOnce',
        'Get-VmfRebuildToAccept', 'Assert-VmfRebuildNamed', 'Get-VmfRebuildExtensionsNotAccepted',
        'Get-VmfIdentityLossToAccept', 'Assert-VmfIdentityLossNamed', 'Test-VmfEntryLosesSystemIdentity', 'Get-VmfIdentityOutcome',
        'Read-VmfPrecheckSqlVirtualMachine', 'Read-VmfPrecheckDataCollectionRuleAssociations',
        'Get-VmfRebuildRefusal', 'Assert-VmfNoRebuildPlanned'
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $_ } { param($f) Get-Command $f -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: the contracts (wave-options-acceptance v9, wave-approval v5)' {
    It 'the writers write v9 and v5' {
        InModuleScope VmMigrationFactory {
            Get-VmfWaveOptionsAcceptanceSchemaVersion | Should -Be 9
            Get-VmfWaveApprovalSchemaVersion | Should -Be 5
        }
    }
    It 'the schemas allow only the new versions, and the samples are at them with no identity loss and no rebuild' {
        foreach ($s in @(@{ n = 'wave-options-acceptance'; v = 9 }, @{ n = 'wave-approval'; v = 5 })) {
            $schema = Get-Content (Join-Path $script:repoRoot 'schemas' "$($s.n).schema.json") -Raw | ConvertFrom-Json -Depth 40
            $schema.properties.schemaVersion.const | Should -Be $s.v
            $text = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' "$($s.n).sample.json") -Raw
            $sample = $text | ConvertFrom-Json -Depth 20
            $sample.schemaVersion | Should -Be $s.v
            $sample.PSObject.Properties['identityLoss'] | Should -BeNullOrEmpty
            $sample.PSObject.Properties['rebuild'] | Should -BeNullOrEmpty
            $text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' "$($s.n).schema.json") | Should -BeTrue
        }
    }
    It 'the migration note says what changed' {
        $md = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $md | Should -Match 'wave-options-acceptance v7 -> v8, wave-approval v3 -> v4 \(2026-11-07, REBUILD-REMOVE-ACCEPT-1\)'
        $md | Should -Match 'wave-options-acceptance v8 -> v9, wave-approval v4 -> v5'
    }
}

Describe 'REBUILD-REMOVE-ACCEPT-1: the service passes no acceptance of a rebuild or an identity loss' {
    It 'FacadeCore passes none of the four inputs to the engine' {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') |
            Should -Not -Match 'IdentityLossNamed|RebuildNamed|IdentityLossPrincipalId|RebuildExtensions'
    }
    It '<f> names no field of a rebuild or an identity loss' -ForEach @(
        @{ f = 'PostAcceptWaveOptions' }, @{ f = 'PostApprove' }, @{ f = 'PostApprovePlan' }, @{ f = 'PostResolve' }
    ) {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' $f 'run.ps1') |
            Should -Not -Match 'identityLossNamed|rebuildNamed|identityLossPrincipalId|rebuildExtensions'
    }
    It 'a wave save never writes the identity setting into the plan' {
        $rp = RraRun @((RraEntry 'app-03' 'A'))
        $before = Get-Content (Join-Path $rp 'plan.json') -Raw
        $doc = @{ auth_typ = 'aad'; claims = @(@{ typ = 'preferred_username'; val = 'oper@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' }) } | ConvertTo-Json -Depth 5
        $op = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        # As a changed setting it is not a setting of a wave, and the save is refused.
        { Invoke-VmfFacadeSetWaves -Principal $op -StorePath $rp -Waves @(@{ name = 'w1'; vmIds = @("$($script:sub)app-03"); changed = @{ onSystemAssignedIdentity = 'stop' } }) } |
            Should -Throw "*'onSystemAssignedIdentity' is not a setting of a wave*"
        Get-Content (Join-Path $rp 'plan.json') -Raw | Should -Be $before
        # As a field of the wave it is no setting the save reads.
        try { Invoke-VmfFacadeSetWaves -Principal $op -StorePath $rp -Waves @(@{ name = 'w1'; vmIds = @("$($script:sub)app-03"); onSystemAssignedIdentity = 'stop' }) | Out-Null } catch { }
        Get-Content (Join-Path $rp 'plan.json') -Raw | Should -Not -Match 'onSystemAssignedIdentity'
    }
}