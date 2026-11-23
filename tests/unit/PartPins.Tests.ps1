#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DEPS-CURRENT-1, 2026-10-21: every part is current before 1.0, then
# watched, with a test schema for updates.
#
# ONE pin file, infra/part-versions.json, for every part the product ships that
# does not update by itself: its version, where the latest one is read, and
# why. The Bicep CLI keeps its own pin (BICEP-PIN-1, infra/bicep-version.json),
# and this file names it.
#
# Three checks, and the tests below hold each of them to its rule:
#   - tools/Test-VmfPartPins.ps1 (no network): each reference in the
#     repository matches its pin - a Dockerfile FROM, a template module, the
#     sign-in library files by sha256, a test tool's version in a script - AND
#     the repository has no outside part the pin file does not list. Without
#     the second half the watch covers only the parts that existed on the day
#     it was written.
#   - tools/Test-VmfPartPinDrift.ps1 (the daily upstream-drift run): a newer
#     version of each pinned part, and a GitHub advisory that names a pinned
#     version, go into the issue that run keeps open. A read that fails is
#     "not checked", never "current" (UPST-4).
#   - -UpdateBaseline -Part <key> moves one pin, and the references with it.
#
# No test here reaches a registry: each provider is a stand-in.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'ppin'

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pinPath = Join-Path $script:repoRoot 'infra' 'part-versions.json'
    $script:localTool = Join-Path $script:repoRoot 'tools' 'Test-VmfPartPins.ps1'
    $script:driftTool = Join-Path $script:repoRoot 'tools' 'Test-VmfPartPinDrift.ps1'
    $script:workflowDir = Join-Path $script:repoRoot '.github' 'workflows'

    function script:Get-VmfSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    # PIN-ACTIONS-1: stand-in commit ids for the fixture's two actions.
    $script:checkoutCommit = '0123456789abcdef0123456789abcdef01234567'
    $script:loginCommit = 'fedcba9876543210fedcba9876543210fedcba98'
    $script:newCommit = '89abcdef0123456789abcdef0123456789abcdef'

    # A small repository with one part of each kind, all matching their pins.
    # Each test then breaks one thing in its own copy.
    function script:New-VmfPinRepo {
        $root = Join-Path $script:temp ('repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($dir in 'infra', 'docker', '.github/workflows', 'src/dashboard', 'src/facade/app', 'tools', 'tests/unit') {
            $null = New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force
        }
        Set-Content -LiteralPath (Join-Path $root 'docker' 'Dockerfile') -Value "# the engine`nFROM mcr.microsoft.com/azure-powershell:16.2.0-ubuntu-24.04`nCOPY . /app"
        Set-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value @(
            "module site 'br/public:avm/res/web/site:0.19.0' = {", "  name: 'site'", '}',
            "// module old 'br/public:avm/res/web/site:0.1.0' = {",
            "module local 'other.bicep' = {", "  name: 'local'", '}')
        # PINS-COVER-2: a container image named in a template. A commented line,
        # and an image name built from a registry and a tag, are not parts.
        Set-Content -LiteralPath (Join-Path $root 'infra' 'platform.bicep') -Value @(
            "param engineImage string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'",
            "// param oldImage string = 'mcr.microsoft.com/k8se/old-jobs:1.0.0'",
            "var built = '`${registry}/vmf-engine:`${tag}'",
            "var job = { image: '`${registry}/vmf-publish:`${tag}' }")
        Set-Content -LiteralPath (Join-Path $root 'bicepconfig.json') -Value '{ "extensions": { "microsoftGraphV1": "br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0" } }'
        # PINS-COVER-2: the Functions extension bundle a host.json names.
        # PIN-RUNTIME-1: one exact bundle version, in NuGet's exact form [x.y.z].
        Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'host.json') -Value '{ "version": "2.0", "extensionBundle": { "id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "[4.39.1]" } }'
        # PIN-ACTIONS-1: an action is named by its full commit id, with its
        # version as the comment.
        Set-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value @(
            'jobs:', '  a:', '    steps:', "      - uses: actions/checkout@$($script:checkoutCommit) # v7.0.1", '      - uses: ./local-action', "      - name: x`n        uses: azure/login@$($script:loginCommit) # v3.1.0")
        Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Value '/*! @contoso/lib v1.2.3 */ var lib = 1;'
        Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'page.js') -Value 'var mine = 1;'
        # PIN-RUNTIME-1: the service module at one version, and the profile
        # loads that version (Microsoft's "Target specific versions").
        Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'requirements.psd1') -Value "@{ 'Az.Accounts' = '5.5.3' }"
        Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'profile.ps1') -Value "if (`$env:IDENTITY_ENDPOINT) { Import-Module Az.Accounts -RequiredVersion '5.5.3' }"
        Set-Content -LiteralPath (Join-Path $root 'tools' 'run.ps1') -Value "Import-Module Pester -RequiredVersion 5.7.1`n`$v = @('Pester', '5.7.1')"
        # A fixture under tests/ is not a part the product ships.
        Set-Content -LiteralPath (Join-Path $root 'tests' 'unit' 'Dockerfile') -Value 'FROM contoso.azurecr.io/fixture:1.0.0'
        $pin = [ordered]@{
            schemaVersion   = 1
            why             = 'test'
            parts           = @(
                [ordered]@{ key = 'npm:@contoso/lib'; name = 'Contoso library'; version = '1.2.3'; latest = [ordered]@{ source = 'npm'; package = '@contoso/lib' }
                    advisories = [ordered]@{ ecosystem = 'npm'; package = '@contoso/lib' }; releaseNotes = 'https://example.com/lib/releases'; why = 'test'
                    # SBOM-1: a part the repository saves files of names its
                    # licence and the address of the package they came from.
                    license = 'MIT'; source = 'https://registry.npmjs.org/@contoso/lib/-/lib-1.2.3.tgz'
                    files = @([ordered]@{ path = 'src/dashboard/lib.min.js'; from = 'lib/lib.min.js'; sha256 = (Get-VmfSha256 (Join-Path $root 'src' 'dashboard' 'lib.min.js')) }) }
                [ordered]@{ key = 'image:mcr.microsoft.com/azure-powershell'; name = 'Engine base image'; version = '16.2.0'; tag = '{version}-ubuntu-24.04'
                    latest = [ordered]@{ source = 'mcr'; repository = 'azure-powershell' }; releaseNotes = 'https://example.com/az/releases'; why = 'test' }
                [ordered]@{ key = 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'; name = 'Template module avm/res/web/site'; version = '0.19.0'
                    latest = [ordered]@{ source = 'mcr'; repository = 'bicep/avm/res/web/site' }; releaseNotes = 'https://example.com/site'; why = 'test' }
                [ordered]@{ key = 'bicep:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0'; name = 'Graph extension'; version = '1.0.0'
                    latest = [ordered]@{ source = 'mcr'; repository = 'bicep/extensions/microsoftgraph/v1.0' }; releaseNotes = 'https://example.com/graph'; why = 'test' }
                [ordered]@{ key = 'psgallery:Pester'; name = 'Pester'; version = '5.7.1'; holdMajor = 5; latest = [ordered]@{ source = 'psgallery'; id = 'Pester' }
                    releaseNotes = 'https://example.com/pester'; why = 'test'
                    references = @([ordered]@{ path = 'tools/run.ps1'; text = 'Import-Module Pester -RequiredVersion {version}' }, [ordered]@{ path = 'tools/run.ps1'; text = "@('Pester', '{version}')" }) }
                [ordered]@{ key = 'action:actions/checkout'; name = 'GitHub Action actions/checkout'; version = '7.0.1'; commit = $script:checkoutCommit
                    latest = [ordered]@{ source = 'github'; repository = 'actions/checkout' }; releaseNotes = 'https://example.com/checkout'; why = 'test' }
                [ordered]@{ key = 'action:azure/login'; name = 'GitHub Action azure/login'; version = '3.1.0'; commit = $script:loginCommit
                    latest = [ordered]@{ source = 'github'; repository = 'azure/login' }; releaseNotes = 'https://example.com/login'; why = 'test' }
                [ordered]@{ key = 'psmodule:Az.Accounts'; name = 'Service module Az.Accounts'; version = '5.5.3'; latest = [ordered]@{ source = 'psgallery'; id = 'Az.Accounts' }
                    releaseNotes = 'https://example.com/az-accounts'; why = 'test'
                    references = @([ordered]@{ path = 'src/facade/app/profile.ps1'; text = "Import-Module Az.Accounts -RequiredVersion '{version}'" }) }
                [ordered]@{ key = 'bundle:Microsoft.Azure.Functions.ExtensionBundle'; name = 'Functions extension bundle'; version = '4.39.1'; tag = '[{version}]'
                    latest = [ordered]@{ source = 'functions-cdn'; id = 'Microsoft.Azure.Functions.ExtensionBundle' }; releaseNotes = 'https://example.com/bundles'; why = 'test' }
            )
            updatesItself   = @(
                [ordered]@{ key = 'image:mcr.microsoft.com/k8se/quickstart-jobs'; ref = 'latest'; why = 'test' }
            )
            # PINS-COVER-2: the .js and .css files the repository wrote. Every
            # other one in src/dashboard and docs/manual is an outside part.
            ownFiles        = [ordered]@{ why = 'test'; paths = @('src/dashboard/page.js') }
            pinnedElsewhere = @([ordered]@{ name = 'Bicep CLI'; pin = 'infra/bicep-version.json'; check = 'tools/Test-BicepPinDrift.ps1' })
        }
        $pin | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json')
        $root
    }
    function script:Invoke-VmfLocalCheck([string]$Root) {
        & $script:localTool -Root $Root -PinPath (Join-Path $Root 'infra' 'part-versions.json') 6>$null
    }
    function script:Edit-VmfPinFile([string]$Root, [scriptblock]$Change) {
        $file = Join-Path $Root 'infra' 'part-versions.json'
        $pin = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        & $Change $pin
        $pin | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'DEPS-CURRENT-1: the pin file' {

    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json }

    It 'has a version, where the latest is read, release notes and a reason for each pinned part' {
        $script:pin.schemaVersion | Should -Be 1
        $script:pin.why | Should -Match 'DEPS-CURRENT-1'
        @($script:pin.parts).Count | Should -BeGreaterThan 10
        foreach ($part in $script:pin.parts) {
            $part.key | Should -Match '^(npm|image|bicep|psgallery|psmodule|bundle|action):\S+$' -Because $part.name
            $part.version | Should -Match '^\d+\.\d+\.\d+$' -Because $part.key
            $part.latest.source | Should -BeIn @('npm', 'mcr', 'psgallery', 'functions-cdn', 'github') -Because $part.key
            $part.releaseNotes | Should -Match '^https://' -Because $part.key
            $part.why | Should -Not -BeNullOrEmpty -Because $part.key
        }
        @($script:pin.parts.key | Select-Object -Unique).Count | Should -Be @($script:pin.parts).Count -Because 'one entry per part'
    }

    It 'pins the sign-in library with the file the dashboard ships, and asks GitHub for its advisories' {
        $msal = @($script:pin.parts | Where-Object key -eq 'npm:@azure/msal-browser')
        $msal.Count | Should -Be 1
        @($msal[0].files.path) | Should -Contain 'src/dashboard/msal-browser.min.js'
        @($msal[0].files | Where-Object path -eq 'src/dashboard/msal-browser.min.js')[0].from | Should -Be 'lib/msal-browser.min.js'
        $msal[0].advisories.ecosystem | Should -Be 'npm'
        $msal[0].advisories.package | Should -Be '@azure/msal-browser'
    }

    It 'pins the sign-in library at a v5 release, the library file alone' {
        # NO-POPUPS-SIGNOUT-1: the redirect bridge answered the library's
        # pop-up. Nothing opens one now, so the file is not shipped.
        $msal = @($script:pin.parts | Where-Object key -eq 'npm:@azure/msal-browser')[0]
        $msal.version | Should -Match '^5\.'
        @($msal.files.path) | Should -Be @('src/dashboard/msal-browser.min.js')
        @($msal.files.from) | Should -Be @('lib/msal-browser.min.js')
        Test-Path (Join-Path $script:repoRoot 'src' 'dashboard' 'msal-redirect-bridge.min.js') | Should -BeFalse
    }

    It 'names the Bicep CLI pin as the one kept elsewhere' {
        $script:pin.pinnedElsewhere.pin | Should -Contain 'infra/bicep-version.json'
    }

    It 'Pester is held on 5 for 1.0, and says which item moves it' {
        $pester = @($script:pin.parts | Where-Object key -eq 'psgallery:Pester')[0]
        $pester.holdMajor | Should -Be 5
        $pester.why | Should -Match 'PESTER-6-1'
    }

    # MANUAL-MERMAID-1: GitHub named nine advisories against mermaid 11.4.1;
    # the last of them was fixed in 11.16.1. The floor is recorded with the
    # advisories it answers, so the pin can never move back under it with no
    # network (the daily check asks GitHub; this one does not need to).
    It 'the manual''s diagram library has a floor at the release that fixed its nine advisories, and its pin is at or above it' {
        $mermaid = @($script:pin.parts | Where-Object key -eq 'npm:mermaid')
        $mermaid.Count | Should -Be 1
        $mermaid[0].minimumVersion | Should -Be '11.16.1'
        foreach ($id in 'GHSA-c4c3-pg64-4m4v', 'GHSA-6x64-9x62-f2gx', 'GHSA-2v8p-3f2j-5mp7', 'GHSA-87f9-hvmw-gh4p', 'GHSA-6m6c-36f7-fhxh',
            'GHSA-ghcm-xqfw-q4vr', 'GHSA-xcj9-5m2h-648r', 'GHSA-7rqq-prvp-x9jh', 'GHSA-8gwm-58g9-j8pw') {
            $mermaid[0].minimumWhy | Should -Match $id -Because 'the floor names each advisory it answers'
        }
        [version]$mermaid[0].version | Should -BeGreaterOrEqual ([version]$mermaid[0].minimumVersion)
    }

    # MANUAL-MERMAID-1 (lead, 2026-10-23): 12 doubles the browser file, needs
    # an ES2024 browser and changes three drawing defaults, and 11.17.2 fixes
    # all nine advisories. Held the way Pester is held on 5.
    It 'the manual''s diagram library is held on 11, and says why' {
        $mermaid = @($script:pin.parts | Where-Object key -eq 'npm:mermaid')[0]
        $mermaid.holdMajor | Should -Be 11
        ([version]$mermaid.version).Major | Should -Be 11
        $mermaid.why | Should -Match 'held on 11'
        $mermaid.why | Should -Match 'ES2024'
    }

    # DEPS-CURRENT-1 part 4 (2026-10-24): docsify 5 draws the manual, but with
    # a new theme, a new sidebar and a new code-block call, so the manual's
    # look and its diagram hook must be made again first. Held the way mermaid
    # is held on 11, and MANUAL-DOCSIFY-5-1 moves it.
    It 'the manual''s reader is held on 4, and says why and which item moves it' {
        $docsify = @($script:pin.parts | Where-Object key -eq 'npm:docsify')[0]
        $docsify.holdMajor | Should -Be 4
        ([version]$docsify.version).Major | Should -Be 4
        $docsify.why | Should -Match 'held on 4'
        $docsify.why | Should -Match 'MANUAL-DOCSIFY-5-1'
    }

    # MANUAL-FONTS-1: the theme's first line imports two fonts from
    # fonts.googleapis.com, which the dashboard's policy refuses. The pin
    # removes that line, so a later move of the pin removes it again.
    It 'the manual''s theme is saved without the docsify line that asks Google for its fonts, and the pin says why' {
        $docsify = @($script:pin.parts | Where-Object key -eq 'npm:docsify')[0]
        $theme = @($docsify.files | Where-Object path -eq 'docs/manual/vendor/vue.css')[0]
        @($theme.remove).Count | Should -Be 1
        $theme.remove[0] | Should -Match '^@import url\("https://fonts\.googleapis\.com/'
        $theme.removeWhy | Should -Match 'MANUAL-FONTS-1'
        $theme.removeWhy | Should -Match 'content security policy'
        $saved = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot $theme.path))
        $saved.Contains($theme.remove[0]) | Should -BeFalse
        $saved | Should -Match '^\*\{-webkit-font-smoothing' -Because 'only the import goes; the theme starts with its next rule'
        foreach ($other in @($docsify.files | Where-Object path -ne 'docs/manual/vendor/vue.css')) {
            $other.PSObject.Properties['remove'] | Should -BeNullOrEmpty -Because "$($other.path) is saved as the package has it"
        }
    }
}

