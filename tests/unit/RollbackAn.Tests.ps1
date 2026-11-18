#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ROLLBACK-AN-1: a rollback puts accelerated networking back as it was.
#
# Every move to v6 or v7 - and a v5 move to an Intel D size - turns accelerated
# networking ON for the primary network interface, before the new size. The
# rollback put back the size, the controller and every disk, and left the
# interface as the move made it: "the machine runs again as it was, with one
# exception". A move is one change window, and "as it was" means as it was.
#
# The capture records each interface's setting before the move. The rollback,
# on both paths, and an operator's restore from the first copy (which also puts
# back the original size and controller), set each interface back to that. An
# interface the capture could not read is left alone: unknown is not a value.
# Azure refusing it is said, and never stops the rollback.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
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

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:nic0 = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic0"
    $script:nic1 = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic1"
    $script:nic2 = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic2"

    # A machine captured with AN off on its primary (the move turns it on), on
    # a second interface, and unknown on a third.
    function Global:RanNewRun([string]$Path = 'A', [string]$State = '') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ran-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; n0 = $script:nic0; n1 = $script:nic1; n2 = $script:nic2; st = $State } {
            param($rp, $id, $sub, $n0, $n1, $n2, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'ran' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'ran' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; capacityReservationGroupId = $null
                        zones = @()
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/Microsoft.Compute/disks/vm1-osdisk" }
                        dataDisks = @()
                        nics = @(
                            [pscustomobject]@{ id = $n0; primary = $true; acceleratedNetworking = $false }
                            [pscustomobject]@{ id = $n1; primary = $false; acceleratedNetworking = $true }
                            [pscustomobject]@{ id = $n2; primary = $false; acceleratedNetworking = $null })
                        tags = @{} } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true }) -Force
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            if ($st) { $doc.state = $st }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:RanCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'ran'
        }
    }
    function Global:RanLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
}
AfterAll { Remove-Item function:RanNewRun, function:RanCtx, function:RanLog -ErrorAction SilentlyContinue; Remove-Variable ranCat -Scope Global -ErrorAction SilentlyContinue }

Describe 'ROLLBACK-AN-1: the setter says whether it changed anything' {
    It 'returns true when it changed the interface, false when it was already so' {
        $script:nicObj = [pscustomobject]@{ EnableAcceleratedNetworking = $true }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { $script:nicObj }
        Mock -ModuleName VmMigrationFactory Set-AzNetworkInterface { }
        InModuleScope VmMigrationFactory -Parameters @{ n = $script:nic0 } { param($n) Set-VmfNicAcceleratedNetworking -NicId $n -Enabled $false } | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ n = $script:nic0 } { param($n) Set-VmfNicAcceleratedNetworking -NicId $n -Enabled $false } | Should -BeFalse
        Should -Invoke -ModuleName VmMigrationFactory Set-AzNetworkInterface -Times 1 -Exactly
    }
}

