# azureops boundary for the Azure Storage DATA PLANE (STORE-1 azblob backend).
# One HTTP seam: every blob operation goes through Invoke-VmfStorageRequest so
# unit tests can fake the whole service (ETag / If-None-Match / append
# semantics) without Azure. Auth is a storage-scoped bearer token - no keys, no
# SAS, no secrets at rest: from the managed identity endpoint in the web
# service, and from the ambient Az context everywhere else (Get-VmfAccessToken,
# AzureOpsToken.ps1).

function Get-VmfSignedInIdentity {
    <#
    .SYNOPSIS
        The operator's signed-in Entra identity from the ambient Az context -
        used to stamp approvals with WHO, from their login, never typed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # FACADE-SIGNIN-COLD-1: the web service has no Az sign-in, and every call
    # it makes names the signed-in user (OnBehalfOf, RemovedBy, ...).
    if (Test-VmfTokenFromIdentityEndpoint) { throw 'The web service has no Az sign-in. Give the identity of the signed-in user.' }
    else {
        $ctx = Get-AzContext
        if (-not $ctx -or -not $ctx.Account) { throw 'No Az context - Connect-AzAccount first.' }
        @{ Identity = [string]$ctx.Account.Id; TenantId = [string]$ctx.Tenant.Id }
    }
}

function Invoke-VmfStorageRequest {
    <#
    .SYNOPSIS
        Signed Azure Storage data-plane request. Returns StatusCode + Content +
        Headers; never throws on HTTP status (callers branch on the code).
    .DESCRIPTION
        PERF-TELEMETRY-1: every store call of the service passes here, so this
        is where its time is counted (CallTimings.ps1) - the whole call, with
        its token and its retries, as one store call.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][hashtable]$Headers = @{},
        [Parameter()][string]$Body,
        # STORE-REQUEST-TIMEOUT-1: time an earlier attempt of this request
        # already took (a read sent together, Invoke-VmfStorageGetMany). It
        # counts against the limit on the whole request.
        [Parameter()][ValidateRange(0, [double]::MaxValue)][double]$SpentMs = 0
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 0
    try {
        $resp = Invoke-VmfStorageRequestCore @PSBoundParameters
        $status = [int]$resp.StatusCode
        $resp
    }
    finally {
        Add-VmfCallTiming -Kind store -Method $Method -Target $Uri -Status $status -DurationMs $clock.Elapsed.TotalMilliseconds
    }
}

function Invoke-VmfStorageRequestCore {
    # The request itself; Invoke-VmfStorageRequest times it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][hashtable]$Headers = @{},
        [Parameter()][string]$Body,
        [Parameter()][double]$SpentMs = 0
    )

    $tokenClock = [System.Diagnostics.Stopwatch]::StartNew()
    # FACADE-SIGNIN-COLD-1: the managed identity endpoint in the web service,
    # Get-AzAccessToken everywhere else (AzureOpsToken.ps1).
    $token = Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/'
    Add-VmfCallTiming -Kind token -Operation 'storage' -DurationMs $tokenClock.Elapsed.TotalMilliseconds

    $h = @{
        Authorization  = "Bearer $token"
        'x-ms-version' = '2023-11-03'
    }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $h
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $params.Body = [System.Text.UTF8Encoding]::new($false).GetBytes($Body) }

    # STORE-2: retry the way every ARM call already does.
    #
    # This was a single unguarded request. Every Azure call in the engine goes
    # through Invoke-VmfAzOperation - bounded retries, backoff, jitter - but the
    # STATE STORE, which is written at every checkpoint of every machine, had
    # none. A connection-level blip therefore aborted a run mid-flight, which is
    # exactly what happened to the UX-STUCK-1 drill: a timeout writing an event
    # after SAFETY_COPY killed a wave whose machine had migrated perfectly well.
    #
    # Retries only what is worth retrying: connection failures and the server
    # saying "later" (429/500/502/503/504). A 403 or a 404 is an answer, and
    # retrying an answer just burns the wave's window.
    $maxAttempts = 5
    $resp = $null
    # STORE-REQUEST-TIMEOUT-1: each attempt waits a limited time for the
    # store's FIRST answer (its headers), and in the service the whole request
    # has a limit too (Get-VmfStoreRequestLimit), so a store that never answers
    # ends the request inside the service's five-minute limit. Only the waits
    # for headers and the back-off count against that limit ($countedMs), with
    # what an earlier attempt already spent (-SpentMs): a store that has
    # started to answer finishes its body under the body limit, and a body
    # that fails is sent again as before. The token is not counted (a token
    # with no answer is TOKEN-REQUEST-HUNG-1).
    $limit = Get-VmfStoreRequestLimit
    $countedMs = [double]$SpentMs
    $params.BodyTimeoutMs = $limit.BodyMs
    $lastError = $null
    $budgetSpent = $false
    # PERF-TELEMETRY-HUNG-1: an attempt that waited for no answer names the
    # call in a part line, once, so a call that waits is still named.
    $heldNamed = $false
    $attemptClock = [System.Diagnostics.Stopwatch]::new()
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $timeoutMs = Get-VmfStoreAttemptTimeoutMs -ElapsedMs $countedMs -AttemptMs $limit.AttemptMs -BudgetMs $limit.BudgetMs
        if ($timeoutMs -le 0) { $budgetSpent = $true; break }
        $params.TimeoutMs = $timeoutMs
        # Send-VmfStorageHttpRequest writes Ms here when the headers came.
        $headerWait = @{}
        $params.HeaderWait = $headerWait
        $transient = $false
        $resp = $null
        $attemptClock.Restart()
        try {
            $resp = Send-VmfStorageHttpRequest @params
            if ([int]$resp.StatusCode -in @(429, 500, 502, 503, 504)) { $transient = $true }
        }
        catch {
            # No response at all - timeout, reset, DNS. Always worth another go.
            $transient = $true
            $lastError = $_
            if ($attempt -eq $maxAttempts) { throw }
            if (-not $heldNamed) {
                $heldNamed = Write-VmfCallTimingHeld -Kind store -Method $Method -Target $Uri -ElapsedMs $attemptClock.Elapsed.TotalMilliseconds -Attempt $attempt
            }
        }
        $countedMs += if ($headerWait.ContainsKey('Ms')) { [double]$headerWait.Ms } else { $attemptClock.Elapsed.TotalMilliseconds }
        if (-not $transient) { break }
        if ($attempt -eq $maxAttempts) {
            if ($resp) { break }   # let the caller see the final status code
            throw "State store request to '$Uri' did not succeed after $maxAttempts attempts."
        }
        # Exponential backoff with jitter, same shape as the ARM retry.
        $delayMs = [int]([Math]::Min(8000, 250 * [Math]::Pow(2, $attempt - 1)) + (Get-Random -Minimum 0 -Maximum 250))
        # No wait for an attempt the limit on the whole request leaves no time for.
        if ((Get-VmfStoreAttemptTimeoutMs -ElapsedMs ($countedMs + $delayMs) -AttemptMs $limit.AttemptMs -BudgetMs $limit.BudgetMs) -le 0) {
            $budgetSpent = $true; break
        }
        Start-Sleep -Milliseconds $delayMs
        $countedMs += $delayMs
    }
    if ($budgetSpent -and -not $resp) {
        # The last attempt got no answer, and no time is left for another.
        $seconds = [Math]::Round($limit.BudgetMs / 1000, 1)
        # A stop before an attempt has not made it; a stop before a wait has.
        $tries = if ($timeoutMs -le 0) { $attempt - 1 } else { $attempt }
        $why = if ($null -ne $lastError) { " Last error: $($lastError.Exception.Message)" } else { '' }
        $noun = if ($tries -eq 1) { 'attempt' } else { 'attempts' }
        throw "State store request to '$Uri' got no answer in $seconds seconds, after $tries $noun.$why"
    }
    # The store is UTF-8, and blobs are served application/octet-stream
    # (found by the STORE-1 live smoke): decode explicitly, never [string].
    $content = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) }
               else { [string]$resp.Content }
    [pscustomobject]@{
        StatusCode = [int]$resp.StatusCode
        Content    = $content
        Headers    = $resp.Headers
    }
}

