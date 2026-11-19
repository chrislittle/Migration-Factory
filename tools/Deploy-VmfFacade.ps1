<#
.SYNOPSIS
    PKG-1: publish the facade's CODE. The infrastructure comes from
    infra/platform.bicep and the Entra registrations from infra/identity.bicep.
.DESCRIPTION
    This script used to create the Function App, its plan, its telemetry, its
    settings, its Easy Auth AND the Entra registrations behind them. All of
    that now lives in templates, where a customer deploys it in one step.
    What is left here is only what a template genuinely cannot express:

      1. granting the deploying operator the app roles, so a fresh install
         has someone who can actually use it (GATE-1 will make this the
         first-admin bootstrap).
      2. pushing the code.

    Run infra/identity.bicep and infra/platform.bicep FIRST - they own the
    Entra registrations and the infrastructure respectively. This script
    refuses to guess at either.
.EXAMPLE
    ./tools/Deploy-VmfFacade.ps1 -StorageAccountName <vmfstate...> -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$FunctionAppName = "vmf-facade-$($StorageAccountName -replace '^vmfstate', '')",
    # PUBLISH-IN-1: the registry that builds the package image, and the job that
    # puts it in the store. Both follow the store account's suffix, like the
    # facade's own name above - infra/platform.bicep derives all three from it.
    [string]$AcrName = "vmfacr$($StorageAccountName -replace '^vmfstate', '')",
    [string]$PublishJobName = "vmf-publish-$($StorageAccountName -replace '^vmfstate', '')",
    [string]$ApiDisplayName = 'vmf-api'
)

$ErrorActionPreference = 'Stop'
# The one way this product finds its own registrations: an exact name, and a
# refusal when two carry it.
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRegistration.ps1')
. (Join-Path $PSScriptRoot '..' 'infra' 'New-VmfRunTag.ps1')
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfImageDigest.ps1')
. (Join-Path $PSScriptRoot '..' 'infra' 'Wait-VmfJobRun.ps1')

# INSTALL-THROTTLE-RETRY-1: every az step runs through Invoke-VmfAzStep, which
# tries a throttled answer (HTTP 429) again and stops on any other failure with
# "Deploy step failed (az exit N): <step>" - the words Assert-AzOk used to say.
# MEASURED 2026-11-16: the step "read app settings" below got "Too Many Requests" in the
# final lab, and the install stopped on that one read.
. (Join-Path $PSScriptRoot '..' 'infra' 'Invoke-VmfAzStep.ps1')

# Fixed ids keep re-runs idempotent (Graph treats changed role ids as new roles).
# ALL FOUR are listed because this map is the mirror of identity.bicep, and a
# test fails if the two ever disagree. Only ONE of them is granted - see below.
$RoleIds = [ordered]@{
    'Vmf.Viewer'   = '6f1c3a10-0001-4b6e-9e6a-100000000001'
    'Vmf.Approver' = '6f1c3a10-0002-4b6e-9e6a-100000000002'
    'Vmf.Operator' = '6f1c3a10-0003-4b6e-9e6a-100000000003'
    'Vmf.Admin'    = '6f1c3a10-0004-4b6e-9e6a-100000000004'
}

Write-Host '0/2 checking the platform and its registration exist...'
# ONE read of the app: its name says it exists, and its id addresses the
# sign-in check below. It was two reads of the same resource.
$siteJson = Invoke-VmfAzStep -Step "read the service app $FunctionAppName" -AllowFailure -Command {
    az functionapp show -g $ResourceGroup -n $FunctionAppName -o json
}
$site = if ($siteJson) { try { ($siteJson | Out-String) | ConvertFrom-Json } catch { $null } } else { $null }
if (-not $site -or -not $site.id) {
    throw "The facade '$FunctionAppName' does not exist. Deploy the platform first: az deployment group create -g $ResourceGroup --template-file infra/platform.bicep --parameters baseSuffix=<suffix> ..."
}

