#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
SCHEDULE-PASS-DUE-1: the five-minute schedule pass reads only what is due.

MEASURED (2026-11-10): the pass read every run in the store - about 530
store calls and its whole 210-second budget, every pass - though almost no run
had anything due. It runs in the web service beside the dashboard's calls.

These tests hold the record of the runs to check (schedule-due.json): its
rules, its version-checked writes on both store backends, the facts that keep
a run in it (Get-VmfRunScheduleNeed), the three service paths that mark a run,
and the store calls of a pass before and after, counted on a store on disk.
SchedulePass.Tests.ps1 runs the pass itself.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI, so the service tests mock stand-ins, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'scheddue'
    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'
    $script:dueSchema = Join-Path $script:repoRoot 'schemas' 'schedule-due.schema.json'
    $script:at = [datetime]::new(2026, 11, 10, 10, 0, 0, [System.DateTimeKind]::Utc)
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    $script:approver = [pscustomobject]@{ Identity = 'approver@example.com'; Roles = @('Vmf.Approver') }
    $script:NewRoot = { $r = Join-Path $script:temp "d-$([guid]::NewGuid().ToString('N').Substring(0,8))"; New-Item -ItemType Directory -Path $r -Force | Out-Null; $r }
    $script:DueOf = { param($root) Get-Content (Join-Path $root 'schedule-due.json') -Raw | ConvertFrom-Json -DateKind String }
    $script:Entry = { param([string]$id, [string]$mark = 'm1', [string]$hold = $null, [string]$next = $null, [string]$reason = 'engine')
        [ordered]@{ runId = $id; markId = $mark; reason = $reason; markedUtc = '2026-11-10T09:00:00.0000000Z'; holdUntilUtc = $(if ($hold) { $hold } else { $null }); nextUtc = $(if ($next) { $next } else { $null }) }
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_STORE_PATH, Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
}

