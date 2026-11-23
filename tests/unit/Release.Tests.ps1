#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DIST-1a - a version becomes a thing you can name, fetch and compare against.
#
# Before this, `git tag` returned NOTHING. The manifest said 0.1.0, no commit
# was marked as being it, and the manual's update path could only ever hand a
# customer the tip of a branch. VERSION-1 gave every part a version to update
# FROM and stopped there on purpose: tags and a release workflow need somewhere
# to publish to, and that is this item.
#
# WHAT THESE TESTS GUARD. Not "does a release happen" - that needs a tag push
# and GitHub. They guard the two REFUSALS that make a tag mean anything, and
# the fact that the version has exactly one source:
#
#   1. the tag must equal the manifest's ModuleVersion, or the product reports
#      a version nobody can fetch;
#   2. the gates must pass on the TAGGED COMMIT, because a tag can point at any
#      commit, including one that never had a pull request.
#
# A workflow is YAML that nothing else reads, so its rules can rot silently.
# These read it, the same way FacadeAuth.Tests.ps1 reads the publish script.
BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    # PUBLIC-SYNC-1: this repository's workflows do not ship to the public one, and the
    # public release.yml is a different file. The Describes that read this one skip where
    # this repository's own CI runner set-up (tools/Initialize-VmfCiRunner.ps1) is absent.
    $releaseYml = Join-Path $script:repoRoot '.github' 'workflows' 'release.yml'
    $script:release   = if (Test-Path $releaseYml) { Get-Content $releaseYml -Raw } else { $null }
    $script:newRelease = Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfRelease.ps1') -Raw
    $script:manifestPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
    $script:manifest  = Import-PowerShellDataFile $script:manifestPath
}

