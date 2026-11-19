<#
.SYNOPSIS
    UPST-3: watch Microsoft's v6/v7 migration DOCUMENTATION for changes.

.DESCRIPTION
    UPST-1 watches upstream SCRIPTS. This watches the prose - the pages the whole
    tool is built from. Nearly every hard-won fact in CLAUDE.md started as a line
    in these docs (the temp-disk categories, the OS floors, the hibernation
    rules, the quota-family quirk), so a change there can invalidate a rule the
    engine enforces, with nothing in the code moving at all.

    DOCS-DRIFT-LEARN-1 (2026-10-03): it reads the PUBLIC LEARN PAGES, not the
    GitHub documentation repositories. Microsoft announced on 2026-09-23 that it
    is making most of those repositories private by the end of December 2026,
    repository by repository and with no date for each. Until 2026-10-03 this
    listed folders through the GitHub contents API and compared blob shas; on
    the day a repository went private that listing would fail every day and the
    check would stop watching.

    How it works now, and why:

    1. Each watched page is read from learn.microsoft.com with
       `Accept: text/markdown`, which returns the page as markdown with its
       includes already expanded. The front matter at the top changes on every
       publish (`updated_at`, `git_commit_id`), so only the text AFTER it is
       compared. A page that does not come back as markdown is UNREACHABLE,
       never "changed" - an HTML page hashed as text would report every page as
       changed on the day Learn stops answering in markdown.

    2. The accepted text of every page is KEPT IN THE REPOSITORY next to the
       baseline (`docs/upstream-docs/<learn path>.md`), and the baseline pins
       the sha256 of that text. GitHub's history said what changed; Learn has
       no history, so the stored text is what a change is compared with, and
       the report shows the difference.

    3. A section is still watched as a SECTION, not as a list of files. A new
       page appearing is the signal most worth having - Microsoft added
       `scsi-to-nvme-migration.md` and the capacity-limitations page alongside
       the original five, and a file-list watcher would never have said so.
       Each section names the table of contents (`toc.json`) that lists its
       pages; a page in the section's folder that matches its pattern and is
       not pinned is a NEW page. A page Learn no longer serves (404) is a
       REMOVED page, and one that redirects is a MOVED page. Both are changes.

    4. DRIFT-VERSIONED-1: a folder may name a Learn version (`view`, for
       example `cyclecloud-8`). Learn serves every Azure CycleCloud page at a
       versioned address and redirects the plain address to it, so a folder
       with no version would report its page as MOVED every day. Each page and
       the table of contents of such a folder are read at `?view=<version>`;
       a redirect from there - to another version or to another page - is
       still a MOVED page. The stored text keeps the page's Learn path, with no
       version in the file name.

    It reads public pages anonymously, so it needs no token and no Azure.

.PARAMETER PageProvider
    Overrides the page fetch, for tests. Called with the page URL; returns an
    object with .StatusCode, .ContentType, .Content and .Location (the redirect
    target, if any). Redirects are NOT followed - a moved page is drift.

.PARAMETER TocProvider
    Overrides the table-of-contents fetch, for tests. Called with the toc.json
    URL; returns the JSON text.

.PARAMETER UpdateBaseline
    Re-pins every page that was read, writes its text into the store, adds new
    pages and removes the pins and stored text of removed pages. Only after the
    change has been read and evaluated - re-pinning first only silences it.
    It prints every page it adds, re-pins or removes. A MOVED page is NOT
    re-pinned: its pin stays and the run fails, so the watch is moved on
    purpose, by editing the baseline, rather than dropped without a word.

.PARAMETER RetryDelaySeconds
    The wait before the one retry of a page that timed out, was refused (429)
    or failed on the server (5xx). Tests pass 0.
#>
param(
    [string]$BaselinePath = (Join-Path $PSScriptRoot '..' 'docs' 'upstream-docs.json'),
    [scriptblock]$PageProvider,
    [scriptblock]$TocProvider,
    [switch]$UpdateBaseline,
    [int]$RetryDelaySeconds = 5
)

