#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H6, and the derived guard the audit asked for.
#
# The dashboard posts four fields for a shell rebuild (vmId, note, diskSource,
# as). The handler forwarded the first two. FacadeCore declared and used both
# missing parameters, so with nothing bound no environment override was emitted
# and the engine silently fell back to disks/original - while the operator got
# HTTP 202 and the state document recorded the DEFAULTED values as what
# happened. On the most destructive operation in the tool, the audit trail
# contradicted the person who pressed the button.
#
# The class of defect is invisible because THE CALL SUCCEEDS. So this test
# derives the contract from both sides: every key a page sends to an endpoint
# must be read by that endpoint.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pages = Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html' |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Text = (Get-VmfPageSource -Path $_.FullName) } }
    $script:handlers = Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Directory |
        ForEach-Object {
            $runFile = Join-Path $_.FullName 'run.ps1'
            $fnFile = Join-Path $_.FullName 'function.json'
            if (-not (Test-Path $runFile) -or -not (Test-Path $fnFile)) { return }
            $cfg = Get-Content $fnFile -Raw | ConvertFrom-Json
            $trigger = @($cfg.bindings | Where-Object { $_.type -eq 'httpTrigger' })[0]
            # PROJECT-1 exposed the gap: GET /projects and POST /projects are two
            # handlers on ONE route - ordinary REST, and something this matcher
            # could not express. It picked whichever came first and then reported
            # that the GET never reads the POST's body.
            [pscustomobject]@{ Name = $_.Name; Route = $trigger.route
                               Methods = @($trigger.methods | ForEach-Object { "$_".ToUpperInvariant() })
                               Text = Get-Content $runFile -Raw }
        } | Where-Object { $_ -and $_.Route }

    # Keys a page sends: apiFetch(`runs/${x}/engine/wave`, { wave, throttle, note })
    function Script:BodyKeys([string]$pageText) {
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($m in [regex]::Matches($pageText, "api(Fetch)?\(\s*['\`"``]?(?<path>[^'\`"``,)]+)['\`"``]?\s*,\s*\{(?<body>[^{}]*)\}")) {
            $path = $m.Groups['path'].Value
            $keys = @([regex]::Matches($m.Groups['body'].Value, '(?m)(?:^|[\s,{])([a-zA-Z][a-zA-Z0-9]*)\s*:') |
                ForEach-Object { $_.Groups[1].Value })
            if ($keys.Count -gt 0) { $found.Add([pscustomobject]@{ Path = $path; Keys = $keys; Method = $null }) }
        }
        # api('POST', `runs/.../acknowledge`, { topic: 'x' }) - the wizard's shape
        foreach ($m in [regex]::Matches($pageText, "api\(\s*'POST'\s*,\s*[\`"'``](?<path>[^\`"'``]+)[\`"'``]\s*,\s*\{(?<body>[^{}]*)\}")) {
            $path = $m.Groups['path'].Value
            $keys = @([regex]::Matches($m.Groups['body'].Value, '(?m)(?:^|[\s,{])([a-zA-Z][a-zA-Z0-9]*)\s*:') |
                ForEach-Object { $_.Groups[1].Value })
            if ($keys.Count -gt 0) { $found.Add([pscustomobject]@{ Path = $path; Keys = $keys; Method = 'POST' }) }
        }
        $found
    }

    # Which handler serves a path like runs/${runSeg()}/engine/wave
    function Script:HandlerFor([string]$path, [string]$method) {
        $normalised = ($path -replace '\$\{[^}]*\}', '{x}') -replace '`', ''
        foreach ($h in $script:handlers) {
            $pattern = '^' + ([regex]::Escape($h.Route) -replace '\\\{[^}]*\\\}', '[^/]+') + '$'
            if ($normalised -notmatch $pattern) { continue }
            # A body is only sent by a method that carries one, so when the call
            # site names its method, honour it. Without this, GET /projects was
            # asked to read POST /projects' body and reported as dropping it.
            if ($method -and $h.Methods -and ($method -notin $h.Methods)) { continue }
            return $h
        }
        $null
    }
}

Describe 'EVAL-H6: every field a page sends is read by the endpoint it sends it to' {
    It 'found pages and handlers to compare' {
        @($script:handlers).Count | Should -BeGreaterThan 5
        @($script:pages).Count | Should -BeGreaterThan 3
    }

    It 'no key is posted into a void' {
        $dropped = foreach ($page in $script:pages) {
            foreach ($call in Script:BodyKeys $page.Text) {
                $handler = Script:HandlerFor $call.Path $call.Method
                if (-not $handler) { continue }   # covered by the route test elsewhere
                foreach ($key in $call.Keys) {
                    # the handler must mention the key - it reads $body.<key>
                    if ($handler.Text -notmatch "\`$body\.$([regex]::Escape($key))\b") {
                        "$($page.Name) sends '$key' to $($handler.Name) ($($call.Path)), which never reads it"
                    }
                }
            }
        }
        $dropped -join '; ' | Should -BeNullOrEmpty -Because 'the call still succeeds, so nothing else can catch this'
    }

    It 'the restore specifically forwards its copy' {
        # The finding that produced this test (a rebuild's two choices) was
        # dropped. REBUILD-REMOVE-RECOVER-1: the rebuild is gone, and the
        # restore's copy, which RESTORE-COPY-1 found dropped the same way, stays.
        $start = $script:handlers | Where-Object Name -eq 'PostStartEngine'
        $start.Text | Should -Match '\$body\.diskSource'
        $start.Text | Should -Match 'DiskSource'
        $start.Text | Should -Not -Match '\$body\.as\b|RebuildAs'
    }
}

Describe 'EVAL-H6, the other direction: a parameter FacadeCore declares must be bound by its handler' {
    # The first half of this file catches a page sending a field nobody reads.
    # This catches the half that actually happened: FacadeCore DECLARING a
    # parameter, using it to emit an environment override, and the handler
    # never binding it - so the engine silently ran on defaults while the
    # caller got HTTP 202.
    #
    # Derived from the function's own parameter block, so an operation added
    # later cannot forget one of its parameters quietly.
    It 'PostStartEngine binds every parameter Invoke-VmfFacadeStartEngine declares' {
        $core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $fn = [regex]::Match($core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Not -BeNullOrEmpty
        $block = [regex]::Match($fn, '(?ms)^    param\((.*?)^    \)').Groups[1].Value
        $declared = @([regex]::Matches($block, '(?m)\]\$(\w+)') | ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique | Where-Object { $_ -notin @('Principal', 'Operation', 'RunId') })
        @($declared).Count | Should -BeGreaterThan 10 -Because 'the parameter block must actually have been read'

        $handler = ($script:handlers | Where-Object Name -eq 'PostStartEngine').Text
        # Two binding forms are legitimate: assignment after the fact
        # ($params.Wave = ...) and the initial hashtable literal
        # (Note      = [string]$body.note). Both count; neither being
        # present is the defect.
        $unbound = @($declared | Where-Object {
                $n = [regex]::Escape($_)
                $handler -notmatch "(?m)(\`$params\.$n\s*=|^\s+$n\s*=)" })
        $unbound -join ', ' | Should -BeNullOrEmpty -Because @'
FacadeCore declares these and the handler never binds them, so they can never
arrive. The call still returns 202 and the engine runs on its defaults - which
is how EVAL-H6 hid on the most destructive operation in the tool.
'@
    }
}
