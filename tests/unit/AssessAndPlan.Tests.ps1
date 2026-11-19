#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    function Global:Get-AzVMUsage { param($Location) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewInventoryRow {
        param(
            [string]$Name = 'vm1', [string]$Size = 'Standard_D2ds_v4', [string]$Os = 'Windows',
            [string]$Gen = 'V2', [string]$ImagePublisher = 'MicrosoftWindowsServer',
            [string]$ImageSku = '2022-datacenter-g2', [string]$VmssId = '',
            [string]$Rg = 'rg-app', $Tags = $null, [string]$DiskController = 'SCSI',
            [object[]]$Zones = @(), [string]$IdentityType = 'None'
        )
        [pscustomobject]@{
            id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$Rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = $Rg; location = 'centralus'; zones = $Zones
            sku = $Size; os = $Os; gen = $Gen; diskController = $DiskController
            imagePublisher = $ImagePublisher; imageSku = $ImageSku; vmssId = $VmssId
            hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $Tags; identityType = $IdentityType; identityPrincipalId = $(if ($IdentityType -match 'SystemAssigned') { '11111111-2222-3333-4444-555555555555' } else { '' })
        }
    }

    function Global:NewSkuEntry {
        param([string]$Name, [int]$ResourceMb = 0, [string]$Family = 'StandardDDSv4Family', [int]$Vcpus = 2, $Restrictions = @())
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = "$ResourceMb" },
                [pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" }
            )
            Restrictions = $Restrictions
        }
    }
}

AfterAll {
    Remove-Item -Path 'function:\Invoke-AzRestMethod', 'function:\Get-AzVMUsage', 'function:\NewInventoryRow', 'function:\NewSkuEntry' -ErrorAction SilentlyContinue
}

Describe 'Assessment rules (Get-VmfAssessmentRecord)' {

    It 'classifies a standard Windows v4 VM as ReadyAfterPrep with the right prep list' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (NewInventoryRow) -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)
            $rec.classification | Should -Be 'ReadyAfterPrep'
            $rec.sourceDiskArch | Should -Be 'scsi-temp'
            $rec.prepNeeded | Should -Contain 'stornvme'
            $rec.prepNeeded | Should -Contain 'pagefile'
            $rec.blockers | Should -BeNullOrEmpty
        }
    }

    # REBUILD-REMOVE-PLAN-1: IDENTITY-UX-1 told this machine it would get a new
    # identity, because its move was a rebuild. Its move is the in-place upgrade
    # (Preview) now, which keeps the identity, so the scan says nothing.
    It 'IDENTITY-UX-1, rewritten: a Windows temp-disk machine with a system-assigned identity is no longer told it gets a new one' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (NewInventoryRow -IdentityType 'SystemAssigned') -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)
            $rec.warnings | Should -Not -Contain 'system-identity-recreated'
            $rec.prepNeeded | Should -Not -Contain 'system-identity-recreated'
            $rec.identityType | Should -Be 'SystemAssigned'
            $rec.identityPrincipalId | Should -Be '11111111-2222-3333-4444-555555555555'
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -IdentityType 'SystemAssigned, UserAssigned') -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)).warnings |
                Should -Not -Contain 'system-identity-recreated'
            # Not said where it is not true: no identity, a user-assigned one only, a Linux machine (resized, never rebuilt).
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow) -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)).warnings |
                Should -Not -Contain 'system-identity-recreated'
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -IdentityType 'UserAssigned') -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)).warnings |
                Should -Not -Contain 'system-identity-recreated'
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -Os 'Linux' -ImagePublisher 'Canonical' -ImageSku '22_04-lts-gen2' -IdentityType 'SystemAssigned') -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)).warnings |
                Should -Not -Contain 'system-identity-recreated'
            # A row from before this field (no identityType at all) is simply not told.
            $old = NewInventoryRow; $old.PSObject.Properties.Remove('identityType'); $old.PSObject.Properties.Remove('identityPrincipalId')
            $rec2 = Get-VmfAssessmentRecord -Vm $old -SkuEntry (NewSkuEntry -Name 'Standard_D2ds_v4' -ResourceMb 76800)
            $rec2.warnings | Should -Not -Contain 'system-identity-recreated'
            $rec2.identityType | Should -Be ''
        }
    }

    It 'hard-excludes VMSS members and AKS node RGs (scope guard)' {
        InModuleScope VmMigrationFactory {
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -VmssId '/subscriptions/s/rg/providers/Microsoft.Compute/virtualMachineScaleSets/ss1')).classification |
                Should -Be 'Excluded'
            # The MC_* naming convention no longer decides anything (AKS
            # review, 2026-08-28): an RG that merely LOOKS like a node RG is
            # an ordinary machine unless the cluster itself declares it.
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -Rg 'MC_myaks_rg_centralus')).classification |
                Should -Not -Be 'Excluded'
            # The provider's declaration is what excludes - real node RG,
            # whatever it is named.
            $vm = NewInventoryRow -Rg 'my-custom-node-rg'
            $sub = ([string]$vm.id -split '/')[2]
            (Get-VmfAssessmentRecord -Vm $vm -ManagedPlatformGroups @{ "$sub/my-custom-node-rg".ToLowerInvariant() = "AKS cluster 'aks1'" }).classification |
                Should -Be 'Excluded'
        }
    }

    It "AKS-1: a 'VirtualMachines' node-pool node has NO scale-set id and is still excluded, by the cluster's own declaration" {
        # The details on screen did not make sense - and the ledger agreed, then
        # assumed the opposite: that every modern node pool is scale-set backed
        # and vmssId is the one solid signal. Microsoft's API definition
        # (AgentPoolType, managedClusters.json 2025-05-01) lists THREE pool
        # types: VirtualMachineScaleSets; AvailabilitySet ("Use of this is
        # strongly discouraged"); and VirtualMachines - "an Agent Pool backed by
        # a Single Instance VM orchestration mode". That third type is GA, its
        # nodes are ordinary Microsoft.Compute/virtualMachines, and they carry
        # no scale-set id at all. vmssId cannot be the catch for AKS.
        #
        # What catches them is the cluster's nodeResourceGroup - "the resource
        # group containing agent pool nodes", every pool type - which the guard
        # reads from the provider (WORKLOAD-1). This case is that shape, named:
        # a machine with an EMPTY vmssId, in the group the cluster declared.
        InModuleScope VmMigrationFactory {
            $vm = NewInventoryRow -Name 'aks-vmpool-12345' -Rg 'rg-aks-nodes' -VmssId ''
            $sub = ([string]$vm.id -split '/')[2]
            $rec = Get-VmfAssessmentRecord -Vm $vm -ManagedPlatformGroups @{ "$sub/rg-aks-nodes".ToLowerInvariant() = "AKS cluster 'aks-vmpools'" }
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
            (@($rec.notes) -join ' ') | Should -Match "AKS cluster 'aks-vmpools'" -Because 'the reason names the cluster, from the platform record'
            # and the same machine with NO declaration is an ordinary server -
            # the declaration is the signal, not the name or the emptiness
            (Get-VmfAssessmentRecord -Vm $vm -ManagedPlatformGroups @{}).classification | Should -Not -Be 'Excluded'
        }
    }

    It 'blocks Gen1 and pre-2019 Windows' {
        InModuleScope VmMigrationFactory {
            $gen1 = Get-VmfAssessmentRecord -Vm (NewInventoryRow -Gen 'V1')
            $gen1.classification | Should -Be 'Blocked'
            $gen1.blockers | Should -Contain 'gen1-requires-redeploy'

            $old = Get-VmfAssessmentRecord -Vm (NewInventoryRow -ImageSku '2016-datacenter')
            $old.classification | Should -Be 'Blocked'
            $old.blockers | Should -Contain 'windows-version-below-2019'
        }
    }

    It 'IAC-2: does NOT guess at infrastructure-as-code from tags' {
        # Removed deliberately: the product builds no tag dependency at all
        # and tracks none. The old rule
        # matched managed-by/provisioner against terraform/tf/opentofu, which
        # could not tell Terraform from Bicep, Pulumi, ARM or Ansible and read a
        # differently-tagged estate as unmanaged - then drove a decision that
        # could stop a migration. The drift question is now put to the customer
        # once for the whole run.
        InModuleScope VmMigrationFactory {
            $tags = [pscustomobject]@{ 'managed-by' = 'Terraform'; env = 'prod' }
            $r = Get-VmfAssessmentRecord -Vm (NewInventoryRow -Tags $tags)
            $r.PSObject.Properties['iacManaged'] | Should -BeNullOrEmpty
            @($r.notes) -join ' ' | Should -Not -Match '(?i)iac tag'
        }
    }

    It 'READY-NOW-REMOVE-1: a machine already on NVMe is ReadyAfterPrep, never ReadyNow' {
        InModuleScope VmMigrationFactory {
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -DiskController 'NVMe' -Size 'Standard_D2ds_v6')).classification |
                Should -Be 'ReadyAfterPrep'
        }
    }

    It 'flags unknown generation as needing verification, not blocked' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (NewInventoryRow -Gen '')
            $rec.classification | Should -Be 'ReadyAfterPrep'
            $rec.prepNeeded | Should -Contain 'verify-generation'
        }
    }
}

