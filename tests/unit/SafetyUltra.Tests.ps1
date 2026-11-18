#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-ULTRA-1: a failed move puts back Premium SSD v2 and Ultra Disk data
# disks from their safety copies, like every other disk.
#
# SAFETY-ALL-1 took their copies and then LEFT these disks on a put-back: a new
# disk of these types needs IOPS and throughput the capture did not hold, and a
# copy of them cannot make a disk until Azure has copied it in the background.
# The rule of 2026-10-10: a machine must always go back fully to its safety copies.
# Measured in the lab the same day: an instant access copy of both types on a
# stopped machine, a disk made from it at once (Ultra Disk too), the values and
# sector size kept, the two-update swap accepted, the data exactly as copied.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    # PRECHECK-WORKLOAD-1: Checking reads the maxShares of each data disk; none is shared here.
    Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
    # This file mocks Start-Sleep inside some tests, and the guard leaves the
    # module's waiting alone in a file that does (CI-SPEED-1). So every test
    # starts from a mock that does not wait; a test's own mock wins over it.
    # Invoke-AzRestMethod needs nothing here since TEST-AZURE-GUARD-1: the
    # guard blocks it in every test, whatever one test mocks.
    Mock -ModuleName VmMigrationFactory Start-Sleep { }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"

    # One machine in zone 1: an OS disk and three data disks - Premium SSD on
    # LUN 0, Premium SSD v2 (512-byte sectors) on LUN 1, Ultra Disk (4096) on
    # LUN 2 - with the values PRECHECK records, and every first copy on record.
    function Global:UlDisks([switch]$NoFacts) {
        $f = { param($iops, $mbps, $sector) if ($NoFacts) { @{} } else { @{ diskIOPSReadWrite = $iops; diskMBpsReadWrite = $mbps; logicalSectorSize = $sector; diskZones = @('1'); maxShares = 1; completionPercent = 100 } } }
        @(
            [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$($script:sub)/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' }
            ([pscustomobject](@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$($script:sub)/disks/vm1-data1"; caching = 'None'; sizeGB = 16; skuName = 'PremiumV2_LRS' } + (& $f 5000 200 512)))
            ([pscustomobject](@{ name = 'vm1-data2'; lun = 2; managedDiskId = "$($script:sub)/disks/vm1-data2"; caching = 'None'; sizeGB = 8; skuName = 'UltraSSD_LRS' } + (& $f 3000 150 4096)))
        )
    }
    function Global:UlNewRun([switch]$NoCopies, [switch]$NoFacts, [string]$State = 'PLANNED') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ul-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; noCopies = [bool]$NoCopies; disks = (UlDisks -NoFacts:$NoFacts); st = $State } {
            param($rp, $id, $sub, $noCopies, $disks, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'ul' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'ul' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.state = $st
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'
                        zones = @('1'); ultraSsdEnabled = $true
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" }
                        dataDisks = $disks; nics = @(); tags = @{} } }) -Force
            $safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true }
            if (-not $noCopies) {
                $safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue "$sub/snapshots/vm1-pristine" -Force
                $safety | Add-Member -NotePropertyName pristineSnapshotLocked -NotePropertyValue $true -Force
                $safety | Add-Member -NotePropertyName pristineDataCopies -NotePropertyValue @(
                    [pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true }
                    [pscustomobject]@{ lun = 1; diskId = "$sub/disks/vm1-data1"; snapshotId = "$sub/snapshots/vm1-pristine-d1"; locked = $true; instantAccessMinutes = 300; takenUtc = '2026-10-10T12:00:00Z' }
                    [pscustomobject]@{ lun = 2; diskId = "$sub/disks/vm1-data2"; snapshotId = "$sub/snapshots/vm1-pristine-d2"; locked = $true; instantAccessMinutes = 300; takenUtc = '2026-10-10T12:00:00Z' }) -Force
            }
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:UlCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'; assessment = [pscustomobject]@{ os = 'Linux'; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'ul'
        }
    }
    function Global:UlDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:UlLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:UlDrop($rp) { if ($rp -and (Test-Path $rp)) { [System.IO.Directory]::Delete($rp, $true) } }
    # What Azure says about a copy: a state, and minutes since it was made.
    function Global:UlAccess([string]$State, [double]$AgoMinutes = 5, $Minutes = 300) {
        [pscustomobject]@{ snapshotAccessState = $State; completionPercent = $(if ($State -like 'Available*') { 100 } else { 20 })
            instantAccessDurationMinutes = $Minutes; timeCreated = (Get-Date).ToUniversalTime().AddMinutes(-$AgoMinutes).ToString('o') }
    }
    # What Azure says about a disk it made: matching the record unless told.
    function Global:UlFacts($DiskId, [hashtable]$Change = @{}) {
        $isUltra = [string]$DiskId -match 'vm1-data2'
        $f = [ordered]@{ id = $DiskId; skuName = $(if ($isUltra) { 'UltraSSD_LRS' } else { 'PremiumV2_LRS' })
            diskSizeGB = $(if ($isUltra) { 8 } else { 16 }); diskIOPSReadWrite = $(if ($isUltra) { 3000 } else { 5000 })
            diskMBpsReadWrite = $(if ($isUltra) { 150 } else { 200 }); logicalSectorSize = $(if ($isUltra) { 4096 } else { 512 })
            zones = @('1'); maxShares = 1; completionPercent = 100; provisioningState = 'Succeeded'
            # SAFETY-CMK-1: PRECHECK reads every disk's encryption with the same call.
            encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null }
        foreach ($k in $Change.Keys) { $f[$k] = $Change[$k] }
        [pscustomobject]$f
    }
}
AfterAll {
    Remove-Item function:UlDisks, function:UlNewRun, function:UlCtx, function:UlDoc, function:UlLog, function:UlDrop, function:UlAccess, function:UlFacts -ErrorAction SilentlyContinue
}

