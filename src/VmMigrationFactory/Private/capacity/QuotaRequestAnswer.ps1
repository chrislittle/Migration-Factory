# QUOTA-REQUEST-POLL-1: the answer of Azure to each quota increase request.
#
# A request Azure takes with HTTP 202 continues without us. Request-VmfQuota
# recorded its ID (claim.quota.requestId) and nothing read it again, so the
# wave editor said "Filed. Azure has not answered yet." for ever. In the final
# lab, 2026-11-16, nothing showed whether a request was done or not.
#
# MEASURED that night: the Quota Request Status GET answered InProgress
# "Request processing." and, about 80 seconds after the request was filed,
# Failed "Request failed." with error.code QuotaNotAvailableForResource; the
# limit did not change. Earlier requests in the subscription read Succeeded
# "Request completed.". Microsoft's page lists the states Accepted, Invalid,
# Succeeded, Failed and InProgress (QuotaRequestState).

# How long the engine reads a request after it was filed, and how often. The
# need was at least a minute; the task asked for at least 2 minutes.
$script:VmfQuotaAnswerWaitSeconds = 120
$script:VmfQuotaAnswerPollSeconds = 15

function ConvertFrom-VmfQuotaRequestAnswer {
    <#
    .SYNOPSIS
        What one Quota Request Status answer means. Pure; never throws.
    .DESCRIPTION
        Answer is APPROVED (Succeeded), REFUSED (Failed or Invalid, with
        error.code), WAITING (InProgress, Accepted, or a state Microsoft does
        not list - never read as a yes or a no), or NOTREAD (no 200, or a body
        that is not JSON). Final is true only for APPROVED and REFUSED: a read
        that failed can work at the next try.

        The fields are read from properties, the shape Microsoft's page
        gives, and from the top when there is no properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()][object]$StatusCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Content
    )
    $out = [ordered]@{ Answer = 'NOTREAD'; Final = $false; State = $null; Code = $null; Message = $null; Reason = $null }
    if ([string]$StatusCode -ne '200') {
        $out.Reason = Get-VmfQuotaRefusalText -StatusCode $StatusCode -Content $Content
        return [pscustomobject]$out
    }
    try { $j = $Content | ConvertFrom-Json -ErrorAction Stop } catch { $j = $null }
    if ($null -eq $j -or $j -is [string] -or $j -is [array]) {
        $out.Reason = "Azure answered HTTP 200 with a body that is not JSON."
        return [pscustomobject]$out
    }
    $props = if ($j.PSObject.Properties['properties'] -and $j.properties) { $j.properties } else { $j }
    $state = if ($props.PSObject.Properties['provisioningState']) { [string]$props.provisioningState } else { '' }
    $out.State = if ($state) { $state } else { $null }
    if ($props.PSObject.Properties['message'] -and $props.message) { $out.Message = [string]$props.message }
    if ($props.PSObject.Properties['error'] -and $props.error) {
        if ($props.error.PSObject.Properties['code'] -and $props.error.code) { $out.Code = [string]$props.error.code }
        if (-not $out.Message -and $props.error.PSObject.Properties['message']) { $out.Message = [string]$props.error.message }
    }
    switch ($state) {
        'Succeeded' { $out.Answer = 'APPROVED'; $out.Final = $true }
        { $_ -in @('Failed', 'Invalid') } { $out.Answer = 'REFUSED'; $out.Final = $true }
        default { $out.Answer = 'WAITING' }
    }
    [pscustomobject]$out
}

function Get-VmfQuotaRequestIdFromHeader {
    <#
    .SYNOPSIS
        The GUID at the end of the location header of a 202, or null. Pure.
    .DESCRIPTION
        Microsoft's Quota - Create Or Update page: a 202 has the headers
        Retry-After and location (.../operationsStatus/{GUID}), and the GUID is
        the quota request ID that Quota Request Status reads. Only a GUID is
        returned, so nothing else from a header reaches a later URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][object]$Response)
    if ($null -eq $Response -or -not $Response.PSObject.Properties['Headers'] -or $null -eq $Response.Headers) { return $null }
    $headers = $Response.Headers
    $value = $null
    try {
        if ($headers -is [System.Collections.IDictionary]) {
            foreach ($k in @($headers.Keys)) { if ([string]$k -eq 'Location') { $value = $headers[$k] } }
        }
        elseif ($headers.PSObject.Properties['Location']) { $value = $headers.Location }
    }
    catch { $value = $null }
    $text = [string](@($value) | Select-Object -First 1)
    if (-not $text) { return $null }
    $path = ($text -split '\?')[0]
    $last = @($path.Split('/') | Where-Object { $_ })
    if (-not $last.Count) { return $null }
    $guid = [guid]::Empty
    if ([guid]::TryParseExact($last[-1], 'D', [ref]$guid)) { return $last[-1] }
    $null
}

