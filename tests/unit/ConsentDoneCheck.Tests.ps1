#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CONSENT-DONE-CHECK-1: the install asks for admin consent only when it is not
# given. Before this, every install and every update ended with "One directory
# action is left" and the admin consent hand-off, also for an install whose
# administrator approved it weeks ago - so a customer could send an
# administrator to approve the product again for nothing.
#
# CONSENT-TOOL-LINK-1 (folded in): tools/Test-VmfConsentReadiness.ps1 ended by
# printing `az ad app permission admin-consent --id ...` for somebody else to
# run. Rule 12: nobody is handed a command. It prints the install's own
# hand-off now, and reads consent with the same function.
#
# Every function here is CALLED with az stubbed out, never only read: a source
# match passes while the branch it names is never taken.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:rightsPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1'
    $script:postPath   = Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1'
    $script:toolPath   = Join-Path $script:repoRoot 'tools' 'Test-VmfConsentReadiness.ps1'
    . (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1')
    . $script:rightsPath

    # Placeholder ids only (rule 13): no real tenant, application or person.
    $script:tenant    = '00000000-0000-0000-0000-000000000000'
    $script:client    = '11111111-2222-3333-4444-555555555555'
    $script:clientSp  = '22222222-0000-0000-0000-000000000001'
    $script:graphSp   = '22222222-0000-0000-0000-000000000002'
    $script:armSp     = '22222222-0000-0000-0000-000000000003'
    $script:otherSp   = '22222222-0000-0000-0000-000000000009'
    $script:personA   = '33333333-0000-0000-0000-00000000000a'
    $script:personB   = '33333333-0000-0000-0000-00000000000b'
    $script:graphApp  = '00000003-0000-0000-c000-000000000000'
    $script:armApp    = '797f4846-ba00-4fd7-ba43-dac1f8f63013'
    $script:graphAll  = 'AppRoleAssignment.ReadWrite.All Application.Read.All User.ReadBasic.All Group.Read.All'
    $script:url = "https://login.microsoftonline.com/$($script:tenant)/adminconsent?client_id=$($script:client)"

    # az: each key is a -like pattern over the joined arguments, and a '?' in
    # a URL is written [?] - a bare '?' matches any character, so 'me?' also
    # matched 'me/memberOf' and the answer depended on the hashtable's order.
    # The longest key is tried first, so the most exact one wins. A value
    # 'FAIL' answers with exit code 1 and nothing on stdout, as a refusal does.
    function global:az {
        $joined = $args -join ' '
        $global:VmfTestAzCalls += , $joined
        $global:LASTEXITCODE = 0
        foreach ($key in @($global:VmfTestAnswers.Keys | Sort-Object Length -Descending)) {
            if ($joined -like $key) {
                $value = $global:VmfTestAnswers[$key]
                if ($value -eq 'FAIL') { $global:LASTEXITCODE = 1; return $null }
                return $value
            }
        }
        $global:LASTEXITCODE = 1
        $null
    }

    function script:Set-Sp {
        param([string]$AppId, [string]$ObjectId)
        $global:VmfTestAnswers["ad sp list --filter appId eq '$AppId'*"] =
            if ($ObjectId) { (ConvertTo-Json -Compress -InputObject @(@{ id = $ObjectId; appId = $AppId })) } else { '[]' }
    }
    function script:New-Grant {
        param([string]$ConsentType, [string]$ResourceId, [string]$Scope, [string]$Principal = $null, [string]$ClientId = $script:clientSp)
        @{ clientId = $ClientId; consentType = $ConsentType; resourceId = $ResourceId; scope = $Scope; principalId = $Principal }
    }
    function script:Set-Grants {
        param([object[]]$Grants)
        $global:VmfTestAnswers["ad app permission list-grants --id $($script:client)*"] =
            if ($Grants.Count) { ConvertTo-Json -Compress -Depth 4 -InputObject @($Grants) } else { '[]' }
    }
    # The directory every test starts from: all three service principals exist.
    function script:Set-Directory {
        Set-Sp $script:client $script:clientSp
        Set-Sp $script:graphApp $script:graphSp
        Set-Sp $script:armApp $script:armSp
    }
    function script:Get-Closing {
        param($Consent, [string]$CanConsent = 'no', [string]$Workflow = 'off')
        (Get-VmfConsentClosing -Consent $Consent -CanConsent $CanConsent -Workflow $Workflow `
            -TenantId $script:tenant -ClientId $script:client -RegistrationName 'vmf-dashboard-example') -join "`n"
    }
}

Describe 'CONSENT-DONE-CHECK-1' {

AfterAll {
    Remove-Item 'function:\az' -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name VmfTestAzCalls, VmfTestAnswers -ErrorAction SilentlyContinue
}

BeforeEach {
    $global:VmfTestAnswers = @{}
    $global:VmfTestAzCalls = @()
}

Describe 'CONSENT-DONE-CHECK-1: the permissions it looks for are the registration''s own' {

    It 'every delegated permission in identity.bicep, by resource, and nothing else' {
        # Read with comments: the permission NAME is the comment after its id.
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $block = [regex]::Match($bicep, '(?s)requiredResourceAccess:\s*\[.*?\n  \]').Value
        $block | Should -Not -BeNullOrEmpty
        $found = @{}
        foreach ($part in ($block -split 'resourceAppId:\s*' | Select-Object -Skip 1)) {
            $var = [regex]::Match($part, '^\w+').Value
            $appId = [regex]::Match($bicep, "var $var = '([0-9a-f-]{36})'").Groups[1].Value
            $appId | Should -Not -BeNullOrEmpty -Because "var $var holds an application id"
            $found[$appId] = @([regex]::Matches($part, "type:\s*'Scope'\s*\}\s*\]?\s*//\s*(\S+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        }
        $found.Keys.Count | Should -Be 2
        @($script:VmfDashboardConsentScopes.Keys | Sort-Object) | Should -Be @($found.Keys | Sort-Object)
        foreach ($appId in $found.Keys) {
            @($script:VmfDashboardConsentScopes[$appId].Scopes | Sort-Object) | Should -Be $found[$appId]
        }
    }
}

Describe 'CONSENT-DONE-CHECK-1: what the directory says about admin consent' {

    BeforeEach { Set-Directory }

    It 'given: an organization-wide grant covers every permission, on the right resources' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp " $($script:graphAll) "),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'given'
        @($c.Missing).Count | Should -Be 0
    }

    It 'given, also when users approved it for themselves first' {
        Set-Grants @(
            (New-Grant 'Principal' $script:graphSp $script:graphAll $script:personA),
            (New-Grant 'AllPrincipals' $script:graphSp $script:graphAll),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'given'
    }

    It 'given, also when the scopes are split over two grants for one resource' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp 'AppRoleAssignment.ReadWrite.All Application.Read.All'),
            (New-Grant 'AllPrincipals' $script:graphSp 'User.ReadBasic.All Group.Read.All'),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'given'
    }

    It 'partial: one Microsoft Graph permission is missing, and it is named' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp 'AppRoleAssignment.ReadWrite.All Application.Read.All User.ReadBasic.All'),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'partial'
        @($c.Missing) | Should -Be @('Group.Read.All')
    }

    It 'a lookalike permission name is missing, not a match - each token is compared whole' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp 'AppRoleAssignment.ReadWrite.All Application.Read.All.Extra User.ReadBasic.AllX Group.Read.All'),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'partial'
        @($c.Missing | Sort-Object) | Should -Be @('Application.Read.All', 'User.ReadBasic.All')
    }

    It 'given, with a leading space and the extra sign-in scopes a real grant carries' {
        # The shape of a real organization-wide Graph grant, read in the lab.
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp ' AppRoleAssignment.ReadWrite.All Application.Read.All User.ReadBasic.All Group.Read.All openid profile offline_access'),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'given'
        @($c.Missing).Count | Should -Be 0
    }

    It 'partial: the Azure Service Management permission is missing' {
        Set-Grants @((New-Grant 'AllPrincipals' $script:graphSp $script:graphAll))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'partial'
        @($c.Missing) | Should -Be @('user_impersonation')
    }

    It 'a grant for another resource does not count, whatever its scopes say' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:otherSp $script:graphAll),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Not -Be 'given'
        @($c.Missing).Count | Should -Be 4
    }

    It 'a grant for another client does not count' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp $script:graphAll -ClientId $script:otherSp),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation' -ClientId $script:otherSp))
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'none'
    }

    It 'person-only: users approved it for themselves, and they are counted once each' {
        Set-Grants @(
            (New-Grant 'Principal' $script:graphSp $script:graphAll $script:personA),
            (New-Grant 'Principal' $script:armSp 'user_impersonation' $script:personA),
            (New-Grant 'Principal' $script:graphSp $script:graphAll $script:personB))
        $c = Get-VmfAdminConsentState -ClientId $script:client
        $c.State | Should -Be 'person-only'
        $c.People | Should -Be 2
    }

    It 'none: no grant at all' {
        Set-Grants @()
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'none'
    }

    It 'none: the dashboard has no service principal, and no grant is read' {
        Set-Sp $script:client ''
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'none'
        @($global:VmfTestAzCalls | Where-Object { $_ -like '*list-grants*' }).Count | Should -Be 0
    }

    It 'unknown: the service principal read is refused' {
        $global:VmfTestAnswers["ad sp list --filter appId eq '$($script:client)'*"] = 'FAIL'
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'unknown'
    }

    It 'unknown: the grant read is refused - never given, never none' {
        $global:VmfTestAnswers["ad app permission list-grants --id $($script:client)*"] = 'FAIL'
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'unknown'
    }

    It 'unknown: a resource service principal read is refused' {
        Set-Grants @(
            (New-Grant 'AllPrincipals' $script:graphSp $script:graphAll),
            (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))
        $global:VmfTestAnswers["ad sp list --filter appId eq '$($script:armApp)'*"] = 'FAIL'
        (Get-VmfAdminConsentState -ClientId $script:client).State | Should -Be 'unknown'
    }

    It 'unknown: no application id, and nothing is read' {
        foreach ($id in '', 'vmf-dashboard-example', "$($script:client)&x") {
            $global:VmfTestAzCalls = @()
            (Get-VmfAdminConsentState -ClientId $id).State | Should -Be 'unknown'
            $global:VmfTestAzCalls.Count | Should -Be 0
        }
    }

    It 'only reads, with no URL and so no ampersand (CLAUDE.md: cmd eats it)' {
        Set-Grants @((New-Grant 'AllPrincipals' $script:graphSp $script:graphAll))
        $null = Get-VmfAdminConsentState -ClientId $script:client
        $global:VmfTestAzCalls.Count | Should -BeGreaterThan 0
        foreach ($call in $global:VmfTestAzCalls) {
            $call | Should -Match '^ad (sp list|app permission list-grants) '
            $call | Should -Not -Match '&'
        }
    }
}

