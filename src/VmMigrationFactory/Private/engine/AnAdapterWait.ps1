# AN-AMDV7-VF-GAP-1: VALIDATING waits for a late accelerated networking
# adapter before it fails the move.
#
# Measured 2026-11-06, 20 starts each on Ubuntu 22.04: on Intel
# Standard_D2s_v6 the virtual function appeared 3.6 to 6.2 seconds after boot,
# every time. On AMD Standard_D2as_v7 it was late on 9 of 20 starts (56, 85,
# 117, 120, 169, 189, 298, 423 and 435 seconds). It always arrived, and
# traffic flowed through it. The synthetic interface (hv_netvsc) carries the
# network during the wait - Microsoft documents that it carries traffic when
# the virtual function is absent, and that Azure can remove and add the
# virtual function again (host servicing). Verifying read once, so a healthy
# machine was rolled back for a virtual function that had not arrived yet.
#
# The wait is checkpointed in the state document (captured.anAdapterWait):
# when it started and how many reads finished. A worker that stops during the
# wait is resumed in the SAME wait - each read is counted once, and the window
# is not started again. The retry of the step after the window ran out reads
# once and fails. Clear-VmfRetryState removes the record, so the rollback and a
# person's retry start a new wait.

function Get-VmfAnAdapterWaitSettings {
    <#
    .SYNOPSIS
        The wait for the accelerated networking adapter: IntervalSeconds
        between reads, and WaitMinutes in all. From the engine's settings
        ($script:VmfAnAdapterWait, beside $script:VmfMaxAttempts).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{ IntervalSeconds = [int]$script:VmfAnAdapterWait.IntervalSeconds; WaitMinutes = [int]$script:VmfAnAdapterWait.WaitMinutes }
}

function Get-VmfAcceleratedFabric {
    <#
    .SYNOPSIS
        Which accelerated adapter a guest reading shows bound, if any. Pure.
    .DESCRIPTION
        The rule VALIDATING always used (VAL-1, REH-2): MANA when a check named
        'adapter bound' (Windows) or 'interface <name>' (Linux) passed; else an
        SR-IOV virtual function when a check named 'sriov' passed. Facts from
        mana-check.sh or Test-ManaReady.ps1; the engine judges them.
    .OUTPUTS
        @{ Bound = <bool>; Fabric = 'mana' | 'sriov' | ''; Detail = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Reading)
    $checks = @(@(if ($Reading -and $Reading.PSObject.Properties['checks']) { @($Reading.checks) }) | Where-Object { $_ })
    $mana = @($checks | Where-Object { $_.status -eq 'PASS' -and ($_.name -match 'adapter bound' -or $_.name -match '^interface ') })
    if ($mana.Count) { return @{ Bound = $true; Fabric = 'mana'; Detail = [string]$mana[0].detail } }
    $sriov = @($checks | Where-Object { $_.status -eq 'PASS' -and $_.name -match 'sriov' })
    if ($sriov.Count) { return @{ Bound = $true; Fabric = 'sriov'; Detail = [string]$sriov[0].detail } }
    @{ Bound = $false; Fabric = ''; Detail = '' }
}

