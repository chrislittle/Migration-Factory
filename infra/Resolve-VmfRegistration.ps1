. (Join-Path $PSScriptRoot 'New-VmfRunTag.ps1')
# INSTALL-THROTTLE-RETRY-2: a throttled directory read is tried again.
. (Join-Path $PSScriptRoot 'Invoke-VmfAzStep.ps1')
# How this product finds its OWN Entra registrations.
#
# Every deploy script used to ask the directory for a registration by display
# name and take the first answer:
#
#     az ad app list --display-name $ApiDisplayName --query '[0].appId' -o tsv
#
# Entra does not make a display name unique, and `--display-name` is a filter
# rather than an exact match, so that list can hold more than one application.
# Any member of the tenant may register one, with any name. `[0]` then takes
# whichever the directory listed first.
#
# THAT VALUE IS THE ONE THE FACADE TRUSTS. It becomes clientId and
# allowedAudiences in platform.bicep's authsettingsV2, and clientId on the
# dashboard page. An application somebody else owns would therefore decide who
# may call the migration control plane: the owner of an application writes its
# app roles, so they can issue themselves the Vmf.Admin role that
# Assert-VmfFacadeRole reads out of the sign-in header.
#
# The rule here:
#
#   1. the id comes from the identity deployment's own output where a script
#      has one (infra/identity-deploy.ps1 returns it; the azd hooks carry it
#      as VMF_API_APP_ID);
#   2. where a lookup is unavoidable, the display name is matched EXACTLY, in
#      PowerShell - a bracketed --query filter loses its brackets through the
#      az shim (CLAUDE.md) - and two applications with one name is a REFUSAL,
#      never a choice between them.
#
# A refusal holds up the install until a directory administrator removes the
# duplicate registration. That is the correct trade: the other answer is to
# trust an application the installer did not create.
#
# A FAILED DIRECTORY CALL IS NOT AN ABSENT OBJECT. "Nothing came back" used to
# read as "the object does not exist", and infra/identity-deploy.ps1 turns that
# into "the sign-in gate is open" and then deploys it open - the silent
# re-open GATE-1 exists to stop. So a call that FAILS throws here. Only a
# caller that has a safe answer for a failed call passes
# -AllowDirectoryFailure: tools/Deploy-VmfDashboard.ps1, which then reads the
# settings already published on the site.
#
# Dot-sourced by infra/deploy.ps1, infra/identity-deploy.ps1, the azd hooks
# (through infra/hooks/AzdHooks.ps1), tools/Deploy-VmfFacade.ps1,
# tools/Deploy-VmfDashboard.ps1 and tools/Grant-VmfAccess.ps1.

# One directory read. Returns the objects az listed, an EMPTY LIST when the
# directory holds none, or $null when the call failed and the caller said it
# can live with that. Everything else throws.
function Get-VmfDirectoryList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$What,
        [switch]$AllowDirectoryFailure
    )
    $json = $null
    $failure = ''
    $code = 0
    $stderr = ''
    # The stderr text is kept, not thrown away: the operator needs the words
    # "insufficient privileges" or "throttled", not silence.
    # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again
    # (Invoke-VmfAzCall); a read that is throttled on every try fails here as
    # any failed read does, and the message says it was a throttle.
    # Invoke-VmfAzCall leaves no exit code behind: pwsh returns $LASTEXITCODE
    # as the process exit code, so a tolerated failure would fail the caller.
    $call = $null
    try {
        $call = Invoke-VmfAzCall -Step "read $What from the directory" -Quiet -Command { az @Arguments -o json }
        $json = $call.Output
        $code = $call.ExitCode
        # An empty stream is NOTHING, not an empty string: joined, it is ''.
        $stderr = ((@($call.ErrorLines) -join [Environment]::NewLine).Trim() + (Get-VmfAzThrottleNote -Result $call)).Trim()
    }
    catch { $failure = $_.Exception.Message; $global:LASTEXITCODE = 0 }
    if (-not $failure -and $code -ne 0) { $failure = "az exit $code" }

    $items = @()
    if (-not $failure) {
        $text = ''
        $answer = $json | Out-String
        if ($answer) { $text = ([string]$answer).Trim() }
        if ($text) {
            try { $items = @($text | ConvertFrom-Json) }
            catch { $failure = "the directory answer is not readable: $text" }
        }
    }
    if ($failure) {
        $message = "Could not read $What from the directory ($failure). $stderr".Trim()
        if ($AllowDirectoryFailure) {
            Write-Warning $message
            return $null
        }
        throw ($message + " The call FAILED, so nothing here reads it as 'the object does not exist'. " +
               'Check that the signed-in account may read the directory, then run this again.')
    }
    return , @($items)
}

