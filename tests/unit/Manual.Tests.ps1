#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DOC-4: the manual (since 2026-09-05): complete documentation from start
# to finish, with full user guides for the app - a manual a novice can use,
# kept in GitHub and shown in the app, written in strong ASD-STE100.
#
# What is held here: the manual is whole (every sidebar entry is a page,
# every picture it shows exists), it matches the product (the three generated
# reference pages are not stale; the screenshots are taken by a tool, not by
# hand), it ships with the dashboard (the deploy copies it, IIS serves its
# Markdown, the Get help menu opens it), and it never uses the two words a
# user does not understand outside the technical chapter.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:sidebar = Get-Content (Join-Path $script:manual '_sidebar.md') -Raw
    $script:pages = @(Get-ChildItem $script:manual -Filter '*.md' -Recurse | Where-Object { $_.Name -ne '_sidebar.md' })
}

Describe 'DOC-4: the manual is whole' {
    It 'every sidebar entry is a page that exists, and every page is in the sidebar' {
        # Absolute, from the manual's root: docsify resolves page links relative
        # to the page (relativePath), and a relative sidebar link would then
        # point somewhere different from every page. Found live.
        $raw = @([regex]::Matches($script:sidebar, '\]\(([^)]+\.md)\)') | ForEach-Object { $_.Groups[1].Value })
        foreach ($r in $raw) { $r | Should -Match '^/' -Because "the sidebar link $r must start with / so it resolves the same from every page" }
        $links = @($raw | ForEach-Object { $_.TrimStart('/') })
        $links.Count | Should -BeGreaterThan 40
        foreach ($l in $links) { Test-Path (Join-Path $script:manual $l) | Should -BeTrue -Because "the sidebar names $l" }
        foreach ($p in $script:pages) {
            $rel = $p.FullName.Substring($script:manual.Length + 1) -replace '\\', '/'
            $links | Should -Contain $rel -Because "$rel is a page nobody can reach from the sidebar"
        }
    }

    It 'every picture a page shows exists, and every picture on disk is shown' {
        $shown = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            foreach ($m in [regex]::Matches($text, '!\[[^\]]*\]\(([^)]+)\)')) {
                $img = [System.IO.Path]::GetFullPath((Join-Path $p.DirectoryName $m.Groups[1].Value))
                Test-Path $img | Should -BeTrue -Because "$($p.Name) shows $($m.Groups[1].Value)"
                $null = $shown.Add([System.IO.Path]::GetFileName($img))
            }
        }
        foreach ($png in Get-ChildItem (Join-Path $script:manual 'images') -Filter '*.png') {
            $shown.Contains($png.Name) | Should -BeTrue -Because "$($png.Name) is on disk and no page shows it"
        }
    }

    It 'every link between pages resolves' {
        foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            foreach ($m in [regex]::Matches($text, '(?<!!)\[[^\]]+\]\(([^)#]+\.md)(#[^)]*)?\)')) {
                $target = [System.IO.Path]::GetFullPath((Join-Path $p.DirectoryName $m.Groups[1].Value))
                Test-Path $target | Should -BeTrue -Because "$($p.Name) links to $($m.Groups[1].Value)"
            }
        }
    }

    It 'the screenshots are taken by a tool from the sample pages, so they can be re-taken' {
        $shots = Get-Content (Join-Path $script:repoRoot 'tools' 'manual-shots.js') -Raw
        foreach ($png in Get-ChildItem (Join-Path $script:manual 'images') -Filter '*.png') {
            $shots | Should -Match ([regex]::Escape("'$($png.Name)'")) -Because "$($png.Name) must be listed in the screenshot tool, never taken by hand"
        }
        $shots | Should -Match '\?demo' -Because 'the pictures come from the sample data, never from a real estate'
    }

    It 'the four generated reference pages are not stale' {
        { & (Join-Path $script:repoRoot 'tools' 'Update-VmfManualReference.ps1') -Check } | Should -Not -Throw
    }
}

