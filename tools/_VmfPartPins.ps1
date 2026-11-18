<#
    DEPS-CURRENT-1: what the two part-pin tools share - reading the pin file,
    and finding every outside part the repository references.

    Dot-sourced by tools/Test-VmfPartPins.ps1 (no network: each reference
    matches its pin, and nothing outside is unlisted) and by
    tools/Test-VmfPartPinDrift.ps1 (the daily check, and -UpdateBaseline,
    which moves the references with the pin).

    WHAT COUNTS AS AN OUTSIDE PART. The places the product takes code it did
    not write, and the key each one is listed under in
    infra/part-versions.json:
      - a Dockerfile FROM                          image:<registry>/<repository>
      - a container image named in a template      image:<registry>/<repository>
        (a quoted image name with a tag or digest, or any `image:` value, in a
        .bicep or .bicepparam file; a name built from ${...} is not one)
      - a Bicep registry module or extension       bicep:<registry>/<repository>
        (in a .bicep file, or in bicepconfig.json)
      - a workflow or action `uses:`               action:<owner>/<repo>
        (PIN-ACTIONS-1: named by its full commit id, with its version as
        the comment after it - `@<40 hex> # v1.2.3` - and pinned like any
        other part, with the commit in the pin)
      - a Functions extension bundle in a          bundle:<bundle id>
        host.json
      - a file the browser loads as code, a style,  file:<path>
        a font or a vector picture, in src/dashboard or docs/manual
        (.js, .mjs, .cjs, .css, .map, .wasm, .svg, .woff, .woff2, .ttf, .otf,
        .eot - SBOM-1 added every kind but .js, .mjs and .css), unless the pin file's
        ownFiles lists it as a file the repository wrote (PINS-COVER-2: found
        by that list, never by the file's name or its first line, so a saved
        copy with no version line is found too)
      - a module in a requirements.psd1            psmodule:<name>
    PIN-RUNTIME-1: Azure installs the last two kinds when the service starts,
    so each must name ONE version: a module version of three or four numbers,
    and a bundle version in NuGet's exact form [x.y.z]. Any other value is a
    'floating' finding, also when the pin file lists the part under
    updatesItself.
    The tests folder is left out: a fixture there is not a part the product
    ships, and the unit tests build such fixtures on purpose.
#>

. (Join-Path $PSScriptRoot '..' 'tests' 'unit' '_CodeOnly.ps1')

function Read-VmfPartPins {
    param([Parameter(Mandatory)][string]$Path)
    $pin = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($pin.schemaVersion -ne 1) { throw "$Path has schemaVersion '$($pin.schemaVersion)'; this tool reads 1." }
    foreach ($part in @($pin.parts)) {
        if ([string]$part.version -notmatch '^\d+\.\d+\.\d+$') {
            throw "$Path pins $($part.key) at '$($part.version)', which is not a version (three numbers, for example 1.2.3)."
        }
        # PIN-ACTIONS-1: a GitHub Action is pinned by the commit its version's
        # tag names, read from GitHub (-UpdateBaseline), never typed.
        if ([string]$part.key -like 'action:*') {
            $commit = $part.PSObject.Properties['commit']
            if (-not $commit -or [string]$commit.Value -cnotmatch '^[0-9a-f]{40}$') {
                throw "$Path pins $($part.key) with the commit '$(if ($commit) { $commit.Value })', which is not a full commit id (40 lower-case hex characters). Take it from GitHub with -UpdateBaseline."
            }
            if ([string]$part.latest.source -ne 'github' -or [string]$part.latest.repository -notmatch '^[\w.-]+/[\w.-]+$') {
                throw "$Path pins $($part.key) with no GitHub repository to read its releases and tags from (latest.source 'github', latest.repository 'owner/name')."
            }
        }
        # MANUAL-MERMAID-1: a floor, with the advisories it answers.
        if ($part.PSObject.Properties['minimumVersion']) {
            if ([string]$part.minimumVersion -notmatch '^\d+\.\d+\.\d+$') {
                throw "$Path gives $($part.key) the minimumVersion '$($part.minimumVersion)', which is not a version (three numbers, for example 1.2.3)."
            }
            if (-not [string]$part.minimumWhy) {
                throw "$Path gives $($part.key) a minimumVersion and no minimumWhy. Name the advisories the floor answers."
            }
        }
        # MANUAL-FONTS-1: text the pin removes from a file of the package, with
        # the reason. -UpdateBaseline removes it again from each new release.
        foreach ($f in @($part.files)) {
            if (-not $f -or -not $f.PSObject.Properties['remove']) { continue }
            foreach ($text in @($f.remove)) {
                if (-not [string]$text) { throw "$Path gives $($f.path) of $($part.key) an empty remove text. Name the exact text to remove." }
            }
            if (-not [string]$f.removeWhy) {
                throw "$Path gives $($f.path) of $($part.key) a remove and no removeWhy. Say why the text is removed from the package's file."
            }
        }
    }
    # PINS-COVER-2: the .js and .css files the repository wrote. Every other
    # one in src/dashboard and docs/manual is an outside part.
    $own = $pin.PSObject.Properties['ownFiles']
    if (-not $own -or -not $own.Value -or -not [string]$own.Value.why -or -not $own.Value.PSObject.Properties['paths']) {
        throw "$Path has no ownFiles with a why and paths: the list of the .js and .css files in src/dashboard and docs/manual that the repository wrote."
    }
    $pin
}

