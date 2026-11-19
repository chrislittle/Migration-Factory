#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-THROTTLE-RETRY-1: an install stopped on ONE throttled read.
#
# Found 2026-11-16 in the final lab: azd up, postprovision, tools/Deploy-VmfFacade.ps1
# step "read app settings" got Azure Resource Manager "ERROR: Too Many Requests"
# (HTTP 429), az exit 1, and the hook threw. Everything before it had worked.
#
# Every install az step now runs through infra/Invoke-VmfAzStep.ps1: a throttled
# answer (429, Too Many Requests, TooManyRequests) is tried again a fixed number
# of times, with Retry-After when az prints one; any other failure stops at once,
# as before, naming the step.
#
# The stand-in az is a function, and one test uses a real child process, so the
# path az itself takes (text on the standard error stream) is proved too.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:helperPath = Join-Path $script:repoRoot 'infra' 'Invoke-VmfAzStep.ps1'
    . $script:helperPath

    # The stand-in az: each call takes the next answer from the queue. An
    # answer is @{ Exit = n; Out = 'stdout text'; Err = 'stderr text' }. The
    # last answer repeats when the queue is empty.
    function global:az {
        $global:VmfThrottleAzCalls += , ($args -join ' ')
        $answer = if ($global:VmfThrottleAnswers.Count -gt 1) {
            $first = $global:VmfThrottleAnswers[0]
            $global:VmfThrottleAnswers = @($global:VmfThrottleAnswers | Select-Object -Skip 1)
            $first
        } else { $global:VmfThrottleAnswers[0] }
        if ($answer.Err) { Write-Error -Message $answer.Err -ErrorAction Continue }
        $global:LASTEXITCODE = [int]$answer.Exit
        if ($answer.Out) { $answer.Out }
    }
    function script:Set-Answers { param([object[]]$Answers) $global:VmfThrottleAnswers = @($Answers); $global:VmfThrottleAzCalls = @() }
    $script:ok = @{ Exit = 0; Out = '[{"name":"AzureWebJobsStorage__accountName","value":"vmfstateexample"}]' }
    $script:throttled = @{ Exit = 1; Err = 'ERROR: Too Many Requests' }
    $script:forbidden = @{ Exit = 1; Err = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Web/sites/config/list/action' over scope '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.Web/sites/vmf-facade-429'." }
}

AfterAll {
    Remove-Item 'function:\az' -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name VmfThrottleAnswers, VmfThrottleAzCalls -ErrorAction SilentlyContinue
}

Describe 'INSTALL-THROTTLE-RETRY-1: what a throttled answer is' {
    It 'is a throttle: <Name>' -ForEach @(
        @{ Name = 'the words az printed in the lab'; Text = 'ERROR: Too Many Requests' }
        @{ Name = 'the ARM error code'; Text = "ERROR: (TooManyRequests) The request is being throttled." }
        @{ Name = 'a Graph throttle'; Text = 'ERROR: Too many requests. Please retry later.' }
        @{ Name = 'an HTTP status line'; Text = 'HTTP 429 returned by the service' }
        @{ Name = 'a status code line'; Text = 'Operation returned an invalid status code: StatusCode: 429' }
    ) {
        Test-VmfAzThrottled -Text $Text | Should -BeTrue
    }

    It 'is no throttle: <Name>' -ForEach @(
        @{ Name = 'a refusal (403)'; Text = 'ERROR: (AuthorizationFailed) The client does not have authorization. Status: 403' }
        @{ Name = 'not found (404)'; Text = "ERROR: (ResourceNotFound) The Resource 'Microsoft.Web/sites/x' was not found. HTTP 404" }
        @{ Name = 'a validation error'; Text = 'ERROR: (InvalidTemplate) Deployment template validation failed.' }
        @{ Name = '429 only inside a name'; Text = "ERROR: (ResourceNotFound) The site 'vmf-facade-429' was not found." }
        @{ Name = '429 in brackets inside a name'; Text = "ERROR: (ResourceNotFound) The disk 'data(429)' was not found." }
        @{ Name = 'a number that starts with 429'; Text = "ERROR: (InvalidResourceName) The name '(429-app)' is not valid." }
        @{ Name = 'nothing'; Text = '' }
    ) {
        Test-VmfAzThrottled -Text $Text | Should -BeFalse
    }

    It 'reads a Retry-After that az prints: <Text>' -ForEach @(
        @{ Text = "Retry-After: 17"; Want = 17 }
        @{ Text = "'Retry-After': '33'"; Want = 33 }
        @{ Text = 'Please try again after 25 seconds.'; Want = 25 }
    ) {
        Get-VmfAzRetryAfterSeconds -Text $Text | Should -Be $Want
    }

    It 'finds no Retry-After when az prints none' {
        Get-VmfAzRetryAfterSeconds -Text 'ERROR: Too Many Requests' | Should -BeNullOrEmpty
    }
}

