# VOLUMES-ONLINE-1 (final lab, 2026-11-13): are the volumes the machine had
# mounted before the move mounted again - after the move, after a rollback and
# after Restore this machine? The goal: on every OS type, the volumes are
# online as they were before, after a migration and after a rollback.
#
# The guest validation scripts report the volumes as a FACT ('mounted volumes':
# the mount points joined with '; ', or 'none'); the engine judges them against
# the reading of the same script before the move (captured.guestBefore), per
# the SCSI-direction rule. These functions are pure.

function Get-VmfMountedVolumes {
    <#
    .SYNOPSIS
        The mounted volumes a guest validation reading reports, or $null when
        it does not report them. Pure.
    .DESCRIPTION
        $null means NOT ASKED - an output with no 'mounted volumes' check (a
        reading that failed, or no reading). That stays distinct from 'none',
        which is a real answer: the machine mounts nothing the script lists.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$GuestOutput)
    $checks = @(if ($GuestOutput -and $GuestOutput.PSObject.Properties['checks']) { $GuestOutput.checks })
    $check = @($checks | Where-Object { $_ -and [string]$_.name -eq 'mounted volumes' }) | Select-Object -First 1
    if (-not $check) { return $null }
    $detail = ([string]$check.detail).Trim()
    if (-not $detail -or $detail -eq 'none') { return , [string[]]@() }
    , [string[]]@($detail -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-VmfVolumesBack {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-1: is every volume that was mounted before mounted now?
        Pure.
    .DESCRIPTION
        Only a volume LOST is a failure: more volumes after than before is
        somebody's change, not this check's business. UNKNOWN IS NOT A PASS
        AND NOT A FAIL: a side that was not asked gives UNKNOWN with Ok, and
        the words say which side - failing would roll a healthy machine back
        for a reading that could not be taken; passing would be the claim this
        item exists to stop.
        -CaseSensitive for Linux paths; Windows drive letters and folders
        compare without case.
    .OUTPUTS
        @{ Ok; Verdict = 'MATCH'|'MISSING'|'UNKNOWN'; Missing = @(); Detail }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        [Parameter()][switch]$CaseSensitive
    )
    $b = Get-VmfMountedVolumes -GuestOutput $Before
    $a = Get-VmfMountedVolumes -GuestOutput $After
    if ($null -eq $b -or $null -eq $a) {
        $side = if ($null -eq $b -and $null -eq $a) { 'before or after' } elseif ($null -eq $b) { 'before' } else { 'after' }
        return @{ Ok = $true; Verdict = 'UNKNOWN'; Missing = @()
                  Detail = "this machine was not asked which volumes were mounted $side the move, so the product cannot say whether every volume is mounted" }
    }
    $comparer = if ($CaseSensitive) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
    $now = [System.Collections.Generic.HashSet[string]]::new([string[]]@($a), $comparer)
    $missing = @($b | Where-Object { -not $now.Contains([string]$_) })
    if ($missing.Count) {
        return @{ Ok = $false; Verdict = 'MISSING'; Missing = $missing
                  Detail = "these volumes were mounted before the move and are not mounted now: $($missing -join ', ')" }
    }
    $named = if (@($b).Count) { @($b) -join ', ' } else { 'none' }
    @{ Ok = $true; Verdict = 'MATCH'; Missing = @()
       Detail = "every volume that was mounted before the move is mounted: $named" }
}