# PAGE-LOAD-FREEZE-1: ONE HTTP CLIENT FOR EVERY STORE REQUEST OF THE PROCESS.
#
# Every store request used to go through Invoke-WebRequest, which makes a new
# HttpClient for each call when no -WebSession is given, so each request opened
# a new TCP connection (MEASURED, PowerShell 7.6.9: 20 calls, 20 connections; a
# shared HttpClient, 1). The schedule timer makes about 700 store calls a pass,
# every five minutes, all to one storage address and port. On the lab install
# (Application Insights, 2026-11-06 and 2026-11-07) store calls on one instance
# then stalled for 65 s or about 110 s and ended together - in a page load, and
# with no page open when the two timers ran at once.
#
# Microsoft, "Troubleshoot intermittent outbound connection errors in Azure App
# Service", Cause: each instance has 128 SNAT ports for one address and port,
# a closed connection's port comes back only after four minutes, and an app
# that opens new connections fast is "blocked until a new SNAT port becomes
# available". "Manage connections in Azure Functions": "Don't create a new
# client with every function invocation."
#
# WHY NOT Invoke-WebRequest -WebSession: a session keeps every header it is
# given (MEASURED: an If-None-Match sent once is sent again on the next call),
# so one write's condition would ride on the next request.
#
# ONE FOR THE PROCESS, NOT FOR THE RUNSPACE. The Functions worker runs calls in
# many runspaces of one process, and each imports the module again, so a
# $script: variable is one client per runspace. HttpClient is safe to share
# between threads. The client is kept in the process's AppDomain data.
#
# PooledConnectionLifetime: the .NET guide "HttpClient guidelines" - a
# long-lived client resolves DNS only when it opens a connection, so a limit on
# a connection's life lets it see a changed storage address. The client's own
# Timeout stays HttpClient's default (100 s); each request carries its own,
# shorter limit (STORE-REQUEST-TIMEOUT-1, below).
# v2 (STORE-REQUEST-TIMEOUT-1): the handler drains nothing (below).
$script:VmfStorageHttpSlot = 'VmMigrationFactory.StorageHttp.v2'
$script:VmfStorageConnectionLifetime = [timespan]::FromMinutes(5)

