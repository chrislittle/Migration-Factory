<#
.SYNOPSIS
    CONSENT-1: can the signed-in account approve this product's permissions in
    THIS directory? Read-only.
.DESCRIPTION
    THERE ARE TWO CONSENT QUESTIONS, AND THEY HAVE DIFFERENT ANSWERS. Reading
    them as one question is how this check was wrong the first time.

    1. THE PRODUCT. The dashboard reads Azure as the SIGNED-IN USER, never with
       a key of its own, and reaches the run store through this product's own
       API:

         Azure Service Mgmt   user_impersonation
         this product's API   access_as_user

       Entra reserves none of those for an administrator. Whether an ordinary
       USER may approve them is a per-directory setting, and this script reads
       it rather than assuming.

    2. THE ADMIN PAGE, which gives and removes people's access:

         AppRoleAssignment.ReadWrite.All   give and remove a person's role
         Application.Read.All              read the product's own registration
         Group.Read.All                    give a role to a group

       Entra reserves these four for an administrator in EVERY directory. No
       setting changes that. (IDENTITY-4 removed a fifth, AuditLog.Read.All,
       with the control that needed it.)

    So the answer is one of two shapes. A directory that lets users consent
    gives you a product you can install and use ALONE, with the Admin page
    waiting for an administrator. A directory that does not lets you install
    it, and then waits for an administrator before the FIRST sign-in.

    THIS SCRIPT ONLY READS. It grants no consent, changes no role, and writes
    nothing anywhere. Run it in any tenant you can sign in to.

    Which roles are enough, from Microsoft's own prerequisites:
      Privileged Role Administrator ......... any permission, any API
      Cloud Application Administrator ....... any permission EXCEPT Microsoft
      Application Administrator ............. Graph APPLICATION permissions
      AI Administrator ...................... (app roles)
    Global Administrator holds all of it.

    THE SECOND GROUP IS ENOUGH FOR THIS PRODUCT. Every permission it asks for
    is DELEGATED - `type: 'Scope'` in infra/identity.bicep - and it asks for no
    Graph app role at all. That matters in a corporate directory, where
    Application Administrator is common and Privileged Role Administrator is
    not.

    The question, 2026-09-10: in another Azure environment, such as a
    corporate tenant, how does a user check that they can consent to the app?
    Being able to create apps does not answer which roles they hold.

    And then: "my whole need is to make sure a user can consent OR an admin can
    consent or wide. either is fine. we seem to have assumed admin is the only
    avenue to this app working." He was right, and the first version of this
    script repeated the same mistake in its own output.

    MEASURED 2026-09-10, from the built-in policy definitions themselves:
      microsoft-user-default-legacy       classification 'all' - a user may
                                          approve anything not admin-only
      microsoft-user-default-recommended  classification 'all'
      microsoft-user-default-low          classification 'low' - a user may
                                          approve ONLY permissions this
                                          directory has classified as low
                                          impact, and NOTHING is classified by
                                          default
    The 'low' policy also limits WHICH applications: Microsoft's words are
    "apps from verified publishers and apps that are registered in your
    tenant". This product is registered in the customer's own tenant by the
    install, so it passes that half and fails on classification.

.EXAMPLE
    az login --tenant <your-corp-tenant>
    ./tools/Test-VmfConsentReadiness.ps1

.EXAMPLE
    ./tools/Test-VmfConsentReadiness.ps1 -DashboardDisplayName 'vmf-dashboard-prod'
#>
[CmdletBinding()]
param(
    # Only needed when the product is already registered in this tenant and you
    # want its current consent read back.
    [Parameter()][string]$DashboardDisplayName = ''
)

$ErrorActionPreference = 'Continue'

