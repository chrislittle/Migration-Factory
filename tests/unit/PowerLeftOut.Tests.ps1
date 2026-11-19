#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# POWER-ONLY-CHANGED-1, the second ruling (2026-11-06): a machine the product
# turned on at any phase and then left out or stopped must be turned off
# again. It folds POWER-LEFT-OUT-1.
#
# Leave this machine out (Skip-VmfVm) and Stop this migration (Stop-VmfRun)
# run in the web service, which has no right to change a machine. So:
#   - each records the power state the product changed and did not return
#     (history[].powerNotPutBack, Get-VmfPowerOwed) and says so (PowerOwed);
#   - the service then starts the engine operation 'powerback'
#     (Add-VmfFacadePowerReturn -> Invoke-VmfFacadeStartEngine), and the
#     machine panel offers it again while the power state is owed;
#   - the engine (Restore-VmfMachinePower) returns the machine with the
#     product's tries, writes a line that says untouched, and gives back the
#     claim of a machine left out - or, refused, writes changed again;
#   - a job killed after the return and before its line returns it again.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-left'
    $script:vmId2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-other'

    # A store with one migration that holds the machines, each with the
    # history given, and a claim on each.
    function Script:PlSeed {
        param([hashtable]$Machines)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; m = $Machines } {
            param($rp, $m)
            Initialize-VmfRun -RunPath $rp -RunId 'pl-test' -Kind 'migration' | Out-Null
            $entries = @($m.Keys | ForEach-Object { [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $_; wave = 'w1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus'; classification = 'ReadyNow' }; target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} } })
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = $entries }) -Depth 24
            foreach ($id in $m.Keys) {
                New-VmfStateDoc -RunPath $rp -RunId 'pl-test' -VmId $id -Wave 'w1' | Out-Null
                # Made here, so each step runs in the module, where the store is.
                foreach ($step in @($m[$id])) { & ([scriptblock]::Create([string]$step)) $rp $id }
                $c = New-VmfVmClaim -RunPath $rp -VmId $id -RunId 'pl-test'
                if (-not $c.Granted) { throw "the test could not claim the machine: $($c.Detail)" }
            }
        }
    }
    # The history of a parked machine whose stop could not return its power state.
    $script:owedStop = {
        param($rp, $id)
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 't' | Out-Null
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome ok -ReasonCode 'rollbackDisksBeforeMoveNotMade' `
            -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' -Detail 'the product could not deallocate it again' | Out-Null
    }
    $script:untouchedStop = {
        param($rp, $id)
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 't' | Out-Null
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome fail -ReasonCode 'sizeRetired' -MachineState 'untouched' -Detail 'x' | Out-Null
    }
    $script:changedStop = {
        param($rp, $id)
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 't' | Out-Null
        Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'x' | Out-Null
    }
    function Script:PlDoc([string]$Id = $script:vmId) { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $Id } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Script:PlClaim([string]$Id = $script:vmId) { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $Id } { param($rp, $id) Get-VmfVmClaim -RunPath $rp -VmId $id } }

    # Azure, as a power model: the machine runs; each call that changes the
    # power sets $global:plPower. $global:plFail throws to refuse a call.
    function Script:PlMockAzure {
        $global:plPower = 'PowerState/running'
        $global:plCalls = [System.Collections.Generic.List[string]]::new()
        $global:plFail = { param($name) }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:plPower }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:plFail 'deallocate'; $global:plCalls.Add('deallocate'); $global:plPower = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:plFail 'powerOff'; $global:plCalls.Add('powerOff'); $global:plPower = 'PowerState/stopped' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:plFail 'start'; $global:plCalls.Add('start'); $global:plPower = 'PowerState/running' }
    }
    function Script:PlReturn([string]$Id) {
        $p = @{ RunPath = $script:runPath; By = 'operator@example.com'; Note = 'left out'; Confirm = $false }
        if ($Id) { $p.VmId = $Id }
        @(Restore-VmfMachinePower @p)
    }
}

AfterAll {
    Remove-Variable plPower, plCalls, plFail, plKilled -Scope Global -ErrorAction SilentlyContinue
}

Describe 'POWER-ONLY-CHANGED-1: the engine returns a machine whose power state is owed (powerback)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Script:PlMockAzure
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'Leave this machine out says the power state is owed and keeps the claim; the return writes untouched and gives back the claim' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop) }
        $skip = Skip-VmfVm -RunPath $script:runPath -VmId $script:vmId -Reason 'later' -SkippedBy 'operator@example.com' -Confirm:$false
        $skip.PowerOwed | Should -Be 'PowerState/deallocated'
        $skip.ClaimReleased | Should -BeFalse
        Script:PlClaim | Should -Not -BeNullOrEmpty

        $r = Script:PlReturn $script:vmId
        $r[0].Returned | Should -BeTrue
        $global:plPower | Should -Be 'PowerState/deallocated'
        $last = @((Script:PlDoc).history)[-1]
        $last.state | Should -Be 'SKIPPED'
        $last.machineState | Should -Be 'untouched'
        $last.detail | Should -Match 'The product deallocated the machine again, as it was before the move\. operator@example\.com asked for it'
        Script:PlClaim | Should -BeNullOrEmpty -Because 'the power state is back, so the machine is as it was'
    }

    It 'a return Azure refuses at every try writes changed again, keeps the claim, and is tried the bounded number of times' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop) }
        Skip-VmfVm -RunPath $script:runPath -VmId $script:vmId -Reason 'later' -SkippedBy 'operator@example.com' -Confirm:$false | Out-Null
        $global:plTries = 0
        $global:plFail = { param($name) if ($name -eq 'deallocate') { $global:plTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $r = Script:PlReturn $script:vmId
        $r[0].Returned | Should -BeFalse
        $global:plTries | Should -Be (InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries })
        $last = @((Script:PlDoc).history)[-1]
        $last.machineState | Should -Be 'changed'
        $last.powerNotPutBack | Should -Be 'PowerState/deallocated'
        Script:PlClaim | Should -Not -BeNullOrEmpty
        Remove-Variable plTries -Scope Global -ErrorAction SilentlyContinue
    }

    It 'kill and resume (rule 4): a job stopped after the return, before its line, returns it again and writes one line' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop) }
        Skip-VmfVm -RunPath $script:runPath -VmId $script:vmId -Reason 'later' -SkippedBy 'operator@example.com' -Confirm:$false | Out-Null
        $global:plKilled = $false
        $global:plFail = {
            param($name)
            if ($name -eq 'deallocate' -and -not $global:plKilled) {
                $global:plKilled = $true
                $global:plPower = 'PowerState/deallocated'
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        $lost = Script:PlReturn $script:vmId
        $lost[0].Returned | Should -BeFalse -Because 'another job holds the machine now'
        $lost[0].Detail | Should -Match 'abandon this VM'
        @((Script:PlDoc).history | Where-Object { $_.machineState -eq 'untouched' -and $_.state -eq 'SKIPPED' }) | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Remove-VmfLease -RunPath $rp -VmId $id -Force -ErrorAction SilentlyContinue }

        $r = Script:PlReturn $script:vmId
        $r[0].Returned | Should -BeTrue
        @((Script:PlDoc).history | Where-Object { $_.machineState -eq 'untouched' -and $_.state -eq 'SKIPPED' }) | Should -HaveCount 1
        Script:PlClaim | Should -BeNullOrEmpty
    }

    It 'a lost lease on one machine does not stop the others: the rest are returned, and the one is said' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop); $script:vmId2 = @($script:owedStop) }
        $global:plKilled = $false
        $global:plFail = {
            param($name)
            if ($name -eq 'deallocate' -and -not $global:plKilled) {
                $global:plKilled = $true
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        $r = @(Script:PlReturn)
        @($r) | Should -HaveCount 2
        @($r | Where-Object { -not $_.Returned }) | Should -HaveCount 1
        @($r | Where-Object { $_.Returned }) | Should -HaveCount 1 -Because 'the other machine is returned'
        @($r | Where-Object { -not $_.Returned })[0].Detail | Should -Match 'abandon this VM'
    }

    It 'with no machine named, it returns every machine whose power state is owed, and leaves the others' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop); $script:vmId2 = @($script:untouchedStop) }
        $r = Script:PlReturn
        @($r) | Should -HaveCount 1
        $r[0].VmId | Should -Be $script:vmId
        @((Script:PlDoc $script:vmId2).history)[-1].reasonCode | Should -Be 'sizeRetired'
    }

    It 'with one machine named, only that machine is returned, though another is owed too' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop); $script:vmId2 = @($script:owedStop) }
        $r = Script:PlReturn $script:vmId2
        @($r) | Should -HaveCount 1
        $r[0].VmId | Should -Be $script:vmId2
        @((Script:PlDoc $script:vmId).history)[-1].powerNotPutBack | Should -Be 'PowerState/deallocated' -Because 'the other machine is still owed'
    }

    It 'a machine a job holds now is not changed: it says so' {
        Script:PlSeed @{ $script:vmId = @($script:owedStop) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) New-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null }
        $r = Script:PlReturn $script:vmId
        $r[0].Returned | Should -BeFalse
        $r[0].Detail | Should -Match 'did not return'
        @($global:plCalls) | Should -BeNullOrEmpty
    }

    It 'a machine with nothing owed is not touched' {
        Script:PlSeed @{ $script:vmId = @($script:changedStop) }
        @(Script:PlReturn $script:vmId) | Should -BeNullOrEmpty
        @($global:plCalls) | Should -BeNullOrEmpty
    }
}

Describe 'POWER-ONLY-CHANGED-1: Stop this migration says every machine whose power state is owed' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a parked machine owed its power state, and a machine closed out part way, are both on PowerOwed; a changed one is not' {
        $midway = {
            param($rp, $id)
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 't' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'SAFETY_PRISTINE' -Outcome ok -Detail 't' | Out-Null
        }
        $third = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-changed'
        Script:PlSeed @{ $script:vmId = @($script:owedStop); $script:vmId2 = @($midway); $third = @($script:changedStop) }
        $r = Stop-VmfRun -RunPath $script:runPath -Reason 'closing' -StoppedBy 'operator@example.com' -Force -Confirm:$false
        @($r.PowerOwed | Sort-Object) | Should -Be @(@($script:vmId, $script:vmId2) | Sort-Object)
        @((Script:PlDoc $script:vmId2).history)[-1].powerNotPutBack | Should -Be 'PowerState/running'
    }
}

Describe 'POWER-ONLY-CHANGED-1: a stop whose power state the product returned reads as untouched' {
    It 'Get-VmfSkipMachineState: <Name>' -ForEach @(
        @{ Name = 'owed: changed'; Back = $false; Want = 'changed' }
        @{ Name = 'returned since: untouched'; Back = $true; Want = 'untouched' }
    ) {
        $h = @([pscustomobject]@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'clusterNode'; machineState = 'changed'; powerNotPutBack = 'PowerState/stopped' })
        if ($Back) { $h += [pscustomobject]@{ tsUtc = '2026-11-06T11:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'ok'; machineState = 'untouched' } }
        $doc = [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; history = $h }
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfSkipMachineState -Doc $d }) | Should -Be $Want
    }
    It 'a power state this build does not know stays changed' {
        $doc = [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; history = @(
            [pscustomobject]@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'x'; machineState = 'changed'; powerNotPutBack = 'PowerState/starting' }) }
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfSkipMachineState -Doc $d }) | Should -Be 'changed'
    }
}

Describe 'POWER-ONLY-CHANGED-1: the service starts the return' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }

    It 'after a leave out with a power state owed, it starts powerback for the machine with the note, and says it started' {
        $global:plStarted = $null
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { $global:plStarted = @{ Operation = $Operation; RunId = $RunId; Project = $Project; VmId = $VmId; Note = $Note }; [pscustomobject]@{ started = $true } }
        $res = InModuleScope FacadeCore -Parameters @{ p = $script:op; id = $script:vmId } {
            param($p, $id) Add-VmfFacadePowerReturn -Principal $p -Result ([pscustomobject]@{ VmId = $id; PowerOwed = 'PowerState/deallocated' }) -RunId 'run-1' -Project 'proj' -VmId $id -Note 'later'
        }
        $res.PowerReturn | Should -Be 'started'
        $global:plStarted.Operation | Should -Be 'powerback'
        $global:plStarted.RunId | Should -Be 'run-1'
        $global:plStarted.Project | Should -Be 'proj'
        $global:plStarted.VmId | Should -Be $script:vmId
        $global:plStarted.Note | Should -Be 'later'
        Remove-Variable plStarted -Scope Global -ErrorAction SilentlyContinue
    }

    It 'nothing owed: nothing starts' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'must not start' }
        $res = InModuleScope FacadeCore -Parameters @{ p = $script:op } {
            param($p) Add-VmfFacadePowerReturn -Principal $p -Result ([pscustomobject]@{ VmId = 'x'; PowerOwed = $null }) -RunId 'run-1' -Note 'later'
        }
        $res.PowerReturn | Should -Be ''
    }

    It 'a start that is refused is said, never thrown: the record keeps the power state owed' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw '400: the engine is busy' }
        $res = InModuleScope FacadeCore -Parameters @{ p = $script:op } {
            param($p) Add-VmfFacadePowerReturn -Principal $p -Result ([pscustomobject]@{ PowerOwed = @('a', 'b') }) -RunId 'run-1' -Note 'stop'
        }
        $res.PowerReturn | Should -Be 'not started: the engine is busy'
    }

    It 'the skip and stop functions of the service hand their result to it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Match 'Add-VmfFacadePowerReturn -Principal \$Principal -Result \$result -RunId \$RunId -Project \$Project -VmId'
        $code | Should -Match 'Add-VmfFacadePowerReturn -Principal \$Principal -Result \$result -RunId \$RunId -Project \$Project -Note \$reason'
        foreach ($route in 'PostSkipVm', 'PostStopRun') {
            Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' $route 'run.ps1') | Should -Match 'RunId = \[string\]\$Request\.Params\.runId'
        }
    }

    It 'powerback starts the engine with who asked and why, needs a note, and refuses a held machine' {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-plf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $store)
        try {
            Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
                [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                    name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
            }
            $global:plDeleting = $false
            Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { $global:plDeleting = $true }
            Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
            $global:plBody = $null
            Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:plBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
            Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'powerback' -RunId 'run-x' -Note 'left out' -VmId $script:vmId | Out-Null
            $envs = @(($global:plBody | ConvertFrom-Json).containers[0].env)
            ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'powerback'
            ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
            ($envs | Where-Object name -EQ 'VMF_NOTE').value | Should -Be 'left out'
            ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
            $global:plDeleting | Should -BeTrue -Because 'nothing changes a machine of a migration being deleted'
            { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'powerback' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400:*note*'
            $viewer = [pscustomobject]@{ Identity = 'viewer@example.com'; Roles = @('Vmf.Viewer') }
            { Invoke-VmfFacadeStartEngine -Principal $viewer -Operation 'powerback' -RunId 'run-x' -Note 'n' -VmId $script:vmId } | Should -Throw '403*'
            Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { 'A wave works on vm-left now.' }
            { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'powerback' -RunId 'run-x' -Note 'n' -VmId $script:vmId } | Should -Throw '400: A wave works on vm-left now.'
        }
        finally {
            [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
            [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
            Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable plBody, plDeleting -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'the engine runs the operation powerback through Restore-VmfMachinePower, for one machine or for every one' {
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $text | Should -Match "'powerback' \{"
        $text | Should -Match 'Restore-VmfMachinePower @powerParams'
        $text | Should -Match 'if \(\$env:VMF_VM_ID\) \{ \$powerParams\.VmId = \$env:VMF_VM_ID \}'
    }
}
