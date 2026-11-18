<#
.SYNOPSIS
    DEPS-CURRENT-1: compare each pinned part with its latest release, and ask
    GitHub for an advisory that names a pinned version.

.DESCRIPTION
    infra/part-versions.json pins every part the product ships that does not
    update by itself. Nothing moves those pins, so a newer version, or a
    security notice, is found here: the daily upstream-drift workflow runs
    this with its other checks and reports the result in the same issue.

    For each pinned part, one question of the place its releases are listed:
      - npm (the sign-in library): the registry's list of versions;
      - mcr (the engine base image, the template modules): the registry's
        list of tags. For an image, only tags of the pinned shape count
        ({version}-ubuntu-24.04);
      - psgallery (the test tools): the
        gallery's list of versions;
      - functions-cdn (the service's extension bundle, PIN-RUNTIME-1): the
        bundle index on cdn.functions.azure.com, the place Microsoft's
        extension bundles page says the Functions host downloads bundles from;
      - github (the workflows' GitHub Actions, PIN-ACTIONS-1): the
        repository's releases, each tag v<version>. Drafts and pre-releases
        are left out.
    A pre-release never counts. A part with holdMajor is compared only with
    releases of that major version (Pester stays on 5 for 1.0).
      - the same version as the pin: current;
      - a newer one: a change. Read the release notes, then move the pin;
      - only older ones: a change too. The pin names a version that is not
        released, or one that was withdrawn.
    And for a part with an advisory source (npm), GitHub's advisory database
    is asked for advisories that affect the PINNED version. Each one is a
    change, named by its id and severity.

    And a pin kept in a file of its own, which pinnedElsewhere names with this
    script as its check (SBOM-GEN-DRIFT-1: the SBOM generator, syft, in
    infra/sbom-generator.json), is asked the same two questions: its GitHub
    releases, and GitHub's advisories against the pinned version. Its entry
    gives the key (-Part), the repository, the advisory package and the name
    of the release's checksums file. The workflow reports it with the parts.

    And for an action (PIN-ACTIONS-1), GitHub is asked which commit the tag
    of the pinned version names now. A tag that names another commit than the
    pin is a change: its publisher moved it, which is what the pin is there
    to stop from reaching CI unseen.

    And for a saved file whose pin records a lock file (MERMAID-CONTENTS-1:
    the libraries built into the manual's diagram file), the lock file is
    downloaded from its address at the release's tag. A sha256 other than the
    recorded one is a change, and so is a row it proves that it does not name.

    A source it cannot read - a failed request, a rate limit, an answer with
    no release in it - is NOT CHECKED, never current. The same rule as the
    other checks (UPST-4): a check that cannot reach its evidence must not
    pass, and must not claim a change.

    Only GitHub receives a token (VMF_DRIFT_TOKEN, which the workflow sets).
    The registries are read anonymously.

.PARAMETER PinPath
    The pin file. Defaults to infra/part-versions.json.

.PARAMETER Root
    The repository whose references -UpdateBaseline moves. Defaults to the one
    this script is in.

.PARAMETER VersionProvider
    Replaces the registry requests, for tests. Called with one part; returns
    the version strings its source lists.

.PARAMETER AdvisoryProvider
    Replaces the GitHub advisory request, for tests. Called with one part;
    returns advisories in GitHub's shape (ghsa_id, html_url, severity,
    summary).

.PARAMETER PackageProvider
    Replaces the npm package download, for tests. Called with a part and a
    version; returns Path (a .tgz) and Integrity (npm's sha512- value).

.PARAMETER CommitProvider
    Replaces the GitHub tag request, for tests. Called with an action's part
    and a version; returns the commit id the tag v<version> names (an
    annotated tag is followed to its commit).

.PARAMETER Downloader
    Replaces the download of a release file, for tests: { param($Url, $OutFile) },
    the shape tools/New-VmfSbom.ps1 takes. Used when -UpdateBaseline moves a
    pin kept in a file of its own (SBOM-GEN-DRIFT-1), and to read a lock file
    a saved file's pin records (MERMAID-CONTENTS-1).

.PARAMETER UpdateBaseline
    Move ONE pin (-Part) to its latest release, and every reference with it:
    the Dockerfile FROM lines, the template module lines, the text references
    in scripts, each workflow uses: line of an action (its commit, read from
    GitHub, and the version comment), and for a library the files themselves, taken from the npm
    package after its integrity is checked. A file entry with a remove has
    that text removed again (MANUAL-FONTS-1: the manual theme's Google font
    import), and a release whose file no longer has it is refused. A file
    entry with a lockFile (MERMAID-CONTENTS-1) has its lock file address moved
    to the new release's tag and its sha256 read again; a new lock file that
    does not name a row it proves is refused, and the rows to read again are
    said: a library the new lock file names at more than one version, and a
    row whose text the new file no longer has. One kind of
    update per pull request, with the tests the item names for it.
    For the SBOM generator (-Part generator:anchore/syft), the version, the
    release notes link, the address and the sha256 move together. The sha256
    is the one the release's own checksums file gives, and the file is
    downloaded and refused unless its sha256 is that one.

.PARAMETER Part
    The key of the pin to move, for example image:mcr.microsoft.com/azure-powershell.

.EXAMPLE
    ./tools/Test-VmfPartPinDrift.ps1
    ./tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline -Part 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'
#>
[CmdletBinding()]
param(
    [string]$PinPath = (Join-Path $PSScriptRoot '..' 'infra' 'part-versions.json'),
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [scriptblock]$VersionProvider,
    [scriptblock]$AdvisoryProvider,
    [scriptblock]$PackageProvider,
    [scriptblock]$CommitProvider,
    [scriptblock]$Downloader,
    [switch]$UpdateBaseline,
    [string]$Part
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VmfPartPins.ps1')
. (Join-Path $PSScriptRoot '_VmfSbom.ps1')
$Root = [System.IO.Path]::GetFullPath($Root)
$pinFile = 'infra/part-versions.json'

$pin = Read-VmfPartPins -Path $PinPath

# SBOM-GEN-DRIFT-1: the pins kept in a file of their own that this script
# checks - each pinnedElsewhere entry whose check is this script. Its pin path
# is relative to the repository the pin file is in.
$selfCheck = 'tools/Test-VmfPartPinDrift.ps1'
$pinRepo = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($PinPath))) '..'))
$generators = @($pin.pinnedElsewhere | Where-Object { $_ -and [string]$_.check -eq $selfCheck })

