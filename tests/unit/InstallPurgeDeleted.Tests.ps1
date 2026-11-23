#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-PURGE-DELETED-1: the install permanently deletes ONLY a deleted
# registration that holds the unique name it is about to create.
#
# MEASURED 2026-11-22 (the INSTALL-ADOPT-OWNER-1 walk): a test registration
# named 'vmf-api-<env>' was made and deleted. The next fresh azd up printed
# "removing a deleted registration still holding the name 'vmf-api-<env>'" and
# purged it from Entra's deleted items - matched by DISPLAY NAME alone, so it
# purges a deleted registration somebody else made and may want back.
#
# MEASURED 2026-09-09 (identity.bicep): a deleted registration blocks a
# deployment only through its UNIQUE NAME. Same uniqueName fails; a new
# uniqueName with the same displayName succeeds. And the uniqueName is
# '<display name>-<registration key>', so:
#   - a NEW key (a fresh install): no deleted registration can hold a unique
#     name that did not exist before this run, so nothing is read or purged;
#   - a RECORDED key: only a deleted registration whose uniqueName is exactly
#     '<display name>-<key>' blocks the deployment (a registration this
#     environment made, then deleted by hand). Only that one is purged.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:graphDeleted = 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application'

    # `az` is an external command; a FUNCTION of the same name wins
    # resolution, so every directory call is answered here and none reaches
    # Azure.
    function Global:az {
        $line = (@($args) -join ' ')
        $global:azCalls += , $line
        $global:azCallArgs += , @($args)
        $global:LASTEXITCODE = 0
        if ($line -like 'ad app list --display-name *') {
            if ($global:azLiveFails) { $global:LASTEXITCODE = 1; return }
            $name = [string]$args[4]
            return (@($global:azLive | Where-Object { $_.displayName -eq $name }) | ConvertTo-Json -Depth 5 -AsArray)
        }
        if ($line -like 'ad app list --app-id *') {
            if ($global:azByIdFails) { $global:LASTEXITCODE = 1; return }
            $wantId = [string]$args[4]
            return (@($global:azById | Where-Object { $_.appId -eq $wantId }) | ConvertTo-Json -Depth 5 -AsArray)
        }
        if ($line -like 'rest --method GET --url *') {
            if ($global:azDeletedFails) { $global:LASTEXITCODE = 1; return }
            $pageKey = if ($line -match '--url-parameters') { 'next' } else { 'first' }
            $page = $global:azPages[$pageKey]
            if ($null -eq $page) { return '{}' }
            return ($page | ConvertTo-Json -Depth 6)
        }
        if ($line -like 'rest --method DELETE --url *') {
            if ($global:azDeleteFails) { $global:LASTEXITCODE = 1; return }
            return
        }
        return '[]'
    }
    function Global:SetPurgeDirectory {
        param(
            [object[]]$Live = @(),
            [object[]]$ById = @(),
            [object[]]$Deleted = @(),
            [object[]]$DeletedNextPage,
            [string]$NextLink = 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?$select=id,displayName,uniqueName&$skiptoken=RFNwdAIAAQAAAA'
        )
        $global:azLive = $Live
        $global:azById = $ById
        $global:azByIdFails = $false
        $first = [ordered]@{ value = @($Deleted) }
        $global:azPages = @{ first = $first }
        if ($PSBoundParameters.ContainsKey('DeletedNextPage')) {
            $first['@odata.nextLink'] = $NextLink
            $global:azPages['next'] = [ordered]@{ value = @($DeletedNextPage) }
        }
        $global:azCalls = @()
        $global:azCallArgs = @()
        $global:azLiveFails = $false
        $global:azDeletedFails = $false
        $global:azDeleteFails = $false
        $global:LASTEXITCODE = 0
    }
    function Global:NewDeleted {
        param([string]$Name, [string]$UniqueName, [string]$Id)
        [ordered]@{ id = $Id; displayName = $Name; uniqueName = $UniqueName }
    }
    $script:mine = '33333333-3333-3333-3333-333333333333'
    $script:theirs = '44444444-4444-4444-4444-444444444444'
    $script:purgeArgs = @{ ApiDisplayName = 'vmf-api-prod'; DashboardDisplayName = 'vmf-dashboard-prod'; RegistrationKey = 'abc123' }
    function Global:DeleteCalls { @($global:azCalls | Where-Object { $_ -like 'rest --method DELETE*' }) }
}
AfterAll {
    Remove-Item 'function:\az', 'function:\SetPurgeDirectory', 'function:\NewDeleted', 'function:\DeleteCalls' -ErrorAction SilentlyContinue
}

