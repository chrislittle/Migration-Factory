<#
.SYNOPSIS
    HOST-1: publish the Migration Dashboard's CONTENT to the App Service the
    platform template creates for it.
.DESCRIPTION
    This script used to do far more: enable static-website hosting on the
    storage account, create the Entra app registration, set its redirect URIs,
    write the admin consent grant and set blob CORS. All of that now belongs
    to templates - infra/platform.bicep owns the host and the CORS rules,
    infra/identity.bicep owns the registration - so doing it here as well
    would fight them. In particular this script used to PATCH the redirect
    URIs to the storage endpoint, which would silently undo identity.bicep.

    What is left is what a template genuinely cannot do: write the config the
    page needs, and push the files.

    WHY IT MOVED OFF STORAGE: a storage static website cannot serve response
    headers at all. The dashboard holds an access token in browser memory and
    was being served with no Content-Security-Policy. App Service can, and
    web.config ships that policy with the content.

    The dashboard mutates nothing by itself: viewers authenticate as
    themselves and see only what their own RBAC and app roles allow.
.EXAMPLE
    ./tools/Deploy-VmfDashboard.ps1 -StorageAccountName <vmfstate...> -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$AppDisplayName = 'vmf-dashboard',
    [string]$ApiDisplayName = 'vmf-api',
    [string]$SiteName = "vmf-dash-$($StorageAccountName -replace '^vmfstate', '')",
    [int]$RefreshSeconds = 15,
    # ID-ADDRESS-1: the EXACT name of the facade the page calls. The install
    # passes it: a hosting-plan change leaves the old facade in the resource
    # group, and the name prefix below matches both.
    [string]$FacadeName = ''
)

$ErrorActionPreference = 'Stop'
$dashboardDir = Join-Path $PSScriptRoot '..' 'src' 'dashboard'
# The one way this product finds its own registrations: an exact name, and a
# refusal when two carry it. The page's clientId is what a browser signs in
# against, so the first answer to a name lookup is not good enough.
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRegistration.ps1')
. (Join-Path $PSScriptRoot '..' 'infra' 'New-VmfRunTag.ps1')
# CSP-AZUREWEBSITES-1: the web.config this publish ships names the service the
# page calls, not every site on azurewebsites.net.
. (Join-Path $PSScriptRoot '..' 'infra' 'Get-VmfDashboardWebConfig.ps1')

# INSTALL-THROTTLE-RETRY-1: every az step runs through Invoke-VmfAzStep, which
# tries a throttled answer (HTTP 429) again and stops on any other failure with
# "Deploy step failed (az exit N): <step>" - the words Assert-AzOk used to say.
. (Join-Path $PSScriptRoot '..' 'infra' 'Invoke-VmfAzStep.ps1')

