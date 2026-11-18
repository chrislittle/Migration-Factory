# ROLE-DEPLOY-1: a role whose PERMISSIONS changed is deployed again.
#
# THE DEFECT, measured on a live subscription 2026-09-18. The install decided
# whether to deploy the two custom roles by comparing their assignable scopes
# and nothing else:
#
#     $unchanged = ... Compare-Object $current.Assess.assignableScopes $wanted
#     if ($unchanged) { Write-Host '   the list of places ... is already correct'; return }
#
# So when a role's ACTIONS changed and its scopes did not - which is what every
# permission fix looks like - it reported success and deployed NOTHING.
#
# ROLE-SNAP-1 added an action the restore path needs. It was merged and
# `azd up` ran. The install printed "the list of places these roles may be given
# out is already correct", which was TRUE and had nothing to do with what had
# changed. The role never gained the action and the restore went on failing.
#
# THERE WAS NO OTHER WAY TO APPLY IT. The dashboard has no re-apply, and a grant
# made by hand cannot add a permission the DEFINITION does not carry. So the
# Admin page could not apply a new set of roles at all.
#
# AND IT HID A REMOVAL TOO. Reading the live subscription while writing this
# found the role still carrying Microsoft.Authorization/roleAssignments/read and
# Microsoft.KeyVault/vaults/read - two permissions IDENTITY-4 took OUT of the
# map. The skip blocked the removal exactly as it blocked the addition, so a
# removal that was meant to remove did not. That breaks a standing rule - a
# removal must remove - through a comparison nobody thought about.
#
# The whole point of deriving the role from the map is that the role cannot fall
# behind the code. A deploy that skips on a stale comparison IS that failure,
# wearing a reassuring message.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1')

    # A deployed role, shaped the way `az role definition list` returns one.
    function New-FakeRole {
        param([string[]]$Actions, [string[]]$Scopes = @('/subscriptions/s'))
        [pscustomobject]@{
            roleName         = 'VMF Migration (test)'
            assignableScopes = $Scopes
            permissions      = @([pscustomobject]@{ actions = $Actions; notActions = @() })
        }
    }
}

Describe 'ROLE-DEPLOY-1: the install notices a permission change' {

    It 'the expected actions come from the map, and are not empty' {
        # THE VACUITY GUARD. An empty expectation would call every role correct,
        # which is the defect with extra steps.
        $assess = Get-VmfExpectedRoleActions -Role 'assess'
        $execute = Get-VmfExpectedRoleActions -Role 'execute'
        @($assess).Count | Should -BeGreaterThan 5
        @($execute).Count | Should -BeGreaterThan @($assess).Count `
            -Because 'a migration does everything an assessment does, and more'
    }

    It 'the execute role contains the assess role, as the template unions them' {
        $assess = Get-VmfExpectedRoleActions -Role 'assess'
        $execute = Get-VmfExpectedRoleActions -Role 'execute'
        foreach ($a in $assess) { $execute | Should -Contain $a }
    }

    It 'and it carries the action the restore path needs' {
        # ROLE-SNAP-1. Named here as well, because this is the check that would
        # have told somebody the fix had not reached Azure.
        # Assigned first, not piped. The helper returns the list as ONE pipeline
        # object so a single-action role does not unroll into a bare string -
        # piping it straight in makes the collection a list holding a list, and
        # the check then fails on a role that is correct.
        $execute = Get-VmfExpectedRoleActions -Role 'execute'
        $execute | Should -Contain 'Microsoft.Compute/disks/beginGetAccess/action'
    }

    It 'THE DEFECT: a role MISSING an action is not current' {
        $expected = Get-VmfExpectedRoleActions -Role 'execute'
        $short = @($expected | Where-Object { $_ -ne 'Microsoft.Compute/disks/beginGetAccess/action' })
        Test-VmfRoleActionsCurrent -Role (New-FakeRole -Actions $short) -Expected $expected |
            Should -BeFalse -Because 'this is exactly the state that left the restore broken'
    }

    It 'a role carrying an action the map dropped is not current either' {
        # A removal that does not remove. Measured on the live subscription:
        # two permissions IDENTITY-4 took out were still deployed.
        $expected = Get-VmfExpectedRoleActions -Role 'execute'
        $extra = @($expected) + @('Microsoft.KeyVault/vaults/read')
        Test-VmfRoleActionsCurrent -Role (New-FakeRole -Actions $extra) -Expected $expected |
            Should -BeFalse -Because 'a privilege nobody can account for is drift too'
    }

    It 'a role that matches exactly IS current, so this does not deploy for ever' {
        # The other half. A check that always says "drifted" would redeploy on
        # every install and demand a permission the operator may not hold.
        $expected = Get-VmfExpectedRoleActions -Role 'execute'
        Test-VmfRoleActionsCurrent -Role (New-FakeRole -Actions $expected) -Expected $expected |
            Should -BeTrue
    }

    It 'order and duplicates do not count as drift' {
        $expected = Get-VmfExpectedRoleActions -Role 'execute'
        $shuffled = @($expected | Sort-Object { Get-Random }) + @($expected[0])
        Test-VmfRoleActionsCurrent -Role (New-FakeRole -Actions $shuffled) -Expected $expected |
            Should -BeTrue -Because 'Azure does not promise an order, and a repeat is not a privilege'
    }

    It 'a role that is absent, or has no permissions at all, is not current' {
        $expected = Get-VmfExpectedRoleActions -Role 'execute'
        Test-VmfRoleActionsCurrent -Role $null -Expected $expected | Should -BeFalse
        $empty = [pscustomobject]@{ roleName = 'x'; assignableScopes = @('/subscriptions/s') }
        Test-VmfRoleActionsCurrent -Role $empty -Expected $expected | Should -BeFalse `
            -Because 'a definition with nothing on it has drifted as far as it can'
    }

    It 'the install compares BOTH things before it skips' {
        # The wiring. Neither helper is any use if the caller still decides on
        # the scopes alone - which is the whole defect.
        . (Join-Path $script:repoRoot 'tests' 'unit' '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1')
        $code | Should -Match 'if \(\$scopesMatch -and \$permissionsMatch\)' `
            -Because 'a skip needs both to be true'
        $code | Should -Not -Match '\$unchanged = ' `
            -Because 'the single stale comparison is gone, not merely added to'
    }

    It 'and says which of the two brought a deployment about' {
        . (Join-Path $script:repoRoot 'tests' 'unit' '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1')
        $code | Should -Match 'no longer permit everything the product does' `
            -Because 'an operator reading the install output can tell a widening from a permission change'
    }
}
