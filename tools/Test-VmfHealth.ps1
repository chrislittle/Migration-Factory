<#
.SYNOPSIS
    HEALTH-1: one command that says whether a deployed install actually works.
.DESCRIPTION
    Run it after an install, after an update, or when the dashboard says
    something you do not believe. It prints one table. Paste that table.

    It follows the chain a person's sign-in actually takes, and the FIRST row
    that says PROBLEM is where it breaks:

      1. you are signed in to Azure, and where
      2. the platform is there
      3. the DASHBOARD is configured with registration X
      4. the SERVICE validates tokens against registration Y
      5. X and Y are the same        <- a mismatch here is an HTTP 401
      6. you hold a role in the product, and which
      7. the service answers YOU, with your own token
      8. the engine can reach machines in Azure
      9. the perimeter around the run store has no unresolved issue

    Row 7 is the one no other check can do. The API pre-authorises the Azure
    CLI (infra/identity.bicep), so this asks Entra for the SAME token the
    browser asks for and calls the service with it. A browser showing "you have
    no role" while this row passes means the page is wrong, not your access.

    It reads. It changes nothing, and it needs no permission a person running
    an install does not already hold.
    ID-ADDRESS-1: it checks ONE install. Two resources of a kind whose names
    start alike (two installs in one resource group, or the old facade a
    hosting-plan change leaves) are a PROBLEM row that names both. Give the
    exact name with -FacadeName, -DashboardName, -EngineIdentityName or
    -StorageAccountName.
.EXAMPLE
    ./tools/Test-VmfHealth.ps1 -ResourceGroup rg-contoso-demo
.EXAMPLE
    ./tools/Test-VmfHealth.ps1 -ResourceGroup rg-contoso-demo -FacadeName vmf-facade-b1-contoso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$ApiDisplayName,
    # ID-ADDRESS-1: the exact names, where a name prefix matches more than one.
    [string]$FacadeName = '',
    [string]$DashboardName = '',
    [string]$EngineIdentityName = '',
    [string]$StorageAccountName = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRegistration.ps1')

$script:rows = [System.Collections.Generic.List[object]]::new()
function Add-Row {
    param([string]$Check, [string]$Result, [string]$Detail = '')
    $script:rows.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
}

# A JWT's middle part, as an object. base64url is base64 with two characters
# swapped and the padding left off.
function ConvertFrom-VmfTokenPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    $part = ($Token -split '\.')[1]
    if (-not $part) { return $null }
    $part = $part.Replace('-', '+').Replace('_', '/')
    switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
    try { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($part)) | ConvertFrom-Json }
    catch { $null }
}

# What a refused call actually said. The service answers with { error: '...' };
# anything else is handed back as it came.
function Get-VmfBodyText {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Response)
    $raw = [string]($Response.Content)
    if (-not $raw) { return 'no answer body' }
    try {
        $doc = $raw | ConvertFrom-Json
        $text = [string]$doc.error
        if ($text) { return $text }
    }
    catch { }
    $raw.Trim()
}

# The one comparison this whole script exists for.
function Test-VmfRegistrationMatch {
    [CmdletBinding()]
    param([AllowNull()][string]$DashboardAppId, [AllowNull()][string]$ServiceAppId)
    if (-not $DashboardAppId -or -not $ServiceAppId) { return 'UNKNOWN' }
    if ($DashboardAppId -eq $ServiceAppId) { return 'MATCH' }
    'MISMATCH'
}