Describe 'Planner internals' {

    It 'default size transform preserves capability letters: <Source> -> <Expected>' -TestCases @(
        @{ Source = 'Standard_D2ds_v4'; Expected = 'Standard_D2ds_v6' }
        @{ Source = 'Standard_D2s_v4'; Expected = 'Standard_D2s_v6' }
        @{ Source = 'Standard_E2bds_v5'; Expected = 'Standard_E2bds_v6' }
        @{ Source = 'Standard_E8-4ds_v5'; Expected = 'Standard_E8-4ds_v6' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ src = $Source; exp = $Expected } {
            (Get-VmfTargetSize -SourceSize $src).Target | Should -Be $exp
        }
    }

    It 'a named size (a chosen one) takes the place of the transform, and the reason says so' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E2bds_v5' -Size 'Standard_E2ads_v6'
            $r.Target | Should -Be 'Standard_E2ads_v6'
            @($r.Alternates).Count | Should -Be 0
            $r.Reason | Should -Be 'chosen-size'
        }
    }

    It 'a named size missing from the region catalog gives no target - never another size' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = $true }
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -Size 'Standard_D2ds_v6' -CatalogBySize $catalog).Target |
                Should -BeNullOrEmpty
        }
    }

    It 'returns null with a reason when nothing maps' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_B2s' -CatalogBySize @{ 'x' = $true }
            $r.Target | Should -BeNullOrEmpty
            # This used to read 'no candidate available in
            # region', which describes a regional shortage. B-series has no
            # v6 at all - it is not part of the migration path - and those are
            # different facts needing different actions.
            $r.Reason | Should -Match 'not part of the v6/v7 migration path'
        }
    }

    Context 'which families the v6/v7 path actually covers' {
        BeforeAll {
            # A catalog shaped like a real region: D and E have v6 sizes,
            # nothing else does - which is what Azure reports.
            $script:famCatalog = @{}
            foreach ($n in 'Standard_D2s_v6', 'Standard_D2ds_v6', 'Standard_D4ds_v6',
                           'Standard_E2ds_v6', 'Standard_E8ds_v6', 'Standard_D2s_v7') {
                $script:famCatalog[$n] = @{ Name = $n }
            }
        }

        It 'reads the family letters off a size name' {
            InModuleScope VmMigrationFactory {
                Get-VmfSizeFamilyPrefix -SizeName 'Standard_D2ds_v4'   | Should -Be 'D'
                Get-VmfSizeFamilyPrefix -SizeName 'Standard_E8-4ds_v5' | Should -Be 'E'
                Get-VmfSizeFamilyPrefix -SizeName 'Standard_NC6s_v3'   | Should -Be 'NC'
                Get-VmfSizeFamilyPrefix -SizeName 'Standard_B2s'       | Should -Be 'B'
            }
        }

        It 'answers from the catalog, which is what Azure actually offers' {
            InModuleScope VmMigrationFactory -Parameters @{ c = $script:famCatalog } {
                Test-VmfFamilyHasGeneration -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c | Should -BeTrue
                Test-VmfFamilyHasGeneration -SourceSize 'Standard_E8-4ds_v5' -CatalogBySize $c | Should -BeTrue
                Test-VmfFamilyHasGeneration -SourceSize 'Standard_L8s_v3' -CatalogBySize $c | Should -BeFalse
            }
        }

        It 'a family with v6 but no v7 anywhere is still IN scope' {
            # The case this got wrong first time round: asking about the wave's
            # chosen generation told a v7 wave that the D family was not part
            # of the programme, because that region had no v7 yet. "No v6/v7 at
            # all" and "v7 not here yet" are different facts with different
            # answers, and the second already has its own refusal.
            InModuleScope VmMigrationFactory {
                $v6only = @{}
                foreach ($n in 'Standard_D2s_v6', 'Standard_E2ds_v6') { $v6only[$n] = @{ Name = $n } }
                Test-VmfFamilyHasGeneration -SourceSize 'Standard_D2ds_v4' -CatalogBySize $v6only | Should -BeTrue
                $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $v6only -TargetGeneration 'v7'
                $r.Target | Should -BeNullOrEmpty
                $r.Reason | Should -Match 'Standard_D2s_v6' -Because 'the v7 refusal names the v6 size that would have worked'
                $r.Reason | Should -Not -Match 'not part of the v6/v7 migration path'
            }
        }

        It 'and says it CANNOT TELL when there is no catalog to ask' {
            # Unknown must never turn into "out of scope" - that would refuse a
            # perfectly migratable machine because a lookup failed.
            InModuleScope VmMigrationFactory {
                $null -eq (Test-VmfFamilyHasGeneration -SourceSize 'Standard_D2ds_v4' -CatalogBySize @{}) |
                    Should -BeTrue
            }
        }

        It 'an out-of-scope family is told it is out of scope, not that the region is short' {
            InModuleScope VmMigrationFactory -Parameters @{ c = $script:famCatalog } {
                foreach ($s in 'Standard_NC6s_v3', 'Standard_M8ms_v2', 'Standard_L8s_v3', 'Standard_F2s_v2') {
                    $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c
                    $r.Target | Should -BeNullOrEmpty
                    $r.Reason | Should -Match 'not part of the v6/v7 migration path'
                    $r.Reason | Should -Not -Match 'no candidate available in region'
                }
            }
        }

        It 'an IN-scope size missing from this region still reads as a regional miss' {
            # The distinction that makes this worth having: the E family HAS
            # v6, so an E size absent from one region is a regional fact and
            # the operator may have somewhere else to put it.
            InModuleScope VmMigrationFactory -Parameters @{ c = $script:famCatalog } {
                $r = Get-VmfTargetSize -SourceSize 'Standard_E64ds_v5' -CatalogBySize $c
                $r.Target | Should -BeNullOrEmpty
                $r.Reason | Should -Match 'no candidate available in region'
            }
        }

        It 'and a D or E machine still maps, which is the whole point' {
            InModuleScope VmMigrationFactory -Parameters @{ c = $script:famCatalog } {
                (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c).Target |
                    Should -Be 'Standard_D2ds_v6'
                (Get-VmfTargetSize -SourceSize 'Standard_E2ds_v5' -CatalogBySize $c).Target |
                    Should -Be 'Standard_E2ds_v6'
            }
        }
    }

    # REBUILD-REMOVE-PLAN-1: cross-arch was B (a rebuild). It is the in-place upgrade
    # (Preview) for a measured shape, and no move at all for an unknown generation.
    It 'path selection: Linux always A; Windows same-arch A, cross-arch A (Preview) or MANUAL; blocked MANUAL; NVMe excluded' {
        InModuleScope VmMigrationFactory {
            $mk = { param($os, $cls, $arch, $ctrl) [pscustomobject]@{ os = $os; classification = $cls; sourceDiskArch = $arch; diskController = $ctrl; platformManaged = $false } }
            Get-VmfPathSelection -Assessment (& $mk 'Linux' 'ReadyAfterPrep' 'diskless' 'SCSI') -TargetDiskArch 'diskless' | Should -Be 'A'
            Get-VmfPathSelection -Assessment (& $mk 'Windows' 'ReadyAfterPrep' 'scsi-temp' 'SCSI') -TargetDiskArch 'scsi-temp' | Should -Be 'A'
            Get-VmfPathSelection -Assessment ((& $mk 'Windows' 'ReadyAfterPrep' 'scsi-temp' 'SCSI') | Add-Member -NotePropertyName gen -NotePropertyValue 'V2' -PassThru) -TargetDiskArch 'nvme-temp' | Should -Be 'A'
            Get-VmfPathSelection -Assessment (& $mk 'Windows' 'ReadyAfterPrep' 'scsi-temp' 'SCSI') -TargetDiskArch 'nvme-temp' | Should -Be 'MANUAL' -Because 'the generation was not read'
            Get-VmfPathSelection -Assessment (& $mk 'Windows' 'Blocked' 'scsi-temp' 'SCSI') -TargetDiskArch 'nvme-temp' | Should -Be 'MANUAL'
            Get-VmfPathSelection -Assessment (& $mk 'Windows' 'ReadyNow' 'nvme-temp' 'NVMe') -TargetDiskArch 'nvme-temp' | Should -Be 'EXCLUDED'
        }
    }

    It 'WAVE-2: ONE safe default set for every wave - the four-way ring table is gone' {
        # Rings named lab, canary, prod and non-prod were invented; each of
        # their settings is a lever to pull per wave. The safe end is the default for
        # every wave, and every loosening is a deliberate per-wave act.
        InModuleScope VmMigrationFactory {
            $p = Get-VmfDefaultWavePolicy
            $p.safetyCopy | Should -Be 'pristine' -Because 'the failure model depends on it - not a lever'
            $p.onDDataFound | Should -Be 'stop' -Because 'losing customer data is never a default'
            # WAVE-2 phase C, decided lever by lever 2026-08-28
            $p.capacityGate | Should -Be 'BestEffort' -Because 'lever 1: check it looks available, then go'
            $p.requireApproval | Should -BeTrue -Because 'lever 2: accepting what a wave IS is not the same act as saying it may run now'
            $p.onDriverBelowFloor | Should -Be 'stop' -Because 'lever 4: a known, avoidable way to lose accelerated networking'
            $p.keepSnapshotDays | Should -Be 7 -Because 'lever 7: wired, not decorative'
            $p.ContainsKey('acceleratedNetworking') | Should -BeFalse -Because 'lever 5 resolves per machine: ensure on for a migration, preserve for a reversion'
            # and the taxonomy is really dead
            Get-Command Get-VmfRingPolicy -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'wave batching keeps app groups together, one group to a wave' {
        InModuleScope VmMigrationFactory {
            $entries = @(
                1..8 | ForEach-Object { [pscustomobject]@{ vmId = "app1-$_"; appGroup = 'app1' } }
                1..8 | ForEach-Object { [pscustomobject]@{ vmId = "app2-$_"; appGroup = 'app2' } }
                [pscustomobject]@{ vmId = 'solo'; appGroup = 'solo' }
            )
            $waves = Get-VmfWaveAssignments -Entries $entries
            # app1 entirely in one wave
            @($entries | Where-Object appGroup -eq 'app1' | ForEach-Object { $waves[$_.vmId] } | Sort-Object -Unique).Count | Should -Be 1
            # app2 does not share app1's wave (WAVE-GROUP-1: one group to a wave)
            $waves['app1-1'] | Should -Not -Be $waves['app2-1']
            # WAVE-2: neutral names the customer renames - never an environment word
            $waves['solo'] | Should -Match '^wave-\d+$'
        }
    }
}

Describe 'IAC-1 park enforcement in PRECHECK' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-iac-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'iac-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'IAC-2: the drift question gates the RUN, not each machine' {
        # This used to park an IaC-tagged machine at PRECHECK. That gate is gone
        # with the guess that fed it; the replacement is a run-level
        # acknowledgement the ENGINE requires - checked in Start-VmfWave rather
        # than the wizard, because a wizard-only gate is bypassed by the API
        # path that the engine job actually uses.
        # this file has no $script:repoRoot - derive it, like its other tests do
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $sm = Get-Content (Join-Path $root 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $sm | Should -Not -Match "onIacManaged"
        $sm | Should -Not -Match "IaC-managed VM \(Terraform\)"

        $sw = Get-Content (Join-Path $root 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $sw | Should -Match 'Test-VmfRunAcknowledged'
        # and it is checked BEFORE the wave approval, because accepting the
        # terms of the run precedes approving a wave within it
        $sw.IndexOf('Test-VmfRunAcknowledged') | Should -BeLessThan $sw.IndexOf('Test-VmfWaveApproval')
    }
}

Describe 'Reservation v1' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        # Minimal plan file: 3 executable VMs -> 2 cells (2x D2s_v6 zonal, 1x D2ds_v6 regional)
        $plan = @{
            schemaVersion = 1; assessmentRunId = 'r1'
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vma'; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6'; zone = '1' } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vmb'; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6'; zone = '1' } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vmc'; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6'; zone = $null } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vmd'; wave = 'prod-1'; path = 'MANUAL'; assessment = @{ location = 'centralus' }; target = @{ size = $null; zone = $null } }
            )
        }
        $script:planPath = Join-Path $script:runPath 'plan.json'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'builds claims per cell, verifies quota via catalog-provided family (never by name)' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @(
                (NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
                (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2)
            )
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @(
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 2; Limit = 10 },
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 }
            )
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        @($result.Claims).Count | Should -Be 2
        @($result.Blocked).Count | Should -Be 0
        $dsClaim = @($result.Claims) | Where-Object size -eq 'Standard_D2s_v6'
        $dsClaim.vmFamily | Should -Be 'StandardDsv6Family'
        $dsClaim.demand.instances | Should -Be 2
        $dsClaim.demand.vcpus | Should -Be 4
        $dsClaim.state | Should -Be 'QUOTA_VERIFIED'
        # claims persisted to disk
        @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json').Count | Should -Be 2
    }

    It 'counts only machines still to move: a MIGRATED machine is in the usage already, a SKIPPED one never moves' {
        # RETRY-SERIES-1's review: a wave checked again after one machine's
        # target changed counted the machines that had already migrated - a
        # false shortfall, or a reservation that bills for nobody.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 2; Limit = 10 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; sub = $sub } {
            foreach ($pair in @(@('vma', 'MIGRATED'), @('vmc', 'SKIPPED'), @('vmb', 'FAILED_ROLLED_BACK'))) {
                $doc = New-VmfStateDoc -RunPath $rp -RunId 'r1' -VmId "$sub/$($pair[0])" -Wave 'prod-1'
                $doc.state = $pair[1]
                Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null
            }
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $ds = @($result.Claims) | Where-Object size -eq 'Standard_D2s_v6'
        $ds.demand.instances | Should -Be 1 -Because 'vmb rolled back and still has to move; vma is migrated'
        @($result.Claims | Where-Object size -eq 'Standard_D2ds_v6').Count | Should -Be 0 -Because 'vmc was left out'
    }

    It 'blocks on quota shortfall with the exact numbers' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 8; Limit = 10 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $blocked = @($result.Blocked)
        @($blocked).Count | Should -Be 1
        $blocked[0].size | Should -Be 'Standard_D2s_v6'
        $blocked[0].notes -join ' ' | Should -Match 'needs 4 vCPUs, headroom 2'
    }

    It 'handles the s-suffix listing bug: family absent from usage -> verified with warning' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $dsClaim = @($result.Claims) | Where-Object size -eq 'Standard_D2s_v6'
        $dsClaim.state | Should -Be 'QUOTA_VERIFIED'
        $dsClaim.notes -join ' ' | Should -Match 'known platform bug'
    }

    It 'blocks restricted SKUs (region and zone)' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @(
                (NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2 -Restrictions @(
                    [pscustomobject]@{ Type = 'Zone'; ReasonCode = 'NotAvailableForSubscription'
                        RestrictionInfo = [pscustomobject]@{ Zones = @('1') } }
                )),
                (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2)
            )
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $zBlocked = @($result.Blocked) | Where-Object size -eq 'Standard_D2s_v6'
        $zBlocked.state | Should -Be 'BLOCKED'   # BLOCKED-NAME-1
        $zBlocked.notes -join ' ' | Should -Match 'restricted in zone 1'
    }

    It 'ZONES-1: blocks a size the region offers only in its other zones, read as the cell''s subscription' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            $only23 = NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2
            $only23 | Add-Member -NotePropertyName LocationInfo -NotePropertyValue @([pscustomobject]@{ Location = 'centralus'; Zones = [string[]]@('2', '3') })
            @($only23, (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $zBlocked = @($result.Blocked) | Where-Object size -eq 'Standard_D2s_v6'
        $zBlocked.state | Should -Be 'BLOCKED'
        $zBlocked.notes -join ' ' | Should -Match 'not offered in zone 1'
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -Times 0 -Exactly -ParameterFilter { -not $SubscriptionId }
    }

    It 'Test-VmfQuotaAndReservation gates a wave on claim states' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 10 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'prod-1').Pass | Should -BeTrue
        # Reserved gate fails closed while claims are merely QUOTA_VERIFIED
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'prod-1' -Gate 'Reserved').Pass | Should -BeFalse
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'nope').Pass | Should -BeFalse
    }

    It 'forecast splits AvSet members out of reservable demand (CAP-2)' {
        # Azure cannot associate AvSet members to capacity reservations, so
        # reserving slots for them double-counts quota (their unusable slots
        # PLUS their general-capacity cores - REH-1 jammed a 10-core family
        # exactly this way). instances still drives quota verification;
        # reservableInstances drives ODCR quantity.
        $plan = Get-Content $script:planPath -Raw | ConvertFrom-Json -Depth 10
        $avsEntry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vme'; wave = 'prod-1'; path = 'A'
            assessment = [pscustomobject]@{ location = 'centralus'
                availabilitySetId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/availabilitySets/avs1' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; zone = '1' }
        }
        $plan.entries = @($plan.entries) + @($avsEntry)
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 10 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        $result = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $cell = @($result.Claims) | Where-Object { $_.size -eq 'Standard_D2s_v6' -and $_.zone -eq '1' }
        $cell.demand.instances | Should -Be 3 -Because 'quota verification covers ALL instances'
        $cell.demand.reservableInstances | Should -Be 2 -Because 'the AvSet member cannot consume a reservation'
        ($cell.notes -join ' ') | Should -Match 'availability set'
        # Derived, not pinned: a hard-coded version here is a line to hand-edit
        # on every bump rather than a guard. What matters is that the claim
        # carries the version this build declares.
        $cell.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfCapacityClaimSchemaVersion })
        $other = @($result.Claims) | Where-Object size -EQ 'Standard_D2ds_v6'
        $other.demand.reservableInstances | Should -Be 1 -Because 'cells without AvSet members reserve everything'
    }

    It 'Test-VmfQuotaAndReservation accepts states STRONGER than the gate requires (REH-1)' {
        # Found by the wave rehearsal: after New-VmfWaveReservation moved claims
        # to RESERVED, Start-VmfWave's BestEffort pre-flight failed because the
        # gate demanded literal QUOTA_VERIFIED. The ladder is
        # QUOTA_VERIFIED < RESERVED < CONSUMED; a gate passes at-or-above its rung.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D2ds_v6' -Family 'StandardDdsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 10 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        foreach ($state in @('RESERVED', 'CONSUMED')) {
            foreach ($f in Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json') {
                $c = Get-Content $f.FullName -Raw | ConvertFrom-Json -Depth 12
                $c.state = $state
                $c | ConvertTo-Json -Depth 12 | Set-Content $f.FullName
            }
            (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'prod-1' -Gate 'BestEffort').Pass |
                Should -BeTrue -Because "BestEffort must accept $state"
            (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'prod-1' -Gate 'Reserved').Pass |
                Should -BeTrue -Because "Reserved must accept $state"
        }
    }
}