# STORE-REQUEST-TIMEOUT-1: HOW LONG A STORE REQUEST WAITS FOR AN ANSWER.
#
# Each attempt waited HttpClient's default, 100 s, and a request made up to 5
# attempts: about 8 minutes for a store that never answers. The service's time
# limit is 5 minutes (Consumption; host.json sets no functionTimeout), so the
# host stopped the call first. MEASURED on the lab install, 2026-11-07: a
# schedule pass ended with FunctionTimeoutException at 300 s after one store
# request waited about 3.5 minutes (FACADE-QUEUE-1).
#
# IN THE SERVICE: 20 s with no answer for one attempt, 40 s with no answer
# for the whole request. "No answer" is the wait for the store's headers: the
# slowest store answer measured since every request shares one pooled client
# is 2.7 s (PAGE-LOAD-FREEZE-1: 4,889 calls) and a timer pass's slowest 1.02 s
# (STORE-CALL-SLOW-1: 469 calls), so 20 s is about seven times the slowest
# answer that came. The schedule and retention passes stop starting runs at
# 210 s (Test-VmfPassTimeLeft), which leaves 90 s for the last run and the
# pass record: two requests with no answer take 80 s. In 40 s a request with
# no answer gets two attempts; one that fails at once (a refused connection, a
# 503) still gets all five.
#
# THE BODY IS NOT HELD TO THOSE LIMITS (2026-11-09): a store that has
# started to answer finishes a large body as it did before this item, under
# HttpClient's 100 s, and a body that fails is sent again with the attempts
# and back-off as before. Nobody has measured the largest store document of a
# fleet, so the short limit must never fail one that is coming.
#
# OUTSIDE THE SERVICE (the engine job, a script): no five-minute limit, and an
# engine checkpoint that fails can stop a machine's move, so its attempts stay
# as they were: 100 s each, five of them, no limit on the whole request.
#
# The service is known by FUNCTIONS_WORKER_RUNTIME, the setting Azure Functions
# requires of every function app (infra/platform.bicep sets it); the engine's
# container does not have it.
$script:VmfStoreServiceAttemptMs = 20000
$script:VmfStoreServiceRequestMs = 40000
$script:VmfStoreEngineAttemptMs = 100000
$script:VmfStoreBodyMs = 100000
# Less time than this left on the whole request starts no further attempt.
$script:VmfStoreAttemptFloorMs = 1000

function Test-VmfStoreHostTimeLimited {
    # $true in the Azure Functions service, whose calls stop at its time limit.
    [OutputType([bool])]
    param()
    -not [string]::IsNullOrEmpty($env:FUNCTIONS_WORKER_RUNTIME)
}

function Get-VmfStoreRequestLimit {
    <#
    .SYNOPSIS
        STORE-REQUEST-TIMEOUT-1: how long one attempt of a store request waits
        for the store's headers (AttemptMs), how long the waits for headers
        and the back-off may take in all (BudgetMs; 0 = no limit), and how
        long the body may take once the headers came (BodyMs).
    #>
    [OutputType([hashtable])]
    param([Parameter()][bool]$HostTimeLimited = (Test-VmfStoreHostTimeLimited))
    if ($HostTimeLimited) {
        return @{ AttemptMs = [int]$script:VmfStoreServiceAttemptMs; BudgetMs = [int]$script:VmfStoreServiceRequestMs; BodyMs = [int]$script:VmfStoreBodyMs }
    }
    @{ AttemptMs = [int]$script:VmfStoreEngineAttemptMs; BudgetMs = 0; BodyMs = [int]$script:VmfStoreBodyMs }
}

function Get-VmfStoreAttemptTimeoutMs {
    <#
    .SYNOPSIS
        STORE-REQUEST-TIMEOUT-1: how long the next attempt of a store request
        may wait, after -ElapsedMs of the request. The attempt limit, or what
        is left of the whole request when that is less. 0 when less than
        $script:VmfStoreAttemptFloorMs is left: no further attempt starts.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][double]$ElapsedMs,
        [Parameter(Mandatory)][int]$AttemptMs,
        [Parameter(Mandatory)][int]$BudgetMs
    )
    if ($BudgetMs -le 0) { return $AttemptMs }
    $left = $BudgetMs - $ElapsedMs
    if ($left -lt $script:VmfStoreAttemptFloorMs) { return 0 }
    [int][Math]::Min([double]$AttemptMs, [Math]::Floor($left))
}

# STORE-CALL-SLOW-1: THE THREAD POOL'S MINIMUM, RAISED ONCE FOR THE PROCESS.
#
# The run store is reached over TLS. A request on a pooled TLS connection
# waits for a read that a thread-pool thread finishes - with HttpClient.Send
# as with SendAsync. The Functions worker runs each call in a runspace that
# holds a thread-pool thread, and the pool's minimum is the processor count:
# above it the pool adds a thread only after a wait. MEASURED on the lab
# install after the first fix (2026-11-08): a timer pass's store calls still
# took about 415 ms each, the longest about 1 s. MEASURED on this computer
# (one processor, one TLS connection, other calls starting): mean 391 ms with
# the default minimum, about 1 ms with a minimum of 16 or 64. Below its
# minimum the pool adds a thread at once (.NET, "The managed thread pool").
# The minimum is only raised, never lowered, and the I/O minimum is kept.
$script:VmfStorageThreadFloor = 64

function Set-VmfStorageThreadFloor {
    [OutputType([bool])]
    param()
    $worker = 0; $io = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
    if ($worker -ge $script:VmfStorageThreadFloor) { return $true }
    [System.Threading.ThreadPool]::SetMinThreads($script:VmfStorageThreadFloor, $io)
}

