#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# UPST-3: watch Microsoft's v6/v7 migration DOCUMENTATION, not just their scripts.
#
# UPST-1 watches upstream code. Nearly every hard-won rule in CLAUDE.md started
# as a line in these pages - temp-disk categories, OS floors, hibernation, the
# quota-family quirk - so guidance can change underneath the engine with nothing
# in our code moving at all.
#
# Watched as a SECTION on purpose. Microsoft has already added pages next to the
# original five (scsi-to-nvme-migration, previous-gen-series-capacity-limitations),
# and a file-LIST watcher would never have said a word about them. New and
# removed pages are first-class drift here.
#
# DOCS-DRIFT-LEARN-1, 2026-10-03: the pages are read from learn.microsoft.com as
# markdown, not from the GitHub documentation repositories, which Microsoft is
# making private by the end of December 2026. Every test here runs on stored
# sample responses (tests/fixtures/docs-drift) - none needs the network.
BeforeAll {
    # TEMP-LITTER-1: this file made fifteen loose json files in the temp folder
    # per run and removed none of them - 2,367 of the 4,307 measured there.
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'docs'

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-DocsDrift.ps1'
    $script:baselinePath = Join-Path $script:repoRoot 'docs' 'upstream-docs.json'
    $script:baseline = Get-Content $script:baselinePath -Raw | ConvertFrom-Json -Depth 8
    $script:textRoot = Join-Path $script:repoRoot 'docs' $script:baseline.textFolder

    $fixtures = Join-Path $script:repoRoot 'tests' 'fixtures' 'docs-drift'
    # A Learn page as Learn returns it for Accept: text/markdown - front matter,
    # then the page - and the same page republished with only the front matter
    # moved, which is what happens on every publish.
    $script:pageMd = [System.IO.File]::ReadAllText((Join-Path $fixtures 'page.md'))
    $script:republishedMd = $script:pageMd -replace 'updated_at: .*', 'updated_at: 2026-10-02T09:00:00.0000000Z' -replace 'git_commit_id: .*', ('git_commit_id: ' + ('f' * 40))
    $script:changedMd = $script:pageMd -replace 'Accelerated networking is supported\.', 'Accelerated networking is required.'
    $script:tocJson = [System.IO.File]::ReadAllText((Join-Path $fixtures 'toc.json'))
    $script:site = 'https://learn.microsoft.com/en-us/'

    # A baseline in its own folder, with its own text store beside it - the
    # shape of docs/upstream-docs.json and docs/upstream-docs/.
    function Script:NewBaseline {
        param([object[]]$Pages = @(), [string]$Include = '-series$', [object[]]$ExtraFolders = @())
        $dir = Join-Path $script:temp ('bl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir
        $doc = [ordered]@{
            schemaVersion = 2
            site = $script:site
            textFolder = 'upstream-docs'
            checkedUtc = '2026-10-03T00:00:00Z'
            folders = @(@{
                    path = 'azure/virtual-machines/sizes/example'
                    toc = 'azure/virtual-machines/toc.json'
                    include = $Include
                    localDerivatives = @('engine:assessment-rules')
                    pages = @($Pages)
                }) + @($ExtraFolders)
        }
        $file = Join-Path $dir 'upstream-docs.json'
        $doc | ConvertTo-Json -Depth 8 | Set-Content $file
        $file
    }

    function Script:Md { param([string]$Content) [pscustomobject]@{ StatusCode = 200; ContentType = 'text/markdown; charset=utf-8'; Content = $Content; Location = $null } }
    function Script:Status { param([int]$Code, [string]$Location) [pscustomobject]@{ StatusCode = $Code; ContentType = 'text/html'; Content = '<html></html>'; Location = $Location } }

    # Answers by the page's last path segment; anything not named is a 404.
    function Script:Pages {
        param([hashtable]$Map)
        $captured = $Map
        {
            param($Url)
            $leaf = $Url.Substring($Url.LastIndexOf('/') + 1)
            if (-not $captured.ContainsKey($leaf)) {
                return [pscustomobject]@{ StatusCode = 404; ContentType = 'text/html'; Content = 'not found'; Location = $null }
            }
            $answer = $captured[$leaf]
            if ($answer -is [scriptblock]) { & $answer } else { $answer }
        }.GetNewClosure()
    }

    function Script:Toc {
        param([string]$Json)
        $captured = $Json
        { param($Url) $captured }.GetNewClosure()
    }
    # A toc that lists only the one pinned page, so a test sees no new page.
    $script:onlyA = Script:Toc '{"items":[{"toc_title":"A","href":"sizes/example/a-series"}]}'

    function Script:Sha256 {
        param([string]$Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($Text -replace "`r`n", "`n"))) | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
    }

    # Pinned to the fixture page by the tool's own re-pin, so the hash rule is
    # stated once (in the tool) and checked independently below.
    function Script:PinnedBaseline {
        $bl = Script:NewBaseline -Pages @(@{ name = 'a-series' })
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:pageMd) }) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $bl
    }
}

