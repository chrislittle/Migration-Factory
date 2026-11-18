#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-JS-HANG-1, 2026-11-03. A dashboard behaviour test that awaits a promise
# that never settles, with nothing else waiting (no timer, no socket), lets node
# run out of work and end - with exit code 0, before the harness's run() prints
# its summary or sets the exit code. Every failure recorded before it is lost,
# and tools/Invoke-VmfJsTests.ps1 read only the exit code, so the file passed.
#
# Found twice: PERF-ONE-LIMIT-1's mutation "a failed read keeps its slot" made a
# page's load wait forever, and QUOTA-FILED-WORDS-1's first Request test awaited
# a send while the boot DOM's setTimeout never fired. Both ended with no output
# and exit code 0.
#
# These run real node against small test files written to TestDrive, each
# loading the real tests/js/_harness.js.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:harness  = (Join-Path $script:repoRoot 'tests' 'js' '_harness.js') -replace '\\', '/'
    $script:runner   = Join-Path $script:repoRoot 'tools' 'Invoke-VmfJsTests.ps1'
    $script:node     = (Get-Command node -ErrorAction SilentlyContinue)?.Source

    # A test file that loads the real harness. $body is the file's tests.
    function New-HangFixture([string]$Folder, [string]$Name, [string]$Body) {
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $file = Join-Path $Folder $Name
        $text = "'use strict';`nconst HARNESS = '$($script:harness)';`nconst { test, eq, run } = require(HARNESS);`n$Body`n"
        [System.IO.File]::WriteAllText($file, $text)
        $file
    }

    # Run one file in node; the exit code and the whole output. Bounded
    # (TEST-JS-TIMER-HANG-1): a harness that lost its time limit must fail
    # this file, not stop it. Code is 'did not end' when it was stopped.
    function Invoke-HangFixture([string]$File, [int]$Seconds = 60) {
        Invoke-Bounded $script:node @($File) $Seconds
    }

    # The runner, in its own pwsh, bounded the same way: a runner that lost
    # its limit, or reads one pipe to its end before it starts the limit,
    # must fail these tests, not stop this file. Code is the runner's exit
    # code (1 when it throws); Text holds its output and its error.
    function Invoke-RunnerBounded([string]$Folder, [int]$Limit) {
        $shell = [System.Environment]::ProcessPath
        Invoke-Bounded $shell @('-NoProfile', '-NonInteractive', '-File', $script:runner, '-Path', $Folder, '-TimeoutSeconds', "$Limit") ($Limit + 90)
    }

    function Invoke-Bounded([string]$Exe, [string[]]$Arguments, [int]$Seconds) {
        $info = [System.Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in $Arguments) { $info.ArgumentList.Add($a) }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($info)
        try {
            $stdout = $proc.StandardOutput.ReadToEndAsync()
            $stderr = $proc.StandardError.ReadToEndAsync()
            $ended = $proc.WaitForExit($Seconds * 1000)
            if (-not $ended) { try { $proc.Kill($true) } catch { $null = $_ }; $null = $proc.WaitForExit(10000) }
            # Bounded, and a read that has not finished gives nothing: a process
            # a broken runner left running inherits and holds these pipes.
            try { $null = [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 10000) } catch { $null = $_ }
            $text = @($stdout, $stderr) | ForEach-Object { if ($_.IsCompletedSuccessfully) { $_.Result } else { '(not read: the pipe stayed open)' } }
            [pscustomobject]@{ Code = $(if ($ended) { $proc.ExitCode } else { 'did not end' }); Text = ($text -join "`n") }
        } finally { $proc.Dispose() }
    }
}