Describe 'Ring and app-group tag flow (assessment -> planner)' {
    It 'reads the app-group tag, which is a GROUPING option the customer picks' {
        # Grouping machines by a tag is fine: it is one of four strategies, and
        # nothing depends on it - choose another and it is never read.
        InModuleScope VmMigrationFactory {
            $tags = [pscustomobject]@{ app = 'payments'; ring = 'prod' }
            (Get-VmfAssessmentRecord -Vm (NewInventoryRow -Tags $tags)).appGroup | Should -Be 'payments'
        }
    }

    It 'and does NOT read a ring tag, because that would let a tag decide behaviour' {
        # The ring tag selected an entire policy set - eight
        # behaviours - from a tag value, and silently ignored anything that was
        # not one of our four invented words, so a customer tagging
        # env=production got the default and was never told why. The ring is the
        # explicit choice made at planning time now.
        InModuleScope VmMigrationFactory {
            $tags = [pscustomobject]@{ ring = 'prod'; app = 'payments' }
            $r = Get-VmfAssessmentRecord -Vm (NewInventoryRow -Tags $tags)
            $r.ring | Should -BeNullOrEmpty
            @($r.notes) -join ' ' | Should -Not -Match '(?i)ring tag'
        }
    }
}

Describe 'CAP-3: capacity assurance as a user choice' {
    It 'the default is BestEffort until a customer chooses otherwise' {
        InModuleScope VmMigrationFactory {
            (Get-VmfDefaultWavePolicy).capacityGate | Should -Be 'BestEffort'
        }
    }

    It 'the plan-time choice overrides, and touches ONLY the capacity fact' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfDefaultWavePolicy -CapacityGateOverride 'Reserved'
            $p.capacityGate | Should -Be 'Reserved'
            $p.onDDataFound | Should -Be 'stop'
            $p.safetyCopy | Should -Be 'pristine'
        }
    }

    It 'New-VmfPlan rejects an invalid capacity choice before reading anything' {
        { New-VmfPlan -AssessmentPath 'never-read.json' -OutPath 'never-written' -CapacityGate 'Cheapest' } |
            Should -Throw "*BestEffort*"
        { New-VmfPlan -AssessmentPath 'never-read.json' -OutPath 'never-written' -CapacityGate @{ prod = 'Nope' } } |
            Should -Throw "*BestEffort*"
    }
}

