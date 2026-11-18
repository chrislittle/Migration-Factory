<#
.SYNOPSIS
    Check Windows readiness for the MANA network adapter (v6/v7 networking).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand. Read-only: it reports the MANA
    driver file, the bound adapters and the OS version as facts. It does not
    judge a missing driver file (MANA-READY-ADVICE-1): Windows installs the
    driver when the hardware appears (AN-KEEP-1), and GUEST_PREP adds the
    MANA driver to the driver store when the store has none (MANA-WIN-1).

    Output contract: schemas/guest-output.schema.json. result: READY | NEEDS_PREP
    (advisory - never BLOCKED: the platform falls back to synthetic NIC).
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.4.0'
# The lowest Windows Server release Microsoft lists for MANA (driver-floors.json).
$script:LowestListedName = 'Windows Server 2016'
$script:LowestListedBuild = '10.0.14393'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:facts = [ordered]@{}

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Add-Fact {
    param([string]$Name, [string]$Value)
    $script:facts[$Name] = [string]$Value
}

function Send-VfTraffic {
    # AN-TRAFFIC-VERIFY-1: three Instance Metadata Service requests, 0.3
    # seconds apart (inside its limit of 5 requests a second), so the machine
    # sent traffic just before the counters are read. Header Metadata: true,
    # and no proxy - Windows PowerShell 5.1 has no -NoProxy (VERIFY-FP-1). An
    # answer is not needed; a machine that never reaches the service still
    # sent the requests.
    $uri = 'http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01'
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $req = [System.Net.WebRequest]::Create($uri)
            $req.Proxy = $null
            $req.Headers.Add('Metadata', 'true')
            $req.Timeout = 1000
            $resp = $req.GetResponse()
            $resp.Close()
        }
        catch {
            # An error answer holds a connection open until it is closed.
            $inner = $_.Exception.InnerException
            if ($inner -and $inner.PSObject.Properties['Response'] -and $inner.Response) { $inner.Response.Close() }
        }
        Start-Sleep -Milliseconds 300
    }
}

