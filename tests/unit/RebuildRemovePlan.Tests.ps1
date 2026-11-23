#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-PLAN-1: no plan and no target option rebuilds a machine.
#
# THE DECISION (2026-11-07). The rebuild around the same disks (Path B)
# is removed. Every move is the in-place upgrade (Path A), or the in-place
# upgrade (Preview): Path A on a subscription where Microsoft's preview feature
# VMTempDiskResizePreview is registered (TEMP-DISK-PREVIEW-1). Generation 1 to
# Generation 2 is out of scope. A machine with Azure Disk Encryption whose move
# changes the kind of temporary disk stays refused.
#
# THE DEFECT THIS CLOSES. Get-VmfPathSelection returned 'B' for every Windows
# machine whose move changes the kind of temporary disk, unless a person had
# saved the Preview. A Generation 1 machine, and a machine whose generation the
# scan did not read, could not take the Preview at all, so their only move was
# a rebuild, which deletes the VM definition with its system-assigned identity,
# its extensions and the links other services hold.
#
# THE MEASUREMENTS (docs/research/temp-disk-in-place-preview.md, 2026-11-01,
# 2026-11-02 and 2026-11-07): with the feature registered, Azure resized a
# Windows machine in place, forward and back, from a SCSI temporary disk to an
# NVMe temporary disk or to none on Generation 2, and to none on Generation 1
# (v5 and Bsv2), on F, A v2, D v2, Dv4 and Dasv4 sources and Windows Server
# 2016 to 2025. Nothing else is measured, and unknown is never a yes.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    # One catalog entry per size, as Get-VmfSkuCatalog gives it, from the
    # catalogs read from centralus (the same fixtures Bsv2Target uses).
    function Global:RrEntries([string]$File) {
        $doc = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $File) -Raw | ConvertFrom-Json
        foreach ($s in @($doc.sizes)) {
            $caps = @(foreach ($pr in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $pr.Name; Value = [string]$pr.Value } })
            [pscustomobject]@{
                Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                Family = $(if ($s.PSObject.Properties['family']) { [string]$s.family } else { 'standardX' })
                Restrictions = @(); LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
            }
        }
    }
    $script:allEntries = @(RrEntries 'old-size-catalog-centralus.json') + @(RrEntries 'bsv2-catalog-centralus.json')
    # The v4 sources of the measurements are not in those catalogs (they hold
    # the targets): each is its v5 twin by shape, under its own name.
    foreach ($pair in @(@('Standard_D2ds_v4', 'Standard_D2ds_v5'), @('Standard_D2s_v4', 'Standard_D2s_v5'), @('Standard_D2s_v3', 'Standard_D2ds_v5'))) {
        $twin = @($script:allEntries | Where-Object Name -EQ $pair[1])[0]
        $script:allEntries += [pscustomobject]@{ Name = $pair[0]; ResourceType = 'virtualMachines'; Capabilities = $twin.Capabilities
            Family = $twin.Family; Restrictions = @(); LocationInfo = $twin.LocationInfo }
    }
    function Global:RrCatalog {
        $c = @{}
        foreach ($e in $script:allEntries) { $c[$e.Name] = $e }
        $c
    }
    function Global:RrTemp([string]$Size) {
        $e = @($script:allEntries | Where-Object Name -EQ $Size)[0]
        $cap = @($e.Capabilities | Where-Object Name -EQ 'MaxResourceVolumeMB')[0]
        [int64]$cap.Value
    }
    # A scanned machine, as the assessment holds it.
    function Global:RrVm {
        param([string]$Size = 'Standard_D2ds_v4', [string]$Gen = 'V2', [string]$Os = 'Windows', [string]$Name = 'win-01',
              [switch]$Encrypted, [string]$Arch)
        $temp = RrTemp $Size
        $blockers = @(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' }; if ($Encrypted) { 'disk-encryption-present' })
        $kind = if ($Arch) { $Arch } elseif ($temp -gt 0) { 'scsi-temp' } else { 'diskless' }
        [pscustomobject]@{
            vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter' } else { '22_04-lts' })
            classification = $(if ($blockers.Count) { 'Blocked' } else { 'ReadyAfterPrep' }); blockers = $blockers; prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $kind; sourceTempDisks = $(if ($kind -eq 'scsi-temp') { 1 } else { 0 })
            diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = 0; nicCount = 1
            acceleratedNicCount = 0; primaryNicAccelerated = $false; platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'SystemAssigned'
            identityPrincipalId = '11111111-2222-3333-4444-555555555555'; tags = @{ app = $Name }
        }
    }
    function Global:RrPath($Vm, [string]$To, [string]$Series = 'v6') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; a = $To; s = $Series } {
            param($v, $a, $s) Get-VmfPathSelection -Assessment $v -TargetDiskArch $a -TargetGeneration $s
        }
    }
    function Global:RrShape($Vm, [string]$To) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; a = $To } {
            param($v, $a) if ($a) { Test-VmfPreviewShape -Assessment $v -TargetDiskArch $a } else { Test-VmfPreviewShape -Assessment $v }
        }
    }
    function Global:RrTarget($Vm, [string]$Series = 'v6', [string]$Chosen = '') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = (RrCatalog); s = $Series; ch = $Chosen } {
            param($v, $c, $s, $ch) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s -ChosenSize $ch
        }
    }
    function Global:RrAdvise([object[]]$Vms) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (RrCatalog) } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
}
AfterAll {
    Remove-Item 'function:\RrEntries', 'function:\RrCatalog', 'function:\RrTemp', 'function:\RrVm', 'function:\RrPath', 'function:\RrShape',
        'function:\RrTarget', 'function:\RrAdvise' -ErrorAction SilentlyContinue
}

