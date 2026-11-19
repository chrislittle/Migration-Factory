# WAVE-LEVER-OVERRIDE-1: a wave save never writes over a machine's own answer.
#
# A decision's answer is written to ONE machine (Resolve-VmfDecision puts, for
# example, onDDataFound = proceed on that plan entry). The wave editor drew each
# wave's settings from its FIRST machine and sent all seven for every wave on
# every save, and Set-VmfWavePlan wrote each one wherever it differed. So any
# save, of any wave, wrote the card's value over that machine's answer - or, when
# the decided machine was the first, spread its answer to the whole wave - and
# the write cleared the wave's acceptance and quota check, and (since
# WAVE-SAVE-FALSE-1) every approval.
#
# Nothing recorded that a value came from a decision: the state history and the
# activity say it in words, and an acceptance amendment exists only when the
# acceptance was current. So plan-entry v17 records it (`decisions`), and the
# rule is:
#
#   * the page sends, for each wave, what its card shows AND which settings the
#     person changed on it, each with the value the card showed when it was
#     drawn (`changed`);
#   * a machine that STAYS in its wave is written only for a changed setting,
#     and only when it holds the value the card showed - a machine holding
#     another value has its own (the card names it), and it keeps it;
#   * a machine JOINING a wave takes the card's settings, because that is what
#     joining a wave means;
#   * and never over a setting a decision recorded for that machine.
#
# Every machine that keeps its own value is named - in the result, and in the
# activity. A layout with no `changed` (the command line, or a page from before
# this) sets the wave: every setting it names is written, except over a decision.

# The settings of a wave, in the order the wave editor shows them.
# REBUILD-REMOVE-ACCEPT-1: onSystemAssignedIdentity is gone - it chose what a
# rebuild did to a system-assigned identity, and no move rebuilds a machine.
# WAVE-KERNEL-LINE-1: and onDriverBelowFloor. The kernel choice belongs to each
# machine (KERNEL-UX-1, the targets step); the wave's value could only be
# 'stop', and it made every machine that chose Update the kernel read as one
# that does not follow its wave. Each plan entry keeps its own value.
$script:VmfWaveSettingFields = @('capacityGate', 'requireApproval', 'onDDataFound', 'keepSnapshotDays', 'throttle')

# Review finding 1: three settings belong to the WAVE, not to a machine. The
# engine reads ONE value for the wave - the capacity gate from its first
# machine (Start-VmfWave), how many at once from the first machine that has one
# (Get-VmfNextPlanWave), and the sign-off from every machine (any one that
# requires it). A machine "keeping its own" value of one of these would leave
# the card saying one thing and the engine doing another. So a change to one of
# these is written to every machine of the wave, a decision is never recorded
# for one, and the card shows the engine's own reading.
$script:VmfWaveWideFields = @('capacityGate', 'requireApproval', 'throttle')
# Their labels in the wave editor, for a refusal that names one.
$script:VmfWaveWideLabels = @{
    capacityGate    = 'On-demand capacity reservation for this wave'
    requireApproval = 'Someone must sign off before this wave runs'
    throttle        = 'How many machines at once'
}

function Test-VmfWaveWideField {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Setting)
    $Setting -in $script:VmfWaveWideFields
}

function Get-VmfWaveSettingFields {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $script:VmfWaveSettingFields
}

function Test-VmfOwnDecision {
    <#
    .SYNOPSIS
        Does this plan entry hold a decision for this setting (plan-entry v17
        `decisions`)?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$PlanEntry, [Parameter(Mandatory)][string]$Setting)
    if (-not $PlanEntry -or -not $PlanEntry.PSObject.Properties['decisions']) { return $false }
    if ($Setting -in $script:VmfWaveWideFields) { return $false }
    [bool](@($PlanEntry.decisions) | Where-Object { $_ -and [string]$_.setting -eq $Setting })
}

