# PUBLISH-IN-1: put the package this image carries into the code container.
#
# Runs as a Container Apps job, once, inside the subscription - which is the
# whole point: a network security perimeter admits this and cannot admit a
# laptop. It holds ONE data role, Storage Blob Data Contributor on the
# vmf-deploy container, and it reads nothing.
#
# Every failure here has to SAY what Azure said. This runs where nobody is
# watching, and the only thing the installer ever sees is this job's exit code
# and its log.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Required([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "The job was started without $Name. The template sets it; deploy infra/platform.bicep again."
    }
    return $value
}

$account = Get-Required 'VMF_STORE_ACCOUNT'
$container = Get-Required 'VMF_DEPLOY_CONTAINER'
$clientId = Get-Required 'AZURE_CLIENT_ID'
$blob = 'facade.zip'
$package = '/app/facade.zip'

if (-not (Test-Path $package)) {
    throw "This image carries no package at $package. The image was built wrong; see docker/publish/Dockerfile."
}
$size = (Get-Item $package).Length
Write-Host "Publishing $blob to $account/$container ($([math]::Round($size / 1MB, 2)) MB)"

# The job's user-assigned identity, named explicitly. A container can be given
# more than one, and Connect-AzAccount -Identity with no account picks whatever
# the platform offers first - which is a coin toss that fails a publish weeks
# later, on a change that had nothing to do with this.
Connect-AzAccount -Identity -AccountId $clientId -ErrorAction Stop | Out-Null

# No key, ever (SEC-1). The context signs in as the identity above.
$context = New-AzStorageContext -StorageAccountName $account -UseConnectedAccount

# A role assignment made moments ago is not always visible to the DATA plane
# yet, and on a first install this grant is seconds old. Microsoft documents
# that propagation as taking up to ten minutes, so the wait is longer than ten.
#
# UPLOAD-WAIT-1's other lesson matters more: DO NOT ASSERT THE CAUSE. A storage
# firewall, a perimeter rule and a missing role all refuse this upload, and a
# message that names a permission sends somebody to fix one that was never
# wrong. Say what Azure said, then judge it.
$backoff = @(5, 10, 15, 20, 30, 30, 45, 45, 60, 60, 60, 60)
$budget = [int](($backoff | Measure-Object -Sum).Sum / 60)
$uploaded = $false
$lastError = ''
for ($attempt = 0; $attempt -lt $backoff.Count; $attempt++) {
    try {
        Set-AzStorageBlobContent -File $package -Container $container -Blob $blob `
            -Context $context -Force -ErrorAction Stop | Out-Null
        $uploaded = $true
        break
    }
    catch {
        $lastError = [string]$_.Exception.Message
        if ($attempt -eq 0) { Write-Host "   waiting for the code container permission to apply (up to $budget minutes)..." }
        Write-Host "   attempt $($attempt + 1) failed: $lastError"
        Start-Sleep -Seconds $backoff[$attempt]
    }
}

if (-not $uploaded) {
    $why = if ([string]::IsNullOrWhiteSpace($lastError)) { 'Azure returned no message.' } else { $lastError }
    $head = "Could not put $blob in $account/$container after $budget minutes."
    if ($lastError -match '(?i)AuthorizationPermissionMismatch|AuthorizationFailure|Forbidden|403|not authorized') {
        $head += " Azure refuses the write. This job's identity needs Storage Blob Data Contributor on the $container container, which infra/platform.bicep grants."
    }
    else {
        $head += ' Azure did not refuse this for a permission, so a role assignment does not fix it. A network rule on the storage account stops it the same way. Read what Azure said:'
    }
    throw ($head + [Environment]::NewLine + $why)
}

Write-Host "Published $blob."
