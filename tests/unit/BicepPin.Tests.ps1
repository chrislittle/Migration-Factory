#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BICEP-PIN-1, 2026-10-18: ONE Bicep CLI version, pinned in
# infra/bicep-version.json.
#
# It replaces the upgrade at each start that CI-ONDEMAND-1 and
# CI-LINUX-RUNNER-1 added on 2026-10-17 ("that seems a bit much... I didn't
# realize every VM would do it every start"). Now:
#   - CI installs the pinned version only when the runner has another one
#     (tools/Sync-VmfBicepVersion.ps1), and fails if it still has another.
#   - The runner set-up installs the pinned version on a new machine.
#   - The daily upstream-drift check reports a newer Bicep release into its
#     one issue (tools/Test-BicepPinDrift.ps1). A failed read is "not
#     checked", never "current".
#
# No test here reaches GitHub or the real az: each provider is a stand-in.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_WorkflowCommands.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'bpin'

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pinPath = Join-Path $script:repoRoot 'infra' 'bicep-version.json'
    $script:driftTool = Join-Path $script:repoRoot 'tools' 'Test-BicepPinDrift.ps1'
    $script:syncTool = Join-Path $script:repoRoot 'tools' 'Sync-VmfBicepVersion.ps1'
    $script:workflowDir = Join-Path $script:repoRoot '.github' 'workflows'

    function script:New-VmfTestPin {
        param([string]$Version = '0.48.1')
        $file = Join-Path $script:temp "pin-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
        [ordered]@{ schemaVersion = 1; version = $Version; releases = 'https://github.com/Azure/bicep/releases'; pinnedUtc = '2026-10-18T00:00:00Z'; why = 'test' } |
            ConvertTo-Json | Set-Content -LiteralPath $file
        $file
    }
    # The shape of GitHub's "latest release" answer, as far as the check reads it.
    function script:New-VmfTestRelease {
        param([string]$Tag = 'v0.48.1', [bool]$Prerelease = $false, [bool]$Draft = $false)
        $answer = [pscustomobject]@{ tag_name = $Tag; prerelease = $Prerelease; draft = $Draft; html_url = "https://github.com/Azure/bicep/releases/tag/$Tag" }
        { $answer }.GetNewClosure()
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'BICEP-PIN-1: one pin, in one file' {

    It 'infra/bicep-version.json pins one Bicep version, three numbers, and says where releases are' {
        $pin = Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json
        $pin.schemaVersion | Should -Be 1
        $pin.version | Should -Match '^\d+\.\d+\.\d+$'
        $pin.releases | Should -Be 'https://github.com/Azure/bicep/releases'
        $pin.why | Should -Match 'BICEP-PIN-1'
    }

    It 'no workflow and no runner script writes a Bicep version of its own' {
        # A second copy of the version is the copy nobody moves.
        # PUBLIC-SYNC-1: the workflows and the CI runner files do not ship to
        # the public repository; there it reads the ones that are there.
        $runnerFiles = @((Join-Path $script:repoRoot 'tools' 'Initialize-VmfCiPoolRunner.ps1'),
                     (Join-Path $script:repoRoot 'tools' 'Initialize-VmfCiLinuxRunner.sh'),
                     (Join-Path $script:repoRoot 'tools' 'Initialize-VmfCiRunner.ps1'),
                     (Join-Path $script:repoRoot 'infra' 'ci-runners.bicep'),
                     (Join-Path $script:repoRoot 'infra' 'ci-linux-runner.bicep'))
        if (Test-Path (Join-Path $script:repoRoot 'infra' 'ci-runners.bicep')) { $runnerFiles = @(Get-Item $runnerFiles) } else { $runnerFiles = @() }
        $files = @(if (Test-Path $script:workflowDir) { Get-ChildItem $script:workflowDir -Filter '*.yml' }) + $runnerFiles + @(
            Get-Item (Join-Path $script:repoRoot 'tools' 'Sync-VmfBicepVersion.ps1'))
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text | Should -Not -Match '(?i)bicep install (--version|-v) +v?\d' -Because $file.Name
            $text | Should -Not -Match '(?i)bicep[^\n]{0,40}\b0\.\d+\.\d+\b' -Because $file.Name
        }
    }
}

