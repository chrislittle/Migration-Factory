<#
.SYNOPSIS
    TEARDOWN-1: the Entra registrations, removed AFTER the platform is gone.
.DESCRIPTION
    A stack cannot hold an Entra object, so the two registrations live outside
    it and `azd down` would leave them behind. Something has to remove them,
    and for a long time that was `predown` - which runs BEFORE anything is
    deleted.

    MEASURED 2026-09-11, on a corporate subscription. An `azd up`
    failed on AKS capacity in centralus. `azd down` then:

      * ran predown, which deleted both registrations;
      * deleted the deployment stack;
      * DETACHED the 14 resources instead of deleting them;
      * left 25 deny assignments behind, owned by a stack that no longer
        existed, which then refused every attempt to delete the resource
        group by hand;
      * and printed "No Azure resources were found" and "SUCCESS: Your
        application was removed from Azure in 15 seconds".

    So the platform was entirely intact, still billing, still protected from
    deletion - and nobody could sign in to it, because the one step that DID
    succeed was the one this hook used to do.

    The order was backwards. A thing outside the stack must be removed once
    the stack is gone, not before, and `postdown` runs only when the removal
    actually succeeded. If it fails, the registrations are still there and the
    product still works.

    THE QUESTION IS ASKED HERE TOO, not recorded in predown and read back.
    `azd down` clears recorded decisions (DRILL-F, 2026-09-09), so an answer
    carried between two hooks is an answer that can go missing between them.
    Asking where the work happens needs no state at all.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzdHooks.ps1')

# AZD-DOWN-RG-RECHECK-1: READ THE RESOURCE GROUP BEFORE ANYTHING IS REMOVED.
#
# azd runs this hook after a delete it saw succeed. It is also the way to
# finish a removal that azd stopped (azd hooks run postdown), and predown runs
# it when the group is already gone. In each case the registrations go only
# when Azure says the resource group is gone: removed while the platform runs,
# nobody can sign in to it (TEARDOWN-1). A group that is still there is never
# deleted here - azd down deletes it, and then runs this hook.
#
# The name is the one predown recorded: a successful azd down has cleared
# AZURE_RESOURCE_GROUP before this runs (measured, azd 1.39.1).
Write-Step 'The resource group'
$downGroup = Get-VmfDownResourceGroupName
$downSubscription = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
$groupState = Wait-VmfResourceGroupGone -Name $downGroup -Subscription $downSubscription
switch ($groupState.State) {
    'gone' { Write-Host "   The resource group $downGroup is gone." }
    'deleting' {
        Write-Host "   Azure is still deleting the resource group $downGroup. The two Entra registrations stay."
        Write-Host '   When the resource group is gone, type azd hooks run postdown to remove them.'
        exit 1
    }
    'present' {
        Write-Host "   The resource group $downGroup is still in Azure. The two Entra registrations stay, so you can still sign in to the product."
        Write-Host '   Type azd down again. It deletes the resource group, and then it removes the registrations.'
        exit 1
    }
    default {
        if (-not $downGroup) {
            Write-Host '   The name of the resource group is not recorded, so the removal cannot make sure that the platform is gone.'
        }
        else {
            Write-Host "   The removal could not read the resource group ${downGroup}: $($groupState.Detail)"
        }
        Write-Host '   The two Entra registrations stay. When Azure answers, type azd hooks run postdown again.'
        exit 1
    }
}

# NO-STACKS-2: the heading said '(the stack does not own them)'. Nothing owns
# them, because there is no stack - and the next line already says the useful
# half of it.
Write-Step 'The two Entra registrations'
Write-Host '   The platform is gone. These are the last things the install made.'
Write-Host ''

$names = Get-VmfRegistrationNames
$remove = Read-VmfChoice -Name 'VMF_REMOVE_REGISTRATIONS' -Default 'yes' `
    -Question "Remove the two registrations, $($names.Api) and $($names.Dashboard)?" `
    -Options @('yes|Yes. Nothing else uses them.', 'no|No. Keep them. A later install with this environment name then stops, until an administrator removes them.')

# BOTH of these belong with the removal, and moved here with it.
#
# The choice is per run, never remembered: the next install asks again. And the
# registration key goes, so the NEXT install cannot collide with the tombstones
# this removal creates - Entra keeps a deleted application's uniqueName for 30
# days, a new key sidesteps it, and preprovision generates one when it finds
# none.
#
# They are cleared whether or not the registrations were removed. The question
# has been answered either way. INSTALL-ADOPT-OWNER-1: a kept pair is NOT used
# again. With no key, preprovision stops on any registration with the names,
# because nothing the directory shows proves who made it; the operator removes
# the pair or chooses another environment name. (Before, the empty key made a
# second registration beside each kept one, so reuse never worked.)
#
# AZD-DOWN-RG-RECHECK-1: the name predown recorded goes too. The removal is
# finished, and a name kept after it could point a later run of this hook at a
# group from an earlier install.
function Clear-VmfRegistrationState {
    Set-AzdValue -Name 'VMF_REMOVE_REGISTRATIONS' -Value ''
    Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''
    Set-AzdValue -Name 'VMF_DOWN_RESOURCE_GROUP' -Value ''
}

if ($remove -ne 'yes') {
    Write-Host '   kept'
    Clear-VmfRegistrationState
    return
}

# BOTH registrations are resolved before EITHER is deleted, and each by an
# exact name: `--display-name ... --query '[0].id'` deleted whichever
# application the directory listed first, and a display name is not unique in
# Entra. A name that finds two registrations, or a directory call that fails,
# leaves that registration in place and says so - the platform is already gone
# either way.
#
# ID-ADDRESS-1: BY THE ID THE INSTALL RECORDED FIRST. preprovision records each
# registration's application id, and that id is the object this install made -
# a name is only what it was called. The registration there must still carry
# the name, or it is left. When an id is recorded it is the whole answer: a
# registration that has the name but not the id is somebody else's, even
# when the one with the id is gone. Only with no id recorded (azd down may
# clear the values, DRILL-F) is the exact-name lookup the answer. The install
# blanks the ids before it deploys the registrations and records them after,
# so an id is never one from before a failed deployment.
$found = foreach ($want in @(@($names.Api, 'VMF_API_APP_ID'), @($names.Dashboard, 'VMF_DASHBOARD_APP_ID'))) {
    $n = $want[0]
    $recordedId = Get-AzdValue -Name $want[1]
    try {
        $app = if ($recordedId) { Get-VmfEntraApplicationByAppId -AppId $recordedId -DisplayName $n }
               else { Get-VmfEntraApplication -DisplayName $n }
        [pscustomobject]@{ Name = $n; IdKey = $want[1]; App = $app; Problem = '' }
    }
    catch { [pscustomobject]@{ Name = $n; IdKey = $want[1]; App = $null; Problem = $_.Exception.Message } }
}
# A registration that is removed, or is not there, takes its recorded id with
# it: an id kept after this would point the next removal at nothing. One left
# in place keeps its id, so the next removal finds it again.
foreach ($entry in $found) {
    if ($entry.Problem) { Write-Host "   $($entry.Name) is left in place: $($entry.Problem)"; continue }
    if (-not $entry.App) {
        Write-Host "   $($entry.Name) was not found"
        Set-AzdValue -Name $entry.IdKey -Value ''
        continue
    }
    Invoke-VmfAzStep -Step "removing the registration $($entry.Name)" -Command {
        az ad app delete --id ([string]$entry.App.id) -o none
    } | Out-Null
    Set-AzdValue -Name $entry.IdKey -Value ''
    Write-Host "   removed $($entry.Name)"
}

Clear-VmfRegistrationState
