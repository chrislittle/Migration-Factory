# PERF-TELEMETRY-1: the time of each call the service makes to the run store
# and to Azure Resource Manager, written as ONE trace line per invocation.
#
# WHY. PERF-ANALYSIS-1 found the `dependencies` table of the lab install's
# Application Insights empty for seven days: the PowerShell worker does not
# report the HTTP calls that Invoke-WebRequest and Invoke-AzRestMethod make.
# So a 60-second schedule pass and a 115-second GetRuns showed only their
# total, and nobody could say how much of it was the store.
#
# WHY A TRACE LINE. Microsoft gives a PowerShell function app no way to write
# a custom dependency: "OpenTelemetry output to Application Insights from the
# language worker isn't currently supported for PowerShell apps"
# (learn.microsoft.com/azure/azure-functions/opentelemetry-howto, PowerShell),
# and the classic SDK route exists for C#, JavaScript and Python only
# (functions-monitoring, "Dependencies"). The worker DOES send the information
# stream to `traces` at the Information level (functions-reference-powershell,
# "Logging"), with the invocation's operation_Id - so a query joins the line
# to its request. No SDK is loaded, nothing is added to start-up, and no new
# setting or Azure resource is needed.
#
# WHY ONE LINE PER INVOCATION. A schedule pass makes about a thousand store
# calls every five minutes. One row per call would pass the workspace's
# 0.2 GB daily cap by itself. So each invocation counts its calls here and
# writes one line at its end, naming only the slowest and the failed calls.
#
# WHAT IS NEVER RECORDED: a token, an account name, a query string (a SAS
# signature, a list marker, a skip token), a subscription id, a group or a
# resource name. A store call is named by its path in the container; an ARM
# call by its resource type, with every name replaced by {}.
#
# THE ENGINE (PERF-TELEMETRY-ENGINE-1) starts a record at each step of a
# machine (Start-VmfStepCallTimings) and puts its summary on the step's closing
# line in the run's activity log (Stop-VmfStepCallTimings), never on the
# console: a worker's console output goes to a file in the container, not to
# Log Analytics. Its record names only run store calls in `slow` and `ops` -
# each Azure operation has its own activity line with its time - and writes no
# part line. Outside a step, every call there is a no-op: one test of a script
# variable. Nothing grows in a long engine worker.
#
# A PowerShell runspace runs one invocation at a time, and this module's
# script scope belongs to the runspace, so concurrent invocations on one
# instance never share a record.

$script:VmfCallTimings = $null
# A call this slow (or a failed one) is named in the line.
$script:VmfCallTimingSlowMs = 1000
# At most this many named calls; the slowest are kept.
$script:VmfCallTimingKeep = 10
# The function timeout on Consumption is five minutes, and a timed-out
# invocation never reaches its finally. So the first call COUNTED after a
# record is this old writes a partial line, once. THERE IS NO TIMER: the check
# runs only inside Add-VmfCallTiming, so an invocation that makes no further
# call after this age - one call that hangs, or a body that stops calling -
# writes no partial line, and if the host then times it out, no line at all.
# A pass that keeps calling, as the timers do, is measured.
# PERF-TELEMETRY-HUNG-1 closed the two ways one call could hold an invocation
# to the limit: an ARM request now ends at a time limit (Receive-VmfArmAnswer)
# and is counted; a store request names itself in a part line after an
# attempt that waited (Write-VmfCallTimingHeld). STORE-REQUEST-TIMEOUT-1 then
# gave a store request in the service a limit of 40 s in all
# (Get-VmfStoreRequestLimit), where its attempts could take about 8 minutes.
$script:VmfCallTimingInterimMs = 240000
# PERF-TELEMETRY-HUNG-1: an attempt of a call that got no answer after this
# long writes a part line that names the call (`held`). STORE-REQUEST-TIMEOUT-1:
# less than the 20 s a store attempt waits in the service, so an attempt that
# reached its limit is named; an attempt that fails fast (a refused
# connection, about a thousand in a store outage) writes nothing.
$script:VmfCallTimingHeldMs = 15000
# Inside an Azure operation (Invoke-VmfAzOperation) the operation is the ARM
# call; the requests it makes are not counted again.
$script:VmfCallTimingArmDepth = 0

