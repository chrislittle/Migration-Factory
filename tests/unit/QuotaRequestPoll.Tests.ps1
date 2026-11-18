#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    QUOTA-REQUEST-POLL-1: a quota increase request Azure accepts with HTTP 202
    showed "Pending" for ever. Nothing in the product read the request again,
    so the page never said that Azure approved it or refused it.

    MEASURED 2026-11-16 in the final lab: after the product filed a request
    (202), GET .../providers/Microsoft.Quota/quotaRequests/{id}?api-version=2023-02-01
    answered provisioningState InProgress "Request processing." and, about 80
    seconds later, Failed "Request failed." with error.code
    QuotaNotAvailableForResource. Earlier requests: Succeeded "Request completed.".
    Microsoft's Quota Request Status page lists the states Accepted, Invalid,
    Succeeded, Failed and InProgress.

    Now the engine reads each filed request through azureops for at least 2
    minutes after it was filed, and writes one quotaAnswer line for each, with
    the request ID and the answer: APPROVED, REFUSED (with Azure's code),
    WAITING (no answer in the time) or NOTREAD (the product could not read it).
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '11111111-2222-3333-4444-555555555555'
    $script:guidA = '00000000-0000-4000-8000-0000000000aa'
    $script:guidB = '00000000-0000-4000-8000-0000000000bb'
    $script:idA = "/subscriptions/$($script:sub)/providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/quotaRequests/$($script:guidA)"

    function script:Write-TestClaim {
        param($RunPath, $Name, $State = 'BLOCKED', $BlockReason = 'quota-shortfall', $Family = 'StandardDASv5Family',
              $Region = 'centralus', $RequestId = $null, $RequestedUtc = $null, $RegionalRequestId = $null, $RegionalRequestedUtc = $null)
        $quota = @{ limit = 2; used = 2; name = 'Standard DASv5 Family vCPUs'; requestId = $RequestId; requestedUtc = $RequestedUtc }
        if ($RegionalRequestId) { $quota.regionalRequestId = $RegionalRequestId; $quota.regionalRequestedUtc = $RegionalRequestedUtc }
        @{
            schemaVersion = 12; runId = 'r1'; wave = 'wave-1'; region = $Region; zone = $null
            subscriptionId = $script:sub
            size = 'Standard_D2as_v5'; vmFamily = $Family; state = $State
            blockReason = $BlockReason
            demand = @{ instances = 1; vcpus = 2; familyVcpus = 4 }
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
    function script:Get-TestAnswers {
        param($RunPath)
        @(Get-TestEvents -RunPath $RunPath | Where-Object { $_.step -eq 'quotaAnswer' })
    }
    # An answer of the Quota Request Status GET, in the shape Microsoft's page gives.
    function script:New-TestStatus {
        param($State, $Code = $null, $Message = 'Request processing.', $StatusCode = 200)
        $props = [ordered]@{ provisioningState = $State; message = $Message }
        if ($Code) { $props.error = @{ code = $Code; message = $Message } }
        [pscustomobject]@{ StatusCode = $StatusCode; Content = (@{ id = $script:idA; name = $script:guidA; properties = $props } | ConvertTo-Json -Depth 6) }
    }
}

AfterAll {
    Remove-Item -Path 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'QUOTA-REQUEST-POLL-1: the read of one quota request (azureops)' {
    It 'sends ONE GET to the Quota Request Status path of the subscription, region and request' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub; id = $script:idA } {
            param($sub, $id)
            Get-VmfQuotaRequestState -SubscriptionId $sub -Location 'centralus' -RequestId $id | Out-Null
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and
            $Path -eq "/subscriptions/$($script:sub)/providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/quotaRequests/$($script:guidA)?api-version=2023-02-01"
        }
    }

    It 'takes a bare request ID (the GUID) as well as the full ID' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub; id = $script:guidA } {
            param($sub, $id)
            Get-VmfQuotaRequestState -SubscriptionId $sub -Location 'centralus' -RequestId $id | Out-Null
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $Path -like "*/quotaRequests/$($script:guidA)?api-version=2023-02-01"
        }
    }

    It 'refuses a request ID, subscription or region that is not in the form Azure gives, with no call' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub; guid = $script:guidA } {
            param($sub, $guid)
            { Get-VmfQuotaRequestState -SubscriptionId $sub -Location 'centralus' -RequestId '/quota-requests/e' } | Should -Throw
            { Get-VmfQuotaRequestState -SubscriptionId $sub -Location 'centralus' -RequestId "$guid/../x" } | Should -Throw
            { Get-VmfQuotaRequestState -SubscriptionId 'not-a-sub' -Location 'centralus' -RequestId $guid } | Should -Throw
            { Get-VmfQuotaRequestState -SubscriptionId $sub -Location 'central us/../x' -RequestId $guid } | Should -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 0 -Exactly
    }
}

