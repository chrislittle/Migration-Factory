#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ACTIVITY-LINES-1 (1.0): a step that recovered showed as two red "Open the
# machine to see why this step failed" lines, one with no cause, and the
# activity showed other lines twice.
#
# MEASURED on the lab install, 2026-11-04 (machine names are the lab's test
# machines):
#   - the stop step of l26-w1 failed on attempt 1 with a connection reset, ran
#     again and went on. The Activity showed two red lines: the Azure call's
#     ("104 - An error occurred while sending the request. -> ... Connection
#     reset by peer") and the step's ("An error occurred while sending the
#     request." - no cause, because the step read only the outer message).
#   - "accepted the rebuild of this machine in the settings of the wave" was
#     written twice: Checking said it, stopped for the identity, and said it
#     again when it ran after the decision.
#   - the swap events of a 409 ConflictingUserInput carried "statusCode": null.
#
# Now: an attempt that is tried again writes a retry line, never a fail line,
# and red is only for the attempt that ends the step; every step line has the
# cause (Resolve-VmfOperationError); an acceptance is said once for each
# machine; and an Azure call's line carries the status code Azure sent, also
# when it is only in Azure's words. tests/js/activity-lines.test.js holds the
# Activity list to the same lines.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Update-AzVM { param($ResourceGroupName, $VM) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'acl'

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
    # The shape of the lab's error: .NET's outer sentence, the cause inside.
    # The inner words are on no list of temporary errors, so the Azure call
    # does not try it again and the step does.
    $script:outer = 'An error occurred while sending the request.'
    $script:inner = 'The response ended prematurely.'

    function Global:AclPlan([string]$Path = 'A') {
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = $Path; policy = [pscustomobject]@{}
            decisions = @(if ($Path -eq 'B') { [pscustomobject]@{ setting = 'rebuild'; by = 'approver@example.com'; utc = '2026-11-01T00:00:00Z'; extensions = @() } })
        }
    }
    function Global:AclFakeVm {
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }
    function Global:AclStep {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            if (-not $d) { throw 'AclStep found no state document for vm-under-test.' }
            [string]$d.state
        }
    }
    function Global:AclRun {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = (AclPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'acl'
        }
    }
    function Global:AclEvents([string]$RunPath = $script:runPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
    # PERF-TELEMETRY-ENGINE-1: one run store call as the blob seam counts it
    # (the file store these tests use counts none), with a signed address.
    function Global:AclStoreCall([string]$Step) {
        $script:storeCalls[$Step] = 1 + [int]$script:storeCalls[$Step]
        & (Get-Module VmMigrationFactory) {
            param($s) Add-VmfCallTiming -Kind store -Method GET -Status 200 -DurationMs 1500 `
                -Target "https://acct.blob.core.windows.net/vmf-runs/p1/acl/state/$s.json?sv=2024-01-01&sig=SECRETSIGNATURE"
        } $Step
    }
    # The lines that close an attempt of a step: they carry its time. A check
    # inside Verifying writes its own ok line, with no time.
    function Global:AclStepLines([string]$Step) {
        @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.step -eq $Step -and $_.outcome -in @('ok', 'retry', 'fail') -and
            $null -ne $_.PSObject.Properties['durationSec'] })
    }
    function Global:AclNetError {
        [System.Net.Http.HttpRequestException]::new($script:outer, [System.IO.IOException]::new($script:inner))
    }

    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Update-AzVM', 'function:\Get-AzNetworkInterface', 'function:\AclPlan', 'function:\AclFakeVm',
        'function:\AclStep', 'function:\AclRun', 'function:\AclEvents', 'function:\AclNetError', 'function:\AclStoreCall', 'function:\AclStepLines' -ErrorAction SilentlyContinue
}

Describe 'ACTIVITY-LINES-1: a step attempt that is tried again' {
    BeforeEach {
        $script:runPath = Join-Path $script:temp "acl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'acl' | Out-Null }
        $script:prepFailsLeft = 0
        $script:validateFailsLeft = 0
        # PERF-TELEMETRY-ENGINE-1: when a test sets this table, each guest
        # script call also makes one run store call, counted by its step.
        $script:storeCalls = $null
        $script:storeAtThrow = $null
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-AzVM { AclFakeVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm1-osdisk-asitwas' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $step = AclStep
            if ($script:storeCalls) { AclStoreCall $step }
            if ($ScriptName -eq 'imds-check.sh') {
                $size = if ($step -in @('CONVERTING', 'STARTING', 'VALIDATING')) { 'Standard_D2s_v6' } else { 'Standard_D2s_v4' }
                return [pscustomobject]@{ schema = 'vmf.guest/2'; result = 'READY'; checks = @(); warnings = @()
                    facts = [pscustomobject]@{ os = 'Linux'; imdsReached = 'yes'; imdsVmSize = $size } }
            }
            if ($ScriptName -match 'Mana|mana') {
                if ($step -eq 'GUEST_PREP' -and $script:prepFailsLeft -gt 0) {
                    $script:prepFailsLeft--
                    if ($script:storeCalls) { $script:storeAtThrow = $script:storeCalls['GUEST_PREP'] }
                    throw (AclNetError)
                }
                return [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() }
            }
            if ($ScriptName -eq 'guest-validate.sh' -and $step -eq 'VALIDATING' -and $script:validateFailsLeft -gt 0) {
                $script:validateFailsLeft--
                throw (AclNetError)
            }
            [pscustomobject]@{ result = 'PASS'; checks = @(
                @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' },
                @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() }
        }
    }

    It 'THE DEFECT: an attempt that failed and was tried again is a retry line with the cause, never a red fail line' {
        $script:prepFailsLeft = 1
        $final = AclRun
        $final.state | Should -Be 'MIGRATED' -Because 'the second attempt worked'
        $lines = @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.step -eq 'GUEST_PREP' })
        @($lines | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 0 -Because 'the step did not fail: it was tried again and went on'
        $retry = @($lines | Where-Object { $_.outcome -eq 'retry' })
        $retry.Count | Should -Be 1
        $retry[0].detail | Should -Match ([regex]::Escape($script:inner)) -Because 'the line has the cause, not only .NET''s outer sentence'
        $retry[0].attempt | Should -Be 1
        $retry[0].maxAttempts | Should -Be 2
    }

    It 'the history of the machine says the cause of the attempt too' {
        $script:prepFailsLeft = 1
        $final = AclRun
        $h = @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' })
        $h.Count | Should -Be 1
        $h[0].detail | Should -Match ([regex]::Escape("Attempt 1 of 2 failed: ")) -Because 'the retry entry says the attempt as a sentence (MANUAL-REVIEW-1)'
        $h[0].detail | Should -Match ([regex]::Escape($script:inner))
    }

    It 'the attempt that ends the step is the one red line, with the cause; no step line is the bare outer sentence' {
        $script:prepFailsLeft = 9
        $null = AclRun
        $lines = @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.step -eq 'GUEST_PREP' -and $_.outcome -in @('retry', 'fail') })
        @($lines.outcome) | Should -Be @('retry', 'fail') -Because 'attempt 1 is tried again; attempt 2 of 2 ends the step'
        $lines[1].attempt | Should -Be 2
        $lines[1].maxAttempts | Should -Be 2
        foreach ($l in $lines) {
            [string]$l.detail | Should -Not -Be $script:outer -Because 'a bare "An error occurred while sending the request." names no cause'
            [string]$l.detail | Should -Match ([regex]::Escape($script:inner))
        }
    }

    It 'finding 21: Verifying that fails twice writes a retry line, then ONE red line, and the rollback goes on' {
        # The two attempts had the same words, so the Activity list showed the
        # red line of attempt 1, hid it when attempt 2 wrote the same red line
        # (one line per text in three minutes), and showed it again at the top.
        $script:validateFailsLeft = 2
        $final = AclRun
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $lines = @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.step -eq 'VALIDATING' -and $_.outcome -in @('retry', 'fail') })
        @($lines.outcome) | Should -Be @('retry', 'fail')
    }

    It 'a step with one attempt (Moving) that fails is red at once' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw (AclNetError) }
        $null = AclRun
        $lines = @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.step -eq 'CONVERTING' -and $_.outcome -in @('retry', 'fail') })
        @($lines.outcome) | Should -Be @('fail')
        $lines[0].detail | Should -Match ([regex]::Escape($script:inner))
        $lines[0].maxAttempts | Should -Be 1
    }

    It 'a lost lease is still not a step failure: no line, the worker stops' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "Lease for 'vm' is held by 'worker-2', not 'worker-1' - abandon this VM." }
        { AclRun } | Should -Throw '*abandon this VM*'
        @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.outcome -in @('retry', 'fail') -and $_.step -notlike 'azureops:*' }).Count | Should -Be 0
    }

    # PERF-TELEMETRY-ENGINE-1: each step's closing line carries the run store
    # and ARM call times of that step (the `calls` field).
    It 'PERF-TELEMETRY-ENGINE-1: every step''s closing line carries the call times of that step, and only that step' {
        $script:storeCalls = @{}
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { throw 'The engine wrote a VMF-CALLS line.' }
        $final = AclRun
        $final.state | Should -Be 'MIGRATED'
        $states = @('PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING')
        foreach ($s in $states) {
            $lines = AclStepLines $s
            $lines.Count | Should -Be 1 -Because "$s ran once"
            $c = $lines[0].calls
            $c | Should -Not -BeNullOrEmpty -Because "the closing line of $s holds its call times"
            $c.v | Should -Be 1
            [int]$c.store.n | Should -Be ([int]$script:storeCalls[$s]) -Because "only the store calls of $s are on its line"
            $null -ne $c.PSObject.Properties['arm'] -and $null -ne $c.PSObject.Properties['other'] -and $null -ne $c.PSObject.Properties['token'] | Should -BeTrue
        }
        ($script:storeCalls.Values | Measure-Object -Sum).Sum | Should -BeGreaterThan 0 -Because 'the guest scripts made store calls, so the test proves something'
        $start = @(AclEvents | Where-Object { $_.vmId -eq $script:vmId -and $_.outcome -eq 'start' -and $null -ne $_.PSObject.Properties['calls'] })
        $start.Count | Should -Be 0 -Because 'the times are on the line that closes a step, not on the line that opens it'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfCallTimingLine -Times 0 -Exactly
    }

    It 'PERF-TELEMETRY-ENGINE-1: the retry line holds the attempt that failed, and the ok line the attempt that worked' {
        $script:storeCalls = @{}
        $script:prepFailsLeft = 1
        $final = AclRun
        $final.state | Should -Be 'MIGRATED'
        $lines = AclStepLines 'GUEST_PREP'
        @($lines.outcome) | Should -Be @('retry', 'ok')
        $script:storeAtThrow | Should -BeGreaterThan 0
        [int]$lines[0].calls.store.n | Should -Be $script:storeAtThrow
        [int]$lines[1].calls.store.n | Should -Be ($script:storeCalls['GUEST_PREP'] - $script:storeAtThrow) -Because 'each attempt starts its own record'
        $lines[0].attempt | Should -Be 1 -Because 'the line keeps its attempt fields'
        $lines[0].maxAttempts | Should -Be 2
    }

    It 'PERF-TELEMETRY-ENGINE-1: the line of a step that fails holds its calls, named without the account or the signature' {
        $script:storeCalls = @{}
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { AclStoreCall 'CONVERTING'; throw (AclNetError) }
        $null = AclRun
        $lines = AclStepLines 'CONVERTING'
        @($lines.outcome) | Should -Be @('fail')
        [int]$lines[0].calls.store.n | Should -Be 1
        $lines[0].calls.slow[0].target | Should -Be 'p1/acl/state/CONVERTING.json'
        $json = $lines[0] | ConvertTo-Json -Depth 10 -Compress
        $json | Should -Not -Match 'SECRETSIGNATURE'
        $json | Should -Not -Match 'acct\.blob'
    }

    It 'PERF-TELEMETRY-ENGINE-1: no record is left open after the machine, or after a lost lease' {
        $script:storeCalls = @{}
        $null = AclRun
        InModuleScope VmMigrationFactory { $script:VmfCallTimings | Should -BeNullOrEmpty }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "Lease for 'vm' is held by 'worker-2', not 'worker-1' - abandon this VM." }
        $script:runPath = Join-Path $script:temp "acl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'acl' | Out-Null }
        { AclRun } | Should -Throw '*abandon this VM*'
        InModuleScope VmMigrationFactory { $script:VmfCallTimings | Should -BeNullOrEmpty }
    }
}

Describe 'ACTIVITY-LINES-1: an Azure call line carries the status code Azure sent' {
    BeforeEach {
        $script:runPath = Join-Path $script:temp "acs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'acs' | Out-Null }
    }

    It 'finding 60: a data-disk swap Azure refused with 409 ConflictingUserInput says 409 on every line' {
        # The words of an Az cmdlet error, as Set-VmfVmDataDisks hands them on
        # (the disk name is a test name).
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            param($rp)
            {
                Invoke-VmfAzOperation -Name 'rollback:swapDataDisks' -RunPath $rp -VmId 'vm1' -MaxAttempts 3 -BaseDelayMs 1 -Operation {
                    $refused = [System.InvalidOperationException]::new("Azure did not swap the data disks: Disk 'vm1-d0-restored' cannot be attached as it is in 'ActiveSAS' state.`nErrorCode: ConflictingUserInput`nErrorMessage: Disk 'vm1-d0-restored' cannot be attached as it is in 'ActiveSAS' state.`nErrorTarget: `nStatusCode: 409`nReasonPhrase: Conflict")
                    $refused.Data['vmfSwapRefused'] = $true
                    throw $refused
                }
            } | Should -Throw '*ActiveSAS*'
        }
        $lines = @(AclEvents | Where-Object { $_.step -eq 'azureops:rollback:swapDataDisks' })
        @($lines.outcome) | Should -Be @('retry', 'retry', 'fail')
        foreach ($l in $lines) { $l.statusCode | Should -Be 409 -Because 'Azure sent 409, in its own words' }
    }

    It 'a status on the error object is written as before' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            param($rp)
            {
                Invoke-VmfAzOperation -Name 'op' -RunPath $rp -VmId 'vm1' -MaxAttempts 1 -BaseDelayMs 1 -Operation {
                    $e = [System.Exception]::new('refused')
                    $e | Add-Member -NotePropertyName StatusCode -NotePropertyValue 403
                    throw $e
                }
            } | Should -Throw
        }
        @(AclEvents | Where-Object { $_.step -eq 'azureops:op' })[0].statusCode | Should -Be 403
    }

    It 'no status code anywhere: none is written, and a number in a name is not one' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            param($rp)
            { Invoke-VmfAzOperation -Name 'op' -RunPath $rp -VmId 'vm1' -MaxAttempts 1 -BaseDelayMs 1 -Operation { throw "The machine 'vm-409' is not where it was." } } | Should -Throw
        }
        $null -eq @(AclEvents | Where-Object { $_.step -eq 'azureops:op' })[0].statusCode | Should -BeTrue
    }
}

