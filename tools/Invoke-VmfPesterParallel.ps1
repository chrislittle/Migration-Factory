<#
.SYNOPSIS
    CI-SPEED-3: run the Pester suite as several groups of test files at once.
.DESCRIPTION
    Pester 5 runs every test file one after another on one core. The suite is
    about 340 files, and most of the time goes on each file's own set-up, not
    on its tests - so on a machine with idle cores, groups of files in
    separate processes finish in a fraction of the time.

    Each group is its own PowerShell process with the pinned Pester loaded,
    so the groups share nothing in memory. The results are added up here:
    every failure is printed with its message, a file that could not even be
    read counts as a failure, and the exit code is 1 when anything failed.
    TEST-DISCOVERY-DROP-1: a file that throws while Pester reads it is a
    failure too, even when the tests found before the throw all passed - and
    so is any group whose run Pester itself calls Failed.

    The groups are balanced by how long each file took last time on this
    machine (kept in the temp folder), and by file size when there is no
    record yet. CI's shares are balanced on the measured times in the
    repository instead (tests/test-timings.json), the same on every runner.
.PARAMETER TestPath
    A folder of *.Tests.ps1 files, or one file. Default tests/unit.
.PARAMETER Groups
    How many processes at once. Default: half the logical processors, at
    least 1 and at most 6 - so the machine stays usable.
.PARAMETER Shard
    CI-SHARD-1: run only this share of the files, from 1 to ShardCount. CI
    runs each share as its own job, on its own runner. Give the same two
    numbers here to run one CI job's files on this machine.
.PARAMETER ShardCount
    CI-SHARD-1: how many shares the files are split into.
.PARAMETER TimingsFile
    CI-SHARD-MEASURE-1: the measured seconds of each test file, which the
    shares are balanced on. Default tests/test-timings.json. Refresh it with
    tools/Update-VmfTestTimings.ps1.
.PARAMETER ShowTimings
    CI-SHARD-MEASURE-1: write the seconds of each test file to the output,
    one line each, for tools/Update-VmfTestTimings.ps1 to read. A share run
    (-Shard) always writes them.
.EXAMPLE
    ./tools/Invoke-VmfPesterParallel.ps1
.EXAMPLE
    ./tools/Invoke-VmfPesterParallel.ps1 -Groups 1
.EXAMPLE
    ./tools/Invoke-VmfPesterParallel.ps1 -Shard 2 -ShardCount 3
.EXAMPLE
    ./tools/Invoke-VmfPesterParallel.ps1 -ShowTimings *> pester.log
#>
[CmdletBinding()]
param(
    [Parameter()][string]$TestPath = 'tests/unit',
    [Parameter()][ValidateRange(1, 32)][int]$Groups = [Math]::Max(1, [Math]::Min(6, [Math]::Floor([Environment]::ProcessorCount / 2))),
    [Parameter()][string]$PesterVersion = '5.9.1',
    [Parameter()][ValidateRange(1, 32)][int]$Shard,
    [Parameter()][ValidateRange(1, 32)][int]$ShardCount,
    [Parameter()][string]$TimingsFile = (Join-Path $PSScriptRoot '..' 'tests' 'test-timings.json'),
    [Parameter()][switch]$ShowTimings,
    # Internal: the file of test paths ONE group runs, and where it writes its
    # result. The parent calls this same script with these.
    [Parameter()][string]$GroupFile,
    [Parameter()][string]$ResultFile
)

$ErrorActionPreference = 'Stop'

function Split-VmfTestGroups {
    <#
    .SYNOPSIS
        Share files between groups so each group's total weight is as even as
        it can be: the heaviest file first, each to the lightest group so far.
    .OUTPUTS
        An array of arrays of paths, one per group, no group empty unless
        there are fewer files than groups.
    #>
    param([Parameter(Mandatory)][hashtable]$Weights, [Parameter(Mandatory)][int]$Count)
    $bins = @(for ($i = 0; $i -lt $Count; $i++) { [pscustomobject]@{ Total = 0.0; Files = [System.Collections.Generic.List[string]]::new() } })
    foreach ($entry in ($Weights.GetEnumerator() | Sort-Object { $_.Value } -Descending)) {
        $lightest = $bins | Sort-Object Total | Select-Object -First 1
        $lightest.Files.Add($entry.Key)
        $lightest.Total += [double]$entry.Value
    }
    , @($bins | Where-Object { $_.Files.Count } | ForEach-Object { , @($_.Files) })
}

