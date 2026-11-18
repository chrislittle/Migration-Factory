function Get-VmfPlannedAcceleratedNetworking {
    <#
    .SYNOPSIS
        AN-PLAN-1: the accelerated networking setting the plan gives a machine,
        so that accepting its wave's settings is the approval.
    .DESCRIPTION
        Microsoft requires accelerated networking on the Intel D-family and
        E-family v5 sizes (E since 2026-10-01, DRIFT-5) and says to turn it on
        before the resize. When the target is one
        of those and the machine's PRIMARY interface has it off, the plan says
        'ensureOn'. The wave's settings name the machine where they are
        accepted, and the acceptance is bound by hash to every machine's
        settings - so a person approves it once, at plan time, instead of the
        move stopping for it after the first safety copy.

        Anything this cannot read returns nothing, and the engine decides live
        as before - it still stops for an approver. A multi-interface machine
        known only by a count, with some on, is one of those: the primary may be
        the one that is off, and 'ensureOn' is about the primary (NIC-1).
    .OUTPUTS
        'ensureOn', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Vm,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetSize
    )
    if (-not $Vm -or -not $TargetSize) { return $null }
    if ((Test-VmfTargetRequiresAcceleratedNetworking -SizeName $TargetSize) -ne $true) { return $null }

    $has = { param($name) $Vm.PSObject.Properties[$name] -and $null -ne $Vm.$name }
    $primaryOff = if (& $has 'primaryNicAccelerated') { -not [bool]$Vm.primaryNicAccelerated }
                  elseif (& $has 'acceleratedNicCount') { [int]$Vm.acceleratedNicCount -eq 0 }
                  else { $null }
    if ($primaryOff -eq $true) { 'ensureOn' } else { $null }
}

function Get-VmfPlannedAnOutcome {
    <#
    .SYNOPSIS
        WAVE-AN-NAMES-1: does this plan entry's move turn accelerated
        networking on for the primary network interface?
        @{ turnsOn = $true|$false|$null; unknownWhy = 'kernel'|'nics'|$null },
        or $null for an entry that does not move.
    .DESCRIPTION
        The wave settings named only the machines whose plan entry SETS
        ensureOn - the sizes that require it (AN-PLAN-1). Every other move but
        a SCSI reversion has no setting, and the engine's default is ensureOn
        (Get-VmfPolicy), so the move turned the primary on and the row said
        None (the lab run of 2026-10-11: two Bsv2 moves).

        The answer, from the entry itself, in the engine's order:
          preserve             nothing turns on - the plan keeps it as it is
                               (on a size that can give MANA Checking refuses
                               it for a primary that is off,
                               AN-MANA-DRIVER-RULE-1);
          a SCSI reversion     with no setting, preserve: nothing turns on;
          the primary not read unknown, 'nics' - PRECHECK reads the
                               interfaces (AN-PRIMARY-1, never a no);
          the primary on       nothing turns on - it is on already;
          ensureOn             it turns on (a size that requires it, or a
                               decision);
          no setting           the target advice's own rule (Get-VmfAnTurnsOn):
                               it turns on. AN-MANA-DRIVER-RULE-1: a Linux
                               kernel with no MANA driver no longer keeps it
                               off - the move stops in Preparing instead - so
                               the answer 'kernel' (unknown) is never given now.
        The pages read this record and never work it out again. Pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowNull()]$PlanEntry)
    if (-not $PlanEntry -or [string]$PlanEntry.path -ne 'A') { return $null }
    $size = [string]$PlanEntry.target.size
    if (-not $size) { return $null }
    $say = { param($On, $Why) [ordered]@{ turnsOn = $On; unknownWhy = $Why } }
    $set = if ($PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties['acceleratedNetworking']) { [string]$PlanEntry.policy.acceleratedNetworking } else { '' }
    $kind = Get-VmfMoveKind -PlanEntry $PlanEntry
    if ($set -eq 'preserve') { return (& $say $false $null) }
    if (-not $set -and $kind -eq 'scsi-reversion') { return (& $say $false $null) }
    $vm = $PlanEntry.assessment
    if (-not $vm) { return (& $say $null 'nics') }
    $uses = Test-VmfUsesAcceleratedNetworking -Vm $vm
    if ($null -eq $uses) { return (& $say $null 'nics') }
    if ($uses) { return (& $say $false $null) }
    if ($set -eq 'ensureOn') { return (& $say $true $null) }
    $on = Get-VmfAnTurnsOn -Vm $vm -TargetSize $size -Move $kind -Required (Test-VmfTargetRequiresAcceleratedNetworking -SizeName $size)
    if ($null -eq $on) { return (& $say $null 'kernel') }
    & $say ([bool]$on) $null
}

function Set-VmfPlannedAnOutcome {
    <#
    .SYNOPSIS
        WAVE-AN-NAMES-1: write Get-VmfPlannedAnOutcome onto one plan entry as
        acceleratedNetworkingOutcome (plan-entry v20), or take the record away
        from an entry that does not move.
    .DESCRIPTION
        Every writer that changes what decides the answer asks this for the
        entry it changes: the plan (New-VmfPlan), a target changed in the wave
        editor (Set-VmfMachineTarget) and a decision that sets accelerated
        networking (Resolve-VmfDecision). A wave save writes no setting the
        answer reads. The entry is read as the plan stores it: a dictionary is
        put through JSON first, so the answer is the one a later reader gets.
        An entry that gains the record says v20.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$PlanEntry)
    if (-not $PSCmdlet.ShouldProcess([string]$PlanEntry.vmId, 'record whether the move turns accelerated networking on')) { return }
    $asRead = if ($PlanEntry -is [System.Collections.IDictionary]) { $PlanEntry | ConvertTo-Json -Depth 24 | ConvertFrom-Json -Depth 24 } else { $PlanEntry }
    $outcome = Get-VmfPlannedAnOutcome -PlanEntry $asRead
    if ($PlanEntry -is [System.Collections.IDictionary]) {
        if ($outcome) { $PlanEntry['acceleratedNetworkingOutcome'] = $outcome; $PlanEntry['schemaVersion'] = Get-VmfPlanSchemaVersion }
        elseif ($PlanEntry.Contains('acceleratedNetworkingOutcome')) { $PlanEntry.Remove('acceleratedNetworkingOutcome') }
        return
    }
    $had = $PlanEntry.PSObject.Properties['acceleratedNetworkingOutcome']
    if (-not $outcome) {
        if ($had) { $PlanEntry.PSObject.Properties.Remove('acceleratedNetworkingOutcome') }
        return
    }
    # The same answer is left where it is. Add-Member -Force moves a property
    # to the end, and a plan text changed with nothing changed voids the
    # wave's approval (WAVE-APPROVE-1) - a decision made again must not.
    if ($had -and (($had.Value | ConvertTo-Json -Compress) -ceq ($outcome | ConvertTo-Json -Compress))) { return }
    if ($had) { $PlanEntry.acceleratedNetworkingOutcome = $outcome }
    else { $PlanEntry | Add-Member -NotePropertyName acceleratedNetworkingOutcome -NotePropertyValue $outcome }
    $current = Get-VmfPlanSchemaVersion
    if (-not $PlanEntry.PSObject.Properties['schemaVersion']) { $PlanEntry | Add-Member -NotePropertyName schemaVersion -NotePropertyValue $current }
    elseif ([int]$PlanEntry.schemaVersion -ne $current) { $PlanEntry.schemaVersion = $current }
}