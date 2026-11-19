#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-CAPACITY-1 (2026-11-14): a rollback that finds no Azure
# capacity for the original size.
#
# Microsoft restricts capacity growth for older series (the pinned page
# retirements-and-capacity-restrictions, section Impacted VM series), and a
# rollback returns a machine to its original size. The product cannot
# guarantee capacity. So:
#   - the rollback's start tries an allocation failure again, a few times over
#     some minutes (the codes are Microsoft's: Troubleshooting Azure VM
#     allocation failures), before it stops;
#   - the stop says that Azure has no capacity for the size now, that every
#     disk is back, and that the machine is stopped on its original size;
#   - a size change that Azure refused (case B) says so, and that the machine
#     is stopped on the new size;
#   - the plan records, from data, whether the original size of a machine is
#     in a series with restricted capacity, so the sign-off can say it once.
#
# Capacity cannot be forced in a lab, so every case is Azure's own words from
# a mock (the item's proof plan).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    # Az cmdlets are not installed in CI: stand-ins so Pester can mock them,
    # defined before the guard so both mocks take one shape.
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Start-AzVM { param($ResourceGroupName, $Name, [switch]$NoWait) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:allocation = 'Allocation failed. We do not have sufficient capacity for the requested VM size in this region. ErrorCode: AllocationFailed'

    function Global:RbcReset {
        $global:rbc = @{
            size = 'Standard_D2ds_v6'; controller = 'NVMe'
            # Each start answers with the next entry: a string is thrown, $null starts.
            starts = [System.Collections.Generic.List[object]]::new()
            sizeError = $null
            calls = [System.Collections.Generic.List[string]]::new()
            sleeps = [System.Collections.Generic.List[int]]::new()
            power = 'PowerState/running'
        }
    }
    function Global:RbcMockAzure {
        # A mock's $PSBoundParameters is empty: the parameter is read by name.
        Mock -ModuleName VmMigrationFactory Start-Sleep { if ($Seconds) { $global:rbc.sleeps.Add([int]$Seconds) } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rbc.calls.Add('stop'); $global:rbc.power = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { $global:rbc.calls.Add('powerOff') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            $global:rbc.calls.Add('start')
            $next = if ($global:rbc.starts.Count) { $global:rbc.starts[0] } else { $null }
            if ($global:rbc.starts.Count) { $global:rbc.starts.RemoveAt(0) }
            if ($next) { throw $next }
            $global:rbc.power = 'PowerState/running'
        }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:rbc.power }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:rbc.size }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-osdisk'; id = '/disks/vm1-osdisk'; resourceGroup = 'rg-lab'
                location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = $global:rbc.controller }
        }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:rbc.calls.Add("create:$DiskName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            if ($global:rbc.sizeError) { throw $global:rbc.sizeError }
            $global:rbc.size = $Size; $global:rbc.controller = $Controller
            $global:rbc.calls.Add("size:$Size")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rbc.calls.Add("swap:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        # VOLUMES-ONLINE-1's check inside the machine is another item's: here
        # it answers nothing, so the stop is this item's alone.
        Mock -ModuleName VmMigrationFactory Get-VmfRollbackVolumesCheck { $null }
    }

    function Global:RbcNewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rbc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'rbc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rbc' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ size = 'Standard_D2s_v3'; controller = 'SCSI'; location = 'centralus'
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/vm1-osdisk' } }
                    startedTarget = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe'; series = 'v6' }
                }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = '/snapshots/vm1-prepared'; pristineSnapshotId = '/snapshots/vm1-pristine' }) -Force
            $doc.state = 'VALIDATING'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }

    # The context of the full rollback, after a move to D2ds_v6.
    function Global:RbcContext([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'
                assessment = [pscustomobject]@{ os = 'Linux'; sourceSize = 'Standard_D2s_v3' }
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rbc'
        }
    }
}
AfterAll { Remove-Item 'function:\RbcReset', 'function:\RbcMockAzure', 'function:\RbcNewRun', 'function:\RbcContext', 'function:\Get-AzVM', 'function:\Start-AzVM' -ErrorAction SilentlyContinue }