Describe 'QUOTA-REQUEST-POLL-1: what an answer of Azure means (pure)' {
    It 'Succeeded is APPROVED, and it is the end' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content '{"properties":{"provisioningState":"Succeeded","message":"Request completed."}}'
            $a.Answer | Should -Be 'APPROVED'
            $a.Final | Should -BeTrue
            $a.State | Should -Be 'Succeeded'
        }
    }
    It 'Failed is REFUSED, with Azure''s code and message' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content '{"properties":{"provisioningState":"Failed","message":"Request failed.","error":{"code":"QuotaNotAvailableForResource","message":"Request failed."}}}'
            $a.Answer | Should -Be 'REFUSED'
            $a.Final | Should -BeTrue
            $a.Code | Should -Be 'QuotaNotAvailableForResource'
            $a.Message | Should -Be 'Request failed.'
        }
    }
    It 'Invalid is REFUSED too: Azure will not grant it' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content '{"properties":{"provisioningState":"Invalid","message":"x"}}'
            $a.Answer | Should -Be 'REFUSED'
            $a.Final | Should -BeTrue
        }
    }
    It 'InProgress and Accepted are not an answer yet' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'InProgress', 'Accepted') {
                $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content ('{"properties":{"provisioningState":"' + $s + '"}}')
                $a.Answer | Should -Be 'WAITING'
                $a.Final | Should -BeFalse
                $a.State | Should -Be $s
            }
        }
    }
    It 'a state Microsoft does not list is not read as an answer' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content '{"properties":{"provisioningState":"Somethingnew"}}'
            $a.Answer | Should -Be 'WAITING'
            $a.Final | Should -BeFalse
        }
    }
    It 'reads the fields at the top too, the shape the lab evidence shows' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content '{"provisioningState":"Failed","message":"Request failed.","error":{"code":"QuotaNotAvailableForResource"}}'
            $a.Answer | Should -Be 'REFUSED'
            $a.Code | Should -Be 'QuotaNotAvailableForResource'
        }
    }
    It 'a refused read is NOTREAD, with the reason Azure gave, and it is not the end' {
        InModuleScope VmMigrationFactory {
            $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode 403 -Content '{"error":{"code":"AuthorizationFailed","message":"no access"}}'
            $a.Answer | Should -Be 'NOTREAD'
            $a.Final | Should -BeFalse
            $a.Reason | Should -Match 'HTTP 403 AuthorizationFailed'
        }
    }
    It 'a body that is not JSON is NOTREAD, never an answer' {
        InModuleScope VmMigrationFactory {
            (ConvertFrom-VmfQuotaRequestAnswer -StatusCode 200 -Content 'oops').Answer | Should -Be 'NOTREAD'
        }
    }
}