Describe 'TEST-JS-HANG-1: a test that never finishes fails its file' {
    It 'needs node, and does not skip when it is missing' {
        $script:node | Should -Not -BeNullOrEmpty -Because 'a check that quietly does not run is worse than no check'
    }

    It 'a test that awaits a promise that never settles ends the file with exit code 1 and names that test' {
        $file = New-HangFixture (Join-Path $TestDrive 'hang') 'hang.test.js' @'
test('first, passes', () => { eq(1, 1); });
test('second, never ends', async () => { await new Promise(() => {}); });
test('third, never reached', () => { eq(1, 1); });
run('hang');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1 -Because "node ran out of work inside a test. Output: $($r.Text)"
        $r.Text | Should -Match 'second, never ends' -Because 'the line must say which test did not finish'
        $r.Text | Should -Match 'did not finish'
        $r.Text | Should -Not -Match 'third, never reached' -Because 'only the test that was running is named'
    }

    It 'a failure recorded before the hang is still printed' {
        $file = New-HangFixture (Join-Path $TestDrive 'hangfail') 'hangfail.test.js' @'
test('fails first', () => { eq(1, 2, 'one'); });
test('then waits forever', async () => { await new Promise(() => {}); });
run('hangfail');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'fails first'
        $r.Text | Should -Match 'one: got 1, wanted 2'
        $r.Text | Should -Match 'then waits forever'
    }

    It 'a file that never calls run() fails, because none of its tests ran' {
        $file = New-HangFixture (Join-Path $TestDrive 'norun') 'norun.test.js' @'
test('never run', () => { eq(1, 1); });
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1 -Because "no test ran. Output: $($r.Text)"
        $r.Text | Should -Match 'run\(\)'
    }

    It 'a test that waits on a timer and then finishes still passes' {
        $file = New-HangFixture (Join-Path $TestDrive 'timer') 'timer.test.js' @'
test('waits 20 ms', async () => { await new Promise(r => setTimeout(r, 20)); eq(1, 1); });
test('then passes', () => { eq(2, 2); });
run('timer');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 0 -Because "every test finished. Output: $($r.Text)"
        $r.Text | Should -Match 'timer: 2/2 passed'
        $r.Text | Should -Not -Match 'did not finish'
    }

    It 'a failing test still ends the file with exit code 1 and the summary' {
        $file = New-HangFixture (Join-Path $TestDrive 'fail') 'fail.test.js' @'
test('fails', () => { eq('a', 'b', 'letter'); });
run('fail');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'fail: 0/1 passed, 1 FAILED'
        $r.Text | Should -Not -Match 'did not finish'
    }
}

Describe 'TEST-JS-HANG-1: the runner fails a file that printed no summary' {
    It 'a file that ends with exit code 0 and no "N/M passed" line fails the run, and the run names it' {
        $folder = Join-Path $TestDrive 'silent'
        $null = New-HangFixture $folder 'good.test.js' @'
test('passes', () => { eq(1, 1); });
run('good');
'@
        $null = New-Item -ItemType Directory -Path $folder -Force
        [System.IO.File]::WriteAllText((Join-Path $folder 'silent.test.js'), "'use strict';`n// ends with exit code 0 and says nothing`n")
        $err = $null
        try { $null = & $script:runner -Path $folder } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty -Because 'a file that printed no summary did not prove that its tests ran'
        "$err" | Should -Match 'silent\.test\.js'
        "$err" | Should -Not -Match 'good\.test\.js'
    }

    It 'a file that ran no test fails the run, though it printed "0/0 passed"' {
        $folder = Join-Path $TestDrive 'empty'
        $null = New-HangFixture $folder 'empty.test.js' @"
run('empty');
"@
        $err = $null
        try { $null = & $script:runner -Path $folder } catch { $err = $_ }
        "$err" | Should -Match 'empty\.test\.js' -Because 'a file with no test proves nothing'
    }
    It 'a file that printed its summary and then ended with exit code 1 fails the run' {
        # Code after run() that throws, or exits 1, is a failure, whatever the
        # summary said.
        $folder = Join-Path $TestDrive 'lateexit'
        $null = New-HangFixture $folder 'late.test.js' @"
test('passes', () => { eq(1, 1); });
run('late').then(() => { process.exit(1); });
"@
        $err = $null
        try { $null = & $script:runner -Path $folder } catch { $err = $_ }
        "$err" | Should -Match 'late\.test\.js \(exit code 1\)'
    }
    It 'a file whose summary line is there passes the run' {
        $folder = Join-Path $TestDrive 'clean'
        $null = New-HangFixture $folder 'a.test.js' @'
test('passes', () => { eq(1, 1); });
run('a');
'@
        $null = New-HangFixture $folder 'b.test.js' @'
test('passes too', () => { eq(2, 2); });
run('b');
'@
        $result = & $script:runner -Path $folder | Select-Object -Last 1
        $result.Files | Should -Be 2
    }

    It 'a file that fails is named in the run''s error' {
        $folder = Join-Path $TestDrive 'named'
        $null = New-HangFixture $folder 'ok.test.js' @'
test('passes', () => { eq(1, 1); });
run('ok');
'@
        $null = New-HangFixture $folder 'broken.test.js' @'
test('fails', () => { eq(1, 2); });
run('broken');
'@
        $err = $null
        try { $null = & $script:runner -Path $folder } catch { $err = $_ }
        "$err" | Should -Match 'broken\.test\.js'
        "$err" | Should -Not -Match 'ok\.test\.js'
    }
}

