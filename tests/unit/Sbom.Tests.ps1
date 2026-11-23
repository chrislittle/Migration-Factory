#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SBOM-1: each release carries a bill of materials - an SPDX 2.3 document that
# says which third-party parts, at which versions, the release contains and
# the install pulls in - so a person can answer "are we affected?" the day an
# advisory is announced.
#
# HOW IT IS MADE. The release workflow runs tools/New-VmfSbom.ps1:
#   1. it downloads the pinned open-source generator (syft,
#      infra/sbom-generator.json) and refuses it unless its sha256 and the
#      version it reports are the pin;
#   2. syft writes an SPDX 2.3 document of the released commit;
#   3. syft cannot see a saved browser file (no package manager names one), so
#      the parts the pin file lists are added to it from infra/part-versions.json
#      - which is also the manifest of those files (tools/_VmfPartPins.ps1
#      holds each row to its file) - and the result is checked;
#   4. tools/Publish-VmfRelease.ps1 creates the release as a draft, attaches
#      the document, reads the attachment back, and only then publishes.
#
# No test here reaches the network or GitHub: the generator, the download and
# the GitHub API are stand-ins, and the workflow is read, never run.
BeforeAll {
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_WorkflowCommands.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'tools' '_VmfSbom.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'sbom'
    $script:fixture = Join-Path $script:repoRoot 'tests' 'fixtures' 'sbom' 'syft-dir-2.3.spdx.json'
    $script:sbomTool = Join-Path $script:repoRoot 'tools' 'New-VmfSbom.ps1'
    $script:publishTool = Join-Path $script:repoRoot 'tools' 'Publish-VmfRelease.ps1'
    $script:generatorPinPath = Join-Path $script:repoRoot 'infra' 'sbom-generator.json'

    function script:Get-VmfHex([string]$Path, [string]$Algorithm = 'SHA256') { (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant() }

    # A small release: one saved library with a library inside it, one with a
    # line the pin removed, an engine image, a template module, a service
    # module and bundle, a test tool and a workflow action.
    function script:New-VmfSbomRepo {
        $root = Join-Path $script:temp ('repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'src' 'dashboard'), (Join-Path $root 'docs' 'manual' 'vendor'), (Join-Path $root 'infra') -Force
        Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Value '/*! @contoso/lib v1.2.3 */ var lib = 1; /*! @license Sanitizer 2.0.1 */'
        Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'vendor' 'theme.css') -Value 'body { }'
        $pin = [ordered]@{
            schemaVersion = 1
            why           = 'test'
            parts         = @(
                [ordered]@{ key = 'npm:@contoso/lib'; name = 'Contoso library'; version = '1.2.3'; latest = [ordered]@{ source = 'npm'; package = '@contoso/lib' }
                    license = 'MIT'; source = 'https://registry.npmjs.org/@contoso/lib/-/lib-1.2.3.tgz'; why = 'test'
                    files = @([ordered]@{ path = 'src/dashboard/lib.min.js'; from = 'lib/lib.min.js'; sha256 = (Get-VmfHex (Join-Path $root 'src' 'dashboard' 'lib.min.js'))
                            contains = @([ordered]@{ name = 'sanitizer'; version = '2.0.1'; license = '(MPL-2.0 OR Apache-2.0)'; evidence = 'Sanitizer 2.0.1'; why = 'test' },
                                # MERMAID-CONTENTS-1: a library the file does not name, proved by the lock file of the release.
                                [ordered]@{ name = '@contoso/charts'; version = '7.9.0'; license = 'ISC' })
                            lockFile = [ordered]@{ url = 'https://raw.githubusercontent.com/contoso/lib/lib%401.2.3/pnpm-lock.yaml'; sha256 = ('b' * 64); why = 'test' } }) }
                [ordered]@{ key = 'npm:contoso-theme'; name = 'Contoso theme'; version = '4.0.0'; latest = [ordered]@{ source = 'npm'; package = 'contoso-theme' }
                    license = 'MIT'; source = 'https://registry.npmjs.org/contoso-theme/-/contoso-theme-4.0.0.tgz'; why = 'test'
                    files = @([ordered]@{ path = 'docs/manual/vendor/theme.css'; from = 'lib/theme.css'; sha256 = (Get-VmfHex (Join-Path $root 'docs' 'manual' 'vendor' 'theme.css'))
                            remove = @('@import url("https://fonts.example.com");'); removeWhy = 'the content policy refuses it' }) }
                [ordered]@{ key = 'image:mcr.microsoft.com/azure-powershell'; name = 'Engine base image'; version = '16.4.0'; tag = '{version}-ubuntu-24.04'
                    latest = [ordered]@{ source = 'mcr'; repository = 'azure-powershell' }; why = 'the base of the engine image' }
                [ordered]@{ key = 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'; name = 'Template module avm/res/web/site'; version = '0.24.0'
                    latest = [ordered]@{ source = 'mcr'; repository = 'bicep/avm/res/web/site' }; why = 'test' }
                [ordered]@{ key = 'psgallery:Pester'; name = 'Test tool Pester'; version = '5.9.1'; latest = [ordered]@{ source = 'psgallery'; id = 'Pester' }; why = 'Not shipped.' }
                # PIN-ACTIONS-1: an action is pinned by its commit, like any other part.
                [ordered]@{ key = 'action:actions/checkout'; name = 'GitHub Action actions/checkout'; version = '7.0.1'; commit = '0123456789abcdef0123456789abcdef01234567'
                    latest = [ordered]@{ source = 'github'; repository = 'actions/checkout' }; why = 'Not shipped.' }
                # PIN-RUNTIME-1: the service's module and bundle are pinned.
                [ordered]@{ key = 'psmodule:Az.Accounts'; name = 'Service module Az.Accounts'; version = '5.5.3'; latest = [ordered]@{ source = 'psgallery'; id = 'Az.Accounts' }; why = 'the service loads this version' }
                [ordered]@{ key = 'bundle:Microsoft.Azure.Functions.ExtensionBundle'; name = 'Functions extension bundle'; version = '4.39.1'; tag = '[{version}]'
                    latest = [ordered]@{ source = 'functions-cdn'; id = 'Microsoft.Azure.Functions.ExtensionBundle' }; why = 'test' }
            )
            updatesItself = @(
                [ordered]@{ key = 'image:mcr.microsoft.com/k8se/quickstart-jobs'; ref = 'latest'; why = 'a placeholder the first publish replaces' }
            )
            ownFiles      = [ordered]@{ why = 'test'; paths = @() }
        }
        $pin | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json')
        $root
    }
    function script:Read-VmfTestPin([string]$Root) { Get-Content -LiteralPath (Join-Path $Root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json }
    function script:Read-VmfFixture { Get-Content -LiteralPath $script:fixture -Raw | ConvertFrom-Json -AsHashtable }
    function script:Get-VmfPackage($Doc, [string]$Name) { @($Doc.packages | Where-Object { $_.name -eq $Name }) }
    function script:Test-VmfRelation($Doc, [string]$From, [string]$Type, [string]$To) {
        @($Doc.relationships | Where-Object { $_.spdxElementId -eq $From -and $_.relationshipType -eq $Type -and $_.relatedSpdxElement -eq $To }).Count -eq 1
    }

    # A stand-in for syft: a script that writes the fixture where -o says, and
    # records what it was asked. The real call is `syft scan dir:<root> -o
    # spdx-json@2.3=<file> ...` (syft's own CLI reference).
    function script:New-VmfFakeSyft([int]$ExitCode = 0, [switch]$WriteNothing, [string]$Body) {
        $dir = Join-Path $script:temp ('syft-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir
        $record = Join-Path $dir 'args.json'
        $content = if ($Body) { $Body } else { [System.IO.File]::ReadAllText($script:fixture) }
        [System.IO.File]::WriteAllText((Join-Path $dir 'body.json'), $content)
        $script = @'
$record = Join-Path $PSScriptRoot 'args.json'
[pscustomobject]@{ args = @($args); update = $env:SYFT_CHECK_FOR_APP_UPDATE } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $record
if ($args -contains '--version') { 'syft 1.54.1'; exit 0 }
$out = @($args | Where-Object { $_ -like 'spdx-json@2.3=*' })
if (-not __NOTHING__ -and $out.Count -eq 1) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'body.json') -Destination ($out[0].Substring('spdx-json@2.3='.Length)) }
exit __CODE__
'@
        $script = $script.Replace('__NOTHING__', $(if ($WriteNothing) { '$true' } else { '$false' })).Replace('__CODE__', [string]$ExitCode)
        Set-Content -LiteralPath (Join-Path $dir 'syft.ps1') -Value $script
        [pscustomobject]@{ Path = (Join-Path $dir 'syft.ps1'); Record = $record }
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'SBOM-1: the generator is pinned, and nothing else runs' {

    It 'the pin names one release of syft, its Windows file, that file''s sha256 and its licence' {
        $pin = Get-Content -LiteralPath $script:generatorPinPath -Raw | ConvertFrom-Json
        $pin.schemaVersion | Should -Be 1
        $pin.name | Should -Be 'syft'
        $pin.version | Should -Match '^\d+\.\d+\.\d+$'
        $pin.url | Should -Be "https://github.com/anchore/syft/releases/download/v$($pin.version)/syft_$($pin.version)_windows_amd64.zip"
        $pin.sha256 | Should -Match '^[0-9a-f]{64}$'
        $pin.license | Should -Be 'Apache-2.0' -Because 'an open-source generator'
        $pin.executable | Should -Be 'syft.exe'
        $pin.why | Should -Match 'SBOM-1'
        # The pin file reader refuses what is not a pin.
        { Read-VmfSbomGeneratorPin -Path $script:generatorPinPath } | Should -Not -Throw
    }

    It 'the part pin file names where the generator is pinned' {
        $parts = Get-Content -LiteralPath (Join-Path $script:repoRoot 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        @($parts.pinnedElsewhere.pin) | Should -Contain 'infra/sbom-generator.json'
    }

    It 'a pin with no sha256, a url of another version, or a version that is not one, is refused' -ForEach @(
        @{ Field = 'sha256'; Value = ''; Says = '*no sha256*' }
        @{ Field = 'url'; Value = 'https://github.com/anchore/syft/releases/download/v1.0.0/syft_1.54.1_windows_amd64.zip'; Says = '*not an https address of the release*' }
        @{ Field = 'url'; Value = 'https://github.com/anchore/syft/releases/download/v1.54.1/syft_1.0.0_windows_amd64.zip'; Says = '*not an https address of the release*' }
        @{ Field = 'version'; Value = 'latest'; Says = '*not a version*' }
        @{ Field = 'url'; Value = 'http://github.com/anchore/syft/releases/download/v1.54.1/syft_1.54.1_windows_amd64.zip'; Says = '*not an https address*' }
    ) {
        $pin = Get-Content -LiteralPath $script:generatorPinPath -Raw | ConvertFrom-Json
        $pin.$Field = $Value
        $file = Join-Path $script:temp ('pin-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $pin | ConvertTo-Json | Set-Content -LiteralPath $file
        { Read-VmfSbomGeneratorPin -Path $file } | Should -Throw $Says
    }

    Context 'the download' {

        BeforeAll {
            # A stand-in release file: a zip with a program that reports a
            # version, and a pin that names it.
            function script:New-VmfGeneratorZip([string]$Reports = 'syft 1.54.1') {
                $dir = Join-Path $script:temp ('zip-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                $null = New-Item -ItemType Directory -Path (Join-Path $dir 'in')
                Set-Content -LiteralPath (Join-Path $dir 'in' 'syft.ps1') -Value "'$Reports'"
                $zip = Join-Path $dir 'syft.zip'
                Compress-Archive -Path (Join-Path $dir 'in' 'syft.ps1') -DestinationPath $zip
                $pin = [pscustomobject]@{ schemaVersion = 1; name = 'syft'; version = '1.54.1'; license = 'Apache-2.0'
                    url = 'https://github.com/anchore/syft/releases/download/v1.54.1/syft_1.54.1_windows_amd64.zip'; sha256 = (Get-VmfHex $zip); executable = 'syft.ps1'; why = 'test' }
                $work = Join-Path $dir 'work'
                $null = New-Item -ItemType Directory -Path $work
                $copy = { param($Url, $OutFile) Copy-Item -LiteralPath $zip -Destination $OutFile }.GetNewClosure()
                [pscustomobject]@{ Zip = $zip; Pin = $pin; Work = $work; Downloader = $copy; Asked = $null }
            }
        }

        It 'downloads the pinned file, checks its sha256 and the version the program reports, and gives the program' {
            $g = New-VmfGeneratorZip
            $asked = [System.Collections.Generic.List[string]]::new()
            $downloader = { param($Url, $OutFile) $asked.Add($Url); Copy-Item -LiteralPath $g.Zip -Destination $OutFile }.GetNewClosure()
            $exe = Get-VmfSbomGenerator -Pin $g.Pin -WorkDir $g.Work -Downloader $downloader
            $exe | Should -Be (Join-Path $g.Work 'syft' 'syft.ps1')
            @($asked) | Should -Be @($g.Pin.url)
        }

        It 'a file whose sha256 is not the pin is refused before it is unpacked' {
            $g = New-VmfGeneratorZip
            $g.Pin.sha256 = '0' * 64
            { Get-VmfSbomGenerator -Pin $g.Pin -WorkDir $g.Work -Downloader $g.Downloader } | Should -Throw '*sha256*'
            Test-Path -LiteralPath (Join-Path $g.Work 'syft') | Should -BeFalse -Because 'nothing from a file that failed its check is unpacked'
        }

        It 'a program that reports another version is refused' {
            $g = New-VmfGeneratorZip -Reports 'syft 1.55.0'
            { Get-VmfSbomGenerator -Pin $g.Pin -WorkDir $g.Work -Downloader $g.Downloader } | Should -Throw '*1.54.1*'
        }

        It 'a zip with no program of the pinned name is refused' {
            $g = New-VmfGeneratorZip
            $g.Pin.executable = 'syft.exe'
            { Get-VmfSbomGenerator -Pin $g.Pin -WorkDir $g.Work -Downloader $g.Downloader } | Should -Throw '*has no syft.exe*'
        }
    }
}

Describe 'SBOM-1: the parts the pin file lists are added to what the generator found' {

    BeforeAll {
        $script:root = New-VmfSbomRepo
        $script:doc = Add-VmfSbomParts -Document (Read-VmfFixture) -Pin (Read-VmfTestPin $script:root) -Root $script:root -ToolVersion '1.2.3'
        $script:docRoot = 'SPDXRef-DocumentRoot-Directory-VmMigrationFactory'
    }

    It 'keeps every package the generator found, and its relationships' {
        @(Get-VmfPackage $script:doc 'contoso-widget').Count | Should -Be 1
        Test-VmfRelation $script:doc 'SPDXRef-DOCUMENT' 'DESCRIBES' $script:docRoot | Should -BeTrue
        $script:doc.spdxVersion | Should -Be 'SPDX-2.3'
    }

    It 'a saved library: its name, version, licence, package address and package url, contained in the release' {
        $p = @(Get-VmfPackage $script:doc '@contoso/lib')
        $p.Count | Should -Be 1
        $p[0].versionInfo | Should -Be '1.2.3'
        $p[0].licenseDeclared | Should -Be 'MIT'
        $p[0].downloadLocation | Should -Be 'https://registry.npmjs.org/@contoso/lib/-/lib-1.2.3.tgz'
        @($p[0].externalRefs | Where-Object referenceType -eq 'purl')[0].referenceLocator | Should -Be 'pkg:npm/%40contoso/lib@1.2.3'
        Test-VmfRelation $script:doc $script:docRoot 'CONTAINS' $p[0].SPDXID | Should -BeTrue
    }

    It 'each of its files, with the sha256 measured now and the SHA1 SPDX 2.3 asks for, expanded from the archive of its package' {
        $file = @($script:doc.files | Where-Object fileName -eq './src/dashboard/lib.min.js')
        $file.Count | Should -Be 1
        $path = Join-Path $script:root 'src' 'dashboard' 'lib.min.js'
        @($file[0].checksums | Where-Object algorithm -eq 'SHA256')[0].checksumValue | Should -Be (Get-VmfHex $path)
        @($file[0].checksums | Where-Object algorithm -eq 'SHA1')[0].checksumValue | Should -Be (Get-VmfHex $path 'SHA1')
        $pkg = @(Get-VmfPackage $script:doc '@contoso/lib')[0]
        # SBOM-SPDX-VALID-1: the package is the npm release (its download is
        # the .tgz), and its files were not analyzed, so SPDX 2.3 clause 7.8.1
        # allows it to contain no file. Table 68: "SPDXRef-A is expanded from
        # the archive SPDXRef-B".
        $pkg.filesAnalyzed | Should -BeFalse -Because 'the release holds one file of the npm package, not the package'
        Test-VmfRelation $script:doc $file[0].SPDXID 'EXPANDED_FROM_ARCHIVE' $pkg.SPDXID | Should -BeTrue
        Test-VmfRelation $script:doc $pkg.SPDXID 'CONTAINS' $file[0].SPDXID | Should -BeFalse -Because 'the official SPDX validator rejects it: package must contain no elements if files_analyzed is False'
        @($script:doc.relationships | Where-Object { $_.relationshipType -in 'CONTAINS', 'CONTAINED_BY' -and ($_.spdxElementId -eq $file[0].SPDXID -and $_.relatedSpdxElement -eq $pkg.SPDXID -or $_.spdxElementId -eq $pkg.SPDXID -and $_.relatedSpdxElement -eq $file[0].SPDXID) }).Count | Should -Be 0
    }

    It 'a file the pin changed from its package is generated from the package, not expanded from it unchanged' {
        $file = @($script:doc.files | Where-Object fileName -eq './docs/manual/vendor/theme.css')[0]
        $pkg = @(Get-VmfPackage $script:doc 'contoso-theme')[0]
        Test-VmfRelation $script:doc $file.SPDXID 'GENERATED_FROM' $pkg.SPDXID | Should -BeTrue
        Test-VmfRelation $script:doc $file.SPDXID 'EXPANDED_FROM_ARCHIVE' $pkg.SPDXID | Should -BeFalse -Because 'the file is not the one in the archive: a text is removed'
        Test-VmfRelation $script:doc $pkg.SPDXID 'CONTAINS' $file.SPDXID | Should -BeFalse
    }

    It 'a library a file carries inside it, contained in that file, with the text that proves its version' {
        $p = @(Get-VmfPackage $script:doc 'sanitizer')
        $p.Count | Should -Be 1
        $p[0].versionInfo | Should -Be '2.0.1'
        $p[0].licenseDeclared | Should -Be '(MPL-2.0 OR Apache-2.0)'
        $p[0].comment | Should -Match 'Sanitizer 2\.0\.1'
        @($p[0].externalRefs)[0].referenceLocator | Should -Be 'pkg:npm/sanitizer@2.0.1'
        $file = @($script:doc.files | Where-Object fileName -eq './src/dashboard/lib.min.js')[0]
        Test-VmfRelation $script:doc $file.SPDXID 'CONTAINS' $p[0].SPDXID | Should -BeTrue
    }

    It 'a library a file carries inside it whose version the lock file proves: contained in that file, with the lock file named' {
        $p = @(Get-VmfPackage $script:doc '@contoso/charts')
        $p.Count | Should -Be 1
        $p[0].versionInfo | Should -Be '7.9.0'
        $p[0].licenseDeclared | Should -Be 'ISC'
        @($p[0].externalRefs)[0].referenceLocator | Should -Be 'pkg:npm/%40contoso/charts@7.9.0'
        $p[0].comment | Should -Match ([regex]::Escape('https://raw.githubusercontent.com/contoso/lib/lib%401.2.3/pnpm-lock.yaml'))
        $p[0].comment | Should -Match ('b' * 64)
        $p[0].comment | Should -Not -Match "names it: ''" -Because 'a row with no evidence text has no text to quote'
        $file = @($script:doc.files | Where-Object fileName -eq './src/dashboard/lib.min.js')[0]
        Test-VmfRelation $script:doc $file.SPDXID 'CONTAINS' $p[0].SPDXID | Should -BeTrue
    }

    It 'a file the pin changed from its package says what was removed and why' {
        $file = @($script:doc.files | Where-Object fileName -eq './docs/manual/vendor/theme.css')[0]
        $file.comment | Should -Match 'fonts\.example\.com'
        $file.comment | Should -Match 'content policy'
    }

    It 'what the install pulls in: the engine image at its tag, the template module, the service module and bundle, each a dependency' {
        $image = @(Get-VmfPackage $script:doc 'mcr.microsoft.com/azure-powershell')[0]
        $image.versionInfo | Should -Be '16.4.0-ubuntu-24.04' -Because 'the tag the Dockerfile names'
        $image.comment | Should -Match 'the base of the engine image'
        Test-VmfRelation $script:doc $script:docRoot 'DEPENDS_ON' $image.SPDXID | Should -BeTrue
        $module = @(Get-VmfPackage $script:doc 'mcr.microsoft.com/bicep/avm/res/web/site')[0]
        $module.versionInfo | Should -Be '0.24.0'
        Test-VmfRelation $script:doc $script:docRoot 'DEPENDS_ON' $module.SPDXID | Should -BeTrue
        $az = @(Get-VmfPackage $script:doc 'Az.Accounts')[0]
        $az.versionInfo | Should -Be '5.5.3' -Because 'PIN-RUNTIME-1: the one version the service loads'
        $az.comment | Should -Match 'the service loads this version'
        Test-VmfRelation $script:doc $script:docRoot 'DEPENDS_ON' $az.SPDXID | Should -BeTrue
        $bundle = @(Get-VmfPackage $script:doc 'Microsoft.Azure.Functions.ExtensionBundle')
        $bundle.Count | Should -Be 1
        $bundle[0].versionInfo | Should -Be '4.39.1' -Because 'a version, not the [4.39.1] notation host.json uses to name it'
        $placeholder = @(Get-VmfPackage $script:doc 'mcr.microsoft.com/k8se/quickstart-jobs')[0]
        $placeholder.versionInfo | Should -Be 'latest' -Because 'a part that takes its own fixes is named by the label that lets it, never one version it may not be'
        $placeholder.comment | Should -Match 'Takes its own fixes inside latest'
    }

    It 'leaves out the test tools and the workflow actions: neither is in the release or the install' {
        @(Get-VmfPackage $script:doc 'Pester').Count | Should -Be 0
        @($script:doc.packages | Where-Object { $_.SPDXID -like 'SPDXRef-VmfPart-action*' }).Count | Should -Be 0
    }

    It 'names itself beside the generator as a maker of the document' {
        @($script:doc.creationInfo.creators) | Should -Contain 'Tool: syft-1.54.1'
        @($script:doc.creationInfo.creators) | Should -Contain 'Tool: New-VmfSbom-1.2.3'
    }

    It 'the result passes the document check' {
        @(Test-VmfSbomDocument -Document $script:doc) | Should -BeNullOrEmpty
    }

    It 'a saved file whose sha256 is not its row is refused: the document never states a sha256 nobody measured' {
        $root = New-VmfSbomRepo
        Add-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Value '// edited'
        { Add-VmfSbomParts -Document (Read-VmfFixture) -Pin (Read-VmfTestPin $root) -Root $root -ToolVersion '1.2.3' } | Should -Throw '*sha256*'
    }

    It 'a part of a kind it does not know is refused: a new kind is a decision, never silence' {
        $root = New-VmfSbomRepo
        $pin = Read-VmfTestPin $root
        $pin.updatesItself += [pscustomobject]@{ key = 'pip:contoso'; ref = '1.*'; why = 'test' }
        { Add-VmfSbomParts -Document (Read-VmfFixture) -Pin $pin -Root $root -ToolVersion '1.2.3' } | Should -Throw '*pip:contoso*'
    }

    It 'a document that is not SPDX 2.3 is refused' {
        $doc = Read-VmfFixture
        $doc.spdxVersion = 'SPDX-2.2'
        { Add-VmfSbomParts -Document $doc -Pin (Read-VmfTestPin $script:root) -Root $script:root -ToolVersion '1.2.3' } | Should -Throw '*SPDX-2.3*'
    }

    It 'a document that describes no root, or two, is refused' {
        $none = Read-VmfFixture
        $none.relationships = @($none.relationships | Where-Object { $_.relationshipType -ne 'DESCRIBES' })
        { Add-VmfSbomParts -Document $none -Pin (Read-VmfTestPin $script:root) -Root $script:root -ToolVersion '1.2.3' } | Should -Throw '*DESCRIBES*'
        $two = Read-VmfFixture
        $two.relationships = @($two.relationships) + @(@{ spdxElementId = 'SPDXRef-DOCUMENT'; relatedSpdxElement = 'SPDXRef-Package-python-contoso-widget-0000000000000001'; relationshipType = 'DESCRIBES' })
        { Add-VmfSbomParts -Document $two -Pin (Read-VmfTestPin $script:root) -Root $script:root -ToolVersion '1.2.3' } | Should -Throw '*DESCRIBES*'
    }

    It 'a root named in documentDescribes is found too' {
        $doc = Read-VmfFixture
        $doc.relationships = @($doc.relationships | Where-Object { $_.relationshipType -ne 'DESCRIBES' })
        $doc.documentDescribes = @('SPDXRef-DocumentRoot-Directory-VmMigrationFactory')
        $out = Add-VmfSbomParts -Document $doc -Pin (Read-VmfTestPin $script:root) -Root $script:root -ToolVersion '1.2.3'
        Test-VmfRelation $out 'SPDXRef-DocumentRoot-Directory-VmMigrationFactory' 'CONTAINS' @(Get-VmfPackage $out '@contoso/lib')[0].SPDXID | Should -BeTrue
    }
}

Describe 'SBOM-1: the document check' {

    BeforeAll {
        $goodRoot = New-VmfSbomRepo
        $script:good = Add-VmfSbomParts -Document (Read-VmfFixture) -Pin (Read-VmfTestPin $goodRoot) -Root $goodRoot -ToolVersion '1.2.3'
        function script:Copy-VmfDoc { $script:good | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
    }

    It 'a second element with one SPDXID is a finding' {
        $doc = Copy-VmfDoc
        $doc.packages = @($doc.packages) + @($doc.packages[0])
        @(Test-VmfSbomDocument -Document $doc) -join ' ' | Should -Match 'twice'
    }

    It 'a relationship to an element the document does not have is a finding' {
        $doc = Copy-VmfDoc
        $doc.relationships = @($doc.relationships) + @(@{ spdxElementId = 'SPDXRef-DOCUMENT'; relatedSpdxElement = 'SPDXRef-Nobody'; relationshipType = 'DESCRIBES' })
        @(Test-VmfSbomDocument -Document $doc) -join ' ' | Should -Match 'SPDXRef-Nobody'
    }

    It 'an SPDXID SPDX does not allow is a finding' {
        $doc = Copy-VmfDoc
        $doc.packages[0].SPDXID = 'SPDXRef-has space'
        @(Test-VmfSbomDocument -Document $doc) -join ' ' | Should -Match 'has space'
    }

    It 'a package with no download location, or a file with no SHA1, is a finding' {
        $doc = Copy-VmfDoc
        $doc.packages[0].Remove('downloadLocation')
        $doc.files[0].checksums = @(@($doc.files[0].checksums) | Where-Object { $_.algorithm -ne 'SHA1' })
        $found = @(Test-VmfSbomDocument -Document $doc)
        $found -join ' ' | Should -Match 'downloadLocation'
        $found -join ' ' | Should -Match 'SHA1'
    }

    It 'a document with no data licence, namespace or creation time is a finding for each' {
        $doc = Copy-VmfDoc
        $doc.dataLicense = 'MIT'
        $doc.Remove('documentNamespace')
        $doc.creationInfo.Remove('created')
        @(Test-VmfSbomDocument -Document $doc).Count | Should -Be 3
    }

    # SBOM-SPDX-VALID-1: SPDX 2.3 clause 7.8.1, "If false, the package shall
    # not contain any files", and clauses 7.9 and 7.14 (0..0 if false). The
    # v0.5.0 document broke the first, and the official validator rejected it.
    Context 'a package whose files were not analyzed (SBOM-SPDX-VALID-1)' {

        BeforeAll {
            function script:Get-VmfNotAnalyzedPart($Doc) { @($Doc.packages | Where-Object { $_.name -eq '@contoso/lib' })[0] }
            function script:Get-VmfSavedFile($Doc) { @($Doc.files | Where-Object { $_.fileName -eq './src/dashboard/lib.min.js' })[0] }
        }

        It 'that CONTAINS a file is a finding that names the package, the file and the clause' {
            $doc = Copy-VmfDoc
            $pkg = Get-VmfNotAnalyzedPart $doc
            $file = Get-VmfSavedFile $doc
            $doc.relationships = @($doc.relationships) + @(@{ spdxElementId = $pkg.SPDXID; relatedSpdxElement = $file.SPDXID; relationshipType = 'CONTAINS' })
            $found = @(Test-VmfSbomDocument -Document $doc)
            $found.Count | Should -Be 1
            $found[0] | Should -Match ([regex]::Escape($pkg.SPDXID))
            $found[0] | Should -Match ([regex]::Escape($file.SPDXID))
            $found[0] | Should -Match '7\.8'
        }

        It 'that a file is CONTAINED_BY is a finding' {
            $doc = Copy-VmfDoc
            $pkg = Get-VmfNotAnalyzedPart $doc
            $file = Get-VmfSavedFile $doc
            $doc.relationships = @($doc.relationships) + @(@{ spdxElementId = $file.SPDXID; relatedSpdxElement = $pkg.SPDXID; relationshipType = 'CONTAINED_BY' })
            $found = @(Test-VmfSbomDocument -Document $doc)
            $found.Count | Should -Be 1
            $found[0] | Should -Match ([regex]::Escape($pkg.SPDXID))
        }

        It 'that CONTAINS another package is not a finding: clause 7.8.1 names files only' {
            $doc = Copy-VmfDoc
            $root = 'SPDXRef-DocumentRoot-Directory-VmMigrationFactory'
            @($doc.packages | Where-Object SPDXID -eq $root)[0].filesAnalyzed | Should -BeFalse -Because 'the root syft writes is a package whose files were not analyzed'
            Test-VmfRelation $doc $root 'CONTAINS' (Get-VmfNotAnalyzedPart $doc).SPDXID | Should -BeTrue
            @(Test-VmfSbomDocument -Document $doc) | Should -BeNullOrEmpty
        }

        It 'whose files were analyzed, or that does not say, may contain a file' -ForEach @(
            @{ Analyzed = $true }
            @{ Analyzed = $null }
        ) {
            $doc = Copy-VmfDoc
            $pkg = Get-VmfNotAnalyzedPart $doc
            if ($null -eq $Analyzed) { $pkg.Remove('filesAnalyzed') } else { $pkg.filesAnalyzed = $Analyzed }
            $doc.relationships = @($doc.relationships) + @(@{ spdxElementId = $pkg.SPDXID; relatedSpdxElement = (Get-VmfSavedFile $doc).SPDXID; relationshipType = 'CONTAINS' })
            @(Test-VmfSbomDocument -Document $doc) | Should -BeNullOrEmpty
        }

        It 'with a package verification code, or licences from its files, is a finding for each' {
            $doc = Copy-VmfDoc
            $pkg = Get-VmfNotAnalyzedPart $doc
            $pkg.packageVerificationCode = @{ packageVerificationCodeValue = ('0' * 40) }
            $pkg.licenseInfoFromFiles = @('MIT')
            $found = @(Test-VmfSbomDocument -Document $doc)
            $found.Count | Should -Be 2
            $found -join ' ' | Should -Match 'packageVerificationCode'
            $found -join ' ' | Should -Match 'licenseInfoFromFiles'
        }

        It 'an empty list of licences from its files is not a finding' {
            $doc = Copy-VmfDoc
            (Get-VmfNotAnalyzedPart $doc).licenseInfoFromFiles = @()
            @(Test-VmfSbomDocument -Document $doc) | Should -BeNullOrEmpty
        }
    }

    It 'a relationship type SPDX 2.3 does not have is a finding (SBOM-SPDX-VALID-1)' {
        $doc = Copy-VmfDoc
        $doc.relationships[0].relationshipType = 'EXPANDED_FROM'
        @(Test-VmfSbomDocument -Document $doc) -join ' ' | Should -Match 'EXPANDED_FROM'
    }
}

Describe 'SBOM-1: tools/New-VmfSbom.ps1 runs the generator and writes the document' {

    It 'asks syft for SPDX 2.3 of the released commit, named and versioned, with no update check, and writes the checked document' {
        $root = New-VmfSbomRepo
        $syft = New-VmfFakeSyft
        $out = Join-Path $script:temp ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
        $r = & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null
        $asked = Get-Content -LiteralPath $syft.Record -Raw | ConvertFrom-Json
        $a = @($asked.args)
        $a[0] | Should -Be 'scan'
        $a | Should -Contain "dir:$root"
        @($a | Where-Object { $_ -like 'spdx-json@2.3=*' }).Count | Should -Be 1
        $a[[array]::IndexOf($a, '--source-name') + 1] | Should -Be 'VmMigrationFactory'
        $a[[array]::IndexOf($a, '--source-version') + 1] | Should -Be '1.2.3'
        $a | Should -Contain './.git/**'
        $asked.update | Should -Be 'false' -Because 'a release must not depend on syft reaching its update service'
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable
        $doc.spdxVersion | Should -Be 'SPDX-2.3'
        @($doc.packages | Where-Object name -eq '@contoso/lib').Count | Should -Be 1
        $r.Path | Should -Be $out
        $env:SYFT_CHECK_FOR_APP_UPDATE | Should -BeNullOrEmpty -Because 'the setting is put back after the call'
    }

    It 'a generator that fails stops the release, and names its exit code' {
        $root = New-VmfSbomRepo
        $syft = New-VmfFakeSyft -ExitCode 3
        $out = Join-Path $script:temp 'never.spdx.json'
        { & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null } | Should -Throw '*exit code 3*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'a generator that writes nothing stops the release: an empty answer is never a document' {
        $root = New-VmfSbomRepo
        $syft = New-VmfFakeSyft -WriteNothing
        { & $script:sbomTool -Version '1.2.3' -OutFile (Join-Path $script:temp 'none.spdx.json') -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null } | Should -Throw '*wrote no document*'
    }

    It 'a document that fails its check is not written' {
        $root = New-VmfSbomRepo
        $bad = Read-VmfFixture
        $bad.Remove('documentNamespace')
        $syft = New-VmfFakeSyft -Body ($bad | ConvertTo-Json -Depth 20)
        $out = Join-Path $script:temp 'bad.spdx.json'
        { & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null } | Should -Throw '*documentNamespace*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'a library inside a file with no text of the file and no lock file to prove it stops the document (MERMAID-CONTENTS-1)' {
        $root = New-VmfSbomRepo
        $pinFile = Join-Path $root 'infra' 'part-versions.json'
        $pin = Get-Content -LiteralPath $pinFile -Raw | ConvertFrom-Json
        @($pin.parts[0].files)[0].PSObject.Properties.Remove('lockFile')
        $pin | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pinFile
        $syft = New-VmfFakeSyft
        $out = Join-Path $script:temp ('nolock-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
        { & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath $pinFile -Executable $syft.Path 6>$null } | Should -Throw '*@contoso/charts 7.9.0*lock file*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'a version that is not one is refused before anything runs' {
        $syft = New-VmfFakeSyft
        { & $script:sbomTool -Version 'v1.2.3; rm' -OutFile (Join-Path $script:temp 'x.spdx.json') -Executable $syft.Path 6>$null } | Should -Throw
        Test-Path -LiteralPath $syft.Record | Should -BeFalse
    }

    It 'the repository as it stands makes a document that passes its check' {
        # The real pin file and the real saved files, with the stand-in syft.
        $syft = New-VmfFakeSyft
        $out = Join-Path $script:temp ('repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
        & $script:sbomTool -Version '1.2.3' -OutFile $out -Executable $syft.Path 6>$null | Out-Null
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in '@azure/msal-browser', 'docsify', 'mermaid', 'dompurify', '@azure/msal-common', 'mcr.microsoft.com/azure-powershell') {
            @($doc.packages | Where-Object name -eq $name).Count | Should -Be 1 -Because $name
        }
        @($doc.files | Where-Object fileName -eq './docs/manual/vendor/mermaid.min.js').Count | Should -Be 1
        # SBOM-SPDX-VALID-1: each saved file of each npm part is expanded from
        # (or, when the pin changed it, generated from) its package, and no
        # package whose files were not analyzed contains a file. The v0.5.0
        # document broke this for these three parts.
        $pinRows = Get-Content -LiteralPath (Join-Path $script:repoRoot 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        foreach ($part in @($pinRows.parts | Where-Object { ([string]$_.key).StartsWith('npm:') })) {
            $pkg = @($doc.packages | Where-Object { $_.name -eq $part.latest.package -and $_.versionInfo -eq $part.version })[0]
            $pkg.filesAnalyzed | Should -BeFalse
            foreach ($f in @($part.files)) {
                $saved = @($doc.files | Where-Object fileName -eq ('./' + $f.path))[0]
                $type = if ($f.PSObject.Properties['remove']) { 'GENERATED_FROM' } else { 'EXPANDED_FROM_ARCHIVE' }
                Test-VmfRelation $doc $saved.SPDXID $type $pkg.SPDXID | Should -BeTrue -Because "$($f.path) $type $($part.key)"
            }
        }
        $fileIds = @($doc.files | ForEach-Object { $_.SPDXID })
        $notAnalyzed = @($doc.packages | Where-Object { $_.filesAnalyzed -eq $false } | ForEach-Object { $_.SPDXID })
        @($doc.relationships | Where-Object { $_.relationshipType -eq 'CONTAINS' -and $_.spdxElementId -in $notAnalyzed -and $_.relatedSpdxElement -in $fileIds }).Count | Should -Be 0
        # MERMAID-CONTENTS-1: each library built into the diagram file is a
        # package of its own, at its version, contained in that file.
        $mermaidFile = @($doc.files | Where-Object fileName -eq './docs/manual/vendor/mermaid.min.js')[0]
        $pin = Get-Content -LiteralPath (Join-Path $script:repoRoot 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        $rows = @(@(@($pin.parts | Where-Object key -eq 'npm:mermaid')[0].files)[0].contains)
        $rows.Count | Should -BeGreaterThan 1
        foreach ($row in $rows) {
            $pkg = @($doc.packages | Where-Object { $_.name -eq $row.name -and $_.versionInfo -eq $row.version })
            $pkg.Count | Should -Be 1 -Because "$($row.name) $($row.version)"
            Test-VmfRelation $doc $mermaidFile.SPDXID 'CONTAINS' $pkg[0].SPDXID | Should -BeTrue -Because "$($row.name) $($row.version)"
        }
        foreach ($name in 'd3', 'langium', 'lodash-es', 'katex') { @($doc.packages | Where-Object name -eq $name).Count | Should -BeGreaterThan 0 -Because $name }
    }
}

Describe 'SBOM-1: tools/Publish-VmfRelease.ps1 publishes only a release that has its bill of materials' {

    BeforeAll {
        # A stand-in GitHub API that records each call and answers like the
        # real one: a release with an id and an upload address.
        # RELEASE-DRAFT-RERUN-1: -Existing is what the releases list holds
        # before the run, on its first page; -SecondPage is page 2.
        function script:New-VmfFakeGitHub([switch]$UploadFails, [switch]$AssetMissing, [switch]$StaysDraft, [object[]]$Existing = @(), [object[]]$SecondPage = @(), [object[]]$DraftAssets = @()) {
            $state = [pscustomobject]@{ Calls = [System.Collections.Generic.List[object]]::new(); Uploaded = $null }
            $rest = {
                param($Method, $Uri, $Body, $InFile, $ContentType)
                $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body; InFile = $InFile; ContentType = $ContentType })
                if ($Method -eq 'Get' -and $Uri -match '^https://api\.github\.com/repos/contoso/vmf/releases\?per_page=100&page=(\d+)$') {
                    $page = [int]$matches[1]
                    if ($page -eq 1) { return , @($Existing) }
                    if ($page -eq 2) { return , @($SecondPage) }
                    return , @()
                }
                if ($Method -eq 'Get' -and $Uri -eq 'https://api.github.com/repos/contoso/vmf/releases/41/assets') {
                    if ($state.Uploaded) { return , @([pscustomobject]@{ id = 10; name = 'vm-migration-factory-1.2.3.spdx.json'; size = $state.Uploaded; state = 'uploaded' }) }
                    return , @($DraftAssets)
                }
                if ($Method -eq 'Delete' -and $Uri -like 'https://api.github.com/repos/contoso/vmf/releases/assets/*') { return $null }
                if ($Method -eq 'Patch' -and $Uri -eq 'https://api.github.com/repos/contoso/vmf/releases/41') {
                    return [pscustomobject]@{ id = 41; tag_name = 'v1.2.3'; draft = [bool]$StaysDraft; html_url = 'https://github.com/contoso/vmf/releases/tag/v1.2.3' }
                }
                if ($Method -eq 'Post' -and $Uri -eq 'https://api.github.com/repos/contoso/vmf/releases') {
                    return [pscustomobject]@{ id = 42; tag_name = 'v1.2.3'; draft = $true; html_url = 'https://github.com/contoso/vmf/releases/tag/v1.2.3'; upload_url = 'https://uploads.github.com/repos/contoso/vmf/releases/42/assets{?name,label}' }
                }
                if ($Method -eq 'Post' -and $Uri -like 'https://uploads.github.com/*') {
                    if ($UploadFails) { throw 'Response status code does not indicate success: 500' }
                    $state.Uploaded = (Get-Item -LiteralPath $InFile).Length
                    return [pscustomobject]@{ id = 7; name = 'x'; state = 'uploaded' }
                }
                if ($Method -eq 'Get' -and $Uri -eq 'https://api.github.com/repos/contoso/vmf/releases/42/assets') {
                    if ($AssetMissing) { return , @() }
                    return , @([pscustomobject]@{ name = 'vm-migration-factory-1.2.3.spdx.json'; size = $state.Uploaded; state = 'uploaded' })
                }
                if ($Method -eq 'Patch' -and $Uri -eq 'https://api.github.com/repos/contoso/vmf/releases/42') {
                    return [pscustomobject]@{ id = 42; tag_name = 'v1.2.3'; draft = [bool]$StaysDraft; html_url = 'https://github.com/contoso/vmf/releases/tag/v1.2.3' }
                }
                throw "unexpected call $Method $Uri"
            }.GetNewClosure()
            [pscustomobject]@{ State = $state; Rest = $rest }
        }
        $script:sbomFile = Join-Path $script:temp 'vm-migration-factory-1.2.3.spdx.json'
        Set-Content -LiteralPath $script:sbomFile -Value '{ "spdxVersion": "SPDX-2.3" }'
        function script:Invoke-VmfPublish($Fake, [string]$Version = '1.2.3', [string]$Sbom = $script:sbomFile) {
            & $script:publishTool -Repository 'contoso/vmf' -Version $Version -SbomPath $Sbom -Rest $Fake.Rest 6>$null
        }
    }

    It 'creates a draft, attaches the document, reads the attachment back, and only then publishes' {
        $gh = New-VmfFakeGitHub
        $r = Invoke-VmfPublish $gh
        $calls = @($gh.State.Calls)
        @($calls.Method) | Should -Be @('Get', 'Post', 'Post', 'Get', 'Patch')
        $calls[0].Uri | Should -Be 'https://api.github.com/repos/contoso/vmf/releases?per_page=100&page=1' -Because 'it looks for a release of the tag before it creates anything'
        $calls = @($calls | Select-Object -Skip 1)
        $create = $calls[0].Body | ConvertFrom-Json
        $create.draft | Should -BeTrue -Because 'nobody sees a release before its bill of materials is on it'
        $create.tag_name | Should -Be 'v1.2.3'
        $create.name | Should -Be 'v1.2.3'
        $create.generate_release_notes | Should -BeTrue
        $calls[1].Uri | Should -Be 'https://uploads.github.com/repos/contoso/vmf/releases/42/assets?name=vm-migration-factory-1.2.3.spdx.json'
        $calls[1].InFile | Should -Be $script:sbomFile
        ($calls[3].Body | ConvertFrom-Json).draft | Should -BeFalse
        $r.Asset | Should -Be 'vm-migration-factory-1.2.3.spdx.json'
    }

    It 'below 1.0.0 the release is a pre-release, and from 1.0.0 it is not' {
        # Only the body of the create is read here; the stand-in lists the
        # 1.2.3 file, so the attachment check stops each of these after it.
        foreach ($case in @(@{ Version = '0.9.0'; Pre = $true }, @{ Version = '1.0.0'; Pre = $false }, @{ Version = '1.2.3'; Pre = $false })) {
            $gh = New-VmfFakeGitHub
            $file = Join-Path $script:temp "vm-migration-factory-$($case.Version).spdx.json"
            Set-Content -LiteralPath $file -Value '{}'
            try { Invoke-VmfPublish $gh $case.Version $file | Out-Null } catch { $null = $_ }
            (@($gh.State.Calls | Where-Object Method -eq 'Post')[0].Body | ConvertFrom-Json).prerelease | Should -Be $case.Pre -Because $case.Version
        }
    }

    It 'no document: nothing is created at all' {
        $gh = New-VmfFakeGitHub
        { Invoke-VmfPublish $gh '1.2.3' (Join-Path $script:temp 'absent.spdx.json') } | Should -Throw '*absent.spdx.json*'
        $gh.State.Calls.Count | Should -Be 0
    }

    It 'an attachment that fails leaves the release a draft, and says so' {
        $gh = New-VmfFakeGitHub -UploadFails
        { Invoke-VmfPublish $gh } | Should -Throw '*draft*'
        @($gh.State.Calls.Method) | Should -Not -Contain 'Patch'
    }

    It 'an attachment the release does not list afterwards leaves it a draft: the upload''s own answer is not proof' {
        $gh = New-VmfFakeGitHub -AssetMissing
        { Invoke-VmfPublish $gh } | Should -Throw '*draft*'
        @($gh.State.Calls.Method) | Should -Not -Contain 'Patch'
    }

    It 'a release GitHub still reports as a draft after the publish is a failure, never a success' {
        $gh = New-VmfFakeGitHub -StaysDraft
        { Invoke-VmfPublish $gh } | Should -Throw '*draft*'
    }

    # RELEASE-DRAFT-RERUN-1 (fault g of 2026-11-19): a run for a tag that
    # already had a release left a second draft, because the tool created a
    # draft before it looked.
    It 'REFUSES a tag that already has a published release, and creates, uploads and changes nothing' {
        $gh = New-VmfFakeGitHub -Existing @([pscustomobject]@{ id = 40; tag_name = 'v1.2.3'; draft = $false; html_url = 'https://github.com/contoso/vmf/releases/tag/v1.2.3' })
        { Invoke-VmfPublish $gh } | Should -Throw '*v1.2.3*already*releases/tag/v1.2.3*'
        @($gh.State.Calls.Method) | Should -Be @('Get') -Because 'a refusal comes before anything is made'
    }

    It 'finds the release on a later page of the list too' {
        $gh = New-VmfFakeGitHub -Existing @(1..100 | ForEach-Object { [pscustomobject]@{ id = $_; tag_name = "v0.0.$_"; draft = $false; html_url = 'x' } }) `
            -SecondPage @([pscustomobject]@{ id = 40; tag_name = 'v1.2.3'; draft = $false; html_url = 'https://github.com/contoso/vmf/releases/tag/v1.2.3' })
        { Invoke-VmfPublish $gh } | Should -Throw '*already*'
        @($gh.State.Calls.Method) | Should -Not -Contain 'Post'
    }

    It 'a release of another tag is no reason to stop' {
        $gh = New-VmfFakeGitHub -Existing @([pscustomobject]@{ id = 39; tag_name = 'v1.2.2'; draft = $false; html_url = 'x' }, [pscustomobject]@{ id = 38; tag_name = 'v1.2.30'; draft = $true; html_url = 'y' })
        (Invoke-VmfPublish $gh).Asset | Should -Be 'vm-migration-factory-1.2.3.spdx.json'
        @($gh.State.Calls | Where-Object { $_.Method -eq 'Post' -and $_.Uri -eq 'https://api.github.com/repos/contoso/vmf/releases' }).Count | Should -Be 1
    }

    It 'REUSES the one draft an earlier failed run of the same version left: no second release, its old attachment replaced' {
        $gh = New-VmfFakeGitHub -Existing @([pscustomobject]@{ id = 41; tag_name = 'v1.2.3'; draft = $true; html_url = 'https://github.com/contoso/vmf/releases/tag/untagged-1'; upload_url = 'https://uploads.github.com/repos/contoso/vmf/releases/41/assets{?name,label}' }) `
            -DraftAssets @([pscustomobject]@{ id = 9; name = 'vm-migration-factory-1.2.3.spdx.json'; size = 1; state = 'uploaded' })
        $r = Invoke-VmfPublish $gh
        $calls = @($gh.State.Calls)
        @($calls | Where-Object { $_.Method -eq 'Post' -and $_.Uri -eq 'https://api.github.com/repos/contoso/vmf/releases' }) | Should -BeNullOrEmpty -Because 'one tag has one release'
        @($calls | Where-Object Method -eq 'Delete').Uri | Should -Be @('https://api.github.com/repos/contoso/vmf/releases/assets/9')
        $upload = @($calls | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like 'https://uploads.github.com/*' })
        $upload.Uri | Should -Be @('https://uploads.github.com/repos/contoso/vmf/releases/41/assets?name=vm-migration-factory-1.2.3.spdx.json')
        $calls.IndexOf(@($calls | Where-Object Method -eq 'Delete')[0]) | Should -BeLessThan $calls.IndexOf($upload[0]) -Because 'the old file goes before the new one comes'
        @($calls | Where-Object Method -eq 'Patch').Uri | Should -Be @('https://api.github.com/repos/contoso/vmf/releases/41')
        $r.Tag | Should -Be 'v1.2.3'
    }

    It 'REFUSES when the tag has more than one draft, names them, and changes nothing' {
        $gh = New-VmfFakeGitHub -Existing @(
            [pscustomobject]@{ id = 41; tag_name = 'v1.2.3'; draft = $true; html_url = 'https://github.com/contoso/vmf/releases/tag/untagged-1' }
            [pscustomobject]@{ id = 43; tag_name = 'v1.2.3'; draft = $true; html_url = 'https://github.com/contoso/vmf/releases/tag/untagged-2' })
        { Invoke-VmfPublish $gh } | Should -Throw '*2 drafts*untagged-1*untagged-2*'
        @($gh.State.Calls.Method) | Should -Be @('Get')
    }
}

# PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its own
# runners (tools/Initialize-VmfCiRunner.ps1). Neither ships, and the public workflows are
# different files, so there this is skipped.
Describe 'SBOM-1: the release workflow makes the document and attaches it' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    BeforeAll {
        # RELEASE-FLOW-RESTORE-1: one job again, after the CI check and the tag.
        $script:releasePath = Join-Path $script:repoRoot '.github' 'workflows' 'release.yml'
        $script:steps = @(Get-VmfWorkflowSteps -Path $script:releasePath)
        $script:make = @($script:steps | Where-Object Name -eq 'Make the bill of materials')
        $script:publish = @($script:steps | Where-Object Name -eq 'Publish the release')
        $script:versionStep = @($script:steps | Where-Object Name -eq 'Read the version that was released')
        $script:yaml = Get-Content -LiteralPath $script:releasePath -Raw
    }

    It 'has one step that makes it, on both ways in, after the version is read and before the release is published' {
        $script:make.Count | Should -Be 1
        $script:make[0].If | Should -BeNullOrEmpty -Because 'the button and a pushed tag both release, so both carry the document'
        $script:make[0].Line | Should -BeGreaterThan $script:versionStep[0].Line
        $script:publish[0].Line | Should -BeGreaterThan $script:make[0].Line -Because 'a generator that fails must stop the release before it exists'
    }

    It 'the step runs the tool with the released version, and the publish attaches the file it wrote' {
        $script:make[0].Script | Should -Match '\./tools/New-VmfSbom\.ps1 -Version \$env:VMF_VERSION -OutFile \$sbom'
        $script:publish[0].Script | Should -Match '\./tools/Publish-VmfRelease\.ps1 '
        $script:publish[0].Script | Should -Match '-SbomPath \$sbom'
        foreach ($s in $script:make[0], $script:publish[0]) {
            $s.Script | Should -Match ([regex]::Escape('$sbom = Join-Path $env:RUNNER_TEMP "vm-migration-factory-$env:VMF_VERSION.spdx.json"'))
        }
    }

    It 'the version reaches the scripts through the environment, never written into them' {
        # A value GitHub writes into a script is part of the script. The version
        # is checked text, and the environment keeps it that way anyway.
        $block = [regex]::Match($script:yaml, '(?s)- name: Make the bill of materials(.*?)(?=\r?\n      - name: )').Groups[1].Value
        $block | Should -Match 'VMF_VERSION: \$\{\{ steps\.version\.outputs\.number \}\}'
        # The last step since WORKFLOWS-UNUSED-1, so it may end at the file's end.
        $publishBlock = [regex]::Match($script:yaml, '(?s)- name: Publish the release(.*?)(?=\r?\n      - name: |\z)').Groups[1].Value
        $publishBlock | Should -Match 'VMF_VERSION: \$\{\{ steps\.version\.outputs\.number \}\}'
        $script:publish[0].Script | Should -Match '-Repository \$env:GITHUB_REPOSITORY'
        $script:make[0].Script | Should -Not -Match '\$\{\{'
        $script:publish[0].Script | Should -Not -Match '\$\{\{'
    }

}

Describe 'SBOM-SHIPPED-ONLY-1: the list names only what ships, and each part once' {
    # A run on 2026-11-03 (syft 1.54.1) listed actions/checkout v7
    # six times and azure/login v3 three times: one entry for each workflow
    # file. The workflows run on GitHub and never reach the install, and one
    # part named many times is a wrong count. The stand-in output below has
    # that shape.

    BeforeAll {
        $script:actionsFixture = Join-Path $script:repoRoot 'tests' 'fixtures' 'sbom' 'syft-dir-2.3-actions.spdx.json'
        function script:Read-VmfActionsFixture { Get-Content -LiteralPath $script:actionsFixture -Raw | ConvertFrom-Json -AsHashtable }
        function script:Get-VmfElementIds($Doc) { @(@($Doc.packages) + @($Doc.files) | Where-Object { $_ } | ForEach-Object { $_.SPDXID }) + 'SPDXRef-DOCUMENT' }
        $script:shippedRoot = 'SPDXRef-DocumentRoot-Directory-VmMigrationFactory'
    }

    Context 'what the generator scans' {

        It 'the stand-in output has the shape the real run had' {
            $doc = Read-VmfActionsFixture
            @(Get-VmfPackage $doc 'actions/checkout').Count | Should -Be 6
            @(Get-VmfPackage $doc 'azure/login').Count | Should -Be 3
        }

        It 'leaves out each tree that does not ship, and every docs folder except the manual' {
            $out = @(Get-VmfSbomNotShipped -Root $script:repoRoot)
            $paths = @($out.Path)
            # PUBLIC-SYNC-1: a docs folder that does not ship to the public
            # repository is not there to list; the loop below reads each that is.
            foreach ($tree in @('.git', '.github', '.claude', 'tests', 'lab', 'infra/ci-schedule', 'docs/backlog', 'docs/research', 'docs/architecture').Where({
                        $_ -notlike 'docs/*' -or (Test-Path (Join-Path $script:repoRoot $_)) })) {
                $paths | Should -Contain $tree
            }
            foreach ($ships in 'src', 'docs/manual', 'docs', 'infra', 'infra/hooks', 'docker', 'tools', 'schemas') {
                $paths | Should -Not -Contain $ships
            }
            foreach ($child in Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'docs') -Directory) {
                if ($child.Name -eq 'manual') { continue }
                $paths | Should -Contain "docs/$($child.Name)" -Because 'only the manual ships from docs (DOCS-SPLIT-1)'
            }
            foreach ($row in $out) { [string]$row.Why | Should -Not -BeNullOrEmpty -Because "$($row.Path) must say why it does not ship" }
        }

        It 'a docs folder added later is left out too, and the manual never is' {
            $root = Join-Path $script:temp ('docs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'manual'), (Join-Path $root 'docs' 'later-notes')
            $paths = @((Get-VmfSbomNotShipped -Root $root).Path)
            $paths | Should -Contain 'docs/later-notes'
            $paths | Should -Not -Contain 'docs/manual'
            $paths | Should -Contain '.github' -Because 'a tree that does not ship is left out whether or not it is there'
        }

        It 'with no root, it still names the fixed trees' {
            $paths = @((Get-VmfSbomNotShipped).Path)
            $paths | Should -Contain '.github'
            $paths | Should -Contain 'lab'
        }

        It 'the install never reads a tree that is left out' {
            . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
            $install = @(
                @{ Path = (Join-Path $script:repoRoot 'azure.yaml'); Language = 'Shell' }
                @{ Path = (Join-Path $script:repoRoot 'infra' 'main.bicep'); Language = 'CStyle' }
                @{ Path = (Join-Path $script:repoRoot 'infra' 'platform.bicep'); Language = 'CStyle' }
            ) + @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'infra' 'hooks') -Filter '*.ps1' | ForEach-Object { @{ Path = $_.FullName; Language = 'PowerShell' } }) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'infra') -Filter '*.ps1' | ForEach-Object { @{ Path = $_.FullName; Language = 'PowerShell' } }) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot 'docker') -Recurse -Filter 'Dockerfile' | ForEach-Object { @{ Path = $_.FullName; Language = 'Shell' } })
            $install.Count | Should -BeGreaterThan 6
            foreach ($tree in @((Get-VmfSbomNotShipped -Root $script:repoRoot).Path)) {
                $pattern = '(^|[^A-Za-z0-9_.-])' + ([regex]::Escape($tree) -replace '/', '[/\\]') + '[/\\]'
                foreach ($file in $install) {
                    Get-VmfCodeOnly -Path $file.Path -Language $file.Language | Should -Not -Match $pattern -Because "$($file.Path) is part of the install, and $tree is left out of the bill of materials"
                }
            }
        }

        It 'syft is asked to leave out each of them, with its own syntax for a directory scan' {
            $root = New-VmfSbomRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'backlog')
            $syft = New-VmfFakeSyft
            $out = Join-Path $script:temp ('ex-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
            & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null | Out-Null
            $a = @((Get-Content -LiteralPath $syft.Record -Raw | ConvertFrom-Json).args)
            $excluded = @(for ($i = 0; $i -lt $a.Count - 1; $i++) { if ($a[$i] -eq '--exclude') { $a[$i + 1] } })
            foreach ($tree in '.git', '.github', '.claude', 'tests', 'lab', 'infra/ci-schedule', 'docs/backlog') {
                $excluded | Should -Contain "./$tree/**"
            }
            $excluded | Should -Not -Contain './docs/manual/**'
            $excluded | Should -Not -Contain './docs/**'
        }
    }

    Context 'each part once' {

        It 'six entries of one action at one version become one, and so do three of another, with every workflow file kept' {
            $doc = Merge-VmfSbomDuplicatePackages -Document (Read-VmfActionsFixture)
            $checkout = @(Get-VmfPackage $doc 'actions/checkout')
            $checkout.Count | Should -Be 1
            @(Get-VmfPackage $doc 'azure/login').Count | Should -Be 1
            @($doc.packages).Count | Should -Be 3
            # The workflow files the RECORDED generator output names, read from
            # the fixture rather than listed here: three of the six were removed
            # from the repository later (WORKFLOWS-UNUSED-1), and the fixture
            # stays as it was recorded.
            $files = @((Read-VmfActionsFixture).packages | Where-Object name -eq 'actions/checkout' |
                    ForEach-Object { [regex]::Match($_.sourceInfo, '/\.github/workflows/[^\s,]+').Value })
            $files.Count | Should -Be 6
            @($files | Where-Object { $_ }).Count | Should -Be 6
            foreach ($wf in $files) {
                $checkout[0].sourceInfo | Should -Match ([regex]::Escape($wf))
            }
            @(Get-VmfPackage $doc 'azure/login')[0].sourceInfo | Should -Not -Match 'release\.yml' -Because 'only the files that named it are kept'
        }

        It 'every relationship of a copy goes to the one kept, once, and none names a copy that is gone' {
            $doc = Merge-VmfSbomDuplicatePackages -Document (Read-VmfActionsFixture)
            $kept = @(Get-VmfPackage $doc 'actions/checkout')[0].SPDXID
            Test-VmfRelation $doc $script:shippedRoot 'CONTAINS' $kept | Should -BeTrue
            $ids = Get-VmfElementIds $doc
            foreach ($r in @($doc.relationships)) {
                $ids | Should -Contain $r.spdxElementId
                $ids | Should -Contain $r.relatedSpdxElement
            }
            @($doc.relationships).Count | Should -Be 3 -Because 'the root contains each of two parts once, and the document describes the root'
        }

        It 'a relationship that starts at a copy, and documentDescribes, move to the one kept' {
            $src = Read-VmfActionsFixture
            $copies = @(Get-VmfPackage $src 'azure/login')
            $src.relationships = @($src.relationships) + @(@{ spdxElementId = $copies[2].SPDXID; relatedSpdxElement = $script:shippedRoot; relationshipType = 'OTHER' })
            $src.documentDescribes = @($copies[1].SPDXID)
            $doc = Merge-VmfSbomDuplicatePackages -Document $src
            $kept = @(Get-VmfPackage $doc 'azure/login')[0].SPDXID
            Test-VmfRelation $doc $kept 'OTHER' $script:shippedRoot | Should -BeTrue
            @($doc.documentDescribes) | Should -Be @($kept)
        }

        It 'a part at another version, or with another package url, stays its own entry' {
            $src = Read-VmfActionsFixture
            $copies = @(Get-VmfPackage $src 'actions/checkout')
            $copies[0].versionInfo = 'v6'
            $copies[1].externalRefs[0].referenceLocator = 'pkg:github/actions/checkout@v7?fork=contoso'
            $doc = Merge-VmfSbomDuplicatePackages -Document $src
            @(Get-VmfPackage $doc 'actions/checkout').Count | Should -Be 3
        }

        It 'keeps every package url and reference of the copies' {
            $src = Read-VmfActionsFixture
            $copies = @(Get-VmfPackage $src 'azure/login')
            $copies[2].externalRefs = @($copies[2].externalRefs) + @(@{ referenceCategory = 'SECURITY'; referenceType = 'cpe23Type'; referenceLocator = 'cpe:2.3:a:azure:login:v3:*:*:*:*:*:*:*' })
            $copies[1].externalRefs = @($copies[1].externalRefs) + @(@{ referenceCategory = 'SECURITY'; referenceType = 'cpe23Type'; referenceLocator = 'cpe:2.3:a:azure:login:v3:*:*:*:*:*:*:*' })
            $doc = Merge-VmfSbomDuplicatePackages -Document $src
            $refs = @(@(Get-VmfPackage $doc 'azure/login')[0].externalRefs)
            @($refs | Where-Object referenceType -eq 'cpe23Type').Count | Should -Be 1
            @($refs | Where-Object referenceType -eq 'purl').Count | Should -Be 1
        }
    }

    Context 'the document check' {

        It 'a package named twice is a finding, with its count' {
            $found = @(Test-VmfSbomDocument -Document (Read-VmfActionsFixture) -NotShipped @())
            ($found -join ' ') | Should -Match 'actions/checkout v7 is in the document 6 times'
            ($found -join ' ') | Should -Match 'azure/login v3 is in the document 3 times'
        }

        It 'a merged document has no such finding' {
            @(Test-VmfSbomDocument -Document (Merge-VmfSbomDuplicatePackages -Document (Read-VmfActionsFixture)) -NotShipped @()) | Should -BeNullOrEmpty
        }

        It 'a source location in .github is a finding, by default and with no root' {
            $found = @(Test-VmfSbomDocument -Document (Merge-VmfSbomDuplicatePackages -Document (Read-VmfActionsFixture)))
            ($found -join ' ') | Should -Match '\.github'
            ($found -join ' ') | Should -Match 'does not ship'
        }

        It 'a file in a tree that does not ship is a finding, in either kind of slash; one in the manual is not' -ForEach @(
            @{ Name = './lab/fleet.json'; Finding = $true }
            @{ Name = '/tests/unit/x.json'; Finding = $true }
            @{ Name = '.\infra\ci-schedule\host.json'; Finding = $true }
            @{ Name = './docs/manual/vendor/x.js'; Finding = $false }
            @{ Name = './src/dashboard/lab-view.js'; Finding = $false }
            @{ Name = './src/contests/x.js'; Finding = $false }
        ) {
            $doc = Read-VmfFixture
            $doc.files = @([ordered]@{ fileName = $Name; SPDXID = 'SPDXRef-File-x'; checksums = @(@{ algorithm = 'SHA1'; checksumValue = ('0' * 40) }) })
            $found = @(Test-VmfSbomDocument -Document $doc -NotShipped @('lab', 'tests', 'infra/ci-schedule', 'docs/backlog'))
            if ($Finding) { ($found -join ' ') | Should -Match 'does not ship' } else { $found | Should -BeNullOrEmpty }
        }

        It 'a package file name in a tree that does not ship is a finding' {
            $doc = Read-VmfFixture
            $doc.packages[0].packageFileName = '/.claude/agents/x.md'
            (@(Test-VmfSbomDocument -Document $doc) -join ' ') | Should -Match '\.claude'
        }
    }

    Context 'tools/New-VmfSbom.ps1' {

        It 'a generator that did not leave a tree out stops the release, and nothing is written' {
            $root = New-VmfSbomRepo
            $syft = New-VmfFakeSyft -Body ([System.IO.File]::ReadAllText($script:actionsFixture))
            $out = Join-Path $script:temp ('gh-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
            { & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null } | Should -Throw '*.github*'
            Test-Path -LiteralPath $out | Should -BeFalse
        }

        It 'a docs folder that does not ship is checked too, not only the fixed trees' {
            $root = New-VmfSbomRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'backlog')
            $body = [System.IO.File]::ReadAllText($script:fixture).Replace('/docker/requirements.txt', '/docs/backlog/requirements.txt')
            $syft = New-VmfFakeSyft -Body $body
            $out = Join-Path $script:temp ('bk-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
            { & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null } | Should -Throw '*docs/backlog*'
            Test-Path -LiteralPath $out | Should -BeFalse
        }

        It 'a part the generator finds twice in what ships is written once' {
            $root = New-VmfSbomRepo
            $body = [System.IO.File]::ReadAllText($script:actionsFixture).Replace('/.github/workflows/', '/src/dashboard/')
            $syft = New-VmfFakeSyft -Body $body
            $out = Join-Path $script:temp ('dup-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.spdx.json')
            $r = & $script:sbomTool -Version '1.2.3' -OutFile $out -Root $root -PinPath (Join-Path $root 'infra' 'part-versions.json') -Executable $syft.Path 6>$null
            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable
            @(Get-VmfPackage $doc 'actions/checkout').Count | Should -Be 1
            @(Get-VmfPackage $doc 'azure/login').Count | Should -Be 1
            $r.Packages | Should -Be @($doc.packages).Count
        }
    }
}