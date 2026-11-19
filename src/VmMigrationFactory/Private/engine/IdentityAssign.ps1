# UAMI-ASSIGN-1: may this account assign each user-assigned managed identity
# of the machine? Asked at PRECHECK, before anything is touched.
#
# Every write of a machine with a user-assigned identity - a resize (Path A),
# a rebuild (Path B), and the rollback of either - assigns the identity again,
# and Azure checks the assign on the IDENTITY, which can be in another resource
# group or subscription. MEASURED 2026-11-01: with the VMF Migration role
# alone, the first write was refused on both paths, and the rollback was
# refused the same way, so the machine was left stopped for a person. Found
# here, the same gap costs a role assignment and nothing on the machine.
#
# The NIC-JOIN-1 way (Test-VmfNicLinkedPermissions): Get-VmfEffectivePermissions
# at the linked scope, Get-VmfMissingActions against the action. Unknown is its
# own answer: a read that fails, or an identity Azure reports with no id, stops
# the machine too - never read as allowed.

function Get-VmfCapturedUserAssignedIdentities {
    <#
    .SYNOPSIS
        The user-assigned identities of a capture (Get-VmfVmCapture), one per
        resource id without regard to letter case. Pure.
    .OUTPUTS
        @{ Reported = <the identity type says UserAssigned>; Ids = @(...) }
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Capture)
    $identity = Get-VmfRecordField -Object $Capture -Name 'identity'
    $type = [string](Get-VmfRecordField -Object $identity -Name 'type')
    if (-not $type) { $type = [string](Get-VmfRecordField -Object $Capture -Name 'identityType') }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = @(foreach ($id in @(Get-VmfRecordField -Object $identity -Name 'userAssignedIds')) {
            $s = ([string]$id).Trim()
            if ($s -and $seen.Add($s)) { $s }
        })
    @{ Reported = ($type -match 'UserAssigned'); Ids = $ids }
}

function Test-VmfIdentityAssignPermissions {
    <#
    .SYNOPSIS
        UAMI-ASSIGN-1, at PRECHECK: can this account assign each user-assigned
        identity the machine has? Asked of the IDENTITY, at its own scope.
    .OUTPUTS
        $null when it can, or the machine has no user-assigned identity;
        otherwise the NEEDS_DECISION result, machine untouched:
        permissionMissingIdentity naming each identity and the action, or
        identityAssignNotKnown when the answer could not be read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowNull()]$Capture,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks - the
        # same check, with the words of the restore.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    $why = if ($For -eq 'restore') { 'The restore updates the machine. Each update assigns each user-assigned managed identity again.' }
           else { 'Every change to the machine, and its rollback, assigns the identity again.' }
    $found = Get-VmfCapturedUserAssignedIdentities -Capture $Capture
    if (-not $found.Ids.Count) {
        if (-not $found.Reported) { return $null }
        return @{ Next = 'NEEDS_DECISION'; Reason = 'identityAssignNotKnown'; MachineState = 'untouched'
                  Detail = "Azure reports a user-assigned managed identity on this machine and returned no identity id, so the product cannot check that its managed identity may assign it. $why Nothing on the machine changed." }
    }
    $missing = [System.Collections.Generic.List[object]]::new()
    $unread = [System.Collections.Generic.List[string]]::new()
    foreach ($idNow in $found.Ids) {
        try {
            $perms = Invoke-VmfAzOperation -Name 'identityAssignPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfEffectivePermissions -Scope $idNow
            }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $unread.Add("$idNow ($($_.Exception.Message))")
            continue
        }
        # Test-VmfIdentityAssignHeld, not Get-VmfMissingActions: it also
        # accepts Managed Identity Operator's documented form, for this action
        # only (review of UAMI-ASSIGN-1).
        if (-not (Test-VmfIdentityAssignHeld -Permissions $perms)) {
            $missing.Add([pscustomobject]@{ Scope = $idNow; Action = $script:VmfIdentityAssignAction })
        }
    }
    if ($missing.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'permissionMissingIdentity'; MachineState = 'untouched'
                  Detail = (Format-VmfIdentityAssignMissingMessage -Missing @($missing) -Unread @($unread) -For $For) }
    }
    if ($unread.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'identityAssignNotKnown'; MachineState = 'untouched'
                  Detail = "$(if ($For -eq 'restore') { 'This machine has a user-assigned managed identity. The restore updates the machine. Each update assigns each user-assigned managed identity again.' } else { 'This machine has a user-assigned managed identity, and every change to the machine, and its rollback, assigns the identity again.' }) Azure checks $($script:VmfIdentityAssignAction) on the identity for that, and the product could not read whether its managed identity has it: $($unread -join '; '). Nothing on the machine changed." }
    }
    $null
}