Describe 'SCOPE-1: discovery scope beyond one resource group' {
    It 'a management group scope goes to Resource Graph as managementGroups' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                $script:argBody = $Payload | ConvertFrom-Json -Depth 10
                [pscustomobject]@{ StatusCode = 200; Content = (@{ data = @() } | ConvertTo-Json) }
            }
            Get-VmfFleetInventory -ManagementGroup 'mg-root' | Out-Null
            $script:argBody.managementGroups | Should -Be @('mg-root')
            $script:argBody.PSObject.Properties.Name | Should -Not -Contain 'subscriptions'
        }
    }

    It 'multiple subscriptions pass through together' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                $script:argBody = $Payload | ConvertFrom-Json -Depth 10
                [pscustomobject]@{ StatusCode = 200; Content = (@{ data = @() } | ConvertTo-Json) }
            }
            Get-VmfFleetInventory -Subscriptions @('s1', 's2', 's3') | Out-Null
            @($script:argBody.subscriptions).Count | Should -Be 3
        }
    }

    It 'refuses to run with no declared scope at all' {
        InModuleScope VmMigrationFactory {
            { Get-VmfFleetInventory } | Should -Throw '*scope*'
        }
    }
}

Describe 'WAVE-1: wave grouping without tags' {
    BeforeAll {
        $script:mk = {
            param($name, $ring, $app, $rg, $avset)
            [pscustomobject]@{ vmId = "/vm/$name"; ring = $ring; appGroup = $app
                               resourceGroup = $rg; availabilitySetId = $avset }
        }
    }

    It 'groups by resource group when no useful app tags exist' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mk } {
            $entries = @(
                & $mk 'a' 'lab' 'a' 'rg-one' ''      # appGroup defaults to the VM name = no grouping
                & $mk 'b' 'lab' 'b' 'rg-one' ''
                & $mk 'c' 'lab' 'c' 'rg-two' ''
            )
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            $w['/vm/a'] | Should -Be $w['/vm/b'] -Because 'one resource group migrates together'
            $w['/vm/c'] | Should -Not -Be $w['/vm/a']
        }
    }

    It 'singleWave puts EVERYTHING in one wave with no size cap' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mk } {
            $entries = 1..40 | ForEach-Object { & $mk "vm$_" 'x' "app$_" 'rg-one' '' }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'singleWave'
            @($w.Values | Sort-Object -Unique) | Should -Be @('wave-1')
        }
    }

    It 'availability-set members NEVER split, whatever the strategy (WAVE-1 safety)' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mk } {
            foreach ($strategy in 'tags', 'resourceGroup') {
                # different app tags AND different resource groups - only the
                # availability set holds them together
                $entries = @(
                    & $mk 'pair1' 'lab' 'app-x' 'rg-one' '/avsets/set1'
                    & $mk 'pair2' 'lab' 'app-y' 'rg-two' '/avsets/set1'
                    & $mk 'filler' 'lab' 'app-z' 'rg-three' ''
                )
                $w = Get-VmfWaveAssignments -Entries $entries -Strategy $strategy
                $w['/vm/pair1'] | Should -Be $w['/vm/pair2'] -Because "$strategy must keep an availability set together"
            }
        }
    }

    It 'waves carry NEUTRAL names - no environment vocabulary is ever generated' {
        # WAVE-2: the old names were <ring>-<n>, which put OUR four invented
        # words on the customer's screen. wave-<n> is a starting name they
        # rename in the editor, and nothing more.
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mk } {
            $entries = @(
                & $mk 'a' 'x' 'a' 'rg1' ''
                & $mk 'b' 'x' 'b' 'rg2' ''
            )
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            @($w.Values) | ForEach-Object { $_ | Should -Match '^wave-\d+$' }
            @($w.Values | Sort-Object -Unique).Count | Should -Be 2
            foreach ($word in 'lab', 'canary', 'nonprod', 'prod') {
                @($w.Values) -join ' ' | Should -Not -Match $word
            }
        }
    }

    It 'New-VmfPlan rejects an unknown grouping strategy' {
        { New-VmfPlan -AssessmentPath 'x.json' -OutPath 'y' -WaveStrategy 'vibes' } | Should -Throw
    }
}

