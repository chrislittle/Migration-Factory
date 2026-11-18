#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STALE-WAVE-HOLD-1. A wave worker removes its hold (leases/<machine>.lease)
# in the finally of worker.ps1, AFTER the state machine wrote a final state.
# A container the platform stops between those two writes leaves the hold on a
# machine whose move ended. A restore never takes over a wave worker's hold
# (RESTORE-MID-MOVE-1, 2026-10-19), and nothing else removed it: the wave
# watchdog runs only while the wave runs, and the service starts a wave again
# only for a machine that has not ended. So Restore this machine was refused
# for a migrated machine until somebody stopped the migration.
#
# Decided 2026-10-30: the service's timer removes an EXPIRED wave
# worker's hold on a machine whose state is FINAL, when no execution of its
# wave runs - with Remove-VmfExpiredLease, which removes only the text it
# judged. A hold on a machine at a working state is never removed (the wave
# resumes that machine), and a restore still never takes over a wave worker's
# hold. In the same pass the claim of a MIGRATED or SKIPPED machine is given
# back (Remove-VmfSettledVmClaim, CLAIM-KEPT-AFTER-WAVE-1's one rule); a failed
# machine keeps its claim (this run still recovers it).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    # Az is not installed in CI, so the service tests mock stand-ins, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'stalewavehold'
    $script:workerPath = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'))

    $global:SwhVmBase = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-swh/providers/Microsoft.Compute/virtualMachines/'
    $global:SwhA = "${global:SwhVmBase}vm-a"
    $global:SwhB = "${global:SwhVmBase}vm-b"
    $global:SwhC = "${global:SwhVmBase}vm-c"
    $global:SwhGone = "${global:SwhVmBase}vm-gone"

    # A store in memory that answers as blob storage does: an ETag per text,
    # If-None-Match: * for a create, If-Match on a write and on a delete, and
    # an append blob that comp=appendblock adds to.
    function Global:Install-SwhBlobService {
        $global:SwhBlobs = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:SwhTags = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:SwhSerial = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:SwhBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    $there = $global:SwhBlobs.ContainsKey($path)
                    if ($query -match 'comp=appendblock') {
                        if (-not $there) { return @{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                        $global:SwhBlobs[$path] = $global:SwhBlobs[$path] + [string]$Body
                        $global:SwhTags[$path] = '"t' + (++$global:SwhSerial) + '"'
                        return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:SwhTags[$path] } }
                    }
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:SwhTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:SwhBlobs[$path] = [string]$Body
                    $global:SwhTags[$path] = '"t' + (++$global:SwhSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:SwhTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:SwhBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:SwhTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:SwhBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:SwhBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:SwhBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:SwhBlobs[$path]; Headers = @{ ETag = $global:SwhTags[$path] } }
                }
            }
        }
    }

    function Global:SwhModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store per test: a run 'swh' with wave w1 (vm-a, vm-b) and w2 (vm-c).
    function Global:SwhNewStore([string]$Backend) {
        $global:SwhBackend = $Backend
        if ($Backend -eq 'file') {
            $global:SwhRoot = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            [System.IO.Directory]::CreateDirectory($global:SwhRoot) | Out-Null
            $global:SwhRun = Join-Path $global:SwhRoot 'swh'
        }
        else {
            Install-SwhBlobService
            $global:SwhRoot = 'azblob://acct/cont'
            $global:SwhRun = 'azblob://acct/cont/swh'
        }
        SwhModule { param($r, $a, $b, $c)
            Initialize-VmfRun -RunPath $r -RunId 'swh' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'swh'; assessmentRunId = 'swh'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A' }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A' }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $c; wave = 'w2'; path = 'A' }) })
        } @($global:SwhRun, $global:SwhA, $global:SwhB, $global:SwhC)
    }
    function Global:SwhCleanup {
        if ($global:SwhBackend -eq 'file' -and $global:SwhRoot -and (Test-Path $global:SwhRoot)) { Remove-Item $global:SwhRoot -Recurse -Force }
    }
    # What a worker holds: this run's claim, then the lease, with a heartbeat
    # this many seconds old.
    function Global:SwhHold([string]$VmId, [int]$AgeSeconds = 2000, [string]$WorkerId = 'worker-1', [switch]$NoClaim) {
        SwhModule { param($r, $v, $age, $wid, $noClaim)
            if (-not $noClaim) { (New-VmfVmClaim -RunPath $r -VmId $v -RunId 'swh').Granted | Should -BeTrue }
            $at = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
            Write-VmfStoreJson -RunPath $r -RelPath (Get-VmfLeaseRelPath -VmId $v) -Depth 6 -Document ([ordered]@{
                vmId = $v; workerId = $wid; acquiredUtc = $at; heartbeatUtc = $at })
        } @($global:SwhRun, $VmId, $AgeSeconds, $WorkerId, [bool]$NoClaim)
    }
    function Global:SwhSetState([string]$VmId, [string]$State) {
        SwhModule { param($r, $v, $s)
            $doc = New-VmfStateDoc -RunPath $r -RunId 'swh' -VmId $v -Wave 'w1'
            if ($s -ne 'PLANNED') { $doc.state = $s; Write-VmfStateDoc -RunPath $r -Document $doc }
        } @($global:SwhRun, $VmId, $State)
    }
    function Global:SwhLease([string]$VmId) { SwhModule { param($r, $v) Get-VmfLeaseInfo -RunPath $r -VmId $v } @($global:SwhRun, $VmId) }
    function Global:SwhClaim([string]$VmId) { SwhModule { param($r, $v) Get-VmfVmClaim -RunPath $r -VmId $v } @($global:SwhRun, $VmId) }
    # The service's question before it starts Restore this machine.
    function Global:SwhRefusal([string]$VmId) { SwhModule { param($r, $v) Get-VmfMachineLeaseRefusal -RunPath $r -VmId $v } @($global:SwhRun, $VmId) }
    function Global:SwhEvents([string]$Step) { SwhModule { param($r, $s) @(Read-VmfEvents -RunPath $r -Step $s) } @($global:SwhRun, $Step) }

    # Azure's list of the engine job's executions.
    function Global:SwhExec([string]$Status, [string]$Wave, [string]$Run = 'swh', [string]$Operation = 'wave') {
        @{ name = "exec-$Status-$Wave"; properties = @{ status = $Status; template = @{ containers = @(@{ env = @(
            @{ name = 'VMF_OPERATION'; value = $Operation }, @{ name = 'VMF_RUN_ID'; value = $Run }, @{ name = 'VMF_WAVE'; value = $Wave }) }) } } }
    }
    function Global:SwhMockArm([object[]]$Executions = @()) {
        $global:SwhExecutions = @($Executions)
        $global:SwhListed = 0
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:SwhListed++
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($global:SwhExecutions) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'the pass starts nothing' }
    }
    function Global:SwhPass { @(Invoke-VmfFacadeRemoveEndedWaveHolds -StorePath $global:SwhRun -RunId 'swh') }
}

