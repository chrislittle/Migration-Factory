# State store: schema-versioned VM documents over the generic run store
# (StoreApi.ps1 - file or azblob, selected by the RunPath string). One JSON doc
# per VM under <store>/state/, evidence under <store>/evidence/, run manifest
# at <store>/run.json. Atomicity lives in the store layer.

function Get-VmfVmKey {
    <#
    .SYNOPSIS
        Derive a filesystem-safe key from a VM resource id.
    .DESCRIPTION
        Uses "<rg>--<vmName>" plus a short hash of the full id, so two VMs with the
        same name in different subscriptions/RGs can never collide.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)

    $parts = $VmId.Trim('/') -split '/'
    $rg = 'unknownrg'; $name = ($parts[-1])
    $rgIndex = [array]::IndexOf($parts, 'resourceGroups')
    if ($rgIndex -ge 0 -and $rgIndex + 1 -lt $parts.Count) { $rg = $parts[$rgIndex + 1] }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($VmId.ToLowerInvariant())) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally { $sha.Dispose() }

    $safe = ('{0}--{1}' -f $rg, $name) -replace '[^A-Za-z0-9\-_.]', '_'
    return '{0}--{1}' -f $safe, $hash.Substring(0, 8)
}

function Get-VmfMachineName {
    <#
    .SYNOPSIS
        VMID-CASE-1: the name a person reads for a machine - as Azure spells it
        on the machine, not as it appears inside the ID.
    .DESCRIPTION
        Azure gives some resource IDs with the resource group or the machine
        name in upper case, and others as they were made. The ID is kept as the
        assessment read it, so a name cut from it showed MX-G1W for mx-g1w.
        The records hold the name itself (the capture, then the assessment):
        the first one given that is the ID's last part, ignoring case, is the
        name. A recorded name of anything else never renames the machine.
        The dashboard's twin is VmfHelp.machineName; both are held to
        tests/fixtures/machine-names.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$VmId,
        # In order: the name each record holds. Null or empty is no name.
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Names = @()
    )
    $leaf = ($VmId -split '/')[-1]
    foreach ($n in @($Names)) {
        $s = [string]$n
        if ($s -and (-not $leaf -or $s -ieq $leaf)) { return $s }
    }
    $leaf
}

