#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREVIEW-PUTBACK-1: a rollback or a put back of a Preview move needs the
# preview feature too.
#
# THE DEFECT. A move by the in-place upgrade (Preview) is Path A: Azure resizes
# the machine in place across the kinds of temporary disk, which it allows only
# with Microsoft.Compute/VMTempDiskResizePreview registered on the subscription
# (MEASURED 2026-11-01: refused without it). Its way back - the automatic
# rollback, and Restore this machine from the first copy - resizes it back
# across the same kinds. Checking read the feature before the move, and nothing
# read it before the way back. A subscription that unregistered the feature
# after the move got an Azure refusal of the resize while the machine was
# stopped: the machine was left stopped.
#
# Project rules applied (CLAUDE.md, the builder brief): one change window - a
# stop after a change puts the machine back at once; every disk back, or
# refuse before any change. A rebuild of the way back is not used: it deletes
# the system-assigned identity and the extensions the Preview kept, and that
# needs a named acceptance (IDENTITY-LOSS-1, REBUILD-ACCEPT-1).
#
# So both ways back read the feature BEFORE they stop the machine or make a
# disk, and refuse there when it is not registered or cannot be read - unless
# the machine is on its original size already (a forward resize Azure refused):
# then the way back changes no temporary disk and needs no feature.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute"
    $script:vmId = "$($script:sub)/virtualMachines/win-01"
    $script:started = '2026-11-03T08:30:00.0000000Z'
    $script:original = 'Standard_D4ds_v4'
    $script:target = 'Standard_D4ds_v6'

    # The target a move started on (STATE-TARGET-1), with its method.
    function Global:PpStarted([string]$Method = 'preview') {
        [pscustomobject]@{ path = 'A'; series = 'v6'; acceleratedNetworking = ''; diskUpgrade = ''
            size = $script:target; controller = 'NVMe'
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp'; tempDisks = 1
                choice = [pscustomobject]@{ option = 'v6'; source = 'person'; method = $Method } } }
    }
    function Global:PpEntry([string]$Method = 'preview') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = 'A'; wave = 'w1'
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; diskArch = 'nvme-temp'
                choice = [pscustomobject]@{ option = 'v6'; source = 'person'; method = $Method } }
            policy = [pscustomobject]@{ targetGeneration = 'v6' } }
    }
    # A Windows machine moved from D4ds_v4 to D4ds_v6, its first copies taken.
    # -Kind writes a rollback checkpoint, as the failed step does.
    function Global:PpRun {
        param([string]$Method = 'preview', [string]$Kind = '', [string]$State = 'VALIDATING', [switch]$Migrated)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; st = $State; kind = $Kind; started = $script:started
            orig = $script:original; tgt = (Global:PpStarted $Method); entry = (Global:PpEntry $Method); mig = [bool]$Migrated } {
            param($rp, $id, $sub, $st, $kind, $started, $orig, $tgt, $entry, $mig)
            Initialize-VmfRun -RunPath $rp -RunId 'pp' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'pp' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'win-01'; size = $orig; controller = 'SCSI'; location = 'centralus'; osType = 'Windows'; zones = @(); capacityReservationGroupId = $null
                        osDisk = [pscustomobject]@{ name = 'win-01-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/win-01-os"; deleteOption = 'Delete' }
                        dataDisks = @(); tags = @{}; nics = @() }
                    startedTarget = $tgt })
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/snapshots/win-01-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/win-01-pristine"; pristineSnapshotLocked = $true })
            if ($mig) { $doc.state = 'MIGRATED' }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
            if ($kind) {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok | Out-Null
                Set-VmfRollbackPending -Context (New-VmfContext -PlanEntry $entry -RunPath $rp -RunId 'pp') -Kind $kind -State $st -ReasonCode 'validationFailed' -Detail 'The health check did not answer.'
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc.rollbackPending.startedUtc = $started
                $null = Complete-VmfTestCapture $doc
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        $rp
    }
    function Global:PpCtx($rp, [string]$Method = 'preview') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = (Global:PpEntry $Method) } { param($rp, $e) New-VmfContext -PlanEntry $e -RunPath $rp -RunId 'pp' }
    }
    function Global:PpDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:PpLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }

    # The state of the feature Azure gives: Registered, NotRegistered,
    # Unregistered, or 'unread' for a read that failed.
    function Global:PpFeature([string]$State) {
        $global:ppFeature = $State
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState {
            $global:pp.calls.Add('featureRead')
            if ($global:ppFeature -eq 'unread') { return @{ Read = $false; Registered = $false; State = $null; SubscriptionName = 'Applications'; Detail = 'the read of VMTempDiskResizePreview failed: Forbidden' } }
            @{ Read = $true; Registered = ($global:ppFeature -eq 'Registered'); State = $global:ppFeature; SubscriptionName = 'Applications'; Detail = '' }
        }
    }
    # Azure for a way back. Every call that changes the machine or makes a
    # disk is recorded in order.
    function Global:PpMockAzure {
        $global:pp = @{ calls = [System.Collections.Generic.List[string]]::new(); sizeNow = $script:target; sizeReadFails = $false; power = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState {
            $global:pp.calls.Add('powerRead')
            if ($global:pp.power -eq 'fail') { throw 'The read of the power state was refused.' }
            $global:pp.power
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:pp.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:pp.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize {
            $global:pp.calls.Add('sizeRead')
            if ($global:pp.sizeReadFails) { throw 'The read of the machine was refused.' }
            $global:pp.sizeNow
        }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'win-01-os'; id = "$($script:sub)/disks/win-01-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:pp.calls.Add("create:$DiskName"); "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pp.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:pp.calls.Add('data'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:pp.calls.Add('an'); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { $global:pp.calls.Add('type') }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'win-01' } }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
    }
    # Every call that changes the machine or makes a disk - not the reads.
    function Global:PpChanges { @($global:pp.calls | Where-Object { $_ -notin @('featureRead', 'sizeRead', 'powerRead') }) }
    function Global:PpCheck([string]$Kind = 'rollback', [string]$Method = 'preview', [string]$SizeNow = '') {
        InModuleScope VmMigrationFactory -Parameters @{ k = $Kind; m = $Method; sn = $SizeNow; id = $script:vmId; s = $script:subId; o = $script:original; rp = $global:ppRp } {
            param($k, $m, $sn, $id, $s, $o, $rp)
            Get-VmfPreviewPutBackCheck -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id; SubscriptionId = $s; Rg = 'rg-app'; VmName = 'win-01' }) -Kind $k -Method $m -Size $o -SizeNow $sn
        }
    }
}
AfterAll {
    Remove-Item 'function:\PpStarted', 'function:\PpEntry', 'function:\PpRun', 'function:\PpCtx', 'function:\PpDoc', 'function:\PpLog', 'function:\PpFeature',
        'function:\PpMockAzure', 'function:\PpChanges', 'function:\PpCheck' -ErrorAction SilentlyContinue
    Remove-Variable pp, ppFeature, ppRp -Scope Global -ErrorAction SilentlyContinue
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vmf-pp-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'PREVIEW-PUTBACK-1: the method a move started with' {
    It 'the record of the move it started wins over the plan entry - Azure did what the record says' {
        InModuleScope VmMigrationFactory -Parameters @{ st = (Global:PpStarted 'preview'); e = (Global:PpEntry 'in-place') } {
            param($st, $e)
            Get-VmfStartedMoveMethod -Doc ([pscustomobject]@{ captured = [pscustomobject]@{ startedTarget = $st } }) -PlanEntry $e | Should -Be 'preview'
        }
    }
    It 'with no record of the move, the plan entry; with neither, no method' {
        InModuleScope VmMigrationFactory -Parameters @{ e = (Global:PpEntry 'preview') } {
            param($e)
            Get-VmfStartedMoveMethod -Doc ([pscustomobject]@{ captured = [pscustomobject]@{} }) -PlanEntry $e | Should -Be 'preview'
            Get-VmfStartedMoveMethod -Doc ([pscustomobject]@{}) | Should -Be ''
            Get-VmfStartedMoveMethod -Doc $null | Should -Be ''
        }
    }
    It 'a record from before the method was saved (no choice) is no method, whatever the entry says now' {
        InModuleScope VmMigrationFactory -Parameters @{ e = (Global:PpEntry 'preview') } {
            param($e)
            $old = [pscustomobject]@{ path = 'A'; size = 'Standard_D4ds_v6'; target = [pscustomobject]@{ size = 'Standard_D4ds_v6' } }
            Get-VmfStartedMoveMethod -Doc ([pscustomobject]@{ captured = [pscustomobject]@{ startedTarget = $old } }) -PlanEntry $e | Should -Be ''
        }
    }
}

Describe 'PREVIEW-PUTBACK-1: the check before a way back' {
    BeforeEach { Global:PpMockAzure; $global:ppRp = Global:PpRun }
    AfterEach { if ($global:ppRp -and (Test-Path $global:ppRp)) { Remove-Item $global:ppRp -Recurse -Force } }

    It 'a move that is not a Preview reads nothing: <Method>' -ForEach @(@{ Method = 'in-place' }, @{ Method = 'rebuild' }, @{ Method = '' }) {
        Global:PpFeature 'NotRegistered'
        Global:PpCheck -Method $Method | Should -BeNullOrEmpty
        @($global:pp.calls) | Should -HaveCount 0 -Because 'only a Preview move needs the feature for its way back'
    }
    It 'registered: the way back goes on, and the words name the feature, the subscription and the size' {
        Global:PpFeature 'Registered'
        $r = Global:PpCheck
        $r.Refuse | Should -BeFalse
        $r.Detail | Should -Match 'VMTempDiskResizePreview'
        $r.Detail | Should -Match ([regex]::Escape("Applications ($($script:subId))"))
        $r.Detail | Should -Match $script:original
        @($global:pp.calls) | Should -Be @('featureRead') -Because 'the size is read only when the feature is not registered'
    }
    It 'not registered, the machine on its new size: refused, naming the feature, the subscription and the state Azure gives (<State>)' -ForEach @(
        @{ State = 'NotRegistered' }, @{ State = 'Unregistered' }, @{ State = 'Unregistering' }, @{ State = 'Pending' }
    ) {
        Global:PpFeature $State
        $r = Global:PpCheck
        $r.Refuse | Should -BeTrue
        $r.Detail | Should -Match 'in-place upgrade \(Preview\)'
        $r.Detail | Should -Match 'VMTempDiskResizePreview'
        $r.Detail | Should -Match ([regex]::Escape("Applications ($($script:subId))"))
        $r.Detail | Should -Match ([regex]::Escape("Azure gives its state as $State"))
        $r.Detail | Should -Not -Match 'register it for you|registers' -Because 'the product tells, and never registers'
    }
    It 'a read that fails is not a yes: refused, and the words say the product could not read it' {
        Global:PpFeature 'unread'
        $r = Global:PpCheck
        $r.Refuse | Should -BeTrue
        $r.Detail | Should -Match 'could not read its state'
        $r.Detail | Should -Match 'Forbidden'
    }
    It 'not registered, but the machine is on its original size already (Azure refused the forward resize): the way back changes no temporary disk, so it goes on' {
        Global:PpFeature 'NotRegistered'
        $global:pp.sizeNow = $script:original.ToLowerInvariant()
        $r = Global:PpCheck
        $r.Refuse | Should -BeFalse
        $r.Detail | Should -Match 'does not need the preview feature'
    }
    It 'the size the caller read already is used, and not read again' {
        Global:PpFeature 'NotRegistered'
        (Global:PpCheck -SizeNow $script:original).Refuse | Should -BeFalse
        @($global:pp.calls) | Should -Not -Contain 'sizeRead'
        (Global:PpCheck -SizeNow $script:target).Refuse | Should -BeTrue
    }
    It 'not registered and the size cannot be read: unknown is not a yes - refused' {
        Global:PpFeature 'NotRegistered'
        $global:pp.sizeReadFails = $true
        (Global:PpCheck).Refuse | Should -BeTrue
    }
    It 'a lease lost during the size read is not an answer: it stops this worker, and nothing is refused in its name' {
        Global:PpFeature 'NotRegistered'
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { throw 'The lease was lost - abandon this VM.' }
        { Global:PpCheck } | Should -Throw '*abandon this VM*'
    }
    It 'the words tell the person what to do next: <Kind>' -ForEach @(
        @{ Kind = 'rollback'; Next = 'Restore this machine' }, @{ Kind = 'restore'; Next = 'Nothing on the machine changed' }
    ) {
        Global:PpFeature 'NotRegistered'
        (Global:PpCheck -Kind $Kind).Detail | Should -Match $Next
    }
    It 'the check makes no change in Azure: it never registers the feature' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PreviewFeatureGate.ps1')
        $code | Should -Not -Match 'register/action|Register-Az|-Method\s+(POST|PUT)'
    }
}