Describe 'REBUILD-REMOVE-PLAN-1: the path of a move is never a rebuild' {
    It 'no machine of any shape, on any series, is given Path B' {
        $seen = foreach ($os in 'Windows', 'Linux') {
            foreach ($gen in 'V1', 'V2', '') {
                foreach ($from in 'scsi-temp', 'nvme-temp', 'diskless', '') {
                    foreach ($to in 'scsi-temp', 'nvme-temp', 'diskless') {
                        foreach ($series in 'v5', 'v6', 'v7') {
                            $vm = [pscustomobject]@{ os = $os; gen = $gen; sourceDiskArch = $from; sourceSize = 'Standard_D2ds_v4'
                                classification = 'ReadyAfterPrep'; platformManaged = $false; diskController = 'SCSI' }
                            RrPath $vm $to $series
                        }
                    }
                }
            }
        }
        @($seen) | Should -Not -Contain 'B'
        @($seen | Sort-Object -Unique) | Should -Contain 'A'
        @($seen | Sort-Object -Unique) | Should -Contain 'MANUAL' -Because 'a shape nobody measured has no move at all'
    }
    It 'THE DEFECT: a Windows Generation 2 machine with a SCSI temporary disk is upgraded in place to <To>, with no saved method' -ForEach @(
        @{ To = 'nvme-temp' }, @{ To = 'diskless' }
    ) {
        RrPath (RrVm) $To 'v6' | Should -Be 'A'
        RrPath (RrVm) $To 'v7' | Should -Be 'A'
    }
    It 'a Windows Generation 1 machine with a SCSI temporary disk is upgraded in place to a size with none (measured on v5 and Bsv2)' {
        # The series judges the classification (GEN-V5-1 C3): v5 takes Generation 1.
        $vm = RrVm -Gen 'V1'
        $vm.classification = 'ReadyAfterPrep'
        RrPath $vm 'diskless' 'v5' | Should -Be 'A'
    }
    It 'never for a shape nobody measured: <Case>' -ForEach @(
        @{ Case = 'Generation 1 to an NVMe temporary disk'; Gen = 'V1'; From = 'scsi-temp'; To = 'nvme-temp' }
        @{ Case = 'a generation the scan did not read'; Gen = ''; From = 'scsi-temp'; To = 'diskless' }
        @{ Case = 'an NVMe temporary disk to a SCSI one'; Gen = 'V2'; From = 'nvme-temp'; To = 'scsi-temp' }
        @{ Case = 'a kind of temporary disk the scan did not read'; Gen = 'V2'; From = 'unread'; To = 'diskless' }
    ) {
        $vm = RrVm -Gen $Gen -Arch $From
        $vm.classification = 'ReadyAfterPrep'
        if ($From -eq 'unread') { $vm.sourceDiskArch = '' }
        RrPath $vm $To 'v5' | Should -Be 'MANUAL'
    }
    It 'no temporary disk to an NVMe temporary disk is the in-place upgrade with no feature (measured 2026-11-07, feature not registered), on <Series>' -ForEach @(
        @{ Series = 'v6' }, @{ Series = 'v7' }
    ) {
        $vm = RrVm -Size 'Standard_D2s_v5' -Arch 'diskless'
        RrPath $vm 'nvme-temp' $Series | Should -Be 'A'
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Test-VmfTempDiskKindChanges -Assessment $v -TargetDiskArch 'nvme-temp' } | Should -BeFalse
    }
    It 'and the way back, an NVMe temporary disk to none, is the same plain in-place upgrade (the way back of the same six checks)' {
        $vm = RrVm -Arch 'nvme-temp'
        $vm.classification = 'ReadyAfterPrep'
        RrPath $vm 'diskless' 'v6' | Should -Be 'A'
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Test-VmfTempDiskKindChanges -Assessment $v -TargetDiskArch 'diskless' } | Should -BeFalse
    }
    It 'the same kind of temporary disk, and any Linux machine, is the in-place upgrade as before' {
        RrPath (RrVm) 'scsi-temp' 'v5' | Should -Be 'A'
        RrPath (RrVm -Os 'Linux' -Gen '') 'nvme-temp' 'v6' | Should -Be 'A'
    }
    It 'the path function takes no method any more: the method is a fact of the move' {
        InModuleScope VmMigrationFactory { (Get-Command Get-VmfPathSelection).Parameters.ContainsKey('Method') | Should -BeFalse }
        InModuleScope VmMigrationFactory { (Get-Command Resolve-VmfEntryTarget).Parameters.ContainsKey('Method') | Should -BeFalse }
    }
    It 'the planner code returns no B and has no rebuild method' {
        $planner = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $planner | Should -Not -Match "return 'B'"
        $method = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'MoveMethod.ps1')
        $method | Should -Not -Match "'rebuild'"
        InModuleScope VmMigrationFactory {
            (Get-Command Get-VmfMoveMethod).Parameters.ContainsKey('Rebuild') | Should -BeFalse
            Get-VmfMoveMethod -Preview | Should -Be 'preview'
            Get-VmfMoveMethod | Should -Be 'in-place'
            Get-Command Select-VmfInPlaceStart -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Command Select-VmfIdentityKeepingStart -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe 'REBUILD-REMOVE-PLAN-1: the shape the preview feature moves follows the measurements' {
    It 'Generation <Gen> with a SCSI temporary disk to <To>: <Want>' -ForEach @(
        @{ Gen = 'V2'; To = 'nvme-temp'; Want = $true }
        @{ Gen = 'V2'; To = 'diskless'; Want = $true }
        @{ Gen = 'V1'; To = 'diskless'; Want = $true }
        @{ Gen = 'V1'; To = 'nvme-temp'; Want = $false }
        @{ Gen = ''; To = 'diskless'; Want = $false }
        @{ Gen = 'V3'; To = 'diskless'; Want = $false }
    ) {
        RrShape (RrVm -Gen $Gen) $To | Should -Be $Want
    }
    It 'Generation 1 is of the shape, and an unknown generation is not, also with no target named' {
        RrShape (RrVm -Gen 'V1') '' | Should -BeTrue
        RrShape (RrVm -Gen '') '' | Should -BeFalse
        RrShape ([pscustomobject]@{ os = 'Windows'; sourceDiskArch = 'scsi-temp'; hyperVGeneration = 'V1' }) '' | Should -BeTrue
    }
    It 'never Linux, and never a source with no SCSI temporary disk' {
        RrShape (RrVm -Os 'Linux') 'diskless' | Should -BeFalse
        RrShape (RrVm -Arch 'diskless') 'nvme-temp' | Should -BeFalse
        RrShape (RrVm -Arch 'nvme-temp') 'diskless' | Should -BeFalse
    }
}

Describe 'REBUILD-REMOVE-PLAN-1: the target of each measured shape' {
    It 'Windows Server, Generation <Gen>, <Size> on <Series> (<Chosen>) is the in-place upgrade (Preview)' -ForEach @(
        @{ Size = 'Standard_D2ds_v4'; Gen = 'V2'; Series = 'v6'; Chosen = '' }
        @{ Size = 'Standard_D2ds_v4'; Gen = 'V2'; Series = 'v7'; Chosen = '' }
        @{ Size = 'Standard_F2s_v2'; Gen = 'V2'; Series = 'v6'; Chosen = '' }
        @{ Size = 'Standard_DS2_v2'; Gen = 'V2'; Series = 'v6'; Chosen = '' }
        # Generation 1 is sized by shape, which keeps the d (OLD-SKU-1B): its one move to
        # no temporary disk is the Bsv2 size of a B v1 machine.
        @{ Size = 'Standard_D2s_v3'; Gen = 'V2'; Series = 'v5'; Chosen = 'Standard_D2s_v5' }
        @{ Size = 'Standard_B2s'; Gen = 'V1'; Series = 'v5'; Chosen = 'Standard_B2ls_v2' }
    ) {
        $t = RrTarget (RrVm -Size $Size -Gen $Gen) $Series $Chosen
        [string]$t.Mapping.Target | Should -Not -BeNullOrEmpty -Because "$Size has a target on $Series"
        if ($Chosen) { $t.Mapping.Target | Should -Be $Chosen }
        $t.Path | Should -Be 'A'
        $t.Preview | Should -BeTrue
        $t.Keys | Should -Not -Contain 'RefusedRebuild'
        $t.Keys | Should -Not -Contain 'PreviewOffered'
    }
    It 'a size that keeps the SCSI temporary disk is the in-place upgrade with no feature: Generation 1 <Size>' -ForEach @(
        @{ Size = 'Standard_D2ds_v4' }, @{ Size = 'Standard_F2s_v2' }, @{ Size = 'Standard_A2_v2' }, @{ Size = 'Standard_D2_v2' }
    ) {
        # The sizes by shape and the name twins keep the d (V4-NAMES-1, OLD-FAM-1).
        $t = RrTarget (RrVm -Size $Size -Gen 'V1') 'v5'
        [string]$t.Mapping.Target | Should -Match 'd'
        $t.Path | Should -Be 'A'
        $t.Preview | Should -BeFalse
    }
    It 'a Linux machine never takes the Preview' {
        $t = RrTarget (RrVm -Os 'Linux') 'v6'
        $t.Path | Should -Be 'A'
        $t.Preview | Should -BeFalse
    }
    It 'a generation the scan did not read: no target, MANUAL, and the reason says to scan again' {
        $t = RrTarget (RrVm -Gen '') 'v6'
        $t.Path | Should -Be 'MANUAL'
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'generation-unknown'
        $t.Mapping.Reason | Should -Match 'did not read the generation'
        $t.Mapping.Reason | Should -Match 'Scan'
        $t.Preview | Should -BeFalse
        $t.DiskArch | Should -BeNullOrEmpty
    }
    It 'a Windows machine with no temporary disk to a size with an NVMe temporary disk needs no reason and no feature' {
        $vm = RrVm -Size 'Standard_D2s_v5' -Arch 'diskless'
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            param($v) Get-VmfNoInPlaceMove -Assessment $v -TargetDiskArch 'nvme-temp' -TargetGeneration 'v6' } | Should -BeNullOrEmpty
    }
    It 'a shape nobody measured has a reason in words that names both kinds of temporary disk' {
        $vm = RrVm -Arch 'nvme-temp'
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            param($v) Get-VmfNoInPlaceMove -Assessment $v -TargetDiskArch 'scsi-temp' -TargetGeneration 'v5'
        }
        $r.Code | Should -Be 'temp-disk-change-not-measured'
        $r.Reason | Should -Match 'from an NVMe temporary disk to a SCSI temporary disk'
    }
    It 'an encrypted Windows machine whose move changes the kind of temporary disk stays refused, with the reason in words' {
        # V5-ADE-1 is a v5 rule: the scan already blocks an encrypted machine on
        # v6 and v7 (disk-encryption-present). On v5 the size with no temporary
        # disk of a v3 machine changes the kind.
        $t = RrTarget (RrVm -Size 'Standard_D2s_v3' -Encrypted) 'v5' 'Standard_D2s_v5'
        $t.Classification | Should -Be 'Blocked'
        @($t.Blockers) | Should -Contain 'disk-encryption-preview'
        $t.Mapping.Code | Should -Be 'disk-encryption-preview'
        $t.Mapping.Reason | Should -Match 'Azure Disk Encryption'
        $t.Mapping.Reason | Should -Match 'Preview'
        $t.Mapping.Reason | Should -Not -Match 'rebuil'
        $t.Path | Should -Be 'MANUAL'
        $t.Preview | Should -BeFalse
    }
    It 'an encrypted machine that keeps the SCSI temporary disk on v5 still moves in place' {
        $t = RrTarget (RrVm -Size 'Standard_D2s_v3' -Encrypted) 'v5'
        $t.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        $t.Path | Should -Be 'A'
        @($t.Blockers) | Should -Not -Contain 'disk-encryption-preview'
    }
    It 'an encrypted Windows B v1 machine is not offered its Bsv2 size, and the reason names the Preview' {
        $t = RrTarget (RrVm -Size 'Standard_B2s' -Gen 'V1' -Encrypted) 'v5'
        $t.BurstableTarget | Should -Be 'disk-encryption-preview'
        @($t.SizeChoices | Where-Object { $_.family -eq 'Bsv2' }).Count | Should -Be 0
        $t.Path | Should -Be 'A' -Because 'it moves in place to its D or E d size'
    }
}