function Get-VmfLvmDevicesFileFact {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-1: the LVM devices file as a Linux guest script reports
        it ('lvm devices file'). Pure.
    .OUTPUTS
        @{ State = 'inUse'|'notInUse'|'noLvm'|'unknown'; Detail; Path; Total; NotFound }
        Total and NotFound are $null unless the file is in use.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$GuestOutput)
    $checks = @(if ($GuestOutput -and $GuestOutput.PSObject.Properties['checks']) { $GuestOutput.checks })
    $check = @($checks | Where-Object { $_ -and [string]$_.name -eq 'lvm devices file' }) | Select-Object -First 1
    $detail = if ($check) { [string]$check.detail } else { '' }
    $fact = @{ State = 'unknown'; Detail = $detail; Path = $null; Total = $null; NotFound = $null }
    if ($detail -eq 'not in use') { $fact.State = 'notInUse' }
    elseif ($detail -eq 'LVM is not installed') { $fact.State = 'noLvm' }
    elseif ($detail -match '^in use \((.*)\): (\d+) physical volume\(s\), (every one found|(\d+) not found)') {
        $fact.State = 'inUse'
        $fact.Path = $Matches[1]
        $fact.Total = [int]$Matches[2]
        $fact.NotFound = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
    }
    $fact
}

# VOLUMES-ONLINE-WINDOWS-1: the 'data disks' fact of Test-GuestValidation.ps1 -
# each data disk as "<key>=<number>:<online|offline>:<writable|readonly>",
# joined by '; ', or 'none'. The key is the partition table's own ID: gpt: and
# the disk GUID, or mbr: and the signature in 8 hex digits. A disk made from a
# snapshot keeps it, and so does the same disk on NVMe; the disk number can
# change.
$script:VmfDiskKeyPattern = '^(gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|mbr:[0-9a-f]{8})$'

function Get-VmfDataDiskStates {
    <#
    .SYNOPSIS
        The data disks a Windows guest validation reading reports, or $null
        when it does not report them (not asked). Pure.
    .OUTPUTS
        @(@{ Key; Number; Offline; ReadOnly }) - an empty list for 'none'.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$GuestOutput)
    $checks = @(if ($GuestOutput -and $GuestOutput.PSObject.Properties['checks']) { $GuestOutput.checks })
    $check = @($checks | Where-Object { $_ -and [string]$_.name -eq 'data disks' }) | Select-Object -First 1
    if (-not $check) { return $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($part in @(([string]$check.detail) -split ';')) {
        $m = [regex]::Match($part.Trim(), '^(?<key>[^=\s]+)=(?<n>\d+):(?<on>online|offline):(?<rw>writable|readonly)$')
        if (-not $m.Success) { continue }
        $key = $m.Groups['key'].Value.ToLowerInvariant()
        if ($key -notmatch $script:VmfDiskKeyPattern) { continue }
        $rows.Add([pscustomobject]@{ Key = $key; Number = [int]$m.Groups['n'].Value; Offline = ($m.Groups['on'].Value -eq 'offline'); ReadOnly = ($m.Groups['rw'].Value -eq 'readonly') })
    }
    , $rows.ToArray()
}

function Get-VmfDisksToBringOnline {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-WINDOWS-1: the data disks to put back as they were
        before the move. Pure.
    .DESCRIPTION
        Online: each disk offline now that the reading before the move shows
        online. Writable: each disk read-only now that the reading before the
        move shows writable. A disk not in the reading before the move, or a
        side that was not read, is left as it is: the product changes only
        what it can prove the move changed.
    .OUTPUTS
        @{ Online = @(rows of the reading now); Writable = @(rows of the reading now) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Before, [Parameter()][AllowNull()]$After)
    $out = @{ Online = @(); Writable = @() }
    $was = Get-VmfDataDiskStates -GuestOutput $Before
    $now = Get-VmfDataDiskStates -GuestOutput $After
    if ($null -eq $was -or $null -eq $now) { return $out }
    $byKey = @{}
    foreach ($w in @($was)) { $byKey[[string]$w.Key] = $w }
    $out.Online = @(@($now) | Where-Object { $_.Offline -and $byKey.ContainsKey([string]$_.Key) -and -not $byKey[[string]$_.Key].Offline })
    $out.Writable = @(@($now) | Where-Object { $_.ReadOnly -and $byKey.ContainsKey([string]$_.Key) -and -not $byKey[[string]$_.Key].ReadOnly })
    $out
}