Describe 'BICEP-PIN-1: the drift check against Bicep''s latest release (no network)' {

    It 'reports nothing when the pin is the latest release' {
        $r = & $script:driftTool -PinPath (New-VmfTestPin '0.48.1') -ReleaseProvider (New-VmfTestRelease 'v0.48.1') 6>$null
        $r.Checked | Should -Be 1
        @($r.Drifted).Count | Should -Be 0
        $r.ExitCode | Should -Be 0
    }

    It 'a newer release is drift, and the report names both versions, the release page and the pin file' {
        $r = & $script:driftTool -PinPath (New-VmfTestPin '0.48.1') -ReleaseProvider (New-VmfTestRelease 'v0.49.0') 6>$null
        @($r.Drifted).Count | Should -Be 1
        $d = $r.Drifted[0]
        $d.kind | Should -Be 'changed'
        $d.path | Should -Be 'infra/bicep-version.json'
        $d.reason | Should -Match '0\.49\.0'
        $d.reason | Should -Match '0\.48\.1'
        $d.url | Should -Be 'https://github.com/Azure/bicep/releases/tag/v0.49.0'
        @($d.localDerivatives) -join ' ' | Should -Match 'infra/bicep-version\.json'
        $r.ExitCode | Should -Be 1
    }

    It 'compares versions as numbers, not as text: 0.48.10 is newer than 0.48.9' {
        $r = & $script:driftTool -PinPath (New-VmfTestPin '0.48.9') -ReleaseProvider (New-VmfTestRelease 'v0.48.10') 6>$null
        @($r.Drifted | Where-Object kind -eq 'changed').Count | Should -Be 1
        $r = & $script:driftTool -PinPath (New-VmfTestPin '0.48.10') -ReleaseProvider (New-VmfTestRelease 'v0.48.9') 6>$null
        @($r.Drifted | Where-Object { $_.reason -match 'newer than' }).Count | Should -Be 1
    }

    It 'a pin newer than the latest release is drift too: the pin names a version Bicep has not released' {
        $r = & $script:driftTool -PinPath (New-VmfTestPin '0.50.0') -ReleaseProvider (New-VmfTestRelease 'v0.48.1') 6>$null
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'changed'
        $r.Drifted[0].reason | Should -Match '0\.50\.0'
        $r.Drifted[0].reason | Should -Match 'newer than'
    }

    It 'a release it cannot read is NOT CHECKED - never "current"' {
        # The rate limit is the case that has happened here (UPST-4, 2026-09-13).
        $r = & $script:driftTool -PinPath (New-VmfTestPin) -ReleaseProvider { throw 'Response status code does not indicate success: 403 (rate limit exceeded).' } 6>$null
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].kind | Should -Be 'unreachable'
        $r.Drifted[0].reason | Should -Match '403'
        $r.Drifted[0].url | Should -Be 'https://github.com/Azure/bicep/releases'
        $r.ExitCode | Should -Be 1 -Because 'a check that cannot reach its evidence must never pass'
    }

    It 'an answer with no version in it, a pre-release or a draft is not checked either' {
        foreach ($release in @((New-VmfTestRelease 'nightly'), (New-VmfTestRelease ''), (New-VmfTestRelease 'v0.49.0' $true), (New-VmfTestRelease 'v0.49.0' $false $true))) {
            $r = & $script:driftTool -PinPath (New-VmfTestPin) -ReleaseProvider $release 6>$null
            @($r.Drifted).Count | Should -Be 1
            $r.Drifted[0].kind | Should -Be 'unreachable'
        }
    }

    It 'a pin file with no version stops the check with its name, rather than reporting a guess' {
        { & $script:driftTool -PinPath (New-VmfTestPin 'latest') -ReleaseProvider (New-VmfTestRelease) 6>$null } | Should -Throw '*latest*'
    }

    It '-UpdateBaseline moves the pin to the latest release, and only to a release it read' {
        $pin = New-VmfTestPin '0.48.1'
        & $script:driftTool -PinPath $pin -ReleaseProvider (New-VmfTestRelease 'v0.49.2') -UpdateBaseline 6>$null | Out-Null
        $after = Get-Content -LiteralPath $pin -Raw | ConvertFrom-Json
        $after.version | Should -Be '0.49.2'
        $after.why | Should -Be 'test' -Because 'the rest of the file stays'
        { & $script:driftTool -PinPath $pin -ReleaseProvider { throw 'offline' } -UpdateBaseline 6>$null } | Should -Throw '*offline*'
        (Get-Content -LiteralPath $pin -Raw | ConvertFrom-Json).version | Should -Be '0.49.2'
    }

    It 'asks GitHub for the latest release of Azure/bicep, with the drift token when the workflow gives one' {
        $code = Get-VmfCodeOnly -Path $script:driftTool
        $code | Should -Match 'https://api\.github\.com/repos/Azure/bicep/releases/latest'
        $code | Should -Match 'if \(\$env:VMF_DRIFT_TOKEN\) \{ \$headers\[''Authorization''\] = "Bearer \$env:VMF_DRIFT_TOKEN" \}'
    }
}

# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
# There this runs on the public workflow (public/.github), once there is one.
Describe 'BICEP-PIN-1: the daily upstream-drift run reports the Bicep pin in its one issue' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {

    BeforeAll {
        $script:wf = Get-Content (Join-Path $script:workflowDir 'upstream-drift.yml') -Raw
        $m = [regex]::Match($script:wf, '(?ms)^\s+id: check\s*$.*?^\s+run: \|\s*$(?<body>.*?)^\s{6}- name:')
        $script:checkStep = (($m.Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_.TrimStart() } }) -join "`n"

        # The check step RUN, with stand-in checks: the DocsDrift.Tests.ps1 way.
        function script:Invoke-VmfDriftStep {
            param($Bicep)
            $dir = Join-Path $script:temp ('wf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $dir 'tools')
            $quiet = '[pscustomobject]@{ Checked = 4; Drifted = @(); ExitCode = 0 }'
            # DEPS-CURRENT-1: the fifth check, Test-VmfPartPinDrift.ps1, runs in the same step.
            foreach ($tool in 'Test-UpstreamDrift.ps1', 'Test-DocsDrift.ps1', 'Test-PolicyDrift.ps1', 'Test-VmfPartPinDrift.ps1') { Set-Content (Join-Path $dir 'tools' $tool) $quiet }
            $Bicep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'bicep.json')
            Set-Content (Join-Path $dir 'tools' 'Test-BicepPinDrift.ps1') '$r = Get-Content (Join-Path $PSScriptRoot ".." "bicep.json") -Raw | ConvertFrom-Json; [pscustomobject]@{ Checked = $r.Checked; Drifted = @($r.Drifted); ExitCode = 1 }'
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

    It 'runs the Bicep check with the others, and its result feeds the totals' {
        $script:checkStep | Should -Match '\$bicep = \./tools/Test-BicepPinDrift\.ps1'
        $script:checkStep | Should -Match '\$all = @\(\$scripts\.Drifted\) \+ @\(\$docs\.Drifted\) \+ @\(\$policies\.Drifted\) \+ @\(\$bicep\.Drifted\)'
        $script:checkStep | Should -Match '\[int\]\$policies\.Checked \+ \[int\]\$bicep\.Checked'
    }

    It 'a newer Bicep release is a change in the issue, with its page, its rule and how to re-pin' {
        $bicep = @{ Checked = 1; Drifted = @(@{
                    path = 'infra/bicep-version.json'; kind = 'changed'
                    reason = 'Bicep 0.49.0 is released, and the pin is 0.48.1.'
                    url = 'https://github.com/Azure/bicep/releases/tag/v0.49.0'
                    localDerivatives = @('infra/bicep-version.json')
                }) }
        $r = Invoke-VmfDriftStep $bicep
        $r.Issue | Should -Match '## Bicep CLI version'
        $r.Issue | Should -Match ([regex]::Escape('- **infra/bicep-version.json** - Bicep 0.49.0 is released, and the pin is 0.48.1.'))
        $r.Issue | Should -Match ([regex]::Escape('[read the page](https://github.com/Azure/bicep/releases/tag/v0.49.0)'))
        $r.Issue | Should -Match ([regex]::Escape('./tools/Test-BicepPinDrift.ps1 -UpdateBaseline'))
        $r.Issue | Should -Match '^1 of 17 tracked items changed\. 0 could not be checked\.'
        $r.Output | Should -Match 'changed=1'
        $r.Output | Should -Match 'unreachable=0'
    }

    It 'a release it could not read is reported as not checked, never as current and never as a change' {
        $bicep = @{ Checked = 1; Drifted = @(@{
                    path = 'infra/bicep-version.json'; kind = 'unreachable'
                    reason = 'could not read the latest release: 403'
                    url = 'https://github.com/Azure/bicep/releases'
                    localDerivatives = @('infra/bicep-version.json')
                }) }
        $r = Invoke-VmfDriftStep $bicep
        $r.Output | Should -Match 'changed=0'
        $r.Output | Should -Match 'unreachable=1'
        $r.Output | Should -Match 'drifted=1'
        $r.Issue | Should -Match '(?s)## Bicep CLI version.*\*\*Not checked\*\*.*infra/bicep-version\.json'
    }

    It 'no drift at all: the Bicep section says so' {
        $r = Invoke-VmfDriftStep @{ Checked = 1; Drifted = @() }
        $r.Output | Should -Match 'drifted=0'
        $r.Issue | Should -Match '(?s)## Bicep CLI version[^#]*No drift\.'
    }
}

Describe 'BICEP-PIN-1: CI installs the pinned Bicep only when the runner has another (stand-in az)' {

    BeforeAll {
        # A stand-in az: a PowerShell script that records each call and keeps
        # the "installed" version in a file. The real az never runs here.
        $script:fakeRoot = Join-Path $script:temp 'az'
        $null = New-Item -ItemType Directory -Path $script:fakeRoot
        $script:fakeAz = Join-Path $script:fakeRoot 'az.ps1'
        Set-Content -LiteralPath $script:fakeAz -Value @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Content -LiteralPath (Join-Path $root 'calls.txt') -Value ($args -join ' ')
Add-Content -LiteralPath (Join-Path $root 'env.txt') -Value "$env:AZURE_BICEP_USE_BINARY_FROM_PATH"
$stateFile = Join-Path $root 'installed.txt'
$have = (Get-Content -LiteralPath $stateFile -Raw).Trim()
if ($args[0] -eq 'bicep' -and $args[1] -eq 'version') {
    if ($have -eq 'none') { 'Bicep CLI not found. Install it now by running "az bicep install".' }
    else { "Bicep CLI version $have (cec7951cf6)" }
    exit 0
}
if ($args[0] -eq 'bicep' -and $args[1] -eq 'install') {
    if ($env:VMF_FAKE_INSTALL_EXIT -and $env:VMF_FAKE_INSTALL_EXIT -ne '0') { 'ERROR: the download failed'; exit [int]$env:VMF_FAKE_INSTALL_EXIT }
    if ($env:VMF_FAKE_INSTALL_STICKS -ne '0') { Set-Content -LiteralPath $stateFile -Value ($args[3] -replace '^v', '') }
    'Successfully installed Bicep CLI'
    exit 0
}
if ($args[0] -eq 'bicep' -and $args[1] -eq 'restore' -and $args[2] -eq '--file') {
    # CI-BICEP-RESTORE-1: a file whose name is in VMF_FAKE_RESTORE_FAIL fails
    # as a cold cache behind the network floor did on a new runner.
    if ($env:VMF_FAKE_RESTORE_FAIL -and (Split-Path -Leaf $args[3]) -eq $env:VMF_FAKE_RESTORE_FAIL) {
        "ERROR: $($args[3])(1,10) : Error BCP192: Unable to restore the artifact with reference ""br:mcr.microsoft.com/bicep/avm/res/web/site:0.19.0"""
        exit 1
    }
    # A file named in VMF_FAKE_RESTORE_FAIL_ONCE fails the first time only.
    $once = Join-Path (Split-Path -Parent $stateFile) 'failed-once.txt'
    if ($env:VMF_FAKE_RESTORE_FAIL_ONCE -and (Split-Path -Leaf $args[3]) -eq $env:VMF_FAKE_RESTORE_FAIL_ONCE -and -not (Test-Path -LiteralPath $once)) {
        Set-Content -LiteralPath $once -Value 'x'
        "ERROR: $($args[3])(1,10) : Error BCP192: a short refusal"
        exit 1
    }
    exit 0
}
exit 3
'@
        # CI-BICEP-RESTORE-1: a repository with templates. Only the ones that
        # use a registry module or extension are restored.
        $script:restoreRoot = Join-Path $script:temp 'repo'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:restoreRoot 'infra' 'nested'), (Join-Path $script:restoreRoot 'lab'), (Join-Path $script:restoreRoot 'other')
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'infra' 'public.bicep') -Value "module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {`n  name: 'logs'`n}"
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'infra' 'nested' 'registry.bicep') -Value "module a 'br:contoso.azurecr.io/bicep/a:1.0.0' = {`n  name: 'a'`n}"
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'infra' 'graph.bicep') -Value "extension microsoftGraphV1`nparam name string"
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'lab' 'fleet.bicep') -Value "module v 'br/public:avm/res/compute/virtual-machine:0.1.0' = {`n  name: 'v'`n}"
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'infra' 'local.bicep') -Value "module p 'platform.bicep' = {`n  name: 'p'`n}`n// module old 'br/public:avm/res/web/site:0.1.0' = {"
        Set-Content -LiteralPath (Join-Path $script:restoreRoot 'other' 'elsewhere.bicep') -Value "module x 'br/public:avm/res/web/site:0.19.0' = {`n  name: 'x'`n}"
        $script:restoreFiles = @(
            (Join-Path $script:restoreRoot 'infra' 'graph.bicep'),
            (Join-Path $script:restoreRoot 'infra' 'nested' 'registry.bicep'),
            (Join-Path $script:restoreRoot 'infra' 'public.bicep'),
            (Join-Path $script:restoreRoot 'lab' 'fleet.bicep'))
        $script:restoreCalls = @($script:restoreFiles | ForEach-Object { "bicep restore --file $_" })

        function script:Invoke-VmfTestSync {
            param([string]$Installed, [string]$Pin = '0.48.1', [string]$InstallExit = '0', [string]$Sticks = '1', [string]$RestoreFail = '')
            Remove-Item (Join-Path $script:fakeRoot 'calls.txt'), (Join-Path $script:fakeRoot 'env.txt') -ErrorAction SilentlyContinue
            Set-Content -LiteralPath (Join-Path $script:fakeRoot 'installed.txt') -Value $Installed
            $ghEnv = Join-Path $script:temp "github-env-$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt"
            $saved = @{ gh = $env:GITHUB_ENV; bin = $env:AZURE_BICEP_USE_BINARY_FROM_PATH }
            $env:GITHUB_ENV = $ghEnv
            $env:VMF_FAKE_INSTALL_EXIT = $InstallExit
            $env:VMF_FAKE_INSTALL_STICKS = $Sticks
            $env:VMF_FAKE_RESTORE_FAIL = $RestoreFail
            $result = $null; $failure = $null
            try { $result = & $script:syncTool -PinPath (New-VmfTestPin $Pin) -Az $script:fakeAz -RestoreRoot $script:restoreRoot 6>$null }
            catch { $failure = $_.Exception.Message }
            finally {
                $env:GITHUB_ENV = $saved.gh
                $env:AZURE_BICEP_USE_BINARY_FROM_PATH = $saved.bin
                $env:VMF_FAKE_INSTALL_EXIT = ''
                $env:VMF_FAKE_INSTALL_STICKS = ''
                $env:VMF_FAKE_RESTORE_FAIL = ''
            }
            $read = { param($file) if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file) } else { @() } }
            [pscustomobject]@{
                Result  = $result
                Failure = $failure
                Calls   = & $read (Join-Path $script:fakeRoot 'calls.txt')
                AzEnv   = & $read (Join-Path $script:fakeRoot 'env.txt')
                GhEnv   = & $read $ghEnv
            }
        }
    }

    It 'the runner has the pinned version: nothing is installed' {
        $r = Invoke-VmfTestSync -Installed '0.48.1'
        $r.Failure | Should -BeNullOrEmpty
        $r.Calls | Should -Be (@('bicep version') + $script:restoreCalls)
        $r.Result.Installed | Should -BeFalse
        $r.Result.Version | Should -Be '0.48.1'
    }

    It 'the runner has another version: the pinned one is installed, then read back' {
        $r = Invoke-VmfTestSync -Installed '0.47.0'
        $r.Failure | Should -BeNullOrEmpty
        $r.Calls | Should -Be (@('bicep version', 'bicep install --version v0.48.1', 'bicep version') + $script:restoreCalls)
        $r.Result.Installed | Should -BeTrue
        $r.Result.Before | Should -Be '0.47.0'
        $r.Result.Version | Should -Be '0.48.1'
    }

    It 'a newer version on the runner is replaced too: the pin decides, not the newest' {
        $r = Invoke-VmfTestSync -Installed '0.49.0'
        $r.Calls | Should -Contain 'bicep install --version v0.48.1'
        $r.Result.Version | Should -Be '0.48.1'
    }

    It 'a runner with no Bicep gets the pinned one' {
        $r = Invoke-VmfTestSync -Installed 'none'
        $r.Failure | Should -BeNullOrEmpty
        $r.Calls | Should -Contain 'bicep install --version v0.48.1'
    }

    It 'a version that is still not the pin after the install fails the step, and names both' {
        $r = Invoke-VmfTestSync -Installed '0.47.0' -Sticks '0'
        $r.Failure | Should -Match '0\.47\.0'
        $r.Failure | Should -Match '0\.48\.1'
    }

    It 'an install that fails fails the step, with its exit code' {
        $r = Invoke-VmfTestSync -Installed '0.47.0' -InstallExit '2'
        $r.Failure | Should -Match 'exit code 2'
    }

    It 'a pin that is not three numbers stops the step before it calls az' {
        $r = Invoke-VmfTestSync -Installed '0.48.1' -Pin 'latest'
        $r.Failure | Should -Match 'latest'
        $r.Calls | Should -BeNullOrEmpty
    }

    It 'az uses the Bicep it installs, never one found on PATH, in this step and in the steps after it' {
        # The Azure CLI's own setting bicep.use_binary_from_path, as an
        # environment variable: in CI it would otherwise run a bicep found on
        # PATH, which `az bicep install` does not change. GITHUB_ENV carries
        # it to the steps that run the templates and the tests.
        $r = Invoke-VmfTestSync -Installed '0.47.0'
        @($r.AzEnv | Select-Object -Unique) | Should -Be @('false')
        $r.GhEnv | Should -Contain 'AZURE_BICEP_USE_BINARY_FROM_PATH=false'
    }
}