Describe 'UPST-3: the pinned docs baseline is well-formed' {
    It 'reads the public Learn pages, and starts with the folder that holds the migration guidance' {
        # DRIFT-2: Microsoft moved the guide on 2026-09-25 from migration/sizes
        # to sizes/lifecycle and renamed it "modernization". DOCS-DRIFT-LEARN-1
        # moved the watch from GitHub to the Learn path of the same folder.
        $script:baseline.schemaVersion | Should -Be 2
        $script:baseline.site | Should -Be 'https://learn.microsoft.com/en-us/'
        $script:baseline.folders[0].path | Should -Be 'azure/virtual-machines/sizes/lifecycle'
    }

    It 'has every page pinned with a sha256, and covers the whole documented journey' {
        $pages = @($script:baseline.folders[0].pages)
        @($pages).Count | Should -BeGreaterThan 5
        foreach ($pg in $pages) { $pg.sha256 | Should -Match '^[0-9a-f]{64}$' }
        # discover -> assess -> plan -> modernize -> validate is the journey the
        # tool implements; "migrate" became "modernize" in the 2026-09-25 rewrite.
        foreach ($stage in 'discover', 'assess', 'plan', 'modernize', 'validate', 'overview', 'faq') {
            @($pages.name) | Should -Contain "sizes-v6-v7-modernization-$stage"
        }
    }

    It 'every folder has pages pinned and a table of contents - a folder that matches nothing watches nothing' {
        foreach ($folder in @($script:baseline.folders)) {
            @($folder.pages).Count | Should -BeGreaterThan 0 -Because "$($folder.path) pins no page"
            foreach ($pg in @($folder.pages)) { $pg.sha256 | Should -Match '^[0-9a-f]{64}$' }
            $folder.toc | Should -Match '/toc\.json$'
            # A toc lists the pages under its own folder; a folder outside it
            # would never see a new page.
            $tocDir = $folder.toc.Substring(0, $folder.toc.LastIndexOf('/'))
            "$($folder.path)/" | Should -BeLike "$tocDir/*" -Because "$($folder.path) must sit under $($folder.toc)"
            # A page name is a Learn page, not a repository file.
            foreach ($pg in @($folder.pages)) { $pg.name | Should -Not -Match '\.(md|yml)$' }
        }
    }

    It 'every pinned page has its accepted text stored, and the text hashes to the pin' {
        # The text is what a change is shown against. A pin with no text, or a
        # text that is not the pinned one, would show the wrong difference.
        $count = 0
        $bad = foreach ($folder in @($script:baseline.folders)) {
            foreach ($pg in @($folder.pages)) {
                $count++
                $file = Join-Path $script:textRoot ("$($folder.path)/$($pg.name).md")
                if (-not (Test-Path -LiteralPath $file)) { "$($folder.path)/$($pg.name): no stored text"; continue }
                $text = [System.IO.File]::ReadAllText($file)
                if ((Script:Sha256 $text) -ne $pg.sha256) { "$($folder.path)/$($pg.name): stored text does not match the pin" }
            }
        }
        $count | Should -BeGreaterThan 80
        @($bad) -join '; ' | Should -BeNullOrEmpty
    }

    It 'and no stored text is left behind for a page that is no longer pinned' {
        $pinned = @(foreach ($folder in @($script:baseline.folders)) {
                foreach ($pg in @($folder.pages)) { [System.IO.Path]::GetFullPath((Join-Path $script:textRoot ("$($folder.path)/$($pg.name).md"))) }
            })
        $stored = @(Get-ChildItem $script:textRoot -Recurse -File -Filter '*.md' | ForEach-Object { $_.FullName })
        $stored.Count | Should -BeGreaterThan 80
        @($stored | Where-Object { $_ -notin $pinned }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'the stored text is the page only - no front matter, so no author or reviewer names' {
        # CLAUDE.md rule 13: Learn's front matter names the people who wrote
        # and reviewed each page. The page body is what is compared and stored.
        foreach ($file in Get-ChildItem $script:textRoot -Recurse -File -Filter '*.md') {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $text | Should -Not -Match '\A---' -Because "$($file.Name) must not keep the front matter"
            $text | Should -Not -Match '(?m)^(ms\.)?(author|reviewer|manager): ' -Because "$($file.Name) must not keep the front matter"
        }
    }

    It 'the stored text says whose it is, under what licence, and that it was changed' {
        # CC BY 4.0 asks for the creator, the source, the licence and a note of
        # any change - the front matter is removed.
        $notice = Get-Content (Join-Path $script:textRoot 'NOTICE.txt') -Raw
        $notice | Should -Match 'Microsoft'
        $notice | Should -Match 'creativecommons\.org/licenses/by/4\.0'
        $notice | Should -Match '(?s)front matter.*is removed'
        $notice | Should -Match 'https://learn\.microsoft\.com/en-us/'
    }

    It 'says which of our rules to re-read when a page moves' {
        @($script:baseline.folders[0].localDerivatives).Count | Should -BeGreaterThan 2
        @($script:baseline.folders[0].localDerivatives) -join ' ' | Should -Match 'CLAUDE\.md'
    }

    It 'every spec file a size page includes is listed with the pinned page that includes it' {
        # Learn has no page for an include: it serves the size page with the
        # include expanded in place (measured 2026-10-03 - an include's own URL
        # is a 404). So an include is watched THROUGH its size page.
        $includes = @(foreach ($folder in @($script:baseline.folders)) {
                if (-not $folder.PSObject.Properties['includes']) { continue }
                foreach ($inc in @($folder.includes)) { [pscustomobject]@{ Folder = $folder; Include = $inc } }
            })
        $includes.Count | Should -Be 14
        foreach ($i in $includes) {
            @($i.Folder.pages.name) | Should -Contain $i.Include.includedIn -Because "$($i.Include.name) is watched only through $($i.Include.includedIn)"
        }
    }
}

Describe 'DOCS-DRIFT-LEARN-1: the check never reads a GitHub documentation repository' {
    It 'the tool''s code names no GitHub address, and asks Learn for markdown' {
        $code = Get-VmfCodeOnly -Path $script:tool
        $code | Should -Not -Match 'github\.com|githubusercontent' -Because 'the repositories go private by the end of December 2026'
        $code | Should -Match 'text/markdown'
    }
}

Describe 'UPST-3: drift detection (no network)' {
    It 'stores the page after its front matter, and pins the sha256 of that text' {
        $bl = Script:PinnedBaseline
        $stored = Join-Path (Split-Path $bl -Parent) 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'example' 'a-series.md'
        Test-Path -LiteralPath $stored | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($stored)
        $text | Should -Match '\A# Example size series'
        $text | Should -Not -Match 'updated_at|git_commit_id|example-author'
        $text | Should -Match 'Accelerated networking is supported\.'
        $pin = (Get-Content $bl -Raw | ConvertFrom-Json).folders[0].pages[0]
        $pin.name | Should -Be 'a-series'
        $pin.sha256 | Should -Be (Script:Sha256 $text)
    }

    It 'reports nothing when every page matches' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:pageMd) }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 0
        $r.Checked | Should -Be 1
        @($r.Drifted).Count | Should -Be 0
    }

    It 'a republish that moves only the front matter is not a change' {
        # updated_at and git_commit_id change on every publish; comparing them
        # would report every page every day.
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:republishedMd) }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 0
    }

    It 'line endings do not count as a change' {
        $bl = Script:PinnedBaseline
        $crlf = $script:pageMd -replace "`r?`n", "`r`n"
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $crlf) }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 0
    }

    It 'reports a page whose content changed, and shows what changed against the stored text' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:changedMd) }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'content changed'
        $r.Drifted[0].diff | Should -Match '(?m)^- Accelerated networking is supported\.$'
        $r.Drifted[0].diff | Should -Match '(?m)^\+ Accelerated networking is required\.$'
        # Context, not the whole page: the line beside the change, not the title.
        $r.Drifted[0].diff | Should -Match '(?m)^  Premium storage is supported\.$'
        $r.Drifted[0].diff | Should -Not -Match 'Example size series'
    }

    It 'a change late in a long line shows the part that changed, not two equal starts' {
        # Learn writes a paragraph as one line; 1,265 stored lines are over the
        # width the diff shows.
        $para = 'Word ' * 80
        $old = $script:pageMd.Replace('Premium storage is supported.', $para + 'the old ending.')
        $new = $script:pageMd.Replace('Premium storage is supported.', $para + 'the new ending.')
        $bl = Script:NewBaseline -Pages @(@{ name = 'a-series' })
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $old) }) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $new) }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].diff | Should -Match '(?m)^- \.\.\. .*the old ending\.$'
        $r.Drifted[0].diff | Should -Match '(?m)^\+ \.\.\. .*the new ending\.$'
    }

    It 'two changes far apart are two hunks, each saying where it is' {
        $filler = (1..30 | ForEach-Object { "Unchanged line $_." }) -join "`n"
        $old = $script:pageMd.Replace('## Feature support', "First old line.`n$filler`n## Feature support")
        $new = $script:changedMd.Replace('## Feature support', "First new line.`n$filler`n## Feature support")
        $bl = Script:NewBaseline -Pages @(@{ name = 'a-series' })
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $old) }) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $new) }) -TocProvider $script:onlyA 6>$null
        $diff = $r.Drifted[0].diff
        @([regex]::Matches($diff, '(?m)^@@ line \d+ @@$')).Count | Should -Be 2
        $diff | Should -Match '(?m)^- First old line\.$'
        $diff | Should -Match '(?m)^- Accelerated networking is supported\.$'
        $diff | Should -Not -Match 'Unchanged line 15\.'
    }

    It 'a one-line page that changes is diffed by line, not by character' {
        $bl = Script:NewBaseline -Pages @(@{ name = 'a-series' })
        $one = "---`ntitle: x`n---`nOnly line before."
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $one) }) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $one.Replace('before', 'after')) }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].diff | Should -Be "@@ line 1 @@`n- Only line before.`n+ Only line after."
    }

    It 'a change too long for an issue is cut short and says so' {
        $bl = Script:PinnedBaseline
        $long = $script:pageMd + (-join (1..120 | ForEach-Object { "`nAdded line $_" }))
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $long) }) -TocProvider $script:onlyA 6>$null
        $lines = @($r.Drifted[0].diff -split "`n")
        $lines.Count | Should -BeLessOrEqual 41
        $lines[-1] | Should -Match 'more lines - read the page'
    }

    It 'reports a NEW page in the section''s table of contents - the signal a file-list watcher cannot give' {
        # The fixture toc writes hrefs every way Learn does: relative, with ./,
        # as a site path with a toc query, with a locale and an anchor, and as a
        # full address. Pages in another folder, on another site, in another
        # section or not matching the pattern are not this section's.
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:pageMd) }) -TocProvider (Script:Toc $script:tocJson) 6>$null
        $r.ExitCode | Should -Be 1
        $new = @($r.Drifted | Where-Object { $_.reason -match 'NEW PAGE' } | ForEach-Object { $_.path } | Sort-Object)
        $new | Should -Be @(
            'azure/virtual-machines/sizes/example/b-series',
            'azure/virtual-machines/sizes/example/d-series',
            'azure/virtual-machines/sizes/example/e-series',
            'azure/virtual-machines/sizes/example/f-series')
        @($r.Drifted).Count | Should -Be 4
    }

    It 'a pinned page the table of contents does not list is still read, not reported removed' {
        # Measured 2026-10-03: enable-nvme-faqs is served but not in the toc.
        $bl = Script:NewBaseline -Pages @(@{ name = 'a-series' }, @{ name = 'unlisted-series' })
        $live = Script:Pages @{ 'a-series' = (Script:Md $script:pageMd); 'unlisted-series' = (Script:Md $script:pageMd) }
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 0
        $r.Checked | Should -Be 2
    }

    It 'a table of contents that lists NONE of the pinned pages is UNREACHABLE - it may have changed shape' {
        # Read as "no new page", a toc Learn renamed or reshaped would hide
        # every new page from then on, and nothing would fail.
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:pageMd) }) -TocProvider (Script:Toc '{"entries":[{"href":"sizes/example/a-series"}]}') 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match 'lists none of the 1 pinned pages'
        $r.Checked | Should -Be 1
    }

    It 'one timeout or server error is read again before it counts' {
        $bl = Script:PinnedBaseline
        $calls = [System.Collections.Generic.List[string]]::new()
        $md = $script:pageMd
        $flaky = {
            param($Url)
            $calls.Add($Url)
            if ($calls.Count -eq 1) { [pscustomobject]@{ StatusCode = 503; ContentType = 'text/html'; Content = ''; Location = $null } }
            else { [pscustomobject]@{ StatusCode = 200; ContentType = 'text/markdown'; Content = $md; Location = $null } }
        }.GetNewClosure()
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $flaky -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 0
        $calls.Count | Should -Be 2
    }

    It 'when most pages change at once, each entry says to check Learn''s format first' {
        $names = 'a-series', 'b-series', 'c-series', 'd-series'
        $bl = Script:NewBaseline -Pages @($names | ForEach-Object { @{ name = $_ } })
        $before = @{}; $after = @{}
        foreach ($n in $names) { $before[$n] = Script:Md $script:pageMd; $after[$n] = Script:Md $script:changedMd }
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages $before) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages $after) -TocProvider $script:onlyA 6>$null
        @($r.Drifted).Count | Should -Be 4
        foreach ($d in $r.Drifted) { $d.reason | Should -Match '4 of 4 pages changed in this run' }
    }

    It 'and one changed page out of several says nothing of the kind' {
        $names = 'a-series', 'b-series', 'c-series', 'd-series'
        $bl = Script:NewBaseline -Pages @($names | ForEach-Object { @{ name = $_ } })
        $before = @{}
        foreach ($n in $names) { $before[$n] = Script:Md $script:pageMd }
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages $before) -TocProvider $script:onlyA -UpdateBaseline 6>$null | Out-Null
        $after = $before.Clone(); $after['b-series'] = Script:Md $script:changedMd
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages $after) -TocProvider $script:onlyA 6>$null
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Not -Match 'pages changed in this run'
    }

    It 'reports a REMOVED page - guidance we may still be relying on' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{}) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'REMOVED'
        $r.Drifted[0].kind | Should -Be 'changed'
    }

    It 'reports a MOVED page, and links to where it went' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Status 301 '/en-us/azure/virtual-machines/sizes/new-place/a-series') }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'MOVED'
        $r.Drifted[0].url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/new-place/a-series'
    }

    It 'a MOVED page with a relative address links to the address it resolves to' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Status 302 'a-series-renamed') }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/example/a-series-renamed'
    }

    It '-UpdateBaseline does NOT drop a MOVED page - its pin stays and the run fails' {
        # The new address may be outside every watched folder. Dropping the pin
        # would end the watch without a word.
        $bl = Script:PinnedBaseline
        $before = (Get-Content $bl -Raw | ConvertFrom-Json).folders[0].pages[0].sha256
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Status 301 '/en-us/azure/elsewhere/a-series') }) -TocProvider $script:onlyA -UpdateBaseline 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'MOVED'
        (Get-Content $bl -Raw | ConvertFrom-Json).folders[0].pages[0].sha256 | Should -Be $before
        Test-Path -LiteralPath (Join-Path (Split-Path $bl -Parent) 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'example' 'a-series.md') | Should -BeTrue
    }

    It 'a page it cannot read FAILS - it never reports "unchanged" on no evidence' {
        # The drill lesson, applied here: a check that cannot reach its evidence
        # must fail, not pass quietly.
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = { throw 'No such host is known.' } }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'fetch failed'
    }

    It '-UpdateBaseline re-pins to what is live, stores the new text, adds new pages and drops removed ones' {
        $bl = Script:PinnedBaseline
        $dir = Split-Path $bl -Parent
        # A second pinned page that will be gone, with its stored text.
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $doc.folders[0].pages = @($doc.folders[0].pages) + [pscustomobject]@{ name = 'z-series'; sha256 = ('0' * 64) }
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $gone = Join-Path $dir 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'example' 'z-series.md'
        Set-Content -LiteralPath $gone -Value 'old text'

        $live = Script:Pages @{
            'a-series' = (Script:Md $script:changedMd)
            'b-series' = (Script:Md $script:pageMd); 'd-series' = (Script:Md $script:pageMd)
            'e-series' = (Script:Md $script:pageMd); 'f-series' = (Script:Md $script:pageMd)
        }
        & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider (Script:Toc $script:tocJson) -UpdateBaseline 6>$null | Out-Null
        $after = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider (Script:Toc $script:tocJson) 6>$null
        $after.ExitCode | Should -Be 0
        $repinned = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        @($repinned.folders[0].pages.name) | Should -Be @('a-series', 'b-series', 'd-series', 'e-series', 'f-series')
        Test-Path -LiteralPath $gone | Should -BeFalse -Because 'a removal must remove its stored text too'
        [System.IO.File]::ReadAllText((Join-Path $dir 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'example' 'a-series.md')) |
            Should -Match 'Accelerated networking is required\.'
    }

    It '-UpdateBaseline says every page it added, re-pinned and removed' {
        $bl = Script:PinnedBaseline
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $doc.folders[0].pages = @($doc.folders[0].pages) + [pscustomobject]@{ name = 'z-series'; sha256 = ('0' * 64) }
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $live = Script:Pages @{
            'a-series' = (Script:Md $script:changedMd)
            'b-series' = (Script:Md $script:pageMd); 'd-series' = (Script:Md $script:pageMd)
            'e-series' = (Script:Md $script:pageMd); 'f-series' = (Script:Md $script:pageMd)
        }
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider (Script:Toc $script:tocJson) -UpdateBaseline 6>$null
        @($r.Changes | Where-Object { $_ -match '^re-pinned .*/a-series$' }).Count | Should -Be 1
        @($r.Changes | Where-Object { $_ -match '^added .*/b-series$' }).Count | Should -Be 1
        @($r.Changes | Where-Object { $_ -match '^removed .*/z-series' }).Count | Should -Be 1
        @($r.Changes).Count | Should -Be 6
    }

    It '-UpdateBaseline keeps the old pin of a page it could not read, and fails' {
        $bl = Script:PinnedBaseline
        $before = (Get-Content $bl -Raw | ConvertFrom-Json).folders[0].pages[0].sha256
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Status 503) }) -TocProvider $script:onlyA -UpdateBaseline 6>$null
        $r.ExitCode | Should -Be 1
        (Get-Content $bl -Raw | ConvertFrom-Json).folders[0].pages[0].sha256 | Should -Be $before
    }

    It 'refuses a version 1 baseline - the GitHub shape - rather than reading it wrong' {
        $file = Join-Path $script:temp 'v1.json'
        @{ schemaVersion = 1; repo = 'MicrosoftDocs/azure-compute-docs'; folders = @() } | ConvertTo-Json | Set-Content $file
        { & $script:tool -RetryDelaySeconds 0 -BaselinePath $file -PageProvider (Script:Pages @{}) -TocProvider $script:onlyA } | Should -Throw '*schemaVersion*'
    }
}

# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
# There this runs on the public workflow (public/.github), once there is one.
Describe 'UPST-3: it runs on the schedule with the script check' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {
    BeforeAll { $script:wf = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'upstream-drift.yml') -Raw }

    It 'the daily workflow checks the docs too' {
        $script:wf | Should -Match 'Test-DocsDrift\.ps1'
    }

    It 'and a docs failure is not swallowed by the script check passing' {
        # Both results have to reach the exit code, or a red docs check hides
        # behind a green script check.
        $script:wf | Should -Match '(?s)Test-UpstreamDrift\.ps1.*Test-DocsDrift\.ps1'
        $script:wf | Should -Match 'docsResult|\$docs'
    }

    It 'the issue shows what changed on a page, in a diff block' {
        $script:wf | Should -Match '\$d\.diff'
        $script:wf | Should -Match '\$\{fence\}diff'
    }

    It 'and an entry with no history link still gets its page link' {
        # Learn has no history page. The other two checks still give one, so
        # the line must work with and without it.
        $script:wf | Should -Match '(?s)if \(\$d\.changesUrl\).*\[read the page\]\(\$\(\$d\.url\)\)'
    }

    It 'and an issue too long for GitHub drops the diffs rather than failing' {
        # GitHub refuses an issue body over 65,536 characters; a refused issue
        # is a lost report.
        $script:wf | Should -Match '60000'
    }
}

