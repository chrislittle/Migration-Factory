#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DOCS-1 - the manual is one set of files read two ways, and both ways must work.
#
# Found 2026-09-07: the readme and its links to the install docs (md files)
# were poor. Everything in the manual must also read well on GitHub, so a
# user can use either way; a manual ONLY in the app would be a flaw.
#
# It is not only in the app - the files ARE markdown in the repository - but
# nobody could navigate them there. In the app docsify renders `_sidebar.md` as
# navigation. On GitHub there is no docsify: `_sidebar.md` is just another file,
# and a reader landing in docs/manual had no way through 45 pages.
#
# So the manual's README carries a contents list generated FROM the sidebar by
# tools/Update-VmfManualToc.ps1 - one source, two renderings. These tests hold
# the properties that make that safe: nothing orphaned, nothing dead, and the
# two lists never out of step.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:sidebarText = Get-Content (Join-Path $script:manual '_sidebar.md') -Raw
    $script:readmeText = Get-Content (Join-Path $script:manual 'README.md') -Raw

    $script:pages = @(Get-ChildItem $script:manual -Filter '*.md' -Recurse |
        Where-Object { $_.Name -ne '_sidebar.md' } |
        ForEach-Object { $_.FullName.Substring($script:manual.Length + 1).Replace('\', '/') })

    $script:sidebarLinks = @([regex]::Matches($script:sidebarText, '\]\(/([^)]+\.md)\)') |
        ForEach-Object { $_.Groups[1].Value })
    # The contents block only - the prose above it links pages too, and those
    # are not navigation.
    $block = [regex]::Match($script:readmeText, '(?s)contents:start.*?contents:end').Value
    $script:readmeLinks = @([regex]::Matches($block, '\]\(([^)]+\.md)\)') |
        ForEach-Object { $_.Groups[1].Value })
}

Describe 'DOCS-1: the manual can be read on GitHub, not only in the app' {

    It 'found the pages, or this proves nothing' {
        $script:pages.Count | Should -BeGreaterThan 30
    }

    It 'every page is reachable from the sidebar - nothing is orphaned' {
        # A page nobody links to is a page nobody reads, in either renderer.
        $missing = @($script:pages | Where-Object { $_ -notin $script:sidebarLinks })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a page not in the sidebar cannot be found in the app'
    }

    It 'every page is reachable from the contents list too - the GitHub route' {
        $missing = @($script:pages | Where-Object { $_ -ne 'README.md' -and $_ -notin $script:readmeLinks })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'GitHub does not render the sidebar, so this list is the only way through'
    }

    It 'and every link points at a file that exists, in both' {
        $dead = foreach ($link in ($script:sidebarLinks + $script:readmeLinks)) {
            if (-not (Test-Path (Join-Path $script:manual $link))) { $link }
        }
        @($dead | Sort-Object -Unique) -join ', ' | Should -BeNullOrEmpty
    }

    It 'the contents list is exactly what the generator produces, so the two cannot drift' {
        # Regenerating must be a no-op. If it is not, somebody edited a page
        # list by hand and the other renderer is now wrong.
        $readme = Join-Path $script:manual 'README.md'
        $before = Get-Content $readme -Raw
        try {
            & (Join-Path $script:repoRoot 'tools' 'Update-VmfManualToc.ps1') | Out-Null
            (Get-Content $readme -Raw) | Should -Be $before -Because 'run tools/Update-VmfManualToc.ps1 and commit the result'
        }
        # REVIEW-1: written back only when the generator changed it. Test files
        # run in groups at once now (CI-SPEED-3), and rewriting an unchanged
        # file opens a moment where another group's scanner reads it half-written.
        finally { if ((Get-Content $readme -Raw) -ne $before) { Set-Content -LiteralPath $readme -Value $before -Encoding utf8NoBOM -NoNewline } }
    }

    It 'the contents links are RELATIVE, because docsify and GitHub both resolve those' {
        # The sidebar uses docsify's root-relative form (/use/start.md). On
        # GitHub that is a link to the site root and 404s.
        $rooted = @($script:readmeLinks | Where-Object { $_.StartsWith('/') })
        $rooted -join ', ' | Should -BeNullOrEmpty -Because 'a root-relative link is broken on GitHub'
    }
}

Describe 'DOCS-1: the front door points at the manual, install first' {

    BeforeAll { $script:rootReadme = Get-Content (Join-Path $script:repoRoot 'README.md') -Raw }

    It 'the repository README links into the manual' {
        $script:rootReadme | Should -Match 'docs/manual/README\.md'
    }

    It 'and names the install path, because that is what a new reader needs first' {
        # The problem: the manual read as something you consult AFTER
        # installing, which is backwards - the install chapters are IN it.
        $script:rootReadme | Should -Match 'docs/manual/install/before-you-install\.md'
    }

    It 'nothing tells a reader to call Pester directly, wherever it says it' {
        # CLAUDE.md: a bare Invoke-Pester takes the newest of the installed
        # versions, which is not the one CI runs. The README once printed
        # exactly that.
        #
        # THIS TEST IS NOW KEYED TO CONTENT, NOT TO A PATH. In two hours the
        # instruction moved three times - out of the README, into the manual,
        # then out of the manual again - and this test had to be edited every
        # time, which made it a maintenance cost rather than a guard. A test
        # that names one file only holds that file.
        #
        # The rule is: SOMEWHERE authoritative says how to run the checks, and
        # NOWHERE a person follows says to call Pester directly.
        # PUBLIC-SYNC-1: CLAUDE.md does not ship to the public repository;
        # there CONTRIBUTING.md (from public/) is the page that says it.
        $brief = @('CLAUDE.md', 'CONTRIBUTING.md') | ForEach-Object { Join-Path $script:repoRoot $_ } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        $brief | Should -Not -BeNullOrEmpty -Because 'CLAUDE.md here, or CONTRIBUTING.md in the public repository, must say how to run the checks'
        (Get-Content $brief -Raw) | Should -Match 'Invoke-VmfTests\.ps1' -Because 'the brief must say how to run the checks'

        # Every markdown a person would follow. The ledger is excluded on
        # purpose: it is a historical record, and it QUOTES the wrong command
        # while explaining why it was wrong.
        $docs = @(Get-ChildItem $script:repoRoot -Filter '*.md' -File) +
                @(Get-ChildItem (Join-Path $script:repoRoot 'docs') -Filter '*.md' -File -Recurse |
                    Where-Object { $_.Name -ne 'backlog.md' -and $_.Directory.Name -ne 'backlog' })
        @($docs).Count | Should -BeGreaterThan 40 -Because 'a narrow check that finds nothing proves nothing'
        $bad = foreach ($doc in $docs) {
            $lines = [System.IO.File]::ReadAllLines($doc.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*(pwsh\s+)?Invoke-Pester\b') { "$($doc.Name):$($i + 1)" }
            }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'a bare Invoke-Pester takes a version CI does not run'
    }}

# DOCS-NEXT-1, 2026-09-09. Found on `use/read-an-assessment.md`: the page
# just ended, with no link to the next step. Every page must end by moving
# the reader on through the manual.
#
# MEASURED before the fix: 29 of 45 pages ended with no link to anywhere. The
# 16 that looked correct were not a convention - they were prose links that
# happened to sit near the end of a section. Only use/start.md had a footer.
#
# In the app docsify draws the sidebar, so a reader can always move. On GitHub
# there is no sidebar: the page IS the whole of what a reader sees, and a page
# that ends is a dead end.
Describe 'DOCS-NEXT-1: no manual page is a dead end' {

    BeforeAll {
        $script:nextBegin = '<!-- next:begin -->'
        # The reading order, straight through the sidebar - the same source
        # tools/Update-VmfManualNextSteps.ps1 writes from.
        $script:order = @([regex]::Matches($script:sidebarText, '(?m)^\s*-\s*\[(?<text>[^\]]+)\]\((?<href>[^)]+)\)\s*$') |
            ForEach-Object { [pscustomobject]@{
                Href = ($_.Groups['href'].Value -replace '^/', '')
                Text = $_.Groups['text'].Value
            } })
    }

    It 'the sidebar still lists the whole manual' {
        $script:order.Count | Should -Be $script:pages.Count
    }

    It 'EVERY page carries a footer' {
        # The assertion that would have caught this on the day it appeared.
        $without = @($script:order | Where-Object {
            (Get-Content (Join-Path $script:manual $_.Href) -Raw) -notmatch [regex]::Escape($script:nextBegin)
        } | ForEach-Object { $_.Href })
        $without -join ', ' | Should -BeNullOrEmpty -Because 'a page that ends nowhere is a dead end on GitHub'
    }

    It 'and every footer names the page the sidebar puts next' {
        # Hand-written, a chain of 45 links is wrong the first time a page
        # moves. This is what makes the generator worth having.
        for ($i = 0; $i -lt $script:order.Count - 1; $i++) {
            $page = $script:order[$i]
            $next = $script:order[$i + 1]
            $text = Get-Content (Join-Path $script:manual $page.Href) -Raw
            $footer = [regex]::Match($text, '(?s)<!-- next:begin -->(?<f>.*?)<!-- next:end -->').Groups['f'].Value
            $footer | Should -Match ([regex]::Escape("[$($next.Text)]")) -Because "$($page.Href) comes before $($next.Href)"
        }
    }

    It 'the last page leads back to the contents, not nowhere' {
        $last = $script:order[-1]
        $text = Get-Content (Join-Path $script:manual $last.Href) -Raw
        $text | Should -Match 'Back to.*\]\(\.\./README\.md\)'
    }

    It 'every footer link resolves to a file that exists' {
        # '../README.md/README.md/README.md' was a real output of the first
        # version: $parts[0..($parts.Count - 2)] on a path with no folder is the
        # range 0..-1, which PowerShell expands to the FIRST and LAST element
        # rather than to nothing.
        foreach ($page in $script:order) {
            $path = Join-Path $script:manual $page.Href
            $text = Get-Content $path -Raw
            $href = [regex]::Match($text, '(?s)<!-- next:begin -->.*?\]\((?<h>[^)]+)\)').Groups['h'].Value
            $href | Should -Not -BeNullOrEmpty -Because "$($page.Href) must link somewhere"
            $target = Join-Path (Split-Path $path -Parent) $href
            (Test-Path -LiteralPath $target) | Should -BeTrue -Because "$($page.Href) links to $href"
        }
    }
}