Describe 'ROLLBACK-CAPACITY-1: the codes of an allocation failure are Microsoft''s' {
    It 'tries again on <Code>' -TestCases @(
        @{ Code = 'AllocationFailed' }, @{ Code = 'ZonalAllocationFailed' },
        @{ Code = 'OverconstrainedAllocationRequest' }, @{ Code = 'OverconstrainedZonalAllocationRequest' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $Code } {
            param($c)
            Get-VmfAllocationFailureCode -Message "Start refused. ErrorCode: $c. More text." | Should -Be $c
            Get-VmfAllocationFailureCode -Message "Azure did not start the machine: ProvisioningState/failed/$c - Allocation failed." | Should -Be $c
        }
    }
    It 'does not try again on <Code>, which more minutes do not mend' -TestCases @(
        @{ Code = 'SkuNotAvailable' }, @{ Code = 'QuotaExceeded' }, @{ Code = 'NotAvailableForSubscription' }, @{ Code = 'OperationNotAllowed' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $Code } {
            param($c)
            Get-VmfAllocationFailureCode -Message "Start refused. ErrorCode: $c." | Should -BeNullOrEmpty
        }
    }
    It 'reads a code only as a whole word, never inside a name' {
        InModuleScope VmMigrationFactory {
            Get-VmfAllocationFailureCode -Message "Conflict on 'vm-AllocationFailedTest'." | Should -BeNullOrEmpty
            Get-VmfAllocationFailureCode -Message '' | Should -BeNullOrEmpty
        }
    }
    It 'the codes are the four of Microsoft''s page, and the source names that page' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackStart.ps1')
        $code | Should -Match 'VmfAllocationFailureCodes\s*=\s*@\('
        InModuleScope VmMigrationFactory { @($script:VmfAllocationFailureCodes | Sort-Object) } |
            Should -Be @('AllocationFailed', 'OverconstrainedAllocationRequest', 'OverconstrainedZonalAllocationRequest', 'ZonalAllocationFailed')
        (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackStart.ps1') -Raw) |
            Should -Match ([regex]::Escape('learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/allocation-failure'))
    }
}

Describe 'ROLLBACK-CAPACITY-1: only Azure''s refusal of the size is the size refused' {
    It 'reads <Code> as a refusal of the size' -TestCases @(
        @{ Code = 'NotAvailableForSubscription'; Said = "The requested size for resource '<placeholder>' is not available in location 'centralus'. ErrorCode: NotAvailableForSubscription" }
        @{ Code = 'SkuNotAvailable'; Said = "The requested VM size Standard_D2s_v3 is not available in the current region. ErrorCode: SkuNotAvailable" }
        @{ Code = 'OperationNotAllowed'; Said = 'OperationNotAllowed: Operation could not be completed as it results in exceeding approved standardDSv3Family Cores quota.' }
        @{ Code = 'OperationNotAllowed'; Said = 'OperationNotAllowed: The VM size Standard_D2s_v3 is not allowed in this subscription.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Said; c = $Code } {
            param($s, $c)
            Get-VmfSizeRefusalCode -Message $s -Size 'Standard_D2s_v3' | Should -Be $c
        }
    }
    It 'does not read <Name> as a refusal of the size' -TestCases @(
        @{ Name = 'a throttle'; Said = 'TooManyRequests: The request is being throttled.' }
        @{ Name = 'a timeout'; Said = 'The operation timed out after 1800 seconds.' }
        @{ Name = 'a failed update status'; Said = 'Update-AzVM returned status Failed for vm1.' }
        @{ Name = 'OperationNotAllowed that names neither the size nor a quota'; Said = 'OperationNotAllowed: The operation is not allowed because the VM is being updated.' }
        @{ Name = 'a code that is a quoted name'; Said = "Conflict on the disk 'SkuNotAvailable'." }
        @{ Name = 'a code inside a longer word'; Said = 'ErrorCode: NotAvailableForSubscriptionX' }
        @{ Name = 'nothing'; Said = '' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Said } {
            param($s)
            Get-VmfSizeRefusalCode -Message $s -Size 'Standard_D2s_v3' | Should -BeNullOrEmpty
        }
    }
    It 'the source names Microsoft''s pages for the codes' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackStart.ps1') -Raw
        $src | Should -Match ([regex]::Escape('learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-sku-not-available'))
        $src | Should -Match ([regex]::Escape('learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-resource-quota'))
    }
}
Describe 'ROLLBACK-CAPACITY-1: the put-back says which settings changed' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'accelerated networking names only each interface whose setting Azure changed' {
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $NicId -like '*nic1' }
        $out = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $changed = [System.Collections.Generic.List[string]]::new()
            $nics = @([pscustomobject]@{ id = '/nics/vm1-nic1'; acceleratedNetworking = $true }, [pscustomobject]@{ id = '/nics/vm1-nic2'; acceleratedNetworking = $false })
            $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $rp -VmId $id -Nics $nics -Kind 'rollback' -ChangedOut $changed
            , @($changed)
        }
        $out | Should -Be @('vm1-nic1')
    }

    It 'the disk types name only each disk whose type Azure set back' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'StandardSSD_LRS' } }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { if ($DiskId -like '*data1') { throw 'Azure refused the type.' } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName diskTypeChanges -NotePropertyValue @(
                [pscustomobject]@{ diskId = '/disks/vm1-osdisk'; from = 'Premium_LRS'; to = 'StandardSSD_LRS'; by = 'move' },
                [pscustomobject]@{ diskId = '/disks/vm1-data1'; from = 'Premium_LRS'; to = 'StandardSSD_LRS'; by = 'move' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $back = [System.Collections.Generic.List[string]]::new()
            $notBack = Restore-VmfCapturedDiskTypes -RunPath $rp -VmId $id -Kind 'rollback' -DiskIds @('/disks/vm1-osdisk', '/disks/vm1-data1') -SetBack $back
            @{ back = @($back); notBack = $notBack }
        }
        $r.back | Should -Be @('vm1-osdisk')
        $r.notBack | Should -Be 1
    }
}
Describe 'ROLLBACK-CAPACITY-1: Start-VmfVm reads a start that Azure refused' {
    BeforeEach {
        $global:svPower = 'PowerState/deallocated'
        Mock -ModuleName VmMigrationFactory Start-AzVM { $global:svStarts++ }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:svPower }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        $global:svStarts = 0
    }
    It 'stops waiting at once when Azure reports a failed start newer than the request, and names the code' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmStartFailure {
            [pscustomobject]@{ Code = 'ProvisioningState/failed/AllocationFailed'; Message = 'Allocation failed.'; Time = (Get-Date).ToUniversalTime().AddSeconds(5) }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { InModuleScope VmMigrationFactory { Start-VmfVm -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 30 -PollIntervalSeconds 0 } } |
            Should -Throw -ExpectedMessage '*AllocationFailed*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        $global:svStarts | Should -Be 1
    }
    It 'does not read a failed start older than the request as this start - only names it when the wait ends' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmStartFailure {
            [pscustomobject]@{ Code = 'ProvisioningState/failed/AllocationFailed'; Message = 'Allocation failed.'; Time = (Get-Date).ToUniversalTime().AddMinutes(-10) }
        }
        $err = $null
        try { InModuleScope VmMigrationFactory { Start-VmfVm -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 1 -PollIntervalSeconds 0 } }
        catch { $err = $_.Exception.Message }
        $err | Should -Match 'did not reach PowerState/running'
        $err | Should -Match 'AllocationFailed'
    }
    It 'a read of the failure that fails is no answer, and the wait goes on' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmStartFailure { throw 'The service did not answer.' }
        $script:n = 0
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $script:n++; if ($script:n -ge 3) { 'PowerState/running' } else { 'PowerState/starting' } }
        { InModuleScope VmMigrationFactory { Start-VmfVm -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 30 -PollIntervalSeconds 0 } } | Should -Not -Throw
    }
}

