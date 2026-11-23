<#
.SYNOPSIS
    RELEASE-NO-SECOND-SUITE-1: refuse a release unless CI passed on the exact
    commit it releases.

.DESCRIPTION
    A release used to run the whole suite again in one job - about an hour
    each time - on a commit CI had already checked in four jobs at once. Now
    each release workflow runs this instead. It asks GitHub, with the
    workflow's own token, for the runs of the CI workflow (-Workflow) on the
    commit -Sha, and:

      - counts only runs of the events in -Event. A pull request run never
        counts: GitHub files it under the pull request's head commit, but it
        tests that commit merged into its base, which is another tree;
      - counts only runs whose head_sha is -Sha, whatever GitHub hands back;
      - lets the NEWEST such run decide (a run that is run again keeps its id
        and shows its latest attempt);
      - passes when that run ended "success" and its one job named -JobName
        ("CI result", the job that passes only when every other job passed)
        ended "success";
      - throws at once when the run ended any other way;
      - waits while the run has not ended, or while there is no run yet (a
        run can start minutes after its push, CI-DISPATCH-1), and throws when
        -TimeoutMinutes have passed;
      - with -TimeoutMinutes 0, looks once and throws at once when the run
        has not ended or is not there (RELEASE-FLOW-RESTORE-1: the private
        Release button never waits for CI).

    Every refusal says that nothing was tagged or released: the workflows run
    this before they tag or publish anything.

    It only reads. The REST calls go through -Rest, so the tests give a
    stand-in GitHub; the default calls the API with -Token.

.PARAMETER Repository
    owner/name. The workflow gives GITHUB_REPOSITORY.

.PARAMETER Sha
    The full commit id that is released.

.PARAMETER Event
    The events whose runs count: push, workflow_dispatch, or both.

.PARAMETER Workflow
    The file name of the CI workflow.

.PARAMETER JobName
    The job that gives the result of the whole run.

.PARAMETER TimeoutMinutes
    How long to wait for a run that has not ended, or is not there yet.

.PARAMETER PollSeconds
    How long to wait between two looks.

.PARAMETER Token
    A token that may read the repository's Actions runs.

.PARAMETER Rest
    { param($Method, $Uri) }. Tests give a stand-in GitHub.


.EXAMPLE
    ./tools/Wait-VmfCiResult.ps1 -Repository $env:GITHUB_REPOSITORY -Sha $env:GITHUB_SHA -Event push
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Sha,
    [ValidateSet('push', 'workflow_dispatch')][string[]]$Event = @('push', 'workflow_dispatch'),
    [ValidatePattern('^[A-Za-z0-9_.-]+\.ya?ml$')][string]$Workflow = 'ci.yml',
    [ValidateNotNullOrEmpty()][string]$JobName = 'CI result',
    [ValidateRange(0, 600)][int]$TimeoutMinutes = 120,
    [ValidateRange(0, 600)][int]$PollSeconds = 30,
    [AllowEmptyString()][string]$Token = $env:GH_TOKEN,
    [scriptblock]$Rest
)

$ErrorActionPreference = 'Stop'
if (-not $Rest) {
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'There is no token to read the CI runs with (GH_TOKEN), so CI on the commit cannot be checked. Nothing was tagged or released.'
    }
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $Rest = {
        param($Method, $Uri)
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }.GetNewClosure()
}

$api = "https://api.github.com/repos/$Repository/actions"
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$Sha = $Sha.ToLowerInvariant()

while ($true) {
    $runs = @(foreach ($e in $Event) {
            $page = & $Rest 'Get' "$api/workflows/$Workflow/runs?head_sha=$Sha&event=$e&per_page=100"
            @($page.workflow_runs) | Where-Object { $_ -and [string]$_.head_sha -eq $Sha -and [string]$_.event -eq $e }
        })
    $run = $runs | Sort-Object -Property { [long]$_.id } -Descending | Select-Object -First 1

    if ($run -and [string]$run.status -eq 'completed') {
        $jobs = @(@((& $Rest 'Get' "$api/runs/$($run.id)/jobs?filter=latest&per_page=100").jobs) | Where-Object { $_ -and [string]$_.name -eq $JobName })
        if ($jobs.Count -ne 1) {
            throw "The CI run $($run.html_url) of commit $Sha has $($jobs.Count) jobs named '$JobName', and a release needs exactly one that passed. Nothing was tagged or released."
        }
        $jobResult = [string]$jobs[0].conclusion
        if ([string]$run.conclusion -eq 'success' -and $jobResult -eq 'success') {
            Write-Host "CI passed on commit ${Sha}: the job '$JobName' of $($run.html_url) ended success."
            return [pscustomobject]@{ Sha = $Sha; RunId = [long]$run.id; Url = [string]$run.html_url }
        }
        throw "CI on commit $Sha ended '$($run.conclusion)', and its job '$JobName' ended '$jobResult' ($($run.html_url)). Nothing was tagged or released. Make CI pass on this commit, then start the release again."
    }

    if ([DateTime]::UtcNow -ge $deadline) {
        # RELEASE-FLOW-RESTORE-1: with -TimeoutMinutes 0 this is the first
        # look, and the private Release button never waits: a job that waits
        # holds a runner CI needs. The public release waits up to its limit.
        $what = if ($run) { "the CI run $($run.html_url) of commit $Sha has not ended (status '$($run.status)')" }
        else { "there is no CI run of $Workflow ($($Event -join ' or ')) on commit $Sha" }
        if ($TimeoutMinutes -eq 0) {
            throw "$($what.Substring(0, 1).ToUpperInvariant())$($what.Substring(1)), and the release does not wait for CI. Nothing was tagged or released. When the job '$JobName' passed on this commit, press Release again."
        }
        throw "After $TimeoutMinutes minutes, $what. Nothing was tagged or released. When CI passed on this commit, start the release again."
    }
    $state = if ($run) { "the run $($run.html_url) is '$($run.status)'" } else { 'there is no CI run yet' }
    Write-Host "Waiting for CI on commit ${Sha}: $state."
    Start-Sleep -Seconds $PollSeconds
}
