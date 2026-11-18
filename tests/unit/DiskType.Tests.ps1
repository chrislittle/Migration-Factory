#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# OLD-SKU-1C: upgrade a machine's disks to Premium SSD during the move.
#
# Decided 2026-09-29: the customer picks per machine - keep the disk types, the
# OS disk only, or every disk. A rollback puts the old type back, even
# though Azure then refuses a same-day retry: two type changes per disk a day.
#
# THE TRAP these tests hold: Azure refuses to put a machine on a size that
# takes no Premium SSD (D4_v2) while a Premium SSD disk is attached. So every
# put-back sets the disk types back BEFORE it sets the size back.

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
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:os = "$($script:sub)/Microsoft.Compute/disks/vm1-os"
    $script:d0 = "$($script:sub)/Microsoft.Compute/disks/vm1-data0"
    $script:d1 = "$($script:sub)/Microsoft.Compute/disks/vm1-data1"

    # A D4_v2 machine: a Standard HDD OS disk, a Standard SSD data disk, and a
    # Premium SSD v2 data disk that is never changed.
    function Global:DtCapture {
        [pscustomobject]@{ name = 'vm1'; size = 'Standard_D4_v2'; controller = ''; location = 'centralus'; osType = 'Linux'; zones = @()
            osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Standard_LRS'; managedDiskId = $script:os }
            dataDisks = @(
                [pscustomobject]@{ name = 'vm1-data0'; lun = 0; skuName = 'StandardSSD_LRS'; managedDiskId = $script:d0; caching = 'None'; sizeGB = 64 }
                [pscustomobject]@{ name = 'vm1-data1'; lun = 1; skuName = 'PremiumV2_LRS'; managedDiskId = $script:d1; caching = 'None'; sizeGB = 64 })
            nics = @([pscustomobject]@{ id = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic0"; primary = $true; acceleratedNetworking = $true })
            tags = @{} }
    }
    function Global:DtPlan([string]$Path = 'A', [string]$Upgrade = 'all') {
        $policy = [ordered]@{ safetyCopy = 'pristine' }
        if ($Upgrade) { $policy.diskUpgrade = $Upgrade }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = $Path; wave = 'w1'
            assessment = [pscustomobject]@{ location = 'centralus'; os = 'Linux'; gen = 'V1'; sourceSize = 'Standard_D4_v2' }
            target = [pscustomobject]@{ size = 'Standard_D8ds_v5'; controller = '' }; policy = [pscustomobject]$policy }
    }
    function Global:DtRun([string]$Path = 'A', [object[]]$Changes = @()) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; cap = (DtCapture); ch = $Changes; sub = $script:sub } {
            param($rp, $id, $cap, $ch, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'dt' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'dt' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = $cap }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true }) -Force
            if ($ch.Count) { $doc | Add-Member -NotePropertyName diskTypeChanges -NotePropertyValue @($ch) -Force }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:DtCtx($rp, $plan) {
        Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$plan.vmId) -PlanEntry $plan
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $plan } { param($rp, $plan) New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'dt' }
    }
    function Global:DtDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:DtLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:DtAgo([double]$Hours) { (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('o') }

    # The live disks, and every Azure call in order.
    function Global:DtMockDisks {
        $global:dt = @{ calls = [System.Collections.Generic.List[string]]::new()
            sku = @{ $script:os = 'Standard_LRS'; $script:d0 = 'StandardSSD_LRS'; $script:d1 = 'PremiumV2_LRS' }; shares = @{} }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku {
            @{ SkuName = $global:dt.sku[$DiskId]; MaxShares = $(if ($global:dt.shares[$DiskId]) { $global:dt.shares[$DiskId] } else { 1 }); ProvisioningState = 'Succeeded' }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku {
            $global:dt.calls.Add("sku:$(($DiskId -split '/')[-1])=$SkuName"); $global:dt.sku[$DiskId] = $SkuName; $true
        }
    }
}
AfterAll { Remove-Item function:DtCapture, function:DtPlan, function:DtRun, function:DtCtx, function:DtDoc, function:DtLog, function:DtAgo, function:DtMockDisks -ErrorAction SilentlyContinue }

Describe 'OLD-SKU-1C: which disks change, to what' {
    It 'every Standard type goes to Premium SSD, keeping zone redundancy' {
        InModuleScope VmMigrationFactory {
            Get-VmfPremiumDiskSku 'Standard_LRS' | Should -Be 'Premium_LRS'
            Get-VmfPremiumDiskSku 'StandardSSD_LRS' | Should -Be 'Premium_LRS'
            Get-VmfPremiumDiskSku 'StandardSSD_ZRS' | Should -Be 'Premium_ZRS'
        }
    }

    It 'Premium SSD is left, and so are Premium SSD v2, Ultra Disk and anything unknown' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'UltraSSD_LRS', '', 'Something_New') {
                Get-VmfPremiumDiskSku $s | Should -BeNullOrEmpty -Because $s
            }
        }
    }

    It 'os: the OS disk only; all: every disk that can change; none chosen: nothing' {
        $os = InModuleScope VmMigrationFactory -Parameters @{ c = (DtCapture) } { param($c) @(Get-VmfDiskTypeUpgradePlan -Capture $c -Upgrade 'os') }
        @($os.name) | Should -Be @('vm1-os')
        $all = InModuleScope VmMigrationFactory -Parameters @{ c = (DtCapture) } { param($c) @(Get-VmfDiskTypeUpgradePlan -Capture $c -Upgrade 'all') }
        @($all.name) | Should -Be @('vm1-os', 'vm1-data0') -Because 'the Premium SSD v2 disk is never changed'
        ($all | Where-Object name -EQ 'vm1-data0').to | Should -Be 'Premium_LRS'
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCapture) } { param($c) @(Get-VmfDiskTypeUpgradePlan -Capture $c -Upgrade '') } |
            Should -BeNullOrEmpty
    }
}

