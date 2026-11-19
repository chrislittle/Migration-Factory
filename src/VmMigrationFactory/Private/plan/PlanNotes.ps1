function Get-VmfPlanEntryNotes {
    <#
    .SYNOPSIS
        PLAN-NOTES-TARGET-1: the notes of one plan entry that follow from its
        target. Pure.
    .DESCRIPTION
        Every plan writer that sets a machine's target asks this, so a target
        changed in the wave editor (Set-VmfMachineTarget) has the notes a plan
        made on that target (New-VmfPlan) has. Before it, the wave editor wrote
        the retirement warning alone, and the other notes were lost.
        In this order:
          * the reason, for a machine with no target (why it is not moved), or
            for a size the catalog could not verify;
          * why each size tried before the target was not taken
            (Get-VmfSizeNotTakenNote, SIZE-FALLTHROUGH-NOTE-1);
          * the retirement warning of the size a rollback returns to, for a
            machine the plan moves (Get-VmfRetirementWarning).
        MANUAL-REVIEW-1: no note for a machine already on NVMe. It said that no
        lab run had moved one, which a person cannot act on.
        The MANA driver note is not one of them: Set-VmfManaDriverDownloadNote
        adds it after, from the whole entry. And no kernel note: since
        AN-MANA-DRIVER-RULE-1 no plan moves a machine whose release Microsoft
        does not list for MANA to a size that can give MANA.
    .PARAMETER Mapping
        The target as Resolve-VmfEntryTarget gives it: Target and Reason.
    .PARAMETER Assessment
        The machine as the scan read it: sourceSize and diskController. A plan
        entry does not carry diskController, so the wave editor passes the one
        in the target options saved with the plan.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Mapping,
        [Parameter(Mandatory)][AllowNull()]$Assessment,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Controller,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Path
    )
    $target = if ($Mapping) { [string]$Mapping.Target } else { '' }
    $reason = if ($Mapping) { [string]$Mapping.Reason } else { '' }
    $sourceSize = if ($Assessment) { [string]$Assessment.sourceSize } else { '' }
    $notes = @(
        if (-not $target) { $reason }
        elseif ($reason -match 'could not be verified') { $reason }
        # SIZE-FALLTHROUGH-NOTE-1: why a size tried before the target was not
        # taken - most often the d size, so the temporary disk goes.
        if ($target) { Get-VmfSizeNotTakenNote -NotTaken @($Mapping.NotTaken) -Target $target }
        if ($Path -eq 'A') { Get-VmfRetirementWarning -Size $sourceSize }
    )
    # Callers wrap the answer in @(): no note is an empty list.
    $notes | Where-Object { $_ } | ForEach-Object { [string]$_ }
}

function Get-VmfSizeNotTakenNote {
    <#
    .SYNOPSIS
        SIZE-FALLTHROUGH-NOTE-1: one note that says which size the default
        transform tried before the target, and why it did not take it. Pure.
    .DESCRIPTION
        The default transform tries the d size first for a machine with a
        temporary disk, then the size without one (Get-VmfDefaultSizeCandidates).
        Get-VmfTargetSize records each size it did not take and the gate, as a
        code with its facts (NotTaken). The plan said nothing, and on Windows
        the size without a temporary disk changes the kind of temporary disk,
        which makes the move the in-place upgrade (Preview). The targets step
        says the same from the same codes (sizesNotTaken, wizard.js
        tNotTakenText).
    .PARAMETER NotTaken
        The NotTaken list of a Get-VmfTargetSize result. Empty or absent gives
        no note: a plan or an advice written before this item has none.
    .OUTPUTS
        string, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$NotTaken,
        [Parameter(Mandatory)][string]$Target
    )
    $parts = @(foreach ($n in @($NotTaken | Where-Object { $_ })) {
        $size = [string]$n.size
        $why = switch ([string]$n.why) {
            'not-listed' { 'Microsoft does not list it.' }
            'not-in-region' { 'this region does not offer it.' }
            'not-approved' { 'it is not a target size that the product offers.' }
            'gen1-no-size' { 'it does not take Generation 1 machines.' }
            'too-few-nics' { "it holds $($n.holds) network interfaces, and this machine has $($n.needs)." }
            'too-few-data-disks' { "it holds $($n.holds) data disks, and this machine has $($n.needs)." }
            'smaller-than-source' { "it is smaller: it has $($n.vcpus) vCPUs and $($n.memoryGB) GiB, and this machine has $($n.sourceVcpus) vCPUs and $($n.sourceMemoryGB) GiB." }
            'shape-unknown' { 'the catalog of this region does not give its vCPUs and memory.' }
            'one-accelerated-nic' { "it has $($n.vcpus) vCPUs, and Azure allows accelerated networking on one network interface only of such a size. This machine has accelerated networking on $($n.needs) network interfaces." }
            default { $null }
        }
        if ($why) { "The product did not use $size because $why" }
    })
    if (-not $parts.Count) { return }
    ($parts -join ' ') + " The target is $Target."
}