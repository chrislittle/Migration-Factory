#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LEASE-HEARTBEAT-RACE-1: a lease heartbeat could write over a hold another
# job had just taken.
#
# Update-VmfLeaseHeartbeat read the lease, checked the holder, and wrote the
# whole lease back with an ordinary write. A takeover between the read and the
# write - the wave watchdog removes an expired lease and another worker creates
# it, or a restore takes it over - was written over: the old holder's name came
# back, and two jobs both believed they held the machine.
#
# Now every change to a lease after its create is one step with its check, the
# product's own mechanism (PLANVER-2 versions, PLAN-WRITE-RACE-1):
#   a renewal      writes only if the lease is still the text it read
#                  (Write-VmfStoreTextIfVersion: If-Match on blob storage, the
#                  lock file on the file backend); a refused write is a lost
#                  lease, said with 'abandon this VM' - the words the state
#                  machine treats as fencing, never as a step failure;
#   a removal      removes only the text it read (Remove-VmfStoreItemIfVersion),
#                  and on the file backend it waits for the lock a renewal
#                  holds, so nothing removes a lease between a renewal's check
#                  and its write;
#   the watchdog   removes a lease only as it judged it expired.
#
# Each test puts the other job in the window, on both store backends.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # Az is not installed in CI, so there is a stand-in to mock; defined before
    # the guard, which blocks it too (TEST-AZURE-GUARD-1).
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $global:LhVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01'

    # A store in memory that answers as blob storage does: an ETag per text,
    # If-None-Match: * for a create, If-Match on a write and on a delete.
    # $global:LhOnRewrite runs once, just before a PUT that rewrites a lease
    # is judged: the other job, between the renewal's check and its write.
    function Global:Install-LhBlobService {
        $global:LhBlobs = @{}
        $global:LhTags = @{}
        $global:LhSerial = 0
        $global:LhOnRewrite = $null
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:LhBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    if ($path -like '*/leases/*' -and $h['If-None-Match'] -ne '*' -and $global:LhOnRewrite) {
                        $hook = $global:LhOnRewrite
                        $global:LhOnRewrite = $null
                        & $hook
                    }
                    $there = $global:LhBlobs.ContainsKey($path)
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:LhTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:LhBlobs[$path] = [string]$Body
                    $global:LhTags[$path] = '"t' + (++$global:LhSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:LhTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:LhBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:LhTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:LhBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:LhBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:LhBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:LhBlobs[$path]; Headers = @{ ETag = $global:LhTags[$path] } }
                }
            }
        }
    }

    function Global:LhNewRun([string]$Backend) {
        $rp = if ($Backend -eq 'file') { Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lh-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
              else { 'azblob://acct/cont/lh-run' }
        & (Get-Module VmMigrationFactory) { param($r) Initialize-VmfRun -RunPath $r -RunId 'lh-test' | Out-Null } $rp
        $global:LhRun = $rp
        $rp
    }
    function Global:LhRel { & (Get-Module VmMigrationFactory) { param($v) Get-VmfLeaseRelPath -VmId $v } $global:LhVm }
    # The lease as stored, read past every mock.
    function Global:LhRaw {
        $rel = LhRel
        if ($global:LhRun -like 'azblob://*') {
            $key = 'cont/lh-run/' + $rel
            if ($global:LhBlobs.ContainsKey($key)) { return $global:LhBlobs[$key] }
            return $null
        }
        $file = Join-Path $global:LhRun ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.File]::Exists($file)) { return [System.IO.File]::ReadAllText($file) }
        $null
    }
    # Another job's lease, put in place past every mock: the end of a takeover
    # (removed, then created again), or the holder's own renewal.
    function Global:LhPut([string]$Holder, [int]$AgeSeconds = 0) {
        $when = (Get-Date).ToUniversalTime().AddSeconds(-$AgeSeconds).ToString('o')
        $text = [ordered]@{ vmId = $global:LhVm; workerId = $Holder; acquiredUtc = $when; heartbeatUtc = $when } | ConvertTo-Json
        $rel = LhRel
        if ($global:LhRun -like 'azblob://*') {
            $key = 'cont/lh-run/' + $rel
            $global:LhBlobs[$key] = $text
            $global:LhTags[$key] = '"t' + (++$global:LhSerial) + '"'
            return
        }
        $file = Join-Path $global:LhRun ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        [System.IO.Directory]::CreateDirectory((Split-Path $file -Parent)) | Out-Null
        [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
    }
    function Global:LhHolder {
        $raw = LhRaw
        if ($null -eq $raw) { return '' }
        [string]($raw | ConvertFrom-Json).workerId
    }
    # Seconds since the stored heartbeat, from the text: ConvertFrom-Json would
    # turn the time into a date value in the local zone.
    function Global:LhAge {
        if ([string](LhRaw) -notmatch '"heartbeatUtc":\s*"([^"]+)"') { throw 'no heartbeat in the lease' }
        $when = [datetime]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        ((Get-Date).ToUniversalTime() - $when).TotalSeconds
    }
    # Runs $global:LhInject on the Nth read of the lease, after the text is
    # read: the other job acts between that read and what the caller does next.
    function Global:LhInjectOnRead([int]$At) {
        $global:LhReads = 0
        $global:LhInjectAt = $At
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -like 'leases/*' } {
            $global:LhReads++
            $text = LhRaw
            if ($global:LhReads -eq $global:LhInjectAt -and $global:LhInject) { & $global:LhInject }
            $text
        }
    }
    function Global:LhModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }
}