Describe 'SAFETY-ULTRA-1: the Azure boundary' {
    BeforeEach { $global:ulRest = [System.Collections.Generic.List[object]]::new() }
    AfterEach { Remove-Variable ulRest -Scope Global -ErrorAction SilentlyContinue }

    It 'reads a disk by its id, at the instant access api version, and an absent value is null - never 0' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:ulRest.Add("$Method $Path")
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'd'; sku = @{ name = 'PremiumV2_LRS' }; zones = @('1')
                        properties = @{ diskSizeGB = 16; diskIOPSReadWrite = 5000; creationData = @{ logicalSectorSize = 512 }; completionPercent = 100; provisioningState = 'Succeeded' } } | ConvertTo-Json -Depth 6) }
        }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/disks/vm1-data1" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $global:ulRest[0] | Should -Be "GET $($script:sub)/disks/vm1-data1?api-version=2025-01-02"
        $f.diskIOPSReadWrite | Should -Be 5000
        $f.diskMBpsReadWrite | Should -BeNullOrEmpty -Because 'Azure returned no throughput, and a 0 would make the disk with 0'
        $f.logicalSectorSize | Should -Be 512
        $f.diskSizeGB | Should -Be 16
        @($f.zones) | Should -Be @('1')
        $f.maxShares | Should -Be 1
    }

    It 'reads a copy''s access state, and gives its time as ISO 8601 UTC whatever ConvertFrom-Json made of it' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{"id":"s","properties":{"provisioningState":"Succeeded","snapshotAccessState":"InstantAccess","completionPercent":12.5,"timeCreated":"2026-10-10T12:00:00.1234567+00:00","creationData":{"createOption":"Copy","sourceResourceId":"d1","instantAccessDurationMinutes":300}}}' }
        }
        $a = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/snapshots/s" } { param($id) Get-VmfSnapshotAccess -SnapshotId $id }
        $a.snapshotAccessState | Should -Be 'InstantAccess'
        $a.instantAccessDurationMinutes | Should -Be 300
        $a.timeCreated | Should -Be '2026-10-10T12:00:00Z'
        $a.sourceResourceId | Should -Be 'd1'
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = 'gone' } }
        { InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/snapshots/s" } { param($id) Get-VmfSnapshotAccess -SnapshotId $id } } | Should -Throw '*404*'
    }

    It 'takes the instant access copy: incremental, a copy of the disk, the minutes asked - and waits until Azure says it succeeded' {
        $global:ulGets = 0
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:ulRest.Add([pscustomobject]@{ Method = $Method; Path = $Path; Payload = $Payload })
            if ($Method -eq 'PUT') { return [pscustomobject]@{ StatusCode = 202; Content = '' } }
            $global:ulGets++
            if ($global:ulGets -eq 1) { return [pscustomobject]@{ StatusCode = 404; Content = 'not found' } }
            $state = if ($global:ulGets -eq 2) { 'Creating' } else { 'Succeeded' }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'x'; tags = @{ vmfSafetyCopy = 'true' }; properties = @{ provisioningState = $state } } | ConvertTo-Json -Depth 5) }
        }
        $id = InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data1" } {
            param($d) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'vm1-vmf-ul-pristine-d1' -DiskId $d -Location 'centralus' -Minutes 300 -Tags @{ vmfSafetyCopy = 'true' } -PollSeconds 0
        }
        $id | Should -Be "$($script:sub)/snapshots/vm1-vmf-ul-pristine-d1"
        $put = @($global:ulRest | Where-Object Method -EQ 'PUT')
        $put.Count | Should -Be 1
        $put[0].Path | Should -Match '/snapshots/vm1-vmf-ul-pristine-d1\?api-version=2025-01-02$'
        $body = $put[0].Payload | ConvertFrom-Json
        $body.properties.incremental | Should -BeTrue
        $body.properties.creationData.createOption | Should -Be 'Copy'
        $body.properties.creationData.sourceResourceId | Should -Be "$($script:sub)/disks/vm1-data1"
        $body.properties.creationData.instantAccessDurationMinutes | Should -Be 300
        $body.tags.vmfSafetyCopy | Should -Be 'true'
        $global:ulGets | Should -Be 3 -Because 'one read before, and reads until Succeeded'
        Remove-Variable ulGets -Scope Global
    }

    It 'STOP AND RESUME: a copy Azure made before the record is returned by its name - never taken twice' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:ulRest.Add($Method)
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'x'; properties = @{ provisioningState = 'Succeeded'; creationData = @{ sourceResourceId = "$($script:sub)/disks/vm1-data1" } } } | ConvertTo-Json -Depth 5) }
        }
        $id = InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data1" } {
            param($d) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'vm1-vmf-ul-pristine-d1' -DiskId $d -Location 'centralus'
        }
        $id | Should -Match '/snapshots/vm1-vmf-ul-pristine-d1$'
        @($global:ulRest) | Should -Be @('GET')
    }

    It 'a copy of that name of ANOTHER disk is refused, never used' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'x'; properties = @{ provisioningState = 'Succeeded'; creationData = @{ sourceResourceId = 'another-disk' } } } | ConvertTo-Json -Depth 5) }
        }
        { InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data1" } {
                param($d) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'n' -DiskId $d -Location 'centralus' } } | Should -Throw '*another-disk*'
    }

    It 'a copy Azure refuses throws - it is the way back' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            if ($Method -eq 'GET') { return [pscustomobject]@{ StatusCode = 404; Content = '' } }
            [pscustomobject]@{ StatusCode = 409; Content = 'OperationNotAllowed' }
        }
        { InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data1" } {
                param($d) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'n' -DiskId $d -Location 'centralus' } } | Should -Throw '*refused the instant access copy*OperationNotAllowed*'
    }

    It 'a disk is made with the IOPS and throughput given, and an ordinary disk with neither' {
        $global:ulCfg = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $null }
        Mock -ModuleName VmMigrationFactory New-AzDiskConfig { $global:ulCfg.Add($PesterBoundParameters); [pscustomobject]@{} }
        Mock -ModuleName VmMigrationFactory New-AzDisk { [pscustomobject]@{ Id = "/disks/$DiskName" } }
        InModuleScope VmMigrationFactory {
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s' -Location 'centralus' -SkuName 'PremiumV2_LRS' -Zone '1' -DiskIopsReadWrite 5000 -DiskMBpsReadWrite 200 | Out-Null
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'b' -SnapshotId '/s' -Location 'centralus' -SkuName 'Premium_LRS' -Zone '1' | Out-Null
        }
        $global:ulCfg[0].DiskIOPSReadWrite | Should -Be 5000
        $global:ulCfg[0].DiskMBpsReadWrite | Should -Be 200
        $global:ulCfg[0].SkuName | Should -Be 'PremiumV2_LRS'
        @($global:ulCfg[0].Zone) | Should -Be @('1')
        $global:ulCfg[1].ContainsKey('DiskIOPSReadWrite') | Should -BeFalse
        $global:ulCfg[1].ContainsKey('DiskMBpsReadWrite') | Should -BeFalse
        Remove-Variable ulCfg -Scope Global
    }

    It 'a swap that names its caching attaches with it (None for these types), and one that does not keeps the caching the LUN had' {
        $global:ulVm = [pscustomobject]@{ StorageProfile = [pscustomobject]@{ DataDisks = [System.Collections.Generic.List[object]]::new() } }
        $global:ulVm.StorageProfile.DataDisks.Add([pscustomobject]@{ Lun = 1; Name = 'old1'; Caching = 'ReadOnly'; ManagedDisk = [pscustomobject]@{ Id = '/old1' }; WriteAcceleratorEnabled = $false; DeleteOption = 'Detach' })
        $global:ulVm.StorageProfile.DataDisks.Add([pscustomobject]@{ Lun = 2; Name = 'old2'; Caching = 'ReadOnly'; ManagedDisk = [pscustomobject]@{ Id = '/old2' }; WriteAcceleratorEnabled = $false; DeleteOption = 'Detach' })
        $global:ulAttach = @{}
        Mock -ModuleName VmMigrationFactory Get-AzVM { $global:ulVm }
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' { }
        Mock -ModuleName VmMigrationFactory Add-AzVMDataDisk -RemoveParameterType 'VM' {
            $global:ulAttach[[int]$Lun] = $Caching
            $VM.StorageProfile.DataDisks.Add([pscustomobject]@{ Lun = $Lun; Name = $Name; Caching = $Caching; ManagedDisk = [pscustomobject]@{ Id = $ManagedDiskId } })
            $VM
        }
        $r = InModuleScope VmMigrationFactory {
            Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @(
                [pscustomobject]@{ lun = 1; diskId = '/new1'; diskName = 'new1'; caching = 'None' }
                [pscustomobject]@{ lun = 2; diskId = '/new2'; diskName = 'new2' })
        }
        $r.Applied | Should -BeTrue
        $global:ulAttach[1] | Should -Be 'None'
        $global:ulAttach[2] | Should -Be 'ReadOnly'
        Remove-Variable ulVm, ulAttach -Scope Global
    }
}

