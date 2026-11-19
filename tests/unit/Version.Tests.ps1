#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VERSION-1 - the product can say which build it is.
#
# Asked 2026-09-03, in a review of the install decisions: how does a customer
# update to a new version, and which item covers it?
#
# None did, because nothing had a version. The manifest said
# 0.1.0 and nothing read it. The engine image was tagged `dev`. The facade had
# no version endpoint. The dashboard's help menu promised a bug report "with
# the page and version filled in" and filled in no version - a false sentence
# that had shipped for a week. A support bundle could not say which code had
# run the migration it described.
#
# An update path needs something to update FROM. This is that something: one
# number in the manifest, one stamp written by the install, and the same answer from
# the module, the engine's activity log, the service, and the screen.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:moduleDir = Join-Path $repoRoot 'src' 'VmMigrationFactory'
    Import-Module (Join-Path $script:moduleDir 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:manifest = Import-PowerShellDataFile (Join-Path $script:moduleDir 'VmMigrationFactory.psd1')
    $script:number = [string]$script:manifest.ModuleVersion

    # A module COPY to stamp, so no test ever writes a build.json into the
    # checkout - the one place it must never exist.
    function Global:NewVersionedModule {
        param($Stamp)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ver-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item (Join-Path $script:moduleDir 'VmMigrationFactory.psd1') $dir
        if ($Stamp) { $Stamp | ConvertTo-Json | Set-Content (Join-Path $dir 'build.json') -Encoding utf8NoBOM }
        $dir
    }
}
AfterAll {
    Remove-Item 'function:\NewVersionedModule' -ErrorAction SilentlyContinue
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-ver-*' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'VERSION-1: Get-VmfVersion - one number, one stamp, one answer' {

    It 'the number is the manifest, and it is a semantic version' {
        $script:number | Should -Match '^\d+\.\d+\.\d+$' -Because 'a release tag must be able to equal it (DIST-1)'
        (Get-VmfVersion).number | Should -Be $script:number
    }

    It 'a checkout with no stamp says local, which is true, rather than inventing a build' {
        $v = Get-VmfVersion -ModulePath (NewVersionedModule)
        $v.version | Should -Be "$($script:number)+local"
        $v.build | Should -Be 'local'
        $v.source | Should -Be 'local'
        $v.commit | Should -BeNullOrEmpty
        $v.builtUtc | Should -BeNullOrEmpty
        $v.warning | Should -BeNullOrEmpty
    }

    It 'a stamped module reads the commit the install wrote, as semver build metadata' {
        $dir = NewVersionedModule -Stamp @{ moduleVersion = $script:number; commit = '1fee594abcdef0123456789abcdef0123456789a'; builtUtc = '2026-09-03T12:00:00.0000000Z'; run = 42 }
        $v = Get-VmfVersion -ModulePath $dir
        $v.version | Should -Be "$($script:number)+1fee594"
        $v.build | Should -Be '1fee594'
        $v.commit | Should -Be '1fee594abcdef0123456789abcdef0123456789a'
        # ISO text in, ISO text out. ConvertFrom-Json had turned it into a
        # [datetime], and the first version of the cmdlet emitted the reader's
        # locale format - '09/03/2026 12:00:00' - which is not a timestamp.
        $v.builtUtc | Should -Be '2026-09-03T12:00:00.0000000Z'
        $v.source | Should -Be 'stamp'
        $v.warning | Should -BeNullOrEmpty
    }

    It 'every version string has the same shape, stamped or not' {
        foreach ($dir in @((NewVersionedModule), (NewVersionedModule -Stamp @{ moduleVersion = $script:number; commit = 'abc1234' }))) {
            (Get-VmfVersion -ModulePath $dir).version | Should -Match '^\d+\.\d+\.\d+\+[0-9a-z]+$'
        }
    }

    It 'a stamp from a different revision is REPORTED, and the manifest wins' {
        # Reported rather than thrown: an endpoint that dies when asked its
        # version is worse than one that answers with a caveat.
        $dir = NewVersionedModule -Stamp @{ moduleVersion = '9.9.9'; commit = 'abc1234def'; builtUtc = '2026-09-03T12:00:00Z' }
        $v = Get-VmfVersion -ModulePath $dir
        $v.version | Should -Be "$($script:number)+abc1234"
        $v.warning | Should -Match '9\.9\.9'
        $v.warning | Should -Match ([regex]::Escape($script:number))
    }

    It 'a stamp with no commit is no stamp' {
        $v = Get-VmfVersion -ModulePath (NewVersionedModule -Stamp @{ moduleVersion = $script:number })
        $v.source | Should -Be 'local'
        $v.version | Should -Be "$($script:number)+local"
    }

    It 'the stamp is never committed: absent from the checkout and ignored by git' {
        Test-Path (Join-Path $script:moduleDir 'build.json') | Should -BeFalse -Because 'the install writes it per build; a committed one would stamp every build with one old commit'
        Get-Content (Join-Path $script:repoRoot '.gitignore') -Raw | Should -Match 'src/VmMigrationFactory/build\.json'
    }

    It 'is exported, so the facade and the entrypoint can call it' {
        $script:manifest.FunctionsToExport | Should -Contain 'Get-VmfVersion'
        Get-Command Get-VmfVersion -Module VmMigrationFactory | Should -Not -BeNullOrEmpty
    }
}

