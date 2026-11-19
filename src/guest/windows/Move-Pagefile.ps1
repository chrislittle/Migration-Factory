<#
.SYNOPSIS
    Migrate the Windows pagefile from D:\ (SCSI temp disk) to C:\ ahead of a move
    to a size without a formatted temp disk.
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand. Idempotent; takes effect on next
    boot (no reboot triggered here - the VM is about to be deallocated anyway).

    Output contract: schemas/guest-output.schema.json.
    result: FIXED | NO_CHANGE | BLOCKED.

    TEMPCHECK-FIRST-1: this script no longer lists what is on D:\. That is
    Test-TempDiskContent.ps1, which the engine asks BEFORE any change, so a
    machine that stops for those files is left as it was.
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.1.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:warnings = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema  = 'vmf.guest/2'
        script  = 'Move-Pagefile.ps1'
        version = $script:VERSION
        os      = $script:osCaption
        result  = $Result
        checks  = @($script:checks)
        warnings = @($script:warnings)
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    $existing = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
    $cs = Get-CimInstance Win32_ComputerSystem
    $hasC = $existing | Where-Object { $_.Name -like 'C:\*' }
    $hasD = $existing | Where-Object { $_.Name -like 'D:\*' }

    $changed = $false

    if ($hasC -and -not $hasD -and -not $cs.AutomaticManagedPagefile) {
        Add-Check 'pagefile placement' 'PASS' 'already C:\ only, not auto-managed'
    }
    else {
        if ($cs.AutomaticManagedPagefile) {
            $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } | Out-Null
            Add-Check 'auto-managed pagefile' 'FIXED' 'disabled'
            $changed = $true
        }
        foreach ($pf in @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)) {
            $name = $pf.Name
            $pf | Remove-CimInstance
            Add-Check "remove pagefile $name" 'FIXED' ''
            $changed = $true
        }
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name = 'C:\pagefile.sys'; InitialSize = [uint32]0; MaximumSize = [uint32]0
        } | Out-Null
        Add-Check 'pagefile C:\pagefile.sys' 'FIXED' 'system-managed, effective next boot'
        $changed = $true
    }

    if ($changed) { Emit -Result 'FIXED' } else { Emit -Result 'NO_CHANGE' }
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
