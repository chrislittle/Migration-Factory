#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DEPS-CURRENT-1 part 4: the install template's Azure Verified Modules moved to
# their current versions, and the resources they deploy did not change.
#
# A module can add a setting by itself in a new version. web/site 0.20.0 does:
# when a site's `appsettings` config names `applicationInsightResourceId`, the
# module also writes ApplicationInsightsAgent_EXTENSION_VERSION (~2 on a
# Windows app), which turns on the App Service Application Insights site
# extension. The facade never had it, Microsoft's Functions settings reference
# does not ask for it, and a template can state an app setting but cannot
# unstate one (tools/Deploy-VmfFacade.ps1 has to delete the ones it retired).
# So the facade's app settings are written by infra/facade-appsettings.bicep,
# which does what web/site 0.19.0 did: the settings that are there now, then
# the template's, then the connection string read from the component.
#
# serverfarm 0.7.0 takes any plan kind, so the facade's plan states the kind
# as Azure stores it, and the permanent DRIFT-3 preview entry
# (`kind: functionapp -> functionApp`) ends.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:platformPath = Join-Path $script:repoRoot 'infra' 'platform.bicep'
    $script:settingsPath = Join-Path $script:repoRoot 'infra' 'facade-appsettings.bicep'
    $script:platform = Get-VmfCodeOnly -Path $script:platformPath -Language CStyle
    $script:settingsModule = if (Test-Path -LiteralPath $script:settingsPath) { Get-VmfCodeOnly -Path $script:settingsPath -Language CStyle } else { '' }
    $script:writePath = Join-Path $script:repoRoot 'infra' 'facade-appsettings-write.bicep'
    $script:writeModule = if (Test-Path -LiteralPath $script:writePath) { Get-VmfCodeOnly -Path $script:writePath -Language CStyle } else { '' }

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
    $script:facade = Get-VmfBicepBlock -Text $script:platform -Header 'module facade '
    $script:facadePlan = Get-VmfBicepBlock -Text $script:platform -Header 'module facadeHostingPlan '
    $script:settingsCall = Get-VmfBicepBlock -Text $script:platform -Header 'module facadeAppSettings '

    # The settings the facade carried before this change (web/site 0.19.0).
    # PIPELINE-LATER-1 removed two on purpose, VMF_UPDATE_MODEL and
    # VMF_DEPLOY_PRINCIPAL: a person runs every update, so nothing reads them.
    $script:facadeSettings = @(
        'FUNCTIONS_EXTENSION_VERSION', 'FUNCTIONS_WORKER_RUNTIME', 'WEBSITE_AAD_ENABLE_MISE',
        'AzureWebJobsStorage__accountName', 'AzureWebJobsStorage__blobServiceUri',
        'AzureWebJobsStorage__queueServiceUri', 'AzureWebJobsStorage__tableServiceUri',
        'AzureWebJobsStorage__credential', 'WEBSITE_RUN_FROM_PACKAGE', 'VMF_STORE_ACCOUNT',
        'VMF_STORE_CONTAINER', 'VMF_ENGINE_JOB_ID'
    )
}

