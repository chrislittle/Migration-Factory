#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PATH-NAME-1, 2026-09-19. Microsoft's rewritten migration guide names two
# execution methods, and one of them is exactly what this product does.
#
#   IN-PLACE UPGRADE    convert the controller, resize, keep the OS disk.
#                       Their eligibility list matches Path A item for item,
#                       and their rollback is ours: switch back to SCSI and
#                       the original size, disks untouched.
#
#   REDEPLOY FROM IMAGE a new machine from a FRESH IMAGE and a FRESH OS DISK,
#                       which is why their guide spends a section on capturing
#                       OS-disk data and restoring it afterwards.
#
# CLAUDE.md rule 10 says to use Azure's own technical names, so Path A takes
# theirs.
#
# PATH B TOOK NEITHER. It patched the controller on the EXISTING OS disk and
# rebuilt the machine around THE SAME DISKS. REBUILD-REMOVE-1
# (2026-11-07) removed it, and OLD-REBUILD-RESTORE-READERS-1 removed its name
# from the pages, so every page names one path. The rule that no move is a
# redeploy from image still holds: it would promise data loss the product does
# not cause.
#
# Against Microsoft's two names, none of the product's behaviour is a
# redeploy from image, and PATH-C-1 removed the one place the contract said
# otherwise.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:pages = @('assessments.html', 'migrations.html', 'reports.html')

    # Read the names OUT OF THE PRODUCT rather than writing them here twice.
    # A wording check with its own copy of the string passes on what the test
    # says, not on what ships.
    $script:names = @{}
    foreach ($page in $script:pages) {
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page)
        $map = [regex]::Match($text, "(?m)^const (?:PATH_WORDS|UX_PATH) = \{ A: '([^']+)' \};")
        if ($map.Success) { $script:names[$page] = @{ A = $map.Groups[1].Value } }
    }
}

Describe 'PATH-NAME-1: the resize is called what Azure calls it' {

    It 'every page that names a path was read' {
        $script:names.Keys.Count | Should -Be 3 -Because 'a check that read no pages proves nothing'
    }

    It 'and all three give the same name' {
        # Three copies of one map. They must not drift.
        @($script:names.Values | ForEach-Object { $_.A } | Sort-Object -Unique).Count | Should -Be 1
    }

    It 'path A uses Microsoft''s term' {
        foreach ($page in $script:pages) {
            $script:names[$page].A | Should -Be 'In-place upgrade' -Because "$page shows what Azure calls this"
        }
    }

    It 'OLD-REBUILD-RESTORE-READERS-1: and no page has a name for path B' {
        foreach ($page in $script:pages) {
            $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page)
            $text | Should -Not -Match "(?m)^const (?:PATH_WORDS|UX_PATH) = \{[^}]*B: '"
            $text | Should -Not -Match '(?i)rebuild around the same disks'
        }
    }
}

Describe 'PATH-NAME-1: nothing calls path B a redeploy from image' {
    # The inverted rule. Path B keeps the machine's own OS disk, so this phrase
    # would promise data loss the product does not cause.

    It 'no page says it' {
        $checked = 0
        foreach ($page in $script:pages) {
            $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page)
            $text | Should -Not -Match '(?i)redeploy from (a )?image'
            $text | Should -Not -Match '(?i)from a fresh image'
            $checked++
        }
        $checked | Should -Be 3
    }

    It 'and neither does anything an operator reads in the manual' {
        $pagesRead = 0
        foreach ($file in (Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Filter '*.md' -Recurse)) {
            ((Get-VmfPageSource -Path $file.FullName)) | Should -Not -Match '(?i)redeploy from (a )?image'
            $pagesRead++
        }
        $pagesRead | Should -BeGreaterOrEqual 40 -Because 'the whole manual was read, not an empty folder'
    }
}

