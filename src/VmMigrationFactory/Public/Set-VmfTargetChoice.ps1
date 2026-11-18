function Set-VmfTargetChoice {
    <#
    .SYNOPSIS
        ADVISOR-1: save the target a person chose for each machine -
        target-choices.json, beside the reviewed assessment.
    .DESCRIPTION
        The options come from New-VmfTargetAdvice. This records the choice
        made from them: which option, for which machine, whether it is the
        one the machine started on under the migration's default or a
        person's change, and who saved it. New-VmfPlan plans each machine on
        its choice.

        Only a SUPPORTED option can be saved - the same facts the screen
        shows decide it, so the screen and this cannot disagree. Nothing is
        saved when any choice is refused.

        Two guards against saving over something unseen, the way wave
        acceptance guards the plan (PLANVER-2): the caller quotes back the
        document versions the service issued with what it read - the options,
        and the targets already saved - and a version that no longer matches
        is refused with 409. The versions are computed here from the stored
        text by Get-VmfDocumentVersion, never re-derived by a caller.

        Store-only: it reads and writes the run store and calls no Azure API,
        so the service can run it.
    .PARAMETER Choices
        One per machine: @{ vmId = '...'; option = 'v5'|'v6'|'v7' }. A
        machine left out has no target and is not moved. REBUILD-PICKER-1: a
        choice may name its method (in-place, or preview for the in-place
        upgrade with the preview feature); it must be the method of the
        chosen size. The file records that method in every case.
        REBUILD-REMOVE-PLAN-1: no size is a rebuild, so a choice that names
        rebuild is refused.
    .PARAMETER Default
        The migration's default when the targets were saved, a Microsoft
        lifecycle stage: current (v6) or extended (v5).
    .PARAMETER ExpectedAdviceVersion
        The document version of target-advice.json the choices were made from.
    .PARAMETER ExpectedChoicesVersion
        The document version of the target-choices.json the page read, or
        empty when there was none.
    .PARAMETER ExpectedMachinesVersion
        MACHINE-PICK-1: the document version of the machine-choices.json the
        page read. Only a chosen machine may have a target, and the targets
        record the version of the list they were saved against. With no list,
        nothing is saved (TARGETS-NO-LIST-1).
    .PARAMETER KernelDefault
        MANA-LINUX-KERNEL-1: the migration's default for a Linux machine whose
        target can give MANA, when its kernel has no MANA driver - stop (stop
        and ask). KERNEL-DEFAULT-EARLIER-1: the only value; the targets step
        offers no default. A choice may name its own `kernel` (stop or update);
        only a Linux machine whose chosen size can give MANA may
        (Test-VmfKernelUpdateOffered, from the same facts the screen shows).
    .PARAMETER OnBehalfOf
        @{ Identity; TenantId } of the signed-in user. The service passes it;
        a command-line caller omits it and gets their Azure sign-in.
    .EXAMPLE
        Set-VmfTargetChoice -RunPath ./runs/scan-1 -Default current -ExpectedAdviceVersion $v -Choices @(@{ vmId = $id; option = 'v5' })
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Choices,
        [Parameter(Mandatory)][ValidateSet('current', 'extended')][string]$Default,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedAdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ExpectedChoicesVersion = '',
        [Parameter()][AllowEmptyString()][string]$ExpectedMachinesVersion = '',
        [Parameter()][ValidateSet('stop')][string]$KernelDefault = 'stop',
        [Parameter()][hashtable]$OnBehalfOf
    )

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if ($manifest -and [string]$manifest.kind -eq 'migration') {
        throw "400: '$($manifest.runId)' is a migration, not an assessment. Targets are chosen on the assessment."
    }
    # Asked before it is read: Read-VmfTextDocument throws on a missing file.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'target-advice.json')) {
        throw '400: The target options for this assessment are not written yet. They are made when the review is approved; start them again if they did not appear.'
    }
    $adviceText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'target-advice.json')
    if ((Get-VmfDocumentVersion -Text $adviceText) -ne $ExpectedAdviceVersion) {
        throw '409: The target options changed since this page read them. Load the page again, then choose the targets again.'
    }
    $advice = $adviceText | ConvertFrom-Json -Depth 30
    # An older options file names its defaults differently. Refused by name, so
    # a choice is never saved against a default it cannot read.
    if ([int]$advice.schemaVersion -ne (Get-VmfTargetAdviceSchemaVersion)) {
        throw '409: These target options were made by an older version. Make the target options again, then choose the targets.'
    }

    $existingVersion = ''
    $existingBy = 'somebody'
    if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'target-choices.json') {
        $existingText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'target-choices.json')
        $existingVersion = Get-VmfDocumentVersion -Text $existingText
        $existingBy = [string](($existingText | ConvertFrom-Json -Depth 20).savedBy.identity)
    }
    if ($existingVersion -ne $ExpectedChoicesVersion) {
        throw "409: $existingBy saved the targets after this page read them. Load the page again to see them."
    }
    # MACHINE-PICK-1: the machines the page offered targets for. The wizard
    # saves the list before any target (TARGETS-NO-LIST-1), so an assessment
    # with no list takes no target.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'machine-choices.json')) {
        throw '400: Choose the machines for this migration first. Then choose their targets.'
    }
    $machinesText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'machine-choices.json')
    $machinesVersion = Get-VmfDocumentVersion -Text $machinesText
    $chosen = @{}
    foreach ($id in @(($machinesText | ConvertFrom-Json -Depth 10).machines)) { $chosen[[string]$id] = $true }
    if ($machinesVersion -ne $ExpectedMachinesVersion) {
        throw '409: The machines for this migration changed after this page read them. Load the page again, then choose the targets again.'
    }

    $byId = @{}
    foreach ($m in @($advice.machines)) { $byId[[string]$m.vmId] = $m }
    $seen = @{}
    $saved = foreach ($c in @($Choices)) {
        $vmId = [string]$c.vmId
        $option = [string]$c.option
        $machine = $byId[$vmId]
        if (-not $machine) { throw "400: The machine '$vmId' is not in this assessment." }
        if ($seen.ContainsKey($vmId)) { throw "400: The machine '$($machine.name)' is named more than once." }
        if (-not $chosen.ContainsKey($vmId)) {
            throw "400: The machine '$($machine.name)' is not chosen for this migration. Choose it in the first step, then give it a target."
        }
        $seen[$vmId] = $true
        $o = @($machine.options) | Where-Object { [string]$_.option -eq $option } | Select-Object -First 1
        if (-not $o -or -not $o.supported) {
            $why = if ($o) { @($o.notSupported) -join ', ' } else { 'not an option' }
            throw "400: The machine '$($machine.name)' cannot take $option ($why). Choose one of its supported options."
        }
        # OLD-SKU-1B: a size, when named, must be one of THIS option's size
        # choices - the facts the screen showed. The option's own target size
        # is the same as naming none.
        # A hashtable (the service) or an object (a script): a hashtable's keys
        # are not in PSObject.Properties, so the value is read directly.
        $size = if ([string]$c.size) { [string]$c.size } else { $null }
        if ($size -and $size -ne [string]$o.targetSize) {
            $offered = @(@($o.sizeChoices) | ForEach-Object { [string]$_.size })
            if ($offered -notcontains $size) {
                throw "400: The machine '$($machine.name)' cannot take the size $size on $option. Choose one of its size choices."
            }
        }
        # OLD-SKU-1C: Premium SSD for the OS disk (os) or every disk (all),
        # only on a size that takes it - the size this machine will have.
        $disks = if ([string]$c.disks) { [string]$c.disks } else { 'keep' }
        if ($disks -notin @('keep', 'os', 'all', 'os-standard-ssd')) { throw "400: The machine '$($machine.name)' has an unknown disk choice '$disks'. Choose keep, os, all or os-standard-ssd." }
        # HDD-OS-1: Standard SSD for the OS disk, on any size - every size
        # takes Standard SSD - and only where the scan read the OS disk as
        # Standard HDD. Unknown is not a yes: there is then nothing to change.
        if ($disks -eq 'os-standard-ssd') {
            $osType = if ($machine.PSObject.Properties['osDiskType']) { [string]$machine.osDiskType } else { '' }
            if (-not $osType) {
                throw "400: The scan did not read the type of the OS disk of '$($machine.name)', so Standard SSD cannot be chosen for it. Keep the disk types of this machine, or scan again."
            }
            if ($osType -ne 'Standard_LRS') {
                throw "400: The OS disk of '$($machine.name)' is not Standard HDD: its type is $osType. Keep the disk types of this machine."
            }
        }
        elseif ($disks -ne 'keep') {
            $sizeFacts = if ($size -and $size -ne [string]$o.targetSize) { @($o.sizeChoices) | Where-Object { [string]$_.size -eq $size } | Select-Object -First 1 } else { $o }
            if ($sizeFacts.premiumDisks -ne $true) {
                $sizeName = if ($size) { $size } else { [string]$o.targetSize }
                throw "400: The size $sizeName does not take Premium SSD disks, or Azure does not say. Keep the disk types of '$($machine.name)', or choose a size with an s after its number, such as D4s_v5."
            }
        }
        # MANA-LINUX-KERNEL-1: what to do when the kernel has no MANA driver,
        # for this machine alone. Only where the question can come up: a
        # Linux machine whose chosen size can give MANA - the facts the
        # screen shows (the option's, or the size choice's).
        $kernel = if ([string]$c.kernel) { [string]$c.kernel } else { $null }
        if ($kernel -and $kernel -notin @('stop', 'update')) {
            throw "400: The machine '$($machine.name)' has an unknown kernel choice '$kernel'. Choose stop or update."
        }
        if ($kernel -eq 'update') {
            $sizeChoice = if ($size -and $size -ne [string]$o.targetSize) { @($o.sizeChoices) | Where-Object { [string]$_.size -eq $size } | Select-Object -First 1 } else { $null }
            $mana = if ($sizeChoice) { $sizeChoice.acceleratedNetworking.mayUseMana } else { $o.acceleratedNetworking.mayUseMana }
            # ADVISE-AN-1: and never where the VM agent reports a release
            # Microsoft does not list for MANA - no update can give it MANA.
            $rel = if ($machine.PSObject.Properties['linuxRelease']) { $machine.linuxRelease } else { $null }
            if ($rel -and [string]$rel.source -eq 'agent' -and [string]$rel.mana -eq 'unlisted') {
                throw "400: The kernel of '$($machine.name)' is not updated: the Azure Linux Agent reports $($rel.distroId) $($rel.version), and Microsoft does not list that release for MANA. A kernel update does not change the release."
            }
            if (-not (Test-VmfKernelUpdateOffered -Os ([string]$machine.os) -Move ([string]$o.move) -MayUseMana $mana)) {
                throw "400: The kernel of '$($machine.name)' cannot be updated by this product. Only a Linux machine whose target can use MANA has this choice."
            }
        }
        # REBUILD-PICKER-1: the method of the chosen size, from the facts the
        # screen showed (the size choice's preview, else the option's). A
        # request may name it, and then it must be that method: the person
        # chose what the screen said. REBUILD-REMOVE-PLAN-1: the method is
        # preview - the in-place upgrade with the preview feature
        # VMTempDiskResizePreview - where the size changes the kind of
        # temporary disk of a Windows machine, and in-place for every other
        # size. Nothing is a rebuild. The save is store-only and reads no Azure
        # API: Checking reads the feature before any change.
        $methodFacts = if ($size -and $size -ne [string]$o.targetSize) { @($o.sizeChoices) | Where-Object { [string]$_.size -eq $size } | Select-Object -First 1 } else { $o }
        $method = Get-VmfMoveMethod -Preview:([bool]($methodFacts -and $methodFacts.PSObject.Properties['preview'] -and $methodFacts.preview -eq $true))
        $asked = if ([string]$c.method) { [string]$c.method } else { $null }
        if ($asked -and $asked -ne $method) {
            $sizeName = if ($size) { $size } else { [string]$o.targetSize }
            throw "400: The machine '$($machine.name)' cannot take $sizeName on $option by the method $asked. The method of that size is $method. Choose the target again."
        }
        $started = [string]$machine.start.$Default
        [ordered]@{
            vmId = $vmId
            option = $option
            source = $(if ($started -eq $option -and (-not $size -or $size -eq [string]$o.targetSize) -and $disks -eq 'keep') { 'default' } else { 'person' })
            started = $(if ($started) { $started } else { $null })
            size = $(if ($size -and $size -ne [string]$o.targetSize) { $size } else { $null })
            disks = $(if ($disks -eq 'keep') { $null } else { $disks })
            # REBUILD-PICKER-1 (v7): the method of the move. REBUILD-REMOVE-PLAN-1
            # (v8): in-place or preview, never rebuild.
            method = $method
            kernel = $kernel
        }
    }

    # REBUILD-REMOVE-PLAN-1: no machine waits for a choice any more. IDENTITY-LOSS-1
    # refused a save without a choice for a machine whose start a rebuild would
    # take its system-assigned identity from (decide reason identity).

    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }
    $doc = [ordered]@{
        # MANA-LINUX-KERNEL-1 (v5): the kernel default and each machine's own.
        # REBUILD-PICKER-1 (v7): the method of each choice.
        # REBUILD-REMOVE-PLAN-1 (v8): the method is in-place or preview.
        # TARGETS-NO-LIST-1 (v9): the list of machines is always named.
        schemaVersion = Get-VmfTargetChoicesSchemaVersion
        assessmentId = [string]$advice.assessmentId
        assessmentHash = $advice.assessmentHash
        adviceVersion = $ExpectedAdviceVersion
        # MACHINE-PICK-1 (v4): New-VmfPlan refuses targets saved against a
        # list that was saved again since.
        machinesVersion = $machinesVersion
        default = $Default
        kernelDefault = $KernelDefault
        savedBy = [ordered]@{ identity = [string]$who.Identity; tenantId = $(if ($who.TenantId) { [string]$who.TenantId } else { $null }) }
        savedUtc = (Get-Date).ToUniversalTime().ToString('o')
        choices = @($saved)
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'target-choices.json' -Document $doc -Depth 20

    $changed = @($saved | Where-Object { $_.source -eq 'person' }).Count
    # Out of the machines chosen for this migration.
    $none = $chosen.Count - @($saved).Count
    # STEP-LOG-4: written after the targets are saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'targets' -Outcome ok `
        -Detail ("{0} saved the targets for {1} machine(s): {2} changed from the default, {3} with no target." -f $who.Identity, @($saved).Count, $changed, $none)

    [pscustomobject]@{
        Saved    = @($saved).Count
        Changed  = $changed
        NoTarget = $none
    }
}
