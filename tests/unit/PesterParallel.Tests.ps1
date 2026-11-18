#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CI-SPEED-3: the suite runs as groups of test files at once, and nothing a
# group finds may be lost on the way back.
#
# Pester 5 runs file after file on one core. On a Windows PC the suite used
# one of 16 threads while its set-up, per file, was most of the wall clock. The
# tool splits the files into groups, runs each in its own process, and adds the
# results up. What must hold: every failing test is reported with its message,
# a file that cannot even be read is a failure, and the exit code says so.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Invoke-VmfPesterParallel.ps1'

    # The splitter, lifted out of the tool without running the tool.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Split-VmfTestGroups' }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($fn.Extent.Text))

    function Global:NewSuite([hashtable]$Files) {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-par-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($name in $Files.Keys) { Set-Content (Join-Path $dir $name) $Files[$name] }
        $dir
    }
    function Global:RunTool([string]$Dir, [int]$Groups) {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:tool -TestPath $Dir -Groups $Groups 2>&1 | Out-String
        [pscustomobject]@{ Text = $out; Code = $LASTEXITCODE }
    }
}
AfterAll { Remove-Item 'function:\NewSuite', 'function:\RunTool' -ErrorAction SilentlyContinue }

Describe 'CI-SPEED-3: how the files are shared out' {

    It 'every file lands in exactly one group' {
        $w = @{}; 1..20 | ForEach-Object { $w["f$_"] = $_ }
        $groups = Split-VmfTestGroups -Weights $w -Count 4
        @($groups).Count | Should -Be 4
        $all = @($groups | ForEach-Object { $_ })
        $all.Count | Should -Be 20
        @($all | Sort-Object -Unique).Count | Should -Be 20
    }

    It 'the groups come out close in total weight' {
        $w = @{}; 1..20 | ForEach-Object { $w["f$_"] = $_ }
        $totals = @(Split-VmfTestGroups -Weights $w -Count 4 | ForEach-Object { ($_ | ForEach-Object { $w[$_] } | Measure-Object -Sum).Sum })
        (($totals | Measure-Object -Maximum).Maximum - ($totals | Measure-Object -Minimum).Minimum) | Should -BeLessOrEqual 2
    }

    It 'fewer files than groups gives no empty group' {
        $groups = Split-VmfTestGroups -Weights @{ a = 1; b = 2 } -Count 6
        @($groups).Count | Should -Be 2
    }
}

