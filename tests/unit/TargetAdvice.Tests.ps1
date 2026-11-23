#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ADVISOR-1: the target options for each machine, before the waves.
#
# The shape accepted on 2026-09-26, after two others were rejected:
#   - one default for the whole migration, the Current default (v6) or
#     the Extended default (v5), and v7 a choice for any machine where it is
#     supported;
#   - each machine STARTS on that default where it is supported, else on the
#     other supported option, else on nothing;
#   - any machine can be changed to any other SUPPORTED option, and an option
#     that is not supported is shown with the fact that stops it;
#   - facts only - no judgement words.
# So the advice document carries, for every machine, every option with its
# facts, and the two starting targets. It carries codes, never sentences: the
# screen turns each code into words.
#
# The facts come from the functions the planner and the engine already use,
# never from a second copy of their rules: Resolve-VmfEntryTarget for the size,
# the path and the blockers of a series; the target-families data for the
# lifecycle stage and accelerated networking.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:TaSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2', [string]$Nics = '4') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = $Nics }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    # centralus as the tests need it: v5 takes Generation 1 and keeps a SCSI
    # temporary disk on its d sizes; v6 is Generation 2 only; no v7 D size.
    function Global:TaCatalog([switch]$WithV7, [switch]$NoV6) {
        $c = @{}
        foreach ($s in @(
                (TaSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (TaSku 'Standard_D2s_v5' '0' 'V1,V2'),
                (TaSku 'Standard_D2as_v5' '0' 'V1,V2'))) { $c[$s.Name] = $s }
        if (-not $NoV6) {
            foreach ($s in @((TaSku 'Standard_D2ds_v6' '0'), (TaSku 'Standard_D2s_v6' '0'))) { $c[$s.Name] = $s }
        }
        if ($WithV7) {
            foreach ($s in @((TaSku 'Standard_D2ds_v7' '0'), (TaSku 'Standard_D2s_v7' '0'))) { $c[$s.Name] = $s }
        }
        $c
    }
    function Global:TaVm {
        param([string]$Name = 'm', [string]$Size = 'Standard_D2ds_v4', [string]$Os = 'Linux', [string]$Gen = 'V2',
              [string]$Classification = 'ReadyAfterPrep', [string[]]$Blockers = @(), [string[]]$Prep = @(),
              [string]$Arch = 'scsi-temp', [string]$Controller = 'SCSI', [object]$AnCount = 1, [bool]$PlatformManaged = $false,
              [string]$OsVersion = '22_04-lts-gen2', [int]$Nics = 1)
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = $Classification; gen = $Gen; os = $Os; osVersion = $OsVersion
            sourceSize = $Size; sourceDiskArch = $Arch; sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 })
            diskController = $Controller; dataDiskCount = 1; nicCount = $Nics; acceleratedNicCount = $AnCount
            platformManaged = $PlatformManaged; blockers = @($Blockers); prepNeeded = @($Prep)
        }
    }
    function Global:TaAdvise([object[]]$Vms, [hashtable]$Catalog = (TaCatalog), [string[]]$NotRead = @()) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms) }
        $cat = @{}
        if ($NotRead -notcontains 'centralus') { $cat['centralus'] = $Catalog }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = $cat; n = $NotRead } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -RegionsNotRead $n
        }
    }
    function Global:TaOpt($Machine, [string]$Option) { @($Machine.options) | Where-Object { $_.option -eq $Option } | Select-Object -First 1 }
}
AfterAll { Remove-Item 'function:\TaSku', 'function:\TaCatalog', 'function:\TaVm', 'function:\TaAdvise', 'function:\TaOpt', 'function:\TaPrincipal' -ErrorAction SilentlyContinue }

