#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERM-1: least-privilege custom roles, replacing the broad
# grants the lab accumulated - Contributor on a resource group and Reader at
# the TENANT ROOT management group, the latter granted only so SCOPE-1's
# management-group scanning could be tested.
#
# The point of this file is that the role is DERIVED, never hand-written.
# Every ARM call the tool can make lives behind the azureops boundary, so that
# folder is the specification. data/rbac-actions.json maps each operation to
# the actions it needs, the template builds the roles from that map, and the
# test below fails the build when an azureops call appears that the map has
# never heard of. Without that guard the role silently falls behind the code
# and somebody "fixes" it by reaching for Contributor again.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json

    # Every Az cmdlet the MODULE calls, not just the azureops folder: a role
    # that covers only part of the code is a role that fails mid-migration.
    # Get-AzVMUsage lives in a Public cmdlet, for instance - wrapped for retry
    # but outside the folder - and the role still has to permit it.
    $script:azureopsCmdlets = @(
        Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter *.ps1 -Recurse |
            ForEach-Object {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                    ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $_ -match '^(Get|Set|New|Remove|Update|Start|Stop|Restart|Invoke)-Az' }
            }
    ) | Sort-Object -Unique
}

Describe 'PERM-1: the role map covers what the tool actually does' {
    It 'every Azure operation behind the boundary is accounted for' {
        # THE guard. A new azureops call with no entry here means the custom
        # role would not permit it, and the failure would surface as a
        # mid-migration authorization error on a customer machine.
        $mapped = @($script:rbac.operations | ForEach-Object { $_.cmdlet })
        $unmapped = @($script:azureopsCmdlets | Where-Object { $_ -notin $mapped })
        $unmapped -join ', ' | Should -BeNullOrEmpty -Because 'each of these needs an entry in data/rbac-actions.json'
    }

    It 'the map does not carry operations the tool no longer performs' {
        # Dead entries are how a "least privilege" role quietly stops being one.
        $stale = @($script:rbac.operations | Where-Object { $_.cmdlet -notin $script:azureopsCmdlets } |
            ForEach-Object { $_.cmdlet })
        $stale -join ', ' | Should -BeNullOrEmpty
    }

    It 'every entry says which role needs it and why' {
        foreach ($op in @($script:rbac.operations)) {
            $op.role | Should -BeIn @('assess', 'execute', 'none')
            $op.why | Should -Not -BeNullOrEmpty -Because "$($op.cmdlet) must say what it is for"
            if ($op.role -ne 'none') {
                @($op.actions).Count | Should -BeGreaterThan 0 -Because "$($op.cmdlet) claims a role but names no actions"
            }
        }
    }
}

Describe 'PERM-1: assess can only look, execute can act' {
    BeforeAll {
        $script:assessActions = @($script:rbac.operations | Where-Object { $_.role -eq 'assess' } |
            ForEach-Object { $_.actions }) | Sort-Object -Unique
        $script:executeActions = @($script:rbac.operations | Where-Object { $_.role -eq 'execute' } |
            ForEach-Object { $_.actions }) | Sort-Object -Unique
    }

    It 'the assess role contains NOTHING that can change a machine' {
        # This is what makes it safe to grant broadly - the whole point of
        # splitting the roles. If a write leaks in here, scanning a whole
        # management group stops being harmless.
        $writes = @($script:assessActions | Where-Object {
            $_ -match '/(write|delete|action)$' -and $_ -notmatch 'ResourceGraph|/read$'
        })
        $writes -join ', ' | Should -BeNullOrEmpty -Because 'assess is read-only by definition'
    }

    It 'the assess role can still read everything the assessment needs' {
        foreach ($needed in 'Microsoft.Compute/virtualMachines/read',
                            'Microsoft.Compute/disks/read',
                            'Microsoft.Network/networkInterfaces/read',
                            'Microsoft.Compute/skus/read') {
            $script:assessActions | Should -Contain $needed
        }
    }

    It 'the execute role can do the things a migration actually requires' {
        foreach ($needed in 'Microsoft.Compute/virtualMachines/write',
                            'Microsoft.Compute/virtualMachines/deallocate/action',
                            'Microsoft.Compute/virtualMachines/start/action',
                            'Microsoft.Compute/snapshots/write',
                            'Microsoft.Compute/disks/write',
                            'Microsoft.Compute/virtualMachines/runCommand/action') {
            $script:executeActions | Should -Contain $needed
        }
    }

    It 'NEITHER role can hand out permissions or rewrite policy' {
        # The two escalation paths that turn a scoped role into an unscoped
        # one. Nothing in azureops needs either.
        foreach ($forbidden in 'Microsoft.Authorization/roleAssignments/write',
                               'Microsoft.Authorization/roleDefinitions/write',
                               'Microsoft.Authorization/policyAssignments/write') {
            $script:assessActions | Should -Not -Contain $forbidden
            $script:executeActions | Should -Not -Contain $forbidden
        }
    }

    It 'neither role is a wildcard in disguise' {
        foreach ($a in @($script:assessActions) + @($script:executeActions)) {
            $a | Should -Not -Be '*'
            $a | Should -Not -Match '^Microsoft\.[A-Za-z]+/\*$' -Because "'$a' grants a whole provider"
        }
    }
}

