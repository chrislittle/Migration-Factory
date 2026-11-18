<#
.SYNOPSIS
    Prepare a Windows VM for SCSI-to-NVMe conversion: stornvme boot-start across
    ALL ControlSets, StartOverride removed, registry flushed to disk.
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand. Idempotent.

    CRITICAL invariants (validated on 450+ VMs by the source scripts):
    - Fix ALL ControlSets, not just CurrentControlSet. LastKnownGood with a stale
      StartOverride causes INACCESSIBLE_BOOT_DEVICE on boot recovery.
    - Registry changes are flushed SYNCHRONOUSLY (RegistryKey.Flush) before returning;
      the lazy writer may otherwise lose them to an immediate deallocation.
    - Each SCSI boot re-creates StartOverride: the caller MUST deallocate the VM
      immediately after this script succeeds, with no reboot in between.
    - Do NOT shut down from inside this script (races with Stop-AzVM).

    Output contract: schemas/guest-output.schema.json.
    result: FIXED | NO_CHANGE | BLOCKED
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:changed = $false

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
    if ($Status -eq 'FIXED') { $script:changed = $true }
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema  = 'vmf.guest/2'
        script  = 'Set-NvmeReady.ps1'
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

    $driverPath = Join-Path $env:SystemRoot 'System32\drivers\stornvme.sys'
    if (-not (Test-Path $driverPath)) {
        Add-Check 'stornvme.sys' 'FAIL' "not found at $driverPath"
        Emit -Result 'BLOCKED' -ErrorDetail 'stornvme.sys driver missing'
        exit 0
    }
    Add-Check 'stornvme.sys' 'PASS' ((Get-Item $driverPath).VersionInfo.FileVersion)

    # sc.exe config handles CurrentControlSet atomically (Start=0 AND StartOverride removal)
    & sc.exe config stornvme start= boot *> $null
    if ($LASTEXITCODE -eq 0) { Add-Check 'sc.exe stornvme start=boot' 'PASS' '' }
    else { Add-Check 'sc.exe stornvme start=boot' 'WARN' "exit $LASTEXITCODE - continuing with registry" }

    # Fix ALL ControlSets manually (sc.exe only touches CurrentControlSet)
    $controlSets = @(Get-ChildItem 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        ForEach-Object { $_.PSChildName })

    foreach ($cs in $controlSets) {
        $csRoot = "HKLM:\SYSTEM\$cs"

        # UPST-2: vpci added 2026-08-27 from Microsoft's Azure-NVMe-Utils
        # 2026082514 - "fix Windows starting with BSOD after conversion by
        # adding additional registry keys". NVMe on Boost arrives over VIRTUAL
        # PCI, so a vpci StartOverride hides the controller the machine is
        # trying to boot from: INACCESSIBLE_BOOT_DEVICE, the failure with no
        # cheap recovery. We had stornvme and pci and had never touched vpci.
        foreach ($svc in @('stornvme', 'pci', 'vpci')) {
            $svcPath = "$csRoot\Services\$svc"

            # EVAL-M2: not every image has vpci. The CHECKER treats its absence
            # as INFO ("Absent is not the same as misconfigured", locked in by a
            # hygiene test) - and this loop wrote to it regardless, which throws
            # under ErrorActionPreference Stop and emitted BLOCKED with a raw
            # registry path. Such an image could never be prepared, and the
            # error named neither vpci nor the image. Every other write in this
            # file guards with Test-Path; this one did not.
            if (-not (Test-Path $svcPath)) {
                Add-Check "$cs\$svc" 'INFO' 'not present on this image - nothing to set'
                continue
            }

            $cur = (Get-ItemProperty -Path $svcPath -Name Start -ErrorAction SilentlyContinue).Start
            if ($cur -eq 0) { Add-Check "$cs\$svc Start" 'PASS' '0 (Boot)' }
            else {
                Set-ItemProperty -Path $svcPath -Name 'Start' -Value 0 -Type DWord
                Add-Check "$cs\$svc Start" 'FIXED' "was $cur, set to 0"
            }

            $soPath = "$svcPath\StartOverride"
            if (Test-Path $soPath) {
                Remove-Item -Path $soPath -Recurse -Force
                if (Test-Path $soPath) {
                    Add-Check "$cs\$svc StartOverride" 'FAIL' 'removal failed'
                    Emit -Result 'BLOCKED' -ErrorDetail "Could not remove $cs\$svc StartOverride"
                    exit 0
                }
                Add-Check "$cs\$svc StartOverride" 'FIXED' 'removed'
            }
            else { Add-Check "$cs\$svc StartOverride" 'PASS' 'absent' }
        }

        # UPST-2: the stornvme driver parameters from the same upstream fix.
        # IoTimeoutValue is the Windows twin of the nvme_core.io_timeout=240 we
        # already set on Linux - without it an NVMe I/O that stalls longer than
        # the default is treated as a failed device. The other three configure
        # how stornvme claims the controller; they come from Microsoft's script
        # for THIS conversion and we have no independent account of them, which
        # is why every one is reported as its own check rather than hidden in a
        # single "parameters" line.
        #
        # These touch the NVMe driver only. The machine is still booting SCSI
        # through storvsc at this point, so a wrong value cannot strand it
        # before the conversion - it would surface as a failed conversion, not
        # a failed rollback.
        $paramsPath = "$csRoot\Services\stornvme\Parameters"
        if (-not (Test-Path $paramsPath)) {
            New-Item -Path $paramsPath -Force | Out-Null
            Add-Check "$cs stornvme Parameters" 'FIXED' 'key created'
        }
        foreach ($p in @(
            @{ Name = 'IoTimeoutValue';           Value = 240; Why = 'seconds an NVMe I/O may stall before the device is failed' },
            @{ Name = 'BusType';                  Value = 17;  Why = 'NVMe' },
            @{ Name = 'StorageSupportedFeatures'; Value = 3;   Why = 'upstream value' }
        )) {
            $cur = (Get-ItemProperty -Path $paramsPath -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
            if ($cur -eq $p.Value) { Add-Check "$cs stornvme $($p.Name)" 'PASS' "$($p.Value) ($($p.Why))" }
            else {
                Set-ItemProperty -Path $paramsPath -Name $p.Name -Value $p.Value -Type DWord
                Add-Check "$cs stornvme $($p.Name)" 'FIXED' "was '$cur', set to $($p.Value)"
            }
        }

        $pnpPath = "$paramsPath\PnpInterface"
        if (-not (Test-Path $pnpPath)) { New-Item -Path $pnpPath -Force | Out-Null }
        $pnpCur = (Get-ItemProperty -Path $pnpPath -Name '5' -ErrorAction SilentlyContinue).'5'
        if ($pnpCur -eq 1) { Add-Check "$cs stornvme PnpInterface\5" 'PASS' '1' }
        else {
            Set-ItemProperty -Path $pnpPath -Name '5' -Value 1 -Type DWord
            Add-Check "$cs stornvme PnpInterface\5" 'FIXED' "was '$pnpCur', set to 1"
        }
    }

    # Synchronous flush: RegFlushKey returns only when data IS on disk
    try {
        $systemKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM', $false)
        $systemKey.Flush()
        $systemKey.Close()
        Add-Check 'registry flush' 'PASS' 'SYSTEM hive flushed synchronously'
    }
    catch {
        $flushOK = $true
        foreach ($cs in $controlSets) {
            try {
                $csKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\$cs\Services\stornvme", $false)
                if ($csKey) { $csKey.Flush(); $csKey.Close() }
            }
            catch { $flushOK = $false }
        }
        if (-not $flushOK) {
            Add-Check 'registry flush' 'FAIL' 'both flush strategies failed'
            Emit -Result 'BLOCKED' -ErrorDetail 'Registry flush failed - changes may not persist across deallocation'
            exit 0
        }
        Add-Check 'registry flush' 'PASS' 'per-ControlSet flush fallback'
    }

    # Post-flush verification: re-read to confirm persistence
    foreach ($cs in $controlSets) {
        if (Test-Path "HKLM:\SYSTEM\$cs\Services\stornvme\StartOverride") {
            Add-Check "$cs post-flush verify" 'FAIL' 'StartOverride reappeared'
            Emit -Result 'BLOCKED' -ErrorDetail "$cs stornvme StartOverride still present after flush"
            exit 0
        }
    }
    Add-Check 'post-flush verify' 'PASS' 'StartOverride absent in all ControlSets'

    if ($script:changed) { Emit -Result 'FIXED' } else { Emit -Result 'NO_CHANGE' }
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
