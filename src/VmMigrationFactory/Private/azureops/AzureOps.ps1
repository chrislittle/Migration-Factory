# azureops v1: the ONLY layer allowed to touch ARM (CLAUDE.md rule 3).
# Everything here is idempotent, retried with backoff+jitter, and mockable -
# unit tests stub the Az cmdlets; the lab is the only place real calls happen.

function Get-VmfEngineSubscriptionId {
    <#
    .SYNOPSIS
        The subscription this engine is signed in to. ENGINE-SUB-1.
    .OUTPUTS
        The id, or $null when there is no context - which callers must treat as
        "cannot tell", never as "it matches".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) { return $null }
    [string]$ctx.Subscription.Id
}

function Resolve-VmfOperationError {
    <#
    .SYNOPSIS
        RETRY-MSG-1: turn a caught error into something an operator can act on,
        and something the transient classifier can actually READ.
    .DESCRIPTION
        Seen in the PERM-2 drill: two red rows whose entire explanation
        was `An error occurred while sending the request.`

        That is .NET's HttpRequestException message. The real cause - a socket
        reset, a DNS failure, a 503 - is in the INNER exception, and nothing
        here ever looked at it. Two consequences, and the second is the serious
        one:

          1. the operator is told nothing they can act on, and
          2. THE TRANSIENT CLASSIFIER READS THE SAME IMPOVERISHED STRING. It
             matches no pattern, so a genuinely retryable failure is called
             permanent and thrown on attempt 1 with the retry budget untouched.
             What recovered in the drill was the state machine re-running the
             whole step - far more expensive, and it surfaces as a failure.

        So this walks the whole exception chain and pulls out the HTTP status
        and the Azure error code wherever they are kept. Pure: no Azure calls,
        unit-testable, and it MUST NOT THROW - it runs inside a catch block,
        where an exception of its own would destroy the error being reported.
    .OUTPUTS
        A hashtable: Message (what a person reads), StatusCode, ErrorCode,
        ClassifyText (what the transient test matches against).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorRecord)

    $parts  = [System.Collections.Generic.List[string]]::new()
    $status = $null
    $code   = $null

    try {
        $ex = $null
        if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            $ex = $ErrorRecord.Exception
            # PowerShell parses an HTTP error body into ErrorDetails, and for
            # ARM that body is where the Azure error CODE lives.
            $body = [string]$ErrorRecord.ErrorDetails.Message
            if ($body) {
                $parts.Add($body)
                try {
                    $j = $body | ConvertFrom-Json -ErrorAction Stop
                    if ($j.error.code) { $code = [string]$j.error.code }
                    elseif ($j.code)   { $code = [string]$j.code }
                }
                catch { }   # not JSON. The raw body is still worth showing.
            }
        }
        elseif ($ErrorRecord -is [Exception]) { $ex = $ErrorRecord }
        else { $parts.Add([string]$ErrorRecord) }

        # Depth-capped: an exception chain can be circular, and a worker that
        # hangs formatting an error message is worse than the error.
        $depth = 0
        while ($ex -and $depth -lt 8) {
            $m = [string]$ex.Message
            if ($m -and -not $parts.Contains($m)) { $parts.Add($m) }

            foreach ($path in 'StatusCode', 'Status', 'Response.StatusCode') {
                if ($null -ne $status) { break }
                try {
                    $v = $ex
                    foreach ($seg in $path.Split('.')) {
                        if ($null -eq $v) { break }
                        $v = $v.PSObject.Properties[$seg].Value
                    }
                    # An HttpStatusCode enum casts to its number; a string does
                    # not, and guessing would invent a status that was never sent.
                    if ($null -ne $v) {
                        $n = $v -as [int]
                        if ($null -ne $n -and $n -ge 100 -and $n -le 599) { $status = $n }
                    }
                }
                catch { }
            }
            if (-not $code) {
                try {
                    $v = $ex.PSObject.Properties['ErrorCode'].Value
                    if ($v) { $code = [string]$v }
                }
                catch { }
            }

            $ex = $ex.InnerException
            $depth++
        }
    }
    catch {
        # Reporting must never be the thing that fails.
        if ($parts.Count -eq 0) { $parts.Add('an error occurred, and it could not be described') }
    }

    $message = ($parts | Where-Object { $_ }) -join ' -> '
    if (-not $message) { $message = 'an error occurred, and it could not be described' }
    # The status and code go in front so they survive any truncation, and so a
    # person sees the actionable part first.
    $prefix = @()
    if ($null -ne $status) { $prefix += "HTTP $status" }
    if ($code)             { $prefix += $code }
    if ($prefix.Count)     { $message = "$($prefix -join ' ') - $message" }

    @{
        Message      = $message
        StatusCode   = $status
        ErrorCode    = $code
        ClassifyText = $message
    }
}