Describe 'DIST-1a: the release workflow refuses a tag that lies' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_WorkflowCommands.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:relSteps = @(Get-VmfWorkflowSteps -Path (Join-Path $script:repoRoot '.github' 'workflows' 'release.yml'))
        $script:allCode = (@($script:relSteps | ForEach-Object { Get-VmfCodeOnly -Language PowerShell -Text $_.Script })) -join "`n"
        $script:on = [regex]::Match($script:release, '(?ms)^on:\s*$(.+?)^\S').Groups[1].Value
        function script:Get-RelPermissions([string]$Text) {
            $block = [regex]::Match($Text, '(?ms)^permissions:\s*$(.+?)^\S').Groups[1].Value
            @([regex]::Matches($block, '(?m)^  ([a-z-]+): (\S+)\s*$') | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" } | Sort-Object)
        }
        function script:Get-RelTimeout([string]$Text) { [int][regex]::Match($Text, '(?m)^    timeout-minutes: (\d+)\s*$').Groups[1].Value }
    }

    It 'the button runs on the button and on nothing else: a pushed tag starts no release (RELEASE-TAG-PUSH-TRIGGER-1)' {
        # On 2026-11-19 a tag pushed by hand started this workflow and made a
        # second draft release. A release is a deliberate act, never a side
        # effect of a push.
        $script:on | Should -Match '(?m)^  workflow_dispatch:\s*$'
        $script:on | Should -Not -Match '(?m)^  push:'
        $script:on | Should -Not -Match 'tags:'
        $script:on | Should -Not -Match '(?m)^\s+branches:'
        $script:on | Should -Not -Match 'pull_request|schedule|workflow_run|release:'
    }

    It 'ONE job checks CI, commits, tags, makes the bill of materials and publishes, in that order (RELEASE-FLOW-RESTORE-1)' {
        $jobs = [regex]::Match($script:release, '(?ms)^jobs:\s*$(.*)').Groups[1].Value
        @([regex]::Matches($jobs, '(?m)^  [A-Za-z0-9_-]+:\s*$')).Count | Should -Be 1 -Because 'one job'
        @($script:relSteps.Name) | Should -Be @(
            'Let git read a directory an earlier service account created',
            'Check CI on main, commit the version and tag it',
            'Read the version that was released',
            'Make the bill of materials',
            'Publish the release')
        @($script:relSteps | Where-Object { $_.If }) | Should -BeNullOrEmpty -Because 'no step may be skipped'
    }

    It 'NOTHING WAITS FOR CI on a runner CI needs: the tool looks once, with no time limit to wait for (RELEASE-FLOW-RESTORE-1)' {
        # Four Windows runners for CI's four Windows shares, one Linux runner
        # for its last two jobs: any job that waited for CI on either would
        # take the runner CI needs.
        foreach ($wf in @(Get-ChildItem (Join-Path $script:repoRoot '.github' 'workflows') -Filter '*.yml')) {
            $code = (@(Get-VmfWorkflowSteps -Path $wf.FullName | ForEach-Object { Get-VmfCodeOnly -Language PowerShell -Text $_.Script })) -join "`n"
            $code | Should -Not -Match 'Wait-VmfCiResult' -Because "$($wf.Name) must not wait for CI on a pool runner; release.yml checks CI through its tool, with no wait"
        }
        $tool = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfReleaseTag.ps1') -Raw)
        $tool | Should -Match ([regex]::Escape('TimeoutMinutes = 0; PollSeconds = 0 }'))
        $tool | Should -Match ([regex]::Escape("WaitScript = (Join-Path `$PSScriptRoot 'Wait-VmfCiResult.ps1')"))
        $tool | Should -Not -Match 'Start-Sleep|dispatches'
        Get-RelTimeout $script:release | Should -BeLessOrEqual 30 -Because 'one look at CI, a commit, two pushes, the bill of materials and the release'
    }

    It 'compares the tag against the manifest of the tagged commit, and throws when they differ' {
        $step = @($script:relSteps | Where-Object Name -eq 'Read the version that was released')[0]
        $step.Script | Should -Match 'git checkout --quiet --detach "refs/tags/\$tag"'
        $step.Script | Should -Match 'Get-VmfReleaseVersion -Root \.'
        $step.Script | Should -Match '\$tag -ne \$wanted'
        $step.Script | Should -Match 'throw '
    }

    It 'runs no suite of its own: CI on the head of main is the check (RELEASE-NO-SECOND-SUITE-1)' {
        # It took about an hour, on a tree from before the version change.
        $script:allCode | Should -Not -Match 'Invoke-VmfTests|Invoke-Pester|Invoke-VmfPesterParallel|Sync-VmfBicepVersion'
    }

    It 'uses the same runner as CI, so a release costs no billed minutes' {
        # CI-RUNNER-1. A Windows GitHub-hosted runner bills at 2x against an
        # allowance that ran out once already.
        $script:release | Should -Match '(?m)^    runs-on: \[self-hosted, Windows, vmf-ci\]\s*$'
        $script:release | Should -Not -Match 'runs-on: (ubuntu|windows|macos)-'
    }

    It 'asks for no more permission than it needs, and can start no workflow' {
        # It pushes the version commit and the tag, makes the release, and
        # reads the CI runs.
        Get-RelPermissions $script:release | Should -Be @('actions=read', 'contents=write')
        $script:release | Should -Not -Match '(?m)^\s+permissions: write-all'
        $script:release | Should -Not -Match 'id-token'
    }

    It 'never cancels a release in flight' {
        # Two releases started together are two releases. Cancelling the first
        # would leave a tag with no release behind it.
        $script:release | Should -Match 'cancel-in-progress: false'
    }

    It 'creates the release without a tool the runner does not have' {
        # tools/Initialize-VmfCiRunner.ps1 installs pwsh, Git, az, Node, Pester,
        # PSScriptAnalyzer and the Az modules. NOT the gh CLI. A workflow that
        # needs one more thing on the machine fails on the machine, at the one
        # moment nobody is watching a release.
        $runnerInit = Get-Content (Join-Path $script:repoRoot 'tools' 'Initialize-VmfCiRunner.ps1') -Raw
        $runnerInit | Should -Not -Match '(?m)gh\.exe|GitHub CLI'
        $script:release | Should -Not -Match '(?m)^\s+run: gh |gh release '
        $script:release | Should -Match 'tools/Publish-VmfRelease\.ps1'
        foreach ($tool in 'Publish-VmfRelease.ps1', 'Wait-VmfCiResult.ps1') {
            $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' $tool) -Raw)
            $code | Should -Match 'api\.github\.com/repos/' -Because $tool
            $code | Should -Not -Match '(?m)^\s*gh |gh release |gh api ' -Because $tool
        }
        $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfReleaseTag.ps1') -Raw)
        $code | Should -Not -Match '(?m)^\s*gh |gh release |gh api '
    }
}

