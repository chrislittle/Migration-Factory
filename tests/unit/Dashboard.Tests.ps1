#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dashboard = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'migrations.html'))
}

Describe 'Migration Dashboard (COCK-1/COCK-3 ledger) - contract and read-only guarantees' {

    It 'reads only documented JSON-contract paths' {
        foreach ($contractPath in @('run-status.json', 'logs/events.jsonl', 'plan.json', 'halt.flag', 'dashboard.config.json')) {
            $dashboard | Should -Match ([regex]::Escape($contractPath))
        }
        # PERF-PROBES-1: the open run's folders come from one listing of the run
        # (folder), which lists the folder itself only when that listing is not known.
        $dashboard | Should -Match "folder\('state'\)"
        $dashboard | Should -Match "folder\('capacity'\)"
    }

    It 'mutates ONLY through the facade client, never against storage (S3-5)' {
        # Exactly one mutating verb in the whole page: the POST inside apiFetch.
        # REBUILD-REMOVE-DOCS-1: counted as an HTTP verb, because the sample
        # plan's entries carry target.choice.method ('preview'), the field the
        # engine writes - that is data, not a request.
        ([regex]::Matches($dashboard, "(?i)method:\s*['`"](GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)['`"]")).Count | Should -Be 1
        $dashboard | Should -Not -Match "method:\s*['`"](PUT|DELETE|PATCH)"
        $apiFetch = [regex]::Match($dashboard, '(?s)async function apiFetch.*?\n\}').Value
        $apiFetch | Should -Match "method:\s*'POST'"
        $apiFetch | Should -Match 'cfg\.apiUrl' -Because 'mutations go to the facade base URL only'
        # The storage reader carries no method override (GET) and no write headers.
        $blobFetch = [regex]::Match($dashboard, '(?s)async function blobFetch.*?\n\}').Value
        $blobFetch | Should -Not -Match 'method:'
    }

    It 'gates every action behind app roles and requires a recorded note (S3-5)' {
        $dashboard | Should -Match 'Vmf\.Approver'
        $dashboard | Should -Match 'Vmf\.Operator'
        $dashboard | Should -Match 'Vmf\.Admin'
        $dashboard | Should -Match 'hasRole' -Because 'UI gating mirrors the facade role checks'
        $dashboard | Should -Match 'noteMissing' -Because 'an empty note must be rejected before the call'
        $dashboard | Should -Match 'access_as_user' -Because 'actions use the delegated API scope, as the signed-in user'
    }

    It 'stays fully read-only when no facade is configured' {
        $dashboard | Should -Match 'cfg\?\.apiUrl' -Because 'without apiUrl the page must render zero action controls'
    }

    It 'the setup flow offers resource group, chosen subscriptions, or a management group (SCOPE-1)' {
        # Moved with the flow: the wizard asks this now, and still offers all
        # three - a scan scoped only to one resource group was the original
        # complaint behind SCOPE-1.
        $wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        foreach ($s in 'scopeRgOpt', 'scopeSubsOpt', 'scopeMgOpt') { $wiz | Should -Match $s }
        $wiz | Should -Match 'scopeSubs'
        $wiz | Should -Match 'scopeMg'
    }

    It 'the setup flow never blocks on the service, and says so while it works' {
        # This used to be checked on a dashboard dialog that the wizard replaced.
        # The guarantee did not move - the test did.
        $wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match 'class="working"'
        $wiz | Should -Match 'class="spin"'
        $wiz | Should -Match 'startPolling\(\)' -Because 'it watches the run rather than freezing on a request'
    }

    It 'scopes are picked from real lists, never free-typed' {
        $wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match 'id="f-sub"'
        # SCOPE-PICK-1: the resource groups are TICKED from the list now, not
        # picked one at a time, because a real estate is spread across several.
        # The rule is unchanged - the names come from the service, never from a
        # person typing one - so this checks the shape rather than the id.
        $wiz | Should -Match 'id="f-rgs"'
        $wiz | Should -Match "name=`"f-rgs`" value="
        $wiz | Should -Not -Match 'id="f-rgs" type="text"' -Because 'a typed scope is a scope nobody can verify'
        $wiz | Should -Match 'scopes\?\.subscriptions' -Because 'the lists come from what the service reports'
        # the run NAME is deliberately typed - it is the customer's own word
        $wiz | Should -Match 'id="f-name"'
    }

    It 'asks for a reason only where something CHANGES' {
        # Starting a wave changes machines, so it asks. Accepting settings is
        # agreement, not justification, so it does not ask "why" - the person
        # who accepts has nothing to justify.
        $wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match 'noteMissing' -Because 'starting a wave requires a note'
        $accept = [regex]::Match($script:idx ?? $dashboard, '(?s)function askAcceptOptions\(wave\).*?
\}').Value
        $accept | Should -Not -Match 'noteField'
    }

    It 'shows the machines a scan found, before any plan exists' {
        # A scan that produces nothing visible makes the whole flow senseless.
        $dashboard | Should -Match 'function renderFound'
        # PERF-PROBES-1: read when the listing of the run names it.
        # PAGE-LOAD-2: or from the run's one call, which holds it.
        $dashboard | Should -Match "doc\('assessment\.json'\)"
        # WAVE-RUNNING-LEASE-1: 'plan-*.json' names plan-approval.json and plan-run.json.
        $dashboard | Should -Match "'assessment\.json'.*'plan-\*\.json'" -Because 'RUN_READS names it'
        $dashboard | Should -Match 'id="found"'
        $dashboard | Should -Match 'UX_FOUND' -Because 'classifications are rendered in real words'
        $dashboard | Should -Match 'reasonText' -Because 'blockers and prep items are explained plainly'
        # raw engine vocabulary stays OUT of the linted string block
        $uxBlock = [regex]::Match($dashboard, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END').Groups[1].Value
        $uxBlock | Should -Not -Match 'stornvme'
        # The wording lives in the engine's assessment-reasons.json now, copied
        # to the dashboard by the deploy. It used to be a map in this page AND a
        # different one in the wizard, and both were missing five of the seven
        # blockers - so a machine held back as confidential showed a raw code.
        $dashboard | Should -Match "fetch\('assessment-reasons\.json'\)"
        $dashboard | Should -Not -Match 'const REASON_MAP' -Because 'the page must not keep its own copy'
    }

    It 'always says what happens next instead of leaving an empty page' {
        $dashboard | Should -Match 'function renderNextStep'
        # doneScan/donePlan USED TO BE HERE and were removed by STRING-SWEEP-1.
        # They were the "Looking for machines now..." messages shown after the
        # IN-PAGE dialog was submitted, and that dialog moved to the wizard -
        # which the very next test in this file pins. nextWorking covers the
        # same state on this page now, and the wizard has its own progress text.
        # Listing them here made a stale assertion look like coverage.
        foreach ($s in 'nextNoRun', 'nextNoPlan', 'nextWorking', 'nextTitle', 'nextPlanned') {
            $dashboard | Should -Match $s
        }
        $dashboard | Should -Match 'id="nextstep"'
    }



    It 'scanning and planning route to the wizard, which owns them' {
        # The dashboard used to carry its own "new migration" and "build the
        # plan" dialogs. They became unreachable when the wizard took over and
        # sat there declared-but-never-called until a lint found them. The
        # dashboard now ROUTES, and this pins that rather than the dead code.
        $askPlanGone = $script:idx ?? $dashboard
        $askPlanGone | Should -Not -Match 'function askBuildPlan'
        $askPlanGone | Should -Not -Match 'function askNewRun'
        $askPlanGone | Should -Match "href=\`"wizard\.html"
    }

    It 'WAVE-2: the ring vocabulary is gone from every SURFACE, not just the engine' {
        # This replaces assertions that PINNED the ring fields in place - which
        # is why removing rings from the engine in phase A left a BROKEN path:
        # the dashboard still sent defaultRing, the facade forwarded it, and the
        # container passed -DefaultRing to a cmdlet that no longer has it. Every
        # plan built from the dashboard would have failed at the plan step.
        $files = @{
            'dashboard'  = $dashboard
            'wizard'     = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
            'waves page' = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
            'reports'    = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'reports.html'))
            'facade'     = Get-Content (Join-Path $repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
            'start job'  = Get-Content (Join-Path $repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Raw
            'container'  = Get-Content (Join-Path $repoRoot 'docker' 'entrypoint.ps1') -Raw
        }
        foreach ($name in $files.Keys) {
            foreach ($dead in 'defaultRing', 'DefaultRing', 'VMF_DEFAULT_RING', 'ringTag') {
                $files[$name] | Should -Not -Match ([regex]::Escape($dead)) -Because "$name must not carry the removed ring vocabulary"
            }
        }
        foreach ($name in 'dashboard', 'wizard', 'waves page', 'reports') {
            $files[$name] | Should -Not -Match "'(?:canary|prod|lab|nonprod)-\d+'" -Because "$name samples must show waves a customer named, not ours"
        }
    }

    It 'capacity is chosen PER WAVE in the editor, with the availability-set caveat there (CAP-3)' {
        $wavesPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $wavesPage | Should -Match 'capOnDemand'
        $wavesPage | Should -Match 'capReserved'
        $wavesPage | Should -Match 'capTip' -Because 'the availability-set limitation belongs where capacity is chosen'
        $wavesPage | Should -Match 'data-cap'
        # the engine still accepts a plan-wide default for scripted runs
        $facade = Get-Content (Join-Path $repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $facade | Should -Match 'CapacityGate'
    }

    It 'authenticates viewers as THEMSELVES (no keys, no SAS)' {
        # STORE-READ-1: the marker changed, the rule did not. The page used to
        # ask Entra for a STORAGE token and read blob directly; it now asks for
        # a token for the service and the service reads. Either way the token
        # is the signed-in viewer's own - the thing this test exists to stop is
        # a shared secret standing in for a person, and it still cannot happen.
        $dashboard | Should -Match 'access_as_user'
        $dashboard | Should -Not -Match 'storage\.azure\.com' -Because 'the browser no longer holds a storage token'
        $dashboard | Should -Not -Match 'sig=' -Because 'no SAS tokens'
        $dashboard | Should -Not -Match 'AccountKey' -Because 'no storage keys'
    }

    It 'escapes untrusted store content before injecting into the DOM' {
        $dashboard | Should -Match 'const esc ='
        $dashboard | Should -Match 'esc\(vmName\('
        $dashboard | Should -Match 'esc\(stepText\('
    }

    It 'ships a demo mode that never requires auth or config' {
        $dashboard | Should -Match 'DEMO_MODE'
        $dashboard | Should -Match "has\('demo'\)"
    }

    It 'sample config parses and carries the required fields' {
        $cfg = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw | ConvertFrom-Json
        foreach ($f in 'tenantId', 'clientId', 'refreshSeconds', 'apiUrl', 'apiAppId') {
            $cfg.PSObject.Properties.Name | Should -Contain $f
        }
        # STORE-READ-1: `storageAccount`, `storageAccountId` and `container`
        # were required fields and are gone. No page reads the store directly,
        # so the browser has no use for any of them - and a config field
        # nothing reads is a claim that something still works that way.
        foreach ($f in 'storageAccount', 'storageAccountId', 'container') {
            $cfg.PSObject.Properties.Name | Should -Not -Contain $f
        }
    }
}

Describe 'COCK-3 core principle: UX surfaces speak plain language' {
    # The audience knows what a virtual machine and a disk are - NOTHING else.
    # All user-facing strings live between the UX-STRINGS markers; this lint
    # fails the moment engine vocabulary leaks into them (REH-2, seen live:
    # "VM shell" is engine vocabulary, not a term the operator knows).
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $m = [regex]::Match($script:dashboard, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
        $script:uxBlock = $m.Groups[1].Value
    }

    It 'has the marked UX-strings block' {
        $uxBlock | Should -Not -BeNullOrEmpty
    }

    It 'UX strings contain no internal or platform vocabulary' {
        # Values only: string literals inside the block, minus code-side words.
        $values = [regex]::Matches($uxBlock, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }
        # ONE vocabulary, in tools/Test-SimplifiedEnglish.ps1. This assertion
        # used to carry its own copy of the banned list; there were six copies
        # in this file alone and they had already drifted apart - and the copy
        # that banned 'NVMe' is what forced the reason wording to say "the new
        # disk type", which names nothing. STE-1.
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'index' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'PLANTIME-1: the run page makes no planning decisions' {
        # The run page carried planning buttons, and once a wave runs it is too
        # late for that kind of planning. A quota increase takes
        # DAYS and a reservation wants creating a day or two ahead, and both sat
        # on the screen you open when you are about to press start.
        #
        # They live in the wizard's Capacity step now. This page still SHOWS the
        # capacity picture - watching it is a run-time concern - it just offers
        # no decision that belongs earlier.
        $dashboard = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'migrations.html'))
        foreach ($gone in 'askReserveCapacity', 'askReleaseCapacity', 'askQuota', 'renderCapacityActions') {
            $dashboard | Should -Not -Match $gone -Because "$gone is a plan-time decision and belongs in the wizard"
        }
        # And they exist at plan time, so this is a MOVE rather than a loss.
        # WAVE-FLOW-1 moved them once more, from the wizard's capacity step to
        # the wave editor - which IS the plan-time screen now, and is where the
        # per-wave quota check that finds the shortfall already lived. Still
        # plan time; one screen closer to the thing it is about.
        $waves = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Match 'engine/reserve'
        $waves | Should -Match 'engine/quota'
    }

    It 'the navigation bar is defined in ONE place' {
        # Found 2026-08-31: the navigation bars did not agree from page to
        # page. Because six pages each carried their own copy of the
        # labels, so the same tab was whatever each page happened to say. Two
        # had drifted: one page called Runs "Migrations" while five said
        # "Runs", and index called Admin "Manage access".
        #
        # A page cannot disagree about a label it does not hold.
        foreach ($page in Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter *.html) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Not -Match "nav(Runs|Reports|Admin|Assess)\s*:" -Because "$($page.Name) must not carry its own nav labels"
            $text | Should -Not -Match "nav-(runs|reports|access|assess)'\)\.textContent" -Because "$($page.Name) must not set nav text"
        }
    }

    It 'and every page has the empty bar for it to fill, and loads the file that fills it' {
        foreach ($page in Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter *.html) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Match '<nav class="topnav"></nav>' -Because "$($page.Name) needs the container"
            $text | Should -Match 'src="help.js"' -Because "$($page.Name) needs the file that renders it"
        }
    }

    It 'the active tab is derived from the address, not declared per page' {
        # A page that names its own active tab is a page that can name the
        # wrong one - and did, on every page that was copied from another.
        $help = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'location\.pathname'
        foreach ($page in Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter *.html) {
            ((Get-VmfPageSource -Path $page.FullName)) | Should -Not -Match 'id="nav-[a-z]+" class="active"'
        }
    }

    It 'every dashboard page is on the deploy list' {
        # The deploy script refuses a file that is LISTED and missing. This is
        # the other direction: a page that exists and is not listed simply never
        # ships, and the only symptom is a 404 on a link that looks right.
        $deploy = Get-Content (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $pages = Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter *.html |
            ForEach-Object { $_.Name }
        @($pages).Count | Should -BeGreaterThan 3 -Because 'the pages must actually have been found'
        $missing = @($pages | Where-Object { $deploy -notmatch [regex]::Escape($_) })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a page that is not deployed is a 404 on a link that looks right'
    }

    It 'no UX string contains an HTML entity' {
        # Found 2026-08-31: the access console showed
        # "Reading what the tool can reach&hellip;" on screen. These strings are
        # assigned three different ways - textContent, innerHTML, and esc() into
        # an attribute - and an entity only survives ONE of them. textContent
        # prints it literally; esc() turns the & into &amp; so it prints
        # literally too. Three strings were wrong, and an earlier one had been
        # patched in place with .replace('&hellip;', '…') rather than fixed.
        #
        # Real characters work in all three. So the rule is: no entities here.
        foreach ($page in 'index.html', 'migrations.html', 'reports.html', 'access.html', 'waves.html', 'wizard.html') {
            $text = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' $page))
            $m = [regex]::Match($text, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
            if (-not $m.Success) { continue }
            $hits = @([regex]::Matches($m.Groups[1].Value, '&[a-zA-Z]+;|&#\d+;') |
                ForEach-Object { $_.Value } | Sort-Object -Unique)
            $hits -join ', ' | Should -BeNullOrEmpty -Because "$page must use real characters - an entity renders literally through textContent and esc()"
        }
    }

    It 'guard the guard: the lint still catches a banned word next to an allowed role name' {
        # The exception strips the exact role name and nothing else, so a
        # string that says "Storage Blob Data Reader" AND talks about blobs
        # separately must still fail. Otherwise the exception is a hole.
        $v = 'Grant Storage Blob Data Reader so the app can read the blob store'
        $stripped = $v.Replace('Storage Blob Data Reader', '')
        $stripped -match 'blob' | Should -BeTrue
    }

    It 'and an apostrophe in a comment inside the block breaks the extraction' {
        # Learned the hard way 2026-08-30: the value extraction pairs
        # apostrophes, so ONE in a comment shifts every pairing after it and
        # the lint starts reading code as UX text. It reports a nonsense
        # violation rather than the real one, which is a confusing hour.
        $comments = [regex]::Matches($script:uxBlock, '(?m)^\s*//.*$') | ForEach-Object { $_.Value }
        $offenders = @($comments | Where-Object { $_ -match "'" })
        $offenders -join ' | ' | Should -BeNullOrEmpty `
            -Because 'an apostrophe in a comment here silently corrupts the lint above'
    }

    It 'renders wave sections by NAME order with a sign-off gate - no ring vocabulary (WAVE-2)' {
        $dashboard | Should -Not -Match "RING_ORDER = \[" -Because 'rings are gone; waves are customer-named'
        $dashboard | Should -Match 'localeCompare'
        $dashboard | Should -Match 'gateText'
        $dashboard | Should -Match 'byWave'
    }

    It 'shows migration methods by their real names, never bare path letters (NAME-1 display)' {
        # NAME-1's point is that a page never shows a bare path LETTER. The
        # words themselves belong to PATH-NAME-1, which reads them out of the
        # page and holds the manual to the same two - so they are not written
        # down a second time here, where they would go stale on a rename.
        $map = [regex]::Match($dashboard, "(?m)^const UX_PATH = \{ A: '([^']+)' \};")
        $map.Success | Should -BeTrue -Because 'the page declares a word for the path'
        foreach ($group in @($map.Groups[1])) {
            $group.Value | Should -Not -Match '^[AB]$'
            $group.Value.Length | Should -BeGreaterThan 4 -Because 'a letter with punctuation is still a letter'
        }
        # Engine detail strings ("Path B recreation complete") get the same
        # treatment in displayed technical lines - raw stays in the tooltip
        # (residual Path A/B was leaking into machine details).
        $dashboard | Should -Match 'techText\(h\.detail\)'
        $dashboard | Should -Match 'title="\$\{esc\(h\.detail\)\}"'
        $reportsPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'reports.html'))
        $reportsPage | Should -Match 'techText\(i\.detail\)'
    }

    It 'decomposes capacity into quota and reservation facets' {
        $dashboard | Should -Match 'function quotaFacet'
        $dashboard | Should -Match 'function reservationFacet'
        $dashboard | Should -Match 'reservableInstances'
    }

    It 'carries the observed-friction fixes: liveness, stuck detection, refresh countdown, evidence viewer' {
        $dashboard | Should -Match 'updatedUtc'          # run-picker liveness sort
        $dashboard | Should -Match 'STUCK_SECONDS'       # elapsed-in-state warning
        $dashboard | Should -Match 'next in'             # refresh countdown
        $dashboard | Should -Match 'evlink'              # inline evidence viewer
        $dashboard | Should -Match 'status-chips'        # real status filter
        $dashboard | Should -Match 'vmCategory'
    }

    It 'feedback round: signed-in name, top-level nav, home brand link, remembered run, live run list' {
        # BAR-1: the signed-in person is still shown, but the ELEMENT is built
        # by help.js now rather than declared here. Seven pages carried this
        # markup and access.html did not, so the admin page lost the theme
        # button, the sign-out and its own alignment. Asserting the markup per
        # page is asserting the thing that drifted; assert the one mechanism.
        $navSrc = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw
        $navSrc | Should -Match "who\.id = 'who'"                   # signed-in person shown, GHCP style
        $dashboard | Should -Match 'VmfHelp\.identity\('            # and this page asks for it
        # The nav is rendered from help.js now (one place, so it cannot drift),
        # so the tab is asserted where it is defined rather than in each page.
        $navSource = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw
        $navSource | Should -Match "id: 'access'"                   # admin surfaces in the top nav, not Start work
        # The product name is a LABEL now, not a link (2026-09-01): clicking it
        # opened the migrations page, and with several areas there is no one
        # home for it to go to. This reverses an earlier round of feedback,
        # and rightly - back then there was one area to go home to.
        $dashboard | Should -Match '<span class="brand">'
        $dashboard | Should -Match 'vmf-last-run'                   # picker defaults to the last-viewed run
        $dashboard | Should -Match 'loadRuns'                       # run list refreshes without a page reload
        $access = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'access.html'))
        $access | Should -Match '<span class="brand">'
    }

    It 'keeps the raw technical record reachable (tooltips), never erased' {
        $dashboard | Should -Match 'title="\$\{esc\(raw\)\}"'
    }

    It 'the activity feed shows ONE line per step (layered records looked like duplicates)' {
        # RESTORE-PANEL-TIMELINE-1: the line rule of the feed is activityLines, which the machine panel shares.
        $renderEvents = [regex]::Match($dashboard, '(?s)function activityLines.*?\n\}').Value
        $dashboard | Should -Match 'const recent = activityLines\(events, showWholeLog, showWholeLog \? Infinity : FEED_RECENT\);'
        $renderEvents | Should -Match "outcome === 'start'" -Because 'start markers are technical layering, not activity'
        $renderEvents | Should -Match 'shownAt' -Because 'same sentence + same machine within a window collapses to one row'
        $renderEvents | Should -Match "fail" -Because 'a failed repeat must never be collapsed into an earlier success'
    }
}

