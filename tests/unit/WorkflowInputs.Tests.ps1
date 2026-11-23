#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RELEASE-INPUT-ENV-1. A value GitHub writes into a run: script is part of the
# script: a version typed with a quote in it, a tag name, a branch name or the
# title of a pull request would run as code on the runner. Such a value comes
# in through env: and the script reads the variable.
#
# The release workflow had two: `-Version '${{ inputs.version }}'` and
# `$tag = '${{ github.ref_name }}'`. RELEASE-NO-SECOND-SUITE-1 rewrote both
# steps; this holds every workflow, here and in public/, to the rule.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_WorkflowCommands.ps1')
    $script:files = @(foreach ($dir in (Join-Path $script:repoRoot '.github' 'workflows'), (Join-Path $script:repoRoot 'public' '.github' 'workflows')) {
            if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -File -Filter '*.yml' }
        })
    # The values a person outside the repository's writers can choose, or a
    # writer can type: inputs, ref and branch names, and the text of an
    # issue, a pull request, a comment or a commit.
    $script:userValue = '\$\{\{\s*(inputs\.|github\.event\.inputs\.|github\.ref_name|github\.head_ref|github\.base_ref|github\.event\.(pull_request|issue|comment|review|review_comment|discussion|head_commit|commits|pages|workflow_run)\b)'
}

Describe 'RELEASE-INPUT-ENV-1: no workflow writes a typed or outside value into a script' {

    It 'found the workflows and their run steps, so this cannot pass by reading nothing' {
        $script:files.Count | Should -BeGreaterOrEqual 3
        @(foreach ($f in $script:files) { Get-VmfWorkflowSteps -Path $f.FullName }).Count | Should -BeGreaterOrEqual 10
    }

    It 'no run: script holds an input, a ref name or the text of an event' {
        foreach ($f in $script:files) {
            foreach ($s in @(Get-VmfWorkflowSteps -Path $f.FullName)) {
                $s.Script | Should -Not -Match $script:userValue -Because "$($f.Name) line $($s.Line) ('$($s.Name)'): pass it through env: and read the variable"
            }
        }
    }

    It 'no one-line run: holds one either' {
        foreach ($f in $script:files) {
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                if ($line -match '^\s+(?:- )?run:\s+[^|\s]') { $line | Should -Not -Match $script:userValue -Because $f.Name }
            }
        }
    }

    It 'the rule finds the two forms the release workflow had, and a pull request title' {
        foreach ($bad in "./tools/New-VmfRelease.ps1 -Version '`${{ inputs.version }}'", "`$tag = '`${{ github.ref_name }}'", 'echo "${{ github.event.pull_request.title }}"', "'`${{ github.head_ref }}'") {
            $bad | Should -Match $script:userValue
        }
        foreach ($fine in 'VMF_VERSION: ${{ inputs.version }}', "if ('`${{ steps.check.outputs.changed }}' -ne '0')", '$env:VMF_VERSION') {
            ($fine -match '^\s*[A-Z_]+:\s') -or ($fine -notmatch $script:userValue) | Should -BeTrue -Because $fine
        }
    }
}
