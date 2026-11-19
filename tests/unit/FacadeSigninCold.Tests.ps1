#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1: the web service takes its tokens
# from the managed identity endpoint, with no Az sign-in and no Az module.
#
# MEASURED on the lab install, 2026-11-08: the first runspace of each new
# service process signed in with Connect-AzAccount -Identity in 4 to 7 s
# (1.3 to 8.5 s), after Az.Accounts loaded from the managed dependencies
# (about 1.4 s, PERF-ANALYSIS-1). The request that started the process waited
# for both. The service used the sign-in only for bearer tokens: the run
# store, and ARM by full path.
#
# Microsoft, "Managed identities - Azure App Service" (overview-managed-
# identity, "REST endpoint reference", read 2026-11-12): an app with a managed
# identity has IDENTITY_ENDPOINT (the local token service) and IDENTITY_HEADER
# (sent as X-IDENTITY-HEADER, against server-side request forgery; the
# platform rotates it). A GET with resource and api-version 2019-08-01, and no
# client_id, gives a token for the system-assigned identity; expires_on is
# seconds since 1970. The web service has ONE identity, system-assigned.
#
# Which runtime takes which path (Test-VmfTokenFromIdentityEndpoint):
#   - the web service: FUNCTIONS_WORKER_RUNTIME, IDENTITY_ENDPOINT and
#     IDENTITY_HEADER are all set - the endpoint, no Az module;
#   - the engine job: Container Apps sets IDENTITY_ENDPOINT too, but there is
#     no FUNCTIONS_WORKER_RUNTIME, and the engine runs as a USER-assigned
#     identity that it signs in with (docker/entrypoint.ps1) - Az, as before;
#   - a developer computer and these tests: no endpoint - Az, as before.
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzStandIns.ps1')
    # CI has no Az module: stand-ins, so a mock has a command to replace -
    # defined BEFORE the guard (TEST-AZURE-GUARD-1).
    $script:stubs = [System.Collections.Generic.List[string]]::new()
    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) { function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }; $script:stubs.Add('Get-AzAccessToken') }
    if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) { function Global:Invoke-AzRestMethod { param($Method, $Path, $Uri, $Payload, [switch]$AsJob) throw 'stub' }; $script:stubs.Add('Invoke-AzRestMethod') }
    if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) { function Global:Get-AzContext { throw 'stub' }; $script:stubs.Add('Get-AzContext') }
    if (-not (Get-Command Update-AzConfig -ErrorAction SilentlyContinue)) { function Global:Update-AzConfig { param($EnableDataCollection, $Scope) throw 'stub' }; $script:stubs.Add('Update-AzConfig') }
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:envNames = 'FUNCTIONS_WORKER_RUNTIME', 'IDENTITY_ENDPOINT', 'IDENTITY_HEADER'
    $script:envBefore = @{}
    foreach ($n in $script:envNames) { $script:envBefore[$n] = [Environment]::GetEnvironmentVariable($n) }
    # The values the platform gives the web service. The header is a test value.
    $script:headerValue = 'header-value-0001'
    function Global:SetFscService {
        param([string]$Endpoint = 'http://127.0.0.1:9/msi/token')
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        $env:IDENTITY_ENDPOINT = $Endpoint
        $env:IDENTITY_HEADER = $script:headerValue
    }
    function Global:ClearFscEnvironment { foreach ($n in $script:envNames) { [Environment]::SetEnvironmentVariable($n, $null) } }
    function Global:ClearFscCache { InModuleScope VmMigrationFactory { (Get-VmfIdentityTokenCache).Clear() } }
    # An answer of the token endpoint, as Send-VmfStorageHttpRequest gives it.
    function Global:NewFscAnswer {
        param([int]$Status = 200, [string]$Text)
        [pscustomobject]@{ StatusCode = $Status; Content = [System.Text.UTF8Encoding]::new($false).GetBytes($Text); Headers = @{} }
    }
    function Global:NewFscTokenText {
        param([string]$Token, [long]$ExpiresOn)
        '{"access_token":"' + $Token + '","expires_on":"' + $ExpiresOn + '","resource":"https://storage.azure.com/","token_type":"Bearer","client_id":"00000000-0000-0000-0000-0000000000bb"}'
    }
}
AfterAll {
    foreach ($n in $script:envNames) { [Environment]::SetEnvironmentVariable($n, $script:envBefore[$n]) }
    try { ClearFscCache } catch { $null = $_ }
    foreach ($s in $script:stubs) { Remove-Item -Path ('function:' + $s) -ErrorAction SilentlyContinue }
    Remove-Item 'function:\SetFscService', 'function:\ClearFscEnvironment', 'function:\ClearFscCache', 'function:\NewFscAnswer', 'function:\NewFscTokenText' -ErrorAction SilentlyContinue
}