function Start-VmfCallTimings {
    <#
    .SYNOPSIS
        Begin the record of one invocation. Clears any record a previous
        invocation in this runspace left behind.
    #>
    [CmdletBinding()]
    param(
        # The kinds of call the record names in `slow` and `ops`. Every kind
        # is counted in its totals either way. The service names all three.
        [Parameter()][ValidateSet('store', 'arm', 'token')][string[]]$NamedKinds = @('store', 'arm', 'token'),
        # No part line: for a record that does not end at a host time limit.
        [Parameter()][switch]$NoInterim,
        # Not counted in the calls open in the process (an engine step).
        [Parameter()][switch]$Uncounted
    )
    $script:VmfCallTimingArmDepth = 0
    # A record a previous invocation of this runspace left open (the host
    # stopped it) was counted once; this one takes its place in the count.
    $wasCounted = ($null -ne $script:VmfCallTimings) -and $script:VmfCallTimings.Counted
    if ($wasCounted -and $Uncounted) { $null = Step-VmfCallTimingsOpen -By -1 }
    elseif (-not $wasCounted -and -not $Uncounted) { $null = Step-VmfCallTimingsOpen -By 1 }
    $script:VmfCallTimings = @{
        Clock    = [System.Diagnostics.Stopwatch]::StartNew()
        Kinds    = @{}
        Ops      = @{}
        Slow     = [System.Collections.Generic.List[object]]::new()
        Dropped  = 0
        Interim  = [bool]$NoInterim
        Named    = @($NamedKinds)
        Counted  = -not $Uncounted
        # STORE-CALL-SLOW-1 round 3: the pool as the calls were counted, and
        # the store calls by their time.
        PoolMaxThreads = 0
        PoolMaxPending = 0
        TcpStart = (Get-VmfCallTimingSafe { Get-VmfTcpCounters })
        Spread   = [ordered]@{ lt50 = 0; lt250 = 0; lt1000 = 0; lt1500 = 0; ge1500 = 0 }
    }
}

# STORE-CALL-SLOW-1 round 3: THE THREAD POOL IN EACH SERVICE CALL'S LINE.
#
# The lab install after the raised pool minimum (2026-11-08): the timer's store
# calls still waited - many 1015-1035 ms, one 2007 ms - with no failure and the
# processor about 2% busy, while page calls waited up to 15 s BEFORE their
# function body ran. The line now says, from the worker process itself:
# processors, the pool's minimum, its threads now and the most seen in this
# call, the work waiting now and the most seen, the service calls open in the
# process, and whether this process raised the minimum. With the store call
# times by range, the next install shows whether the pool ran short.
$script:VmfCallTimingsOpenSlot = 'VmMigrationFactory.CallTimings.Open.v1'

function Get-VmfCallTimingsOpenCell {
    # One counter for the process (AppDomain data), shared by every runspace.
    $domain = [System.AppDomain]::CurrentDomain
    $cell = $domain.GetData($script:VmfCallTimingsOpenSlot)
    if ($cell) { return , $cell }
    [System.Threading.Monitor]::Enter($domain)
    try {
        $cell = $domain.GetData($script:VmfCallTimingsOpenSlot)
        if (-not $cell) { $cell = [int[]]::new(1); $domain.SetData($script:VmfCallTimingsOpenSlot, $cell) }
    }
    finally { [System.Threading.Monitor]::Exit($domain) }
    , $cell
}

function Step-VmfCallTimingsOpen {
    param([Parameter(Mandatory)][int]$By)
    try {
        $cell = Get-VmfCallTimingsOpenCell
        # A [ref] to an array item in PowerShell is a copy, so a lock, not
        # Interlocked.
        [System.Threading.Monitor]::Enter($cell)
        try { $cell[0] = [Math]::Max(0, $cell[0] + $By); $cell[0] }
        finally { [System.Threading.Monitor]::Exit($cell) }
    }
    catch { $null = $_; 0 }
}

