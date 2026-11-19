#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CLAIM-TAKEOVER-RACE-1: two migrations could both take the claim of a
# migration that is gone, and both could then stop and change the machine.
#
# The machine claim (RUN-CLAIM-1) is the fence between migrations. A first
# claim is made with the store's create-only write, so only one creator wins.
# But a claim whose migration is gone, and a claim a person takes with -Force,
# were taken by a read, a judgement and an ordinary write. Two migrations that
# both read the dead claim both wrote their own, and both were told "claimed".
# A release read the claim, saw its own migration, and removed whatever was
# there by then - a claim another migration had just taken with -Force.
#
# Now every change to a claim after its create is one step with its check, the
# mechanism LEASE-HEARTBEAT-RACE-1 used for leases (PLANVER-2 versions):
#   a takeover   writes only if the claim is still the text it judged
#                (Write-VmfStoreTextIfVersion: If-Match on blob storage, the
#                lock file on the file backend). A refused write means another
#                migration took it: the claim is read again and judged again,
#                so the losing migration is refused with the other one's name;
#   a release    removes only the text it read (Remove-VmfStoreItemIfVersion);
#   the older name (VMID-CASE-1) has the same two rules.
#
# Each test puts the other migration in the window, on both store backends.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # Az is not installed in CI, so there is a stand-in to mock; defined before
    # the guard, which blocks it too (TEST-AZURE-GUARD-1).
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # All lower case, so the claim has one name on both backends.
    $global:CtVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01'
    # Upper case letters, so a claim also has its older name (VMID-CASE-1).
    $global:CtVmUp = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-App/providers/Microsoft.Compute/virtualMachines/App01'

    # A store in memory that answers as blob storage does: an ETag per text,
    # If-None-Match: * for a create, If-Match on a write and on a delete.
    # $global:CtOnRewrite runs once, just before a PUT that rewrites a claim
    # is judged: the other migration, between the takeover's check and its write.
    function Global:Install-CtBlobService {
        # Blob names are case sensitive, and a PowerShell hashtable is not.
        $global:CtBlobs = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:CtTags = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:CtSerial = 0
        $global:CtOnRewrite = $null
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:CtBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    if ($path -like '*.claim' -and $h['If-None-Match'] -ne '*' -and $global:CtOnRewrite) {
                        $hook = $global:CtOnRewrite
                        $global:CtOnRewrite = $null
                        & $hook
                    }
                    $there = $global:CtBlobs.ContainsKey($path)
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:CtTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:CtBlobs[$path] = [string]$Body
                    $global:CtTags[$path] = '"t' + (++$global:CtSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:CtTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:CtBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:CtTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:CtBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:CtBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:CtBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:CtBlobs[$path]; Headers = @{ ETag = $global:CtTags[$path] } }
                }
            }
        }
    }

    function Global:CtModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store per test. Live runs have a run.json; 'run-gone' has none.
    function Global:CtNewStore([string]$Backend) {
        $global:CtBackend = $Backend
        $global:CtRoot = if ($Backend -eq 'file') { Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ct-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
                         else { 'azblob://acct/cont' }
        if ($Backend -eq 'file') { [System.IO.Directory]::CreateDirectory($global:CtRoot) | Out-Null }
        foreach ($id in 'run-a', 'run-b', 'run-c', 'run-d') {
            CtModule { param($r, $i) Initialize-VmfRun -RunPath $r -RunId $i | Out-Null } @((CtRun $id), $id)
        }
    }
    function Global:CtRun([string]$Id) {
        if ($global:CtBackend -eq 'file') { return (Join-Path $global:CtRoot $Id) }
        "$global:CtRoot/$Id"
    }
    function Global:CtScope { CtModule { param($r) Get-VmfClaimScopePath -RunPath $r } @((CtRun 'run-a')) }
    function Global:CtRel([string]$VmId = $global:CtVm) { CtModule { param($v) Get-VmfClaimRelPath -VmId $v } @($VmId) }
    function Global:CtLegacyRel([string]$VmId = $global:CtVmUp) { CtModule { param($v) Get-VmfClaimLegacyRelPath -VmId $v } @($VmId) }
    # The claim as stored, read past every mock.
    function Global:CtRaw([string]$Rel = (CtRel)) {
        if ($global:CtBackend -eq 'azblob') {
            $key = 'cont/vmf-claims/' + $Rel
            if ($global:CtBlobs.ContainsKey($key)) { return $global:CtBlobs[$key] }
            return $null
        }
        $file = Join-Path $global:CtRoot 'vmf-claims' $Rel
        if ([System.IO.File]::Exists($file)) { return [System.IO.File]::ReadAllText($file) }
        $null
    }
    # A claim put in place past every mock: another migration's write.
    function Global:CtPut([string]$RunId, [string]$Rel = (CtRel), [string]$VmId = $global:CtVm) {
        $text = [ordered]@{
            schemaVersion = 1; vmId = $VmId; runId = $RunId; runPath = (CtRun $RunId)
            claimedUtc = (Get-Date).ToUniversalTime().ToString('o'); takenFrom = $null; takenBy = $null
            # So two claims put one after the other are never the same text.
            nonce = [guid]::NewGuid().ToString('N')
        } | ConvertTo-Json
        if ($global:CtBackend -eq 'azblob') {
            $key = 'cont/vmf-claims/' + $Rel
            $global:CtBlobs[$key] = $text
            $global:CtTags[$key] = '"t' + (++$global:CtSerial) + '"'
            return
        }
        $file = Join-Path $global:CtRoot 'vmf-claims' $Rel
        [System.IO.Directory]::CreateDirectory((Split-Path $file -Parent)) | Out-Null
        [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
    }
    function Global:CtHolder([string]$Rel = (CtRel)) {
        $raw = CtRaw $Rel
        if ($null -eq $raw) { return '' }
        [string]($raw | ConvertFrom-Json).runId
    }
    function Global:CtField([string]$Field, [string]$Rel = (CtRel)) { [string]((CtRaw $Rel) | ConvertFrom-Json).$Field }
    # Runs $global:CtInject once, on the Nth read of a claim whose name is
    # like $Like, after the text is read: the other migration acts between
    # that read and what the caller does next.
    function Global:CtInjectOnRead([int]$At, [string]$Like = '*.claim') {
        $global:CtReads = 0
        $global:CtInjectAt = $At
        $global:CtLike = $Like
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -like '*.claim' } {
            $text = CtRaw $RelPath
            if ($RelPath -clike $global:CtLike) {
                $global:CtReads++
                if ($global:CtReads -eq $global:CtInjectAt -and $global:CtInject) {
                    $hook = $global:CtInject
                    $global:CtInject = $null
                    & $hook
                }
            }
            $text
        }
    }
    function Global:CtClaim([string]$RunId, [switch]$Force, [string]$VmId = $global:CtVm) {
        CtModule { param($r, $v, $i, $f) New-VmfVmClaim -RunPath $r -VmId $v -RunId $i -Force:$f -TakenBy 'operator@example.com' } @((CtRun $RunId), $VmId, $RunId, [bool]$Force)
    }
    function Global:CtRelease([string]$RunId, [string]$VmId = $global:CtVm) {
        CtModule { param($r, $v, $i) Remove-VmfVmClaim -RunPath $r -VmId $v -RunId $i } @((CtRun $RunId), $VmId, $RunId)
    }
    function Global:CtCleanup {
        CtModule { $script:VmfDocumentLockWaitMilliseconds = 10000 }
        if ($global:CtBackend -eq 'file' -and $global:CtRoot -and (Test-Path $global:CtRoot)) { Remove-Item $global:CtRoot -Recurse -Force }
    }
}

