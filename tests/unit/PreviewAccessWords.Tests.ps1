#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREVIEW-ACCESS-WORDS-1: no page, manual page or map entry says that the
# in-place upgrade (Preview) needs Assess on the subscription.
#
# THE DEFECT. The Admin page said, under the resource group choice, "The
# in-place upgrade (Preview) needs Assess on the subscription.", the targets
# step said on AuthorizationFailed that "the product needs Assess on the
# subscription", and the manual and the permission map said a grant on
# resource groups only does not reach the read of the preview feature.
#
# THE MEASUREMENT (final lab, 2026-11-13, a new installation, one subscription,
# one tenant): with the roles given on ONE resource group only (Assess and
# migrate, nothing on the subscription; read back), the web service and the
# engine read Microsoft.Compute/VMTempDiskResizePreview as Registered, and an
# in-place upgrade (Preview) of a Windows machine completed through the app.
# No Microsoft page found says why (unverified), so nothing says either that
# a resource group grant is enough everywhere.
#
# THE RULE. Nothing says the Preview needs the subscription. The targets step
# still says, only when Azure answered AuthorizationFailed, that Azure did
# not let the product read the feature, and gives Assess on the subscription
# as the step (measured to work by TEMP-DISK-PREVIEW-ROLE-1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:claim = '(?i)needs\s+(\*\*)?Assess(\*\*)?\s+on\s+the\s+subscription'
    $script:noReach = '(?i)resource groups? only does not reach'
}

Describe 'PREVIEW-ACCESS-WORDS-1: the Admin page' {
    It 'has no line that says the Preview needs Assess on the subscription' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.js') -Language CStyle
        $code | Should -Not -Match 'scopeLevelRgPreview'
        $code | Should -Not -Match 'scope-rg-preview'
        $code | Should -Not -Match $script:claim
    }
    It 'still offers the resource group first, with its own sentence only' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.js') -Language CStyle
        $code | Should -Match "scopeLevelRg:\s+'One resource group\. This is the smallest choice, and the one to prefer\.'"
        $code | Should -Match "\[\['rg', UX\.scopeLevelRg\], \['sub', UX\.scopeLevelSub\], \['mg', UX\.scopeLevelMg\]\]"
    }
}

Describe 'PREVIEW-ACCESS-WORDS-1: the targets step' {
    It 'says on AuthorizationFailed that Azure did not let the product read the feature, not that it needs the subscription' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Language CStyle
        $code | Should -Match "tPvAuthWhy: 'Azure registers a preview feature for the whole subscription\. Azure did not let the product read the feature state\.'"
        $code | Should -Not -Match $script:claim
    }
    It 'keeps the step that gives Assess on the subscription, and shows the why only on AuthorizationFailed' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Language CStyle
        $code | Should -Match "tPvAuthStep: 'Open the Admin page\. Under Where the product may work, give Assess on subscription \{sub\}\.'"
        $code | Should -Match "if \(String\(p\.code \?\? ''\) === 'AuthorizationFailed'\) \{\s+return ``<p>\$\{esc\(UX\.tPvAuthWhy\)\}</p>"
    }
}

Describe 'PREVIEW-ACCESS-WORDS-1: the manual' {
    It 'no manual page says the Preview needs Assess on the subscription, or that a resource group grant does not reach the read' {
        $pages = Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter '*.md'
        $pages.Count | Should -BeGreaterThan 10
        foreach ($page in $pages) {
            $text = Get-Content -LiteralPath $page.FullName -Raw
            $text | Should -Not -Match $script:claim -Because $page.Name
            $text | Should -Not -Match $script:noReach -Because $page.Name
        }
    }
    It 'the Admin page of the manual says the resource group sentence and nothing about the Preview' {
        $admin = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'admin.md') -Raw
        $admin | Should -Match '- \*\*One resource group\.\*\* The smallest choice, and the one to prefer\.\r?\n'
    }
    It 'the targets step page says that Azure did not let the product read the feature, then the steps' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
        $page | Should -Match 'Error code from Azure: AuthorizationFailed\.\*\* Azure did not let the product read the feature state\. For AuthorizationFailed, the notice gives the steps'
    }
}

Describe 'PREVIEW-ACCESS-WORDS-1: the permission map' {
    BeforeAll {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json -Depth 20
        $script:why = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' } | ForEach-Object { $_.why }) -join ' '
    }
    It 'records the measurement on one resource group only' {
        $script:why | Should -Match 'MEASURED 2026-11-13'
        $script:why | Should -Match 'on ONE resource group only'
        $script:why | Should -Match 'the web service \(the targets step\) and the engine \(Checking\) read VMTempDiskResizePreview as Registered'
    }
    It 'says the reason is not sourced, and no longer says a resource group grant does not reach the read' {
        $script:why | Should -Match 'unverified'
        $script:why | Should -Not -Match '(?i)does not reach it'
        $script:why | Should -Not -Match '(?i)not proof either way'
        $script:why | Should -Not -Match $script:claim
    }
}
