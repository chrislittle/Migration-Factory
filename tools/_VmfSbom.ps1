<#
    SBOM-1: what tools/New-VmfSbom.ps1 uses to make the release's bill of
    materials, kept apart so the unit tests run each piece with no network.

      Read-VmfSbomGeneratorPin  the pinned generator (infra/sbom-generator.json)
      Get-VmfSbomGenerator      download it, and refuse it unless its sha256 and
                                the version it reports are the pin
      Invoke-VmfSbomGenerator   syft scan dir:<root> -o spdx-json@2.3=<file>
      Add-VmfSbomParts          add the parts infra/part-versions.json lists
      Get-VmfSbomNotShipped     the trees a release does not ship (SBOM-SHIPPED-ONLY-1)
      Merge-VmfSbomDuplicatePackages  one package for each part
      Test-VmfSbomDocument      the SPDX 2.3 rules the document must keep

    WHY THE PIN FILE IS ADDED TO WHAT THE GENERATOR FOUND. syft finds a part by
    a package manager's own record of it (a package.json, a lock file, a
    workflow's uses:). The release carries none for its saved browser files,
    the engine image is named in a Dockerfile, and the template modules in
    Bicep, so syft cannot list them. infra/part-versions.json pins each of them
    and tools/Test-VmfPartPins.ps1 holds each row to the repository, so the
    document takes them from there, and says which tool added what.
#>

. (Join-Path $PSScriptRoot '_VmfPartPins.ps1')

function Read-VmfSbomGeneratorPin {
    param([Parameter(Mandatory)][string]$Path)
    $pin = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($pin.schemaVersion -ne 1) { throw "$Path has schemaVersion '$($pin.schemaVersion)'; this tool reads 1." }
    $version = [string]$pin.version
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "$Path pins '$version', which is not a version (three numbers, for example 1.2.3)." }
    if ([string]$pin.url -notmatch '^https://' -or -not ([string]$pin.url).Contains("v$version/") -or -not ([string]$pin.url).Contains("_$($version)_")) {
        throw "$Path gives the address '$($pin.url)', which is not an https address of the release $version."
    }
    if ([string]$pin.sha256 -notmatch '^[0-9a-f]{64}$') { throw "$Path gives no sha256 for the file (64 lower-case hex characters). A file nobody checked is never run." }
    if (-not [string]$pin.executable -or ([string]$pin.executable).IndexOfAny([char[]]'/\') -ge 0) { throw "$Path names no program file (executable) inside the zip." }
    $pin
}

function Get-VmfSbomGenerator {
    <#
    .SYNOPSIS
        The pinned generator, downloaded into -WorkDir and checked. Returns the
        path of the program.
    .PARAMETER Downloader
        { param($Url, $OutFile) }. Tests give a stand-in; the default downloads.
    #>
    param(
        [Parameter(Mandatory)]$Pin,
        [Parameter(Mandatory)][string]$WorkDir,
        [scriptblock]$Downloader = { param($Url, $OutFile) Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 300 }
    )
    $zip = Join-Path $WorkDir 'generator.zip'
    & $Downloader $Pin.url $zip
    if (-not (Test-Path -LiteralPath $zip)) { throw "The download of $($Pin.url) wrote no file." }
    $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne [string]$Pin.sha256) {
        throw "The file from $($Pin.url) has the sha256 $got, and the pin (infra/sbom-generator.json) records $($Pin.sha256). It was not unpacked or run."
    }
    $dir = Join-Path $WorkDir 'syft'
    Expand-Archive -LiteralPath $zip -DestinationPath $dir
    $exe = Join-Path $dir $Pin.executable
    if (-not (Test-Path -LiteralPath $exe)) { throw "The file from $($Pin.url) has no $($Pin.executable)." }
    # The sha256 proves the file; the version it reports proves the pin and
    # the file are the same release.
    $said = @(& $exe --version 2>&1 | ForEach-Object { "$_" }) -join ' '
    if ($said -notmatch ('(^|\s)' + [regex]::Escape([string]$Pin.version) + '(\s|$)')) {
        throw "The program from $($Pin.url) reports '$said', and the pin is $($Pin.version)."
    }
    $exe
}

