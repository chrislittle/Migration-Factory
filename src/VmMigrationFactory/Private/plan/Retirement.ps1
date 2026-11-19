# V3-RETIRE-1, as reversed in part by RETIRE-SCOPE-1: a size Microsoft retires.
#
# Microsoft retires Dv3, Dsv3, Ev3 and Esv3 on 2029-11-15, and the older
# families before that (data/target-families.json lifecycle.retirements, read
# from Microsoft's retirements page). At the date the machines that remain are
# deallocated and stop working; their managed disks are kept, and they come
# back only by a resize to a supported size.
#
# THE RULE (2026-10-04, RETIRE-SCOPE-1): the product does not support a
# machine that was not moved in time by the Microsoft lifecycle; after
# retirement it is outside the scope of this tool.
#
#   - Before the margin nothing changes: the move is allowed, its rollback goes
#     to the original size, and the product warns from 12 months before.
#   - From ONE DAY before the date a machine on that size is OUTSIDE THE SCOPE
#     OF THIS TOOL: the assessment says so, the target advice gives it no
#     option, the plan does not plan it, PRECHECK refuses it untouched, and a
#     restore from the first copy or a rebuild as it was is refused before
#     anything changes. The margin: a rollback started the evening before must
#     not reach the old size after midnight, inside the stopped window.
#
# V3-RETIRE-1 (2026-10-03) had sent the rollback to the nearest current size of
# the same shape instead. That machinery is gone; a record it wrote is read and
# ignored (docs/schema-migrations.md).
#
# Read from the data, for every row it has; nothing here names a series or a
# date. These functions make no Azure call.
function Get-VmfSizeRetirement {
    <#
    .SYNOPSIS
        The retirement entry for a size, from data/target-families.json
        lifecycle.retirements, or $null when Microsoft has announced none.
    .DESCRIPTION
        The size's series is read the way the data's sizeSeries is written:
        the family, the letters after the size number, and the version -
        Standard_D4s_v3 is Dsv3, Standard_E64is_v3 Eisv3, Standard_DS13-4_v2
        DSv2, Standard_B2ms Bms, Standard_D4 D. Case is ignored.
    .OUTPUTS
        @{ Series = <Microsoft's names>; RetiresUtc = 'yyyy-MM-dd'; Source } or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)

    # BSV2-TARGET-1: the reading is shared with burstableTargets.
    $read = Get-VmfSizeSeriesReading -SizeName $SizeName
    if (-not $read) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    foreach ($row in @($Families.lifecycle.retirements)) {
        $names = if ($row.PSObject.Properties['sizeSeries']) { @($row.sizeSeries) } else { @($row.series) }
        if ($names -contains $read) {
            # CLAUDE.md: ConvertFrom-Json can turn a date into a date value.
            $day = if ($row.retiresUtc -is [datetime]) { $row.retiresUtc.ToString('yyyy-MM-dd') } else { [string]$row.retiresUtc }
            return @{ Series = @($row.series); RetiresUtc = $day; Source = [string]$row.source }
        }
    }
    $null
}

function Get-VmfPutBackRetirement {
    <#
    .SYNOPSIS
        Where a size stands against its retirement date: 'none', 'warn' or
        'refused'.
    .DESCRIPTION
        refused - on or after the retirement date (00:00 UTC that day).
        warn    - within the 12 months before it.
        none    - no retirement entry, or more than 12 months away.
        The product's own line is one day earlier (Test-VmfSizeRetiredForTool).
    .OUTPUTS
        @{ State; Size; RetiresUtc; Series; WarnFromUtc } - RetiresUtc and
        WarnFromUtc are 'yyyy-MM-dd' text, never date values (PLANVER-2: a
        date re-read from JSON is not the text that was written).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    $r = Get-VmfSizeRetirement -SizeName $SizeName -Families $Families
    if (-not $r) { return @{ State = 'none'; Size = $SizeName; RetiresUtc = $null; Series = @(); WarnFromUtc = $null } }
    $day = [datetime]::ParseExact($r.RetiresUtc, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $warnFrom = $day.AddMonths(-12)
    $utc = $Now.ToUniversalTime()
    $state = if ($utc -ge $day) { 'refused' } elseif ($utc -ge $warnFrom) { 'warn' } else { 'none' }
    @{ State = $state; Size = $SizeName; RetiresUtc = $r.RetiresUtc; Series = @($r.Series); WarnFromUtc = $warnFrom.ToString('yyyy-MM-dd') }
}

function Test-VmfSizeRetiredForTool {
    <#
    .SYNOPSIS
        RETIRE-SCOPE-1: is a machine on this size outside the scope of this
        tool now - on or after one day before the size's retirement date?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    (Get-VmfPutBackRetirement -SizeName $Size -Now ($Now.ToUniversalTime().AddDays(1)) -Families $Families).State -eq 'refused'
}

function Get-VmfRetiredScopeDetail {
    <#
    .SYNOPSIS
        RETIRE-SCOPE-1: the words for a machine on a size that is outside the
        scope of this tool now, with the size and the date. $null for any
        other size.
    .DESCRIPTION
        The rule (OLD-FAM-3): a scope refusal is said as SCOPE, never as an
        invented technical reason. What to do is Microsoft's: resize the
        machine to a supported size; then the product assesses it again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families,
        # REVIEW: the size is the one a rollback returns the machine to (its
        # first capture), not the size it is on now - after a rebuild as the
        # target the machine already runs on a supported size, and telling it
        # to resize would be wrong.
        [Parameter()][switch]$RollbackSize
    )
    if (-not (Test-VmfSizeRetiredForTool -Size $Size -Now $Now -Families $Families)) { return $null }
    $retiresWords = Get-VmfRetiresWords -Size $Size -Now $Now -Families $Families
    if ($RollbackSize) {
        return "A rollback returns this machine to $Size. $retiresWords From one day before that date, a return to that size is outside the scope of this tool."
    }
    "$retiresWords From one day before that date, a machine on that size is outside the scope of this tool. " +
        'Resize the machine to a size that Microsoft supports, then assess it again.'
}

function Get-VmfRetiresWords {
    <#
    .SYNOPSIS
        "Microsoft retires <size> on <date>." - or "retired", once the date has
        passed (REVIEW, ASD-STE100: a past date in the present tense).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    $r = Get-VmfPutBackRetirement -SizeName $Size -Now $Now -Families $Families
    if (-not $r.RetiresUtc) { return $null }
    if ($r.State -eq 'refused') { "Microsoft retired $Size on $($r.RetiresUtc)." } else { "Microsoft retires $Size on $($r.RetiresUtc)." }
}

function Get-VmfRetiredRollbackRefusal {
    <#
    .SYNOPSIS
        REVIEW of RETIRE-SCOPE-1: for the automatic rollback, the words when
        the size it returns the machine to is ALREADY retired (on or after the
        date), so Azure refuses it. $null otherwise.
    .DESCRIPTION
        PRECHECK refuses such a machine from one day before the date, so this
        is reached only by a move that passed PRECHECK before then and resumed
        past the date (a worker that stopped, a wave started again). Trying the
        rollback would stop the machine and ask Azure for a size it refuses -
        on Path B with the definition already deleted - so it is not started.
        On the margin day itself the size still runs, and the rollback goes on.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    if ((Get-VmfPutBackRetirement -SizeName $Size -Now $Now -Families $Families).State -ne 'refused') { return $null }
    "$(Get-VmfRetiresWords -Size $Size -Now $Now -Families $Families) A machine on that size is outside the scope of this tool, " +
        'so the product did not start the rollback. The machine is as the failed step left it.'
}

function Get-VmfRetirementWarning {
    <#
    .SYNOPSIS
        RETIRE-SCOPE-1: the warning for a move whose rollback returns the
        machine to a size Microsoft retires within the next 12 months, and
        which is not yet outside the scope of this tool. $null otherwise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    $r = Get-VmfPutBackRetirement -SizeName $Size -Now $Now -Families $Families
    if ($r.State -ne 'warn' -or (Test-VmfSizeRetiredForTool -Size $Size -Now $Now -Families $Families)) { return $null }
    "Microsoft retires $Size, the size a rollback returns this machine to, on $($r.RetiresUtc). " +
        'From one day before that date, a machine on that size is outside the scope of this tool. Move this machine before then.'
}

function Get-VmfMoveRetirementRecord {
    <#
    .SYNOPSIS
        What PRECHECK records on the machine (captured.putBackRetirement) for
        the restore dialog: the size and its dates, or $null when the size has
        no retirement entry.
    .DESCRIPTION
        These three fields only: the vm-state contract (v48) allows no other
        (OLD-STATE-READERS-FINISH-1).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    $r = Get-VmfPutBackRetirement -SizeName $Size -Now $Now -Families $Families
    if (-not $r.RetiresUtc) { return $null }
    [ordered]@{ size = $Size; retiresUtc = $r.RetiresUtc; warnFromUtc = $r.WarnFromUtc }
}

function Get-VmfPutBackRetirementCheck {
    <#
    .SYNOPSIS
        For a person's return to the size a machine had - Restore this machine
        from the first copy, Rebuild this machine as it was - before anything
        changes: refused, warned, or nothing to say.
    .OUTPUTS
        @{ Refuse; Warn; Detail }. The refusal is RETRY-GATE-1's form: what did
        not happen, and why, in one sentence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][string]$VmName = 'this machine',
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime(),
        [Parameter()][AllowNull()]$Families
    )
    $r = Get-VmfPutBackRetirement -SizeName $Size -Now $Now -Families $Families
    if (-not $r.RetiresUtc) { return @{ Refuse = $false; Warn = $false; Detail = $null } }
    if (Test-VmfSizeRetiredForTool -Size $Size -Now $Now -Families $Families) {
        return @{ Refuse = $true; Warn = $false
            # REVIEW: at most 25 words, the form RETRY-GATE-1 uses.
            Detail = "Nothing changed for $VmName, because a return to $Size is outside the scope of this tool from one day before Microsoft $(if ($r.State -eq 'refused') { 'retired' } else { 'retires' }) it on $($r.RetiresUtc)." }
    }
    if ($r.State -eq 'warn') {
        return @{ Refuse = $false; Warn = $true
            Detail = "Microsoft retires $Size on $($r.RetiresUtc). From one day before that date, the product does not return a machine to that size." }
    }
    @{ Refuse = $false; Warn = $false; Detail = $null }
}