$ErrorActionPreference = 'Stop'
$BaselinePath = [System.IO.Path]::GetFullPath($BaselinePath)
$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json -Depth 8
if ([int]$baseline.schemaVersion -ne 2) {
    throw "upstream-docs.json schemaVersion $($baseline.schemaVersion) is not 2. Version 1 watched the GitHub documentation repositories (DOCS-DRIFT-LEARN-1)."
}
$site = ([string]$baseline.site).TrimEnd('/') + '/'

# DRIFT-VERSIONED-1: a Learn version goes into every address the folder reads,
# so only a plain version name is taken - a "&" or "#" would change the request.
foreach ($folder in @($baseline.folders)) {
    if ($folder.PSObject.Properties['view'] -and $null -ne $folder.view -and [string]$folder.view -cnotmatch '^[a-z0-9][a-z0-9.-]*\z') {
        throw "Folder $($folder.path) names view '$($folder.view)', which is not a Learn version name (lower-case letters, digits, dots and hyphens)."
    }
}

# The query that puts an address at the folder's Learn version, or nothing.
function Get-VmfViewQuery {
    param($Folder)
    if ($Folder -and $Folder.PSObject.Properties['view'] -and [string]$Folder.view) { "?view=$([string]$Folder.view)" } else { '' }
}
$textRoot = Join-Path (Split-Path $BaselinePath -Parent) ([string]$baseline.textFolder)

$userAgent = 'vm-migration-factory-docs-drift'
if (-not $PageProvider) {
    $PageProvider = {
        param($Url)
        # HttpClient, not Invoke-WebRequest: a redirect must come back AS a
        # redirect, so a moved page is reported instead of silently followed.
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(60)
            $request = [System.Net.Http.HttpRequestMessage]::new('GET', $Url)
            $request.Headers.UserAgent.ParseAdd($userAgent)
            $request.Headers.Accept.ParseAdd('text/markdown')
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            [pscustomobject]@{
                StatusCode  = [int]$response.StatusCode
                ContentType = [string]$response.Content.Headers.ContentType
                Content     = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Location    = if ($response.Headers.Location) { [string]$response.Headers.Location } else { $null }
            }
        }
        finally { $client.Dispose() }
    }.GetNewClosure()
}
if (-not $TocProvider) {
    $TocProvider = {
        param($Url)
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{ 'User-Agent' = $userAgent }
        if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    }.GetNewClosure()
}

