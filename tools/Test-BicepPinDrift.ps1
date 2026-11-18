<#
.SYNOPSIS
    BICEP-PIN-1: compare the pinned Bicep CLI version with Bicep's latest
    release.

.DESCRIPTION
    infra/bicep-version.json pins the ONE Bicep CLI version that CI and the
    CI runners use (2026-10-18). Nothing upgrades it by itself, so a
    newer release is found here: the daily upstream-drift workflow runs this
    with the other three checks and reports the result in the same issue.

    One question, asked of GitHub's "latest release" answer for Azure/bicep,
    which names the newest release that is neither a pre-release nor a draft:
      - the same version as the pin: current;
      - a newer version: a change. Read its release notes, then move the pin
        with -UpdateBaseline. CI installs the new version on its next run, and
        a new runner gets it from its set-up;
      - an older version: a change too. The pin names a version Bicep has not
        released, or one it withdrew.
    An answer it cannot read - a failed request, a rate limit, no version in
    the answer, a pre-release or a draft - is NOT CHECKED, never current. The
    same rule as the other checks (UPST-4): a check that cannot reach its
    evidence must not pass, and must not claim a change.

    GitHub allows 60 anonymous reads an hour per address, and runners share
    addresses. The workflow gives VMF_DRIFT_TOKEN (the repository's own
    token), which raises that limit, as for the script and policy checks.

.PARAMETER PinPath
    The pin file. Defaults to infra/bicep-version.json.

.PARAMETER ReleaseProvider
    Replaces the GitHub request, for tests. Returns an object with tag_name,
    prerelease, draft and html_url: the shape of GitHub's answer.

.PARAMETER UpdateBaseline
    Write the latest release into the pin. Only a release it could read.

.EXAMPLE
    ./tools/Test-BicepPinDrift.ps1                   # check
    ./tools/Test-BicepPinDrift.ps1 -UpdateBaseline   # move the pin, after reading the release notes
#>
[CmdletBinding()]
param(
    [string]$PinPath = (Join-Path $PSScriptRoot '..' 'infra' 'bicep-version.json'),
    [scriptblock]$ReleaseProvider,
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'
$releasesPage = 'https://github.com/Azure/bicep/releases'
$pinFile = 'infra/bicep-version.json'

$pin = Get-Content -LiteralPath $PinPath -Raw | ConvertFrom-Json
$pinned = [string]$pin.version
if ($pinned -notmatch '^\d+\.\d+\.\d+$') {
    throw "$PinPath pins '$pinned', which is not a Bicep version (three numbers, for example 1.2.3)."
}

if (-not $ReleaseProvider) {
    $ReleaseProvider = {
        $headers = @{
            'User-Agent'           = 'vm-migration-factory-bicep-pin'
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        # UPST-4: the workflow sets this; a local run stays anonymous.
        if ($env:VMF_DRIFT_TOKEN) { $headers['Authorization'] = "Bearer $env:VMF_DRIFT_TOKEN" }
        Invoke-RestMethod -Uri 'https://api.github.com/repos/Azure/bicep/releases/latest' -Headers $headers -TimeoutSec 60
    }
}

$derivatives = @(
    $pinFile,
    'CI: tools/Sync-VmfBicepVersion.ps1 installs the pin on each runner',
    'a new runner: infra/ci-runners.bicep and infra/ci-linux-runner.bicep give the pin to the set-up'
)
function New-VmfPinEntry([string]$Kind, [string]$Reason, [string]$Url) {
    [pscustomobject]@{ path = $pinFile; kind = $Kind; reason = $Reason; url = $Url; localDerivatives = $derivatives }
}

$drifted = [System.Collections.Generic.List[object]]::new()
$latest = $null
try {
    $release = & $ReleaseProvider
    $tag = [string]$release.tag_name
    if ($release.draft -eq $true -or $release.prerelease -eq $true) {
        $drifted.Add((New-VmfPinEntry 'unreachable' "GitHub gave $tag as the latest release, and it is a pre-release or a draft, so the pin was not compared." $releasesPage))
    }
    elseif ($tag -notmatch '^v?(\d+\.\d+\.\d+)$') {
        $drifted.Add((New-VmfPinEntry 'unreachable' "GitHub gave '$tag' as the latest release, which is not a version, so the pin was not compared." $releasesPage))
    }
    else {
        $latest = $Matches[1]
        $page = if ($release.html_url) { [string]$release.html_url } else { "$releasesPage/tag/v$latest" }
        if ([version]$latest -gt [version]$pinned) {
            $drifted.Add((New-VmfPinEntry 'changed' "Bicep $latest is released, and the pin is $pinned. Read the release notes, then move the pin." $page))
        }
        elseif ([version]$latest -lt [version]$pinned) {
            $drifted.Add((New-VmfPinEntry 'changed' "The pin is $pinned, which is newer than Bicep's latest release, $latest. Bicep has not released it, or withdrew it." $page))
        }
    }
}
catch {
    $drifted.Add((New-VmfPinEntry 'unreachable' "could not read the latest Bicep release: $($_.Exception.Message)" $releasesPage))
}

if ($UpdateBaseline) {
    if (-not $latest) {
        throw "The pin stays at ${pinned}: there is no release to pin. $(@($drifted | ForEach-Object { $_.reason }) -join ' ')"
    }
    $pin.version = $latest
    $pin.pinnedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $pin | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $PinPath -Encoding utf8NoBOM
    Write-Host "Bicep pinned at $latest in $PinPath. CI installs it on its next run; a new runner gets it from its set-up."
    $drifted.Clear()
}
elseif ($drifted.Count -eq 0) {
    Write-Host "Bicep pin current: $pinned is the latest release."
}
else {
    foreach ($d in $drifted) { Write-Host "BICEP PIN: $($d.reason)" }
}

[pscustomobject]@{
    Checked  = 1
    Drifted  = @($drifted)
    ExitCode = if ($drifted.Count -gt 0) { 1 } else { 0 }
}
