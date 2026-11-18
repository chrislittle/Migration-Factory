#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# UI-MARKUP-1 - the static markup of every dashboard page must be structurally sound.
#
# FOUND 2026-09-01 while building the Projects page: `assessments.html` shipped
# with TWO tables carrying `id="runs-table"` and an unbalanced `</div>` - a
# leftover from building that page off the reports skeleton. It had been live.
#
# It did not break anything visible, because `querySelector` returns the first
# match, which is exactly why nothing caught it: the page worked, the JavaScript
# parsed (UI-PARSE-1 checks that), and every string test passed. A duplicate id
# is a trap for whoever edits the page next - they change the markup and the
# script silently keeps reading the other one.
#
# STATIC markup only. Ids built in a template literal (`id="mf-${f.id}"`) are
# generated per item and are not duplicates, and two render functions that never
# run at once may legitimately both use `id="b"`.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')

    function Global:StaticMarkup {
        param([string]$Path)
        $raw = (Get-VmfPageSource -Path $Path)
        # Everything outside <script>...</script> is markup the browser parses
        # as-is. Inside is where generated ids legitimately live.
        [regex]::Replace($raw, '(?is)<script\b.*?</script>', '')
    }
}
AfterAll { Remove-Item 'function:\StaticMarkup' -ErrorAction SilentlyContinue }

