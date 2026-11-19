#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISCLAIMER-1: the product says, in its own pages, its reports, its manual and
# its install, that it is not an official Microsoft product and that Microsoft
# does not support it.
#
# The words were agreed on 2026-10-30 (product name changed to Migration
# Factory on 2026-10-31). They live ONCE, in data/disclaimer.json. Every other
# place that shows them - help.js for the pages, the report, the manual page and
# the install hook - is held to that file here, and the file is held to the
# agreed words, so a change to the words is a change to this test too.
#
# tests/js/disclaimer.test.js RUNS the pages: the line on every page, the
# notice at first sign-in, and the line in each download the browser writes.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'disclaimer.json'
    $script:words = if (Test-Path -LiteralPath $script:dataFile) { Get-Content -LiteralPath $script:dataFile -Raw | ConvertFrom-Json } else { $null }
    $script:hooks = Join-Path $script:repoRoot 'infra' 'hooks'
    $script:manualPage = Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'disclaimer.md'

    # A JavaScript string literal of help.js, by its key in TEXT. Single quotes
    # only, as TEXT writes them; an escaped quote is unescaped.
    function Get-DcHelpText([string]$Key) {
        $src = Get-Content -LiteralPath (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $m = [regex]::Match($src, "(?m)^\s*$Key\s*:\s*'((?:[^'\\]|\\.)*)'")
        if (-not $m.Success) { return $null }
        $m.Groups[1].Value -replace "\\'", "'"
    }
}

Describe 'DISCLAIMER-1: the words are the agreed words, in one place' {

    It 'the data file holds the agreed words exactly' {
        # The agreed words, with the product name the dashboard uses. Change
        # them only by agreement - and then here as well.
        $script:words | Should -Not -BeNullOrEmpty -Because 'data/disclaimer.json holds the words'
        $script:words.shortLine | Should -BeExactly 'Migration Factory is not an official Microsoft product. Microsoft does not support or endorse it. It is provided as is, with no warranty.'
        $script:words.title | Should -BeExactly 'Disclaimer'
        @($script:words.paragraphs).Count | Should -Be 3
        $script:words.paragraphs[0] | Should -BeExactly 'Migration Factory is not an official Microsoft product. Microsoft does not support, sponsor or endorse it.'
        $script:words.paragraphs[1] | Should -BeExactly 'Do not open an Azure support request for the product. Report a problem with the product on its GitHub repository.'
        $script:words.paragraphs[2] | Should -BeExactly 'The product is provided as is, with no warranty, under the Apache License 2.0. You are responsible for the changes it makes in your subscriptions. Test it on machines that are not in production first.'
    }

    It 'the words name nobody: no person, no employer and no team (rule 13)' {
        $all = (@($script:words.shortLine, $script:words.title) + @($script:words.paragraphs)) -join ' '
        $all | Should -Not -Match '@' -Because 'no address'
        $all | Should -Not -Match '(?i)\bteam\b|\bour\b|\bwe\b' -Because 'the words say what the product is not, never who made it'
    }

    It 'the pages show the same words: help.js carries a copy that is equal to the file' {
        Get-DcHelpText 'disclaimerLine' | Should -BeExactly $script:words.shortLine
        Get-DcHelpText 'disclaimerTitle' | Should -BeExactly $script:words.title
        Get-DcHelpText 'disclaimerP1' | Should -BeExactly $script:words.paragraphs[0]
        Get-DcHelpText 'disclaimerP2' | Should -BeExactly $script:words.paragraphs[1]
        Get-DcHelpText 'disclaimerP3' | Should -BeExactly $script:words.paragraphs[2]
    }

    It 'the module reads the words from the file, and from nowhere else' {
        $d = InModuleScope VmMigrationFactory { Get-VmfDisclaimer }
        $d.shortLine | Should -BeExactly $script:words.shortLine
        $d.title | Should -BeExactly $script:words.title
        @($d.paragraphs) | Should -Be @($script:words.paragraphs)
    }
}