# The report step RUN, not read: its script is lifted out of the workflow and
# run against stand-in checks, and the issue text it writes is measured.
# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
# There this runs on the public workflow (public/.github), once there is one.
Describe 'DOCS-DRIFT-LEARN-1: the drift issue the workflow writes' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {
    BeforeAll {
        $wf = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'upstream-drift.yml') -Raw
        $m = [regex]::Match($wf, '(?ms)^\s+id: check\s*$.*?^\s+run: \|\s*$(?<body>.*?)^\s{6}- name:')
        $script:checkStep = (($m.Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_.TrimStart() } }) -join "`n"

        function Script:RunReport {
            param($Docs)
            $dir = Join-Path $script:temp ('wf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $dir 'tools')
            $quiet = '[pscustomobject]@{ Checked = 4; Drifted = @(); ExitCode = 0 }'
            Set-Content (Join-Path $dir 'tools' 'Test-UpstreamDrift.ps1') $quiet
            Set-Content (Join-Path $dir 'tools' 'Test-PolicyDrift.ps1') $quiet
            # BICEP-PIN-1: the fourth check in the same step.
            Set-Content (Join-Path $dir 'tools' 'Test-BicepPinDrift.ps1') $quiet
            # DEPS-CURRENT-1: the fifth.
            Set-Content (Join-Path $dir 'tools' 'Test-VmfPartPinDrift.ps1') $quiet
            $Docs | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'docs.json')
            Set-Content (Join-Path $dir 'tools' 'Test-DocsDrift.ps1') '$r = Get-Content (Join-Path $PSScriptRoot ".." "docs.json") -Raw | ConvertFrom-Json; [pscustomobject]@{ Checked = $r.Checked; Drifted = @($r.Drifted); ExitCode = 1 }'
            Set-Content (Join-Path $dir 'step.ps1') $script:checkStep
            $saved = @{ out = $env:GITHUB_OUTPUT; sum = $env:GITHUB_STEP_SUMMARY }
            $env:GITHUB_OUTPUT = Join-Path $dir 'output.txt'
            $env:GITHUB_STEP_SUMMARY = Join-Path $dir 'summary.md'
            Push-Location $dir
            try { & (Join-Path $dir 'step.ps1') 6>$null | Out-Null }
            finally {
                Pop-Location
                $env:GITHUB_OUTPUT = $saved.out
                $env:GITHUB_STEP_SUMMARY = $saved.sum
            }
            [pscustomobject]@{
                Issue   = Get-Content (Join-Path $dir 'drift-report.md') -Raw
                Summary = Get-Content (Join-Path $dir 'summary.md') -Raw
                Output  = Get-Content (Join-Path $dir 'output.txt') -Raw
            }
        }
    }

    It 'lifted the step''s script, so the tests below run real code' {
        $script:checkStep | Should -Match 'Test-DocsDrift\.ps1'
        $script:checkStep | Should -Match 'function Add-Section'
    }

    It 'a changed Learn page gets its page link, its rules and what changed - and no dead history link' {
        $docs = @{ Checked = 89; Drifted = @(@{
                    path = 'azure/virtual-machines/sizes/example/a-series'; kind = 'changed'; reason = 'content changed (baseline 111..., now 222...)'
                    url = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/example/a-series'
                    localDerivatives = @('engine:planner')
                    diff = "@@ line 3 @@`n  context`n- Accelerated networking is supported.`n+ Accelerated networking is required."
                }) }
        $r = Script:RunReport $docs
        $r.Issue | Should -Match ([regex]::Escape('[read the page](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/example/a-series)'))
        $r.Issue | Should -Not -Match 'see what changed\]\(\)'
        $r.Issue | Should -Match 're-evaluate: engine:planner'
        $r.Issue | Should -Match '(?s)```diff.*- Accelerated networking is supported\..*\+ Accelerated networking is required\..*```'
        $r.Output | Should -Match 'changed=1'
    }

    It 'a code fence quoted from the page does not close the diff block' {
        # 93 stored lines are a bare fence; one in the context of a change
        # would end the block early and leave the details open.
        $fence3 = [string]::new([char]96, 3)
        $docs = @{ Checked = 89; Drifted = @(@{
                    path = 'azure/virtual-machines/nvme-linux'; kind = 'changed'; reason = 'content changed'
                    url = 'https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-linux'
                    localDerivatives = @('src/guest/linux')
                    diff = "@@ line 9 @@`n  $fence3`n- old command`n+ new command`n  $fence3"
                }) }
        $r = Script:RunReport $docs
        $r.Issue | Should -Match '(?m)^  ````diff$'
        $r.Issue | Should -Match '(?s)````diff.*- old command.*\+ new command.*\n  ````\n  </details>'
    }

    It 'every page reported at once still fits in one issue, and says where the rest is' {
        # Each entry carries its folder's rules, about 1,000 characters for a
        # size folder, so 89 entries pass GitHub's limit even with no diffs.
        $rules = @('a long rule name ' * 60)
        $docs = @{ Checked = 89; Drifted = @(1..89 | ForEach-Object {
                    @{ path = "azure/virtual-machines/sizes/example/p$_-series"; kind = 'changed'; reason = 'content changed'
                       url = "https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/example/p$_-series"; localDerivatives = $rules }
                }) }
        $r = Script:RunReport $docs
        $r.Summary.Length | Should -BeGreaterThan 65536 -Because 'the test needs a report over the limit'
        $r.Issue.Length | Should -BeLessThan 65536
        $r.Issue | Should -Match 'The report was cut here'
    }

    It 'a report too long for one issue keeps the diffs in the run summary only' {
        $big = (1..900 | ForEach-Object { "+ An added line of a long rewrite, number $_, written out to fill the report." }) -join "`n"
        $docs = @{ Checked = 89; Drifted = @(@{
                    path = 'azure/virtual-machines/sizes/example/a-series'; kind = 'changed'; reason = 'content changed'
                    url = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/example/a-series'
                    localDerivatives = @('engine:planner'); diff = $big
                }) }
        $r = Script:RunReport $docs
        $r.Issue.Length | Should -BeLessThan 60000
        $r.Issue | Should -Not -Match '```diff'
        $r.Issue | Should -Match 'too long for one issue'
        $r.Issue | Should -Match ([regex]::Escape('[read the page]('))
        $r.Summary | Should -Match '```diff'
    }
}

