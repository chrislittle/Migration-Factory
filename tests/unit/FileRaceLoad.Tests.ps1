#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# FILE-RACE-LOAD-1: on a busy computer the file store gave up on a held lease
# file too soon.
#
# Every file-store read, replace, delete, aside move, log append and lock take
# tries again while another handle holds the file (FILE-BACKEND-RACE-1). The
# wait was 1 second of clock time, counted from before the first try. On a
# busy computer that failed twice in this repository's own suites and once in
# CI on a GitHub runner (2026-11-18, WAVE-APPROVE-1: "Exception calling .ctor
# with 4 argument(s) ... rg-app--app-02--3572842f.lease ... being used by
# another process"): a holder that is not given the processor keeps its handle
# for longer than a second, and a thread that is not given the processor
# misses the whole second and makes ONE try.
#
# MEASURED on this computer (2026-11-20, 16 logical processors, 48 busy
# threads and 4 disk writers with Flush(true)): the longest stretch for which
# the store's own lease create, renew and delete kept a shared reader out was
# 65 ms (82 ms with no processor load). The I/O is short; the risk is the
# scheduler. So the wait is now 10 seconds (the same as the lock a
# version-checked writer waits for), AND at least a set number of tries,
# whatever the clock says.
#
# Most tests here hold the file from a second handle in THIS thread, and let
# go when the store has tried again a set number of times
# (Wait-VmfFileRetry is the store's pause between tries). That makes them
# independent of the speed of the computer. The tests of the clock bound use
# a second thread, because they test the clock.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:storeApi = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'StoreApi.ps1'

    function Global:FrlRun {
        $rp = Join-Path $TestDrive "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $rp 'leases') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rp 'logs') -Force | Out-Null
        $rp
    }
    # Hold $Path from a second handle in this thread.
    function Global:FrlHold([string]$Path, [string]$Share) {
        $global:FrlHandle = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]$Share)
        $global:FrlRelease = { if ($global:FrlHandle) { $global:FrlHandle.Dispose(); $global:FrlHandle = $null } }
    }
    # Hold $Path from another thread for $Milliseconds; returns once it IS held.
    function Global:FrlHoldThread([string]$Path, [string]$Share, [int]$Milliseconds) {
        $flag = "$Path.held.$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $job = Start-ThreadJob -Name 'vmf-frl-hold' -ArgumentList $Path, $Share, $Milliseconds, $flag -ScriptBlock {
            param($file, $share, $ms, $flag)
            $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]$share)
            try { [System.IO.File]::WriteAllText($flag, 'held'); [System.Threading.Thread]::Sleep($ms) }
            finally { $fs.Dispose() }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not [System.IO.File]::Exists($flag) -and [DateTime]::UtcNow -lt $deadline) { [System.Threading.Thread]::Sleep(5) }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        $job
    }
    $script:wasWait = InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds }
    $script:wasTries = InModuleScope VmMigrationFactory { $script:VmfFileMinAttempts }
}
AfterAll { Remove-Item function:FrlRun, function:FrlHold, function:FrlHoldThread -ErrorAction SilentlyContinue }

Describe 'FILE-RACE-LOAD-1: the wait for a held file' {
    It 'is 10 seconds and at least 20 tries' {
        InModuleScope VmMigrationFactory {
            $script:VmfFileWaitMilliseconds | Should -Be 10000
            $script:VmfFileMinAttempts | Should -Be 20
        }
    }

    It 'every file-store retry loop asks the one rule (Test-VmfFileRetryLeft), and none asks the clock alone' {
        $code = Get-VmfCodeOnly -Path $script:storeApi
        $code | Should -Not -Match 'UtcNow\s+-ge\s+\$deadline' -Because 'a clock-only bound gives a thread that missed the wait ONE try'
        $code | Should -Not -Match 'UtcNow\s+-gt\s+\$deadline'
        $code | Should -Not -Match '\$attempt\s+-le\s+5' -Because 'the log append used to give up after 5 tries with no wait under test'
        ([regex]::Matches($code, 'Test-VmfFileRetryLeft\s+-')).Count | Should -Be 7 -Because 'read, replace, delete, aside move, put-back (ASIDE-PUTBACK-ONE-TRY-1), log append and lock take'
        ([regex]::Matches($code, 'Wait-VmfFileRetry\b(?!\s*\{)')).Count | Should -BeGreaterOrEqual 6
    }
}

