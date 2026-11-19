#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# GRANT-QUERY-SHIM-1: -CloseTheGate counts the Vmf.Admin holders in
# PowerShell, from the json az returns.
#
# It used to ask az for the count with --query "value[?appRoleId=='...'] |
# length(@)". On Windows az is az.cmd: cmd eats the [? filter and drops the
# double quotes (CLAUDE.md), so what came back was not a count. [int] read it
# as 0 or threw, and the script said nobody held the role when somebody did.
#
# The script is RUN here, with a stand-in for az that answers like Graph and
# IGNORES any --query - which is what the shim makes of a filter.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:grantPath = Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1'
    $script:subA = '00000000-0000-0000-0000-000000000000'
    $global:gqAppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $global:gqSpId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:spId = $global:gqSpId
    $script:adminRole = '6f1c3a10-0004-4b6e-9e6a-100000000004'
    $script:otherRole = '6f1c3a10-0001-4b6e-9e6a-100000000001'
    $script:assignedTo = "https://graph.microsoft.com/v1.0/servicePrincipals/$($script:spId)/appRoleAssignedTo"

    # Graph's answer for each appRoleAssignedTo address the test serves.
    function Global:GqPage([object[]]$Assignments, [string]$Next) {
        $page = [ordered]@{ value = @($Assignments | ForEach-Object { [ordered]@{ appRoleId = $_; principalType = 'User' } }) }
        if ($Next) { $page['@odata.nextLink'] = $Next }
        $page | ConvertTo-Json -Depth 5
    }
}

AfterAll { Remove-Item 'function:\GqPage' -ErrorAction SilentlyContinue }