function Get-VmfVfTrafficVerdict {
    <#
    .SYNOPSIS
        AN-TRAFFIC-VERIFY-1: whether the guest saw traffic on the accelerated
        path. Pure.
    .DESCRIPTION
        The guest reports the virtual function counters as the fact vfTraffic,
        read after it sent a few Instance Metadata Service requests: 'yes' when
        they show packets, 'no' when they show none or the virtual function is
        down, 'unknown' when it could not read them. Microsoft, and CLAUDE.md
        DRIVER-1: a loaded driver proves nothing; the counters are the proof.
        Anything but 'yes' or 'no' is 'unknown' - never read as either.
    .OUTPUTS
        @{ Verdict = 'yes' | 'no' | 'unknown'; Detail = <the guest's traffic line> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Reading)
    $said = ''
    if ($Reading -and $Reading.PSObject.Properties['facts'] -and $Reading.facts -and $Reading.facts.PSObject.Properties['vfTraffic']) {
        $said = [string]$Reading.facts.vfTraffic
    }
    $checks = @(@(if ($Reading -and $Reading.PSObject.Properties['checks']) { @($Reading.checks) }) | Where-Object { $_ })
    $line = @($checks | Where-Object { [string]$_.name -like 'vf carrying traffic*' } | Select-Object -First 1)
    @{
        Verdict = $(if ($said -ceq 'yes' -or $said -ceq 'no') { $said } else { 'unknown' })
        Detail  = $(if ($line.Count) { [string]$line[0].detail } else { '' })
    }
}

function Get-VmfAnAdapterWaitElapsed {
    <#
    .SYNOPSIS
        How many seconds of the wait are used. Pure.
    .DESCRIPTION
        The wall clock since the first read, or the waits between the reads
        that finished, whichever is more. Each read follows a wait of
        IntervalSeconds, so on a machine the wall clock is never less; the
        reads keep the wait bounded when the clock does not move (a test).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]$FirstReadUtc,
        [Parameter(Mandatory)][int]$Reads,
        [Parameter(Mandatory)][int]$IntervalSeconds,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $text = ConvertTo-VmfUtcText -Value $FirstReadUtc
    $started = [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $wall = ($NowUtc.ToUniversalTime() - $started).TotalSeconds
    $byReads = [double]([Math]::Max(0, $Reads - 1) * $IntervalSeconds)
    [Math]::Max($wall, $byReads)
}

function Save-VmfAnAdapterWait {
    # The checkpoint of the wait, or none ($null removes it).
    param([Parameter(Mandatory)]$Context, [Parameter()][AllowNull()]$Wait)
    if ($Wait) {
        Save-VmfCapturedFacts -Context $Context -Facts @{ anAdapterWait = [ordered]@{
                firstReadUtc = ConvertTo-VmfUtcText -Value $Wait.firstReadUtc; reads = [int]$Wait.reads } }
        return
    }
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if ($doc -and $doc.PSObject.Properties['captured'] -and $doc.captured -and $doc.captured.PSObject.Properties['anAdapterWait']) {
        $doc.captured.PSObject.Properties.Remove('anAdapterWait')
        Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
    }
}

function Wait-VmfAcceleratedAdapter {
    <#
    .SYNOPSIS
        VALIDATING's proof that accelerated networking runs: read the guest
        until an accelerated adapter is bound, for up to the wait in the
        engine's settings. Throws when the wait runs out.
    .DESCRIPTION
        One read. An adapter on it ends the step's question at once - every
        Intel start measured. With none, the wait starts (or a resumed worker
        continues the one on record): a read every IntervalSeconds, each
        checkpointed, until an adapter is bound or WaitMinutes are used. A read
        that throws is not counted, and the error goes to the step as before.
        AN-TRAFFIC-VERIFY-1: an adapter that is present but carries no
        traffic (Get-VmfVfTrafficVerdict says 'no') is not ready either. The
        wait goes on for it, and when the wait runs out with the adapter still
        present, the stop says it carried no traffic. Counters the guest could
        not read ('unknown') do not hold the wait: the caller says so.
    .OUTPUTS
        @{ Reading = <guest result that decided>; Fabric = Get-VmfAcceleratedFabric;
           Traffic = Get-VmfVfTrafficVerdict; Reads = <int>; Waited = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ScriptName)

    $settings = Get-VmfAnAdapterWaitSettings
    $interval = $settings.IntervalSeconds
    $minutes = $settings.WaitMinutes
    $read = {
        Invoke-VmfGuestScriptOnVm -ScriptName $ScriptName -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
    }
    $readyLine = {
        param($Wait)
        $seconds = [int][Math]::Round((Get-VmfAnAdapterWaitElapsed -FirstReadUtc $Wait.firstReadUtc -Reads $Wait.reads -IntervalSeconds $interval -NowUtc ([datetime]::UtcNow)))
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome ok -VmId $Context.VmId `
            -Detail "The accelerated networking adapter is ready after $seconds seconds. The product checked it $($Wait.reads) times."
    }

    # Ready: an adapter is present, and it is not known to carry no traffic.
    $isReady = { param($Fab, $Traf) $Fab.Bound -and $Traf.Verdict -ne 'no' }

    $reading = & $read
    $fabric = Get-VmfAcceleratedFabric -Reading $reading
    $traffic = Get-VmfVfTrafficVerdict -Reading $reading
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $onRecord = if ($doc -and $doc.PSObject.Properties['captured'] -and $doc.captured -and $doc.captured.PSObject.Properties['anAdapterWait']) { $doc.captured.anAdapterWait } else { $null }
    $wait = if ($onRecord) { @{ firstReadUtc = (ConvertTo-VmfUtcText -Value $onRecord.firstReadUtc); reads = [int]$onRecord.reads + 1 } } else { $null }

    if (& $isReady $fabric $traffic) {
        if (-not $wait) { return @{ Reading = $reading; Fabric = $fabric; Traffic = $traffic; Reads = 1; Waited = $false } }
        Save-VmfAnAdapterWait -Context $Context -Wait $null
        & $readyLine $wait
        return @{ Reading = $reading; Fabric = $fabric; Traffic = $traffic; Reads = $wait.reads; Waited = $true }
    }

    if ($wait) {
        Save-VmfAnAdapterWait -Context $Context -Wait $wait
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome info -VmId $Context.VmId `
            -Detail "The accelerated networking adapter is still not ready. The product continues the wait that started at $($wait.firstReadUtc), for up to $minutes minutes in all."
    }
    else {
        $wait = @{ firstReadUtc = [datetime]::UtcNow.ToString('o'); reads = 1 }
        Save-VmfAnAdapterWait -Context $Context -Wait $wait
        $firstLine = if ($fabric.Bound) {
            "The accelerated networking adapter is present, but its packet counters show no traffic. The product checks again every $interval seconds for up to $minutes minutes."
        }
        else {
            "The accelerated networking adapter is not ready yet. The product checks again every $interval seconds for up to $minutes minutes."
        }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome info -VmId $Context.VmId -Detail $firstLine
    }

    while ((Get-VmfAnAdapterWaitElapsed -FirstReadUtc $wait.firstReadUtc -Reads $wait.reads -IntervalSeconds $interval -NowUtc ([datetime]::UtcNow)) -lt ($minutes * 60)) {
        # The lease, as every wait in the engine renews it (S3-7).
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $interval
        $reading = & $read
        $wait.reads++
        $fabric = Get-VmfAcceleratedFabric -Reading $reading
        $traffic = Get-VmfVfTrafficVerdict -Reading $reading
        if (& $isReady $fabric $traffic) {
            Save-VmfAnAdapterWait -Context $Context -Wait $null
            & $readyLine $wait
            return @{ Reading = $reading; Fabric = $fabric; Traffic = $traffic; Reads = $wait.reads; Waited = $true }
        }
        Save-VmfAnAdapterWait -Context $Context -Wait $wait
    }
    # AN-TRAFFIC-VERIFY-1: the last read found the adapter, with no traffic.
    if ($fabric.Bound) {
        throw "The accelerated networking adapter is present, but its packet counters showed no traffic in $minutes minutes. The product checked it $($wait.reads) times."
    }
    throw "The accelerated networking adapter did not become ready in $minutes minutes. The product checked it $($wait.reads) times, and found no MANA interface and no SR-IOV virtual function."
}
