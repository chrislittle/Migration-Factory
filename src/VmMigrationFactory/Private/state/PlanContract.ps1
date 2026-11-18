# EVAL-H11, from the 2026-08-28 self-evaluation.
#
# The plan is the one artifact with no version gate. State documents refuse an
# unsupported version ("never silently misreads"), assessments refuse - and the
# plan, the contract that moved v3 to v8 in 36 hours, was parsed and returned.
#
# That is not theoretical. On 2026-08-28 the values of onDDataFound and
# onDriverBelowFloor were renamed from 'park' to 'stop'. A plan written before
# that carries 'park'; both the acceptance hash and the approval hash still
# match, so every gate passes and the wave resumes exactly as the "a run in
# flight across an upgrade must not strand" design intends - and then
# 'park' -eq 'stop' is false, so the engine does NOT stop when user data is
# found on the temporary disk. The machine converts, the drive is recreated
# raw, and the data the lever exists to protect is gone, with the plan file
# still saying, in the customer's own words, that this machine was supposed to
# stop and ask. Both dashboards render 'park' as "Stop and ask", so the screen
# shows the safe behaviour while the engine does the other thing.
#
# So: every read of a plan comes through here, and a newer one is REFUSED BY
# NAME (this build cannot know what a later version means). The rename of
# 'park' was applied on read until OLD-VERSION-READERS-REMOVE-2: no writer
# gives 'park', and nothing is public before 1.0, so no store holds a plan
# with it. OLD-VERSION-READERS-REMOVE-7: an earlier version is refused too.

