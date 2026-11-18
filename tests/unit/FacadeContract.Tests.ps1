#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Found the hard way, 2026-08-28, during a live demo: clicking Run
# returned "The term 'Invoke-VmfFacadeAcknowledge' is not recognized". The
# function existed in FacadeCore.psm1 and its endpoint existed in the app - but
# the MANIFEST did not export it, so the Function App could not see it.
#
# The unit tests missed it because they reach INSIDE the module (InModuleScope
# and direct calls resolve non-exported functions perfectly well). The Function
# App does not have that luxury: each endpoint runs in its own scope and can
# only call what the manifest exports.
#
# So this file checks the seam the tests were flattering: every function an
# endpoint calls must actually be exported to it.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:appDir = Join-Path $script:repoRoot 'src' 'facade' 'app'
    $script:coreDir = Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore'
    $script:manifest = Import-PowerShellDataFile (Join-Path $script:coreDir 'FacadeCore.psd1')
    $script:exported = @($script:manifest.FunctionsToExport)

    # Every Vmf command an endpoint invokes, by AST rather than by regex.
    $script:calls = @{}
    foreach ($run in Get-ChildItem $script:appDir -Filter 'run.ps1' -Recurse) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($run.FullName, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and $_ -like '*-Vmf*' } | Sort-Object -Unique)
        $script:calls[$run.Directory.Name] = $names
    }
}

Describe 'The facade endpoints can actually call what they call' {
    It 'found the endpoints to check' {
        @($script:calls.Keys).Count | Should -BeGreaterThan 5
    }

    It 'every Vmf function an endpoint invokes is exported by the FacadeCore manifest' {
        # This is the test that would have saved the demo.
        $defined = @(([System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:coreDir 'FacadeCore.psm1'), [ref]$null, [ref]$null)
            ).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })

        $broken = foreach ($endpoint in $script:calls.Keys) {
            foreach ($cmd in $script:calls[$endpoint]) {
                # Only functions FacadeCore itself owns; engine cmdlets come
                # from the VmMigrationFactory module the app also imports.
                if ($cmd -in $defined -and $cmd -notin $script:exported) {
                    "$endpoint calls $cmd, which FacadeCore.psd1 does not export"
                }
            }
        }
        $broken -join '; ' | Should -BeNullOrEmpty -Because 'an endpoint can only call what the manifest exports - the unit tests reach inside the module and never notice'
    }

    It 'the manifest exports nothing that no longer exists' {
        $defined = @(([System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:coreDir 'FacadeCore.psm1'), [ref]$null, [ref]$null)
            ).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
        $ghosts = @($script:exported | Where-Object { $_ -notin $defined })
        $ghosts -join ', ' | Should -BeNullOrEmpty -Because 'a manifest promising a function that was deleted fails at import time, not at call time'
    }

    It 'every endpoint route in the app is one the dashboard or wizard actually calls, or vice versa' {
        # The demo also hit the other half of this seam: the dashboard shipped
        # an "accept options" button months before the endpoint was deployed.
        # This does not check deployment - nothing in a unit test can - but it
        # does check the two halves agree in the REPOSITORY.
        $routes = foreach ($fj in Get-ChildItem $script:appDir -Filter 'function.json' -Recurse) {
            $cfg = Get-Content $fj.FullName -Raw | ConvertFrom-Json
            $r = @($cfg.bindings | Where-Object { $_.type -eq 'httpTrigger' }).route
            if ($r) { [pscustomobject]@{ Endpoint = $fj.Directory.Name; Route = $r } }
        }
        @($routes).Count | Should -BeGreaterThan 5

        # help.js is part of the dashboard, and all seven pages load it. The
        # store reads live there rather than in any one page (STORE-READ-1), so
        # reading only the HTML would report both store endpoints as endpoints
        # nobody calls.
        $pages = (@(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html' |
            ForEach-Object { (Get-VmfPageSource -Path $_.FullName) }) +
            @(Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw)) -join "`n"
        # Route templates -> the literal head of the path the pages fetch.
        $unused = foreach ($r in $routes) {
            if ($r.Endpoint -eq 'ScheduleRunner') { continue }          # timer, not HTTP
            $head = ($r.Route -split '\{')[0].TrimEnd('/')              # e.g. runs/
            $tail = ($r.Route -split '\}')[-1].TrimStart('/')           # e.g. waves/accept-options
            if ($tail -and $pages -notmatch [regex]::Escape($tail)) { "$($r.Endpoint) ($($r.Route))" }
        }
        $unused -join ', ' | Should -BeNullOrEmpty -Because 'an endpoint no page calls is either dead or a page is missing its action'
    }
}
