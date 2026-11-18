#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STORE-LOGS-TELEMETRY-1: the service signs its Application Insights data with
# its managed identity, so the run store's perimeter admits it.
#
# MEASURED on the lab install, 2026-11-06, with the perimeter's access log
# (NSPAccessLogs): the workspace's association is Enforced, and the profile's
# only rule admits this subscription. The perimeter REFUSED
# "microsoft.insights/telemetry/write" from the service's outbound addresses,
# with NO identity on the call - the Application Insights SDK sent with the
# connection string's instrumentation key. Every store call of the service
# carries its system-assigned identity and is admitted. Only the service sends
# Application Insights data; the dashboard site has no telemetry settings.
#
# So: the component takes no key (disableLocalAuth), the service says it signs
# in with Entra (APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD,
# the system-assigned form), and its identity holds Monitoring Metrics
# Publisher on that one component. The same pattern as
# infra/ci-schedule/ci-starter.bicep, and Microsoft's page "Microsoft Entra
# authentication for Application Insights".
#
# The WORKSPACE keeps key-based ingestion: the Container Apps environment sends
# its logs with the workspace's shared key (the pin in platform.bicep).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:platformPath = Join-Path $script:repoRoot 'infra' 'platform.bicep'
    $script:settingsPath = Join-Path $script:repoRoot 'infra' 'facade-appsettings.bicep'
    $script:platform = Get-VmfCodeOnly -Path $script:platformPath -Language CStyle
    $script:settingsModule = Get-VmfCodeOnly -Path $script:settingsPath -Language CStyle
    $script:writeModule = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'facade-appsettings-write.bicep') -Language CStyle
    $script:roleId = '3913510d-42f4-4e42-8a64-420c390055eb'   # Monitoring Metrics Publisher

    function Script:Get-VmfBicepBlock {
        param([string]$Text, [string]$Header)
        $at = $Text.IndexOf($Header)
        if ($at -lt 0) { return '' }
        $open = $Text.IndexOf('{', $at)
        $depth = 0
        for ($i = $open; $i -lt $Text.Length; $i++) {
            if ($Text[$i] -eq '{') { $depth++ }
            elseif ($Text[$i] -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($at, $i - $at + 1) } }
        }
        ''
    }
    $script:component = Get-VmfBicepBlock -Text $script:platform -Header 'module appInsights '
    $script:logs = Get-VmfBicepBlock -Text $script:platform -Header 'module logs '
    $script:grant = Get-VmfBicepBlock -Text $script:platform -Header 'resource facadeTelemetryPublisher '
    $script:componentRef = Get-VmfBicepBlock -Text $script:platform -Header 'resource facadeTelemetryComponent '
}

Describe 'STORE-LOGS-TELEMETRY-1: the component takes Entra sign-in only' {

    It 'found the component and the workspace, or this proves nothing' {
        $script:component | Should -Match "^module appInsights 'br/public:avm/res/insights/component:"
        $script:logs | Should -Match "^module logs 'br/public:avm/res/operational-insights/workspace:"
    }

    It 'turns off key-based ingestion on the component' {
        # The AVM module's parameter is disableLocalAuth (component 0.8.0, default false).
        $script:component | Should -Match '(?m)^\s*disableLocalAuth: true\s*$'
    }

    It 'keeps key-based ingestion on the workspace, which the Container Apps environment sends with' {
        $script:logs | Should -Match '(?s)features: \{\s*disableLocalAuth: false\s*\}'
    }
}

Describe 'STORE-LOGS-TELEMETRY-1: the service signs its telemetry with its managed identity' {

    It 'writes the authentication string with the connection string, in the settings module' {
        $script:writeModule | Should -Match '(?s)properties: union\(\s*currentAppSettings,\s*settings,\s*\{\s*APPLICATIONINSIGHTS_CONNECTION_STRING: connectionString\s*APPLICATIONINSIGHTS_AUTHENTICATION_STRING: ''Authorization=AAD''\s*\}\s*\)'
        $script:settingsModule | Should -Match '(?m)^\s*connectionString: appInsights\.properties\.ConnectionString\s*$'
    }

    It 'uses the system-assigned form: no ClientId in the string' {
        $script:settingsModule | Should -Not -Match 'Authorization=AAD;ClientId'
        $script:writeModule | Should -Not -Match 'Authorization=AAD;ClientId'
        $script:platform | Should -Not -Match 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING' -Because 'the settings module writes it last, so a caller setting cannot override it'
    }

    It 'no template in infra sends Application Insights data with a key' {
        # A class rule: any template that hands a site the connection string
        # also tells it to sign in with Entra.
        $files = Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'infra') -Recurse -Filter '*.bicep'
        $found = 0
        foreach ($file in $files) {
            $code = Get-VmfCodeOnly -Path $file.FullName -Language CStyle
            if ($code -notmatch 'APPLICATIONINSIGHTS_CONNECTION_STRING') { continue }
            $found++
            $code | Should -Match "APPLICATIONINSIGHTS_AUTHENTICATION_STRING'?[:,]?\s*(value: )?'Authorization=AAD'" -Because "$($file.Name) sends Application Insights data"
        }
        # PUBLIC-SYNC-1: the CI starter (infra/ci-schedule) does not ship to the
        # public repository, so there the service settings module is the one.
        $senders = if (Test-Path (Join-Path $script:repoRoot 'infra' 'ci-schedule')) { 2 } else { 1 }
        $found | Should -BeGreaterOrEqual $senders -Because 'the service settings module and the CI starter both send it, or this proves nothing'
    }
}