function Invoke-VmfSbomGenerator {
    <#
    .SYNOPSIS
        syft scan dir:<Root> -o spdx-json@2.3=<OutFile>, named and versioned as
        the release. The flags are syft's own CLI reference's. Each tree that
        does not ship is left out (Get-VmfSbomNotShipped).
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$OutFile
    )
    # syft asks its update service at each start unless told not to
    # (check-for-app-update). A release must not depend on that service.
    $before = $env:SYFT_CHECK_FOR_APP_UPDATE
    $env:SYFT_CHECK_FOR_APP_UPDATE = 'false'
    try {
        # SBOM-SHIPPED-ONLY-1: each tree that does not ship, in syft's own
        # syntax for a directory scan (a pattern relative to the root starts
        # with ./).
        $exclude = @(foreach ($tree in @((Get-VmfSbomNotShipped -Root $Root).Path)) { '--exclude'; "./$tree/**" })
        $said = @(& $Executable scan "dir:$Root" -o "spdx-json@2.3=$OutFile" --source-name 'VmMigrationFactory' --source-version $Version @exclude -q 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $env:SYFT_CHECK_FOR_APP_UPDATE = $before }
    if ($code -ne 0) { throw "syft ended with exit code $code`: $($said -join ' ')" }
    if (-not (Test-Path -LiteralPath $OutFile) -or -not (Get-Item -LiteralPath $OutFile).Length) {
        throw "syft ended with exit code 0 and wrote no document to $OutFile`: $($said -join ' ')"
    }
}

# SBOM-SHIPPED-ONLY-1: the trees of the repository that a release does not
# ship. The document names only what the install runs or pulls in, so the
# generator is told to leave each of these out, and Test-VmfSbomDocument fails
# a document that still names a path in one. The run of 2026-11-03
# listed actions/checkout six times, one for each workflow file.
$script:VmfSbomNotShipped = [ordered]@{
    '.git'              = 'The history of the repository. The install reads the files at the tag.'
    '.github'           = 'The CI workflows and the actions they use. They run on GitHub only.'
    '.claude'           = 'The instructions and notes of the agents that develop the product.'
    'tests'             = 'The tests. They run in CI and on a developer computer.'
    'lab'               = 'The lab fleet builder. It deploys test machines into the lab only.'
    'infra/ci-schedule' = 'The starter of the CI runners. azd up does not deploy it.'
    'public'            = 'The files of the public repository, which the public export copies over their private twins. The install does not read them.'
}

function Get-VmfSbomNotShipped {
    <#
    .SYNOPSIS
        Each tree a release does not ship, as { Path; Why }, the path relative
        to the root with '/'. With -Root, also every folder in docs except
        manual: only the manual ships from docs (DOCS-SPLIT-1), so a docs
        folder added later is left out without a change here.
    #>
    param([string]$Root)
    foreach ($tree in $script:VmfSbomNotShipped.Keys) { [pscustomobject]@{ Path = $tree; Why = $script:VmfSbomNotShipped[$tree] } }
    if ($Root) {
        $docs = Join-Path ([System.IO.Path]::GetFullPath($Root)) 'docs'
        if (Test-Path -LiteralPath $docs) {
            foreach ($child in Get-ChildItem -LiteralPath $docs -Directory -Force | Sort-Object Name) {
                if ($child.Name -eq 'manual') { continue }
                [pscustomobject]@{ Path = "docs/$($child.Name)"; Why = 'Notes for the people who develop the product. Only docs/manual ships, inside the dashboard.' }
            }
        }
    }
}

