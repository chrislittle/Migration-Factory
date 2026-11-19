#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    QUOTA-FILED-WORDS-1: the wave editor said "The quota increase request is
    filed" as soon as the engine job STARTED, before Azure was asked. Any of
    the requests could then fail - Azure answers with an error, the record
    names no subscription, the product has no access - and the reason was only in
    the activity log, which nobody had cause to open.

    The fix copies QUOTA-PREVIEW-1: the engine writes ONE line when the real
    request finishes (step quotaResult), with each quota, its status
    (APPROVED, PENDING, FAILED, NOACCESS) and, for a quota not filed, the
    reason. The page waits for that line and says "filed" only for the quotas
    Azure took.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function script:Write-TestClaim {
        param($RunPath, $Name, $State = 'BLOCKED', $BlockReason = 'quota-shortfall', $Used = 8, $Limit = 10, $Vcpus = 4,
              $Family = 'StandardDDSv6Family', $Wave = 'wave-1', $SubscriptionId = '11111111-2222-3333-4444-555555555555',
              $Region = 'centralus', $QuotaName = $null, $Access = $null)
        $quota = @{ limit = $Limit; used = $Used; requestId = $null; requestedUtc = $null }
        if ($QuotaName) { $quota.name = $QuotaName }
        if ($Access) { $quota.requestAccess = $Access }
        @{
            schemaVersion = 12; runId = 'r1'; wave = $Wave; region = $Region; zone = $null
            subscriptionId = $SubscriptionId
            size = 'Standard_D2ds_v6'; vmFamily = $Family; state = $State
            blockReason = $BlockReason
            demand = @{ instances = 2; vcpus = $Vcpus }
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
    function script:Get-TestResult {
        param($RunPath)
        @(Get-TestEvents -RunPath $RunPath | Where-Object { $_.step -eq 'quotaResult' })
    }
    function script:Get-TestRow {
        param($Result, $Family)
        @($Result.requests | Where-Object family -eq $Family)[0]
    }
}

AfterAll {
    Remove-Item -Path 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'QUOTA-FILED-WORDS-1: the engine says which quota increase requests Azure took' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qfw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'writes ONE result line after a real request, with each quota and its status' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -QuotaName 'Standard DDSv6 Family vCPUs'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardEDSv6Family' -Region 'eastus2'
        Write-TestClaim -RunPath $script:runPath -Name 'c' -Family 'StandardFSv2Family'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            switch ($Family) {
                'StandardDDSv6Family' { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
                'StandardEDSv6Family' { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/e"}' } }
                default { [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"code":"QuotaNotAvailable","message":"The quota is not available for this subscription."}}' } }
            }
        }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $result = @(Get-TestResult -RunPath $script:runPath)
        $result.Count | Should -Be 1 -Because 'the page waits for exactly one answer'
        $rows = @($result[0].requests)
        $rows.Count | Should -Be 3
        $dds = Get-TestRow -Result $result[0] -Family 'StandardDDSv6Family'
        $dds.status | Should -Be 'APPROVED'
        $dds.quotaName | Should -Be 'Standard DDSv6 Family vCPUs'
        $dds.region | Should -Be 'centralus'
        $dds.subscriptionId | Should -Be '11111111-2222-3333-4444-555555555555'
        $dds.requestedLimit | Should -Be 12
        (Get-TestRow -Result $result[0] -Family 'StandardEDSv6Family').status | Should -Be 'PENDING'
        (Get-TestRow -Result $result[0] -Family 'StandardEDSv6Family').region | Should -Be 'eastus2'
        (Get-TestRow -Result $result[0] -Family 'StandardFSv2Family').status | Should -Be 'FAILED'
    }

    It 'gives the reason Azure wrote for a refused request, with its HTTP status and error code' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"code":"QuotaNotAvailable","message":"The quota is not available for this subscription."}}' }
        }

        $r = Request-VmfQuota -OutPath $script:runPath

        $row = Get-TestRow -Result (Get-TestResult -RunPath $script:runPath)[0] -Family 'StandardDDSv6Family'
        $row.reason | Should -Be 'Azure answered HTTP 400 QuotaNotAvailable: The quota is not available for this subscription.'
        @($r.Failed).Count | Should -Be 1
        $fail = @(Get-TestEvents -RunPath $script:runPath | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1 -Because 'the activity log still has its own line for the quota'
        # MANUAL-REVIEW-1: the line is shown word for word, so it is a sentence:
        # the quota and its region, then the reason - never key=value and Azure's raw body.
        $fail[0].detail | Should -Match '^StandardDDSv6Family in \w+: Azure answered HTTP 400 QuotaNotAvailable: The quota is not available for this subscription\.$'
        $fail[0].detail | Should -Not -Match 'family=|\{"error"'
    }

    It 'gives the whole body when Azure''s answer is not an error it can read' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 500; Content = 'upstream broke' } }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        (Get-TestRow -Result (Get-TestResult -RunPath $script:runPath)[0] -Family 'StandardDDSv6Family').reason |
            Should -Be 'Azure answered HTTP 500: upstream broke'
    }

    It 'gives the reason for a record with no subscription, and for a quota the tool has no access to request' {
        Write-TestClaim -RunPath $script:runPath -Name 'nosub' -SubscriptionId ''
        Write-TestClaim -RunPath $script:runPath -Name 'noaccess' -Family 'StandardEDSv6Family' -Access 'missing'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { throw 'must not be asked' }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $result = (Get-TestResult -RunPath $script:runPath)[0]
        $nosub = Get-TestRow -Result $result -Family 'StandardDDSv6Family'
        $nosub.status | Should -Be 'FAILED'
        $nosub.reason | Should -Match '^The quota record does not name a subscription'
        $noaccess = Get-TestRow -Result $result -Family 'StandardEDSv6Family'
        $noaccess.status | Should -Be 'NOACCESS'
        $noaccess.reason | Should -Match '^The product cannot request a quota increase on subscription'
        $noaccess.reason | Should -Match 'Assess and migrate role'
    }

    It 'gives the reason when the request itself throws, and still requests the other quotas' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardEDSv6Family'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            if ($Family -eq 'StandardDDSv6Family') { throw 'AuthorizationFailed: the client does not have authorization' }
            [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/e"}' }
        }

        $r = Request-VmfQuota -OutPath $script:runPath

        $result = (Get-TestResult -RunPath $script:runPath)[0]
        $thrown = Get-TestRow -Result $result -Family 'StandardDDSv6Family'
        $thrown.status | Should -Be 'FAILED'
        $thrown.reason | Should -Match 'AuthorizationFailed'
        (Get-TestRow -Result $result -Family 'StandardEDSv6Family').status | Should -Be 'PENDING' -Because 'one quota that fails does not stop the others'
        @($r.Submitted).Count | Should -Be 1
        @($r.Failed).Count | Should -Be 1
        (Get-Content (Join-Path $script:runPath 'capacity' 'a.json') -Raw | ConvertFrom-Json).state | Should -Be 'BLOCKED'
        $fail = @(Get-TestEvents -RunPath $script:runPath | Where-Object { $_.step -eq 'quotaRequest' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].detail | Should -Match 'AuthorizationFailed'
    }

    It 'gives the request ID Azure returned for each filed request, so the page can name it (QUOTA-CHECK-SPINNER-1)' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardEDSv6Family'
        Write-TestClaim -RunPath $script:runPath -Name 'c' -Family 'StandardFSv2Family'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            switch ($Family) {
                'StandardEDSv6Family' { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Quota/quotaRequests/00000000-0000-0000-0000-0000000000aa"}' } }
                'StandardDDSv6Family' { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
                default { [pscustomobject]@{ StatusCode = 400; Content = '{}' } }
            }
        }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $result = (Get-TestResult -RunPath $script:runPath)[0]
        (Get-TestRow -Result $result -Family 'StandardEDSv6Family').requestId |
            Should -Be '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Quota/quotaRequests/00000000-0000-0000-0000-0000000000aa'
        $approved = Get-TestRow -Result $result -Family 'StandardDDSv6Family'
        $approved.PSObject.Properties.Name | Should -Contain 'requestId' -Because 'every row has the field, empty when Azure gave none'
        $approved.requestId | Should -BeNullOrEmpty
        (Get-TestRow -Result $result -Family 'StandardFSv2Family').requestId | Should -BeNullOrEmpty -Because 'a request not filed has no ID'
    }

    It 'says in the line how many requests the engine filed, as ok when all, and as warn when not' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardEDSv6Family'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            if ($Family -eq 'StandardDDSv6Family') { [pscustomobject]@{ StatusCode = 403; Content = '{}' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $line = (Get-TestResult -RunPath $script:runPath)[0]
        $line.detail | Should -Be 'The engine filed 1 of 2 quota increase requests.'
        $line.outcome | Should -Be 'warn'
    }

    It 'writes ok when every request is filed' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"x"}' } }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $line = (Get-TestResult -RunPath $script:runPath)[0]
        $line.detail | Should -Be 'The engine filed 1 of 1 quota increase requests.'
        $line.outcome | Should -Be 'ok'
        $raw = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"quotaResult"' }
        $raw | Should -Match '"requests":\[\{' -Because 'one row stays a list'
    }

    It 'writes the result line with no rows when nothing is too low, so the page has an answer' {
        Write-TestClaim -RunPath $script:runPath -Name 'ok' -State 'QUOTA_VERIFIED' -BlockReason $null

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $result = @(Get-TestResult -RunPath $script:runPath)
        $result.Count | Should -Be 1
        $raw = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"quotaResult"' }
        $raw | Should -Match '"requests":\[\]' -Because 'an empty list, not a missing field'
    }

    It 'writes no result line for a preview' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'

        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null

        @(Get-TestResult -RunPath $script:runPath).Count | Should -Be 0 -Because 'a preview files nothing, and the page waits for its own line'
    }

    It 'never turns requests Azure took into a failure when the result line cannot be written (STEP-LOG-5)' {
        # The line comes after Azure was asked. A store error writing it must
        # not decide what the engine did: the requests stay filed and recorded.
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"x"}' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaResult' } { throw 'store unavailable' }

        $r = Request-VmfQuota -OutPath $script:runPath -WarningVariable said -WarningAction SilentlyContinue

        @($r.Submitted).Count | Should -Be 1
        (Get-Content (Join-Path $script:runPath 'capacity' 'a.json') -Raw | ConvertFrom-Json).state | Should -Be 'QUOTA_REQUESTED'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaResult' } -Times 1 -Exactly
        ($said -join ' ') | Should -Match 'quotaResult' -Because 'the engine output keeps what the line said'
    }
}