# UPST-4: "I could not look" and "it changed" are different facts. Both must
# fail the run; only one of them means Microsoft moved. Reporting the first as
# the second is a check announcing a result it never measured - and it trains
# the reader to ignore the next real one.
Describe 'DOCS-DRIFT: the report says what was measured, not what was assumed' {
    It 'marks a page it could not read as UNREACHABLE, not as a change' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Status 429) }) -TocProvider $script:onlyA 6>$null
        $r.ExitCode | Should -Be 1 -Because 'it still must not pass on no evidence'
        $r.Drifted[0].kind | Should -Be 'unreachable'
        @($r.Drifted | Where-Object { $_.kind -eq 'changed' }).Count | Should -Be 0
    }

    It 'a page that comes back as HTML is UNREACHABLE - it is never hashed as a change' {
        # The day Learn stops answering in markdown, hashing the HTML would
        # report all 89 pages as changed.
        $bl = Script:PinnedBaseline
        $html = [pscustomobject]@{ StatusCode = 200; ContentType = 'text/html; charset=utf-8'; Content = '<!DOCTYPE html><html></html>'; Location = $null }
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = $html }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match 'markdown'
    }

    It 'and so is a body that looks like markdown but is not served as markdown' {
        # The content type is what Learn promises; a body is only compared
        # when the promise was made.
        $bl = Script:PinnedBaseline
        $plain = [pscustomobject]@{ StatusCode = 200; ContentType = 'text/html; charset=utf-8'; Content = $script:changedMd; Location = $null }
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = $plain }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].kind | Should -Be 'unreachable'
    }

    It 'and so is markdown without the front matter it always carries - a shape it does not know is not compared' {
        $bl = Script:PinnedBaseline
        $bare = $script:changedMd.Substring($script:changedMd.IndexOf('# Example'))
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $bare) }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].kind | Should -Be 'unreachable'
    }

    It 'a table of contents it cannot read is UNREACHABLE, and the pages are still compared' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:changedMd) }) -TocProvider { param($Url) throw '403' } 6>$null
        $r.ExitCode | Should -Be 1
        @($r.Drifted | Where-Object { $_.kind -eq 'unreachable' -and $_.reason -match 'table of contents' }).Count | Should -Be 1
        @($r.Drifted | Where-Object { $_.kind -eq 'changed' -and $_.reason -match 'content changed' }).Count | Should -Be 1
    }

    It 'every drift entry carries a kind, so nothing lands in the report unclassified' {
        # An entry with no kind would be counted as a CHANGE by the workflow's
        # filter, which is the false alarm coming back by omission.
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:changedMd) }) -TocProvider (Script:Toc $script:tocJson) 6>$null
        @($r.Drifted).Count | Should -BeGreaterThan 1
        foreach ($d in $r.Drifted) { $d.kind | Should -BeIn @('changed', 'unreachable') }
    }
}