AfterAll {
    Remove-Item 'function:\Install-LhBlobService', 'function:\LhNewRun', 'function:\LhRel', 'function:\LhRaw', 'function:\LhPut',
        'function:\LhHolder', 'function:\LhAge', 'function:\LhInjectOnRead', 'function:\LhModule', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable LhVm, LhRun, LhBlobs, LhTags, LhSerial, LhOnRewrite, LhReads, LhInjectAt, LhInject, LhW2, LhMoved -Scope Global -ErrorAction SilentlyContinue
}

Describe 'LEASE-HEARTBEAT-RACE-1: a renewal never writes over a hold another job took (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        Install-LhBlobService
        LhNewRun $backend | Out-Null
        $global:LhInject = $null
        LhModule { param($r, $v) $null = New-VmfLease -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm)
    }
    AfterEach {
        if ($global:LhRun -notlike 'azblob://*' -and (Test-Path $global:LhRun)) { Remove-Item $global:LhRun -Recurse -Force }
    }

    It 'a takeover between the renewal''s read and its write: the new holder stays, and the renewal says the lease is lost' {
        $global:LhInject = { LhPut 'w2' }
        LhInjectOnRead 1
        { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw '*abandon this VM*'
        $global:LhReads | Should -BeGreaterOrEqual 1 -Because 'the takeover happened in the window'
        LhHolder | Should -Be 'w2' -Because 'the renewal wrote nothing over the new hold'
    }

    It 'without anybody in the window, the renewal writes a new heartbeat for its own holder' {
        LhPut 'w1' 300
        LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm)
        LhHolder | Should -Be 'w1'
        LhAge | Should -BeLessThan 60
    }

    It 'a renewal by a holder that is not the one in the lease writes nothing' {
        LhPut 'w2' 300
        { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw '*abandon this VM*'
        LhHolder | Should -Be 'w2'
        LhAge | Should -BeGreaterThan 200
    }

    It 'the owner''s removal after a takeover between its check and its delete leaves the new holder' {
        $global:LhInject = { LhPut 'w2' }
        LhInjectOnRead 1
        { LhModule { param($r, $v) Remove-VmfLease -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw '*Refusing*'
        LhHolder | Should -Be 'w2' -Because 'a removal removes only the lease it checked'
    }

    It 'a forced removal (a stopped run) that meets a renewal in its window still removes the lease' {
        $global:LhInject = { LhPut 'w1' }
        LhInjectOnRead 1
        LhModule { param($r, $v) Remove-VmfLease -RunPath $r -VmId $v -Force } @($global:LhRun, $global:LhVm)
        LhRaw | Should -BeNullOrEmpty -Because 'a person stopped the run, and the removal reads the lease again'
    }

    It 'the watchdog removes a lease whose heartbeat is older than the limit' {
        LhPut 'w1' 600
        LhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 120 } @($global:LhRun, $global:LhVm) | Should -BeTrue
        LhRaw | Should -BeNullOrEmpty
    }

    It 'the watchdog keeps a lease whose heartbeat is inside the limit' {
        LhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 120 } @($global:LhRun, $global:LhVm) | Should -BeFalse
        LhHolder | Should -Be 'w1'
    }

    It 'the watchdog judged the lease expired, and the holder renewed it before the removal: the renewed lease stays' {
        LhPut 'w1' 600
        Mock -ModuleName VmMigrationFactory Test-VmfMachineLeaseExpired { LhPut 'w1'; $true }
        LhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 120 } @($global:LhRun, $global:LhVm) | Should -BeFalse
        LhHolder | Should -Be 'w1'
        LhAge | Should -BeLessThan 60 -Because 'the lease the watchdog did not judge is the one left'
    }

    It 'a store error that left the lease as it was is a store error, not a lost lease' {
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'leases/*' } { throw 'Store write failed: HTTP 503 ServerBusy' }
        $err = $null
        try { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) }
        catch { $err = $_.Exception.Message }
        $err | Should -Match 'HTTP 503' -Because 'the step that called it fails and is tried again, as before'
        $err | Should -Not -Match 'abandon this VM'
        LhHolder | Should -Be 'w1'
    }

    It 'a write that landed but lost its answer is a renewal' {
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'leases/*' } {
            LhModule { param($r, $rel, $c) Write-VmfStoreText -RunPath $r -RelPath $rel -Content $c } @($RunPath, $RelPath, $Content)
            throw 'Store write failed: the connection closed before the answer'
        }
        LhPut 'w1' 300
        { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } | Should -Not -Throw
        LhAge | Should -BeLessThan 60
    }

    It 'a store error after which another job holds the lease is a lost lease' {
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'leases/*' } {
            LhPut 'w2'
            throw 'Store write failed: HTTP 500'
        }
        { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw '*abandon this VM*'
        LhHolder | Should -Be 'w2'
    }
}

