#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# PRECHECK-EXT-READ-1: a failed extension read at Checking is "not read",
# never "no extensions".
#
# PRECHECK reads the extensions of the machine once. A rebuild (Path B)
# deletes every one of them, so the rebuild gate (REBUILD-ACCEPT-1) compares
# them with what the acceptance showed, the line after the delete names them,
# and Verifying compares the machine with the same list. The read used to
# return an empty list when Azure did not answer: the gate then passed an
# extension nobody accepted, and the line named none. REBUILD-PROPS-1 made the
# read throw; this makes Checking say so - a named stop, the machine
# untouched - after the operation wrapper has tried the read again.
#
# REBUILD-REMOVE-ACCEPT-1: a plan that rebuilds stops at the top of Checking
# now (rebuildNotSupported), so every machine here moves in place, where the
# list still matters: Verifying compares the machine with it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    # One machine, one interface, no data disk and no zone, shaped like
    # Get-AzVM returns it.
    function Global:PxVm {
        [pscustomobject]@{
            Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    function Global:PxPlan {
        param([string]$Path = 'A')
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = $Path
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
    }

    # PRECHECK of one machine, through the real step and the real operation
    # wrapper (the guard makes its waits zero).
    function Global:PxPrecheck {
        param([string]$RunPath, [string]$Path = 'A')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; plan = (Global:PxPlan -Path $Path) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'pxr'
            New-VmfStateDoc -RunPath $rp -RunId 'pxr' -VmId $ctx.VmId | Out-Null
            Invoke-VmfStepPrecheck -Context $ctx
        }
    }

    function Global:PxDoc {
        param([string]$RunPath)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $script:vmId } {
            param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
    }
}

AfterAll {
    foreach ($fn in 'PxVm', 'PxPlan', 'PxPrecheck', 'PxDoc') { Remove-Item "function:\$fn" -ErrorAction SilentlyContinue }
}

Describe 'PRECHECK-EXT-READ-1: Checking stops a machine whose extensions Azure did not return' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pxr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'pxr' | Out-Null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:PxVm }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: a machine whose extension read Azure never answers stops untouched, not as a machine with no extensions' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { throw 'HTTP 503 Service Unavailable' }
        $r = Global:PxPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'extensionsNotRead' -Because 'Verifying must never compare with an empty list it did not read'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match '503' -Because 'the stop says what Azure answered'
        $r.Detail | Should -Match 'Nothing on the machine changed'
        # The capture is written after the read: nothing records "no extensions".
        $doc = Global:PxDoc -RunPath $script:rp
        ($doc.captured -and $doc.captured.PSObject.Properties['extensions']) | Should -BeFalse
    }

    It 'the read is tried again first: a throttle is retried by the operation wrapper' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { throw 'HTTP 429 Too Many Requests' }
        (Global:PxPrecheck -RunPath $script:rp).Reason | Should -Be 'extensionsNotRead'
        Should -Invoke Get-VmfVmExtensions -ModuleName VmMigrationFactory -Times 4 -Exactly -Because 'Invoke-VmfAzOperation tries a transient read four times'
    }

    It 'a read that answers the second time goes on, with the extensions it read' {
        $script:pxCalls = 0
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions {
            $script:pxCalls++
            if ($script:pxCalls -eq 1) { throw 'HTTP 503 Service Unavailable' }
            , @([ordered]@{ name = 'AzureMonitorLinuxAgent'; publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorLinuxAgent'; provisioningState = 'Succeeded' })
        }
        $r = Global:PxPrecheck -RunPath $script:rp
        $r.Reason | Should -Not -Be 'extensionsNotRead'
        # It goes on, and the capture holds what Azure returned.
        $r.Next | Should -Be 'SAFETY_PRISTINE'
        $doc = Global:PxDoc -RunPath $script:rp
        @($doc.captured.extensions | ForEach-Object { $_.name }) | Should -Be @('AzureMonitorLinuxAgent')
    }

    It 'a successful empty read is an answer: the machine goes on, and none is recorded as an answer' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        $r = Global:PxPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because 'the read gave an answer, so the machine goes on'
        $doc = Global:PxDoc -RunPath $script:rp
        $doc.captured.PSObject.Properties['extensions'] | Should -Not -BeNullOrEmpty -Because 'none is recorded as an answer'
        @($doc.captured.extensions).Count | Should -Be 0
    }

    It 'any error stops it: Verifying compares with the list, and an empty one compares nothing' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { throw 'HTTP 500 Internal Server Error' }
        $r = Global:PxPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'extensionsNotRead'
        $r.MachineState | Should -Be 'untouched'
    }

    It 'a resize in place with no extensions goes on' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        (Global:PxPrecheck -RunPath $script:rp).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'a lost lease is never a stop of the machine: it goes to the worker' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { throw 'Lease lost - abandon this VM' }
        { Global:PxPrecheck -RunPath $script:rp } | Should -Throw '*abandon this VM*'
    }

    It 'kill and resume: Checking asks again, and stops the same way while Azure does not answer' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { throw 'HTTP 503 Service Unavailable' }
        $first = Global:PxPrecheck -RunPath $script:rp
        $again = Global:PxPrecheck -RunPath $script:rp
        $again.Reason | Should -Be $first.Reason
    }
}

Describe 'PRECHECK-EXT-READ-1: the stop has guidance' {
    It 'the reason is in the list, untouched, and a person can correct its cause' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'extensionsNotRead'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.retry | Should -Be 'afterFix'
            $g.meaning | Should -Match 'extension'
            $g.whatToDo | Should -Match 'portal'
        }
    }

    It 'PRECHECK reads the extensions through the one helper, never the wrapper alone' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $pre | Should -Not -BeNullOrEmpty
        $pre | Should -Match 'Read-VmfPrecheckExtensions -Context \$Context'
        $pre | Should -Not -Match 'Get-VmfVmExtensions' -Because 'a second read in PRECHECK would not carry the stop'
    }
}
