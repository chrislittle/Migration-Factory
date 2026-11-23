<#
.SYNOPSIS
    SBOM-1: publish a GitHub release only once its bill of materials is on it.

.DESCRIPTION
    The release workflow's last step. In order, and nothing anybody
    else can see happens before the last one:

      1. The document is there, or nothing is created.
      1a. RELEASE-DRAFT-RERUN-1: read the releases of the repository first,
         drafts included. A tag that already has a published release stops
         here, and so does a tag with more than one draft; nothing is created
         or changed. One draft of the tag is what an earlier run of the same
         version left: this run finishes that draft (an attachment of the
         same name on it is removed first) instead of making a second one.
      2. Create the release as a DRAFT, with release notes GitHub writes from
         the commits since the last release. Below 1.0.0 it is a pre-release:
         the schemas, the cmdlet names and the install path can still change.
      3. Attach the document (the release's upload address).
      4. Read the release's attachments back: the upload's own answer is not
         proof, so the file must be listed, at its size, as uploaded.
      5. Publish the draft, and read the answer: a release GitHub still reports
         as a draft is a failure.

    A failure at 3, 4 or 5 leaves a draft only a writer of the repository can
    see, and stops the job with the reason.

    The release is created through the REST API, not the gh CLI, which the
    runner does not have (tools/Initialize-VmfCiRunner.ps1).

.PARAMETER Repository
    owner/name. The workflow gives GITHUB_REPOSITORY.

.PARAMETER Version
    The manifest's ModuleVersion. The tag and the release's name are v<Version>.

.PARAMETER SbomPath
    The document tools/New-VmfSbom.ps1 wrote.

.PARAMETER Rest
    { param($Method, $Uri, $Body, $InFile, $ContentType) }. Tests give a
    stand-in GitHub; the default calls the API with -Token.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$SbomPath,
    [string]$Token = $env:GH_TOKEN,
    [scriptblock]$Rest
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $SbomPath -PathType Leaf)) {
    throw "There is no bill of materials at $SbomPath, so no release was created."
}
if (-not $Rest) {
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $Rest = {
        param($Method, $Uri, $Body, $InFile, $ContentType)
        $call = @{ Method = $Method; Uri = $Uri; Headers = $headers }
        if ($Body) { $call.Body = $Body; $call.ContentType = 'application/json' }
        if ($InFile) { $call.InFile = $InFile; $call.ContentType = $ContentType }
        Invoke-RestMethod @call
    }.GetNewClosure()
}

$tag = "v$Version"
$api = "https://api.github.com/repos/$Repository/releases"
$name = [System.IO.Path]::GetFileName($SbomPath)
$size = (Get-Item -LiteralPath $SbomPath).Length

# RELEASE-DRAFT-RERUN-1: look before making anything. The list holds the
# drafts too (the token can write the repository), page by page.
$ofTag = [System.Collections.Generic.List[object]]::new()
for ($page = 1; $page -le 50; $page++) {
    $listed = @(& $Rest 'Get' "${api}?per_page=100&page=$page" $null $null $null | ForEach-Object { $_ } | Where-Object { $_ })
    foreach ($r in $listed) { if ([string]$r.tag_name -eq $tag) { $ofTag.Add($r) } }
    if ($listed.Count -lt 100) { break }
}
$published = @($ofTag | Where-Object { $_.draft -ne $true })
if ($published.Count) {
    throw "$tag is already released ($($published[0].html_url)). A released version is never released again, so nothing was created. Release the next version."
}
$drafts = @($ofTag | Where-Object { $_.draft -eq $true })
if ($drafts.Count -gt 1) {
    throw "$tag has $($drafts.Count) drafts ($(@($drafts | ForEach-Object html_url) -join ', ')), so nothing was created or changed. Delete all but one of them, then run the release again."
}
if ($drafts.Count -eq 1) {
    # An earlier run of this version stopped after it made its draft. That
    # draft is this release: the run finishes it instead of making a second.
    $draft = $drafts[0]
    Write-Host "$tag already has a draft (release $($draft.id)) from an earlier run, so this run finishes that draft."
    foreach ($old in @(& $Rest 'Get' "$api/$($draft.id)/assets" $null $null $null | ForEach-Object { $_ } | Where-Object { $_ -and [string]$_.name -eq $name })) {
        $null = & $Rest 'Delete' "$api/assets/$($old.id)" $null $null $null
        Write-Host "removed the earlier $name from the draft"
    }
}
else {
    $body = @{
        tag_name               = $tag
        name                   = $tag
        generate_release_notes = $true
        draft                  = $true
        prerelease             = ([version]$Version -lt [version]'1.0.0')
    } | ConvertTo-Json
    $draft = & $Rest 'Post' $api $body $null $null
    Write-Host "created $tag as a draft (release $($draft.id))"
}

try {
    # The upload address is a URI template: {?name,label} is its query.
    $upload = ([string]$draft.upload_url -replace '\{[^}]*\}$', '') + '?name=' + [uri]::EscapeDataString($name)
    $null = & $Rest 'Post' $upload $null $SbomPath 'application/json'
    $listed = @(& $Rest 'Get' "$api/$($draft.id)/assets" $null $null $null | ForEach-Object { $_ })
    $asset = @($listed | Where-Object { $_.name -eq $name -and [long]$_.size -eq $size -and $_.state -eq 'uploaded' })
    if (-not $asset.Count) {
        throw "the release lists no uploaded $name of $size bytes (it lists: $(@($listed | ForEach-Object { "$($_.name) $($_.size) $($_.state)" }) -join ', '))"
    }
}
catch {
    throw "The bill of materials did not attach to $tag, so the release stays a draft that only writers of the repository see ($($draft.html_url)): $($_.Exception.Message). Attach the file to the draft and publish it, or delete the draft."
}

$published = & $Rest 'Patch' "$api/$($draft.id)" (@{ draft = $false } | ConvertTo-Json) $null $null
if ($published.draft -ne $false) {
    throw "GitHub still reports $tag as a draft after the publish ($($published.html_url))."
}
Write-Host "released $tag with its bill of materials $name`: $($published.html_url)"
[pscustomobject]@{ Tag = $tag; Url = $published.html_url; Asset = $name }
