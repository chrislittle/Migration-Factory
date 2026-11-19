#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-CLOSING-AFTER-CONSENT-1: the install's last lines said "Widen or
# narrow that on the Admin page, once your directory has approved the product."
# also after the install read admin consent back as given (final lab azd up,
# 2026-11-16). Given: the condition is said no more. Any other state: it stays.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Get-VmfInstallClosingLines.ps1')
    $script:given = 'Widen or narrow that on the Admin page.'
    $script:notYet = 'Widen or narrow that on the Admin page, once your directory has approved the product.'
}

Describe 'INSTALL-CLOSING-AFTER-CONSENT-1: the Admin page line' {
    It 'admin consent given: says only where to widen or narrow it' {
        Get-VmfScopeAdminPageLine -AdminDone $true -Consent @{ State = 'given' } | Should -BeExactly $script:given
    }

    It 'admin consent <State>: keeps the condition' -ForEach @(
        @{ State = 'none' }, @{ State = 'partial' }, @{ State = 'unknown' }
    ) {
        Get-VmfScopeAdminPageLine -AdminDone $true -Consent @{ State = $State } | Should -BeExactly $script:notYet
    }

    It 'consent never read (a service principal ran the install): keeps the condition' {
        Get-VmfScopeAdminPageLine -AdminDone $true -Consent $null | Should -BeExactly $script:notYet
    }

    It 'not the administrator: no line, whatever the consent' {
        Get-VmfScopeAdminPageLine -AdminDone $false -Consent @{ State = 'given' } | Should -BeNullOrEmpty
        Get-VmfScopeAdminPageLine -AdminDone $false -Consent $null | Should -BeNullOrEmpty
    }

    It 'postprovision prints the line from the function, with the consent it read back' {
        $post = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
        $post | Should -Match 'Get-VmfInstallClosingLines\.ps1'
        $post | Should -Match 'Get-VmfScopeAdminPageLine -AdminDone \$adminDone -Consent \$consent'
        $post | Should -Not -Match 'once your directory has approved the product'
    }
}
