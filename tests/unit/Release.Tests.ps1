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

    It 'runs on the button and on a version tag, and on nothing else' {
        # Not on a branch push: a release is a deliberate act, never a side
        # effect of a merge.
        $script:release | Should -Match 'workflow_dispatch:'
        $script:release | Should -Match "tags: \['v\*'\]"
        $script:release | Should -Not -Match '(?m)^\s+branches:'
    }

    It 'compares the tag against the manifest, and throws when they differ' {
        $script:release | Should -Match 'Import-PowerShellDataFile'
        $script:release | Should -Match 'ModuleVersion'
        $script:release | Should -Match '\$tag -ne \$wanted'
        $script:release | Should -Match 'throw '
    }

    It 'runs the gates on the tagged commit before it publishes anything' {
        # The order matters and is checked as an order: a release that ran the
        # gates AFTER publishing would be a release nobody could withdraw.
        $gates   = $script:release.IndexOf('Invoke-VmfTests.ps1')
        $publish = $script:release.IndexOf('Publish the release')
        $gates | Should -BeGreaterThan 0
        $publish | Should -BeGreaterThan $gates -Because 'a release must not be published before the gates pass'
    }

    It 'uses the same runner as CI, so a release costs no billed minutes' {
        # CI-RUNNER-1. A Windows GitHub-hosted runner bills at 2x against an
        # allowance that ran out once already.
        $script:release | Should -Match 'runs-on: \[self-hosted, Windows, vmf-ci\]'
    }

    It 'asks for no more permission than creating a release needs' {
        $script:release | Should -Match 'contents: write'
        $script:release | Should -Not -Match '(?m)^\s+permissions: write-all'
        $script:release | Should -Not -Match 'id-token'
    }

    It 'never cancels a release in flight' {
        # Two tags pushed together are two releases. Cancelling the first would
        # leave a tag with no release behind it, which is the state this item
        # exists to remove.
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
        # The REST call lives in the publish tool since SBOM-1. The deploy step
        # that also called it from this file went with WORKFLOWS-UNUSED-1.
        $script:release | Should -Match 'tools/Publish-VmfRelease\.ps1'
        $publish = Get-Content (Join-Path $script:repoRoot 'tools' 'Publish-VmfRelease.ps1') -Raw
        $publish | Should -Match 'api\.github\.com/repos/'
        $publish | Should -Not -Match '(?m)^\s*gh |gh release '
    }
}