function Get-VmfCallTimingsOpen {
    # The service calls with an open record in this process.
    [OutputType([int])]
    param()
    $cell = Get-VmfCallTimingsOpenCell
    [System.Threading.Monitor]::Enter($cell)
    try { $cell[0] } finally { [System.Threading.Monitor]::Exit($cell) }
}

function Get-VmfTcpCounters {
    # The computer's TCP counters (IPv4 and IPv6 together): connections opened
    # and segments sent again. $null where the host does not give them.
    try {
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $opened = 0L; $resent = 0L
        foreach ($family in 'InterNetwork', 'InterNetworkV6') {
            try {
                $s = $props.GetTcpIPv4Statistics()
                if ($family -eq 'InterNetworkV6') { $s = $props.GetTcpIPv6Statistics() }
                $opened += $s.ConnectionsInitiated; $resent += $s.SegmentsResent
            }
            catch { $null = $_ }
        }
        @{ opened = $opened; resent = $resent }
    }
    catch { $null = $_; $null }
}

function Get-VmfCallTimingSafe {
    # One diagnostic read: its value, or $null when it throws. A read that
    # fails never loses the line (the review of round 3).
    param([Parameter(Mandatory)][scriptblock]$Read)
    try { & $Read } catch { $null = $_; $null }
}

function Get-VmfProcessUpSeconds {
    # How long this process has run, in seconds.
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    try { [int]([datetime]::Now - $proc.StartTime).TotalSeconds }
    finally { $proc.Dispose() }
}

function Get-VmfCallTimingPool {
    # The pool now, with the most this record saw. Each field is read on its
    # own and is $null when its read fails. maxThreads and maxPending are the
    # most seen at the moments the calls were counted, not a continuous peak:
    # a short rise between two calls is not seen.
    param($Record)
    $now = Get-VmfCallTimingSafe { Get-VmfThreadPoolNow }
    $threads = Get-VmfCallTimingSafe { [System.Threading.ThreadPool]::ThreadCount }
    $pending = Get-VmfCallTimingSafe { [System.Threading.ThreadPool]::PendingWorkItemCount }
    $tcp = Get-VmfCallTimingSafe {
        $tcpNow = Get-VmfTcpCounters
        if ($Record.TcpStart -and $tcpNow) {
            [ordered]@{ opened = $tcpNow.opened - $Record.TcpStart.opened; resent = $tcpNow.resent - $Record.TcpStart.resent }
        }
        else { $null }
    }
    [ordered]@{
        cpus       = (Get-VmfCallTimingSafe { [System.Environment]::ProcessorCount })
        # The worker process and how long it has run, so a restart shows.
        process    = (Get-VmfCallTimingSafe { [System.Environment]::ProcessId })
        upS        = (Get-VmfCallTimingSafe { Get-VmfProcessUpSeconds })
        min        = $(if ($now) { $now.min } else { $null })
        max        = $(if ($now) { $now.max } else { $null })
        free       = $(if ($now) { $now.free } else { $null })
        threads    = $threads
        maxThreads = (Get-VmfCallTimingSafe { [Math]::Max([int]$Record.PoolMaxThreads, [int]$threads) })
        pending    = $pending
        maxPending = (Get-VmfCallTimingSafe { [Math]::Max([long]$Record.PoolMaxPending, [long]$pending) })
        open       = (Get-VmfCallTimingSafe { Get-VmfCallTimingsOpen })
        floor      = (Get-VmfCallTimingSafe { $held = [System.AppDomain]::CurrentDomain.GetData($script:VmfStorageHttpSlot); [bool]($held -and $held.Floor) })
        # FACADE-PASS-SHARE-1: Azure PowerShell's data collection in this
        # process (off, on, notLoaded or failed), set when the store client was
        # made; $null before that.
        azData     = (Get-VmfCallTimingSafe { $held = [System.AppDomain]::CurrentDomain.GetData($script:VmfStorageHttpSlot); if ($held) { $held.AzData } else { $null } })
        # The runspace's own thread: a thread-pool thread or one of its own.
        onPool     = (Get-VmfCallTimingSafe { [System.Threading.Thread]::CurrentThread.IsThreadPoolThread })
        # The computer's TCP connections opened and segments sent again during
        # this service call: about one opened per store call means the pooled
        # connection was not reused.
        tcp        = $tcp
    }
}