Describe 'Access console (S3-6 / ROLE-1)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:access = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'access.html'))
    }

    It 'acts only through Microsoft Graph as the signed-in admin - no facade, no storage, no secrets' {
        $access | Should -Match 'graph\.microsoft\.com/v1\.0'
        $access | Should -Not -Match 'blob\.core\.windows\.net' -Because 'the console never touches the run store'
        $access | Should -Not -Match 'sig=' -Because 'no SAS tokens'
        $access | Should -Not -Match 'AccountKey' -Because 'no storage keys'
    }

    It 'requests only delegated Graph scopes (the directory stays the real gate)' {
        foreach ($s in 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All',
                       'User.ReadBasic.All', 'Group.Read.All') {
            $access | Should -Match ([regex]::Escape($s))
        }
        $access | Should -Not -Match '\.default' -Because 'explicit delegated scopes, not app-wide default'
    }

    It 'gates the page to administrators and explains the denial plainly' {
        $access | Should -Match "Vmf\.Admin"
        $access | Should -Match 'notAdminCopy'
    }

    It 'covers users AND groups (group members inherit the role)' {
        $access | Should -Match 'appRoleAssignedTo'
        $access | Should -Match "graph\('GET', ``groups"
        $access | Should -Match "graph\('GET', ``users"
    }

    It 'speaks plain language: every role has a person-readable word and description' {
        $m = [regex]::Match($access, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
        $m.Success | Should -BeTrue
        foreach ($r in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin') {
            $access | Should -Match ([regex]::Escape("'$r':"))
        }
        # ONE vocabulary, in tools/Test-SimplifiedEnglish.ps1. This assertion
        # used to carry its own copy of the banned list; there were six copies
        # in this file alone and they had already drifted apart - and the copy
        # that banned 'NVMe' is what forced the reason wording to say "the new
        # disk type", which names nothing. STE-1.
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'access' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'escapes directory content before injecting into the DOM' {
        $access | Should -Match 'const esc ='
        $access | Should -Match 'esc\(p\.name\)'
    }

    It 'the console is reachable from the standard nav; the page itself gates non-admins' {
        # Decided: the nav is identical on every page, so Admin is always
        # visible - the console explains itself to non-admins (notAdminCopy)
        # and the directory is the real gate.
        (Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw) | Should -Match "href: 'access\.html'"
        $access | Should -Match 'notAdminCopy'
    }
}

Describe 'Reports page (REPORT-2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:reports = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'reports.html'))
    }

    It 'is strictly read-only: no mutating HTTP verbs at all' {
        $reports | Should -Not -Match "method:\s*['`"]" -Because 'the reports page never mutates anything'
        $reports | Should -Not -Match 'sig=' -Because 'no SAS tokens'
        $reports | Should -Not -Match 'AccountKey' -Because 'no storage keys'
    }

    It 'reads only documented contract paths and derives everything from them' {
        foreach ($p in 'run.json', 'run-status.json', 'plan.json', 'customer-report.html') {
            $reports | Should -Match ([regex]::Escape($p))
        }
        $reports | Should -Match "listFolder\(run, 'state'\)"
        $reports | Should -Match "listFolder\(run, 'capacity'\)"
        $reports | Should -Match "listFolder\(run, 'approvals'\)"
    }

    It 'opens the private customer report with the viewer''s own token, never a bare link' {
        $reports | Should -Match "readText\(run, 'customer-report\.html'\)"
        $reports | Should -Not -Match 'href="https://[^"]*customer-report' -Because 'a bare blob link would 404/401 without a token'
    }

    It 'links each run into the dashboard' {
        $reports | Should -Match 'VmfRun\.link\('migrations\.html''
        # RUN-LINK-1: this matched `get('run')` for weeks while the link never
        # opened its migration. tests/js/run-link.test.js RUNS the page's code.
        $dashboard | Should -Match 'linkedRunId\(location\.search' -Because 'the dashboard honors the ?run= deep link'
        (Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw) |
            Should -Match "href: 'reports\.html'" -Because 'reports is a top-level nav item'
    }

    It 'speaks plain language (same banned-vocabulary bar, acronyms case-sensitive)' {
        $m = [regex]::Match($reports, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
        $m.Success | Should -BeTrue
        # ONE vocabulary, in tools/Test-SimplifiedEnglish.ps1. This assertion
        # used to carry its own copy of the banned list; there were six copies
        # in this file alone and they had already drifted apart - and the copy
        # that banned 'NVMe' is what forced the reason wording to say "the new
        # disk type", which names nothing. STE-1.
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'reports' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'escapes store content and ships a demo mode' {
        $reports | Should -Match 'const esc ='
        $reports | Should -Match 'esc\(i\.name\)'
        $reports | Should -Match 'DEMO_MODE'
    }
}

Describe 'Wave editor (WAVE-1 phase 2)' {
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wavesPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html')) }

    It 'mutates only through the facade, and only the wave layout endpoint' {
        # Counts MUTATING verbs, not every method literal. It used to count
        # both, which said the same thing only while the page never read
        # anything - REACH-2 added a GET (the capacity gate's answer) and the
        # check failed on a call that mutates nothing. The rule is about
        # writes; now it says so.
        $verbs = [regex]::Matches($wavesPage, "method:\s*'([A-Z]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -ne 'GET' }
        @($verbs).Count | Should -Be 1 -Because 'the wave editor writes in exactly one place'
        @($verbs)[0] | Should -Be 'POST'
        $wavesPage | Should -Match 'runs/\$\{runSeg\(\)\}/plan/waves'
        $wavesPage | Should -Match 'cfg\.apiUrl'
    }

    It 'the wave editor finds machines by ANY tag, by resource group, or by picking' {
        $wavesPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $wavesPage | Should -Match 'id="f-tagkey"'
        $wavesPage | Should -Match 'id="f-rg"'
        $wavesPage | Should -Match 'selectAll'
        $wavesPage | Should -Match 'class="pick"' -Because 'picking has to be visible to be a way in'
    }

    It 'no UX string contains an unbalanced quote (a stray apostrophe breaks the page)' {
        # Found live: "machine's" inside a single-quoted string took the whole
        # dashboard down with a syntax error. A blank page is the worst
        # possible failure, so it gets its own guard.
        foreach ($page in 'index.html', 'migrations.html', 'reports.html', 'access.html', 'waves.html', 'wizard.html') {
            $html = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' $page))
            $block = [regex]::Match($html, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END').Groups[1].Value
            $bad = foreach ($line in ($block -split "`n")) {
                $stripped = $line -replace "\'", ''          # escaped quotes are fine
                $stripped = $stripped -replace '//.*$', ''       # trailing comments
                $count = ([regex]::Matches($stripped, "'")).Count
                if ($count % 2 -ne 0) { $line.Trim() }
            }
            ($bad -join ' | ') | Should -BeNullOrEmpty -Because "$page has an unbalanced quote"
        }
    }

    It 'every user-facing string is plain ASCII (no stray characters)' {
        foreach ($page in 'index.html', 'migrations.html', 'reports.html', 'access.html', 'waves.html') {
            $html = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' $page))
            $block = [regex]::Match($html, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END').Groups[1].Value
            $bad = [regex]::Matches($block, '[^\x00-\x7F]') | ForEach-Object { $_.Value } | Select-Object -Unique
            ($bad -join ' ') | Should -BeNullOrEmpty -Because "$page UX strings should be plain ASCII"
        }
    }

    It 'supports the whole runbook: create, rename, delete waves and move machines' {
        $wavesPage | Should -Match 'addWave'
        $wavesPage | Should -Match 'data-rename'
        $wavesPage | Should -Match 'data-del'
        $wavesPage | Should -Match 'function moveTo'
        $wavesPage | Should -Match 'dragstart' -Because 'machines can be dragged between waves'
    }

    It 'gives every wave its capacity choice and sign-off rule - and NO ring selector (WAVE-2)' {
        $wavesPage | Should -Not -Match 'data-ring' -Because 'the environment dropdown died with the taxonomy'
        $wavesPage | Should -Match 'data-cap'
        $wavesPage | Should -Match 'data-appr'
        $wavesPage | Should -Match 'capReserved'
    }

    It 'keeps availability sets together and refuses to move machines already under way' {
        $wavesPage | Should -Match 'function expand' -Because 'moving one member moves the whole set'
        $wavesPage | Should -Match 'VmfHelp\.machineStarted'
        $wavesPage | Should -Match 'started\(id\)'
        $wavesPage | Should -Match 'lockedTip'
    }

    It 'says plainly that changing a wave means approving it again' {
        $wavesPage | Should -Match 'savedApprovals'
        $wavesPage | Should -Match 'ApprovalsInvalidated'
    }

    It 'is read-only for non-operators and speaks plain language' {
        $wavesPage | Should -Match 'notAllowedCopy'
        $wavesPage | Should -Match 'canEdit'
        $m = [regex]::Match($wavesPage, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
        $m.Success | Should -BeTrue
        # ONE vocabulary, in tools/Test-SimplifiedEnglish.ps1. This assertion
        # used to carry its own copy of the banned list; there were six copies
        # in this file alone and they had already drifted apart - and the copy
        # that banned 'NVMe' is what forced the reason wording to say "the new
        # disk type", which names nothing. STE-1.
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'waves' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'is reachable from the run view' {
        $dashboard | Should -Match "runHref\('waves\.html'\)|VmfRun\.link\('waves\.html'"
        $dashboard | Should -Match 'arrangeWaves'
    }
}

Describe 'Scheduling a wave (SCHED-1)' {
    It 'starting later is the same dialog as starting now' {
        $askStart = [regex]::Match($dashboard, '(?s)function askStartWave\(.*?
\}').Value
        $askStart | Should -Match "value: 'now'"
        $askStart | Should -Match "value: 'later'"
        $askStart | Should -Match 'waves/\$\{encodeURIComponent\(wave\)\}/schedule'
        $askStart | Should -Match 'whenPast' -Because 'a time in the past is refused before the call'
        $askStart | Should -Match 'noteField\(\)' -Because 'scheduling changes something, so it needs a reason'
    }

    It 'a scheduled wave is visible and can be called off' {
        $dashboard | Should -Match 'scheduledFor'
        $dashboard | Should -Match 'data-cancelsched'
        $dashboard | Should -Match 'function askCancelSchedule'
        $dashboard | Should -Match "folder\('schedules'\)"  # PERF-PROBES-1: from the one listing of the run
        # and while scheduled, the start button steps aside
        # LAB-UX-1: the start control is waveStartHtml now, which reads it as o.sched;
        # finished-plan-words.test.js RUNS it with a schedule.
        $dashboard | Should -Match '!o\.sched &&'
    }

    It 'SCHEDULE-START-SHOWN-1: the card asks the schedule state, and the manual says what a starting schedule shows' {
        # tests/js/schedule-start-shown.test.js RUNS waveScheduleHtml for each
        # state; this holds that the wave card uses it and the manual says it.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code =Get-VmfCodeOnly -Path (Join-Path $repoRoot 'src' 'dashboard' 'migrations.js')
        # STOP-STATE-SHOWN-1: and whether a person stopped the migration.
        $code | Should -Match ([regex]::Escape('waveScheduleHtml(wave, sched, canOperate(), Boolean(runStop))'))
        $code | Should -Match ([regex]::Escape("['starting', 'started'].includes(sched.state)"))
        $code | Should -Match "scheduleStarting:\s*'The wave is starting\.'"
        $manual = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'docs' 'manual' 'use' 'start.md'))
        $manual | Should -Match ([regex]::Escape('the wave shows **The wave is starting.** before the time, and it does not show **Cancel the scheduled start**'))
    }

    It 'the engine keeps sign-off ahead of the schedule' {
        $facade = Get-Content (Join-Path $repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $facade | Should -Match 'has not been approved'
        $facade | Should -Match 'Invoke-VmfFacadeReleaseDueSchedules'
        # the timer only releases decisions already recorded in the store
        $runner = Get-Content (Join-Path $repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Raw
        $runner | Should -Match 'Invoke-VmfFacadeReleaseDueSchedules'
        $timer = Get-Content (Join-Path $repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'function.json') -Raw
        $timer | Should -Match 'timerTrigger'
    }
}

Describe 'Restore in the UX (RESTORE-1)' {
    It 'offers the restore only where a safety copy exists, to operators' {
        $dashboard | Should -Match 'function askRestore'
        # DISCARD-ENGINE-1 review 2: the rule moved into restoreOffered, which
        # also leaves out copies recorded as deleted; tests/js/discard-engine
        # runs it. Here: the button is drawn through it.
        # RESTORE-ONE-AT-A-TIME-1: through putBackControls, which also leaves
        # it out while a restore of the machine runs - and asks
        # restoreOffered for the rest (tests/js/restore-one-at-a-time runs it).
        $dashboard | Should -Match 'const restoreBtn = putBack\.restore\b' `
            -Because 'a machine that never reached the safety-copy step has not been changed'
        # SWAP-REFUSED-AFTER-STOP-1: and not while a refused swap waits for its finish.
        $dashboard | Should -Match 'restore: !busy && !finish && restoreOffered\(doc, operate\)'
        # PREP-ROLLBACK-1: also from the first copy alone, when the last stop left
        # the machine changed (tests/js/discard-engine.test.js runs the rule).
        $dashboard | Should -Match 'if \(!operator \|\| doc\?\.retention\?\.deletedUtc\) \{ return false; \}'
        $dashboard | Should -Match 'if \(doc\?\.safety\?\.snapshotId\) \{ return true; \}'
        $dashboard | Should -Match 'engine/restore' -Because 'restore runs on the engine, not in an HTTP call that would time out'
    }

    It 'the destructive option is no softer in the UI than on the command line' {
        $askR = [regex]::Match($dashboard, '(?s)function askRestore\(.*?
\}').Value
        $askR | Should -Match "value: 'new'"
        $askR | Should -Match "value: 'preserve'"
        $askR | Should -Match 'acceptPreserveRisk' -Because 'the engine demands an explicit acknowledgement; so must the page'
        $askR | Should -Match 'restoreRiskMissing'
        $askR | Should -Match 'noteField\(\)' -Because 'a restore changes something, so it needs a recorded reason'
    }

    It 'a machine that was put back says so - the wave row alone would still read Migrated' {
        $dashboard | Should -Match 'wasRestored' -Because 'the wave row carries a marker'
        $dashboard | Should -Match 'restoredFrom' -Because 'the machine panel explains it'
        $dashboard | Should -Match 'restoredIdChanged'
        $dashboard | Should -Match 'restoredIdSame'
    }

    It 'the engine and facade accept the restore operation' {
        $entry = Get-Content (Join-Path $repoRoot 'docker' 'entrypoint.ps1') -Raw
        $entry | Should -Match "'restore'"
        $entry | Should -Match 'VMF_VM_ID'
        $entry | Should -Match 'VMF_ACCEPT_PRESERVE_RISK'
        $facade = Get-Content (Join-Path $repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $facade | Should -Match "'assess', 'plan', 'wave', 'restore'"
        $facade | Should -Match 'restoring a machine requires a note'
        $facade | Should -Match 'must accept that explicitly'
    }
}

Describe 'Setup wizard (WIZARD-1)' {
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html')) }

    It 'walks TWO journeys, and assessing never ends at running' {
        # Since 2026-08-31, no path from 'assess an estate' ends with
        # 'run it'. It was one flow of five steps, so the
        # button said assess and the last step said run - the same misnaming
        # one level up from the button itself.
        #
        # Assessing an estate and migrating one are two pieces of work.
        # Assessing ends when the assessment has been reviewed; migrating is
        # entered deliberately from an approved assessment.
        # PROJECT-1 put the piece of work first: one front door, and the
        # wizard asks which project rather than three doors skipping it.
        $wiz | Should -Match "stepsAssess: \['Which work', 'Where to look', 'What the scan found', 'Review it'\]"
        # WAVE-FLOW-1: the migrate journey is THREE steps and its labels live
        # in help.js, because the middle step is the editor - a second page
        # that draws the same strip. A journey written down twice is a journey
        # that comes to disagree with itself.
        $help = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw
        # ADVISOR-1: choosing each target comes first. MACHINE-PICK-1: and,
        # before the targets, which machines the migration moves.
        $help | Should -Match "MIGRATE_STEPS = \['Choose the machines', 'Choose each target', 'How to group them', 'Arrange the waves', 'Run it'\]"
        $wiz | Should -Not -Match 'stepsMigrate' -Because 'one list, read by both pages'
        # The assess list must not end at running, whatever it is renamed to.
        $assessSteps = [regex]::Match($wiz, "stepsAssess: \[([^\]]*)\]").Groups[1].Value
        $assessSteps | Should -Not -Match '(?i)run'
    }

    It 'and the journey is DERIVED, like the step' {
        # A remembered journey is one that can be wrong after a reload, which
        # is exactly the bug the step derivation exists to avoid.
        $wiz | Should -Match 'function deriveJourney'
        $wiz | Should -Match "journey = deriveJourney\(\)"
    }

    It 'derives the step from the RUN, so leaving and returning resumes correctly' {
        $wiz | Should -Match 'function deriveStep'
        $deriv = [regex]::Match($wiz, '(?s)function deriveStep\(\).*?
\}').Value
        $deriv | Should -Match 'assessment'
        $deriv | Should -Match 'plan'
        $deriv | Should -Match 'VmfHelp\.machineStarted\(' -Because 'once a wave has started, setup is over for that run'
    }

    It 'only the last step changes anything - looking and planning are reads' {
        # assess and plan are posted without a note; the wave start demands one
        $wiz | Should -Match "engine/assess"
        $wiz | Should -Match "engine/plan"
        $start = [regex]::Match($wiz, "(?s)engine/wave.*?\}\)").Value
        $start | Should -Match 'note'
        $wiz | Should -Match 'noteMissing'
    }

    It 'carries the scope pickers, grouping choices and the wave preview' {
        foreach ($s in 'scopeRgOpt', 'scopeSubsOpt', 'scopeMgOpt', 'gTags', 'gRg', 'gSingle', 'gNone', 'appTag') {
            $wiz | Should -Match $s
        }
        $wiz | Should -Match 'planWaves' -Because 'step 4 previews the waves before anything runs'
        $wiz | Should -Match "runHref\('waves\.html'\)|VmfRun\.link\('waves\.html'" -Because 'rearranging reuses the wave editor rather than duplicating it'
    }

    It 'is operator-gated and speaks plain language' {
        $wiz | Should -Match 'canOperate'
        $wiz | Should -Match 'needOperator'
        $m = [regex]::Match($wiz, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END')
        $m.Success | Should -BeTrue
        # ONE vocabulary, in tools/Test-SimplifiedEnglish.ps1. This assertion
        # used to carry its own copy of the banned list; there were six copies
        # in this file alone and they had already drifted apart - and the copy
        # that banned 'NVMe' is what forced the reason wording to say "the new
        # disk type", which names nothing. STE-1.
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'wizard' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'replaces the engine-named buttons in the run view' {
        $dashboard | Should -Match "wizard\.html"
        # PROJECT-1: the button said "New migration" and started an
        # ASSESSMENT. It named the end state rather than the thing it makes,
        # which was only ever accurate while the two were one object.
        $dashboard | Should -Match "menuBtn:\s*'Assess an estate'"
        # the old menu of engine operations is gone
        $dashboard | Should -Not -Match "id=`"act-newrun`""
        $dashboard | Should -Not -Match "id=`"act-plan`""
    }
}

Describe 'Top navigation consistency' {
    It 'every page carries the brand link, and the SAME nav from one source' {
        # This used to assert the nav markup in each page, which is exactly the
        # duplication that let it drift: six copies of the labels, and two had
        # already disagreed (Runs vs Migrations, Admin vs Manage access).
        # The bar is rendered from help.js now, so the page's job is only to
        # provide the container and load the file.
        foreach ($page in Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter *.html) {
            $html = (Get-VmfPageSource -Path $page.FullName)
            $html | Should -Match '<span class="brand">' -Because "$($page.Name) shows the product name, and it is not a link"
            $html | Should -Match '<nav class="topnav"></nav>' -Because "$($page.Name) provides the container"
        }
        # And the tabs themselves exist exactly once, where they are defined.
        $help = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'help.js') -Raw
        foreach ($tab in 'assessments\.html', 'index\.html', 'reports\.html', 'access\.html') {
            $help | Should -Match "href: '$tab'"
        }
    }
}

Describe 'Deploy-VmfDashboard.ps1 (COCK-2, rehosted by HOST-1)' {
    It 'parses cleanly and never writes to the run store' {
        # The invariant is unchanged and still matters - publishing the page
        # must never touch migration data. Only the mechanism moved: the
        # content goes to App Service now, so there is no blob write at all
        # rather than a blob write aimed at the right container.
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1'), [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
        $text = Get-Content (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $text | Should -Not -Match 'az storage blob'
        $text | Should -Match 'az webapp deploy'
    }

    It 'still wires the facade into the page config (S3-5 actions)' {
        $text = Get-Content (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $text | Should -Match 'access\.html'
        $text | Should -Match 'apiUrl'
    }

    It 'the access console permissions moved to the template that owns them' {
        # PKG-1 gave identity.bicep the registration; the deploy script used
        # to set these too and would have fought it. Same permissions, one
        # owner - assert them where they now live.
        $identity = Get-Content (Join-Path $repoRoot 'infra' 'identity.bicep') -Raw
        $identity | Should -Match '84bccea3-f856-4a8a-967b-dbe0a3d53a64'   # AppRoleAssignment.ReadWrite.All
        $identity | Should -Match 'c79f8feb-a9db-4090-85f9-90d820caa0eb'   # Application.Read.All
        $script = Get-Content (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $script | Should -Not -Match '84bccea3-f856-4a8a-967b-dbe0a3d53a64' -Because 'one owner, not two'
    }
}

Describe 'Run picker does not scroll forever' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:idx = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'defaults to a time window rather than every run ever' {
        $script:idx | Should -Match 'RUN_WINDOW_DAYS\s*=\s*\d+'
        $script:idx | Should -Match 'Show \$\{hidden\} older run'
    }

    It 'NEVER hides a run that is live or needs attention, however old' {
        # Hiding a stuck machine because it is from last month would be the
        # worst possible reading of "keep the list short".
        $script:idx | Should -Match "runIsRecent"
        # APPROVE-GROUP-1 added the third group a person is needed for; the
        # rule is run against the page in tests/js/run-picker.test.js.
        $script:idx | Should -Match "if \(x\.group === 'In progress' \|\| x\.group === 'Needs attention' \|\| x\.group === 'Waiting for approval'\) return true"
    }

    It 'never hides the run you are currently looking at' {
        $script:idx | Should -Match "if \(x\.r === currentRun\) return true"
    }

    It 'the older view can be collapsed again' {
        $script:idx | Should -Match 'Show only the last'
    }
}

Describe 'Wizard: a scan that finds nothing stops and says so' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:wiz = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'wizard.html'))
    }

    It 'does not walk past the findings step when nothing was found' {
        # The bug: zero machines means no plan either, so deriveStep fell
        # through to "how to group them" - past the findings, with nothing to
        # group and no way forward.
        # Step 3 since PROJECT-1 added the piece-of-work question at the front.
        # Derived rather than restated: whatever the findings step is numbered,
        # an empty scan must stop THERE.
        # Both now name the step rather than numbering it, so this asserts they
        # name the SAME one - which is the thing that actually matters.
        $script:wiz | Should -Match 'if \(!assessment\) return STEP\.assess\.findings;'
        $script:wiz | Should -Match 'if \(!\(assessment\.vms \?\? \[\]\)\.length\) return STEP\.assess\.findings;'
    }

    It 'the empty result says WHERE it looked' {
        # Otherwise the person cannot tell whether the scope was the mistake.
        $script:wiz | Should -Match 'function scopeSummary'
        $script:wiz | Should -Match 's2NoneWhere'
    }

    It 'and offers the access explanation, since that is the other cause' {
        $script:wiz | Should -Match 's2NoneWhy'
        $script:wiz | Should -Match '(?i)cannot see them yet'
    }

    It 'the subscription picker looks like the other two pickers' {
        # It was bare checkboxes with the id welded to the name.
        # DARK-1: the CSS moved into src/dashboard/app.css. Same rule, one home.
        $appCss = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'app.css') -Raw
        $appCss | Should -Match '\.checks \{ border:1px solid var\(--line\)'
        $appCss | Should -Match '\.checks \.sub \{ display:block'
    }
}

Describe 'The page really does refresh itself' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ix = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'the countdown does not depend on a run having loaded' {
        # The bug: the loop returned early until lastUpdated was set, and
        # lastUpdated is only set after a run's data loads - while refresh()
        # bails when no run is selected. With nothing selected the loop was
        # dead and new runs never appeared without a page reload.
        $script:ix | Should -Not -Match 'if \(!lastUpdated\) return;'
        $script:ix | Should -Match 'Looking for migrations'
    }

    It 'never reads the run list from the browser cache' {
        # The poll hits the SAME url every time; a cached answer freezes the
        # list on whatever it first saw, which a hard reload then bypasses.
        #
        # STORE-READ-1: the two fetches moved out of this page into the shared
        # store client, so the count here dropped to zero and the rule had to
        # follow them. It is the same rule, and it is now stronger: it holds
        # for all seven pages rather than this one.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        foreach ($name in 'storeList', 'storeBlob') {
            $fn = [regex]::Match($help, "(?s)async function $name\(.*?
  \}").Value
            $fn | Should -Not -BeNullOrEmpty -Because "$name is where the read is now"
            # The OPTIONS object, not the string anywhere in the function -
            # the comment above the fetch quotes it too, and matching that
            # would let the real setting be deleted with the test still green.
            $fn | Should -Match "\{ cache: 'no-store', headers:" -Because "$name polls one url and must not be cached"
        }
        # and this page reads through them, so it gets that guarantee.
        $script:ix | Should -Match 'VmfHelp\.storeList\('
        $script:ix | Should -Match 'VmfHelp\.storeBlob\('
    }
}

Describe 'The 14-day window must not hide a run you just made' {
    It 'shows runs it cannot date, rather than hiding them' {
        # Regression from the window added the same day: a run has no
        # timestamp until run-status.json exists, so a run created seconds ago
        # looked exactly like one abandoned last year - and was hidden. The
        # window may only hide what it can positively date as old.
        $ix = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
        $ix | Should -Match 'if \(!x\.t\) return true;'
        $ix | Should -Not -Match 'if \(!x\.t\) return false;'
    }
}

Describe 'A machine that needs a person offers a way in' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:ixa = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'the row says what to do, instead of only a chevron' {
        # The decision and restore controls were only in the detail panel, and
        # nothing said so - the row announced a problem and offered no way to
        # act on it.
        $script:ixa | Should -Match 'rowDecide'
        $script:ixa | Should -Match 'const goCell = needsPerson\s+\? `<span class="rowact">'
    }

    It 'and only on rows where something is actually waiting' {
        # A call to action on a healthy row is noise. FINISH-COUNT-1: "waiting"
        # is the page's one rule (waitsOnPerson), which also sees a machine a
        # restore left stopped; tests/js/finish-count.test.js runs the rule.
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:ixa
        $code | Should -Match 'const needsPerson = rank\(v\) === 0;'
        # STATUS-WORDS-1: the rank reads the one status of the row; its
        # waiting group holds the swap left, and a rolled-back machine still
        # offers its choices. tests/js/machine-status.test.js runs the groups.
        $code | Should -Match "const rank = \(v\) => \(WAITING_STATUS\.includes\(v\.st\.key\) \|\| v\.st\.key === 'rolledBack'\) \? 0"
        # RUN-SUMMARY-SWAP-1: the rule is help.js's outcomeWaitsOnPerson, the
        # twin of the engine's count; tests/js/run-summary-swap.test.js runs it.
        $code | Should -Match "function waitsOnPerson\(doc\) \{\s*return VmfHelp\.outcomeWaitsOnPerson\(VmfHelp\.machineOutcome\(doc\)\);"
        $script:ixa | Should -Match "'<span aria-hidden=\`"true\`">&rsaquo;</span>'"
    }
}

Describe 'SAFETY-2 shows up correctly in the UI' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:root2 = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:ixs = (Get-VmfPageSource -Path (Join-Path $script:root2 'src' 'dashboard' 'migrations.html'))
    }

    It 'the new state has a plain-language label, not its internal name' {
        # The raw SAFETY_PRISTINE was showing through on the wave row.
        $script:ixs | Should -Match "SAFETY_PRISTINE:\s+\['Backing up'"
    }

    It 'the progress order matches what the engine actually does now' {
        # The meter reads percentages straight off this list. Leaving the old
        # order would have every machine at the wrong percentage.
        $script:ixs | Should -Match "'PRECHECK','SAFETY_PRISTINE','GUEST_PREP','STOPPED','SAFETY_COPY','CONVERTING'"
    }

    It 'a machine mid-safety-copy counts as STARTED on every page' {
        # Otherwise the wave editor would let someone move a machine that is
        # already being snapshotted into a different wave.
        # WAVES-BUTTON-RUNNING-1: one list, in help.js, which every page asks.
        $helpJs = Get-Content (Join-Path $script:root2 'src' 'dashboard' 'help.js') -Raw
        $helpJs | Should -Match "function machineStarted\(state\) \{\s*return \['PRECHECK', 'SAFETY_PRISTINE'"
        foreach ($page in 'waves.html', 'wizard.html', 'migrations.html') {
            $t = (Get-VmfPageSource -Path (Join-Path $script:root2 'src' 'dashboard' $page))
            $t | Should -Match 'VmfHelp\.machineStarted\(' -Because "$page must treat it as under way"
        }
    }
}

Describe 'The activity feed names the safety copy' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ixf = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'matches the snapshot event whatever its capitalisation' {
        # The event is named pristineSnapshot; the pattern was case-sensitive
        # and lowercase, so it never matched. The feed then showed a shutdown
        # followed by a start with nothing between them - which reads as the
        # copy being taken AFTER the restart. The order was fine; the feed lied.
        $script:ixf | Should -Match '\[/snapshot/i'
        $script:ixf | Should -Match '\[/pristineSnapshot/i'
    }

    It 'distinguishes the two copies, since they mean different things' {
        $script:ixf | Should -Match 'snapshotPristine:'
        $script:ixf | Should -Match '(?i)exactly as it is now'
        $script:ixf | Should -Match '(?i)now the machine is stopped'
    }
}

Describe 'The size column reports the machine, not the plan' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ixz = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'a machine that was put back shows the size it is on NOW' {
        # It showed source -> target regardless, so after a put-back the column
        # claimed the machine was still heading to the new size when it had
        # been returned to the old one.
        $script:ixz | Should -Match 'doc\?\.restore\?\.sizeAfter'
        $script:ixz | Should -Match 'const liveSize'
    }

    It 'a machine that arrived shows one size, with no arrow' {
        # An arrow says "still moving". A migrated machine is not still moving.
        $script:ixz | Should -Match "const arrived = \['MIGRATED', 'VALIDATING', 'STARTING'\]"
    }

    It 'and the restore records the size it ended on, or the UI could not know' {
        $rs = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw
        $rs | Should -Match 'sizeAfter\s+='
    }
}

Describe 'The capacity panel does not overstate what it knows' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ixc = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'quota headroom says WHEN it was read, because it is never refreshed' {
        # used/limit is taken once, at plan time. It looked live and sat
        # unchanged while a wave consumed cores.
        $script:ixc | Should -Match 'quota\?\.checkedUtc'
        $script:ixc | Should -Match 'quotaWhen:'
    }

    It 'and the forecast records that timestamp, or the page cannot show it' {
        # Was a grep of one cmdlet's source, which broke the moment the claim
        # moved into a function of its own. This file reads no module by
        # design, so assert the CONTRACT the page depends on; the emitted
        # document is checked in CapacityContract.Tests.ps1.
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.quota.properties.PSObject.Properties.Name |
            Should -Contain 'checkedUtc' -Because 'the page renders it, so it must be part of the claim'
    }

    It 'reserved-but-unused is NOT green' {
        # "Reserved 1" in green beside "In use 0" reads as all-good when it
        # means capacity is being paid for and nothing is consuming it.
        # RES-LIST-1: the count is the row's Details (reservationFact), the colour the pill's.
        $script:ixc | Should -Match 'const idle = \(c\.reservation\?\.consumedInstances \?\? 0\) === 0'
        $script:ixc | Should -Match "pill \`$\{idle \? 'warn' : 'good'\}"
    }

    It 'and says plainly that idle reserved capacity costs money' {
        $script:ixc | Should -Match '(?i)bills whether or not a machine is using it'
        $script:ixc | Should -Match '\{idle\} idle'
        $script:ixc | Should -Match '(?i)release it'
    }
}

Describe 'COCK-4 follow-up: what happened to THIS machine capacity' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ixp = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
    }

    It 'answers it per machine, from the claim that actually names it' {
        # The capacity table keeps the aggregate maths per wave x size, which is
        # where it belongs. What was missing was the per-machine answer, and the
        # claims already recorded it in associatedVmIds.
        $script:ixp | Should -Match 'associatedVmIds \?\? \[\]\)\.includes\(vmId\)'
        $script:ixp | Should -Match 'placementLine'
        # CAPACITY-WORDS-1: the panel draws the one rule, with the run's claims.
        $script:ixp | Should -Match 'const placement = capacityLine\(doc, entry, vmId, latestClaims\)'
    }

    It 'has the four approved cases, and the fact for a Reserved wave with no slot (CAPACITY-WORDS-1)' {
        # tests/js/capacity-words.test.js runs capacityLine on each case and
        # holds the words exactly.
        foreach ($k in 'capOdcrUsed', 'capNoneWave', 'capOwnGroup', 'capAvset', 'capNoneSlot') {
            $script:ixp | Should -Match "$k\s*:"
        }
    }

    It 'says WHY an availability-set machine cannot have reserved capacity' {
        # "not reservable" on its own reads like a fault. It is an Azure rule.
        $script:ixp | Should -Match 'Azure does not allow one for a machine in an availability set\.'
    }
}

Describe 'RUN-LIFECYCLE-1 and UX-WAVE-3 on the surfaces' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:idx = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'migrations.html'))
        $script:wav = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $script:rep = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'reports.html'))
        $script:wiz = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
    }

    It 'a run that was only scanned is not counted as a migration that happened' {
        $script:rep | Should -Match 'setupOnly'
        # PAGE-SCALE-REPORTS-1: the counted tiles take the real runs only, and
        # a run that was only scanned has a tile of its own that says why.
        $script:rep | Should -Match 'const real = list\.filter\(x => !x\.setupOnly\)'
        $script:rep | Should -Match 'hint: UX\.tSetupHint'
    }

    It 'the run picker groups setup-stage runs and offers the way back in' {
        $script:idx | Should -Match 'Still being prepared'
        $script:idx | Should -Match 'continueSetup'
        $script:idx | Should -Match "VmfRun\.link\('wizard\.html'|runHref\('wizard\.html'"
    }

    It 'saving the plan leads onward with a real button, not a text afterthought' {
        # After a save, the way onward was only text; it is now a primary
        # button, and it goes to the NEXT STEP (accepting how the wave runs),
        # not the run page. It sits with the other buttons, not in an area of
        # its own - and the run page is not the next step, so it is not offered.
        $script:wav | Should -Match 'continueSetup'
        $script:wav | Should -Match 'id="continue"'
        $script:wav | Should -Not -Match 'backToRun'
    }

    It 'the wave editor never offers a capacity choice that says nothing' {
        # "Leave as planned" meant nothing to somebody setting the plan for the
        # first time. Every option is now a real setting.
        $script:wav | Should -Not -Match 'capDefault'
        $script:wav | Should -Match "capNow = w\.capacityGate \|\| 'BestEffort'"
    }

    It 'the wizard carries the accept gate and the scheduler, instead of walking past them' {
        # The wizard walked past the accept gate, and the scheduler never
        # showed in it. The engine refuses an unaccepted wave, so a wizard
        # that skipped the gate could only ever fail at the last step.
        $script:wiz | Should -Match 'accept-options'
        $script:wiz | Should -Match 'acceptBtn'
        # PLANRUN-1: the scheduler is the start-time list of "Give some waves a
        # start time" - one time per wave - not one wave's now-or-later choice.
        $script:wiz | Should -Match 'howTimes'
        $script:wiz | Should -Match 'data-time='
        $script:wiz | Should -Match '/schedule'
    }

    It 'accepting settings does not interrogate the person' {
        # The choice is accept or edit, with no "why?" question. Accepting
        # is agreement, not justification - who and
        # when are recorded already.
        $askAccept = [regex]::Match($script:idx, '(?s)function askAcceptOptions\(wave\).*?
\}').Value
        $askAccept | Should -Not -Match 'noteField'
        $askAccept | Should -Match 'acceptOptionsEdit'
    }

    It 'the levers have their own layout, not the header row (UX-WAVE-3b)' {
        # Verified in a browser as well: five cells, no overlapping boxes at
        # desktop OR tablet width, and the header carries no controls.
        # DARK-1: the CSS moved into src/dashboard/app.css. Same rule, one home.
        $appCssW = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'app.css') -Raw
        $appCssW | Should -Match '\.wave \.levers \{ display:grid'
        $wh = [regex]::Match($script:wav, '(?s)<div class="wh">.*?</div>').Value
        $wh | Should -Not -Match 'data-cap|data-keep|data-driver'
    }

    It 'the wizard has no column that nothing feeds (UX-WAVE-3c)' {
        $script:wiz | Should -Not -Match 'colRing'
        $script:wiz | Should -Not -Match 'info\.ring'
    }
}

Describe 'The Run it step does not throw away what you entered' {
    # The first click to begin the wave reset the accept options (the IaC
    # checkbox) completely, so it took two clicks.
    #
    # Accepting the settings and approving the wave both call render(), which
    # rebuilds the step - discarding the ticked acknowledgement, the note and
    # the throttle. Clicking Start then failed the acknowledgement check and
    # redrew that section, so only the SECOND attempt worked. From the outside
    # that is a button that does not work.
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wizard = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html')) }

    It 'keeps what was entered outside the DOM, so a redraw cannot lose it' {
        $script:wizard | Should -Match 'const runForm ='
        # PLANRUN-1: 'how' and 'times' replaced one wave's 'when'.
        # MACHINES-AT-ONCE-RANGE-1: no number of machines at once is entered here any more.
        foreach ($field in 'note', 'ack', 'how', 'times') {
            $script:wizard | Should -Match "runForm\.$field"
        }
    }

    It 'seeds every field from what was entered before' {
        # verified in a browser too: tick, type, re-render, and all three survive
        # WIZARD-START-ERROR-OUT-OF-VIEW-1: each field also names its error box.
        $script:wizard | Should -Match 'id="f-ack"[^>$]*\$\{runForm\.ack \? '' checked'' : ''''\}'
        $script:wizard | Should -Match 'id="f-note" rows="2"[^>]*>\$\{esc\(runForm\.note\)\}'
    }

    It 'records each change as it happens' {
        foreach ($id in 'f-note', 'f-ack') {
            $script:wizard | Should -Match "\`$\('#$id'\)\?\.addEventListener"
        }
        # PLANRUN-1: each wave's start time, and the run-it-how choice.
        $script:wizard | Should -Match "querySelectorAll\('\[data-time\]'\)\.forEach\(inp => inp\.addEventListener\('input'"
        $script:wizard | Should -Match "querySelectorAll\('input\[name=how\]'\)\.forEach"
    }
}

Describe 'WIZARD-STEPS-1: step numbers are NAMED, not scattered' {
    # Seen on the first real run: the "where to look" step hung for almost a
    # minute and never loaded, a regression that blocked the wizard. Every
    # step and stage was then checked for the same regression.
    #
    # The scope loader re-rendered only `if (step === 1)` - true when the scope
    # question WAS step one, and false the moment the project question was
    # inserted in front of it. The data arrived and nothing redrew.
    #
    # Sweeping for the same shape found SIX more, all from the two-journey split
    # and the insert, and none caught by any test because every one of them is a
    # number that is still a valid number:
    #
    #   deriveStep returned 9 for "already running", render asked for 6
    #   "arrange the waves" Back went FORWARD to capacity
    #   "arrange the waves" Next went to a step that does not exist, so it fell
    #       through to "Run it" and SKIPPED THE CAPACITY STEP ENTIRELY
    #   "Run it" Back went to itself
    #   "how to group" Back went FORWARD to the waves
    #   polling waited on the wrong step for both the scan and the plan
    #
    # A number is not a name. The fix is the STEP table, and this keeps it.
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) }

    It 'declares both journeys in one table' {
        $script:wiz | Should -Match 'const STEP = \{'
        foreach ($n in 'project', 'scope', 'findings', 'review') {
            $script:wiz | Should -Match "$n\s*:" -Because "the assess journey needs a named '$n' step"
        }
        foreach ($n in 'group', 'waves', 'capacity', 'run') {
            $script:wiz | Should -Match "$n\s*:" -Because "the migrate journey needs a named '$n' step"
        }
    }

    It 'and NOTHING outside it compares or assigns a bare step number' {
        # The whole class of bug in one assertion. `step = 1` at declaration is
        # the only literal allowed.
        $lines = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) -split "`n"
        $inTable = $false
        $offenders = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l -match '^const STEP = \{') { $inTable = $true }
            if ($inTable) { if ($l -match '^\};') { $inTable = $false }; continue }
            if ($l -match '^let step = 1,') { continue }
            if ($l -match 'step\s*(===|>=|<=|>|<|=)\s*\d') {
                $offenders += "$($i + 1): $($l.Trim())"
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because 'a bare step number is still a valid number when the steps move, which is why none of these failed'
    }

    It 'the running card and deriveStep agree on which step that is' {
        # They disagreed - 9 versus 6 - so a wizard opened on a run already under
        # way showed "Run it" instead of sending you to watch it.
        $script:wiz | Should -Match 'if \(step === STEP\.running\)'
        $script:wiz | Should -Match 'return STEP\.running;'
    }

    It 'WAVE-FLOW-1: the waves step IS the editor, so it hands over to it' {
        # There is no capacity step to lead to any more. Two of the four steps
        # did nothing - a read-only summary with a yes button, and a capacity
        # step that usually said there was nothing to check - while the screen
        # where the work happens sat behind a link called "Rearrange these
        # waves". The editor is the step now, and it is another page.
        $script:wiz | Should -Not -Match 'STEP\.migrate\.capacity' -Because 'the capacity step is gone'
        # ADVISOR-1 put choosing each target in front, so everything moved on one.
        # MACHINE-PICK-1 put choosing the machines in front of that, so again.
        $script:wiz | Should -Match "migrate: \{ choose: 1, targets: 2, group: 3, waves: 4, run: 5 \}"
        $script:wiz | Should -Match "runHref\('waves\.html', \{ flow: 1 \}\)" -Because 'the step hands over to the editor'
    }

    It 'WAVE-FLOW-1: and the quota request went with the step that was removed' {
        # That step was the ONLY place a person could ask Azure to raise a
        # quota. Deleting it without moving this would take the action away.
        $waves = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Match "runs/\`${runSeg\(\)}/engine/quota" -Because 'the editor asks for the increase now'
        $script:wiz | Should -Not -Match 'engine/quota' -Because 'and the wizard no longer does'
    }

    It 'and the scope loader redraws on DATA arriving, not on a step number' {
        $script:wiz | Should -Match 'awaitingScopes'
        $script:wiz | Should -Match 'if \(awaitingScopes\) render\(\)'
    }
}

Describe 'SCOPE-NAME-1: the Assessments page names the subscription, as the wizard does' {
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:assessPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'assessments.html')) }

    It 'resolves subscription and management-group names from /scopes, id as the fallback' {
        # Seen on screen: the wizard said "inside subscription
        # Contoso-Prod"; this page said "in subscription aaaa0a0a-bb1b-...". Same
        # scan. The assessment holds the id; the wizard looks the name up; this
        # page never asked.
        $assessPage | Should -Match "api\('GET', 'scopes'\)"
        $assessPage | Should -Match "const subName = \(id\) =>.*\?\.name \|\| id"
        $assessPage | Should -Match "const mgName = \(id\) =>.*\?\.name \|\| id"
        $assessPage | Should -Match 'UX\.inSubscription \+ subName\('
        $assessPage | Should -Match 'UX\.inGroup \+ mgName\('
    }

    It 'and does not hold the page up waiting for them' {
        # COLD-1: the facade can take 20-40 s to wake. The list must draw with
        # ids and be REDRAWN with names, never wait. So the call is not awaited
        # and its then() redraws.
        $fn = [regex]::Match($assessPage, '(?s)async function start\(\) \{.*?\n\}').Value
        # PAGE-SCALE-ASSESSMENTS-1: the list has no scope column; the report
        # beside it says where the scan looked, and its line is drawn again.
        $fn | Should -Match "(?s)api\('GET', 'scopes'\)\s*\.then\(d => \{ scopes = d; refreshScopeLine\(\); \}\)"
        $fn | Should -Not -Match "await api\('GET', 'scopes'\)"
    }

    It 'so the scope text is made when the row is DRAWN, not when it is loaded' {
        # A name that arrives after load must still reach the screen. Rows
        # keep the raw scope and scopeText() runs at render time.
        $assessPage | Should -Match 'const sc = scopeText\(row\.scope\);' -Because 'the report must resolve names at draw time'
        $assessPage | Should -Match 'if \(line && row\) \{ line\.innerHTML = scopeLineHtml\(row\); \}' -Because 'and draw its line again when they arrive'
        $assessPage | Should -Not -Match 'scope: scopeText\(' -Because 'pre-rendering at load time would freeze the ids in'
    }
}

Describe 'LOG-1: the activity feed can show the whole log, not only the newest 30' {
    # Found 2026-09-04: as the activity list grew it dropped old messages,
    # and there was no way to scroll back past the last minute or two.
    It 'one button with two states (rule 11): the whole log, or the latest 30 again' {
        $script:dashboard | Should -Match 'const FEED_RECENT = 30;'
        $script:dashboard | Should -Match 'function toggleWholeLog\(\) \{\s*showWholeLog = !showWholeLog;'
        $script:dashboard | Should -Match "tog\.textContent = showWholeLog \? UX_MISC\.logShowRecent\.replace\('\{n\}', FEED_RECENT\) : UX_MISC\.logShowAll;"
        $script:dashboard | Should -Match 'const recent = activityLines\(events, showWholeLog, showWholeLog \? Infinity : FEED_RECENT\);'
        $script:dashboard | Should -Match 'if \(recent\.length >= cap\) break;'
    }

    It 'the whole log collapses nothing and scrolls inside its card' {
        $script:dashboard | Should -Match 'if \(!whole && shownAt\.has\(key\)'
        $script:dashboard | Should -Match "classList\.toggle\('all', showWholeLog\)"
        $css = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'app.css') -Raw
        $css | Should -Match '#event-scroll\.all \{ max-height:65vh;overflow:auto; \}'
    }

    It 'and the footer says what is on screen out of how much there is' {
        $script:dashboard | Should -Match "logRecentOf:\s+'The latest \{n\} of \{total\} lines'"
        $script:dashboard | Should -Match "logAllOf:\s+'All \{total\} lines, newest first'"
        $script:dashboard | Should -Match 'tog\.hidden = total <= FEED_RECENT && !showWholeLog;'
    }
}

Describe 'TIMER-WORDS-1: a run-level failure from the timers has words, and its pill does not point at a machine' {
    # Seen 2026-09-05, on screen: two red lines reading "schedule"
    # with "Open the machine for details" - written by the five-minute timer
    # during the environment rebuild, into runs with no schedule at all.
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:runner = Get-Content (Join-Path $repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Raw }

    It 'the timer records a release failure and a resume failure separately, each in its own words' {
        $script:runner | Should -Match "Step 'schedule' -Outcome fail"
        $script:runner | Should -Match "Step 'resume' -Outcome fail"
        $script:runner | Should -Match 'The engine could not be checked for a wave that stopped mid-flight: \$why\.'
        ([regex]::Matches($script:runner, '(?m)^\s+try \{')).Count | Should -BeGreaterOrEqual 3 -Because 'release and resume no longer share one catch'
    }

    It 'the page shows the sentence the timer wrote, and a pill that does not send the reader to a machine' {
        $script:dashboard | Should -Match "if \(\(e\.step === 'schedule' \|\| e\.step === 'resume'\) && e\.outcome === 'fail' && e\.detail\) \{ return e\.detail; \}"
        # LOG-SAYS-WHY-1: THE PROPERTY, NOT THE SENTENCE. This pinned the
        # exact words, so rewording it failed a test about where the pill
        # sends the reader - which is what it is really for. The run-level
        # pill must not point at a machine; the machine one must.
        $runPill = [regex]::Match($script:dashboard, "failedNoteRun:\s*'([^']*)'").Groups[1].Value
        $runPill | Should -Not -BeNullOrEmpty
        $runPill | Should -Not -Match '(?i)machine' -Because 'a run-level failure has no machine to open'
        $machinePill = [regex]::Match($script:dashboard, "failedNote:\s*'([^']*)'").Groups[1].Value
        $machinePill | Should -Match '(?i)machine' -Because 'the machine one does point at one'
        # RESTORE-END-LOST-1: the choice moved into feedFailNote, which also keeps
        # an engine line on the run pill (tests/js/putback-gone.test.js runs it).
        $script:dashboard | Should -Match "esc\(feedFailNote\(e\)\)"
        $script:dashboard | Should -Match "\(e\.vmId && !/\^engine:/\.test\(String\(e\.step \?\? ''\)\)\) \? UX_STEP\.failedNote : UX_STEP\.failedNoteRun"
    }
}

Describe 'IDENTITY-UX-1: a rebuilt machine gets a new system-assigned identity, and every screen says so' {
    # Since 2026-09-05, the demo pages show a VM that will be rebuilt (not
    # just resized), and state that its system-assigned managed identity
    # will be recreated - in the assessment details, the acceptance and the
    # other screens. The point had to be stated clearly on every one.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:wavesPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        $script:wizardPage = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        $script:assessPage2 = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'assessments.html'))
        $script:reasons = Get-Content (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $script:planWriter = Get-Content (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1') -Raw
    }

    It 'the assessment explains it as a warning, in Azure words, with what to do' {
        # IDENTITY-LOSS-1: it was a prep item, under "handled for you; nothing
        # here needs doing first" - false for a finding a person decides on.
        $script:reasons.prep.PSObject.Properties['system-identity-recreated'] | Should -BeNullOrEmpty
        # REBUILD-REMOVE-PLAN-1: no move deletes the identity now, so the scan gives
        # no such finding and the reason is gone with it.
        $script:reasons.warnings.PSObject.Properties['system-identity-recreated'] | Should -BeNullOrEmpty
        $script:assessPage2 | Should -Not -Match "warnings: \['system-identity-recreated'\]" -Because 'the sample shows what the scan gives now'
    }

    # REBUILD-REMOVE-ACCEPT-1: no move rebuilds a machine, so no machine gets a
    # new identity. The setting, the pill and the rows are gone from every
    # screen; tests/js/rebuild-remove-accept.test.js runs the dialogs.
    It 'the wave editor has no identity setting and marks no machine' {
        $script:wavesPage | Should -Not -Match "identityLabel:|data-identity=|identityTag:|onSystemAssignedIdentity"
        $script:wavesPage | Should -Not -Match ([regex]::Escape('VmfHelp.getsNewIdentity('))
        # WAVE-LEVER-OVERRIDE-1: the page still reads every setting through one
        # table of defaults. ACCEPT-FIRST-MACHINE-1: the table and leverValue
        # are in help.js, which the acceptance asks too.
        $script:wavesPage | Should -Match ([regex]::Escape('const WAVE_DEFAULTS = VmfHelp.waveSettingDefaults();'))
        Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw |
            Should -Match ([regex]::Escape('e?.policy?.[field] ?? waveSettingDefaults()[field]'))
        $script:planWriter | Should -Match 'ConvertTo-VmfWaveLayout -Layout \$Layout'
        Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'WaveSettings.ps1') -Raw |
            Should -Match "'onDDataFound', 'keepSnapshotDays'" -Because 'WAVE-KERNEL-LINE-1: no identity setting, and no kernel setting, between them'
    }

    It 'the acceptance and Run it show no identity row, so nothing asks a person to accept a loss' {
        $script:dashboard | Should -Not -Match "UX_LEVER\.onSystemAssignedIdentity|UX_LEVER\.identityMachines|newIdentityNames\("
        $script:wizardPage | Should -Not -Match "UX\.lvIdentity|lever\.onSystemAssignedIdentity"
    }
    It 'and the run page shows the sentence PRECHECK writes when the wave proceeds by choice' {
        $script:dashboard | Should -Match "if \(e\.step === 'precheck' && e\.outcome === 'warn' && e\.detail\) \{ return e\.detail; \}"
        # REBUILD-REMOVE-DOCS-1: the sample machine with a system-assigned
        # identity is planned in place now (path A, the in-place upgrade
        # (Preview)), as every machine is; it keeps its identity.
        # WAVE-SAMPLE-RUN-1: the sample plan is written once, in help.js
        # (VmfHelp.sampleRun), and the run page reads it. at() plans path A.
        $script:dashboard | Should -Match "'plan\.json': VmfHelp\.sampleRun\.plan\(\),"
        $helpJs = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $helpJs | Should -Match "at\('prd-ebs-a', 'billing-apps', \{ identityType: 'SystemAssigned'"
        $helpJs | Should -Match "const at = \(vm, wave, assessment, target, an, pol, more\) => \(\{ vmId: SUB \+ vm, wave, path: 'A',"
    }
}

Describe 'IDENTITY-4: the product no longer researches what an identity reaches' {
    # Since 2026-09-11, the product makes no research or statement about the
    # impact of a rebuilt system-assigned identity. It states the risk and asks
    # the customer to approve it, and only after their own analysis.
    #
    # What stood here tested IDENTITY-3 step 2 - a control that asked five
    # questions with the signed-in person's own tokens. It could not answer its
    # own question and said so, in its own closing sentence: a runbook, a
    # pipeline or a linked service holding the client id was invisible to every
    # check it ran. These tests now hold the ABSENCES, because a removal that
    # nothing guards comes back one convenience at a time.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:report3 = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'assessment-report.js') -Raw
        $script:assess3 = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'assessments.html'))
        $script:wizard3 = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        $script:identityBicep = Get-Content (Join-Path $repoRoot 'infra' 'identity.bicep') -Raw
    }

    It 'the control is gone from the renderer and from both pages' {
        # Every file here carries a COMMENT saying what was removed and why,
        # and that history is worth keeping - so this reads CODE ONLY, or the
        # assertions would match the explanation. COMMENT-TRAP-1 again, on the
        # removal whose own tests keep finding it.
        #
        # IDENTITY-4 could not use the helper here: its CStyle scanner met the
        # regex in this file's own HTML escaper, took the quote inside it as
        # the start of a string, and returned every comment below it intact. So
        # these assertions were written against code FORMS instead - a
        # declaration or a call, which cannot appear in a sentence about them.
        # CODEONLY-2 fixed the helper, and this is the case that exposed it, so
        # it reads through the helper again - and keeps the code forms, which
        # cost nothing and hold if somebody writes the identifier into prose.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $codeOnly = @(
            (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'src' 'dashboard' 'assessment-report.js')),
            (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'src' 'dashboard' 'assessments.html')),
            (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'src' 'dashboard' 'wizard.html'))
        )
        foreach ($text in $codeOnly) {
            $text | Should -Not -Match 'installWhereUsed'
            $text | Should -Not -Match 'whereUsedAnswers'
            $text | Should -Not -Match 'Where is it used'
            $text | Should -Not -Match 'identityGrants'
            $text | Should -Not -Match 'identityNote'
        }
        foreach ($text in $script:report3, $script:assess3, $script:wizard3) {
            $text | Should -Not -Match 'installWhereUsed\('
            $text | Should -Not -Match 'whereUsed:'
            $text | Should -Not -Match 'whereSignIn'
        }
    }

    It 'and the comments that explain the removal SURVIVE, which is the other half' {
        # A removal with no record is how somebody adds it back next quarter
        # believing it was an oversight.
        $script:report3 | Should -Match 'IDENTITY-4'
        $script:report3 | Should -Match 'Where is it used'
    }

    It 'and so is the sign-in read, with the whole opt-in that carried it' {
        # It was an on/off switch reaching from an install question, through a
        # bicep parameter and two deploy scripts, to three states on a page.
        # The permission it asked for was WIDER than its read - every sign-in in
        # the tenant, in a reader's session - and a customer's security team is
        # right to refuse a permission nothing uses.
        # The scope's GUID is the thing that actually grants it, and no comment
        # here spells a GUID.
        $script:identityBicep | Should -Not -Match 'e4c9e354-4dc5-45b8-9e7c-e1393b0b1a20'
        $script:identityBicep | Should -Not -Match 'param signInActivity'
        # PowerShell files go through the real parser, which does not have the
        # CStyle scanner's problem.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'infra' 'identity-deploy.ps1')) |
            Should -Not -Match '\[switch\]\$SignInActivity'
        (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1')) |
            Should -Not -Match '\$signInActivity'
        (Get-VmfCodeOnly -Path (Join-Path $repoRoot 'infra' 'hooks' 'preprovision.ps1')) |
            Should -Not -Match 'VMF_SIGN_IN_ACTIVITY'
        $sample = Get-Content (Join-Path $repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw | ConvertFrom-Json
        $sample.PSObject.Properties['signInActivity'] | Should -BeNullOrEmpty
    }

    It 'the four scopes the ACCESS CONSOLE needs are untouched, because they are not this' {
        # A removal that took these with it would break giving people access -
        # a different feature that happens to read the directory.
        $script:identityBicep | Should -Match "\{ id: '84bccea3-f856-4a8a-967b-dbe0a3d53a64', type: 'Scope' \}\s*// AppRoleAssignment\.ReadWrite\.All"
        $script:identityBicep | Should -Match "\{ id: 'c79f8feb-a9db-4090-85f9-90d820caa0eb', type: 'Scope' \}\s*// Application\.Read\.All"
        $script:identityBicep | Should -Match "\{ id: 'b340eb25-3456-403f-be2f-af7a0d370277', type: 'Scope' \}\s*// User\.ReadBasic\.All"
        $script:identityBicep | Should -Match "\{ id: '5f8c59db-677d-491f-a6b8-5f174b11ec1d', type: 'Scope' \}\s*// Group\.Read\.All"
        $script:identityBicep | Should -Match "var armAppId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'" -Because 'the access console reads Azure as the person too'
    }

    It 'the DETECTION survives, because that is what the risk is built on' {
        # The finding, the wave gate and the PRECHECK record all rest on two
        # fields that come off the VM object and cost nothing. A removal that
        # took these would take the warning with it.
        $script:wizard3 | Should -Match "identityType: 'SystemAssigned'"
        $script:wizard3 | Should -Match "identityPrincipalId: '11111111-2222-3333-4444-555555555555'"
        $script:assess3 | Should -Match "identityType: 'SystemAssigned'"
        # WAVE-SAMPLE-RUN-1: the run page's sample plan is in help.js (VmfHelp.sampleRun).
        Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw | Should -Match "\{ identityType: 'SystemAssigned', os: 'Windows'"
    }

    It 'and the finding still tells the reader what happens' {
        # The reason's own words, from assessment-reasons.json, which is where
        # they always were. Every machine says the same thing now, because the
        # thing that differed per machine was the research.
        $reasons = Get-Content (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        # IDENTITY-LOSS-1: a warning now, not a prep item.
        # REBUILD-REMOVE-PLAN-1: the warning is gone - no move deletes the identity.
        $reasons.warnings.PSObject.Properties['system-identity-recreated'] | Should -BeNullOrEmpty
    }
}
