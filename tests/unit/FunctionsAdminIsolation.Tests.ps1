#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FUNCTIONS-ADMIN-ISOLATION-1: the install closes the /admin paths of the
# service's Functions host, on both hosting plans.
#
# MEASURED 2026-11-14 on a lab install, unsigned: /api/* answered 401 from App
# Service authentication, but /admin/host/status answered 401 from the
# Functions HOST, which asks for the master key. Microsoft, "Work with access
# keys in Azure Functions": the master key gives "administrative access to the
# runtime REST APIs", so the key reached /admin around the product's sign-in.
#
# Microsoft, "App settings reference for Azure Functions",
# functionsRuntimeAdminIsolationEnabled: "When true, /admin endpoints can't be
# accessed, even with a master key." It "can't be set for apps running on Linux
# in a Consumption plan" - the service is a WINDOWS function app on both plans.
#
# WHY A HOOK AND NOT THE TEMPLATE. The service is deployed by the Azure
# Verified Module web/site 0.24.0, the newest there is, and it has no
# parameter for this site property and passes none through; the published
# Microsoft.Web/sites 2025-03-01 schema does not list it either. Azure returns
# it at every api-version from 2023-12-01 to 2025-05-01 (read on the lab
# install, 2026-11-14). So the install sets it after every deployment, by the
# service's resource ID, and READS IT BACK: an exit code is not proof of a
# property a policy may govern (CLAUDE.md).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:infra = Join-Path $script:repoRoot 'infra'
    $script:helperPath = Join-Path $script:infra 'Set-VmfFacadeAdminIsolation.ps1'
    $script:platform = Get-VmfCodeOnly -Path (Join-Path $script:infra 'platform.bicep') -Language CStyle
    $script:main = Get-VmfCodeOnly -Path (Join-Path $script:infra 'main.bicep') -Language CStyle
    $script:post = Get-VmfCodeOnly -Path (Join-Path $script:infra 'hooks' 'postprovision.ps1')
    $script:deploy = Get-VmfCodeOnly -Path (Join-Path $script:infra 'deploy.ps1')

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
    $script:siteId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Web/sites/vmf-facade-example'
}

Describe 'FUNCTIONS-ADMIN-ISOLATION-1: every hosting plan gets the property' {

    It 'found the service site, or none of this proves anything' {
        $script:facade | Should -Match "^module facade 'br/public:avm/res/web/site:"
    }

    It 'both hosting plans deploy the one service site: it has no plan condition of its own' {
        $script:facade | Should -Match "^module facade '[^']+' = \{" -Because 'a site deployed only on one plan would leave the other plan with nothing to close'
        ([regex]::Matches($script:platform, "(?m)^module facade\w* 'br/public:avm/res/web/site:")).Count | Should -Be 1
    }

    It 'the service is a Windows function app, the one kind Microsoft lets carry the property on Consumption' {
        $script:facade | Should -Match "(?m)^\s*kind: 'functionapp'\s*$"
        $script:facade | Should -Not -Match '(?i)linux'
        $script:facade | Should -Not -Match '(?m)^\s*reserved:\s*true'
    }

    It 'the template reports the service resource ID, and azd records it' {
        $script:platform | Should -Match '(?m)^output facadeResourceId string = facade\.outputs\.resourceId\s*$'
        $script:main | Should -Match '(?m)^output VMF_FACADE_ID string = platform\.outputs\.facadeResourceId\s*$'
    }

    It 'the install closes the paths on every run, for every plan, before the slow steps' {
        $script:post | Should -Match "\. \(Join-Path \`$PSScriptRoot '\.\.' 'Set-VmfFacadeAdminIsolation\.ps1'\)"
        $script:post | Should -Match "Get-AzdValue -Name 'VMF_FACADE_ID'"
        $script:post | Should -Match "@\('VMF_FACADE_ID', \`$facadeId\)" -Because 'a missing ID must stop the install, not skip the step'
        $call = [regex]::Match($script:post, '(?m)^(\s*)\$closed = Set-VmfFacadeAdminIsolation -SiteId \$facadeId\s*$')
        $call.Success | Should -BeTrue
        $call.Groups[1].Value | Should -Be '' -Because 'the call sits at the top level of the hook, inside no plan condition'
        $call.Index | Should -BeLessThan $script:post.IndexOf('az acr build') -Because 'the engine build takes minutes; the paths close first'
    }

    It 'the hand deployment closes the paths too, after the deployment and never on -WhatIf' {
        $script:deploy | Should -Match "\. \(Join-Path \`$PSScriptRoot 'Set-VmfFacadeAdminIsolation\.ps1'\)"
        $create = $script:deploy.IndexOf('az deployment group create @deployArgs')
        $whatIf = $script:deploy.IndexOf('az deployment group what-if')
        $call = [regex]::Match($script:deploy, 'Set-VmfFacadeAdminIsolation -SiteId \$facadeId')
        $call.Success | Should -BeTrue
        $create | Should -BeGreaterThan $whatIf
        $call.Index | Should -BeGreaterThan $create
        $script:deploy | Should -Match 'az deployment group create @deployArgs --query properties\.outputs\.facadeResourceId\.value --output tsv'
        $script:deploy | Should -Not -Match 'ConvertFrom-Json' -Because 'a warning az prints to stdout would break a parse of the whole output'
    }
}

