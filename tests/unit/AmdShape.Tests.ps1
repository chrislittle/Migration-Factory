#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AMD-SHAPE-1: a machine keeps its processor maker when it is sized by shape.
#
# OWNER-QUESTIONS-1 row 17, decided 2026-10-05: a machine keeps its processor
# maker. An AMD machine sized by shape is offered AMD sizes only (Dasv5,
# Dadsv5, Easv5, Eadsv5 and their v6/v7 rows), never Intel; with none in the
# region, it has no target and the reason says so.
#
# What was wrong: Get-VmfShapeSizeChoices matched the Intel names only
# (Standard_D4ds_v5, Standard_E8-4ds_v5, Standard_D4lds_v5), whatever the
# machine ran on. A Generation 1 machine on an AMD size (Dav4, Dasv4, Eav4,
# Easv4) is sized by shape on v5. Its own AMD size was its default when the
# region had it (the name rule, DAV4-TEMPDISK-1), but every other choice was
# Intel - and with no AMD size of its own name, an Intel size was the default.
#
# The processor is read the way the product already reads it:
# Get-VmfSizeProcessor, from the 'a' and 'p' letters in
# data/target-families.json (processorLetters), Intel when neither.
#
# The catalog: Microsoft's AMD and Intel D and E v5 sizes with their vCPUs and
# memory (Dasv5, Dadsv5, Easv5, Eadsv5 and the Intel twins), two constrained E
# sizes on each processor, the Intel Dl v5 sizes, and on v6 the AMD and Intel
# Dl, D and E sizes - so a planner that changed the processor would have
# somewhere to go, and a test would see it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:AsSku {
        param([string]$Name, [int]$Vcpus, [double]$Gb, [object]$TempMb = 0, [string]$Gens = 'V1,V2', [object]$Available = $null)
        $caps = @(
            [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = ([string]$Gb) }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '16' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$TempMb })
        if ($null -ne $Available) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = [string]$Available } }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }

    # -NoAmd: a region with no AMD v5 or v6 target at all.
    # -NoTwin: a region without the AMD sizes of the source's own name
    # (D4ads_v5, D4as_v5), so the name rule gives nothing and the shape decides.
    function Global:AsCatalog([switch]$NoAmd, [switch]$NoTwin) {
        $c = @{}
        $add = { param($s) $c[$s.Name] = $s }
        # Sources: AMD v4 (with a temporary disk on every size), an Intel v4, an old Intel Dv2.
        & $add (AsSku 'Standard_D4as_v4' 4 16 32768)
        & $add (AsSku 'Standard_D4a_v4' 4 16 102400)
        & $add (AsSku 'Standard_E8as_v4' 8 64 131072)
        & $add (AsSku 'Standard_D4s_v4' 4 16 0)
        & $add (AsSku 'Standard_D4_v2' 8 28 409600 'V1')
        $d = @(@(2, 8), @(4, 16), @(8, 32), @(16, 64))
        $e = @(@(2, 16), @(4, 32), @(8, 64), @(16, 128))
        foreach ($g in 'v5', 'v6') {
            $gens = if ($g -eq 'v5') { 'V1,V2' } else { 'V2' }
            $temp = if ($g -eq 'v5') { 76800 } else { 0 }
            foreach ($fam in @(@('D', $d), @('E', $e))) {
                foreach ($r in $fam[1]) {
                    $n = "$($fam[0])$($r[0])"
                    $twin = $NoTwin -and $g -eq 'v5' -and $n -eq 'D4'
                    if (-not $NoAmd -and -not $twin) {
                        & $add (AsSku "Standard_$($n)ads_$g" $r[0] $r[1] $temp $gens)
                        & $add (AsSku "Standard_$($n)as_$g" $r[0] $r[1] 0 $gens)
                    }
                    & $add (AsSku "Standard_$($n)ds_$g" $r[0] $r[1] $temp $gens)
                    & $add (AsSku "Standard_$($n)s_$g" $r[0] $r[1] 0 $gens)
                }
            }
            # Constrained E sizes: the same size with fewer active vCPUs.
            if (-not $NoAmd) {
                & $add (AsSku "Standard_E8-4ads_$g" 8 64 $temp $gens 4)
                & $add (AsSku "Standard_E8-2ads_$g" 8 64 $temp $gens 2)
            }
            & $add (AsSku "Standard_E8-4ds_$g" 8 64 $temp $gens 4)
            & $add (AsSku "Standard_E8-2ds_$g" 8 64 $temp $gens 2)
            # Dl (2 GiB for each vCPU): Intel on v5 and v6, AMD on v6 only (Daldsv6;
            # Microsoft has no AMD Dl on v5).
            foreach ($r in $d) {
                & $add (AsSku "Standard_D$($r[0])lds_$g" $r[0] (2 * $r[0]) $temp $gens)
                if ($g -eq 'v6' -and -not $NoAmd) { & $add (AsSku "Standard_D$($r[0])alds_$g" $r[0] (2 * $r[0]) $temp $gens) }
            }
        }
        $c
    }

    function Global:AsVm {
        param([string]$Size = 'Standard_D4as_v4', [string]$Gen = 'V1', [string]$Name = 'amd-01')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen; hyperVGeneration = $Gen
            os = 'Linux'; osVersion = '22_04-lts'
            classification = $(if ($Gen -eq 'V1') { 'Blocked' } else { 'ReadyAfterPrep' })
            blockers = @($(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' })); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'
            tags = @{ app = $Name }
        }
    }

    function Global:AsTarget($Vm, [hashtable]$Catalog, [string]$Series = 'v5', [string]$Chosen = '') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = $Catalog; g = $Series; ch = $Chosen } {
            param($v, $c, $g, $ch) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g -ChosenSize $ch
        }
    }

    function Global:AsMakers($choices) {
        @(@($choices) | ForEach-Object { InModuleScope VmMigrationFactory -Parameters @{ s = [string]$_.size } { param($s) Get-VmfSizeProcessor -SizeName $s } } | Sort-Object -Unique)
    }
}
AfterAll { Remove-Item 'function:\AsSku', 'function:\AsCatalog', 'function:\AsVm', 'function:\AsTarget', 'function:\AsMakers' -ErrorAction SilentlyContinue }

