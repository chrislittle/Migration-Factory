# Facade profile: load the factory module and the facade core. No sign-in.
#
# PERF-PROFILE-1. Microsoft's PowerShell guide for Functions: this script runs
# on each cold start, and "the profile script is run for each runspace
# created" - so a warm instance runs it again for each new runspace. The
# module loads its files as one script block (VmMigrationFactory.psm1).
#
# FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1: NO SIGN-IN AND NO AZ MODULE.
# MEASURED on the lab install, 2026-11-08: the first runspace of each new
# process signed in with Connect-AzAccount -Identity in 4 to 7 s, after
# Az.Accounts loaded from the managed dependencies (about 1.4 s). The service
# used that sign-in only for bearer tokens - the run store, and ARM by full
# path. Each token now comes from the managed identity endpoint the platform
# gives the site (IDENTITY_ENDPOINT and IDENTITY_HEADER; Microsoft, "Managed
# identities - Azure App Service", "REST endpoint reference"), asked when a
# call first needs it and kept for the process until close to its expiry
# (Get-VmfAccessToken, src/VmMigrationFactory/Private/azureops/AzureOpsToken.ps1).
# So host.json turns managed dependencies off and there is no requirements.psd1.
#
# THE PERF-PROFILE-1 RULE STAYS: never a second sign-in in a signed-in
# process. Azure PowerShell keeps its context at PROCESS level, so a second
# Connect-AzAccount replaced the context the other runspaces were using in the
# middle of their calls. There is now no sign-in at all, and a test fails if
# this script calls Connect-AzAccount, or any Az command, again
# (FacadeSigninCold.Tests.ps1).
$ErrorActionPreference = 'Stop'
$vmfStartUp = [System.Diagnostics.Stopwatch]::StartNew()
Import-Module (Join-Path $PSScriptRoot 'Modules' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
Import-Module (Join-Path $PSScriptRoot 'Modules' 'FacadeCore' 'FacadeCore.psd1')
$vmfLoadMs = $vmfStartUp.ElapsedMilliseconds
$vmfTokens = if (& (Get-Module VmMigrationFactory) { Test-VmfTokenFromIdentityEndpoint }) {
    'from the managed identity endpoint, with no sign-in.'
}
else { 'from the Az context of this computer (no managed identity endpoint).' }
# One line in the Application Insights traces for each start (Write-Host is the
# Information level), so the lab proof can read the start-up time.
Write-Host ('VMF start-up: the modules loaded in {0} ms. Tokens: {1}' -f $vmfLoadMs, $vmfTokens)
