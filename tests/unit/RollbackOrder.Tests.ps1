#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-ORDER-1, from the GEN1-DISTROS-1 lab run (2026-09-25). A Red Hat 8.10
# machine failed validation on D2ds_v6 and the put-back FAILED too, leaving it in
# FAILED_NEEDS_ATTENTION. The put-back swapped the OS disk BEFORE it set the size
# and controller back, while the machine was still NVMe, and Azure refused
# (redacted): "Swapping OS Disk is not allowed since Disk Controller Type
# property 'NVMe' is not supported by the OS Disk '<the as-it-was copy>'. The
# Disk Controller Types supported by the OS Disk are 'SCSI'."
#
# A disk made from a safety copy carries the disk capabilities of the moment the
# copy was taken - before the conversion added NVMe to them. The born-Gen2 Red
# Hat machine's disk already allowed NVMe (its image said so), so its put-back
# worked; any disk that did not, could not be put back. Not a Gen1 matter.
#
# THE CLASS: a disk made from a safety copy must allow the controller of the
# machine it is swapped into. Three places swap one in:
#   the automatic put-back (pristine copy)       - set SCSI back FIRST, then swap
#   the operator's restore, -From pristine       - the same
#   the operator's restore, -From prepared       - the machine stays NVMe on
#     purpose, so the new disk is given NVMe first, exactly as the conversion
#     gave it to the original disk
#
# The fake below enforces Azure's rule as Azure stated it, so these tests fail
# the way the lab run did.
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

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1'

    # One fake machine, as Azure would hold it after a Path A move.
    function Global:RboReset {
        $global:rbo = @{
            size = 'Standard_D2ds_v6'; controller = 'NVMe'
            # disk name -> the controllers it allows. The original disk was
            # patched by the conversion; every copy was taken before that.
            disks = @{ 'vm1-osdisk' = 'SCSI, NVMe' }
            attached = 'vm1-osdisk'
            calls = [System.Collections.Generic.List[string]]::new()
        }
    }

    function Global:RboMockAzure {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rbo.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rbo.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:rbo.size }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:rbo.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
            [pscustomobject]@{ name = $global:rbo.attached; id = "/disks/$($global:rbo.attached)"; resourceGroup = 'rg-lab'
                location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = $global:rbo.controller }
        }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            # A copy keeps the capabilities it was taken with: SCSI only.
            $global:rbo.disks[$DiskName] = 'SCSI'
            $global:rbo.calls.Add("create:$DiskName")
            "/disks/$DiskName"
        }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes {
            $global:rbo.disks[$DiskName] = $ControllerTypes
            $global:rbo.calls.Add("allow:$DiskName=$ControllerTypes")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            # Azure: the attached disk must allow the controller asked for.
            if ($global:rbo.disks[$global:rbo.attached] -notmatch $Controller) {
                throw "Disk Controller Type property '$Controller' is not supported by the OS Disk '$($global:rbo.attached)'."
            }
            $global:rbo.size = $Size; $global:rbo.controller = $Controller
            $global:rbo.calls.Add("hardware:$Size/$Controller")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk {
            # Azure, word for word in substance: the new disk must allow the
            # controller the machine has now.
            if ($global:rbo.disks[$DiskName] -notmatch $global:rbo.controller) {
                throw "Swapping OS Disk is not allowed since Disk Controller Type property '$($global:rbo.controller)' is not supported by the OS Disk '$DiskName'."
            }
            $global:rbo.attached = $DiskName
            $global:rbo.calls.Add("swap:$DiskName")
        }
    }

    function Global:RboNewRun([string]$Path, [string]$State = '') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rbo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path; st = $State } {
            param($rp, $id, $path, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'rbo' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rbo' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/vm1-osdisk' } }
                }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = '/snapshots/vm1-prepared'; pristineSnapshotId = '/snapshots/vm1-pristine' }) -Force
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            if ($st) { $doc.state = $st }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
}
AfterAll { Remove-Item 'function:\RboReset', 'function:\RboMockAzure', 'function:\RboNewRun' -ErrorAction SilentlyContinue }

