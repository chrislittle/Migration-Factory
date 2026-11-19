# WORKLOAD-1 (AVD half): ask the provider that OWNS the host-pool
# relationship which machines are session hosts, instead of reading a label
# someone stuck on the machine.
#
# The rule: a tag on an AVD host is not enough to protect it, and no tag is
# an AVD signal at all - so this is the ONLY AVD
# signal, and when it cannot run, the scan REFUSES rather than proceeding
# with less.
#
# The authoritative record: session hosts are CHILD RESOURCES of the host
# pool - hostPools/{name}/sessionHosts - each carrying the VM's ARM resource
# id. True for Personal and Pooled (multi-session) pools alike, because
# hostPoolType changes assignment semantics, never how membership is
# recorded.
#
# TWO FAILURE MODES the first version of this file had, found by asking in
# which scenario it would not work:
#
#   1. CROSS-SUBSCRIPTION LAYOUT. The pool OBJECT can live in a management
#      subscription while its session-host VMs live in a workloads
#      subscription. Enumerating pools only where the scanned VMs live finds
#      nothing in that layout - the common enterprise shape, not an edge
#      case. So pools are enumerated in EVERY subscription of the scan scope:
#      the subscriptions chosen, and every subscription under a chosen
#      management group, even one that holds no machine.
#      SCAN-SCOPE-READS-1 (ruling, 2026-11-14): NEVER
#      wider. An earlier version read every subscription the identity could
#      see (GET /subscriptions). An assessment reads nothing outside the
#      scope the person chose, so a pool in a subscription outside the scope
#      is not read, and the scan dialog and the manual tell the person to
#      put the subscription that holds the host pools in the scope.
#   2. PAGINATION. Both list APIs return nextLink pages; ignoring them
#      silently drops session hosts past the first page - exactly at the
#      fleet scale the product exists for. Every listing now follows nextLink.
#
# The limit that remains, stated rather than implied away: a subscription under
# a management group that the identity CANNOT SEE is not in Resource Graph's
# answer, and returns no error - we never knew to ask (the inventory query has
# the same limit). The Detail therefore records how many subscriptions were
# actually checked, so the coverage is visible in the run record.
#
# REST rather than a module dependency: Az.DesktopVirtualization is not
# installed anywhere the product runs, and a handful of GETs needs no SDK.

# PERF-TELEMETRY-HUNG-1: AN ARM REQUEST HAS A TIME LIMIT.
#
# MEASURED 2026-11-08, Az.Accounts 5.5.2, against a local stand-in for ARM
# that accepts a request and never answers: Invoke-AzRestMethod sent one
# request, did not try again, and had not ended after 10 minutes. The
# Functions time limit on Consumption is five minutes, and a call the host
# stops there never reaches its finally - so it wrote no VMF-CALLS line, and
# nothing said which request held the page.
#
# The request is sent with -AsJob, Az's own way to run it in the background,
# and waited for at most this long. Measured the same day: a good request
# costs what a direct call costs (10 to 20 ms), a request that throws gives
# the job the same exception and message, and Stop-Job ends a request that
# got no answer at once. 100 s is the time limit HttpClient and Azure.Core
# give one try by default, and the one each store request already has.
# A request that reaches it is a FAILED call with no status (never success,
# never "not found"), and its error says "timed out", so the retry rule of an
# Azure operation reads it as temporary.
$script:VmfArmAnswerLimitMs = 100000

function Test-VmfCommandCanRunAsJob {
    <#
    .SYNOPSIS
        Does a command with these parameter names take -AsJob? The real
        Invoke-AzRestMethod does. A stand-in that does not (a unit test's) is
        called as it is, with no limit.
    .PARAMETER ParameterName
        The names, read in the CALLER's module: a test's mock of the command
        is an alias that only that module can resolve.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$ParameterName)
    'AsJob' -in @($ParameterName)
}

