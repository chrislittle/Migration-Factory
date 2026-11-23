#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# FILE-BACKEND-RACE-1: the file store races its own files.
#
# A wave's watch loop reads every lease file on each pass while its workers
# create (FileShare.None), renew (a File.Move over the file) and release
# (a delete) them. On Windows each of those clashes with a plain open:
# "The process cannot access the file ... because it is being used by another
# process", or "Access to the path is denied". It failed three full test runs
# and could stop Start-VmfWave or a worker. Measured on this Windows
# (2026-10-16): a replace is refused even over a reader that allows delete, so
# the fix is a short retry on every read, replace and delete, and a file gone
# by the time it is read reads as not there.
#
# Each test holds the file from a SECOND thread, the way the other process
# does, and lets go after a short time.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # Hold $Path open from another thread for $Milliseconds, then let go.
    # Returns once the file IS held, so the caller acts inside the window.
    function Global:FbrHold([string]$Path, [string]$Share, [string]$Access, [int]$Milliseconds) {
        $flag = "$Path.held.$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $job = Start-ThreadJob -Name 'vmf-fbr-hold' -ArgumentList $Path, $Share, $Access, $Milliseconds, $flag -ScriptBlock {
            param($p, $share, $access, $ms, $flag)
            $fs = [System.IO.FileStream]::new($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]$access, [System.IO.FileShare]$share)
            try { [System.IO.File]::WriteAllText($flag, 'held'); Start-Sleep -Milliseconds $ms }
            finally { $fs.Dispose() }
        }
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $flag) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 5 }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        $job
    }
    # FILE-RACE-LOAD-1: the wait as the module sets it, put back after a test changes it.
    $script:fbrWait = InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds }
    $script:fbrTries = InModuleScope VmMigrationFactory { $script:VmfFileMinAttempts }
    function Global:FbrRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-fbr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $rp 'leases') -Force | Out-Null
        $rp
    }
}
AfterAll { Remove-Item function:FbrHold, function:FbrRun -ErrorAction SilentlyContinue }