function Read-Graph {
    <#
        Returns the parsed body, or $null AND a reason. A read that FAILED must
        never look like a read that came back empty - that is how a check
        reports a clean result it never made.
    #>
    param([Parameter(Mandatory)][string]$Url)

    # NEVER put an '&' in this URL. az.cmd passes its arguments through cmd,
    # which treats '&' as a command separator - so a second query parameter is
    # silently cut off and the FIRST one goes too. MEASURED 2026-09-10:
    # `applications?$filter=...&$select=...` returned EVERY application in the
    # tenant with exit code 1, rather than the one asked for. The same family as
    # the `az --query "[?...]"` mangling already in CLAUDE.md.
    # One parameter per call. Filter the rest here.
    if ($Url -like '*&*') { throw "Read-Graph: '&' in a URL is eaten by cmd. Use one query parameter: $Url" }

    $raw = az rest --method GET --url $Url -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        $text = ($raw | Out-String).Trim()
        # Graph answers a refusal with a JSON body. Its first LINE is '{', which
        # tells a reader nothing - dig out the message it actually sent.
        # And az does not hand back that body alone: MEASURED 2026-09-10, it
        # arrives as `ERROR: Forbidden({"error":...})` - a prefix AND a trailing
        # bracket, so ConvertFrom-Json rejects it. Take the range from the FIRST
        # brace to the LAST. Cutting only the prefix is not enough: that closing
        # ')' still fails the parse, and the reader gets 200 characters of noise.
        $why = ''
        $brace = $text.IndexOf('{')
        $close = $text.LastIndexOf('}')
        if ($brace -ge 0 -and $close -gt $brace) {
            try { $why = [string](($text.Substring($brace, $close - $brace + 1) | ConvertFrom-Json).error.message) } catch { $why = '' }
        }
        if (-not $why) { $why = (($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)).Trim() }
        if ($why.Length -gt 200) { $why = $why.Substring(0, 200) + '...' }
        return [pscustomobject]@{ Ok = $false; Body = $null; Why = $why }
    }
    try { return [pscustomobject]@{ Ok = $true; Body = ($raw | ConvertFrom-Json); Why = '' } }
    catch { return [pscustomobject]@{ Ok = $false; Body = $null; Why = 'the answer could not be read as JSON' } }
}

# ONE LIST of the roles that can consent, and ONE hand-off: the install's own
# (CONSENT-TOOL-LINK-1). This check ended by printing an az command for
# somebody else to run, after the install had stopped doing that (rule 12).
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfInstallerRights.ps1')
$anyPermission = $script:VmfConsentAnyPermission
$delegatedOnly = $script:VmfConsentDelegatedOnly

Write-Host ''
Write-Host '== Who you are' -ForegroundColor Cyan
$me = Read-Graph -Url 'https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName'
if (-not $me.Ok) {
    Write-Host "   your account could not be read: $($me.Why)"
    Write-Host '   Sign in first:  az login --tenant <tenant>'
    return
}
Write-Host "   $($me.Body.displayName)  <$($me.Body.userPrincipalName)>"
if ([string]$me.Body.userPrincipalName -like '*#EXT#*') {
    # A guest is a member of another directory. Guests rarely hold a directory
    # role here, and cannot be given one as easily, so say it now.
    Write-Host '   You are a GUEST in this directory, not a member.' -ForegroundColor Yellow
    Write-Host '   A guest can hold a directory role. The next section reads whether you do.'
}
$org = Read-Graph -Url 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName'
if ($org.Ok) {
    $o = @($org.Body.value)[0]
    Write-Host "   directory: $($o.displayName)  $($o.id)"
}
else { Write-Host "   directory: could not be read - $($org.Why)" }