Describe 'DIST-1a: the button releases without anybody running a script' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_WorkflowCommands.ps1')
        $script:relSteps = @(Get-VmfWorkflowSteps -Path (Join-Path $script:repoRoot '.github' 'workflows' 'release.yml'))
        $script:tagStep = @($script:relSteps | Where-Object Name -eq 'Check CI on main, commit the version and tag it')[0]
    }

    It 'takes the version as an input, so a person types a number and nothing else' {
        $script:release | Should -Match '(?s)workflow_dispatch:.*inputs:.*version:'
        $script:release | Should -Match 'required: true'
    }

    It 'RUNS the rules rather than restating them' {
        # Two copies of "what refuses a release" would drift, and the copy that
        # drifted would be the one nobody ran.
        $script:tagStep | Should -Not -BeNullOrEmpty
        $script:tagStep.Script | Should -Match '\./tools/New-VmfReleaseTag\.ps1 -Version \$env:VMF_VERSION -Repository \$env:GITHUB_REPOSITORY'
        $script:tagStep.Script | Should -Not -Match 'Import-PowerShellDataFile|git push|git tag' -Because 'the version rules and the pushes live in the tool'
        Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfReleaseTag.ps1') -Raw | Should -Match 'NewReleaseScript = \(Join-Path \$PSScriptRoot ''New-VmfRelease\.ps1''\)'
    }

    It 'no run: script holds a value GitHub writes into it: the input and the token come through env (RELEASE-INPUT-ENV-1)' {
        foreach ($s in $script:relSteps) { $s.Script | Should -Not -Match '\$\{\{' -Because "step '$($s.Name)': a value GitHub writes into a script is part of the script" }
        $block = [regex]::Match($script:release, '(?s)- name: Check CI on main, commit the version and tag it(.*?)(?=\n      - name: |\n      #)').Groups[1].Value
        $block | Should -Match 'VMF_VERSION: \$\{\{ inputs\.version \}\}'
        $block | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
    }

    It 'checks out main' {
        $script:release | Should -Match '(?m)^          ref: main\s*$'
    }

    It 'fetches every tag, or the look for an existing tag cannot see one' {
        $script:release | Should -Match 'fetch-depth: 0'
    }

    It 'names a committer, because a commit with no author fails on the runner' {
        $script:tagStep.Script | Should -Match 'git config user\.name'
        $script:tagStep.Script | Should -Match 'git config user\.email'
    }

    It 'the release names the version the released commit states' {
        $script:release | Should -Match '(?s)- name: Read the version that was released.*Get-VmfReleaseVersion'
        $script:release | Should -Match ([regex]::Escape('VMF_VERSION: ${{ steps.tag.outputs.number }}'))
        $script:tagStep.Script | Should -Match ([regex]::Escape('"number=$($done.Version)" >> $env:GITHUB_OUTPUT'))
        # SBOM-1 moved the release's creation into tools/Publish-VmfRelease.ps1
        # (a draft, the bill of materials attached, then published), which
        # names the tag v<version> from the one number this step read.
        # Sbom.Tests.ps1 runs that script and checks the tag it sends.
        $script:release | Should -Match '(?s)- name: Publish the release\s+shell: pwsh\s+env:\s+GH_TOKEN: \$\{\{ github.token \}\}\s+VMF_VERSION: \$\{\{ steps.version.outputs.number \}\}'
        $script:release | Should -Match '\./tools/Publish-VmfRelease\.ps1 -Repository \$env:GITHUB_REPOSITORY -Version \$env:VMF_VERSION'
    }
}