Describe 'SAFETY-ULTRA-1: PRECHECK records each Premium SSD v2 and Ultra Disk data disk' {
    BeforeEach {
        $global:ulRead = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { $global:ulRead.Add(($DiskId -split '/')[-1]); UlFacts $DiskId @{ diskSizeGB = 17 } }
        $script:capture = [ordered]@{ dataDisks = @(UlDisks -NoFacts | ForEach-Object { $h = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h }) }
        $script:ctxRun = UlNewRun
        $script:ctx = @{ RunPath = $script:ctxRun; VmId = $script:vmId }
    }
    AfterEach { UlDrop $script:ctxRun; Remove-Variable ulRead -Scope Global -ErrorAction SilentlyContinue }

    It 'reads ONLY those disks, by id, and records what a new disk needs on each; a Premium SSD disk is not read or changed' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $script:ctx; cap = $script:capture } { param($c, $cap) Add-VmfInstantAccessDiskFacts -Context $c -Capture $cap }
        $r | Should -BeNullOrEmpty
        @($global:ulRead) | Should -Be @('vm1-data1', 'vm1-data2')
        $d1 = $script:capture.dataDisks[1]; $d2 = $script:capture.dataDisks[2]
        $d1.diskIOPSReadWrite | Should -Be 5000; $d1.diskMBpsReadWrite | Should -Be 200; $d1.logicalSectorSize | Should -Be 512
        $d2.diskIOPSReadWrite | Should -Be 3000; $d2.diskMBpsReadWrite | Should -Be 150; $d2.logicalSectorSize | Should -Be 4096
        @($d1.diskZones) | Should -Be @('1')
        $d1.maxShares | Should -Be 1
        $d1.completionPercent | Should -Be 100
        $d1.sizeGB | Should -Be 17 -Because 'the size is the disk''s own'
        $script:capture.dataDisks[0].Contains('diskIOPSReadWrite') | Should -BeFalse
    }

    It 'a disk Azure is still filling from a copy (a retry soon after a put-back) is refused, untouched' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { UlFacts $DiskId @{ completionPercent = $(if ($DiskId -match 'data2') { 63.4 } else { 100 }) } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $script:ctx; cap = $script:capture } { param($c, $cap) Add-VmfInstantAccessDiskFacts -Context $c -Capture $cap }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'dataDiskFilling'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'vm1-data2' on LUN 2 \(Ultra Disk\), 63 percent"
        $r.Detail | Should -Match 'Nothing on the machine changed'
        $r.Detail | Should -Not -Match 'vm1-data1'
    }

    # The review of SAFETY-ULTRA-1 changed this on purpose: it was a throw,
    # which after two attempts reads as a fault with no next step. A machine
    # that can never move must say why, in words a person can act on.
    It 'a disk Azure returns no sector size for is refused UNTOUCHED, with a reason a person can act on - never a bare error' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { UlFacts $DiskId @{ logicalSectorSize = $null } } else { UlFacts $DiskId } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $script:ctx; cap = $script:capture } { param($c, $cap) Add-VmfInstantAccessDiskFacts -Context $c -Capture $cap }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'dataDiskValuesUnknown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'vm1-data1' on LUN 1 \(Premium SSD v2\): no sector size"
        $r.Detail | Should -Not -Match 'vm1-data2'
        $r.Detail | Should -Match 'Nothing on the machine changed'
    }

    It 'a machine in an availability set with such a disk is refused UNTOUCHED, before any disk is read - outside the scope of this tool' {
        $script:capture.availabilitySetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/availabilitySets/as1'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $script:ctx; cap = $script:capture } { param($c, $cap) Add-VmfInstantAccessDiskFacts -Context $c -Capture $cap }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'instantAccessAvailabilitySet'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'vm1-data1' on LUN 1 \(Premium SSD v2\), 'vm1-data2' on LUN 2 \(Ultra Disk\)"
        $r.Detail | Should -Match 'outside the scope of this tool'
        @($global:ulRead).Count | Should -Be 0
    }

    It 'a machine in an availability set with no such disk is not refused for it' {
        $script:capture.availabilitySetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/availabilitySets/as1'
        $script:capture.dataDisks = @($script:capture.dataDisks[0])
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:ctx; cap = $script:capture } { param($c, $cap) Add-VmfInstantAccessDiskFacts -Context $c -Capture $cap } | Should -BeNullOrEmpty
    }

    # SAFETY-CMK-1 took v21 (the encryption of every disk); v21 keeps these values.
    It 'PRECHECK itself saves the values with the capture, at v21, and changes nothing in Azure' {
        $writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
            ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
            Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -eq 'Invoke-VmfRunCommand' })
        foreach ($n in $writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }

        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        # TARGET-CAPABILITY-PRECHECK-1: Checking asks the target size for Ultra Disks in zone 1 and for
        # Premium Storage - a catalog that does not say would stop the machine.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines'; Restrictions = @()
                    Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' })
                    LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = [string[]]@('1', '2', '3')
                            ZoneDetails = @([pscustomobject]@{ Name = [string[]]@('1'); Capabilities = @([pscustomobject]@{ Name = 'UltraSSDAvailable'; Value = 'True' }) }) }) }) }
        Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = 'nic0' } }
        $global:ulLive = InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub } {
            param($sub)
            [pscustomobject]@{
                Id = "$sub/virtualMachines/vm1"; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'; ManagedDisk = [pscustomobject]@{ Id = "$sub/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @([pscustomobject]@{ Lun = 1; Name = 'vm1-data1'; Caching = 'None'; DiskSizeGB = 16; DeleteOption = 'Detach'
                            ManagedDisk = [pscustomobject]@{ Id = "$sub/disks/vm1-data1"; StorageAccountType = 'PremiumV2_LRS' } })
                    ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic0'; Primary = $true }) }
                Zones = @('1'); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = [pscustomobject]@{ UltraSSDEnabled = $true }; DiagnosticsProfile = $null; SecurityProfile = $null
            }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:ulLive }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ulp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
                param($rp, $sub)
                Initialize-VmfRun -RunPath $rp -RunId 'ulp' | Out-Null
                $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/virtualMachines/vm1"; wave = 'w1'; ring = 'lab'; path = 'A'
                    assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                        platformManaged = $false; location = 'centralus'; dataDiskCount = 1 }
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '1' }
                    policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v6'; acceleratedNetworking = 'preserve' } }
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'ulp'
                New-VmfStateDoc -RunPath $rp -RunId 'ulp' -VmId $ctx.VmId | Out-Null
                Invoke-VmfStepPrecheck -Context $ctx
            }
            $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = "$($script:sub)/virtualMachines/vm1" } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
            $d = @($doc.captured.vmConfig.dataDisks)[0]
            $d.diskIOPSReadWrite | Should -Be 5000
            $d.diskMBpsReadWrite | Should -Be 200
            $d.logicalSectorSize | Should -Be 512
            @($doc.captured.original.vmConfig.dataDisks)[0].diskIOPSReadWrite | Should -Be 5000 -Because 'the first capture keeps them too'
            $doc.schemaVersion | Should -Be 51   # SAFETY-CMK-1 took v21, ROLLBACK-DISKS-FIRST-1 v22, RECOVER-ALL-DISKS-1 v23, ROLLBACK-CRG-1 v24, SWAP-REFUSED-AFTER-STOP-1 v25, MADE-DISK-RECORD-1 v26, RESTORE-END-JOB-1 v27, FINISH-EMPTY-LUN-PROOF-1 v28, FINISH-KEPT-DISKS-1 v29, RESTORE-EARLIER-DELETE-1 v40
        }
        finally { UlDrop $script:rp; Remove-Variable ulLive -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'SAFETY-ULTRA-1: when is a copy usable, and will it last' {
    It 'InstantAccess, AvailableWithInstantAccess and Available are usable; only the two Available states are complete' {
        InModuleScope VmMigrationFactory {
            $now = [datetime]::Parse('2026-10-10T13:00:00Z').ToUniversalTime()
            $ia = Get-VmfCopyUsability -Access ([pscustomobject]@{ snapshotAccessState = 'InstantAccess'; instantAccessDurationMinutes = 300; timeCreated = '2026-10-10T12:00:00Z' }) -NowUtc $now
            $ia.Usable | Should -BeTrue; $ia.Complete | Should -BeFalse; $ia.MinutesLeft | Should -Be 240
            foreach ($s in 'AvailableWithInstantAccess', 'Available') {
                $c = Get-VmfCopyUsability -Access ([pscustomobject]@{ snapshotAccessState = $s }) -NowUtc $now
                $c.Usable | Should -BeTrue -Because $s; $c.Complete | Should -BeTrue -Because $s
            }
        }
    }

    It 'Pending, an empty state and no reading at all are NOT usable - unknown is never a yes' {
        InModuleScope VmMigrationFactory {
            $now = (Get-Date).ToUniversalTime()
            (Get-VmfCopyUsability -Access ([pscustomobject]@{ snapshotAccessState = 'Pending'; completionPercent = 99 }) -NowUtc $now).Usable | Should -BeFalse
            (Get-VmfCopyUsability -Access ([pscustomobject]@{ snapshotAccessState = '' ; completionPercent = 100 }) -NowUtc $now).Usable | Should -BeFalse
            (Get-VmfCopyUsability -Access $null -NowUtc $now).Usable | Should -BeFalse
            (Get-VmfCopyUsability -Access ([pscustomobject]@{ snapshotAccessState = 'InstantAccess' }) -NowUtc $now).MinutesLeft | Should -BeNullOrEmpty -Because 'no time from Azure, no minutes'
        }
    }

    It 'before the move: complete, or at least 120 minutes left; 119 minutes, Pending, no end time or a failed read all fail' {
        InModuleScope VmMigrationFactory {
            $r = { param($lun, $state, $left, $complete, $err) [pscustomobject]@{ lun = $lun; State = $state; MinutesLeft = $left; Complete = $complete; Percent = 20; Error = $err } }
            @(Get-VmfCopyWindowProblems -Readiness @((& $r 1 'Available' 0 $true $null), (& $r 2 'InstantAccess' 120 $false $null)) -MarginMinutes 120).Count | Should -Be 0
            $bad = @(Get-VmfCopyWindowProblems -Readiness @((& $r 1 'InstantAccess' 119 $false $null), (& $r 2 'Pending' $null $false $null),
                    (& $r 3 'InstantAccess' $null $false $null), (& $r 4 '' $null $false 'AuthorizationFailed')) -MarginMinutes 120)
            $bad.Count | Should -Be 4
            $bad[0] | Should -Match 'LUN 1: access state InstantAccess, 20 percent copied, 119 minutes of instant access left'
            $bad[3] | Should -Match 'LUN 4: the product could not read its copy \(AuthorizationFailed\)'
        }
    }
}

Describe 'SAFETY-ULTRA-1: the first copy, and the wait while the machine is stopped' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $global:ul = @{ calls = [System.Collections.Generic.List[string]]::new(); access = @{}; reads = 0 }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:ul.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ul.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfSafetyCopyTags { @{ vmfSafetyCopy = 'true' } }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:ul.calls.Add("snap:$SnapshotName"); "$($script:sub)/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory New-VmfInstantAccessSnapshot { $global:ul.calls.Add("instant:$SnapshotName/$Minutes"); "$($script:sub)/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { $global:ul.calls.Add("lock:$(($SnapshotId -split '/')[-1])") }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        # A wait that never ends fails the test instead of hanging it.
        Mock -ModuleName VmMigrationFactory Start-Sleep { $global:ul.calls.Add('sleep'); if (@($global:ul.calls | Where-Object { $_ -eq 'sleep' }).Count -gt 50) { throw 'the wait never ended' } }
        # Azure's answer per copy; a list is read one answer at a time.
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess {
            $global:ul.reads++
            $global:ul.calls.Add("read:$(($SnapshotId -split '/')[-1])")
            $key = ($SnapshotId -split '/')[-1] -replace '^.*-(d\d)$', '$1'
            $a = $global:ul.access[$key]
            if ($null -eq $a) { $a = $global:ul.access['*'] }
            if ($a -is [scriptblock]) { & $a } elseif ($a -is [System.Collections.IList]) { $first = $a[0]; if ($a.Count -gt 1) { $a.RemoveAt(0) }; $first } else { $a }
        }
    }
    AfterEach { UlDrop $script:rp; Remove-Variable ul -Scope Global -ErrorAction SilentlyContinue }

    It 'the first copy of each of these disks is an instant access copy of 300 minutes, read back, with its evidence; the Premium SSD disk gets an ordinary copy' {
        $script:rp = UlNewRun -NoCopies
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
        $global:ul.calls | Should -Contain 'snap:vm1-vmf-ul-pristine-d0'
        $global:ul.calls | Should -Contain 'instant:vm1-vmf-ul-pristine-d1/300'
        $global:ul.calls | Should -Contain 'instant:vm1-vmf-ul-pristine-d2/300'
        $global:ul.calls | Should -Not -Contain 'snap:vm1-vmf-ul-pristine-d1'
        $doc = UlDoc $script:rp
        $c1 = @($doc.safety.pristineDataCopies) | Where-Object lun -EQ 1
        $c1.instantAccessMinutes | Should -Be 300
        # Read back as a date value (ConvertFrom-Json); the instant is what counts.
        ([datetime]$c1.takenUtc).ToUniversalTime() | Should -BeGreaterThan ((Get-Date).ToUniversalTime().AddMinutes(-10))
        $c1.locked | Should -BeTrue -Because 'the evidence survives the second write, after the lock'
        (@($doc.safety.pristineDataCopies) | Where-Object lun -EQ 0).PSObject.Properties['instantAccessMinutes'] | Should -BeNullOrEmpty
        $calls = @($global:ul.calls)
        $calls[-1] | Should -Be 'start' -Because 'the machine starts only after Azure said every copy is usable'
        [array]::IndexOf($calls, 'start') | Should -BeGreaterThan ([array]::LastIndexOf($calls, ($calls | Where-Object { $_ -like 'read:*' } | Select-Object -Last 1)))
    }

    It 'the second copy of these disks stays an ordinary copy' {
        $script:rp = UlNewRun
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepSafetyCopy -Context $c } | Out-Null
        $global:ul.calls | Should -Contain 'snap:vm1-vmf-ul-d1'
        $global:ul.calls | Should -Contain 'snap:vm1-vmf-ul-d2'
        @($global:ul.calls | Where-Object { $_ -like 'instant:*' }).Count | Should -Be 0
    }

    It 'STOP AND RESUME: a stop after Azure made the copy and before the record asks Azure again by the SAME name, once' {
        $script:rp = UlNewRun -NoCopies
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue "$sub/snapshots/os" -Force
            $doc.safety | Add-Member -NotePropertyName pristineDataCopies -NotePropertyValue @(
                [pscustomobject]@{ lun = 0; diskId = 'd0'; snapshotId = "$sub/snapshots/vm1-vmf-ul-pristine-d0"; locked = $true }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } | Out-Null
        @($global:ul.calls | Where-Object { $_ -like 'instant:*' }) | Should -Be @('instant:vm1-vmf-ul-pristine-d1/300', 'instant:vm1-vmf-ul-pristine-d2/300')
        @($global:ul.calls | Where-Object { $_ -like 'snap:*' }).Count | Should -Be 0 -Because 'the OS disk and LUN 0 are on record'
    }

    It 'a copy Azure cannot use yet: the machine STAYS STOPPED, Azure is read again, and the move goes on when it is usable' {
        $script:rp = UlNewRun -NoCopies
        # The first answer is the read right after the copy (its evidence).
        $global:ul.access['d1'] = [System.Collections.ArrayList]@((UlAccess 'Pending' 1), (UlAccess 'Pending' 2), (UlAccess 'Pending' 3), (UlAccess 'InstantAccess' 4))
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
        $calls = @($global:ul.calls)
        @($calls | Where-Object { $_ -eq 'sleep' }).Count | Should -Be 2
        @($calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        [array]::IndexOf($calls, 'start') | Should -BeGreaterThan ([array]::LastIndexOf($calls, 'sleep')) -Because 'never a wait while the machine runs'
        UlLog $script:rp | Should -Match 'The machine stays stopped while Azure makes these first safety copies usable, for at most 30 minutes: LUN 1: access state Pending'
    }

    It 'a copy still not usable 30 minutes after Azure made it: the move stops UNTOUCHED, and the machine starts again' {
        $script:rp = UlNewRun
        $global:ul.access['d2'] = UlAccess 'Pending' 31
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Wait-VmfInstantAccessCopies -Context $c }
        $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
        $r.Reason | Should -Be 'safetyCopyNotReady'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'LUN 2: access state Pending'
        $r.Detail | Should -Match 'stayed stopped for up to 30 minutes'
        $r.Detail | Should -Match 'Nothing on the machine changed'
        @($global:ul.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        $global:ul.calls | Should -Not -Contain 'sleep'
    }

    It 'a machine that runs is never kept waiting: it stops untouched at once' {
        $script:rp = UlNewRun
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        $global:ul.access['*'] = UlAccess 'Pending' 1
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Wait-VmfInstantAccessCopies -Context $c }
        $r.Reason | Should -Be 'safetyCopyNotReady'
        $r.Detail | Should -Match 'does not wait while a machine runs'
        $global:ul.calls | Should -Not -Contain 'sleep'
    }

    It 'a copy that cannot be read is not usable, and the stop says why' {
        $script:rp = UlNewRun
        $global:ul.access['d1'] = { throw 'AuthorizationFailed: no snapshots/read' }
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Wait-VmfInstantAccessCopies -Context $c }
        $r.Reason | Should -Be 'safetyCopyNotReady'
        $r.Detail | Should -Match 'LUN 1: the product could not read its copy \(AuthorizationFailed'
    }

    It 'a machine with no such disk makes no call to Azure at all' {
        $script:rp = UlNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.captured.vmConfig.dataDisks = @(@($doc.captured.vmConfig.dataDisks)[0])
            $doc.captured.original.vmConfig.dataDisks = @(@($doc.captured.original.vmConfig.dataDisks)[0])
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Wait-VmfInstantAccessCopies -Context $c } | Should -BeNullOrEmpty
        $global:ul.reads | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfPowerState -Times 0 -Exactly
    }

    It 'STOP AND RESUME: a stop during the wait resumes with no new copy and no stop - Azure is read again, then the move goes on' {
        $script:rp = UlNewRun -State 'SAFETY_PRISTINE'
        $global:ul.access['d1'] = [System.Collections.ArrayList]@((UlAccess 'Pending' 10), (UlAccess 'AvailableWithInstantAccess' 11))
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
        @($global:ul.calls | Where-Object { $_ -like 'snap:*' -or $_ -like 'instant:*' -or $_ -eq 'stop' -or $_ -like 'lock:*' }).Count | Should -Be 0
        $global:ul.calls | Should -Contain 'read:vm1-pristine-d1'
        $global:ul.calls | Should -Contain 'sleep'
    }

    It 'through the state machine: the stop is FAILED_NEEDS_ATTENTION, reason safetyCopyNotReady, machine untouched - never GUEST_PREP' {
        $script:rp = UlNewRun -State 'SAFETY_PRISTINE'
        $global:ul.access['d1'] = UlAccess 'Pending' 45
        $global:ul.access['*'] = UlAccess 'InstantAccess'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfStepGuestPrep { throw 'GUEST_PREP must not run' }
        $plan = InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id) [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ p = $plan; rp = $script:rp } { param($p, $rp) Invoke-VmfStateMachine -PlanEntry $p -RunPath $rp -RunId 'ul' }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'safetyCopyNotReady'
        $last.machineState | Should -Be 'untouched'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfStepGuestPrep -Times 0 -Exactly
    }
}