AfterAll {
    Remove-Item 'function:\Install-CtBlobService', 'function:\CtModule', 'function:\CtNewStore', 'function:\CtRun', 'function:\CtScope', 'function:\CtRel',
        'function:\CtLegacyRel', 'function:\CtRaw', 'function:\CtPut', 'function:\CtHolder', 'function:\CtField', 'function:\CtInjectOnRead',
        'function:\CtClaim', 'function:\CtRelease', 'function:\CtCleanup', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable CtVm, CtVmUp, CtBlobs, CtTags, CtSerial, CtOnRewrite, CtBackend, CtRoot, CtReads, CtInjectAt, CtLike, CtInject,
        CtOther, CtMoved, CtLine, CtOlderSeen -Scope Global -ErrorAction SilentlyContinue
}

Describe 'CLAIM-TAKEOVER-RACE-1: one dead claim, two migrations, one holder (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        Install-CtBlobService
        CtNewStore $backend
        $global:CtInject = $null
        $global:CtOther = $null
        # The claim of a migration that was deleted.
        CtPut 'run-gone'
    }
    AfterEach { CtCleanup }

    It 'another migration takes the dead claim between this one''s read and its write: only the other one holds it, and this one is refused with its name' {
        $global:CtInject = { $global:CtOther = CtClaim 'run-c' }
        CtInjectOnRead 1
        $mine = CtClaim 'run-b'
        $global:CtReads | Should -BeGreaterOrEqual 1 -Because 'the other migration acted in the window'
        $global:CtOther.Granted | Should -BeTrue
        $mine.Granted | Should -BeFalse -Because 'two migrations must never both be told they hold one machine'
        $mine.HeldBy | Should -Be 'run-c'
        $mine.Detail | Should -Match "run 'run-c'"
        CtHolder | Should -Be 'run-c' -Because 'the takeover wrote nothing over the claim the other migration took'
    }

    It 'without anybody in the window, the takeover gives the dead claim to this migration, and says whose it was' {
        $mine = CtClaim 'run-b'
        $mine.Granted | Should -BeTrue
        $mine.Detail | Should -Match "run-gone"
        CtHolder | Should -Be 'run-b'
        CtField 'takenFrom' | Should -Be 'run-gone'
        CtField 'takenBy' | Should -Be 'automatic'
    }

    It 'a forced takeover that meets another migration''s takeover in its window takes the claim from that migration, and the record names it' {
        CtPut 'run-a'
        $global:CtInject = { $global:CtOther = CtClaim 'run-c' -Force }
        CtInjectOnRead 1
        $mine = CtClaim 'run-b' -Force
        $global:CtOther.Granted | Should -BeTrue
        $mine.Granted | Should -BeTrue -Because 'a person took the machine on purpose'
        CtHolder | Should -Be 'run-b'
        CtField 'takenFrom' | Should -Be 'run-c' -Because 'the record says who the claim was really taken from, not who held it at the first read'
    }

    It 'a claim that changes at each try is not taken, and the refusal says so' {
        # Each read sees a dead claim, and each write meets a new one.
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -like '*.claim' } {
            $text = CtRaw $RelPath
            CtPut 'run-gone'
            $text
        }
        $mine = CtClaim 'run-b'
        $mine.Granted | Should -BeFalse
        $mine.Detail | Should -Match 'changed each time'
        CtHolder | Should -Be 'run-gone'
    }

    It 'a first claim: two migrations that create it, one after the other, give it to the first one only' {
        CtModule { param($s, $rel) Remove-VmfStoreItem -RunPath $s -RelPath $rel } @((CtScope), (CtRel))
        CtRaw | Should -BeNullOrEmpty
        (CtClaim 'run-a').Granted | Should -BeTrue
        $second = CtClaim 'run-b'
        $second.Granted | Should -BeFalse
        $second.HeldBy | Should -Be 'run-a'
        CtHolder | Should -Be 'run-a'
    }
}

