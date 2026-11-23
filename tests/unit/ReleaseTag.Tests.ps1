#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RELEASE-FLOW-RESTORE-1 (2026-11-20). The Release button is one job
# of a few minutes again. tools/New-VmfReleaseTag.ps1 is what it runs:
#
#   1. CI result passed on the head commit of main (tools/Wait-VmfCiResult.ps1
#      with no wait: push or workflow_dispatch runs of ci.yml on that commit).
#      A run that has not ended, failed, or is not there is a refusal; the job
#      never waits for CI.
#   2. The version commit on top of that exact commit (tools/New-VmfRelease.ps1),
#      pushed to main with no force. When main moved, git refuses and nothing
#      is tagged.
#   3. The tag v<version> on that commit.
#
# It replaces the candidate branch and the second workflow of PR 1070
# (RELEASE-RUNNER-WAIT-1). These run the real New-VmfRelease and the real
# Wait-VmfCiResult against a local bare repository and a stand-in GitHub.
#
# EVERY COMMIT A TEST MAKES HAS ITS OWN GIT TIME. Two commits of the same tree,
# parent, message and second are the same commit: the "newer press" test of
# the candidate flow failed on a fast runner for exactly that.
#
# AND NO GIT SETTING OF THIS COMPUTER IS USED. A CI runner has no global git
# identity; this PC has one. A `git tag --annotate` with no -c user.name
# worked here and failed silently on the runner (2026-11-20, PR 1073), so a
# refusal test saw no tag and no refusal. Every git call in this file runs
# with an empty global config, as on the runner.
BeforeAll {
    $script:savedGlobalGitConfig = $env:GIT_CONFIG_GLOBAL
    $script:emptyGitConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("vmf-rt-empty-gitconfig-" + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($script:emptyGitConfig, '')
    $env:GIT_CONFIG_GLOBAL = $script:emptyGitConfig
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'New-VmfReleaseTag.ps1'
    $script:wait = Join-Path $script:repoRoot 'tools' 'Wait-VmfCiResult.ps1'
    $script:clock = 0

    # A commit in -Repo with a git time no other commit of the test has.
    function script:New-RtCommit([string]$Repo, [string]$Message, [switch]$Push) {
        $script:clock++
        $when = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero).AddMinutes($script:clock).ToString('yyyy-MM-ddTHH:mm:ssK')
        $env:GIT_AUTHOR_DATE = $when; $env:GIT_COMMITTER_DATE = $when
        try {
            git -C $Repo add -A
            git -C $Repo -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m $Message
            if ($Push) { git -C $Repo push -q origin HEAD:refs/heads/main 2>$null }
        }
        finally { Remove-Item env:GIT_AUTHOR_DATE, env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
        git -C $Repo rev-parse HEAD
    }

    function script:Set-RtVersion([string]$Repo, [string]$Version) {
        Set-Content -LiteralPath (Join-Path $Repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Value "@{`n    ModuleVersion = '$Version'`n}"
        Set-Content -LiteralPath (Join-Path $Repo 'README.md') -Value "# Product`n`nVersion **$Version**. See Releases."
    }

    function script:New-RtFixture {
        param([string]$Version = '1.0.0')
        $root = Join-Path $TestDrive ('rt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $bare = Join-Path $root 'origin.git'; $seed = Join-Path $root 'seed'; $work = Join-Path $root 'work'
        $null = New-Item -ItemType Directory -Path $root
        git init -q --bare -b main $bare
        git clone -q $bare $seed 2>$null
        $null = New-Item -ItemType Directory -Path (Join-Path $seed 'src' 'VmMigrationFactory'), (Join-Path $seed 'tools')
        Set-RtVersion $seed $Version
        Set-Content -LiteralPath (Join-Path $seed 'code.ps1') -Value '# the product'
        foreach ($n in 'New-VmfRelease.ps1', '_VmfReleaseVersion.ps1') { Copy-Item -LiteralPath (Join-Path $script:repoRoot 'tools' $n) -Destination (Join-Path $seed 'tools') }
        $null = New-RtCommit $seed 'one'
        $main = New-RtCommit $seed 'two' -Push
        git clone -q $bare $work 2>$null
        [pscustomobject]@{ Root = $root; Bare = $bare; Seed = $seed; Work = $work; Main = $main }
    }

    # A stand-in GitHub. -Ci maps a commit to the state of its CI run:
    # success, failure, in_progress, or pull_request (a run of a pull request,
    # which never counts). A commit not in -Ci has no run. -OnCall runs on
    # every call, so a test can merge into main while the release runs.
    function script:New-RtGitHub([hashtable]$Ci = @{}, [scriptblock]$OnCall) {
        $state = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
        $ci = $Ci; $onCall = $OnCall
        $rest = {
            param($Method, $Uri)
            $state.Calls.Add("$Method $Uri")
            if ($onCall) { & $onCall }
            if ($Uri -match '/actions/workflows/ci\.yml/runs\?head_sha=([0-9a-f]{40})&event=([a-z_]+)&') {
                $sha = $Matches[1]; $event = $Matches[2]
                $s = $ci[$sha]
                if (-not $s) { return [pscustomobject]@{ workflow_runs = @() } }
                $runEvent = if ($s -eq 'pull_request') { 'pull_request' } else { 'push' }
                if ($runEvent -ne $event) { return [pscustomobject]@{ workflow_runs = @() } }
                $status = if ($s -eq 'in_progress') { 'in_progress' } else { 'completed' }
                $conclusion = if ($s -eq 'in_progress') { '' } elseif ($s -eq 'pull_request') { 'success' } else { $s }
                return [pscustomobject]@{ workflow_runs = @([pscustomobject]@{ id = 77; status = $status; conclusion = $conclusion; event = $runEvent; head_sha = $sha; html_url = 'https://github.com/contoso/repo/actions/runs/77' }) }
            }
            if ($Uri -match '/actions/runs/77/jobs\?') {
                $done = @($ci.Values | Where-Object { $_ -in 'success', 'failure' })[0]
                return [pscustomobject]@{ jobs = @([pscustomobject]@{ name = 'CI result'; status = 'completed'; conclusion = $done }) }
            }
            throw "unexpected call $Method $Uri"
        }.GetNewClosure()
        [pscustomobject]@{ State = $state; Rest = $rest }
    }

    # Runs the tool in the release job's own checkout, with the git identity
    # a runner has, and every variable put back after.
    function script:Invoke-RtTool($Fx, $GitHub, [string]$Version = '1.1.0', [string]$RepoRoot) {
        if (-not $RepoRoot) { $RepoRoot = $Fx.Work }
        $vars = @{ GIT_AUTHOR_NAME = 'github-actions[bot]'; GIT_AUTHOR_EMAIL = 'bot@example.com'; GIT_COMMITTER_NAME = 'github-actions[bot]'; GIT_COMMITTER_EMAIL = 'bot@example.com' }
        $before = @{}
        foreach ($k in $vars.Keys) { $before[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item -LiteralPath "env:$k" -Value $vars[$k] }
        $err = $null; $result = $null
        try { $result = & $script:tool -Version $Version -Repository 'contoso/repo' -Token 'fake' -RepoRoot $RepoRoot -NewReleaseScript (Join-Path $RepoRoot 'tools' 'New-VmfRelease.ps1') -Rest $GitHub.Rest 6>$null 3>$null }
        catch { $err = $_ }
        finally {
            foreach ($k in $vars.Keys) {
                if ($null -eq $before[$k]) { Remove-Item -LiteralPath "env:$k" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "env:$k" -Value $before[$k] }
            }
        }
        [pscustomobject]@{ Result = $result; Error = $err; Calls = @($GitHub.State.Calls) }
    }

    function script:Get-RtRefs($Fx) { @(git -C $Fx.Bare for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags) }
    function script:Get-RtFile($Fx, [string]$Ref, [string]$Path) { (git -C $Fx.Bare show "${Ref}:$Path") -join "`n" }
}

AfterAll {
    if ($null -eq $script:savedGlobalGitConfig) { Remove-Item env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_GLOBAL = $script:savedGlobalGitConfig }
    if ($script:emptyGitConfig) { Remove-Item -LiteralPath $script:emptyGitConfig -Force -ErrorAction SilentlyContinue }
}

Describe 'RELEASE-FLOW-RESTORE-1: the release checks CI on the head of main, commits the version on it and tags that commit' {

    BeforeEach { Mock Start-Sleep { } }

    It 'CI passed on the head of main: the version commit goes on top of THAT commit, to main, and gets the tag' {
        $fx = New-RtFixture
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $sha = git -C $fx.Bare rev-parse 'refs/heads/main'
        $sha | Should -Not -Be $fx.Main
        git -C $fx.Bare rev-parse "$sha~1" | Should -Be $fx.Main -Because 'one version commit on top of the commit CI passed on'
        git -C $fx.Bare rev-parse 'refs/tags/v1.1.0^{commit}' | Should -Be $sha
        git -C $fx.Bare cat-file -t 'refs/tags/v1.1.0' | Should -Be 'tag' -Because 'an annotated tag carries who made it and when'
        Get-RtFile $fx $sha 'README.md' | Should -Match ([regex]::Escape('Version **1.1.0**'))
        Get-RtFile $fx $sha 'src/VmMigrationFactory/VmMigrationFactory.psd1' | Should -Match "ModuleVersion = '1.1.0'"
        @(git -C $fx.Bare diff --name-only "$sha~1" $sha) | Should -Be @('README.md', 'src/VmMigrationFactory/VmMigrationFactory.psd1')
        $r.Result.Version | Should -Be '1.1.0'
        $r.Result.Tag | Should -Be 'v1.1.0'
        $r.Result.Sha | Should -Be $sha
        $r.Result.CheckedSha | Should -Be $fx.Main
        @(Get-RtRefs $fx | ForEach-Object { ($_ -split ' ')[0] }) | Should -Be @('refs/heads/main', 'refs/tags/v1.1.0') -Because 'no other branch is made'
    }

    It 'asks GitHub only about the head of main, push and workflow_dispatch runs, and looks once: it never waits' {
        $fx = New-RtFixture
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $runs = @($r.Calls | Where-Object { $_ -match '/runs\?head_sha=' })
        $runs | Should -Be @(
            "Get https://api.github.com/repos/contoso/repo/actions/workflows/ci.yml/runs?head_sha=$($fx.Main)&event=push&per_page=100",
            "Get https://api.github.com/repos/contoso/repo/actions/workflows/ci.yml/runs?head_sha=$($fx.Main)&event=workflow_dispatch&per_page=100")
        @($r.Calls | Where-Object { $_ -notmatch '^Get ' }) | Should -BeNullOrEmpty -Because 'it starts no workflow'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'REFUSES, at once, when CI on the head of main has not ended: nothing pushed, nothing tagged, and it says to press Release again' {
        $fx = New-RtFixture
        $refs = Get-RtRefs $fx
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'in_progress' })
        "$($r.Error)" | Should -Match 'has not ended'
        "$($r.Error)" | Should -Match 'Nothing was tagged or released'
        "$($r.Error)" | Should -Match 'press Release again'
        "$($r.Error)" | Should -Match $fx.Main
        Get-RtRefs $fx | Should -Be $refs
        @($r.Calls | Where-Object { $_ -match '/runs\?head_sha=' }).Count | Should -Be 2 -Because 'one look per event, and no second look'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'REFUSES when CI on the head of main failed: nothing pushed, nothing tagged' {
        $fx = New-RtFixture
        $refs = Get-RtRefs $fx
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'failure' })
        "$($r.Error)" | Should -Match "ended 'failure'"
        "$($r.Error)" | Should -Match 'Nothing was tagged or released'
        Get-RtRefs $fx | Should -Be $refs
    }

    It 'REFUSES, at once, when the head of main has no CI run, or only a pull request run: nothing pushed, nothing tagged' -ForEach @(
        @{ State = $null }, @{ State = 'pull_request' }
    ) {
        $fx = New-RtFixture
        $refs = Get-RtRefs $fx
        $ci = @{}; if ($State) { $ci[$fx.Main] = $State }
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci $ci)
        "$($r.Error)" | Should -Match 'no CI run'
        "$($r.Error)" | Should -Match 'Nothing was tagged or released'
        Get-RtRefs $fx | Should -Be $refs
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'REFUSES when main moved while the release ran: git refuses the push, main keeps the merge, and nothing is tagged' {
        $fx = New-RtFixture
        $seed = $fx.Seed
        $moved = [pscustomobject]@{ Sha = $null }
        # A closure sees no function of this file: the merge is plain git, with
        # a git time of its own (2025, before every other commit here).
        $onCall = {
            if (-not $moved.Sha) {
                $env:GIT_AUTHOR_DATE = '2025-06-01T00:00:00Z'; $env:GIT_COMMITTER_DATE = '2025-06-01T00:00:00Z'
                try {
                    git -C $seed -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m 'a merge while the release runs'
                    git -C $seed push -q origin HEAD:refs/heads/main 2>$null
                }
                finally { Remove-Item env:GIT_AUTHOR_DATE, env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
                $moved.Sha = git -C $seed rev-parse HEAD
            }
        }.GetNewClosure()
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' } -OnCall $onCall)
        "$($r.Error)" | Should -Match 'main moved'
        "$($r.Error)" | Should -Match 'press Release again'
        $moved.Sha | Should -Not -BeNullOrEmpty
        git -C $fx.Bare rev-parse 'refs/heads/main' | Should -Be $moved.Sha -Because 'the push has no force: the merge stays'
        @(git -C $fx.Bare tag --list) | Should -BeNullOrEmpty
    }

    It 'REFUSES a checkout that is not the head of main of the remote, before it asks GitHub anything' {
        $fx = New-RtFixture
        $null = New-RtCommit $fx.Seed 'newer' -Push
        $refs = Get-RtRefs $fx
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        "$($r.Error)" | Should -Match 'main moved'
        $r.Calls.Count | Should -Be 0
        Get-RtRefs $fx | Should -Be $refs
    }

    It 'REFUSES a version that does not move forward, and pushes nothing' {
        $fx = New-RtFixture
        $refs = Get-RtRefs $fx
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) -Version '0.9.0'
        "$($r.Error)" | Should -Match 'does not move forward'
        Get-RtRefs $fx | Should -Be $refs
    }

    It 'REFUSES a version that is not three numbers, before anything' -ForEach @(@{ V = '1.1' }, @{ V = "1.1.0'; Write-Host x" }, @{ V = '' }) {
        $fx = New-RtFixture
        $gh = New-RtGitHub -Ci @{ $fx.Main = 'success' }
        $r = Invoke-RtTool $fx $gh -Version $V
        $r.Error | Should -Not -BeNullOrEmpty
        $r.Calls.Count | Should -Be 0
    }

    It 'REFUSES a version commit that changes more than the version, and pushes nothing' {
        $fx = New-RtFixture
        # A broken version tool: it also changes the product.
        $broken = Join-Path $fx.Root 'Broken-Release.ps1'
        $work = $fx.Work
        $real = Join-Path $work 'tools' 'New-VmfRelease.ps1'
        $code = Join-Path $work 'code.ps1'
        Set-Content -LiteralPath $broken -Encoding utf8NoBOM -Value @(
            'param([string]$Version)'
            "& '$real' -Version `$Version"
            "Set-Content -LiteralPath '$code' -Value '# changed'"
            "git -C '$work' commit -q -a --amend --no-edit")
        $refs = Get-RtRefs $fx
        $names = 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'
        $before = @{}; foreach ($k in $names) { $before[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item -LiteralPath "env:$k" -Value 'b@example.com' }
        try {
            { & $script:tool -Version '1.1.0' -Repository 'contoso/repo' -Token 'fake' -RepoRoot $work -NewReleaseScript $broken -Rest (New-RtGitHub -Ci @{ $fx.Main = 'success' }).Rest 6>$null 3>$null } |
                Should -Throw '*not one commit of the version on top of main*'
        }
        finally {
            foreach ($k in $names) { if ($null -eq $before[$k]) { Remove-Item -LiteralPath "env:$k" -ErrorAction SilentlyContinue } else { Set-Item -LiteralPath "env:$k" -Value $before[$k] } }
        }
        Get-RtRefs $fx | Should -Be $refs
    }
    It 'a local tag the remote does not have is removed, not obeyed (a runner keeps its folder between runs)' {
        $fx = New-RtFixture
        git -C $fx.Work tag v1.1.0
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        git -C $fx.Bare rev-parse 'refs/tags/v1.1.0^{commit}' | Should -Not -Be $fx.Main
    }
}

Describe 'RELEASE-FLOW-RESTORE-1: pressing Release again finishes a run that stopped' {

    BeforeEach { Mock Start-Sleep { } }

    It 'main has the version commit but no tag (the tag push failed): CI is checked on the commit under it, and main''s commit is tagged' {
        $fx = New-RtFixture
        Set-RtVersion $fx.Seed '1.1.0'
        $versionCommit = New-RtCommit $fx.Seed 'Release v1.1.0' -Push
        git -C $fx.Work pull -q 2>$null
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        git -C $fx.Bare rev-parse 'refs/heads/main' | Should -Be $versionCommit -Because 'no new commit'
        git -C $fx.Bare rev-parse 'refs/tags/v1.1.0^{commit}' | Should -Be $versionCommit
        $r.Result.CheckedSha | Should -Be $fx.Main
        @($r.Calls | Where-Object { $_ -match "head_sha=$versionCommit" }) | Should -BeNullOrEmpty -Because 'the version commit is pushed with the workflow token, which starts no CI'
    }

    It 'main states the version in a commit that changed more than the version: CI must have passed on that commit itself' {
        $fx = New-RtFixture
        Set-RtVersion $fx.Seed '1.1.0'
        Set-Content -LiteralPath (Join-Path $fx.Seed 'code.ps1') -Value '# the product, changed'
        $head = New-RtCommit $fx.Seed 'a pull request with the version and code' -Push
        git -C $fx.Work pull -q 2>$null
        $refused = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        "$($refused.Error)" | Should -Match 'no CI run'
        @(git -C $fx.Bare tag --list) | Should -BeNullOrEmpty
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $head = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        git -C $fx.Bare rev-parse 'refs/tags/v1.1.0^{commit}' | Should -Be $head
        $r.Result.CheckedSha | Should -Be $head
    }

    It 'the tag is already there (the bill of materials or the publish failed): nothing is committed or tagged again, and the run goes on' {
        $fx = New-RtFixture
        $first = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $first.Error | Should -BeNullOrEmpty -Because "$($first.Error)"
        $refs = Get-RtRefs $fx
        $again = Join-Path $fx.Root 'again'
        git clone -q $fx.Bare $again 2>$null
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) -RepoRoot $again
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        Get-RtRefs $fx | Should -Be $refs
        $r.Result.Sha | Should -Be $first.Result.Sha
        $r.Result.CheckedSha | Should -Be $fx.Main
    }

    It 'a release right after a release: the head of main is the last version commit, so CI is checked on the commit under it' {
        $fx = New-RtFixture
        $first = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        $first.Error | Should -BeNullOrEmpty -Because "$($first.Error)"
        $next = Join-Path $fx.Root 'next'
        git clone -q $fx.Bare $next 2>$null
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) -Version '1.2.0' -RepoRoot $next
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $r.Result.CheckedSha | Should -Be $fx.Main
        git -C $fx.Bare rev-parse 'refs/heads/main~1' | Should -Be $first.Result.Sha
        git -C $fx.Bare rev-parse 'refs/tags/v1.2.0^{commit}' | Should -Be (git -C $fx.Bare rev-parse 'refs/heads/main')
        # And a third, with no merge between: two version commits under it.
        $third = Join-Path $fx.Root 'third'
        git clone -q $fx.Bare $third 2>$null
        $r3 = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) -Version '1.3.0' -RepoRoot $third
        $r3.Error | Should -BeNullOrEmpty -Because "$($r3.Error)"
        $r3.Result.CheckedSha | Should -Be $fx.Main
    }

    It 'a commit with the version AND another line of <File> is not a version commit: its own CI is read' -ForEach @(
        @{ File = 'the manifest'; Path = 'src/VmMigrationFactory/VmMigrationFactory.psd1'; Text = "@{`n    ModuleVersion = '1.1.0'`n    Description = 'changed'`n}" }
        @{ File = 'README.md'; Path = 'README.md'; Text = "# Product, changed`n`nVersion **1.1.0**. See Releases." }
    ) {
        $fx = New-RtFixture
        Set-RtVersion $fx.Seed '1.1.0'
        Set-Content -LiteralPath (Join-Path $fx.Seed $Path) -Value $Text
        $head = New-RtCommit $fx.Seed "the version and another line of $File" -Push
        git -C $fx.Work pull -q 2>$null
        $refused = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        "$($refused.Error)" | Should -Match 'no CI run'
        "$($refused.Error)" | Should -Match $head -Because 'the CI of the merge itself is read, not the commit under it'
        @(git -C $fx.Bare tag --list) | Should -BeNullOrEmpty
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $head = 'success' })
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $r.Result.CheckedSha | Should -Be $head
    }

    It 'one changed line in each file is still not a version commit when <Case>: its own CI is read' -ForEach @(
        @{ Case = 'the manifest line is not ModuleVersion'
            BaseReadme = "# Product`n`nVersion **1.0.0**. See Releases."; BasePsd = "@{`n    ModuleVersion = '1.1.0'`n    PowerShellVersion = '7.2.0'`n}"
            Readme = "# Product`n`nVersion **1.1.0**. See Releases."; Psd = "@{`n    ModuleVersion = '1.1.0'`n    PowerShellVersion = '7.4.0'`n}" }
        @{ Case = 'the README line is not the Version line'
            BaseReadme = "# Product`n`nVersion **1.1.0**. See Releases.`nTested on 7.2.0."; BasePsd = "@{`n    ModuleVersion = '1.0.0'`n}"
            Readme = "# Product`n`nVersion **1.1.0**. See Releases.`nTested on 7.4.0."; Psd = "@{`n    ModuleVersion = '1.1.0'`n}" }
        @{ Case = 'the Version line changes more than its number'
            BaseReadme = "# Product`n`nVersion **1.0.0**. See Releases."; BasePsd = "@{`n    ModuleVersion = '1.0.0'`n}"
            Readme = "# Product`n`nVersion **1.1.0**. See the notes."; Psd = "@{`n    ModuleVersion = '1.1.0'`n}" }
        @{ Case = 'only the manifest changes'
            BaseReadme = "# Product`n`nVersion **1.1.0**. See Releases."; BasePsd = "@{`n    ModuleVersion = '1.0.0'`n}"
            Readme = "# Product`n`nVersion **1.1.0**. See Releases."; Psd = "@{`n    ModuleVersion = '1.1.0'`n}" }
    ) {
        $fx = New-RtFixture
        $readmePath = Join-Path $fx.Seed 'README.md'; $psdPath = Join-Path $fx.Seed 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
        Set-Content -LiteralPath $readmePath -Value $BaseReadme; Set-Content -LiteralPath $psdPath -Value $BasePsd
        $base = New-RtCommit $fx.Seed 'a base the next commit changes one line of'
        Set-Content -LiteralPath $readmePath -Value $Readme; Set-Content -LiteralPath $psdPath -Value $Psd
        $head = New-RtCommit $fx.Seed "a commit where $Case" -Push
        git -C $fx.Work pull -q 2>$null
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $base = 'success'; $fx.Main = 'success' })
        "$($r.Error)" | Should -Match 'no CI run'
        "$($r.Error)" | Should -Match $head -Because 'the commit itself is read, not the commit under it'
        @(git -C $fx.Bare tag --list) | Should -BeNullOrEmpty
    }
    It 'two version commits on main with no tag: CI is read two commits down' {
        $fx = New-RtFixture
        Set-RtVersion $fx.Seed '1.1.0'
        $null = New-RtCommit $fx.Seed 'Release v1.1.0' -Push
        Set-RtVersion $fx.Seed '1.2.0'
        $top = New-RtCommit $fx.Seed 'Release v1.2.0' -Push
        git -C $fx.Work pull -q 2>$null
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) -Version '1.2.0'
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $r.Result.CheckedSha | Should -Be $fx.Main
        git -C $fx.Bare rev-parse 'refs/tags/v1.2.0^{commit}' | Should -Be $top
    }
    It 'a warning git writes to standard error is never read as a commit id' {
        # 2026-11-20: a "bash.exe:" warning on standard error was read as the
        # head of main, and the release refused with "main is bash.exe: now".
        # The warning came and went, so this forces one on every git call.
        $fx = New-RtFixture
        function global:git {
            & cmd.exe /d /c 'echo bash.exe: warning: a line on standard error 1>&2'
            & git.exe @args
        }
        try { $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' }) }
        finally { Remove-Item 'function:\git' -ErrorAction SilentlyContinue }
        # TEST-STUB-1: the function:global: form removes nothing; this one does.
        Get-Command git -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the stand-in git must not outlive this test'
        $r.Error | Should -BeNullOrEmpty -Because "$($r.Error)"
        $r.Result.CheckedSha | Should -Be $fx.Main
        git -C $fx.Bare rev-parse 'refs/tags/v1.1.0^{commit}' | Should -Not -BeNullOrEmpty
    }
    It 'REFUSES a tag on a commit that main does not hold' {
        $fx = New-RtFixture
        Set-RtVersion $fx.Seed '1.1.0'
        $side = New-RtCommit $fx.Seed 'Release v1.1.0, never merged'
        git -C $fx.Seed -c user.name=t -c user.email=t@example.com tag --annotate v1.1.0 $side -m 'Release v1.1.0'
        if ($LASTEXITCODE -ne 0) { throw 'the test could not make its tag' }
        git -C $fx.Seed push -q origin refs/tags/v1.1.0 2>$null
        $refs = Get-RtRefs $fx
        $r = Invoke-RtTool $fx (New-RtGitHub -Ci @{ $fx.Main = 'success' })
        "$($r.Error)" | Should -Match 'main does not hold'
        Get-RtRefs $fx | Should -Be $refs
    }
}

