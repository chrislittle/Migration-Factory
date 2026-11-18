#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REGIONAL-QUOTA-REQUEST-1, 2026-11-02.
#
# REGIONAL-VCPU-QUOTA-1 made the quota check block a record whose machines add
# more vCPUs than the subscription's Total Regional vCPUs quota has free
# (blockReason 'regional-quota-shortfall'). Request an increase acted only on
# 'quota-shortfall', so the operator was sent to the Quotas page of the Azure
# portal - an action outside the app (hard rule 12).
#
# Now Request-VmfQuota files ONE regional request per subscription and region,
# through the same Microsoft.Quota PUT as a family request
# (Request-VmfQuotaIncrease), with the resource name 'cores'. PROBED 2026-11-02
# (read only, the lab subscription, centralus):
# GET .../providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/quotas/cores
# returned name 'cores', localizedValue 'Total Regional vCPUs',
# isQuotaApplicable true, limitType Independent.
#
# The new limit is the regional usage plus the vCPUs the whole plan adds in the
# region (demand.regionalVcpus, the number the check judged) plus the headroom
# asked for - and never below the present limit, for either kind of request.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subA = '00000000-0000-0000-0000-000000000000'
    $script:subB = '11111111-1111-1111-1111-111111111111'

    # A record as Test-VmfQuota writes it, through the module's own builder.
    function Global:RrClaim {
        param([string]$RunPath, [string]$File, [string]$Reason = 'regional-quota-shortfall', [string]$Wave = 'wave-1',
              [string]$Sub = '00000000-0000-0000-0000-000000000000', [string]$Region = 'centralus',
              [string]$Size = 'Standard_D4s_v6', [string]$Family = 'standardDSv6Family', [int]$Vcpus = 4,
              $QuotaLimit = 100, $QuotaUsed = 0, $FamilyVcpus = $null,
              $RegionalVcpus = 6, $RegionalLimit = 10, $RegionalUsed = 8, [string]$Access = $null,
              [string]$CheckedUtc = '2026-11-02T10:00:00.0000000Z', [string]$State = 'BLOCKED')
        InModuleScope VmMigrationFactory -Parameters @{ a = $PSBoundParameters; d = @{
                Reason = $Reason; Wave = $Wave; Sub = $Sub; Region = $Region; Size = $Size; Family = $Family; Vcpus = $Vcpus
                QuotaLimit = $QuotaLimit; QuotaUsed = $QuotaUsed; FamilyVcpus = $FamilyVcpus; RegionalVcpus = $RegionalVcpus
                RegionalLimit = $RegionalLimit; RegionalUsed = $RegionalUsed; Access = $Access; CheckedUtc = $CheckedUtc
                State = $State; RunPath = $RunPath; File = $File } } {
            param($a, $d)
            Initialize-VmfStore -RunPath $d.RunPath
            $claim = New-VmfCapacityClaim -RunId 'r1' -Wave $d.Wave -SubscriptionId $d.Sub -ResourceGroup 'rg-app' `
                -Region $d.Region -Size $d.Size -VmFamily $d.Family -State $d.State `
                -BlockReason $(if ($d.State -eq 'BLOCKED') { $d.Reason } else { $null }) `
                -Instances 1 -ReservableInstances 1 -Vcpus $d.Vcpus -FamilyVcpus $d.FamilyVcpus `
                -QuotaLimit $d.QuotaLimit -QuotaUsed $d.QuotaUsed -RegionalVcpus $d.RegionalVcpus `
                -RegionalLimit $d.RegionalLimit -RegionalUsed $d.RegionalUsed -RequestAccess $d.Access -CheckedUtc $d.CheckedUtc
            Write-VmfStoreJson -RunPath $d.RunPath -RelPath "capacity/$($d.File).json" -Document $claim -Depth 12
        }
    }
    function Global:RrRead {
        param([string]$RunPath, [string]$File)
        Get-Content (Join-Path $RunPath 'capacity' "$File.json") -Raw | ConvertFrom-Json -Depth 12
    }
    function Global:RrEvents {
        param([string]$RunPath)
        $log = Join-Path $RunPath 'logs' 'events.jsonl'
        if (-not (Test-Path $log)) { return @() }
        @(Get-Content $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 12 })
    }
}
AfterAll {
    foreach ($f in 'RrClaim', 'RrRead', 'RrEvents') { Remove-Item "function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'REGIONAL-QUOTA-REQUEST-1: Request an increase asks for the Total Regional vCPUs quota' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        $script:asked = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            $script:asked.Add([pscustomobject]@{ SubscriptionId = $SubscriptionId; Location = $Location; Family = $Family; NewLimit = $NewLimit })
            [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/r-1"}' }
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: a regional shortfall files ONE request for the quota Azure names cores, sized from the regional figures' {
        RrClaim $script:rp 'c1' -RegionalVcpus 6 -RegionalLimit 10 -RegionalUsed 8
        $r = Request-VmfQuota -OutPath $script:rp -HeadroomVcpus 2
        $script:asked.Count | Should -Be 1
        $script:asked[0].Family | Should -Be 'cores' -Because 'the Microsoft.Quota resource name of Total Regional vCPUs, probed 2026-11-02'
        $script:asked[0].SubscriptionId | Should -Be $script:subA
        $script:asked[0].Location | Should -Be 'centralus'
        $script:asked[0].NewLimit | Should -Be 16 -Because 'regional usage 8 + the 6 the plan adds + headroom 2'
        @($r.Submitted).Count | Should -Be 1
        @($r.Submitted)[0].Kind | Should -Be 'regional'
        @($r.Submitted)[0].QuotaName | Should -Be 'Total Regional vCPUs' -Because 'Azure''s own name, as the usage list and the Quotas page give it'
    }

    It 'never asks the FAMILY for a regional shortfall - its family fits' {
        RrClaim $script:rp 'c1' -QuotaLimit 100 -QuotaUsed 0
        Request-VmfQuota -OutPath $script:rp | Out-Null
        @($script:asked | Where-Object Family -ne 'cores').Count | Should -Be 0
    }

    It 'records of one subscription and region are ONE request, for the plan''s whole regional ask' {
        RrClaim $script:rp 'c1' -Wave 'wave-1' -Size 'Standard_D4s_v6' -RegionalVcpus 12 -RegionalUsed 8 -RegionalLimit 10
        RrClaim $script:rp 'c2' -Wave 'wave-2' -Size 'Standard_E4s_v6' -Family 'standardESv6Family' -RegionalVcpus 12 -RegionalUsed 8 -RegionalLimit 10
        $r = Request-VmfQuota -OutPath $script:rp
        $script:asked.Count | Should -Be 1 -Because 'one quota is one request; a second would write over the first'
        $script:asked[0].NewLimit | Should -Be 20 -Because 'usage 8 + 12, the regional ask of the whole plan, once - not 12 per record'
        foreach ($f in 'c1', 'c2') {
            $claim = RrRead $script:rp $f
            $claim.state | Should -Be 'QUOTA_REQUESTED' -Because "$f is a record of the quota that was requested"
            $claim.quota.requestId | Should -Be '/quota-requests/r-1'
        }
        @($r.All).Count | Should -Be 1
    }

    It 'the newest check gives the usage and the ask' {
        RrClaim $script:rp 'old' -Wave 'wave-1' -RegionalVcpus 30 -RegionalUsed 2 -CheckedUtc '2026-11-01T10:00:00.0000000Z'
        RrClaim $script:rp 'new' -Wave 'wave-2' -Size 'Standard_E4s_v6' -RegionalVcpus 6 -RegionalUsed 8 -CheckedUtc '2026-11-02T10:00:00.0000000Z'
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $script:asked[0].NewLimit | Should -Be 14 -Because 'the newest reading: usage 8 + 6'
    }

    It 'another region and another subscription each get their own request' {
        RrClaim $script:rp 'a' -Region 'centralus'
        RrClaim $script:rp 'b' -Region 'eastus2'
        RrClaim $script:rp 'c' -Sub $script:subB
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $script:asked.Count | Should -Be 3
        @($script:asked | ForEach-Object { "$($_.SubscriptionId)|$($_.Location)" } | Sort-Object) |
            Should -Be @("$($script:subA)|centralus", "$($script:subA)|eastus2", "$($script:subB)|centralus")
        @($script:asked | Where-Object Family -ne 'cores').Count | Should -Be 0
    }

    It 'a family shortfall still files its family request, beside the regional one' {
        RrClaim $script:rp 'fam' -Reason 'quota-shortfall' -Region 'eastus2' -Family 'standardDDSv6Family' -Size 'Standard_D4ds_v6' `
            -QuotaLimit 10 -QuotaUsed 8 -FamilyVcpus 4
        RrClaim $script:rp 'reg' -Region 'centralus'
        $r = Request-VmfQuota -OutPath $script:rp
        $script:asked.Count | Should -Be 2
        $fam = @($script:asked | Where-Object Family -eq 'standardDDSv6Family')
        $fam.Count | Should -Be 1
        $fam[0].Location | Should -Be 'eastus2'
        $fam[0].NewLimit | Should -Be 12 -Because 'family usage 8 + the family''s 4'
        @($script:asked | Where-Object Family -eq 'cores').Count | Should -Be 1
        @($r.All | ForEach-Object Kind | Sort-Object) | Should -Be @('family', 'regional')
    }

    It 'a regional request never asks for a limit below the present one' {
        # A reading where the region was short when judged, and the record's
        # figures put the usage and the ask below the limit now on file: the
        # request must never LOWER a quota.
        RrClaim $script:rp 'c1' -RegionalVcpus 2 -RegionalUsed 3 -RegionalLimit 10
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $script:asked[0].NewLimit | Should -Be 10
    }

    It 'a family request never asks for a limit below the present one either' {
        RrClaim $script:rp 'c1' -Reason 'quota-shortfall' -QuotaLimit 40 -QuotaUsed 10 -FamilyVcpus 4
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $script:asked[0].Family | Should -Be 'standardDSv6Family'
        $script:asked[0].NewLimit | Should -Be 40
    }

    It 'a record with no regional reading is not asked for, and the activity log says why' {
        RrClaim $script:rp 'c1' -RegionalLimit $null -RegionalUsed $null
        $r = Request-VmfQuota -OutPath $script:rp
        $script:asked.Count | Should -Be 0
        @($r.Failed).Count | Should -Be 1
        @($r.Failed)[0].Status | Should -Be 'FAILED'
        $line = @(RrEvents $script:rp | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'fail' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Match 'Total Regional vCPUs'
        $line[0].detail | Should -Match 'Check the quota'
        (RrRead $script:rp 'c1').state | Should -Be 'BLOCKED'
    }

    It 'with no access recorded on the subscription, nothing is asked and the row says NOACCESS' {
        RrClaim $script:rp 'c1' -Access 'missing'
        $r = Request-VmfQuota -OutPath $script:rp
        $script:asked.Count | Should -Be 0
        @($r.All)[0].Status | Should -Be 'NOACCESS'
        (RrRead $script:rp 'c1').state | Should -Be 'BLOCKED'
    }

    It 'an answer Azure refuses leaves the records blocked and says what Azure said' {
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 400; Content = 'refused' } }
        RrClaim $script:rp 'c1'
        $r = Request-VmfQuota -OutPath $script:rp
        @($r.Failed).Count | Should -Be 1
        (RrRead $script:rp 'c1').state | Should -Be 'BLOCKED'
        $line = @(RrEvents $script:rp | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'fail' })
        # MANUAL-REVIEW-1: the Azure name of the quota, and its region, in a sentence.
        $line[0].detail | Should -Match '^Total Regional vCPUs in centralus: '
        $line[0].detail | Should -Match 'refused'
        $line[0].detail | Should -Not -Match 'quota='
    }

    It 'an approved request writes an ok line that names the quota and the region' {
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        RrClaim $script:rp 'c1'
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $line = @(RrEvents $script:rp | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'ok' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Match '^quota=cores region=centralus newLimit=14 status=APPROVED$'
    }

    It 'the preview has one row for the regional quota, in Azure''s columns, and files nothing' {
        RrClaim $script:rp 'c1' -RegionalVcpus 6 -RegionalLimit 10 -RegionalUsed 8
        RrClaim $script:rp 'c2' -Reason 'quota-shortfall' -Region 'eastus2' -QuotaLimit 10 -QuotaUsed 8 -FamilyVcpus 4
        Request-VmfQuota -OutPath $script:rp -WhatIfOnly | Out-Null
        $script:asked.Count | Should -Be 0
        $preview = @(RrEvents $script:rp | Where-Object step -eq 'quotaPreview')
        $preview.Count | Should -Be 1
        $rows = @($preview[0].requests)
        $rows.Count | Should -Be 2
        $regional = @($rows | Where-Object kind -eq 'regional')
        $regional.Count | Should -Be 1
        $regional[0].family | Should -Be 'cores'
        $regional[0].quotaName | Should -Be 'Total Regional vCPUs'
        $regional[0].region | Should -Be 'centralus'
        $regional[0].usage | Should -Be 8
        $regional[0].currentLimit | Should -Be 10
        $regional[0].requestedLimit | Should -Be 14
        $regional[0].free | Should -Be 2
        $regional[0].status | Should -Be 'WHATIF'
        @($rows | Where-Object kind -eq 'family').Count | Should -Be 1
    }
}