Describe 'ROLLBACK-ORDER-1: the automatic put-back, Path A' {
    BeforeEach { Global:RboReset; Global:RboMockAzure; $script:rp = Global:RboNewRun 'A' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'puts back a machine whose original disk only allows SCSI - the Red Hat 8.10 case' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rbo'
            { Invoke-VmfRollback -Context $ctx } | Should -Not -Throw
        }
        $global:rbo.controller | Should -Be 'SCSI'
        $global:rbo.size | Should -Be 'Standard_D2ds_v4'
        $global:rbo.attached | Should -Match 'asitwas'
    }

    It 'sets the hardware back BEFORE it swaps the disk in' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' } }
            Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rbo')
        }
        $calls = @($global:rbo.calls)
        $hw = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'hardware:*' } | Select-Object -First 1))
        $swap = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'swap:*' } | Select-Object -First 1))
        $hw | Should -BeGreaterOrEqual 0
        $swap | Should -BeGreaterThan $hw -Because "the calls were: $($calls -join ', ')"
        $calls | Should -Not -Contain 'allow:' -Because 'the as-it-was copy goes back as it was, not re-marked'
    }
}

Describe 'ROLLBACK-ORDER-1: the operator''s restore' {
    BeforeEach { Global:RboReset; Global:RboMockAzure; $script:rp = Global:RboNewRun 'A' -State 'MIGRATED' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It '-From pristine sets the hardware back first, then swaps' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $global:rbo.controller | Should -Be 'SCSI'
        $global:rbo.attached | Should -Match 'restored'
        $calls = @($global:rbo.calls)
        ([array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'swap:*' } | Select-Object -First 1))) |
            Should -BeGreaterThan ([array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'hardware:*' } | Select-Object -First 1)))
        # The as-it-was copy goes back as it was: once the machine is on SCSI
        # again, nothing re-marks the disk (a mutation that forgot the machine
        # had changed controller did exactly that, and nothing else noticed).
        @($calls | Where-Object { $_ -like 'allow:*' }).Count | Should -Be 0
    }

    It '-From pristine with the original disk name keeps the same order through the temporary disk' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        $global:rbo.controller | Should -Be 'SCSI'
        $global:rbo.attached | Should -Be 'vm1-osdisk'
    }

    It '-From prepared keeps the machine on NVMe, and gives the new disk NVMe before the swap' {
        # The prepared copy was taken after guest prep, so it boots on NVMe -
        # the restore keeps the size by design. The copy was taken BEFORE the
        # conversion added NVMe to the disk, so the new disk needs it added.
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        $global:rbo.controller | Should -Be 'NVMe'
        $global:rbo.size | Should -Be 'Standard_D2ds_v6'
        $global:rbo.attached | Should -Match 'restored'
        $calls = @($global:rbo.calls)
        $allow = $calls | Where-Object { $_ -like 'allow:*=SCSI, NVMe' } | Select-Object -First 1
        $allow | Should -Not -BeNullOrEmpty
        [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'swap:*' } | Select-Object -First 1)) |
            Should -BeGreaterThan ([array]::IndexOf($calls, $allow))
    }

    It '-From prepared with the original disk name gives BOTH disks NVMe before they go in' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        $global:rbo.attached | Should -Be 'vm1-osdisk'
        @($global:rbo.calls | Where-Object { $_ -like 'allow:*=SCSI, NVMe' }).Count | Should -Be 2
    }

    It '-From prepared on a machine that is still SCSI changes no capability' {
        $global:rbo.controller = 'SCSI'; $global:rbo.size = 'Standard_D2ds_v4'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        $global:rbo.attached | Should -Match 'restored'
        @($global:rbo.calls | Where-Object { $_ -like 'allow:*' }).Count | Should -Be 0
    }
}

Describe 'ROLLBACK-ORDER-1: the disk facts carry the controller' {
    It 'Get-VmfOsDiskInfo reports the machine''s controller, read from the machine it already reads' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        $fn = [regex]::Match($src, '(?s)function Get-VmfOsDiskInfo \{.*?\n\}').Value
        $fn | Should -Match 'controller\s*=\s*.*DiskControllerType'
    }
}
