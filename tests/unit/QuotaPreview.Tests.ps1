#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    QUOTA-PREVIEW-1: "Show me what would be requested first" showed nothing.

    The engine computed the preview (Request-VmfQuota -WhatIfOnly, the WHATIF
    rows) and wrote it only to the container log, which no page can read. The
    wave editor then printed "The quota increase request is filed" for a
    request nobody filed. The engine's answers reach a page through the run's
    activity log (logs/events.jsonl), the way the quota check's summary line
    does, so the preview goes there as ONE line the page waits for.

    The design (2026-10-25): no checkbox. Request an increase opens a
    confirmation that lists exactly what will be requested, ONE ROW PER QUOTA
    with Azure's columns (Quota, Region, Usage, Current limit, New limit), and
    under it each wave's need and what the current limit leaves. So the engine
    groups by quota (subscription, region, family), asks for the limit the
    whole plan needs of it, and files exactly the rows the preview shows.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function script:Write-TestClaim {
        param($RunPath, $Name, $State = 'BLOCKED', $BlockReason = 'quota-shortfall', $Used = 8, $Limit = 10, $Vcpus = 4,
              $Family = 'StandardDDSv6Family', $Wave = 'wave-1', $SubscriptionId = '11111111-2222-3333-4444-555555555555',
              $Region = 'centralus', $FamilyVcpus = $null, $QuotaName = $null, $Access = $null)
        $quota = @{ limit = $Limit; used = $Used; requestId = $null; requestedUtc = $null }
        if ($QuotaName) { $quota.name = $QuotaName }
        if ($Access) { $quota.requestAccess = $Access }
        $demand = @{ instances = 2; vcpus = $Vcpus }
        if ($null -ne $FamilyVcpus) { $demand.familyVcpus = $FamilyVcpus }
        @{
            schemaVersion = 12; runId = 'r1'; wave = $Wave; region = $Region; zone = $null
            subscriptionId = $SubscriptionId
            size = 'Standard_D2ds_v6'; vmFamily = $Family; state = $State
            blockReason = $BlockReason
            demand = $demand
            quota = $quota
            notes = @()
        } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $RunPath 'capacity' "$Name.json")
    }
    function script:Get-TestEvents {
        param($RunPath)
        $log = Join-Path $RunPath 'logs' 'events.jsonl'
        if (-not (Test-Path $log)) { return @() }
        @(Get-Content $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    function script:Get-TestPreviewEvents {
        param($RunPath)
        @(Get-TestEvents -RunPath $RunPath | Where-Object { $_.step -eq 'quotaPreview' })
    }
    function script:Read-TestClaim {
        param($RunPath, $Name)
        Get-Content (Join-Path $RunPath 'capacity' "$Name.json") -Raw | ConvertFrom-Json
    }
}

AfterAll {
    Remove-Item -Path 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'QUOTA-PREVIEW-1: the preview reaches the activity log, one row per quota' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'writes ONE preview line with each quota, its usage, its current limit and the limit asked for' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -Used 8 -Limit 10 -Vcpus 4 -QuotaName 'Standard DDSv6 Family vCPUs'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Used 20 -Limit 24 -Vcpus 8 -Family 'StandardEDSv6Family' -Wave 'wave-2'
        Write-TestClaim -RunPath $script:runPath -Name 'ok' -State 'QUOTA_VERIFIED' -BlockReason $null -Family 'StandardFSv2Family'

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly -HeadroomVcpus 2 | Out-Null

        $preview = @(Get-TestPreviewEvents -RunPath $script:runPath)
        $preview.Count | Should -Be 1
        $preview[0].outcome | Should -Be 'info'
        $preview[0].detail | Should -Be 'The preview shows 2 quota increase requests. No request was filed.'
        @(Get-TestEvents -RunPath $script:runPath | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -ne 'fail' }).Count |
            Should -Be 0 -Because 'the activity log calls every quotaRequest line "A quota increase was requested"'
        $rows = @($preview[0].requests | Sort-Object family)
        $rows.Count | Should -Be 2 -Because 'only the quotas too low are requested'
        $rows[0].family | Should -Be 'StandardDDSv6Family'
        $rows[0].quotaName | Should -Be 'Standard DDSv6 Family vCPUs' -Because 'Azure''s own name for the quota, from the usage list'
        $rows[0].subscriptionId | Should -Be '11111111-2222-3333-4444-555555555555'
        $rows[0].region | Should -Be 'centralus'
        $rows[0].usage | Should -Be 8
        $rows[0].currentLimit | Should -Be 10
        $rows[0].requestedLimit | Should -Be 14 -Because 'used 8 + needed 4 + headroom 2'
        $rows[0].status | Should -Be 'WHATIF'
        $rows[1].family | Should -Be 'StandardEDSv6Family'
        $rows[1].quotaName | Should -Be 'StandardEDSv6Family' -Because 'a record with no name from Azure shows its family'
        $rows[1].usage | Should -Be 20
        $rows[1].currentLimit | Should -Be 24
        $rows[1].requestedLimit | Should -Be 30
    }

    It 'puts two records of ONE quota in one row, asks for what the whole plan needs of it, and says what each wave needs' {
        # Two waves, one family: 6 + 10 vCPUs, the check judged 16 in all.
        Write-TestClaim -RunPath $script:runPath -Name 'w1' -Wave 'wave-1' -Vcpus 6 -Used 30 -Limit 40 -FamilyVcpus 16
        Write-TestClaim -RunPath $script:runPath -Name 'w2' -Wave 'wave-2' -Vcpus 10 -Used 30 -Limit 40 -FamilyVcpus 16

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $rows = @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests)
        $rows.Count | Should -Be 1 -Because 'one quota is one row, and one request'
        $rows[0].requestedLimit | Should -Be 46 -Because 'used 30 + the 16 the whole plan needs of the family'
        $rows[0].free | Should -Be 10 -Because 'the current limit 40 less the 30 in use'
        $waves = @($rows[0].waves | Sort-Object wave)
        $waves.Count | Should -Be 2
        $waves[0].wave | Should -Be 'wave-1'
        $waves[0].vcpus | Should -Be 6
        $waves[1].wave | Should -Be 'wave-2'
        $waves[1].vcpus | Should -Be 10
    }

    It 'adds the records'' vCPUs when no record carries the family total' {
        Write-TestClaim -RunPath $script:runPath -Name 'w1' -Wave 'wave-1' -Vcpus 6 -Used 30 -Limit 40
        Write-TestClaim -RunPath $script:runPath -Name 'w2' -Wave 'wave-1' -Vcpus 10 -Used 30 -Limit 40

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $row = @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests)[0]
        $row.requestedLimit | Should -Be 46
        @($row.waves).Count | Should -Be 1 -Because 'one wave with two sizes is one line'
        @($row.waves)[0].vcpus | Should -Be 16
    }

    It 'never says the current limit leaves less than nothing' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -Used 12 -Limit 10 -Vcpus 4

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $row = @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests)[0]
        $row.free | Should -Be 0 -Because 'usage above the limit leaves 0, not -2'
        $row.requestedLimit | Should -Be 16
    }

    It 'keeps two subscriptions of one family apart' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -SubscriptionId '11111111-2222-3333-4444-555555555555'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -SubscriptionId '00000000-0000-0000-0000-000000000000'

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests).Count | Should -Be 2
    }

    It 'says in the preview which family cannot be requested, because its record names no subscription' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Write-TestClaim -RunPath $script:runPath -Name 'nosub' -Family 'StandardEDSv6Family' -SubscriptionId ''

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $rows = @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests)
        $rows.Count | Should -Be 2
        ($rows | Where-Object family -eq 'StandardEDSv6Family').status | Should -Be 'FAILED'
        ($rows | Where-Object family -eq 'StandardDDSv6Family').status | Should -Be 'WHATIF'
    }

    It 'marks a quota the tool has no access to request, and carries the access of each row' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -Access 'missing'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardEDSv6Family' -Access 'unknown'
        Write-TestClaim -RunPath $script:runPath -Name 'c' -Family 'StandardFSv2Family' -Access 'granted'

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $rows = @((Get-TestPreviewEvents -RunPath $script:runPath)[0].requests)
        ($rows | Where-Object family -eq 'StandardDDSv6Family').status | Should -Be 'NOACCESS'
        ($rows | Where-Object family -eq 'StandardEDSv6Family').status | Should -Be 'WHATIF' -Because 'unknown is not a no: Azure decides'
        ($rows | Where-Object family -eq 'StandardEDSv6Family').access | Should -Be 'unknown'
        ($rows | Where-Object family -eq 'StandardFSv2Family').status | Should -Be 'WHATIF'
    }

    It 'writes the preview line with no rows when nothing is too low, so the page has an answer' {
        Write-TestClaim -RunPath $script:runPath -Name 'ok' -State 'QUOTA_VERIFIED' -BlockReason $null

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $preview = @(Get-TestPreviewEvents -RunPath $script:runPath)
        $preview.Count | Should -Be 1
        @($preview[0].requests).Count | Should -Be 0
        $raw = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"quotaPreview"' }
        $raw | Should -Match '"requests":\[\]' -Because 'an empty list, not a missing field'
    }

    It 'keeps a one-row preview, and a one-wave row, a list' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        $raw = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"quotaPreview"' }
        $raw | Should -Match '"requests":\[\{'
        $raw | Should -Match '"waves":\[\{'
        $raw | Should -Match 'shows 1 quota increase request\.'
    }

    It 'files nothing for a preview' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { throw 'a preview must not file a request' }

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly
        (Read-TestClaim -RunPath $script:runPath -Name 'a').state | Should -Be 'BLOCKED'
    }

    It 'writes no preview line for a real request' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/abc"}' }
        }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        @(Get-TestPreviewEvents -RunPath $script:runPath).Count | Should -Be 0
    }
}

