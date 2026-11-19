# azureops: VM lifecycle operations for the state machine (Path A).
# Same rules as AzureOps.ps1 - idempotent, mockable, ARM only through here.

function Invoke-VmfRunCommand {
    <#
    .SYNOPSIS
        Run a script inside a guest via Azure RunCommand; return joined stdout text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('RunPowerShellScript', 'RunShellScript')][string]$CommandId,
        [Parameter(Mandatory)][string]$ScriptString,
        # VOLUMES-ONLINE-WINDOWS-1: the script's parameters, as name and value.
        [Parameter()][hashtable]$Parameter
    )

    $more = @{}
    if ($Parameter -and $Parameter.Count) { $more.Parameter = $Parameter }
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $Name `
        -CommandId $CommandId -ScriptString $ScriptString -ErrorAction Stop @more
    if ($null -eq $result -or $null -eq $result.Value -or @($result.Value).Count -eq 0) {
        throw "RunCommand on '$Name' returned no result - verify the VM is running and permissions allow RunCommand."
    }
    $message = (@($result.Value) | ForEach-Object { $_.Message }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "RunCommand on '$Name' returned an empty result."
    }
    return $message
}

function Start-VmfVm {
    <#
    .SYNOPSIS
        Start a VM and poll until running. Idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$TimeoutSeconds = 360,
        [Parameter()][int]$PollIntervalSeconds = 15
    )

    if ((Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name) -eq 'PowerState/running') { return }
    # EVAL-LAB-1 / H1, FOUND BY THE LAB DRILL 2026-08-30. -NoWait is not a
    # micro-optimisation, it is the whole fix. Without it Start-AzVM BLOCKS
    # until Azure finishes, so all the waiting happened HERE, before the
    # poll loop below - and by the time the loop ran, the machine had
    # already reached the state and the very first iteration returned. The
    # heartbeat two lines down was never reached, not once, in a 44-second
    # operation. Measured: zero renewals.
    #
    # The EVAL-H1 unit test asserts the heartbeat is invoked IN THE LOOP,
    # and it is - the loop was simply not where the time went. Only a real
    # Azure wait could show that, which is exactly why EVAL-LAB-1 existed.
    # ROLLBACK-CAPACITY-1: with -NoWait, a start that Azure refuses after it
    # accepted the request (AllocationFailed: no capacity for the size) is
    # never thrown here - the poll waited its whole time and said only that
    # the machine did not reach running. So each poll also reads the failed
    # provisioning state of the instance view (Get-VmfVmStartFailure). Only a
    # failure dated from this request ends the wait: an older one is an
    # earlier try's, and a failure with no date is not known to be this one.
    # Either is still named when the wait ends.
    $issuedUtc = (Get-Date).ToUniversalTime()
    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -NoWait | Out-Null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPollError = $null
    $lastFailure = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        # EVAL-LAB-1: with -NoWait the machine is genuinely mid-transition when
        # this first polls, and Azure sometimes reports NO power-state code at
        # all - which Get-VmfPowerState correctly treats as fatal, because
        # everywhere ELSE an unreadable power state must not be guessed at.
        # Inside a poll that is waiting FOR a state, though, "cannot tell yet"
        # is simply "not yet": it is not being read as a yes or a no, and the
        # timeout below still ends it. Found by the drill - the first -NoWait
        # run threw "Could not determine power state" a second after issuing
        # the start.
        try { $state = Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $Name }
        catch { $state = $null; $lastPollError = $_.Exception.Message }
        if ($state -eq 'PowerState/running') { return }
        # ROLLBACK-CAPACITY-1: a read that fails is no answer; the wait goes on.
        $failed = $null
        try { $failed = Get-VmfVmStartFailure -ResourceGroupName $ResourceGroupName -Name $Name } catch { $failed = $null }
        if ($failed) {
            $lastFailure = $failed
            $at = $null
            if ($failed.Time -is [datetime]) { $at = $failed.Time.ToUniversalTime() }
            elseif ($failed.Time) {
                try { $at = [datetime]::Parse([string]$failed.Time, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') }
                catch { $at = $null }
            }
            if ($at -and $at -ge $issuedUtc) {
                throw "Azure did not start VM '$Name': $($failed.Code). $($failed.Message)"
            }
        }
        # EVAL-H1: renew the lease WHILE waiting. The wrapper renews before
        # each ARM operation, but a single call that polls for up to ten
        # minutes is ONE operation - so nothing renewed during the longest
        # waits the engine performs, and the watchdog reaped healthy workers
        # mid-conversion, handing a machine to a second worker while the first
        # was still inside the poll.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw ("VM '$Name' did not reach PowerState/running within ${TimeoutSeconds}s." +
           $(if ($lastPollError) { " Last power-state read said: $lastPollError" }) +
           $(if ($lastFailure) { " Azure reported this last failed provisioning state: $($lastFailure.Code). $($lastFailure.Message)" }))
}

function Get-VmfVmStartFailure {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1: the failed provisioning state of a VM's instance
        view - its code (ProvisioningState/failed/<Azure's error code>), its
        message and its time - or $null when the provisioning state did not
        fail.
    .DESCRIPTION
        Get-AzVM -Status, the read Get-VmfPowerState makes. Azure keeps a
        failed provisioning state until the next operation, so the caller
        compares its time with its own request.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status
    $row = @($status.Statuses) | Where-Object { $_ -and [string]$_.Code -like 'ProvisioningState/failed*' } | Select-Object -First 1
    if (-not $row) { return $null }
    [pscustomobject]@{ Code = [string]$row.Code; Message = [string]$row.Message; Time = $row.Time }
}

function Wait-VmfVmAgentReady {
    <#
    .SYNOPSIS
        Poll until the VM agent reports Ready (the strongest cheap boot-health signal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$TimeoutSeconds = 600,
        [Parameter()][int]$PollIntervalSeconds = 20
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $view = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status
        $agent = $view.VMAgent.Statuses | Select-Object -First 1
        if ($agent -and $agent.DisplayStatus -eq 'Ready') { return }
        # EVAL-H1: renew the lease WHILE waiting. The wrapper renews before
        # each ARM operation, but a single call that polls for up to ten
        # minutes is ONE operation - so nothing renewed during the longest
        # waits the engine performs, and the watchdog reaped healthy workers
        # mid-conversion, handing a machine to a second worker while the first
        # was still inside the poll.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "VM '$Name' agent did not report Ready within ${TimeoutSeconds}s - possible boot failure."
}

function Clear-VmfDiskPerfProperties {
    <#
    .SYNOPSIS
        DISK-2 guard: strip per-disk IOPS/throughput properties from a VM object
        before Update-AzVM. Ultra Disk and Premium SSD v2 data disks carry
        DiskIOPSReadWrite/DiskMBpsReadWrite values that ARM rejects in a VM PATCH
        payload with HTTP 409 PropertyChangeNotAllowed (documented on the MS
        scsi-to-nvme-migration page; hits SAP/database fleets).

        OLD-SKU-1C: and each disk's storage type. The machine's own record of
        a disk's type is a copy of the disk's; after the product changes a
        disk's type, or swaps in a disk made on another type, a copy sent
        back in a machine update either disagrees with the disk or asks Azure
        to change it again - one of the two type changes a disk has a day.
        An attached disk's type is the disk's to say, so no update sends one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Vm)

    foreach ($dd in @($Vm.StorageProfile.DataDisks)) {
        foreach ($prop in @('DiskIOPSReadWrite', 'DiskMBpsReadWrite')) {
            if ($dd.PSObject.Properties[$prop] -and $null -ne $dd.$prop) {
                $dd.$prop = $null
            }
        }
    }
    foreach ($disk in @(@($Vm.StorageProfile.OsDisk) + @($Vm.StorageProfile.DataDisks))) {
        if ($disk -and $disk.PSObject.Properties['ManagedDisk'] -and $disk.ManagedDisk -and
            $disk.ManagedDisk.PSObject.Properties['StorageAccountType'] -and $null -ne $disk.ManagedDisk.StorageAccountType) {
            $disk.ManagedDisk.StorageAccountType = $null
        }
    }
    return $Vm
}

function Set-VmfVmSizeAndController {
    <#
    .SYNOPSIS
        Path A core: set the VM's size and disk controller type via Update-AzVM.
        The VM must be deallocated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Size,
        # ROLLBACK-NULL-1: empty when the capture recorded no controller - Azure
        # reports one for Generation 2 machines only. Empty means "the original
        # was not NVMe": a machine on NVMe now goes back to SCSI, and anything
        # else is left as Azure has it (Azure refuses the setting on Gen1).
        [Parameter()][AllowNull()][AllowEmptyString()][ValidateSet('NVMe', 'SCSI', '')][string]$Controller
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $want = if ($Controller) { $Controller }
            elseif ([string]$vm.StorageProfile.DiskControllerType -eq 'NVMe') { 'SCSI' }
            else { $null }
    if ($vm.HardwareProfile.VmSize -eq $Size -and (-not $want -or $vm.StorageProfile.DiskControllerType -eq $want)) {
        return   # idempotent: already applied (resume path)
    }
    $vm.HardwareProfile.VmSize = $Size
    if ($want) { $vm.StorageProfile.DiskControllerType = $want }
    $vm = Clear-VmfDiskPerfProperties -Vm $vm
    $result = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm
    if ($result.StatusCode -ne 'OK') {
        throw "Update-AzVM for '$Name' returned status '$($result.StatusCode)'."
    }
}

function New-VmfOsDiskSnapshot {
    <#
    .SYNOPSIS
        Snapshot one managed disk (a safety copy). Idempotent per name. The
        name says OS disk; SAFETY-ALL-1 uses it for every data disk too - it
        copies whatever disk -OsDiskId names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$SnapshotName,
        [Parameter(Mandatory)][string]$OsDiskId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()]$Tags,
        # SAFETY-CMK-1: the encryption PRECHECK recorded for the disk. Microsoft:
        # "A disk and all of its associated incremental snapshots must have the
        # same disk encryption set." So the copy asks for the disk's own set,
        # and what Azure made is compared with it. Every capture records it
        # (Add-VmfDiskEncryptionFacts). Empty: not on record - the copy is
        # taken, and no disk is made from it (Get-VmfEncryptionNotOnRecordWords).
        [Parameter()][AllowNull()][AllowEmptyString()][string]$EncryptionType,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DiskEncryptionSetId
    )

    # MISSING-READ-2: only a NotFound is "no copy yet". A read Azure does not
    # answer throws: taking the copy again under the same name would write the
    # disk as it is NOW over a copy that may already be there.
    $existing = $null
    try { $existing = Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -ErrorAction Stop }
    catch {
        if (-not (Test-VmfAzNotFound -ErrorRecord $_)) { throw }
    }
    if ($existing) {
        # A resume after Azure made it: the same copy only with the same key.
        if ($EncryptionType) {
            $diff = Get-VmfEncryptionDifference -WantType $EncryptionType -WantSetId $DiskEncryptionSetId `
                -GotType ([string]$existing.Encryption.Type) -GotSetId ([string]$existing.Encryption.DiskEncryptionSetId)
            if ($diff) { throw "The safety copy '$SnapshotName' exists, and $diff. The product does not use it." }
        }
        return $existing.Id
    }

    # SAFETY-2: INCREMENTAL. Sequence C takes two snapshots per machine - the
    # pristine copy before guest prep and the clean copy before conversion -
    # and two FULL copies would double the storage bill for no restore
    # benefit: the first stores the used blocks, the second only what prep
    # changed. A disk can be created from any incremental snapshot
    # independently; they are not a chain that has to be replayed.
    # Constraints that come with it: incremental snapshots are always stored
    # on Standard HDD, and must live in the same subscription and region as
    # the source disk.
    $configArgs = @{ SourceUri = $OsDiskId; Location = $Location; CreateOption = 'Copy'; Incremental = $true }
    if ($EncryptionType) { $configArgs.EncryptionType = $EncryptionType }
    if ($DiskEncryptionSetId) { $configArgs.DiskEncryptionSetId = $DiskEncryptionSetId }
    $config = New-AzSnapshotConfig @configArgs
    # FIND-COPY-1: a safety copy has to say what it is, on ITSELF.
    #
    # These copies live in the resource group of the machine they came from,
    # not in this product's. Removing the product leaves them there, and takes
    # away the only two things that knew about them: the run store, which holds
    # every machine's retention, and the daily pass that acts on it.
    #
    # The lock name marks them today, which is real but thin - it is on the
    # LOCK, so removing the lock makes the snapshot anonymous, and the resource
    # name carries the run id only until a long machine name pushes it past 75
    # characters. Tags are on the resource, survive both, and are what
    # `az resource list --tag` searches.
    $tagTable = ConvertTo-VmfTagTable -Tags $Tags
    if ($tagTable.Count -gt 0) { $config.Tags = $tagTable }

    # A TAG MUST NEVER COST A SAFETY COPY. A customer policy can allow only
    # certain tags, so the product must be able to skip a tag it cannot set.
    #
    # The direction of the risk is what makes it serious: this
    # snapshot is the rollback for a machine that is about to be changed. A
    # customer policy that denies a tag name would turn a label into a failed
    # migration at the one step whose whole purpose is safety.
    #
    # So the tags are attempted, and a refusal costs the LABEL, never the COPY.
    # A failure that is not about the tags fails again on the retry and throws
    # from there, so nothing real is swallowed - it surfaces one attempt later.
    $snap = $null
    if ($tagTable.Count -gt 0) {
        try { $snap = New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Snapshot $config }
        catch {
            Write-Warning ("The safety copy '$SnapshotName' was refused with its tags, so it is being taken without them. " +
                           "It will not be found by 'az resource list --tag vmfSafetyCopy=true'; its lock still names it. " +
                           "Azure said: $($_.Exception.Message)")
            $config.Tags = $null
            $tagTable = @{}
        }
    }
    if (-not $snap) { $snap = New-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Snapshot $config }
    if (-not $snap.Id) { throw "Snapshot '$SnapshotName' creation returned no id." }
    # SAFETY-CMK-1: the response is what Azure stored. A copy on another key
    # than its disk is not the rollback the record promises.
    if ($EncryptionType) {
        $diff = Get-VmfEncryptionDifference -WantType $EncryptionType -WantSetId $DiskEncryptionSetId `
            -GotType ([string]$snap.Encryption.Type) -GotSetId ([string]$snap.Encryption.DiskEncryptionSetId)
        if ($diff) { throw "Azure made the safety copy '$SnapshotName', but $diff. The product does not use it." }
    }

    # POLICY-REVERT-1: READ BACK WHAT LANDED. A policy with the modify effect
    # strips or rewrites tags and reports success, exactly as one does to a
    # storage account's public network access. If that happened here the copy
    # is fine and the FIND COMMAND IS A LIE - it would answer "none" for a
    # subscription full of them. This is the response Azure returned, not a
    # hopeful assumption, and it costs no extra call.
    if ($tagTable.Count -gt 0) {
        $landed = ConvertTo-VmfTagTable -Tags $snap.Tags
        if (-not $landed.ContainsKey('vmfSafetyCopy')) {
            Write-Warning ("The safety copy '$SnapshotName' was created but Azure did not keep its tags - a policy in " +
                           "this subscription removes them. It will not be found by 'az resource list --tag " +
                           "vmfSafetyCopy=true'; its lock still names it.")
        }
    }
    return $snap.Id
}

function Get-VmfVmConfig {
    <#
    .SYNOPSIS
        One machine's configuration, as Azure has it now.
    .DESCRIPTION
        BOUNDARY-2. Five bare Get-AzVM calls sat in the state machine, reading
        the live machine to compare it with what was captured before the move.
        Hard rule 3 puts every ARM call here, and the reason is not tidiness:
        outside this folder there is no seam for a test to replace, so those
        comparisons could only be tested by mocking an AZURE cmdlet - a test
        that breaks when the SDK moves and cannot say which of our reads it
        meant.

        Thin on purpose. The caller keeps its own Invoke-VmfAzOperation wrapper,
        because that is where the run path and the machine id are known and
        where the retry and the heartbeat belong.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][switch]$AllowMissing
    )
    # REBUILD-PROPS-1: -UserData, or Azure leaves user data out of the answer
    # and a machine that has it reads the same as one that does not.
    if ($AllowMissing) {
        # Rollback asks whether the shell is still there at all, so "gone" is
        # an answer rather than a failure. MISSING-READ-1: only a NotFound is
        # "gone". A read that fails throws, or the rollback would rebuild with
        # New-AzVM over a definition it could not see (an earlier version's rebuild).
        try { Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -UserData -ErrorAction Stop }
        catch {
            if (Test-VmfAzNotFound -ErrorRecord $_) { return $null }
            throw
        }
    }
    else {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -UserData
    }
}

function Get-VmfNetworkInterface {
    <#
    .SYNOPSIS
        One network interface, as Azure has it now.
    .DESCRIPTION
        BOUNDARY-2. Read to answer one question: does this interface really
        carry accelerated networking? NIC-1 measured why that must be read
        rather than assumed - a v4 machine's accelerated NIC is Mellanox, and
        MANA only appears once it is on Boost hardware.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    Get-AzNetworkInterface -Name $Name -ResourceGroupName $ResourceGroupName
}

function Get-VmfOsDiskInfo {
    <#
    .SYNOPSIS
        RESTORE-1: the machine's current OS disk as facts - name, id, resource
        group, location, sku, size. Needed before a restore so the identity of
        what is being replaced is recorded, not guessed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    if (-not $vm) { throw "VM '$Name' not found in '$ResourceGroupName'." }
    # ID-ADDRESS-1: the disk is found through the ID the machine records for
    # it, never by its NAME beside the machine. Azure allows the OS disk in
    # another resource group, and a same-named disk in the machine's resource
    # group is somebody else's - a restore that keeps the name DELETES the
    # disk this returns.
    $diskId = [string]$vm.StorageProfile.OsDisk.ManagedDisk.Id
    if (-not $diskId) { throw "VM '$Name' has no managed disk ID for its OS disk, so the disk cannot be found by its ID." }
    $diskSub = Get-VmfSubscriptionId -ResourceId $diskId
    $vmSub = Get-VmfSubscriptionId -ResourceId ([string]$vm.Id)
    if (-not $diskSub -or -not $vmSub -or $diskSub -ne $vmSub) {
        throw "The OS disk ID of VM '$Name' ($diskId) is not in the subscription of the machine."
    }
    $diskRg = Get-VmfResourceGroupName -ResourceId $diskId
    $osDiskName = ($diskId -split '/')[-1]
    $disk = Get-AzDisk -ResourceGroupName $diskRg -DiskName $osDiskName
    # The name as the disk spells it: an ID can carry another case, and a
    # restore that keeps the name makes the disk again under this one.
    if ($disk -and [string]$disk.Name) { $osDiskName = [string]$disk.Name }
    [pscustomobject]@{
        name          = $osDiskName
        id            = [string]$disk.Id
        resourceGroup = $diskRg
        location      = [string]$disk.Location
        skuName       = [string]$disk.Sku.Name
        sizeGB        = [int]$disk.DiskSizeGB
        # ROLLBACK-ORDER-1: the controller the machine has NOW, so a restore
        # can make the disk it swaps in allow it. A machine created before the
        # property existed reports nothing, and Azure's default then is SCSI.
        controller    = $(if ([string]$vm.StorageProfile.DiskControllerType) { [string]$vm.StorageProfile.DiskControllerType } else { 'SCSI' })
    }
}

function Get-VmfBoundedDiskName {
    <#
    .SYNOPSIS
        RESTORE-1: build a derived disk name that Azure will actually accept.
        Managed disk names cap at 80 characters, and Azure rejects the whole
        request with a bare "disk.name is invalid" if you exceed it. Found by
        the restore drill: restoring an already-restored disk stacked suffixes
        past the limit. The BASE is truncated, never the suffix, so the
        suffix stays meaningful and unique.

        RESTORE-NAME-STACK-1: every product suffix at the end of the base comes
        off first (Remove-VmfDiskNameSuffix). Before, a second rollback cut the
        base to make room and kept the old suffix in part:
        '<name>-asitwas-20-asitwas-202609301614'. Pure: no Azure call, and
        every caller that derives a disk name from a disk name uses it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter()][int]$MaxLength = 80
    )

    $room = $MaxLength - $Suffix.Length
    if ($room -lt 1) { throw "Disk-name suffix '$Suffix' leaves no room within $MaxLength characters." }
    $base = Remove-VmfDiskNameSuffix -Name $BaseName -MaxLength $MaxLength
    if ($base.Length -gt $room) { $base = $base.Substring(0, $room) }
    # a truncated base must not leave a doubled or trailing separator
    $base = $base.TrimEnd('-', '.', '_')
    # SNAPSHOT-NAME-END-1: the shared rule checks the whole name before Azure does.
    return (ConvertTo-VmfAzureName -Name $base -Suffix $Suffix -MaxLength $MaxLength -Rule 'disk')
}

function Test-VmfDiskNameSuffixPart {
    <#
    .SYNOPSIS
        RESTORE-NAME-STACK-1: is this end of a name one piece of a product
        suffix '[-d<lun>]-<word>-<12-digit time>' that the old cut left -
        '-asitwas-20', '-asitwa', or the '-d0' before them? A part like
        '-d0-asitwa' is two pieces, and Remove-VmfDiskNameSuffix takes them
        off one at a time.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tail)

    if (-not $Tail.StartsWith('-')) { return $false }
    $rest = $Tail.Substring(1)
    if ($rest -eq '' -or $rest -match '^d\d*$') { return $true }
    foreach ($word in 'asitwas', 'restored', 'rtmp', 'rec') {
        if ($word.StartsWith($rest, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($rest -match "^$word-\d{0,11}$") { return $true }
    }
    $false
}

function Remove-VmfDiskNameSuffix {
    <#
    .SYNOPSIS
        RESTORE-NAME-STACK-1: the name without the suffixes the product put on
        its end - '-asitwas-', '-restored-', '-rtmp-' and '-rec-' with a
        12-digit time, each with or without '-d<lun>' before it, and the old
        'rec-<time>' with no separator. Repeats all come off. Text elsewhere
        in the name is the customer's and stays.

        A PART suffix ('-asitwas-20') comes off only after a complete one did,
        and only when the name is at the length limit: the old cut is the only
        thing that made one, and it made the name that long. So 'disk-a' and
        'vm1-d1' in a short name are never read as a cut suffix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$MaxLength = 80
    )

    $complete = '(?:(?:-d\d+)?-(?:asitwas|restored|rtmp|rec)|rec)-\d{12}$'
    # The old cut removed a trailing separator, so a cut name can be one short.
    $wasCut = $Name.Length -ge ($MaxLength - 1)
    $rest = $Name
    $strippedAny = $false
    while ($rest) {
        $m = [regex]::Match($rest, $complete, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $rest = $rest.Substring(0, $m.Index)
            $strippedAny = $true
            continue
        }
        if (-not ($strippedAny -and $wasCut)) { break }
        # The longest end of the name that is one piece of a product suffix.
        $cutAt = -1
        for ($i = [Math]::Max(0, $rest.Length - 32); $i -lt $rest.Length; $i++) {
            if ($rest[$i] -eq '-' -and (Test-VmfDiskNameSuffixPart -Tail $rest.Substring($i))) { $cutAt = $i; break }
        }
        if ($cutAt -lt 0) { break }
        $rest = $rest.Substring(0, $cutAt)
    }
    $rest = $rest.TrimEnd('-', '.', '_')
    # A name that was nothing but a suffix keeps what it had.
    if (-not $rest) { return $Name }
    $rest
}

function New-VmfDiskFromSnapshot {
    <#
    .SYNOPSIS
        RESTORE-1: create a managed disk from a snapshot. Idempotent - an
        existing disk of that name is returned rather than duplicated.
        NOTE the identity consequence: this is a NEW resource with a NEW id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][string]$SkuName = 'Premium_LRS',
        # SAFETY-ALL-1: a machine in an availability zone takes only disks in
        # the same zone. The put-back used to make its disk with no zone.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        # SAFETY-ULTRA-1: a Premium SSD v2 or Ultra Disk is made with the IOPS
        # and throughput PRECHECK recorded for it. The sector size comes from
        # the copy (MEASURED 2026-10-10: 4096 and 512 both kept); the caller
        # reads the new disk back and compares every value.
        [Parameter()][AllowNull()][Nullable[long]]$DiskIopsReadWrite,
        [Parameter()][AllowNull()][Nullable[long]]$DiskMBpsReadWrite,
        # SAFETY-CMK-1: the encryption type and disk encryption set PRECHECK
        # recorded for the disk this one replaces. Microsoft's sample makes a
        # disk with a customer-managed key from a snapshot by naming the set,
        # and says the one that names none "creates a managed disk with
        # platform-managed keys". What Azure does with a copy that HAS a set
        # and a request that names none is not documented, so the set is
        # always named. Empty is never sent: the makers refuse a disk whose
        # encryption is not on record (Get-VmfEncryptionNotOnRecordWords).
        [Parameter()][AllowNull()][AllowEmptyString()][string]$EncryptionType,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DiskEncryptionSetId
    )

    # DISK-TYPE-DEALLOCATED-1: never a disk with no type. Azure refuses one
    # ("Required property 'name' not found in 'sku'"), and an empty type
    # given here means the record does not know the disk - so nothing is
    # asked of Azure. PRECHECK refuses such a machine before any change.
    if (-not $SkuName) { throw "The product does not make disk '$DiskName': no disk type is on record for it." }

    # MISSING-READ-1: only a NotFound is "no disk of that name". A read that
    # fails throws - it never makes a disk over one it could not see.
    $existing = $null
    try { $existing = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -ErrorAction Stop }
    catch { if (-not (Test-VmfAzNotFound -ErrorRecord $_)) { throw } }
    if ($existing) {
        # SAFETY-CMK-1: nor is a disk of that name on another key - the same
        # rule as the copy and the zone below.
        if ($EncryptionType) {
            $haveEnc = if ($existing.PSObject.Properties['Encryption']) { $existing.Encryption } else { $null }
            $diff = Get-VmfEncryptionDifference -WantType $EncryptionType -WantSetId $DiskEncryptionSetId `
                -GotType ([string]$(if ($haveEnc) { $haveEnc.Type })) -GotSetId ([string]$(if ($haveEnc) { $haveEnc.DiskEncryptionSetId }))
            if ($diff) { throw "Disk '$DiskName' exists, and $diff." }
        }
        # SAFETY-ALL-1: a disk of that name made from ANOTHER copy is not this
        # disk. Returning it would put one disk on two LUNs.
        $source = if ($existing.PSObject.Properties['CreationData'] -and $existing.CreationData) { [string]$existing.CreationData.SourceResourceId } else { '' }
        if ($source -and $source -ne $SnapshotId) {
            throw "Disk '$DiskName' exists and was made from '$source', not from '$SnapshotId'."
        }
        # ZONES-1: nor is a disk of that name in another zone - a zonal
        # machine refuses it at the swap, with the machine stopped.
        $haveZones = @(@($existing.Zones) | Where-Object { $_ })
        if ($Zone -and $SkuName -notlike '*_ZRS' -and $haveZones -notcontains $Zone) {
            throw "Disk '$DiskName' exists in zone '$($haveZones -join ',')', not in zone '$Zone', where the machine is."
        }
        return [string]$existing.Id
    }

    $configArgs = @{ Location = $Location; CreateOption = 'Copy'; SourceResourceId = $SnapshotId; SkuName = $SkuName }
    # A zone-redundant disk has no zone of its own, and any machine in the
    # region takes it; Azure refuses a zone on one.
    if ($Zone -and $SkuName -notlike '*_ZRS') { $configArgs.Zone = @($Zone) }
    if ($null -ne $DiskIopsReadWrite) { $configArgs.DiskIOPSReadWrite = [long]$DiskIopsReadWrite }
    if ($null -ne $DiskMBpsReadWrite) { $configArgs.DiskMBpsReadWrite = [long]$DiskMBpsReadWrite }
    if ($EncryptionType) { $configArgs.EncryptionType = $EncryptionType }
    if ($DiskEncryptionSetId) { $configArgs.DiskEncryptionSetId = $DiskEncryptionSetId }
    $config = New-AzDiskConfig @configArgs
    $disk = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $config
    if (-not $disk.Id) { throw "Disk '$DiskName' creation from snapshot returned no id." }
    return [string]$disk.Id
}