function Get-VmfPolicyDenial {
    <#
    .SYNOPSIS
        ROLLBACK-POLICY-DENY-1: Azure Policy's refusal of a request, read from
        Azure's error, or $null. PURE, and it must not throw: it runs inside a
        catch block.
    .DESCRIPTION
        The shape is Microsoft's ("Resolve errors for request disallowed by
        policy",
        https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-policy-requestdisallowedbypolicy,
        read 2026-11-16): the code RequestDisallowedByPolicy, and the message
        names the assignment as "policyAssignment":{"name":...,"id":...}. A
        REST body (ErrorDetails) has the same text with escaped quotes, and its
        additionalInfo holds policyAssignmentDisplayName, which wins.
        The code counts only as a whole word, outside a quoted name, as
        Get-VmfSizeRefusalCode reads a code. An assignment that cannot be read
        is $null - never a guess.
    .OUTPUTS
        [pscustomobject]@{ Code = 'RequestDisallowedByPolicy'; Assignment = <name or $null> }, or $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Message)
    try {
        if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
        $plain = $Message -replace "'[^'\s]*'", ' '
        if ($plain -cnotmatch '(?<![A-Za-z0-9_-])RequestDisallowedByPolicy(?![A-Za-z0-9_-])') { return $null }
        # A quote, with or without the backslash of a JSON string inside JSON.
        $qt = '\\?"'
        $name = $null
        $m = [regex]::Match($Message, "policyAssignmentDisplayName$qt\s*:\s*$qt(?<n>[^`"\\]+)$qt")
        if ($m.Success) { $name = $m.Groups['n'].Value }
        else {
            $body = [regex]::Match($Message, "policyAssignment$qt\s*:\s*\{(?<b>[^}]*)")
            if ($body.Success) {
                $m = [regex]::Match($body.Groups['b'].Value, "$($qt)name$qt\s*:\s*$qt(?<n>[^`"\\]+)$qt")
                if ($m.Success) { $name = $m.Groups['n'].Value }
            }
        }
        if ($name) {
            $name = $name.Trim()
            # Azure's limit for an assignment's display name is 128 characters.
            if ($name.Length -gt 128) { $name = $name.Substring(0, 128) }
        }
        if (-not $name) { $name = $null }
        [pscustomobject]@{ Code = 'RequestDisallowedByPolicy'; Assignment = $name }
    }
    catch { $null }
}

function Get-VmfPolicyDenialWords {
    <#
    .SYNOPSIS
        ROLLBACK-POLICY-DENY-1: Azure Policy's refusal in one sentence that
        names the assignment, in place of Azure's policy JSON. PURE.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Denial)
    if ([string]$Denial.Assignment) {
        "The Azure Policy assignment '$([string]$Denial.Assignment)' did not allow the request (RequestDisallowedByPolicy)."
    }
    else { 'An Azure Policy assignment did not allow the request (RequestDisallowedByPolicy).' }
}

# AZOP-RETRY-MATCH-1: what makes an Azure error temporary. A number is a status
# code only where a status code is written: on the error object, or in a
# message after the words that put it there. A bare '500' or '503' anywhere in
# the text matched a subscription id, a resource name or a request id, and such
# an error was tried again four times inside a machine's change window.
$script:VmfTransientStatus = @(408, 429, 500, 502, 503, 504)
# Azure's own names for the same answers: the ARM error code, and the name
# AutoRest puts in "Operation returned an invalid status code 'X'".
$script:VmfTransientErrorCodes = @('TooManyRequests', 'InternalServerError', 'ServiceUnavailable',
    'ServerTimeout', 'RetryableError', 'GatewayTimeout', 'BadGateway', 'RequestTimeout')
# Each form puts the status in group 's', exactly three digits, with no digit,
# letter or hyphen after it - so '5030' and '503a-77' are not 503. The FIRST
# form in the text wins: every caller writes its status before the content
# Azure sent, and that content can name another number.
$script:VmfStatusInTextPattern = '(?i)(?:' + (@(
        '\bHTTP\s+\(?(?<s>[1-5]\d\d)'                       # "HTTP 503", "(HTTP 503)", never "http500."
        '\bStatusCode\s*[:=]\s*''?(?<s>[1-5]\d\d)'          # Az: "StatusCode: 503"
        '\bStatus:\s*(?<s>[1-5]\d\d)'                       # Azure.Core: "Status: 503 (Service Unavailable)"
        '\bstatus code\s*:?\s*''?(?<s>[1-5]\d\d)'           # "Response status code 429"
        '\bdoes not indicate success:\s*(?<s>[1-5]\d\d)'    # .NET HttpRequestException
        '\breturned an error:\s*\((?<s>[1-5]\d\d)\)'        # .NET WebException
        '\bstatus\s+''(?<s>[1-5]\d\d)'''                    # "returned status '502'"
        '\bfailed with\s+(?<s>[1-5]\d\d)'                   # "failed with 503: ..."
        '\breturned\s+''?(?<s>[1-5]\d\d)'                   # "returned 409: ...", "returned '409'"
        '\((?<s>[1-5]\d\d)\)\s*:'                           # "... (504): ..."
    ) -join '|') + ')(?![\w-])'
# Words for a failure with no status and no Azure code: a timeout, a throttle,
# or a connection that broke. No number is in this list.
$script:VmfTransientWords = @('throttl', 'timeout', 'timed out', 'connection was reset',
    # RETRY-MSG-1: the inner-exception wordings that were previously
    # invisible, because only the outermost message was ever read.
    'connection attempt failed', 'forcibly closed', 'actively refused',
    'No such host is known', 'Name or service not known', 'broken pipe',
    'unexpected EOF', 'SSL connection could not be established',
    # LINUX-TRANSIENT-1: the engine runs in a LINUX container, where .NET
    # writes the operating system's own words for a socket failure. Measured
    # in the lab: 'Connection reset by peer' at a stop step, and 'Cannot
    # assign requested address' at a rollback, which stopped half done.
    # ('Connection timed out' is caught by 'timed out' above.)
    'reset by peer', 'Cannot assign requested address', 'Network is unreachable',
    'Connection refused',
    # HttpClient reports a request that took too long as a cancel
    # (TaskCanceledException). Nothing in the engine cancels an Azure request
    # for a person - a stop of a run is read between the steps - so this is a
    # timeout. A stopped pipeline says 'The pipeline has been stopped.'
    'operation was canceled')