# FACADE-PASS-SHARE-1: AZURE POWERSHELL'S DATA COLLECTION, OFF FOR THE PROCESS.
#
# Every store request asks Az.Accounts for its token (Get-AzAccessToken), and
# every Az cmdlet call sends Azure PowerShell's own usage data to Microsoft
# (EnableDataCollection, on by default) from a thread-pool thread that waits
# for the send. MEASURED on this computer (Az.Accounts 5.5.2, two processors,
# every request outside the computer sent to a proxy that never answers):
# each Get-AzAccessToken left one more thread-pool thread waiting - 77 after
# 200 calls - and a token took about 9 ms; with the data collection off, no
# thread waited and a token took about 1 ms. A store request over TLS needs a
# free pool thread for one read, and above the pool's minimum the pool adds
# one only after a wait: the store calls then waited in steps of about 500 ms.
# On the lab install (2026-11-10) a schedule pass made about 530 store calls,
# about 2.5 a second, while about 270 pool threads were busy and the processor
# was idle - the shape of a send that waits about 100 s, HttpClient's limit.
#
# Turned off at Process scope, once a process, when the process makes the
# store client: the setting is the process's, so every runspace of the service
# sees it (MEASURED: a second runspace reads False). Nothing is written to disk.
# Only when Az.Accounts is already loaded: this never loads it. The setting is
# read back, because an exit code is not proof of a setting.
function Set-VmfAzDataCollectionOff {
    <#
    .SYNOPSIS
        FACADE-PASS-SHARE-1: Azure PowerShell's data collection off for this
        process. 'off' when the setting reads False after the change, 'on'
        when it does not, 'notLoaded' when Az.Accounts is not loaded (nothing
        is changed). Throws when the change throws.
    #>
    [OutputType([string])]
    param()
    # FACADE-SIGNIN-COLD-1: the web service loads no Az module.
    if (Test-VmfTokenFromIdentityEndpoint) { 'notLoaded' }
    else {
        if (-not (Get-Module -Name Az.Accounts)) { return 'notLoaded' }
        $null = Update-AzConfig -EnableDataCollection $false -Scope Process -WarningAction SilentlyContinue
        $now = Get-AzConfig -EnableDataCollection -WarningAction SilentlyContinue
        if ($null -ne $now -and -not [bool]@($now)[0].Value) { return 'off' }
        'on'
    }
}

function Get-VmfThreadPoolNow {
    # The pool's minimum, maximum, free and current worker threads.
    $minW = 0; $minIo = 0; $maxW = 0; $maxIo = 0; $freeW = 0; $freeIo = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$minW, [ref]$minIo)
    [System.Threading.ThreadPool]::GetMaxThreads([ref]$maxW, [ref]$maxIo)
    [System.Threading.ThreadPool]::GetAvailableThreads([ref]$freeW, [ref]$freeIo)
    [ordered]@{ min = $minW; max = $maxW; free = $freeW; threads = [System.Threading.ThreadPool]::ThreadCount; minIo = $minIo }
}

function Get-VmfStorageHttpHolder {
    $domain = [System.AppDomain]::CurrentDomain
    $held = $domain.GetData($script:VmfStorageHttpSlot)
    if ($held) { return $held }
    $poolLine = $null
    [System.Threading.Monitor]::Enter($domain)
    try {
        $held = $domain.GetData($script:VmfStorageHttpSlot)
        if (-not $held) {
            # The pool's state and its raised minimum never stop the client
            # from being made: a failure here leaves the line out, or says
            # the minimum was not raised (the review of round 3).
            $before = $null
            try { $before = Get-VmfThreadPoolNow } catch { $null = $_ }
            $floorSet = $false
            try { $floorSet = [bool](Set-VmfStorageThreadFloor) } catch { $null = $_ }
            # FACADE-PASS-SHARE-1: no Az usage data sent from a pool thread
            # that waits. A failure never stops the client; the line says it.
            $azData = 'failed'
            try { $azData = [string](Set-VmfAzDataCollectionOff) } catch { $null = $_ }
            $handler = [System.Net.Http.SocketsHttpHandler]::new()
            $handler.PooledConnectionLifetime = $script:VmfStorageConnectionLifetime
            # Invoke-WebRequest asked for gzip, deflate and brotli; so does this.
            $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::All
            # STORE-REQUEST-TIMEOUT-1: a body read that reaches its limit ends by
            # disposing its stream. By default the handler first drains what is
            # left, for up to 2 s (ResponseDrainTimeout), to keep the connection
            # - MEASURED on this computer: the limit then ended the read about
            # 2 s late, and a drain that met the end gave a short body with no
            # error. Every other answer is read to its end, so nothing is lost.
            $handler.MaxResponseDrainSize = 0
            $handler.ResponseDrainTimeout = [timespan]::Zero
            $held = [hashtable]::Synchronized(@{
                    Client  = [System.Net.Http.HttpClient]::new($handler)
                    Handler = $handler
                    # STORE-CALL-SLOW-1 round 3: named in each service call's line.
                    Floor   = $floorSet
                    # FACADE-PASS-SHARE-1: off, on, notLoaded or failed.
                    AzData  = $azData
                })
            $domain.SetData($script:VmfStorageHttpSlot, $held)
            # STORE-CALL-SLOW-1 round 3: ONE line a process, when it makes the
            # store client, with the pool before and after the raised minimum,
            # so an install shows whether the minimum was reached.
            try {
                $poolLine = 'VMF-POOL ' + ([ordered]@{
                        v       = 1
                        process = [System.Environment]::ProcessId
                        cpus    = [System.Environment]::ProcessorCount
                        floor   = $script:VmfStorageThreadFloor
                        set     = $floorSet
                        azData  = $azData
                        before  = $before
                        after   = (Get-VmfThreadPoolNow)
                    } | ConvertTo-Json -Compress -Depth 4)
            }
            catch { $poolLine = $null }
        }
    }
    finally { [System.Threading.Monitor]::Exit($domain) }
    if ($poolLine) {
        try { Write-Information -MessageData $poolLine -InformationAction Continue } catch { $null = $_ }
    }
    $held
}

