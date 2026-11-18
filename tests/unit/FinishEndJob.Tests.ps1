#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# FINISH-END-JOB-1: a finish whose job stops is started again.
#
# Finish the rollback and Finish the restore (Complete-VmfDataDiskSwap,
# SWAP-REFUSED-AFTER-STOP-1) run as an engine job once, like a restore. A job
# the platform stops - out of memory, the time limit, a restart - wrote nothing
# more, and nothing started it again: the machine stayed stopped until a person
# noticed and pressed Finish again. RESTORE-END-JOB-1 made a restore and a
# rebuild resume; a finish now uses the SAME mechanism: a checkpoint on the
# machine's record (putBackJob, kind finish), the service's timer
# (Invoke-VmfFacadeResumeStalledPutBacks) and the same operation id
# (VMF_RESUME_ID). Never a second mechanism.
#
# THE KILL HARNESS (as RestoreEndJob.Tests.ps1). A real kill runs no catch and
# no finally. So a test kill copies the run store and the fake Azure AT THE
# INSTANT the process dies (a chosen call, before or after Azure did it), lets
# the job unwind, then puts that copy back - what a new container finds - and
# resumes. Every Azure call of the uninterrupted finish is a kill point, before
# and after the call (and between the two updates of a data disk swap), so
# every step has its kill-resume test (rule 4).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    function Global:FeDisk([string]$Name) { "$($script:sub)/disks/$Name" }

    # A machine a rollback (or a restore) left stopped: its OS disk and LUN 0
    # back from the copy, LUN 1 (plain) and LUN 2 (Premium SSD v2) not - two
    # batches, so a kill can fall between them.
    function Global:FeRun {
        param([ValidateSet('rollback', 'restore')][string]$Kind = 'rollback')
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-fe-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; kind = $Kind } {
            param($rp, $id, $sub, $kind)
            Initialize-VmfRun -RunPath $rp -RunId 'fe' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'fe' -VmId $id -Wave 'w1' | Out-Null
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" }
                        dataDisks = @(
                            [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' }
                            [pscustomobject]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$sub/disks/vm1-data1"; caching = 'None'; sizeGB = 256; skuName = 'Premium_LRS' }
                            [pscustomobject]@{ name = 'vm1-data2'; lun = 2; managedDiskId = "$sub/disks/vm1-data2"; caching = 'None'; sizeGB = 256; skuName = 'PremiumV2_LRS' })
                        nics = @(); tags = @{} } }) -Force
            $d.state = 'FAILED_NEEDS_ATTENTION'
            $d.history = @($d.history) + @([pscustomobject]@{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'dataDiskSwapRefused'; machineState = 'changed'; detail = 'left' })
            $d | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-23T10:00:00Z'; path = 'A'
                    osDisk = [pscustomobject]@{ id = "$sub/disks/vm1-osdisk-asitwas-x"; name = 'vm1-osdisk-asitwas-x' }
                    dataDisks = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' }); keptDataDisks = @() }) -Force
            $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @();
                    kind = $kind; leftUtc = '2026-10-23T10:00:00Z'; error = 'OperationNotAllowed: the disk is in use'; usedBy = 'rollback-x'
                    swaps = @(
                        [pscustomobject]@{ lun = 1; name = 'vm1-data1'; oldDiskId = "$sub/disks/vm1-data1"; diskId = "$sub/disks/vm1-data1-d1-asitwas-x"; diskName = 'vm1-data1-d1-asitwas-x'; caching = 'None'; instantAccess = $false; snapshotId = "$sub/snapshots/pristine-d1" }
                        [pscustomobject]@{ lun = 2; name = 'vm1-data2'; oldDiskId = "$sub/disks/vm1-data2"; diskId = "$sub/disks/vm1-data2-d2-asitwas-x"; diskName = 'vm1-data2-d2-asitwas-x'; caching = 'None'; instantAccess = $true; snapshotId = "$sub/snapshots/pristine-d2" })
                    swapped = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' })
                    stop = [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; reasonCode = 'rolledBack'; machineState = 'restored'; detail = 'CONVERTING failed; the machine was rolled back to how it was: the resize failed' } }) -Force
            if ($kind -eq 'restore') {
                $d.state = 'MIGRATED'
                $d.history = @($d.history | Select-Object -First 1)
                $d.PSObject.Properties.Remove('rollback')
                $d.swapPending.PSObject.Properties.Remove('stop')
                $d.swapPending.usedBy = ''
                # A restore's swap record and its own record name its operation (vm-state v32).
                $d.swapPending | Add-Member -NotePropertyName operationId -NotePropertyValue 'op-0' -Force
                $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ operationId = 'op-0'; restoredUtc = '2026-10-23T10:00:00Z'; restoredBy = 'operator@example.com'; fromCopy = 'pristine'
                        newDiskName = 'vm1-osdisk-restored-x'; newDiskId = "$sub/disks/vm1-osdisk-restored-x"; diskNaming = 'new'
                        dataDisks = @([pscustomobject]@{ lun = 0; previousDiskId = "$sub/disks/vm1-data0"; previousDiskName = 'vm1-data0'; newDiskId = "$sub/disks/vm1-data0-d0-asitwas-x"; newDiskName = 'vm1-data0-d0-asitwas-x' })
                        dataDisksKept = @() }) -Force
            }
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
        $rp
    }
    function Global:FeRecord($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:FeEvents($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    function Global:FeEdit($rp, [scriptblock]$Change) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; change = $Change } {
            param($rp, $id, $change)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            & $change $doc
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }

    # The fake Azure: the stopped machine and what is on each LUN, kept as
    # state, so a resume meets what the killed job left.
    function Global:FeAzure {
        $global:fe = @{
            power = 'deallocated'
            luns = @{ '0' = (FeDisk 'vm1-data0-d0-asitwas-x'); '1' = (FeDisk 'vm1-data1'); '2' = (FeDisk 'vm1-data2') }
            sources = @{ (FeDisk 'vm1-data1-d1-asitwas-x') = "$($script:sub)/snapshots/pristine-d1"; (FeDisk 'vm1-data2-d2-asitwas-x') = "$($script:sub)/snapshots/pristine-d2" }
            refuseLun = -1
            sites = [System.Collections.Generic.List[string]]::new(); seen = @{}
            swaps = [System.Collections.Generic.List[string]]::new(); attaches = [System.Collections.Generic.List[string]]::new()
            killAt = $null; dead = $false; snap = $null; rp = $null
        }
    }
    function Global:FeClone($o) { $o | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable }
    function Global:FeKill([string]$Site) {
        $f = $global:fe
        if ($f.dead) { throw 'VMF-TEST-KILLED: the process is gone' }
        $f.sites.Add($Site)
        $n = 1 + [int]$f.seen[$Site]
        $f.seen[$Site] = $n
        if ($f.killAt -and $f.killAt.site -eq $Site -and $f.killAt.n -eq $n) {
            Copy-Item -LiteralPath $f.rp -Destination "$($f.rp).snap" -Recurse
            $f.snap = @{ power = $f.power; luns = (FeClone $f.luns) }
            $f.dead = $true
            throw 'VMF-TEST-KILLED: the process is gone'
        }
    }
    function Global:FeMocks {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { "PowerState/$($global:fe.power)" }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            Global:FeKill 'read'
            @(foreach ($k in @($global:fe.luns.Keys | Sort-Object { [int]$_ })) {
                    $id = [string]$global:fe.luns[$k]
                    if (-not $id) { continue }
                    [pscustomobject]@{ lun = [int]$k; id = $id; name = ($id -split '/')[-1]; resourceGroup = 'rg-app'; skuName = 'Premium_LRS'; caching = 'None' }
                })
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            Global:FeKill 'stop:before'
            $global:fe.power = 'deallocated'
            Global:FeKill 'stop:after'
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            Global:FeKill 'start:before'
            $global:fe.power = 'running'
            Global:FeKill 'start:after'
        }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { Global:FeKill 'agent:before' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            Global:FeKill 'swapData:before'
            if ($global:fe.power -ne 'deallocated') { throw 'Azure swaps data disks here only on a stopped machine' }
            foreach ($s in $Swaps) { if (-not $global:fe.luns["$([int]$s.lun)"]) { throw "Machine 'vm1' has no data disk on LUN $($s.lun)." } }
            if (@($Swaps | Where-Object { [int]$_.lun -eq $global:fe.refuseLun }).Count) { return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' } }
            foreach ($s in $Swaps) { $global:fe.swaps.Add("$([int]$s.lun)") }
            foreach ($s in $Swaps) { $global:fe.luns["$([int]$s.lun)"] = '' }
            # SWAP-2UPD-1: two updates; the job can stop between them.
            Global:FeKill 'swapData:between'
            foreach ($s in $Swaps) { $global:fe.luns["$([int]$s.lun)"] = [string]$s.diskId }
            Global:FeKill 'swapData:after'
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            Global:FeKill 'attachEmpty:before'
            if ($global:fe.power -ne 'deallocated') { throw 'Azure attaches data disks here only on a stopped machine' }
            $key = "$([int]$Lun)"
            $have = [string]$global:fe.luns[$key]
            if ($have) { if ($have -eq $DiskId) { return @{ Applied = $true } }; throw "Machine 'vm1' has the disk '$have' on LUN $Lun." }
            $global:fe.luns[$key] = $DiskId
            $global:fe.attaches.Add("$key/$Caching")
            Global:FeKill 'attachEmpty:after'
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $by = if (@($global:fe.luns.Values) -contains $DiskId) { $script:vmId } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $by; SourceResourceId = [string]$global:fe.sources[$DiskId] }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
    }
    function Global:FeState {
        [ordered]@{ power = $global:fe.power
            luns = @(foreach ($k in @($global:fe.luns.Keys | Sort-Object { [int]$_ })) { "$k=$((([string]$global:fe.luns[$k]) -split '/')[-1])" }) -join ',' } | ConvertTo-Json -Compress
    }
    function Global:FeRecordFacts($doc) {
        [ordered]@{ state = $doc.state
            swapPending = [bool]$doc.PSObject.Properties['swapPending']
            putBackJob = [bool]$doc.PSObject.Properties['putBackJob']
            rollbackLuns = @(@($doc.rollback.dataDisks) | Where-Object { $_ } | ForEach-Object { [string]$_.lun }) -join ','
            restoreLuns = @(@($doc.restore.dataDisks) | Where-Object { $_ } | ForEach-Object { [string]$_.lun }) -join ',' } | ConvertTo-Json -Compress
    }
    function Global:FeAct {
        param([string]$Rp, [switch]$Resume)
        $a = @{ RunPath = $Rp; VmId = $script:vmId; CorrelationId = 'op-1'; Confirm = $false }
        if ($Resume) { $a.Resume = $true } else { $a.FinishedBy = 'operator@example.com'; $a.Note = 'Azure accepts the swap now' }
        Complete-VmfDataDiskSwap @a 3>$null
    }
    function Global:FeReference([string]$Kind) {
        FeAzure
        $rp = FeRun -Kind $Kind
        $global:fe.rp = $rp
        try {
            $null = FeAct -Rp $rp
            $points = [System.Collections.Generic.List[object]]::new()
            $count = @{}
            foreach ($s in $global:fe.sites) { $count[$s] = 1 + [int]$count[$s]; $points.Add([pscustomobject]@{ site = $s; n = $count[$s] }) }
            [pscustomobject]@{ State = (FeState); Points = @($points); Record = (FeRecord $rp); Starts = @($global:fe.sites | Where-Object { $_ -eq 'start:before' }).Count }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    function Global:FeRevive([string]$Rp) {
        Remove-Item $Rp -Recurse -Force
        Move-Item -LiteralPath "$Rp.snap" -Destination $Rp
        $global:fe.power = $global:fe.snap.power; $global:fe.luns = $global:fe.snap.luns
        $global:fe.dead = $false; $global:fe.killAt = $null; $global:fe.snap = $null
        $global:fe.sites.Clear(); $global:fe.swaps.Clear(); $global:fe.attaches.Clear()
    }
    function Global:FeKillAndResume([string]$Kind, [string]$Site, [int]$N) {
        FeAzure
        $rp = FeRun -Kind $Kind
        $global:fe.rp = $rp
        $global:fe.killAt = @{ site = $Site; n = $N }
        try {
            try { $null = FeAct -Rp $rp } catch { $null = $_ }
            if (-not $global:fe.snap) { return [pscustomobject]@{ Killed = $false } }
            FeRevive $rp
            $found = FeRecord $rp
            $lunsAtKill = FeClone $global:fe.luns
            $err = $null
            try { $null = FeAct -Rp $rp -Resume } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Killed = $true; Found = $found; LunsAtKill = $lunsAtKill; State = (FeState); Error = $err; Record = (FeRecord $rp); Events = @(FeEvents $rp)
                Starts = @($global:fe.sites | Where-Object { $_ -eq 'start:before' }).Count; Swaps = @($global:fe.swaps); Sites = @($global:fe.sites) }
        }
        finally {
            Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$rp.snap" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    function Global:FeEveryKill([string]$Kind) {
        FeMocks
        $ref = FeReference -Kind $Kind
        $bad = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($p in $ref.Points) {
            $r = FeKillAndResume -Kind $Kind -Site $p.site -N $p.n
            $where = "killed at $($p.site) #$($p.n)"
            if (-not $r.Killed) { $bad.Add("${where}: the kill did not happen"); continue }
            $checked++
            $job = $r.Found.putBackJob
            if (-not $job -or [string]$job.kind -ne 'finish' -or [string]$job.operationId -ne 'op-1' -or $job.ended) { $bad.Add("${where}: the record holds no open finish to resume"); continue }
            if ($r.Error) { $bad.Add("${where}: the resume failed: $($r.Error)"); continue }
            if ($r.State -ne $ref.State) { $bad.Add("${where}: ended $($r.State), not $($ref.State)") }
            $a = FeRecordFacts $ref.Record
            $b = FeRecordFacts $r.Record
            if ($a -ne $b) { $bad.Add("${where}: the record says $b, not $a") }
            # Never a second swap of a LUN Azure already put on its disk.
            foreach ($lun in $r.Swaps) {
                $had = [string]$r.LunsAtKill[$lun]
                if ($had -notmatch 'vm1-data\d$') { $bad.Add("${where}: the resume swapped LUN $lun, which held '$had'") }
            }
            # The machine starts once: the resume starts it, unless the step
            # that started it was saved before the kill.
            $wantStarts = if ([string]$job.phase -eq 'started') { 0 } else { 1 }
            if ($r.Starts -ne $wantStarts) { $bad.Add("${where}: the resume started the machine $($r.Starts) times, not $wantStarts (phase $($job.phase))") }
            if (-not @($r.Events | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'info' -and $_.detail -match 'started again after its job stopped' }).Count) {
                $bad.Add("${where}: no line says it started again")
            }
            if (@($r.Events | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'start' }).Count -ne 1) { $bad.Add("${where}: the resume wrote a second start line") }
            if (-not @($r.Events | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'ok' }).Count) { $bad.Add("${where}: no line ends the finish") }
        }
        [pscustomobject]@{ Bad = @($bad); Checked = $checked; Reference = $ref }
    }
}
AfterAll {
    Remove-Item function:FeDisk, function:FeRun, function:FeRecord, function:FeEvents, function:FeEdit, function:FeAzure, function:FeClone, function:FeKill,
        function:FeMocks, function:FeState, function:FeRecordFacts, function:FeAct, function:FeReference, function:FeRevive, function:FeKillAndResume,
        function:FeEveryKill, function:Invoke-AzRestMethod -ErrorAction SilentlyContinue
    Remove-Variable fe -Scope Global -ErrorAction SilentlyContinue
}