Describe 'CONSENT-DONE-CHECK-1: the end of the install' {

    It 'given: says so, and sends nobody to an administrator' {
        $text = Get-Closing ([pscustomobject]@{ State = 'given'; Missing = @(); People = 0 })
        $text | Should -Match 'Your organization has admin consent for the product'
        $text | Should -Not -Match 'directory action is left'
        $text | Should -Not -Match 'adminconsent'
        $text | Should -Not -Match 'Send this link'
        $text | Should -Not -Match 'Grant admin consent'
    }

    It 'none: the hand-off, as before' {
        $text = Get-Closing ([pscustomobject]@{ State = 'none'; Missing = @(); People = 0 })
        $text | Should -Match 'One directory action is left'
        $text | Should -Match 'Nobody gave admin consent for your organization'
        $text | Should -Match ([regex]::Escape($script:url))
    }

    It 'partial: names what is missing, and gives the hand-off' {
        $text = Get-Closing ([pscustomobject]@{ State = 'partial'; Missing = @('Group.Read.All'); People = 0 })
        $text | Should -Match 'does not include these permissions: Group\.Read\.All'
        $text | Should -Match ([regex]::Escape($script:url))
    }

    It 'person-only: works for the users who approved and nobody else, and gives the hand-off' {
        $one = Get-Closing ([pscustomobject]@{ State = 'person-only'; Missing = @(); People = 1 })
        $one | Should -Match 'One user approved the product for that user only'
        $one | Should -Match 'nobody else'
        $one | Should -Match ([regex]::Escape($script:url))
        $two = Get-Closing ([pscustomobject]@{ State = 'person-only'; Missing = @(); People = 2 })
        $two | Should -Match '2 users approved the product'
    }

    It 'unknown: says it could not read, and gives the hand-off - unknown is never given' {
        $text = Get-Closing ([pscustomobject]@{ State = 'unknown'; Missing = @(); People = 0 })
        $text | Should -Match 'could not read if your organization has admin consent'
        $text | Should -Match ([regex]::Escape($script:url))
    }

    It 'not read (a service principal ran the install): the hand-off, and no claim either way' {
        $text = Get-Closing $null 'unknown' 'unknown'
        $text | Should -Match 'One directory action is left'
        $text | Should -Match ([regex]::Escape($script:url))
        $text | Should -Not -Match 'Nobody gave'
        $text | Should -Not -Match 'could not read if your organization'
        $text | Should -Not -Match 'has admin consent for the product'
    }

    It 'every sentence is short enough for STE' {
        foreach ($state in 'given', 'partial', 'person-only', 'none', 'unknown') {
            $c = [pscustomobject]@{ State = $state; Missing = @('Group.Read.All'); People = 3 }
            foreach ($line in ((Get-Closing $c) -split "`n")) {
                foreach ($sentence in ($line -split '(?<=\.)\s+')) {
                    @($sentence.Trim() -split '\s+').Count | Should -BeLessOrEqual 25 -Because $sentence
                }
            }
        }
    }
}

