#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AZD-DOWN-RG-RECHECK-1 - a removal azd reports as failed, with the resource
# group gone.
#
# FOUND 2026-11-19 in a real removal (identifiers redacted, rule 13):
# azd down printed "Failed deleting resource group rg-<name>" and "context
# canceled". Azure still deleted the group, but azd runs postdown only after a
# delete it saw succeed, so the two Entra registrations stayed. A second azd
# down ran predown, then stopped on "404 ResourceGroupNotFound" - again before
# postdown.
#
# MEASURED 2026-11-20, azd 1.39.1, an empty resource group in a lab
# subscription:
#   * azd down with the group already gone runs predown (AZURE_RESOURCE_GROUP
#     still set), then exits 1 on ResourceGroupNotFound, and never runs
#     postdown;
#   * a successful azd down clears AZURE_RESOURCE_GROUP (a deployment output)
#     BEFORE postdown, and keeps a value predown wrote with azd env set;
#   * azd hooks run postdown runs the hook with the environment.
#
# So: predown records the group's name, postdown reads the group back before it
# removes anything and refuses while the group is there, and predown finishes
# the removal itself when the group is already gone.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:hooks = Join-Path $script:repoRoot 'infra' 'hooks'
    . (Join-Path $script:hooks 'AzdHooks.ps1')
    # Remove Set-StrictMode's reach from the dot-source: the hooks file turns
    # it on for the hooks, and this file only calls its functions.
    Set-StrictMode -Off

    $script:envKeys = 'AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'VMF_DOWN_RESOURCE_GROUP',
        'VMF_REMOVE_REGISTRATIONS', 'VMF_API_APP_ID', 'VMF_DASHBOARD_APP_ID', 'VMF_API_DISPLAY_NAME',
        'VMF_DASHBOARD_DISPLAY_NAME', 'VMF_REGISTRATION_KEY'
    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:api = @{ id = 'object-api'; appId = 'aaaaaaaa-0000-4000-8000-000000000001'; displayName = 'vmf-api-rgtest' }
    $script:dash = @{ id = 'object-dash'; appId = 'aaaaaaaa-0000-4000-8000-000000000002'; displayName = 'vmf-dashboard-rgtest' }

    # A stand-in for az. Each 'az group show' takes the next answer from
    # $global:rgAnswers, and the last one repeats: gone, deleting, present, or
    # error (a failure that is not ResourceGroupNotFound).
    function script:Set-RgStandIn {
        $global:rgShown = @()
        $global:rgDeleted = @()
        $global:rgOtherDelete = @()
        $global:rgAzdSets = @()
        $global:rgApps = @($script:api, $script:dash)
        function global:azd {
            if ($args[0] -eq 'env' -and $args[1] -eq 'set') { $global:rgAzdSets += , @([string]$args[2], [string]$args[3]) }
            $global:LASTEXITCODE = 0
        }
        function global:az {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'group' -and $args[1] -eq 'show') {
                $global:rgShown += , @($args)
                $answer = if ($global:rgAnswers.Count -gt 1) { $first, $rest = $global:rgAnswers; $global:rgAnswers = @($rest); $first } else { $global:rgAnswers[0] }
                $groupName = [string]$args[[array]::IndexOf($args, '--name') + 1]
                switch ($answer) {
                    'gone' {
                        Write-Error "(ResourceGroupNotFound) Resource group '$groupName' could not be found."
                        $global:LASTEXITCODE = 3; return
                    }
                    'error' {
                        Write-Error '(AuthorizationFailed) The client does not have authorization to perform action.'
                        $global:LASTEXITCODE = 1; return
                    }
                    'deleting' { return (@{ name = $groupName; properties = @{ provisioningState = 'Deleting' } } | ConvertTo-Json -Depth 4) }
                    default { return (@{ name = $groupName; properties = @{ provisioningState = 'Succeeded' } } | ConvertTo-Json -Depth 4) }
                }
            }
            if ($args[0] -eq 'ad' -and $args[2] -eq 'delete') { $global:rgDeleted += [string]$args[[array]::IndexOf($args, '--id') + 1]; return }
            if ($args -contains 'delete') { $global:rgOtherDelete += , @($args); return }
            if ($args -contains '--app-id') {
                $id = $args[[array]::IndexOf($args, '--app-id') + 1]
                return ($global:rgApps | Where-Object { $_.appId -eq $id } | ConvertTo-Json -AsArray -Depth 4)
            }
            if ($args -contains '--display-name') {
                $n = $args[[array]::IndexOf($args, '--display-name') + 1]
                return ($global:rgApps | Where-Object { $_.displayName -eq $n } | ConvertTo-Json -AsArray -Depth 4)
            }
            '[]'
        }
    }
    function script:Clear-RgStandIn {
        Remove-Item function:az, function:azd -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name rgAnswers, rgShown, rgDeleted, rgOtherDelete, rgAzdSets, rgApps -ErrorAction SilentlyContinue
    }
}