# PUBLIC-SYNC-1: the pin file names this repository's workflows, CI runner set-up
# and CI starter, which do not ship to the public repository. There the
# repository-wide pin check waits for PUBLIC-PINS-1.
Describe 'DEPS-CURRENT-1: every reference in this repository matches its pin, and every outside part is listed' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    It 'the repository as it stands: no finding' {
        $r = & $script:localTool 6>$null
        @($r.Findings | ForEach-Object { "$($_.kind) $($_.key) $($_.path): $($_.detail)" }) | Should -BeNullOrEmpty
        $r.References.Count | Should -BeGreaterThan 20 -Because 'the check must have found the references to compare'
    }

    It 'finds each kind of reference in the repository' {
        $r = & $script:localTool 6>$null
        $keys = @($r.References.key)
        $keys | Should -Contain 'image:mcr.microsoft.com/azure-powershell'
        $keys | Should -Contain 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'
        $keys | Should -Contain 'bicep:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0'
        $keys | Should -Contain 'action:actions/checkout'
        $keys | Should -Contain 'file:src/dashboard/msal-browser.min.js'
        $keys | Should -Not -Contain 'file:src/dashboard/msal-redirect-bridge.min.js'
        # FACADE-SIGNIN-COLD-1: the service takes no module from the gallery, so the
        # repository has no psmodule part (the fixtures below still test the kind).
        $keys | Should -Not -Contain 'psmodule:Az.Accounts'
        # DOC-4: the manual ships inside the dashboard, with its reader and diagrams.
        $keys | Should -Contain 'file:docs/manual/vendor/mermaid.min.js'
        $keys | Should -Contain 'file:docs/manual/vendor/vue.css'
        @($r.References | Where-Object key -eq 'image:mcr.microsoft.com/azure-powershell').Count | Should -Be 2 -Because 'both Dockerfiles'
        # PINS-COVER-2: the two service host.json files, and the engine and
        # publish jobs' first image in both install templates.
        @($r.References | Where-Object key -eq 'bundle:Microsoft.Azure.Functions.ExtensionBundle').path | Sort-Object |
            Should -Be @('infra/ci-schedule/starter-function/host.json', 'src/facade/app/host.json')
        @($r.References | Where-Object key -eq 'image:mcr.microsoft.com/k8se/quickstart-jobs').Count | Should -Be 4 -Because 'engineImage and publishImage, in infra/main.bicep and infra/platform.bicep'
        $keys | Should -Contain 'file:src/dashboard/help.js' -Because 'every saved .js and .css file is read; the pin file says which ones the repository wrote'
    }

    It 'the pin file lists each .js and .css file the repository wrote, with a reason, and none of them is an outside part' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        $pin.ownFiles.why | Should -Match 'PINS-COVER-2'
        @($pin.ownFiles.paths) | Should -Contain 'src/dashboard/help.js'
        @($pin.ownFiles.paths) | Should -Contain 'docs/manual/manual.css'
        $placeholder = @($pin.updatesItself | Where-Object key -eq 'image:mcr.microsoft.com/k8se/quickstart-jobs')
        $placeholder.Count | Should -Be 1
        $placeholder[0].why | Should -Match 'placeholder'
    }

    It 'a fixture repository that matches: no finding' {
        $r = Invoke-VmfLocalCheck (New-VmfPinRepo)
        @($r.Findings | ForEach-Object { "$($_.kind) $($_.key) $($_.path): $($_.detail)" }) | Should -BeNullOrEmpty
        @($r.References).Count | Should -Be 10 -Because 'the image, the module, the extension, two actions, the library file, the service module, the template image, the bundle and the page the repository wrote; the commented module and image, the built image name, the local action and the fixture under tests are not parts'
    }

    It 'a Dockerfile on another tag is a mismatch that names the file and both tags' {
        $root = New-VmfPinRepo
        Set-Content -LiteralPath (Join-Path $root 'docker' 'Dockerfile') -Value 'FROM mcr.microsoft.com/azure-powershell:16.4.0-ubuntu-24.04'
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].path | Should -Be 'docker/Dockerfile'
        $f[0].detail | Should -Match '16\.4\.0-ubuntu-24\.04'
        $f[0].detail | Should -Match '16\.2\.0-ubuntu-24\.04'
    }

    It 'a template module on another version is a mismatch; a commented line is not read' {
        $root = New-VmfPinRepo
        (Get-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Raw).Replace('site:0.19.0', 'site:0.24.0') | Set-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep')
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1 -Because 'the commented 0.1.0 is not a reference'
        $f[0].kind | Should -Be 'mismatch'
        $f[0].key | Should -Be 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'
        $f[0].detail | Should -Match '0\.24\.0'
    }

    It 'the extension in bicepconfig.json on another version is a mismatch' {
        $root = New-VmfPinRepo
        Set-Content -LiteralPath (Join-Path $root 'bicepconfig.json') -Value '{ "extensions": { "microsoftGraphV1": "br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.1.0" } }'
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].path | Should -Be 'bicepconfig.json'
        $f[0].kind | Should -Be 'mismatch'
    }

    It 'a library file whose bytes changed is a mismatch on its sha256' {
        $root = New-VmfPinRepo
        Add-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Value '// edited'
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].path | Should -Be 'src/dashboard/lib.min.js'
        $f[0].detail | Should -Match 'sha256'
    }

    It 'a library file the pin lists and the repository lacks is missing' {
        $root = New-VmfPinRepo
        Remove-Item -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js')
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        @($f.kind) | Should -Contain 'missing'
    }
    # MANUAL-FONTS-1: a file entry may name text the pin removes from the
    # package's file (remove), with the reason (removeWhy).
    It 'a saved file that still has text its pin removes is a mismatch, even when its sha256 is recorded' {
        $root = New-VmfPinRepo
        $lib = Join-Path $root 'src' 'dashboard' 'lib.min.js'
        Add-Content -LiteralPath $lib -Value 'loadFonts("https://fonts.example.com");'
        Edit-VmfPinFile $root { param($pin) $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
            $file.sha256 = (Get-VmfSha256 $lib)
            $file | Add-Member -NotePropertyName remove -NotePropertyValue @('loadFonts("https://fonts.example.com");')
            $file | Add-Member -NotePropertyName removeWhy -NotePropertyValue 'test' }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].path | Should -Be 'src/dashboard/lib.min.js'
        $f[0].detail | Should -Match 'removes'
        $f[0].detail | Should -Match 'fonts\.example\.com'
    }

    It 'a remove with no reason, or with empty text, is refused' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
            $file | Add-Member -NotePropertyName remove -NotePropertyValue @('var lib = 1;') }
        { Invoke-VmfLocalCheck $root } | Should -Throw '*removeWhy*'
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
            $file | Add-Member -NotePropertyName remove -NotePropertyValue @('')
            $file | Add-Member -NotePropertyName removeWhy -NotePropertyValue 'test' }
        { Invoke-VmfLocalCheck $root } | Should -Throw '*empty*'
    }

    # MANUAL-MERMAID-1: a part may carry a floor, minimumVersion, with the
    # advisories it answers in minimumWhy. Compared as numbers, like the
    # daily check: 1.10.0 is above 1.9.0.
    It 'a pin under its floor is a finding that names both versions and why the floor is there' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $lib = $pin.parts | Where-Object key -eq 'npm:@contoso/lib'
            $lib | Add-Member -NotePropertyName minimumVersion -NotePropertyValue '1.10.0'
            $lib | Add-Member -NotePropertyName minimumWhy -NotePropertyValue 'GHSA-xxxx-yyyy-zzzz is fixed in 1.10.0.' }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'below'
        $f[0].key | Should -Be 'npm:@contoso/lib'
        $f[0].path | Should -Be 'infra/part-versions.json'
        $f[0].detail | Should -Match '1\.2\.3'
        $f[0].detail | Should -Match '1\.10\.0'
        $f[0].detail | Should -Match 'GHSA-xxxx-yyyy-zzzz'
    }

    It 'a pin at its floor, or above it, is no finding' {
        foreach ($floor in '1.2.3', '1.2.0', '0.19.9') {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $lib = $pin.parts | Where-Object key -eq 'npm:@contoso/lib'
                $lib | Add-Member -NotePropertyName minimumVersion -NotePropertyValue $floor
                $lib | Add-Member -NotePropertyName minimumWhy -NotePropertyValue 'test' }
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty -Because "1.2.3 is not under $floor"
        }
    }

    It 'a floor that is not a version, or has no reason, is refused' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $lib = $pin.parts | Where-Object key -eq 'npm:@contoso/lib'
            $lib | Add-Member -NotePropertyName minimumVersion -NotePropertyValue 'latest'
            $lib | Add-Member -NotePropertyName minimumWhy -NotePropertyValue 'test' }
        { Invoke-VmfLocalCheck $root } | Should -Throw '*minimumVersion*'
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $lib = $pin.parts | Where-Object key -eq 'npm:@contoso/lib'
            $lib | Add-Member -NotePropertyName minimumVersion -NotePropertyValue '1.0.0' }
        { Invoke-VmfLocalCheck $root } | Should -Throw '*minimumWhy*'
    }

    It 'a test tool version in a script that is not the pin is a mismatch' {
        $root = New-VmfPinRepo
        Set-Content -LiteralPath (Join-Path $root 'tools' 'run.ps1') -Value "Import-Module Pester -RequiredVersion 5.7.1`n`$v = @('Pester', '5.6.0')"
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].detail | Should -Match '5\.6\.0'
    }

    It 'a test tool reference that is gone from its script is missing' {
        $root = New-VmfPinRepo
        Set-Content -LiteralPath (Join-Path $root 'tools' 'run.ps1') -Value "`$v = @('Pester', '5.7.1')"
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'missing'
        $f[0].detail | Should -Match 'Import-Module Pester'
    }

    It 'an action on another commit is a mismatch that names both commits' {
        $root = New-VmfPinRepo
        (Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Raw).Replace("checkout@$($script:checkoutCommit)", "checkout@$($script:newCommit)") | Set-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml')
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].key | Should -Be 'action:actions/checkout'
        $f[0].detail | Should -Match $script:newCommit
        $f[0].detail | Should -Match $script:checkoutCommit
    }

    Context 'a part the pin file does not list is reported (the watch must grow with the repository)' {

        It 'a new Dockerfile FROM' {
            $root = New-VmfPinRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docker' 'tool')
            Set-Content -LiteralPath (Join-Path $root 'docker' 'tool' 'Dockerfile') -Value "FROM mcr.microsoft.com/dotnet/runtime:9.0 AS base`nFROM base"
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1 -Because 'a FROM that names an earlier stage is not an outside part'
            $f[0].kind | Should -Be 'unlisted'
            $f[0].key | Should -Be 'image:mcr.microsoft.com/dotnet/runtime'
            $f[0].path | Should -Be 'docker/tool/Dockerfile'
        }

        It 'a new template module, in any registry' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value "module kv 'br/public:avm/res/key-vault/vault:0.13.0' = {`n  name: 'kv'`n}`nmodule own 'br:contoso.azurecr.io/bicep/thing:2.0.0' = {`n  name: 'own'`n}"
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('bicep:contoso.azurecr.io/bicep/thing', 'bicep:mcr.microsoft.com/bicep/avm/res/key-vault/vault')
        }

        It 'a new workflow action' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value "      - uses: actions/setup-node@$($script:newCommit) # v5.0.0"
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'unlisted'
            $f[0].key | Should -Be 'action:actions/setup-node'
        }

        It 'a new library file in the dashboard, by its name or by its banner' {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'chart.min.js') -Value 'var c = 1;'
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'vendor.js') -Value "/*! contoso-grid v3.1.0 | MIT */`nvar g = 1;"
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('file:src/dashboard/chart.min.js', 'file:src/dashboard/vendor.js')
        }

        It 'a new file in the manual''s vendor folder, whatever its name: the manual ships inside the dashboard' {
            $root = New-VmfPinRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'manual' 'vendor') -Force
            Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'vendor' 'reader.js') -Value 'var r = 1;'
            Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'vendor' 'theme.css') -Value 'body { }'
            Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'manual.css') -Value 'h1 { }'
            Edit-VmfPinFile $root { param($pin) $pin.ownFiles.paths = @($pin.ownFiles.paths) + 'docs/manual/manual.css' }
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('file:docs/manual/vendor/reader.js', 'file:docs/manual/vendor/theme.css') -Because 'the manual''s own stylesheet is on the list of files the repository wrote'
        }

        # PINS-COVER-2: a library is found by a list of the files the
        # repository wrote, never by its name or its first line. A saved copy
        # with no banner and an ordinary name was not found before.
        It 'a saved library with no version line and an ordinary name, in the dashboard or the manual' {
            $root = New-VmfPinRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'src' 'dashboard' 'lib') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'manual') -Force
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'grid.js') -Value 'var grid = 1;'
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib' 'table.css') -Value '.t { }'
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'chart.mjs') -Value 'export const c = 1;'
            Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'plugin.js') -Value 'window.$docsify = {};'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('file:docs/manual/plugin.js', 'file:src/dashboard/chart.mjs', 'file:src/dashboard/grid.js', 'file:src/dashboard/lib/table.css') -Because 'src/dashboard/page.js is on the list of files the repository wrote'
        }

        It 'a new Functions extension bundle, in a new host.json' {
            $root = New-VmfPinRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'infra' 'fn') -Force
            Set-Content -LiteralPath (Join-Path $root 'infra' 'fn' 'host.json') -Value @('{', '  "version": "2.0",', '  "extensionBundle": {', '    "id": "Microsoft.Azure.Functions.ExtensionBundle.Preview",', '    "version": "[4.*, 5.0.0)"', '  }', '}')
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 2 -Because 'it is not listed, and (PIN-RUNTIME-1) its range is not one version'
            @($f.kind | Sort-Object) | Should -Be @('floating', 'unlisted')
            @($f.key | Select-Object -Unique) | Should -Be @('bundle:Microsoft.Azure.Functions.ExtensionBundle.Preview')
            @($f.path | Select-Object -Unique) | Should -Be @('infra/fn/host.json')
            @($f | Where-Object kind -eq 'unlisted')[0].detail | Should -Match 'Line 5 ' -Because 'the line of the version range'
        }

        It 'a new container image named in a template: a parameter default, and an image property' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value @(
                "param toolImage string = 'mcr.microsoft.com/dotnet/runtime:9.0'",
                "var sidecar = { image: 'contoso.azurecr.io/tools/sidecar@sha256:$('a' * 64)' }",
                "var other = { image: 'nginx:1.27' }")
            Set-Content -LiteralPath (Join-Path $root 'infra' 'main.bicepparam') -Value @("using 'main.bicep'", "param toolImage = 'contoso.azurecr.io/param-image:2.0'")
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('image:contoso.azurecr.io/param-image', 'image:contoso.azurecr.io/tools/sidecar', 'image:mcr.microsoft.com/dotnet/runtime', 'image:nginx') -Because 'each image once, and a digest is not part of the image name'
        }

        It 'a new container image in a workflow job''s container or services, or in a template parameters file' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value @(
                '  b:', '    container: mcr.microsoft.com/powershell:7.4-ubuntu-22.04', '    services:', '      db:', "        image: 'contoso.azurecr.io/db:3.1'",
                '  c:', '    container:', '      image: ${{ matrix.image }}')
            Set-Content -LiteralPath (Join-Path $root 'infra' 'main.parameters.json') -Value '{ "parameters": { "toolImage": { "value": "contoso.azurecr.io/param-tool:4.0" }, "name": { "value": "${AZURE_ENV_NAME}" } } }'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
            @($f.key | Sort-Object) | Should -Be @('image:contoso.azurecr.io/db', 'image:contoso.azurecr.io/param-tool', 'image:mcr.microsoft.com/powershell') -Because 'an image name from ${{ }} is chosen when the job runs'
        }
        It 'a host.json that is not JSON stops the check and names the file: a part it cannot read is never a pass' {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'host.json') -Value '{ "version": "2.0", '
            { Invoke-VmfLocalCheck $root } | Should -Throw '*src/facade/app/host.json*'
        }

        It 'a new module for the service' {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'requirements.psd1') -Value "@{ 'Az.Accounts' = '5.5.3'; 'Az.Storage' = '8.1.0' }"
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'unlisted'
            $f[0].key | Should -Be 'psmodule:Az.Storage'
        }    }

    Context 'PINS-COVER-2: a bundle, a template image and the list of files the repository wrote are held to the pin file' {

        It 'a bundle range that is not the one the pin file lists is a mismatch' {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'host.json') -Value '{ "version": "2.0", "extensionBundle": { "id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "[3.*, 4.0.0)" } }'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Sort-Object) | Should -Be @('floating', 'mismatch')
            @($f.key | Select-Object -Unique) | Should -Be @('bundle:Microsoft.Azure.Functions.ExtensionBundle')
            @($f | Where-Object kind -eq 'mismatch')[0].detail | Should -Match ([regex]::Escape('[3.*, 4.0.0)'))
            @($f | Where-Object kind -eq 'mismatch')[0].detail | Should -Match ([regex]::Escape('[4.39.1]')) -Because 'the value the pin asks for'
        }

        It 'a host.json with no bundle names no part, and a bundle nothing names any more is reported' {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'host.json') -Value '{ "version": "2.0" }'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'unused'
            $f[0].key | Should -Be 'bundle:Microsoft.Azure.Functions.ExtensionBundle'
        }

        It 'a template image on another tag is a mismatch' {
            $root = New-VmfPinRepo
            (Get-Content -LiteralPath (Join-Path $root 'infra' 'platform.bicep') -Raw).Replace('quickstart-jobs:latest', 'quickstart-jobs:2.0') | Set-Content -LiteralPath (Join-Path $root 'infra' 'platform.bicep')
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].key | Should -Be 'image:mcr.microsoft.com/k8se/quickstart-jobs'
            $f[0].path | Should -Be 'infra/platform.bicep'
        }

        It 'a file on the list that the repository lacks is missing, so the list holds no dead entry' {
            $root = New-VmfPinRepo
            Remove-Item -LiteralPath (Join-Path $root 'src' 'dashboard' 'page.js')
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'missing'
            $f[0].path | Should -Be 'src/dashboard/page.js'
        }

        It 'a file on the list that a pinned part also lists is a mismatch: a saved library is not the repository''s own file' {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $pin.ownFiles.paths = @($pin.ownFiles.paths) + 'src/dashboard/lib.min.js' }
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].key | Should -Be 'npm:@contoso/lib'
            $f[0].path | Should -Be 'src/dashboard/lib.min.js'
        }

        It 'a pin file with no list of the files the repository wrote, or no reason for it, is refused' {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $pin.PSObject.Properties.Remove('ownFiles') }
            { Invoke-VmfLocalCheck $root } | Should -Throw '*ownFiles*'
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $pin.ownFiles.why = '' }
            { Invoke-VmfLocalCheck $root } | Should -Throw '*ownFiles*'
        }

        It 'an image named by tag and digest is not moved by -UpdateBaseline: it is refused, and nothing changes' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value "param toolImage string = 'contoso.azurecr.io/tool:1.0.0@sha256:$('b' * 64)'"
            Edit-VmfPinFile $root { param($pin) $pin.parts += [pscustomobject]@{ key = 'image:contoso.azurecr.io/tool'; name = 'Tool image'; version = '1.0.0'
                    latest = [pscustomobject]@{ source = 'mcr'; repository = 'tool' }; releaseNotes = 'https://example.com/tool'; why = 'test' } }
            $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Raw
            $pinBefore = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
            $map = @{ 'image:contoso.azurecr.io/tool' = @('1.0.0', '1.1.0') }
            $provider = { param($p) if ($map.ContainsKey($p.key)) { $map[$p.key] } else { @($p.version) } }.GetNewClosure()
            { & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider $provider -AdvisoryProvider { param($p) @() } -UpdateBaseline -Part 'image:contoso.azurecr.io/tool' 6>$null } |
                Should -Throw '*digest*'
            Get-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Raw | Should -Be $before
            Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $pinBefore
        }
        It 'a template image pinned to a version moves with -UpdateBaseline, the way a Dockerfile FROM does' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value "param toolImage string = 'contoso.azurecr.io/tool:1.0.0'"
            Edit-VmfPinFile $root { param($pin) $pin.parts += [pscustomobject]@{ key = 'image:contoso.azurecr.io/tool'; name = 'Tool image'; version = '1.0.0'
                    latest = [pscustomobject]@{ source = 'mcr'; repository = 'tool' }; releaseNotes = 'https://example.com/tool'; why = 'test' } }
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
            $map = @{ 'image:contoso.azurecr.io/tool' = @('1.0.0', '1.1.0') }
            $provider = { param($p) if ($map.ContainsKey($p.key)) { $map[$p.key] } else { @($p.version) } }.GetNewClosure()
            & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider $provider -AdvisoryProvider { param($p) @() } -UpdateBaseline -Part 'image:contoso.azurecr.io/tool' 6>$null | Out-Null
            Get-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Raw | Should -Match "'contoso\.azurecr\.io/tool:1\.1\.0'"
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        }

    }

    It 'a pinned part nothing uses any more is reported, so the pin file does not keep a dead entry' {
        $root = New-VmfPinRepo
        Set-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Value "module local 'other.bicep' = {`n  name: 'local'`n}"
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'unused'
        $f[0].key | Should -Be 'bicep:mcr.microsoft.com/bicep/avm/res/web/site'
    }

    It 'every dashboard file of a pinned part is on the dashboard deploy list, or it does not ship' {
        $deploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        foreach ($file in @($pin.parts.files | Where-Object { $_.path -like 'src/dashboard/*' })) {
            $deploy | Should -Match ("'" + [regex]::Escape(($file.path -replace '^src/dashboard/', '')) + "'") -Because $file.path
        }
    }
}

