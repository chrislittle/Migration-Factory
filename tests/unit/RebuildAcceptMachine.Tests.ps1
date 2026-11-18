#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-ACCEPT-MACHINE-1: Accept this for one machine must let the machine
# go on, while its wave still runs.
#
# THE DEFECT, measured in the lab on 2026-11-04 (REBUILD-ACCEPT-LAB-1, step 3):
# a Windows machine of a running wave stopped at Checking for an extension
# added after the wave was accepted (BGInfo). An approver accepted the rebuild
# for that machine, and the dialog listed BGInfo. The decision was saved with
# BGInfo in it. 31 seconds later Checking stopped the machine AGAIN, for BGInfo.
#
# THE CAUSE is not the comparison of the extensions: the gate passes on the
# entry the decision wrote (the first Describe proves it). It is the worker.
# A worker runs every machine from the plan it read when its wave started
# (WAVE-MIX-2). It was still alive, waiting for another machine of the wave
# (30 seconds), and it took the machine again with ITS copy of the entry - one
# with no decision. Test-VmfLeasedEntryCurrent compared the path, the target
# and the policy only, and a rebuild acceptance changes none of them: it is a
# decision record, never a setting.
#
# Now a leased entry whose settings or decisions changed is run as the plan
# says NOW when the wave, as stored now, passes its start gates (the gates the
# decision itself asked before it put the machine back to Checking) - else it
# is left untouched, as before.
#
# REBUILD-REMOVE-ACCEPT-1: the acceptance of a rebuild is gone (no move
# rebuilds a machine), so the decision here is the one a running wave still
# gets: Continue when files are found on the temporary disk, for one machine.
# The worker rule is the same for any decision; the tests of the rebuild
# gate's words went with the gate.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'ram'
    $script:workerScript = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    $script:one = "$($script:sub)app-01"
    $script:two = "$($script:sub)app-02"
    $script:asr = [pscustomobject]@{ name = 'SiteRecovery-Windows'; publisher = 'Microsoft.Azure.RecoveryServices.SiteRecovery'; type = 'Windows'; provisioningState = 'Succeeded' }
    $script:bgi = [pscustomobject]@{ name = 'BGInfo'; publisher = 'Microsoft.Compute'; type = 'BGInfo'; provisioningState = 'Succeeded' }
    $script:ext = [pscustomobject]@{ name = 'CustomScriptExtension'; publisher = 'Microsoft.Compute'; type = 'CustomScriptExtension'; provisioningState = 'Succeeded' }

    # A run with two machines in wave w1, accepted and approved. Checking
    # stopped app-02 for files on its temporary disk.
    function Global:RamRun([string]$Reason = 'dataOnTempDrive', [string]$State = 'NEEDS_DECISION') {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'ram' | Out-Null }
        $mk = { param($id) @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'prod'; path = 'A'; target = @{ size = 'Standard_D2ds_v6' }
                assessment = @{ identityType = 'None' }
                policy = @{ requireApproval = $true; onDDataFound = 'stop' } } }
        @{ schemaVersion = 1; assessmentRunId = 'ram'; entries = @((& $mk $script:one), (& $mk $script:two)) } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json')
        Open-VmfTestWaveGate -RunPath $rp -PlanPath (Join-Path $rp 'plan.json')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two; x = @($script:asr, $script:bgi); why = $Reason; st = $State } {
            param($rp, $id, $x, $why, $st)
            New-VmfStateDoc -RunPath $rp -RunId 'ram' -VmId $id -Wave 'w1' | Out-Null
            Save-VmfCapturedFacts -Context @{ RunPath = $rp; VmId = $id } -Facts @{ vmConfig = [pscustomobject]@{ name = 'app-02'; identity = $null }; extensions = @($x) }
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok -ReasonCode $why `
                -Detail 'Files were found on the temporary disk.' | Out-Null
        }
        $rp
    }
    function Global:RamResolve([string]$RunPath, [string]$Note = 'The files on the temporary disk are not needed') {
        Resolve-VmfDecision -RunPath $RunPath -PlanPath (Join-Path $RunPath 'plan.json') -VmId $script:two -Note $Note `
            -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') -PolicyOverride @{ onDDataFound = 'proceed' }
    }
    function Global:RamStored([string]$RunPath, [string]$VmId = $script:two) {
        @((Get-Content (Join-Path $RunPath 'plan.json') -Raw | ConvertFrom-Json -Depth 24).entries | Where-Object { $_.vmId -eq $VmId })[0]
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\RamRun', 'function:\RamResolve', 'function:\RamStored' -ErrorAction SilentlyContinue
}

