#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SBOM-GEN-DRIFT-1: the daily drift check watches the SBOM generator.
#
# SBOM-1 pins the generator the release workflow runs (syft,
# infra/sbom-generator.json) by its version and the sha256 of its Windows
# file. Nothing watched the pin, so a newer syft that fixes a defect, or a
# GitHub advisory against the pinned one, went unreported. Now:
#   - infra/part-versions.json names the pin under pinnedElsewhere, and its
#     check is tools/Test-VmfPartPinDrift.ps1 - the script the daily
#     upstream-drift workflow already runs, so its findings reach the drift
#     issue with no change to the workflow;
#   - a newer release, a pin newer than every release, and a GitHub advisory
#     that names the pinned version are each a change; a source it cannot
#     read is NOT CHECKED, never current (UPST-4);
#   - -UpdateBaseline -Part generator:anchore/syft moves the version, the
#     release notes link, the address and the sha256 together, takes the
#     sha256 from the release's own checksums file, and refuses a file whose
#     sha256 is not the one that file gives.
#
# No test here reaches GitHub: each provider is a stand-in, and the default
# readers are tested with Invoke-RestMethod stood in for.
BeforeAll {
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'sgpin'
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $script:repoRoot 'tools' '_VmfSbom.ps1')
    $script:driftTool = Join-Path $script:repoRoot 'tools' 'Test-VmfPartPinDrift.ps1'
    $script:realParts = Join-Path $script:repoRoot 'infra' 'part-versions.json'
    $script:realGenerator = Join-Path $script:repoRoot 'infra' 'sbom-generator.json'
    $script:key = 'generator:anchore/syft'
    $script:zipBytes = [System.Text.Encoding]::UTF8.GetBytes('a stand-in for the syft 1.55.0 Windows zip')
    $script:zipSha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($script:zipBytes)).Replace('-', '').ToLowerInvariant()

    # A repository with no parts, and the generator pinned at 1.54.1.
    function script:New-VmfGeneratorRepo {
        param([string]$Version = '1.54.1', [hashtable]$Entry = @{})
        $root = Join-Path $script:temp ('repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'infra') -Force
        $generator = [ordered]@{
            schemaVersion = 1; name = 'syft'; version = $Version; license = 'Apache-2.0'; project = 'https://github.com/anchore/syft'
            releaseNotes  = "https://github.com/anchore/syft/releases/tag/v$Version"
            url           = "https://github.com/anchore/syft/releases/download/v$Version/syft_$($Version)_windows_amd64.zip"
            sha256        = '8b56e8285e295e0bbed26eeea9b16ed51c493be97ccdf42dae6326c84fe8e19f'
            executable    = 'syft.exe'; pinnedUtc = '2026-11-02T00:00:00Z'; why = 'test'
        }
        $generator | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'infra' 'sbom-generator.json')
        $elsewhere = [ordered]@{
            name = 'SBOM generator (syft)'; pin = 'infra/sbom-generator.json'; check = 'tools/Test-VmfPartPinDrift.ps1'; key = $script:key
            latest = [ordered]@{ source = 'github'; repository = 'anchore/syft' }
            advisories = [ordered]@{ ecosystem = 'go'; package = 'github.com/anchore/syft' }
            checksums = 'syft_{version}_checksums.txt'
        }
        foreach ($k in $Entry.Keys) { $elsewhere[$k] = $Entry[$k] }
        [ordered]@{
            schemaVersion   = 1; why = 'test'; parts = @(); updatesItself = @()
            ownFiles        = [ordered]@{ why = 'test'; paths = @() }
            pinnedElsewhere = @(
                [ordered]@{ name = 'Bicep CLI'; pin = 'infra/bicep-version.json'; check = 'tools/Test-BicepPinDrift.ps1' }
                $elsewhere
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'infra' 'part-versions.json')
        $root
    }
    function script:Read-VmfTestGenerator([string]$Root) { Get-Content -LiteralPath (Join-Path $Root 'infra' 'sbom-generator.json') -Raw | ConvertFrom-Json }
    # The versions GitHub's release list gives (drafts and pre-releases are
    # already left out by the reader, tested below).
    function script:New-VmfVersionsOf([string[]]$Versions) { $list = $Versions; { param($part) $list }.GetNewClosure() }
    $script:noAdvisory = { param($part) @() }
    function script:Invoke-VmfGeneratorDrift {
        param([string]$Root, [scriptblock]$Versions = (New-VmfVersionsOf '1.54.1'), [scriptblock]$Advisories = $script:noAdvisory)
        & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -Root $Root -VersionProvider $Versions -AdvisoryProvider $Advisories 6>$null
    }
    # A stand-in download: each address gives its text or bytes, and every
    # address asked and file written is recorded.
    function script:New-VmfDownloads([hashtable]$ByUrl) {
        $state = @{ Asked = [System.Collections.Generic.List[string]]::new(); Files = [System.Collections.Generic.List[string]]::new(); ByUrl = $ByUrl }
        $block = {
            param($Url, $OutFile)
            $state.Asked.Add([string]$Url)
            $state.Files.Add([string]$OutFile)
            if (-not $state.ByUrl.ContainsKey([string]$Url)) { throw "404 Not Found: $Url" }
            $body = $state.ByUrl[[string]$Url]
            if ($body -is [byte[]]) { [System.IO.File]::WriteAllBytes($OutFile, $body) } else { [System.IO.File]::WriteAllText($OutFile, [string]$body) }
        }.GetNewClosure()
        [pscustomobject]@{ Block = $block; State = $state }
    }
    $script:newZipUrl = 'https://github.com/anchore/syft/releases/download/v1.55.0/syft_1.55.0_windows_amd64.zip'
    $script:newSumsUrl = 'https://github.com/anchore/syft/releases/download/v1.55.0/syft_1.55.0_checksums.txt'
    function script:New-VmfChecksums([string]$ZipSha = $script:zipSha) {
        @(
            "7dd24987fd174ab1c85b3fc5884d060d65e5fe1f2391a9fa49c97e3101e11d69  syft_1.55.0_windows_amd64.sbom"
            "$ZipSha  syft_1.55.0_windows_amd64.zip"
            "440019acac7c5b3b44edb8d224aa226b52aadca66a1c3a0a8d58a9525f675e36  syft_1.55.0_windows_arm64.zip"
            ''
        ) -join "`n"
    }
    function script:Invoke-VmfGeneratorMove {
        param([string]$Root, [scriptblock]$Versions = (New-VmfVersionsOf '1.54.1', '1.55.0'), [scriptblock]$Downloader)
        & $script:driftTool -PinPath (Join-Path $Root 'infra' 'part-versions.json') -Root $Root -VersionProvider $Versions -AdvisoryProvider $script:noAdvisory -Downloader $Downloader -UpdateBaseline -Part $script:key 6>$null
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'SBOM-GEN-DRIFT-1: the pin names its check' {

    It 'the generator''s pinnedElsewhere entry is checked by the part pin drift check, with its release list, advisories and checksums file' {
        $parts = Get-Content -LiteralPath $script:realParts -Raw | ConvertFrom-Json
        $entry = @($parts.pinnedElsewhere | Where-Object pin -eq 'infra/sbom-generator.json')
        $entry.Count | Should -Be 1
        $entry[0].check | Should -Be 'tools/Test-VmfPartPinDrift.ps1'
        $entry[0].key | Should -Be $script:key
        $entry[0].latest.source | Should -Be 'github'
        $entry[0].latest.repository | Should -Be 'anchore/syft'
        $entry[0].advisories.ecosystem | Should -Be 'go'
        $entry[0].advisories.package | Should -Be 'github.com/anchore/syft'
        $entry[0].checksums | Should -Be 'syft_{version}_checksums.txt'
    }

    It 'no pin outside the part list is left with no check' {
        $parts = Get-Content -LiteralPath $script:realParts -Raw | ConvertFrom-Json
        foreach ($e in @($parts.pinnedElsewhere)) {
            $e.check | Should -Match '^tools/[\w-]+\.ps1$' -Because "$($e.name) needs a check that runs"
            Test-Path -LiteralPath (Join-Path $script:repoRoot $e.check) | Should -BeTrue -Because $e.check
        }
    }

    # PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
    It 'the daily drift workflow runs the part pin drift check, so the findings reach its issue' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {
        $workflow = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot '.github' 'workflows' 'upstream-drift.yml'))
        $workflow | Should -Match '\$parts = \./tools/Test-VmfPartPinDrift\.ps1\s'
        $workflow | Should -Match '@\(\$parts\.Drifted\)'
    }

    It 'the generator pin says how to move it' {
        (Get-Content -LiteralPath $script:realGenerator -Raw | ConvertFrom-Json).why | Should -Match ([regex]::Escape("Test-VmfPartPinDrift.ps1 -UpdateBaseline -Part $($script:key)"))
    }
}