Describe 'ADVISOR-1: the size choice says WHICH no it is, as a code' {
    # The advice turns "why is v6 not an option" into words on the screen, so
    # the reason must be a code, not a sentence to be parsed. Every refusal in
    # Get-VmfTargetSize now carries one beside its sentence.

    It '<Case>' -ForEach @(
        @{ Case = 'a size the region offers: mapped';               Source = 'Standard_D2ds_v4'; Gen = 'v6'; Hv = 'V2'; Nics = 1; Expected = 'mapped' }
        @{ Case = 'a series the region does not offer: not-in-region'; Source = 'Standard_D2ds_v4'; Gen = 'v7'; Hv = 'V2'; Nics = 1; Expected = 'not-in-region' }
        @{ Case = 'Generation 1 and no size takes it: gen1-no-size'; Source = 'Standard_D2ds_v4'; Gen = 'v6'; Hv = 'V1'; Nics = 1; Expected = 'gen1-no-size' }
        @{ Case = 'more interfaces than the size holds: too-few-nics'; Source = 'Standard_D2ds_v4'; Gen = 'v6'; Hv = 'V2'; Nics = 9; Expected = 'too-few-nics' }
        @{ Case = 'an Arm64 machine: processor-not-approved';      Source = 'Standard_D2pds_v5'; Gen = 'v6'; Hv = 'V2'; Nics = 1; Expected = 'processor-not-approved' }
        @{ Case = 'a family with no target at all: family-not-in-region'; Source = 'Standard_L8s_v3'; Gen = 'v6'; Hv = 'V2'; Nics = 1; Expected = 'family-not-in-region' }
    ) {
        $cat = TaCatalog
        InModuleScope VmMigrationFactory -Parameters @{ c = $cat; s = $Source; g = $Gen; hv = $Hv; n = $Nics; e = $Expected } {
            (Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g -HyperVGeneration $hv -RequiredNics $n).Code |
                Should -Be $e
        }
    }

    It 'a size chosen without a reading of its limits is mapped-unverified, never plain mapped' {
        $bare = @{ 'Standard_D2ds_v5' = [pscustomobject]@{ Name = 'Standard_D2ds_v5'; Capabilities = @() } }
        InModuleScope VmMigrationFactory -Parameters @{ c = $bare } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v5' -HyperVGeneration 'V1').Code |
                Should -Be 'mapped-unverified'
        }
    }

    It 'the sentence is still there for everything that already reads it' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (TaCatalog) } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v7').Reason | Should -Match 'no candidate'
        }
    }
}

Describe 'ADVISOR-1: the lifecycle stage of the size moved from and to' {

    It '<Size> is End of Life, as Microsoft lists it - it read as no stage before' -ForEach @(
        @{ Size = 'Standard_DS2_v2' }, @{ Size = 'Standard_DS2' }, @{ Size = 'Standard_D2' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size } {
            (Get-VmfSizeLifecycleStage -SizeName $s).Stage | Should -Be 'End of Life'
        }
    }

    It 'a size outside the table still has no stage - it is never given one' {
        InModuleScope VmMigrationFactory {
            Get-VmfSizeLifecycleStage -SizeName 'Standard_L8s_v3' | Should -BeNullOrEmpty
            # BSV2-TARGET-1 gave Bsv2 its derived Current stage, so a GPU size stands in for it.
            Get-VmfSizeLifecycleStage -SizeName 'Standard_NC6s_v3' | Should -BeNullOrEmpty
        }
    }

    It '<From> to <To> is <Expected>' -ForEach @(
        @{ From = 'Standard_D2ds_v4'; To = 'Standard_D2ds_v5'; Expected = 'same' }
        @{ From = 'Standard_D2s_v3';  To = 'Standard_D2ds_v5'; Expected = 'up' }
        @{ From = 'Standard_D2ds_v4'; To = 'Standard_D2ds_v6'; Expected = 'up' }
        @{ From = 'Standard_D2ds_v6'; To = 'Standard_D2ds_v5'; Expected = 'down' }
        @{ From = 'Standard_L8s_v3';  To = 'Standard_D2ds_v6'; Expected = 'unknown' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $From; t = $To; e = $Expected } {
            Get-VmfLifecycleChange -FromSize $f -ToSize $t | Should -Be $e
        }
    }
}

