#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# CPU-BASELINE-REMOVE-1: Checking reads no CPU average, and no role holds
# Azure Monitor metrics read.
#
# PRECHECK used to ask Azure Monitor for the machine's 7-day 'Percentage CPU'
# (Get-VmfCpuBaseline -> Get-AzMetric) and save the average as
# captured.baseline.cpuAvg7d. No page, report or check read it, and the VMF
# Assessment role held Microsoft.Insights/metrics/read only for it. The owner,
# 2026-11-14: nothing unused stays in the app - remove it, never harden it.
#
# The two custom roles are built from the permission map (infra/roles.bicep
# reads rbac-actions.json), so the map holding no Microsoft.Insights action is
# the roles holding none.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:map = Get-Content (Join-Path $script:moduleRoot 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json -Depth 20

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    function Global:CbrVm {
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

    function Global:CbrPrecheck {
        param([string]$RunPath)
        $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; plan = $plan } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'cbr'
            New-VmfStateDoc -RunPath $rp -RunId 'cbr' -VmId $ctx.VmId | Out-Null
            Invoke-VmfStepPrecheck -Context $ctx
        }
    }
}

AfterAll {
    foreach ($fn in 'CbrVm', 'CbrPrecheck', 'Get-AzMetric') { Remove-Item "function:\$fn" -ErrorAction SilentlyContinue }
}

Describe 'CPU-BASELINE-REMOVE-1: no role holds Azure Monitor metrics read' {
    It 'the permission map holds no Microsoft.Insights action' {
        $actions = @($script:map.operations | ForEach-Object { @($_.actions) } | Where-Object { $_ -match '^Microsoft\.Insights/' })
        $actions -join ', ' | Should -BeNullOrEmpty
    }

    It 'the permission map lists no Get-AzMetric call' {
        @($script:map.operations | Where-Object { $_.cmdlet -eq 'Get-AzMetric' }) | Should -BeNullOrEmpty
    }

    It 'the custom roles take their actions from the map and add no Microsoft.Insights action of their own' {
        $roles = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'roles.bicep')
        $roles | Should -Match "loadJsonContent\('\.\./src/VmMigrationFactory/data/rbac-actions\.json'\)"
        $roles | Should -Not -Match 'Microsoft\.Insights'
    }

    It 'the Permissions page of the manual does not name it' {
        Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'permissions.md') -Raw | Should -Not -Match 'Microsoft\.Insights/metrics'
    }
}

Describe 'CPU-BASELINE-REMOVE-1: the module reads no metric' {
    It 'no file of the module calls Get-AzMetric' {
        $hits = @(Get-ChildItem $script:moduleRoot -Filter *.ps1 -Recurse | Where-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Get-AzMetric' }, $true)).Count
        } | ForEach-Object Name)
        $hits -join ', ' | Should -BeNullOrEmpty
    }

    It 'the module has no Get-VmfCpuBaseline' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfCpuBaseline -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }
}

Describe 'CPU-BASELINE-REMOVE-1: Checking makes no metrics call and saves no CPU average' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cbr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'cbr' | Out-Null }
        # A function wins over a cmdlet of the same name, so this catches the
        # call whether Az.Monitor is installed here or not.
        $global:CbrMetricCalls = 0
        function Global:Get-AzMetric { $global:CbrMetricCalls++; throw 'Get-AzMetric must not be called' }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:CbrVm }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
    }
    AfterEach {
        Remove-Item 'function:\Get-AzMetric' -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name CbrMetricCalls -ErrorAction SilentlyContinue
        if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force }
    }

    It 'Checking goes on, asks Azure Monitor nothing, and the capture holds no baseline' {
        $r = Global:CbrPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because 'the machine passes Checking, so the whole capture is written'
        $global:CbrMetricCalls | Should -Be 0 -Because 'nothing reads a CPU average, so Checking does not ask for one'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $doc.captured | Should -Not -BeNullOrEmpty
        $doc.captured.PSObject.Properties.Name | Should -Not -Contain 'baseline'
    }
}