# ---------------------------------------------------------------- shares
# CI-SHARD-1: CI runs the files as several jobs, one share each, and every job
# works out the whole split for itself. So the split must come out the same on
# every runner, from what every runner has: the commit's files.
#
# NOT the timing history the groups above are balanced on. That is kept in
# each machine's own temp folder, so two runners hold two histories, would
# make two splits, and a file would run twice or not at all - with every job
# green. Size is what every runner sees alike. Measured 2026-10-17 against the
# timing history of a full local run: the heaviest of three shares by size
# took 1% longer than an even third, by name in turn 2%, by the history
# itself 0.1%.
#
# CI-SHARD-MEASURE-1: the shares are now balanced on MEASURED seconds, kept in
# the repository (tests/test-timings.json), so every runner reads the same
# numbers. Size split the files unevenly: main run 39158910940 on the pool
# runners gave the three shares 548, 417 and 332 seconds of Pester. Size
# stays the weight only when the file names no test file of this run.
#
# Everything here is exact and has one order: weights are whole numbers, ties
# go to the name in ordinal order (never the machine's language settings), and
# a file is named by its path from the test folder with forward slashes.

function Get-VmfShardWeight {
    <#
    .SYNOPSIS
        A test file's weight for the split: its size in bytes, carriage
        returns not counted - so a CRLF checkout weighs the same as an LF one.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # Latin-1 maps each byte to one character, so this counts bytes exactly.
    $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($Path))
    [long]$text.Replace("`r", '').Length
}

function Get-VmfShardKey {
    <#
    .SYNOPSIS
        A test file's name for the split: its path from the test folder, with
        forward slashes, the same on every runner whatever folder it checks
        out into.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$File)
    [System.IO.Path]::GetRelativePath($Root, $File).Replace('\', '/')
}

function Read-VmfTestTimings {
    <#
    .SYNOPSIS
        The measured time of each test file, in whole milliseconds, by its
        key (Get-VmfShardKey). An empty table when there is no file. A file
        that cannot be read stops the run: every share would stop the same
        way, so no file runs twice or never.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $ms = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $ms }
    $data = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path) | ConvertFrom-Json
    if (-not $data.seconds) { throw "The timings file '$Path' has no 'seconds' object." }
    foreach ($prop in $data.seconds.PSObject.Properties) {
        $value = [double]$prop.Value
        if ($value -lt 0) { throw "The timings file '$Path' gives $($prop.Name) a time below zero." }
        $ms[[string]$prop.Name] = [long][Math]::Round($value * 1000)
    }
    $ms
}