Describe 'FILE-RACE-LOAD-1: a thread that missed the whole wait still tries again' {
    BeforeEach {
        $script:rp = FrlRun
        $global:FrlHandle = $null
        $global:FrlRelease = $null
        $global:FrlTries = 0
        $global:FrlReleaseAt = 3
        # The clock bound is already spent at the first try, as for a thread
        # the computer did not run for longer than the wait.
        InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds = 0; $script:VmfFileMinAttempts = 5 }
        Mock -ModuleName VmMigrationFactory Wait-VmfFileRetry {
            $global:FrlTries++
            if ($global:FrlReleaseAt -gt 0 -and $global:FrlTries -ge $global:FrlReleaseAt -and $global:FrlRelease) { & $global:FrlRelease; $global:FrlRelease = $null }
        }
    }
    AfterEach {
        if ($global:FrlHandle) { $global:FrlHandle.Dispose(); $global:FrlHandle = $null }
        InModuleScope VmMigrationFactory -Parameters @{ w = $script:wasWait; t = $script:wasTries } { param($w, $t) $script:VmfFileWaitMilliseconds = $w; $script:VmfFileMinAttempts = $t }
    }

    It 'a lease read while another handle holds the lease exclusively' {
        $file = Join-Path $script:rp 'leases' 'a.lease'
        [System.IO.File]::WriteAllText($file, '{"vmId":"a","workerId":"w1"}')
        FrlHold $file 'None'
        $text = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Read-VmfStoreText -RunPath $rp -RelPath 'leases/a.lease' }
        $text | Should -Match '"workerId":"w1"'
        $global:FrlTries | Should -Be 3
    }

    It 'a lease renewal (a replace) while another process reads the lease' {
        $file = Join-Path $script:rp 'leases' 'b.lease'
        [System.IO.File]::WriteAllText($file, 'old')
        FrlHold $file 'Read'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Write-VmfStoreText -RunPath $rp -RelPath 'leases/b.lease' -Content 'new' }
        [System.IO.File]::ReadAllText($file) | Should -Be 'new'
        @(Get-ChildItem (Join-Path $script:rp 'leases') -Filter '*.tmp.*').Count | Should -Be 0
        $global:FrlTries | Should -Be 3
    }

    It 'a lease delete while another process reads the lease' {
        $file = Join-Path $script:rp 'leases' 'c.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        FrlHold $file 'Read'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Remove-VmfStoreItem -RunPath $rp -RelPath 'leases/c.lease' }
        Test-Path -LiteralPath $file | Should -BeFalse
        $global:FrlTries | Should -Be 3
    }

    It 'a worker releases its lease (Remove-VmfLease) while another process reads it: the lease is moved aside and removed' {
        $vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-02'
        $null = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $vmId } { param($rp, $v) New-VmfLease -RunPath $rp -VmId $v -WorkerId 'w1' }
        $file = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $vmId } { param($rp, $v) Get-VmfLeasePath -RunPath $rp -VmId $v }
        Test-Path -LiteralPath $file | Should -BeTrue
        FrlHold $file 'Read'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $vmId } { param($rp, $v) Remove-VmfLease -RunPath $rp -VmId $v -WorkerId 'w1' }
        Test-Path -LiteralPath $file | Should -BeFalse
        @(Get-ChildItem (Join-Path $script:rp 'leases')).Count | Should -Be 0 -Because 'no lock file and no text moved aside is left'
        $global:FrlTries | Should -Be 3
    }

    It 'a log line appended while another process reads the log without write sharing' {
        $file = Join-Path $script:rp 'logs' 'events.jsonl'
        [System.IO.File]::WriteAllText($file, "first`n")
        FrlHold $file 'Read'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Add-VmfStoreLine -RunPath $rp -RelPath 'logs/events.jsonl' -Line 'second' }
        [System.IO.File]::ReadAllText($file) | Should -Be "first`nsecond`n"
        $global:FrlTries | Should -Be 3
    }

    It 'the lock of a version-checked writer, held by another writer, is taken when that writer lets it go' {
        $doc = Join-Path $script:rp 'leases' 'e.lease'
        [System.IO.File]::WriteAllText($doc, '{}')
        [System.IO.File]::WriteAllText("$doc.lock", 'other')
        $global:FrlRelease = { [System.IO.File]::Delete("$doc.lock") }.GetNewClosure()
        $lock = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Enter-VmfDocumentFileLock -Path $d -WaitMilliseconds 0 }
        try {
            $lock.Outcome | Should -Be 'held'
            $global:FrlTries | Should -Be 3
        }
        finally { InModuleScope VmMigrationFactory -Parameters @{ l = $lock } { param($l) Exit-VmfDocumentFileLock -Lock $l } }
    }

    It 'a file nobody lets go of is an error after the tries, and the error names the file and the wait' {
        $global:FrlReleaseAt = 0
        $file = Join-Path $script:rp 'leases' 'stuck.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        FrlHold $file 'None'
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Read-VmfStoreText -RunPath $rp -RelPath 'leases/stuck.lease' } }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match ([regex]::Escape($file))
        $err.Exception.Message | Should -Match 'tried 5 times'
        $err.Exception.Message | Should -Match 'another process kept the file open'
        $global:FrlTries | Should -Be 4 -Because 'five tries have four pauses between them'
    }

    It 'a replace and a delete of a file nobody lets go of are errors too, with no temporary file left' {
        $global:FrlReleaseAt = 0
        $file = Join-Path $script:rp 'leases' 'stuck2.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        FrlHold $file 'Read'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Write-VmfStoreText -RunPath $rp -RelPath 'leases/stuck2.lease' -Content 'x' } } |
            Should -Throw '*tried 5 times*another process kept the file open*'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Remove-VmfStoreItem -RunPath $rp -RelPath 'leases/stuck2.lease' } } |
            Should -Throw '*tried 5 times*another process kept the file open*'
        @(Get-ChildItem (Join-Path $script:rp 'leases') -Filter '*.tmp.*').Count | Should -Be 0
        Test-Path -LiteralPath $file | Should -BeTrue
    }

    It 'a lock nobody lets go of is busy after the tries, not taken' {
        $global:FrlReleaseAt = 0
        $doc = Join-Path $script:rp 'leases' 'f.lease'
        [System.IO.File]::WriteAllText("$doc.lock", 'other')
        $lock = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Enter-VmfDocumentFileLock -Path $d -WaitMilliseconds 0 }
        $lock.Outcome | Should -Be 'busy'
        $global:FrlTries | Should -Be 4
        [System.IO.File]::ReadAllText("$doc.lock") | Should -Be 'other'
    }
}