Describe 'CLAIM-TAKEOVER-RACE-1: the other migration acts between the takeover''s own check and its write' {
    BeforeEach {
        Install-CtBlobService
        $global:CtInject = $null
        $global:CtOther = $null
        $global:CtMoved = $false
        CtModule { $script:VmfDocumentLockWaitMilliseconds = 300 }
    }
    AfterEach { CtCleanup }

    It 'file: the other migration waits for the takeover''s lock, so exactly one of the two holds the machine' {
        CtNewStore 'file'
        CtPut 'run-gone'
        # The takeover's write is the move of its new text over the claim; the
        # other migration acts just before it.
        Mock -ModuleName VmMigrationFactory Move-VmfFileReplace -ParameterFilter { $Destination -like '*.claim' -and -not $global:CtMoved } {
            $global:CtMoved = $true
            $global:CtOther = CtClaim 'run-c'
            [System.IO.File]::Move($Source, $Destination, $true)
        }
        $mine = CtClaim 'run-b'
        $global:CtMoved | Should -BeTrue -Because 'the other migration acted in the window'
        @(@($mine, $global:CtOther) | Where-Object { $_.Granted }).Count | Should -Be 1 -Because 'two migrations must never both hold one machine'
        $winner = if ($mine.Granted) { 'run-b' } else { 'run-c' }
        CtHolder | Should -Be $winner -Because 'the migration that was told it holds the machine is the one the claim names'
    }

    It 'azblob: a takeover between the check and the PUT fails the If-Match, and the other migration keeps the claim' {
        CtNewStore 'azblob'
        CtPut 'run-gone'
        $global:CtOnRewrite = { CtPut 'run-c' }
        $mine = CtClaim 'run-b'
        $global:CtOnRewrite | Should -BeNullOrEmpty -Because 'the other migration acted in the window'
        $mine.Granted | Should -BeFalse
        $mine.Detail | Should -Match "run 'run-c'"
        CtHolder | Should -Be 'run-c'
    }
}