Describe 'SCHEDULE-PASS-DUE-1: the rules of the record, pure' {
    It 'a run id the record may hold: <Id> is <Ok>' -ForEach @(
        @{ Id = 'r1'; Ok = $true }
        @{ Id = 'contoso-exit/wave-plan-4'; Ok = $true }
        @{ Id = 'a/b/c'; Ok = $false }
        @{ Id = '../r1'; Ok = $false }
        @{ Id = 'p/..'; Ok = $false }
        @{ Id = '/r1'; Ok = $false }
        @{ Id = 'r1/'; Ok = $false }
        @{ Id = ''; Ok = $false }
        @{ Id = ('x' * 513); Ok = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ i = $Id } { param($i) Test-VmfScheduleDueRunId -RunId $i } | Should -Be $Ok
    }

    It 'a run id with a backslash, a control character or another type is refused' {
        InModuleScope VmMigrationFactory {
            Test-VmfScheduleDueRunId -RunId ('p' + [char]0x5C + 'r') | Should -BeFalse
            Test-VmfScheduleDueRunId -RunId ('r' + [char]7) | Should -BeFalse
            Test-VmfScheduleDueRunId -RunId 5 | Should -BeFalse
            Test-VmfScheduleDueRunId -RunId $null | Should -BeFalse
        }
    }

    It 'the shipped sample reads as a usable record' {
        $text = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'schedule-due.sample.json') -Raw
        $r = InModuleScope VmMigrationFactory -Parameters @{ t = $text } { param($t) ConvertFrom-VmfScheduleDueText -Text $t }
        $r.Valid | Should -BeTrue
        @($r.Entries).Count | Should -Be 2
        $r.Entries[1]['nextUtc'] | Should -Be '2026-11-11T02:00:00.0000000Z' -Because 'times stay text'
    }

    It 'a text that is not the record gives no entries and is not usable: <Why>' -ForEach @(
        @{ Why = 'empty'; Json = '' }
        @{ Why = 'not JSON'; Json = '{oops' }
        @{ Why = 'a list'; Json = '[1]' }
        @{ Why = 'another schema'; Json = '{"schemaVersion":2,"runs":[]}' }
        @{ Why = 'schemaVersion as text'; Json = '{"schemaVersion":"1","runs":[]}' }
        @{ Why = 'runs is text'; Json = '{"schemaVersion":1,"runs":"r1"}' }
        @{ Why = 'runs is an object'; Json = '{"schemaVersion":1,"runs":{"runId":"r1"}}' }
        @{ Why = 'no runs'; Json = '{"schemaVersion":1}' }
    ) {
        $r = InModuleScope VmMigrationFactory -Parameters @{ t = $Json } { param($t) ConvertFrom-VmfScheduleDueText -Text $t }
        $r.Valid | Should -BeFalse
        @($r.Entries).Count | Should -Be 0
    }

    It 'an entry that does not fit is left out, and the record is not usable, so the pass sweeps: <Why>' -ForEach @(
        @{ Why = 'a bad run id'; Bad = '{"runId":"a/b/c","markId":"m","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":null}' }
        @{ Why = 'no mark id'; Bad = '{"runId":"r9","markId":"","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":null}' }
        @{ Why = 'an unknown reason'; Bad = '{"runId":"r9","markId":"m","reason":"other","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":null}' }
        @{ Why = 'a mark time that is not a time'; Bad = '{"runId":"r9","markId":"m","reason":"engine","markedUtc":"soon","holdUntilUtc":null,"nextUtc":null}' }
        @{ Why = 'a hold that is a number'; Bad = '{"runId":"r9","markId":"m","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":5,"nextUtc":null}' }
        @{ Why = 'a next time that is not a time'; Bad = '{"runId":"r9","markId":"m","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":"later"}' }
        @{ Why = 'the run twice'; Bad = '{"runId":"r1","markId":"m2","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":null}' }
        @{ Why = 'not an object'; Bad = '7' }
    ) {
        $json = '{"schemaVersion":1,"runs":[{"runId":"r1","markId":"m1","reason":"engine","markedUtc":"2026-11-10T09:00:00Z","holdUntilUtc":null,"nextUtc":null},' + $Bad + ']}'
        $r = InModuleScope VmMigrationFactory -Parameters @{ t = $json } { param($t) ConvertFrom-VmfScheduleDueText -Text $t }
        $r.Valid | Should -BeFalse
        @($r.Entries | ForEach-Object { $_['runId'] }) | Should -Be @('r1')
    }

    It 'a pass checks each run with no next time or a next time that has come, in ordinal order' {
        $entries = @(
            (& $script:Entry 'r9'), (& $script:Entry 'R2'),
            (& $script:Entry 'r3' -next '2026-11-10T09:59:00Z'),
            (& $script:Entry 'r4' -next '2026-11-10T10:01:00Z'))
        $ids = InModuleScope VmMigrationFactory -Parameters @{ e = $entries; n = $script:at } { param($e, $n) @(Select-VmfScheduleDueRuns -Entries $e -NowUtc $n) }
        $ids | Should -Be @('R2', 'r3', 'r9')
    }

    It 'a mark gives a new mark id and no next time, and an existing hold never gets shorter' {
        $entries = @((& $script:Entry 'r1' -mark 'old' -hold '2026-11-10T11:00:00Z' -next '2026-11-12T00:00:00Z'), (& $script:Entry 'r2'))
        $out = InModuleScope VmMigrationFactory -Parameters @{ e = $entries; n = $script:at } { param($e, $n)
            @(Merge-VmfScheduleDueMark -Entries $e -RunId 'r1' -Reason 'schedule' -HoldMinutes 15 -NowUtc $n) }
        @($out).Count | Should -Be 2
        $r1 = @($out | Where-Object { $_['runId'] -eq 'r1' })[0]
        $r1['markId'] | Should -Not -Be 'old'
        $r1['reason'] | Should -Be 'schedule'
        $r1['nextUtc'] | Should -BeNullOrEmpty -Because 'the next pass checks it'
        ([datetime]::Parse($r1['holdUntilUtc']).ToUniversalTime()) | Should -Be ([datetime]::new(2026, 11, 10, 11, 0, 0, [System.DateTimeKind]::Utc)) -Because 'an hour of hold is not cut to 15 minutes'
        $again = InModuleScope VmMigrationFactory -Parameters @{ e = $out; n = $script:at } { param($e, $n)
            @(Merge-VmfScheduleDueMark -Entries $e -RunId 'r3' -Reason 'engine' -HoldMinutes 15 -NowUtc $n) }
        $r3 = @($again | Where-Object { $_['runId'] -eq 'r3' })[0]
        ([datetime]::Parse($r3['holdUntilUtc']).ToUniversalTime()) | Should -Be $script:at.AddMinutes(15)
    }

    It 'what a pass found: <Why>' -ForEach @(
        @{ Why = 'nothing due, the same mark, no hold: removed'; Entry = @{ id = 'r1'; mark = 'm1' }; Change = @{ Seen = 'm1'; Needed = $false }; Present = $false; Next = $null }
        @{ Why = 'nothing due, but a mark written since: kept'; Entry = @{ id = 'r1'; mark = 'm2' }; Change = @{ Seen = 'm1'; Needed = $false }; Present = $true; Next = $null }
        @{ Why = 'nothing due, the same mark, a hold not ended: kept'; Entry = @{ id = 'r1'; mark = 'm1'; hold = '2026-11-10T10:10:00Z' }; Change = @{ Seen = 'm1'; Needed = $false }; Present = $true; Next = $null }
        @{ Why = 'nothing due, the same mark, a hold ended: removed'; Entry = @{ id = 'r1'; mark = 'm1'; hold = '2026-11-10T09:50:00Z' }; Change = @{ Seen = 'm1'; Needed = $false }; Present = $false; Next = $null }
        @{ Why = 'nothing due, the run was not in the record at the start: nothing'; Entry = @{ id = 'r1'; mark = 'm1' }; Change = @{ Seen = $null; Needed = $false }; Present = $true; Next = $null }
        @{ Why = 'due later, the same mark: it waits for that time'; Entry = @{ id = 'r1'; mark = 'm1' }; Change = @{ Seen = 'm1'; Needed = $true; NextUtc = '2026-11-11T02:00:00.0000000Z' }; Present = $true; Next = '2026-11-11T02:00:00' }
        @{ Why = 'due later, but a mark written since: checked at the next pass'; Entry = @{ id = 'r1'; mark = 'm2' }; Change = @{ Seen = 'm1'; Needed = $true; NextUtc = '2026-11-11T02:00:00.0000000Z' }; Present = $true; Next = $null }
        @{ Why = 'due at a time that has passed: checked at the next pass'; Entry = @{ id = 'r1'; mark = 'm1' }; Change = @{ Seen = 'm1'; Needed = $true; NextUtc = '2026-11-10T09:00:00.0000000Z' }; Present = $true; Next = $null }
    ) {
        $e = & $script:Entry $Entry.id -mark $Entry.mark -hold $Entry.hold
        $c = [pscustomobject]@{ RunId = 'r1'; SeenMarkId = $Change.Seen; Needed = $Change.Needed; NextUtc = $Change.NextUtc }
        $out = InModuleScope VmMigrationFactory -Parameters @{ e = @($e); c = @($c); n = $script:at } { param($e, $c, $n) @(Merge-VmfScheduleDueChanges -Entries $e -Changes $c -NowUtc $n) }
        $r1 = @($out | Where-Object { $_['runId'] -eq 'r1' })
        ($r1.Count -eq 1) | Should -Be $Present
        if ($Present) {
            if ($Next) { ([datetime]::Parse($r1[0]['nextUtc']).ToUniversalTime()) | Should -Be ([datetime]::Parse("$($Next)Z").ToUniversalTime()) }
            else { $r1[0]['nextUtc'] | Should -BeNullOrEmpty }
        }
    }

    It 'a run the sweep found with a fact, not in the record: added, with a new mark and the reason sweep' {
        $c = [pscustomobject]@{ RunId = 'p1/r7'; SeenMarkId = $null; Needed = $true; NextUtc = $null }
        $out = @(InModuleScope VmMigrationFactory -Parameters @{ c = @($c); n = $script:at } { param($c, $n) @(Merge-VmfScheduleDueChanges -Entries @() -Changes $c -NowUtc $n) })
        @($out).Count | Should -Be 1
        $out[0]['runId'] | Should -Be 'p1/r7'
        $out[0]['reason'] | Should -Be 'sweep'
        $out[0]['markId'] | Should -Match '^[0-9a-f]{32}$'
    }

    It 'a run the sweep found that a mark added meanwhile is left as the mark wrote it' {
        $e = & $script:Entry 'r1' -mark 'fresh'
        $c = [pscustomobject]@{ RunId = 'r1'; SeenMarkId = $null; Needed = $true; NextUtc = '2026-11-12T00:00:00Z' }
        $out = @(InModuleScope VmMigrationFactory -Parameters @{ e = @($e); c = @($c); n = $script:at } { param($e, $c, $n) @(Merge-VmfScheduleDueChanges -Entries $e -Changes $c -NowUtc $n) })
        $out[0]['markId'] | Should -Be 'fresh'
        $out[0]['nextUtc'] | Should -BeNullOrEmpty
    }

    It 'the text of the record lists the runs in ordinal order, so the same entries give the same text' {
        $a = InModuleScope VmMigrationFactory -Parameters @{ x = @((& $script:Entry 'b'), (& $script:Entry 'B'), (& $script:Entry 'a')) } { param($x) ConvertTo-VmfScheduleDueText -Entries $x }
        $b = InModuleScope VmMigrationFactory -Parameters @{ x = @((& $script:Entry 'a'), (& $script:Entry 'b'), (& $script:Entry 'B')) } { param($x) ConvertTo-VmfScheduleDueText -Entries $x }
        $a | Should -BeExactly $b
        @(($a | ConvertFrom-Json).runs.runId) | Should -Be @('B', 'a', 'b')
        Test-Json -Json $a -SchemaFile $script:dueSchema | Should -BeTrue
        $empty = InModuleScope VmMigrationFactory { ConvertTo-VmfScheduleDueText -Entries @() }
        Test-Json -Json $empty -SchemaFile $script:dueSchema | Should -BeTrue
    }

    It 'when a pass checks every run: <Why>' -ForEach @(
        @{ Why = 'the due record cannot be used'; Usable = $false; Rec = @{ last = '2026-11-10T09:55:00Z' }; Open = $true }
        @{ Why = 'no pass record'; Usable = $true; Rec = $null; Open = $true }
        @{ Why = 'a sweep is open'; Usable = $true; Rec = @{ last = '2026-11-10T09:55:00Z'; started = '2026-11-10T09:58:00Z' }; Open = $true }
        @{ Why = 'the last sweep is an hour old'; Usable = $true; Rec = @{ last = '2026-11-10T09:00:00Z' }; Open = $true }
        @{ Why = 'the last sweep is 59 minutes old: not yet'; Usable = $true; Rec = @{ last = '2026-11-10T09:01:00Z' }; Open = $false }
        @{ Why = 'no sweep ever ended'; Usable = $true; Rec = @{ last = $null }; Open = $true }
        @{ Why = 'the last sweep is ahead of this clock by more than 5 minutes'; Usable = $true; Rec = @{ last = '2026-11-10T11:00:00Z' }; Open = $true }
        @{ Why = 'the last sweep is ahead of this clock by 2 minutes: not yet'; Usable = $true; Rec = @{ last = '2026-11-10T10:02:00Z' }; Open = $false }
    ) {
        $prev = if ($Rec) { [pscustomobject]@{ schemaVersion = 2; finishedUtc = '2026-11-10T09:59:00Z'; resumeAtRunId = $null; checkingRunId = $null; checkingStops = 0
                sweepStartedUtc = $Rec.started; lastSweepUtc = $Rec.last } } else { $null }
        InModuleScope VmMigrationFactory -Parameters @{ p = $prev; u = $Usable; n = $script:at } { param($p, $u, $n)
            Test-VmfScheduleSweepOpen -Previous $p -DueUsable $u -NowUtc $n } | Should -Be $Open
    }

    It 'the sweep is hourly and an engine start holds its run 15 minutes' {
        InModuleScope VmMigrationFactory {
            $script:VmfScheduleSweepMinutes | Should -Be 60
            $script:VmfScheduleDueHoldMinutes | Should -Be 15
        }
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the record in a store on disk' {
    It 'a mark makes the record, and a second mark keeps the first run' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r)
            Add-VmfScheduleDueRun -StorePath $r -RunId 'r2' -Reason 'schedule' | Should -BeTrue
            Add-VmfScheduleDueRun -StorePath $r -RunId 'p1/r1' -Reason 'engine' -HoldMinutes 15 | Should -BeTrue
        }
        Test-Json -Json (Get-Content (Join-Path $root 'schedule-due.json') -Raw) -SchemaFile $script:dueSchema | Should -BeTrue
        $due = & $script:DueOf $root
        @($due.runs.runId) | Should -Be @('p1/r1', 'r2')
        $due.runs[0].holdUntilUtc | Should -Not -BeNullOrEmpty
        $due.runs[1].holdUntilUtc | Should -BeNullOrEmpty
    }

    It 'a mark of a run id the record may not hold, or with an unknown reason, is refused' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r)
            { Add-VmfScheduleDueRun -StorePath $r -RunId '../r1' -Reason 'engine' } | Should -Throw "*is not a run id*"
            { Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'because' } | Should -Throw "*not a reason*"
        }
        Test-Path (Join-Path $root 'schedule-due.json') | Should -BeFalse
    }

    It 'a pass that changes nothing writes nothing' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'engine' | Out-Null }
        $before = (Get-Item (Join-Path $root 'schedule-due.json')).LastWriteTimeUtc
        Mock -ModuleName VmMigrationFactory Write-VmfStoreRootTextIfVersion { throw 'nothing to write' }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreRootTextExclusive { throw 'nothing to create' }
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Update-VmfScheduleDue -StorePath $r -Changes @() | Should -BeTrue }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfStoreRootTextIfVersion -Times 0 -Exactly
        (Get-Item (Join-Path $root 'schedule-due.json')).LastWriteTimeUtc | Should -Be $before
    }

    It 'THE RACE: a mark written between the pass''s read and its write is kept - the write is version-checked and done again' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'engine' | Out-Null }
        $seen = (& $script:DueOf $root).runs[0].markId
        $global:SpdRaced = $false
        # The first write of the pass meets a record another writer changed:
        # the real version check refuses it, and the pass reads again.
        Mock -ModuleName VmMigrationFactory Write-VmfStoreRootTextIfVersion {
            if (-not $global:SpdRaced) {
                $global:SpdRaced = $true
                & (Get-Module VmMigrationFactory) { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'engine' | Out-Null; Add-VmfScheduleDueRun -StorePath $r -RunId 'r8' -Reason 'schedule' | Out-Null } $StorePath
            }
            & (Get-Module VmMigrationFactory) { param($a, $b, $c, $d)
                & (Get-Command Write-VmfStoreRootTextIfVersion -CommandType Function) -StorePath $a -Name $b -Content $c -ExpectedVersion $d
            } $StorePath $Name $Content $ExpectedVersion
        }
        $c = [pscustomobject]@{ RunId = 'r1'; SeenMarkId = $seen; Needed = $false; NextUtc = $null }
        InModuleScope VmMigrationFactory -Parameters @{ r = $root; c = @($c) } { param($r, $c) Update-VmfScheduleDue -StorePath $r -Changes $c | Should -BeTrue }
        @((& $script:DueOf $root).runs.runId) | Should -Be @('r1', 'r8') -Because 'r1 was marked again after the pass read it, and r8 is the other writer''s'
        $global:SpdRaced | Should -BeTrue -Because 'the first write of the pass met the other writer''s record'
        Remove-Variable -Name SpdRaced -Scope Global
    }

    It 'the version-checked write on disk refuses a stale version, and the create refuses a record that is there' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r)
            Write-VmfStoreRootTextExclusive -StorePath $r -Name 'schedule-due.json' -Content '{"schemaVersion":1,"runs":[]}' | Should -BeTrue
            Write-VmfStoreRootTextExclusive -StorePath $r -Name 'schedule-due.json' -Content '{"schemaVersion":1,"runs":[]}' | Should -BeFalse
            Write-VmfStoreRootTextIfVersion -StorePath $r -Name 'schedule-due.json' -Content 'x' -ExpectedVersion ('0' * 64) | Should -BeFalse
            $v = Get-VmfDocumentVersion -Text (Read-VmfStoreRootText -StorePath $r -Name 'schedule-due.json')
            Write-VmfStoreRootTextIfVersion -StorePath $r -Name 'schedule-due.json' -Content '{"schemaVersion":1,"runs":[ ]}' -ExpectedVersion $v | Should -BeTrue
            { Read-VmfStoreRootText -StorePath $r -Name 'sub/x.json' } | Should -Throw '*not a document name*'
        }
    }

    It 'a record that cannot be used is written over by the next change' {
        $root = & $script:NewRoot
        Set-Content -Path (Join-Path $root 'schedule-due.json') -Value '{"schemaVersion":1,"runs":[{"runId":"a/b/c"}]}' -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'engine' | Should -BeTrue }
        Test-Json -Json (Get-Content (Join-Path $root 'schedule-due.json') -Raw) -SchemaFile $script:dueSchema | Should -BeTrue
        @((& $script:DueOf $root).runs.runId) | Should -Be @('r1')
    }

    It 'a record another writer keeps changing: after five tries the write says it did not land' {
        $root = & $script:NewRoot
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r1' -Reason 'engine' | Out-Null }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreRootTextIfVersion { $false }
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r2' -Reason 'engine' | Should -BeFalse }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfStoreRootTextIfVersion -Times 5 -Exactly
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the record on blob storage' {
    BeforeEach {
        $global:SpdBlobs = @{}
        $global:SpdCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = $u.AbsolutePath.TrimStart('/')
            $global:SpdCalls.Add("$Method $path")
            switch ($Method) {
                'PUT' {
                    if ($Headers['If-None-Match'] -eq '*' -and $global:SpdBlobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($Headers['If-Match'] -and (-not $global:SpdBlobs.ContainsKey($path) -or $global:SpdBlobs[$path].ETag -ne $Headers['If-Match'])) { return [pscustomobject]@{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:SpdBlobs[$path] = @{ Content = [string]$Body; ETag = '"' + [guid]::NewGuid().ToString('N') + '"' }
                    return [pscustomobject]@{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:SpdBlobs[$path].ETag } }
                }
                'GET' {
                    if (-not $global:SpdBlobs.ContainsKey($path)) { return [pscustomobject]@{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                    return [pscustomobject]@{ StatusCode = 200; Content = $global:SpdBlobs[$path].Content; Headers = @{ ETag = $global:SpdBlobs[$path].ETag } }
                }
            }
            [pscustomobject]@{ StatusCode = 500; Content = "unhandled: $Method $Uri"; Headers = @{} }
        }
    }
    AfterEach { Remove-Variable -Name SpdBlobs, SpdCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'the record is at the top of the container, created once, and every change is a write with If-Match' {
        InModuleScope VmMigrationFactory {
            Add-VmfScheduleDueRun -StorePath 'azblob://acct/vmf-runs' -RunId 'r1' -Reason 'engine' | Should -BeTrue
            Add-VmfScheduleDueRun -StorePath 'azblob://acct/vmf-runs/' -RunId 'p/r2' -Reason 'schedule' | Should -BeTrue
        }
        $global:SpdBlobs.Keys | Should -Be @('vmf-runs/schedule-due.json')
        @(($global:SpdBlobs['vmf-runs/schedule-due.json'].Content | ConvertFrom-Json).runs.runId) | Should -Be @('p/r2', 'r1')
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfStorageRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Headers['If-None-Match'] -eq '*' }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfStorageRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Headers['If-Match'] }
    }

    It 'a version that is not the record''s is refused before any write; an ETag that changed is refused by the store' {
        $global:SpdBlobs['vmf-runs/schedule-due.json'] = @{ Content = '{"schemaVersion":1,"runs":[]}'; ETag = '"e1"' }
        InModuleScope VmMigrationFactory {
            Write-VmfStoreRootTextIfVersion -StorePath 'azblob://acct/vmf-runs' -Name 'schedule-due.json' -Content 'x' -ExpectedVersion ('0' * 64) | Should -BeFalse
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfStorageRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        InModuleScope VmMigrationFactory {
            Write-VmfStoreRootTextExclusive -StorePath 'azblob://acct/vmf-runs' -Name 'schedule-due.json' -Content 'y' | Should -BeFalse
        }
    }

    It 'a run is in the store when it has run.json, or anything else under it' {
        $global:SpdBlobs['vmf-runs/r1/run.json'] = @{ Content = '{}'; ETag = '"a"' }
        $global:SpdBlobs['vmf-runs/r2/state/a.json'] = @{ Content = '{}'; ETag = '"b"' }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { $p = $RunPath -replace '^azblob://acct/', ''; @($global:SpdBlobs.Keys | Where-Object { $_.StartsWith("$p/") } | ForEach-Object { ($_ -split '/')[-1] }) }
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem { $p = $RunPath -replace '^azblob://acct/', ''; $global:SpdBlobs.ContainsKey("$p/$RelPath") }
        InModuleScope VmMigrationFactory {
            Test-VmfStoreRunPresent -RunPath 'azblob://acct/vmf-runs/r1' | Should -BeTrue
            Test-VmfStoreRunPresent -RunPath 'azblob://acct/vmf-runs/r2' | Should -BeTrue
            Test-VmfStoreRunPresent -RunPath 'azblob://acct/vmf-runs/r3' | Should -BeFalse
        }
    }
    It 'a document of a run is still written at the address it always had' {
        InModuleScope VmMigrationFactory {
            Write-VmfStoreTextExclusive -RunPath 'azblob://acct/vmf-runs/p1/r1' -RelPath 'plan.json' -Content '{"a":1}' | Should -BeTrue
            $v = Get-VmfDocumentVersion -Text '{"a":1}'
            Write-VmfTextDocumentIfVersion -Path 'azblob://acct/vmf-runs/p1/r1/plan.json' -Content '{"a":2}' -ExpectedVersion $v
            Read-VmfStoreText -RunPath 'azblob://acct/vmf-runs/p1/r1' -RelPath 'plan.json' | Should -Be '{"a":2}'
            Get-VmfStoreHandleUri -Handle 'azblob://acct/vmf-runs/p1/r1/plan.json' | Should -Be 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/plan.json'
            Get-VmfStoreHandleUri -Handle 'azblob://acct/vmf-runs/schedule-due.json' | Should -Be 'https://acct.blob.core.windows.net/vmf-runs/schedule-due.json'
            { Get-VmfStoreHandleUri -Handle 'azblob://acct/vmf-runs/p1/../x.json' } | Should -Throw '*goes up a level*'
            { Get-VmfStoreHandleUri -Handle 'azblob://acct/vmf-runs' } | Should -Throw '*Invalid azblob document*'
        }
        $global:SpdBlobs.Keys | Should -Be @('vmf-runs/p1/r1/plan.json')
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the facts that keep a run in the record' {
    BeforeAll {
        $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-01'
        $script:Run = {
            $rp = Join-Path $script:temp "n-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $rp -Force | Out-Null
            $rp
        }
        $script:Put = { param($rp, $rel, $doc) $file = Join-Path $rp $rel; New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null; $doc | ConvertTo-Json -Depth 8 | Set-Content $file -Encoding utf8NoBOM }
        $script:Need = { param($rp, $docs = $null)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; d = $docs; n = [datetime]::UtcNow } { param($rp, $d, $n)
                if ($null -eq $d) { Get-VmfRunScheduleNeed -RunPath $rp -NowUtc $n } else { Get-VmfRunScheduleNeed -RunPath $rp -StateDocs $d -NowUtc $n } }
        }
        $script:Lease = { param($rp, [string]$vmId, [string]$worker, [int]$ageSeconds)
            & $script:Put $rp "leases/$([guid]::NewGuid().ToString('N')).lease" ([ordered]@{ schemaVersion = 1; vmId = $vmId; workerId = $worker
                acquiredUtc = [datetime]::UtcNow.AddHours(-2).ToString('o'); heartbeatUtc = [datetime]::UtcNow.AddSeconds(-$ageSeconds).ToString('o') })
        }
    }

    It 'a run with nothing in it: no check acts on it' {
        $r = & $script:Need (& $script:Run)
        $r.NextUtc | Should -BeNullOrEmpty
        $r.Reason | Should -BeNullOrEmpty
    }

    It 'a machine at a working state (<State>): now' -ForEach @(@{ State = 'PLANNED' }, @{ State = 'STOPPED' }, @{ State = 'VALIDATING' }) {
        $rp = & $script:Run
        & $script:Put $rp 'state/a.json' @{ vmId = $script:vm; state = $State }
        (& $script:Need $rp).Reason | Should -Be 'machineWorking'
    }

    It 'machines at final states (<State>): nothing' -ForEach @(@{ State = 'MIGRATED' }, @{ State = 'NEEDS_DECISION' }, @{ State = 'FAILED_ROLLED_BACK' }, @{ State = 'FAILED_NEEDS_ATTENTION' }, @{ State = 'SKIPPED' }) {
        $rp = & $script:Run
        & $script:Put $rp 'state/a.json' @{ vmId = $script:vm; state = $State }
        (& $script:Need $rp).NextUtc | Should -BeNullOrEmpty
    }

    It 'the machine records the pass read are used, not read again' {
        $rp = & $script:Run
        & $script:Put $rp 'state/a.json' @{ vmId = $script:vm; state = 'MIGRATED' }
        (& $script:Need $rp @([pscustomobject]@{ vmId = $script:vm; state = 'CONVERTING' })).Reason | Should -Be 'machineWorking'
    }

    It 'a restore or a finish on a machine record: now, unless the service gave up on it (<Kind>, <Ended>)' -ForEach @(
        @{ Kind = 'restore'; Ended = $null; Reason = 'putBackJob' }
        @{ Kind = 'finish'; Ended = $null; Reason = 'putBackJob' }
        @{ Kind = 'restore'; Ended = 'done'; Reason = 'putBackJob' }
        @{ Kind = 'restore'; Ended = 'gaveUp'; Reason = $null }
    ) {
        $job = [ordered]@{ kind = $Kind; operationId = 'op-1'; phase = 'made'; resumes = 0 }
        if ($Ended) { $job.ended = @{ reason = $Ended; why = 'w' } }
        $docs = @([pscustomobject]@{ vmId = $script:vm; state = 'MIGRATED'; putBackJob = [pscustomobject]$job })
        (& $script:Need (& $script:Run) $docs).Reason | Should -Be $Reason
    }

    It 'holds: <Why>' -ForEach @(
        @{ Why = 'a wave worker with a heartbeat that is not old: now'; Vm = 'machine'; Worker = 'wave-1-worker-0'; Age = 30; State = 'MIGRATED'; Reason = 'holdLive' }
        @{ Why = 'an old hold on a machine at a final state: now'; Vm = 'machine'; Worker = 'wave-1-worker-0'; Age = 3600; State = 'MIGRATED'; Reason = 'holdEnded' }
        @{ Why = 'an old hold on a machine with no record (taken before its check): now'; Vm = 'machine'; Worker = 'wave-1-worker-0'; Age = 3600; State = $null; Reason = 'holdTaken' }
        @{ Why = 'an old hold on a group of machines: nothing'; Vm = 'group-avset/x'; Worker = 'wave-1-worker-0'; Age = 3600; State = 'MIGRATED'; Reason = $null }
        @{ Why = 'the hold of a restore, a job of its own: nothing'; Vm = 'machine'; Worker = 'restore:op-1'; Age = 30; State = 'MIGRATED'; Reason = $null }
    ) {
        $rp = & $script:Run
        $vmId = if ($Vm -eq 'machine') { $script:vm } else { $Vm }
        & $script:Lease $rp $vmId $Worker $Age
        $docs = if ($State) { @([pscustomobject]@{ vmId = $script:vm.ToUpperInvariant(); state = $State }) } else { @() }
        (& $script:Need $rp $docs).Reason | Should -Be $Reason
    }

    It 'a signed-off plan: now until the plan has run every wave' {
        $rp = & $script:Run
        & $script:Put $rp 'plan-approval.json' @{ schemaVersion = 3; planHash = 'x' }
        (& $script:Need $rp).Reason | Should -Be 'planSignedOff'
        & $script:Put $rp 'plan-run.json' @{ schemaVersion = 1; reason = 'held'; detail = 'd' }
        (& $script:Need $rp).Reason | Should -Be 'planSignedOff'
        & $script:Put $rp 'plan-run.json' @{ schemaVersion = 1; reason = 'done'; detail = 'every wave of the plan has run' }
        (& $script:Need $rp).NextUtc | Should -BeNullOrEmpty
    }

    It 'a plan run record with no sign-off: nothing' {
        $rp = & $script:Run
        & $script:Put $rp 'plan-run.json' @{ schemaVersion = 1; reason = 'held'; detail = 'd' }
        (& $script:Need $rp).NextUtc | Should -BeNullOrEmpty
    }

    It 'schedules: <Why>' -ForEach @(
        @{ Why = 'a start on record: now'; Docs = @(@{ wave = 'w1'; state = 'started'; runAtUtc = '2026-01-01T00:00:00Z' }); Reason = 'scheduleStarted' }
        @{ Why = 'a start being made: now'; Docs = @(@{ wave = 'w1'; state = 'starting'; runAtUtc = '2099-01-01T00:00:00Z' }); Reason = 'scheduleStarted' }
        @{ Why = 'a pending wave whose time came: now'; Docs = @(@{ wave = 'w1'; state = 'pending'; runAtUtc = '2026-01-01T00:00:00Z' }); Reason = 'scheduleDue' }
        @{ Why = 'a pending wave with a time that cannot be read: now'; Docs = @(@{ wave = 'w1'; state = 'pending'; runAtUtc = 'tonight' }); Reason = 'scheduleDue' }
        @{ Why = 'two pending waves later: the earlier time'; Docs = @(@{ wave = 'w1'; state = 'pending'; runAtUtc = '2099-03-01T00:00:00Z' }, @{ wave = 'w2'; state = 'pending'; runAtUtc = '2099-02-01T00:00:00Z' }); Reason = 'schedulePending' }
    ) {
        $rp = & $script:Run
        $i = 0
        foreach ($d in $Docs) { $i++; & $script:Put $rp "schedules/w$i.json" $d }
        $r = & $script:Need $rp
        $r.Reason | Should -Be $Reason
        if ($Reason -eq 'schedulePending') { $r.NextUtc | Should -Be ([datetime]::new(2099, 2, 1, 0, 0, 0, [System.DateTimeKind]::Utc)) }
        else { $r.NextUtc | Should -BeLessOrEqual ([datetime]::UtcNow) }
    }

    It 'a schedule that is not JSON: now - the check says what is wrong with it' {
        $rp = & $script:Run
        New-Item -ItemType Directory -Path (Join-Path $rp 'schedules') -Force | Out-Null
        Set-Content -Path (Join-Path $rp 'schedules' 'w1.json') -Value '{not json' -Encoding utf8NoBOM
        (& $script:Need $rp).Reason | Should -Be 'scheduleDue'
    }

    It 'a fact for now ends the read: a working machine reads no hold, no sign-off and no schedule' {
        $rp = & $script:Run
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { @() }
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem { $false }
        (& $script:Need $rp @([pscustomobject]@{ vmId = $script:vm; state = 'STOPPED' })).Reason | Should -Be 'machineWorking'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfStoreNames -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfStoreItem -Times 0 -Exactly
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the service paths that make a run due mark it' {
    BeforeEach {
        $script:root = & $script:NewRoot
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'exec-1'; id = 'x' } | ConvertTo-Json) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 2 }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'an engine start of a <Op> marks its run, after the start, and holds it 15 minutes' -ForEach @(
        @{ Op = 'wave'; Extra = @{ Wave = 'w1'; Note = 'tonight' } }
        @{ Op = 'restore'; Extra = @{ VmId = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'; Note = 'back'; DiskSource = 'prepared' } }
        @{ Op = 'finish'; Extra = @{ VmId = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'; Note = 'finish' } }
    ) {
        $start = $Extra.Clone()
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation $Op -RunId 'r1' -Project 'proj-1' @start | Out-Null
        $due = & $script:DueOf $script:root
        $due.runs[0].runId | Should -Be 'proj-1/r1' -Because 'the pass names a run by its place in the store'
        $due.runs[0].reason | Should -Be 'engine'
        $hold = [datetime]::Parse($due.runs[0].holdUntilUtc).ToUniversalTime()
        ($hold - [datetime]::UtcNow).TotalMinutes | Should -BeGreaterThan 14
        Test-Path (Join-Path $script:root 'proj-1' 'r1' 'run.json') | Should -BeTrue -Because 'the manifest is written before the mark, so the pass finds the run'
    }

    # SCAN-FAIL-SHOWN-1: a scan marks its run (ScanFailShown.Tests.ps1): its job
    # can stop with no answer, and the pass then ends the wizard's wait.
    It 'an engine start that changes no machine (<Op>) does not mark its run' -ForEach @(@{ Op = 'advise' }, @{ Op = 'plan' }) {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation $Op -RunId 'r1' | Out-Null
        Test-Path (Join-Path $script:root 'schedule-due.json') | Should -BeFalse
    }

    It 'a start Azure refuses marks nothing' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 409; Content = '{"error":{"code":"Conflict"}}' }
        }
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n' } | Should -Throw
        Test-Path (Join-Path $script:root 'schedule-due.json') | Should -BeFalse
    }

    It 'a mark that cannot be written does not fail the start: a warning in the service log names it' {
        Mock -ModuleName VmMigrationFactory Add-VmfScheduleDueRun { throw 'HTTP 403 refused' }
        $all = @(Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n' 3>&1)
        $w = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $r = @($all | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
        $r.execution | Should -Be 'exec-1'
        (@($w | ForEach-Object { [string]$_ }) -join "`n") | Should -Match 'could not add the run to the record of the runs to check \(engine\): HTTP 403 refused\. The hourly check of every run finds it\.'
    }

    It 'the pass asks Azure about a wave, a restore, a finish, a scan and a check of the volumes of the run, by its place in the store' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Test-VmfFacadeRunJobRunning -RunId 'p1/r1' | Should -BeTrue
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 1 -Exactly -ParameterFilter {
            $RunId -eq 'p1/r1' -and -not $Project -and @($Operation).Count -eq 5 -and 'wave' -in $Operation -and 'restore' -in $Operation -and 'finish' -in $Operation -and 'assess' -in $Operation -and 'checkvolumes' -in $Operation }
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the cmdlets mark their run through the one shared mark' {
    BeforeEach {
        $script:root = & $script:NewRoot
        $script:Run = { param([string]$id)
            $rp = Join-Path $script:root ($id -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path $rp -Force | Out-Null
            if ($id -match '^([^/]+)/') { Set-Content -Path (Join-Path $script:root $Matches[1] 'project.json') -Value '{"schemaVersion":1}' -Encoding utf8NoBOM }
            Set-Content -Path (Join-Path $rp 'run.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 1; runId = ($id -split '/')[-1]; kind = 'migration' } | ConvertTo-Json)
            $rp
        }
    }

    It 'the store and the run id of a run path: <Why>' -ForEach @(
        @{ Why = 'a run on blob storage'; Path = 'azblob://acct/vmf-runs/r1'; Store = 'azblob://acct/vmf-runs'; Id = 'r1' }
        @{ Why = 'a run of a project on blob storage'; Path = 'azblob://acct/vmf-runs/proj-1/r1/'; Store = 'azblob://acct/vmf-runs'; Id = 'proj-1/r1' }
    ) {
        $p = InModuleScope VmMigrationFactory -Parameters @{ x = $Path } { param($x) Get-VmfStoreRunPlace -RunPath $x }
        $p.StorePath | Should -Be $Store
        $p.RunId | Should -Be $Id
    }

    It 'the store and the run id of a run on disk: in the store, and in a project (project.json)' {
        $a = & $script:Run 'r1'
        $b = & $script:Run 'proj-1/r2'
        $pa = InModuleScope VmMigrationFactory -Parameters @{ x = $a } { param($x) Get-VmfStoreRunPlace -RunPath $x }
        $pb = InModuleScope VmMigrationFactory -Parameters @{ x = $b } { param($x) Get-VmfStoreRunPlace -RunPath $x }
        $pa.RunId | Should -Be 'r1'
        $pa.StorePath | Should -Be ([System.IO.Path]::GetFullPath($script:root).TrimEnd([char]0x5C, [char]0x2F))
        $pb.RunId | Should -Be 'proj-1/r2'
        $pb.StorePath | Should -Be $pa.StorePath
        InModuleScope VmMigrationFactory -Parameters @{ x = [System.IO.Path]::GetPathRoot($a) } { param($x) Get-VmfStoreRunPlace -RunPath $x } | Should -BeNullOrEmpty
    }

    It 'Set-VmfWaveSchedule marks its run after it saves the schedule' {
        $rp = & $script:Run 'proj-1/r2'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp)
            Set-VmfWaveSchedule -RunPath $rp -Wave 'w1' -RunAtUtc ([datetime]::UtcNow.AddHours(2)) -Note 'at night' -ScheduledBy 'operator@example.com' | Out-Null }
        $due = & $script:DueOf $script:root
        $due.runs[0].runId | Should -Be 'proj-1/r2'
        $due.runs[0].reason | Should -Be 'schedule'
        $due.runs[0].holdUntilUtc | Should -BeNullOrEmpty
        Test-Path (Join-Path $rp 'schedules' 'w1.json') | Should -BeTrue
    }

    It 'a schedule that is refused marks nothing' {
        $rp = & $script:Run 'r1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp)
            { Set-VmfWaveSchedule -RunPath $rp -Wave 'w1' -RunAtUtc ([datetime]::UtcNow.AddHours(-1)) -Note 'late' } | Should -Throw '*already in the past*' }
        Test-Path (Join-Path $script:root 'schedule-due.json') | Should -BeFalse
    }

    It 'a mark that cannot be written does not fail the cmdlet: the schedule is saved, and a warning names it' {
        $rp = & $script:Run 'r1'
        Mock -ModuleName VmMigrationFactory Add-VmfScheduleDueRun { throw 'HTTP 403 refused' }
        $w = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp)
            @(Set-VmfWaveSchedule -RunPath $rp -Wave 'w1' -RunAtUtc ([datetime]::UtcNow.AddHours(2)) -Note 'n' 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ }) }
        ($w -join "`n") | Should -Match 'could not add the run to the record of the runs to check \(schedule\): HTTP 403 refused\. The hourly check of every run finds it\.'
        Test-Path (Join-Path $rp 'schedules' 'w1.json') | Should -BeTrue
    }

    It 'Approve-VmfPlan marks its run after it saves the sign-off' {
        $rp = & $script:Run 'r3'
        $plan = [pscustomobject]@{ assessmentRunId = 'r3'; entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/a'; wave = 'w1'; path = 'A'; policy = [pscustomobject]@{ throttle = 2 } }) }
        $plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'plan.json')
        Approve-VmfPlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Note 'reviewed' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        $due = & $script:DueOf $script:root
        $due.runs[0].runId | Should -Be 'r3'
        $due.runs[0].reason | Should -Be 'planSignOff'
    }

    It 'Clear-VmfWaveHalt marks its run after it removes the brake; with no brake it marks nothing' {
        $rp = & $script:Run 'r5'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Clear-VmfWaveHalt -RunPath $rp -Note 'go on' | Out-Null }
        Test-Path (Join-Path $script:root 'schedule-due.json') | Should -BeFalse
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp)
            Set-VmfWaveHalt -RunPath $rp -Reason 'paused' | Out-Null
            Clear-VmfWaveHalt -RunPath $rp -Note 'go on' | Out-Null }
        $due = & $script:DueOf $script:root
        $due.runs[0].runId | Should -Be 'r5'
        $due.runs[0].reason | Should -Be 'resume'
    }

    It 'the start of a restore or a finish (New-VmfPutBackJob) marks its run, held 15 minutes' {
        $rp = & $script:Run 'r6'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp)
            New-VmfStateDoc -RunPath $rp -RunId 'r6' -VmId '/s/rg/vm/a' -Wave 'w1' | Out-Null
            New-VmfPutBackJob -RunPath $rp -VmId '/s/rg/vm/a' -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp 's' | Out-Null }
        $due = & $script:DueOf $script:root
        $due.runs[0].runId | Should -Be 'r6'
        $due.runs[0].reason | Should -Be 'engine'
        $due.runs[0].holdUntilUtc | Should -Not -BeNullOrEmpty
    }

    It 'Resolve-VmfDecision and Start-VmfWave mark their run after their write, through the shared mark' {
        $root = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        $resolve = Get-VmfCodeOnly -Path (Join-Path $root 'Public' 'Resolve-VmfDecision.ps1')
        $resolve | Should -Match '(?s)\$updated = Add-VmfStateTransition -RunPath \$RunPath -VmId \$VmId -NewState \$ReturnTo.*?Add-VmfRunScheduleDue -RunPath \$RunPath -Reason ''decision'''
        $wave = Get-VmfCodeOnly -Path (Join-Path $root 'Public' 'Start-VmfWave.ps1')
        $wave | Should -Match '(?s)Write-VmfStepLine -RunPath \$RunPath -Step ''wave'' -Outcome start.*?Add-VmfRunScheduleDue -RunPath \$RunPath -Reason ''engine'' -EngineStart'
    }

    It 'the service marks only an engine start; the other paths are marked by the cmdlet they call, once' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        @([regex]::Matches($code, 'Add-VmfRunScheduleDue')).Count | Should -Be 1
        @([regex]::Matches($code, 'Add-VmfScheduleDueRun')).Count | Should -Be 0
    }
}
# MEASURED HERE: the store calls of a pass, counted at the module's own store
# primitives on the file backend - each document read, folder listing,
# existence check, document write, line append and removal. On blob storage
# each is one request. Twenty migrations of three machines, one of them with a
# machine that stopped part way: the first pass sweeps every run, which is
# what EVERY pass did before this item; the next pass checks the one run that
# has something due.
Describe 'SCHEDULE-PASS-DUE-1: the store calls of a pass, before and after' {
    BeforeAll {
        $script:oldStore = $env:VMF_STORE_PATH
        $script:countRoot = & $script:NewRoot
        foreach ($i in 1..20) {
            $run = 'run{0:00}' -f $i
            $rp = Join-Path $script:countRoot $run
            New-Item -ItemType Directory -Path (Join-Path $rp 'state') -Force | Out-Null
            Set-Content -Path (Join-Path $rp 'run.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 1; runId = $run; kind = 'migration' } | ConvertTo-Json)
            $entries = @(foreach ($m in 'a', 'b', 'c') {
                    @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$run-$m"; wave = 'w1'; path = 'A'; policy = @{ throttle = 2 } } })
            Set-Content -Path (Join-Path $rp 'plan.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 9; runId = $run; entries = $entries } | ConvertTo-Json -Depth 6)
            foreach ($m in 'a', 'b', 'c') {
                $state = if ($i -eq 7 -and $m -eq 'b') { 'STOPPED' } else { 'MIGRATED' }
                Set-Content -Path (Join-Path $rp 'state' "$m.json") -Encoding utf8NoBOM -Value (@{ vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$run-$m"; state = $state } | ConvertTo-Json)
            }
        }
        # Each primitive counts its call, then runs the real one by name: a
        # mock's $PSBoundParameters is empty.
        $script:CountCalls = {
            $global:SpdStoreCalls = 0
            Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a) & (Get-Command Read-VmfFileTextShared -CommandType Function) -Path $a } $Path }
            Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a, $b, $c) if ($c) { & (Get-Command Get-VmfStoreNames -CommandType Function) -RunPath $a -Folder $b -Extension $c } else { & (Get-Command Get-VmfStoreNames -CommandType Function) -RunPath $a -Folder $b } } $RunPath $Folder $Extension }
            Mock -ModuleName VmMigrationFactory Test-VmfStoreItem { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a, $b) & (Get-Command Test-VmfStoreItem -CommandType Function) -RunPath $a -RelPath $b } $RunPath $RelPath }
            Mock -ModuleName VmMigrationFactory Move-VmfFileReplace { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a, $b) & (Get-Command Move-VmfFileReplace -CommandType Function) -Source $a -Destination $b } $Source $Destination }
            Mock -ModuleName VmMigrationFactory Write-VmfStoreTextExclusive { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a, $b, $c) & (Get-Command Write-VmfStoreTextExclusive -CommandType Function) -RunPath $a -RelPath $b -Content $c } $RunPath $RelPath $Content }
            Mock -ModuleName VmMigrationFactory Add-VmfStoreLine { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a, $b, $c) & (Get-Command Add-VmfStoreLine -CommandType Function) -RunPath $a -RelPath $b -Line $c } $RunPath $RelPath $Line }
            Mock -ModuleName VmMigrationFactory Remove-VmfFileShared { $global:SpdStoreCalls++; & (Get-Module VmMigrationFactory) { param($a) & (Get-Command Remove-VmfFileShared -CommandType Function) -Path $a } $Path }
            # The listing of the runs, as blob storage answers it: the top of
            # the store and the first page of each folder (PERF-RUN-IDS-1).
            Mock Get-VmfFacadeRunIds {
                $global:SpdStoreCalls += 1 + @(Get-ChildItem $StorePath -Directory).Count
                @(Get-ChildItem $StorePath -Directory | ForEach-Object { $_.Name } | Sort-Object)
            }
        }
    }
    AfterAll {
        if ($null -eq $script:oldStore) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStore }
        Remove-Variable -Name SpdStoreCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a pass with one run due makes a fifth of the store calls of a pass that checks every run, or fewer' {
        $env:VMF_STORE_PATH = $script:countRoot
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
        & $script:CountCalls
        & $script:schedule -Timer $null 3>$null 6>$null
        $before = $global:SpdStoreCalls
        $rec = Get-Content (Join-Path $script:countRoot 'schedule-status.json') -Raw | ConvertFrom-Json -DateKind String
        $rec.runsChecked | Should -Be 20 -Because 'the first pass checks every run, as every pass did before'
        @((Get-Content (Join-Path $script:countRoot 'schedule-due.json') -Raw | ConvertFrom-Json).runs.runId) | Should -Be @('run07') -Because 'only the run with a stopped machine has something due'

        & $script:CountCalls
        & $script:schedule -Timer $null 3>$null 6>$null
        $after = $global:SpdStoreCalls
        (Get-Content (Join-Path $script:countRoot 'schedule-status.json') -Raw | ConvertFrom-Json -DateKind String).runsChecked | Should -Be 1

        InModuleScope VmMigrationFactory -Parameters @{ r = $script:countRoot } { param($r)
            $text = Get-Content (Join-Path $r 'run07' 'state' 'b.json') -Raw | ConvertFrom-Json
            $text.state = 'MIGRATED'
            $text | ConvertTo-Json | Set-Content (Join-Path $r 'run07' 'state' 'b.json') -Encoding utf8NoBOM
        }
        & $script:CountCalls
        & $script:schedule -Timer $null 3>$null 6>$null
        & $script:CountCalls
        & $script:schedule -Timer $null 3>$null 6>$null
        $idle = $global:SpdStoreCalls

        Write-Host ("SCHEDULE-PASS-DUE-1 store calls: every run {0}, one run due {1}, nothing due {2}" -f $before, $after, $idle)
        ($after * 5) | Should -BeLessOrEqual $before
        $idle | Should -BeLessOrEqual 4 -Because 'with nothing due a pass reads its two records and writes its own, and nothing else'
    }
}

Describe 'SCHEDULE-PASS-DUE-1: the pass and the record, in the code' {
    It 'the service marks an engine start only after the start and the manifest' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Match '(?s)Initialize-VmfRun -RunPath \$rp -RunId \$rid -Kind \$kind -Project \$proj.*?Add-VmfRunScheduleDue -StorePath \$r -RunId \$i -Reason ''engine'' -EngineStart'

    }

    It 'a removal from the record is version-checked: the write quotes the version it read' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'ScheduleDue.ps1')
        $code | Should -Match 'Write-VmfStoreRootTextIfVersion -StorePath \$StorePath -Name \$script:VmfScheduleDueName -Content \$text -ExpectedVersion \$now\.Version'
        $code | Should -Not -Match 'Write-VmfStoreRootJson'
    }
}
