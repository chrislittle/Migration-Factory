#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RESTORE-END-JOB-1: a restore whose job stops resumes from its
# last checkpoint, the way a wave does.
#
# A job the platform stops - out of memory, the job's time limit, a restart -
# writes nothing more. The restore's job runs once (replicaRetryLimit 0), and
# nothing started it again: the machine could be left stopped part way, or with
# no definition in Azure, and the Migrations page said "Restoring" for ever.
# Decided 2026-10-19 and 2026-10-24: it resumes, as a wave does.
#
# THE KILL HARNESS. A real kill runs no catch and no finally. So a test kill
# copies the run store and the fake Azure AT THE INSTANT the process dies (a
# chosen call, before or after Azure did it), lets the job unwind, then puts
# that copy back - what a new container finds - and resumes. Every place the
# uninterrupted run calls Azure is a kill point, before and after the call, so
# every step of every path has its kill-resume test (rule 4), the window
# between deleting a rebuilt machine's definition and creating it again among
# them. Each resume must end exactly where the uninterrupted run ended, and
# make no second set of disks.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:nicId = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic"
    function Global:RjDiskId([string]$Name) { "$($script:sub)/Microsoft.Compute/disks/$Name" }

    # A Windows machine with two captured data disks and one somebody attached
    # after the move (LUN 5), which every restore leaves as it is.
    # RESTORE-EMPTY-LUN-1: -OneDisk keeps LUN 0 only. The capture says LUN 0
    # has ReadOnly caching; the machine has ReadWrite on it now (RjAzure), so a
    # LUN that gets its caching from the capture, not from the LUN as the
    # checkpoint read it, ends on another machine than the uninterrupted run.
    function Global:RjDoc {
        param([string]$Path = 'A', [string]$State = 'MIGRATED', [switch]$PutBack, [switch]$OneDisk)
        $doc = [pscustomobject]@{
            captured = [pscustomobject]@{
                startedTarget = [pscustomobject]@{ path = $Path; size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                vmConfig = [pscustomobject]@{
                    vmId = $script:vmId; name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Windows'
                    osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = (RjDiskId 'vm1-os'); deleteOption = 'Detach' }
                    dataDisks = @(
                        [pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'Premium_LRS'; caching = 'ReadOnly'; managedDiskId = (RjDiskId 'vm1-d0'); deleteOption = 'Detach' },
                        [pscustomobject]@{ lun = 1; name = 'vm1-d1'; skuName = 'Premium_LRS'; caching = 'None'; managedDiskId = (RjDiskId 'vm1-d1'); deleteOption = 'Detach' })
                    nics = @([pscustomobject]@{ id = $script:nicId; primary = $true; acceleratedNetworking = $false })
                    tags = @{} } }
            safety = [pscustomobject]@{
                snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-prepared"
                pristineSnapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine"
                cloneVmId = $null; locksAllowed = $true; pristineSnapshotLocked = $true
                pristineDataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = (RjDiskId 'vm1-d0'); snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/pristine-d0"; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = (RjDiskId 'vm1-d1'); snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/pristine-d1"; locked = $true })
                dataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = (RjDiskId 'vm1-d0'); snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/prepared-d0"; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = (RjDiskId 'vm1-d1'); snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/prepared-d1"; locked = $true })
            }
            state = $State
        }
        if ($PutBack) {
            # ROLLBACK-DISKS-FIRST-1: the rollback disks before the move.
            $mk = { param($lun, $name, $base, $snap) [pscustomobject]@{ lun = $lun; name = $base; diskId = (RjDiskId $name); diskName = $name; snapshotId = $snap
                    skuName = 'Premium_LRS'; instantAccess = $false; madeUtc = '2026-10-01T00:00:00Z'; usedUtc = $null; deletedUtc = $null } }
            $doc.safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{
                    stamp = '202610010000'; pristineSnapshotId = $doc.safety.pristineSnapshotId; zone = $null; complete = $true; kept = @()
                    disks = @((& $mk $null 'vm1-os-asitwas-202610010000' 'vm1-os' $doc.safety.pristineSnapshotId),
                              (& $mk 0 'vm1-d0-d0-asitwas-202610010000' 'vm1-d0' "$($script:sub)/Microsoft.Compute/snapshots/pristine-d0"),
                              (& $mk 1 'vm1-d1-d1-asitwas-202610010000' 'vm1-d1' "$($script:sub)/Microsoft.Compute/snapshots/pristine-d1")) }) -Force
        }
        if ($OneDisk) {
            $doc.captured.vmConfig.dataDisks = @($doc.captured.vmConfig.dataDisks | Where-Object { [int]$_.lun -eq 0 })
            $doc.safety.pristineDataCopies = @($doc.safety.pristineDataCopies | Where-Object { [int]$_.lun -eq 0 })
            $doc.safety.dataCopies = @($doc.safety.dataCopies | Where-Object { [int]$_.lun -eq 0 })
            if ($PutBack) { $doc.safety.rollbackDisksBeforeMove.disks = @($doc.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -eq $_.lun -or [int]$_.lun -eq 0 }) }
        }
        $doc
    }

    function Global:RjRun {
        param($Doc = (RjDoc))
        $null = Complete-VmfTestCapture $Doc
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rj-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; d = $Doc } {
            param($rp, $id, $d)
            Initialize-VmfRun -RunPath $rp -RunId 'rj' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rj' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            foreach ($f in 'captured', 'safety') { $doc | Add-Member -NotePropertyName $f -NotePropertyValue $d.$f -Force }
            $doc.state = $d.state
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }

    # The fake Azure: one machine and the disks of one resource group, kept as
    # state, so a resume meets what the killed job left.
    function Global:RjAzure {
        param([switch]$NoMachine, [switch]$PutBack, [switch]$OneDisk)
        $disks = @{}
        foreach ($n in 'vm1-os', 'vm1-d0', 'vm1-d1', 'added-later') { $disks[(RjDiskId $n)] = @{ name = $n; source = ''; sku = 'Premium_LRS' } }
        if ($PutBack) {
            $disks[(RjDiskId 'vm1-os-asitwas-202610010000')] = @{ name = 'vm1-os-asitwas-202610010000'; source = "$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine"; sku = 'Premium_LRS' }
            $disks[(RjDiskId 'vm1-d0-d0-asitwas-202610010000')] = @{ name = 'vm1-d0-d0-asitwas-202610010000'; source = "$($script:sub)/Microsoft.Compute/snapshots/pristine-d0"; sku = 'Premium_LRS' }
            $disks[(RjDiskId 'vm1-d1-d1-asitwas-202610010000')] = @{ name = 'vm1-d1-d1-asitwas-202610010000'; source = "$($script:sub)/Microsoft.Compute/snapshots/pristine-d1"; sku = 'Premium_LRS' }
        }
        $global:fa = @{
            vm = @{ exists = (-not $NoMachine); size = 'Standard_D2ds_v6'; controller = 'NVMe'; power = $(if ($NoMachine) { 'none' } else { 'running' })
                    os = (RjDiskId 'vm1-os'); data = @{ '0' = (RjDiskId 'vm1-d0'); '1' = (RjDiskId 'vm1-d1'); '5' = (RjDiskId 'added-later') }
                    caching = @{ '0' = 'ReadWrite'; '1' = 'None'; '5' = 'None' } }
            disks = $disks; nic = $true; creates = 0
            sites = [System.Collections.Generic.List[string]]::new(); reads = [System.Collections.Generic.List[string]]::new(); seen = @{}
            killAt = $null; dead = $false; snap = $null; rp = $null
            refuseLun = -1; failDataReadOnce = $false
            # RESTORE-EMPTY-LUN-1: which attaches to an empty LUN Azure refuses
            # ('made': a disk made from a copy; 'all'), each attach as LUN:name/caching,
            # and the disks attached to another machine.
            refuseEmpty = ''; attaches = [System.Collections.Generic.List[string]]::new(); elsewhere = @()
            # RESTORE-ORIGINAL-DELETE-RESTART-1: the disk names (wildcards)
            # whose delete Azure refuses, and whether it refuses to put the
            # machine's own OS disk back on it.
            refuseDelete = @(); refuseOsBack = $false
        }
        if ($OneDisk) { $global:fa.vm.data.Remove('1'); $global:fa.vm.caching.Remove('1') }
    }
    function Global:RjClone($o) { $o | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable }
    # The instant the process dies, or a call that goes on.
    function Global:RjKill([string]$Site) {
        $fa = $global:fa
        if ($fa.dead) { throw 'VMF-TEST-KILLED: the process is gone' }
        $fa.sites.Add($Site)
        $n = 1 + [int]$fa.seen[$Site]
        $fa.seen[$Site] = $n
        if ($fa.killAt -and $fa.killAt.site -eq $Site -and $fa.killAt.n -eq $n) {
            Copy-Item -LiteralPath $fa.rp -Destination "$($fa.rp).snap" -Recurse
            $fa.snap = @{ vm = (RjClone $fa.vm); disks = (RjClone $fa.disks); creates = $fa.creates; nic = $fa.nic }
            $fa.dead = $true
            throw 'VMF-TEST-KILLED: the process is gone'
        }
    }
    function Global:RjAttachedTo([string]$Id) {
        $vm = $global:fa.vm
        if (@($global:fa.elsewhere) -contains $Id) { return "$($script:sub)/Microsoft.Compute/virtualMachines/other-vm" }
        if ($vm.exists -and ($vm.os -eq $Id -or @($vm.data.Values) -contains $Id)) { $script:vmId } else { '' }
    }

    function Global:RjMocks {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            Global:RjKill 'make:before'
            $id = Global:RjDiskId $DiskName
            $have = $global:fa.disks[$id]
            if ($have) { if ($have.source -and $have.source -ne $SnapshotId) { throw "Disk '$DiskName' exists and was made from '$($have.source)', not from '$SnapshotId'." } }
            else { $global:fa.disks[$id] = @{ name = $DiskName; source = $SnapshotId; sku = $SkuName }; $global:fa.creates++ }
            Global:RjKill 'make:after'
            $id
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            Global:RjKill 'stop:before'
            if (-not $global:fa.vm.exists) { throw 'NotFound: the machine does not exist' }
            $global:fa.vm.power = 'deallocated'
            Global:RjKill 'stop:after'
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            Global:RjKill 'start:before'
            if (-not $global:fa.vm.exists) { throw 'NotFound: the machine does not exist' }
            $global:fa.vm.power = 'running'
            Global:RjKill 'start:after'
        }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk {
            Global:RjKill 'swapOs:before'
            if (-not $global:fa.vm.exists -or $global:fa.vm.power -ne 'deallocated') { throw 'Azure swaps an OS disk only on a stopped machine' }
            if (-not $global:fa.disks[$DiskId]) { throw "NotFound: disk '$DiskName'" }
            if ($global:fa.refuseOsBack -and $DiskId -eq (Global:RjDiskId 'vm1-os')) { throw 'OperationNotAllowed: Azure refused the OS disk swap.' }
            $global:fa.vm.os = $DiskId
            Global:RjKill 'swapOs:after'
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            Global:RjKill 'swapData:before'
            if (-not $global:fa.vm.exists -or $global:fa.vm.power -ne 'deallocated') { throw 'Azure swaps data disks here only on a stopped machine' }
            foreach ($s in $Swaps) { if (-not $global:fa.vm.data["$([int]$s.lun)"]) { throw "Machine 'vm1' has no data disk on LUN $($s.lun) to put a copy back on." } }
            if (@($Swaps | Where-Object { [int]$_.lun -eq $global:fa.refuseLun }).Count) { return @{ Applied = $false; Reason = 'Azure refused the swap' } }
            foreach ($s in $Swaps) { $global:fa.vm.data["$([int]$s.lun)"] = '' }
            # SWAP-2UPD-1: two updates; the job can stop between them.
            Global:RjKill 'swapData:between'
            foreach ($s in $Swaps) { $global:fa.vm.data["$([int]$s.lun)"] = [string]$s.diskId }
            Global:RjKill 'swapData:after'
            @{ Applied = $true }
        }
        # RESTORE-EMPTY-LUN-1: Azure attaches a disk only to a LUN with no disk.
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            Global:RjKill 'attachEmpty:before'
            if (-not $global:fa.vm.exists -or $global:fa.vm.power -ne 'deallocated') { throw 'Azure attaches data disks here only on a stopped machine' }
            $key = "$([int]$Lun)"
            $have = [string]$global:fa.vm.data[$key]
            if ($have) {
                if ($have -eq $DiskId) { return @{ Applied = $true } }
                throw "Machine 'vm1' has the disk '$have' on LUN $Lun. The product attaches a disk only to a LUN that has no disk."
            }
            if (-not $global:fa.disks[$DiskId]) { throw "NotFound: disk '$DiskName'" }
            $made = [bool]$global:fa.disks[$DiskId].source
            $temporary = [string]$global:fa.disks[$DiskId].name -like '*-rtmp-*'
            if ($global:fa.refuseEmpty -eq 'all' -or ($global:fa.refuseEmpty -eq 'made' -and $made) -or ($global:fa.refuseEmpty -eq 'rtmp' -and $temporary)) {
                return @{ Applied = $false; Reason = 'OperationNotAllowed: Azure refused the attach' }
            }
            $global:fa.vm.data[$key] = $DiskId
            $global:fa.vm.caching[$key] = $Caching
            $global:fa.attaches.Add("${key}:$($global:fa.disks[$DiskId].name)/$Caching")
            Global:RjKill 'attachEmpty:after'
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk {
            Global:RjKill 'delete:before'
            $id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/$DiskName"
            # Stricter than Azure: a delete of a disk that is gone is a test
            # failure, so a resume must ask before it deletes again.
            if (-not $global:fa.disks[$id]) { throw "NotFound: the disk '$DiskName' does not exist" }
            if (Global:RjAttachedTo $id) { throw "Azure refuses to delete the attached disk '$DiskName'" }
            if (@($global:fa.refuseDelete | Where-Object { $DiskName -like $_ }).Count) { throw "ScopeLocked: the disk '$DiskName' is locked." }
            $global:fa.disks.Remove($id)
            Global:RjKill 'delete:after'
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            Global:RjKill 'size:before'
            $global:fa.vm.size = $Size; $global:fa.vm.controller = $Controller
            Global:RjKill 'size:after'
        }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking {
            Global:RjKill 'an:before'
            $global:fa.nic = [bool]$Enabled
            Global:RjKill 'an:after'
            $true
        }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku {
            Global:RjKill 'type:before'
            if ($global:fa.disks[$DiskId]) { $global:fa.disks[$DiskId].sku = $SkuName }
            Global:RjKill 'type:after'
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = $(if ($global:fa.disks[$DiskId]) { $global:fa.disks[$DiskId].sku } else { 'Premium_LRS' }); MaxShares = 1 } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            $d = $global:fa.disks[$global:fa.vm.os]
            [pscustomobject]@{ name = $d.name; id = $global:fa.vm.os; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = $global:fa.vm.controller }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            if ($global:fa.failDataReadOnce) { $global:fa.failDataReadOnce = $false; throw 'Azure did not answer the read' }
            @(foreach ($k in @($global:fa.vm.data.Keys | Sort-Object { [int]$_ })) {
                    $id = [string]$global:fa.vm.data[$k]
                    if (-not $id) { continue }
                    [pscustomobject]@{ lun = [int]$k; id = $id; name = $global:fa.disks[$id].name; resourceGroup = 'rg-app'; skuName = 'Premium_LRS'
                        caching = [string]$global:fa.vm.caching[$k]; deleteOption = 'Detach'; writeAcceleratorEnabled = $false }
                })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if (-not $global:fa.disks[$DiskId]) { throw "NotFound: disk '$DiskId'" }; 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $d = $global:fa.disks[$DiskId]
            if (-not $d) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = (Global:RjAttachedTo $DiskId); SourceResourceId = [string]$d.source }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { Global:RjKill 'readSize:before'; if (-not $global:fa.vm.exists) { throw 'NotFound: the machine does not exist' }; $global:fa.vm.size }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { [bool]$global:fa.vm.exists }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:fa.reads.Add('vmConfig'); if (-not $global:fa.vm.exists) { throw 'NotFound: the machine does not exist' }; [pscustomobject]@{ Name = 'vm1' } }
        # REBUILD-PROPS-1: the restore reads the purchase plan of each OS disk it rebuilds around.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ purchasePlan = $null; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapture {
            $vm = $global:fa.vm
            [ordered]@{
                vmId = $script:vmId; name = 'vm1'; size = $vm.size; controller = $vm.controller; location = 'centralus'; osType = 'Windows'
                osDisk = [ordered]@{ name = $global:fa.disks[$vm.os].name; skuName = 'Premium_LRS'; managedDiskId = $vm.os; deleteOption = 'Detach' }
                dataDisks = @(foreach ($k in @($vm.data.Keys | Sort-Object { [int]$_ })) {
                        $id = [string]$vm.data[$k]; if (-not $id) { continue }
                        [ordered]@{ lun = [int]$k; name = $global:fa.disks[$id].name; skuName = 'Premium_LRS'; caching = [string]$vm.caching[$k]; managedDiskId = $id; deleteOption = 'Detach' } })
                nics = @([ordered]@{ id = $script:nicId; primary = $true; acceleratedNetworking = [bool]$global:fa.nic })
                tags = @{ owner = 'app-team' }
            }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
    }

    # What the machine and its disks are at the end - the time in every name
    # read as STAMP, so two runs a minute apart compare.
    function Global:RjState {
        $vm = $global:fa.vm
        $norm = { param($s) ([string]$s) -replace '\d{12}', 'STAMP' }
        [ordered]@{
            exists = [bool]$vm.exists; size = $vm.size; controller = $vm.controller; power = $vm.power
            os = $(if ($vm.exists) { & $norm $global:fa.disks[$vm.os].name } else { '' })
            # RESTORE-EMPTY-LUN-1: and the caching of each LUN.
            data = @(foreach ($k in @($vm.data.Keys | Sort-Object { [int]$_ })) { $id = [string]$vm.data[$k]; "$k=$(if ($id) { & $norm $global:fa.disks[$id].name } else { 'NO DISK' })/$($vm.caching[$k])" }) -join ','
            disks = @($global:fa.disks.Values | ForEach-Object { & $norm $_.name } | Sort-Object) -join ','
            nic = [bool]$global:fa.nic
        } | ConvertTo-Json -Compress
    }
    # What the record says the restore or the rebuild did - every disk name read
    # with STAMP for the time, so two runs a minute apart compare.
    function Global:RjRecordFacts($doc, [string]$Kind) {
        $norm = { param($s) ([string]$s) -replace '\d{12}', 'STAMP' }
        if ($Kind -eq 'rebuild') {
            $r = $doc.recovery
            if (-not $r) { return '(no recovery record)' }
            return ([ordered]@{ source = $r.diskSource; as = $r.rebuiltAs; os = (& $norm $r.osDiskId); size = $r.sizeAfter
                    data = @(@($r.dataDisks) | Where-Object { $_ } | ForEach-Object { "$($_.lun)=$(& $norm $_.diskName)" }) -join ','
                    kept = @(@($r.keptDataDisks) | Where-Object { $_ } | ForEach-Object { [string]$_.lun }) -join ','; state = $doc.state } | ConvertTo-Json -Compress)
        }
        $r = $doc.restore
        if (-not $r) { return '(no restore record)' }
        [ordered]@{ copy = $r.fromCopy; naming = $r.diskNaming; rebuilt = [bool]$r.rebuilt; size = $r.sizeAfter
            previous = (& $norm $r.previousDiskName); new = (& $norm $r.newDiskName); newId = (& $norm $r.newDiskId); changed = [bool]$r.diskIdChanged
            data = @(@($r.dataDisks) | Where-Object { $_ } | ForEach-Object { "$($_.lun):$(& $norm $_.previousDiskName)>$(& $norm $_.newDiskName)" }) -join ','
            kept = @(@($r.dataDisksKept) | Where-Object { $_ } | ForEach-Object { [string]$_.lun }) -join ','
            left = @(@($doc.swapPending.swaps) | Where-Object { $_ } | ForEach-Object { [string]$_.lun }) -join ',' } | ConvertTo-Json -Compress
    }
    function Global:RjRecord($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
    }
    function Global:RjEvents($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }

    # One action, by kind: 'restore' with its options, or 'rebuild'.
    function Global:RjAct {
        param([string]$Rp, [hashtable]$Opt, [switch]$Resume)
        if ($Opt.kind -eq 'rebuild') {
            $a = @{ RunPath = $Rp; VmId = $script:vmId; CorrelationId = 'op-1'; RestoredBy = 'operator@example.com'; Note = 'it does not start'; Confirm = $false }
            if ($Resume) { $a.Resume = $true } else { $a.DiskSource = $Opt.source; $a.As = 'original' }
            return (Restore-VmfVmShell @a)
        }
        $a = @{ RunPath = $Rp; VmId = $script:vmId; CorrelationId = 'op-1'; RestoredBy = 'operator@example.com'; Note = 'it does not start'; Confirm = $false }
        if ($Resume) { $a.Resume = $true }
        else {
            $a.From = $Opt.from; $a.DiskNaming = $Opt.naming
            if ($Opt.naming -eq 'preserve') { $a.AcceptPreserveRisk = $true }
        }
        Restore-VmfVm @a 3>$null
    }

    # The uninterrupted run: where it ends, how many disks it made, and every
    # kill point it passes.
    function Global:RjReference {
        param([hashtable]$Opt)
        RjAzure -NoMachine:([bool]$Opt.noMachine) -PutBack:([bool]$Opt.putBack) -OneDisk:([bool]$Opt.oneDisk)
        if ($null -ne $Opt.refuseLun) { $global:fa.refuseLun = [int]$Opt.refuseLun }
        $rp = RjRun -Doc (RjDoc -Path $Opt.path -State $(if ($Opt.state) { $Opt.state } else { 'MIGRATED' }) -PutBack:([bool]$Opt.putBack) -OneDisk:([bool]$Opt.oneDisk))
        $global:fa.rp = $rp
        $initial = RjState
        try {
            try { $null = RjAct -Rp $rp -Opt $Opt } catch { if ($null -eq $Opt.refuseLun) { throw } }
            $points = [System.Collections.Generic.List[object]]::new()
            $count = @{}
            foreach ($s in $global:fa.sites) { $count[$s] = 1 + [int]$count[$s]; $points.Add([pscustomobject]@{ site = $s; n = $count[$s] }) }
            [pscustomobject]@{ State = (RjState); Initial = $initial; Creates = $global:fa.creates; Points = @($points); Record = (RjRecord $rp) }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Kill at one point, then resume as the service's timer does. Returns what
    # the resume left, and whether the kill happened.
    # What a new container finds after a kill: the store and Azure at the kill.
    function Global:RjRevive([string]$Rp) {
        Remove-Item $Rp -Recurse -Force
        Move-Item -LiteralPath "$Rp.snap" -Destination $Rp
        $global:fa.vm = $global:fa.snap.vm; $global:fa.disks = $global:fa.snap.disks
        $global:fa.creates = $global:fa.snap.creates; $global:fa.nic = $global:fa.snap.nic
        $global:fa.dead = $false; $global:fa.killAt = $null; $global:fa.snap = $null
        $global:fa.sites.Clear(); $global:fa.reads.Clear(); $global:fa.attaches.Clear()
    }
    # RESTORE-EMPTY-LUN-1: -AfterResume runs with the run's path once the
    # resume ended (a second kill, or Finish the restore); what it returns is
    # on After.
    function Global:RjKillAndResume {
        param([hashtable]$Opt, [string]$Site, [int]$N, [scriptblock]$BeforeResume, [scriptblock]$AfterResume)
        RjAzure -NoMachine:([bool]$Opt.noMachine) -PutBack:([bool]$Opt.putBack) -OneDisk:([bool]$Opt.oneDisk)
        if ($null -ne $Opt.refuseLun) { $global:fa.refuseLun = [int]$Opt.refuseLun }
        $rp = RjRun -Doc (RjDoc -Path $Opt.path -State $(if ($Opt.state) { $Opt.state } else { 'MIGRATED' }) -PutBack:([bool]$Opt.putBack) -OneDisk:([bool]$Opt.oneDisk))
        $global:fa.rp = $rp
        $global:fa.killAt = @{ site = $Site; n = $N }
        try {
            try { $null = RjAct -Rp $rp -Opt $Opt } catch { $null = $_ }
            if (-not $global:fa.snap) { return [pscustomobject]@{ Killed = $false } }
            RjRevive $rp
            if ($BeforeResume) { & $BeforeResume }
            # What the new container finds: a checkpoint, or none yet.
            $hadJob = [bool](RjRecord $rp).PSObject.Properties['putBackJob']
            $err = $null
            try { $null = RjAct -Rp $rp -Opt $Opt -Resume } catch { $err = $_.Exception.Message }
            $out = [pscustomobject]@{ Killed = $true; HadJob = $hadJob; State = (RjState); Creates = $global:fa.creates; Error = $err; Record = (RjRecord $rp); Events = @(RjEvents $rp)
                StartedAfter = @($global:fa.sites | Where-Object { $_ -eq 'start:before' }).Count
                SitesAfter = @($global:fa.sites); ReadsAfter = @($global:fa.reads); Attaches = @($global:fa.attaches); After = $null }
            if ($AfterResume) { $out.After = & $AfterResume $rp }
            $out
        }
        finally {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Every kill point of one path. Returns each point that did not end where
    # the uninterrupted run did, in words, so the test names the step.
    function Global:RjEveryKill {
        param([hashtable]$Opt)
        RjMocks
        $ref = RjReference -Opt $Opt
        $bad = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($p in $ref.Points) {
            $r = RjKillAndResume -Opt $Opt -Site $p.site -N $p.n
            $where = "killed at $($p.site) #$($p.n)"
            if (-not $r.Killed) { $bad.Add("${where}: the kill did not happen"); continue }
            $checked++
            if (-not $r.HadJob) {
                # Killed before the checkpoint was written: nothing changed yet,
                # and there is nothing to resume. The resume is refused, and the
                # machine is as it was.
                if ($r.State -ne $ref.Initial) { $bad.Add("${where}: before the checkpoint, the machine changed: $($r.State)") }
                if ($r.Creates) { $bad.Add("${where}: before the checkpoint, $($r.Creates) disks were made") }
                if ($r.Error -notmatch 'There is no') { $bad.Add("${where}: the resume was not refused: $($r.Error)") }
                continue
            }
            # RESTORE-EMPTY-LUN-1: killed between the two updates of a data disk
            # swap (swapData:between) too - the resume attaches the disk the
            # record proves belongs on the empty LUN, and ends where the
            # uninterrupted run ended. It used to stop, with the machine stopped.
            if ($r.Creates -ne $ref.Creates) { $bad.Add("${where}: $($r.Creates) disks made in all, the uninterrupted run made $($ref.Creates)") }
            if ($p.site -eq 'swapData:between' -and -not @($r.SitesAfter | Where-Object { $_ -eq 'attachEmpty:before' }).Count) {
                $bad.Add("${where}: the resume did not attach a disk to the empty LUN")
            }
            if ($r.Error -and $null -eq $Opt.refuseLun) { $bad.Add("${where}: the resume failed: $($r.Error)"); continue }
            if ($r.State -ne $ref.State) { $bad.Add("${where}: ended $($r.State), not $($ref.State)") }
            $recA = Global:RjRecordFacts $ref.Record $Opt.kind
            $recB = Global:RjRecordFacts $r.Record $Opt.kind
            if ($recA -ne $recB) { $bad.Add("${where}: the record says $recB, not $recA") }
            if ($r.Record.PSObject.Properties['putBackJob']) { $bad.Add("${where}: the checkpoint is still on the record") }
            $recName = if ($Opt.kind -eq 'rebuild') { 'recovery' } else { 'restore' }
            if (-not $r.Record.$recName) { $bad.Add("${where}: no $recName record") }
            $step = if ($Opt.kind -eq 'rebuild') { 'recovery' } else { 'restore' }
            if (-not @($r.Events | Where-Object { $_.step -eq $step -and $_.outcome -eq 'info' -and $_.detail -match 'started again after its job stopped' }).Count) {
                $bad.Add("${where}: no line says it started again")
            }
        }
        [pscustomobject]@{ Bad = @($bad); Checked = $checked; Reference = $ref }
    }
}
AfterAll {
    Remove-Item function:RjDiskId, function:RjDoc, function:RjRun, function:RjAzure, function:RjClone, function:RjKill, function:RjAttachedTo,
        function:RjMocks, function:RjState, function:RjRecordFacts, function:RjRecord, function:RjEvents, function:RjAct, function:RjReference, function:RjKillAndResume,
        function:RjEveryKill, function:RjRevive, function:Invoke-AzRestMethod -ErrorAction SilentlyContinue
    Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue
}

Describe 'RESTORE-END-JOB-1: the checkpoint (pure rules)' {
    It 'a step is past only when the record reached it or a later one; no record has reached none' {
        InModuleScope VmMigrationFactory {
            $job = [pscustomobject]@{ kind = 'restore'; phase = 'osSwapped' }
            Test-VmfPutBackJobPast -Job $job -Phase 'stopped' | Should -BeTrue
            Test-VmfPutBackJobPast -Job $job -Phase 'osSwapped' | Should -BeTrue
            Test-VmfPutBackJobPast -Job $job -Phase 'dataSwapped' | Should -BeFalse
            Test-VmfPutBackJobPast -Job $null -Phase 'begun' | Should -BeFalse
        }
    }
    It 'a step this version does not know is refused, never guessed' {
        InModuleScope VmMigrationFactory {
            { Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = 'somethingNew' }) -Phase 'made' } | Should -Throw '*does not know*'
            { Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = 'made' }) -Phase 'nope' } | Should -Throw '*not a step*'
        }
    }
    It 'the steps of each path are in the order they end' {
        InModuleScope VmMigrationFactory {
            $at = { param($p) [array]::IndexOf($script:VmfPutBackJobPhases, $p) }
            foreach ($path in @(
                    @('begun', 'made', 'stopped', 'hardware', 'osOnTemp', 'originalRemoved', 'osSwapped', 'tempRemoved', 'dataSwapped', 'started'),
                    # RESTORE-ORIGINAL-DELETE-RESTART-1: Azure refused the delete
                    # of the original OS disk, and the machine goes back on it.
                    @('begun', 'made', 'stopped', 'hardware', 'osOnTemp', 'originalKept', 'originalBack', 'originalStarted'))) {
                for ($i = 1; $i -lt $path.Count; $i++) { (& $at $path[$i]) | Should -BeGreaterThan (& $at $path[$i - 1]) -Because "$($path[$i]) comes after $($path[$i - 1])" }
            }
            # And no step of the way back is past the delete it replaces: a
            # resume there never goes on to make the disk under the name.
            foreach ($back in 'originalKept', 'originalBack', 'originalStarted') {
                Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = $back }) -Phase 'originalRemoved' | Should -BeFalse -Because $back
                Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = $back }) -Phase 'osOnTemp' | Should -BeTrue -Because $back
            }
        }
    }
    It 'an open restore refuses another job of the machine; its own resume, an ended one and none do not' {
        InModuleScope VmMigrationFactory {
            $open = [pscustomobject]@{ putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; phase = 'stopped' } }
            Get-VmfPutBackJobRefusal -Doc $open -VmName 'vm1' | Should -Match "Restore this machine of 'vm1' did not finish"
            Get-VmfPutBackJobRefusal -Doc $open -VmName 'vm1' -OperationId 'op-2' | Should -Match 'starts it again by itself'
            Get-VmfPutBackJobRefusal -Doc $open -VmName 'vm1' -OperationId 'op-1' | Should -BeNullOrEmpty
            Get-VmfPutBackJobRefusal -Doc $open -VmName 'vm1' -OperationId 'OP-1' | Should -Not -BeNullOrEmpty -Because 'the id is the engine''s own: ordinal'
            $ended = [pscustomobject]@{ putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; phase = 'stopped'; ended = [pscustomobject]@{ outcome = 'fail' } } }
            Get-VmfPutBackJobRefusal -Doc $ended -VmName 'vm1' | Should -BeNullOrEmpty
            Get-VmfPutBackJobRefusal -Doc ([pscustomobject]@{ state = 'MIGRATED' }) -VmName 'vm1' | Should -BeNullOrEmpty
        }
    }
    It 'a checkpoint never moves back, and one that cannot be written throws only when told to' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610240900'
                (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob.phase | Should -Be 'begun'
                Save-VmfPutBackJobStep -Token $t -Phase 'osSwapped' -Data @{ os = [pscustomobject]@{ newId = 'x' } }
                Save-VmfPutBackJobStep -Token $t -Phase 'stopped'
                $j = (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob
                $j.phase | Should -Be 'osSwapped' -Because 'a step that ended stays ended'
                $j.os.newId | Should -Be 'x'
                $gone = [pscustomobject]@{ RunPath = $rp; VmId = ($id + '-not-here'); Job = $t.Job }
                { Save-VmfPutBackJobStep -Token $gone -Phase 'dataSwapped' -MustWrite } | Should -Throw
                { Save-VmfPutBackJobStep -Token $gone -Phase 'dataSwapped' 3>$null } | Should -Not -Throw
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a job that ends without its record is marked ended; one that wrote its record leaves nothing to mark' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610240900'
                Close-VmfPutBackJob -Token $t -Why 'Azure refused'
                $j = (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob
                $j.ended.outcome | Should -Be 'fail'
                $j.ended.why | Should -Be 'Azure refused'
                Test-VmfPutBackJobOpen -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id) | Should -BeFalse
                $t2 = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-2' -Options @{ from = 'pristine' } -Stamp '202610240910'
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                Remove-VmfPutBackJobOnDoc -Doc $doc -Token $t2
                Write-VmfStateDoc -RunPath $rp -Document $doc
                Close-VmfPutBackJob -Token $t2
                (Read-VmfStateDoc -RunPath $rp -VmId $id).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
                # Only its own record: a job never marks or removes another's.
                $t3 = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-3' -Options @{ from = 'pristine' } -Stamp '202610240920'
                Close-VmfPutBackJob -Token $t2
                Test-VmfPutBackJobOpen -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id) | Should -BeTrue
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                Remove-VmfPutBackJobOnDoc -Doc $doc -Token $t2
                $doc.putBackJob.operationId | Should -Be 'op-3'
                $null = $t3
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a resume takes only its own job: another id, another kind, an ended job and none are refused before anything changes' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' } | Should -Throw '*no Restore this machine*'
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610240900'
                (Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1').Job.operationId | Should -Be 'op-1'
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-2' } | Should -Throw
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'rebuild' -OperationId 'op-1' } | Should -Throw
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId '' } | Should -Throw
                Close-VmfPutBackJob -Token $t
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' } | Should -Throw '*ended already*'
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'the service counts a start again and removes a record in one version-checked write, and only for the same job' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610240900'
                Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action resume | Should -BeTrue
                Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action resume | Should -BeTrue
                (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob.resumes | Should -Be 2
                Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-9' -Action remove | Should -BeFalse
                Mock Write-VmfStoreTextIfVersion { $false }
                Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action remove | Should -BeFalse -Because 'somebody wrote the document since it was read'
                (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob | Should -Not -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'an end line is found by the order of the log: the restore''s own end, or the engine''s fail line with its id' {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id)
            $start = [pscustomobject]@{ step = 'restore'; outcome = 'start'; vmId = $id; correlationId = 'op-1' }
            $info = [pscustomobject]@{ step = 'restore'; outcome = 'info'; vmId = $id }
            Test-VmfPutBackEndWritten -Events @($start, $info) -VmId $id -Kind restore -OperationId 'op-1' | Should -BeFalse
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'restore'; outcome = 'warn'; vmId = $id.ToUpper() }) -VmId $id -Kind restore -OperationId 'op-1' | Should -BeTrue
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'engine:restore'; outcome = 'fail'; vmId = $id; correlationId = 'op-1' }) -VmId $id -Kind restore -OperationId 'op-1' | Should -BeTrue
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'engine:restore'; outcome = 'fail'; vmId = $id; correlationId = 'op-2' }) -VmId $id -Kind restore -OperationId 'op-1' | Should -BeFalse
            Test-VmfPutBackEndWritten -Events @([pscustomobject]@{ step = 'restore'; outcome = 'ok'; vmId = $id }, $start) -VmId $id -Kind restore -OperationId 'op-1' | Should -BeFalse -Because 'an end before the start is another restore''s'
            Test-VmfPutBackEndWritten -Events @() -VmId $id -Kind restore -OperationId 'op-1' | Should -BeTrue -Because 'no start line: nothing on the page to end'
        }
    }
}