function Receive-VmfArmAnswer {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-HUNG-1: the answer of one ARM request sent with -AsJob,
        waited for at most $script:VmfArmAnswerLimitMs. The answer as Azure
        gave it; the error of the request as it was; or, at the limit, the job
        is stopped and a "timed out" error is thrown. The job is always
        removed.
    .PARAMETER Answer
        What Invoke-AzRestMethod -AsJob gave back. Anything that is not a job
        (a stand-in that answers at once) is the answer itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Answer,
        [Parameter(Mandatory)][string]$Method,
        [Parameter()][AllowEmptyString()][string]$Target
    )
    if ($Answer -isnot [System.Management.Automation.Job]) { return $Answer }
    try {
        if (-not $Answer.Finished.WaitOne([int]$script:VmfArmAnswerLimitMs)) {
            Stop-Job -Job $Answer
            # The target as the timing line names it: no subscription, group
            # or resource name.
            throw ('Azure Resource Manager did not answer {0} {1} in {2} seconds: the request timed out.' -f
                $Method.ToUpperInvariant(), (ConvertTo-VmfCallTarget -Kind arm -Target $Target), [int]($script:VmfArmAnswerLimitMs / 1000))
        }
        Receive-Job -Job $Answer -ErrorAction Stop
    }
    finally {
        Remove-Job -Job $Answer -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VmfArmRequest {
    <#
    .SYNOPSIS
        PERF-TELEMETRY-1: one ARM request, counted in the invocation's call
        record (CallTimings.ps1). Takes a -Path or a whole -Uri (a nextLink),
        and passes on only what it was given. PERF-TELEMETRY-HUNG-1: it ends
        at $script:VmfArmAnswerLimitMs if Azure does not answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter()][string]$Path,
        [Parameter()][string]$Uri,
        [Parameter()][string]$Payload
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 0
    $target = if ($PSBoundParameters.ContainsKey('Uri')) { $Uri } else { $Path }
    try {
        $send = @{}
        foreach ($key in $PSBoundParameters.Keys) { $send[$key] = $PSBoundParameters[$key] }
        # FACADE-SIGNIN-COLD-1: the web service has no Az module; its ARM
        # requests carry a token from the managed identity endpoint.
        if (Test-VmfTokenFromIdentityEndpoint) { $resp = Invoke-VmfArmHttpRequest @send }
        else {
            if (Test-VmfCommandCanRunAsJob -ParameterName @((Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue).Parameters.Keys)) { $send.AsJob = $true }
            $resp = Receive-VmfArmAnswer -Answer (Invoke-AzRestMethod @send) -Method $Method -Target $target
        }
        $status = [int]$resp.StatusCode
        $resp
    }
    finally {
        Add-VmfCallTiming -Kind arm -Method $Method -Target $target -Status $status -DurationMs $clock.Elapsed.TotalMilliseconds
    }
}

function Get-VmfArmList {
    <#
    .SYNOPSIS
        GET an ARM collection, following nextLink to the end.
    .OUTPUTS
        @{ Ok = bool; Items = object[]; StatusCode = int; Content = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $items = [System.Collections.Generic.List[object]]::new()
    # PERF-TELEMETRY-1: each page is one ARM call in the invocation's record.
    $resp = Invoke-VmfArmRequest -Method GET -Path $Path
    # Backstop against a nextLink chain that never ends (a pathological or
    # looping response) - the same runaway guard the state machine carries.
    # Found the hard way: a TEST mock with exactly that behaviour hung the
    # whole suite, which is what production would have done against ARM.
    $pageLimit = 100
    while ($true) {
        if (--$pageLimit -lt 0) { throw "ARM listing '$Path' exceeded 100 pages - refusing to follow what looks like a looping nextLink chain" }
        if ($resp.StatusCode -ge 400) {
            return @{ Ok = $false; Items = @($items); StatusCode = $resp.StatusCode; Content = [string]$resp.Content }
        }
        $page = $resp.Content | ConvertFrom-Json
        foreach ($v in @($page.value)) { $items.Add($v) }
        if (-not $page.nextLink) { break }
        $resp = Invoke-VmfArmRequest -Method GET -Uri ([string]$page.nextLink)
    }
    @{ Ok = $true; Items = @($items); StatusCode = 200; Content = $null }
}

$script:VmfScopeSubscriptionsQuery = @'
ResourceContainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId
'@

function Get-VmfManagementGroupSubscriptionIds {
    <#
    .SYNOPSIS
        SCAN-SCOPE-READS-1: every subscription under a management group that
        the identity can read - the subscriptions the inventory query reads
        for the same management group (Resource Graph expands it the same
        way, SCOPE-1). Throws when Resource Graph does not answer.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$ManagementGroup)

    $ids = [System.Collections.Generic.List[string]]::new()
    $skipToken = $null
    do {
        $body = @{ query = $script:VmfScopeSubscriptionsQuery; options = @{ '$top' = 500 }; managementGroups = @($ManagementGroup) }
        if ($skipToken) { $body.options['$skipToken'] = $skipToken }
        $parsed = Invoke-VmfResourceGraphQuery -Body $body
        foreach ($row in @($parsed.data)) { if ($row.subscriptionId) { $ids.Add([string]$row.subscriptionId) } }
        $skipToken = $parsed.'$skipToken'
    } while ($skipToken)
    , $ids.ToArray()
}