# REPORT-1, 2026-09-19: a report that names a file and does not link to it makes
# the reader search for the change before they can judge it. Nine changed pages
# sat unread; the report is the product of this check, so it carries the way in.
Describe 'REPORT-1: every drift entry can be opened' {
    It 'a changed page links to its Learn page' {
        $bl = Script:PinnedBaseline
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{ 'a-series' = (Script:Md $script:changedMd) }) -TocProvider $script:onlyA 6>$null
        $r.Drifted[0].url | Should -Be "https://learn.microsoft.com/en-us/$($r.Drifted[0].path)"
    }

    It 'and so does a new page, a removed page, and one that could not be read' {
        # The links must be on EVERY emit site.
        $bl = Script:PinnedBaseline
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $doc.folders[0].pages = @($doc.folders[0].pages) +
            [pscustomobject]@{ name = 'gone-series'; sha256 = ('0' * 64) } +
            [pscustomobject]@{ name = 'down-series'; sha256 = ('0' * 64) }
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $live = Script:Pages @{ 'a-series' = (Script:Md $script:changedMd); 'down-series' = { throw 'timeout' } }
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $live -TocProvider (Script:Toc $script:tocJson) 6>$null
        $all = @($r.Drifted)
        # changed, new (4), removed and unreachable - every emit site.
        @($all | Where-Object { $_.reason -match 'content changed' }).Count | Should -Be 1
        @($all | Where-Object { $_.reason -match 'NEW PAGE' }).Count | Should -Be 4
        @($all | Where-Object { $_.reason -match 'REMOVED' }).Count | Should -Be 1
        @($all | Where-Object { $_.kind -eq 'unreachable' }).Count | Should -Be 1
        foreach ($d in $all) {
            $d.url | Should -BeLike 'https://learn.microsoft.com/en-us/*' -Because "$($d.path) ($($d.kind)) has to be reachable"
            $d.url | Should -BeLike "*$($d.path)"
            $d.url | Should -Not -Match 'github' -Because 'a GitHub link 404s once the repository is private'
        }
    }
}

Describe 'DRIFT-2: folders in different Learn sections read their own table of contents' {
    It 'reads each section''s toc once, and finds a new page in either' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $other = @{
            path = 'azure/virtual-network'; toc = 'azure/virtual-network/toc.json'; include = '^accelerated-'
            localDerivatives = @('y'); pages = @()
        }
        $second = @{
            path = 'azure/virtual-machines/sizes/other'; toc = 'azure/virtual-machines/toc.json'; include = '-series$'
            localDerivatives = @('z'); pages = @()
        }
        $bl = Script:NewBaseline -Pages @() -ExtraFolders @($other, $second)
        $vmToc = $script:tocJson
        $toc = {
            param($Url)
            $calls.Add($Url)
            if ($Url -like '*virtual-network/toc.json') { '{"items":[{"href":"accelerated-networking-new"}]}' } else { $vmToc }
        }.GetNewClosure()
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:Pages @{}) -TocProvider $toc 6>$null
        @($calls | Sort-Object) | Should -Be @(
            'https://learn.microsoft.com/en-us/azure/virtual-machines/toc.json',
            'https://learn.microsoft.com/en-us/azure/virtual-network/toc.json')
        @($r.Drifted.path) | Should -Contain 'azure/virtual-network/accelerated-networking-new'
        @($r.Drifted.path) | Should -Contain 'azure/virtual-machines/sizes/other/c-series'
    }
}

