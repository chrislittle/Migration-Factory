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