Describe 'WAVE-1: choosing WHICH tag groups machines' {
    It 'the assessment keeps every tag, not just the two convention keys' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; zones = @()
                tags = [pscustomobject]@{ service = 'billing'; owner = 'finance'; costCentre = '42' }
            }
            $r = Get-VmfAssessmentRecord -Vm $vm
            $r.tags.service | Should -Be 'billing'
            $r.tags.costCentre | Should -Be '42' -Because 'any tag can become the grouping tag later'
        }
    }

    It 'a chosen app tag groups machines that no convention tag would have grouped' {
        InModuleScope VmMigrationFactory {
            $mk = {
                param($n, $svc)
                [pscustomobject]@{ vmId = "/vm/$n"; name = $n; classification = 'ReadyAfterPrep'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; os = 'Linux'; gen = 'V2'
                    location = 'centralus'; zones = @(); blockers = @(); prepNeeded = @()
                    resourceGroup = 'rg'; availabilitySetId = ''
                    tags = [pscustomobject]@{ service = $svc } }
            }
            # no 'app' or 'ring' tag anywhere - only 'service'
            $vms = @((& $mk 'a' 'billing'), (& $mk 'b' 'billing'), (& $mk 'c' 'storefront'))
            $entries = foreach ($vm in $vms) {
                $prop = $vm.tags.PSObject.Properties | Where-Object { $_.Name -ieq 'service' } | Select-Object -First 1
                [pscustomobject]@{ vmId = $vm.vmId; ring = 'lab'; appGroup = [string]$prop.Value
                                   resourceGroup = 'rg'; availabilitySetId = '' }
            }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'tags'
            $w['/vm/a'] | Should -Be $w['/vm/b'] -Because 'the chosen tag groups them'
            $w['/vm/c'] | Should -Not -Be $w['/vm/a']
        }
    }

    It 'the "none" strategy assigns nothing - a blank canvas to compose by hand' {
        InModuleScope VmMigrationFactory {
            $entries = @([pscustomobject]@{ vmId = '/vm/a'; ring = 'lab'; appGroup = 'a'; resourceGroup = 'rg'; availabilitySetId = '' })
            (Get-VmfWaveAssignments -Entries $entries -Strategy 'none').Count | Should -Be 0
        }
    }
}