Describe 'ROLLBACK-CAPACITY-1: Get-VmfVmStartFailure reads the provisioning state of the instance view' {
    It 'gives a failed provisioning state with its time and message' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ Statuses = @(
                    [pscustomobject]@{ Code = 'ProvisioningState/failed/AllocationFailed'; Message = 'Allocation failed.'; Time = [datetime]'2026-11-14T10:00:00Z' },
                    [pscustomobject]@{ Code = 'PowerState/deallocated'; Message = $null; Time = $null }) }
        }
        $r = InModuleScope VmMigrationFactory { Get-VmfVmStartFailure -ResourceGroupName 'rg' -Name 'vm1' }
        $r.Code | Should -Be 'ProvisioningState/failed/AllocationFailed'
        $r.Message | Should -Be 'Allocation failed.'
        $r.Time | Should -Not -BeNullOrEmpty
    }
    It 'gives nothing for a provisioning state that did not fail' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/updating'; Time = [datetime]'2026-11-14T10:00:00Z' },
                    [pscustomobject]@{ Code = 'PowerState/starting' }) }
        }
        InModuleScope VmMigrationFactory { Get-VmfVmStartFailure -ResourceGroupName 'rg' -Name 'vm1' } | Should -BeNullOrEmpty
    }
}

Describe 'ROLLBACK-CAPACITY-1: the start of the full rollback tries an allocation failure again' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'tries 4 times with a wait between each, then throws a start-only failure that names the size' {
        foreach ($i in 1..4) { $global:rbc.starts.Add($script:allocation) }
        $ctx = Global:RbcContext $script:rp
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfRollback -Context $ctx } }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        @($global:rbc.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 4
        @($global:rbc.sleeps | Where-Object { $_ -ge 60 }).Count | Should -Be 3 -Because "the waits were: $($global:rbc.sleeps -join ', ')"
        $err.Exception.Data['vmfRollbackStartOnly'] | Should -BeTrue
        $err.Exception.Data['vmfRollbackNoCapacity'] | Should -Be 'Standard_D2s_v3'
        $err.Exception.Message | Should -Match 'Azure has no capacity for Standard_D2s_v3'
        # Every disk is back before the start: the size, then the swap.
        $global:rbc.calls | Should -Contain 'size:Standard_D2s_v3'
        @($global:rbc.calls | Where-Object { $_ -like 'swap:*' }).Count | Should -Be 1
    }

    It 'starts on the third try, and the rollback ends as any other' {
        $global:rbc.starts.Add($script:allocation); $global:rbc.starts.Add('ZonalAllocationFailed: Allocation failed.')
        $ctx = Global:RbcContext $script:rp
        { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfRollback -Context $ctx } } | Should -Not -Throw
        @($global:rbc.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 3
    }

    It 'another refusal is not tried again here, and is still a start-only failure: every disk is back' {
        $global:rbc.starts.Add('OperationNotAllowed: The operation is not allowed now.')
        $ctx = Global:RbcContext $script:rp
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfRollback -Context $ctx } }
        catch { $err = $_ }
        @($global:rbc.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        $err.Exception.Data['vmfRollbackStartOnly'] | Should -BeTrue
        $err.Exception.Data['vmfRollbackNoCapacity'] | Should -BeNullOrEmpty
    }

    It 'a lost lease between two tries goes up at once, untouched' {
        $global:rbc.starts.Add($script:allocation); $global:rbc.starts.Add('Lease lost - abandon this VM.')
        $ctx = Global:RbcContext $script:rp
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfRollback -Context $ctx } }
        catch { $err = $_ }
        $err.Exception.Message | Should -Match 'abandon this VM'
        $err.Exception.Data['vmfRollbackStartOnly'] | Should -BeNullOrEmpty
        @($global:rbc.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 2
    }
}

