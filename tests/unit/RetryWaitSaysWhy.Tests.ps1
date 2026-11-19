#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETRY-WAIT-SAYS-WHY-1. Final lab, 2026-11-16: a person selected Try this
# machine again on a machine of a finished wave (W1) while wave W2 ran. For
# 22 minutes the page said "Waits for the service's next check" and "The
# service starts it again within about 5 minutes". The service's restart
# (Invoke-VmfFacadeResumeStalledWaves) starts nothing while any hold in the
# run has a live heartbeat, and it wrote no line - nor for a wave that fails
# a start gate other than changed settings. The machine started about 6
# minutes after W2 finished.
#
# Now, when the restart holds a wave with a machine at work in it, it writes
# ONE line per cause (step 'resume', code 'held', the wave as data), the way
# Set-VmfPlanRunStatus writes the plan run only when its reason changed:
#   - holdBy 'wave'    : a live hold of a worker of ANOTHER wave (its wave
#                        named, or '' when no plan entry names it);
#   - holdBy 'restore' : only a live restore holds the run;
#   - holdBy 'gate'    : the wave fails a start gate, with its code and the
#                        gate's own words (data/start-gates.json).
# The line the restart writes when it starts the wave says 'resumed', and ends
# the hold. A live hold of a worker of the SAME wave is not a hold: that worker
# takes the machine. The page reads the line (tests/js/retry-wait-says-why.test.js).

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
    $script:temp = New-VmfTestTemp -Prefix 'retrywaitsayswhy'

    $global:RwsVmBase = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-rws/providers/Microsoft.Compute/virtualMachines/'
    $global:RwsA = "${global:RwsVmBase}vm-a"
    $global:RwsB = "${global:RwsVmBase}vm-b"
    $global:RwsC = "${global:RwsVmBase}vm-c"
    $global:RwsSet = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-rws/providers/Microsoft.Compute/availabilitySets/AS-ONE'

    function Global:Install-RwsBlobService {
        $global:RwsBlobs = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:RwsTags = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:RwsSerial = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:RwsBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    $there = $global:RwsBlobs.ContainsKey($path)
                    if ($query -match 'comp=appendblock') {
                        if (-not $there) { return @{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                        $global:RwsBlobs[$path] = $global:RwsBlobs[$path] + [string]$Body
                        $global:RwsTags[$path] = '"t' + (++$global:RwsSerial) + '"'
                        return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:RwsTags[$path] } }
                    }
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:RwsTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:RwsBlobs[$path] = [string]$Body
                    $global:RwsTags[$path] = '"t' + (++$global:RwsSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:RwsTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:RwsBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:RwsTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:RwsBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:RwsBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:RwsBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:RwsBlobs[$path]; Headers = @{ ETag = $global:RwsTags[$path] } }
                }
            }
        }
    }

    function Global:RwsModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store per test: a run 'rws' with wave w1 (vm-a, vm-b) and w2 (vm-c).
    function Global:RwsNewStore([string]$Backend) {
        $global:RwsBackend = $Backend
        if ($Backend -eq 'file') {
            $global:RwsRoot = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            [System.IO.Directory]::CreateDirectory($global:RwsRoot) | Out-Null
            $global:RwsRun = Join-Path $global:RwsRoot 'rws'
        }
        else {
            Install-RwsBlobService
            $global:RwsRoot = 'azblob://acct/cont'
            $global:RwsRun = 'azblob://acct/cont/rws'
        }
        RwsModule { param($r, $a, $b, $c)
            Initialize-VmfRun -RunPath $r -RunId 'rws' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'rws'; assessmentRunId = 'rws'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $c; wave = 'w2'; path = 'A'; policy = [ordered]@{ throttle = 5 } }) })
        } @($global:RwsRun, $global:RwsA, $global:RwsB, $global:RwsC)
    }
    function Global:RwsCleanup {
        if ($global:RwsBackend -eq 'file' -and $global:RwsRoot -and (Test-Path $global:RwsRoot)) { Remove-Item $global:RwsRoot -Recurse -Force }
    }
    # A hold, as a worker or a restore writes it, with a heartbeat this many seconds old.
    function Global:RwsLease([string]$VmId, [int]$AgeSeconds = 5, [string]$WorkerId = 'worker-1') {
        RwsModule { param($r, $v, $age, $w)
            Write-VmfStoreJson -RunPath $r -RelPath (Get-VmfLeaseRelPath -VmId $v) -Depth 6 -Document ([ordered]@{
                schemaVersion = 1; vmId = $v; workerId = $w; acquiredUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
                heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o') })
        } @($global:RwsRun, $VmId, $AgeSeconds, $WorkerId)
    }
    function Global:RwsUnlease([string]$VmId) {
        RwsModule { param($r, $v) Remove-VmfStoreItem -RunPath $r -RelPath (Get-VmfLeaseRelPath -VmId $v) } @($global:RwsRun, $VmId)
    }
    # A machine record at this state, whose last history step wrote it this
    # many minutes ago - the shape a decision's retry leaves.
    function Global:RwsSetState([string]$VmId, [string]$State, [double]$MinutesAgo = 10, [string]$Wave = 'w1') {
        RwsModule { param($r, $v, $s, $ago, $w)
            $doc = New-VmfStateDoc -RunPath $r -RunId 'rws' -VmId $v -Wave $w
            $doc.state = $s
            $doc.history = @([ordered]@{ tsUtc = (Get-Date).ToUniversalTime().AddMinutes(-$ago).ToString('o'); state = $s; outcome = 'ok'; detail = 'Decision resolved.' })
            Write-VmfStateDoc -RunPath $r -Document $doc
        } @($global:RwsRun, $VmId, $State, $MinutesAgo, $Wave)
    }
    function Global:RwsMockArm([object[]]$Executions = @()) {
        $global:RwsExecutions = @($Executions)
        $global:RwsStarts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($global:RwsExecutions) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $global:RwsStarts.Add([string]$Payload)
                return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = "exec-$($global:RwsStarts.Count)"; id = 'x' } | ConvertTo-Json) }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    function Global:RwsOpenGates([string[]]$Waves = @('w1', 'w2'), [switch]$NoApproval) {
        $pp = Get-VmfFacadePlanPath -StorePath $global:RwsRun
        Confirm-VmfRunAcknowledgement -RunPath $global:RwsRun -AcknowledgedBy 'operator@example.com' | Out-Null
        foreach ($w in $Waves) {
            Confirm-VmfWaveOptions -RunPath $global:RwsRun -PlanPath $pp -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            if (-not $NoApproval) {
                Approve-VmfWave -RunPath $global:RwsRun -PlanPath $pp -Wave $w -Note 'test' `
                    -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            }
        }
    }
    function Global:RwsResume { @(Invoke-VmfFacadeResumeStalledWaves -StorePath $global:RwsRun -RunId 'rws') }
    function Global:RwsHeld {
        @(RwsModule { param($r) @(Read-VmfEvents -RunPath $r -Step 'resume') } @($global:RwsRun) |
            Where-Object { $_.PSObject.Properties['code'] -and $_.code -eq 'held' })
    }
    function Global:RwsResumeLines { @(RwsModule { param($r) @(Read-VmfEvents -RunPath $r -Step 'resume') } @($global:RwsRun)) }
}

AfterAll {
    Remove-Item 'function:\Install-RwsBlobService', 'function:\RwsModule', 'function:\RwsNewStore', 'function:\RwsCleanup',
        'function:\RwsLease', 'function:\RwsUnlease', 'function:\RwsSetState', 'function:\RwsMockArm', 'function:\RwsOpenGates',
        'function:\RwsResume', 'function:\RwsHeld', 'function:\RwsResumeLines',
        'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable RwsVmBase, RwsA, RwsB, RwsC, RwsSet, RwsBlobs, RwsTags, RwsSerial, RwsBackend, RwsRoot, RwsRun,
        RwsExecutions, RwsStarts -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH, Env:\VMF_STORE_ACCOUNT, Env:\VMF_STORE_CONTAINER -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'RETRY-WAIT-SAYS-WHY-1: what holds a wave the service would start again (Get-VmfResumeLeaseHold)' {
    # Pure: the plan, the wave and the live holds in; the cause out.
    BeforeAll {
        $script:Plan = [pscustomobject]@{ entries = @(
            [pscustomobject]@{ vmId = $global:RwsA; wave = 'w1'; assessment = [pscustomobject]@{ availabilitySetId = '' } }
            [pscustomobject]@{ vmId = $global:RwsB; wave = 'w1' }
            [pscustomobject]@{ vmId = $global:RwsC; wave = 'w2'; assessment = [pscustomobject]@{ availabilitySetId = $global:RwsSet } }) }
        $script:L = { param($v, $w = 'worker-1') [pscustomobject]@{ vmId = $v; workerId = $w } }
        $script:Hold = { param($wave, $leases) RwsModule { param($p, $w, $l) Get-VmfResumeLeaseHold -Plan $p -Wave $w -Leases $l } @($script:Plan, $wave, @($leases)) }
    }

    It 'a live hold of a worker of another wave holds this wave, and names that wave' {
        $h = & $script:Hold 'w1' @((& $script:L $global:RwsC))
        $h.HoldBy | Should -Be 'wave'
        $h.HoldWave | Should -Be 'w2'
    }
    It 'a live hold of a worker of this wave is not a hold - that worker takes the machine' {
        & $script:Hold 'w1' @((& $script:L $global:RwsB), (& $script:L $global:RwsC)) | Should -BeNullOrEmpty
    }
    It 'the machine ID of a hold is matched in any letter case, and so is the wave' {
        & $script:Hold 'W1' @((& $script:L $global:RwsB.ToUpperInvariant())) | Should -BeNullOrEmpty
        (& $script:Hold 'w1' @((& $script:L $global:RwsC.ToUpperInvariant()))).HoldWave | Should -Be 'w2'
    }
    It 'only a restore holds the run: the cause is the restore, also when the restore is on a machine of this wave' {
        $h = & $script:Hold 'w1' @((& $script:L $global:RwsB 'restore:op-1'))
        $h.HoldBy | Should -Be 'restore'
        $h.HoldWave | Should -Be ''
    }
    It 'a wave worker is named before a restore' {
        $h = & $script:Hold 'w1' @((& $script:L $global:RwsA 'restore:op-1'), (& $script:L $global:RwsC))
        $h.HoldBy | Should -Be 'wave'
        $h.HoldWave | Should -Be 'w2'
    }
    It 'the hold a worker takes on an availability set is read as the wave of a machine in that set' {
        $set = 'group-avset/' + $global:RwsSet.Trim('/').ToLowerInvariant()
        (& $script:Hold 'w1' @((& $script:L $set))).HoldWave | Should -Be 'w2'
        & $script:Hold 'w2' @((& $script:L $set)) | Should -BeNullOrEmpty
    }
    It 'a worker hold on a machine no plan entry names holds the run, with no wave named' {
        $h = & $script:Hold 'w1' @((& $script:L "${global:RwsVmBase}vm-gone"))
        $h.HoldBy | Should -Be 'wave'
        $h.HoldWave | Should -Be ''
    }
    It 'no live hold: nothing holds the wave' {
        & $script:Hold 'w1' @() | Should -BeNullOrEmpty
    }
}

Describe 'RETRY-WAIT-SAYS-WHY-1: the restart says once why it holds a retried machine (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        RwsNewStore $backend
        RwsMockArm
        if ($backend -eq 'file') { $env:VMF_STORE_PATH = $global:RwsRoot }
        else { $env:VMF_STORE_ACCOUNT = 'acct'; $env:VMF_STORE_CONTAINER = 'cont' }
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
    }
    AfterEach {
        RwsCleanup
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH, Env:\VMF_STORE_ACCOUNT, Env:\VMF_STORE_CONTAINER -ErrorAction SilentlyContinue
    }

    It 'a live hold of another wave: one line names that wave, and a second pass writes no second line' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsSetState $global:RwsC 'CONVERTING' -Wave 'w2'
        RwsLease $global:RwsC
        RwsResume | Should -BeNullOrEmpty
        $held = @(RwsHeld)
        $held.Count | Should -Be 1
        $held[0].wave | Should -Be 'w1'
        $held[0].holdBy | Should -Be 'wave'
        $held[0].holdWave | Should -Be 'w2'
        $held[0].outcome | Should -Be 'info'
        $held[0].detail | Should -Be 'A machine in wave w1 waits for wave w2 to finish. Then the service starts wave w1 again.'
        $held[0].PSObject.Properties['vmId'] | Should -BeNullOrEmpty -Because 'a line of a machine would tell the page that something works on it'
        RwsResume | Should -BeNullOrEmpty
        RwsResume | Should -BeNullOrEmpty
        @(RwsHeld).Count | Should -Be 1 -Because 'the cause did not change'
        $global:RwsStarts.Count | Should -Be 0
    }
    It 'the cause changes: one more line, which names the new cause' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsLease $global:RwsC
        RwsResume | Out-Null
        RwsUnlease $global:RwsC
        RwsLease $global:RwsB -WorkerId 'restore:op-7'
        # A restore of a machine of this wave: the wave is still held, by the restore.
        RwsResume | Out-Null
        $held = @(RwsHeld)
        $held.Count | Should -Be 2
        $held[1].holdBy | Should -Be 'restore'
        $held[1].detail | Should -Be 'A machine in wave w1 waits for a restore to finish. Then the service starts wave w1 again.'
    }
    It 'a retry after the line: the same cause is said again, for the new retry' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK' -MinutesAgo 30
        RwsLease $global:RwsC
        RwsResume | Out-Null
        RwsSetState $global:RwsB 'PRECHECK' -MinutesAgo -1
        RwsResume | Out-Null
        @(RwsHeld).Count | Should -Be 2
    }
    It 'a live hold of a worker of the same wave writes no line - that worker takes the machine' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsLease $global:RwsB
        RwsResume | Should -BeNullOrEmpty
        @(RwsHeld).Count | Should -Be 0
    }
    It 'a hold with an old heartbeat holds nothing: the wave starts, and its line says resumed' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsLease $global:RwsC -AgeSeconds 2000
        $r = @(RwsResume)
        $r.Count | Should -Be 1
        @(RwsHeld).Count | Should -Be 0
        $line = @(RwsResumeLines) | Select-Object -Last 1
        $line.code | Should -Be 'resumed'
        $line.wave | Should -Be 'w1'
    }
    It 'a wave that fails a start gate: one line with the gate''s code and its own words, and once' {
        RwsOpenGates -NoApproval
        RwsSetState $global:RwsA 'PRECHECK'
        RwsResume | Should -BeNullOrEmpty
        RwsResume | Should -BeNullOrEmpty
        $held = @(RwsHeld)
        $held.Count | Should -Be 1
        $held[0].holdBy | Should -Be 'gate'
        $held[0].gate | Should -Be 'notApproved'
        $held[0].reason | Should -Be 'Nobody approved wave w1. An approver must select Approve on wave w1.'
        $held[0].detail | Should -Be 'A machine in wave w1 waits, because wave w1 cannot start yet. Nobody approved wave w1. An approver must select Approve on wave w1.'
        $global:RwsStarts.Count | Should -Be 0
    }
    It 'changed settings: the refusal the page offers the acceptance from, and the hold line' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsModule { param($r)
            $plan = Read-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24
            $plan.entries[0].policy.throttle = 2
            Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24 -Document $plan
        } @($global:RwsRun)
        RwsResume | Should -BeNullOrEmpty
        @(RwsModule { param($r) @(Read-VmfEvents -RunPath $r -Step 'acceptance' | Where-Object { $_.outcome -eq 'refused' }) } @($global:RwsRun)).Count | Should -Be 1
        $held = @(RwsHeld)
        $held.Count | Should -Be 1
        $held[0].gate | Should -Be 'changed'
    }
    It 'after the start, the same cause is said again when it comes back' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsLease $global:RwsC
        RwsResume | Out-Null
        RwsUnlease $global:RwsC
        @(RwsResume).Count | Should -Be 1
        RwsLease $global:RwsC
        # The engine started, and the machine waits again (a new execution
        # that stopped): the start line ended the first hold.
        $global:RwsExecutions = @()
        RwsResume | Out-Null
        @(RwsHeld).Count | Should -Be 2
    }
    It 'nothing holds a wave with no machine at work: no line' {
        RwsOpenGates
        RwsLease $global:RwsC
        RwsResume | Should -BeNullOrEmpty
        @(RwsHeld).Count | Should -Be 0
    }
    It 'a run stopped with Stop the run, or paused by the brake, writes no hold line' {
        RwsOpenGates
        RwsSetState $global:RwsA 'PRECHECK'
        RwsLease $global:RwsC
        RwsModule { param($r) Set-VmfWaveHalt -RunPath $r -Reason 'stop' | Out-Null } @($global:RwsRun)
        RwsResume | Should -BeNullOrEmpty
        @(RwsHeld).Count | Should -Be 0
    }
}

Describe 'RETRY-WAIT-SAYS-WHY-1: the line is written once per cause (Write-VmfResumeHoldLine)' {
    BeforeEach { RwsNewStore 'file' }
    AfterEach { RwsCleanup }

    It 'a line of another wave does not count for this one' {
        RwsModule { param($r)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w2' -Hold @{ HoldBy = 'restore'; HoldWave = '' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'restore'; HoldWave = '' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'restore'; HoldWave = '' } | Should -BeFalse
        } @($global:RwsRun)
    }
    It 'a line older than the newest retry of the wave is said again' {
        RwsModule { param($r)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w2' } | Should -BeTrue
            $later = (Get-Date).ToUniversalTime().AddMinutes(1)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w2' } -Since $later | Should -BeTrue
            $earlier = (Get-Date).ToUniversalTime().AddMinutes(-10)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w2' } -Since $earlier | Should -BeFalse
        } @($global:RwsRun)
    }
    It 'another gate is another cause' {
        RwsModule { param($r)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'gate'; Gate = 'notApproved'; Reason = 'Nobody approved wave w1. An approver must select Approve on wave w1.' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'gate'; Gate = 'notAccepted'; Reason = 'Nobody accepted the settings of wave w1. On wave w1, select Review & accept options.' } | Should -BeTrue
        } @($global:RwsRun)
    }
    It 'another holding wave is another cause: a worker of w3 after a worker of w2 gets its own line' {
        RwsModule { param($r)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w2' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w3' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = 'w3' } | Should -BeFalse
        } @($global:RwsRun)
        @(RwsHeld | ForEach-Object { $_.holdWave }) | Should -Be @('w2', 'w3')
    }
    It 'the same gate with other words is another cause: the line says the words the gate gives now' {
        RwsModule { param($r)
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'gate'; Gate = 'changed'; Reason = 'The settings of wave w1 changed after a@example.com accepted them. On wave w1, select Review & accept options again.' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'gate'; Gate = 'changed'; Reason = 'The settings of wave w1 changed after b@example.com accepted them. On wave w1, select Review & accept options again.' } | Should -BeTrue
            Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'gate'; Gate = 'changed'; Reason = 'The settings of wave w1 changed after b@example.com accepted them. On wave w1, select Review & accept options again.' } | Should -BeFalse
        } @($global:RwsRun)
        @(RwsHeld)[1].reason | Should -Match 'b@example\.com'
    }
    It 'a wave worker of an unnamed wave is said as a running wave' {
        RwsModule { param($r) Write-VmfResumeHoldLine -RunPath $r -Wave 'w1' -Hold @{ HoldBy = 'wave'; HoldWave = '' } | Out-Null } @($global:RwsRun)
        (@(RwsHeld)[0]).detail | Should -Be 'A machine in wave w1 waits for a running wave to finish. Then the service starts wave w1 again.'
    }
}