# WAVE-LEVER-OVERRIDE-1 (v17): an entry may carry `decisions`, the settings a
# person decided for that machine alone. V3-RETIRE-1 (v18): target.rollbackSize,
# the size a machine's rollback was to use when Microsoft retired its own - no
# longer written or read since RETIRE-SCOPE-1; it left the contract at v33.
# MANA-LINUX-KERNEL-1 (v19): onDriverBelowFloor may be 'updateKernel', chosen
# per machine on the targets step; and SAFETYCOPY-CLEAN-1's 'clean' and the
# unread assessment.osDiskData leave the contract. An older entry that holds
# either still reads (PRECHECK refuses 'clean').
# WAVE-AN-NAMES-1 (v20): acceleratedNetworkingOutcome, whether the move turns
# accelerated networking on for the primary interface, recorded for the wave
# settings to name (Get-VmfPlannedAnOutcome). An older entry has none.
# HDD-OS-1 (v21): policy.diskUpgrade may be 'os-standard-ssd' - Standard SSD
# for an OS disk that is Standard HDD - and assessment.osDiskType carries the
# OS disk's type as the scan read it. An older entry has neither.
# IDENTITY-LOSS-1 (v22): a decision for onSystemAssignedIdentity may carry
# principalId, the account of the system-assigned identity the person accepted
# to lose, which PRECHECK compares with the account Azure reports. An older
# decision has none, and PRECHECK asks again for it.
# REBUILD-PICKER-1 (v23): target.choice.method - in-place, rebuild or preview -
# how the machine moves, as the person saved it. An older entry has none, and
# its path says it.
# REBUILD-ACCEPT-1 (v24): a decision may be the acceptance of a rebuild of one
# machine (setting rebuild, with the extensions shown), and assessment
# rebuildLinks carries what the scan read. An older entry has neither, and
# PRECHECK asks for the acceptance.
# SQLVM-REREAD-1 (v25): a rebuild decision may carry sqlVirtualMachine, the
# SQL virtual machine resource Checking read before the stop, which the person
# accepted the rebuild deletes. An older decision has none: PRECHECK accepts
# that resource only when the scan found it or the wave's acceptance listed it.
# DCR-READ-1 (v26): a rebuild decision may carry dataCollectionRuleAssociations,
# the names of the associations Checking read before the stop, which the
# person accepted the rebuild deletes. An older decision has none: PRECHECK
# accepts an association only when the scan found it or the wave's acceptance
# named it.
# MACHINES-AT-ONCE-RANGE-1 (v27): policy.throttle - how many machines at once -
# is written as one of four choices: Pilot 5, Standard 15 (the default), Large
# 30 and Maximum 60 (2026-11-06). The limit is 60, as the engine has run
# since SCALE-2. An older entry keeps the number it holds, any whole number 1
# to 60, and the engine runs it; an entry with none reads as the default.
# AN-MANA-DRIVER-RULE-1 (v28): policy.acceleratedNetworking is never ensureOff
# on an NVMe target (v6, v7). An older entry that holds it still reads, and
# Checking stops that machine, untouched (acceleratedNetworkingRequired), for
# an approver to accept accelerated networking - as it does for ensureOff, or
# preserve on a primary that is off, on every size that can give MANA.
# REBUILD-REMOVE-PLAN-1 (v29): no new entry has path B or target.choice.method
# rebuild, and assessment.rebuildLinks is no longer written - the rebuild
# around the same disks is removed. They left the contract at v31.
# CRG-MOVE-DEMAND-1 (v30): assessment.capacityReservationGroupId, the capacity
# reservation group the scan found the machine in (null for none). An older
# entry has no field, which reads as unknown, and the machine is counted for a
# reservation as before.
# OLD-VERSION-READERS-REMOVE-1 (v31): no field of the rebuild in the contract -
# path B, target.choice.method rebuild, assessment.rebuildLinks,
# policy.onSystemAssignedIdentity and the decision fields extensions,
# sqlVirtualMachine, dataCollectionRuleAssociations and principalId. No writer
# gave them since v29, and nothing is public before 1.0 (2026-11-11), so
# no store holds an entry with one; no reader takes them.
# PLAN-HIBERNATION-UNUSED-1 (v32): no assessment.hibernationEnabled. Nothing read
# it - the scan excludes such a machine, and Checking reads it again.
# OLD-VERSION-READERS-REMOVE-3 (v33): no assessment.classification ReadyNow, no
# onDriverBelowFloor proceed, no acceleratedNetworking ensureOff and no
# target.rollbackSize - no writer of this version gives them. An older entry
# that holds a policy value of them is refused in PRECHECK (policyNotKnown).
# ROLLBACK-CAPACITY-1 (v35): assessment.sourceCapacityRestricted - whether
# Microsoft restricts capacity growth for the series of the original size, so
# the sign-off of a wave says once that the product gives no guarantee of
# capacity for the new size or, on a rollback, for the original size.
# VF-UNMANAGED-CONFIG-1 (v36): policy.onSriovUnmanagedMissing, stop or proceed.
# Only Resolve-VmfDecision writes it, when an approver accepts the move of one
# Linux machine whose network settings do not set the SR-IOV interface as
# unmanaged (sriovNotUnmanaged, sriovUnmanagedNotChecked). Absent reads as stop.
# SQL-TEMPDB-SIGNOFF-1 (v37): assessment.sqlServerDetected - the scan found SQL
# Server on the machine, so the plan sign-off names a SQL Server machine that
# moves from a SCSI temporary disk to an NVMe temporary disk or none.
$script:VmfPlanSchemaVersion = 37

# MACHINES-AT-ONCE-RANGE-1: the four choices of "How many machines at once",
# written down once. help.js holds the same list (WAVE_TIERS), and
# MachinesAtOnceRange.Tests.ps1 holds the two to each other. An engine
# container runs 15 machines (SCALE-2), so they are one, one, two and four
# containers.
$script:VmfThrottleTiers = @(
    [pscustomobject]@{ Id = 'pilot';    Machines = 5 }
    [pscustomobject]@{ Id = 'standard'; Machines = 15 }
    [pscustomobject]@{ Id = 'large';    Machines = 30 }
    [pscustomobject]@{ Id = 'maximum';  Machines = 60 }
)

function Get-VmfThrottleTiers {
    <#
    .SYNOPSIS
        MACHINES-AT-ONCE-RANGE-1: the four choices of how many machines at
        once, smallest first.
    #>
    [CmdletBinding()]
    param()
    $script:VmfThrottleTiers
}