function Get-VmfShardWeights {
    <#
    .SYNOPSIS
        Each file's weight for the split: its measured milliseconds, and the
        median of the measured files of this run for a file with no time yet
        (the lower of the two middle values when the count is even, so it
        stays a whole number). When no file of this run has a time, every
        weight is the size (Get-VmfShardWeight), as before.
    #>
    param([Parameter(Mandatory)][hashtable]$Sizes, [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Measured)
    $known = [System.Collections.Generic.List[long]]::new()
    foreach ($key in $Sizes.Keys) { if ($Measured.ContainsKey($key)) { $known.Add([long]$Measured[$key]) } }
    if ($known.Count -eq 0) { return @{} + $Sizes }
    $known.Sort()
    $median = $known[[int][Math]::Floor(($known.Count - 1) / 2)]
    $weights = @{}
    foreach ($key in $Sizes.Keys) { $weights[$key] = if ($Measured.ContainsKey($key)) { [long]$Measured[$key] } else { $median } }
    $weights
}

function Split-VmfTestShards {
    <#
    .SYNOPSIS
        Share files between shards: the heaviest first, each to the lightest
        shard so far, the lower-numbered shard on a tie.
    .OUTPUTS
        An array of exactly Count arrays of keys. A shard is empty only when
        there are fewer files than shards.
    #>
    param([Parameter(Mandatory)][hashtable]$Weights, [Parameter(Mandatory)][int]$Count)
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $Weights.Keys) { $files.Add([pscustomobject]@{ Name = [string]$key; Weight = [long]$Weights[$key] }) }
    # The names are unique, so this order is total: the result never depends
    # on the order the table hands its keys out, which differs per process.
    $files.Sort([System.Comparison[object]] {
            param($a, $b)
            $byWeight = $b.Weight.CompareTo($a.Weight)
            if ($byWeight -ne 0) { return $byWeight }
            [string]::CompareOrdinal($a.Name, $b.Name)
        })
    $totals = [long[]]::new($Count)
    $shards = @(for ($i = 0; $i -lt $Count; $i++) { , [System.Collections.Generic.List[string]]::new() })
    foreach ($file in $files) {
        $lightest = 0
        for ($i = 1; $i -lt $Count; $i++) { if ($totals[$i] -lt $totals[$lightest]) { $lightest = $i } }
        $shards[$lightest].Add($file.Name)
        $totals[$lightest] += $file.Weight
    }
    , @(foreach ($shard in $shards) { $names = $shard.ToArray(); [Array]::Sort($names, [System.StringComparer]::Ordinal); , $names })
}

function Get-VmfSplitId {
    <#
    .SYNOPSIS
        A short fingerprint of the whole split. Every share of one commit
        prints it, so a person can see the jobs agreed.
    #>
    param([Parameter(Mandatory)][object[]]$Shards)
    $lines = for ($i = 0; $i -lt $Shards.Count; $i++) { foreach ($name in @($Shards[$i])) { "$i`t$name" } }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((@($lines) -join "`n"))
    ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' | ForEach-Object { $_.Substring(0, 12) }
}

# ---------------------------------------------------------------- judging a run
function Get-VmfFirstLines {
    <#
    .SYNOPSIS
        The first four lines of an error message that are not blank.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    @([string]$Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4)
}

function ConvertTo-VmfGroupResult {
    <#
    .SYNOPSIS
        What one group's Pester run found, as plain data for the parent: the
        counts, every failure with its reason, the run's own verdict, and the
        seconds of each file.
    .DESCRIPTION
        TEST-DISCOVERY-DROP-1: a Describe that throws part way through
        discovery leaves its container's Result Passed and its FailedCount 0;
        the error is only in the container's ErrorRecord. So a container with
        ANY error record is a failure, and the run's own Result and failed
        container count travel with the result, for the parent to judge too.
    #>
    param([Parameter(Mandatory)]$Result)
    [ordered]@{
        passed  = $Result.PassedCount
        failed  = $Result.FailedCount
        skipped = $Result.SkippedCount
        # TEST-DISCOVERY-DROP-1: Pester's own verdict on the run. The parent
        # fails a group whose verdict is Failed even when nothing below names
        # why, so a case Pester reports in a new way is never green.
        run     = [ordered]@{ result = [string]$Result.Result; failedContainers = [int]$Result.FailedContainersCount }
        tests   = @($Result.Failed | ForEach-Object {
                [ordered]@{ name = $_.ExpandedPath; why = Get-VmfFirstLines ([string]$_.ErrorRecord.Exception.Message) } })
        # A file whose discovery or set-up threw has no failed TEST to show,
        # and would otherwise pass unnoticed. TEST-DISCOVERY-DROP-1: that
        # includes a file whose container says Passed but holds an error -
        # Pester ran the tests it found before the throw, and lost the rest.
        files   = @($Result.Containers | Where-Object { ($_.Result -eq 'Failed' -or @($_.ErrorRecord).Count) -and $_.FailedCount -eq 0 } | ForEach-Object {
                $kind = if ($_.PassedCount -eq 0) { 'unread' } elseif ($_.Result -ne 'Failed') { 'partial' } else { 'setup' }
                [ordered]@{ name = [string]$_.Item; kind = $kind; why = Get-VmfFirstLines ([string](@($_.ErrorRecord)[0].Exception.Message)) } })
        # REVIEW-1: a BeforeAll or AfterAll that throws. Pester marks the tests
        # under a failed BeforeAll failed with an EMPTY error, and keeps the
        # reason on the block - so without this a set-up failure printed its
        # tests' names and never why.
        blocks  = @($Result.FailedBlocks | ForEach-Object {
                [ordered]@{ name = [string]$_.ExpandedPath; why = Get-VmfFirstLines ([string](@($_.ErrorRecord)[0].Exception.Message)) } })
        # And a file-level BeforeAll or AfterAll, which sits on the container
        # even when some of its tests also failed.
        fileErrors = @($Result.Containers | Where-Object { @($_.ErrorRecord).Count -and $_.FailedCount -gt 0 } | ForEach-Object {
                [ordered]@{ name = [string]$_.Item; why = Get-VmfFirstLines ([string](@($_.ErrorRecord)[0].Exception.Message)) } })
        # CI-SHARD-MEASURE-1: discovery too - a file that builds its cases
        # while it is discovered spends that time before its tests run.
        seconds = @($Result.Containers | ForEach-Object { [ordered]@{ file = [string]$_.Item; s = [math]::Round(($_.Duration + $_.DiscoveryDuration).TotalSeconds, 2) } })
    }
}