Describe 'FINISH-END-JOB-1: the checkpoint of a finish (pure rules)' {
    It 'a finish is a kind of job: its words are the finish it does, and its own resume passes the refusal' {
        InModuleScope VmMigrationFactory {
            $job = [pscustomobject]@{ kind = 'finish'; operationId = 'op-1'; options = [pscustomobject]@{ finishes = 'rollback' }; phase = 'begun'; resumes = 0 }
            Get-VmfPutBackJobWords -Job $job | Should -Be 'Finish the rollback'
            $job.options.finishes = 'restore'
            Get-VmfPutBackJobWords -Job $job | Should -Be 'Finish the restore'
            Get-VmfPutBackJobWords -Job ([pscustomobject]@{ kind = 'restore' }) | Should -Be 'Restore this machine'
            $doc = [pscustomobject]@{ putBackJob = $job }
            $words = Get-VmfPutBackJobRefusal -Doc $doc -VmName 'vm1'
            $words | Should -Match "^Finish the restore of 'vm1' has not ended\."
            $words | Should -Match 'starts it again by itself'
            Get-VmfPutBackJobRefusal -Doc $doc -VmName 'vm1' -OperationId 'op-1' | Should -BeNullOrEmpty
            Get-VmfPutBackHoldWhy -Doc $doc | Should -Match '^Finish the restore of this machine has not ended'
        }
    }
    It 'an end line of a finish is its own ok, warn or fail line, or the engine''s finish fail line with its id' {
        InModuleScope VmMigrationFactory {
            $id = 'vm-x'
            $start = [pscustomobject]@{ step = 'finish'; outcome = 'start'; vmId = $id; correlationId = 'op-1' }
            Test-VmfPutBackEndWritten -Events @($start) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeFalse
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'finish'; outcome = 'info'; vmId = $id }) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeFalse
            foreach ($o in 'ok', 'warn', 'fail') {
                Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'finish'; outcome = $o; vmId = $id }) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeTrue
            }
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'engine:finish'; outcome = 'fail'; vmId = $id; correlationId = 'op-1' }) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeTrue
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'engine:finish'; outcome = 'fail'; vmId = $id; correlationId = 'op-2' }) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeFalse
            Test-VmfPutBackEndWritten -Events @($start, [pscustomobject]@{ step = 'restore'; outcome = 'ok'; vmId = $id }) -VmId $id -Kind 'finish' -OperationId 'op-1' | Should -BeFalse
        }
    }
    It 'a resume takes only its own finish: another id, a restore and an ended finish are refused before anything changes' {
        FeMocks; FeAzure
        $rp = FeRun
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'rollback' } -Stamp '202611020900'
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-2' } | Should -Throw "There is no Finish the rollback of 'vm1' with the id 'op-2'*"
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-1' } | Should -Throw '*There is no Restore this machine*'
                (Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1').Job.kind | Should -Be 'finish'
                Close-VmfPutBackJob -Token $t
                { Get-VmfPutBackJobToken -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' } | Should -Throw "Finish the rollback of 'vm1' ended already*"
            }
            $global:fe.sites.Count | Should -Be 0
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'FINISH-END-JOB-1: Finish keeps a checkpoint (rule 4)' {
    BeforeEach { FeMocks; FeAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It '<Kind>: the checkpoint is written before the start line and before anything changes, and goes in the same write as the record that ends the finish' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }
    ) {
        $script:rp = FeRun -Kind $Kind
        $global:fe.rp = $script:rp
        $script:seen = [System.Collections.Generic.List[object]]::new()
        $script:started = [System.Collections.Generic.List[bool]]::new()
        $script:azureAt = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName VmMigrationFactory Write-VmfStateDoc {
            $script:seen.Add(($Document | ConvertTo-Json -Depth 24 | ConvertFrom-Json))
            $script:azureAt.Add($global:fe.sites.Count)
            # Was the start line written before this write?
            $script:started.Add([bool]@(& (Get-Module VmMigrationFactory) { param($rp) @(Read-VmfEvents -RunPath $rp) } $RunPath | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'start' }).Count)
            & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $d.vmId) + '.json') -Document $d } $RunPath $Document
        }
        $null = FeAct -Rp $script:rp
        $first = $script:seen[0]
        $script:started[0] | Should -BeFalse -Because 'the checkpoint is written before the start line'
        $script:azureAt[0] | Should -Be 0 -Because 'the checkpoint is written before the finish asks Azure anything or changes the machine'
        $first.putBackJob.kind | Should -Be 'finish'
        $first.putBackJob.operationId | Should -Be 'op-1'
        $first.putBackJob.options.finishes | Should -Be $Kind
        $first.putBackJob.startedBy | Should -Be 'operator@example.com'
        $first.putBackJob.note | Should -Be 'Azure accepts the swap now'
        $first.putBackJob.phase | Should -Be 'begun'
        $first.schemaVersion | Should -Be 51

        # Never a moment with neither, nor with the finish ended and its
        # checkpoint left behind.
        foreach ($d in $script:seen) {
            [bool]$d.PSObject.Properties['swapPending'] | Should -Be ([bool]$d.PSObject.Properties['putBackJob'])
        }
        $doc = FeRecord $script:rp
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($script:seen | Where-Object { $_.putBackJob.phase -eq 'dataSwapped' }).Count | Should -BeGreaterThan 0
        @($script:seen | Where-Object { $_.putBackJob.phase -eq 'started' }).Count | Should -BeGreaterThan 0
    }

    It 'a finish that Azure refuses again ends with the answer it said: its checkpoint is marked ended, and it is never resumed' {
        $script:rp = FeRun
        $global:fe.refuseLun = 2
        { FeAct -Rp $script:rp } | Should -Throw '*stays stopped*'
        $job = (FeRecord $script:rp).putBackJob
        $job.kind | Should -Be 'finish'
        $job.ended.outcome | Should -Be 'fail'
        { FeAct -Rp $script:rp -Resume } | Should -Throw '*ended already*'
        # A person can press Finish again: an ended job refuses nothing.
        $global:fe.refuseLun = -1
        $null = FeAct -Rp $script:rp
        (FeRecord $script:rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        $global:fe.power | Should -Be 'running'
    }

    It 'a restore that starts after the finish asked and before it writes its checkpoint is never kept as prior: the finish is refused, and the restore''s record stays' {
        $script:rp = FeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-r' -StartedBy 'b@example.com' -Options @{ from = 'pristine'; diskNaming = 'new' } -Stamp '202611020900'
            { New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'rollback' } -Stamp '202611020901' } |
                Should -Throw "Restore this machine of 'vm1' did not finish*"
            $job = (Read-VmfStateDoc -RunPath $rp -VmId $id).putBackJob
            $job.kind | Should -Be 'restore'
            $job.operationId | Should -Be 'op-r'
        }
    }

    It 'a second finish is refused while the first has not ended, and so is a restore; nothing changes' {
        $script:rp = FeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'rollback' } -Stamp '202611020900'
        }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -CorrelationId 'op-2' -FinishedBy 'b@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw "Finish the rollback of 'vm1' has not ended*"
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -RestoredBy 'b@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw "Finish the rollback of 'vm1' has not ended*"
        $global:fe.sites.Count | Should -Be 0
    }

    It 'the resume uses who asked and why from the record - never the call that started it again - and writes no second start line' {
        $script:rp = FeRun
        $global:fe.rp = $script:rp
        $global:fe.killAt = @{ site = 'swapData:after'; n = 1 }
        try { $null = FeAct -Rp $script:rp } catch { $null = $_ }
        FeRevive $script:rp
        $null = Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -CorrelationId 'op-1' -Resume -FinishedBy 'someone@example.com' -Note 'other' -Confirm:$false 3>$null
        $ev = @(FeEvents $script:rp | Where-Object { $_.step -eq 'finish' })
        @($ev | Where-Object outcome -EQ 'start').Count | Should -Be 1
        @($ev | Where-Object outcome -EQ 'start')[0].detail | Should -Match 'by operator@example.com: Azure accepts the swap now'
        @($ev | Where-Object outcome -EQ 'info' | Where-Object detail -Match 'started again') | Should -Not -BeNullOrEmpty
        ($ev | ConvertTo-Json -Depth 4) | Should -Not -Match 'someone@example.com'
        $global:fe.power | Should -Be 'running'
    }

    It 'a resume with no checkpoint, or of another finish, changes nothing' {
        $script:rp = FeRun
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -CorrelationId 'op-9' -Resume -Confirm:$false } | Should -Throw "There is no finish of 'vm1' with the id 'op-9'*"
        $global:fe.sites.Count | Should -Be 0
        (FeRecord $script:rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }

    It 'a resume another job''s hold refuses stays open - it is never marked ended, so the timer asks again' {
        $script:rp = FeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'rollback' } -Stamp '202611020900'
            $null = New-VmfLease -RunPath $rp -VmId $id -WorkerId 'w1-worker-1'
        }
        { FeAct -Rp $script:rp -Resume } | Should -Throw
        $job = (FeRecord $script:rp).putBackJob
        $job.ended | Should -BeNullOrEmpty
        $global:fe.sites.Count | Should -Be 0
    }

    It 'a resume whose earlier job removed the swap record ends its own checkpoint and starts nothing' {
        $script:rp = FeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'restore' } -Stamp '202611020900'
            Set-VmfSwapPending -RunPath $rp -VmId $id -Record $null
        }
        $r = FeAct -Rp $script:rp -Resume
        $r.Started | Should -BeFalse
        (FeRecord $script:rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
        $global:fe.sites.Count | Should -Be 0
    }
}

