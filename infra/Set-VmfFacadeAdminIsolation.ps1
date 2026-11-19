# FUNCTIONS-ADMIN-ISOLATION-1: close the /admin paths of the service's
# Functions host, so the master key does not reach them around the sign-in.
#
# WHAT WAS OPEN. App Service authentication refuses an unsigned call to every
# function, but it does not cover /admin. MEASURED 2026-11-14 on a lab install:
# /admin/host/status answered 401 from the Functions host, which asks for the
# master key, not from the sign-in. Microsoft, "Work with access keys in Azure
# Functions": the master key "also provides administrative access to the
# runtime REST APIs"; "Manually run a non HTTP-triggered function": a POST to
# /admin/functions/<name> with it runs the function - here the daily cleanup
# and the 5-minute check, with no sign-in and no name of a person.
#
# THE SETTING. Microsoft, "App settings reference for Azure Functions" (ms.date
# 2026-09-15), functionsRuntimeAdminIsolationEnabled: "When true, /admin
# endpoints can't be accessed, even with a master key." It "can't be set for
# apps running on Linux in a Consumption plan"; the service is a Windows
# function app on Consumption (Free) and on Basic, so both plans carry it.
# "Securing Azure Functions" (Disable administrative endpoints): the same
# operations stay reachable through the Azure Resource Manager
# Microsoft.Web/sites API, "which offers Azure RBAC" - which is the route the
# install's own calls take (syncfunctiontriggers, the function list).
#
# WHY HERE AND NOT IN THE TEMPLATE. The site is deployed by the Azure Verified
# Module web/site 0.24.0, the newest there is; it has no parameter for this
# property and passes none through, and the published Microsoft.Web/sites
# 2025-03-01 schema does not list it. Azure returns the property at every
# api-version from 2023-12-01 to 2025-05-01 (read on the lab install,
# 2026-11-14). So the install sets it after every deployment, by the site's
# resource ID, with a PATCH that sends ONLY this property. Not a GET and a PUT
# of the whole site (`az resource update`): a GET of a site does not return its
# app settings or every part of siteConfig, so a whole-site PUT could drop
# them on a live install (review, 2026-11-15).
# Microsoft, "Web Apps - Update" (REST reference, ms.date 2026-10-23):
# "PATCH https://management.azure.com/subscriptions/{subscriptionId}/
# resourceGroups/{resourceGroupName}/providers/Microsoft.Web/sites/{name}",
# with the site settings under `properties` (properties.httpsOnly,
# properties.clientAffinityEnabled, properties.siteConfig). That body table
# does NOT list functionsRuntimeAdminIsolationEnabled; Microsoft calls it a
# "site property", and a GET returns it under `properties`, so it goes there.
# Whether the PATCH keeps it is what the read back below proves.
#
# THE READ BACK IS THE PROOF. An Azure Policy with the modify effect puts a
# setting back and reports success (CLAUDE.md, MEASURED 2026-09-10), so an
# exit code proves nothing. No value after the write is a failure too:
# unknown is never a pass.
#
# Dot-sourced by infra/hooks/postprovision.ps1 and infra/deploy.ps1.
#
# INSTALL-THROTTLE-RETRY-3: each az call here runs through Invoke-VmfAzCall
# (infra/Invoke-VmfAzStep.ps1), which tries a throttled answer (HTTP 429)
# again. The failures keep their own words; when every try was throttled, the
# words say so (Get-VmfAzThrottleNote).
. (Join-Path $PSScriptRoot 'Invoke-VmfAzStep.ps1')
# The api-version of the site in the Azure Verified Module that deploys it.
function Get-VmfFacadeSiteApiVersion { '2025-03-01' }

# The PATCH body: this one property, and nothing else on the site.
function Get-VmfFacadeAdminIsolationBody { '{"properties":{"functionsRuntimeAdminIsolationEnabled":true}}' }

function Get-VmfFacadeAdminIsolation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SiteId)
    $apiVersion = Get-VmfFacadeSiteApiVersion
    $read = Invoke-VmfAzCall -Step 'read the service site' -Quiet -Command { az resource show --ids $SiteId --api-version $apiVersion -o json }
    $json = @($read.Output)
    if ($read.ExitCode -ne 0 -or -not $json) {
        throw "The install cannot read the service site $SiteId. The az command stopped with exit code $($read.ExitCode).$(Get-VmfAzThrottleNote -Result $read)"
    }
    $site = ($json | Out-String) | ConvertFrom-Json
    $props = $site.properties
    if ($null -eq $props -or $props.PSObject.Properties.Name -notcontains 'functionsRuntimeAdminIsolationEnabled') { return $null }
    return $props.functionsRuntimeAdminIsolationEnabled
}

function Set-VmfFacadeAdminIsolation {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SiteId)
    if ($SiteId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$') {
        throw "'$SiteId' is not the resource ID of a Microsoft.Web/sites resource."
    }
    $before = Get-VmfFacadeAdminIsolation -SiteId $SiteId
    if ($before -eq $true) { return 'already' }

    # One query parameter only: az.cmd hands the URL to cmd, which reads `&` as
    # a command separator (CLAUDE.md). The body goes in a file, so no shell
    # quotes it.
    $url = "https://management.azure.com${SiteId}?api-version=$(Get-VmfFacadeSiteApiVersion)"
    $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vmf-admin-isolation-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $bodyPath -Value (Get-VmfFacadeAdminIsolationBody) -Encoding utf8NoBOM
        $patch = Invoke-VmfAzCall -Step 'close the /admin paths of the service' -Command {
            az rest --method patch --url $url --body "@$bodyPath" --headers 'Content-Type=application/json' --output none
        }
        if ($patch.ExitCode -ne 0) {
            throw "The install cannot close the /admin paths of the service. The az command stopped with exit code $($patch.ExitCode).$(Get-VmfAzThrottleNote -Result $patch)"
        }
    }
    finally { Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue }

    $after = Get-VmfFacadeAdminIsolation -SiteId $SiteId
    if ($null -eq $after) {
        throw "Azure accepted the change. The property functionsRuntimeAdminIsolationEnabled of the service site has no value. The install does not know if the /admin paths are closed."
    }
    if ($after -ne $true) {
        throw "Azure accepted the change. The property functionsRuntimeAdminIsolationEnabled of the service site is false. An Azure Policy with the modify effect can change a value after Azure accepts it. The /admin paths are open."
    }
    return 'closed'
}