function Measure-VmfGroupResult {
    <#
    .SYNOPSIS
        The parent's verdict on one group's result (read back from JSON):
        the counts to add up, and each failure to print with its reason.
    .DESCRIPTION
        A failed file counts as one failure. A failed block or a file-level
        error is a reason only: the tests it failed are counted already. And
        TEST-DISCOVERY-DROP-1: a group that Pester calls Failed, or that has
        a failed container, is a failure even when nothing else names one -
        and so is a result with no run record, which cannot be judged.
    #>
    param([Parameter(Mandatory)]$Group, [Parameter(Mandatory)][string]$Label)
    $failures = [System.Collections.Generic.List[object]]::new()
    $failed = [int]$Group.failed
    foreach ($t in @($Group.tests)) { if ($t) { $failures.Add($t) } }
    foreach ($f in @($Group.files)) {
        if (-not $f) { continue }
        $leaf = Split-Path ([string]$f.name) -Leaf
        $name = switch ([string]$f.kind) {
            'unread'  { "could not run: $leaf" }
            'partial' { "some tests did not run, Pester stopped while it read $leaf" }
            default   { "set-up or clean-up failed in $leaf" }
        }
        $failures.Add([pscustomobject]@{ name = $name; why = $f.why }); $failed++
    }
    foreach ($b in @($Group.blocks)) { if ($b) { $failures.Add([pscustomobject]@{ name = "set-up or clean-up failed: $($b.name)"; why = $b.why }) } }
    foreach ($f in @($Group.fileErrors)) { if ($f) { $failures.Add([pscustomobject]@{ name = "set-up or clean-up failed in $(Split-Path ([string]$f.name) -Leaf)"; why = $f.why }) } }
    if (-not $Group.run) {
        $failures.Add([pscustomobject]@{ name = "$Label gave a result with no run record, so the run cannot be judged"; why = @() }); $failed++
    }
    elseif ($failed -eq 0 -and ([string]$Group.run.result -eq 'Failed' -or [int]$Group.run.failedContainers -gt 0)) {
        $failures.Add([pscustomobject]@{
                name = "$Label`: Pester gave the result $($Group.run.result) with $([int]$Group.run.failedContainers) failed container(s), and named no failed test or file"
                why = @() }); $failed++
    }
    [pscustomobject]@{ Passed = [int]$Group.passed; Failed = $failed; Skipped = [int]$Group.skipped; Failures = @($failures) }
}

