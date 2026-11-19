# CSP-AZUREWEBSITES-1: the web.config the dashboard publish ships, with the
# product's OWN service named in the content security policy.
#
# The policy used to allow `https://*.azurewebsites.net`. App Service names are
# handed out first-come across the whole of Azure, so that let a page holding
# an access token connect to a site anybody can create. The install knows the
# one service the page calls - it is the apiUrl it writes into
# dashboard.config.json - so the template (src/dashboard/web.config) carries a
# marker in connect-src and this writes the ORIGIN of that address there.
#
# Pure text in, text out: no Azure call, so tests/unit/CspServiceHost.Tests.ps1
# runs it.

function Get-VmfDashboardWebConfig {
    [CmdletBinding()]
    param(
        # The text of src/dashboard/web.config.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        # The service address the page configuration names (apiUrl). Empty
        # means no service is deployed: the policy then names no service.
        [AllowEmptyString()][AllowNull()][string]$ApiUrl
    )

    $marker = '{vmf-service-origin}'
    $header = [regex]::Match($Template, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"')
    if (-not $header.Success) {
        throw 'The dashboard web.config has no Content-Security-Policy header with value=. Refusing to publish a page with no policy.'
    }
    $policy = $header.Groups['v'].Value

    $count = ([regex]::Matches($policy, [regex]::Escape($marker))).Count
    if ($count -ne 1) {
        throw "The dashboard web.config policy holds the service marker $marker $count times, not once. The publish cannot write the service address."
    }
    if (-not [regex]::IsMatch($policy, "(?:^|;)\s*connect-src\s[^;]*" + [regex]::Escape($marker))) {
        throw "The service marker $marker is not in connect-src. Only connect-src may reach the service."
    }

    # A wildcard host in ANY directive admits sites nobody here controls.
    foreach ($part in $policy -split ';') {
        foreach ($source in @($part.Trim() -split '\s+' | Select-Object -Skip 1)) {
            if ($source.Contains('*')) {
                throw "The dashboard web.config policy holds the wildcard source '$source'. Name the exact host instead."
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
        $newPolicy = $policy.Replace(" $marker", '')
    }
    else {
        $uri = $null
        if (-not [uri]::TryCreate($ApiUrl, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            throw "The service address '$ApiUrl' is not an absolute https address. The page sends a token to it."
        }
        # One exact host: letters, digits, hyphens and dots. No wildcard, no
        # user part, and nothing that could end the source or the header.
        if ($uri.UserInfo -or $uri.Host -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' -or
            $ApiUrl -match '[\s;"''*,]') {
            throw "The service address '$ApiUrl' does not name one exact host."
        }
        $origin = 'https://' + $uri.Host.ToLowerInvariant() + $(if ($uri.IsDefaultPort) { '' } else { ':' + $uri.Port })
        $newPolicy = $policy.Replace($marker, $origin)
    }

    $Template.Substring(0, $header.Groups['v'].Index) + $newPolicy +
        $Template.Substring($header.Groups['v'].Index + $header.Groups['v'].Length)
}