Describe 'FILE-RACE-LOAD-1: a holder that keeps a lease for longer than one second' {
    BeforeEach { $script:rp = FrlRun }
    AfterEach {
        Get-Job -Name 'vmf-frl-hold' -ErrorAction SilentlyContinue | Wait-Job -Timeout 20 | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    It 'a read waits for it and reads the lease' {
        $file = Join-Path $script:rp 'leases' 'g.lease'
        [System.IO.File]::WriteAllText($file, '{"vmId":"g","workerId":"w1"}')
        $job = FrlHoldThread $file 'None' 1500
        $text = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Read-VmfStoreText -RunPath $rp -RelPath 'leases/g.lease' }
        $job | Wait-Job | Out-Null
        $text | Should -Match '"workerId":"w1"'
    }

    It 'a release waits for it and removes the lease' {
        $file = Join-Path $script:rp 'leases' 'h.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        $job = FrlHoldThread $file 'Read' 1500
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Remove-VmfStoreItem -RunPath $rp -RelPath 'leases/h.lease' }
        $job | Wait-Job | Out-Null
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'a renewal waits for it and replaces the lease' {
        $file = Join-Path $script:rp 'leases' 'i.lease'
        [System.IO.File]::WriteAllText($file, 'old')
        $job = FrlHoldThread $file 'Read' 1500
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Write-VmfStoreText -RunPath $rp -RelPath 'leases/i.lease' -Content 'new' }
        $job | Wait-Job | Out-Null
        [System.IO.File]::ReadAllText($file) | Should -Be 'new'
    }
}