Describe 'RESTORE-END-JOB-1: a delete a stopped job may have done is asked of Azure first' {
    It 'gone is done; the disk made under the name from the copy is never deleted; an attached disk is refused; the disk the machine had is deleted' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rjd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
        InModuleScope VmMigrationFactory -Parameters @{ t = $tmp } {
            param($t)
            $script:rjTmp = $t
            $script:rjDel = [System.Collections.Generic.List[string]]::new()
            Mock Remove-VmfManagedDisk { $script:rjDel.Add($DiskName) }
            Mock Get-VmfManagedDiskAttachment { $script:rjDiskState }
            $ask = { param($state) $script:rjDiskState = $state
                Remove-VmfDiskForResume -RunPath $script:rjTmp -VmId '/subscriptions/0/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' -DiskId '/d/os' -ResourceGroupName 'rg' -DiskName 'os' -NotFrom '/snap/copy' }
            & $ask ([pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' }) | Should -BeFalse
            & $ask ([pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = '/SNAP/COPY' }) | Should -BeFalse
            { & $ask ([pscustomobject]@{ Exists = $true; ManagedBy = '/vm/other'; SourceResourceId = '' }) } | Should -Throw '*attached*'
            @($script:rjDel).Count | Should -Be 0
            & $ask ([pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = '' }) | Should -BeTrue
            @($script:rjDel) | Should -Be @('os')
        }
        }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Describe 'RESTORE-END-JOB-1: kill-resume at every step of Restore this machine (rule 4)' {
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { } }
    AfterEach { Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }

    It 'in place, the second copy, new names: every kill point resumes to the same machine, with no second set of disks' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $r.Checked | Should -BeGreaterThan 8
        $r.Bad | Should -BeNullOrEmpty
    }
    It 'in place, the first copy (the size and the controller go back), new names: every kill point' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new' }
        $r.Reference.State | Should -Match '"size":"Standard_D2ds_v4"'
        $r.Checked | Should -BeGreaterThan 10
        $r.Bad | Should -BeNullOrEmpty
    }
    It 'in place, keeping the names - every delete is asked before it is done again: every kill point' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' }
        $r.Reference.State | Should -Match '"os":"vm1-os"'
        $r.Checked | Should -BeGreaterThan 20
        $r.Bad | Should -BeNullOrEmpty
    }
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).

    It 'from the first copy with the rollback disks: every kill point, and the resume never makes a disk' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new'; putBack = $true }
        $r.Reference.Creates | Should -Be 0 -Because 'the rollback disks were made before the move'
        $r.Checked | Should -BeGreaterThan 8
        $r.Bad | Should -BeNullOrEmpty
    }
    It 'a data disk swap Azure refuses: every kill point ends with the machine stopped and the swap on record - a resume is never refused by its own swap' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new'; refuseLun = 1 }
        $r.Reference.State | Should -Match '"power":"deallocated"'
        $r.Reference.Record.swapPending | Should -Not -BeNullOrEmpty
        @($r.Reference.Points | Where-Object { $_.site -eq 'readSize:before' -and $_.n -eq 2 }).Count | Should -Be 1 -Because 'the read between the swap record and the restore record is a kill point'
        $r.Bad | Should -BeNullOrEmpty
    }
    It 'a read that fails while the resume reads the data disks keeps the machine stopped, with every data disk on record' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        RjMocks
        # Past the OS disk, so the resume reads the data disks before it swaps any.
        $r = RjKillAndResume -Opt $opt -Site 'swapData:before' -N 1 -BeforeResume { $global:fa.failDataReadOnce = $true }
        $r.Error | Should -Match 'STOPPED'
        $r.StartedAfter | Should -Be 0
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
    }
    It 'the step that saves the disks made before the stop must be written: if it cannot be, the restore stops before it stops the machine' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            Mock -ModuleName VmMigrationFactory Write-VmfStateDoc {
                $j = if ($Document.PSObject.Properties['putBackJob']) { $Document.putBackJob } else { $null }
                if ($j -and [string]$j.phase -eq 'made') { throw 'The store did not answer.' }
                & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $d.vmId) + '.json') -Document $d } $RunPath $Document
            }
            { RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } | Should -Throw '*stopped before it changed the machine*'
            $global:fa.sites | Should -Not -Contain 'stop:before'
            $global:fa.vm.power | Should -Be 'running'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a resume does not ask the retirement date again: the restore passed it when it started' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new' }
        RjMocks
        $ref = RjReference -Opt $opt
        $r = RjKillAndResume -Opt $opt -Site 'stop:after' -N 1 -BeforeResume {
            Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { [pscustomobject]@{ Refuse = $true; Warn = $false; Detail = 'Microsoft retires this size tomorrow.' } }
        }
        $r.Error | Should -BeNullOrEmpty
        $r.State | Should -Be $ref.State
        # The mock refuses a new restore, so it is the resume that skips it.
        RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        try { { RjAct -Rp $rp -Opt $opt } | Should -Throw '*retires this size*' }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    It 'a resume does no step the record says ended: not the size, not the data disks, not the start' {
        RjMocks
        # Killed after the size went back (hardware saved): the size is not set again.
        $r = RjKillAndResume -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new' } -Site 'swapOs:before' -N 1
        $r.Error | Should -BeNullOrEmpty
        $r.SitesAfter | Should -Not -Contain 'size:before'
        # Killed after the start was saved: the machine is not started again.
        $r = RjKillAndResume -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } -Site 'readSize:before' -N 2
        $r.Error | Should -BeNullOrEmpty
        $r.SitesAfter | Should -Not -Contain 'start:before'
        $r.SitesAfter | Should -Not -Contain 'swapData:before'
        # Killed after a refused swap was recorded: Azure is not asked again.
        $r = RjKillAndResume -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new'; refuseLun = 1 } -Site 'readSize:before' -N 2
        $r.Error | Should -Match 'STOPPED'
        $r.SitesAfter | Should -Not -Contain 'swapData:before'
    }
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    # Killed between the two updates of a data disk swap: see the
    # RESTORE-EMPTY-LUN-1 Describe below.
    It 'killed after the OS disk swap: the restore record names the disk the machine had, not the restored one' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        RjMocks
        $r = RjKillAndResume -Opt $opt -Site 'swapOs:after' -N 1
        $r.Error | Should -BeNullOrEmpty
        $r.Record.restore.previousDiskName | Should -Be 'vm1-os'
        $r.Record.restore.newDiskName | Should -Match '^vm1-os-restored-\d{12}$'
    }
    It 'the resume uses what the person asked for from the record - never the call that started it again' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new' }
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            $global:fa.killAt = @{ site = 'stop:after'; n = 1 }
            try { $null = RjAct -Rp $rp -Opt $opt } catch { $null = $_ }
            Remove-Item $rp -Recurse -Force; Move-Item -LiteralPath "$rp.snap" -Destination $rp
            $global:fa.vm = $global:fa.snap.vm; $global:fa.disks = $global:fa.snap.disks; $global:fa.dead = $false; $global:fa.killAt = $null
            # The call says the other copy and the destructive naming: ignored.
            $null = Restore-VmfVm -RunPath $rp -VmId $script:vmId -Resume -CorrelationId 'op-1' -From prepared -DiskNaming preserve -AcceptPreserveRisk -RestoredBy 'resume (watchdog)' -Confirm:$false 3>$null
            $rec = (RjRecord $rp).restore
            $rec.fromCopy | Should -Be 'pristine'
            $rec.diskNaming | Should -Be 'new'
            $rec.restoredBy | Should -Be 'operator@example.com'
            $global:fa.vm.size | Should -Be 'Standard_D2ds_v4'
        }
        finally { Remove-Item $rp, "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a resume with no checkpoint, or of another job, changes nothing' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            { Restore-VmfVm -RunPath $rp -VmId $script:vmId -Resume -CorrelationId 'op-9' -Confirm:$false } | Should -Throw '*no Restore this machine*'
            $global:fa.sites | Should -BeNullOrEmpty -Because 'nothing in Azure was asked or changed'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a resume another job''s hold refuses stays open - it is never marked ended, so the timer asks again' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            $global:fa.killAt = @{ site = 'stop:after'; n = 1 }
            try { $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } catch { $null = $_ }
            Remove-Item $rp -Recurse -Force; Move-Item -LiteralPath "$rp.snap" -Destination $rp
            $global:fa.vm = $global:fa.snap.vm; $global:fa.disks = $global:fa.snap.disks; $global:fa.dead = $false; $global:fa.killAt = $null
            # A wave worker took the machine in between.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $id) -Depth 6 -Document ([ordered]@{
                        vmId = $id; workerId = 'worker-1'; heartbeatUtc = (Get-Date).ToUniversalTime().ToString('o') })
            }
            $global:fa.sites.Clear()
            { Restore-VmfVm -RunPath $rp -VmId $script:vmId -Resume -CorrelationId 'op-1' -Confirm:$false } | Should -Throw '*A wave migrates*'
            $job = (RjRecord $rp).putBackJob
            $job.PSObject.Properties['ended'] | Should -BeNullOrEmpty
            $job.phase | Should -Be 'made' -Because 'killed after the stop and before its step was saved'
            $global:fa.sites | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp, "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a new restore is refused while one has not ended; the refusal changes nothing' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            $global:fa.killAt = @{ site = 'stop:after'; n = 1 }
            try { $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } catch { $null = $_ }
            Remove-Item $rp -Recurse -Force; Move-Item -LiteralPath "$rp.snap" -Destination $rp
            $global:fa.vm = $global:fa.snap.vm; $global:fa.disks = $global:fa.snap.disks; $global:fa.dead = $false; $global:fa.killAt = $null
            $global:fa.sites.Clear()
            { Restore-VmfVm -RunPath $rp -VmId $script:vmId -CorrelationId 'op-2' -Confirm:$false } | Should -Throw '*did not finish*'
            $global:fa.sites | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp, "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'RESTORE-MID-MOVE-1: a resume finishes its own restore, whatever state the record shows - the state refusal is for a new restore only' {
        # A new restore of a machine whose move has not ended is refused. A
        # resume is not new: it finishes what it started, so the machine is
        # never left part way (a stopped machine, or one with no definition).
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        RjMocks
        $r = RjKillAndResume -Opt $opt -Site 'stop:after' -N 1 -BeforeResume {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $global:fa.rp; id = $script:vmId } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $d.state = 'CONVERTING'
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
        }
        $r.Killed | Should -BeTrue
        $r.HadJob | Should -BeTrue
        $r.Error | Should -BeNullOrEmpty
        $r.Record.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'the resume finished the restore'
        $r.Record.restore | Should -Not -BeNullOrEmpty
    }
    It 'a restore that ends with a failure it says marks its checkpoint ended, and is never resumed' {
        RjMocks; RjAzure
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'Azure refused the OS disk swap' }
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            { RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } | Should -Throw
            $job = (RjRecord $rp).putBackJob
            $job.ended.outcome | Should -Be 'fail'
            { Restore-VmfVm -RunPath $rp -VmId $script:vmId -Resume -CorrelationId 'op-1' -Confirm:$false } | Should -Throw '*ended already*'
            # And it no longer refuses a new restore.
            InModuleScope VmMigrationFactory -Parameters @{ d = (RjRecord $rp) } { param($d) Get-VmfPutBackJobRefusal -Doc $d -VmName 'vm1' } | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a restore that finishes leaves no checkpoint: it goes in the same write as the restore record' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' }
            $doc = RjRecord $rp
            $doc.restore.restoredUtc | Should -Not -BeNullOrEmpty
            $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
            $doc.schemaVersion | Should -Be 51
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It '-WhatIf writes no checkpoint' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            Restore-VmfVm -RunPath $rp -VmId $script:vmId -CorrelationId 'op-1' -WhatIf | Out-Null
            (RjRecord $rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'RESTORE-EMPTY-LUN-1: a restore killed between the two updates of a data disk swap' {
    # SWAP-2UPD-1: Azure swaps a data disk in two updates, detach then attach.
    # A job killed between them left the LUN with NO disk, and the resume kept
    # the machine stopped for a person to attach the disk in Azure. Now the
    # resume attaches the disk the record proves belongs there, with the LUN's
    # settings, and the machine starts only when every LUN holds its disk.
    BeforeAll {
        # Each kill between the two updates of one path, resumed.
        function Global:RjBetween([hashtable]$Opt) {
            $ref = RjReference -Opt $Opt
            $results = foreach ($pt in @($ref.Points | Where-Object { $_.site -eq 'swapData:between' })) {
                $r = RjKillAndResume -Opt $Opt -Site $pt.site -N $pt.n
                $r | Add-Member -NotePropertyName N -NotePropertyValue $pt.n -PassThru
            }
            [pscustomobject]@{ Reference = $ref; Results = @($results) }
        }
        # The disk made from the copy for LUN 0, as the fake Azure holds it.
        function Global:RjMadeFor0 { @($global:fa.disks.Keys | Where-Object { $global:fa.disks[$_].name -like 'vm1-d0-d0-restored-*' }) | Select-Object -First 1 }
        function Global:RjFinish($rp) {
            $err = $null
            try { Complete-VmfDataDiskSwap -RunPath $rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null }
            catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Error = $err; State = (RjState); Record = (RjRecord $rp); Started = @($global:fa.sites | Where-Object { $_ -eq 'start:before' }).Count }
        }
    }
    AfterAll { Remove-Item function:RjBetween, function:RjMadeFor0, function:RjFinish -ErrorAction SilentlyContinue }
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { }; RjMocks }
    AfterEach { Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }

    It '<Naming>, <Disks> data disk(s): every kill between the two updates resumes to the machine the uninterrupted run gave - each LUN on its restored disk, with the caching it had, started only after' -ForEach @(
        @{ Naming = 'new'; Disks = 1 }, @{ Naming = 'new'; Disks = 2 }, @{ Naming = 'preserve'; Disks = 1 }, @{ Naming = 'preserve'; Disks = 2 }) {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = $Naming; oneDisk = ($Disks -eq 1) }
        $b = RjBetween -Opt $opt
        $b.Results.Count | Should -BeGreaterThan 0
        $b.Reference.State | Should -Match '"data":"0=[^/,]+/ReadWrite' -Because 'LUN 0 keeps the caching the machine had (ReadWrite), not the ReadOnly the capture recorded'
        if ($Disks -eq 1) { $b.Reference.State | Should -Not -Match '1=' }
        foreach ($r in $b.Results) {
            $where = "killed at swapData:between #$($r.N)"
            $r.Killed | Should -BeTrue -Because $where
            $r.Error | Should -BeNullOrEmpty -Because $where
            $r.State | Should -Be $b.Reference.State -Because $where
            $r.Creates | Should -Be $b.Reference.Creates -Because "$where - never a second set of disks"
            @($r.Attaches).Count | Should -BeGreaterThan 0 -Because "$where - the resume attaches the disk to the empty LUN"
            $r.StartedAfter | Should -Be 1 -Because $where
            $sites = @($r.SitesAfter)
            [array]::LastIndexOf($sites, 'attachEmpty:after') | Should -BeLessThan ([array]::IndexOf($sites, 'start:before')) -Because "$where - the machine starts only when every LUN holds its disk"
            $r.Record.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty -Because $where
            $r.Record.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because $where
        }
    }
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    It 'with the rollback disks: the resume attaches the disk made before the move, and makes none' {
        $b = RjBetween -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new'; putBack = $true }
        $b.Reference.Creates | Should -Be 0
        foreach ($r in $b.Results) {
            $r.Error | Should -BeNullOrEmpty
            $r.State | Should -Be $b.Reference.State
            $r.Creates | Should -Be 0
            @($r.Attaches | Where-Object { $_ -like '0:vm1-d0-d0-asitwas-*' }).Count | Should -Be 1
        }
    }

    It 'new names: Azure refuses the attach - the disk the LUN had goes back, the machine stays stopped, the record names the LUN, and Finish the restore ends where the uninterrupted run ends' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $ref = RjReference -Opt $opt
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume { $global:fa.refuseEmpty = 'made' } -AfterResume {
            param($rp)
            $global:fa.refuseEmpty = ''
            RjFinish $rp
        }
        $r.StartedAfter | Should -Be 0
        $r.Error | Should -Match 'STOPPED'
        $r.Error | Should -Match 'Finish the restore'
        $r.State | Should -Match '"power":"deallocated"'
        $r.State | Should -Match '"data":"0=vm1-d0/ReadWrite,1=vm1-d1/None' -Because 'each LUN has the disk it had, with its own caching'
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        @($r.Record.swapPending.swaps | ForEach-Object { ([string]$_.oldDiskId -split '/')[-1] }) | Should -Be @('vm1-d0', 'vm1-d1')
        # FINISH-EMPTY-LUN-PROOF-1: each row names the copy its disk was made from.
        foreach ($row in @($r.Record.swapPending.swaps)) {
            [string]$row.snapshotId | Should -Not -BeNullOrEmpty
            $row.snapshotId | Should -Be ([string]$global:fa.disks[[string]$row.diskId].source)
        }
        $r.After.Error | Should -BeNullOrEmpty
        $r.After.State | Should -Be $ref.State
        $r.After.Record.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
    }
    It 'new names: Azure refuses the attach and the disk it had too - the LUN stays empty and on record, the machine never starts, and Finish the restore attaches it when Azure takes it' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $ref = RjReference -Opt $opt
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume { $global:fa.refuseEmpty = 'all' } -AfterResume {
            param($rp)
            # Azure still refuses: Finish keeps the machine stopped.
            $first = RjFinish $rp
            $global:fa.refuseEmpty = ''
            [pscustomobject]@{ Refused = $first; Done = (RjFinish $rp) }
        }
        $r.StartedAfter | Should -Be 0
        $r.State | Should -Match '"data":"0=NO DISK/[^,]*,1=NO DISK'
        $r.Error | Should -Match 'LUN 0 has no disk'
        $r.Error | Should -Match 'Finish the restore'
        $r.Error | Should -Not -Match 'Attach each disk to its LUN' -Because 'the way forward is in the app, never in Azure'
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        $r.After.Refused.Error | Should -Match 'stays stopped'
        $r.After.Refused.Started | Should -Be 0
        $r.After.Done.Error | Should -BeNullOrEmpty
        $r.After.Done.State | Should -Be $ref.State
    }
    It 'FINISH-EMPTY-LUN-PROOF-1: the resume leaves LUN 0 with no disk, and the disk that waits is then found made from another copy - Finish the restore refuses it before anything changes, and the machine stays stopped' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume { $global:fa.refuseEmpty = 'all' } -AfterResume {
            param($rp)
            $made = RjMadeFor0
            $row0 = @((RjRecord $rp).swapPending.swaps | Where-Object { [int]$_.lun -eq 0 })[0]
            $copy = [string]$row0.snapshotId
            $source = [string]$global:fa.disks[$made].source
            $global:fa.refuseEmpty = ''
            $global:fa.disks[$made].source = "$($script:sub)/Microsoft.Compute/snapshots/another-copy"
            $global:fa.sites.Clear(); $global:fa.attaches.Clear()
            $f = RjFinish $rp
            [pscustomobject]@{ Copy = $copy; Source = $source; Finish = $f; Sites = @($global:fa.sites); Attaches = @($global:fa.attaches) }
        }
        $r.StartedAfter | Should -Be 0
        $r.State | Should -Match '"data":"0=NO DISK'
        $r.After.Copy | Should -Not -BeNullOrEmpty
        $r.After.Copy | Should -Be $r.After.Source -Because 'the record names the copy the disk that waits was made from'
        $r.After.Finish.Error | Should -Match 'LUN 0 has no disk'
        $r.After.Finish.Error | Should -Match 'another-copy'
        $r.After.Finish.Error | Should -Match 'The machine is as it was before Finish the restore'
        $r.After.Finish.Started | Should -Be 0
        $r.After.Finish.State | Should -Match '"data":"0=NO DISK'
        $r.After.Finish.State | Should -Match '"power":"deallocated"'
        @($r.After.Attaches) | Should -BeNullOrEmpty
        @($r.After.Sites | Where-Object { $_ -like 'attachEmpty:*' -or $_ -like 'swapData:*' -or $_ -like 'start:*' }) | Should -BeNullOrEmpty
        @($r.After.Finish.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Contain 0
    }
    It 'keeping the names, killed in the second swap of a LUN (onto the disk under the old name), and Azure refuses the temporary disk: the disk under the old name goes on instead, and the machine ends as the uninterrupted run' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' }
        $ref = RjReference -Opt $opt
        # #1 is the swap of LUN 0 onto its temporary disk, #2 the swap onto the disk under its name.
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 2 -BeforeResume { $global:fa.refuseEmpty = 'rtmp' }
        $r.Error | Should -BeNullOrEmpty
        $r.State | Should -Be $ref.State
        @($r.Attaches | Where-Object { $_ -like '0:vm1-d0/*' }).Count | Should -Be 1
        $r.StartedAfter | Should -Be 1
    }
    It 'keeping the names: Azure refuses the temporary disk - the disk the LUN had goes back, and the machine stays stopped with the LUN on record' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' }
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume { $global:fa.refuseEmpty = 'made' }
        $r.StartedAfter | Should -Be 0
        $r.Error | Should -Match 'STOPPED'
        $r.State | Should -Match '"data":"0=vm1-d0/ReadWrite'
        $row = @($r.Record.swapPending.swaps | Where-Object { [int]$_.lun -eq 0 })
        $row.Count | Should -Be 1
        $row[0].temporary | Should -BeTrue
        ([string]$row[0].oldDiskId -split '/')[-1] | Should -Be 'vm1-d0'
        $row[0].lunHolds | Should -Be 'had' -Because 'FINISH-EMPTY-LUN-WORDS-1: the disk the LUN had is back on it'
        # FINISH-EMPTY-LUN-PROOF-1: the row names the copy its temporary disk was made from.
        [string]$row[0].snapshotId | Should -Not -BeNullOrEmpty
        $row[0].snapshotId | Should -Be ([string]$global:fa.disks[[string]$row[0].diskId].source)
    }

    It 'the record does not prove the disk - <Case>: no disk is attached to that LUN, the machine never starts, and the words name the LUN and the disk' -ForEach @(
        @{ Case = 'the disk made from its copy is gone'; Foreign = $false; Change = { $global:fa.disks.Remove((RjMadeFor0)) } }
        @{ Case = 'it is attached to another machine'; Foreign = $false; Change = { $global:fa.elsewhere = @(RjMadeFor0) } }
        @{ Case = 'it was made from another copy'; Foreign = $true; Change = { $global:fa.disks[(RjMadeFor0)].source = "$($script:sub)/Microsoft.Compute/snapshots/another-copy" } }) {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume $Change -AfterResume { param($rp) RjFinish $rp }
        $r.StartedAfter | Should -Be 0
        @($r.Attaches | Where-Object { $_ -like '0:*' }) | Should -BeNullOrEmpty
        $r.State | Should -Match '"data":"0=NO DISK'
        $r.Error | Should -Match 'LUN 0 has no disk'
        $r.Error | Should -Match 'vm1-d0-d0-restored-'
        $r.Error | Should -Match "'vm1-d0'" -Because 'it names the disk the LUN had too'
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Contain 0
        $row0 = @($r.Record.swapPending.swaps | Where-Object { [int]$_.lun -eq 0 })[0]
        $row0.caching | Should -Be 'ReadWrite' -Because 'the record keeps the caching the LUN is to have, for Finish the restore'
        # A disk made from another copy is not the disk the product made: the
        # record does not name it as the disk that waits.
        if ($Foreign) { [string]$row0.diskId | Should -BeNullOrEmpty } else { [string]$row0.diskId | Should -BeLike '*vm1-d0-d0-restored-*' }
        # Finish the restore asks again, and refuses the same way.
        $r.After.Started | Should -Be 0
        $r.After.Error | Should -Match 'LUN 0'
        $r.After.State | Should -Match '"data":"0=NO DISK'
    }

    It 'killed again <Where> the attach to the empty LUN: the next resume finishes it, and the machine ends as the uninterrupted run' -ForEach @(
        @{ Where = 'before'; Site = 'attachEmpty:before' }, @{ Where = 'after'; Site = 'attachEmpty:after' }) {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $ref = RjReference -Opt $opt
        $kill2 = $Site
        $r = RjKillAndResume -Opt $opt -Site 'swapData:between' -N 1 -BeforeResume { $global:fa.killAt = @{ site = $kill2; n = 1 } } -AfterResume {
            param($rp)
            if (-not $global:fa.snap) { return [pscustomobject]@{ Killed = $false } }
            RjRevive $rp
            $err = $null
            try { $null = RjAct -Rp $rp -Opt $opt -Resume } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Killed = $true; Error = $err; State = (RjState); Creates = $global:fa.creates; Record = (RjRecord $rp) }
        }
        $r.After.Killed | Should -BeTrue
        $r.After.Error | Should -BeNullOrEmpty
        $r.After.State | Should -Be $ref.State
        $r.After.Creates | Should -Be $ref.Creates
        $r.After.Record.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
}