Describe 'CLAIM-TAKEOVER-RACE-1: a release removes only the claim it read (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        Install-CtBlobService
        CtNewStore $backend
        $global:CtInject = $null
        CtModule { $script:VmfDocumentLockWaitMilliseconds = 300 }
        (CtClaim 'run-a').Granted | Should -BeTrue
    }
    AfterEach { CtCleanup }

    It 'a forced takeover between the release''s read and its removal: the new claim stays, and the release says who holds it' {
        $global:CtInject = { CtPut 'run-b' }
        CtInjectOnRead 1
        $out = CtRelease 'run-a'
        $global:CtReads | Should -BeGreaterOrEqual 1 -Because 'the takeover happened in the window'
        $out.Released | Should -BeFalse
        $out.Detail | Should -Match 'run-b'
        CtHolder | Should -Be 'run-b' -Because 'a release removes only the claim it read'
    }

    It 'without anybody in the window, the release removes this migration''s claim' {
        (CtRelease 'run-a').Released | Should -BeTrue
        CtRaw | Should -BeNullOrEmpty
        (CtClaim 'run-b').Detail | Should -Be 'claimed' -Because 'the machine is free for the next migration'
    }

    It 'a claim that changes at each try of the release is not removed, and the release says so' {
        # Each read sees this migration's claim, and each removal meets a new text.
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -like '*.claim' } {
            $text = CtRaw $RelPath
            CtPut 'run-a'
            $text
        }
        $out = CtRelease 'run-a'
        $out.Released | Should -BeFalse -Because 'a release that removed nothing must not say it released the machine'
        $out.Detail | Should -Match 'changed each time'
        CtHolder | Should -Be 'run-a'
    }
    It 'a release by a migration that does not hold the claim removes nothing' {
        (CtRelease 'run-b').Released | Should -BeFalse
        CtHolder | Should -Be 'run-a'
    }
}

Describe 'CLAIM-TAKEOVER-RACE-1: the older name of a claim (VMID-CASE-1, blob storage)' {
    BeforeEach {
        Install-CtBlobService
        CtNewStore 'azblob'
        $global:CtInject = $null
        CtLegacyRel | Should -Not -BeNullOrEmpty -Because 'the test needs a machine whose claim has two names'
    }
    AfterEach { CtCleanup }

    It 'a migration on older code takes the older name between this one''s read and its write: this one is refused, and gives the new name back' {
        CtPut 'run-gone' (CtLegacyRel) $global:CtVmUp
        # Read 1 of the older name is the claim's first look; read 2 is the
        # look before it takes the older name, and the other one acts after it.
        $global:CtInject = { CtPut 'run-c' (CtLegacyRel) $global:CtVmUp }
        CtInjectOnRead 2 (CtLegacyRel)
        $mine = CtClaim 'run-b' -VmId $global:CtVmUp
        $global:CtReads | Should -BeGreaterOrEqual 2 -Because 'the other migration acted in the window'
        $mine.Granted | Should -BeFalse
        $mine.Detail | Should -Match "run 'run-c'"
        CtHolder (CtLegacyRel) | Should -Be 'run-c'
        CtRaw (CtRel $global:CtVmUp) | Should -BeNullOrEmpty -Because 'a refused migration holds neither name'
    }

    It 'the new name given back after a refusal is removed only as read: a claim taken on it in the window stays' {
        CtPut 'run-c' (CtLegacyRel) $global:CtVmUp
        # run-c is alive and holds the older name, so this migration's grant of
        # the new name is given back. Read 1 of the new name is that give-back.
        Mock -ModuleName VmMigrationFactory Test-VmfClaimHolderAlive { $false } -ParameterFilter { [string]$Claim.runId -eq 'run-c' -and -not $global:CtOlderSeen }
        $global:CtOlderSeen = $false
        $global:CtInject = { CtPut 'run-d' (CtRel $global:CtVmUp) $global:CtVmUp }
        CtInjectOnRead 1 (CtRel $global:CtVmUp)
        # At the first look, run-c's older claim reads as dead; at the take of
        # the older name it is alive, so this migration loses.
        Mock -ModuleName VmMigrationFactory Write-VmfStoreJsonExclusive -ParameterFilter { $RelPath -ceq (CtLegacyRel) } { $global:CtOlderSeen = $true; $false }
        $mine = CtClaim 'run-b' -VmId $global:CtVmUp
        $mine.Granted | Should -BeFalse
        $global:CtReads | Should -BeGreaterOrEqual 1 -Because 'the other migration acted in the window'
        CtHolder (CtRel $global:CtVmUp) | Should -Be 'run-d' -Because 'the give-back removes only the claim this migration wrote'
    }

    It 'an older name that changes at each try is not taken: this migration is refused, and gives the new name back' {
        CtPut 'run-gone' (CtLegacyRel) $global:CtVmUp
        # Each read of the older name sees a dead claim, and each write meets a new one.
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -ceq (CtLegacyRel) } {
            $text = CtRaw $RelPath
            CtPut 'run-gone' (CtLegacyRel) $global:CtVmUp
            $text
        }
        $mine = CtClaim 'run-b' -VmId $global:CtVmUp
        $mine.Granted | Should -BeFalse -Because 'unknown never lets two migrations change one machine'
        $mine.Detail | Should -Match 'changed each time'
        CtRaw (CtRel $global:CtVmUp) | Should -BeNullOrEmpty -Because 'a refused migration holds neither name'
    }
    It 'a release that judged the older name dead leaves it when a migration on older code takes it in the window' {
        CtPut 'run-gone' (CtLegacyRel) $global:CtVmUp
        $global:CtInject = { CtPut 'run-c' (CtLegacyRel) $global:CtVmUp }
        CtInjectOnRead 1 (CtLegacyRel)
        $null = CtRelease 'run-b' -VmId $global:CtVmUp
        $global:CtReads | Should -BeGreaterOrEqual 1 -Because 'the other migration acted in the window'
        CtHolder (CtLegacyRel) | Should -Be 'run-c' -Because 'a release removes only the claim it judged'
    }
}