# TEST-JS-TIMER-HANG-1, 2026-11-07. The beforeExit guard above comes only when
# node has nothing left to do. A test that awaits a promise that never settles
# while a timer repeats (setInterval, or a page's poll) never gets there: node
# runs forever, the CI gates job stops at its own limit with no line that names
# the file, and every builder on this PC waits behind the suite lock.
# So the runner gives each file a time limit, and the harness gives each test
# one; each failure names what did not end.
Describe 'TEST-JS-TIMER-HANG-1: the runner stops a file that does not end' {
    BeforeAll {
        # A test that waits forever while a repeating timer keeps node busy.
        $script:busyHang = @'
test('first, passes', () => { eq(1, 1); });
test('waits forever while a timer repeats', async () => { setInterval(() => {}, 50); await new Promise(() => {}); });
run('busy');
'@
    }

    It 'fails the file with "did not end in N seconds", names it, stops it, and still runs the next file' {
        $folder = Join-Path $TestDrive 'busy'
        $null = New-HangFixture $folder 'a-busy.test.js' ("require('fs').writeFileSync(require('path').join(__dirname, 'pid.txt'), String(process.pid));`n" + $script:busyHang)
        $null = New-HangFixture $folder 'b-after.test.js' @'
test('passes', () => { eq(1, 1); });
run('after');
'@
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RunnerBounded $folder 4
        $sw.Stop()
        $r.Code | Should -Be 1 -Because "a file that never ended did not prove its tests. Output: $($r.Text)"
        $r.Text | Should -Match 'a-busy\.test\.js \(did not end in 4 seconds\)'
        $r.Text | Should -Match '(?<!\d)1 JavaScript test file\(s\) failed' -Because 'the file is counted once'
        $r.Text | Should -Not -Match 'b-after\.test\.js \(' -Because 'the file after it ended and passed'
        $r.Text | Should -Match 'after: 1/1 passed' -Because 'the run goes on to the next file'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 40 -Because 'the limit was 4 seconds, not the harness limit or none'
        $nodePid = [int](Get-Content (Join-Path $folder 'pid.txt'))
        $alive = Get-Process -Id $nodePid -ErrorAction SilentlyContinue
        if ($alive) { Stop-Process -Id $nodePid -Force -ErrorAction SilentlyContinue }
        $alive | Should -BeNullOrEmpty -Because 'the runner stops the node process it gave up on'
    }

    It 'prints what the file wrote before it was stopped, and the line that says it was stopped' {
        $folder = Join-Path $TestDrive 'busyout'
        $null = New-HangFixture $folder 'busy.test.js' ("require('fs').writeFileSync(require('path').join(__dirname, 'pid.txt'), String(process.pid));`nconsole.log('written before the wait');`n" + $script:busyHang)
        $r = Invoke-RunnerBounded $folder 3
        Stop-Process -Id ([int](Get-Content (Join-Path $folder 'pid.txt'))) -Force -ErrorAction SilentlyContinue # only a broken runner leaves it
        $r.Text | Should -Match 'written before the wait'
        $r.Text | Should -Match 'busy\.test\.js: did not end in 3 seconds'
    }

    It 'stops the processes the file started as well' {
        # Detached: on Windows a child that is not detached shares node's job
        # object and ends with node anyway, which would prove nothing here.
        $folder = Join-Path $TestDrive 'busychild'
        $null = New-HangFixture $folder 'parent.test.js' @'
const cp = require('child_process');
const child = cp.spawn(process.execPath, ['-e', 'setInterval(() => {}, 50)'], { stdio: 'ignore', detached: true });
require('fs').writeFileSync(require('path').join(__dirname, 'child.txt'), String(child.pid));
setInterval(() => {}, 50);
'@
        $null = Invoke-RunnerBounded $folder 3
        $childPid = [int](Get-Content (Join-Path $folder 'child.txt'))
        $alive = Get-Process -Id $childPid -ErrorAction SilentlyContinue
        if ($alive) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        $alive | Should -BeNullOrEmpty -Because 'a process the file started must not outlive the run'
    }

    It 'a file that writes a lot to stderr and to stdout ends, and passes' {
        # Both pipes are read at the same time; one read after the other
        # leaves node waiting on a full pipe.
        $folder = Join-Path $TestDrive 'loud'
        $null = New-HangFixture $folder 'loud.test.js' @'
const chunk = 'x'.repeat(1023) + '\n';
for (let i = 0; i < 1024; i++) { process.stderr.write(chunk); }
for (let i = 0; i < 1024; i++) { process.stdout.write(chunk); }
test('passes', () => { eq(1, 1); });
run('loud');
'@
        $r = Invoke-RunnerBounded $folder 20
        $r.Code | Should -Be 0 -Because 'the file ended and passed'
        @($r.Text -split '\r?\n' | Where-Object { $_ -match '^x{1023}$' }).Count | Should -Be 2048 -Because 'every line of both streams is printed'
    }

    It 'a file that ends inside the limit passes as before' {
        $folder = Join-Path $TestDrive 'quick'
        $null = New-HangFixture $folder 'quick.test.js' @'
test('waits 200 ms', async () => { await new Promise(r => setTimeout(r, 200)); eq(1, 1); });
run('quick');
'@
        $r = Invoke-RunnerBounded $folder 10
        $r.Code | Should -Be 0 -Because "the file ended inside the limit. Output: $($r.Text)"
        $r.Text | Should -Match 'quick: 1/1 passed'
    }

    It 'the default limit is well above the slowest file (about 25 seconds, measured 2026-11-07)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:runner, [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutSeconds' }
        $param | Should -Not -BeNullOrEmpty
        $default = [int]$param.DefaultValue.SafeGetValue()
        $default | Should -BeGreaterOrEqual 120 -Because 'a slow runner must not fail a file that works'
        $default | Should -BeLessOrEqual 600 -Because 'the CI gates job stops at 20 minutes, with no line that names the file'
    }
}