Describe 'ADVISOR-1: the options for each machine' {

    Context 'a Generation 2 Linux machine on D2ds_v4, in a region with v5 and v6 and no v7' {
        BeforeAll { $script:m = @((TaAdvise @(TaVm)).machines)[0] }

        It 'v6 is supported: an NVMe conversion in place, on D2ds_v6, Extended to Current' {
            $o = TaOpt $script:m 'v6'
            $o.supported | Should -BeTrue
            $o.targetSize | Should -Be 'Standard_D2ds_v6'
            $o.path | Should -Be 'A'
            $o.move | Should -Be 'nvme-conversion'
            $o.preview | Should -BeFalse -Because 'a Linux move needs no preview feature'
            $o.targetStage.stage | Should -Be 'Current'
            $o.stageChange | Should -Be 'up'
        }

        It 'v5 is supported: a resize on SCSI, which stays Extended - never shown as a newer stage' {
            $o = TaOpt $script:m 'v5'
            $o.supported | Should -BeTrue
            $o.targetSize | Should -Be 'Standard_D2ds_v5'
            $o.move | Should -Be 'scsi-resize'
            $o.stageChange | Should -Be 'same'
        }

        It 'v7 is not supported, and says the region has no size for it' {
            $o = TaOpt $script:m 'v7'
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Contain 'not-in-region'
        }

        It 'it has no Generation 1 route option' {
            TaOpt $script:m 'gen1Route' | Should -BeNullOrEmpty
        }

        It 'it starts on v6 under Current and on v5 under Extended' {
            $script:m.start.current | Should -Be 'v6'
            $script:m.start.extended | Should -Be 'v5'
        }

        It 'the size it moves from is Extended' {
            $script:m.sourceStage.stage | Should -Be 'Extended'
        }

        It 'it carries the disk controller it has now, for the before and after of each option' {
            $script:m.diskController | Should -Be 'SCSI'
        }
    }

    Context 'a Generation 1 machine the scan blocked for v6' {
        BeforeAll {
            $vm = TaVm -Size 'Standard_D2s_v4' -Arch 'diskless' -Gen 'V1' -Classification 'Blocked' -Blockers 'gen1-requires-redeploy'
            $script:m = @((TaAdvise @($vm)).machines)[0]
        }

        It 'v6 is not supported, and the fact is the blocker' {
            $o = TaOpt $script:m 'v6'
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Be @('gen1-requires-redeploy')
        }

        It 'v5 is supported - a resize on SCSI' {
            $o = TaOpt $script:m 'v5'
            $o.supported | Should -BeTrue
            $o.path | Should -Be 'A'
            $o.targetSize | Should -Be 'Standard_D2s_v5'
        }

        It 'it has v5, v6 and v7 only - the tool has no Generation 1 route (GEN1-ROUTE-GONE-1)' {
            @($script:m.options.option) | Should -Be @('v5', 'v6', 'v7')
        }

        It 'it starts on v5 under both defaults - the only supported option' {
            $script:m.start.current | Should -Be 'v5'
            $script:m.start.extended | Should -Be 'v5'
        }
    }

    Context 'a Windows machine whose temporary disk changes kind' {
        It 'v6 is the in-place upgrade (Preview), no longer a rebuild (REBUILD-REMOVE-PLAN-1); v5 stays a resize' {
            $m = @((TaAdvise @(TaVm -Os 'Windows' -OsVersion '2022-datacenter-g2')).machines)[0]
            (TaOpt $m 'v6').path | Should -Be 'A'
            (TaOpt $m 'v6').preview | Should -BeTrue
            (TaOpt $m 'v5').path | Should -Be 'A'
            (TaOpt $m 'v5').preview | Should -BeFalse
        }
    }

    Context 'accelerated networking' {
        It 'Intel D v5 requires it: a machine with it off meets that stop, and the move turns it on' {
            $m = @((TaAdvise @(TaVm -AnCount 0)).machines)[0]
            $o = TaOpt $m 'v5'
            $o.acceleratedNetworking.required | Should -BeTrue
            $o.acceleratedNetworking.turnsOn | Should -BeTrue
            @($o.stops) | Should -Contain 'acceleratedNetworkingRequired'
            $o.supported | Should -BeTrue -Because 'an approver can accept the stop, so it is a fact to show, not a refusal'
        }

        It 'with it on, nothing is turned on and there is no stop' {
            $m = @((TaAdvise @(TaVm -AnCount 1)).machines)[0]
            (TaOpt $m 'v5').acceleratedNetworking.turnsOn | Should -BeFalse
            @((TaOpt $m 'v5').stops).Count | Should -Be 0
        }

        It 'a scan that did not record it gives unknown - never a no' {
            $m = @((TaAdvise @(TaVm -AnCount $null)).machines)[0]
            $null -eq (TaOpt $m 'v5').acceleratedNetworking.turnsOn | Should -BeTrue
            @((TaOpt $m 'v5').stops).Count | Should -Be 0
        }

        It 'v6 requires it (DRIFT-11, since 2026-10-27), and MANA is possible there' {
            $m = @((TaAdvise @(TaVm -AnCount 0)).machines)[0]
            (TaOpt $m 'v6').acceleratedNetworking.required | Should -BeTrue
            (TaOpt $m 'v6').acceleratedNetworking.mayUseMana | Should -BeTrue
            @((TaOpt $m 'v6').stops) | Should -Contain 'acceleratedNetworkingRequired'
        }
    }

    Context 'the region' {
        It 'with only v7 offered, Current starts on v7' {
            $m = @((TaAdvise @(TaVm) -Catalog (TaCatalog -WithV7 -NoV6)).machines)[0]
            (TaOpt $m 'v6').supported | Should -BeFalse
            (TaOpt $m 'v7').supported | Should -BeTrue
            $m.start.current | Should -Be 'v7'
        }

        It 'with v6 and v7 both offered, Current is still v6' {
            $m = @((TaAdvise @(TaVm) -Catalog (TaCatalog -WithV7)).machines)[0]
            (TaOpt $m 'v7').supported | Should -BeTrue
            $m.start.current | Should -Be 'v6'
        }

        It 'a region whose sizes could not be read supports nothing, says so, and starts on nothing' {
            $advice = TaAdvise @(TaVm) -NotRead @('centralus')
            $m = @($advice.machines)[0]
            foreach ($o in @($m.options)) {
                $o.supported | Should -BeFalse
                @($o.notSupported) | Should -Contain 'region-not-read'
                $o.targetSize | Should -BeNullOrEmpty
            }
            $m.start.current | Should -BeNullOrEmpty
            $m.start.extended | Should -BeNullOrEmpty
            (@($advice.regions) | Where-Object location -eq 'centralus').read | Should -BeFalse
        }
    }

    Context 'machines with nothing to choose' {
        It 'a platform-managed machine supports nothing' {
            $m = @((TaAdvise @(TaVm -Classification 'Excluded' -PlatformManaged $true)).machines)[0]
            @($m.options | Where-Object supported).Count | Should -Be 0
            @((TaOpt $m 'v6').notSupported) | Should -Be @('excluded')
            $m.start.current | Should -BeNullOrEmpty
        }

        It 'a machine already on v6 has no target: v6 is where it is, and v5 would be an older size' {
            $m = @((TaAdvise @(TaVm -Size 'Standard_D2ds_v6' -Arch 'diskless' -Controller 'NVMe' -Classification 'ReadyNow')).machines)[0]
            @((TaOpt $m 'v6').notSupported) | Should -Be @('already-on-nvme')
            @((TaOpt $m 'v5').notSupported) | Should -Be @('source-is-newer')
            $m.start.current | Should -BeNullOrEmpty
            $m.start.extended | Should -BeNullOrEmpty
        }

        It 'Windows Server 2012 R2 on Generation 1: blocked for v6 and held on v5' {
            $vm = TaVm -Os 'Windows' -Size 'Standard_D2s_v3' -Arch 'scsi-temp' -Gen 'V1' -OsVersion '2012-R2-Datacenter' `
                -Classification 'Blocked' -Blockers @('gen1-requires-redeploy', 'windows-version-below-2019', 'windows-version-not-proven')
            $m = @((TaAdvise @($vm)).machines)[0]
            @((TaOpt $m 'v5').notSupported) | Should -Be @('windows-version-not-proven')
            (TaOpt $m 'v6').supported | Should -BeFalse
            $m.start.current | Should -BeNullOrEmpty
            $m.start.extended | Should -BeNullOrEmpty
        }
    }
}

Describe 'ADVISOR-1: the document' {

    BeforeAll {
        $vms = @(
            (TaVm -Name 'a'),
            (TaVm -Name 'g1' -Size 'Standard_D2s_v4' -Arch 'diskless' -Gen 'V1' -Classification 'Blocked' -Blockers 'gen1-requires-redeploy'),
            (TaVm -Name 'aks' -Classification 'Excluded' -PlatformManaged $true))
        $script:advice = TaAdvise $vms
    }

    It 'has one entry per machine in the scan, in the scan''s order' {
        @($script:advice.machines | ForEach-Object name) | Should -Be @('a', 'g1', 'aks')
    }

    It 'names the assessment it was made from' {
        $script:advice.assessmentId | Should -Be 'scan-1'
        $script:advice.schemaVersion | Should -Be 34 -Because 'RHEL-EUS-TARGET-NOTE-1 made it 31 (eusImage); SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); v2 named the defaults after the lifecycle stages; v3 added the two SIZE-FIT-1 reasons; v4 added disk-encryption-rebuild (V5-ADE-1); v5 added sizeChoices (OLD-SKU-1B); v6 gave them on v6 and v7 (OLD-SKU-V6-1); v7 added premiumDisks (OLD-SKU-1C); v8 added the Dl family (OLD-FAM-1); v9 the reasons for families it does not move (OLD-FAM-3); v10 the d size and the size without a temporary disk for a v3 machine (V3-TEMPDISK-1); v11 the same for an AMD v4 machine, on AMD (DAV4-TEMPDISK-1); v12 burstableEnds and size-retired (OLD-FAM-4); v13 the reason gpu-size (GPU-SCOPE-1); v14 the processor maker by shape and no-amd-shape-fit (AMD-SHAPE-1); v15 the Bsv2 size of a B v1 machine, burstableKept and burstableTarget, and the stage and CPU credits on each size choice (BSV2-TARGET-1); v16 the reason too-many-data-disks (DISKS-32-1); v17 the reason one-accelerated-nic (AN-ONE-NIC-1); v18 keptOn, linuxRelease and the start that keeps accelerated networking (ADVISE-AN-1); v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine; v21 (IDENTITY-LOSS-1) what each target does to the system-assigned identity; v22 (GEN1-ROUTE-GONE-1) no Generation 1 route; v23 (REBUILD-PICKER-1) every machine whose move would rebuild it starts on the in-place upgrade'
    }

    It 'matches its schema' {
        $json = $script:advice | ConvertTo-Json -Depth 12
        $json | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'every code it can write is in the schema''s list - so the screen can have words for each' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $known = @($schema.'$defs'.reason.enum)
        $known.Count | Should -BeGreaterThan 10
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        foreach ($code in @($reasons.blockers.PSObject.Properties.Name)) {
            $known | Should -Contain $code -Because "the scan can write blocker '$code'"
        }
        foreach ($code in 'region-not-read', 'excluded', 'already-on-nvme', 'already-on-series', 'source-is-newer',
                          'not-in-region', 'family-not-in-region', 'gen1-no-size', 'too-few-nics', 'too-few-data-disks',
                          'processor-unreadable', 'processor-not-approved', 'not-approved', 'smaller-than-source', 'shape-unknown', 'no-shape-fit', 'no-amd-shape-fit',
                          'disk-encryption-preview', 'generation-unknown', 'temp-disk-change-not-measured') {
            $known | Should -Contain $code
        }
    }
}

Describe 'ADVISOR-1: New-VmfTargetAdvice writes it beside the reviewed assessment' {

    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-adv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); vms = @(TaVm) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        $script:catalog = @((TaCatalog).Values)
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses an assessment nobody has reviewed - the same gate as planning' {
        { New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') } | Should -Throw '*has not been reviewed*'
    }

    It 'after the review, writes target-advice.json bound to the assessment that was reviewed' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $approval = Get-Content (Join-Path $script:rp 'approval.json') -Raw | ConvertFrom-Json
        $r = New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json')
        $r.Machines | Should -Be 1
        $written = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
        $written.assessmentHash | Should -Be $approval.assessmentHash
        (@($written.machines)[0].start.current) | Should -Be 'v6'
    }

    It 'a region Azure would not list is recorded as not read, and the advice is still written' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { throw 'AuthorizationFailed' }
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') -WarningVariable warned -WarningAction SilentlyContinue | Out-Null
        ($warned -join ' ') | Should -Match 'AuthorizationFailed' -Because 'the operator needs the reason Azure gave, not only that the read failed'
        $written = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
        (@($written.regions)[0]).read | Should -BeFalse
        (@($written.machines)[0].start.current) | Should -BeNullOrEmpty
    }

    It 'running it again replaces it - it is safe to re-run' {
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        { New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') } | Should -Not -Throw
    }
}

Describe 'ADVISOR-1: the options start when the review is approved' {
    # A step that is required needs no button to ask for it. The service starts the engine's advise operation as soon as the
    # review is recorded.

    BeforeAll {
        function Global:TaPrincipal([string]$Role) {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = $Role })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }

    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-adv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = 'scan-1'; vms = @(TaVm) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId 'scan-1' -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'approving the review starts the advise operation for that assessment, as the approver' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ Execution = 'exec-1' } }
        $r = Invoke-VmfFacadeApproveAssessment -Principal (TaPrincipal 'Vmf.Approver') -StorePath $script:rp -AssessmentHash (InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { param($p) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'assessment.json')) }) -RunId 'scan-1' -Project 'alpha'
        $r.TargetOptions.started | Should -BeTrue
        $r.TargetOptions.execution | Should -Be 'exec-1'
        Should -Invoke Invoke-VmfFacadeStartEngine -ModuleName FacadeCore -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'advise' -and $RunId -eq 'scan-1' -and $Project -eq 'alpha' -and $Principal.Identity -eq 'person@example.com'
        }
    }

    It 'a start that fails still leaves the review recorded, and says the options did not start' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'the engine job could not be read' }
        $r = Invoke-VmfFacadeApproveAssessment -Principal (TaPrincipal 'Vmf.Approver') -StorePath $script:rp -AssessmentHash (InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { param($p) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'assessment.json')) }) -RunId 'scan-1'
        Test-Path (Join-Path $script:rp 'approval.json') | Should -BeTrue
        $r.TargetOptions.started | Should -BeFalse
        $r.TargetOptions.error | Should -Match 'did not start'
    }

    It 'an approver may ask for the options again; a viewer may not' {
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob { throw 'reached the start' }
        { Invoke-VmfFacadeStartEngine -Principal (TaPrincipal 'Vmf.Approver') -Operation 'advise' -RunId 'scan-1' } |
            Should -Throw '*reached the start*'
        { Invoke-VmfFacadeStartEngine -Principal (TaPrincipal 'Vmf.Viewer') -Operation 'advise' -RunId 'scan-1' } |
            Should -Throw '403*'
    }

    It 'the route passes the run id and project through' {
        $route = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostApproveAssessment' 'run.ps1') -Raw
        $route | Should -Match 'RunId = \$runId'
        $route | Should -Match '\$approveParams\.Project = \$project'
    }

    It 'the engine runs New-VmfTargetAdvice on the assessment it was started for' {
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $branch = [regex]::Match($entry, "(?s)'advise' \{(.*?)\n    \}").Groups[1].Value
        $branch | Should -Match 'New-VmfTargetAdvice -AssessmentPath "\$runPath/assessment\.json"'
    }
}