function ConvertTo-VmfCallTarget {
    <#
    .SYNOPSIS
        The part of an address that is safe to record. A store address gives
        its path in the container; an ARM address gives its resource type with
        every name replaced by {}. Anything else is '<redacted>'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('store', 'arm', 'token')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$Target
    )
    if ($Kind -eq 'token') { return '' }
    if ($Kind -eq 'store') {
        $u = $null
        if (-not [uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$u)) { return '<redacted>' }
        if ($u.Scheme -ne 'https' -or $u.Host -notmatch '^[a-z0-9]+\.blob\.core\.windows\.net$') { return '<redacted>' }
        # The first segment is the container; the rest is the store path.
        $segments = @($u.AbsolutePath.TrimStart('/') -split '/' | Select-Object -Skip 1)
        $path = (@($segments | ForEach-Object { [uri]::UnescapeDataString($_) }) -join '/')
        if (-not $path) {
            # A listing names its prefix, which is a store path, and nothing
            # else from its query.
            foreach ($pair in ($u.Query.TrimStart('?') -split '&')) {
                $kv = $pair -split '=', 2
                if ($kv.Count -eq 2 -and $kv[0] -eq 'prefix') { $path = [uri]::UnescapeDataString($kv[1]) }
            }
        }
        return $path
    }
    # ARM: a path, or a whole address (a nextLink) on the ARM endpoint.
    $armPath = $Target
    if ($Target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $u = $null
        if (-not [uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$u)) { return '<redacted>' }
        if ($u.Scheme -ne 'https' -or $u.Host -notmatch '^management\.(azure\.com|usgovcloudapi\.net|chinacloudapi\.cn)$') { return '<redacted>' }
        $armPath = $u.AbsolutePath
    }
    $armPath = ($armPath -split '\?', 2)[0]
    $parts = @($armPath.Trim('/') -split '/' | Where-Object { $_ })
    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $parts.Count) {
        $seg = $parts[$i]
        if ($seg -in @('subscriptions', 'resourceGroups', 'resourcegroups', 'managementGroups')) {
            $out.Add($seg)
            if ($i + 1 -lt $parts.Count) { $out.Add('{}') }
            $i += 2
        }
        elseif ($seg -eq 'providers') {
            $out.Add($seg)
            # The namespace is kept; then type and name alternate, and a type
            # with no name after it (an action, a collection) is kept.
            if ($i + 1 -lt $parts.Count) { $out.Add($parts[$i + 1]) }
            $i += 2
            while ($i -lt $parts.Count -and $parts[$i] -ne 'providers') {
                $out.Add($parts[$i])
                if ($i + 1 -lt $parts.Count -and $parts[$i + 1] -ne 'providers') { $out.Add('{}') }
                $i += 2
            }
        }
        else {
            # Anything this reader does not know is not recorded.
            $out.Add('{}')
            $i += 1
        }
    }
    $out -join '/'
}

