#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-THROTTLE-RETRY-2 and the review of INSTALL-THROTTLE-RETRY-1.
#
# 1. The two Container Apps job updates wait on a throttle, and SAY it was a
#    throttle - they printed "another operation is in flight on the job", and
#    the time-out said "blocked by another operation".
# 2. The throttle forms Microsoft documents: SubscriptionRequestsThrottled
#    ("Troubleshoot common Azure deployment errors", with "Please try again
#    after '6' seconds."), and ARM background job throttling ("an excessive
#    volume of traffic"). With -Echo (a build log), only az's own "ERROR:"
#    lines are read for a throttle.
# 3. The install's other az calls go through the same helper, each keeping
#    its own failure meaning.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Invoke-VmfAzStep.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRoleScopes.ps1')
    . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfImageDigest.ps1')

    # The stand-in az: each call takes the next answer from the queue; the
    # last answer repeats. An answer is @{ Exit; Out; Err }.
    function global:az {
        $global:VmfThr2Calls += , ($args -join ' ')
        $answer = if ($global:VmfThr2Answers.Count -gt 1) {
            $first = $global:VmfThr2Answers[0]
            $global:VmfThr2Answers = @($global:VmfThr2Answers | Select-Object -Skip 1)
            $first
        } else { $global:VmfThr2Answers[0] }
        foreach ($line in @($answer.Err)) { if ($line) { Write-Error -Message $line -ErrorAction Continue } }
        $global:LASTEXITCODE = [int]$answer.Exit
        if ($answer.Out) { $answer.Out }
    }
    function script:Set-Answers { param([object[]]$Answers) $global:VmfThr2Answers = @($Answers); $global:VmfThr2Calls = @() }
    $script:throttled = @{ Exit = 1; Err = 'ERROR: Too Many Requests' }
    $script:busy = @{ Exit = 1; Err = 'ERROR: (OperationInProgress) Another operation is in progress on the job.' }
    $script:refused = @{ Exit = 1; Err = 'ERROR: (AuthorizationFailed) The client does not have authorization.' }
    $script:ok = @{ Exit = 0; Out = '{}' }
}

AfterAll {
    Remove-Item 'function:\az' -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name VmfThr2Answers, VmfThr2Calls -ErrorAction SilentlyContinue
}

Describe 'INSTALL-THROTTLE-RETRY-1 review: the throttle forms Microsoft documents' {
    It 'is a throttle: <Name>' -ForEach @(
        @{ Name = 'SubscriptionRequestsThrottled'; Text = "ERROR: (SubscriptionRequestsThrottled) Number of requests for subscription '00000000-0000-0000-0000-000000000000' and operation 'GET/SUBSCRIPTIONS/RESOURCEGROUPS' exceeded the backend storage limit. Please try again after '6' seconds." }
        @{ Name = 'ARM background job throttling'; Text = "ERROR: The request for subscription '00000000-0000-0000-0000-000000000000' could not be processed due to an excessive volume of traffic. Please try again later." }
        @{ Name = 'the Compute throttling body'; Text = 'ERROR: (OperationNotAllowed) The server rejected the request because too many requests have been received for this subscription.' }
    ) {
        Test-VmfAzThrottled -Text $Text | Should -BeTrue
    }

    It 'reads the wait in Microsoft''s example, with the number in quotes' {
        Get-VmfAzRetryAfterSeconds -Text "Please try again after '6' seconds." | Should -Be 6
    }

    It 'an OperationNotAllowed that is not a throttle is not one' {
        Test-VmfAzThrottled -Text 'ERROR: (OperationNotAllowed) Operation could not be completed as it results in exceeding approved standardDSv5Family Cores quota.' | Should -BeFalse
    }
}