# SWAP-2UPD-1: the sentence every "neither" state carries. Invoke-VmfAzOperation
# never retries an error that holds it: a re-run would find an empty LUN and
# replace the message that names each disk with one that names none.
$script:VmfSwapNeitherWords = 'The data disks are neither swapped nor as they were.'

function Update-VmfVmWhileBusy {
    <#
    .SYNOPSIS
        One machine update, tried again (three tries in all) only while Azure
        says it is busy. Set-VmfVmDataDisks and Add-VmfVmDataDiskOnEmptyLun
        send their updates through it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)]$Vm
    )
    for ($try = 1; ; $try++) {
        try {
            # OLD-SKU-1C: one scrub before each update (DiskType.Tests.ps1).
            $vm = Clear-VmfDiskPerfProperties -Vm $vm
            Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null
            return
        }
        catch {
            $busy = $_.Exception.Message -match '(?i)\b(429|TooManyRequests|throttl|ServerTimeout|InternalServerError|ServiceUnavailable|timed? ?out)\b'
            if (-not $busy -or $try -ge 3) { throw }
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

function Add-VmfVmDataDiskOnEmptyLun {
    <#
    .SYNOPSIS
        RESTORE-EMPTY-LUN-1: attach one disk to a LUN of a stopped machine that
        has NO disk, then read the machine back.
    .DESCRIPTION
        A data disk is swapped in two updates (SWAP-2UPD-1, Set-VmfVmDataDisks):
        detach, then attach. A job that stops between them leaves the LUN with
        no disk. This is the second update on its own, for the caller that has
        proven which disk belongs there (Invoke-VmfEmptyLunAttach).

        It never replaces a disk: a LUN that holds another disk is refused
        before any update. A LUN that holds this disk already is done (a job
        that stopped after Azure attached it). The settings are the caller's -
        the ones the record holds for the LUN; a setting it does not give is
        not named, so Azure keeps its own default. Only the read back says
        whether the disk is on: never the answer to the update.
    .OUTPUTS
        @{ Applied = $true } when the disk is on the LUN. @{ Applied = $false;
        Reason } when it is not, and the LUN still has no disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowEmptyString()][string]$Caching = '',
        [Parameter()][AllowEmptyString()][string]$DeleteOption = '',
        [Parameter()][switch]$WriteAccelerator
    )
    $onLun = {
        param($machine)
        $slot = @($machine.StorageProfile.DataDisks) | Where-Object { [int]$_.Lun -eq $Lun } | Select-Object -First 1
        if ($slot -and $slot.ManagedDisk) { [string]$slot.ManagedDisk.Id } elseif ($slot) { [string]$slot.Name } else { '' }
    }
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $have = & $onLun $vm
    if ($have) {
        if ($have -ieq $DiskId) { return @{ Applied = $true } }
        throw "Machine '$Name' has the disk '$have' on LUN $Lun. The product attaches a disk only to a LUN that has no disk."
    }
    $refused = $null
    try {
        $attachArgs = @{ VM = $vm; Name = $DiskName; ManagedDiskId = $DiskId; Lun = $Lun; CreateOption = 'Attach' }
        if ($Caching) { $attachArgs.Caching = $Caching }
        if ($WriteAccelerator) { $attachArgs.WriteAccelerator = $true }
        if ($DeleteOption) { $attachArgs.DeleteOption = $DeleteOption }
        $vm = Add-AzVMDataDisk @attachArgs
        Update-VmfVmWhileBusy -ResourceGroupName $ResourceGroupName -Vm $vm
    }
    catch { $refused = $_.Exception.Message }
    $now = & $onLun (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name)
    if ($now -ieq $DiskId) { return @{ Applied = $true } }
    @{ Applied = $false; Reason = $(if ($refused) { $refused } else { 'Azure accepted the update and did not attach the disk' }) }
}