Describe 'DOC-4: the manual ships with the dashboard' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $script:help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $script:webConfig = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'web.config') -Raw
        $script:index = (Get-VmfPageSource -Path (Join-Path $script:manual 'index.html'))
    }

    It 'the deploy copies the whole manual beside the pages, and refuses to publish without it' {
        $script:deploy | Should -Match "Copy-Item \`$manual \(Join-Path \`$stage 'manual'\) -Recurse"
        $script:deploy | Should -Match 'Refusing to publish: the manual is missing'
    }

    It 'IIS serves the Markdown pages' {
        $script:webConfig | Should -Match '<mimeMap fileExtension="\.md" mimeType="text/markdown" />'
    }

    It 'the manual needs nothing outside the dashboard: every script and sheet it loads is vendored' {
        foreach ($m in [regex]::Matches($script:index, '(?:src|href)="([^"]+)"')) {
            $m.Groups[1].Value | Should -Not -Match '^https?://' -Because 'the content policy allows scripts from the dashboard itself and nowhere else'
            Test-Path (Join-Path $script:manual $m.Groups[1].Value) | Should -BeTrue -Because "index.html loads $($m.Groups[1].Value)"
        }
    }

    # MANUAL-MERMAID-1: the diagram library draws in strict mode: no script
    # and no click handler from a diagram. Read from the page's script with
    # its comments removed, so a comment cannot pass it.
    It 'the diagrams are drawn in strict mode' {
        $page = [regex]::Match($script:index, '(?s)<script>(?<js>.*?mermaid\.initialize.*?)</script>').Groups['js'].Value
        $page | Should -Not -BeNullOrEmpty
        $code = Get-VmfCodeOnly -Text $page -Language CStyle
        $init = [regex]::Match($code, '(?s)mermaid\.initialize\(\{(?<o>.*?)\}\);').Groups['o'].Value
        $init | Should -Match "securityLevel: 'strict'"
    }

    It 'the Get help menu opens it, and the screen guide points at it rather than at GitHub' {
        $script:help | Should -Match "menuManual: 'Read the manual'"
        $script:help | Should -Match "const MANUAL_URL = 'manual/index\.html'"
        # NO-POPUPS-1: in this tab, through the one helper that names the way back.
        $script:help | Should -Match "if \(kind === 'manual'\) \{ openManual\(\); return; \}"
        $script:help | Should -Match "return MANUAL_URL \+ '\?from=' \+ encodeURIComponent\(from\)"
        $script:help | Should -Match "guideGeneral: 'Read the manual'"
        $script:help | Should -Not -Match 'window\.open\(`\$\{REPO\}#readme`' -Because 'DOC-3 already ruled that a person mid-migration is not sent out of the product to read about it'
    }
}