Describe 'CONSENT-DONE-CHECK-1: postprovision reads it, for a person only (CD-1)' {

    BeforeAll {
        $script:postCode = Get-VmfCodeOnly -Path $script:postPath
        $script:postAst = [System.Management.Automation.Language.Parser]::ParseFile($script:postPath, [ref]$null, [ref]$null)
    }

    It 'prints the closing from the one function, and no copy of its words' {
        $script:postCode | Should -Match 'Get-VmfConsentClosing'
        $script:postCode | Should -Not -Match 'directory action is left'
        $script:postCode | Should -Not -Match 'Get-VmfConsentHandoff'
    }

    It 'reads the admin consent with the dashboard application id the install recorded' {
        $call = $script:postAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match '^Get-VmfAdminConsentState' }, $true)
        $call | Should -Not -BeNullOrEmpty
        "$call" | Should -Match '-ClientId \$dashboardAppId'
        $node = $call.Parent; $guard = $null
        while ($node) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $node; break }
            $node = $node.Parent
        }
        $guard | Should -Not -BeNullOrEmpty
        "$($guard.Clauses[0].Item1)" | Should -Match 'installerIsPerson'
    }

    It 'passes what it read to the closing' {
        $call = $script:postAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match '^Get-VmfConsentClosing' }, $true)
        "$call" | Should -Match '-Consent \$consent\b'
    }
}