Describe 'REBUILD-REMOVE-PLAN-1: the target advice offers no rebuild (v28)' {
    BeforeAll {
        $script:doc = RrAdvise @((RrVm -Name 'win-01'), (RrVm -Name 'gen1-01' -Gen 'V1' -Size 'Standard_B2s'), (RrVm -Name 'nogen-01' -Gen ''))
        $script:m = @{}; foreach ($x in @($script:doc.machines)) { $script:m[$x.name] = $x }
    }
    It 'is version 29 (SIZE-FALLTHROUGH-NOTE-1 added sizesNotTaken after this item made it 28) and passes its schema' {
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
        $script:doc.schemaVersion | Should -Be 34
        ($script:doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
    It 'no option and no size choice carries rebuild or identity, and no machine carries identityPrincipalId or decide' {
        foreach ($x in @($script:doc.machines)) {
            $x.Keys | Should -Not -Contain 'identityPrincipalId'
            $x.Keys | Should -Not -Contain 'decide'
            foreach ($o in @($x.options)) {
                $o.Keys | Should -Not -Contain 'rebuild'
                $o.Keys | Should -Not -Contain 'identity'
                [string]$o.path | Should -Not -Be 'B'
                foreach ($c in @($o.sizeChoices)) {
                    $c.Keys | Should -Not -Contain 'rebuild'
                    $c.Keys | Should -Not -Contain 'identity'
                    [string]$c.path | Should -Not -Be 'B'
                }
            }
        }
    }
    It 'a Windows Generation 2 D2ds_v4 starts on v6 under Current, the in-place upgrade (Preview)' {
        $x = $script:m['win-01']
        $x.start.current | Should -Be 'v6' -Because 'the start is the first supported option in the order of the default'
        $x.start.extended | Should -Be 'v5'
        (@($x.options) | Where-Object option -EQ 'v6').preview | Should -BeTrue
        (@($x.options) | Where-Object option -EQ 'v7').preview | Should -BeTrue
        (@($x.options) | Where-Object option -EQ 'v5').preview | Should -BeFalse -Because 'D2ds_v5 keeps the SCSI temporary disk'
    }
    It 'a Windows Generation 1 B2s starts on its Bsv2 size, the in-place upgrade (Preview)' {
        $x = $script:m['gen1-01']
        $x.start.current | Should -Be 'v5'
        $v5 = @($x.options) | Where-Object option -EQ 'v5'
        $v5.supported | Should -BeTrue
        $v5.targetSize | Should -Match '_v2$'
        $v5.preview | Should -BeTrue
        $v5.burstableTarget | Should -Be 'offered'
    }
    It 'a machine whose generation the scan did not read has no option that changes its kind of temporary disk' {
        $x = $script:m['nogen-01']
        foreach ($s in 'v6', 'v7') {
            $o = @($x.options) | Where-Object option -EQ $s
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Contain 'generation-unknown'
        }
    }
    It 'the schema has no rebuild, no identity and no path B, and the sample passes it' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        $s = $schema | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 34
        $schema | Should -Not -Match '"rebuild"'
        $schema | Should -Not -Match '"identityPrincipalId"'
        $reasons = @($s.'$defs'.reason.enum)
        $reasons | Should -Not -Contain 'disk-encryption-rebuild'
        $reasons | Should -Contain 'disk-encryption-preview'
        $reasons | Should -Contain 'generation-unknown'
        $reasons | Should -Contain 'temp-disk-change-not-measured'
        @($s.'$defs'.option.properties.path.enum) | Should -Not -Contain 'B'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'target-advice.sample.json') -Raw
        $sample | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
        $sample | Should -Not -Match '"rebuild"'
    }
}