# REBUILD-REMOVE-ACCEPT-1: the line that said who accepted a rebuild or the loss
# of an identity, once for each acceptance (finding 70), is gone with the
# acceptances (Write-VmfAcceptanceLineOnce). Its tests were here.

Describe 'ACTIVITY-LINES-1 (review): the stop code of the wider error text' {
    # The step loop now classifies Resolve-VmfOperationError's text: the status
    # and code in front, Azure's error body, the message and each inner
    # message, joined by ' -> '. Each family keeps its code, and a pattern never
    # matches across two messages of the chain: one message's "subscription"
    # and another's "quota" are not a quota.
    BeforeAll {
        function Global:AclWide([string]$Outer, [string]$Inner, [string]$Body) {
            $ex = if ($Inner) { [System.Exception]::new($Outer, [System.Exception]::new($Inner)) } else { [System.Exception]::new($Outer) }
            $er = [System.Management.Automation.ErrorRecord]::new($ex, 'acl', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
            if ($Body) { $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
            InModuleScope VmMigrationFactory -Parameters @{ er = $er } { param($er) (Resolve-VmfOperationError -ErrorRecord $er).Message }
        }
        function Global:AclCode([string]$Message) {
            InModuleScope VmMigrationFactory -Parameters @{ m = $Message } { param($m) Get-VmfErrorStopReason -Message $m }
        }
    }
    AfterAll { Remove-Item 'function:\AclWide', 'function:\AclCode' -ErrorAction SilentlyContinue }

    It '<code>: the wider text has the same code as the outer message' -ForEach @(
        @{ code = 'quotaExceeded'; outer = "Long running operation failed with status 'Failed'."; inner = 'Operation could not be completed as it results in exceeding approved standardDDSv6Family Cores quota.'
           body = '{ "error": { "code": "OperationNotAllowed", "message": "Operation could not be completed as it results in exceeding approved standardDDSv6Family Cores quota." } }' }
        @{ code = 'capacityUnavailable'; outer = "Allocation failed. We do not have sufficient capacity for the requested VM size in this region. ErrorCode: AllocationFailed"; inner = 'Response status code does not indicate success: 409 (Conflict).'; body = '' }
        @{ code = 'subscriptionReadOnly'; outer = "The subscription '00000000-0000-0000-0000-000000000000' is disabled and therefore marked as read only. ErrorCode: ReadOnlyDisabledSubscription"; inner = ''; body = '' }
        @{ code = 'resourceLockRefused'; outer = "The scope '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/d1' cannot perform delete operation because following scope(s) are locked. ErrorCode: ScopeLocked"; inner = 'Response status code does not indicate success: 409 (Conflict).'; body = '' }
        @{ code = 'permissionRefused'; outer = 'Operation returned an invalid status code ''Forbidden'''; inner = ''
           body = '{ "error": { "code": "AuthorizationFailed", "message": "The client does not have authorization to perform action ''Microsoft.Compute/virtualMachines/write''." } }' }
        @{ code = 'safetyCopyMissing'; outer = 'Safety copy missing: the snapshot of the OS disk is not there.'; inner = ''; body = '' }
        @{ code = 'storageVolumesLost'; outer = 'Storage volumes are missing after the move: vg-data.'; inner = ''; body = '' }
        @{ code = 'stepFailedRepeatedly'; outer = 'An error occurred while sending the request.'; inner = 'Unable to read data from the transport connection: Connection reset by peer.'; body = '' }
    ) {
        $wide = AclWide $outer $inner $body
        AclCode $wide | Should -Be $code
    }

    It 'a word in one message and a word in another are not one pattern' {
        $wide = AclWide "Reading the disk failed in subscription '00000000-0000-0000-0000-000000000000'." 'The guest said: user quota is full on /home.'
        $wide | Should -Match ' -> ' -Because 'the chain has two messages'
        AclCode "Reading the disk failed in subscription '00000000-0000-0000-0000-000000000000'." | Should -Be 'stepFailedRepeatedly'
        AclCode $wide | Should -Be 'stepFailedRepeatedly' -Because 'the code is the one the outer message alone gives'
    }

    It 'a lock word in an unrelated inner message is not a lock' {
        AclCode (AclWide 'An error occurred while sending the request.' 'The process cannot access the file because another process has locked a portion of the file.') | Should -Be 'stepFailedRepeatedly'
    }
}