# EASYAUTH-403-1, MEASURED on a live service: an EMPTY allowedApplications
# array makes App Service refuse every caller with HTTP 403, whatever token
# they hold. Microsoft documents the opposite - that the list restricts only
# when it holds an id. Four states of one site, one property changed at a
# time, proved it: remove the array and the service answers 200; put the
# empty array back and the 403 returns.
#
# THE COUNT IS THE TRAP. @($policy.allowedApplications) is 1 when the property
# is absent, because @($null) has one element - so an absent list read as a
# configured list, and the table printed the permitted applications with
# nothing after it.
function Get-VmfAuthPolicyVerdict {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Policy)
    if (-not $Policy) {
        return [pscustomobject]@{ Result = 'OK'; Detail = 'no authorization policy. The service accepts every caller Entra issues a token for.' }
    }
    $stated = $null -ne $Policy.PSObject.Properties['allowedApplications']
    $apps = @($Policy.allowedApplications | Where-Object { $_ })
    if ($apps.Count) {
        return [pscustomobject]@{ Result = 'INFO'; Detail = "only these client applications: $($apps -join ', ')" }
    }
    if ($stated) {
        return [pscustomobject]@{
            Result = 'PROBLEM'
            Detail = ('allowedApplications is configured and holds no application id. The service refuses EVERY caller with HTTP 403. ' +
                      'Deploy the platform template again. It states the applications that are permitted. See docs/backlog/easyauth-403-1.')
        }
    }
    [pscustomobject]@{ Result = 'OK'; Detail = 'the policy permits every application.' }
}

# NSP-5: what Azure says about the perimeter around the run store. The portal
# shows this as "Issues (1)" on the association, which is where it was found -
# by accident, while looking for something else. Nobody finds it there twice.
#
# THE ISSUE NAMES ARE NOT A CLOSED LIST. Microsoft's own schema for this
# response declares two issue types and Azure answers with names that are in
# neither, MissingIdentityConfiguration among them. So this reports what Azure
# said and decides on SEVERITY, which is Warning or Error.
function Get-VmfPerimeterVerdict {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Configurations)
    $configs = @($Configurations | Where-Object { $_ })
    if (-not $configs.Count) {
        return [pscustomobject]@{ Result = 'OK'; Detail = 'the run store is in no perimeter. Only the storage account rules apply.' }
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    $worst = 'OK'
    foreach ($c in $configs) {
        $mode = [string]$c.properties.resourceAssociation.accessMode
        if (-not $mode) { $mode = 'unknown access mode' }
        $state = [string]$c.properties.provisioningState
        $issues = @($c.properties.provisioningIssues | Where-Object { $_ })
        $errors = @($issues | Where-Object { [string]$_.properties.severity -eq 'Error' })
        $said = ($issues | ForEach-Object { "$($_.name) ($($_.properties.severity))" }) -join ', '
        if ($errors.Count) {
            $worst = 'PROBLEM'
            $parts.Add("$mode. Azure reports an error: $said. $([string]$errors[0].properties.description)")
        }
        elseif ($state -and $state -ne 'Succeeded') {
            $worst = 'PROBLEM'
            $parts.Add("$mode. Azure did not apply the configuration: $state.")
        }
        elseif ($issues.Count) {
            if ($worst -eq 'OK') { $worst = 'INFO' }
            $parts.Add("$mode. Azure reports: $said.")
        }
        else { $parts.Add("$mode. Azure reports no issue.") }
    }
    [pscustomobject]@{ Result = $worst; Detail = ($parts -join ' ') }
}