Describe 'OLD-SKU-1C: two type changes per disk a day' {
    It 'a move needs room for two - its change and the rollback''s: two recent changes wait until the later is 24 hours old' {
        $doc = [pscustomobject]@{ diskTypeChanges = @(
                [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 5) }
                [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = (DtAgo 3) }) }
        $r = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; ids = @($script:os) } { param($d, $ids) Get-VmfDiskTypeChangeRefusal -Doc $d -DiskIds $ids }
        $r.disk | Should -Be $script:os
        ($r.retryAfterUtc - (Get-Date).ToUniversalTime()).TotalHours | Should -BeGreaterThan 20.9
        ($r.retryAfterUtc - (Get-Date).ToUniversalTime()).TotalHours | Should -BeLessThan 21.1
    }

    It 'ONE recent change is already too many: the rollback would need the third' {
        $doc = [pscustomobject]@{ diskTypeChanges = @(
                [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 30) }
                [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = (DtAgo 3) }) }
        $r = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; ids = @($script:os) } { param($d, $ids) Get-VmfDiskTypeChangeRefusal -Doc $d -DiskIds $ids }
        ($r.retryAfterUtc - (Get-Date).ToUniversalTime()).TotalHours | Should -BeGreaterThan 20.9
    }

    It 'changes older than 24 hours, or on another disk: allowed' {
        $doc = [pscustomobject]@{ diskTypeChanges = @(
                [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 30) }
                [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = (DtAgo 25) }
                [pscustomobject]@{ diskId = $script:d1; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 2) }) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; ids = @($script:os, $script:d0) } { param($d, $ids) Get-VmfDiskTypeChangeRefusal -Doc $d -DiskIds $ids } |
            Should -BeNullOrEmpty
    }
}