Describe 'LEASE-HEARTBEAT-RACE-1: the other job acts between the renewal''s own check and its write' {
    BeforeEach {
        Install-LhBlobService
        $global:LhInject = $null
        $global:LhW2 = $null
        $global:LhMoved = $false
        LhModule { $script:VmfDocumentLockWaitMilliseconds = 300 }
    }
    AfterEach {
        LhModule { $script:VmfDocumentLockWaitMilliseconds = 10000 }
        if ($global:LhRun -and $global:LhRun -notlike 'azblob://*' -and (Test-Path $global:LhRun)) { Remove-Item $global:LhRun -Recurse -Force }
    }

    It 'file: <what> waits for the renewal''s lock, so the new worker gets no lease and one job holds the machine' -ForEach @(
        @{ what = 'the watchdog''s removal'; takeover = {
            $global:LhW2 = LhModule { param($r, $v)
                $null = Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 120
                New-VmfLease -RunPath $r -VmId $v -WorkerId 'w2' } @($global:LhRun, $global:LhVm) } }
        @{ what = 'a forced removal'; takeover = {
            $global:LhW2 = LhModule { param($r, $v)
                Remove-VmfLease -RunPath $r -VmId $v -Force -WarningAction SilentlyContinue
                New-VmfLease -RunPath $r -VmId $v -WorkerId 'w2' } @($global:LhRun, $global:LhVm) } }
    ) {
        LhNewRun 'file' | Out-Null
        LhPut 'w1' 600
        $global:LhInject = $takeover
        # The renewal's write is the move of its new text over the lease; the
        # other job acts just before it.
        Mock -ModuleName VmMigrationFactory Move-VmfFileReplace -ParameterFilter { $Destination -like '*.lease' -and -not $global:LhMoved } {
            $global:LhMoved = $true
            & $global:LhInject
            [System.IO.File]::Move($Source, $Destination, $true)
        }
        $thrown = $null
        try { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) }
        catch { $thrown = $_.Exception.Message }
        $global:LhMoved | Should -BeTrue -Because 'the other job acted in the window'
        if ($global:LhW2) {
            LhHolder | Should -Be 'w2' -Because 'a worker that was given the lease must be the one the lease names'
            $thrown | Should -Match 'abandon this VM'
        }
        else {
            LhHolder | Should -Be 'w1'
            $thrown | Should -BeNullOrEmpty
        }
        $global:LhW2 | Should -BeNullOrEmpty -Because 'the removal waited for the renewal, and then found a renewed lease'
    }

    It 'azblob: a takeover between the renewal''s check and its PUT fails the If-Match, and the new holder stays' {
        LhNewRun 'azblob' | Out-Null
        LhPut 'w1' 600
        $global:LhOnRewrite = { LhPut 'w2' }
        { LhModule { param($r, $v) Update-VmfLeaseHeartbeat -RunPath $r -VmId $v -WorkerId 'w1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw '*abandon this VM*'
        $global:LhOnRewrite | Should -BeNullOrEmpty -Because 'the takeover happened in the window'
        LhHolder | Should -Be 'w2'
    }
}

Describe 'LEASE-HEARTBEAT-RACE-1: a version-checked removal waits for the file backend''s write lock' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lh-lock-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        LhModule { param($d) Initialize-VmfStore -RunPath $d } @($script:dir)
        $script:doc = Join-Path $script:dir 'state' 'one.json'
        [System.IO.File]::WriteAllText($script:doc, '{"a":1}', [System.Text.UTF8Encoding]::new($false))
        $script:ver = LhModule { Get-VmfDocumentVersion -Text '{"a":1}' }
        LhModule { $script:VmfDocumentLockWaitMilliseconds = 300 }
    }
    AfterEach {
        LhModule { $script:VmfDocumentLockWaitMilliseconds = 10000 }
        if (Test-Path $script:dir) { Remove-Item $script:dir -Recurse -Force }
    }

    It 'a lock a writer holds now: nothing is removed, and the document stays as it is' {
        [System.IO.File]::WriteAllText("$script:doc.lock", 'another-writer')
        LhModule { param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'state/one.json' -ExpectedVersion $v } @($script:dir, $script:ver) | Should -BeFalse
        [System.IO.File]::Exists($script:doc) | Should -BeTrue
        [System.IO.File]::ReadAllText("$script:doc.lock") | Should -Be 'another-writer' -Because 'only the writer that holds a lock removes it'
    }

    It 'once the writer lets go, the removal removes the text it judged, and leaves no lock' {
        LhModule { param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'state/one.json' -ExpectedVersion $v } @($script:dir, $script:ver) | Should -BeTrue
        [System.IO.File]::Exists($script:doc) | Should -BeFalse
        [System.IO.File]::Exists("$script:doc.lock") | Should -BeFalse
    }

    It 'a lock older than a minute is from a writer that stopped: it is taken over, and the removal goes on' {
        [System.IO.File]::WriteAllText("$script:doc.lock", 'a-writer-that-stopped')
        [System.IO.File]::SetLastWriteTimeUtc("$script:doc.lock", [DateTime]::UtcNow.AddMinutes(-3))
        LhModule { param($d, $v) Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'state/one.json' -ExpectedVersion $v } @($script:dir, $script:ver) | Should -BeTrue
        [System.IO.File]::Exists($script:doc) | Should -BeFalse
        [System.IO.File]::Exists("$script:doc.lock") | Should -BeFalse
    }
}

