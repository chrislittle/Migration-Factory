#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-NULL-1, found while planning GEN-V5-1 (2026-09-26).
#
# Azure reports a machine's diskControllerType for Generation 2 machines only, so
# the capture of any Generation 1 machine records NOTHING there. Three recovery
# paths then broke on that nothing:
#   - the put-back (Path A) and the operator's pristine restore passed it to
#     Set-VmfVmSizeAndController, whose -Controller was Mandatory with a
#     ValidateSet: "Cannot validate argument on parameter 'Controller'" - the
#     safety net failed at its first step (measured by running it);
#   - the Path B put-back passed it to New-VmfVmFromCapture, the same way;
#   - the operator's rebuild (Restore-VmfVmShell) filled the gap with 'SCSI',
#     which Azure refuses outright for a Generation 1 machine - the put-back
#     failure the Gen1 lab drill hit on 2026-09-24.
#
# THE RULE: no recorded controller means the original machine was not NVMe
# (Azure reports NVMe whenever a machine uses it). Going back, a machine that is
# on NVMe now is set to SCSI; anything else is left exactly as Azure has it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1'
}

Describe 'ROLLBACK-NULL-1: resizing with no recorded controller' {
    BeforeEach {
        $global:rbnSent = $null
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' { $global:rbnSent = $VM; [pscustomobject]@{ StatusCode = 'OK' } }
    }
    AfterAll { Remove-Variable rbnSent, rbnLive -Scope Global -ErrorAction SilentlyContinue }

    It 'a machine on NVMe now goes back to SCSI - NVMe cannot have been its original' {
        $global:rbnLive = 'NVMe'
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v6' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = $global:rbnLive; DataDisks = @() } } }
        InModuleScope VmMigrationFactory { Set-VmfVmSizeAndController -ResourceGroupName 'rg-lab' -Name 'vm1' -Size 'Standard_D2s_v4' -Controller $null }
        $global:rbnSent.HardwareProfile.VmSize | Should -Be 'Standard_D2s_v4'
        $global:rbnSent.StorageProfile.DiskControllerType | Should -Be 'SCSI'
    }

    It 'a machine with no controller now keeps none - Azure refuses the setting on Generation 1' {
        $global:rbnLive = $null
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v5' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = $global:rbnLive; DataDisks = @() } } }
        InModuleScope VmMigrationFactory { Set-VmfVmSizeAndController -ResourceGroupName 'rg-lab' -Name 'vm1' -Size 'Standard_D2_v2' -Controller '' }
        $global:rbnSent.HardwareProfile.VmSize | Should -Be 'Standard_D2_v2'
        $global:rbnSent.StorageProfile.DiskControllerType | Should -BeNullOrEmpty
    }

    It 'a machine on SCSI keeps its setting exactly - left alone, not cleared' {
        # A mutation that cleared the setting instead of leaving it passed every
        # other case here; this is the machine where the two differ.
        $global:rbnLive = 'SCSI'
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = $global:rbnLive; DataDisks = @() } } }
        InModuleScope VmMigrationFactory { Set-VmfVmSizeAndController -ResourceGroupName 'rg-lab' -Name 'vm1' -Size 'Standard_D4s_v4' -Controller '' }
        $global:rbnSent.StorageProfile.DiskControllerType | Should -Be 'SCSI'
    }

    It 'a named controller is still set as named' {
        $global:rbnLive = 'SCSI'
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = $global:rbnLive; DataDisks = @() } } }
        InModuleScope VmMigrationFactory { Set-VmfVmSizeAndController -ResourceGroupName 'rg-lab' -Name 'vm1' -Size 'Standard_D2s_v6' -Controller 'NVMe' }
        $global:rbnSent.StorageProfile.DiskControllerType | Should -Be 'NVMe'
    }

    It 'a controller that is neither is refused' {
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'x' }; StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'; DataDisks = @() } } }
        { InModuleScope VmMigrationFactory { Set-VmfVmSizeAndController -ResourceGroupName 'rg-lab' -Name 'vm1' -Size 'y' -Controller 'IDE' } } | Should -Throw
    }
}

Describe 'ROLLBACK-NULL-1: the put-back runs for a machine with no recorded controller' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-nullc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'nullc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'nullc' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = $null; location = 'centralus'; osType = 'Linux'
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/vm1-osdisk' }
                        dataDisks = @(); nics = @(); zones = @(); tags = @{} }
                }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = '/snapshots/p' }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { '/disks/new' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v6' }; StorageProfile = [pscustomobject]@{ DiskControllerType = 'NVMe'; DataDisks = @() } } }
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' { [pscustomobject]@{ StatusCode = 'OK' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rbnTarget -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A completes - it failed at its first step before' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }
            { Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'nullc') } | Should -Not -Throw
        }
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
# REBUILD-REMOVE-ROLE-1: New-VmfVmFromCapture is gone, and its test with it.
