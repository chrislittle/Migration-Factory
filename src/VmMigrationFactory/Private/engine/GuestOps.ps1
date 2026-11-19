# Engine <-> guest bridge: runs manifest-verified guest scripts via RunCommand,
# parses under the vmf.guest/1 contract, and records an audit entry (script
# version + sha256 + result) in the VM's state document.

# PREP-ROLLBACK-1 (review F3): the scripts that CHANGE the guest. The one
# list - Test-VmfGuestChangedThisAttempt reads it to say whether this attempt
# changed the machine. Each of these gets its audit entry BEFORE the run
# command, as STARTED, and the same entry takes the real result after: an
# entry written only after the script returned said nothing about a script
# that changed the registry and then timed out, or a worker killed while it
# ran, and the next attempt's read-only check then found the machine READY
# and the stop called it untouched. A STARTED entry left behind means "may
# have changed".
# VOLUMES-ONLINE-V5-1: lvm-devices-task.sh, the start task of a move to v5 or
# Bsv2, is one of them.
$script:VmfGuestChangerScripts = @('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1',
    'nvme-fix.sh', 'temp-disk-setup.sh', 'kernel-update.sh', 'Install-ManaDriver.ps1', 'lvm-devices-task.sh')
$script:VmfGuestStartedResult = 'STARTED'

# RUNCMD-REPLAY-1, MEASURED 2026-10-11: after a machine went back to disks made
# from its first copy, Azure ran the machine's LAST Run Command again when it
# started - a script that changed the machine changed the restored disks too.
# When the last Run Command before the put-back only read the machine, nothing
# came back (the same day, through the installation). The extension the first
# fix removed is not listed on a stopped machine at all, so there was nothing
# to remove. The decision: every script that changes the machine is
# followed AT ONCE - machine still running, no restart between, so the Windows
# rule "prepare, then stop with no boot between" still holds - by a neutral
# script that reads only the machine name and the time. If Azure runs the last
# command again, it runs that one, which changes nothing.
#
# The scripts the engine runs that change the machine: the changing list above
# (PREP-ROLLBACK-1) and Repair-NvmeIoTimeout.ps1, which runs after the
# conversion and so is not part of "the preparation changed the guest". The
# lab's data seeds (Set-DataDiskSeed.ps1, data-disk-seed.sh) are not here: the
# engine never runs them, and a drill runs them before the move, so the
# product's own read-only checks always run after them.
#
# CLUSTER-DETECT-1: and the cluster check at Checking, which only reads. The
# design for that check says the neutral script runs after it, so
# the last Run Command before the safety copies is always the neutral one.
#
# VOLUMES-ONLINE-1: and lvm-devices-refresh.sh, which can write the LVM devices
# file after a rollback or a restore. It is not in the changing list above: it
# runs after the put-back, so it says nothing about what the preparation of
# this attempt changed.
#
# VOLUMES-ONLINE-WINDOWS-1: and Set-DataDisksOnline.ps1, which can bring a
# data disk online after a start on new disks - not a preparation script
# either, for the same reason.
# VF-UNMANAGED-CONFIG-1: and sriov-unmanaged-check.sh, which only reads and
# runs at Checking right after the cluster check, for the same reason.
$script:VmfGuestFollowUpScripts = @($script:VmfGuestChangerScripts + 'Repair-NvmeIoTimeout.ps1' + 'Test-ClusterNode.ps1' + 'cluster-node-check.sh' + 'lvm-devices-refresh.sh' + 'sriov-unmanaged-check.sh' + 'Set-DataDisksOnline.ps1')
$script:VmfGuestNeutralScripts = @{ windows = 'Get-NeutralMark.ps1'; linux = 'neutral-mark.sh' }

function Write-VmfGuestAuditEntry {
    <#
    .SYNOPSIS
        Add one audit entry, or replace the entry with the same evidenceRef -
        the STARTED entry of the same run. Returns nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)]$Entry
    )
    $state = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $state) { return }
    # NOTE: @() must wrap the WHOLE if-expression - assignment from an if
    # statement pipelines its output, collapsing a 1-element array to a
    # scalar PSObject (found by the P1-6 conversion drill: op_Addition).
    $existing = @(if ($state.PSObject.Properties['guestExecutions']) { $state.guestExecutions })
    $at = -1
    for ($i = 0; $i -lt $existing.Count; $i++) {
        if ($existing[$i] -and [string]$existing[$i].evidenceRef -eq [string]$Entry.evidenceRef) { $at = $i }
    }
    if ($at -ge 0) { $existing[$at] = $Entry; $all = $existing }
    else { $all = $existing + @($Entry) }
    $state | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @($all) -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $state
}

