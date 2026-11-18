# azureops boundary: the bearer token of each Azure call the module makes over
# HTTP (the run store, and ARM by full path), and ARM by full path in the web
# service.
#
# FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1. MEASURED on the lab install,
# 2026-11-08: the first runspace of each new web service process signed in
# with Connect-AzAccount -Identity in 4 to 7 s (1.3 to 8.5 s), after
# Az.Accounts loaded from the managed dependencies (about 1.4 s,
# PERF-ANALYSIS-1). The request that started the process waited for both, and
# the service used the sign-in only for bearer tokens.
#
# Microsoft, "Managed identities - Azure App Service" (overview-managed-
# identity, "Connect to Azure services in app code" and "REST endpoint
# reference", read 2026-11-12): App Service and Azure Functions give an app
# with a managed identity a local token service. IDENTITY_ENDPOINT is its URL;
# IDENTITY_HEADER goes in the X-IDENTITY-HEADER header (it helps stop
# server-side request forgery, and the platform rotates it). A GET with
# resource=<resource> and api-version=2019-08-01 gives access_token and
# expires_on (seconds since 1970). With no client_id, principal_id or
# mi_res_id it is the token of the SYSTEM-assigned identity - the one identity
# the web service has (infra/platform.bicep, managedIdentities.systemAssigned).
# The CI starter function already takes its tokens this way
# (infra/ci-schedule/starter-function, Get-CiIdentityToken).
#
# WHICH RUNTIME TAKES WHICH PATH (Test-VmfTokenFromIdentityEndpoint):
#   - The web service (Azure Functions: FUNCTIONS_WORKER_RUNTIME, the same
#     marker as Test-VmfStoreHostTimeLimited, with IDENTITY_ENDPOINT and
#     IDENTITY_HEADER): the endpoint, here. It loads no Az module and does
#     not sign in.
#   - The engine job (Container Apps): Container Apps sets IDENTITY_ENDPOINT
#     too, but the job runs as a USER-assigned identity, signs in with
#     Connect-AzAccount -Identity -AccountId (docker/entrypoint.ps1) because
#     every change to a machine is an Az cmdlet, and has no
#     FUNCTIONS_WORKER_RUNTIME. So it keeps Get-AzAccessToken and
#     Invoke-AzRestMethod. A GET here with no client_id would ask for a
#     system-assigned identity the job does not have.
#   - A developer computer, the tests, and `func start` on a computer: no
#     endpoint, so Get-AzAccessToken and Invoke-AzRestMethod of the signed-in
#     Az context, as before.
#
# Never written anywhere: a token, the IDENTITY_HEADER value, or the body of a
# token answer. An error names the resource, the HTTP status and the error
# fields of a refusal only.

# One cache for the PROCESS, so every runspace of the web service uses one
# token for each resource (the store client is kept the same way:
# Get-VmfStorageHttpHolder).
$script:VmfIdentityTokenSlot = 'VmfIdentityTokens.v1'
# A kept token is used until this many seconds before it expires.
$script:VmfIdentityTokenRenewSec = 300
# How long a token request waits for the local token service, for its headers
# and then for its body.
$script:VmfIdentityTokenTimeoutMs = 30000
# Azure Resource Manager, and the resource of its tokens. The web service
# reaches the store at blob.core.windows.net, so it is the Azure public cloud.
$script:VmfArmHost = 'management.azure.com'
$script:VmfArmResource = 'https://management.azure.com/'

function Test-VmfTokenFromIdentityEndpoint {
    <#
    .SYNOPSIS
        $true in the web service (the Azure Functions host with a managed
        identity endpoint): its tokens come from IDENTITY_ENDPOINT, with no Az
        module. $false everywhere else.
    #>
    [OutputType([bool])]
    param()
    (Test-VmfStoreHostTimeLimited) -and
        -not [string]::IsNullOrEmpty($env:IDENTITY_ENDPOINT) -and
        -not [string]::IsNullOrEmpty($env:IDENTITY_HEADER)
}