function Get-VmfStorageHttpClient {
    # The one HttpClient every store request of this process uses.
    [OutputType([System.Net.Http.HttpClient])]
    param()
    (Get-VmfStorageHttpHolder).Client
}

function Get-VmfStorageHttpHandler {
    # Its handler: the connection pool and its settings.
    [OutputType([System.Net.Http.SocketsHttpHandler])]
    param()
    (Get-VmfStorageHttpHolder).Handler
}

function Get-VmfStorageHttpSendFunc {
    # STORE-CALL-SLOW-1: HttpClient.Send of the shared client as a .NET
    # delegate (Func[object, HttpResponseMessage]), built once for the process,
    # so a dedicated thread (a LongRunning task) can send a request with no
    # runspace. A script block cannot run there.
    # STORE-REQUEST-TIMEOUT-1: its state is object[] { request, token }. It
    # sends with that token and gives the answer back when its HEADERS come
    # (ResponseHeadersRead), so the token limits only the wait for the first
    # answer; Get-VmfStorageHttpReadFunc reads the body.
    [OutputType([System.Func[object, System.Net.Http.HttpResponseMessage]])]
    param()
    $held = Get-VmfStorageHttpHolder
    if (-not $held.SendHeaders) {
        $x = [System.Linq.Expressions.Expression]
        $state = $x::Parameter([object], 'state')
        $pair = $x::Convert($state, [object[]])
        $request = $x::Convert($x::ArrayIndex($pair, $x::Constant(0)), [System.Net.Http.HttpRequestMessage])
        $token = $x::Convert($x::ArrayIndex($pair, $x::Constant(1)), [System.Threading.CancellationToken])
        $send = [System.Net.Http.HttpClient].GetMethod('Send', [type[]]@([System.Net.Http.HttpRequestMessage], [System.Net.Http.HttpCompletionOption], [System.Threading.CancellationToken]))
        $call = $x::Call($x::Constant($held.Client), $send, $request, $x::Constant([System.Net.Http.HttpCompletionOption]::ResponseHeadersRead), $token)
        $held.SendHeaders = $x::Lambda[System.Func[object, System.Net.Http.HttpResponseMessage]]($call, $state).Compile()
    }
    $held.SendHeaders
}

function Get-VmfStorageHttpReadFunc {
    # STORE-REQUEST-TIMEOUT-1: the body of an answer whose headers came, read
    # on a dedicated thread as a .NET delegate (Func[object, byte[]]; its state
    # is the answer's body stream, which it disposes), with no runspace and no
    # wait on a Task.
    [OutputType([System.Func[object, byte[]]])]
    param()
    $held = Get-VmfStorageHttpHolder
    if (-not $held.ReadBody) {
        $x = [System.Linq.Expressions.Expression]
        $state = $x::Parameter([object], 'state')
        $stream = $x::Convert($state, [System.IO.Stream])
        $mem = $x::Variable([System.IO.MemoryStream], 'mem')
        $copyTo = [System.IO.Stream].GetMethod('CopyTo', [type[]]@([System.IO.Stream]))
        # Expression.New by reflection: in PowerShell $x::New is the constructor of Expression.
        $newExpr = $x.GetMethod('New', [type[]]@([type]))
        $body = $x::Block(
            [System.Linq.Expressions.ParameterExpression[]]@($mem),
            [System.Linq.Expressions.Expression[]]@(
                $x::Assign($mem, $newExpr.Invoke($null, @([System.IO.MemoryStream]))),
                $x::TryFinally($x::Call($stream, $copyTo, $mem), $x::Call($stream, [System.IDisposable].GetMethod('Dispose'))),
                $x::Call($mem, [System.IO.MemoryStream].GetMethod('ToArray'))
            ))
        $held.ReadBody = $x::Lambda[System.Func[object, byte[]]]($body, $state).Compile()
    }
    $held.ReadBody
}

function Get-VmfStorageDisposeAction {
    # STORE-REQUEST-TIMEOUT-1: Dispose of its state, as a .NET delegate
    # (Action[object]) that a cancellation token can run on a timer thread with
    # no runspace. Disposing a body stream ends a read that waits on it.
    [OutputType([System.Action[object]])]
    param()
    $held = Get-VmfStorageHttpHolder
    if (-not $held.DisposeState) {
        $x = [System.Linq.Expressions.Expression]
        $state = $x::Parameter([object], 'state')
        $call = $x::Call($x::Convert($state, [System.IDisposable]), [System.IDisposable].GetMethod('Dispose'))
        $held.DisposeState = $x::Lambda[System.Action[object]]($call, $state).Compile()
    }
    $held.DisposeState
}