Describe 'DIST-1a: the button releases without anybody running a script' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {

    # Since 2026-09-08 a release needs nobody to run a script by hand each
    # time. The first version of this item
    # put the DECISION in the right place and the WORK in the wrong one.

    It 'takes the version as an input, so a person types a number and nothing else' {
        $script:release | Should -Match '(?s)workflow_dispatch:.*inputs:.*version:'
        $script:release | Should -Match 'required: true'
    }

    It 'RUNS the rules rather than restating them' {
        # Two copies of "what refuses a release" would drift, and the copy that
        # drifted would be the one nobody ran. The button path must call the
        # script, and must NOT carry its own version comparison.
        $script:release | Should -Match './tools/New-VmfRelease\.ps1 -Version'
        $button = [regex]::Match($script:release,
            '(?s)- name: Prepare and push the release(.*?)(?=
      - name: )').Groups[1].Value
        $button | Should -Not -BeNullOrEmpty
        $button | Should -Not -Match 'Import-PowerShellDataFile' -Because 'the version rules live in one place'
    }

    It 'pushes only AFTER the script has run, which is after the checks pass' {
        $button = [regex]::Match($script:release,
            '(?s)- name: Prepare and push the release(.*?)(?=
      - name: )').Groups[1].Value
        $runsScript = $button.IndexOf('New-VmfRelease.ps1')
        $pushes     = $button.IndexOf('git push origin main')
        $runsScript | Should -BeGreaterThan 0
        $pushes | Should -BeGreaterThan $runsScript -Because 'nothing anybody else can see may happen before the refusals and the checks'
    }

    It 'checks out main for the button and the tag for a pushed tag' {
        $script:release | Should -Match "ref: \$\{\{ github.event_name == 'workflow_dispatch' && 'main' \|\| github.ref \}\}"
    }

    It 'fetches every tag, or the refusal on an existing tag cannot see one' {
        # A shallow checkout has no tags, so New-VmfRelease would happily
        # re-cut a version that already exists.
        $script:release | Should -Match 'fetch-depth: 0'
    }

    It 'names a committer, because a commit with no author fails on the runner' {
        $script:release | Should -Match 'git config user\.name'
        $script:release | Should -Match 'git config user\.email'
    }

    It 'the two paths never both run' {
        # Each step that belongs to one way in says which. A step with no
        # condition runs on both by design - reading the version, and
        # publishing - and those are the same on either path.
        $script:release | Should -Match "if: github.event_name == 'workflow_dispatch'"
        $script:release | Should -Match "if: github.event_name == 'push'"
    }

    It 'the checks run exactly once, whichever way in' {
        # The button gets them from New-VmfRelease; a pushed tag gets them from
        # its own step, which is why that step is conditional. Two runs of the
        # suite would double a release that already takes minutes.
        @([regex]::Matches($script:release, 'Invoke-VmfTests\.ps1')).Count | Should -Be 1
        $script:release | Should -Match "(?s)- name: The checks must pass on the tagged commit\s+if: github.event_name == 'push'"
    }

    It 'the release names the version the released commit states' {
        # Not the typed input. If the script and the input ever disagreed, the
        # manifest is the one that ships, so the manifest is the one that names
        # the release.
        $script:release | Should -Match '(?s)- name: Read the version that was released.*Import-PowerShellDataFile'
        # SBOM-1 moved the release's creation into tools/Publish-VmfRelease.ps1
        # (a draft, the bill of materials attached, then published), which
        # names the tag v<version> from the one number this step read.
        # Sbom.Tests.ps1 runs that script and checks the tag it sends.
        $script:release | Should -Match '(?s)- name: Publish the release\s+shell: pwsh\s+env:\s+GH_TOKEN: \$\{\{ github.token \}\}\s+VMF_VERSION: \$\{\{ steps.version.outputs.number \}\}'
        $script:release | Should -Match '\./tools/Publish-VmfRelease\.ps1 -Repository \$env:GITHUB_REPOSITORY -Version \$env:VMF_VERSION'
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

    It 'stops before the outward step' {
        # Pushing the tag is what starts the release, so it stays a decision a
        # person makes. The command is printed, not run.
        $script:newRelease | Should -Match 'git push origin main \$tag'
        $script:newRelease | Should -Not -Match '(?m)^\s*git .*push'
    }

    It 'refuses a dirty tree, a branch that is not main, a tag that exists, and a version that goes backwards' -ForEach @(
        @{ Refusal = 'dirty tree';       Pattern = 'status --porcelain' }
        @{ Refusal = 'not main';         Pattern = "\`$branch -ne 'main'" }
        @{ Refusal = 'tag exists';       Pattern = 'tag --list \$tag' }
        @{ Refusal = 'no going back';    Pattern = '\[version\]\$Version -le \[version\]\$current' }
    ) {
        $script:newRelease | Should -Match $Pattern -Because "a release must refuse: $Refusal"
    }

    It 'runs the gates before it writes the version, not after' {
        $gates  = $script:newRelease.IndexOf('Invoke-VmfTests.ps1')
        $write  = $script:newRelease.IndexOf('setting ModuleVersion to')
        $gates | Should -BeGreaterThan 0
        $write | Should -BeGreaterThan $gates -Because 'a person should find out before a commit exists, not after'
    }

    It 'writes an annotated tag, which carries who cut it and when' {
        $script:newRelease | Should -Match 'git -C \$repoRoot tag -a \$tag'
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