Describe 'UI-MARKUP-1: every page is structurally sound' {
    It 'found the pages' {
        @($script:pages).Count | Should -BeGreaterThan 3
    }

    It 'no page repeats an id in its static markup' {
        $offenders = @()
        foreach ($p in $script:pages) {
            $markup = StaticMarkup $p.FullName
            $ids = [regex]::Matches($markup, 'id="([^"${]+)"') | ForEach-Object { $_.Groups[1].Value }
            $dupes = @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
            if ($dupes) { $offenders += "$($p.Name): $($dupes -join ', ')" }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because 'querySelector returns the first match, so a duplicate id is a silent trap for the next editor'
    }

    It 'every page balances its div tags' {
        # The other half of the same leftover: a stray closing tag. Browsers
        # recover from it, which is why it survives review.
        $offenders = @()
        foreach ($p in $script:pages) {
            $markup = StaticMarkup $p.FullName
            $open  = @([regex]::Matches($markup, '<div\b')).Count
            $close = @([regex]::Matches($markup, '</div>')).Count
            if ($open -ne $close) { $offenders += "$($p.Name): $open open, $close close" }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }

    It 'every page is on the deploy list - a page not listed ships invisible' {
        # The deploy already throws for a LISTED file that is missing. The other
        # direction had no guard: a page that exists and is not named there is
        # simply never copied, so it is built, tested, committed and absent from
        # the running app. Found when projects.html was not on the list.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $missing = @($script:pages | Where-Object { $deploy -notmatch [regex]::Escape("'$($_.Name)'") } |
            ForEach-Object { $_.Name })
        ($missing -join ', ') | Should -BeNullOrEmpty -Because 'a dashboard page not named in the deploy list is never published'
    }

    It 'and every page the navigation links to actually exists' {
        # A nav entry pointing at a file nobody wrote is a 404 with the app's own
        # chrome around it.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $nav = [regex]::Match($help, '(?ms)const NAV = \[(.*?)\];').Groups[1].Value
        $hrefs = [regex]::Matches($nav, "href:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($hrefs).Count | Should -BeGreaterThan 3
        foreach ($h in $hrefs) {
            Test-Path (Join-Path $script:repoRoot 'src' 'dashboard' $h) |
                Should -BeTrue -Because "the navigation links to $h"
        }
    }

    It 'and every page carries the shared navigation rather than its own copy' {
        # The defect that produced help.js: the navigation bars did not agree
        # from page to page - six hand-maintained copies.
        foreach ($p in $script:pages) {
            $raw = (Get-VmfPageSource -Path $p.FullName)
            if ($raw -notmatch '<nav class="topnav"') { continue }
            $raw | Should -Match 'help\.js' -Because "$($p.Name) has a nav bar and must get it from the one place"
            # An empty <nav> that help.js fills. A page with links written in is
            # a seventh copy waiting to drift.
            $nav = [regex]::Match($raw, '(?s)<nav class="topnav">(.*?)</nav>').Groups[1].Value
            $nav.Trim() | Should -BeNullOrEmpty -Because "$($p.Name) must let help.js build the nav, not hard-code it"
        }
    }
}

Describe 'UI-WORDS-1: the pages use the app own nouns, not invented ones' {
    # Found on the project step: the UX text said 'carry on', avoided the
    # word project, said 'a person will look for this' and 'short name used
    # in addresses' - invented words everywhere.
    #
    # The cause was over-applying the plain-language rule. That
    # rule is about ENGINE vocabulary - NVMe, SCSI, schemaVersion - not a licence
    # to invent euphemisms for ordinary words. A project became a "piece of
    # work", assessments "times looked at", Continue "carry on". The result
    # contradicted the app's OWN NAVIGATION, which says Projects, Assessments,
    # Migrations, and read as baby talk.
    #
    # Project, assessment and migration are the words. They are what Azure
    # Migrate uses - the model this product follows - and what an
    # operator already knows.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # Only OPERATOR-FACING strings: the UX blocks each page declares. Code
        # comments explain the history and must stay free to say "piece of work"
        # when describing the mistake.
        $script:uxText = @{}
        foreach ($p in $script:pages) {
            $raw = (Get-VmfPageSource -Path $p.FullName)
            $block = [regex]::Match($raw, '(?ms)^const UX(_\w+)? = \{.*?^\};').Value
            if ($block) { $script:uxText[$p.Name] = $block }
        }
    }

    It 'found the UX blocks to check' {
        @($script:uxText.Keys).Count | Should -BeGreaterThan 2
    }

    It 'no page invents a substitute for a word the navigation already uses' {
        # The words moved into tools/Test-SimplifiedEnglish.ps1 with every other
        # vocabulary rule (STE-1), so a page answers to ONE bar rather than to
        # whichever test happens to read it.
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $ste = & (Join-Path $repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') 6>$null
        @($ste.Findings | Where-Object { $_.Rule -eq 'vague' } |
            ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' |
            Should -BeNullOrEmpty -Because 'the navigation says Projects, Assessments and Migrations - the pages must agree with it'
    }

    It 'the product name is a label, not a shortcut into one area' {
        # Clicking the product name opened the migrations page; with several
        # areas, the name should go nowhere.
        #
        # It linked to index.html, so the name of the WHOLE product acted as a
        # shortcut to one of its five areas - and the one it chose was
        # Migrations, which is not where anybody starts. The navigation beside
        # it names every area; the name itself needs to name the product.
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        foreach ($page in Get-ChildItem (Join-Path $repoRoot 'src' 'dashboard') -Filter '*.html') {
            $text = (Get-VmfPageSource -Path $page.FullName)
            if ($text -notmatch 'class="brand"') { continue }
            $text | Should -Not -Match '<a[^>]*class="brand"' -Because "$($page.Name) must not make the product name a link"
            $text | Should -Match '<span class="brand">' -Because "$($page.Name) still shows the name"
        }
    }

    It 'buttons say Continue, not Carry on' {
        # Folksy is not plain. It is just a different dialect for the reader to
        # translate.
        $offenders = @()
        foreach ($name in $script:uxText.Keys) {
            if ($script:uxText[$name] -match "(?i)'[^']*\bcarry on\b[^']*'") { $offenders += $name }
        }
        ($offenders -join ', ') | Should -BeNullOrEmpty
    }

    It 'and does not explain a field by describing the reader' {
        # "A person will look for this" tells somebody about themselves instead
        # of about the box they are filling in.
        $offenders = @()
        foreach ($name in $script:uxText.Keys) {
            if ($script:uxText[$name] -match '(?i)a person will look') { $offenders += $name }
        }
        ($offenders -join ', ') | Should -BeNullOrEmpty
    }

    It 'the Projects page actually calls them projects' {
        $ux = $script:uxText['projects.html']
        $ux | Should -Not -BeNullOrEmpty
        $ux | Should -Match "listTitle:\s*'Projects'"
        $ux | Should -Match "(?i)'[^']*\bproject\b"
    }
}
