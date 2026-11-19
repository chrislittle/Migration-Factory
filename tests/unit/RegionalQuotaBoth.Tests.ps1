#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REGIONAL-QUOTA-BOTH-1 and REGIONAL-QUOTA-WAVES-1, 2026-11-06.
#
# A record whose size family is short keeps blockReason 'quota-shortfall', also
# when the subscription's Total Regional vCPUs quota is short too. Request an
# increase asked only for the family, and only the check after Azure granted it
# blocked the record on the region - so the wave waited for two requests, one
# after the other, each of which can take days.
#
# Now the quota check records, on every record it judges against the region,
# whether THAT record's machines are short of the region (regionalShort) and
# what they add to it (demand.regionalAdds). Request-VmfQuota files the
# regional request beside the family request in the same press, and the
# confirmation gives the regional row a line for each wave, from the vCPUs that
# wave's records add (REGIONAL-QUOTA-WAVES-1, folded in: it needs the same field).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schema = Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json'

    function Global:RbSku {
        param([string]$Name, [string]$Family, [int]$Vcpus)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
        }
    }
    function Global:RbCatalog {
        @((RbSku 'Standard_D2s_v4' 'standardDSv4Family' 2),
          (RbSku 'Standard_D4s_v4' 'standardDSv4Family' 4),
          (RbSku 'Standard_D2s_v6' 'standardDSv6Family' 2),
          (RbSku 'Standard_D4s_v6' 'standardDSv6Family' 4),
          (RbSku 'Standard_D8s_v6' 'standardDSv6Family' 8))
    }
    function Global:RbUsage {
        param([string]$Name, [int]$Used, [int]$Limit)
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $Name }; CurrentValue = $Used; Limit = $Limit }
    }
    function Global:RbEntry {
        param([string]$Name, [string]$Source, [string]$Target, [string]$Wave = 'wave-1')
        @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
           wave = $Wave; path = 'A'
           assessment = @{ location = 'centralus'; sourceSize = $Source; availabilitySetId = '' }
           target = @{ size = $Target; zone = $null }
           policy = @{ capacityGate = 'BestEffort' } }
    }
    function Global:RbPlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'rb'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }
    function Global:RbByWave { param($Result, [string]$Wave) @($Result.Claims | Where-Object { $_.wave -eq $Wave })[0] }

    # A record as Test-VmfQuota writes it, through the module's own builder, with
    # the two v14 fields added by hand - so a test of Request-VmfQuota fails on
    # what it does, not on a builder parameter. The sentinel is on the LEFT: a
    # bool on the left turns 'absent' into $true.
    function Global:RbClaim {
        param([string]$RunPath, [string]$File, [string]$Reason = 'quota-shortfall', [string]$Wave = 'wave-1',
              [string]$Size = 'Standard_D4s_v6', [string]$Family = 'standardDSv6Family', [int]$Vcpus = 4,
              $QuotaLimit = 10, $QuotaUsed = 8, $FamilyVcpus = 4,
              $RegionalVcpus = 6, $RegionalLimit = 10, $RegionalUsed = 8,
              $RegionalAdds = 'absent', $RegionalShort = 'absent', [string]$Access = 'granted')
        InModuleScope VmMigrationFactory -Parameters @{ d = @{
                Reason = $Reason; Wave = $Wave; Size = $Size; Family = $Family; Vcpus = $Vcpus
                QuotaLimit = $QuotaLimit; QuotaUsed = $QuotaUsed; FamilyVcpus = $FamilyVcpus; RegionalVcpus = $RegionalVcpus
                RegionalLimit = $RegionalLimit; RegionalUsed = $RegionalUsed; Access = $Access
                RunPath = $RunPath; File = $File; RegionalAdds = $RegionalAdds; RegionalShort = $RegionalShort } } {
            param($d)
            Initialize-VmfStore -RunPath $d.RunPath
            $claim = New-VmfCapacityClaim -RunId 'r1' -Wave $d.Wave -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-app' `
                -Region 'centralus' -Size $d.Size -VmFamily $d.Family -State 'BLOCKED' -BlockReason $d.Reason `
                -Instances 1 -ReservableInstances 1 -Vcpus $d.Vcpus -FamilyVcpus $d.FamilyVcpus `
                -QuotaLimit $d.QuotaLimit -QuotaUsed $d.QuotaUsed -RegionalVcpus $d.RegionalVcpus `
                -RegionalLimit $d.RegionalLimit -RegionalUsed $d.RegionalUsed -RequestAccess $d.Access -CheckedUtc '2026-11-06T10:00:00.0000000Z'
            # 'absent' is a record written before v14: the field is not there at all.
            if ('absent' -ne $d.RegionalAdds) { $claim.demand['regionalAdds'] = $d.RegionalAdds } else { $claim.demand.Remove('regionalAdds') }
            if ('absent' -ne $d.RegionalShort) { $claim['regionalShort'] = $d.RegionalShort } else { $claim.Remove('regionalShort') }
            Write-VmfStoreJson -RunPath $d.RunPath -RelPath "capacity/$($d.File).json" -Document $claim -Depth 12
        }
    }
    function Global:RbRead {
        param([string]$RunPath, [string]$File)
        Get-Content (Join-Path $RunPath 'capacity' "$File.json") -Raw | ConvertFrom-Json -Depth 12
    }
    function Global:RbPreview {
        param([string]$RunPath)
        $log = Join-Path $RunPath 'logs' 'events.jsonl'
        $line = @(Get-Content $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 12 } | Where-Object step -eq 'quotaPreview')[-1]
        @($line.requests)
    }
}
AfterAll {
    foreach ($f in 'RbSku', 'RbCatalog', 'RbUsage', 'RbEntry', 'RbPlan', 'RbByWave', 'RbClaim', 'RbRead', 'RbPreview') {
        Remove-Item "function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'REGIONAL-QUOTA-BOTH-1: the quota check records that the region is short beside a family shortfall' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { RbCatalog }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @() }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: a family short AND a region short - the record keeps the family reason and says the region is short too' {
        # Two machines D2s_v4 to D4s_v6: 8 vCPUs of the family (2 free), and 4
        # added to the region (2 free).
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RbEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 8 10), (RbUsage 'cores' 8 10)) }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'quota-shortfall' -Because 'the family reason stays, so the family request is still made'
        $claim.regionalShort | Should -BeTrue -Because 'the region is short for the machines of this record too'
        $claim.demand.regionalAdds | Should -Be 4
        $file = Get-ChildItem (Join-Path $script:rp 'capacity') -Filter '*.json' | Select-Object -First 1
        Test-Json -Json (Get-Content $file.FullName -Raw) -SchemaFile $script:schema | Should -BeTrue
    }

    It 'a family short and a region with room - regionalShort is false' {
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RbEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 8 10), (RbUsage 'cores' 0 100)) }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'quota-shortfall'
        $claim.regionalShort | Should -BeFalse
    }

    It 'a region short for the plan, but this record''s machines add nothing - regionalShort is false' {
        # wave-1: D4s_v4 to D4s_v6 adds 0. wave-2: D2s_v4 to D8s_v6 adds 6, and
        # the region has 2 free. The family is short for both.
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D4s_v4' 'Standard_D4s_v6' -Wave 'wave-1'), (RbEntry 'b' 'Standard_D2s_v4' 'Standard_D8s_v6' -Wave 'wave-2'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 8 10), (RbUsage 'cores' 8 10)) }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp
        (RbByWave $r 'wave-1').regionalShort | Should -BeFalse -Because 'a record that adds no vCPUs cannot be refused by the regional quota'
        (RbByWave $r 'wave-1').demand.regionalAdds | Should -Be 0
        (RbByWave $r 'wave-2').regionalShort | Should -BeTrue
    }

    It 'REGIONAL-QUOTA-WAVES-1: two waves in one region each record what THEIR machines add, beside the whole plan''s total' {
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6' -Wave 'wave-1'), (RbEntry 'b' 'Standard_D2s_v4' 'Standard_D8s_v6' -Wave 'wave-2'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 0 100), (RbUsage 'cores' 0 100)) }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp
        (RbByWave $r 'wave-1').demand.regionalAdds | Should -Be 2
        (RbByWave $r 'wave-2').demand.regionalAdds | Should -Be 6
        (RbByWave $r 'wave-1').demand.regionalVcpus | Should -Be 8 -Because 'regionalVcpus stays the whole plan''s'
        (RbByWave $r 'wave-1').regionalShort | Should -BeFalse
    }

    It 'a region short with the family fitting - regional-quota-shortfall, and regionalShort true' {
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 0 100), (RbUsage 'cores' 9 10)) }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'regional-quota-shortfall'
        $claim.regionalShort | Should -BeTrue
    }

    It 'no regional reading - regionalShort is null, never a yes or a no' {
        $plan = RbPlan $script:rp @((RbEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RbUsage 'standardDSv6Family' 8 10)) }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.PSObject.Properties['regionalShort'] | Should -Not -BeNullOrEmpty -Because 'the record says it, as null'
        $claim.regionalShort | Should -BeNullOrEmpty
        $claim.demand.regionalAdds | Should -Be 2 -Because 'what the machines add is known without the reading'
    }
}

Describe 'REGIONAL-QUOTA-BOTH-1: one press files the family request and the regional request' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        $script:asked = [System.Collections.Generic.List[object]]::new()
        $script:refuse = @()
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            $script:asked.Add([pscustomobject]@{ Family = $Family; NewLimit = $NewLimit; Location = $Location })
            if ($Family -in $script:refuse) { return [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"code":"BadRequest","message":"refused"}}' } }
            [pscustomobject]@{ StatusCode = 202; Content = ('{"id":"/quota-requests/' + $Family + '"}') }
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: a record short on both files BOTH requests in one press' {
        RbClaim $script:rp 'c1' -QuotaLimit 10 -QuotaUsed 8 -FamilyVcpus 4 -RegionalVcpus 6 -RegionalLimit 10 -RegionalUsed 8 -RegionalAdds 4 -RegionalShort $true
        $r = Request-VmfQuota -OutPath $script:rp
        @($script:asked.Family) | Sort-Object | Should -Be @('cores', 'standardDSv6Family')
        @($script:asked | Where-Object Family -eq 'standardDSv6Family')[0].NewLimit | Should -Be 12 -Because 'family usage 8 + 4'
        @($script:asked | Where-Object Family -eq 'cores')[0].NewLimit | Should -Be 14 -Because 'regional usage 8 + the 6 the plan adds'
        @($r.Submitted).Count | Should -Be 2
    }

    It 'the record keeps the family request as its own, and records the regional request beside it' {
        RbClaim $script:rp 'c1' -RegionalAdds 4 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $claim = RbRead $script:rp 'c1'
        $claim.state | Should -Be 'QUOTA_REQUESTED'
        $claim.quota.requestId | Should -Be '/quota-requests/standardDSv6Family'
        $claim.quota.regionalRequestId | Should -Be '/quota-requests/cores'
        $claim.quota.regionalRequestedUtc | Should -Not -BeNullOrEmpty
        Test-Json -Json (Get-Content (Join-Path $script:rp 'capacity' 'c1.json') -Raw) -SchemaFile $script:schema | Should -BeTrue
    }

    It 'a family refused and the region filed - the record stays BLOCKED on its family, so the next press asks again' {
        $script:refuse = @('standardDSv6Family')
        RbClaim $script:rp 'c1' -RegionalAdds 4 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp | Out-Null
        $claim = RbRead $script:rp 'c1'
        $claim.state | Should -Be 'BLOCKED' -Because 'its family was not requested'
        $claim.quota.regionalRequestId | Should -Be '/quota-requests/cores'
    }

    It 'a record short on the family only files NO regional request' {
        RbClaim $script:rp 'c1' -RegionalAdds 4 -RegionalShort $false -RegionalLimit 100 -RegionalUsed 0
        Request-VmfQuota -OutPath $script:rp | Out-Null
        @($script:asked.Family) | Should -Be @('standardDSv6Family')
    }

    It 'a record written before v14 (no regionalShort) files no regional request - the check did not judge it' {
        RbClaim $script:rp 'c1'
        (RbRead $script:rp 'c1').PSObject.Properties['regionalShort'] | Should -BeNullOrEmpty -Because 'the record has the shape of v13'
        Request-VmfQuota -OutPath $script:rp | Out-Null
        @($script:asked.Family) | Should -Be @('standardDSv6Family')
    }

    It 'a family-short record and a regional-only record of one region are ONE regional request' {
        RbClaim $script:rp 'c1' -Wave 'wave-1' -RegionalAdds 4 -RegionalShort $true
        RbClaim $script:rp 'c2' -Wave 'wave-2' -Reason 'regional-quota-shortfall' -Size 'Standard_E4s_v6' -Family 'standardESv6Family' `
            -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 2 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp | Out-Null
        @($script:asked | Where-Object Family -eq 'cores').Count | Should -Be 1
        (RbRead $script:rp 'c2').quota.requestId | Should -Be '/quota-requests/cores' -Because 'for c2 the regional request is its own'
        (RbRead $script:rp 'c2').state | Should -Be 'QUOTA_REQUESTED'
    }

    It 'NOACCESS on the subscription asks for neither' {
        RbClaim $script:rp 'c1' -RegionalAdds 4 -RegionalShort $true -Access 'missing'
        $r = Request-VmfQuota -OutPath $script:rp
        $script:asked.Count | Should -Be 0
        @($r.All | Where-Object Status -eq 'NOACCESS').Count | Should -Be 2
    }

    It 'the preview shows both rows for a record short on both' {
        RbClaim $script:rp 'c1' -RegionalAdds 4 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp -WhatIfOnly | Out-Null
        $script:asked.Count | Should -Be 0
        $rows = RbPreview $script:rp
        @($rows.kind) | Sort-Object | Should -Be @('family', 'regional')
    }
}