Describe 'FINISH-END-JOB-1: kill-resume at every step of a finish (rule 4)' {
    It '<Kind>: every kill point resumes to the machine the uninterrupted finish gave - each LUN swapped once, and the machine started once' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }
    ) {
        $r = FeEveryKill -Kind $Kind
        $r.Bad | Should -BeNullOrEmpty
        $r.Checked | Should -BeGreaterOrEqual 10
        @($r.Reference.Points | Where-Object { $_.site -eq 'swapData:between' }).Count | Should -Be 2 -Because 'two batches, so a kill falls between the two updates of each'
        $r.Reference.Starts | Should -Be 1
        $r.Reference.State | Should -Match '"power":"running"'
    }

    It 'killed between the two updates of a swap: the resume attaches the disk from the copy to the empty LUN, then starts the machine' {
        FeMocks
        $r = FeKillAndResume -Kind 'rollback' -Site 'swapData:between' -N 1
        $r.Killed | Should -BeTrue
        $r.LunsAtKill['1'] | Should -Be '' -Because 'Azure detached the disk and the job stopped before the attach'
        $r.Error | Should -BeNullOrEmpty
        $r.Sites | Should -Contain 'attachEmpty:before'
        $r.State | Should -Match 'vm1-data1-d1-asitwas-x'
        $r.Record.state | Should -Be 'FAILED_ROLLED_BACK'
    }
}