Describe 'SAFETY-ULTRA-1: the check just before the conversion' {
    BeforeEach {
        $global:ul = @{ calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ul.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfAcceleratedNetworkingDecision { throw 'CONVERTING went past the check' }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { throw 'no disk may change' }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'no interface may change' }
        Mock -ModuleName VmMigrationFactory Test-VmfGuestChangedThisAttempt { $true }
    }
    AfterEach { UlDrop $script:rp; Remove-Variable ul -Scope Global -ErrorAction SilentlyContinue }

    It 'a copy with 119 minutes of instant access left, after the preparation changed the guest: put back at once, never converted' {
        $script:rp = UlNewRun -State 'CONVERTING'
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { if ($SnapshotId -match 'd2$') { UlAccess 'InstantAccess' 181 } else { UlAccess 'AvailableWithInstantAccess' 30 } }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c }
        $r.PutBack | Should -BeTrue
        $r.Next | Should -Be 'FAILED_ROLLED_BACK'
        $r.Reason | Should -Be 'safetyCopyWindowShort'
        $r.Detail | Should -Match 'LUN 2: access state InstantAccess, 20 percent copied, 11[89] minutes of instant access left'
        $r.Detail | Should -Not -Match 'LUN 1'
        $global:ul.calls | Should -Not -Contain 'start' -Because 'the disks-only rollback starts the machine, after it puts the disks back'
    }

    It 'nothing changed the guest: the machine starts again, untouched, and does not move' {
        $script:rp = UlNewRun -State 'CONVERTING'
        Mock -ModuleName VmMigrationFactory Test-VmfGuestChangedThisAttempt { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { UlAccess 'Pending' 400 }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c }
        $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
        $r.Reason | Should -Be 'safetyCopyWindowShort'
        $r.MachineState | Should -Be 'untouched'
        $r.PutBack | Should -BeNullOrEmpty
        @($global:ul.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
    }

    It 'complete copies, or 120 minutes left, go on into the conversion' {
        $script:rp = UlNewRun -State 'CONVERTING'
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { if ($SnapshotId -match 'd2$') { UlAccess 'InstantAccess' 179.5 } else { UlAccess 'Available' 900 } }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c } } | Should -Throw '*went past the check*'
    }

    It 'STOP AND RESUME: the conversion is on record BEFORE accelerated networking changes, so a resume never stops it as unchanged' {
        $script:rp = UlNewRun -State 'CONVERTING'
        $global:ul.an = 0
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { $global:ul.calls.Add('readCopy'); if ($global:ul.an) { UlAccess 'InstantAccess' 200 } else { UlAccess 'InstantAccess' 30 } }
        Mock -ModuleName VmMigrationFactory Get-VmfAcceleratedNetworkingDecision { @{ Policy = 'ensureOn' } }
        Mock -ModuleName VmMigrationFactory Get-VmfNicAnPlan { @([pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic0'; enabled = $true }) }
        Mock -ModuleName VmMigrationFactory Get-VmfSourceAcceleratedNetworking { $true }
        # The worker stops right after Azure changed the interface.
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:ul.an++; throw 'Lease lost - abandon this VM' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c } } | Should -Throw '*abandon this VM*'
        (UlDoc $script:rp).pathCheckpoint | Should -Be 'converting:started' -Because 'written before the first change'
        $global:ul.an | Should -Be 1

        # The resume: the copies now have less than 120 minutes left. It must
        # NOT run the check again, roll back the disks only, or say unchanged.
        $global:ul.calls.Clear()
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { throw 'the conversion goes on' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c } } | Should -Throw '*the conversion goes on*'
        $global:ul.calls | Should -Not -Contain 'readCopy'
        $global:ul.calls | Should -Not -Contain 'start'
    }

    It 'once the conversion has started (a checkpoint on record), there is no check: the fastest way out is to finish or to put back' {
        $script:rp = UlNewRun -State 'CONVERTING'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName pathCheckpoint -NotePropertyValue 'A:diskPatched' -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { UlAccess 'Pending' 400 }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c } } | Should -Throw '*went past the check*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSnapshotAccess -Times 0 -Exactly
    }
}