Describe 'FACADE-SIGNIN-COLD-1: which runtime takes the identity endpoint' {
    AfterEach { ClearFscEnvironment }

    It 'the web service (Functions, IDENTITY_ENDPOINT and IDENTITY_HEADER) takes it' {
        SetFscService
        InModuleScope VmMigrationFactory { Test-VmfTokenFromIdentityEndpoint } | Should -BeTrue
    }

    It 'it does not when <Name>' -ForEach @(
        @{ Name = 'the process is not the Functions service (the engine job: Container Apps sets the endpoint too)'; Drop = 'FUNCTIONS_WORKER_RUNTIME' }
        @{ Name = 'there is no IDENTITY_ENDPOINT (a developer computer, func start)'; Drop = 'IDENTITY_ENDPOINT' }
        @{ Name = 'there is no IDENTITY_HEADER'; Drop = 'IDENTITY_HEADER' }) {
        SetFscService
        [Environment]::SetEnvironmentVariable($Drop, $null)
        InModuleScope VmMigrationFactory { Test-VmfTokenFromIdentityEndpoint } | Should -BeFalse
    }

    It 'the facade module asks the same question of the engine module' {
        SetFscService
        InModuleScope FacadeCore { Test-VmfFacadeTokenFromIdentityEndpoint } | Should -BeTrue
        ClearFscEnvironment
        InModuleScope FacadeCore { Test-VmfFacadeTokenFromIdentityEndpoint } | Should -BeFalse
    }

    It 'the engine runs as a user-assigned identity that it signs in with, so it must never take the endpoint' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        $entry | Should -Match 'Connect-AzAccount -Identity -AccountId \$env:AZURE_CLIENT_ID' -Because 'a GET with no client_id would ask for a system-assigned identity the job does not have'
        $entry | Should -Not -Match 'FUNCTIONS_WORKER_RUNTIME'
        $platform = Get-VmfCodeOnly -Path (Join-Path $script:repo 'infra' 'platform.bicep') -Language CStyle
        $platform | Should -Match "FUNCTIONS_WORKER_RUNTIME:\s*'powershell'"
        $platform | Should -Match 'systemAssigned:\s*true' -Because 'the endpoint gives the system-assigned identity when no client_id is named'
    }
}