# The key that makes two packages one part: its name, its version and its
# package urls. syft writes one package for each place it finds a part.
function Get-VmfSbomPackageKey($Package) {
    $purls = @(@($Package['externalRefs']) | Where-Object { $_ -and $_['referenceType'] -eq 'purl' } | ForEach-Object { [string]$_['referenceLocator'] } | Sort-Object -Unique)
    "$($Package['name'])|$($Package['versionInfo'])|$($purls -join ' ')"
}

function Merge-VmfSbomDuplicatePackages {
    <#
    .SYNOPSIS
        SBOM-SHIPPED-ONLY-1: one package for each part. Packages with the same
        name, version and package urls become the first of them. Its source
        locations and references take those of every copy, and every
        relationship and documentDescribes entry that named a copy names it.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    $kept = [ordered]@{}
    $moved = @{}
    foreach ($p in @($Document['packages'] | Where-Object { $_ })) {
        $key = Get-VmfSbomPackageKey $p
        if (-not $kept.Contains($key)) { $kept[$key] = $p; continue }
        $first = $kept[$key]
        $moved[[string]$p['SPDXID']] = [string]$first['SPDXID']
        $sources = @(@([string]$first['sourceInfo']) + @([string]$p['sourceInfo']) | Where-Object { $_ } | Select-Object -Unique)
        if ($sources.Count) { $first['sourceInfo'] = $sources -join '; ' }
        $refs = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($ref in @(@($first['externalRefs']) + @($p['externalRefs']) | Where-Object { $_ })) {
            if ($seen.Add("$($ref['referenceCategory'])|$($ref['referenceType'])|$($ref['referenceLocator'])")) { $refs.Add($ref) }
        }
        if ($refs.Count) { $first['externalRefs'] = $refs.ToArray() }
    }
    $Document['packages'] = @($kept.Values)
    if (-not $moved.Count) { return $Document }
    $relations = [System.Collections.Generic.List[object]]::new()
    $seenRelation = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in @($Document['relationships'] | Where-Object { $_ })) {
        foreach ($end in 'spdxElementId', 'relatedSpdxElement') {
            if ($moved.ContainsKey([string]$r[$end])) { $r[$end] = $moved[[string]$r[$end]] }
        }
        if ($seenRelation.Add("$($r['spdxElementId'])|$($r['relationshipType'])|$($r['relatedSpdxElement'])")) { $relations.Add($r) }
    }
    $Document['relationships'] = $relations.ToArray()
    if ($Document.Contains('documentDescribes')) {
        $Document['documentDescribes'] = @(@($Document['documentDescribes']) | Where-Object { $_ } | ForEach-Object { if ($moved.ContainsKey([string]$_)) { $moved[[string]$_] } else { [string]$_ } } | Select-Object -Unique)
    }
    $Document
}

# The tree a path names, when it is one that does not ship: in a file name
# ('./lab/x', '/tests/x', '.\infra\ci-schedule\x') or in syft's sourceInfo
# text ('... file: /.github/workflows/ci.yml').
function Find-VmfSbomNotShippedPath([string]$Text, [string[]]$NotShipped) {
    if (-not $Text) { return }
    foreach ($tree in $NotShipped) {
        if (-not $tree) { continue }
        $pattern = '(^|[\s:,;''"(=])\.?[/\\]?' + ([regex]::Escape($tree) -replace '/', '[/\\]') + '[/\\]'
        if ($Text -match $pattern) { return $tree }
    }
}
# An SPDX id from a key or a path: SPDX allows letters, digits, '.' and '-'.
function ConvertTo-VmfSpdxId([string]$Prefix, [string]$Text) {
    'SPDXRef-' + $Prefix + '-' + (($Text -replace '[^A-Za-z0-9.-]+', '-').Trim('-'))
}

function New-VmfNpmPurl([string]$Package, [string]$Version) {
    # The package url specification: an npm scope's '@' is written %40.
    'pkg:npm/' + $Package.Replace('@', '%40') + '@' + $Version
}