Describe 'TEST-JS-TIMER-HANG-1: the harness stops a test that does not end' {
    It 'a test that waits forever while a timer repeats fails with its name, and the next test still runs' {
        $file = New-HangFixture (Join-Path $TestDrive 'limit') 'limit.test.js' @'
const { testLimit } = require(HARNESS);
testLimit(1);
test('fails first', () => { eq(1, 2, 'one'); });
test('waits forever while a timer repeats', async () => { setInterval(() => {}, 50); await new Promise(() => {}); });
test('then passes', () => { eq(1, 1); });
run('limit');
'@
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-HangFixture $file
        $sw.Stop()
        $r.Code | Should -Be 1 -Because "a test did not end. Output: $($r.Text)"
        $r.Text | Should -Match 'limit: 1/3 passed, 2 FAILED'
        $r.Text | Should -Match 'waits forever while a timer repeats\s+did not end in 1 seconds'
        $r.Text | Should -Match 'one: got 1, wanted 2' -Because 'a failure recorded before it is still printed'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'the limit runs on node''s own clock, when a file puts a fake setTimeout on the global object' {
        # Several files fake setTimeout to control a page's clock.
        $file = New-HangFixture (Join-Path $TestDrive 'fakeclock') 'fakeclock.test.js' @'
const { testLimit } = require(HARNESS);
testLimit(1);
const realInterval = setInterval;
global.setTimeout = () => ({ unref() {} });
global.clearTimeout = () => {};
test('waits forever while a timer repeats', async () => { realInterval(() => {}, 50); await new Promise(() => {}); });
run('fakeclock');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'waits forever while a timer repeats\s+did not end in 1 seconds' -Because "Output: $($r.Text)"
    }

    It 'a test that ends after its limit is not counted as passed when it ends' {
        $file = New-HangFixture (Join-Path $TestDrive 'late') 'late.test.js' @'
const { testLimit } = require(HARNESS);
testLimit(2);
// The first ends at 3 s, while the second (2 s to 3.5 s) runs.
test('ends after its limit', async () => { await new Promise(r => setTimeout(r, 3000)); });
test('waits while the late one ends', async () => { await new Promise(r => setTimeout(r, 1500)); });
run('late');
'@
        $r = Invoke-HangFixture $file
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'late: 1/2 passed, 1 FAILED' -Because "the late test failed once and must not also pass. Output: $($r.Text)"
    }

    It 'the default limit for one test is well above the slowest test (about 1 second, measured 2026-11-07)' {
        . (Join-Path $script:repoRoot 'tests' 'unit' '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tests' 'js' '_harness.js')
        $code | Should -Match 'let testLimitMs = (\d+) \* 1000;'
        $null = $code -match 'let testLimitMs = (\d+) \* 1000;'
        [int]$Matches[1] | Should -BeGreaterOrEqual 30 -Because 'a slow runner must not fail a test that works'
        [int]$Matches[1] | Should -BeLessThan 120 -Because 'the limit for one test must come before the runner limit for its file, so the line names the test'
    }
}