AfterAll {
    Remove-Item 'function:\Install-SwhBlobService', 'function:\SwhModule', 'function:\SwhNewStore', 'function:\SwhCleanup',
        'function:\SwhHold', 'function:\SwhSetState', 'function:\SwhLease', 'function:\SwhClaim', 'function:\SwhRefusal',
        'function:\SwhEvents', 'function:\SwhExec', 'function:\SwhMockArm', 'function:\SwhPass',
        'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable SwhVmBase, SwhA, SwhB, SwhC, SwhGone, SwhBlobs, SwhTags, SwhSerial, SwhBackend, SwhRoot, SwhRun,
        SwhExecutions, SwhListed -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'STALE-WAVE-HOLD-1: Remove-VmfExpiredLease -WaveWorkerOnly judges the holder and the age in one read (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach { SwhNewStore $backend }
    AfterEach { SwhCleanup }

    It 'removes an expired hold of a wave worker' {
        SwhHold $global:SwhA -AgeSeconds 2000 -NoClaim
        SwhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 900 -WaveWorkerOnly } @($global:SwhRun, $global:SwhA) | Should -BeTrue
        SwhLease $global:SwhA | Should -BeNullOrEmpty
    }
    It 'keeps an expired hold of a restore - that is the restart of the job, not this' {
        foreach ($holder in 'restore:op-1', 'restore:op-2') {
            SwhHold $global:SwhA -AgeSeconds 2000 -WorkerId $holder -NoClaim
            SwhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 900 -WaveWorkerOnly } @($global:SwhRun, $global:SwhA) | Should -BeFalse
            [string](SwhLease $global:SwhA).workerId | Should -Be $holder
        }
    }
    It 'keeps a fresh hold of a wave worker' {
        SwhHold $global:SwhA -AgeSeconds 30 -NoClaim
        SwhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 900 -WaveWorkerOnly } @($global:SwhRun, $global:SwhA) | Should -BeFalse
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
    }
    It 'without the switch it still removes any expired hold, as the wave watchdog needs' {
        SwhHold $global:SwhA -AgeSeconds 2000 -WorkerId 'restore:op-1' -NoClaim
        SwhModule { param($r, $v) Remove-VmfExpiredLease -RunPath $r -VmId $v -TimeoutSeconds 900 } @($global:SwhRun, $global:SwhA) | Should -BeTrue
    }
}