Describe 'DEPS-CURRENT-1 part 4: the facade keeps the app settings it had' {

    It 'found the facade, its plan and the settings call, or this proves nothing' {
        $script:facade | Should -Match "^module facade 'br/public:avm/res/web/site:"
        $script:facadePlan | Should -Match "^module facadeHostingPlan 'br/public:avm/res/web/serverfarm:"
        $script:settingsCall | Should -Match "^module facadeAppSettings 'facade-appsettings\.bicep'"
    }

    It 'the site module is never given the component, so it adds no agent setting' {
        $script:facade | Should -Not -Match 'applicationInsightResourceId' -Because 'web/site 0.20.0 and later then also write ApplicationInsightsAgent_EXTENSION_VERSION'
        $script:platform | Should -Not -Match 'ApplicationInsightsAgent_EXTENSION_VERSION'
        $script:settingsModule | Should -Not -Match 'ApplicationInsightsAgent_EXTENSION_VERSION'
    }

    It 'the site module still sets the sign-in settings, and no app settings of its own' {
        $script:facade | Should -Match "name: 'authsettingsV2'"
        $script:facade | Should -Not -Match "name: 'appsettings'"
    }

    It 'every setting the facade had is written by the settings module call' {
        foreach ($name in $script:facadeSettings) {
            $script:settingsCall | Should -Match "(?m)^\s*$([regex]::Escape($name)):" -Because "$name was a facade app setting"
        }
    }

    It 'the call names the facade and its component, and runs after both exist' {
        $script:settingsCall | Should -Match 'siteName: facadeSiteName'
        $script:settingsCall | Should -Match 'appInsightsName: facadeName'
        $script:settingsCall | Should -Match '(?s)dependsOn: \[[^\]]*\bfacade\b[^\]]*\]'
        $script:settingsCall | Should -Match '(?s)dependsOn: \[[^\]]*\bappInsights\b[^\]]*\]'
    }

    It 'the settings that are there now are kept, as the site module kept them' {
        # INSTALL-FIRST-RUN-SETTINGS-1: read INSIDE the module, from its
        # existing site, never in the parent and passed in. The parent's read
        # ran before the facade module made the site, so a first install
        # stopped with ResourceNotFound.
        # The read stays in facade-appsettings.bicep and goes to the write
        # module as a parameter: a read and a write of <site>/config/appsettings
        # in one template is refused as a circular dependency (measured).
        $script:settingsModule | Should -Match "(?m)^\s*currentAppSettings: list\('\$\{site\.id\}/config/appsettings', '2023-12-01'\)\.properties\s*$"
        $script:settingsModule | Should -Not -Match '(?m)^param currentAppSettings\b'
        $script:settingsModule | Should -Not -Match "name: 'appsettings'"
        $script:settingsCall | Should -Not -Match 'currentAppSettings'
        $script:settingsCall | Should -Not -Match '(?i)\blist\w*\('
    }

    It 'the module writes the current settings, then the template settings, then the connection string and how to sign in with it' {
        # STORE-LOGS-TELEMETRY-1 added the authentication string, on purpose:
        # the component takes Entra sign-in only, and the run store's
        # perimeter refused the key-based telemetry (lab, 2026-11-06). These
        # two, and nothing else, follow the caller's settings.
        $script:settingsModule | Should -Match "resource appInsights 'Microsoft\.Insights/components@[\d-]+' existing"
        $script:settingsModule | Should -Match "resource site 'Microsoft\.Web/sites@[\d-]+' existing"
        $script:settingsModule | Should -Match "(?m)^\s*connectionString: appInsights\.properties\.ConnectionString\s*$"
        $script:writeModule | Should -Match "resource site 'Microsoft\.Web/sites@[\d-]+' existing"
        $script:writeModule | Should -Match "name: 'appsettings'"
        $script:writeModule | Should -Match "(?s)properties: union\(\s*currentAppSettings,\s*settings,\s*\{\s*APPLICATIONINSIGHTS_CONNECTION_STRING: connectionString\s*APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'\s*\}\s*\)"
        # Their values stay out of a deployment's history.
        $script:writeModule | Should -Match "(?s)@secure\(\)\s*@description\([^)]*\)\s*param currentAppSettings object"
        $script:writeModule | Should -Match "(?s)@secure\(\)\s*@description\([^)]*\)\s*param connectionString string"
    }

    It 'the module reads no storage key' {
        $script:settingsModule | Should -Not -Match '(?i)listKeys|AccountKey'
    }
}

Describe 'DEPS-CURRENT-1 part 4: the facade plan states its kind as Azure stores it' {

    It 'is functionapp, in lower case' {
        $script:facadePlan | Should -Match "kind: 'functionapp'"
        $script:facadePlan | Should -MatchExactly "kind: 'functionapp'"
    }
}

Describe 'DEPS-CURRENT-1 part 4: the compiled template' {
    BeforeAll {
        $script:compiled = $null
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $out = az bicep build --file $script:platformPath --stdout 2>$null
            if ($LASTEXITCODE -eq 0) { $script:compiled = ($out -join "`n") | ConvertFrom-Json -Depth 100 }
        }
        function Script:Get-VmfDeployment {
            param($Template, [string]$Name)
            # languageVersion 2.0 keeps resources in an object keyed by symbolic name
            $items = if ($Template.resources -is [array]) { $Template.resources } else { $Template.resources.PSObject.Properties.Value }
            @($items | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.properties.expressionEvaluationOptions.scope -eq 'inner' -and [string]$_.name -eq $Name })[0]
        }
    }

    It 'compiles' {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'az is not installed'; return }
        $script:compiled | Should -Not -BeNullOrEmpty
    }

    It 'gives the site module no app settings config and no component' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $site = Get-VmfDeployment -Template $script:compiled -Name 'vmf-facade-deploy'
        $site | Should -Not -BeNullOrEmpty
        $configs = $site.properties.parameters.configs | ConvertTo-Json -Depth 30 -Compress
        $configs | Should -Match 'authsettingsV2'
        $configs | Should -Not -Match 'appsettings'
        $configs | Should -Not -Match 'applicationInsightResourceId'
    }

    It 'gives the settings deployment no reference and no list in any parameter' {
        if (-not $script:compiled) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $call = Get-VmfDeployment -Template $script:compiled -Name 'vmf-facade-appsettings-deploy'
        $call | Should -Not -BeNullOrEmpty
        @($call.properties.parameters.PSObject.Properties).Count | Should -BeGreaterThan 0
        foreach ($param in $call.properties.parameters.PSObject.Properties) {
            ($param.Value | ConvertTo-Json -Depth 20 -Compress) | Should -Not -Match '(?i)reference\(|list\w*\(' -Because "$($param.Name) must resolve at preview time, and a first install has no site to read"
        }
    }
}