function Set-VmfVmDataDisks {
    <#
    .SYNOPSIS
        SAFETY-ALL-1: put other disks on a stopped machine's data-disk LUNs,
        then re-read and verify every swap took.
    .DESCRIPTION
        SWAP-2UPD-1, MEASURED on a lab machine 2026-09-30: Azure identifies a
        data disk by its LUN, so a disk cannot be swapped on a LUN in ONE
        update. Changing the LUN's disk is refused ("Changing property
        'dataDisk.managedDisk.id' is not allowed"), and so is removing it and
        adding another on the same LUN in one request ("Changing property
        'dataDisk.createOption' is not allowed"). The first version did it in
        one update, and every rollback's data-disk swap was refused in the
        first lab run.

        So it takes two updates: detach the old disks (by LUN), then attach the
        new ones on the same LUNs, with the same caching, write accelerator and
        delete option. Between them the machine has no disk on those LUNs - it
        is stopped, and nothing reads them. If Azure refuses the attach, the old
        disks go back on their LUNs in a third update. A detach Azure reported
        as failed but applied is carried on, not stopped. Each update is tried
        again, briefly, when Azure is only busy.
    .PARAMETER Swaps
        Each: @{ lun = <int>; diskId = <string>; diskName = <string> }.
    .OUTPUTS
        @{ Applied = $true } when every swap took. @{ Applied = $false; Reason }
        when NONE took and the old disks are on their LUNs. Throws, with
        $script:VmfSwapNeitherWords and each LUN's disk, when the machine is
        neither - and then a LUN may have NO disk: the caller must not start it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Swaps
    )
    $luns = @($Swaps | ForEach-Object { [int]$_.lun })
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $before = @{}
    foreach ($swap in $Swaps) {
        $slot = @($vm.StorageProfile.DataDisks) | Where-Object { [int]$_.Lun -eq [int]$swap.lun } | Select-Object -First 1
        if (-not $slot) { throw "Machine '$Name' has no data disk on LUN $($swap.lun) to put a copy back on." }
        $before[[int]$swap.lun] = [pscustomobject]@{
            Id = [string]$slot.ManagedDisk.Id; Name = [string]$slot.Name; Caching = [string]$slot.Caching
            WriteAccelerator = [bool]$slot.WriteAcceleratorEnabled; DeleteOption = [string]$slot.DeleteOption
        }
    }
    $attach = {
        param($target, $lun, $diskId, $diskName, $was, $caching)
        $attachArgs = @{ VM = $target; Name = $diskName; ManagedDiskId = $diskId; Lun = $lun; CreateOption = 'Attach' }
        # SAFETY-ULTRA-1: a swap may name its caching - None for Premium SSD v2
        # and Ultra Disk, which take no host caching.
        if ($caching) { $attachArgs.Caching = $caching }
        elseif ($was.Caching) { $attachArgs.Caching = $was.Caching }
        if ($was.WriteAccelerator) { $attachArgs.WriteAccelerator = $true }
        if ($was.DeleteOption) { $attachArgs.DeleteOption = $was.DeleteOption }
        Add-AzVMDataDisk @attachArgs
    }
    # One machine update, tried again only while Azure says it is busy.
    $send = { param($vm) Update-VmfVmWhileBusy -ResourceGroupName $ResourceGroupName -Vm $vm }
    $read = {
        $now = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
        $map = @{}
        foreach ($lun in $luns) {
            $d = @($now.StorageProfile.DataDisks) | Where-Object { [int]$_.Lun -eq $lun } | Select-Object -First 1
            $map[$lun] = if ($d) { [string]$d.ManagedDisk.Id } else { '' }
        }
        $map
    }
    $report = { param($map) ($luns | ForEach-Object { "LUN ${_}: $(if ($map[$_]) { "'$($map[$_])'" } else { 'NO DISK' })" }) -join ', ' }
    $oldDisks = ($luns | ForEach-Object { "LUN ${_}: '$($before[$_].Id)'" }) -join ', '
    $neither = {
        param($what, $map)
        "$script:VmfSwapNeitherWords $what ARM reports $(& $report $map). Before the swap: $oldDisks. Attach each old disk to its LUN before the machine starts."
    }

    # 1. Detach, by LUN. Refused: nothing changed.
    $detachError = $null
    try {
        foreach ($lun in $luns) {
            $slot = @($vm.StorageProfile.DataDisks) | Where-Object { [int]$_.Lun -eq $lun } | Select-Object -First 1
            [void]$vm.StorageProfile.DataDisks.Remove($slot)
        }
        & $send $vm
    }
    catch { $detachError = $_.Exception.Message }
    if ($detachError) {
        $now = & $read
        $stillOld = @($luns | Where-Object { $now[$_] -eq $before[$_].Id }).Count
        $empty = @($luns | Where-Object { -not $now[$_] }).Count
        if ($stillOld -eq $luns.Count) { return @{ Applied = $false; Reason = $detachError } }
        # Reported as failed, but it took: carry on to the attach.
        if ($empty -ne $luns.Count) { throw (& $neither "Detaching them failed part way: $detachError" $now) }
    }

    # 2. Attach the new disks on the same LUNs.
    $refused = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
        foreach ($swap in $Swaps) {
            # Member access reads a field and a hashtable key alike.
            $swapCaching = [string]$swap.caching
            $vm = & $attach $vm ([int]$swap.lun) ([string]$swap.diskId) ([string]$swap.diskName) $before[[int]$swap.lun] $swapCaching
        }
        & $send $vm
    }
    catch { $refused = $_.Exception.Message }

    $now = & $read
    $took = @($Swaps | Where-Object { $now[[int]$_.lun] -eq [string]$_.diskId }).Count
    if ($took -eq $luns.Count) { return @{ Applied = $true } }
    if ($took -gt 0) {
        throw (& $neither "The swap took on some LUNs and not others.$(if ($refused) { " The update failed: $refused" })" $now)
    }

    # 3. None took: put the old disks back, so the machine has what it had.
    $putBackError = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
        foreach ($lun in $luns) {
            if (-not $now[$lun]) { $vm = & $attach $vm $lun $before[$lun].Id $before[$lun].Name $before[$lun] }
        }
        & $send $vm
    }
    catch { $putBackError = $_.Exception.Message }
    $back = & $read
    if (@($luns | Where-Object { $back[$_] -eq $before[$_].Id }).Count -ne $luns.Count) {
        $why = if ($refused) { $refused } else { 'it accepted the update and did not attach them' }
        throw (& $neither "Azure refused the disks made from the copies ($why), and not every old disk is attached again$(if ($putBackError) { ": $putBackError" } else { '.' })" $back)
    }
    @{ Applied = $false; Reason = $(if ($refused) { $refused } else { 'Azure accepted the update and did not attach the disks' }) }
}



