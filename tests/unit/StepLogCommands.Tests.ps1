#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STEP-LOG-4: a run history line that cannot be written, in an operator
# command, never decides what the command did.
#
# STEP-LOG-2 put every line written after a change in the engine and in the
# two restore commands through Write-VmfStepLine. The other exported commands
# still wrote each line with Write-VmfEvent, which throws when the store
# refuses the line. So a command that had saved an approval, a schedule, a
# halt removal or a skip, and then could not write its line, reported the
# change as failed - and did not write the summary the list on the Migrations
# page reads. Each test below makes the one line fail and shows the change is
# made, the command returns its result, and the engine output has a warning
# that names the line. The commands with bigger fixtures are tested beside
# their own tests (each test there is named STEP-LOG-4).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'steplog4'
    $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    $script:Who = @{ Identity = 'approver@example.com'; TenantId = $null }
    # Two waves, as RunSummary.Tests.ps1 builds them.
    $script:NewPlan = {
        [pscustomobject]@{
            schemaVersion = 16; assessmentRunId = 'r1'; waveOrder = @('w1', 'w2')
            entries = @(
                foreach ($pair in @(@('w2', 'a'), @('w2', 'b'), @('w1', 'y'), @('w1', 'z'))) {
                    [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vm)$($pair[1])"; wave = $pair[0]; path = 'A'
                                       policy = [pscustomobject]@{ requireApproval = $true; throttle = 5 } }
                }
            )
        }
    }
    # The warning a lost line gives, read back as one string.
    $script:Said = { param($w) (@($w | ForEach-Object { [string]$_ }) -join "`n") }
}
AfterAll { Remove-VmfTestTemp }