# DRIFT-2, 2026-09-26. Two blind spots, both measured the same day:
#   - the MANA table our rules rest on lives in another documentation set, and
#     the watcher could read one only. driver-floors.json said the page was
#     watched; it was not, and Microsoft changed it on 2026-09-25;
#   - Microsoft moved the whole v6/v7 guide the same day, and the watcher went
#     on watching a folder that now holds only images.
# THE CLASS: every Microsoft page the product's data cites is either watched or
# named as not watched, with the reason. A new citation must choose.
Describe 'DRIFT-2: every Microsoft page the product cites is watched, or excused by name' {
    BeforeAll {
        $dataDir = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'
        $script:cited = @(Get-ChildItem $dataDir -Filter '*.json' | ForEach-Object {
                $file = $_.Name
                [regex]::Matches((Get-Content $_.FullName -Raw), 'https://learn\.microsoft\.com/[^\s"''<>)\]]+') | ForEach-Object {
                    [pscustomobject]@{ Url = (($_.Value -replace '[#?].*$', '') -replace '/en-us/', '/'); File = $file }
                }
            } | Sort-Object Url -Unique)
        $script:excused = @($script:baseline.notWatched)
        # A citation is a Learn path; a watched page is a folder path plus a name.
        $script:isWatched = {
            param([string]$Url)
            $rest = ($Url -replace '^https://learn\.microsoft\.com/', '').TrimEnd('/')
            if (-not $rest.Contains('/')) { return $false }
            $dir = $rest.Substring(0, $rest.LastIndexOf('/'))
            $leaf = $rest.Substring($rest.LastIndexOf('/') + 1)
            foreach ($folder in @($script:baseline.folders)) {
                if ($folder.path -eq $dir -and @($folder.pages.name) -contains $leaf) { return $true }
            }
            $false
        }
    }

    It 'the data cites Microsoft pages, so this cannot pass by finding none' {
        $script:cited.Count | Should -BeGreaterThan 10
    }

    It 'every cited page is watched, or excused with a reason' {
        $unwatched = foreach ($c in $script:cited) {
            if (& $script:isWatched $c.Url) { continue }
            if ($script:excused | Where-Object { $_.url -eq $c.Url -and $_.reason }) { continue }
            "$($c.Url) (cited in $($c.File))"
        }
        @($unwatched) -join '; ' | Should -BeNullOrEmpty
    }

    It 'an excuse is for a page still cited - no stale excuses' {
        foreach ($e in $script:excused) {
            @($script:cited.Url) | Should -Contain $e.url -Because 'an excuse for a page nothing cites hides nothing, and misleads'
        }
    }

    It 'the MANA table - the page that went unwatched - is watched' {
        & $script:isWatched 'https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview' | Should -BeTrue
    }
}