Describe 'SAFETY-ULTRA-1: what a put-back makes, and when it leaves a disk' {
    BeforeAll {
        function Global:UlReady([string]$State = 'InstantAccess', [string]$Err = $null) {
            $m = @{}
            foreach ($l in 1, 2) { $m["$($script:sub)/snapshots/vm1-pristine-d$l"] = [pscustomobject]@{ snapshotId = "$($script:sub)/snapshots/vm1-pristine-d$l"; lun = $l; State = $State; Usable = $State -in 'InstantAccess', 'Available', 'AvailableWithInstantAccess'; Complete = $State -like 'Available*'; MinutesLeft = 200; Error = $Err } }
            $m
        }
    }
    AfterAll { Remove-Item function:UlReady -ErrorAction SilentlyContinue }
    AfterEach { UlDrop $script:rp }

    It 'a disk with its values on record and a usable copy goes back - with its type, values, sector size, size and zone' {
        $script:rp = UlNewRun
        $plan = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = (UlReady) } { param($d, $r) Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness $r }
        @($plan.Restore | ForEach-Object lun) | Should -Be @(0, 1, 2)
        @($plan.Kept).Count | Should -Be 0
        $u = @($plan.Restore) | Where-Object lun -EQ 2
        $u.instantAccess | Should -BeTrue
        $u.skuName | Should -Be 'UltraSSD_LRS'
        $u.diskIOPSReadWrite | Should -Be 3000; $u.diskMBpsReadWrite | Should -Be 150; $u.logicalSectorSize | Should -Be 4096; $u.sizeGB | Should -Be 8
        @($u.diskZones) | Should -Be @('1')
        (@($plan.Restore) | Where-Object lun -EQ 0).PSObject.Properties['instantAccess'] | Should -BeNullOrEmpty -Because 'a Premium SSD disk goes back as before'
    }

    It 'left, each with the reason: a copy Azure cannot use, no answer, a failed read, values not on record, a type that changed' {
        $script:rp = UlNewRun
        $doc = UlDoc $script:rp
        $leftWhy = { param($d, $r) $p = InModuleScope VmMigrationFactory -Parameters @{ d = $d; r = $r } { param($d, $r) Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness $r }; (@($p.Kept) | Where-Object lun -EQ 1).why }
        & $leftWhy $doc (UlReady 'Pending') | Should -Match "Azure cannot make a disk from its copy '.*vm1-pristine-d1' now: the access state is Pending\."
        & $leftWhy $doc $null | Should -Match 'did not read whether Azure can make a disk from its copy'
        & $leftWhy $doc (UlReady '' 'AuthorizationFailed') | Should -Match 'could not read its copy .*AuthorizationFailed'
        & $leftWhy (UlDoc ($script:rp2 = UlNewRun -NoFacts)) (UlReady) | Should -Match 'its IOPS, throughput, sector size are not on record\. Its copy is'
        UlDrop $script:rp2
        $changed = $doc | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $changed.captured | Add-Member -NotePropertyName original -NotePropertyValue ([pscustomobject]@{ vmConfig = ($changed.captured.vmConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10) }) -Force
        (@($changed.captured.original.vmConfig.dataDisks) | Where-Object lun -EQ 1).skuName = 'Premium_LRS'
        & $leftWhy $changed (UlReady) | Should -Match 'Its disk type was Premium_LRS when the product first read the machine, and it is Premium SSD v2 in this attempt'
    }

    It 'the new disk is made with the recorded IOPS and throughput, read back, and swapped with no host caching' {
        $script:rp = UlNewRun
        $global:ulMade = @{}
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:ulMade[$DiskName] = @{ iops = $DiskIopsReadWrite; mbps = $DiskMBpsReadWrite; sku = $SkuName; zone = $Zone }; "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { UlFacts $DiskId }
        $out = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp); d = (UlDoc $script:rp); r = (UlReady) } {
            param($c, $d, $r)
            $p = Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness $r
            Invoke-VmfDataDiskRestore -Context $c -RestorePlan $p -Location 'centralus' -Zone '1'
        }
        @($out.Kept).Count | Should -Be 0
        $global:ulMade['vm1-data1-d1-asitwas-s'].iops | Should -Be 5000
        $global:ulMade['vm1-data2-d2-asitwas-s'].mbps | Should -Be 150
        $global:ulMade['vm1-data2-d2-asitwas-s'].sku | Should -Be 'UltraSSD_LRS'
        $global:ulMade['vm1-data0-d0-asitwas-s'].iops | Should -BeNullOrEmpty
        $s2 = @($out.Swaps) | Where-Object lun -EQ 2
        $s2.caching | Should -Be 'None'
        $s2.instantAccess | Should -BeTrue
        (@($out.Swaps) | Where-Object lun -EQ 0).caching | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts -Times 3 -Exactly -Because 'each disk is read back once: these types for their values and key, a Premium SSD disk for its key (OLD-VERSION-READERS-REMOVE-4)'
        Remove-Variable ulMade -Scope Global
        (@((UlDoc $script:rp).rollbackDisksDuringRollback) | ForEach-Object diskName) | Should -Contain 'vm1-data2-d2-asitwas-s'
    }

    It 'a new disk that differs from the record is NOT swapped: the old disk stays, the new one is kept on record, and why is said' {
        $script:rp = UlNewRun
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { UlFacts $DiskId @{ diskIOPSReadWrite = 3000; logicalSectorSize = 4096 } } else { UlFacts $DiskId @{ zones = @('2') } } }
        $out = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp); d = (UlDoc $script:rp); r = (UlReady) } {
            param($c, $d, $r)
            Invoke-VmfDataDiskRestore -Context $c -RestorePlan (Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness $r) -Location 'centralus' -Zone '1'
        }
        @($out.Swaps | ForEach-Object lun) | Should -Be @(0)
        $k1 = (@($out.Kept) | Where-Object lun -EQ 1).why
        $k1 | Should -Match "Azure made the disk 'vm1-data1-d1-asitwas-s', but it differs from the record: the IOPS is 3000, not 5000; the sector size is 4096, not 512\.$" -Because 'RESTORE-DIALOG-WORDS-1: the caller says what happens to each disk'
        (@($out.Kept) | Where-Object lun -EQ 2).why | Should -Match 'the zone is 2, not 1'
        $made = @((UlDoc $script:rp).rollbackDisksDuringRollback | ForEach-Object diskName)
        $made | Should -Contain 'vm1-data1-d1-asitwas-s' -Because 'a disk Azure made bills; it is on record the moment it exists'
        UlLog $script:rp | Should -Match "The data disk 'vm1-data1' on LUN 1 is left as it is\. Azure made the disk"
    }

    It 'a new disk that cannot be read back is not swapped either' {
        $script:rp = UlNewRun
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { throw 'ResourceNotFound' }
        $out = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp); d = (UlDoc $script:rp); r = (UlReady) } {
            param($c, $d, $r) Invoke-VmfDataDiskRestore -Context $c -RestorePlan (Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness $r) -Location 'centralus' -Zone '1'
        }
        # OLD-VERSION-READERS-REMOVE-4: every disk is read back for its key now, so the read that fails keeps each one.
        @($out.Swaps).Count | Should -Be 0
        (@($out.Kept) | Where-Object lun -EQ 2).why | Should -Match 'could not read it back to compare it with the record: ResourceNotFound'
    }

    It 'compares every value; one Azure did not return is a difference' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{ skuName = 'PremiumV2_LRS'; sizeGB = 16; diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512; diskZones = @() }
            $ok = [pscustomobject]@{ skuName = 'PremiumV2_LRS'; diskSizeGB = 16; diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512; zones = @('3') }
            @(Compare-VmfMadeDiskFacts -Row $row -Got $ok -Zone '3').Count | Should -Be 0 -Because 'no zone on record: the machine''s'
            $bad = $ok.PSObject.Copy(); $bad.skuName = 'Premium_LRS'; $bad.diskSizeGB = 32; $bad.diskMBpsReadWrite = $null
            $d = @(Compare-VmfMadeDiskFacts -Row $row -Got $bad -Zone '3')
            $d | Should -Contain 'the disk type is Premium_LRS, not PremiumV2_LRS'
            $d | Should -Contain 'the size in GiB is 32, not 16'
            $d | Should -Contain 'Azure did not return the throughput in MBps'
            @(Compare-VmfMadeDiskFacts -Row $row -Got $null -Zone '3') | Should -Be @('Azure returned nothing for it')
        }
    }
}