Describe 'ROLLBACK-CAPACITY-1: the stop when Azure still has no capacity' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'is rolled back, with its own reason, and says every disk is back and the machine is stopped on its size' {
        foreach ($i in 1..20) { $global:rbc.starts.Add($script:allocation) }
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackNoCapacity'
        $last.detail | Should -Match 'Azure has no capacity for Standard_D2s_v3 now'
        $last.detail | Should -Match 'Every disk is back from the first safety copy'
        $last.detail | Should -Match 'stopped on Standard_D2s_v3'
        $last.detail | Should -Match 'The check failed\.'
        $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        # Not held: only its power state can differ, and a retry puts that back first.
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d } | Should -BeFalse
    }

    It 'Azure has capacity again when the machine found running is started once more: no capacity stop, and the words never say stopped' {
        foreach ($i in 1..4) { $global:rbc.starts.Add($script:allocation) }
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'validationFailedAfterConversion'
        @($doc.history)[-1].detail | Should -Not -Match 'is stopped on'
        $global:rbc.power | Should -Be 'PowerState/running'
    }

    It 'the reason is in the stop table, rolled back, and says when to try again' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'rollbackNoCapacity'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'restored'
            $g.retry | Should -Be 'whenAvailable'
        }
    }

    It 'a worker that stopped between two tries: the resume runs the rollback again and ends in one stop' {
        $global:rbc.starts.Add($script:allocation); $global:rbc.starts.Add('Lease lost - abandon this VM.')
        $ctx = Global:RbcContext $script:rp
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            { Complete-VmfRollback -Context $ctx } | Should -Throw -ExpectedMessage '*abandon this VM*'
            (Read-VmfStateDoc -RunPath $ctx.RunPath -VmId $ctx.VmId).rollbackPending | Should -Not -BeNullOrEmpty
        }
        # Azure has capacity again when the next worker takes the machine.
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Complete-VmfRollback -Context $ctx -Resumed }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'validationFailedAfterConversion'
        @($doc.history | Where-Object { $_.state -eq 'FAILED_ROLLED_BACK' }).Count | Should -Be 1
    }
}

Describe 'ROLLBACK-CAPACITY-1: the disks-only rollback before the move tries the same way' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun; $global:rbc.size = 'Standard_D2s_v3'; $global:rbc.controller = 'SCSI' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'tries 4 times, then stops with the same reason and words' {
        foreach ($i in 1..20) { $global:rbc.starts.Add($script:allocation) }
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind disks -State 'GUEST_PREP' -ReasonCode 'guestPrepBlocked' -Detail 'The preparation failed.'
            Complete-VmfRollback -Context $ctx
        }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'rollbackNoCapacity'
        @($doc.history)[-1].detail | Should -Match 'Azure has no capacity for Standard_D2s_v3 now'
        @($global:rbc.sleeps | Where-Object { $_ -ge 60 }).Count | Should -Be 3
    }
}

