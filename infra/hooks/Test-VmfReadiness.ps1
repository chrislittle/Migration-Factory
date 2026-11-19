<#
.SYNOPSIS
    INSTALL-1 piece 5: is this subscription ready for the platform? Asked
    BEFORE the first resource is created.
.DESCRIPTION
    Can the azd install check quota for everything it deploys? Partly
    (2026-09-04). This says what it
    checked, what has room, and what it could not check - with the error text
    to expect if that part fails later. It refuses only on a definite
    blocker; a check it cannot make is said, never guessed.

    What Azure will say in advance:
      - the tools on this machine (az, azd, PowerShell 7, the containerapp
        extension) and their versions;
      - the signed-in subscription is the one azd will deploy to;
      - the resource providers the platform needs are registered (and it
        asks Azure to register the missing ones - that needs the right to,
        which an Owner or Contributor on the subscription has);
      - the region offers Container Apps with workload profiles;
      - Container Apps environments: the region's count against its limit;
      - storage accounts: the region's count against its limit;
      - App Service plans: the F1 plan the dashboard needs, and the Y1 or B1
        plan the service needs, each against its limit.
    App Service plan quota answers under the Microsoft.Quota provider scoped to
    Microsoft.Web, NOT at the locations/{location}/usages path the other two
    providers use. Found 2026-09-10: App Service plans do have a quota API;
    this check used the wrong one.
.PARAMETER Location
    The region azd will deploy to.
.PARAMETER SubscriptionId
    The subscription azd will deploy to.
.OUTPUTS
    One object per check: Check, Result (ok | warn | blocker | unknown), Detail.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId,
    # The install's resource group. A plan it already holds needs no room.
    [string]$ResourceGroup = ''
)
$ErrorActionPreference = 'Stop'
# INSTALL-THROTTLE-RETRY-2: each Azure Resource Manager read below tries a
# throttled answer again (Invoke-VmfAzCall). A read that still fails keeps its
# meaning: a check it could not make, said as unknown, never a blocker made
# from a throttle.
. (Join-Path $PSScriptRoot '..' 'Invoke-VmfAzStep.ps1')
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Check, [string]$Result, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
}

# ---- tools ---------------------------------------------------------------------
# READINESS-FIX-WORDS-1 (2026-11-10): an item that does not pass stops
# azd and says what to do - every blocker's detail ends with
# the action, in the words of docs/manual/install/if-it-fails.md. And a
# version is said as a fact - "version X is installed" - never "too old".
$retry = ', then run azd up again.'
$otherRegion = 'Choose another region: azd env set AZURE_LOCATION <region>, then run azd up again.'
$azVersion = $null
try { $azVersion = [version]((az version -o json | ConvertFrom-Json).'azure-cli') } catch { $azVersion = $null }
if (-not $azVersion) { Add-Check 'Azure CLI' 'blocker' "The Azure CLI is not installed. Install the Azure CLI version 2.61.0 or a later version$retry" }
# NO-STACKS-2: the blocker used to read "too old for deployment stacks", which
# is a reason that stopped being true when NO-STACKS-1 dropped them. THE FLOOR
# IS DELIBERATELY UNCHANGED: 2.61 was chosen for stacks and nobody has measured
# what this product actually needs without them, so lowering it here would be a
# guess. A wrong reason is removed; a floor is not moved on a hunch.
elseif ($azVersion -lt [version]'2.61.0') { Add-Check 'Azure CLI' 'blocker' "Azure CLI version $azVersion is installed. Install version 2.61.0 or a later version$retry" }
else { Add-Check 'Azure CLI' 'ok' "az $azVersion" }

# azd and PowerShell 7 are said, never checked. Only azd runs this script,
# from the preprovision hook, and azure.yaml runs that hook with pwsh - so
# "azd was not found" and "PowerShell 6 or earlier" could never be true here.
# (2026-11-10: a script azd runs cannot find azd missing.) The rows
# stay because the versions help to read a failed install.
Add-Check 'Azure Developer CLI' 'ok' ((azd version) -join ' ')
Add-Check 'PowerShell' 'ok' "PowerShell $($PSVersionTable.PSVersion)"