Describe 'FACADE-SIGNIN-COLD-1: the token from the identity endpoint' {
    BeforeEach { ClearFscCache; SetFscService }
    AfterEach { ClearFscCache; ClearFscEnvironment }

    It 'asks once for each resource, and keeps the token until close to its expiry' {
        $script:asked = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest {
            $script:asked.Add($ResourceUrl)
            NewFscAnswer -Text (NewFscTokenText -Token ('tok-' + $script:asked.Count) -ExpiresOn ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()))
        }
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'tok-1'
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'tok-1'
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://management.azure.com/' } | Should -Be 'tok-2'
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://management.azure.com/' } | Should -Be 'tok-2'
        $script:asked | Should -Be @('https://storage.azure.com/', 'https://management.azure.com/')
    }

    It 'asks again for a token that expires within 5 minutes, and keeps one with more time' {
        $now = [DateTimeOffset]::UtcNow
        InModuleScope VmMigrationFactory -Parameters @{ Now = $now } {
            param($Now)
            (Get-VmfIdentityTokenCache)['https://storage.azure.com/'] = @{ Token = 'old'; ExpiresOn = $Now.AddSeconds(299) }
            (Get-VmfIdentityTokenCache)['https://management.azure.com/'] = @{ Token = 'kept'; ExpiresOn = $Now.AddSeconds(301) }
        }
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest {
            NewFscAnswer -Text (NewFscTokenText -Token 'new' -ExpiresOn ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()))
        }
        InModuleScope VmMigrationFactory -Parameters @{ Now = $now } { param($Now) Get-VmfIdentityEndpointToken -ResourceUrl 'https://storage.azure.com/' -NowUtc $Now } | Should -Be 'new'
        InModuleScope VmMigrationFactory -Parameters @{ Now = $now } { param($Now) Get-VmfIdentityEndpointToken -ResourceUrl 'https://management.azure.com/' -NowUtc $Now } | Should -Be 'kept'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest -Times 1 -Exactly
    }

    It 'keeps the expiry the endpoint gives, in seconds since 1970' {
        $at = [DateTimeOffset]::UtcNow.AddMinutes(42)
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Text (NewFscTokenText -Token 'tok' -ExpiresOn $at.ToUnixTimeSeconds()) }
        $null = InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' }
        $kept = InModuleScope VmMigrationFactory { (Get-VmfIdentityTokenCache)['https://storage.azure.com/'] }
        $kept.ExpiresOn.ToUnixTimeSeconds() | Should -Be $at.ToUnixTimeSeconds()
    }

    It 'a token with an expiry it cannot read is used once and not kept' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Text '{"access_token":"tok","expires_on":"soon"}' }
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'tok'
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'tok'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest -Times 2 -Exactly
    }

    It 'the cache is the process''s: a second runspace finds the token the first one got' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest {
            NewFscAnswer -Text (NewFscTokenText -Token 'shared' -ExpiresOn ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()))
        }
        $null = InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' }
        $modulePath = Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript({ param($m) Import-Module $m; & (Get-Module VmMigrationFactory) { (Get-VmfIdentityTokenCache)['https://storage.azure.com/'].Token } }).AddArgument($modulePath)
            @($ps.Invoke())[0] | Should -Be 'shared'
        }
        finally { $ps.Dispose() }
    }

    It 'the request is a GET to IDENTITY_ENDPOINT with the resource, api-version 2019-08-01, the identity header and no client_id' {
        $identity = [VmfFakeIdentity]::new('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000aa')
        try {
            SetFscService -Endpoint "$($identity.BaseUri)msi/token"
            InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'stand-in-token'
            $paths = @($identity.Paths.ToArray())
            $paths.Count | Should -Be 1
            $paths[0] | Should -Be '/msi/token?resource=https%3A%2F%2Fstorage.azure.com%2F&api-version=2019-08-01'
            $paths[0] | Should -Not -Match 'client_id|principal_id|mi_res_id|object_id' -Because 'the web service has one identity, system-assigned'
            @($identity.IdentityHeaders.ToArray()) | Should -Be @($script:headerValue)
        }
        finally { $identity.Dispose() }
    }

    It 'an endpoint that does not answer fails with a clear error that names the resource' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { throw [System.Net.Http.HttpRequestException]::new('No connection could be made because the target machine actively refused it.') }
        { InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } } |
            Should -Throw 'The managed identity endpoint gave no token for https://storage.azure.com/: No connection could be made*'
    }

    It 'an endpoint that answers in no time limit says it did not answer, not that the run store did not' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { throw [System.TimeoutException]::new('No answer from the run store in 30 seconds: the request timed out.') }
        $err = $null
        try { InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } } catch { $err = $_.Exception.Message }
        $err | Should -Be 'The managed identity endpoint did not answer the token request for https://storage.azure.com/ in 30 seconds.'
    }

    It 'a refused request names the HTTP status and the error the endpoint gives' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Status 400 -Text '{"error":"invalid_request","error_description":"No managed identity is set up for this app."}' }
        { InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } } |
            Should -Throw 'The managed identity endpoint refused the token request for https://storage.azure.com/: HTTP 400. invalid_request: No managed identity is set up for this app.'
    }

    It 'an answer with no token fails, and nothing is kept' {
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Text '{"token_type":"Bearer"}' }
        { InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } } |
            Should -Throw 'The managed identity endpoint answered the token request for https://storage.azure.com/ with no token.'
        InModuleScope VmMigrationFactory { (Get-VmfIdentityTokenCache).Count } | Should -Be 0
    }

    It 'no token, no identity header and no token answer is in any output, on success or failure' {
        $secret = 'eyJ0eXAi-secret-token-value'
        $streams = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Text (NewFscTokenText -Token $secret -ExpiresOn ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())) }
        $all = InModuleScope VmMigrationFactory { Get-VmfIdentityEndpointToken -ResourceUrl 'https://storage.azure.com/' *>&1 }
        @($all).Count | Should -Be 1 -Because 'the token is the one thing written, to the caller, and nothing goes to another stream'
        ClearFscCache
        # A refused answer that carries a token-like field and the header value.
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest {
            NewFscAnswer -Status 500 -Text ('{"error":"x","error_description":"' + $script:headerValue + '","access_token":"' + $secret + '"}')
        }
        foreach ($rec in @(InModuleScope VmMigrationFactory { try { Get-VmfIdentityEndpointToken -ResourceUrl 'https://storage.azure.com/' *>&1 } catch { $_ } })) { $streams.Add([string]$rec); if ($rec -is [System.Management.Automation.ErrorRecord]) { $streams.Add($rec.Exception.ToString()) } }
        # A good answer that is not JSON.
        ClearFscCache
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { NewFscAnswer -Text ('access_token=' + $secret) }
        foreach ($rec in @(InModuleScope VmMigrationFactory { try { Get-VmfIdentityEndpointToken -ResourceUrl 'https://storage.azure.com/' *>&1 } catch { $_ } })) { $streams.Add([string]$rec); if ($rec -is [System.Management.Automation.ErrorRecord]) { $streams.Add($rec.Exception.ToString()) } }
        $streams.Count | Should -BeGreaterThan 1
        foreach ($s in $streams) {
            $s | Should -Not -Match ([regex]::Escape($secret))
            $s | Should -Not -Match ([regex]::Escape($script:headerValue))
        }
    }

    It 'the store, the reads sent together and ARM take their tokens from the same place' {
        foreach ($fn in 'Invoke-VmfStorageRequestCore', 'Invoke-VmfStorageGetMany', 'Invoke-VmfArmHttpRequest') {
            $body = InModuleScope VmMigrationFactory -Parameters @{ F = $fn } { param($F) (Get-Command $F).ScriptBlock.Ast.Body }
            $calls = @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            $calls | Should -Contain 'Get-VmfAccessToken' -Because $fn
            $calls | Should -Not -Contain 'Get-AzAccessToken' -Because "$fn asks Get-VmfAccessToken, which chooses the path"
        }
    }
}

