#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RELEASE-NO-SECOND-SUITE-1 (2026-11-20). A release used to run the whole
# suite again in one job, about an hour each time, on a commit CI had already
# checked. Now each release asks GitHub whether the job "CI result" of the
# CI workflow passed on the EXACT commit it releases
# (tools/Wait-VmfCiResult.ps1), and refuses when it did not.
#
# What must hold:
#   - only a run of ci.yml on that commit counts, from a push or from a run
#     started by a button - never a pull request run, which tests the pull
#     request merged into its base, not the commit itself;
#   - the newest such run decides;
#   - its job "CI result" and the run itself both ended "success";
#   - a run that has not ended is waited for, up to a limit, then refused;
#   - no run at all is waited for too (a run can be minutes late,
#     CI-DISPATCH-1), then refused;
#   - with no time limit (the private Release button, RELEASE-FLOW-RESTORE-1)
#     it looks once and refuses at once: nothing waits for CI there.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Wait-VmfCiResult.ps1'
    $script:sha = 'abcdef0123456789abcdef0123456789abcdef01'

    # A stand-in GitHub: each call to the runs list hands out the next answer
    # of -Runs (the last one repeats), and the jobs list answers -Jobs.
    function script:New-CiFake {
        param([object[]]$Runs = @(), [object[]]$Jobs = @(), [switch]$IgnoreEvent)
        $state = [pscustomobject]@{ Calls = [System.Collections.Generic.List[object]]::new(); RunsAsked = 0 }
        $runs = $Runs; $jobs = $Jobs; $ignore = [bool]$IgnoreEvent
        $rest = {
            param($Method, $Uri)
            $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Uri -match '/actions/workflows/ci\.yml/runs\?') {
                $i = [math]::Min($state.RunsAsked, [math]::Max($runs.Count - 1, 0))
                $state.RunsAsked++
                $answer = if ($runs.Count) { $runs[$i] } else { @() }
                $event = [regex]::Match($Uri, 'event=([a-z_]+)').Groups[1].Value
                return [pscustomobject]@{ workflow_runs = @($answer | Where-Object { $ignore -or $_.event -eq $event }) }
            }
            if ($Uri -match '/actions/runs/(\d+)/jobs\?') { return [pscustomobject]@{ jobs = @($jobs) } }
            throw "unexpected call $Method $Uri"
        }.GetNewClosure()
        [pscustomobject]@{ State = $state; Rest = $rest }
    }
    function script:New-CiRun([long]$Id = 11, [string]$Status = 'completed', [string]$Conclusion = 'success', [string]$Event = 'push', [string]$Sha = $script:sha) {
        [pscustomobject]@{ id = $Id; status = $Status; conclusion = $Conclusion; event = $Event; head_sha = $Sha; html_url = "https://github.com/contoso/repo/actions/runs/$Id" }
    }
    function script:New-CiJob([string]$Name = 'CI result', [string]$Conclusion = 'success') {
        [pscustomobject]@{ name = $Name; status = 'completed'; conclusion = $Conclusion }
    }
    function script:Invoke-CiWait($Fake, [string[]]$Event = @('push', 'workflow_dispatch'), [int]$TimeoutMinutes = 5) {
        & $script:tool -Repository 'contoso/repo' -Sha $script:sha -Event $Event -TimeoutMinutes $TimeoutMinutes -PollSeconds 0 -Rest $Fake.Rest 6>$null
    }
}

