# EVAL-C1 / EVAL-H2, from the 2026-08-28 self-evaluation, after
# REBUILD-REMOVE-ENGINE-1.
#
# The rebuild around the same disks (Path B) replayed a hand-maintained list of
# properties from the capture onto a new machine, and this file held that list
# and the refusal of a machine whose capture held a property the list did not
# know. The rebuild was removed on 2026-11-07, and the list and the
# refusal went with it (Get-VmfCaptureFieldPolicy, Test-VmfCaptureReproducible,
# Test-VmfIdentityReproducible).
#
# What stays is the comparison VALIDATING runs on every move: the identity and
# the Ultra Disk capability the machine had before the move, held to what it
# has now - "should never change" is an assumption, and this step exists to
# retire assumptions. And the storage topology the guest reports, below.
function Test-VmfRebuildFidelity {
    <#
    .SYNOPSIS
        Did the machine keep the identity and capability it had? Pure
        comparison, run by VALIDATING on every move.
    .DESCRIPTION
        Unknown stays unknown: a capture taken before these fields existed
        cannot be compared, and says so rather than passing or failing.
        REBUILD-REMOVE-ENGINE-1: a new object ID for a system-assigned identity
        is always a MISMATCH. The acceptance of an identity loss went with the
        rebuild, which was the only move that deleted one.
    .OUTPUTS
        @{ Ok = <bool>; Verdict = 'MATCH'|'MISMATCH'|'UNKNOWN'; Detail = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Captured,
        [Parameter()][AllowNull()]$Live
    )

    if (-not $Captured) {
        return @{ Ok = $true; Verdict = 'UNKNOWN'; Detail = 'nothing was recorded about this machine before the move, so there is nothing to compare' }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    $unknowns = [System.Collections.Generic.List[string]]::new()

    # --- identity -----------------------------------------------------------
    $capIdentity = if ($Captured.PSObject.Properties['identity']) { $Captured.identity } else { $null }
    $capType = if ($capIdentity) { [string]$capIdentity.type }
               elseif ($Captured.PSObject.Properties['identityType']) { [string]$Captured.identityType }
               else { $null }
    if ($null -eq $capType -and -not $Captured.PSObject.Properties['identityType']) {
        $unknowns.Add('managed identity (not recorded before the move)')
    }
    else {
        $liveType = if ($Live -and $Live.PSObject.Properties['identityType']) { [string]$Live.identityType } else { '' }
        $capWanted = if ($capType) { $capType } else { 'None' }
        $liveHas = if ($liveType) { $liveType } else { 'None' }
        if ($capWanted -ne $liveHas) {
            $problems.Add("its managed identity was '$capWanted' before the move and is '$liveHas' now")
        }
        elseif ($capWanted -match 'SystemAssigned') {
            # IDENTITY-2: the types can match while the machine is NOT as it
            # was - a new principal is the one loss in this whole comparison
            # that cannot be undone. Compare the principal itself.
            $capPrincipal = if ($capIdentity -and $capIdentity.PSObject.Properties['principalId']) { [string]$capIdentity.principalId } else { '' }
            $livePrincipal = if ($Live -and $Live.PSObject.Properties['identityPrincipalId']) { [string]$Live.identityPrincipalId } else { '' }
            if (-not $capPrincipal -or -not $livePrincipal) {
                $unknowns.Add('whether this machine kept the same identity (its identity was not recorded in enough detail before the move)')
            }
            elseif ($capPrincipal -ne $livePrincipal) {
                $problems.Add("its identity is a NEW one - it was $capPrincipal before the move and is $livePrincipal now, so anything that granted access to the old one no longer trusts this machine")
            }
        }
        # IDENTITY-ACCEPT-VALIDATE-1: compared whenever the machine had
        # user-assigned identities - also beside a system-assigned one. This was
        # an elseif of the system-assigned branch, so a machine with both kinds
        # that came back without one of them passed.
        if ($capWanted -match 'UserAssigned' -and $capIdentity -and @($capIdentity.userAssignedIds).Count -gt 0) {
            $capIds = @($capIdentity.userAssignedIds | ForEach-Object { [string]$_ } | Sort-Object)
            $liveIds = @(if ($Live -and $Live.PSObject.Properties['userAssignedIds']) {
                @($Live.userAssignedIds) | ForEach-Object { [string]$_ }
            }) | Sort-Object
            $lost = @($capIds | Where-Object { $_ -notin $liveIds })
            if ($lost.Count -gt 0) {
                $problems.Add("it has lost $($lost.Count) assigned identity/identities: " + (($lost | ForEach-Object { ($_ -split '/')[-1] }) -join ', '))
            }
        }
    }

    # --- ultra disk capability ---------------------------------------------
    if ($Captured.PSObject.Properties['ultraSsdEnabled']) {
        $capUltra = [bool]$Captured.ultraSsdEnabled
        $liveUltra = if ($Live -and $Live.PSObject.Properties['ultraSsdEnabled']) { [bool]$Live.ultraSsdEnabled } else { $false }
        if ($capUltra -and -not $liveUltra) {
            $problems.Add('it can no longer use Ultra Disks, and it could before the move')
        }
    }

    if ($problems.Count -gt 0) {
        return @{ Ok = $false; Verdict = 'MISMATCH'; Detail = ($problems -join '; ') }
    }
    if ($unknowns.Count -gt 0) {
        return @{ Ok = $true; Verdict = 'UNKNOWN'; Detail = ($unknowns -join '; ') }
    }

    @{ Ok = $true; Verdict = 'MATCH'; Detail = 'identity and disk capability are as they were' }
}

function Get-VmfStorageFacts {
    <#
    .SYNOPSIS
        LVM-1 / STORAGE-SPACES-1: pull the customer's volume topology out of a
        guest script's checks, on either platform. Pure.
    .DESCRIPTION
        The guest scripts report volume managers as INFO checks, per the
        SCSI-direction rule. This turns those checks into the few comparable
        numbers that matter, so the same comparison works for LVM and for
        Storage Spaces without either one knowing about the other.

        Everything is nullable and $null means NOT REPORTED - an older script,
        or an image whose tooling could not be asked. That has to stay distinct
        from "none", because a machine with no volume manager and a machine we
        could not ask about one look identical otherwise, and only one of them
        is safe to pass.
    .OUTPUTS
        @{ Groups = <int|null>; Volumes = <int|null>; Incomplete = <string|null>
           Unmounted = <string|null>; Reported = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$GuestOutput)

    $checks = @(if ($GuestOutput -and $GuestOutput.PSObject.Properties['checks']) { $GuestOutput.checks })
    $get = { param($name) @($checks | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1).detail }

    $facts = @{ Groups = $null; Volumes = $null; Incomplete = $null; Unmounted = $null; Reported = $false }

    # --- Linux: LVM ---------------------------------------------------------
    $topology = & $get 'lvm topology'
    if ($topology) {
        $facts.Reported = $true
        if ($topology -match '(\d+) volume group') { $facts.Groups = [int]$Matches[1] }
        if ($topology -match '(\d+) logical volume') { $facts.Volumes = [int]$Matches[1] }
    }
    $complete = & $get 'lvm volume groups complete'
    if ($complete) { $facts.Reported = $true; if ($complete -match 'INCOMPLETE:(.*)') { $facts.Incomplete = $Matches[1].Trim() } }
    $mounted = & $get 'lvm volumes mounted'
    if ($mounted) { $facts.Reported = $true; if ($mounted -match 'NOT MOUNTED:(.*?) - ') { $facts.Unmounted = $Matches[1].Trim() } }
    # A Linux machine that reported "no LVM in use" HAS answered the question.
    $lvmRoot = & $get 'lvm root'
    if ($lvmRoot) {
        $facts.Reported = $true
        if ($lvmRoot -match 'no LVM in use') { if ($null -eq $facts.Groups) { $facts.Groups = 0 }; if ($null -eq $facts.Volumes) { $facts.Volumes = 0 } }
    }

    # --- Windows: Storage Spaces --------------------------------------------
    $pools = & $get 'storage pools'
    if ($pools) {
        $facts.Reported = $true
        if ($pools -eq 'none') { $facts.Groups = 0; $facts.Volumes = 0 }
        elseif ($pools -match 'could not be inspected') { $facts.Reported = $false }
        else { $facts.Groups = @([regex]::Matches($pools, '\[health=')).Count }
    }
    $vols = & $get 'storage volumes'
    if ($vols -and $vols -ne 'none') { $facts.Volumes = @([regex]::Matches($vols, '\[health=')).Count }
    $missing = & $get 'storage pool disks missing'
    if ($missing -and $missing -match 'MISSING:(.*)') { $facts.Incomplete = $Matches[1].Trim() }

    $facts
}

function Test-VmfStorageTopology {
    <#
    .SYNOPSIS
        LVM-1 / STORAGE-SPACES-1: did the customer's volumes come back?
    .DESCRIPTION
        The reason it needs its own comparison: a volume group
        or storage pool on DATA disks is not boot-critical. After a Path B
        recreate the machine comes up, the agent reports Ready, the boot disk is
        on NVMe, the drivers are bound, and every other check in VALIDATING
        passes - while the filesystem holding the application's data is absent,
        because the recreate detached and reattached the data disks and the
        group came back a member short.

        Nothing else in this engine can see that. The ARM-level capture sees
        DISKS; volume groups live inside the guest.

        UNKNOWN IS NOT A PASS AND NOT A FAIL. If either side did not report -
        an older guest script, an image with no LVM tooling or no Storage
        module - the answer is that we cannot tell, and the operator is told
        so. Failing there would roll back healthy machines for a missing
        script; passing would be the silent loss this exists to prevent.
    .OUTPUTS
        @{ Ok = <bool>; Verdict = 'MATCH'|'MISMATCH'|'UNKNOWN'; Detail = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After
    )

    $b = Get-VmfStorageFacts -GuestOutput $Before
    $a = Get-VmfStorageFacts -GuestOutput $After

    if (-not $b.Reported -or -not $a.Reported) {
        # STORAGE-BEFORE-1: say WHICH side is missing. "before or after" sent
        # the reader to check both, when the cause was one specific thing - a
        # run that resumed past the capture - and the STOPPED step already
        # wrote the reason. A verdict that names its cause can be acted on.
        $side = if (-not $b.Reported -and -not $a.Reported) { 'before or after' }
                elseif (-not $b.Reported) { 'before' } else { 'after' }
        return @{ Ok = $true; Verdict = 'UNKNOWN'
                  Detail = "this machine was not asked about its storage volumes $side the move, so the product cannot say whether they are complete" }
    }
    if ($b.Groups -eq 0 -and $a.Groups -eq 0) {
        return @{ Ok = $true; Verdict = 'MATCH'; Detail = 'this machine uses no volume groups or storage pools' }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $b.Groups -and $null -ne $a.Groups -and $a.Groups -lt $b.Groups) {
        $problems.Add("it had $($b.Groups) volume group(s) or storage pool(s) before the move and has $($a.Groups) now")
    }
    if ($null -ne $b.Volumes -and $null -ne $a.Volumes -and $a.Volumes -lt $b.Volumes) {
        $problems.Add("it had $($b.Volumes) volume(s) before the move and has $($a.Volumes) now")
    }
    # A group that is short a disk is the specific shape a recreate produces.
    if ($a.Incomplete) {
        $problems.Add("a volume group or pool is missing one or more of its disks: $($a.Incomplete)")
    }
    if ($a.Unmounted) {
        $problems.Add("a volume the machine expects is not mounted: $($a.Unmounted)")
    }

    if ($problems.Count -gt 0) {
        return @{ Ok = $false; Verdict = 'MISMATCH'; Detail = ($problems -join '; ') }
    }
    @{ Ok = $true; Verdict = 'MATCH'; Detail = 'every volume group and storage pool is complete' }
}