# CD-1: this step exists to give the FIRST PERSON a way in - it is a bootstrap,
# not part of publishing code. A pipeline has no person to bootstrap, so it is
# skipped rather than failing the deploy. Detected rather than flagged: a switch
# CI has to remember to pass is a switch CI will one day forget, and the failure
# would look like a broken deploy instead of a skipped nicety.
Write-Host '1/2 make the signed-in operator the first administrator...'
# A probe that is ALLOWED to fail must not leave its exit code behind: pwsh
# returns $LASTEXITCODE as the process exit code, so a deliberate "is anybody
# signed in?" failure made a completely successful publish exit 1 - and the
# step failed after printing every success message it has. Found by the
# pipeline's fourth run.
$me = Invoke-VmfAzStep -Step 'read the signed-in user' -AllowFailure -Command { az ad signed-in-user show --query id -o tsv }

# CD-1: the registration lookup lives HERE, inside the bootstrap, because that
# is the only thing that uses it. Reading it unconditionally meant publishing
# code required permission to read the DIRECTORY - which a deploy pipeline
# should not have, and which failed the pipeline's second run.
#
# BOTH objects are resolved BEFORE the first role is granted, and the
# registration is matched by an EXACT name. Taking the first answer of a
# display-name lookup would grant these roles on an application somebody else
# in the tenant may have registered under the same name.
$apiAppId = $null; $apiSpId = $null
if ($me) {
    $apiApp = Get-VmfEntraApplication -DisplayName $ApiDisplayName
    if (-not $apiApp) {
        throw "The '$ApiDisplayName' registration does not exist, or this account may not read it. Deploy it first: az deployment group create -g $ResourceGroup --template-file infra/identity.bicep --parameters dashboardOrigin=<web endpoint>"
    }
    $apiAppId = [string]$apiApp.appId
    $apiSp = Get-VmfEntraServicePrincipal -AppId $apiAppId
    if (-not $apiSp) {
        throw ("No service principal for the '$ApiDisplayName' registration can be read. Either it was removed, " +
               'or this account may not read service principals. Redeploy infra/identity.bicep.')
    }
    $apiSpId = [string]$apiSp.id
}
if (-not $me) {
    Write-Host '   no signed-in user (running as a service principal) - skipping the first-admin bootstrap'
}
# ROLE-3: ONE role, not four.
#
# This step used to grant all four, and the Admin page showed it: the
# installing user held every role, with the page's own note saying three of
# them could be removed. They were removed, and nothing broke - which is the
# point. Administrator appears in EVERY Assert-VmfFacadeRole call in the
# service, so the other three add no permission to a person who holds it.
#
# The three extra assignments were not merely untidy. They contradicted the
# product in two places at once: the Admin page tells a person to grant the
# SMALLEST role that does the job, and the install then did the opposite on
# the very first account. And every extra assignment is a real object in the
# directory that somebody has to read, judge and remove by hand.
#
# An existing install keeps the three it was given - a code publish must never
# delete a role assignment behind an operator's back. The Admin page already
# draws them quiet, says what covers them, and removes them on one click, which
# is where that decision belongs.
if ($me) {
    $assignFile = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-role-$(New-VmfRunTag).json"
    @{ principalId = $me; resourceId = $apiSpId; appRoleId = $RoleIds['Vmf.Admin'] } |
        ConvertTo-Json | Set-Content $assignFile -Encoding utf8NoBOM
    try {
        Invoke-VmfAzStep -Step 'ask the directory for Vmf.Admin' -AllowFailure -Command {
            az rest --method POST --url "https://graph.microsoft.com/v1.0/users/$me/appRoleAssignments" `
                --headers 'Content-Type=application/json' --body "@$assignFile" --output none
        } | Out-Null
    }
    finally { Remove-Item $assignFile -Force -ErrorAction SilentlyContinue }
    # SAID, NOT CLAIMED. This printed "granted" whatever happened - the exit
    # code is discarded, because an already-assigned role answers with an error
    # and that is success here. So a directory that refused read as a grant.
    # The install reads the assignment back further down and reports what it
    # found; this line says only what was asked.
    Write-Host '   asked the directory for Vmf.Admin'
}

# PUBLISH-IN-1: the operator's own data role on the code container was granted
# here and is gone.
#
# NOFILES-1 gave it to the person installing, because the person uploaded the
# package. They do not: the publish job does, with its own identity, from inside
# the subscription. Nobody who runs this script needs a data role on the store
# in either update model now, which is the point - a laptop that holds no data
# role is a laptop a locked-down store has no reason to admit.

# EVAL-H13: refuse to publish code to a control plane that is not behind
# sign-in. The template now makes that impossible to create, but an app can be
# reconfigured afterwards by hand, and this tool is the last thing to touch it
# before it starts serving. Read the platform's own answer rather than trusting
# the template that was supposed to have set it.
#
# AUTHREAD-1, 2026-09-09, MEASURED on a live install: this gate CRASHED instead
# of refusing. The platform answered without a globalValidation property, and
#
#   $auth.globalValidation.requireAuthentication
#
# threw "The property 'globalValidation' cannot be found on this object" -
# killing the publish after the engine image was built and the job repointed,
# with a message that names a property and nothing a person can act on.
#
# The reason it throws HERE and not in a shell is worth keeping: this script
# sets no strict mode. postprovision.ps1 dot-sources AzdHooks.ps1, which sets
# Set-StrictMode -Version Latest, and strict mode is INHERITED BY CHILD SCOPES.
# Run standalone, the absent property reads as $null and the refusal below
# fires properly. Run from the hook, the same line is fatal. The same code,
# two behaviours, decided by the caller.
#
# So every value is read by name, and an absent one reads as $null in both
# worlds. The gate still FAILS CLOSED - an answer it cannot read is not a pass -
# but it now says whether the platform reported 'off' or reported nothing.
$readAuth = {
    param($Node, [string[]]$Path)
    foreach ($segment in $Path) {
        if ($null -eq $Node) { return $null }
        $property = $Node.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $Node = $property.Value
    }
    $Node
}
$siteId = [string]$site.id
$authJson = Invoke-VmfAzStep -Step 'read the sign-in settings of the service app' -AllowFailure -Command {
    az rest --method GET --url "https://management.azure.com$siteId/config/authsettingsV2/list?api-version=2022-03-01" --query properties
}
$auth = if ($authJson) { try { $authJson | ConvertFrom-Json } catch { $null } } else { $null }
$requireAuth = & $readAuth $auth @('globalValidation', 'requireAuthentication')
$unauthAction = & $readAuth $auth @('globalValidation', 'unauthenticatedClientAction')
$aadEnabled = & $readAuth $auth @('identityProviders', 'azureActiveDirectory', 'enabled')
$said = { param($v) if ($null -eq $v) { 'not reported' } else { "$v" } }
if ($requireAuth -ne $true -or $unauthAction -ne 'Return401' -or $aadEnabled -ne $true) {
    throw ("Refusing to publish: '$FunctionAppName' is not known to require sign-in. " +
           "requireAuthentication=$(& $said $requireAuth), " +
           "unauthenticatedClientAction=$(& $said $unauthAction), " +
           "aadEnabled=$(& $said $aadEnabled). " +
           "Every function is anonymous at the platform level and the identity check in code trusts a header, " +
           "so publishing here would put an unauthenticated migration control plane on the internet. " +
           "'not reported' means the platform did not answer, which is not the same as 'off' - read the app's " +
           "Authentication page, and use azd provision again. " +
           "If the settings are absent, deploy infra/platform.bicep with apiAppId set (from infra/identity.bicep).")
}
Write-Host '   sign-in enforcement verified on the app itself'

# SEC-1 / F4 and F7: retire a shared-key runtime connection left by an older
# install.
#
# The template now states the runtime storage connection in its identity form
# (AzureWebJobsStorage__accountName and the three service URIs), and the store
# refuses shared-key access outright. But the site module MERGES app settings
# rather than replacing them, so an app created before this change still
# carries the old AzureWebJobsStorage connection string - and a plain
# connection string wins over the identity form, so the host would keep using
# a key against an account that no longer accepts one.
#
# Removing it belongs here rather than in the template, because a template can
# state a setting and cannot unstate one. It is idempotent: after the first
# publish there is nothing to delete and nothing is said.
$settings = Invoke-VmfAzStep -Step 'read app settings' -Command {
    az functionapp config appsettings list -g $ResourceGroup -n $FunctionAppName -o json
} | ConvertFrom-Json
$hasKeyForm = @($settings | Where-Object { $_.name -eq 'AzureWebJobsStorage' }).Count -gt 0
$hasIdentityForm = @($settings | Where-Object { $_.name -eq 'AzureWebJobsStorage__accountName' }).Count -gt 0
if ($hasKeyForm -and $hasIdentityForm) {
    Write-Host '   retiring the old key-based runtime storage setting...'
    Invoke-VmfAzStep -Step 'remove the key-based AzureWebJobsStorage setting' -Command {
        az functionapp config appsettings delete -g $ResourceGroup -n $FunctionAppName --setting-names AzureWebJobsStorage --output none
    } | Out-Null
}
# NOFILES-1: retire the Azure Files content share an older install left behind.
#
# Same shape and same reason as the setting above. A Windows Consumption app
# created by `az functionapp create` - which this script used to do - carries
# WEBSITE_CONTENTAZUREFILECONNECTIONSTRING and WEBSITE_CONTENTSHARE, and the
# connection string holds an account key. The store refuses keys, so the share
# cannot be mounted; and Azure Files has no identity path the App Service
# worker will take (measured - see NOFILES-1 in infra/platform.bicep).
#
# The app runs from a package in blob storage instead, which the host fetches
# with its own identity. The order guard is not belt-and-braces: removing the
# share before WEBSITE_RUN_FROM_PACKAGE exists leaves the app with nowhere to
# get its code from at all.
$hasContentShare = @($settings | Where-Object { $_.name -in @('WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', 'WEBSITE_CONTENTSHARE') }).Count -gt 0
$hasRunFromPackage = @($settings | Where-Object { $_.name -eq 'WEBSITE_RUN_FROM_PACKAGE' }).Count -gt 0
if ($hasContentShare -and $hasRunFromPackage) {
    Write-Host '   retiring the key-based Azure Files content share...'
    Invoke-VmfAzStep -Step 'remove the content share settings' -Command {
        az functionapp config appsettings delete -g $ResourceGroup -n $FunctionAppName `
            --setting-names WEBSITE_CONTENTAZUREFILECONNECTIONSTRING WEBSITE_CONTENTSHARE --output none
    } | Out-Null
}
elseif ($hasContentShare) {
    Write-Host '   the app still keeps its code on an Azure Files share; leaving it.' -ForegroundColor Yellow
    Write-Host '   Deploy infra/platform.bicep (which states WEBSITE_RUN_FROM_PACKAGE), then publish again.'
}

# PIPELINE-LATER-1: retire the update model settings an older install left.
#
# The template stated VMF_UPDATE_MODEL and VMF_DEPLOY_PRINCIPAL until a person
# became the only one who runs an update. It cannot unstate them: the facade's
# settings are the settings the site has now merged with the template's own
# (infra/facade-appsettings.bicep). Nothing reads either one now, so there is
# no order to keep. Idempotent - after the first publish nothing is found.
$retiredModel = @($settings | Where-Object { $_.name -in @('VMF_UPDATE_MODEL', 'VMF_DEPLOY_PRINCIPAL') })
if ($retiredModel.Count) {
    Write-Host '   retiring the update model settings...'
    Invoke-VmfAzStep -Step 'remove the update model settings' -Command {
        az functionapp config appsettings delete -g $ResourceGroup -n $FunctionAppName --setting-names @($retiredModel.name) --output none
    } | Out-Null
}
# NOFILES-1: delete the SHARE, not only the setting that named it.
#
# Found 2026-09-07: a stale Azure file share was still present, although the
# template no longer used it. The template cannot clean it up. ARM deploys incrementally and never removes a child
# resource the template does not declare, so a share created outside the
# template outlives every redeploy. Left alone it keeps a full copy of the
# app's code and holds a 100 GiB quota, which makes it a data remnant rather
# than untidiness.
#
# Matched on the function app's own name, which is the prefix Azure uses for
# the share it creates, so no other share on the account can be caught. Guarded
# on the package setting for the same reason the retirement above is: without
# it the app may still be running from this share. Idempotent - after the first
# publish there is nothing to list.
if ($hasRunFromPackage) {
    $shares = Invoke-VmfAzStep -Step 'list the file shares' -AllowFailure -Command {
        az storage share-rm list -g $ResourceGroup --storage-account $StorageAccountName -o json
    } | ConvertFrom-Json
    foreach ($share in @($shares | Where-Object { $_.name -like "$FunctionAppName*" })) {
        Write-Host "   deleting the unused content share $($share.name)..."
        Invoke-VmfAzStep -Step "delete the unused content share $($share.name)" -Command {
            az storage share-rm delete -g $ResourceGroup --storage-account $StorageAccountName `
                -n $share.name --include snapshots --yes --output none
        } | Out-Null
    }
}

elseif ($hasKeyForm) {
    # ORDER SAFETY, and it is not hypothetical: this script can run against a
    # site whose template is older than the code - an installation that last
    # deployed infra/platform.bicep before the identity form. Removing the
    # key here before the identity settings exist would leave the host with no
    # storage connection at all, and it would not start - the whole control
    # plane, taken down by a publish. The replacement has to be in place first.
    Write-Host '   the runtime storage setting is still key-based; leaving it.' -ForegroundColor Yellow
    Write-Host '   Deploy infra/platform.bicep (which states the identity form), then publish again to retire it.'
}

Write-Host '2/2 build the code package and publish it from inside Azure...'

# PUBLISH-IN-1: THE PACKAGE NO LONGER TRAVELS FROM HERE TO THE STORE.
#
# It used to: stage the files, zip them, and `az storage blob upload` straight
# at the account. That is the ONE step of an install a locked-down store
# refuses. A corporate subscription measured here assigns a policy with the modify
# effect that forces publicNetworkAccess to Disabled on every storage account as
# it is created, and NSP-1 measured what a network security perimeter can and
# cannot admit: a subscription inbound rule admits the engine, the service and
# the dashboard's host, because all three run in the subscription. It can never
# admit a laptop.
#
# So the upload happens where the rule reaches. The package is built INTO a
# small single-purpose image by the customer's own registry (cloud-side, like
# the engine image - nothing runs Docker here), and a Container Apps job runs
# that image once. The job holds one data role on one container and reads
# nothing.
#
# Three steps, and each one says which it is when it fails.
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $tag = 'publish-' + (Get-Date -Format 'yyyyMMddHHmmss')
    Write-Host "   building the package image in registry $AcrName (cloud-side)..."
    Invoke-VmfAzStep -Step "building the package image in $AcrName" -Echo -Command {
        az acr build -r $AcrName -t "vmf-publish:$tag" -f docker/publish/Dockerfile . --only-show-errors --output none
    }
}
finally { Pop-Location }

# By DIGEST, never by tag. A tag can be moved; the job must run the bytes this
# build produced, and the recorded image must still name them on a later
# redeploy that reads the job back (Resolve-VmfPublishImage).
# ACR-DIGEST-1: one step, one copy - see infra/Resolve-VmfImageDigest.ps1.
$publishImage = (Resolve-VmfImageDigest -Registry $AcrName -Repository 'vmf-publish' -Tag $tag -What 'package').Image
Write-Host "   $publishImage"

# Pointing the job at the image. Container Apps refuses a second write while one
# is in flight, and a publish that arrives while the stack is still settling
# meets exactly that - so OperationInProgress is a wait, not a failure. Same
# shape as the engine job update in postprovision.ps1.
Write-Host '   pointing the publish job at it...'
# INSTALL-THROTTLE-RETRY-1: a throttle is a wait too, inside the same limit,
# and the line it prints says it was a throttle (infra/Invoke-VmfAzStep.ps1).
Invoke-VmfAzUpdateWhileBusy -Step "point the publish job $PublishJobName at the package image" -What 'The publish job update' `
    -RefusedMessage ("The publish job $PublishJobName could not be pointed at the package image. " +
                     'Deploy infra/platform.bicep, which creates it, then publish again.') `
    -Command { az containerapp job update -g $ResourceGroup -n $PublishJobName --image $publishImage --only-show-errors -o none }

Write-Host '   running it...'
# The error text az writes is printed as it arrives, above this refusal.
try {
    $started = Invoke-VmfAzStep -Step "start the publish job $PublishJobName" -Command {
        az containerapp job start -g $ResourceGroup -n $PublishJobName --only-show-errors -o json
    }
}
catch {
    throw ("The publish job $PublishJobName would not start. The account publishing needs Container Apps Jobs " +
           'Contributor on it, or a wider role such as Contributor or Owner on the resource group or the subscription.' +
           [Environment]::NewLine + $_.Exception.Message)
}
$execution = ''
try { $execution = [string](($started | ConvertFrom-Json).name) } catch { $execution = '' }
if (-not $execution) { throw "The publish job started but Azure did not name the execution. Nothing can be waited on." }
Write-Host "   execution $execution"

# WAIT FOR IT, AND READ THE ANSWER. A job that started is not a job that
# worked, and this is the step that used to be a blob upload whose failure the
# installer saw immediately. Now it happens out of sight, so the failure has to
# be fetched and put in front of them.
#
# PUBLISH-RUN-LOG-1: and the run's own console is read WHILE it runs, into a
# file in the azd environment's folder. MEASURED 2026-11-05: a run that failed
# in under a minute left no reason anywhere - the execution record said Failed,
# the replica was gone, and Log Analytics had nothing. infra/Wait-VmfJobRun.ps1
# says how the read is made.
#
# The job allows itself fifteen minutes for a seconds-old role assignment to
# reach the data plane, so this waits longer than the job can run.
$consolePath = Get-VmfJobConsolePath -Execution $execution -RepoRoot (Join-Path $PSScriptRoot '..') -EnvironmentName $env:AZURE_ENV_NAME
$run = Wait-VmfJobRun -ResourceGroup $ResourceGroup -JobName $PublishJobName -Execution $execution -Container 'publish' -ConsolePath $consolePath -TimeoutMinutes 18
if ($run.Status -ne 'Succeeded') {
    throw (Format-VmfJobRunFailure -What 'The publish job' -JobName $PublishJobName -ResourceGroup $ResourceGroup `
            -Execution $execution -Status $run.Status -Read $run.Read -Lines $run.Lines -ReadError $run.ReadError `
            -ConsolePath $run.ConsolePath -Cut:$run.Cut -TimeoutMinutes 18)
}
Remove-Item -LiteralPath $run.ConsolePath -Force -ErrorAction SilentlyContinue
Write-Host '   the package is in the store'

# The running host holds the package it started with, so new code needs a
# restart to be fetched - and then the platform's function list has to be
# re-read, or it keeps serving the old set. Both are required by
# WEBSITE_RUN_FROM_PACKAGE = <URL>; neither was needed with zip deploy.
Write-Host '   restarting onto the new package...'
Invoke-VmfAzStep -Step 'restart onto the new package' -Command {
    az functionapp restart -g $ResourceGroup -n $FunctionAppName --output none
} | Out-Null

# Sync triggers reaches INTO the host, so it fails while the host is still
# starting - a cold start from a URL package is slower than one from a file
# share. That is a wait, not a failure, so it is retried rather than thrown.
Write-Host '   syncing triggers...'
$syncUrl = "https://management.azure.com$siteId/syncfunctiontriggers?api-version=2022-03-01"
$synced = $false
# Four minutes, which is what postprovision.ps1 allows for the same app to
# start after this returns. A FIRST install is the slow case: the app has never
# run, and its very first start fetches the package over the network rather
# than reading a mounted share.
foreach ($attempt in 1..24) {
    az rest --method post --url $syncUrl --output none 2>$null
    if ($LASTEXITCODE -eq 0) { $synced = $true; break }
    $global:LASTEXITCODE = 0
    Start-Sleep -Seconds 10
}
if (-not $synced) {
    throw ('The package is in the store but the host did not answer a trigger sync within four minutes. ' +
           "Check that $FunctionAppName can read https://$StorageAccountName.blob.core.windows.net/vmf-deploy/facade.zip " +
           'with its managed identity (it needs Storage Blob Data Reader or better on the account).')
}

Write-Host ''
Write-Host "Facade published: https://$FunctionAppName.azurewebsites.net/api" -ForegroundColor Green
if ($apiAppId) { Write-Host "API app: $apiAppId - roles assignable to users and groups in Entra (infra/identity.bicep)." }
Write-Host "Infrastructure (plan, settings, sign-in enforcement, telemetry) comes from infra/platform.bicep."