Describe 'REBUILD-REMOVE-PLAN-1: the contracts of the choices and the plan' {
    It 'target-choices records in-place or preview; a file that names rebuild fails the schema, and so does a v7 file' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json'
        $one = { param([int]$V, [string]$M)
            [ordered]@{ schemaVersion = $V; assessmentId = 'scan-1'; assessmentHash = $null; adviceVersion = 'x'; machinesVersion = 'y'; default = 'current'; kernelDefault = 'stop'
                savedBy = @{ identity = 'operator@example.com' }; savedUtc = '2026-11-07T00:00:00Z'
                choices = @([ordered]@{ vmId = 'vm-1'; option = 'v6'; source = 'default'; started = 'v6'; size = $null; disks = $null; method = $M; kernel = $null }) } | ConvertTo-Json -Depth 8 }
        (& $one 9 'preview') | Test-Json -SchemaFile $schemaFile | Should -BeTrue
        (& $one 9 'in-place') | Test-Json -SchemaFile $schemaFile | Should -BeTrue
        (& $one 9 'rebuild') | Test-Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (& $one 7 'rebuild') | Test-Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'TARGETS-NO-LIST-1: only the version this product writes'
        Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'target-choices.sample.json') -Raw | Test-Json -SchemaFile $schemaFile | Should -BeTrue
    }
    It 'plan-entry v29: the plan writes 29, and the sample passes the schema' {
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
        $pe = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $pe.properties.schemaVersion.const | Should -Be 37
        Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }
    It 'a plan of version 28 still reads, path B and method rebuild included' {
        $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'vm-1'; path = 'B'
                    target = [pscustomobject]@{ choice = [pscustomobject]@{ method = 'rebuild' } }; policy = [pscustomobject]@{} }) }
        $read = InModuleScope VmMigrationFactory -Parameters @{ p = $plan } { param($p) ConvertTo-VmfSupportedPlan -Plan $p }
        @($read.entries)[0].path | Should -Be 'B'
    }
    It 'the migration note names the three versions' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match ([regex]::Escape('## target-advice v27 -> v28, target-choices v7 -> v8, plan-entry v28 -> v29 (2026-11-07, REBUILD-REMOVE-PLAN-1)'))
    }
}

