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

# NO-STACKS-2: the heading said '(the stack does not own them)'. Nothing owns
# them, because there is no stack - and the next line already says the useful
# half of it.
Write-Step 'The two Entra registrations'
Write-Host '   The platform is gone. These are the last things the install made.'
Write-Host ''

$names = Get-VmfRegistrationNames
$remove = Read-VmfChoice -Name 'VMF_REMOVE_REGISTRATIONS' -Default 'yes' `
    -Question "Remove the two registrations, $($names.Api) and $($names.Dashboard)?" `
    -Options @('yes|Yes. Nothing else uses them.', 'no|No. Keep them; a later install with the same environment name adopts them.')

# BOTH of these belong with the removal, and moved here with it.
#
# The choice is per run, never remembered: the next install asks again. And the
# registration key goes, so the NEXT install cannot collide with the tombstones
# this removal creates - Entra keeps a deleted application's uniqueName for 30
# days, a new key sidesteps it, and preprovision generates one when it finds
# none.
#
# They are cleared whether or not the registrations were removed. The question
# has been answered either way, and a kept registration keeps its key because
# preprovision only generates one when there is nothing to preserve.
function Clear-VmfRegistrationState {
    Set-AzdValue -Name 'VMF_REMOVE_REGISTRATIONS' -Value ''
    Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''
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