function Set-VmfVmOsDisk {
    <#
    .SYNOPSIS
        RESTORE-1: swap the machine's OS disk (it must be deallocated), then
        RE-READ from ARM and verify the swap actually took - the same
        verify-after-write discipline the detach path uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $vm.StorageProfile.OsDisk.ManagedDisk.Id = $DiskId
    $vm.StorageProfile.OsDisk.Name = $DiskName
    $vm = Clear-VmfDiskPerfProperties -Vm $vm
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null

    $after = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    if ([string]$after.StorageProfile.OsDisk.ManagedDisk.Id -ne $DiskId) {
        throw "OS disk swap on '$Name' did not take effect - ARM still reports '$($after.StorageProfile.OsDisk.ManagedDisk.Id)'."
    }
}

function Get-VmfLockScope {
    <#
    .SYNOPSIS
        EVAL-C2/M7: what does this lock actually cover?
    .DESCRIPTION
        A lock's OWN id always ends `/providers/Microsoft.Authorization/locks/
        <name>`, whatever it is placed on. Two functions here each wrote their
        own idea of scope against that id and each got it wrong in the opposite
        direction: the VM one dropped every RESOURCE-GROUP lock (so the LOCK-1
        gate was inert for the commonest enterprise placement, and the machine
        died past the point of no return), and the disk one treated every lock
        that was not a disk lock as blocking (so an operator mid-incident was
        sent to unlock somebody else's storage account).

        So there is now ONE answer to the question, and both ask it. Strip the
        lock's own suffix, then look at what is left.
    .OUTPUTS
        @{ Kind = 'group'|'resource'; ResourceType = <string|null>; ResourceName = <string|null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()][string]$LockResourceId)

    $id = [string]$LockResourceId
    # Everything before the lock's own /providers/Microsoft.Authorization/locks/...
    $scope = ($id -split '/providers/Microsoft\.Authorization/locks/', 2)[0]

    # <scope>/providers/<namespace>/<type>/<name> means the lock sits on a
    # resource; anything shorter is the group (or something we cannot parse,
    # which is treated as the group - unknown must never resolve towards
    # "nothing is locked").
    if ($scope -match '/providers/[^/]+/([^/]+)/([^/]+)$') {
        return @{ Kind = 'resource'; ResourceType = $Matches[1]; ResourceName = $Matches[2] }
    }
    @{ Kind = 'group'; ResourceType = $null; ResourceName = $null }
}

function Select-VmfCoveringLocks {
    <#
    .SYNOPSIS
        EVAL-C2: given the locks in a resource group, which ones cover THIS
        machine? Pure - no Azure call - so it can be tested with real lock
        shapes instead of source-text greps.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()]$Locks,
        [Parameter(Mandatory)][string]$VmName
    )
    $covering = foreach ($lock in @($Locks)) {
        if (-not $lock) { continue }
        $level = [string]$lock.Properties.level
        if ($level -notin @('CanNotDelete', 'ReadOnly')) { continue }
        $on = Get-VmfLockScope -LockResourceId ([string]$lock.ResourceId)
        if ($on.Kind -eq 'resource' -and
            -not ($on.ResourceType -eq 'virtualMachines' -and $on.ResourceName -eq $VmName)) { continue }
        [pscustomobject]@{
            name  = [string]$lock.Name
            level = $level
            scope = if ($on.Kind -eq 'resource') { 'this machine' } else { 'the resource group' }
        }
    }
    , @($covering)
}

function Select-VmfDeleteBlockingLocks {
    <#
    .SYNOPSIS
        EVAL-M7: given the locks in a resource group, which ones actually stop
        THIS disk being deleted? Pure, for the same reason as its sibling - and
        the two now share Get-VmfLockScope, so they cannot disagree again.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()]$Locks,
        [Parameter(Mandatory)][string]$DiskName
    )
    $blocking = foreach ($lock in @($Locks)) {
        if (-not $lock) { continue }
        $level = [string]$lock.Properties.level
        if ($level -notin @('CanNotDelete', 'ReadOnly')) { continue }
        $on = Get-VmfLockScope -LockResourceId ([string]$lock.ResourceId)
        if ($on.Kind -eq 'resource' -and
            -not ($on.ResourceType -eq 'disks' -and $on.ResourceName -eq $DiskName)) { continue }
        "$($lock.Name) ($level)"
    }
    , @($blocking)
}

function Get-VmfVmResourceLocks {
    <#
    .SYNOPSIS
        LOCK-1: every lock covering this VM - its own and its resource group's.
        Returns @{ name; level; scope } objects; the verdict is made elsewhere,
        because whether a lock matters depends on the migration path.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )

    # Locks inherit downward, so a group lock covers the machine as surely as
    # one placed on the machine itself. The DECISION lives in
    # Select-VmfCoveringLocks so it can be tested against real lock ids; this
    # function only fetches.
    # REBUILD-PROPS-1: a read that fails throws. It used to read as "no
    # locks", and a delete lock then stopped Path B inside the stopped window.
    $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    Select-VmfCoveringLocks -Locks $locks -VmName $Name
}

function Get-VmfDataDiskInfo {
    <#
    .SYNOPSIS
        RESTORE-ALL-1: the machine's data disks NOW, as facts - LUN, id, name,
        resource group and type - so a restore replaces the disk that is on
        each LUN, not the one the capture remembers.
    .DESCRIPTION
        ID-ADDRESS-1, as Get-VmfOsDiskInfo: each disk is found through the ID
        the machine records for it, never by its name beside the machine, and
        its name is the name the disk spells. A restore that keeps the names
        DELETES the disks this returns.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    if (-not $vm) { throw "VM '$Name' not found in '$ResourceGroupName'." }
    $vmSub = Get-VmfSubscriptionId -ResourceId ([string]$vm.Id)
    foreach ($slot in @($vm.StorageProfile.DataDisks | Where-Object { $_ })) {
        $diskId = if ($slot.ManagedDisk) { [string]$slot.ManagedDisk.Id } else { '' }
        # An unmanaged disk has no ID to restore by; the restore leaves it.
        if (-not $diskId) {
            [pscustomobject]@{ lun = [int]$slot.Lun; id = ''; name = [string]$slot.Name; resourceGroup = ''; skuName = '' }
            continue
        }
        $diskSub = Get-VmfSubscriptionId -ResourceId $diskId
        if (-not $diskSub -or -not $vmSub -or $diskSub -ne $vmSub) {
            throw "The data disk ID on LUN $($slot.Lun) of VM '$Name' ($diskId) is not in the subscription of the machine."
        }
        $diskRg = Get-VmfResourceGroupName -ResourceId $diskId
        $diskName = ($diskId -split '/')[-1]
        $disk = Get-AzDisk -ResourceGroupName $diskRg -DiskName $diskName
        [pscustomobject]@{
            lun           = [int]$slot.Lun
            id            = $(if ($disk -and [string]$disk.Id) { [string]$disk.Id } else { $diskId })
            name          = $(if ($disk -and [string]$disk.Name) { [string]$disk.Name } else { $diskName })
            resourceGroup = $diskRg
            skuName       = $(if ($disk -and $disk.Sku) { [string]$disk.Sku.Name } else { [string]$slot.ManagedDisk.StorageAccountType })
            # RESTORE-EMPTY-LUN-1: the LUN's own settings. A restore keeps
            # this read in its checkpoint (putBackJob.before) before it changes
            # anything, so a LUN a stopped job left with no disk gets its disk
            # back with them (Get-VmfEmptyLunSettings).
            caching                 = [string]$slot.Caching
            deleteOption            = [string]$slot.DeleteOption
            writeAcceleratorEnabled = [bool]$slot.WriteAcceleratorEnabled
        }
    }
}
function Get-VmfDeleteBlockingLocks {
    <#
    .SYNOPSIS
        RESTORE-1: resource locks that would stop a disk being deleted, checked
        BEFORE a restore that needs to delete one. Azure refuses to delete a
        locked resource, and finding that out mid-restore would strand the
        machine on a temporary disk. Returns lock names (empty = clear).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DiskName
    )

    # Locks inherit downward, so a lock on the resource group blocks the disk
    # just as surely as one on the disk itself. The DECISION lives in
    # Select-VmfDeleteBlockingLocks; this function only fetches.
    # REBUILD-PROPS-1: a read that fails throws, and the restore stops before
    # anything moves. It used to read as "no locks".
    $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    Select-VmfDeleteBlockingLocks -Locks $locks -DiskName $DiskName
}

function Remove-VmfManagedDisk {
    <#
    .SYNOPSIS
        RESTORE-1: delete a managed disk. Only ever called on a disk that is
        already detached, and only when the caller chose to preserve a disk
        NAME (a managed disk cannot be renamed, so the name must be freed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DiskName
    )

    Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force | Out-Null
}

function Remove-VmfSnapshot {
    <#
    .SYNOPSIS
        WAVE-2 lever 7: delete one safety-copy snapshot by its resource id.
    .DESCRIPTION
        A snapshot that is already gone is SUCCESS, not a failure - retention
        must be re-runnable, and a half-finished cleanup is the normal way to
        arrive here. Any other failure is left to the caller.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SnapshotId)

    # SEC-1 / F10. Every action in the product addresses a resource by its
    # resource ID, the one string Azure keeps unique.
    #
    # This used to reduce the id to resource group and name and call
    # Remove-AzSnapshot, which resolves that pair against whatever subscription
    # the process happened to be signed in to. A resource group and a name are
    # unique only INSIDE one subscription, so a same-named snapshot elsewhere
    # was a candidate for deletion - and a delete that found nothing was
    # reported as success, which then marked the safety copies gone and
    # refused every later restore.
    #
    # The id already carries the subscription. Deleting through ARM by that id
    # cannot address anything else, and needs no ambient context at all - which
    # matters here beyond correctness: this runs inside the service, which
    # serves several requests on one PowerShell worker, so a process-wide
    # subscription switch would be a race between them.
    $null = Assert-VmfResourceId -ResourceId $SnapshotId -Kind 'snapshot'
    $r = Invoke-AzRestMethod -Method DELETE -Path "$SnapshotId`?api-version=$script:VmfSnapshotApiVersion"
    # 204 is "there was nothing there", 404 likewise: a snapshot already gone
    # is SUCCESS, because retention must be re-runnable and a half-finished
    # cleanup is the normal way to arrive here.
    if ($r.StatusCode -in 200, 202, 204, 404) { return }
    throw "Deleting snapshot '$SnapshotId' failed with $($r.StatusCode): $($r.Content)"
}