# The application registration with EXACTLY this display name, $null when the
# directory holds none. Two of them is a refusal.
function Get-VmfEntraApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [switch]$AllowDirectoryFailure
    )
    $items = Get-VmfDirectoryList -Arguments @('ad', 'app', 'list', '--display-name', $DisplayName) `
        -What "the '$DisplayName' application registration" -AllowDirectoryFailure:$AllowDirectoryFailure
    if ($null -eq $items) { return $null }
    $exact = @($items | Where-Object {
        $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'displayName') -and [string]$_.displayName -eq $DisplayName
    })
    if ($exact.Count -gt 1) {
        $ids = (@($exact | ForEach-Object { [string]$_.appId }) -join ', ')
        throw ("Refusing to guess: $($exact.Count) application registrations in this directory are named " +
               "'$DisplayName' (application ids: $ids). This id is the application the service checks every " +
               'sign-in against, so the wrong one gives control of this tool to whoever owns it. ' +
               'Ask a directory administrator to remove the duplicate registration, or install again with a ' +
               'different environment name, which gives the registrations a name nothing else uses.')
    }
    if ($exact.Count -eq 1) { return $exact[0] }
    return $null
}

# GRANT-NAME-1: the registrations of an install whose environment name nobody
# remembers. The names carry it - 'vmf-api-<env>' - so a tool run by hand,
# outside azd, cannot know the exact name to ask for.
#
# It REFUSES when the answer is not exactly one, for the reason the whole of
# this file exists: taking the first match is how the wrong registration comes
# to decide who may call the engine.
function Find-VmfEntraApplications {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NameStartsWith,
        [switch]$AllowDirectoryFailure
    )
    # `--display-name`, NOT `--filter "startswith(...)"`. MEASURED on a
    # Windows PC: the parentheses go to cmd, which reads them as its own
    # syntax and answers "-o was unexpected at this time". Same cause as the
    # bracket in `--query "[?...]"` that CLAUDE.md records - one character
    # class wider. az builds the filter itself from this argument, so nothing
    # cmd cares about reaches the command line.
    $items = Get-VmfDirectoryList -Arguments @('ad', 'app', 'list', '--display-name', $NameStartsWith) `
        -What "application registrations named '$NameStartsWith...'" -AllowDirectoryFailure:$AllowDirectoryFailure
    if ($null -eq $items) { return @() }
    @($items | Where-Object {
        $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'displayName') -and
        ([string]$_.displayName).StartsWith($NameStartsWith)
    } | Sort-Object displayName)
}

# The service principal of an application, found by APPLICATION ID - which is
# unique - and never by display name. $null when the directory holds none.
function Get-VmfEntraServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [switch]$AllowDirectoryFailure
    )
    # The id goes into an OData filter, so it is checked before it is sent.
    if ($AppId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw ("'$AppId' is not an application id. A service principal is found by application id, " +
               'never by name. Deploy infra/identity.bicep and use the apiAppId it reports.')
    }
    $items = Get-VmfDirectoryList -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$AppId'") `
        -What "the service principal of application $AppId" -AllowDirectoryFailure:$AllowDirectoryFailure
    if ($null -eq $items) { return $null }
    $exact = @($items | Where-Object {
        $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'appId') -and [string]$_.appId -eq $AppId
    })
    if ($exact.Count -gt 1) {
        $ids = (@($exact | ForEach-Object { [string]$_.id }) -join ', ')
        throw ("Refusing to guess: $($exact.Count) service principals in this directory report application id " +
               "$AppId (object ids: $ids). Ask a directory administrator to remove the duplicate.")
    }
    if ($exact.Count -eq 1) { return $exact[0] }
    return $null
}