function Get-VmfPutBackRetirementRefusal {
    <#
    .SYNOPSIS
        For the service, before it starts a restore from the first copy or a
        rebuild as it was: the refusal when the size the machine goes back to
        is outside the scope of this tool, from the machine's record alone.
        $null when it may start, or when there is no record to read: the
        engine asks again before it stops anything.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime())
    $recorded = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
    if (-not $doc -or -not $doc.captured -or -not $doc.captured.vmConfig) { return $null }
    # ROLLBACK-RETRY-CAPTURE-1: the size it goes back to is the FIRST capture's.
    $capture = Get-VmfPutBackCapture -Doc $doc
    # ROLLBACK-SIZE-REFUSED-SERIES-1: a restore onto the target size of the
    # plan goes to that size, and one it refuses is refused here too.
    $onto = Get-VmfRestoreOntoTargetForRun -RunPath $RunPath -VmId $recorded -Doc $doc
    if ($onto -and $onto.Refusal) { return [string]$onto.Refusal }
    $size = if ($onto) { [string]$onto.Size } else { [string]$capture.size }
    $check = Get-VmfPutBackRetirementCheck -Size $size -VmName (($recorded -split '/')[-1]) -Now $Now
    if ($check.Refuse) { return $check.Detail }
    $null
}