Describe 'STALE-WAVE-HOLD-1: the holds a stopped wave worker left on a machine whose move ended (Get-VmfEndedWaveHolds) (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach { SwhNewStore $backend }
    AfterEach { SwhCleanup }

    It 'lists an expired wave worker hold on a machine at each final state' {
        foreach ($state in 'MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION') {
            SwhSetState $global:SwhA $state
            SwhHold $global:SwhA -NoClaim
            $found = @(SwhModule { param($r) Get-VmfEndedWaveHolds -RunPath $r -TimeoutSeconds 900 } @($global:SwhRun))
            @($found.VmId) | Should -Be @($global:SwhA) -Because "$state is a final state"
            $found[0].State | Should -Be $state
        }
    }
    It 'never lists a hold on a machine at a working state - the wave resumes that machine' {
        foreach ($state in 'PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING') {
            SwhSetState $global:SwhA $state
            SwhHold $global:SwhA -NoClaim
            @(SwhModule { param($r) Get-VmfEndedWaveHolds -RunPath $r -TimeoutSeconds 900 } @($global:SwhRun)) | Should -BeNullOrEmpty -Because "$state is a working state"
        }
    }
    It 'never lists a hold on a machine with no record (taken, and stopped before its check)' {
        SwhHold $global:SwhA
        @(SwhModule { param($r) Get-VmfEndedWaveHolds -RunPath $r -TimeoutSeconds 900 } @($global:SwhRun)) | Should -BeNullOrEmpty
    }
    It 'never lists a fresh hold, or a hold of a restore' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA -AgeSeconds 30 -NoClaim
        SwhSetState $global:SwhB 'MIGRATED'
        SwhHold $global:SwhB -WorkerId 'restore:op-1' -NoClaim
        @(SwhModule { param($r) Get-VmfEndedWaveHolds -RunPath $r -TimeoutSeconds 900 } @($global:SwhRun)) | Should -BeNullOrEmpty
    }
}

