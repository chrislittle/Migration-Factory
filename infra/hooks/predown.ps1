<#
.SYNOPSIS
    INSTALL-1: what has to be true before `azd down` removes the platform.
.DESCRIPTION
    A safety copy is a snapshot this tool took before it changed a machine.
    It lives in the resource group of that machine, never in this product's,
    so the removal leaves every one of them - and takes away the daily pass
    that deletes them when their retention ends.

    FIND-COPY-1 (2026-09-10): this SAYS SO and lets the removal go
    ahead. It used to refuse, with VMF_ACCEPT_PENDING_COPIES to walk past the
    refusal - a gate that only fired on `azd down`, that had its own way out,
    and whose "accept the loss" named nothing that was being lost. What helps
    is a command that still works after the product is gone, so this runs the
    tag search and prints what it found. Copies taken WITHOUT a lock (an
    install whose identity may not place locks) are not counted here, and that
    is said too.

    Then the Entra registrations: the stack does not own them (Entra objects
    cannot live in one), so `azd down` would leave them behind. This offers
    to remove them, as the signed-in person.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzdHooks.ps1')

$subscription = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'

# AZD-DOWN-RG-RECHECK-1: RECORD THE NAME OF THE RESOURCE GROUP FIRST.
# MEASURED 2026-11-20, azd 1.39.1: a successful azd down clears
# AZURE_RESOURCE_GROUP (a deployment output) before postdown runs, and keeps a
# value written here. postdown reads the group by this name before it removes
# the registrations. With no AZURE_RESOURCE_GROUP, a name an earlier removal
# recorded stays: only a finished removal clears it.
$rgNow = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
if ($rgNow) { Set-AzdValue -Name 'VMF_DOWN_RESOURCE_GROUP' -Value $rgNow }
$downGroup = Get-VmfDownResourceGroupName
Write-Step 'Safety copies'
# FIND-COPY-1: THIS TELLS YOU. IT DOES NOT STOP YOU.
#
# It used to refuse the removal while any safety copy was locked, and offered
# VMF_ACCEPT_PENDING_COPIES to walk past the refusal. Now it says the copies
# are left behind and gives the az command, by tag, for the customer to clean
# them up. That is right, for three reasons:
#
#   * the refusal only ever fired on `azd down`. Deleting the resource group in
#     the portal, `az group delete`, or a subscription going away all skip this
#     hook entirely. A gate on one road out of several is not a gate.
#   * it had its own way out, so it stopped nobody who meant it.
#   * "accept the loss" named nothing. Nothing is lost at that moment; what
#     happens is that the copies stay, for good, because the daily pass that
#     would delete them is inside the product being removed.
#
# What actually helps is a command that still works after the product is gone.
#
# DRILL-F's lesson survives the change of shape: this once printed "locked
# safety copies: 0" having made no count at all. A number here must be one that
# was measured. "Could not be counted" is an answer; a made-up zero is not.
$locks = $null
$cannotCount = ''
if (-not $subscription) {
    $cannotCount = 'AZURE_SUBSCRIPTION_ID is not set'
}
else {
    # INSTALL-THROTTLE-RETRY-2: each listing here tries a throttled answer
    # again (Invoke-VmfAzCall); a listing that still fails is "not counted".
    $lockRead = Invoke-VmfAzCall -Step 'list the locks' -Quiet -Command { az lock list --subscription $subscription -o json }
    if ($lockRead.ExitCode -ne 0) {
        $cannotCount = "the locks in subscription $subscription could not be listed"
    }
    else { $locks = @($lockRead.Output | ConvertFrom-Json | Where-Object { $_.name -eq 'vmf-safety-copy' }) }
}

# The tag search, RUN rather than promised.
#
# POLICY-REVERT-1: a policy with the modify effect strips tags and reports
# success. Printing a command without running it would hand somebody a query
# that answers "none" for a subscription full of copies. Running it here is one
# control-plane call - it works with the store locked down, because it reads
# resources rather than their contents - and what it prints is the truth.
$tagged = $null
if ($subscription) {
    $copyRead = Invoke-VmfAzCall -Step 'list the safety copies' -Quiet -Command { az resource list --tag vmfSafetyCopy=true --subscription $subscription -o json }
    if ($copyRead.ExitCode -eq 0) { $tagged = @($copyRead.Output | ConvertFrom-Json | Where-Object { $_.type -eq 'Microsoft.Compute/snapshots' }) }
}