function Set-VmfOwnDecision {
    <#
    .SYNOPSIS
        Record that a person decided this setting for this machine alone. One
        record per setting: a later decision replaces the earlier one. Raises
        the entry to the plan contract that has the field.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$By,
        # Whole seconds, on purpose. ConvertFrom-Json reads an ISO time as a
        # date, and ConvertTo-Json writes it back without trailing zeros, so
        # '...06.1693700Z' came back as '...06.16937Z': the next write of the
        # plan changed its text with nothing changed, and an approval signs
        # that text (PLANVER-2). Found by the full suite, about one run in ten.
        [Parameter()][string]$Utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        # REBUILD-REMOVE-ACCEPT-1: -PrincipalId (IDENTITY-LOSS-1), -Extensions
        # (REBUILD-ACCEPT-1), -SqlVirtualMachine (SQLVM-REREAD-1) and
        # -DataCollectionRuleAssociations (DCR-READ-1) are gone: they recorded
        # the acceptance of a rebuild or of an identity loss, which no decision
        # makes any more. A decision an earlier version wrote with them still
        # reads (plan-entry v22 to v28).
    )
    if (-not $PSCmdlet.ShouldProcess([string]$PlanEntry.vmId, "record a decision for $Setting")) { return }
    $kept = @(if ($PlanEntry.PSObject.Properties['decisions']) { @($PlanEntry.decisions) | Where-Object { $_ -and [string]$_.setting -ne $Setting } })
    $record = [ordered]@{ setting = $Setting; by = $By; utc = $Utc }
    $list = @($kept) + @([pscustomobject]$record)
    $PlanEntry | Add-Member -NotePropertyName decisions -NotePropertyValue $list -Force
    if ($PlanEntry.PSObject.Properties['schemaVersion']) { $PlanEntry.schemaVersion = Get-VmfPlanSchemaVersion }
    else { $PlanEntry | Add-Member -NotePropertyName schemaVersion -NotePropertyValue (Get-VmfPlanSchemaVersion) -Force }
}

function Remove-VmfOwnDecision {
    <#
    .SYNOPSIS
        WAVE-LEVER-RESET-1: remove the record of a decision for this setting
        from this machine, when a person gives it back the value of its wave.
        The entry loses the field when no record is left. Returns whether a
        record was removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$PlanEntry, [Parameter(Mandatory)][string]$Setting)
    if (-not $PlanEntry.PSObject.Properties['decisions']) { return $false }
    $all = @(@($PlanEntry.decisions) | Where-Object { $_ })
    $kept = @($all | Where-Object { [string]$_.setting -ne $Setting })
    if ($kept.Count -eq $all.Count) { return $false }
    if (-not $PSCmdlet.ShouldProcess([string]$PlanEntry.vmId, "remove the decision for $Setting")) { return $false }
    if ($kept.Count) { $PlanEntry.decisions = $kept }
    else { $PlanEntry.PSObject.Properties.Remove('decisions') }
    $true
}

