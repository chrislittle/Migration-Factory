#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SECURITY-FAQ-1 (MANUAL-REVIEW-1, the last part): the security and
# permissions questions page says what the code, the templates and the
# permission map say, and links to the pages that hold the detail.
#
# Each fact the page states is held here to its source, so a change to the
# source that makes the page false fails the build.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:faqPath = Join-Path $script:manual 'technical' 'security-faq.md'
    $script:faq = Get-Content $script:faqPath -Raw
    $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
    $script:actions = @($rbac.operations | ForEach-Object { @($_.actions) } | Sort-Object -Unique)
    $script:platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $script:slug = {
        param($Heading)
        (($Heading.ToLowerInvariant() -replace '[^a-z0-9 -]', '') -replace ' ', '-')
    }
}

Describe 'SECURITY-FAQ-1: the page is in the manual' {

    It 'is in the sidebar, after Security' {
        $sidebar = Get-Content (Join-Path $script:manual '_sidebar.md') -Raw
        $sidebar | Should -Match ([regex]::Escape('[Security](/technical/security.md)') + '\s+- \[Security and permissions questions\]\(/technical/security-faq\.md\)')
    }

    It 'answers the twelve questions, each as a heading' {
        @([regex]::Matches($script:faq, '(?m)^## .+\?\s*$')).Count | Should -Be 12
    }

    It 'every link goes to a page of the manual, and every anchor to a heading of that page' {
        $links = @([regex]::Matches($script:faq, '\]\(([^)#]+\.md)(#[^)]+)?\)'))
        $links.Count | Should -BeGreaterThan 10
        foreach ($m in $links) {
            $target = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $script:faqPath) $m.Groups[1].Value))
            Test-Path $target | Should -BeTrue -Because $m.Value
            if ($m.Groups[2].Success) {
                $anchor = $m.Groups[2].Value.Substring(1)
                $slugs = @(Get-Content $target | Where-Object { $_ -match '^#{1,4} ' } | ForEach-Object { & $script:slug ($_ -replace '^#+ ', '') })
                $slugs | Should -Contain $anchor -Because $m.Value
            }
        }
    }
}