Describe 'RELEASE-FLOW-RESTORE-1: a merge to main starts CI only, and Public release follows Release only' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    BeforeAll {
        $script:wfDir = Join-Path $script:repoRoot '.github' 'workflows'
        # The on: block of each workflow, comments removed.
        $script:onBlocks = @{}
        foreach ($wf in @(Get-ChildItem $script:wfDir -File -Filter '*.yml')) {
            $code = (@(Get-Content -LiteralPath $wf.FullName | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") + "`n"
            $script:onBlocks[$wf.Name] = [regex]::Match($code, '(?ms)^on:\s*$(.+?)^\S').Groups[1].Value
        }
    }

    It 'reads every workflow, so this cannot pass by reading nothing' {
        $script:onBlocks.Count | Should -BeGreaterOrEqual 4
        foreach ($name in $script:onBlocks.Keys) { $script:onBlocks[$name] | Should -Not -BeNullOrEmpty -Because "$name has an on: block" }
    }

    It 'only ci.yml starts on a push or a pull request' {
        foreach ($name in $script:onBlocks.Keys) {
            if ($name -eq 'ci.yml') { $script:onBlocks[$name] | Should -Match '(?m)^  push:'; continue }
            $script:onBlocks[$name] | Should -Not -Match '(?m)^  (push|pull_request|pull_request_target|merge_group):' -Because "$name would start on a merge to main"
        }
    }

    It 'no workflow starts when a CI run ends' {
        foreach ($name in $script:onBlocks.Keys) {
            $block = $script:onBlocks[$name]
            if ($block -notmatch '(?m)^  workflow_run:') { continue }
            $listed = [regex]::Match($block, '(?m)^    workflows: \[([^\]]*)\]').Groups[1].Value
            @($listed -split ',' | ForEach-Object { $_.Trim() }) | Should -Not -Contain 'CI' -Because "$name would run after every CI run"
        }
    }

    It 'workflow_run is used once: Public release, after Release and nothing else' {
        $withRun = @($script:onBlocks.Keys | Where-Object { $script:onBlocks[$_] -match '(?m)^  workflow_run:' })
        $withRun | Should -Be @('public-release.yml')
        $block = $script:onBlocks['public-release.yml']
        $block | Should -Match '(?m)^    workflows: \[Release\]\s*$'
        $block | Should -Match '(?m)^    types: \[completed\]\s*$'
        $block | Should -Match '(?m)^  workflow_dispatch:\s*$' -Because 'a failed send is sent again by its own button'
        [IO.File]::ReadAllText((Join-Path $script:wfDir 'release.yml')) | Should -Match '(?m)^name: Release\s*$' -Because 'workflow_run names the workflow, not the file'
    }
}
Describe 'DIST-1a: git can read a directory an earlier service account created' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    # FOUND BY THE FIRST PRESS OF THE BUTTON, which is what the first press was
    # for. The runner's work directory is owned by NETWORK SERVICE - what the
    # runner service ran as until the SEC-F1 failures moved it to a real local
    # administrator. The service moved; the files it had already made kept
    # their owner, and git refuses a repository owned by somebody else.
    #
    # It hid because actions/checkout passes safe.directory on its own git
    # calls. So the checkout worked and the FIRST BARE `git` found out - which
    # was the release step, on the day a release was wanted.

    It 'marks the workspace safe BEFORE any step that runs git' {
        $mark = $script:release.IndexOf('safe.directory')
        $git  = $script:release.IndexOf('git config user.name')
        $mark | Should -BeGreaterThan 0 -Because 'without this the runner refuses the repository'
        $git  | Should -BeGreaterThan $mark
    }

    It 'is idempotent, because a self-hosted runner keeps its config between runs' {
        # --add every run would grow the global config without end.
        $script:release | Should -Match 'git config --global --get-all safe\.directory'
        $script:release | Should -Match '\$known -notcontains \$workspace'
    }

    It 'VERIFIES that git can read the directory rather than assuming it' {
        # The call that failed was rev-parse. Making it again is what turns
        # this from a hopeful command into a check.
        $script:release | Should -Match 'git -C \$workspace rev-parse'
        $script:release | Should -Match 'git still cannot read'
    }

    It 'converts the path with .Replace and never with the regex operator' {
        # -replace takes a REGEX, and a lone backslash in one is invalid. This
        # exact line was written wrong once, in the change that added it.
        # A PLAIN STRING COMPARISON, deliberately. Every regex form of this
        # assertion lost its backslash to one escaping layer or another - which
        # is the very fault it exists to catch.
        $script:release.Contains("GITHUB_WORKSPACE.Replace('\', '/')") | Should -BeTrue
        $script:release | Should -Not -Match "GITHUB_WORKSPACE -replace"
    }
}

# DIST-1a's last step asked the deploy workflow to run on main, because a push
# made with GITHUB_TOKEN starts no workflow. WORKFLOWS-UNUSED-1
# (2026-11-05) removed that workflow and the step: an installation updates only
# by `azd up`. WorkflowsUnused.Tests.ps1 holds that the release starts nothing.
Describe 'DIST-1a: the version has one source' {

    It 'the manifest states a version this workflow can tag' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {
        # v-prefixed tag, plain number in the manifest. If the manifest ever
        # carried the v, the workflow comparison would be wrong in a way that
        # only shows on release day.
        $script:manifest.ModuleVersion | Should -Match '^\d+\.\d+\.\d+$'
        $script:release | Should -Match '\$wanted = "v\$number"'
    }

    It 'and Get-VmfVersion reports that same number, which is what a tag names' {
        $version = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Get-VmfVersion.ps1') -Raw
        $version | Should -Match 'ModuleVersion' -Because 'the tag names what the product reports, or it names nothing'
    }

    It 'the manifest states ModuleVersion exactly once, which New-VmfRelease relies on' {
        $text = Get-Content $script:manifestPath -Raw
        @([regex]::Matches($text, "(?m)^\s*ModuleVersion\s*=")).Count | Should -Be 1
    }
}

Describe 'DIST-1a: New-VmfRelease refuses before it writes, and never pushes' {

    It 'stops before the outward step: it commits, and never tags or pushes' {
        # VERSION-BUMP-TESTED-TREE-1: the tag comes only after CI passed on
        # the head of main this commit is on (tools/New-VmfReleaseTag.ps1).
        $script:newRelease | Should -Not -Match '(?m)^\s*git .*push'
        $script:newRelease | Should -Not -Match '(?m)^\s*git .*\btag -a'
        $script:newRelease | Should -Match 'git -C \$repoRoot commit -m "Release \$tag"'
    }

    It 'refuses a dirty tree, a branch that is not main, a tag that exists, and a version that goes backwards' -ForEach @(
        @{ Refusal = 'dirty tree';       Pattern = 'status --porcelain' }
        @{ Refusal = 'not main';         Pattern = "\`$branch -ne 'main'" }
        @{ Refusal = 'tag exists';       Pattern = 'tag --list \$tag' }
        @{ Refusal = 'no going back';    Pattern = '\[version\]\$Version -le \[version\]\$current' }
    ) {
        $script:newRelease | Should -Match $Pattern -Because "a release must refuse: $Refusal"
    }

    It 'the release writes an annotated tag, which carries who cut it and when' {
        Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfReleaseTag.ps1') -Raw | Should -Match "tag --annotate \`$tag \`$sha"
    }

    It 'parses, and the analyzer has nothing to say about it' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'tools' 'New-VmfRelease.ps1'), [ref]$null, [ref]$errs) | Out-Null
        @($errs) -join '; ' | Should -BeNullOrEmpty
    }

    It 'never names a path variable $p, and never assigns a read-only automatic variable' {
        # Two rules this repository learned the hard way, both twice.
        $script:newRelease | Should -Not -Match '\$p\s*='
        $script:newRelease | Should -Not -Match '\$(home|host|pwd|args|input)\s*='
    }
}

Describe 'DIST-1a: the manual says how to take a release' {

    It 'the update page names the released path as well as the newest source' {
        $update = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'update.md') -Raw
        $update | Should -Match '(?i)released version'
        $update | Should -Match 'git fetch --tags'
    }
}
