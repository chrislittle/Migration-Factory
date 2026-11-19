# DISCLAIMER-1: the product says it is not an official Microsoft product and
# that Microsoft does not support it - in its pages, its reports, its manual
# and its install.
#
# The words are written ONCE, in data/disclaimer.json, and agreed with the
# owner; tests/unit/Disclaimer.Tests.ps1 holds that file to them. The report
# reads them here. The install hook reads the same file (infra/hooks).

function Get-VmfDisclaimer {
    <#
    .SYNOPSIS
        The disclaimer: the short line, the title and the paragraphs of the
        full notice, from data/disclaimer.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $file = Join-Path $script:VmfModuleRoot 'data' 'disclaimer.json'
    $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    [pscustomobject]@{
        shortLine  = [string]$doc.shortLine
        title      = [string]$doc.title
        paragraphs = @($doc.paragraphs | ForEach-Object { [string]$_ })
    }
}