# SBOM-1: the kinds of file in src/dashboard and docs/manual that the browser
# loads as code, a style, a font or a vector picture. Each one is the
# repository's own (ownFiles) or a pinned part's.
$script:VmfBrowserFileTypes = @('.js', '.mjs', '.cjs', '.css', '.map', '.wasm', '.svg', '.woff', '.woff2', '.ttf', '.otf', '.eot')

# SBOM-1: the address of the package a pinned part's files come from, the one
# -UpdateBaseline downloads. Only an npm package has files today; another
# source gives no address, and the check says so rather than guess one.
function Get-VmfPartSourceUrl {
    param([Parameter(Mandatory)]$Part, [string]$Version = $Part.version)
    if ([string]$Part.latest.source -ne 'npm' -or -not [string]$Part.latest.package) { return $null }
    $package = [string]$Part.latest.package
    'https://registry.npmjs.org/' + $package + '/-/' + $package.Split('/')[-1] + '-' + $Version + '.tgz'
}

# MERMAID-CONTENTS-1 (2026-11-08): a library a saved file carries
# inside it (contains) is proved by a text of the file that names its version
# (evidence), or - when the file names no version for it - by the lock file
# of the part's release: its address at the release's tag and its sha256,
# recorded beside the rows as the file's lockFile. The lock file gives the
# exact version each library was built at, never a range. The check here has
# no network, so it holds the record to its shape: an https address that
# names the pinned release, and a sha256. The daily check
# (Test-VmfPartPinDrift.ps1) downloads it and compares both.
function Get-VmfLockProvedRows {
    param($File)
    @(@($File.contains) | Where-Object { $_ -and -not [string]$_.evidence })
}

# The pinned release's version as one part of an address: after '@', '%40'
# (an '@' in a URL), '/' or '/v', and before '/'. 11.2.3 and 1.2.30 are not
# 1.2.3.
function Get-VmfLockFileVersionPattern([string]$Version) {
    '(?<=@|%40|/v|/)' + [regex]::Escape($Version) + '(?=/)'
}

# What is wrong with a file's lockFile record for the pinned version, or
# nothing.
function Get-VmfLockFileProblem {
    param($File, [string]$Version)
    $lock = $File.PSObject.Properties['lockFile']
    if (-not $lock -or -not $lock.Value) { return "the pin records no lock file for it (lockFile: the address of the release's lock file at its tag, and its sha256)." }
    $url = [string]$lock.Value.url
    if ($url -cnotmatch '^https://[^\s]+$' -or -not [regex]::IsMatch($url, (Get-VmfLockFileVersionPattern $Version))) {
        return "its lock file address '$url' is not an https address that names the release $Version. Move it with tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline."
    }
    if ([string]$lock.Value.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        return "its lock file sha256 '$($lock.Value.sha256)' is not a sha256 (64 lower-case hex characters)."
    }
    $null
}

# A lock file names a library at a version when name@version is one of its
# keys: a line two spaces in, with the key in quotes or not, followed by ':'
# or by '(' and the peers it was resolved with (pnpm's packages and snapshots
# lists). A dependency line of an importer is further in, and is not a key.
function Test-VmfLockFileNames([string]$LockText, [string]$Name, [string]$Version) {
    [regex]::IsMatch($LockText, '(?m)^  ''?' + [regex]::Escape("$Name@$Version") + '[''(:]')
}
function Get-VmfLockFileVersions([string]$LockText, [string]$Name) {
    @([regex]::Matches($LockText, '(?m)^  ''?' + [regex]::Escape($Name) + '@(?<v>\d+\.\d+\.\d+[^''(:\s]*)[''(:]') | ForEach-Object { $_.Groups['v'].Value } | Select-Object -Unique)
}