function Test-VmfThrottleTier {
    <#
    .SYNOPSIS
        MACHINES-AT-ONCE-RANGE-1: is this number one of the four choices? A
        whole number only: '15' is 15, and '15.5' or 'x' is no choice.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Value)
    $n = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$n)) { return $false }
    [bool](@($script:VmfThrottleTiers | Where-Object { $_.Machines -eq $n }).Count)
}

function Get-VmfThrottleTierWords {
    <#
    .SYNOPSIS
        The four choices as a person reads them in a refusal: "5, 15, 30 or 60".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = @($script:VmfThrottleTiers | ForEach-Object { [string]$_.Machines })
    "$(@($n | Select-Object -First ($n.Count - 1)) -join ', ') or $($n[-1])"
}

function Get-VmfWaveThrottle {
    <#
    .SYNOPSIS
        MACHINES-AT-ONCE-RANGE-1: how many machines at once a wave runs - the
        one reading the engine, the service and the pages use.
    .DESCRIPTION
        The number of the first machine of the wave that has one (a whole
        number above 0). A wave whose machines have none runs at the default
        of a new plan (Get-VmfDefaultWavePolicy), which is how Get-VmfPolicy
        reads a missing setting. help.js has the same rule (waveAtOnce).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Entries)
    foreach ($e in @($Entries)) {
        if (-not $e -or -not $e.policy) { continue }
        $prop = $e.policy.PSObject.Properties['throttle']
        if (-not $prop -and $e.policy -is [System.Collections.IDictionary] -and $e.policy.Contains('throttle')) { $prop = @{ Value = $e.policy['throttle'] } }
        if (-not $prop) { continue }
        $n = 0
        if ([int]::TryParse([string]$prop.Value, [ref]$n) -and $n -gt 0) { return $n }
    }
    [int](Get-VmfDefaultWavePolicy).throttle
}

# OLD-VERSION-READERS-REMOVE-2: no value is renamed on read. 'park' became
# 'stop' long before 1.0, nothing is public before 1.0, and no writer gives
# 'park', so no store holds a plan with it.

function Get-VmfPlanSchemaVersion {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $script:VmfPlanSchemaVersion
}

function ConvertTo-VmfSupportedPlan {
    <#
    .SYNOPSIS
        EVAL-H11: check a plan's version.
    .DESCRIPTION
        Refuses an entry of any version but the current one, by name: a newer
        one (this build cannot know what it means), and an earlier one or one
        with no version (OLD-VERSION-READERS-REMOVE-7: every writer of this
        version writes the current version, and nothing is public before 1.0).
        A policy value the contract does not list is refused in PRECHECK
        (Get-VmfPlanPolicyRefusal).
    .OUTPUTS
        The plan, as it was read.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Plan,
        [Parameter()][string]$Source = 'plan.json'
    )
    if (-not $Plan) { return $Plan }

    $current = Get-VmfPlanSchemaVersion
    $entries = @($Plan.entries)

    # A plan written by a LATER build may mean things this one cannot act on.
    # Refusing names the version rather than guessing.
    $tooNew = @($entries | Where-Object {
        $_ -and $_.PSObject.Properties['schemaVersion'] -and [int]$_.schemaVersion -gt $current
    })
    if ($tooNew.Count -gt 0) {
        $seen = @($tooNew | ForEach-Object { [int]$_.schemaVersion } | Sort-Object -Unique) -join ', '
        throw ("This plan ($Source) was written by a newer version of the product - its entries are contract version $seen and this build understands up to $current. " +
               "Refusing to act on it rather than guessing what the newer settings mean. Upgrade the product, or re-plan with this one.")
    }
    # OLD-VERSION-READERS-REMOVE-7: and an entry of an earlier version, or with
    # no version, is refused too. Every writer of this version (New-VmfPlan,
    # Set-VmfMachineTarget, the wave settings, a decision) writes the current
    # version on each entry, and nothing is public before 1.0
    # (2026-11-11), so no store holds an older entry.
    $older = @($entries | Where-Object {
        # No version reads as 0, so it is refused by the same comparison.
        $_ -and [int]$_.schemaVersion -lt $current
    })
    if ($older.Count -gt 0) {
        throw "The entries of this plan ($Source) are of an earlier contract version, so make the plan again with this version."
    }
    $Plan
}

