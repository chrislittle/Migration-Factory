<#
.SYNOPSIS
    UPST-1: detect upstream drift in the source scripts our guest assets were
    extracted from (Azure/SAP-on-Azure-Scripts-and-Utilities).
.DESCRIPTION
    Compares the sha256 of each tracked upstream file at branch HEAD against
    the pinned baseline in src/guest/upstream.json. Drift means upstream
    shipped changes we have not evaluated: review the upstream changelog,
    port anything relevant into src/guest (bumping script versions +
    manifest), then re-pin with -UpdateBaseline.

    Exit code 0 = current, 1 = drift detected (CI-friendly). No Azure calls;
    only raw.githubusercontent.com. -ContentProvider overrides the fetch for
    tests.

    MANA-WIN-1: it also watches the `downloads` - a package a guest script
    installs, pinned IN that script (Install-ManaDriver.ps1 pins one MANA
    driver). Two questions, both asked without downloading anything:
      1. Does Microsoft's link (aka.ms/manawindowsdrivers) still point at the
         pinned file? A new address is a new driver version: read it, then
         pin it on purpose with tools/Update-VmfManaDriverPin.ps1.
      2. Is the pinned file still there, at the size pinned? A removed file
         means a machine with no driver cannot get one; a new size means
         Microsoft replaced the file, and every guest would refuse it on the
         sha256. Either one must be known before a wave finds it.
    -LinkProvider overrides those reads for tests.
.EXAMPLE
    ./tools/Test-UpstreamDrift.ps1                     # check
    ./tools/Test-UpstreamDrift.ps1 -UpdateBaseline     # re-pin after review
#>
[CmdletBinding()]
param(
    [string]$BaselinePath = (Join-Path $PSScriptRoot '..' 'src' 'guest' 'upstream.json'),
    [scriptblock]$ContentProvider,
    [switch]$UpdateBaseline,
    # HEAD commit to record when re-pinning; resolved from the GitHub API when omitted.
    [string]$CommitSha,
    # MANA-WIN-1: reads a URL WITHOUT following a redirect. Returns an object
    # with .StatusCode, .Location and .ContentLength.
    [scriptblock]$LinkProvider
)

$ErrorActionPreference = 'Stop'
$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json -Depth 8

if (-not $ContentProvider) {
    $ContentProvider = {
        param($Path)
        $url = "https://raw.githubusercontent.com/$($baseline.repo)/$($baseline.branch)/$Path"
        (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    }.GetNewClosure()
}

function Get-ContentHash([string]$Content) {
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Content))
    try { (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() }
    finally { $stream.Dispose() }
}

$drifted = [System.Collections.Generic.List[object]]::new()
foreach ($file in @($baseline.files)) {
    try {
        $content = & $ContentProvider $file.path
        $hash = Get-ContentHash $content
    }
    catch {
        $drifted.Add([pscustomobject]@{
            path = $file.path; kind = 'unreachable'; reason = "fetch failed: $($_.Exception.Message)"
            url = "https://github.com/$($baseline.repo)/blob/$($baseline.branch)/$($file.path)"
            changesUrl = "https://github.com/$($baseline.repo)/commits/$($baseline.branch)/$($file.path)"
            localDerivatives = @($file.localDerivatives)
        })
        continue
    }

    if ($UpdateBaseline) {
        $file.sha256 = $hash
        continue
    }
    if ($hash -ne $file.sha256) {
        $drifted.Add([pscustomobject]@{
            path = $file.path; kind = 'changed'; reason = "content changed (baseline $($file.sha256.Substring(0,12))..., now $($hash.Substring(0,12))...)"
            url = "https://github.com/$($baseline.repo)/blob/$($baseline.branch)/$($file.path)"
            changesUrl = "https://github.com/$($baseline.repo)/commits/$($baseline.branch)/$($file.path)"
            localDerivatives = @($file.localDerivatives)
        })
    }
}

# MANA-WIN-1: the packages a guest script downloads. The pin lives in the
# script (its sha256 in the guest manifest covers it), so this reads the pin
# from there - one place, never a second copy here to fall out of step.
if (-not $LinkProvider) {
    $LinkProvider = {
        param($Url)
        # HEAD, and NO redirect: the redirect target IS the answer for the link.
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(60)
            $request = [System.Net.Http.HttpRequestMessage]::new('HEAD', $Url)
            $request.Headers.UserAgent.ParseAdd('vm-migration-factory-upstream-drift')
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            [pscustomobject]@{
                StatusCode    = [int]$response.StatusCode
                Location      = if ($response.Headers.Location) { [string]$response.Headers.Location } else { $null }
                ContentLength = $response.Content.Headers.ContentLength
            }
        }
        finally { $client.Dispose() }
    }
}