# SBOM-1: the pin file is also the manifest of the third-party files the
# release carries - for each, its name, version, licence, the address of the
# package it came from, and its sha256 - and the release's bill of materials
# (tools/New-VmfSbom.ps1) is built from it. These hold each row to its file.
Describe 'SBOM-1: each saved third-party file has a row, and the row agrees with the file' {

    It 'every part the repository saves files of names a licence and the package address of its version' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        $withFiles = @($pin.parts | Where-Object { $_.files })
        $withFiles.Count | Should -Be 3 -Because 'the sign-in library, the manual reader and the manual diagrams'
        foreach ($part in $withFiles) {
            $part.license | Should -Be 'MIT' -Because "the npm registry gives $($part.latest.package) $($part.version) the licence MIT"
            $base = ([string]$part.latest.package).Split('/')[-1]
            $part.source | Should -Be "https://registry.npmjs.org/$($part.latest.package)/-/$base-$($part.version).tgz"
        }
    }

    It 'a library a saved file carries inside it is named, with the text in the file that proves its version' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        $mermaid = @(@($pin.parts | Where-Object key -eq 'npm:mermaid')[0].files)[0]
        $dompurify = @($mermaid.contains | Where-Object name -eq 'dompurify')
        $dompurify.Count | Should -Be 1 -Because 'the diagram library carries the HTML sanitizer DOMPurify, and an advisory against it is an advisory against the manual'
        $dompurify[0].version | Should -Be '3.4.12'
        $dompurify[0].license | Should -Be '(MPL-2.0 OR Apache-2.0)'
        $msal = @(@($pin.parts | Where-Object key -eq 'npm:@azure/msal-browser')[0].files | Where-Object path -eq 'src/dashboard/msal-browser.min.js')[0]
        @($msal.contains | Where-Object name -eq '@azure/msal-common')[0].version | Should -Be '16.17.0'
    }

    It 'the manifest takes in every file a browser loads as code, a style, a font or a picture in vector form' {
        $root = New-VmfPinRepo
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'manual' 'vendor') -Force
        foreach ($name in 'icons.svg', 'font.woff2', 'font.woff', 'face.ttf', 'face.otf', 'old.eot', 'engine.wasm', 'mod.cjs', 'lib.min.js.map') {
            Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' $name) -Value 'x'
        }
        Set-Content -LiteralPath (Join-Path $root 'docs' 'manual' 'vendor' 'emoji.svg') -Value '<svg/>'
        Set-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'notes.txt') -Value 'not a file the browser loads as code'
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        @($f.kind | Select-Object -Unique) | Should -Be @('unlisted')
        @($f.key | Sort-Object) | Should -Be @(
            'file:docs/manual/vendor/emoji.svg', 'file:src/dashboard/engine.wasm', 'file:src/dashboard/face.otf',
            'file:src/dashboard/face.ttf', 'file:src/dashboard/font.woff', 'file:src/dashboard/font.woff2',
            'file:src/dashboard/icons.svg', 'file:src/dashboard/lib.min.js.map', 'file:src/dashboard/mod.cjs', 'file:src/dashboard/old.eot')
    }

    It 'the repository''s own pictures in vector form are on the list of files it wrote' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        foreach ($own in 'src/dashboard/logo.svg', 'docs/manual/logo.svg', 'docs/manual/images/architecture.svg') {
            @($pin.ownFiles.paths) | Should -Contain $own
        }
    }

    It 'a part with saved files and no licence is missing its licence' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $pin.parts[0].PSObject.Properties.Remove('license') }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'missing'
        $f[0].key | Should -Be 'npm:@contoso/lib'
        $f[0].detail | Should -Match 'licence'
    }

    It 'a licence that is not an SPDX licence expression is a mismatch' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $pin.parts[0].license = 'the MIT one' }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].detail | Should -Match 'SPDX'
    }

    It 'an SPDX licence expression is ids joined by AND, OR or WITH, in brackets or not, and nothing else' {
        . (Join-Path $script:repoRoot 'tools' '_VmfPartPins.ps1')
        foreach ($good in 'MIT', '(MPL-2.0 OR Apache-2.0)', 'GPL-2.0-only WITH Classpath-exception-2.0', 'LicenseRef-Contoso') {
            Test-VmfSpdxLicenseExpression $good | Should -BeTrue -Because $good
        }
        foreach ($bad in 'MIT OR', 'OR MIT', 'the MIT one', 'NOASSERTION', '(MIT', 'MIT)', '', ' MIT') {
            Test-VmfSpdxLicenseExpression $bad | Should -BeFalse -Because "'$bad'"
        }
    }

    It 'a part with saved files and no package address is missing it' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $pin.parts[0].PSObject.Properties.Remove('source') }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'missing'
        $f[0].detail | Should -Match 'registry\.npmjs\.org/@contoso/lib/-/lib-1\.2\.3\.tgz'
    }

    It 'a package address of another version is a mismatch that names both' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $pin.parts[0].source = 'https://registry.npmjs.org/@contoso/lib/-/lib-1.2.0.tgz' }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].detail | Should -Match 'lib-1\.2\.0\.tgz'
        $f[0].detail | Should -Match 'lib-1\.2\.3\.tgz'
    }

    It 'a saved file whose own first line names another version of its package is a mismatch, even when its sha256 is recorded' {
        $root = New-VmfPinRepo
        $lib = Join-Path $root 'src' 'dashboard' 'lib.min.js'
        Set-Content -LiteralPath $lib -Value '/*! @contoso/lib v1.2.4 */ var lib = 1;'
        Edit-VmfPinFile $root { param($pin) @($pin.parts[0].files)[0].sha256 = (Get-VmfSha256 $lib) }
        $f = @((Invoke-VmfLocalCheck $root).Findings)
        $f.Count | Should -Be 1
        $f[0].kind | Should -Be 'mismatch'
        $f[0].path | Should -Be 'src/dashboard/lib.min.js'
        $f[0].detail | Should -Match 'v1\.2\.4'
        $f[0].detail | Should -Match '1\.2\.3'
    }

    It 'a first line that names another package says nothing about this pin' {
        $root = New-VmfPinRepo
        $lib = Join-Path $root 'src' 'dashboard' 'lib.min.js'
        Set-Content -LiteralPath $lib -Value '/*! @contoso/other v9.9.9 */ var lib = 1;'
        Edit-VmfPinFile $root { param($pin) @($pin.parts[0].files)[0].sha256 = (Get-VmfSha256 $lib) }
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
    }

    Context 'a library a saved file carries inside it' {

        BeforeAll {
            . (Join-Path $PSScriptRoot '_PageSource.ps1')
            function script:Add-VmfContains([string]$Root, [string]$Text, [hashtable]$Entry) {
                $lib = Join-Path $Root 'src' 'dashboard' 'lib.min.js'
                Add-Content -LiteralPath $lib -Value $Text
                Edit-VmfPinFile $Root { param($pin) $file = @($pin.parts[0].files)[0]
                    $file.sha256 = (Get-VmfSha256 $lib)
                    $file | Add-Member -NotePropertyName contains -NotePropertyValue @([pscustomobject]$Entry) }
            }
        }

        It 'whose text is in the file, with its version: no finding' {
            $root = New-VmfPinRepo
            Add-VmfContains $root '/*! @license Sanitizer 2.0.1 | MIT */' @{ name = 'sanitizer'; version = '2.0.1'; license = 'MIT'; evidence = 'Sanitizer 2.0.1' }
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        }

        It 'whose text is not in the file is a mismatch: a new release carries another version' {
            $root = New-VmfPinRepo
            Add-VmfContains $root '/*! @license Sanitizer 2.0.2 | MIT */' @{ name = 'sanitizer'; version = '2.0.1'; license = 'MIT'; evidence = 'Sanitizer 2.0.1' }
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].detail | Should -Match 'sanitizer'
            $f[0].detail | Should -Match 'Sanitizer 2\.0\.1'
        }

        It 'whose text does not name its version proves nothing, and is a mismatch' {
            $root = New-VmfPinRepo
            Add-VmfContains $root '/*! @license Sanitizer 2.0.1 | MIT */' @{ name = 'sanitizer'; version = '2.0.1'; license = 'MIT'; evidence = '@license Sanitizer' }
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].detail | Should -Match '2\.0\.1'
        }

        It 'with no licence, or a version that is not one, is a mismatch' {
            $root = New-VmfPinRepo
            Add-VmfContains $root '/*! @license Sanitizer 2.0.1 | MIT */' @{ name = 'sanitizer'; version = 'latest'; license = ''; evidence = 'Sanitizer 2.0.1' }
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind | Select-Object -Unique) | Should -Be @('mismatch')
            # Three: the version, the licence, and a text that cannot name a
            # version that is not one.
            $f.Count | Should -Be 3
            @($f.detail -match 'not a version').Count | Should -Be 1
            @($f.detail -match 'not an SPDX licence expression').Count | Should -Be 1
        }
    }

    # MERMAID-CONTENTS-1 (2026-11-08): a library whose version the
    # file does not name is proved by the lock file of the part's release -
    # its address at the release's tag and its sha256, recorded beside the
    # rows. A row with no evidence text needs that record.
    Context 'a library whose version the file does not name' {

        BeforeAll {
            $script:lockSha = 'a' * 64
            function script:Add-VmfLockRow([string]$Root, [hashtable]$Entry, $LockFile) {
                Edit-VmfPinFile $Root { param($pin) $file = @($pin.parts[0].files)[0]
                    $file | Add-Member -NotePropertyName contains -NotePropertyValue @([pscustomobject]$Entry)
                    if ($LockFile) { $file | Add-Member -NotePropertyName lockFile -NotePropertyValue ([pscustomobject]$LockFile) } }
            }
            $script:goodLock = @{ url = 'https://raw.githubusercontent.com/contoso/lib/lib%401.2.3/pnpm-lock.yaml'; sha256 = $script:lockSha; why = 'test' }
        }

        It 'with the lock file of the pinned release recorded: no finding' {
            $root = New-VmfPinRepo
            Add-VmfLockRow $root @{ name = 'charts'; version = '7.9.0'; license = 'ISC' } $script:goodLock
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        }

        It 'with no lock file recorded proves nothing, and is a mismatch that names the row' {
            $root = New-VmfPinRepo
            Add-VmfLockRow $root @{ name = 'charts'; version = '7.9.0'; license = 'ISC' } $null
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].detail | Should -Match 'charts 7\.9\.0'
            $f[0].detail | Should -Match 'lock file'
        }

        It 'with a lock file of another release is a mismatch: the address names the pinned version' {
            $root = New-VmfPinRepo
            $other = $script:goodLock.Clone(); $other.url = 'https://raw.githubusercontent.com/contoso/lib/lib%401.2.2/pnpm-lock.yaml'
            Add-VmfLockRow $root @{ name = 'charts'; version = '7.9.0'; license = 'ISC' } $other
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'mismatch'
            $f[0].detail | Should -Match '1\.2\.3'
            # 11.2.3 and 1.2.30 are not 1.2.3.
            foreach ($near in 'lib%4011.2.3', 'lib%401.2.30') {
                $root = New-VmfPinRepo
                $other.url = "https://raw.githubusercontent.com/contoso/lib/$near/pnpm-lock.yaml"
                Add-VmfLockRow $root @{ name = 'charts'; version = '7.9.0'; license = 'ISC' } $other
                @((Invoke-VmfLocalCheck $root).Findings).Count | Should -Be 1 -Because $near
            }
        }

        It 'with a lock file address that is not https, or a sha256 that is not one, is a mismatch' {
            foreach ($bad in @(@{ url = 'http://raw.githubusercontent.com/contoso/lib/lib%401.2.3/pnpm-lock.yaml' }, @{ sha256 = 'A' * 64 }, @{ sha256 = 'a' * 63 }, @{ sha256 = '' })) {
                $root = New-VmfPinRepo
                $lock = $script:goodLock.Clone()
                foreach ($k in $bad.Keys) { $lock[$k] = $bad[$k] }
                Add-VmfLockRow $root @{ name = 'charts'; version = '7.9.0'; license = 'ISC' } $lock
                $f = @((Invoke-VmfLocalCheck $root).Findings)
                $f.Count | Should -Be 1 -Because ($bad | ConvertTo-Json -Compress)
                $f[0].kind | Should -Be 'mismatch'
            }
        }

        It 'a row with an evidence text is still held to that text, never to the lock file' {
            $root = New-VmfPinRepo
            Add-VmfLockRow $root @{ name = 'sanitizer'; version = '2.0.1'; license = 'MIT'; evidence = 'Sanitizer 2.0.1' } $script:goodLock
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1 -Because 'the file does not have the text, and a lock file does not excuse it'
            $f[0].detail | Should -Match 'Sanitizer 2\.0\.1'
        }
    }
}