Describe 'REBUILD-ACCEPT-MACHINE-1: a worker of the running wave takes the machine with the decision, not with its old copy' {
    It 'THE DEFECT: the decision is made while the worker runs another machine; the worker then gives Checking the entry with the decision' {
        $rp = RamRun
        # The fake engine. For app-01 it does what a person does while app-01
        # runs: decide Continue for the files on the temporary disk of app-02.
        # For app-02 it records the entry the worker gave.
        $fake = Join-Path $rp 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
& (Get-Module VmMigrationFactory) { param($e, $rp, $rid)
    $name = ($e.vmId -split '/')[-1]
    if ($name -eq 'app-01') {
        $two = $e.vmId -replace 'app-01$', 'app-02'
        Resolve-VmfDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -VmId $two -Note 'The files on the temporary disk are not needed' `
            -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') -PolicyOverride @{ onDDataFound = 'proceed' } | Out-Null
        New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $e.vmId -Wave 'w1' | Out-Null
    }
    else {
        [ordered]@{ decisions = @(if ($e.PSObject.Properties['decisions']) { @($e.decisions) }); onDDataFound = [string](Get-VmfPolicy -PlanEntry $e -Name 'onDDataFound') } |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'seen-app-02.json')
    }
    Add-VmfStateTransition -RunPath $rp -VmId $e.vmId -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry $RunPath $RunId
'@ | Set-Content $fake
        $env:VMF_TEST_ENGINE = $fake
        try {
            & pwsh -NoProfile -File $script:workerScript -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -RunId 'ram' `
                -WorkerId 'worker-t1' -IdleWaitSeconds 1 *> $null
        }
        finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }
        $seenFile = Join-Path $rp 'seen-app-02.json'
        Test-Path $seenFile | Should -BeTrue -Because 'the worker took app-02 again after the decision put it back to Checking'
        $seen = Get-Content $seenFile -Raw | ConvertFrom-Json -Depth 8
        @($seen.decisions | Where-Object { $_.setting -eq 'onDDataFound' }).Count | Should -Be 1 -Because 'the worker must run the entry the decision wrote, not the copy it read at the start'
        $seen.onDDataFound | Should -Be 'proceed' -Because 'Checking reads the setting the decision gave this machine'
        $line = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) @(Read-VmfEvents -RunPath $rp -Step 'worker' | Where-Object { $_.vmId -eq $id -and $_.outcome -eq 'info' -and $_.detail -match 'decision' }) })
        $line.Count | Should -Be 1 -Because 'the worker says that it uses the plan as it is now'
        $line[0].detail | Should -Be 'A decision changed this machine after wave w1 started. The wave is still accepted and approved, so worker-t1 uses the plan as it is now.'
    }
}