Describe 'FINISH-KEPT-DISKS-1: a restore killed after it records a waiting swap and before it writes its own record (rule 4)' {
    # Restore this machine records the swap Azure refused (swapPending) and
    # then writes its own record (restore), which named the data disks it keeps
    # as they are by design. Killed between the two writes, the swap record
    # alone did not account for a kept disk, and Finish the restore refused the
    # machine: a person had to attach each disk in Azure. Now the swap record
    # names the kept disks in the same write.
    BeforeAll {
        # LUN 0 is refused on every try; LUN 1 is a shared disk, kept as it is.
        function Global:RjKeptKilled {
            RjMocks
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if (-not $global:fa.disks[$DiskId]) { throw "NotFound: disk '$DiskId'" }; if ([string]$DiskId -like '*/vm1-d1') { 2 } else { 1 } }
            RjAzure
            $global:fa.refuseLun = 0
            $rp = RjRun -Doc (RjDoc -Path 'A')
            $global:fa.rp = $rp
            # The read of the size between the swap record and the restore record.
            $global:fa.killAt = @{ site = 'readSize:before'; n = 2 }
            try { $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } catch { $null = $_ }
            if (-not $global:fa.snap) { throw 'The kill did not happen.' }
            RjRevive $rp
            $rp
        }
    }
    AfterAll { Remove-Item function:RjKeptKilled -ErrorAction SilentlyContinue }
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { }; $script:rjRp = $null }
    AfterEach {
        if ($script:rjRp) { Remove-Item $script:rjRp -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item "$($script:rjRp).snap" -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue
    }

    It 'what the kill leaves: the swap record names the waiting swap AND the kept disk, with no restore record yet' {
        $script:rjRp = RjKeptKilled
        $doc = RjRecord $script:rjRp
        $doc.PSObject.Properties['restore'] | Should -BeNullOrEmpty -Because 'the job was killed before it wrote its own record'
        [string]$doc.putBackJob.phase | Should -Be 'dataSwapped'
        @($doc.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        @($doc.swapPending.kept | ForEach-Object { [int]$_.lun }) | Should -Contain 1
        $global:fa.vm.power | Should -Be 'deallocated'
    }
    It 'the service gave up on the resume: Finish the restore swaps LUN 0, leaves the kept disk as it is, and starts the machine' {
        $script:rjRp = RjKeptKilled
        # RESUME-GIVEUP-KEEP-1: the resume limit, as the service marks it.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rjRp; id = $script:vmId } {
            param($rp, $id)
            Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action gaveUp -Why 'did not finish' | Should -BeTrue
        }
        $global:fa.refuseLun = -1
        $err = $null
        # The service gives up only once the killed job's hold on the machine
        # has ended by itself: here, at once.
        $limit = InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds }
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds = 0 }
        try { Complete-VmfDataDiskSwap -RunPath $script:rjRp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -CorrelationId 'op-finish' -Confirm:$false 3>$null | Out-Null }
        catch { $err = $_.Exception.Message }
        finally { InModuleScope VmMigrationFactory -Parameters @{ l = $limit } { param($l) $script:VmfMachineLeaseTimeoutSeconds = $l } }
        $err | Should -BeNullOrEmpty
        $global:fa.vm.power | Should -Be 'running'
        $global:fa.disks[$global:fa.vm.data['0']].name | Should -BeLike 'vm1-d0-d0-restored-*'
        $global:fa.vm.data['1'] | Should -Be (RjDiskId 'vm1-d1') -Because 'a kept disk is never touched'
        (RjRecord $script:rjRp).PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
    }
    It 'the service resumed it: the resume writes the restore record with the kept disk, keeps the swap record whole, and Finish the restore ends it' {
        $script:rjRp = RjKeptKilled
        $err = $null
        try { $null = RjAct -Rp $script:rjRp -Opt @{ kind = 'restore' } -Resume } catch { $err = $_.Exception.Message }
        $err | Should -Match 'STOPPED'
        $doc = RjRecord $script:rjRp
        @($doc.restore.dataDisksKept | ForEach-Object { [int]$_.lun }) | Should -Contain 1
        @($doc.swapPending.kept | ForEach-Object { [int]$_.lun }) | Should -Contain 1
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        $global:fa.refuseLun = -1
        Complete-VmfDataDiskSwap -RunPath $script:rjRp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:fa.vm.power | Should -Be 'running'
        $global:fa.vm.data['1'] | Should -Be (RjDiskId 'vm1-d1')
    }
}