function Get-VmfExtensionVerdict {
    <#
    .SYNOPSIS
        EXT-1: what to report for the containerapp extension. Pure logic, so it
        is testable without an Azure CLI in any particular state.
    .DESCRIPTION
        MEASURED 2026-09-10 on a corporate machine, mid-install:
        `az extension list` NAMED the extension and reported an EMPTY version,
        and this check printed "ok  version " - an ok with nothing behind it.
        One line below, the workload-profile listing that USES the extension
        failed, and the operator got a message about REGIONS for a problem with
        their own machine.

        An extension directory can exist while its metadata does not, which is
        what a part-finished install leaves behind: it lists, and then it does
        not work. Reporting ok because a NAME appeared is the same defect this
        install has now been fixed for three times - a check that states
        something it never measured.
    .OUTPUTS
        Result (ok | warn | blocker), Detail, and Broken - which the
        workload-profile check reads so it can name the likely cause.
    #>
    param(
        [Parameter()]$Extension,
        [Parameter()][bool]$InstallSucceeded
    )
    $repair = 'az extension remove -n containerapp; az extension add -n containerapp --upgrade'
    if (-not $Extension) {
        if ($InstallSucceeded) {
            # `az extension add` said it worked and the extension still does not
            # list. That is not an ok - it is the same "report a result nobody
            # measured" trap, one step further along.
            return [pscustomobject]@{
                Result = 'warn'
                Detail = "it installed without error and still does not list. Repair it: $repair"
                Broken = $true
            }
        }
        return [pscustomobject]@{ Result = 'blocker'; Detail = 'The install could not add this extension. Run: az extension add -n containerapp, then run azd up again.'; Broken = $true }
    }
    $version = [string]$Extension.version
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        return [pscustomobject]@{ Result = 'ok'; Detail = "version $version"; Broken = $false }
    }
    # A BLOCKER, not a warning. MEASURED 2026-09-10 on that machine, and
    # the chain is proven end to end: az could list the extension DIRECTORIES
    # and could not read the .dist-info inside them, which is the same code path
    # that returns the version. The traceback named a DIFFERENT extension
    # (automation), so the whole extension tree was unreadable and every
    # `az containerapp` command was broken.
    #
    # The install needs one of them - `az containerapp job update`, which points
    # the engine job at the image it just built. That runs in postprovision,
    # AFTER 10 to 15 minutes of deployment and real money. Warning about it and
    # carrying on spends both to reach a failure this check already saw.
    # AND NOW IT ASKS THE EXTENSION, rather than deciding from its metadata.
    #
    # MEASURED 2026-09-15, on the same machine: the install hit this blocker,
    # removed nothing, REOPENED POWERSHELL AS ADMINISTRATOR, and the row read
    # 'ok version 1.3.0b5'. The extension was never broken. What changed was
    # who was asking.
    #
    # An unreadable version is a SYMPTOM. Whether `az containerapp` works is the
    # question, and it can be asked for nothing: --help loads the extension and
    # calls no Azure service. A check that infers the answer instead of asking
    # sent somebody to remove a working extension, which is the one action here
    # that can make a machine worse.
    $probe = & az containerapp job --help 2>$null
    $works = ($LASTEXITCODE -eq 0) -and $probe
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0 }
    if ($works) {
        return [pscustomobject]@{
            Result = 'ok'
            Detail = 'its version cannot be read, and it runs. Nothing to repair.'
            Broken = $false
        }
    }
    # WHAT IT ACTUALLY IS, measured on that machine 2026-09-15:
    #
    #   PermissionError: [WinError 5] Access is denied:
    #   'C:\Users\<name>\.azure\cliextensions\containerapp\containerapp-1.3.0b5.dist-info'
    #
    # The extension is not broken and the files are in the person's OWN
    # profile. Their permissions refuse them. 12 of his 13 extensions were in
    # that state and one was not, which is the tell: the 12 were installed from
    # an ELEVATED window, so Administrators owns them.
    #
    # THE REMEDY THIS USED TO PRINT CAUSED IT. "Repair it in a PowerShell
    # running as administrator: az extension remove; az extension add" installs
    # the extension elevated again, so the next ordinary window fails the same
    # way. Microsoft documents no administrator anywhere in this: an extension
    # belongs in %USERPROFILE%\.azure\cliextensions and an ordinary account
    # owns it.
    return [pscustomobject]@{
        Result = 'blocker'
        Detail = ('the Azure CLI cannot read this extension, so az containerapp fails. The files are in your own ' +
                  'profile and their permissions refuse you. This happens when an extension is installed from a ' +
                  'window opened as administrator, and it usually affects every extension installed that way. ' +
                  'To repair the permissions, in PowerShell as administrator: ' +
                  'icacls "$env:USERPROFILE\.azure\cliextensions" /reset /T ' +
                  '- then run this check again in an ordinary window. To go on now instead, run the install from a ' +
                  'window opened as administrator. Do not add the extension again as administrator: that is the cause.')
        Broken = $true
    }
}