function Get-VmfCallOperation {
    <#
    .SYNOPSIS
        A short name for what a call did: read, list, write, append, delete or
        exists for the store; the method for ARM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter()][string]$Method,
        [Parameter()][string]$Target
    )
    $m = ([string]$Method).ToUpperInvariant()
    if ($Kind -ne 'store') { return $m }
    $comp = ''
    if ($Target -match '[?&]comp=([a-zA-Z]+)') { $comp = $Matches[1].ToLowerInvariant() }
    switch ($m) {
        'GET' { if ($comp -eq 'list') { 'list' } elseif ($comp) { "get $comp" } else { 'read' } }
        'HEAD' { 'exists' }
        'PUT' { if ($comp -eq 'appendblock') { 'append' } elseif ($comp) { "put $comp" } else { 'write' } }
        'DELETE' { 'delete' }
        default { $m.ToLowerInvariant() }
    }
}

function Test-VmfCallSucceeded {
    # A 404 is an answer: a document not written yet, a safety copy already
    # deleted. In the store so are 409 and 412 (a create that lost, a version
    # that moved). Status 0 is no response.
    param([string]$Kind, [int]$Status)
    if ($Status -le 0) { return $false }
    if ($Status -lt 400 -or $Status -eq 404) { return $true }
    return ($Kind -eq 'store' -and $Status -in @(409, 412))
}

function Add-VmfCallTiming {
    <#
    .SYNOPSIS
        Count one call into this invocation's record. Does nothing when no
        record was started, and never throws.
    .PARAMETER Operation
        A name for the call in place of the one read from Method and Target -
        an Azure operation's name.
    .PARAMETER Status
        The HTTP status. Left out for a call with no single status (an Azure
        operation); then the call failed only when -Failed is given.
    .PARAMETER Overlapped
        One of several requests sent at once (Invoke-VmfStorageGetMany). It
        counts as a call - number, longest, failed, operation, slow list - but
        its time is not added to the kind's total, because the requests ran
        side by side.
    .PARAMETER TimeOnly
        The wall time of such a batch: added to the kind's total and to its own
        operation, and counted as no call.
    .NOTES
        An ARM call made while an Azure operation runs is not counted: the
        operation is counted when it ends, at depth zero again. So an
        operation inside another operation is not counted either.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('store', 'arm', 'token')][string]$Kind,
        [Parameter()][string]$Method,
        [Parameter()][AllowEmptyString()][string]$Target,
        [Parameter()][int]$Status,
        [Parameter(Mandatory)][double]$DurationMs,
        [Parameter()][string]$Operation,
        [Parameter()][switch]$Failed,
        [Parameter()][switch]$Overlapped,
        [Parameter()][switch]$TimeOnly
    )
    try {
        $rec = $script:VmfCallTimings
        if ($null -eq $rec) { return }
        if ($Kind -eq 'arm' -and $script:VmfCallTimingArmDepth -gt 0) { return }

        $ms = [int][Math]::Round($DurationMs)
        $ok = if ($Kind -eq 'token') { $true }
              elseif (-not $PSBoundParameters.ContainsKey('Status')) { -not $Failed }
              else { (-not $Failed) -and (Test-VmfCallSucceeded -Kind $Kind -Status $Status) }
        $statusValue = if ($PSBoundParameters.ContainsKey('Status')) { $Status } else { $null }
        $op = if ($Operation) { $Operation } else { Get-VmfCallOperation -Kind $Kind -Method $Method -Target $Target }

        if ($rec.ContainsKey('Spread')) {
            # Its own try: a failed read of the pool never loses the call's count.
            try {
                if ($Kind -eq 'store' -and -not $Overlapped -and -not $TimeOnly) {
                    $bucket = if ($DurationMs -lt 50) { 'lt50' } elseif ($DurationMs -lt 250) { 'lt250' } elseif ($DurationMs -lt 1000) { 'lt1000' } elseif ($DurationMs -lt 1500) { 'lt1500' } else { 'ge1500' }
                    $rec.Spread[$bucket]++
                }
                $threads = [System.Threading.ThreadPool]::ThreadCount
                $pending = [System.Threading.ThreadPool]::PendingWorkItemCount
                if ($threads -gt $rec.PoolMaxThreads) { $rec.PoolMaxThreads = $threads }
                if ($pending -gt $rec.PoolMaxPending) { $rec.PoolMaxPending = $pending }
            }
            catch { $null = $_ }
        }
        if (-not $rec.Kinds.ContainsKey($Kind)) { $rec.Kinds[$Kind] = @{ n = 0; ms = 0; max = 0; fail = 0 } }
        $k = $rec.Kinds[$Kind]
        if (-not $Overlapped) { $k.ms += $ms }
        if (-not $TimeOnly) {
            $k.n++
            if ($ms -gt $k.max) { $k.max = $ms }
            if (-not $ok) { $k.fail++ }
        }

        # PERF-TELEMETRY-ENGINE-1: a kind the record does not name is counted
        # above and goes no further.
        $named = (-not $rec.ContainsKey('Named')) -or ($Kind -in $rec.Named)
        if (-not $named) { return }

        $opKey = "$Kind $op"
        if (-not $rec.Ops.ContainsKey($opKey)) { $rec.Ops[$opKey] = @{ n = 0; ms = 0; max = 0 } }
        $o = $rec.Ops[$opKey]
        $o.n++; $o.ms += $ms
        if ($ms -gt $o.max) { $o.max = $ms }

        if ($Kind -ne 'token' -and -not $TimeOnly -and ($ms -ge $script:VmfCallTimingSlowMs -or -not $ok)) {
            $entry = [ordered]@{
                k      = $Kind
                op     = $op
                target = (ConvertTo-VmfCallTarget -Kind $Kind -Target $Target)
                status = $statusValue
                ms     = $ms
                ok     = $ok
            }
            if ($rec.Slow.Count -lt $script:VmfCallTimingKeep) { $rec.Slow.Add($entry) }
            else {
                # Keep the slowest: replace the fastest kept call when this one
                # is slower, and count the call that leaves.
                $minIndex = 0
                for ($i = 1; $i -lt $rec.Slow.Count; $i++) { if ($rec.Slow[$i].ms -lt $rec.Slow[$minIndex].ms) { $minIndex = $i } }
                if ($ms -gt $rec.Slow[$minIndex].ms) { $rec.Slow[$minIndex] = $entry }
                $rec.Dropped++
            }
        }

        if (-not $rec.Interim -and $rec.Clock.Elapsed.TotalMilliseconds -ge $script:VmfCallTimingInterimMs) {
            $rec.Interim = $true
            Write-VmfCallTimingLine -Message ('VMF-CALLS ' + (Get-VmfCallTimingSummary -Partial | ConvertTo-Json -Depth 6 -Compress))
        }
    }
    catch {
        # Telemetry never fails the call it measures.
        $null = $_
    }
}

