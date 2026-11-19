<#
.SYNOPSIS
    DOCS-1: keep the manual's contents page in step with its sidebar.
.DESCRIPTION
    The manual is one set of markdown files read two ways. In the app, docsify
    renders `_sidebar.md` as navigation down the side. On GitHub there is no
    docsify, `_sidebar.md` is just another file, and a reader who lands in
    docs/manual has NO WAY THROUGH the 45 pages at all.

    So the manual's own README carries a contents list, and this script writes
    it from `_sidebar.md` - one source, two renderings, rather than two lists
    that drift. The links are RELATIVE, which docsify and GitHub both resolve.

    Run it after adding, moving or renaming a page.
    `tests/unit/ManualNavigation.Tests.ps1` fails if the two ever disagree.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManualRoot = (Join-Path $PSScriptRoot '..' 'docs' 'manual')
)

$ErrorActionPreference = 'Stop'

function Get-VmfManualToc {
    <#
        Reads _sidebar.md and returns the contents markdown. A section is a
        bare line; a page is an indented link. The sidebar writes docsify's
        root-relative form (/use/start.md); GitHub needs a relative one
        (use/start.md), and docsify resolves that too.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SidebarPath)

    $lines = Get-Content -LiteralPath $SidebarPath
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $link = [regex]::Match($line, '^\s*-\s*\[(?<text>[^\]]+)\]\((?<href>[^)]+)\)\s*$')
        if ($link.Success) {
            $href = $link.Groups['href'].Value -replace '^/', ''
            $text = $link.Groups['text'].Value
            # A top-level link is the manual's own home page, and a contents
            # list that links to the page it is printed on helps nobody.
            if ($line -match '^\s{2,}') { $out.Add("- [$text]($href)") }
            continue
        }
        $section = [regex]::Match($line, '^\s*-\s*(?<text>.+?)\s*$')
        if ($section.Success) {
            if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
            $out.Add("### $($section.Groups['text'].Value)")
            $out.Add('')
        }
    }
    ($out -join "`n").TrimEnd() + "`n"
}

$sidebar = Join-Path $ManualRoot '_sidebar.md'
$readme = Join-Path $ManualRoot 'README.md'
if (-not (Test-Path $sidebar)) { throw "No sidebar at $sidebar" }
if (-not (Test-Path $readme)) { throw "No manual README at $readme" }

$startMark = '<!-- contents:start - written by tools/Update-VmfManualToc.ps1 -->'
$endMark = '<!-- contents:end -->'
$toc = Get-VmfManualToc -SidebarPath $sidebar
$block = "$startMark`n`n$toc`n$endMark"

$text = Get-Content -LiteralPath $readme -Raw
if ($text -match [regex]::Escape($startMark)) {
    $pattern = [regex]::Escape($startMark) + '.*?' + [regex]::Escape($endMark)
    $updated = [regex]::Replace($text, $pattern, { $block }, 'Singleline')
}
else {
    $updated = $text.TrimEnd() + "`n`n## Contents`n`n$block`n"
}

if ($updated -eq $text) {
    Write-Host 'The manual contents are already in step with the sidebar.'
    return
}
if ($PSCmdlet.ShouldProcess($readme, 'write the contents list')) {
    Set-Content -LiteralPath $readme -Value $updated -Encoding utf8NoBOM -NoNewline
    Write-Host "Wrote the contents list into $readme"
}