# ---------------------------------------------------------------- one group
if ($GroupFile) {
    Import-Module Pester -RequiredVersion $PesterVersion -Force
    $files = @(Get-Content $GroupFile | Where-Object { $_ })
    $config = New-PesterConfiguration
    $config.Run.Path = $files
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'None'
    # SUITE-SPEED-1, measured 2026-11-02 (docs/research/suite-speed-2026-11-02.md):
    # Pester makes and deletes a key under HKCU\Software\Pester for every test
    # file. That one shared key wears with each cycle, and several Pester
    # processes writing it at once made each call take 0.4-1.5 s - the local
    # suite went from about 17 minutes to 50-60. No test here uses
    # TestRegistry, so turning it off removes no coverage: 9.7 minutes, every
    # test passing. CI has one process per runner and never saw it.
    $config.TestRegistry.Enabled = $false
    $result = Invoke-Pester -Configuration $config
    ConvertTo-VmfGroupResult -Result $result | ConvertTo-Json -Depth 6 | Set-Content $ResultFile -Encoding utf8
    exit 0
}

# ---------------------------------------------------------------- the parent
$allFiles = if (Test-Path $TestPath -PathType Leaf) { @((Resolve-Path $TestPath).Path) }
            else { @(Get-ChildItem $TestPath -Filter '*.Tests.ps1' -Recurse | ForEach-Object FullName) }
if (-not $allFiles.Count) { throw "No test files under '$TestPath'." }
$suiteCount = $allFiles.Count
$shardNote = ''
if ($PSBoundParameters.ContainsKey('Shard') -or $PSBoundParameters.ContainsKey('ShardCount')) {
    if (-not $ShardCount) { throw 'Give -ShardCount with -Shard.' }
    if ($Shard -lt 1 -or $Shard -gt $ShardCount) { throw "Give -Shard from 1 to $ShardCount." }
    $shardRoot = if (Test-Path $TestPath -PathType Leaf) { Split-Path (Resolve-Path $TestPath).Path -Parent } else { (Resolve-Path $TestPath).Path }
    $byKey = @{}
    $sizes = @{}
    foreach ($file in $allFiles) {
        $key = Get-VmfShardKey -Root $shardRoot -File $file
        $byKey[$key] = $file
        $sizes[$key] = Get-VmfShardWeight -Path $file
    }
    $measured = Read-VmfTestTimings -Path $TimingsFile
    $shardWeights = Get-VmfShardWeights -Sizes $sizes -Measured $measured
    $byTime = @($sizes.Keys | Where-Object { $measured.ContainsKey($_) }).Count
    $shards = Split-VmfTestShards -Weights $shardWeights -Count $ShardCount
    $allFiles = @($shards[$Shard - 1] | ForEach-Object { $byKey[$_] })
    if (-not $allFiles.Count) { throw "Shard $Shard of $ShardCount has no test files: there are only $suiteCount." }
    $basis = if ($byTime) {
        $predicted = [long]0; foreach ($key in $shards[$Shard - 1]) { $predicted += $shardWeights[$key] }
        "by measured time: $byTime of $suiteCount files measured, about $([Math]::Round($predicted / 1000)) s"
    }
    else { 'by size: no file has a measured time' }
    $shardNote = "shard $Shard of $ShardCount (split $(Get-VmfSplitId -Shards $shards), $basis), "
}

$history = Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-test-seconds.json'
$known = @{}
if (Test-Path $history) {
    try { (Get-Content $history -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $known[$_.Name] = [double]$_.Value } } catch { $known = @{} }
}
$weights = @{}
foreach ($file in $allFiles) {
    $leaf = Split-Path $file -Leaf
    $weights[$file] = if ($known.ContainsKey($leaf)) { $known[$leaf] } else { (Get-Item $file).Length / 10000.0 }
}

$count = [Math]::Min($Groups, $allFiles.Count)
$split = Split-VmfTestGroups -Weights $weights -Count $count