# SBOM-1: an SPDX licence expression, as the SPDX specification writes one:
# licence ids joined by AND, OR or WITH, with brackets. NOASSERTION is not a
# licence: a file the release carries has one, and it is read from its package.
function Test-VmfSpdxLicenseExpression {
    param([string]$Expression)
    if (-not $Expression -or $Expression.Trim() -ne $Expression) { return $false }
    $tokens = @(($Expression -replace '[()]', ' ') -split '\s+' | Where-Object { $_ })
    if (-not $tokens.Count -or $Expression.Split('(').Count -ne $Expression.Split(')').Count) { return $false }
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $isOperator = $tokens[$i] -cin @('AND', 'OR', 'WITH')
        if (($i % 2) -eq 1) { if (-not $isOperator) { return $false } }
        elseif ($isOperator -or $tokens[$i] -cnotmatch '^(LicenseRef-)?[A-Za-z0-9][A-Za-z0-9.+-]*$' -or $tokens[$i] -in @('NOASSERTION', 'NONE')) { return $false }
    }
    ($tokens.Count % 2) -eq 1
}

# PINS-COVER-2: an image name with a registry (a host name with a dot) and a
# tag or a digest. Inside quotes, it tells an image from any other string.
$script:VmfImageNamePattern = '[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z0-9-]+(?::\d+)?/[a-z0-9._/-]+(?:(?::[A-Za-z0-9_][A-Za-z0-9_.-]*)(?:@sha256:[0-9a-f]{64})?|@sha256:[0-9a-f]{64})'

# An image reference as the image and its tag. A digest is not a tag, and is
# left out of both.
function Split-VmfImageReference {
    param([Parameter(Mandatory)][string]$Reference)
    $image = $Reference -replace '@sha256:[0-9a-f]+$', ''
    $tag = ''
    $colon = $image.LastIndexOf(':')
    if ($colon -gt $image.LastIndexOf('/')) { $tag = $image.Substring($colon + 1); $image = $image.Substring(0, $colon) }
    [pscustomobject]@{ Image = $image; Tag = $tag }
}

# The pin file names a reference by its key; this is the value a reference
# must have for that pin: the tag a Dockerfile names, the version a module
# names, or a file's sha256.
function Get-VmfPartExpectedValue {
    param([Parameter(Mandatory)]$Part, [string]$Version = $Part.version)
    # PIN-ACTIONS-1: an action is named by the commit its pin records.
    if ([string]$Part.key -like 'action:*') { return [string]$Part.commit }
    if ($Part.tag) { return ([string]$Part.tag).Replace('{version}', $Version) }
    $Version
}

# A text reference ("Import-Module Pester -RequiredVersion {version}") as a
# pattern that finds it with ANY version, so a second copy at another version
# is found too.
function ConvertTo-VmfPartTextPattern {
    param([Parameter(Mandatory)][string]$Text)
    $parts = $Text -split '\{version\}', 2
    if ($parts.Count -ne 2) { throw "The reference '$Text' has no {version} in it." }
    [regex]::Escape($parts[0]) + '(?<v>\d+(?:\.\d+){1,3})' + [regex]::Escape($parts[1])
}