function Read-VfCounters {
    # AN-TRAFFIC-VERIFY-1: the unicast packet counters of each virtual function
    # adapter (MANA or Mellanox), by name. An adapter that is not Up carries no
    # traffic now, whatever its counters say; counters that cannot be read are
    # unknown, never zero.
    param([object[]]$Adapters)
    $read = [ordered]@{}
    foreach ($a in $Adapters) {
        $name = [string]$a.Name
        if ([string]$a.Status -ne 'Up') {
            $read[$name] = @{ state = 'down'; text = ('{0} is {1}' -f $name, $a.Status) }
            continue
        }
        try {
            $st = Get-NetAdapterStatistics -Name $name -ErrorAction Stop
            if ($null -eq $st -or ($null -eq $st.ReceivedUnicastPackets -and $null -eq $st.SentUnicastPackets)) {
                $read[$name] = @{ state = 'unread'; text = ('{0}: counters not read' -f $name) }
                continue
            }
            $rx = [uint64]$st.ReceivedUnicastPackets
            $tx = [uint64]$st.SentUnicastPackets
            $state = 'zero'
            if ($rx -gt 0 -or $tx -gt 0) { $state = 'traffic' }
            $read[$name] = @{ state = $state; text = ('{0}: ReceivedUnicastPackets={1} SentUnicastPackets={2}' -f $name, $rx, $tx) }
        }
        catch {
            $read[$name] = @{ state = 'unread'; text = ('{0}: counters not read' -f $name) }
        }
    }
    $read
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osCaption = '{0} ({1})' -f $os.Caption, $os.Version
    $needsPrep = $false
    # Which OS this is, as a FACT the engine can branch on. Found by the UPST-2
    # drill: without it the engine fell back to the OS caption and, since
    # "Microsoft Windows Server 2022 Datacenter (...)" is not the string
    # 'Windows', judged every Windows machine against Linux's MANA kernel floor.
    Add-Fact 'os' 'Windows'
    Add-Fact 'osVersion' ([string]$os.Version)

    # The MANA driver file, read as a fact. MANA-READY-ADVICE-1: no file is
    # NOT a reason to prepare. AN-KEEP-1: a Windows machine with no mana*.sys
    # before the move is normal - Windows installs the driver when the MANA
    # hardware appears. MANA-WIN-1: when the target can use MANA, GUEST_PREP
    # reads the driver store (Install-ManaDriver.ps1) and adds the pinned MANA
    # driver when the store has none. So the detail states the fact only (this
    # check also runs after the move), and it gives no advice to install updates.
    $manaDriver = Get-ChildItem "$env:SystemRoot\System32\drivers" -Filter 'mana*.sys' -ErrorAction SilentlyContinue
    $driverVersion = ''
    if ($manaDriver) {
        $ver = ($manaDriver | Select-Object -First 1).VersionInfo.FileVersion
        $driverVersion = [string]$ver
        Add-Check 'mana driver file' 'PASS' "$($manaDriver[0].Name) version $ver"
    }
    else {
        Add-Check 'mana driver file' 'INFO' 'No mana*.sys file is in System32\drivers.'
    }
    Add-Fact 'driverVersion' $driverVersion

    # Any adapter already bound to MANA (present only on Boost hosts, informational elsewhere)
    $manaAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.DriverDescription -like '*MANA*' -or $_.DriverDescription -like '*Microsoft Azure Network Adapter*' })
    if ($manaAdapters.Count -gt 0) {
        Add-Check 'mana adapter bound' 'PASS' (($manaAdapters | ForEach-Object { $_.Name }) -join ', ')
    }
    else {
        Add-Check 'mana adapter bound' 'INFO' 'none bound (expected before migration to v6/v7)'
    }

    # DRIVER-1: which fabric is actually carrying this machine. Mellanox is as
    # valid as MANA - some v6 clusters accelerate via an SR-IOV VF (REH-2).
    $mlxAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.DriverDescription -like '*Mellanox*' -or $_.DriverDescription -like '*ConnectX*'
    })
    if ($manaAdapters.Count -gt 0) { $fabric = 'mana' }
    elseif ($mlxAdapters.Count -gt 0) { $fabric = 'mlx5' }
    else { $fabric = 'none' }
    Add-Fact 'fabric' $fabric
    if ($fabric -eq 'mlx5') {
        Add-Fact 'driverVersion' ([string](($mlxAdapters | Select-Object -First 1).DriverVersion))
    }

    # SR-IOV VF fabric (Mellanox ConnectX): some v6 clusters serve accelerated
    # networking via a classic SR-IOV VF instead of MANA (observed on
    # E2ads_v6/AMD, REH-2). A fact, not a judgment - the engine decides.
    $vfAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and ($_.InterfaceDescription -like '*Mellanox*' -or $_.InterfaceDescription -like '*ConnectX*')
    })
    if ($vfAdapters.Count -gt 0) {
        Add-Check 'sriov vf bound' 'PASS' (($vfAdapters | ForEach-Object { "$($_.Name) ($($_.InterfaceDescription))" }) -join ', ')
    }
    else {
        Add-Check 'sriov vf bound' 'INFO' 'no SR-IOV VF adapter up'
    }

    # DRIVER-1 and AN-TRAFFIC-VERIFY-1: proof that the accelerated path is
    # really in use is its packet counters - an adapter that is present
    # proves nothing. Read before and after the Instance Metadata Service
    # requests; the reading after them decides, and the one before is kept
    # as evidence of the increment. A fact: the ENGINE judges it.
    $vfAll = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.DriverDescription -like '*MANA*' -or $_.DriverDescription -like '*Microsoft Azure Network Adapter*' -or
        $_.InterfaceDescription -like '*Microsoft Azure Network Adapter*' -or
        $_.InterfaceDescription -like '*Mellanox*' -or $_.InterfaceDescription -like '*ConnectX*' -or
        $_.DriverDescription -like '*Mellanox*' -or $_.DriverDescription -like '*ConnectX*'
    })
    if ($vfAll.Count -eq 0) {
        Add-Check 'vf carrying traffic' 'INFO' 'No MANA or Mellanox adapter is present.'
        Add-Fact 'vfTraffic' 'unknown'
    }
    else {
        $vfBefore = Read-VfCounters -Adapters $vfAll
        Send-VfTraffic
        $vfAfter = Read-VfCounters -Adapters $vfAll
        $states = @($vfAfter.Values | ForEach-Object { $_.state })
        $detail = '{0}. Before the metadata requests: {1}.' -f (@($vfAfter.Values | ForEach-Object { $_.text }) -join '; '), (@($vfBefore.Values | ForEach-Object { $_.text }) -join '; ')
        if ($states -contains 'traffic') {
            Add-Check 'vf carrying traffic' 'PASS' $detail
            Add-Fact 'vfTraffic' 'yes'
        }
        elseif ($states -contains 'unread') {
            Add-Check 'vf carrying traffic' 'INFO' $detail
            Add-Fact 'vfTraffic' 'unknown'
        }
        else {
            Add-Check 'vf carrying traffic' 'WARN' $detail
            Add-Fact 'vfTraffic' 'no'
        }
    }

    # The OS version, as a fact. MANA-READY-OS-FLOOR-1: Microsoft's accelerated
    # networking overview lists Windows Server 2016 and later for MANA, and
    # driver-floors.json (mana.windows.supportedProducts) holds that list. A
    # unit test keeps the two values below equal to the lowest Windows Server
    # release in it. Only a version below that release is NEEDS_PREP.
    if ([version]$os.Version -ge [version]$script:LowestListedBuild) {
        Add-Check 'os version floor' 'INFO' ('Version {0} is installed.' -f $os.Version)
    }
    else {
        Add-Check 'os version floor' 'WARN' ('Version {0} is installed. Microsoft lists {1} and later.' -f $os.Version, $script:LowestListedName)
        $needsPrep = $true
    }

    $result = if ($needsPrep) { 'NEEDS_PREP' } else { 'READY' }
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-ManaReady.ps1'; version = $script:VERSION
        os = $osCaption; result = $result; checks = @($script:checks); facts = $script:facts; warnings = @()
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-ManaReady.ps1'; version = $script:VERSION
        os = ''; result = 'BLOCKED'; checks = @($script:checks); facts = $script:facts; warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