function Get-VmfTransientVerdict {
    <#
    .SYNOPSIS
        AZOP-RETRY-MATCH-1: is a resolved Azure error temporary, and is it a
        throttle? Pure, and it must not throw: it runs inside a catch block.
    .DESCRIPTION
        In this order, and the first that has an answer decides:
          1. the status code on the error object (Resolve-VmfOperationError),
             both ways - a 403 is an answer whatever its text says;
          2. a status code where a message puts it ($script:VmfStatusInTextPattern),
             both ways, the first one in the text;
          3. an Azure error code's name as a whole word. Resolve-VmfOperationError
             puts the parsed ARM code at the front of the text. This only ever
             says yes: the error code of a socket failure is a number of the
             operating system, not Azure's;
          4. the words of a timeout, a throttle or a broken connection.
        Never a bare number anywhere in the text.
    .PARAMETER ErrorInfo
        The hashtable from Resolve-VmfOperationError.
    .OUTPUTS
        @{ Transient; Throttle; StatusCode (the one used, or $null);
           Source = 'status' | 'text-status' | 'code' | 'words' | 'none' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorInfo)

    $verdict = @{ Transient = $false; Throttle = $false; StatusCode = $null; Source = 'none' }
    try {
        $text = [string]$ErrorInfo.ClassifyText
        $code = [string]$ErrorInfo.ErrorCode
        $status = $null
        if ($null -ne $ErrorInfo.StatusCode) {
            $status = [int]$ErrorInfo.StatusCode
            $verdict.Source = 'status'
        }
        else {
            $m = [regex]::Match($text, $script:VmfStatusInTextPattern)
            if ($m.Success) {
                $status = [int]$m.Groups['s'].Value
                $verdict.Source = 'text-status'
            }
        }
        $codeWord = '\b(?:' + ($script:VmfTransientErrorCodes -join '|') + ')\b'
        # A word inside a name is not that word: a machine 'vm-timeout-01' or a
        # group '/subscriptions/.../rg-throttle' is a name. So the words are
        # read with every quoted name (no space inside the quotes) and every
        # resource id taken out.
        $plain = $text -replace '/subscriptions/\S+', ' ' -replace "'[^'\s]*'", ' '
        if ($null -ne $status) {
            $verdict.StatusCode = $status
            $verdict.Transient = $script:VmfTransientStatus -contains $status
        }
        elseif ($text -match $codeWord) {
            $verdict.Transient = $true
            $verdict.Source = 'code'
        }
        else {
            foreach ($word in $script:VmfTransientWords) {
                if ($plain -match [regex]::Escape($word)) { $verdict.Transient = $true; $verdict.Source = 'words'; break }
            }
        }
        # SCALE-1: only a throttle tells the other workers to wait. A 429, or
        # Azure's TooManyRequests, or the word throttled - never a 429 that is
        # only a part of a name, and never a 503.
        $verdict.Throttle = $verdict.Transient -and (
            $status -eq 429 -or $code -eq 'TooManyRequests' -or
            ($null -eq $status -and ($text -match '\bTooManyRequests\b' -or $plain -match 'throttl')))
    }
    catch {
        # Classifying must never be the thing that fails. Not temporary: the
        # error goes to the caller once, as it was.
        $verdict = @{ Transient = $false; Throttle = $false; StatusCode = $null; Source = 'none' }
    }
    $verdict
}

