#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# OLD-FAM-1: a source size that cannot carry accelerated networking.
#
# B1s to B8ms, F1 and some Av2 sizes report AcceleratedNetworkingEnabled =
# False, and Azure refuses the setting on a network interface of a machine on
# such a size. The engine turned it on BEFORE the resize - while the machine
# was still on its old size - and every way back set the old size back while
# it was still on. The independent review of OLD-FAM-1 found it: the same
# class as OLD-SKU-1C's disk types. So: PRECHECK records what the source size
# can carry; the move turns it on only on the new size (Path A) or while the
# interface belongs to no machine (Path B); every way back turns it off first.

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

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:nic0 = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic0"

    # A B2s machine: accelerated networking off, and its size cannot turn it on.
    function Global:SaRun([object]$Capable = $false) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; n0 = $script:nic0; cap = $Capable } {
            param($rp, $id, $sub, $n0, $cap)
            Initialize-VmfRun -RunPath $rp -RunId 'sa' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'sa' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{
                    sourceAcceleratedNetworking = $cap
                    acceleratedNetworking = [pscustomobject]@{ policy = 'ensureOn'; expectFabric = $false }
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_B2s'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @()
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/Microsoft.Compute/disks/vm1-osdisk" }
                        dataDisks = @(); tags = @{}
                        nics = @([pscustomobject]@{ id = $n0; primary = $false; acceleratedNetworking = $false }) } })
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:SaCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = 'Standard_B2s' }
                target = [pscustomobject]@{ size = 'Standard_D2lds_v5'; controller = '' }
                policy = [pscustomobject]@{ safetyCopy = 'pristine'; acceleratedNetworking = 'ensureOn'; targetGeneration = 'v5' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sa'
        }
    }
    function Global:SaMocks {
        $global:sa = @{ calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:sa.calls.Add("an=$Enabled"); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:sa.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:sa.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:sa.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = '/d/vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:sa.calls.Add('osdisk') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
    }
}
AfterAll { Remove-Item function:SaRun, function:SaCtx, function:SaMocks -ErrorAction SilentlyContinue }

Describe 'OLD-FAM-1: what a size can carry' {
    It 'reads the catalog; a size that does not say is not a yes and not a no' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeTakesAcceleratedNetworking -SkuEntry ([pscustomobject]@{ Capabilities = @([pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'False' }) }) | Should -BeFalse
            Test-VmfSizeTakesAcceleratedNetworking -SkuEntry ([pscustomobject]@{ Capabilities = @([pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'True' }) }) | Should -BeTrue
            Test-VmfSizeTakesAcceleratedNetworking -SkuEntry ([pscustomobject]@{ Capabilities = @() }) | Should -BeNullOrEmpty
            Test-VmfSizeTakesAcceleratedNetworking -SkuEntry $null | Should -BeNullOrEmpty
        }
    }

    It 'PRECHECK records it, beside the capture' {
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        # ROLLBACK-RETRY-CAPTURE-1: the value is computed once and saved twice -
        # beside this attempt's capture, and with the first capture when that is written.
        $sm | Should -Match '\$sourceAn = Test-VmfSizeTakesAcceleratedNetworking -SkuEntry \$sourceSku'
        $sm | Should -Match 'sourceAcceleratedNetworking = \$sourceAn'
    }
}

Describe 'OLD-FAM-1: the move turns it on only on the new size' {
    BeforeEach { SaMocks }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sa -Scope Global -ErrorAction SilentlyContinue }

    It 'THE REVIEW CASE, Path A: a B2s is resized first, then accelerated networking goes on' {
        $script:rp = SaRun $false
        InModuleScope VmMigrationFactory -Parameters @{ c = (SaCtx $script:rp 'A') } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:sa.calls) | Should -Be @('size:Standard_D2lds_v5', 'an=True')
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'a source size that carries it, or does not say, keeps the order the engine always had' {
        foreach ($cap in $true, $null) {
            $script:rp = SaRun $cap
            $global:sa.calls.Clear()
            InModuleScope VmMigrationFactory -Parameters @{ c = (SaCtx $script:rp 'A') } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
            @($global:sa.calls) | Should -Be @('an=True', 'size:Standard_D2lds_v5') -Because "source says $cap"
            Remove-Item $script:rp -Recurse -Force
        }
    }
}

Describe 'OLD-FAM-1: every way back turns it off before the old size' {
    BeforeEach { SaMocks }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sa -Scope Global -ErrorAction SilentlyContinue }

    It 'THE REVIEW CASE, rollback Path A: off before B2s comes back, and only once' {
        $script:rp = SaRun $false
        # As the move left it: on.
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:sa.calls.Add("an=$Enabled"); $true }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SaCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:sa.calls)
        [array]::IndexOf($calls, 'an=False') | Should -BeLessThan ([array]::IndexOf($calls, 'size:Standard_B2s'))
        @($calls | Where-Object { $_ -eq 'an=False' }).Count | Should -Be 1
        $calls[-1] | Should -Be 'start'
    }

    It 'rollback Path A on a size that carries it: after the size, as before' {
        $script:rp = SaRun $true
        InModuleScope VmMigrationFactory -Parameters @{ c = (SaCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:sa.calls)
        [array]::IndexOf($calls, 'an=False') | Should -BeGreaterThan ([array]::IndexOf($calls, 'size:Standard_B2s'))
    }

    It 'an operator''s restore from the first copy: off before B2s comes back, and only once' {
        $script:rp = SaRun $false
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id; $doc.state = 'MIGRATED'; Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2lds_v5'; controller = '' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_B2s' }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:sa.calls)
        [array]::IndexOf($calls, 'an=False') | Should -BeLessThan ([array]::IndexOf($calls, 'size:Standard_B2s'))
        @($calls | Where-Object { $_ -eq 'an=False' }).Count | Should -Be 1
    }
}