Describe 'PREVIEW-PUTBACK-1: the automatic rollback of a Preview move' {
    BeforeEach { Global:PpMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: not registered - the rollback is not started: no disk made, no stop, no resize' {
        $script:rp = Global:PpRun
        Global:PpFeature 'NotRegistered'
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c } }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'VMTempDiskResizePreview'
        $err.Exception.Data['vmfRollbackUntouched'] | Should -BeTrue
        $err.Exception.Data['vmfRollbackReason'] | Should -Be 'previewRollbackNotRegistered'
        @(Global:PpChanges) | Should -HaveCount 0 -Because "the machine stays as the failed step left it: $(@($global:pp.calls) -join ', ')"
        (Global:PpLog $script:rp) | Should -Match '"step":"rollback".*"outcome":"fail"|"outcome":"fail".*"step":"rollback"'
    }
    It 'through the checkpoint: its own stop reason, the machine changed, and the words keep the original cause' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'NotRegistered'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'previewRollbackNotRegistered'
        $stop.machineState | Should -Be 'changed' -Because 'the move changed the machine'
        $stop.detail | Should -Match 'the rollback stopped before it changed the machine'
        $stop.detail | Should -Match 'VMTempDiskResizePreview'
        $stop.detail | Should -Match 'health check did not answer'
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        @(Global:PpChanges) | Should -HaveCount 0
    }
    It 'registered: the rollback goes on, back to the original size, and says the feature was read' {
        $script:rp = Global:PpRun
        Global:PpFeature 'Registered'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        @($global:pp.calls) | Should -Contain "size:$($script:original)"
        @($global:pp.calls)[0] | Should -Be 'featureRead' -Because 'the feature is read before any disk is made and before the stop'
        @($global:pp.calls) | Should -Contain 'start'
        (Global:PpLog $script:rp) | Should -Match 'is registered on subscription'
    }
    It 'the forward resize was refused (the machine is on its original size): the rollback puts it back, also with the feature not registered' {
        $script:rp = Global:PpRun
        Global:PpFeature 'NotRegistered'
        $global:pp.sizeNow = $script:original
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        @($global:pp.calls) | Should -Contain 'stop'
        @($global:pp.calls) | Should -Contain 'start' -Because 'a refusal here would leave a stopped machine that could be put back'
    }
    It 'an in-place move (not a Preview) never reads the feature' {
        $script:rp = Global:PpRun -Method 'in-place'
        Global:PpFeature 'NotRegistered'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp 'in-place') } { param($c) Invoke-VmfRollback -Context $c }
        @($global:pp.calls) | Should -Not -Contain 'featureRead'
        @($global:pp.calls) | Should -Contain "size:$($script:original)"
    }
    It 'the record of the move decides: a plan entry changed to in-place after a Preview move started still reads the feature' {
        $script:rp = Global:PpRun -Method 'preview'
        Global:PpFeature 'NotRegistered'
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp 'in-place') } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*VMTempDiskResizePreview*'
        @(Global:PpChanges) | Should -HaveCount 0
    }
    It 'the disks-only rollback (before the size changed) reads nothing: it changes no size' {
        $script:rp = Global:PpRun
        Global:PpFeature 'NotRegistered'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        @($global:pp.calls) | Should -Not -Contain 'featureRead'
        @($global:pp.calls) | Should -Contain 'start'
    }

    It 'kill-resume: a worker lost after the check, the next one asks Azure again before it goes on' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'Registered'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop'); throw 'The lease was lost - abandon this VM.' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        (Global:PpDoc $script:rp).rollbackPending.kind | Should -Be 'full' -Because 'the checkpoint stays until the rollback is done'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop') }
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:pp.calls | Where-Object { $_ -eq 'featureRead' }) | Should -HaveCount 2 -Because 'the check keeps no answer: every run asks Azure'
        @($global:pp.calls) | Should -Contain "size:$($script:original)"
    }
    It 'kill-resume: unregistered before the resume - its own stop reason, and the words do not say the rollback changed nothing' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'Registered'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop'); throw 'The lease was lost - abandon this VM.' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop') }
        $global:ppFeature = 'Unregistered'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'previewRollbackNotRegistered'
        $stop.detail | Should -Not -Match 'stopped before it changed the machine' -Because 'the worker before may have stopped the machine'
        $stop.detail | Should -Not -Match 'as the failed step left it' -Because 'the rollback''s own first worker stopped it'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'VMTempDiskResizePreview'
        $stop.detail | Should -Match ([regex]::Escape('Azure reports the machine as Stopped (deallocated), not Running'))
        $stop.detail | Should -Match 'stays stopped on its new size'
        $stop.detail | Should -Match ([regex]::Escape("on subscription Applications ($($script:subId)) again"))
        $stop.detail | Should -Match 'Restore this machine'
        $stop.detail | Should -Match 'does not rebuild the machine or start it on its new size'
        @($global:pp.calls | Where-Object { $_ -like 'size:*' }) | Should -HaveCount 0
        @($global:pp.calls | Where-Object { $_ -eq 'start' }) | Should -HaveCount 0 -Because 'since 2026-11-03 the machine stays as it is, and the person registers the feature again'
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }
    It 'kill-resume: a resumed refusal on a running machine says it runs' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'Registered'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop'); throw 'The lease was lost - abandon this VM.' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        $global:pp.power = 'PowerState/running'
        $global:ppFeature = 'NotRegistered'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'previewRollbackNotRegistered'
        $stop.detail | Should -Match ([regex]::Escape('Azure reports the machine as Running, on its new size'))
        $stop.detail | Should -Not -Match 'stays stopped'
    }
    It 'kill-resume: a power state that cannot be read is said as not read, never as running' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'Registered'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop'); throw 'The lease was lost - abandon this VM.' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        $global:pp.power = 'fail'
        $global:ppFeature = 'NotRegistered'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $stop = @($final.history)[-1]
        $stop.detail | Should -Match 'could not read its power state'
        $stop.detail | Should -Not -Match 'reports the machine as running'
    }
    It 'kill-resume: a lease lost during the power read stops this worker, and records no stop in its name' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'Registered'
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pp.calls.Add('stop'); throw 'The lease was lost - abandon this VM.' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { throw 'The lease was lost - abandon this VM.' }
        $global:ppFeature = 'NotRegistered'
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed } } | Should -Throw '*abandon this VM*'
        (Global:PpDoc $script:rp).rollbackPending.kind | Should -Be 'full' -Because 'the worker that holds the machine finishes the rollback'
        (Global:PpLog $script:rp) | Should -Not -Match 'could not read its power state' -Because 'a worker that lost the machine writes no refusal for it'
    }
    It 'the first run reads no power state: the machine is as the failed step left it' {
        $script:rp = Global:PpRun -Kind 'full'
        Global:PpFeature 'NotRegistered'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PpCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        (@($final.history)[-1]).detail | Should -Match 'as the failed step left it'
        @($global:pp.calls) | Should -Not -Contain 'powerRead'
    }
}