Describe 'Module hygiene: one command per file' {
    # The module publishes commands BY FILENAME (Export-ModuleMember uses each
    # Public file's BaseName), so a second command hiding in a file is simply
    # never published - it silently does not exist. Caught live when four
    # schedule commands shared one file and only one loaded.
    It 'every Public file defines exactly the one command it is named after' {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $offenders = foreach ($file in Get-ChildItem (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'Public') -Filter '*.ps1') {
            $names = [regex]::Matches((Get-Content $file.FullName -Raw), '(?m)^function\s+([A-Za-z][A-Za-z0-9-]*)') |
                ForEach-Object { $_.Groups[1].Value }
            if (@($names).Count -ne 1) { "$($file.Name) defines $(@($names).Count): $($names -join ', ')" }
            elseif (@($names)[0] -ne $file.BaseName) { "$($file.Name) defines '$($names[0])'" }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty -Because 'anything else is never published'
    }

    It 'every published command actually loads' {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
        foreach ($name in $manifest.FunctionsToExport) {
            Get-Command $name -Module VmMigrationFactory -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$name is listed as published"
        }
    }
}

Describe 'BOUNDARY-1: the assessment survives Resource Graph throttling' {
    # Found while reviewing the boundary debt: the Resource Graph paging loop
    # threw on ANY non-200, including 429 TooManyRequests, with no retry -
    # while Invoke-VmfAzOperation exists precisely to retry those with backoff.
    # Resource Graph throttles hard and this is a FLEET-scale tool paging
    # through thousands of machines, so a large scan could die on a throttle
    # and lose the whole assessment. That is a robustness defect, not tidiness.
    It 'retries a 429 instead of losing the whole scan' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            Mock Invoke-AzRestMethod {
                $script:calls++
                if ($script:calls -eq 1) {
                    return [pscustomobject]@{ StatusCode = 429; Content = '{"error":"TooManyRequests"}' }
                }
                [pscustomobject]@{ StatusCode = 200; Content = '{"data":[{"id":"/vm/1","name":"a"}]}' }
            }
            $rows = @(Get-VmfFleetInventory -Subscriptions @('sub-1'))
            $script:calls | Should -BeGreaterThan 1 -Because 'the first attempt was throttled'
            $rows.Count | Should -Be 1 -Because 'the scan completed after the retry'
        }
    }

    It 'still fails fast on an error that retrying cannot fix' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 403; Content = '{"error":"AuthorizationFailed"}' }
            }
            { Get-VmfFleetInventory -Subscriptions @('sub-1') } | Should -Throw '*403*'
        }
    }

    It 'the whole module keeps ARM calls behind the boundary, not just the engine' {
        # CLAUDE.md rule 3, enforced across the WHOLE module rather than one
        # folder. Two real defects came out of this rule being unenforced:
        # NIC-1 found bare Az calls in NIC validation and in ROLLBACK (no
        # retry, no heartbeat - the watchdog-reaping bug class), and
        # BOUNDARY-1 found the Resource Graph scan losing everything to a 429.
        #
        # QUOTA-BOUNDARY-1 CHANGED WHAT THIS CHECKS, because the name overstated
        # it. It used to pass any Az call that sat inside Invoke-VmfAzOperation,
        # wherever it lived - which is the RETRY rule, not the boundary rule.
        # Request-VmfQuota's PUT was wrapped and outside azureops, so this test
        # was green while the rule was broken. Its own tests still passed too -
        # they mock Invoke-AzRestMethod, which Pester replaces wherever it
        # lives - so nothing anywhere was reporting the breach.
        #
        # Now: an ARM call outside Private/azureops/ fails, wrapped or not.
        # Get-AzContext is still allowed anywhere - it reads local session
        # state and makes no ARM call.
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $allowedAnywhere = @('Get-AzContext')
        # BOUNDARY-2 moved the six that were here, so the rule has no debt at
        # all. The table stays as an EMPTY one on purpose: it is where a future
        # exemption would have to be written down and counted, rather than
        # added as a silent skip.
        $knownDebt = @{}
        $found = @{}
        $bare = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem (Join-Path $root 'src' 'VmMigrationFactory') -Filter *.ps1 -Recurse) {
            if ($file.FullName -like '*azureops*') { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($cmd in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $cmd.GetCommandName()
                if ($name -notmatch '^(Get|Set|New|Remove|Update|Start|Stop|Restart|Invoke)-Az') { continue }
                if ($allowedAnywhere -contains $name) { continue }
                if ($knownDebt.ContainsKey($file.Name)) {
                    $found[$file.Name] = [int]$found[$file.Name] + 1
                    continue
                }
                $bare.Add("$($file.Name):$($cmd.Extent.StartLineNumber) $name")
            }
        }
        $bare -join ', ' | Should -BeNullOrEmpty -Because 'an ARM call outside Private/azureops/ cannot be mocked, so the code that uses it cannot be tested'
        foreach ($file in $knownDebt.Keys) {
            [int]$found[$file] | Should -BeLessOrEqual $knownDebt[$file] -Because "$file may only lose ARM calls to BOUNDARY-2, never gain them"
        }
    }
}

Describe 'ASSESS-2(a): an unmanaged OS disk is BLOCKED, and said so up front' {
    # This tool works on managed disks throughout - snapshots, capability
    # patches, capture, recreate. A machine still on a blob VHD cannot be
    # migrated by it at all, and today it got as far as PRECHECK before failing
    # messily on a capture that assumes a managed disk.
    It 'blocks a machine whose OS disk is a page blob' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/old'; name = 'old'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
                osDiskVhdUri = 'https://acct.blob.core.windows.net/vhds/old.vhd'; osDiskManagedId = ''
                nicCount = 1
            }
            $r = Get-VmfAssessmentRecord -Vm $vm
            $r.classification | Should -Be 'Blocked'
            $r.blockers | Should -Contain 'unmanaged-os-disk'
            $r.hasManagedOsDisk | Should -BeFalse
        }
    }

    It 'says what to do about it in plain words' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/old'; name = 'old'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                osDiskVhdUri = 'https://acct.blob.core.windows.net/vhds/old.vhd'; osDiskManagedId = ''
                nicCount = 1
            }
            (Get-VmfAssessmentRecord -Vm $vm).notes -join ' ' | Should -Match '(?i)convert it to a managed disk first'
        }
    }

    It 'and leaves a normal managed machine alone' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/ok'; name = 'ok'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/ok'; osDiskVhdUri = ''; nicCount = 1
            }
            $r = Get-VmfAssessmentRecord -Vm $vm
            $r.blockers | Should -Not -Contain 'unmanaged-os-disk'
            $r.hasManagedOsDisk | Should -BeTrue
        }
    }
}