Describe 'FUNCTIONS-ADMIN-ISOLATION-1: Set-VmfFacadeAdminIsolation sets the property and reads it back' {
    BeforeAll {
        . $script:helperPath
        # `az` is an external command; a FUNCTION of the same name wins
        # resolution, so the helper is driven without Azure.
        function Global:SetLabSite {
            param([object[]]$Reads, [int]$UpdateExit = 0, [int]$ShowThrottles = 0, [int]$RestThrottles = 0)
            $script:showThrottles = $ShowThrottles; $script:restThrottles = $RestThrottles
            $script:reads = [System.Collections.Generic.Queue[object]]::new()
            foreach ($r in $Reads) { $script:reads.Enqueue($r) }
            $script:updateExit = $UpdateExit
            $script:azCalls = [System.Collections.Generic.List[string]]::new()
            $script:bodies = [System.Collections.Generic.List[string]]::new()
        }
        function Global:az {
            $script:azCalls.Add(($args -join ' '))
            if ($args[0] -eq 'resource' -and $args[1] -eq 'show') {
                if ($script:showThrottles -gt 0) { $script:showThrottles--; Write-Error -Message 'ERROR: Too Many Requests' -ErrorAction Continue; $global:LASTEXITCODE = 1; return }
                $global:LASTEXITCODE = 0
                $value = $script:reads.Dequeue()
                $props = [ordered]@{ enabled = $true }
                if (-not ($value -is [string] -and $value -eq 'absent')) { $props['functionsRuntimeAdminIsolationEnabled'] = $value }
                return (@{ id = $script:siteId; properties = $props } | ConvertTo-Json -Depth 4)
            }
            if ($args[0] -eq 'rest') {
                if ($script:restThrottles -gt 0) { $script:restThrottles--; Write-Error -Message 'ERROR: Too Many Requests' -ErrorAction Continue; $global:LASTEXITCODE = 1; return }
                $at = [array]::IndexOf($args, '--body')
                $file = ([string]$args[$at + 1]).TrimStart('@')
                $script:bodies.Add([System.IO.File]::ReadAllText($file))
                $global:LASTEXITCODE = $script:updateExit
                return
            }
            throw "unexpected az call: $($args -join ' ')"
        }
    }
    AfterAll { Remove-Item 'function:\az', 'function:\SetLabSite' -ErrorAction SilentlyContinue }

    It 'an open site gets a PATCH of the one property by its resource ID, is read back, and reported closed' {
        SetLabSite -Reads @($false, $true)
        Set-VmfFacadeAdminIsolation -SiteId $script:siteId | Should -Be 'closed'
        @($script:azCalls | Where-Object { $_ -like 'resource update*' }).Count | Should -Be 0 -Because 'a GET and PUT of the whole site can drop what a GET does not return'
        $patches = @($script:azCalls | Where-Object { $_ -like 'rest *' })
        $patches.Count | Should -Be 1
        $patches[0] | Should -Match '--method patch'
        $patches[0] | Should -Match ([regex]::Escape("--url https://management.azure.com$($script:siteId)?api-version=2025-03-01 "))
        $patches[0] | Should -Not -Match '&' -Because 'az.cmd hands the URL to cmd, which reads & as a command separator'
        $patches[0] | Should -Match '--body @\S+\.json'
        $script:bodies.Count | Should -Be 1
        $sent = $script:bodies[0] | ConvertFrom-Json -AsHashtable
        @($sent.Keys) | Should -Be @('properties')
        @($sent.properties.Keys) | Should -Be @('functionsRuntimeAdminIsolationEnabled')
        $sent.properties.functionsRuntimeAdminIsolationEnabled | Should -BeTrue
        $sent.properties.functionsRuntimeAdminIsolationEnabled | Should -BeOfType [bool]
        $reads = @($script:azCalls | Where-Object { $_ -like 'resource show*' })
        $reads.Count | Should -Be 2
        foreach ($c in $reads) { $c | Should -Match ([regex]::Escape("--ids $script:siteId")) }
    }

    It 'the body file is removed after the PATCH, also when it fails' {
        SetLabSite -Reads @($false, $true)
        Set-VmfFacadeAdminIsolation -SiteId $script:siteId | Out-Null
        $file = ([regex]::Match(@($script:azCalls | Where-Object { $_ -like 'rest *' })[0], '--body @(\S+\.json)')).Groups[1].Value
        Test-Path -LiteralPath $file | Should -BeFalse
        SetLabSite -Reads @($false) -UpdateExit 1
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw
        $file = ([regex]::Match(@($script:azCalls | Where-Object { $_ -like 'rest *' })[0], '--body @(\S+\.json)')).Groups[1].Value
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'a site that is already closed is not written again' {
        SetLabSite -Reads @($true)
        Set-VmfFacadeAdminIsolation -SiteId $script:siteId | Should -Be 'already'
        @($script:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 0
    }

    It 'a site with no value is set, the same as false' {
        SetLabSite -Reads @('absent', $true)
        Set-VmfFacadeAdminIsolation -SiteId $script:siteId | Should -Be 'closed'
        @($script:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 1
    }

    It 'a write Azure accepts but a read gives false is a failure: a policy can put the value back' {
        SetLabSite -Reads @($false, $false)
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw '*functionsRuntimeAdminIsolationEnabled of the service site is false.*'
    }

    It 'a read after the write that gives no value is a failure, not a pass' {
        SetLabSite -Reads @($false, 'absent')
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw '*functionsRuntimeAdminIsolationEnabled of the service site has no value.*'
    }

    It 'a refused write is a failure' {
        SetLabSite -Reads @($false) -UpdateExit 1
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw '*cannot close the /admin paths of the service. The az command stopped with exit code 1.'
        @($script:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 1 -Because 'a refusal that is not a throttle is not tried again (INSTALL-THROTTLE-RETRY-3)'
    }

    # INSTALL-THROTTLE-RETRY-3: a throttled answer (HTTP 429) is tried again,
    # and a step throttled on every try keeps its own words and says so.
    It 'a throttled read and a throttled PATCH are tried again, and the site is closed' {
        Mock Start-Sleep { }
        SetLabSite -Reads @($false, $true) -ShowThrottles 1 -RestThrottles 2
        Set-VmfFacadeAdminIsolation -SiteId $script:siteId | Should -Be 'closed'
        @($script:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 3 -Because 'two throttled tries, then the PATCH that Azure accepts'
        @($script:azCalls | Where-Object { $_ -like 'resource show*' }).Count | Should -Be 3
    }

    It 'a PATCH throttled on every try stops with its own words and the throttle' {
        Mock Start-Sleep { }
        SetLabSite -Reads @($false) -RestThrottles 10
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw '*cannot close the /admin paths of the service. The az command stopped with exit code 1. Azure answered Too Many Requests (HTTP 429) 4 times.*'
        @($script:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 4
    }

    It 'a read throttled on every try stops with its own words and the throttle' {
        Mock Start-Sleep { }
        SetLabSite -Reads @() -ShowThrottles 10
        { Set-VmfFacadeAdminIsolation -SiteId $script:siteId } | Should -Throw '*cannot read the service site*exit code 1. Azure answered Too Many Requests (HTTP 429) 4 times.*'
    }

    It 'an ID that is not a Microsoft.Web/sites resource ID is refused before any call' {
        SetLabSite -Reads @()
        { Set-VmfFacadeAdminIsolation -SiteId 'vmf-facade-example' } | Should -Throw '*resource ID*'
        { Set-VmfFacadeAdminIsolation -SiteId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Web/serverfarms/plan' } | Should -Throw '*resource ID*'
        $script:azCalls.Count | Should -Be 0
    }
}