Describe 'FINISH-NO-RESTORE-RECORD-1: Finish the restore after the service gave up on a restore killed before its record (rule 4)' {
    # Restore this machine records the swap Azure refused (swapPending), then
    # writes its own record (restore) and removes its checkpoint (putBackJob)
    # in one write. Killed between the two, and the service gave up on its
    # resume, Finish the restore swapped the disks that were left and started
    # the machine - and left NO restore record (the panel, the report and the
    # count did not say the machine was restored) and the checkpoint the
    # service marked gaveUp, which kept the safety copies for ever. Now Finish
    # writes the restore's record from the checkpoint and the swap record, and
    # removes the checkpoint, in the same write as it removes the swap record.
    BeforeAll {
        # The uninterrupted restore and Finish, and the killed restore, the
        # service giving up, and Finish - each from a new store and a new Azure.
        # LUN 1 is refused on every try of the restore; Finish swaps it.
        # FINISH-END-JOB-1: -Resume starts the finish a kill stopped again, as
        # the service's timer does.
        function Global:FnrFinish([string]$Rp, [switch]$Resume) {
            $limit = InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds }
            InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds = 0 }
            $err = $null
            $a = @{ RunPath = $Rp; VmId = $script:vmId; CorrelationId = 'op-finish'; Confirm = $false }
            if ($Resume) { $a.Resume = $true } else { $a.FinishedBy = 'lead@example.com'; $a.Note = 'Azure accepts the swap now' }
            try { Complete-VmfDataDiskSwap @a 3>$null | Out-Null }
            catch { $err = $_.Exception.Message }
            finally { InModuleScope VmMigrationFactory -Parameters @{ l = $limit } { param($l) $script:VmfMachineLeaseTimeoutSeconds = $l } }
            $err
        }
        function Global:FnrNew([hashtable]$Opt) {
            RjAzure -PutBack:([bool]$Opt.putBack)
            $global:fa.refuseLun = 1
            $rp = RjRun -Doc (RjDoc -Path $Opt.path -PutBack:([bool]$Opt.putBack))
            $global:fa.rp = $rp
            if ($Opt.earlier) {
                # An earlier restore of the machine finished: its record is on the machine.
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                    param($rp, $id)
                    $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                    $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject][ordered]@{
                            restoredUtc = '2026-10-01T00:00:00Z'; restoredBy = 'operator@example.com'; note = 'the earlier restore'; fromSnapshotId = '/s/earlier'
                            fromCopy = 'prepared'; sizeAfter = 'Standard_D2ds_v6'; diskNaming = 'new'; rebuilt = $false
                            previousDiskId = '/d/earlier-before'; previousDiskName = 'earlier-before'; newDiskId = '/d/earlier-os'; newDiskName = 'earlier-os'
                            diskIdChanged = $true; retainedDiskId = '/d/earlier-before'
                            dataDisks = @([pscustomobject][ordered]@{ lun = 3; previousDiskId = '/d/e3'; previousDiskName = 'e3'; newDiskId = '/d/e3-new'; newDiskName = 'earlier-lun3' })
                            dataDisksKept = @() })
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                }
            }
            $rp
        }
        function Global:FnrReference([hashtable]$Opt) {
            $rp = FnrNew $Opt
            try {
                try { $null = RjAct -Rp $rp -Opt $Opt } catch { $null = $_ }
                $reads = @($global:fa.sites | Where-Object { $_ -eq 'readSize:before' }).Count
                $stopped = RjRecord $rp
                $global:fa.refuseLun = -1
                $err = FnrFinish $rp
                [pscustomobject]@{ Error = $err; Reads = $reads; Stopped = $stopped; Record = (RjRecord $rp); State = (RjState) }
            }
            finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Killed at the read of the size between the swap record and the
        # restore's record; the service gives up on the resume, as at its limit.
        function Global:FnrKilled([hashtable]$Opt, [int]$N, [switch]$KeepRefusing) {
            $rp = FnrNew $Opt
            $global:fa.killAt = @{ site = 'readSize:before'; n = $N }
            try {
                try { $null = RjAct -Rp $rp -Opt $Opt } catch { $null = $_ }
                if (-not $global:fa.snap) { throw 'The kill did not happen.' }
                RjRevive $rp
                $atKill = RjRecord $rp
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                    param($rp, $id)
                    if (-not (Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action gaveUp -Why 'The restore did not finish after three starts.')) { throw 'The service did not mark the record.' }
                }
                $gaveUp = RjRecord $rp
                if (-not $KeepRefusing) { $global:fa.refuseLun = -1 }
                $global:fa.sites.Clear()
                $err = FnrFinish $rp
                [pscustomobject]@{ AtKill = $atKill; GaveUp = $gaveUp; Error = $err; Record = (RjRecord $rp); State = (RjState); Events = @(RjEvents $rp); Sites = @($global:fa.sites) }
            }
            finally {
                Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        function Global:FnrHolds($doc) { InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfPutBackJobHolds -Doc $d } }
    }
    AfterAll { Remove-Item function:FnrFinish, function:FnrNew, function:FnrReference, function:FnrKilled, function:FnrHolds -ErrorAction SilentlyContinue }
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { }; RjMocks }
    AfterEach { Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }

    It '<Name>: Finish writes the record the uninterrupted restore and Finish write, removes the checkpoint, and the copies are no longer held' -ForEach @(
        @{ Name = 'in place, the second copy, new names'; Opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } }
        @{ Name = 'in place, the first copy, new names'; Opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new' } }
        @{ Name = 'in place, the first copy, keeping the names'; Opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' } }
        @{ Name = 'the first copy with the rollback disks'; Opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new'; putBack = $true } }
        @{ Name = 'an earlier restore''s record on the machine'; Opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new'; earlier = $true } }
    ) {
        $ref = FnrReference $Opt
        $ref.Error | Should -BeNullOrEmpty
        $ref.Stopped.swapPending | Should -Not -BeNullOrEmpty -Because 'the uninterrupted restore left LUN 1 for Finish'
        $ref.Stopped.swapPending.operationId | Should -Be 'op-1' -Because 'the swap record names the restore that left it'
        $ref.Record.restore.operationId | Should -Be 'op-1'
        $ref.Record.restore.PSObject.Properties['writtenByFinish'] | Should -BeNullOrEmpty -Because 'the restore wrote its own record'

        # The last read of the size is the one between the two writes.
        $r = FnrKilled $Opt -N $ref.Reads
        $r.AtKill.swapPending.operationId | Should -Be 'op-1' -Because 'the swap record names the restore that left it'
        $r.AtKill.putBackJob.phase | Should -Be 'dataSwapped'
        if ($Opt.earlier) { $r.AtKill.restore.note | Should -Be 'the earlier restore' }
        else { $r.AtKill.PSObject.Properties['restore'] | Should -BeNullOrEmpty -Because 'the job was killed before it wrote its own record' }
        FnrHolds $r.GaveUp | Should -BeTrue -Because 'the service gave up, so the copies are held'

        $r.Error | Should -BeNullOrEmpty
        $r.State | Should -Be $ref.State
        $rec = $r.Record
        $rec.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $rec.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'the hold ends when a restore of the machine finishes'
        FnrHolds $rec | Should -BeFalse
        (RjRecordFacts $rec 'restore') | Should -Be (RjRecordFacts $ref.Record 'restore')
        foreach ($f in 'restoredBy', 'note', 'fromSnapshotId', 'operationId') { [string]$rec.restore.$f | Should -Be ([string]$ref.Record.restore.$f) -Because "the record keeps $f" }
        ([string]$rec.restore.retainedDiskId -replace '\d{12}', 'STAMP') | Should -Be ([string]$ref.Record.restore.retainedDiskId -replace '\d{12}', 'STAMP')
        @($rec.restore.dataDisks | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 3 -Because 'an earlier restore''s disks are not this restore''s'
        $rec.restore.writtenByFinish.by | Should -Be 'lead@example.com'
        $rec.restore.writtenByFinish.utc | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory -Parameters @{ d = $rec } { param($d) Get-VmfMachineOutcome -StateDoc $d } | Should -Be 'putBack'
        $ok = @($r.Events | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'ok' })
        $ok.Count | Should -Be 1
        $ok[0].detail | Should -Match 'Finish the restore wrote the record of the restore'
    }
    It 'the record Finish writes is valid against the vm-state schema' {
        $r = FnrKilled @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } -N 2
        $r.Error | Should -BeNullOrEmpty
        Test-Json -Json ($r.Record | ConvertTo-Json -Depth 24) -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') | Should -BeTrue
    }
    It 'the checkpoint is gone too (the service removed it): Finish starts the machine, writes no record it cannot prove, and says so' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $rp = FnrNew $opt
        $global:fa.killAt = @{ site = 'readSize:before'; n = 2 }
        try {
            try { $null = RjAct -Rp $rp -Opt $opt } catch { $null = $_ }
            RjRevive $rp
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id) if (-not (Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action remove)) { throw 'not removed' }
            }
            $global:fa.refuseLun = -1
            (FnrFinish $rp) | Should -BeNullOrEmpty
            $global:fa.vm.power | Should -Be 'running'
            $doc = RjRecord $rp
            $doc.PSObject.Properties['restore'] | Should -BeNullOrEmpty
            $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
            $ok = @(RjEvents $rp | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'ok' })
            $ok[-1].detail | Should -Match 'does not hold the record of this restore'
        }
        finally {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'Azure refuses the swap again: Finish writes no record, and the checkpoint and the hold stay' {
        $r = FnrKilled @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } -N 2 -KeepRefusing
        $r.Error | Should -Match 'did not finish'
        $r.Record.PSObject.Properties['restore'] | Should -BeNullOrEmpty
        $r.Record.swapPending | Should -Not -BeNullOrEmpty
        $r.Record.putBackJob.ended.reason | Should -Be 'gaveUp'
        FnrHolds $r.Record | Should -BeTrue
    }
    It 'Azure refuses the swap again over an earlier restore''s record: that record is not changed' {
        $r = FnrKilled @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new'; earlier = $true } -N 2 -KeepRefusing
        $r.Record.restore.note | Should -Be 'the earlier restore'
        @($r.Record.restore.dataDisks | ForEach-Object { [int]$_.lun }) | Should -Be @(3)
    }
    It 'killed while Finish writes: the swap is on the machine, and the finish started again writes the record and starts nothing twice' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' }
        $ref = FnrReference $opt
        # The start of the machine by Finish is a kill point: the swap is on
        # record, the record of the restore is not yet.
        $rp = FnrNew $opt
        $global:fa.killAt = @{ site = 'readSize:before'; n = 2 }
        try {
            try { $null = RjAct -Rp $rp -Opt $opt } catch { $null = $_ }
            RjRevive $rp
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id) $null = Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action gaveUp -Why 'w'
            }
            $global:fa.refuseLun = -1
            $global:fa.killAt = @{ site = 'start:after'; n = 1 }
            $null = FnrFinish $rp
            if (-not $global:fa.snap) { throw 'The kill did not happen.' }
            RjRevive $rp
            (RjRecord $rp).PSObject.Properties['restore'] | Should -BeNullOrEmpty
            # FINISH-END-JOB-1: a second Finish is refused while the killed one
            # has not ended; the service starts the killed one again.
            (FnrFinish $rp) | Should -Match 'has not ended'
            (FnrFinish $rp -Resume) | Should -BeNullOrEmpty
            $doc = RjRecord $rp
            (RjRecordFacts $doc 'restore') | Should -Be (RjRecordFacts $ref.Record 'restore')
            $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
            (RjState) | Should -Be $ref.State
        }
        finally {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'FINISH-NO-RESTORE-RECORD-1: which restore record is the one of the restore that left the swap (pure)' {
    It '<Name>' -ForEach @(
        @{ Name = 'the swap record and the restore record name the same restore'; Rec = @{ operationId = 'op-1' }; Sp = 'op-1'; Job = $null; Want = $true }
        @{ Name = 'another restore wrote the restore record'; Rec = @{ operationId = 'op-0' }; Sp = 'op-1'; Job = $null; Want = $false }
        # OLD-VERSION-READERS-REMOVE-4: a restore's swap record always names its
        # operation. One that names none matches no record, whatever the
        # checkpoint says, so Finish says the record is missing.
        @{ Name = 'a restore record that names no operation, and the job that left the swap is on record'; Rec = @{}; Sp = ''; Job = 'op-1'; Want = $false }
        @{ Name = 'a restore record and a swap record that name no operation, and no job'; Rec = @{}; Sp = ''; Job = $null; Want = $false }
        @{ Name = 'a swap record that names no operation, and the job named in the restore record'; Rec = @{ operationId = 'op-1' }; Sp = ''; Job = 'op-1'; Want = $false }
        @{ Name = 'a swap record that names no operation, and another job is on record'; Rec = @{ operationId = 'op-0' }; Sp = ''; Job = 'op-1'; Want = $false }
        @{ Name = 'no restore record'; Rec = $null; Sp = 'op-1'; Job = 'op-1'; Want = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rec = $Rec; sp = $Sp; job = $Job; want = $Want } {
            param($rec, $sp, $job, $want)
            $doc = [pscustomobject]@{ swapPending = [pscustomobject]@{ kind = 'restore'; swaps = @() } }
            if ($sp) { $doc.swapPending | Add-Member -NotePropertyName operationId -NotePropertyValue $sp }
            if ($null -ne $rec) { $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]$rec) }
            if ($job) { $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; operationId = $job; ended = [pscustomobject]@{ reason = 'gaveUp' } }) }
            [bool](Get-VmfSwapRestoreRecord -Doc $doc) | Should -Be $want
        }
    }
    It 'the record Finish writes comes from what the restore saved: <Name>' -ForEach @(
        @{ Name = 'the OS disk the data disk step saved, the copy of its kind, the kept disks of the swap record'; Case = 'result' }
        @{ Name = 'the OS disk step only, a copy named by its ID, and the kept disks of the swap record'; Case = 'os' }
        @{ Name = 'no OS disk saved: unknown, never a guess'; Case = 'none' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ case = $Case } {
            param($case)
            $job = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; startedBy = 'operator@example.com'; note = 'n'; phase = 'dataSwapped'
                options = [pscustomobject]@{ from = 'pristine'; diskNaming = 'new'; snapshotId = $null }
                before = [pscustomobject]@{ osDisk = [pscustomobject]@{ id = '/d/os'; name = 'os' }; dataDisks = @([pscustomobject]@{ lun = 0; id = '/d/d0'; name = 'd0' }, [pscustomobject]@{ lun = 1; id = '/d/d1'; name = 'd1' }) }
                ended = [pscustomobject]@{ outcome = 'fail'; reason = 'gaveUp' } }
            $sp = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; swaps = @()
                swapped = @([pscustomobject]@{ lun = 1; diskId = '/d/d1-new'; diskName = 'd1-new' }, [pscustomobject]@{ lun = 0; diskId = '/d/d0-new'; diskName = 'd0-new' })
                kept = @([pscustomobject]@{ lun = 5; name = 'later'; why = 'no copy' }) }
            $doc = [pscustomobject]@{ safety = [pscustomobject]@{ snapshotId = '/s/prepared'; pristineSnapshotId = '/s/pristine' }; swapPending = $sp; putBackJob = $job }
            switch ($case) {
                'result' {
                    $job | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject]@{ newId = '/d/os-new'; finalName = 'os-new'
                            data = [pscustomobject]@{ Replaced = @([pscustomobject]@{ lun = 0; previousDiskId = '/d/d0-was'; previousDiskName = 'd0-was'; newDiskId = '/d/d0-new'; newDiskName = 'd0-new' }); Kept = @() } })
                    $job | Add-Member -NotePropertyName os -NotePropertyValue ([pscustomobject]@{ newId = '/d/other'; finalName = 'other' })
                }
                'os' {
                    $job.options.snapshotId = '/s/named'
                    $job | Add-Member -NotePropertyName os -NotePropertyValue ([pscustomobject]@{ newId = '/d/os-new'; finalName = 'os-new' })
                    $job | Add-Member -NotePropertyName result -NotePropertyValue ([pscustomobject]@{ data = [pscustomobject]@{ Kept = @([pscustomobject]@{ lun = 4; name = 'old-kept'; why = 'shared' }) } })
                }
            }
            $rec = New-VmfFinishRestoreRecord -Doc $doc -FinishedBy 'lead@example.com' -SizeAfter 'Standard_D2s_v4'
            $rec.operationId | Should -Be 'op-1'
            $rec.restoredBy | Should -Be 'operator@example.com'
            $rec.note | Should -Be 'n'
            $rec.fromCopy | Should -Be 'pristine'
            $rec.sizeAfter | Should -Be 'Standard_D2s_v4'
            $rec.previousDiskId | Should -Be '/d/os'
            $rec.writtenByFinish.by | Should -Be 'lead@example.com'
            $rec.diskIdChanged | Should -BeTrue
            $rec.retainedDiskId | Should -Be '/d/os'
            @($rec.dataDisks | ForEach-Object { "$($_.lun):$($_.previousDiskName)>$($_.newDiskName)" }) -join ',' | Should -Be $(if ($case -eq 'result') { '0:d0-was>d0-new,1:d1>d1-new' } else { '0:d0>d0-new,1:d1>d1-new' })
            switch ($case) {
                'result' { $rec.newDiskId | Should -Be '/d/os-new'; $rec.fromSnapshotId | Should -Be '/s/pristine'; @($rec.dataDisksKept.lun) | Should -Be @(5); $rec.Keys | Should -Not -Contain 'rebuilt' }
                'os' { $rec.newDiskName | Should -Be 'os-new'; $rec.fromSnapshotId | Should -Be '/s/named'; @($rec.dataDisksKept.lun) | Should -Be @(5) -Because 'the swap record''s list, never the data disk step''s' }
                'none' { $rec.newDiskId | Should -BeNullOrEmpty; $rec.newDiskName | Should -BeNullOrEmpty }
            }
        }
    }
    It 'Finish writes no record from a checkpoint that is not this restore''s: none, a rebuild, one that has not ended, or one the swap record does not name' {
        InModuleScope VmMigrationFactory {
            $sp = [pscustomobject]@{ kept = @(); kind = 'restore'; operationId = 'op-1'; swaps = @(); swapped = @() }
            $mk = { param($kind, $op, $ended) $j = [pscustomobject]@{ kind = $kind; operationId = $op; options = [pscustomobject]@{ from = 'prepared'; diskNaming = 'new' } }
                if ($ended) { $j | Add-Member -NotePropertyName ended -NotePropertyValue ([pscustomobject]@{ outcome = 'fail'; reason = 'gaveUp' }) }; $j }
            New-VmfFinishRestoreRecord -Doc ([pscustomobject]@{ swapPending = $sp }) -FinishedBy 'x' | Should -BeNullOrEmpty
            foreach ($j in @((& $mk 'rebuild' 'op-1' $true), (& $mk 'restore' 'op-1' $false), (& $mk 'restore' 'op-2' $true))) {
                New-VmfFinishRestoreRecord -Doc ([pscustomobject]@{ swapPending = $sp; putBackJob = $j }) -FinishedBy 'x' | Should -BeNullOrEmpty
                Test-VmfFinishWritesRestoreRecord -Doc ([pscustomobject]@{ swapPending = $sp; putBackJob = $j }) | Should -BeFalse
            }
            Test-VmfFinishWritesRestoreRecord -Doc ([pscustomobject]@{ swapPending = $sp; putBackJob = (& $mk 'restore' 'op-1' $true) }) | Should -BeTrue
            Test-VmfFinishWritesRestoreRecord -Doc ([pscustomobject]@{ swapPending = $sp; putBackJob = (& $mk 'restore' 'op-1' $true); restore = [pscustomobject]@{ operationId = 'op-1' } }) | Should -BeFalse -Because 'the restore wrote its own record'
        }
    }
    It 'Add-VmfSwapFinished adds each disk to the record of the restore that left the swap, never to an earlier restore''s' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $row = [pscustomobject]@{ lun = 1; name = 'd1'; oldDiskId = '/d/d1'; diskId = '/d/d1-new'; diskName = 'd1-new' }
                foreach ($recOp in 'op-0', 'op-1') {
                    $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                    $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject]@{ operationId = $recOp; dataDisks = @() })
                    $doc | Add-Member -NotePropertyName swapPending -Force -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'; operationId = 'op-1'; swaps = @($row); swapped = @() })
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                    Add-VmfSwapFinished -RunPath $rp -VmId $id -Rows @($row)
                    $after = Read-VmfStateDoc -RunPath $rp -VmId $id
                    @($after.swapPending.swapped | ForEach-Object { [int]$_.lun }) | Should -Be @(1)
                    $want = if ($recOp -eq 'op-1') { 1 } else { 0 }
                    @($after.restore.dataDisks | Where-Object { $_ }).Count | Should -Be $want -Because "the record of $recOp"
                }
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'the last write keeps a record the restore wrote itself, says nothing is missing, and removes its ended checkpoint' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject]@{ operationId = 'op-1'; restoredUtc = '2026-11-01T00:00:00Z'; note = 'its own'; dataDisks = @() })
                $doc | Add-Member -NotePropertyName swapPending -Force -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'; operationId = 'op-1'; swaps = @(); swapped = @() })
                $doc | Add-Member -NotePropertyName putBackJob -Force -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; startedUtc = '2026-11-01T00:00:00Z'; stamp = '202611010000'; phase = 'dataSwapped'; resumes = 0
                        options = [pscustomobject]@{ from = 'prepared'; diskNaming = 'new' }; before = [pscustomobject]@{ osDisk = [pscustomobject]@{ id = '/d/os'; name = 'os' } }
                        ended = [pscustomobject]@{ utc = '2026-11-01T01:00:00Z'; outcome = 'fail' } })
                Write-VmfStateDoc -RunPath $rp -Document $doc
                $r = Save-VmfFinishedRestore -RunPath $rp -VmId $id -FinishedBy 'lead@example.com' -SizeAfter 'x'
                $r.Wrote | Should -BeFalse
                $r.Missing | Should -BeFalse
                $after = Read-VmfStateDoc -RunPath $rp -VmId $id
                $after.restore.note | Should -Be 'its own'
                $after.restore.PSObject.Properties['writtenByFinish'] | Should -BeNullOrEmpty
                $after.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
                $after.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'New-VmfSwapPendingRecord names the operation that left the swap, and none for a rollback' {
        InModuleScope VmMigrationFactory {
            (New-VmfSwapPendingRecord -Kind 'restore' -Swaps @() -Reason 'e' -OperationId 'op-1').operationId | Should -Be 'op-1'
            (New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @() -Reason 'e').Contains('operationId') | Should -BeFalse
        }
    }
    It 'vm-state v32 declares the operation on the restore record and the swap record, and who wrote the restore record with Finish; the sample validates' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $schema.properties.restore.properties.operationId | Should -Not -BeNullOrEmpty
        $schema.properties.swapPending.properties.operationId | Should -Not -BeNullOrEmpty
        @($schema.properties.restore.properties.writtenByFinish.required) | Should -Be @('by', 'utc')
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).restore.writtenByFinish.by | Should -Not -BeNullOrEmpty
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $base = { param($w) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"restore":{"operationId":"op-1"' + $w + '}}' }
        Test-Json -Json (& $base '') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base ',"writtenByFinish":null') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base ',"writtenByFinish":{"by":"lead@example.com","utc":"2026-11-02T00:00:00Z"}') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base ',"writtenByFinish":{"by":"lead@example.com"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json (& $base ',"writtenByFinish":{"by":"x","utc":"2026-11-02T00:00:00Z","why":"w"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v31 -> v32 \(2026-11-02, FINISH-NO-RESTORE-RECORD-1\)'
    }
}