Describe 'AN-1: the assessment records accelerated networking as a fact' {
    # It recorded nicCount and nothing else, so an AN layout that would not fit
    # its target surfaced at plan time or PRECHECK - not in the report someone
    # reads to decide. Recorded, never JUDGED here: whether it fits depends on
    # the target size, which is a planning decision (NIC-1).
    It 'counts the interfaces that have it on' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 2
                nicIds = @([pscustomobject]@{ id = '/s/rg/nic/one' }, [pscustomobject]@{ id = '/s/rg/nic/two' })
            }
            $map = @{ '/s/rg/nic/one' = $true; '/s/rg/nic/two' = $false }
            $r = Get-VmfAssessmentRecord -Vm $vm -NicAcceleratedMap $map
            $r.acceleratedNicCount | Should -Be 1
            $r.notes -join ' ' | Should -Match 'accelerated networking is on 1 of 2'
        }
    }

    It 'says nothing at all when the interfaces could not be read' {
        # $null means "not looked up", which is NOT the same as "none are on".
        # Reporting zero would be a reassuring answer we cannot support.
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 2
                nicIds = @([pscustomobject]@{ id = '/s/rg/nic/one' })
            }
            $r = Get-VmfAssessmentRecord -Vm $vm -NicAcceleratedMap $null
            $r.acceleratedNicCount | Should -BeNullOrEmpty
            $r.notes -join ' ' | Should -Not -Match 'accelerated networking'
        }
    }

    It 'and an interface missing from the map does not count as off' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 2
                nicIds = @([pscustomobject]@{ id = '/s/rg/nic/one' }, [pscustomobject]@{ id = '/s/rg/nic/unreadable' })
            }
            $map = @{ '/s/rg/nic/one' = $true }
            $r = Get-VmfAssessmentRecord -Vm $vm -NicAcceleratedMap $map
            # one KNOWN interface, and it is on - the unreadable one is not
            # counted as a denominator we cannot vouch for
            $r.notes -join ' ' | Should -Match 'on 1 of 1'
        }
    }
}

Describe 'WAVE-GROUP-1: a wave holds ONE group, of any size' {
    # WAVE-SIZE-REMOVE-1 (2026-11-08): the cap is gone. It was a
    # ceiling that cut a large group into several waves.
    # MEASURED 2026-09-16, before the fix: three resource groups and four
    # machines at the default cap produced ONE wave holding all of them.
    # Choosing "group by resource group" produced no grouping at all.
    #
    # The old code kept a group from being SPLIT and then filled the wave up
    # with the next group, and the next, until the cap. Sixty tests passed over
    # it, because every one of them used a cap small enough that the packing
    # never showed - which is why these say what the ANSWER is, not that a
    # particular pair landed together.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
        Block-VmfAzureCalls -TestFile $PSCommandPath
        $script:mkv = {
            param($name, $app, $rg, $avset = '')
            [pscustomobject]@{ vmId = "/vm/$name"; ring = 'x'; appGroup = $app
                               resourceGroup = $rg; availabilitySetId = $avset }
        }
        # How many distinct values of one property share a wave, at worst.
        $script:mixing = {
            param($assignment, $entries, $property)
            $byWave = @{}
            foreach ($e in $entries) {
                $wave = $assignment[$e.vmId]
                if (-not $byWave.ContainsKey($wave)) { $byWave[$wave] = [System.Collections.Generic.HashSet[string]]::new() }
                [void]$byWave[$wave].Add([string]$e.$property)
            }
            ($byWave.Values | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
        }
    }

    It 'THE DEFECT: three resource groups make three waves' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv; mixing = $script:mixing } {
            $entries = @(
                & $mk 'a' 'web'  'rg-one'
                & $mk 'b' 'web'  'rg-one'
                & $mk 'c' 'data' 'rg-two'
                & $mk 'd' 'etl'  'rg-three')
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            @($w.Values | Sort-Object -Unique).Count | Should -Be 3 -Because 'resource groups are never merged'
            (& $mixing $w $entries 'resourceGroup') | Should -Be 1 -Because 'a wave held two resource groups'
        }
    }

    It 'and grouping by tag keeps two applications apart' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv; mixing = $script:mixing } {
            $entries = @(
                & $mk 'a' 'web'  'rg-one'
                & $mk 'b' 'web'  'rg-one'
                & $mk 'c' 'data' 'rg-two'
                & $mk 'd' 'etl'  'rg-three')
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'tags'
            (& $mixing $w $entries 'appGroup') | Should -Be 1 -Because 'a wave held two applications'
        }
    }

    It 'WAVE-SIZE-REMOVE-1: a group of 30 is one wave - there is no ceiling to cut it at' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            $entries = 1..30 | ForEach-Object { & $mk "vm$_" "app$_" 'rg-big' }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            @($w.Values | Sort-Object -Unique) | Should -Be @('wave-1') -Because 'How many machines at once controls the wave; nothing cuts a group'
        }
    }

    It 'and an availability set is NEVER cut' {
        # Its members are a real dependency the engine serialises anyway.
        # An oversized wave is the honest answer; a split one is a broken run.
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            $entries = 1..8 | ForEach-Object { & $mk "vm$_" "app$_" 'rg-one' '/avsets/set1' }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            @($w.Values | Sort-Object -Unique).Count | Should -Be 1 -Because 'an availability set moves together'
        }
    }

    It 'and never shares its wave with a machine outside it' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            $entries = @(
                & $mk 'pair1' 'web' 'rg-one' '/avsets/set1'
                & $mk 'pair2' 'web' 'rg-one' '/avsets/set1'
                & $mk 'alone' 'web' 'rg-one')
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            $w['/vm/pair1'] | Should -Be $w['/vm/pair2']
            $w['/vm/alone'] | Should -Not -Be $w['/vm/pair1'] -Because 'the set is its own group'
        }
    }

    It 'the same estate makes the same waves, every time' {
        # ACCEPT-HASH-1 binds an acceptance to the plan that was on screen. A
        # wave order that came out of enumeration order is not the same plan
        # twice, and the person would be accepting something else.
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            $entries = @(
                & $mk 'a' 'web'  'rg-zulu'
                & $mk 'b' 'data' 'rg-alpha'
                & $mk 'c' 'etl'  'rg-mike')
            # The entries arrive zulu, alpha, mike. The waves come out in the
            # GROUP's order, not the order the estate happened to be read in.
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            $w['/vm/b'] | Should -Be 'wave-1' -Because 'rg-alpha sorts first'
            $w['/vm/c'] | Should -Be 'wave-2' -Because 'rg-mike sorts second'
            $w['/vm/a'] | Should -Be 'wave-3' -Because 'rg-zulu sorts last'
            # And the same estate read in any order gives the same answer.
            $reversed = @($entries[2], $entries[0], $entries[1])
            $again = Get-VmfWaveAssignments -Entries $reversed -Strategy 'resourceGroup'
            foreach ($id in $w.Keys) { $again[$id] | Should -Be $w[$id] -Because "$id moved when the estate was read in another order" }
        }
    }

    It 'one wave for everything still means one wave, with no ceiling' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            $entries = 1..40 | ForEach-Object { & $mk "vm$_" "app$_" "rg$_" }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'singleWave'
            @($w.Values | Sort-Object -Unique) | Should -Be @('wave-1')
        }
    }

    It 'and building them yourself still starts with none' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            (Get-VmfWaveAssignments -Entries @(& $mk 'a' 'web' 'rg-one') -Strategy 'none').Count | Should -Be 0
        }
    }
}

