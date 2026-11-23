<#
.SYNOPSIS
    RELEASE-FLOW-RESTORE-1: check that CI passed on the head of main, commit
    the version on top of that exact commit, push it to main and tag it. It
    never waits.

.DESCRIPTION
    The Release button (.github/workflows/release.yml) runs this, in one job
    of a few minutes, then makes the bill of materials and publishes the
    release. The rules live here and the workflow runs them: two copies of
    "what refuses a release" would drift.

    In order, and nothing anybody else can see changes before every check
    passed:

      1. The checkout must be the head of main on the remote. When main moved
         after the run started, it stops.
      2. It picks the commit to release:
           A. THE TAG v<Version> IS ALREADY THERE (an earlier run stopped
              after its tag, before its release was published): the tagged
              commit, which main must hold. Nothing is committed or tagged.
           B. MAIN ALREADY STATES <Version> (an earlier run stopped after its
              push to main, or the version came in a pull request): the head
              of main. Nothing is committed.
           C. OTHERWISE, the normal press: a new version commit, made in 4.
      3. CI result passed on the commit CI checked (tools/Wait-VmfCiResult.ps1
         with -TimeoutMinutes 0: push or workflow_dispatch runs of ci.yml on
         that exact commit, one look, no wait). A run that has not ended,
         failed, or is not there is a refusal. The commit CI checked is the
         commit to release for A and B, and the head of main for C - in each
         case after going down through every version commit (one that changes
         exactly README.md's "Version **x.y.z**" line and the manifest's
         ModuleVersion line, and nothing else): the workflow token pushed it,
         and that push started no CI.
      4. For C, tools/New-VmfRelease.ps1 commits the version on top of that
         head (its refusals: a dirty tree, not main, a version that does not
         move forward), and the commit goes to main with NO force. When main
         moved since step 1, git refuses, and nothing is tagged.
      5. The annotated tag v<Version> on that commit, pushed with no force.

    It gives { Version; Tag; Sha; CheckedSha; Made }.

.PARAMETER Version
    The version to release, for example 1.1.0.

.PARAMETER Repository
    owner/name. The workflow gives GITHUB_REPOSITORY.

.PARAMETER Token
    The workflow's token: it reads the CI runs.

.PARAMETER RepoRoot
    The checkout of main, with every tag. Default: the repository this script is in.

.PARAMETER Remote
    The git remote of the repository.

.PARAMETER NewReleaseScript
    The tool that commits the version. Tests give a copy in their own repository.

.PARAMETER WaitScript
    The tool that checks CI on a commit.

.PARAMETER Rest
    { param($Method, $Uri) }, handed to the CI check. Tests give a stand-in GitHub.

.EXAMPLE
    ./tools/New-VmfReleaseTag.ps1 -Version 1.1.0 -Repository $env:GITHUB_REPOSITORY
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [AllowEmptyString()][string]$Token = $env:GH_TOKEN,
    [string]$RepoRoot = ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))),
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Remote = 'origin',
    [string]$NewReleaseScript = (Join-Path $PSScriptRoot 'New-VmfRelease.ps1'),
    [string]$WaitScript = (Join-Path $PSScriptRoot 'Wait-VmfCiResult.ps1'),
    [scriptblock]$Rest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VmfReleaseVersion.ps1')
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$tag = "v$Version"
# A version commit changes one line in each of these two files and nothing else (tools/New-VmfRelease.ps1).
$versionFiles = @('README.md', 'src/VmMigrationFactory/VmMigrationFactory.psd1')