Describe 'SAFETY-ULTRA-1: the rollback puts them back' {
    BeforeEach {
        $global:ul = @{ calls = [System.Collections.Generic.List[string]]::new(); swaps = [System.Collections.Generic.List[object]]::new(); refuseIa = $false; rebuild = $null; abandon = $false }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:ul.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ul.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:ul.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:ul.calls.Add("create:$DiskName"); "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { UlFacts $DiskId }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:ul.calls.Add('os') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $luns = @($Swaps | ForEach-Object { [int]$_.lun })
            $global:ul.calls.Add("data:$($luns -join ',')"); $global:ul.swaps.Add(@($Swaps))
            $ia = @($Swaps | Where-Object { $_.instantAccess }).Count -gt 0
            if ($ia -and $global:ul.abandon) { throw 'Lease lost - abandon this VM' }
            if ($ia -and $global:ul.refuseIa) { return @{ Applied = $false; Reason = 'OperationNotAllowed: zone' } }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { $global:ul.calls.Add('readCopy'); UlAccess 'InstantAccess' 60 }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
    }
    AfterEach { UlDrop $script:rp; Remove-Variable ul -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: each copy is read BEFORE the machine stops; every disk is made before any swap; every other disk is swapped first, then these two' {
        $script:rp = UlNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:ul.calls)
        [array]::LastIndexOf($calls, 'readCopy') | Should -BeLessThan ([array]::IndexOf($calls, 'stop'))
        [array]::LastIndexOf($calls, ($calls | Where-Object { $_ -like 'create:*' } | Select-Object -Last 1)) | Should -BeLessThan ([array]::IndexOf($calls, 'os'))
        @($calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:0', 'data:1,2')
        $calls[-1] | Should -Be 'start'
        @($global:ul.swaps[1] | ForEach-Object caching) | Should -Be @('None', 'None')
        $doc = UlDoc $script:rp
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1, 2)
        @($doc.rollback.keptDataDisks).Count | Should -Be 0
        UlLog $script:rp | Should -Not -Match 'except \d+ data disk'
    }

    # SWAP-REFUSED-AFTER-STOP-1 rewrote these two on purpose. The batch Azure
    # refused kept its old disks and the machine STARTED - disks from two
    # moments. Now the others still go back, the refused batch is tried again,
    # and the machine stays stopped with every disk named on its record.
    It 'Path A: Azure refuses the attach of these two on every try - the others still go back, the old disks stay on their LUNs, and the machine stays stopped' {
        $script:rp = UlNewRun
        $global:ul.refuseIa = $true
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $doc = UlDoc $script:rp
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Be @(0)
        @($doc.rollback.keptDataDisks).Count | Should -Be 0 -Because 'a disk the swap left is not a disk left by design'
        $left = @($doc.swapPending.swaps)
        @($left | ForEach-Object lun) | Should -Be @(1, 2)
        $left[0].diskName | Should -Match '^vm1-data1-d1-asitwas-'
        $left[0].instantAccess | Should -BeTrue
        $left[0].caching | Should -Be 'None'
        $doc.swapPending.error | Should -Be 'OperationNotAllowed: zone'
        @($global:ul.calls | Where-Object { $_ -eq 'data:1,2' }).Count | Should -Be 3 -Because 'the refused batch is tried three times'
        $global:ul.calls | Should -Not -Contain 'start'
        UlLog $script:rp | Should -Match "LUN 1 keeps 'vm1-data1'"
    }

    It 'the stop that ends the rollback names each disk not put back, and why - and leaves the machine changed' {
        $script:rp = UlNewRun -State 'CONVERTING'
        $global:ul.refuseIa = $true
        # ROLLBACK-EMPTY-LUN-1: the stop says each LUN as Azure reports it, so
        # Azure reports LUN 1 and LUN 2 on the disks they had (the refused swap
        # put them back).
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @(1, 2 | ForEach-Object { [pscustomobject]@{ lun = $_; id = "$($script:sub)/disks/vm1-data$_"; name = "vm1-data$_" } })
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.machineState | Should -Be 'changed'
        $last.detail | Should -Match "LUN 1 keeps 'vm1-data1', not the disk 'vm1-data1-d1-asitwas-"
        $last.detail | Should -Match "LUN 2 keeps 'vm1-data2'"
        $last.detail | Should -Match 'Azure said: OperationNotAllowed: zone\.'
        $last.detail | Should -Match "LUN 0 'vm1-data0-d0-asitwas-"
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'the disks-only rollback before the move puts them back the same way' {
        $script:rp = UlNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        @($global:ul.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:0', 'data:1,2')
        $global:ul.calls | Should -Not -Contain 'size'
        (UlDoc $script:rp).rollback.path | Should -Be 'disks'
    }

    It 'STOP AND RESUME: a stop after these disks are made and before their swap leaves no LUN empty, the made disks on record, and the resume finishes' {
        $script:rp = UlNewRun -State 'CONVERTING'
        $global:ul.abandon = $true
        { InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } {
                param($c)
                Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
                Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
        $doc = UlDoc $script:rp
        $doc.rollbackPending | Should -Not -BeNullOrEmpty -Because 'the checkpoint stays, so the next worker finishes this rollback'
        $made = @($doc.rollbackDisksDuringRollback | ForEach-Object diskName)
        @($made | Where-Object { $_ -like 'vm1-data1-d1-asitwas-*' }).Count | Should -Be 1
        @($made | Where-Object { $_ -like 'vm1-data2-d2-asitwas-*' }).Count | Should -Be 1
        @($global:ul.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:0', 'data:1,2') -Because 'the stop came before the swap of these two touched the machine'
        $global:ul.calls | Should -Not -Contain 'start'

        $global:ul.abandon = $false
        $global:ul.calls.Clear()
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (UlCtx $script:rp 'A') } { param($c) Complete-VmfRollback -Context $c }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Contain 2
        $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }
}

Describe 'SAFETY-ULTRA-1: Restore this machine follows the same rules' {
    BeforeAll {
        function Global:UlLive {
            @(
                [pscustomobject]@{ lun = 0; id = "$($script:sub)/disks/vm1-data0"; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' }
                [pscustomobject]@{ lun = 1; id = "$($script:sub)/disks/vm1-data1"; name = 'vm1-data1'; resourceGroup = 'rg-app'; skuName = 'PremiumV2_LRS' }
                [pscustomobject]@{ lun = 2; id = "$($script:sub)/disks/vm1-data2"; name = 'vm1-data2'; resourceGroup = 'rg-app'; skuName = 'UltraSSD_LRS' })
        }
        function Global:UlRestoreReady([string]$D1State = 'InstantAccess', [bool]$D1Complete = $false) {
            $m = @{}
            foreach ($l in 1, 2) {
                $st = if ($l -eq 1) { $D1State } else { 'AvailableWithInstantAccess' }
                $m["$($script:sub)/snapshots/vm1-pristine-d$l"] = [pscustomobject]@{ snapshotId = "$($script:sub)/snapshots/vm1-pristine-d$l"; diskId = "$($script:sub)/disks/vm1-data$l"; lun = $l
                    State = $st; Usable = $st -ne 'Pending'; Complete = $(if ($l -eq 1) { $D1Complete } else { $true }); MinutesLeft = 200; Error = $null }
            }
            $m
        }
    }
    AfterAll { Remove-Item function:UlLive, function:UlRestoreReady -ErrorAction SilentlyContinue }
    AfterEach { UlDrop $script:rp }

    It 'new names: these disks come back with their recorded values, from usable copies' {
        $script:rp = UlNewRun
        $p = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = (UlRestoreReady); live = (UlLive) } {
            param($d, $r, $live) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'new' -CopyReadiness $r
        }
        @($p.Restore | ForEach-Object lun) | Should -Be @(0, 1, 2)
        $r1 = @($p.Restore) | Where-Object lun -EQ 1
        $r1.instantAccess | Should -BeTrue
        $r1.diskIOPSReadWrite | Should -Be 5000
        $r1.skuName | Should -Be 'PremiumV2_LRS'
    }

    It 'keeping the names NEVER deletes a disk whose copy in instant access is not complete - that copy depends on it' {
        $script:rp = UlNewRun
        $p = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = (UlRestoreReady 'InstantAccess' $false); live = (UlLive) } {
            param($d, $r, $live) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve' -CopyReadiness $r
        }
        @($p.Restore | ForEach-Object lun) | Should -Be @(0, 2) -Because 'the copy of LUN 2 is complete'
        (@($p.Kept) | Where-Object lun -EQ 1).why | Should -Match "Keeping the names deletes this disk, and a copy of it depends on it until Azure finishes copying it: '.*vm1-pristine-d1' \(InstantAccess\)\. Try again later, or give the restored disks new names\."
        $p2 = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = (UlRestoreReady 'AvailableWithInstantAccess' $true); live = (UlLive) } {
            param($d, $r, $live) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve' -CopyReadiness $r
        }
        @($p2.Restore | ForEach-Object lun) | Should -Be @(0, 1, 2)
    }

    It 'a copy that could not be read counts as not complete: keeping the names leaves that disk' {
        $script:rp = UlNewRun
        $ready = UlRestoreReady 'AvailableWithInstantAccess' $true
        $ready["$($script:sub)/snapshots/vm1-pristine-d2"].Error = 'AuthorizationFailed'
        $p = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = $ready; live = (UlLive) } {
            param($d, $r, $live) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve' -CopyReadiness $r
        }
        (@($p.Kept) | Where-Object lun -EQ 2) | Should -Not -BeNullOrEmpty
    }

    It 'a disk on another type now is left: it comes back only as the type its copy was taken from' {
        $script:rp = UlNewRun
        $live = UlLive; $live[2].skuName = 'Premium_LRS'
        $p = InModuleScope VmMigrationFactory -Parameters @{ d = (UlDoc $script:rp); r = (UlRestoreReady); live = $live } {
            param($d, $r, $live) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'new' -CopyReadiness $r
        }
        (@($p.Kept) | Where-Object lun -EQ 2).why | Should -Match 'Its disk type is Premium_LRS now, and its copy was taken from a disk on Ultra Disk\.'
    }

    It 'keeping the names: each disk of these types is made with its values and read back before the stop; a difference stops the restore, and NOTHING is deleted' {
        $script:rp = UlNewRun
        $global:ulR = @{ deleted = [System.Collections.Generic.List[string]]::new(); made = @{}; swaps = [System.Collections.Generic.List[object]]::new() }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:ulR.made[$DiskName] = $DiskIopsReadWrite; "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data2') { UlFacts $DiskId @{ diskMBpsReadWrite = 1 } } else { UlFacts $DiskId } }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:ulR.swaps.Add(@($Swaps)); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:ulR.deleted.Add($DiskName) }
        $res = InModuleScope VmMigrationFactory -Parameters @{ c = ([pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId; Rg = 'rg-app' }); d = (UlDoc $script:rp); r = (UlRestoreReady 'AvailableWithInstantAccess' $true); live = (UlLive) } {
            param($c, $d, $r, $live)
            $plan = Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve' -CopyReadiness $r
            # RESTORE-INLOOP-TEMP-1: the temporary disks are made before the
            # stop, as Restore this machine makes them. A disk refused there
            # stops the restore (Assert-VmfDataDisksAllBack); the others go
            # through the stopped window as Restore this machine would take them.
            $pre = New-VmfOperatorTempDataDisks -Context $c -Plan $plan -Location 'centralus' -Zone '1'
            $stop = $null
            try { Assert-VmfDataDisksAllBack -Kept @($pre.Kept) } catch { $stop = $_.Exception.Message }
            $onTemp = @{ Restore = @($plan.Restore | Where-Object { $pre.Temp.ContainsKey([int]$_.lun) }); Kept = @(@($plan.Kept) + @($pre.Kept)) }
            $out = Invoke-VmfOperatorDataRestore -Context $c -VmName 'vm1' -Plan $onTemp -Naming 'preserve' -Location 'centralus' -Zone '1' -TempMade $pre.Temp
            @{ Kept = @($out.Kept); Stop = $stop }
        }
        $global:ulR.made['vm1-data1-d1-rtmp-s'] | Should -Be 5000
        $global:ulR.made['vm1-data1'] | Should -Be 5000 -Because 'the disk under the old name is made the same way'
        $global:ulR.deleted | Should -Not -Contain 'vm1-data2' -Because 'its temporary disk differed, so the disk it has is never deleted'
        (@($res.Kept) | Where-Object lun -EQ 2).why | Should -Match 'differs from the record: the throughput in MBps is 1, not 150'
        $res.Stop | Should -Match "on LUN 2" -Because 'Restore this machine stops before the stop on such a disk'
        $lun1 = @($global:ulR.swaps | ForEach-Object { $_ } | Where-Object { [int]$_.lun -eq 1 })
        @($lun1 | ForEach-Object caching | Select-Object -Unique) | Should -Be @('None')
        Remove-Variable ulR -Scope Global
    }
}

