#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ASIDE-PUTBACK-ONE-TRY-1: on the file store, a document that a refused
# delete puts back could stay under its aside name.
#
# Remove-VmfStoreItemIfVersion moves the document aside, checks its version,
# and puts it back when the version is not the one judged. The move aside
# waits for a held file (FILE-RACE-LOAD-1); the put-back was one try. If
# another handle held the file at that moment, the put-back threw, and the
# document stayed under '<file>.removing-<ticks>-<id>', which no listing
# finds: a lease read as released, a record as deleted.
#
# Now the put-back uses the same wait as every other held-file step
# (Test-VmfFileRetryLeft and Wait-VmfFileRetry). A file still held after the
# wait is an error that names the aside file and the document, so a person
# can put it back.
#
# Each test holds the aside text from a second handle with no delete sharing
# (a rename needs it) right after the version check reads it, and lets go
# when the store has tried again a set number of times, so the tests do not
# depend on the speed of the computer.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:storeApi = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'StoreApi.ps1'
    $script:wasWait = InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds }
    $script:wasTries = InModuleScope VmMigrationFactory { $script:VmfFileMinAttempts }
}

Describe 'ASIDE-PUTBACK-ONE-TRY-1: a refused delete puts the document back while another handle holds it' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive "apo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'leases') -Force | Out-Null
        $script:file = Join-Path $script:dir 'leases' 'a.lease'
        # The text on disk is not the text judged, so the delete is refused
        # and the document must go back.
        [System.IO.File]::WriteAllText($script:file, '{"workerId":"w2"}', [System.Text.UTF8Encoding]::new($false))
        $script:judged = InModuleScope VmMigrationFactory { Get-VmfDocumentVersion -Text '{"workerId":"w1"}' }

        $global:ApoHandle = $null
        $global:ApoAside = $null
        $global:ApoTries = 0
        $global:ApoReleaseAt = 3
        # The clock bound is already spent at the first try, as for a thread
        # the computer did not run for longer than the wait.
        InModuleScope VmMigrationFactory { $script:VmfFileWaitMilliseconds = 0; $script:VmfFileMinAttempts = 5 }
        # The version check reads the aside text; then another handle opens it
        # with no delete sharing, so a rename of it is refused.
        Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared -ParameterFilter { $Path -like '*.removing-*' } {
            $text = [System.IO.File]::ReadAllText($Path)
            $global:ApoAside = $Path
            $global:ApoHandle = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $text
        }
        Mock -ModuleName VmMigrationFactory Wait-VmfFileRetry {
            $global:ApoTries++
            if ($global:ApoReleaseAt -gt 0 -and $global:ApoTries -ge $global:ApoReleaseAt -and $global:ApoHandle) { $global:ApoHandle.Dispose(); $global:ApoHandle = $null }
        }
    }
    AfterEach {
        if ($global:ApoHandle) { $global:ApoHandle.Dispose(); $global:ApoHandle = $null }
        InModuleScope VmMigrationFactory -Parameters @{ w = $script:wasWait; t = $script:wasTries } { param($w, $t) $script:VmfFileWaitMilliseconds = $w; $script:VmfFileMinAttempts = $t }
    }

    It 'the document comes back under its own name with its own text, and nothing is left aside' {
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:judged } {
            param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'leases/a.lease' -ExpectedVersion $v
        } | Should -BeFalse
        [System.IO.File]::ReadAllText($script:file) | Should -Be '{"workerId":"w2"}'
        @(Get-ChildItem (Join-Path $script:dir 'leases') -Filter '*.removing-*').Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:dir 'leases')).Count | Should -Be 1 -Because 'no lock file and no aside text is left'
        $global:ApoTries | Should -Be 3 -Because 'the put-back tried again until the other handle let go'
    }

    It 'a listing finds the document again' {
        $null = InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:judged } {
            param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'leases/a.lease' -ExpectedVersion $v
        }
        $names = InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir } { param($d) Get-VmfStoreNames -RunPath $d -Folder 'leases' }
        @($names) | Should -Contain 'a.lease'
    }

    It 'a handle nobody lets go of is an error after the tries that names the aside file and the document, and the text is not removed' {
        $global:ApoReleaseAt = 0
        $err = $null
        try {
            $null = InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:judged } {
                param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'leases/a.lease' -ExpectedVersion $v
            }
        }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $global:ApoAside | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match ([regex]::Escape($global:ApoAside))
        $err.Exception.Message | Should -Match ([regex]::Escape($script:file))
        $err.Exception.Message | Should -Match 'tried 5 times'
        $global:ApoTries | Should -Be 4 -Because 'five tries have four pauses between them'
        [System.IO.File]::Exists($global:ApoAside) | Should -BeTrue -Because 'the text is kept, so a person can put it back'
        [System.IO.File]::ReadAllText($global:ApoAside) | Should -Be '{"workerId":"w2"}'
        $lock = "$script:file.lock"
        [System.IO.File]::Exists($lock) | Should -BeFalse -Because 'the lock is let go on the error too'
    }

    It 'a newer document already in place stays, and the aside text is removed once it is let go' {
        Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared -ParameterFilter { $Path -like '*.removing-*' } {
            $text = [System.IO.File]::ReadAllText($Path)
            [System.IO.File]::WriteAllText($script:file, '{"workerId":"w3"}', [System.Text.UTF8Encoding]::new($false))
            $global:ApoHandle = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $text
        }
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:judged } {
            param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'leases/a.lease' -ExpectedVersion $v
        } | Should -BeFalse
        [System.IO.File]::ReadAllText($script:file) | Should -Be '{"workerId":"w3"}'
        @(Get-ChildItem (Join-Path $script:dir 'leases')).Count | Should -Be 1
    }
}

Describe 'ASIDE-PUTBACK-ONE-TRY-1: the put-back asks the one rule' {
    It 'the put-back is a retry loop that asks Test-VmfFileRetryLeft and names the aside file when it gives up' {
        $code = Get-VmfCodeOnly -Path $script:storeApi
        $body = [regex]::Match($code, '(?s)function Remove-VmfStoreItemIfVersion \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        ([regex]::Matches($body, 'Test-VmfFileRetryLeft\s+-')).Count | Should -Be 2 -Because 'the move aside and the put-back'
        $body | Should -Not -Match 'try\s*\{\s*\[System\.IO\.File\]::Move\(\$aside,\s*\$path\)\s*\}\s*catch' -Because 'a put-back of one try leaves the document aside'
    }
}