# One such pin, read and held to its shape, as a part the readers below can
# ask: key, name, version, latest (the GitHub releases) and advisories.
function Get-VmfGeneratorPart($g) {
    $key = [string]$g.key
    if ($key -notmatch '^generator:[\w.-]+/[\w.-]+$') { throw "the pinnedElsewhere entry for $($g.pin) has the key '$key', which is not generator:<owner>/<name>." }
    if ([string]$g.latest.source -ne 'github' -or [string]$g.latest.repository -notmatch '^[\w.-]+/[\w.-]+$') {
        throw "the pinnedElsewhere entry $key names no GitHub repository to read its releases from (latest.source 'github', latest.repository 'owner/name')."
    }
    if (-not [string]$g.advisories.ecosystem -or -not [string]$g.advisories.package) {
        throw "the pinnedElsewhere entry $key names no package to ask GitHub's advisories about (advisories.ecosystem, advisories.package)."
    }
    if (-not ([string]$g.checksums).Contains('{version}') -or ([string]$g.checksums).IndexOfAny([char[]]'/\') -ge 0) {
        throw "the pinnedElsewhere entry $key names no checksums file of a release (checksums, a file name with {version})."
    }
    $file = Join-Path $pinRepo ([string]$g.pin)
    $generator = Read-VmfSbomGeneratorPin -Path $file
    [pscustomobject]@{ key = $key; name = [string]$g.name; version = [string]$generator.version; latest = $g.latest; advisories = $g.advisories; Pin = $generator; File = $file }
}
function New-VmfGeneratorEntry($g, [string]$Kind, [string]$Reason, [string]$Url) {
    [pscustomobject]@{
        path = [string]$g.name; key = [string]$g.key; kind = $Kind; reason = $Reason; url = $Url
        localDerivatives = @([string]$g.pin, 'tools/New-VmfSbom.ps1, which the release workflow runs to make the bill of materials')
    }
}

# Every request to GitHub's API sends these. Only GitHub receives the token.
function Get-VmfGitHubHeaders {
    $headers = @{
        'User-Agent'           = 'vm-migration-factory-part-pins'
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    # UPST-4: the workflow sets this; a local run stays anonymous.
    if ($env:VMF_DRIFT_TOKEN) { $headers['Authorization'] = "Bearer $env:VMF_DRIFT_TOKEN" }
    $headers
}

if (-not $VersionProvider) {
    $VersionProvider = {
        param($p)
        $source = $p.latest
        switch ($source.source) {
            'npm' {
                # The abbreviated document lists every version and is much smaller.
                $doc = Invoke-RestMethod -Uri ('https://registry.npmjs.org/' + $source.package) -Headers @{ Accept = 'application/vnd.npm.install-v1+json' } -TimeoutSec 60
                @($doc.versions.PSObject.Properties.Name)
            }
            'mcr' {
                $tags = @((Invoke-RestMethod -Uri ('https://mcr.microsoft.com/v2/' + $source.repository + '/tags/list') -TimeoutSec 60).tags)
                if ($p.tag) {
                    $shape = '^' + ([regex]::Escape([string]$p.tag)).Replace('\{version}', '(?<v>\d+\.\d+\.\d+)') + '$'
                    foreach ($t in $tags) { $m = [regex]::Match([string]$t, $shape); if ($m.Success) { $m.Groups['v'].Value } }
                }
                else { $tags }
            }
            'psgallery' {
                # The gallery answers in pages of 100; follow the next link.
                $url = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='" + $source.id + "'"
                for ($page = 0; $url -and $page -lt 20; $page++) {
                    [xml]$feed = (Invoke-WebRequest -Uri $url -TimeoutSec 60).Content
                    foreach ($entry in @($feed.feed.entry)) { if ($entry) { [string]$entry.properties.Version } }
                    $url = @($feed.feed.link | Where-Object { $_.rel -eq 'next' } | ForEach-Object { $_.href })[0]
                }
            }
            'functions-cdn' {
                # A JSON array of version strings. Invoke-RestMethod gives an
                # array as ONE object: unroll it.
                $url = 'https://cdn.functions.azure.com/public/ExtensionBundles/' + $source.id + '/index.json'
                @(Invoke-RestMethod -Uri $url -TimeoutSec 60) | ForEach-Object { $_ }
            }
            'github' {
                # PIN-ACTIONS-1: the releases, newest first, in one page of
                # 100. A tag v7.0.1 is the version 7.0.1.
                $releases = Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $source.repository + '/releases?per_page=100') -Headers (Get-VmfGitHubHeaders) -TimeoutSec 60
                foreach ($r in @($releases | ForEach-Object { $_ })) {
                    if ($r -and -not $r.draft -and -not $r.prerelease) { ([string]$r.tag_name) -replace '^v', '' }
                }
            }
            default { throw "the pin names a source this tool cannot read: '$($source.source)'." }
        }
    }
}
if (-not $CommitProvider) {
    $CommitProvider = {
        param($p, $version)
        # PIN-ACTIONS-1: the commit the tag names. An annotated tag is its own
        # object, which names the commit; follow it (a tag can name a tag).
        $repo = [string]$p.latest.repository
        $object = (Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/git/ref/tags/v' + $version) -Headers (Get-VmfGitHubHeaders) -TimeoutSec 60).object
        for ($hop = 0; $object -and $object.type -eq 'tag' -and $hop -lt 5; $hop++) {
            $object = (Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $repo + '/git/tags/' + $object.sha) -Headers (Get-VmfGitHubHeaders) -TimeoutSec 60).object
        }
        if (-not $object -or $object.type -ne 'commit') { throw "the tag v$version of $repo does not lead to a commit." }
        [string]$object.sha
    }
}
if (-not $AdvisoryProvider) {
    $AdvisoryProvider = {
        param($p)
        $headers = Get-VmfGitHubHeaders
        $affects = [uri]::EscapeDataString("$($p.advisories.package)@$($p.version)")
        $answer = Invoke-RestMethod -Uri ('https://api.github.com/advisories?ecosystem=' + $p.advisories.ecosystem + '&affects=' + $affects + '&per_page=100') -Headers $headers -TimeoutSec 60
        foreach ($one in $answer) { $one }
    }
}
if (-not $Downloader) {
    $Downloader = { param($Url, $OutFile) Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 300 }
}

# MERMAID-CONTENTS-1: a lock file recorded beside the rows it proves, read
# from its address: its sha256 (of the bytes as served) and its text. The
# download is not kept (TEMP-LITTER-1).
function Get-VmfLockFileText([string]$Url) {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-part-lock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $work
    try {
        $out = Join-Path $work 'lock'
        & $Downloader $Url $out
        if (-not (Test-Path -LiteralPath $out)) { throw "The download of $Url wrote no file." }
        $bytes = [System.IO.File]::ReadAllBytes($out)
        [pscustomobject]@{
            Sha256 = ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
            Text   = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force }
}
if (-not $PackageProvider) {
    $PackageProvider = {
        param($p, $version)
        $meta = Invoke-RestMethod -Uri ('https://registry.npmjs.org/' + $p.latest.package + '/' + $version) -TimeoutSec 60
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-part-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir
        $tgz = Join-Path $dir 'package.tgz'
        Invoke-WebRequest -Uri $meta.dist.tarball -OutFile $tgz -TimeoutSec 120
        [pscustomobject]@{ Path = $tgz; Integrity = [string]$meta.dist.integrity }
    }
}

# Where a part is used: the pin file, and every file that names it.
$refs = Find-VmfOutsidePartReferences -Root $Root
function Get-VmfPartUses($p) {
    $paths = [System.Collections.Generic.List[string]]::new()
    $paths.Add($pinFile)
    foreach ($r in $refs) { if ($r.key -eq $p.key) { $paths.Add($r.path) } }
    foreach ($f in @($p.files)) { if ($f) { $paths.Add($f.path) } }
    foreach ($t in @($p.references)) { if ($t) { $paths.Add($t.path) } }
    @($paths | Select-Object -Unique)
}
function New-VmfPartEntry($p, [string]$Kind, [string]$Reason, [string]$Url) {
    [pscustomobject]@{ path = [string]$p.name; key = [string]$p.key; kind = $Kind; reason = $Reason; url = $Url; localDerivatives = (Get-VmfPartUses $p) }
}

# The latest release a source lists, or a reason there is none.
function Get-VmfPartLatest($p) {
    $all = @(& $VersionProvider $p | ForEach-Object { [string]$_ })
    $stable = @($all | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
    if ($p.holdMajor) { $stable = @($stable | Where-Object { ([version]$_).Major -eq [int]$p.holdMajor }) }
    if (-not $stable.Count) {
        $held = if ($p.holdMajor) { " of major version $($p.holdMajor)" } else { '' }
        return [pscustomobject]@{ Version = $null; Why = "the source listed $($all.Count) version(s) and no release$held, so the pin was not compared." }
    }
    [pscustomobject]@{ Version = [string]($stable | Sort-Object { [version]$_ } | Select-Object -Last 1); Why = $null }
}

$drifted = [System.Collections.Generic.List[object]]::new()

if ($UpdateBaseline) {
    $allKeys = @(@($pin.parts.key) + @($generators.key) | Where-Object { $_ }) -join ', '
    if (-not $Part) {
        throw "Say which pin to move with -Part. One kind of update per pull request. The keys: $allKeys."
    }
    $generator = @($generators | Where-Object { [string]$_.key -eq $Part })
    $target = @($pin.parts | Where-Object { $_.key -eq $Part })
    if (-not $target.Count -and -not $generator.Count) { throw "infra/part-versions.json has no part '$Part'. The keys: $allKeys." }
}
if ($UpdateBaseline -and $generator.Count) {
    # SBOM-GEN-DRIFT-1: a pin kept in a file of its own moves as one unit: the
    # version, the release notes link, the address and the sha256, which is
    # the one the release's own checksums file gives. The file is downloaded
    # and refused unless its sha256 is that one. Nothing is written until
    # every check passed.
    $g = $generator[0]
    $gp = Get-VmfGeneratorPart $g
    $latest = Get-VmfPartLatest $gp
    if (-not $latest.Version) { throw "The pin for $Part stays at $($gp.version): $($latest.Why)" }
    $new = $latest.Version
    $old = $gp.version
    if ($new -eq $old) {
        Write-Host "$Part is already at its latest release, $new."
    }
    else {
        $notes = [string]$gp.Pin.releaseNotes
        if (-not $notes.Contains("v$old")) {
            throw "$($g.pin) gives the releaseNotes '$notes', which does not name the release v$old, so the new link cannot be made from it. Correct it, then run this again. Nothing was changed."
        }
        # Read-VmfSbomGeneratorPin holds the address to the release: it has
        # v<version>/ and _<version>_ in it.
        $newUrl = ([string]$gp.Pin.url).Replace("v$old/", "v$new/").Replace("_$($old)_", "_$($new)_")
        $newNotes = $notes.Replace("v$old", "v$new")
        $fileName = $newUrl.Substring($newUrl.LastIndexOf('/') + 1)
        $sumsName = ([string]$g.checksums).Replace('{version}', $new)
        $sumsUrl = $newUrl.Substring(0, $newUrl.LastIndexOf('/') + 1) + $sumsName
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-part-gen-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work
        try {
            $sumsFile = Join-Path $work $sumsName
            & $Downloader $sumsUrl $sumsFile
            if (-not (Test-Path -LiteralPath $sumsFile)) { throw "The download of $sumsUrl wrote no file. Nothing was changed." }
            # One line for the file: <sha256>, white space, its exact name.
            $lines = @([System.IO.File]::ReadAllLines($sumsFile) | ForEach-Object { [regex]::Match($_, '^(?<sha>[0-9a-fA-F]{64})\s+\*?(?<name>\S+)\s*$') } |
                    Where-Object { $_.Success -and $_.Groups['name'].Value -ceq $fileName })
            if ($lines.Count -ne 1) {
                throw "The release's checksums file $sumsName gives $($lines.Count) sha256 lines for $fileName, and the pin needs exactly one. Nothing was changed."
            }
            $want = $lines[0].Groups['sha'].Value.ToLowerInvariant()
            $zip = Join-Path $work $fileName
            & $Downloader $newUrl $zip
            if (-not (Test-Path -LiteralPath $zip)) { throw "The download of $newUrl wrote no file. Nothing was changed." }
            $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($got -ne $want) {
                throw "The file $newUrl has the sha256 $got, and the release's checksums file $sumsName gives $want. Nothing was changed."
            }
            $moved = $gp.Pin
            $moved.version = $new
            $moved.releaseNotes = $newNotes
            $moved.url = $newUrl
            $moved.sha256 = $want
            $moved.pinnedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $text = $moved | ConvertTo-Json -Depth 5
        }
        finally {
            # TEMP-LITTER-1: the downloads are not kept.
            Remove-Item -LiteralPath $work -Recurse -Force
        }
        [System.IO.File]::WriteAllText($gp.File, $text + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        Write-Host "$Part pinned at $new in $($g.pin): its address, release notes link, and the sha256 its release's checksums file gives. Read the release notes before you merge it."
    }
}
elseif ($UpdateBaseline) {
    $target = $target[0]
    $latest = Get-VmfPartLatest $target
    if (-not $latest.Version) { throw "The pin for $Part stays at $($target.version): $($latest.Why)" }
    $new = $latest.Version
    if ($new -eq $target.version) {
        Write-Host "$Part is already at its latest release, $new."
    }
    else {
        # Everything is prepared first, and written only when all of it is
        # ready, so a refusal (a package that fails its integrity) leaves the
        # repository as it was.
        $writes = [System.Collections.Generic.List[object]]::new()
        $unpack = $null; $pkg = $null
        if ($target.files) {
            $pkg = & $PackageProvider $target $new
            $bytes = [System.IO.File]::ReadAllBytes($pkg.Path)
            $got = 'sha512-' + [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData($bytes))
            if ($got -ne [string]$pkg.Integrity) {
                throw "The package for $Part $new does not match its integrity (the registry says $($pkg.Integrity), the download is $got). Nothing was changed."
            }
            $unpack = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-part-x-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $unpack
            & tar -xzf $pkg.Path -C $unpack
            if ($LASTEXITCODE -ne 0) { throw "tar could not unpack the package for $Part $new (exit code $LASTEXITCODE). Nothing was changed." }
            foreach ($f in @($target.files)) {
                $from = Join-Path $unpack 'package' $f.from
                if (-not (Test-Path -LiteralPath $from)) { throw "The package for $Part $new has no $($f.from). Nothing was changed." }
                # MANUAL-FONTS-1: text the pin removes goes from the new file
                # too, before anything is written. A release that no longer has
                # the text is refused: read it, then change or drop the remove.
                if ($f.PSObject.Properties['remove']) {
                    $content = [System.IO.File]::ReadAllText($from)
                    foreach ($text in @($f.remove)) {
                        if (-not $content.Contains([string]$text)) {
                            throw "The package for $Part $new has no '$text' in $($f.from), which the pin removes ($($f.removeWhy)). Read the new file, then change or drop the remove for $($f.path). Nothing was changed."
                        }
                        $content = $content.Replace([string]$text, '')
                    }
                    $writes.Add([pscustomobject]@{ Kind = 'write'; Content = $content; To = (Join-Path $Root $f.path); File = $f })
                    continue
                }
                $writes.Add([pscustomobject]@{ Kind = 'copy'; From = $from; To = (Join-Path $Root $f.path); File = $f })
            }
        }
        # MERMAID-CONTENTS-1 (2026-11-08): the lock file that proves the
        # libraries a file carries inside it moves to the new release's tag,
        # and its sha256 is read again. A new lock file that does not name a
        # row it proves is refused before anything is written: read the row
        # in it, change the row, then run this again. A row whose library the
        # new lock file names at another version as well, and a row whose
        # text the new file no longer has, are said: read each again.
        $lockMoves = [System.Collections.Generic.List[object]]::new()
        $readAgain = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @($target.files)) {
            if (-not $f -or -not $f.PSObject.Properties['lockFile']) { continue }
            $oldUrl = [string]$f.lockFile.url
            $versionPattern = Get-VmfLockFileVersionPattern ([string]$target.version)
            if ([regex]::Matches($oldUrl, $versionPattern).Count -ne 1) {
                throw "The lock file address of $($f.path), '$oldUrl', does not name the release $($target.version) once, so the address for $new cannot be made from it. Correct it, then run this again. Nothing was changed."
            }
            $newUrl = [regex]::Replace($oldUrl, $versionPattern, $new)
            $lock = Get-VmfLockFileText $newUrl
            $byLock = @(Get-VmfLockProvedRows $f)
            $gone = @($byLock | Where-Object { -not (Test-VmfLockFileNames $lock.Text ([string]$_.name) ([string]$_.version)) })
            if ($gone.Count) {
                throw "The lock file of $Part $new ($newUrl) does not name $(($gone | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '), which $($f.path) carries by its row. Read each in that lock file, change or remove the row, then run this again. Nothing was changed."
            }
            foreach ($row in $byLock) {
                $listed = @(Get-VmfLockFileVersions $lock.Text ([string]$row.name))
                if ($listed.Count -gt 1) { $readAgain.Add("$($row.name) $($row.version) (the new lock file names $($row.name) at $($listed -join ', '))") }
            }
            $write = @($writes | Where-Object { $_.File -eq $f })[0]
            if ($write) {
                $content = if ($write.Kind -eq 'write') { $write.Content } else { [System.IO.File]::ReadAllText($write.From) }
                foreach ($row in @(@($f.contains) | Where-Object { $_ -and [string]$_.evidence })) {
                    if (-not $content.Contains([string]$row.evidence)) { $readAgain.Add("$($row.name) $($row.version) (the new file does not have the text '$($row.evidence)')") }
                }
            }
            $lockMoves.Add([pscustomobject]@{ File = $f; Url = $newUrl; Sha256 = $lock.Sha256 })
        }
        # PIN-ACTIONS-1: an action moves to the commit GitHub's tag of the new
        # version names, and every uses: line takes the commit and the comment.
        $isAction = $Part -like 'action:*'
        if ($isAction) {
            $newCommit = [string](& $CommitProvider $target $new)
            if ($newCommit -cnotmatch '^[0-9a-f]{40}$') {
                throw "GitHub answered '$newCommit' for the commit of $Part $new, which is not a full commit id. Nothing was changed."
            }
            foreach ($r in @($refs | Where-Object { $_.key -eq $Part })) {
                if ($r.value -ne $target.commit) {
                    throw "$($r.path) line $($r.line) names $($r.text), and the pin is the commit $($target.commit). Run ./tools/Test-VmfPartPins.ps1 and correct the line first. Nothing was changed."
                }
                $lines = [System.IO.File]::ReadAllLines((Join-Path $Root $r.path))
                $oldLine = $lines[$r.line - 1]
                $newLine = [regex]::Replace($oldLine, '@' + $target.commit + '(?:\s*#.*)?$', { param($m) '@' + $newCommit + ' # v' + $new })
                $writes.Add([pscustomobject]@{ Kind = 'text'; Path = (Join-Path $Root $r.path); Old = $oldLine; New = $newLine })
            }
        }
        $oldValue = Get-VmfPartExpectedValue $target
        $newValue = Get-VmfPartExpectedValue $target $new
        foreach ($r in @($refs | Where-Object { $_.key -eq $Part -and -not $isAction })) {
            # PINS-COVER-2: the version is the end of the text. An image named
            # by tag AND digest ends with the digest, which only a person can
            # move with the tag.
            if (-not $r.text.EndsWith($oldValue)) {
                throw "$($r.path) line $($r.line) names $($r.text), which does not end with $($oldValue): an image named by a tag and a digest. Move it by hand with its new digest, then run this again. Nothing was changed."
            }
            $writes.Add([pscustomobject]@{ Kind = 'text'; Path = (Join-Path $Root $r.path); Old = $r.text; New = ($r.text.Substring(0, $r.text.Length - $oldValue.Length) + $newValue) })
        }
        foreach ($t in @($target.references)) {
            if (-not $t) { continue }
            $writes.Add([pscustomobject]@{ Kind = 'pattern'; Path = (Join-Path $Root $t.path); Pattern = (ConvertTo-VmfPartTextPattern $t.text); Text = $t.text })
        }
        foreach ($w in $writes) {
            switch ($w.Kind) {
                'copy' {
                    Copy-Item -LiteralPath $w.From -Destination $w.To -Force
                    $w.File.sha256 = (Get-FileHash -LiteralPath $w.To -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                'write' {
                    [System.IO.File]::WriteAllText($w.To, $w.Content, [System.Text.UTF8Encoding]::new($false))
                    $w.File.sha256 = (Get-FileHash -LiteralPath $w.To -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                'text' {
                    $content = [System.IO.File]::ReadAllText($w.Path)
                    [System.IO.File]::WriteAllText($w.Path, $content.Replace($w.Old, $w.New))
                }
                'pattern' {
                    $content = [System.IO.File]::ReadAllText($w.Path)
                    $replacement = $w.Text.Replace('{version}', $new)
                    [System.IO.File]::WriteAllText($w.Path, [regex]::Replace($content, $w.Pattern, { param($m) $replacement }))
                }
            }
        }
        # TEMP-LITTER-1: the unpacked package is not kept. A download made by
        # the default provider is in a vmf-part- folder of its own.
        if ($unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        if ($pkg -and (Split-Path -Leaf (Split-Path -Parent $pkg.Path)) -like 'vmf-part-*') { Remove-Item -LiteralPath (Split-Path -Parent $pkg.Path) -Recurse -Force }
        $target.version = $new
        if ($isAction) { $target.commit = $newCommit }
        # SBOM-1: the package address the bill of materials states moves with
        # the version. The licence stays: read the new release's, and change it
        # in the same pull request when it changed.
        if ($target.PSObject.Properties['source']) { $target.source = Get-VmfPartSourceUrl $target $new }
        foreach ($m in $lockMoves) { $m.File.lockFile.url = $m.Url; $m.File.lockFile.sha256 = $m.Sha256 }
        $pin | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PinPath -Encoding utf8NoBOM
        Write-Host "$Part pinned at $new in $PinPath, with its references. Run ./tools/Test-VmfPartPins.ps1, then the tests the item names for this kind of update."
        foreach ($m in $lockMoves) {
            Write-Host "The lock file of $($m.File.path) is now $($m.Url), sha256 $($m.Sha256). It names each row it proves."
        }
        if ($readAgain.Count) {
            Write-Host "Read these rows of contains again before you merge: $($readAgain -join '; ')."
        }
    }
}
else {
    foreach ($p in @($pin.parts)) {
        $notes = [string]$p.releaseNotes
        try {
            $latest = Get-VmfPartLatest $p
            if (-not $latest.Version) {
                $drifted.Add((New-VmfPartEntry $p 'unreachable' "$($p.key): $($latest.Why)" $notes))
            }
            elseif ([version]$latest.Version -gt [version]$p.version) {
                $drifted.Add((New-VmfPartEntry $p 'changed' "$($p.key -replace '^\w+:', '') $($latest.Version) is released, and the pin is $($p.version). Read the release notes, then move the pin." $notes))
            }
            elseif ([version]$latest.Version -lt [version]$p.version) {
                $drifted.Add((New-VmfPartEntry $p 'changed' "The pin is $($p.version), which is newer than the latest release, $($latest.Version). It was not released, or it was withdrawn." $notes))
            }
        }
        catch {
            $drifted.Add((New-VmfPartEntry $p 'unreachable' "could not read the versions of $($p.key): $($_.Exception.Message)" $notes))
        }

        # PIN-ACTIONS-1: the tag of the pinned version still names the pinned
        # commit, or its publisher moved it.
        if ([string]$p.key -like 'action:*') {
            $repo = [string]$p.latest.repository
            try {
                $now = [string](& $CommitProvider $p $p.version)
                if ($now -ne [string]$p.commit) {
                    $drifted.Add((New-VmfPartEntry $p 'changed' "The tag v$($p.version) of $repo now names the commit $now, and the pin is $($p.commit). Its publisher moved the tag: read both commits before you trust either." "https://github.com/$repo/releases/tag/v$($p.version)"))
                }
            }
            catch {
                $drifted.Add((New-VmfPartEntry $p 'unreachable' "could not read the tag v$($p.version) of $($repo): $($_.Exception.Message)" "https://github.com/$repo/releases/tag/v$($p.version)"))
            }
        }

        if ($p.advisories) {
            try {
                # Invoke-RestMethod gives a JSON array as ONE object; unroll it, or
                # every advisory arrives as one entry with all the ids joined.
                foreach ($a in @(& $AdvisoryProvider $p | ForEach-Object { $_ })) {
                    if (-not $a) { continue }
                    $drifted.Add((New-VmfPartEntry $p 'changed' "GitHub advisory $($a.ghsa_id) ($($a.severity)) names $($p.advisories.package) $($p.version): $($a.summary)" ([string]$a.html_url)))
                }
            }
            catch {
                $drifted.Add((New-VmfPartEntry $p 'unreachable' "could not read the GitHub advisories for $($p.advisories.package) $($p.version): $($_.Exception.Message)" 'https://github.com/advisories'))
            }
        }

        # MERMAID-CONTENTS-1: the lock file that proves the libraries a saved
        # file carries inside it is still the one recorded, and still names
        # each of them. A tag can be moved; a recorded sha256 says so.
        foreach ($f in @($p.files)) {
            if (-not $f -or -not $f.PSObject.Properties['lockFile']) { continue }
            $url = [string]$f.lockFile.url
            $byLock = @(Get-VmfLockProvedRows $f)
            try { $lock = Get-VmfLockFileText $url }
            catch {
                $drifted.Add((New-VmfPartEntry $p 'unreachable' "could not read the lock file of $($p.key) $($p.version) at $($url): $($_.Exception.Message)" $url))
                continue
            }
            if ($lock.Sha256 -ne [string]$f.lockFile.sha256) {
                $drifted.Add((New-VmfPartEntry $p 'changed' "The lock file of $($p.key) $($p.version) has the sha256 $($lock.Sha256), and the pin records $($f.lockFile.sha256). The tag was moved or the file changed: read it, then each row of $($f.path) it proves." $url))
            }
            $gone = @($byLock | Where-Object { -not (Test-VmfLockFileNames $lock.Text ([string]$_.name) ([string]$_.version)) })
            if ($gone.Count) {
                $drifted.Add((New-VmfPartEntry $p 'changed' "The lock file of $($p.key) $($p.version) does not name $(($gone | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '), which $($f.path) carries by its row. Read each row again." $url))
            }
        }
    }
    # SBOM-GEN-DRIFT-1: each pin kept in a file of its own that this script
    # checks: its GitHub releases, then GitHub's advisories against it.
    foreach ($g in $generators) {
        $releases = "https://github.com/$($g.latest.repository)/releases"
        try { $gp = Get-VmfGeneratorPart $g }
        catch {
            $drifted.Add((New-VmfGeneratorEntry $g 'unreachable' "could not read the pin $($g.pin): $($_.Exception.Message)" $releases))
            continue
        }
        try {
            $latest = Get-VmfPartLatest $gp
            if (-not $latest.Version) {
                $drifted.Add((New-VmfGeneratorEntry $g 'unreachable' "$($gp.key): $($latest.Why)" $releases))
            }
            elseif ([version]$latest.Version -gt [version]$gp.version) {
                $drifted.Add((New-VmfGeneratorEntry $g 'changed' "$($gp.name) $($latest.Version) is released, and the pin is $($gp.version). Read the release notes, then move the pin with -Part $($gp.key)." "$releases/tag/v$($latest.Version)"))
            }
            elseif ([version]$latest.Version -lt [version]$gp.version) {
                $drifted.Add((New-VmfGeneratorEntry $g 'changed' "The pin is $($gp.version), which is newer than the latest release, $($latest.Version). It was not released, or it was withdrawn." $releases))
            }
        }
        catch {
            $drifted.Add((New-VmfGeneratorEntry $g 'unreachable' "could not read the releases of $($gp.key): $($_.Exception.Message)" $releases))
        }
        try {
            foreach ($a in @(& $AdvisoryProvider $gp | ForEach-Object { $_ })) {
                if (-not $a) { continue }
                $drifted.Add((New-VmfGeneratorEntry $g 'changed' "GitHub advisory $($a.ghsa_id) ($($a.severity)) names $($gp.advisories.package) $($gp.version): $($a.summary)" ([string]$a.html_url)))
            }
        }
        catch {
            $drifted.Add((New-VmfGeneratorEntry $g 'unreachable' "could not read the GitHub advisories for $($gp.advisories.package) $($gp.version): $($_.Exception.Message)" 'https://github.com/advisories'))
        }
    }
    if ($drifted.Count -eq 0) { Write-Host "Every pinned part is current, and no GitHub advisory names a pinned version ($(@($pin.parts).Count) parts, $($generators.Count) pinned elsewhere)." }
    else { foreach ($d in $drifted) { Write-Host "PART PIN ($($d.kind)) $($d.path): $($d.reason)" } }
}

[pscustomobject]@{
    Checked  = @($pin.parts).Count + $generators.Count
    Drifted  = @($drifted)
    ExitCode = if ($drifted.Count -gt 0) { 1 } else { 0 }
}