# CI-BICEP-RESTORE-1: THE REGISTRY MODULES, BEFORE THE FLOOR BELOW CLOSES THE
# NETWORK. A test that runs `az bicep build` can read a br/public module only
# from this machine's Bicep cache, and a new machine has none (main CI run
# 39158910940). In CI the pin step restored them and failed if it could not,
# so this runs only for a person's run, and only when a test file in it builds
# a template. A test process that runs this tool has the floor already
# (VMF_TEST_AZURE_GUARD), so it never tries. A failure is a warning: a machine
# that is offline may still have the cache.
$needsBicep = @($allFiles | Where-Object { [System.IO.File]::ReadAllText($_) -match 'az bicep build' }).Count -gt 0
if (-not $env:GITHUB_ACTIONS -and -not $env:VMF_TEST_AZURE_GUARD -and $needsBicep) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $null = & (Join-Path $PSScriptRoot 'Restore-VmfBicepModules.ps1') -BestEffort
    }
    else { Write-Warning 'az is not installed, so the registry modules of the templates were not restored. A test that compiles a template can fail with BCP192.' }
}
# SUITE-TEMP-1: ONE FOLDER FOR EVERY TEST SCRATCH FILE. The tests use more than
# 200 temp folder names of their own, and a real-time scanner checks each file
# they write. Each group's process gets its own temp folder under
# <temp>\vmf-tests\run-<id>, so a scanner can leave test scratch alone with ONE
# narrow exclusion rather than a wildcard over the whole temp folder. A process
# a test starts inherits it. The run removes the folder when it ends; a run
# that was killed leaves one, and the next run removes any older than a day.
# A day is far longer than a suite (about 18 minutes), so a run in another
# worktree never loses a folder it is still using. A run folder's time changes
# only when a group folder is added, so a suite that ran for over a day - a
# machine asleep mid-run - could lose it.
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-tests'
Get-ChildItem $scratchRoot -Directory -Filter 'run-*' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$work = Join-Path $scratchRoot "run-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work -Force | Out-Null

$started = Get-Date

