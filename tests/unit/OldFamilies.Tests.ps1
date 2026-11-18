#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-FAM-4: the last of the old families, checked against REAL sizes.
#
# OLD-SKU-1B, OLD-SKU-V6-1 and OLD-FAM-1 gave the old families a target by
# shape. Their tests used a dozen hand-made sizes. This file runs EVERY size of
# those families that Azure offers in centralus against every Intel D, Dl and E
# size Azure offers there (tests/fixtures/old-size-catalog-centralus.json, read
# 2026-10-04): a full machine - as many network interfaces and data disks as
# its size takes - must get a target on each series that takes its generation.
#
# And two things those parts left:
#   - A v1 (Basic A, Standard A0 to A11). Microsoft retired it on 2024-08-31
#     and deallocated every machine on it. Azure no longer lists the sizes, so
#     the scan called them "not in this region" or "processor unreadable".
#     A size past its retirement date cannot start, and the move must start
#     the machine to prepare it - so the scan says the size is retired. Read
#     from the retirement data, so B v1, F and the rest get the same answer
#     on their own date.
#   - B v1 is burstable: it runs on CPU credits. Every target is a D or E size
#     with full CPU performance all the time. The advice says so.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'old-size-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:catalog = @{}
    foreach ($s in @($fixture.sizes)) {
        $caps = @(foreach ($p in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $p.Name; Value = [string]$p.Value } })
        $script:catalog[$s.name] = [pscustomobject]@{
            Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
            Restrictions = @(@($s.restrictions) | ForEach-Object { [pscustomobject]@{ Type = $_.type; ReasonCode = $_.reasonCode; RestrictionInfo = [pscustomobject]@{ Zones = @($_.zones) } } })
            LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
        }
    }
    function Global:OfCap($Entry, [string]$Name) {
        $c = @($Entry.Capabilities | Where-Object { $_.Name -eq $Name })
        if ($c.Count) { [string]$c[0].Value } else { $null }
    }
    # A machine on this size, as full as the size allows - and, since
    # DISKS-32-1, never more than 32 data disks: a machine with more is
    # outside the scope of this tool (tested below and in Disks32.Tests.ps1).
    function Global:OfMachine([string]$Size, [string]$Gen, $Catalog, [switch]$AllDisks) {
        $e = $Catalog[$Size]
        $temp = [int](OfCap $e 'MaxResourceVolumeMB')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m"
            name = 'm'; location = 'centralus'; gen = $Gen; os = 'Linux'; osVersion = '22_04-lts'
            classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $(if ($temp -gt 0) { 'scsi-temp' } else { 'diskless' })
            sourceTempDisks = $(if ($temp -gt 0) { 1 } else { 0 }); diskController = 'SCSI'
            nicCount = [int](OfCap $e 'MaxNetworkInterfaces')
            dataDiskCount = $(if ($AllDisks) { [int](OfCap $e 'MaxDataDiskCount') } else { [Math]::Min(32, [int](OfCap $e 'MaxDataDiskCount')) })
            acceleratedNicCount = 0; platformManaged = $false
        }
    }
    $script:sourcePattern = '^Standard_(A\d+m?_v2|B\d+(ls|s|ms)|F\d+s?(_v2)?|DS?\d+(-\d+)?(_v2)?(_Promo)?)$'
}
AfterAll { Remove-Item function:OfCap, function:OfMachine -ErrorAction SilentlyContinue }