Describe 'CI-BICEP-RESTORE-1: the pin step restores the registry modules before the tests close the network (stand-in az)' {
    # Main CI run 39158910940: on a new pool machine, "Pester 2 of 3" could not
    # compile infra/main.bicep. The test processes have the network floor
    # (TEST-AZURE-GUARD-1), and the machine had no Bicep module cache, so every
    # br/public module failed with BCP192. The pin step runs before the tests,
    # with the network open, so it restores the modules there.

    It 'restores each template in infra and lab that uses a registry module or extension, and no other' {
        $r = Invoke-VmfTestSync -Installed '0.48.1'
        $r.Failure | Should -BeNullOrEmpty
        @($r.Calls | Where-Object { $_ -like 'bicep restore *' }) | Should -Be $script:restoreCalls
        $r.Calls | Should -Not -Contain "bicep restore --file $(Join-Path $script:restoreRoot 'infra' 'local.bicep')" -Because 'a local module and a comment are not registry references'
        $r.Calls | Should -Not -Contain "bicep restore --file $(Join-Path $script:restoreRoot 'other' 'elsewhere.bicep')" -Because 'only infra and lab hold the templates the tests compile'
        @($r.Result.Restored) | Should -Be @('infra/graph.bicep', 'infra/nested/registry.bicep', 'infra/public.bicep', 'lab/fleet.bicep')
    }

    It 'restores after an install too, with the installed Bicep' {
        $r = Invoke-VmfTestSync -Installed '0.47.0'
        $r.Failure | Should -BeNullOrEmpty
        $r.Calls[3] | Should -BeLike 'bicep restore --file *'
        @($r.AzEnv | Select-Object -Unique) | Should -Be @('false')
    }

    It 'a restore that fails fails the step, and names the file and the error' {
        $r = Invoke-VmfTestSync -Installed '0.48.1' -RestoreFail 'public.bicep'
        $r.Failure | Should -Match 'infra/public\.bicep'
        $r.Failure | Should -Match 'exit code 1'
        $r.Failure | Should -Match 'BCP192'
        $r.Failure | Should -Not -Match 'graph\.bicep' -Because 'the files that restored are not named as failures'
        # Every file is tried, so one run names every failure; the failed file
        # is tried twice, the second time after a pause.
        $expected = @(foreach ($c in $script:restoreCalls) { $c; if ($c -like '*public.bicep') { $c } })
        @($r.Calls | Where-Object { $_ -like 'bicep restore *' }) | Should -Be $expected
    }

    It 'a file that fails once and then restores does not fail the step' {
        $env:VMF_FAKE_RESTORE_FAIL_ONCE = 'public.bicep'
        try {
            Remove-Item (Join-Path $script:fakeRoot 'calls.txt'), (Join-Path $script:fakeRoot 'failed-once.txt') -ErrorAction SilentlyContinue
            $r = & (Join-Path $script:repoRoot 'tools' 'Restore-VmfBicepModules.ps1') -Root $script:restoreRoot -Az $script:fakeAz -RetryDelaySeconds 0 -WarningAction SilentlyContinue 6>$null
        }
        finally { $env:VMF_FAKE_RESTORE_FAIL_ONCE = '' }
        @($r.Failed) | Should -BeNullOrEmpty
        @($r.Restored) | Should -Contain 'infra/public.bicep'
    }

    It 'restores nothing when the pinned version could not be installed' {
        $r = Invoke-VmfTestSync -Installed '0.47.0' -InstallExit '2'
        $r.Failure | Should -Match 'exit code 2'
        @($r.Calls | Where-Object { $_ -like 'bicep restore *' }) | Should -BeNullOrEmpty
    }

    It 'the real repository has templates to restore: infra/platform.bicep and infra/identity.bicep' {
        # So a change that moves the modules out of infra cannot make the
        # restore a silent no-op. The tool only lists them here: -ListOnly
        # calls no az.
        $listed = & (Join-Path $script:repoRoot 'tools' 'Restore-VmfBicepModules.ps1') -ListOnly 6>$null
        @($listed.Restored) | Should -Contain 'infra/platform.bicep'
        @($listed.Restored) | Should -Contain 'infra/identity.bicep'
    }

    It '-BestEffort warns for each file that fails, names it, and does not stop' {
        $env:VMF_FAKE_RESTORE_FAIL = 'fleet.bicep'
        try {
            Remove-Item (Join-Path $script:fakeRoot 'calls.txt') -ErrorAction SilentlyContinue
            $r = & (Join-Path $script:repoRoot 'tools' 'Restore-VmfBicepModules.ps1') -Root $script:restoreRoot -Az $script:fakeAz -BestEffort -RetryDelaySeconds 0 -WarningVariable warned -WarningAction SilentlyContinue 6>$null
        }
        finally { $env:VMF_FAKE_RESTORE_FAIL = '' }
        @($r.Failed.File) | Should -Be @('lab/fleet.bicep')
        @($r.Restored) | Should -Be @('infra/graph.bicep', 'infra/nested/registry.bicep', 'infra/public.bicep')
        ($warned -join ' ') | Should -Match 'lab/fleet\.bicep'
        ($warned -join ' ') | Should -Match 'BCP192'
    }
}