function Read-VmfStorageHttpBytes {
    # The body of an answer, read on this thread without waiting on a Task
    # (STORE-CALL-SLOW-1). STORE-REQUEST-TIMEOUT-1: with -TimeoutMs, a body
    # that has not all come in that time ends: the answer is disposed, and
    # this throws a TimeoutException.
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter()][int]$TimeoutMs = 0
    )
    $limit = $null
    $registration = $null
    $mem = [System.IO.MemoryStream]::new()
    try {
        $stream = Get-VmfStorageBodyStream -Response $Response
        if ($TimeoutMs -gt 0) {
            # At the limit the stream the read waits on is disposed, which ends
            # the read with an IOException at once (MEASURED on this computer,
            # PowerShell 7.6.9, with the handler draining nothing).
            $limit = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
            $registration = $limit.Token.Register((Get-VmfStorageDisposeAction), $stream)
        }
        try { $stream.CopyTo($mem) } finally { $stream.Dispose() }
        $bytes = $mem.ToArray()
        # The limit fired and disposed the stream, and the read still ended
        # cleanly: a stream with no Content-Length (a chunked answer) can give
        # a clean end on dispose, so what was read is not the body.
        if ($limit -and $limit.IsCancellationRequested) { throw [System.TimeoutException]::new((Get-VmfStoreBodyStoppedText -TimeoutMs $TimeoutMs)) }
        # A body shorter than its Content-Length is not an answer. MEASURED on
        # this computer, before the handler stopped draining: a body read
        # ended at its limit while the handler drained the rest gave a short
        # body with no error.
        $short = Get-VmfStorageBodyShortText -Response $Response -Length $bytes.Length
        if ($short) { throw [System.IO.IOException]::new($short) }
        , $bytes
    }
    catch {
        if ($limit -and $limit.IsCancellationRequested) { throw [System.TimeoutException]::new((Get-VmfStoreBodyStoppedText -TimeoutMs $TimeoutMs), $_.Exception) }
        throw
    }
    finally {
        $mem.Dispose()
        if ($null -ne $registration) { $registration.Dispose() }
        if ($limit) { $limit.Dispose() }
    }
}

function Send-VmfStorageHttpRequest {
    <#
    .SYNOPSIS
        PAGE-LOAD-FREEZE-1: one HTTP request over the shared store client.
        Gives back StatusCode, Content (bytes) and Headers (every response and
        content header, any letter case). Throws only when no answer came.
    .DESCRIPTION
        Sends what Invoke-WebRequest sent: the caller's headers on the request,
        the body as given (bytes) with its length and no content type. A PUT
        with no body goes with a length of 0, which HttpClient sends itself
        (Azure Storage refuses a PUT with no length; StoreConnections.Tests.ps1
        holds it).

        STORE-REQUEST-TIMEOUT-1: the request waits at most -TimeoutMs for the
        store's headers, then throws a TimeoutException; with no -TimeoutMs,
        the attempt limit of Get-VmfStoreRequestLimit. Once the headers came,
        it writes the wait in -HeaderWait (Ms), and the body has -BodyTimeoutMs
        (with none, the body limit of Get-VmfStoreRequestLimit). The answer is
        disposed on every path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][hashtable]$Headers = @{},
        [Parameter()][byte[]]$Body,
        [Parameter()][int]$TimeoutMs = 0,
        [Parameter()][int]$BodyTimeoutMs = 0,
        [Parameter()][hashtable]$HeaderWait
    )
    if ($TimeoutMs -le 0) { $TimeoutMs = (Get-VmfStoreRequestLimit).AttemptMs }
    if ($BodyTimeoutMs -le 0) { $BodyTimeoutMs = (Get-VmfStoreRequestLimit).BodyMs }
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), [uri]$Uri)
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            $req.Content = [System.Net.Http.ByteArrayContent]::new([byte[]]@($Body))
        }
        foreach ($k in $Headers.Keys) {
            $value = [string]$Headers[$k]
            if (-not $req.Headers.TryAddWithoutValidation([string]$k, $value)) {
                if (-not $req.Content) { $req.Content = [System.Net.Http.ByteArrayContent]::new([byte[]]::new(0)) }
                $null = $req.Content.Headers.TryAddWithoutValidation([string]$k, $value)
            }
        }
        # STORE-CALL-SLOW-1: Send, not SendAsync(...).GetAwaiter().GetResult().
        # The Functions worker runs each call in a runspace that holds a
        # thread-pool thread; a wait on a Task needs ANOTHER pool thread to
        # finish it, and when none is free the pool adds one only after a wait.
        # MEASURED: about 450 ms a call on the lab install (469 calls, 212 s in
        # one timer pass) and on this computer with other calls starting; Send
        # reads and writes a plain HTTP connection on this thread: about 2.5 ms.
        # Over TLS a reused connection still needs a pool thread for one read,
        # which is why the pool's minimum is raised (Set-VmfStorageThreadFloor).
        # STORE-REQUEST-TIMEOUT-1: ResponseHeadersRead, so the token limits
        # only the wait for the headers; the body is read below, under its own
        # limit. The answer holds its connection until it is disposed.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = (Get-VmfStorageHttpClient).Send($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)
        }
        catch {
            if ($cts.IsCancellationRequested) { throw [System.TimeoutException]::new((Get-VmfStoreNoAnswerText -TimeoutMs $TimeoutMs), $_.Exception) }
            throw
        }
        try {
            if ($null -ne $HeaderWait) { $HeaderWait.Ms = $clock.Elapsed.TotalMilliseconds }
            $out = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($pair in $resp.Headers) { $out[$pair.Key] = [string[]]@($pair.Value) }
            foreach ($pair in $resp.Content.Headers) { $out[$pair.Key] = [string[]]@($pair.Value) }
            $bytes = Read-VmfStorageHttpBytes -Response $resp -TimeoutMs $BodyTimeoutMs
            [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Content = [byte[]]$bytes; Headers = $out }
        }
        finally { $resp.Dispose() }
    }
    finally { $req.Dispose(); $cts.Dispose() }
}