# What each kind of part the pin file lists is to the release. A kind not
# here stops the document: a new kind is a decision, never silence.
$script:VmfSbomPartKinds = @{
    'npm'       = 'contains'   # saved browser files, in the release
    'image'     = 'install'    # an image the install builds on or names
    'bicep'     = 'install'    # a template module or extension the install uses
    'psmodule'  = 'install'    # a module the service takes when it starts
    'bundle'    = 'install'    # the Functions extension bundle of the service
    'psgallery' = 'leave'      # a test tool: runs the tests, ships nowhere
    'action'    = 'leave'      # a workflow action: runs in CI, ships nowhere
}

function Add-VmfSbomParts {
    <#
    .SYNOPSIS
        The generator's SPDX 2.3 document (a hashtable, ConvertFrom-Json
        -AsHashtable), with every part infra/part-versions.json lists that
        the release contains or the install pulls in.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SPDX 2.3 requires a SHA1 checksum for every file. It identifies the file in the document; the SHA256 beside it is the one the pin checks.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)]$Pin,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ToolVersion
    )
    $Root = [System.IO.Path]::GetFullPath($Root)
    if ([string]$Document['spdxVersion'] -ne 'SPDX-2.3') {
        throw "The generator wrote '$($Document['spdxVersion'])', and the release carries SPDX-2.3."
    }
    # The element the document describes: the released commit. Found the two
    # ways SPDX 2.3 allows, and there must be exactly one.
    $described = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($Document['relationships'])) {
        if ($r -and $r['spdxElementId'] -eq 'SPDXRef-DOCUMENT' -and $r['relationshipType'] -eq 'DESCRIBES' -and -not $described.Contains([string]$r['relatedSpdxElement'])) { $described.Add([string]$r['relatedSpdxElement']) }
    }
    foreach ($id in @($Document['documentDescribes'])) { if ($id -and -not $described.Contains([string]$id)) { $described.Add([string]$id) } }
    if ($described.Count -ne 1) {
        throw "The generator's document DESCRIBES $($described.Count) elements ($($described -join ', ')), and this tool adds the parts to exactly one: the release."
    }
    $releaseId = $described[0]

    $packages = [System.Collections.Generic.List[object]]::new(); foreach ($x in @($Document['packages'])) { if ($x) { $packages.Add($x) } }
    $files = [System.Collections.Generic.List[object]]::new(); foreach ($x in @($Document['files'])) { if ($x) { $files.Add($x) } }
    $relations = [System.Collections.Generic.List[object]]::new(); foreach ($x in @($Document['relationships'])) { if ($x) { $relations.Add($x) } }
    function Add-Relation([string]$From, [string]$Type, [string]$To) {
        $relations.Add([ordered]@{ spdxElementId = $From; relatedSpdxElement = $To; relationshipType = $Type })
    }

    $entries = @(foreach ($part in @($Pin.parts)) { if ($part) { [pscustomobject]@{ part = $part; itself = $false } } }) +
        @(foreach ($entry in @($Pin.updatesItself)) { if ($entry) { [pscustomobject]@{ part = $entry; itself = $true } } })
    foreach ($e in $entries) {
        $part = $e.part
        $prefix = ([string]$part.key).Split(':')[0]
        if (-not $script:VmfSbomPartKinds.ContainsKey($prefix)) {
            throw "infra/part-versions.json lists $($part.key), and this tool does not know whether a part of that kind is in the release, pulled in by the install, or neither. Add its kind to the list in tools/_VmfSbom.ps1."
        }
        $kind = $script:VmfSbomPartKinds[$prefix]
        if ($kind -eq 'leave') { continue }
        $name = ([string]$part.key).Substring($prefix.Length + 1)
        $id = ConvertTo-VmfSpdxId 'VmfPart' $part.key

        if ($kind -eq 'contains') {
            if ($e.itself -or -not @($part.files | Where-Object { $_ }).Count) {
                throw "infra/part-versions.json lists $($part.key) with no saved files, and an npm part is in the release only as its saved files."
            }
            $name = [string]$part.latest.package
            $packages.Add([ordered]@{
                    name                  = $name
                    SPDXID                = $id
                    versionInfo           = [string]$part.version
                    supplier              = 'NOASSERTION'
                    downloadLocation      = [string]$part.source
                    filesAnalyzed         = $false
                    licenseConcluded      = 'NOASSERTION'
                    licenseDeclared       = [string]$part.license
                    copyrightText         = 'NOASSERTION'
                    externalRefs          = @([ordered]@{ referenceCategory = 'PACKAGE-MANAGER'; referenceType = 'purl'; referenceLocator = (New-VmfNpmPurl $name $part.version) })
                    primaryPackagePurpose = 'LIBRARY'
                    comment               = "$($part.name). Saved in the release as files from this package (infra/part-versions.json): each file says so with EXPANDED_FROM_ARCHIVE, or GENERATED_FROM when a text is removed from it."
                })
            Add-Relation $releaseId 'CONTAINS' $id
            foreach ($f in @($part.files)) {
                if (-not $f) { continue }
                $path = Join-Path $Root $f.path
                if (-not (Test-Path -LiteralPath $path)) { throw "infra/part-versions.json lists $($f.path) of $($part.key), and the release does not have it." }
                $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($sha256 -ne [string]$f.sha256) {
                    throw "$($f.path) has the sha256 $sha256, and its row in infra/part-versions.json records $($f.sha256). The document states only what was measured: run tools/Test-VmfPartPins.ps1."
                }
                $sha1 = (Get-FileHash -LiteralPath $path -Algorithm SHA1).Hash.ToLowerInvariant()
                $fileId = ConvertTo-VmfSpdxId 'VmfFile' $f.path
                $note = "From $($f.from) in $($part.source)."
                if ($f.PSObject.Properties['remove']) {
                    $note += " Changed from the package: the text $((@($f.remove) | ForEach-Object { "'$_'" }) -join ', ') is removed. $($f.removeWhy)"
                }
                $files.Add([ordered]@{
                        fileName           = './' + $f.path
                        SPDXID             = $fileId
                        checksums          = @([ordered]@{ algorithm = 'SHA1'; checksumValue = $sha1 }, [ordered]@{ algorithm = 'SHA256'; checksumValue = $sha256 })
                        licenseConcluded   = 'NOASSERTION'
                        licenseInfoInFiles = @('NOASSERTION')
                        copyrightText      = 'NOASSERTION'
                        comment            = $note
                    })
                # SBOM-SPDX-VALID-1. The package is the npm release (its
                # download is the .tgz), and the release holds only some of its
                # files, so its files are not analyzed - and SPDX 2.3 clause
                # 7.8.1 says such a package "shall not contain any files". The
                # v0.5.0 document said CONTAINS, and the official validator
                # rejected it. Table 68 (clause 11.1) names what the file is:
                # EXPANDED_FROM_ARCHIVE ("SPDXRef-A is expanded from the
                # archive SPDXRef-B") when it is the file in the archive, and
                # GENERATED_FROM when the pin removed a text from it.
                $fromPackage = if ($f.PSObject.Properties['remove']) { 'GENERATED_FROM' } else { 'EXPANDED_FROM_ARCHIVE' }
                Add-Relation $fileId $fromPackage $id
                foreach ($inside in @($f.contains)) {
                    if (-not $inside) { continue }
                    $insideId = ConvertTo-VmfSpdxId 'VmfInside' "$($inside.name)-$($inside.version)"
                    if (@($packages | Where-Object { $_['SPDXID'] -eq $insideId }).Count) { Add-Relation $fileId 'CONTAINS' $insideId; continue }
                    # MERMAID-CONTENTS-1: a row with no text of the file is
                    # proved by the lock file of the part's release.
                    $proof = if ([string]$inside.evidence) { "The file names it: '$($inside.evidence)'." }
                    else {
                        $problem = Get-VmfLockFileProblem $f ([string]$part.version)
                        if ($problem) { throw "$($f.path) carries $($inside.name) $($inside.version) by its row, and $problem The document states only what was proved: run tools/Test-VmfPartPins.ps1." }
                        "Its version is the one the lock file of $($part.name) $($part.version) names: $($f.lockFile.url) (sha256 $($f.lockFile.sha256))."
                    }
                    $packages.Add([ordered]@{
                            name                  = [string]$inside.name
                            SPDXID                = $insideId
                            versionInfo           = [string]$inside.version
                            supplier              = 'NOASSERTION'
                            downloadLocation      = 'NOASSERTION'
                            filesAnalyzed         = $false
                            licenseConcluded      = 'NOASSERTION'
                            licenseDeclared       = [string]$inside.license
                            copyrightText         = 'NOASSERTION'
                            externalRefs          = @([ordered]@{ referenceCategory = 'PACKAGE-MANAGER'; referenceType = 'purl'; referenceLocator = (New-VmfNpmPurl $inside.name $inside.version) })
                            primaryPackagePurpose = 'LIBRARY'
                            comment               = "Built into $($f.path). $proof"
                        })
                    Add-Relation $fileId 'CONTAINS' $insideId
                }
            }
            continue
        }

        # The install pulls it in. A pinned part at the value the repository
        # references (an image at its tag); a part that takes its own fixes at
        # the range or label that lets it, never one version it may not be.
        # PIN-RUNTIME-1: a pinned bundle is named in host.json as [x.y.z];
        # the document states the version.
        $version = if ($e.itself) { [string]$part.ref } elseif ($prefix -eq 'bundle') { [string]$part.version } else { Get-VmfPartExpectedValue $part }
        $comment = if ($e.itself) { "Takes its own fixes inside $($part.ref). $($part.why)" } elseif ($part.name) { "$($part.name). $($part.why)" } else { [string]$part.why }
        $packages.Add([ordered]@{
                name                  = $name
                SPDXID                = $id
                versionInfo           = $version
                supplier              = 'NOASSERTION'
                downloadLocation      = 'NOASSERTION'
                filesAnalyzed         = $false
                licenseConcluded      = 'NOASSERTION'
                licenseDeclared       = 'NOASSERTION'
                copyrightText         = 'NOASSERTION'
                primaryPackagePurpose = $(if ($prefix -eq 'image') { 'CONTAINER' } else { 'LIBRARY' })
                comment               = $comment
            })
        Add-Relation $releaseId 'DEPENDS_ON' $id
    }

    $Document['packages'] = $packages.ToArray()
    if ($files.Count) { $Document['files'] = $files.ToArray() }
    $Document['relationships'] = $relations.ToArray()
    if (-not $Document['creationInfo']) { $Document['creationInfo'] = [ordered]@{} }
    $Document['creationInfo']['creators'] = @(@($Document['creationInfo']['creators']) | Where-Object { $_ }) + "Tool: New-VmfSbom-$ToolVersion"
    $Document
}