Describe 'RELEASE-NO-SECOND-SUITE-1: CI passed on the exact commit' {

    It 'passes when the newest CI run of the commit and its job CI result both ended success' {
        $fake = New-CiFake -Runs @(, @(New-CiRun)) -Jobs @((New-CiJob 'Gates and unit tests 1 of 4 (Windows)'), (New-CiJob))
        $r = Invoke-CiWait $fake
        $r.RunId | Should -Be 11
        $r.Sha | Should -Be $script:sha
    }

    It 'asks for runs of ci.yml on this commit, one event at a time, and the latest jobs of that run' {
        $fake = New-CiFake -Runs @(, @(New-CiRun)) -Jobs @(New-CiJob)
        $null = Invoke-CiWait $fake
        $uris = @($fake.State.Calls.Uri)
        $uris | Should -Contain "https://api.github.com/repos/contoso/repo/actions/workflows/ci.yml/runs?head_sha=$($script:sha)&event=push&per_page=100"
        $uris | Should -Contain "https://api.github.com/repos/contoso/repo/actions/workflows/ci.yml/runs?head_sha=$($script:sha)&event=workflow_dispatch&per_page=100"
        $uris | Should -Contain 'https://api.github.com/repos/contoso/repo/actions/runs/11/jobs?filter=latest&per_page=100'
        @($fake.State.Calls.Method | Sort-Object -Unique) | Should -Be @('Get')
    }

    It 'REFUSES when CI result failed, and says nothing was tagged or released' {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Conclusion 'failure')) -Jobs @(New-CiJob -Conclusion 'failure')
        { Invoke-CiWait $fake } | Should -Throw '*failure*Nothing was tagged or released*'
    }

    It 'REFUSES when the run ended success but CI result did not, and the other way round' -ForEach @(
        @{ Run = 'success'; Job = 'skipped' }, @{ Run = 'failure'; Job = 'success' }, @{ Run = 'cancelled'; Job = 'cancelled' }
    ) {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Conclusion $Run)) -Jobs @(New-CiJob -Conclusion $Job)
        { Invoke-CiWait $fake } | Should -Throw '*Nothing was tagged or released*'
    }

    It 'REFUSES a run with no job named CI result, or with two' -ForEach @(
        @{ Jobs = @() }, @{ Jobs = @('two') }
    ) {
        $list = if ($Jobs.Count) { @((New-CiJob), (New-CiJob)) } else { @(New-CiJob 'Gates (Windows)') }
        $fake = New-CiFake -Runs @(, @(New-CiRun)) -Jobs $list
        { Invoke-CiWait $fake } | Should -Throw "*'CI result'*"
    }

    It 'never counts a pull request run: it tests the pull request merged into its base, not this commit' {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Event 'pull_request')) -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw '*no CI run*'
        @($fake.State.Calls.Uri | Where-Object { $_ -match 'event=pull_request' }) | Should -BeNullOrEmpty
    }

    It 'never counts a run of another commit, even when GitHub hands one back' {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Sha ('1' * 40))) -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw '*no CI run*'
    }

    It 'never counts a run of another event, even when GitHub hands one back' {
        $fake = New-CiFake -IgnoreEvent -Runs @(, @(New-CiRun -Event 'pull_request')) -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw '*no CI run*'
    }

    It 'only the events it is given count: a release of a merge to main reads push runs only' {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Event 'workflow_dispatch')) -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -Event 'push' -TimeoutMinutes 0 } | Should -Throw '*no CI run*'
    }

    It 'the newest run decides: an older run that passed does not hide a newer one that failed' {
        $runs = @((New-CiRun -Id 11), (New-CiRun -Id 12 -Event 'workflow_dispatch' -Conclusion 'failure'))
        $fake = New-CiFake -Runs @(, $runs) -Jobs @(New-CiJob -Conclusion 'failure')
        { Invoke-CiWait $fake } | Should -Throw '*runs/12*'
    }

    It 'waits for a run that has not ended, then passes when it ends well' {
        $fake = New-CiFake -Runs @(@(New-CiRun -Status 'in_progress' -Conclusion ''), @(New-CiRun)) -Jobs @(New-CiJob)
        $r = Invoke-CiWait $fake
        $r.RunId | Should -Be 11
        $fake.State.RunsAsked | Should -BeGreaterThan 2 -Because 'it asked again after the run was still going'
    }

    It 'waits for a run that is not there yet (a run can start minutes late), then passes' {
        $fake = New-CiFake -Runs @(@(), @(New-CiRun)) -Jobs @(New-CiJob)
        (Invoke-CiWait $fake).RunId | Should -Be 11
    }

    It 'REFUSES after its time limit when the run has not ended, and names the run' {
        $fake = New-CiFake -Runs @(, @(New-CiRun -Status 'in_progress' -Conclusion '')) -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw '*runs/11*not ended*Nothing was tagged or released*'
    }

    It 'REFUSES after its time limit when there is no run at all' {
        $fake = New-CiFake -Runs @() -Jobs @()
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw '*no CI run*Nothing was tagged or released*'
    }

    It 'with no time limit (the private Release button), it looks once, never sleeps, and says to press Release again (RELEASE-FLOW-RESTORE-1)' -ForEach @(
        @{ Case = 'not ended'; Runs = @(, @(@{ Status = 'in_progress' })); Says = '*runs/11*has not ended*does not wait for CI*Nothing was tagged or released*press Release again*' }
        @{ Case = 'no run'; Runs = @(); Says = '*There is no CI run*does not wait for CI*Nothing was tagged or released*press Release again*' }
    ) {
        Mock Start-Sleep { }
        $list = @(foreach ($r in $Runs) { , @(New-CiRun -Status 'in_progress' -Conclusion '') })
        $fake = New-CiFake -Runs $list -Jobs @(New-CiJob)
        { Invoke-CiWait $fake -TimeoutMinutes 0 } | Should -Throw $Says
        $fake.State.RunsAsked | Should -Be 2 -Because 'one look for each of the two events, and no second look'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'with a time limit, a run that has not ended is waited for (the Start-Sleep stand-in sees the wait)' {
        Mock Start-Sleep { }
        $fake = New-CiFake -Runs @(@(New-CiRun -Status 'in_progress' -Conclusion ''), @(New-CiRun -Status 'in_progress' -Conclusion ''), @(New-CiRun)) -Jobs @(New-CiJob)
        (Invoke-CiWait $fake).RunId | Should -Be 11
        Should -Invoke Start-Sleep -Times 1
    }
    It 'refuses a commit that is not a full commit id, and an empty token, before it asks GitHub anything' {
        { & $script:tool -Repository 'contoso/repo' -Sha 'main' -PollSeconds 0 -Rest { throw 'asked' } } | Should -Throw
        { & $script:tool -Repository 'contoso/repo' -Sha $script:sha -Token '' -PollSeconds 0 } | Should -Throw '*token*'
    }
}

Describe 'RELEASE-NO-SECOND-SUITE-1: the tool' {

    It 'parses, and puts no variable straight before a question mark in a string' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$errs) | Out-Null
        @($errs) -join '; ' | Should -BeNullOrEmpty
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        Get-VmfCodeOnly -Language PowerShell -Text ([IO.File]::ReadAllText($script:tool)) | Should -Not -Match '\$[A-Za-z_]+\?'
    }
}
