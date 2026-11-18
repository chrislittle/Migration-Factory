#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CSP-AZUREWEBSITES-1: the dashboard's content security policy names the
# product's OWN service, never every site on azurewebsites.net.
#
# Until 2026-11-12 web.config sent `connect-src ... https://*.azurewebsites.net`.
# App Service names are handed out first-come across the whole of Azure, so
# that wildcard let a page that has an access token in memory connect to a site
# anybody can create. The install knows the one service the page calls - it
# writes that address into dashboard.config.json as apiUrl - so the publish now
# writes the same origin into the policy, and the template carries a marker in
# its place.
#
# The rules:
#   - no directive of the policy in the repository holds a wildcard host;
#   - connect-src holds the marker exactly once, so the publish has one place
#     to write the service;
#   - Get-VmfDashboardWebConfig writes the ORIGIN of apiUrl (https only, no
#     wildcard, no path), or removes the marker when no service is deployed,
#     and refuses a template with no marker or two;
#   - the publish writes the result of that function, from the same apiUrl it
#     writes into dashboard.config.json, into the web.config it ships.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:helper = Join-Path $script:repoRoot 'infra' 'Get-VmfDashboardWebConfig.ps1'
    if (Test-Path -LiteralPath $script:helper) { . $script:helper }
    $script:template = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'web.config'))
    $script:marker = '{vmf-service-origin}'

    # The policy a web.config sends, as directive -> sources.
    function script:Get-VmfPolicyMap([string]$WebConfig) {
        $value = [regex]::Match($WebConfig, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"').Groups['v'].Value
        $policy = [ordered]@{}
        foreach ($part in $value -split ';') {
            $tokens = @($part.Trim() -split '\s+' | Where-Object { $_ })
            if ($tokens.Count) { $policy[$tokens[0].ToLowerInvariant()] = @($tokens | Select-Object -Skip 1) }
        }
        $policy
    }

    # Every source in any directive whose host part holds a wildcard.
    function script:Find-VmfWildcardSources([System.Collections.IDictionary]$Policy) {
        foreach ($directive in $Policy.Keys) {
            foreach ($source in $Policy[$directive]) {
                if ($source -match '\*') { "$directive $source" }
            }
        }
    }

    $script:facadeApi = 'https://vmf-facade-contoso.azurewebsites.net/api'
}

Describe 'CSP-AZUREWEBSITES-1: the policy in the repository names no wildcard host' {
    It 'reads a policy, so the checks below cannot pass on nothing' {
        $policy = Get-VmfPolicyMap $script:template
        $policy.Keys | Should -Contain 'connect-src'
        $policy.Keys | Should -Contain 'default-src'
    }

    It 'no directive holds a wildcard host' {
        @(Find-VmfWildcardSources (Get-VmfPolicyMap $script:template)) -join '; ' |
            Should -BeNullOrEmpty -Because 'a wildcard on a shared domain admits sites anybody can create'
    }

    It 'connect-src holds the service marker exactly once, and no other directive holds it' {
        $policy = Get-VmfPolicyMap $script:template
        @($policy['connect-src'] | Where-Object { $_ -eq $script:marker }).Count | Should -Be 1
        foreach ($directive in $policy.Keys) {
            if ($directive -eq 'connect-src') { continue }
            $policy[$directive] | Should -Not -Contain $script:marker -Because "$directive must not reach the service"
        }
    }

    It 'the wildcard check finds a wildcard in any directive (fixture)' {
        foreach ($bad in "connect-src 'self' https://*.azurewebsites.net", "frame-src https://*.example.com", "img-src *") {
            $text = '<add name="Content-Security-Policy" value="default-src ''self''; ' + $bad + '" />'
            @(Find-VmfWildcardSources (Get-VmfPolicyMap $text)).Count | Should -Be 1 -Because $bad
        }
    }
}

