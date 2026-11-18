#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-ONE-AT-A-TIME-1: one restore of a machine at a time.
#
# A second click, or a second person, started a second engine job for the same
# machine. Each stopped the machine, made disks from the copy and swapped them
# in - and one could start the machine while the other swapped its disks. Two
# layers now refuse that, and both are tested here:
#
#   the service  refuses the start while Azure lists a restore of
#                the same machine, or while a live hold (lease) is on it;
#   the engine   takes the machine's lease - the one a wave worker takes - in
#                Restore-VmfVm and Restore-VmfVmShell before it reads or changes
#                anything, so two jobs that both passed the service cannot both
#                change the machine.
#
# The lease ends on every exit, ends by itself when a job dies (its heartbeat
# stops), and a resume of the SAME restore (the same operation id) takes it over.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:SUB = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines'
    $script:VMID = "$script:SUB/app01"
    $script:DISKS = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks'
    $global:OneVm = $script:VMID

    function Script:NewOneRun {
        param([switch]$Stranded)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-one-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $script:VMID; disks = $script:DISKS; stranded = [bool]$Stranded } {
            Initialize-VmfRun -RunPath $rp -RunId 'one-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'one-test' -VmId $vmId -Wave 'lab-1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                snapshotId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/app01-snap'
                cloneVmId = $null }) -Force
            if ($stranded) {
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{
                        name = 'app01'; osType = 'Windows'; location = 'centralus'
                        size = 'Standard_D2ds_v4'; controller = 'SCSI'
                        osDisk = [pscustomobject]@{ name = 'app01-osdisk'; managedDiskId = "$disks/app01-osdisk"; deleteOption = 'Delete'; skuName = 'Premium_LRS' }
                        dataDisks = @(); nics = @()
                    } }) -Force
                $doc.state = 'FAILED_NEEDS_ATTENTION'
            }
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            else { $doc.state = 'MIGRATED' }
            $null = Add-VmfTestMachineCapture $doc 'app01' "$disks/app01-osdisk"
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $global:OneRun = $rp
        $rp
    }

    # Every lease helper asks the module itself, so a mock body - which runs
    # outside the module - can call it too. $global:OneRun names the run.
    function Global:OneSetLease([string]$Holder, [int]$AgeSeconds = 0) {
        & (Get-Module VmMigrationFactory) { param($rp, $v, $h, $age)
            $when = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $v) -Document ([ordered]@{ vmId = $v; workerId = $h; acquiredUtc = $when; heartbeatUtc = $when })
        } $global:OneRun $global:OneVm $Holder $AgeSeconds
    }
    function Global:OneLeaseHolder {
        $l = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfLeaseInfo -RunPath $rp -VmId $v } $global:OneRun $global:OneVm
        if ($l) { [string]$l.workerId } else { '' }
    }
    function Global:OneRemoveLease {
        & (Get-Module VmMigrationFactory) { param($rp, $v) Remove-VmfLease -RunPath $rp -VmId $v -Force } $global:OneRun $global:OneVm
    }
    # Seconds since the heartbeat, read from the stored text: ConvertFrom-Json
    # would turn the time into a date value in the local zone.
    function Global:OneHeartbeatAge {
        $raw = & (Get-Module VmMigrationFactory) { param($rp, $v) Read-VmfStoreText -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $v) } $global:OneRun $global:OneVm
        if ([string]$raw -notmatch '"heartbeatUtc":\s*"([^"]+)"') { throw 'no heartbeat in the lease' }
        $when = [datetime]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        ((Get-Date).ToUniversalTime() - $when).TotalSeconds
    }
    # The next Azure call renews at once, not 25 seconds later.
    function Global:OneBeatDue { & (Get-Module VmMigrationFactory) { if ($script:VmfMachineLeaseToken) { $script:VmfMachineLeaseToken.Last = [datetime]::MinValue } } }

    function Script:MockRestoreOps {
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
    }

    function Script:MockRebuildOps {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $false }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2ds_v4' }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { @() }
        Mock -ModuleName VmMigrationFactory Assert-VmfSizeTakesKeptDisks { }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { $null }
    }

    function Script:Enter([string]$Holder) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; vmId = $global:OneVm; h = $Holder } {
            Enter-VmfMachineLease -RunPath $rp -VmId $vmId -Holder $h
        }
    }

    function Script:Events {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { @(Read-VmfEvents -RunPath $rp) }
    }

    function Script:CleanUp {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if ($global:OneRun -and (Test-Path $global:OneRun)) { Remove-Item $global:OneRun -Recurse -Force }
    }
}

