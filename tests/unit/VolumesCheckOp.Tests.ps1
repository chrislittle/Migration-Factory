#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VOLUMES-RESTORE-MIGRATED-1 (rule 12: every operator action is reachable from
# the app). Restore this machine on a migrated machine can leave a volume not
# mounted. The machine stays MIGRATED, so Try this machine again - which checks
# the volumes first (VOLUMES-RETRY-CHECK-1) - is not offered. Check the volumes
# on the machine panel starts the engine operation 'checkvolumes' through the
# service's engine route, the shape of 'deletemade': an operator only, one
# machine, one job of the machine at a time, never while a hold stands on it.
# The engine (Invoke-VmfVolumesCheck) runs the check of the retry with no move;
# VolumesRetryCheck.Tests.ps1 holds what it does to the machine and its record.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:vmId = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01"
}

Describe 'VOLUMES-RESTORE-MIGRATED-1: the service starts checkvolumes for one machine, for an operator' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.App/jobs/engine")
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        $global:vckDeleting = $false
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { $global:vckDeleting = $true }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $global:vckBody = $null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:vckBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
        Remove-Item $script:store -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable vckBody, vckDeleting, vckAsked -Scope Global -ErrorAction SilentlyContinue
    }

    It 'starts the engine with the machine and who asked; needs a machine; refuses a viewer and an approver' {
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'checkvolumes' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $envs = @(($global:vckBody | ConvertFrom-Json).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'checkvolumes'
        ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
        ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
        $global:vckDeleting | Should -BeTrue -Because 'nothing starts a machine of a migration that is being deleted'
        $global:vckBody = $null
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'checkvolumes' -RunId 'run-x' } | Should -Throw '400:*machine*'
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver') {
            $who = [pscustomobject]@{ Identity = 'someone@example.com'; Roles = @($role) }
            { Invoke-VmfFacadeStartEngine -Principal $who -Operation 'checkvolumes' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '403*'
        }
        $global:vckBody | Should -BeNullOrEmpty
    }

    It 'is refused while another job of the machine runs, while a hold stands on it, and with the engine''s own refusal' {
        $global:vckAsked = $null
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $global:vckAsked = @($Operation); $VmId -eq $script:vmId }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'checkvolumes' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400: The engine works on this machine now*'
        foreach ($o in 'restore', 'finish', 'deleteearlier', 'deletemade', 'checkvolumes') { @($global:vckAsked) | Should -Contain $o }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { "A wave migrates 'app-01' now." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'checkvolumes' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: A wave migrates 'app-01' now."
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfVolumesCheckRefusal { "The product did not check the volumes of app-01." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'checkvolumes' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400: The product did not check the volumes of app-01.'
        $global:vckBody | Should -BeNullOrEmpty -Because 'no job started'
    }

    It 'a restore of the machine is refused while its check runs' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { @($Operation) -contains 'checkvolumes' }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewPutBackRefusal { $null }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -VmId $script:vmId -Note 'n' -DiskSource 'prepared' } | Should -Throw '400:*'
        $global:vckBody | Should -BeNullOrEmpty
    }
}

Describe 'VOLUMES-RESTORE-MIGRATED-1: the engine and the page' {
    It 'the engine runs checkvolumes through Invoke-VmfVolumesCheck, with the machine and who asked' {
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $block = [regex]::Match($text, "(?s)'checkvolumes' \{.*?Invoke-VmfVolumesCheck @checkParams").Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match 'VMF_VM_ID'
        $block | Should -Match 'VMF_RESTORED_BY'
        $text | Should -Match 'Unknown VMF_OPERATION .*checkvolumes'
    }

    It 'the engine refuses a machine a job works on, and one with a data disk swap left - one copy of the words for the service too' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ state = 'MIGRATED'; volumesCheckOwed = [pscustomobject]@{ reason = 'volumesNotBack'; kind = 'restore'; tsUtc = '2026-11-15T10:00:00Z' } }
            Get-VmfVolumesCheckRefusal -Doc $doc -VmName 'app-01' | Should -BeNullOrEmpty
            foreach ($s in 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED') {
                $doc.state = $s
                Get-VmfVolumesCheckRefusal -Doc $doc -VmName 'app-01' | Should -BeNullOrEmpty -Because "$s is a state no job works on"
            }
            $doc.state = 'STARTING'
            Get-VmfVolumesCheckRefusal -Doc $doc -VmName 'app-01' | Should -Match 'STARTING'
            $doc.state = 'MIGRATED'
            $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'rollback' })
            Get-VmfVolumesCheckRefusal -Doc $doc -VmName 'app-01' | Should -Match 'Finish the rollback'
        }
    }
}

