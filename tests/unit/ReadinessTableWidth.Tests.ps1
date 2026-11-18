#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# READINESS-TABLE-WIDTH-1 - the readiness table fits the window it is shown in.
#
# Seen 2026-11-11 in a screenshot of azd up in a narrow window: the text
# wrapped badly in smaller windows. preprovision.ps1 laid the table out 160
# characters wide whatever the window, so each long Detail wrapped a second
# time, across the Check and Result columns.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $hooks = Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($hooks, [ref]$null, [ref]$null)
    $found = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VmfConsoleWidth'
    }, $true))
    if ($found.Count -ne 1) { throw "expected one Get-VmfConsoleWidth, found $($found.Count)" }
    $script:width = & ([scriptblock]::Create("function Get-VmfConsoleWidth $($found[0].Body.Extent.Text)`n`${function:Get-VmfConsoleWidth}"))
    $script:pre = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
}

Describe 'READINESS-TABLE-WIDTH-1: the readiness table fits the window' {
    It 'a window gives its own width, one column less so a full line does not wrap by itself' {
        & $script:width -Reported 100 | Should -Be 99
        & $script:width -Reported 240 | Should -Be 239
    }

    It 'no window, or one too narrow to read a table in, keeps 160' {
        & $script:width -Reported $null | Should -Be 160
        & $script:width -Reported '' | Should -Be 160
        & $script:width -Reported 0 | Should -Be 160
        & $script:width -Reported 40 | Should -Be 160
    }

    It 'the readiness table is laid out to that width, not a fixed one' {
        $script:pre | Should -Match 'Format-Table Check, Result, Detail -AutoSize -Wrap \| Out-String -Width \(Get-VmfConsoleWidth\)'
        $script:pre | Should -Not -Match 'Out-String -Width 160'
    }

    It 'a long detail wraps inside its column at that width' {
        $rows = @([pscustomobject]@{ Check = 'App Service plans'; Result = 'ok'; Detail = ('word ' * 40).Trim() })
        $text = $rows | Format-Table Check, Result, Detail -AutoSize -Wrap | Out-String -Width (& $script:width -Reported 100)
        foreach ($line in ($text -split "`r?`n")) { $line.Length | Should -BeLessOrEqual 99 }
    }
}
