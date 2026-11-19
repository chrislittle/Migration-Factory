function Get-VmfDiskArchitecture {
    <#
    .SYNOPSIS
        Classify a VM size into its disk architecture category:
        scsi-temp | nvme-temp | diskless.
    .DESCRIPTION
        Pure logic, no Azure calls (SKU data is passed in). Rules, in order:

          MaxResourceVolumeMB > 0            -> scsi-temp   (API is authoritative: covers
                                                             older sizes like B2ms, D2s_v3
                                                             that predate the 'd' naming)
          MaxResourceVolumeMB = 0, name 'd'  -> nvme-temp   (v6/v7 report 0 because the
                                                             local disk arrives raw)
          MaxResourceVolumeMB = 0, no 'd'    -> diskless

        The 'd' capability letter is parsed from the size name pattern
        Standard_<FAMILY><digits><letters>_v<N>; it is ONLY used to split
        nvme-temp from diskless when the API value is 0 (or unknown).

        A Windows cross-category move is the in-place upgrade (Preview), or no
        move for a shape nobody measured (REBUILD-REMOVE-PLAN-1; it was Path B,
        the rebuild, until 2026-11-07); Linux always resizes. That decision
        lives in the path selector, not here.
    .PARAMETER SizeName
        VM size name, e.g. Standard_E8bds_v5.
    .PARAMETER MaxResourceVolumeMB
        The SKU's MaxResourceVolumeMB capability. Pass $null when the SKU is
        unknown (name-based detection only).
    .OUTPUTS
        [string] 'scsi-temp' | 'nvme-temp' | 'diskless'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SizeName,
        [Parameter()][AllowNull()][Nullable[int64]]$MaxResourceVolumeMB
    )

    $apiHasDisk = ($null -ne $MaxResourceVolumeMB -and $MaxResourceVolumeMB -gt 0)

    $nameHasDisk = $false
    $version = $null
    # Size grammar: Standard_<Family><vcpus>[-<constrained>]<capability letters>_v<N>
    # e.g. Standard_E8ads_v7, Standard_E8-4ds_v5 (constrained vCPU inserts -N before the letters)
    if ($SizeName -match '_[A-Za-z]+\d+(?:-\d+)?([a-z]*)_[vV](\d+)') {
        $nameHasDisk = ($Matches[1] -like '*d*')
        $version = [int]$Matches[2]
    }

    if ($apiHasDisk) { return 'scsi-temp' }
    # GEN-V5-1: with no catalog reading, a 'd' name at v5 or older is a SCSI
    # temporary disk - v5 has no NVMe at all. Only v6 and v7 put it on NVMe.
    # A reading of 0 is the catalog's own word and still means NVMe.
    if ($nameHasDisk -and $null -eq $MaxResourceVolumeMB -and $null -ne $version -and $version -le 5) { return 'scsi-temp' }
    if ($nameHasDisk) { return 'nvme-temp' }
    'diskless'
}