Describe 'PERM-1: the template builds the roles from that one map' {
    BeforeAll {
        $script:roles = Get-Content (Join-Path $script:repoRoot 'infra' 'roles.bicep') -Raw
    }

    It 'loads the map rather than restating the actions' {
        # Two lists that must agree is one list too many.
        $script:roles | Should -Match "loadJsonContent\("
        $script:roles | Should -Match 'rbac-actions\.json'
    }

    It 'declares both roles' {
        $script:roles | Should -Match 'assess'
        $script:roles | Should -Match 'execute'
        $script:roles | Should -Match 'Microsoft\.Authorization/roleDefinitions'
    }

    It 'the execute role includes what assess can do' {
        # A migration reads before it writes; a separate read grant would just
        # be another thing to forget.
        $script:roles | Should -Match 'union\('
    }

    It 'the scope is a parameter, because the user chooses it' {
        # The decision: onboarding grants at a level the user sets,
        # not whatever the lab happened to need.
        $script:roles | Should -Match 'param assignableScope'
    }
}

Describe 'PERM-1: WHERE the role definition lives decides where it can be granted' {
    # A custom role can only be assigned at or BELOW its
    # ROLES-1: there is ONE pair of definitions for a subscription, and the
    # list of scopes they may be granted at GROWS.
    #
    # This block used to assert the opposite, because the code did: it said a
    # role's assignable scope "is fixed when the definition is created" and
    # that a subscription role "can NEVER be granted at a management group",
    # and there was a second template to work around it.
    #
    # MEASURED 2026-09-07 with a throwaway role: adding a management group to
    # assignableScopes was accepted, the role kept its id, the grant it had
    # already made survived, and it could then be granted at that group. So the
    # workaround is gone and these tests hold the shape that replaced it.
    BeforeAll {
        $script:sub = Get-Content (Join-Path $script:repoRoot 'infra' 'roles.bicep') -Raw
        $script:grant = Get-Content (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1') -Raw
        $script:helper = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1') -Raw
    }

    It 'there is ONE template, at the subscription - the management-group twin is gone' {
        $script:sub | Should -Match "targetScope = 'subscription'"
        Test-Path (Join-Path $script:repoRoot 'infra' 'roles-mg.bicep') | Should -BeFalse -Because 'a subscription role can be granted at a management group, so the second template had no reason to exist'
    }

    It 'the scopes are a LIST, so onboarding widens rather than duplicates' {
        $script:sub | Should -Match 'param assignableScopes array'
        $script:sub | Should -Match 'assignableScopes: assignableScopes'
    }

    It 'and the role identity comes from the SUBSCRIPTION, never from that list' {
        # This is the fix. Keyed to the scope list, adding a management group
        # produced a SECOND pair under a second name, and the first pair's
        # assignments pointed at a definition nothing used any more.
        $script:sub | Should -Match 'var roleKey = subscription\(\)\.id'
        foreach ($role in 'vmf-assess-role', 'vmf-execute-role') {
            $script:sub | Should -Match ([regex]::Escape("guid(roleKey, '$role')"))
        }
        $script:sub | Should -Not -Match 'guid\(assignableScopes'
        $script:sub | Should -Not -Match 'uniqueString\(assignableScopes'
    }

    It 'the union is computed in ONE place, and refuses a second management group' {
        # Azure allows only one management group in a custom role. Refusing here
        # with the two real options beats an ARM error that names a limit and no
        # way forward.
        $script:helper | Should -Match 'function Get-VmfScopeUnion'
        $script:helper | Should -Match 'may name only ONE management group'
        $script:helper | Should -Match 'contains both'
    }

    It 'widening passes the WHOLE list, because a deployment cannot add to one' {
        # Passing only the new scope would drop the others and break every
        # grant made through them.
        $script:helper | Should -Match 'function Set-VmfRoleScopes'
        $script:helper | Should -Match 'Get-VmfScopeUnion -Existing'
    }

    It 'both the install and onboarding go through that one place' {
        $pre = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
        foreach ($caller in @($pre, $script:grant)) {
            $caller | Should -Match 'Resolve-VmfRoleScopes\.ps1'
            $caller | Should -Match 'Set-VmfRoleScopes'
        }
        # and neither creates a definition at a management group any more
        $code = (Get-VmfCodeOnly -Language PowerShell -Text $script:grant)
        $code | Should -Not -Match 'az deployment mg create'
        $code | Should -Not -Match 'roles-mg'
    }

    It 'a role is found by name AND by living in this subscription, not by name alone' {
        # A bare name match also finds roles inherited from a management group
        # above, and roles another install made. There is no defined order to
        # choose from, so the wrong definition can be granted silently.
        $script:helper | Should -Match 'function Get-VmfSubscriptionRoles'
        $script:helper | Should -Match '\$definedHere = "/subscriptions/\$SubscriptionId/providers/Microsoft\.Authorization/roleDefinitions/"'
        $script:helper | Should -Match '\$_\.id -like "\$definedHere\*"'
        $script:grant | Should -Match 'Get-VmfSubscriptionRoles -SubscriptionId'
    }
}

Describe 'INSTALL-ROLES-1: the FIRST install, where the roles do not exist yet' {
    # Found 2026-09-10, running azd up in another environment:
    #
    #   Get-VmfSubscriptionRoles: infra/Resolve-VmfRoleScopes.ps1:101
    #   | Index was outside the bounds of the array.
    #   ERROR: step "cmdhook-preprovision" failed
    #
    # infra/hooks/AzdHooks.ps1 sets Set-StrictMode -Version Latest, and strict
    # mode is INHERITED BY CHILD SCOPES, so it is live inside these helpers.
    # Under it, `@()[0]` throws instead of returning $null - and `@()` is what a
    # subscription with no VMF roles returns. So the install failed for every
    # first-time customer, and never here, because this subscription has had the
    # pair since ROLES-1.
    #
    # These run the real function under real strict mode. A source match could
    # not tell the two behaviours apart.

    BeforeAll {
        $script:rolesHelperPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1'
        $script:suffixHelperPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfSuffix.ps1'
    }

    It 'returns nothing rather than throwing when the subscription has no custom roles' {
        $run = {
            param($helperPath)
            Set-StrictMode -Version Latest
            $global:LASTEXITCODE = 0
            function az { '[]' }        # a subscription with no custom roles at all
            . $helperPath
            Get-VmfSubscriptionRoles -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }
        $found = & $run $script:rolesHelperPath
        $found.Assess | Should -BeNullOrEmpty
        $found.Execute | Should -BeNullOrEmpty
    }

    It 'and when custom roles exist but none of them is ours' {
        # The other empty-set shape: az answers, the list is not empty, and the
        # filter matches nothing.
        $run = {
            param($helperPath)
            Set-StrictMode -Version Latest
            $global:LASTEXITCODE = 0
            function az { '[{"id":"/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/r","roleName":"Somebody Elses Role"}]' }
            . $helperPath
            Get-VmfSubscriptionRoles -SubscriptionId 's'
        }
        $found = & $run $script:rolesHelperPath
        $found.Assess | Should -BeNullOrEmpty
    }

    It 'and it still finds the pair when they DO exist' {
        # The fix must not turn the working case into nothing.
        $run = {
            param($helperPath)
            Set-StrictMode -Version Latest
            $global:LASTEXITCODE = 0
            function az {
                '[{"id":"/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/a","roleName":"VMF Assessment"},' +
                '{"id":"/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/b","roleName":"VMF Migration"}]'
            }
            . $helperPath
            Get-VmfSubscriptionRoles -SubscriptionId 's'
        }
        $found = & $run $script:rolesHelperPath
        $found.Assess.roleName | Should -Be 'VMF Assessment'
        $found.Execute.roleName | Should -Be 'VMF Migration'
    }

    It 'the engine image lookup survives a job with no containers' {
        # Same defect class, same install path, one file over.
        $run = {
            param($helperPath)
            Set-StrictMode -Version Latest
            $global:LASTEXITCODE = 0
            function az { '{"properties":{"template":{"containers":[]}}}' }
            . $helperPath
            Resolve-VmfEngineImage -ResourceGroup 'rg' -JobName 'job'
        }
        (& $run $script:suffixHelperPath) | Should -BeNullOrEmpty
    }

    It 'and no helper on the install path indexes an array with [0]' {
        # The rule, not the instance. Strict mode makes every one of these a
        # first-install failure waiting for the right empty list.
        foreach ($file in @($script:rolesHelperPath, $script:suffixHelperPath)) {
            (Get-Content $file -Raw) | Should -Not -Match '\)\[0\]' -Because "$(Split-Path $file -Leaf) runs under Set-StrictMode -Version Latest"
        }
    }
}
