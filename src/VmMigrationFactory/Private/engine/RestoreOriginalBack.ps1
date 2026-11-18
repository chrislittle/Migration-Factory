# RESTORE-ORIGINAL-DELETE-RESTART-1 (decided 2026-11-11, option A).
#
# Restore this machine with the original disk names puts the machine on a
# temporary OS disk made from the safety copy, then deletes the original OS
# disk to free its name. The lock check before the stop can pass and Azure can
# still refuse that delete (a lock added during the restore, or another
# refusal). The restore then started the machine on the temporary disk - the
# moment of the copy - with the data disks of now: disks from two moments.
#
# Now the restore goes back instead. The original OS disk is still there,
# because Azure did not delete it, and no data disk is touched before that
# delete. So the original OS disk goes back on the machine, the machine starts
# as it was before the restore (and returns to the power state the restore
# found), the temporary disks made for this restore are deleted, and the
# record says the restore did not happen. Each step saves its checkpoint
# (originalKept, originalBack, originalStarted - rule 4), so a job that stops
# part way goes on from there and never goes on to make the disk under the
# name. The machine is never started on the temporary disk.

function Invoke-VmfRestoreOriginalBack {
    <#
    .SYNOPSIS
        Put the original OS disk back on a machine whose restore could not
        delete it, start the machine as it was, delete the temporary disks made
        for the restore, and say that the restore did not happen.
    .DESCRIPTION
        The caller saved the checkpoint originalKept with Azure's words. Each
        step here is safe to do again: the swap puts on the disk the machine
        may already have, a start of a running machine changes nothing, and
        each temporary disk is read before it is deleted (gone is done).
        A lost hold of the machine goes up at once: another job has it.
    .OUTPUTS
        @{ Words; Stopped } - the words that end the restore (also written as
        its fail line), and whether the machine is left stopped. The caller
        throws the words; nothing after it may start the machine.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        # The OS disk the machine had before the restore: id and name.
        [Parameter(Mandatory)]$Original,
        # Azure's words for the refused delete.
        [Parameter(Mandatory)][string]$Why,
        [Parameter(Mandatory)][string]$TempName,
        [Parameter(Mandatory)][string]$TempId,
        # Each temporary data disk made for this restore: @{ name; id }. The
        # rollback disks before the move are not in it: they are
        # kept, unused, for the next put-back.
        [Parameter()][AllowEmptyCollection()][object[]]$TempDataDisks = @(),
        [Parameter()][AllowNull()]$JobToken,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$PowerAtStart = ''
    )
    $past = { param($phase) $null -ne $JobToken -and (Test-VmfPutBackJobPast -Job $JobToken.Job -Phase $phase) }
    $lostHold = { param($err) [string]$err.Exception.Message -match 'abandon this VM' }
    $azureWords = { param($text) ([string]$text).TrimEnd('.') + '.' }
    $origName = [string]$Original.name
    $refused = "Azure refused to delete the OS disk '$origName': $(& $azureWords $Why)"
    # The temporary disks made for this restore that are not on the machine.
    # Each is read first, so a resume never deletes twice. A disk Azure does
    # not delete is said with the temporary disk warning's own words.
    $deleteTemps = {
        param([object[]]$Disks)
        $said = [System.Collections.Generic.List[string]]::new()
        foreach ($t in @($Disks | Where-Object { $_ -and [string]$_.name -and [string]$_.id })) {
            try {
                $null = Remove-VmfDiskForResume -RunPath $RunPath -VmId $VmId -DiskId ([string]$t.id) -ResourceGroupName $ResourceGroupName -DiskName ([string]$t.name) -RemoveOp 'restore:removeTemp'
                # MADE-DISK-RECORD-1: gone, so no restore names it again.
                Set-VmfMadeDiskMark -RunPath $RunPath -VmId $VmId -DiskIds @([string]$t.id) -Field 'deletedUtc'
            }
            catch {
                if (& $lostHold $_) { throw }
                $tempWord = "The temporary disk '$($t.name)' is not attached and was not deleted: $(([string]$_.Exception.Message).TrimEnd('.')). Delete it when you are sure."
                Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome warn -VmId $VmId -Detail $tempWord
                $said.Add($tempWord)
            }
        }
        @($said | ForEach-Object { " $_" }) -join ''
    }

    # 1. The original OS disk back on the machine, still stopped. Refused: the
    # machine stays stopped on the temporary disk - never started there.
    if (-not (& $past 'originalBack')) {
        try {
            Invoke-VmfAzOperation -Name 'restore:swapDiskBack' -RunPath $RunPath -VmId $VmId -Operation {
                Set-VmfVmOsDisk -ResourceGroupName $ResourceGroupName -Name $VmName -DiskId ([string]$Original.id) -DiskName $origName
            } | Out-Null
        }
        catch {
            if (& $lostHold $_) { throw }
            $words = "The restore did not happen. $refused Azure also refused to put the OS disk '$origName' back: $(& $azureWords $_.Exception.Message) The machine is stopped on the temporary disk '$TempName'. The data disks are as before. Attach the OS disk '$origName' to the machine before you start it."
            # The machine is on the temporary OS disk; the temporary data disks
            # are on nothing.
            $words += (& $deleteTemps @($TempDataDisks))
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $words
            return @{ Words = $words; Stopped = $true }
        }
        Save-VmfPutBackJobStep -Token $JobToken -Phase 'originalBack'
    }
    $words = "The restore did not happen: $refused The machine has its OS disk '$origName' and its data disks again, as before the restore."

    # 2. Started as it was, then back to the power state the restore found.
    $startWords = ''
    if (-not (& $past 'originalStarted')) {
        try {
            Invoke-VmfAzOperation -Name 'restore:recoverStart' -RunPath $RunPath -VmId $VmId -Operation {
                Start-VmfVm -ResourceGroupName $ResourceGroupName -Name $VmName
            } | Out-Null
            Save-VmfPutBackJobStep -Token $JobToken -Phase 'originalStarted'
        }
        catch {
            if (& $lostHold $_) { throw }
            $startWords = " Azure did not start the machine, so it is not running and needs attention: $(& $azureWords $_.Exception.Message)"
        }
    }
    $powerWords = ''
    if (-not $startWords) {
        $back = Invoke-VmfJobPowerReturn -RunPath $RunPath -VmId $VmId -Step 'restore' -Power $PowerAtStart -Before 'the restore' -RecordRefusal
        if ($back -and [string]$back.Words) { $powerWords = " $($back.Words)" }
    }

    # 3. The temporary disks made for this restore: none is on the machine now.
    $tempWords = & $deleteTemps @(@([pscustomobject]@{ name = $TempName; id = $TempId }) + @($TempDataDisks))

    $words = "$words$startWords$tempWords$powerWords"
    Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $words
    @{ Words = $words; Stopped = [bool]$startWords }
}
