<#
.SYNOPSIS
    FIRSTRUN-1: what the account running the install is actually allowed to do.
.DESCRIPTION
    The install used to ask a question about permission and leave the person to
    work out whether they could answer it. Since 2026-09-15, the install reads
    the user's roles and gives guidance from them.

    So it reads. Two rights decide everything, they are different rights, and
    calling both of them "administrator" is what made this so hard to see:

      1. AZURE, on the subscription. Owner or User Access Administrator lets
         somebody give the product permission over machines.
      2. MICROSOFT ENTRA ID, in the directory. One of a few roles lets somebody
         give admin consent, which is what the Admin page needs before it works
         at all.

    A person can hold either, both or neither, and the four cases need
    different guidance. MEASURED in two tenants 2026-09-15: in one the installer
    holds Global Administrator and Owner through a management group; in the
    other the installer holds Owner on the subscription and no directory role. The
    second is the case this product exists for.

    WHAT IS NOT KNOWN IS SAID, NEVER GUESSED. Reading directory roles is
    refused in some tenants - measured, twice, once for an account holding
    Global Administrator. A refused read means UNKNOWN, and UNKNOWN offers
    everything rather than narrowing what a person may choose. A check that
    turned a refusal into "no" would take away the only answer that works.
#>

# CONSENT-DONE-CHECK-1: Get-VmfEntraServicePrincipal and Get-VmfDirectoryList,
# the product's one way to find a service principal by application id. The
# hooks load it through AzdHooks.ps1 already; the readiness check does not.
. (Join-Path $PSScriptRoot 'Resolve-VmfRegistration.ps1')

# Which directory roles can approve this product's permissions, from
# Microsoft's own prerequisites. tools/Test-VmfConsentReadiness.ps1 reads the
# same lists, so the two cannot disagree about who can consent.
$script:VmfConsentAnyPermission = @('Global Administrator', 'Privileged Role Administrator')
$script:VmfConsentDelegatedOnly = @('Cloud Application Administrator', 'Application Administrator', 'AI Administrator')

# INSTALL-CONSENT-PUSH-1: the role the install RECOMMENDS is the one with the
# fewest rights that can approve every permission this product asks for.
# Microsoft, read 2026-11-02:
#   learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent
#     (Prerequisites): Privileged Role Administrator for any permission;
#     Cloud Application Administrator, AI Administrator or Application
#     Administrator for any permission EXCEPT Microsoft Graph app roles.
#   learn.microsoft.com/entra/identity/role-based-access-control/delegate-by-task
#     "Consent to any delegated permissions": least privileged role Cloud
#     Application Administrator. "Consent to application permissions to
#     Microsoft Graph": Privileged Role Administrator.
# Every permission in infra/identity.bicep is delegated (type 'Scope'), so
# Cloud Application Administrator is enough. Privileged Role Administrator can
# give ANY directory role to anybody, Global Administrator included - it is
# not the least role here. A test holds this flag to identity.bicep.
$script:VmfProductAsksGraphAppRoles = $false

function Get-VmfConsentLeastRole {
    if ($script:VmfProductAsksGraphAppRoles) { 'Privileged Role Administrator' } else { 'Cloud Application Administrator' }
}

# The Azure roles that can grant a role to somebody else. Contributor cannot:
# it may build machines and may not hand out access to them.
$script:VmfGrantingRoles = @('Owner', 'User Access Administrator')

# A REFUSED READ MUST NOT THROW. `az ... | ConvertFrom-Json` with nothing on
# the pipeline fails with "Cannot bind argument to parameter 'InputObject'",
# and the install runs with $ErrorActionPreference = 'Stop' - so a directory
# that refuses a read would have ENDED THE INSTALL rather than leaving the
# answer unknown. Found by calling this function with Azure stubbed out; no
# amount of reading the script would have shown it.
function Read-VmfAzJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again; a read that
    # still fails is unknown, as before.
    $read = Invoke-VmfAzCall -Step 'read the directory' -Quiet -Command { az @Arguments -o json }
    if ($read.ExitCode -ne 0) { return $null }
    $text = $read.Output
    if (-not $text) { return $null }
    try { $text | ConvertFrom-Json } catch { $null }
}