Describe 'RESTORE-THROW-STARTS-1:a data disk swap throws and Azure cannot be read - the machine never starts, and Finish the restore ends it' {
    # The restore put each LUN it could not read after a swap that threw on
    # the kept list, saw no disk left to swap, and STARTED the machine: its OS
    # disk from the copy, a data disk from another moment or with no disk.
    # Now each such LUN is on the list of disks left. The machine stays
    # stopped, and Finish the restore reads Azure for each LUN.
    BeforeAll {
        # The swap whose disk name is like $global:rts.throwOn takes only the
        # LUNs in $global:rts.attach, then throws; from then on every read of
        # the data disks fails until a test says Azure answers again.
        function Global:RtsMocks {
            RjMocks
            Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
                Global:RjKill 'swapData:before'
                if (-not $global:fa.vm.exists -or $global:fa.vm.power -ne 'deallocated') { throw 'Azure swaps data disks here only on a stopped machine' }
                if ($global:rts.throwOn -and @($Swaps | Where-Object { [string]$_.diskName -like $global:rts.throwOn }).Count) {
                    $global:rts.throwOn = $null
                    foreach ($s in $Swaps) { $global:fa.vm.data["$([int]$s.lun)"] = '' }
                    foreach ($s in $Swaps) { if ([int]$s.lun -in @($global:rts.attach)) { $global:fa.vm.data["$([int]$s.lun)"] = [string]$s.diskId } }
                    if ($global:rts.failReadsOnce) { $global:rts.readFailTimes = 1 } else { $global:rts.readFail = $true }
                    throw 'The data disks are neither swapped nor as they were.'
                }
                foreach ($s in $Swaps) { $global:fa.vm.data["$([int]$s.lun)"] = [string]$s.diskId }
                Global:RjKill 'swapData:after'
                @{ Applied = $true }
            }
            Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
                if ($global:rts.readFail) { Global:RjKill 'readData:fail'; throw 'Azure did not answer the read.' }
                if ([int]$global:rts.readFailTimes -gt 0) { $global:rts.readFailTimes--; throw 'Azure did not answer the read.' }
                @(foreach ($k in @($global:fa.vm.data.Keys | Sort-Object { [int]$_ })) {
                        $id = [string]$global:fa.vm.data[$k]
                        if (-not $id) { continue }
                        [pscustomobject]@{ lun = [int]$k; id = $id; name = $global:fa.disks[$id].name; resourceGroup = 'rg-app'; skuName = 'Premium_LRS'
                            caching = [string]$global:fa.vm.caching[$k]; deleteOption = 'Detach'; writeAcceleratorEnabled = $false }
                    })
            }
        }
        function Global:RtsFinish($rp) {
            $global:rts.readFail = $false
            $global:fa.sites.Clear(); $global:fa.attaches.Clear()
            $err = $null
            try { Complete-VmfDataDiskSwap -RunPath $rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false 3>$null | Out-Null }
            catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Error = $err; Record = (RjRecord $rp); Power = $global:fa.vm.power; Attaches = @($global:fa.attaches)
                Data = @(foreach ($k in @($global:fa.vm.data.Keys | Sort-Object { [int]$_ })) { "$k=$([string]$global:fa.disks[[string]$global:fa.vm.data[$k]].name)" }) -join ',' }
        }
    }
    AfterAll { Remove-Item function:RtsMocks, function:RtsFinish -ErrorAction SilentlyContinue }
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { }; $script:rtsRp = $null }
    AfterEach {
        if ($script:rtsRp) { Remove-Item $script:rtsRp -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Variable fa, rts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'new names: the swap of both LUNs throws with LUN 0 empty and LUN 1 on its new disk, and no read answers - the machine stays stopped, both LUNs are left, none is kept, and Finish the restore ends it' {
        RtsMocks
        RjAzure
        $global:rts = @{ throwOn = 'vm1-d*-restored-*'; attach = @(1); readFail = $false }
        $script:rtsRp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $script:rtsRp
        $err = $null
        try { $null = RjAct -Rp $script:rtsRp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } catch { $err = $_.Exception.Message }
        $err | Should -Match 'STOPPED'
        $err | Should -Match 'Finish the restore'
        $err | Should -Match "did not read which disk is on these LUNs after it: LUN 0, where the disk 'vm1-d0-d0-restored-\d+' made from its copy waits to go on; LUN 1, "
        $err | Should -Not -Match 'LUN \d keeps' -Because 'nobody read the LUNs, so the words never say which disk a LUN holds'
        @($global:fa.sites | Where-Object { $_ -eq 'start:before' }) | Should -BeNullOrEmpty -Because 'the machine never starts with disks from two moments'
        $global:fa.vm.power | Should -Be 'deallocated'
        $doc = RjRecord $script:rtsRp
        @($doc.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        @($doc.restore.dataDisksKept | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 0
        @($doc.restore.dataDisksKept | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 1
        @($doc.swapPending.kept | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 0 -Because 'Finish the restore never counts a LUN nobody read as accounted for'
        @($doc.swapPending.kept | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 1

        $f = RtsFinish $script:rtsRp
        $f.Error | Should -BeNullOrEmpty
        $f.Power | Should -Be 'running'
        $f.Data | Should -Match '^0=vm1-d0-d0-restored-\d+,1=vm1-d1-d1-restored-\d+,5=added-later$'
        @($f.Attaches | Where-Object { $_ -like '0:vm1-d0-d0-restored-*' }).Count | Should -Be 1 -Because 'the empty LUN gets the disk the record proves, by its copy'
        $f.Record.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($f.Record.restore.dataDisks | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
    }

    It 'new names: the read after the swap threw fails once, and Azure answers the read before the start - the machine stays stopped, and the words say which LUNs the product did not read' {
        RtsMocks
        RjAzure
        $global:rts = @{ throwOn = 'vm1-d*-restored-*'; attach = @(1); readFail = $false; failReadsOnce = $true }
        $script:rtsRp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $script:rtsRp
        $err = $null
        try { $null = RjAct -Rp $script:rtsRp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } catch { $err = $_.Exception.Message }
        @($global:fa.sites | Where-Object { $_ -eq 'start:before' }) | Should -BeNullOrEmpty
        $global:fa.vm.power | Should -Be 'deallocated'
        $err | Should -Match 'STOPPED'
        $err | Should -Match 'LUN 0 has no disk' -Because 'the read before the start found LUN 0 empty'
        $err | Should -Match "did not read which disk is on these LUNs after it: LUN 1, where the disk 'vm1-d1-d1-restored-\d+' made from its copy waits to go on"
        $err | Should -Not -Match 'LUN 1 keeps'
        $doc = RjRecord $script:rtsRp
        @($doc.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'the restore ended with its record'
        $f = RtsFinish $script:rtsRp
        $f.Error | Should -BeNullOrEmpty
        $f.Power | Should -Be 'running'
    }

    It 'killed just before the swap (rule 4), and the resume''s swap throws with no read that answers: the machine stays stopped, the words say which LUNs the product did not read, and Finish the restore ends it' {
        RtsMocks
        $global:rts = @{ throwOn = 'vm1-d*-restored-*'; attach = @(1); readFail = $false }
        $r = RjKillAndResume -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } -Site 'swapData:before' -N 1 -AfterResume { param($rp) RtsFinish $rp }
        $r.Killed | Should -BeTrue
        $r.HadJob | Should -BeTrue
        $r.StartedAfter | Should -Be 0
        $r.State | Should -Match '"power":"deallocated"'
        $r.Error | Should -Match 'STOPPED'
        $r.Error | Should -Match "did not read which disk is on these LUNs after it: LUN 0, where the disk 'vm1-d0-d0-restored-\d+' made from its copy waits to go on; LUN 1, "
        $r.Error | Should -Not -Match 'LUN \d keeps'
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        $r.After.Error | Should -BeNullOrEmpty
        $r.After.Power | Should -Be 'running'
        $r.After.Data | Should -Match '^0=vm1-d0-d0-restored-\d+,1=vm1-d1-d1-restored-\d+,5=added-later$'
    }

    It 'keeping the names: the swap onto the disk under the old name throws, the LUN is left empty, and no read answers - the machine stays stopped, and Finish the restore puts the disk under the old name on' {
        RtsMocks
        RjAzure -OneDisk
        $global:rts = @{ throwOn = 'vm1-d0'; attach = @(); readFail = $false }
        $script:rtsRp = RjRun -Doc (RjDoc -Path 'A' -OneDisk)
        $global:fa.rp = $script:rtsRp
        $err = $null
        try { $null = RjAct -Rp $script:rtsRp -Opt @{ kind = 'restore'; from = 'pristine'; naming = 'preserve' } } catch { $err = $_.Exception.Message }
        $err | Should -Match 'STOPPED'
        $err | Should -Match "did not read which disk is on these LUNs after it: LUN 0, where the disk 'vm1-d0' made from its copy waits to go on"
        @($global:fa.sites | Where-Object { $_ -eq 'start:before' }) | Should -BeNullOrEmpty
        $global:fa.vm.power | Should -Be 'deallocated'
        $doc = RjRecord $script:rtsRp
        $row = @($doc.swapPending.swaps | Where-Object { [int]$_.lun -eq 0 })
        $row.Count | Should -Be 1
        $row[0].diskName | Should -Be 'vm1-d0'
        ([string]$row[0].oldDiskId -split '/')[-1] | Should -BeLike 'vm1-d0-d0-rtmp-*'
        @($doc.restore.dataDisksKept | ForEach-Object { [int]$_.lun }) | Should -Not -Contain 0

        $f = RtsFinish $script:rtsRp
        $f.Error | Should -BeNullOrEmpty
        $f.Power | Should -Be 'running'
        $f.Data | Should -Be '0=vm1-d0,5=added-later'
        $f.Record.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
    }

    It 'killed at the read after the swap threw (rule 4), and <Case> at the resume: <Ends>' -ForEach @(
        @{ Case = 'Azure still does not answer'; Ends = 'the machine stays stopped with both LUNs left, and Finish the restore ends it'; ReadsWork = $false }
        @{ Case = 'Azure answers'; Ends = 'the resume puts each LUN on its disk and starts the machine'; ReadsWork = $true }) {
        RtsMocks
        $global:rts = @{ throwOn = 'vm1-d*-restored-*'; attach = @(1); readFail = $false }
        $works = $ReadsWork
        $r = RjKillAndResume -Opt @{ kind = 'restore'; path = 'A'; from = 'prepared'; naming = 'new' } -Site 'readData:fail' -N 1 `
            -BeforeResume { $global:rts.readFail = -not $works } -AfterResume { param($rp) if (-not $works) { RtsFinish $rp } }
        $r.Killed | Should -BeTrue
        $r.HadJob | Should -BeTrue
        if ($ReadsWork) {
            $r.Error | Should -BeNullOrEmpty
            $r.StartedAfter | Should -Be 1
            $r.State | Should -Match '"power":"running"'
            $r.State | Should -Match '"data":"0=vm1-d0-d0-restored-STAMP/[^,]*,1=vm1-d1-d1-restored-STAMP/'
            $r.Record.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
            return
        }
        $r.StartedAfter | Should -Be 0 -Because 'a resume that cannot read the LUNs never starts the machine'
        $r.Error | Should -Match 'STOPPED'
        $r.State | Should -Match '"power":"deallocated"'
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        $r.After.Error | Should -BeNullOrEmpty
        $r.After.Power | Should -Be 'running'
        $r.After.Data | Should -Match '^0=vm1-d0-d0-restored-\d+,1=vm1-d1-d1-restored-\d+,5=added-later$'
    }
}
# REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).

Describe 'RESTORE-END-JOB-1: what else waits for a restore that has not ended' {
    It 'Finish the restore is refused while a restore of the machine has not ended' {
        $rp = RjRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610240900'
                Set-VmfSwapPending -RunPath $rp -VmId $id -Record (New-VmfSwapPendingRecord -Kind 'restore' -Swaps @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; diskId = 'x'; diskName = 'x' }) -Reason 'refused' -UsedBy '' -Swapped @())
            }
            { Complete-VmfDataDiskSwap -RunPath $rp -VmId $script:vmId -CorrelationId 'op-2' -Confirm:$false } | Should -Throw '*did not finish*'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'a retry, a validation again and a decision are refused while a restore job of the machine that stopped has not ended' {
        $rp = RjRun -Doc (RjDoc -Path 'A' -State 'FAILED_ROLLED_BACK')
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{ schemaVersion = 9; runId = 'rj'; assessmentRunId = 'rj'
                        entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; path = 'A'; target = [ordered]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' } }) })
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc.history = @($doc.history) + @([pscustomobject]@{ tsUtc = '2026-10-24T10:00:00Z'; state = 'FAILED_ROLLED_BACK'; outcome = 'fail'; reasonCode = 'rolledBack'; machineState = 'restored' })
                Write-VmfStateDoc -RunPath $rp -Document $doc
                $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -Options @{ from = 'pristine' } -Stamp '202610241000'
            }
            foreach ($to in 'PRECHECK', 'VALIDATING') {
                { Resolve-VmfDecision -RunPath $rp -VmId $script:vmId -PlanPath (Join-Path $rp 'plan.json') -ResolvedBy 'operator@example.com' -Note 'n' -ReturnTo $to } |
                    Should -Throw -ExpectedMessage '400: Restore this machine of*did not finish*'
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'RESUME-GIVEUP-KEEP-1: a restore the service gave up on keeps the copies and the disks until a restore of the machine ends' {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id)
            $doc = [pscustomobject]@{
                vmId = $id; state = 'MIGRATED'
                history = @([pscustomobject]@{ state = 'MIGRATED'; tsUtc = '2026-01-01T00:00:00Z'; outcome = 'ok' })
                safety = [pscustomobject]@{ snapshotId = '/s/copy'; rollbackDisksBeforeMove = [pscustomobject]@{ complete = $true; disks = @([pscustomobject]@{ diskId = '/d/pb'; diskName = 'pb' }) } }
                restoreDisks = @([pscustomobject]@{ diskId = '/d/made'; diskName = 'made' })
                putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; phase = 'stopped'; ended = [pscustomobject]@{ outcome = 'fail'; reason = 'gaveUp' } }
            }
            $entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; policy = [pscustomobject]@{ retentionDays = 1 } })
            $r = Get-VmfExpiredSafetyCopies -StateDocs @($doc) -PlanEntries $entries -NowUtc ([datetime]'2026-10-24')
            @($r.Eligible).Count | Should -Be 0
            @($r.Skipped | Where-Object { $_.Reason -match 'stopped and did not finish' -and $_.Reason -match 'needs a person' }).Count | Should -Be 1
            @(Get-VmfDueRollbackDisksBeforeMove -StateDocs @($doc)).Count | Should -Be 0
            @(Get-VmfDueMadeDisks -StateDocs @($doc)).Count | Should -Be 0
            # A later restore that failed carries the hold.
            $doc.putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-2'; phase = 'made'; ended = [pscustomobject]@{ outcome = 'fail' }; held = [pscustomobject]@{ operationId = 'op-1' } }
            @((Get-VmfExpiredSafetyCopies -StateDocs @($doc) -PlanEntries $entries -NowUtc ([datetime]'2026-10-24')).Eligible).Count | Should -Be 0
            @(Get-VmfDueMadeDisks -StateDocs @($doc)).Count | Should -Be 0
            # A restore that finished removed the record: retention goes on.
            $doc.PSObject.Properties.Remove('putBackJob')
            @((Get-VmfExpiredSafetyCopies -StateDocs @($doc) -PlanEntries $entries -NowUtc ([datetime]'2026-10-24')).Eligible).Count | Should -Be 1
        }
    }
    It 'RESUME-GIVEUP-KEEP-1: a new restore is allowed over a record the service gave up on, carries the hold while it runs, and clears it when it finishes' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc | Add-Member -NotePropertyName putBackJob -Force -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; operationId = 'op-0'; startedUtc = '2026-10-24T08:00:00Z'
                        options = [pscustomobject]@{ from = 'prepared' }; stamp = '202610240800'; phase = 'stopped'; resumes = 3
                        ended = [pscustomobject]@{ utc = '2026-10-24T09:00:00Z'; outcome = 'fail'; reason = 'gaveUp'; why = 'did not finish' } })
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
            # While it runs, its own record carries the hold.
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
                $script:rjHeldWhileRunning = (Global:RjRecord $global:fa.rp).putBackJob.held.operationId
                $global:fa.vm.power = 'deallocated'
            }
            $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' }
            $script:rjHeldWhileRunning | Should -Be 'op-0'
            $doc = RjRecord $rp
            $doc.restore.restoredUtc | Should -Not -BeNullOrEmpty
            $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'a restore that finished clears the hold'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'RESUME-GIVEUP-KEEP-1: a new restore that fails over it ends with the hold still on its record' {
        RjMocks; RjAzure
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'Azure refused the OS disk swap' }
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc | Add-Member -NotePropertyName putBackJob -Force -NotePropertyValue ([pscustomobject]@{ kind = 'rebuild'; operationId = 'op-0'; startedUtc = '2026-10-24T08:00:00Z'
                        options = [pscustomobject]@{ diskSource = 'disks' }; stamp = '202610240800'; phase = 'shellDeleted'; resumes = 3
                        ended = [pscustomobject]@{ utc = '2026-10-24T09:00:00Z'; outcome = 'fail'; reason = 'gaveUp'; why = 'did not finish' } })
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
            { RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'new' } } | Should -Throw
            $job = (RjRecord $rp).putBackJob
            $job.operationId | Should -Be 'op-1'
            $job.ended.outcome | Should -Be 'fail'
            $job.held.operationId | Should -Be 'op-0'
            InModuleScope VmMigrationFactory -Parameters @{ d = (RjRecord $rp) } { param($d) Test-VmfPutBackJobHolds -Doc $d } | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'retention keeps the copies, the rollback disks and the disks a put-back made, of a machine whose restore has not ended - and says so' {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id)
            $doc = [pscustomobject]@{
                vmId = $id; state = 'MIGRATED'
                history = @([pscustomobject]@{ state = 'MIGRATED'; tsUtc = '2026-01-01T00:00:00Z'; outcome = 'ok' })
                safety = [pscustomobject]@{ snapshotId = '/s/copy'; rollbackDisksBeforeMove = [pscustomobject]@{ complete = $true; disks = @([pscustomobject]@{ diskId = '/d/pb'; diskName = 'pb' }) } }
                restoreDisks = @([pscustomobject]@{ diskId = '/d/made'; diskName = 'made' })
                putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; phase = 'shellDeleted' }
            }
            $entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; policy = [pscustomobject]@{ retentionDays = 1 } })
            $r = Get-VmfExpiredSafetyCopies -StateDocs @($doc) -PlanEntries $entries -NowUtc ([datetime]'2026-10-24')
            @($r.Eligible).Count | Should -Be 0
            @($r.Skipped | Where-Object { $_.Reason -match 'has not ended' }).Count | Should -Be 1
            @(Get-VmfDueRollbackDisksBeforeMove -StateDocs @($doc)).Count | Should -Be 0
            @(Get-VmfDueMadeDisks -StateDocs @($doc)).Count | Should -Be 0
            # Ended: the rules of before apply again.
            $doc.putBackJob | Add-Member -NotePropertyName ended -NotePropertyValue ([pscustomobject]@{ outcome = 'fail' }) -Force
            @((Get-VmfExpiredSafetyCopies -StateDocs @($doc) -PlanEntries $entries -NowUtc ([datetime]'2026-10-24')).Eligible).Count | Should -Be 1
            @(Get-VmfDueRollbackDisksBeforeMove -StateDocs @($doc)).Count | Should -Be 1
            @(Get-VmfDueMadeDisks -StateDocs @($doc)).Count | Should -Be 1
        }
    }
}

Describe 'RESTORE-END-JOB-1: the service starts a stopped restore again' {
    BeforeAll {
        $script:svStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rjs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:svStore
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        function Script:SvSeed {
            param([string]$Kind = 'restore', [int]$Resumes = 0, [int]$LeaseAge = 2000, [switch]$Ended, [switch]$EndLine, [string]$Naming = 'new')
            if (Test-Path $script:svStore) { Remove-Item $script:svStore -Recurse -Force }
            $rp = Join-Path $script:svStore 'rj'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; k = $Kind; n = $Resumes; age = $LeaseAge; ended = [bool]$Ended; endLine = [bool]$EndLine; naming = $Naming } {
                param($rp, $id, $k, $n, $age, $ended, $endLine, $naming)
                Initialize-VmfRun -RunPath $rp -RunId 'rj' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'rj' -VmId $id -Wave 'w1' | Out-Null
                $opts = if ($k -eq 'restore') { @{ from = 'pristine'; diskNaming = $naming; acceptPreserveRisk = ($naming -eq 'preserve'); snapshotId = $null } } else { @{ diskSource = 'pristine'; as = 'original'; diskSku = $null } }
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind $k -OperationId 'op-1' -StartedBy 'operator@example.com' -Note 'it does not start' -Options $opts -Stamp '202610240900'
                Save-VmfPutBackJobStep -Token $t -Phase 'stopped'
                $step = if ($k -eq 'rebuild') { 'recovery' } else { 'restore' }
                Write-VmfEvent -RunPath $rp -Step $step -Outcome start -VmId $id -CorrelationId 'op-1' -Detail 'started'
                if ($endLine) { Write-VmfEvent -RunPath $rp -Step $step -Outcome fail -VmId $id -Detail 'it failed' }
                foreach ($i in 1..$n) { if ($n -gt 0) { $null = Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action resume } }
                if ($ended) { Close-VmfPutBackJob -Token $t -Why 'Azure refused' }
                if ($age -ge 0) {
                    Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $id) -Depth 6 -Document ([ordered]@{
                            vmId = $id; workerId = "${k}:op-1"; heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o') })
                }
            }
        }
        function Script:SvArm {
            param([object[]]$Running = @())
            $script:svPosts = [System.Collections.Generic.List[object]]::new()
            $script:svRunning = @($Running)
            Mock -ModuleName FacadeCore Invoke-AzRestMethod {
                if ($Method -eq 'GET' -and $Path -notmatch '/executions') {
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
                }
                if ($Method -eq 'POST' -and $Path -match '/start\?') {
                    $script:svPosts.Add(($Payload | ConvertFrom-Json))
                    return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'exec-resume'; id = 'x' } | ConvertTo-Json) }
                }
                [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            Mock -ModuleName VmMigrationFactory Get-VmfArmList {
                [pscustomobject]@{ Ok = $true; StatusCode = 200; Items = @($script:svRunning | ForEach-Object {
                            [pscustomobject]@{ name = 'exec-old'; properties = [pscustomobject]@{ status = 'Running'; template = [pscustomobject]@{ containers = @([pscustomobject]@{ env = @(
                                                [pscustomobject]@{ name = 'VMF_OPERATION'; value = $_ }, [pscustomobject]@{ name = 'VMF_RUN_ID'; value = 'rj' },
                                                [pscustomobject]@{ name = 'VMF_VM_ID'; value = $script:vmId }) }) } } } }) }
            }
        }
        function Script:SvEnv($post, $name) { [string](@($post.containers[0].env) | Where-Object { $_.name -eq $name } | Select-Object -First 1).value }
        function Script:SvRecord { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:svStore 'rj'); id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
        function Script:SvEvents { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:svStore 'rj') } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    }
    AfterAll { if (Test-Path $script:svStore) { Remove-Item $script:svStore -Recurse -Force }; Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a restore whose hold expired and whose job Azure no longer runs is started again for the SAME operation, with what the person asked for' {
        SvSeed -Naming preserve
        SvArm
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj')
        $r.Count | Should -Be 1
        $r[0].Action | Should -Be 'resumed'
        $script:svPosts.Count | Should -Be 1
        $p = $script:svPosts[0]
        SvEnv $p 'VMF_OPERATION' | Should -Be 'restore'
        SvEnv $p 'VMF_RESUME_ID' | Should -Be 'op-1'
        SvEnv $p 'VMF_VM_ID' | Should -Be $script:vmId
        SvEnv $p 'VMF_DISK_SOURCE' | Should -Be 'pristine'
        SvEnv $p 'VMF_DISK_NAMING' | Should -Be 'preserve'
        SvEnv $p 'VMF_ACCEPT_PRESERVE_RISK' | Should -Be 'true'
        (SvRecord).putBackJob.resumes | Should -Be 1
        $line = @(SvEvents | Where-Object { $_.step -eq 'resume' -and $_.outcome -eq 'warn' })[-1]
        $line.vmId | Should -Be $script:vmId -Because 'the page keeps the row on Restoring by its machine'
        $line.detail | Should -Match "stopped part way when its job stopped, at the step 'stopped'.*started it again"
    }
    It 'STEP-LOG-6: a restore started again is returned as resumed when its resume line cannot be written' {
        SvSeed
        SvArm
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'resume' } { throw 'The store did not answer.' }
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj' -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 1 -Because 'the job runs, so the pass says so'
        $r[0].Action | Should -Be 'resumed'
        $r[0].Execution | Should -Be 'exec-resume'
        $script:svPosts.Count | Should -Be 1
        (@($w | ForEach-Object { [string]$_ }) -join "`n") | Should -BeLike "*'resume warn' for $($script:vmId) could not be written*The engine started it again (execution exec-resume)*"
    }
    It 'STEP-LOG-6: a start that Azure refuses is counted, and the pass goes on, when its fail line cannot be written' {
        SvSeed
        SvArm
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw '400: the engine job is being updated' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'resume' } { throw 'The store did not answer.' }
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj' -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 0
        (SvRecord).putBackJob.resumes | Should -Be 1 -Because 'counted before the start, so the next passes end it at the limit'
        (@($w | ForEach-Object { [string]$_ }) -join "`n") | Should -BeLike "*'resume fail' for $($script:vmId) could not be written*could not start it again: the engine job is being updated*"
    }
    It 'STEP-LOG-6: the line that ends the row stays a throwing write - a lost one keeps the record, so the next pass ends the row' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfPutBackResumeLimit }
        SvSeed -Resumes $limit
        SvArm
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine:restore' } { throw 'The store did not answer.' }
        { Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj' } | Should -Throw '*The store did not answer.*'
        $job = (SvRecord).putBackJob
        $job.PSObject.Properties['ended'] -and $job.ended | Should -BeFalse -Because 'the record is marked only after the line that ends the row is written'
    }
    It 'the service does not ask the retirement date of a resume; a new restore from the first copy is still refused' {
        SvSeed
        SvArm
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementRefusal { 'Microsoft retires this size tomorrow.' }
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj')
        $r[0].Action | Should -Be 'resumed'
        $script:svPosts.Count | Should -Be 1
        { Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }) -Operation restore -RunId 'rj' -VmId $script:vmId -DiskSource pristine -Note 'again' } |
            Should -Throw '400: Microsoft retires this size tomorrow.'
    }
    # REBUILD-REMOVE-RECOVER-1: removed with the restore that rebuilds and Rebuild this machine; no restore rebuilds, and an old job of either is not resumed (RebuildRemoveRecover.Tests.ps1).
    It 'a live hold means the job runs: nothing is started' {
        SvSeed -LeaseAge 30
        SvArm
        @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj').Count | Should -Be 0
        $script:svPosts.Count | Should -Be 0
        (SvRecord).putBackJob.resumes | Should -Be 0
    }
    It 'an execution Azure lists as running for the machine means the job runs, even with no hold yet: nothing is started' {
        foreach ($op in 'restore', 'finish') {
            SvSeed -LeaseAge -1
            SvArm -Running @($op)
            @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj').Count | Should -Be 0 -Because "a $op of the machine runs"
            $script:svPosts.Count | Should -Be 0
            (SvRecord).putBackJob.resumes | Should -Be 0 -Because 'a job that runs is not counted as started again'
            @(SvEvents | Where-Object { $_.step -eq 'resume' }).Count | Should -Be 0
        }
    }
    It 'two passes in a row start it once: the second sees the first as running' {
        SvSeed
        SvArm
        $null = Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj'
        $script:svRunning = @('restore')
        @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj').Count | Should -Be 0
        $script:svPosts.Count | Should -Be 1
    }
    It 'at the limit the service stops trying: the row ends on the engine''s fail line with the operation id, and the record stays, marked gaveUp' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfPutBackResumeLimit }
        SvSeed -Resumes $limit
        SvArm
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj')
        $r[0].Action | Should -Be 'gaveUp'
        $script:svPosts.Count | Should -Be 0
        $fail = @(SvEvents | Where-Object { $_.step -eq 'engine:restore' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].correlationId | Should -Be 'op-1'
        $fail[0].vmId | Should -Be $script:vmId
        $fail[0].detail | Should -Match "started it again $limit times, and it did not finish"
        $fail[0].detail | Should -Match 'keeps the safety copies of the machine'
        # RESUME-GIVEUP-KEEP-1: the record stays, marked, so retention keeps the
        # copies a machine left part way needs. It no longer refuses anything.
        $job = (SvRecord).putBackJob
        $job.ended.reason | Should -Be 'gaveUp'
        InModuleScope VmMigrationFactory -Parameters @{ d = (SvRecord) } { param($d) Get-VmfPutBackJobRefusal -Doc $d -VmName 'vm1' } | Should -BeNullOrEmpty -Because 'a person can start a new restore'
        # A second pass changes nothing and says nothing again.
        $null = Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj'
        @(SvEvents | Where-Object { $_.step -eq 'engine:restore' }).Count | Should -Be 1
        $script:svPosts.Count | Should -Be 0
        (SvRecord).putBackJob.ended.reason | Should -Be 'gaveUp'
    }
    It 'a later restore that fails over a record the service gave up on keeps the hold: the record becomes the same mark again' {
        SvSeed -Ended
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:svStore 'rj'); id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.putBackJob | Add-Member -NotePropertyName held -NotePropertyValue ([pscustomobject]@{ operationId = 'op-0'; sinceUtc = '2026-10-24T08:00:00Z'; why = 'gave up' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        SvArm
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj')
        $r[0].Action | Should -Be 'ended'
        $job = (SvRecord).putBackJob
        $job.ended.reason | Should -Be 'gaveUp'
        $job.held.operationId | Should -Be 'op-0'
    }
    It 'a job that ended with an answer, whose last lines were both lost: the service ends the row, then removes the record' {
        SvSeed -Ended
        SvArm
        $r = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj')
        $r[0].Action | Should -Be 'ended'
        $script:svPosts.Count | Should -Be 0 -Because 'a job that ended is never started again'
        $fail = @(SvEvents | Where-Object { $_.step -eq 'engine:restore' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].correlationId | Should -Be 'op-1'
        $fail[0].detail | Should -Match 'its last line was not written.*Azure refused'
        (SvRecord).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
    It 'a job that ended and wrote its own last line: the record goes, and no second end line is written' {
        SvSeed -Ended -EndLine
        SvArm
        $null = Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj'
        @(SvEvents | Where-Object { $_.step -eq 'engine:restore' }).Count | Should -Be 0
        (SvRecord).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
    It 'a start Azure refuses is said on the machine and counted; it never stops the pass' {
        SvSeed
        SvArm
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw '400: The engine job is not ready.' }
        @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'rj') -RunId 'rj').Count | Should -Be 0
        $line = @(SvEvents | Where-Object { $_.step -eq 'resume' -and $_.outcome -eq 'fail' })[-1]
        $line.vmId | Should -Be $script:vmId
        $line.detail | Should -Match 'could not start it again: The engine job is not ready'
        (SvRecord).putBackJob.resumes | Should -Be 1
    }
    It 'a run with no open restore asks Azure nothing' {
        if (Test-Path $script:svStore) { Remove-Item $script:svStore -Recurse -Force }
        $rp = Join-Path $script:svStore 'rj'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Initialize-VmfRun -RunPath $rp -RunId 'rj' | Out-Null; New-VmfStateDoc -RunPath $rp -RunId 'rj' -VmId $id -Wave 'w1' | Out-Null }
        SvArm
        @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath $rp -RunId 'rj').Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfArmList -Times 0 -Exactly
    }
    It 'the timer runs it on every pass, after the wave resume and with its own record of a failure' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1')
        $code | Should -Match 'Invoke-VmfFacadeResumeStalledPutBacks -StorePath \$store -RunId \$runId'
        $code.IndexOf('Invoke-VmfFacadeResumeStalledPutBacks') | Should -BeGreaterThan $code.IndexOf('Invoke-VmfFacadeResumeStalledWaves')
        $code | Should -Match 'could not check for a restore that stopped part way'
    }
}