# MERMAID-CONTENTS-1: the real rows. Which libraries are built in was read
# from the source maps of the npm packages (dist/mermaid.min.js.map of
# mermaid 11.17.2, and the chunk maps of @mermaid-js/parser 1.2.1, whose
# chunks the mermaid map names): each node_modules/.pnpm/<name>@<version>
# path is a library esbuild put in the file. Each version is a key of
# mermaid's pnpm-lock.yaml at the tag mermaid@11.17.2.
Describe 'MERMAID-CONTENTS-1: the parts list names every library built into the diagram file' {

    BeforeAll {
        . (Join-Path $script:repoRoot 'tools' '_VmfPartPins.ps1')
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        $script:mermaidPart = @($pin.parts | Where-Object key -eq 'npm:mermaid')[0]
        $script:mermaidFile = @($script:mermaidPart.files)[0]
        $script:rows = @($script:mermaidFile.contains)
    }

    It 'records the lock file of the release: its address at the tag, and its sha256' {
        $script:mermaidFile.lockFile.url | Should -BeExactly 'https://raw.githubusercontent.com/mermaid-js/mermaid/mermaid%4011.17.2/pnpm-lock.yaml'
        $script:mermaidFile.lockFile.sha256 | Should -BeExactly 'fdc5fdda2c7067c9e10cc8743e0837554c5a924a763a7e2fbaa1cbaa9a775ffa'
    }

    It 'names each of the 71 libraries once, at the version the lock file gives' {
        $script:rows.Count | Should -Be 71
        @($script:rows | ForEach-Object { "$($_.name)@$($_.version)" } | Select-Object -Unique).Count | Should -Be 71
        $want = @{
            'd3' = '7.9.0'; 'dagre-d3-es' = '7.0.14'; 'khroma' = '2.1.0'; 'marked' = '16.3.0'; 'katex' = '0.16.47'; 'roughjs' = '4.6.6'
            '@braintree/sanitize-url' = '7.1.2'; 'cytoscape' = '3.34.0'; 'langium' = '4.2.1'; 'chevrotain' = '11.1.2'; 'js-yaml' = '4.3.0'
            'uuid' = '14.0.0'; 'dompurify' = '3.4.12'; 'vscode-jsonrpc' = '8.2.0'
        }
        foreach ($name in $want.Keys) {
            @($script:rows | Where-Object name -eq $name).version | Should -Be $want[$name] -Because $name
        }
        # Two versions of one library are built in where two packages ask for two.
        foreach ($name in 'lodash-es', 'd3-array', 'd3-path', 'd3-shape', 'cose-base', 'layout-base') {
            @($script:rows | Where-Object name -eq $name).Count | Should -Be 2 -Because $name
        }
        @($script:rows | Where-Object name -eq 'lodash-es').version | Sort-Object | Should -Be @('4.17.23', '4.18.1')
    }

    It 'names no development or type-only package: those are not in the file' {
        foreach ($name in '@types/d3', '@chevrotain/types', '@iconify/types', '@microsoft/api-extractor', 'mermaid', '@mermaid-js/parser') {
            @($script:rows | Where-Object name -eq $name) | Should -BeNullOrEmpty -Because $name
        }
    }

    It 'each row has an SPDX licence, and only DOMPurify, which the file names, has an evidence text' {
        foreach ($row in $script:rows) { Test-VmfSpdxLicenseExpression ([string]$row.license) | Should -BeTrue -Because $row.name }
        @($script:rows | Where-Object { $_.PSObject.Properties['evidence'] }).name | Should -Be @('dompurify')
    }
}

