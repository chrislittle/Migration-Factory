<#
.SYNOPSIS
    Read-only check: is this Windows VM ready for SCSI-to-NVMe conversion?
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand. Checks, across ALL ControlSets:
    stornvme.sys present, stornvme Start=0 (Boot), stornvme StartOverride absent
    (the key NVMe boot blocker), pci Start=0, pci StartOverride absent, and the
    boot driver chain. Makes NO changes.

    Output contract: a single JSON object on stdout per schemas/guest-output.schema.json.
    result: READY | NEEDS_PREP | BLOCKED
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
$script:checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema  = 'vmf.guest/2'
        script  = 'Test-NvmeReady.ps1'
        version = $script:VERSION
        os      = $script:osCaption
        result  = $Result
        checks  = @($script:checks)
        warnings = @()
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    # 1. stornvme.sys driver binary
    $driverPath = Join-Path $env:SystemRoot 'System32\drivers\stornvme.sys'
    if (Test-Path $driverPath) {
        $ver = (Get-Item $driverPath).VersionInfo.FileVersion
        Add-Check 'stornvme.sys' 'PASS' "version $ver"
    }
    else {
        Add-Check 'stornvme.sys' 'FAIL' "not found at $driverPath"
        Emit -Result 'BLOCKED' -ErrorDetail 'stornvme.sys driver missing - NVMe conversion not possible'
        exit 0
    }

    # 2. All ControlSets: stornvme + pci Start / StartOverride
    $controlSets = @(Get-ChildItem 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        ForEach-Object { $_.PSChildName })
    $fail = 0

    foreach ($cs in $controlSets) {
        $csRoot = "HKLM:\SYSTEM\$cs"

        $start = (Get-ItemProperty -Path "$csRoot\Services\stornvme" -Name Start -ErrorAction SilentlyContinue).Start
        if ($start -eq 0) { Add-Check "$cs\stornvme Start" 'PASS' '0 (Boot)' }
        else { Add-Check "$cs\stornvme Start" 'FAIL' "$start (need 0=Boot)"; $fail++ }

        $soPath = "$csRoot\Services\stornvme\StartOverride"
        if (Test-Path $soPath) {
            $soVal = (Get-ItemProperty -Path $soPath -ErrorAction SilentlyContinue).'0'
            Add-Check "$cs\stornvme StartOverride" 'FAIL' "present (value=$soVal) overrides Start to demand-start"
            $fail++
        }
        else { Add-Check "$cs\stornvme StartOverride" 'PASS' 'absent' }

        $pciStart = (Get-ItemProperty -Path "$csRoot\Services\pci" -Name Start -ErrorAction SilentlyContinue).Start
        if ($pciStart -eq 0) { Add-Check "$cs\pci Start" 'PASS' '0 (Boot)' }
        else { Add-Check "$cs\pci Start" 'FAIL' "$pciStart (need 0=Boot)"; $fail++ }

        if (Test-Path "$csRoot\Services\pci\StartOverride") {
            Add-Check "$cs\pci StartOverride" 'FAIL' 'present - may block PCI bus enumeration'
            $fail++
        }
        else { Add-Check "$cs\pci StartOverride" 'PASS' 'absent' }

        # UPST-2 (2026-08-27): vpci and the stornvme driver parameters, from
        # Microsoft's Azure-NVMe-Utils 2026082514 BSOD fix. vpci is the one that
        # matters most - NVMe on Boost arrives over VIRTUAL PCI, so a vpci
        # StartOverride hides the controller the machine boots from.
        $vpciStart = (Get-ItemProperty -Path "$csRoot\Services\vpci" -Name Start -ErrorAction SilentlyContinue).Start
        if ($null -eq $vpciStart) { Add-Check "$cs\vpci Start" 'INFO' 'vpci service not present on this image' }
        elseif ($vpciStart -eq 0) { Add-Check "$cs\vpci Start" 'PASS' '0 (Boot)' }
        else { Add-Check "$cs\vpci Start" 'FAIL' "$vpciStart (need 0=Boot)"; $fail++ }

        if (Test-Path "$csRoot\Services\vpci\StartOverride") {
            Add-Check "$cs\vpci StartOverride" 'FAIL' 'present - hides the Virtual PCI bus the NVMe controller arrives on'
            $fail++
        }
        else { Add-Check "$cs\vpci StartOverride" 'PASS' 'absent' }

        $paramsPath = "$csRoot\Services\stornvme\Parameters"
        foreach ($p in @(
            @{ Name = 'IoTimeoutValue';           Want = 240 },
            @{ Name = 'BusType';                  Want = 17 },
            @{ Name = 'StorageSupportedFeatures'; Want = 3 }
        )) {
            $cur = (Get-ItemProperty -Path $paramsPath -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
            if ($cur -eq $p.Want) { Add-Check "$cs stornvme $($p.Name)" 'PASS' ([string]$p.Want) }
            else { Add-Check "$cs stornvme $($p.Name)" 'FAIL' "'$cur' (need $($p.Want))"; $fail++ }
        }
        $pnpCur = (Get-ItemProperty -Path "$paramsPath\PnpInterface" -Name '5' -ErrorAction SilentlyContinue).'5'
        if ($pnpCur -eq 1) { Add-Check "$cs stornvme PnpInterface\5" 'PASS' '1' }
        else { Add-Check "$cs stornvme PnpInterface\5" 'FAIL' "'$pnpCur' (need 1)"; $fail++ }
    }

    # 3. Boot driver chain (CurrentControlSet), warnings only
    $selectProps = Get-ItemProperty 'HKLM:\SYSTEM\Select' -ErrorAction SilentlyContinue
    $currentCS = 'HKLM:\SYSTEM\ControlSet{0:D3}' -f [int]$selectProps.Current
    foreach ($driver in @('partmgr', 'disk', 'volmgr', 'volume', 'volsnap', 'mountmgr')) {
        $drvPath = "$currentCS\Services\$driver"
        if (Test-Path $drvPath) {
            $drvStart = (Get-ItemProperty -Path $drvPath -Name Start -ErrorAction SilentlyContinue).Start
            if ($drvStart -eq 0) { Add-Check $driver 'PASS' 'Start=0 (Boot)' }
            else { Add-Check $driver 'WARN' "Start=$drvStart (non-boot)" }
        }
        else { Add-Check $driver 'WARN' 'service not found' }
    }

    # STORAGE-SPACES-1: record the customer's storage topology BEFORE the move,
    # so VALIDATING has something to compare against afterwards. A pool spanning
    # data disks is not boot-critical, so nothing else would ever notice it came
    # back a member short - the machine boots, the agent reports Ready, and the
    # volume holding the data is simply absent.
    #
    # FACTS ONLY, and INFO always: this script's PASS/FAIL is about NVMe boot
    # readiness. A customer's storage pool is never a reason to refuse to
    # prepare a machine - it is a thing to remember and check later.
    #
    # Our own temp pool is excluded by name; it does not exist yet at this point
    # anyway, and including it would make the before/after comparison disagree
    # with itself by construction.
    try {
        $custPools = @(Get-StoragePool -ErrorAction SilentlyContinue |
            Where-Object { -not $_.IsPrimordial -and $_.FriendlyName -ne 'NVMeTempPool' })
        if ($custPools.Count -gt 0) {
            Add-Check 'storage pools' 'INFO' (($custPools | ForEach-Object {
                "$($_.FriendlyName)[health=$($_.HealthStatus);disks=$(@($_ | Get-PhysicalDisk -ErrorAction SilentlyContinue).Count)]" }) -join ' ')
            $custVds = @(Get-VirtualDisk -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -ne 'NVMeTempDisk' })
            Add-Check 'storage volumes' 'INFO' (($custVds | ForEach-Object {
                "$($_.FriendlyName)[health=$($_.HealthStatus);state=$($_.OperationalStatus)]" }) -join ' ')
        }
        else { Add-Check 'storage pools' 'INFO' 'none' }
    }
    catch { Add-Check 'storage pools' 'INFO' "could not be inspected on this image: $($_.Exception.Message)" }

    if ($fail -eq 0) { Emit -Result 'READY' } else { Emit -Result 'NEEDS_PREP' }
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