Write-Host "0/2 checking the platform and its registration exist..."
$siteExists = Invoke-VmfAzStep -Step "read the dashboard host $SiteName" -AllowFailure -Command {
    az webapp show -g $ResourceGroup -n $SiteName --query name -o tsv
}
if (-not $siteExists) {
    throw "The dashboard host '$SiteName' does not exist. Deploy the platform first: az deployment group create -g $ResourceGroup --template-file infra/platform.bicep --parameters baseSuffix=<suffix> ..."
}
# CD-1: the page's sign-in configuration comes from the Entra registrations,
# so unlike the facade this deploy genuinely needs to know them. A PIPELINE has
# no directory permission and should not be given one just to publish a page -
# so when the directory cannot be read, the values are taken from the config
# ALREADY DEPLOYED on the site. They only change when identity.bicep is
# redeployed, which is a person's act, and that person can read the directory.
# The "is it missing, or can I just not see it" distinction matters here: a
# pipeline gets an empty answer for the second reason, and the fallback below
# covers it. The refusal for a genuinely missing registration is down there
# too, after both sources have been tried.
# A probe that is ALLOWED to fail must not leave its exit code behind: pwsh
# returns $LASTEXITCODE as the process exit code, so a deliberate "is anybody
# signed in?" failure made a completely successful publish exit 1 - and the
# step failed after printing every success message it has. Found by the
# pipeline's fourth run.
#
# ONE reading of the registration, matched EXACTLY by name. It used to be two
# lookups that each took the FIRST answer, and a display name is not unique in
# Entra: the page's clientId - the application a browser signs in against -
# could have been a registration any member of the tenant had made with the
# same name. -AllowDirectoryFailure covers the pipeline case above: a call
# that FAILS gives $null here and the deployed settings are read instead. Two
# registrations with one name is still a refusal - there is no safe fallback
# from an answer that names the wrong application.
$dashApp = Get-VmfEntraApplication -DisplayName $AppDisplayName -AllowDirectoryFailure
$appId = if ($dashApp) { [string]$dashApp.appId } else { '' }
$siteUrl = "https://$SiteName.azurewebsites.net"
Write-Host '1/2 write the page configuration...'
$tenantId = az account show --query tenantId -o tsv
# CLAUDE.md: a JMESPath FILTER passed through the az CMD shim loses its
# brackets, and what comes back is an error string a script then treats as a
# name. This one has been sitting here working by luck. Filter in PowerShell.
# ID-ADDRESS-1 part 3: ONE facade. With no -FacadeName, two whose names start
# alike are refused with both names (Select-VmfOneByName), never the first one
# listed. A listing that fails is said, not read as "no facade".
$facadeJson = Invoke-VmfAzStep -Step "list the function apps in '$ResourceGroup'" -Command { az functionapp list -g $ResourceGroup -o json }
$facadeApps = @($facadeJson | ConvertFrom-Json)
$facadeSite = Select-VmfOneByName -Items $facadeApps -Exact $FacadeName -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' `
    -ResourceGroup $ResourceGroup -Use 'publish the dashboard for'
if ($FacadeName -and -not $facadeSite) { throw "The facade '$FacadeName' is not in resource group '$ResourceGroup'." }
$facadeName = $facadeSite.name