function Get-VmfInstallerRights {
    <#
    .SYNOPSIS
        Read what the signed-in account may do, without changing anything.
    .OUTPUTS
        CanGrant / CanConsent, each 'yes', 'no' or 'unknown'.
        GrantRoles / ConsentRoles: what was found, for the person to read.
        IsPerson: false when a service principal runs the install.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $rights = [pscustomobject]@{
        IsPerson     = $false
        CanGrant     = 'unknown'
        CanConsent   = 'unknown'
        GrantRoles   = @()
        ConsentRoles = @()
    }

    $type = az account show --query 'user.type' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
    $rights.IsPerson = ($type -eq 'user')
    if (-not $rights.IsPerson) { return $rights }

    $me = (Invoke-VmfAzCall -Step 'read the signed-in user' -Quiet -Command { az ad signed-in-user show --query id -o tsv }).Output
    if (-not $me) { return $rights }

    # --include-inherited, and the ROLE NAME decides - never the scope string.
    # MEASURED 2026-09-15: an installer held Owner of a whole tenant through two
    # management groups and held NO assignment on the subscription itself. A
    # check that looked for an assignment whose scope is the subscription would
    # have told a user who holds Owner on everything that they may grant nothing.
    $assignments = Read-VmfAzJson -Arguments @(
        'role', 'assignment', 'list', '--assignee', $me,
        '--scope', "/subscriptions/$SubscriptionId", '--include-inherited')
    if ($null -ne $assignments) {
        $names = @($assignments | ForEach-Object { [string]$_.roleDefinitionName } | Where-Object { $_ })
        $rights.GrantRoles = @($names | Where-Object { $script:VmfGrantingRoles -contains $_ } | Sort-Object -Unique)
        $rights.CanGrant = if ($rights.GrantRoles.Count) { 'yes' } else { 'no' }
    }

    # One query parameter, no bracket filter: cmd eats both.
    $memberOf = Read-VmfAzJson -Arguments @(
        'rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me/memberOf')
    if ($null -ne $memberOf) {
        $held = @($memberOf.value |
            Where-Object { $_.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
            ForEach-Object { [string]$_.displayName })
        $can = @($script:VmfConsentAnyPermission + $script:VmfConsentDelegatedOnly)
        $rights.ConsentRoles = @($held | Where-Object { $can -contains $_ } | Sort-Object -Unique)
        # A role held as ELIGIBLE in PIM and not activated does not appear
        # here, so 'no' means "not right now", which is what matters today.
        $rights.CanConsent = if ($rights.ConsentRoles.Count) { 'yes' } else { 'no' }
    }

    $rights
}

# ---- INSTALL-CONSENT-PUSH-1: push, never block -----------------------------------------
#
# Since 2026-11-02, the install pushes its user toward a role that can give
# admin consent, not only a role at the subscription. A user without that role
# is told to work with a user who has it.
#
# The install used to say one line - the Admin page needs admin consent, and
# you cannot give it - and go on. Nothing said who could give it, or how to
# ask. FIRSTSCOPE-1 still holds: an Owner with no directory role installs,
# scans and migrates. This says, asks once, and hands over a link.

function Get-VmfConsentNotice {
    <#
    .SYNOPSIS
        What the install says about admin consent before it creates anything.
        Lines for a person to read; it reads nothing and decides nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rights)
    $least = Get-VmfConsentLeastRole
    $all = @($script:VmfConsentAnyPermission + $script:VmfConsentDelegatedOnly)
    $pim = '   A role that is eligible in Privileged Identity Management counts only when it is active. If you have one, activate it and run azd up again.'
    $lines = @(
        '   The full product needs admin consent in Microsoft Entra ID. Without it, the Admin page does not work.',
        "   These roles can give admin consent: $($all -join ', ').",
        "   Use $least. It is the role with the fewest rights that can approve every permission of this product."
    )
    if (-not $Rights.IsPerson) {
        $lines += '   A service principal runs this install. After the install, a user with one of these roles gives admin consent.'
        return $lines
    }
    switch ($Rights.CanConsent) {
        'yes' {
            $lines += "   You hold $(@($Rights.ConsentRoles) -join ' and '), so you can give admin consent. After the install creates the registrations, it asks to give admin consent for your organization."
        }
        'no' {
            $lines += '   You hold no role that can give admin consent.'
            $lines += $pim
        }
        default {
            # UNKNOWN IS SAID, NEVER GUESSED. A refused directory read is
            # measured, once for an account holding Global Administrator.
            $lines += '   This install could not read your Microsoft Entra roles, so it cannot say if you can give admin consent.'
            $lines += $pim
        }
    }
    $lines
}