function Resolve-VmfRecordedVmId {
    <#
    .SYNOPSIS
        VMID-CASE-1: a machine's ID as this run's record spells it.
    .DESCRIPTION
        A machine's record is kept under a name made from its ID as the
        assessment read it, and blob storage names are case sensitive. Azure
        IDs are not, and Azure does not always give one ID in one case - so an
        ID copied from Azure can miss the record, and a write under it starts
        a second record for the same machine. Every page sends the recorded ID;
        this is for a person or a tool that names the machine another way.

        The short hash in the record's name is taken over the ID in lower case,
        so it is the same for every spelling: only records with that hash are
        read. Returns the record's own vmId, or the ID as given when this run
        holds no record of the machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if ($doc -and [string]$doc.vmId) { return [string]$doc.vmId }
    $hashPart = '--' + ((Get-VmfVmKey -VmId $VmId) -split '--')[-1] + '.json'
    foreach ($n in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) {
        if (-not $n.EndsWith($hashPart, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $found = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$n"
        if ($found -and [string]$found.vmId -ieq $VmId) { return [string]$found.vmId }
    }
    $VmId
}

function Resolve-VmfRunProject {
    <#
    .SYNOPSIS
        PROJECT-1: which project a run at this path belongs to, derived from the
        path itself.
    .DESCRIPTION
        NOT a parameter. The project is WHERE the run is, so asking the caller to
        also state it invites the two to disagree - and the disagreement would be
        silent, because nothing downstream can tell which was meant. Same reason
        the run id is read from the path rather than passed.

        A run whose parent holds no `project.json` belongs to no project, which
        is a legitimate answer (an ad-hoc run from the command line) and
        returns $null rather than inventing one.
    .OUTPUTS
        [string] the project id, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunPath)

    try {
        $parent = Split-VmfStorePath -Path $RunPath
        if (-not $parent -or $parent -eq $RunPath) { return $null }
        $doc = Read-VmfStoreJson -RunPath $parent -RelPath 'project.json' -Depth 6
        if ($doc -and $doc.projectId) { return [string]$doc.projectId }
        $null
    }
    catch {
        # Belonging to a project is metadata. Failing to work it out must never
        # fail the assessment or the plan that was otherwise fine.
        Write-Verbose "could not resolve the project for '$RunPath': $($_.Exception.Message)"
        $null
    }
}

function Initialize-VmfRun {
    <#
    .SYNOPSIS
        Create the run directory layout and run manifest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RunId,
        # ASSESS-PAGE-1: which of the two things this object is. Everything in
        # the store used to be a "run", so scanning an estate created one that
        # then sat in the run list looking like an abandoned migration. An
        # assessment is not a failed run - it answers a question on its own, it
        # gets re-run and compared, it is the thing that gets signed off, and it
        # is read-only and broad where a migration writes and should be narrow.
        #
        # Defaulting to 'migration' keeps every existing caller working: a
        # migration is what they have always created. Assessment is opt-in and
        # explicit.
        [Parameter()][ValidateSet('assessment', 'migration')][string]$Kind = 'migration',
        # Migrations only: the assessment this was planned from, which is the
        # traceability the product has never had.
        [Parameter()][string]$FromAssessment,
        # Assessments only: what was scanned, so the page can say so without
        # opening the assessment itself.
        [Parameter()][AllowNull()]$Scope,
        # PROJECT-1: which project this belongs to. Derived by the callers from
        # where the run is being created rather than typed twice.
        [Parameter()][AllowNull()][string]$Project
    )

    # STORE-RESERVED-NAMES-1: never at a folder the product keeps, asked before
    # the store is touched. And a NEW run never at a project's root or inside
    # another run: a run there is one whose delete takes the project, or the
    # other run. Asked only when there is no manifest yet, the one time a run
    # is made, so every later call costs no extra read.
    Assert-VmfRunNames -RunPath $RunPath
    $hasManifest = Test-VmfStoreItem -RunPath $RunPath -RelPath 'run.json'
    if (-not $hasManifest) {
        Assert-VmfNotProject -RunPath $RunPath
        Assert-VmfParentNotRun -RunPath $RunPath -HasProject:([bool]$Project)
    }

    Initialize-VmfStore -RunPath $RunPath

    # NOT re-written when it already exists. Every operation calls this, so a
    # later call that could overwrite the kind would silently turn an assessment
    # into a migration the moment somebody planned from it.
    if (-not $hasManifest) {
        $manifest = [ordered]@{
            schemaVersion  = 9
            kind           = $Kind
            runId          = $RunId
            createdUtc     = (Get-Date).ToUniversalTime().ToString('o')
        }
        # PROJECT-1. Recorded on BOTH kinds - it is what makes an assessment and
        # the migrations planned from it one piece of work.
        $manifest.project = $(if ($Project) { $Project } else { $null })
        if ($Kind -eq 'migration' -and $FromAssessment) { $manifest.fromAssessment = $FromAssessment }
        if ($Kind -eq 'assessment' -and $Scope) {
            $manifest.scope = [ordered]@{
                # SCAN-SCOPE-NULL-1: no null in a list - see Invoke-VmfAssessment.
                subscriptions   = @(@($Scope.subscriptions ?? $Scope.Subscriptions) | Where-Object { $_ })
                managementGroup = [string]($Scope.managementGroup ?? $Scope.ManagementGroup)
                resourceGroups  = @(@($Scope.resourceGroups ?? $Scope.ResourceGroups) | Where-Object { $_ })
            }
            if (-not $manifest.scope.managementGroup) { $manifest.scope.managementGroup = $null }
        }
        Write-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Document $manifest
    }
    Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json'
}