function Read-VmfPlanDocument {
    <#
    .SYNOPSIS
        The ONE way to read a plan from the run store. Version-gated.
    .DESCRIPTION
        A test asserts nothing else reads plan.json directly - the gate is
        worthless if half the callers walk around it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$Depth = 24,
        [Parameter()][string]$RelPath = 'plan.json'
    )
    $plan = Read-VmfStoreJson -RunPath $RunPath -RelPath $RelPath -Depth $Depth
    ConvertTo-VmfSupportedPlan -Plan $plan -Source $RelPath
}

function Read-VmfPlanFile {
    <#
    .SYNOPSIS
        The same gate for a plan addressed by path or store handle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # Accepted so callers that were passing it to the raw reader keep
        # working; the underlying reader parses at full depth.
        [Parameter()][int]$Depth = 24
    )
    $plan = Read-VmfJsonDocument -Path $Path
    ConvertTo-VmfSupportedPlan -Plan $plan -Source $Path
}

function Read-VmfPlanFileVersioned {
    <#
    .SYNOPSIS
        WAVE-MIX-2: the same gate, AND the version of the text it parsed - from
        ONE read, so the version a caller checks is the version of the plan it
        acts on (PLANVER-2).
    .OUTPUTS
        @{ Text; Version; Plan }, or $null when there is no plan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-VmfTextDocument -Path $Path
    if (-not $text) { return $null }
    [pscustomobject]@{
        Text    = $text
        Version = Get-VmfDocumentVersion -Text $text
        Plan    = ConvertTo-VmfSupportedPlan -Plan ($text | ConvertFrom-Json -Depth 24) -Source $Path
    }
}

# EVAL-H12: -PolicyOverride copied ANY key into the plan with no name or value
# check, while the wave editor validated the same object "here, at the boundary,
# because a nonsense lever would otherwise reach the engine as a policy nobody
# can act on". The two writers disagreed about what a policy is; now they do not.
$script:VmfPolicyLevers = [ordered]@{
    # SAFETYCOPY-CLEAN-1: 'clean' left the contract at v19, and the engine
    # refuses an entry that does not ask for the first copy.
    safetyCopy          = @('pristine')
    capacityGate        = @('BestEffort', 'Reserved')
    requireApproval     = 'bool'
    onDDataFound        = @('stop', 'proceed')
    # MANA-LINUX-KERNEL-1: a plan may also hold 'updateKernel', but only the
    # planner writes it, from the choice a person made for that machine on the
    # targets step - never a wave save or a decision.
    # AN-PROCEED-NETVSC-1 (2026-11-06: a move is not allowed if the network
    # will not work with AN): 'proceed' (Continue) is no longer written -
    # it moved a machine with no driver for its target's adapter onto the
    # synthetic interface. It left the contract at v33.
    onDriverBelowFloor  = @('stop')
    # REBUILD-REMOVE-ACCEPT-1: onSystemAssignedIdentity (IDENTITY-2) is no
    # longer written - it chose what a rebuild did to a system-assigned
    # identity, and no move rebuilds a machine. A wave save and a decision
    # refuse it by name.
    # AN-MANA-DRIVER-RULE-1: 'ensureOff' is not written (off is not off on a
    # size that can give MANA). It left the contract at v33.
    acceleratedNetworking = @('ensureOn', 'preserve')
    # VF-UNMANAGED-CONFIG-1 (v36): an approver's decision for one machine only,
    # never a wave setting. proceed: Checking does not read the SR-IOV setting.
    onSriovUnmanagedMissing = @('stop', 'proceed')
    keepSnapshotDays    = 'days'
    # SCALE-UX-1 (v12): how many machines at once. MACHINES-AT-ONCE-RANGE-1
    # (v27): one of the four choices, 5, 15, 30 or 60 (Get-VmfThrottleTiers).
    # ATONCE-EARLIER-1: the contract lists only these. An entry with none
    # reads as 15.
    throttle            = 'machines'
    # GEN-V5-1 (v14): v5 joined v6 and v7.
    targetGeneration    = @('v5', 'v6', 'v7')
    # EOL-RELEASE-AN-1 (v34): a Linux release past its vendor's end of
    # standard support stops at Checking (linuxReleaseEndOfLife) until an
    # approver accepts it for that machine. Written by a decision only, never
    # a wave save; absent reads as stop.
    onReleaseEndOfLife  = @('stop', 'proceed')
}

