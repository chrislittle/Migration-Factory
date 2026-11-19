# INSTALL-THROTTLE-RETRY-1: the one way an install runs an az step.
#
# FOUND 2026-11-16 in the final lab: azd up, postprovision,
# tools/Deploy-VmfFacade.ps1 step "read app settings" got Azure Resource
# Manager "ERROR: Too Many Requests" (HTTP 429), az exit 1, and the install
# stopped. Everything before it had worked; a second azd up was the recovery.
#
# A throttle says "later", not "no". Microsoft, "Understand how Azure Resource
# Manager throttles requests" (ms.date 2026-02-27): "When you reach the limit,
# you receive the HTTP status code 429 Too many requests. The response
# includes a Retry-After value". "Troubleshoot common Azure deployment errors"
# (ms.date 2025-04-28) names the error code SubscriptionRequestsThrottled, with
# "Please try again after '6' seconds." The Compute throttling page shows a
# body whose inner code is TooManyRequests. The ARM page also gives the words
# of background job throttling: "could not be processed due to an excessive
# volume of traffic. Please try again later." Those are the forms read here;
# nothing else is guessed.
#
# So a throttled answer is tried again, a fixed number of times, with a wait
# between: the Retry-After az prints when it prints one (capped), else 10, 20
# and 40 seconds. Four tries at most, then the step fails as it always did,
# naming the step.
#
# NOTHING ELSE IS TRIED AGAIN. A refusal (403), a resource that is not there
# (404) and a validation error are answers: a second try gets the same answer
# and only hides it for longer. The engine reads its own rule from
# Get-VmfTransientVerdict (src/VmMigrationFactory/Private/azureops/AzureOps.ps1),
# and that module is not loaded by an install hook, so the throttle test is
# kept here, narrow: the words Azure writes, never a bare 429 inside a name.
#
# ONLY AZ'S ERROR STREAM IS READ FOR IT. A build log on standard output can
# hold any words. With -Echo (a log, az acr build) only az's own error lines,
# the ones that start "ERROR:", are read.
#
# Dot-sourced by infra/hooks/AzdHooks.ps1 (every hook), tools/Deploy-VmfFacade.ps1,
# tools/Deploy-VmfDashboard.ps1, tools/Grant-VmfAccess.ps1, and the infra helpers
# that call az (Resolve-VmfRegistration, Resolve-VmfRoleScopes,
# Resolve-VmfImageDigest, Wait-VmfJobRun).

function Test-VmfAzThrottled {
    <#
    .SYNOPSIS
        Is this az error text a throttle? "Too Many Requests", the error codes
        TooManyRequests and SubscriptionRequestsThrottled, the words of ARM
        background job throttling, or 429 where a status code is written.
        A 429 inside a resource name is not one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return $false }
    if ($Text -match '(?i)\bToo\s+Many\s+Requests\b') { return $true }
    if ($Text -match '\b(?:TooManyRequests|SubscriptionRequestsThrottled)\b') { return $true }
    if ($Text -match '(?i)\bexcessive volume of traffic\b') { return $true }
    # A status code, where a message puts one: "HTTP 429", "StatusCode: 429",
    # "Status: 429", "status code 429", "(429)". Never a 429 with a letter,
    # digit or hyphen next to it, which is a part of a name.
    return [bool]($Text -match '(?i)(?<![\w-])(?:HTTP\s+|StatusCode\s*[:=]\s*|Status:\s*|status code\s*:?\s*|\()429(?![\w-])')
}

function Get-VmfAzRetryAfterSeconds {
    <#
    .SYNOPSIS
        The wait Azure asked for, if az printed it: a Retry-After header
        ("Retry-After: 17", "'Retry-After': '17'") or "try again after 17
        seconds" (also "after '17' seconds", Microsoft's own example). $null
        when az printed none.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?i)\bRetry-After\b[''"]?\s*[:=]\s*[''"]?(\d{1,6})\b')
    if (-not $m.Success) {
        $m = [regex]::Match($Text, '(?i)\b(?:retry|try again)\s+(?:after|in)\s+''?(\d{1,6})''?\s*(?:s\b|sec)')
    }
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Get-VmfAzThrottleWaitLine {
    <#
    .SYNOPSIS
        The line the install prints before it waits on a throttle. One copy, so
        every wait says the same words.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][int]$Seconds,
        [int]$Try = 0,
        [int]$MaxTries = 0
    )
    $again = if ($Try -gt 0 -and $MaxTries -gt 0) { "then tries again (try $Try of $MaxTries)." } else { 'then tries again.' }
    "   Azure answered Too Many Requests (HTTP 429) at the step '$Step'. The install waits $Seconds seconds, $again"
}

