#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-3: the safety copies are the restore chain, and now something
# protects them.
#
# Question, 2026-09-05: are the snapshots locked, so that nobody can delete
# them and break the restore chain they make up? They were not. Now: a CanNotDelete lock goes on each copy the moment it is
# taken; the copies are checked before the first change to the machine;
# retention removes the lock before it deletes; and every one of those is a
# sentence on the run page, never a raw step name.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:ops  = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
    $script:sm   = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    $script:ret  = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Remove-VmfExpiredSafetyCopies.ps1') -Raw
    $script:page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    # PUBLIC-SYNC-1: lab/ does not ship to the public repository.
    $labTeardown = Join-Path $script:repoRoot 'lab' 'teardown.ps1'
    $script:teardown = if (Test-Path $labTeardown) { Get-Content $labTeardown -Raw } else { $null }
    $script:rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json

    function Global:LockPlan {
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/lockvm'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                platformManaged = $false; location = 'centralus'
            }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]@{ safetyCopy = 'pristine'; onIacManaged = 'proceed' }
        }
    }
}
AfterAll { Remove-Item 'function:\LockPlan' -ErrorAction SilentlyContinue }

Describe 'SAFETY-3: the azureops boundary - lock, unlock, still there?' {
    It 'the lock is CanNotDelete, under one name, and says why on the lock itself' {
        $script:ops | Should -Match "VmfSafetyCopyLockName = 'vmf-safety-copy'"
        $script:ops | Should -Match 'New-AzResourceLock -LockLevel CanNotDelete -LockName \$script:VmfSafetyCopyLockName'
        $script:ops | Should -Match '-LockNotes \$Notes'
    }

    It 'placing the lock is idempotent: a lock already there is the outcome wanted' {
        Mock -ModuleName VmMigrationFactory Get-AzResourceLock { [pscustomobject]@{ LockId = '/snap/a/providers/Microsoft.Authorization/locks/vmf-safety-copy' } }
        Mock -ModuleName VmMigrationFactory New-AzResourceLock { throw 'must not be called' }
        $id = InModuleScope VmMigrationFactory { Lock-VmfSnapshot -SnapshotId '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' -Notes 'n' }
        $id | Should -Match 'locks/vmf-safety-copy$'
        Should -Invoke -ModuleName VmMigrationFactory New-AzResourceLock -Times 0
    }

    It 'and places it when there is none' {
        Mock -ModuleName VmMigrationFactory Get-AzResourceLock { $null }
        Mock -ModuleName VmMigrationFactory New-AzResourceLock { [pscustomobject]@{ LockId = '/lock/new' } }
        $id = InModuleScope VmMigrationFactory { Lock-VmfSnapshot -SnapshotId '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' -Notes 'why' }
        $id | Should -Be '/lock/new'
        Should -Invoke -ModuleName VmMigrationFactory New-AzResourceLock -Times 1 -ParameterFilter { $LockLevel -eq 'CanNotDelete' -and $LockNotes -eq 'why' }
    }

    It 'removing a lock that is already gone is success, because retention must be re-runnable' {
        Mock -ModuleName VmMigrationFactory Remove-AzResourceLock { throw 'LockNotFound: no lock with that name' }
        # COPY-DELETE-LOCK-RACE-1: the unlock then reads the lock back.
        Mock -ModuleName VmMigrationFactory Get-AzResourceLock { $null }
        { InModuleScope VmMigrationFactory { Unlock-VmfSnapshot -SnapshotId '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' } } | Should -Not -Throw
        Mock -ModuleName VmMigrationFactory Remove-AzResourceLock { throw 'AuthorizationFailed: no' }
        { InModuleScope VmMigrationFactory { Unlock-VmfSnapshot -SnapshotId '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' } } | Should -Throw '*AuthorizationFailed*'
    }

    It '"still there?" answers no on NotFound and passes any other failure up' {
        # SEC-1 / F10: asked of the resource id through ARM, so the answer is
        # about THIS snapshot and not about a same-named one in whichever
        # subscription the process happened to be pointed at. Answering "yes"
        # about the wrong snapshot would let a migration pass the point of no
        # return with no safety copy behind it.
        $snapId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a'
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
        InModuleScope VmMigrationFactory -Parameters @{ id = $snapId } { Test-VmfSnapshotExists -SnapshotId $id } | Should -BeFalse
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"name":"a"}' } }
        InModuleScope VmMigrationFactory -Parameters @{ id = $snapId } { Test-VmfSnapshotExists -SnapshotId $id } | Should -BeTrue
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 504; Content = 'Gateway timeout' } }
        { InModuleScope VmMigrationFactory -Parameters @{ id = $snapId } { Test-VmfSnapshotExists -SnapshotId $id } } | Should -Throw '*Gateway timeout*'
    }

    It 'and it refuses an id that names no subscription, rather than guessing one' {
        # An id missing its subscription is not a weaker id - it is not an id,
        # and acting on it would mean acting on whatever the ambient context
        # resolved.
        { InModuleScope VmMigrationFactory { Test-VmfSnapshotExists -SnapshotId '/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' } } |
            Should -Throw '*must name the subscription*'
        { InModuleScope VmMigrationFactory { Remove-VmfSnapshot -SnapshotId '/resourceGroups/rg/providers/Microsoft.Compute/snapshots/a' } } |
            Should -Throw '*must name the subscription*'
    }

    It 'the role map carries the two lock actions in the execute role, each with its why' {
        $new = $script:rbac.operations | Where-Object cmdlet -EQ 'New-AzResourceLock'
        $rem = $script:rbac.operations | Where-Object cmdlet -EQ 'Remove-AzResourceLock'
        $new.role | Should -Be 'execute'
        $new.actions | Should -Contain 'Microsoft.Authorization/locks/write'
        $new.why | Should -Match 'SAFETY-3'
        $rem.role | Should -Be 'execute'
        $rem.actions | Should -Contain 'Microsoft.Authorization/locks/delete'
    }
}

