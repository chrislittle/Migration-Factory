<#
.SYNOPSIS
    SBOM-1: write the release's bill of materials, an SPDX 2.3 document.

.DESCRIPTION
    The release workflow runs this before it publishes a release, and
    tools/Publish-VmfRelease.ps1 attaches the file it writes.

      1. Download the pinned open-source generator (syft,
         infra/sbom-generator.json) into a folder of its own, and refuse it
         unless its sha256 and the version it reports are the pin.
      2. syft scan dir:<repository> -o spdx-json@2.3=<file>: the released
         commit, named VmMigrationFactory and versioned as the release, with
         each tree that does not ship left out (Get-VmfSbomNotShipped).
      3. Add the parts infra/part-versions.json lists, which syft cannot see:
         the saved browser files (with their sha256, licence and package
         address, and the libraries built into them), and what the install
         pulls in (the engine image, the template modules, the service's
         module and extension bundle). See tools/_VmfSbom.ps1.
      4. Merge the packages that name one part, check the result
         (Test-VmfSbomDocument), and write it only when it
         passes. Any failure stops the release before it exists.

.PARAMETER Version
    The release's version, the manifest's ModuleVersion (three numbers).

.PARAMETER OutFile
    Where the document is written.

.PARAMETER Executable
    A generator already on this machine. Tests give a stand-in; the release
    downloads the pinned one.

.EXAMPLE
    ./tools/New-VmfSbom.ps1 -Version 0.9.0 -OutFile ./vm-migration-factory-0.9.0.spdx.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [string]$PinPath,
    [string]$GeneratorPinPath = (Join-Path $PSScriptRoot '..' 'infra' 'sbom-generator.json'),
    [string]$Executable,
    [scriptblock]$Downloader
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VmfSbom.ps1')
$Root = [System.IO.Path]::GetFullPath($Root)
$OutFile = [System.IO.Path]::GetFullPath($OutFile)
if (-not $PinPath) { $PinPath = Join-Path $Root 'infra' 'part-versions.json' }

$pin = Read-VmfPartPins -Path $PinPath
$parent = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$work = Join-Path $parent ('vmf-sbom-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work
try {
    if (-not $Executable) {
        $generator = Read-VmfSbomGeneratorPin -Path $GeneratorPinPath
        $extra = @{}
        if ($Downloader) { $extra.Downloader = $Downloader }
        $Executable = Get-VmfSbomGenerator -Pin $generator -WorkDir $work @extra
        Write-Host "syft $($generator.version) downloaded, and its sha256 and version are the pin."
    }
    $raw = Join-Path $work 'generator.spdx.json'
    Invoke-VmfSbomGenerator -Executable $Executable -Root $Root -Version $Version -OutFile $raw
    $doc = Get-Content -LiteralPath $raw -Raw | ConvertFrom-Json -AsHashtable
    $doc = Add-VmfSbomParts -Document $doc -Pin $pin -Root $Root -ToolVersion $Version
    # SBOM-SHIPPED-ONLY-1: each part once; and a path in a tree that does
    # not ship (a generator that did not leave it out) stops the release.
    $doc = Merge-VmfSbomDuplicatePackages -Document $doc
    $found = @(Test-VmfSbomDocument -Document $doc -NotShipped @((Get-VmfSbomNotShipped -Root $Root).Path))
    if ($found.Count) { throw "The bill of materials fails its check, so it was not written: $($found -join ' ')" }
    [System.IO.File]::WriteAllText($OutFile, ($doc | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $OutFile`: $(@($doc.packages).Count) packages, $(@($doc.files).Count) files."
    [pscustomobject]@{ Path = $OutFile; Packages = @($doc.packages).Count; Files = @($doc.files).Count }
}
finally {
    # TEMP-LITTER-1: the download and the generator's own document go.
    Remove-Item -LiteralPath $work -Recurse -Force
}
