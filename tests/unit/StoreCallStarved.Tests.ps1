#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
STORE-CALL-SLOW-1: a store request does not wait for a free thread-pool
thread.

MEASURED on the lab install (Application Insights, 2026-11-08): after
PAGE-LOAD-FREEZE-1 sent every store request over one shared HttpClient, each
schedule-timer pass took about 212 s instead of about 84 s. 469 store calls
took 212603 ms, about 453 ms each, the longest about 1020 ms, for small reads,
lists and writes.

MEASURED on this computer (the numbers are in the item file): four runspaces
on thread-pool threads, as the Functions worker runs calls, with other calls
starting all the time. SendAsync(...).GetAwaiter().GetResult() took 449 ms a
call (median 497 ms), because the Task it waits on needs another thread-pool
thread, and the pool adds one only after a wait. HttpClient.Send() took 2.7 ms:
it reads and writes the pooled connection on the calling thread.

So these tests hold every thread the pool may have (_ThreadPoolStarved.ps1)
and send store requests to a service that answers from its own threads.

THE LAB RESULT AFTER THAT FIX (2026-11-08): the pages' reads were fast, but a
timer pass's single store calls still took about 415 ms each. The store is
reached over TLS, and over TLS a request on a pooled connection waits for a
read that a thread-pool thread finishes, with Send as with SendAsync (MEASURED
on this computer: one connection, mean about 400 ms, longest 850 ms, with
other calls starting). The fix is in the pool: its minimum is raised when the
process makes the store client, so it adds a thread at once.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:server = [VmfThreadServer]::new()
    $script:holdMs = 4000
    # One store request through the whole path the service uses, timed.
    $script:Timed = { param([string]$Method, [string]$name, $Body)
        $call = @{ Method = $Method; Uri = "$($script:server.BaseUri)cont/$name"; Headers = @{ 'x-ms-blob-type' = 'BlockBlob' } }
        if ($PSBoundParameters.ContainsKey('Body')) { $call.Body = $Body }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = InModuleScope VmMigrationFactory -Parameters @{ a = $call } { Invoke-VmfStorageRequest @a }
        [pscustomobject]@{ Ms = $clock.Elapsed.TotalMilliseconds; Answer = $r }
    }
}
AfterAll {
    [VmfPoolStarver]::Release()
    $script:server.Dispose()
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'STORE-CALL-SLOW-1: a store request does not wait for a free thread-pool thread' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'starved-token' } }
    }
    AfterEach { [VmfPoolStarver]::Release() }

    It 'answers a read, a write and a check in milliseconds while the pool has no free thread' {
        # The pooled connection is open before the pool is held, as it is
        # between the calls of a timer pass.
        (& $script:Timed GET 'warm.json').Answer.StatusCode | Should -Be 200
        [VmfPoolStarver]::Starve($script:holdMs) | Should -BeTrue
        [VmfPoolStarver]::IsStarved(300) | Should -BeTrue -Because 'the test proves nothing unless the pool really has no free thread'
        $read = & $script:Timed GET 'doc1.json'
        $write = & $script:Timed PUT 'doc2.json' '{"a":1}'
        $check = & $script:Timed HEAD 'doc3.json'
        $stillHeld = [VmfPoolStarver]::IsStarved(50)
        [VmfPoolStarver]::Release()
        foreach ($one in $read, $write, $check) {
            $one.Ms | Should -BeLessThan 1500 -Because "a store request that waits for a thread-pool thread waited about a second on the lab install (this one took $([int]$one.Ms) ms; the pool was held for $($script:holdMs) ms)"
        }
        $stillHeld | Should -BeTrue -Because 'the three requests must all run while the pool is held'
        $read.Answer.StatusCode | Should -Be 200
        $read.Answer.Content | Should -BeExactly '{"n":1}'
        $write.Answer.StatusCode | Should -Be 200
        $check.Answer.StatusCode | Should -Be 200
    }

    It 'answers the reads sent together in milliseconds while the pool has no free thread' {
        $uris = @(1..16 | ForEach-Object { "$($script:server.BaseUri)cont/many$_.json" })
        # The connections are open before the pool is held.
        $null = InModuleScope VmMigrationFactory -Parameters @{ u = $uris } { Invoke-VmfStorageGetMany -Uri $u }
        [VmfPoolStarver]::Starve($script:holdMs) | Should -BeTrue
        [VmfPoolStarver]::IsStarved(300) | Should -BeTrue -Because 'the test proves nothing unless the pool really has no free thread'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $out = @(InModuleScope VmMigrationFactory -Parameters @{ u = $uris } { (Invoke-VmfStorageGetMany -Uri $u) | ForEach-Object { $_ } })
        $ms = $clock.Elapsed.TotalMilliseconds
        $stillHeld = [VmfPoolStarver]::IsStarved(50)
        [VmfPoolStarver]::Release()
        $ms | Should -BeLessThan 1500 -Because "16 reads 8 at a time with SendAsync waited for the pool (these took $([int]$ms) ms; the pool was held for $($script:holdMs) ms)"
        $stillHeld | Should -BeTrue -Because 'the reads must all run while the pool is held'
        $out.Count | Should -Be 16
        foreach ($one in $out) {
            $one.StatusCode | Should -Be 200
            $one.Content | Should -BeExactly '{"n":1}'
        }
    }

    It 'answers a timer pass''s store calls over TLS in milliseconds while other calls take thread-pool threads' {
        # One processor, as a small Functions instance has, in a process of its
        # own: the pool's minimum and the client's certificate check are set
        # once a process.
        $childOut = $null
        $before = $env:DOTNET_PROCESSOR_COUNT
        try {
            $env:DOTNET_PROCESSOR_COUNT = '1'
            $childOut = @(& ([System.Environment]::ProcessPath) -NoProfile -File (Join-Path $PSScriptRoot '_StoreTlsTimerPass.ps1') -ModulePath (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') 2>&1)
        }
        finally { if ($null -eq $before) { Remove-Item env:DOTNET_PROCESSOR_COUNT -ErrorAction SilentlyContinue } else { $env:DOTNET_PROCESSOR_COUNT = $before } }
        $line = @($childOut | ForEach-Object { "$_" } | Where-Object { $_ -like '{"ms":*' }) | Select-Object -Last 1
        $line | Should -Not -BeNullOrEmpty -Because "the timer pass must run: $($childOut -join ' | ')"
        $result = $line | ConvertFrom-Json
        $result.connections | Should -Be 1 -Because 'the wait is on a connection that is open, not on a new one'
        $sorted = @($result.ms | Sort-Object)
        $median = $sorted[[int]($sorted.Count / 2)]
        $mean = ($sorted | Measure-Object -Average).Average
        $median | Should -BeLessThan 50 -Because "a timer pass's store call waited about 415 ms on the lab install (here: median $median ms, mean $([int]$mean) ms, longest $($sorted[-1]) ms)"
        $mean | Should -BeLessThan 100
    }

    It 'gives the process enough thread-pool threads at once when it makes the store client' {
        $null = InModuleScope VmMigrationFactory { Get-VmfStorageHttpClient }
        $floor = InModuleScope VmMigrationFactory { $script:VmfStorageThreadFloor }
        $floor | Should -BeGreaterOrEqual 32
        $worker = 0; $io = 0
        [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
        $worker | Should -BeGreaterOrEqual $floor -Because 'below its minimum the pool adds a thread at once; above it, only after a wait'
    }

    It 'names the thread pool and the spread of the store call times in each service call''s line (round 3)' {
        # The lab result after the raised minimum (2026-11-08): the timer's
        # store calls still waited, many about 1015-1035 ms, with no failure and
        # low processor use. The line now says what the pool was doing, so the
        # next install shows whether the minimum was reached and the pool ran short.
        $null = InModuleScope VmMigrationFactory { Get-VmfStorageHttpClient }
        $lines = InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            foreach ($ms in 10, 120, 700, 1020, 2007) { Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/runs/p/r/run.json' -Status 200 -DurationMs $ms }
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/runs/p/r/a.json' -Status 200 -DurationMs 5000 -Overlapped
            Complete-VmfCallTimings 6>&1
        }
        $json = [string]@($lines)[0].MessageData -replace '^VMF-CALLS ', ''
        $rec = $json | ConvertFrom-Json
        $rec.pool | Should -Not -BeNullOrEmpty
        $worker = 0; $io = 0
        [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
        $rec.pool.min | Should -Be $worker
        $rec.pool.cpus | Should -Be ([System.Environment]::ProcessorCount)
        $rec.pool.floor | Should -BeTrue -Because 'the store client was made, so the minimum was raised'
        $rec.pool.threads | Should -BeGreaterThan 0
        $rec.pool.maxThreads | Should -BeGreaterOrEqual 1
        $rec.pool.PSObject.Properties.Name | Should -Contain 'pending'
        $rec.pool.PSObject.Properties.Name | Should -Contain 'maxPending'
        $rec.pool.PSObject.Properties.Name | Should -Contain 'open'
        $maxWorker = 0; $maxIo = 0
        [System.Threading.ThreadPool]::GetMaxThreads([ref]$maxWorker, [ref]$maxIo)
        $rec.pool.max | Should -Be $maxWorker
        $rec.pool.process | Should -Be ([System.Environment]::ProcessId)
        $rec.pool.upS | Should -BeGreaterOrEqual 0
        $rec.pool.free | Should -BeGreaterThan 0
        $rec.pool.onPool | Should -BeFalse -Because 'a Pester run is on the main thread, not a thread-pool thread'
        # Each store call that is not one of several sent together, by its time.
        $rec.storeSpread.lt50 | Should -Be 1
        $rec.storeSpread.lt250 | Should -Be 1
        $rec.storeSpread.lt1000 | Should -Be 1
        $rec.storeSpread.lt1500 | Should -Be 1
        $rec.storeSpread.ge1500 | Should -Be 1
    }

    It 'records the most work the pool had waiting during the service call' {
        $null = InModuleScope VmMigrationFactory { Start-VmfCallTimings }
        [VmfPoolStarver]::Starve($script:holdMs) | Should -BeTrue
        [VmfPoolStarver]::IsStarved(300) | Should -BeTrue
        InModuleScope VmMigrationFactory { Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/runs/p/r/run.json' -Status 200 -DurationMs 5 }
        [VmfPoolStarver]::Release()
        $lines = InModuleScope VmMigrationFactory { Complete-VmfCallTimings 6>&1 }
        $rec = ([string]@($lines)[0].MessageData -replace '^VMF-CALLS ', '') | ConvertFrom-Json
        $rec.pool.maxPending | Should -BeGreaterOrEqual 4 -Because 'the pool held every thread and had at least four items waiting while the store call was counted'
    }

    It 'counts the TCP connections the computer opened during the service call' {
        $null = InModuleScope VmMigrationFactory { Start-VmfCallTimings }
        foreach ($i in 1..3) {
            $c = [System.Net.Sockets.TcpClient]::new()
            try { $c.Connect([System.Net.IPAddress]::Loopback, ([uri]$script:server.BaseUri).Port) } finally { $c.Dispose() }
        }
        $lines = InModuleScope VmMigrationFactory { Complete-VmfCallTimings 6>&1 }
        $rec = ([string]@($lines)[0].MessageData -replace '^VMF-CALLS ', '') | ConvertFrom-Json
        $rec.pool.tcp | Should -Not -BeNullOrEmpty -Because 'the computer gives its TCP counters here; the install shows whether it does'
        $rec.pool.tcp.opened | Should -BeGreaterOrEqual 3
        $rec.pool.tcp.PSObject.Properties.Name | Should -Contain 'resent'
    }

    It 'writes one pool line a process when it makes the store client, with the pool before and after the raised minimum' {
        $childScript = @'
param($m)
Import-Module $m -Force
$first = @(& (Get-Module VmMigrationFactory) { $null = Get-VmfStorageHttpClient } 6>&1)
$second = @(& (Get-Module VmMigrationFactory) { $null = Get-VmfStorageHttpClient } 6>&1)
[pscustomobject]@{ first = @($first | ForEach-Object { [string]$_.MessageData }); second = $second.Count } | ConvertTo-Json -Compress
'@
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pool-line-$([guid]::NewGuid().ToString('n')).ps1"
        Set-Content -LiteralPath $file -Value $childScript -Encoding utf8NoBOM
        try {
            $before = $env:DOTNET_PROCESSOR_COUNT
            try {
                $env:DOTNET_PROCESSOR_COUNT = '1'
                $out = @(& ([System.Environment]::ProcessPath) -NoProfile -File $file -m (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') 2>&1)
            }
            finally { if ($null -eq $before) { Remove-Item env:DOTNET_PROCESSOR_COUNT -ErrorAction SilentlyContinue } else { $env:DOTNET_PROCESSOR_COUNT = $before } }
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        $result = (@($out | ForEach-Object { "$_" } | Where-Object { $_ -like '{"first":*' }) | Select-Object -Last 1) | ConvertFrom-Json
        $result | Should -Not -BeNullOrEmpty -Because "$($out -join ' | ')"
        @($result.first).Count | Should -Be 1
        $result.second | Should -Be 0 -Because 'the line is written once a process'
        $result.first[0] | Should -BeLike 'VMF-POOL {*'
        $pool = ($result.first[0] -replace '^VMF-POOL ', '') | ConvertFrom-Json
        $pool.set | Should -BeTrue
        $pool.cpus | Should -Be 1
        $pool.before.min | Should -Be 1 -Because 'with one processor the default minimum is 1'
        $pool.after.min | Should -Be $pool.floor
        $pool.after.max | Should -BeGreaterOrEqual $pool.floor
    }

    It 'makes the store client and sends store requests when the pool read and the raised minimum both fail' {
        # The review of round 3: the pool line was built before the client,
        # with nothing to catch a failure - one throw there and every store
        # request of the process failed. In a new process: the holder is made
        # once a process.
        $childScript = @'
param($m, $helper)
$ErrorActionPreference = 'Stop'
. $helper
function Global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = 'guard-token' } }
Import-Module $m -Force
& (Get-Module VmMigrationFactory) {
    function script:Get-VmfThreadPoolNow { throw 'the pool read failed' }
    function script:Set-VmfStorageThreadFloor { throw 'the raised minimum failed' }
}
# The first call that makes the client must not throw.
$clientMade = try { $null = & (Get-Module VmMigrationFactory) { Get-VmfStorageHttpClient } 6>$null; $true } catch { $false }
$server = [VmfThreadServer]::new()
try {
    $info = @(& (Get-Module VmMigrationFactory) { param($u) $r = Invoke-VmfStorageRequest -Method GET -Uri $u; Write-Output ([pscustomobject]@{ status = $r.StatusCode; content = $r.Content }) } "$($server.BaseUri)cont/doc1.json" 6>&1)
    $answer = @($info | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
    $lines = @($info | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    $floor = & (Get-Module VmMigrationFactory) { [bool](Get-VmfStorageHttpHolder).Floor }
    [pscustomobject]@{ status = $answer.status; content = $answer.content; poolLines = @($lines | Where-Object { $_ -like 'VMF-POOL*' }).Count; floor = $floor; clientMade = $clientMade } | ConvertTo-Json -Compress
}
finally { $server.Dispose() }
'@
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pool-guard-$([guid]::NewGuid().ToString('n')).ps1"
        Set-Content -LiteralPath $file -Value $childScript -Encoding utf8NoBOM
        try {
            $out = @(& ([System.Environment]::ProcessPath) -NoProfile -File $file -m (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -helper (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1') 2>&1)
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        $line = @($out | ForEach-Object { "$_" } | Where-Object { $_ -like '{"status":*' }) | Select-Object -Last 1
        $line | Should -Not -BeNullOrEmpty -Because "$($out -join ' | ')"
        $result = $line | ConvertFrom-Json
        $result.clientMade | Should -BeTrue -Because 'the call that makes the client must not throw (a store request would only get through on its retry)'
        $result.status | Should -Be 200 -Because 'a failed diagnostic must never stop a store request'
        $result.content | Should -BeExactly '{"n":1}'
        $result.poolLines | Should -Be 0 -Because 'the pool line is left out when its read fails'
        $result.floor | Should -BeFalse -Because 'the line says the minimum was not raised'
    }

    It 'still writes the service call''s line with its totals when every pool read fails' {
        Mock -ModuleName VmMigrationFactory Get-VmfProcessUpSeconds { throw 'no process start time' }
        Mock -ModuleName VmMigrationFactory Get-VmfTcpCounters { throw 'no TCP counters' }
        Mock -ModuleName VmMigrationFactory Get-VmfThreadPoolNow { throw 'no pool' }
        Mock -ModuleName VmMigrationFactory Get-VmfCallTimingsOpen { throw 'no count' }
        $lines = InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/runs/p/r/run.json' -Status 200 -DurationMs 30
            Complete-VmfCallTimings 6>&1
        }
        @($lines).Count | Should -Be 1 -Because 'a failed diagnostic read must not lose the line'
        $rec = ([string]@($lines)[0].MessageData -replace '^VMF-CALLS ', '') | ConvertFrom-Json
        $rec.store.n | Should -Be 1
        $rec.storeSpread.lt50 | Should -Be 1
        $rec.pool.upS | Should -BeNullOrEmpty
        $rec.pool.tcp | Should -BeNullOrEmpty
        $rec.pool.min | Should -BeNullOrEmpty
        $rec.pool.open | Should -BeNullOrEmpty
        $rec.pool.cpus | Should -Be ([System.Environment]::ProcessorCount) -Because 'each field is read on its own'
    }

    It 'writes the line without the pool when the whole pool read fails' {
        Mock -ModuleName VmMigrationFactory Get-VmfCallTimingPool { throw 'the pool failed' }
        $lines = InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/runs/p/r/run.json' -Status 200 -DurationMs 30
            Complete-VmfCallTimings 6>&1
        }
        @($lines).Count | Should -Be 1
        $rec = ([string]@($lines)[0].MessageData -replace '^VMF-CALLS ', '') | ConvertFrom-Json
        $rec.store.n | Should -Be 1
        $rec.pool | Should -BeNullOrEmpty
    }

    It 'gives back the process object it reads the start time from' {
        $file = Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'azureops' 'CallTimings.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-VmfProcessUpSeconds' }, $true)
        $code = Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
        $code | Should -Match 'finally\s*\{\s*\$proc\.Dispose\(\)' -Because 'GetCurrentProcess makes a new object each call'
        (Get-VmfCodeOnly -Path $file -Language PowerShell) | Should -Not -Match 'GetCurrentProcess\(\)\.StartTime' -Because 'only Get-VmfProcessUpSeconds reads it, and it gives the object back'
    }

    It 'counts the service calls open in the process' {
        $before = InModuleScope VmMigrationFactory { Get-VmfCallTimingsOpen }
        InModuleScope VmMigrationFactory { Start-VmfCallTimings }
        (InModuleScope VmMigrationFactory { Get-VmfCallTimingsOpen }) | Should -Be ($before + 1)
        $null = InModuleScope VmMigrationFactory { Complete-VmfCallTimings 6>&1 }
        (InModuleScope VmMigrationFactory { Get-VmfCallTimingsOpen }) | Should -Be $before
    }

    It 'sends and reads with the synchronous HttpClient calls, never by waiting on a Task' {
        $file = Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsStorage.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $codeOf = { param($name)
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
            $fn | Should -Not -BeNullOrEmpty -Because "$name must exist"
            Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
        }
        $one = & $codeOf 'Send-VmfStorageHttpRequest'
        $one | Should -Match '\.Send\(\$req\b'
        $one | Should -Not -Match 'Async\(' -Because 'an ...Async call waited on from a runspace needs a second thread-pool thread to finish'
        $one | Should -Not -Match 'GetAwaiter|\.Result\b|\.Wait\('
        $many = & $codeOf 'Invoke-VmfStorageGetMany'
        $many | Should -Match 'LongRunning'
        $many | Should -Not -Match 'Async\(|GetAwaiter' -Because 'each read sent together must finish on its own thread, not on a thread-pool thread'
        $read = & $codeOf 'Read-VmfStorageHttpBytes'
        $read | Should -Not -Match 'Async\(|GetAwaiter|\.Result\b'
    }
}