Describe 'The unique name the purge looks for is the one identity.bicep creates' {

    It 'is the display name, a hyphen and the key' {
        Get-VmfRegistrationUniqueName -DisplayName 'vmf-api-prod' -RegistrationKey 'abc123' | Should -Be 'vmf-api-prod-abc123'
    }

    It 'and identity.bicep builds both unique names that way' {
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $bicep | Should -Match ([regex]::Escape("'`${apiDisplayName}-`${registrationKey}'"))
        $bicep | Should -Match ([regex]::Escape("'`${dashboardDisplayName}-`${registrationKey}'"))
    }

    It 'refuses an empty key, whose unique name would be the display name alone' {
        { Get-VmfRegistrationUniqueName -DisplayName 'vmf-api-prod' -RegistrationKey '' } | Should -Throw
    }
}

Describe 'A deleted registration with the display name but another unique name is never purged' {

    It 'leaves a deleted vmf-api-prod that somebody else made (the measured case)' {
        SetPurgeDirectory -Deleted @(
            (NewDeleted 'vmf-api-prod' 'vmf-api-prod' $script:theirs),
            (NewDeleted 'vmf-dashboard-prod' 'vmf-dashboard-prod-zz9999' '55555555-5555-5555-5555-555555555555')
        )
        $out = Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-String
        @(DeleteCalls).Count | Should -Be 0 -Because 'a display name is not proof that this install made it'
        $out | Should -Not -Match 'removing'
    }

    It 'leaves one whose unique name only STARTS with the wanted one' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc1234' $script:theirs)
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @(DeleteCalls).Count | Should -Be 0
    }

    It 'leaves one with no unique name at all' {
        SetPurgeDirectory -Deleted @([ordered]@{ id = $script:theirs; displayName = 'vmf-api-prod' })
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @(DeleteCalls).Count | Should -Be 0
    }
}

Describe 'A deleted registration with exactly the unique name this install creates is purged' {

    It 'purges it by its object ID and says which one and why' {
        SetPurgeDirectory -Deleted @(
            (NewDeleted 'vmf-api-prod' 'vmf-api-prod' $script:theirs),
            (NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        )
        $out = Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-String
        @(DeleteCalls) | Should -Be @("rest --method DELETE --url https://graph.microsoft.com/v1.0/directory/deletedItems/$($script:mine) --output none")
        $out | Should -Match ([regex]::Escape($script:mine))
        $out | Should -Match 'vmf-api-prod-abc123'
        $out | Should -Match '30 days'
    }

    It 'purges the dashboard one the same way' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-dashboard-prod' 'vmf-dashboard-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @(DeleteCalls).Count | Should -Be 1
        @(DeleteCalls)[0] | Should -Match ([regex]::Escape($script:mine))
    }

    It 'finds one on a later page of deleted items, and passes no & to the Azure CLI' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod' $script:theirs) `
            -DeletedNextPage @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @(DeleteCalls).Count | Should -Be 1
        @(DeleteCalls)[0] | Should -Match ([regex]::Escape($script:mine))
        foreach ($callArgs in $global:azCallArgs) {
            foreach ($one in $callArgs) { [string]$one | Should -Not -Match '&' -Because 'az.cmd reads & as a command separator' }
        }
        @($global:azCallArgs | Where-Object { (@($_) -join ' ') -match '--url-parameters' }) | Should -HaveCount 1
        $next = @($global:azCallArgs | Where-Object { (@($_) -join ' ') -match '--url-parameters' })[0]
        @($next) | Should -Contain '$skiptoken=RFNwdAIAAQAAAA'
        @($next) | Should -Contain $script:graphDeleted
    }

    It 'reads the deleted items once for both names' {
        SetPurgeDirectory
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @($global:azCalls | Where-Object { $_ -like 'rest --method GET*' }).Count | Should -Be 1
    }
}