Describe 'INSTALL-THROTTLE-RETRY-1: Invoke-VmfAzStep' {
    BeforeEach { Mock Start-Sleep {} }

    It 'two throttled answers, then success: returns the output, and waits 10 then 20 seconds' {
        Set-Answers @($script:throttled, $script:throttled, $script:ok)
        $settings = Invoke-VmfAzStep -Step 'read app settings' -Command { az functionapp config appsettings list -o json } 6>$null | ConvertFrom-Json
        $settings.name | Should -Be 'AzureWebJobsStorage__accountName'
        $global:VmfThrottleAzCalls.Count | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
        $LASTEXITCODE | Should -Be 0
    }

    It 'says each wait, with the step and the try' {
        Set-Answers @($script:throttled, $script:ok)
        $said = Invoke-VmfAzStep -Step 'read app settings' -Command { az x } 6>&1 | Out-String
        $said | Should -Match "Azure answered Too Many Requests \(HTTP 429\) at the step 'read app settings'\."
        $said | Should -Match 'The install waits 10 seconds, then tries again \(try 2 of 4\)\.'
    }

    It 'always throttled: stops after 4 tries, names the step, and waits 10, 20 and 40 seconds' {
        Set-Answers @($script:throttled)
        $err = $null
        try { Invoke-VmfAzStep -Step 'read app settings' -Command { az x } 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Deploy step failed \(az exit 1\): read app settings'
        $err | Should -Match 'Too Many Requests \(HTTP 429\) 4 times'
        $global:VmfThrottleAzCalls.Count | Should -Be 4
        Should -Invoke Start-Sleep -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 40 }
    }

    It 'a refusal (403) is not tried again, and names the step' {
        Set-Answers @($script:forbidden, $script:ok)
        $err = $null
        try { Invoke-VmfAzStep -Step 'read app settings' -Command { az x } 6>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'Deploy step failed \(az exit 1\): read app settings'
        $err | Should -Not -Match '429'
        $global:VmfThrottleAzCalls.Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'a failure with no text at all is not tried again' {
        Set-Answers @(@{ Exit = 3 }, $script:ok)
        { Invoke-VmfAzStep -Step 'zip deploy the dashboard' -Command { az x } 6>$null } |
            Should -Throw 'Deploy step failed (az exit 3): zip deploy the dashboard*'
        $global:VmfThrottleAzCalls.Count | Should -Be 1
    }

    It 'honours a Retry-After that az prints, in place of the fixed wait' {
        Set-Answers @(@{ Exit = 1; Err = "ERROR: Too Many Requests`nRetry-After: 7" }, $script:ok)
        Invoke-VmfAzStep -Step 's' -Command { az x } 6>$null | Out-Null
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It 'a Retry-After longer than 5 minutes waits 5 minutes, never longer' {
        Set-Answers @(@{ Exit = 1; Err = "ERROR: Too Many Requests`nRetry-After: 86400" }, $script:ok)
        Invoke-VmfAzStep -Step 's' -Command { az x } 6>$null | Out-Null
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 300 }
    }

    It 'a throttle that ends in a refusal stops at the refusal' {
        Set-Answers @($script:throttled, $script:forbidden, $script:ok)
        { Invoke-VmfAzStep -Step 'read app settings' -Command { az x } 6>$null } | Should -Throw '*read app settings*'
        $global:VmfThrottleAzCalls.Count | Should -Be 2
    }

    It '-AllowFailure: a refusal returns nothing, prints none of its text, and leaves no exit code' {
        Set-Answers @($script:forbidden, $script:ok)
        $printed = Invoke-VmfAzStep -Step 'read the signed-in user' -AllowFailure -Command { az x } 6>&1 | Out-String
        $printed | Should -Not -Match 'AuthorizationFailed'
        $LASTEXITCODE | Should -Be 0
        Set-Answers @($script:forbidden, $script:ok)
        $returned = @(Invoke-VmfAzStep -Step 'read the signed-in user' -AllowFailure -Command { az x } 6>$null)
        $returned.Count | Should -Be 0
        $global:VmfThrottleAzCalls.Count | Should -Be 1
    }

    It '-AllowFailure: a throttle is still tried again' {
        Set-Answers @($script:throttled, $script:ok)
        $returned = Invoke-VmfAzStep -Step 'read the service app' -AllowFailure -Command { az x } 6>$null | ConvertFrom-Json
        $returned.name | Should -Be 'AzureWebJobsStorage__accountName'
        $global:VmfThrottleAzCalls.Count | Should -Be 2
    }

    It '-AllowFailure: every try throttled still stops the step (never read as "not there")' {
        Set-Answers @($script:throttled)
        { Invoke-VmfAzStep -Step 'read the service app' -AllowFailure -Command { az x } 6>$null } |
            Should -Throw '*read the service app*Too Many Requests (HTTP 429) 4 times*'
        $global:VmfThrottleAzCalls.Count | Should -Be 4
    }

    It 'with -Echo, prints the output and returns none' {
        Set-Answers @(@{ Exit = 0; Out = 'build log line' })
        $printed = Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command { az acr build } 6>&1 | Out-String
        $printed | Should -Match 'build log line'
        Set-Answers @(@{ Exit = 0; Out = 'build log line' })
        $returned = @(Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command { az acr build } 6>$null)
        $returned.Count | Should -Be 0
    }

    It 'the caller''s variables reach the command (no name of the helper hides them)' {
        Set-Answers @($script:ok)
        $Step = 'caller'; $try = 'caller'; $out = 'caller'
        $ResourceGroup = 'rg-example'
        Invoke-VmfAzStep -Step 'read app settings' -Command { az show -g $ResourceGroup } 6>$null | Out-Null
        $global:VmfThrottleAzCalls[0] | Should -Be 'show -g rg-example'
    }

    It 'a real process that writes the throttle on its standard error stream is tried again' {
        # az is a child process: its error text arrives on the standard error
        # stream, not as a PowerShell error. Prove that path with a real one.
        $global:VmfThrottleNative = 0
        $pwshPath = (Get-Process -Id $PID).Path
        $cmd = {
            $global:VmfThrottleNative++
            if ($global:VmfThrottleNative -lt 3) {
                & $pwshPath -NoProfile -NonInteractive -Command '[Console]::Error.WriteLine(''ERROR: Too Many Requests''); exit 1'
            }
            else {
                & $pwshPath -NoProfile -NonInteractive -Command 'Write-Output ''done''; exit 0'
            }
        }
        $result = Invoke-VmfAzStep -Step 'read app settings' -Command $cmd 6>$null
        $result | Should -Be 'done'
        $global:VmfThrottleNative | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Remove-Variable -Scope Global -Name VmfThrottleNative -ErrorAction SilentlyContinue
    }
}

Describe 'INSTALL-THROTTLE-RETRY-1: every install az step goes through the helper' {
    BeforeAll {
        $script:facade = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1')
        $script:dash = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $script:hooks = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1')
        $script:post = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
        $script:pre = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
        $script:down = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1')
    }

    It '<Name> loads the helper' -ForEach @(
        @{ Name = 'Deploy-VmfFacade.ps1'; Key = 'facade' }
        @{ Name = 'Deploy-VmfDashboard.ps1'; Key = 'dash' }
        @{ Name = 'AzdHooks.ps1 (every hook)'; Key = 'hooks' }
    ) {
        (Get-Variable -Scope Script -Name $Key).Value | Should -Match "Invoke-VmfAzStep\.ps1"
    }

    It '<Name> has no step left that only checks the exit code after the call' -ForEach @(
        @{ Name = 'Deploy-VmfFacade.ps1'; Key = 'facade' }
        @{ Name = 'Deploy-VmfDashboard.ps1'; Key = 'dash' }
        @{ Name = 'postprovision.ps1'; Key = 'post' }
        @{ Name = 'preprovision.ps1'; Key = 'pre' }
        @{ Name = 'postdown.ps1'; Key = 'down' }
    ) {
        (Get-Variable -Scope Script -Name $Key).Value | Should -Not -Match 'Assert-AzOk'
    }

    It 'the read that failed in the lab is a retried step' {
        $script:facade | Should -Match "Invoke-VmfAzStep -Step 'read app settings'"
    }

    It 'Deploy-VmfFacade reads the function app once, for its name and its id' {
        ([regex]::Matches($script:facade, 'az functionapp show')).Count | Should -Be 1
    }

    It 'the old exit code helpers are gone, so no step can use them by mistake' {
        foreach ($text in $script:facade, $script:dash, $script:hooks) { $text | Should -Not -Match 'function Assert-AzOk' }
    }
}