Describe 'STEP-LOG-4: a line that cannot be written, in an operator command' {
    BeforeEach {
        # One folder per test: the claims live beside the run (Get-VmfClaimScopePath).
        $script:rp = Join-Path $script:temp "sl4-$([guid]::NewGuid().ToString('N').Substring(0,8))" 'runs' 'sl4'
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'sl4' | Out-Null }
        (& $script:NewPlan) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json') -Encoding utf8NoBOM
        $script:pp = Join-Path $script:rp 'plan.json'
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
    }

    It 'an assessment approval is saved and returned when its line cannot be written' {
        $a = Join-Path (Split-Path $script:rp) 'scan'
        InModuleScope VmMigrationFactory -Parameters @{ a = $a } { Initialize-VmfRun -RunPath $a -RunId 'scan' -Kind 'assessment' | Out-Null }
        @{ schemaVersion = 17; runId = 'scan'; generatedUtc = '2026-08-31T00:00:00Z'; scope = @{ subscriptions = @() }; summary = @{}; vms = @() } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $a 'assessment.json')
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } { throw 'The store did not answer.' }
        $r = Approve-VmfAssessment -RunPath $a -Note 'reviewed' -OnBehalfOf $script:Who -WarningVariable w -WarningAction SilentlyContinue
        $r.ApprovedBy | Should -Be 'approver@example.com'
        Test-Path (Join-Path $a 'approval.json') | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'approval ok' could not be written*assessment approved by approver@example.com*"
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } -Times 1 -Exactly
    }

    It 'a plan sign-off is saved, and the list is told, when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } { throw 'The store did not answer.' }
        $r = Approve-VmfPlan -RunPath $script:rp -PlanPath $script:pp -Note 'reviewed' -OnBehalfOf $script:Who -WarningVariable w -WarningAction SilentlyContinue
        @($r.Waves) | Should -Be @('w1', 'w2')
        Test-Path (Join-Path $script:rp 'plan-approval.json') | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'approval ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'planSignedOff' } -Times 1 -Exactly
    }

    It 'a wave approval is saved, and the list is told, when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } { throw 'The store did not answer.' }
        $r = Approve-VmfWave -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -Note 'reviewed' -OnBehalfOf $script:Who -WarningVariable w -WarningAction SilentlyContinue
        $r.Wave | Should -Be 'w1'
        Test-Path (Join-Path $script:rp 'approvals' 'w1.json') | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'approval ok' could not be written*wave w1 approved*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'waveApproved' } -Times 1 -Exactly
    }

    It 'the note about machines defined in code is accepted, and the list is told, when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'acknowledgement' } { throw 'The store did not answer.' }
        $r = Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.acknowledgedBy | Should -Be 'operator@example.com'
        Test-Path (Join-Path $script:rp 'acknowledgements' 'infrastructure-as-code.json') | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'acknowledgement ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'acknowledged' } -Times 1 -Exactly
    }

    It 'the settings of a wave are accepted, and the list is told, when the line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'acceptance' } { throw 'The store did not answer.' }
        $r = Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.wave | Should -Be 'w1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Test-VmfStoreItem -RunPath $rp -RelPath (Resolve-VmfWaveOptionsAcceptancePath -Wave 'w1') | Should -BeTrue
        }
        (& $script:Said $w) | Should -BeLike "*'acceptance ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'optionsAccepted' } -Times 1 -Exactly
    }

    It 'a halt is cleared, and the list is told, when its line cannot be written' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Set-VmfWaveHalt -RunPath $rp -Reason 'operator halt' | Out-Null }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' } { throw 'The store did not answer.' }
        $r = Clear-VmfWaveHalt -RunPath $script:rp -Note 'cause corrected' -ClearedBy 'operator@example.com' -WarningVariable w -WarningAction SilentlyContinue
        $r.WasHalted | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Test-VmfWaveHalted -RunPath $rp | Should -BeFalse }
        (& $script:Said $w) | Should -BeLike "*'wave warn' could not be written*HALT CLEARED*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'resumed' } -Times 1 -Exactly
    }

    It 'a wave is scheduled when the line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'schedule' } { throw 'The store did not answer.' }
        $r = Set-VmfWaveSchedule -RunPath $script:rp -Wave 'w1' -RunAtUtc (Get-Date).AddHours(2) -ScheduledBy 'operator@example.com' -Note 'change window' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.state | Should -Be 'pending'
        Test-Path (Join-Path $script:rp 'schedules' 'w1.json') | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'schedule ok' could not be written*"
    }

    It 'a scheduled start is cancelled when the line cannot be written' {
        Set-VmfWaveSchedule -RunPath $script:rp -Wave 'w1' -RunAtUtc (Get-Date).AddHours(2) -ScheduledBy 'operator@example.com' -Note 'change window' -Confirm:$false | Out-Null
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'schedule' } { throw 'The store did not answer.' }
        $r = Remove-VmfWaveSchedule -RunPath $script:rp -Wave 'w1' -CancelledBy 'operator@example.com' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.Cancelled | Should -BeTrue
        Test-Path (Join-Path $script:rp 'schedules' 'w1.json') | Should -BeFalse
        (& $script:Said $w) | Should -BeLike "*'schedule info' could not be written*"
    }

    It 'a machine is left out, its claim released, and the list told, when the line cannot be written' {
        $id = "$($script:vm)z"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $id } { (New-VmfVmClaim -RunPath $rp -VmId $id -RunId 'sl4').Granted | Should -BeTrue }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'skip' } { throw 'The store did not answer.' }
        $r = Skip-VmfVm -RunPath $script:rp -VmId $id -Reason 'not needed' -SkippedBy 'operator@example.com' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.ClaimReleased | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $id } { (Read-VmfStateDoc -RunPath $rp -VmId $id).state | Should -Be 'SKIPPED' }
        (& $script:Said $w) | Should -BeLike "*'skip skip' for $id could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'machineSkipped' } -Times 1 -Exactly
    }

    It 'a stopped run says the line was lost in its result, and still keeps the record and tells the list' {
        Mock -ModuleName VmMigrationFactory Save-VmfRecordAndReport { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'run' } { throw 'The store did not answer.' }
        $r = Stop-VmfRun -RunPath $script:rp -Reason 'done here' -StoppedBy 'operator@example.com' -Force -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.Stopped | Should -BeTrue
        $r.LogWarning | Should -BeLike '*could not be written*The store did not answer.*'
        (& $script:Said $w) | Should -BeLike "*'run ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Save-VmfRecordAndReport -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'runStopped' } -Times 1 -Exactly
    }
}

