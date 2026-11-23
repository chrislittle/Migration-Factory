# INSTALL-1: what every hook needs, once. Dot-sourced by preprovision.ps1,
# postprovision.ps1 and predown.ps1.
#
# azd preloads its environment (.azure/<env>/.env) into the hook's process
# environment, so a value is read as $env:NAME. Writing one back is
# `azd env set`, which is what makes it survive to the next command and to
# main.parameters.json.
Set-StrictMode -Version Latest

# How a hook finds an Entra registration: by an EXACT name, refusing when two
# carry it, and never by taking the first answer of a display-name lookup.
. (Join-Path $PSScriptRoot '..' 'Resolve-VmfRegistration.ps1')

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

function Set-AzdValue {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not record $Name in the azd environment" }
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

# INSTALL-THROTTLE-RETRY-1: every az step of a hook runs through
# Invoke-VmfAzStep, which tries a throttled answer (HTTP 429) again and stops
# on any other failure, naming the step. Assert-AzOk, which only read the exit
# code after the call, is gone.
. (Join-Path $PSScriptRoot '..' 'Invoke-VmfAzStep.ps1')

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

# DISCLAIMER-1: the person who installs the product reads the full notice
# before anything is deployed. The words are the product's one copy, in the
# module's data folder - the report reads the same file - so the install never
# says something the app does not. It takes no switch: nothing can hide it.
function Show-VmfDisclaimer {
    [CmdletBinding()]
    param()
    $file = Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'disclaimer.json'
    $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Write-Step ([string]$doc.title)
    foreach ($para in @($doc.paragraphs)) {
        Write-Host ''
        Write-Host "   $para"
    }
}

# Can this hook ask a person anything? One place answers, so a test can say
# "no console" without changing the process it runs in.
function Test-VmfConsole {
    [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

# READINESS-TABLE-WIDTH-1 (2026-11-11, from a screenshot): the text wrapped
# badly in smaller windows. The readiness table was laid out 160
# characters wide whatever the window, so a narrower window wrapped each long
# line a second time, across the columns. Lay it out to the window's own width,
# one column less so a full line does not wrap by itself. When the width
# cannot be read, or is under 60 columns, 160 as before. (MEASURED: pwsh with
# no console still reports 120, so an unattended run gets 119 - harmless, the
# table is only printed.)
function Get-VmfConsoleWidth {
    param([object]$Reported = $(try { $Host.UI.RawUI.WindowSize.Width } catch { $null }))
    $width = 0
    if ([int]::TryParse([string]$Reported, [ref]$width) -and $width -ge 60) { return $width - 1 }
    return 160
}

# A choice, asked ONCE and recorded. A value already in the environment is
# never asked again, so a re-run is silent and a pipeline presets its answers.
# With no console (a pipeline that preset nothing), the default is taken and
# said - never a hang on a prompt nobody can answer.
function Read-VmfChoice {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Options,   # 'value|label'
        [Parameter(Mandatory)][string]$Default,
        # INSTALL-PROMPT-1: a question that is its own whole explanation
        # explains nothing. An option can say what it does in a few words and
        # still hide WHY it is being asked.
        [string[]]$Help = @(),
        # INSTALL-CONSENT-PUSH-1: the answer an install with no console takes,
        # when it is not the answer a person gets by pressing Enter. The consent
        # question stops by default for a person, and an unattended install
        # must continue (FIRSTSCOPE-1: push, never block).
        [string]$NoConsoleDefault = ''
    )
    $have = Get-AzdValue -Name $Name
    if ($have) { return $have }
    $values = @($Options | ForEach-Object { ($_ -split '\|', 2)[0] })
    if (-not (Test-VmfConsole)) {
        # PIPELINE-LATER-1 removed -Consequential, which refused the default
        # here. Its one caller was the update question: taking 'person'
        # unattended disowned a pipeline. No choice left has such a cost.
        if ($NoConsoleDefault) {
            Write-Host "   $Question -> $NoConsoleDefault (no console)"
            Set-AzdValue -Name $Name -Value $NoConsoleDefault
            return $NoConsoleDefault
        }
        Write-Host "   $Question -> $Default (no console; the default is taken)"
        Set-AzdValue -Name $Name -Value $Default
        return $Default
    }
    Write-Host ''
    # After every early return, so a recorded answer and an unattended install
    # print nothing.
    foreach ($line in $Help) { Write-Host "  $line" }
    if ($Help.Count) { Write-Host '' }
    Write-Host $Question
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $parts = $Options[$i] -split '\|', 2
        $mark = if ($parts[0] -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $parts[1], $mark)
    }
    $pick = $Default
    while ($true) {
        $answer = Read-Host 'Type the number, or press Enter for the default'
        if ([string]::IsNullOrWhiteSpace($answer)) { break }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Options.Count) { $pick = $values[[int]$answer - 1]; break }
        Write-Host '  That is not one of the numbers above.'
    }
    Set-AzdValue -Name $Name -Value $pick
    return $pick
}