function Get-VmfCallTimingSummary {
    <#
    .SYNOPSIS
        This invocation's record as one object: per kind (store, token, arm)
        the count, total, longest and failed; per operation the count, total
        and longest; the slow and failed calls; and the time left for the
        service itself (total less store and ARM - the token time is part of
        the store time).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Partial,
        # For a test: the invocation's total, in place of the clock.
        [Parameter()][double]$ElapsedMs = -1
    )
    $rec = $script:VmfCallTimings
    $total = if ($ElapsedMs -ge 0) { [int]$ElapsedMs } else { [int][Math]::Round($rec.Clock.Elapsed.TotalMilliseconds) }
    $empty = @{ n = 0; ms = 0; max = 0; fail = 0 }
    $kind = { param($name) if ($rec.Kinds.ContainsKey($name)) { $rec.Kinds[$name] } else { $empty } }
    $store = & $kind 'store'
    $arm = & $kind 'arm'
    $ops = [ordered]@{}
    foreach ($key in @($rec.Ops.Keys | Sort-Object)) { $ops[$key] = $rec.Ops[$key] }
    [ordered]@{
        v           = 1
        partial     = [bool]$Partial
        ms          = $total
        store       = $store
        token       = (& $kind 'token')
        arm         = $arm
        other       = [Math]::Max(0, $total - $store.ms - $arm.ms)
        ops         = $ops
        slow        = @($rec.Slow | Sort-Object { $_.ms } -Descending)
        slowDropped = $rec.Dropped
    }
}