Describe 'FACADE-SIGNIN-COLD-1: outside the web service, the tokens come from Az as before' {
    BeforeEach { ClearFscCache; ClearFscEnvironment }

    It 'with no endpoint, Get-VmfAccessToken asks Get-AzAccessToken and gives the token as text (<Kind>)' -ForEach @(
        @{ Kind = 'a SecureString, Az.Accounts 5' ; Secure = $true }
        @{ Kind = 'a string, Az.Accounts 2'; Secure = $false }) {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken {
            if ($Secure) { [pscustomobject]@{ Token = (ConvertTo-SecureString 'az-token' -AsPlainText -Force) } } else { [pscustomobject]@{ Token = 'az-token' } }
        }
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { throw 'must not be called' }
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'az-token'
        Should -Invoke -ModuleName VmMigrationFactory Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://storage.azure.com/' }
    }

    It 'the engine job (Container Apps sets IDENTITY_ENDPOINT, no Functions) asks Get-AzAccessToken' {
        $env:IDENTITY_ENDPOINT = 'http://127.0.0.1:9/msi/token'; $env:IDENTITY_HEADER = $script:headerValue
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'engine-token' } }
        Mock -ModuleName VmMigrationFactory Send-VmfIdentityTokenRequest { throw 'must not be called' }
        InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } | Should -Be 'engine-token'
        ClearFscEnvironment
    }

    It 'in the Functions host with no endpoint and no Az module, it says so instead of a command that is not found' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        try {
            Mock -ModuleName VmMigrationFactory Get-Command { $null } -ParameterFilter { $Name -eq 'Get-AzAccessToken' }
            { InModuleScope VmMigrationFactory { Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/' } } |
                Should -Throw 'The web service has no managed identity endpoint (IDENTITY_ENDPOINT and IDENTITY_HEADER are not set), and the Az.Accounts module is not there.'
        }
        finally { ClearFscEnvironment }
    }
}

