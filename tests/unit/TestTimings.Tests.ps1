#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CI-SHARD-MEASURE-1: CI's shares are balanced on the MEASURED seconds of each
# test file, kept in tests/test-timings.json, not on the file's size.
#
# Measured on the pool runners (main run 39158910940): split by size, the three
# shares took 548, 417 and 332 seconds of Pester. What must hold:
#   - the split comes from the commit's files only, the same on every runner;
#   - every file is in exactly one share, a file with no time too;
#   - the shares' totals differ by no more than the longest file;
#   - the timings file can be written again from Pester's own output.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Invoke-VmfPesterParallel.ps1'
    $script:updater = Join-Path $script:repoRoot 'tools' 'Update-VmfTestTimings.ps1'
    $script:timings = Join-Path $script:repoRoot 'tests' 'test-timings.json'

    $toolAst = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
    foreach ($name in 'Read-VmfTestTimings', 'Get-VmfShardWeights', 'Split-VmfTestShards', 'Get-VmfShardWeight', 'Get-VmfShardKey', 'Get-VmfSplitId') {
        $def = $toolAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name }, $true) | Select-Object -First 1
        $def | Should -Not -BeNullOrEmpty -Because "the tool defines $name"
        . ([scriptblock]::Create($def.Extent.Text))
    }
    $updaterAst = [System.Management.Automation.Language.Parser]::ParseFile($script:updater, [ref]$null, [ref]$null)
    foreach ($name in 'Get-VmfTimingLines', 'Merge-VmfTestTimings') {
        $def = $updaterAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name }, $true) | Select-Object -First 1
        $def | Should -Not -BeNullOrEmpty -Because "the updater defines $name"
        . ([scriptblock]::Create($def.Extent.Text))
    }

    function Global:New-TimingSandbox {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-timing-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $dir
    }
    function Global:Write-TimingFile([string]$Path, [hashtable]$Seconds) {
        $o = [ordered]@{ seconds = $Seconds }
        [System.IO.File]::WriteAllText($Path, ($o | ConvertTo-Json -Depth 3))
    }

    # The real suite, as CI splits it.
    $script:unitDir = Join-Path $script:repoRoot 'tests' 'unit'
    $script:unitSizes = @{}
    foreach ($file in Get-ChildItem $script:unitDir -Filter '*.Tests.ps1' -Recurse) {
        $script:unitSizes[(Get-VmfShardKey -Root $script:unitDir -File $file.FullName)] = Get-VmfShardWeight -Path $file.FullName
    }
}
AfterAll { Remove-Item 'function:\New-TimingSandbox', 'function:\Write-TimingFile' -ErrorAction SilentlyContinue }