function Invoke-VmfConsentPush {
    <#
    .SYNOPSIS
        The one question, for a person who can give no admin consent: Stop
        (the default) or Continue. Returns 'continue' or 'not-asked'; a Stop
        throws, before anything is created.
    .DESCRIPTION
        Asked through Read-VmfChoice (infra/hooks/AzdHooks.ps1), the way every
        install question is asked. Nobody else is asked anything: a person who
        can consent does not need it, UNKNOWN is never read as no, and a
        service principal has nobody to ask. With no console the install
        CONTINUES - it never stops an unattended install on a question nobody
        can answer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rights)
    if (-not $Rights.IsPerson -or $Rights.CanConsent -ne 'no') { return 'not-asked' }

    $least = Get-VmfConsentLeastRole
    $earlier = Get-AzdValue -Name 'VMF_CONSENT_LATER'
    $answer = Read-VmfChoice -Name 'VMF_CONSENT_LATER' -Default 'stop' -NoConsoleDefault 'continue' `
        -Question 'Stop now, or install without admin consent?' `
        -Help @('Nothing is created yet.',
                "If you continue, the install ends with a link. Send it to a person who holds $least.") `
        -Options @('stop|Stop. Run azd up again with a person who holds one of these roles.',
                   'continue|Continue. Install now, and send the link at the end to a person who holds one of these roles.')
    if ($answer -ne 'continue') {
        # A STOP IS NEVER KEPT. Read-VmfChoice records every answer and never
        # asks a recorded one again, so a kept Stop would stop every later run
        # with no question to answer.
        Set-AzdValue -Name 'VMF_CONSENT_LATER' -Value ''
        throw ("The install stopped before it created anything. Run azd up again with a person who holds $least, " +
               'or run it again and choose Continue.')
    }
    if ($earlier) { Write-Host '   You chose Continue on an earlier install, so this install continues.' }
    Write-Host '   The install continues. It ends with the link to send.'
    'continue'
}

function Get-VmfConsentRequestWorkflow {
    <#
    .SYNOPSIS
        Is Microsoft's admin consent request workflow on in this directory?
        'on', 'off' or 'unknown'. A refused read is unknown, never off.
    #>
    [CmdletBinding()]
    param()
    # One URL, no query string: az.cmd hands its arguments to cmd, which eats
    # an '&' (CLAUDE.md). tools/Test-VmfConsentReadiness.ps1 reads the same.
    $policy = Read-VmfAzJson -Arguments @(
        'rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/policies/adminConsentRequestPolicy')
    if ($null -eq $policy -or $null -eq $policy.PSObject.Properties['isEnabled']) { return 'unknown' }
    if ($policy.isEnabled -eq $true) { 'on' } else { 'off' }
}

function Get-VmfAdminConsentUrl {
    <#
    .SYNOPSIS
        Microsoft's tenant-wide admin consent URL for one registration, or
        $null. Built from two ids the install already holds, and from nothing
        else, so no other text can reach the URL.
        learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent
    #>
    [CmdletBinding()]
    param([string]$TenantId, [string]$ClientId)
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($TenantId -notmatch $guid -or $ClientId -notmatch $guid) { return $null }
    "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$ClientId"
}

function Get-VmfConsentHandoff {
    <#
    .SYNOPSIS
        The end of the install: how admin consent gets given, and by whom.
        Lines for a person to read. Nobody is handed a command (rule 12): the
        person with the role approves in the browser.
    .PARAMETER NoLinkLine
        What to say when there is no link. The install says it did not record
        the ids; the readiness check, run before an install, says the install
        ends with the link (CONSENT-TOOL-LINK-1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CanConsent,
        [Parameter(Mandatory)][ValidateSet('on', 'off', 'unknown')][string]$Workflow,
        [string]$TenantId = '',
        [string]$ClientId = '',
        [string]$RegistrationName = '',
        [string]$NoLinkLine = '   The install could not make the link, because it did not record the IDs it needs.'
    )
    $least = Get-VmfConsentLeastRole
    $others = @(@($script:VmfConsentAnyPermission + $script:VmfConsentDelegatedOnly) | Where-Object { $_ -ne $least })
    $url = Get-VmfAdminConsentUrl -TenantId $TenantId -ClientId $ClientId
    $registration = if ($RegistrationName) { $RegistrationName } else { 'the dashboard registration' }
    $portal = "   Or, in the Microsoft Entra admin center: App registrations, $registration, API permissions, then Grant admin consent."
    $lines = @()
    if ($CanConsent -eq 'yes') {
        if ($url) {
            $lines += '   You hold a role that can give admin consent. Open this link, read the permissions, and select Accept:'
            $lines += "     $url"
        }
        else {
            $lines += '   You hold a role that can give admin consent.'
            $lines += $NoLinkLine
        }
        $lines += $portal
        return $lines
    }

    $lines += "   A person who holds $least gives admin consent. $($others -join ', ') can also give it."
    $linkLead = '   Send this link to a person who holds one of these roles. They open it, read the permissions, and select Accept:'
    switch ($Workflow) {
        'on' {
            $lines += '   Your directory has the admin consent request workflow on. Sign in to the dashboard and open the Admin page.'
            $lines += '   When Microsoft asks for approval, type a reason and select Request approval.'
            $lines += '   A reviewer approves it in the Microsoft Entra admin center: Enterprise apps, then Admin consent requests.'
            $linkLead = '   Or send this link to a person who holds one of these roles. They open it and select Accept:'
        }
        'unknown' {
            # No speaker: the install and the readiness check both say it.
            $lines += '   This account could not read if your directory has the admin consent request workflow on.'
            $lines += '   If Microsoft shows Request approval when you open the Admin page, use it.'
        }
    }
    if ($url) {
        $lines += $linkLead
        $lines += "     $url"
    }
    else {
        $lines += $NoLinkLine
    }
    $lines += $portal
    $lines
}

# ---- CONSENT-DONE-CHECK-1: ask only when it is not given --------------------------------
#
# Every install and every update ended with "One directory action is left" and
# the hand-off above, also for an install whose administrator approved it weeks
# ago. So a customer could send an administrator to approve the product again
# for nothing. The install now READS the grants first.
#
# The delegated permissions the dashboard registration asks for, by the
# application id of the API that offers them - infra/identity.bicep, and a test
# holds this list to it. Admin consent from the link or the portal grants all
# of them at once, so "given" means every one of them, organization-wide.
# This product's own access_as_user is not here: identity.bicep pre-authorizes
# the dashboard for it, so it never needs consent.
$script:VmfDashboardConsentScopes = [ordered]@{
    '00000003-0000-0000-c000-000000000000' = @{
        Name   = 'Microsoft Graph'
        Scopes = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All', 'User.ReadBasic.All', 'Group.Read.All')
    }
    '797f4846-ba00-4fd7-ba43-dac1f8f63013' = @{
        Name   = 'Azure Service Management'
        Scopes = @('user_impersonation')
    }
}

function Get-VmfAdminConsentState {
    <#
    .SYNOPSIS
        Does the dashboard registration have admin consent for the whole
        organization? Reads only.
    .OUTPUTS
        State: 'given', 'partial' (an organization-wide grant that misses some
        permissions), 'person-only' (users approved it for themselves only),
        'none', or 'unknown'. Missing: the permissions no organization-wide
        grant covers. People: how many users approved it for themselves.
    .DESCRIPTION
        Read the way tools/Test-VmfConsentReadiness.ps1 always read it: the
        dashboard's service principal by APPLICATION ID, then its
        oauth2PermissionGrants by clientId. The grants come from
        `az ad app permission list-grants`, which filters on the service
        principal's clientId itself and follows Microsoft Graph's next pages.
        A plain `az rest` GET returns the first page only, and the next page's
        URL carries an '&' that cmd eats (CLAUDE.md) - so a directory with many
        person-level grants could hide the organization-wide one on page two.

        A grant counts only for the resource it names, found by application id
        too: a scope NAME is not proof of the API it belongs to.

        A REFUSED READ IS UNKNOWN, NEVER GIVEN. Unknown prints the hand-off,
        because a request sent for nothing costs less than an install that
        claims a consent nobody gave.
    #>
    [CmdletBinding()]
    param([string]$ClientId = '')
    $unknown = [pscustomobject]@{ State = 'unknown'; Missing = @(); People = 0 }

    # Get-VmfEntraServicePrincipal THROWS on a failed read, and on anything
    # that is not an application id before it reads at all, and returns $null
    # only when the directory holds none - the difference this needs.
    try { $sp = Get-VmfEntraServicePrincipal -AppId $ClientId } catch { return $unknown }
    if ($null -eq $sp) {
        # No service principal: nobody can have approved anything.
        return [pscustomobject]@{ State = 'none'; Missing = @(); People = 0 }
    }
    $spId = [string]$sp.id
    try {
        $grants = Get-VmfDirectoryList -Arguments @('ad', 'app', 'permission', 'list-grants', '--id', $ClientId) `
            -What "the permission grants of application $ClientId"
    }
    catch { return $unknown }
    $grants = @($grants | Where-Object { $null -ne $_ -and [string]$_.clientId -eq $spId })

    $missing = @()
    $anyOrgWide = $false
    foreach ($resourceAppId in $script:VmfDashboardConsentScopes.Keys) {
        try { $resource = Get-VmfEntraServicePrincipal -AppId $resourceAppId } catch { return $unknown }
        $have = @()
        if ($null -ne $resource) {
            $orgWide = @($grants | Where-Object {
                [string]$_.consentType -eq 'AllPrincipals' -and [string]$_.resourceId -eq [string]$resource.id })
            if ($orgWide.Count) { $anyOrgWide = $true }
            $have = @($orgWide | ForEach-Object { ([string]$_.scope) -split '\s+' } | Where-Object { $_ })
        }
        $missing += @($script:VmfDashboardConsentScopes[$resourceAppId].Scopes | Where-Object { $have -notcontains $_ })
    }
    $people = @($grants | Where-Object { [string]$_.consentType -eq 'Principal' } |
        ForEach-Object { [string]$_.principalId } | Where-Object { $_ } | Sort-Object -Unique).Count

    $state = if ($missing.Count -eq 0) { 'given' }
             elseif ($anyOrgWide) { 'partial' }
             elseif ($people -gt 0) { 'person-only' }
             else { 'none' }
    [pscustomobject]@{ State = $state; Missing = @($missing); People = $people }
}