Describe 'OLD-SKU-1C: the checks before the machine is touched' {
    BeforeEach {
        $script:premium = 'True'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            $caps = @([pscustomobject]@{ Name = 'vCPUs'; Value = '8' })
            if ($null -ne $script:premium) { $caps += [pscustomobject]@{ Name = 'PremiumIO'; Value = $script:premium } }
            @([pscustomobject]@{ Name = 'Standard_D8ds_v5'; Capabilities = $caps })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a target size that takes Premium SSD, and no recent change: go on' {
        $script:rp = DtRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan)); cap = (DtCapture); p = (DtPlan) } {
            param($c, $cap, $p) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $p -Capture $cap
        } | Should -BeNullOrEmpty
    }

    It 'a target size that takes no Premium SSD stops the machine untouched, and says so' {
        $script:rp = DtRun; $script:premium = 'False'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan)); cap = (DtCapture); p = (DtPlan) } {
            param($c, $cap, $p) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $p -Capture $cap
        }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'premiumDisksNotSupported'
        $r.Detail | Should -Match 'Standard_D8ds_v5 does not take Premium SSD'
    }

    It 'a catalog that does not say is not a yes' {
        $script:rp = DtRun; $script:premium = $null
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan)); cap = (DtCapture); p = (DtPlan) } {
            param($c, $cap, $p) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $p -Capture $cap
        }
        $r.Reason | Should -Be 'premiumDisksNotSupported'
        $r.Detail | Should -Match 'does not say'
    }

    It 'THE REPORTED CASE: a same-day retry after a restore set the type back is refused, with the time' {
        $script:rp = DtRun -Changes @(
            [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 4) }
            [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = (DtAgo 1) })
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan)); cap = (DtCapture); p = (DtPlan) } {
            param($c, $cap, $p) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $p -Capture $cap
        }
        $r.Reason | Should -Be 'diskTypeChangeLimit'
        $r.Detail | Should -Match "The disk 'vm1-os' had a type change in the last 24 hours\. Select Try this machine again after \d{4}-\d\d-\d\d \d\d:\d\d UTC\."
        # RESTORE-DIALOG-WORDS-1: "room" is an invented word (QUOTA-NOT-CAPACITY-1).
        $r.Detail | Should -Match ([regex]::Escape('Azure allows two type changes for each disk in 24 hours. A move needs both of them: its own change, and the change back if the move fails.'))
        $r.Detail | Should -Not -Match '(?i)\broom\b'
    }

    It 'nothing chosen: no check, no catalog read' {
        $script:rp = DtRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan -Upgrade '')); cap = (DtCapture); p = (DtPlan -Upgrade '') } {
            param($c, $cap, $p) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $p -Capture $cap
        } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0
    }

    It 'both stop reasons are declared, untouched, with words for the operator' {
        $reasons = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons)
        foreach ($code in 'premiumDisksNotSupported', 'diskTypeChangeLimit') {
            $r = $reasons | Where-Object code -EQ $code
            $r | Should -Not -BeNullOrEmpty -Because $code
            $r.machine | Should -Be 'untouched'
        }
        ($reasons | Where-Object code -EQ 'diskTypeChangeLimit').retry | Should -Be 'whenAvailable'
    }
}

Describe 'OLD-SKU-1C: the change, while the machine is stopped' {
    BeforeEach {
        DtMockDisks
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:dt.calls.Add('controller') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:dt.calls.Add('resize') }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable dt -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: after the resize - a Premium SSD disk needs a size that takes one - and each change recorded first' {
        $script:rp = DtRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        $calls = @($global:dt.calls)
        $calls | Should -Be @('resize', 'sku:vm1-os=Premium_LRS', 'sku:vm1-data0=Premium_LRS')
        $rec = @((DtDoc $script:rp).diskTypeChanges)
        @($rec.diskId) | Should -Be @($script:os, $script:d0)
        @($rec.by | Sort-Object -Unique) | Should -Be @('move')
        (DtDoc $script:rp).schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'KILL-RESUME: killed after the record and before Azure changed it - changed, and recorded once' {
        $script:rp = DtRun 'A' -Changes @([pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 0.1) })
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A' 'os')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:dt.calls) | Should -Contain 'sku:vm1-os=Premium_LRS'
        @((DtDoc $script:rp).diskTypeChanges).Count | Should -Be 1
    }

    It 'a shared disk keeps its type, and the record says why' {
        $script:rp = DtRun
        $global:dt.shares[$script:d0] = 2
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:dt.calls) | Should -Not -Contain 'sku:vm1-data0=Premium_LRS'
        DtLog $script:rp | Should -Match "The disk 'vm1-data0' keeps the type Standard SSD\. It is a shared disk"
    }

    It 'keep: nothing is read or changed' {
        $script:rp = DtRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A' '')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:dt.calls) | Should -Be @('resize')
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskSku -Times 0
    }
}