function ConvertTo-VmfUtcTime {
    # A stored time can come back from ConvertFrom-Json as a date or as text
    # (PLANVER-2 explains why); both give the same instant here. Null when none.
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
    $null
}

function Get-VmfQuotaRequestsToRead {
    <#
    .SYNOPSIS
        The quota increase requests filed in the last -WaitSeconds, from the
        stored quota records. One entry per request ID.
    .DESCRIPTION
        From the records, never from the memory of one run, so a re-run of
        the quota operation goes on reading where an earlier one stopped
        (resumable), and the time counts from when the request was filed.
        A request Azure approved at once (HTTP 200) has no ID and is not read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter()][int]$WaitSeconds = $script:VmfQuotaAnswerWaitSeconds,
        [Parameter()][datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )
    $seen = [ordered]@{}
    foreach ($name in @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json')) {
        $claim = Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$name" -Depth 12
        if (-not $claim -or -not $claim.PSObject.Properties['quota'] -or -not $claim.quota) { continue }
        $q = $claim.quota
        $field = { param($n) if ($q.PSObject.Properties[$n]) { $q.$n } else { $null } }
        $regional = [string]$claim.blockReason -eq 'regional-quota-shortfall'
        $familyName = if (& $field 'name') { [string](& $field 'name') } else { [string]$claim.vmFamily }
        $pairs = @(
            @{ Id = & $field 'requestId'; At = & $field 'requestedUtc'; Quota = $(if ($regional) { $script:VmfRegionalQuotaDisplayName } else { $familyName }) }
            @{ Id = & $field 'regionalRequestId'; At = & $field 'regionalRequestedUtc'; Quota = $script:VmfRegionalQuotaDisplayName }
        )
        foreach ($pair in $pairs) {
            $id = [string]$pair.Id
            if (-not $id) { continue }
            $at = ConvertTo-VmfUtcTime -Value $pair.At
            if ($null -eq $at) { continue }
            $deadline = $at.AddSeconds($WaitSeconds)
            if ($deadline -lt $NowUtc) { continue }
            $key = $id.ToLowerInvariant()
            if ($seen.Contains($key)) { continue }
            $seen[$key] = [pscustomobject]@{
                RequestId = $id; QuotaName = [string]$pair.Quota; Region = [string]$claim.region
                SubscriptionId = [string]$claim.subscriptionId; Deadline = $deadline
            }
        }
    }
    @($seen.Values)
}