Describe 'RESTORE-END-JOB-1: the service refuses a second job, and only its timer resumes one' {
    BeforeAll {
        $script:sgStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rjg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:sgStore
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $rp = Join-Path $script:sgStore 'rj'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'rj' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rj' -VmId $id -Wave 'w1' | Out-Null
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ from = 'prepared'; diskNaming = 'new' } -Stamp '202610240900'
        }
        $script:sgPrincipal = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    AfterAll { if (Test-Path $script:sgStore) { Remove-Item $script:sgStore -Recurse -Force }; Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:sgPosts = 0
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'POST') { $script:sgPosts++; return [pscustomobject]@{ StatusCode = 202; Content = '{"name":"e"}' } }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{ name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfArmList { [pscustomobject]@{ Ok = $true; StatusCode = 200; Items = @() } }
    }
    It 'a restore, a rebuild and a finish of the machine are refused with the sentence, before a job starts' {
        foreach ($op in 'restore', 'finish') {
            { Invoke-VmfFacadeStartEngine -Principal $script:sgPrincipal -Operation $op -RunId 'rj' -VmId $script:vmId -Note 'again' } | Should -Throw '400: *did not finish: its job stopped part way*'
        }
        $script:sgPosts | Should -Be 0
    }
    It 'no request can claim to be the resume: the operation id is a module value only the timer sets, never a parameter' {
        $core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $fn = [regex]::Match($core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Not -Match '\[string\]\$Resume'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $code | Should -Not -Match '(?i)resume'
    }
}