function Get-VmfAzThrottleNote {
    <#
    .SYNOPSIS
        The sentence added to a step's own failure text when every try was
        throttled; empty otherwise. A caller that keeps its own refusal words
        adds this, so the operator is told it was a throttle.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Result)
    if (-not $Result.Throttled) { return '' }
    " Azure answered Too Many Requests (HTTP 429) $($Result.Tries) times. Run azd up again in a few minutes."
}

function Invoke-VmfAzCall {
    <#
    .SYNOPSIS
        Run one az call, try a throttled answer again, and hand back what
        happened. It never throws for a failure az reports: the caller keeps
        its own failure meaning (Invoke-VmfAzStep is the caller that throws).
    .PARAMETER Quiet
        Do not print what az writes on its error stream; the caller reads it
        from ErrorLines. The throttle wait line is still printed.
    .PARAMETER Echo
        Print standard output as it arrives and keep none of it: a log.
    .OUTPUTS
        ExitCode, Output (standard output lines), ErrorLines (error stream
        lines), Throttled (the last answer was a throttle), Tries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Command,
        [switch]$Echo,
        [switch]$Quiet,
        [ValidateRange(1, 10)][int]$MaxTries = 4,
        [int[]]$WaitSeconds = @(10, 20, 40),
        [int]$MaxWaitSeconds = 300
    )
    # The command's error stream is read, not thrown: with 'Stop' a line az
    # writes there would end the step before its exit code is read. The names
    # below start with 'vmfAzCall' because the command runs in a scope below
    # this one, and a plain $out or $try would hide the caller's own.
    $ErrorActionPreference = 'Continue'
    for ($vmfAzCallTry = 1; ; $vmfAzCallTry++) {
        $global:LASTEXITCODE = 0
        $vmfAzCallOut = [System.Collections.Generic.List[object]]::new()
        $vmfAzCallErr = [System.Collections.Generic.List[string]]::new()
        & $Command 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $vmfAzCallLine = $_.ToString()
                $vmfAzCallErr.Add($vmfAzCallLine)
                if (-not $Quiet) { Write-Host $vmfAzCallLine }
            }
            elseif ($Echo) { Write-Host $_ }
            else { $vmfAzCallOut.Add($_) }
        }
        $vmfAzCallExit = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        $vmfAzCallThrottled = $false
        if ($vmfAzCallExit -ne 0) {
            $vmfAzCallRead = if ($Echo) { @($vmfAzCallErr | Where-Object { $_ -match '^\s*ERROR:' }) } else { @($vmfAzCallErr) }
            $vmfAzCallText = $vmfAzCallRead -join [Environment]::NewLine
            $vmfAzCallThrottled = Test-VmfAzThrottled -Text $vmfAzCallText
            if ($vmfAzCallThrottled -and $vmfAzCallTry -lt $MaxTries) {
                $vmfAzCallWait = Get-VmfAzRetryAfterSeconds -Text $vmfAzCallText
                if ($null -eq $vmfAzCallWait) {
                    $vmfAzCallWait = $WaitSeconds[[Math]::Min($vmfAzCallTry - 1, $WaitSeconds.Count - 1)]
                }
                $vmfAzCallWait = [Math]::Max(1, [Math]::Min([int]$vmfAzCallWait, $MaxWaitSeconds))
                Write-Host (Get-VmfAzThrottleWaitLine -Step $Step -Seconds $vmfAzCallWait -Try ($vmfAzCallTry + 1) -MaxTries $MaxTries)
                Start-Sleep -Seconds $vmfAzCallWait
                continue
            }
        }
        return [pscustomobject]@{
            ExitCode   = $vmfAzCallExit
            Output     = $vmfAzCallOut.ToArray()
            ErrorLines = $vmfAzCallErr.ToArray()
            Throttled  = $vmfAzCallThrottled
            Tries      = $vmfAzCallTry
        }
    }
}