$ext = az extension list -o json | ConvertFrom-Json | Where-Object { $_.name -eq 'containerapp' }
$installed = $false
if (-not $ext) {
    az extension add -n containerapp --upgrade -o none 2>$null
    $installed = ($LASTEXITCODE -eq 0)
    if (-not $installed) { $global:LASTEXITCODE = 0 }
    if ($installed) { $ext = az extension list -o json | ConvertFrom-Json | Where-Object { $_.name -eq 'containerapp' } }
}
$verdict = Get-VmfExtensionVerdict -Extension $ext -InstallSucceeded $installed
$extensionLooksBroken = $verdict.Broken
Add-Check 'az containerapp extension' $verdict.Result $verdict.Detail

# ---- the subscription -------------------------------------------------------------
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Add-Check 'Signed in' 'blocker' 'Nobody is signed in to the Azure CLI. Run: az login' }
elseif ($acct.id -ne $SubscriptionId) {
    # ID-ADDRESS-1: this switch is DELIBERATE, and it stays. The later steps -
    # the resource group, the image build, the job, the facade and dashboard
    # publishers - find their resources by name in the Azure CLI's current
    # subscription. Without the switch they would look in the wrong one. So
    # the switch is kept, and the check says it is kept after the install.
    az account set --subscription $SubscriptionId 2>$null
    if ($LASTEXITCODE -eq 0) {
        Add-Check 'Signed in' 'ok' ("switched the Azure CLI from subscription $($acct.id) to $SubscriptionId. " +
            'It stays on that subscription after the install.')
    }
    else { $global:LASTEXITCODE = 0; Add-Check 'Signed in' 'blocker' "The Azure CLI is signed in to $($acct.id), and cannot switch to $SubscriptionId. Run: az login" }
}
else { Add-Check 'Signed in' 'ok' "$($acct.user.name) on $($acct.name)" }

# ---- resource providers -----------------------------------------------------------
$providers = 'Microsoft.App', 'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.ContainerRegistry',
             'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.Resources'
foreach ($p in $providers) {
    $state = (Invoke-VmfAzCall -Step "read the provider $p" -Quiet -Command { az provider show -n $p --query registrationState -o tsv }).Output
    if ($state -eq 'Registered') { Add-Check "Provider $p" 'ok' 'registered'; continue }
    $registered = Invoke-VmfAzCall -Step "register the provider $p" -Quiet -Command { az provider register -n $p -o none }
    if ($registered.ExitCode -eq 0) { Add-Check "Provider $p" 'warn' "was '$state'; registration requested. It completes in a few minutes; the deployment waits for it." }
    elseif ($registered.Throttled) { Add-Check "Provider $p" 'unknown' "was '$state'. Azure answered Too Many Requests (HTTP 429) to each registration request. Run azd up again in a few minutes." }
    else { Add-Check "Provider $p" 'blocker' "The provider is $state, and your account cannot register it. Ask a subscription Owner to run: az provider register -n $p" }
}

# ---- the region -------------------------------------------------------------------
$appRead = Invoke-VmfAzCall -Step 'read the provider Microsoft.App' -Quiet -Command { az provider show -n Microsoft.App -o json }
$app = if ($appRead.ExitCode -eq 0) { $appRead.Output | ConvertFrom-Json } else { $null }
$envType = if ($app) { @($app.resourceTypes | Where-Object { $_.resourceType -eq 'managedEnvironments' }) | Select-Object -First 1 } else { $null }
$norm = { param($s) ([string]$s).ToLowerInvariant() -replace '\s', '' }
if ($envType) {
    $locs = @($envType.locations | ForEach-Object { & $norm $_ })
    if ($locs -contains (& $norm $Location)) { Add-Check 'Region offers Container Apps' 'ok' $Location }
    else { Add-Check 'Region offers Container Apps' 'blocker' "$Location does not offer Azure Container Apps. The install creates a Container Apps environment. $otherRegion" }
}
else { Add-Check 'Region offers Container Apps' 'unknown' 'could not read the provider (is Microsoft.App registered?)' }