Describe 'CLAIM-TAKEOVER-RACE-1: two migrations take a gone migration''s older-name claim at once (<backend>, other one at read <at>)' -ForEach @(
    @{ backend = 'file'; at = 1 }, @{ backend = 'file'; at = 2 }, @{ backend = 'azblob'; at = 1 }, @{ backend = 'azblob'; at = 2 }
) {
    BeforeEach {
        Install-CtBlobService
        CtNewStore $backend
        $global:CtInject = $null
        $global:CtOther = $null
        CtModule { $script:VmfDocumentLockWaitMilliseconds = 300 }
        # The older-name claim of a migration that was deleted, and no new name.
        CtPut 'run-gone' (CtLegacyRel) $global:CtVmUp
    }
    AfterEach { CtCleanup }

    It 'exactly one wins, the other is refused with its name, and the older name names the winner' {
        # Read 1 of the older name is the first look; read 2 is the look before
        # the older name is taken. The other migration acts after that read.
        $global:CtInject = { $global:CtOther = CtClaim 'run-c' -VmId $global:CtVmUp }
        CtInjectOnRead $at (CtLegacyRel)
        $mine = CtClaim 'run-b' -VmId $global:CtVmUp
        $global:CtOther | Should -Not -BeNullOrEmpty -Because 'the other migration acted in the window'
        $granted = @(@($mine, $global:CtOther) | Where-Object { $_.Granted })
        $granted.Count | Should -Be 1 -Because 'two migrations must never both hold one machine'
        $winner = if ($mine.Granted) { 'run-b' } else { 'run-c' }
        $loser = if ($mine.Granted) { $global:CtOther } else { $mine }
        $loser.Detail | Should -Match "run '$winner'"
        CtHolder (CtLegacyRel) | Should -Be $winner -Because 'a migration on older code reads only the older name'
        CtHolder (CtRel $global:CtVmUp) | Should -Be $winner
    }
}
Describe 'CLAIM-TAKEOVER-RACE-1: a worker that loses the claim takes no lease' {
    BeforeEach {
        Install-CtBlobService
        CtNewStore 'file'
        CtPut 'run-gone'
        $global:CtInject = $null
        $global:CtLine = $null
    }
    AfterEach { CtCleanup }

    It 'the wave''s worker skips the machine before any change, and the run history names the other migration' {
        $entry = [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $global:CtVm; wave = 'w1'; ring = 'lab'; appGroup = 'app01'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; availabilitySetId = '' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]@{ capacityGate = 'BestEffort'; keepSnapshotDays = 7 }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine -ParameterFilter { $Step -eq 'claim' } { $global:CtLine = $Detail }
        $global:CtInject = { $null = CtClaim 'run-c' }
        CtInjectOnRead 1
        $got = CtModule { param($r, $e) Get-VmfNextWaveVm -RunPath $r -Plan ([pscustomobject]@{ schemaVersion = 1; entries = @($e) }) -Wave 'w1' -WorkerId 'w1' } @((CtRun 'run-b'), $entry)
        $got | Should -BeNullOrEmpty -Because 'the worker takes no machine another migration holds'
        CtModule { param($r, $v) Get-VmfLeaseInfo -RunPath $r -VmId $v } @((CtRun 'run-b'), $global:CtVm) | Should -BeNullOrEmpty
        $global:CtLine | Should -Match "run 'run-c'"
        CtHolder | Should -Be 'run-c'
    }
}
