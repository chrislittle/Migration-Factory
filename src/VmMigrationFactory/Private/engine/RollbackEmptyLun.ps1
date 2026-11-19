# ROLLBACK-EMPTY-LUN-1: a LUN that the rollback's own data disk swap left with
# NO disk.
#
# A data disk is swapped in two updates (SWAP-2UPD-1, Set-VmfVmDataDisks):
# detach, then attach. When Azure failed between them, or the platform stopped
# the wave worker there, the rollback stopped the machine rollbackFailed with
# "Attach each disk to its LUN, then start the machine" - a step in Azure,
# which hard rule 12 does not allow. RESTORE-EMPTY-LUN-1 had already made the
# restore finish such a swap; the rollback had its own swap code.
#
# So the rollback now does what the restore does, with the same mechanism:
#   1. After a swap that threw, and before a resumed rollback swaps anything,
#      each LUN is read (Get-VmfRollbackLiveLuns).
#   2. A LUN on the disk made from its copy took. A LUN with no disk gets the
#      disk the record proves belongs there (Resolve-VmfEmptyDataLun -Kind
#      rollback: the disk exists, no machine holds it, Azure made it from the
#      copy), with the settings the capture holds. Refused, the disk the LUN
#      had goes back on it.
#   3. Every LUN that is not on its disk from the copy goes on swapPending: the
#      machine stays stopped, and Finish the rollback finishes it. The full
#      rollback rule: every disk back to its copy, or the machine never starts.

function Get-VmfRollbackLiveLuns {
    <#
    .SYNOPSIS
        Which disk is on each data disk LUN of the machine now, for the
        rollback. A read that fails is no answer.
    .OUTPUTS
        @{ Luns = @{ <lun> = @{ id; name } } or $null; Why = <why the read
        failed, or ''> }. A lost lease ('abandon this VM') is thrown.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context)
    try {
        $now = @(Invoke-VmfAzOperation -Name 'rollback:readDataDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                @(Get-VmfDataDiskInfo -ResourceGroupName $Context.Rg -Name $Context.VmName)
            })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{ Luns = $null; Why = ([string]$_.Exception.Message).TrimEnd('.') }
    }
    $map = @{}
    foreach ($d in @($now | Where-Object { $_ })) {
        $id = [string]$d.id
        $map[[int]$d.lun] = @{ id = $id; name = $(if ([string]$d.name) { [string]$d.name } else { ($id -split '/')[-1] }) }
    }
    @{ Luns = $map; Why = '' }
}

function Resolve-VmfRollbackSwapLuns {
    <#
    .SYNOPSIS
        Judge each LUN of one batch of the rollback's data disk swaps against
        what is on it now, and fill each LUN that has no disk.
    .DESCRIPTION
        Per swap, by the disk on its LUN (-Live, which this updates as Azure
        changes it):
          the disk made from its copy   Took.
          the disk it had               -Resumed: Todo, swapped as usual. After
                                        a swap that threw: Left, a refused swap
                                        with -Why.
          no disk                       Resolve-VmfEmptyDataLun -Kind rollback.
                                        Attached: Took. Refused, the disk it
                                        had back on it: Left, a refused swap.
                                        Not proven, or both refused: Left, with
                                        the LUN said as having no disk. An
                                        attach with no answer (Unknown): Left,
                                        and -Live says the LUN as not read.
          another disk                  Left: Finish the rollback refuses it
                                        before any change.
        -Cause says why the LUN has no disk, in the run's log.
    .OUTPUTS
        @{ Took = @(<swap>); Todo = @(<swap>); Left = @(New-VmfSwapLeftRow ...);
           Reason = <the words of the last LUN left> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Swaps,
        [Parameter(Mandatory)][hashtable]$Live,
        # LUN -> the id, and the name, of the disk the LUN had before the swap.
        [Parameter(Mandatory)][hashtable]$OnLun,
        [Parameter(Mandatory)][hashtable]$NameOn,
        [Parameter(Mandatory)][string]$Cause,
        [Parameter()][AllowEmptyString()][string]$Why = '',
        [Parameter()][switch]$Resumed
    )
    $took = [System.Collections.Generic.List[object]]::new()
    $todo = [System.Collections.Generic.List[object]]::new()
    $left = [System.Collections.Generic.List[object]]::new()
    $reason = $Why
    $say = { param($outcome, $detail) Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome $outcome -VmId $Context.VmId -Detail $detail }
    foreach ($s in @($Swaps | Where-Object { $_ })) {
        $lun = [int]$s.lun
        $old = [string]$OnLun[$lun]
        $oldName = [string]$NameOn[$lun]
        $on = $Live[$lun]
        $onId = if ($on) { [string]$on.id } else { '' }
        if ($onId -and $onId -ieq [string]$s.diskId) { $took.Add($s); continue }
        if ($onId -and $old -and $onId -ieq $old) {
            if ($Resumed) { $todo.Add($s) }
            else { $left.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId $old -Why $Why -Holds 'had')) }
            continue
        }
        if (-not $onId) {
            $fill = Resolve-VmfEmptyDataLun -Kind 'rollback' -Context $Context -VmName $Context.VmName -OpName 'rollback:swapDataDisks' -Lun $lun `
                -WantId ([string]$s.diskId) -WantName ([string]$s.diskName) -SnapshotId ([string](Get-VmfRecordField -Object $s -Name 'snapshotId')) `
                -HadId $old -HadName $oldName -Caching ([string](Get-VmfRecordField -Object $s -Name 'caching'))
            if ($fill.Outcome -eq 'want') {
                $Live[$lun] = @{ id = [string]$s.diskId; name = [string]$s.diskName }
                & $say 'info' "LUN $lun had no disk: $Cause. The disk '$($s.diskName)' made from its copy is on it now."
                $took.Add($s)
                continue
            }
            if ($fill.Outcome -eq 'fallback') {
                $Live[$lun] = @{ id = $old; name = $oldName }
                & $say 'warn' "LUN $lun had no disk: $Cause. Azure did not attach the disk '$($s.diskName)' made from its copy ($(([string]$fill.Reason).TrimEnd('.'))), so the disk '$oldName' that it had is back on it."
            }
            else {
                & $say 'warn' ([string]$fill.Why)
                # RESUME-ATTACH-UNKNOWN-WORDS-1: the attach stopped with an
                # error that is not a refusal, so which disk is on the LUN is
                # not known: said as not read (Format-VmfRollbackLeft), never
                # as no disk.
                if ($fill.Unknown) { $Live[$lun] = @{ unread = $true } }
            }
            $left.Add((Set-VmfEmptyLunRow -Row (New-VmfSwapLeftRow -Swap $s -OldDiskId $old -Why ([string]$fill.Why)) -Fill $fill))
            $reason = [string]$fill.Why
            continue
        }
        $holds = "LUN $lun holds the disk '$([string]$on.name)' now - not the disk it had, nor the disk '$($s.diskName)' made from its copy."
        & $say 'warn' $holds
        $left.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId $old -Why $(if ($Why) { "$($Why.TrimEnd('.')). $holds" } else { $holds }) -Holds 'other'))
        $reason = $holds
    }
    @{ Took = @($took); Todo = @($todo); Left = @($left); Reason = $reason }
}