Describe 'DEPS-CURRENT-1: the daily check for a newer version or an advisory (no network)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:New-VmfVersions([hashtable]$ByKey) {
            # A stand-in registry: the versions each part's source lists.
            $map = $ByKey
            { param($part) if ($map.ContainsKey($part.key)) { $v = $map[$part.key]; if ($v -is [scriptblock]) { & $v } else { $v } } else { @($part.version) } }.GetNewClosure()
        }
        $script:noAdvisory = { param($part) @() }
        # PIN-ACTIONS-1: a stand-in for GitHub's tags. Each action's tag names
        # the commit its pin records, unless the test says otherwise.
        $script:pinnedCommits = { param($part, $version) [string]$part.commit }
        function script:Invoke-VmfDrift([string]$Root, [hashtable]$Versions = @{}, [scriptblock]$Advisories = $script:noAdvisory, [scriptblock]$Commits = $script:pinnedCommits) {
            & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -VersionProvider (New-VmfVersions $Versions) -AdvisoryProvider $Advisories -CommitProvider $Commits 6>$null
        }
    }

    It 'every part at its latest version, and no advisory: nothing to report' {
        $r = Invoke-VmfDrift (New-VmfPinRepo)
        # Five parts, the two actions (PIN-ACTIONS-1) and the service's module and bundle (PIN-RUNTIME-1).
        $r.Checked | Should -Be 9
        @($r.Drifted).Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }

    It 'a newer version is a change that names the part, both versions, the release notes and where the part is used' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'image:mcr.microsoft.com/azure-powershell' = @('16.2.0', '16.4.0', '16.3.0') }
        @($r.Drifted).Count | Should -Be 1
        $d = $r.Drifted[0]
        $d.kind | Should -Be 'changed'
        $d.path | Should -Be 'Engine base image'
        $d.reason | Should -Match '16\.4\.0'
        $d.reason | Should -Match '16\.2\.0'
        $d.url | Should -Be 'https://example.com/az/releases'
        @($d.localDerivatives) | Should -Contain 'infra/part-versions.json'
        $r.ExitCode | Should -Be 1
    }

    It 'compares versions as numbers: 0.9.0 is older than 0.19.0, and 0.24.0 newer' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'bicep:mcr.microsoft.com/bicep/avm/res/web/site' = @('0.9.0', '0.19.0') }
        @($r.Drifted).Count | Should -Be 0
        $r = Invoke-VmfDrift $root @{ 'bicep:mcr.microsoft.com/bicep/avm/res/web/site' = @('0.9.0', '0.19.0', '0.24.0') }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match '0\.24\.0'
    }

    It 'a pre-release is not a newer version' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'npm:@contoso/lib' = @('1.2.3', '2.0.0-beta.1', '1.3.0-preview') }
        @($r.Drifted).Count | Should -Be 0
    }

    It 'a pin newer than every version the source lists is a change too' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'npm:@contoso/lib' = @('1.0.0', '1.2.0') }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match 'newer than'
    }

    It 'a part held on one major version is compared only inside it' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'psgallery:Pester' = @('5.7.1', '6.2.0') }
        @($r.Drifted).Count | Should -Be 0 -Because 'Pester 6 is PESTER-6-1, after 1.0'
        $r = Invoke-VmfDrift $root @{ 'psgallery:Pester' = @('5.7.1', '5.7.2', '6.2.0') }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match '5\.7\.2'
    }

    It 'a source it cannot read is NOT CHECKED, never current, and names the part' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root @{ 'npm:@contoso/lib' = { throw 'Response status code does not indicate success: 503' } }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].path | Should -Be 'Contoso library'
        $r.Drifted[0].reason | Should -Match '503'
        $r.ExitCode | Should -Be 1 -Because 'a check that cannot reach its evidence must never pass'
    }

    It 'an answer with no release in it is not checked either' {
        $root = New-VmfPinRepo
        foreach ($answer in @(@(), @('latest', 'nightly'), @('2.0.0-rc.1'))) {
            $r = Invoke-VmfDrift $root @{ 'npm:@contoso/lib' = $answer }
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'unreachable'
        }
    }

    It 'a GitHub advisory that names the pinned version is a change, with its id, its page and its severity' {
        $root = New-VmfPinRepo
        $asked = [System.Collections.Generic.List[string]]::new()
        $advisories = {
            param($part)
            $asked.Add("$($part.advisories.package)@$($part.version)")
            @([pscustomobject]@{ ghsa_id = 'GHSA-aaaa-bbbb-cccc'; html_url = 'https://github.com/advisories/GHSA-aaaa-bbbb-cccc'; severity = 'high'; summary = 'A token can leak' })
        }.GetNewClosure()
        $r = Invoke-VmfDrift $root -Advisories $advisories
        @($asked) | Should -Be @('@contoso/lib@1.2.3') -Because 'only a part with an advisory source is asked about, at its pinned version'
        @($r.Drifted).Count | Should -Be 1
        $d = $r.Drifted[0]
        $d.kind | Should -Be 'changed'
        $d.reason | Should -Match 'GHSA-aaaa-bbbb-cccc'
        $d.reason | Should -Match 'high'
        $d.reason | Should -Match '1\.2\.3'
        $d.url | Should -Be 'https://github.com/advisories/GHSA-aaaa-bbbb-cccc'
    }

    It 'each advisory is its own entry, also when the answer arrives as one list (the shape Invoke-RestMethod gives a JSON array)' {
        # MEASURED 2026-10-23, the first run against GitHub: nine advisories
        # for mermaid 11.4.1 came back as ONE entry with every id joined,
        # because the list was one object in the pipeline.
        $root = New-VmfPinRepo
        $advisories = {
            param($part)
            , @([pscustomobject]@{ ghsa_id = 'GHSA-1111-1111-1111'; html_url = 'https://github.com/advisories/GHSA-1111-1111-1111'; severity = 'low'; summary = 'one' },
                [pscustomobject]@{ ghsa_id = 'GHSA-2222-2222-2222'; html_url = 'https://github.com/advisories/GHSA-2222-2222-2222'; severity = 'high'; summary = 'two' })
        }
        $r = Invoke-VmfDrift $root -Advisories $advisories
        @($r.Drifted).Count | Should -Be 2
        @($r.Drifted.url) | Should -Be @('https://github.com/advisories/GHSA-1111-1111-1111', 'https://github.com/advisories/GHSA-2222-2222-2222')
    }
    It 'advisories it cannot read are not checked, never "none"' {
        $root = New-VmfPinRepo
        $r = Invoke-VmfDrift $root -Advisories { param($part) throw '403 rate limit' }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match 'advisor'
    }

    It 'asks each source for its versions, and sends the drift token to GitHub only' {
        $code = Get-VmfCodeOnly -Path $script:driftTool
        $code | Should -Match 'https://registry\.npmjs\.org/'
        $code | Should -Match 'https://mcr\.microsoft\.com/v2/'
        $code | Should -Match 'https://www\.powershellgallery\.com/api/v2/'
        $code | Should -Match 'https://cdn\.functions\.azure\.com/public/ExtensionBundles/' -Because 'PIN-RUNTIME-1: the index the Functions host itself downloads bundles from'
        $code | Should -Match 'https://api\.github\.com/advisories'
        $code | Should -Match 'https://api\.github\.com/repos/'
        @($code -split "`n" | Where-Object { $_ -match 'VMF_DRIFT_TOKEN' }).Count | Should -Be 1 -Because 'the token goes on the GitHub request and nowhere else'
        $code | Should -Match 'if \(\$env:VMF_DRIFT_TOKEN\) \{ \$headers\[''Authorization''\] = "Bearer \$env:VMF_DRIFT_TOKEN" \}'
    }
}

Describe 'DEPS-CURRENT-1: -UpdateBaseline moves one pin, and its references with it (no network)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:Invoke-VmfMove([string]$Root, [string]$Part, [hashtable]$Versions, [scriptblock]$Package, [scriptblock]$Commits = { param($p, $v) throw 'this test asks no tag' }) {
            $map = $Versions
            $provider = { param($p) if ($map.ContainsKey($p.key)) { $map[$p.key] } else { @($p.version) } }.GetNewClosure()
            $extra = @{}
            if ($Package) { $extra.PackageProvider = $Package }
            & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -Root $Root -VersionProvider $provider -AdvisoryProvider { param($p) @() } -CommitProvider $Commits -UpdateBaseline -Part $Part @extra 6>$null
        }
    }

    It 'asks which part: one kind of update per pull request' {
        $root = New-VmfPinRepo
        { & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider { param($p) @('99.0.0') } -AdvisoryProvider { param($p) @() } -UpdateBaseline 6>$null } |
            Should -Throw '*-Part*'
        { Invoke-VmfMove $root 'image:contoso/none' @{} } | Should -Throw '*image:contoso/none*'
    }

    It 'the engine image: the pin and both FROM lines move, and the local check then passes' {
        $root = New-VmfPinRepo
        Copy-Item -LiteralPath (Join-Path $root 'docker' 'Dockerfile') -Destination (Join-Path $root 'docker' 'Dockerfile.publish')
        Invoke-VmfMove $root 'image:mcr.microsoft.com/azure-powershell' @{ 'image:mcr.microsoft.com/azure-powershell' = @('16.2.0', '16.4.0') } | Out-Null
        $pin = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        @($pin.parts | Where-Object key -eq 'image:mcr.microsoft.com/azure-powershell')[0].version | Should -Be '16.4.0'
        foreach ($name in 'Dockerfile', 'Dockerfile.publish') {
            Get-Content -LiteralPath (Join-Path $root 'docker' $name) -Raw | Should -Match 'FROM mcr\.microsoft\.com/azure-powershell:16\.4\.0-ubuntu-24\.04'
        }
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        $pin.why | Should -Be 'test' -Because 'the rest of the file stays'
    }

    It 'a template module: the reference moves, and only that module' {
        $root = New-VmfPinRepo
        Invoke-VmfMove $root 'bicep:mcr.microsoft.com/bicep/avm/res/web/site' @{ 'bicep:mcr.microsoft.com/bicep/avm/res/web/site' = @('0.24.0') } | Out-Null
        $text = Get-Content -LiteralPath (Join-Path $root 'infra' 'main.bicep') -Raw
        $text | Should -Match "'br/public:avm/res/web/site:0\.24\.0'"
        (Get-Content -LiteralPath (Join-Path $root 'bicepconfig.json') -Raw) | Should -Match 'v1\.0:1\.0\.0'
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
    }

    It 'a test tool: each text reference moves' {
        $root = New-VmfPinRepo
        Invoke-VmfMove $root 'psgallery:Pester' @{ 'psgallery:Pester' = @('5.7.2', '6.2.0') } | Out-Null
        $text = Get-Content -LiteralPath (Join-Path $root 'tools' 'run.ps1') -Raw
        $text | Should -Match 'RequiredVersion 5\.7\.2'
        $text | Should -Match "@\('Pester', '5\.7\.2'\)"
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
    }

    It 'a library: the files come from the package, are checked against its integrity, and their sha256 is recorded' {
        $root = New-VmfPinRepo
        # A stand-in package, built the way npm lays one out.
        $pkgDir = Join-Path $script:temp ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $pkgDir 'package' 'lib')
        Set-Content -LiteralPath (Join-Path $pkgDir 'package' 'lib' 'lib.min.js') -Value '/*! @contoso/lib v1.3.0 */ var lib = 2;'
        $tgz = Join-Path $pkgDir 'lib-1.3.0.tgz'
        & tar -czf $tgz -C $pkgDir package
        $integrity = 'sha512-' + [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData([System.IO.File]::ReadAllBytes($tgz)))
        $package = { param($part, $version) [pscustomobject]@{ Path = $tgz; Integrity = $integrity } }.GetNewClosure()
        Invoke-VmfMove $root 'npm:@contoso/lib' @{ 'npm:@contoso/lib' = @('1.3.0') } $package | Out-Null
        (Get-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Raw) | Should -Match 'v1\.3\.0'
        # SBOM-1: the package address moves with the version, and the licence stays.
        $moved = @((Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json).parts)[0]
        $moved.source | Should -Be 'https://registry.npmjs.org/@contoso/lib/-/lib-1.3.0.tgz'
        $moved.license | Should -Be 'MIT'
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
    }

    It 'a package that does not match its integrity is refused, and nothing changes' {
        $root = New-VmfPinRepo
        $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
        $pkgDir = Join-Path $script:temp ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $pkgDir 'package' 'lib')
        Set-Content -LiteralPath (Join-Path $pkgDir 'package' 'lib' 'lib.min.js') -Value 'var tampered = 1;'
        $tgz = Join-Path $pkgDir 'lib.tgz'
        & tar -czf $tgz -C $pkgDir package
        $package = { param($part, $version) [pscustomobject]@{ Path = $tgz; Integrity = 'sha512-AAAA' } }.GetNewClosure()
        { Invoke-VmfMove $root 'npm:@contoso/lib' @{ 'npm:@contoso/lib' = @('1.3.0') } $package } | Should -Throw '*integrity*'
        Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Raw) | Should -Match 'var lib = 1'
    }
    # MANUAL-FONTS-1: the text a file entry removes is removed again from the
    # new package's file, before its sha256 is recorded.
    It 'a library file with text its pin removes: the text goes, the rest stays as the package has it, and the local check passes' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
            $file | Add-Member -NotePropertyName remove -NotePropertyValue @('@import url("https://fonts.example.com/a.css");')
            $file | Add-Member -NotePropertyName removeWhy -NotePropertyValue 'test' }
        $pkgDir = Join-Path $script:temp ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $pkgDir 'package' 'lib')
        [System.IO.File]::WriteAllText((Join-Path $pkgDir 'package' 'lib' 'lib.min.js'), '/*! @contoso/lib v1.3.0 */@import url("https://fonts.example.com/a.css");var lib = 2;')
        $tgz = Join-Path $pkgDir 'lib-1.3.0.tgz'
        & tar -czf $tgz -C $pkgDir package
        $integrity = 'sha512-' + [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData([System.IO.File]::ReadAllBytes($tgz)))
        $package = { param($part, $version) [pscustomobject]@{ Path = $tgz; Integrity = $integrity } }.GetNewClosure()
        Invoke-VmfMove $root 'npm:@contoso/lib' @{ 'npm:@contoso/lib' = @('1.3.0') } $package | Out-Null
        $saved = Join-Path $root 'src' 'dashboard' 'lib.min.js'
        [System.IO.File]::ReadAllText($saved) | Should -BeExactly '/*! @contoso/lib v1.3.0 */var lib = 2;'
        $pin = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
        $file.sha256 | Should -Be (Get-VmfSha256 $saved)
        @($file.remove) | Should -Be @('@import url("https://fonts.example.com/a.css");') -Because 'the pin keeps the rule for the next move'
        @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
    }

    It 'a package whose file no longer has the text the pin removes is refused, and nothing changes' {
        $root = New-VmfPinRepo
        Edit-VmfPinFile $root { param($pin) $file = @(($pin.parts | Where-Object key -eq 'npm:@contoso/lib').files)[0]
            $file | Add-Member -NotePropertyName remove -NotePropertyValue @('@import url("https://fonts.example.com/a.css");')
            $file | Add-Member -NotePropertyName removeWhy -NotePropertyValue 'test' }
        $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
        $pkgDir = Join-Path $script:temp ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $pkgDir 'package' 'lib')
        [System.IO.File]::WriteAllText((Join-Path $pkgDir 'package' 'lib' 'lib.min.js'), '/*! @contoso/lib v1.3.0 */@import url("https://fonts.example.com/b.css");var lib = 2;')
        $tgz = Join-Path $pkgDir 'lib-1.3.0.tgz'
        & tar -czf $tgz -C $pkgDir package
        $integrity = 'sha512-' + [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData([System.IO.File]::ReadAllBytes($tgz)))
        $package = { param($part, $version) [pscustomobject]@{ Path = $tgz; Integrity = $integrity } }.GetNewClosure()
        { Invoke-VmfMove $root 'npm:@contoso/lib' @{ 'npm:@contoso/lib' = @('1.3.0') } $package } | Should -Throw '*fonts.example.com/a.css*'
        Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
        (Get-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Raw) | Should -Match 'var lib = 1'
    }

    It 'only to a version it read: a failed read moves nothing' {
        $root = New-VmfPinRepo
        $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
        { & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider { param($p) throw 'offline' } -AdvisoryProvider { param($p) @() } -UpdateBaseline -Part 'image:mcr.microsoft.com/azure-powershell' 6>$null } |
            Should -Throw '*offline*'
        Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
    }
}