Describe 'ROLLBACK-CAPACITY-1: case B, Azure refuses the original size' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'stops before any swap and any start, with its own reason, and names both sizes' {
        $global:rbc.sizeError = "The requested size for resource '<placeholder>' is currently not available in location 'centralus' zones '' for subscription '<placeholder>'. ErrorCode: NotAvailableForSubscription"
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackSizeRefused'
        $last.machineState | Should -Be 'changed'
        $last.detail | Should -Match 'Azure refused the original size Standard_D2s_v3'
        $last.detail | Should -Match 'stopped on Standard_D2ds_v6'
        $last.detail | Should -Match 'NotAvailableForSubscription'
        @($global:rbc.calls | Where-Object { $_ -like 'swap:*' -or $_ -eq 'start' }).Count | Should -Be 0
    }

    It 'a lost lease on the size change goes up untouched, and is never the size refused - even when the error also names a refusal code' {
        $global:rbc.sizeError = 'Lease lost while Azure answered NotAvailableForSubscription - abandon this VM.'
        $ctx = Global:RbcContext $script:rp
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            $err = $null
            try { Invoke-VmfRollback -Context $ctx } catch { $err = $_ }
            $err.Exception.Message | Should -Match 'abandon this VM'
            $err.Exception.Data['vmfRollbackSizeRefused'] | Should -BeNullOrEmpty
            $err.Exception.Data['vmfRollbackReason'] | Should -BeNullOrEmpty
            { Complete-VmfRollback -Context $ctx } | Should -Throw -ExpectedMessage '*abandon this VM*'
            $doc = Read-VmfStateDoc -RunPath $ctx.RunPath -VmId $ctx.VmId
            $doc.rollbackPending | Should -Not -BeNullOrEmpty
            @($doc.history | Where-Object { $_.reasonCode -eq 'rollbackSizeRefused' }).Count | Should -Be 0
        }
    }

    It 'a size change that failed for another cause (<Name>) is a failed rollback, not the size refused' -TestCases @(
        @{ Name = 'a throttle out of tries'; Said = 'TooManyRequests: The request is being throttled. The operation was tried 5 times.' }
        @{ Name = 'a timeout'; Said = 'The operation timed out after 1800 seconds.' }
        @{ Name = 'an update with a failed status'; Said = 'Update-AzVM returned status Failed for vm1.' }
        @{ Name = 'OperationNotAllowed for something else'; Said = 'OperationNotAllowed: The operation is not allowed because the VM is being updated.' }
    ) {
        $global:rbc.sizeError = $Said
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackFailed'
        $last.detail | Should -Not -Match 'refused the original size'
        $last.detail | Should -Match ([regex]::Escape($Said))
    }

    It 'names each setting the rollback put back before Azure refused the size' {
        $global:rbc.sizeError = "The requested size for resource '<placeholder>' is not available. ErrorCode: SkuNotAvailable"
        Mock -ModuleName VmMigrationFactory Get-VmfReservationPutBack {
            @{ Leave = $true; LeaveGroupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/crg-move'; LeaveIsOurs = $true; Words = @() }
        }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { if ($null -ne $SetBack) { $SetBack.Add('vm1-osdisk') }; 0 }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedAcceleratedNetworking { if ($OffFirst -and $null -ne $ChangedOut) { $ChangedOut.Add('vm1-nic2') }; 0 }
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackSizeRefused'
        $last.detail | Should -Match 'The rollback did not swap a disk\.'
        $last.detail | Should -Match ([regex]::Escape("Accelerated networking is off again on these network interfaces: 'vm1-nic2'."))
        $last.detail | Should -Match ([regex]::Escape("The machine left the capacity reservation group 'crg-move'."))
        $last.detail | Should -Match ([regex]::Escape("These disks have their type from before the move again: 'vm1-osdisk'."))
        $last.detail | Should -Not -Match 'as the move left them'
    }

    It 'says when the rollback found no other setting to put back before the size' {
        $global:rbc.sizeError = "ErrorCode: NotAvailableForSubscription"
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        @($doc.history)[-1].detail | Should -Match 'This rollback found no other setting to restore before the size change\.'
    }
    It 'the reason is in the stop table, changed' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'rollbackSizeRefused'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'changed'
        }
    }
}