AfterAll {
    Remove-Variable OneRun, OneVm -Scope Global -ErrorAction SilentlyContinue
    Remove-Item 'function:\OneSetLease', 'function:\OneLeaseHolder', 'function:\OneRemoveLease', 'function:\OneHeartbeatAge', 'function:\OneBeatDue' -ErrorAction SilentlyContinue
}

Describe 'RESTORE-ONE-AT-A-TIME-1: the machine lease a restore takes' {
    BeforeEach { Script:NewOneRun | Out-Null }
    AfterEach { Script:CleanUp }

    It 'a free machine is taken, under the holder the job names' {
        (Script:Enter 'restore:op-1').Holder | Should -Be 'restore:op-1'
        OneLeaseHolder | Should -Be 'restore:op-1'
    }

    It 'refuses a second holder while a <What> holds the machine, and names it' -ForEach @(
        @{ What = 'restore'; Holder = 'restore:op-1'; Words = "A restore of 'app01' runs now*" }
        @{ What = 'wave worker'; Holder = 'one-test-w2'; Words = "A wave migrates 'app01' now*" }) {
        OneSetLease $Holder
        { Script:Enter 'restore:op-2' } | Should -Throw $Words
        OneLeaseHolder | Should -Be $Holder -Because 'a refusal never touches the hold of the other job'
    }

    It 'kill-resume: a resume of the SAME restore (the same operation id) takes its own hold over' {
        OneSetLease 'restore:op-1' -AgeSeconds 300
        (Script:Enter 'restore:op-1').Holder | Should -Be 'restore:op-1'
        OneHeartbeatAge | Should -BeLessThan 30 -Because 'the takeover renews the heartbeat'
    }

    It 'the same holder is matched exactly: another letter case is another job' {
        OneSetLease 'restore:OP-1'
        { Script:Enter 'restore:op-1' } | Should -Throw '*runs now*'
    }

    It 'kill-resume: a hold whose job died ends by itself - another job takes it once the heartbeat is older than the limit' {
        OneSetLease 'restore:dead' -AgeSeconds 901
        (Script:Enter 'restore:op-2').Holder | Should -Be 'restore:op-2'
        OneLeaseHolder | Should -Be 'restore:op-2'
    }

    It 'and not before: a hold within the limit still refuses' {
        OneSetLease 'restore:alive' -AgeSeconds 880
        { Script:Enter 'restore:op-2' } | Should -Throw '*runs now*'
    }

    It 'the limit is the one the wave watchdog uses, so the two never disagree about who is alive' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds }
        $limit | Should -Be 900
        foreach ($file in 'Start-VmfWave.ps1', 'Stop-VmfRun.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $file)
            $code | Should -Match ('\[int\]\$LeaseTimeoutSeconds = ' + $limit)
        }
    }

    It 'review: the page waits the same hold before it offers the buttons again (one value, two languages)' {
        $limit = InModuleScope VmMigrationFactory { $script:VmfMachineLeaseTimeoutSeconds }
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        $found = [regex]::Match($page, 'const PUTBACK_HOLD_MS = (\d+);')
        $found.Success | Should -BeTrue
        [int]$found.Groups[1].Value | Should -Be ($limit * 1000)
    }
    It 'an expired hold is taken by ONE job only: the second sees the fresh hold of the first and refuses' {
        OneSetLease 'restore:dead' -AgeSeconds 2000
        Script:Enter 'restore:op-2' | Out-Null
        { Script:Enter 'restore:op-3' } | Should -Throw "A restore of 'app01' runs now*"
        OneLeaseHolder | Should -Be 'restore:op-2'
    }

    It 'the expired hold is removed only as it was judged: one renewed in between is kept' {
        # A renewal lands between the judgement and the removal. The removal is
        # conditional on the text judged (Remove-VmfStoreItemIfVersion), so the
        # live hold stays and the job is refused.
        OneSetLease 'restore:slow' -AgeSeconds 2000
        $global:OneRenewed = $false
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion {
            if (-not $global:OneRenewed) { $global:OneRenewed = $true; OneSetLease 'restore:slow' }
            # The real one, by name: a mock's $PSBoundParameters is empty.
            & (Get-Module VmMigrationFactory) { param($a, $b, $c)
                & (Get-Command Remove-VmfStoreItemIfVersion -CommandType Function) -RunPath $a -RelPath $b -ExpectedVersion $c
            } $RunPath $RelPath $ExpectedVersion
        }
        { Script:Enter 'restore:op-2' } | Should -Throw "A restore of 'app01' runs now*"
        $global:OneRenewed | Should -BeTrue -Because 'the test must reach the removal'
        OneLeaseHolder | Should -Be 'restore:slow'
        Remove-Variable OneRenewed -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the release removes only its own hold' {
        OneSetLease 'one-test-w1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; vmId = $global:OneVm } {
            Exit-VmfMachineLease -Token ([pscustomobject]@{ RunPath = $rp; VmId = $vmId; Holder = 'restore:op-9'; PreviousHook = $null }) 3>$null
        }
        OneLeaseHolder | Should -Be 'one-test-w1'
    }

    It 'the release removes its own hold and puts the earlier heartbeat hook back' {
        InModuleScope VmMigrationFactory { $script:VmfOpHeartbeat = { 'earlier' } }
        $token = Script:Enter 'restore:op-1'
        InModuleScope VmMigrationFactory -Parameters @{ t = $token } { Exit-VmfMachineLease -Token $t }
        OneLeaseHolder | Should -Be ''
        InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat } | Should -Be 'earlier'
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken } | Should -BeNullOrEmpty
    }

    It 'the heartbeat renews the hold while it is this job''s' {
        Script:Enter 'restore:op-1' | Out-Null
        OneSetLease 'restore:op-1' -AgeSeconds 600
        OneBeatDue
        InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat }
        OneHeartbeatAge | Should -BeLessThan 30
    }

    It 'the heartbeat waits between renewals, so small calls do not each write the store' {
        Script:Enter 'restore:op-1' | Out-Null
        OneSetLease 'restore:op-1' -AgeSeconds 600
        InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat }
        OneHeartbeatAge | Should -BeGreaterThan 500
    }

    It 'the heartbeat never throws, and never writes over the hold, when another job took it' {
        Script:Enter 'restore:op-1' | Out-Null
        OneSetLease 'restore:other'
        OneBeatDue
        { InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat 3>$null } } | Should -Not -Throw
        OneLeaseHolder | Should -Be 'restore:other'
    }

    It 'the heartbeat never throws when the store cannot be read' {
        Script:Enter 'restore:op-1' | Out-Null
        OneBeatDue
        Mock -ModuleName VmMigrationFactory Get-VmfLeaseInfo { throw 'the store answered 503' }
        { InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat 3>$null } } | Should -Not -Throw
    }

    It 'a wave container does not count a restore as another container of its wave' {
        OneSetLease 'restore:op-1'
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('one-test-c1-1') }
        $r.Working | Should -BeFalse -Because 'otherwise every container leaves quietly and nobody ends the wave'
        OneSetLease 'one-test-c2-1'
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Test-VmfOtherContainersWorking -RunPath $rp -MyWorkerIds @('one-test-c1-1') }
        $r.Working | Should -BeTrue -Because 'a worker of another container still counts'
    }

    It 'Stop-VmfRun names a restore among what holds a machine' {
        OneSetLease 'restore:op-1'
        { Stop-VmfRun -RunPath $global:OneRun -Reason 'x' -StoppedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '*a restore*'
        OneLeaseHolder | Should -Be 'restore:op-1'
    }

    It 'review: the wave watchdog does not say a restore it reaps will be resumed' {
        foreach ($h in 'restore:op-1') {
            $w = InModuleScope VmMigrationFactory -Parameters @{ h = $h } { Get-VmfReapedLeaseWords -Lease ([pscustomobject]@{ workerId = $h; vmId = 'x' }) }
            $w | Should -Not -Match 'resumed'
            $w | Should -Match ('the wave does not resume it')
            # RESTORE-END-JOB-1: the service's timer resumes it now, and the
            # words say who does - not "start it again" by hand.
            $w | Should -Match 'The service starts the restore again by itself'
        }
        InModuleScope VmMigrationFactory { Get-VmfReapedLeaseWords -Lease ([pscustomobject]@{ workerId = 'one-test-w1'; vmId = 'x' }) } | Should -Match 'will be resumed'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match "-Step 'watchdog'[^\n]*\n[^\n]*-Detail \(Get-VmfReapedLeaseWords -Lease \`$expired\)"
    }

    It 'review: the run summary does not read a restore alone as a running wave' {
        OneSetLease 'restore:op-1'
        Mock -ModuleName VmMigrationFactory Get-VmfRunSummary { $global:OneLeased = $Leased; [pscustomobject]@{} }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } {
            Get-VmfRunSummaryFromStore -RunPath $rp -PlanPath (Get-VmfStoreItemHandle -RunPath $rp -RelPath 'plan.json') -Reason 'test' | Out-Null
        }
        $global:OneLeased | Should -BeFalse
        OneSetLease 'one-test-w1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } {
            Get-VmfRunSummaryFromStore -RunPath $rp -PlanPath (Get-VmfStoreItemHandle -RunPath $rp -RelPath 'plan.json') -Reason 'test' | Out-Null
        }
        $global:OneLeased | Should -BeTrue -Because 'a wave worker still means a wave runs'
        Remove-Variable OneLeased -Scope Global -ErrorAction SilentlyContinue
    }

    It 'review: the wave status does not list a restore as a running worker' {
        # OVERVIEW-RUNNING-STALE-1: a MIGRATED machine is never moving, whoever
        # holds it, so the machine is put in a working state for this test.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; v = $global:OneVm } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $v; $doc.state = 'CONVERTING'; Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        OneSetLease 'restore:op-1'
        Mock -ModuleName VmMigrationFactory Write-VmfRunStatusDocument { $null }
        $plan = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Read-VmfPlanDocument -RunPath $rp -Depth 24 }
        $s = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; wavePlan = $plan } { Write-VmfRunStatus -RunPath $rp -Plan $wavePlan -Wave 'lab-1' -RunId 'one-test' }
        @($s.running).Count | Should -Be 0
        OneSetLease 'one-test-w1'
        $s = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; wavePlan = $plan } { Write-VmfRunStatus -RunPath $rp -Plan $wavePlan -Wave 'lab-1' -RunId 'one-test' }
        @($s.running).Count | Should -Be 1
    }

    It 'review: a refusal that names what holds a machine says a restore, not a worker' {
        OneSetLease 'restore:op-1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Get-VmfWaveRunningDetail -RunPath $rp -Wave 'lab-1' } | Should -Match 'held by a restore'
        OneSetLease 'one-test-w1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Get-VmfWaveRunningDetail -RunPath $rp -Wave 'lab-1' } | Should -Match 'held by a worker'
    }
    It 'the heartbeat takes the hold back when somebody removed it' {
        Script:Enter 'restore:op-1' | Out-Null
        OneRemoveLease
        OneBeatDue
        InModuleScope VmMigrationFactory { & $script:VmfOpHeartbeat }
        OneLeaseHolder | Should -Be 'restore:op-1'
    }

    It 'a wave worker does not take a machine a restore holds' {
        OneSetLease 'restore:op-1'
        $plan = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun } { Read-VmfPlanDocument -RunPath $rp -Depth 24 }
        $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; wavePlan = $plan } {
            Get-VmfNextWaveVm -RunPath $rp -Plan $wavePlan -Wave 'lab-1' -WorkerId 'one-test-w1' 3>$null
        }
        $claim | Should -BeNullOrEmpty
        OneLeaseHolder | Should -Be 'restore:op-1'
    }
}