function Invoke-VmfAzOperation {
    <#
    .SYNOPSIS
        Run an Azure operation with bounded retries, exponential backoff and jitter.
    .DESCRIPTION
        Retries on transient/throttling failures (429, timeouts, 5xx, socket resets).
        Non-transient errors (authorization, not found, validation) fail immediately -
        retrying those only wastes the wave's window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$MaxAttempts = 4,
        [Parameter()][int]$BaseDelayMs = 1000,
        [Parameter()][string]$RunPath,
        [Parameter()][string]$VmId,
        # DISK-TYPE-WORDS-1: fields for every line this operation writes - the
        # run page names a disk type change from its skuName. The operation's
        # own fields (attempt, the error codes) are never replaced by one.
        [Parameter()][hashtable]$EventData
    )

    $extraData = if ($EventData) { $EventData } else { @{} }
    $withEventData = {
        param([hashtable]$Own)
        $all = @{}
        foreach ($k in $extraData.Keys) { $all[$k] = $extraData[$k] }
        foreach ($k in $Own.Keys) { $all[$k] = $Own[$k] }
        $all
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # In-step lease renewal (S3-7): a single state can run many 60s guest
        # commands, so renewing only between states let the watchdog falsely
        # reap healthy workers. Every ARM call passes here - the hook (set by
        # the state machine while a worker holds a lease) renews before each
        # operation. A lost lease throws OUTSIDE the try: fencing must abort,
        # never be retried as a transient Azure error.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }

        # SCALE-1: ease off if ANOTHER worker on this run has just been
        # throttled. One worker's 429 is evidence about the subscription, not
        # about that worker - the others are about to find out the same way, and
        # arriving together is what turns a burst into a wave-wide failure.
        # Cached, so this is not a store read per ARM call, and it can only ever
        # ADD a short jittered delay.
        if ($RunPath) {
            $paceMs = Get-VmfPacingWaitMs -RunPath $RunPath
            if ($paceMs -gt 0) { Start-Sleep -Milliseconds $paceMs }
        }
        # STEP-LOG-1: only the operation is inside the try. Its "ok" line was
        # written there, and a line that could not be written landed in the
        # catch below, which could read a store error as transient and run the
        # operation AGAIN. The line now comes after the try, with its own
        # handler - and anything it still lets through (a lost lease) is never
        # classified as an Azure error.
        $succeeded = $false
        # PERF-TELEMETRY-1: the operation is the ARM call the record counts,
        # and the requests inside it are not counted again.
        $script:VmfCallTimingArmDepth++
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $Operation
            $succeeded = $true
        }
        catch {
            $script:VmfCallTimingArmDepth--
            Add-VmfCallTiming -Kind arm -Operation $Name -Failed -DurationMs $sw.Elapsed.TotalMilliseconds
            # The WHOLE error, not just its outermost sentence. See
            # Resolve-VmfOperationError: reading only .Exception.Message left
            # both the operator and this classifier with "An error occurred
            # while sending the request."
            $err = Resolve-VmfOperationError -ErrorRecord $_
            $msg = $err.Message
            # AZOP-RETRY-MATCH-1: the status code, where Azure or the caller
            # put it, decides - never a number anywhere in the text.
            $verdict = Get-VmfTransientVerdict -ErrorInfo $err
            $isTransient = $verdict.Transient
            # RESERVING-STUCK-1: a reservation Azure did not confirm in time is
            # an answer, not a passing fault. Its sentence carries the group's
            # name, and a name can hold 429 or 503; retrying would make the
            # whole create and its wait again.
            if ($err.ClassifyText -like "*$($script:VmfReservationUnconfirmedWords)*") { $isTransient = $false }
            # SWAP-2UPD-1: a data-disk swap left neither way is an answer too. A re-run
            # would find an empty LUN and lose the message that names each disk.
            if ($err.ClassifyText -like "*$($script:VmfSwapNeitherWords)*") { $isTransient = $false }
            # SWAP-REFUSED-AFTER-STOP-1: a data-disk swap Azure refused, with the
            # old disks verified back on their LUNs (Invoke-VmfDataDiskSwap marks
            # it). The machine is stopped and nothing changed, so it is tried
            # again whatever Azure's code - the rule is that every disk
            # goes back. A swap left neither way is caught above and never is.
            elseif ($_.Exception.Data -and $_.Exception.Data['vmfSwapRefused']) { $isTransient = $true }
            # POWER-ONLY-CHANGED-1: a put-back of the power state a machine was
            # found in, that Azure refused (Invoke-VmfPowerPutBack marks it).
            # Nothing else on the machine changed, and the rule is that
            # the machine goes back to its power state, so it is tried again
            # whatever Azure's code.
            elseif ($_.Exception.Data -and $_.Exception.Data['vmfPowerRefused']) { $isTransient = $true }
            # COPY-DELETE-LOCK-RACE-1: a safety copy delete refused with
            # ScopeLocked just after the product removed the copy's lock
            # (Invoke-VmfSafetyCopyDelete marks it). Azure can still apply a
            # lock for a moment after its removal, so it is tried again, within
            # the caller's -MaxAttempts.
            elseif ($_.Exception.Data -and $_.Exception.Data['vmfLockLag']) { $isTransient = $true }

            if (-not $isTransient -or $attempt -eq $MaxAttempts) {
                if ($RunPath) {
                    # ROLLBACK-POLICY-DENY-1: an Azure Policy refusal that holds
                    # Azure's policy JSON is said as the assignment's name. The
                    # thrown error is untouched, for the caller to read.
                    $lineWords = $msg
                    $denial = Get-VmfPolicyDenial -Message $msg
                    if ($denial -and ($denial.Assignment -or $msg -match 'policyAssignment|policyDefinition')) { $lineWords = Get-VmfPolicyDenialWords -Denial $denial }
                    # ACTIVITY-LINES-1 (finding 60): the status code Azure sent,
                    # also when it is only in Azure's words ("StatusCode: 409") -
                    # the one the classifier read (Get-VmfTransientVerdict).
                    Write-VmfStepLine -RunPath $RunPath -Step "azureops:$Name" -Outcome fail -VmId $VmId `
                        -Detail $lineWords -Data (& $withEventData @{ attempt = $attempt; transient = $isTransient
                                              statusCode = $verdict.StatusCode; errorCode = $err.ErrorCode })
                }
                throw
            }

            # SCALE-1: a throttle is the one transient worth telling the other
            # workers about. Not a 500 or a socket reset - those are about this
            # call. A 429 is about the subscription, and every other worker is
            # heading for the same answer.
            if ($RunPath -and $verdict.Throttle) {
                Write-VmfThrottleSignal -RunPath $RunPath
            }

            $delay = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
            $jitter = Get-Random -Minimum 0 -Maximum ([int][math]::Max(1, $delay * 0.3))
            if ($RunPath) {
                Write-VmfStepLine -RunPath $RunPath -Step "azureops:$Name" -Outcome retry -VmId $VmId `
                    -Detail $msg -Data (& $withEventData @{ attempt = $attempt; delayMs = [int]($delay + $jitter)
                                          statusCode = $verdict.StatusCode; errorCode = $err.ErrorCode })
            }
            Start-Sleep -Milliseconds ($delay + $jitter)
        }
        if ($succeeded) {
            $script:VmfCallTimingArmDepth--
            Add-VmfCallTiming -Kind arm -Operation $Name -DurationMs $sw.Elapsed.TotalMilliseconds
            if ($RunPath) {
                Write-VmfStepLine -RunPath $RunPath -Step "azureops:$Name" -Outcome ok -VmId $VmId `
                    -DurationSec $sw.Elapsed.TotalSeconds -Data (& $withEventData @{ attempt = $attempt })
            }
            return $result
        }
    }
}

function Get-VmfVmCapture {
    <#
    .SYNOPSIS
        Capture a VM's full pre-mutation configuration as a plain, JSON-safe
        hashtable for the state doc (the recreate/rollback source of truth).
    .PARAMETER Vm
        A VM object from Get-AzVM (or a compatible test double).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Vm,
        # DISK-TYPE-DEALLOCATED-1 (review): filled with what Azure said, per
        # disk id, for each disk read that failed - so the stop at PRECHECK
        # names the cause (a missing permission, a throttle), not only the gap.
        # Never written into the capture itself.
        [Parameter()][hashtable]$DiskReadErrors
    )

    # REBUILD-PROPS-1: the settings below are read the same way Verifying
    # reads the machine after the move (Get-VmfRebuildSettingsFromVm).
    $settings = Get-VmfRebuildSettingsFromVm -Vm $Vm
    # DISK-TYPE-DEALLOCATED-1, MEASURED 2026-11-05: Azure's model of a
    # DEALLOCATED machine gives each managedDisk with ONLY its id - no
    # storageAccountType - and no diskSizeGB on any disk (az vm show, Get-AzVM
    # and four REST api versions). The disk resource always has both. So a
    # disk the model gives no type or size for is read by its id. Only then:
    # a running machine's model carries the disk's own values, and a read per
    # disk on every capture would buy nothing. A read that fails leaves the
    # value empty - never a guess - and PRECHECK refuses a disk with no type,
    # or a data disk with no size (Get-VmfDiskTypeUnknownStop), before anything
    # changes, with what Azure said (-DiskReadErrors).
    $diskRead = @{}
    $fromDisk = {
        param([string]$DiskId)
        if (-not $DiskId) { return $null }
        if ($diskRead.ContainsKey($DiskId)) { return $diskRead[$DiskId] }
        $facts = $null
        try {
            $facts = Invoke-VmfAzOperation -Name 'captureReadDisk' -VmId ([string]$Vm.Id) -Operation { Get-VmfManagedDiskFacts -DiskId $DiskId }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            if ($null -ne $DiskReadErrors) { $DiskReadErrors[$DiskId] = [string]$_.Exception.Message }
            $facts = $null
        }
        $diskRead[$DiskId] = $facts
        $facts
    }
    $osType = [string]$Vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
    if (-not $osType) {
        $osFacts = & $fromDisk ([string]$Vm.StorageProfile.OsDisk.ManagedDisk.Id)
        if ($osFacts) { $osType = [string]$osFacts.skuName }
    }
    $capture = [ordered]@{
        vmId       = $Vm.Id
        name       = $Vm.Name
        location   = $Vm.Location
        size       = $Vm.HardwareProfile.VmSize
        controller = $Vm.StorageProfile.DiskControllerType
        osType     = [string]$Vm.StorageProfile.OsDisk.OsType
        osDisk     = [ordered]@{
            name          = $Vm.StorageProfile.OsDisk.Name
            managedDiskId = $Vm.StorageProfile.OsDisk.ManagedDisk.Id
            deleteOption  = $Vm.StorageProfile.OsDisk.DeleteOption
            # UX-STUCK-1, found by its drill: rebuilding a machine from a safety
            # copy has to CREATE a disk, and a disk cannot be created without
            # saying what performance tier it is. The capture never recorded it,
            # so the rebuild sent an empty sku and Azure refused with "Required
            # property 'name' not found in 'sku'". The tier is a property of the
            # machine we are promising to restore, so it belongs in the capture -
            # by the time it is needed, the disk it came from may be gone.
            # DISK-TYPE-DEALLOCATED-1: from the disk when the model gives none.
            skuName       = $osType
            # REBUILD-PROPS-1: the rebuild attaches the disk with these again.
            caching                 = $settings.osDisk.caching
            writeAcceleratorEnabled = $settings.osDisk.writeAcceleratorEnabled
        }
        dataDisks  = @(foreach ($dd in @($Vm.StorageProfile.DataDisks)) {
            # DISK-TYPE-DEALLOCATED-1: the type and size from the disk when
            # the model gives none.
            $ddType = [string]$dd.ManagedDisk.StorageAccountType
            $ddSize = $dd.DiskSizeGB
            if (-not $ddType -or $null -eq $ddSize) {
                $ddFacts = & $fromDisk ([string]$dd.ManagedDisk.Id)
                if ($ddFacts) {
                    if (-not $ddType) { $ddType = [string]$ddFacts.skuName }
                    if ($null -eq $ddSize -and $null -ne $ddFacts.diskSizeGB) { $ddSize = [int]$ddFacts.diskSizeGB }
                }
            }
            [ordered]@{
                name          = $dd.Name
                lun           = $dd.Lun
                managedDiskId = $dd.ManagedDisk.Id
                caching       = [string]$dd.Caching
                sizeGB        = $ddSize
                deleteOption  = $dd.DeleteOption
                # SAFETY-ALL-1: a put-back makes this disk again from its copy,
                # and a disk cannot be made without its type (UX-STUCK-1 found
                # the same for the OS disk).
                skuName       = $ddType
                # REBUILD-PROPS-1: a move refuses it; a rebuild on the same size puts it back.
                writeAcceleratorEnabled = [bool]$dd.WriteAcceleratorEnabled
            }
        })
        nics       = @(foreach ($nic in @($Vm.NetworkProfile.NetworkInterfaces)) {
            # AN state read per-NIC (AN-1): capture is the rollback source of truth
            $nicName = ($nic.Id -split '/')[-1]
            $nicRg = ($nic.Id -split '/')[4]
            $accelNet = $null
            try {
                $nicObj = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg -ErrorAction Stop
                $accelNet = [bool]$nicObj.EnableAcceleratedNetworking
            }
            catch { $accelNet = $null }
            # REBUILD-PROPS-1: the delete option, which the rebuild sets again.
            [ordered]@{ id = $nic.Id; primary = [bool]$nic.Primary; acceleratedNetworking = $accelNet
                deleteOption = $(if ([string]$nic.DeleteOption) { [string]$nic.DeleteOption } else { $null }) }
        })
        zones      = @($Vm.Zones)
        tags       = if ($Vm.Tags) { [hashtable]$Vm.Tags } else { @{} }
        licenseType        = $Vm.LicenseType
        availabilitySetId  = if ($Vm.AvailabilitySetReference) { $Vm.AvailabilitySetReference.Id } else { $null }
        proximityGroupId   = if ($Vm.ProximityPlacementGroup) { $Vm.ProximityPlacementGroup.Id } else { $null }
        priority           = $Vm.Priority
        # ROLLBACK-CRG-1 (vm-state v24): the capacity reservation group the
        # machine is in, or $null for none. Every put-back puts the machine
        # back in it. Always written, so every record says; a put-back of a
        # record that does not say stops (Get-VmfPutBackRecordGap).
        capacityReservationGroupId = if ($Vm.CapacityReservation -and $Vm.CapacityReservation.CapacityReservationGroup) {
            [string]$Vm.CapacityReservation.CapacityReservationGroup.Id } else { $null }
        # EVAL-C1: identityType was captured here and read NOWHERE - one write,
        # zero reads across the whole repository - and the Path B rebuild set no
        # identity at all. A machine came back with none. Deleting a VM destroys
        # its system-assigned service principal, and re-enabling identity mints
        # a NEW principal id, so every role assignment, Key Vault policy and AAD
        # SQL user bound to the old one is orphaned and cannot be repaired by
        # turning the setting back on. The type alone was never enough to
        # rebuild a user-assigned identity either, so the ids are captured too.
        identityType       = if ($Vm.Identity) { [string]$Vm.Identity.Type } else { $null }
        identity           = if ($Vm.Identity) {
            [ordered]@{
                type            = [string]$Vm.Identity.Type
                userAssignedIds = @(if ($Vm.Identity.UserAssignedIdentities) {
                    @($Vm.Identity.UserAssignedIdentities.Keys) | ForEach-Object { [string]$_ }
                })
                # IDENTITY-2: the SYSTEM-assigned principal's object id, recorded
                # because a rebuild destroys it and mints a different one. This
                # is the only place the old id will ever exist again - the
                # machine will not know it, and neither will Azure. Without it,
                # an operator who accepts the loss has no way to find what used
                # to be granted to it.
                principalId     = [string]$Vm.Identity.PrincipalId
            }
        } else { $null }
        # TRUST-1: Path B deletes the machine definition and
        # rebuilds it from THIS document. Before this field existed, a Trusted
        # Launch machine went through that rebuild with no record of secure
        # boot or vTPM - whatever ARM defaulted to is what the customer got,
        # and validation never compared. A security posture resting on an
        # unmeasured platform default is uncontrolled whichever way the
        # default falls.
        securityProfile    = if ($Vm.SecurityProfile) {
            [ordered]@{
                securityType       = [string]$Vm.SecurityProfile.SecurityType
                secureBootEnabled  = if ($Vm.SecurityProfile.UefiSettings) { [bool]$Vm.SecurityProfile.UefiSettings.SecureBootEnabled } else { $null }
                vTpmEnabled        = if ($Vm.SecurityProfile.UefiSettings) { [bool]$Vm.SecurityProfile.UefiSettings.VTpmEnabled } else { $null }
                encryptionAtHost   = if ($null -ne $Vm.SecurityProfile.EncryptionAtHost) { [bool]$Vm.SecurityProfile.EncryptionAtHost } else { $null }
            }
        } else { $null }
        ultraSsdEnabled    = if ($Vm.AdditionalCapabilities) { [bool]$Vm.AdditionalCapabilities.UltraSSDEnabled } else { $false }
        bootDiagnostics    = if ($Vm.DiagnosticsProfile -and $Vm.DiagnosticsProfile.BootDiagnostics) {
            [ordered]@{
                enabled    = [bool]$Vm.DiagnosticsProfile.BootDiagnostics.Enabled
                storageUri = $Vm.DiagnosticsProfile.BootDiagnostics.StorageUri
            }
        } else { $null }
        imageReference     = if ($Vm.StorageProfile.ImageReference) {
            [ordered]@{
                publisher = $Vm.StorageProfile.ImageReference.Publisher
                offer     = $Vm.StorageProfile.ImageReference.Offer
                sku       = $Vm.StorageProfile.ImageReference.Sku
            }
        } else { $null }
        # REBUILD-PROPS-1 (vm-state v31): what a rebuild dropped before. A
        # machine with none records none ($null / $false). Always written, so
        # Verifying fails a capture without them (Test-VmfRebuildSettingsFidelity).
        # NO-PLAN-SCOPE-1 (v34): no purchase plan. Checking stops a machine
        # with one, outside the scope of this tool, so no rebuild sends one.
        # The patch settings: an Attach create has no osProfile, so they are
        # set again after the create. No step sets them now (REBUILD-REMOVE-ROLE-1); Verifying compares them.
        patchSettings      = $settings.patchSettings
        # THAT the machine has user data - never the value. The run store is
        # readable by every reader of the dashboard, and user data is the
        # machine's own. So no rebuild can put it back, and a move refuses it.
        userDataPresent    = $settings.userDataPresent
        # VERIFY-HOST-HIBERNATION-UNUSED-1 (v44): no dedicated host, host group
        # or hibernation. Checking stops a machine with any of them before the
        # capture (Get-VmfHostHibernationStop), so no capture holds one.
        evictionPolicy     = $settings.evictionPolicy
        maxPrice           = $settings.maxPrice
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    # JSON round-trip guard: the capture must serialize losslessly for the state doc
    $null = $capture | ConvertTo-Json -Depth 12
    return $capture
}

function Get-VmfPowerState {
    <#
    .SYNOPSIS
        Return the VM's power state code, e.g. 'PowerState/running'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status
    $code = ($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code
    if (-not $code) { throw "Could not determine power state for VM '$Name'." }
    return $code
}

function Stop-VmfVmDeallocated {
    <#
    .SYNOPSIS
        Deallocate a VM and poll until Azure confirms PowerState/deallocated.
        Idempotent: returns immediately if already deallocated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$TimeoutSeconds = 360,
        [Parameter()][int]$PollIntervalSeconds = 15
    )

    if ((Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name) -eq 'PowerState/deallocated') {
        return
    }

    # EVAL-LAB-1 / H1, FOUND BY THE LAB DRILL 2026-08-30. -NoWait is not a
    # micro-optimisation, it is the whole fix. Without it Stop-AzVM BLOCKS
    # until Azure finishes, so all the waiting happened HERE, before the
    # poll loop below - and by the time the loop ran, the machine had
    # already reached the state and the very first iteration returned. The
    # heartbeat two lines down was never reached, not once, in a 44-second
    # operation. Measured: zero renewals.
    #
    # The EVAL-H1 unit test asserts the heartbeat is invoked IN THE LOOP,
    # and it is - the loop was simply not where the time went. Only a real
    # Azure wait could show that, which is exactly why EVAL-LAB-1 existed.
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Force -NoWait | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPollError = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        # EVAL-LAB-1: with -NoWait the machine is genuinely mid-transition when
        # this first polls, and Azure sometimes reports NO power-state code at
        # all - which Get-VmfPowerState correctly treats as fatal, because
        # everywhere ELSE an unreadable power state must not be guessed at.
        # Inside a poll that is waiting FOR a state, though, "cannot tell yet"
        # is simply "not yet": it is not being read as a yes or a no, and the
        # timeout below still ends it. Found by the drill - the first -NoWait
        # run threw "Could not determine power state" a second after issuing
        # the start.
        try { $state = Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name }
        catch { $state = $null; $lastPollError = $_.Exception.Message }
        if ($state -eq 'PowerState/deallocated') { return }
        # EVAL-H1: renew the lease WHILE waiting. The wrapper renews before
        # each ARM operation, but a single call that polls for up to ten
        # minutes is ONE operation - so nothing renewed during the longest
        # waits the engine performs, and the watchdog reaped healthy workers
        # mid-conversion, handing a machine to a second worker while the first
        # was still inside the poll.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw ("VM '$Name' did not reach PowerState/deallocated within ${TimeoutSeconds}s." +
           $(if ($lastPollError) { " Last power-state read said: $lastPollError" }))
}

function Stop-VmfVmPoweredOff {
    <#
    .SYNOPSIS
        CLUSTER-DETECT-1: stop a VM and keep it allocated (PowerState/stopped),
        and poll until Azure confirms it. Idempotent.
    .DESCRIPTION
        Only to put a machine back as it was: Checking starts a machine that
        was stopped (not deallocated) to run the cluster check inside it, and
        a machine it must not move goes back to stopped, not to deallocated.
        Stop-AzVM -StayProvisioned is Microsoft.Compute/virtualMachines/
        powerOff/action, already in the execute role (rbac-actions.json).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$TimeoutSeconds = 360,
        [Parameter()][int]$PollIntervalSeconds = 15
    )

    if ((Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name) -eq 'PowerState/stopped') { return }
    # -NoWait, then poll, for the reason Stop-VmfVmDeallocated gives (EVAL-LAB-1).
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -StayProvisioned -Force -NoWait | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPollError = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try { $state = Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name }
        catch { $state = $null; $lastPollError = $_.Exception.Message }
        if ($state -eq 'PowerState/stopped') { return }
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw ("VM '$Name' did not reach PowerState/stopped within ${TimeoutSeconds}s." +
           $(if ($lastPollError) { " Last power-state read said: $lastPollError" }))
}

function Set-VmfOsDiskControllerTypes {
    <#
    .SYNOPSIS
        Patch the OS disk's supported disk controller types ('SCSI, NVMe' or 'SCSI').
        Idempotent: skips the update when the value already matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiskResourceGroup,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter(Mandatory)][ValidateSet('SCSI, NVMe', 'SCSI')][string]$ControllerTypes
    )

    $disk = Get-AzDisk -ResourceGroupName $DiskResourceGroup -DiskName $DiskName
    $current = $disk.SupportedCapabilities.DiskControllerTypes
    if ($current -eq $ControllerTypes) { return }

    $disk.SupportedCapabilities = @{ DiskControllerTypes = $ControllerTypes }
    $result = $disk | Update-AzDisk
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "OS disk '$DiskName' capability update returned provisioning state '$($result.ProvisioningState)'."
    }
}

function Get-VmfImageVersionFacts {
    <#
    .SYNOPSIS
        IMAGE-1 and GEN1-IMAGE-1: what Azure reports about the latest version
        of one marketplace image.
    .DESCRIPTION
        Reads the LATEST version of the image at api-version 2024-07-01 - older
        versions do not return features at all, and Get-AzVMImage returns an
        empty Features array. Measured: Gen1 images report DiskControllerTypes
        "SCSI"; Gen2 images report "SCSI, NVMe". Canonical 22_04-lts is the
        exception that shows why this is read, never inferred: it is V1 and
        reports "SCSI, NVMe".

        Returns version, hyperVGeneration and architecture as well as the NVMe
        answer, because GEN1-IMAGE-1 confirms that two SKUs are the same build
        by comparing them.

        Returns $null when the answer cannot be obtained - a delisted image, a
        permission gap, any error. Unknown must never be turned into a yes or
        a no by this function; the caller decides what to do with silence.

        Cached per image because a fleet runs a handful of distinct images
        across thousands of machines.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Offer,
        [Parameter(Mandatory)][string]$Sku
    )

    if (-not $script:VmfImageFeatureCache) { $script:VmfImageFeatureCache = @{} }
    $key = "$Location/$Publisher/$Offer/$Sku".ToLowerInvariant()
    if ($script:VmfImageFeatureCache.ContainsKey($key)) { return $script:VmfImageFeatureCache[$key] }

    $result = $null
    try {
        $subId = (Get-AzContext).Subscription.Id
        $base = "/subscriptions/$subId/providers/Microsoft.Compute/locations/$Location/publishers/$Publisher/artifacttypes/vmimage/offers/$Offer/skus/$Sku"
        $list = Invoke-AzRestMethod -Method GET -Path "$base/versions?api-version=2024-07-01"
        $versions = if ($list.StatusCode -eq 200) { @($list.Content | ConvertFrom-Json) } else { @() }
        if ($versions.Count -gt 0) {
            $latest = [string]$versions[-1].name
            $one = Invoke-AzRestMethod -Method GET -Path "$base/versions/$latest`?api-version=2024-07-01"
            if ($one.StatusCode -eq 200) {
                $detail = $one.Content | ConvertFrom-Json
                $result = [pscustomobject]@{
                    sku              = $Sku
                    version          = $latest
                    hyperVGeneration = [string]$detail.properties.hyperVGeneration
                    architecture     = [string]$detail.properties.architecture
                    nvme             = Test-VmfImageSupportsNvme -Features $detail.properties.features
                }
            }
        }
    }
    catch { $result = $null }

    $script:VmfImageFeatureCache[$key] = $result
    $result
}