# REACH-1: the engine and the web service are two identities, and the dashboard
# needs both. The service reads Azure with its OWN identity - the wizard's
# resource group list is its answer, not the browser's - so a subscription the
# engine can reach and the service cannot shows a picker with nothing in it.
#
# MEASURED on a lab install 2026-09-15: the engine held a role on the
# subscription, the service held nothing outside the product's resource group,
# and this check said "The engine can reach ..." and nothing else. A true
# sentence about the wrong identity.
# FIRSTSCOPE-1: WHAT THE PRODUCT MAY DO, which is a different question from
# what it can reach - and the one this tool never asked.
#
# MEASURED on a corporate install, 2026-09-22: both identities held
# VMF Assessment at the subscription, neither held a migration role anywhere,
# and this tool printed "Every check passed". Every row was true. The install
# could not stop a machine, resize one, take a safety copy or run anything in
# a guest - and the person relying on it found that out with a demo the next
# day. His words: "you had me run a check prior and it was fine".
#
# Scan-only is a LEGITIMATE choice, so this is not a failure. It is a FACT the
# tool has to say out loud, because nothing else does: the Admin page needs a
# consent some directories reserve for an administrator, and the install
# records the answer once and never asks again.
function Get-VmfCapabilityVerdict {
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$EngineGrants)

    $grants  = @($EngineGrants | Where-Object { $_ })
    $migrate = @($grants | Where-Object { $_.roleDefinitionName -like 'VMF Migration*' })
    $assess  = @($grants | Where-Object { $_.roleDefinitionName -like 'VMF Assessment*' })

    if ($migrate.Count) {
        $where = @($migrate | ForEach-Object { $_.scope }) -join ', '
        return [pscustomobject]@{
            Result = 'OK'
            Detail = "scan and migrate, in $where"
        }
    }
    if ($assess.Count) {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = ('SCAN ONLY. No place has the migration role, so this install cannot stop a machine, ' +
                      'resize one, take a safety copy or run anything inside a guest. To migrate, give the ' +
                      'engine the migration role on the Admin page, or run the install again and answer ' +
                      'that it may migrate.')
        }
    }
    return [pscustomobject]@{
        Result = 'PROBLEM'
        Detail = 'nothing. The engine holds neither role, so it can neither scan nor migrate.'
    }
}

function Get-VmfReachVerdict {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][string[]]$EngineScopes,
        [Parameter()][AllowNull()][string[]]$ServiceScopes
    )
    # REACH-2: one scope per GRANT arrives here, so an identity holding two
    # roles at one place named it twice - "both reach /subscriptions/s,
    # /subscriptions/s". Seen the moment a corporate install gained
    # its migration role beside its assessment role. Harmless, and it reads
    # like the tool cannot count, which is the last thing a health check should
    # look like when somebody is deciding whether to trust it.
    $engine = @($EngineScopes | Where-Object { $_ } | Select-Object -Unique)
    $service = @($ServiceScopes | Where-Object { $_ } | Select-Object -Unique)
    if (-not $engine.Count) {
        return [pscustomobject]@{
            Result = 'PROBLEM'
            Detail = 'nothing. Until it is given access, an assessment finds no machines. Give it access on the Admin page, or with tools/Grant-VmfAccess.ps1.'
        }
    }
    # A scope the engine reaches and the service does not. Compared as text,
    # because a grant at a subscription covers a resource group inside it and
    # the string does not say so - this reports what it can see and never
    # claims the reverse.
    $blind = @($engine | Where-Object { $service -notcontains $_ })
    if (-not $service.Count) {
        return [pscustomobject]@{
            Result = 'PROBLEM'
            Detail = ("the engine reaches $($engine -join ', '), and the web service reaches nothing. " +
                      'The dashboard asks the service for resource groups, so its lists are empty. ' +
                      'Run tools/Grant-VmfAccess.ps1 again to give the service read access.')
        }
    }
    if ($blind.Count) {
        return [pscustomobject]@{
            Result = 'INFO'
            Detail = ("the engine reaches $($engine -join ', '); the web service reaches $($service -join ', '). " +
                      'Where the service does not reach, the dashboard cannot list resource groups.')
        }
    }
    [pscustomobject]@{ Result = 'OK'; Detail = "both reach $($engine -join ', ')" }
}

