#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RESTORE-EMPTY-LUN-1: a data disk swap that stopped between its two updates.
#
# Azure swaps a data disk in two updates (SWAP-2UPD-1): detach the disk on the
# LUN, then attach the other one. A restore whose job stopped between them left
# that LUN with NO disk; its resume kept the machine stopped and Finish the
# restore refused the LUN, so the only way forward was to attach the disk in
# Azure, outside the app (hard rule 12 does not allow that).
#
# Now the product attaches the disk that the record proves belongs on the
# empty LUN - the disk made from its copy - with the settings the LUN had, and
# reads it back. If Azure refuses it, the disk the LUN had goes back, and the
# machine stays stopped for Finish the restore. The machine never starts with
# a LUN that has no disk, nor with disks from two moments.
#
# This file holds the Azure call (azureops) and the pure rules. The kill-resume
# tests are in RestoreEndJob.Tests.ps1, beside the kill harness; Finish the
# restore on an empty LUN is in SwapRefusedAfterStop.Tests.ps1.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'RESTORE-EMPTY-LUN-1: Add-VmfVmDataDiskOnEmptyLun attaches a disk only to a LUN with no disk' {
    # The mocks act like Azure: the machine is one object, and an update that
    # changes the disk on a LUN that has one is refused.
    BeforeEach {
        $global:elLive = @{ 1 = @{ id = '/disks/d1'; caching = 'None'; deleteOption = 'Detach'; wa = $false } }
        $global:elSent = [System.Collections.Generic.List[object]]::new()
        $global:elRefuse = 0; $global:elIgnore = 0; $global:elBusy = 0
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ StorageProfile = [pscustomobject]@{ DataDisks = [System.Collections.Generic.List[object]]@($global:elLive.Keys | Sort-Object | ForEach-Object {
                $d = $global:elLive[$_]
                [pscustomobject]@{ Lun = [int]$_; Name = ($d.id -split '/')[-1]; CreateOption = 'Attach'; Caching = $d.caching; DeleteOption = $d.deleteOption
                    WriteAcceleratorEnabled = [bool]$d.wa; ManagedDisk = [pscustomobject]@{ Id = $d.id } } }) } }
        }
        Mock -ModuleName VmMigrationFactory Add-AzVMDataDisk -RemoveParameterType 'VM' {
            $VM.StorageProfile.DataDisks.Add([pscustomobject]@{ Lun = $Lun; Name = $Name; CreateOption = $CreateOption; Caching = $Caching
                    DeleteOption = $DeleteOption; WriteAcceleratorEnabled = [bool]$WriteAccelerator; ManagedDisk = [pscustomobject]@{ Id = $ManagedDiskId } })
            $VM }
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' {
            if ($global:elBusy -gt 0) { $global:elBusy--; throw 'TooManyRequests: 429, try again later' }
            $global:elSent.Add(@($VM.StorageProfile.DataDisks | ForEach-Object { [pscustomobject]@{ Lun = [int]$_.Lun; Id = $_.ManagedDisk.Id; Caching = $_.Caching
                            DeleteOption = $_.DeleteOption; WriteAccelerator = [bool]$_.WriteAcceleratorEnabled; CreateOption = $_.CreateOption } }))
            foreach ($dd in @($VM.StorageProfile.DataDisks)) {
                $had = $global:elLive[[int]$dd.Lun]
                if ($had -and $had.id -ne $dd.ManagedDisk.Id) { throw "Changing property 'dataDisk.managedDisk.id' is not allowed." }
            }
            if ($global:elRefuse -gt 0) { $global:elRefuse--; throw 'OperationNotAllowed: the disk cannot be attached' }
            if ($global:elIgnore -gt 0) { $global:elIgnore--; return }
            $now = @{}
            foreach ($dd in @($VM.StorageProfile.DataDisks)) {
                $now[[int]$dd.Lun] = @{ id = $dd.ManagedDisk.Id; caching = $dd.Caching; deleteOption = $dd.DeleteOption; wa = [bool]$dd.WriteAcceleratorEnabled }
            }
            $global:elLive = $now
        }
    }
    AfterEach { Remove-Variable elLive, elSent, elRefuse, elIgnore, elBusy -Scope Global -ErrorAction SilentlyContinue }

    It 'attaches the disk to the empty LUN in one update, with the caching, delete option and write accelerator it is given, and reads it back' {
        $r = InModuleScope VmMigrationFactory {
            Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' `
                -Caching 'ReadOnly' -DeleteOption 'Delete' -WriteAccelerator }
        $r.Applied | Should -BeTrue
        $global:elSent.Count | Should -Be 1
        $slot = $global:elSent[0] | Where-Object Lun -EQ 0
        $slot.Id | Should -Be '/disks/d0-restored'
        $slot.CreateOption | Should -Be 'Attach'
        $slot.Caching | Should -Be 'ReadOnly'
        $slot.DeleteOption | Should -Be 'Delete'
        $slot.WriteAccelerator | Should -BeTrue
        ($global:elSent[0] | Where-Object Lun -EQ 1).Id | Should -Be '/disks/d1' -Because 'the other LUNs keep their disks'
        $global:elLive[0].id | Should -Be '/disks/d0-restored'
    }

    It 'names no delete option and no write accelerator when it is given none - Azure keeps its own default' {
        InModuleScope VmMigrationFactory { Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' -Caching 'None' } | Out-Null
        $slot = $global:elSent[0] | Where-Object Lun -EQ 0
        $slot.DeleteOption | Should -BeNullOrEmpty
        $slot.WriteAccelerator | Should -BeFalse
    }

    It 'a LUN that holds another disk is refused before any update - it never replaces a disk' {
        { InModuleScope VmMigrationFactory { Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 1 -DiskId '/disks/d1-restored' -DiskName 'd1-restored' -Caching 'None' } } |
            Should -Throw -ExpectedMessage "*'/disks/d1' on LUN 1*only to a LUN that has no disk*"
        $global:elSent.Count | Should -Be 0
    }

    It 'a LUN that holds this disk already is done: no update (a job that stopped after Azure attached it)' {
        $global:elLive[0] = @{ id = '/disks/d0-restored'; caching = 'ReadOnly'; deleteOption = 'Detach'; wa = $false }
        $r = InModuleScope VmMigrationFactory { Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' -Caching 'ReadOnly' }
        $r.Applied | Should -BeTrue
        $global:elSent.Count | Should -Be 0
    }

    It 'Azure refuses the attach: not applied, with Azure''s words, and the LUN is still empty' {
        $global:elRefuse = 1
        $r = InModuleScope VmMigrationFactory { Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' -Caching 'ReadOnly' }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Match 'OperationNotAllowed'
        $global:elLive.ContainsKey(0) | Should -BeFalse
    }

    It 'Azure accepts the update and does not attach the disk: not applied - the read back decides, never the answer' {
        $global:elIgnore = 1
        $r = InModuleScope VmMigrationFactory { Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' -Caching 'ReadOnly' }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Match 'did not attach'
    }

    It 'Azure only busy: the update is tried again, and the disk goes on' {
        $global:elBusy = 2
        # The Azure guard makes every wait take no time (_AzureGuard.ps1).
        $r = InModuleScope VmMigrationFactory {
            Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName 'rg' -Name 'vm1' -Lun 0 -DiskId '/disks/d0-restored' -DiskName 'd0-restored' -Caching 'ReadOnly' }
        $r.Applied | Should -BeTrue
    }
}

Describe 'RESTORE-EMPTY-LUN-1: Get-VmfDataDiskInfo records the settings of each LUN' {
    It 'each LUN carries its caching, delete option and write accelerator, so the checkpoint holds them before anything changes' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                StorageProfile = [pscustomobject]@{ DataDisks = @(
                        [pscustomobject]@{ Lun = 0; Name = 'd0'; Caching = 'ReadOnly'; DeleteOption = 'Delete'; WriteAcceleratorEnabled = $true
                            ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/d0' } }) } }
        }
        Mock -ModuleName VmMigrationFactory Get-AzDisk { [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/d0'; Name = 'd0'; Sku = [pscustomobject]@{ Name = 'Premium_LRS' } } }
        $d = @(InModuleScope VmMigrationFactory { Get-VmfDataDiskInfo -ResourceGroupName 'rg' -Name 'vm1' })
        $d.Count | Should -Be 1
        $d[0].caching | Should -Be 'ReadOnly'
        $d[0].deleteOption | Should -Be 'Delete'
        $d[0].writeAcceleratorEnabled | Should -BeTrue
    }
}

Describe 'RESTORE-EMPTY-LUN-1: the settings an empty LUN gets come from the record (pure)' {
    BeforeAll {
        function Global:ElDoc {
            param($Before, $Rebuild, [string]$CapturedCaching = 'ReadOnly')
            $job = [pscustomobject]@{ kind = 'restore'; phase = 'osSwapped'; before = $Before }
            if ($Rebuild) { $job | Add-Member -NotePropertyName rebuild -NotePropertyValue $Rebuild }
            [pscustomobject]@{
                captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ dataDisks = @(
                            [pscustomobject]@{ lun = 0; name = 'd0'; caching = $CapturedCaching; deleteOption = 'Delete' }) } }
                putBackJob = $job
            }
        }
    }
    AfterAll { Remove-Item function:ElDoc -ErrorAction SilentlyContinue }

    It 'the LUN as the checkpoint read it before the job changed it: its caching, delete option and write accelerator' {
        $doc = ElDoc -Before ([pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; id = '/disks/d0'; caching = 'ReadWrite'; deleteOption = 'Delete'; writeAcceleratorEnabled = $true }) })
        $s = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 0 }
        $s.Caching | Should -Be 'ReadWrite' -Because 'the checkpoint read the LUN itself; the capture is older'
        $s.DeleteOption | Should -Be 'Delete'
        $s.WriteAccelerator | Should -BeTrue
    }
    It 'a caching the swap names (None for Premium SSD v2 and Ultra Disk) comes first' {
        $doc = ElDoc -Before ([pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; id = '/disks/d0'; caching = 'ReadOnly'; deleteOption = 'Detach'; writeAcceleratorEnabled = $false }) })
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 0 -Caching 'None' }).Caching | Should -Be 'None'
    }
    It 'a checkpoint with no caching for the LUN (written before this version): the caching the capture recorded' {
        $doc = ElDoc -Before ([pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; id = '/disks/d0' }) }) -CapturedCaching 'ReadOnly'
        $s = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 0 }
        $s.Caching | Should -Be 'ReadOnly'
        $s.DeleteOption | Should -BeNullOrEmpty -Because 'the capture is from before the move: Azure keeps its default'
    }
    It 'OLD-REBUILD-RESTORE-READERS-1: a field rebuild on the job is not read - the LUN as the checkpoint read it' {
        $doc = ElDoc -Before ([pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; id = '/disks/d0'; caching = 'ReadWrite'; deleteOption = 'Delete'; writeAcceleratorEnabled = $true }) }) `
            -Rebuild ([pscustomobject]@{ asBefore = [pscustomobject]@{ name = 'vm1' } }) -CapturedCaching 'ReadOnly'
        $s = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 0 }
        $s.Caching | Should -Be 'ReadWrite'
        $s.DeleteOption | Should -Be 'Delete'
        $s.WriteAccelerator | Should -BeTrue
    }
    It 'no caching anywhere on the record: no settings - the product does not guess one' {
        $doc = ElDoc -Before $null -CapturedCaching ''
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 0 }) | Should -BeNullOrEmpty
    }
}

Describe 'RESTORE-EMPTY-LUN-1: Invoke-VmfEmptyLunAttach attaches only the disk the record proves, and puts the old disk back when Azure refuses it' {
    BeforeEach {
        # The disks Azure holds: each one's machine and the copy it was made from.
        $global:ea = @{
            disks = @{
                '/d/want' = @{ ManagedBy = ''; Source = '/s/copy-d0' }
                '/d/old'  = @{ ManagedBy = ''; Source = '' }
            }
            calls = [System.Collections.Generic.List[string]]::new(); refuse = @(); throwOn = @()
            # A run path outside the repository (LITTER-1): a failed call writes its line there.
            rp = (Join-Path ([System.IO.Path]::GetTempPath()) "vmf-el-$([guid]::NewGuid().ToString('N').Substring(0,8))")
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $d = $global:ea.disks[$DiskId]
            if (-not $d) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $d.ManagedBy; SourceResourceId = $d.Source }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:ea.calls.Add("${DiskId}:${Caching}:${DeleteOption}:$([bool]$WriteAccelerator)")
            if ($global:ea.throwOn -contains $DiskId) { throw 'Get-AzVM failed: the machine could not be read' }
            if ($global:ea.refuse -contains $DiskId) { return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk cannot be attached' } }
            @{ Applied = $true }
        }
        function Global:EaRun([hashtable]$Settings = @{ Caching = 'ReadOnly'; DeleteOption = 'Delete'; WriteAccelerator = $true }) {
            InModuleScope VmMigrationFactory -Parameters @{ s = $(if ($null -ne $Settings) { [pscustomobject]$Settings } else { $null }); rp = $global:ea.rp } {
                param($s, $rp)
                Invoke-VmfEmptyLunAttach -Context ([pscustomobject]@{ RunPath = $rp; VmId = '/vm1'; Rg = 'rg' }) -VmName 'vm1' -OpName 'restore:swapDataDisks' -ReadOpName 'restore:readDataDisk' `
                    -Lun 0 -Want @{ id = '/d/want'; name = 'd0-restored'; snapshotId = '/s/copy-d0' } -Fallback @{ id = '/d/old'; name = 'd0' } -Settings $s
            }
        }
    }
    AfterEach { if ($global:ea -and (Test-Path $global:ea.rp)) { Remove-Item $global:ea.rp -Recurse -Force }; Remove-Variable ea -Scope Global -ErrorAction SilentlyContinue; Remove-Item function:EaRun -ErrorAction SilentlyContinue }

    It 'proven: the disk goes on, once, with the settings it is given' {
        $r = EaRun
        $r.Outcome | Should -Be 'want'
        @($global:ea.calls) | Should -Be @('/d/want:ReadOnly:Delete:True')
    }
    It 'refused: tried three times in all, then the disk the LUN had goes back on it with the same settings' {
        $global:ea.refuse = @('/d/want')
        $r = EaRun
        $r.Outcome | Should -Be 'fallback'
        $r.Reason | Should -Match 'OperationNotAllowed'
        @($global:ea.calls | Where-Object { $_ -like '/d/want:*' }).Count | Should -Be 3
        @($global:ea.calls)[-1] | Should -Be '/d/old:ReadOnly:Delete:True'
    }
    It 'refused, and the disk it had refused too: the LUN stays empty, with both reasons' {
        $global:ea.refuse = @('/d/want', '/d/old')
        $r = EaRun
        $r.Outcome | Should -Be 'empty'
        $r.Reason | Should -Match "was not attached to it again either"
    }
    It 'refused, and the disk it had is attached to another machine: it is not attached, and the LUN stays empty' {
        $global:ea.refuse = @('/d/want')
        $global:ea.disks['/d/old'].ManagedBy = '/vm/other'
        $r = EaRun
        $r.Outcome | Should -Be 'empty'
        $r.Reason | Should -Match "attached to '/vm/other'"
        @($global:ea.calls | Where-Object { $_ -like '/d/old:*' }) | Should -BeNullOrEmpty
    }
    It 'an attach that fails with no answer (not a refusal): where the LUN stands is not known, so the disk it had is not attached either' {
        $global:ea.throwOn = @('/d/want')
        $r = EaRun
        $r.Outcome | Should -Be 'empty'
        @($global:ea.calls | Where-Object { $_ -like '/d/old:*' }) | Should -BeNullOrEmpty
        # FINISH-ATTACH-UNKNOWN-WORDS-1: the answer says it was not a refusal,
        # and its sentence never says Azure refused the disk or tried 3 times.
        $r.Unknown | Should -BeTrue
        $r.Reason | Should -Match 'the machine could not be read'
        $r.Why | Should -Match "^The attach of the disk 'd0-restored' made from its copy to LUN 0 stopped with an error that is not a refusal from Azure: Get-AzVM failed: the machine could not be read\. The product does not know which disk is on LUN 0 now\. So it did not attach the disk 'd0' that LUN 0 had\.$"
        $r.Why | Should -Not -Match 'after 3 tries|LUN 0 has no disk|did not attach the disk ''d0-restored'''
    }
    It 'FINISH-ATTACH-UNKNOWN-WORDS-1: an attach with no answer, and no disk on record for the LUN before: the sentence names no disk it had' {
        $global:ea.throwOn = @('/d/want')
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:ea.rp } {
            param($rp)
            Invoke-VmfEmptyLunAttach -Context ([pscustomobject]@{ RunPath = $rp; VmId = '/vm1'; Rg = 'rg' }) -VmName 'vm1' -OpName 'restore:swapDataDisks' -ReadOpName 'restore:readDataDisk' `
                -Lun 0 -Want @{ id = '/d/want'; name = 'd0-restored'; snapshotId = '/s/copy-d0' } -Fallback $null -Settings ([pscustomobject]@{ Caching = 'None' })
        }
        $r.Unknown | Should -BeTrue
        $r.Why | Should -Match 'The product does not know which disk is on LUN 0 now\.$'
    }
    It 'FINISH-ATTACH-UNKNOWN-WORDS-1: a refusal is never marked as no answer - <Case>' -ForEach @(
        @{ Case = 'the disk it had went back'; Refuse = @('/d/want'); Outcome = 'fallback' }
        @{ Case = 'both refused'; Refuse = @('/d/want', '/d/old'); Outcome = 'empty' }) {
        $global:ea.refuse = $Refuse
        $r = EaRun
        $r.Outcome | Should -Be $Outcome
        [bool]$r.Unknown | Should -BeFalse
    }
    It 'FINISH-ATTACH-UNKNOWN-WORDS-1: Resolve-VmfEmptyDataLun keeps the sentence of an attach with no answer, and says a refusal as Azure did not attach' {
        $rp = $global:ea.rp
        $words = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            param($rp)
            Mock Read-VmfStateDoc { $null }
            Mock Get-VmfEmptyLunSettings { [pscustomobject]@{ Caching = 'None' } }
            $ctx = [pscustomobject]@{ RunPath = $rp; VmId = '/vm1'; Rg = 'rg' }
            $out = @{}
            $global:ea.throwOn = @('/d/want')
            $out.unknown = Resolve-VmfEmptyDataLun -Context $ctx -VmName 'vm1' -OpName 'restore:swapDataDisks' -Lun 0 -WantId '/d/want' -WantName 'd0-restored' -SnapshotId '/s/copy-d0' -HadId '/d/old' -HadName 'd0'
            $global:ea.throwOn = @(); $global:ea.refuse = @('/d/want', '/d/old')
            $out.refused = Resolve-VmfEmptyDataLun -Context $ctx -VmName 'vm1' -OpName 'restore:swapDataDisks' -Lun 0 -WantId '/d/want' -WantName 'd0-restored' -SnapshotId '/s/copy-d0' -HadId '/d/old' -HadName 'd0'
            $out
        }
        $words.unknown.Why | Should -Match '^The attach of the disk ''d0-restored'' made from its copy to LUN 0 stopped with an error that is not a refusal from Azure'
        $words.unknown.Why | Should -Not -Match 'Azure did not attach'
        $words.refused.Why | Should -Match "^LUN 0 has no disk\. Azure did not attach the disk 'd0-restored' made from its copy"
    }
    It 'not proven - <Case>: nothing is attached, and the words name the LUN, the disk and the disk the LUN had' -ForEach @(
        @{ Case = 'the disk does not exist'; Change = { $global:ea.disks.Remove('/d/want') }; Words = 'does not exist'; Foreign = $false }
        @{ Case = 'it is attached to another machine'; Change = { $global:ea.disks['/d/want'].ManagedBy = '/vm/other' }; Words = "attached to '/vm/other'"; Foreign = $false }
        @{ Case = 'it was made from another copy'; Change = { $global:ea.disks['/d/want'].Source = '/s/another' }; Words = "made from '/s/another', not from the copy '/s/copy-d0'"; Foreign = $true }) {
        & $Change
        $r = EaRun
        $r.Outcome | Should -Be 'unproven'
        $r.Why | Should -Match 'LUN 0 has no disk'
        $r.Why | Should -Match "'d0-restored'"
        $r.Why | Should -Match ([regex]::Escape($Words))
        $r.Why | Should -Match "LUN 0 had the disk 'd0'"
        [bool]$r.Foreign | Should -Be $Foreign
        $global:ea.calls.Count | Should -Be 0
    }
    # LEASE-LOST-EMPTY-LUN-1: a wave worker that lost its lease must stop at
    # once. Every Azure call renews the lease first (Invoke-VmfAzOperation),
    # and a lost one throws "... abandon this VM". None of the three catches
    # here may read that as an answer about the disk: the worker would go on
    # and write the machine's record while another worker may hold it.
    It 'LEASE-LOST-EMPTY-LUN-1, <Fn>: the lease is lost at <Where> - it throws the lost lease, and attaches nothing after it' -ForEach @(
        foreach ($fn in 'Invoke-VmfEmptyLunAttach', 'Resolve-VmfEmptyDataLun') {
            @{ Fn = $fn; Where = 'the read of the disk made from its copy'; LoseAt = 1; Refuse = @(); Calls = '' }
            @{ Fn = $fn; Where = 'the attach of the disk made from its copy'; LoseAt = 2; Refuse = @(); Calls = '' }
            @{ Fn = $fn; Where = 'a second try of a refused attach'; LoseAt = 3; Refuse = @('/d/want'); Calls = '/d/want' }
            @{ Fn = $fn; Where = 'the read of the disk the LUN had'; LoseAt = 5; Refuse = @('/d/want'); Calls = '/d/want,/d/want,/d/want' }
            @{ Fn = $fn; Where = 'the attach of the disk the LUN had'; LoseAt = 6; Refuse = @('/d/want'); Calls = '/d/want,/d/want,/d/want' }
        }) {
        $global:ea.refuse = $Refuse
        $global:ea.beats = 0
        $global:ea.loseAt = $LoseAt
        $out = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:ea.rp; fn = $Fn } {
            param($rp, $fn)
            Mock Read-VmfStateDoc { $null }
            Mock Get-VmfEmptyLunSettings { [pscustomobject]@{ Caching = 'ReadOnly' } }
            # The heartbeat as a wave worker sets it: it runs before every Azure
            # call, and throws once another worker holds the lease.
            $script:VmfOpHeartbeat = {
                $global:ea.beats++
                if ($global:ea.beats -ge $global:ea.loseAt) { throw "Lease for '/vm1' is held by 'worker-2', not 'worker-1' - abandon this VM." }
            }
            $ctx = [pscustomobject]@{ RunPath = $rp; VmId = '/vm1'; Rg = 'rg' }
            try {
                if ($fn -eq 'Invoke-VmfEmptyLunAttach') {
                    $r = Invoke-VmfEmptyLunAttach -Context $ctx -VmName 'vm1' -OpName 'rollback:swapDataDisks' -ReadOpName 'rollback:readDataDisk' -Lun 0 `
                        -Want @{ id = '/d/want'; name = 'd0-restored'; snapshotId = '/s/copy-d0' } -Fallback @{ id = '/d/old'; name = 'd0' } -Settings ([pscustomobject]@{ Caching = 'ReadOnly' })
                }
                else {
                    $r = Resolve-VmfEmptyDataLun -Kind rollback -Context $ctx -VmName 'vm1' -OpName 'rollback:swapDataDisks' -Lun 0 -WantId '/d/want' -WantName 'd0-restored' `
                        -SnapshotId '/s/copy-d0' -HadId '/d/old' -HadName 'd0'
                }
                @{ Threw = ''; Result = $r }
            }
            catch { @{ Threw = [string]$_.Exception.Message } }
            finally { $script:VmfOpHeartbeat = $null }
        }
        $out.Threw | Should -Match 'abandon this VM' -Because "a lost lease is not an answer about the disk (it returned: $($out.Result | ConvertTo-Json -Compress))"
        $global:ea.beats | Should -Be $LoseAt -Because 'no Azure call follows the lost lease'
        (@($global:ea.calls | ForEach-Object { ($_ -split ':')[0] }) -join ',') | Should -Be $Calls -Because 'nothing is attached after the lease is lost'
    }
    It 'no settings on record: nothing is attached' {
        $r = EaRun -Settings $null
        $r.Outcome | Should -Be 'unproven'
        $r.Why | Should -Match 'no caching'
        $global:ea.calls.Count | Should -Be 0
    }
}

Describe 'RESTORE-EMPTY-LUN-1: the row the record keeps for a LUN that is still left (pure)' {
    BeforeAll {
        function Global:ElRow { [pscustomobject]@{ lun = 0; name = 'd0'; oldDiskId = '/d/old'; diskId = '/d/want'; diskName = 'd0-restored'; caching = $null; instantAccess = $false; temporary = $false; why = 'w' } }
    }
    AfterAll { Remove-Item function:ElRow -ErrorAction SilentlyContinue }
    It 'a LUN with no disk keeps the caching it is to have, for Finish the restore' {
        $row = InModuleScope VmMigrationFactory -Parameters @{ r = (ElRow) } { param($r) Set-VmfEmptyLunRow -Row $r -Fill @{ Outcome = 'empty'; Caching = 'ReadWrite' } }
        $row.caching | Should -Be 'ReadWrite'
        $row.diskId | Should -Be '/d/want'
    }
    It 'a disk made from another copy is not named as the disk that waits' {
        $row = InModuleScope VmMigrationFactory -Parameters @{ r = (ElRow) } { param($r) Set-VmfEmptyLunRow -Row $r -Fill @{ Outcome = 'unproven'; Caching = 'ReadOnly'; Foreign = $true } }
        [string]$row.diskId | Should -BeNullOrEmpty
    }
    It 'after the disk it had went back, the row is a plain swap: nothing changes' {
        $row = InModuleScope VmMigrationFactory -Parameters @{ r = (ElRow) } { param($r) Set-VmfEmptyLunRow -Row $r -Fill @{ Outcome = 'fallback'; Caching = 'ReadWrite'; Foreign = $true } }
        $row.caching | Should -BeNullOrEmpty
        $row.diskId | Should -Be '/d/want'
    }
}

Describe 'RESTORE-EMPTY-LUN-1: the words for a LUN with no disk' {
    It 'a LUN with no disk is said as no disk, never as a disk it keeps' {
        $w = InModuleScope VmMigrationFactory {
            Format-VmfSwapLeft -Swaps @(
                [pscustomobject]@{ lun = 0; name = 'd0'; diskName = 'd0-restored' },
                [pscustomobject]@{ lun = 1; name = 'd1'; diskName = 'd1-restored' }) -EmptyLuns @(1)
        }
        $w | Should -Match "LUN 0 keeps 'd0', not the disk 'd0-restored' made from its copy"
        $w | Should -Match "LUN 1 has no disk, and the disk 'd1-restored' made from its copy waits to go on it"
        $w | Should -Not -Match "LUN 1 keeps"
    }
    It 'the sentence a restore ends on: a disk Azure did not swap with Azure''s words, each LUN with no disk with its own why, and Finish the restore - never a step in Azure' {
        $w = InModuleScope VmMigrationFactory {
            Format-VmfRestoreSwapLeftWords -Swaps @(
                [pscustomobject]@{ lun = 0; name = 'd0'; diskName = 'd0-restored'; why = 'OperationNotAllowed: in use' },
                [pscustomobject]@{ lun = 1; name = 'd1'; diskName = 'd1-restored'; why = "LUN 1 has no disk. The disk 'd1-restored' made from its copy does not exist." }) -EmptyLuns @(1) -Refused @(0)
        }
        $w | Should -Match "LUN 0 keeps 'd0'.*Azure said: OperationNotAllowed: in use\."
        $w | Should -Match "LUN 1 has no disk\. The disk 'd1-restored' made from its copy does not exist\."
        $w | Should -Match 'Use Finish the restore on this machine\. It puts on only the disks that are left'
        $w | Should -Not -Match 'LUN 1 keeps'
        $plain = InModuleScope VmMigrationFactory { Format-VmfRestoreSwapLeftWords -Swaps @([pscustomobject]@{ lun = 0; name = 'd0'; diskName = 'd0-restored'; why = 'refused' }) }
        $plain | Should -Match 'It swaps only the disks that are left, then starts the machine\.$'
    }
}