Describe 'FACADE-SIGNIN-COLD-1: ARM by full path in the web service' {
    BeforeEach {
        ClearFscCache; SetFscService
        InModuleScope VmMigrationFactory { (Get-VmfIdentityTokenCache)['https://management.azure.com/'] = @{ Token = 'arm-token'; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) } }
        $script:sent = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $script:sent.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $(if ($null -ne $Body) { [System.Text.Encoding]::UTF8.GetString($Body) }); TimeoutMs = $TimeoutMs; BodyTimeoutMs = $BodyTimeoutMs })
            [pscustomobject]@{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}'); Headers = @{ 'x-ms-request-id' = @('r1') } }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw 'the web service has no Az module' }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'the web service has no Az module' }
    }
    AfterEach { ClearFscCache; ClearFscEnvironment }

    It 'Invoke-VmfArmRequest sends -Path to management.azure.com with the ARM token, and gives StatusCode and Content as text' {
        $r = InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method GET -Path '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Features/providers/Microsoft.Compute/features/x?api-version=2021-07-01' }
        $r.StatusCode | Should -Be 200
        $r.Content | Should -Be '{"ok":true}'
        $script:sent.Count | Should -Be 1
        $script:sent[0].Method | Should -Be 'GET'
        $script:sent[0].Uri | Should -Be 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Features/providers/Microsoft.Compute/features/x?api-version=2021-07-01'
        $script:sent[0].Headers.Authorization | Should -Be 'Bearer arm-token'
        $script:sent[0].Body | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'a -Payload goes as the JSON body' {
        $null = InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method POST -Path '/x/start?api-version=2025-01-01' -Payload '{"a":1}' }
        $script:sent[0].Method | Should -Be 'POST'
        $script:sent[0].Body | Should -Be '{"a":1}'
        $script:sent[0].Headers['Content-Type'] | Should -Be 'application/json'
    }

    It 'a nextLink -Uri on management.azure.com is sent as it is' {
        $null = InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method GET -Uri 'https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=abc' }
        $script:sent[0].Uri | Should -Be 'https://management.azure.com/subscriptions?api-version=2022-12-01&$skiptoken=abc'
    }

    It 'a -Uri on another host is refused, and the ARM token is never sent there (<Uri>)' -ForEach @(
        @{ Uri = 'https://contoso.example.com/subscriptions?api-version=1' }
        @{ Uri = 'http://management.azure.com/subscriptions?api-version=1' }
        @{ Uri = 'https://management.azure.com.example.com/x' }) {
        { InModuleScope VmMigrationFactory -Parameters @{ U = $Uri } { param($U) Invoke-VmfArmRequest -Method GET -Uri $U } } |
            Should -Throw '*not an Azure Resource Manager address*'
        $script:sent.Count | Should -Be 0
    }

    It 'an ARM request that waits past the limit says Azure Resource Manager did not answer, and each wait has the ARM limit' {
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { $script:sent.Add([pscustomobject]@{ TimeoutMs = $TimeoutMs; BodyTimeoutMs = $BodyTimeoutMs }); throw [System.TimeoutException]::new('No answer from the run store in 100 seconds: the request timed out.') }
        $err = $null
        try { InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method GET -Path '/subscriptions?api-version=2022-12-01' } } catch { $err = $_.Exception.Message }
        $err | Should -Be 'Azure Resource Manager did not answer GET subscriptions in 100 seconds: the request timed out.' -Because 'the target as the timing line and Receive-VmfArmAnswer name it'
        $limit = InModuleScope VmMigrationFactory { $script:VmfArmAnswerLimitMs }
        $script:sent[0].TimeoutMs | Should -Be $limit
        $script:sent[0].BodyTimeoutMs | Should -Be $limit
    }

    It 'the ARM request is counted once in the call record' {
        Mock -ModuleName VmMigrationFactory Add-VmfCallTiming { }
        $null = InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method GET -Path '/subscriptions?api-version=2022-12-01' }
        Should -Invoke -ModuleName VmMigrationFactory Add-VmfCallTiming -Times 1 -Exactly -ParameterFilter { $Kind -eq 'arm' }
    }

    It 'the facade''s own ARM request takes the same path, counted once' {
        Mock -ModuleName VmMigrationFactory Add-VmfCallTiming { }
        $r = InModuleScope FacadeCore { Send-VmfFacadeArmRequest -Method GET -Path '/subscriptions?api-version=2022-12-01' }
        $r.StatusCode | Should -Be 200
        $r.Content | Should -Be '{"ok":true}'
        $script:sent[0].Uri | Should -Be 'https://management.azure.com/subscriptions?api-version=2022-12-01'
        Should -Invoke -ModuleName FacadeCore Invoke-AzRestMethod -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Add-VmfCallTiming -Times 1 -Exactly -ParameterFilter { $Kind -eq 'arm' }
    }

    It 'outside the web service, both ARM requests still go through Invoke-AzRestMethod' {
        ClearFscEnvironment
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 204; Content = '' } }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 202; Content = '' } }
        (InModuleScope VmMigrationFactory { Invoke-VmfArmRequest -Method GET -Path '/x' }).StatusCode | Should -Be 204
        (InModuleScope FacadeCore { Send-VmfFacadeArmRequest -Method GET -Path '/x' }).StatusCode | Should -Be 202
        $script:sent.Count | Should -Be 0
    }
}

