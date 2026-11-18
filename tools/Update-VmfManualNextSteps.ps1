<#
.SYNOPSIS
    DOCS-NEXT-1: give every manual page somewhere to go.
.DESCRIPTION
    Found 2026-09-09 on `use/read-an-assessment.md`: the page ended with no
    link to the next step. Each page must end with a way forward in the
    manual.

    He was right, and it was not one page: 29 of the 45 pages ended with no
    link to anywhere. The 16 that looked correct were not a convention either -
    they were prose links that happened to sit near the end of a section. Only
    `use/start.md` had a real footer.

    In the app, docsify shows the sidebar, so a reader can always move. On
    GitHub there is no sidebar - a page IS the whole of what a reader sees, and
    a page that ends is a dead end.

    So every page gets a Next footer, and it is WRITTEN FROM `_sidebar.md`
    rather than by hand, because a hand-written chain of 45 links is wrong the
    first time a page moves. The order is the sidebar's own order, straight
    through, so the last page of a section leads into the first page of the
    next one. The last page of all leads back to the contents.

    Run it after adding, moving or renaming a page.
    `tests/unit/ManualNavigation.Tests.ps1` fails if a page has no footer, or
    if a footer disagrees with the sidebar.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManualRoot = (Join-Path $PSScriptRoot '..' 'docs' 'manual')
)

$ErrorActionPreference = 'Stop'

# The marker pairs the way the contents list does, so the footer can be
# rewritten without touching a word the author put there.
$script:VmfNextBegin = '<!-- next:begin -->'
$script:VmfNextEnd   = '<!-- next:end -->'

function Get-VmfManualOrder {
    <#
        The page order, straight through the sidebar. Returns the href and the
        link text of each page, in the order a reader meets them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SidebarPath)

    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($line in (Get-Content -LiteralPath $SidebarPath)) {
        $link = [regex]::Match($line, '^\s*-\s*\[(?<text>[^\]]+)\]\((?<href>[^)]+)\)\s*$')
        if (-not $link.Success) { continue }
        # The parentheses matter: inside a hashtable literal PowerShell reads
        # the comma of `-replace 'a', 'b'` as a list separator and will not parse.
        $out.Add([pscustomobject]@{
            Href = ($link.Groups['href'].Value -replace '^/', '')
            Text = $link.Groups['text'].Value
        })
    }
    $out
}

function Get-VmfRelativeHref {
    <#
        A link from one manual page to another, as both docsify and GitHub
        resolve it. Same folder is a bare name; anywhere else walks up.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)

    # NOT $parts[0..($parts.Count - 2)]. For a path with no folder that range
    # is 0..-1, which PowerShell expands to the FIRST and LAST element rather
    # than to nothing - and 'README.md' came out as '../README.md/README.md'.
    $fromParts = @($From -split '/')
    $toParts   = @($To -split '/')
    $fromDir   = if ($fromParts.Count -gt 1) { @($fromParts[0..($fromParts.Count - 2)]) } else { @() }
    $toDir     = if ($toParts.Count -gt 1) { @($toParts[0..($toParts.Count - 2)]) } else { @() }
    $toName    = $toParts[-1]

    if (($fromDir -join '/') -eq ($toDir -join '/')) { return $toName }
    $up = '../' * $fromDir.Count
    if ($toDir.Count -eq 0) { return "$up$toName" }
    "$up$($toDir -join '/')/$toName"
}

function Get-VmfNextFooter {
    <#
        The footer for one page. The last page leads back to the contents,
        because a manual that ends nowhere is the defect this fixes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From, $Next)

    $body = if ($null -eq $Next) {
        $href = Get-VmfRelativeHref -From $From -To 'README.md'
        "**Back to** [the contents]($href)."
    }
    else {
        $href = Get-VmfRelativeHref -From $From -To $Next.Href
        "**Next:** [$($Next.Text)]($href)"
    }
    @($script:VmfNextBegin, '', '---', '', $body, '', $script:VmfNextEnd)
}

$sidebar = Join-Path $ManualRoot '_sidebar.md'
$order = @(Get-VmfManualOrder -SidebarPath $sidebar)
if ($order.Count -lt 2) { throw "Read $($order.Count) pages from $sidebar - expected the whole manual." }

$changed = 0
for ($i = 0; $i -lt $order.Count; $i++) {
    $page = $order[$i]
    $next = if ($i -lt $order.Count - 1) { $order[$i + 1] } else { $null }
    $path = Join-Path $ManualRoot $page.Href
    if (-not (Test-Path -LiteralPath $path)) { throw "The sidebar names $($page.Href), which does not exist." }

    $text = (Get-Content -LiteralPath $path -Raw) -replace "`r`n", "`n"
    $footer = (Get-VmfNextFooter -From $page.Href -Next $next) -join "`n"

    $begin = $text.IndexOf($script:VmfNextBegin)
    $body = if ($begin -ge 0) { $text.Substring(0, $begin).TrimEnd("`n") } else { $text.TrimEnd("`n") }
    $wanted = "$body`n`n$footer`n"

    if ($wanted -ne $text) {
        if ($PSCmdlet.ShouldProcess($page.Href, 'write the Next footer')) {
            [System.IO.File]::WriteAllText($path, $wanted, [System.Text.UTF8Encoding]::new($false))
        }
        $changed++
    }
}
if ($changed -eq 0) { Write-Host 'Every manual page already leads somewhere.' }
else { Write-Host "Wrote the Next footer on $changed page(s) of $($order.Count)." }
