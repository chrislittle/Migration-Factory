#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DELETE-CHANGED-FREED-1, ruled 2026-11-06 (option 2). Delete this
# migration stays allowed: a migration must always be discardable
# (RUN-LIFECYCLE-1). But a machine of it whose record says it is left CHANGED
# (Test-VmfMachineLeftChanged: a rollback that did not finish, a data disk swap
# that is left, a stop part way) is not as it was, and its safety copies are
# the only way to put it back. So:
#   - the delete ALWAYS keeps that machine's safety copies, also with
#     -DeleteSafetyCopies (Test-VmfRunDiscardable leaves them out of what it
#     deletes and lists the machine in ChangedMachines);
#   - the deletion record beside the claims names the machine and its kept
#     copies, because the migration record is what goes;
#   - nothing else deletes the kept copies: the daily cleanup finds copies only
#     through a migration's records (Get-VmfSafetyCopyIds), never by their tag;
#   - the dialog names the machine and says it is not as it was (the run page's
#     machineLeftChanged, held with the engine's rule to one fixture).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $global:DcSub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute'
    $global:DcChanged = "$global:DcSub/virtualMachines/vm-changed"
    $global:DcMoved = "$global:DcSub/virtualMachines/vm-moved"

    # One migration. vm-changed stopped with the rollback not finished
    # (machineState 'changed') and has a safety copy; vm-moved MIGRATED with a
    # safety copy, unless -OnlyChanged. -Mended adds a restore after the stop.
    function Global:DcRun {
        param([switch]$OnlyChanged, [switch]$Mended, [switch]$Skipped)
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; ch = $global:DcChanged; mv = $global:DcMoved; sub = $global:DcSub
            only = [bool]$OnlyChanged; mended = [bool]$Mended; skipped = [bool]$Skipped } {
            param($rp, $ch, $mv, $sub, $only, $mended, $skipped)
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' -Kind 'migration' | Out-Null
            $entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $ch; wave = 'w1'; path = 'A' })
            if (-not $only) { $entries += [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $mv; wave = 'w1'; path = 'A' } }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{ schemaVersion = 8; entries = $entries })

            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $ch -Wave 'w1' | Out-Null
            New-VmfVmClaim -RunPath $rp -VmId $ch -RunId 'run-x' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $ch -NewState 'PRECHECK' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ch
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    pristineSnapshotId = "$sub/snapshots/vm-changed-pristine"; snapshotId = "$sub/snapshots/vm-changed-snap"; cloneVmId = $null }) -Force
            if ($mended) { $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2099-01-01T00:00:00Z' }) -Force }
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $ch -NewState 'GUEST_PREP' -Outcome ok | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $ch -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'test' | Out-Null
            if ($skipped) { Add-VmfStateTransition -RunPath $rp -VmId $ch -NewState 'SKIPPED' -Outcome skip -Detail 'left out' | Out-Null }

            if (-not $only) {
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $mv -Wave 'w1' | Out-Null
                New-VmfVmClaim -RunPath $rp -VmId $mv -RunId 'run-x' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $mv -NewState 'PRECHECK' -Outcome ok | Out-Null
                $d2 = Read-VmfStateDoc -RunPath $rp -VmId $mv
                $d2 | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                        pristineSnapshotId = "$sub/snapshots/vm-moved-pristine"; snapshotId = $null; cloneVmId = $null }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $d2
                Add-VmfStateTransition -RunPath $rp -VmId $mv -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
        }
        @{ Store = $store; Run = $run }
    }

    function Global:DcDocs([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } { param($rp)
            @(Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json' | ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "state/$_" -Depth 24 }) }
    }
    function Global:DcVerdict([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ d = @(Global:DcDocs $RunPath) } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs $d }
    }

    # Azure, as far as a delete of copies needs it: every copy exists until it
    # is deleted, and each unlock and delete is counted.
    function Global:DcAzure {
        $global:DcSim = @{ Unlocks = [System.Collections.Generic.List[string]]::new(); Deletes = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { ($SnapshotId -split '/')[-1] -notin $global:DcSim.Deletes }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { $global:DcSim.Unlocks.Add(($SnapshotId -split '/')[-1]) }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $global:DcSim.Deletes.Add(($SnapshotId -split '/')[-1]) }
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }

    function Global:DcDeletionLines([string]$Store) {
        $file = Join-Path $Store 'vmf-claims' 'deletions.jsonl'
        if (-not (Test-Path $file)) { return @() }
        @(Get-Content $file | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 8 })
    }
}
AfterAll {
    Remove-Item 'function:\DcRun', 'function:\DcDocs', 'function:\DcVerdict', 'function:\DcAzure', 'function:\DcDeletionLines' -ErrorAction SilentlyContinue
    Remove-Variable -Name DcSim, DcSub, DcChanged, DcMoved -Scope Global -ErrorAction SilentlyContinue
}