# SBOM-SPDX-VALID-1: every relationship type SPDX 2.3 has (clause 11.1,
# Table 68). A type that is not here is not SPDX 2.3, and a validator
# rejects the document.
$script:VmfSpdxRelationshipTypes = @(
    'DESCRIBES', 'DESCRIBED_BY', 'CONTAINS', 'CONTAINED_BY', 'DEPENDS_ON', 'DEPENDENCY_OF', 'DEPENDENCY_MANIFEST_OF',
    'BUILD_DEPENDENCY_OF', 'DEV_DEPENDENCY_OF', 'OPTIONAL_DEPENDENCY_OF', 'PROVIDED_DEPENDENCY_OF', 'TEST_DEPENDENCY_OF',
    'RUNTIME_DEPENDENCY_OF', 'EXAMPLE_OF', 'GENERATES', 'GENERATED_FROM', 'ANCESTOR_OF', 'DESCENDANT_OF', 'VARIANT_OF',
    'DISTRIBUTION_ARTIFACT', 'PATCH_FOR', 'PATCH_APPLIED', 'COPY_OF', 'FILE_ADDED', 'FILE_DELETED', 'FILE_MODIFIED',
    'EXPANDED_FROM_ARCHIVE', 'DYNAMIC_LINK', 'STATIC_LINK', 'DATA_FILE_OF', 'TEST_CASE_OF', 'BUILD_TOOL_OF', 'DEV_TOOL_OF',
    'TEST_OF', 'TEST_TOOL_OF', 'DOCUMENTATION_OF', 'OPTIONAL_COMPONENT_OF', 'METAFILE_OF', 'PACKAGE_OF', 'AMENDS',
    'PREREQUISITE_FOR', 'HAS_PREREQUISITE', 'REQUIREMENT_DESCRIPTION_FOR', 'SPECIFICATION_FOR', 'OTHER'
)