Describe 'PREVIEW-PUTBACK-1: Restore this machine after a Preview move' {
    BeforeEach { Global:PpMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: from the first copy, not registered - refused before a disk is made or the machine is stopped' {
        $script:rp = Global:PpRun -Migrated
        Global:PpFeature 'NotRegistered'
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw "*VMTempDiskResizePreview*Applications ($($script:subId))*Nothing on the machine changed*"
        @(Global:PpChanges) | Should -HaveCount 0 -Because "no disk made, no stop, no resize: $(@($global:pp.calls) -join ', ')"
        (Global:PpLog $script:rp) | Should -Match '"step":"putBack"'
        (Global:PpDoc $script:rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'no restore job was started'
    }
    It 'from the first copy, registered: the restore goes on, back to the original size' {
        $script:rp = Global:PpRun -Migrated
        Global:PpFeature 'Registered'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:pp.calls) | Should -Contain "size:$($script:original)"
        @($global:pp.calls) | Should -Contain 'start'
    }
    It 'from the other copy: the size does not change, so nothing is read' {
        $script:rp = Global:PpRun -Migrated
        Global:PpFeature 'NotRegistered'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:pp.calls) | Should -Not -Contain 'featureRead'
    }
    It 'a machine back on its original size already: the restore goes on with the feature not registered' {
        $script:rp = Global:PpRun -Migrated
        Global:PpFeature 'NotRegistered'
        $global:pp.sizeNow = $script:original
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:pp.calls) | Should -Contain 'start'
    }
    It 'an in-place move: the restore never reads the feature' {
        $script:rp = Global:PpRun -Method 'in-place' -Migrated
        Global:PpFeature 'NotRegistered'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:pp.calls) | Should -Not -Contain 'featureRead'
    }
    It '-WhatIf says the restore is refused, and writes nothing' {
        $script:rp = Global:PpRun -Migrated
        Global:PpFeature 'NotRegistered'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -WhatIf | Out-Null
        (Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw -ErrorAction SilentlyContinue) | Should -Not -Match 'putBack'
        @(Global:PpChanges) | Should -HaveCount 0
    }
}

Describe 'PREVIEW-PUTBACK-1: the stop reason' {
    It 'previewRollbackNotRegistered says what happened and what to do, with the machine changed' {
        $j = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($j.reasons | Where-Object code -eq 'previewRollbackNotRegistered')
        $r | Should -HaveCount 1
        $r[0].machine | Should -Be 'changed'
        $r[0].meaning | Should -Match 'VMTempDiskResizePreview'
        $r[0].whatToDo | Should -Match 'Register the preview feature VMTempDiskResizePreview'
        $r[0].whatToDo | Should -Match 'Restore this machine'
    }
    It 'the permission map says the way back reads the feature too' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $op = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' })
        $op | Should -HaveCount 1
        $op[0].why | Should -Match 'A rollback or a restore of a Preview move reads it too'
    }
}