Describe 'CSP-AZUREWEBSITES-1: the publish writes the exact service origin into the policy' {
    It 'the helper exists, so the publish has one place that writes the policy' {
        Test-Path -LiteralPath $script:helper | Should -BeTrue
        Get-Command Get-VmfDashboardWebConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'writes the origin of the service address, and nothing else changes' {
        $out = Get-VmfDashboardWebConfig -Template $script:template -ApiUrl $script:facadeApi
        $policy = Get-VmfPolicyMap $out
        $policy['connect-src'] | Should -Contain 'https://vmf-facade-contoso.azurewebsites.net'
        $policy['connect-src'] | Should -Not -Contain $script:marker
        @(Find-VmfWildcardSources $policy) | Should -BeNullOrEmpty
        $out | Should -Not -Match '/api[ ;"]' -Because 'a source with a path admits only that path; the origin is what the page calls'
        $out | Should -Be ($script:template.Replace($script:marker, 'https://vmf-facade-contoso.azurewebsites.net')) -Because 'only the marker changes'
    }

    It 'the result is still a web.config IIS reads: well formed, value= and not content=' {
        $out = Get-VmfDashboardWebConfig -Template $script:template -ApiUrl $script:facadeApi
        { [xml]$out } | Should -Not -Throw
        $out | Should -Match '<add name="Content-Security-Policy"\s+value="'
        ([regex]::Matches($out, '<add name="[^"]+"\s+content=')).Count | Should -Be 0
    }

    It 'with no service deployed, the marker goes and connect-src names no service' {
        foreach ($none in '', $null) {
            $out = Get-VmfDashboardWebConfig -Template $script:template -ApiUrl $none
            $connect = (Get-VmfPolicyMap $out)['connect-src']
            $connect | Should -Not -Contain $script:marker
            @($connect | Where-Object { $_ -match 'azurewebsites' }) | Should -BeNullOrEmpty
            $connect[0] | Should -Be "'self'"
            $value = [regex]::Match($out, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"').Groups['v'].Value
            $value | Should -Not -Match '  ' -Because 'removing the marker leaves no double space in the header'
            $out | Should -Be ($script:template.Replace(" $($script:marker)", '')) -Because 'only the marker and its space go'
        }
    }

    It 'keeps a port, and gives the host in lower case' {
        $out = Get-VmfDashboardWebConfig -Template $script:template -ApiUrl 'https://VMF-Facade-Contoso.azurewebsites.net:8443/api'
        (Get-VmfPolicyMap $out)['connect-src'] | Should -Contain 'https://vmf-facade-contoso.azurewebsites.net:8443'
    }

    It 'refuses an address that is not an absolute https address with one exact host' {
        foreach ($bad in 'http://vmf-facade-contoso.azurewebsites.net/api', '/api', 'vmf-facade-contoso.azurewebsites.net/api',
            'https://*.azurewebsites.net/api', 'https://user@example.com/api', 'https://vmf facade.example.com/api',
            'https://vmf-facade-contoso.azurewebsites.net;script-src/api', "https://vmf-facade-contoso.azurewebsites.net`"/api") {
            { Get-VmfDashboardWebConfig -Template $script:template -ApiUrl $bad } | Should -Throw -Because $bad
        }
    }

    It 'refuses a template with no marker, or with two' {
        $none = $script:template.Replace($script:marker, '')
        { Get-VmfDashboardWebConfig -Template $none -ApiUrl $script:facadeApi } | Should -Throw '*marker*'
        $two = $script:template.Replace($script:marker, "$($script:marker) $($script:marker)")
        { Get-VmfDashboardWebConfig -Template $two -ApiUrl $script:facadeApi } | Should -Throw '*marker*'
    }

    It 'refuses a template whose marker is in another directive than connect-src' {
        $moved = $script:template.Replace(" $($script:marker)", '').Replace('frame-src https://login.microsoftonline.com', "frame-src $($script:marker) https://login.microsoftonline.com")
        $moved | Should -Match ([regex]::Escape("frame-src $($script:marker)")) -Because 'the fixture must really move the marker'
        { Get-VmfDashboardWebConfig -Template $moved -ApiUrl $script:facadeApi } | Should -Throw '*connect-src*'
    }

    It 'refuses a template whose policy holds a wildcard host, whatever the address' {
        $wild = $script:template.Replace($script:marker, "$($script:marker) https://*.azurewebsites.net")
        { Get-VmfDashboardWebConfig -Template $wild -ApiUrl $script:facadeApi } | Should -Throw '*wildcard*'
        { Get-VmfDashboardWebConfig -Template $wild -ApiUrl '' } | Should -Throw '*wildcard*'
    }
}

Describe 'CSP-AZUREWEBSITES-1: the dashboard publish uses it, with the address it gives the page' {
    BeforeAll {
        $script:deploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
    }

    It 'dot-sources the helper' {
        $script:deploy | Should -Match "Join-Path \`$PSScriptRoot '\.\.' 'infra' 'Get-VmfDashboardWebConfig\.ps1'"
    }

    It 'the page configuration and the policy take the service address from ONE variable' {
        $script:deploy | Should -Match 'apiUrl\s*=\s*\$serviceApiUrl\b'
        $script:deploy | Should -Match 'Get-VmfDashboardWebConfig -Template \$[A-Za-z]+ -ApiUrl \$serviceApiUrl\b'
        ([regex]::Matches($script:deploy, '\$serviceApiUrl\s*=')).Count | Should -Be 1 -Because 'one address, set once'
    }

    It 'writes the result into the web.config it packages, after the copy' {
        $copyAt = $script:deploy.IndexOf('Copy-Item $src (Join-Path $stage $f)')
        $writeAt = [regex]::Match($script:deploy, "Set-Content -LiteralPath \(Join-Path \`$stage 'web\.config'\)").Index
        $copyAt | Should -BeGreaterThan 0
        $writeAt | Should -BeGreaterThan $copyAt -Because 'a copy after the write would ship the template with its marker'
        $zipAt = $script:deploy.IndexOf('Compress-Archive')
        $writeAt | Should -BeLessThan $zipAt -Because 'the policy is written before the package is made'
    }
}
