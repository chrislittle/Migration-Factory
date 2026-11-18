#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREVIEW-RG-SCOPE-1: what the product says about a read of the preview
# feature VMTempDiskResizePreview that fails, and about a role granted on a
# resource group.
#
# THE DEFECT. When the read failed, the targets step said only "The product
# could not read the feature there": the web service dropped the answer of
# Azure, so a person could not tell a refusal (AuthorizationFailed) from a
# fault, and was not told what to do.
#
# THE RULE (2026-11-11). A read that fails stays "not checked" -
# never Registered, never NotRegistered - and carries the error code that
# Azure gave: to the stop of Checking (with the HTTP status) and to the
# targets step (the code only; tests/js/preview-rg-scope.test.js holds the
# box). PREVIEW-ACCESS-WORDS-1 (measured 2026-11-13: a role on one resource
# group only read the feature) removed the Admin line and the words that a
# resource group grant does not reach the read; tests/unit/PreviewAccessWords.Tests.ps1
# holds those words now.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in with the one shape the mocks take
    # (TEST-AZURE-GUARD-1), defined before the guard.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:PrsRead([int]$Code, [string]$Content) {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '/features/' } {
            [pscustomobject]@{ StatusCode = $Code; Content = $Content } }.GetNewClosure()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '^/subscriptions/[^/]+\?' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Applications"}' } }
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
    }
}
AfterAll {
    Remove-Item 'function:\PrsRead', 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-prs-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'PREVIEW-RG-SCOPE-1: a read that fails carries the answer of Azure (azureops)' {
    It 'HTTP 403 with AuthorizationFailed: not checked, with the status and the code' {
        $r = PrsRead -Code 403 -Content '{"error":{"code":"AuthorizationFailed","message":"The client does not have authorization."}}'
        $r.Read | Should -BeFalse
        $r.Registered | Should -BeFalse
        $r.State | Should -BeNullOrEmpty
        $r.Status | Should -Be 403
        $r.ErrorCode | Should -Be 'AuthorizationFailed'
        $r.Detail | Should -Match 'HTTP 403, AuthorizationFailed'
    }
    It 'an error with no code gives the status and no code' {
        $r = PrsRead -Code 500 -Content ''
        $r.Read | Should -BeFalse
        $r.Status | Should -Be 500
        $r.ErrorCode | Should -Be ''
        $r.Detail | Should -Match 'HTTP 500\)'
    }
    It 'a code that is not a plain Azure code (<Case>) is not passed on' -ForEach @(
        @{ Case = 'markup'; Code = '<b>x</b>' }
        @{ Case = 'a sentence'; Code = 'Access is denied for you' }
        @{ Case = 'too long'; Code = ('A' * 81) }
    ) {
        $body = @{ error = @{ code = $Code } } | ConvertTo-Json -Compress
        $r = PrsRead -Code 403 -Content $body
        $r.Read | Should -BeFalse
        $r.Status | Should -Be 403
        $r.ErrorCode | Should -Be ''
    }
    It 'a top-level code (the Features provider shape) is read too' {
        $r = PrsRead -Code 404 -Content '{"code":"FeatureNotFound","message":"x"}'
        $r.ErrorCode | Should -Be 'FeatureNotFound'
    }
    It 'a read that works has the status 200 and no code' {
        $r = PrsRead -Code 200 -Content '{"properties":{"state":"Registered"}}'
        $r.Read | Should -BeTrue
        $r.Status | Should -Be 200
        $r.ErrorCode | Should -Be ''
    }
    It 'a call that throws has no status and no code: Azure gave no answer' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw 'network down' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } { param($s) Get-VmfPreviewFeatureState -SubscriptionId $s }
        $r.Read | Should -BeFalse
        $r.Status | Should -Be 0
        $r.ErrorCode | Should -Be ''
    }
}

Describe 'PREVIEW-RG-SCOPE-1: the stop of Checking names the answer' {
    It 'previewFeatureNotRead says HTTP 403 and AuthorizationFailed' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '/features/' } {
            [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -match '^/subscriptions/[^/]+\?' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"displayName":"Applications"}' } }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-prs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $stop = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub; rp = $rp } {
            param($s, $rp)
            Initialize-VmfRun -RunPath $rp -RunId 'prs' | Out-Null
            $entry = [pscustomobject]@{ target = [pscustomobject]@{ path = 'A'; choice = [pscustomobject]@{ method = 'preview' } } }
            Get-VmfPreviewFeatureGate -Context @{ SubscriptionId = $s; RunPath = $rp; VmId = 'vm' } -PlanEntry $entry
        }
        $stop.Reason | Should -Be 'previewFeatureNotRead'
        $stop.MachineState | Should -Be 'untouched'
        $stop.Detail | Should -Match 'HTTP 403, AuthorizationFailed'
    }
}

Describe 'PREVIEW-RG-SCOPE-1: the web service gives the targets step the answer' {
    BeforeAll {
        function Global:PrsPrincipal {
            $claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }, @{ typ = 'roles'; val = 'Vmf.Viewer' })
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5))))
        }
    }
    AfterAll { Remove-Item 'function:\PrsPrincipal' -ErrorAction SilentlyContinue }

    It 'not read: read false, with httpStatus and errorCode' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState {
            @{ Read = $false; Registered = $false; State = $null; SubscriptionName = 'Applications'; Status = 403; ErrorCode = 'AuthorizationFailed'
               Detail = 'Azure did not give the state of VMTempDiskResizePreview (HTTP 403, AuthorizationFailed)' } }
        $r = Get-VmfFacadePreviewFeature -Principal (PrsPrincipal) -SubscriptionId $script:sub
        $r.read | Should -BeFalse
        $r.registered | Should -BeFalse
        $r.httpStatus | Should -Be 403
        $r.errorCode | Should -Be 'AuthorizationFailed'
    }
    It 'no answer: httpStatus 0 and no code' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState {
            @{ Read = $false; Registered = $false; State = $null; SubscriptionName = 'Applications'; Status = 0; ErrorCode = ''; Detail = 'the read failed' } }
        $r = Get-VmfFacadePreviewFeature -Principal (PrsPrincipal) -SubscriptionId $script:sub
        $r.httpStatus | Should -Be 0
        $r.errorCode | Should -Be ''
    }
}

Describe 'PREVIEW-RG-SCOPE-1: the words of the targets step, the Admin page, the manual and the map' {
    It 'the targets step has no role sentence, no HTTP status and no portal steps in its help' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Language CStyle
        $code | Should -Not -Match 'tPreviewRole|tPreviewAnswer|tPreviewPortal|tPreviewWait'
        $code | Should -Not -Match 'must be on the subscription|covers this read|Azure gave the answer'
        $code | Should -Match "tPvAuthStep: 'Open the Admin page\. Under Where the product may work, give Assess on subscription \{sub\}\.'"
    }
    It 'the manual page of the targets step says the approved words and no HTTP status' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
        $page | Should -Not -Match 'not only on a resource group|covers this read|Azure gave the answer'
        $page | Should -Match 'Error code from Azure: AuthorizationFailed\.'
    }
    It 'the permission map says the read is of the subscription, with the lab item and the measurement on a resource group grant' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json -Depth 20
        $text = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' } | ForEach-Object { $_.why }) -join ' '
        $text | Should -Match 'resource of the SUBSCRIPTION'
        $text | Should -Match 'PREVIEW-RG-SCOPE-LAB-1'
        $text | Should -Match 'on ONE resource group only'
    }
}