#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REGIONAL-VCPU-QUOTA-1, 2026-10-19.
#
# Azure holds TWO vCPU quotas for a subscription in a region: one per size
# family, and one for all vCPUs ("Total Regional vCPUs", 'cores' in the usage
# list). Test-VmfQuota judged only the family. A wave whose families each fit
# could ask for more vCPUs in all than the region allows, and Azure refused the
# resize or the rebuild with a quota error - with the machine stopped, so it
# rolled back inside its change window.
#
# The regional quota is read from the SAME usage list the family check reads
# (Get-VmfVmUsage), so no new Azure call is made. Azure counts a deallocated
# machine against it, and a move gives back the old size's vCPUs as it takes
# the new size's - so a machine asks the region only for the vCPUs it ADDS.
# Each machine's old size offsets only its own new size: the order the machines
# run in is not known, so one machine's smaller size is never lent to another.
#
# THESE TESTS RUN Test-VmfQuota with Azure's answers mocked.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:RqSku {
        param([string]$Name, [string]$Family, [int]$Vcpus)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
        }
    }
    # The sizes these tests use: v4 sources, v6 targets, each with its vCPUs.
    function Global:RqCatalog {
        @((RqSku 'Standard_D2s_v4' 'standardDSv4Family' 2),
          (RqSku 'Standard_D4s_v4' 'standardDSv4Family' 4),
          (RqSku 'Standard_D8s_v4' 'standardDSv4Family' 8),
          (RqSku 'Standard_D2s_v6' 'standardDSv6Family' 2),
          (RqSku 'Standard_D4s_v6' 'standardDSv6Family' 4),
          (RqSku 'Standard_D8s_v6' 'standardDSv6Family' 8))
    }
    function Global:RqUsage {
        param([string]$Name, [int]$Used, [int]$Limit)
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $Name }; CurrentValue = $Used; Limit = $Limit }
    }
    function Global:RqEntry {
        param([string]$Name, [string]$Source, [string]$Target, [string]$Wave = 'wave-1',
              [string]$Region = 'centralus', [string]$Sub = '00000000-0000-0000-0000-000000000000',
              [string]$Gate = 'BestEffort', [switch]$Avset)
        @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
           wave = $Wave; path = 'A'
           assessment = @{ location = $Region; sourceSize = $Source; availabilitySetId = $(if ($Avset) { '/avsets/pair' } else { '' }) }
           target = @{ size = $Target; zone = $null }
           policy = @{ capacityGate = $Gate } }
    }
    function Global:RqPlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'rq'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }
    function Global:RqNotes { param($Claim) (@($Claim.notes) -join ' | ') }
}
AfterAll {
    foreach ($f in 'RqSku', 'RqCatalog', 'RqUsage', 'RqEntry', 'RqPlan', 'RqNotes') {
        Remove-Item "function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'REGIONAL-VCPU-QUOTA-1: the Total Regional vCPUs quota is judged beside the family quota' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { RqCatalog }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: every family fits, and the region does not - the record is BLOCKED on the regional quota' {
        # Two machines, D2s_v4 to D4s_v6: each adds 2 vCPUs, 4 in all. The
        # family has 100 free. The region has 2 free.
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 8 10))
        }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp
        @($r.Claims).Count | Should -Be 1
        $claim = @($r.Claims)[0]
        $claim.state | Should -Be 'BLOCKED'
        $claim.blockReason | Should -Be 'regional-quota-shortfall'
        @($r.Blocked).Count | Should -Be 1
        RqNotes $claim | Should -Match 'Total Regional vCPUs'
        RqNotes $claim | Should -Match 'needs 4 vCPUs'
        RqNotes $claim | Should -Match 'headroom 2'
        RqNotes $claim | Should -Not -Match 'capacity' -Because 'a quota is not capacity (QUOTA-NOT-CAPACITY-1)'
    }

    It 'the record carries the regional ask and the regional reading it was judged on' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 8 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 4
        $claim.quota.regionalLimit | Should -Be 10
        $claim.quota.regionalUsed | Should -Be 8
        # And the record on disk validates against its schema.
        $file = Get-ChildItem (Join-Path $script:rp 'capacity') -Filter '*.json' | Select-Object -First 1
        Test-Json -Json (Get-Content $file.FullName -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') |
            Should -BeTrue
    }

    It 'the region fitting is still verified' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 6 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.state | Should -Be 'QUOTA_VERIFIED' -Because '4 vCPUs fit in 4 free'
    }

    It 'a move to a size of the same vCPUs asks the region for nothing, because the old size is given back' {
        # D4s_v4 to D4s_v6. Azure counts the old size until the move, and the
        # move gives it back as it takes the new one. The region is full.
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D4s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D4s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 10 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.state | Should -Be 'QUOTA_VERIFIED'
        $claim.demand.regionalVcpus | Should -Be 0
    }

    It 'a wave that reserves asks for the WHOLE new size - the reservation is made while the old machines still count' {
        # D4s_v4 to D4s_v6 adds nothing to a resize. But a capacity reservation
        # needs quota as a VM create does, and it is made before the wave, with
        # the old machine still counted. The region has 2 free.
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D4s_v4' 'Standard_D4s_v6' -Gate 'Reserved'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 8 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 4
        $claim.state | Should -Be 'BLOCKED'
        $claim.blockReason | Should -Be 'regional-quota-shortfall'
    }

    It 'but a machine in an availability set in that wave moves on general capacity, and asks only for what it adds' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D4s_v4' 'Standard_D4s_v6' -Gate 'Reserved' -Avset))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 10 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 0
        $claim.state | Should -Be 'QUOTA_VERIFIED'
    }

    It 'a smaller size never lends its vCPUs to another machine - the order the machines run in is not known' {
        # 'a' goes 8 -> 4 and gives back 4. 'b' goes 2 -> 8 and adds 6. If 'b'
        # runs first, it needs 6 free. The region has 4 free.
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D8s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D8s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 6 10))
        }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp
        $grow = @($r.Claims) | Where-Object size -eq 'Standard_D8s_v6'
        $shrink = @($r.Claims) | Where-Object size -eq 'Standard_D4s_v6'
        $grow.demand.regionalVcpus | Should -Be 6 -Because 'each machine offsets only its own new size: 0 + 6, not 6 - 4'
        $grow.state | Should -Be 'BLOCKED'
        $grow.blockReason | Should -Be 'regional-quota-shortfall'
        # A machine that adds no vCPUs cannot fail on the regional quota, so it
        # is not blocked by the others - and its note says so.
        $shrink.state | Should -Be 'QUOTA_VERIFIED'
        RqNotes $shrink | Should -Match 'Total Regional vCPUs'
    }

    It 'a source size the size list does not show gives back nothing, which is the safe side, and says so' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D4_v2' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 8 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 4 -Because 'the vCPUs of Standard_D4_v2 are not known, so its release is not counted'
        $claim.state | Should -Be 'BLOCKED'
        RqNotes $claim | Should -Match 'Standard_D4_v2'
    }

    It 'a region that Azure does not list a regional quota for is not judged, and the record says unknown, never 0' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @((RqUsage 'standardDSv6Family' 0 100)) }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.state | Should -Be 'QUOTA_VERIFIED'
        $null -eq $claim.quota.regionalLimit | Should -BeTrue
        $null -eq $claim.quota.regionalUsed | Should -BeTrue
        RqNotes $claim | Should -Match 'Total Regional vCPUs'
    }

    It 'the family short too keeps the family reason - Request an increase can act on it - and names the regional quota as well' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 2), (RqUsage 'cores' 9 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.blockReason | Should -Be 'quota-shortfall'
        RqNotes $claim | Should -Match 'family standardDSv6Family needs 4'
        RqNotes $claim | Should -Match 'Total Regional vCPUs'
    }

    It 'another region and another subscription keep their own regional quota' {
        $plan = RqPlan $script:rp @(
            (RqEntry 'a' 'Standard_D2s_v4' 'Standard_D8s_v6'),
            (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D8s_v6' -Region 'eastus2'),
            (RqEntry 'c' 'Standard_D2s_v4' 'Standard_D8s_v6' -Sub '11111111-1111-1111-1111-111111111111'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 0 6))
        }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp
        @($r.Claims).Count | Should -Be 3
        foreach ($claim in @($r.Claims)) {
            $claim.demand.regionalVcpus | Should -Be 6 -Because 'each subscription and region holds one machine that adds 6'
            $claim.state | Should -Be 'QUOTA_VERIFIED'
        }
    }

    It 'a check of ONE wave judges the regional ask of the whole plan, as the family check does' {
        $plan = RqPlan $script:rp @(
            (RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6' -Wave 'wave-1'),
            (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D8s_v6' -Wave 'wave-2'))
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 0 6))
        }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp -Wave 'wave-1'
        @($r.Claims).Count | Should -Be 1
        $claim = @($r.Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 8 -Because '2 for wave-1 and 6 for wave-2'
        $claim.state | Should -Be 'BLOCKED'
        $claim.blockReason | Should -Be 'regional-quota-shortfall'
    }

    It 'a machine that has migrated is not in the regional ask' {
        $plan = RqPlan $script:rp @((RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'), (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6'))
        $vmB = (RqEntry 'b' 'Standard_D2s_v4' 'Standard_D4s_v6').vmId
        InModuleScope VmMigrationFactory -Parameters @{ RunPath = $script:rp; VmId = $vmB } {
            param($RunPath, $VmId)
            Initialize-VmfStore -RunPath $RunPath
            Write-VmfStoreJson -RunPath $RunPath -RelPath 'state/b.json' -Document @{ vmId = $VmId; state = 'MIGRATED' }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 8 10))
        }
        $claim = @((Test-VmfQuota -PlanPath $plan -OutPath $script:rp).Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 2
        $claim.state | Should -Be 'QUOTA_VERIFIED'
    }

    It 'a machine that continues its move and is not on its new size yet counts its whole new size first' {
        # It may be in the middle of a rebuild, with its old definition gone
        # and its old vCPUs no longer counted - so nothing is given back for
        # it. The machines not started are judged against what is left.
        $a = RqEntry 'a' 'Standard_D2s_v4' 'Standard_D4s_v6'
        $b = RqEntry 'b' 'Standard_D4s_v4' 'Standard_D4s_v6'
        $plan = RqPlan $script:rp @($a, $b)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $b.vmId } {
            param($rp, $id)
            Initialize-VmfStore -RunPath $rp
            $doc = [ordered]@{ schemaVersion = 3; vmId = $id; state = 'CONVERTING'
                captured = [ordered]@{ startedTarget = [ordered]@{ path = 'B'; target = [ordered]@{ size = 'Standard_D4s_v6' } } } }
            Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $id) + '.json') -Document $doc -Depth 8
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @((RqUsage 'standardDSv6Family' 0 100), (RqUsage 'cores' 4 10))
        }
        $r = Test-VmfQuota -PlanPath $plan -OutPath $script:rp -LeaveOutStarted
        @($r.Claims).Count | Should -Be 1 -Because 'the machine that continues gets no record'
        $claim = @($r.Claims)[0]
        $claim.demand.regionalVcpus | Should -Be 6 -Because '4 for the machine that continues, then 2 for the one not started'
        $claim.state | Should -Be 'QUOTA_VERIFIED' -Because '6 fit in 6 free'
    }
}

