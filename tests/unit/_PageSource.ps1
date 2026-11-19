# CSP-INLINE-1: a page's source, as the browser puts it together.
#
# The dashboard pages, and the manual's index.html, kept their script in one
# inline block each. The content security policy now refuses inline script
# (src/dashboard/web.config: script-src 'self'), so each page's script moved
# to a file with the page's own name: wizard.html loads wizard.js.
#
# Hundreds of checks read a page and look for a function, a string table or a
# call in it. Read alone, the .html no longer holds any of that, and a
# `Should -Not -Match` against it can never fail again. So a check reads the
# page through this helper: the page's markup, with the tag that loads its own
# script replaced by that script, inline, exactly where the browser runs it.
# At the move, the text was the same text the page held before, except for
# what CSP-INLINE-1 changed on purpose: two comment lines in reports.js, and
# the close-button listener added to migrations.js in place of an onclick=
# attribute. So a position, an order or a pattern a check relies on still
# means what it meant.
#
# Only the page's OWN script goes in. The shared files (help.js, theme.js,
# assessment-report.js) stay as the tags that load them, as they always were.
#
# CspInline.Tests.ps1 reads the RAW page, because that is the file the browser
# receives and the policy judges.
#
# Dot-sourced, not named *.Tests.ps1, so Pester does not discover it.
# _CodeOnly.ps1 dot-sources it, so every check that reads code has it.

function Get-VmfPageSource {
    <#
    .SYNOPSIS
        The text of a page with its own script put back inline.
    .PARAMETER Path
        The page. A file that is not .html or .htm is returned as it is.
    .OUTPUTS
        [string]. For a page that loads `<name>.js` from its own folder, the
        page with `<script src="<name>.js"></script>` replaced by
        `<script>` + a newline + the file + `</script>`.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    # Resolved against the PowerShell location, as Get-Content would: .NET alone
    # resolves a relative path against the process folder.
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $text = [System.IO.File]::ReadAllText($full)
    $ext = [System.IO.Path]::GetExtension($full)
    if ($ext -notin '.html', '.htm') { return $text }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($full) + '.js'
    $own = Join-Path ([System.IO.Path]::GetDirectoryName($full)) $name
    $tag = '<script src="' + $name + '"></script>'
    $at = $text.IndexOf($tag, [System.StringComparison]::Ordinal)
    if ($at -lt 0) { return $text }
    if (-not [System.IO.File]::Exists($own)) {
        throw "$([System.IO.Path]::GetFileName($full)) loads $name, which is not beside it."
    }
    if ($text.IndexOf($tag, $at + $tag.Length, [System.StringComparison]::Ordinal) -ge 0) {
        throw "$([System.IO.Path]::GetFileName($full)) loads $name twice."
    }
    $ownText = [System.IO.File]::ReadAllText($own)
    $text.Substring(0, $at) + "<script>`n" + $ownText + '</script>' + $text.Substring($at + $tag.Length)
}