Describe 'QUOTA-REQUEST-POLL-1: the engine reads each filed request after Request' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qrp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
        $script:slept = [System.Collections.Generic.List[double]]::new()
        Mock -ModuleName VmMigrationFactory Start-Sleep { $script:slept.Add([double]$Seconds) }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'reads a request Azure took with 202 until Azure refuses it, and writes the answer with the request ID and code' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState {
            $script:reads++
            if ($script:reads -lt 3) { New-TestStatus -State 'InProgress' } else { New-TestStatus -State 'Failed' -Code 'QuotaNotAvailableForResource' -Message 'Request failed.' }
        }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $script:reads | Should -Be 3 -Because 'it stops reading once Azure answers'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -ParameterFilter {
            $SubscriptionId -eq $script:sub -and $Location -eq 'centralus' -and $RequestId -eq $script:idA
        } -Times 3 -Exactly
        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 1
        $answers[0].requestId | Should -Be $script:idA
        $answers[0].answer | Should -Be 'REFUSED'
        $answers[0].state | Should -Be 'Failed'
        $answers[0].code | Should -Be 'QuotaNotAvailableForResource'
        $answers[0].quotaName | Should -Be 'Standard DASv5 Family vCPUs'
        $answers[0].region | Should -Be 'centralus'
        $answers[0].detail | Should -Match $script:guidA
        $answers[0].detail | Should -Match 'QuotaNotAvailableForResource'
        # The page shows "filed" first, from the result line, then the answer.
        $steps = @(Get-TestEvents -RunPath $script:runPath | ForEach-Object step)
        [array]::IndexOf($steps, 'quotaResult') | Should -BeLessThan ([array]::IndexOf($steps, 'quotaAnswer'))
    }

    It 'writes APPROVED when Azure approves it' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' -Message 'Request completed.' }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 1
        $answers[0].answer | Should -Be 'APPROVED'
        $answers[0].outcome | Should -Be 'ok'
    }

    It 'waits at least 2 minutes for an answer, then stops and says Azure did not answer' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'InProgress' }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        ($script:slept | Measure-Object -Sum).Sum | Should -BeGreaterOrEqual 120 -Because 'the owner: at least a minute; the task: at least 2 minutes'
        ($script:slept | Measure-Object -Sum).Sum | Should -BeLessOrEqual 180 -Because 'the wait has a fixed end'
        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 1
        $answers[0].answer | Should -Be 'WAITING'
        $answers[0].state | Should -Be 'InProgress'
        $answers[0].requestId | Should -Be $script:idA
    }

    It 'the number of reads has a fixed end' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { $script:reads++; New-TestStatus -State 'InProgress' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        $script:reads | Should -BeGreaterOrEqual 2
        $script:reads | Should -BeLessOrEqual 12
    }

    It 'a read that fails each time ends as NOTREAD, with the reason' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization."}}' } }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 1
        $answers[0].answer | Should -Be 'NOTREAD'
        $answers[0].reason | Should -Match 'AuthorizationFailed'
    }

    It 'an ID that does not end with a GUID is NOTREAD at once, with no read and no wait' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/e"}' } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 0 -Exactly
        $script:slept.Count | Should -Be 0
        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 1
        $answers[0].answer | Should -Be 'NOTREAD'
    }

    It 'a read that fails after one that worked does not hide the state Azure gave' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState {
            $script:reads++
            if ($script:reads -eq 1) { New-TestStatus -State 'InProgress' } else { [pscustomobject]@{ StatusCode = 503; Content = '' } }
        }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        $a = @(Get-TestAnswers -RunPath $script:runPath)[0]
        $a.answer | Should -Be 'WAITING'
        $a.state | Should -Be 'InProgress'
    }

    It 'a read that throws does not stop the others or the engine' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState {
            $script:reads++
            if ($script:reads -eq 1) { throw 'network' } else { New-TestStatus -State 'Succeeded' }
        }
        { Request-VmfQuota -OutPath $script:runPath | Out-Null } | Should -Not -Throw
        @(Get-TestAnswers -RunPath $script:runPath)[0].answer | Should -Be 'APPROVED'
    }

    It 'a request Azure approved at once (200) is not read again' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 0 -Exactly
        @(Get-TestAnswers -RunPath $script:runPath).Count | Should -Be 0
    }

    It 'a preview reads nothing' {
        Write-TestClaim -RunPath $script:runPath -Name 'a' -State 'QUOTA_REQUESTED' -BlockReason $null -RequestId $script:idA -RequestedUtc ((Get-Date).ToUniversalTime().AddSeconds(-10).ToString('o'))
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' }
        Request-VmfQuota -OutPath $script:runPath -WhatIfOnly | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 0 -Exactly
    }

    It 'when Azure gives no ID in the body, the request ID comes from the Location header' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{ Location = "https://management.azure.com/subscriptions/$($script:sub)/providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/operationsStatus/$($script:guidB)?api-version=2023-02-01" } }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'a.json') -Raw | ConvertFrom-Json
        $claim.quota.requestId | Should -Be $script:guidB
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -ParameterFilter { $RequestId -eq $script:guidB }
    }

    It 'RESUMABLE: a re-run reads a request filed in the last 2 minutes from the stored record, and an old one not at all' {
        $recent = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('o')
        $old = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        Write-TestClaim -RunPath $script:runPath -Name 'a' -State 'QUOTA_REQUESTED' -BlockReason $null -RequestId $script:idA -RequestedUtc $recent
        Write-TestClaim -RunPath $script:runPath -Name 'b' -State 'QUOTA_REQUESTED' -BlockReason $null -Family 'StandardDDSv5Family' -RequestId $script:guidB -RequestedUtc $old
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { throw 'nothing is blocked, so nothing is filed' }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Failed' -Code 'QuotaNotAvailableForResource' }

        Request-VmfQuota -OutPath $script:runPath | Out-Null

        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 1 -Exactly -ParameterFilter { $RequestId -eq $script:idA }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 0 -Exactly -ParameterFilter { $RequestId -eq $script:guidB }
        @(Get-TestAnswers -RunPath $script:runPath).requestId | Should -Be @($script:idA)
    }

    It 'RESUMABLE: the 2 minutes count from when the request was filed, not from the re-run' {
        $recent = (Get-Date).ToUniversalTime().AddSeconds(-110).ToString('o')
        Write-TestClaim -RunPath $script:runPath -Name 'a' -State 'QUOTA_REQUESTED' -BlockReason $null -RequestId $script:idA -RequestedUtc $recent
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'InProgress' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        ($script:slept | Measure-Object -Sum).Sum | Should -BeLessOrEqual 30 -Because '110 of the 120 seconds were spent before the re-run'
        @(Get-TestAnswers -RunPath $script:runPath)[0].answer | Should -Be 'WAITING'
    }

    It 'a family request and its regional request each get their answer; one ID on two records is read once' {
        Write-TestClaim -RunPath $script:runPath -Name 'a'
        Write-TestClaim -RunPath $script:runPath -Name 'b' -Family 'StandardDASv5Family'
        $script:put = 0
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = (@{ id = $script:idA } | ConvertTo-Json) } }
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState { New-TestStatus -State 'Succeeded' }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfQuotaRequestState -Times 1 -Exactly
        @(Get-TestAnswers -RunPath $script:runPath).Count | Should -Be 1
    }

    It 'the regional request beside a family request is read too, under its own name' {
        $at = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString('o')
        Write-TestClaim -RunPath $script:runPath -Name 'a' -State 'QUOTA_REQUESTED' -BlockReason $null -RequestId $script:idA -RequestedUtc $at -RegionalRequestId $script:guidB -RegionalRequestedUtc $at
        Mock -ModuleName VmMigrationFactory Get-VmfQuotaRequestState {
            if ($RequestId -eq $script:guidB) { New-TestStatus -State 'Failed' -Code 'QuotaNotAvailableForResource' } else { New-TestStatus -State 'Succeeded' }
        }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        $answers = @(Get-TestAnswers -RunPath $script:runPath)
        $answers.Count | Should -Be 2
        ($answers | Where-Object requestId -eq $script:guidB).quotaName | Should -Be 'Total Regional vCPUs'
        ($answers | Where-Object requestId -eq $script:guidB).answer | Should -Be 'REFUSED'
        ($answers | Where-Object requestId -eq $script:idA).answer | Should -Be 'APPROVED'
    }
}

Describe 'QUOTA-REQUEST-POLL-1: the permission map' {
    BeforeAll {
        $script:map = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
    }
    It 'the execute role holds Microsoft.Quota/quotaRequests/read, Microsoft''s action for the read' {
        $ops = @($script:map.operations | Where-Object { $_.actions -contains 'Microsoft.Quota/quotaRequests/read' })
        $ops.Count | Should -Be 1
        $ops[0].role | Should -Be 'execute'
    }
    It 'it is optional: a role without it still files the request, and the page says the product could not read the answer' {
        $op = @($script:map.operations | Where-Object { $_.actions -contains 'Microsoft.Quota/quotaRequests/read' })[0]
        $op.optional | Should -BeTrue
        [string]$op.whenMissing | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-VmfQuotaRequestActions } | Should -Not -Contain 'Microsoft.Quota/quotaRequests/read'
        InModuleScope VmMigrationFactory { Get-VmfRequiredActions -Role execute -Optional } | Should -Contain 'Microsoft.Quota/quotaRequests/read'
    }
    It 'says to the operator why the product holds it' {
        [string]$script:map.operatorWhy.'Microsoft.Quota/quotaRequests/read' | Should -Match 'Request'
    }
}