# SEC-1 / F10: snapshots are addressed through ARM by their resource id, so
# the api version is stated once rather than at each call site.
$script:VmfSnapshotApiVersion = '2024-03-02'

function Assert-VmfResourceId {
    <#
    .SYNOPSIS
        SEC-1 / F10: refuse anything that is not a full Azure resource id.
    .DESCRIPTION
        An id is what makes an action unambiguous, so a value that is missing
        its subscription is not a weaker id - it is not an id, and acting on it
        would mean acting on whatever the ambient context resolved. Returns the
        subscription id, so a caller that needs it does not parse the string a
        second time. Pure: no Azure call.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResourceId,
        [Parameter()][string]$Kind = 'resource'
    )

    $m = [regex]::Match([string]$ResourceId,
        '(?i)^/subscriptions/(?<sub>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/resourceGroups/[^/]+/providers/.+/[^/]+$')
    if (-not $m.Success) {
        throw ("Not a full $Kind resource id: '$ResourceId'. " +
               'An action must name the subscription it acts in, because a resource group and a name are unique only inside one.')
    }
    $m.Groups['sub'].Value
}

function Assert-VmfManagedDiskId {
    <#
    .SYNOPSIS
        DISK-ID-SCOPE-1: refuse anything that is not the full resource id of a
        managed disk (Microsoft.Compute/disks). Returns the subscription id.
    .DESCRIPTION
        Assert-VmfResourceId checks the form of an id only, so a snapshot, a
        machine or a resource under a disk passed as a disk. The read and the
        delete by disk id take a managed disk, and nothing else. Pure: no Azure
        call.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DiskId)

    $sub = Assert-VmfResourceId -ResourceId $DiskId -Kind 'disk'
    if ($DiskId -notmatch '(?i)^/subscriptions/[^/?#%\s]+/resourceGroups/[^/?#%\s]+/providers/Microsoft\.Compute/disks/[^/?#%\s]+\z') {
        throw "Not a managed disk resource id: '$DiskId'. The product reads and deletes a disk by its id only when the id is a resource of the type Microsoft.Compute/disks."
    }
    $sub
}

function Assert-VmfDiskInMachineScope {
    <#
    .SYNOPSIS
        DISK-ID-SCOPE-1: refuse a disk outside the subscription of the machine,
        or outside the resource groups the product makes disks in for it.
    .DESCRIPTION
        The product makes a disk for a machine in the resource group of the
        machine, or - a restore that keeps the names - in the resource group of
        the disk it replaces. -ResourceGroupNames names those others
        (Get-VmfMadeDiskResourceGroups); the machine's own is always allowed.
        Azure resource group names and subscription ids ignore case, and so does
        this check. Pure: no Azure call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DiskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MachineId,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$ResourceGroupNames = @()
    )

    $diskSub = Assert-VmfManagedDiskId -DiskId $DiskId
    $machineSub = Assert-VmfResourceId -ResourceId $MachineId -Kind 'machine'
    if ($MachineId -notmatch '(?i)^/subscriptions/[^/?#%\s]+/resourceGroups/[^/?#%\s]+/providers/Microsoft\.Compute/virtualMachines/[^/?#%\s]+\z') {
        throw "Not a machine resource id: '$MachineId'. The product deletes a disk only for a resource of the type Microsoft.Compute/virtualMachines."
    }
    if ($diskSub -ne $machineSub) {
        throw "The product did not read or delete the disk '$DiskId', because it is not in the subscription of the machine '$MachineId'."
    }
    $allowed = @(@(Get-VmfResourceGroupName -ResourceId $MachineId) + @($ResourceGroupNames) | Where-Object { $_ })
    if ((Get-VmfResourceGroupName -ResourceId $DiskId) -notin $allowed) {
        throw ("The product did not read or delete the disk '$DiskId', because it is not in a resource group where the product makes disks for the machine '$MachineId': " +
               "$(@($allowed | ForEach-Object { "'$_'" }) -join ', ').")
    }
}

# SAFETY-3: the safety copies are the restore chain. A CanNotDelete lock on
# each one stops a Contributor, a script or a cleanup job from deleting it
# before its accepted retention ends; the product removes the lock itself when
# retention runs. A lock stops accidents and automation, not an Owner who
# removes it first - the run page says so in as many words.
$script:VmfSafetyCopyLockName = 'vmf-safety-copy'

