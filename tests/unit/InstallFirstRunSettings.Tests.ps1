#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-FIRST-RUN-SETTINGS-1: a first install into a new resource group
# stopped before the web service had its app settings.
#
# The platform template read the facade's current app settings with list() on
# a STRING id (resourceId() of the site) and passed the result to the settings
# module as a parameter. The site is made by another module (vmf-facade-deploy),
# so this template does not declare it, and ARM read the site before the facade
# module had made it, in spite of the dependsOn. Every install that already had the
# site passed, so only a first install failed: "ResourceNotFound: The Resource
# 'Microsoft.Web/sites/<site>' ... was not found" on <site>/appsettings.
#
# The rule held here, over the COMPILED template (what ARM runs), not the
# bicep text: in the install's templates, a list*() or reference() in a module
# parameter or a resource property names a resource by its SYMBOLIC name, which
# ARM orders after that resource. A string id gives ARM no resource of this
# template to wait for.
# The facade's settings are read inside facade-appsettings.bicep, from its
# existing site, so the read runs only when that nested deployment runs.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:az = [bool](Get-Command az -ErrorAction SilentlyContinue)

    function Script:Get-VmfCompiled {
        param([string]$Name)
        if (-not $script:az) { return $null }
        $file = Join-Path $script:repoRoot 'infra' $Name
        $out = az bicep build --file $file --stdout 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        ($out -join "`n") | ConvertFrom-Json -Depth 100
    }

    # Each resource of a template's TOP level, with its symbolic name.
    # languageVersion 2.0 keeps them in an object keyed by symbolic name.
    function Script:Get-VmfTopResources {
        param($Template)
        if ($Template.resources -is [array]) {
            foreach ($r in $Template.resources) { [pscustomobject]@{ Symbol = $null; Resource = $r } }
        } else {
            foreach ($pr in $Template.resources.PSObject.Properties) { [pscustomobject]@{ Symbol = $pr.Name; Resource = $pr.Value } }
        }
    }

    # Every list*() and reference() call in a resource's evaluated parts: a
    # module's parameters, or another resource's properties. A nested
    # template's own body is not evaluated in this deployment, so it is left
    # to its own deployment.
    function Script:Get-VmfReadCalls {
        param($Template)
        foreach ($item in (Get-VmfTopResources $Template)) {
            $r = $item.Resource
            $evaluated = if ($r.type -eq 'Microsoft.Resources/deployments') { $r.properties.parameters } else { $r.properties }
            $text = $evaluated | ConvertTo-Json -Depth 100 -Compress
            foreach ($m in [regex]::Matches([string]$text, '(?i)\b(list\w*|reference)\(\s*([^,\)]*)')) {
                [pscustomobject]@{ Resource = if ($item.Symbol) { $item.Symbol } else { [string]$r.name }; Function = $m.Groups[1].Value; FirstArgument = $m.Groups[2].Value.Trim() }
            }
        }
    }

    function Script:Test-VmfSymbolicArgument {
        param([string]$Argument, [string[]]$Symbols)
        if ($Argument -notmatch "^'([A-Za-z_][A-Za-z0-9_]*)'$") { return $false }
        $Matches[1] -in $Symbols
    }

    $script:platform = Get-VmfCompiled 'platform.bicep'
    $script:main = Get-VmfCompiled 'main.bicep'
    $script:settings = Get-VmfCompiled 'facade-appsettings.bicep'
    $script:write = Get-VmfCompiled 'facade-appsettings-write.bicep'
}

