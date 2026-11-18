<#
.SYNOPSIS
    POLICY-DRIFT: watch the Azure built-in POLICY definitions our data files
    are generated from.

.DESCRIPTION
    UPST-1 watches upstream scripts, UPST-3 watches the migration docs. This
    watches a third kind of source: `data/nva-offers.json` is generated from
    Microsoft's built-in MANA NVA policy, so a new policy version - a vendor
    added, an offer pattern changed - invalidates local data with nothing in
    our code moving.

    Built-in policies are published in the public Azure/azure-policy repo, so
    this reads GitHub anonymously like the other two watchers: no Azure auth,
    no token. (Deliberately anonymous - an authenticated token bound to another
    org's SAML gets 403 on the Azure org, which is how the first fetch of this
    file failed.)

    Blob-SHA compare from ONE directory listing, the UPST-3 pattern. When a
    file HAS drifted, it is fetched once more to name the version change in
    the report ("1.3.0 -> 1.4.0"), because "content changed" alone sends
    someone diffing JSON to learn what one field would have told them.

    One extra check the other watchers do not need: the pinned version here
    must equal the version recorded inside the GENERATED data file. If someone
    regenerates the data without re-pinning, or re-pins without regenerating,
    the two halves disagree and that is drift too - internal drift, which no
    upstream fetch would ever show.

.PARAMETER ListingProvider
    Overrides the directory fetch, for tests. Returns objects with .name,
    .sha and .type - the shape of the GitHub contents API.

.PARAMETER ContentProvider
    Overrides the raw-file fetch used to name a drifted file's new version.