Describe 'DISCLAIMER-1: the report carries the short line' {

    BeforeAll {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-disclaimer-run-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $null = & (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1') -RunPath $script:runPath
        $script:report = Get-Content -LiteralPath (New-VmfReport -OutPath $script:runPath) -Raw
    }
    AfterAll {
        if ($script:runPath -and (Test-Path $script:runPath)) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'the report a migration writes has the line, in its foot' {
        $line = [System.Net.WebUtility]::HtmlEncode($script:words.shortLine)
        $script:report | Should -Match ([regex]::Escape("<p class=`"disclaimer`">$line</p>"))
        $script:report.IndexOf($line) | Should -BeGreaterThan $script:report.IndexOf('class="foot"') -Because 'it is at the end, where a reader looks for it'
    }

    It 'and the line takes the colours of the theme the report shows' {
        $css = InModuleScope VmMigrationFactory { $script:VmfReportCss }
        $css | Should -Match '\.disclaimer\{[^}]*color:var\(--muted\)' -Because 'a token, so light and dark both reach it'
    }
}

Describe 'DISCLAIMER-1: the manual has the full notice on one page' {

    It 'the page exists, and holds the title and each paragraph as written' {
        Test-Path -LiteralPath $script:manualPage | Should -BeTrue
        $text = (Get-Content -LiteralPath $script:manualPage -Raw) -replace "`r", ''
        $text | Should -Match ('(?m)^# ' + [regex]::Escape($script:words.title) + '$')
        foreach ($para in $script:words.paragraphs) {
            $text | Should -Match ('(?m)^' + [regex]::Escape($para) + '$') -Because 'each paragraph is its own line, word for word'
        }
    }

    It 'the short line the page quotes is the short line of the file, word for word' {
        $text = (Get-Content -LiteralPath $script:manualPage -Raw) -replace "`r", ''
        $m = [regex]::Match($text, '(?m)^The short line says: "(.*)"$')
        $m.Success | Should -BeTrue -Because 'the page quotes the short line'
        $m.Groups[1].Value | Should -BeExactly $script:words.shortLine
    }
    It 'the sidebar lists it' {
        Get-Content -LiteralPath (Join-Path $script:repoRoot 'docs' 'manual' '_sidebar.md') -Raw |
            Should -Match ([regex]::Escape('(/understand/disclaimer.md)'))
    }

    It 'the line on every page links to it' {
        $help = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Language CStyle
        # NO-POPUPS-1: the manual page, through the helper that opens it in this tab.
        $help | Should -Match ([regex]::Escape("const MANUAL_URL = 'manual/index.html';"))
        $help | Should -Match ([regex]::Escape("const DISCLAIMER_HASH = '#/understand/disclaimer';"))
        $help | Should -Match ([regex]::Escape('href="${esc(manualHref(DISCLAIMER_HASH))}"'))
    }
}

Describe 'DISCLAIMER-1: the install shows the notice before anything deploys' {

    BeforeAll {
        $script:pre = Join-Path $script:hooks 'preprovision.ps1'
        $tokens = $null; $errs = $null
        $script:preAst = [System.Management.Automation.Language.Parser]::ParseFile($script:pre, [ref]$tokens, [ref]$errs)
    }

    It 'Show-VmfDisclaimer prints the title and every paragraph, as written' {
        . (Join-Path $script:hooks 'AzdHooks.ps1')
        $out = (Show-VmfDisclaimer 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $out | Should -Match ([regex]::Escape($script:words.title))
        foreach ($para in $script:words.paragraphs) {
            $out | Should -Match ([regex]::Escape($para))
        }
    }

    It 'it reads the words from the data file, not from a copy of its own' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:hooks 'AzdHooks.ps1') -Language PowerShell
        $code | Should -Match ([regex]::Escape("'disclaimer.json'"))
        $code | Should -Not -Match 'not an official Microsoft product' -Because 'one source of the words'
    }

    It 'preprovision shows it first: before the readiness check, before any value is written, and before any az call' {
        $calls = @($script:preAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $show = @($calls | Where-Object { $_.GetCommandName() -eq 'Show-VmfDisclaimer' })
        $show.Count | Should -Be 1 -Because 'preprovision shows the notice once'
        $at = $show[0].Extent.StartOffset
        $later = @($calls | Where-Object {
                $n = $_.GetCommandName()
                $n -in @('az', 'azd', 'Set-AzdValue', 'Read-VmfChoice') -or
                ($_.Extent.Text -match 'Test-VmfReadiness\.ps1')
            })
        $later.Count | Should -BeGreaterThan 0 -Because 'the hook does deploy, so there is something to be first before'
        foreach ($c in $later) {
            $c.Extent.StartOffset | Should -BeGreaterThan $at -Because "the notice comes before: $($c.Extent.Text.Split("`n")[0])"
        }
    }

    It 'and nothing can hide it: the call stands under no condition, and the function takes no switch' {
        $show = @($script:preAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-VmfDisclaimer' }, $true))[0]
        $parent = $show.Parent
        while ($parent) {
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.IfStatementAst])
            $parent | Should -Not -BeOfType ([System.Management.Automation.Language.TryStatementAst])
            $parent = $parent.Parent
        }
        . (Join-Path $script:hooks 'AzdHooks.ps1')
        @((Get-Command Show-VmfDisclaimer).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters }) |
            Should -BeNullOrEmpty
    }
}