$profileRead = Invoke-VmfAzCall -Step 'list the workload profiles' -Quiet -Command { az containerapp env workload-profile list-supported -l $Location -o json }
$profiles = if ($profileRead.ExitCode -eq 0) { $profileRead.Output | ConvertFrom-Json } else { $null }
if ($profiles) {
    $consumption = @($profiles | Where-Object { $_.properties.category -eq 'Consumption' -or $_.name -eq 'Consumption' })
    if ($consumption.Count) { Add-Check 'Region offers workload profiles' 'ok' "Consumption profile, $($profiles.Count) profile type(s)" }
    else { Add-Check 'Region offers workload profiles' 'blocker' "$Location does not offer the Consumption workload profile. The install creates its Container Apps environment with this profile. $otherRegion" }
}
else {
    # EXT-1. This listing is the FIRST thing that uses the containerapp
    # extension, so when the extension is incomplete this is where it shows -
    # and the operator gets a message about regions for a problem about their
    # own machine. MEASURED 2026-09-10: the extension reported no version and
    # this line said only "could not list workload profiles for centralus".
    # Say the likely cause, because the engine needs a Consumption workload
    # profile and finding that out at the deployment costs 10 to 15 minutes.
    $why = "could not list workload profiles for $Location"
    if ($extensionLooksBroken) {
        $why += '. The az containerapp extension above reports no version, which is the likely cause. ' +
                'Repair it: az extension remove -n containerapp; az extension add -n containerapp --upgrade'
    }
    else {
        $why += '. Check it by hand: az containerapp env workload-profile list-supported -l ' + $Location
    }
    Add-Check 'Region offers workload profiles' 'unknown' $why
}

# ---- quota the API will tell us ---------------------------------------------------
function Get-Usage {
    param([string]$Provider, [string]$ApiVersion)
    $usageRead = Invoke-VmfAzCall -Step "read the usage of $Provider" -Quiet -Command {
        az rest --method GET --url "https://management.azure.com/subscriptions/$SubscriptionId/providers/$Provider/locations/$Location/usages?api-version=$ApiVersion" -o json
    }
    if ($usageRead.ExitCode -ne 0) { return $null }
    $u = $usageRead.Output | ConvertFrom-Json
    return $u.value
}
$appUsage = Get-Usage -Provider 'Microsoft.App' -ApiVersion '2024-03-01'
$envs = if ($appUsage) { @($appUsage | Where-Object { $_.name.value -eq 'ManagedEnvironmentCount' }) | Select-Object -First 1 } else { $null }
if ($envs) {
    $room = [int]$envs.limit - [int]$envs.currentValue
    $said = "$($envs.currentValue) of $($envs.limit) used; the platform needs 1"
    if ($room -ge 1) { Add-Check 'Container Apps environments in the region' 'ok' $said }
    else { Add-Check 'Container Apps environments in the region' 'blocker' "The limit in $Location is $($envs.limit) Container Apps environments, and $($envs.currentValue) are in use. The install creates 1. Request a quota increase, or choose another region$retry" }
}
else { Add-Check 'Container Apps environments in the region' 'unknown' 'the usage API did not answer' }

$stUsage = Get-Usage -Provider 'Microsoft.Storage' -ApiVersion '2023-05-01'
$st = if ($stUsage) { @($stUsage | Where-Object { $_.name.value -eq 'StorageAccounts' }) | Select-Object -First 1 } else { $null }
if ($st) {
    $room = [int]$st.limit - [int]$st.currentValue
    $said = "$($st.currentValue) of $($st.limit) used; the platform needs 1"
    if ($room -ge 1) { Add-Check 'Storage accounts in the region' 'ok' $said }
    else { Add-Check 'Storage accounts in the region' 'blocker' "The limit in $Location is $($st.limit) storage accounts, and $($st.currentValue) are in use. The install creates 1. Request a quota increase, or choose another region$retry" }
}
else { Add-Check 'Storage accounts in the region' 'unknown' 'the usage API did not answer' }