function Get-VmfAvdSessionHostIds {
    <#
    .SYNOPSIS
        Every VM resource id registered as an AVD session host, in the host
        pools of the scan scope's subscriptions.
    .OUTPUTS
        @{ Ids = hashtable (lowercased vmId -> host pool name);
           PoolTypes = hashtable (lowercased vmId -> hostPoolType, when the pool gives one);
           Verified = bool; Detail = string }
    .PARAMETER Subscriptions
        The scope's chosen subscriptions, and the subscriptions of the machines
        found (which are inside the scope by construction).
    .PARAMETER ManagementGroup
        The scope's management group, when it has one: every subscription
        under it is read too (Get-VmfManagementGroupSubscriptionIds).
    .NOTES
        SCAN-SCOPE-READS-1: no subscription outside the scope is read.
        Outcomes, kept honest and distinct:
        - pools enumerated                     -> Verified, Ids filled
        - provider NOT REGISTERED in a sub     -> that sub is a verified "no
          AVD here", not a failure
        - anything REFUSED (permissions, outage, the subscriptions under the
          management group) -> Verified = $false. Cannot read it = cannot
          claim "no AVD members" (the drill rule). The caller REFUSES the scan.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Subscriptions,
        [Parameter()][string]$ManagementGroup
    )

    $ids = @{}
    $poolTypes = @{}
    $api = '2024-04-03'

    $underGroup = @()
    if ($ManagementGroup) {
        try { $underGroup = @(Get-VmfManagementGroupSubscriptionIds -ManagementGroup $ManagementGroup) }
        catch {
            return @{ Ids = $ids; PoolTypes = $poolTypes; Verified = $false
                      Detail = "the scan cannot list the subscriptions under management group ${ManagementGroup}: $($_.Exception.Message)" }
        }
    }
    $subs = @(@($Subscriptions) + @($underGroup) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    # SCOPE-SUBS-GUID-1: each value goes into a request path below, so each
    # must be a subscription id - from the engine's setting or from the list
    # Resource Graph gives for a management group. Every value is checked
    # before the first read. \z, not $: $ also matches before a final new line.
    foreach ($sub in $subs) {
        if ($sub -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') {
            return @{ Ids = $ids; PoolTypes = $poolTypes; Verified = $false; NotSubscriptionId = $sub
                      Detail = "the scan scope has the value '$sub', which is not a subscription ID" }
        }
    }

    foreach ($sub in $subs) {
        $pools = Get-VmfArmList -Path "/subscriptions/$sub/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$api"
        if (-not $pools.Ok) {
            if ($pools.StatusCode -eq 404 -or
                ($pools.Content -and $pools.Content -match 'NoRegisteredProviderFound|InvalidResourceNamespace')) {
                continue   # no AVD in this subscription - a real, verified answer
            }
            return @{ Ids = $ids; PoolTypes = $poolTypes; Verified = $false
                      Detail = "could not list AVD host pools in $sub (HTTP $($pools.StatusCode)) - session-host membership CANNOT be verified" }
        }
        foreach ($pool in @($pools.Items)) {
            $hosts = Get-VmfArmList -Path "$($pool.id)/sessionHosts?api-version=$api"
            if (-not $hosts.Ok) {
                return @{ Ids = $ids; PoolTypes = $poolTypes; Verified = $false
                          Detail = "could not list session hosts of host pool '$($pool.name)' (HTTP $($hosts.StatusCode)) - membership CANNOT be verified" }
            }
            foreach ($sh in @($hosts.Items)) {
                $vmId = [string]$sh.properties.resourceId
                if ($vmId) {
                    $ids[$vmId.ToLowerInvariant()] = [string]$pool.name
                    # DETECT-PATTERNS-1: the pool's own hostPoolType (Pooled or
                    # Personal), from the host pool already read - no new call.
                    # A pooled host is the workload type Pooled AVD host; a
                    # personal one moves as a standalone machine.
                    $poolType = if ($pool.PSObject.Properties['properties'] -and $pool.properties -and
                        $pool.properties.PSObject.Properties['hostPoolType']) { [string]$pool.properties.hostPoolType } else { '' }
                    if ($poolType) { $poolTypes[$vmId.ToLowerInvariant()] = $poolType }
                }
            }
        }
    }
    @{ Ids = $ids; PoolTypes = $poolTypes; Verified = $true
       Detail = "The scan read $($subs.Count) $(if ($subs.Count -eq 1) { 'subscription' } else { 'subscriptions' }) in the scan scope. It found $($ids.Count) $(if ($ids.Count -eq 1) { 'session host' } else { 'session hosts' })." }
}