function Invoke-VmfReleaseGit {
    # git in the checkout, its output kept, and a failure that says what git
    # said. Long options only: a short one such as -d would bind to -Debug.
    param([Parameter(Mandatory)][string]$Step, [Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    # ONLY STANDARD OUTPUT IS THE ANSWER. A warning git writes to standard
    # error (seen 2026-11-20 with no global git config: a line that starts
    # "bash.exe:") must never be read as a commit id; it was, and a release
    # refused with "main is bash.exe: now". Standard error goes only into the
    # failure message.
    $global:LASTEXITCODE = 0
    $all = @(& git -C $RepoRoot @GitArgs 2>&1)
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $err = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "git could not $Step (exit $LASTEXITCODE): $(($err + $out) -join ' ')" }
    $out
}

function Get-VmfRemoteMain {
    $line = @(Invoke-VmfReleaseGit 'read the main of the remote' ls-remote $Remote 'refs/heads/main' | Where-Object { $_ })
    if (-not $line.Count) { throw 'The remote has no main branch, so nothing was committed, tagged or released.' }
    ($line[0] -split '\s+')[0]
}

function Test-VmfVersionLineChange([string]$Before, [string]$After, [string]$File) {
    # One changed line of a version commit: the same line with only the
    # version number changed. README.md: the "Version **x.y.z**" line
    # (Get-VmfReadmeVersionPattern). The manifest: the ModuleVersion line.
    $number = '(\d+\.\d+\.\d+)'
    if ($File -eq 'README.md') {
        $m = [regex]::Match($Before, "Version \*\*$number\*\*")
        if (-not $m.Success -or $Before -notmatch (Get-VmfReadmeVersionPattern $m.Groups[1].Value)) { return $false }
        $n = [regex]::Match($After, "Version \*\*$number\*\*")
        if (-not $n.Success -or $After -notmatch (Get-VmfReadmeVersionPattern $n.Groups[1].Value)) { return $false }
    }
    else {
        $m = [regex]::Match($Before, "^\s*ModuleVersion\s*=\s*'$number'\s*$")
        $n = [regex]::Match($After, "^\s*ModuleVersion\s*=\s*'$number'\s*$")
        if (-not $m.Success -or -not $n.Success) { return $false }
    }
    $old = $m.Groups[1]; $newNumber = $n.Groups[1].Value
    ($Before.Substring(0, $old.Index) + $newNumber + $Before.Substring($old.Index + $old.Length)) -ceq $After
}

function Get-VmfVersionCommitParent([string]$Sha) {
    # The first parent of a version commit; $null for any other commit. A
    # version commit (tools/New-VmfRelease.ps1) changes exactly two lines:
    # README.md's "Version **x.y.z**" line and the manifest's ModuleVersion
    # line, each to the same line with another number, and nothing else. A
    # merge that changes any other line of either file is not one: its own
    # CI is read.
    $parents = @(@(Invoke-VmfReleaseGit 'read the parents of the commit' rev-list --parents --max-count=1 $Sha)[0] -split '\s+' | Select-Object -Skip 1)
    if ($parents.Count -lt 1) { return $null }
    $changed = @(Invoke-VmfReleaseGit 'read the files the commit changes' diff --name-only $parents[0] $Sha | Where-Object { $_ } | Sort-Object)
    if (($changed -join '|') -ne (($versionFiles | Sort-Object) -join '|')) { return $null }
    foreach ($file in $versionFiles) {
        $diff = @(Invoke-VmfReleaseGit 'read the lines the commit changes' diff --unified=0 --no-color --no-ext-diff $parents[0] $Sha -- $file)
        $body = @($diff | Where-Object { $_ -notmatch '^(diff |index |--- |\+\+\+ |@@|\\ )' -and $_ -notmatch '^(old|new) mode ' })
        $removed = @($body | Where-Object { $_.StartsWith('-') } | ForEach-Object { $_.Substring(1) })
        $added = @($body | Where-Object { $_.StartsWith('+') } | ForEach-Object { $_.Substring(1) })
        if ($removed.Count -ne 1 -or $added.Count -ne 1 -or $body.Count -ne 2) { return $null }
        if (-not (Test-VmfVersionLineChange $removed[0] $added[0] $file)) { return $null }
    }
    $parents[0]
}

function Get-VmfCheckedCommit([string]$Sha) {
    # The commit CI checked: down through version commits, which the workflow
    # token pushed and so had no CI run, to the first commit that is not one.
    for ($i = 0; $i -lt 50; $i++) {
        $parent = Get-VmfVersionCommitParent $Sha
        if (-not $parent) { return $Sha }
        $Sha = $parent
    }
    throw "The last 50 commits under main change only the version, so no commit CI checked was found. Nothing was committed, tagged or released."
}

# --- 1. the checkout is the head of main ------------------------------------------
$mainSha = Get-VmfRemoteMain
$head = @(Invoke-VmfReleaseGit 'read the checkout' rev-parse HEAD)[0]
if ($head -ne $mainSha) {
    throw "main moved after the run started: the checkout is $head, and main is $mainSha now. Nothing was committed, tagged or released. Press Release again."
}

# --- 2. the commit to release ------------------------------------------------------
# A tag only this folder has (a runner keeps its folder between runs) is not a
# release: the remote is the record.
if (@(Invoke-VmfReleaseGit 'list the local tags' tag --list $tag | Where-Object { $_ }).Count) {
    $null = Invoke-VmfReleaseGit 'remove a local tag' tag --delete $tag
}
$remoteTag = @(Invoke-VmfReleaseGit 'read the tags of the remote' ls-remote --tags $Remote "refs/tags/$tag" | Where-Object { $_ })
$sha = $null
if ($remoteTag.Count) {
    # --- A. the tag is already there ---
    $null = Invoke-VmfReleaseGit 'fetch the tag' fetch --quiet $Remote "refs/tags/${tag}:refs/tags/$tag"
    $sha = @(Invoke-VmfReleaseGit 'read the tagged commit' rev-parse "refs/tags/$tag^{commit}")[0]
    $global:LASTEXITCODE = 0
    $null = & git -C $RepoRoot merge-base --is-ancestor $sha $mainSha 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "The tag $tag is on $sha, a commit main does not hold. Nothing was committed, tagged or released. Delete that tag if it has no release, then press Release again."
    }
    $made = 'nothing: the tag was already there'
}
elseif ((Get-VmfReleaseVersion -Root $RepoRoot) -eq $Version) {
    # --- B. main already states the version ---
    $sha = $mainSha
    $made = 'nothing: main already states the version'
}