# SAFETY-CMK-1 took v21; the v20 fields are unchanged in it.
Describe 'SAFETY-ULTRA-1: the contract, v20' {
    It 'the sample is a valid current document (v23) and shows every v20 field' {
        $schema = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        Test-Json -Json $sample -SchemaFile $schema -ErrorAction Stop | Should -BeTrue
        $s = $sample | ConvertFrom-Json
        $s.schemaVersion | Should -Be 51
        (@($s.captured.vmConfig.dataDisks) | Where-Object skuName -EQ 'PremiumV2_LRS').diskIOPSReadWrite | Should -Not -BeNullOrEmpty
        @($s.safety.pristineDataCopies)[0].instantAccessMinutes | Should -Be 300
        @($s.rollback.keptDataDisks).Count | Should -BeGreaterThan 0
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
    }

    It 'the closed parts stay closed: an unknown field on a copy or a kept disk is refused' {
        $schema = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        # The current version, or the document is refused for the version and
        # the check proves nothing (found when SAFETY-CMK-1 took v21; v23 since RECOVER-ALL-DISKS-1).
        $bad1 = '{"schemaVersion":51,"runId":"r","vmId":"v","state":"PLANNED","history":[],"safety":{"pristineDataCopies":[{"lun":1,"diskId":"d","snapshotId":"s","madeUp":1}]}}'
        $bad2 = '{"schemaVersion":51,"runId":"r","vmId":"v","state":"PLANNED","history":[],"rollback":{"rolledBackUtc":"2026-10-10T00:00:00Z","path":"A","osDisk":null,"dataDisks":[],"keptDataDisks":[{"lun":1,"name":"n"}]}}'
        # SWAP-REFUSED-AFTER-STOP-1: Test-Json returns False, and does not throw, for a
        # fault inside a nested list (measured on PowerShell 7.6.7, 2026-10-23), so a
        # check that waits for a throw fails on a document the schema refuses. Each now
        # counts a False as a refusal too.
        { if (-not (Test-Json -Json $bad1 -SchemaFile $schema -ErrorAction Stop)) { throw 'not valid with the schema' } } | Should -Throw
        { if (-not (Test-Json -Json $bad2 -SchemaFile $schema -ErrorAction Stop)) { throw 'not valid with the schema' } } | Should -Throw -Because 'a kept disk must say why'
    }

    It 'a copy with no instant access record: its Premium SSD v2 and Ultra Disk disks are left as they are, with the reason' {
        $script:rp = UlNewRun -NoFacts
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                foreach ($c in @($doc.safety.pristineDataCopies)) { foreach ($n in 'instantAccessMinutes', 'takenUtc') { $c.PSObject.Properties.Remove($n) } }
                $null = Complete-VmfTestCapture $doc
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
            $doc = UlDoc $script:rp
            $plan = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDataRestorePlan -Doc $d -Stamp 's' -CopyReadiness @{} }
            @($plan.Restore | ForEach-Object lun) | Should -Be @(0)
            @($plan.Kept | ForEach-Object lun) | Should -Be @(1, 2)
            @($plan.Kept)[0].why | Should -Match 'not on record'
        }
        finally { UlDrop $script:rp }
    }

    It 'the two refusals at PRECHECK have their words: one outside the scope of this tool, one a person can correct' {
        $reasons = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
        $as = $reasons | Where-Object code -EQ 'instantAccessAvailabilitySet'
        $as.retry | Should -Be 'outOfScope'
        $as.machine | Should -Be 'untouched'
        $as.meaning | Should -Match 'outside the scope of this tool'
        $un = $reasons | Where-Object code -EQ 'dataDiskValuesUnknown'
        $un.retry | Should -Be 'afterFix'
        $un.machine | Should -Be 'untouched'
        ($reasons | Where-Object code -EQ 'safetyCopyNotReady').PSObject.Properties['machineVaries'] | Should -BeNullOrEmpty -Because 'it is untouched, or still stopped - never rolled back'
    }

    It 'every new stop has its words, a machine state and a retry kind' {
        $reasons = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
        foreach ($code in 'dataDiskFilling', 'safetyCopyNotReady', 'safetyCopyWindowShort') {
            $r = $reasons | Where-Object code -EQ $code
            $r | Should -Not -BeNullOrEmpty -Because $code
            $r.retry | Should -Be 'whenAvailable' -Because $code
            $r.meaning | Should -Match 'Premium SSD v2 (or|and) Ultra Disk' -Because $code
        }
    }
}