# ---- App Service plans: a real quota API, under a DIFFERENT provider ----------------
# Found 2026-09-10, installing in another environment: App Service plans do
# have a quota API, and this check used the wrong one. It
# used to say the quota "surfaces only at deploy time", which was wrong.
#
# Microsoft.Web does NOT answer at providers/Microsoft.Web/locations/{location}/
# usages the way Microsoft.App and Microsoft.Storage do - MEASURED 2026-09-10,
# that path returns an error. The quota lives under the Microsoft.Quota
# provider SCOPED TO Microsoft.Web, and it takes TWO reads: /quotas carries the
# limit, /usages carries what is used.
#
# MEASURED in centralus: 67 plan SKUs reported. Y1 limit 3, B1 limit 31, F1
# limit 33. Y1's limit of 3 is low enough to stop a real install.
function Get-WebPlanQuota {
    # Strict mode is live here (the hook sets it and child scopes inherit it),
    # so read every property through PSObject rather than by name: one SKU that
    # reports a different limit shape would otherwise throw and lose the lot.
    function Get-Prop {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $found = $Object.PSObject.Properties[$Name]
        if ($found) { return $found.Value }
        return $null
    }
    $base = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/providers/Microsoft.Quota"
    $limitRead = Invoke-VmfAzCall -Step 'read the hosting plan quotas' -Quiet -Command { az rest --method GET --url "$base/quotas?api-version=2023-02-01" -o json }
    if ($limitRead.ExitCode -ne 0) { return $null }
    $limits = $limitRead.Output | ConvertFrom-Json
    $usedRead = Invoke-VmfAzCall -Step 'read the hosting plan usage' -Quiet -Command { az rest --method GET --url "$base/usages?api-version=2023-02-01" -o json }
    if ($usedRead.ExitCode -ne 0) { return $null }
    $used = $usedRead.Output | ConvertFrom-Json

    $plans = @{}
    foreach ($quota in @(Get-Prop $limits 'value')) {
        $props = Get-Prop $quota 'properties'
        if (-not (Get-Prop $props 'isQuotaApplicable')) { continue }
        $limitValue = Get-Prop (Get-Prop $props 'limit') 'value'
        if ($null -eq $limitValue) { continue }
        $plans[[string](Get-Prop $quota 'name')] = [pscustomobject]@{ Limit = [int]$limitValue; Used = 0 }
    }
    foreach ($usage in @(Get-Prop $used 'value')) {
        $name = [string](Get-Prop $usage 'name')
        if (-not $plans.ContainsKey($name)) { continue }
        $value = Get-Prop (Get-Prop (Get-Prop $usage 'properties') 'usages') 'value'
        if ($null -ne $value) { $plans[$name].Used = [int]$value }
    }
    # An EMPTY set is not a failure. MEASURED 2026-09-10 across regions: every
    # region reports one entry named '*', "Total Regional VMs", with
    # isQuotaApplicable FALSE. Some regions ALSO report 66 per-plan entries with
    # isQuotaApplicable true; others report only the '*'. In those others Azure
    # is saying that App Service plans are NOT limited per plan type there - the
    # portal greys out "Request adjustment" and says "Quota need not be
    # requested for this SKU".
    #
    # So returning $null here would report "the quota API did not answer" for a
    # region where it answered perfectly clearly. $null now means ONLY that the
    # read failed. The caller tells the two apart.
    return $plans
}