# DRIFT-VERSIONED-1, 2026-11-07. Learn serves every Azure CycleCloud page at a
# versioned address and redirects the plain address to it (measured: the plain
# tag-nodes address answers 301 to ?view=cyclecloud-8; an unknown version
# answers 301 to cyclecloud-8 with viewFallbackFrom). The check does not follow
# a redirect, on purpose, so until this it reported the page as moved and the
# tags a rule rests on were not watched. A folder now names its Learn version.
Describe 'DRIFT-VERSIONED-1: a folder watched at a Learn version' {
    BeforeAll {
        $script:ccSite = 'https://learn.microsoft.com/en-us/'
        $script:ccFolder = 'azure/cyclecloud/how-to'
        $script:ccPlain = "$($script:ccSite)$($script:ccFolder)/tag-nodes"
        $script:ccToc = '{"items":[{"toc_title":"Tag nodes","href":"how-to/tag-nodes"}]}'

        function Script:NewVersionedBaseline {
            param([string]$View, [object[]]$Pages = @(@{ name = 'tag-nodes' }))
            $dir = Join-Path $script:temp ('blv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $dir
            $folder = [ordered]@{
                path = $script:ccFolder
                toc = 'azure/cyclecloud/toc.json'
                include = '^tag-nodes$'
                localDerivatives = @('BATCH-CYCLECLOUD-SIGNAL-1')
                pages = @($Pages)
            }
            if ($View) { $folder.view = $View }
            $doc = [ordered]@{
                schemaVersion = 2; site = $script:ccSite; textFolder = 'upstream-docs'
                checkedUtc = '2026-11-07T00:00:00Z'; folders = @($folder)
            }
            $file = Join-Path $dir 'upstream-docs.json'
            $doc | ConvertTo-Json -Depth 8 | Set-Content $file
            $file
        }

        # Learn as measured: the plain address redirects to cyclecloud-8, the
        # cyclecloud-8 address serves the page, and any other version redirects
        # to cyclecloud-8 with viewFallbackFrom. Every URL asked is recorded.
        function Script:LearnVersioned {
            param([string]$Markdown, [System.Collections.Generic.List[string]]$Calls)
            $md = $Markdown; $seen = $Calls; $plain = $script:ccPlain
            {
                param($Url)
                # $null -ne: an empty list is false in an if.
                if ($null -ne $seen) { $seen.Add($Url) }
                if ($Url -eq $plain) {
                    return [pscustomobject]@{ StatusCode = 301; ContentType = ''; Content = ''; Location = '/en-us/azure/cyclecloud/how-to/tag-nodes?view=cyclecloud-8' }
                }
                if ($Url -eq "$($plain)?view=cyclecloud-8") {
                    return [pscustomobject]@{ StatusCode = 200; ContentType = 'text/markdown; charset=utf-8'; Content = $md; Location = $null }
                }
                if ($Url -like "$($plain)?view=*") {
                    $asked = $Url.Substring($Url.IndexOf('=') + 1)
                    return [pscustomobject]@{ StatusCode = 301; ContentType = ''; Content = ''; Location = "/en-us/azure/cyclecloud/how-to/tag-nodes?view=cyclecloud-8&viewFallbackFrom=$asked" }
                }
                [pscustomobject]@{ StatusCode = 404; ContentType = 'text/html'; Content = 'not found'; Location = $null }
            }.GetNewClosure()
        }

        function Script:PinnedVersioned {
            $bl = Script:NewVersionedBaseline -View 'cyclecloud-8'
            & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider (Script:Toc $script:ccToc) -UpdateBaseline 6>$null | Out-Null
            $bl
        }
    }

    It 'watched at its version, the page is read at the versioned address and compared' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $bl = Script:PinnedVersioned
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd $calls) -TocProvider (Script:Toc $script:ccToc) 6>$null
        @($r.Drifted | ForEach-Object { "$($_.path): $($_.reason)" }) -join '; ' | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 0
        $r.Checked | Should -Be 1
        @($calls) | Should -Be @("$($script:ccPlain)?view=cyclecloud-8")
    }

    It 'with no version, the same page is still a MOVED page' {
        $bl = Script:NewVersionedBaseline -View $null -Pages @(@{ name = 'tag-nodes'; sha256 = ('0' * 64) })
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider (Script:Toc $script:ccToc) 6>$null
        $r.ExitCode | Should -Be 1
        $r.Checked | Should -Be 0
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'PAGE MOVED'
        # A folder with no version watches no version, so none is named.
        $r.Drifted[0].reason | Should -Not -Match 'another version'
        $r.Drifted[0].url | Should -Be "$($script:ccPlain)?view=cyclecloud-8"
    }

    It 'a redirect from the watched version to another version is drift, and says it is another version' {
        # The day Microsoft retires cyclecloud-8, Learn sends its address to the
        # next version. That is a page the rule was not read from.
        $bl = Script:PinnedVersioned
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $doc.folders[0].view = 'cyclecloud-7'
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider (Script:Toc $script:ccToc) 6>$null
        $r.ExitCode | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'PAGE MOVED'
        $r.Drifted[0].reason | Should -Match 'another version than view=cyclecloud-7'
        $r.Drifted[0].url | Should -Be "$($script:ccPlain)?view=cyclecloud-8&viewFallbackFrom=cyclecloud-7"
    }

    It 'and a redirect from the version to another page is a MOVED page, not another version' {
        $bl = Script:PinnedVersioned
        $moved = { param($Url) [pscustomobject]@{ StatusCode = 301; ContentType = ''; Content = ''; Location = '/en-us/azure/cyclecloud/how-to/tags?view=cyclecloud-8' } }
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider $moved -TocProvider (Script:Toc $script:ccToc) 6>$null
        $r.Drifted[0].reason | Should -Match 'PAGE MOVED'
        $r.Drifted[0].reason | Should -Not -Match 'another version'
    }

    It 'reads the table of contents at the same version' {
        # Measured 2026-11-07: the CycleCloud toc.json also answers 301 at the
        # plain address. A toc of another version could list other pages.
        $tocCalls = [System.Collections.Generic.List[string]]::new()
        $json = $script:ccToc
        $toc = { param($Url) $tocCalls.Add($Url); $json }.GetNewClosure()
        $bl = Script:PinnedVersioned
        $null = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider $toc 6>$null
        @($tocCalls) | Should -Be @("$($script:ccSite)azure/cyclecloud/toc.json?view=cyclecloud-8")
    }

    It 'a versioned toc and a plain toc of the same path are read and kept apart' {
        $tocCalls = [System.Collections.Generic.List[string]]::new()
        $json = $script:ccToc
        $toc = { param($Url) $tocCalls.Add($Url); $json }.GetNewClosure()
        $bl = Script:PinnedVersioned
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $plainFolder = [pscustomobject]@{ path = 'azure/cyclecloud/concepts'; toc = 'azure/cyclecloud/toc.json'; include = '^x$'; localDerivatives = @('y'); pages = @() }
        $doc.folders = @($doc.folders) + $plainFolder
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $null = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider $toc 6>$null
        @($tocCalls | Sort-Object) | Should -Be @("$($script:ccSite)azure/cyclecloud/toc.json", "$($script:ccSite)azure/cyclecloud/toc.json?view=cyclecloud-8")
    }

    It 'every report link of a versioned folder carries the version' {
        $bl = Script:PinnedVersioned
        $changed = $script:pageMd -replace 'Accelerated networking is supported\.', 'Accelerated networking is required.'
        $twoPages = Script:Toc '{"items":[{"href":"how-to/tag-nodes"},{"href":"how-to/tag-nodes-new"}]}'
        $doc = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $doc.folders[0].include = '^tag-nodes'
        $doc | ConvertTo-Json -Depth 8 | Set-Content $bl
        $r = & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $changed) -TocProvider $twoPages 6>$null
        $byPath = @{}; foreach ($d in $r.Drifted) { $byPath[$d.path] = $d }
        $byPath["$($script:ccFolder)/tag-nodes"].reason | Should -Match 'content changed'
        $byPath["$($script:ccFolder)/tag-nodes"].url | Should -Be "$($script:ccPlain)?view=cyclecloud-8"
        $byPath["$($script:ccFolder)/tag-nodes-new"].reason | Should -Match 'NEW PAGE'
        $byPath["$($script:ccFolder)/tag-nodes-new"].url | Should -Be "$($script:ccPlain)-new?view=cyclecloud-8"
    }

    It '-UpdateBaseline stores the text at the page''s Learn path, with no version in the file name' {
        $bl = Script:PinnedVersioned
        $stored = Join-Path (Split-Path $bl -Parent) 'upstream-docs' 'azure' 'cyclecloud' 'how-to' 'tag-nodes.md'
        Test-Path -LiteralPath $stored | Should -BeTrue
        $pin = (Get-Content $bl -Raw | ConvertFrom-Json).folders[0]
        $pin.view | Should -Be 'cyclecloud-8'
        $pin.pages[0].sha256 | Should -Be (Script:Sha256 ([System.IO.File]::ReadAllText($stored)))
    }

    It 'refuses a version that is not a plain Learn version name - it goes into every address' {
        foreach ($bad in 'cyclecloud-8&x=1', 'cyclecloud 8', 'cyclecloud-8#top', '../x', 'CycleCloud-8') {
            $bl = Script:NewVersionedBaseline -View $bad
            { & $script:tool -RetryDelaySeconds 0 -BaselinePath $bl -PageProvider (Script:LearnVersioned $script:pageMd) -TocProvider (Script:Toc $script:ccToc) 6>$null } |
                Should -Throw '*view*' -Because "'$bad' is not a version name"
        }
    }

    It 'the real baseline watches the CycleCloud tag page at cyclecloud-8, and no longer excuses it' {
        $folder = @($script:baseline.folders | Where-Object { $_.path -eq 'azure/cyclecloud/how-to' })
        $folder.Count | Should -Be 1
        $folder[0].view | Should -Be 'cyclecloud-8'
        @($folder[0].pages.name) | Should -Contain 'tag-nodes'
        @($folder[0].localDerivatives) -join ' ' | Should -Match 'BATCH-CYCLECLOUD-SIGNAL-1'
        @($script:baseline.notWatched.url) | Should -Not -Contain 'https://learn.microsoft.com/azure/cyclecloud/how-to/tag-nodes'
        $text = [System.IO.File]::ReadAllText((Join-Path $script:textRoot 'azure' 'cyclecloud' 'how-to' 'tag-nodes.md'))
        foreach ($tag in 'CycleCloudCluster', 'CycleCloudNodeArray', 'ClusterId') { $text | Should -Match $tag }
    }

    It 'every version named in the real baseline is a plain Learn version name' {
        foreach ($folder in @($script:baseline.folders)) {
            if ($folder.PSObject.Properties['view']) { [string]$folder.view | Should -Match '^[a-z0-9][a-z0-9.-]*$' }
        }
    }
}

AfterAll {
    # TEMP-LITTER-1. A throw here fails the container, which is the point: a
    # removal nobody checks is how four thousand folders accumulated.
    Remove-VmfTestTemp
}