Describe 'REGIONAL-QUOTA-WAVES-1: the regional row of the confirmation has a line for each wave' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { throw 'a preview files nothing' }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'two waves in one region give two lines, each with what its own machines add' {
        RbClaim $script:rp 'c1' -Wave 'wave-1' -Reason 'regional-quota-shortfall' -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 2 -RegionalShort $true
        RbClaim $script:rp 'c2' -Wave 'wave-2' -Reason 'regional-quota-shortfall' -Size 'Standard_E4s_v6' -Family 'standardESv6Family' `
            -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 4 -RegionalShort $true
        RbClaim $script:rp 'c3' -Wave 'wave-2' -Reason 'regional-quota-shortfall' -Size 'Standard_D8s_v6' -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 1 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp -WhatIfOnly | Out-Null
        $regional = @(RbPreview $script:rp | Where-Object kind -eq 'regional')[0]
        @($regional.waves).Count | Should -Be 2
        (@($regional.waves) | Where-Object wave -eq 'wave-1').vcpus | Should -Be 2
        (@($regional.waves) | Where-Object wave -eq 'wave-2').vcpus | Should -Be 5 -Because 'the two records of wave-2 add 4 and 1'
    }

    It 'a wave line comes from regionalAdds, never from demand.vcpus (the whole new size)' {
        RbClaim $script:rp 'c1' -Wave 'wave-1' -Reason 'regional-quota-shortfall' -Vcpus 8 -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 2 -RegionalShort $true
        Request-VmfQuota -OutPath $script:rp -WhatIfOnly | Out-Null
        $regional = @(RbPreview $script:rp | Where-Object kind -eq 'regional')[0]
        @($regional.waves)[0].vcpus | Should -Be 2
    }

    It 'a record that does not carry what it adds (written before v14) gives the row no wave lines, not a wrong figure' {
        RbClaim $script:rp 'c1' -Wave 'wave-1' -Reason 'regional-quota-shortfall' -QuotaLimit 100 -QuotaUsed 0 -RegionalAdds 2 -RegionalShort $true
        RbClaim $script:rp 'c2' -Wave 'wave-2' -Reason 'regional-quota-shortfall' -Size 'Standard_E4s_v6' -Family 'standardESv6Family' -QuotaLimit 100 -QuotaUsed 0
        Request-VmfQuota -OutPath $script:rp -WhatIfOnly | Out-Null
        $regional = @(RbPreview $script:rp | Where-Object kind -eq 'regional')[0]
        @($regional.waves).Count | Should -Be 0
    }
}

# REGIONAL-QUOTA-BOTH-PAGE-1: one rule says whether a record is short of the
# Total Regional vCPUs quota. The engine asks it to put the record in its
# region's request; the dashboard's twin (help.js claimRegionalShort) asks it to
# draw the capacity card and the wave editor's line. Both are held to
# tests/fixtures/regional-short.json.
Describe 'REGIONAL-QUOTA-BOTH-PAGE-1: Test-VmfClaimRegionalShort gives the answer the dashboard gives' {
    BeforeAll {
        $script:shortCases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'regional-short.json') -Raw |
            ConvertFrom-Json).cases
    }

    It 'gives every shared case the answer help.js gives' {
        @($script:shortCases).Count | Should -BeGreaterOrEqual 12 -Because 'the fixture loaded'
        foreach ($c in $script:shortCases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ claim = $c.claim } { Test-VmfClaimRegionalShort -Claim $claim }
            $got | Should -BeOfType [bool]
            $got | Should -Be ([bool]$c.short) -Because "$($c.claim | ConvertTo-Json -Compress) - $($c.why)"
        }
    }

    It 'reads a hashtable the same way as a JSON object' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimRegionalShort -Claim @{ state = 'BLOCKED'; blockReason = 'quota-shortfall'; regionalShort = $true } | Should -BeTrue
            Test-VmfClaimRegionalShort -Claim @{ state = 'BLOCKED'; blockReason = 'quota-shortfall'; regionalShort = $false } | Should -BeFalse
            Test-VmfClaimRegionalShort -Claim @{ state = 'BLOCKED'; blockReason = 'regional-quota-shortfall' } | Should -BeTrue
            Test-VmfClaimRegionalShort -Claim @{ state = 'BLOCKED'; blockReason = 'quota-shortfall' } | Should -BeFalse
        }
    }

    It 'is the rule Request-VmfQuota uses to put a record in its region''s request' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Request-VmfQuota.ps1')
        $code | Should -Match 'Test-VmfClaimRegionalShort\s+-Claim'
        $code | Should -Not -Match 'regionalShort\s+-eq' -Because 'the request reads the one rule, not a copy of it'
    }
}