# MERMAID-CONTENTS-1 (2026-11-08): the lock file recorded beside the
# rows it proves is read again by the daily check, and -UpdateBaseline moves
# it with the version and says which rows to read again. The download is a
# stand-in: no test here reaches GitHub.
Describe 'MERMAID-CONTENTS-1: the lock file that proves the libraries built into a file (no network)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:lockUrl = 'https://raw.githubusercontent.com/contoso/lib/lib%401.2.3/pnpm-lock.yaml'
        $script:newLockUrl = 'https://raw.githubusercontent.com/contoso/lib/lib%401.3.0/pnpm-lock.yaml'
        # A lock file in pnpm's shape: a packages list of name@version keys.
        function script:New-VmfLockText([string[]]$Keys) {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("lockfileVersion: '9.0'"); $lines.Add(''); $lines.Add('importers:'); $lines.Add('  .:'); $lines.Add('    dependencies:')
            $lines.Add('      charts:'); $lines.Add('        specifier: ^7.0.0'); $lines.Add('        version: 7.9.0'); $lines.Add(''); $lines.Add('packages:')
            foreach ($k in $Keys) { $lines.Add(''); $lines.Add("  $($k):"); $lines.Add('    resolution: {integrity: sha512-x}') }
            ($lines -join "`n") + "`n"
        }
        function script:Get-VmfTextSha256([string]$Text) {
            ([System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join ''
        }
        $script:oldLock = New-VmfLockText @('charts@7.9.0', "'@contoso/shapes@1.0.0'", 'charts-core@3.0.0(charts@7.9.0)')
        # A repository whose library file carries three libraries: two the
        # lock file proves, and one the file itself names.
        function script:New-VmfLockRepo([string]$Lock = $script:oldLock) {
            $root = New-VmfPinRepo
            $lib = Join-Path $root 'src' 'dashboard' 'lib.min.js'
            Add-Content -LiteralPath $lib -Value '/*! @license Sanitizer 2.0.1 | MIT */'
            $sha = Get-VmfTextSha256 $Lock
            $libSha = Get-VmfSha256 $lib
            $url = $script:lockUrl
            Edit-VmfPinFile $root { param($pin) $file = @($pin.parts[0].files)[0]
                $file.sha256 = $libSha
                $file | Add-Member -NotePropertyName contains -NotePropertyValue @(
                    [pscustomobject]@{ name = 'charts'; version = '7.9.0'; license = 'ISC' },
                    [pscustomobject]@{ name = '@contoso/shapes'; version = '1.0.0'; license = 'MIT' },
                    [pscustomobject]@{ name = 'charts-core'; version = '3.0.0'; license = 'MIT' },
                    [pscustomobject]@{ name = 'sanitizer'; version = '2.0.1'; license = 'MIT'; evidence = 'Sanitizer 2.0.1' })
                $file | Add-Member -NotePropertyName lockFile -NotePropertyValue ([pscustomobject]@{ url = $url; sha256 = $sha; why = 'test' }) }.GetNewClosure()
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty -Because 'the fixture starts clean'
            $root
        }
        # A stand-in download: the text each address gives, or a failure.
        function script:New-VmfLockDownloader([hashtable]$ByUrl, [System.Collections.Generic.List[string]]$Asked) {
            $map = $ByUrl; $log = $Asked
            {
                param($Url, $OutFile)
                if ($null -ne $log) { $log.Add([string]$Url) }
                if (-not $map.ContainsKey([string]$Url)) { throw "404 Not Found: $Url" }
                [System.IO.File]::WriteAllText($OutFile, $map[[string]$Url], [System.Text.UTF8Encoding]::new($false))
            }.GetNewClosure()
        }
        function script:Invoke-VmfLockDrift([string]$Root, [scriptblock]$Downloader) {
            & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -VersionProvider { param($p) @($p.version) } -AdvisoryProvider { param($p) @() } -CommitProvider { param($p, $v) [string]$p.commit } -Downloader $Downloader 6>$null
        }
    }

    Context 'the daily check' {

        It 'a lock file as recorded, which names every row it proves: nothing to report' {
            $root = New-VmfLockRepo
            $asked = [System.Collections.Generic.List[string]]::new()
            $r = Invoke-VmfLockDrift $root (New-VmfLockDownloader @{ $script:lockUrl = $script:oldLock } $asked)
            @($asked) | Should -Be @($script:lockUrl)
            @($r.Drifted).Count | Should -Be 0
            $r.ExitCode | Should -Be 0
        }

        It 'a lock file whose sha256 is not the recorded one is a change that names the address and both sha256 values' {
            $root = New-VmfLockRepo
            $other = $script:oldLock + "`n# changed`n"
            $r = Invoke-VmfLockDrift $root (New-VmfLockDownloader @{ $script:lockUrl = $other })
            @($r.Drifted).Count | Should -Be 1
            $d = $r.Drifted[0]
            $d.kind | Should -Be 'changed'
            $d.url | Should -Be $script:lockUrl
            $d.reason | Should -Match (Get-VmfTextSha256 $other)
            $d.reason | Should -Match (Get-VmfTextSha256 $script:oldLock)
            $r.ExitCode | Should -Be 1
        }

        It 'a lock file that does not name a row it proves is a change that names the row' {
            $short = New-VmfLockText @('charts@7.9.0', 'charts-core@3.0.0(charts@7.9.0)')
            $root = New-VmfLockRepo $short
            $r = Invoke-VmfLockDrift $root (New-VmfLockDownloader @{ $script:lockUrl = $short })
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'changed'
            $r.Drifted[0].reason | Should -Match '@contoso/shapes 1\.0\.0'
        }

        It 'a name and version count only as a key of the lock file: a near version, or the name in another line, is not one' {
            $near = (New-VmfLockText @('charts@7.9.01', "'@contoso/shapes@1.0.0'", 'charts-core@3.0.0(charts@7.9.0)')) + "      charts@7.9.0:`n"
            $root = New-VmfLockRepo $near
            $r = Invoke-VmfLockDrift $root (New-VmfLockDownloader @{ $script:lockUrl = $near })
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].reason | Should -Match 'charts 7\.9\.0'
        }

        It 'a lock file it cannot download is NOT CHECKED, never current' {
            $root = New-VmfLockRepo
            $r = Invoke-VmfLockDrift $root (New-VmfLockDownloader @{})
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'unreachable'
            $r.Drifted[0].reason | Should -Match '404'
            $r.ExitCode | Should -Be 1
        }
    }

    Context '-UpdateBaseline' {

        BeforeAll {
            # The new release's package: the file no longer names Sanitizer 2.0.1.
            function script:New-VmfLibPackage([string]$Text = '/*! @contoso/lib v1.3.0 */ var lib = 2;') {
                $pkgDir = Join-Path $script:temp ('pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                $null = New-Item -ItemType Directory -Path (Join-Path $pkgDir 'package' 'lib')
                Set-Content -LiteralPath (Join-Path $pkgDir 'package' 'lib' 'lib.min.js') -Value $Text
                $tgz = Join-Path $pkgDir 'lib-1.3.0.tgz'
                & tar -czf $tgz -C $pkgDir package
                $integrity = 'sha512-' + [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData([System.IO.File]::ReadAllBytes($tgz)))
                { param($part, $version) [pscustomobject]@{ Path = $tgz; Integrity = $integrity } }.GetNewClosure()
            }
            function script:Invoke-VmfLockMove([string]$Root, [scriptblock]$Downloader, [scriptblock]$Package = (New-VmfLibPackage)) {
                # The words it says go to the information stream; keep them.
                $said = & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -Root $Root -VersionProvider { param($p) @('1.3.0') } -AdvisoryProvider { param($p) @() } -PackageProvider $Package -Downloader $Downloader -UpdateBaseline -Part 'npm:@contoso/lib' 6>&1
                @($said | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n"
            }
        }

        It 'moves the lock file address to the new release and records its sha256, and says which rows to read again' {
            $root = New-VmfLockRepo
            # charts is in the new lock file at another version too; the other
            # rows only at their own.
            $newLock = New-VmfLockText @('charts@7.9.0', 'charts@8.0.0', "'@contoso/shapes@1.0.0'", 'charts-core@3.0.0(charts@8.0.0)')
            $asked = [System.Collections.Generic.List[string]]::new()
            $said = Invoke-VmfLockMove $root (New-VmfLockDownloader @{ $script:newLockUrl = $newLock } $asked)
            @($asked) | Should -Be @($script:newLockUrl)
            $file = @((Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json).parts[0].files)[0]
            $file.lockFile.url | Should -BeExactly $script:newLockUrl
            $file.lockFile.sha256 | Should -BeExactly (Get-VmfTextSha256 $newLock)
            $file.lockFile.why | Should -Be 'test' -Because 'the reason stays'
            $said | Should -Match 'charts 7\.9\.0' -Because 'the new lock file names charts at 8.0.0 too'
            $said | Should -Not -Match '@contoso/shapes 1\.0\.0'
            $said | Should -Not -Match 'charts-core 3\.0\.0'
            $said | Should -Match 'sanitizer 2\.0\.1' -Because 'the new file does not have the text Sanitizer 2.0.1'
        }

        It 'a new lock file that does not name a row is refused: it names the row, and nothing changes' {
            $root = New-VmfLockRepo
            $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
            $newLock = New-VmfLockText @('charts@8.0.0', "'@contoso/shapes@1.0.0'", 'charts-core@3.0.0(charts@8.0.0)')
            { Invoke-VmfLockMove $root (New-VmfLockDownloader @{ $script:newLockUrl = $newLock }) } | Should -Throw '*charts 7.9.0*'
            Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
            (Get-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Raw) | Should -Match 'var lib = 1'
        }

        It 'a new lock file it cannot download is refused, and nothing changes' {
            $root = New-VmfLockRepo
            $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
            { Invoke-VmfLockMove $root (New-VmfLockDownloader @{}) } | Should -Throw '*404*'
            Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
            (Get-Content -LiteralPath (Join-Path $root 'src' 'dashboard' 'lib.min.js') -Raw) | Should -Match 'var lib = 1'
        }

        It 'a lock file address that does not name the old version once is refused: the new address cannot be made from it' {
            $root = New-VmfLockRepo
            Edit-VmfPinFile $root { param($pin) @($pin.parts[0].files)[0].lockFile.url = 'https://raw.githubusercontent.com/contoso/lib/main/pnpm-lock.yaml' }
            $before = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
            { Invoke-VmfLockMove $root (New-VmfLockDownloader @{}) } | Should -Throw '*1.2.3*'
            Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $before
        }
    }
}

# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
Describe 'DEPS-CURRENT-1: the daily upstream-drift run reports the pinned parts in its one issue' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:wf = Get-Content (Join-Path $script:workflowDir 'upstream-drift.yml') -Raw
        $m = [regex]::Match($script:wf, '(?ms)^\s+id: check\s*$.*?^\s+run: \|\s*$(?<body>.*?)^\s{6}- name:')
        $script:checkStep = (($m.Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_.TrimStart() } }) -join "`n"

        function script:Invoke-VmfDriftStep {
            param($Parts)
            $dir = Join-Path $script:temp ('wf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $dir 'tools')
            $quiet = '[pscustomobject]@{ Checked = 4; Drifted = @(); ExitCode = 0 }'
            foreach ($tool in 'Test-UpstreamDrift.ps1', 'Test-DocsDrift.ps1', 'Test-PolicyDrift.ps1', 'Test-BicepPinDrift.ps1') { Set-Content (Join-Path $dir 'tools' $tool) $quiet }
            $Parts | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'parts.json')
            Set-Content (Join-Path $dir 'tools' 'Test-VmfPartPinDrift.ps1') '$r = Get-Content (Join-Path $PSScriptRoot ".." "parts.json") -Raw | ConvertFrom-Json; [pscustomobject]@{ Checked = $r.Checked; Drifted = @($r.Drifted); ExitCode = 1 }'
            Set-Content (Join-Path $dir 'step.ps1') $script:checkStep
            $saved = @{ out = $env:GITHUB_OUTPUT; sum = $env:GITHUB_STEP_SUMMARY }
            $env:GITHUB_OUTPUT = Join-Path $dir 'output.txt'
            $env:GITHUB_STEP_SUMMARY = Join-Path $dir 'summary.md'
            Push-Location $dir
            try { & (Join-Path $dir 'step.ps1') 6>$null | Out-Null }
            finally {
                Pop-Location
                $env:GITHUB_OUTPUT = $saved.out
                $env:GITHUB_STEP_SUMMARY = $saved.sum
            }
            [pscustomobject]@{
                Issue  = Get-Content (Join-Path $dir 'drift-report.md') -Raw
                Output = Get-Content (Join-Path $dir 'output.txt') -Raw
            }
        }
    }

    It 'runs the part check with the others, and its result feeds the totals' {
        $script:checkStep | Should -Match '\$parts = \./tools/Test-VmfPartPinDrift\.ps1'
        $script:checkStep | Should -Match '\$all = [^\r\n]*\+ @\(\$parts\.Drifted\)'
        $script:checkStep | Should -Match '\$checkedCount = [^\r\n]*\+ \[int\]\$parts\.Checked'
    }

    It 'a newer version is a change in the issue, with its release notes, where it is used, and how to move the pin' {
        $parts = @{ Checked = 15; Drifted = @(@{
                    path = 'Engine base image'; kind = 'changed'
                    reason = 'mcr.microsoft.com/azure-powershell 16.4.0 is released, and the pin is 16.2.0.'
                    url = 'https://learn.microsoft.com/powershell/azure/release-notes-azureps'
                    localDerivatives = @('infra/part-versions.json', 'docker/Dockerfile')
                }) }
        $r = Invoke-VmfDriftStep $parts
        $r.Issue | Should -Match '## Parts the product ships'
        $r.Issue | Should -Match ([regex]::Escape('- **Engine base image** - mcr.microsoft.com/azure-powershell 16.4.0 is released, and the pin is 16.2.0.'))
        $r.Issue | Should -Match ([regex]::Escape('[read the page](https://learn.microsoft.com/powershell/azure/release-notes-azureps)'))
        $r.Issue | Should -Match ([regex]::Escape('re-evaluate: infra/part-versions.json, docker/Dockerfile'))
        $r.Issue | Should -Match ([regex]::Escape('./tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline -Part'))
        $r.Issue | Should -Match '^1 of 31 tracked items changed\. 0 could not be checked\.'
        $r.Output | Should -Match 'changed=1'
    }

    It 'a source it could not read is reported as not checked, never as a change' {
        $parts = @{ Checked = 15; Drifted = @(@{ path = 'Contoso library'; kind = 'unreachable'; reason = 'could not read the versions: 503'; url = 'https://registry.npmjs.org/'; localDerivatives = @('infra/part-versions.json') }) }
        $r = Invoke-VmfDriftStep $parts
        $r.Output | Should -Match 'changed=0'
        $r.Output | Should -Match 'unreachable=1'
        $r.Issue | Should -Match '(?s)## Parts the product ships.*\*\*Not checked\*\*.*Contoso library'
    }

    It 'no drift at all: the section says so' {
        $r = Invoke-VmfDriftStep @{ Checked = 15; Drifted = @() }
        $r.Output | Should -Match 'drifted=0'
        $r.Issue | Should -Match '(?s)## Parts the product ships[^#]*No drift\.'
    }
}