function Get-VmfRunKind {
    <#
    .SYNOPSIS
        RETAIN-KIND-1: what a run's manifest (run.json) says the run is -
        'migration', 'assessment', or $null when there is no manifest or it
        names no kind. Pure.
    .DESCRIPTION
        Initialize-VmfRun writes the kind on every manifest, and the contract
        requires it, so a manifest with no kind is not known: $null, never a
        guess (OLD-VERSION-READERS-REMOVE-6; it was read as a migration for
        manifests from before the assessment split, which no store holds).
        One rule, once in each language: this, and runKind in help.js, both
        held to tests/fixtures/run-kinds.json. A kind the schema does not know
        is returned as written: it is not made into a migration.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Manifest)
    if ($null -eq $Manifest) { return $null }
    # A document that is not an object (text, a number, true) is not a
    # manifest at all: not known, as help.js answers it.
    if ($Manifest -is [string] -or $Manifest -is [ValueType] -or $Manifest -is [array]) { return $null }
    $kind = if ($Manifest -is [System.Collections.IDictionary]) { if ($Manifest.Contains('kind')) { $Manifest['kind'] } else { $null } }
            elseif ($Manifest.PSObject.Properties['kind']) { $Manifest.kind }
            else { $null }
    if ([string]::IsNullOrEmpty([string]$kind)) { return $null }
    [string]$kind
}

function Write-VmfJsonAtomic {
    <#
    .SYNOPSIS
        Atomically write a JSON document: serialize to a temp file, then move over
        the target. A crash mid-write can never leave a half-written document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document
    )

    $tmp = "$Path.tmp.$PID.$([System.Guid]::NewGuid().ToString('N').Substring(0,6))"
    $json = $Document | ConvertTo-Json -Depth 24
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-VmfFileReplace -Source $tmp -Destination $Path
}

function Read-VmfStateDoc {
    <#
    .SYNOPSIS
        Read a VM's state document. Returns $null when none exists yet.
        Throws on unsupported schemaVersion - never silently misreads.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )

    $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath ('state/' + (Get-VmfVmKey -VmId $VmId) + '.json')
    if ($null -eq $doc) { return $null }
    # OLD-STATE-READERS-FINISH-1: the current version only. New-VmfStateDoc
    # writes the current version on every document, and nothing is public
    # before 1.0 (2026-11-11), so no store holds a document an earlier
    # version wrote, and no writer raises one field by field.
    if ($doc.schemaVersion -ne $script:VmfStateDocSchemaVersion) {
        throw "State doc for '$VmId' has unsupported schemaVersion '$($doc.schemaVersion)' (this version reads only $script:VmfStateDocSchemaVersion)."
    }
    return $doc
}