Describe 'SBOM-GEN-DRIFT-1: the daily check of the generator (no network)' {

    It 'the pin at the latest release, and no advisory: nothing to report, and the generator is counted' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo)
        $r.Checked | Should -Be 1 -Because 'no parts, and one generator'
        @($r.Drifted).Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }

    It 'a newer release is a change that names both versions, the release notes, the key to move it, and where the pin is used' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo) -Versions (New-VmfVersionsOf '1.54.0', '1.55.0', '1.54.1')
        @($r.Drifted).Count | Should -Be 1
        $d = $r.Drifted[0]
        $d.kind | Should -Be 'changed'
        $d.path | Should -Be 'SBOM generator (syft)'
        $d.key | Should -Be $script:key
        $d.reason | Should -Match '1\.55\.0 is released, and the pin is 1\.54\.1'
        $d.reason | Should -Match ([regex]::Escape("-Part $($script:key)"))
        $d.url | Should -Be 'https://github.com/anchore/syft/releases/tag/v1.55.0'
        @($d.localDerivatives) | Should -Contain 'infra/sbom-generator.json'
        (@($d.localDerivatives) -join ' ') | Should -Match 'tools/New-VmfSbom\.ps1'
        $r.ExitCode | Should -Be 1
    }

    It 'compares versions as numbers: 1.54.10 is newer than 1.54.9' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo '1.54.9') -Versions (New-VmfVersionsOf '1.54.9', '1.54.10')
        @($r.Drifted | Where-Object kind -eq 'changed').Count | Should -Be 1
    }

    It 'a pin newer than every release is a change: syft has not released it, or withdrew it' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo '1.60.0') -Versions (New-VmfVersionsOf '1.54.1', '1.55.0')
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match '1\.60\.0, which is newer than the latest release, 1\.55\.0'
    }

    It 'a GitHub advisory against the pinned version is a change, named by its id and severity, with its page' {
        $advisories = { param($part)
            if ($part.version -ne '1.54.1' -or $part.advisories.package -ne 'github.com/anchore/syft' -or $part.advisories.ecosystem -ne 'go') { throw "asked for $($part.advisories.ecosystem) $($part.advisories.package) $($part.version)" }
            , @([pscustomobject]@{ ghsa_id = 'GHSA-aaaa-bbbb-cccc'; severity = 'high'; summary = 'a stand-in defect'; html_url = 'https://github.com/advisories/GHSA-aaaa-bbbb-cccc' },
                [pscustomobject]@{ ghsa_id = 'GHSA-dddd-eeee-ffff'; severity = 'low'; summary = 'another'; html_url = 'https://github.com/advisories/GHSA-dddd-eeee-ffff' })
        }
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo) -Advisories $advisories
        @($r.Drifted).Count | Should -Be 2 -Because 'each advisory is its own entry, even from one JSON array'
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].key | Should -Be $script:key
        $r.Drifted[0].reason | Should -Match 'GHSA-aaaa-bbbb-cccc \(high\)'
        $r.Drifted[0].reason | Should -Match '1\.54\.1'
        $r.Drifted[0].url | Should -Be 'https://github.com/advisories/GHSA-aaaa-bbbb-cccc'
        $r.ExitCode | Should -Be 1
    }

    It 'a release list it cannot read is NOT CHECKED, never current, and the advisories are still asked' {
        $asked = [System.Collections.Generic.List[string]]::new()
        $advisories = { param($part) $asked.Add($part.version); @() }.GetNewClosure()
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo) -Versions { param($part) throw 'Response status code does not indicate success: 403 (rate limit exceeded).' } -Advisories $advisories
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match '403'
        $r.ExitCode | Should -Be 1
        @($asked) | Should -Be @('1.54.1')
    }

    It 'a release list with no release in it is not checked either' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo) -Versions (New-VmfVersionsOf 'nightly')
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
    }

    It 'advisories it cannot read are NOT CHECKED' {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo) -Advisories { param($part) throw 'offline' }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match 'offline'
        $r.Drifted[0].reason | Should -Match 'github\.com/anchore/syft 1\.54\.1'
    }

    It 'a generator pin it cannot read is NOT CHECKED, and the other parts are still checked' {
        $root = New-VmfGeneratorRepo
        $g = Read-VmfTestGenerator $root; $g.version = 'latest'
        $g | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'infra' 'sbom-generator.json')
        $r = Invoke-VmfGeneratorDrift $root
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match 'latest'
    }

    It 'an entry with no <Field> it can use is NOT CHECKED, and says so' -ForEach @(
        @{ Field = 'key'; Entry = @{ key = 'syft' }; Says = 'generator:<owner>/<name>' }
        @{ Field = 'GitHub repository'; Entry = @{ latest = [ordered]@{ source = 'npm'; repository = 'anchore/syft' } }; Says = 'GitHub repository' }
        @{ Field = 'advisory package'; Entry = @{ advisories = [ordered]@{ ecosystem = 'go' } }; Says = 'advisories' }
        @{ Field = 'checksums file'; Entry = @{ checksums = 'checksums.txt' }; Says = 'checksums' }
    ) {
        $r = Invoke-VmfGeneratorDrift (New-VmfGeneratorRepo -Entry $Entry) -Versions { param($part) throw 'nothing may be asked' } -Advisories { param($part) throw 'nothing may be asked' }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match ([regex]::Escape($Says))
    }

    It 'reads the generator pin of the repository the pin file is in, not of -Root' {
        $root = New-VmfGeneratorRepo '1.40.0'
        $r = & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $script:repoRoot -VersionProvider (New-VmfVersionsOf '1.40.0', '1.41.0') -AdvisoryProvider $script:noAdvisory 6>$null
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'the pin is 1\.40\.0'
    }
    It 'a pinnedElsewhere entry with another check is not read here: the Bicep CLI has its own check' {
        $root = New-VmfGeneratorRepo -Entry @{ check = 'tools/Test-BicepPinDrift.ps1' }
        $r = Invoke-VmfGeneratorDrift $root -Versions { param($part) throw 'nothing may be asked' } -Advisories { param($part) throw 'nothing may be asked' }
        $r.Checked | Should -Be 0
        @($r.Drifted).Count | Should -Be 0
    }

    Context 'the default GitHub readers (Invoke-RestMethod stood in for)' {

        BeforeAll {
            # Not $script: - the mock runs while the tool runs, and $script:
            # there is the tool's own scope. One object; only its contents change.
            $ghState = @{ Asked = [System.Collections.Generic.List[object]]::new() }
            Mock Invoke-RestMethod {
                $ghState.Asked.Add([pscustomobject]@{ Uri = [string]$Uri; Auth = [string]$Headers['Authorization'] })
                if ([string]$Uri -like 'https://api.github.com/repos/anchore/syft/releases*') {
                    return , @(
                        [pscustomobject]@{ tag_name = 'v1.60.0'; draft = $true; prerelease = $false },
                        [pscustomobject]@{ tag_name = 'v1.59.0'; draft = $false; prerelease = $true },
                        [pscustomobject]@{ tag_name = 'v1.55.0'; draft = $false; prerelease = $false },
                        [pscustomobject]@{ tag_name = 'v1.54.1'; draft = $false; prerelease = $false })
                }
                if ([string]$Uri -like 'https://api.github.com/advisories*') { return , @() }
                throw "404 Not Found: $Uri"
            }
        }
        BeforeEach { $ghState.Asked.Clear() }

        It 'reads syft''s releases, leaves out drafts and pre-releases, and asks for advisories of the Go package at the pinned version' {
            $r = & $script:driftTool -PinPath (Join-Path (New-VmfGeneratorRepo) 'infra' 'part-versions.json') 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].reason | Should -Match '1\.55\.0 is released, and the pin is 1\.54\.1'
            @($ghState.Asked.Uri) | Should -Contain 'https://api.github.com/repos/anchore/syft/releases?per_page=100'
            $advisory = @($ghState.Asked.Uri | Where-Object { $_ -like 'https://api.github.com/advisories*' })
            $advisory.Count | Should -Be 1
            $advisory[0] | Should -Match 'ecosystem=go&'
            $advisory[0] | Should -Match ([regex]::Escape('affects=' + [uri]::EscapeDataString('github.com/anchore/syft@1.54.1')))
        }

        It 'sends the drift token on each GitHub request when the workflow sets it' {
            $before = $env:VMF_DRIFT_TOKEN
            try {
                $env:VMF_DRIFT_TOKEN = 'test-token'
                $null = & $script:driftTool -PinPath (Join-Path (New-VmfGeneratorRepo) 'infra' 'part-versions.json') 6>$null
                $ghState.Asked.Count | Should -Be 2
                @($ghState.Asked | Where-Object Auth -ne 'Bearer test-token') | Should -BeNullOrEmpty
            }
            finally { $env:VMF_DRIFT_TOKEN = $before }
        }
    }
}

