<#
.SYNOPSIS
    INSTALL-1: the code, published after the stack exists.
.DESCRIPTION
    Runs from `azd up` (and `azd provision`) after infra/main.bicep. The
    stack created every resource; this puts the product on them:
      1. the engine image, BUILT BY THE CUSTOMER'S OWN REGISTRY from this
         checkout (az acr build: the laptop uploads the source; the cloud
         builds; nothing here runs Docker) - INSTALL-0 piece 4;
      2. the engine job, pointed at that image BY DIGEST, and the digest
         recorded so a later `azd up` adopts it rather than resetting the
         job to the placeholder;
      3. the facade (tools/Deploy-VmfFacade.ps1) - which also gives the
         user installing the Vmf.Admin app role (one role, ROLE-3), so
         they can sign in;
      4. the dashboard (tools/Deploy-VmfDashboard.ps1);
      5. the sign-in gate CLOSED (GATE-1): from now on a person needs a
         role to sign in at all. Safe here and only here, because step 3
         just gave the installer the administrator role - the install
         waits until the directory shows it, and leaves the gate open with
         a warning if it never does. Until 2026-09-05 closing the gate was
         a step a user took, by a script nobody had
         documented. Now it is the install's own last act, and later runs
         of the identity template preserve it.
      6. proof the facade answers, then the front door and the next step.
    A person runs it, with `azd up`: it is the one way an installation
    updates.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzdHooks.ps1')
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfImageDigest.ps1')
. (Join-Path $PSScriptRoot '..' 'Set-VmfFacadeAdminIsolation.ps1')
. (Join-Path $PSScriptRoot '..' 'Get-VmfInstallClosingLines.ps1')
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

$rg = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
$acr = Get-AzdValue -Name 'VMF_ACR_NAME'
$store = Get-AzdValue -Name 'VMF_STORE_ACCOUNT'
$facade = Get-AzdValue -Name 'VMF_FACADE_NAME'
$facadeId = Get-AzdValue -Name 'VMF_FACADE_ID'
$dashboard = Get-AzdValue -Name 'VMF_DASHBOARD_NAME'
$job = Get-AzdValue -Name 'VMF_ENGINE_JOB_NAME'
$dashboardUrl = Get-AzdValue -Name 'VMF_DASHBOARD_URL'
foreach ($pair in @(@('AZURE_RESOURCE_GROUP', $rg), @('VMF_ACR_NAME', $acr), @('VMF_STORE_ACCOUNT', $store),
                    @('VMF_FACADE_NAME', $facade), @('VMF_FACADE_ID', $facadeId), @('VMF_DASHBOARD_NAME', $dashboard), @('VMF_ENGINE_JOB_NAME', $job))) {
    # NO-STACKS-2: said "The stack did not report". The deployment reports
    # these, and naming a stack sends the reader looking for one.
    if (-not $pair[1]) { throw "The deployment did not report $($pair[0]). Run azd provision again." }
}
$names = Get-VmfRegistrationNames
# The application the facade validates every token against, as the Entra
# deployment REPORTED it (preprovision recorded the template's own apiAppId
# output). Step 5 closes the sign-in gate on this application and no other: a
# second lookup by display name could name a registration somebody else in the
# tenant owns, and Entra does not make a display name unique.
$apiAppId = Get-AzdValue -Name 'VMF_API_APP_ID'
if (-not $apiAppId) {
    throw 'The install did not record VMF_API_APP_ID, the application the service checks every sign-in against. Run azd provision again.'
}

# ---- 0. the /admin paths of the service, closed (FUNCTIONS-ADMIN-ISOLATION-1) ------------
# The master key of a function app reaches the /admin paths of its host around
# the sign-in. The template cannot close them (infra/Set-VmfFacadeAdminIsolation.ps1
# says why), so this does, on every run and for both hosting plans, FIRST: the
# steps below take minutes. It reads the value back, and a value Azure does not
# keep stops the install.
Write-Step "The install closes the /admin paths of the service $facade."
$closed = Set-VmfFacadeAdminIsolation -SiteId $facadeId
Write-Host $(if ($closed -eq 'already') { '   The /admin paths are closed. The install made no change.' } else { '   The install closed the /admin paths.' })

