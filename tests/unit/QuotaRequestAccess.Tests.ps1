#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# QUOTA-PREVIEW-1, designed 2026-10-25: know the access at plan time.
#
# The plan can show from the start whether the product has the access; before
# this, the request button was the first
# place a missing grant showed, and Azure refused it there. A quota belongs to
# a subscription, and an Azure role given on a resource group never reaches the
# subscription (Microsoft, "Understand scope for Azure RBAC": scope inheritance
# is downward only). So the narrow grant the manual tells a customer to prefer
# cannot request a quota.
#
# When the quota check finds a quota too low, the engine asks Azure for its OWN
# effective permissions on that subscription (Get-VmfEffectivePermissions - the
# same read the pre-move permission check makes), compares them with the quota
# actions of data/rbac-actions.json, and records the answer with the quota
# record: granted, missing, or unknown when the read failed. Unknown is never
# shown as either.
#
# THESE TESTS RUN Test-VmfQuota with Azure's answers mocked.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subA = '11111111-2222-3333-4444-555555555555'
    $script:subB = '00000000-0000-0000-0000-000000000000'
    function Global:QaSku {
        param([string]$Name, [string]$Family, [int]$Vcpus)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
        }
    }
    function Global:QaUsage {
        param([string]$Name, [int]$Used, [int]$Limit, [string]$Localized)
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $(if ($Localized) { $Localized } else { $Name }) }; CurrentValue = $Used; Limit = $Limit }
    }
    function Global:QaEntry {
        param([string]$Name, [string]$Sub, [string]$Wave = 'wave-1')
        @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
           wave = $Wave; path = 'A'
           assessment = @{ location = 'centralus'; sourceSize = 'Standard_D4s_v4'; availabilitySetId = '' }
           target = @{ size = 'Standard_D4ds_v6'; zone = $null }
           policy = @{ capacityGate = 'BestEffort' } }
    }
    function Global:QaPlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'qa'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }
    # A permission entry, as Azure's permissions list returns one.
    function Global:QaPerm { param([string[]]$Actions, [string[]]$NotActions = @()) [pscustomobject]@{ actions = @($Actions); notActions = @($NotActions) } }
}
AfterAll {
    foreach ($f in 'QaSku', 'QaUsage', 'QaEntry', 'QaPlan', 'QaPerm') { Remove-Item "function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'QUOTA-PREVIEW-1: the quota check records whether the tool may request the quota' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((QaSku 'Standard_D4s_v4' 'standardDSv4Family' 4), (QaSku 'Standard_D4ds_v6' 'standardDDSv6Family' 4)) }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        # Too low: 2 vCPUs free, the plan needs 4 or more.
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((QaUsage 'standardDDSv6Family' 8 10 'Standard DDSv6 Family vCPUs'), (QaUsage 'cores' 0 1000))
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a role that holds the quota write on the subscription is recorded as granted, asked at the subscription' {
        $script:scopes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $script:scopes.Add($Scope)
            @(QaPerm @('Microsoft.Compute/*', 'Microsoft.Quota/*'))
        }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'quota-shortfall'
        $claim.quota.requestAccess | Should -Be 'granted'
        $script:scopes | Should -Be @("/subscriptions/$($script:subA)") -Because 'a quota belongs to the subscription, so its access is asked there'
    }

    It 'a role that does not reach the subscription is recorded as missing' {
        # A grant on a resource group is not in the subscription's list at all:
        # the list Azure gives at the subscription is empty, or holds reads only.
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @(QaPerm @('*/read')) }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.quota.requestAccess | Should -Be 'missing'
    }

    It 'an empty permission list is missing, not unknown - Azure answered' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @() }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        (@((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]).quota.requestAccess | Should -Be 'missing'
    }

    It 'a NotActions that takes the quota write away is missing' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @(QaPerm @('*') @('Microsoft.Quota/*')) }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        (@((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]).quota.requestAccess | Should -Be 'missing'
    }

    It 'a read that fails is unknown, the record is still written, and its notes say so' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'Could not read effective permissions (HTTP 403)' }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.quota.requestAccess | Should -Be 'unknown'
        (@($claim.notes) -join ' | ') | Should -Match 'could not read'
        @(Get-ChildItem (Join-Path $script:rp 'capacity') -Filter '*.json').Count | Should -Be 1
    }

    It 'asks once per subscription, and keeps two subscriptions apart' {
        $script:scopes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $script:scopes.Add($Scope)
            if ($Scope -like "*$($script:subA)") { @(QaPerm @('Microsoft.Quota/*')) } else { @() }
        }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA), (QaEntry 'b' $script:subA -Wave 'wave-2'), (QaEntry 'c' $script:subB))
        $claims = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)
        $script:scopes.Count | Should -Be 2 -Because 'one read per subscription, not per record'
        @($claims | Where-Object subscriptionId -eq $script:subA | ForEach-Object { $_.quota.requestAccess } | Sort-Object -Unique) | Should -Be @('granted')
        @($claims | Where-Object subscriptionId -eq $script:subB)[0].quota.requestAccess | Should -Be 'missing'
    }

    It 'asks nothing when every quota fits, and records no access' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((QaUsage 'standardDDSv6Family' 0 100), (QaUsage 'cores' 0 1000)) }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'must not be asked' }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.state | Should -Be 'QUOTA_VERIFIED'
        $claim.quota.requestAccess | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }

    It 'records Azure''s own name for the quota, from the usage list' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @() }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.quota.name | Should -Be 'Standard DDSv6 Family vCPUs'
    }

    It 'the record on disk, with the new fields, validates against its schema' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @() }
        $plan = QaPlan $script:rp @((QaEntry 'a' $script:subA))
        Test-VmfQuota -PlanPath $plan -OutPath $script:rp | Out-Null
        $file = Get-ChildItem (Join-Path $script:rp 'capacity') -Filter '*.json' | Select-Object -First 1
        $json = Get-Content $file.FullName -Raw
        ($json | ConvertFrom-Json).schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfCapacityClaimSchemaVersion }) -Because 'the fields came in v12, and the record is written at the version the writer declares'
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') | Should -BeTrue
    }
}

Describe 'QUOTA-PREVIEW-1: the quota actions come from the permission map' {
    It 'the actions asked about are the Microsoft.Quota actions rbac-actions.json gives the execute role' {
        $actions = InModuleScope VmMigrationFactory { Get-VmfQuotaRequestActions }
        $actions | Should -Contain 'Microsoft.Quota/quotas/write'
        @($actions | Where-Object { $_ -notlike 'Microsoft.Quota/*' }).Count | Should -Be 0
    }

    It 'a role with the quota actions is granted; one with reads only is missing' {
        InModuleScope VmMigrationFactory {
            Get-VmfQuotaRequestAccess -Permissions @([pscustomobject]@{ actions = @('Microsoft.Quota/quotas/write', 'Microsoft.Quota/quotas/read'); notActions = @() }) | Should -Be 'granted'
            Get-VmfQuotaRequestAccess -Permissions @([pscustomobject]@{ actions = @('*'); notActions = @() }) | Should -Be 'granted'
            Get-VmfQuotaRequestAccess -Permissions @([pscustomobject]@{ actions = @('Microsoft.Quota/quotas/read'); notActions = @() }) | Should -Be 'missing'
            Get-VmfQuotaRequestAccess -Permissions @() | Should -Be 'missing'
        }
    }
}