Describe 'FINISH-END-JOB-1: a finish over a restore the service gave up on (RESUME-GIVEUP-KEEP-1)' {
    BeforeEach { FeMocks; FeAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }
    BeforeAll {
        function Script:FeGaveUp($rp, [switch]$NoStep) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; noStep = [bool]$NoStep } {
                param($rp, $id, $noStep)
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'restore' -OperationId 'op-0' -StartedBy 'operator@example.com' -Options @{ from = 'pristine'; diskNaming = 'new' } -Stamp '202611010900' `
                    -Before ([pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 1; caching = 'ReadWrite'; deleteOption = 'Delete'; writeAcceleratorEnabled = $false }) })
                if (-not $noStep) { Save-VmfPutBackJobStep -Token $t -Phase 'stopped' }
                $null = Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-0' -Action gaveUp -Why 'The service gave up.'
            }
        }
    }

    It 'Finish the restore, killed and resumed, keeps the restore''s record whole under it, then writes the restore''s record from it and ends its hold (FINISH-NO-RESTORE-RECORD-1)' {
        $script:rp = FeRun -Kind 'restore'
        FeEdit $script:rp { param($d) $d.PSObject.Properties.Remove('restore') }
        FeGaveUp $script:rp
        $global:fe.rp = $script:rp
        $global:fe.killAt = @{ site = 'stop:after'; n = 1 }
        try { $null = FeAct -Rp $script:rp } catch { $null = $_ }
        FeRevive $script:rp
        $job = (FeRecord $script:rp).putBackJob
        $job.kind | Should -Be 'finish'
        $job.PSObject.Properties['held'] | Should -BeNullOrEmpty -Because 'the record it stands over carries the hold'
        $job.prior.operationId | Should -Be 'op-0'
        $job.prior.ended.reason | Should -Be 'gaveUp'
        $job.prior.before.dataDisks[0].caching | Should -Be 'ReadWrite'
        $job.prior.phase | Should -Be 'stopped'
        InModuleScope VmMigrationFactory -Parameters @{ d = (FeRecord $script:rp) } { param($d) Test-VmfPutBackJobHolds -Doc $d } | Should -BeTrue -Because 'the copies are kept while the finish has not ended'
        $null = FeAct -Rp $script:rp -Resume
        $doc = FeRecord $script:rp
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'a restore of the machine finished, so its hold ends'
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.restore.operationId | Should -Be 'op-0'
        $doc.restore.writtenByFinish.by | Should -Be 'operator@example.com'
        $global:fe.power | Should -Be 'running'
    }

    It 'Finish the rollback over it: when the finish ends, the restore''s record is back as it was, with its hold' {
        $script:rp = FeRun -Kind 'rollback'
        FeGaveUp $script:rp
        $null = FeAct -Rp $script:rp
        $after = (FeRecord $script:rp).putBackJob
        $after.kind | Should -Be 'restore'
        $after.operationId | Should -Be 'op-0'
        $after.ended.reason | Should -Be 'gaveUp'
        $after.PSObject.Properties['prior'] | Should -BeNullOrEmpty
        (FeRecord $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'a finish over it that Azure refuses again puts the restore''s record back - never a finish record to resume' {
        $script:rp = FeRun -Kind 'restore'
        FeGaveUp $script:rp
        $global:fe.refuseLun = 2
        { FeAct -Rp $script:rp } | Should -Throw '*stays stopped*'
        $after = (FeRecord $script:rp).putBackJob
        $after.kind | Should -Be 'restore'
        $after.ended.reason | Should -Be 'gaveUp'
        { FeAct -Rp $script:rp -Resume } | Should -Throw '*There is no finish*'
    }

    It 'killed between the two updates of a swap: the empty LUN gets the caching the restore read before it changed the machine, from the record under the finish' {
        $script:rp = FeRun -Kind 'restore'
        FeEdit $script:rp { param($d) foreach ($s in $d.swapPending.swaps) { $s.caching = $null } }
        FeGaveUp $script:rp -NoStep
        $global:fe.rp = $script:rp
        $global:fe.killAt = @{ site = 'swapData:between'; n = 1 }
        try { $null = FeAct -Rp $script:rp } catch { $null = $_ }
        FeRevive $script:rp
        $global:fe.luns['1'] | Should -Be ''
        $null = FeAct -Rp $script:rp -Resume
        @($global:fe.attaches) | Should -Be @('1/ReadWrite') -Because 'the LUN had ReadWrite before the restore changed it, and the capture says None'
    }
    It 'a finish with no record under it leaves no record when it ends' {
        $script:rp = FeRun -Kind 'restore'
        $null = FeAct -Rp $script:rp
        (FeRecord $script:rp).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
}

Describe 'FINISH-END-JOB-1: the service starts a stopped finish again' {
    BeforeAll {
        $script:svStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-fes-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:svStore
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        function Script:SvSeed {
            param([int]$Resumes = 0, [int]$LeaseAge = 2000, [switch]$Ended, [switch]$EndLine, [switch]$Held)
            if (Test-Path $script:svStore) { Remove-Item $script:svStore -Recurse -Force }
            $rp = Join-Path $script:svStore 'fe'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; n = $Resumes; age = $LeaseAge; ended = [bool]$Ended; endLine = [bool]$EndLine; held = [bool]$Held } {
                param($rp, $id, $n, $age, $ended, $endLine, $held)
                Initialize-VmfRun -RunPath $rp -RunId 'fe' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'fe' -VmId $id -Wave 'w1' | Out-Null
                $t = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Note 'Azure accepts the swap now' -Options @{ finishes = 'rollback' } -Stamp '202611020900'
                if ($held) {
                    $t.Job | Add-Member -NotePropertyName prior -Force -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; operationId = 'op-0'; startedUtc = '2026-11-01T09:00:00Z'
                            options = [pscustomobject]@{ from = 'pristine'; diskNaming = 'new' }; stamp = '202611010900'; phase = 'stopped'; resumes = 3
                            ended = [pscustomobject]@{ utc = '2026-11-01T10:00:00Z'; outcome = 'fail'; reason = 'gaveUp'; why = 'gave up' } })
                }
                Save-VmfPutBackJobStep -Token $t -Phase 'dataSwapped'
                Write-VmfEvent -RunPath $rp -Step 'finish' -Outcome start -VmId $id -CorrelationId 'op-1' -Detail 'started'
                if ($endLine) { Write-VmfEvent -RunPath $rp -Step 'finish' -Outcome fail -VmId $id -Detail 'it failed' }
                foreach ($i in 1..$n) { if ($n -gt 0) { $null = Update-VmfPutBackJobRecord -RunPath $rp -VmId $id -OperationId 'op-1' -Action resume } }
                if ($ended) { Close-VmfPutBackJob -Token $t -Why 'Azure refused' }
                if ($age -ge 0) {
                    Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $id) -Depth 6 -Document ([ordered]@{
                            vmId = $id; workerId = 'restore:op-1'; heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o') })
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
                                                [pscustomobject]@{ name = 'VMF_OPERATION'; value = $_ }, [pscustomobject]@{ name = 'VMF_RUN_ID'; value = 'fe' },
                                                [pscustomobject]@{ name = 'VMF_VM_ID'; value = $script:vmId }) }) } } } }) }
            }
        }
        function Script:SvEnv($post, $name) { [string](@($post.containers[0].env) | Where-Object { $_.name -eq $name } | Select-Object -First 1).value }
        function Script:SvRecord { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:svStore 'fe'); id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
        function Script:SvEvents { InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:svStore 'fe') } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
        function Script:SvPass { @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:svStore 'fe') -RunId 'fe') }
    }
    AfterAll { if (Test-Path $script:svStore) { Remove-Item $script:svStore -Recurse -Force }; Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a finish whose hold expired and whose job Azure no longer runs is started again as a finish, for the SAME operation' {
        SvSeed
        SvArm
        $r = SvPass
        $r.Count | Should -Be 1
        $r[0].Action | Should -Be 'resumed'
        $r[0].Kind | Should -Be 'finish'
        $script:svPosts.Count | Should -Be 1
        $p = $script:svPosts[0]
        SvEnv $p 'VMF_OPERATION' | Should -Be 'finish'
        SvEnv $p 'VMF_RESUME_ID' | Should -Be 'op-1'
        SvEnv $p 'VMF_VM_ID' | Should -Be $script:vmId
        SvEnv $p 'VMF_NOTE' | Should -Match "resumed: the job of Finish the rollback started by operator@example.com stopped at the step 'dataSwapped'"
        (SvRecord).putBackJob.resumes | Should -Be 1
        $line = @(SvEvents | Where-Object { $_.step -eq 'resume' -and $_.outcome -eq 'warn' })[-1]
        $line.vmId | Should -Be $script:vmId
        $line.detail | Should -Match "^Finish the rollback of 'vm1' stopped part way when its job stopped\. The engine started it again \(execution exec-resume\)\. It swaps only the data disks that are left, then starts the machine\.$"
    }
    It 'a live hold, or a finish Azure lists as running, means the job runs: nothing is started' {
        SvSeed -LeaseAge 10
        SvArm
        (SvPass).Count | Should -Be 0
        $script:svPosts.Count | Should -Be 0
        SvSeed
        SvArm -Running @('finish')
        (SvPass).Count | Should -Be 0
        $script:svPosts.Count | Should -Be 0
        (SvRecord).putBackJob.resumes | Should -Be 0
    }
    It 'at the limit the service stops trying: the row ends on the engine''s finish fail line, and the record goes - the swap record still offers Finish' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfPutBackResumeLimit }
        SvSeed -Resumes $limit
        SvArm
        $r = SvPass
        $r[0].Action | Should -Be 'gaveUp'
        $script:svPosts.Count | Should -Be 0
        $fail = @(SvEvents | Where-Object { $_.step -eq 'engine:finish' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].correlationId | Should -Be 'op-1'
        $fail[0].vmId | Should -Be $script:vmId
        $fail[0].detail | Should -Match "started it again $limit times, and it did not finish"
        $fail[0].detail | Should -Match 'The machine stays stopped, and its record names each data disk that is left\. Look at the machine and its disks, then use Finish the rollback again\.$'
        (SvRecord).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'a finish holds no safety copy; the swap record keeps the disks it needs'
        $null = SvPass
        @(SvEvents | Where-Object { $_.step -eq 'engine:finish' }).Count | Should -Be 1
    }
    It 'at the limit, a finish over the record of a restore the service gave up on puts that record back, with its hold' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfPutBackResumeLimit }
        SvSeed -Resumes $limit -Held
        SvArm
        $r = SvPass
        $r[0].Action | Should -Be 'gaveUp'
        $job = (SvRecord).putBackJob
        $job.kind | Should -Be 'restore'
        $job.operationId | Should -Be 'op-0'
        $job.ended.reason | Should -Be 'gaveUp'
        @(SvEvents | Where-Object { $_.step -eq 'engine:finish' })[0].detail | Should -Match 'keeps the safety copies of the machine'
        $null = SvPass
        @(SvEvents | Where-Object { $_.step -match '^engine:' }).Count | Should -Be 1 -Because 'the restore''s record is one the service gave up on: nothing more to say'
    }
    It 'a finish that ended with an answer, whose last lines were both lost: the service ends the row on the finish fail line, then removes the record' {
        SvSeed -Ended
        SvArm
        $r = SvPass
        $r[0].Action | Should -Be 'ended'
        $script:svPosts.Count | Should -Be 0
        $fail = @(SvEvents | Where-Object { $_.step -eq 'engine:finish' -and $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].detail | Should -Match "^Finish the rollback of 'vm1' ended, and its last line was not written"
        (SvRecord).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
    It 'a finish that ended and wrote its own last line: the record goes, and no second end line is written' {
        SvSeed -Ended -EndLine
        SvArm
        $null = SvPass
        @(SvEvents | Where-Object { $_.step -eq 'engine:finish' }).Count | Should -Be 0
        (SvRecord).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }
}

Describe 'FINISH-END-JOB-1: the service refuses a second finish, and only its timer resumes one' {
    BeforeAll {
        $script:sgStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-feg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:sgStore
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $rp = Join-Path $script:sgStore 'fe'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'fe' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'fe' -VmId $id -Wave 'w1' | Out-Null
            $null = New-VmfPutBackJob -RunPath $rp -VmId $id -Kind 'finish' -OperationId 'op-1' -StartedBy 'operator@example.com' -Options @{ finishes = 'restore' } -Stamp '202611020900'
        }
        $script:sgPrincipal = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    AfterAll { if (Test-Path $script:sgStore) { Remove-Item $script:sgStore -Recurse -Force }; Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:sgPosts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'POST') { $script:sgPosts.Add(($Payload | ConvertFrom-Json)); return [pscustomobject]@{ StatusCode = 202; Content = '{"name":"e"}' } }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{ name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfArmList { [pscustomobject]@{ Ok = $true; StatusCode = 200; Items = @() } }
    }
    # REBUILD-REMOVE-RECOVER-1: no engine operation rebuild.
    It 'a restore and a finish of the machine are refused with the sentence, before a job starts' {
        foreach ($op in 'restore', 'finish') {
            { Invoke-VmfFacadeStartEngine -Principal $script:sgPrincipal -Operation $op -RunId 'fe' -VmId $script:vmId -Note 'again' } | Should -Throw "400: Finish the restore of 'vm1' has not ended*"
        }
        $script:sgPosts.Count | Should -Be 0
    }
    It 'the timer''s resume of that same finish passes, and carries its operation id' {
        InModuleScope FacadeCore { $script:VmfResumeDispatch = 'op-1' }
        try { $null = Invoke-VmfFacadeStartEngine -Principal $script:sgPrincipal -Operation 'finish' -RunId 'fe' -VmId $script:vmId -Note 'resumed' }
        finally { InModuleScope FacadeCore { $script:VmfResumeDispatch = $null } }
        $script:sgPosts.Count | Should -Be 1
        [string](@($script:sgPosts[0].containers[0].env) | Where-Object { $_.name -eq 'VMF_RESUME_ID' }).value | Should -Be 'op-1'
    }
}

Describe 'FINISH-END-JOB-1: the engine and the contract' {
    It 'the engine starts the finish it resumes with that job''s id - the start line, the lease and the fail line all carry it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $code | Should -Match "\`$resumeId = if \(\`$env:VMF_OPERATION -in @\('restore', 'finish'\) -and \`$env:VMF_RESUME_ID\)"
        $code | Should -Match 'if \(\$resumeId\) \{ \$finishParams\.Resume = \$true \}'
        $code.IndexOf('$finishParams.Resume = $true') | Should -BeLessThan $code.IndexOf('Complete-VmfDataDiskSwap @finishParams')
    }
    It 'the timer reads a finish as a job it resumes' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match "\[string\]\`$job\.kind -in @\('restore', 'finish'\)"
        $core | Should -Match "\`$resumeId = if \(\`$Operation -in @\('restore', 'finish'\) -and \`$script:VmfResumeDispatch\)"
    }
    It 'vm-state v33 declares a finish checkpoint; a record with it validates, and another kind or another finish is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        @($schema.properties.putBackJob.properties.kind.enum) | Should -Contain 'finish'
        $base = { param($kind, $fin) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"putBackJob":{"kind":"' + $kind + '","operationId":"op-1","startedUtc":"2026-11-02T09:00:00Z","options":{"finishes":"' + $fin + '"},"stamp":"202611020900","phase":"dataSwapped","resumes":0}}' }
        Test-Json -Json (& $base 'finish' 'rollback') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base 'finish' 'restore') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base 'finish' 'rebuild') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json (& $base 'discard' 'rollback') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 51
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v32 -> v33 \(2026-11-02, FINISH-END-JOB-1\)'
    }
    It 'every record a finish writes, with its checkpoint, validates against the checkpoint''s part of the schema' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        FeMocks; FeAzure
        $rp = FeRun -Kind 'restore'
        $global:fe.rp = $rp
        $script:docsSeen = [System.Collections.Generic.List[string]]::new()
        try {
            Mock -ModuleName VmMigrationFactory Write-VmfStateDoc {
                $json = $Document | ConvertTo-Json -Depth 24
                if ($json -match '"putBackJob"') { $script:docsSeen.Add($json) }
                & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $d.vmId) + '.json') -Document $d } $RunPath $Document
            }
            $null = FeAct -Rp $rp
            $script:docsSeen.Count | Should -BeGreaterOrEqual 3
            $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
            $part = [ordered]@{ '$schema' = 'https://json-schema.org/draft/2020-12/schema' }
            foreach ($p in $schema.properties.putBackJob.PSObject.Properties) { $part[$p.Name] = $p.Value }
            $partJson = $part | ConvertTo-Json -Depth 30
            foreach ($j in $script:docsSeen) { Test-Json -Json (($j | ConvertFrom-Json).putBackJob | ConvertTo-Json -Depth 24) -Schema $partJson | Should -BeTrue }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