Describe 'REBUILD-ACCEPT-MACHINE-1: Test-VmfLeasedEntryCurrent sees a decision, and asks the start gates of the wave as stored now' {
    It 'a decision with the wave still accepted and approved: current, with the stored entry' {
        $rp = RamRun
        $held = RamStored $rp
        RamResolve $rp | Out-Null
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $held } { param($rp, $e) Test-VmfLeasedEntryCurrent -PlanPath (Join-Path $rp 'plan.json') -Entry $e -RunPath $rp }
        $r.Current | Should -BeTrue
        $r.Changed | Should -BeTrue
        @($r.Entry.decisions | Where-Object setting -EQ 'onDDataFound').Count | Should -Be 1
    }

    It 'the same entry: current, not changed, with the held entry' {
        $rp = RamRun
        $held = RamStored $rp
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $held } { param($rp, $e) Test-VmfLeasedEntryCurrent -PlanPath (Join-Path $rp 'plan.json') -Entry $e -RunPath $rp }
        $r.Current | Should -BeTrue
        $r.Changed | Should -BeFalse
        [object]::ReferenceEquals($r.Entry, $held) | Should -BeTrue
    }

    It 'a decision when the wave as stored now fails a start gate: left untouched' {
        $rp = RamRun
        $held = RamStored $rp
        RamResolve $rp | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Remove-Item (Join-Path $rp 'acknowledgements' 'infrastructure-as-code.json') -Force }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $held } { param($rp, $e) Test-VmfLeasedEntryCurrent -PlanPath (Join-Path $rp 'plan.json') -Entry $e -RunPath $rp }
        $r.Current | Should -BeFalse
        $r.Reason | Should -Match 'its target or its settings changed'
    }

    It 'a decision with no run path given: left untouched, as before' {
        $rp = RamRun
        $held = RamStored $rp
        RamResolve $rp | Out-Null
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $held } { param($rp, $e) Test-VmfLeasedEntryCurrent -PlanPath (Join-Path $rp 'plan.json') -Entry $e }
        $r.Current | Should -BeFalse
    }

    It 'a new target or another wave is never run on the stored entry, even with the gates open' {
        foreach ($change in @({ param($x) $x.target.size = 'Standard_D2ds_v5' }, { param($x) $x.path = 'MANUAL' }, { param($x) $x.wave = 'w2' })) {
            $rp = RamRun
            $held = RamStored $rp
            $plan = Get-Content (Join-Path $rp 'plan.json') -Raw | ConvertFrom-Json -Depth 24
            & $change @($plan.entries | Where-Object { $_.vmId -eq $script:two })[0]
            $plan | ConvertTo-Json -Depth 24 | Set-Content (Join-Path $rp 'plan.json')
            Open-VmfTestWaveGate -RunPath $rp -PlanPath (Join-Path $rp 'plan.json')
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $held } { param($rp, $e) Test-VmfLeasedEntryCurrent -PlanPath (Join-Path $rp 'plan.json') -Entry $e -RunPath $rp }
            $r.Current | Should -BeFalse
        }
    }

    It 'the worker passes the run path and runs the entry the check returns' {
        $code = Get-VmfCodeOnly -Path $script:workerScript
        $code | Should -Match 'Test-VmfLeasedEntryCurrent -PlanPath \$file -Entry \$e -RunPath \$rp'
        $code | Should -Match '\$entry = \$fresh\.Entry'
        $code.IndexOf('$entry = $fresh.Entry') | Should -BeLessThan $code.IndexOf('Invoke-VmfStateMachine')
    }
}

Describe 'REBUILD-ACCEPT-MACHINE-1: the words of a decision for one machine' {
    It 'the history line of the decision has one full stop after the note, and product words' {
        $rp = RamRun
        RamResolve $rp -Note 'The files on the temporary disk are not needed.' | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $detail = [string]@($doc.history)[-1].detail
        $detail | Should -Be ('Decision resolved by approver@example.com: The files on the temporary disk are not needed. ' +
            'The setting onDDataFound of this machine is now proceed. The machine returns to Checking.')
    }
    It 'a note with no full stop gets one, and the line has no engine words' {
        $rp = RamRun
        RamResolve $rp -Note 'no note stop' | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $detail = [string]@($doc.history)[-1].detail
        $detail | Should -Not -Match '\.\.'
        $detail | Should -Not -Match 'Re-armed|policy:'
        $detail | Should -Match '^Decision resolved by approver@example\.com: no note stop\. '
    }

    It 'a retry with no change says only the note and where the machine goes back to' {
        $rp = RamRun
        Resolve-VmfDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -VmId $script:two -Note 'BGInfo is removed' -ResolvedBy 'operator@example.com' | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        [string]@($doc.history)[-1].detail | Should -Be 'Decision resolved by operator@example.com: BGInfo is removed. The machine returns to Checking.'
    }

    It 'a retry of the final checks says the machine goes back to Verifying' {
        $rp = RamRun -Reason 'validationFailed' -State 'FAILED_NEEDS_ATTENTION'
        Resolve-VmfDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -VmId $script:two -Note 'The check is fixed' -ResolvedBy 'operator@example.com' -ReturnTo VALIDATING | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        [string]@($doc.history)[-1].detail | Should -Be 'Decision resolved by operator@example.com: The check is fixed. The machine returns to Verifying.'
    }

    It 'a decision of a setting names the setting and its value' {
        $rp = RamRun
        Resolve-VmfDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -VmId $script:two -Note 'The files on D are temporary' `
            -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') -PolicyOverride @{ onDDataFound = 'proceed' } | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:two } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        [string]@($doc.history)[-1].detail | Should -Be ('Decision resolved by approver@example.com: The files on D are temporary. ' +
            'The setting onDDataFound of this machine is now proceed. The machine returns to Checking.')
    }
}