Describe 'CONSENT-TOOL-LINK-1: the readiness check hands nobody a command' {

    BeforeAll {
        # The tool, run with az answering as a directory would. Returns what it printed.
        function script:Invoke-Tool {
            param([hashtable]$Extra = @{}, [string]$Name = '')
            $global:VmfTestAnswers = @{
                '*v1.0/me[?]*'                                = '{"id":"44444444-0000-0000-0000-000000000001","displayName":"Example User","userPrincipalName":"user@example.com"}'
                '*v1.0/organization[?]*'                      = "{""value"":[{""id"":""$($script:tenant)"",""displayName"":""Contoso""}]}"
                '*v1.0/me/memberOf*'                          = '{"value":[]}'
                '*v1.0/policies/authorizationPolicy*'         = '{"defaultUserRolePermissions":{"permissionGrantPoliciesAssigned":[]}}'
                '*v1.0/policies/adminConsentRequestPolicy*'   = '{"isEnabled":false}'
                '*v1.0/applications[?]*'                      = "{""value"":[{""displayName"":""vmf-dashboard-example"",""appId"":""$($script:client)""}]}"
            }
            Set-Directory
            foreach ($k in $Extra.Keys) { $global:VmfTestAnswers[$k] = $Extra[$k] }
            $toolArgs = @{}
            if ($Name) { $toolArgs.DashboardDisplayName = $Name }
            $all = @(& $script:toolPath @toolArgs 6>&1)
            @($all | ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } })
        }
        $script:given = @{ "ad app permission list-grants --id $($script:client)*" = (ConvertTo-Json -Compress -Depth 4 -InputObject @(
            (New-Grant 'AllPrincipals' $script:graphSp $script:graphAll), (New-Grant 'AllPrincipals' $script:armSp 'user_impersonation'))) }
    }

    It 'prints no az command for anybody to run' {
        foreach ($lines in @((Invoke-Tool), (Invoke-Tool -Name 'vmf-dashboard-example'))) {
            foreach ($line in $lines) { $line.Trim() | Should -Not -Match '^(az|azd|Connect-MgGraph|pwsh)\s' }
            ($lines -join "`n") | Should -Not -Match 'admin-consent --id'
        }
    }

    It 'before the install: names the role, and says the install ends with the link' {
        $text = (Invoke-Tool) -join "`n"
        $text | Should -Match 'Cloud Application Administrator'
        $text | Should -Match 'The install ends with a link'
        $text | Should -Not -Match 'adminconsent'
        $text | Should -Not -Match 'did not record the IDs'
    }

    It 'with the registration found and no admin consent: the same link the install prints' {
        $script:Extra = @{ "ad app permission list-grants --id $($script:client)*" = '[]' }
        $text = (Invoke-Tool -Extra $script:Extra -Name 'vmf-dashboard-example') -join "`n"
        $text | Should -Match 'Nobody gave admin consent for your organization'
        $text | Should -Match ([regex]::Escape($script:url))
    }

    It 'with admin consent given: says so, and no hand-off' {
        $text = (Invoke-Tool -Extra $script:given -Name 'vmf-dashboard-example') -join "`n"
        $text | Should -Match 'Your organization has admin consent for the product'
        $text | Should -Not -Match 'adminconsent'
        $text | Should -Not -Match 'Send this link'
    }

    It 'the request workflow it read goes to the hand-off' {
        $text = (Invoke-Tool -Extra @{ '*v1.0/policies/adminConsentRequestPolicy*' = '{"isEnabled":true}' }) -join "`n"
        $text | Should -Match 'Request approval'
    }

    It 'a person with a consent role is told to give it themselves' {
        $text = (Invoke-Tool -Extra @{ '*v1.0/me/memberOf*' = '{"value":[{"@odata.type":"#microsoft.graph.directoryRole","displayName":"Cloud Application Administrator"}]}' } -Name 'vmf-dashboard-example') -join "`n"
        $text | Should -Match 'You hold a role that can give admin consent'
    }

    It 'before the install, a person with a consent role: the install asks to give it (INSTALL-CONSENT-IN-FLOW-1)' {
        $text = (Invoke-Tool -Extra @{ '*v1.0/me/memberOf*' = '{"value":[{"@odata.type":"#microsoft.graph.directoryRole","displayName":"Global Administrator"}]}' }) -join "`n"
        $text | Should -Match 'it asks to give admin consent for your organization'
        $text | Should -Not -Match 'The install ends with a link'
    }
    It 'and it still changes nothing' {
        $null = Invoke-Tool -Name 'vmf-dashboard-example'
        foreach ($call in $global:VmfTestAzCalls) {
            $call | Should -Not -Match '--method (POST|PATCH|PUT|DELETE)'
            $call | Should -Not -Match 'admin-consent|grant |create|delete|update'
        }
    }

    It 'counts the roles from the one shared list' {
        $tool = Get-VmfCodeOnly -Path $script:toolPath
        $tool | Should -Match 'Resolve-VmfInstallerRights\.ps1'
        $tool | Should -Match 'VmfConsentAnyPermission'
        $tool | Should -Match 'VmfConsentDelegatedOnly'
        $tool | Should -Not -Match "'Privileged Role Administrator'"
    }
}
}