Describe 'ROLLBACK-AN-1: a rollback puts accelerated networking back' {
    BeforeEach {
        # ROLLBACK-RETRY-CAPTURE-3: the size catalog the off pass reads for the size the machine goes back to.
        $global:ranCat = @{ vcpus = '2'; active = $null; fail = $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($global:ranCat.fail) { throw 'The size catalog did not answer.' }
            $caps = @([pscustomobject]@{ Name = 'vCPUs'; Value = $global:ranCat.vcpus })
            if ($global:ranCat.active) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $global:ranCat.active } }
            @([pscustomobject]@{ Name = 'Standard_D2ds_v4'; Capabilities = $caps })
        }
        $global:ran = @{ calls = [System.Collections.Generic.List[string]]::new(); nics = @{} }
        # The live interfaces, as the move left them: primary turned ON.
        $global:ran.nics[$script:nic0] = $true; $global:ran.nics[$script:nic1] = $true; $global:ran.nics[$script:nic2] = $true
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:ran.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ran.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:ran.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking {
            $global:ran.calls.Add("an:$(($NicId -split '/')[-1])=$Enabled")
            $was = $global:ran.nics[$NicId]; $global:ran.nics[$NicId] = $Enabled; ($was -ne $Enabled)
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable ran -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: each interface goes back to its captured setting, after the size and before the start' {
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:ran.nics[$script:nic0] | Should -BeFalse -Because 'the move turned it on; it was off'
        $global:ran.nics[$script:nic1] | Should -BeTrue
        $calls = @($global:ran.calls)
        $calls | Should -Not -Contain 'an:vm1-nic2=True' -Because 'an interface the capture could not read is left alone'
        $calls | Should -Not -Contain 'an:vm1-nic2=False'
        # ROLLBACK-RETRY-CAPTURE-3: an interface the capture recorded OFF now
        # goes off first, right after the stop (this capture has another
        # interface on). The full set-back still runs on the original size,
        # so the LAST call for it is after the size.
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size')) -Because 'on the original size, which is what allows each setting'
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeLessThan ([array]::IndexOf($calls, 'start'))
        [array]::IndexOf($calls, 'an:vm1-nic1=True') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size')) -Because 'turning one ON waits for the original size'
        RanLog $script:rp | Should -Match 'Accelerated networking is set back to off first, as the capture recorded it: vm1-nic0'
        # IAC-REPORT-1: the disk it made is on the record, after the retry state is cleared.
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $doc.rollback.osDisk.name | Should -Match '^vm1-osdisk-asitwas-'
        $doc.rollback.path | Should -Be 'A'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step.
    It 'an interface Azure refuses is said, and the rollback still finishes and starts the machine' {
        $script:rp = RanNewRun
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'NetworkInterfaceInUse' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:ran.calls | Should -Contain 'start'
        $log = RanLog $script:rp
        $log | Should -Match 'Accelerated networking could not be set back on vm1-nic0.*NetworkInterfaceInUse'
        $log | Should -Match 'except accelerated networking on 2 network interface' -Because 'the final record does not claim "as it was" for them'
    }

    It 'RESTORE-WARN-ENDS-1: an interface Azure refuses is info in a restore, warn in a rollback' {
        # The run page reads a 'restore' warn as the end of the restore, so a
        # line in the middle of one must not be a warn.
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'NetworkInterfaceInUse' }
        foreach ($case in @(@{ kind = 'restore'; outcome = 'info' }, @{ kind = 'rollback'; outcome = 'warn' })) {
            $script:rp = RanNewRun
            $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; k = $case.kind } {
                param($rp, $id, $k)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $rp -VmId $id -Nics $doc.captured.vmConfig.nics -Kind $k
                @(Read-VmfEvents -RunPath $rp)
            }
            $lines = @($events | Where-Object { [string]$_.detail -match 'Accelerated networking could not be set back on' })
            $lines.Count | Should -Be 2 -Because 'both interfaces with a recorded value are refused'
            foreach ($line in $lines) {
                $line.step | Should -Be $case.kind
                $line.outcome | Should -Be $case.outcome
            }
            Remove-Item $script:rp -Recurse -Force
        }
    }

    It 'a lost lease is not a network interface warning: it stops the rollback, as everywhere else' {
        $script:rp = RanNewRun
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'lease lost - abandon this VM' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        $global:ran.calls | Should -Not -Contain 'start'
    }

    It 'nothing to change: no event claims a change' {
        $script:rp = RanNewRun
        $global:ran.nics[$script:nic0] = $false
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        RanLog $script:rp | Should -Not -Match 'Accelerated networking is set back'
    }

    It 'a refusal in BOTH passes is counted once in the final line' {
        $script:rp = RanNewRun
        $global:ran.nics[$script:nic1] = $false
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { if (($NicId -split '/')[-1] -eq 'vm1-nic0') { throw 'NetworkInterfaceInUse' }; $global:ran.nics[$NicId] = $Enabled; $true }
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $log = RanLog $script:rp
        $log | Should -Match 'except accelerated networking on 1 network interface' -Because 'the first pass is tried again, so only the second pass counts'
        ([regex]::Matches($log, 'starts with it as the move left it')).Count | Should -Be 1 -Because 'only the second refusal is final'
    }
}