function Get-VmfRelativePath([string]$Root, [string]$Path) {
    [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Get-VmfPartScanFiles {
    param([string]$Root)
    $skip = @('.git', 'tests', 'node_modules', '.azure')
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($item in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
            if ([System.IO.Directory]::Exists($item)) {
                if ($dir -eq $Root -and ([System.IO.Path]::GetFileName($item) -in $skip)) { continue }
                if ([System.IO.Path]::GetFileName($item) -in @('.git', 'node_modules')) { continue }
                $stack.Push($item)
            }
            else { $item }
        }
    }
}

function Find-VmfOutsidePartReferences {
    <#
    .SYNOPSIS
        Every outside part the repository under -Root references.
    .OUTPUTS
        One object per reference: key, value, path (relative, with /), line,
        and text (the exact text that names it, which -UpdateBaseline
        replaces).
    #>
    param([Parameter(Mandatory)][string]$Root)
    $Root = [System.IO.Path]::GetFullPath($Root)
    $refs = [System.Collections.Generic.List[object]]::new()
    # note: the comment after a reference on its line (PIN-ACTIONS-1: the
    # version of an action named by its commit).
    function Add-Ref($key, $value, $path, $line, $text, $note = '') {
        $refs.Add([pscustomobject]@{ key = $key; value = $value; path = $path; line = $line; text = $text; note = $note })
    }

    foreach ($file in @(Get-VmfPartScanFiles -Root $Root | Sort-Object)) {
        $name = [System.IO.Path]::GetFileName($file)
        $rel = Get-VmfRelativePath $Root $file

        # 1. Dockerfile FROM. A FROM that names an earlier stage is not a part.
        if ($name -like 'Dockerfile*' -or $name -like '*.Dockerfile') {
            $stages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $n = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                $n++
                $m = [regex]::Match($line, '^\s*FROM\s+(?:--platform=\S+\s+)?(?<ref>\S+)(?:\s+AS\s+(?<stage>\S+))?\s*$', 'IgnoreCase')
                if (-not $m.Success) { continue }
                $ref = $m.Groups['ref'].Value
                if (-not $stages.Contains($ref)) {
                    $split = Split-VmfImageReference $ref
                    Add-Ref "image:$($split.Image)" $split.Tag $rel $n $ref
                }
                if ($m.Groups['stage'].Success) { $null = $stages.Add($m.Groups['stage'].Value) }
            }
            continue
        }

        # 2. Bicep registry references, in a template (code only, so a
        # commented line is not a reference) or in bicepconfig.json. And
        # (PINS-COVER-2) a container image a template names: a quoted image
        # name with a registry and a tag or digest, or any value of an
        # `image:` property. A name built from ${...} is the product's own
        # image, which the publish builds.
        if ($name -like '*.bicep' -or $name -like '*.bicepparam' -or $name -eq 'bicepconfig.json') {
            $text = if ($name -eq 'bicepconfig.json') { [System.IO.File]::ReadAllText($file) } else { Get-VmfCodeOnly -Path $file -Language CStyle }
            $lines = $text -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($name -ne 'bicepconfig.json') {
                    $seen = [System.Collections.Generic.HashSet[int]]::new()
                    $named = @([regex]::Matches($lines[$i], "'(?<ref>$script:VmfImageNamePattern)'")) +
                    @([regex]::Matches($lines[$i], '\bimage\s*:\s*''(?<ref>[^''$\s]+)'''))
                    foreach ($m in $named) {
                        if (-not $seen.Add($m.Groups['ref'].Index)) { continue }
                        $split = Split-VmfImageReference $m.Groups['ref'].Value
                        Add-Ref "image:$($split.Image)" $split.Tag $rel ($i + 1) $m.Groups['ref'].Value
                    }
                }
                foreach ($m in [regex]::Matches($lines[$i], '[''"](?<ref>br(?<alias>/[\w-]+)?:(?<path>[^''"\s]+):(?<ver>[^''":\s]+))[''"]')) {
                    $path = $m.Groups['path'].Value
                    $key = switch ($m.Groups['alias'].Value) {
                        '' { "bicep:$path" }
                        '/public' { "bicep:mcr.microsoft.com/bicep/$path" }
                        default { "bicep:br$($m.Groups['alias'].Value)/$path" }
                    }
                    Add-Ref $key $m.Groups['ver'].Value $rel ($i + 1) $m.Groups['ref'].Value
                }
            }
            continue
        }

        # 3. Workflow and action `uses:`. A local action (./) is our own code.
        # PUBLIC-PIPELINE-1: public/.github holds the public repository's
        # workflows, which the public export copies over .github there.
        if (($rel -like '.github/*' -or $rel -like 'public/.github/*') -and ($name -like '*.yml' -or $name -like '*.yaml')) {
            $n = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                $n++
                # PINS-COVER-2: a job's container, or a service container. An
                # image from ${{ }} is chosen when the job runs.
                $m = [regex]::Match($line, '^\s*(?:-\s+)?(?:image|container):\s*[''"]?(?<ref>[^''"\s#]+)')
                if ($m.Success) {
                    if (-not $m.Groups['ref'].Value.Contains('${{')) {
                        $split = Split-VmfImageReference $m.Groups['ref'].Value
                        Add-Ref "image:$($split.Image)" $split.Tag $rel $n $m.Groups['ref'].Value
                    }
                    continue
                }
                $m = [regex]::Match($line, '^\s*(?:-\s+)?uses:\s*[''"]?(?<ref>[^''"\s#]+)')
                if (-not $m.Success) { continue }
                $ref = $m.Groups['ref'].Value
                # The comment after it, if any.
                $hash = $line.IndexOf('#', $m.Index + $m.Length)
                $note = if ($hash -ge 0) { $line.Substring($hash + 1).Trim() } else { '' }
                if ($ref.StartsWith('./')) { continue }
                if ($ref.StartsWith('docker://')) {
                    $split = Split-VmfImageReference $ref.Substring(9)
                    Add-Ref "image:$($split.Image)" $split.Tag $rel $n $ref
                    continue
                }
                $at = $ref.LastIndexOf('@')
                if ($at -lt 0) { Add-Ref "action:$ref" '' $rel $n $ref $note; continue }
                Add-Ref "action:$($ref.Substring(0, $at))" $ref.Substring($at + 1) $rel $n $ref $note
            }
            continue
        }

        # 3b. (PINS-COVER-2) A container image a template parameters file
        # names as a value.
        if ($name -like '*.parameters.json') {
            $n = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                $n++
                foreach ($m in [regex]::Matches($line, """(?<ref>$script:VmfImageNamePattern)""")) {
                    $split = Split-VmfImageReference $m.Groups['ref'].Value
                    Add-Ref "image:$($split.Image)" $split.Tag $rel $n $m.Groups['ref'].Value
                }
            }
            continue
        }

        # 4. A script or stylesheet in the dashboard or in the manual, which
        # ships inside the dashboard (DOC-4). EVERY one is read
        # (PINS-COVER-2): the pin file's ownFiles says which ones the
        # repository wrote, and any other is an outside part. A name, a
        # vendor folder or a release banner on the first line is not proof:
        # a saved copy can have none of them.
        # SBOM-1: not only scripts and styles. A saved font, an icon set in
        # vector form (an SVG can carry script) or a WebAssembly file is third-
        # party code in the release too, and the bill of materials lists only
        # what the pin file lists.
        if (($rel -like 'src/dashboard/*' -or $rel -like 'docs/manual/*') -and ([System.IO.Path]::GetExtension($name).ToLowerInvariant() -in $script:VmfBrowserFileTypes)) {
            $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            Add-Ref "file:$rel" $sha $rel 1 $rel
            continue
        }

        # 5. The Functions extension bundle a host.json names: Azure installs
        # the bundle the range allows.
        if ($name -eq 'host.json') {
            try { $hostConfig = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json }
            catch { throw "$rel is not JSON this check can read: $($_.Exception.Message)" }
            $bundle = $hostConfig.PSObject.Properties['extensionBundle']
            if ($bundle -and $bundle.Value) {
                $range = [string]$bundle.Value.version
                $line = 1
                $all = [System.IO.File]::ReadAllLines($file)
                $at = -1
                for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -match '"extensionBundle"') { $at = $i; break } }
                for ($i = [Math]::Max($at, 0); $i -lt $all.Count; $i++) {
                    if ($all[$i].Contains('"' + $range + '"')) { $line = $i + 1; break }
                }
                Add-Ref "bundle:$([string]$bundle.Value.id)" $range $rel $line $range
            }
            continue
        }

        # 6. A module the service takes from the gallery. PIN-RUNTIME-1: the
        # text is the module's line up to the end of its version, so
        # -UpdateBaseline can move it, and the line is the real one.
        if ($name -eq 'requirements.psd1') {
            $data = Import-PowerShellDataFile -LiteralPath $file
            $all = [System.IO.File]::ReadAllLines($file)
            foreach ($module in @($data.Keys | Sort-Object)) {
                $value = [string]$data[$module]
                $line = 1; $text = $module
                $pattern = '[''"]?' + [regex]::Escape($module) + '[''"]?\s*=\s*[''"]' + [regex]::Escape($value)
                for ($i = 0; $i -lt $all.Count; $i++) {
                    $m = [regex]::Match($all[$i], $pattern)
                    if ($m.Success) { $line = $i + 1; $text = $m.Value; break }
                }
                Add-Ref "psmodule:$module" $value $rel $line $text
            }
        }
    }
    , $refs.ToArray()
}