Describe 'GRANT-QUERY-SHIM-1: closing the gate counts the administrators in PowerShell' {
    BeforeEach {
        $global:gqCalls = [System.Collections.Generic.List[string]]::new()
        $global:gqPatched = $false
        $global:gqPages = @{}
        $global:gqFail = $false
        # The stand-in for az. It answers the four reads the run makes and
        # records every call. A --query is ignored, as az.cmd breaks a filter.
        function global:az {
            $joined = $args -join ' '
            $global:gqCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'ad app list*') { return "[{`"displayName`":`"vmf-api-test`",`"appId`":`"$($global:gqAppId)`"}]" }
            if ($joined -like 'ad sp list*') { return "[{`"appId`":`"$($global:gqAppId)`",`"id`":`"$($global:gqSpId)`"}]" }
            if ($joined -like 'rest --method PATCH*') { $global:gqPatched = $true; return }
            if ($joined -like '*appRoleAssignedTo*') {
                if ($global:gqFail) { $global:LASTEXITCODE = 1; Write-Error 'Insufficient privileges'; return }
                $url = $args[[array]::IndexOf($args, '--url') + 1]
                return $global:gqPages[$url]
            }
            if ($joined -like 'rest --method GET*') { return 'true' }
            throw "the stand-in for az has no answer for: $joined"
        }
        $script:grantRun = {
            & $script:grantPath -ResourceGroup 'rg-vmf' -SubscriptionId $script:subA -CloseTheGate 6>&1 | Out-String
        }
    }
    # TEST-STUB-1: the function:global: form removes nothing.
    AfterEach { Remove-Item 'function:\az' -ErrorAction SilentlyContinue }

    It 'two assignments, one of them Vmf.Admin: the count is 1 and the gate closes' {
        $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole, $script:adminRole)
        $said = & $script:grantRun
        $global:gqPatched | Should -BeTrue
        $said | Should -Match 'done - the Vmf\.Admin role has at least 1 assignment'
    }

    It 'asks az for the json, with no --query, so the shim has nothing to break' {
        $global:gqPages[$script:assignedTo] = GqPage @($script:adminRole)
        & $script:grantRun | Out-Null
        $read = @($global:gqCalls | Where-Object { $_ -like '*appRoleAssignedTo*' })
        $read.Count | Should -Be 1
        $read[0] | Should -Not -Match '--query'
        $read[0] | Should -Match '-o json'
    }

    It 'no assignment of Vmf.Admin: refuses, and the gate stays open' {
        $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole)
        { & $script:grantRun } | Should -Throw '*no one holds the administrator role*'
        $global:gqPatched | Should -BeFalse
    }

    It 'a read that fails says the read failed, not that nobody holds the role' {
        $global:gqFail = $true
        $err = { & $script:grantRun } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Refusing to close the gate*Could not read the assignments of the Vmf.Admin role*'
        $err.Exception.Message | Should -BeLike '*Insufficient privileges*'
        $err.Exception.Message | Should -Not -BeLike '*no one holds*'
        $err.Exception.Message | Should -Not -BeLike '*users who hold*'
        $global:gqPatched | Should -BeFalse
    }

    It 'an answer that is not json is a failed read, not a count of 0' {
        $global:gqPages[$script:assignedTo] = 'ERROR: argument --query: invalid jmespath_type value'
        $err = { & $script:grantRun } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Refusing to close the gate*not readable*'
        $global:gqPatched | Should -BeFalse
    }

    It 'an empty answer is a failed read, not a count of 0' {
        $global:gqPages[$script:assignedTo] = ''
        $err = { & $script:grantRun } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Refusing to close the gate*assignments of the Vmf.Admin role*'
        $err.Exception.Message | Should -Not -BeLike '*no one holds*'
        $global:gqPatched | Should -BeFalse
    }

    It 'reads the next page while no administrator is found: one on the second page counts' {
        $next = "$($script:assignedTo)?`$skiptoken=page2"
        $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole, $script:otherRole) $next
        $global:gqPages[$next] = GqPage @($script:adminRole, $script:otherRole)
        $said = & $script:grantRun
        $global:gqPatched | Should -BeTrue
        $said | Should -Match 'done - the Vmf\.Admin role has at least 1 assignment'
        @($global:gqCalls | Where-Object { $_ -like '*appRoleAssignedTo*' }).Count | Should -Be 2
    }

    It 'stops reading once an administrator is found: a later page is not read' {
        $next = "$($script:assignedTo)?`$skiptoken=page2"
        $global:gqPages[$script:assignedTo] = GqPage @($script:adminRole) $next
        $global:gqPages[$next] = GqPage @($script:adminRole)
        & $script:grantRun | Out-Null
        $global:gqPatched | Should -BeTrue
        @($global:gqCalls | Where-Object { $_ -like '*appRoleAssignedTo*' }).Count | Should -Be 1
    }

    It 'an administrator on the first page closes the gate, though the next address holds & or leaves Graph' {
        foreach ($next in "$($script:assignedTo)?`$top=100&`$skiptoken=page2", 'https://contoso.example.com/next') {
            $global:gqPatched = $false
            $global:gqPages[$script:assignedTo] = GqPage @($script:adminRole) $next
            & $script:grantRun | Out-Null
            $global:gqPatched | Should -BeTrue -Because $next
        }
    }

    It 'with no administrator found, a next page whose address holds & is not read through az.cmd' {
        $next = "$($script:assignedTo)?`$top=100&`$skiptoken=page2"
        $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole) $next
        $err = { & $script:grantRun } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Refusing to close the gate*&*The gate stays open*'
        @($global:gqCalls | Where-Object { $_ -like '*appRoleAssignedTo*' }).Count | Should -Be 1
        $global:gqPatched | Should -BeFalse
    }

    It 'with no administrator found, a next page outside Microsoft Graph is not read' {
        foreach ($next in 'https://graph.microsoft.com.example.com/v1.0/x', 'http://graph.microsoft.com/v1.0/x', 'https://contoso.example.com/next') {
            $global:gqCalls.Clear()
            $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole) $next
            $global:gqPages[$next] = GqPage @($script:adminRole)
            $err = { & $script:grantRun } | Should -Throw -PassThru -Because $next
            $err.Exception.Message | Should -BeLike '*Refusing to close the gate*https://graph.microsoft.com/*The gate stays open*'
            @($global:gqCalls | Where-Object { $_ -like '*rest --method GET*' -and $_ -notlike '*servicePrincipals/*' }).Count | Should -Be 0 -Because $next
            $global:gqPatched | Should -BeFalse
        }
    }

    It 'with no administrator found, a next page that never ends stops at a fixed limit' {
        $global:gqPages[$script:assignedTo] = GqPage @($script:otherRole) $script:assignedTo
        $err = { & $script:grantRun } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike '*Refusing to close the gate*pages*The gate stays open*'
        $global:gqPatched | Should -BeFalse
    }
}