function Get-VmfHostingPlanRoom {
    <#
        One row per answer to the hosting plan question: Result ok (room),
        warn (no room: that answer cannot be chosen) or unknown (a plan type
        the region does not report). Pure: no Azure call, so it is tested.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Plans,   # sku -> { Limit; Used }
        [string[]]$Have = @(),                     # skus the resource group already holds
        [Parameter(Mandatory)][string]$Location
    )
    $label = @{ F1 = 'Free plan (F1)'; Y1 = 'Consumption plan (Y1)'; B1 = 'Basic plan (B1)' }
    $answers = [ordered]@{ Free = @('F1', 'Y1'); Basic = @('B1') }
    foreach ($choice in $answers.Keys) {
        $short = @(); $unknown = @()
        if (@($answers[$choice] | Where-Object { $Have -notcontains $_ }).Count -eq 0) {
            [pscustomobject]@{ Choice = $choice; Result = 'ok'; Detail = "The resource group already has the plans that $choice uses." }
            continue
        }
        foreach ($sku in $answers[$choice]) {
            if ($Have -contains $sku) { continue }
            if (-not $Plans.ContainsKey($sku)) { $unknown += $sku; continue }
            if ($Plans[$sku].Limit - $Plans[$sku].Used -lt 1) { $short += $sku }
        }
        $needs = ($answers[$choice] | ForEach-Object { "1 $($label[$_])" }) -join ' and '
        if ($short.Count) {
            $full = ($short | ForEach-Object { "the limit for the $($label[$_]) is $($Plans[$_].Limit), and $($Plans[$_].Used) are in use" }) -join '; '
            [pscustomobject]@{ Choice = $choice; Result = 'warn'; Detail = "$choice needs $needs. In $Location, $full. To choose $choice, request a quota increase for the $(($short | ForEach-Object { $label[$_] }) -join ' and the ')." }
        }
        elseif ($unknown.Count) {
            [pscustomobject]@{ Choice = $choice; Result = 'unknown'; Detail = "$choice needs $needs. $Location does not report the limit for the $(($unknown | ForEach-Object { $label[$_] }) -join ' or the '). If the plan cannot be created, the deployment error names it." }
        }
        else {
            [pscustomobject]@{ Choice = $choice; Result = 'ok'; Detail = "$choice needs $needs, and the quota in $Location allows them." }
        }
    }
}

$plans = Get-WebPlanQuota
if ($null -eq $plans) {
    # MEASURED 2026-09-10: 13 of 63 physical regions answer nothing here. They
    # are mostly EUAP, staging and restricted regions. So a failed read is more
    # often "App Service quota is not offered in that region" than a fault, and
    # the message should not sound like something went wrong.
    Add-Check 'App Service plans' 'unknown' "the quota API did not answer for App Service in $Location, which may not offer it. If a plan cannot be created, the deploy error names the plan type (F1, Y1 or B1)."
}
elseif ($plans.Count -eq 0) {
    # The API answered, and its answer was "nothing here is limited per plan
    # type". Say that, rather than "it did not answer".
    # There is NO SELF-SERVICE PATH in these regions: with no plan type shown,
    # there is nothing to request in the portal. Microsoft's own guidance is to
    # deploy and read the error, and to open a support ticket if one says quota
    # is needed. Say that, because the operator cannot find it from the portal.
    Add-Check 'App Service plans' 'ok' "$Location does not limit App Service plans by type. Azure reports only Total Regional VMs there, for information. If a deployment fails for quota, open an Azure support request for quota type 'Function or Web App (Windows and Linux)'."
}
else {
    # READINESS-FIX-WORDS-1 (2026-11-10): the check must not assume F1, as
    # Basic is also a choice made later. This runs BEFORE the hosting
    # plan question, and the two answers need different plans
    # (infra/platform.bicep): Free is a Free plan (F1) for the dashboard AND a
    # Consumption plan (Y1) for the service; Basic is ONE Basic plan (B1) for
    # both. So room is judged per answer, a plan the resource group already
    # holds needs no room (a second azd up), and the install stops here only
    # when NEITHER answer has room. preprovision.ps1 refuses an answer whose
    # row says it has none.
    $have = @()
    # Never list with an empty group: that lists every plan in the subscription.
    if ($ResourceGroup) {
        $planRead = Invoke-VmfAzCall -Step 'list the hosting plans' -Quiet -Command { az appservice plan list -g $ResourceGroup -o json }
        if ($planRead.ExitCode -eq 0) { $have = @($planRead.Output | ConvertFrom-Json | ForEach-Object { [string]$_.sku.name }) }
    }
    $rooms = @(Get-VmfHostingPlanRoom -Plans $plans -Have $have -Location $Location)
    foreach ($room in $rooms) { Add-Check "Hosting plan: $($room.Choice)" $room.Result $room.Detail }
    if (@($rooms | Where-Object { $_.Result -eq 'warn' }).Count -eq $rooms.Count) {
        Add-Check 'Hosting plans' 'blocker' "The quota in $Location allows neither hosting plan. Request a quota increase for a plan named above, or choose another region$retry"
    }
}

$results