Describe 'Nothing is read where nothing can block the install' {

    It 'a NEW key reads and purges nothing: no deleted registration can hold a unique name made in this run' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:purgeArgs -NewKey 6>&1 | Out-Null
        @($global:azCalls).Count | Should -Be 0
    }

    It 'a registration that is still there with the unique name: its deleted items are not read' {
        SetPurgeDirectory -Live @(
            @{ displayName = 'vmf-api-prod'; appId = '11111111-1111-1111-1111-111111111111'; uniqueName = 'vmf-api-prod-abc123' },
            @{ displayName = 'vmf-dashboard-prod'; appId = '22222222-2222-2222-2222-222222222222'; uniqueName = 'vmf-dashboard-prod-abc123' }
        ) -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @($global:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 0 -Because 'a live registration holds the unique name, so no deleted one can'
    }

    It 'a live registration with the display name but ANOTHER unique name still has the deleted items read' {
        SetPurgeDirectory -Live @(@{ displayName = 'vmf-api-prod'; appId = '11111111-1111-1111-1111-111111111111'; uniqueName = 'vmf-api-prod' }) `
            -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null
        @(DeleteCalls).Count | Should -Be 1
    }
}

Describe 'An ordinary update: the recorded registrations are there, found by application ID' {

    BeforeAll {
        $script:apiAppId = '11111111-1111-1111-1111-111111111111'
        $script:dashAppId = '22222222-2222-2222-2222-222222222222'
        $script:recorded = $script:purgeArgs + @{ RecordedApiAppId = $script:apiAppId; RecordedDashboardAppId = $script:dashAppId }
    }

    It 'reads no deleted items, even when the az answer holds no uniqueName' {
        # No uniqueName in these answers: the update must not depend on it.
        SetPurgeDirectory -ById @(
            @{ displayName = 'vmf-api-prod'; appId = $script:apiAppId },
            @{ displayName = 'vmf-dashboard-prod'; appId = $script:dashAppId }
        ) -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        Clear-VmfDeletedRegistration @script:recorded 6>&1 | Out-Null
        @($global:azCalls | Where-Object { $_ -like 'rest *' }).Count | Should -Be 0
        @($global:azCalls | Where-Object { $_ -like 'ad app list --display-name*' }).Count | Should -Be 0
        @($global:azCalls) | Should -Contain "ad app list --app-id $($script:apiAppId) -o json"
        @($global:azCalls) | Should -Contain "ad app list --app-id $($script:dashAppId) -o json"
    }

    It 'a registration deleted in the portal: purges only the exact unique name' {
        # The dashboard is still there; the API registration was deleted, and
        # somebody else also has a deleted 'vmf-api-prod'.
        SetPurgeDirectory -ById @(@{ displayName = 'vmf-dashboard-prod'; appId = $script:dashAppId }) -Deleted @(
            (NewDeleted 'vmf-api-prod' 'vmf-api-prod' $script:theirs),
            (NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine),
            (NewDeleted 'vmf-dashboard-prod' 'vmf-dashboard-prod-abc123' '55555555-5555-5555-5555-555555555555')
        )
        Clear-VmfDeletedRegistration @script:recorded 6>&1 | Out-Null
        @(DeleteCalls) | Should -Be @("rest --method DELETE --url https://graph.microsoft.com/v1.0/directory/deletedItems/$($script:mine) --output none")
    }

    It 'a failed read by application ID stops' {
        SetPurgeDirectory
        $global:azByIdFails = $true
        { Clear-VmfDeletedRegistration @script:recorded 6>&1 | Out-Null } | Should -Throw
        @(DeleteCalls).Count | Should -Be 0
    }

    It 'a recorded ID that is not an application ID is refused' {
        SetPurgeDirectory
        { Clear-VmfDeletedRegistration @script:purgeArgs -RecordedApiAppId 'x eq y' 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*not an application ID*'
        @($global:azCalls).Count | Should -Be 0
    }
}

Describe 'A directory call that fails stops the install; it is never "none found"' {

    It 'a failed read of the deleted items stops, and purges nothing' {
        SetPurgeDirectory
        $global:azDeletedFails = $true
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*deleted application registrations*'
        @(DeleteCalls).Count | Should -Be 0
    }

    It 'a failed read of the live registrations stops' {
        SetPurgeDirectory
        $global:azLiveFails = $true
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw
        @(DeleteCalls).Count | Should -Be 0
    }

    It 'an answer with no list of deleted items stops' {
        SetPurgeDirectory
        $global:azPages = @{ first = [ordered]@{ error = 'unexpected' } }
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*no list*'
    }

    It 'a next page that is not on graph.microsoft.com stops' {
        SetPurgeDirectory -DeletedNextPage @() -NextLink 'https://graph.example.com/v1.0/directory/deletedItems?$skiptoken=x'
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*graph.microsoft.com*'
    }

    It 'a next page whose address holds a character the Azure CLI on Windows cannot pass stops' {
        SetPurgeDirectory -DeletedNextPage @() -NextLink 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?$skiptoken=a%7Cb'
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*cannot pass*'
    }

    It 'a list of deleted items longer than the page limit stops' {
        SetPurgeDirectory -DeletedNextPage @()
        # The next page points at itself.
        $global:azPages['next']['@odata.nextLink'] = $global:azPages['first']['@odata.nextLink']
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*pages*'
    }

    It 'a purge that fails stops, and names the object and the command for a directory administrator' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' $script:mine)
        $global:azDeleteFails = $true
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } |
            Should -Throw -ExpectedMessage "*vmf-api-prod-abc123*directory administrator*deletedItems/$($script:mine)*different environment name*"
    }

    It 'an object ID that is not an ID is never put into a URL' {
        SetPurgeDirectory -Deleted @(NewDeleted 'vmf-api-prod' 'vmf-api-prod-abc123' '../applications/x')
        { Clear-VmfDeletedRegistration @script:purgeArgs 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*not an object ID*'
        @(DeleteCalls).Count | Should -Be 0
    }
}

Describe 'Every install route uses the narrowed purge' {

    BeforeAll {
        $script:idDeploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'identity-deploy.ps1')
        $script:preprov = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
    }

    It 'identity-deploy purges through Clear-VmfDeletedRegistration, before the template deployment' {
        $script:idDeploy | Should -Match 'Clear-VmfDeletedRegistration -ApiDisplayName \$ApiDisplayName -DashboardDisplayName \$DashboardDisplayName -RegistrationKey \$RegistrationKey -NewKey:\$RegistrationKeyIsNew `\s+-RecordedApiAppId \$RecordedApiAppId -RecordedDashboardAppId \$RecordedDashboardAppId'
        $script:idDeploy.IndexOf('Clear-VmfDeletedRegistration') | Should -BeLessThan $script:idDeploy.IndexOf('az deployment group create')
    }

    It 'and matches nothing by display name, and lists no deleted items itself' {
        $script:idDeploy | Should -Not -Match 'deletedItems'
        $script:idDeploy | Should -Not -Match '\.displayName -eq \$wanted'
    }

    It 'a what-if run removes no deleted registration' {
        $script:idDeploy | Should -Match '(?s)if \(\$WhatIf\) \{[^}]*\}\s*else \{\s*Clear-VmfDeletedRegistration'
        ([regex]::Matches($script:idDeploy, 'Clear-VmfDeletedRegistration')).Count | Should -Be 1 -Because 'the one call sits in the else of the what-if'
    }

    It 'a key identity-deploy makes itself counts as new' {
        $script:idDeploy | Should -Match "\`$RegistrationKeyIsNew = \(\`$registration\.Source -eq 'new'\)"
    }

    It 'preprovision passes the recorded application IDs, read before it blanks them' {
        $script:preprov | Should -Match "\`$recordedApiAppId = \[string\]\(Get-AzdValue -Name 'VMF_API_APP_ID'\)"
        $script:preprov | Should -Match "\`$recordedDashboardAppId = \[string\]\(Get-AzdValue -Name 'VMF_DASHBOARD_APP_ID'\)"
        $script:preprov | Should -Match 'RecordedApiAppId\s*=\s*\$recordedApiAppId'
        $script:preprov | Should -Match 'RecordedDashboardAppId\s*=\s*\$recordedDashboardAppId'
        $script:preprov.IndexOf("Get-AzdValue -Name 'VMF_API_APP_ID'") | Should -BeLessThan $script:preprov.IndexOf("Set-AzdValue -Name 'VMF_API_APP_ID' -Value ''")
        $script:preprov.IndexOf("Get-AzdValue -Name 'VMF_DASHBOARD_APP_ID'") | Should -BeLessThan $script:preprov.IndexOf("Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID' -Value ''")
    }

    It 'preprovision says whether the key is new' {
        $script:preprov | Should -Match "RegistrationKeyIsNew\s*=\s*\(\`$registration\.Source -eq 'new'\)"
    }

    It 'the removal hooks purge nothing' {
        foreach ($hook in 'predown.ps1', 'postdown.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' $hook)
            $code | Should -Not -Match 'deletedItems' -Because "$hook deletes by the recorded application ID, and Entra keeps what it deletes"
        }
    }
}