#>
param(
    [string]$BaselinePath = (Join-Path $PSScriptRoot '..' 'docs' 'upstream-policies.json'),
    [scriptblock]$ListingProvider,
    [scriptblock]$ContentProvider,
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Stop'
$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json -Depth 8

if (-not $ListingProvider) {
    $ListingProvider = {
        param($Repo, $Branch, $Folder)
        $url = "https://api.github.com/repos/$Repo/contents/$Folder`?ref=$Branch"
        $headers = @{
            'User-Agent' = 'vm-migration-factory-policy-drift'
            'Accept'     = 'application/vnd.github+json'
        }
        # UPST-4: unauthenticated GitHub allows 60 requests an hour PER IP, and
        # the Actions runners share addresses - which is how the scheduled
        # check got a 403 on 2026-09-13 and the issue announced a change
        # nobody had measured. The WORKFLOW sets this; nothing sets it on a
        # developer's machine, so a local run stays anonymous.
        # Its own variable name on purpose: a PERSONAL token bound to another
        # org's SAML gets 403 on the Azure org, which is why these fetches are
        # anonymous by default and must stay that way unless the caller has
        # deliberately supplied a token that works.
        if ($env:VMF_DRIFT_TOKEN) { $headers['Authorization'] = "Bearer $env:VMF_DRIFT_TOKEN" }
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers
        $content = if ($resp.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($resp.Content)
        } else { [string]$resp.Content }
        $content | ConvertFrom-Json
    }
}
if (-not $ContentProvider) {
    $ContentProvider = {
        param($Repo, $Branch, $Path)
        $url = "https://raw.githubusercontent.com/$Repo/$Branch/$Path"
        (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{
            'User-Agent' = 'vm-migration-factory-policy-drift'
        }).Content
    }
}

$drifted = [System.Collections.Generic.List[object]]::new()
$checked = 0

# The listings are per-folder; group so each folder costs one request.
$byFolder = @($baseline.policies) | Group-Object path
foreach ($group in $byFolder) {
    try {
        $listing = @(& $ListingProvider $baseline.repo $baseline.branch $group.Name)
    }
    catch {
        # Cannot read it = cannot claim it is unchanged (the drill rule).
        foreach ($p in $group.Group) {
            $drifted.Add([pscustomobject]@{
                path = "$($p.path)/$($p.name)"
                kind = 'unreachable'; reason = "listing failed: $($_.Exception.Message)"
                localDerivatives = @($p.localDerivatives)
            url = "https://github.com/$($baseline.repo)/blob/$($baseline.branch)/$($p.path)/$($p.name)"
            changesUrl = "https://github.com/$($baseline.repo)/commits/$($baseline.branch)/$($p.path)/$($p.name)"
            })
        }
        continue
    }

    $live = @{}
    foreach ($item in $listing) {
        if ($item.type -eq 'file') { $live[[string]$item.name] = [string]$item.sha }
    }

    foreach ($p in $group.Group) {
        $checked++
        if (-not $live.ContainsKey([string]$p.name)) {
            $drifted.Add([pscustomobject]@{
                path = "$($p.path)/$($p.name)"
                kind = 'changed'; reason = 'POLICY REMOVED upstream - the list our detection is generated from no longer exists there'
                localDerivatives = @($p.localDerivatives)
            url = "https://github.com/$($baseline.repo)/blob/$($baseline.branch)/$($p.path)/$($p.name)"
            changesUrl = "https://github.com/$($baseline.repo)/commits/$($baseline.branch)/$($p.path)/$($p.name)"
            })
            continue
        }
        if ($live[[string]$p.name] -eq [string]$p.sha) { continue }

        # Drifted: fetch once to say WHAT changed in human terms.
        $newVersion = '(unreadable)'
        try {
            $raw = & $ContentProvider $baseline.repo $baseline.branch "$($p.path)/$($p.name)"
            $doc = $raw | ConvertFrom-Json -Depth 20
            $props = if ($doc.properties) { $doc.properties } else { $doc }
            $newVersion = [string]$props.metadata.version
        } catch { }
        $drifted.Add([pscustomobject]@{
            path = "$($p.path)/$($p.name)"
            kind = 'changed'; reason = "policy changed: pinned version $($p.pinnedVersion), upstream now $newVersion (blob $([string]$p.sha.Substring(0,12))... -> $($live[[string]$p.name].Substring(0,12))...)"
            localDerivatives = @($p.localDerivatives)
            url = "https://github.com/$($baseline.repo)/blob/$($baseline.branch)/$($p.path)/$($p.name)"
            changesUrl = "https://github.com/$($baseline.repo)/commits/$($baseline.branch)/$($p.path)/$($p.name)"
        })

        if ($UpdateBaseline) {
            $p.sha = $live[[string]$p.name]
            if ($newVersion -and $newVersion -ne '(unreadable)') { $p.pinnedVersion = $newVersion }
        }
    }
}

# Internal drift: the generated data file must agree with the pin. Neither
# upstream fetch can see this - it is the two local halves disagreeing.
$nvaDataPath = Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'data' 'nva-offers.json'
if (Test-Path $nvaDataPath) {
    $nvaData = Get-Content $nvaDataPath -Raw | ConvertFrom-Json -Depth 8
    $pin = @($baseline.policies) | Where-Object { $_.policyDefinitionId -eq [string]$nvaData.source.policyDefinitionId } | Select-Object -First 1
    if ($pin -and [string]$nvaData.source.version -ne [string]$pin.pinnedVersion) {
        $drifted.Add([pscustomobject]@{
            path = 'src/VmMigrationFactory/data/nva-offers.json'
            kind = 'changed'; reason = "INTERNAL drift: the generated data says policy v$($nvaData.source.version) but the baseline pins v$($pin.pinnedVersion) - one half was updated without the other"
            localDerivatives = @('regenerate the data from the new definition AND re-pin, together')
        })
    }
}

if ($UpdateBaseline) {
    $baseline.checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $baseline | ConvertTo-Json -Depth 8 | Set-Content $BaselinePath
    Write-Host "Baseline re-pinned: $BaselinePath"
}

if ($drifted.Count -eq 0) {
    Write-Host "Policy sources current: all $checked tracked polic$(if ($checked -eq 1) { 'y matches' } else { 'ies match' }) their pins."
}
else {
    Write-Host "POLICY DRIFT: $($drifted.Count) tracked item(s) changed:"
    foreach ($d in $drifted) {
        Write-Host "  $($d.path)"
        Write-Host "    $($d.reason)"
        Write-Host "    re-evaluate: $(@($d.localDerivatives) -join ', ')"
    }
    Write-Host "Regenerate the derived data from the new definition, then ./tools/Test-PolicyDrift.ps1 -UpdateBaseline - re-pinning first only silences the signal."
}

[pscustomobject]@{ Checked = $checked; Drifted = @($drifted) }