Describe 'SECURITY-FAQ-1: each answer is the fact of the code' {

    It 'the actions the page says the roles do not hold are not in the permission map' {
        foreach ($a in 'Microsoft.Compute/virtualMachines/delete', 'Microsoft.Authorization/roleAssignments/write', 'Microsoft.Authorization/roleDefinitions/write') {
            $script:faq | Should -Match ([regex]::Escape("``$a``")) -Because $a
            $script:actions | Should -Not -Contain $a
        }
        $script:faq | Should -Match 'hold only `Microsoft\.Compute/virtualMachines/extensions/read`'
        @($script:actions | Where-Object { $_ -like 'Microsoft.Compute/virtualMachines/extensions/*' -and $_ -ne 'Microsoft.Compute/virtualMachines/extensions/read' }) | Should -BeNullOrEmpty
        $script:faq | Should -Match 'never registers it'
        @($script:actions | Where-Object { $_ -like 'Microsoft.Features/*' -and $_ -ne 'Microsoft.Features/providers/features/read' }) | Should -BeNullOrEmpty
    }

    It 'every other action the page names is in the permission map' {
        $notHeld = 'Microsoft.Compute/virtualMachines/delete', 'Microsoft.Authorization/roleAssignments/write', 'Microsoft.Authorization/roleDefinitions/write'
        $named = @([regex]::Matches($script:faq, '`(Microsoft\.[A-Za-z]+/[A-Za-z/]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $named.Count | Should -BeGreaterThan 5
        foreach ($a in $named) {
            if ($a -notin $notHeld) { $script:actions | Should -Contain $a -Because $a }
        }
    }

    It 'the templates give the product identities only the built-in roles reviewed here, none of which can assign roles (infra/*.bicep)' {
        # Each built-in role a product template assigns, by its id. A new one
        # fails here until somebody checks that it cannot assign roles and adds it.
        $allowed = @{
            'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
            'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Storage Blob Data Contributor'
            'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' = 'Storage Blob Data Owner'
            '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Storage Blob Data Reader'
            '974c5e8b-45b9-4653-ba55-5f855dd0fb88' = 'Storage Queue Data Contributor'
            '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' = 'Storage Table Data Contributor'
            '7f951dda-4ed3-4680-a7ca-43fe172d538d' = 'AcrPull'
            'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
            '3913510d-42f4-4e42-8a64-420c390055eb' = 'Monitoring Metrics Publisher'
        }
        # The CI runner templates are not part of an install.
        $templates = @(Get-ChildItem (Join-Path $script:repoRoot 'infra') -Filter *.bicep | Where-Object Name -NotLike 'ci-*')
        $templates.Count | Should -BeGreaterThan 3
        $found = 0
        foreach ($tpl in $templates) {
            $code = Get-VmfCodeOnly -Path $tpl.FullName -Language CStyle
            $vars = @{}
            foreach ($m in [regex]::Matches($code, "(?m)^\s*var\s+(\w+)\s*=\s*'([0-9a-f-]{36})'")) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value }
            $refs = @([regex]::Matches($code, "roleDefinitionIdOrName:\s*(\S+)") | ForEach-Object { $_.Groups[1].Value }) +
                    @([regex]::Matches($code, "roleDefinitionId:\s*subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions',\s*(\w+)\)") | ForEach-Object { $_.Groups[1].Value })
            # Any other form of role reference is not read by this test, so it fails.
            @([regex]::Matches($code, 'roleDefinitionId(OrName)?:')).Count | Should -Be $refs.Count -Because "$($tpl.Name): every role reference has a form this test reads"
            foreach ($r in $refs) {
                $vars.ContainsKey($r) | Should -BeTrue -Because "$($tpl.Name): $r is a variable holding a built-in role id"
                $allowed.ContainsKey($vars[$r]) | Should -BeTrue -Because "$($tpl.Name): $r ($($vars[$r])) is a reviewed role"
                $found++
            }
        }
        $found | Should -BeGreaterThan 10
    }

    It 'the install and the Admin page assign only the two custom roles (Grant-VmfAccess.ps1, access.js)' {
        $grant = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
        $creates = @([regex]::Matches($grant, 'az role assignment create(?:[^\r\n`]|`\s*\r?\n)*'))
        $creates.Count | Should -Be 1
        $creates[0].Value | Should -Match '--role \$roleId\b'
        @([regex]::Matches($grant, '\$roleId\s*=\s*([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() }) | Should -Be @('Resolve-RoleId -NamePrefix $RoleName')
        $grant | Should -Match '\$role = if \(\$NamePrefix -like ''VMF Assessment\*''\) \{ \$found\.Assess \} else \{ \$found\.Execute \}'
        foreach ($hook in Get-ChildItem (Join-Path $script:repoRoot 'infra' 'hooks') -Filter *.ps1) {
            Get-VmfCodeOnly -Path $hook.FullName | Should -Not -Match 'role assignment create|New-AzRoleAssignment|roleAssignments/' -Because $hook.Name
        }
        $access = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.js')
        $values = @([regex]::Matches($access, 'roleDefinitionId:\s*([^,\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ -notmatch 'def-' })
        $values.Count | Should -BeGreaterThan 2
        foreach ($v in $values) {
            $v | Should -BeIn @("level === 'migrate' ? ids.migrateRoleId : ids.assessRoleId", 'ids.assessRoleId', 'part.roleDefinitionId', 'roleId') -Because $v
        }
        # roleId: the engine's role is the custom role definition read by its configured id.
        $access | Should -Match ([regex]::Escape("const roleId = part.who === 'engine' ? def.id : part.roleDefinitionId;"))
        $access | Should -Match ([regex]::Escape('def = await vmfRoleDefinition(mode);'))
        $access | Should -Match ([regex]::Escape("return mode === 'migrate' ? (cfg.migrateRoleId || '') : (cfg.assessRoleId || '');"))
        $script:faq | Should -Match 'No pipeline holds a role in the product'
    }

    It 'the page says each retention the template sets, and the 90 days Microsoft keeps the telemetry tables (infra/platform.bicep, LOG-RETENTION-READ-1)' {
        $script:platform | Should -Match 'dataRetention: 30\b'
        $script:platform | Should -Match 'retentionInDays: 90\b'
        $script:faq | Should -Match 'Log Analytics workspace of the product to keep data 30 days'
        $script:faq | Should -Match 'keeps the tables of Application Insights 90 days'
        $script:faq | Should -Match 'install also sets 90 days on the Application Insights resource'
        $script:faq | Should -Not -Match '(?i)not read yet'
    }

    It 'every host the engine, the service or a guest script calls is in the network table' {
        $start = $script:faq.IndexOf('## What does the product need from the network?')
        $start | Should -BeGreaterThan 0
        $end = $script:faq.IndexOf("`n## ", $start + 5)
        $section = $script:faq.Substring($start, $end - $start)
        # Not addresses the product connects to: a token audience and a claim type.
        $notCalled = @{
            'storage.azure.com'     = "-ResourceUrl 'https://storage.azure.com/'"
            'schemas.microsoft.com' = "'http://schemas.microsoft.com/ws/2008/06/identity/claims/role'"
        }
        $roots = 'src/VmMigrationFactory', 'src/guest', 'src/facade', 'docker'
        $files = @(foreach ($r in $roots) { Get-ChildItem (Join-Path $script:repoRoot $r) -Recurse -File -Include *.ps1, *.psm1, *.sh })
        $hosts = @{}
        foreach ($file in $files) {
            $code = Get-VmfCodeOnly -Path $file.FullName
            # A host written after a variable keeps its literal part: https://$account.blob.core.windows.net
            foreach ($m in [regex]::Matches($code, 'https?://(?:\$\([^)]*\)|\$\w+|\{\d\})?([A-Za-z0-9][A-Za-z0-9.-]*|\.[A-Za-z0-9.-]+)')) {
                $h = $m.Groups[1].Value.Trim('.')
                if ($h -notmatch '\.') { continue }
                if ($notCalled.ContainsKey($h)) {
                    # Every use is the stated form, so none of them is a call.
                    @([regex]::Matches($code, 'https?://' + [regex]::Escape($h))).Count |
                        Should -Be @([regex]::Matches($code, [regex]::Escape($notCalled[$h]))).Count -Because "$($file.Name): $h is only a name, never an address"
                    continue
                }
                $hosts[$h] = $file.Name
            }
        }
        $hosts.Keys | Should -Contain 'prices.azure.com'
        $hosts.Keys | Should -Contain 'management.azure.com'
        foreach ($h in $hosts.Keys) {
            $section | Should -Match ([regex]::Escape($h)) -Because "$($hosts[$h]) calls $h"
        }
    }

    It 'the MANA driver comes from the host the page names (Install-ManaDriver.ps1)' {
        $guest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-ManaDriver.ps1') -Raw
        $guest | Should -Match "PACKAGE_URL = 'https://download\.microsoft\.com/"
        $script:faq | Should -Match 'download\.microsoft\.com over HTTPS'
    }

    It 'a guest script runs only when its hash matches the manifest (Get-VmfGuestScript)' {
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Get-VmfGuestScript.ps1') -Raw
        $code | Should -Match 'if \(\$actualHash -ne \$entry\.sha256\)'
        $script:faq | Should -Match 'When they are different, the engine does not run the script'
    }

    It 'no answer says that a move, a rollback or a restore rebuilds a machine (REBUILD-REMOVE-1)' {
        $script:faq | Should -Not -Match '(?i)\b(is|are|gets|get) rebuilt\b|\bwhich machines are rebuilt'
        $script:faq | Should -Match 'No rollback and no restore rebuilds a machine'
    }

    It 'the service telemetry and the engine logs keep the retention the pages name (LOG-RETENTION-READ-1)' {
        # Microsoft, "Manage data retention in a Log Analytics workspace", Log tables
        # with 90-day default retention (ms.date 2026-09-02): "Tables related to
        # Application Insights resources also keep data for 90 days at no charge."
        # Every other Analytics table inherits the workspace default (30 here).
        # The pages hold only while the install sets no retention of its own on
        # a table, so a table setting in any install template fails here.
        foreach ($tpl in @(Get-ChildItem (Join-Path $script:repoRoot 'infra') -Filter *.bicep | Where-Object Name -NotLike 'ci-*')) {
            $code = Get-VmfCodeOnly -Path $tpl.FullName -Language CStyle
            $code | Should -Not -Match '(?i)workspaces/tables|totalRetentionInDays|\btables\s*:' -Because "$($tpl.Name) sets no table retention"
        }
        # The component is workspace-based: its tables are in the product's workspace.
        $script:platform | Should -Match '(?s)module appInsights [^\r\n]*\{.{0,200}workspaceResourceId: logsResourceId'
        $runStore = Get-Content (Join-Path $script:manual 'technical' 'run-store.md') -Raw
        $runStore | Should -Match 'The Log Analytics workspace keeps the logs of the engine 30 days\.'
        $runStore | Should -Match 'It keeps the tables of Application Insights 90 days\.'
    }

    It 'no answer says the in-place upgrade (Preview) needs the subscription (PREVIEW-ACCESS-WORDS-1)' {
        $script:faq | Should -Not -Match '(?i)Preview\)? needs .{0,20}subscription|does not reach'
    }
}

Describe 'SECURITY-HOSTKEYS-WORDS-1: the pages name the host keys of the Functions host, and each fact holds' {

    BeforeAll {
        $script:security = Get-Content (Join-Path $script:manual 'technical' 'security.md') -Raw
        $script:permissionsPage = Get-Content (Join-Path $script:manual 'reference' 'permissions.md') -Raw
        $script:platformCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Language CStyle
    }

    It 'Security, the permissions reference and this page name the host keys and their container' {
        foreach ($pair in @(@('security.md', $script:security), @('permissions.md', $script:permissionsPage), @('security-faq.md', $script:faq))) {
            $pair[1] | Should -Match 'Functions host of the service' -Because $pair[0]
            $pair[1] | Should -Match 'host keys' -Because $pair[0]
            $pair[1] | Should -Match '`azure-webjobs-secrets`' -Because $pair[0]
            # The old words said the two logging settings were all that held a key.
            $pair[1] | Should -Not -Match '(?i)^Two logging settings hold a key\.|Azure writes two logging settings that hold a key' -Because $pair[0]
        }
    }

    It 'the install gives a data role on azure-webjobs-secrets only to the service (infra/platform.bicep)' {
        $m = [regex]::Match($script:platformCode, "(?s)name: 'azure-webjobs-secrets'\s*roleAssignments: \[(.*?)\]")
        $m.Success | Should -BeTrue
        $principals = @([regex]::Matches($m.Groups[1].Value, 'principalId:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
        $principals | Should -Be @('facade.outputs.systemAssignedMIPrincipalId!')
        $script:security | Should -Match 'The install gives a data role on that container only to the service\.'
    }

    It 'the host keeps its keys in the run store: no other secret storage is set (infra/*.bicep)' {
        foreach ($tpl in @(Get-ChildItem (Join-Path $script:repoRoot 'infra') -Filter *.bicep | Where-Object Name -NotLike 'ci-*')) {
            Get-VmfCodeOnly -Path $tpl.FullName -Language CStyle | Should -Not -Match 'AzureWebJobsSecretStorage' -Because $tpl.Name
        }
        $script:platformCode | Should -Match "AzureWebJobsStorage__credential: 'managedidentity'"
    }

    It 'no function of the service accepts a key: each HTTP function is anonymous, and App Service authentication refuses a call with no sign-in' {
        $functions = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Filter function.json)
        $http = 0
        foreach ($fn in $functions) {
            $bindings = @((Get-Content $fn.FullName -Raw | ConvertFrom-Json).bindings)
            foreach ($b in @($bindings | Where-Object type -eq 'httpTrigger')) {
                $b.authLevel | Should -Be 'anonymous' -Because $fn.Directory.Name
                $http++
            }
        }
        $http | Should -BeGreaterThan 20
        $script:platformCode | Should -Match "(?s)name: 'authsettingsV2'.{0,200}requireAuthentication: true\s+unauthenticatedClientAction: 'Return401'"
        # No path is left out of the sign-in.
        $script:platformCode | Should -Not -Match '(?i)excludedPaths'
        $script:security | Should -Match 'No function of the service accepts a key\.'
        $script:security | Should -Match 'App Service authentication refuses each call that has no Microsoft Entra ID sign-in'
    }

    It 'Security says what is not measured: an /admin call with the master key and no sign-in' {
        $script:security | Should -Match 'The master key also opens the `/admin` endpoints of the Functions host\.'
        $script:security | Should -Match 'No test measured this on an install for the `/admin` endpoints\.'
    }

    It 'no identity of the product can list the host keys, and Security names who can (rbac-actions.json, infra/platform.bicep)' {
        @($script:actions | Where-Object { $_ -like 'Microsoft.Web/*' }) | Should -BeNullOrEmpty
        # Contributor holds every Microsoft.Web action. The install gives it once: to the service, on the engine job.
        @([regex]::Matches($script:platformCode, 'roleDefinitionIdOrName:\s*roleContributor\b')).Count | Should -Be 1
        $script:platformCode | Should -Match '(?s)name: engineJobName.{0,1500}roleDefinitionIdOrName: roleContributor'
        $script:security | Should -Match '`Microsoft\.Web/sites/host/listkeys/action`'
        $script:security | Should -Match 'No identity of the product holds this action\.'
        $script:security | Should -Match 'Owner and Contributor hold this action\.'
    }
}