Describe 'RESTORE-ONE-AT-A-TIME-1: Restore-VmfVm holds the machine for the whole restore' {
    BeforeEach { Script:NewOneRun | Out-Null; Script:MockRestoreOps }
    AfterEach { Script:CleanUp }

    It 'refuses before any Azure call and before its start line while a <What> holds the machine' -ForEach @(
        @{ What = 'restore'; Holder = 'restore:op-1'; Words = "*A restore of 'app01' runs now*" }
        @{ What = 'wave worker'; Holder = 'one-test-w1'; Words = "*A wave migrates 'app01' now*" }) {
        OneSetLease $Holder
        { Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-2' -Confirm:$false } | Should -Throw $Words
        Should -Invoke -ModuleName VmMigrationFactory Use-VmfSubscriptionContext -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfOsDiskInfo -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
        # No start line: the page would otherwise open a second restore and end
        # it on this refusal, while the first still works on a stopped machine.
        @(Script:Events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'start' }).Count | Should -Be 0
        OneLeaseHolder | Should -Be $Holder
        Should -Invoke -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext -Times 1 -Exactly -Because 'a refusal puts the context back too'
    }

    It 'holds the machine under restore: and the operation id while it stops it, and releases it at the end' {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:OneHeldAtStop = OneLeaseHolder }
        Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-7' -Confirm:$false | Out-Null
        $global:OneHeldAtStop | Should -Be 'restore:op-7'
        OneLeaseHolder | Should -Be '' -Because 'the hold ends with the restore'
        InModuleScope VmMigrationFactory { $script:VmfOpHeartbeat } | Should -BeNullOrEmpty -Because 'the heartbeat hook is put back'
        Remove-Variable OneHeldAtStop -Scope Global -ErrorAction SilentlyContinue
    }

    It 'with -WhatIf it changes nothing and leaves no hold' {
        Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-7' -WhatIf | Out-Null
        OneLeaseHolder | Should -Be ''
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
    }

    It 'releases the hold when the restore fails after the stop' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'Azure refused the swap' }
        { Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-8' -Confirm:$false } | Should -Throw
        OneLeaseHolder | Should -Be ''
    }

    It 'releases the hold when the restore stops before it changes anything' {
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { throw 'Azure refused the disk' }
        { Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-8' -Confirm:$false } | Should -Throw '*before it changed the machine*'
        OneLeaseHolder | Should -Be ''
    }

    It 'a restore with no operation id still holds the machine, under an id of its own' {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:OneHeldAtStop = OneLeaseHolder }
        Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -Confirm:$false | Out-Null
        $global:OneHeldAtStop | Should -Match '^restore:.+'
        Remove-Variable OneHeldAtStop -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stops before the stop when another job took the machine while the restore made its disks' {
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            OneSetLease 'restore:other'
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        { Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-1' -Confirm:$false 3>$null } |
            Should -Throw "*before it changed the machine*A restore of 'app01' runs now*"
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        OneLeaseHolder | Should -Be 'restore:other' -Because 'the release never removes the hold of another job'
    }

    It 'after the stop, a lost hold never stops the restore: the machine is not left stopped' {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { OneSetLease 'one-test-w1'; OneBeatDue }
        $r = Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-1' -Confirm:$false 3>$null
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1 -Exactly
        OneLeaseHolder | Should -Be 'one-test-w1'
    }

    It 'renews the hold during the restore (every Azure call passes the heartbeat)' {
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            # An old heartbeat, as after a long Azure call; the next call renews.
            OneSetLease 'restore:op-1' -AgeSeconds 800
            OneBeatDue
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:OneAgeAtStop = OneHeartbeatAge }
        Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-1' -Confirm:$false | Out-Null
        $global:OneAgeAtStop | Should -BeLessThan 60
        Remove-Variable OneAgeAtStop -Scope Global -ErrorAction SilentlyContinue
    }

    It 'kill-resume: a restore whose job died blocks a new one for the limit, then frees the machine by itself' {
        OneSetLease 'restore:dead' -AgeSeconds 300
        { Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-2' -Confirm:$false } | Should -Throw '*runs now*'
        OneSetLease 'restore:dead' -AgeSeconds 1000
        $r = Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-2' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        OneLeaseHolder | Should -Be ''
    }

    It 'kill-resume: the SAME restore started again (its operation id) is not refused by its own hold' {
        OneSetLease 'restore:op-5' -AgeSeconds 120
        $r = Restore-VmfVm -RunPath $global:OneRun -VmId $global:OneVm -CorrelationId 'op-5' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        OneLeaseHolder | Should -Be ''
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).

Describe 'RESTORE-ONE-AT-A-TIME-1: the engine operation names each job' {
    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).
}