function Get-VmfAdminConsentStatus {
    <#
    .SYNOPSIS
        One or two lines that say what Get-VmfAdminConsentState read. Nothing
        for a state nobody read (a service principal runs the install: CD-1).
    #>
    [CmdletBinding()]
    param($Consent)
    if ($null -eq $Consent) { return @() }
    switch ([string]$Consent.State) {
        'given' { @('   Nothing is left to do in Microsoft Entra ID. Give roles to users on the Admin page.') }
        'partial' {
            @("   The admin consent in your directory does not include these permissions: $(@($Consent.Missing) -join ', ').",
              '   A person who holds one of the roles below gives admin consent again to add them.')
        }
        'person-only' {
            $who = if ([int]$Consent.People -eq 1) {
                '   One user approved the product for that user only, so its permissions work for that user and nobody else.'
            }
            else {
                "   $([int]$Consent.People) users approved the product each for themselves, so its permissions work for them and nobody else."
            }
            @($who, '   Nobody gave admin consent for your organization.')
        }
        'none' { @('   Nobody gave admin consent for your organization.') }
        default { @('   This account could not read if your organization has admin consent for the product.') }
    }
}

function Get-VmfConsentClosing {
    <#
    .SYNOPSIS
        Everything the install says about admin consent at its end. The FIRST
        line is the heading; the hook gives it a colour.
    .DESCRIPTION
        Given: say so, and send nobody to an administrator. Anything else -
        partial, person-only, none, unknown, or not read - says what is left
        and gives the hand-off, as every install did before.
    #>
    [CmdletBinding()]
    param(
        $Consent,
        [Parameter(Mandatory)][string]$CanConsent,
        [Parameter(Mandatory)][ValidateSet('on', 'off', 'unknown')][string]$Workflow,
        [string]$TenantId = '',
        [string]$ClientId = '',
        [string]$RegistrationName = ''
    )
    if ($null -ne $Consent -and [string]$Consent.State -eq 'given') {
        return @('Your organization has admin consent for the product.') + @(Get-VmfAdminConsentStatus -Consent $Consent)
    }
    $lines = @('One directory action is left, before you can give anyone else access.')
    $lines += @(Get-VmfAdminConsentStatus -Consent $Consent)
    $lines += @(
        '   In most directories you can use the product now. Signing in, assessments, migrations'
        '   and reports ask only for permissions a user may approve.'
        '   Your directory can be stricter. If Microsoft refuses your first sign-in, it lets a user'
        '   approve nothing, or only what an administrator marked as low impact. Then the action'
        '   below must happen first, not later.'
        '   THE ADMIN PAGE IS DIFFERENT. It reads your directory to show who can sign in and to'
        '   give and remove roles, and Microsoft Entra reserves those permissions for a directory'
        '   administrator. Until that is approved you are the only person who can sign in, because'
        '   the Admin page is where a role is given.'
        ''
    )
    $lines += @(Get-VmfConsentHandoff -CanConsent $CanConsent -Workflow $Workflow -TenantId $TenantId `
        -ClientId $ClientId -RegistrationName $RegistrationName)
    $lines
}

# ---- INSTALL-CONSENT-IN-FLOW-1: give it during azd up, for a person who can ----------
#
# Found 2026-11-16, before the final lab: a Global Administrator should give
# the admin consent during azd up, as part of the flow, and the install did
# not. CONSENT-1 (2026-09-09) had decided that an install
# should not approve permissions across a directory "quietly on somebody's
# behalf", so even a Global Administrator finished with a link to open. Now the
# install ASKS - one question, nothing quiet - and a yes gives admin consent as
# the signed-in user, with that user's own directory role. A person who cannot
# consent, an unknown, and a service principal see what they saw before.
#
# HOW, AND WHY NOT `az ad app permission admin-consent`. That command (read in
# az 2.88) still posts to main.iam.ad.ext.azure.com, the portal's own
# undocumented API, which Microsoft does not support in sovereign clouds and
# does not document. Microsoft documents admin consent through Microsoft Graph:
# one oauth2PermissionGrant per API, consentType AllPrincipals
# (learn.microsoft.com/entra/identity/enterprise-apps/grant-admin-consent,
# "Microsoft Graph API"). So this writes those, with `az rest`, as the
# signed-in user - no service principal, no secret.
#
# WHAT IT GRANTS is $script:VmfDashboardConsentScopes, the list
# Get-VmfAdminConsentState checks and a test holds to identity.bicep - so the
# read back asks exactly what the grant wrote. Every permission is delegated
# (type 'Scope'); a Microsoft Graph app role would need an appRoleAssignment
# this does not make, so the grant refuses rather than claim it.

function Grant-VmfDashboardAdminConsent {
    <#
    .SYNOPSIS
        Give admin consent for the whole organization to every delegated
        permission the dashboard registration asks for. Throws on anything it
        cannot do; the caller reports it and reads back.
    .DESCRIPTION
        For each API: no organization-wide grant -> POST one with every scope;
        one there with scopes missing -> PATCH it with its own scopes plus the
        missing ones; nothing missing -> nothing written. A grant a user gave
        for themselves (consentType Principal) is never changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ClientId)
    if ($script:VmfProductAsksGraphAppRoles) {
        throw 'The dashboard registration asks for a Microsoft Graph application permission. The install gives admin consent only for delegated permissions.'
    }
    # Throws on a failed read and on anything that is not an application id.
    $sp = Get-VmfEntraServicePrincipal -AppId $ClientId
    if ($null -eq $sp) {
        throw "Microsoft Entra ID has no service principal for the dashboard registration $ClientId."
    }
    $spId = [string]$sp.id
    $grants = Get-VmfDirectoryList -Arguments @('ad', 'app', 'permission', 'list-grants', '--id', $ClientId) `
        -What "the permission grants of application $ClientId"
    $orgWide = @($grants | Where-Object {
        $null -ne $_ -and [string]$_.clientId -eq $spId -and [string]$_.consentType -eq 'AllPrincipals' })

    foreach ($resourceAppId in $script:VmfDashboardConsentScopes.Keys) {
        $api = $script:VmfDashboardConsentScopes[$resourceAppId]
        $resource = Get-VmfEntraServicePrincipal -AppId $resourceAppId
        if ($null -eq $resource) { throw "Microsoft Entra ID has no service principal for $($api.Name)." }
        $resourceId = [string]$resource.id
        $existing = @($orgWide | Where-Object { [string]$_.resourceId -eq $resourceId })
        $have = @($existing | ForEach-Object { ([string]$_.scope) -split '\s+' } | Where-Object { $_ })
        $missing = @($api.Scopes | Where-Object { $have -notcontains $_ })
        if ($missing.Count -eq 0) { continue }

        if ($existing.Count) {
            $grantId = [string]$existing[0].id
            # The id goes into a URL that cmd reads: a Microsoft Graph grant id
            # is base64url, and anything else is refused, never sent.
            if ($grantId -notmatch '^[A-Za-z0-9_-]+$') {
                throw "The admin consent grant for $($api.Name) has an ID the install does not send: $grantId."
            }
            $kept = @((([string]$existing[0].scope) -split '\s+') | Where-Object { $_ })
            $method = 'PATCH'
            $url = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$grantId"
            $body = @{ scope = (@($kept + $missing) -join ' ') }
        }
        else {
            $method = 'POST'
            $url = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants'
            $body = [ordered]@{ clientId = $spId; consentType = 'AllPrincipals'; resourceId = $resourceId
                                scope = (@($api.Scopes) -join ' ') }
        }
        # The body goes in a file: a JSON string through az.cmd loses its quotes.
        $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-consent-$(New-VmfRunTag).json"
        $body | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
        try {
            # INSTALL-THROTTLE-RETRY-2: a throttled grant is tried again.
            $sent = Invoke-VmfAzCall -Step "give admin consent for $($api.Name)" -Quiet -Command {
                az rest --method $method --url $url --headers 'Content-Type=application/json' --body "@$bodyFile" --output none
            }
            $said = @(@($sent.ErrorLines) + @($sent.Output))
            $code = $sent.ExitCode
        }
        finally { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
        if ($code -ne 0) {
            $why = (@($said | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join ' ').Trim()
            throw "Microsoft Entra ID refused admin consent for $($api.Name): $why"
        }
    }
}

function Invoke-VmfAdminConsentInFlow {
    <#
    .SYNOPSIS
        The one question, for a person who can give admin consent, when the
        organization does not have it: give it now (the default), or not.
        Returns the admin consent to show at the end - READ BACK after a grant,
        else the one the caller read.
    .DESCRIPTION
        Asked through Read-VmfChoice (VMF_ADMIN_CONSENT), the way every install
        question is asked. With no console it takes yes, as a person pressing
        Enter would: consent is part of the flow, and Yes does
        not stop the install (INSTALL-CONSENT-PUSH-1 differs only because its
        default, Stop, would). Nobody else is asked: CanConsent 'no' or
        'unknown' is never read as yes, and a service principal is never
        asked (CD-1).

        A FAILURE IS REPORTED, NEVER THROWN, like the first scope: the platform
        is deployed and works, and the closing gives the link. And only a read
        back of 'given' is given: a grant command that answered 0 proves
        nothing about what the directory holds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rights,
        $Consent,
        [AllowEmptyString()][string]$ClientId = '',
        [int]$ReadBackTries = 6
    )
    if (-not $Rights.IsPerson -or $Rights.CanConsent -ne 'yes') { return $Consent }
    if ($null -ne $Consent -and [string]$Consent.State -eq 'given') { return $Consent }
    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($ClientId -notmatch $guid) { return $Consent }

    $help = @("You hold $(@($Rights.ConsentRoles) -join ' and '), so you can give admin consent in Microsoft Entra ID.",
              'Admin consent approves these permissions of the dashboard registration for all users in your organization:')
    foreach ($resourceAppId in $script:VmfDashboardConsentScopes.Keys) {
        $api = $script:VmfDashboardConsentScopes[$resourceAppId]
        $help += "  $($api.Name): $(@($api.Scopes) -join ', ')."
    }
    $help += 'Without admin consent, the Admin page does not work.'
    $answer = Read-VmfChoice -Name 'VMF_ADMIN_CONSENT' -Default 'yes' `
        -Question 'Give admin consent for your organization now?' -Help $help `
        -Options @('yes|Yes. Give admin consent now, as the signed-in user.',
                   'no|No. Give no admin consent now. The end of the install shows how to give it later.')
    if ($answer -ne 'yes') {
        Write-Host '   The install gives no admin consent. The end of the install shows how to give it.'
        return $Consent
    }

    Write-Step 'Giving admin consent for your organization'
    $granted = $false
    try {
        Grant-VmfDashboardAdminConsent -ClientId $ClientId
        $granted = $true
    }
    catch {
        Write-Host ''
        Write-Host 'The install could not give admin consent.' -ForegroundColor Yellow
        Write-Host "   $($_.Exception.Message)"
        Write-Host '   The platform is deployed and running. The end of the install shows how to give admin consent.'
    }

    # READ BACK. Microsoft Entra ID can show a new grant some seconds late, so
    # a grant that was sent is read up to $ReadBackTries times; a failed one
    # is read once, because part of it can have been written.
    $tries = if ($granted) { [Math]::Max(1, $ReadBackTries) } else { 1 }
    $read = $null
    for ($i = 1; $i -le $tries; $i++) {
        $read = Get-VmfAdminConsentState -ClientId $ClientId
        if ([string]$read.State -eq 'given') { break }
        if ($i -lt $tries) { Start-Sleep -Seconds 10 }
    }
    if ($granted -and [string]$read.State -ne 'given') {
        Write-Host '   The install gave admin consent, but the directory does not show it for every permission.'
    }
    $read
}