function Get-VmfStorageBodyStream {
    # STORE-REQUEST-TIMEOUT-1: the body stream of an answer whose headers came
    # (a seam: a test gives a stream that ends cleanly when disposed).
    [OutputType([System.IO.Stream])]
    param([Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response)
    $Response.Content.ReadAsStream()
}

function Get-VmfStorageBodyShortText {
    # STORE-REQUEST-TIMEOUT-1: why a body read is not the whole body - shorter
    # than the Content-Length the store gave - or $null when it is whole. A
    # HEAD answer gives the blob's length with no body.
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][long]$Length
    )
    if ($Response.RequestMessage -and [string]$Response.RequestMessage.Method -eq 'HEAD') { return $null }
    $want = $Response.Content.Headers.ContentLength
    if ($null -eq $want -or [long]$want -eq $Length) { return $null }
    [string]::Format([cultureinfo]::InvariantCulture, 'The run store answer ended after {0} of {1} bytes.', $Length, $want)
}

function Get-VmfStoreBodyStoppedText {
    # The error of a store answer whose body did not all come in its time limit.
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$TimeoutMs)
    [string]::Format([cultureinfo]::InvariantCulture, 'The run store stopped sending its answer: the body did not arrive in {0} seconds.', [Math]::Round($TimeoutMs / 1000, 1))
}

function Get-VmfStoreNoAnswerText {
    # The error of a store attempt that reached its time limit.
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$TimeoutMs)
    [string]::Format([cultureinfo]::InvariantCulture, 'No answer from the run store in {0} seconds: the request timed out.', [Math]::Round($TimeoutMs / 1000, 1))
}

# PERF-RUNS-LIST-1: how many store reads are in flight at once. The same number
# the pages keep (STORE_READ_LIMIT in help.js): enough that a list of a hundred
# runs does not wait for each read in turn, low enough that a fleet-scale store
# cannot open a thousand sockets from one instance of the service.
$script:VmfStorageReadLimit = 8