Describe 'CI-SPEED-3: nothing a group finds is lost' {

    It 'a suite that passes: the counts add up across groups, and the exit code is 0' {
        $dir = NewSuite @{
            'One.Tests.ps1' = "Describe 'one' { It 'a' { 1 | Should -Be 1 }; It 'b' { 2 | Should -Be 2 } }"
            'Two.Tests.ps1' = "Describe 'two' { It 'c' { 3 | Should -Be 3 } }"
            'Three.Tests.ps1' = "Describe 'three' { It 'd' { 4 | Should -Be 4 } }"
        }
        try {
            $r = RunTool $dir 2
            $r.Code | Should -Be 0
            $r.Text | Should -Match '4 passed, 0 failed'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a failing test and a file that cannot be read are both reported, with why, and the exit code is 1' {
        $dir = NewSuite @{
            'Good.Tests.ps1' = "Describe 'good' { It 'passes' { 1 | Should -Be 1 } }"
            'Bad.Tests.ps1' = "Describe 'bad' { It 'says one is two' { 1 | Should -Be 2 } }"
            'Broken.Tests.ps1' = "throw 'this file cannot be read'`nDescribe 'never' { It 'x' { } }"
        }
        try {
            $r = RunTool $dir 3
            $r.Code | Should -Be 1
            $r.Text | Should -Match '1 passed, 2 failed'
            $r.Text | Should -Match 'FAIL bad\.says one is two'
            $r.Text | Should -Match 'Expected 2, but got 1'
            $r.Text | Should -Match 'could not run: Broken\.Tests\.ps1'
            $r.Text | Should -Match 'this file cannot be read'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }
}

Describe 'REVIEW-1: a set-up or clean-up failure says why' {

    It 'a BeforeAll that throws prints its reason, not only its tests'' names' {
        $dir = NewSuite @{
            'Setup.Tests.ps1' = "Describe 'setup' { BeforeAll { throw 'the set-up broke here' }; It 'x' { 1 | Should -Be 1 } }"
        }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'the set-up broke here'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'an AfterAll that throws prints its reason, and does not call the file unread' {
        $dir = NewSuite @{
            'Teardown.Tests.ps1' = "Describe 'teardown' { It 'x' { 1 | Should -Be 1 }; AfterAll { throw 'the clean-up broke here' } }"
        }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'the clean-up broke here'
            $r.Text | Should -Not -Match 'could not run'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }
}
# TEST-AZURE-GUARD-1: A SECOND FLOOR, AT THE PROCESS. The Pester guard is the
# first; a gap in it on 2026-10-10 sent unit tests to Azure with the signed-in
# identity of the machine running them. So every test process the runner
# starts sends HTTP to a proxy address that cannot be connected to. MEASURED
# 2026-10-11 against a local listener standing in as the proxy: Az PowerShell's
# own traffic - the endpoint lookup, the token from Entra, the request itself -
# all asked the proxy. The person's saved Az context is never touched: no
# sign-out, nothing to put back.
Describe 'TEST-AZURE-GUARD-1: a test process cannot reach Azure, whatever the mocks do' {

    BeforeAll {
        $script:floorDir = NewSuite @{
            'Floor.Tests.ps1' = @'
Describe 'floor' {
    It 'floor: Azure Resource Manager goes to the dead proxy' {
        [System.Net.Http.HttpClient]::DefaultProxy.GetProxy([uri]'https://management.azure.com/').Authority | Should -Be '0.0.0.0:9'
    }
    It 'floor: the Entra sign-in goes to the dead proxy' {
        [System.Net.Http.HttpClient]::DefaultProxy.GetProxy([uri]'https://login.microsoftonline.com/').Authority | Should -Be '0.0.0.0:9'
    }
    It 'floor: a real request fails at the proxy and leaves the machine with nothing' {
        { Invoke-WebRequest -Uri 'https://example.invalid/' -TimeoutSec 5 } | Should -Throw '*0.0.0.0*'
    }
    It 'floor: a test that talks to its own machine still can' {
        [System.Net.Http.HttpClient]::DefaultProxy.IsBypassed([uri]'http://127.0.0.1:8080/') | Should -BeTrue
        [System.Net.Http.HttpClient]::DefaultProxy.IsBypassed([uri]'http://localhost:8080/') | Should -BeTrue
    }
}
'@
        }
        # The caller has its own proxy settings. They must not reach the tests,
        # and they must be exactly as they were after the run.
        $probe = @'
$env:HTTPS_PROXY = 'http://proxy.example.com:8080'
$env:NO_PROXY = '.example.com'
$env:HTTP_PROXY = $null
$env:ALL_PROXY = $null
$env:VMF_TEST_AZURE_GUARD = $null
& $args[0] -TestPath $args[1] -Groups 1 | Out-Null
'exit=' + $LASTEXITCODE
'HTTPS_PROXY=' + $env:HTTPS_PROXY
'NO_PROXY=' + $env:NO_PROXY
'HTTP_PROXY=' + [string]$env:HTTP_PROXY
'ALL_PROXY=' + [string]$env:ALL_PROXY
'VMF_TEST_AZURE_GUARD=' + [string]$env:VMF_TEST_AZURE_GUARD
'@
        $probeFile = Join-Path $script:floorDir 'probe.ps1'
        Set-Content $probeFile $probe
        $script:floorRun = & (Get-Process -Id $PID).Path -NoProfile -File $probeFile $script:tool $script:floorDir 2>&1 | Out-String
        $script:floorText = (RunTool $script:floorDir 1).Text
    }
    AfterAll { if ($script:floorDir) { Remove-Item $script:floorDir -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'every request to Azure from a test process goes to an address that cannot be connected to' {
        $script:floorText | Should -Match '4 passed, 0 failed' -Because $script:floorText
    }

    It 'the floor wins over a proxy the caller set, and the tests still ran' {
        $script:floorRun | Should -Match 'exit=0' -Because $script:floorRun
    }

    It 'and the caller''s own settings are exactly as they were afterwards' {
        $script:floorRun | Should -Match 'HTTPS_PROXY=http://proxy\.example\.com:8080'
        $script:floorRun | Should -Match 'NO_PROXY=\.example\.com'
        $script:floorRun | Should -Match '(?m)^HTTP_PROXY=\s*$'
        $script:floorRun | Should -Match '(?m)^ALL_PROXY=\s*$'
        # TEST-AZURE-GUARD-2: the worker guard's value is for test processes only.
        $script:floorRun | Should -Match '(?m)^VMF_TEST_AZURE_GUARD=\s*$'
    }

    It 'the local runner sends one file through the same processes, so the floor is there too' {
        $runner = Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Language PowerShell -Text $runner
        $code | Should -Not -Match 'Invoke-Pester\b' -Because 'a run in the caller''s own process has no floor'
    }
}

# SUITE-TEMP-1: every test process writes its scratch files under ONE folder,
# <temp>\vmf-tests, so a scanner can exclude test scratch with one narrow entry
# instead of a wildcard over the whole temp folder. The tests use more than 200
# folder names of their own; the runner points each group's temp folder there,
# so no test file changes, and a process a test starts inherits it.
Describe 'SUITE-TEMP-1: test scratch files go under one folder' {

    BeforeAll {
        $script:callerTemp = NewSuite @{}
        # Doubled for the single-quoted string it goes into, and put in by a
        # script block so a '$' in the path is not read as a group reference.
        $seen = $script:callerTemp -replace "'", "''"
        $body = @'
Describe 'where' {
    It 'records its temp folder and its child''s' {
        $mine = [System.IO.Path]::GetTempPath()
        $child = & (Get-Process -Id $PID).Path -NoProfile -Command '[System.IO.Path]::GetTempPath()'
        Set-Content (Join-Path '__SEEN_DIR__' ('seen-' + [guid]::NewGuid().ToString('N') + '.txt')) @($mine, $child)
        Test-Path $mine | Should -BeTrue
    }
}
'@ -creplace '__SEEN_DIR__', { $seen }
        $script:tempSuite = NewSuite @{ 'WhereA.Tests.ps1' = $body; 'WhereB.Tests.ps1' = $body }
        $probe = @'
$env:TEMP = $args[2]; $env:TMP = $args[2]; $env:TMPDIR = $args[2]
& $args[0] -TestPath $args[1] -Groups 2 | Out-Null
'exit=' + $LASTEXITCODE
'TEMP=' + $env:TEMP
'TMP=' + $env:TMP
'TMPDIR=' + $env:TMPDIR
'LEFT=' + @(Get-ChildItem (Join-Path $args[2] 'vmf-tests') -Force -ErrorAction SilentlyContinue).Count
'@
        $probeFile = Join-Path $script:callerTemp 'probe.ps1'
        Set-Content $probeFile $probe
        $script:tempRun = & (Get-Process -Id $PID).Path -NoProfile -File $probeFile $script:tool $script:tempSuite $script:callerTemp 2>&1 | Out-String
        $script:seenFiles = @(Get-ChildItem $script:callerTemp -Filter 'seen-*.txt')
        $script:scratchRoot = [System.IO.Path]::GetFullPath((Join-Path $script:callerTemp 'vmf-tests')) + [System.IO.Path]::DirectorySeparatorChar
    }
    AfterAll {
        foreach ($dir in $script:callerTemp, $script:tempSuite) { if ($dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'both groups ran and passed' {
        $script:tempRun | Should -Match 'exit=0' -Because $script:tempRun
        $script:seenFiles.Count | Should -Be 2 -Because $script:tempRun
    }

    It 'each test process has its temp folder under <temp>\vmf-tests' {
        $script:seenFiles.Count | Should -Be 2
        foreach ($file in $script:seenFiles) {
            $mine = (Get-Content $file.FullName)[0]
            $mine.StartsWith($script:scratchRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue -Because "'$mine' is not under '$($script:scratchRoot)'"
        }
    }

    It 'a process a test starts inherits the same temp folder' {
        $script:seenFiles.Count | Should -Be 2
        foreach ($file in $script:seenFiles) {
            $lines = @(Get-Content $file.FullName)
            $lines[1] | Should -Be $lines[0]
        }
    }

    It 'each group has its own temp folder' {
        $folders = @($script:seenFiles | ForEach-Object { (Get-Content $_.FullName)[0] } | Sort-Object -Unique)
        $folders.Count | Should -Be 2
    }

    It 'the run removes its scratch files, and the caller''s temp settings are as they were' {
        $script:tempRun | Should -Match '(?m)^LEFT=0\s*$' -Because $script:tempRun
        $expected = [regex]::Escape($script:callerTemp)
        $script:tempRun | Should -Match "(?m)^TEMP=$expected\s*$"
        $script:tempRun | Should -Match "(?m)^TMP=$expected\s*$"
        $script:tempRun | Should -Match "(?m)^TMPDIR=$expected\s*$"
    }
}

# SUITE-TEMP-1: a run that was killed leaves its folder. The next run removes
# one older than a day - and never one that is newer, which may belong to a
# suite running now in another worktree - and nothing outside vmf-tests.
Describe 'SUITE-TEMP-1: a run removes only day-old run folders' {

    BeforeAll {
        $script:oldTemp = NewSuite @{}
        $root = Join-Path $script:oldTemp 'vmf-tests'
        foreach ($name in 'run-old', 'run-new', 'keep-old') { New-Item -ItemType Directory -Path (Join-Path $root $name) -Force | Out-Null }
        (Get-Item (Join-Path $root 'run-old')).LastWriteTime = (Get-Date).AddDays(-2)
        (Get-Item (Join-Path $root 'keep-old')).LastWriteTime = (Get-Date).AddDays(-2)
        $outside = Join-Path $script:oldTemp 'run-outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        (Get-Item $outside).LastWriteTime = (Get-Date).AddDays(-2)
        $script:oldSuite = NewSuite @{ 'Tiny.Tests.ps1' = "Describe 'tiny' { It 'a' { 1 | Should -Be 1 } }" }
        $probe = @'
$env:TEMP = $args[2]; $env:TMP = $args[2]; $env:TMPDIR = $args[2]
& $args[0] -TestPath $args[1] -Groups 1 | Out-Null
'exit=' + $LASTEXITCODE
'@
        $probeFile = Join-Path $script:oldTemp 'probe.ps1'
        Set-Content $probeFile $probe
        $script:oldRun = & (Get-Process -Id $PID).Path -NoProfile -File $probeFile $script:tool $script:oldSuite $script:oldTemp 2>&1 | Out-String
        $script:oldRoot = $root
    }
    AfterAll {
        foreach ($dir in $script:oldTemp, $script:oldSuite) { if ($dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'the run passed' {
        $script:oldRun | Should -Match 'exit=0' -Because $script:oldRun
    }

    It 'a run folder older than a day is removed' {
        Test-Path (Join-Path $script:oldRoot 'run-old') | Should -BeFalse
    }

    It 'a newer run folder stays' {
        Test-Path (Join-Path $script:oldRoot 'run-new') | Should -BeTrue
    }

    It 'an old folder that is not a run folder stays, and so does an old run folder outside vmf-tests' {
        Test-Path (Join-Path $script:oldRoot 'keep-old') | Should -BeTrue
        Test-Path (Join-Path $script:oldTemp 'run-outside') | Should -BeTrue
    }
}

# CI-SHARD-1: CI runs the unit tests as several jobs, one share of the files
# each, on as many runners as there are. Each job computes the whole split for
# itself and runs its own share, so every job of one commit MUST compute the
# same split - or a file runs twice, or not at all, and the run is green.
#
# That rules out the timing history this tool balances its groups on: it is
# kept in each machine's temp folder, so two runners hold two histories and
# would make two splits. The share is decided by the file's size with carriage
# returns not counted (so a checkout with CRLF line endings weighs the same as
# one with LF), its path from the test folder with forward slashes, and an
# ordinal name order for every tie - all the same on every runner.
Describe 'CI-SHARD-1: every file runs in exactly one share, on every runner' {

    BeforeAll {
        $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
        foreach ($name in 'Split-VmfTestShards', 'Get-VmfShardWeight', 'Get-VmfShardKey', 'Get-VmfSplitId') {
            $def = $toolAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name }, $true) | Select-Object -First 1
            $def | Should -Not -BeNullOrEmpty -Because "the tool defines $name"
            . ([scriptblock]::Create($def.Extent.Text))
        }
        $script:unitDir = Join-Path $script:repoRoot 'tests' 'unit'
        $script:unitWeights = @{}
        foreach ($file in Get-ChildItem $script:unitDir -Filter '*.Tests.ps1' -Recurse) {
            $script:unitWeights[(Get-VmfShardKey -Root $script:unitDir -File $file.FullName)] = Get-VmfShardWeight -Path $file.FullName
        }
    }

    It 'the real suite: every test file is in exactly one of <Count> shares, and none is missing' -ForEach @(@{ Count = 2 }, @{ Count = 3 }, @{ Count = 4 }) {
        $shards = Split-VmfTestShards -Weights $script:unitWeights -Count $Count
        $shards.Count | Should -Be $Count
        $all = @($shards | ForEach-Object { $_ })
        $all.Count | Should -Be $script:unitWeights.Count
        @($all | Sort-Object -Unique).Count | Should -Be $script:unitWeights.Count
        foreach ($key in $script:unitWeights.Keys) { $all | Should -Contain $key }
        foreach ($s in $shards) { @($s).Count | Should -BeGreaterThan 0 }
    }

    It 'the real suite: the shares differ in weight by no more than the heaviest file' {
        $shards = Split-VmfTestShards -Weights $script:unitWeights -Count 3
        $totals = @($shards | ForEach-Object { ($_ | ForEach-Object { $script:unitWeights[$_] } | Measure-Object -Sum).Sum })
        $totals.Count | Should -Be 3
        $heaviest = ($script:unitWeights.Values | Measure-Object -Maximum).Maximum
        (($totals | Measure-Object -Maximum).Maximum - ($totals | Measure-Object -Minimum).Minimum) | Should -BeLessOrEqual $heaviest
    }

    It 'files of equal weight give the same shares, whatever order they were added in' {
        $names = 1..12 | ForEach-Object { "F$_.Tests.ps1" }
        $forward = @{}; foreach ($n in $names) { $forward[$n] = 100 }
        $backward = @{}; foreach ($n in ($names | Sort-Object -Descending)) { $backward[$n] = 100 }
        $a = Split-VmfTestShards -Weights $forward -Count 3
        $b = Split-VmfTestShards -Weights $backward -Count 3
        (Get-VmfSplitId -Shards $a) | Should -Be (Get-VmfSplitId -Shards $b)
        for ($i = 0; $i -lt 3; $i++) { (@($a[$i]) -join ',') | Should -Be (@($b[$i]) -join ',') }
    }

    It 'names compare by their characters, not by the machine''s language settings' {
        # An ordinal order puts 'B' before 'a'; a culture order does not.
        $a = Split-VmfTestShards -Weights @{ 'a.Tests.ps1' = 5; 'B.Tests.ps1' = 5 } -Count 1
        @($a[0]) -join ',' | Should -Be 'B.Tests.ps1,a.Tests.ps1'
        # And a tie in weight goes by that same order, which decides the share.
        $b = Split-VmfTestShards -Weights @{ 'a.Tests.ps1' = 5; 'B.Tests.ps1' = 5; 'c.Tests.ps1' = 5 } -Count 2
        @($b[0]) -join ',' | Should -Be 'B.Tests.ps1,c.Tests.ps1'
        @($b[1]) -join ',' | Should -Be 'a.Tests.ps1'
    }

    It 'a file checked out with CRLF line endings weighs the same as with LF' {
        $dir = NewSuite @{}
        try {
            $lf = Join-Path $dir 'lf.txt'; $crlf = Join-Path $dir 'crlf.txt'
            [System.IO.File]::WriteAllText($lf, "one`ntwo`nthree`n")
            [System.IO.File]::WriteAllText($crlf, "one`r`ntwo`r`nthree`r`n")
            Get-VmfShardWeight -Path $crlf | Should -Be (Get-VmfShardWeight -Path $lf)
            Get-VmfShardWeight -Path $lf | Should -Be 14
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a file''s key is its path from the test folder, with forward slashes' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'suite-root'
        Get-VmfShardKey -Root $root -File (Join-Path $root 'sub' 'X.Tests.ps1') | Should -Be 'sub/X.Tests.ps1'
        Get-VmfShardKey -Root $root -File (Join-Path $root 'Y.Tests.ps1') | Should -Be 'Y.Tests.ps1'
    }
}

# The same promise end to end: three runs of the tool, one per share, each
# with a DIFFERENT timing history in its temp folder - as three runners have -
# and one test file added since any history was written. Each test file writes
# a line when it runs, so a file that ran twice or never shows.
Describe 'CI-SHARD-1: three shares on three machines run each file once' {

    BeforeAll {
        $script:shardMarks = NewSuite @{}
        $marks = $script:shardMarks -replace "'", "''"
        $files = @{}
        # Sizes differ, so the split by size is not the split by name.
        $sizes = @{ Alpha = 1; Bravo = 9; Charlie = 3; Delta = 7; Echo = 2; Foxtrot = 6; Golf = 4; Hotel = 8; NewOne = 5 }
        foreach ($name in $sizes.Keys) {
            $pad = '#' + ('x' * (200 * $sizes[$name]))
            $files["$name.Tests.ps1"] = ("$pad`nDescribe '$name' { It 'runs' { Add-Content (Join-Path '__MARKS__' '$name.ran') 'ran' } }" -creplace '__MARKS__', { $marks })
        }
        $script:shardSuite = NewSuite $files
        # Three histories that disagree with the sizes and with each other. A
        # split balanced on them would differ between the three runs. NewOne
        # is in none of them: it was added after the last run.
        $histories = @(
            @{ 'Alpha.Tests.ps1' = 90; 'Bravo.Tests.ps1' = 1; 'Charlie.Tests.ps1' = 70; 'Delta.Tests.ps1' = 2; 'Echo.Tests.ps1' = 80; 'Foxtrot.Tests.ps1' = 3; 'Golf.Tests.ps1' = 60; 'Hotel.Tests.ps1' = 4 }
            @{ 'Alpha.Tests.ps1' = 5; 'Bravo.Tests.ps1' = 50; 'Charlie.Tests.ps1' = 5; 'Delta.Tests.ps1' = 50; 'Echo.Tests.ps1' = 5; 'Foxtrot.Tests.ps1' = 50; 'Golf.Tests.ps1' = 5; 'Hotel.Tests.ps1' = 50 }
            @{}
        )
        $probe = @'
$env:TEMP = $args[2]; $env:TMP = $args[2]; $env:TMPDIR = $args[2]
& $args[0] -TestPath $args[1] -Groups 1 -Shard $args[3] -ShardCount 3
'exit=' + $LASTEXITCODE
'@
        $script:shardRuns = @()
        for ($i = 0; $i -lt 3; $i++) {
            $temp = NewSuite @{}
            if ($histories[$i].Count) { $histories[$i] | ConvertTo-Json | Set-Content (Join-Path $temp 'vmf-test-seconds.json') }
            $probeFile = Join-Path $temp 'probe.ps1'
            Set-Content $probeFile $probe
            $script:shardRuns += (& (Get-Process -Id $PID).Path -NoProfile -File $probeFile $script:tool $script:shardSuite $temp ($i + 1) 2>&1 | Out-String)
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:shardNames = @($sizes.Keys)
    }
    AfterAll {
        foreach ($dir in $script:shardMarks, $script:shardSuite) { if ($dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'each share ran and passed' {
        foreach ($run in $script:shardRuns) { $run | Should -Match 'exit=0' -Because $run }
    }

    It 'every test file ran exactly once across the three shares, the new file too' {
        foreach ($name in $script:shardNames) {
            $mark = Join-Path $script:shardMarks "$name.ran"
            Test-Path $mark | Should -BeTrue -Because "$name ran in no share: $($script:shardRuns -join ' | ')"
            @(Get-Content $mark).Count | Should -Be 1 -Because "$name ran in more than one share"
        }
    }

    It 'each share says which share it is, and all three name the same split' {
        $ids = for ($i = 0; $i -lt 3; $i++) {
            $script:shardRuns[$i] | Should -Match "shard $($i + 1) of 3"
            [regex]::Match($script:shardRuns[$i], 'split ([0-9a-f]{12})').Groups[1].Value
        }
        $ids[0] | Should -Not -BeNullOrEmpty
        @($ids | Sort-Object -Unique).Count | Should -Be 1
    }
}

Describe 'CI-SHARD-1: a share that cannot run fails' {

    BeforeAll {
        $script:smallSuite = NewSuite @{
            'One.Tests.ps1' = "Describe 'one' { It 'a' { 1 | Should -Be 1 } }"
            'Two.Tests.ps1' = "Describe 'two' { It 'b' { 1 | Should -Be 1 } }"
        }
    }
    AfterAll { if ($script:smallSuite) { Remove-Item $script:smallSuite -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'a share with no files fails and says so, rather than passing with nothing run' {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:tool -TestPath $script:smallSuite -Shard 3 -ShardCount 3 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'Shard 3 of 3 has no test files'
    }

    It 'a share number past the count fails' {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:tool -TestPath $script:smallSuite -Shard 3 -ShardCount 2 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'Give -Shard from 1 to 2\.'
    }

    It 'a share number with no count fails' {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:tool -TestPath $script:smallSuite -Shard 1 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'Give -ShardCount with -Shard\.'
    }

    It 'the local runner passes a share through, to run one CI job''s files' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw)
        $code | Should -Match '\[int\]\$Shard\b'
        $code | Should -Match '\[int\]\$ShardCount\b'
        $code | Should -Match 'Invoke-VmfPesterParallel\.ps1[^\r\n]*@shardArgs'
    }
}

# TEST-DISCOVERY-DROP-1: A FILE THAT THROWS WHILE PESTER READS IT IS A FAILURE.
# MEASURED on Pester 5.7.1, 2026-10-24: a Describe whose body throws part way
# through discovery - two It blocks joined on one line, so the first It gets
# the second as an extra argument - runs the tests found before the throw. The
# run's Result is Failed and FailedContainersCount is 1, but the CONTAINER's
# Result is Passed, its FailedCount is 0, and the error sits only in its
# ErrorRecord. The tool looked for a Failed container or a failed test, found
# neither, and printed "N passed, 0 failed" with exit code 0: tests vanished,
# locally and in CI. The fixtures are written to a temp folder at test time, so
# the suite itself never discovers them.
Describe 'TEST-DISCOVERY-DROP-1: a file that throws while Pester reads it fails the run' {

    BeforeAll {
        $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
        foreach ($name in 'ConvertTo-VmfGroupResult', 'Measure-VmfGroupResult', 'Get-VmfFirstLines') {
            $def = $toolAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name }, $true) | Select-Object -First 1
            $def | Should -Not -BeNullOrEmpty -Because "the tool defines $name"
            . ([scriptblock]::Create($def.Extent.Text))
        }
        # The defect exactly as RESTORE-END-JOB-1 met it: one It ends and the
        # next starts on the same line. The file parses.
        $script:joinedIt = @'
Describe 'joined' {
    It 'one' { 1 | Should -Be 1 }
    It 'two' { 1 | Should -Be 1 }    It 'three' { 1 | Should -Be 1 }
    It 'four' { 1 | Should -Be 1 }
}
'@
        # A stand-in for what Invoke-Pester returns: only the properties the
        # tool reads.
        function Global:FakeRun {
            param([string]$Result = 'Passed', [int]$FailedContainers = 0, [object[]]$Containers = @(), [int]$Passed = 0)
            [pscustomobject]@{
                Result = $Result; FailedContainersCount = $FailedContainers
                PassedCount = $Passed; FailedCount = 0; SkippedCount = 0
                Failed = @(); FailedBlocks = @(); Containers = $Containers
            }
        }
        function Global:FakeContainer {
            param([string]$Item, [string]$Result, [int]$Passed = 0, [int]$Failed = 0, [string[]]$Errors = @())
            [pscustomobject]@{
                Item = $Item; Result = $Result; PassedCount = $Passed; FailedCount = $Failed
                ErrorRecord = @($Errors | ForEach-Object { [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($_), 'x', 'NotSpecified', $null) })
                Duration = [timespan]::Zero; DiscoveryDuration = [timespan]::Zero
            }
        }
        # Through JSON, as the parent reads a group's result file.
        function Global:RoundTrip($Out) { $Out | ConvertTo-Json -Depth 6 | ConvertFrom-Json }
    }
    AfterAll { Remove-Item 'function:\FakeRun', 'function:\FakeContainer', 'function:\RoundTrip' -ErrorAction SilentlyContinue }

    It 'two It blocks on one line: the run fails, and names the file and the error' {
        $dir = NewSuite @{ 'Joined.Tests.ps1' = $script:joinedIt }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'some tests did not run, Pester stopped while it read Joined\.Tests\.ps1' -Because $r.Text
            $r.Text | Should -Match "A positional parameter cannot be found that accepts argument 'It'" -Because $r.Text
            $r.Text | Should -Match '1 passed, 1 failed' -Because $r.Text
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'and beside a file that passes, in the same group, the run still fails' {
        $dir = NewSuite @{
            'Joined.Tests.ps1' = $script:joinedIt
            'Fine.Tests.ps1'   = "Describe 'fine' { It 'a' { 1 | Should -Be 1 }; It 'b' { 1 | Should -Be 1 } }"
        }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'Joined\.Tests\.ps1' -Because $r.Text
            $r.Text | Should -Not -Match 'Fine\.Tests\.ps1' -Because 'the file that passed is not a failure'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a Describe that throws before any test is found: the run fails, and names the file and the error' {
        $dir = NewSuite @{ 'NoTests.Tests.ps1' = "Describe 'none' { throw 'discovery broke here'; It 'x' { 1 | Should -Be 1 } }" }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'could not run: NoTests\.Tests\.ps1' -Because $r.Text
            $r.Text | Should -Match 'discovery broke here' -Because $r.Text
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a BeforeAll at the top of the file that throws: the run fails, and says why' {
        $dir = NewSuite @{ 'TopSetup.Tests.ps1' = "BeforeAll { throw 'the file set-up broke' }`nDescribe 'top' { It 'x' { 1 | Should -Be 1 } }" }
        try {
            $r = RunTool $dir 1
            $r.Code | Should -Be 1 -Because $r.Text
            $r.Text | Should -Match 'TopSetup\.Tests\.ps1' -Because $r.Text
            $r.Text | Should -Match 'the file set-up broke' -Because $r.Text
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a container with an error and no test counted, whose Result is Passed, is a failure with its file and error' {
        $run = FakeRun -Result 'Failed' -FailedContainers 1 -Containers @(
            FakeContainer -Item 'C:\t\Odd.Tests.ps1' -Result 'Passed' -Errors @("first line of why`nsecond line")
        )
        $out = ConvertTo-VmfGroupResult -Result $run
        @($out.files).Count | Should -Be 1
        $out.files[0].name | Should -Be 'C:\t\Odd.Tests.ps1'
        $out.files[0].why[0] | Should -Be 'first line of why'
        $m = Measure-VmfGroupResult -Group (RoundTrip $out) -Label 'group 1'
        $m.Failed | Should -Be 1
        ($m.Failures | ForEach-Object name) -join '|' | Should -Match 'Odd\.Tests\.ps1'
    }

    It 'a container that passed with no error is not a failure' {
        $run = FakeRun -Result 'Passed' -Passed 2 -Containers @(FakeContainer -Item 'C:\t\Good.Tests.ps1' -Result 'Passed' -Passed 2)
        $m = Measure-VmfGroupResult -Group (RoundTrip (ConvertTo-VmfGroupResult -Result $run)) -Label 'group 1'
        $m.Failed | Should -Be 0
        @($m.Failures).Count | Should -Be 0
        $m.Passed | Should -Be 2
    }

    It 'the group result keeps the run''s own Result and failed container count' {
        $out = ConvertTo-VmfGroupResult -Result (FakeRun -Result 'Failed' -FailedContainers 3)
        $out.run.result | Should -Be 'Failed'
        $out.run.failedContainers | Should -Be 3
    }

    It 'a run whose Result is Failed with no failed test, file or block is still a failure' {
        $m = Measure-VmfGroupResult -Group (RoundTrip (ConvertTo-VmfGroupResult -Result (FakeRun -Result 'Failed'))) -Label 'group 2 (5 files)'
        $m.Failed | Should -Be 1
        $m.Failures[0].name | Should -Match 'group 2 \(5 files\)'
        $m.Failures[0].name | Should -Match 'Pester gave the result Failed'
    }

    It 'a run with a failed container and no failed test, file or block is still a failure' {
        $m = Measure-VmfGroupResult -Group (RoundTrip (ConvertTo-VmfGroupResult -Result (FakeRun -Result 'Passed' -FailedContainers 1))) -Label 'group 1'
        $m.Failed | Should -Be 1
        $m.Failures[0].name | Should -Match '1 failed container'
    }

    It 'a group result with no run record is a failure, never a pass' {
        $m = Measure-VmfGroupResult -Group ([pscustomobject]@{ passed = 3; failed = 0; skipped = 0 }) -Label 'group 1'
        $m.Failed | Should -Be 1
        $m.Failures[0].name | Should -Match 'no run record'
    }

    It 'the first lines of an error, blank lines left out, at most four' {
        @(Get-VmfFirstLines "`none`n`ntwo`r`nthree`nfour`nfive") -join '|' | Should -Be 'one|two|three|four'
    }
}

Describe 'CI-SPEED-3: CI and the local runner use it' {

    # PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its
    # own runners (set up by tools/Initialize-VmfCiRunner.ps1). Neither ships;
    # the public workflows are different files, so there this is skipped.
    It 'the CI Pester step runs the suite through the tool, on the pinned version' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $step = [regex]::Match($ci, "(?s)- name: Pester unit tests\s*\n(.*?)(?=\n\s*- name: |\n  [a-z-]+:\s*\n|\z)").Groups[1].Value
        $step | Should -Match 'Invoke-VmfPesterParallel\.ps1'
        $pinnedPester = ((Get-Content (Join-Path $script:repoRoot 'infra' 'part-versions.json') -Raw | ConvertFrom-Json).parts | Where-Object key -eq 'psgallery:Pester').version
        $pinnedPester | Should -Match '^\d+\.\d+\.\d+$'
        $step | Should -Match "PesterVersion '$([regex]::Escape($pinnedPester))'"
    }

    It 'SUITE-SPEED-1: every Pester run the tools start has TestRegistry off, and no test uses it' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        foreach ($t in 'Invoke-VmfPesterParallel.ps1', 'Invoke-VmfMutationSweep.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' $t)
            $code | Should -Match '\.TestRegistry\.Enabled\s*=\s*\$false' -Because "$t must not make a registry key per test file"
            $code | Should -Not -Match 'Invoke-Pester\s+-Path' -Because "$t must pass a configuration, so the setting applies"
        }
        $uses = @(Get-ChildItem (Join-Path $script:repoRoot 'tests') -Recurse -Filter '*.ps1' |
            Where-Object { $_.Name -ne 'PesterParallel.Tests.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'TestRegistry' })
        $uses.Count | Should -Be 0 -Because 'a test that needs TestRegistry must turn it on itself, and none does'
    }

    It 'the local runner uses it for a folder' {
        $runner = Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw
        $runner | Should -Match 'Invoke-VmfPesterParallel\.ps1'
    }
}
