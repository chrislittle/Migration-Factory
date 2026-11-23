<#
.SYNOPSIS
    INSTALL-1: everything that has to be true BEFORE the platform is deployed.
.DESCRIPTION
    Runs from `azd up` (and `azd provision`) before infra/main.bicep. In order:
      0. the disclaimer (DISCLAIMER-1): the product is not an official
         Microsoft product, and Microsoft does not support it;
      1. the readiness check (Test-VmfReadiness.ps1) - tools, sign-in,
         providers, region, quota; a definite blocker stops here;
     1b. admin consent (INSTALL-CONSENT-PUSH-1): who can give it, the role
         to use, and - for a person who holds none - Stop or Continue;
      2. the decision page, asked once and recorded in the azd environment:
         the hosting plan for the dashboard and the service; what the
         product may do with the machines in this subscription;
      3. azd's deployment-stack mode, which this product does NOT use -
         reported if the machine has it on, and left alone (NO-STACKS-1);
      4. the resource group, created if missing - the Entra template deploys
         into it;
      5. an EXISTING platform in the group is adopted, never duplicated
         (INSTALL-0: its suffix and the engine job's pinned image win);
      6. the Entra registrations (infra/identity.bicep) - outside the
         product's resource group, because Entra objects are not Azure
         resources - and the API id handed to the platform template
         through VMF_API_APP_ID;
      7. the two custom roles (infra/roles.bicep) at the subscription -
         outside the group too: every install in a subscription shares
         them (same ids), so the removal keeps them.
    Nothing here costs money. Nothing here touches a machine.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzdHooks.ps1')
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfSuffix.ps1')

# ---- 0. the disclaimer (DISCLAIMER-1) ----------------------------------------------
# First, before the readiness check and before anything is written or deployed:
# the person who installs reads that the product is not an official Microsoft
# product and that Microsoft does not support it.
Show-VmfDisclaimer

$envName = Get-AzdValue -Name 'AZURE_ENV_NAME'
$location = Get-AzdValue -Name 'AZURE_LOCATION'
$subscription = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
if (-not $envName -or -not $location -or -not $subscription) {
    # This used to say "Run azd up and answer its first questions", which is
    # advice a person could not follow: azd runs this hook itself, so seeing
    # this message means the hook was started BY HAND, and azd up was the thing
    # that failed. Say what to actually do instead.
    throw @'
This hook reads AZURE_ENV_NAME, AZURE_LOCATION and AZURE_SUBSCRIPTION_ID from its
environment, and azd sets them only when azd itself runs the hook.

If you are running this by hand, export them first:

  azd env get-values

then set each one in your shell, and run this again. If you have no environment
yet, make one:

  azd env new <name> --location <region> --subscription <id>
'@
}
$rg = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP' -Default "rg-$envName"
Set-AzdValue -Name 'AZURE_RESOURCE_GROUP' -Value $rg
# AZD-DOWN-RG-RECHECK-1: a new install has no removal in progress. A name a
# stopped removal recorded could be of another group, and postdown would read
# that group as this install's.
Set-AzdValue -Name 'VMF_DOWN_RESOURCE_GROUP' -Value ''
# ---- 1. readiness ---------------------------------------------------------------
Write-Step "Is subscription $subscription ready for the platform in ${location}?"
$checks = @(& (Join-Path $PSScriptRoot 'Test-VmfReadiness.ps1') -Location $location -SubscriptionId $subscription -ResourceGroup $rg)
$checks | Format-Table Check, Result, Detail -AutoSize -Wrap | Out-String -Width (Get-VmfConsoleWidth) | Write-Host
$blockers = @($checks | Where-Object { $_.Result -eq 'blocker' })
if ($blockers.Count -and (Get-AzdValue -Name 'VMF_SKIP_READINESS') -ne 'true') {
    throw ("The subscription is not ready: " + (($blockers | ForEach-Object { "$($_.Check) - $($_.Detail)" }) -join '; ') +
           ". Fix these and run azd up again. To go ahead regardless: azd env set VMF_SKIP_READINESS true")
}

# ---- 1b. admin consent: said, and asked, before anything is created ---------------
# INSTALL-CONSENT-PUSH-1, 2026-11-02: push the person who installs
# towards a role that can give admin consent. The full product - the Admin
# page - needs it. Said to everyone; asked only of a person who reads as
# holding no such role, and a Stop here has created nothing. FIRSTSCOPE-1
# still holds: Continue installs, scans and migrates as before.
#
# FIRSTRUN-1: the rights are read here, once, and step 2 uses them too.
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfInstallerRights.ps1')
$rights = Get-VmfInstallerRights -SubscriptionId $subscription
Write-Step 'Admin consent in Microsoft Entra ID: the Admin page needs it'
Get-VmfConsentNotice -Rights $rights | ForEach-Object { Write-Host $_ }
$null = Invoke-VmfConsentPush -Rights $rights

# ---- 2. the decision page ---------------------------------------------------------
Write-Step 'The choices this install records (asked once; change them with azd env set, then azd up)'
# PIPELINE-LATER-1 (2026-11-02): no question about who runs updates. A
# person runs every update - get the newer source, then azd up - and no
# automation identity holds any right on the platform. The pipeline model
# waits until after 1.0 (DIST-2, CD-2 stage B).

# WARM-1: an environment that answered the OLD question keeps its answer.
# VMF_FACADE_PLAN was Consumption or Basic and covered the facade alone. The
# new name covers both apps, and Basic means the same thing in each, so the
# only value that has to be translated is Consumption -> Free. Done before the
# question is asked, so a person who already chose is not asked again.
if (-not (Get-AzdValue -Name 'VMF_HOSTING_PLAN')) {
    $was = Get-AzdValue -Name 'VMF_FACADE_PLAN'
    if ($was) {
        $carried = if ($was -eq 'Basic') { 'Basic' } else { 'Free' }
        Set-AzdValue -Name 'VMF_HOSTING_PLAN' -Value $carried
        Write-Host "   hosting plan carried over from VMF_FACADE_PLAN=$was -> $carried"
    }
}

# WARM-1: ONE question, because there was never a second answer worth giving.
# This used to ask only about the facade, and the dashboard was hard-wired to
# a Free plan that cannot be made warm. Azure Functions cannot run on a Free
# or Shared plan at all, so the dashboard's plan could never hold the facade -
# and two separate Basic plans cost twice what one does for the same result.
# Microsoft: "You're billed only for the plan, regardless of how many function
# apps or web apps run in the plan."
#
# INSTALL-PLAN-WORDS-1 (2026-11-12): the question names the plans in
# Azure's own terms and nothing else - no price, no load time, no advice. The
# manual (install/choices.md, install/step-by-step.md) uses the same words,
# and tests/unit/InstallPlanWords.Tests.ps1 pins them.
$plan = Read-VmfChoice -Name 'VMF_HOSTING_PLAN' -Default 'Free' `
    -Question 'Choose the hosting plan for the dashboard and the service' `
    -Options @('Free|Free: App Service Free (F1) for the dashboard, Azure Functions Consumption (Y1) for the service.',
               'Basic|Basic: one App Service Basic (B1) plan for both, with Always On.')
Write-Host "   hosting plan: $plan"
# READINESS-FIX-WORDS-1: the readiness table judged each answer's room before
# the question. An answer with no room is refused here, before anything is
# created, with the reason from that row.
$planRoom = @($checks | Where-Object { $_.Check -eq "Hosting plan: $plan" }) | Select-Object -First 1
if ($planRoom -and $planRoom.Result -eq 'warn' -and (Get-AzdValue -Name 'VMF_SKIP_READINESS') -ne 'true') {
    $other = if ($plan -eq 'Free') { 'Basic' } else { 'Free' }
    throw ("$($planRoom.Detail) To choose ${other}: azd env set VMF_HOSTING_PLAN ${other}, then run azd up again.")
}

# FIRSTRUN-1. The question that was missing, and its absence is what made a
# person who owns their own subscription unable to use what they just
# installed. Every route to a working state ran through the Admin page, and
# that page needs permissions over the DIRECTORY.
#
# With no console the install takes the default chosen below and says so; a
# person can change the scope afterwards on the Admin page.
#
# The scope offered is the subscription being installed into. Never wider, and
# never a list of everything the installer can see.
# FIRSTRUN-1. The install used to ask about permission and leave the person to
# work out whether they could answer. Since 2026-09-15, the install reads the
# user's roles and gives guidance from them.
#
# So it reads first, and says what it found. Two different rights decide this -
# Azure on the subscription, Microsoft Entra ID in the directory - and the
# guidance is different in each of the four cases.
# ($rights was read in step 1b, before anything was created.)

Write-Host ''
Write-Host 'What your account can do'
$grantLine = switch ($rights.CanGrant) {
    'yes'   { "you are $($rights.GrantRoles -join ' and ')" }
    'no'    { 'you hold no role that can give permission over machines' }
    default { 'could not be read' }
}
$consentLine = switch ($rights.CanConsent) {
    'yes'   { "you hold $($rights.ConsentRoles -join ' and ')" }
    'no'    { 'no role that can give admin consent' }
    default { 'could not be read' }
}
Write-Host "   this subscription ....... $grantLine"
Write-Host "   Microsoft Entra ID ...... $consentLine"

# WHAT THE TWO ANSWERS MEAN, said before the question rather than left to the
# reader. UNKNOWN is never read as no: a refused directory read is measured and
# common, once for an account holding Global Administrator.
if ($rights.CanGrant -eq 'no') {
    Write-Host '   You cannot give the product permission over machines. That needs Owner or User Access Administrator.'
}
elseif ($rights.CanConsent -eq 'no') {
    Write-Host '   The Admin page needs admin consent in Microsoft Entra ID, and you cannot give it.'
    Write-Host '   You CAN give permission here, because of the role you hold on this subscription.'
}
elseif ($rights.CanConsent -eq 'yes') {
    Write-Host '   Both routes work for you. The Admin page also covers a resource group or a management group.'
}

# FIRSTSCOPE-2: was this answered NOW, or weeks ago?
#
# Read-VmfChoice returns a stored answer without asking, which is right - a
# re-install must not re-interrogate somebody. But it means the answer that
# decides whether this product can migrate at all is made once and then never
# mentioned again, and the install carried on printing a line that read like a
# fresh statement.
$storedScope = Get-AzdValue -Name 'VMF_FIRST_SCOPE'

# A person who cannot grant is not asked. Every answer would fail, and a
# question whose answers all fail is worse than no question.
if ($rights.CanGrant -eq 'no') {
    Set-AzdValue -Name 'VMF_FIRST_SCOPE' -Value 'no'
    $firstScope = 'no'
    Write-Host '   Ask an Owner of this subscription to give the product permission, or use the Admin page.'
}
else {
    # THE DEFAULT FOLLOWS THE PERSON. Somebody who can use the Admin page is
    # better served by it: it covers a resource group, a subscription or a
    # management group, and takes permission away again. Somebody who cannot
    # would be sent to a page that refuses them, so scanning is the default
    # instead. An install with no console takes the same default and grants
    # only what a person in that position could have chosen.
    $sendToAdminPage = ($rights.CanConsent -ne 'no')
    # FIRSTSCOPE-1, RULED 2026-09-22: a user with the Owner role on a
    # subscription can migrate, so scan and migrate is the default.
    #
    # THE DEFAULT USED TO BE DECIDED BY THE WRONG PERMISSION.
    #
    #     $default = if ($sendToAdminPage) { 'no' } else { 'assess' }
    #
    # Giving ADMIN CONSENT is a DIRECTORY question, about the app registration.
    # Granting the product reach over MACHINES is an AZURE question, about the
    # person's role on the subscription - and the guard above has already
    # answered it: nobody who cannot grant reaches this line at all.
    #
    # So a subscription Owner who happened to work in a directory that reserves
    # consent for an administrator was handed SCANNING, and could not change it
    # afterwards, because the Admin page needs the consent they do not have.
    # MEASURED on a corporate install: both identities on VMF
    # Assessment at the subscription, no migration role anywhere, and a health
    # check reporting every check passed.
    #
    # A migration tool installs able to migrate. Consent still decides WHERE a
    # person is pointed - the Admin page is the fuller route and is offered
    # first to anybody who can use it - but never what they end up with.
    $default = 'migrate'
    $adminPageOption = if ($sendToAdminPage) {
        'no|Nothing now. Choose the place on the Admin page: a resource group, a subscription or a management group.'
    }
    else {
        'no|Nothing now. Ask an administrator for admin consent, then use the Admin page.'
    }
    $options = if ($sendToAdminPage) {
        @($adminPageOption,
          'assess|Scan the machines in this subscription. Change nothing.',
          'migrate|Scan them, and migrate a machine after you approve a migration.')
    }
    else {
        @('assess|Scan the machines in this subscription. Change nothing.',
          'migrate|Scan them, and migrate a machine after you approve a migration.',
          $adminPageOption)
    }
    $firstScope = Read-VmfChoice -Name 'VMF_FIRST_SCOPE' -Default $default `
        -Question 'What may the product do with the machines in this subscription?' `
        -Help @('The product has no permission over your machines. It cannot scan or migrate a machine until you give permission.',
                'What you give here covers this subscription. It covers no other subscription.',
                'Permission changes no machine. The product changes a machine only after you plan a migration and approve it.') `
        -Options $options
}
# FIRSTSCOPE-2: say what this install is about to grant, EVERY time.
#
# It used to print '   the product may scan this subscription' - true, quiet,
# among a page of install output, saying nothing about what scan-only forbids
# and nothing about the answer being weeks old. A corporate install ran that
# way for a fortnight, and nobody knew until the evening before a demo.
#
# So: what it may do, what it may NOT do when that matters, and where the
# answer came from. The change line names an azd command because this IS the
# installer's console - hard rule 12 is about the operator app, and somebody
# who cannot give admin consent has no route there anyway.
switch ($firstScope) {
    'assess' {
        Write-Host '   This install may SCAN this subscription. It may NOT migrate a machine.' -ForegroundColor Yellow
        Write-Host '   It cannot stop a machine, resize one, or take a safety copy.'
    }
    'migrate' { Write-Host '   This install may scan and migrate machines in this subscription.' }
    default {
        Write-Host '   This install grants nothing. It may NOT scan or migrate a machine yet.' -ForegroundColor Yellow
        Write-Host '   Choose the place on the Admin page.'
    }
}
if ($storedScope) {
    Write-Host "   That is the answer you gave on an earlier install, and it is reused."
    if ($firstScope -ne 'migrate') {
        Write-Host '   To let it migrate: azd env set VMF_FIRST_SCOPE migrate, then install again.'
    }
}

# IDENTITY-4, 2026-09-11: a THIRD question was here - may the dashboard read
# sign-in logs, so it can show what a machine identity calls? It is gone with
# the control that used the answer. An install asks one question fewer, and no
# customer has to decide about a permission nothing uses.

# ---- 3. deployment stacks: NOT USED, and this says so if the flag is on -------------
#
# NO-STACKS-1: this step used to TURN THE FLAG ON, on every install, on
# whoever's machine ran it:
#
#     azd config set alpha.deployment.stacks on
#
# Two things were wrong with that, and only the second was obvious.
#
# The product no longer uses deployment stacks - see the note at the top of
# azure.yaml, and docs/research/option-b-dropping-deployment-stacks.md. But
# REMOVING THE BLOCK FROM azure.yaml IS NOT ENOUGH: the block supplies a
# stack's options, and this flag is what enables the code path. azd falls back
# to its own defaults when the block is absent, so a machine with the flag on
# would still get stacks - with settings nobody chose, and nothing saying so.
#
# And `azd config set` is MACHINE-WIDE. It writes to the person's azd
# configuration, not to this project, so it reaches every other azd project
# they have. Turning it OFF for them has the same reach, which is why this does
# not do that either. It says what it found and leaves the machine alone -
# the same rule this product follows everywhere else it meets something it
# does not own.
#
# NO-STACKS-2, 2026-09-14: IT NOW STOPS THE INSTALL RATHER THAN WARNING.
#
# NO-STACKS-1 left this as a warning and let the install continue. MEASURED
# on a corporate subscription, with the flag on:
#
#     ERROR: A referenced resource was not found.
#     ResourceNotFound: The resource 'azd-stack-contoso-demo' was not found.
#
# The install cannot succeed while the flag is on, so a warning bought nothing
# and cost the operator a failure whose message names a stack this product does
# not create, eight minutes after the warning scrolled past. It read as the
# product still using stacks, after their removal.
#
# STOPPING IS NOT THE SAME AS CHANGING THEIR MACHINE. The setting is still not
# ours to write, and this still does not write it. It refuses to walk into a
# failure it can see coming, and names the one command that clears it.
#
# AZD-UP-QUIET-1 (2026-11-10): the check stays, and says nothing while
# the setting is off. "off; this install is an ordinary deployment" told the
# person about a feature this product does not use.
$stacks = (azd config get alpha.deployment.stacks 2>$null) -join ''
if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
if ($stacks -match '"?on"?') {
    Write-Step 'Deployment-stack mode: an azd setting on this machine'
    Write-Host '   azd deployment-stack mode is ON for this machine. This product does not use it,'
    Write-Host '   and the install FAILS while it is on. It fails like this:'
    Write-Host ''
    Write-Host '     ResourceNotFound: The resource "azd-stack-<your environment>" was not found.'
    Write-Host ''
    Write-Host '   Turn it off if nothing else needs it, then run azd up again:'
    Write-Host ''
    Write-Host '     azd config set alpha.deployment.stacks off'
    Write-Host ''
    Write-Host '   This install does not change the setting. It belongs to your machine, not to'
    Write-Host '   this product, and it reaches every other azd project you have.'
    Write-Host ''
    throw 'Deployment-stack mode is on for this machine. This product cannot install while it is on.'
}

# ---- 4. the resource group ---------------------------------------------------------
Write-Step "Resource group $rg"
$exists = Invoke-VmfAzStep -Step 'read whether the resource group exists' -AllowFailure -Command { az group exists -n $rg -o tsv }
if ($exists -ne 'true') {
    Invoke-VmfAzStep -Step 'creating the resource group' -Command {
        az group create -n $rg -l $location --tags "azd-env-name=$envName" project=vm-migration-factory -o none
    } | Out-Null
    Write-Host "   created in $location"
}
else { Write-Host '   exists' }

# ---- 5. adopt what is there ------------------------------------------------------------
$suffix = Resolve-VmfSuffix -ResourceGroup $rg -BaseSuffix (Get-AzdValue -Name 'VMF_BASE_SUFFIX')
Set-AzdValue -Name 'VMF_BASE_SUFFIX' -Value $suffix
$image = if ($suffix) { Resolve-VmfEngineImage -ResourceGroup $rg -JobName "vmf-engine-$suffix" } else { '' }
Set-AzdValue -Name 'VMF_ENGINE_IMAGE' -Value $image
# PUBLISH-IN-1: the publish job carries a built image too, and a redeploy that
# passed nothing would put its placeholder back - which does not fail, it
# publishes Microsoft's sample job instead of this product's code.
$publish = if ($suffix) { Resolve-VmfPublishImage -ResourceGroup $rg -JobName "vmf-publish-$suffix" } else { '' }
Set-AzdValue -Name 'VMF_PUBLISH_IMAGE' -Value $publish
Write-Host "   platform suffix: $(if ($suffix) { "$suffix (existing deployment adopted)" } else { 'derived by the template (fresh install)' })"
Write-Host "   engine image: $(if ($image) { "kept as published ($image)" } else { 'the placeholder, until this install publishes' })"
Write-Host "   publish image: $(if ($publish) { "kept as published ($publish)" } else { 'the placeholder, until this install publishes' })"

# ---- 6. the Entra registrations ------------------------------------------------------
# NO-STACKS-2: the heading said '(outside the stack)'. ROLES-UX-1 had already
# ruled that phrase out on the step below - "'the stack' is a word the operator
# has not met at this point in the output" - and this one was missed. It is
# also no longer true of anything: there is no stack to be outside of.
Write-Step 'The two Entra registrations the product signs in with'
$names = Get-VmfRegistrationNames
Set-AzdValue -Name 'VMF_API_DISPLAY_NAME' -Value $names.Api
Set-AzdValue -Name 'VMF_DASHBOARD_DISPLAY_NAME' -Value $names.Dashboard
# THE REGISTRATION KEY. Entra keeps a deleted application's uniqueName for 30
# days, so an environment that is removed and installed again collides with its
# own tombstone. A key on the uniqueName sidesteps that; the displayName a
# person reads never changes.
#
# THREE CASES (Resolve-VmfRegistrationKey, INSTALL-ADOPT-OWNER-1):
#   a key is already recorded  -> reuse it, so an UPDATE upserts the same
#                                 registration rather than making a second one.
#                                 The directory is not read.
#   no key, no registration    -> a fresh install, so generate one
#   no key, but a registration with the name EXISTS -> STOP, before anything
#                                 here touches the directory. It used to record
#                                 an EMPTY key, and the uniqueName
#                                 'vmf-api-<env>' is one any member of the
#                                 tenant can make first. Nothing the directory
#                                 shows proves who made a registration, so none
#                                 is taken over.
$registration = Resolve-VmfRegistrationKey -RecordedKey (Get-AzdValue -Name 'VMF_REGISTRATION_KEY') `
    -ApiDisplayName $names.Api -DashboardDisplayName $names.Dashboard
$registrationKey = $registration.Key
switch ($registration.Source) {
    'recorded' { Write-Host "   registration key $registrationKey (recorded by the first install)" }
    'new' {
        Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value $registrationKey
        Write-Host "   fresh install: registrations get the key $registrationKey"
    }

}

# INSTALL-PURGE-DELETED-1: the ids the last install recorded, read before they
# are blanked below. identity-deploy looks for a live registration with each:
# one that is there means no deleted registration can hold its unique name.
$recordedApiAppId = [string](Get-AzdValue -Name 'VMF_API_APP_ID')
$recordedDashboardAppId = [string](Get-AzdValue -Name 'VMF_DASHBOARD_APP_ID')
$identityArgs = @{
    ResourceGroup        = $rg
    RecordedApiAppId     = $recordedApiAppId
    RecordedDashboardAppId = $recordedDashboardAppId
    ApiDisplayName       = $names.Api
    DashboardDisplayName = $names.Dashboard
    RegistrationKey      = $registrationKey
    # INSTALL-PURGE-DELETED-1: a key made in this run is held by no deleted
    # registration, so identity-deploy reads no deleted items for it.
    RegistrationKeyIsNew = ($registration.Source -eq 'new')
}
if ($suffix) { $identityArgs.BaseSuffix = $suffix }
# The id comes from the DEPLOYMENT'S OWN OUTPUT (identity.bicep reports
# apiAppId), never from a second lookup by display name. Entra does not make a
# display name unique, so a lookup that took the first answer could hand
# VMF_API_APP_ID - which becomes clientId and allowedAudiences on the facade -
# to a registration any member of the tenant had made with the same name.
# ID-ADDRESS-1: the recorded ids are blanked BEFORE the deployment. The removal
# deletes by the recorded id, so an id left from an earlier install, with a
# deployment that then failed, would send it to a registration that is gone -
# and leave the one this run made. With no id recorded it finds by exact name.
Set-AzdValue -Name 'VMF_API_APP_ID' -Value ''
Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID' -Value ''
$identity = & (Join-Path $PSScriptRoot '..' 'identity-deploy.ps1') @identityArgs
$apiAppId = [string]($identity | Select-Object -ExpandProperty ApiAppId -ErrorAction SilentlyContinue)
if (-not $apiAppId) {
    throw ("The Entra deployment did not report the API registration's application id. " +
           'Run azd provision again. If it repeats, deploy infra/identity.bicep by hand and read its apiAppId output.')
}
Set-AzdValue -Name 'VMF_API_APP_ID' -Value $apiAppId
# CONSENT-1: identity-deploy has always RETURNED the dashboard's application
# id and nobody recorded it. The install's closing message needs it, because
# the one action left after an install is an administrator approving that
# registration's permissions - and a message that says "<the application id>"
# instead of the id is not an instruction, it is homework.
$dashboardAppId = [string]($identity | Select-Object -ExpandProperty DashboardAppId -ErrorAction SilentlyContinue)
Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID' -Value $dashboardAppId
Write-Host "   API registration $($names.Api): $apiAppId"
Write-Host "   dashboard registration: $($names.Dashboard)$(if ($dashboardAppId) { ": $dashboardAppId" })"

# ---- 7. the two custom roles, which the resource group does not hold --------------------
Write-Step 'The two custom roles the product creates: VMF Assessment and VMF Migration'
# ROLES-1: there is ONE pair for a subscription, and the scopes it may be
# granted at grow later. This call is not destructive: it reads what the roles
# already reach and passes the union, so an install run again after somebody
# onboarded a management group does not take that group away and break every
# grant made through it.
#
# The VMF_CREATE_ROLES switch that used to sit here is gone. It existed to skip
# this step when the roles "live at a management group" - a shape that only
# existed because of a belief now measured to be false. A role created here can
# be granted at a management group, so there is one place they live and no
# choice to make.
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfRoleScopes.ps1')
# ROLES-UX-1. Found 2026-09-10 during an install: this line did not say what
# it means, and it did not read right. The
# old text was 'The assess and migrate roles at the subscription (outside the
# stack; shared by every install here)' - a noun phrase with no verb, so a
# reader cannot tell whether it CHECKS or CREATES; 'the stack' is a word the
# operator has not met at this point in the output; and 'here' could mean this
# machine or this subscription. It also failed to say the one thing that
# matters most: this step gives nobody access to anything.
Write-Host '   These are CUSTOM roles this product defines. It uses no built-in Azure role for your machines.'
Write-Host '   Each one contains the operations the product performs, and nothing else.'
Write-Host '   Azure keeps them in this subscription. Every install in it uses the same two.'
Write-Host '   A removal of the product keeps them, because another install can still need them.'
Write-Host '   This step gives nobody access to your machines. You do that later, on the Admin page.'
$roleScopes = Set-VmfRoleScopes -SubscriptionId $subscription -Location $location -DeploymentName "vmf-roles-$envName"
# ROLES-UX-2: this line said "They can be granted at: <subscription id>", and
# a reader took it during a work install as proof the product already had
# access to that subscription. It does not: this names the places the roles MAY
# be given out, which is a property of the definition, not a grant to anybody.
#
# The line three rows above already says "This step gives nobody access to your
# machines", and was believed less than the subscription id printed under it.
# So the sentence that carries the meaning now sits immediately BEFORE the id,
# where a person reading downwards meets it first.
Write-Host '   Nobody holds either role yet, and this install gives nobody one.'
Write-Host "   These are the places you can give them out: $($roleScopes -join ', ')"
Write-Host ''
Write-Host 'Ready. azd now deploys the platform.'