function Lock-VmfSnapshot {
    <#
    .SYNOPSIS
        SAFETY-3: place the CanNotDelete lock on one safety copy. Returns the
        lock's id.
    .DESCRIPTION
        Idempotent: a lock already there is the outcome wanted (a resumed
        machine re-runs the step that placed it).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][AllowEmptyString()][string]$Notes = ''
    )

    # MISSING-READ-2: a NotFound is "no lock yet". A read Azure does not answer
    # is not known either way, and asking for the lock again is the safe
    # answer: it is the same lock name on the same copy, so Azure keeps one
    # lock, and a write Azure refuses throws below. Never a throw here - the
    # lock is the safety copy's protection, and one read must not cost it.
    $existing = $null
    try { $existing = Get-AzResourceLock -LockName $script:VmfSafetyCopyLockName -Scope $SnapshotId -ErrorAction Stop }
    catch {
        if (-not (Test-VmfAzNotFound -ErrorRecord $_)) {
            Write-Verbose "Azure did not say if the safety copy '$SnapshotId' has its lock, so the lock is asked for again: $($_.Exception.Message)"
        }
    }
    if ($existing) { return [string]$existing.LockId }
    $lock = New-AzResourceLock -LockLevel CanNotDelete -LockName $script:VmfSafetyCopyLockName `
        -Scope $SnapshotId -LockNotes $Notes -Force
    if (-not $lock.LockId) { throw "Locking snapshot '$SnapshotId' returned no lock." }
    [string]$lock.LockId
}

function Unlock-VmfSnapshot {
    <#
    .SYNOPSIS
        SAFETY-3: remove the product's lock from one safety copy, so retention
        can delete it.
    .DESCRIPTION
        A lock (or a snapshot) that is already gone is SUCCESS: retention must
        be re-runnable, and a half-finished cleanup is the normal way here.

        COPY-DELETE-LOCK-RACE-1 (lab install, 2026-11-14): an accepted removal
        is not proof the lock is gone. A delete sent at once was refused with
        ScopeLocked while Azure still listed the lock. So this returns only
        when a read of the lock says Azure no longer lists it, and throws when
        it is still listed after -ConfirmReads reads -ConfirmDelaySec apart.
        A read that fails for another reason throws too: unknown is not gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][ValidateRange(1, 100)][int]$ConfirmReads = 6,
        [Parameter()][ValidateRange(0, 600)][int]$ConfirmDelaySec = 10
    )

    try {
        Remove-AzResourceLock -LockName $script:VmfSafetyCopyLockName -Scope $SnapshotId -Force -Confirm:$false | Out-Null
    }
    catch {
        if ("$_" -notmatch 'NotFound|ResourceNotFound|could not be found|was not found|LockNotFound') { throw }
    }

    for ($i = 1; $i -le $ConfirmReads; $i++) {
        $listed = $null
        try { $listed = Get-AzResourceLock -LockName $script:VmfSafetyCopyLockName -Scope $SnapshotId -ErrorAction Stop }
        catch {
            if (-not (Test-VmfAzNotFound -ErrorRecord $_) -and "$_" -notmatch 'LockNotFound|could not be found') { throw }
        }
        if (-not $listed) { return }
        if ($i -lt $ConfirmReads) { Start-Sleep -Seconds $ConfirmDelaySec }
    }
    throw "After $($ConfirmReads * $ConfirmDelaySec) seconds, Azure still shows the lock '$($script:VmfSafetyCopyLockName)' on the safety copy. The product did not delete the copy."
}

function Test-VmfSnapshotExists {
    <#
    .SYNOPSIS
        SAFETY-3: is this safety copy still there? Asked before the point of
        no return, so a deleted copy stops the migration with the machine
        untouched instead of surfacing at restore time.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SnapshotId)

    # SEC-1 / F10: asked of the id, so the answer is about THIS snapshot and
    # not about a same-named one in whichever subscription the process happens
    # to be pointed at. Answering "yes" about the wrong snapshot would let a
    # migration pass the point of no return with no safety copy behind it.
    $null = Assert-VmfResourceId -ResourceId $SnapshotId -Kind 'snapshot'
    # PERF-TELEMETRY-1: the daily cleanup asks this for each copy, so it is timed.
    $r = Invoke-VmfArmRequest -Method GET -Path "$SnapshotId`?api-version=$script:VmfSnapshotApiVersion"
    if ($r.StatusCode -eq 200) { return $true }
    if ($r.StatusCode -eq 404) { return $false }
    throw "Reading snapshot '$SnapshotId' failed with $($r.StatusCode): $($r.Content)"
}

function Get-VmfDiskShareCount {
    <#
    .SYNOPSIS
        SAFETY-ALL-1: how many machines may attach this disk at once
        (maxShares). A shared disk is never swapped for a copy: the other
        machines keep writing to the original.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$DiskId)

    $null = Assert-VmfResourceId -ResourceId $DiskId -Kind 'disk'
    # The disks provider takes the same api version as its snapshots.
    $r = Invoke-AzRestMethod -Method GET -Path "$DiskId`?api-version=$script:VmfSnapshotApiVersion"
    if ($r.StatusCode -ne 200) { throw "Reading disk '$DiskId' failed with $($r.StatusCode): $($r.Content)" }
    $shares = ($r.Content | ConvertFrom-Json).properties.maxShares
    if ($null -eq $shares) { 1 } else { [int]$shares }
}

function Get-VmfManagedDiskSku {
    <#
    .SYNOPSIS
        OLD-SKU-1C: a managed disk's type and how many machines may share it,
        by resource id.
    .OUTPUTS
        @{ SkuName; MaxShares; ProvisioningState }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$DiskId)

    $null = Assert-VmfResourceId -ResourceId $DiskId -Kind 'disk'
    $r = Invoke-AzRestMethod -Method GET -Path "$DiskId`?api-version=$script:VmfSnapshotApiVersion"
    if ($r.StatusCode -ne 200) { throw "Reading disk '$DiskId' failed with $($r.StatusCode): $($r.Content)" }
    $body = $r.Content | ConvertFrom-Json
    @{
        SkuName           = [string]$body.sku.name
        MaxShares         = $(if ($null -eq $body.properties.maxShares) { 1 } else { [int]$body.properties.maxShares })
        ProvisioningState = [string]$body.properties.provisioningState
    }
}

# SAFETY-ULTRA-1: the reads and the copy that a put-back of a Premium SSD v2 or
# Ultra Disk data disk needs. A separate api version, so the disk and snapshot
# reads above do not change: snapshotAccessState and instant access are read at
# the version Microsoft's instant access template uses.
$script:VmfInstantAccessApiVersion = '2025-01-02'

function ConvertTo-VmfNullableNumber {
    # A number Azure returned, or $null when it returned none. Never 0 for
    # "absent": a disk with 0 IOPS on record would be made with 0.
    param([Parameter()][AllowNull()]$Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    [long]$Value
}

function Get-VmfManagedDiskFacts {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: what a put-back needs to make this disk again, read
        from the disk itself by its resource id.
    .DESCRIPTION
        IOPS and throughput are on the DISK, not on the machine (the machine's
        record of a data disk does not hold them), so PRECHECK reads each
        Premium SSD v2 and Ultra Disk data disk once. The put-back reads the
        disk it made the same way and compares. A field Azure does not return
        is $null - never a default.
        SAFETY-CMK-1: and its encryption (encryption.type and
        encryption.diskEncryptionSetId), which PRECHECK records for every disk
        and every put-back compares on the disk it made.
    .OUTPUTS
        @{ id; skuName; diskSizeGB; diskIOPSReadWrite; diskMBpsReadWrite;
           logicalSectorSize; zones; maxShares; completionPercent; provisioningState;
           encryptionType; diskEncryptionSetId }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$DiskId)

    $null = Assert-VmfResourceId -ResourceId $DiskId -Kind 'disk'
    $r = Invoke-AzRestMethod -Method GET -Path "$DiskId`?api-version=$script:VmfInstantAccessApiVersion"
    if ($r.StatusCode -ne 200) { throw "Reading disk '$DiskId' failed with $($r.StatusCode): $($r.Content)" }
    $body = $r.Content | ConvertFrom-Json
    $p = $body.properties
    $creation = if ($p -and $p.PSObject.Properties['creationData']) { $p.creationData } else { $null }
    $encryption = if ($p -and $p.PSObject.Properties['encryption']) { $p.encryption } else { $null }
    $encField = { param($n) if ($encryption -and $encryption.PSObject.Properties[$n] -and [string]$encryption.$n) { [string]$encryption.$n } else { $null } }
    [pscustomobject]@{
        id                = [string]$body.id
        skuName           = [string]$body.sku.name
        diskSizeGB        = ConvertTo-VmfNullableNumber $p.diskSizeGB
        diskIOPSReadWrite = ConvertTo-VmfNullableNumber $p.diskIOPSReadWrite
        diskMBpsReadWrite = ConvertTo-VmfNullableNumber $p.diskMBpsReadWrite
        logicalSectorSize = $(if ($creation) { ConvertTo-VmfNullableNumber $creation.logicalSectorSize } else { $null })
        zones             = @(@($body.zones) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        maxShares         = $(if ($null -eq $p.maxShares) { 1 } else { [int]$p.maxShares })
        # Microsoft: other disk types always report 100; a Premium SSD v2 or
        # Ultra Disk below 100 is still being filled from a copy.
        completionPercent = $(if ($null -eq $p.completionPercent) { $null } else { [double]$p.completionPercent })
        provisioningState = [string]$p.provisioningState
        # Null when Azure returned none - never "platform key".
        encryptionType      = (& $encField 'type')
        diskEncryptionSetId = (& $encField 'diskEncryptionSetId')
        # NO-PLAN-SCOPE-1: the disk's Marketplace purchase plan, or $null for
        # none - Checking stops a machine whose OS disk has one. A read that
        # succeeded is an answer; a failed one threw above.
        purchasePlan        = ConvertTo-VmfPurchasePlan -Plan $(if ($p -and $p.PSObject.Properties['purchasePlan']) { $p.purchasePlan } else { $null })
        # ADE-DETECT-ANY-NAME-1: Azure Disk Encryption on this disk, from
        # encryptionSettingsCollection.enabled. No setting on a disk Azure
        # answered for is $false (an answer); a setting with no true or false
        # value is $null - unknown, never yes or no (EVAL-M6). A failed read
        # threw above. Always returned, so a reader can tell unknown from absent.
        adeEnabled          = ConvertTo-VmfAdeEnabled -Properties $p
    }
}

function ConvertTo-VmfAdeEnabled {
    # ADE-DETECT-ANY-NAME-1: $true, $false or $null (unknown) from a disk's
    # properties. Microsoft: enabled is required in encryptionSettingsCollection.
    param([Parameter()][AllowNull()]$Properties)
    if (-not $Properties -or -not $Properties.PSObject.Properties['encryptionSettingsCollection'] -or $null -eq $Properties.encryptionSettingsCollection) { return $false }
    $collection = $Properties.encryptionSettingsCollection
    if (-not $collection.PSObject.Properties['enabled']) { return $null }
    $enabled = $collection.enabled
    if ($enabled -is [bool]) { return $enabled }
    switch ([string]$enabled) { 'true' { return $true } 'false' { return $false } }
    $null
}

function Get-VmfManagedDiskAttachment {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: whether a disk still exists and what it is
        attached to, read by its resource id.
    .DESCRIPTION
        A put-back reads each rollback disk before it stops the
        machine, and a cleanup reads each one before it deletes it. A disk
        that is gone is an answer (Exists $false), never an error; any other
        failed read throws, and the caller treats it as no answer.
        RESTORE-END-JOB-1: and the copy it was made from, so a resume of a
        restore that keeps the names can tell the disk the machine had from
        the disk made under its name - the two have one resource id.
    .OUTPUTS
        @{ Exists; ManagedBy; SourceResourceId } - ManagedBy is the machine's
        resource id, or empty when nothing is attached. SourceResourceId is
        creationData.sourceResourceId, or empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$DiskId)

    # DISK-ID-SCOPE-1: a managed disk, and nothing else.
    $null = Assert-VmfManagedDiskId -DiskId $DiskId
    # PERF-TELEMETRY-1: the daily cleanup asks this for each disk, so it is timed.
    $r = Invoke-VmfArmRequest -Method GET -Path "$DiskId`?api-version=$script:VmfInstantAccessApiVersion"
    if ($r.StatusCode -eq 404) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
    if ($r.StatusCode -ne 200) { throw "Reading disk '$DiskId' failed with $($r.StatusCode): $($r.Content)" }
    $body = $r.Content | ConvertFrom-Json
    $p = if ($body.PSObject.Properties['properties']) { $body.properties } else { $null }
    $creation = if ($p -and $p.PSObject.Properties['creationData']) { $p.creationData } else { $null }
    [pscustomobject]@{
        Exists           = $true
        ManagedBy        = $(if ($body.PSObject.Properties['managedBy']) { [string]$body.managedBy } else { '' })
        SourceResourceId = $(if ($creation -and $creation.PSObject.Properties['sourceResourceId']) { [string]$creation.sourceResourceId } else { '' })
    }
}