# ID-ADDRESS-1: one resource of a kind, by the rule every tool uses
# (Select-VmfOneByName). Two that match are not an error that stops the check:
# the refusal is kept for the row that needs the resource, and that row says it.
$script:pickProblems = @{}
function Select-VmfHealthResource {
    param([AllowNull()][object[]]$Items, [string]$Exact, [string]$Prefix, [string]$What, [string]$NameParameter, [string]$Row)
    try {
        Select-VmfOneByName -Items $Items -Exact $Exact -Prefix $Prefix -What $What -NameParameter $NameParameter `
            -ResourceGroup $ResourceGroup -Use 'check'
    }
    catch {
        if (-not $script:pickProblems.ContainsKey($Row)) { $script:pickProblems[$Row] = $_.Exception.Message }
        $null
    }
}

function Get-VmfJson {
    param([string[]]$Arguments)
    $text = & az @Arguments -o json 2>$null
    $global:LASTEXITCODE = 0
    if (-not $text) { return $null }
    try { $text | ConvertFrom-Json } catch { $null }
}

# ---- 1. who you are ------------------------------------------------------
$account = Get-VmfJson @('account', 'show')
if (-not $account) {
    Add-Row 'Signed in to Azure' 'PROBLEM' 'az is not signed in. Run az login.'
    # ---- 9. the perimeter around the run store -------------------------------
# NSP-1: the perimeter is what lets this product work against a store that a
# corporate policy has closed. An unresolved issue on it, in Enforced mode,
# is the kind of thing that works until it does not - and until now the
# install said nothing about it at all.
$storeAccount = Select-VmfHealthResource -Items @(Get-VmfJson @('storage', 'account', 'list', '-g', $ResourceGroup)) -Exact $StorageAccountName `
    -Prefix 'vmfstate' -What 'storage accounts' -NameParameter 'StorageAccountName' -Row 'The run store perimeter'
if ($script:pickProblems['The run store perimeter']) { Add-Row 'The run store perimeter' 'PROBLEM' $script:pickProblems['The run store perimeter'] }
elseif (-not $storeAccount) { Add-Row 'The run store perimeter' 'UNKNOWN' "no vmfstate account in '$ResourceGroup'" }
else {
    # Read from the STORE, not from the perimeter: this answer is the effective
    # configuration Azure applies to the account, issues and all, and it is
    # what the portal shows on the association. One query parameter, because
    # an & in a URL given to az rest is a command separator to cmd.
    $nspUrl = "https://management.azure.com$($storeAccount.id)/networkSecurityPerimeterConfigurations?api-version=2023-05-01"
    $nsp = Get-VmfJson @('rest', '--method', 'GET', '--url', $nspUrl)
    $perimeter = Get-VmfPerimeterVerdict -Configurations $nsp.value
    Add-Row 'The run store perimeter' $perimeter.Result $perimeter.Detail
}

$script:rows | Format-Table -AutoSize -Wrap
    return
}
Add-Row 'Signed in to Azure' 'OK' "$($account.user.name) in subscription $($account.name)"

# ---- 2. the platform -----------------------------------------------------
# TWO LISTS, because they are two kinds of resource. The facade is a FUNCTION
# app and `az webapp list` does not return those - the first version of this
# check looked there and reported a healthy install as missing its service.
$facade = Select-VmfHealthResource -Items @(Get-VmfJson @('functionapp', 'list', '-g', $ResourceGroup)) -Exact $FacadeName `
    -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -Row 'The platform'
$dashboard = Select-VmfHealthResource -Items @(Get-VmfJson @('webapp', 'list', '-g', $ResourceGroup)) -Exact $DashboardName `
    -Prefix 'vmf-dash' -What 'web apps' -NameParameter 'DashboardName' -Row 'The platform'
$engineMi = Select-VmfHealthResource -Items @(Get-VmfJson @('identity', 'list', '-g', $ResourceGroup)) -Exact $EngineIdentityName `
    -Prefix 'vmf-engine-mi' -What 'managed identities' -NameParameter 'EngineIdentityName' -Row 'What can reach your machines'

if ($script:pickProblems['The platform']) { Add-Row 'The platform' 'PROBLEM' $script:pickProblems['The platform'] }
elseif (-not $facade) {
    Add-Row 'The platform' 'PROBLEM' $(if ($FacadeName) { "No function app named '$FacadeName' in '$ResourceGroup'." }
                                       else { "No vmf-facade site in '$ResourceGroup'. Is that the right resource group?" })
}
elseif (-not $dashboard) { Add-Row 'The platform' 'PROBLEM' "The service is there, the dashboard is not, in '$ResourceGroup'." }
else { Add-Row 'The platform' 'OK' "service $($facade.name), dashboard $($dashboard.name)" }

if ($facade -and $dashboard) {
    $dashUrl = "https://$($dashboard.defaultHostName)"
    $facadeUrl = "https://$($facade.defaultHostName)"

    # ---- 3. what the DASHBOARD is configured with ------------------------
    $dashAppId = $null
    try {
        $cfg = Invoke-RestMethod -Uri "$dashUrl/dashboard.config.json" -TimeoutSec 30
        $dashAppId = [string]$cfg.apiAppId
        if ($dashAppId) { Add-Row 'The dashboard is configured with' 'OK' $dashAppId }
        else { Add-Row 'The dashboard is configured with' 'PROBLEM' 'its configuration names no API registration' }
    }
    catch { Add-Row 'The dashboard is configured with' 'UNKNOWN' "could not read $dashUrl/dashboard.config.json - $($_.Exception.Message)" }

    # ---- 4. what the SERVICE validates against ---------------------------
    $svcAppId = $null
    # STRAIGHT TO ARM, not through `az webapp auth show`. MEASURED: an older
    # CLI answers that with the v1 shape, whose every v2 field is null, and
    # `az webapp auth v2 show` is not in it at all.
    $settingsUrl = "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$ResourceGroup" +
                   "/providers/Microsoft.Web/sites/$($facade.name)/config/authsettingsV2?api-version=2022-03-01"
    $authDoc = Get-VmfJson @('rest', '--method', 'GET', '--url', $settingsUrl)
    $aad = $authDoc.properties.identityProviders.azureActiveDirectory
    $svcAppId = [string]$aad.registration.clientId
    if (-not $svcAppId) {
        $auth = Get-VmfJson @('webapp', 'auth', 'show', '-g', $ResourceGroup, '-n', $facade.name)
        $svcAppId = [string]$auth.clientId
    }
    if ($svcAppId) { Add-Row 'The service validates against' 'OK' $svcAppId }
    else { Add-Row 'The service validates against' 'UNKNOWN' 'the sign-in settings could not be read' }

    # ---- 5. THE COMPARISON ----------------------------------------------
    switch (Test-VmfRegistrationMatch -DashboardAppId $dashAppId -ServiceAppId $svcAppId) {
        'MATCH' { Add-Row 'They are the same registration' 'OK' 'the dashboard and the service agree' }
        'MISMATCH' {
            Add-Row 'They are the same registration' 'PROBLEM' `
                'THEY DISAGREE. Every call from the dashboard is refused with HTTP 401, whatever role you hold. Run azd up to write both from one source.'
        }
        default { Add-Row 'They are the same registration' 'UNKNOWN' 'one of the two could not be read' }
    }

    # ---- 5b. what the sign-in layer refuses before any code runs ----------
    # Every caller got HTTP 403 on this install - the browser and the command
    # line alike - with the right registration, the right audiences and a role
    # in the token. A 403 from here is App Service, not the product, and it is
    # invisible from inside the app.
    $verdict = Get-VmfAuthPolicyVerdict -Policy $aad.validation.defaultAuthorizationPolicy
    Add-Row 'What the sign-in layer allows' $verdict.Result $verdict.Detail

    $authApp = @(Get-VmfJson @('webapp', 'config', 'appsettings', 'list', '-g', $ResourceGroup, '-n', $facade.name) |
        Where-Object { $_.name -like 'WEBSITE_AUTH*' })
    if ($authApp.Count) {
        # These two refuse every caller when wrong, whatever their role.
        Add-Row 'Sign-in settings on the service' 'INFO' (($authApp | ForEach-Object { "$($_.name)=$($_.value)" }) -join '; ')
    }
    else { Add-Row 'Sign-in settings on the service' 'OK' 'none set' }

    # ---- 6. your role, out of a REAL token -------------------------------
    $apiAppId = if ($dashAppId) { $dashAppId } elseif ($svcAppId) { $svcAppId } else { $null }
    $token = $null
    if ($apiAppId) {
        # --scope, NOT --resource. MEASURED: `--resource api://<id>` returns a
        # v1.0 token, whose issuer is sts.windows.net. The service's sign-in is
        # configured for the v2.0 issuer (platform.bicep), so Easy Auth refuses
        # it before any code runs and answers "You do not have permission to
        # view this directory or page" - which reads exactly like a role
        # refusal and is not one. The browser uses v2.0; this must too, or the
        # row tests something the product never does.
        $issued = Get-VmfJson @('account', 'get-access-token', '--scope', "api://$apiAppId/access_as_user")
        $token = [string]$issued.accessToken
    }
    if (-not $apiAppId) { Add-Row 'Your role in the product' 'UNKNOWN' 'no registration to ask about' }
    elseif (-not $token) {
        # Entra refuses this token outright to somebody with no role.
        Add-Row 'Your role in the product' 'PROBLEM' `
            'Entra would not issue a token for this product. Usually that means you hold no role in it (AADSTS50105).'
    }
    else {
        $claims = ConvertFrom-VmfTokenPayload -Token $token
        # NOT @($claims.roles): a token with no roles claim gives $null, and
        # @($null) has ONE element - so an empty list would have read as OK.
        $roles = @($claims.roles | Where-Object { $_ })
        if ($roles.Count) { Add-Row 'Your role in the product' 'OK' ($roles -join ', ') }
        else { Add-Row 'Your role in the product' 'PROBLEM' 'the token carries no role. Somebody with the Admin role can give you one.' }
    }

    # ---- 7. does the service answer YOU ----------------------------------
    if ($token) {
        try {
            $answer = Invoke-WebRequest -Uri "$facadeUrl/api/version" -Headers @{ Authorization = "Bearer $token" } `
                -TimeoutSec 90 -SkipHttpErrorCheck
            $code = [int]$answer.StatusCode
            if ($code -eq 200) { Add-Row 'The service answers you' 'OK' "HTTP 200 from $facadeUrl/api/version" }
            elseif ($code -eq 401) {
                Add-Row 'The service answers you' 'PROBLEM' `
                    'HTTP 401 - the service refused your token. Compare the two registrations above; they are the usual cause.'
            }
            elseif ($code -eq 403) {
                # THE BODY, not just the code. The service's own refusal names
                # the roles it required AND the roles it saw, and swallowing
                # that cost an evening: the table said "your role does not
                # allow this" while Entra said Vmf.Admin, and the one line that
                # reconciled them was in the response.
                Add-Row 'The service answers you' 'PROBLEM' "HTTP 403 - $(Get-VmfBodyText -Response $answer)"
            }
            else { Add-Row 'The service answers you' 'PROBLEM' "HTTP $code - $(Get-VmfBodyText -Response $answer)" }
        }
        catch { Add-Row 'The service answers you' 'PROBLEM' $_.Exception.Message }
    }
    else { Add-Row 'The service answers you' 'SKIPPED' 'no token to ask with' }
}

# ---- 8. what the engine can reach ---------------------------------------
if ($script:pickProblems['What can reach your machines']) { Add-Row 'What can reach your machines' 'PROBLEM' $script:pickProblems['What can reach your machines'] }
elseif (-not $engineMi) { Add-Row 'What can reach your machines' 'PROBLEM' "no vmf-engine-mi identity in '$ResourceGroup'" }
else {
    $engineGrants = @(Get-VmfJson @('role', 'assignment', 'list', '--assignee', $engineMi.principalId, '--all') |
        Where-Object { $_.roleDefinitionName -like 'VMF *' })
    # BOTH identities, because the dashboard needs both. The service is the
    # function app read at the top of this script.
    $serviceGrants = @()
    if ($facade -and $facade.identity -and $facade.identity.principalId) {
        $serviceGrants = @(Get-VmfJson @('role', 'assignment', 'list', '--assignee', $facade.identity.principalId, '--all') |
            Where-Object { $_.roleDefinitionName -like 'VMF *' })
    }
    $reach = Get-VmfReachVerdict -EngineScopes @($engineGrants | ForEach-Object { $_.scope }) `
                                 -ServiceScopes @($serviceGrants | ForEach-Object { $_.scope })
    Add-Row 'What can reach your machines' $reach.Result $reach.Detail
    foreach ($g in $engineGrants) { Add-Row 'The engine can reach' 'OK' "$($g.roleDefinitionName) at $($g.scope)" }
    foreach ($g in $serviceGrants) { Add-Row 'The service can reach' 'OK' "$($g.roleDefinitionName) at $($g.scope)" }
    # FIRSTSCOPE-1: reach is not capability. Said last, because it is the row a
    # person is actually asking about when they run this.
    $capable = Get-VmfCapabilityVerdict -EngineGrants $engineGrants
    Add-Row 'What it may DO with them' $capable.Result $capable.Detail
}

# ---- 9. the perimeter around the run store -------------------------------
# NSP-1: the perimeter is what lets this product work against a store that a
# corporate policy has closed. An unresolved issue on it, in Enforced mode,
# is the kind of thing that works until it does not - and until now the
# install said nothing about it at all.
$storeAccount = Select-VmfHealthResource -Items @(Get-VmfJson @('storage', 'account', 'list', '-g', $ResourceGroup)) -Exact $StorageAccountName `
    -Prefix 'vmfstate' -What 'storage accounts' -NameParameter 'StorageAccountName' -Row 'The run store perimeter'
if ($script:pickProblems['The run store perimeter']) { Add-Row 'The run store perimeter' 'PROBLEM' $script:pickProblems['The run store perimeter'] }
elseif (-not $storeAccount) { Add-Row 'The run store perimeter' 'UNKNOWN' "no vmfstate account in '$ResourceGroup'" }
else {
    # Read from the STORE, not from the perimeter: this answer is the effective
    # configuration Azure applies to the account, issues and all, and it is
    # what the portal shows on the association. One query parameter, because
    # an & in a URL given to az rest is a command separator to cmd.
    $nspUrl = "https://management.azure.com$($storeAccount.id)/networkSecurityPerimeterConfigurations?api-version=2023-05-01"
    $nsp = Get-VmfJson @('rest', '--method', 'GET', '--url', $nspUrl)
    $perimeter = Get-VmfPerimeterVerdict -Configurations $nsp.value
    Add-Row 'The run store perimeter' $perimeter.Result $perimeter.Detail
}

# Both verdicts are worked out BEFORE the table is printed. A pipeline run
# after Format-Table interleaves with the formatter's own output and PowerShell
# refuses it - "not valid or not in the correct sequence", which says nothing
# about the cause.
$problems = @($script:rows | Where-Object { $_.Result -eq 'PROBLEM' })
$scanOnly = @($script:rows | Where-Object { $_.Check -eq 'What it may DO with them' -and $_.Detail -like 'SCAN ONLY*' })

$script:rows | Format-Table -AutoSize -Wrap
if ($problems.Count) {
    Write-Host ''
    Write-Host "The first PROBLEM above is where it breaks: $($problems[0].Check)" -ForegroundColor Yellow
}
else {
    Write-Host ''
    Write-Host 'Every check passed.' -ForegroundColor Green
    # FIRSTSCOPE-1: "Every check passed" was printed on an install that could
    # not migrate a machine. Nothing had failed - the tool had not asked. It
    # asks now, and a scan-only install is said here as well as in the table,
    # because this line is the one people read.
    if ($scanOnly.Count) {
        Write-Host 'This install may SCAN. It may NOT migrate a machine - see the row above.' -ForegroundColor Yellow
    }
}