function Invoke-VmfStorageGetMany {
    <#
    .SYNOPSIS
        PERF-RUNS-LIST-1: many signed GET requests to the store, at most -Limit
        in flight, one token for all of them. Returns one answer per -Uri, in
        the same order: StatusCode and Content, as Invoke-VmfStorageRequest
        gives them. Never throws on an HTTP status.
    .DESCRIPTION
        MEASURED on the lab install, 2026-11-02 (PERF-ANALYSIS-1): the list of
        runs sent its reads one after another, each after asking for a token,
        and took 25 to 115 seconds. The reads do not depend on each other.

        THE SECOND SEAM. Every other store request goes through
        Invoke-VmfStorageRequest, which sends one request and waits for it. This
        sends several at once, each on a dedicated thread (HttpClient.Send, no
        runspace per read - STORE-CALL-SLOW-1), so a unit test fakes it with a
        real HTTP service on the computer (tests/unit/_FakeBlobService.ps1),
        not with a mock.

        A request the service answers "later" (429, 500, 502, 503, 504), or one
        that gets no answer at all, is sent again through Invoke-VmfStorageRequest,
        one at a time: the same retries and the same back-off as every other
        store request, written once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Uri,
        [Parameter()][ValidateRange(1, 64)][int]$Limit = $script:VmfStorageReadLimit
    )
    $count = @($Uri).Count
    $out = [object[]]::new($count)
    if ($count -eq 0) { return , $out }

    $tokenClock = [System.Diagnostics.Stopwatch]::StartNew()
    # FACADE-SIGNIN-COLD-1: the managed identity endpoint in the web service,
    # Get-AzAccessToken everywhere else (AzureOpsToken.ps1).
    $token = Get-VmfAccessToken -ResourceUrl 'https://storage.azure.com/'
    Add-VmfCallTiming -Kind token -Operation 'storage' -DurationMs $tokenClock.Elapsed.TotalMilliseconds
    # PERF-TELEMETRY-1: each read is a store call with its own time, from its
    # send to the moment this loop sees it end (so at most a little long). The
    # reads run side by side, so the store's total gets the wall time of the
    # batch once, not the sum (Add-VmfCallTiming -Overlapped / -TimeOnly). A
    # read sent again goes through Invoke-VmfStorageRequest, which counts it.
    $batchClock = [System.Diagnostics.Stopwatch]::StartNew()
    $sentAt = [System.Collections.Generic.Dictionary[int, long]]::new()
    $readMs = { param([int]$taskId) ([System.Diagnostics.Stopwatch]::GetTimestamp() - $sentAt[$taskId]) * 1000.0 / [System.Diagnostics.Stopwatch]::Frequency }
    # PAGE-LOAD-FREEZE-1: the same client, so the same connections, as every
    # other store request of the process.
    # STORE-CALL-SLOW-1: each read is HttpClient.Send on a dedicated thread (a
    # LongRunning task), not SendAsync. SendAsync needs a free thread-pool
    # thread to finish each read, and the Functions worker's runspaces hold
    # them. MEASURED on this computer, 24 reads 8 at a time with other calls
    # starting: 1359 ms with SendAsync, 40 ms with this (plain HTTP; over TLS
    # the raised pool minimum is what keeps it fast - Set-VmfStorageThreadFloor).
    $sendFunc = Get-VmfStorageHttpSendFunc
    $longRunning = [System.Threading.Tasks.TaskCreationOptions]::LongRunning
    $noCancel = [System.Threading.CancellationToken]::None
    $scheduler = [System.Threading.Tasks.TaskScheduler]::Default
    # STORE-REQUEST-TIMEOUT-1: each read sent together is the first attempt
    # of its request. Its wait for the store's headers has the attempt limit
    # (a token); once the headers came, its body is read on a thread of its
    # own under the body limit (a token that disposes the answer). A read sent
    # again carries only its wait for headers (-SpentMs), so the whole
    # request keeps its limit and a body that fails is sent again as before.
    $readLimit = Get-VmfStoreRequestLimit
    $readFunc = Get-VmfStorageHttpReadFunc
    $disposeAction = Get-VmfStorageDisposeAction

    $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    $indexOf = [System.Collections.Generic.Dictionary[int, int]]::new()
    $limitOf = [System.Collections.Generic.Dictionary[int, System.Threading.CancellationTokenSource]]::new()
    # A body read's answer and its registration, by the body task.
    $answerOf = [System.Collections.Generic.Dictionary[int, System.Net.Http.HttpResponseMessage]]::new()
    $hookOf = [System.Collections.Generic.Dictionary[int, System.Threading.CancellationTokenRegistration]]::new()
    $headMsOf = [System.Collections.Generic.Dictionary[int, double]]::new()
    $again = [System.Collections.Generic.List[int]]::new()
    $spentOf = [System.Collections.Generic.Dictionary[int, double]]::new()
    $next = 0
    try {
        while ($next -lt $count -or $pending.Count -gt 0) {
            while ($pending.Count -lt $Limit -and $next -lt $count) {
                $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [uri]$Uri[$next])
                $null = $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $token")
                $null = $req.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
                $cts = [System.Threading.CancellationTokenSource]::new($readLimit.AttemptMs)
                $task = [System.Threading.Tasks.Task]::Factory.StartNew($sendFunc, [object[]]@($req, $cts.Token), $noCancel, $longRunning, $scheduler)
                $pending.Add($task)
                $indexOf[$task.Id] = $next
                $limitOf[$task.Id] = $cts
                $sentAt[$task.Id] = [System.Diagnostics.Stopwatch]::GetTimestamp()
                $next++
            }
            $at = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray())
            $task = $pending[$at]
            $pending.RemoveAt($at)
            $i = $indexOf[$task.Id]
            $tookMs = & $readMs $task.Id
            # A body read whose limit fired is not the body, even when its read
            # ended cleanly (a chunked answer can end so on dispose).
            $cut = $limitOf[$task.Id].IsCancellationRequested
            $limitOf[$task.Id].Dispose(); $null = $limitOf.Remove($task.Id)
            if ($answerOf.ContainsKey($task.Id)) {
                # The body of a read whose headers came.
                $resp = $answerOf[$task.Id]; $null = $answerOf.Remove($task.Id)
                $hookOf[$task.Id].Dispose(); $null = $hookOf.Remove($task.Id)
                try {
                    $code = [int]$resp.StatusCode
                    if ($task.IsFaulted -or $task.IsCanceled -or $cut) {
                        Add-VmfCallTiming -Kind store -Method GET -Target $Uri[$i] -Status 0 -DurationMs $tookMs -Overlapped
                        $again.Add($i); $spentOf[$i] = $headMsOf[$i]; continue
                    }
                    Add-VmfCallTiming -Kind store -Method GET -Target $Uri[$i] -Status $code -DurationMs $tookMs -Overlapped
                    # The store is UTF-8, and blobs are served application/octet-stream.
                    $out[$i] = [pscustomobject]@{ StatusCode = $code; Content = [System.Text.Encoding]::UTF8.GetString([byte[]]$task.Result) }
                }
                finally { $resp.Dispose() }
                continue
            }
            if ($task.IsFaulted -or $task.IsCanceled) {
                Add-VmfCallTiming -Kind store -Method GET -Target $Uri[$i] -Status 0 -DurationMs $tookMs -Overlapped
                $again.Add($i); $spentOf[$i] = $tookMs; continue
            }
            $resp = $task.Result
            $code = [int]$resp.StatusCode
            if ($code -in @(429, 500, 502, 503, 504)) {
                $resp.Dispose()
                Add-VmfCallTiming -Kind store -Method GET -Target $Uri[$i] -Status $code -DurationMs $tookMs -Overlapped
                $again.Add($i); $spentOf[$i] = $tookMs; continue
            }
            # The headers came: read the body under the body limit.
            $headMsOf[$i] = $tookMs
            $bodyLimit = $null
            try {
                $bodyStream = Get-VmfStorageBodyStream -Response $resp
                $bodyLimit = [System.Threading.CancellationTokenSource]::new($readLimit.BodyMs)
                $hook = $bodyLimit.Token.Register($disposeAction, $bodyStream)
                $bodyTask = [System.Threading.Tasks.Task]::Factory.StartNew($readFunc, $bodyStream, $noCancel, $longRunning, $scheduler)
            }
            catch {
                $resp.Dispose()
                if ($bodyLimit) { $bodyLimit.Dispose() }
                throw
            }
            $pending.Add($bodyTask)
            $indexOf[$bodyTask.Id] = $i
            $limitOf[$bodyTask.Id] = $bodyLimit
            $answerOf[$bodyTask.Id] = $resp
            $hookOf[$bodyTask.Id] = $hook
            $sentAt[$bodyTask.Id] = $sentAt[$task.Id]
        }
    }
    finally {
        # What a read this batch did not wait for left (an error above): its
        # limit, its registration and its answer, which holds a connection.
        foreach ($left in @($limitOf.Values)) { $left.Cancel(); $left.Dispose() }
        foreach ($left in @($hookOf.Values)) { $left.Dispose() }
        foreach ($left in @($answerOf.Values)) { $left.Dispose() }
    }
    Add-VmfCallTiming -Kind store -Operation 'read many' -DurationMs $batchClock.Elapsed.TotalMilliseconds -TimeOnly
    foreach ($i in $again) { $out[$i] = Invoke-VmfStorageRequest -Method GET -Uri $Uri[$i] -SpentMs $spentOf[$i] }
    , $out
}