Describe 'PATH-NAME-1: the manual uses the words the product shows' {

    It 'the words page defines the name, as the pages spell it' {
        $words = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'words.md') -Raw
        $any = $script:names[$script:pages[0]]
        $words | Should -Match ([regex]::Escape($any.A))
        $words | Should -Not -Match '(?i)rebuild around the same disks'
    }

    It 'and so does the page that explains how a machine moves' {
        $how = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'how-a-machine-moves.md') -Raw
        $any = $script:names[$script:pages[0]]
        $how | Should -Match ([regex]::Escape($any.A))
        $how | Should -Not -Match '(?i)rebuild around the same disks'
    }
}

Describe 'PATH-NAME-1: Generation 1 points at no route the product does not offer' {
    # PATH-NAME-1 first sent the operator to Microsoft's Trusted Launch upgrade
    # for v6 and v7. GEN1-UPGRADE-1 was decided 2026-10-05: not built, outside
    # the scope of this tool. Since 2026-10-31 (SUPPORT-MATRIX-2), no move
    # from Generation 1 to Generation 2 is supported. The reason now names no route
    # from Generation 1 to Generation 2, and links Microsoft's Generation 2 page.

    It 'the reason names no Generation 1 to Generation 2 route, and says what is outside the scope of this tool' {
        $reasons = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $g = $reasons.blockers.'gen1-requires-redeploy'
        $g.meaning | Should -Not -Match '(?i)trusted launch'
        $g.whatToDo | Should -Not -Match '(?i)trusted launch|upgrade'
        $g.whatToDo | Should -Match 'outside the scope of this tool'
        $g.docs.url | Should -Match '/generation-2$'
    }
}

Describe 'MAP-FIX-1: a Generation 1 machine is told about v5, never to rebuild from its disks' {
    # The finding told the operator to "Build a new Generation 2 machine from
    # this machine's disks" - route 2, which was ruled lab evidence only
    # (2026-09-24) - and five manual pages said a Generation 1 machine "cannot
    # move". GEN-V5-1 (2026-09-26) made v5 take Generation 1 with a resize, and
    # the lab proved it (V5-LAB-1). On 2026-09-28 the Generation 1 to v5 route
    # was built while the other routes were still evaluated.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:gen1 = (Get-Content -LiteralPath (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw |
            ConvertFrom-Json).blockers.'gen1-requires-redeploy'
        $script:manual = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter '*.md')
    }

    It 'reads the manual at all - an empty list would pass the checks below' {
        $script:manual.Count | Should -BeGreaterThan 30
    }

    It 'the finding sends the operator to v5 in the Choose each target step, only where a v5 size fits' {
        $script:gen1.meaning | Should -Match 'v5 sizes take Generation 1'
        # Not a promise: D v1, most Dv2 sizes and Windows older than 2016 get no
        # v5 option (the independent review of 2026-09-28).
        $script:gen1.whatToDo | Should -Match 'The Choose each target step shows v5 for this machine when a v5 size fits it'
        $script:gen1.whatToDo | Should -Not -Match '(?i)^Choose v5'
    }

    It 'the finding no longer tells anyone to build a machine from its disks' {
        $script:gen1.whatToDo | Should -Not -Match '(?i)disks'
        $script:gen1.whatToDo | Should -Not -Match '(?i)build a new'
    }

    It 'the finding still applies to v6 and v7 only' {
        @($script:gen1.appliesTo) | Should -Be @('v6', 'v7')
    }

    It 'no manual page says a Generation 1 machine cannot move at all, or needs a machine built from an image' {
        $found = foreach ($page in $script:manual) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            # Any phrasing of 'cannot move' that does not go on to name v6 or v7.
            if ($text -match '(?i)generation 1 machines? (cannot|can''t) (move|be moved)(?! to v6)' -or
                $text -match '(?i)built from a Generation 2 image') { $page.Name }
        }
        @($found) | Should -BeNullOrEmpty
    }

    # PUBLIC-SYNC-1: the guide map does not ship to the public repository.
    It 'the guide map no longer names the removed Path C' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'ms-guide-traceability.md'))) {
        Get-Content -LiteralPath (Join-Path $script:repoRoot 'docs' 'ms-guide-traceability.md') -Raw | Should -Not -CMatch '\bPath C\b'
    }
}
