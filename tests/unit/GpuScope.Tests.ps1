#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GPU-SCOPE-1: GPU sizes (NC, ND, NG, NV) are outside the scope of this tool.
#
# Since 2026-10-09, GPU sizes are outside the scope. Found by a copy of
# the target logic run on a real customer sheet: a Generation 1 machine on
# Standard_NC8as_T4_v3 was given a plain D or E v5 size by its vCPUs and
# memory (the shape choices), which DROPS THE GPU; a Generation 2 one was told
# its region had no size of its family, which reads as capacity, not scope.
#
# So the rule is the OLD-FAM-3 rule for one more family: a blocker the scan
# records, words that say SCOPE (never an invented technical limit), no
# Generation 1 route - and, as RETIRE-SCOPE-1 did for a retired size, the
# same answer from the target rules themselves, so an assessment made before
# this change cannot hand a GPU machine a size either.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json

    # Azure's figures for these sizes: vCPUs, memory, temp disk MB, generations.
    function Global:GsSku([string]$Name, [double]$Vcpus, [double]$MemoryGB, [string]$TempMb = '0', [string]$Gens = 'V1,V2') {
        $caps = @(
            [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '8' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }
            [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' })
        [pscustomobject]@{ Name = $Name; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    # A region where every GPU machine below WOULD fit a D, Dl or E size by
    # shape, so a missing rule shows as a target.
    function Global:GsCatalog {
        $c = @{}
        foreach ($s in @(
                (GsSku 'Standard_NC8as_T4_v3' 8 56 '360448'), (GsSku 'Standard_NV12ads_A10_v5' 12 110 '368640' 'V2'),
                (GsSku 'Standard_NG8ads_V620_v1' 8 16 '262144' 'V2'), (GsSku 'Standard_ND6s' 6 112 '344064'),
                (GsSku 'Standard_D2s_v4' 2 8 '0'),
                (GsSku 'Standard_D8lds_v5' 8 16 '307200'), (GsSku 'Standard_D8ds_v5' 8 32 '307200'), (GsSku 'Standard_D16ds_v5' 16 64 '614400'),
                (GsSku 'Standard_D32ds_v5' 32 128 '1228800'),
                (GsSku 'Standard_E8ds_v5' 8 64 '307200'), (GsSku 'Standard_E16ds_v5' 16 128 '614400'),
                (GsSku 'Standard_D2s_v5' 2 8 '0'), (GsSku 'Standard_D2s_v6' 2 8 '0' 'V2'), (GsSku 'Standard_D2s_v7' 2 8 '0' 'V2'),
                (GsSku 'Standard_D8lds_v6' 8 16 '0' 'V2'), (GsSku 'Standard_D8ds_v6' 8 32 '0' 'V2'), (GsSku 'Standard_D16ds_v6' 16 64 '0' 'V2'),
                (GsSku 'Standard_E8ds_v6' 8 64 '0' 'V2'), (GsSku 'Standard_E16ds_v6' 16 128 '0' 'V2'),
                (GsSku 'Standard_D8ds_v7' 8 32 '0' 'V2'), (GsSku 'Standard_E16ds_v7' 16 128 '0' 'V2'))) { $c[$s.Name] = $s }
        $c
    }
    # One assessed machine, as the target advice reads it. $Blockers empty is
    # an assessment made BEFORE this change - the case the target rules must
    # catch on their own.
    function Global:GsVm([string]$Size, [string]$Gen, [string[]]$Blockers = @()) {
        [pscustomobject]@{ vmId = "/s/rg/vm/$Size-$Gen"; name = "m-$Gen"; location = 'centralus'; gen = $Gen; os = 'Linux'; osVersion = '22.04-LTS'
            classification = $(if (@($Blockers).Count) { 'Blocked' } else { 'ReadyAfterPrep' }); blockers = @($Blockers); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = 0
            nicCount = 1; acceleratedNicCount = 0; platformManaged = $false }
    }
    function Global:GsAdvice($Vm) {
        $cat = GsCatalog
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = $cat } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
    }
    function Global:GsScan([string]$Size, [string]$Gen) {
        $vm = [pscustomobject]@{ vmId = '/s/rg/vm/g1'; name = 'g1'; sku = $Size; location = 'centralus'; resourceGroup = 'rg'
            os = 'Linux'; gen = $Gen; tags = @{}; nicIds = @(); dataDiskCount = 0; osDiskManaged = $true; securityType = '' }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -NicAcceleratedMap @{} -ManagedPlatformGroups @{} -SapSystemVms @{} -AvdSessionHosts @{} }
    }
    $script:gpuSizes = @('Standard_NC8as_T4_v3', 'Standard_NV12ads_A10_v5', 'Standard_ND6s', 'Standard_NG8ads_V620_v1')
}
AfterAll {
    Remove-Item function:GsSku, function:GsCatalog, function:GsVm, function:GsAdvice, function:GsScan, function:GsPlanned, function:GsId,
        function:GsAssessed, function:GsSmallSku, function:GsDropDir, function:GsLiveVm, function:GsPlanEntry -ErrorAction SilentlyContinue
}

Describe 'GPU-SCOPE-1: which sizes are GPU sizes' {
    It 'every GPU family - NC, ND, NG, NV - and the confidential GPU sizes' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_NC8as_T4_v3', 'Standard_NC6s_v3', 'Standard_NC24ads_A100_v4', 'Standard_NC40ads_H100_v5', 'Standard_NCC40ads_H100_v5',
                'Standard_ND6s', 'Standard_ND40rs_v2', 'Standard_ND96asr_v4', 'Standard_ND96isr_H100_v5',
                'Standard_NG8ads_V620_v1', 'Standard_NG32ads_V620_v1',
                'Standard_NV12ads_A10_v5', 'Standard_NV6ads_A10_v5', 'Standard_NV12s_v3', 'Standard_NV4as_v4', 'Standard_NV6') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -Be 'gpu-size' -Because $s
            }
        }
    }

    It 'NP is FPGA, not GPU - it keeps hpc-or-fpga-size' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_NP10s', 'Standard_NP20s', 'Standard_NP40s') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -Be 'hpc-or-fpga-size' -Because $s
            }
        }
    }

    It 'a size the tool moves is not touched' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_D2s_v4', 'Standard_D8ds_v5', 'Standard_E8-4ds_v5', 'Standard_B2s', 'Standard_F8s_v2', 'Standard_D4_v2', '') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -BeNullOrEmpty -Because $s
            }
        }
    }
}