# The two display names of the Entra registrations. A registration's unique
# name is tenant-wide, so an install names its two after the environment;
# a deployment made before azd (our own lab) keeps the plain names by
# setting these two values by hand.
function Get-VmfRegistrationNames {
    # DRILL-F, 2026-09-09: with no AZURE_ENV_NAME this returned 'vmf-api-' and
    # 'vmf-dashboard-' - names no install has ever created. predown then said
    # "was not found" for both, removed nothing, and reported success. Every
    # value here comes from the azd environment, which azd gives its hooks as
    # process variables. An empty one means azd is not running this hook, so
    # say that. Do not act on a name built from nothing.
    $envName   = Get-AzdValue -Name 'AZURE_ENV_NAME'
    $api       = Get-AzdValue -Name 'VMF_API_DISPLAY_NAME'
    $dashboard = Get-AzdValue -Name 'VMF_DASHBOARD_DISPLAY_NAME'
    if ((-not $api -or -not $dashboard) -and -not $envName) {
        throw ('The names of the registrations are unknown, because AZURE_ENV_NAME is not set. ' +
               'azd gives the environment to its hooks, so azd is not running this hook. ' +
               'Use azd up or azd down, which run it for you.')
    }
    if (-not $api)       { $api       = "vmf-api-$envName" }
    if (-not $dashboard) { $dashboard = "vmf-dashboard-$envName" }
    @{ Api = $api; Dashboard = $dashboard }
}

# AZD-DOWN-RG-RECHECK-1: IS THE PLATFORM REALLY GONE? READ THE RESOURCE GROUP.
#
# FOUND 2026-11-19 in a real removal: azd down printed "Failed deleting
# resource group" and "context canceled", and Azure still deleted the group.
# azd runs postdown only after a delete it saw succeed, so the two Entra
# registrations stayed. A second azd down stopped on "404
# ResourceGroupNotFound", again before postdown.
#
# MEASURED 2026-11-20, azd 1.39.1, an empty resource group in a lab
# subscription:
#   * a successful azd down CLEARS AZURE_RESOURCE_GROUP (it is a deployment
#     output) before postdown runs, and keeps a value predown wrote with
#     azd env set. So predown records the name in VMF_DOWN_RESOURCE_GROUP;
#   * azd down with the group already gone runs predown, exits 1 on
#     ResourceGroupNotFound and never runs postdown. So predown finishes the
#     removal itself in that case (predown.ps1);
#   * azd hooks run postdown runs the hook with the environment, so a removal
#     that azd stopped can be finished with it.
#
# The resource group is the whole platform (one resource group holds it all,
# azure.yaml), so "the group is gone" is what TEARDOWN-1 waits for before the
# registrations go. Only Azure's own ResourceGroupNotFound is "gone". Any other
# failure is "unknown", never a pass.
function Get-VmfDownResourceGroupName {
    $recorded = Get-AzdValue -Name 'VMF_DOWN_RESOURCE_GROUP'
    if ($recorded) { return $recorded }
    return (Get-AzdValue -Name 'AZURE_RESOURCE_GROUP')
}