Describe 'LEASE-HEARTBEAT-RACE-1: what each job does when its renewal loses' {
    BeforeEach {
        Install-LhBlobService
        LhNewRun 'file' | Out-Null
        $global:LhInject = $null
    }
    AfterEach {
        LhModule { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if (Test-Path $global:LhRun) { Remove-Item $global:LhRun -Recurse -Force }
    }

    It 'a restore that resumes its own hold, and loses it as it renews, is refused with the sentence that names the new holder' {
        LhPut 'restore:op-1'
        Mock -ModuleName VmMigrationFactory Update-VmfLeaseHeartbeat {
            LhPut 'lh-w2'
            throw "Lease for '$VmId' was taken by 'lh-w2' while '$WorkerId' renewed it - abandon this VM."
        }
        { LhModule { param($r, $v) Enter-VmfMachineLease -RunPath $r -VmId $v -Holder 'restore:op-1' } @($global:LhRun, $global:LhVm) } |
            Should -Throw "A wave migrates 'app01' now*"
        LhHolder | Should -Be 'lh-w2'
    }

    It 'a restore''s heartbeat that loses the race never throws, says so, and leaves the new holder' {
        LhModule { param($r, $v) $null = Enter-VmfMachineLease -RunPath $r -VmId $v -Holder 'restore:op-1' } @($global:LhRun, $global:LhVm)
        LhModule { $script:VmfMachineLeaseToken.Last = [datetime]::MinValue }
        # Read 1 is the heartbeat's own look at the holder; read 2 is the
        # renewal's read, and the takeover lands after it.
        $global:LhInject = { LhPut 'lh-w2' }
        LhInjectOnRead 2
        $warned = LhModule { Invoke-VmfMachineLeaseHeartbeat -WarningVariable wv -WarningAction SilentlyContinue; @($wv | ForEach-Object { [string]$_ }) }
        $global:LhReads | Should -BeGreaterOrEqual 2 -Because 'the takeover happened in the window'
        LhHolder | Should -Be 'lh-w2' -Because 'the restore finishes what it started, but never writes over the new hold'
        ($warned -join ' ') | Should -Match 'lh-w2'
    }

    It 'the wave watchdog removes a lease only as it judged it, and says nothing about a lease it left' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match 'if \(-not \(Remove-VmfExpiredLease -RunPath \$RunPath -VmId \$expired\.vmId -TimeoutSeconds \$LeaseTimeoutSeconds\)\) \{ continue \}'
        $code | Should -Not -Match 'Remove-VmfLease[^\n]*\$expired'
    }
}