function Invoke-VmfAzStep {
    <#
    .SYNOPSIS
        Run one az step of the install: retry a throttled answer, stop on any
        other failure with "Deploy step failed (az exit N): <Step>".
    .PARAMETER Step
        The step's name, as the operator reads it when the step fails.
    .PARAMETER Command
        The az call, in a script block. Its standard output is returned, as a
        bare az call returns it; what az writes on its error stream is printed
        as it arrives, as it was before.
    .PARAMETER Echo
        Print the output as it arrives and return nothing: for a long step
        whose output is a log (az acr build).
    .PARAMETER AllowFailure
        For a probe whose failure is an answer ("is it there?", "who is signed
        in?"): a failure that is not a throttle returns nothing, prints none of
        its error text, and leaves no exit code behind. A throttle is still
        tried again, and still stops the step when every try is throttled -
        a throttled probe read as "not there" would send the operator the
        wrong way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Command,
        [switch]$Echo,
        [switch]$AllowFailure,
        [ValidateRange(1, 10)][int]$MaxTries = 4,
        [int[]]$WaitSeconds = @(10, 20, 40),
        [int]$MaxWaitSeconds = 300
    )
    $vmfAzStepResult = Invoke-VmfAzCall -Step $Step -Command $Command -Echo:$Echo -Quiet:$AllowFailure `
        -MaxTries $MaxTries -WaitSeconds $WaitSeconds -MaxWaitSeconds $MaxWaitSeconds
    if ($vmfAzStepResult.ExitCode -eq 0) { return $vmfAzStepResult.Output }
    if ($AllowFailure -and -not $vmfAzStepResult.Throttled) { return }
    $vmfAzStepMessage = "Deploy step failed (az exit $($vmfAzStepResult.ExitCode)): $Step"
    if ($vmfAzStepResult.Throttled) {
        $vmfAzStepMessage += ". Azure answered Too Many Requests (HTTP 429) $($vmfAzStepResult.Tries) times. Run azd up again in a few minutes."
    }
    throw $vmfAzStepMessage
}

function Invoke-VmfAzUpdateWhileBusy {
    <#
    .SYNOPSIS
        A Container Apps update that Azure can refuse for a while: another
        operation in flight (OperationInProgress) or a throttle. Both are a
        wait, inside one time limit; any other refusal stops at once.
    .PARAMETER RefusedMessage
        The step's own words for a refusal that is not a wait. '{0}' becomes
        the az exit code. Azure's text follows on a new line.
    .PARAMETER What
        The update, as a sentence names it: 'The publish job update'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Command,
        [Parameter(Mandatory)][string]$RefusedMessage,
        [Parameter(Mandatory)][string]$What,
        [string]$BusyPattern = 'OperationInProgress',
        [int]$Minutes = 10,
        [int]$WaitSeconds = 20,
        [int]$MaxWaitSeconds = 300
    )
    $vmfAzStepDeadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        $vmfAzStepResult = Invoke-VmfAzCall -Step $Step -Command $Command -Quiet -MaxTries 1
        if ($vmfAzStepResult.ExitCode -eq 0) { return }
        $vmfAzStepText = (@($vmfAzStepResult.ErrorLines) + @($vmfAzStepResult.Output | ForEach-Object { [string]$_ })) -join [Environment]::NewLine
        $vmfAzStepBusy = $vmfAzStepText -match $BusyPattern
        if (-not $vmfAzStepBusy -and -not $vmfAzStepResult.Throttled) {
            throw (($RefusedMessage -replace '\{0\}', [string]$vmfAzStepResult.ExitCode) + [Environment]::NewLine + $vmfAzStepText.Trim())
        }
        if ((Get-Date) -gt $vmfAzStepDeadline) {
            if ($vmfAzStepResult.Throttled) {
                throw ("Azure answered Too Many Requests (HTTP 429) to $($What.Substring(0,1).ToLower() + $What.Substring(1)) for $Minutes minutes. " +
                       'Run azd up again in a few minutes.' + [Environment]::NewLine + $vmfAzStepText.Trim())
            }
            throw "$What was blocked by another operation for $Minutes minutes: $($vmfAzStepText.Trim())"
        }
        if ($vmfAzStepResult.Throttled) {
            $vmfAzStepWait = Get-VmfAzRetryAfterSeconds -Text $vmfAzStepText
            if ($null -eq $vmfAzStepWait) { $vmfAzStepWait = $WaitSeconds }
            $vmfAzStepWait = [Math]::Max(1, [Math]::Min([int]$vmfAzStepWait, $MaxWaitSeconds))
            Write-Host (Get-VmfAzThrottleWaitLine -Step $Step -Seconds $vmfAzStepWait)
        }
        else {
            $vmfAzStepWait = $WaitSeconds
            Write-Host "   another operation is in flight on the job; waiting $($WaitSeconds)s"
        }
        Start-Sleep -Seconds $vmfAzStepWait
    }
}
