#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CLAIM-KEPT-AFTER-WAVE-1. Start-VmfWave gave back the claim (RUN-CLAIM-1) of
# each MIGRATED or SKIPPED machine only AFTER its watch loop ended. An
# execution that stopped after the last machine settled and before that pass
# (the container killed, or the loop threw) left every machine of the wave
# claimed. The service starts a wave again only while a machine is not
# settled, so nothing started, and another migration was refused the machine
# until a person stopped or deleted the run (FreeMachineGone.Tests.ps1).
#
# Now the WORKER gives the claim back where the machine settles, after the
# state machine checkpointed the final state (Remove-VmfSettledVmClaim). The
# end-of-wave pass stays, as a second pass that is safe to run again.
#
# The rules held here:
#   - a machine that is MIGRATED or SKIPPED is released, on both backends;
#   - a machine in any other state keeps its claim - a live worker's machine
#     mid-move, and a rolled-back machine this run still recovers
#     (FREE-MACHINE-GONE-1 keeps FAILED_ROLLED_BACK held on purpose);
#   - another run's claim is never removed;
#   - a second release is safe;
#   - a real worker process whose execution stops before the end of the wave
#     leaves no claim on the machine it migrated.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # Az is not installed in CI, so there is a stand-in to mock; defined before
    # the guard, which blocks it too (TEST-AZURE-GUARD-1).
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'claimkept'
    $script:workerPath = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'))

    # Upper case letters, so the claim also has its older name (VMID-CASE-1)
    # and the release must take both.
    $global:CkVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-Ck/providers/Microsoft.Compute/virtualMachines/Ck01'

    # A store in memory that answers as blob storage does: an ETag per text,
    # If-None-Match: * for a create, If-Match on a write and on a delete.
    function Global:Install-CkBlobService {
        $global:CkBlobs = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:CkTags = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $global:CkSerial = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:CkBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            if ($query -match 'restype=container') { return @{ StatusCode = 201; Content = ''; Headers = @{} } }
            switch ($Method) {
                'PUT' {
                    $there = $global:CkBlobs.ContainsKey($path)
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:CkTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:CkBlobs[$path] = [string]$Body
                    $global:CkTags[$path] = '"t' + (++$global:CkSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:CkTags[$path] } }
                }
                'DELETE' {
                    if (-not $global:CkBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    if ($h['If-Match'] -and $global:CkTags[$path] -ne $h['If-Match']) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:CkBlobs.Remove($path)
                    return @{ StatusCode = 202; Content = ''; Headers = @{} }
                }
                'HEAD' { return @{ StatusCode = $(if ($global:CkBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:CkBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    return @{ StatusCode = 200; Content = $global:CkBlobs[$path]; Headers = @{ ETag = $global:CkTags[$path] } }
                }
            }
        }
    }

    function Global:CkModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store per test, with two live runs.
    function Global:CkNewStore([string]$Backend) {
        $global:CkBackend = $Backend
        $global:CkRoot = if ($Backend -eq 'file') { Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
                         else { 'azblob://acct/cont' }
        if ($Backend -eq 'file') { [System.IO.Directory]::CreateDirectory($global:CkRoot) | Out-Null }
        foreach ($id in 'run-a', 'run-b') {
            CkModule { param($r, $i) Initialize-VmfRun -RunPath $r -RunId $i | Out-Null } @((CkRun $id), $id)
        }
    }
    function Global:CkRun([string]$Id) {
        if ($global:CkBackend -eq 'file') { return (Join-Path $global:CkRoot $Id) }
        "$global:CkRoot/$Id"
    }
    # Every claim name of the machine, as stored, read past every mock.
    function Global:CkClaimNames {
        $names = @(CkModule { param($v) Get-VmfClaimRelPath -VmId $v; Get-VmfClaimLegacyRelPath -VmId $v } @($global:CkVm)) | Where-Object { $_ }
        foreach ($n in $names) {
            if ($global:CkBackend -eq 'azblob') {
                if ($global:CkBlobs.ContainsKey('cont/vmf-claims/' + $n)) { $n }
            }
            elseif ([System.IO.File]::Exists((Join-Path $global:CkRoot 'vmf-claims' $n))) { $n }
        }
    }
    function Global:CkHolder {
        $c = CkModule { param($r, $v) Get-VmfVmClaim -RunPath $r -VmId $v } @((CkRun 'run-a'), $global:CkVm)
        if ($c) { [string]$c.runId } else { '' }
    }
    function Global:CkClaim([string]$RunId, [switch]$Force) {
        CkModule { param($r, $v, $i, $f) New-VmfVmClaim -RunPath $r -VmId $v -RunId $i -Force:$f -TakenBy 'operator@example.com' } @((CkRun $RunId), $global:CkVm, $RunId, [bool]$Force)
    }
    function Global:CkSetState([string]$RunId, [string]$State) {
        CkModule { param($r, $i, $v, $s)
            New-VmfStateDoc -RunPath $r -RunId $i -VmId $v -Wave 'w1' | Out-Null
            if ($s -ne 'PLANNED') { Add-VmfStateTransition -RunPath $r -VmId $v -NewState $s -Outcome ok -Detail 'test' | Out-Null }
        } @((CkRun $RunId), $RunId, $global:CkVm, $State)
    }
    function Global:CkSettle([string]$RunId) {
        CkModule { param($r, $v) Remove-VmfSettledVmClaim -RunPath $r -VmId $v } @((CkRun $RunId), $global:CkVm)
    }
    function Global:CkCleanup {
        if ($global:CkBackend -eq 'file' -and $global:CkRoot -and (Test-Path $global:CkRoot)) { Remove-Item $global:CkRoot -Recurse -Force }
    }
}

AfterAll {
    Remove-Item 'function:\Install-CkBlobService', 'function:\CkModule', 'function:\CkNewStore', 'function:\CkRun', 'function:\CkClaimNames',
        'function:\CkHolder', 'function:\CkClaim', 'function:\CkSetState', 'function:\CkSettle', 'function:\CkCleanup',
        'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
    Remove-Variable CkVm, CkBlobs, CkTags, CkSerial, CkBackend, CkRoot -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp   # TEMP-LITTER-1; throws if anything survives
}

Describe 'CLAIM-KEPT-AFTER-WAVE-1: the claim goes back where the machine settles (<backend>)' -ForEach @(
    @{ backend = 'file' }, @{ backend = 'azblob' }
) {
    BeforeEach {
        Install-CkBlobService
        CkNewStore $backend
        (CkClaim 'run-a').Granted | Should -BeTrue
        @(CkClaimNames).Count | Should -Be 2 -Because 'the claim is held under both of its names before the release'
    }
    AfterEach { CkCleanup }

    It 'a machine that is <state> gives its claim back, under both names, and another migration can take it' -ForEach @(
        @{ state = 'MIGRATED' }, @{ state = 'SKIPPED' }
    ) {
        CkSetState 'run-a' $state
        (CkSettle 'run-a').Released | Should -BeTrue
        @(CkClaimNames).Count | Should -Be 0
        (CkClaim 'run-b').Granted | Should -BeTrue
    }

    It 'a machine in <state> keeps its claim: nothing is released for a machine that is not settled' -ForEach @(
        @{ state = 'PLANNED' }, @{ state = 'PRECHECK' }, @{ state = 'CONVERTING' }, @{ state = 'VALIDATING' },
        @{ state = 'FAILED_ROLLED_BACK' }, @{ state = 'FAILED_NEEDS_ATTENTION' }, @{ state = 'NEEDS_DECISION' }
    ) {
        CkSetState 'run-a' $state
        CkSettle 'run-a' | Should -BeNullOrEmpty
        @(CkClaimNames).Count | Should -Be 2
        CkHolder | Should -Be 'run-a'
        (CkClaim 'run-b').Granted | Should -BeFalse
    }

    It 'a machine with no state document keeps its claim' {
        CkSettle 'run-a' | Should -BeNullOrEmpty
        CkHolder | Should -Be 'run-a'
    }

    It 'a second release is safe: it says there is no claim, and changes nothing' {
        CkSetState 'run-a' 'MIGRATED'
        (CkSettle 'run-a').Released | Should -BeTrue
        $again = CkSettle 'run-a'
        $again.Released | Should -BeTrue
        $again.Detail | Should -Be 'no claim to release'
        @(CkClaimNames).Count | Should -Be 0
    }

    It 'the end-of-wave pass after the release never removes the claim another migration took in between' {
        CkSetState 'run-a' 'MIGRATED'
        (CkSettle 'run-a').Released | Should -BeTrue
        (CkClaim 'run-b').Granted | Should -BeTrue
        (CkSettle 'run-a').Released | Should -BeFalse
        CkHolder | Should -Be 'run-b'
    }

    It 'the claim is released under the id in run.json, the id it was taken under, not the folder name' {
        $folder = if ($global:CkBackend -eq 'file') { Join-Path $global:CkRoot 'folder-c' } else { "$global:CkRoot/folder-c" }
        CkModule { param($r) Initialize-VmfRun -RunPath $r -RunId 'run-c' | Out-Null } @($folder)
        CkModule { param($r, $v) Remove-VmfVmClaim -RunPath $r -VmId $v -RunId 'run-a' | Out-Null } @((CkRun 'run-a'), $global:CkVm)
        (CkModule { param($r, $v) New-VmfVmClaim -RunPath $r -VmId $v -RunId 'run-c' } @($folder, $global:CkVm)).Granted | Should -BeTrue
        CkModule { param($r, $v) New-VmfStateDoc -RunPath $r -RunId 'run-c' -VmId $v -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'MIGRATED' -Outcome ok -Detail 'test' | Out-Null } @($folder, $global:CkVm)
        (CkModule { param($r, $v) Remove-VmfSettledVmClaim -RunPath $r -VmId $v } @($folder, $global:CkVm)).Released | Should -BeTrue
        @(CkClaimNames).Count | Should -Be 0
    }

    It 'a run whose run.json cannot be read releases nothing, and does not throw' {
        $folder = if ($global:CkBackend -eq 'file') { Join-Path $global:CkRoot 'run-gone' } else { "$global:CkRoot/run-gone" }
        CkModule { param($r, $v) New-VmfStateDoc -RunPath $r -RunId 'run-gone' -VmId $v -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'MIGRATED' -Outcome ok -Detail 'test' | Out-Null } @($folder, $global:CkVm)
        $r = CkModule { param($r, $v) Remove-VmfSettledVmClaim -RunPath $r -VmId $v } @($folder, $global:CkVm)
        $r.Released | Should -BeFalse
        CkHolder | Should -Be 'run-a'
    }

    It 'a claim another migration took with -Force is never removed by this run''s release' {
        (CkClaim 'run-b' -Force).Granted | Should -BeTrue
        CkSetState 'run-a' 'MIGRATED'
        (CkSettle 'run-a').Released | Should -BeFalse
        CkHolder | Should -Be 'run-b'
    }
}

Describe 'CLAIM-KEPT-AFTER-WAVE-1: a real worker whose execution stops before the end of the wave' {
    BeforeEach {
        $script:storeRoot = Join-Path $script:temp "w-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runPath = Join-Path $script:storeRoot 'run-w'
        CkModule { param($r) Initialize-VmfRun -RunPath $r -RunId 'run-w' | Out-Null } @($script:runPath)
        $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ck/providers/Microsoft.Compute/virtualMachines/ckw1'
        $plan = [pscustomobject]@{
            schemaVersion = 1
            entries = @([pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; ring = 'lab'; appGroup = 'ckw1'
                assessment = [pscustomobject]@{ classification = 'ReadyNow'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'; policy = [pscustomobject]@{ requireApproval = $false }
            })
        }
        $script:planPath = Join-Path $script:runPath 'plan.json'
        $plan | ConvertTo-Json -Depth 24 | Set-Content $script:planPath
        # The worker is started on its own: no Start-VmfWave, so its
        # end-of-wave pass never runs - the execution stopped after the machine
        # settled. Whatever releases the claim here is the worker.
        function script:Invoke-CkWorker([string]$EndState) {
            $engine = Join-Path $script:storeRoot 'fake-engine.ps1'
            @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
& (Get-Module VmMigrationFactory) {
    param($id, $rp, $rid, $s)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $s -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId $env:CK_END_STATE
'@ | Set-Content $engine
            $env:VMF_TEST_ENGINE = $engine
            $env:CK_END_STATE = $EndState
            try {
                $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-File', $script:workerPath, '-RunPath', $script:runPath, '-PlanPath', $script:planPath,
                    '-Wave', 'w1', '-RunId', 'run-w', '-WorkerId', 'ck-w1', '-IdleWaitSeconds', '1')
                $proc.WaitForExit(90000) | Should -BeTrue -Because 'the worker drains its one machine and exits'
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE, Env:\CK_END_STATE -ErrorAction SilentlyContinue }
        }
        function script:Get-CkWorkerClaim {
            CkModule { param($r, $v) Get-VmfVmClaim -RunPath $r -VmId $v } @($script:runPath, $script:vm)
        }
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'a machine the worker MIGRATED has no claim, with no end-of-wave pass, and another migration can take it' {
        Invoke-CkWorker 'MIGRATED'
        (CkModule { param($r, $v) Read-VmfStateDoc -RunPath $r -VmId $v } @($script:runPath, $script:vm)).state | Should -Be 'MIGRATED'
        Get-CkWorkerClaim | Should -BeNullOrEmpty
        $other = Join-Path $script:storeRoot 'run-x'
        CkModule { param($r) Initialize-VmfRun -RunPath $r -RunId 'run-x' | Out-Null } @($other)
        (CkModule { param($r, $v) New-VmfVmClaim -RunPath $r -VmId $v -RunId 'run-x' } @($other, $script:vm)).Granted | Should -BeTrue
    }

    It 'a machine the worker left FAILED_ROLLED_BACK keeps its claim: this run still recovers it' {
        Invoke-CkWorker 'FAILED_ROLLED_BACK'
        (Get-CkWorkerClaim).runId | Should -Be 'run-w'
    }
}

Describe 'CLAIM-KEPT-AFTER-WAVE-1: one rule for both releases' {
    It 'the worker releases a settled machine''s claim after the state machine, in its finally, after the lease' {
        $code = Get-VmfCodeOnly -Path $script:workerPath
        $code | Should -Match 'Remove-VmfSettledVmClaim'
        $finallyAt = $code.LastIndexOf('finally {')
        $finallyAt | Should -BeGreaterThan $code.IndexOf('Invoke-VmfStateMachine')
        $code.IndexOf('Remove-VmfSettledVmClaim') | Should -BeGreaterThan $code.IndexOf('Remove-VmfLease -RunPath $rp -VmId $id')
    }

    It 'the end-of-wave pass of Start-VmfWave uses the same rule' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match 'Remove-VmfSettledVmClaim'
        $code | Should -Not -Match 'Remove-VmfVmClaim'
    }

    It 'the rule asks the states that mean a machine wants nothing further, never its own list' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'VmClaims.ps1')
        $code | Should -Match 'VmfSettledStates'
    }
}