# PIN-RUNTIME-1, filed 2026-11-02: the service asked for Az.Accounts 5.* and the
# extension bundle [4.*, 5.0.0), so Azure installed versions nobody tested.
# MEASURED on the lab install, 2026-11-03: its managed dependencies held
# Az.Accounts 5.5.3 from 2026-09-17 and took 5.5.4 by themselves that day.
# Each is now one version in infra/part-versions.json, and a floating value in
# either file is a finding of its own, wherever the pin file lists the part.
Describe 'PIN-RUNTIME-1: the service takes one version of its module and of its extension bundle' {

    # PUBLIC-SYNC-1: the pin file names this repository's CI runner set-up and
    # CI starter, which do not ship to the public repository (PUBLIC-PINS-1).
    Context 'the repository' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

        BeforeAll {
            $script:rtPin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
            $script:facadeApp = Join-Path $script:repoRoot 'src' 'facade' 'app'
        }

        # FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1: the service no longer loads
        # Az.Accounts - it takes its tokens from the managed identity endpoint -
        # so Azure installs no module for it, and Az.Accounts is a test tool.
        It 'the service takes no module from the gallery; Az.Accounts is pinned as a test tool for the CI runner only' {
            @($script:rtPin.parts | Where-Object key -like 'psmodule:*') | Should -BeNullOrEmpty
            @($script:rtPin.updatesItself | Where-Object key -like 'psmodule:*') | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $script:facadeApp 'requirements.psd1') | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $script:facadeApp 'host.json') -Raw | ConvertFrom-Json).managedDependency.enabled | Should -BeFalse
            $az = @($script:rtPin.parts | Where-Object key -eq 'psgallery:Az.Accounts')
            $az.Count | Should -Be 1
            $az[0].version | Should -Match '^\d+\.\d+\.\d+$'
            $az[0].latest.source | Should -Be 'psgallery'
            $az[0].latest.id | Should -Be 'Az.Accounts'
            @($az[0].references.path) | Should -Be @('tools/Initialize-VmfCiRunner.ps1')
            Get-VmfCodeOnly -Path (Join-Path $script:facadeApp 'profile.ps1') | Should -Not -Match 'Az\.Accounts'
        }

        It 'pins the extension bundle at one version, read from the Functions index, in both host.json files' {
            $bundle = @($script:rtPin.parts | Where-Object key -eq 'bundle:Microsoft.Azure.Functions.ExtensionBundle')
            $bundle.Count | Should -Be 1
            $bundle[0].version | Should -Match '^\d+\.\d+\.\d+$'
            $bundle[0].tag | Should -Be '[{version}]' -Because 'NuGet interval notation: [1.0] is the exact version 1.0'
            $bundle[0].latest.source | Should -Be 'functions-cdn'
            $bundle[0].latest.id | Should -Be 'Microsoft.Azure.Functions.ExtensionBundle'
            @($script:rtPin.updatesItself | Where-Object key -like 'bundle:*').Count | Should -Be 0
            foreach ($hostFile in (Join-Path $script:facadeApp 'host.json'), (Join-Path $script:repoRoot 'infra' 'ci-schedule' 'starter-function' 'host.json')) {
                (Get-Content -LiteralPath $hostFile -Raw | ConvertFrom-Json).extensionBundle.version | Should -Be "[$($bundle[0].version)]" -Because $hostFile
            }
        }
    }

    Context 'a version that is not one version is a finding' {

        It 'a module version <Value> in requirements.psd1 is floating' -ForEach @(
            @{ Value = '5.*' }, @{ Value = '*' }, @{ Value = '5' }, @{ Value = '5.5' }, @{ Value = '5.5.*' }, @{ Value = '[5.5.3,6.0.0)' }) {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'requirements.psd1') -Value "@{ 'Az.Accounts' = '$Value' }"
            $f = @((Invoke-VmfLocalCheck $root).Findings | Where-Object kind -eq 'floating')
            $f.Count | Should -Be 1
            $f[0].key | Should -Be 'psmodule:Az.Accounts'
            $f[0].path | Should -Be 'src/facade/app/requirements.psd1'
            $f[0].detail | Should -Match ([regex]::Escape($Value))
        }

        It 'a bundle version <Value> in host.json is floating' -ForEach @(
            @{ Value = '[4.*, 5.0.0)' }, @{ Value = '[4.0.0, 5.0.0)' }, @{ Value = '[4.39.1, 5.0.0)' }, @{ Value = '4.39.1' }, @{ Value = '[4.39.1,)' }, @{ Value = '(4.39.0,4.39.2)' }, @{ Value = '[4.*]' }) {
            $root = New-VmfPinRepo
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'host.json') -Value ('{ "version": "2.0", "extensionBundle": { "id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "' + $Value + '" } }')
            $f = @((Invoke-VmfLocalCheck $root).Findings | Where-Object kind -eq 'floating')
            $f.Count | Should -Be 1 -Because "NuGet reads $Value as more than one version, or as a minimum"
            $f[0].key | Should -Be 'bundle:Microsoft.Azure.Functions.ExtensionBundle'
            $f[0].path | Should -Be 'src/facade/app/host.json'
            $f[0].detail | Should -Match ([regex]::Escape($Value))
        }

        It 'one exact version, [4.39.1] and 5.5.3, is not floating' {
            @((Invoke-VmfLocalCheck (New-VmfPinRepo)).Findings) | Should -BeNullOrEmpty
        }

        It 'a range listed under updatesItself is still floating: the pin file cannot let a range back in' {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root {
                param($pin)
                $pin.parts = @($pin.parts | Where-Object key -ne 'psmodule:Az.Accounts')
                $pin.updatesItself = @($pin.updatesItself) + [pscustomobject]@{ key = 'psmodule:Az.Accounts'; ref = '5.*'; why = 'test' }
            }
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'requirements.psd1') -Value "@{ 'Az.Accounts' = '5.*' }"
            Set-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'profile.ps1') -Value '# no import'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f.kind) | Should -Be @('floating')
            $f[0].key | Should -Be 'psmodule:Az.Accounts'
        }
    }

    Context 'the daily check and -UpdateBaseline' {

        It 'asks the Functions index for the bundle versions, unrolls the list, and takes no pre-release' {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $pin.parts = @($pin.parts | Where-Object key -eq 'bundle:Microsoft.Azure.Functions.ExtensionBundle') }
            Mock Invoke-RestMethod -ParameterFilter { [string]$Uri -eq 'https://cdn.functions.azure.com/public/ExtensionBundles/Microsoft.Azure.Functions.ExtensionBundle/index.json' } {
                , @('4.39.1', '3.41.0', '4.41.1', '4.50.0-preview')
            }
            Mock Invoke-RestMethod { throw "unexpected request $Uri" }
            $r = & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'changed'
            $r.Drifted[0].reason | Should -Match '4\.41\.1 is released, and the pin is 4\.39\.1'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { [string]$Uri -like 'https://cdn.functions.azure.com/*' }
        }

        It 'moves the bundle in every host.json, and the module in requirements.psd1 and the profile' {
            $root = New-VmfPinRepo
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'infra' 'fn') -Force
            Set-Content -LiteralPath (Join-Path $root 'infra' 'fn' 'host.json') -Value @('{', '  "version": "2.0",', '  "extensionBundle": {', '    "id": "Microsoft.Azure.Functions.ExtensionBundle",', '    "version": "[4.39.1]"', '  }', '}')
            $provider = { param($p) switch ($p.key) { 'bundle:Microsoft.Azure.Functions.ExtensionBundle' { @('4.39.1', '4.41.1') } 'psmodule:Az.Accounts' { @('5.5.3', '5.5.4') } default { @($p.version) } } }
            foreach ($key in 'bundle:Microsoft.Azure.Functions.ExtensionBundle', 'psmodule:Az.Accounts') {
                & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider $provider -AdvisoryProvider { param($p) @() } -UpdateBaseline -Part $key 6>$null | Out-Null
            }
            foreach ($hostFile in (Join-Path $root 'src' 'facade' 'app' 'host.json'), (Join-Path $root 'infra' 'fn' 'host.json')) {
                (Get-Content -LiteralPath $hostFile -Raw | ConvertFrom-Json).extensionBundle.version | Should -Be '[4.41.1]'
            }
            (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'requirements.psd1'))['Az.Accounts'] | Should -Be '5.5.4'
            Get-Content -LiteralPath (Join-Path $root 'src' 'facade' 'app' 'profile.ps1') -Raw | Should -Match ([regex]::Escape("-RequiredVersion '5.5.4'"))
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        }
    }
}

Describe 'NO-POPUPS-SIGNOUT-1: no page that signs in loads the redirect bridge, and each starts at once' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
        $script:signIn = @(Get-ChildItem -LiteralPath $script:dash -Filter '*.html' | Where-Object {
                (Get-VmfCodeOnly -Path $_.FullName -Language CStyle) -match 'new msal\.PublicClientApplication\(' })
    }

    It 'found the pages' { $script:signIn.Count | Should -BeGreaterOrEqual 8 }

    It 'each loads the library and not the bridge, and has no pop-up check to pass before it starts' {
        # The bridge answered the library's pop-up (DEPS-CURRENT-1). From v4
        # "Redirect-based flows (acquireTokenRedirect / loginRedirect) will
        # still complete" with no bridge, and for logoutRedirect it is optional
        # (lib/msal-browser/docs/v4-migration.md, Microsoft's library
        # repository). The pages already never called it outside the pop-up.
        foreach ($page in $script:signIn) {
            $html = (Get-VmfPageSource -Path $page.FullName)
            $html.IndexOf('<script src="msal-browser.min.js"></script>') | Should -BeGreaterThan 0 -Because $page.Name
            $html | Should -Not -Match 'msal-redirect-bridge' -Because "$($page.Name) loads a file that nothing calls"
            $code = Get-VmfCodeOnly -Path $page.FullName -Language CStyle
            $code | Should -Not -Match 'relaySignInWindow|msalRedirectBridge|window\.name' -Because "$($page.Name): nothing opens the library's window now"
        }
    }

    It 'the dashboard deploy does not copy the bridge' {
        $deploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $deploy | Should -Not -Match 'msal-redirect-bridge'
        $deploy | Should -Match "'msal-browser\.min\.js'"
    }

    It 'the web server serves each pinned dashboard file as a script: .js needs no new MIME map, and no new extension is added' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        foreach ($file in @($pin.parts.files | Where-Object { $_.path -like 'src/dashboard/*' })) {
            [System.IO.Path]::GetExtension($file.path) | Should -Be '.js' -Because "IIS answers 404 for an extension with no MIME map; $($file.path)"
        }
    }
}

