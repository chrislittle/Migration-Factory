#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VOLUMES-ONLINE-2 closes three items VOLUMES-ONLINE-1 left. The rule:
# every volume mounted before the move is mounted again after EVERY start on
# disks made from copies or on a new size.
#
# This file holds:
#   - VOLUMES-ONLINE-FINISH-1: Finish the rollback and Finish the restore
#     (Complete-VmfDataDiskSwap) start the machine on disks made from the
#     safety copies. They now run the same check as the rollback and the
#     restore (Invoke-VmfVolumesCheckAfterPutBack), keep its result on the
#     finish's checkpoint (putBackJob.volumes) before the power state goes
#     back, stop with volumesNotBack when a volume is not mounted, and write
#     the record a checked retry reads (volumesCheckOwed).
#   - VOLUMES-ONLINE-WINDOWS-1: the pure rule that chooses which data disks to
#     bring online (only a disk that was online before the move, and read-only
#     off only on a disk that was writable before), and the two Windows guest
#     scripts that read and change the disks (Windows PowerShell 5.1).
# The engine's Windows flows (Verifying, a rollback) and the v5 start task
# (VOLUMES-ONLINE-V5-1) are in VolumesOnline.Tests.ps1, beside the harness
# they share.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    $script:winDir = Join-Path $script:repoRoot 'src' 'guest' 'windows'

    # A machine a rollback (or a restore) left stopped: LUN 0 back from the
    # copy, LUN 1 left. It ran guest scripts (so the record says its
    # operating system), and the reading before the move is on record.
    function Global:VfRun {
        param([ValidateSet('rollback', 'restore')][string]$Kind = 'rollback', [string]$Os = 'Linux', [string]$Before = '/; /boot; /var/crash', [string]$PowerAtStart = '')
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; kind = $Kind; os = $Os; before = $Before; pas = $PowerAtStart } {
            param($rp, $id, $sub, $kind, $os, $before, $pas)
            Initialize-VmfRun -RunPath $rp -RunId 'vf' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'vf' -VmId $id -Wave 'w1' | Out-Null
            $scr = if ($os -eq 'Windows') { 'Test-GuestValidation.ps1' } else { 'guest-validate.sh' }
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = $os
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" }
                        dataDisks = @(
                            [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' }
                            [pscustomobject]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$sub/disks/vm1-data1"; caching = 'None'; sizeGB = 256; skuName = 'Premium_LRS' })
                        nics = @(); tags = @{} }
                    guestBefore = [pscustomobject]@{ schema = 'vmf.guest/2'; script = $scr; version = '1.0.0'; result = 'PASS'; warnings = @()
                        checks = @([pscustomobject]@{ name = 'mounted volumes'; status = 'INFO'; detail = $before }) } }) -Force
            $d | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{ script = $scr; version = '1.0.0'; sha256 = ('a' * 64); tsUtc = '2026-11-14T00:00:00Z'; result = 'READING'; evidenceRef = 'evidence/x.txt' }) -Force
            $d.state = 'FAILED_NEEDS_ATTENTION'
            $d.history = @($d.history) + @([pscustomobject]@{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'dataDiskSwapRefused'; machineState = 'changed'; detail = 'left' })
            $d | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-11-14T10:00:00Z'; path = 'A'
                    osDisk = [pscustomobject]@{ id = "$sub/disks/vm1-osdisk-asitwas-x"; name = 'vm1-osdisk-asitwas-x' }
                    dataDisks = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' }); keptDataDisks = @() }) -Force
            $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @()
                    kind = $kind; leftUtc = '2026-11-14T10:00:00Z'; error = 'OperationNotAllowed: the disk is in use'; usedBy = 'rollback-x'
                    swaps = @([pscustomobject]@{ lun = 1; name = 'vm1-data1'; oldDiskId = "$sub/disks/vm1-data1"; diskId = "$sub/disks/vm1-data1-d1-asitwas-x"; diskName = 'vm1-data1-d1-asitwas-x'; caching = 'None'; instantAccess = $false; snapshotId = "$sub/snapshots/pristine-d1" })
                    swapped = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' })
                    stop = [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; reasonCode = 'rolledBack'; machineState = 'restored'; detail = 'The CONVERTING step failed, and the product rolled the machine back to how it was: the resize failed' } }) -Force
            if ($kind -eq 'restore') {
                $d.state = 'MIGRATED'
                $d.history = @($d.history | Select-Object -First 1)
                $d.PSObject.Properties.Remove('rollback')
                $d.swapPending.PSObject.Properties.Remove('stop')
                $d.swapPending.usedBy = ''
                $d.swapPending | Add-Member -NotePropertyName operationId -NotePropertyValue 'op-0' -Force
                if ($pas) { $d.swapPending | Add-Member -NotePropertyName powerAtStart -NotePropertyValue $pas -Force }
                $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ operationId = 'op-0'; restoredUtc = '2026-11-14T10:00:00Z'; restoredBy = 'operator@example.com'; fromCopy = 'pristine'
                        newDiskName = 'vm1-osdisk-restored-x'; newDiskId = "$sub/disks/vm1-osdisk-restored-x"; diskNaming = 'new'
                        dataDisks = @([pscustomobject]@{ lun = 0; previousDiskId = "$sub/disks/vm1-data0"; previousDiskName = 'vm1-data0'; newDiskId = "$sub/disks/vm1-data0-d0-asitwas-x"; newDiskName = 'vm1-data0-d0-asitwas-x' })
                        dataDisksKept = @() }) -Force
            }
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
        $rp
    }
    function Global:VfRecord($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:VfEvents($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    function Global:VfEdit($rp, [scriptblock]$Change) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; change = $Change } {
            param($rp, $id, $change)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            & $change $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }

    # The fake Azure and the fake guest. $global:vf.mounted is what the
    # validation reading reports now; a key "throw:<script>" makes that
    # script's run command fail.
    function Global:VfMocks {
        param([string]$Mounted = '/; /boot; /var/crash')
        $global:vf = @{ power = 'deallocated'; mounted = $Mounted; order = [System.Collections.Generic.List[string]]::new(); throws = @{}; kill = $null
            luns = @{ '0' = "$($script:sub)/disks/vm1-data0-d0-asitwas-x"; '1' = "$($script:sub)/disks/vm1-data1" } }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { "PowerState/$($global:vf.power)" }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @(foreach ($k in @($global:vf.luns.Keys | Sort-Object)) {
                    $id = [string]$global:vf.luns[$k]
                    [pscustomobject]@{ lun = [int]$k; id = $id; name = ($id -split '/')[-1]; resourceGroup = 'rg-app'; skuName = 'Premium_LRS'; caching = 'None' }
                })
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            if ($global:vf.kill -and $global:vf.kill.at -eq 'deallocate' -and @($global:vf.order) -contains 'start' -and -not $global:vf.kill.done) {
                $global:vf.kill.done = $true
                Copy-Item -LiteralPath $global:vf.kill.rp -Destination "$($global:vf.kill.rp).snap" -Recurse
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            }
            $global:vf.order.Add('deallocate'); $global:vf.power = 'deallocated'
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:vf.order.Add('start'); $global:vf.power = 'running' }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:vf.order.Add('agentReady') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            foreach ($s in $Swaps) { $global:vf.luns["$([int]$s.lun)"] = [string]$s.diskId }
            $global:vf.order.Add('swapData')
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
            [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name; Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' }) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $name = [string]$ScriptString
            $global:vf.order.Add("script:$name")
            if ($global:vf.throws.ContainsKey($name)) { throw $global:vf.throws[$name] }
            $checks = switch ($name) {
                { $_ -in @('guest-validate.sh', 'Test-GuestValidation.ps1') } { @(@{ name = 'mounted volumes'; status = 'INFO'; detail = [string]$global:vf.mounted }) }
                'lvm-devices-refresh.sh' { @(@{ name = 'lvm devices refresh'; status = 'FIXED'; detail = 'lvmdevices --update --refresh found each physical volume on its new device' }) }
                default { @() }
            }
            $result = if ($name -in @('guest-validate.sh', 'Test-GuestValidation.ps1')) { 'PASS' } elseif ($name -eq 'lvm-devices-refresh.sh') { 'FIXED' } else { 'READY' }
            [ordered]@{ schema = 'vmf.guest/2'; script = $name; version = '1.0.0'; result = $result; checks = @($checks); warnings = @() } | ConvertTo-Json -Depth 6 -Compress
        }
    }
    function Global:VfAct {
        param([string]$Rp, [switch]$Resume)
        $a = @{ RunPath = $Rp; VmId = $script:vmId; CorrelationId = 'op-1'; Confirm = $false }
        if ($Resume) { $a.Resume = $true } else { $a.FinishedBy = 'operator@example.com'; $a.Note = 'Azure accepts the swap now' }
        Complete-VmfDataDiskSwap @a 3>$null
    }
    function Global:VfAfter([string]$Marker) {
        $all = @($global:vf.order); $at = [array]::LastIndexOf($all, $Marker)
        @($all | Select-Object -Skip ($at + 1))
    }
}
AfterAll {
    Remove-Item function:VfRun, function:VfRecord, function:VfEvents, function:VfEdit, function:VfMocks, function:VfAct, function:VfAfter -ErrorAction SilentlyContinue
    Remove-Variable vf -Scope Global -ErrorAction SilentlyContinue
}