Describe 'OLD-SKU-1C: every put-back sets the types back before the size' {
    BeforeEach {
        DtMockDisks
        # As the move left them.
        $global:dt.sku[$script:os] = 'Premium_LRS'; $global:dt.sku[$script:d0] = 'Premium_LRS'
        $script:moved = @(
            [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 1) }
            [pscustomobject]@{ diskId = $script:d0; from = 'StandardSSD_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 1) })
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:dt.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:dt.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:dt.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = $script:os; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = '' } }
        # RESTORE-ALL-1: the data disks the move changed are on the machine now,
        # and the restore makes them again from their copies too.
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = $script:d0; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' },
              [pscustomobject]@{ lun = 1; id = $script:d1; name = 'vm1-data1'; resourceGroup = 'rg-app'; skuName = 'PremiumV2_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:dt.calls.Add('datadisks'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:dt.calls.Add("newDisk:$SkuName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:dt.calls.Add('osdisk') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true; Reason = '' } }
        $script:originalPremium = 'False'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D4_v2'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = $script:originalPremium }) })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable dt -Scope Global -ErrorAction SilentlyContinue }

    It 'THE TRAP, Path A: both disks go back to their types, then the size, then the copy on the recorded type' {
        $script:rp = DtRun 'A' -Changes $script:moved
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:dt.calls)
        $size = [array]::IndexOf($calls, 'size:Standard_D4_v2')
        [array]::IndexOf($calls, 'sku:vm1-os=Standard_LRS') | Should -BeLessThan $size
        [array]::IndexOf($calls, 'sku:vm1-data0=StandardSSD_LRS') | Should -BeLessThan $size
        $calls | Should -Contain 'newDisk:Standard_LRS' -Because 'the OS disk comes back from its copy on the type the capture recorded, not the Premium SSD the move left'
        $calls | Should -Not -Contain 'newDisk:Premium_LRS'
        @((DtDoc $script:rp).diskTypeChanges | Where-Object by -EQ 'rollback').Count | Should -Be 2
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'a disk already set back (a restore) is not changed again - that would be a third change' {
        $script:rp = DtRun 'A' -Changes @($script:moved[0],
            [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = (DtAgo 0.5) })
        $global:dt.sku[$script:os] = 'Standard_LRS'
        $n = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; ids = @($script:os) } {
            param($rp, $id, $ids) Restore-VmfCapturedDiskTypes -RunPath $rp -VmId $id -DiskIds $ids -Kind 'rollback'
        }
        $n | Should -Be 0
        @($global:dt.calls | Where-Object { $_ -like 'sku:*' }).Count | Should -Be 0
    }

    It 'a disk the move did not change is not touched' {
        $script:rp = DtRun 'A' -Changes @($script:moved[0])
        $global:dt.sku[$script:d0] = 'StandardSSD_LRS'
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        @($global:dt.calls | Where-Object { $_ -like 'sku:vm1-data0*' }).Count | Should -Be 0
    }

    It 'REVIEW: a type Azure will not set back, on an old size that takes no Premium SSD, stops by name before the size - Azure would refuse it' {
        $script:rp = DtRun 'A' -Changes $script:moved
        $script:originalPremium = 'False'
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { throw 'OperationNotAllowed' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw '*2 disks of this machine keep Premium SSD*Standard_D4_v2 takes no Premium SSD*stopped, on its new size*'
        @($global:dt.calls) | Should -Not -Contain 'size:Standard_D4_v2'
        $global:dt.calls | Should -Not -Contain 'start'
        DtLog $script:rp | Should -Match "The disk 'vm1-os' keeps the type Premium SSD\. Azure did not set Standard HDD back: OperationNotAllowed"
    }

    It 'the same on an old size that takes Premium SSD: said, and the rollback finishes' {
        $script:rp = DtRun 'A' -Changes $script:moved
        $script:originalPremium = 'True'
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { throw 'OperationNotAllowed' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        $global:dt.calls | Should -Contain 'start'
        DtLog $script:rp | Should -Match 'except the type of 2 disk'
    }

    It 'REVIEW: a set-back that failed is tried again by the next put-back - its record does not hide the disk' {
        $script:rp = DtRun 'A' -Changes @($script:moved[0],
            [pscustomobject]@{ diskId = $script:os; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'rollback'; utc = (DtAgo 0.5) })
        $n = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; ids = @($script:os) } {
            param($rp, $id, $ids) Restore-VmfCapturedDiskTypes -RunPath $rp -VmId $id -DiskIds $ids -Kind 'restore'
        }
        $n | Should -Be 0
        @($global:dt.calls) | Should -Contain 'sku:vm1-os=Standard_LRS'
    }

    It 'RESTORE-WARN-ENDS-1: a type Azure will not set back is info in a restore, warn in a rollback' {
        # The run page reads a 'restore' warn as the end of the restore, so a
        # line in the middle of one must not be a warn.
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { throw 'OperationNotAllowed' }
        foreach ($case in @(@{ kind = 'restore'; outcome = 'info' }, @{ kind = 'rollback'; outcome = 'warn' })) {
            $script:rp = DtRun 'A' -Changes $script:moved
            $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; ids = @($script:os); k = $case.kind } {
                param($rp, $id, $ids, $k)
                $null = Restore-VmfCapturedDiskTypes -RunPath $rp -VmId $id -DiskIds $ids -Kind $k
                @(Read-VmfEvents -RunPath $rp)
            }
            $line = @($events | Where-Object { [string]$_.detail -match 'keeps the type Premium SSD\.' })
            $line.Count | Should -Be 1 -Because "the $($case.kind) says the disk that did not go back"
            $line[0].step | Should -Be $case.kind
            $line[0].outcome | Should -Be $case.outcome
            Remove-Item $script:rp -Recurse -Force
        }
    }

    It 'a lost lease stops the rollback' {
        $script:rp = DtRun 'A' -Changes $script:moved
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { throw 'lease lost - abandon this VM' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (DtCtx $script:rp (DtPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
    }
}

Describe 'OLD-SKU-1C: a person''s restore from the first copy' {
    BeforeEach {
        DtMockDisks
        $global:dt.sku[$script:os] = 'Premium_LRS'; $global:dt.sku[$script:d0] = 'Premium_LRS'
        $script:rp = DtRun 'A' -Changes @(
            [pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 1) }
            [pscustomobject]@{ diskId = $script:d0; from = 'StandardSSD_LRS'; to = 'Premium_LRS'; by = 'move'; utc = (DtAgo 1) })
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id; $doc.state = 'MIGRATED'; Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D8ds_v5'; controller = '' }; path = 'A'
                        policy = [ordered]@{ diskUpgrade = 'all' } }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = $script:os; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = '' } }
        # RESTORE-ALL-1: the data disks the move changed are on the machine now,
        # and the restore makes them again from their copies too.
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = $script:d0; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' },
              [pscustomobject]@{ lun = 1; id = $script:d1; name = 'vm1-data1'; resourceGroup = 'rg-app'; skuName = 'PremiumV2_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:dt.calls.Add('datadisks'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:dt.calls.Add("newDisk:$SkuName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:dt.calls.Add('osdisk') }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:dt.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:dt.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D4_v2' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:dt.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable dt -Scope Global -ErrorAction SilentlyContinue }

    It 'the types go back before the size, and the OS disk comes back on its recorded type' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:dt.calls)
        $size = [array]::IndexOf($calls, 'size:Standard_D4_v2')
        [array]::IndexOf($calls, 'sku:vm1-data0=StandardSSD_LRS') | Should -BeLessThan $size
        [array]::IndexOf($calls, 'sku:vm1-os=Standard_LRS') | Should -BeLessThan $size
        $calls | Should -Contain 'newDisk:Standard_LRS'
        @((DtDoc $script:rp).diskTypeChanges | Where-Object by -EQ 'restore').Count | Should -Be 2
    }

    It 'the second copy keeps the new setup, disk types included' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:dt.calls | Where-Object { $_ -like 'sku:*' }).Count | Should -Be 0
        $global:dt.calls | Should -Contain 'newDisk:Premium_LRS'
    }
}