Describe 'VOLUMES-CHECK-JOB-STOP-1: the service starts again a check of the volumes whose job stopped after the start' {
    BeforeEach {
        $script:jsRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vjs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:jsRun; id = $script:vmId } { param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'vjs' -Kind 'migration' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'vjs' -VmId $id -Wave 'w1' | Out-Null
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d.state = 'MIGRATED'
            Set-VmfVolumesCheckOwed -Doc $d -Verdict 'MISSING' -Kind 'restore'
            $d | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{
                    volumesCheckPower = [pscustomobject]@{ power = 'PowerState/deallocated'; status = 'started'; tsUtc = '2026-11-15T10:00:00Z' } })
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
        $global:vjsStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { $global:vjsStarts.Add([pscustomobject]@{ Operation = $Operation; VmId = $VmId; RunId = $RunId; Roles = @($Principal.Roles) }); [pscustomobject]@{ execution = 'exec-9' } }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
    }
    AfterEach {
        Remove-Item $script:jsRun -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable vjsStarts -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeAll {
        function Script:JsDoc { & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:jsRun $script:vmId }
        function Script:JsLines { & (Get-Module VmMigrationFactory) { param($rp) @(Read-VmfEvents -RunPath $rp | Where-Object { [string]$_.step -eq 'resume' }) } $script:jsRun }
    }

    It 'a start on record with no hold and no job: checkvolumes starts again for the machine, and the record says when the service found it stopped' {
        $out = @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs')
        $out.Count | Should -Be 1
        $out[0].Action | Should -Be 'resumed'
        $global:vjsStarts.Count | Should -Be 1
        $global:vjsStarts[0].Operation | Should -Be 'checkvolumes'
        $global:vjsStarts[0].VmId | Should -Be $script:vmId
        $rec = (Script:JsDoc).captured.volumesCheckPower
        [string]$rec.stoppedUtc | Should -Not -BeNullOrEmpty
        [int]$rec.resumes | Should -Be 1
        @(Script:JsLines)[-1].detail | Should -BeExactly "The check of the volumes of 'app-01' started the machine. The check did not finish. The engine started the check again (execution exec-9). The check returns the machine to the power state Stopped (deallocated)."
    }

    It 'a hold, or a job of the machine that runs, is left alone' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { @($Operation) -contains 'checkvolumes' -and $VmId -eq $script:vmId }
        @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs').Count | Should -Be 0
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $true }
        @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs').Count | Should -Be 0
        $global:vjsStarts.Count | Should -Be 0
        [string](Script:JsDoc).captured.volumesCheckPower.stoppedUtc | Should -BeNullOrEmpty
    }

    It 'a machine at a working state (the check before a retry, in its wave) is the wave''s' {
        & (Get-Module VmMigrationFactory) { param($rp, $id) $d = Read-VmfStateDoc -RunPath $rp -VmId $id; $d.state = 'PRECHECK'; Write-VmfStateDoc -RunPath $rp -Document $d } $script:jsRun $script:vmId
        @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs').Count | Should -Be 0
        $global:vjsStarts.Count | Should -Be 0
    }

    It 'at the limit of a restore''s resumes the record is marked gaveUp, one line says so, and nothing starts again' {
        1..3 | ForEach-Object { $null = Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs' }
        $global:vjsStarts.Count | Should -Be 3
        $out = @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs')
        $out[0].Action | Should -Be 'gaveUp'
        $global:vjsStarts.Count | Should -Be 3
        (Script:JsDoc).captured.volumesCheckPower.gaveUp | Should -BeTrue
        @(Script:JsLines | Where-Object { $_.outcome -eq 'fail' })[-1].detail | Should -BeExactly "The check of the volumes of 'app-01' started the machine. The check did not finish. The service started the check again 3 times. The check did not finish. The machine is in the power state Running. Before the check, it was Stopped (deallocated). Select Check the volumes to start the check again."
        @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs').Count | Should -Be 0 -Because 'it is said once'
    }

    It 'Set-VmfVolumesCheckStopped: a record given up before answers none and does not change' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:jsRun; id = $script:vmId } { param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d.captured.volumesCheckPower | Add-Member -NotePropertyName gaveUp -NotePropertyValue $true -Force
            $d.captured.volumesCheckPower | Add-Member -NotePropertyName resumes -NotePropertyValue 3 -Force
            Write-VmfStateDoc -RunPath $rp -Document $d
            Set-VmfVolumesCheckStopped -RunPath $rp -VmId $id | Should -Be 'none'
            $rec = (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.volumesCheckPower
            [int]$rec.resumes | Should -Be 3
            [string]$rec.stoppedUtc | Should -BeNullOrEmpty
        }
    }
    It 'a record the return ended (putBack) is not acted on' {
        & (Get-Module VmMigrationFactory) { param($rp, $id) $d = Read-VmfStateDoc -RunPath $rp -VmId $id; $d.captured.volumesCheckPower.status = 'putBack'; Write-VmfStateDoc -RunPath $rp -Document $d } $script:jsRun $script:vmId
        @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $script:jsRun -RunId 'vjs').Count | Should -Be 0
    }

    It 'the five-minute pass visits the run while the start is on record, and asks the jobs of checkvolumes' {
        $need = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:jsRun } { param($rp) Get-VmfRunScheduleNeed -RunPath $rp }
        $need.Reason | Should -Be 'volumesCheckStarted'
        $runner = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1')
        $runner | Should -Match 'Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath \$store -RunId \$runId -StateDocs \$putBackDocs'
        $global:vjsAsked = $null
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $global:vjsAsked = @($Operation); $false }
        $null = Test-VmfFacadeRunJobRunning -RunId 'vjs'
        @($global:vjsAsked) | Should -Contain 'checkvolumes'
        Remove-Variable vjsAsked -Scope Global -ErrorAction SilentlyContinue
    }
}