Describe 'STALE-WAVE-HOLD-1: the service timer removes a stopped wave worker hold on a machine whose move ended (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        SwhNewStore $backend
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        SwhMockArm
    }
    AfterEach {
        SwhCleanup
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
    }

    It 'THE DEFECT: a MIGRATED machine whose worker stopped can be restored after one pass, and its claim is given back' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA -AgeSeconds 2000
        SwhRefusal $global:SwhA | Should -BeLike "*A wave migrates 'vm-a' now*" -Because 'the hold refuses the restore before the pass'
        $r = SwhPass
        @($r.VmId) | Should -Be @($global:SwhA)
        $r[0].ClaimReleased | Should -BeTrue
        SwhLease $global:SwhA | Should -BeNullOrEmpty
        SwhClaim $global:SwhA | Should -BeNullOrEmpty -Because 'a migrated machine is free for another migration (CLAIM-KEPT-AFTER-WAVE-1)'
        SwhRefusal $global:SwhA | Should -BeNullOrEmpty
        # And the engine's own take of the machine, as a restore makes it.
        SwhModule { param($r, $v)
            $token = Enter-VmfMachineLease -RunPath $r -VmId $v -Holder 'restore:op-9'
            try { [string](Get-VmfLeaseInfo -RunPath $r -VmId $v).workerId | Should -Be 'restore:op-9' }
            finally { Exit-VmfMachineLease -Token $token }
        } @($global:SwhRun, $global:SwhA)
        $line = @(SwhEvents 'watchdog')[-1]
        $line.outcome | Should -Be 'warn'
        $line.vmId | Should -Be $global:SwhA
        $line.detail | Should -BeLike "*worker-1*vm-a*MIGRATED*w1*"
    }
    It 'a SKIPPED machine gives its claim back too' {
        SwhSetState $global:SwhA 'SKIPPED'
        SwhHold $global:SwhA
        @((SwhPass).VmId) | Should -Be @($global:SwhA)
        SwhClaim $global:SwhA | Should -BeNullOrEmpty
    }
    It 'SKIP-CHANGED-FREED-1: a SKIPPED machine that was changed when it was left out loses the hold and KEEPS its claim' {
        # Another migration would take its first safety copy of the changed
        # machine as it was. Remove-VmfSettledVmClaim keeps that claim, and the
        # timer pass releases only through it.
        SwhModule { param($r, $v)
            New-VmfStateDoc -RunPath $r -RunId 'swh' -VmId $v -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'test' | Out-Null
            Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'SKIPPED' -Outcome skip -Detail 'left out by operator@example.com: later' | Out-Null
        } @($global:SwhRun, $global:SwhA)
        SwhHold $global:SwhA
        $r = SwhPass
        @($r.VmId) | Should -Be @($global:SwhA) -Because 'SKIPPED is a final state'
        $r[0].ClaimReleased | Should -BeFalse
        SwhLease $global:SwhA | Should -BeNullOrEmpty
        [string](SwhClaim $global:SwhA).runId | Should -Be 'swh'
        $line = @(SwhEvents 'watchdog')[-1]
        $line.detail | Should -Not -BeLike '*free for another migration*'
    }
    It 'a FAILED machine loses the hold and KEEPS its claim - this run still recovers it' {
        foreach ($state in 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION') {
            SwhSetState $global:SwhA $state
            SwhHold $global:SwhA
            $r = SwhPass
            @($r.VmId) | Should -Be @($global:SwhA) -Because "$state is a final state"
            $r[0].ClaimReleased | Should -BeFalse
            SwhLease $global:SwhA | Should -BeNullOrEmpty
            [string](SwhClaim $global:SwhA).runId | Should -Be 'swh' -Because "a machine at $state keeps its claim"
            SwhModule { param($r, $v) Remove-VmfVmClaim -RunPath $r -VmId $v -RunId 'swh' | Out-Null } @($global:SwhRun, $global:SwhA)
        }
    }
    It 'a machine at CONVERTING keeps the hold - the wave resumes it' {
        SwhSetState $global:SwhA 'CONVERTING'
        SwhHold $global:SwhA
        (SwhPass).Count | Should -Be 0
        [string](SwhLease $global:SwhA).workerId | Should -Be 'worker-1'
        [string](SwhClaim $global:SwhA).runId | Should -Be 'swh'
        SwhRefusal $global:SwhA | Should -BeLike "*A wave migrates 'vm-a' now*"
    }
    It 'a machine at PLANNED with a claim keeps the hold - WAVE-RESUME-PLANNED-1 starts its wave again' {
        SwhSetState $global:SwhA 'PLANNED'
        SwhHold $global:SwhA
        SwhHold $global:SwhB
        (SwhPass).Count | Should -Be 0
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
        SwhLease $global:SwhB | Should -Not -BeNullOrEmpty -Because 'a machine with no record was taken and stopped before its check'
        [string](SwhClaim $global:SwhA).runId | Should -Be 'swh'
    }
    It 'a fresh hold on a MIGRATED machine is kept - its worker may be in its finally now' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA -AgeSeconds 30
        (SwhPass).Count | Should -Be 0
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
        [string](SwhClaim $global:SwhA).runId | Should -Be 'swh'
    }
    It 'a hold is kept while an execution of the wave of the machine is Running or Processing' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        foreach ($status in 'Running', 'Processing') {
            SwhMockArm -Executions @((SwhExec $status 'w1'))
            (SwhPass).Count | Should -Be 0 -Because "a $status execution of w1 runs its own watchdog"
            SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
            [string](SwhClaim $global:SwhA).runId | Should -Be 'swh'
        }
    }
    It 'a run of the wave named the way the page starts it (VMF_PROJECT and VMF_RUN_ID apart) keeps the hold too' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        $exec = SwhExec 'Running' 'w1' -Run 'swh'
        $exec.properties.template.containers[0].env += @{ name = 'VMF_PROJECT'; value = 'p1' }
        SwhMockArm -Executions @($exec)
        @(Invoke-VmfFacadeRemoveEndedWaveHolds -StorePath $global:SwhRun -RunId 'p1/swh').Count | Should -Be 0
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
    }
    It 'an execution of another wave, a finished one, or one of another run does not keep it' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        SwhMockArm -Executions @((SwhExec 'Running' 'w2'), (SwhExec 'Succeeded' 'w1'), (SwhExec 'Running' 'w1' -Run 'other'), (SwhExec 'Running' 'w1' -Operation 'restore'))
        @((SwhPass).VmId) | Should -Be @($global:SwhA)
        SwhLease $global:SwhA | Should -BeNullOrEmpty
    }
    It 'a machine that is no longer in the plan loses the hold only while no wave of the run runs' {
        SwhSetState $global:SwhGone 'MIGRATED'
        SwhHold $global:SwhGone
        SwhMockArm -Executions @((SwhExec 'Running' 'w2'))
        (SwhPass).Count | Should -Be 0 -Because 'a wave of the run runs, and the plan cannot say which wave the machine was in'
        SwhMockArm
        @((SwhPass).VmId) | Should -Be @($global:SwhGone)
    }
    It 'a hold of a restore is left to the restart of its job' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA -WorkerId 'restore:op-1' -NoClaim
        (SwhPass).Count | Should -Be 0
        [string](SwhLease $global:SwhA).workerId | Should -Be 'restore:op-1'
    }
    It 'a hold renewed after the listing is kept - only the text judged is removed' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        # The heartbeat lands between the listing and the removal.
        Mock -ModuleName VmMigrationFactory Get-VmfEndedWaveHolds {
            SwhHold $global:SwhA -AgeSeconds 0 -NoClaim
            [pscustomobject]@{ VmId = $global:SwhA; State = 'MIGRATED'; WorkerId = 'worker-1' }
        }
        (SwhPass).Count | Should -Be 0
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
        [string](SwhClaim $global:SwhA).runId | Should -Be 'swh' -Because 'a claim is never given back while its hold stands'
    }
    It 'a hold that a restore took after the listing is kept, even when it is expired' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA -WorkerId 'restore:op-1' -NoClaim
        Mock -ModuleName VmMigrationFactory Get-VmfEndedWaveHolds { [pscustomobject]@{ VmId = $global:SwhA; State = 'MIGRATED'; WorkerId = 'worker-1' } }
        (SwhPass).Count | Should -Be 0
        [string](SwhLease $global:SwhA).workerId | Should -Be 'restore:op-1'
    }
    It 'finds the wave of a machine whose ID the plan spells in another letter case (VMID-CASE-1)' {
        $upper = $global:SwhA.ToUpperInvariant()
        SwhSetState $upper 'MIGRATED'
        SwhHold $upper -NoClaim
        SwhMockArm -Executions @((SwhExec 'Running' 'w2'))
        @((SwhPass).VmId) | Should -Be @($upper) -Because 'the machine is in w1, and only w2 runs'
    }
    It 'a machine that left its final state after the listing keeps the hold' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        Mock -ModuleName VmMigrationFactory Get-VmfEndedWaveHolds {
            SwhModule { param($r, $v) $doc = Read-VmfStateDoc -RunPath $r -VmId $v; $doc.state = 'PLANNED'; Write-VmfStateDoc -RunPath $r -Document $doc } @($global:SwhRun, $global:SwhA)
            [pscustomobject]@{ VmId = $global:SwhA; State = 'MIGRATED'; WorkerId = 'worker-1' }
        }
        (SwhPass).Count | Should -Be 0
        SwhLease $global:SwhA | Should -Not -BeNullOrEmpty
    }
    It 'a second pass finds nothing and says nothing more' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        (SwhPass).Count | Should -Be 1
        (SwhPass).Count | Should -Be 0
        @(SwhEvents 'watchdog').Count | Should -Be 1
    }
    It 'asks Azure once for each wave, and not at all when nothing is held' {
        (SwhPass).Count | Should -Be 0
        $global:SwhListed | Should -Be 0 -Because 'no hold, no question to Azure'
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        SwhSetState $global:SwhB 'MIGRATED'
        SwhHold $global:SwhB
        @((SwhPass).VmId | Sort-Object) | Should -Be @($global:SwhA, $global:SwhB)
        $global:SwhListed | Should -Be 1 -Because 'both machines are in w1'
    }
    It 'a halted run still loses the hold - a halt stops waves, and this starts nothing' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        SwhModule { param($r) Set-VmfWaveHalt -RunPath $r -Reason 'stop' } @($global:SwhRun)
        @((SwhPass).VmId) | Should -Be @($global:SwhA)
    }
    It 'a hold removed when the line cannot be written is still removed, and the words are not lost' {
        SwhSetState $global:SwhA 'MIGRATED'
        SwhHold $global:SwhA
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'watchdog' } { throw 'The store did not answer.' }
        $r = @(Invoke-VmfFacadeRemoveEndedWaveHolds -StorePath $global:SwhRun -RunId 'swh' -WarningVariable w -WarningAction SilentlyContinue)
        @($r.VmId) | Should -Be @($global:SwhA)
        SwhLease $global:SwhA | Should -BeNullOrEmpty
        ($w | ForEach-Object { "$_" }) -join ' ' | Should -BeLike "*'watchdog warn'*vm-a*"
    }
}