Describe 'RESTORE-END-JOB-1: the engine and the contract' {
    It 'the engine starts the job it resumes with that job''s id - the start line, the lease and the fail line all carry it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        # FINISH-END-JOB-1: and a finish (FinishEndJob.Tests.ps1).
        $code | Should -Match "\`$resumeId = if \(\`$env:VMF_OPERATION -in @\('restore', 'finish'\) -and \`$env:VMF_RESUME_ID\)"
        $code | Should -Match 'if \(\$resumeId\) \{ \$engineRunId = \$resumeId \}'
        $code | Should -Match 'if \(\$resumeId\) \{ \$restoreParams\.Resume = \$true \}'
        $code.IndexOf('$engineRunId = $resumeId') | Should -BeLessThan $code.IndexOf("CorrelationId = `$engineRunId")
    }
    It 'vm-state v27 declares putBackJob, and the sample holds one that validates' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        @($schema.properties.putBackJob.properties.phase.enum) | Should -Be (InModuleScope VmMigrationFactory { $script:VmfPutBackJobPhases })
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).putBackJob.operationId | Should -Not -BeNullOrEmpty
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $bad = $sample -replace '"phase": "osSwapped"', '"phase": "somewhere"'
        Test-Json -Json $bad -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v26 -> v27 \(2026-10-24, RESTORE-END-JOB-1\)'
    }
    It 'a record the restore writes, with its checkpoint, validates against the schema at every step' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        RjMocks; RjAzure
        # REBUILD-REMOVE-RECOVER-1: in place - no restore rebuilds now.
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        $script:docsSeen = [System.Collections.Generic.List[string]]::new()
        try {
            Mock -ModuleName VmMigrationFactory Write-VmfStateDoc {
                $json = $Document | ConvertTo-Json -Depth 24
                if ($json -match '"putBackJob"') { $script:docsSeen.Add($json) }
                & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $d.vmId) + '.json') -Document $d } $RunPath $Document
            }
            $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'pristine'; naming = 'preserve' }
            $script:docsSeen.Count | Should -BeGreaterThan 5
            # The checkpoint against its own part of the schema: the rest of a
            # test record is not what this item changed.
            $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
            $part = [ordered]@{ '$schema' = 'https://json-schema.org/draft/2020-12/schema' }
            foreach ($p in $schema.properties.putBackJob.PSObject.Properties) { $part[$p.Name] = $p.Value }
            $partJson = $part | ConvertTo-Json -Depth 30
            foreach ($j in $script:docsSeen) { Test-Json -Json (($j | ConvertFrom-Json).putBackJob | ConvertTo-Json -Depth 24) -Schema $partJson | Should -BeTrue }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue; Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }
    }
}

# RESTORE-INLOOP-TEMP-1 (rule 4): keeping the names, the stopped window takes
# only LUNs whose temporary disk was made before the stop. A checkpoint that
# names no temporary disk for a LUN it restores is refused by the resume
# before it changes anything more; and if the stopped window is still given
# such a LUN, it changes no data disk and the machine stays stopped - never
# started with its OS disk from the copy and that data disk as it is now.
Describe 'RESTORE-INLOOP-TEMP-1: kill-resume, keeping the names, a checkpoint with no temporary disk for a LUN' {
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { } }
    AfterEach { Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }
    BeforeAll {
        # The checkpoint as a job that made no temporary disk for LUN 1 would leave it.
        $script:dropTemp1 = {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $global:fa.rp; id = $script:vmId } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $d.putBackJob.made.tempData.PSObject.Properties.Remove('1')
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
        }
    }

    It 'the uninterrupted run has a temporary disk for each LUN on its checkpoint (the premise of the two tests below)' {
        RjMocks; RjAzure
        $rp = RjRun -Doc (RjDoc -Path 'A')
        $global:fa.rp = $rp
        try {
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'VMF-TEST: stopped here to read the checkpoint' }
            try { $null = RjAct -Rp $rp -Opt @{ kind = 'restore'; from = 'pristine'; naming = 'preserve' } } catch { $null = $_ }
            $made = (RjRecord $rp).putBackJob.made
            @($made.tempData.PSObject.Properties.Name | Sort-Object) | Should -Be @('0', '1')
            @($made.dataPlan.Restore | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'killed after the stop: the resume refuses before it changes anything more, and names the LUN' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' }
        RjMocks
        $r = RjKillAndResume -Opt $opt -Site 'stop:after' -N 1 -BeforeResume $script:dropTemp1
        $r.Killed | Should -BeTrue
        $r.HadJob | Should -BeTrue
        $r.Error | Should -Match "'vm1-d1' on LUN 1"
        foreach ($site in 'size:before', 'swapOs:before', 'swapData:before', 'make:before', 'delete:before', 'start:before', 'attachEmpty:before') {
            @($r.SitesAfter) | Should -Not -Contain $site -Because "the resume refuses before any change ($site)"
        }
        $r.State | Should -Match '"data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None"'
    }

    It 'killed after the stop, and the stopped window is still given that LUN: it changes no data disk, and the machine stays STOPPED' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve' }
        RjMocks
        $r = RjKillAndResume -Opt $opt -Site 'stop:after' -N 1 -BeforeResume {
            & $script:dropTemp1
            Mock -ModuleName VmMigrationFactory Assert-VmfDataTempDisksMade { }
        }
        $r.Killed | Should -BeTrue
        $r.Error | Should -Match 'STOPPED'
        $r.Error | Should -Match 'LUN 1'
        $r.StartedAfter | Should -Be 0
        @($r.SitesAfter) | Should -Not -Contain 'swapData:before'
        @($r.SitesAfter) | Should -Not -Contain 'attachEmpty:before'
        $r.State | Should -Match '"power":"deallocated"'

        $r.State | Should -Match '0=vm1-d0/ReadWrite,1=vm1-d1/None' -Because 'no data disk changed'
    }
}

# PRESERVE-USED-MARK-1: Restore this machine marked the disks made for the way
# back that it put on the machine only once the data restore had returned. A
# process that stopped between a data disk swap that took and that mark left a
# disk on the machine with no mark - and once the job ended, the daily cleanup
# listed it as unused (Get-VmfDueRollbackDisksBeforeMove). Each disk is marked the moment
# its swap takes, inside the data restore, as the rollback does per batch
# (Invoke-VmfDataSwapBatches).
Describe 'PRESERVE-USED-MARK-1: a rollback disk is marked used the moment its data disk swap takes (rule 4)' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        RjMocks
        # The line the data restore writes after a swap that took, with new
        # names, is a kill point: nothing else stands between the swap and the
        # end of the data restore.
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine -ParameterFilter { $Detail -like 'The data disks were restored from the safety copy:*' } { Global:RjKill 'line:dataRestored' }
    }
    AfterEach {
        Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable pumAtKill, pumOnAtKill -Scope Global -ErrorAction SilentlyContinue
    }

    It '<Naming>: killed at the first step after a data disk swap took, each rollback disk that is on the machine is marked used, no other is, and the daily cleanup never lists it' -ForEach @(
        @{ Naming = 'preserve' }, @{ Naming = 'new' }) {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = $Naming; putBack = $true }
        $ref = RjReference -Opt $opt
        $points = @($ref.Points)
        $first = -1
        for ($i = 0; $i -lt $points.Count; $i++) { if ($points[$i].site -eq 'swapData:after') { $first = $i; break } }
        $first | Should -BeGreaterOrEqual 0 -Because 'the restore swaps a data disk'
        $next = $points[$first + 1]
        $r = RjKillAndResume -Opt $opt -Site $next.site -N $next.n -BeforeResume {
            # What a new container finds: the store and Azure at the kill.
            $global:pumAtKill = Global:RjRecord $global:fa.rp
            $global:pumOnAtKill = @($global:fa.vm.data.Values | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
        $r.Killed | Should -BeTrue
        $pb = @($global:pumAtKill.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -ne $_.lun })
        $on = @($pb | Where-Object { [string]$_.diskId -in $global:pumOnAtKill })
        $on.Count | Should -BeGreaterThan 0 -Because "a rollback disk is on the machine at the kill ($($next.site) #$($next.n))"
        foreach ($d in $on) {
            [string]$d.usedUtc | Should -Not -BeNullOrEmpty -Because "the disk '$($d.diskName)' is on the machine"
            $d.usedBy | Should -Be 'restore'
        }
        foreach ($d in @($pb | Where-Object { [string]$_.diskId -notin $global:pumOnAtKill })) {
            [string]$d.usedUtc | Should -BeNullOrEmpty -Because "the disk '$($d.diskName)' was never on the machine: the record agrees with the machine"
        }
        # The job ends without its resume (a failure it says): the hold goes,
        # and the daily cleanup reads the record as the kill left it.
        $ended = $global:pumAtKill
        $ended.putBackJob | Add-Member -NotePropertyName ended -NotePropertyValue ([pscustomobject]@{ outcome = 'fail'; reason = 'failed' }) -Force
        $due = @(InModuleScope VmMigrationFactory -Parameters @{ d = $ended } { param($d) Get-VmfDueRollbackDisksBeforeMove -StateDocs @($d) })
        $dueIds = @($due | ForEach-Object { @($_.Disks) } | ForEach-Object { [string]$_.diskId })
        foreach ($d in $on) { $dueIds | Should -Not -Contain ([string]$d.diskId) -Because "the disk '$($d.diskName)' is on the machine" }
        # And the resume ends where the uninterrupted run ended.
        $r.Error | Should -BeNullOrEmpty
        $r.State | Should -Be $ref.State
    }

    It 'keeping the names: Azure took the swap and the job stopped before it heard - the resume marks the disk used before it changes anything more' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve'; putBack = $true }
        $r = RjKillAndResume -Opt $opt -Site 'swapData:after' -N 1 -BeforeResume {
            # The resume dies at its first change after it: the delete of the
            # disk LUN 0 had, which frees its name.
            $global:fa.seen = @{}
            $global:fa.killAt = @{ site = 'delete:before'; n = 1 }
        } -AfterResume { param($rp) Global:RjRecord "$rp.snap" }
        $r.Killed | Should -BeTrue
        $r.After | Should -Not -BeNullOrEmpty -Because 'the resume was killed at the delete'
        $d0 = @($r.After.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -ne $_.lun -and [int]$_.lun -eq 0 })[0]
        [string]$d0.usedUtc | Should -Not -BeNullOrEmpty -Because 'LUN 0 runs on it'
        $d1 = @($r.After.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -ne $_.lun -and [int]$_.lun -eq 1 })[0]
        [string]$d1.usedUtc | Should -BeNullOrEmpty -Because 'LUN 1 is not swapped yet'
    }

    It 'new names: a swap that took on one LUN and stopped with an error - killed at the next step, the disk on that LUN is marked used and the disk Azure did not swap is not' {
        $opt = @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'new'; putBack = $true }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine -ParameterFilter { $Detail -like 'The data disk swap took on some LUNs and not others*' } { Global:RjKill 'line:partial' }
        # Azure puts the first LUN of the batch on its disk, then stops.
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            Global:RjKill 'swapData:before'
            $s = @($Swaps | Sort-Object { [int]$_.lun })[0]
            $global:fa.vm.data["$([int]$s.lun)"] = [string]$s.diskId
            throw 'BadRequest: the update stopped part way'
        }
        RjAzure -PutBack
        $rp = RjRun -Doc (RjDoc -Path 'A' -PutBack)
        $global:fa.rp = $rp
        $global:fa.killAt = @{ site = 'line:partial'; n = 1 }
        try {
            try { $null = RjAct -Rp $rp -Opt $opt } catch { $null = $_ }
            $global:fa.snap | Should -Not -BeNullOrEmpty -Because 'the kill happened at the line after the swap'
            $atKill = Global:RjRecord "$rp.snap"
            $pb = @($atKill.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -ne $_.lun })
            $d0 = @($pb | Where-Object { [int]$_.lun -eq 0 })[0]
            $d1 = @($pb | Where-Object { [int]$_.lun -eq 1 })[0]
            $global:fa.snap.vm.data['0'] | Should -Be ([string]$d0.diskId)
            [string]$d0.usedUtc | Should -Not -BeNullOrEmpty -Because 'LUN 0 runs on it'
            $d0.usedBy | Should -Be 'restore'
            [string]$d1.usedUtc | Should -BeNullOrEmpty -Because 'Azure did not swap it onto LUN 1'
        }
        finally {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeping the names, with the rollback disks: every kill point resumes to the same machine, and the resume never makes a disk' {
        $r = RjEveryKill -Opt @{ kind = 'restore'; path = 'A'; from = 'pristine'; naming = 'preserve'; putBack = $true }
        $r.Checked | Should -BeGreaterThan 10
        $r.Bad | Should -BeNullOrEmpty
    }
}