function Get-VmfResourceGroupState {
    <#
    .SYNOPSIS
        One read of a resource group: gone (ResourceGroupNotFound), deleting
        (provisioningState Deleting), present, or unknown (with what Azure
        said, or what is missing).
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Name, [AllowEmptyString()][string]$Subscription)
    # The names start with 'vmfRg' because the az script block runs in a scope
    # below Invoke-VmfAzCall, and a plain $Name could meet one of its own.
    $vmfRgName = $Name
    $vmfRgSubscription = $Subscription
    if (-not $vmfRgName) { return [pscustomobject]@{ State = 'unknown'; Detail = 'the name of the resource group is not recorded' } }
    if (-not $vmfRgSubscription) { return [pscustomobject]@{ State = 'unknown'; Detail = 'AZURE_SUBSCRIPTION_ID is not set' } }
    $read = Invoke-VmfAzCall -Step "read the resource group $vmfRgName" -Quiet -Command {
        az group show --name $vmfRgName --subscription $vmfRgSubscription -o json
    }
    if ($read.ExitCode -eq 0) {
        $group = $null
        try { $group = ($read.Output -join [Environment]::NewLine) | ConvertFrom-Json } catch { $group = $null }
        if (-not $group) { return [pscustomobject]@{ State = 'unknown'; Detail = 'Azure gave an answer that is not a resource group' } }
        $provisioning = ''
        if ($group.PSObject.Properties['properties'] -and $group.properties -and $group.properties.PSObject.Properties['provisioningState']) {
            $provisioning = [string]$group.properties.provisioningState
        }
        if ($provisioning -eq 'Deleting') { return [pscustomobject]@{ State = 'deleting'; Detail = '' } }
        return [pscustomobject]@{ State = 'present'; Detail = $provisioning }
    }
    $said = (@($read.ErrorLines) -join ' ').Trim()
    if ($said -match '\bResourceGroupNotFound\b') { return [pscustomobject]@{ State = 'gone'; Detail = '' } }
    if (-not $said) { $said = "az exit $($read.ExitCode)" }
    return [pscustomobject]@{ State = 'unknown'; Detail = $said }
}

function Wait-VmfResourceGroupGone {
    <#
    .SYNOPSIS
        Read the resource group until it is gone, or until a fixed limit:
        DeletingSeconds while Azure reports it Deleting, PresentSeconds for any
        other answer. Returns the last read.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Subscription,
        [int]$DeletingSeconds = 1800,
        [int]$PresentSeconds = 60,
        [ValidateRange(1, 600)][int]$IntervalSeconds = 30
    )
    $waited = 0
    $saidDeleting = $false
    $saidOther = $false
    while ($true) {
        $state = Get-VmfResourceGroupState -Name $Name -Subscription $Subscription
        if ($state.State -eq 'gone') { return $state }
        # With no name there is nothing to read again.
        if (-not $Name -or -not $Subscription) { return $state }
        $limit = if ($state.State -eq 'deleting') { $DeletingSeconds } else { $PresentSeconds }
        if ($waited -ge $limit) {
            $state | Add-Member -NotePropertyName WaitedSeconds -NotePropertyValue $waited -Force
            return $state
        }
        if ($state.State -eq 'deleting' -and -not $saidDeleting) {
            Write-Host ("   Azure is deleting the resource group $Name. The removal reads it again every $IntervalSeconds seconds, " +
                "for up to $([Math]::Ceiling($DeletingSeconds / 60)) minutes.")
            $saidDeleting = $true
        }
        elseif ($state.State -ne 'deleting' -and -not $saidOther) {
            Write-Host "   The resource group $Name is still in Azure. The removal reads it again for up to $PresentSeconds seconds."
            $saidOther = $true
        }
        Start-Sleep -Seconds $IntervalSeconds
        $waited += $IntervalSeconds
    }
}