Describe 'AZD-DOWN-RG-RECHECK-1: the resource group is read back, not assumed' {
    BeforeEach {
        Set-RgStandIn
        Mock Start-Sleep { }
    }
    AfterEach { Clear-RgStandIn }

    It 'ResourceGroupNotFound is gone' {
        $global:rgAnswers = @('gone')
        (Get-VmfResourceGroupState -Name 'rg-rgtest' -Subscription $script:sub).State | Should -Be 'gone'
        # It asks for that group, in that subscription.
        $global:rgShown[0] | Should -Contain 'rg-rgtest'
        $global:rgShown[0] | Should -Contain $script:sub
    }

    It 'a group Azure is deleting is deleting, and any other state is present' {
        $global:rgAnswers = @('deleting')
        (Get-VmfResourceGroupState -Name 'rg-rgtest' -Subscription $script:sub).State | Should -Be 'deleting'
        $global:rgAnswers = @('present')
        (Get-VmfResourceGroupState -Name 'rg-rgtest' -Subscription $script:sub).State | Should -Be 'present'
    }

    It 'any other failure is unknown, never gone, and keeps what Azure said' {
        $global:rgAnswers = @('error')
        $state = Get-VmfResourceGroupState -Name 'rg-rgtest' -Subscription $script:sub
        $state.State | Should -Be 'unknown'
        $state.Detail | Should -Match 'AuthorizationFailed'
    }

    It 'with no name or no subscription it is unknown, and Azure is not asked' {
        $global:rgAnswers = @('gone')
        (Get-VmfResourceGroupState -Name '' -Subscription $script:sub).State | Should -Be 'unknown'
        (Get-VmfResourceGroupState -Name 'rg-rgtest' -Subscription '').State | Should -Be 'unknown'
        $global:rgShown | Should -BeNullOrEmpty
    }

    It 'the wait reads again while Azure deletes the group, and stops at gone' {
        $global:rgAnswers = @('deleting', 'deleting', 'deleting', 'gone')
        $state = Wait-VmfResourceGroupGone -Name 'rg-rgtest' -Subscription $script:sub -DeletingSeconds 600 -PresentSeconds 0 -IntervalSeconds 30 6>$null
        $state.State | Should -Be 'gone'
        $global:rgShown.Count | Should -Be 4
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }

    It 'the wait has a fixed limit for a group Azure is still deleting' {
        $global:rgAnswers = @('deleting')
        $state = Wait-VmfResourceGroupGone -Name 'rg-rgtest' -Subscription $script:sub -DeletingSeconds 300 -PresentSeconds 0 -IntervalSeconds 30 6>$null
        $state.State | Should -Be 'deleting'
        # 300 / 30 = 10 waits, then one last read.
        Should -Invoke Start-Sleep -Times 10 -Exactly
        $global:rgShown.Count | Should -Be 11
    }

    It 'a group that is there is read again only for the shorter limit' {
        $global:rgAnswers = @('present')
        $state = Wait-VmfResourceGroupGone -Name 'rg-rgtest' -Subscription $script:sub -DeletingSeconds 600 -PresentSeconds 60 -IntervalSeconds 30 6>$null
        $state.State | Should -Be 'present'
        Should -Invoke Start-Sleep -Times 2 -Exactly
        $global:rgAnswers = @('present')
        $state = Wait-VmfResourceGroupGone -Name 'rg-rgtest' -Subscription $script:sub -DeletingSeconds 600 -PresentSeconds 0 -IntervalSeconds 30 6>$null
        $state.State | Should -Be 'present'
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'the name is the one the removal recorded, else AZURE_RESOURCE_GROUP' {
        $before = @{}; foreach ($k in 'VMF_DOWN_RESOURCE_GROUP', 'AZURE_RESOURCE_GROUP') { $before[$k] = [Environment]::GetEnvironmentVariable($k) }
        try {
            [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', 'rg-recorded')
            [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-other')
            Get-VmfDownResourceGroupName | Should -Be 'rg-recorded'
            [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', $null)
            Get-VmfDownResourceGroupName | Should -Be 'rg-other'
            [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', $null)
            Get-VmfDownResourceGroupName | Should -Be ''
        }
        finally { foreach ($k in $before.Keys) { [Environment]::SetEnvironmentVariable($k, $before[$k]) } }
    }
}

Describe 'AZD-DOWN-RG-RECHECK-1: postdown removes the registrations only when the group is gone' {
    BeforeEach {
        $script:envBefore = @{}
        foreach ($k in $script:envKeys) { $script:envBefore[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
        [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'rgtest')
        [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:sub)
        # MEASURED: a successful azd down has cleared AZURE_RESOURCE_GROUP by
        # the time postdown runs. The name predown recorded is what is left.
        [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', 'rg-rgtest')
        [Environment]::SetEnvironmentVariable('VMF_REMOVE_REGISTRATIONS', 'yes')
        [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:api.appId)
        [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
        Set-RgStandIn
        Mock Start-Sleep { }
        $script:runDown = { & (Join-Path $script:hooks 'postdown.ps1') 6>&1 | Out-String }
    }
    AfterEach {
        foreach ($k in $script:envKeys) { [Environment]::SetEnvironmentVariable($k, $script:envBefore[$k]) }
        Clear-RgStandIn
    }

    It 'a group that is gone: both registrations are removed, by their recorded IDs, and the record is cleared' {
        $global:rgAnswers = @('gone')
        $global:LASTEXITCODE = 0
        $said = & $script:runDown
        $global:rgShown[0] | Should -Contain 'rg-rgtest'
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
        $said | Should -Match 'The resource group rg-rgtest is gone'
        [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('VMF_DASHBOARD_APP_ID') | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP') | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'the group is read BEFORE the question and before any registration is looked up' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:hooks 'postdown.ps1')
        $check = $code.IndexOf('Wait-VmfResourceGroupGone')
        $check | Should -BeGreaterThan -1
        $check | Should -BeLessThan $code.IndexOf("Read-VmfChoice -Name 'VMF_REMOVE_REGISTRATIONS'")
        $check | Should -BeLessThan $code.IndexOf('az ad app delete')
    }

    It 'a group that is still there: nothing is removed, the IDs stay, and it says to run azd down again' {
        $global:rgAnswers = @('present')
        $said = & $script:runDown
        $global:rgDeleted | Should -BeNullOrEmpty
        $global:rgOtherDelete | Should -BeNullOrEmpty -Because 'postdown never deletes the resource group itself'
        $said | Should -Match 'The resource group rg-rgtest is still in Azure'
        $said | Should -Match 'azd down'
        $LASTEXITCODE | Should -Be 1
        [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -Be $script:api.appId
        [Environment]::GetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP') | Should -Be 'rg-rgtest'
        [Environment]::GetEnvironmentVariable('VMF_REMOVE_REGISTRATIONS') | Should -Be 'yes' -Because 'the question is not reached'
    }

    It 'a group Azure is still deleting is read again until it is gone, then the registrations go' {
        $global:rgAnswers = @('deleting', 'deleting', 'gone')
        $said = & $script:runDown
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
        $said | Should -Match 'Azure is deleting the resource group rg-rgtest'
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'a group Azure is still deleting after the limit: nothing is removed, and it says how to finish' {
        $global:rgAnswers = @('deleting')
        $said = & $script:runDown
        $global:rgDeleted | Should -BeNullOrEmpty
        $said | Should -Match 'Azure is still deleting the resource group rg-rgtest'
        $said | Should -Match 'azd hooks run postdown'
        $LASTEXITCODE | Should -Be 1
    }

    It 'a read that fails: nothing is removed, and it says what Azure answered' {
        $global:rgAnswers = @('error')
        $said = & $script:runDown
        $global:rgDeleted | Should -BeNullOrEmpty
        $said | Should -Match 'could not read the resource group rg-rgtest'
        $said | Should -Match 'AuthorizationFailed'
        $LASTEXITCODE | Should -Be 1
    }

    It 'no name recorded: nothing is removed, and Azure is not asked about a group it cannot name' {
        [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', $null)
        $global:rgAnswers = @('gone')
        $said = & $script:runDown
        $global:rgShown | Should -BeNullOrEmpty
        $global:rgDeleted | Should -BeNullOrEmpty
        $said | Should -Match 'The name of the resource group is not recorded'
        $LASTEXITCODE | Should -Be 1
    }

    It 'a failed removal that left AZURE_RESOURCE_GROUP set is read by that name' {
        [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', $null)
        [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-rgtest')
        $global:rgAnswers = @('gone')
        & $script:runDown | Out-Null
        $global:rgShown[0] | Should -Contain 'rg-rgtest'
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
    }

    It 'the answer No also ends the removal, so the record is cleared' {
        [Environment]::SetEnvironmentVariable('VMF_REMOVE_REGISTRATIONS', 'no')
        $global:rgAnswers = @('gone')
        & $script:runDown | Out-Null
        $global:rgDeleted | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP') | Should -BeNullOrEmpty
    }
}

Describe 'AZD-DOWN-RG-RECHECK-1: predown records the group, and finishes a removal whose group is already gone' {
    BeforeEach {
        $script:envBefore = @{}
        foreach ($k in $script:envKeys) { $script:envBefore[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
        [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'rgtest')
        [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:sub)
        [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-rgtest')
        [Environment]::SetEnvironmentVariable('VMF_REMOVE_REGISTRATIONS', 'yes')
        [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:api.appId)
        [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
        Set-RgStandIn
        Mock Start-Sleep { }
        $script:runPre = { & (Join-Path $script:hooks 'predown.ps1') 6>&1 | Out-String }
    }
    AfterEach {
        foreach ($k in $script:envKeys) { [Environment]::SetEnvironmentVariable($k, $script:envBefore[$k]) }
        Clear-RgStandIn
    }

    It 'records the name of the group, because azd clears AZURE_RESOURCE_GROUP before postdown' {
        $global:rgAnswers = @('present')
        & $script:runPre | Out-Null
        $set = @($global:rgAzdSets | Where-Object { $_[0] -eq 'VMF_DOWN_RESOURCE_GROUP' })
        $set.Count | Should -Be 1
        $set[0][1] | Should -Be 'rg-rgtest'
    }

    It 'a group that is there (the usual removal): nothing is removed, and nothing is deleted' {
        $global:rgAnswers = @('present')
        $said = & $script:runPre
        $global:rgDeleted | Should -BeNullOrEmpty
        $global:rgOtherDelete | Should -BeNullOrEmpty
        $said | Should -Match 'azd now deletes the resource group'
        [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -Be $script:api.appId
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'a group that is already gone: the registrations are removed, and it says why azd stops next' {
        $global:rgAnswers = @('gone')
        $said = & $script:runPre
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
        $global:rgOtherDelete | Should -BeNullOrEmpty
        $said | Should -Match 'The resource group rg-rgtest is already gone'
        $said | Should -Match 'ResourceGroupNotFound'
        [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP') | Should -BeNullOrEmpty
    }

    It 'a group Azure is still deleting is read again, and when it is gone the registrations go' {
        $global:rgAnswers = @('deleting', 'deleting', 'gone')
        $said = & $script:runPre
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
        $said | Should -Match 'Azure is deleting the resource group rg-rgtest'
    }

    It 'gone, then a read that fails inside postdown: predown fails too, and never says the step is done' {
        $global:rgAnswers = @('gone', 'error')
        $global:LASTEXITCODE = 0
        $said = & $script:runPre
        $global:rgDeleted | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 1
        $said | Should -Not -Match 'do not have to do this step again'
    }

    It 'a read that fails: nothing is removed, and the removal goes on as before' {
        $global:rgAnswers = @('error')
        $said = & $script:runPre
        $global:rgDeleted | Should -BeNullOrEmpty
        $said | Should -Match 'could not read the resource group rg-rgtest'
        [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -Be $script:api.appId
    }

    It 'with AZURE_RESOURCE_GROUP gone, it keeps the name an earlier removal recorded' {
        [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', $null)
        [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', 'rg-rgtest')
        $global:rgAnswers = @('gone')
        & $script:runPre | Out-Null
        @($global:rgAzdSets | Where-Object { $_[0] -eq 'VMF_DOWN_RESOURCE_GROUP' -and $_[1] -eq '' }).Count |
            Should -Be 1 -Because 'only the finished removal clears it, never the record step'
        $global:rgShown[0] | Should -Contain 'rg-rgtest'
        $global:rgDeleted | Should -Be @('object-api', 'object-dash')
    }

    It 'predown itself still deletes nothing: the registrations go through postdown, which reads the group again' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:hooks 'predown.ps1')
        $code | Should -Not -Match 'az ad app delete'
        $code | Should -Not -Match 'az .* delete'
        $code | Should -Match "Join-Path \`$PSScriptRoot 'postdown\.ps1'"
    }
}

Describe 'AZD-DOWN-RG-RECHECK-1: a new install starts with no recorded group' {
    It 'preprovision clears the name a removal recorded' {
        # A record left by a removal that stopped would otherwise name an old
        # group, and postdown would read that group as the install's.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:hooks 'preprovision.ps1')
        $code | Should -Match "Set-AzdValue -Name 'VMF_DOWN_RESOURCE_GROUP' -Value ''"
    }
}
