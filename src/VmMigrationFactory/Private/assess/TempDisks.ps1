function Get-VmfTempDiskCount {
    <#
    .SYNOPSIS
        TEMPPOOL-1: how many LOCAL TEMPORARY disks a VM size has.
    .DESCRIPTION
        A question on the guest script: why pool the NVMe temporary disks at
        all? A pool is not required, and many customers do not use one.

        Pooling stayed - the temp disks arrive RAW on every start and the pool is
        rebuilt by a boot task, so there is nothing for a customer to manage or be
        confused by. What was missing is the INFORMATION: a v4 machine has one
        temporary disk, its v6 target may have four or six, and a v3 machine
        moving to a non-'d' v6 size loses its temporary disk entirely. An
        operator should see that before running anything, not discover it after.

        The count is arithmetic on capabilities Azure publishes, not a guess from
        the size name (SKU-1: stop inferring architecture from names):

          MaxResourceVolumeMB > 0   -> 1   the single SCSI temporary disk of v3/v4/v5
          NvmeDiskSizeInMiB / NvmeSizePerDiskInMiB   the v6/v7 local NVMe count
          neither, and no 'd'       -> 0   genuinely diskless

        UNKNOWN IS NOT ZERO. A size missing from the catalog, or an NVMe size
        whose per-disk capability is absent, returns $null - "cannot tell". Zero
        would read as "this machine has no temporary disk", which for a `d` size
        is a claim the data does not support, and it is the claim that would send
        an operator into a migration believing nothing changes.
    .PARAMETER SkuEntry
        The size's entry from the SKU catalog, or $null when it is not in it.
    .PARAMETER SizeName
        The size name, used ONLY to tell a genuinely diskless size from one whose
        capabilities are missing - never to infer a count.
    .OUTPUTS
        [Nullable[int]] - the number of local temporary disks, or $null when the
        catalog cannot answer.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][AllowNull()][string]$SizeName
    )

    $cap = {
        param($name)
        if (-not $SkuEntry) { return $null }
        $c = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $c) { return $null }
        $v = $null
        # A capability value is a string on the wire. Anything unparseable is
        # unknown, never zero.
        if ([int64]::TryParse([string]$c.Value, [ref]$v)) { return $v }
        $null
    }

    if (-not $SkuEntry) { return $null }

    $maxResourceMb = & $cap 'MaxResourceVolumeMB'
    $nvmeTotalMiB  = & $cap 'NvmeDiskSizeInMiB'
    $nvmePerMiB    = & $cap 'NvmeSizePerDiskInMiB'

    # A SCSI temporary disk is a single disk, whatever its size.
    if ($null -ne $maxResourceMb -and $maxResourceMb -gt 0) { return [int]1 }

    if ($null -ne $nvmeTotalMiB -and $nvmeTotalMiB -gt 0) {
        if ($null -eq $nvmePerMiB -or $nvmePerMiB -le 0) { return $null }
        return [int][math]::Floor($nvmeTotalMiB / $nvmePerMiB)
    }

    # Nothing reported. That is a real zero only when the size does not claim a
    # local disk in the first place, and the question "does this name claim one"
    # is ALREADY ANSWERED by Get-VmfDiskArchitecture. Asking it rather than
    # writing a second 'd'-suffix regex here: two rules for one question is how
    # they drift, and this one has a constrained-vCPU case (Standard_E8-4ds_v5)
    # that a fresh regex gets wrong.
    if (-not $SizeName) { return $null }
    # GEN-V5-1: 'anything but diskless' - a v5 d name reads as scsi-temp now.
    if ((Get-VmfDiskArchitecture -SizeName $SizeName -MaxResourceVolumeMB $null) -ne 'diskless') {
        return $null   # claims a local disk, but the catalog did not size it
    }
    [int]0
}