Describe 'STORE-LOGS-TELEMETRY-1: the service identity may publish to that one component' {

    It 'found the grant and the component it is scoped to, or this proves nothing' {
        $script:grant | Should -Match "^resource facadeTelemetryPublisher 'Microsoft\.Authorization/roleAssignments@[\d-]+' = \{"
        $script:componentRef | Should -Match "^resource facadeTelemetryComponent 'Microsoft\.Insights/components@[\d-]+' existing = \{"
    }

    It 'names the role by its id, and the id is Monitoring Metrics Publisher' {
        $script:platform | Should -Match "var roleMetricsPublisher = '$($script:roleId)'"
        $script:grant | Should -Match "roleDefinitionId: subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions', roleMetricsPublisher\)"
    }

    It 'scopes it to the component of the service, nothing wider' {
        $script:grant | Should -Match '(?m)^\s*scope: facadeTelemetryComponent\s*$'
        $script:componentRef | Should -Match '(?m)^\s*name: facadeName\s*$' -Because 'the component is named for the service (module appInsights)'
        $script:component | Should -Match '(?m)^\s*name: facadeName\s*$'
    }

    It 'gives it to the system-assigned identity of the service, as a service principal' {
        $script:grant | Should -Match 'principalId: facade\.outputs\.systemAssignedMIPrincipalId!'
        $script:grant | Should -Match "principalType: 'ServicePrincipal'"
    }

    It 'has a name that is the same on every deployment, and new for a new site' {
        # The site id changes when the hosting plan changes (WARM-1), and so
        # does the identity: a new name, not a refused update of the old one.
        $script:grant | Should -Match '(?m)^\s*name: guid\(facadeTelemetryComponent\.id, facadeResourceId, roleMetricsPublisher\)\s*$'
    }

    It 'is made after the component exists' {
        $script:grant | Should -Match '(?s)dependsOn: \[[^\]]*\bappInsights\b[^\]]*\]'
    }
}

Describe 'STORE-LOGS-TELEMETRY-1: the compiled template' {
    BeforeAll {
        $script:compiled = $null
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $out = az bicep build --file $script:platformPath --stdout 2>$null
            if ($LASTEXITCODE -eq 0) { $script:compiled = ($out -join "`n") | ConvertFrom-Json -Depth 100 }
        }
        function Script:Get-VmfItems {
            param($Template)
            if ($Template.resources -is [array]) { $Template.resources } else { $Template.resources.PSObject.Properties.Value }
        }
    }

    It 'gives the component deployment disableLocalAuth true' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $deploy = @(Get-VmfItems $script:compiled | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and [string]$_.name -eq 'vmf-ai-deploy' })[0]
        $deploy | Should -Not -BeNullOrEmpty
        $deploy.properties.parameters.disableLocalAuth.value | Should -BeTrue
    }

    It 'has one Monitoring Metrics Publisher grant, on the component' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $grants = @(Get-VmfItems $script:compiled | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and ($_ | ConvertTo-Json -Depth 20 -Compress) -match 'roleMetricsPublisher' })
        $grants.Count | Should -Be 1
        [string]$grants[0].scope | Should -Match "Microsoft\.Insights/components"
        [string]$script:compiled.variables.roleMetricsPublisher | Should -Be $script:roleId
    }

    It 'gives the settings deployment the authentication string' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $deploy = @(Get-VmfItems $script:compiled | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and [string]$_.name -eq 'vmf-facade-appsettings-deploy' })[0]
        $deploy | Should -Not -BeNullOrEmpty
        ($deploy.properties.template | ConvertTo-Json -Depth 40 -Compress) | Should -Match 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING.{1,20}Authorization=AAD'
    }
}