# ---- the build stamp (VERSION-1) --------------------------------------------------------
# The number is the manifest's; the build is this commit and this moment. A
# checkout without git (a downloaded release) is stamped 'install'.
$commit = 'install'
try { $g = git -C $repoRoot rev-parse HEAD 2>$null; if ($LASTEXITCODE -eq 0 -and $g) { $commit = [string]$g } else { $global:LASTEXITCODE = 0 } } catch { $commit = 'install' }
$manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
$stampPath = Join-Path $repoRoot 'src' 'VmMigrationFactory' 'build.json'
[ordered]@{
    moduleVersion = [string]$manifest.ModuleVersion
    commit        = $commit
    builtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    run           = 0
    ref           = 'azd-up'
} | ConvertTo-Json | Set-Content $stampPath -Encoding utf8NoBOM

try {
    # ---- 1. the engine image -------------------------------------------------------
    Write-Step "Building the engine image in registry $acr (cloud-side; nothing runs here)"
    $tag = if ($commit -ne 'install') { $commit.Substring(0, 12) } else { 'install-' + (Get-Date -Format 'yyyyMMddHHmm') }
    Push-Location $repoRoot
    try {
        Invoke-VmfAzStep -Step 'building the engine image' -Echo -Command {
            az acr build -r $acr -t "vmf-engine:$tag" -f docker/Dockerfile . --only-show-errors --output none
        }
    }
    finally { Pop-Location }
    # ACR-DIGEST-1: one step, one copy. These lines lived here, in the facade
    # publisher and in the deploy workflow (removed 2026-11-05), and were wrong in all three at once
    # three times in two days. infra/Resolve-VmfImageDigest.ps1 says why.
    $built = Resolve-VmfImageDigest -Registry $acr -Repository 'vmf-engine' -Tag $tag -What 'engine'
    $image = $built.Image
    Write-Host "   $image"

    # ---- 2. the engine job, by digest --------------------------------------------------
    Write-Step "Pointing the engine job $job at the image"
    # INSTALL-THROTTLE-RETRY-1: a throttle is a wait too, inside the same limit,
    # and the line it prints says it was a throttle (infra/Invoke-VmfAzStep.ps1).
    Invoke-VmfAzUpdateWhileBusy -Step "point the engine job $job at the image" -What 'The engine job update' `
        -RefusedMessage 'engine job update failed (az exit {0}):' `
        -Command { az containerapp job update -g $rg -n $job --image $image --only-show-errors -o none }
    Set-AzdValue -Name 'VMF_ENGINE_IMAGE' -Value $image
    Write-Host '   pinned by digest; recorded for the next azd up'

    # ---- 3. the facade -----------------------------------------------------------------
    Write-Step "Publishing the service $facade"
    & (Join-Path $repoRoot 'tools' 'Deploy-VmfFacade.ps1') -StorageAccountName $store -ResourceGroup $rg `
        -FunctionAppName $facade -ApiDisplayName $names.Api

    # ---- 4. the dashboard ----------------------------------------------------------------
    Write-Step "Publishing the dashboard $dashboard"
    & (Join-Path $repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -StorageAccountName $store -ResourceGroup $rg `
        -SiteName $dashboard -AppDisplayName $names.Dashboard -ApiDisplayName $names.Api -FacadeName $facade

    # ---- 5. the sign-in gate -----------------------------------------------------------------
    Write-Step 'From now on, a person needs a role to sign in'
    $adminRoleId = '6f1c3a10-0004-4b6e-9e6a-100000000004'   # Vmf.Admin, identity.bicep
    # Found by APPLICATION ID - unique - rather than by display name.
    $apiSp = Get-VmfEntraServicePrincipal -AppId $apiAppId
    if (-not $apiSp) {
        throw ("No service principal for application $apiAppId ($($names.Api)) can be read. Either it was removed, " +
               'or the signed-in account may not read service principals. Deploy infra/identity.bicep again.')
    }
    $apiSpId = [string]$apiSp.id
    # The role was granted seconds ago; the directory can take a moment to show it.
    $admins = 0
    $deadline = (Get-Date).AddSeconds(90)
    do {
        $assigned = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo" -o json 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
        $admins = @($assigned.value | Where-Object { $_.appRoleId -eq $adminRoleId }).Count
        if ($admins -ge 1) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($admins -ge 1) {
        Invoke-VmfAzStep -Step 'closing the sign-in gate' -Command {
            az rest --method PATCH --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId" `
                --headers 'Content-Type=application/json' --body '{"appRoleAssignmentRequired": true}' --output none
        } | Out-Null
        Write-Host "   set: $admins administrator(s) can sign in; everyone else needs a role from the Admin page"
    }
    else {
        Write-Warning 'The sign-in rule is NOT set yet: the directory does not yet show an administrator. Run azd up again in a minute.'
    }
}
finally {
    # A checkout honestly reads "+local" again; only a build carries a stamp.
    Remove-Item $stampPath -Force -ErrorAction SilentlyContinue
}

# ---- 6. proof, and the front door ----------------------------------------------------------
Write-Step 'Is the service answering?'
$deadline = (Get-Date).AddMinutes(4)
do {
    $fns = @(az functionapp function list -g $rg -n $facade -o json 2>$null | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
    if ($fns.Count -gt 0) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)
if ($fns.Count -eq 0) { throw 'The service was published but no functions are indexed after 4 minutes. Run azd provision again.' }
Write-Host "   $($fns.Count) function(s) indexed"

# CONSENT-1, 2026-09-09. The first sign-in needs user or admin consent to the
# app, the manual must say so, and some enterprises block user consent with
# Entra ID policies.
#
# It is stronger than that. THREE of the dashboard's scopes reserve consent to
# an administrator in EVERY directory, not only where a policy blocks users:
# AppRoleAssignment.ReadWrite.All, Application.Read.All and Group.Read.All.
# Read from Graph, not from memory.
#
# CONSENT-1 decided the install grants nothing, because approving permissions
# across a directory is not something an install should do quietly on
# somebody's behalf. INSTALL-CONSENT-IN-FLOW-1 (2026-11-16: a Global
# Administrator gives the admin consent during azd up, as part of the flow)
# keeps the "not quietly" and drops the rest: a
# person who can give it is ASKED, below, and a yes gives it. Everybody else
# still gets the hand-off, because until it is done nobody else can use the
# Admin page, and Microsoft's refusal does not say why.
# ---- 7. FIRSTRUN-1: the first scope -----------------------------------------------------
#
# WHAT WAS MISSING. The install granted the product no reach over any machine,
# and the only route to that was the Admin page - which needs permissions over
# the DIRECTORY that one person with one subscription may not hold. So the
# simplest case met a wall built for a much larger organisation.
#
# THE ADMINISTRATOR ROLE IS NOT THIS. Step 3 already gives the person
# installing the Vmf.Admin role (CD-1, in tools/Deploy-VmfFacade.ps1), and
# skips it for a service principal. This step is the OTHER half: which machines
# the product may work on.
#
# NOTHING NEW DOES THE WORK. tools/Grant-VmfAccess.ps1 has granted the engine
# its scopes since ONBOARD-1. The install simply never called it.
#
# IT MUST NOT FAIL THE INSTALL. An installer who is not an Owner of the
# subscription still gets a working platform and a sentence about what is left.
# An install that succeeds today must not start failing.
$firstScope = Get-AzdValue -Name 'VMF_FIRST_SCOPE'
$subId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
$scopeDone = $false
if ($firstScope -in @('assess', 'migrate')) {
    Write-Step 'Giving the product the reach you asked for'
    # ID-ADDRESS-1: the exact names the deployment made. A plan change leaves
    # the old facade in the resource group, so a name prefix can match two.
    $grantArgs = @{ ResourceGroup = $rg; SubscriptionId = $subId; FacadeName = $facade }
    $baseSuffix = Get-AzdValue -Name 'VMF_BASE_SUFFIX'
    if ($baseSuffix) { $grantArgs.EngineIdentityName = "vmf-engine-mi-$baseSuffix" }
    $apiName = Get-AzdValue -Name 'VMF_API_DISPLAY_NAME'
    if ($apiName) { $grantArgs.ApiDisplayName = $apiName }
    # The migration role CONTAINS the assessment role (infra/roles.bicep unions
    # the two action lists), so ONE scope is passed, never both.
    if ($firstScope -eq 'assess') { $grantArgs.AssessScope = "/subscriptions/$subId" }
    else { $grantArgs.MigrateScope = "/subscriptions/$subId" }
    try {
        & (Join-Path $PSScriptRoot '..' '..' 'tools' 'Grant-VmfAccess.ps1') @grantArgs
        $scopeDone = $true
    }
    catch {
        # REPORTED, NEVER THROWN. The platform is deployed and works; what
        # failed is a grant, and the app has a page for it.
        Write-Host ''
        Write-Host 'The install could not grant that reach.' -ForegroundColor Yellow
        Write-Host "   $($_.Exception.Message)"
        Write-Host '   The platform is deployed and running. Nothing here is lost.'
        Write-Host '   Granting reach over machines needs Owner or User Access Administrator on the subscription.'
        Write-Host '   Make the grant on the Admin page.'
    }
}

# Whether the person installing can actually sign in - READ BACK, not assumed.
# Step 3 assigns the role and has never checked: the exit code is discarded
# there, because an already-assigned role answers with an error and that is
# success. So the closing line below was printed on installs where the
# directory had refused.
#
# A service principal is not asked about. It was never given a role, it has no
# person to speak for, and CD-1 keeps directory reads out of the pipeline path
# on purpose.
#
# No wait here: step 5 already waited up to 90 seconds for the directory to
# show an administrator before it closed the gate.
$adminDone = $false
$installerIsPerson = (az account show --query 'user.type' -o tsv 2>$null) -eq 'user'
if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
if ($installerIsPerson) {
    # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again, so a throttle
    # does not print "YOU DO NOT HOLD THE ADMINISTRATOR ROLE" for a person who
    # holds it.
    $myId = Invoke-VmfAzStep -Step 'read the signed-in user' -AllowFailure -Command { az ad signed-in-user show --query id -o tsv }
    if ($myId) {
        $vmfAdminRoleId = '6f1c3a10-0004-4b6e-9e6a-100000000004'
        $held = @(Invoke-VmfAzStep -Step 'read back the Vmf.Admin role' -AllowFailure -Command {
                az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$myId/appRoleAssignments" -o json
            } | ConvertFrom-Json | Select-Object -ExpandProperty value -ErrorAction SilentlyContinue |
            Where-Object { $_.appRoleId -eq $vmfAdminRoleId })
        $adminDone = [bool]$held.Count
    }
}
$dashboardAppId = Get-AzdValue -Name 'VMF_DASHBOARD_APP_ID'
# INSTALL-CONSENT-PUSH-1: the hand-off. This printed
# `az ad app permission admin-consent --id ...` - a command for somebody else
# to run, which rule 12 rules out. The person with the role approves in the
# browser: through Microsoft's admin consent request workflow when the
# directory has it on, or from the admin consent link for THIS install's
# dashboard registration, built from ids the install already holds.
#
# CONSENT-DONE-CHECK-1: and only when it is not given. Every install and every
# update used to end with the hand-off, also when an administrator approved the
# product weeks before. The grants are READ now; a refused read is unknown, and
# unknown still gives the hand-off.
#
# The directory is read for a PERSON only (CD-1 keeps directory reads out of
# the pipeline path). A service principal gets the link and the portal route.
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfInstallerRights.ps1')
$consentState = 'unknown'
$workflow = 'unknown'
$consent = $null
if ($installerIsPerson) {
    $rights = Get-VmfInstallerRights -SubscriptionId $subId
    $consentState = $rights.CanConsent
    $workflow = Get-VmfConsentRequestWorkflow
    $consent = Get-VmfAdminConsentState -ClientId $dashboardAppId
    # INSTALL-CONSENT-IN-FLOW-1 (2026-11-16): a person who CAN give
    # admin consent is asked once, and a yes gives it here, as that person.
    # What comes back is READ BACK: only 'given' prints the green closing, and
    # a refusal or a failed read keeps the hand-off. It never throws.
    $consent = Invoke-VmfAdminConsentInFlow -Rights $rights -Consent $consent -ClientId $dashboardAppId
}
$tenantId = [string](az account show --query tenantId -o tsv 2>$null)
if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; $tenantId = '' }
$closing = @(Get-VmfConsentClosing -Consent $consent -CanConsent $consentState -Workflow $workflow -TenantId $tenantId.Trim() `
    -ClientId $dashboardAppId -RegistrationName $names.Dashboard)
$headingColour = if ($null -ne $consent -and $consent.State -eq 'given') { 'Green' } else { 'Yellow' }
Write-Host ''
Write-Host $closing[0] -ForegroundColor $headingColour
$closing | Select-Object -Skip 1 | ForEach-Object { Write-Host $_ }

Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host "   Open $dashboardUrl and sign in."
# FIRSTRUN-1: it said "You are the administrator" on every install, including
# the ones where nobody had been made one. A closing line that states a result
# the run never achieved is the same defect as a check that reports what it
# never measured.
if ($adminDone) { Write-Host '   You are the administrator. Nobody else can sign in until you give them a role on the Admin page.' }
elseif (-not $installerIsPerson) { Write-Host '   A service principal ran this install, so nobody was made an administrator here.' }
else { Write-Host '   YOU DO NOT HOLD THE ADMINISTRATOR ROLE. The product refuses every page until somebody gives it to you.' }
if ($scopeDone) {
    # FIRSTSCOPE-3: SAY WHICH. This line used to read "The product may work on
    # the machines in subscription X, as you chose during the install" - the
    # same sentence whether the product could migrate or only scan. So the LAST
    # thing an installer reads could not tell them which they had, and a
    # corporate install ran scan-only for a fortnight before anyone found
    # out, the evening before a demo. "Where this leaves things" above says it
    # properly; this line is four lines later and said less.
    if ($firstScope -eq 'migrate') {
        Write-Host "   This install may SCAN AND MIGRATE machines in subscription $subId."
    }
    else {
        Write-Host "   This install may SCAN subscription $subId. It may NOT migrate a machine." -ForegroundColor Yellow
        Write-Host '   To let it migrate: azd env set VMF_FIRST_SCOPE migrate, then install again.'
    }
    # AND STOP PROMISING A PAGE THAT MAY REFUSE THEM. "Widen or narrow that on
    # the Admin page at any time" is untrue for anybody whose directory keeps
    # admin consent for an administrator - which is exactly the person who most
    # needs another route, and a common corporate situation.
    # INSTALL-CLOSING-AFTER-CONSENT-1: and not the condition, once the install
    # read admin consent back as given.
    $adminPageLine = Get-VmfScopeAdminPageLine -AdminDone $adminDone -Consent $consent
    if ($adminPageLine) { Write-Host "   $adminPageLine" }
}
else {
    Write-Host '   Next: on the Admin page, give the product permission to look at your machines: a resource group, a subscription or a management group.'
    Write-Host '   The install gave the product no reach over your machines. You answered no, or were not asked.'
    Write-Host '   Granting reach needs Owner or User Access Administrator on the place you choose.'
}
Write-Host '   The manual: open the dashboard, select Get help, then Read the manual.'