Describe 'OLD-FAM-4: every old size Azure offers gets a target by shape, from real sizes' {
    It 'the fixture holds every family, so this cannot pass by reading nothing' {
        $names = @($script:catalog.Keys)
        foreach ($p in '^Standard_A\d+_v2$', '^Standard_A\d+m_v2$', '^Standard_B\d+(ls|s|ms)$', '^Standard_F\d+$',
                       '^Standard_F\d+s$', '^Standard_F\d+s_v2$', '^Standard_D\d+$', '^Standard_DS\d+$', '^Standard_D\d+_v2$', '^Standard_DS\d+(-\d+)?_v2$') {
            @($names | Where-Object { $_ -match $p }).Count | Should -BeGreaterThan 2 -Because "the family $p"
        }
    }

    It 'a full machine on each size gets a target on each series that takes its generation, and the target holds it' {
        $failures = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($src in @($script:catalog.Keys | Where-Object { $_ -match $script:sourcePattern } | Sort-Object)) {
            $e = $script:catalog[$src]
            foreach ($gen in @((OfCap $e 'HyperVGenerations') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $series = if ($gen -eq 'V1') { @('v5') } else { @('v5', 'v6', 'v7') }
                foreach ($s in $series) {
                    $vm = OfMachine $src $gen $script:catalog
                    $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog; s = $s } {
                        param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
                    }
                    $checked++
                    $to = [string]$t.Mapping.Target
                    $what = "$src ($gen) on $s"
                    if (-not $to) {
                        # DISKS-32-1: the one miss this test allowed - more
                        # data disks than any v5 shape size takes (D14_v2,
                        # DS5_v2, F16 take 64) - is gone: the machine has at
                        # most 32 (OfMachine), and every one now gets a target.
                        $failures.Add("$what - no target: $($t.Mapping.Code)"); continue
                    }
                    if ($t.Path -notin @('A', 'B')) { $failures.Add("$what - path $($t.Path)"); continue }
                    $te = $script:catalog[$to]
                    if (-not $te) { $failures.Add("$what - $to is not a size Azure offers"); continue }
                    if ($to -notmatch "^Standard_[DE]\d+(-\d+)?l?d?s_$s$") { $failures.Add("$what - $to is not an Intel D, Dl or E size on $s") }
                    # CONSTRAINED-DEFAULT-1: active vCPUs against active vCPUs.
                    # A constrained vCPU source (DS13-4_v2: 8 vCPUs, 4 active)
                    # keeps its 4 active on E8-4ds_v5 - not fewer than it uses.
                    $srcActive = OfCap $e 'vCPUsAvailable'
                    if (-not $srcActive) { $srcActive = OfCap $e 'vCPUs' }
                    if ([double](OfCap $te 'vCPUsAvailable') -lt [double]$srcActive) { $failures.Add("$what - $to has fewer vCPUs") }
                    if ([double](OfCap $te 'MemoryGB') -lt [double](OfCap $e 'MemoryGB')) { $failures.Add("$what - $to has less memory") }
                    if ((OfCap $te 'HyperVGenerations') -notmatch $gen) { $failures.Add("$what - $to does not take $gen") }
                    if ([int](OfCap $te 'MaxNetworkInterfaces') -lt $vm.nicCount) { $failures.Add("$what - $to takes fewer network interfaces") }
                    if ([int](OfCap $te 'MaxDataDiskCount') -lt $vm.dataDiskCount) { $failures.Add("$what - $to takes fewer data disks") }
                    if ($vm.sourceTempDisks -gt 0 -and $to -notmatch 'ds_v\d$') { $failures.Add("$what - $to drops the temporary disk") }
                }
            }
        }
        $checked | Should -BeGreaterThan 150 -Because 'every old size, on every series its generation takes'
        $failures -join "`n" | Should -BeNullOrEmpty
    }

    It 'DISKS-32-1: a machine as full as a 64-disk size allows is outside the scope of this tool on every series, in those words' {
        # This test used to accept "too-few-data-disks" on v5 for these sizes,
        # and on v6 and v7 they were planned onto a size that takes 64. Since
        # 2026-10-05, more than 32 is outside the scope.
        $big = @($script:catalog.Keys | Where-Object { $_ -match $script:sourcePattern -and [int](OfCap $script:catalog[$_] 'MaxDataDiskCount') -gt 32 } | Sort-Object)
        $big.Count | Should -BeGreaterThan 3 -Because 'D14_v2, DS5_v2, F16 and others take 64'
        foreach ($src in $big) {
            foreach ($s in 'v5', 'v6', 'v7') {
                $vm = OfMachine $src 'V2' $script:catalog -AllDisks
                $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog; s = $s } {
                    param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
                }
                [string]$t.Mapping.Target | Should -BeNullOrEmpty -Because "$src on $s"
                $t.Mapping.Code | Should -Be 'too-many-data-disks' -Because "$src on $s"
                $t.Mapping.Reason | Should -Match 'outside the scope of this tool' -Because "$src on $s"
            }
        }
    }

    It 'a machine with more network interfaces than any size of its shape takes is told that' {
        $vm = OfMachine 'Standard_F2s_v2' 'V2' $script:catalog
        $vm.nicCount = 9; $vm.dataDiskCount = 0
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5'
        }
        [string]$t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'too-few-nics'
        $t.Mapping.Reason | Should -Match '9 network interfaces'
    }

    It 'a Generation 1 machine gets no v6 or v7 target, and is told it is Generation 1' {
        foreach ($src in 'Standard_F2', 'Standard_A2_v2', 'Standard_B2s') {
            foreach ($s in 'v6', 'v7') {
                $vm = OfMachine $src 'V1' $script:catalog
                $vm.blockers = @('gen1-requires-redeploy'); $vm.classification = 'Blocked'
                $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog; s = $s } {
                    param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
                }
                [string]$t.Mapping.Target | Should -BeNullOrEmpty -Because "$src on $s"
                @($t.Blockers) | Should -Contain 'gen1-requires-redeploy'
            }
        }
    }

    It 'RETIRE-SCOPE-1: every 2028 size is outside the scope of this tool from one day before its date, and not before' {
        # V3-RETIRE-1 checked here that each of these sizes had a current v5
        # size for its rollback after the date. RETIRE-SCOPE-1
        # (2026-10-04) removed that way back: from one day before the date a
        # machine on such a size is not moved at all.
        $wrong = @(foreach ($src in @($script:catalog.Keys | Where-Object { $_ -match '^Standard_(A\d+m?_v2|B\d+(ls|s|ms)|F\d+s?(_v2)?)$' })) {
                $r = InModuleScope VmMigrationFactory -Parameters @{ s = $src } {
                    param($s)
                    $day = [datetime]::ParseExact((Get-VmfSizeRetirement -SizeName $s).RetiresUtc, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                    @((Test-VmfSizeRetiredForTool -Size $s -Now $day.AddDays(-1).AddSeconds(-1)), (Test-VmfSizeRetiredForTool -Size $s -Now $day.AddDays(-1)))
                }
                if ($r[0] -or -not $r[1]) { $src }
            })
        $wrong -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'OLD-FAM-4: A v1 is retired, and the scan says so' {
    It 'every A v1 name reads as retired on 2024-08-31, Basic and Standard' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Basic_A0', 'Basic_A4', 'Standard_A0', 'Standard_A3', 'Standard_A7') {
                $r = Get-VmfSizeRetirement -SizeName $s
                $r | Should -Not -BeNullOrEmpty -Because $s
                $r.RetiresUtc | Should -Be '2024-08-31'
            }
        }
    }

    It 'and no newer A size does' {
        InModuleScope VmMigrationFactory {
            (Get-VmfSizeRetirement -SizeName 'Standard_A2_v2').RetiresUtc | Should -Be '2028-11-15'
            (Get-VmfSizeRetirement -SizeName 'Standard_A4m_v2').RetiresUtc | Should -Be '2028-11-15'
        }
    }

    It 'the scan blocks a machine on a retired size, for every series' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_A2', 'Basic_A1') {
                $vm = [pscustomobject]@{ vmId = '/s/rg/vm/old'; name = 'old'; sku = $s; location = 'centralus'; resourceGroup = 'rg'
                    os = 'Linux'; gen = 'V1'; tags = @{}; nicIds = @(); dataDiskCount = 0; osDiskManaged = $true; securityType = '' }
                $rec = Get-VmfAssessmentRecord -Vm $vm -SkuEntry $null -NicAcceleratedMap @{} -ManagedPlatformGroups @{} -SapSystemVms @{} -AvdSessionHosts @{}
                @($rec.blockers) | Should -Contain 'size-retired' -Because $s
            }
        }
    }

    It 'a size retires on its own date, read from the data: B v1 is not blocked two days before 2028-11-15, and is from the day before (RETIRE-SCOPE-1)' {
        # RETIRE-SCOPE-1 moved the line one day earlier than OLD-FAM-4 drew it:
        # a rollback started the evening before must not reach the old size
        # after midnight, so from one day before the date the machine is
        # outside the scope of this tool.
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{ vmId = '/s/rg/vm/b'; name = 'b'; sku = 'Standard_B2s'; location = 'centralus'; resourceGroup = 'rg'
                os = 'Linux'; gen = 'V2'; tags = @{}; nicIds = @(); dataDiskCount = 0; osDiskManaged = $true; securityType = '' }
            $rest = @{ NicAcceleratedMap = @{}; ManagedPlatformGroups = @{}; SapSystemVms = @{}; AvdSessionHosts = @{} }
            @((Get-VmfAssessmentRecord -Vm $vm -SkuEntry $null @rest -Now ([datetime]::new(2028, 11, 13, 12, 0, 0, [DateTimeKind]::Utc))).blockers) | Should -Not -Contain 'size-retired'
            @((Get-VmfAssessmentRecord -Vm $vm -SkuEntry $null @rest -Now ([datetime]::new(2028, 11, 14, 0, 0, 0, [DateTimeKind]::Utc))).blockers) | Should -Contain 'size-retired'
        }
    }

    It 'the options say the size is retired - not that the region lacks it' {
        $vm = OfMachine 'Standard_A2_v2' 'V1' $script:catalog
        $vm.sourceSize = 'Standard_A2'; $vm.blockers = @('gen1-requires-redeploy', 'size-retired'); $vm.classification = 'Blocked'
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $m = $advice.machines[0]
        foreach ($o in @($m.options)) {
            @($o.notSupported) | Should -Contain 'size-retired' -Because $o.option
            @($o.notSupported) | Should -Not -Contain 'family-not-in-region'
        }
        @($m.options.option) | Should -Be @('v5', 'v6', 'v7')
        $m.sourceStage.stage | Should -Be 'Retired'
        InModuleScope VmMigrationFactory { (Get-VmfSizeLifecycleStage -SizeName 'Basic_A1').Stage } | Should -Be 'Retired' -Because 'the Basic tier is A v1 too'
    }

    It 'the reason has words, a route from Microsoft and a link, for every series' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $r = $reasons.blockers.'size-retired'
        $r | Should -Not -BeNullOrEmpty
        [string]$r.meaning | Should -Match '(?i)retire'
        [string]$r.docs.url | Should -Match '^https://learn\.microsoft\.com/'
        @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }
}