# OLD-VERSION-READERS-REMOVE-3, hardening (security pass finding): the values a
# plan entry's policy may hold, as the plan-entry contract lists them. A
# writer of this version writes nothing else. The engine acts only on these:
# any other value is refused in PRECHECK and at the wave's acceptance
# (Get-VmfPlanPolicyRefusal), never read as the default or as go on. The
# temporary disk check read any onDDataFound but 'stop' as proceed.
# MANUAL-REVIEW-1: safetyCopy is one of them - pristine only - and its own
# refusal (safetyCopyNotPristine) is gone with bootableClone. PolicyFailClosed
# .Tests.ps1 holds this table to the contract, value for value.
$script:VmfStoredPolicyValues = [ordered]@{
    safetyCopy            = @('pristine')
    capacityGate          = @('BestEffort', 'Reserved')
    requireApproval       = 'bool'
    onDDataFound          = @('stop', 'proceed')
    onDriverBelowFloor    = @('stop', 'updateKernel')
    acceleratedNetworking = @('ensureOn', 'preserve')
    onSriovUnmanagedMissing = @('stop', 'proceed')
    keepSnapshotDays      = @{ Min = 0; Max = 90 }
    # ATONCE-EARLIER-1: the four choices only - a whole number in this list.
    throttle              = @{ Values = @(5, 15, 30, 60) }
    targetGeneration      = @('v5', 'v6', 'v7')
    diskUpgrade           = @('os', 'all', 'os-standard-ssd')
    onReleaseEndOfLife    = @('stop', 'proceed')
}

function Get-VmfStoredPolicyValues {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $script:VmfStoredPolicyValues
}

function Get-VmfPlanPolicyRefusal {
    <#
    .SYNOPSIS
        OLD-VERSION-READERS-REMOVE-3: why this plan entry may not run, when its
        policy holds a value the plan-entry contract does not list - or $null.
    .DESCRIPTION
        One rule for PRECHECK and the wave's acceptance. No value (absent or
        null) is the engine default. A value is compared exactly (ordinal):
        'Proceed' or 'proceed ' is not proceed. A count is a whole number in
        its range; a text '7' is not a number. A yes or no is a boolean.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$PlanEntry)
    if ($null -eq $PlanEntry) { return $null }
    $policy = if ($PlanEntry -is [System.Collections.IDictionary]) { $PlanEntry['policy'] } else { $PlanEntry.policy }
    if ($null -eq $policy) { return $null }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($script:VmfStoredPolicyValues.Keys)) {
        $value = $null
        if ($policy -is [System.Collections.IDictionary]) { if ($policy.Contains($name)) { $value = $policy[$name] } }
        elseif ($policy.PSObject.Properties[$name]) { $value = $policy.$name }
        if ($null -eq $value) { continue }
        $kind = $script:VmfStoredPolicyValues[$name]
        $ok = if ($kind -is [string] -and $kind -eq 'bool') { $value -is [bool] }
              elseif ($kind -is [hashtable]) {
                  $whole = $value -is [int] -or $value -is [long] -or $value -is [int16] -or $value -is [byte]
                  if ($kind.ContainsKey('Values')) { $whole -and @($kind.Values) -contains [long]$value }
                  else { $whole -and [long]$value -ge $kind.Min -and [long]$value -le $kind.Max }
              }
              else { $value -is [string] -and [System.Linq.Enumerable]::Contains([string[]]@($kind), [string]$value, [System.StringComparer]::Ordinal) }
        if (-not $ok) { $found.Add("'$name' to '$value'") }
    }
    if ($found.Count -eq 0) { return $null }
    "The plan for this machine sets $($found -join ', and '). This product does not know this value, so it does not move the machine."
}