function Write-VmfCallTimingHeld {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-HUNG-1: one attempt of a call got no answer after
        -ElapsedMs, and the call goes on. Writes a part line with the record so
        far and `held`: the call's kind, operation, target, attempt and time so
        far. Only at $script:VmfCallTimingHeldMs or more, only when a record
        was started, and never throws. The caller writes it once for a call.
    .OUTPUTS
        $true when it wrote the line.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('store', 'arm')][string]$Kind,
        [Parameter()][string]$Method,
        [Parameter()][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][double]$ElapsedMs,
        [Parameter()][int]$Attempt = 1
    )
    try {
        if ($null -eq $script:VmfCallTimings) { return $false }
        if ($ElapsedMs -lt $script:VmfCallTimingHeldMs) { return $false }
        $summary = Get-VmfCallTimingSummary -Partial
        $summary.held = [ordered]@{
            k       = $Kind
            op      = (Get-VmfCallOperation -Kind $Kind -Method $Method -Target $Target)
            target  = (ConvertTo-VmfCallTarget -Kind $Kind -Target $Target)
            attempt = $Attempt
            ms      = [int][Math]::Round($ElapsedMs)
        }
        Write-VmfCallTimingLine -Message ('VMF-CALLS ' + ($summary | ConvertTo-Json -Depth 6 -Compress))
        return $true
    }
    catch {
        # Telemetry never fails the call it measures.
        $null = $_
        return $false
    }
}

function Write-VmfCallTimingLine {
    <#
    .SYNOPSIS
        The one place a timing line leaves the service: the information
        stream, which the Functions worker sends to Application Insights as a
        trace with the invocation's operation_Id.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Information -MessageData $Message -InformationAction Continue
}

function Complete-VmfCallTimings {
    <#
    .SYNOPSIS
        Write this invocation's line and end its record. Does nothing when no
        record was started, and never throws.
    #>
    [CmdletBinding()]
    param()
    $counted = $false
    try {
        if ($null -eq $script:VmfCallTimings) { return }
        $counted = [bool]$script:VmfCallTimings.Counted
        $summary = Get-VmfCallTimingSummary
        # STORE-CALL-SLOW-1 round 3: the pool and the spread, in the service's
        # line only (an engine step's line stays as it was).
        $summary.pool = Get-VmfCallTimingSafe { Get-VmfCallTimingPool -Record $script:VmfCallTimings }
        $summary.storeSpread = $script:VmfCallTimings.Spread
        Write-VmfCallTimingLine -Message ('VMF-CALLS ' + ($summary | ConvertTo-Json -Depth 6 -Compress))
    }
    catch {
        $null = $_
    }
    finally {
        if ($counted) { $null = Step-VmfCallTimingsOpen -By -1 }
        $script:VmfCallTimings = $null
        $script:VmfCallTimingArmDepth = 0
    }
}

function Start-VmfStepCallTimings {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-ENGINE-1: begin the record of one step of a machine in
        the engine. It names only run store calls and writes no part line.
        Never throws: telemetry never fails a step.
    #>
    [CmdletBinding()]
    param()
    try { Start-VmfCallTimings -NamedKinds store -NoInterim -Uncounted }
    catch { $null = $_ }
}

function Stop-VmfStepCallTimings {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-ENGINE-1: end the record of a step and give its summary
        as @{ calls = ... }, ready to add to the step's closing activity line.
        An empty table when no record is open or it cannot be read. Never
        throws, and always ends the record.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    try {
        if ($null -eq $script:VmfCallTimings) { return @{} }
        $summary = Get-VmfCallTimingSummary
        # The engine writes no part line, so the field would say nothing.
        $summary.Remove('partial')
        return @{ calls = $summary }
    }
    catch {
        $null = $_
        return @{}
    }
    finally {
        $script:VmfCallTimings = $null
        $script:VmfCallTimingArmDepth = 0
    }
}