# TEST-AZURE-GUARD-1: A SECOND FLOOR, AT THE PROCESS. Unit tests must never
# reach Azure (hard rule 8), and on 2026-10-10 a gap in the Pester guard sent
# reads and one PUT there, signed in as the person running the tests. So every
# test process gets HTTP proxy settings that point at 0.0.0.0, which .NET
# refuses as a target at once: whatever the mocks do, a request fails before it
# leaves the machine. MEASURED 2026-10-11: Az PowerShell's own traffic - the
# endpoint lookup, the Entra token, the request - all goes through these
# settings. The person's saved Az context is never read or changed, so there
# is no sign-out and nothing to put back. Loopback stays direct, for a test
# that talks to its own machine.
#
# Set only while the processes start - a child copies the environment when it
# starts - and the caller's own values are put back at once. Both spellings:
# Linux treats them as two variables and some clients read only the lower-case
# one; on Windows they are one variable, read before anything is set.
#
# TEST-AZURE-GUARD-2: and VMF_TEST_AZURE_GUARD. A worker that a test starts
# (worker.ps1) is a new process that no Pester mock reaches; it inherits this
# value and loads the guard's stand-ins before the module. One spelling only:
# the product reads it, not an HTTP client.
$floor = [ordered]@{
    HTTP_PROXY = 'http://0.0.0.0:9'; HTTPS_PROXY = 'http://0.0.0.0:9'; ALL_PROXY = 'http://0.0.0.0:9'
    NO_PROXY = 'localhost,127.0.0.1,::1'
    VMF_TEST_AZURE_GUARD = '1'
}
$floorNames = @($floor.Keys) + @($floor.Keys | Where-Object { $_ -like '*_PROXY' } | ForEach-Object { $_.ToLowerInvariant() })
# SUITE-TEMP-1: Windows reads TMP then TEMP, Linux and macOS read TMPDIR.
$tempNames = @('TMP', 'TEMP', 'TMPDIR')
$floorNames += $tempNames
$callerValues = @{}
foreach ($name in $floorNames) { $callerValues[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    foreach ($name in $floorNames) { if ($name -notin $tempNames) { [Environment]::SetEnvironmentVariable($name, $floor[$name.ToUpperInvariant()]) } }
    $procs = for ($i = 0; $i -lt $split.Count; $i++) {
        $groupFile = Join-Path $work "group-$i.txt"
        $resultFile = Join-Path $work "result-$i.json"
        Set-Content $groupFile @($split[$i])
        $groupTemp = Join-Path $work "temp-$i"
        New-Item -ItemType Directory -Path $groupTemp | Out-Null
        foreach ($name in $tempNames) { [Environment]::SetEnvironmentVariable($name, $groupTemp) }
        $argsList = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-GroupFile', $groupFile, '-ResultFile', $resultFile, '-PesterVersion', $PesterVersion)
        [pscustomobject]@{
            Index = $i; ResultFile = $resultFile; Files = @($split[$i]).Count
            Process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argsList -NoNewWindow -PassThru `
                -RedirectStandardOutput (Join-Path $work "out-$i.txt") -RedirectStandardError (Join-Path $work "err-$i.txt")
        }
    }
}
finally {
    foreach ($name in $floorNames) { [Environment]::SetEnvironmentVariable($name, $callerValues[$name]) }
}
$fileNote = if ($shardNote) { "$($allFiles.Count) of $suiteCount" } else { "$($allFiles.Count)" }
Write-Host ("Pester {0}: {1}{2} test files in {3} groups at once..." -f $PesterVersion, $shardNote, $fileNote, $procs.Count) -ForegroundColor Cyan
$procs | ForEach-Object { $_.Process.WaitForExit() }

$passed = 0; $failed = 0; $skipped = 0
$failures = [System.Collections.Generic.List[object]]::new()
$seconds = @{}
$fileSeconds = [System.Collections.Generic.List[object]]::new()
foreach ($g in $procs) {
    if (-not (Test-Path $g.ResultFile)) {
        # A group that died without a result is a failure of every file in it,
        # never a silent pass.
        $err = (Get-Content (Join-Path $work "err-$($g.Index).txt") -Raw -ErrorAction SilentlyContinue)
        $failures.Add([pscustomobject]@{ name = "group $($g.Index + 1) ($($g.Files) files) ended without a result"; why = @(([string]$err).Trim() -split "`r?`n" | Select-Object -First 4) })
        $failed++
        continue
    }
    $r = Get-Content $g.ResultFile -Raw | ConvertFrom-Json
    $verdict = Measure-VmfGroupResult -Group $r -Label "group $($g.Index + 1) ($($g.Files) files)"
    $passed += $verdict.Passed; $failed += $verdict.Failed; $skipped += $verdict.Skipped
    foreach ($t in $verdict.Failures) { $failures.Add($t) }
    foreach ($s in @($r.seconds)) { $seconds[(Split-Path $s.file -Leaf)] = $s.s; $fileSeconds.Add($s) }
}

# Remember this run's times, so the next one balances its groups on them.
try { $merged = @{} + $known; foreach ($k in $seconds.Keys) { $merged[$k] = $seconds[$k] }; $merged | ConvertTo-Json | Set-Content $history -Encoding utf8 } catch { }
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# CI-SHARD-MEASURE-1: each file's seconds, one line each, for
# tools/Update-VmfTestTimings.ps1 to read from a CI log or a saved output. In
# a CI log the lines fold into one group, so they do not hide the result.
if ($ShowTimings -or $shardNote) {
    $timingRoot = if (Test-Path $TestPath -PathType Leaf) { Split-Path (Resolve-Path $TestPath).Path -Parent } else { (Resolve-Path $TestPath).Path }
    if ($env:GITHUB_ACTIONS) { Write-Host '::group::Seconds of each test file' }
    foreach ($s in @($fileSeconds | Sort-Object { [string]$_.file })) {
        $key = Get-VmfShardKey -Root $timingRoot -File ([string]$s.file)
        Write-Host ('vmf-test-seconds {0} {1}' -f ([double]$s.s).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture), $key)
    }
    if ($env:GITHUB_ACTIONS) { Write-Host '::endgroup::' }
}

$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds)
Write-Host ''
$colour = if ($failed) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed, {2} skipped ({3} groups, {4}s)" -f $passed, $failed, $skipped, $procs.Count, $elapsed) -ForegroundColor $colour
foreach ($t in $failures) {
    Write-Host ("  FAIL {0}" -f $t.name) -ForegroundColor Red
    foreach ($line in @($t.why)) { Write-Host ("       {0}" -f ([string]$line).Trim()) -ForegroundColor DarkRed }
}
if ($failed) { exit 1 }
# REVIEW-1: said, not left to the caller's last native exit code.
exit 0