Describe 'GPU-SCOPE-1: the scan names it' {
    It 'a machine on each GPU family gets the gpu-size blocker, Generation 1 and Generation 2' {
        foreach ($s in $script:gpuSizes) {
            foreach ($g in 'V1', 'V2') {
                $r = GsScan $s $g
                @($r.blockers) | Should -Contain 'gpu-size' -Because "$s $g"
                $r.classification | Should -Be 'Blocked' -Because "$s $g"
            }
        }
    }

    It 'NP still gets the FPGA blocker and not the GPU one' {
        $r = GsScan 'Standard_NP10s' 'V2'
        @($r.blockers) | Should -Contain 'hpc-or-fpga-size'
        @($r.blockers) | Should -Not -Contain 'gpu-size'
    }

    It 'a D size machine gets no scope blocker' {
        $r = GsScan 'Standard_D2s_v4' 'V2'
        @($r.blockers) | Should -Not -Contain 'gpu-size'
        @($r.blockers) | Should -Not -Contain 'hpc-or-fpga-size'
    }
}

Describe 'GPU-SCOPE-1: the words say scope' {
    It 'the reason exists, applies to every series, and links Microsoft' {
        $r = $script:reasons.blockers.'gpu-size'
        $r | Should -Not -BeNullOrEmpty
        @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
        $r.docs.url | Should -Match '^https://learn\.microsoft\.com/'
    }

    It 'THE RULE: scope, and no invented technical limit' {
        $r = $script:reasons.blockers.'gpu-size'
        $r.title | Should -Match 'not in scope'
        $r.meaning | Should -Match 'outside the scope of this tool'
        foreach ($field in 'meaning', 'whatToDo') {
            $r.$field | Should -Not -Match 'cannot|impossible|does not survive|no D or E size has' -Because $field
        }
    }

    It 'the target options file may carry it' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json
        @($schema.'$defs'.reason.enum) | Should -Contain 'gpu-size'
    }
}