# ACCESS-HALF-1: the web service's OWN identity, which the Access page needs
# and never had.
#
# THE PRODUCT HAS TWO IDENTITIES THAT NEED REACH OVER A CUSTOMER'S MACHINES.
# The engine changes them; the web service READS them, and every list the
# dashboard shows comes from the web service. The page could only ever grant
# the engine, because this config named only the engine - so a scope granted
# in the app left every list in the product blank while the page reported the
# subscription as covered. MEASURED on a lab install 2026-09-22: the
# engine held the subscription role, the web service held no VMF role at all,
# and no role assignment had changed there in fourteen days.
#
# `tools/Grant-VmfAccess.ps1` has always granted both, which is why an install
# is fine and only the app was wrong.
$webServicePrincipalId = if ($facadeSite) { [string]$facadeSite.identity.principalId } else { '' }
if (-not $webServicePrincipalId) {
    Write-Warning ("No system-assigned identity on the web service in this resource group - " +
        "the Admin page will be able to grant the engine access to machines but NOT the web service, " +
        "so the lists in the product would stay empty. Re-run the install, or use tools/Grant-VmfAccess.ps1.")
}
# The same exact reading for the service's own registration: this id is the
# audience the page asks Entra for a token for.
$apiApp = Get-VmfEntraApplication -DisplayName $ApiDisplayName -AllowDirectoryFailure
$apiAppId = if ($apiApp) { [string]$apiApp.appId } else { '' }
if (-not $appId -or -not $apiAppId) {
    $siteName = "vmf-dash-$($StorageAccountName -replace '^vmfstate', '')"
    Write-Host '   directory not readable - reading sign-in settings from the deployed page...'
    try {
        $tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
        $live = Invoke-RestMethod -Uri "https://$siteName.scm.azurewebsites.net/api/vfs/site/wwwroot/dashboard.config.json" `
            -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 60
        if (-not $appId) { $appId = [string]$live.clientId }
        if (-not $apiAppId) { $apiAppId = [string]$live.apiAppId }
    }
    catch {
        throw ("Cannot read the Entra registrations, and cannot read the settings already on the site " +
               "($($_.Exception.Message)). Publishing now would write a page nobody can sign in to. Run this " +
               'once as a person who can read the directory, or deploy infra/identity.bicep first.')
    }
    if (-not $appId) {
        throw ("The '$AppDisplayName' registration does not exist and the deployed page does not name one either. " +
               "Deploy it first: az deployment group create -g $ResourceGroup --template-file infra/identity.bicep " +
               "--parameters dashboardOrigin=$siteUrl")
    }
}
# SCOPE-ADD-1. Filtered in PowerShell rather than with --query: the az CMD shim
# eats a JMESPath filter's brackets, and what comes back is an error string a
# script then happily treats as a value (CLAUDE.md, nine orphaned disks).
# Named EXACTLY, the way SiteName above already is - not by prefix. During the
# suffix reconciliation both vmf-engine-mi and vmf-engine-mi-examplesuffix existed, a
# prefix match found both, and the page was published naming the WRONG identity:
# the access console would then have granted a customer's subscription to an
# identity nothing runs as.
$engineMiName = "vmf-engine-mi-$($StorageAccountName -replace '^vmfstate', '')"
$engineMi = @(Invoke-VmfAzStep -Step 'list the managed identities' -AllowFailure -Command { az identity list -g $ResourceGroup -o json } |
    ConvertFrom-Json | Where-Object { $_.name -eq $engineMiName }) | Select-Object -First 1
$enginePrincipalId = if ($engineMi) { $engineMi.principalId } else { '' }
if (-not $enginePrincipalId) {
    Write-Warning "No identity named '$engineMiName' in this resource group - the access console will not be able to grant it access to anything."
}
# VERSION-1: the build this page is, written into the page so the bar can
# show it and a bug report can say it. From the module - the one reading of
# the manifest and the stamp - never a second copy of that logic here.
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
$build = Get-VmfVersion
Write-Host "   version $($build.version)$(if ($build.warning) { ' - ' + $build.warning })"
# ROLES-1 part 2: resolve the two custom roles through the one helper that
# knows how to find them - name AND defined in this subscription - so this
# script cannot disagree with the install about which pair is ours.
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRoleScopes.ps1')
$installSub = az account show --query id -o tsv
$vmfRoles = Get-VmfSubscriptionRoles -SubscriptionId $installSub
$assessRoleId = if ($vmfRoles.Assess) { $vmfRoles.Assess.id } else { '' }
$migrateRoleId = if ($vmfRoles.Execute) { $vmfRoles.Execute.id } else { '' }
if (-not $assessRoleId -or -not $migrateRoleId) {
    Write-Warning ('The two custom roles were not found in subscription ' + $installSub +
        '. The Admin page will not be able to grant access to machines until the install creates them.')
}
else { Write-Host "   custom roles found: assess and migrate" }

# CSP-AZUREWEBSITES-1: ONE service address, set once. The page configuration
# names it as apiUrl, and the content security policy names its origin - so
# the policy admits exactly the service the page sends its token to.
$serviceApiUrl = if ($facadeName -and $apiAppId) { "https://$facadeName.azurewebsites.net/api" } else { '' }
$configPath = Join-Path $dashboardDir 'dashboard.config.json'
@{
    tenantId       = $tenantId
    clientId       = $appId
    # STORE-READ-1: `storageAccount`, `storageAccountId` and `container` were
    # written here and are gone. No page reads the store directly any more, so
    # the browser has no use for the account's name, its ARM id or its
    # container - the service holds all three. A config field nothing reads is
    # a claim that something still works this way.
    refreshSeconds = $RefreshSeconds
    apiUrl         = $serviceApiUrl
    apiAppId       = if ($facadeName -and $apiAppId) { $apiAppId } else { '' }
    # INSTALL-0: `scopeRg` used to be written here from a -DefaultScopeRg that
    # defaulted to OUR lab's resource group. No page ever read it. Gone.
    # SCOPE-ADD-1: the identity the access console grants access TO. Read from
    # the deployment rather than named here, so it follows the resource group
    # it actually lives in.
    enginePrincipalId = $enginePrincipalId
    # ACCESS-HALF-1: the OTHER half. The page grants both or says it cannot.
    webServicePrincipalId = $webServicePrincipalId
    # ROLES-1 part 2: the two custom role definitions, BY ID.
    #
    # The page used to find them by name prefix at the scope being granted.
    # That also finds roles inherited from a management group above, and roles
    # another install made, and there is no defined order to choose between
    # them - so it could grant the wrong definition and say nothing. Ids are
    # exact, and Microsoft's own advice is to use them rather than names.
    #
    # Read from the subscription the roles are DEFINED in, which is the one
    # this install lives in. They exist by now: the install hook creates them
    # before the dashboard is published.
    assessRoleId  = $assessRoleId
    migrateRoleId = $migrateRoleId
    # VERSION-1: which build this page is. Shown on the bar; carried in bug
    # reports and support bundles.
    version   = $build.version
    commit    = $build.commit
    builtUtc  = $build.builtUtc
} | ConvertTo-Json | Set-Content $configPath -Encoding utf8NoBOM

Write-Host '2/2 package + zip deploy the dashboard...'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dash-pkg-$(New-VmfRunTag)"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    # web.config carries the response headers that were impossible on storage.
    # help.js is SHARED by every page - leaving it out of this list would not
    # just remove the help option, it would break each page's script at the
    # point it installs it. Found by deploying without it.
    # CSP-INLINE-1: each page's script is the .js file with the page's name, and
    # the policy refuses inline script, so a page without its file has no
    # script at all.
    foreach ($f in 'index.html', 'migrations.html', 'access.html', 'assessments.html', 'projects.html', 'reports.html', 'waves.html', 'wizard.html',
                   'index.js', 'migrations.js', 'access.js', 'assessments.js', 'projects.js', 'reports.js', 'waves.js', 'wizard.js',
                   'app.css', 'theme.js', 'help.js', 'assessment-report.js',
                   'msal-browser.min.js', 'dashboard.config.json', 'web.config', 'logo.svg', 'mark.svg') {
        $src = Join-Path $dashboardDir $f
        # Silently skipping a listed file is how help.js shipped missing once
        # already: the deploy succeeded, said so, and every page was broken.
        # A file named here and absent is a mistake, not an option.
        #
        # The OTHER direction is guarded by a test rather than here: a page that
        # exists and is NOT on this list ships invisible, which is how a new page
        # gets built, tested and then never deployed. See DashboardMarkup.Tests.
        if (-not (Test-Path $src)) {
            throw "Refusing to publish: '$f' is on the deploy list and is not in $dashboardDir. Either it was renamed and this list was not, or the working tree is incomplete."
        }
        Copy-Item $src (Join-Path $stage $f)
    }
    # CSP-AZUREWEBSITES-1: the template's policy carries a marker where the
    # service goes. Write the origin of the address the page configuration
    # names, or no service when none is deployed. The function refuses a
    # template with no marker, or with a wildcard host.
    $webConfigTemplate = [System.IO.File]::ReadAllText((Join-Path $stage 'web.config'))
    $publishedWebConfig = Get-VmfDashboardWebConfig -Template $webConfigTemplate -ApiUrl $serviceApiUrl
    Set-Content -LiteralPath (Join-Path $stage 'web.config') -Value $publishedWebConfig -NoNewline -Encoding utf8NoBOM
    Write-Host "   content security policy names the service: $(if ($serviceApiUrl) { ([uri]$serviceApiUrl).Host } else { 'none deployed' })"
    # RETRY-1: the stop-reason guidance the page shows is the SAME file the
    # engine writes codes against. Copied, never duplicated - a second copy
    # in src/dashboard would drift the moment a new stop was added, and the
    # page would confidently explain the wrong thing.
    Copy-Item (Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') `
        (Join-Path $stage 'stop-reasons.json')
    # ASSESS-PAGE-1: the same rule for what an assessment's blockers MEAN. Two
    # pages used to carry their own partial copies and both were missing five of
    # the seven blockers, so a machine held back for one of them showed the
    # operator a raw code. Copied, never duplicated.
    Copy-Item (Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') `
        (Join-Path $stage 'assessment-reasons.json')
    # DOC-3: the operator guide travels the same way: the documentation in
    # GitHub is also the documentation in the app. The tension is real - docs in the
    # repo are invisible to somebody mid-run, and docs copied into the app drift
    # from the repo. This is the third use of the answer already proven here:
    # ONE file, copied at deploy, with a test that fails if a second copy
    # appears under src/dashboard.
    Copy-Item (Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'data' 'operator-guide.json') `
        (Join-Path $stage 'operator-guide.json')
    # DOC-4: the manual, whole, under manual/: comprehensive documentation in
    # GitHub that the app uses as well. One
    # source (docs/manual), copied at deploy like the three files above; the
    # Get help menu opens it at a relative address, so it needs nothing
    # outside the dashboard's own origin.
    $manual = Join-Path $PSScriptRoot '..' 'docs' 'manual'
    if (-not (Test-Path (Join-Path $manual 'index.html'))) { throw "Refusing to publish: the manual is missing from $manual." }
    Copy-Item $manual (Join-Path $stage 'manual') -Recurse
    # TEMP-LOCK-1: the name is unique to this RUN, so a leftover from a failed
    # publish can never be reopened - and it is removed in the `finally` below,
    # so leftovers stop being made. It used to be removed only HERE, on the
    # success path, and every failed publish left one in the temp folder.
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dash-$(New-VmfRunTag).zip"

    # And wait, if something is holding it anyway. WHAT holds it is not known -
    # by the time this was looked into the process was gone and the file was
    # gone, and the two obvious theories were both checked on the machine that
    # failed and were both wrong. It was the personal machine rather than the
    # managed one, and Defender real-time protection is off there.
    #
    # A short wait costs nothing and covers a transient holder of any kind. It
    # is not a substitute for the two real fixes above, and it gives up rather
    # than hanging: an installer that waits for ever is worse than one that
    # says which file it could not write.
    $zipped = $false
    for ($try = 1; $try -le 5 -and -not $zipped; $try++) {
        try {
            Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -ErrorAction Stop
            $zipped = $true
        }
        catch {
            if ($try -eq 5) {
                throw ("Could not package the dashboard into '$zip': $($_.Exception.Message) " +
                    'Something else has the file open. Close anything reading the temp folder, ' +
                    'or restart this machine, and run the install again.')
            }
            Start-Sleep -Milliseconds (200 * $try)
        }
    }

    Invoke-VmfAzStep -Step 'zip deploy the dashboard' -Command {
        az webapp deploy -g $ResourceGroup -n $SiteName --src-path $zip --type zip --only-show-errors --output none
    } | Out-Null
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
    if ($zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}

# STORE-READ-1: the operator's Storage Blob Data Reader grant was made here and
# is gone. The person who runs the deploy does not read the store - the service
# does, with its own identity - so there is nobody to bootstrap. The grant that
# matters now is made in infra/platform.bicep, to the facade.

# DARK-1: fetch the stylesheet back before saying the deploy worked.
#
# Every page now carries markup and no appearance of its own, so app.css
# failing to serve does not degrade the look - it removes it, on all eight
# pages at once, and the deploy would still report success. That is the same
# shape as the .json MIME map that once made the dashboard unable to read its
# own config: served by IIS or not served at all, and nothing named the file.
#
# Sign-in enforcement sits in front of the site, so a redirect to login is a
# PASS here - it proves the site is up and routing. Only a 404 is a failure.
Write-Host ''
Write-Host '   checking the published stylesheet answers...'
try {
    $css = Invoke-WebRequest "$siteUrl/app.css" -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
    if ($css.StatusCode -eq 404) {
        throw "app.css returned 404. The pages are deployed with no appearance at all. Check the deploy list and the staticContent map in web.config."
    }
    Write-Host "   app.css: HTTP $($css.StatusCode)"
}
catch [System.Net.Http.HttpRequestException] {
    # A redirect to Entra with -MaximumRedirection 0 lands here on some hosts.
    Write-Host '   app.css: behind sign-in (the site answered) - ok'
}

Write-Host ''
Write-Host "Migration Dashboard published: $siteUrl" -ForegroundColor Green
Write-Host "Hosting, CORS and sign-in enforcement come from infra/platform.bicep; the registration from infra/identity.bicep."
Write-Host 'Viewers need: Entra sign-in and a role in the app. Give roles on the Admin page.'