Describe 'ODCR-FAMILY-1: two sizes that share a quota family compete for one pool' {
    # THE QUESTION, 2026-09-17: do the on-demand capacity reservation and
    # quota checks on a wave honor the VM types? A wave can hold several VM
    # families and need several checks.
    #
    # The forecast already splits a wave by subscription, region, zone and
    # SIZE, so several machine types do get several checks. That half is right.
    #
    # THE HOLE IS UNDERNEATH IT: quota is not per size, it is per FAMILY. Two
    # sizes in one plan can bill to the SAME pool, and each cell was checked on
    # its own against the same live headroom - so both could pass while their
    # sum did not fit. The wave then meets QuotaExceeded partway through, with
    # machines already stopped.
    #
    # CLAUDE.md makes it likelier than it looks: 's'-suffix v6 sizes bill under
    # the general d_v6 family, so sizes that look unrelated share a pool. The
    # family comes from the SKU catalog, never from the name - that part was
    # already right, and is what makes this checkable.

    BeforeEach {
        $script:famRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-fam-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:famRun -Force | Out-Null
        # ONE wave, TWO sizes, ONE family. Four machines: 2 x D2s_v6 (2 vCPU
        # each) and 2 x D4s_v6 (4 vCPU each) = 4 + 8 = 12 vCPUs of one family.
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        $plan = @{
            schemaVersion = 1; assessmentRunId = 'r1'
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/vma"; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6'; zone = $null } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/vmb"; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6'; zone = $null } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/vmc"; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D4s_v6'; zone = $null } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/vmd"; wave = 'prod-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D4s_v6'; zone = $null } }
            )
        }
        $script:famPlan = Join-Path $script:famRun 'plan.json'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:famPlan

        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @(
                (NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
                (NewSkuEntry -Name 'Standard_D4s_v6' -Family 'StandardDsv6Family' -Vcpus 4)
            )
        }
    }
    AfterEach { if (Test-Path $script:famRun) { Remove-Item $script:famRun -Recurse -Force } }

    It 'THE DEFECT: each cell fits alone, and together they do not' {
        # Headroom 8. The D2s cell needs 4 and the D4s cell needs 8: each one
        # fits on its own, and 12 does not fit in 8. Before this rule both
        # answered QUOTA_VERIFIED and the wave was started on a promise the
        # subscription could not keep.
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 8 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        @($result.Claims).Count | Should -Be 2 -Because 'two sizes are still two cells - reservations are per size'
        @($result.Blocked).Count | Should -Be 2 -Because 'the FAMILY does not fit, so neither cell can be promised'
        (@($result.Blocked).notes -join ' ') | Should -Match 'needs 12 vCPUs'
        (@($result.Blocked).notes -join ' ') | Should -Match 'headroom 8'
    }

    It 'and it names the OTHER sizes sharing the pool, so the reason is findable' {
        # A cell blocked by a sibling it does not name is a cell nobody can act
        # on: the operator looks at 4 vCPUs of D2s, sees headroom of 8, and has
        # no way to know what took it.
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 8 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        $small = @($result.Blocked) | Where-Object size -eq 'Standard_D2s_v6'
        ($small.notes -join ' ') | Should -Match 'Standard_D4s_v6' -Because 'the sibling that shares the pool must be named'
    }

    It 'and the whole family fitting is still verified' {
        # The rule must not simply refuse everything. Headroom 12, demand 12.
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 12 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        @($result.Blocked).Count | Should -Be 0
        foreach ($claim in @($result.Claims)) { $claim.state | Should -Be 'QUOTA_VERIFIED' }
    }

    It 'and usage ALREADY on the subscription still counts' {
        # Headroom is limit minus what is running now, and the plan's own
        # demand comes out of what is left. Limit 16, used 6, demand 12.
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 6; Limit = 16 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        @($result.Blocked).Count | Should -Be 2
        (@($result.Blocked).notes -join ' ') | Should -Match 'headroom 10'
    }

    It 'DIFFERENT families do not take each other''s headroom' {
        # The rule is about a SHARED pool. Two genuinely separate families are
        # independent, and treating them as one would block plans that fit.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D4s_v6' -Family 'StandardDdsv6Family' -Vcpus 4))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 4 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 8 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        @($result.Blocked).Count | Should -Be 0 -Because '4 of one family and 8 of another each fit their own pool'
    }
    # QUOTA-FAMILY-1 (issue 425): the dashboard shows one row per family, with
    # vCPUs needed against vCPUs free. The number it shows must be THIS one -
    # the family total the check judged - not a sum the page makes from the
    # records it can see. A finished wave's records are never rewritten (its
    # machines leave the plan's demand), so a page sum counted moved machines
    # for ever, beside a reading whose "used" already held them.
    It 'QUOTA-FAMILY-1: every record carries the family total it was judged on' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 12 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        foreach ($claim in @($result.Claims)) {
            $claim.demand.familyVcpus | Should -Be 12 -Because 'both sizes draw on one pool of 4 + 8'
        }
        (@($result.Claims) | Where-Object size -eq 'Standard_D2s_v6').demand.vcpus | Should -Be 4 -Because 'the cell keeps its own demand beside it'
    }

    It 'and a machine that has migrated is not in the family total' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 12 })
        }
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        InModuleScope VmMigrationFactory -Parameters @{ RunPath = $script:famRun; VmId = "$sub/vmc" } {
            param($RunPath, $VmId)
            Initialize-VmfStore -RunPath $RunPath
            Write-VmfStoreJson -RunPath $RunPath -RelPath 'state/vmc.json' -Document @{ vmId = $VmId; state = 'MIGRATED' }
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        foreach ($claim in @($result.Claims)) {
            $claim.demand.familyVcpus | Should -Be 8 -Because 'one D4s machine has moved: 2 x 2 + 1 x 4 are left'
        }
    }

    It 'and a size the region does not offer has no family, so no family total' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 12 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        $missing = @($result.Claims) | Where-Object size -eq 'Standard_D4s_v6'
        $missing.demand.familyVcpus | Should -BeNullOrEmpty -Because 'a total for a family nobody named would be a guess'
        (@($result.Claims) | Where-Object size -eq 'Standard_D2s_v6').demand.familyVcpus | Should -Be 4
    }
    It 'and a catalog entry with an EMPTY family has no family total, not 0' {
        # Found by mutation: removing the family guard survived, because a size
        # the region does not offer never reaches it. A catalog entry that
        # names no family does - and 0 would read as "this family needs
        # nothing".
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((NewSkuEntry -Name 'Standard_D2s_v6' -Family 'StandardDsv6Family' -Vcpus 2),
              (NewSkuEntry -Name 'Standard_D4s_v6' -Family '' -Vcpus 4))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 12 })
        }
        $result = Test-VmfQuota -PlanPath $script:famPlan -OutPath $script:famRun
        $unnamed = @($result.Claims) | Where-Object size -eq 'Standard_D4s_v6'
        $null -eq $unnamed.demand.familyVcpus | Should -BeTrue -Because 'no family, so no total - null, never 0'
    }
}