function Format-VmfRollbackLeft {
    <#
    .SYNOPSIS
        Each data disk the rollback left, in words, by what is on its LUN now.
        Pure.
    .DESCRIPTION
        A LUN is said as what Azure reports (-Live), never as the disk it had
        when it holds something else: a LUN with no disk is said as no disk -
        with the sentence its row keeps when that row says so - and a LUN with
        another disk names that disk. With no read (-Live $null), every LUN is
        said as not read; so is a LUN whose entry says unread.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Swaps = @(),
        [Parameter()][AllowNull()][hashtable]$Live,
        [Parameter()][AllowEmptyString()][string]$AzureSaid = ''
    )
    $rows = @($Swaps | Where-Object { $_ } | Sort-Object { [int]$_.lun })
    if (-not $rows.Count) { return '' }
    $unread = @($rows | Where-Object { $null -eq $Live -or ($Live[[int]$_.lun] -and $Live[[int]$_.lun].unread) })
    $read = @($rows | Where-Object { $_ -notin $unread })
    $keeps = @($read | Where-Object { $on = $Live[[int]$_.lun]; $on -and [string]$_.oldDiskId -and [string]$on.id -ieq [string]$_.oldDiskId })
    $unfinishedWhy = { param($w) [string]$w -like "*$script:VmfSwapNeitherWords*" -or [string]$w -like 'The data disk swap did not finish*' }
    $refused = @($keeps | Where-Object { -not (& $unfinishedWhy $_.why) })
    $unfinished = @($keeps | Where-Object { & $unfinishedWhy $_.why })
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($unread.Count) {
        $parts.Add("The product did not read which disk is on these LUNs after the data disk swap: $(@($unread | ForEach-Object { "LUN $($_.lun), where the disk '$($_.diskName)' made from its copy waits to go on" }) -join '; ').")
    }
    if ($refused.Count) {
        $said = if ($AzureSaid) { $AzureSaid } else { [string]$refused[-1].why }
        $parts.Add("Azure did not swap these data disks back after $script:VmfSwapRefusedTries tries: $(Format-VmfSwapLeft -Swaps $refused). Azure said: $($said.TrimEnd('.')).")
    }
    if ($unfinished.Count) {
        $parts.Add("Azure did not finish the swap of these data disks: $(Format-VmfSwapLeft -Swaps $unfinished). Azure said: $(([string]$unfinished[-1].why).TrimEnd('.')).")
    }
    foreach ($r in @($read | Where-Object { $_ -notin $keeps })) {
        $lun = [int]$r.lun
        $on = $Live[$lun]
        $onId = if ($on) { [string]$on.id } else { '' }
        if (-not $onId) {
            $parts.Add($(if ([string]$r.why -like "LUN $lun has no disk*") { ([string]$r.why).TrimEnd('.') + '.' }
                         else { (Format-VmfSwapLeft -Swaps @($r) -EmptyLuns @($lun)) + '.' }))
        }
        elseif ([string]$r.diskId -and $onId -ieq [string]$r.diskId) { $parts.Add("LUN $lun has the disk '$($r.diskName)' made from its copy now.") }
        else { $parts.Add("LUN $lun holds the disk '$([string]$on.name)' now - not the disk it had, nor the disk '$($r.diskName)' made from its copy.") }
    }
    $parts -join ' '
}