Describe 'CI-BICEP-RESTORE-1: a local test run restores the modules before it closes the network' {

    BeforeAll {
        $script:parallelCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Invoke-VmfPesterParallel.ps1')
    }

    It 'calls the restore with -BestEffort, before the floor is set' {
        $call = [regex]::Match($script:parallelCode, 'Restore-VmfBicepModules\.ps1''\)? -BestEffort')
        $call.Success | Should -BeTrue
        $floorAt = $script:parallelCode.IndexOf('$floor = [ordered]@{')
        $floorAt | Should -BeGreaterThan 0
        $call.Index | Should -BeLessThan $floorAt
    }

    It 'restores only in the parent run, never in CI (the pin step did it) and never inside a test process' {
        $m = [regex]::Match($script:parallelCode, '(?s)if \((?<cond>[^\r\n]*)\) \{[^}]*?Restore-VmfBicepModules\.ps1')
        $m.Success | Should -BeTrue
        $cond = $m.Groups['cond'].Value
        $cond | Should -Match '-not \$env:GITHUB_ACTIONS'
        $cond | Should -Match '-not \$env:VMF_TEST_AZURE_GUARD'
        $cond | Should -Match '\$needsBicep'
        $script:parallelCode | Should -Match '\$needsBicep = .*az bicep build'
    }
}

# PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its own
# runners (tools/Initialize-VmfCiRunner.ps1). Neither ships, and the public workflows are
# different files, so there this is skipped.
Describe 'BICEP-PIN-1: every workflow step that runs Bicep follows the pin' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    BeforeAll {
        # Get-VmfWorkflowSteps reads `run: |` blocks. A one-line `run: x` is
        # written as a block first, in a copy, so it is read too: release.yml
        # runs the tests that way. The order of the lines stays.
        $script:steps = @(foreach ($file in Get-ChildItem $script:workflowDir -Filter '*.yml') {
                $copy = Join-Path $script:temp "wf-$([guid]::NewGuid().ToString('N').Substring(0, 8))-$($file.Name)"
                $lines = foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    $one = [regex]::Match($line, '^(?<indent>\s+(?:- )?)run:\s+(?<cmd>[^|\s].*)$')
                    if ($one.Success) {
                        $pad = ' ' * $one.Groups['indent'].Value.Length
                        "$($one.Groups['indent'].Value)run: |"
                        "$pad  $($one.Groups['cmd'].Value)"
                    }
                    else { $line }
                }
                Set-Content -LiteralPath $copy -Value $lines
                foreach ($s in @(Get-VmfWorkflowSteps -Path $copy)) {
                    $code = if ($s.Shell -eq 'pwsh' -or $s.RunsOn -match 'Windows') { Get-VmfCodeOnly -Language PowerShell -Text $s.Script } else { Get-VmfCodeOnly -Language Shell -Text $s.Script }
                    $s | Add-Member -NotePropertyName File -NotePropertyValue $file.Name -PassThru | Add-Member -NotePropertyName Code -NotePropertyValue $code -PassThru
                }
            })
        # A step runs Bicep when it builds a template, or runs the tests (the
        # Pester files compile the templates with `az bicep build`).
        # PUBLIC-PIPELINE-1: the public send runs the export, which runs the tests.
        $script:runsBicep = '(?i)az bicep|Invoke-VmfTests\.ps1|New-VmfRelease\.ps1|Invoke-VmfPesterParallel\.ps1|Invoke-Pester\b|Send-VmfPublicRelease\.ps1|Export-VmfPublicRelease\.ps1'
        $script:sync = 'Sync-VmfBicepVersion\.ps1'
    }

    It 'found the steps to check' {
        $script:steps.Count | Should -BeGreaterThan 20
        @($script:steps | Where-Object { $_.Code -match $script:runsBicep }).Count | Should -BeGreaterOrEqual 3
    }

    It 'each one has the pin step earlier in its own job, with no condition that could skip it' {
        foreach ($s in @($script:steps | Where-Object { $_.Code -match $script:runsBicep -and $_.Code -notmatch $script:sync })) {
            $before = @($script:steps | Where-Object { $_.File -eq $s.File -and $_.Job -eq $s.Job -and $_.Line -lt $s.Line -and $_.Code -match $script:sync })
            $before.Count | Should -Be 1 -Because "$($s.File) job $($s.Job), step '$($s.Name)' runs Bicep"
            $before[0].If | Should -BeNullOrEmpty -Because "$($s.File) job $($s.Job): the pin step must run whenever the job does"
        }
    }

    It 'ci.yml: the pin step comes before the templates compile in the gates job, and before the tests in each share' {
        # CI-SHARD-1 split the Windows job into the gates and the test shares;
        # each runs on its own runner, so each has its own pin step.
        $ci = @($script:steps | Where-Object { $_.File -eq 'ci.yml' })
        $pinSteps = @($ci | Where-Object { $_.Code -match $script:sync })
        @($pinSteps.Job | Sort-Object) | Should -Be @('gates', 'unit-tests')
        $pinSteps | ForEach-Object { $_.Shell | Should -Be 'pwsh' }
        foreach ($pair in @(@('gates', 'Templates compile'), @('unit-tests', 'Pester unit tests'))) {
            $pin = @($pinSteps | Where-Object { $_.Job -eq $pair[0] })[0]
            $target = @($ci | Where-Object { $_.Job -eq $pair[0] -and $_.Name -eq $pair[1] })
            $target.Count | Should -Be 1 -Because "ci.yml job $($pair[0]) has the step '$($pair[1])'"
            $pin.Line | Should -BeLessThan $target[0].Line -Because "$($pair[0]): the pin step comes first"
        }
    }

    It 'release.yml: the pin step comes before the release is prepared and before the checks on a tag' {
        $rel = @($script:steps | Where-Object { $_.File -eq 'release.yml' })
        $pinStep = @($rel | Where-Object { $_.Code -match $script:sync })
        $pinStep.Count | Should -Be 1
        foreach ($name in 'Prepare and push the release', 'The checks must pass on the tagged commit') {
            $pinStep[0].Line | Should -BeLessThan (@($rel | Where-Object { $_.Name -eq $name })[0].Line) -Because $name
        }
    }

    It 'no job on the Linux runner runs Bicep, so none needs the pin step' {
        @($script:steps | Where-Object { $_.RunsOn -match 'Linux|vmf-ci-linux' -and $_.Code -match $script:runsBicep }) | Should -BeNullOrEmpty
    }
}