Describe 'RESTORE-ONE-AT-A-TIME-1: the service refuses before a job starts' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-one-store-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        $global:OneRun = Join-Path $script:store 'run-x'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:OneRun; vmId = $global:OneVm } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vmId -Wave 'lab-1' | Out-Null
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'reached the engine start' }
    }
    AfterEach {
        if ($script:store -and (Test-Path $script:store)) { Remove-Item $script:store -Recurse -Force }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
    }

    # REBUILD-REMOVE-RECOVER-1: no engine operation rebuild; a restore and a finish are the jobs of one machine.
    It 'refuses a <Operation> while Azure lists a restore or a finish of the same machine' -ForEach @(
        @{ Operation = 'restore' }, @{ Operation = 'finish' }) {
        # $PesterBoundParameters: an unbound $VmId in a mock body reads the
        # caller's variable of that name, so only what was passed counts.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning {
            (@($Operation) -contains 'restore') -and (@($Operation) -contains 'finish') -and $RunId -eq 'run-x' -and
                $PesterBoundParameters.ContainsKey('VmId') -and $PesterBoundParameters['VmId'] -eq $global:OneVm
        }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' -VmId $global:OneVm } |
            Should -Throw '400: The engine works on this machine now*'
    }

    # MANUAL-REVIEW-1: the job Azure lists may be Delete these disks or Delete
    # these disks now, so the refusal names no restore - it said "A restore of
    # this machine runs now" for each of the four jobs.
    It 'refuses a <Operation> while Azure lists a job of the same machine, and calls no job a restore' -ForEach @(
        @{ Operation = 'deleteearlier' }, @{ Operation = 'deletemade' }) {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning {
            (@($Operation) -contains 'deleteearlier') -and (@($Operation) -contains 'deletemade') -and $RunId -eq 'run-x' -and
                $PesterBoundParameters.ContainsKey('VmId') -and $PesterBoundParameters['VmId'] -eq $global:OneVm
        }
        $err = $null
        try { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' -VmId $global:OneVm } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '400: The engine works on this machine now. Wait until that job ends, then try again.'
        $err | Should -Not -Match '(?i)restore'
    }

    It 'lets a <Operation> through while only another machine is restored' -ForEach @(
        @{ Operation = 'restore' }, @{ Operation = 'finish' }) {
        # Azure lists a restore in the run, of another machine: a question that
        # names no machine is answered yes, and that must not refuse this one.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { -not $PesterBoundParameters.ContainsKey('VmId') -or $PesterBoundParameters['VmId'] -ne $global:OneVm }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' -VmId $global:OneVm } |
            Should -Throw 'reached the engine start'
    }

    It 'refuses a <Operation> while a live wave worker holds the machine, in the words of the engine' -ForEach @(
        @{ Operation = 'restore' }, @{ Operation = 'finish' }) {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        OneSetLease 'run-x-w1'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' -VmId $global:OneVm } |
            Should -Throw "400: A wave migrates 'app01' now*"
    }

    It 'lets it through when the hold is older than the limit (its job died)' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        OneSetLease 'restore:dead' -AgeSeconds 1000
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:OneVm } |
            Should -Throw 'reached the engine start'
    }

    It 'finds the hold whatever the letter case the page sent' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        OneSetLease 'restore:op-1'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:OneVm.ToUpperInvariant() } |
            Should -Throw "400: A restore of 'app01' runs now*"
    }

    It 'a wave start does not ask about one machine (it is not one machine)' {
        # ENGINE-START-PART-1: it asks whether its own wave runs, and names no machine.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { if ($PesterBoundParameters.ContainsKey('VmId') -or @($Operation) -contains 'restore') { throw 'asked' }; $false }
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveContainers { throw 'reached the engine start' }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'run-x' -Note 'n' -Wave 'lab-1' } |
            Should -Throw 'reached the engine start'
    }
}