# ROLLBACK-POLICY-DENY-1 (2026-11-16, final lab step 3.13): an Azure
# Policy deny of the original size. The error shape is Microsoft's ("Resolve
# errors for request disallowed by policy", read 2026-11-16): the code
# RequestDisallowedByPolicy, and the policy assignment named in the message as
# "policyAssignment":{"name":...,"id":...}. A REST body also carries it in
# additionalInfo as policyAssignmentDisplayName. Every id is a placeholder
# (rule 13); the assignment's display name is a made-up one.
Describe 'ROLLBACK-POLICY-DENY-1: Get-VmfPolicyDenial reads Azure''s policy refusal' {
    BeforeAll {
        $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000'
        # Az PowerShell (Update-AzVM), as Resolve-VmfOperationError gives it.
        $script:azPs = "HTTP 403 RequestDisallowedByPolicy - Resource 'vm1' was disallowed by policy. Policy identifiers: " +
            "'[{`"policyAssignment`":{`"name`":`"Deny Standard_D2s_v3 in rg-lab`",`"id`":`"$($script:sub)/resourceGroups/rg-lab/providers/Microsoft.Authorization/policyAssignments/1111aa2222bb3333cc4444dd`"}," +
            "`"policyDefinition`":{`"name`":`"Allowed virtual machine size SKUs`",`"id`":`"/providers/Microsoft.Authorization/policyDefinitions/00000000-0000-0000-0000-000000000000`",`"version`":`"1.0.1`"}}]'.`n" +
            "ErrorCode: RequestDisallowedByPolicy`nErrorMessage: Resource 'vm1' was disallowed by policy.`nErrorTarget: vm1`nStatusCode: 403`nReasonPhrase: Forbidden"
        # The REST body (ErrorDetails): the message holds the identifiers with
        # escaped quotes, and additionalInfo the display name.
        $bs = [string][char]92
        $q = $bs + '"'
        $script:rest = '{"error":{"code":"RequestDisallowedByPolicy","target":"vm1","message":"Resource ''vm1'' was disallowed by policy. Policy identifiers: ''[{' +
            $q + 'policyAssignment' + $q + ':{' + $q + 'name' + $q + ':' + $q + 'Assignment name in the message' + $q + ',' + $q + 'id' + $q + ':' + $q + $script:sub + '/providers/Microsoft.Authorization/policyAssignments/1111aa2222bb3333cc4444dd' + $q + '}}]''.",' +
            '"additionalInfo":[{"type":"PolicyViolation","info":{"policyDefinitionDisplayName":"Allowed virtual machine size SKUs","policyAssignmentDisplayName":"Deny Standard_D2s_v3 in rg-lab","policyAssignmentName":"1111aa2222bb3333cc4444dd"}}]}}'
        # Microsoft's page, as written there: a space after a comma, the id last.
        $script:page = '"statusMessage": "{"error":{"code":"RequestDisallowedByPolicy", "target":"examplenic1207", "message":"Resource `examplenic1207` was disallowed by policy. Policy identifiers: ' +
            '"policyAssignment":{"name":"Network interfaces should not have public IPs", "id":"/subscriptions/{guid}/providers/Microsoft.Authorization/policyAssignments/1111aa2222bb3333cc4444dd"}'
    }
    It 'reads the code and the assignment from <Name>' -TestCases @(
        @{ Name = 'Az PowerShell'; Key = 'azPs'; Want = 'Deny Standard_D2s_v3 in rg-lab' }
        @{ Name = 'a REST body, display name first'; Key = 'rest'; Want = 'Deny Standard_D2s_v3 in rg-lab' }
        @{ Name = 'Microsoft''s own example'; Key = 'page'; Want = 'Network interfaces should not have public IPs' }
    ) {
        $said = (Get-Variable -Scope Script -Name $Key).Value
        $d = InModuleScope VmMigrationFactory -Parameters @{ s = $said } { param($s) Get-VmfPolicyDenial -Message $s }
        $d.Code | Should -Be 'RequestDisallowedByPolicy'
        $d.Assignment | Should -BeExactly $Want
    }
    It 'reads the name when the id comes first, and a name with an apostrophe' {
        $said = "RequestDisallowedByPolicy: Policy identifiers: '[{`"policyAssignment`":{`"id`":`"$($script:sub)/providers/Microsoft.Authorization/policyAssignments/abc`",`"name`":`"Don't allow D2s_v3`"}}]'."
        $d = InModuleScope VmMigrationFactory -Parameters @{ s = $said } { param($s) Get-VmfPolicyDenial -Message $s }
        $d.Assignment | Should -BeExactly "Don't allow D2s_v3"
    }
    It 'the code with no identifiers is a refusal with no name' {
        $d = InModuleScope VmMigrationFactory { Get-VmfPolicyDenial -Message 'HTTP 403 RequestDisallowedByPolicy - The request was disallowed by policy.' }
        $d.Code | Should -Be 'RequestDisallowedByPolicy'
        $d.Assignment | Should -BeNullOrEmpty
    }
    It 'is not a policy refusal: <Name>' -TestCases @(
        @{ Name = 'nothing'; Said = '' }
        @{ Name = 'the code inside a longer word'; Said = 'ErrorCode: RequestDisallowedByPolicyX' }
        @{ Name = 'the code as a quoted name'; Said = "Conflict on the disk 'RequestDisallowedByPolicy'." }
        @{ Name = 'another refusal'; Said = 'HTTP 403 AuthorizationFailed - The client does not have authorization.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Said } { param($s) Get-VmfPolicyDenial -Message $s } | Should -BeNullOrEmpty
    }
    It 'a name longer than Azure allows (128) is cut, so a bad read cannot fill a line' {
        $long = 'x' * 300
        $d = InModuleScope VmMigrationFactory -Parameters @{ s = "RequestDisallowedByPolicy `"policyAssignment`":{`"name`":`"$long`"}" } { param($s) Get-VmfPolicyDenial -Message $s }
        $d.Assignment.Length | Should -Be 128
    }
    It 'the words name the assignment, never the JSON' {
        InModuleScope VmMigrationFactory {
            Get-VmfPolicyDenialWords -Denial ([pscustomobject]@{ Code = 'RequestDisallowedByPolicy'; Assignment = 'Deny Standard_D2s_v3 in rg-lab' }) |
                Should -BeExactly "The Azure Policy assignment 'Deny Standard_D2s_v3 in rg-lab' did not allow the request (RequestDisallowedByPolicy)."
            Get-VmfPolicyDenialWords -Denial ([pscustomobject]@{ Code = 'RequestDisallowedByPolicy'; Assignment = $null }) |
                Should -BeExactly 'An Azure Policy assignment did not allow the request (RequestDisallowedByPolicy).'
        }
    }
    It 'Get-VmfSizeRefusalCode reads a policy refusal of the size update as the size refused' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:azPs; r = $script:rest } {
            param($a, $r)
            Get-VmfSizeRefusalCode -Message $a -Size 'Standard_D2s_v3' | Should -Be 'RequestDisallowedByPolicy'
            Get-VmfSizeRefusalCode -Message $r -Size 'Standard_D2s_v3' | Should -Be 'RequestDisallowedByPolicy'
        }
    }
    It 'the source names Microsoft''s page for the code' {
        (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackStart.ps1') -Raw) |
            Should -Match ([regex]::Escape('learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-policy-requestdisallowedbypolicy'))
    }
}

