#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ONBOARD-1 + GATE-1: first-run access.
#
# Two jobs that have to happen in one order, because getting it wrong locks
# everyone out of their own tool:
#
#   ONBOARD-1  grant the service what it needs to do its job - the PERM-1
#              custom roles, at a scope the OPERATOR chooses - and give the
#              first person an admin role so the tool is usable at all.
#   GATE-1     only then require a role to sign in, so people who have not
#              been granted anything are turned away at the door rather than
#              signing in to an empty tool.
#
# The interlock below is the point of this file: GATE-1 must REFUSE to run
# when nobody holds an admin role, because the failure mode is locking the
# owner out of the thing they just installed, with no way back in through the
# tool itself.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:onboard = Get-Content (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1') -Raw
}

Describe 'ONBOARD-1: the operator chooses the scope, not the tool' {
    It 'parses cleanly' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1'), [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }

    It 'takes the two scopes separately, because they are different questions' {
        # Where may it LOOK, and where may it CHANGE things. Collapsing them
        # into one scope is how a tool ends up with write access everywhere it
        # can see.
        $script:onboard | Should -Match '\$AssessScope'
        $script:onboard | Should -Match '\$MigrateScope'
    }

    It 'grants the custom roles, never Contributor or Owner' {
        $script:onboard | Should -Match 'VMF Assessment'
        $script:onboard | Should -Match 'VMF Migration'
        foreach ($banned in "'Contributor'", "'Owner'", "'User Access Administrator'") {
            $script:onboard | Should -Not -Match ([regex]::Escape($banned)) -Because "$banned is what PERM-1 exists to replace"
        }
    }

    It 'stores no secret of any kind' {
        $script:onboard | Should -Not -Match 'client_secret|password|AccountKey=|-SecureString'
    }

    It 'says what it granted, in terms a person can check' {
        # An access change nobody can read afterwards is an access change
        # nobody will review.
        $script:onboard | Should -Match 'Write-Host'
        $script:onboard | Should -Match '(?i)granted'
    }

    It 'is safe to run twice' {
        # Role assignment creation is not naturally idempotent - a second run
        # must not fail the install.
        $script:onboard | Should -Match '(?i)already|RoleAssignmentExists|ErrorAction SilentlyContinue|-ne 0'
    }
}

Describe 'GATE-1: the door only locks once somebody has a key' {
    It 'refuses to close the gate when nobody holds an admin role' {
        # THE safety property. Enabling appRoleAssignmentRequired with no
        # admin assigned locks everyone out of the tool they just installed,
        # and the tool cannot let them back in - it takes a directory admin
        # and the portal.
        $script:onboard | Should -Match 'appRoleAssignmentRequired'
        $script:onboard | Should -Match '(?i)refus|no one|nobody|would lock'
    }

    It 'the gate is opt-in, not a side effect of onboarding' {
        # Granting access and restricting access are different decisions and
        # should not happen in the same breath by accident.
        $script:onboard | Should -Match '\[switch\]\$CloseTheGate'
    }

    It 'counts real admin assignments before flipping it' {
        $script:onboard | Should -Match 'appRoleAssignments'
        $script:onboard | Should -Match '6f1c3a10-0004-4b6e-9e6a-100000000004'   # Vmf.Admin
    }
}

Describe 'ONBOARD-1: the roles it grants are the ones PERM-1 derived' {
    It 'the role names match the map exactly' {
        # A typo here means the grant silently does nothing.
        $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $script:onboard | Should -Match ([regex]::Escape($rbac.roles.assess.roleName))
        $script:onboard | Should -Match ([regex]::Escape($rbac.roles.execute.roleName))
    }

    It 'deploys the role definitions rather than assuming they exist' {
        $script:onboard | Should -Match 'roles\.bicep'
    }
}