Describe 'STALE-WAVE-HOLD-1: the schedule pass removes the hold for every run' {
    It 'calls the pass for each run, and a failure of it is said and does not stop the next run' {
        $root = Join-Path $script:temp "tp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $env:VMF_STORE_PATH = $root
        try {
            foreach ($run in 'r1', 'r2') {
                SwhModule { param($rp, $id) Initialize-VmfRun -RunPath $rp -RunId $id | Out-Null
                    Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{ schemaVersion = 9; runId = $id; entries = @() })
                } @((Join-Path $root $run), $run)
            }
            Mock Invoke-VmfFacadeReleaseDueSchedules { @() }
            Mock Invoke-VmfFacadeResumeStalledWaves { @() }
            Mock Invoke-VmfFacadeResumeStalledPutBacks { @() }
            Mock Invoke-VmfFacadeContinuePlan { $null }
            Mock Invoke-VmfFacadeRemoveEndedWaveHolds { throw 'the leases could not be listed' }
            $schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'
            $null = & $schedule -Timer $null 3>&1
            Should -Invoke Invoke-VmfFacadeRemoveEndedWaveHolds -Times 2 -Exactly
            foreach ($run in 'r1', 'r2') {
                $line = @(SwhModule { param($rp) @(Read-VmfEvents -RunPath $rp -Step 'watchdog') } @((Join-Path $root $run)))[-1]
                $line.outcome | Should -Be 'fail'
                $line.detail | Should -BeLike '*the leases could not be listed*'
            }
        }
        finally {
            Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'STALE-WAVE-HOLD-1: a real worker that stops after the final state (kill-resume)' {
    # The worker process itself: the test engine stands where the state machine
    # runs, writes MIGRATED as the last checkpoint does, and ends the process
    # at once - so the finally that removes the hold and the claim never runs.
    It 'leaves the hold and the claim, and one timer pass after the limit lets a restore take the machine' {
        SwhNewStore 'file'
        try {
            $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
            SwhMockArm
            $planPath = Join-Path $global:SwhRun 'plan.json'
            $pp = Get-VmfFacadePlanPath -StorePath $global:SwhRun
            Confirm-VmfRunAcknowledgement -RunPath $global:SwhRun -AcknowledgedBy 'operator@example.com' | Out-Null
            Confirm-VmfWaveOptions -RunPath $global:SwhRun -PlanPath $pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            Approve-VmfWave -RunPath $global:SwhRun -PlanPath $pp -Wave 'w1' -Note 'test' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            $fakeEngine = Join-Path $global:SwhRoot 'migrated-then-stop.ps1'
            Set-Content -LiteralPath $fakeEngine -Value @'
param($entryJson, $rp, $rid)
$e = $entryJson | ConvertFrom-Json
& (Get-Module VmMigrationFactory) { param($r, $id, $v)
    $doc = New-VmfStateDoc -RunPath $r -RunId $id -VmId $v -Wave 'w1'
    $doc.state = 'MIGRATED'
    Write-VmfStateDoc -RunPath $r -Document $doc
} $rp $rid ([string]$e.vmId)
[Environment]::Exit(9)
'@
            $env:VMF_TEST_ENGINE = $fakeEngine
            try {
                $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-File', $script:workerPath, '-RunPath', $global:SwhRun, '-PlanPath', $planPath,
                    '-Wave', 'w1', '-RunId', 'swh', '-WorkerId', 'worker-1', '-IdleWaitSeconds', '1')
                $proc.WaitForExit(90000) | Should -BeTrue
                $proc.ExitCode | Should -Be 9
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }

            $taken = @($global:SwhA, $global:SwhB) | Where-Object { SwhLease $_ } | Select-Object -First 1
            $taken | Should -Not -BeNullOrEmpty -Because 'the stopped worker left its hold'
            $name = ($taken -split '/')[-1]
            [string](SwhModule { param($r, $v) (Read-VmfStateDoc -RunPath $r -VmId $v).state } @($global:SwhRun, $taken)) | Should -Be 'MIGRATED'
            [string](SwhClaim $taken).runId | Should -Be 'swh'
            SwhRefusal $taken | Should -BeLike "*A wave migrates '$name' now*"

            (SwhPass).Count | Should -Be 0 -Because 'the hold is still within the limit'
            SwhModule { param($r, $v)
                $rel = Get-VmfLeaseRelPath -VmId $v
                $lease = Read-VmfStoreJson -RunPath $r -RelPath $rel -Depth 6
                $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-2000).ToString('o')
                Write-VmfStoreJson -RunPath $r -RelPath $rel -Depth 6 -Document $lease
            } @($global:SwhRun, $taken)
            @((SwhPass).VmId) | Should -Be @($taken)
            SwhRefusal $taken | Should -BeNullOrEmpty
            SwhClaim $taken | Should -BeNullOrEmpty
            # The same pass again, after a second stop of the service: nothing more.
            (SwhPass).Count | Should -Be 0
        }
        finally {
            SwhCleanup
            Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
        }
    }
}