Describe 'INSTALL-FIRST-RUN-SETTINGS-1: the install template reads only what it orders' {

    It 'compiles the platform, the main template and the settings module' {
        if (-not $script:az) { Set-ItResult -Skipped -Because 'az is not installed'; return }
        $script:platform | Should -Not -BeNullOrEmpty
        $script:main | Should -Not -BeNullOrEmpty
        $script:settings | Should -Not -BeNullOrEmpty
    }

    It 'the platform reads a resource only by its symbolic name, in every module parameter and resource property' {
        if (-not $script:platform) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $symbols = @((Get-VmfTopResources $script:platform).Symbol)
        $calls = @(Get-VmfReadCalls $script:platform)
        $calls.Count | Should -BeGreaterThan 0 -Because 'the platform reads module outputs, so a scan that finds none read nothing'
        $bad = @($calls | Where-Object { -not (Test-VmfSymbolicArgument $_.FirstArgument $symbols) } | ForEach-Object { "$($_.Resource): $($_.Function)($($_.FirstArgument)" })
        $bad | Should -BeNullOrEmpty -Because 'a string id gives ARM no resource of this template to wait for, so it can read before a module makes the resource'
    }

    It 'the main template reads a resource only by its symbolic name' {
        if (-not $script:main) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $symbols = @((Get-VmfTopResources $script:main).Symbol)
        $bad = @(Get-VmfReadCalls $script:main | Where-Object { -not (Test-VmfSymbolicArgument $_.FirstArgument $symbols) } | ForEach-Object { "$($_.Resource): $($_.Function)($($_.FirstArgument)" })
        $bad | Should -BeNullOrEmpty
    }

    It 'the settings deployment gets no current settings from the platform, and runs after the facade module' {
        if (-not $script:platform) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $call = @(Get-VmfTopResources $script:platform | Where-Object { $_.Resource.type -eq 'Microsoft.Resources/deployments' -and [string]$_.Resource.name -eq 'vmf-facade-appsettings-deploy' })[0]
        $call | Should -Not -BeNullOrEmpty
        @($call.Resource.properties.parameters.PSObject.Properties.Name) | Should -Not -Contain 'currentAppSettings'
        @($call.Resource.dependsOn) | Should -Contain 'facade'
        @($call.Resource.dependsOn) | Should -Contain 'appInsights'
    }

    It 'the settings module reads the site current settings itself, from its own site, and hands them to the write module' {
        if (-not $script:settings) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        @($script:settings.parameters.PSObject.Properties.Name) | Should -Not -Contain 'currentAppSettings'
        # No write here: a read and a write of <site>/config/appsettings in one
        # template is refused before anything runs ("Circular dependency
        # detected", measured 2026-11-13).
        @(Get-VmfTopResources $script:settings | Where-Object { $_.Resource.type -eq 'Microsoft.Web/sites/config' }).Count | Should -Be 0
        $call = @(Get-VmfTopResources $script:settings | Where-Object { $_.Resource.type -eq 'Microsoft.Resources/deployments' -and [string]$_.Resource.name -eq 'vmf-facade-appsettings-write' })
        $call.Count | Should -Be 1
        $deployParams = $call[0].Resource.properties.parameters
        [string]$deployParams.currentAppSettings.value | Should -Be "[list(format('{0}/config/appsettings', resourceId('Microsoft.Web/sites', parameters('siteName'))), '2023-12-01').properties]"
        [string]$deployParams.connectionString.value | Should -Match ([regex]::Escape("reference(resourceId('Microsoft.Insights/components', parameters('appInsightsName')), '2020-02-02').ConnectionString"))
    }

    It 'the write module merges current, then template, then the connection and authentication strings, with secrets kept out of history' {
        if (-not $script:write) { Set-ItResult -Skipped -Because 'the template did not compile here'; return }
        $w = @(Get-VmfTopResources $script:write | Where-Object { $_.Resource.type -eq 'Microsoft.Web/sites/config' })
        $w.Count | Should -Be 1
        [string]$w[0].Resource.properties | Should -Be "[union(parameters('currentAppSettings'), parameters('settings'), createObject('APPLICATIONINSIGHTS_CONNECTION_STRING', parameters('connectionString'), 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', 'Authorization=AAD'))]"
        $script:write.parameters.currentAppSettings.type | Should -Be 'secureObject'
        $script:write.parameters.connectionString.type | Should -Be 'securestring'
        # And the write module reads nothing: no list() of the resource it writes.
        ($script:write | ConvertTo-Json -Depth 40 -Compress) | Should -Not -Match 'list\('
    }
}