# The text that is compared: everything after the front matter, with line
# endings made LF so a checkout on Windows hashes the same as the runner.
function Get-VmfPageText {
    param([string]$Markdown)
    $text = $Markdown -replace "`r`n", "`n"
    if (-not $text.StartsWith("---`n", [System.StringComparison]::Ordinal)) { return $null }
    $end = $text.IndexOf("`n---`n", 3, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { return $null }
    $body = $text.Substring($end + 5).Trim("`n").TrimEnd()
    $body + "`n"
}

function Get-VmfTextHash {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Text -replace "`r`n", "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# What changed, as lines a reader can act on: '-' was accepted, '+' is live,
# two lines of context. Capped, because a drift issue has a size limit and a
# rewritten page is better read on the page than in a thousand-line diff.
function Get-VmfTextDiff {
    param([string]$Old, [string]$New, [int]$Context = 2, [int]$MaxLines = 40, [int]$MaxWidth = 200)
    $a = @(($Old -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
    $b = @(($New -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
    $start = 0
    while ($start -lt $a.Count -and $start -lt $b.Count -and $a[$start] -ceq $b[$start]) { $start++ }
    $endA = $a.Count - 1; $endB = $b.Count - 1
    while ($endA -ge $start -and $endB -ge $start -and $a[$endA] -ceq $b[$endB]) { $endA--; $endB-- }
    # @() OUTSIDE the if: an if statement unrolls a one-line array to a bare
    # string, and indexing a string gives its first CHARACTER.
    $midA = @(if ($endA -ge $start) { $a[$start..$endA] })
    $midB = @(if ($endB -ge $start) { $b[$start..$endB] })

    # Each line of the changed middle, marked ' ', '-' or '+'.
    $ops = [System.Collections.Generic.List[object]]::new()
    $n = $midA.Count; $m = $midB.Count
    if ($n * $m -le 1000000) {
        $lcs = New-Object 'int[,]' ($n + 1), ($m + 1)
        for ($i = $n - 1; $i -ge 0; $i--) {
            for ($j = $m - 1; $j -ge 0; $j--) {
                $lcs[$i, $j] = if ($midA[$i] -ceq $midB[$j]) { $lcs[($i + 1), ($j + 1)] + 1 }
                               else { [Math]::Max($lcs[($i + 1), $j], $lcs[$i, ($j + 1)]) }
            }
        }
        $i = 0; $j = 0
        while ($i -lt $n -and $j -lt $m) {
            if ($midA[$i] -ceq $midB[$j]) { $ops.Add(@(' ', $midA[$i])); $i++; $j++ }
            elseif ($lcs[($i + 1), $j] -ge $lcs[$i, ($j + 1)]) { $ops.Add(@('-', $midA[$i])); $i++ }
            else { $ops.Add(@('+', $midB[$j])); $j++ }
        }
        while ($i -lt $n) { $ops.Add(@('-', $midA[$i])); $i++ }
        while ($j -lt $m) { $ops.Add(@('+', $midB[$j])); $j++ }
    }
    else {
        # Too large to align: the whole old block, then the whole new one.
        foreach ($line in $midA) { $ops.Add(@('-', $line)) }
        foreach ($line in $midB) { $ops.Add(@('+', $line)) }
    }

    # One sequence: context before, the aligned middle, context after - each
    # line with its number in the accepted text, so every hunk can say where.
    $seq = [System.Collections.Generic.List[object]]::new()
    $lead = [Math]::Max(0, $start - $Context)
    for ($k = $lead; $k -lt $start; $k++) { $seq.Add(@(' ', $a[$k], ($k + 1))) }
    $oldNo = $start + 1
    foreach ($op in $ops) {
        $seq.Add(@($op[0], $op[1], $oldNo))
        if ($op[0] -ne '+') { $oldNo++ }
    }
    $tailStart = $endA + 1
    for ($k = $tailStart; $k -lt [Math]::Min($a.Count, $tailStart + $Context); $k++) { $seq.Add(@(' ', $a[$k], ($k + 1))) }

    # Learn writes a paragraph as ONE line, often far past any width a reader
    # can scan. A changed pair is shown from just before its first differing
    # character - cutting both at the same width would show two equal lines.
    $from = New-Object 'int[]' $seq.Count
    $k = 0
    while ($k -lt $seq.Count) {
        if ($seq[$k][0] -ne '-') { $k++; continue }
        $minus = [System.Collections.Generic.List[int]]::new()
        $plus = [System.Collections.Generic.List[int]]::new()
        while ($k -lt $seq.Count -and $seq[$k][0] -eq '-') { $minus.Add($k); $k++ }
        while ($k -lt $seq.Count -and $seq[$k][0] -eq '+') { $plus.Add($k); $k++ }
        for ($q = 0; $q -lt [Math]::Min($minus.Count, $plus.Count); $q++) {
            $x = [string]$seq[$minus[$q]][1]; $y = [string]$seq[$plus[$q]][1]
            if ([Math]::Max($x.Length, $y.Length) -le $MaxWidth) { continue }
            $same = 0
            while ($same -lt $x.Length -and $same -lt $y.Length -and $x[$same] -ceq $y[$same]) { $same++ }
            $from[$minus[$q]] = $from[$plus[$q]] = [Math]::Max(0, $same - 40)
        }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    $shownBefore = $false
    for ($k = 0; $k -lt $seq.Count; $k++) {
        $show = $seq[$k][0] -ne ' '
        if (-not $show) {
            # An unchanged line is shown only near a change.
            for ($d = [Math]::Max(0, $k - $Context); $d -le [Math]::Min($seq.Count - 1, $k + $Context); $d++) {
                if ($seq[$d][0] -ne ' ') { $show = $true; break }
            }
        }
        if (-not $show) { $shownBefore = $false; continue }
        if (-not $shownBefore) { $out.Add("@@ line $($seq[$k][2]) @@") }
        $shownBefore = $true
        $text = [string]$seq[$k][1]
        if ($from[$k] -gt 0) { $text = '... ' + $text.Substring($from[$k]) }
        if ($text.Length -gt $MaxWidth) { $text = $text.Substring(0, $MaxWidth) + ' ...' }
        $out.Add("$($seq[$k][0]) $text")
    }

    $lines = @($out)
    if ($lines.Count -gt $MaxLines) {
        $more = $lines.Count - $MaxLines
        $lines = @($lines[0..($MaxLines - 1)]) + "... $more more lines - read the page"
    }
    $lines -join "`n"
}

# A toc.json href is relative to the folder the toc sits in, or a site path.
# Returns the page's Learn path (no locale, no query), or $null for a link
# that leaves Learn.
function Resolve-VmfTocHref {
    param([string]$Href, [string]$TocPath)
    if ($Href -match '^[a-z]+://') {
        if ($Href -notmatch '^https://learn\.microsoft\.com/') { return $null }
        $Href = $Href -replace '^https://learn\.microsoft\.com', ''
    }
    $base = [uri]('https://learn.microsoft.com/' + $TocPath.Substring(0, $TocPath.LastIndexOf('/') + 1))
    $resolved = [uri]::new($base, ($Href -replace '[?#].*$', ''))
    $path = $resolved.AbsolutePath.TrimStart('/') -replace '^[a-z]{2}-[a-z]{2}/', ''
    $path.TrimEnd('/')
}

function Get-VmfTocPages {
    param($Toc, [string]$TocPath)
    $found = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($item in @($Toc.items)) { $stack.Push($item) }
    while ($stack.Count) {
        $item = $stack.Pop()
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties['href'] -and $item.href) {
            $resolved = Resolve-VmfTocHref -Href ([string]$item.href) -TocPath $TocPath
            if ($resolved) { $found.Add($resolved) }
        }
        if ($item.PSObject.Properties['children']) { foreach ($child in @($item.children)) { $stack.Push($child) } }
    }
    @($found | Sort-Object -Unique)
}

function Get-VmfStoredTextPath {
    param([string]$PagePath)
    Join-Path $textRoot (($PagePath -replace '/', [System.IO.Path]::DirectorySeparatorChar) + '.md')
}

$drifted = [System.Collections.Generic.List[object]]::new()
$checked = 0
$tocCache = @{}

function Add-VmfDrift {
    param([string]$Path, [string]$Kind, [string]$Reason, $Folder, [string]$Diff, [string]$Url)
    $entry = [ordered]@{
        path             = $Path
        kind             = $Kind
        reason           = $Reason
        localDerivatives = @($Folder.localDerivatives)
        # UPST-5 / REPORT-1: a link per entry, so the issue can be ACTED ON.
        # Learn has no history page, so there is no second link: what changed
        # is the diff against the stored text, carried in the entry itself.
        url              = if ($Url) { $Url } else { "$site$Path$(Get-VmfViewQuery $Folder)" }
    }
    if ($Diff) { $entry.diff = $Diff }
    $drifted.Add([pscustomobject]$entry)
}

# One retry for what is usually passing: a timeout, a refusal (429) or a
# server error (5xx). The daily run makes about ninety requests, and one
# hiccup must not turn it red as "could not reach Microsoft".
function Invoke-VmfPageRead {
    param([string]$Url)
    $resp = $null
    $failure = $null
    for ($try = 1; $try -le 2; $try++) {
        $resp = $null
        try {
            $resp = & $PageProvider $Url
            $status = [int]$resp.StatusCode
            if ($status -ne 429 -and $status -lt 500) { return $resp }
            $failure = "HTTP $status"
        }
        catch { $failure = $_.Exception.Message }
        if ($try -eq 1 -and $RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
    }
    # Still refused or failing: hand the answer on, and it is reported as
    # unreachable below; an exception is thrown on to the same end.
    if ($resp) { return $resp }
    throw $failure
}

$changes = [System.Collections.Generic.List[string]]::new()
foreach ($folder in @($baseline.folders)) {
    $folderPath = [string]$folder.path
    $pattern = [string]$folder.include
    $viewQuery = Get-VmfViewQuery $folder
    $known = @{}
    foreach ($page in @($folder.pages)) { $known[[string]$page.name] = $page }

    # Pages the section's table of contents lists in this folder.
    $tocPath = [string]$folder.toc
    $listed = $null
    try {
        # A versioned toc is another list from the plain one: cached apart.
        $tocUrl = "$site$tocPath$viewQuery"
        if (-not $tocCache.ContainsKey($tocUrl)) {
            $tocJson = & $TocProvider $tocUrl
            $tocCache[$tocUrl] = @(Get-VmfTocPages -Toc ($tocJson | ConvertFrom-Json -Depth 100) -TocPath $tocPath)
        }
        $inFolder = @($tocCache[$tocUrl] | Where-Object {
                $_.Contains('/') -and $_.Substring(0, $_.LastIndexOf('/')) -eq $folderPath
            } | ForEach-Object { $_.Substring($_.LastIndexOf('/') + 1) })
        # A toc that lists NONE of a folder's pinned pages has changed shape or
        # moved - read as "no new page", it would hide every new page for good.
        # Not "all of them": a pinned page can be served and not listed.
        if ($known.Count -and -not @($inFolder | Where-Object { $known.ContainsKey($_) }).Count) {
            throw "it lists none of the $($known.Count) pinned pages in $folderPath"
        }
        $listed = @($inFolder | Where-Object { $_ -match $pattern })
    }
    catch {
        # Cannot read the list = cannot claim there is no new page. Same rule
        # the drills learned the hard way: a check that cannot reach its
        # evidence FAILS. The pinned pages are still read one by one below.
        Add-VmfDrift -Path $tocPath -Kind 'unreachable' -Folder $folder `
            -Reason "table of contents could not be used, so a new page in $folderPath would not be seen: $($_.Exception.Message)"
    }

    $toRead = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($known.Keys | Sort-Object)) { $toRead.Add($name) }
    $newNames = @(if ($null -ne $listed) { $listed | Where-Object { -not $known.ContainsKey($_) } | Sort-Object -Unique })
    if ($UpdateBaseline) { foreach ($name in $newNames) { $toRead.Add($name) } }
    else {
        foreach ($name in $newNames) {
            Add-VmfDrift -Path "$folderPath/$name" -Kind 'changed' -Folder $folder -Reason 'NEW PAGE upstream - never evaluated'
        }
    }

    $keep = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $toRead) {
        $pagePath = "$folderPath/$name"
        $url = "$site$pagePath$viewQuery"
        $pinned = $known[$name]
        try {
            $resp = Invoke-VmfPageRead $url
        }
        catch {
            Add-VmfDrift -Path $pagePath -Kind 'unreachable' -Folder $folder -Reason "fetch failed: $($_.Exception.Message)"
            if ($pinned) { $keep.Add($pinned) }
            continue
        }
        $status = [int]$resp.StatusCode
        if ($status -eq 404 -or $status -eq 410) {
            if ($UpdateBaseline) {
                $stored = Get-VmfStoredTextPath $pagePath
                if (Test-Path -LiteralPath $stored) { Remove-Item -LiteralPath $stored }
                $changes.Add("removed   $pagePath (HTTP $status)")
            }
            else {
                Add-VmfDrift -Path $pagePath -Kind 'changed' -Folder $folder -Reason 'PAGE REMOVED upstream - guidance we may still be relying on'
            }
            continue
        }
        if ($status -ge 300 -and $status -lt 400) {
            $targetUri = if ($resp.Location) { [uri]::new([uri]$url, [string]$resp.Location) } else { $null }
            $target = if ($targetUri) { $targetUri.AbsoluteUri } else { '(no location given)' }
            # DRIFT-VERSIONED-1: the same page at another version is a page the
            # rule was not read from - drift too, and said so.
            $where = if ($viewQuery -and $targetUri -and $targetUri.AbsolutePath -eq ([uri]$url).AbsolutePath) {
                "the same page at another version than view=$([string]$folder.view), $target"
            } else { $target }
            # Never re-pinned, in either mode: the new address may be outside
            # every watched folder, and dropping the pin would stop the watch
            # without a word. A person moves the watch in the baseline.
            Add-VmfDrift -Path $pagePath -Kind 'changed' -Folder $folder -Url $target `
                -Reason "PAGE MOVED upstream to $where - read it there, then move the watch in docs/upstream-docs.json"
            if ($pinned) { $keep.Add($pinned) }
            continue
        }
        $text = if ($status -eq 200 -and [string]$resp.ContentType -like 'text/markdown*') { Get-VmfPageText ([string]$resp.Content) } else { $null }
        if (-not $text) {
            Add-VmfDrift -Path $pagePath -Kind 'unreachable' -Folder $folder `
                -Reason "the page did not come back as markdown (HTTP $status, $([string]$resp.ContentType)), so it was not compared"
            if ($pinned) { $keep.Add($pinned) }
            continue
        }
        $checked++
        $hash = Get-VmfTextHash $text
        if ($UpdateBaseline) {
            $stored = Get-VmfStoredTextPath $pagePath
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $stored -Parent)
            [System.IO.File]::WriteAllText($stored, $text, [System.Text.UTF8Encoding]::new($false))
            $keep.Add([pscustomobject]@{ name = $name; sha256 = $hash })
            if (-not $pinned) { $changes.Add("added     $pagePath") }
            elseif ([string]$pinned.sha256 -ne $hash) { $changes.Add("re-pinned $pagePath") }
            continue
        }
        if ($hash -ne [string]$pinned.sha256) {
            $stored = Get-VmfStoredTextPath $pagePath
            $diff = if (Test-Path -LiteralPath $stored) {
                Get-VmfTextDiff -Old ([System.IO.File]::ReadAllText($stored)) -New $text
            } else { $null }
            $reason = "content changed (baseline $(([string]$pinned.sha256).Substring(0, [Math]::Min(12, ([string]$pinned.sha256).Length)))..., now $($hash.Substring(0,12))...)"
            if (-not $diff) { $reason += ' - no stored text to compare with' }
            Add-VmfDrift -Path $pagePath -Kind 'changed' -Folder $folder -Reason $reason -Diff $diff
        }
    }

    if ($UpdateBaseline) {
        $folder.pages = @($keep | Sort-Object { [string]$_.name })
    }
}

# Most pages changing in ONE run is more often Learn changing how it writes
# its markdown than Microsoft rewriting the guidance. Say so on each entry, so
# the reader checks one cause before reading every diff.
$contentChanged = @($drifted | Where-Object { $_.reason -like 'content changed*' })
if ($checked -ge 4 -and $contentChanged.Count * 2 -gt $checked) {
    foreach ($d in $contentChanged) {
        $d.reason += " - $($contentChanged.Count) of $checked pages changed in this run; first check whether Learn changed how it writes every page"
    }
}

if ($UpdateBaseline) {
    $baseline.checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $baseline | ConvertTo-Json -Depth 8 | Set-Content $BaselinePath
    Write-Host "Baseline re-pinned: $BaselinePath"
    foreach ($c in $changes) { Write-Host "  $c" }
    if (-not $changes.Count) { Write-Host '  no page added, re-pinned or removed' }
    foreach ($d in $drifted) {
        Write-Host "  NOT re-pinned: $($d.path)"
        Write-Host "    $($d.reason)"
    }
}
else {
    foreach ($d in $drifted) {
        Write-Host "  $($d.path)"
        Write-Host "    $($d.reason)"
        Write-Host "    re-evaluate: $(@($d.localDerivatives) -join ', ')"
    }
    if ($drifted.Count -gt 0) {
        Write-Host "Read the changed pages, decide what it means for the rules in CLAUDE.md and the engine, then ./tools/Test-DocsDrift.ps1 -UpdateBaseline"
    }
}

[pscustomobject]@{
    Checked  = $checked
    Drifted  = @($drifted)
    Changes  = @($changes)
    # A re-pin that could not read a page did not re-pin it, so it fails too.
    ExitCode = if ($drifted.Count -gt 0) { 1 } else { 0 }
}
