#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AZD-UP-QUIET-1 - azd up prints nothing an operator does not need.
#
# Removed 2026-11-10: the last line of the dashboard publish,
# "Point runs at it with: -RunPath azblob://<store>/vmf-runs/<runId>".
# Every operator action is in the app (CLAUDE.md rule 12), and the
# dashboard and the engine give the run path themselves, so the line sent the
# person to a way of working the product no longer asks for. The -Container
# parameter existed only to print it. The stack-mode half is in NoStacks.Tests.ps1.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:deploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
    $script:post   = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
}

Describe 'AZD-UP-QUIET-1: the dashboard publish names no -RunPath' {
    It 'found the publish lines, or none of this proves anything' {
        $script:deploy | Should -Match 'Migration Dashboard published'
    }

    It 'prints no run path for an operator to type' {
        $script:deploy | Should -Not -Match '(?i)-RunPath'
        $script:deploy | Should -Not -Match 'azblob://'
    }

    It 'has no -Container parameter, and the install passes none' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1'), [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Not -Contain 'Container'
        @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Contain 'StorageAccountName'
        $script:post | Should -Match 'Deploy-VmfDashboard\.ps1'
        $script:post | Should -Not -Match "Deploy-VmfDashboard\.ps1'\)[^\r\n]*-Container"
    }
}
