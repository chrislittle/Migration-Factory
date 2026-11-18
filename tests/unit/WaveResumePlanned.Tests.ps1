#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-RESUME-PLANNED-1. A worker takes a machine's claim and its lease
# (Get-VmfNextWaveVm), then the state machine writes its record and moves it
# from PLANNED to PRECHECK. An execution that stopped between the two left the
# lease to expire, and nothing started the wave again: the service's restart
# (Invoke-VmfFacadeResumeStalledWaves) asked only for a machine PAST PLANNED,
# because "a wave nobody started is waiting, not stalled". The machines waited
# for ever, and the taken machine's claim kept it from other migrations.
#
# The service now tells the two apart with two facts the product already
# writes, both durable on both store backends:
#   - THIS RUN'S CLAIM on a machine of the wave whose record is not past
#     PLANNED (or that has no record): only a worker takes a claim, and only
#     after its wave started. A worker that leaves a machine untouched gives
#     the claim back (WAVE-MIX-2), and a settled machine gives it back too
#     (CLAIM-KEPT-AFTER-WAVE-1).
#   - AN OPEN 'wave start' LINE for that wave: the engine writes it after every
#     start gate passed, and writes a 'wave ok' or 'wave fail' line naming the
#     wave when the execution ends. A start no end line follows is an
#     execution that stopped.
# Both, because each alone can misfire: a claim left on a machine that a
# person then moved into a wave nobody has started; a start line whose
# execution stopped before any worker ran (no machine was taken, so nothing
# is held).
#
# The cases held here, each against the rule that would misfire on it:
#   - stopped after the claim, before PRECHECK: started again once the lease
#     expires, never while it is live, never while an execution of the wave is
#     Running or Processing;
#   - a wave nobody started (approved, scheduled, or refused by Azure before
#     any worker ran) is left alone;
#   - a wave whose execution ended (ok or fail) is left alone;
#   - a run stopped by Stop the run is left alone;
#   - the engine's start gates (approval among them) still apply;
#   - the file backend and blob storage.

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
    $script:temp = New-VmfTestTemp -Prefix 'waveresumeplanned'
    $script:workerPath = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'))

    $global:WrpVmBase = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-wrp/providers/Microsoft.Compute/virtualMachines/'
    $global:WrpA = "${global:WrpVmBase}vm-a"
    $global:WrpB = "${global:WrpVmBase}vm-b"
    $global:WrpC = "${global:WrpVmBase}vm-c"

    # A store in memory that answers as blob storage does: an ETag per text,
    # If-None-Match: * for a create, If-Match on a write and on a delete, and
    # an append blob that comp=appendblock adds to.
    function Global:Install-WrpBlobService {
        $global:WrpBlobs = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:WrpTags = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:WrpSerial = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:WrpBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    $there = $global:WrpBlobs.ContainsKey($path)
                    if ($query -match 'comp=appendblock') {
                        if (-not $there) { return @{ StatusCode = 404; Content = 'BlobNotFound'; Headers = @{} } }
                        $global:WrpBlobs[$path] = $global:WrpBlobs[$path] + [string]$Body
                        $global:WrpTags[$path] = '"t' + (++$global:WrpSerial) + '"'
                        return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:WrpTags[$path] } }
                    }
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:WrpTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:WrpBlobs[$path] = [string]$Body
                    $global:WrpTags[$path] = '"t' + (++$global:WrpSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:WrpTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:WrpBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:WrpTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:WrpBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:WrpBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:WrpBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:WrpBlobs[$path]; Headers = @{ ETag = $global:WrpTags[$path] } }
                }
            }
        }
    }

    function Global:WrpModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store per test: a run 'wrp' with wave w1 (vm-a, vm-b) and w2 (vm-c).
    function Global:WrpNewStore([string]$Backend) {
        $global:WrpBackend = $Backend
        if ($Backend -eq 'file') {
            $global:WrpRoot = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            [System.IO.Directory]::CreateDirectory($global:WrpRoot) | Out-Null
            $global:WrpRun = Join-Path $global:WrpRoot 'wrp'
        }
        else {
            Install-WrpBlobService
            $global:WrpRoot = 'azblob://acct/cont'
            $global:WrpRun = 'azblob://acct/cont/wrp'
        }
        WrpModule { param($r, $a, $b, $c)
            Initialize-VmfRun -RunPath $r -RunId 'wrp' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'wrp'; assessmentRunId = 'wrp'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $c; wave = 'w2'; path = 'A'; policy = [ordered]@{ throttle = 5 } }) })
        } @($global:WrpRun, $global:WrpA, $global:WrpB, $global:WrpC)
    }
    function Global:WrpCleanup {
        if ($global:WrpBackend -eq 'file' -and $global:WrpRoot -and (Test-Path $global:WrpRoot)) { Remove-Item $global:WrpRoot -Recurse -Force }
    }
    # The 'wave start' line as Start-VmfWave writes it, after every gate passed.
    function Global:WrpWaveStart([string]$Wave = 'w1') {
        WrpModule { param($r, $w) Write-VmfEvent -RunPath $r -Step 'wave' -Outcome start -Detail "wave=$w entries=2 workers=2" -Data @{ wave = $w } } @($global:WrpRun, $Wave)
    }
    function Global:WrpWaveEnd([string]$Wave = 'w1', [string]$Outcome = 'ok') {
        WrpModule { param($r, $w, $o) Write-VmfEvent -RunPath $r -Step 'wave' -Outcome $o -Detail 'PLANNED=2' -Data @{ wave = $w } } @($global:WrpRun, $Wave, $Outcome)
    }
    # What a worker does before the state machine runs: the claim, under
    # run.json's id, then the lease - with a heartbeat this many seconds old.
    function Global:WrpTake([string]$VmId, [int]$AgeSeconds = 2000, [string]$RunId = 'wrp') {
        WrpModule { param($r, $v, $age, $rid)
            (New-VmfVmClaim -RunPath $r -VmId $v -RunId $rid).Granted | Should -BeTrue
            Write-VmfStoreJson -RunPath $r -RelPath (Get-VmfLeaseRelPath -VmId $v) -Depth 6 -Document ([ordered]@{
                vmId = $v; workerId = 'worker-1'; acquiredUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
                heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o') })
        } @($global:WrpRun, $VmId, $AgeSeconds, $RunId)
    }
    function Global:WrpSetState([string]$VmId, [string]$State) {
        WrpModule { param($r, $v, $s)
            $doc = New-VmfStateDoc -RunPath $r -RunId 'wrp' -VmId $v -Wave 'w1'
            if ($s -ne 'PLANNED') { $doc.state = $s; Write-VmfStateDoc -RunPath $r -Document $doc }
        } @($global:WrpRun, $VmId, $State)
    }
    function Global:WrpTaken {
        WrpModule { param($r)
            $plan = Read-VmfPlanDocument -RunPath $r -Depth 24
            $states = @{}
            foreach ($name in Get-VmfStoreNames -RunPath $r -Folder 'state' -Extension '.json') {
                $doc = Read-VmfStoreJson -RunPath $r -RelPath "state/$name" -Depth 12
                if ($doc) { $states[[string]$doc.vmId] = [string]$doc.state }
            }
            Get-VmfWaveTakenBeforeCheck -RunPath $r -Plan $plan -States $states
        } @($global:WrpRun)
    }

    # Azure's list of the engine job's executions, and a start Azure accepts
    # (or refuses with the code given).
    function Global:WrpExec([string]$Status, [string]$Wave, [string]$Run = 'wrp') {
        @{ name = "exec-$Status-$Wave"; properties = @{ status = $Status; template = @{ containers = @(@{ env = @(
            @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = $Run }, @{ name = 'VMF_WAVE'; value = $Wave }) }) } } }
    }
    function Global:WrpMockArm([object[]]$Executions = @(), [int]$StartCode = 202) {
        $global:WrpExecutions = @($Executions)
        $global:WrpStartCode = $StartCode
        $global:WrpStarts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($global:WrpExecutions) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $global:WrpStarts.Add([string]$Payload)
                if ($global:WrpStartCode -in 200, 202) {
                    return [pscustomobject]@{ StatusCode = $global:WrpStartCode; Content = (@{ name = "exec-$($global:WrpStarts.Count)"; id = 'x' } | ConvertTo-Json) }
                }
                return [pscustomobject]@{ StatusCode = $global:WrpStartCode; Content = '{"error":{"code":"ContainerAppEnvironmentCoresQuotaExceeded"}}' }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    # Every start gate open for these waves, the way a person opens them.
    function Global:WrpOpenGates([string[]]$Waves = @('w1', 'w2'), [switch]$NoApproval) {
        $pp = Get-VmfFacadePlanPath -StorePath $global:WrpRun
        Confirm-VmfRunAcknowledgement -RunPath $global:WrpRun -AcknowledgedBy 'operator@example.com' | Out-Null
        foreach ($w in $Waves) {
            Confirm-VmfWaveOptions -RunPath $global:WrpRun -PlanPath $pp -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            if (-not $NoApproval) {
                Approve-VmfWave -RunPath $global:WrpRun -PlanPath $pp -Wave $w -Note 'test' `
                    -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            }
        }
    }
    function Global:WrpResume { @(Invoke-VmfFacadeResumeStalledWaves -StorePath $global:WrpRun -RunId 'wrp') }
    function Global:WrpEvents([string]$Step) { WrpModule { param($r, $s) @(Read-VmfEvents -RunPath $r -Step $s) } @($global:WrpRun, $Step) }
}

AfterAll {
    Remove-Item 'function:\Install-WrpBlobService', 'function:\WrpModule', 'function:\WrpNewStore', 'function:\WrpCleanup',
        'function:\WrpWaveStart', 'function:\WrpWaveEnd', 'function:\WrpTake', 'function:\WrpSetState', 'function:\WrpTaken',
        'function:\WrpExec', 'function:\WrpMockArm', 'function:\WrpOpenGates', 'function:\WrpResume', 'function:\WrpEvents',
        'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable WrpVmBase, WrpA, WrpB, WrpC, WrpBlobs, WrpTags, WrpSerial, WrpBackend, WrpRoot, WrpRun,
        WrpExecutions, WrpStartCode, WrpStarts -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH, Env:\VMF_STORE_ACCOUNT, Env:\VMF_STORE_CONTAINER -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'WAVE-RESUME-PLANNED-1: which wave starts are still open (Get-VmfOpenWaveStarts)' {
    # Pure: the run history lines in, the waves out.
    BeforeAll {
        $script:Line = { param($o, $w, $d) $e = [ordered]@{ step = 'wave'; outcome = $o; detail = $d }; if ($w) { $e.wave = $w }; [pscustomobject]$e }
        $script:Open = { param($events) @(WrpModule { param($e) Get-VmfOpenWaveStarts -Events $e } @(, @($events))) }
    }

    It 'a start that no end line follows is open' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1 entries=2 workers=2')) | Should -Be @('w1')
    }
    It 'an ok line and a fail line for the wave each end its start' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1 entries=2 workers=2'), (& $script:Line 'ok' 'w1' 'PLANNED=1')) | Should -BeNullOrEmpty
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1 entries=2 workers=2'), (& $script:Line 'fail' 'w1' 'Every worker stopped')) | Should -BeNullOrEmpty
    }
    It 'the end of another wave does not end this one' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1 entries=2'), (& $script:Line 'start' 'w2' 'wave=w2 entries=1'),
            (& $script:Line 'ok' 'w2' 'MIGRATED=1')) | Should -Be @('w1')
    }
    It 'a start after an end opens the wave again' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1'), (& $script:Line 'ok' 'w1' 'x'), (& $script:Line 'start' 'w1' 'wave=w1')) | Should -Be @('w1')
    }
    It 'a start line written before the wave was named on it is read from its words' {
        & $script:Open @((& $script:Line 'start' $null 'wave=w1 entries=2 workers=2')) | Should -Be @('w1')
    }
    It 'an end line that names no wave (written before this change) ends every start before it - unknown never restarts a wave' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1'), (& $script:Line 'start' 'w2' 'wave=w2'), (& $script:Line 'ok' $null 'MIGRATED=2')) | Should -BeNullOrEmpty
    }
    It 'a halt, a halt cleared and the other lines of the wave step end nothing' {
        & $script:Open @((& $script:Line 'start' 'w1' 'wave=w1'), (& $script:Line 'warn' $null 'HALTED: stop'), (& $script:Line 'warn' $null 'HALT CLEARED'),
            (& $script:Line 'info' 'w1' 'Container 1/2 has finished its share')) | Should -Be @('w1')
    }
    It 'lines of other steps are not wave lines' {
        & $script:Open @([pscustomobject]@{ step = 'resume'; outcome = 'start'; detail = 'wave=w9'; wave = 'w9' }) | Should -BeNullOrEmpty
    }
    It 'no lines, no open start' {
        & $script:Open @() | Should -BeNullOrEmpty
    }
}

Describe 'WAVE-RESUME-PLANNED-1: machines a stopped execution took before their check (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach { WrpNewStore $backend }
    AfterEach { WrpCleanup }

    It 'a machine with this run''s claim and no record, in a wave whose start is open, is found' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        $t = WrpTaken
        @($t.Keys) | Should -Be @('w1')
        @($t['w1']) | Should -Be @($global:WrpA)
    }
    It 'so is one whose record says PLANNED' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpSetState $global:WrpA 'PLANNED'
        @((WrpTaken)['w1']) | Should -Be @($global:WrpA)
    }
    It 'a machine with no claim is not taken - nobody took it' {
        WrpWaveStart 'w1'
        (WrpTaken).Count | Should -Be 0
    }
    It 'another run''s claim is not this run''s work' {
        WrpModule { param($r) Initialize-VmfRun -RunPath ($r -replace 'wrp$', 'other') -RunId 'other' | Out-Null } @($global:WrpRun)
        WrpWaveStart 'w1'
        WrpModule { param($r, $v) (New-VmfVmClaim -RunPath ($r -replace 'wrp$', 'other') -VmId $v -RunId 'other').Granted | Should -BeTrue } @($global:WrpRun, $global:WrpA)
        (WrpTaken).Count | Should -Be 0
    }
    It 'a claim in a wave with no start line - a machine moved into a wave nobody started - is not taken' {
        WrpTake $global:WrpC
        (WrpTaken).Count | Should -Be 0
    }
    It 'a claim in a wave whose execution ended is not taken - that execution was not stopped' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpWaveEnd 'w1' 'ok'
        (WrpTaken).Count | Should -Be 0
    }
    It 'a machine past PLANNED is not in this list - the restart already asks for it' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpSetState $global:WrpA 'CONVERTING'
        (WrpTaken).Count | Should -Be 0
    }
    It 'a machine the wave does not move (EXCLUDED or MANUAL) is not taken - no worker ever takes one' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpModule { param($r)
            $plan = Read-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24
            $plan.entries[0].path = 'EXCLUDED'
            Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 24 -Document $plan
        } @($global:WrpRun)
        (WrpTaken).Count | Should -Be 0
    }
    It 'a settled machine is not taken' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpSetState $global:WrpA 'FAILED_ROLLED_BACK'
        (WrpTaken).Count | Should -Be 0
    }
    It 'a run whose own id cannot be read takes nothing' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpModule { param($r) Remove-VmfStoreItem -RunPath $r -RelPath 'run.json' } @($global:WrpRun)
        (WrpTaken).Count | Should -Be 0
        # Not even a claim that names no run: two unknowns are not a match.
        WrpModule { param($r, $v)
            Write-VmfStoreJson -RunPath (Get-VmfClaimScopePath -RunPath $r) -RelPath (Get-VmfClaimRelPath -VmId $v) -Depth 6 -Document ([ordered]@{
                schemaVersion = 1; vmId = $v; runId = ''; runPath = $r })
        } @($global:WrpRun, $global:WrpA)
        (WrpTaken).Count | Should -Be 0
    }
}

Describe 'WAVE-RESUME-PLANNED-1: the service starts a wave again after its execution stopped before any check (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        WrpNewStore $backend
        # The service names a blob store by its account and container, as an install does.
        if ($backend -eq 'file') { $env:VMF_STORE_PATH = $global:WrpRoot }
        else { $env:VMF_STORE_ACCOUNT = 'acct'; $env:VMF_STORE_CONTAINER = 'cont' }
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        WrpOpenGates
        WrpMockArm
    }
    AfterEach {
        WrpCleanup
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH, Env:\VMF_STORE_ACCOUNT, Env:\VMF_STORE_CONTAINER -ErrorAction SilentlyContinue
    }

    It 'an execution that stopped after the claim and before PRECHECK is started again once its lease expires' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA -AgeSeconds 2000
        $r = WrpResume
        @($r.Wave) | Should -Be @('w1')
        @($r[0].Machines) | Should -Be @($global:WrpA)
        $global:WrpStarts.Count | Should -Be 1
        $global:WrpStarts[0] | Should -Match 'w1'
        $line = @(WrpEvents 'resume')[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match 'vm-a at PLANNED'
    }
    It 'not while its lease is live - the worker may still be about to check it' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA -AgeSeconds 30
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'not while an execution of the wave is Running or Processing' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        foreach ($status in 'Running', 'Processing') {
            WrpMockArm -Executions @((WrpExec $status 'w1'))
            (WrpResume).Count | Should -Be 0 -Because "a $status execution is a run of this wave"
            $global:WrpStarts.Count | Should -Be 0
        }
    }
    It 'a wave nobody started is left alone - approved, every gate open, nothing taken' {
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a scheduled wave whose time has not come is left alone' {
        Invoke-VmfFacadeSchedule -Principal ([pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }) `
            -StorePath $global:WrpRun -Wave 'w1' -RunAtUtc ((Get-Date).AddHours(6).ToString('o')) -Note 'tonight' | Out-Null
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a wave whose start Azure refused before any worker ran is left alone' {
        WrpMockArm -StartCode 403
        { Invoke-VmfFacadeStartEngine -Principal ([pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }) `
            -Operation 'wave' -RunId 'wrp' -Wave 'w1' -Note 'first' } | Should -Throw
        $global:WrpStarts.Count | Should -Be 1
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 1 -Because 'the pass started nothing more'
    }
    It 'an execution that stopped after its start line and before any worker took a machine is left for a person (nothing is held)' {
        WrpWaveStart 'w1'
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a machine moved into a wave nobody started keeps no wave waiting for a restart' {
        # A claim left by a worker of w1 that stopped; a person then moved the machine to w2.
        WrpWaveStart 'w1'
        WrpTake $global:WrpC
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a wave whose execution ended (ok or fail) is not started again' {
        foreach ($end in 'ok', 'fail') {
            WrpWaveStart 'w1'
            WrpTake $global:WrpA
            WrpWaveEnd 'w1' $end
            (WrpResume).Count | Should -Be 0 -Because "the execution ended with '$end'"
        }
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a run stopped by Stop the run is left alone' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        Stop-VmfRun -RunPath $global:WrpRun -Reason 'test' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'a halted run is left alone' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpModule { param($r) Set-VmfWaveHalt -RunPath $r -Reason 'stop' } @($global:WrpRun)
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'resuming is not approving - a wave that lost its approval is left alone' {
        WrpWaveStart 'w1'
        WrpTake $global:WrpA
        WrpModule { param($r) Remove-VmfStoreItem -RunPath $r -RelPath 'approvals/w1.json' } @($global:WrpRun)
        (WrpResume).Count | Should -Be 0
        $global:WrpStarts.Count | Should -Be 0
    }
    It 'only the wave with the taken machine starts, and a second pass starts nothing while it runs' {
        WrpWaveStart 'w1'
        WrpWaveStart 'w2'
        WrpTake $global:WrpA
        @((WrpResume).Wave) | Should -Be @('w1') -Because 'w2 holds no machine a stopped execution took'
        WrpMockArm -Executions @((WrpExec 'Processing' 'w1'))
        (WrpResume).Count | Should -Be 0
    }
}

Describe 'WAVE-RESUME-PLANNED-1: a real worker that stops after the claim' {
    # The worker process itself: the test engine stands where the state machine
    # runs and ends the process at once, so the claim and the lease are left
    # with no record, exactly as an execution that stopped there leaves them.
    It 'leaves a claim and a lease with no record, and the service starts the wave again once the lease expires' {
        WrpNewStore 'file'
        try {
            $env:VMF_STORE_PATH = $global:WrpRoot
            $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
            WrpOpenGates
            WrpMockArm
            $planPath = Join-Path $global:WrpRun 'plan.json'
            $fakeEngine = Join-Path $global:WrpRoot 'stop-engine.ps1'
            Set-Content -LiteralPath $fakeEngine -Value '[Environment]::Exit(9)'
            WrpWaveStart 'w1'
            $env:VMF_TEST_ENGINE = $fakeEngine
            try {
                $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-File', $script:workerPath, '-RunPath', $global:WrpRun, '-PlanPath', $planPath,
                    '-Wave', 'w1', '-RunId', 'wrp', '-WorkerId', 'worker-1', '-IdleWaitSeconds', '1')
                $proc.WaitForExit(90000) | Should -BeTrue
                $proc.ExitCode | Should -Be 9
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }

            WrpModule { param($r, $a)
                Read-VmfStateDoc -RunPath $r -VmId $a | Should -BeNullOrEmpty
                [string](Get-VmfVmClaim -RunPath $r -VmId $a).runId | Should -Be 'wrp'
                Get-VmfLeaseInfo -RunPath $r -VmId $a | Should -Not -BeNullOrEmpty
            } @($global:WrpRun, $global:WrpA)

            (WrpResume).Count | Should -Be 0 -Because 'the lease is still live'
            WrpModule { param($r, $a)
                $rel = Get-VmfLeaseRelPath -VmId $a
                $lease = Read-VmfStoreJson -RunPath $r -RelPath $rel -Depth 6
                $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-2000).ToString('o')
                Write-VmfStoreJson -RunPath $r -RelPath $rel -Depth 6 -Document $lease
            } @($global:WrpRun, $global:WrpA)
            @((WrpResume).Wave) | Should -Be @('w1')
            $global:WrpStarts.Count | Should -Be 1
        }
        finally {
            WrpCleanup
            Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        }
    }
}

Describe 'WAVE-RESUME-PLANNED-1: the engine names the wave on every line that starts or ends an execution' {
    # The open-start rule reads the wave from the line. An end line that names
    # no wave ends every start before it, so a missing name never restarts a
    # wave - but it would hide the stopped execution of another wave.
    BeforeAll {
        $script:code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        # One call per line: the wave goes straight after the outcome.
        $script:waveLines = @([regex]::Matches($script:code, "Write-VmfStepLine -RunPath \`$RunPath -Step 'wave' -Outcome (start|ok|fail)\b([^\r\n]*)"))
    }
    It 'finds the start line, the ok line and both fail lines' {
        @($script:waveLines | ForEach-Object { $_.Groups[1].Value } | Sort-Object) | Should -Be @('fail', 'fail', 'ok', 'start')
    }
    It 'each one carries the wave as data' {
        foreach ($m in $script:waveLines) {
            $m.Groups[2].Value | Should -Match '^ -Data @\{ wave = \$Wave \}' -Because "the '$($m.Groups[1].Value)' line must name its wave"
        }
    }
}
