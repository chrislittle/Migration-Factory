#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROUTE-CONTRACT-1: the two halves are checked against each other.
#
# The dashboard builds a path. The service declares a route. Nothing has ever
# compared them, and each side was tested against its own assumption - which is
# how `runs/{runId}` met an id with a slash in it and answered 404 for two
# weeks (RUNID-2).
#
# The server side even had a test for the composite id: StorePathGuard says
# "still builds the path for a run inside a project". The route side had
# nothing, so one half was guarded against the shape the other half was
# sending.
#
# This is the missing check, and it is static: the paths are literals in the
# pages and the routes are literals in function.json.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # What the SERVICE declares, as a shape: runs/{}/engine/{} -> runs/*/engine/*
    $script:routes = @(
        Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Filter 'function.json' -Recurse |
            ForEach-Object {
                $doc = Get-Content $_.FullName -Raw | ConvertFrom-Json
                foreach ($b in @($doc.bindings)) {
                    if ($b.type -ne 'httpTrigger' -or -not $b.route) { continue }
                    [pscustomobject]@{
                        Route = [string]$b.route
                        Shape = ([string]$b.route) -replace '\{[^}]+\}', '*'
                        File  = $_.Directory.Name
                    }
                }
            })

    # What the PAGES ask for. Every api(...) call's first path argument, with
    # its interpolations collapsed the same way.
    $script:asked = @(
        foreach ($page in (Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html' -File)) {
            $code = Get-VmfCodeOnly -Text ((Get-VmfPageSource -Path $page.FullName)) -Language CStyle
            foreach ($m in [regex]::Matches($code, '(?:api|apiPost|apiGet)\((?:''(?:GET|POST|PUT|DELETE)'',\s*)?`([^`]+)`')) {
                [pscustomobject]@{ Page = $page.Name; Raw = $m.Groups[1].Value }
            }
        })
}

Describe 'ROUTE-CONTRACT-1: every path a page asks for is a route the service declares' {

    It 'found routes and requests, so this cannot pass by comparing nothing' {
        $script:routes.Count | Should -BeGreaterThan 20
        $script:asked.Count | Should -BeGreaterThan 10
    }

    It 'every path the dashboard builds matches a declared route' {
        # SEGMENT BY SEGMENT. A route's {runId} matches anything in that
        # position and nothing across a slash - which is the whole finding, so
        # the comparison had better honour it. `runs/{runId}/engine/{operation}`
        # accepts `runs/*/engine/plan`; it does not accept a path with an extra
        # segment in it, which is what an id with a slash becomes.
        function Test-ShapeMatch {
            param([string]$Asked, [string]$Route)
            $a = $Asked -split '/'
            $r = $Route -split '/'
            if ($a.Count -ne $r.Count) { return $false }
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($r[$i] -eq '*' -or $a[$i] -eq '*') { continue }
                if ($r[$i] -ne $a[$i]) { return $false }
            }
            $true
        }
        $shapes = @($script:routes | ForEach-Object { $_.Shape })
        $missing = @()
        foreach ($a in $script:asked) {
            # Collapse ${...} the way a route collapses {runId}, and drop any
            # query string - a route declares a path, never a query.
            $shape = ($a.Raw -replace '\$\{[^}]+\}', '*') -replace '\?.*$', ''
            $shape = $shape.Trim('/')
            if (-not $shape) { continue }
            $hit = @($shapes | Where-Object { Test-ShapeMatch -Asked $shape -Route $_ })
            if (-not $hit.Count) { $missing += "$($a.Page) asks for '$shape'" }
        }
        $missing -join '; ' | Should -BeNullOrEmpty -Because 'a path no route declares is a 404 nobody will explain'
    }

    It 'and no route takes an id that may contain a slash' {
        # THE DEFECT ITSELF. A route segment is one segment. Where a page puts
        # a run id into one, it must use VmfRun.routeSegment, which splits the
        # project off - and RunAddress.Tests.ps1 refuses any other way of
        # building one.
        $runRoutes = @($script:routes | Where-Object { $_.Route -match '\{runId\}' })
        $runRoutes.Count | Should -BeGreaterThan 5 -Because 'most of the API is about a run'
        foreach ($r in $runRoutes) {
            $r.Route | Should -Not -Match '\{\*' -Because 'a catch-all would hide this rather than fix it'
        }
    }
}