Describe 'STEP-LOG-4: a line of a scan that cannot be written' {
    BeforeEach {
        $script:out = Join-Path $script:temp "scan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:scanVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        Mock -ModuleName VmMigrationFactory Get-VmfFleetInventory { , @([pscustomobject]@{
            id = $script:scanVm; name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; sku = 'Standard_D4s_v5' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { , @() }
        # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
        Mock -ModuleName VmMigrationFactory Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
        Mock -ModuleName VmMigrationFactory Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfAvdSessionHostIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
        # DETECT-PATTERNS-1: the three workload reads.
        Mock -ModuleName VmMigrationFactory Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareMap { @{ Disks = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
        Mock -ModuleName VmMigrationFactory Get-VmfMachineImageNvme { @{ Nvme = $null; Note = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfAssessmentRecord { [pscustomobject]@{ vmId = $script:scanVm; name = 'vm1'; classification = 'ReadyNow' } }
        $script:Scan = { Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $script:out -RunId 'scan' -WarningVariable w -WarningAction SilentlyContinue; $script:scanWarn = $w }
    }

    It 'the last line, after the assessment is saved: the scan is returned, not reported as failed' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = & $script:Scan
        $r.Total | Should -Be 1
        Test-Path (Join-Path $script:out 'assessment.json') | Should -BeTrue
        (& $script:Said $script:scanWarn) | Should -BeLike "*'assessment ok' could not be written*"
    }

    It 'the count of machines found: the scan goes on and saves the assessment' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        (& $script:Scan).Total | Should -Be 1
        Test-Path (Join-Path $script:out 'assessment.json') | Should -BeTrue
    }

    It 'accelerated networking cannot be read, and its line cannot be written: the assessment says what it could not read' {
        Mock -ModuleName VmMigrationFactory Get-VmfNicFacts { throw 'Resource Graph did not answer.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        (& $script:Scan).Total | Should -Be 1
        $doc = Get-Content (Join-Path $script:out 'assessment.json') -Raw | ConvertFrom-Json -Depth 24
        @($doc.notRead | ForEach-Object subject) | Should -Contain 'acceleratedNetworking'
    }

    It 'a check the scan cannot verify (<Name>): the refusal names the fix, not the store''s error' -ForEach @(
        @{ Name = 'AVD'; Mocked = 'Get-VmfAvdSessionHostIds'; Words = 'Cannot verify which machines are AVD session hosts (HTTP 403)*' }
        @{ Name = 'SAP'; Mocked = 'Get-VmfSapSystemVmIds'; Words = 'Cannot verify which machines belong to SAP systems (HTTP 403)*' }
        @{ Name = 'AKS and Databricks'; Mocked = 'Get-VmfManagedPlatformGroups'; Words = 'Cannot verify which resource groups belong to AKS clusters or Databricks workspaces (HTTP 403)*' }
        @{ Name = 'SQL Server'; Mocked = 'Get-VmfSqlVirtualMachines'; Words = 'Cannot verify which machines run SQL Server (HTTP 403)*' }
        @{ Name = 'shared disks'; Mocked = 'Get-VmfDiskShareMap'; Words = 'Cannot verify which machines use shared disks (HTTP 403)*' }
        @{ Name = 'resource group owners'; Mocked = 'Get-VmfResourceGroupOwners'; Words = 'Cannot verify which resource groups a service or a managed application owns (HTTP 403)*' }
    ) {
        Mock -ModuleName VmMigrationFactory $Mocked { @{ Ids = @{}; Groups = @{}; Disks = @{}; Verified = $false; Detail = 'HTTP 403' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        { & $script:Scan } | Should -Throw $Words
        Test-Path (Join-Path $script:out 'assessment.json') | Should -BeFalse
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'the start line stays a throwing write: before the scan reads anything, a line that cannot be written stops it, and nothing is assessed' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'assessment' -and $Outcome -eq 'start' } { throw 'The store did not answer.' }
        { & $script:Scan } | Should -Throw 'The store did not answer.'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfFleetInventory -Times 0 -Exactly
        Test-Path (Join-Path $script:out 'assessment.json') | Should -BeFalse
    }
}
Describe 'STEP-LOG-4: a line of the report that cannot be written' {
    BeforeEach {
        $script:rp = Join-Path $script:temp "rep-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'rep' | Out-Null }
        (& $script:NewPlan) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json') -Encoding utf8NoBOM
    }

    It 'the last line, after the report is saved: the report is returned' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'report' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $path = New-VmfReport -OutPath $script:rp -WarningVariable w -WarningAction SilentlyContinue
        $path | Should -Be (Join-Path $script:rp 'customer-report.html')
        Test-Path $path | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'report ok' could not be written*"
    }

    It 'the record cannot be built, and that line cannot be written: the report is still written' {
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore { throw 'The record could not be read.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'report' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $path = New-VmfReport -OutPath $script:rp -WarningAction SilentlyContinue
        Test-Path $path | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'report' -and $Outcome -eq 'warn' } -Times 1 -Exactly
    }
}