Describe 'REGIONAL-VCPU-QUOTA-1: what reads the new block reason' {
    It 'Request an increase never files a FAMILY increase for a regional shortfall - it asks for the regional quota' {
        # Its family fits. A family request sized from this record would ask
        # for used + vcpus - which can be BELOW the family's present limit.
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                param($rp)
                Initialize-VmfStore -RunPath $rp
                $claim = New-VmfCapacityClaim -RunId 'r1' -Wave 'wave-1' -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                    -ResourceGroup 'rg-app' -Region 'centralus' -Size 'Standard_D4s_v6' -VmFamily 'standardDSv6Family' `
                    -State 'BLOCKED' -BlockReason 'regional-quota-shortfall' -Instances 1 -ReservableInstances 1 -Vcpus 4 `
                    -QuotaLimit 100 -QuotaUsed 0 -RegionalVcpus 4 -RegionalLimit 10 -RegionalUsed 8
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/c1.json' -Document $claim -Depth 12
            }
            # REGIONAL-QUOTA-REQUEST-1: it asks for the Total Regional vCPUs
            # quota ('cores') instead - RegionalQuotaRequest.Tests.ps1.
            Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
            $result = Request-VmfQuota -OutPath $rp
            @($result.All).Count | Should -Be 1
            Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly -ParameterFilter { $Family -ne 'cores' }
            Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 1 -Exactly -ParameterFilter { $Family -eq 'cores' }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'a wave start names the machines and the regional quota, in the file''s words' {
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-2'
            wave = 'wave-1'; path = 'A'
            assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = 'Standard_D2s_v4'; availabilitySetId = '' }
            target = [pscustomobject]@{ size = 'Standard_E2s_v6' }
        }
        $claim = [pscustomobject]@{ schemaVersion = 11; wave = 'wave-1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
            region = 'centralus'; zone = $null; size = 'Standard_E2s_v6'; state = 'BLOCKED'; blockReason = 'regional-quota-shortfall'
            demand = [pscustomobject]@{ instances = 1; reservableInstances = 1; vcpus = 2 } }
        $said = InModuleScope VmMigrationFactory -Parameters @{ e = @($entry); c = @($claim) } {
            $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims $c)
            Get-VmfReservedCoverRefusal -Gate BestEffort -Wave 'wave-1' -Gaps $gaps
        }
        $said.Code | Should -Be 'regionalQuotaShortGeneral'
        $said.Detail | Should -Match "'app-2'"
        $said.Detail | Should -Match 'Total Regional vCPUs'
    }
}