function Get-VmfIdentityTokenCache {
    # The process's tokens, by resource: @{ Token; ExpiresOn }.
    [OutputType([hashtable])]
    param()
    $domain = [System.AppDomain]::CurrentDomain
    $held = $domain.GetData($script:VmfIdentityTokenSlot)
    if ($held) { return $held }
    [System.Threading.Monitor]::Enter($domain)
    try {
        $held = $domain.GetData($script:VmfIdentityTokenSlot)
        if (-not $held) {
            $held = [hashtable]::Synchronized(@{})
            $domain.SetData($script:VmfIdentityTokenSlot, $held)
        }
    }
    finally { [System.Threading.Monitor]::Exit($domain) }
    $held
}

function Send-VmfIdentityTokenRequest {
    <#
    .SYNOPSIS
        One GET to the managed identity endpoint for -ResourceUrl, over the
        process's HTTP client. StatusCode, Content (bytes) and Headers, as
        Send-VmfStorageHttpRequest gives them; throws when no answer came.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceUrl)
    $uri = [string]::Format([cultureinfo]::InvariantCulture, '{0}?resource={1}&api-version=2019-08-01',
        $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($ResourceUrl))
    Send-VmfStorageHttpRequest -Method GET -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = [string]$env:IDENTITY_HEADER } `
        -TimeoutMs $script:VmfIdentityTokenTimeoutMs -BodyTimeoutMs $script:VmfIdentityTokenTimeoutMs
}

function ConvertFrom-VmfIdentityTokenExpiry {
    # expires_on of a token answer: seconds since 1970 (api-version
    # 2019-08-01). $null when it is not that.
    param([AllowNull()]$Value)
    $seconds = 0L
    if ([long]::TryParse([string]$Value, [System.Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture, [ref]$seconds)) {
        return [DateTimeOffset]::FromUnixTimeSeconds($seconds)
    }
    $null
}

function Get-VmfIdentityEndpointToken {
    <#
    .SYNOPSIS
        The token of the web service's managed identity for -ResourceUrl, from
        the managed identity endpoint. A kept token is used until
        $script:VmfIdentityTokenRenewSec before it expires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )
    $cache = Get-VmfIdentityTokenCache
    $kept = $cache[$ResourceUrl]
    if ($kept -and $kept.ExpiresOn -gt $NowUtc.AddSeconds($script:VmfIdentityTokenRenewSec)) { return [string]$kept.Token }

    try { $answer = Send-VmfIdentityTokenRequest -ResourceUrl $ResourceUrl }
    catch {
        if ($_.Exception -is [System.TimeoutException]) {
            throw [string]::Format([cultureinfo]::InvariantCulture, 'The managed identity endpoint did not answer the token request for {0} in {1} seconds.',
                $ResourceUrl, [Math]::Round($script:VmfIdentityTokenTimeoutMs / 1000))
        }
        throw [string]::Format([cultureinfo]::InvariantCulture, 'The managed identity endpoint gave no token for {0}: {1}', $ResourceUrl, $_.Exception.Message)
    }

    # The body is read here and nowhere else: it holds the token.
    $doc = $null
    try { $doc = [System.Text.Encoding]::UTF8.GetString([byte[]]$answer.Content) | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
    if ([int]$answer.StatusCode -ne 200) {
        # Only the error fields of a refusal, never the whole body.
        $why = ''
        if ($doc) {
            $parts = @(foreach ($name in 'error', 'error_description', 'message') {
                    $p = $doc.PSObject.Properties[$name]
                    if ($p -and $p.Value -is [string] -and $p.Value) { $p.Value }
                })
            if ($parts.Count) {
                $text = $parts -join ': '
                if ($env:IDENTITY_HEADER) { $text = $text.Replace([string]$env:IDENTITY_HEADER, '<hidden>') }
                if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
                $why = ' ' + $text.TrimEnd('.') + '.'
            }
        }
        throw [string]::Format([cultureinfo]::InvariantCulture, 'The managed identity endpoint refused the token request for {0}: HTTP {1}.{2}', $ResourceUrl, [int]$answer.StatusCode, $why)
    }
    $tokenField = if ($doc) { $doc.PSObject.Properties['access_token'] }
    $token = if ($tokenField) { [string]$tokenField.Value } else { '' }
    if (-not $token) {
        throw [string]::Format([cultureinfo]::InvariantCulture, 'The managed identity endpoint answered the token request for {0} with no token.', $ResourceUrl)
    }
    $expiresOn = ConvertFrom-VmfIdentityTokenExpiry -Value $(if ($doc.PSObject.Properties['expires_on']) { $doc.expires_on })
    # A token with no expiry this can read is used for this call only.
    if ($expiresOn) { $cache[$ResourceUrl] = @{ Token = $token; ExpiresOn = $expiresOn } }
    $token
}

function Get-VmfAccessToken {
    <#
    .SYNOPSIS
        The bearer token for -ResourceUrl, as text. In the web service, from
        the managed identity endpoint (Get-VmfIdentityEndpointToken);
        everywhere else, from the signed-in Az context (Get-AzAccessToken).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ResourceUrl)
    if (Test-VmfTokenFromIdentityEndpoint) {
        Get-VmfIdentityEndpointToken -ResourceUrl $ResourceUrl
    }
    else {
        if ((Test-VmfStoreHostTimeLimited) -and -not (Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue)) {
            throw 'The web service has no managed identity endpoint (IDENTITY_ENDPOINT and IDENTITY_HEADER are not set), and the Az.Accounts module is not there.'
        }
        $t = Get-AzAccessToken -ResourceUrl $ResourceUrl
        # Az.Accounts 2.x returns a plain string, 5.x a SecureString - accept both.
        if ($t.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $t.Token).Password } else { [string]$t.Token }
    }
}

function Invoke-VmfArmHttpRequest {
    <#
    .SYNOPSIS
        One ARM request by full path, in the web service: the token from
        Get-VmfAccessToken, sent over the process's HTTP client. Gives what
        Invoke-AzRestMethod gave: StatusCode, Content (text) and Headers. Not
        counted in the call record: its callers count it.
    .DESCRIPTION
        -Path is put after https://management.azure.com. A whole -Uri (a
        nextLink) must be an https address on management.azure.com, so the
        ARM token is never sent to another host. Each wait - for the headers,
        then for the body - has the ARM limit ($script:VmfArmAnswerLimitMs),
        and a wait that reaches it throws the words Receive-VmfArmAnswer uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter()][string]$Path,
        [Parameter()][string]$Uri,
        [Parameter()][string]$Payload
    )
    if ($PSBoundParameters.ContainsKey('Uri')) {
        $parsed = $null
        if (-not [uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https' -or $parsed.Host -ne $script:VmfArmHost) {
            throw [string]::Format([cultureinfo]::InvariantCulture, 'The address {0} is not an Azure Resource Manager address (https://{1}), so the request was not sent.',
                (ConvertTo-VmfCallTarget -Kind arm -Target $Uri), $script:VmfArmHost)
        }
        $address = $Uri
        $target = $Uri
    }
    else {
        $address = 'https://' + $script:VmfArmHost + $(if ($Path.StartsWith('/')) { $Path } else { '/' + $Path })
        $target = $Path
    }
    $headers = @{ Authorization = 'Bearer ' + (Get-VmfAccessToken -ResourceUrl $script:VmfArmResource) }
    $send = @{
        Method        = $Method
        Uri           = $address
        Headers       = $headers
        TimeoutMs     = [int]$script:VmfArmAnswerLimitMs
        BodyTimeoutMs = [int]$script:VmfArmAnswerLimitMs
    }
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $headers['Content-Type'] = 'application/json'
        $send.Body = [System.Text.UTF8Encoding]::new($false).GetBytes($Payload)
    }
    try { $r = Send-VmfStorageHttpRequest @send }
    catch {
        if ($_.Exception -is [System.TimeoutException]) {
            throw ('Azure Resource Manager did not answer {0} {1} in {2} seconds: the request timed out.' -f
                $Method.ToUpperInvariant(), (ConvertTo-VmfCallTarget -Kind arm -Target $target), [int]($script:VmfArmAnswerLimitMs / 1000))
        }
        throw
    }
    [pscustomobject]@{
        StatusCode = [int]$r.StatusCode
        Content    = [System.Text.Encoding]::UTF8.GetString([byte[]]$r.Content)
        Headers    = $r.Headers
    }
}