Describe 'OLD-FAM-4: a B v1 machine is told its target has no CPU credits' {
    It 'B sizes are burstable, from the data; D, E and F are not' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_B1s', 'Standard_B20ms', 'Standard_B1ls', 'Standard_B2ts_v2', 'Standard_B4as_v2') { Test-VmfBurstableSize -SizeName $s | Should -BeTrue -Because $s }
            foreach ($s in 'Standard_D2lds_v5', 'Standard_E2ds_v6', 'Standard_F2s_v2', 'Standard_A2_v2', 'Basic_A1', '') { Test-VmfBurstableSize -SizeName $s | Should -BeFalse -Because $s }
        }
    }

    It 'every option of a B2s says its CPU credits end; a D4_v2 says nothing changes' {
        $b = OfMachine 'Standard_B2s' 'V2' $script:catalog
        $d = OfMachine 'Standard_D4_v2' 'V1' $script:catalog
        $advice = InModuleScope VmMigrationFactory -Parameters @{ b = $b; d = $d; c = $script:catalog } {
            param($b, $d, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($b, $d) }) -CatalogByLocation @{ centralus = $c }
        }
        foreach ($o in @($advice.machines[0].options)) {
            $o.supported | Should -BeTrue -Because $o.option
            $o.burstableEnds | Should -BeTrue -Because $o.option
        }
        $v5 = @($advice.machines[1].options | Where-Object { $_.option -eq 'v5' })[0]
        $v5.burstableEnds | Should -BeFalse
        # No target, no fact - unknown is never a yes or a no.
        $v6 = @($advice.machines[1].options | Where-Object { $_.option -eq 'v6' })[0]
        $v6.targetSize | Should -BeNullOrEmpty
        $v6.burstableEnds | Should -BeNullOrEmpty
    }

    It 'a burstable target keeps the credits: no change is said (for the day Bsv2 is a target family)' {
        # No approved target is burstable today, so the second half of the rule
        # is read through a copy of the data that calls D burstable.
        $b = OfMachine 'Standard_B2s' 'V2' $script:catalog
        $o = InModuleScope VmMigrationFactory -Parameters @{ b = $b; c = $script:catalog } {
            param($b, $c)
            $fam = (Get-VmfTargetFamilyData | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $fam.burstableFamilies = @('B', 'D')
            Get-VmfAdviceOption -Vm $b -Series 'v5' -RegionCatalog $c -Families $fam
        }
        $o.targetSize | Should -Match '^Standard_D'
        $o.burstableEnds | Should -BeFalse
    }

    It 'the advice still matches its schema' {
        $b = OfMachine 'Standard_B2s' 'V2' $script:catalog
        $advice = InModuleScope VmMigrationFactory -Parameters @{ b = $b; c = $script:catalog } {
            param($b, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($b) }) -CatalogByLocation @{ centralus = $c }
        }
        $advice | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
}