Describe 'TYPECHANGE-CHECK-1: the check sees the capture PRECHECK really makes' {
    # FOUND IN THE LAB, 2026-09-30: a person's retry changed a data disk's type
    # a third time in 24 hours. PRECHECK passes the capture straight from
    # Get-VmfVmCapture - ordered hashtables - and the disk plan asked
    # PSObject.Properties['skuName'], which a hashtable does not have. So the
    # plan was empty, and both PRECHECK checks were skipped on every real move.
    # CONVERTING reads the capture back from the state document, where it is an
    # object, so the change itself was made. Every earlier test built the
    # capture as an object, the shape PRECHECK never passes.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # The machine as Get-AzVM returns it after the rollback: a new OS disk
        # made from its copy, the same data disk - with its resource group in
        # other letter case, as Azure sometimes returns it.
        function Global:DtAzVm {
            $d0Upper = $script:d0 -replace '/resourceGroups/rg-app/', '/resourceGroups/RG-APP/'
            [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4_v2' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = $null
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os-a2'; DeleteOption = 'Detach'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os-a2"; StorageAccountType = 'Standard_LRS' } }
                    DataDisks = @(
                        [pscustomobject]@{ Name = 'vm1-data0'; Lun = 0; Caching = 'None'; DiskSizeGB = 64; DeleteOption = 'Detach'
                            ManagedDisk = [pscustomobject]@{ Id = $d0Upper; StorageAccountType = [string]$global:dt.sku[$script:d0] } }
                        [pscustomobject]@{ Name = 'vm1-data1'; Lun = 1; Caching = 'None'; DiskSizeGB = 64; DeleteOption = 'Detach'
                            ManagedDisk = [pscustomobject]@{ Id = $script:d1; StorageAccountType = 'PremiumV2_LRS' } })
                    ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic0"; Primary = $true }) }
                Zones = @(); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        # The plan entry as PRECHECK reads it, with every assessment field its
        # earlier gates ask.
        function Global:DtPrecheckPlan {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = 'A'; wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; location = 'centralus'; os = 'Linux'; gen = 'V2'
                    sourceSize = 'Standard_D4_v2'; sourceDiskArch = 'scsi-temp'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D8ds_v5'; controller = ''; diskArch = 'scsi-temp' }
                policy = [pscustomobject]@{ safetyCopy = 'pristine'; diskUpgrade = 'all'; targetGeneration = 'v5'; onDDataFound = 'proceed' } }
        }
    }
    AfterAll { Remove-Item function:DtAzVm, function:DtPrecheckPlan -ErrorAction SilentlyContinue }

    BeforeEach {
        DtMockDisks
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        # The move (CONVERTING, Path A).
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:dt.calls.Add("size:$Size") }
        # The rollback: the OS disk comes back from its copy; the data disk has
        # no copy, so it is kept and its type set back (the lab case).
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = $script:os; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = $script:d0; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = $global:dt.sku[$script:d0] },
              [pscustomobject]@{ lun = 1; id = $script:d1; name = 'vm1-data1'; resourceGroup = 'rg-app'; skuName = 'PremiumV2_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true; Reason = '' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        # The retry's PRECHECK: Azure as it stands after the rollback.
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:DtAzVm }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        # SAFETY-ULTRA-1: PRECHECK reads the Premium SSD v2 disk on LUN 1 by its
        # id, and a rollback reads its copy.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'PremiumV2_LRS'; diskSizeGB = 64; diskIOPSReadWrite = 3000; diskMBpsReadWrite = 125; logicalSectorSize = 512; zones = @(); maxShares = 1; completionPercent = 100; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().ToString('o') } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D8ds_v5'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }) },
              [pscustomobject]@{ Name = 'Standard_D4_v2'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'False' }) })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable dt -Scope Global -ErrorAction SilentlyContinue }

    It 'the disk plan reads the type from the capture Get-VmfVmCapture makes, not only from a stored one' {
        $global:dt.sku[$script:d0] = 'StandardSSD_LRS'
        $all = InModuleScope VmMigrationFactory -Parameters @{ vm = (Global:DtAzVm) } {
            param($vm) @(Get-VmfDiskTypeUpgradePlan -Capture (Get-VmfVmCapture -Vm $vm) -Upgrade 'all')
        }
        @($all.name) | Should -Be @('vm1-os-a2', 'vm1-data0')
        @($all.to) | Should -Be @('Premium_LRS', 'Premium_LRS')
    }

    It 'the disk choice reads from a plan entry of either shape' {
        InModuleScope VmMigrationFactory {
            Get-VmfDiskUpgradeValue -PlanEntry @{ policy = @{ diskUpgrade = 'all' } } | Should -Be 'all'
            Get-VmfDiskUpgradeValue -PlanEntry ([pscustomobject]@{ policy = [pscustomobject]@{ diskUpgrade = 'os' } }) | Should -Be 'os'
            Get-VmfDiskUpgradeValue -PlanEntry @{ policy = @{ diskUpgrade = 'everything' } } | Should -Be ''
            Get-VmfDiskUpgradeValue -PlanEntry @{ } | Should -Be ''
        }
    }

    It 'THE LAB CASE: move, rollback, a person''s retry - PRECHECK stops it before the third change, naming the data disk' {
        $script:rp = DtRun 'A'
        $ctx = DtCtx $script:rp (DtPlan 'A')
        InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        $global:dt.sku[$script:d0] | Should -Be 'Premium_LRS' -Because 'the move changed it'
        InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { param($c) Invoke-VmfRollback -Context $c }
        $global:dt.sku[$script:d0] | Should -Be 'StandardSSD_LRS' -Because 'the rollback set the kept data disk back'
        @((DtDoc $script:rp).diskTypeChanges | Where-Object diskId -EQ $script:d0).Count | Should -Be 2

        # A person's retry: a new attempt from PRECHECK, on the real store.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt
        }
        @((DtDoc $script:rp).diskTypeChanges).Count | Should -Be 4 -Because 'a new attempt keeps the record: it is about the count Azure keeps'
        $global:dt.calls.Clear()

        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (Global:DtPrecheckPlan) } {
            param($rp, $p) Invoke-VmfStepPrecheck -Context (New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'dt')
        }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskTypeChangeLimit'
        $r.Detail | Should -Match "The disk 'vm1-data0' had a type change in the last 24 hours\."
        @($global:dt.calls | Where-Object { $_ -like 'sku:*' }).Count | Should -Be 0 -Because 'nothing is changed'
    }

    It 'PRECHECK also asks the size: a target that takes no Premium SSD stops a real capture' {
        $script:rp = DtRun 'A'
        $global:dt.sku[$script:d0] = 'StandardSSD_LRS'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D8ds_v5'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'False' }) })
        }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (Global:DtPrecheckPlan) } {
            param($rp, $p) Invoke-VmfStepPrecheck -Context (New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'dt')
        }
        $r.Reason | Should -Be 'premiumDisksNotSupported'
    }

    It 'a machine with no recent change and a size that takes Premium SSD goes on' {
        $script:rp = DtRun 'A'
        $global:dt.sku[$script:d0] = 'StandardSSD_LRS'
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (Global:DtPrecheckPlan) } {
            param($rp, $p) Invoke-VmfStepPrecheck -Context (New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'dt')
        }
        $r.Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'a stored time reads as the same instant, whatever shape the store gives it' {
        $at = [datetime]::SpecifyKind([datetime]'2026-09-30T14:48:27', 'Utc')
        $now = $at.AddHours(2)
        foreach ($utc in @($at.ToString('o'), $at, $at.ToLocalTime(), [datetimeoffset]$at)) {
            $doc = [pscustomobject]@{ diskTypeChanges = @([pscustomobject]@{ diskId = $script:d0; by = 'rollback'; utc = $utc }) }
            $r = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; ids = @($script:d0); n = $now } { param($d, $ids, $n) Get-VmfDiskTypeChangeRefusal -Doc $d -DiskIds $ids -NowUtc $n }
            $r.retryAfterUtc | Should -Be $at.AddHours(24) -Because "the time was given as $($utc.GetType().Name) $utc"
        }
    }
}