Describe 'QUOTA-PREVIEW-1: a real request files exactly the rows the preview shows' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qr1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'files ONE request per quota, for the limit the whole plan needs, and marks every record of it requested' {
        Write-TestClaim -RunPath $script:runPath -Name 'w1' -Wave 'wave-1' -Vcpus 6 -Used 30 -Limit 40 -FamilyVcpus 16
        Write-TestClaim -RunPath $script:runPath -Name 'w2' -Wave 'wave-2' -Vcpus 10 -Used 30 -Limit 40 -FamilyVcpus 16
        $script:asked = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            $script:asked.Add([pscustomobject]@{ Family = $Family; NewLimit = $NewLimit; SubscriptionId = $SubscriptionId })
            [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/abc"}' }
        }

        $r = Request-VmfQuota -OutPath $script:runPath

        $script:asked.Count | Should -Be 1 -Because 'two records of one quota are one request - two would each ask for less than the plan needs'
        $script:asked[0].NewLimit | Should -Be 46
        @($r.Submitted).Count | Should -Be 1
        (Read-TestClaim -RunPath $script:runPath -Name 'w1').state | Should -Be 'QUOTA_REQUESTED'
        (Read-TestClaim -RunPath $script:runPath -Name 'w2').state | Should -Be 'QUOTA_REQUESTED'
        (Read-TestClaim -RunPath $script:runPath -Name 'w2').quota.requestId | Should -Be '/quota-requests/abc'
    }

    It 'does not ask Azure for a quota the quota check found no access to request, and says so' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -Access 'missing'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { throw 'must not be asked' }

        $r = Request-VmfQuota -OutPath $script:runPath

        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly
        @($r.Failed).Count | Should -Be 1
        $fail = @(Get-TestEvents -RunPath $script:runPath | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        # Since 2026-10-26: request a quota increase - Azure's term, and the role that gives it.
        $fail[0].detail | Should -Match 'cannot request a quota increase on subscription'
        $fail[0].detail | Should -Match 'Assess and migrate role'
        (Read-TestClaim -RunPath $script:runPath -Name 'a').state | Should -Be 'BLOCKED'
    }

    It 'asks Azure when the access could not be read - Azure decides' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -Access 'unknown'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }

        (Request-VmfQuota -OutPath $script:runPath).Submitted[0].Status | Should -Be 'APPROVED'
        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 1 -Exactly
    }
}