Describe 'VOLUMES-ONLINE-FINISH-1: Finish the rollback checks the volumes' {
    BeforeEach { $script:rp = $null }
    AfterEach {
        if ($script:rp) {
            Remove-Item $script:rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$($script:rp).snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Linux, every volume back: after the start the refresh and the check run, and the stop the rollback kept is recorded' {
        VfMocks
        $script:rp = VfRun -Kind 'rollback'
        $null = VfAct -Rp $script:rp
        $after = @(VfAfter 'swapData')
        $want = @('start', 'agentReady', 'script:lvm-devices-refresh.sh', 'script:neutral-mark.sh', 'script:guest-validate.sh')
        @($after | Where-Object { $_ -in $want }) | Should -Be $want -Because "order: $($after -join ', ')"
        $doc = VfRecord $script:rp
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rolledBack'
        $last.machineState | Should -Be 'restored'
        $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        $lines = @(VfEvents $script:rp | Where-Object { $_.step -eq 'finish' -and $_.detail -match 'Every volume that was mounted before the move is mounted again: /, /boot, /var/crash\.' })
        $lines | Should -Not -BeNullOrEmpty -Because 'the check writes its lines on the finish, not on the rollback that ended'
        @(VfEvents $script:rp | Where-Object { $_.step -eq 'rollback' }) | Should -BeNullOrEmpty
    }

    It 'a volume not mounted: FAILED_NEEDS_ATTENTION, volumesNotBack, changed, and the checked retry is owed' {
        VfMocks -Mounted '/; /boot'
        $script:rp = VfRun -Kind 'rollback'
        $null = VfAct -Rp $script:rp
        $doc = VfRecord $script:rp
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'volumesNotBack'
        $last.machineState | Should -Be 'changed'
        $last.detail | Should -Match 'Finish the rollback swapped the data disks that were left and started the machine\. .* These volumes were mounted before the move and are not mounted now: /var/crash\.'
        $last.detail | Should -Match 'Finish the rollback swapped the data disks that were left'
        $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
        $doc.volumesCheckOwed.kind | Should -Be 'rollback'
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse -Because 'the retry checks the volumes first (VOLUMES-RETRY-CHECK-1)'
    }

    It 'the check cannot run: the stop stays the rollback, says so, and owes the check' {
        VfMocks
        $script:rp = VfRun -Kind 'rollback'
        $global:vf.throws['lvm-devices-refresh.sh'] = 'RunCommand timed out.'
        $null = VfAct -Rp $script:rp
        $doc = VfRecord $script:rp
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rolledBack'
        $last.detail | Should -Match 'The product could not check the volumes inside the machine after the rollback \(RunCommand timed out\)'
        $doc.volumesCheckOwed.reason | Should -Be 'notChecked'
    }

    It 'Windows: no refresh, only the validation script' {
        VfMocks -Mounted 'C:\; F:\'
        $script:rp = VfRun -Kind 'rollback' -Os 'Windows' -Before 'C:\; F:\'
        $null = VfAct -Rp $script:rp
        @($global:vf.order | Where-Object { $_ -like 'script:*' }) | Should -Be @('script:Test-GuestValidation.ps1')
        (VfRecord $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
    }
}

Describe 'VOLUMES-ONLINE-FINISH-1: Finish the restore checks the volumes' {
    BeforeEach { $script:rp = $null }
    AfterEach {
        if ($script:rp) {
            Remove-Item $script:rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$($script:rp).snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'every volume back: the restore ends, and a check owed from before is removed in the same write' {
        VfMocks
        $script:rp = VfRun -Kind 'restore'
        VfEdit $script:rp { param($d) $d | Add-Member -NotePropertyName volumesCheckOwed -Force -NotePropertyValue ([pscustomobject]@{ reason = 'volumesNotBack'; kind = 'restore'; tsUtc = '2026-11-14T09:00:00Z' }) }
        $r = VfAct -Rp $script:rp
        $r.Started | Should -BeTrue
        $doc = VfRecord $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        @($doc.history | Where-Object { $_.reasonCode -eq 'volumesNotBack' }) | Should -BeNullOrEmpty
        @(VfEvents $script:rp | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'ok' -and $_.detail -match 'Every volume that was mounted before the move is mounted again' }) | Should -Not -BeNullOrEmpty
    }

    It 'a volume not mounted: the restore is recorded, the stop volumesNotBack says it, the machine is changed, and the finish says it did not bring every volume back' {
        VfMocks -Mounted '/; /boot'
        $script:rp = VfRun -Kind 'restore'
        { VfAct -Rp $script:rp } | Should -Throw -ExpectedMessage '*These volumes were mounted before the move and are not mounted now: /var/crash.*'
        $doc = VfRecord $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty -Because 'every disk is back'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'volumesNotBack'
        $last.machineState | Should -Be 'changed'
        $last.state | Should -Be 'MIGRATED'
        $last.detail | Should -Match '^Finish the restore swapped the other data disks\. These volumes were mounted before the move and are not mounted now: /var/crash\.$'
        $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
        $doc.volumesCheckOwed.kind | Should -Be 'restore'
        @(VfEvents $script:rp | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'warn' }) | Should -Not -BeNullOrEmpty
    }

    It 'the check cannot run: the restore ends, and the check is owed' {
        VfMocks
        $script:rp = VfRun -Kind 'restore'
        $global:vf.throws['guest-validate.sh'] = 'RunCommand timed out.'
        $null = VfAct -Rp $script:rp
        $doc = VfRecord $script:rp
        $doc.volumesCheckOwed.reason | Should -Be 'notChecked'
        @($doc.history | Where-Object { $_.reasonCode -eq 'volumesNotBack' }) | Should -BeNullOrEmpty
    }

    It 'kill and resume (rule 4): the check is on the checkpoint before the power state goes back, and a resume never asks the stopped machine' {
        VfMocks -Mounted '/; /boot'
        $script:rp = VfRun -Kind 'restore' -PowerAtStart 'PowerState/deallocated'
        $global:vf.kill = @{ at = 'deallocate'; rp = $script:rp; done = $false }
        { VfAct -Rp $script:rp } | Should -Throw '*abandon this VM*'
        Remove-Item $script:rp -Recurse -Force
        Move-Item -LiteralPath "$($script:rp).snap" -Destination $script:rp
        $found = VfRecord $script:rp
        $found.putBackJob.kind | Should -Be 'finish'
        $found.putBackJob.volumes.verdict | Should -Be 'MISSING'
        $global:vf.order.Clear()
        $global:vf.power = 'deallocated'
        { VfAct -Rp $script:rp -Resume } | Should -Throw -ExpectedMessage '*/var/crash*'
        @($global:vf.order | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty -Because 'the resume uses the check on the checkpoint'
        $doc = VfRecord $script:rp
        @($doc.history)[-1].reasonCode | Should -Be 'volumesNotBack'
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }

    It 'kill and resume (rule 4), Finish the rollback: the resume finds the check and records the stop it owes' {
        VfMocks -Mounted '/; /boot'
        $script:rp = VfRun -Kind 'rollback'
        # The power state Checking found: deallocated, so the finish returns it.
        VfEdit $script:rp { param($d) $d.captured | Add-Member -NotePropertyName clusterCheckPower -Force -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/deallocated'; status = 'started' }) }
        $global:vf.kill = @{ at = 'deallocate'; rp = $script:rp; done = $false }
        { VfAct -Rp $script:rp } | Should -Throw '*abandon this VM*'
        Remove-Item $script:rp -Recurse -Force
        Move-Item -LiteralPath "$($script:rp).snap" -Destination $script:rp
        (VfRecord $script:rp).putBackJob.volumes.verdict | Should -Be 'MISSING'
        $global:vf.order.Clear()
        $null = VfAct -Rp $script:rp -Resume
        @($global:vf.order | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty
        @((VfRecord $script:rp).history)[-1].reasonCode | Should -Be 'volumesNotBack'
    }
}

Describe 'VOLUMES-ONLINE-WINDOWS-1: which data disks the product brings online (pure)' {
    It 'reads the data disks fact; a reading with none is unknown, and none is an empty list' {
        InModuleScope VmMigrationFactory {
            $g = { param($d) [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'; status = 'INFO'; detail = $d }) } }
            # The list comes as one item, so an empty list stays a list (as Get-VmfMountedVolumes).
            $rows = Get-VmfDataDiskStates -GuestOutput (& $g 'gpt:3f2504e0-4f89-11d3-9a0c-0305e82c3301=2:offline:writable; mbr:0a1b2c3d=3:online:readonly')
            $rows.Count | Should -Be 2
            $rows[0].Key | Should -Be 'gpt:3f2504e0-4f89-11d3-9a0c-0305e82c3301'
            $rows[0].Number | Should -Be 2
            $rows[0].Offline | Should -BeTrue
            $rows[0].ReadOnly | Should -BeFalse
            $rows[1].Key | Should -Be 'mbr:0a1b2c3d'
            $rows[1].ReadOnly | Should -BeTrue
            $notAsked = Get-VmfDataDiskStates -GuestOutput ([pscustomobject]@{ checks = @() })
            $null -eq $notAsked | Should -BeTrue -Because 'not asked is not an empty list'
            $none = Get-VmfDataDiskStates -GuestOutput (& $g 'none')
            $null -eq $none | Should -BeFalse
            @($none).Count | Should -Be 0
            # A part that is not a disk key is not read as one.
            $some = Get-VmfDataDiskStates -GuestOutput (& $g 'x; gpt:not-a-guid=1:offline:writable; mbr:0a1b2c3d=3:offline:writable')
            @($some).Count | Should -Be 1
        }
    }

    It 'brings online only a disk that was online before the move; a disk offline before stays offline' {
        InModuleScope VmMigrationFactory {
            $g = { param($d) [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'; status = 'INFO'; detail = $d }) } }
            $before = & $g 'mbr:0000000f=2:online:writable; mbr:0000000a=3:offline:writable; mbr:0000000b=4:online:writable'
            $after = & $g 'mbr:0000000f=1:offline:writable; mbr:0000000a=2:offline:writable; mbr:0000000b=3:online:writable; mbr:0000000c=4:offline:writable'
            $t = Get-VmfDisksToBringOnline -Before $before -After $after
            @($t.Online | ForEach-Object Key) | Should -Be @('mbr:0000000f') -Because 'F was online before; A was offline before; C is not in the reading before the move'
            @($t.Writable).Count | Should -Be 0
        }
    }

    It 'turns off read-only only on a disk that was writable before the move; a disk read-only before stays read-only' {
        InModuleScope VmMigrationFactory {
            $g = { param($d) [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'; status = 'INFO'; detail = $d }) } }
            $before = & $g 'mbr:0000000f=2:online:writable; mbr:0000000a=3:online:readonly'
            $after = & $g 'mbr:0000000f=2:offline:readonly; mbr:0000000a=3:online:readonly'
            $t = Get-VmfDisksToBringOnline -Before $before -After $after
            @($t.Online | ForEach-Object Key) | Should -Be @('mbr:0000000f')
            @($t.Writable | ForEach-Object Key) | Should -Be @('mbr:0000000f')
        }
    }

    It 'never sends an empty list to the script: a disk that is only read-only now sends WritableKeys alone, one only Offline sends OnlineKeys alone' {
        InModuleScope VmMigrationFactory {
            $g = { param($d) [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'; status = 'INFO'; detail = $d }) } }
            $script:vfSent = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfGuestScriptOnVm { $script:vfSent.Add($Parameters); [pscustomobject]@{ result = 'FIXED'; checks = @([pscustomobject]@{ name = 'disk writable'; status = 'FIXED'; detail = 'disk 2' }) } }
            Mock Write-VmfStepLine { }
            # Nothing is written: the guest run and the activity line are stand-ins. The path is under the temporary folder (LITTER-1).
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-vf-not-written'
            $before = & $g 'mbr:0000000f=2:online:writable'
            $null = Invoke-VmfWindowsDisksOnline -RunPath $rp -VmId 'v' -ResourceGroupName 'rg' -VmName 'vm' -Before $before -After (& $g 'mbr:0000000f=2:online:readonly') -Step 'VALIDATING'
            $null = Invoke-VmfWindowsDisksOnline -RunPath $rp -VmId 'v' -ResourceGroupName 'rg' -VmName 'vm' -Before $before -After (& $g 'mbr:0000000f=2:offline:writable') -Step 'VALIDATING'
            $script:vfSent.Count | Should -Be 2
            @($script:vfSent[0].Keys) | Should -Be @('WritableKeys')
            $script:vfSent[0].WritableKeys | Should -Be 'mbr:0000000f'
            @($script:vfSent[1].Keys) | Should -Be @('OnlineKeys')
            foreach ($p in $script:vfSent) { foreach ($k in $p.Keys) { [string]$p[$k] | Should -Not -BeNullOrEmpty } }
        }
    }

    It 'with no reading on either side it does nothing' {
        InModuleScope VmMigrationFactory {
            $g = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'; status = 'INFO'; detail = 'mbr:0000000f=2:offline:writable' }) }
            $t = Get-VmfDisksToBringOnline -Before $null -After $g
            @($t.Online).Count | Should -Be 0
            $t = Get-VmfDisksToBringOnline -Before $g -After ([pscustomobject]@{ checks = @() })
            @($t.Online).Count | Should -Be 0
        }
    }
}

Describe 'VOLUMES-ONLINE-WINDOWS-1: the Windows guest scripts' {
    BeforeAll {
        $script:fnOf = {
            param([string]$File, [string]$Name)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:winDir $File), [ref]$null, [ref]$null)
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
            if ($fn) { $fn.Extent.Text } else { $null }
        }
        # Four disks: the OS disk, F (GPT, offline now), G (MBR, read-only
        # and offline), and a raw disk with no key.
        $script:fakeDisks = {
            @(
                [pscustomobject]@{ Number = 0; IsBoot = $true; IsSystem = $true; PartitionStyle = 'GPT'; Guid = '{11111111-2222-3333-4444-555555555555}'; Signature = $null; IsOffline = $false; IsReadOnly = $false }
                [pscustomobject]@{ Number = 2; IsBoot = $false; IsSystem = $false; PartitionStyle = 'GPT'; Guid = '{3F2504E0-4F89-11D3-9A0C-0305E82C3301}'; Signature = $null; IsOffline = $true; IsReadOnly = $false }
                [pscustomobject]@{ Number = 3; IsBoot = $false; IsSystem = $false; PartitionStyle = 'MBR'; Guid = $null; Signature = [uint32]168496141; IsOffline = $true; IsReadOnly = $true }
                [pscustomobject]@{ Number = 4; IsBoot = $false; IsSystem = $false; PartitionStyle = 'RAW'; Guid = $null; Signature = $null; IsOffline = $true; IsReadOnly = $false })
        }
    }

    It 'the key of a disk is one text in both scripts' {
        $a = & $script:fnOf 'Test-GuestValidation.ps1' 'Get-VmfDiskKey'
        $b = & $script:fnOf 'Set-DataDisksOnline.ps1' 'Get-VmfDiskKey'
        $a | Should -Not -BeNullOrEmpty
        $b | Should -Be $a
    }

    It 'Test-GuestValidation.ps1 reports each data disk with its key, number, online and read-only state; not the OS disk, not a disk with no key' {
        $key = & $script:fnOf 'Test-GuestValidation.ps1' 'Get-VmfDiskKey'
        $list = & $script:fnOf 'Test-GuestValidation.ps1' 'Get-VmfDataDiskStateList'
        $list | Should -Not -BeNullOrEmpty
        $fake = $script:fakeDisks
        $out = & {
            . ([scriptblock]::Create($key)); . ([scriptblock]::Create($list))
            function Get-Disk { & $fake }
            Get-VmfDataDiskStateList
        }
        @($out) | Should -Be @('gpt:3f2504e0-4f89-11d3-9a0c-0305e82c3301=2:offline:writable', 'mbr:0a0b0c0d=3:offline:readonly')
        (Get-VmfCodeOnly -Path (Join-Path $script:winDir 'Test-GuestValidation.ps1')) | Should -Match "Add-Check 'data disks' 'INFO'"
    }

    It 'Set-DataDisksOnline.ps1 brings online only the disks it is given, then turns off read-only only where it is given; the OS disk and a disk with no key are never touched' {
        $key = & $script:fnOf 'Set-DataDisksOnline.ps1' 'Get-VmfDiskKey'
        $set = & $script:fnOf 'Set-DataDisksOnline.ps1' 'Set-VmfDataDisksOnline'
        $set | Should -Not -BeNullOrEmpty
        $fake = $script:fakeDisks
        $calls = [System.Collections.Generic.List[string]]::new()
        $checks = & {
            . ([scriptblock]::Create($key)); . ([scriptblock]::Create($set))
            function Get-Disk { & $fake }
            function Set-Disk { param($Number, $IsOffline, $IsReadOnly) if ($PSBoundParameters.ContainsKey('IsOffline')) { $calls.Add("offline:$Number=$IsOffline") } else { $calls.Add("readonly:$Number=$IsReadOnly") } }
            # Azure may hand the two lists as one text or as an array: both work.
            Set-VmfDataDisksOnline -OnlineKeys @('gpt:3f2504e0-4f89-11d3-9a0c-0305e82c3301,mbr:0a0b0c0d', 'not-a-key') -WritableKeys 'mbr:0a0b0c0d'
        }
        @($calls) | Should -Be @('offline:2=False', 'offline:3=False', 'readonly:3=False')
        @($checks | Where-Object { $_.name -eq 'disk online' -and $_.status -eq 'FIXED' } | ForEach-Object { $_.detail }) | Should -Be @('disk 2', 'disk 3')
        @($checks | Where-Object { $_.name -eq 'disk writable' -and $_.status -eq 'FIXED' } | ForEach-Object { $_.detail }) | Should -Be @('disk 3')
    }

    It 'a disk Windows refuses to bring online is a FAIL check that names it, and the others still go online' {
        $key = & $script:fnOf 'Set-DataDisksOnline.ps1' 'Get-VmfDiskKey'
        $set = & $script:fnOf 'Set-DataDisksOnline.ps1' 'Set-VmfDataDisksOnline'
        $fake = $script:fakeDisks
        $checks = & {
            . ([scriptblock]::Create($key)); . ([scriptblock]::Create($set))
            function Get-Disk { & $fake }
            function Set-Disk { param($Number, $IsOffline, $IsReadOnly) if ($Number -eq 2) { throw 'The disk has a signature collision.' } }
            Set-VmfDataDisksOnline -OnlineKeys 'gpt:3f2504e0-4f89-11d3-9a0c-0305e82c3301,mbr:0a0b0c0d' -WritableKeys ''
        }
        $f = @($checks | Where-Object { $_.status -eq 'FAIL' })
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match '^disk 2: The disk has a signature collision\.'
        @($checks | Where-Object { $_.name -eq 'disk online' -and $_.status -eq 'FIXED' } | ForEach-Object { $_.detail }) | Should -Be @('disk 3')
    }

    It 'both stay Windows PowerShell 5.1, and Set-DataDisksOnline.ps1 is in the manifest, followed by the neutral script, and not a preparation script' {
        foreach ($f in 'Set-DataDisksOnline.ps1', 'Test-GuestValidation.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:winDir $f)
            $code | Should -Not -Match '\?\?'
            $code | Should -Not -Match '\?\.'
        }
        InModuleScope VmMigrationFactory {
            (Get-VmfGuestScript -Name 'Set-DataDisksOnline.ps1').Os | Should -Be 'windows'
            $script:VmfGuestFollowUpScripts | Should -Contain 'Set-DataDisksOnline.ps1'
            $script:VmfGuestChangerScripts | Should -Not -Contain 'Set-DataDisksOnline.ps1'
        }
    }
}