Describe 'RESTORE-ONE-AT-A-TIME-1: is a restore of THIS machine running?' {
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        function Global:OneExec([string]$Status, [string]$Op, [string]$Vm, [string]$Run = 'run-x') {
            $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
            if ($Vm) { $envs += @{ name = 'VMF_VM_ID'; value = $Vm } }
            @{ properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
        }
        $global:OnePage = @{}
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = ($global:OnePage | ConvertTo-Json -Depth 12) }
        }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        Remove-Variable -Name OnePage -Scope Global -ErrorAction SilentlyContinue
        Remove-Item 'function:\OneExec' -ErrorAction SilentlyContinue
    }

    It 'a running restore of the machine counts, whatever the letter case' {
        $global:OnePage = @{ value = @((OneExec 'Running' 'restore' $global:OneVm.ToUpperInvariant())) }
        InModuleScope FacadeCore -Parameters @{ v = $global:OneVm } { Test-VmfFacadeEngineRunning -Operation @('restore', 'rebuild') -RunId 'run-x' -VmId $v } | Should -BeTrue
    }

    It 'a restore of another machine, or a finished one, does not' {
        $global:OnePage = @{ value = @((OneExec 'Running' 'restore' "$script:SUB/other"), (OneExec 'Succeeded' 'rebuild' $global:OneVm)) }
        InModuleScope FacadeCore -Parameters @{ v = $global:OneVm } { Test-VmfFacadeEngineRunning -Operation @('restore', 'rebuild') -RunId 'run-x' -VmId $v } | Should -BeFalse
    }

    It 'with no machine named it still answers for the whole run, as before' {
        $global:OnePage = @{ value = @((OneExec 'Running' 'restore' "$script:SUB/other")) }
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation @('restore', 'rebuild') -RunId 'run-x' } | Should -BeTrue
    }
}