function ConvertTo-VmfWaveLayout {
    <#
    .SYNOPSIS
        Check and read a wave layout: each wave's settings as the engine holds
        them, and its list of changes. Throws, by name, on anything the engine
        cannot act on - before anything is written.
    .OUTPUTS
        One object per wave: Name, VmIds, Settings (field -> value, only the
        settings the layout names), Changed ($null when the layout has no list
        of changes; else field -> the value the card showed), Reset (field ->
        the machines given back the value of the wave; empty when none).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Layout)

    foreach ($w in @($Layout.waves)) {
        $name = [string]$w.name
        # targetGeneration is NOT editable here. It decides every target
        # SIZE, and it belongs to each MACHINE (ADVISOR-1): a person
        # chooses it on the assessment's targets step, and the plan is
        # built from that. WAVE-SERIES-GONE-1 removed the per-wave shortcut
        # that could replace every machine's choice at once.
        if ($null -ne $w['targetGeneration']) {
            throw "The size series cannot be changed on a wave. It belongs to each machine: choose it on the assessment's targets step, then plan again."
        }
        # WAVE-KERNEL-LINE-1: nor the kernel choice. It is not a setting of a
        # wave, so a layout that names one is refused, not read in silence.
        if ($null -ne $w['onDriverBelowFloor']) {
            throw "A wave has no kernel choice. The kernel choice belongs to each machine. This migration keeps the kernel choice of its plan. To use another choice, change it on the Choose each target step. Select Delete this migration on the Migrations page. Then plan a new migration from the assessment."
        }
        $settings = [ordered]@{}
        # WAVE-2 phase C: every lever that was ruled on is adjustable per
        # wave, not only the two this editor started with. Values are
        # validated here, at the boundary, because a nonsense lever would
        # otherwise reach the engine as a policy nobody can act on.
        foreach ($field in $script:VmfWaveSettingFields) {
            if ($null -eq $w[$field]) { continue }
            $settings[$field] = switch ($field) {
                'requireApproval' {
                    # SIGNOFF-NULL-1: yes or no, nothing else. A [bool] cast
                    # read 0 as off and the text 'false' as on - a request
                    # read two ways, like the stored value was.
                    if ($w[$field] -isnot [bool]) {
                        # Named by the label the wave editor shows (Set-VmfWavePlan).
                        throw "The setting 'Someone must sign off before this wave runs' must be true or false - got '$($w[$field])' for wave '$name'."
                    }
                    $w[$field]
                }
                'throttle' {
                    # SCALE-UX-1: how many machines at once. One engine
                    # container runs at most 15 workers (measured
                    # 2026-09-04: 500 MB a worker); SCALE-2 splits a
                    # larger number over up to four containers; the facade sizes
                    # the container from this number. MACHINES-AT-ONCE-RANGE-1:
                    # one of the four choices (Test-VmfThrottleTier).
                    # ATONCE-EARLIER-1: every writer writes a choice, so a card
                    # only ever sends one back.
                    if (-not (Test-VmfThrottleTier -Value $w[$field])) {
                        throw "How many machines at once must be one of the choices, $(Get-VmfThrottleTierWords) - got '$($w[$field])' for wave '$name'. Select a choice for the wave, then save again."
                    }
                    [int]$w[$field]
                }
                'keepSnapshotDays' {
                    $days = 0
                    if (-not [int]::TryParse([string]$w[$field], [ref]$days) -or $days -lt 0 -or $days -gt 90) {
                        throw "How long to keep the safety copy must be a whole number of days between 0 and 90 - got '$($w[$field])' for wave '$name'."
                    }
                    $days
                }
                default {
                    $allowed = switch ($field) {
                        'capacityGate' { @('BestEffort', 'Reserved') }
                        default        { @('stop', 'proceed') }
                    }
                    # DECIDE-ROLE-1: ORDINAL - character for character. -notin
                    # ignored case and, by culture, zero-width characters, and
                    # the value was stored as sent ('PROCEED' entered a plan).
                    if (-not [System.Linq.Enumerable]::Contains([string[]]@($allowed), [string]$w[$field], [System.StringComparer]::Ordinal)) {
                        throw "'$($w[$field])' is not a setting for $field on wave '$name' - it must be one of: $($allowed -join ', ')."
                    }
                    [string]$w[$field]
                }
            }
        }
        # The settings the person changed on this wave's card, each with the
        # value the card showed. Read the same way as a stored value
        # (ConvertTo-VmfPolicyLeverValue), so 7 and "7" are one number.
        $changed = $null
        $raw = $w['changed']
        if ($null -ne $raw) {
            $changed = @{}
            $pairs = if ($raw -is [System.Collections.IDictionary]) { @($raw.Keys | ForEach-Object { @{ Key = [string]$_; Value = $raw[$_] } }) }
                     else { @($raw.PSObject.Properties | ForEach-Object { @{ Key = [string]$_.Name; Value = $_.Value } }) }
            foreach ($pair in $pairs) {
                if ($pair.Key -notin $script:VmfWaveSettingFields) {
                    throw "'$($pair.Key)' is not a setting of a wave, so wave '$name' cannot list it as changed. The settings are: $($script:VmfWaveSettingFields -join ', ')."
                }
                $changed[$pair.Key] = ConvertTo-VmfPolicyLeverValue -Name $pair.Key -Value $pair.Value
            }
        }
        $vmIds = @($w.vmIds | ForEach-Object { [string]$_ })
        # WAVE-LEVER-RESET-1: the machines the person gave back the value of
        # this wave, per setting. Each gets the value the wave names, and the
        # record of a decision for that setting goes. Checked here, by name:
        # a setting of the wave has no value of a machine to reset, a value the
        # wave does not name cannot be given, and a machine of another wave
        # takes its value from that wave.
        $reset = @{}
        $rawReset = $w['reset']
        if ($null -ne $rawReset) {
            $pairs = if ($rawReset -is [System.Collections.IDictionary]) { @($rawReset.Keys | ForEach-Object { @{ Key = [string]$_; Value = $rawReset[$_] } }) }
                     else { @($rawReset.PSObject.Properties | ForEach-Object { @{ Key = [string]$_.Name; Value = $_.Value } }) }
            foreach ($pair in $pairs) {
                $field = $pair.Key
                if ($field -notin $script:VmfWaveSettingFields) {
                    throw "'$field' is not a setting of a wave, so no machine of wave '$name' can use the setting of its wave for it. The settings are: $($script:VmfWaveSettingFields -join ', ')."
                }
                if ($field -in $script:VmfWaveWideFields) {
                    throw "'$($script:VmfWaveWideLabels[$field])' is one setting for the whole wave, so every machine of wave '$name' uses the setting of its wave."
                }
                if (-not $settings.Contains($field)) {
                    throw "Wave $name does not send its value for '$field', so no machine can use the setting of its wave. Send the value of the wave with the change."
                }
                $ids = @(@($pair.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
                foreach ($id in $ids) {
                    if ($id -notin $vmIds) {
                        throw "Machine $(($id -split '/')[-1]) is not in wave $name, so it cannot use the setting of that wave for '$field'."
                    }
                }
                if ($ids.Count) { $reset[$field] = $ids }
            }
        }
        [pscustomobject]@{ Name = $name; VmIds = $vmIds; Settings = $settings; Changed = $changed; Reset = $reset }
    }
}

function Get-VmfWaveSettingWrites {
    <#
    .SYNOPSIS
        Which setting a wave save writes on which machine, and which machine
        keeps its own value. Pure: no store, no Azure.
    .DESCRIPTION
        The one rule for the writer (Set-VmfWavePlan) and for the service's
        role checks (Invoke-VmfFacadeSetWaves), so the service judges exactly
        what will be written - an approver's act is never asked for a value
        that is not written, and never missed for one that is.
    .PARAMETER Entries
        The plan's entries, as STORED (before any machine moves).
    .PARAMETER Waves
        What ConvertTo-VmfWaveLayout returned.
    .OUTPUTS
        @{ Writes = @(VmId, Machine, Wave, Field, From, To, Joining, Reset, Decided);
           Kept   = @(VmId, Machine, Wave, Field, Value, Reason) }
        Reason: 'decision' (a decision for that machine recorded it) or 'own'
        (it holds another value than the card showed). Reset: the person gave
        the machine back the value of the wave (WAVE-LEVER-RESET-1), so the
        writer removes the record of a decision for that setting; Decided: it
        had one. A reset write can have From equal to To: only the record goes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Entries,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Waves
    )
    $byId = @{}
    foreach ($e in @($Entries)) { if ($e) { $byId[[string]$e.vmId] = $e } }
    $same = { param($a, $b) $null -ne $a -and $null -ne $b -and $a -is $b.GetType() -and $a -eq $b }
    $writes = [System.Collections.Generic.List[object]]::new()
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($w in @($Waves)) {
        foreach ($id in @($w.VmIds)) {
            $entry = $byId[[string]$id]
            # A machine this plan does not have is refused BY NAME by the writer.
            if (-not $entry) { continue }
            $joining = [string]$entry.wave -ne [string]$w.Name
            $machine = ([string]$id -split '/')[-1]
            foreach ($field in @($w.Settings.Keys)) {
                $to = $w.Settings[$field]
                # WAVE-LEVER-RESET-1: a machine the person gave back the value
                # of its wave gets the value the wave names - over its own
                # value, and over a decision, whose record goes (Reset). A
                # decision with the value of the wave is still a write: the
                # record goes, so the plan changes. Nothing else, nothing written.
                $resetHere = $w.PSObject.Properties['Reset'] -and $w.Reset -and $w.Reset.ContainsKey($field) -and ([string]$id -in @($w.Reset[$field]))
                if ($resetHere) {
                    $existing = ConvertTo-VmfPolicyLeverValue -Name $field -Value (Get-VmfPolicy -PlanEntry $entry -Name $field)
                    $decided = Test-VmfOwnDecision -PlanEntry $entry -Setting $field
                    if ((& $same $existing $to) -and -not $decided) { continue }
                    $writes.Add([pscustomobject]@{ VmId = [string]$id; Machine = $machine; Wave = [string]$w.Name; Field = $field; From = $existing; To = $to; Joining = $joining; Reset = $true; Decided = $decided })
                    continue
                }
                $shown = $null
                if (-not $joining -and $null -ne $w.Changed) {
                    # The person did not change this setting on the card: a
                    # machine staying in the wave is not written for it.
                    if (-not $w.Changed.ContainsKey($field)) { continue }
                    $shown = $w.Changed[$field]
                }
                # WAVE-SAVE-FALSE-1: what the setting MEANS - the stored value,
                # or the engine's default when it is absent - both sides read
                # as the same kind of value.
                $existing = ConvertTo-VmfPolicyLeverValue -Name $field -Value (Get-VmfPolicy -PlanEntry $entry -Name $field)
                if (& $same $existing $to) { continue }
                # A setting of the wave is one value for the whole wave.
                if ($field -in $script:VmfWaveWideFields) {
                    $writes.Add([pscustomobject]@{ VmId = [string]$id; Machine = $machine; Wave = [string]$w.Name; Field = $field; From = $existing; To = $to; Joining = $joining; Reset = $false; Decided = $false })
                    continue
                }
                if (Test-VmfOwnDecision -PlanEntry $entry -Setting $field) {
                    $kept.Add([pscustomobject]@{ VmId = [string]$id; Machine = $machine; Wave = [string]$w.Name; Field = $field; Value = $existing; Reason = 'decision' })
                    continue
                }
                if ($null -ne $shown -and -not (& $same $existing $shown)) {
                    $kept.Add([pscustomobject]@{ VmId = [string]$id; Machine = $machine; Wave = [string]$w.Name; Field = $field; Value = $existing; Reason = 'own' })
                    continue
                }
                $writes.Add([pscustomobject]@{ VmId = [string]$id; Machine = $machine; Wave = [string]$w.Name; Field = $field; From = $existing; To = $to; Joining = $joining; Reset = $false; Decided = $false })
            }
        }
    }
    [pscustomobject]@{ Writes = @($writes); Kept = @($kept) }
}

function Get-VmfWaveLayoutWrites {
    <#
    .SYNOPSIS
        Get-VmfWaveSettingWrites for a layout against the plan as stored. The
        service asks this before it lets a save through.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][hashtable]$Layout)
    # PLAN-WRITE-RACE-1: judged on ONE read, whose version goes back with the
    # answer - the service hands it to the writer, which refuses a plan that
    # changed since (review finding 2: with no version from the page, a write
    # between the judgement and the save would have gone unjudged).
    $read = Read-VmfPlanFileVersioned -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json')
    $entries = @(if ($read) { @($read.Plan.entries) })
    $judged = Get-VmfWaveSettingWrites -Entries $entries -Waves @(ConvertTo-VmfWaveLayout -Layout $Layout)
    $judged | Add-Member -NotePropertyName Version -NotePropertyValue $(if ($read) { $read.Version } else { '' }) -PassThru
}