Describe 'AMD-SHAPE-1: an AMD machine sized by shape is offered AMD sizes only' {

    It 'THE CASE: a Generation 1 D4as_v4 in a region without D4ads_v5 is planned on an AMD size, not Intel D4ds_v5' {
        # Before: its own AMD sizes were missing, so the name rule gave nothing,
        # and the best shape choice was Intel D4ds_v5 (4 vCPUs, 16 GiB).
        $t = AsTarget (AsVm) (AsCatalog -NoTwin)
        $t.Mapping.Target | Should -Be 'Standard_E4ads_v5' -Because 'the AMD size with the fewest vCPUs that keeps 4 vCPUs and 16 GiB'
        $t.Path | Should -Be 'A'
        AsMakers $t.SizeChoices | Should -Be @('AMD')
        @($t.SizeChoices | ForEach-Object { $_.size }) | Should -Contain 'Standard_D8ads_v5'
        @($t.SizeChoices | ForEach-Object { $_.size }) | Should -Not -Contain 'Standard_D4ds_v5'
    }

    It 'a Generation 1 AMD v4 machine keeps its own AMD size as the default, and every other choice is AMD' {
        $t = AsTarget (AsVm) (AsCatalog)
        $t.Mapping.Target | Should -Be 'Standard_D4ads_v5'
        @(@($t.SizeChoices) | Where-Object best | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ads_v5')
        AsMakers $t.SizeChoices | Should -Be @('AMD')
        @(@($t.SizeChoices) | Where-Object { $_.family -eq 'E' -and $_.variant -eq 'default' } | ForEach-Object { $_.size }) | Should -Be @('Standard_E4ads_v5')
    }

    It 'the constrained E sizes it is offered are AMD too: E8as_v4 gets E8-2ads_v5 and E8-4ads_v5, never E8-4ds_v5' {
        $t = AsTarget (AsVm -Size 'Standard_E8as_v4') (AsCatalog)
        $con = @(@($t.SizeChoices) | Where-Object variant -EQ 'constrained' | ForEach-Object { $_.size })
        $con | Should -Contain 'Standard_E8-4ads_v5'
        $con | Should -Contain 'Standard_E8-2ads_v5'
        $con | Should -Not -Contain 'Standard_E8-4ds_v5'
        AsMakers $t.SizeChoices | Should -Be @('AMD')
    }

    It 'a Dav4 size with no s (D4a_v4) is AMD too' {
        $t = AsTarget (AsVm -Size 'Standard_D4a_v4') (AsCatalog -NoTwin)
        AsMakers $t.SizeChoices | Should -Be @('AMD')
        InModuleScope VmMigrationFactory -Parameters @{ s = [string]$t.Mapping.Target } { param($s) Get-VmfSizeProcessor -SizeName $s } | Should -Be 'AMD'
    }

    It 'on v6, the AMD Dl sizes are its Dl choices (Daldsv6), as the Intel Dl sizes are for an Intel machine' {
        $c = InModuleScope VmMigrationFactory -Parameters @{ c = (AsCatalog) } {
            param($c) @(Get-VmfShapeSizeChoices -SourceSize 'Standard_D4as_v4' -CatalogBySize $c -HyperVGeneration 'V2' -TargetGeneration 'v6')
        }
        AsMakers $c | Should -Be @('AMD')
        @(@($c) | Where-Object family -EQ 'Dl' | ForEach-Object { $_.size }) | Should -Be @('Standard_D8alds_v6')
        @(@($c) | Where-Object family -EQ 'D' | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ads_v6')
    }

    It 'a chosen Intel size is refused with the reason - the targets step never offered it, and a plan never takes it' {
        $t = AsTarget (AsVm) (AsCatalog -NoTwin) 'v5' 'Standard_D4ds_v5'
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'chosen-size-gone'
        $t.Path | Should -Be 'MANUAL'
    }
}

Describe 'AMD-SHAPE-1: the processor letter is read from the same data as the processor' {

    It '<Processor> is written <Letter>' -ForEach @(
        @{ Processor = 'AMD'; Letter = 'a' }
        @{ Processor = 'Intel'; Letter = '' }
        @{ Processor = 'Arm64'; Letter = 'p' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ p0 = $Processor } { param($p0) Get-VmfProcessorLetter -Processor $p0 } | Should -BeExactly $Letter
    }

    It 'a processor the data does not name has no letter - never the Intel names' {
        InModuleScope VmMigrationFactory { $null -eq (Get-VmfProcessorLetter -Processor 'Power') } | Should -BeTrue
        InModuleScope VmMigrationFactory { $null -eq (Get-VmfProcessorLetter -Processor '') } | Should -BeTrue
    }

    It 'every letter round-trips: a size written with it reads back as its processor' {
        InModuleScope VmMigrationFactory {
            foreach ($p0 in 'AMD', 'Intel') {
                Get-VmfSizeProcessor -SizeName "Standard_D4$(Get-VmfProcessorLetter -Processor $p0)ds_v5" | Should -Be $p0
            }
        }
    }
}

Describe 'AMD-SHAPE-1: with no AMD size in the region, no target, and the reason says so' {

    It 'THE CASE: a Generation 1 D4as_v4 in a region with only Intel v5 sizes has no target, and is never moved to Intel' {
        $t = AsTarget (AsVm) (AsCatalog -NoAmd)
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'no-amd-shape-fit'
        $t.Mapping.Reason | Should -Match 'AMD'
        $t.Mapping.Reason | Should -Match 'Intel' -Because 'it says why the Intel sizes in the region are not offered'
        $t.Mapping.Reason | Should -BeLike '*no v5 AMD D or E size*' -Because 'Microsoft has no AMD Dl size on v5, so the note does not name one'
        $t.Path | Should -Be 'MANUAL'
        @($t.SizeChoices).Count | Should -Be 0
    }

    It 'an Intel machine with no size of its shape keeps its own code, and the reason names Intel' {
        $cat = AsCatalog
        foreach ($k in @($cat.Keys)) { if ($k -match '_v5$' -and $k -notmatch 'a[a-z]*_v5$') { $cat.Remove($k) } }
        $t = AsTarget (AsVm -Size 'Standard_D4_v2') $cat
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'no-shape-fit'
        $t.Mapping.Reason | Should -Match 'Intel'
    }
}

Describe 'AMD-SHAPE-1: an Intel machine keeps Intel, as before' {

    It 'a Generation 1 D4_v2 is offered Intel sizes only, even where an AMD size has the same shape' {
        $t = AsTarget (AsVm -Size 'Standard_D4_v2') (AsCatalog)
        $t.Mapping.Target | Should -Be 'Standard_D8ds_v5'
        AsMakers $t.SizeChoices | Should -Be @('Intel')
    }

    It 'a Generation 1 D4s_v4 keeps its name twin and Intel choices' {
        $t = AsTarget (AsVm -Size 'Standard_D4s_v4') (AsCatalog)
        $t.Mapping.Target | Should -Be 'Standard_D4s_v5'
        AsMakers $t.SizeChoices | Should -Be @('Intel')
    }

    It 'every shape choice is on the processor of its machine: <Source> on <Series>' -ForEach @(
        @{ Source = 'Standard_D4as_v4'; Series = 'v5'; Maker = 'AMD' }
        @{ Source = 'Standard_D4a_v4'; Series = 'v5'; Maker = 'AMD' }
        @{ Source = 'Standard_E8as_v4'; Series = 'v5'; Maker = 'AMD' }
        @{ Source = 'Standard_D4as_v4'; Series = 'v6'; Maker = 'AMD' }
        @{ Source = 'Standard_E8as_v4'; Series = 'v6'; Maker = 'AMD' }
        @{ Source = 'Standard_D4_v2'; Series = 'v5'; Maker = 'Intel' }
        @{ Source = 'Standard_D4s_v4'; Series = 'v5'; Maker = 'Intel' }
        @{ Source = 'Standard_D4s_v4'; Series = 'v6'; Maker = 'Intel' }
    ) {
        $c = InModuleScope VmMigrationFactory -Parameters @{ s = $Source; c = (AsCatalog); g = $Series } {
            param($s, $c, $g) @(Get-VmfShapeSizeChoices -SourceSize $s -CatalogBySize $c -HyperVGeneration 'V2' -TargetGeneration $g)
        }
        @($c).Count | Should -BeGreaterThan 1
        AsMakers $c | Should -Be @($Maker)
    }
}

Describe 'AMD-SHAPE-1: the target options, the save and the wave editor follow the same rule' {

    It 'the v5 option of a Generation 1 AMD machine lists AMD sizes only, at version 14, and fits the schema' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((AsVm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (AsCatalog -NoTwin) } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $advice.schemaVersion | Should -Be 33 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); REBUILD-PICKER-1 made it 23; GEN1-ROUTE-GONE-1 made it 22; IDENTITY-LOSS-1 made it 21; a v13 file can offer an AMD machine an Intel size, so it is refused and made again; v15 (BSV2-TARGET-1) added the Bsv2 choice of a B v1 machine, which an AMD machine never has; v16 (DISKS-32-1) the reason too-many-data-disks; v17 (AN-ONE-NIC-1) the reason one-accelerated-nic; v18 (ADVISE-AN-1) keptOn and the start that keeps accelerated networking; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine'
        $v5 = @(@($advice.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
        $v5.supported | Should -BeTrue
        $v5.targetSize | Should -Be 'Standard_E4ads_v5'
        AsMakers $v5.sizeChoices | Should -Be @('AMD')
        $advice.assessmentHash = '0' * 64
        $advice | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'with no AMD size, the v5 option is not supported, for the reason no-amd-shape-fit, and fits the schema' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((AsVm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (AsCatalog -NoAmd) } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $v5 = @(@($advice.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
        $v5.supported | Should -BeFalse
        @($v5.notSupported) | Should -Be @('no-amd-shape-fit')
        $v5.targetSize | Should -BeNullOrEmpty
        @($v5.sizeChoices).Count | Should -Be 0
        $advice.assessmentHash = '0' * 64
        $advice | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the wave editor: a machine planned on an Intel shape size before this item does not agree with the rules' {
        $vm = AsVm
        $agrees = { param([string]$Size)
            $entry = [pscustomobject]@{ assessment = $vm; path = 'A'; target = [pscustomobject]@{ size = $Size } }
            InModuleScope VmMigrationFactory -Parameters @{ e = $entry; c = (AsCatalog -NoTwin) } {
                param($e, $c) Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current 'v5'
            }
        }
        & $agrees 'Standard_D4ds_v5' | Should -BeFalse -Because 'an Intel size is not one of its choices now'
        & $agrees 'Standard_E4ads_v5' | Should -BeTrue
        & $agrees 'Standard_D8ads_v5' | Should -BeTrue
    }

    Context 'the save' {
        BeforeEach {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((AsCatalog -NoTwin).Values) }
            $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-amd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-10-09T00:00:00Z'
                scope = @{ subscriptions = @() }; summary = @{}; vms = @((AsVm)) }
            InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp; d = $doc } {
                param($p0, $d)
                Initialize-VmfRun -RunPath $p0 -RunId (Split-Path $p0 -Leaf) -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $p0 -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
            $script:adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp } {
                param($p0) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p0 -RelPath 'target-advice.json'))
            }
        }
        AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

        It 'an Intel size for an AMD machine is refused, and nothing is saved' {
            $one = @{ vmId = [string](AsVm).vmId; option = 'v5'; size = 'Standard_D4ds_v5' }
            { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @($one) -Default 'extended' -ExpectedAdviceVersion $script:adviceVersion `
                    -OnBehalfOf @{ Identity = 'person@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } } |
                Should -Throw '400: *cannot take the size Standard_D4ds_v5*'
            Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
        }

        It 'an AMD size is saved' {
            $one = @{ vmId = [string](AsVm).vmId; option = 'v5'; size = 'Standard_D8ads_v5' }
            Set-VmfTestTargetChoice -RunPath $script:rp -Choices @($one) -Default 'extended' -ExpectedAdviceVersion $script:adviceVersion `
                -OnBehalfOf @{ Identity = 'person@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            $saved = @((Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20).choices)[0]
            $saved.size | Should -Be 'Standard_D8ads_v5'
        }

        It 'target options made at version 13, which could offer an Intel size, are refused and must be made again' {
            $file = Join-Path $script:rp 'target-advice.json'
            $old = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
            $old.schemaVersion = 13
            $old | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file -Encoding utf8
            $v = InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp } {
                param($p0) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p0 -RelPath 'target-advice.json'))
            }
            $one = @{ vmId = [string](AsVm).vmId; option = 'v5' }
            { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @($one) -Default 'extended' -ExpectedAdviceVersion $v `
                    -OnBehalfOf @{ Identity = 'person@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } } |
                Should -Throw '409: *older version*'
        }
    }
}
