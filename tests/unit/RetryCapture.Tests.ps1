#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-RETRY-CAPTURE-1: a retry never overwrites the capture a put-back
# returns the machine to.
#
# A machine whose rollback failed is CHANGED. SAFETY-RETRY-1 refuses to try it
# again until it is rebuilt or restored - but a rebuild as the TARGET puts it
# on the target size, without its extensions, and the retry's PRECHECK then
# captured THAT as "how it was". Every put-back read that one field, so a
# later rollback or restore returned the machine to the rebuilt shape, not the
# original. Decided 2026-10-03: keep the first capture for the
# put-back; a retry may record the machine as it finds it for its own use.
#
# The state machine half (PRECHECK keeps it, a rollback after a retry uses it,
# kill-resume) is in StateMachine.Tests.ps1.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rcap'

    $script:sub = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/app01"
    $script:nic = "$($script:sub)/Microsoft.Network/networkInterfaces/app01-nic"

    # The first capture: v4, SCSI, accelerated networking off, a Premium SSD
    # OS disk and a Standard SSD data disk.
    function Global:RcOriginal {
        [pscustomobject]@{
            vmId = $script:vmId; name = 'app01'; osType = 'Linux'; location = 'centralus'
            size = 'Standard_D2s_v4'; controller = 'SCSI'; zones = @()
            osDisk = [pscustomobject]@{ name = 'app01-os'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/app01-os"; deleteOption = 'Delete'; skuName = 'Premium_LRS' }
            dataDisks = @([pscustomobject]@{ lun = 0; name = 'app01-d0'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/app01-d0"; caching = 'ReadOnly'; skuName = 'StandardSSD_LRS' })
            nics = @([pscustomobject]@{ id = $script:nic; primary = $true; acceleratedNetworking = $false })
            tags = @{}; capturedUtc = '2026-10-01T08:00:00Z'
        }
    }
    # The retry's capture: the machine as a rebuild as the target left it -
    # on the target size and NVMe, accelerated networking on, on disks made
    # from the copies (new ids), one of them changed to Premium SSD.
    function Global:RcRetry {
        [pscustomobject]@{
            vmId = $script:vmId; name = 'app01'; osType = 'Linux'; location = 'centralus'
            size = 'Standard_D2s_v6'; controller = 'NVMe'; zones = @()
            osDisk = [pscustomobject]@{ name = 'app01-os-rec'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/app01-os-rec"; deleteOption = 'Detach'; skuName = 'StandardSSD_LRS' }
            dataDisks = @([pscustomobject]@{ lun = 0; name = 'app01-d0-asitwas'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/app01-d0-asitwas"; caching = 'ReadOnly'; skuName = 'Premium_LRS' })
            nics = @([pscustomobject]@{ id = $script:nic; primary = $true; acceleratedNetworking = $true })
            tags = @{}; capturedUtc = '2026-10-02T09:00:00Z'
        }
    }
    function Global:RcDoc([switch]$NoOriginal) {
        $captured = [ordered]@{ vmConfig = (RcRetry); extensions = @(); sourceAcceleratedNetworking = $true }
        if (-not $NoOriginal) {
            $captured.original = [pscustomobject]@{ vmConfig = (RcOriginal); extensions = @('MicrosoftMonitoringAgent'); sourceAcceleratedNetworking = $false; capturedUtc = '2026-10-01T08:00:00Z' }
        }
        # Round-tripped, as a document read from the store is.
        $d = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); vmId = $script:vmId; state = 'MIGRATED'; history = @(); captured = [pscustomobject]$captured } |
            ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        # OLD-VERSION-READERS-REMOVE-4: each capture as PRECHECK writes it; -NoOriginal
        # leaves out only the first capture, which no record of this version lacks.
        if ($NoOriginal) { Complete-VmfTestCaptureShape $d.captured.vmConfig } else { $null = Complete-VmfTestCapture $d }
        $d
    }
}
AfterAll {
    Remove-Item function:RcOriginal, function:RcRetry, function:RcDoc -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'ROLLBACK-RETRY-CAPTURE-1: the capture a put-back uses' {

    It 'THE DEFECT: the shape is the FIRST capture''s - size, controller, accelerated networking, disk types' {
        InModuleScope VmMigrationFactory {
            $back = Get-VmfPutBackCapture -Doc (RcDoc)
            $back.size | Should -Be 'Standard_D2s_v4'
            $back.controller | Should -Be 'SCSI'
            @($back.nics)[0].acceleratedNetworking | Should -BeFalse
            $back.osDisk.skuName | Should -Be 'Premium_LRS'
            @($back.dataDisks)[0].skuName | Should -Be 'StandardSSD_LRS' -Because 'the type the first capture recorded for LUN 0'
        }
    }

    It 'and the disks are this attempt''s - the disks its safety copies are of' {
        InModuleScope VmMigrationFactory {
            $back = Get-VmfPutBackCapture -Doc (RcDoc)
            $back.osDisk.managedDiskId | Should -Match 'app01-os-rec$'
            $back.osDisk.name | Should -Be 'app01-os-rec'
            @($back.dataDisks)[0].managedDiskId | Should -Match 'app01-d0-asitwas$'
            @($back.dataDisks)[0].caching | Should -Be 'ReadOnly'
        }
    }

    It 'the stored captures are evidence and are never changed' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $before = $doc | ConvertTo-Json -Depth 30
            $null = Get-VmfPutBackCapture -Doc $doc
            ($doc | ConvertTo-Json -Depth 30) | Should -Be $before
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-4: with no first capture on record, a put-back stops - never this attempt''s capture' {
        InModuleScope VmMigrationFactory {
            { Get-VmfPutBackCapture -Doc (RcDoc -NoOriginal) } | Should -Throw '*holds no first capture*'
            Get-VmfOriginalCapture -Doc (RcDoc -NoOriginal) | Should -BeNullOrEmpty
            (Get-VmfOriginalCapture -Doc (RcDoc)).size | Should -Be 'Standard_D2s_v4'
        }
    }

    It 'a Generation 1 machine has no controller on record, and its put-back names none' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc.captured.original.vmConfig.controller = $null
            (Get-VmfPutBackCapture -Doc $doc).controller | Should -BeNullOrEmpty
        }
    }

    It 'an interface the first capture could not read keeps what this attempt found' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            @($doc.captured.original.vmConfig.nics)[0].acceleratedNetworking = $null
            @((Get-VmfPutBackCapture -Doc $doc).nics)[0].acceleratedNetworking | Should -BeTrue
        }
    }

    It 'the size a put-back asks about for accelerated networking is the first capture''s' {
        InModuleScope VmMigrationFactory {
            Get-VmfSourceAcceleratedNetworking -Doc (RcDoc) -PutBack | Should -BeFalse
            Get-VmfSourceAcceleratedNetworking -Doc (RcDoc) | Should -BeTrue -Because 'the move asks about the size this attempt found'
            Get-VmfSourceAcceleratedNetworking -Doc (RcDoc -NoOriginal) -PutBack | Should -BeNullOrEmpty -Because 'OLD-VERSION-READERS-REMOVE-4: a put-back never asks this attempt''s size in place of the first'
        }
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-1: the first capture is written once' {

    It 'the first PRECHECK keeps its own capture' {
        InModuleScope VmMigrationFactory {
            $r = New-VmfOriginalCaptureRecord -Doc ([pscustomobject]@{ vmId = 'x'; history = @() }) -Capture ([ordered]@{ size = 'Standard_D2s_v4'; capturedUtc = '2026-10-01T08:00:00Z' }) `
                -Extensions @('ext') -SourceAcceleratedNetworking $false
            $r.vmConfig.size | Should -Be 'Standard_D2s_v4'
            $r.capturedUtc | Should -Be '2026-10-01T08:00:00Z'
            @($r.extensions) | Should -Be @('ext')
            $r.sourceAcceleratedNetworking | Should -BeFalse
        }
    }

    It 'a later PRECHECK of a machine the product touched writes nothing - a retry or a resume finds it there' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc.history = @([pscustomobject]@{ tsUtc = '2026-10-01T08:05:00Z'; state = 'SAFETY_PRISTINE'; outcome = 'ok' })
            New-VmfOriginalCaptureRecord -Doc $doc -Capture ([ordered]@{ size = 'Standard_D2s_v6' }) | Should -BeNullOrEmpty
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-4: a touched machine with no first capture is refused - the capture being taken is never the first' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc -NoOriginal
            $doc.history = @([pscustomobject]@{ tsUtc = '2026-10-01T09:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; machineState = 'changed' })
            { New-VmfOriginalCaptureRecord -Doc $doc -Capture ([ordered]@{ size = 'Standard_E2s_v6' }) -SourceAcceleratedNetworking $null } |
                Should -Throw '*holds no first capture*does not start this attempt*'
        }
    }

    It 'no caller can replace it: Save-VmfCapturedFacts keeps the one there' {
        $rp = Join-Path $script:temp "rc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'rc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rc' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $ctx = [pscustomobject]@{ RunPath = $rp; VmId = $id }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ original = [ordered]@{ vmConfig = [ordered]@{ size = 'Standard_D2s_v4' } } }
            # The version the store writes (v16 added captured.original; v19, PREP-ROLLBACK-1, holds it).
            (Read-VmfStateDoc -RunPath $rp -VmId $id).schemaVersion | Should -Be 51   # SAFETY-CMK-1 took v21, ROLLBACK-DISKS-FIRST-1 v22, RECOVER-ALL-DISKS-1 v23, ROLLBACK-CRG-1 v24, SWAP-REFUSED-AFTER-STOP-1 v25, MADE-DISK-RECORD-1 v26, RESTORE-END-JOB-1 v27, FINISH-EMPTY-LUN-PROOF-1 v28, FINISH-KEPT-DISKS-1 v29, RESTORE-EARLIER-DELETE-1 v40
            Save-VmfCapturedFacts -Context $ctx -Facts @{ original = [ordered]@{ vmConfig = [ordered]@{ size = 'Standard_D2s_v6' } }; vmConfig = [ordered]@{ size = 'Standard_D2s_v6' } }
            $after = Read-VmfStateDoc -RunPath $rp -VmId $id
            $after.captured.original.vmConfig.size | Should -Be 'Standard_D2s_v4'
            $after.captured.vmConfig.size | Should -Be 'Standard_D2s_v6' -Because 'the attempt''s own capture is still written'
            # Only PRECHECK, on purpose, for a machine the product never touched.
            Save-VmfCapturedFacts -Context $ctx -Facts @{ original = [ordered]@{ vmConfig = [ordered]@{ size = 'Standard_D4s_v4' } } } -ReplaceOriginal
            (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.original.vmConfig.size | Should -Be 'Standard_D4s_v4'
        }
    }

    It 'while the product has never touched the machine, a later PRECHECK refreshes it - the owner may have changed the machine as a stop asked' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc.history = @([pscustomobject]@{ tsUtc = '2026-10-01T08:00:00Z'; state = 'PRECHECK'; outcome = 'ok' },
                [pscustomobject]@{ tsUtc = '2026-10-01T08:01:00Z'; state = 'NEEDS_DECISION'; outcome = 'ok'; reasonCode = 'targetTooFewNics'; machineState = 'untouched' })
            Test-VmfMachineTouched -Doc $doc | Should -BeFalse
            $r = New-VmfOriginalCaptureRecord -Doc $doc -Capture ([ordered]@{ size = 'Standard_D2s_v4'; capturedUtc = '2026-10-02T08:00:00Z' })
            $r.vmConfig.size | Should -Be 'Standard_D2s_v4'
            $r.capturedUtc | Should -Be '2026-10-02T08:00:00Z' -Because 'the new capture, not the one kept'
        }
    }

    It 'once the product took a copy, prepared the guest, changed or put back the machine, it is never refreshed' {
        InModuleScope VmMigrationFactory {
            foreach ($h in @(
                    [pscustomobject]@{ state = 'SAFETY_PRISTINE'; outcome = 'ok' },
                    [pscustomobject]@{ state = 'NEEDS_DECISION'; outcome = 'ok'; machineState = 'changed' },
                    [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; outcome = 'fail'; machineState = 'restored' })) {
                $doc = RcDoc
                $doc.history = @($h)
                Test-VmfMachineTouched -Doc $doc | Should -BeTrue -Because ($h | ConvertTo-Json -Compress)
                New-VmfOriginalCaptureRecord -Doc $doc -Capture ([ordered]@{ size = 'Standard_E2s_v6' }) | Should -BeNullOrEmpty
            }
            $doc = RcDoc
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2026-10-02T08:00:00Z' }) -Force
            Test-VmfMachineTouched -Doc $doc | Should -BeTrue -Because 'a restore is the product touching it'
        }
    }

    It 'the document with the first capture is valid against the state contract (v16)' {
        $rp = Join-Path $script:temp "rc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'rc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rc' -VmId $id -Wave 'w1' | Out-Null
            $ctx = [pscustomobject]@{ RunPath = $rp; VmId = $id }
            $original = New-VmfOriginalCaptureRecord -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id) -Capture ([ordered]@{ size = 'Standard_D2s_v4'; capturedUtc = '2026-10-01T08:00:00Z'; capacityReservationGroupId = $null; patchSettings = $null })
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = [ordered]@{ size = 'Standard_D2s_v4'; capacityReservationGroupId = $null; patchSettings = $null }; original = $original }
        }
        Get-Content (Join-Path $rp 'state' (Get-ChildItem (Join-Path $rp 'state') -Filter '*.json' | Select-Object -First 1).Name) -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') | Should -BeTrue
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-1: the retry rule, held to the fixture the run page uses' {
    BeforeAll {
        $script:cases = (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'retry-held.json') -Raw | ConvertFrom-Json -Depth 20).cases
    }

    It 'the fixture loaded' { @($script:cases).Count | Should -BeGreaterOrEqual 10 }

    It 'every case: the engine refuses a retry exactly when the fixture says it is held' {
        foreach ($c in @($script:cases)) {
            $held = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } {
                (Get-VmfRetryEntryState -Document $d) -eq 'PRECHECK' -and (Test-VmfRetryHeld -Doc $d)
            }
            $held | Should -Be ([bool]$c.held) -Because $c.why
        }
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-1: the restores put the machine back to the first capture' {

    It 'Restore this machine from the first copy reverts to the FIRST capture''s size and controller' {
        $rp = Join-Path $script:temp "rc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; d = (RcDoc); sub = $script:sub } {
            Initialize-VmfRun -RunPath $rp -RunId 'rc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rc' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue $d.captured -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/app01-prepared-a2"; pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/app01-pristine-a2"
                    cloneVmId = $null; locksAllowed = $true }) -Force
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                        schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; path = 'A'; assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [ordered]@{} }) })

            Mock Get-VmfEngineSubscriptionId { '11111111-2222-3333-4444-555555555555' }
            Mock Use-VmfSubscriptionContext { 'previous' }
            Mock Restore-VmfSubscriptionContext { }
            Mock Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'app01-os-rec'; id = "$sub/Microsoft.Compute/disks/app01-os-rec"; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
            Mock Get-VmfDataDiskInfo { , @() }
            Mock Get-VmfDiskShareCount { 1 }
            Mock Get-VmfVmSize { 'Standard_D2s_v6' }
            Mock Get-VmfVmCapacityReservationGroupId { $null }
            Mock Stop-VmfVmDeallocated { }
            Mock Start-VmfVm { }
            Mock Wait-VmfVmAgentReady { }
            $global:rcCalls = [System.Collections.Generic.List[string]]::new()
            Mock Set-VmfVmSizeAndController { $global:rcCalls.Add("size:$Size") }
            Mock Set-VmfOsDiskControllerTypes { }
            Mock New-VmfDiskFromSnapshot { "$sub/Microsoft.Compute/disks/$DiskName" }
            Mock Set-VmfVmOsDisk { }
            Mock Set-VmfVmDataDisks { @{ Applied = $true } }
            Mock Test-VmfSnapshotExists { $true }
            Mock Set-VmfNicAcceleratedNetworking { $global:rcCalls.Add("an:$Enabled"); $true }
            Mock Set-VmfManagedDiskSku { }
            Mock Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
            Mock Get-VmfSkuCatalog { @() }
            Mock Get-VmfVmConfig { [pscustomobject]@{ Name = 'app01' } }

            Restore-VmfVm -RunPath $rp -VmId $id -From pristine -Confirm:$false | Out-Null
            Should -Invoke Set-VmfVmSizeAndController -ParameterFilter { $Size -eq 'Standard_D2s_v4' -and $Controller -eq 'SCSI' } -Times 1 -Exactly
            Should -Invoke Set-VmfVmSizeAndController -ParameterFilter { $Size -eq 'Standard_D2s_v6' } -Times 0
            # Accelerated networking as the first capture found it: off.
            Should -Invoke Set-VmfNicAcceleratedNetworking -ParameterFilter { $Enabled -eq $false } -Times 1
            Should -Invoke Set-VmfNicAcceleratedNetworking -ParameterFilter { $Enabled -eq $true } -Times 0
            # The first size cannot carry accelerated networking (the first
            # capture says so), so it goes off BEFORE the size changes back -
            # the attempt's size could carry it, and asking about that size
            # would leave it to after, where Azure refuses the resize.
            $calls = @($global:rcCalls)
            [array]::IndexOf($calls, 'an:False') | Should -BeLessThan ([array]::IndexOf($calls, 'size:Standard_D2s_v4')) -Because ($calls -join ', ')
            # And the OS disk from the copy is made on the type the first capture recorded.
            Should -Invoke New-VmfDiskFromSnapshot -ParameterFilter { $SkuName -eq 'Premium_LRS' }
            Should -Invoke New-VmfDiskFromSnapshot -ParameterFilter { $SkuName -eq 'StandardSSD_LRS' } -Times 0
            Remove-Variable rcCalls -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'the disks a rollback or a restore made go back to the FIRST capture''s type for their place' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc | Add-Member -NotePropertyName rollback -Force -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-02T10:00:00Z'; path = 'A'
                    osDisk = [pscustomobject]@{ id = '/disks/os-made'; name = 'os-made' }
                    dataDisks = @([pscustomobject]@{ lun = 0; diskId = '/disks/d0-made'; diskName = 'd0-made' }) })
            $types = Get-VmfMadeDiskTypes -Doc $doc
            $types['/disks/d0-made'] | Should -Be 'StandardSSD_LRS' -Because 'the attempt found Premium SSD there; the first capture had Standard SSD'
            $types['/disks/os-made'] | Should -Be 'Premium_LRS'
        }
    }

    It 'a data disk made from a copy by a put-back is made on the FIRST capture''s type, from the copy of the attempt''s disk' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = '/snap/os'
                    pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = @($doc.captured.vmConfig.dataDisks)[0].managedDiskId; snapshotId = '/snap/d0'; locked = $true }) })
            $plan = Get-VmfDataRestorePlan -Doc $doc -Stamp 's'
            @($plan.Restore).Count | Should -Be 1
            @($plan.Restore)[0].skuName | Should -Be 'StandardSSD_LRS'
            @($plan.Restore)[0].sourceDiskId | Should -Match 'app01-d0-asitwas$'
            # A disk the attempt found on Ultra Disk is left, whatever the first type was.
            @($doc.captured.vmConfig.dataDisks)[0].skuName = 'UltraSSD_LRS'
            $left = Get-VmfDataRestorePlan -Doc $doc -Stamp 's'
            @($left.Restore).Count | Should -Be 0
            @($left.Kept)[0].why | Should -Match 'Ultra Disk'
        }
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

Describe 'ROLLBACK-RETRY-CAPTURE-1: the reports say what the machine was before the first capture changed' {

    It 'the IaC report and the migration record read the FIRST capture''s size as the size before' {
        InModuleScope VmMigrationFactory {
            $doc = RcDoc
            $doc.state = 'MIGRATED'
            $doc.captured | Add-Member -NotePropertyName startedTarget -NotePropertyValue ([pscustomobject]@{ path = 'A'; size = 'Standard_D4s_v6'; controller = 'NVMe' }) -Force
            $rows = @(Get-VmfIacChangeRows -StateDocs @($doc))
            @($rows).Count | Should -Be 1
            $rows[0].size | Should -Be 'Standard_D2s_v4 to Standard_D4s_v6'
            $rec = ConvertTo-VmfMigrationRecord -Manifest ([pscustomobject]@{ runId = 'rc' }) -StateDocs @($doc) -GeneratedBy 'test' -Reason 'downloaded'
            @($rec.machines)[0].before.size | Should -Be 'Standard_D2s_v4'
            @($rec.machines)[0].before.controller | Should -Be 'SCSI'
        }
    }
}