Describe 'ROLLBACK-POLICY-DENY-1: the Activity line of an Azure call that a policy refused' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rbp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'rbp' | Out-Null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }
    It '<Name>' -TestCases @(
        @{ Name = 'policy JSON with no name that can be read: an assignment, never the JSON'
            Said = 'RequestDisallowedByPolicy: Policy identifiers: ''[{"policyAssignment":{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/policyAssignments/abc"}}]''.'
            Want = 'An Azure Policy assignment did not allow the request (RequestDisallowedByPolicy).' }
        @{ Name = 'a policy refusal with no policy JSON keeps Azure''s words'
            Said = 'RequestDisallowedByPolicy: tag name not permitted'
            Want = 'RequestDisallowedByPolicy: tag name not permitted' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; s = $Said } {
            param($rp, $s)
            { Invoke-VmfAzOperation -Name 'test:policy' -RunPath $rp -VmId '/vm1' -Operation { throw $s } } | Should -Throw
        }
        $line = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.step -eq 'azureops:test:policy' -and $_.outcome -eq 'fail' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -BeExactly $Want
    }
}

Describe 'ROLLBACK-POLICY-DENY-1: an Azure Policy that does not allow the original size' {
    BeforeEach { Global:RbcReset; Global:RbcMockAzure; $script:rp = Global:RbcNewRun }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }
    BeforeAll {
        $script:policySaid = "Resource 'vm1' was disallowed by policy. Policy identifiers: " +
            "'[{`"policyAssignment`":{`"name`":`"Deny Standard_D2s_v3 in rg-lab`",`"id`":`"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Authorization/policyAssignments/1111aa2222bb3333cc4444dd`"}," +
            "`"policyDefinition`":{`"name`":`"Allowed virtual machine size SKUs`",`"id`":`"/providers/Microsoft.Authorization/policyDefinitions/00000000-0000-0000-0000-000000000000`"}}]'.`n" +
            "ErrorCode: RequestDisallowedByPolicy`nStatusCode: 403`nReasonPhrase: Forbidden"
        function Global:RbcEvents([string]$Rp) {
            @(Get-Content (Join-Path $Rp 'logs' 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
        }
    }
    AfterAll { Remove-Item 'function:\RbcEvents' -ErrorAction SilentlyContinue }

    It 'stops with rollbackSizeRefused, names the assignment, says what to do, and shows no policy JSON' {
        $global:rbc.sizeError = $script:policySaid
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackSizeRefused'
        $last.machineState | Should -Be 'changed'
        $last.detail | Should -Match ([regex]::Escape('The rollback stopped because Azure refused the original size Standard_D2s_v3 (RequestDisallowedByPolicy).'))
        $last.detail | Should -Match ([regex]::Escape("The Azure Policy assignment 'Deny Standard_D2s_v3 in rg-lab' does not allow this size."))
        $last.detail | Should -Match ([regex]::Escape('To restore the machine to Standard_D2s_v3, change the policy assignment, or add a policy exemption for this machine.'))
        $last.detail | Should -Match 'stopped on Standard_D2ds_v6'
        $last.detail | Should -Match 'The check failed\.'
        $last.detail | Should -Not -Match 'policyAssignment|policyDefinition|Policy identifiers|/subscriptions/|\{'
        @($global:rbc.calls | Where-Object { $_ -like 'swap:*' -or $_ -eq 'start' }).Count | Should -Be 0
    }

    It 'with no assignment in Azure''s words, the stop says an assignment, and is still the size refused' {
        $global:rbc.sizeError = 'ErrorCode: RequestDisallowedByPolicy. The request was disallowed by policy.'
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackSizeRefused'
        $last.detail | Should -Match ([regex]::Escape('An Azure Policy assignment does not allow this size.'))
    }

    It 'the Activity line of the refused size change names the assignment, not the JSON' {
        $global:rbc.sizeError = $script:policySaid
        $ctx = Global:RbcContext $script:rp
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            $null = Complete-VmfRollback -Context $ctx
        }
        $line = @(Global:RbcEvents $script:rp | Where-Object { $_.step -eq 'azureops:rollback:revertSize' -and $_.outcome -eq 'fail' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -BeExactly "The Azure Policy assignment 'Deny Standard_D2s_v3 in rg-lab' did not allow the request (RequestDisallowedByPolicy)."
    }

    It 'a policy refusal of another rollback step is a failed rollback, named in words, never the size refused' {
        # The disk type put-back, before the size: not the size update.
        $global:rbcPolicySaid = $script:policySaid
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { throw $global:rbcPolicySaid }
        $ctx = Global:RbcContext $script:rp
        $doc = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } {
            param($ctx)
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The check failed.'
            Complete-VmfRollback -Context $ctx
        }
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rollbackFailed'
        $last.detail | Should -Not -Match 'refused the original size'
        $last.detail | Should -Match ([regex]::Escape("The Azure Policy assignment 'Deny Standard_D2s_v3 in rg-lab' did not allow the request (RequestDisallowedByPolicy)."))
        $last.detail | Should -Not -Match 'policyAssignment|Policy identifiers|/subscriptions/'
    }

}

