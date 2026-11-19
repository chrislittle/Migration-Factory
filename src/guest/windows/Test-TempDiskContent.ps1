<#
.SYNOPSIS
    List what is on the SCSI temporary disk that Windows and Azure did not put
    there. Read-only (TEMPCHECK-FIRST-1).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1.

    A move stops (deallocates) the machine, which can empty the temporary disk,
    and a target without one has nowhere to put it back. The engine asks this in
    PRECHECK, while the machine still runs and before anything stops or changes
    it, so a machine that stops for these files is left exactly as it was.

    The temporary disk is the volume that holds Azure's
    DATALOSS_WARNING_README.txt - usually D:, but not always. A D: without it is
    a data disk, and is not reported.

    RunCommand returns only the last 4096 bytes of output, so at most 40 items
    or about 2500 characters are named, then "and N more".

    Output contract: schemas/guest-output.schema.json. result: READY (nothing
    to lose), NEEDS_PREP (files found - listed in `warnings`), BLOCKED (the
    script, or the listing, failed). The ENGINE decides, by the wave's
    onDDataFound setting.
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.1.0'
$script:MAXNAMED = 40
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:warnings = [System.Collections.Generic.List[string]]::new()
$script:osCaption = ''

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema   = 'vmf.guest/2'
        script   = 'Test-TempDiskContent.ps1'
        version  = $script:VERSION
        os       = $script:osCaption
        result   = $Result
        checks   = @($script:checks)
        warnings = @($script:warnings)
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    # The temporary disk is the volume Azure marked with its warning file.
    $temp = $null
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem | Sort-Object Name)) {
        if (Test-Path -LiteralPath (Join-Path $drive.Root 'DATALOSS_WARNING_README.txt')) { $temp = $drive.Root; break }
    }
    if (-not $temp) {
        Add-Check 'temporary disk content' 'INFO' 'no temporary disk found (no DATALOSS_WARNING_README.txt on any volume)'
        Emit -Result 'READY'
        exit 0
    }

    # What Windows and Azure put on the temporary disk themselves.
    # DumpStack.log/.tmp: crash-dump plumbing Windows creates on the page file
    # volume - missing them stopped EVERY Windows temp-disk machine whose
    # setting said stop (REH-2).
    $standard = @('pagefile.sys', 'swapfile.sys', 'hiberfil.sys', 'Temp', 'Windows',
                  'CollectGuestLogsTemp', 'DATALOSS_WARNING_README.txt',
                  'DumpStack.log', 'DumpStack.log.tmp',
                  'System Volume Information', '$RECYCLE.BIN')
    # -ErrorAction Stop: a listing that fails is BLOCKED, never "nothing found".
    $nonStd = @(Get-ChildItem -LiteralPath $temp -Force -ErrorAction Stop |
        Where-Object { $_.Name -notin $standard })
    if ($nonStd.Count -gt 0) {
        # Named until 40 items or about 2500 characters, whichever comes first.
        $used = 0
        foreach ($item in $nonStd) {
            $line = [string]$item.FullName
            if ($script:warnings.Count -ge $script:MAXNAMED -or ($used + $line.Length) -gt 2500) { break }
            $script:warnings.Add($line); $used += $line.Length
        }
        $more = $nonStd.Count - $script:warnings.Count
        if ($more -eq 1) { $script:warnings.Add('1 more file or folder') }
        elseif ($more -gt 1) { $script:warnings.Add("$more more files or folders") }
        if ($nonStd.Count -eq 1) { $items = '1 file or folder' } else { $items = "$($nonStd.Count) files or folders" }
        Add-Check 'temporary disk content' 'WARN' "The script found $items on $temp that the system did not create. The warnings list them."
        Emit -Result 'NEEDS_PREP'
    }
    else {
        Add-Check 'temporary disk content' 'PASS' "The script found only system files and folders on $temp."
        Emit -Result 'READY'
    }
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
