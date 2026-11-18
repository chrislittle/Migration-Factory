#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PROJ-LINK-1 - a count you cannot open is not information.
#
# On the Projects page, a test project had no link to the assessment made in
# it, and the page acted as if a new one were needed.
#
# That is what it looked like. The row said this project had 1 assessment, and
# then offered one action: "New assessment". A person who has just made an
# assessment reads that as "the one I made is not here", and the only route the
# page offers is to make a second one - which costs a scan and leaves two
# assessments where one was wanted.
#
# The counts are links now, into the page that lists the thing counted,
# filtered to that project.
#
# AND THE SECOND HALF, from the same walkthrough: "we say not reviewed yet but
# we can just plan a migration and bypass it? shouldn't we at least make people
# review it before that button is available?" - then, having pressed it: "oh nm
# I see it takes to the review anyway".
#
# Nothing was bypassed. The wizard opens at the review step, and the engine
# refuses to plan from an unapproved assessment (ASSESS-PAGE-1). The BUTTON was
# lying about where it went, and a person had to press it to find out. It now
# says what happens next.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:projects = (Get-VmfPageSource -Path (Join-Path $script:dash 'projects.html'))
    $script:help     = Get-Content (Join-Path $script:dash 'help.js') -Raw
    $script:assess   = (Get-VmfPageSource -Path (Join-Path $script:dash 'assessments.html'))
    $script:index    = (Get-VmfPageSource -Path (Join-Path $script:dash 'migrations.html'))
}

Describe 'PROJ-LINK-1: the counts go somewhere' {

    # PAGE-SCALE-PROJECTS-1: the row is drawn by the shared list in help.js
    # (VmfHelp.listMount). The page names where each count goes; help.js
    # writes the address and the cell. tests/js/page-scale-projects.test.js
    # and page-scale-list.test.js RUN both.
    It 'a project links to its assessments and to its migrations' {
        $script:projects | Should -Match "assessments: \{ n: p\.assessments, dest: \{ page: 'assessments', project: id \} \}"
        $script:projects | Should -Match "migrations: \{ n: p\.migrations, dest: \{ page: 'migrations', project: id \} \}"
        $script:help | Should -Match "case 'assessments': return l\.run \? runLink\('assessments\.html', l\.run\) : 'assessments\.html' \+ q;"
        $script:help | Should -Match "case 'migrations': return l\.run \? runLink\('migrations\.html', l\.run\) : 'migrations\.html' \+ q;"
    }

    It 'and passes the project id through a URL encoder' {
        # Project ids are lower-case and hyphenated by New-VmfProject, so today
        # nothing needs escaping. That is a property of the validator, not of
        # this page, and the page must not depend on it.
        $script:help | Should -Match '\?project=\$\{encodeURIComponent\(l\.project\)\}'
    }

    It 'a count of zero is not a link to an empty page' {
        # Nothing to open is a different state from something to open, and a
        # link that leads to "nothing here" wastes the click.
        $script:projects | Should -Match "kind: 'count'"
        $script:help | Should -Match "return n > 0 \? ``<a href=" -Because 'zero renders as text, not as a link'
    }

    It 'both destinations actually honour ?project=' {
        # The link is only real if the page it points at filters. Ids inside a
        # project are `project/run-id`, so the filter is the prefix - and it
        # must be the prefix WITH the slash, or project `ux` would swallow
        # `ux-test-project`.
        $script:index | Should -Match "get\('project'\)" -Because "the migrations page must read the filter"
        $script:index | Should -Match "startsWith\(\s*only\w*\s*\+\s*'/'\s*\)" -Because "the migrations page must match on the whole project id"
        # PAGE-SCALE-ASSESSMENTS-1: the Assessments page gives ?project= to the
        # shared list as the project filter to start with. That filter compares
        # the WHOLE project id of each row (listMatches), never a prefix, and
        # tests/js/page-scale-assessments.test.js and page-scale-list.test.js
        # RUN both.
        $script:assess | Should -Match "const project = new URLSearchParams\(location\.search\)\.get\('project'\) \|\| '';"
        $script:assess | Should -Match 'projectId: VmfHelp\.VmfRun\.parse\(a\.id\)\.project \|\| null'
        $script:help | Should -Match "if \(pid !== project\) \{ return false; \}"
    }

    It 'and an unfiltered page still shows everything' {
        # The filter is opt-in. A missing parameter must not empty the page.
        $script:index | Should -Match '!only\w*\s*\|\|' -Because "the migrations page must show everything when no project is named"
        $script:help | Should -Match "if \(project\) \{" -Because 'the shared list filters only when a project is chosen'
    }
}

Describe 'PROJ-LINK-1: the button says where it goes' {

    # PAGE-SCALE-ASSESSMENTS-1: the words of the approved design - Review,
    # Plan a migration, Open - with the Overview's Review. The row's action
    # is RUN in tests/js/page-scale-assessments.test.js.
    It 'an unreviewed assessment offers the REVIEW, not the plan' {
        $script:assess | Should -Match "text: status === 'accepted' \? UX\.actPlan : UX\.actReview"
        $script:assess | Should -Match "actReview:\s*'Review'"
    }

    It 'and a reviewed one offers the plan, and a planned one the migration and Plan another' {
        $script:assess | Should -Match "actPlan:\s*'Plan a migration'"
        $script:assess | Should -Match "if \(status === 'planned'\) \{ return \{ text: UX\.actOpen, dest: \{ page: 'migrations', run: r\.planned\[0\] \} \}; \}"
        $script:assess | Should -Match 'UX\.openAgain'
    }

    It 'the wording says the action rather than pointing at something' {
        # STE-1: no vague pronouns in a control label.
        foreach ($k in 'actReview', 'actPlan', 'actOpen') {
            $m = [regex]::Match($script:assess, "$k\s*:\s*'([^']*)'")
            $m.Success | Should -BeTrue
            $m.Groups[1].Value | Should -Not -Match '(?i)this one|it$'
        }
    }

    It 'and the gate itself is still in the ENGINE, not in the label' {
        # The button is honest signposting. It is NOT the control that stops an
        # unreviewed plan - a page-only gate is bypassed by the API path, which
        # is how the app actually runs.
        $plan = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $plan | Should -Match 'has not been reviewed' -Because 'the refusal lives where it cannot be routed around'
    }
}