# The vm-state contract's version (schemas/vm-state.schema.json). v11:
# SAFETY-ALL-1's copies of every data disk. v12: OLD-SKU-1C's record of disk
# type changes (diskTypeChanges). v13: IAC-REPORT-1's record of the disks the
# last rollback made (rollback). v14: RESTORE-ALL-1's data disks on a restore.
# v15: RESTORE-PB-1's restore.rebuilt. v16: ROLLBACK-RETRY-CAPTURE-1's
# captured.original, the first capture kept for every put-back. v17:
# V3-RETIRE-1's rollback.sizeAfter, the size a rollback used (no longer written
# since RETIRE-SCOPE-1; removed at v47). v18: MANA-LINUX-KERNEL-1's
# captured.kernelUpdate, what GUEST_PREP did to a Linux kernel. v19: PREP-ROLLBACK-1's
# rollbackPending (the checkpoint a rollback writes before its first change),
# rollbackDisksDuringRollback (every disk a rollback made, recorded the moment it exists)
# and the rollback.path value 'disks'. v20: SAFETY-ULTRA-1's record of a
# Premium SSD v2 or Ultra Disk data disk (captured.vmConfig.dataDisks[]: IOPS,
# throughput, sector size, zones), the evidence on its instant access copy
# (dataCopy instantAccessMinutes, takenUtc), and rollback.keptDataDisks. v21:
# SAFETY-CMK-1's encryption of each disk (captured.vmConfig.osDisk and
# dataDisks[]: encryptionType, diskEncryptionSetId). v22: ROLLBACK-DISKS-FIRST-1's
# safety.rollbackDisksBeforeMove (and earlierCopies[].rollbackDisksBeforeMove), the disks made from
# the first copies for the rollback before the move changes anything. v23:
# RECOVER-ALL-DISKS-1's recovery.dataDisks and recovery.keptDataDisks, the data
# disks a rebuild from the copy made and kept. v24: ROLLBACK-CRG-1's
# captured.vmConfig.capacityReservationGroupId, the capacity reservation group
# the machine was in, and rollback.reservationGroupNotBack. v25:
# SWAP-REFUSED-AFTER-STOP-1's swapPending, the data disks a refused swap left
# with the machine stopped. v26: MADE-DISK-RECORD-1's restoreDisks (every disk
# Restore this machine made, recorded the moment it exists) and usedUtc and
# deletedUtc on each entry of rollbackDisksDuringRollback, recoveryDisks and restoreDisks.
# v27: RESTORE-END-JOB-1's putBackJob, the checkpoint of a Restore this machine
# or a Rebuild this machine, so one whose job stops resumes from its last step.
# v28: FINISH-EMPTY-LUN-PROOF-1's swapPending.swaps[].snapshotId, the copy each
# disk that waits was made from, which Finish checks before it attaches the disk
# to a LUN with no disk.
# v29: FINISH-KEPT-DISKS-1's swapPending.kept, the data disks a put-back keeps as
# they are by design, in the same write as the swaps, so the record Finish reads
# accounts for every data disk on its own.
# v30: IDENTITY-LOSS-1's putBackJob.options.acceptIdentityLoss, the person's
# acceptance that a restore which rebuilds the machine deletes its
# system-assigned identity, so a resume asks the same question of it.
# v31: REBUILD-PROPS-1's capture fields - the purchase plan (of the machine,
# and of its OS disk), the patch settings, user data present, the dedicated
# host and host group, the Spot eviction policy and maximum price,
# hibernation, the OS disk caching, Write Accelerator and each interface's
# delete option - which every rebuild puts back, or a rebuild move refuses.
# v32: FINISH-NO-RESTORE-RECORD-1's restore.operationId and
# swapPending.operationId, the restore's engine operation, so Finish the
# restore adds to the record of the restore that left the swap and never to an
# earlier one; and restore.writtenByFinish, set when Finish the restore wrote
# the record of a restore whose job stopped before it wrote it.
# v33: FINISH-END-JOB-1's putBackJob kind finish, options.finishes and prior -
# Finish the rollback and Finish the restore keep the checkpoint a restore
# keeps, so one whose job stops is started again, with the record it stands
# over kept whole.
# v34: NO-PLAN-SCOPE-1 - the capture no longer writes purchasePlan, of the
# machine or of its OS disk. A machine with a Marketplace purchase plan is
# outside the scope of this tool: Checking stops it, so no rebuild sends one.
# v35, v36: SQLVM-REREAD-1 and DCR-READ-1 fields for a rebuild, gone at v42.
# v38: FINISH-EMPTY-LUN-WORDS-1's swapPending.swaps[].lunHolds - what is on the
# LUN of a swap that is left, as the product last found it - and
# FINISH-TEMP-DISK-LEFT-1's swapPending.swaps[].oldTemporary.
# v39: POWER-AFTER-MOVE-1's powerReturnPending - the checkpoint of the return
# to the power state Checking found, after a move passed Verifying.
# v40: RESTORE-EARLIER-DELETE-1's restore.earlierDisksDeleted - each earlier
# managed disk of a restore that Delete these disks deleted, recorded the
# moment it is deleted, so the panel's list empties.
# v41: ROLLBACK-ORIGINALS-LEFT-1's rollbackOriginals - each disk a rollback
# swapped off the machine (the disks it had before the migration), kept until
# a person deletes them with Delete these disks.
# v42: OLD-VERSION-READERS-REMOVE-1 - no captured.sqlVirtualMachine and no
# captured.dataCollectionRuleAssociations in the contract. No writer gave them
# since the rebuild was removed, and nothing is public before 1.0, so no store
# holds a document with one.
# v43: RESTORE-ORIGINAL-DELETE-RESTART-1's putBackJob.originalKept and the steps
# originalKept, originalBack and originalStarted - a restore that keeps the
# names puts the original OS disk back when Azure refuses to delete it.
# v44: VERIFY-HOST-HIBERNATION-UNUSED-1 - the capture no longer writes hostId,
# hostGroupId or hibernationEnabled, and Verifying no longer compares them.
# Checking stops a machine on a dedicated host or with hibernation enabled
# before the capture.
# v45: OLD-REBUILD-RESTORE-READERS-1 - no recovery, recoveryDisks, restore.rebuilt,
# putBackJob kind rebuild, putBackJob.rebuild, its options or its steps, and no
# disk type change by recover. No flow of this version rebuilds a machine.
# v46: RENAME-WAY-BACK-1 - the rollback disks are named for when they were made:
# safety.rollbackDisksBeforeMove (and in earlierCopies[]), the top-level
# rollbackDisksDuringRollback, and the stop reason rollbackDisksBeforeMoveNotMade.
# docs/schema-migrations.md names the old names; no reader of them (nothing is public before 1.0).
# v47: OLD-VERSION-READERS-REMOVE-4 - no rollback.sizeAfter; captured.vmConfig
# needs captured.original beside it, and every capture holds
# capacityReservationGroupId and patchSettings. The engine reads no record
# without them: a put-back of such a record stops before anything changes.
# v48: OLD-STATE-READERS-FINISH-1 - Read-VmfStateDoc reads this version only,
# and no writer raises a document's version field by field. A swap record
# (swapPending) holds kept, and each row its snapshotId and lunHolds: Finish
# stops before any change on a record without them, and never attaches a disk
# on a weaker proof. captured.putBackRetirement holds size and its dates only,
# and the capture contract names no purchasePlan.
# v49: VOLUMES-ONLINE-1 - rollbackPending.volumes and putBackJob.volumes, the
# check of the volumes inside the machine after a put-back, kept before the
# machine returns to its power state so a resume never asks a stopped machine.
# v50: VOLUMES-RETRY-CHECK-1 - volumesCheckOwed, the check of the volumes that
# the next retry owes after a put-back found a volume not mounted or could not
# check; the retry runs it first, at Checking, before it takes new copies.
$script:VmfStateDocSchemaVersion = 51