function Get-VmfCapacityGate {
    <#
    .SYNOPSIS
        OLD-VERSION-READERS-REMOVE-3: the capacity gate of a plan entry, failed
        closed. BestEffort only when the entry says exactly that, or says
        nothing (the default of a new plan); any other value is Reserved, the
        gate that refuses a start without the capacity reservation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$PlanEntry)
    $policy = if ($null -eq $PlanEntry) { $null } elseif ($PlanEntry -is [System.Collections.IDictionary]) { $PlanEntry['policy'] } else { $PlanEntry.policy }
    $value = $null
    if ($policy -is [System.Collections.IDictionary]) { $value = $policy['capacityGate'] }
    elseif ($null -ne $policy -and $policy.PSObject.Properties['capacityGate']) { $value = $policy.capacityGate }
    if ($null -eq $value -or [string]::Equals([string]$value, 'BestEffort', [System.StringComparison]::Ordinal)) { return 'BestEffort' }
    'Reserved'
}
function Get-VmfPolicyLevers {
    <#
    .SYNOPSIS
        The levers a plan entry's policy may carry, and what each accepts.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $script:VmfPolicyLevers
}

function ConvertTo-VmfPolicyLeverValue {
    <#
    .SYNOPSIS
        WAVE-SAVE-FALSE-1 (issue 424): one reading of a lever's value, so a
        stored value and a sent one compare as the same kind of thing.
    .DESCRIPTION
        JSON gives a plan's `7` back as a number and a hand-edited plan may hold
        "7"; a sign-off flag arrives as a bool. Compared as text, True and true
        or 7 and "7" only agreed by luck. Read by the lever's kind in the lever
        table: a 'bool' lever the way the engine's gate reads it ([bool] - see
        Test-VmfWaveApproval), a count of days or machines as a whole number,
        anything else as text. An unreadable number stays text, so it differs
        from every real value rather than equalling one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()]$Value
    )
    if ($null -eq $Value) { return $null }
    $kind = $script:VmfPolicyLevers[$Name]
    if ($kind -is [string] -and $kind -eq 'bool') { return [bool]$Value }
    if ($kind -is [string] -and $kind -in @('days', 'machines')) {
        $n = 0
        if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    }
    [string]$Value
}