Describe 'RELEASE-FLOW-RESTORE-1: the stand-in proves what it claims' {

    It 'the Start-Sleep stand-in catches a wait: with a time limit, a run that has not ended is waited for' {
        # Without this, "Start-Sleep was called 0 times" could pass because the
        # stand-in never saw the call at all.
        Mock Start-Sleep { }
        $sha = 'abcdef0123456789abcdef0123456789abcdef01'
        $answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('in_progress', 'in_progress', 'success'))
        $ci = @{ $sha = 'in_progress' }
        $gh = New-RtGitHub -Ci $ci -OnCall { if ($answers.Count) { $ci[$sha] = $answers.Dequeue() } }.GetNewClosure()
        $r = & $script:wait -Repository 'contoso/repo' -Sha $sha -Event push -TimeoutMinutes 5 -PollSeconds 1 -Rest $gh.Rest 6>$null
        $r.RunId | Should -Be 77
        Should -Invoke Start-Sleep -Scope It -Times 1
    }
}

Describe 'RELEASE-FLOW-RESTORE-1: the tool' {

    It 'parses, puts no variable before a question mark, never names $p, and pushes with no force' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$errs) | Out-Null
        @($errs) -join '; ' | Should -BeNullOrEmpty
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Language PowerShell -Text ([IO.File]::ReadAllText($script:tool))
        $code | Should -Not -Match '\$[A-Za-z_]+\?'
        $code | Should -Not -Match '\$p\s*='
        $code | Should -Not -Match '--force|\+refs/' -Because 'main and the tag are pushed with no force'
        $code | Should -Match 'TimeoutMinutes = 0'
        $code | Should -Not -Match 'Start-Sleep|dispatches'
    }
}