Describe 'OLD-SKU-1C: a resume finishes with the disk choice it started with' {
    It 'a disk choice changed after the machine started is named, and the started one is used' {
        $started = InModuleScope VmMigrationFactory -Parameters @{ p = (DtPlan 'A' 'all') } { param($p) Get-VmfStartedTarget -PlanEntry $p }
        $started.diskUpgrade | Should -Be 'all'
        $now = DtPlan 'A' ''
        $r = InModuleScope VmMigrationFactory -Parameters @{ p = $now; s = ([pscustomobject]$started) } { param($p, $s) Resolve-VmfStartedTarget -PlanEntry $p -Started $s }
        $r.Entry.policy.diskUpgrade | Should -Be 'all'
        ($r.Changed -join ' ') | Should -Match 'the disks: no change to the disks now, where it started with Premium SSD for every disk'
    }
}

Describe 'OLD-SKU-1C: the words' {
    It 'the run page has words for each disk type step' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        foreach ($k in 'setDiskType', 'setDiskTypeBack', 'readDiskType') { $page | Should -Match "$($k):\s*'[^']{10,}'" -Because $k }
    }

    It 'the role map lists the disk type change by resource id' {
        $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $op = @($rbac.operations) | Where-Object { $_.cmdlet -eq 'Invoke-AzRestMethod' -and $_.why -like 'OLD-SKU-1C*' }
        @($op.actions) | Should -Contain 'Microsoft.Compute/disks/write'
    }
}