Describe 'GPU-SCOPE-1: no target on any series' {
    It 'a machine with the blocker: nothing supported on v5, v6 or v7, the reason is gpu-size' {
        foreach ($s in $script:gpuSizes) {
            foreach ($g in 'V1', 'V2') {
                $advice = GsAdvice (GsVm $s $g @('gpu-size'))
                $m = $advice.machines[0]
                foreach ($series in 'v5', 'v6', 'v7') {
                    $o = @($m.options | Where-Object { $_.option -eq $series })[0]
                    $o.supported | Should -BeFalse -Because "$s $g $series"
                    @($o.notSupported) | Should -Contain 'gpu-size' -Because "$s $g $series"
                    $o.targetSize | Should -BeNullOrEmpty -Because "$s $g $series - no arrow to a size it is not going to"
                    @($o.sizeChoices).Count | Should -Be 0 -Because "$s $g $series - no shape choice"
                }
                @($m.options.option) | Should -Be @('v5', 'v6', 'v7') -Because "$s $g"
                $m.start.current | Should -BeNullOrEmpty
                $m.start.extended | Should -BeNullOrEmpty
            }
        }
    }

    It 'THE CASE: an assessment made before this change (no blocker) - the target rules refuse it all the same' {
        foreach ($s in $script:gpuSizes) {
            foreach ($g in 'V1', 'V2') {
                $advice = GsAdvice (GsVm $s $g)
                $m = $advice.machines[0]
                foreach ($series in 'v5', 'v6', 'v7') {
                    $o = @($m.options | Where-Object { $_.option -eq $series })[0]
                    $o.supported | Should -BeFalse -Because "$s $g $series"
                    @($o.notSupported) | Should -Contain 'gpu-size' -Because "$s $g $series - scope, not capacity"
                    $o.targetSize | Should -BeNullOrEmpty -Because "$s $g $series"
                    @($o.sizeChoices).Count | Should -Be 0 -Because "$s $g $series"
                }
                @($m.options.option) | Should -Be @('v5', 'v6', 'v7') -Because "$s $g"
            }
        }
    }

    It 'the plan and the wave editor: a size chosen by shape before is refused, with the scope reason' {
        $vm = GsVm 'Standard_NC8as_T4_v3' 'V1'
        $cat = GsCatalog
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_E8ds_v5'
        }
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'gpu-size'
        $t.Mapping.Reason | Should -Match 'outside the scope of this tool'
        @($t.Blockers) | Should -Contain 'gpu-size'
        $t.Classification | Should -Be 'Blocked'
        @($t.SizeChoices).Count | Should -Be 0
    }

    It 'NP keeps its own reason, and a D size machine still gets its target' {
        $np = GsAdvice (GsVm 'Standard_NP10s' 'V1' @('hpc-or-fpga-size'))
        $v5 = @($np.machines[0].options | Where-Object { $_.option -eq 'v5' })[0]
        @($v5.notSupported) | Should -Contain 'hpc-or-fpga-size'
        @($v5.notSupported) | Should -Not -Contain 'gpu-size'

        $d = GsAdvice (GsVm 'Standard_D2s_v4' 'V2')
        foreach ($series in 'v5', 'v6', 'v7') {
            $o = @($d.machines[0].options | Where-Object { $_.option -eq $series })[0]
            @($o.notSupported) | Should -Not -Contain 'gpu-size' -Because $series
        }
        (@($d.machines[0].options | Where-Object { $_.option -eq 'v6' })[0]).targetSize | Should -Be 'Standard_D2s_v6'
        (@($d.machines[0].options | Where-Object { $_.option -eq 'v6' })[0]).supported | Should -BeTrue
    }
}