# RESTORE-ORIGINAL-DELETE-RESTART-1 (decision 2026-11-11, option A):
# keeping the names, the restore puts the machine on a temporary OS disk made
# from the copy, then deletes the original OS disk to free its name. The lock
# check before the stop can pass and Azure can still refuse that delete. The
# restore then started the machine on the temporary disk - the copy's moment -
# with the data disks of now: two moments. Now the original OS disk, which
# Azure did not delete, goes back on the machine, the data disks are not
# touched, the machine starts as it was, the temporary disks made for this
# restore are deleted, and the record says the restore did not happen.
Describe 'RESTORE-ORIGINAL-DELETE-RESTART-1: Azure refuses the delete of the original OS disk' {
    BeforeEach { Mock -ModuleName VmMigrationFactory Write-Warning { } }
    AfterEach { Remove-Variable fa -Scope Global -ErrorAction SilentlyContinue }
    BeforeAll {
        $script:rokWords = "The restore did not happen: Azure refused to delete the OS disk 'vm1-os': ScopeLocked: the disk 'vm1-os' is locked. The machine has its OS disk 'vm1-os' and its data disks again, as before the restore."
        # The machine as it was before the restore, with the disks in Azure.
        $script:rokAsBefore = '{"exists":true,"size":"Standard_D2ds_v6","controller":"NVMe","power":"running","os":"vm1-os","data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None","disks":"added-later,vm1-d0,vm1-d1,vm1-os","nic":true}'
        # One run of the restore, with the deletes Azure refuses. Returns where
        # it ended, what it said, and every kill point it passed.
        function Global:RokRun {
            param([hashtable]$Opt, [string[]]$Refuse = @('vm1-os'), [switch]$RefuseOsBack)
            RjAzure -PutBack:([bool]$Opt.putBack)
            $global:fa.refuseDelete = $Refuse
            $global:fa.refuseOsBack = [bool]$RefuseOsBack
            $rp = RjRun -Doc (RjDoc -Path 'A' -PutBack:([bool]$Opt.putBack))
            $global:fa.rp = $rp
            try {
                $err = $null
                try { $null = RjAct -Rp $rp -Opt $Opt } catch { $err = $_.Exception.Message }
                $points = [System.Collections.Generic.List[object]]::new()
                $count = @{}
                foreach ($s in $global:fa.sites) { $count[$s] = 1 + [int]$count[$s]; $points.Add([pscustomobject]@{ site = $s; n = $count[$s] }) }
                [pscustomobject]@{ State = (RjState); Creates = $global:fa.creates; Error = $err; Points = @($points); Sites = @($global:fa.sites)
                    Record = (RjRecord $rp); Events = @(RjEvents $rp) }
            }
            finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Every kill point of that run, each resumed as the service does.
        function Global:RokEveryKill {
            param([hashtable]$Opt, [string[]]$Refuse = @('vm1-os'))
            RjMocks
            $ref = RokRun -Opt $Opt -Refuse $Refuse
            $initial = $null
            $bad = [System.Collections.Generic.List[string]]::new()
            $checked = 0
            foreach ($pt in $ref.Points) {
                RjAzure -PutBack:([bool]$Opt.putBack)
                $global:fa.refuseDelete = $Refuse
                $rp = RjRun -Doc (RjDoc -Path 'A' -PutBack:([bool]$Opt.putBack))
                $global:fa.rp = $rp
                if (-not $initial) { $initial = RjState }
                $global:fa.killAt = @{ site = $pt.site; n = $pt.n }
                $where = "killed at $($pt.site) #$($pt.n)"
                try {
                    try { $null = RjAct -Rp $rp -Opt $Opt } catch { $null = $_ }
                    if (-not $global:fa.snap) { $bad.Add("${where}: the kill did not happen"); continue }
                    RjRevive $rp
                    $hadJob = [bool](RjRecord $rp).PSObject.Properties['putBackJob']
                    $err = $null
                    try { $null = RjAct -Rp $rp -Opt $Opt -Resume } catch { $err = $_.Exception.Message }
                    $checked++
                    $state = RjState
                    if (-not $hadJob) {
                        if ($state -ne $initial) { $bad.Add("${where}: before the checkpoint, the machine changed: $state") }
                        continue
                    }
                    if ($state -ne $ref.State) { $bad.Add("${where}: ended $state, not $($ref.State)") }
                    if ($global:fa.creates -ne $ref.Creates) { $bad.Add("${where}: $($global:fa.creates) disks made in all, the uninterrupted run made $($ref.Creates)") }
                    $norm = { param($s) ([string]$s) -replace '\d{12}', 'STAMP' }
                    if ((& $norm $err) -ne (& $norm $ref.Error)) { $bad.Add("${where}: the resume said '$err', not '$($ref.Error)'") }
                    $rec = RjRecord $rp
                    if ($rec.PSObject.Properties['restore']) { $bad.Add("${where}: a restore record was written") }
                    if (-not $rec.putBackJob.ended) { $bad.Add("${where}: the checkpoint is not marked ended") }
                    if (@($global:fa.sites | Where-Object { $_ -eq 'swapData:before' }).Count) { $bad.Add("${where}: a data disk was swapped") }
                }
                finally {
                    Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            [pscustomobject]@{ Bad = @($bad); Checked = $checked; Reference = $ref }
        }
    }
    AfterAll { Remove-Item function:RokRun, function:RokEveryKill -ErrorAction SilentlyContinue }

    It 'the original OS disk goes back, the data disks are not touched, the machine starts as it was, the temporary disks are deleted, and the record says the restore did not happen' {
        RjMocks
        $script:rokStarts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            Global:RjKill 'start:before'
            $script:rokStarts.Add([string]$global:fa.disks[$global:fa.vm.os].name)
            $global:fa.vm.power = 'running'
        }
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $r.Error | Should -Be $script:rokWords
        $r.State | Should -Be $script:rokAsBefore -Because 'the machine is as it was, and every temporary disk is deleted'
        @($script:rokStarts) | Should -Be @('vm1-os') -Because 'the machine starts once, on its own OS disk - never on the temporary disk'
        $r.Creates | Should -Be 3 -Because 'the temporary OS disk and one temporary disk for each data disk were made before the stop'
        @($r.Sites | Where-Object { $_ -eq 'swapData:before' }) | Should -BeNullOrEmpty -Because 'no data disk is touched'
        @($r.Sites | Where-Object { $_ -eq 'make:before' }).Count | Should -Be 3 -Because 'no disk is made under the original name'
        $r.Record.PSObject.Properties['restore'] | Should -BeNullOrEmpty -Because 'the restore did not happen'
        $r.Record.putBackJob.ended.why | Should -Be $script:rokWords
        $r.Record.putBackJob.phase | Should -Be 'originalStarted'
        $r.Record.putBackJob.originalKept.why | Should -Be "ScopeLocked: the disk 'vm1-os' is locked."
        $fail = @($r.Events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'fail' })
        $fail | Should -HaveCount 1
        $fail[0].detail | Should -Be $script:rokWords
        @($r.Events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'ok' }) | Should -BeNullOrEmpty
        # MADE-DISK-RECORD-1: each temporary disk deleted is marked, so no later
        # restore names it as a disk that costs money.
        @($r.Record.restoreDisks).Count | Should -Be 3
        @($r.Record.restoreDisks | Where-Object { -not $_.deletedUtc }) | Should -BeNullOrEmpty
    }

    It 'a temporary disk Azure does not delete is said with the words of the temporary disk warning, and the machine still runs on its own disks' {
        RjMocks
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' } -Refuse @('vm1-os', '*-rtmp-*')
        $r.State | Should -Match '"power":"running","os":"vm1-os","data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None"'
        foreach ($t in @('vm1-os-rtmp-', 'vm1-d0-d0-rtmp-', 'vm1-d1-d1-rtmp-')) {
            $r.Error | Should -Match ([regex]::Escape(" The temporary disk '$t") + '\d{12}' + [regex]::Escape("' is not attached and was not deleted: ScopeLocked: the disk '$t") + '\d{12}' + [regex]::Escape("' is locked. Delete it when you are sure."))
            @($r.Events | Where-Object { $_.outcome -eq 'warn' -and [string]$_.detail -like "The temporary disk '$t*' is not attached and was not deleted: ScopeLocked*Delete it when you are sure." }) | Should -HaveCount 1 -Because $t
        }
        $r.Error | Should -BeLike "$($script:rokWords) The temporary disk*"
        $r.Record.putBackJob.ended.why | Should -Be $r.Error
        @($r.Record.restoreDisks | Where-Object { $_.deletedUtc }) | Should -BeNullOrEmpty -Because 'no temporary disk was deleted'
    }

    It 'Azure refuses to put the original OS disk back: the machine is never started on the temporary disk, it stays STOPPED, and the words say which disk to attach' {
        RjMocks
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' } -RefuseOsBack
        $r.State | Should -Match '"power":"deallocated","os":"vm1-os-rtmp-STAMP","data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None"'
        @($r.Sites | Where-Object { $_ -eq 'start:before' }) | Should -BeNullOrEmpty
        $r.Error | Should -Match ('^' + [regex]::Escape("The restore did not happen. Azure refused to delete the OS disk 'vm1-os': ScopeLocked: the disk 'vm1-os' is locked. Azure also refused to put the OS disk 'vm1-os' back: OperationNotAllowed: Azure refused the OS disk swap. The machine is stopped on the temporary disk 'vm1-os-rtmp-") + '\d{12}' +
            [regex]::Escape("'. The data disks are as before. Attach the OS disk 'vm1-os' to the machine before you start it.") + '$')
        $r.State | Should -Match '"disks":"added-later,vm1-d0,vm1-d1,vm1-os,vm1-os-rtmp-STAMP"' -Because 'the temporary disk the machine is on is not deleted, and the temporary data disks are'
        @($r.Events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'fail' }) | Should -HaveCount 1
        $r.Record.putBackJob.ended.why | Should -Be $r.Error
    }

    It 'Azure refuses to start the machine on its own disks: the words say it is not running, and the temporary disks are deleted' {
        RjMocks
        Mock -ModuleName VmMigrationFactory Start-VmfVm { Global:RjKill 'start:before'; throw 'AllocationFailed: no capacity.' }
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $r.Error | Should -Be ("$($script:rokWords) Azure did not start the machine, so it is not running and needs attention: AllocationFailed: no capacity.")
        $r.State | Should -Match '"power":"deallocated","os":"vm1-os"'
        $r.State | Should -Match '"disks":"added-later,vm1-d0,vm1-d1,vm1-os"'
        @($r.Sites | Where-Object { $_ -eq 'start:before' }).Count | Should -Be 1 -Because 'the restore does not start it a second time on any disk'
    }

    It 'a lost hold of the machine while the original OS disk is deleted changes nothing more' {
        RjMocks
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { if ($DiskName -eq 'vm1-os') { throw 'Lease lost: abandon this VM.' } }
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $r.Error | Should -BeLike '*abandon this VM*'
        @($r.Sites | Where-Object { $_ -eq 'start:before' -or $_ -eq 'swapOs:before' }).Count | Should -Be 1 -Because 'only the swap onto the temporary disk happened'
    }

    It 'the second copy: every kill point resumes to the machine as it was, says the same words, and makes no disk' {
        $k = RokEveryKill -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $k.Reference.State | Should -Be $script:rokAsBefore
        $k.Reference.Error | Should -Be $script:rokWords
        $k.Checked | Should -BeGreaterThan 15
        $k.Bad | Should -BeNullOrEmpty
    }

    It 'with the rollback disks: the temporary OS disk is deleted, the data rollback disks are kept unused, and every kill point resumes to the same machine' {
        $k = RokEveryKill -Opt @{ kind = 'restore'; from = 'pristine'; naming = 'preserve'; putBack = $true }
        $k.Reference.Error | Should -BeLike "$($script:rokWords)*"
        $k.Reference.Creates | Should -Be 0
        $k.Reference.State | Should -Match '"os":"vm1-os","data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None"'
        $k.Reference.State | Should -Match '"disks":"added-later,vm1-d0,vm1-d0-d0-asitwas-STAMP,vm1-d1,vm1-d1-d1-asitwas-STAMP,vm1-os"'
        $os = @($k.Reference.Record.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -eq $_.lun })[0]
        [string]$os.usedUtc | Should -Not -BeNullOrEmpty -Because 'the machine ran on it while the name was to be freed'
        @($k.Reference.Record.safety.rollbackDisksBeforeMove.disks | Where-Object { $null -ne $_.lun -and $_.usedUtc }) | Should -BeNullOrEmpty
        $k.Checked | Should -BeGreaterThan 10
        $k.Bad | Should -BeNullOrEmpty
    }

    It 'POWER-AFTER-MOVE-1: a machine the restore found Stopped (deallocated) is started on its own disks, then deallocated again, and the words say so' {
        RjMocks
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $r.State | Should -Match '"power":"deallocated","os":"vm1-os","data":"0=vm1-d0/ReadWrite,1=vm1-d1/None,5=added-later/None","disks":"added-later,vm1-d0,vm1-d1,vm1-os"'
        @($r.Sites | Where-Object { $_ -eq 'start:before' }).Count | Should -Be 1
        $r.Error | Should -BeLike "$($script:rokWords) ?*"
        $r.Error.Length | Should -BeGreaterThan $script:rokWords.Length -Because 'the words of the return to the power state follow'
    }
    # Step 3 of the item: the delete of each original DATA disk. The LUN runs on
    # its temporary disk (the copy) when Azure refuses it, and the restore
    # stops there (stopHere): every later LUN is left on record and the machine
    # stays stopped - never started with data disks from two moments.
    It 'the delete of an original data disk that is not the last is refused: the machine stays STOPPED, and the later LUN is on record' {
        RjMocks
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' } -Refuse @('vm1-d0')
        $r.State | Should -Match '"power":"deallocated","os":"vm1-os","data":"0=vm1-d0-d0-rtmp-STAMP/ReadWrite,1=vm1-d1/None,5=added-later/None"'
        @($r.Sites | Where-Object { $_ -eq 'start:before' }) | Should -BeNullOrEmpty
        @($r.Record.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(1)
    }
    It 'the delete of the last original data disk is refused: that LUN runs on its temporary disk, so every disk is from the copy, and the machine starts' {
        RjMocks
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' } -Refuse @('vm1-d1')
        $r.State | Should -Match '"power":"running","os":"vm1-os","data":"0=vm1-d0/ReadWrite,1=vm1-d1-d1-rtmp-STAMP/None,5=added-later/None"'
        @($r.Record.restore.dataDisksKept | ForEach-Object { [int]$_.lun }) | Should -Contain 1
    }

    It 'vm-state v43 declares originalKept and the steps of the way back; the checkpoint the way back writes validates; the migration note says it' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $kept = $schema.properties.putBackJob.properties.originalKept
        @($kept.required) | Should -Be @('why')
        $kept.additionalProperties | Should -BeFalse
        foreach ($phase in 'originalKept', 'originalBack', 'originalStarted') { @($schema.properties.putBackJob.properties.phase.enum) | Should -Contain $phase }
        RjMocks
        $r = RokRun -Opt @{ kind = 'restore'; from = 'prepared'; naming = 'preserve' }
        $part = [ordered]@{ '$schema' = 'https://json-schema.org/draft/2020-12/schema' }
        foreach ($p in $schema.properties.putBackJob.PSObject.Properties) { $part[$p.Name] = $p.Value }
        Test-Json -Json ($r.Record.putBackJob | ConvertTo-Json -Depth 24) -Schema ($part | ConvertTo-Json -Depth 30) | Should -BeTrue
        $r.Record.schemaVersion | Should -Be 51
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## vm-state v42 -> v43 \(2026-11-12, RESTORE-ORIGINAL-DELETE-RESTART-1\)'
        $notes | Should -Match 'originalKept'
    }
}