Describe 'SAFETY-3: each copy is locked the moment it exists, and the record says so' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lock-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'lock-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'the pristine copy: snapshot, then lock, with the sentence for whoever finds the lock' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:LockPlan) -RunPath $rp -RunId 'lock-test'
            New-VmfStateDoc -RunPath $rp -RunId 'lock-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus' } }
            (Invoke-VmfStepSafetyPristine -Context $ctx).Next | Should -Be 'GUEST_PREP'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc.safety.pristineSnapshotLocked | Should -BeTrue
            $doc.safety.pristineSnapshotId | Should -Match 'pristine$'
        }
        Should -Invoke -ModuleName VmMigrationFactory Lock-VmfSnapshot -Times 1 -Exactly -ParameterFilter {
            $SnapshotId -match 'pristine$' -and $Notes -match 'removes this lock and deletes the copy' -and $Notes -match 'lock-test' }
    }

    It 'the prepared copy: the same, and the pristine record is kept (the merge lesson)' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:LockPlan) -RunPath $rp -RunId 'lock-test'
            New-VmfStateDoc -RunPath $rp -RunId 'lock-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus' } }
            Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null
            (Invoke-VmfStepSafetyCopy -Context $ctx).Next | Should -Be 'CONVERTING'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc.safety.snapshotLocked | Should -BeTrue
            $doc.safety.pristineSnapshotLocked | Should -BeTrue
            $doc.safety.pristineSnapshotId | Should -Not -BeNullOrEmpty
        }
        Should -Invoke -ModuleName VmMigrationFactory Lock-VmfSnapshot -Times 2 -Exactly
    }

    It 'when PRECHECK found the identity cannot lock, the copy is still taken, unlocked, and the record and the log say so' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:LockPlan) -RunPath $rp -RunId 'lock-test'
            New-VmfStateDoc -RunPath $rp -RunId 'lock-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus' } }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $false }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            (Invoke-VmfStepSafetyPristine -Context $ctx).Next | Should -Be 'GUEST_PREP'
            $after = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $after.safety.pristineSnapshotLocked | Should -BeFalse
            $after.safety.pristineSnapshotId | Should -Match 'pristine$'
            $warn = @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'lockSnapshot' -and $_.outcome -eq 'warn' })
            $warn.Count | Should -Be 1
            $warn[0].detail | Should -Match 'was not locked: the product''s managed identity cannot place resource locks\. Nothing prevents the deletion of the copy\.$'
        }
        Should -Invoke -ModuleName VmMigrationFactory Lock-VmfSnapshot -Times 0
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1
    }

    It 'PRECHECK asks about the optional lock actions once and records the answer for the lock steps' {
        $script:sm | Should -Match 'Get-VmfRequiredActions -Optional'
        $script:sm | Should -Match "NotePropertyName locksAllowed -NotePropertyValue \(\`$optionalMissing\.Count -eq 0\)"
        $script:sm | Should -Match 'The safety copies will be taken but not locked, so nothing stops their deletion\.'
    }

    It 'the lock is recorded in the state document contract (v8), not smuggled past it' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        # v8 added the locks; SAFETY-RETRY-1 moved the document to v9 (earlierCopies).
        $schema.properties.schemaVersion.const | Should -BeGreaterOrEqual 8
        $schema.properties.safety.properties.PSObject.Properties.Name | Should -Contain 'pristineSnapshotLocked'
        $schema.properties.safety.properties.PSObject.Properties.Name | Should -Contain 'snapshotLocked'
        $schema.properties.safety.properties.PSObject.Properties.Name | Should -Contain 'locksAllowed'
        $script:sm | Should -Match 'pristineSnapshotLocked -NotePropertyValue \$locked'
        $script:sm | Should -Match "NotePropertyName snapshotLocked -NotePropertyValue \`$locked"
    }
}