Describe 'ROLLBACK-AN-1: a restore from the first copy puts it back too; the second copy does not' {
    BeforeEach {
        # ROLLBACK-RETRY-CAPTURE-3: the size catalog the off pass reads for the size the machine goes back to.
        $global:ranCat = @{ vcpus = '2'; active = $null; fail = $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($global:ranCat.fail) { throw 'The size catalog did not answer.' }
            $caps = @([pscustomobject]@{ Name = 'vCPUs'; Value = $global:ranCat.vcpus })
            if ($global:ranCat.active) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $global:ranCat.active } }
            @([pscustomobject]@{ Name = 'Standard_D2ds_v4'; Capabilities = $caps })
        }
        $global:ranR = @{ calls = [System.Collections.Generic.List[string]]::new() }
        # The run a restore reads: the machine migrated, its capture, both copies, the plan.
        $script:rp = RanNewRun -State 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                        schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'
                        assessment = [ordered]@{ location = 'centralus' }
                        target = [ordered]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = '/disks/vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:ranR.calls.Add('osdisk') }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:ranR.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ranR.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2ds_v4' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:ranR.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:ranR.calls.Add("an:$(($NicId -split '/')[-1])=$Enabled"); $true }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable ranR -Scope Global -ErrorAction SilentlyContinue }

    It 'the first copy: size, then accelerated networking, then the start' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:ranR.calls)
        $calls | Should -Contain 'an:vm1-nic0=False'
        # ROLLBACK-RETRY-CAPTURE-3: it also goes off right after the stop; the
        # set-back on the original size is the last call for it.
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeLessThan ([array]::IndexOf($calls, 'start'))
        [array]::IndexOf($calls, 'an:vm1-nic1=True') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
    }

    It 'the first copy leaves alone an interface the capture could not read' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:ranR.calls | Where-Object { $_ -like 'an:vm1-nic2=*' }).Count | Should -Be 0
    }

    It 'the second copy keeps the current hardware, accelerated networking included' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:ranR.calls | Where-Object { $_ -like 'an:*' }).Count | Should -Be 0
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-3: an interface the capture recorded off goes off before any machine update' {
    # MEASURED 2026-10-10 (Standard_D2s_v4, primary off, a second interface
    # on): Azure ACCEPTS a network interface update that turns accelerated
    # networking on for the primary while the machine is deallocated (Q1), and
    # then REFUSES every update of the machine - a resize to the size (Q2a),
    # even a tag (Q2b) - with VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable.
    # A start is accepted (Q2c). So the move's own setting on the primary
    # blocked the rollback's first machine update. The mock below is that
    # rule: any machine update, and a create, refused while more than one
    # interface has it.
    BeforeEach {
        # ROLLBACK-RETRY-CAPTURE-3: the size catalog the off pass reads for the size the machine goes back to.
        $global:ranCat = @{ vcpus = '2'; active = $null; fail = $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($global:ranCat.fail) { throw 'The size catalog did not answer.' }
            $caps = @([pscustomobject]@{ Name = 'vCPUs'; Value = $global:ranCat.vcpus })
            if ($global:ranCat.active) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $global:ranCat.active } }
            @([pscustomobject]@{ Name = 'Standard_D2ds_v4'; Capabilities = $caps })
        }
        $global:rr = @{ calls = [System.Collections.Generic.List[string]]::new(); nics = @{}; rule = $true; sizeFails = 0 }
        # As the move left them: the primary turned ON, the second interface
        # as it was, the third (unknown to the capture) off.
        $global:rr.nics[$script:nic0] = $true; $global:rr.nics[$script:nic1] = $true; $global:rr.nics[$script:nic2] = $false
        $global:rr.vmUpdate = {
            param([string]$What)
            if ($global:rr.rule -and @($global:rr.nics.Values | Where-Object { $_ -eq $true }).Count -gt 1) {
                $global:rr.calls.Add("refused:$What")
                throw 'VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable: Virtual machine <id> with size Standard_D2s_v4 is restricted to have only one network interface with accelerated networking enabled.'
            }
            $global:rr.calls.Add($What)
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rr.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rr.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { "$($script:sub)/Microsoft.Compute/capacityReservationGroups/crg1" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { & $global:rr.vmUpdate 'leaveReservation' }
        Mock -ModuleName VmMigrationFactory Remove-VmfClaimAssociation { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            if ($global:rr.sizeFails -gt 0) { $global:rr.sizeFails--; $global:rr.calls.Add('killed'); throw 'the worker stopped here' }
            & $global:rr.vmUpdate 'size'
        }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { & $global:rr.vmUpdate 'osdisk' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        # Deleted: the interfaces are detached, so the rule no longer applies
        # until the create, which NIC-1 measured it on.
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking {
            $global:rr.calls.Add("an:$(($NicId -split '/')[-1])=$Enabled")
            $was = $global:rr.nics[$NicId]; $global:rr.nics[$NicId] = $Enabled; ($was -ne $Enabled)
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rr -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: with the rule Azure applies, the rollback finishes - the primary goes off before the reservation is left' {
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        @($calls | Where-Object { $_ -like 'refused:*' }) | Should -BeNullOrEmpty -Because 'no machine update meets two interfaces with accelerated networking'
        $calls[0] | Should -Be 'stop'
        $calls[1] | Should -Be 'an:vm1-nic0=False' -Because 'the off pass comes right after the stop, before any machine update'
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeLessThan ([array]::IndexOf($calls, 'leaveReservation'))
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeLessThan ([array]::IndexOf($calls, 'size'))
        $calls[-1] | Should -Be 'start'
        $global:rr.nics[$script:nic0] | Should -BeFalse
        $global:rr.nics[$script:nic1] | Should -BeTrue
    }

    It 'Path A: no interface is turned ON before the size, and the full set-back still runs after it' {
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        $sizeAt = [array]::IndexOf($calls, 'size')
        $sizeAt | Should -BeGreaterThan 0
        @($calls[0..$sizeAt] | Where-Object { $_ -like 'an:*=True' }) | Should -BeNullOrEmpty -Because 'turning it on is what the size caps'
        @($calls | Where-Object { $_ -eq 'an:vm1-nic0=False' }).Count | Should -Be 2 -Because 'the second pass runs as before, and changes nothing the first did'
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan $sizeAt
        [array]::IndexOf($calls, 'an:vm1-nic1=True') | Should -BeGreaterThan $sizeAt
        @($calls | Where-Object { $_ -like 'an:vm1-nic2=*' }) | Should -BeNullOrEmpty -Because 'an interface the capture could not read is left alone'
        $log = RanLog $script:rp
        $log | Should -Match 'vm1-nic0' -Because 'the change is said once'
        ([regex]::Matches($log, 'set back to how it was')).Count | Should -Be 0 -Because 'the second pass changed nothing, so it claims nothing'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step.
    It 'a refusal in the first pass is not said as final: the second pass tries again on the original size' {
        $script:rp = RanNewRun
        $global:rr.rule = $false
        $global:rr.refuseOnce = $true
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking {
            if ($global:rr.refuseOnce) { $global:rr.refuseOnce = $false; $global:rr.calls.Add('an:refused'); throw 'the size requires accelerated networking' }
            $global:rr.calls.Add("an:$(($NicId -split '/')[-1])=$Enabled")
            $was = $global:rr.nics[$NicId]; $global:rr.nics[$NicId] = $Enabled; ($was -ne $Enabled)
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        [array]::IndexOf($calls, 'an:refused') | Should -BeLessThan ([array]::IndexOf($calls, 'size'))
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        $global:rr.nics[$script:nic0] | Should -BeFalse
        $log = RanLog $script:rp
        $log | Should -Match 'the size requires accelerated networking'
        $log | Should -Not -Match 'starts with it as the move left it' -Because 'the second pass has not run yet when the first is refused'
        $log | Should -Not -Match 'except accelerated networking' -Because 'the second pass set it back'
        $log | Should -Match 'set back to how it was: vm1-nic0 off'
    }

    It 'a lost lease in the first pass stops the rollback before any machine update' {
        $script:rp = RanNewRun
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'lease lost - abandon this VM' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        $calls = @($global:rr.calls)
        $calls | Should -Be @('stop')
    }

    It 'KILLED between the first pass and the size: the next run starts again at the stop and ends in the same state' {
        $script:rp = RanNewRun
        $global:rr.sizeFails = 1
        { InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*worker stopped*'
        @($global:rr.calls) | Should -Be @('stop', 'an:vm1-nic0=False', 'leaveReservation', 'killed')
        $global:rr.nics[$script:nic0] | Should -BeFalse -Because 'the first pass happened before the kill'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        [bool]$doc.PSObject.Properties['rollback'] | Should -BeFalse -Because 'nothing is on record before the first swap, so the next run starts again at the stop'

        $global:rr.calls.Clear()
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        $calls[0] | Should -Be 'stop'
        $calls[1] | Should -Be 'an:vm1-nic0=False' -Because 'the first pass runs again, and is a no-op'
        $calls | Should -Contain 'size'
        $calls[-1] | Should -Be 'start'
        $global:rr.nics[$script:nic0] | Should -BeFalse
        $global:rr.nics[$script:nic1] | Should -BeTrue
        $global:rr.nics[$script:nic2] | Should -BeFalse
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $doc.rollback.osDisk.name | Should -Match '^vm1-osdisk-asitwas-'
    }

    It 'no first pass when no interface had it before the move: the machine never meets a machine update with none' {
        # Intel D and E v5 REQUIRE accelerated networking, and whether Azure
        # refuses an update of such a machine with none is not measured. With
        # no interface on in the capture, the count cannot be too high, so
        # nothing is turned off before the size.
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.captured.vmConfig.nics[1].acceleratedNetworking = $false
            $doc.captured.original.vmConfig.nics[1].acceleratedNetworking = $false
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $global:rr.nics[$script:nic1] = $false
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        @($calls | Where-Object { $_ -eq 'an:vm1-nic0=False' }).Count | Should -Be 1
        $global:rr.nics[$script:nic0] | Should -BeFalse
    }
    It 'a put-back size with 4 vCPUs keeps the order from before: no off pass (the cap never applies there)' {
        # Review F3: the move may have gone to a size that REQUIRES accelerated
        # networking (Intel D and E v5); turning the primary off there before
        # a machine update is not measured, and the old order worked.
        $global:ranCat.vcpus = '4'
        $global:rr.rule = $false
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        @($calls | Where-Object { $_ -eq 'an:vm1-nic0=False' }).Count | Should -Be 1
        $global:rr.nics[$script:nic0] | Should -BeFalse
        # REBUILD-REMOVE-ENGINE-1: there is no Path B rollback to check as well.
    }

    It 'a constrained size with 2 active vCPUs counts as capped: the pass runs' {
        $global:ranCat.vcpus = '4'; $global:ranCat.active = '2'
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        $calls[1] | Should -Be 'an:vm1-nic0=False'
        @($calls | Where-Object { $_ -like 'refused:*' }) | Should -BeNullOrEmpty
    }

    It 'a size catalog that does not answer is unknown, and unknown is never a fit: the pass runs' {
        $global:ranCat.fail = $true
        $script:rp = RanNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (RanCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rr.calls)
        $calls[1] | Should -Be 'an:vm1-nic0=False'
        $calls[-1] | Should -Be 'start'
    }

}

Describe 'ROLLBACK-RETRY-CAPTURE-3: when the off pass is needed (pure)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:capOf = { param($v, $a) $c = @([pscustomobject]@{ Name = 'vCPUs'; Value = $v }); if ($a) { $c += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $a } }; [pscustomobject]@{ Name = 'x'; Capabilities = $c } }
        $script:need = { param($nics, $sku, $known = $true) InModuleScope VmMigrationFactory -Parameters @{ n = $nics; s = $sku; k = $known } { param($n, $s, $k) Test-VmfAnOffFirstNeeded -Nics $n -SkuEntry $s -SkuKnown $k } }
        $script:two = @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $false }, [pscustomobject]@{ id = 'n1'; primary = $false; acceleratedNetworking = $true })
    }
    It 'primary off, another on, 2 vCPUs: yes' { & $script:need $script:two (& $script:capOf '2') | Should -BeTrue }
    It 'primary off, another on, 4 vCPUs: no' { & $script:need $script:two (& $script:capOf '4') | Should -BeFalse }
    It 'primary off, another on, 4 vCPUs with 2 active: yes' { & $script:need $script:two (& $script:capOf '4' '2') | Should -BeTrue }
    It 'primary off, another on, no catalog row or no vCPU count: yes' {
        & $script:need $script:two $null | Should -BeTrue
        & $script:need $script:two ([pscustomobject]@{ Name = 'x'; Capabilities = @() }) | Should -BeTrue
    }
    It 'the interface question alone: yes for the shape, before any catalog read' { & $script:need $script:two $null $false | Should -BeTrue }
    It 'the primary recorded ON: the move changes nothing, so no' {
        & $script:need @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $true }, [pscustomobject]@{ id = 'n1'; primary = $false; acceleratedNetworking = $true }) (& $script:capOf '2') | Should -BeFalse
    }
    It 'only the primary recorded (on or off), or the other unknown: no' {
        & $script:need @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $false }) (& $script:capOf '2') | Should -BeFalse
        & $script:need @([pscustomobject]@{ id = 'n0'; primary = $true; acceleratedNetworking = $false }, [pscustomobject]@{ id = 'n1'; primary = $false; acceleratedNetworking = $null }) (& $script:capOf '2') | Should -BeFalse
    }
    It 'no interface flagged primary: the first is the primary, as everywhere else' {
        & $script:need @([pscustomobject]@{ id = 'n0'; primary = $false; acceleratedNetworking = $false }, [pscustomobject]@{ id = 'n1'; primary = $false; acceleratedNetworking = $true }) (& $script:capOf '2') | Should -BeTrue
        & $script:need @([pscustomobject]@{ id = 'n0'; primary = $false; acceleratedNetworking = $true }, [pscustomobject]@{ id = 'n1'; primary = $false; acceleratedNetworking = $false }) (& $script:capOf '2') | Should -BeFalse
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-3: a restore from the first copy turns it off before any machine update' {
    BeforeEach {
        # ROLLBACK-RETRY-CAPTURE-3: the size catalog the off pass reads for the size the machine goes back to.
        $global:ranCat = @{ vcpus = '2'; active = $null; fail = $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            if ($global:ranCat.fail) { throw 'The size catalog did not answer.' }
            $caps = @([pscustomobject]@{ Name = 'vCPUs'; Value = $global:ranCat.vcpus })
            if ($global:ranCat.active) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $global:ranCat.active } }
            @([pscustomobject]@{ Name = 'Standard_D2ds_v4'; Capabilities = $caps })
        }
        $global:rq = @{ calls = [System.Collections.Generic.List[string]]::new(); nics = @{} }
        $global:rq.nics[$script:nic0] = $true; $global:rq.nics[$script:nic1] = $true; $global:rq.nics[$script:nic2] = $false
        $global:rq.vmUpdate = {
            param([string]$What)
            if (@($global:rq.nics.Values | Where-Object { $_ -eq $true }).Count -gt 1) {
                $global:rq.calls.Add("refused:$What")
                throw 'VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable: Virtual machine <id> with size Standard_D2s_v4 is restricted to have only one network interface with accelerated networking enabled.'
            }
            $global:rq.calls.Add($What)
        }
        $script:rp = RanNewRun -State 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                        schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'
                        assessment = [ordered]@{ location = 'centralus' }
                        target = [ordered]@{ size = 'Standard_D4s_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = '/disks/vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { & $global:rq.vmUpdate 'osdisk' }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rq.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rq.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D4s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { "$($script:sub)/Microsoft.Compute/capacityReservationGroups/crg1" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { & $global:rq.vmUpdate 'leaveReservation' }
        Mock -ModuleName VmMigrationFactory Remove-VmfClaimAssociation { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { & $global:rq.vmUpdate 'size' }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking {
            $global:rq.calls.Add("an:$(($NicId -split '/')[-1])=$Enabled")
            $was = $global:rq.nics[$NicId]; $global:rq.nics[$NicId] = $Enabled; ($was -ne $Enabled)
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rq -Scope Global -ErrorAction SilentlyContinue }

    It 'the first copy: off right after the stop, before the reservation, the size and the disk; the set-back after the size still runs' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:rq.calls)
        @($calls | Where-Object { $_ -like 'refused:*' }) | Should -BeNullOrEmpty
        $calls[0] | Should -Be 'stop'
        $calls[1] | Should -Be 'an:vm1-nic0=False'
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeLessThan ([array]::IndexOf($calls, 'leaveReservation'))
        [array]::LastIndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        @($calls[0..([array]::IndexOf($calls, 'size'))] | Where-Object { $_ -like 'an:*=True' }) | Should -BeNullOrEmpty
        $calls[-1] | Should -Be 'start'
    }

    It 'the first copy back to a 4-vCPU size: the order from before, the interface after the size' {
        $global:ranCat.vcpus = '4'
        $global:rq.nics[$script:nic1] = $false   # no cap on 4 vCPUs, so the mock rule must not fire
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:rq.calls)
        [array]::IndexOf($calls, 'an:vm1-nic0=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size'))
        @($calls | Where-Object { $_ -eq 'an:vm1-nic0=False' }).Count | Should -Be 1
    }

    It 'the second copy changes no interface' {
        # On a size that takes both (the target here has 4 vCPUs).
        $global:rq.nics[$script:nic1] = $false
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:rq.calls | Where-Object { $_ -like 'an:*' }) | Should -BeNullOrEmpty
    }
}

Describe 'ROLLBACK-AN-1: the words' {
    It 'no manual page says accelerated networking that a move turned on stays on' {
        foreach ($page in Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Filter '*.md' -Recurse) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Not -Match '(?i)accelerated networking that the move turned on stays on' -Because $page.Name
            $text | Should -Not -Match '(?i)stays on after a rollback' -Because $page.Name
        }
    }

    It 'the run page has words for the step' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        $page | Should -Match "\[/\(rollback\|restore\):nicAccelNet/,\s*'setAn'\]"
        $page | Should -Match "setAn:\s*'[^']{10,}'"
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