# --- 3. CI result passed on the commit CI checked; one look, no wait -------------------
# For C the head of main itself may be the version commit of the release
# before, which no CI ran on: the same rule finds the commit under it.
$checked = if ($sha) { Get-VmfCheckedCommit $sha } else { Get-VmfCheckedCommit $mainSha }
$waitArgs = @{ Repository = $Repository; Sha = $checked; Event = @('push', 'workflow_dispatch'); Token = $Token; TimeoutMinutes = 0; PollSeconds = 0 }
if ($Rest) { $waitArgs.Rest = $Rest }
$null = & $WaitScript @waitArgs

# --- 4. the version commit on top of that exact commit, to main with no force -------------
if (-not $sha) {
    & $NewReleaseScript -Version $Version
    $sha = @(Invoke-VmfReleaseGit 'read the version commit' rev-parse HEAD)[0]
    if ((Get-VmfVersionCommitParent $sha) -ne $mainSha) {
        throw "The version commit ($sha) is not one commit of the version on top of main ($mainSha), so nothing was pushed, tagged or released."
    }
    try { $null = Invoke-VmfReleaseGit 'push the version commit to main' push $Remote "${sha}:refs/heads/main" }
    catch {
        throw "main moved after the run started, so git refused the version commit and nothing was tagged or released. Press Release again. ($($_.Exception.Message))"
    }
    Write-Host "Put the version commit $sha on main, on top of $mainSha, the commit CI passed on."
    $made = 'the version commit'
}

# --- 5. the tag ----------------------------------------------------------------------------
if ($remoteTag.Count) {
    Write-Host "The tag $tag is already on $sha. Nothing is tagged again."
}
else {
    $null = Invoke-VmfReleaseGit 'make the tag' tag --annotate $tag $sha --message "Release $tag"
    $null = Invoke-VmfReleaseGit 'push the tag' push $Remote "refs/tags/${tag}:refs/tags/$tag"
    Write-Host "Tagged $tag on $sha."
}
[pscustomobject]@{ Version = $Version; Tag = $tag; Sha = $sha; CheckedSha = $checked; Made = $made }