Describe 'CI-SHARD-MEASURE-1: the weight of each file is its measured time' {

    It 'a measured file weighs its time in whole milliseconds' {
        $dir = New-TimingSandbox
        try {
            $file = Join-Path $dir 't.json'
            Write-TimingFile $file @{ 'A.Tests.ps1' = 12.5; 'B.Tests.ps1' = 0.25 }
            $ms = Read-VmfTestTimings -Path $file
            $ms['A.Tests.ps1'] | Should -Be 12500
            $ms['B.Tests.ps1'] | Should -Be 250
            $ms['A.Tests.ps1'] | Should -BeOfType [long]
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'no timings file: no times, and the split is by size as before' {
        (Read-VmfTestTimings -Path (Join-Path ([System.IO.Path]::GetTempPath()) "no-such-$([guid]::NewGuid().ToString('N')).json")).Count | Should -Be 0
        $w = Get-VmfShardWeights -Sizes @{ 'A.Tests.ps1' = 700; 'B.Tests.ps1' = 300 } -Measured @{}
        $w['A.Tests.ps1'] | Should -Be 700
        $w['B.Tests.ps1'] | Should -Be 300
    }

    It 'a timings file that names no file of this run: the split is by size' {
        $w = Get-VmfShardWeights -Sizes @{ 'A.Tests.ps1' = 700; 'B.Tests.ps1' = 300 } -Measured @{ 'Other.Tests.ps1' = 5000 }
        $w['A.Tests.ps1'] | Should -Be 700
        $w['B.Tests.ps1'] | Should -Be 300
    }

    It 'a timings file that cannot be read stops the run, the same on every share' {
        $dir = New-TimingSandbox
        try {
            $file = Join-Path $dir 't.json'
            [System.IO.File]::WriteAllText($file, '{ "about": "no seconds here" }')
            { Read-VmfTestTimings -Path $file } | Should -Throw "*no 'seconds'*"
            Write-TimingFile $file @{ 'A.Tests.ps1' = -1 }
            { Read-VmfTestTimings -Path $file } | Should -Throw '*below zero*'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'a file with no time weighs the median of the measured files (odd count)' {
        $sizes = @{ 'A.Tests.ps1' = 1; 'B.Tests.ps1' = 1; 'C.Tests.ps1' = 1; 'New.Tests.ps1' = 999999 }
        $w = Get-VmfShardWeights -Sizes $sizes -Measured @{ 'A.Tests.ps1' = 1000; 'B.Tests.ps1' = 9000; 'C.Tests.ps1' = 4000 }
        $w['New.Tests.ps1'] | Should -Be 4000 -Because 'the median, not the size'
        $w['B.Tests.ps1'] | Should -Be 9000
    }

    It 'a file with no time weighs the lower middle value when the count is even' {
        $sizes = @{ 'A.Tests.ps1' = 1; 'B.Tests.ps1' = 1; 'C.Tests.ps1' = 1; 'D.Tests.ps1' = 1; 'New.Tests.ps1' = 1 }
        $w = Get-VmfShardWeights -Sizes $sizes -Measured @{ 'A.Tests.ps1' = 1000; 'B.Tests.ps1' = 2000; 'C.Tests.ps1' = 8000; 'D.Tests.ps1' = 9000 }
        $w['New.Tests.ps1'] | Should -Be 2000
    }

    It 'the median counts only the files of this run' {
        $w = Get-VmfShardWeights -Sizes @{ 'A.Tests.ps1' = 1; 'New.Tests.ps1' = 1 } -Measured @{ 'A.Tests.ps1' = 3000; 'Gone1.Tests.ps1' = 1; 'Gone2.Tests.ps1' = 1 }
        $w['New.Tests.ps1'] | Should -Be 3000
    }
}

Describe 'CI-SHARD-MEASURE-1: the split of the real suite on the committed times' {

    BeforeAll {
        $script:measured = Read-VmfTestTimings -Path $script:timings
        $script:unitWeights = Get-VmfShardWeights -Sizes $script:unitSizes -Measured $script:measured
    }

    It 'the committed timings file names test files, each with a time of zero or more' {
        $script:measured.Count | Should -BeGreaterThan 100
        $data = Get-Content $script:timings -Raw | ConvertFrom-Json
        $names = @($data.seconds.PSObject.Properties.Name)
        foreach ($n in $names) { $n | Should -Match '^[^\\]+\.Tests\.ps1$' }
        $sorted = [string[]]$names.Clone(); [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        ($names -join ',') | Should -Be ($sorted -join ',') -Because 'the tool writes the names in ordinal order'
    }

    It 'the split uses the times: most files of the suite have one' {
        $timed = @($script:unitSizes.Keys | Where-Object { $script:measured.ContainsKey($_) }).Count
        $timed | Should -BeGreaterThan ($script:unitSizes.Count / 2)
    }

    It 'every test file is in exactly one of <Count> shares, a file with no time too' -ForEach @(@{ Count = 2 }, @{ Count = 3 }, @{ Count = 4 }) {
        # A file the timings do not know, as a file added after the last measurement.
        $weights = Get-VmfShardWeights -Sizes (@{ 'Added-Since.Tests.ps1' = 10 } + $script:unitSizes) -Measured $script:measured
        $shards = Split-VmfTestShards -Weights $weights -Count $Count
        $shards.Count | Should -Be $Count
        $all = @($shards | ForEach-Object { $_ })
        $all.Count | Should -Be $weights.Count
        @($all | Sort-Object -Unique).Count | Should -Be $weights.Count
        $all | Should -Contain 'Added-Since.Tests.ps1'
        foreach ($s in $shards) { @($s).Count | Should -BeGreaterThan 0 }
    }

    It 'the three shares'' times differ by no more than the longest file' {
        $shards = Split-VmfTestShards -Weights $script:unitWeights -Count 3
        $totals = @($shards | ForEach-Object { ($_ | ForEach-Object { $script:unitWeights[$_] } | Measure-Object -Sum).Sum })
        $longest = ($script:unitWeights.Values | Measure-Object -Maximum).Maximum
        (($totals | Measure-Object -Maximum).Maximum - ($totals | Measure-Object -Minimum).Minimum) | Should -BeLessOrEqual $longest
    }

    It 'the split is the same whatever order the times were read in' {
        $keys = [string[]]@($script:unitWeights.Keys); [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $forward = @{}; foreach ($k in $keys) { $forward[$k] = $script:unitWeights[$k] }
        [Array]::Reverse($keys)
        $backward = @{}; foreach ($k in $keys) { $backward[$k] = $script:unitWeights[$k] }
        (Get-VmfSplitId -Shards (Split-VmfTestShards -Weights $forward -Count 3)) | Should -Be (Get-VmfSplitId -Shards (Split-VmfTestShards -Weights $backward -Count 3))
    }
}

# End to end: three share runs, each with its own temp folder (as three runners
# have), on a timings file that disagrees with the sizes. Each file writes a
# mark when it runs.
Describe 'CI-SHARD-MEASURE-1: three share runs split by the times, and each file runs once' {

    BeforeAll {
        $script:marks = New-TimingSandbox
        $marks = $script:marks -replace "'", "''"
        $script:suite = New-TimingSandbox
        # Big is the largest file but quick; Slow is small and slow.
        $sizes = @{ Big = 30; Slow = 1; Mid1 = 5; Mid2 = 5; Mid3 = 5; Added = 2 }
        foreach ($name in $sizes.Keys) {
            $pad = '#' + ('x' * (200 * $sizes[$name]))
            Set-Content (Join-Path $script:suite "$name.Tests.ps1") ("$pad`nDescribe '$name' { It 'runs' { Add-Content (Join-Path '__MARKS__' '$name.ran') 'ran' } }" -creplace '__MARKS__', { $marks })
        }
        $script:timingFile = Join-Path $script:marks 'timings.json'
        # Added has no time: it was added after the last measurement.
        Write-TimingFile $script:timingFile @{ 'Big.Tests.ps1' = 1; 'Slow.Tests.ps1' = 90; 'Mid1.Tests.ps1' = 30; 'Mid2.Tests.ps1' = 30; 'Mid3.Tests.ps1' = 30 }
        $probe = @'
$env:TEMP = $args[2]; $env:TMP = $args[2]; $env:TMPDIR = $args[2]
& $args[0] -TestPath $args[1] -Groups 1 -Shard $args[3] -ShardCount 3 -TimingsFile $args[4]
'exit=' + $LASTEXITCODE
'@
        $script:runs = @()
        for ($i = 0; $i -lt 3; $i++) {
            $temp = New-TimingSandbox
            $probeFile = Join-Path $temp 'probe.ps1'
            Set-Content $probeFile $probe
            $script:runs += (& (Get-Process -Id $PID).Path -NoProfile -File $probeFile $script:tool $script:suite $temp ($i + 1) $script:timingFile 2>&1 | Out-String)
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:names = @($sizes.Keys)
    }
    AfterAll { foreach ($dir in $script:marks, $script:suite) { if ($dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } } }

    It 'each share ran and passed' {
        foreach ($run in $script:runs) { $run | Should -Match 'exit=0' -Because $run }
    }

    It 'every file ran exactly once, the file with no time too' {
        foreach ($name in $script:names) {
            $mark = Join-Path $script:marks "$name.ran"
            Test-Path $mark | Should -BeTrue -Because "$name ran in no share: $($script:runs -join ' | ')"
            @(Get-Content $mark).Count | Should -Be 1 -Because "$name ran in more than one share"
        }
    }

    It 'the split follows the times, not the sizes: the slow file has a share to itself' {
        # Slow (90 s) is the longest by time and goes first, to share 1. By size
        # it is the smallest and would share with others.
        $script:runs[0] | Should -Match 'shard 1 of 3 \(split [0-9a-f]{12}, by measured time: 5 of 6 files measured, about 90 s\)'
        $script:runs[0] | Should -Match 'vmf-test-seconds \d+\.\d\d Slow\.Tests\.ps1'
        $script:runs[0] | Should -Not -Match 'vmf-test-seconds \d+\.\d\d (Big|Mid1|Mid2|Mid3|Added)\.Tests\.ps1'
    }

    It 'all three shares name the same split' {
        $ids = foreach ($run in $script:runs) { [regex]::Match($run, 'split ([0-9a-f]{12})').Groups[1].Value }
        $ids[0] | Should -Not -BeNullOrEmpty
        @($ids | Sort-Object -Unique).Count | Should -Be 1
    }

    It 'each share writes one time line for each file it ran, and the updater reads them back' {
        $all = $script:runs -join "`n"
        $read = Get-VmfTimingLines -Text $all
        @($read.Keys | Sort-Object) | Should -Be @($script:names | ForEach-Object { "$_.Tests.ps1" } | Sort-Object)
    }
}

Describe 'CI-SHARD-MEASURE-1: the timings file is written again from Pester''s output' {

    It 'reads the time lines from a CI log, with the time stamp before each line' {
        $log = "2026-10-18T19:37:41.1Z vmf-test-seconds 12.34 A.Tests.ps1`n2026-10-18T19:37:41.2Z vmf-test-seconds 3.00 sub/B.Tests.ps1`r`nnoise vmf-test-seconds x C.Tests.ps1"
        $read = Get-VmfTimingLines -Text $log
        $read.Count | Should -Be 2
        $read['A.Tests.ps1'] | Should -Be 12.34
        $read['sub/B.Tests.ps1'] | Should -Be 3
    }

    It 'a file named twice keeps its larger time' {
        $read = Get-VmfTimingLines -Text "vmf-test-seconds 2.00 A.Tests.ps1`nvmf-test-seconds 5.00 A.Tests.ps1`nvmf-test-seconds 1.00 A.Tests.ps1"
        $read['A.Tests.ps1'] | Should -Be 5
    }

    It 'measured files get the new time, others keep theirs, and a file no longer present goes' {
        $merged = Merge-VmfTestTimings -Old @{ 'Kept.Tests.ps1' = 7.5; 'Gone.Tests.ps1' = 3; 'A.Tests.ps1' = 1 } -Measured @{ 'A.Tests.ps1' = 4.26; 'b.Tests.ps1' = 2 } -Present @('A.Tests.ps1', 'b.Tests.ps1', 'Kept.Tests.ps1', 'NoTime.Tests.ps1')
        @($merged.Keys) | Should -Be @('A.Tests.ps1', 'Kept.Tests.ps1', 'b.Tests.ps1') -Because 'ordinal order, and no entry for a file with no time or a file gone'
        $merged['A.Tests.ps1'] | Should -Be 4.3
        $merged['Kept.Tests.ps1'] | Should -Be 7.5
    }

    It 'the tool writes the file from a saved output, and the split reads it' {
        $dir = New-TimingSandbox
        try {
            $suite = Join-Path $dir 'unit'; New-Item -ItemType Directory -Path $suite | Out-Null
            foreach ($n in 'A', 'B', 'C') { Set-Content (Join-Path $suite "$n.Tests.ps1") "Describe '$n' { }" }
            $out = Join-Path $dir 'timings.json'
            Write-TimingFile $out @{ 'C.Tests.ps1' = 9; 'Removed.Tests.ps1' = 4 }
            $log = Join-Path $dir 'pester.log'
            Set-Content $log @('Pester 5.7.1: 2 test files', 'vmf-test-seconds 6.50 A.Tests.ps1', 'vmf-test-seconds 2.26 B.Tests.ps1')
            $text = & (Get-Process -Id $PID).Path -NoProfile -File $script:updater -LogPath $log -TestRoot $suite -OutPath $out 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $text
            $text | Should -Match '2 test files measured \(saved Pester output\), 1 kept from before, 0 with no time\.'
            $data = Get-Content $out -Raw | ConvertFrom-Json
            @($data.seconds.PSObject.Properties.Name) | Should -Be @('A.Tests.ps1', 'B.Tests.ps1', 'C.Tests.ps1')
            $data.measured | Should -Match '^\d{4}-\d{2}-\d{2}$'
            $ms = Read-VmfTestTimings -Path $out
            $ms['A.Tests.ps1'] | Should -Be 6500
            $ms['B.Tests.ps1'] | Should -Be 2300
            $ms['C.Tests.ps1'] | Should -Be 9000
            [System.IO.File]::ReadAllText($out) | Should -Not -Match "`r" -Because 'the same bytes on every checkout'
        }
        finally { Remove-Item $dir -Recurse -Force }
    }

    It 'an output with no time line is refused, and the file is left as it was' {
        $dir = New-TimingSandbox
        try {
            $out = Join-Path $dir 'timings.json'
            Write-TimingFile $out @{ 'A.Tests.ps1' = 1 }
            $before = [System.IO.File]::ReadAllText($out)
            $log = Join-Path $dir 'pester.log'
            Set-Content $log '100 passed, 0 failed'
            $text = & (Get-Process -Id $PID).Path -NoProfile -File $script:updater -LogPath $log -TestRoot $dir -OutPath $out 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0
            $text | Should -Match 'no "vmf-test-seconds" line'
            [System.IO.File]::ReadAllText($out) | Should -Be $before
        }
        finally { Remove-Item $dir -Recurse -Force }
    }
}