Describe 'DELETE-CHANGED-FREED-1: one rule for a changed machine, in the engine and on the page' {
    It 'Test-VmfMachineLeftChanged gives the answer of every case in the fixture' {
        $cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'machine-left-changed.json') -Raw | ConvertFrom-Json -Depth 12).cases
        @($cases).Count | Should -BeGreaterOrEqual 12
        foreach ($c in $cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { param($d) Test-VmfMachineLeftChanged -Doc $d }
            $got | Should -Be ([bool]$c.expected) -Because $c.why
        }
    }
}

Describe 'DELETE-CHANGED-FREED-1: the delete keeps the safety copies of a machine left changed' {
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name DcSim -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the verdict leaves the changed machine''s copies out of what it deletes, and names the machine' {
        $script:fx = DcRun
        $v = DcVerdict $script:fx.Run
        $v.Ok | Should -BeTrue -Because 'a migration must always be discardable (RUN-LIFECYCLE-1)'
        @($v.OrphanSnapshots | ForEach-Object { ($_ -split '/')[-1] }) | Should -Be @('vm-moved-pristine')
        @($v.ChangedMachines).Count | Should -Be 1
        $v.ChangedMachines[0].VmId | Should -Be $global:DcChanged
        $v.ChangedMachines[0].Name | Should -Be 'vm-changed'
        @($v.ChangedMachines[0].SnapshotIds | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be @('vm-changed-pristine', 'vm-changed-snap')
    }

    It 'a machine left out while it is changed is a changed machine too' {
        $script:fx = DcRun -Skipped
        $v = DcVerdict $script:fx.Run
        @($v.ChangedMachines | ForEach-Object { $_.Name }) | Should -Be @('vm-changed')
        @($v.OrphanSnapshots | ForEach-Object { ($_ -split '/')[-1] }) | Should -Not -Contain 'vm-changed-snap'
    }

    It 'a changed machine that a restore mended since is not kept: its copies go with the others' {
        $script:fx = DcRun -Mended
        $v = DcVerdict $script:fx.Run
        @($v.ChangedMachines).Count | Should -Be 0
        @($v.OrphanSnapshots | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be @('vm-changed-pristine', 'vm-changed-snap', 'vm-moved-pristine')
    }

    It 'Delete the copies as well deletes the other machine''s copy and never unlocks or deletes the changed machine''s' {
        $script:fx = DcRun
        DcAzure
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        @($global:DcSim.Deletes) | Should -Be @('vm-moved-pristine')
        $global:DcSim.Unlocks | Should -Not -Contain 'vm-changed-snap'
        $global:DcSim.Unlocks | Should -Not -Contain 'vm-changed-pristine'
        $r.SafetyCopiesDeleted | Should -Be 1
        $r.SafetyCopiesKept | Should -Be 2 -Because 'the changed machine''s two copies are kept'
        @($r.ChangedMachinesKept) | Should -Be @('vm-changed')
        Test-Path $script:fx.Run | Should -BeFalse -Because 'the migration is deleted'
    }

    It 'with only a changed machine''s copies, no choice is asked and nothing in Azure is touched' {
        $script:fx = DcRun -OnlyChanged
        DcAzure
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -Confirm:$false
        $r.Removed | Should -BeTrue
        $global:DcSim.Deletes.Count | Should -Be 0
        $global:DcSim.Unlocks.Count | Should -Be 0
    }

    It 'the deletion record beside the claims names the changed machine and the copies kept for it' {
        $script:fx = DcRun
        DcAzure
        Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false | Out-Null
        $line = @(DcDeletionLines $script:fx.Store)
        $line.Count | Should -Be 1
        @($line[0].machinesLeftChanged).Count | Should -Be 1
        $line[0].machinesLeftChanged[0].vmId | Should -Be $global:DcChanged
        @($line[0].machinesLeftChanged[0].safetyCopies | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be @('vm-changed-pristine', 'vm-changed-snap')
        $line[0].safetyCopiesKept | Should -Be 2
    }

    It 'a migration with no changed machine records no changed machine' {
        $script:fx = DcRun -Mended
        DcAzure
        Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false | Out-Null
        $line = @(DcDeletionLines $script:fx.Store)
        @($line[0].machinesLeftChanged).Count | Should -Be 0
        $line[0].safetyCopiesKept | Should -Be 0
    }
}

Describe 'DELETE-CHANGED-FREED-1: the service deletes a migration whose only copies are a changed machine''s' {
    BeforeAll {
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        $script:operator = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    BeforeEach {
        $global:DcStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { $global:DcStarts.Add($Operation); [pscustomobject]@{ execution = 'vmf-engine-abc' } }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { throw 'the service must not delete a copy' }
    }
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name DcStarts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Delete the copies as well starts no engine: there is nothing it may delete, and the copies stay' {
        $script:fx = DcRun -OnlyChanged
        Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies | Out-Null
        $global:DcStarts.Count | Should -Be 0
        Test-Path $script:fx.Run | Should -BeFalse -Because 'the migration is deleted at once'
        @((DcDeletionLines $script:fx.Store)[0].machinesLeftChanged).Count | Should -Be 1
    }
}

Describe 'DELETE-CHANGED-FREED-1: once the migration is gone, nothing deletes the kept copies' {
    It 'the daily cleanup and every delete find a copy only through a migration''s records - nothing lists copies by their tag' {
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter *.ps1
        $hits = @(foreach ($f in $files) {
                # The tag's own name, in its own letter case - not Get-VmfSafetyCopyIds.
                if ((Get-VmfCodeOnly -Path $f.FullName) -cmatch '\bvmfSafetyCopy\b') { $f.Name }
            })
        # Retention.ps1 writes the tag (Get-VmfSafetyCopyTags); AzureOpsVm.ps1
        # reads it back on the copy it just tagged. Neither lists copies.
        @($hits | Sort-Object) | Should -Be @('AzureOpsVm.ps1', 'Retention.ps1') -Because 'a sweep by tag would delete the copies a deleted migration kept for a changed machine'
    }

    It 'the deleted migration is no longer a run the daily cleanup walks' {
        $script:fx = DcRun -OnlyChanged
        try {
            Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
            Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -Confirm:$false | Out-Null
            @(InModuleScope VmMigrationFactory -Parameters @{ s = $script:fx.Store } { param($s) Get-VmfStoreRunPaths -StorePath $s }).Count | Should -Be 0
        }
        finally { if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force } }
    }
}

Describe 'DELETE-CHANGED-FREED-1: the dialog words' {
    It 'the sentence that names the machines is declared, and says the copies stay' {
        $page = Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        $text = [regex]::Match($page, "(?m)^\s*discardChanged\s*:\s*'([^']*)'").Groups[1].Value
        $text | Should -Match '\{names\}'
        $text | Should -Match 'not as they were before the move'
        $text | Should -Match 'keeps'
    }
}