function Remove-VmfManagedDiskById {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: delete a disk the product made for the way
        back, by its resource id.
    .DESCRIPTION
        By the id, never by resource group and name (SEC-1 / F10). The caller
        reads the disk first and never asks for one that is attached; Azure
        refuses to delete an attached disk too. A disk that is already gone is
        success - a cleanup must be safe to run again.
        DISK-ID-SCOPE-1: a managed disk only, of the machine it was made for:
        in the machine's subscription, and in the resource group of the
        machine or one of -ResourceGroupNames (Get-VmfMadeDiskResourceGroups).
        Anything else is refused before Azure is asked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$MachineId,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$ResourceGroupNames = @()
    )

    Assert-VmfDiskInMachineScope -DiskId $DiskId -MachineId $MachineId -ResourceGroupNames $ResourceGroupNames
    $r = Invoke-AzRestMethod -Method DELETE -Path "$DiskId`?api-version=$script:VmfInstantAccessApiVersion"
    if ($r.StatusCode -in 200, 202, 204, 404) { return }
    throw "Deleting disk '$DiskId' failed with $($r.StatusCode): $($r.Content)"
}

function Get-VmfSnapshotAccess {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: whether Azure can make a disk from this copy now, read
        from the copy by its resource id.
    .DESCRIPTION
        snapshotAccessState is Pending, Available, InstantAccess or
        AvailableWithInstantAccess (Microsoft, instant access snapshots).
        timeCreated and instantAccessDurationMinutes say when instant access
        ends. Every decision reads this again; nothing decides from a stored
        date (the PLANVER-2 lesson).
    .OUTPUTS
        @{ id; provisioningState; snapshotAccessState; completionPercent;
           instantAccessDurationMinutes; timeCreated (ISO 8601 UTC or $null);
           sourceResourceId }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SnapshotId)

    $null = Assert-VmfResourceId -ResourceId $SnapshotId -Kind 'snapshot'
    $r = Invoke-AzRestMethod -Method GET -Path "$SnapshotId`?api-version=$script:VmfInstantAccessApiVersion"
    if ($r.StatusCode -ne 200) { throw "Reading snapshot '$SnapshotId' failed with $($r.StatusCode): $($r.Content)" }
    ConvertTo-VmfSnapshotAccess -Body ($r.Content | ConvertFrom-Json)
}

function ConvertTo-VmfSnapshotAccess {
    # One shape for a snapshot read, from a GET or a PUT response.
    param([Parameter(Mandatory)]$Body)
    $p = $Body.properties
    $creation = if ($p -and $p.PSObject.Properties['creationData']) { $p.creationData } else { $null }
    # ConvertFrom-Json turns an ISO date into a date value; one ISO UTC string
    # for every reader (CLAUDE.md, PLANVER-2).
    $created = if ($p -and $p.PSObject.Properties['timeCreated'] -and $p.timeCreated) { ConvertTo-VmfIsoUtc $p.timeCreated } else { $null }
    [pscustomobject]@{
        id                           = [string]$Body.id
        provisioningState            = [string]$p.provisioningState
        snapshotAccessState          = $(if ($p -and $p.PSObject.Properties['snapshotAccessState']) { [string]$p.snapshotAccessState } else { '' })
        completionPercent            = $(if ($p -and $null -ne $p.completionPercent) { [double]$p.completionPercent } else { $null })
        instantAccessDurationMinutes = $(if ($creation -and $creation.PSObject.Properties['instantAccessDurationMinutes']) { ConvertTo-VmfNullableNumber $creation.instantAccessDurationMinutes } else { $null })
        timeCreated                  = $created
        sourceResourceId             = $(if ($creation) { [string]$creation.sourceResourceId } else { '' })
    }
}

function New-VmfInstantAccessSnapshot {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: the first safety copy of a Premium SSD v2 or Ultra
        Disk data disk, as an incremental snapshot in instant access.
        Idempotent per name: a copy that exists is returned, never taken twice.
    .DESCRIPTION
        Without instant access a copy of these types cannot make a disk until
        Azure finishes copying it in the background, and no Microsoft page
        says how long that takes. With it, a disk can be made from the copy at
        once, for the minutes asked (60 to 300). MEASURED 2026-10-10 on a
        stopped D2s_v4 in three regions: Azure accepted it for both types in 5
        to 18 seconds, in the state InstantAccess.

        By ARM and the snapshot's resource id, not New-AzSnapshotConfig: the
        parameter is in that cmdlet's 15.6.0 and 16.4.0 help, and this keeps
        the call independent of the Az version of the engine image (the
        pin in infra/part-versions.json).
        A refusal throws: this copy is the rollback.
    .OUTPUTS
        The snapshot's resource id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$SnapshotName,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][ValidateRange(60, 300)][int]$Minutes = 300,
        [Parameter()][AllowNull()]$Tags,
        [Parameter()][int]$WaitSeconds = 600,
        [Parameter()][int]$PollSeconds = 5,
        # SAFETY-CMK-1: the disk's own encryption, as for New-VmfOsDiskSnapshot.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$EncryptionType,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DiskEncryptionSetId
    )

    # SAFETY-CMK-1: how a copy Azure holds differs from the disk's encryption.
    $encDiff = {
        param($landed)
        if (-not $EncryptionType) { return $null }
        $enc = if ($landed.properties -and $landed.properties.PSObject.Properties['encryption']) { $landed.properties.encryption } else { $null }
        Get-VmfEncryptionDifference -WantType $EncryptionType -WantSetId $DiskEncryptionSetId `
            -GotType ([string]$(if ($enc) { $enc.type })) -GotSetId ([string]$(if ($enc -and $enc.PSObject.Properties['diskEncryptionSetId']) { $enc.diskEncryptionSetId }))
    }

    $sub = Assert-VmfResourceId -ResourceId $DiskId -Kind 'disk'
    # Incremental copies live in the subscription of their disk.
    $id = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/snapshots/$SnapshotName"
    $path = "$id`?api-version=$script:VmfInstantAccessApiVersion"
    $read = { Invoke-AzRestMethod -Method GET -Path $path }

    $now = & $read
    if ($now.StatusCode -eq 200) {
        # A resume after Azure made it and before the record: the same copy.
        $haveBody = $now.Content | ConvertFrom-Json
        $have = ConvertTo-VmfSnapshotAccess -Body $haveBody
        if ($have.sourceResourceId -and $have.sourceResourceId -ne $DiskId) {
            throw "Snapshot '$SnapshotName' exists and is a copy of '$($have.sourceResourceId)', not of '$DiskId'."
        }
        $diff = & $encDiff $haveBody
        if ($diff) { throw "The safety copy '$SnapshotName' exists, and $diff. The product does not use it." }
        return $id
    }
    if ($now.StatusCode -ne 404) { throw "Reading snapshot '$SnapshotName' failed with $($now.StatusCode): $($now.Content)" }

    $tagTable = ConvertTo-VmfTagTable -Tags $Tags
    $body = [ordered]@{
        location   = $Location
        properties = [ordered]@{
            incremental  = $true
            creationData = [ordered]@{ createOption = 'Copy'; sourceResourceId = $DiskId; instantAccessDurationMinutes = $Minutes }
        }
    }
    if ($EncryptionType) {
        $encBody = [ordered]@{ type = $EncryptionType }
        if ($DiskEncryptionSetId) { $encBody.diskEncryptionSetId = $DiskEncryptionSetId }
        $body.properties.encryption = $encBody
    }
    if ($tagTable.Count -gt 0) { $body.tags = $tagTable }
    $put = Invoke-AzRestMethod -Method PUT -Path $path -Payload ($body | ConvertTo-Json -Depth 8)
    if ($put.StatusCode -notin 200, 201, 202 -and $tagTable.Count -gt 0) {
        # A TAG MUST NEVER COST A SAFETY COPY (FIND-COPY-1): taken again
        # without them, as New-VmfOsDiskSnapshot does.
        Write-Warning ("The safety copy '$SnapshotName' was refused with its tags, so it is being taken without them. " +
                       "Azure said: $($put.Content)")
        $body.Remove('tags')
        $put = Invoke-AzRestMethod -Method PUT -Path $path -Payload ($body | ConvertTo-Json -Depth 8)
    }
    if ($put.StatusCode -notin 200, 201, 202) {
        throw "Azure refused the instant access copy '$SnapshotName' of '$DiskId' ($($put.StatusCode)): $($put.Content)"
    }

    # The create is asynchronous: wait until Azure says it succeeded.
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ($true) {
        $now = & $read
        if ($now.StatusCode -eq 200) {
            $landed = $now.Content | ConvertFrom-Json
            $state = [string]$landed.properties.provisioningState
            if ($state -eq 'Succeeded') {
                # POLICY-REVERT-1: read back what landed, as for every copy.
                if ($body.Contains('tags') -and -not (ConvertTo-VmfTagTable -Tags $landed.tags).ContainsKey('vmfSafetyCopy')) {
                    Write-Warning ("The safety copy '$SnapshotName' was created but Azure did not keep its tags - a policy in " +
                                   "this subscription removes them. Its lock still names it.")
                }
                # SAFETY-CMK-1: and its key, never taken from the exit code.
                $diff = & $encDiff $landed
                if ($diff) { throw "Azure made the safety copy '$SnapshotName', but $diff. The product does not use it." }
                return $id
            }
            if ($state -in 'Failed', 'Canceled') { throw "Azure did not make the instant access copy '$SnapshotName': provisioning state $state." }
        }
        elseif ($now.StatusCode -ne 404) { throw "Reading snapshot '$SnapshotName' failed with $($now.StatusCode): $($now.Content)" }
        if ((Get-Date) -ge $deadline) { throw "Azure did not finish the instant access copy '$SnapshotName' within $WaitSeconds seconds." }
        # EVAL-H1: renew the lease while waiting.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Set-VmfManagedDiskSku {
    <#
    .SYNOPSIS
        OLD-SKU-1C: change a managed disk's type, by resource id, and wait
        until Azure reports the new type. Idempotent: a disk that already has
        it is not changed.
    .DESCRIPTION
        Azure allows the change only while no running machine uses the disk,
        and only two changes per disk a day - the engine checks the second
        before the machine is stopped (Get-VmfDiskTypeChangeRefusal).
    .OUTPUTS
        $true when it changed the disk, $false when it already had the type.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS')][string]$SkuName,
        [Parameter()][int]$WaitSeconds = 300
    )

    if ((Get-VmfManagedDiskSku -DiskId $DiskId).SkuName -eq $SkuName) { return $false }
    $payload = @{ sku = @{ name = $SkuName } } | ConvertTo-Json -Compress
    $r = Invoke-AzRestMethod -Method PATCH -Path "$DiskId`?api-version=$script:VmfSnapshotApiVersion" -Payload $payload
    if ($r.StatusCode -notin @(200, 202)) { throw "Changing the type of disk '$DiskId' to $SkuName failed with $($r.StatusCode): $($r.Content)" }
    $until = (Get-Date).AddSeconds($WaitSeconds)
    while ($true) {
        $now = Get-VmfManagedDiskSku -DiskId $DiskId
        if ($now.SkuName -eq $SkuName -and $now.ProvisioningState -eq 'Succeeded') { return $true }
        if ($now.ProvisioningState -eq 'Failed') { throw "Azure could not change the type of disk '$DiskId' to $SkuName. The disk reports provisioning state Failed." }
        if ((Get-Date) -gt $until) { throw "The disk '$DiskId' did not report the type $SkuName within $WaitSeconds seconds. It reports $($now.SkuName), $($now.ProvisioningState)." }
        Start-Sleep -Seconds 5
    }
}