function Get-VmfImageSkuNames {
    <#
    .SYNOPSIS
        GEN1-IMAGE-1: the names of every SKU in one marketplace image offer.
    .DESCRIPTION
        The same catalogue read as Get-VmfImageVersionFacts, one level up. Used
        only to find the Gen2 edition of a Gen1 image. Returns $null when the
        list cannot be read. Cached per offer.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Offer
    )

    if (-not $script:VmfImageSkuCache) { $script:VmfImageSkuCache = @{} }
    $key = "$Location/$Publisher/$Offer".ToLowerInvariant()
    if ($script:VmfImageSkuCache.ContainsKey($key)) { return $script:VmfImageSkuCache[$key] }

    $result = $null
    try {
        $subId = (Get-AzContext).Subscription.Id
        $path = "/subscriptions/$subId/providers/Microsoft.Compute/locations/$Location/publishers/$Publisher/artifacttypes/vmimage/offers/$Offer/skus?api-version=2024-07-01"
        $list = Invoke-AzRestMethod -Method GET -Path $path
        if ($list.StatusCode -eq 200) { $result = @(@($list.Content | ConvertFrom-Json) | ForEach-Object { [string]$_.name }) }
    }
    catch { $result = $null }

    $script:VmfImageSkuCache[$key] = $result
    $result
}
function Invoke-VmfResourceGraphQuery {
    <#
    .SYNOPSIS
        BOUNDARY-1: one page of an Azure Resource Graph query, retried.
    .DESCRIPTION
        This lives in azureops because it is an ARM call (CLAUDE.md rule 3),
        but the reason it MOVED here is not tidiness: the assessment used to
        call Resource Graph directly and throw on any non-200, INCLUDING 429
        TooManyRequests. Resource Graph throttles aggressively and the product
        pages through fleets of thousands of machines, so a large scan could
        lose everything to a single throttle. Now it retries with backoff like
        every other Azure call, and a genuine 403 still fails immediately.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter()][string]$RunPath
    )

    $payload = $Body | ConvertTo-Json -Depth 8
    $opArgs = @{ Name = 'resourceGraphQuery' }
    if ($RunPath) { $opArgs.RunPath = $RunPath }
    $response = Invoke-VmfAzOperation @opArgs -Operation {
        $r = Invoke-AzRestMethod -Method POST `
            -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
            -Payload $payload
        # Throwing INSIDE the operation is what lets the retry logic see a 429
        # for what it is; returning it would make a throttle look like success.
        if ($r.StatusCode -notin @(200)) {
            throw "Resource Graph query failed: HTTP $($r.StatusCode) - $($r.Content)"
        }
        $r
    }
    $response.Content | ConvertFrom-Json -Depth 24
}

function Get-VmfSkuCatalog {
    <#
    .SYNOPSIS
        Fetch the VM SKU catalog for a region, cached per run session.
        Get-AzComputeResourceSku is expensive; N workers must not each call it.
    .PARAMETER SubscriptionId
        ZONES-1: read the catalog AS this subscription, and cache it per
        subscription. Restrictions (NotAvailableForSubscription) and zone
        numbers belong to a subscription - each maps logical zones to physical
        ones its own way - so a catalog read for one subscription answers
        nothing about zones in another. Without it: the ambient context, as
        before, for facts that do not depend on the subscription.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowEmptyString()][string]$SubscriptionId,
        [Parameter()][switch]$Refresh
    )

    if (-not $script:VmfSkuCache) { $script:VmfSkuCache = @{} }
    $key = if ($SubscriptionId) { "$($SubscriptionId.ToLowerInvariant())|$($Location.ToLowerInvariant())" } else { $Location.ToLowerInvariant() }
    if ($Refresh -or -not $script:VmfSkuCache.ContainsKey($key)) {
        $skuArgs = @{ Location = $Location }
        if ($SubscriptionId) { $skuArgs.DefaultProfile = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId }
        $listed = @(Get-AzComputeResourceSku @skuArgs |
            Where-Object { $_.ResourceType -eq 'virtualMachines' })
        # RESERVE-RECHECK-1 review: an empty list is Azure not answering. Kept
        # in the cache, every later read in this session saw no sizes at all.
        if ($listed.Count -eq 0) { return }
        $script:VmfSkuCache[$key] = $listed
    }
    $script:VmfSkuCache[$key]
}