Describe 'REGIONAL-QUOTA-REQUEST-1: the quota check records the access for a regional shortfall too' {
    BeforeAll {
        function Global:RrSku {
            param([string]$Name, [string]$Family, [int]$Vcpus)
            [pscustomobject]@{
                Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
                Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" },
                                 [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
            }
        }
        function Global:RrUsage {
            param([string]$Name, [int]$Used, [int]$Limit)
            [pscustomobject]@{ Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $Name }; CurrentValue = $Used; Limit = $Limit }
        }
    }
    AfterAll { foreach ($f in 'RrSku', 'RrUsage') { Remove-Item "function:\$f" -ErrorAction SilentlyContinue } }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((RrSku 'Standard_D2s_v4' 'standardDSv4Family' 2), (RrSku 'Standard_D8s_v6' 'standardDSv6Family' 8)) }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        $planPath = Join-Path $script:rp 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'rr'; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = "/subscriptions/$($script:subA)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/a"
            wave = 'wave-1'; path = 'A'
            assessment = @{ location = 'centralus'; sourceSize = 'Standard_D2s_v4'; availabilitySetId = '' }
            target = @{ size = 'Standard_D8s_v6'; zone = $null }
            policy = @{ capacityGate = 'BestEffort' } }) } | ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $script:plan = $planPath
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a record blocked on the regional quota carries quota.requestAccess, asked at the subscription' {
        $script:scopes = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RrUsage 'standardDSv6Family' 0 100), (RrUsage 'cores' 8 10)) }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $script:scopes.Add($Scope)
            @([pscustomobject]@{ Actions = @('*/read'); NotActions = @() })
        }
        $claim = @((Test-VmfQuota -PlanPath $script:plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'regional-quota-shortfall'
        $claim.quota.requestAccess | Should -Be 'missing'
        $script:scopes | Should -Be @("/subscriptions/$($script:subA)")
        $json = Get-Content (Get-ChildItem (Join-Path $script:rp 'capacity') -Filter '*.json' | Select-Object -First 1).FullName -Raw
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') | Should -BeTrue
    }

    It 'a record that fits is not asked about' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RrUsage 'standardDSv6Family' 0 100), (RrUsage 'cores' 0 100)) }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'must not be asked' }
        $claim = @((Test-VmfQuota -PlanPath $script:plan -OutPath $script:rp).Claims)[0]
        $claim.state | Should -Be 'QUOTA_VERIFIED'
        $null -eq $claim.quota.requestAccess | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }
}