function Test-VmfSbomDocument {
    <#
    .SYNOPSIS
        What the document breaks of the SPDX 2.3 rules a reader relies on. No
        finding is the only pass.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        # The trees that do not ship (Get-VmfSbomNotShipped -Root). With none
        # given, the fixed ones.
        [AllowEmptyCollection()][string[]]$NotShipped = @((Get-VmfSbomNotShipped).Path)
    )
    $found = [System.Collections.Generic.List[string]]::new()
    if ($Document['spdxVersion'] -ne 'SPDX-2.3') { $found.Add("spdxVersion is '$($Document['spdxVersion'])', not SPDX-2.3.") }
    if ($Document['dataLicense'] -ne 'CC0-1.0') { $found.Add("dataLicense is '$($Document['dataLicense'])'; SPDX requires CC0-1.0.") }
    if ($Document['SPDXID'] -ne 'SPDXRef-DOCUMENT') { $found.Add("The document's SPDXID is '$($Document['SPDXID'])', not SPDXRef-DOCUMENT.") }
    if (-not [string]$Document['name']) { $found.Add('The document has no name.') }
    if (-not [string]$Document['documentNamespace']) { $found.Add('The document has no documentNamespace.') }
    $info = $Document['creationInfo']
    if (-not $info -or -not [string]$info['created']) { $found.Add('creationInfo has no created time.') }
    if (-not $info -or -not @($info['creators'] | Where-Object { $_ }).Count) { $found.Add('creationInfo names no creator.') }

    $ids = [System.Collections.Generic.HashSet[string]]::new()
    $null = $ids.Add('SPDXRef-DOCUMENT')
    foreach ($element in @(@($Document['packages']) + @($Document['files']) | Where-Object { $_ })) {
        $id = [string]$element['SPDXID']
        if ($id -cnotmatch '^SPDXRef-[A-Za-z0-9.-]+$') { $found.Add("'$id' is not an SPDXID SPDX allows (SPDXRef- and letters, digits, '.' or '-').") }
        if (-not $ids.Add($id)) { $found.Add("The document has the SPDXID $id twice.") }
    }
    foreach ($p in @($Document['packages'] | Where-Object { $_ })) {
        foreach ($field in 'name', 'downloadLocation') {
            if (-not [string]$p[$field]) { $found.Add("The package $($p['SPDXID']) has no $field.") }
        }
    }
    foreach ($f in @($Document['files'] | Where-Object { $_ })) {
        if (-not [string]$f['fileName']) { $found.Add("The file $($f['SPDXID']) has no fileName.") }
        if (-not @($f['checksums'] | Where-Object { $_ -and $_['algorithm'] -eq 'SHA1' -and $_['checksumValue'] }).Count) { $found.Add("The file $($f['fileName']) has no SHA1 checksum, which SPDX 2.3 requires.") }
    }
    foreach ($r in @($Document['relationships'] | Where-Object { $_ })) {
        foreach ($end in [string]$r['spdxElementId'], [string]$r['relatedSpdxElement']) {
            if ($end -notin @('NOASSERTION', 'NONE') -and -not $ids.Contains($end)) { $found.Add("A $($r['relationshipType']) relationship names $end, and the document has no such element.") }
        }
        if ([string]$r['relationshipType'] -cnotin $script:VmfSpdxRelationshipTypes) {
            $found.Add("The relationship $($r['spdxElementId']) '$($r['relationshipType'])' $($r['relatedSpdxElement']) has a type SPDX 2.3 does not have (clause 11.1, Table 68).")
        }
    }
    # SBOM-SPDX-VALID-1: SPDX 2.3 clause 7.8.1, "If false, the package shall
    # not contain any files"; clauses 7.9 and 7.14, the verification code and
    # the licences from its files are 0..0 if false. Only an explicit false: an
    # omitted filesAnalyzed is true. The official validator (spdx-tools)
    # rejected the v0.5.0 document for the first.
    $fileIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($f in @($Document['files'] | Where-Object { $_ })) { $null = $fileIds.Add([string]$f['SPDXID']) }
    foreach ($p in @($Document['packages'] | Where-Object { $_ -and $_.Contains('filesAnalyzed') -and $_['filesAnalyzed'] -eq $false })) {
        $pkgId = [string]$p['SPDXID']
        foreach ($r in @($Document['relationships'] | Where-Object { $_ })) {
            $file = if ($r['relationshipType'] -eq 'CONTAINS' -and [string]$r['spdxElementId'] -eq $pkgId) { [string]$r['relatedSpdxElement'] }
            elseif ($r['relationshipType'] -eq 'CONTAINED_BY' -and [string]$r['relatedSpdxElement'] -eq $pkgId) { [string]$r['spdxElementId'] }
            if ($file -and $fileIds.Contains($file)) {
                $found.Add("The package $pkgId has filesAnalyzed false and a $($r['relationshipType']) relationship with the file $file. SPDX 2.3 clause 7.8.1: such a package shall not contain any files.")
            }
        }
        if ($p.Contains('packageVerificationCode') -and $p['packageVerificationCode']) { $found.Add("The package $pkgId has filesAnalyzed false and a packageVerificationCode. SPDX 2.3 clause 7.9: it must be omitted.") }
        if (@($p['licenseInfoFromFiles'] | Where-Object { $_ }).Count) { $found.Add("The package $pkgId has filesAnalyzed false and licenseInfoFromFiles. SPDX 2.3 clause 7.14: it must be omitted.") }
    }
    # SBOM-SHIPPED-ONLY-1: each part once, and nothing from a tree that does
    # not ship.
    $count = [ordered]@{}
    foreach ($p in @($Document['packages'] | Where-Object { $_ })) {
        $key = Get-VmfSbomPackageKey $p
        if ($count.Contains($key)) { $count[$key].n++ } else { $count[$key] = [pscustomobject]@{ n = 1; name = [string]$p['name']; version = [string]$p['versionInfo'] } }
    }
    foreach ($c in $count.Values) {
        if ($c.n -gt 1) { $found.Add("The package $($c.name) $($c.version) is in the document $($c.n) times. Each part must be in it once.") }
    }
    foreach ($p in @($Document['packages'] | Where-Object { $_ })) {
        foreach ($field in 'sourceInfo', 'packageFileName') {
            $tree = Find-VmfSbomNotShippedPath ([string]$p[$field]) $NotShipped
            if ($tree) { $found.Add("The package $($p['name']) $($p['versionInfo']) comes from $tree, which does not ship: '$($p[$field])'.") }
        }
    }
    foreach ($f in @($Document['files'] | Where-Object { $_ })) {
        $tree = Find-VmfSbomNotShippedPath ([string]$f['fileName']) $NotShipped
        if ($tree) { $found.Add("The file $($f['fileName']) is in $tree, which does not ship.") }
    }
    $found.ToArray()
}