Describe 'ROLLBACK-CAPACITY-1: the restricted series are data, read from Microsoft''s page' {
    BeforeAll {
        $script:families = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:page = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'lifecycle' 'retirements-and-capacity-restrictions.md') -Raw
    }
    It 'every series in the data is in the pinned page''s table of impacted series, and every series there is in the data' {
        $table = [regex]::Match($script:page, '(?s)## Impacted VM series.*?\n\n(\|.*?)\n\n').Groups[1].Value
        $table | Should -Not -BeNullOrEmpty
        $onPage = @([regex]::Matches($table, '\[([A-Za-z0-9]+)\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        @($script:families.lifecycle.capacityRestrictions.series | Sort-Object -Unique) | Should -Be $onPage
        $script:families.lifecycle.capacityRestrictions.source | Should -Be 'retirements-and-capacity-restrictions'
        # One page is one source (GEN-V5-1, V3-RETIRE-1): the restrictions are read in its words.
        $src = @($script:families.sources | Where-Object { $_.url -like '*/retirements-and-capacity-restrictions' })
        $src.Count | Should -Be 1
        $src[0].says | Should -Match 'ROLLBACK-CAPACITY-1 \(section impacted-vm-series'
    }
    It '<Size> is restricted: <Want>' -TestCases @(
        @{ Size = 'Standard_D4s_v3'; Want = $true }, @{ Size = 'Standard_E8s_v3'; Want = $true }, @{ Size = 'Standard_E64is_v3'; Want = $true }
        @{ Size = 'Standard_DS2_v2'; Want = $true }, @{ Size = 'Standard_D11_v2'; Want = $true }, @{ Size = 'Standard_D4'; Want = $true }
        @{ Size = 'Standard_B2ms'; Want = $true }, @{ Size = 'Standard_B1ls'; Want = $true }, @{ Size = 'Standard_A2_v2'; Want = $true }
        @{ Size = 'Standard_A2m_v2'; Want = $true }, @{ Size = 'Standard_F4s_v2'; Want = $true }, @{ Size = 'Standard_F4'; Want = $true }
        @{ Size = 'standard_d4s_v3'; Want = $true }
        @{ Size = 'Standard_D4s_v4'; Want = $false }, @{ Size = 'Standard_D4ds_v5'; Want = $false }, @{ Size = 'Standard_E4as_v4'; Want = $false }
        @{ Size = 'Standard_D4ads_v6'; Want = $false }, @{ Size = 'Standard_B2s_v2'; Want = $false }, @{ Size = 'Standard_D4as_v4'; Want = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size } { param($s) Test-VmfSizeCapacityRestricted -SizeName $s } | Should -Be $Want
    }
    It 'a size it cannot read is not known: $null, never a yes or a no' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeCapacityRestricted -SizeName '' | Should -BeNullOrEmpty
            Test-VmfSizeCapacityRestricted -SizeName 'not a size' | Should -BeNullOrEmpty
        }
    }
}