function Test-VmfPolicyOverride {
    <#
    .SYNOPSIS
        EVAL-H12: is this a policy change the engine can actually act on?
    .DESCRIPTION
        An unknown key is refused BY NAME. The old behaviour accepted it,
        echoed it into the machine's history and the event log so it looked
        handled, did nothing, and - because any key changes the wave-options
        hash - refused the ENTIRE WAVE at its next start with "changed after
        <person> accepted its options", for a wave nobody edited.
    .OUTPUTS
        @{ Ok = <bool>; Detail = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Override)

    if (-not $Override) { return @{ Ok = $true; Detail = 'nothing to change' } }
    $levers = Get-VmfPolicyLevers
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @($Override.Keys)) {
        # STATE-TARGET-1: the size series is a setting, but changing it here
        # changes it WITHOUT working out the size, the controller, the disk
        # type and the path that follow from it - a plan that says v5 on a v6
        # size. A decision is about a machine that has STARTED, and its series
        # is fixed from then (STATE-TARGET-1); to use another, it is planned
        # again - which recomputes all of them.
        if ($key -eq 'targetGeneration') {
            $problems.Add("A decision does not change the size series. A machine that has started keeps its series. To use another series, plan the machine again.")
            continue
        }
        # DECIDE-ROLE-1: the NAME exactly, ordinal. The lever table ignores
        # case, so OnSystemAssignedIdentity passed and renamed the policy key
        # in the plan, which the pages then read as missing.
        if (-not (@($levers.Keys) | Where-Object { [string]::Equals([string]$_, [string]$key, [System.StringComparison]::Ordinal) })) {
            $problems.Add("'$key' is not a setting the product has. The settings are: $(@($levers.Keys) -join ', ').")
            continue
        }
        $allowed = $levers[$key]
        $value = $Override[$key]
        # DECIDE-ROLE-1: ONE value, of a plain kind. A list was read as its
        # text - ['proceed'] passed as 'proceed' - and then written into the
        # plan as a list, which the plan-entry contract does not allow.
        if ($null -eq $value -or -not ($value -is [string] -or $value -is [ValueType])) {
            $problems.Add("'$key' takes one value, not a list or a group of values.")
            continue
        }
        if ($allowed -is [string] -and $allowed -eq 'bool') {
            if ($value -isnot [bool]) { $problems.Add("'$key' is yes or no, not '$value'.") }
        }
        elseif ($allowed -is [string] -and $allowed -eq 'days') {
            $days = 0
            if (-not [int]::TryParse([string]$value, [ref]$days) -or $days -lt 0 -or $days -gt 90) {
                $problems.Add("'$key' is a whole number of days between 0 and 90, not '$value'.")
            }
        }
        elseif ($allowed -is [string] -and $allowed -eq 'machines') {
            # MACHINES-AT-ONCE-RANGE-1: a writer writes one of the four choices.
            if (-not (Test-VmfThrottleTier -Value $value)) {
                $problems.Add("'$key' is one of the choices of machines at once: $(Get-VmfThrottleTierWords) - not '$value'.")
            }
        }
        # DECIDE-ROLE-1: the text exactly, ORDINAL. 'PROCEED' passed a check
        # that ignored case and was stored as written, so a reader that
        # compares with case (the pages) and one that does not disagree on it.
        # And -ccontains compares by culture, which ignores zero-width
        # characters: 'pro' + U+200B + 'ceed' passed it too.
        elseif ($value -isnot [string] -or -not [System.Linq.Enumerable]::Contains([string[]]@($allowed), [string]$value, [System.StringComparer]::Ordinal)) {
            $problems.Add("'$value' is not a setting for '$key' - it must be one of: $(@($allowed) -join ', ').")
        }
    }
    if ($problems.Count -gt 0) { return @{ Ok = $false; Detail = ($problems -join ' ') } }
    @{ Ok = $true; Detail = 'ok' }
}

function Get-VmfShortHash {
    <#
    .SYNOPSIS
        The readable front of a plan version, for a message a person reads.
    .DESCRIPTION
        ACCEPT-EVIDENCE-1. The two gates that bind an action to a plan version
        refuse with a sentence, and a sentence carrying two 64-character sums
        is not one anybody reads. Twelve characters is enough to see that two
        versions differ, which is the only question the message has to answer.

        A MISSING VALUE IS SAID, NOT SKIPPED. An empty hash reads as "nothing",
        because a message that quietly drops one half of a comparison is how a
        refusal comes to name no evidence at all - which is the defect this
        exists to close.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) { return 'nothing' }
    if ($Hash.Length -le 12) { return $Hash }
    $Hash.Substring(0, 12)
}

function Get-VmfDocumentVersion {
    <#
    .SYNOPSIS
        The version of a stored document: SHA-256 of its text, lower-case hex.
    .DESCRIPTION
        PLANVER-2. THIS IS THE ONE PLACE THAT COMPUTES IT, and it exists
        because there were three: the acceptance gate, the approval gate, and
        every caller that had to work it out for itself from a copy fetched
        over HTTP.

        That last one is the defect. A caller computing this from text it
        received through the API needs the document to travel BYTE FOR BYTE
        through a JSON service - a requirement nobody wrote down, and one the
        platform does not honour. Measured 2026-09-17 against a real install:
        the same blob, at the same path, hashed to 80402c05e52e in the service
        and ac4008db385d in the caller, and no candidate reading of a
        byte-order mark or a newline closed the gap.

        SO THE SERVICE ISSUES IT. The store endpoint computes this over the
        bytes it read and returns it beside the document, and a caller quotes
        it back rather than deriving it. Transport fidelity stops mattering,
        because nobody downstream recomputes anything.

        THE SECURITY PROPERTY IS UNCHANGED, and that is the point to check
        rather than assume. The gate exists so an acceptance names the plan the
        person was SHOWN. The version is issued WITH the content in the same
        response, so it still describes exactly what the page rendered - it is
        not a second call that could race the first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) |
                ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}
