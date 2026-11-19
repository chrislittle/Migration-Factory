#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# COPY-DELETE-LOCK-RACE-1, found on the lab install 2026-11-14 through the app
# (Delete this migration, with Delete the copies as well): one of four safety
# copies was not deleted. The product removed the copy's lock and sent the
# delete at once. Azure still listed the lock, answered HTTP 409 ScopeLocked,
# and a 409 was never tried again - so one answer ended the delete of that copy.
#
# Now: the unlock reads the lock back until Azure no longer lists it (a fixed
# number of reads), and the delete takes ScopeLocked as temporary for a fixed
# number of tries. In both paths that unlock and delete a copy: Delete the
# copies as well (Remove-VmfRunSafetyCopies) and the daily retention cleanup
# (Remove-VmfExpiredSafetyCopies).
#
# Azure is simulated at the Az cmdlet and REST level, so the REAL
# Unlock-VmfSnapshot and Remove-VmfSnapshot run: the race is between them.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:CdSnap([string]$Name) {
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$Name"
    }

    # Azure, as the lab measured it. Each copy has a lock. After the lock is
    # removed, Azure still lists it for -ListedReads reads, and a delete sent
    # while it is listed is refused with ScopeLocked. -ScopeLockedDeletes adds
    # that many ScopeLocked answers AFTER the lock reads gone (a lock that ARM
    # still applies for a moment). -ForeverLocked: the lock never goes.
    function Global:CdAzure {
        param([string[]]$Copies, [int]$ListedReads = 0, [int]$ScopeLockedDeletes = 0, [switch]$ForeverLocked,
              [switch]$ForeverScopeLocked, [switch]$Refuse403, [string]$LockReadError, [string[]]$RefuseCopies = @(), [switch]$LockWriteFails)
        $global:CdSim = @{
            There = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Copies | ForEach-Object { CdSnap $_ }))
            Locked = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Copies | ForEach-Object { CdSnap $_ }))
            ListedLeft = @{}
            ScopeLockedLeft = @{}
            ListedReads = $ListedReads
            ScopeLockedDeletes = $ScopeLockedDeletes
            ForeverLocked = [bool]$ForeverLocked
            ForeverScopeLocked = [bool]$ForeverScopeLocked
            Refuse403 = [bool]$Refuse403
            RefuseCopies = @($RefuseCopies)
            LockWriteFails = [bool]$LockWriteFails
            LockReadError = $LockReadError
            Calls = [System.Collections.Generic.List[string]]::new()
        }
        Mock -ModuleName VmMigrationFactory Remove-AzResourceLock {
            $id = ($Scope -split '/')[-1]
            $global:CdSim.Calls.Add("unlock $id")
            if (-not $global:CdSim.ForeverLocked) {
                $global:CdSim.ListedLeft[$Scope] = $global:CdSim.ListedReads
                $global:CdSim.ScopeLockedLeft[$Scope] = $global:CdSim.ScopeLockedDeletes
            }
        }
        Mock -ModuleName VmMigrationFactory Get-AzResourceLock {
            $global:CdSim.Calls.Add("readlock $(($Scope -split '/')[-1])")
            if ($global:CdSim.LockReadError) { throw $global:CdSim.LockReadError }
            if (-not $global:CdSim.Locked.Contains($Scope)) { throw "LockNotFound: The lock '$LockName' could not be found." }
            if ($global:CdSim.ForeverLocked) { return [pscustomobject]@{ LockId = "$Scope/providers/Microsoft.Authorization/locks/vmf-safety-copy" } }
            if ($global:CdSim.ListedLeft.ContainsKey($Scope)) {
                if ($global:CdSim.ListedLeft[$Scope] -gt 0) {
                    $global:CdSim.ListedLeft[$Scope]--
                    return [pscustomobject]@{ LockId = "$Scope/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
                }
                [void]$global:CdSim.Locked.Remove($Scope)
                throw "LockNotFound: The lock '$LockName' could not be found."
            }
            [pscustomobject]@{ LockId = "$Scope/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
        }
        Mock -ModuleName VmMigrationFactory New-AzResourceLock {
            $global:CdSim.Calls.Add("lock $(($Scope -split '/')[-1])")
            if ($global:CdSim.LockWriteFails) { throw 'AuthorizationFailed: locks/write' }
            [void]$global:CdSim.Locked.Add($Scope)
            [void]$global:CdSim.ListedLeft.Remove($Scope)
            [pscustomobject]@{ LockId = "$Scope/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
        }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $global:CdSim.There.Contains($SnapshotId) }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $snap = ($Path -split '\?')[0]
            $global:CdSim.Calls.Add("delete $(($snap -split '/')[-1])")
            $scopeLocked = [pscustomobject]@{ StatusCode = 409; Content = ('{"error":{"code":"ScopeLocked","message":"The scope ''' + $snap + ''' cannot perform delete operation because following scope(s) are locked: ''/subscriptions/<placeholder>/resourceGroups/rg/providers/Microsoft.Compute/snapshots/x''. Please remove the lock and try again."}}') }
            if ($global:CdSim.Refuse403 -or (($snap -split '/')[-1] -in $global:CdSim.RefuseCopies)) { return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed","message":"no"}}' } }
            if ($global:CdSim.ForeverScopeLocked) { return $scopeLocked }
            # A delete while Azure still lists the lock: refused.
            $listed = $global:CdSim.ForeverLocked -or ($global:CdSim.ListedLeft.ContainsKey($snap) -and $global:CdSim.ListedLeft[$snap] -gt 0) -or
                      -not $global:CdSim.ListedLeft.ContainsKey($snap)
            if ($listed) {
                # Each refused delete is also time passing: the lock gets one read closer to gone.
                if ($global:CdSim.ListedLeft.ContainsKey($snap) -and $global:CdSim.ListedLeft[$snap] -gt 0) { $global:CdSim.ListedLeft[$snap]-- }
                return $scopeLocked
            }
            if ($global:CdSim.ScopeLockedLeft[$snap] -gt 0) { $global:CdSim.ScopeLockedLeft[$snap]--; return $scopeLocked }
            [void]$global:CdSim.There.Remove($snap)
            [pscustomobject]@{ StatusCode = 202; Content = '' }
        }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
    }

    function Global:CdRunPath {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'cd' | Out-Null }
        $rp
    }
    function Global:CdEvents([string]$RunPath) {
        @(Get-Content (Join-Path $RunPath 'logs' 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
    }
    function Global:CdDiscard([string]$RunPath, [string[]]$Copies) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; ids = @($Copies | ForEach-Object { CdSnap $_ }) } {
            Remove-VmfRunSafetyCopies -RunPath $rp -SnapshotIds $ids -RunId 'cd' -WarningAction SilentlyContinue
        }
    }
}
AfterAll {
    Remove-Item 'function:\CdSnap', 'function:\CdAzure', 'function:\CdRunPath', 'function:\CdEvents', 'function:\CdDiscard' -ErrorAction SilentlyContinue
    Remove-Variable -Name CdSim -Scope Global -ErrorAction SilentlyContinue
}

Describe 'COPY-DELETE-LOCK-RACE-1: the unlock waits until Azure no longer lists the lock' {
    It 'reads the lock back after the removal, and returns when Azure no longer lists it' {
        CdAzure -Copies 'a' -ListedReads 2
        InModuleScope VmMigrationFactory -Parameters @{ id = (CdSnap 'a') } { Unlock-VmfSnapshot -SnapshotId $id -ConfirmReads 6 -ConfirmDelaySec 1 }
        @($global:CdSim.Calls) | Should -Be @('unlock a', 'readlock a', 'readlock a', 'readlock a') -Because 'two reads still list the lock, the third does not'
    }

    It 'throws, naming the lock, when Azure still lists it after the last read' {
        CdAzure -Copies 'a' -ForeverLocked
        { InModuleScope VmMigrationFactory -Parameters @{ id = (CdSnap 'a') } { Unlock-VmfSnapshot -SnapshotId $id -ConfirmReads 3 -ConfirmDelaySec 1 } } |
            Should -Throw '*Azure still shows the lock*vmf-safety-copy*on the safety copy. The product did not delete the copy.'
        @($global:CdSim.Calls | Where-Object { $_ -eq 'readlock a' }) | Should -HaveCount 3 -Because 'the reads have a fixed limit'
    }

    It 'a lock read that fails for another reason is not read as gone' {
        CdAzure -Copies 'a' -LockReadError 'AuthorizationFailed: locks/read'
        { InModuleScope VmMigrationFactory -Parameters @{ id = (CdSnap 'a') } { Unlock-VmfSnapshot -SnapshotId $id -ConfirmReads 3 -ConfirmDelaySec 1 } } |
            Should -Throw '*AuthorizationFailed*'
    }

    It 'a lock read that returns nothing reads as gone' {
        CdAzure -Copies 'a'
        Mock -ModuleName VmMigrationFactory Get-AzResourceLock { $global:CdSim.Calls.Add('readlock'); $null }
        InModuleScope VmMigrationFactory -Parameters @{ id = (CdSnap 'a') } { Unlock-VmfSnapshot -SnapshotId $id -ConfirmReads 3 -ConfirmDelaySec 1 }
        @($global:CdSim.Calls | Where-Object { $_ -eq 'readlock' }) | Should -HaveCount 1
    }
}

Describe 'COPY-DELETE-LOCK-RACE-1: Delete the copies as well' {
    BeforeEach { $script:rp = CdRunPath }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE LAB DEFECT: Azure lists each lock for a while after its removal, and every copy is still deleted' {
        CdAzure -Copies 'p0', 'p1', 's1', 'p2' -ListedReads 2
        $r = CdDiscard $script:rp @('p0', 'p1', 's1', 'p2')
        @($r.Failed) | Should -HaveCount 0 -Because "a lock Azure has not finished removing is a wait, not a failure: $(@($r.Failed | ForEach-Object Reason) -join ' | ')"
        @($r.Deleted) | Should -HaveCount 4
        $global:CdSim.There.Count | Should -Be 0 -Because 'no copy is left in Azure'
        $global:CdSim.Locked.Count | Should -Be 0 -Because 'no lock is left in Azure'
    }

    It 'the delete is sent only after Azure no longer lists the lock' {
        CdAzure -Copies 'p0' -ListedReads 2
        CdDiscard $script:rp @('p0') | Out-Null
        $calls = $global:CdSim.Calls
        $calls.IndexOf('readlock p0') | Should -BeGreaterThan $calls.IndexOf('unlock p0')
        $calls.IndexOf('delete p0') | Should -BeGreaterThan $calls.LastIndexOf('readlock p0')
        @($calls | Where-Object { $_ -eq 'delete p0' }) | Should -HaveCount 1 -Because 'nothing was refused'
    }

    It 'a ScopeLocked answer after the lock reads gone is tried again, and the copy is deleted' {
        CdAzure -Copies 'p0' -ScopeLockedDeletes 2
        $r = CdDiscard $script:rp @('p0')
        @($r.Deleted) | Should -HaveCount 1
        @($global:CdSim.Calls | Where-Object { $_ -eq 'delete p0' }) | Should -HaveCount 3
        $lines = CdEvents $script:rp | Where-Object { $_.step -eq 'azureops:removeSnapshot' }
        @($lines | Where-Object { $_.outcome -eq 'fail' }) | Should -HaveCount 0 -Because 'an answer the product tries again is not a failure'
        @($lines | Where-Object { $_.outcome -eq 'retry' }) | Should -HaveCount 2
        @($lines | Where-Object { $_.snapshotId -ne (CdSnap 'p0') }) | Should -HaveCount 0 -Because 'each Azure call line names its copy, so the Activity list does not mix two copies'
    }

    It 'a lock that never goes ends the delete of that copy, and the copy keeps its lock' {
        CdAzure -Copies 'p0', 'p1' -ForeverLocked
        $r = CdDiscard $script:rp @('p0', 'p1')
        @($r.Failed) | Should -HaveCount 2 -Because 'every copy is tried'
        @($global:CdSim.Calls | Where-Object { $_ -like 'delete *' }) | Should -HaveCount 0 -Because 'a delete is never sent while Azure lists the lock'
        @($r.Failed)[0].Reason | Should -Match 'After \d+ seconds, Azure still shows the lock .vmf-safety-copy. on the safety copy\. The product did not delete the copy\.'
        @($r.Failed)[0].Reason | Should -Match 'The product put the lock back on the copy\.$'
        $global:CdSim.Locked.Count | Should -Be 2
    }

    It 'a delete Azure accepts while the copy stays says so, and the lock does not go back' {
        # STE100 rewrite 2026-11-15: the words of a delete Azure accepted.
        CdAzure -Copies 'p0'
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        $r = CdDiscard $script:rp @('p0')
        @($r.Failed) | Should -HaveCount 1
        @($r.Failed)[0].Reason | Should -Match 'Azure accepted the delete\. The product did not put the lock back\.$'
        $line = @(CdEvents $script:rp | Where-Object { $_.step -eq 'discardCopy' -and $_.outcome -eq 'fail' })
        $line[0].detail | Should -Match '^The product did not delete the safety copy p0: '
    }
    It 'ScopeLocked every time (a lock on the resource group) ends the delete after a fixed number of tries, and the lock goes back' {
        CdAzure -Copies 'p0' -ForeverScopeLocked
        $r = CdDiscard $script:rp @('p0')
        @($r.Failed) | Should -HaveCount 1
        @($r.Failed)[0].Reason | Should -Match 'ScopeLocked'
        @($r.Failed)[0].Reason | Should -Match 'The product put the lock back on the copy\.$'
        $n = @($global:CdSim.Calls | Where-Object { $_ -eq 'delete p0' }).Count
        $n | Should -BeGreaterThan 1
        $n | Should -BeLessOrEqual 8 -Because 'the tries have a fixed limit'
        $global:CdSim.Locked.Contains((CdSnap 'p0')) | Should -BeTrue
    }

    It 'any other refusal of the delete is not tried again' {
        CdAzure -Copies 'p0' -Refuse403
        $r = CdDiscard $script:rp @('p0')
        @($r.Failed) | Should -HaveCount 1
        @($global:CdSim.Calls | Where-Object { $_ -eq 'delete p0' }) | Should -HaveCount 1 -Because 'only ScopeLocked after the unlock is temporary'
    }

    It 'kill and resume: a copy unlocked by a run that stopped is unlocked, confirmed and deleted by the next run' {
        CdAzure -Copies 'p0' -ListedReads 1
        # The first run removed the lock and stopped before the delete.
        $global:CdSim.ListedLeft[(CdSnap 'p0')] = 1
        $global:CdSim.ScopeLockedLeft[(CdSnap 'p0')] = 0
        $r = CdDiscard $script:rp @('p0')
        @($r.Deleted) | Should -HaveCount 1
        $global:CdSim.There.Count | Should -Be 0
    }
}

Describe 'COPY-DELETE-LOCK-RACE-1: the daily retention cleanup' {
    BeforeEach {
        $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        $script:rp = CdRunPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm; a = (CdSnap 'ret-p'); b = (CdSnap 'ret-s') } {
            New-VmfStateDoc -RunPath $rp -RunId 'cd' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = $a; snapshotId = $b; cloneVmId = $null }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $script:pp = Join-Path $script:rp 'plan.json'
        @{ schemaVersion = 6; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; policy = @{ keepSnapshotDays = 7 } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com'; TenantId = 't' } }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE SAME RACE: Azure lists each lock for a while after its removal, and both copies are still deleted' {
        CdAzure -Copies 'ret-p', 'ret-s' -ListedReads 2
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @($r.Deleted) | Should -HaveCount 1
        $global:CdSim.There.Count | Should -Be 0
        $global:CdSim.Locked.Count | Should -Be 0
    }

    It 'a ScopeLocked answer after the lock reads gone is tried again' {
        CdAzure -Copies 'ret-p', 'ret-s' -ScopeLockedDeletes 1
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @($r.Deleted) | Should -HaveCount 1
        $global:CdSim.There.Count | Should -Be 0
        @(CdEvents $script:rp | Where-Object { $_.step -eq 'azureops:removeSnapshot' -and $_.outcome -eq 'retry' } | ForEach-Object { ($_.snapshotId -split '/')[-1] } | Sort-Object) |
            Should -Be @('ret-p', 'ret-s') -Because 'each line names its copy'
    }

    It 'RETENTION-LOCK-PUTBACK-1: a refused delete gets its lock back, is not recorded as deleted, and is named in a retention line' {
        CdAzure -Copies 'ret-p', 'ret-s' -RefuseCopies 'ret-p'
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @($r.Deleted) | Should -HaveCount 0
        @($r.NotDeleted) | Should -HaveCount 1
        @(@($r.NotDeleted)[0].Failed)[0].Reason | Should -Match 'The product put the lock back on the copy\.$'
        $global:CdSim.Locked.Contains((CdSnap 'ret-p')) | Should -BeTrue -Because 'an unlocked copy is one any Contributor or script can delete'
        $global:CdSim.There.Contains((CdSnap 'ret-s')) | Should -BeFalse -Because 'the other copy is still tried'
        $line = @(CdEvents $script:rp | Where-Object { $_.step -eq 'retention' -and $_.outcome -eq 'fail' })
        $line | Should -HaveCount 1
        $line[0].vmId | Should -Be $script:vm
        $line[0].detail | Should -Match '^The product did not delete the safety copy ret-p: .*AuthorizationFailed.* The product put the lock back on the copy\.$'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).PSObject.Properties['retention'] | Should -BeNullOrEmpty -Because 'a copy is still in Azure'
        }
    }

    It 'review: a machine a restore or a wave holds when its copies come due keeps its locks and its copies' {
        CdAzure -Copies 'ret-p', 'ret-s'
        # Eligible by age, then held: the hold is asked just before the unlock.
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $true }
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @($r.Eligible) | Should -HaveCount 1
        @($r.Deleted) | Should -HaveCount 0
        @($global:CdSim.Calls | Where-Object { $_ -like 'unlock *' -or $_ -like 'delete *' }) | Should -HaveCount 0 -Because 'a held machine''s lock is never removed'
        $global:CdSim.Locked.Count | Should -Be 2
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).PSObject.Properties['retention'] | Should -BeNullOrEmpty
        }
    }
    It 'RETENTION-LOCK-PUTBACK-1: a lock that cannot be put back is recorded in the retention line and the result' {
        CdAzure -Copies 'ret-p', 'ret-s' -RefuseCopies 'ret-p' -LockWriteFails
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @(@($r.NotDeleted)[0].Failed)[0].Reason | Should -Match 'The copy has no lock\. The product could not put the lock back: .*AuthorizationFailed'
        @(CdEvents $script:rp | Where-Object { $_.step -eq 'retention' -and $_.outcome -eq 'fail' -and $_.detail -match 'The copy has no lock\. The product could not put the lock back' }) | Should -HaveCount 1
    }

    It 'RETENTION-LOCK-PUTBACK-1: a refused delete on one machine does not stop the cleanup of the next machine' {
        $vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $vm2; a = (CdSnap 'two-p') } {
            New-VmfStateDoc -RunPath $rp -RunId 'cd' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = $a; snapshotId = $null; cloneVmId = $null }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        @{ schemaVersion = 6; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; policy = @{ keepSnapshotDays = 7 } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm2; wave = 'w1'; policy = @{ keepSnapshotDays = 7 } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        CdAzure -Copies 'ret-p', 'ret-s', 'two-p' -RefuseCopies 'ret-p'
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc ([datetime]::UtcNow.AddDays(30)) -Confirm:$false
        @($r.Deleted | ForEach-Object VmId) | Should -Be @($vm2)
        $global:CdSim.There.Contains((CdSnap 'two-p')) | Should -BeFalse
    }
}