Describe 'VERSION-1: the engine records which build ran' {
    BeforeAll {
        $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
    }

    It 'asks its version before it dispatches anything' {
        $script:entry | Should -Match 'Get-VmfVersion'
        $script:entry.IndexOf('Get-VmfVersion') | Should -BeLessThan $script:entry.IndexOf('switch ($env:VMF_OPERATION)') `
            -Because 'the stamp must precede the operation, or a refused operation has no version in its log'
    }

    It 'writes it to the run activity log THROUGH the module, with the version as data' {
        # Write-VmfEvent is private; a bare call from the script fails at the
        # only moment it matters (the refusal wrapper had exactly this defect).
        # The call sits on ONE line inside the module block: matched as a line,
        # because the -f template on it carries {0} and {1}.
        $script:entry | Should -Match '(?m)^\s*&\s*\(Get-Module VmMigrationFactory\)\s*\{[^
]*
\s*Write-VmfEvent[^
]*engineVersion'
    }

    It 'and a failed stamp cannot fail the operation' {
        $script:entry | Should -Match '(?s)try\s*\{\s*&\s*\(Get-Module VmMigrationFactory\)\s*\{.*?engineVersion.*?\n\}\s*catch'
    }

    It 'an event written before the run exists survives the run being initialised (the order the entrypoint uses)' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ver-run-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Write-VmfEvent -RunPath $rp -Step 'engine:assess' -Outcome info -Detail 'Engine version 0.1.0+test started the assess operation.' -Data @{ engineVersion = '0.1.0+test' }
                Initialize-VmfRun -RunPath $rp -RunId 'ver-run' -Kind assessment | Out-Null
                $events = @(Read-VmfEvents -RunPath $rp)
                $events.Count | Should -Be 1
                $events[0].engineVersion | Should -Be '0.1.0+test'
                (Read-VmfStoreJson -RunPath $rp -RelPath 'run.json').kind | Should -Be 'assessment'
            }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'VERSION-1: the service answers GET /api/version' {
    BeforeAll {
        $script:fnDir = Join-Path $script:repoRoot 'src' 'facade' 'app' 'GetVersion'
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    }

    It 'the endpoint exists, on GET version' {
        $cfg = Get-Content (Join-Path $script:fnDir 'function.json') -Raw | ConvertFrom-Json
        $trigger = @($cfg.bindings | Where-Object { $_.type -eq 'httpTrigger' })[0]
        $trigger.route | Should -Be 'version'
        @($trigger.methods) | Should -Be @('get')
        Get-Content (Join-Path $script:fnDir 'run.ps1') -Raw | Should -Match 'Get-VmfFacadeVersion -Principal'
    }

    It 'is open to every role, because a version is the first thing support asks for' {
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeVersion.*?\n\}').Value
        $fn | Should -Match "Assert-VmfFacadeRole[^\n]*'Vmf\.Viewer'[^\n]*'Vmf\.Admin'"
    }

    It 'takes its own version from the module rather than a second copy of the logic' {
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeVersion.*?\n\}').Value
        $fn | Should -Match 'Get-VmfVersion'
        $fn | Should -Not -Match 'ModuleVersion'
    }

    It 'is exported by the FacadeCore manifest' {
        (Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1')).FunctionsToExport |
            Should -Contain 'Get-VmfFacadeVersion'
    }
}

Describe 'VERSION-1: the dashboard shows it, and says it where it promised to' {
    BeforeAll {
        $script:help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $script:deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
    }

    It 'the deploy writes the version into the page configuration, from the module' {
        $script:deploy | Should -Match 'Get-VmfVersion'
        $script:deploy | Should -Match 'version\s*=\s*\$build\.version'
        $script:deploy | Should -Match 'commit\s*=\s*\$build\.commit'
        $script:deploy | Should -Match 'builtUtc\s*=\s*\$build\.builtUtc'
        $script:deploy | Should -Not -Match 'ModuleVersion' -Because 'a second reading of the manifest is a second answer'
    }

    It 'the bar carries the stamp, built by the shared file like every other control on it' {
        $right = [regex]::Match($script:help, '(?s)function installRight\(\).*?\n  \}').Value
        $right | Should -Match "id = 'nav-build'"
        $right | Should -Match 'versionDialog'
    }

    It 'the About dialog offers a way back (rule 11)' {
        $dlg = [regex]::Match($script:help, '(?s)function versionDialog\(\).*?\n  \}').Value
        $dlg | Should -Match 'TEXT\.close'
    }

    It 'the service version is read with the API token, and never on the critical path' {
        $script:help | Should -Match '\$\{cfg\.apiUrl\}/version'
        $load = [regex]::Match($script:help, '(?s)async function loadServiceVersion\(.*?\n  \}').Value
        $load | Should -Match 'acquireTokenSilent'
        $load | Should -Not -Match 'Popup' -Because 'a version read must never throw an Entra window at anybody'
        $gate = [regex]::Match($script:help, '(?s)async function gateOnRole.*?\n  \}').Value
        $gate | Should -Match 'loadServiceVersion\('
        $gate | Should -Not -Match 'await loadServiceVersion' -Because 'the facade cold-starts in 20-40 s and the page must not wait for it (COLD-1)'
    }

    It 'the bug report now really carries the version, as the menu has promised since HELP-2' {
        $script:help | Should -Match "menuBugSub: 'Opens a bug report on GitHub in a new tab, with the page and version filled in\.'"
        $script:help | Should -Match 'Version: \$\{versionSummary\(\)\}'
    }

    It 'and the support bundle names the builds that made it' {
        $script:help | Should -Match 'dashboardVersion:'
        $script:help | Should -Match 'serviceVersion:'
    }
}

Describe 'VERSION-1: the install stamps every build, and the stamp rides with every part' {
    # The deploy workflow stamped a build too, until WORKFLOWS-UNUSED-1 removed
    # it (2026-11-05). An installation updates only by `azd up`, so the install
    # hook is the one writer of the stamp.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:post = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
    }

    It 'writes the stamp BEFORE the engine image is built' {
        $script:post | Should -Match "\`$stampPath = Join-Path \`$repoRoot 'src' 'VmMigrationFactory' 'build\.json'"
        $write = $script:post.IndexOf('Set-Content $stampPath')
        $build = $script:post.IndexOf('az acr build')
        $write | Should -BeGreaterThan 0
        $build | Should -BeGreaterThan $write
    }

    It 'the engine image and the facade package both carry the module directory, so the stamp goes with them' {
        # PUBLISH-IN-1: the facade package is built by a Dockerfile now, not
        # staged by the publish script, so BOTH halves of this are a COPY. The
        # stamp is written into src/VmMigrationFactory by postprovision before
        # either image is built - a package that left the module behind would
        # ship a service that cannot say which build it is.
        Get-Content (Join-Path $script:repoRoot 'docker' 'Dockerfile') -Raw | Should -Match 'COPY src/VmMigrationFactory\s'
        Get-Content (Join-Path $script:repoRoot 'docker' 'publish' 'Dockerfile') -Raw |
            Should -Match 'COPY src/VmMigrationFactory\s+/stage/Modules/VmMigrationFactory'
    }
}