function Invoke-VmfGuestScriptOnVm {
    <#
    .SYNOPSIS
        Run one guest script on a VM and return the validated output document.
        Saves raw output as evidence and appends to the state doc's audit trail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    # ResourceGroupName/VmName are consumed inside the -Operation scriptblock via
    # dynamic scoping; the analyzer cannot see through that.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$RunPath,
        # VERIFY-FP-1 part 3: a run taken only to READ the machine, never
        # judged. Its audit entry says READING, so no page or record shows a
        # check this script would fail before the move as a failure.
        [Parameter()][switch]$AsReading,
        # VOLUMES-ONLINE-WINDOWS-1: named values the script takes as its
        # parameters (Run Command's own parameters). The script text stays the
        # one the manifest verifies.
        [Parameter()][hashtable]$Parameters
    )

    $asset = Get-VmfGuestScript -Name $ScriptName
    $runArgs = @{}
    if ($Parameters -and $Parameters.Count) { $runArgs.Parameter = $Parameters }
    $commandId = if ($asset.Os -eq 'windows') { 'RunPowerShellScript' } else { 'RunShellScript' }

    # The evidence name is chosen BEFORE the run: it is also the key of the
    # audit entry a changing script gets first (PREP-ROLLBACK-1, review F3).
    $evidenceName = 'runcmd-{0}-{1}.txt' -f ($ScriptName -replace '[^A-Za-z0-9.-]', '_'), `
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $newEntry = { param($result) [pscustomobject]@{
            script      = $asset.Name
            version     = $asset.Version
            sha256      = $asset.Sha256
            tsUtc       = (Get-Date).ToUniversalTime().ToString('o')
            result      = $result
            evidenceRef = "evidence/$evidenceName"
        } }
    if (-not $AsReading -and [string]$asset.Name -in $script:VmfGuestChangerScripts) {
        Write-VmfGuestAuditEntry -RunPath $RunPath -VmId $VmId -Entry (& $newEntry $script:VmfGuestStartedResult)
    }
    # RUNCMD-REPLAY-1: decided by the script, never by the caller - so no call
    # site can forget it.
    $followUp = [string]$asset.Name -in $script:VmfGuestFollowUpScripts
    $neutralArgs = @{ Os = [string]$asset.Os; ResourceGroupName = $ResourceGroupName; VmName = $VmName; VmId = $VmId; RunPath = $RunPath; After = [string]$asset.Name }

    try {
        $raw = Invoke-VmfAzOperation -Name "runcmd:$ScriptName" -RunPath $RunPath -VmId $VmId -Operation {
            Invoke-VmfRunCommand -ResourceGroupName $ResourceGroupName -Name $VmName `
                -CommandId $commandId -ScriptString $asset.Content @runArgs
        }

        Write-VmfStoreText -RunPath $RunPath -RelPath "evidence/$evidenceName" -Content $raw

        $doc = ConvertFrom-VmfGuestOutput -RawOutput $raw

        # Audit: exactly which prep logic touched this VM. For a changing script
        # this REPLACES its STARTED entry; a script that threw before here leaves
        # that entry as it is.
        Write-VmfGuestAuditEntry -RunPath $RunPath -VmId $VmId `
            -Entry (& $newEntry $(if ($AsReading) { 'READING' } else { $doc.result }))
    }
    catch {
        $failed = $_
        # A changing script that timed out or answered badly may still have
        # run, and Azure keeps it as the last command: the neutral script
        # still goes after it. A lost lease is another worker's machine now.
        if ($followUp -and $failed.Exception.Message -notmatch 'abandon this VM') {
            $null = Invoke-VmfNeutralGuestMark @neutralArgs -AfterFailure
        }
        throw $failed
    }

    if ($followUp) { $null = Invoke-VmfNeutralGuestMark @neutralArgs }
    return $doc
}

function Invoke-VmfNeutralGuestMark {
    <#
    .SYNOPSIS
        RUNCMD-REPLAY-1: run the neutral script - the machine name and the
        time, nothing else - straight after a script that changed the machine.
    .DESCRIPTION
        Tried twice. If both fail after a changing script that answered, the
        move goes on (after one that threw, its failure is thrown next): this script changes
        nothing, so the machine is exactly as the changing script left it, and
        stopping the move here would itself start the rollback - the put-back
        that could run the change again. The run history says the protection
        is missing, and why. A lost lease always stops the worker.
    .OUTPUTS
        The neutral script's output document, or $null when it did not run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Os,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$After,
        # The changing script threw: the move does NOT go on - its failure is
        # thrown next, and the stop or the rollback follows. Review finding:
        # the warning said "The move goes on" here too, and after a script
        # that answered BLOCKED, whose caller stops the move. So the words
        # after an answer say only that THIS does not stop it.
        [Parameter()][switch]$AfterFailure
    )
    $name = $script:VmfGuestNeutralScripts[$Os.ToLowerInvariant()]
    if (-not $name) { throw "No neutral guest script for the operating system '$Os'." }
    $why = $null
    foreach ($attempt in 1..2) {
        try {
            $mark = Invoke-VmfGuestScriptOnVm -ScriptName $name -ResourceGroupName $ResourceGroupName -VmName $VmName -VmId $VmId -RunPath $RunPath
            if ([string]$mark.result -eq 'READY') { return $mark }
            $why = "it answered $($mark.result)$(if ($mark.PSObject.Properties['error'] -and $mark.error) { ": $($mark.error)" })"
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $why = $_.Exception.Message
        }
    }
    # Its own step, which the run page shows as this sentence (SAYS_ITSELF):
    # under the label of the neutral run the sentence was only in the hover,
    # and the label said the protection was there.
    $first = if ($AfterFailure) { "$After did not finish and can have changed the machine, and the product could not run the read-only script $name twice ($why)." }
    else { "The product ran $After, then could not run the read-only script $name twice ($why). This alone does not stop the move." }
    Write-VmfStepLine -RunPath $RunPath -Step 'neutralMark' -Outcome warn -VmId $VmId `
        -Detail "$first If a rollback or a restore starts this machine on copied disks, Azure can run $After again on them."
    $null
}