Describe 'SAFETY-3: before the machine is changed, the copies are checked' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lock-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'lock-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a missing copy stops the migration with the machine untouched, in a sentence the stop table knows' {
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $SnapshotId -notmatch 'pristine' }
        $err = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:LockPlan) -RunPath $rp -RunId 'lock-test'
            New-VmfStateDoc -RunPath $rp -RunId 'lock-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ osDisk = @{ managedDiskId = '/disks/os'; name = 'os' }; location = 'centralus'; nics = @() } }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                pristineSnapshotId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/lockvm-pristine'
                snapshotId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/lockvm-prepared'
                cloneVmId = $null; pristineSnapshotLocked = $true; snapshotLocked = $true }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            try { Invoke-VmfStepConverting -Context $ctx | Out-Null; 'no error' } catch { $_.Exception.Message }
        }
        $err | Should -Match '^Safety copy missing before the machine is changed: .*lockvm-pristine\. The machine is unchanged\.$'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking -Times 0
        InModuleScope VmMigrationFactory -Parameters @{ m = $err } { Get-VmfErrorStopReason -Message $m } | Should -Be 'safetyCopyMissing'
        $reason = $script:stops.reasons | Where-Object code -EQ 'safetyCopyMissing'
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'afterFix'
    }

    # REBUILD-REMOVE-ENGINE-1: the only resume past the point of no return was Path B after the delete, which is gone; every CONVERTING checks the copies now.
    It 'a machine with no copies (policy: none) is not asked about them' {
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { throw 'must not be asked' }
        $script:sm | Should -Match 'if \(\$copyIds\.Count\) \{\s*\$missing = @\(Invoke-VmfAzOperation -Name ''verifySafetyCopies'''
    }
}

Describe 'SAFETY-3: retention removes the lock before it deletes, and the lab teardown does the same' {
    It 'the unlock comes first, through the same operation wrapper, so it is an event too' {
        # COPY-DELETE-LOCK-RACE-1: retention and Delete the copies as well call
        # the same two helpers, and each goes through the operation wrapper.
        $runCopies = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RunSafetyCopies.ps1') -Raw
        $runCopies | Should -Match "Invoke-VmfAzOperation -Name 'unlockSnapshot'"
        $runCopies | Should -Match "Invoke-VmfAzOperation -Name 'removeSnapshot'"
        # RETENTION-LOCK-PUTBACK-1: retention deletes through Remove-VmfRunSafetyCopies.
        $script:ret | Should -Match '(?s)Remove-VmfRunSafetyCopies -RunPath.*?-Step ''retention'''
        $runCopies.IndexOf('Invoke-VmfSafetyCopyUnlock -SnapshotId $snapId') | Should -BeGreaterThan 0
        $runCopies.IndexOf('Invoke-VmfSafetyCopyUnlock -SnapshotId $snapId') | Should -BeLessThan $runCopies.IndexOf('Invoke-VmfSafetyCopyDelete -SnapshotId $snapId')
    }

    It 'the lab teardown removes the safety-copy locks inside the lab group before it deletes anything' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'lab'))) {
        $script:teardown | Should -Match "\`$_\.name -eq 'vmf-safety-copy' -and \`$_\.id -like ""\*/resourceGroups/\`$ResourceGroup/\*"""
        $script:teardown.IndexOf('vmf-safety-copy') | Should -BeLessThan $script:teardown.IndexOf('az resource delete --ids')
    }
}

Describe 'SAFETY-3: the run page says what happened to the copies, never a step name' {
    It 'the lock, the check, the unlock and the delete are mapped BEFORE the snapshot catch-all' {
        foreach ($k in 'lockSnapshot', 'unlockSnapshot', 'verifySafetyCopies', 'removeSnapshot') {
            $script:page.IndexOf("[/$k/") | Should -BeGreaterThan 0 -Because $k
            $script:page.IndexOf("[/$k/") | Should -BeLessThan $script:page.IndexOf('[/pristineSnapshot/i') -Because "'$k' contains 'snapshot' and would match the catch-all first"
        }
    }

    It 'each has a sentence, and the failed check has its own' {
        $script:page | Should -Match "lockCopy:\s+'Locked the safety copy so nobody can delete it before its retention ends\.'"
        $script:page | Should -Match "lockCopySkipped:\s+`"The safety copy was not locked\. The product's managed identity cannot place locks, so nothing prevents the deletion of the copy\.`""
        $script:page | Should -Match "if \(/\(\^\|:\)lockSnapshot\\b/\.test\(e\.step \?\? ''\) && e\.outcome === 'warn'\) return UX_STEP\.lockCopySkipped;"
        $script:page | Should -Match "unlockCopy:\s+'Removed the lock from the safety copy, so that the copy can be deleted\.'"
        $script:page | Should -Match "verifyCopies:\s+'Checked that the safety copies are still there, before the machine is changed\.'"
        $script:page | Should -Match "verifyCopiesFailed:\s+'A safety copy is missing\. The migration stopped before changing the machine\.'"
        $script:page | Should -Match "deleteCopy:\s+'Deleted the safety copy\.'"
        $script:page | Should -Match "if \(/verifySafetyCopies/\.test\(e\.step \?\? ''\) && e\.outcome === 'fail'\) return UX_STEP\.verifyCopiesFailed;"
    }
}