function Write-VmfStateDoc {
    <#
    .SYNOPSIS
        Persist a VM's state document atomically. Enforces required fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Document
    )

    foreach ($req in @('schemaVersion', 'runId', 'vmId', 'state', 'history')) {
        $val = if ($Document -is [hashtable] -or $Document -is [System.Collections.Specialized.OrderedDictionary]) { $Document[$req] } else { $Document.$req }
        if ($null -eq $val) { throw "State document missing required field '$req'." }
    }
    $vmId = if ($Document -is [hashtable] -or $Document -is [System.Collections.Specialized.OrderedDictionary]) { $Document['vmId'] } else { $Document.vmId }
    Write-VmfStoreJson -RunPath $RunPath -RelPath ('state/' + (Get-VmfVmKey -VmId $vmId) + '.json') -Document $Document
}

function Add-VmfStateTransition {
    <#
    .SYNOPSIS
        Append a history entry and set the new state, then persist atomically.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$NewState,
        [Parameter(Mandatory)][ValidateSet('ok', 'retry', 'fail', 'skip')][string]$Outcome,
        [Parameter()][double]$DurationSec = 0,
        [Parameter()][string]$Detail,
        [Parameter()][string]$EvidenceRef,
        # RETRY-1: names WHY this stop happened, so the dashboard can say what
        # to do about it instead of showing raw engine text.
        [Parameter()][string]$ReasonCode,
        # FAIL-1: where it left the MACHINE. Independent of the reason - the
        # same cause can leave a machine untouched at precheck or restored
        # after a rollback - so the branch that knows records it rather than
        # the dashboard inferring it from the code.
        [Parameter()][ValidateSet('untouched', 'restored', 'changed')][string]$MachineState,
        # PREP-ROLLBACK-1 (review F2): fields removed IN THE SAME WRITE as the
        # transition - the rollback marker goes with the stop that ends it, so
        # no moment exists where neither says what the machine is doing.
        [Parameter()][string[]]$ClearProperty = @(),
        # FINISH-END-JOB-1: a change to the document IN THE SAME WRITE, given
        # the document - a finish's checkpoint ends with the stop it records.
        [Parameter()][scriptblock]$Amend,
        # POWER-ONLY-CHANGED-1 (v37): the stop left the machine changed ONLY in
        # its power state - Azure refused to return it to the power state found
        # (deallocated, stopped, or running), at every try. Named on the entry, so a retry is not held for
        # it (Test-VmfRetryHeld) and puts the power state back first.
        [Parameter()][ValidateSet('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')][string]$PowerNotPutBack,
        # POWER-ONLY-CHANGED-1: this entry is the line of a put-back that
        # worked, so it may say untouched (POWER-AFTER-MOVE-1: or restored)
        # after a power state not put back.
        [Parameter()][switch]$PowerPutBack
    )

    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { throw "No state document exists for '$VmId' - initialize it first." }
    # POWER-ONLY-CHANGED-1: never untouched while the power state differs from
    # the one found. After a stop that could not put it back, only the line of
    # a put-back that worked says untouched; any other stop that says so - a
    # refusal at Checking before the put-back, Stop this migration - says
    # changed, with the power state still owed.
    if ($PowerNotPutBack -and $MachineState -ne 'changed') {
        throw "A power state the product could not return to is recorded only on a stop that left the machine changed, not '$MachineState'."
    }
    # POWER-AFTER-MOVE-1: and never restored - a rollback or a restore says
    # restored only when the power state is as it was found too.
    if ($MachineState -in @('untouched', 'restored') -and -not $PowerPutBack) {
        $owed = Get-VmfPowerOwed -Doc $doc
        if ($owed) { $MachineState = 'changed'; $PowerNotPutBack = $owed }
    }
    foreach ($name in @($ClearProperty | Where-Object { $_ })) {
        if ($doc.PSObject.Properties[$name]) { $doc.PSObject.Properties.Remove($name) }
    }
    if ($Amend) { & $Amend $doc }

    $entry = [ordered]@{
        tsUtc   = (Get-Date).ToUniversalTime().ToString('o')
        state   = $NewState
        outcome = $Outcome
    }
    if ($DurationSec -gt 0) { $entry.durationSec = $DurationSec }
    if ($Detail) { $entry.detail = $Detail }
    if ($EvidenceRef) { $entry.evidenceRef = $EvidenceRef }
    if ($ReasonCode) { $entry.reasonCode = $ReasonCode }
    if ($MachineState) { $entry.machineState = $MachineState }
    if ($PowerNotPutBack) {
        $entry.powerNotPutBack = $PowerNotPutBack
    }

    $doc.state = $NewState
    $doc.history = @($doc.history) + @([pscustomobject]$entry)
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    return $doc
}

function New-VmfStateDoc {
    <#
    .SYNOPSIS
        Create the initial PLANNED state document for a VM in a run.
        Idempotent: returns the existing doc if one is already present.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$Wave
    )

    $existing = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if ($existing) { return $existing }

    $doc = [ordered]@{
        schemaVersion = $script:VmfStateDocSchemaVersion
        runId         = $RunId
        vmId          = $VmId
        state         = 'PLANNED'
        attempts      = @{}
        history       = @(
            [ordered]@{
                tsUtc   = (Get-Date).ToUniversalTime().ToString('o')
                state   = 'PLANNED'
                outcome = 'ok'
            }
        )
    }
    if ($Wave) { $doc.wave = $Wave }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
}