Describe 'REBUILD-REMOVE-PLAN-1: from the targets to the plan and the wave editor' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = "$($script:rp)-mig"
        $vms = foreach ($v in @((RrVm -Name 'win-01'), (RrVm -Name 'win-02'))) {
            $h = [ordered]@{}; foreach ($pr in $v.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
            $h.rebuildLinks = [ordered]@{ extensions = @() }
            $h }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-11-07T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($vms) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        $script:catalogList = @((RrCatalog).Values)
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalogList }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $script:sub } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        $script:version = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
        $script:id = { param([string]$Name) "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
        Set-VmfMachineChoice -RunPath $script:rp -Machines @((& $script:id 'win-01'), (& $script:id 'win-02')) -ExpectedAdviceVersion $script:version `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = $script:sub } | Out-Null
        $script:machines = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'machine-choices.json')) }
        $script:who = @{ Identity = 'operator@example.com'; TenantId = $script:sub }
        $script:save = { param([object[]]$Choices)
            Set-VmfTestTargetChoice -RunPath $script:rp -Choices $Choices -Default 'current' -ExpectedAdviceVersion $script:version `
                -ExpectedChoicesVersion '' -ExpectedMachinesVersion $script:machines -OnBehalfOf $script:who }
    }
    AfterEach { foreach ($d in @($script:rp, $script:mig)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } } }

    It 'the save records preview for a size that changes the kind of temporary disk, and the plan moves it in place as a Preview' {
        & $script:save @(@{ vmId = (& $script:id 'win-01'); option = 'v6' }, @{ vmId = (& $script:id 'win-02'); option = 'v5'; method = 'in-place' }) | Out-Null
        $saved = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20
        $saved.schemaVersion | Should -Be 9
        (@($saved.choices) | Where-Object { $_.vmId -like '*/win-01' }).method | Should -Be 'preview' -Because 'a choice with no method takes the method of its size'
        (@($saved.choices) | Where-Object { $_.vmId -like '*/win-02' }).method | Should -Be 'in-place'
        Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $one = @($plan.entries) | Where-Object { $_.vmId -like '*/win-01' }
        $two = @($plan.entries) | Where-Object { $_.vmId -like '*/win-02' }
        $one.path | Should -Be 'A'
        $one.target.choice.method | Should -Be 'preview'
        $two.path | Should -Be 'A'
        $two.target.choice.method | Should -Be 'in-place'
        $one.schemaVersion | Should -Be 37
        $one.assessment.PSObject.Properties.Name | Should -Not -Contain 'rebuildLinks' -Because 'nothing reads what a rebuild would delete any more'
        $one.assessment.PSObject.Properties.Name | Should -Not -Contain 'hibernationEnabled' -Because 'PLAN-HIBERNATION-UNUSED-1: nothing reads the plan entry''s copy of the scan''s hibernation fact'
        @($plan.entries | Where-Object { $_.path -eq 'B' }).Count | Should -Be 0
        foreach ($e in @($plan.entries)) {
            ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        }
    }

    It 'a request that names rebuild is refused, by name, and nothing is saved' {
        { & $script:save @(@{ vmId = (& $script:id 'win-01'); option = 'v6'; method = 'rebuild' }) } |
            Should -Throw "400: The machine 'win-01' cannot take*rebuild*"
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }

    It 'the plan refuses a saved rebuild, by name, before anything is written' {
        & $script:save @(@{ vmId = (& $script:id 'win-01'); option = 'v6' }, @{ vmId = (& $script:id 'win-02'); option = 'v5' }) | Out-Null
        $file = Join-Path $script:rp 'target-choices.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json -Depth 20
        (@($doc.choices) | Where-Object { $_.vmId -like '*/win-01' }).method = 'rebuild'
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; d = $doc } { param($r, $d) Write-VmfStoreJson -RunPath $r -RelPath 'target-choices.json' -Document $d -Depth 20 }
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } |
            Should -Throw '*win-01*Choose the targets again*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }

    It 'WAVE-PREVIEW-1: Change target in the wave editor plans the new series as the in-place upgrade (Preview)' {
        & $script:save @(@{ vmId = (& $script:id 'win-01'); option = 'v6' }, @{ vmId = (& $script:id 'win-02'); option = 'v5' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $before = Set-VmfMachineTarget -RunPath $script:mig -VmId (& $script:id 'win-01') -WhatIf
        $v7 = @($before.Options) | Where-Object option -EQ 'v7'
        $v7.supported | Should -BeTrue
        $v7.preview | Should -BeTrue
        $v7.PSObject.Properties.Name | Should -Not -Contain 'rebuild'
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (& $script:id 'win-01') -Option 'v7' -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $one = @($plan.entries) | Where-Object { $_.vmId -like '*/win-01' }
        $one.path | Should -Be 'A'
        $one.target.choice.method | Should -Be 'preview'
        $one.target.size | Should -Match '_v7$'
        # And the rules in use now agree with the entry, so the next change
        # and the worker's check read it as current.
        $catalog = RrCatalog
        InModuleScope VmMigrationFactory -Parameters @{ e = $one; c = $catalog } {
            param($e, $c) Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current 'v7' } | Should -BeTrue
        $after = Set-VmfMachineTarget -RunPath $script:mig -VmId (& $script:id 'win-01') -Option 'v5' -ChangedBy 'operator@example.com' -Confirm:$false
        $after.Applied | Should -BeTrue
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        (@($plan.entries) | Where-Object { $_.vmId -like '*/win-01' }).target.choice.method | Should -Be 'in-place'
    }
}