Describe 'INSTALL-THROTTLE-RETRY-1 review: -Echo reads only az''s own error lines' {
    BeforeEach { Mock Start-Sleep {} }

    It 'a build log line on standard output with the words is not a throttle' {
        Set-Answers @(@{ Exit = 1; Out = 'Step 4/9 : npm WARN 429 Too Many Requests from the package feed'; Err = 'ERROR: Run failed' }, $script:ok)
        { Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command { az acr build } 6>$null } |
            Should -Throw 'Deploy step failed (az exit 1): building the engine image'
        $global:VmfThr2Calls.Count | Should -Be 1
    }

    It 'a build log line on the error stream with the words is not a throttle' {
        Set-Answers @(@{ Exit = 1; Err = @('2026/11/16 Too Many Requests from the package feed', 'ERROR: Run failed') }, $script:ok)
        { Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command { az acr build } 6>$null } | Should -Throw
        $global:VmfThr2Calls.Count | Should -Be 1
    }

    It 'az''s own ERROR line with a throttle is tried again' {
        Set-Answers @($script:throttled, @{ Exit = 0; Out = 'done' })
        Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command { az acr build } 6>$null
        $global:VmfThr2Calls.Count | Should -Be 2
    }

    It 'without -Echo, standard output is not read for a throttle either' {
        Set-Answers @(@{ Exit = 1; Out = 'Too Many Requests'; Err = 'ERROR: (BadRequest) The request is not valid.' }, $script:ok)
        { Invoke-VmfAzStep -Step 's' -Command { az x } 6>$null } | Should -Throw
        $global:VmfThr2Calls.Count | Should -Be 1
    }
}