# ID-ADDRESS-1: the application registration an install RECORDED, found by its
# APPLICATION ID. A display name is unique in nothing; the id is the object.
# The answer counts only while the registration still carries the name this
# install gave it: an id somebody typed by hand, or one left from another
# install, is refused rather than acted on. $null when the directory holds no
# application with this id.
function Get-VmfEntraApplicationByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$DisplayName,
        [switch]$AllowDirectoryFailure
    )
    if ($AppId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "'$AppId' is not an application id, so the registration named '$DisplayName' cannot be found by it."
    }
    # `--app-id`, not `az ad app show`: an id with no application is an EMPTY
    # LIST here, and only a real failure is a failure.
    $items = Get-VmfDirectoryList -Arguments @('ad', 'app', 'list', '--app-id', $AppId) `
        -What "the application registration with id $AppId" -AllowDirectoryFailure:$AllowDirectoryFailure
    if ($null -eq $items) { return $null }
    $exact = @($items | Where-Object {
        $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'appId') -and [string]$_.appId -eq $AppId
    })
    if ($exact.Count -eq 0) { return $null }
    $app = $exact[0]
    if ([string]$app.displayName -ne $DisplayName) {
        throw ("The application registration with id $AppId is named '$([string]$app.displayName)', not " +
               "'$DisplayName'. This install did not make it with that name, so nothing is done to it.")
    }
    return $app
}

# INSTALL-ADOPT-OWNER-1: AN INSTALL NEVER TAKES OVER A REGISTRATION IT DID NOT MAKE.
#
# identity.bicep UPSERTS each registration by its uniqueName. A first install
# with no recorded key used to find the API registration by display name and,
# on one match, record an EMPTY key - so the uniqueName was the display name,
# 'vmf-api-<environment>', which anybody can guess. A tenant member who made a
# registration with that name first (the Entra default lets any user register
# applications) then owned the application the service trusts, and the owner of
# an application writes its app roles: they could give themselves Vmf.Admin,
# whose id is public in identity.bicep.
#
# NOTHING THE DIRECTORY SHOWS PROVES WHO MADE A REGISTRATION. The first fix
# adopted one when the installer was its one owner and its uniqueName carried a
# key; the review showed both are the maker's to set - make it, give yourself
# Vmf.Admin, make the installer the one owner, leave. So:
#   - a recorded key is used as it is, and nothing is read: the uniqueName
#     carries a key only this environment holds;
#   - no key and no registration with either name -> a NEW random key;
#   - no key and a registration with either name -> STOP, before the template
#     runs. Not adoption, and not a new key either: that would make a second
#     registration with the same display name, which every later lookup
#     refuses (Get-VmfEntraApplication).
# A pair kept by 'azd down' therefore stops the next install with that
# environment name. It did not work before this change either: postdown clears
# the key, and the empty key made a second registration beside each kept one.

# A new registration key: six lower-case letters and digits from a
# cryptographic random source, so nobody can make the uniqueName first.
function New-VmfRegistrationKey {
    [CmdletBinding()]
    param()
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
    -join ((1..6) | ForEach-Object { $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
}

# The registration key an install uses. Returns Key and Source ('recorded' or
# 'new'), or stops.
function Resolve-VmfRegistrationKey {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$RecordedKey,
        [Parameter(Mandatory)][string]$ApiDisplayName,
        [Parameter(Mandatory)][string]$DashboardDisplayName
    )
    if ($RecordedKey) { return [pscustomobject]@{ Key = $RecordedKey; Source = 'recorded' } }

    $found = @(foreach ($wanted in @($ApiDisplayName, $DashboardDisplayName)) {
        $app = Get-VmfEntraApplication -DisplayName $wanted
        if ($app) { $app }
    })
    if ($found.Count) {
        $list = (@($found | ForEach-Object { "'$([string]$_.displayName)' (application ID $([string]$_.appId))" }) -join ', ')
        throw ("The install stopped. These registration names are already in use in this directory: $list. " +
               'The install does not use an application registration that it did not make in this environment. ' +
               'Ask a directory administrator to remove these registrations. Or use a different environment name with azd env new.')
    }
    [pscustomobject]@{ Key = (New-VmfRegistrationKey); Source = 'new' }
}

# INSTALL-PURGE-DELETED-1: THE INSTALL PERMANENTLY DELETES ONLY A DELETED
# REGISTRATION THAT HOLDS THE UNIQUE NAME IT IS ABOUT TO CREATE.
#
# Entra keeps a deleted application, and its uniqueName, for 30 days, and
# identity.bicep upserts by uniqueName - so a deleted registration with the
# uniqueName this install creates makes the deployment fail on a message about
# appId (MEASURED 2026-09-09). The same measurement proved that ONLY the
# uniqueName collides: a deleted registration with the same display name and
# another uniqueName blocks nothing.
#
# The purge used to match by DISPLAY NAME, so it also permanently deleted a
# deleted registration with the name 'vmf-api-<env>' that somebody else made
# and might want back (MEASURED 2026-11-22). Since INSTALL-ADOPT-OWNER-1 the
# uniqueName is '<display name>-<key>', so:
#   - a NEW key: no registration ever held that uniqueName, so no deleted one
#     can, and the directory is not read (-NewKey);
#   - a RECORDED key: a deleted registration blocks the install only if its
#     uniqueName is EXACTLY '<display name>-<key>' - one this environment made,
#     deleted by hand while the key stayed recorded. Only that one is purged,
#     by its object ID, and the output names it and says why.
# A directory call that fails STOPS the install. It is never read as "no
# deleted registration", which is the answer that lets a purge be skipped
# silently or done on a guess.

# The uniqueName identity.bicep gives a registration. Keep the two in step
# (InstallPurgeDeleted.Tests.ps1 reads the template).
function Get-VmfRegistrationUniqueName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$RegistrationKey
    )
    "$DisplayName-$RegistrationKey"
}

# Every deleted application registration in the directory, all pages. Stops
# on any failure.
function Get-VmfDeletedApplications {
    [CmdletBinding()]
    param([ValidateRange(1, 1000)][int]$MaxPages = 50)
    $graphRoot = 'https://graph.microsoft.com/'
    $what = 'the deleted application registrations'
    # The first page is the call measured on 2026-11-22, with uniqueName added
    # to the fields it asks for.
    $callArgs = @('rest', '--method', 'GET', '--url',
        'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?$select=id,displayName,uniqueName')
    $all = [System.Collections.Generic.List[object]]::new()
    for ($pagesRead = 0; $callArgs; $pagesRead++) {
        if ($pagesRead -ge $MaxPages) {
            throw ("The install stopped. The list of $what fills more than $MaxPages pages, so the install cannot make sure " +
                   'that no deleted registration holds the unique name it creates.')
        }
        $answer = Get-VmfDirectoryList -Arguments $callArgs -What $what
        $page = @($answer) | Select-Object -First 1
        if ($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'value') {
            throw "The install stopped. Could not read $what from the directory (the answer holds no list of them)."
        }
        foreach ($item in @($page.value)) { if ($null -ne $item) { $all.Add($item) } }

        $callArgs = $null
        $next = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { [string]$page.'@odata.nextLink' } else { '' }
        if (-not $next) { break }
        if (-not $next.StartsWith($graphRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The install stopped. The next page of $what has an address that does not start with $graphRoot, so the install does not read it."
        }
        # The next page's address holds '&', which az.cmd reads as a command
        # separator (CLAUDE.md). So its query goes to --url-parameters, one
        # KEY=VALUE per argument, and no argument holds '&'.
        $parts = $next.Split('?', 2)
        $nextArgs = @('rest', '--method', 'GET', '--url', $parts[0])
        if ($parts.Count -gt 1 -and $parts[1]) {
            $nextArgs += '--url-parameters'
            foreach ($pair in $parts[1].Split('&')) {
                if (-not $pair) { continue }
                $decoded = [System.Uri]::UnescapeDataString($pair)
                if ($decoded -match '[&|<>^"%\s]') {
                    throw ("The install stopped. The next page of $what has an address that holds a character the Azure CLI " +
                           'on Windows cannot pass, so the install does not read it.')
                }
                $nextArgs += $decoded
            }
        }
        $callArgs = $nextArgs
    }
    return , $all.ToArray()
}

function Clear-VmfDeletedRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApiDisplayName,
        [Parameter(Mandatory)][string]$DashboardDisplayName,
        [Parameter(Mandatory)][string]$RegistrationKey,
        # The application IDs the environment recorded before this run
        # (VMF_API_APP_ID, VMF_DASHBOARD_APP_ID). Empty when none is recorded.
        [Parameter()][AllowEmptyString()][AllowNull()][string]$RecordedApiAppId = '',
        [Parameter()][AllowEmptyString()][AllowNull()][string]$RecordedDashboardAppId = '',
        [switch]$NewKey
    )
    if ($NewKey) { return }
    $deleted = $null
    foreach ($want in @(@($ApiDisplayName, $RecordedApiAppId), @($DashboardDisplayName, $RecordedDashboardAppId))) {
        $displayName = [string]$want[0]
        $recordedAppId = [string]$want[1]
        $uniqueName = Get-VmfRegistrationUniqueName -DisplayName $displayName -RegistrationKey $RegistrationKey
        # THE ORDINARY UPDATE. The registration this environment recorded is
        # still there, found by its APPLICATION ID, so it still holds the
        # uniqueName and no deleted registration can. Nothing more is read:
        # this does not depend on uniqueName being in the az answer.
        if ($recordedAppId) {
            if ($recordedAppId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                throw "The install stopped. The recorded application ID '$recordedAppId' of '$displayName' is not an application ID."
            }
            $byId = Get-VmfDirectoryList -Arguments @('ad', 'app', 'list', '--app-id', $recordedAppId) `
                -What "the application registration with id $recordedAppId"
            $present = @($byId | Where-Object {
                $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'appId') -and [string]$_.appId -eq $recordedAppId
            })
            if ($present.Count) { continue }
        }
        # No recorded ID, or the registration with it is gone (deleted in the
        # portal). A live registration that holds this uniqueName means no
        # deleted one can.
        $live = Get-VmfDirectoryList -Arguments @('ad', 'app', 'list', '--display-name', $displayName) `
            -What "the '$displayName' application registration"
        $holder = @($live | Where-Object {
            $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'uniqueName') -and [string]$_.uniqueName -eq $uniqueName
        })
        if ($holder.Count) { continue }

        if ($null -eq $deleted) { $deleted = Get-VmfDeletedApplications }
        # Exact, never a prefix and never the display name: a purge cannot be
        # undone. (-eq ignores case, as Entra does for a uniqueName; the key in
        # it is random, so the case does not make the match less exact.)
        $hits = @($deleted | Where-Object {
            $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'uniqueName') -and [string]$_.uniqueName -eq $uniqueName
        })
        foreach ($tomb in $hits) {
            $purgeObjectId = [string]$tomb.id
            # The id goes into a URL, so it is checked before it is sent.
            if ($purgeObjectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                throw "The install stopped. The deleted registration with the unique name $uniqueName has '$purgeObjectId', which is not an object ID."
            }
            Write-Host ("   removing the deleted registration '$([string]$tomb.displayName)' (object ID $purgeObjectId) permanently. " +
                        "It holds the unique name $uniqueName, which this install gives its registration. Entra keeps that name 30 days.")
            $purge = Invoke-VmfAzCall -Step "remove the deleted registration $uniqueName permanently" -Quiet -Command {
                az rest --method DELETE --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$purgeObjectId" --output none
            }
            if ($purge.ExitCode -ne 0) {
                $detail = ((@($purge.ErrorLines) -join [Environment]::NewLine).Trim() + (Get-VmfAzThrottleNote -Result $purge)).Trim()
                throw @"
The install stopped. The deleted registration with the unique name
$uniqueName (object ID $purgeObjectId) holds the name this install
creates, and this account may not remove it permanently. Entra holds the name
for 30 days, and the install cannot create the registration until it is gone.
$detail

Ask a directory administrator to run:

  az rest --method DELETE --url https://graph.microsoft.com/v1.0/directory/deletedItems/$purgeObjectId

Or install with a different environment name, which gives every registration a
different name.
"@
            }
        }
    }
}
function Select-VmfOneByName {
    <#
    .SYNOPSIS
        ID-ADDRESS-1: ONE resource of a kind in a resource group, by its exact
        name, or by the product's name prefix when no name is given.
    .DESCRIPTION
        The same rule as the registrations above. A prefix that matches two -
        two installs in one resource group, the old facade a hosting-plan
        change leaves behind, or somebody else's resource named alike - is a
        refusal that names both, never the first one listed. An exact name
        never falls back to the prefix. None is $null.
    .PARAMETER Use
        What the caller does with it, for the refusal: "grant", "check".
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Items,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Exact,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$NameParameter,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter()][string]$Use = 'use'
    )
    $all = @($Items | Where-Object { $null -ne $_ })
    $hits = if ($Exact) { @($all | Where-Object { [string]$_.name -eq $Exact }) }
            else { @($all | Where-Object { [string]$_.name -like "$Prefix*" }) }
    if ($hits.Count -gt 1) {
        throw ("Resource group '$ResourceGroup' holds $($hits.Count) $What whose names start '$Prefix': " +
               "$(($hits | ForEach-Object { $_.name }) -join ', '). The product does not guess which one to $Use. " +
               "Give the name of the correct one with -$NameParameter.")
    }
    $hits | Select-Object -First 1
}