Describe 'FACADE-SIGNIN-COLD-1: the web service has no Az context to read' {
    AfterEach { ClearFscEnvironment }

    It 'Get-VmfSignedInIdentity in the web service says the user must be named, and reads no Az context' {
        SetFscService
        Mock -ModuleName VmMigrationFactory Get-AzContext { throw 'must not be called' }
        { InModuleScope VmMigrationFactory { Get-VmfSignedInIdentity } } | Should -Throw 'The web service has no Az sign-in. Give the identity of the signed-in user.'
        Should -Invoke -ModuleName VmMigrationFactory Get-AzContext -Times 0 -Exactly
    }

    It 'Set-VmfAzDataCollectionOff in the web service changes nothing: there is no Az module' {
        SetFscService
        # As if Az.Accounts were loaded, so only the web service's rule can say notLoaded.
        Mock -ModuleName VmMigrationFactory Get-Module { [pscustomobject]@{ Name = 'Az.Accounts' } } -ParameterFilter { $Name -eq 'Az.Accounts' }
        Mock -ModuleName VmMigrationFactory Update-AzConfig { throw 'must not be called' }
        InModuleScope VmMigrationFactory { Set-VmfAzDataCollectionOff } | Should -Be 'notLoaded'
        Should -Invoke -ModuleName VmMigrationFactory Update-AzConfig -Times 0 -Exactly
    }

    It 'the daily cleanup preview names its own caller, so it never asks for a sign-in' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repo 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1'), [ref]$null, [ref]$null)
        $call = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-VmfExpiredSafetyCopies' }, $true))
        $call.Count | Should -Be 1
        $call[0].Extent.Text | Should -Match "-DeletedBy 'retention \(scheduled\)'"
    }
}

Describe 'FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1: the service loads no Az module and does not sign in' {
    BeforeAll {
        $script:app = Join-Path $script:repo 'src' 'facade' 'app'
        $script:profileAst = [System.Management.Automation.Language.Parser]::ParseInput((Get-VmfCodeOnly -Path (Join-Path $script:app 'profile.ps1')), [ref]$null, [ref]$null)
    }

    It 'profile.ps1 never calls Connect-AzAccount, or any Az command' {
        $names = @($script:profileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $names | Should -Not -Contain 'Connect-AzAccount'
        @($names | Where-Object { $_ -match '^[A-Za-z]+-Az[A-Z]' }) | Should -BeNullOrEmpty -Because 'PERF-PROFILE-1: never a second sign-in in a signed-in process, and now never a first one'
    }

    It 'profile.ps1 imports only the two modules of the service, and never Az.Accounts' {
        $imports = @($script:profileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
        $imports.Count | Should -Be 2
        ($imports.Extent.Text -join ' ') | Should -Not -Match 'Az\.'
    }

    It 'the service takes no module from managed dependencies: no requirements.psd1, and managedDependency off' {
        Test-Path (Join-Path $script:app 'requirements.psd1') | Should -BeFalse
        (Get-Content (Join-Path $script:app 'host.json') -Raw | ConvertFrom-Json).managedDependency.enabled | Should -BeFalse
    }

    It 'the install gives the web service no setting that only the sign-in used' {
        $platform = Get-VmfCodeOnly -Path (Join-Path $script:repo 'infra' 'platform.bicep') -Language CStyle
        $platform | Should -Not -Match 'VMF_TENANT_ID'
    }
}