# PIN-ACTIONS-1 (2026-11-02): a version label such as @v7 is a name its
# publisher can move to new code, and the next CI run would run that code with
# no change here. So each action is named by its full commit id, with its
# version as the comment, and it is a pinned part like any other: the local
# check holds each uses: line to the pin, the daily check reports a newer
# release AND a tag that no longer names the pinned commit, and -UpdateBaseline
# moves the commit and the comment together.
Describe 'PIN-ACTIONS-1: each GitHub Action is pinned to a full commit id' {

    BeforeAll {
        function script:Set-VmfCiLine([string]$Root, [string]$Old, [string]$New) {
            $file = Join-Path $Root '.github' 'workflows' 'ci.yml'
            $text = [System.IO.File]::ReadAllText($file)
            if (-not $text.Contains($Old)) { throw "the fixture has no '$Old'" }
            [System.IO.File]::WriteAllText($file, $text.Replace($Old, $New))
        }
        function script:Invoke-VmfActionDrift([string]$Root, [hashtable]$Versions = @{}, [scriptblock]$Commits) {
            $map = $Versions
            $provider = { param($part) if ($map.ContainsKey($part.key)) { $map[$part.key] } else { @($part.version) } }.GetNewClosure()
            & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -Root $Root -VersionProvider $provider -AdvisoryProvider { param($p) @() } -CommitProvider $Commits 6>$null
        }
    }

    Context 'the local check' {

        It 'an action named by a version label is unpinned, even when the pin file pins it, and the finding names the line' {
            $root = New-VmfPinRepo
            Set-VmfCiLine $root "actions/checkout@$($script:checkoutCommit) # v7.0.1" 'actions/checkout@v7'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1 -Because 'one line, one finding; the pin is still used, so it is not reported unused'
            $f[0].kind | Should -Be 'unpinned'
            $f[0].key | Should -Be 'action:actions/checkout'
            $f[0].path | Should -Be '.github/workflows/ci.yml'
            $f[0].detail | Should -Match 'Line 4'
            $f[0].detail | Should -Match 'actions/checkout@v7'
        }

        It 'a short commit id, a branch name and an upper-case commit id are unpinned too' {
            foreach ($ref in '0123456', 'main', '0123456789ABCDEF0123456789ABCDEF01234567', "$($script:checkoutCommit)0") {
                $root = New-VmfPinRepo
                Set-VmfCiLine $root "actions/checkout@$($script:checkoutCommit) # v7.0.1" "actions/checkout@$ref # v7.0.1"
                $f = @((Invoke-VmfLocalCheck $root).Findings)
                @($f.kind) | Should -Be @('unpinned') -Because "@$ref is not 40 lower-case hex characters"
            }
        }

        It 'an action the pin file does not list, named by a label, is unpinned' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value '      - uses: actions/setup-node@v5'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            $f.Count | Should -Be 1
            $f[0].kind | Should -Be 'unpinned'
            $f[0].key | Should -Be 'action:actions/setup-node'
        }

        It 'a comment that does not name the pinned version is a mismatch: the reader trusts the comment' {
            foreach ($line in "actions/checkout@$($script:checkoutCommit) # v7.0.0", "actions/checkout@$($script:checkoutCommit)", "actions/checkout@$($script:checkoutCommit) # 7.0.1", "actions/checkout@$($script:checkoutCommit) # v7") {
                $root = New-VmfPinRepo
                Set-VmfCiLine $root "actions/checkout@$($script:checkoutCommit) # v7.0.1" $line
                $f = @((Invoke-VmfLocalCheck $root).Findings)
                $f.Count | Should -Be 1 -Because $line
                $f[0].kind | Should -Be 'mismatch'
                $f[0].key | Should -Be 'action:actions/checkout'
                $f[0].detail | Should -Match '# v7\.0\.1'
            }
        }

        It 'an action listed as one that takes its own fixes is a mismatch: a commit id takes none' {
            $root = New-VmfPinRepo
            Edit-VmfPinFile $root { param($pin) $pin.updatesItself = @($pin.updatesItself) + [pscustomobject]@{ key = 'action:actions/cache'; ref = 'v4'; why = 'test' } }
            Add-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value '      - uses: actions/cache@v4'
            $f = @((Invoke-VmfLocalCheck $root).Findings)
            @($f | Where-Object { $_.kind -eq 'mismatch' -and $_.key -eq 'action:actions/cache' -and $_.path -eq 'infra/part-versions.json' }).Count | Should -Be 1
            @($f | Where-Object { $_.kind -eq 'unpinned' -and $_.key -eq 'action:actions/cache' }).Count | Should -Be 1
        }

        It 'a pinned action with no commit id, a commit id that is not 40 hex characters, or no GitHub repository is refused' {
            foreach ($change in @(
                    { param($pin) $a = $pin.parts | Where-Object key -eq 'action:actions/checkout'; $a.PSObject.Properties.Remove('commit') },
                    { param($pin) ($pin.parts | Where-Object key -eq 'action:actions/checkout').commit = 'v7' },
                    { param($pin) ($pin.parts | Where-Object key -eq 'action:actions/checkout').latest.source = 'npm' },
                    { param($pin) ($pin.parts | Where-Object key -eq 'action:actions/checkout').latest.repository = '' })) {
                $root = New-VmfPinRepo
                Edit-VmfPinFile $root $change
                { Invoke-VmfLocalCheck $root } | Should -Throw '*action:actions/checkout*'
            }
        }
    }

    Context 'the daily check' {

        It 'asks GitHub for the commit of the pinned tag of each action, and of nothing else' {
            $root = New-VmfPinRepo
            $asked = [System.Collections.Generic.List[string]]::new()
            $commits = { param($part, $version) $asked.Add("$($part.key)=$version"); [string]$part.commit }.GetNewClosure()
            $r = Invoke-VmfActionDrift $root -Commits $commits
            @($r.Drifted).Count | Should -Be 0
            @($asked | Sort-Object) | Should -Be @('action:actions/checkout=7.0.1', 'action:azure/login=3.1.0')
        }

        It 'a tag that names another commit than the pin is a change that names the tag and both commits' {
            $root = New-VmfPinRepo
            $moved = $script:newCommit
            $commits = { param($part, $version) if ($part.key -eq 'action:actions/checkout') { $moved } else { [string]$part.commit } }.GetNewClosure()
            $r = Invoke-VmfActionDrift $root -Commits $commits
            @($r.Drifted).Count | Should -Be 1
            $d = $r.Drifted[0]
            $d.kind | Should -Be 'changed'
            $d.key | Should -Be 'action:actions/checkout'
            $d.reason | Should -Match 'v7\.0\.1'
            $d.reason | Should -Match $script:newCommit
            $d.reason | Should -Match $script:checkoutCommit
            @($d.localDerivatives) | Should -Contain '.github/workflows/ci.yml'
            $r.ExitCode | Should -Be 1
        }

        It 'a tag it cannot read is not checked, never current' {
            $root = New-VmfPinRepo
            $r = Invoke-VmfActionDrift $root -Commits { param($part, $version) if ($part.key -eq 'action:azure/login') { throw '404 Not Found' } else { [string]$part.commit } }
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'unreachable'
            $r.Drifted[0].key | Should -Be 'action:azure/login'
            $r.Drifted[0].reason | Should -Match '404'
        }

        It 'a newer release of an action is a change, like any other part' {
            $root = New-VmfPinRepo
            $r = Invoke-VmfActionDrift $root @{ 'action:actions/checkout' = @('7.0.1', '7.1.0', '6.1.0') } -Commits { param($part, $version) [string]$part.commit }
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].reason | Should -Match '7\.1\.0'
        }
    }

    # The tool's own GitHub readers, with GitHub's answers stood in for: a
    # pin file of the two actions only, so no other source is asked.
    Context 'the GitHub readers (Invoke-RestMethod stood in for)' {

        BeforeAll {
            function script:New-VmfActionOnlyRepo {
                $root = New-VmfPinRepo
                Edit-VmfPinFile $root { param($pin) $pin.parts = @($pin.parts | Where-Object { $_.key -like 'action:*' }) }
                $root
            }
            # GitHub's answers: releases (one JSON array, which
            # Invoke-RestMethod gives as one object) and the tag refs.
            # Not $script: - the mock runs while the tool runs, and $script:
            # there is the tool's own scope. One object; only its contents change.
            $ghState = @{ Asked = [System.Collections.Generic.List[object]]::new(); Answers = @{} }
            Mock Invoke-RestMethod {
                $ghState.Asked.Add([pscustomobject]@{ Uri = [string]$Uri; Auth = [string]$Headers['Authorization'] })
                foreach ($k in $ghState.Answers.Keys) { if ([string]$Uri -like $k) { return $ghState.Answers[$k] } }
                throw "404 Not Found: $Uri"
            }
        }
        BeforeEach {
            $ghState.Asked.Clear()
            $c = $script:checkoutCommit; $l = $script:loginCommit
            $ghState.Answers = @{
                'https://api.github.com/repos/actions/checkout/releases*' = , @(
                    [pscustomobject]@{ tag_name = 'v9.0.0'; draft = $true; prerelease = $false },
                    [pscustomobject]@{ tag_name = 'v8.0.0-beta'; draft = $false; prerelease = $true },
                    [pscustomobject]@{ tag_name = 'v8.0.0'; draft = $false; prerelease = $true },
                    [pscustomobject]@{ tag_name = 'v7.0.1'; draft = $false; prerelease = $false },
                    [pscustomobject]@{ tag_name = 'v6.1.0'; draft = $false; prerelease = $false })
                'https://api.github.com/repos/azure/login/releases*'      = , @([pscustomobject]@{ tag_name = 'v3.1.0'; draft = $false; prerelease = $false })
                # A lightweight tag names the commit itself.
                'https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1' = [pscustomobject]@{ ref = 'refs/tags/v7.0.1'; object = [pscustomobject]@{ type = 'commit'; sha = $c } }
                # An annotated tag names a tag object, which names the commit.
                'https://api.github.com/repos/azure/login/git/ref/tags/v3.1.0' = [pscustomobject]@{ ref = 'refs/tags/v3.1.0'; object = [pscustomobject]@{ type = 'tag'; sha = '053f7285eb20bf5469ef084617b0b24d3cec53fc' } }
                'https://api.github.com/repos/azure/login/git/tags/053f7285eb20bf5469ef084617b0b24d3cec53fc' = [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $l } }
            }
        }

        It 'reads the releases, leaves out drafts and pre-releases, follows an annotated tag to its commit: nothing to report' {
            $r = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
            @($r.Drifted | ForEach-Object { "$($_.kind) $($_.key): $($_.reason)" }) | Should -BeNullOrEmpty
            @($ghState.Asked.Uri) | Should -Contain 'https://api.github.com/repos/azure/login/git/tags/053f7285eb20bf5469ef084617b0b24d3cec53fc'
        }

        It 'a newer release is reported by its version, with no v' {
            $ghState.Answers['https://api.github.com/repos/azure/login/releases*'] = , @([pscustomobject]@{ tag_name = 'v3.2.0'; draft = $false; prerelease = $false }, [pscustomobject]@{ tag_name = 'v3.1.0'; draft = $false; prerelease = $false })
            $r = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].key | Should -Be 'action:azure/login'
            $r.Drifted[0].reason | Should -Match '3\.2\.0 is released, and the pin is 3\.1\.0'
        }

        It 'an annotated tag whose tag object names another commit is a moved tag' {
            $ghState.Answers['https://api.github.com/repos/azure/login/git/tags/053f7285eb20bf5469ef084617b0b24d3cec53fc'] = [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $script:newCommit } }
            $r = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'changed'
            $r.Drifted[0].reason | Should -Match $script:newCommit
        }

        It 'a tag that leads to no commit is not checked, never current' {
            $ghState.Answers['https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1'] = [pscustomobject]@{ object = [pscustomobject]@{ type = 'tree'; sha = $script:newCommit } }
            $r = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'unreachable'
            $r.Drifted[0].reason | Should -Match 'does not lead to a commit'
        }

        It 'sends the drift token on every GitHub request when the workflow sets it, and none when it does not' {
            $before = $env:VMF_DRIFT_TOKEN
            try {
                $env:VMF_DRIFT_TOKEN = 'test-token'
                $null = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
                $ghState.Asked.Count | Should -BeGreaterOrEqual 5
                @($ghState.Asked | Where-Object Auth -ne 'Bearer test-token') | Should -BeNullOrEmpty
                $ghState.Asked.Clear()
                $env:VMF_DRIFT_TOKEN = $null
                $null = & $script:driftTool -PinPath (Join-Path (New-VmfActionOnlyRepo) 'infra' 'part-versions.json') -AdvisoryProvider { param($p) @() } 6>$null
                @($ghState.Asked | Where-Object Auth) | Should -BeNullOrEmpty
            }
            finally { $env:VMF_DRIFT_TOKEN = $before }
        }
    }

    Context '-UpdateBaseline' {

        It 'moves the commit and the version comment on every line, and the pin, and the local check then passes' {
            $root = New-VmfPinRepo
            Add-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Value @('  b:', '    steps:', "      - uses: actions/checkout@$($script:checkoutCommit)   #   v7.0.1")
            $asked = [System.Collections.Generic.List[string]]::new()
            $answer = $script:newCommit
            $commits = { param($part, $version) $asked.Add("$($part.key)=$version"); $answer }.GetNewClosure()
            $null = Invoke-VmfMove $root 'action:actions/checkout' @{ 'action:actions/checkout' = @('7.0.1', '7.1.0') } -Commits $commits
            @($asked) | Should -Be @('action:actions/checkout=7.1.0')
            $text = [System.IO.File]::ReadAllText((Join-Path $root '.github' 'workflows' 'ci.yml'))
            ([regex]::Matches($text, [regex]::Escape("actions/checkout@$($script:newCommit) # v7.1.0"))).Count | Should -Be 2
            $text | Should -Not -Match $script:checkoutCommit
            $text | Should -Match ([regex]::Escape("azure/login@$($script:loginCommit) # v3.1.0")) -Because 'only that action moves'
            $pin = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
            $moved = @($pin.parts | Where-Object key -eq 'action:actions/checkout')[0]
            $moved.version | Should -Be '7.1.0'
            $moved.commit | Should -Be $script:newCommit
            @((Invoke-VmfLocalCheck $root).Findings) | Should -BeNullOrEmpty
        }

        It 'a tag GitHub answers with something that is not a full commit id is refused, and nothing changes' {
            foreach ($answer in @('v7.1.0', '89abcdef', '', $null)) {
                $root = New-VmfPinRepo
                $pinBefore = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
                $ciBefore = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Raw
                $commits = { param($part, $version) $answer }.GetNewClosure()
                { Invoke-VmfMove $root 'action:actions/checkout' @{ 'action:actions/checkout' = @('7.1.0') } -Commits $commits } | Should -Throw '*commit*'
                Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $pinBefore
                Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Raw | Should -Be $ciBefore
            }
        }

        It 'a line that does not name the pinned commit is refused, and nothing changes' {
            $root = New-VmfPinRepo
            Set-VmfCiLine $root "actions/checkout@$($script:checkoutCommit) # v7.0.1" 'actions/checkout@v7'
            $pinBefore = Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw
            { Invoke-VmfMove $root 'action:actions/checkout' @{ 'action:actions/checkout' = @('7.1.0') } -Commits { param($p, $v) '89abcdef0123456789abcdef0123456789abcdef' } } | Should -Throw '*actions/checkout@v7*'
            Get-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json') -Raw | Should -Be $pinBefore
            Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'ci.yml') -Raw | Should -Match 'actions/checkout@v7'
        }
    }

    It 'the repository pins the action it uses by commit, and every workflow line matches its pin' {
        # azure/login left with the workflows that signed in to Azure
        # (WORKFLOWS-UNUSED-1, 2026-11-05).
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        foreach ($key in 'action:actions/checkout') {
            $part = @($pin.parts | Where-Object key -eq $key)
            $part.Count | Should -Be 1 -Because $key
            $part[0].commit | Should -MatchExactly '^[0-9a-f]{40}$'
            $part[0].latest.source | Should -Be 'github'
            $part[0].why | Should -Match 'PIN-ACTIONS-1'
        }
        @($pin.updatesItself.key | Where-Object { $_ -like 'action:*' }) | Should -BeNullOrEmpty
    }
}