function Wait-VmfQuotaRequestAnswer {
    <#
    .SYNOPSIS
        Read each quota increase request filed in the last 2 minutes until
        Azure answers it or 2 minutes after it was filed have passed, and
        write ONE quotaAnswer line for each.
    .DESCRIPTION
        Bounded twice: by the time (the deadline of each request, from when it
        was filed) and by the number of reads (enough rounds to cover the time
        left at the start, so a clock that does not move still ends it). A
        read that throws or is refused is tried again at the next round. The
        line carries the request ID and the answer - APPROVED, REFUSED (with
        Azure's code), WAITING (no answer in the time) or NOTREAD (the product
        could not read it, with the reason) - and the page shows it for each
        request. Never throws: Azure has already taken the requests.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter()][int]$WaitSeconds = $script:VmfQuotaAnswerWaitSeconds,
        [Parameter()][int]$PollSeconds = $script:VmfQuotaAnswerPollSeconds
    )
    $startUtc = (Get-Date).ToUniversalTime()
    $pending = [System.Collections.Generic.List[object]]::new()
    try { foreach ($r in @(Get-VmfQuotaRequestsToRead -OutPath $OutPath -WaitSeconds $WaitSeconds -NowUtc $startUtc)) { $pending.Add($r) } }
    catch {
        Write-Warning "The product could not read the quota records to find the quota increase requests: $($_.Exception.Message)"
        return @()
    }
    if ($pending.Count -eq 0) { return @() }

    $left = (@($pending | ForEach-Object { ($_.Deadline - $startUtc).TotalSeconds }) | Measure-Object -Maximum).Maximum
    $rounds = [int][math]::Ceiling([math]::Max(0, $left) / [math]::Max(1, $PollSeconds)) + 1
    $last = @{}
    $done = [System.Collections.Generic.List[object]]::new()
    $minutes = [int][math]::Round($WaitSeconds / 60)
    $write = {
        param($req, $a)
        $guidName = @($req.RequestId.Split('/') | Where-Object { $_ })[-1]
        $about = "the quota increase request $guidName for $($req.QuotaName) in $($req.Region)"
        $outcome = 'info'
        $detail = switch ($a.Answer) {
            'APPROVED' { $outcome = 'ok'; "Azure accepted $about." }
            'REFUSED' {
                $outcome = 'warn'
                if ($a.Code) { "Azure refused $about, with the code $($a.Code)." } else { "Azure refused $about." }
            }
            'WAITING' {
                if ($a.State) { "Azure did not answer $about in $minutes minutes. The state of the request is $($a.State)." }
                else { "Azure did not answer $about in $minutes minutes." }
            }
            default { $outcome = 'warn'; "The product could not read $about. $($a.Reason)" }
        }
        Write-VmfStepLine -RunPath $OutPath -Step 'quotaAnswer' -Outcome $outcome -Detail $detail -Data @{
            requestId = $req.RequestId; requestName = $guidName; answer = $a.Answer; state = $a.State; code = $a.Code
            message = $a.Message; reason = $a.Reason; quotaName = $req.QuotaName; region = $req.Region; subscriptionId = $req.SubscriptionId
        }
        $done.Add([pscustomobject]@{ RequestId = $req.RequestId; Answer = $a.Answer; State = $a.State; Code = $a.Code })
    }

    # An ID that does not end with a GUID is never readable (Get-VmfQuotaRequestState
    # refuses it), so it is said at once rather than tried for 2 minutes.
    foreach ($req in @($pending)) {
        $tail = @($req.RequestId.Split('/') | Where-Object { $_ })
        $g = [guid]::Empty
        if (-not $tail.Count -or -not [guid]::TryParseExact($tail[-1], 'D', [ref]$g)) {
            & $write $req ([pscustomobject]@{ Answer = 'NOTREAD'; Final = $false; State = $null; Code = $null; Message = $null
                                             Reason = 'The request ID does not end with a GUID, so the product cannot read the request.' })
            [void]$pending.Remove($req)
        }
    }
    if ($pending.Count -eq 0) { return @($done) }

    for ($round = 1; $round -le $rounds; $round++) {
        foreach ($req in @($pending)) {
            try {
                $resp = Get-VmfQuotaRequestState -SubscriptionId $req.SubscriptionId -Location $req.Region -RequestId $req.RequestId
                $a = ConvertFrom-VmfQuotaRequestAnswer -StatusCode $resp.StatusCode -Content ([string]$resp.Content)
            }
            catch {
                $a = [pscustomobject]@{ Answer = 'NOTREAD'; Final = $false; State = $null; Code = $null; Message = $null
                                        Reason = "The read failed: $($_.Exception.Message)" }
            }
            # A read that failed does not hide a state an earlier read gave.
            if ($a.Answer -ne 'NOTREAD' -or -not $last.ContainsKey($req.RequestId)) { $last[$req.RequestId] = $a }
            if ($a.Final) { & $write $req $a; [void]$pending.Remove($req) }
        }
        if ($pending.Count -eq 0) { break }
        $now = (Get-Date).ToUniversalTime()
        if (@($pending | Where-Object { $_.Deadline -gt $now }).Count -eq 0) { break }
        if ($round -lt $rounds) { Start-Sleep -Seconds $PollSeconds }
    }
    foreach ($req in @($pending)) { & $write $req $last[$req.RequestId] }
    @($done)
}