$countText = if ($cannotCount) { "not counted, because $cannotCount" } else { "$($locks.Count)" }
# ID-ADDRESS-1: every count here is made in the INSTALL's subscription, and
# says so. The product may have moved machines in other subscriptions, and
# their copies and reservations are there - a count that did not say where it
# looked would read as "all of them".
Write-Host "   locked safety copies in $(if ($subscription) { "subscription $subscription" } else { "the install's subscription" }): $countText"
Write-Host '   copies taken without a lock are not counted here.'
Write-Host '   Machines in other subscriptions keep their copies there. Add --subscription <id> to the commands below for each one.'
Write-Host ''
Write-Host '   These copies are in the resource groups of the machines they came from, not in this'
Write-Host '   product. The removal leaves every one of them. It also removes the daily pass that'
Write-Host '   deletes them when their retention ends, so from now on they stay until you remove them.'
Write-Host ''
if ($null -ne $tagged -and $tagged.Count -gt 0) {
    Write-Host "   Find them at any time, now or after the removal ($($tagged.Count) today):"
    Write-Host '     az resource list --tag vmfSafetyCopy=true -o table'
    Write-Host '   Each copy carries the machine, the run and the days its wave keeps it, as tags.'
    Write-Host '   To remove one, delete its lock and then the snapshot. See "Remove the product" in the manual.'
}
elseif ($null -ne $locks -and $locks.Count -gt 0) {
    # Copies exist and the tag search found none: a policy here removes tags.
    # Say so, and send them to the marker that IS there.
    Write-Host '   The copies carry no tags this search can find, so they are listed by their lock instead:'
    Write-Host '     az lock list --subscription <id> -o table'
    Write-Host '   The lock named vmf-safety-copy is on each copy. Its scope is the copy.'
}
else {
    Write-Host '   Find them at any time, now or after the removal:'
    Write-Host '     az resource list --tag vmfSafetyCopy=true -o table'
}

Write-Step 'Capacity reservations'
# UNINSTALL-RESERVE-1: THE SAME RULE AS THE SAFETY COPIES - TELL, DO NOT STOP.
#
# A capacity reservation bills for the size it holds, used or not, until it is
# deleted. It lives in the resource group of the machines it was made for
# (CAPRG-1), not in this product, so the removal leaves it - and takes away
# every record of it, and the Release on the wave card. So this lists them,
# with a command that still works after the product is gone.
#
# Found two ways: by the tag every group carries (UNINSTALL-RESERVE-1), and by
# the vmf- name every group has, for a group whose tag a policy removed
# (POLICY-REVERT-1). A count that could not be made is said as such - never a
# made-up zero (DRILL-F).
$reservationGroups = $null
$reservationCannotCount = ''
$reservationPartial = ''
if (-not $subscription) {
    $reservationCannotCount = 'AZURE_SUBSCRIPTION_ID is not set'
}
else {
    $tagRead = Invoke-VmfAzCall -Step 'list the capacity reservations by tag' -Quiet -Command {
        az resource list --tag vmfCapacityReservation=true --subscription $subscription -o json
    }
    $tagOk = $tagRead.ExitCode -eq 0
    $byTag = if ($tagOk) { $tagRead.Output | ConvertFrom-Json } else { $null }
    $typeRead = Invoke-VmfAzCall -Step 'list the capacity reservation groups' -Quiet -Command {
        az resource list --resource-type Microsoft.Compute/capacityReservationGroups --subscription $subscription -o json
    }
    $typeOk = $typeRead.ExitCode -eq 0
    $byType = if ($typeOk) { $typeRead.Output | ConvertFrom-Json } else { $null }
    if (-not $tagOk -and -not $typeOk) {
        $reservationCannotCount = "the resources in subscription $subscription could not be listed"
    }
    else {
        # One listing failed: what the other found is a floor, not a count.
        if (-not $tagOk) { $reservationPartial = 'the search by tag failed' }
        elseif (-not $typeOk) { $reservationPartial = 'the search by name failed' }
        $seen = @{}
        $reservationGroups = @(foreach ($r in @(@($byTag) + @($byType))) {
                if (-not $r -or [string]$r.type -ne 'Microsoft.Compute/capacityReservationGroups') { continue }
                $isOurs = ($r.tags -and [string]$r.tags.vmfCapacityReservation -eq 'true') -or ([string]$r.name -like 'vmf-*')
                if ($isOurs -and -not $seen.ContainsKey([string]$r.id)) { $seen[[string]$r.id] = $true; $r }
            })
    }
}