Describe 'FILE-BACKEND-RACE-1: a file in the middle of a change is waited for, not failed' {
    BeforeEach { $script:rp = FbrRun }
    AfterEach {
        Get-Job -Name 'vmf-fbr-hold' -ErrorAction SilentlyContinue | Wait-Job -Timeout 10 | Remove-Job -Force -ErrorAction SilentlyContinue
        InModuleScope VmMigrationFactory -Parameters @{ w = $script:fbrWait; t = $script:fbrTries } { param($w, $t) $script:VmfFileWaitMilliseconds = $w; $script:VmfFileMinAttempts = $t }
        Remove-Item $script:rp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'a read while a lease is held exclusively (as it is created) waits and reads it' {
        $file = Join-Path $script:rp 'leases' 'a.lease'
        [System.IO.File]::WriteAllText($file, '{"vmId":"a","workerId":"w1"}')
        $job = FbrHold $file 'None' 'ReadWrite' 300
        $text = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Read-VmfStoreText -RunPath $rp -RelPath 'leases/a.lease' }
        $job | Wait-Job | Out-Null
        $text | Should -Match '"workerId":"w1"'
    }

    It 'a replace while another process reads the file waits and replaces it' {
        $file = Join-Path $script:rp 'leases' 'b.lease'
        [System.IO.File]::WriteAllText($file, 'old')
        # A plain reader, as Get-Content or another product's read opens it.
        $job = FbrHold $file 'Read' 'Read' 300
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Write-VmfStoreText -RunPath $rp -RelPath 'leases/b.lease' -Content 'new' }
        $job | Wait-Job | Out-Null
        [System.IO.File]::ReadAllText($file) | Should -Be 'new'
        @(Get-ChildItem (Join-Path $script:rp 'leases') -Filter '*.tmp.*').Count | Should -Be 0 -Because 'no temporary file is left behind'
    }

    It 'a state document replaced while it is read is replaced, by both writers of whole documents' {
        $file = Join-Path $script:rp 'doc.json'
        [System.IO.File]::WriteAllText($file, '{"n":1}')
        $job = FbrHold $file 'Read' 'Read' 300
        InModuleScope VmMigrationFactory -Parameters @{ f = $file } { param($f) Write-VmfJsonAtomic -Path $f -Document @{ n = 2 } }
        $job | Wait-Job | Out-Null
        ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json).n | Should -Be 2
        $job = FbrHold $file 'Read' 'Read' 300
        InModuleScope VmMigrationFactory -Parameters @{ f = $file } { param($f) Write-VmfJsonDocument -Path $f -Document @{ n = 3 } }
        $job | Wait-Job | Out-Null
        ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json).n | Should -Be 3
    }

    It 'a release while another process reads the lease waits and removes it' {
        $file = Join-Path $script:rp 'leases' 'c.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        $job = FbrHold $file 'Read' 'Read' 300
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Remove-VmfStoreItem -RunPath $rp -RelPath 'leases/c.lease' }
        $job | Wait-Job | Out-Null
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'a file gone by the time it is read reads as not there, in a folder that is there or not' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            param($rp)
            Read-VmfStoreText -RunPath $rp -RelPath 'leases/gone.lease' | Should -BeNullOrEmpty
            Read-VmfStoreText -RunPath $rp -RelPath 'nofolder/gone.json' | Should -BeNullOrEmpty
            { Remove-VmfStoreItem -RunPath $rp -RelPath 'leases/gone.lease' } | Should -Not -Throw
        }
    }

    It 'the watch loop reads its leases while a worker holds one, and still finds the expired one' {
        $old = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        $now = (Get-Date).ToUniversalTime().ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'leases' 'old.lease'), (@{ vmId = 'old'; workerId = 'w0'; heartbeatUtc = $old } | ConvertTo-Json))
        $held = Join-Path $script:rp 'leases' 'new.lease'
        [System.IO.File]::WriteAllText($held, (@{ vmId = 'new'; workerId = 'w1'; heartbeatUtc = $now } | ConvertTo-Json))
        $job = FbrHold $held 'None' 'ReadWrite' 300
        $expired = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 120) }
        $job | Wait-Job | Out-Null
        @($expired).Count | Should -Be 1
        $expired[0].vmId | Should -Be 'old'
    }

    It 'the shared reader gives exactly the text Get-Content -Raw gave: byte order marks and line ends (PLANVER-2 hashes it)' {
        $cases = @(
            @{ name = 'utf8.json'; bytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("{`r`n  `"a`": `"é`"`r`n}`r`n") }
            @{ name = 'plain.json'; bytes = [System.Text.UTF8Encoding]::new($false).GetBytes("{`n  `"a`": 1`n}`n") }
            @{ name = 'utf16.json'; bytes = [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes("{`"a`":`"b`"}") }
        )
        foreach ($c in $cases) {
            $file = Join-Path $script:rp $c.name
            [System.IO.File]::WriteAllBytes($file, $c.bytes)
            $shared = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; n = $c.name } { param($rp, $n) Read-VmfStoreText -RunPath $rp -RelPath $n }
            $shared | Should -BeExactly (Get-Content -LiteralPath $file -Raw) -Because "$($c.name) must read the same, or every saved version is a mismatch"
        }
    }

    It 'a lease released while a reader still has it open can be taken again at once, with no error' {
        # MEASURED on this Windows (2026-10-16): a delete removes the name at
        # once although a reader that allows delete still has the file open,
        # so the next create wins - correct, the lease was released. On a
        # Windows that keeps the name until the reader closes, CreateNew
        # answers "access denied" instead; Write-VmfStoreJsonExclusive reads
        # that as "held" while the file is still there, never as an error.
        $file = Join-Path $script:rp 'leases' 'd.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        # A reader that allows delete, as the shared reader opens it; the
        # delete then waits for it to close.
        $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            [System.IO.File]::Delete($file)
            $won = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
                param($rp) Write-VmfStoreJsonExclusive -RunPath $rp -RelPath 'leases/d.lease' -Document @{ vmId = 'd' }
            }
            if ([System.IO.File]::Exists($file) -and -not $won) { $won | Should -BeFalse }   # a Windows that keeps the name
            else { $won | Should -BeTrue -Because 'the lease was released, so the next create wins' }
        }
        finally { $fs.Dispose() }
    }

    It 'a file that stays held is still an error, after the retries' {
        $file = Join-Path $script:rp 'leases' 'stuck.lease'
        [System.IO.File]::WriteAllText($file, '{}')
        InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds = 100; $script:VmfFileMinAttempts = 1 }
        $job = FbrHold $file 'None' 'ReadWrite' 2000
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Read-VmfStoreText -RunPath $rp -RelPath 'leases/stuck.lease' } } |
            Should -Throw -Because 'a file nobody lets go of is not "not there"'
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Write-VmfStoreText -RunPath $rp -RelPath 'leases/stuck.lease' -Content 'x' } } |
            Should -Throw
        $job | Wait-Job | Out-Null
        @(Get-ChildItem (Join-Path $script:rp 'leases') -Filter '*.tmp.*').Count | Should -Be 0 -Because 'a replace that gives up removes its temporary file'
    }
}