Describe 'DOC-4: the words' {
    It 'outside the technical chapter, the manual never says "gate" and says "engine" only where it defines the word' {
        # Terms like "closing gates" and "granting the engine access" mean
        # nothing to a user of this product.
        foreach ($p in ($script:pages | Where-Object { $_.FullName -notmatch '[\\/]technical[\\/]' })) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            $text | Should -Not -Match '(?i)\bgates?\b' -Because "$($p.Name) must not say gate"
            $hits = @([regex]::Matches($text, '(?i)\bengine\b')).Count
            if ($p.Name -in 'words.md', 'what-it-does.md') { $hits | Should -BeLessOrEqual 3 -Because "$($p.Name) defines the word once" }
            else { $hits | Should -Be 0 -Because "$($p.Name) must say 'the product', not 'the engine'" }
        }
    }

    It 'no operator-facing word is one Azure already has a name for' {
        <#
            DOCS-NAME-2. The list lives in tests/fixtures/azure-terms.json so a
            later sweep adds a row rather than editing a test, and so the
            reason each phrase is banned travels with it.

            Both halves of what an operator reads are checked: the manual, and
            the dashboard's own strings. DOCS-NAME-1 fixed the manual and left
            an identical phrase sitting in a dashboard label, which is exactly
            how it came back the first time.
        #>
        $fixture = Join-Path $script:repoRoot 'tests' 'fixtures' 'azure-terms.json'
        $avoid = @((Get-Content $fixture -Raw | ConvertFrom-Json).avoid)
        $avoid.Count | Should -BeGreaterThan 3 -Because 'the list must have loaded'

        # FOUND BY MUTATION. Counting the rows does not protect them: swapping
        # a real phrase for a harmless one keeps the count and empties the
        # guard. Every phrase below was in SHIPPED text once, so none of them
        # leaves this list. A later sweep may add rows freely; it may not
        # quietly drop one that already got through.
        $shipped = @('network card', 'disk connection', 'faster adapter',
                     'from the inside', 'before the day')
        foreach ($phrase in $shipped) {
            @($avoid.phrase) | Should -Contain $phrase `
                -Because 'this one reached an operator once already'
        }

        # The dashboard's vendored libraries are somebody else's words.
        $surfaces = @($script:pages | ForEach-Object { $_.FullName }) + @(
            Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -File |
                Where-Object { $_.Extension -in '.html', '.js' -and $_.Name -notlike '*min.js' } |
                ForEach-Object { $_.FullName })

        $found = @()
        foreach ($file in $surfaces) {
            $text = (Get-VmfPageSource -Path $file)
            foreach ($bad in $avoid) {
                if ($text -match [regex]::Escape($bad.phrase)) {
                    $found += "$(Split-Path $file -Leaf) says '$($bad.phrase)' - use $($bad.use)"
                }
            }
        }
        $found | Should -BeNullOrEmpty
    }

    It 'the quota definitions are in the unit Azure states quota in' {
        <#
            Azure states a virtual machine quota in vCPUs, and that is the word
            on the page an operator opens to raise it. The manual said "cores"
            in both places that define quota, which is the same class of defect
            as an invented name: close enough to read past, and not the word
            they will see.

            'cores' is not banned outright - the Container Apps environment's
            quota really is measured in cores, and those pages are correct.

            QUOTA-NOT-CAPACITY-1 rewrote the capacity page's definition in
            Microsoft's framing - "the permission of the subscription to deploy
            vCPUs" - so a defining line is either form. The rule is unchanged:
            the line that defines quota says vCPU.
        #>
        foreach ($rel in @('understand/words.md', 'use/capacity.md')) {
            $text = Get-Content (Join-Path $script:manual ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)) -Raw
            $quotaLines = @($text -split "`n" | Where-Object { $_ -match '(?i)quota' -and $_ -match '(?i)subscription may use|permission of the subscription' })
            $quotaLines.Count | Should -BeGreaterThan 0 -Because "$rel defines quota"
            foreach ($line in $quotaLines) {
                $line | Should -Match 'vCPU' -Because "$rel must state quota in the unit Azure uses"
            }
        }
    }

    It 'the five phases say what the product actually does' {
        <#
            The summary is the first thing a customer reads and it was the
            loosest writing in the manual. "It checks capacity and quota before
            the day" claims more than the product does: the forecast verifies
            QUOTA against the family's limit and usage, and names a size the
            region restricts. CAPACITY - whether the hardware is there - is
            only guaranteed by a reservation, which the capacity page explains
            correctly. The summary skipped the distinction the rest of the
            manual is careful about.
        #>
        $text = Get-Content (Join-Path $script:manual 'understand' 'what-it-does.md') -Raw
        $text | Should -Match '(?i)accelerated networking' -Because 'the network check has an Azure name'
        $text | Should -Match 'Microsoft Azure Network Adapter' -Because 'and so does the adapter'
        $text | Should -Match '(?i)NVMe disk' -Because 'the check inside the machine reads the disk it starts from'
        $text | Should -Match '(?i)verifies the quota' -Because 'quota is the thing the plan verifies'
    }

    It 'the capacity page still separates quota from capacity' {
        <#
            This is the page that got it right, and the reason the summary's
            error was visible at all. Azure states it plainly: "Quota and
            capacity are separate checks. Quota is your subscription's
            permission to deploy resources, while capacity is the underlying
            infrastructure available in a specific region or zone."

            If this distinction is ever edited away, the summary's old claim
            becomes defensible again and the product starts promising capacity
            it cannot give.

            QUOTA-NOT-CAPACITY-1 replaced the page's own sentence ("Even with
            quota, a region can be short of a size on a busy day") with
            Microsoft's framing, which says the same thing without a claim
            about how often Azure runs short. The check follows the new words.
        #>
        $text = Get-Content (Join-Path $script:manual 'use' 'capacity.md') -Raw
        $text | Should -Match '(?i)Quota and capacity are separate checks' -Because 'quota is not capacity, and the page says so'
        $text | Should -Match '(?i)A quota does not reserve or guarantee capacity' -Because 'quota is not capacity, and the page says so'
        $text | Should -Match '(?i)availability set' -Because 'Azure cannot associate an availability set member to a reservation'
    }

    It 'every page is a source of the wording gate' {
        $tool = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Raw
        $tool | Should -Match "Name = \`"manual/\`$rel\`""
        $sources = @(& (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -ListSources 6>$null | Out-String) -join "`n"
        $sources | Should -Match 'manual/README\.md'
        $sources | Should -Match 'manual/use/watch\.md'
    }
}