Describe 'SBOM-GEN-DRIFT-1: -UpdateBaseline moves the generator pin as one unit (no network)' {

    It 'moves the version, the release notes link, the address and the sha256 from the checksums file, and keeps the rest' {
        $root = New-VmfGeneratorRepo
        $partsBefore = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'part-versions.json'))
        $dl = New-VmfDownloads @{ $script:newSumsUrl = (New-VmfChecksums); $script:newZipUrl = $script:zipBytes }
        Invoke-VmfGeneratorMove $root -Downloader $dl.Block | Out-Null
        $g = Read-VmfTestGenerator $root
        $g.version | Should -Be '1.55.0'
        $g.releaseNotes | Should -Be 'https://github.com/anchore/syft/releases/tag/v1.55.0'
        $g.url | Should -Be $script:newZipUrl
        $g.sha256 | Should -Be $script:zipSha
        # Read as text: ConvertFrom-Json turns the date into a date value.
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -Not -Match '2026-11-02T00:00:00Z'
        $g.executable | Should -Be 'syft.exe'
        $g.license | Should -Be 'Apache-2.0'
        $g.why | Should -Be 'test'
        @($dl.State.Asked) | Should -Be @($script:newSumsUrl, $script:newZipUrl)
        # The release tool still reads it.
        { Read-VmfSbomGeneratorPin -Path (Join-Path $root 'infra' 'sbom-generator.json') } | Should -Not -Throw
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'part-versions.json')) | Should -BeExactly $partsBefore
    }

    It 'takes the downloads away again (TEMP-LITTER-1)' {
        $dl = New-VmfDownloads @{ $script:newSumsUrl = (New-VmfChecksums); $script:newZipUrl = $script:zipBytes }
        Invoke-VmfGeneratorMove (New-VmfGeneratorRepo) -Downloader $dl.Block | Out-Null
        $dl.State.Files.Count | Should -Be 2
        foreach ($f in $dl.State.Files) { Test-Path -LiteralPath (Split-Path -Parent $f) | Should -BeFalse -Because $f }
    }

    It 'refuses a file whose sha256 is not the one the checksums file gives, and changes nothing' {
        $root = New-VmfGeneratorRepo
        $before = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json'))
        $dl = New-VmfDownloads @{ $script:newSumsUrl = (New-VmfChecksums ('0' * 64)); $script:newZipUrl = $script:zipBytes }
        { Invoke-VmfGeneratorMove $root -Downloader $dl.Block } | Should -Throw "*$($script:zipSha)*"
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -BeExactly $before
        foreach ($f in $dl.State.Files) { Test-Path -LiteralPath (Split-Path -Parent $f) | Should -BeFalse -Because 'a refusal takes the downloads away too' }
    }

    It 'refuses a checksums file that gives no sha256, or two, for the file' -ForEach @(
        @{ Case = 'no line'; Body = "7dd24987fd174ab1c85b3fc5884d060d65e5fe1f2391a9fa49c97e3101e11d69  syft_1.55.0_windows_amd64.sbom`n" }
        @{ Case = 'not a sha256'; Body = "not-a-hash  syft_1.55.0_windows_amd64.zip`n" }
        @{ Case = 'two lines'; Body = "$('a' * 64)  syft_1.55.0_windows_amd64.zip`n$('b' * 64)  syft_1.55.0_windows_amd64.zip`n" }
        @{ Case = 'another file whose name ends the same'; Body = "$('a' * 64)  other-syft_1.55.0_windows_amd64.zip`n" }
    ) {
        $root = New-VmfGeneratorRepo
        $before = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json'))
        $dl = New-VmfDownloads @{ $script:newSumsUrl = $Body; $script:newZipUrl = $script:zipBytes }
        { Invoke-VmfGeneratorMove $root -Downloader $dl.Block } | Should -Throw '*syft_1.55.0_checksums.txt gives * sha256 lines for syft_1.55.0_windows_amd64.zip, and the pin needs exactly one*'
        $dl.State.Asked | Should -Not -Contain $script:newZipUrl -Because 'the file is not downloaded when the checksums file gives no one sha256 for it'
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -BeExactly $before
    }

    It 'a download that writes no <Which> is refused, and changes nothing' -ForEach @(
        @{ Which = 'checksums file'; Url = 'sums' }
        @{ Which = 'zip'; Url = 'zip' }
    ) {
        $root = New-VmfGeneratorRepo
        $before = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json'))
        $skip = if ($Url -eq 'sums') { $script:newSumsUrl } else { $script:newZipUrl }
        $sums = New-VmfChecksums
        $zip = $script:zipBytes
        $sumsUrl = $script:newSumsUrl
        $block = { param($U, $OutFile) if ($U -eq $skip) { return }; if ($U -eq $sumsUrl) { [System.IO.File]::WriteAllText($OutFile, $sums) } else { [System.IO.File]::WriteAllBytes($OutFile, $zip) } }.GetNewClosure()
        { Invoke-VmfGeneratorMove $root -Downloader $block } | Should -Throw "*$skip wrote no file*"
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -BeExactly $before
    }
    It 'takes a checksums file with Windows line ends' {
        $root = New-VmfGeneratorRepo
        $dl = New-VmfDownloads @{ $script:newSumsUrl = ((New-VmfChecksums) -replace "`n", "`r`n"); $script:newZipUrl = $script:zipBytes }
        Invoke-VmfGeneratorMove $root -Downloader $dl.Block | Out-Null
        (Read-VmfTestGenerator $root).sha256 | Should -Be $script:zipSha
    }

    It 'with no release it could read, the pin stays and nothing is downloaded' {
        $root = New-VmfGeneratorRepo
        $before = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json'))
        $dl = New-VmfDownloads @{}
        { Invoke-VmfGeneratorMove $root -Versions { param($part) throw 'offline' } -Downloader $dl.Block } | Should -Throw '*offline*'
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -BeExactly $before
        $dl.State.Asked.Count | Should -Be 0
    }

    It 'a pin already at the latest release is left as it is, and nothing is downloaded' {
        $root = New-VmfGeneratorRepo '1.55.0'
        $before = [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json'))
        $dl = New-VmfDownloads @{}
        Invoke-VmfGeneratorMove $root -Downloader $dl.Block | Out-Null
        [System.IO.File]::ReadAllText((Join-Path $root 'infra' 'sbom-generator.json')) | Should -BeExactly $before
        $dl.State.Asked.Count | Should -Be 0
    }

    It 'a pin whose address or release notes do not name its version is refused, not guessed at' {
        $root = New-VmfGeneratorRepo
        $g = Read-VmfTestGenerator $root; $g.releaseNotes = 'https://github.com/anchore/syft/releases'
        $g | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'infra' 'sbom-generator.json')
        $dl = New-VmfDownloads @{ $script:newSumsUrl = (New-VmfChecksums); $script:newZipUrl = $script:zipBytes }
        { Invoke-VmfGeneratorMove $root -Downloader $dl.Block } | Should -Throw '*releaseNotes*'
        (Read-VmfTestGenerator $root).version | Should -Be '1.54.1'
    }

    It 'the key of the generator is named when -Part names nothing the pin file has' {
        $root = New-VmfGeneratorRepo
        { & $script:driftTool -PinPath (Join-Path $root 'infra' 'part-versions.json') -Root $root -VersionProvider (New-VmfVersionsOf '1.54.1') -AdvisoryProvider $script:noAdvisory -UpdateBaseline -Part 'nothing:here' 6>$null } |
            Should -Throw "*$($script:key)*"
    }
}