function Test-VmfPartPinsAgainst {
    <#
    .SYNOPSIS
        Each reference against its pin, and each reference against the list.
    .OUTPUTS
        One finding per problem: kind (mismatch, missing, unlisted, unused, below,
        unpinned, floating),
        key, path and detail. No finding is the only pass.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Pin, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$References)
    $Root = [System.IO.Path]::GetFullPath($Root)
    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding($kind, $key, $path, $detail) {
        $findings.Add([pscustomobject]@{ kind = $kind; key = $key; path = $path; detail = $detail })
    }

    $pinned = @{}
    foreach ($part in @($Pin.parts)) {
        if ($pinned.ContainsKey($part.key)) { Add-Finding 'mismatch' $part.key 'infra/part-versions.json' "The pin file lists $($part.key) twice." }
        $pinned[$part.key] = $part
    }
    $files = @{}
    foreach ($part in @($Pin.parts)) {
        foreach ($f in @($part.files)) { if ($f) { $files["file:$($f.path)"] = [pscustomobject]@{ part = $part; file = $f } } }
    }
    $itself = @{}
    foreach ($entry in @($Pin.updatesItself)) { if ($entry) { $itself[$entry.key] = $entry } }
    # PIN-ACTIONS-1: an action named by its commit takes no fix by itself.
    foreach ($key in @($itself.Keys)) {
        if ($key -like 'action:*') {
            Add-Finding 'mismatch' $key 'infra/part-versions.json' "updatesItself lists $key, and an action is named by its full commit id, which takes no fix by itself. Pin it under parts with its version and commit, so the daily check reports a newer release."
        }
    }
    # PINS-COVER-2: the files the repository wrote. Each must be there, and
    # none may also be a file of a pinned part.
    $own = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ownPath in @($Pin.ownFiles.paths)) {
        if (-not $ownPath) { continue }
        $null = $own.Add([string]$ownPath)
        if ($files.ContainsKey("file:$ownPath")) {
            $part = $files["file:$ownPath"].part
            Add-Finding 'mismatch' $part.key $ownPath "ownFiles lists this file as one the repository wrote, and the pin for $($part.key) lists it as a file of that part. Remove it from one of the two lists."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Root $ownPath))) {
            Add-Finding 'missing' 'ownFiles' $ownPath "ownFiles lists this file as one the repository wrote, and the repository does not have it. Remove it from ownFiles."
        }
    }

    $used = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ref in $References) {
        # PIN-RUNTIME-1: a part Azure installs when the service starts names
        # one version, or Azure picks one that nobody tested.
        $exact = switch -Wildcard ($ref.key) {
            'psmodule:*' { '^\d+(\.\d+){2,3}$' }
            'bundle:*' { '^\[\d+(\.\d+){2,3}\]$' }
            default { $null }
        }
        if ($exact -and [string]$ref.value -notmatch $exact) {
            $form = if ($ref.key -like 'bundle:*') { 'one version in the form [4.39.1]' } else { 'one version, for example 5.5.3' }
            Add-Finding 'floating' $ref.key $ref.path "Line $($ref.line) names $($ref.value), which lets Azure install a version nobody tested when the service starts. Name $form, and pin it in infra/part-versions.json."
        }
        # PIN-ACTIONS-1 (2026-11-02): a version label such as v7 is a
        # name its publisher can move to new code, and the next CI run would
        # run that code with no change here. Only a full commit id cannot move.
        if ($ref.key -like 'action:*' -and [string]$ref.value -cnotmatch '^[0-9a-f]{40}$') {
            $null = $used.Add($ref.key)
            Add-Finding 'unpinned' $ref.key $ref.path "Line $($ref.line) names $($ref.text), which is not a full commit id (40 lower-case hex characters). A publisher can move a label to new code. Name the commit with its version as the comment, from tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline."
            continue
        }
        if ($files.ContainsKey($ref.key)) {
            $f = $files[$ref.key]
            $null = $used.Add($f.part.key)
            if ($ref.value -ne $f.file.sha256) {
                Add-Finding 'mismatch' $f.part.key $ref.path "Its sha256 is $($ref.value), and the pin for $($f.part.key) $($f.part.version) records $($f.file.sha256). Take the file from the package (-UpdateBaseline), never by hand."
            }
            # MANUAL-FONTS-1: a recorded sha256 proves only that nobody changed
            # the file since; the text the pin removes must also be gone.
            if ($f.file.PSObject.Properties['remove']) {
                $saved = [System.IO.File]::ReadAllText((Join-Path $Root $ref.path))
                foreach ($text in @($f.file.remove)) {
                    if ($text -and $saved.Contains([string]$text)) {
                        Add-Finding 'mismatch' $f.part.key $ref.path "It still has '$text', which the pin for $($f.part.key) removes: $($f.file.removeWhy)"
                    }
                }
            }
            # SBOM-1: the row and the file agree on the version. A sha256 the
            # tool recorded proves the file is the one recorded, not that the
            # recorded one is the version the row names - the bill of
            # materials states the row. A first line that names the package
            # names its version too.
            $text = [System.IO.File]::ReadAllText((Join-Path $Root $ref.path))
            $banner = [regex]::Match($text.Substring(0, [Math]::Min(300, $text.Length)), '^\s*/\*!\s*(?<package>@?[\w.-]+(?:/[\w.-]+)?)\s+v(?<v>\d+\.\d+\.\d+)\b')
            if ($banner.Success -and $banner.Groups['package'].Value -eq [string]$f.part.latest.package -and $banner.Groups['v'].Value -ne [string]$f.part.version) {
                Add-Finding 'mismatch' $f.part.key $ref.path "Its first line names $($banner.Groups['package'].Value) v$($banner.Groups['v'].Value), and the pin is $($f.part.version). Take the file from the package (-UpdateBaseline), never by hand."
            }
            # SBOM-1: a library the file carries inside it (contains), with the
            # text in the file that proves its version. A new release of the
            # part can carry another version, and then that text is gone.
            foreach ($inside in @($f.file.contains)) {
                if (-not $inside) { continue }
                $label = "$($inside.name) $($inside.version)"
                if ([string]$inside.version -notmatch '^\d+\.\d+\.\d+$') {
                    Add-Finding 'mismatch' $f.part.key $ref.path "It names $($inside.name) inside it at '$($inside.version)', which is not a version (three numbers). Read the version from the file's own text."
                }
                if (-not (Test-VmfSpdxLicenseExpression ([string]$inside.license))) {
                    Add-Finding 'mismatch' $f.part.key $ref.path "It names $label inside it with the licence '$($inside.license)', which is not an SPDX licence expression. Read it from the file's own licence text."
                }
                $evidence = [string]$inside.evidence
                # MERMAID-CONTENTS-1: no text of the file names it; the lock
                # file proves it (below, once for the file).
                if (-not $evidence) { continue }
                if (-not $evidence.Contains([string]$inside.version)) {
                    Add-Finding 'mismatch' $f.part.key $ref.path "It names $label inside it with the text '$evidence', which does not name the version $($inside.version), so it proves nothing. Give the text of the file that names it."
                }
                elseif (-not $text.Contains($evidence)) {
                    Add-Finding 'mismatch' $f.part.key $ref.path "It names $label inside it, and the file does not have the text '$evidence'. A new release carries another version: read the file's own licence text, then change the entry."
                }
            }
            # MERMAID-CONTENTS-1: the rows no text of the file proves need the
            # lock file of the pinned release, recorded beside them.
            $byLock = @(Get-VmfLockProvedRows $f.file)
            if ($byLock.Count) {
                $problem = Get-VmfLockFileProblem $f.file ([string]$f.part.version)
                if ($problem) {
                    $names = ($byLock | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '
                    Add-Finding 'mismatch' $f.part.key $ref.path "It names $($byLock.Count) libraries inside it whose version no text of the file names ($names), so the lock file of $($f.part.key) $($f.part.version) must prove them, and $problem"
                }
            }
        }
        elseif ($pinned.ContainsKey($ref.key)) {
            $part = $pinned[$ref.key]
            $null = $used.Add($part.key)
            $want = Get-VmfPartExpectedValue $part
            if ($ref.value -ne $want) {
                Add-Finding 'mismatch' $part.key $ref.path "Line $($ref.line) names $($ref.value), and the pin is $want."
            }
            # PIN-ACTIONS-1: a reader sees the version only in the comment, so
            # the comment must name the version the commit is.
            elseif ($part.key -like 'action:*' -and [string]$ref.note -cne "v$($part.version)") {
                Add-Finding 'mismatch' $part.key $ref.path "Line $($ref.line) names the commit of $($part.key -replace '^action:', '') $($part.version), and its comment is '$($ref.note)'. Write '# v$($part.version)' after the commit."
            }
        }
        elseif ($ref.key -like 'file:*' -and $own.Contains($ref.path)) {
            # A file the repository wrote: not an outside part.
        }
        elseif ($itself.ContainsKey($ref.key)) {
            $null = $used.Add($ref.key)
            if ($ref.value -ne $itself[$ref.key].ref) {
                Add-Finding 'mismatch' $ref.key $ref.path "Line $($ref.line) names $($ref.value), and the pin file says $($itself[$ref.key].ref) is the reference that takes its fixes."
            }
        }
        else {
            Add-Finding 'unlisted' $ref.key $ref.path "Line $($ref.line) names $($ref.text), and infra/part-versions.json does not list it. Pin it, or list it under updatesItself with the reason it takes its own fixes, so the daily check watches it."
        }
    }

    foreach ($entry in $files.Values) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $entry.file.path))) {
            Add-Finding 'missing' $entry.part.key $entry.file.path "The pin lists this file of $($entry.part.key), and the repository does not have it."
        }
    }
    # SBOM-1: a part whose files the release carries names its licence and the
    # address of the package they came from, for the bill of materials.
    foreach ($part in @($Pin.parts)) {
        if (-not @($part.files | Where-Object { $_ }).Count) { continue }
        $license = $part.PSObject.Properties['license']
        if (-not $license -or -not [string]$license.Value) {
            Add-Finding 'missing' $part.key 'infra/part-versions.json' "The release carries files of $($part.key), and its pin names no licence. Read it from the package of $($part.version) and give it as an SPDX licence expression."
        }
        elseif (-not (Test-VmfSpdxLicenseExpression ([string]$license.Value))) {
            Add-Finding 'mismatch' $part.key 'infra/part-versions.json' "Its licence '$($license.Value)' is not an SPDX licence expression (for example MIT, or (MPL-2.0 OR Apache-2.0))."
        }
        $want = Get-VmfPartSourceUrl $part
        $source = $part.PSObject.Properties['source']
        if (-not $want) {
            Add-Finding 'missing' $part.key 'infra/part-versions.json' "The release carries files of $($part.key), and this check knows the package address of an npm package only. Teach it this source, never write an address it cannot check."
        }
        elseif (-not $source -or -not [string]$source.Value) {
            Add-Finding 'missing' $part.key 'infra/part-versions.json' "The release carries files of $($part.key), and its pin names no source. It is $want."
        }
        elseif ([string]$source.Value -ne $want) {
            Add-Finding 'mismatch' $part.key 'infra/part-versions.json' "Its source is $($source.Value), and the package of the pinned $($part.version) is $want."
        }
    }
    foreach ($part in @($Pin.parts)) {
        foreach ($t in @($part.references)) {
            if (-not $t) { continue }
            $file = Join-Path $Root $t.path
            $null = $used.Add($part.key)
            if (-not (Test-Path -LiteralPath $file)) { Add-Finding 'missing' $part.key $t.path "The pin names '$($t.text)' in this file, and the file is not there."; continue }
            $text = [System.IO.File]::ReadAllText($file)
            $found = @([regex]::Matches($text, (ConvertTo-VmfPartTextPattern $t.text)))
            if (-not $found.Count) {
                Add-Finding 'missing' $part.key $t.path "The pin names '$($t.text)' in this file, with version $($part.version), and the file does not have it."
                continue
            }
            foreach ($m in $found) {
                if ($m.Groups['v'].Value -ne $part.version) {
                    Add-Finding 'mismatch' $part.key $t.path "It names $($m.Value), and the pin for $($part.key) is $($part.version)."
                }
            }
        }
    }
    # MANUAL-MERMAID-1: a pin under its floor names a version with known
    # advisories. Compared as numbers: 1.10.0 is above 1.9.0.
    foreach ($part in @($Pin.parts)) {
        if ($part.PSObject.Properties['minimumVersion'] -and ([version]$part.version -lt [version]$part.minimumVersion)) {
            Add-Finding 'below' $part.key 'infra/part-versions.json' "The pin is $($part.version), under its floor $($part.minimumVersion): $($part.minimumWhy)"
        }
    }
    foreach ($part in @($Pin.parts)) {
        if (-not $used.Contains($part.key)) {
            Add-Finding 'unused' $part.key 'infra/part-versions.json' "Nothing in the repository uses $($part.key) any more. Remove its pin."
        }
    }
    foreach ($key in $itself.Keys) {
        if (-not $used.Contains($key)) {
            Add-Finding 'unused' $key 'infra/part-versions.json' "Nothing in the repository uses $key any more. Remove it from updatesItself."
        }
    }
    , $findings.ToArray()
}