function ConvertTo-VmfTagTable {
    <#
    .SYNOPSIS
        Normalize a captured tags value to Dictionary[string,string].
        Two traps found by the P1-6 conversion drill: (1) tags arrive as a
        PSCustomObject after the state-store JSON round-trip, and (2) the VM
        config's Tags property is a GENERIC IDictionary[string,string], which
        PowerShell will not auto-convert even a plain Hashtable into - it needs
        a real generic Dictionary instance.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param([Parameter()][AllowNull()]$Tags)

    $dict = [System.Collections.Generic.Dictionary[string, string]]::new()
    if ($null -eq $Tags) { return , $dict }
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($k in $Tags.Keys) { $dict[[string]$k] = [string]$Tags[$k] }
    }
    else {
        foreach ($p in $Tags.PSObject.Properties) { $dict[[string]$p.Name] = [string]$p.Value }
    }
    return , $dict
}

function Get-VmfVmIdentityFacts {
    <#
    .SYNOPSIS
        EVAL-C1/H2: what identity and disk capability does this machine have
        RIGHT NOW? Read after a rebuild so the two properties that were being
        dropped are compared rather than assumed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    [pscustomobject]@{
        identityType    = if ($vm.Identity) { [string]$vm.Identity.Type } else { '' }
        userAssignedIds = @(if ($vm.Identity -and $vm.Identity.UserAssignedIdentities) {
            @($vm.Identity.UserAssignedIdentities.Keys) | ForEach-Object { [string]$_ }
        })
        # IDENTITY-2: the principal itself, not just the type. A rebuilt machine
        # reports the same TYPE and a DIFFERENT principal, which is the whole
        # loss - comparing types alone reported a match for it.
        identityPrincipalId = if ($vm.Identity) { [string]$vm.Identity.PrincipalId } else { '' }
        ultraSsdEnabled = if ($vm.AdditionalCapabilities) { [bool]$vm.AdditionalCapabilities.UltraSSDEnabled } else { $false }
    }
}

function Set-VmfNicAcceleratedNetworking {
    <#
    .SYNOPSIS
        AN-1: set enableAcceleratedNetworking on a NIC. Idempotent. The VM must
        be deallocated (or the NIC detached) for the change to apply cleanly.
    .OUTPUTS
        ROLLBACK-AN-1: $true when it changed the NIC, $false when it was
        already so - so a caller can say what it changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$NicId,
        [Parameter(Mandatory)][bool]$Enabled
    )

    # Addressed by its resource id (the standing rule, SEC-1), never a name.
    $null = Assert-VmfResourceId -ResourceId $NicId -Kind 'network interface'
    $nic = Get-AzNetworkInterface -ResourceId $NicId
    if ([bool]$nic.EnableAcceleratedNetworking -eq $Enabled) { return $false }
    $nic.EnableAcceleratedNetworking = $Enabled
    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
    $true
}

function Get-VmfBootDiagnostics {
    <#
    .SYNOPSIS
        Fetch boot-diagnostics evidence (screenshot + serial log URIs) for triage.
        Best-effort: returns what it can, never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $view = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status
        $bd = $view.BootDiagnostics
        return @{
            screenshotUri = $bd.ConsoleScreenshotBlobUri
            serialLogUri  = $bd.SerialConsoleLogBlobUri
            fetchedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    catch {
        return @{ error = $_.Exception.Message; fetchedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }
}

function Test-VmfAzNotFound {
    <#
    .SYNOPSIS
        MISSING-READ-1: $true when a failed Az read says the resource is not
        there - the one answer a failed read may give.
    .DESCRIPTION
        EVAL-M6 wrote this test for the encryption read; MISSING-READ-1 moved
        it here, unchanged, so every read that takes "not found" as an answer
        asks the same question. A throttle, a 5xx, a refused permission or a
        reset socket is $false: the caller throws, and unknown is never read
        as "not there".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorRecord)
    $message = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { [string]$ErrorRecord.Exception.Message }
               elseif ($ErrorRecord -is [Exception]) { [string]$ErrorRecord.Message }
               else { [string]$ErrorRecord }
    $message -match '(?i)not ?found|ResourceNotFound|was not found'
}

function Get-VmfVmExtensions {
    <#
    .SYNOPSIS
        List a VM's extensions (name, publisher/type, provisioning state).
        Captured at PRECHECK; compared at VALIDATING (MS operational validation:
        extensions do not carry forward on a fresh shell).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    # REBUILD-PROPS-1: a read that fails throws. It used to return an empty
    # list, which PRECHECK recorded as "no extensions" and Verifying then did
    # not compare at all. A machine with no extensions is still an empty list.
    $extensions = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $Name -ErrorAction Stop)
    , @($extensions | ForEach-Object {
        [ordered]@{
            name              = $_.Name
            publisher         = $_.Publisher
            type              = $_.ExtensionType
            provisioningState = $_.ProvisioningState
        }
    })
}

function Get-VmfVmSize {
    <#
    .SYNOPSIS
        The size a machine is currently running on.

        Its own op so the put-back can record where the machine LANDED without
        reaching for Az from a Public cmdlet - and so a test can say what the
        answer is instead of asking real Azure, which is what it was doing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    # MISSING-READ-1: a machine that is not there has no size (''). A read
    # that fails throws - an empty size is never the answer to "no answer".
    try { $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
    catch {
        if (Test-VmfAzNotFound -ErrorRecord $_) { return '' }
        throw
    }
    [string]$vm.HardwareProfile.VmSize
}

function Get-VmfVmSizeByArm {
    <#
    .SYNOPSIS
        PREVIEW-RESTORE-UPFRONT-1: the size of a machine, read by a GET of its
        resource id - for the web service, which loads no Az module and so
        has no Get-AzVM (FACADE-SIGNIN-COLD-1, FacadeAzModules.Tests.ps1).
    .DESCRIPTION
        GET {vmId}?api-version=2024-07-01, Microsoft.Compute/virtualMachines/read
        (the VMF Assessment role). '' when Azure does not find the machine
        (404), as Get-VmfVmSize gives. Any other answer throws: an empty size
        is never the answer to no answer (MISSING-READ-1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)
    $null = Assert-VmfResourceId -ResourceId $VmId -Kind 'virtual machine'
    if ($VmId -notmatch '(?i)/providers/Microsoft\.Compute/virtualMachines/[^/]+$') {
        throw "Not a full virtual machine resource id: '$VmId'."
    }
    $r = Invoke-VmfArmRequest -Method GET -Path "$($VmId)?api-version=2024-07-01"
    $code = if ($r) { [int]$r.StatusCode } else { 0 }
    if ($code -eq 404) { return '' }
    if ($code -ne 200 -or -not $r.Content) { throw "The read of the machine '$VmId' failed with HTTP $($code): $(if ($r) { $r.Content })" }
    $size = [string](($r.Content | ConvertFrom-Json -Depth 20).properties.hardwareProfile.vmSize)
    if (-not $size) { throw "Azure gave no size for the machine '$VmId'." }
    $size
}

function Test-VmfVmExists {
    <#
    .SYNOPSIS
        Does this VM exist? The question recovery has to answer before it does
        anything, because rebuilding a machine that is already there would
        create a second one attached to the same disks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    # MISSING-READ-1: $false only when Azure says the machine is not there. A
    # read that fails throws, so a caller never rebuilds over a machine it
    # could not see.
    try { $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop }
    catch {
        if (Test-VmfAzNotFound -ErrorRecord $_) { return $false }
        throw
    }
    [bool]$vm
}

function Get-VmfAvailabilitySetMembers {
    <#
    .SYNOPSIS
        The machines sharing an availability set, and whether they are running.

        AVSET-1. An availability set is pinned to a cluster, and Microsoft's own
        tooling warns that a conversion can fail while other members are still
        allocated - the set cannot move to hardware that supports the new size
        until every member is deallocated. Before saying that to an operator we
        have to know who the others ARE, so this asks rather than guesses.

        Power state is read per member, so this is O(members) calls. Availability
        sets are small by construction (Azure caps them well below the point
        where that matters) and it runs once per machine at PRECHECK.
    .OUTPUTS
        Objects with Name, Id, Allocated - Allocated $null when the power state
        could not be read, which must never be reported as "stopped".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AvailabilitySetId)

    $parts = $AvailabilitySetId -split '/'
    $rg = $parts[4]
    $name = $parts[-1]
    # MISSING-READ-2: only a NotFound is "no set, so no other members". A read
    # Azure does not answer throws, and PRECHECK says it does not know.
    $avset = $null
    try { $avset = Get-AzAvailabilitySet -ResourceGroupName $rg -Name $name -ErrorAction Stop }
    catch {
        if (Test-VmfAzNotFound -ErrorRecord $_) { return @() }
        throw
    }
    if (-not $avset) { return @() }

    @(foreach ($ref in @($avset.VirtualMachinesReferences)) {
        $vmParts = ([string]$ref.Id) -split '/'
        $vmRg = $vmParts[4]
        $vmName = $vmParts[-1]
        $allocated = $null
        # Any failure - a NotFound included - leaves the power state unknown.
        $status = $null
        try { $status = Get-AzVM -ResourceGroupName $vmRg -Name $vmName -Status -ErrorAction Stop }
        catch { $status = $null }
        if ($status) { $allocated = [bool](@($status.Statuses.Code) -match 'PowerState/(running|starting)') }
        [pscustomobject]@{ Name = $vmName; Id = [string]$ref.Id; Allocated = $allocated }
    })
}


function Get-VmfAvailabilitySetSizes {
    <#
    .SYNOPSIS
        The sizes Azure can put a machine in this availability set on, now.
    .DESCRIPTION
        AVSET-NOTE-1. Microsoft's resize page makes stopping the whole set
        conditional: every member must be deallocated only when the new size
        "isn't available on the hardware cluster currently hosting" the set.
        This is the question that decides it - the availability set's own
        available-sizes list, which Microsoft's allocation-failure guidance
        names for exactly this. It says nothing about free capacity, so a size
        on this list can still fail to start when the cluster is full.
    .OUTPUTS
        Size names. The caller treats a failure to read as UNKNOWN, never as
        either answer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AvailabilitySetId)

    $parts = $AvailabilitySetId -split '/'
    @(Get-AzVMSize -ResourceGroupName $parts[4] -AvailabilitySetName $parts[-1] -ErrorAction Stop |
        ForEach-Object { [string]$_.Name })
}
function Get-VmfNetworkInterfaceById {
    <#
    .SYNOPSIS
        NIC-JOIN-1: one network interface, addressed by its resource id - read
        so the pre-move check can see everything the interface links to.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NicId)
    Get-AzNetworkInterface -ResourceId $NicId -ErrorAction Stop
}