Describe 'OLD-SKU-1C: a machine update never sends a disk type' {
    It 'the OS disk''s and every data disk''s storage type are cleared, with the IOPS scrub' {
        $vm = [pscustomobject]@{ StorageProfile = [pscustomobject]@{
                OsDisk = [pscustomobject]@{ ManagedDisk = [pscustomobject]@{ Id = 'os'; StorageAccountType = 'Standard_LRS' } }
                DataDisks = @([pscustomobject]@{ Lun = 0; DiskIOPSReadWrite = 3000; DiskMBpsReadWrite = 125
                        ManagedDisk = [pscustomobject]@{ Id = 'd0'; StorageAccountType = 'StandardSSD_LRS' } }) } }
        $out = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Clear-VmfDiskPerfProperties -Vm $v }
        $out.StorageProfile.OsDisk.ManagedDisk.StorageAccountType | Should -BeNullOrEmpty
        $out.StorageProfile.DataDisks[0].ManagedDisk.StorageAccountType | Should -BeNullOrEmpty
        $out.StorageProfile.DataDisks[0].DiskIOPSReadWrite | Should -BeNullOrEmpty
        $out.StorageProfile.OsDisk.ManagedDisk.Id | Should -Be 'os'
    }

    It 'every function that updates a machine scrubs it first' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        $src += Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1') -Raw
        $updates = [regex]::Matches($src, '(?m)^.*Update-AzVM -ResourceGroupName.*$').Count
        $scrubs = [regex]::Matches($src, '(?m)^\s*\$vm = Clear-VmfDiskPerfProperties -Vm \$vm').Count
        $updates | Should -BeGreaterThan 3
        $scrubs | Should -Be $updates -Because 'one scrub before each update'
    }
}
