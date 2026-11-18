#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUNPAGE-1, OSLOGO-1, HELP-2 and ODCR-GAP-1's honest label - the run page at
# fleet size, and help that knows there is more than one kind of help.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dashDir = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:idx = (Get-VmfPageSource -Path (Join-Path $script:dashDir 'migrations.html'))
    $script:help = Get-Content (Join-Path $script:dashDir 'help.js') -Raw
    $script:waves = (Get-VmfPageSource -Path (Join-Path $script:dashDir 'waves.html'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'RUNPAGE-1: a hundred-machine run is not one long list' {
    It 'machines that need a person are ordered first' {
        # "Needs attention" was already a computed fact; it just was not
        # driving the order, so an operator scrolled past ninety settled rows
        # to reach the two that wanted them.
        # FINISH-COUNT-1: by the page's one rule (waitsOnPerson), which also
        # sees a machine a restore left stopped; tests/js/finish-count.test.js
        # runs the rule.
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:idx
        # STATUS-WORDS-1: by the one status of the row; tests/js/machine-status.test.js
        # runs the groups.
        $code | Should -Match "const rank = \(v\) => \(WAITING_STATUS\.includes\(v\.st\.key\) \|\| v\.st\.key === 'rolledBack'\) \? 0"
        $code | Should -Match 'if \(!filtering\) vms = \[\.\.\.vms\]\.sort\(\(a, b\) => rank\(a\) - rank\(b\)'
        # RUN-SUMMARY-SWAP-1: help.js's rule; tests/js/run-summary-swap.test.js runs it.
        $code | Should -Match "function waitsOnPerson\(doc\) \{\s*return VmfHelp\.outcomeWaitsOnPerson\(VmfHelp\.machineOutcome\(doc\)\);"
    }

    # WAVES-OPEN-1, 2026-09-30: the page never hides its main content on
    # its own. RUNPAGE-1 asked for the CONTROLS; the page also closed a finished
    # wave, and the finished rows of a busy one, by itself.
    It 'a wave starts open, and closes only on a click' {
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:idx
        $code | Should -Match 'const collapsed = waveCollapsed\.has\(waveKey\) \? waveCollapsed\.get\(waveKey\) : false;'
        $code | Should -Match 'const current = waveCollapsed\.has\(k\) \? waveCollapsed\.get\(k\) : false;' -Because 'the first click must close an open wave'
        $code | Should -Not -Match 'autoCollapse'
    }

    It 'a hidden wave says nothing needs anyone only when that is true' {
        # Found by the demo check after WAVES-OPEN-1: Hide machines is on every
        # long wave now, and a hidden RUNNING wave said "nothing here needs anyone".
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:idx
        $code | Should -Match 'const quietWave = !filtering && needsSomeone === 0 && inFlight === 0\s+&& !vms\.some\(v => restoreInFlight\(v\.entry\.vmId, v\.doc\)\);'
        $code | Should -Match '\$\{quietWave \? ` &middot; \$\{esc\(UX_MISC\.waveAllSettled\)\}` : '''''
    }

    It 'the settled tail is offered a Hide control when it is long, and hides only on a click' {
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:idx
        $code | Should -Match 'const offerSettledToggle = !filtering && !collapsed && settledCount > 8 && \(needsSomeone \+ inFlight\) > 0'
        $code | Should -Match 'const settledHiddenNow = offerSettledToggle && settledHidden\.has\(waveKey\);'
        $code | Should -Not -Match 'settledShown'
    }

    It 'a search or a filter always wins - it answers the question that was asked' {
        $script:idx | Should -Match "const filtering = Boolean\(searchTerm\) \|\| statusFilter !== 'all'"
    }

    It 'the toggles re-render rather than hiding rows in place' {
        # Hiding in place leaves the counts saying something different from
        # what is on screen.
        $script:idx | Should -Match "data-wavetoggle"
        $script:idx | Should -Match "data-settled"
        $script:idx | Should -Match 'waveCollapsed\.set\(k, !current\);\s*\r?\n\s*renderWaves\(halted\)'
    }

    It 'the collapse choice is per run, so switching runs does not inherit it' {
        $script:idx | Should -Match '\$\{currentRun\}::\$\{wave\}'
    }
}

Describe 'OSLOGO-1: the operating system, in words, never guessed' {
    It 'renders text and never bundles a logo' {
        $script:idx | Should -Match 'function osText\(entry\)'
        $script:idx | Should -Match 'class="osline"'
        # No image assets, no inline distro artwork.
        $script:idx | Should -Not -Match '(?i)<img[^>]*(ubuntu|redhat|red-hat|suse|windows-logo)'
    }

    It 'says so when the image was never reported, rather than showing a bare OS name' {
        $fn = [regex]::Match($script:idx, '(?s)function osText\(entry\) \{.*?\n\}').Value
        $fn | Should -Match 'osUnknownVersion'
        $fn | Should -Match 'osUnknown'
    }

    It 'falls through to the raw sku rather than inventing a name for it' {
        $fn = [regex]::Match($script:idx, '(?s)function osText\(entry\) \{.*?\n\}').Value
        $fn | Should -Match 'esc\(sku\)'
    }

    It 'reads only fields the plan entry already carries - no contract change' {
        $fn = [regex]::Match($script:idx, '(?s)function osText\(entry\) \{.*?\n\}').Value
        $fn | Should -Match 'entry\?\.assessment\?\.os'
        $fn | Should -Match 'entry\?\.assessment\?\.osVersion'
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        $names = $schema.properties.assessment.properties.PSObject.Properties.Name
        $names | Should -Contain 'os'
        $names | Should -Contain 'osVersion'
    }

    It 'the sample data looks like real data, so the page can be judged on it' {
        # A fixture that does not resemble a real run teaches the wrong thing
        # about the page - and is how this project has had three tests certify
        # a defect as the spec.
        # WAVE-SAMPLE-RUN-1: the run page's sample plan is written once in
        # help.js (VmfHelp.sampleRun), which the wave editor shows too.
        $script:idx | Should -Match "'plan\.json': VmfHelp\.sampleRun\.plan\(\),"
        $script:help | Should -Match "osVersion: '22_04-lts-gen2'"
        $script:help | Should -Match "osVersion: '2022-datacenter-g2'"
        $script:help | Should -Match "osVersion: 'rhel-9_4'"
    }
}

Describe 'HELP-2: help is a menu, and the app files nothing' {
    It 'asks what kind of help before doing anything' {
        $script:help | Should -Match 'function menu\(\)'
        $script:help | Should -Match 'function open\(\) \{ return menu\(\); \}'
        # The attribute is templated, so the four kinds are named where they
        # are declared and where they are handled - assert both ends.
        foreach ($k in 'failure', 'bug', 'idea', 'lost') {
            $script:help | Should -Match "item\('$k'" -Because "the menu must offer '$k'"
        }
        $script:help | Should -Match "if \(kind === 'failure'\) \{ bundleDialog\(\); return; \}"
        $script:help | Should -Match "if \(kind === 'lost'\)"
        $script:help | Should -Match "kind === 'bug' \? 'bug_report\.md' : 'feature_request\.md'"
    }

    It 'hands back a pre-filled link and holds no token' {
        # Accepted design: the user opens their own issue. It keeps their name on
        # it, keeps this page free of credentials, and lets them SEE the
        # resource ids before anything is sent.
        $script:help | Should -Match 'function issueUrl\(kind, title, body\)'
        # NO-POPUPS-1: a link the person clicks, in a new tab, built from issueUrl.
        $script:help | Should -Match "return issueUrl\("
        $script:help | Should -Match "isIssueLink\(href\)"
        $script:help | Should -Not -Match '(?i)api\.github\.com'
        # VERSION-1: the file DOES now send a token - the viewer's own, to OUR
        # service, to read its version - and that is the only place one may
        # go. Every Authorization header in the file must be that one call,
        # on the facade base URL the page configured.
        # STORE-READ-1: this counted the headers, because there was one call.
        # The store reads moved into this file, so there are three - and the
        # count was never the point. The property was: A TOKEN FROM HERE GOES
        # TO THE FACADE AND NOWHERE ELSE. That is what is checked now.
        $auth = @([regex]::Matches($script:help, '(?m)^.*Authorization:.*$') | ForEach-Object { $_.Value })
        $auth.Count | Should -BeGreaterThan 0 -Because 'the file does send the viewer own token'
        $urls = @([regex]::Matches($script:help, 'fetch\(\s*([^,]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
        # PAGE-LOAD-1 added the fourth call to the service: many store
        # documents in one read (storeDocs), to the same facade.
        $urls.Count | Should -Be 6 -Because 'two same-origin config reads and four calls to the service are the whole allowance'
        @($urls | Where-Object { $_ -match 'apiUrl' }).Count |
            Should -Be 4 -Because 'the version read and the three store reads all go to the facade'
        foreach ($u in $urls) {
            $u | Should -Not -Match 'https?://' -Because "'$u' names an absolute host, and nothing here may reach one"
        }
    }

    It 'the templates it points at exist' {
        foreach ($t in 'bug_report.md', 'feature_request.md') {
            Test-Path (Join-Path $script:repoRoot '.github' 'ISSUE_TEMPLATE' $t) |
                Should -BeTrue -Because "the help menu opens ?template=$t"
        }
    }

    It 'a bug report carries the page and the run, which the person can still remove' {
        $script:help | Should -Match 'Page: \$\{page\}'
        $script:help | Should -Match 'Migration: \$\{run'
    }

    It 'the menu has its own title, not the support bundle''s' {
        # It announced "Send us what happened" over a list of four things, only
        # one of which sends anything.
        $script:help | Should -Match 'function dialog\(bodyHtml, buttons, titleText\)'
        $script:help | Should -Match 'esc\(titleText \|\| TEXT\.title\)'
    }

    It 'installing twice does not attach the handler twice' {
        # Found in use: Get help, then Cancel, opened the 'send us what
        # happened' box although the person cancelled. index.html calls
        # install() from renderActMenu(), which re-runs on every render, and
        # addEventListener ADDS rather than replaces - so after N renders one
        # click opened N stacked dialogs, and cancelling revealed the next one
        # down. It looked exactly like the dialog reopening itself.
        $script:help | Should -Match "link\.dataset\.vmfHelpBound === '1'"
        $script:help | Should -Match "link\.dataset\.vmfHelpBound = '1'"
        # the guard must sit BEFORE the listener, or it guards nothing
        $guard = $script:help.IndexOf('vmfHelpBound')
        $listen = $script:help.IndexOf("link.addEventListener('click'")
        $guard | Should -BeGreaterThan 0
        $guard | Should -BeLessThan $listen
    }

    It 'but the adapter IS refreshed each time, because the run can change' {
        # The bug is the listener, not the adapter. getRunId is read at open
        # time, and a later render may know a different run.
        $fn = [regex]::Match($script:help, '(?s)function install\(a\) \{.*?
  \}').Value
        $fn | Should -Match 'adapter = a;'
        $adapterAt = $fn.IndexOf('adapter = a;')
        $guardAt = $fn.IndexOf('vmfHelpBound === ')
        $adapterAt | Should -BeLessThan $guardAt -Because 'an early return must not skip the adapter update'
    }

    It 'the support bundle is still reachable, and unchanged in what it does' {
        $script:help | Should -Match 'function bundleDialog\(\)'
        $script:help | Should -Match 'buildBundle\(run\)'
    }
}

Describe 'ODCR-GAP-1: the page stops promising what the product cannot do' {
    It 'the reserved option says reserving is a separate action' {
        # TERM-1: this used to pin the words "needs reserving separately" and
        # "waits until somebody reserves" - invented phrasing that ALSO went
        # stale. CAPRG-1 gave the engine a working reservation on 2026-08-30,
        # and the facade and hosted engine both accept the operation; what is
        # missing is a screen that offers it. So a test pinning "this app
        # cannot do it" was, by then, holding the UI to a claim about a product
        # we had already stopped being.
        #
        # The gap it guards is real and still open, so the check stays - but
        # against what is TRUE now, in Azure's own words.
        # ODCR-BUTTON-1 CLOSED THIS GAP, so the check turns around: it used to
        # assert the page admitted it could not reserve, and now asserts that
        # it can. The page that ASKS for a reservation is the page that makes
        # one - the wave plan offers it.
        $script:waves | Should -Match 'on-demand capacity reservation'
        $script:waves | Should -Match 'data-reserve='
        $script:waves | Should -Not -Match '(?i)no screen offers it yet'
        $script:waves | Should -Not -Match 'needs reserving separately'
    }

    It 'and the engine refuses with that same explanation, not a claim-state message' {
        # ODCR-STATE-1: the words live in Get-VmfReservedCapacityRefusal now,
        # and there are four of them - the refusal says what THIS wave's
        # capacity is doing rather than reciting the options.
        #
        # The old version of this test also asserted that Start-VmfWave.ps1
        # matched 'New-VmfWaveReservation'. It did - in a COMMENT. The
        # assertion was satisfied by prose, which is the hazard CLAUDE.md
        # names, so it is gone rather than moved.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $refusal = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' `
            'Private' 'capacity' 'ReservedRefusal.ps1')
        $refusal | Should -Match 'no capacity has been reserved for it'
        $refusal | Should -Match 'is having its capacity reserved now'
        $refusal | Should -Match 'did not work'
    }
}

Describe 'FIRSTRUN-1: an empty app answers rather than instructs' {
    It 'renders a checked list instead of a wizard' {
        $script:idx | Should -Match 'async function renderFirstRun\(\)'
        # WAIT-3 gave this branch a second statement - it takes the waiting
        # state down before explaining an empty store - so the shape is no
        # longer one line. The RULE is unchanged and is what is checked: the
        # empty-state path calls renderFirstRun and returns. Pinning the
        # whitespace only pinned the formatting.
        $script:idx | Should -Match '(?s)if \(!currentRun\) \{[^}]*renderFirstRun\(\);[^}]*return;' `
            -Because 'the empty-state path renders the checked list and stops'
        # No FORCED wizard. index.html does navigate to the wizard - from the
        # "New migration" button, which is a person choosing to go there. What
        # must not happen is the empty-state path sending them automatically.
        $fn = [regex]::Match($script:idx, '(?s)async function renderFirstRun\(\) \{.*?
\}').Value
        $fn | Should -Not -Match 'location\.href'
        $fn | Should -Not -Match 'location\.replace'
    }

    It 'every item is something the page can actually check' {
        $fn = [regex]::Match($script:idx, '(?s)async function renderFirstRun\(\) \{.*?
\}').Value
        $fn | Should -Match 'Boolean\(account\)'          # signed in
        $fn | Should -Match 'myRoles\.length > 0'          # has a role
        # can read the store - PAGE-WAIT-1: from the run list's OWN listing,
        # which loadRuns keeps, rather than listing the whole store again.
        $fn | Should -Match 'if \(lastListError\)'
        $script:idx | Should -Match 'try \{ listed = await source\.listRuns\(held\); lastListError = null; \}'
    }

    It 'a refused read is explained in words, not shown raw' {
        # STORE-READ-1: this used to require the page to match /403/ itself and
        # keep its own storeForbidden sentence. The read goes through the
        # service now, so there is one refusal to explain and one place that
        # explains it. The rule is unchanged - what a refused first-run read
        # puts on the screen must be a sentence, never `list : HTTP 403` - so
        # the check moved from the page's own 403 test to the explainer call.
        $fn = [regex]::Match($script:idx, '(?s)async function renderFirstRun\(\) \{.*?
\}').Value
        $fn | Should -Match 'VmfHelp\.explain\('
        $fn | Should -Not -Match 'storeWhy = (e\?\.message|String\(e\))' -Because 'a raw error is engine text on the first screen anybody sees'
    }

    It 'and it says who gives a role, and which role the install gives' {
        # DEPLOYER-ROLES-WORDS-1: the sentence said the install gives nobody a
        # role, not even the person who installed it. False since FIRSTRUN-1:
        # the install (postprovision step 3, tools/Deploy-VmfFacade.ps1) gives
        # the user who runs it the Administrator role, and only that role
        # (ROLE-3). The words are pinned through the page's strings table.
        $code = Get-VmfCodeOnly -Language CStyle -Text $script:idx
        $table = [regex]::Match($code, '(?s)const UX_FIRST = \{.*?\n\};').Value
        $table | Should -Not -BeNullOrEmpty
        $fix = [regex]::Match($table, "fixRole: '([^']*)'").Groups[1].Value
        $fix | Should -Be 'A user with the Administrator role gives you a role on the Admin page. The install gives the Administrator role only to the user who runs the install.'
        $code | Should -Not -Match 'does not grant it' -Because 'the install gives its user the Administrator role'
        # The page's role name is the Admin page's own label for Vmf.Admin.
        (Get-Content (Join-Path $script:dashDir 'access.js') -Raw) | Should -Match "'Vmf\.Admin':\s*\['Administrator',"
        # And the install still grants that role and no other: if it changes,
        # this sentence changes with it.
        $deploy = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1') -Raw)
        $grants = [regex]::Matches($deploy, "appRoleId = \`$RoleIds\['([^']+)'\]") | ForEach-Object { $_.Groups[1].Value }
        @($grants) | Should -Be @('Vmf.Admin')
    }

    It 'it does not claim everything is fine while an item is unticked' {
        $fn = [regex]::Match($script:idx, '(?s)async function renderFirstRun\(\) \{.*?
\}').Value
        $fn | Should -Match 'signedIn && hasAnyRole && storeOk'
        $script:idx | Should -Match 'this page stays empty, even when migrations exist'
    }
}