Write-Host ''
Write-Host '== Directory roles active on your account right now' -ForegroundColor Cyan
$roles = Read-Graph -Url 'https://graph.microsoft.com/v1.0/me/memberOf'
$held = @()
if ($roles.Ok) {
    $held = @($roles.Body.value |
        Where-Object { $_.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
        ForEach-Object { [string]$_.displayName })
    if ($held.Count -eq 0) { Write-Host '   none' }
    else { $held | Sort-Object | ForEach-Object { Write-Host "   $_" } }
}
else {
    Write-Host "   COULD NOT BE READ - $($roles.Why)"
    Write-Host '   So everything below about your own roles is UNKNOWN, not "no".'
}

Write-Host ''
Write-Host '== Can you approve it as an administrator?' -ForegroundColor Cyan
if (-not $roles.Ok) {
    Write-Host '   UNKNOWN. Your roles could not be read, so this cannot say.'
}
else {
    $full = @($held | Where-Object { $anyPermission -contains $_ })
    $partial = @($held | Where-Object { $delegatedOnly -contains $_ })
    if ($full.Count -gt 0) {
        Write-Host "   YES - you hold $($full -join ', ')." -ForegroundColor Green
        Write-Host '   That covers any permission for any API.'
    }
    elseif ($partial.Count -gt 0) {
        Write-Host "   YES - you hold $($partial -join ', ')." -ForegroundColor Green
        Write-Host '   That role cannot approve Microsoft Graph APPLICATION permissions (app roles).'
        Write-Host '   This product asks for none: every permission it wants is delegated, so it is enough.'
        Write-Host '   That covers the Admin page too, which is the part that always needs an administrator.'
    }
    else {
        Write-Host '   NOT AS AN ADMINISTRATOR - no role that can approve is active on your account.' -ForegroundColor Yellow
        Write-Host '   Any ONE of these roles can approve all of it:'
        foreach ($r in ($anyPermission + $delegatedOnly)) { Write-Host "      $r" }
        Write-Host '   This is not the whole answer. The next section reads whether this directory'
        Write-Host '   lets an ordinary user approve the product for themselves.'
    }
}
Write-Host '   PIM: this lists roles ACTIVE now. A role held as ELIGIBLE and not activated' -ForegroundColor DarkGray
Write-Host '   does not appear here. Activate it and run this again.' -ForegroundColor DarkGray

Write-Host ''
Write-Host '== Can an ordinary user approve the product here?' -ForegroundColor Cyan
$gated = @()
$policy = Read-Graph -Url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy'
if (-not $policy.Ok) {
    Write-Host "   COULD NOT BE READ - $($policy.Why)"
    Write-Host '   Reading it needs Policy.Read.All, which an ordinary account usually does not hold.'
    Write-Host '   So this is UNKNOWN, not "no". Ask an administrator to run this part.'
}
else {
    # Only the ForSelf policies decide what a USER may approve. The
    # ForOwnedResource ones govern Teams and chat resources and say nothing here.
    $assigned = @($policy.Body.defaultUserRolePermissions.permissionGrantPoliciesAssigned |
        Where-Object { $_ -like 'ManagePermissionGrantsForSelf.*' })
    if ($assigned.Count -eq 0) {
        Write-Host '   NO - this directory turns user consent off.' -ForegroundColor Yellow
        Write-Host '   An administrator must approve the product before the first sign-in.'
    }
    else {
        # Read what each assigned policy INCLUDES. Never read the answer off the
        # policy name: a directory can assign a custom policy, and a name is not
        # a rule. MEASURED 2026-09-10 on the built-in definitions: the legacy and
        # recommended policies carry classification 'all', the low policy carries
        # classification 'low'.
        $open = @()
        $unread = @()
        foreach ($name in $assigned) {
            $id = $name.Substring($name.IndexOf('.') + 1)
            $inc = Read-Graph -Url "https://graph.microsoft.com/v1.0/policies/permissionGrantPolicies/$id/includes"
            if (-not $inc.Ok) { $unread += $id; continue }
            $classes = @($inc.Body.value | ForEach-Object { [string]$_.permissionClassification })
            if ($classes -contains 'all') { $open += $id } else { $gated += $id }
        }
        if ($open.Count -gt 0) {
            Write-Host '   YES - a user can approve the product for themselves.' -ForegroundColor Green
            Write-Host "   This directory assigns: $($open -join ', ')"
            Write-Host '   That rule sets no classification limit, so it covers the three permissions'
            Write-Host '   the product needs to run. The Admin page still needs an administrator, once.'
        }
        elseif ($gated.Count -gt 0) {
            Write-Host '   ONLY FOR PERMISSIONS THIS DIRECTORY MARKS AS LOW IMPACT.' -ForegroundColor Yellow
            Write-Host "   This directory assigns: $($gated -join ', ')"
            Write-Host '   Entra marks nothing as low impact until an administrator does it.'
        }
        if ($unread.Count -gt 0) {
            Write-Host "   the rules for these could not be read: $($unread -join ', ')"
            Write-Host '   So those are UNKNOWN, not "no".'
        }
    }
}

if ($gated.Count -gt 0) {
    Write-Host '   What this directory marks as low impact, for the permissions the product needs:'
    foreach ($res in @(
        @{ Name = 'Azure Service Management'; AppId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'; Scope = 'user_impersonation' }
    )) {
        $spFilter = [uri]::EscapeDataString("appId eq '$($res.AppId)'")
        $resSp = Read-Graph -Url "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$spFilter"
        if (-not $resSp.Ok) { Write-Host "      $($res.Name): could not be read - $($resSp.Why)"; continue }
        if (@($resSp.Body.value).Count -eq 0) { Write-Host "      $($res.Name): not in this directory yet"; continue }
        $resSpId = @($resSp.Body.value)[0].id
        $marks = Read-Graph -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$resSpId/delegatedPermissionClassifications"
        if (-not $marks.Ok) { Write-Host "      $($res.Name): the marks could not be read - $($marks.Why)"; continue }
        $low = @($marks.Body.value | Where-Object { $_.classification -eq 'low' -and $_.permissionName -eq $res.Scope })
        if ($low.Count -gt 0) { Write-Host "      $($res.Name) $($res.Scope): marked low, so a user can approve it" -ForegroundColor Green }
        else { Write-Host "      $($res.Name) $($res.Scope): not marked, so a user cannot approve it" -ForegroundColor Yellow }
    }
    Write-Host '      this product access_as_user: the install creates it, so no mark can exist yet.'
    Write-Host '   An administrator must either mark these as low impact, or approve the product.'
}

$req = Read-Graph -Url 'https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy'
if ($req.Ok) {
    if ($req.Body.isEnabled) { Write-Host '   You can ask for approval from the sign-in page: the request workflow is on.' }
    else { Write-Host '   The request workflow is off, so ask an administrator directly.' }
}
else {
    # A read that failed must not be SILENT either. The first version printed
    # nothing here, and nothing reads as "there was nothing to say".
    Write-Host "   whether you can ask for approval from the portal could not be read - $($req.Why)"
}

$consent = $null
$apps = $null
if ($DashboardDisplayName) {
    Write-Host ''
    Write-Host "== Is '$DashboardDisplayName' registered here already?" -ForegroundColor Cyan
    $filter = [uri]::EscapeDataString("displayName eq '$DashboardDisplayName'")
    $apps = Read-Graph -Url "https://graph.microsoft.com/v1.0/applications?`$filter=$filter"
    if (-not $apps.Ok) { Write-Host "   could not be read - $($apps.Why)" }
    elseif (@($apps.Body.value).Count -eq 0) { Write-Host '   not registered in this directory yet' }
    else {
        foreach ($app in @($apps.Body.value)) {
            Write-Host "   $($app.displayName)  application id $($app.appId)"
            # CONSENT-DONE-CHECK-1: the install reads the same thing with the
            # same function, so the two cannot give two answers.
            $state = Get-VmfAdminConsentState -ClientId ([string]$app.appId)
            if (@($apps.Body.value).Count -eq 1) { $consent = $state }
            $colour = if ($state.State -eq 'given') { 'Green' } else { 'Yellow' }
            if ($state.State -eq 'given') { Write-Host '      Your organization has admin consent for the product.' -ForegroundColor $colour }
            foreach ($line in (Get-VmfAdminConsentStatus -Consent $state)) { Write-Host "   $line" -ForegroundColor $colour }
            if ($state.State -eq 'person-only') {
                # MEASURED 2026-09-10 on a lab install: three grants,
                # all consentType 'Principal'. A Global Administrator met the
                # consent screen and did not select "Consent on behalf of your
                # organization" - so it worked for that administrator and nobody else.
                Write-Host '      This happens when an administrator signs in and does not select Consent on behalf of your organization.'
            }
        }
    }
}

Write-Host ''
Write-Host '== How admin consent gets given' -ForegroundColor Cyan
if ($null -ne $consent -and $consent.State -eq 'given') {
    Write-Host '   Nothing is left to do. Your organization has admin consent for the product.' -ForegroundColor Green
}
else {
    $canConsent = 'unknown'
    if ($roles.Ok) {
        $canConsent = if (@($held | Where-Object { ($anyPermission + $delegatedOnly) -contains $_ }).Count) { 'yes' } else { 'no' }
    }
    $workflow = 'unknown'
    if ($req.Ok -and $null -ne $req.Body.PSObject.Properties['isEnabled']) {
        $workflow = if ($req.Body.isEnabled -eq $true) { 'on' } else { 'off' }
    }
    $tenantId = if ($org.Ok) { [string]@($org.Body.value)[0].id } else { '' }
    # The link needs the dashboard registration's application id. Before the
    # install there is none, and the install ends with the link.
    $clientId = if ($consent) { [string]@($apps.Body.value)[0].appId } else { '' }
    $noLink = '   The install ends with a link to send, made for its own dashboard registration.'
    # INSTALL-CONSENT-IN-FLOW-1: a person who can give it is asked during the
    # install, and a yes gives it there.
    if ($canConsent -eq 'yes') {
        $noLink = '   After the install creates the registrations, it asks to give admin consent for your organization.'
    }
    if ($apps -and $apps.Ok -and @($apps.Body.value).Count -gt 1) {
        $noLink = '   More than one registration has this name, so this check makes no link. Use the link the install showed.'
    }
    $handoff = @{
        CanConsent = $canConsent; Workflow = $workflow; TenantId = $tenantId; ClientId = $clientId
        NoLinkLine = $noLink
    }
    if ($clientId) { $handoff.RegistrationName = [string]@($apps.Body.value)[0].displayName }
    Get-VmfConsentHandoff @handoff | ForEach-Object { Write-Host $_ }
}
Write-Host 'This script changed nothing.' -ForegroundColor DarkGray