$groupCount = if ($reservationCannotCount) { "not counted, because $reservationCannotCount" }
elseif ($reservationPartial) { "at least $($reservationGroups.Count), because $reservationPartial" }
else { "$($reservationGroups.Count)" }
Write-Host "   capacity reservation groups this product made, in $(if ($subscription) { "subscription $subscription" } else { "the install's subscription" }): $groupCount"
if ($null -ne $reservationGroups -and $reservationGroups.Count -gt 0) {
    foreach ($g in $reservationGroups) { Write-Host "     $($g.name) (resource group $($g.resourceGroup))" }
    Write-Host ''
    Write-Host '   A reserved slot that no machine uses bills for its size until the reservation is deleted.'
    Write-Host '   These are in the resource groups of the machines, not in this product. The removal'
    Write-Host '   leaves them, and it removes the Release control. Select Release beside each reservation'
    Write-Host '   in the wave editor first, or delete them in Azure after the removal.'
    Write-Host '   See "Remove the product" in the manual for the order of the steps in Azure.'
}
Write-Host '   Find them at any time, now or after the removal:'
Write-Host '     az resource list --tag vmfCapacityReservation=true -o table'
Write-Host '   A policy in your subscription can remove the tag. The name of each group starts with vmf-:'
Write-Host '     az resource list --resource-type Microsoft.Compute/capacityReservationGroups -o table'
Write-Host ''

# TEARDOWN-1: THE REGISTRATIONS WERE REMOVED HERE, AND ARE NOW REMOVED IN
# postdown.ps1 - after the platform is actually gone.
#
# They cannot live in the stack (Entra objects cannot), so something has to
# take them, and this hook was the something. It runs BEFORE anything is
# deleted, which was fine until a teardown failed.
#
# MEASURED 2026-09-11 on a corporate subscription: `azd down` deleted both
# registrations here, deleted the deployment stack, DETACHED the 14 resources
# rather than deleting them, orphaned 25 deny assignments that then refused
# every attempt to remove the resource group by hand - and printed "No Azure
# resources were found" and "SUCCESS: Your application was removed from Azure
# in 15 seconds".
#
# The platform was intact, billing, undeletable by hand, and unusable, because
# the only step that succeeded was this one. A thing outside the stack must go
# once the stack is gone; postdown runs only on a removal that worked.

# NO-STACKS-2: this line said 'azd now removes the deployment stack: every
# resource it created, the resource group included.' There is no stack, so it
# told the operator the removal works in a way it does not. It is also the
# wrong way round: the resource group is the thing deleted, and Azure orders
# what is inside it - which is the whole reason NO-STACKS-1 dropped stacks.
# AZD-DOWN-RG-RECHECK-1: A RESOURCE GROUP THAT IS ALREADY GONE.
#
# FOUND 2026-11-19: an azd down stopped on "context canceled" while Azure went
# on and deleted the group. The next azd down ran this hook, then stopped on
# "404 ResourceGroupNotFound" and never ran postdown (MEASURED again
# 2026-11-20, azd 1.39.1). So no azd down could remove the registrations.
#
# When Azure says the group is gone, the platform is gone, and the reason
# TEARDOWN-1 waits for postdown is met. postdown runs from here, and reads the
# group again itself before it removes anything. A group Azure is still
# deleting is read again, for a fixed time. A group that is there, or a read
# that fails, leaves the removal as it was: azd deletes the group, and postdown
# follows. This hook deletes nothing itself.
Write-Step 'The resource group'
$groupState = Wait-VmfResourceGroupGone -Name $downGroup -Subscription $subscription -PresentSeconds 0
if ($groupState.State -eq 'gone') {
    Write-Host "   The resource group $downGroup is already gone. The removal now does the last step: the two Entra registrations."
    # postdown ends with exit 1 when it removes nothing, so its exit code says
    # whether it got as far as the registrations.
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'postdown.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host ''
    Write-Host '   azd can stop next with the error ResourceGroupNotFound, because the resource group is already gone.'
    Write-Host '   The lines above tell what happened to each registration. You do not have to do this step again.'
    return
}
if ($groupState.State -eq 'deleting') {
    Write-Host "   Azure is still deleting the resource group $downGroup. azd now tries to delete it."
}
elseif ($groupState.State -eq 'unknown') {
    if ($downGroup) { Write-Host "   The removal could not read the resource group ${downGroup}: $($groupState.Detail)" }
    else { Write-Host '   The name of the resource group is not recorded.' }
}

Write-Host ''
Write-Host 'azd now deletes the resource group, and everything in it goes with it.'
