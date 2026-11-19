# RESTORE-END-JOB-1: the delete a restore that resumes may have done already.
#
# OLD-REBUILD-RESTORE-READERS-1: this file held the refusal of a restore that
# an earlier version would have done by a rebuild. No flow of this version
# rebuilds a machine, and nothing is public before 1.0, so no record holds
# such a machine; the refusal is gone, and the file is named for what it
# keeps.
function Remove-VmfDiskForResume {
    <#
    .SYNOPSIS
        RESTORE-END-JOB-1: a delete that a stopped job may have done already.
        The disk is read by its resource id first: gone is done; made from
        -NotFrom (the copy) is the disk made under the name, which is never
        deleted; attached to anything is refused. Otherwise it is deleted.
    .OUTPUTS
        $true when it deleted the disk, $false when there was nothing to do.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowEmptyString()][string]$NotFrom = '',
        # The name of the delete in the run's log: the page has words for each.
        [Parameter()][ValidateSet('restore:removeOriginal', 'restore:removeTemp')][string]$RemoveOp = 'restore:removeOriginal'
    )
    $disk = Invoke-VmfAzOperation -Name 'restore:readDataDisk' -RunPath $RunPath -VmId $VmId -Operation { Get-VmfManagedDiskAttachment -DiskId $DiskId }
    if (-not $disk.Exists) { return $false }
    if ($NotFrom -and [string]$disk.SourceResourceId -ieq $NotFrom) { return $false }
    if ([string]$disk.ManagedBy) { throw "The disk '$DiskName' is attached to '$($disk.ManagedBy)', so the product does not delete it." }
    Invoke-VmfAzOperation -Name $RemoveOp -RunPath $RunPath -VmId $VmId -Operation {
        Remove-VmfManagedDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
    } | Out-Null
    $true
}