$downloads = @(if ($baseline.PSObject.Properties['downloads']) { $baseline.downloads })
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($dl in $downloads) {
    if ($UpdateBaseline) { continue }
    $entry = {
        param([string]$Kind, [string]$Reason)
        [pscustomobject]@{
            path = [string]$dl.name; kind = $Kind; reason = $Reason
            url = [string]$dl.page
            localDerivatives = @($dl.localDerivatives)
        }
    }
    try {
        $pinnedIn = [string]$dl.pinnedIn
        if (-not [System.IO.Path]::IsPathRooted($pinnedIn)) { $pinnedIn = Join-Path $repoRoot $pinnedIn }
        $source = Get-Content -LiteralPath $pinnedIn -Raw
        $pin = @{}
        foreach ($field in 'URL', 'BYTES', 'VERSION') {
            if ($source -notmatch "(?m)^\`$script:PACKAGE_$field\s*=\s*'([^']*)'") { throw "$($dl.pinnedIn) has no `$script:PACKAGE_$field" }
            $pin[$field] = $Matches[1]
        }

        $link = & $LinkProvider ([string]$dl.link)
        $status = [int]$link.StatusCode
        if ($status -lt 300 -or $status -ge 400 -or -not $link.Location) {
            $drifted.Add((& $entry 'unreachable' "the link $($dl.link) did not redirect to a file (HTTP $status), so the pinned version was not compared"))
            continue
        }
        $target = [uri]::new([uri][string]$dl.link, [string]$link.Location).AbsoluteUri
        if ($target -ne $pin.URL) {
            $drifted.Add((& $entry 'changed' ("Microsoft's link $($dl.link) now points at $target, and the product pins $($pin.URL) (version $($pin.VERSION)). " +
                        'A newer driver is out: read it, then pin it on purpose with tools/Update-VmfManaDriverPin.ps1')))
            continue
        }

        $file = & $LinkProvider $pin.URL
        $fileStatus = [int]$file.StatusCode
        if ($fileStatus -in 404, 410) {
            $drifted.Add((& $entry 'changed' "the pinned file $($pin.URL) is gone (HTTP $fileStatus). A machine with no MANA driver cannot get one until a new version is pinned with tools/Update-VmfManaDriverPin.ps1"))
        }
        elseif ($fileStatus -ne 200) {
            $drifted.Add((& $entry 'unreachable' "the pinned file $($pin.URL) answered HTTP $fileStatus, so it was not compared"))
        }
        elseif ($null -eq $file.ContentLength) {
            # No size given is "cannot verify", never a change and never a pass.
            $drifted.Add((& $entry 'unreachable' "the pinned file $($pin.URL) answered with no size, so it was not compared"))
        }
        elseif ([string]$file.ContentLength -ne $pin.BYTES) {
            $drifted.Add((& $entry 'changed' ("the pinned file $($pin.URL) is now $($file.ContentLength) bytes, and the pin says $($pin.BYTES). " +
                        'Microsoft replaced it, so every guest would refuse it on the sha256: pin it again with tools/Update-VmfManaDriverPin.ps1')))
        }
    }
    catch {
        $drifted.Add((& $entry 'unreachable' "could not check: $($_.Exception.Message)"))
    }
}

if ($UpdateBaseline) {
    if ($downloads.Count) {
        Write-Host "Downloads are pinned in their guest script, not here: re-pin them with tools/Update-VmfManaDriverPin.ps1."
    }
    if (-not $CommitSha) {
        $CommitSha = (Invoke-RestMethod "https://api.github.com/repos/$($baseline.repo)/commits/$($baseline.branch)").sha
    }
    $baseline.pinnedCommit = $CommitSha
    $baseline.pinnedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $baseline | ConvertTo-Json -Depth 8 | Set-Content $BaselinePath -Encoding utf8NoBOM
    Write-Host "Baseline re-pinned to $CommitSha ($(@($baseline.files).Count) files)."
}
elseif ($drifted.Count -gt 0) {
    Write-Host "UPSTREAM DRIFT: $($drifted.Count) tracked file(s) changed since pin $($baseline.pinnedCommit.Substring(0,12)) ($($baseline.pinnedUtc)):" -ForegroundColor Yellow
    foreach ($d in $drifted) {
        Write-Host "  $($d.path)" -ForegroundColor Yellow
        Write-Host "    $($d.reason)"
        Write-Host "    re-evaluate: $($d.localDerivatives -join ', ')"
    }
    Write-Host "Review https://github.com/$($baseline.repo)/blob/$($baseline.branch)/Azure-NVMe-Utils/Changelog.md, port what applies, then ./tools/Test-UpstreamDrift.ps1 -UpdateBaseline"
}
else {
    Write-Host "Upstream current: all $(@($baseline.files).Count) tracked files match pin $($baseline.pinnedCommit.Substring(0,12)), and $($downloads.Count) pinned download(s) match their link."
}

[pscustomobject]@{
    Checked  = @($baseline.files).Count + $(if ($UpdateBaseline) { 0 } else { $downloads.Count })
    Drifted  = @($drifted)
    ExitCode = if ($drifted.Count -gt 0 -and -not $UpdateBaseline) { 1 } else { 0 }
}