# A planned migration in a store, as the product writes it: the assessment,
# its approval, the target options, the saved targets and the plan.
function Global:GsPlanned([object[]]$Vms, [object[]]$Choices, [switch]$NoChoices) {
    $run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $run -Leaf); generatedUtc = '2026-10-09T00:00:00Z'
        scope = @{ subscriptions = @() }; summary = @{}; vms = @($Vms) }
    InModuleScope VmMigrationFactory -Parameters @{ r = $run; d = $doc } {
        param($r, $d)
        Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
        Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
    }
    Approve-VmfAssessment -RunPath $run -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
    New-VmfTargetAdvice -AssessmentPath (Join-Path $run 'assessment.json') | Out-Null
    $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $run } {
        param($r) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
    # NoChoices: a plan made with no saved targets, as New-VmfPlan run on its
    # own makes one - every machine is planned, on one series.
    if (-not $NoChoices) {
        Set-VmfTestTargetChoice -RunPath $run -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($Choices) -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
    }
    New-VmfPlan -AssessmentPath (Join-Path $run 'assessment.json') -OutPath "$run-migration" | Out-Null
    @{ Scan = $run; Mig = "$run-migration" }
}
function Global:GsId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
function Global:GsAssessed([string]$Name, [string]$Size, [string]$Gen, [string[]]$Blockers = @()) {
    [ordered]@{ vmId = (GsId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
        classification = $(if (@($Blockers).Count) { 'Blocked' } else { 'ReadyAfterPrep' }); gen = $Gen; os = 'Linux'; osVersion = '22_04-lts'
        sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1
        acceleratedNicCount = 1; primaryNicAccelerated = $true; platformManaged = $false; iacManaged = $false; hibernationEnabled = $false
        availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }; blockers = @($Blockers); prepNeeded = @() }
}
function Global:GsSmallSku([string]$Name, [string]$TempMb, [string]$Gens, [string]$Vcpus = '2', [string]$MemoryGB = '8') {
    [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
        Capabilities = @(
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
            [pscustomobject]@{ Name = 'vCPUs'; Value = $Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = $MemoryGB }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
}
function Global:GsDropDir([string]$Dir) { if ($Dir -and (Test-Path $Dir)) { [System.IO.Directory]::Delete($Dir, $true) } }

Describe 'GPU-SCOPE-1: the wave editor, on a plan made before this change (<Gen>)' -ForEach @(
    @{ Gen = 'V1'; Series = 'v5'; Planned = 'Standard_D2s_v5'; Other = 'v6'; Blockers = @('gen1-requires-redeploy') }
    @{ Gen = 'V2'; Series = 'v6'; Planned = 'Standard_D2s_v6'; Other = 'v5'; Blockers = @() }
) {
    BeforeEach {
        $script:gsCatalog = @((GsSmallSku 'Standard_D2s_v5' '0' 'V1,V2'), (GsSmallSku 'Standard_D2ds_v5' '76800' 'V1,V2'),
            (GsSmallSku 'Standard_D2s_v6' '0' 'V2'), (GsSmallSku 'Standard_D2s_v7' '0' 'V2'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:gsCatalog }
        $script:gsId = GsId 'legacy-01'
        $script:gsRun = GsPlanned -Vms @(GsAssessed 'legacy-01' 'Standard_D2s_v4' $Gen $Blockers) -Choices @(@{ vmId = $script:gsId; option = $Series })

        # The plan a GPU machine got before this change: planned on a D size
        # by its shape. Only the source size is changed here.
        $planFile = Join-Path $script:gsRun.Mig 'plan.json'
        $plan = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 40
        @($plan.entries)[0].target.size | Should -Be $Planned -Because 'the test needs a planned machine to start from'
        @($plan.entries)[0].assessment.sourceSize = 'Standard_NC8as_T4_v3'
        [System.IO.File]::WriteAllText($planFile, ($plan | ConvertTo-Json -Depth 40))
    }
    AfterEach { GsDropDir $script:gsRun.Scan; GsDropDir $script:gsRun.Mig }

    It 'the preview gives the scope reason on every series, the current one too' {
        $r = Set-VmfMachineTarget -RunPath $script:gsRun.Mig -VmId $script:gsId -WhatIf
        $r.Current | Should -Be $Series
        foreach ($s in 'v5', 'v6', 'v7') {
            $o = @($r.Options) | Where-Object option -EQ $s
            $o.supported | Should -BeFalse -Because "$s - the machine is outside the scope of this tool"
            @($o.why) | Should -Contain 'gpu-size' -Because "$s - scope, not the old reason the saved options give"
        }
    }

    It 'a change is refused in words that say scope, and the plan is not written' {
        $before = Get-Content (Join-Path $script:gsRun.Mig 'plan.json') -Raw
        { Set-VmfMachineTarget -RunPath $script:gsRun.Mig -VmId $script:gsId -Option $Other -ChangedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '*Standard_NC8as_T4_v3 is outside the scope of this tool*'
        Get-Content (Join-Path $script:gsRun.Mig 'plan.json') -Raw | Should -BeExactly $before
    }
}

Describe 'GPU-SCOPE-1: a new plan does not move a GPU machine, and asks no quota for it (<How>)' -ForEach @(
    @{ How = 'targets saved'; NoChoices = $false }
    @{ How = 'no saved targets, every machine planned on the default series'; NoChoices = $true }
) {
    BeforeEach {
        $script:gsCatalog = @((GsSmallSku 'Standard_D2s_v4' '0' 'V1,V2'), (GsSmallSku 'Standard_D2s_v5' '0' 'V1,V2'),
            (GsSmallSku 'Standard_D2s_v6' '0' 'V2'), (GsSmallSku 'Standard_D2s_v7' '0' 'V2'),
            (GsSmallSku 'Standard_NC8as_T4_v3' '360448' 'V1,V2' '8' '56'),
            (GsSmallSku 'Standard_D8ds_v5' '307200' 'V1,V2' '8' '32'), (GsSmallSku 'Standard_E8ds_v5' '307200' 'V1,V2' '8' '64'),
            (GsSmallSku 'Standard_E8ds_v6' '0' 'V2' '8' '64'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:gsCatalog }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardX' }; CurrentValue = 0; Limit = 100 }) }
        $script:gsRun = GsPlanned -Vms @(
            (GsAssessed 'app-01' 'Standard_D2s_v4' 'V2'),
            (GsAssessed 'gpu-g1' 'Standard_NC8as_T4_v3' 'V1' @('gen1-requires-redeploy', 'gpu-size')),
            (GsAssessed 'gpu-g2' 'Standard_NC8as_T4_v3' 'V2' @('gpu-size'))) `
            -Choices @(@{ vmId = (GsId 'app-01'); option = 'v6' }) -NoChoices:$NoChoices
        $script:dSize = 'Standard_D2s_v6'
    }
    AfterEach { GsDropDir $script:gsRun.Scan; GsDropDir $script:gsRun.Mig }

    It 'no GPU machine is planned to move: MANUAL with no target and in no wave, or not in the plan at all' {
        $plan = Get-Content (Join-Path $script:gsRun.Mig 'plan.json') -Raw | ConvertFrom-Json -Depth 40
        foreach ($n in 'gpu-g1', 'gpu-g2') {
            $e = @($plan.entries) | Where-Object vmId -EQ (GsId $n)
            if ($NoChoices) {
                $e | Should -Not -BeNullOrEmpty -Because "$n - with no saved targets every machine is in the plan"
                $e.path | Should -Be 'MANUAL' -Because $n
                $e.target.size | Should -BeNullOrEmpty -Because $n
                [string]$e.wave | Should -BeIn @('', 'unscheduled') -Because "$n is in no wave"
            }
            else { $e | Should -BeNullOrEmpty -Because "$n has no target to save, so it is not chosen" }
        }
        (@($plan.entries) | Where-Object vmId -EQ (GsId 'app-01')).target.size | Should -Be $script:dSize
    }

    It 'the quota check writes a record for the D machine only' {
        $r = Test-VmfQuota -PlanPath (Join-Path $script:gsRun.Mig 'plan.json') -OutPath $script:gsRun.Mig
        @($r.Claims).Count | Should -Be 1
        @($r.Claims)[0].size | Should -Be $script:dSize
        @($r.Claims)[0].demand.instances | Should -Be 1
    }
}

Describe 'GPU-SCOPE-1: capacity for a machine outside the scope of this tool (<Kind>)' -ForEach @(
    @{ Kind = 'a GPU size on an old plan'; Source = 'Standard_NC8as_T4_v3'; Retire = $false }
    @{ Kind = 'a size Microsoft retires today'; Source = 'Standard_D2s_v3'; Retire = $true }
) {
    BeforeAll {
        $script:familyFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json'
        function Global:GcEntry([string]$Name, [string]$Source, [string]$Size, [string]$Gate = 'BestEffort') {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (GsId $Name); wave = 'w1'; path = 'A'
                assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = $Source; availabilitySetId = '' }
                target = [pscustomobject]@{ size = $Size; zone = $null }
                policy = [pscustomobject]@{ capacityGate = $Gate; requireApproval = $false } }
        }
        function Global:GcPlan([string]$RunPath, [object[]]$Entries) {
            $file = Join-Path $RunPath 'plan.json'
            @{ schemaVersion = 1; assessmentRunId = 'gc'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding utf8NoBOM
            $file
        }
        # A state document. Started: past PRECHECK with the target it started
        # recorded - the move STATE-TARGET-1 finishes whatever the plan says.
        function Global:GcState([string]$RunPath, $Entry, [string]$State, [switch]$Started) {
            $doc = [ordered]@{ schemaVersion = 3; vmId = $Entry.vmId; state = $State }
            if ($Started) { $doc.captured = [ordered]@{ startedTarget = [ordered]@{ path = 'A'; target = [ordered]@{ size = $Entry.target.size } } } }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $Entry.vmId; d = $doc } {
                param($rp, $id, $d)
                Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $id) + '.json') -Document $d -Depth 8
            }
        }
        function Global:GcClaim([string]$RunPath, [string]$Name, [string]$Size, [string]$State) {
            $c = [ordered]@{ schemaVersion = 10; runId = 'gc'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                resourceGroup = 'rg-app'; region = 'centralus'; zone = $null; size = $Size; vmFamily = 'standardX'; state = $State; blockReason = $null
                demand = [ordered]@{ instances = 1; reservableInstances = 1; vcpus = 2; overlapWithSource = $false }
                quota = [ordered]@{ limit = 100; used = 0; requestId = $null; requestedUtc = $null }; notes = @() }
            if ($State -in @('RESERVED', 'CONSUMED')) {
                $c.reservation = [ordered]@{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/g'
                    reservationId = '/subscriptions/00000000-0000-0000-0000-000000000000/g/r'; createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
            }
            $dir = Join-Path $RunPath 'capacity'
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [pscustomobject]$c | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json") -Encoding utf8NoBOM
        }
        function Global:GcLeftOut([string]$RunPath, [object[]]$Entries) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; e = $Entries } { param($rp, $e) @(Get-VmfLeftOutVmIds -RunPath $rp -Entries $e) }
        }
    }
    AfterAll { Remove-Item function:GcEntry, function:GcPlan, function:GcState, function:GcClaim, function:GcLeftOut -ErrorAction SilentlyContinue }
    BeforeEach {
        if ($Retire) {
            # The real dates are years away: the first retirement row (Dv3 and
            # its siblings) is moved to today, in memory, as RetireScope does.
            InModuleScope VmMigrationFactory -Parameters @{ file = $script:familyFile } {
                param($file)
                $copy = (Get-VmfTargetFamilyData -Path $file) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                @($copy.lifecycle.retirements)[0].retiresUtc = (Get-Date).ToUniversalTime().Date.ToString('yyyy-MM-dd')
                $script:VmfTargetFamilies = $copy
            }
        }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'gc' | Out-Null }
        $script:out = GcEntry 'out-1' $Source 'Standard_E8ds_v5'
        $script:app = GcEntry 'app-1' 'Standard_D2s_v4' 'Standard_D2s_v6'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((GsSmallSku 'Standard_D2s_v6' '0' 'V2'), (GsSmallSku 'Standard_E8ds_v5' '307200' 'V1,V2' '8' '64')) }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardX' }; CurrentValue = 0; Limit = 100 }) }
    }
    AfterEach {
        InModuleScope VmMigrationFactory -Parameters @{ file = $script:familyFile } { param($file) $null = Get-VmfTargetFamilyData -Path $file }
        GsDropDir $script:rp
    }

    It 'the one test says so, and a D machine is in scope' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:out; d = $script:app } {
            param($o, $d)
            Test-VmfEntryOutOfScope -Entry $o | Should -BeTrue
            Test-VmfEntryOutOfScope -Entry $d | Should -BeFalse
        }
    }

    It 'left out while its move has not started - with no state, or stopped at Checking' {
        @(GcLeftOut $script:rp @($script:out, $script:app)) | Should -Be @($script:out.vmId)
        GcState $script:rp $script:out 'PRECHECK' -Started
        @(GcLeftOut $script:rp @($script:out, $script:app)) | Should -Be @($script:out.vmId) -Because 'a move that stopped at Checking has not started'
        GcState $script:rp $script:out 'NEEDS_DECISION'
        @(GcLeftOut $script:rp @($script:out, $script:app)) | Should -Be @($script:out.vmId) -Because 'PRECHECK stopped it, untouched'
    }

    It 'REVIEW: NEVER left out once its move has started - it finishes that move and uses capacity' {
        GcState $script:rp $script:out 'CONVERTING' -Started
        @(GcLeftOut $script:rp @($script:out, $script:app)) | Should -BeNullOrEmpty
        $r = Test-VmfQuota -PlanPath (GcPlan $script:rp @($script:out, $script:app)) -OutPath $script:rp
        @($r.Claims.size | Sort-Object) | Should -Be @('Standard_D2s_v6', 'Standard_E8ds_v5')
    }

    It 'a finished machine is still left out, beside it' {
        GcState $script:rp $script:app 'MIGRATED'
        @(GcLeftOut $script:rp @($script:out, $script:app) | Sort-Object) | Should -Be @(@($script:app.vmId, $script:out.vmId) | Sort-Object)
    }

    It 'the quota check writes no record for it' {
        $r = Test-VmfQuota -PlanPath (GcPlan $script:rp @($script:out, $script:app)) -OutPath $script:rp
        @($r.Claims.size) | Should -Be @('Standard_D2s_v6')
    }

    It 'the Reserved gate asks no record for it, and ignores its old cell' {
        $left = GcLeftOut $script:rp @($script:out, $script:app)
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:out; d = $script:app; left = $left } {
            param($o, $d, $left)
            @((Get-VmfReservedCoverageGaps -Claims @() -Entries @($o, $d) -FinishedVmIds $left).VmId) | Should -Be @($d.vmId)
            $cell = { param([string]$Size) [pscustomobject]@{ wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                    region = 'centralus'; zone = $null; size = $Size; state = 'RELEASED' } }
            @((Select-VmfClaimsOfOpenMachines -Claims @((& $cell 'Standard_E8ds_v5'), (& $cell 'Standard_D2s_v6')) -Entries @($o, $d) -FinishedVmIds $left).size) |
                Should -Be @('Standard_D2s_v6')
        }
    }

    It 'REVIEW: a wave of ONLY such machines passes the capacity gate, BestEffort and Reserved - nothing uses capacity' {
        GcPlan $script:rp @($script:out) | Out-Null
        foreach ($gate in 'BestEffort', 'Reserved') {
            $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate $gate
            $r.Pass | Should -BeTrue -Because "$gate - $($r.Detail)"
            $r.Detail | Should -Match 'outside the scope of this tool'
            (Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate $gate -Entries @($script:out)).Pass | Should -BeTrue -Because "$gate, entries given"
        }
    }

    It 'REVIEW: a wave whose only such machine HAS STARTED its move needs a record, BestEffort and Reserved' {
        GcPlan $script:rp @($script:out) | Out-Null
        GcState $script:rp $script:out 'CONVERTING' -Started
        foreach ($gate in 'BestEffort', 'Reserved') {
            $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate $gate
            $r.Pass | Should -BeFalse -Because "$gate - it finishes the move it started, and uses capacity"
        }
    }

    It 'a MIXED wave still needs records for the machine that moves' {
        GcPlan $script:rp @($script:out, $script:app) | Out-Null
        foreach ($gate in 'BestEffort', 'Reserved') {
            $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate $gate
            $r.Pass | Should -BeFalse -Because "$gate - app-1 has no record"
        }
        GcClaim $script:rp 'a' 'Standard_D2s_v6' 'QUOTA_VERIFIED'
        (Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate 'BestEffort').Pass | Should -BeTrue
        (Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate 'Reserved').Pass | Should -BeFalse -Because 'not reserved'
        GcClaim $script:rp 'a' 'Standard_D2s_v6' 'RESERVED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate 'Reserved'
        $r.Pass | Should -BeTrue -Because $r.Detail
    }

    Context 'Start-VmfWave' {
        BeforeEach {
            Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
            Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
            Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
            Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
            Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
            Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
            # Every event is recorded, so a test can ask what was said.
            Mock -ModuleName VmMigrationFactory Write-VmfEvent { }
            # STEP-LOG-5: the launch of the workers, not the wave's start line,
            # which no longer stops a start when it cannot be written.
            Mock -ModuleName VmMigrationFactory Start-Process { throw 'PAST-THE-CAPACITY-GATE' }
        }

        It 'REVIEW: a wave of only such machines starts, BestEffort and Reserved, and says why no capacity is checked' {
            foreach ($gate in 'BestEffort', 'Reserved') {
                $plan = GcPlan $script:rp @(GcEntry 'out-1' $Source 'Standard_E8ds_v5' $gate)
                { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp } | Should -Throw '*PAST-THE-CAPACITY-GATE*' -Because $gate
            }
            Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -match 'outside the scope of this tool' } -Times 2 -Exactly
        }

        It 'REVIEW: a wave whose only such machine HAS STARTED its move is not refused on quota - it finishes its move' {
            # QUOTA-STARTED-TWICE-1: this went through the capacity gate and was
            # refused for want of a record, which left the machine stopped
            # mid-move. A started machine finishes its move, or rolls back.
            foreach ($gate in 'BestEffort', 'Reserved') {
                $entry = GcEntry 'out-1' $Source 'Standard_E8ds_v5' $gate
                $plan = GcPlan $script:rp @($entry)
                GcState $script:rp $entry 'CONVERTING' -Started
                { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp } | Should -Throw '*PAST-THE-CAPACITY-GATE*' -Because $gate
            }
            Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -match 'has started its move' } -Times 2 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -match 'outside the scope of this tool' } -Times 0 -Exactly
        }

        It 'with several containers, only the first says why no capacity is checked' {
            $plan = GcPlan $script:rp @(GcEntry 'out-1' $Source 'Standard_E8ds_v5')
            { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp -Container '2/2' } | Should -Throw '*PAST-THE-CAPACITY-GATE*'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -match 'outside the scope of this tool' } -Times 0 -Exactly
            { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp -Container '1/2' } | Should -Throw '*PAST-THE-CAPACITY-GATE*'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -match 'outside the scope of this tool' } -Times 1 -Exactly
        }

        It 'a reservation of a wave of only such machines says the true reason' {
            GcPlan $script:rp @(GcEntry 'out-1' $Source 'Standard_E8ds_v5' 'Reserved') | Out-Null
            { New-VmfWaveReservation -OutPath $script:rp -Wave 'w1' } | Should -Throw '*outside the scope of this tool*needs no on-demand capacity reservation*'
        }

        It 'a mixed Reserved wave starts once the machine that moves is reserved - no record is asked for the other' {
            $plan = GcPlan $script:rp @((GcEntry 'out-1' $Source 'Standard_E8ds_v5' 'Reserved'), (GcEntry 'app-1' 'Standard_D2s_v4' 'Standard_D2s_v6' 'Reserved'))
            GcClaim $script:rp 'a' 'Standard_D2s_v6' 'RESERVED'
            { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp } | Should -Throw '*PAST-THE-CAPACITY-GATE*'
            Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -Because 'every start checks the quota of the wave again (RESERVE-RECHECK-1)'
        }

        It 'a reservation of a mixed wave reserves the machine that moves, and asks no record for the other' {
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
            GcPlan $script:rp @((GcEntry 'out-1' $Source 'Standard_E8ds_v5' 'Reserved'), (GcEntry 'app-1' 'Standard_D2s_v4' 'Standard_D2s_v6' 'Reserved')) | Out-Null
            GcClaim $script:rp 'a' 'Standard_D2s_v6' 'QUOTA_VERIFIED'
            $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'w1'
            $r.Refused | Should -BeNullOrEmpty
            Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 1 -Exactly
        }

        It 'a mixed wave with no record for the machine that moves is still refused' {
            foreach ($gate in 'BestEffort', 'Reserved') {
                $plan = GcPlan $script:rp @((GcEntry 'out-1' $Source 'Standard_E8ds_v5' $gate), (GcEntry 'app-1' 'Standard_D2s_v4' 'Standard_D2s_v6' $gate))
                $err = $null
                try { Start-VmfWave -PlanPath $plan -Wave 'w1' -RunPath $script:rp } catch { $err = $_.Exception.Message }
                $err | Should -Not -BeNullOrEmpty -Because "$gate - refused"
                $err | Should -Not -Match 'PAST-THE-CAPACITY-GATE' -Because "$gate - refused at the capacity gate, not started"
            }
        }
    }
}

Describe 'GPU-SCOPE-1: PRECHECK stops a machine of an older plan untouched' {
    BeforeAll {
        $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
        function Global:GsLiveVm([string]$Size) {
            [pscustomobject]@{
                Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = $Size }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os" } }
                    DataDisks = @(); ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        function Global:GsPlanEntry([string]$Size, [string]$Gen = 'V1') {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = $Gen; os = 'Linux'; sourceSize = $Size; sourceDiskArch = 'scsi-temp'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_E8ds_v5'; diskArch = 'scsi-temp'; controller = 'SCSI'; zone = $null }
                policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v5' } }
        }
        # Every function in the Azure boundary that changes something.
        $script:writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
            ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
            Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -in @('Invoke-VmfRunCommand', 'Clear-VmfDiskPerfProperties') })
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gsp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'gsp' | Out-Null }
        foreach ($n in $script:writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
    }
    AfterEach {
        foreach ($n in $script:writes) { Should -Invoke -ModuleName VmMigrationFactory -CommandName $n -Times 0 -Exactly -Because "$n changes Azure" }
        GsDropDir $script:rp
    }

    It 'the boundary has write functions to watch' {
        $script:writes | Should -Contain 'Stop-VmfVmDeallocated'
        $script:writes | Should -Contain 'Set-VmfVmSizeAndController'
        $script:writes | Should -Contain 'New-VmfOsDiskSnapshot'
    }

    It 'the plan''s size is a GPU size: refused before the machine is even read' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { throw 'the machine must not be read' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (GsPlanEntry 'Standard_NC8as_T4_v3') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'gsp'
            New-VmfStateDoc -RunPath $rp -RunId 'gsp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'sizeOutOfScope'
            $r.Detail | Should -Match 'Standard_NC8as_T4_v3 is outside the scope of this tool'
            $r.Detail | Should -Match 'Nothing on the machine changed'
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 0 -Exactly
    }

    It 'the machine was resized onto a GPU size after its plan was made: refused when its size is read' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { GsLiveVm 'Standard_NV12ads_A10_v5' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (GsPlanEntry 'Standard_D8s_v4' 'V2') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'gsp'
            New-VmfStateDoc -RunPath $rp -RunId 'gsp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'sizeOutOfScope'
            $r.Detail | Should -Match 'Standard_NV12ads_A10_v5 is outside the scope of this tool'
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 1 -Because 'the size the machine has now is read, then refused'
    }

    It 'the stop has guidance: untouched, out of scope, in scope words' {
        $all = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons)
        $reason = $all | Where-Object code -EQ 'sizeOutOfScope'
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'outOfScope'
        $reason.meaning | Should -Match 'outside the scope of this tool'
        $reason.meaning | Should -Not -Match 'cannot|impossible'
    }
}