Describe 'INSTALL-THROTTLE-RETRY-1 review: a job update says which wait it is' {
    BeforeEach { Mock Start-Sleep {} }
    BeforeAll {
        $script:update = @{
            Step = 'point the publish job vmf-publish-x at the package image'; What = 'The publish job update'
            RefusedMessage = 'The publish job vmf-publish-x could not be pointed at the package image. Deploy infra/platform.bicep, which creates it, then publish again.'
            Command = { az containerapp job update }
        }
    }

    It 'a throttle prints the throttle line, not "another operation"' {
        Set-Answers @($script:throttled, $script:ok)
        $said = Invoke-VmfAzUpdateWhileBusy @script:update 6>&1 | Out-String
        $said | Should -Match ([regex]::Escape("Azure answered Too Many Requests (HTTP 429) at the step 'point the publish job vmf-publish-x at the package image'. The install waits 20 seconds, then tries again."))
        $said | Should -Not -Match 'another operation'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
    }

    It 'the throttle line is the same words Invoke-VmfAzStep prints' {
        Set-Answers @($script:throttled, $script:ok)
        $said = (Invoke-VmfAzUpdateWhileBusy @script:update 6>&1 | Out-String).Trim()
        $said | Should -BeExactly (Get-VmfAzThrottleWaitLine -Step $script:update.Step -Seconds 20).Trim()
    }

    It 'a throttle with a Retry-After waits that long' {
        Set-Answers @(@{ Exit = 1; Err = "ERROR: (SubscriptionRequestsThrottled) Please try again after '6' seconds." }, $script:ok)
        Invoke-VmfAzUpdateWhileBusy @script:update 6>$null
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 6 }
    }

    It 'another operation prints the in-flight line' {
        Set-Answers @($script:busy, $script:ok)
        $said = Invoke-VmfAzUpdateWhileBusy @script:update 6>&1 | Out-String
        $said | Should -Match 'another operation is in flight on the job; waiting 20s'
        $said | Should -Not -Match 'Too Many Requests'
    }

    It 'throttled at the time limit: the failure names Too Many Requests' {
        Set-Answers @($script:throttled)
        $err = $null
        try { Invoke-VmfAzUpdateWhileBusy @script:update -Minutes 0 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Azure answered Too Many Requests \(HTTP 429\) to the publish job update for 0 minutes\. Run azd up again in a few minutes\.'
        $err | Should -Not -Match 'blocked by another operation'
    }

    It 'busy at the time limit: the failure says another operation' {
        Set-Answers @($script:busy)
        $err = $null
        try { Invoke-VmfAzUpdateWhileBusy @script:update -Minutes 0 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match '^The publish job update was blocked by another operation for 0 minutes'
    }

    It 'a refusal stops at once with the step''s own words and Azure''s text' {
        Set-Answers @($script:refused, $script:ok)
        $err = $null
        try { Invoke-VmfAzUpdateWhileBusy @script:update 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match '^The publish job vmf-publish-x could not be pointed at the package image\.'
        $err | Should -Match 'AuthorizationFailed'
        $global:VmfThr2Calls.Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'the engine job''s refusal keeps its exit code' {
        Set-Answers @(@{ Exit = 2; Err = 'ERROR: (BadRequest) The image is not valid.' })
        { Invoke-VmfAzUpdateWhileBusy -Step 'point the engine job at the image' -What 'The engine job update' `
                -RefusedMessage 'engine job update failed (az exit {0}):' -Command { az containerapp job update } 6>$null } |
            Should -Throw 'engine job update failed (az exit 2):*BadRequest*'
    }

    It 'both job updates use it: <Name>' -ForEach @(
        @{ Name = 'the publish job'; File = 'tools/Deploy-VmfFacade.ps1' }
        @{ Name = 'the engine job'; File = 'infra/hooks/postprovision.ps1' }
    ) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $File)
        $code | Should -Match 'Invoke-VmfAzUpdateWhileBusy -Step'
        $code | Should -Not -Match 'another operation is in flight'
    }
}

Describe 'INSTALL-THROTTLE-RETRY-2: the other install az calls keep their meaning and retry a throttle' {
    BeforeEach { Mock Start-Sleep {} }

    It 'a directory read: throttled, then the answer' {
        Set-Answers @($script:throttled, @{ Exit = 0; Out = '[{"id":"app-1","appId":"11111111-2222-3333-4444-555555555555","displayName":"vmf-api"}]' })
        $app = Get-VmfEntraApplication -DisplayName 'vmf-api' 6>$null
        $app.id | Should -Be 'app-1'
        $global:VmfThr2Calls.Count | Should -Be 2
    }

    It 'a directory read throttled on every try still fails as a failed read, and says the throttle' {
        Set-Answers @($script:throttled)
        $err = $null
        try { Get-VmfEntraApplication -DisplayName 'vmf-api' 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Could not read'
        $err | Should -Match 'Too Many Requests \(HTTP 429\) 4 times'
        $err | Should -Match "nothing here reads it as 'the object does not exist'"
    }

    It 'a directory read that is refused is not tried again' {
        Set-Answers @(@{ Exit = 1; Err = 'ERROR: Insufficient privileges to complete the operation.' }, $script:ok)
        { Get-VmfEntraApplication -DisplayName 'vmf-api' 6>$null } | Should -Throw '*Insufficient privileges*'
        $global:VmfThr2Calls.Count | Should -Be 1
    }

    It 'a directory read the caller can live without still warns and returns nothing' {
        Set-Answers @(@{ Exit = 1; Err = 'ERROR: Insufficient privileges to complete the operation.' })
        Get-VmfEntraApplication -DisplayName 'vmf-api' -AllowDirectoryFailure 3>$null 6>$null | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'the custom roles read: throttled, then the answer' {
        $sub = '00000000-0000-0000-0000-000000000000'
        $role = @{ id = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/r1"; roleName = 'VMF Assessment (vmf)'; assignableScopes = @("/subscriptions/$sub") }
        Set-Answers @($script:throttled, @{ Exit = 0; Out = (ConvertTo-Json -Compress -Depth 4 -InputObject @($role)) })
        $roles = Get-VmfSubscriptionRoles -SubscriptionId $sub 6>$null
        $global:VmfThr2Calls.Count | Should -Be 2
        $roles | Should -Not -BeNullOrEmpty
    }

    It 'the image digest read: throttled, then the digest' {
        $digest = 'sha256:' + ('a' * 64)
        Set-Answers @($script:throttled, @{ Exit = 0; Out = $digest })
        (Resolve-VmfImageDigest -Registry 'vmfacrx' -Repository 'vmf-engine' -Tag 't1' -What 'engine' 6>$null).Image | Should -Match ([regex]::Escape($digest))
        $global:VmfThr2Calls.Count | Should -Be 2
    }

    It 'the image digest read throttled on every try keeps its words, and says the throttle' {
        Set-Answers @($script:throttled)
        $err = $null
        try { Resolve-VmfImageDigest -Registry 'vmfacrx' -Repository 'vmf-engine' -Tag 't1' -What 'engine' 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Built the engine image but could not resolve the digest'
        $err | Should -Match 'Too Many Requests \(HTTP 429\) 4 times'
    }

    It 'the image digest read that is refused is not tried again' {
        Set-Answers @($script:refused)
        { Resolve-VmfImageDigest -Registry 'vmfacrx' -Repository 'vmf-engine' -Tag 't1' 6>$null } | Should -Throw '*could not resolve the digest*'
        $global:VmfThr2Calls.Count | Should -Be 1
    }
}

Describe 'INSTALL-THROTTLE-RETRY-2: no install az call is left outside the helper' {
    BeforeAll {
        # The calls that need no retry, by what they are: the Azure CLI's own
        # local state (version, extensions, the signed-in account and its
        # token), and three loops that already try again on ANY failure until
        # their own time limit (trigger sync, the role read back, the function list).
        $script:local = '^az (version|extension|account (show|set|get-access-token)|containerapp job --help)\b'
        $script:loops = @{
            'Deploy-VmfFacade.ps1' = @('az rest --method post --url $syncUrl')
            'postprovision.ps1'    = @('az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo"',
                                       'az functionapp function list')
        }
        function script:Get-BareAz {
            param([string]$Path)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $leaf = Split-Path $Path -Leaf
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'az' }, $true) |
                Where-Object {
                    $parent = $_.Parent; $inside = $false
                    while ($parent) {
                        if ($parent -is [System.Management.Automation.Language.CommandAst] -and
                            $parent.GetCommandName() -match '^Invoke-VmfAz(Call|Step|UpdateWhileBusy)$') { $inside = $true; break }
                        $parent = $parent.Parent
                    }
                    $text = ($_.Extent.Text -replace '^&\s*', '')
                    $allowed = $text -match $script:local -or
                        @($script:loops[$leaf] | Where-Object { $_ -and $text.StartsWith($_) }).Count -gt 0
                    -not $inside -and -not $allowed
                } | ForEach-Object { '{0}:{1}: {2}' -f $leaf, $_.Extent.StartLineNumber, ($_.Extent.Text -split "`n")[0] }
        }
    }

    It '<File> calls az only through Invoke-VmfAzCall, Invoke-VmfAzStep or Invoke-VmfAzUpdateWhileBusy' -ForEach @(
        @{ File = 'tools/Deploy-VmfFacade.ps1' }, @{ File = 'tools/Deploy-VmfDashboard.ps1' }, @{ File = 'tools/Grant-VmfAccess.ps1' }
        @{ File = 'infra/Resolve-VmfRegistration.ps1' }, @{ File = 'infra/Resolve-VmfRoleScopes.ps1' }
        @{ File = 'infra/Resolve-VmfImageDigest.ps1' }, @{ File = 'infra/Wait-VmfJobRun.ps1' }
        @{ File = 'infra/Resolve-VmfInstallerRights.ps1' }, @{ File = 'infra/hooks/Test-VmfReadiness.ps1' }
        @{ File = 'infra/hooks/preprovision.ps1' }, @{ File = 'infra/hooks/postprovision.ps1' }
        @{ File = 'infra/hooks/predown.ps1' }, @{ File = 'infra/hooks/postdown.ps1' }, @{ File = 'infra/hooks/AzdHooks.ps1' }
        # INSTALL-THROTTLE-RETRY-3: the /admin isolation step (FUNCTIONS-ADMIN-ISOLATION-1).
        @{ File = 'infra/Set-VmfFacadeAdminIsolation.ps1' }
    ) {
        @(Get-BareAz -Path (Join-Path $script:repoRoot $File)) | Should -BeNullOrEmpty
    }

    It 'every file that calls the helper loads it' -ForEach @(
        @{ File = 'tools/Grant-VmfAccess.ps1' }, @{ File = 'infra/Resolve-VmfRegistration.ps1' }, @{ File = 'infra/Resolve-VmfRoleScopes.ps1' }
        @{ File = 'infra/Resolve-VmfImageDigest.ps1' }, @{ File = 'infra/Wait-VmfJobRun.ps1' }, @{ File = 'infra/hooks/Test-VmfReadiness.ps1' }
        @{ File = 'infra/Set-VmfFacadeAdminIsolation.ps1' }
    ) {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $File) | Should -Match "'Invoke-VmfAzStep\.ps1'"
    }

    It 'a throttled provider registration is unknown, never a blocker' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1')
        $code | Should -Match "elseif \(\`$registered\.Throttled\) \{ Add-Check `"Provider \`$p`" 'unknown'"
    }
}
