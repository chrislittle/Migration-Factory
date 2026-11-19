#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DISKS-32-1: a machine with more than 32 data disks is outside the scope of
# this tool.
#
# Decided 2026-10-05: at most 32 data disks. A machine with more is
# "outside the scope of this tool", in those words, and the manual says so.
# E104is_v5/E104ids_v5 are not offered.
#
# Before this, a machine with 64 data disks (D14_v2, DS5_v2 and F16 take 64)
# was told on v5 that no size of its shape takes them, and on v6 and v7 it was
# planned onto a size that takes 64. Now it is a scope answer on every series,
# made the way GPU-SCOPE-1 made one for a family: a blocker the scan records,
# words that say scope, no Generation 1 route, the same answer from the target
# rules themselves (so an assessment made before this change is covered), a
# PRECHECK stop for a plan made before it, and no quota or reservation for it
# while its move has not started.

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

    # The real catalog of the test region (read from Azure, centralus): it
    # holds the v6 and v7 sizes that take 64 data disks, and the four E104i v5
    # sizes that are ruled out.
    function Global:DkLoad([string]$FixtureName) {
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $FixtureName) -Raw | ConvertFrom-Json
        $c = @{}
        foreach ($s in @($fixture.sizes)) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[[string]$s.name] = [pscustomobject]@{ Name = [string]$s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        }
        $c
    }
    $script:intel = DkLoad 'intel-v4-catalog-centralus.json'
    $script:old = DkLoad 'old-size-catalog-centralus.json'

    # One assessed machine, as the target advice reads it. $Blockers empty is
    # an assessment made BEFORE this change - the case the target rules must
    # catch on their own.
    function Global:DkVm([string]$Size, [string]$Gen, [int]$Disks, [string[]]$Blockers = @()) {
        [pscustomobject]@{ vmId = "/s/rg/vm/$Size-$Gen-$Disks"; name = "m-$Gen-$Disks"; location = 'centralus'; gen = $Gen; os = 'Linux'; osVersion = '22.04-LTS'
            classification = $(if (@($Blockers).Count) { 'Blocked' } else { 'ReadyAfterPrep' }); blockers = @($Blockers); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = $Disks
            nicCount = 1; acceleratedNicCount = 0; platformManaged = $false }
    }
    function Global:DkAdvice($Vm, $Catalog) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = $Catalog } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
    }
    function Global:DkScan([int]$Disks, [string]$Gen = 'V2', [string]$Size = 'Standard_D14_v2') {
        $vm = [pscustomobject]@{ vmId = '/s/rg/vm/d1'; name = 'd1'; sku = $Size; location = 'centralus'; resourceGroup = 'rg'
            os = 'Linux'; gen = $Gen; tags = @{}; nicIds = @(); dataDiskCount = $Disks; osDiskManaged = $true; securityType = '' }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -NicAcceleratedMap @{} -ManagedPlatformGroups @{} -SapSystemVms @{} -AvdSessionHosts @{} }
    }
    function Global:DkDropDir([string]$Dir) { if ($Dir -and (Test-Path $Dir)) { [System.IO.Directory]::Delete($Dir, $true) } }
}
AfterAll {
    Remove-Item function:DkLoad, function:DkVm, function:DkAdvice, function:DkScan, function:DkDropDir, function:DkPlanned, function:DkId,
        function:DkAssessed, function:DkSku, function:DkEntry, function:DkPlan, function:DkState, function:DkLeftOut,
        function:DkLiveVm, function:DkPlanEntry -ErrorAction SilentlyContinue
}

Describe 'DISKS-32-1: the limit is one number' {
    It 'is 32: 33 is more, 32 is not, and no count is not more' {
        InModuleScope VmMigrationFactory {
            Get-VmfMaxDataDiskCount | Should -Be 32
            Test-VmfTooManyDataDisks -Count 33 | Should -BeTrue
            Test-VmfTooManyDataDisks -Count 64 | Should -BeTrue
            Test-VmfTooManyDataDisks -Count 32 | Should -BeFalse
            Test-VmfTooManyDataDisks -Count 0 | Should -BeFalse
            Test-VmfTooManyDataDisks -Count $null | Should -BeFalse -Because 'an assessment with no count gates nothing, as before'
        }
    }

    It 'the words name the count and say scope' {
        InModuleScope VmMigrationFactory {
            $w = Get-VmfDataDiskScopeDetail -Count 64
            $w | Should -Match '64 data disks'
            $w | Should -Match 'more than 32 data disks is outside the scope of this tool'
            Get-VmfDataDiskScopeDetail -Count 32 | Should -BeNullOrEmpty
        }
    }
}

Describe 'DISKS-32-1: the scan names it' {
    It 'a machine with 33 data disks gets the blocker, Generation 1 and Generation 2' {
        foreach ($g in 'V1', 'V2') {
            $r = DkScan 33 $g
            @($r.blockers) | Should -Contain 'too-many-data-disks' -Because $g
            $r.classification | Should -Be 'Blocked' -Because $g
            $r.dataDiskCount | Should -Be 33
        }
    }

    It 'a machine with 32 data disks does not' {
        $r = DkScan 32
        @($r.blockers) | Should -Not -Contain 'too-many-data-disks'
        # The test machine has no image, so it is blocked for that; 32 data
        # disks add nothing to what a machine with none gets.
        @($r.blockers) -join ',' | Should -Be (@((DkScan 0).blockers) -join ',')
    }

    It 'the count is the data disks only - the scan reads the data disk list, never the operating system disk' {
        # Discovery: dataDiskCount = array_length(properties.storageProfile.dataDisks).
        # The operating system disk is storageProfile.osDisk, a separate field.
        $q = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1') -Raw
        $q | Should -Match 'dataDiskCount\s*=\s*array_length\(properties\.storageProfile\.dataDisks\)'
    }
}

Describe 'DISKS-32-1: the words say scope' {
    It 'the reason exists, applies to every series, and links Microsoft' {
        $r = $script:reasons.blockers.'too-many-data-disks'
        $r | Should -Not -BeNullOrEmpty
        @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
        $r.docs.url | Should -Match '^https://learn\.microsoft\.com/'
    }

    It 'THE RULE: "outside the scope of this tool", and no invented technical limit' {
        $r = $script:reasons.blockers.'too-many-data-disks'
        $r.title | Should -Match 'not in scope'
        $r.meaning | Should -Match 'more than 32 data disks'
        $r.meaning | Should -Match 'outside the scope of this tool'
        foreach ($field in 'meaning', 'whatToDo') {
            $r.$field | Should -Not -Match 'cannot|impossible|no size|does not exist|not supported by Azure' -Because $field
        }
    }

    It 'the target options file may carry it' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json
        @($schema.'$defs'.reason.enum) | Should -Contain 'too-many-data-disks'
    }

    It 'it is one of the scope blockers the target options and the wave editor read' {
        InModuleScope VmMigrationFactory { Get-VmfOutOfScopeBlockerCodes | Should -Contain 'too-many-data-disks' }
    }
}

Describe 'DISKS-32-1: no target on any series' {
    It 'a machine with the blocker: nothing supported on v5, v6 or v7, no size choices' {
        foreach ($case in @(@{ S = 'Standard_D14_v2'; G = 'V1'; C = $script:old }, @{ S = 'Standard_D14_v2'; G = 'V2'; C = $script:old },
                @{ S = 'Standard_E8-4ds_v4'; G = 'V2'; C = $script:intel })) {
            $advice = DkAdvice (DkVm $case.S $case.G 64 @('too-many-data-disks')) $case.C
            $m = $advice.machines[0]
            foreach ($series in 'v5', 'v6', 'v7') {
                $o = @($m.options | Where-Object { $_.option -eq $series })[0]
                $o.supported | Should -BeFalse -Because "$($case.S) $($case.G) $series"
                @($o.notSupported) | Should -Contain 'too-many-data-disks' -Because "$($case.S) $($case.G) $series"
                $o.targetSize | Should -BeNullOrEmpty -Because "$($case.S) $($case.G) $series - no arrow to a size it is not going to"
                @($o.sizeChoices).Count | Should -Be 0 -Because "$($case.S) $($case.G) $series - no size choice"
            }
            @($m.options.option) | Should -Be @('v5', 'v6', 'v7') -Because "$($case.S) $($case.G)"
            $m.start.current | Should -BeNullOrEmpty
            $m.start.extended | Should -BeNullOrEmpty
        }
    }

    It 'THE CASE: an assessment made before this change (no blocker) - the target rules refuse it all the same' {
        # Before this change a Generation 2 D14_v2 machine with 64 data disks
        # was given D32ds_v6, which takes 64. The count is asked on every call.
        foreach ($g in 'V1', 'V2') {
            $advice = DkAdvice (DkVm 'Standard_D14_v2' $g 33) $script:old
            $m = $advice.machines[0]
            foreach ($series in 'v5', 'v6', 'v7') {
                $o = @($m.options | Where-Object { $_.option -eq $series })[0]
                $o.supported | Should -BeFalse -Because "$g $series"
                @($o.notSupported) | Should -Contain 'too-many-data-disks' -Because "$g $series - scope, not capacity"
                $o.targetSize | Should -BeNullOrEmpty -Because "$g $series"
                @($o.sizeChoices).Count | Should -Be 0 -Because "$g $series"
            }
            @($m.options.option) | Should -Be @('v5', 'v6', 'v7') -Because $g
        }
    }

    It 'the same machine with 32 data disks gets its targets' {
        $advice = DkAdvice (DkVm 'Standard_D14_v2' 'V2' 32) $script:old
        $m = $advice.machines[0]
        foreach ($series in 'v5', 'v6', 'v7') {
            $o = @($m.options | Where-Object { $_.option -eq $series })[0]
            @($o.notSupported) | Should -Not -Contain 'too-many-data-disks' -Because $series
            $o.supported | Should -BeTrue -Because "$series - $(@($o.notSupported) -join ', ')"
            $o.targetSize | Should -Not -BeNullOrEmpty -Because $series
        }
        $g1 = DkAdvice (DkVm 'Standard_D14_v2' 'V1' 32) $script:old
        @($g1.machines[0].options.option) | Should -Be @('v5', 'v6', 'v7') -Because 'a Generation 1 machine has the three series (GEN1-ROUTE-GONE-1)'
        (@($g1.machines[0].options) | Where-Object option -eq 'v5').supported | Should -BeTrue -Because 'v5 takes Generation 1'
    }

    It 'the plan and the wave editor: a size chosen before is refused, with the scope reason' {
        $vm = DkVm 'Standard_D14_v2' 'V2' 40
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:old } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D32ds_v6'
        }
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'too-many-data-disks'
        $t.Mapping.Reason | Should -Match '40 data disks'
        $t.Mapping.Reason | Should -Match 'outside the scope of this tool'
        @($t.Blockers) | Should -Contain 'too-many-data-disks'
        $t.Classification | Should -Be 'Blocked'
        $t.Path | Should -Be 'MANUAL'
        @($t.SizeChoices).Count | Should -Be 0
    }

    It 'REVIEW: a GPU machine with more than 32 data disks gets the family sentence, as PRECHECK and the wave editor give it' {
        $vm = DkVm 'Standard_NC8as_T4_v3' 'V2' 40
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:intel } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        $t.Mapping.Code | Should -Be 'gpu-size'
        $t.Mapping.Reason | Should -Match 'Standard_NC8as_T4_v3 is outside the scope of this tool'
        $t.Mapping.Reason | Should -Not -Match 'data disks'
        @($t.Blockers) | Should -Not -Contain 'too-many-data-disks' -Because 'one reason, the one the other two places give'
    }

    It 'an excluded machine keeps its own answer' {
        $vm = DkVm 'Standard_D14_v2' 'V2' 40
        $vm.classification = 'Excluded'; $vm.platformManaged = $true
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:old } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        @($t.Blockers) | Should -Not -Contain 'too-many-data-disks'
    }
}

Describe 'DISKS-32-1: the E104i v5 sizes are never offered' {
    It 'REVIEW: a machine already ON an E104i v5 size is told it is already on v5 - E104 is refused as a target, never as a source' {
        # The first version refused E104 whatever the machine's own size, so a
        # machine on E104is_v5 lost "already on this series" for "not a size
        # Microsoft lists as a target" - untrue both ways.
        foreach ($s in 'Standard_E104is_v5', 'Standard_E104ids_v5') {
            $advice = DkAdvice (DkVm $s 'V2' 8) $script:intel
            $v5 = @($advice.machines[0].options | Where-Object { $_.option -eq 'v5' })[0]
            @($v5.notSupported) | Should -Be @('already-on-series') -Because $s
            InModuleScope VmMigrationFactory -Parameters @{ s = $s } {
                param($s)
                (Test-VmfSizeApprovedTarget -SizeName $s -TargetGeneration 'v5' -SourceSize $s).Approved | Should -BeTrue -Because "$s is the machine's own size"
                (Test-VmfSizeApprovedTarget -SizeName $s -TargetGeneration 'v5' -SourceSize 'Standard_E64s_v4').Approved | Should -BeFalse -Because "$s is a move onto it"
            }
        }
    }

    It 'every E104i v5 size is refused as a target, in scope words; E104 is the only E v5 size refused' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_E104is_v5', 'Standard_E104ids_v5', 'Standard_E104i_v5', 'Standard_E104id_v5') {
                $a = Test-VmfSizeApprovedTarget -SizeName $s -TargetGeneration 'v5'
                $a.Approved | Should -BeFalse -Because $s
                $a.Why | Should -Match 'outside the scope of this tool' -Because $s
            }
            foreach ($s in 'Standard_E96ds_v5', 'Standard_E64s_v5', 'Standard_E8-4ds_v5', 'Standard_D96ds_v5') {
                (Test-VmfSizeApprovedTarget -SizeName $s -TargetGeneration 'v5').Approved | Should -BeTrue -Because $s
            }
        }
    }

    It 'the suggestion of a bigger size never names E104 - a machine on an isolated E v3 size, which would match its letters' {
        # Get-VmfSmallestSizeForDisks keeps the letters of the machine's size:
        # for E64is_v3 that is "is", and the only Eis v5 size is E104is_v5.
        $c = $script:intel.Clone()
        foreach ($n in 'Standard_E64is_v3', 'Standard_E64is_v5') {
            $c[$n] = [pscustomobject]@{ Name = $n; ResourceType = 'virtualMachines'; Restrictions = @()
                Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '64' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '432' },
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '16' }, [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '8' },
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }) }
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            param($c)
            Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E64is_v3' -RequiredDataDisks 20 -CatalogBySize $c -TargetGeneration 'v5' | Should -BeNullOrEmpty
            # The whole answer: the twin takes 16, and the advice names no E104.
            $r = Get-VmfTargetSize -SourceSize 'Standard_E64is_v3' -Size 'Standard_E64is_v5' -CatalogBySize $c -RequiredDataDisks 20 -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'too-few-data-disks'
            $r.Reason | Should -Not -Match 'E104'
        }
        # The network interface twin keeps the letters the same way. With the
        # E64is_v5 here holding 4, the only Eis v5 size that holds 8 is E104is_v5.
        $c['Standard_E64is_v5'].Capabilities = @($c['Standard_E64is_v5'].Capabilities | Where-Object Name -NE 'MaxNetworkInterfaces') +
            @([pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' })
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            param($c)
            Get-VmfSmallestSizeForNics -SourceSize 'Standard_E64is_v3' -RequiredNics 8 -CatalogBySize $c -TargetGeneration 'v5' | Should -BeNullOrEmpty
        }
    }

    It 'the suggestion is never made for more than 32 data disks - such a machine is outside the scope' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:intel } {
            param($c)
            Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 33 -CatalogBySize $c | Should -BeNullOrEmpty
            (Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 30 -CatalogBySize $c).Name | Should -Be 'Standard_E16ds_v6'
        }
    }

    It 'a named E104is_v5 size is refused, with the reason' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:intel } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_E64s_v4' -Size 'Standard_E104is_v5' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.Reason | Should -Match 'E104is_v5 is outside the scope of this tool'
            # Microsoft DOES list E104is_v5: the sentence must not say otherwise.
            $r.Reason | Should -Not -Match 'Microsoft lists'
            $r.Reason | Should -Match '^no target size for this machine is one the product offers on v5'
        }
    }

    It 'FROM REAL SIZES: no machine of 1 to 32 data disks, on any old or v4 size, is offered E104 as a target or a size choice' {
        $checked = 0
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($cat in @($script:old, $script:intel)) {
            $sources = @($cat.Keys | Where-Object { $_ -match '^Standard_(A\d+m?_v2|B\d+(ls|s|ms)|F\d+s?(_v2)?|DS?\d+(-\d+)?(_v2)?|[DE]\d+(-\d+)?[a-z]*_v4)$' } | Sort-Object)
            $sources.Count | Should -BeGreaterThan 10
            foreach ($src in $sources) {
                foreach ($gen in 'V1', 'V2') {
                    foreach ($disks in 16, 32) {
                        $vm = DkVm $src $gen $disks
                        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
                            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5'
                        }
                        $checked++
                        foreach ($size in @([string]$t.Mapping.Target) + @($t.SizeChoices | ForEach-Object { [string]$_.size })) {
                            if ($size -match '^Standard_E104i') { $found.Add("$src $gen $disks -> $size") }
                        }
                    }
                }
            }
        }
        $checked | Should -BeGreaterThan 100
        $found -join '; ' | Should -BeNullOrEmpty
    }
}

# A planned migration in a store, as the product writes it: the assessment,
# its approval, the target options, the saved targets and the plan.
function Global:DkPlanned([object[]]$Vms, [object[]]$Choices, [switch]$NoChoices) {
    $run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $run -Leaf); generatedUtc = '2026-10-10T00:00:00Z'
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
    if (-not $NoChoices) {
        Set-VmfTestTargetChoice -RunPath $run -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($Choices) -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
    }
    New-VmfPlan -AssessmentPath (Join-Path $run 'assessment.json') -OutPath "$run-migration" | Out-Null
    @{ Scan = $run; Mig = "$run-migration" }
}
function Global:DkId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
function Global:DkAssessed([string]$Name, [string]$Size, [int]$Disks, [string[]]$Blockers = @()) {
    [ordered]@{ vmId = (DkId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
        classification = $(if (@($Blockers).Count) { 'Blocked' } else { 'ReadyAfterPrep' }); gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts'
        sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = $Disks; nicCount = 1
        acceleratedNicCount = 1; primaryNicAccelerated = $true; platformManaged = $false; iacManaged = $false; hibernationEnabled = $false
        availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }; blockers = @($Blockers); prepNeeded = @() }
}
function Global:DkSku([string]$Name, [string]$Gens = 'V2', [string]$Disks = '64') {
    [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
        Capabilities = @(
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = $Disks }
            [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
}

Describe 'DISKS-32-1: the wave editor, on a plan made before this change' {
    BeforeEach {
        $script:dkCatalog = @((DkSku 'Standard_D2s_v4' 'V1,V2'), (DkSku 'Standard_D2s_v5' 'V1,V2'), (DkSku 'Standard_D2s_v6'), (DkSku 'Standard_D2s_v7'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:dkCatalog }
        $script:dkId = DkId 'big-01'
        $script:dkRun = DkPlanned -Vms @(DkAssessed 'big-01' 'Standard_D2s_v4' 4) -Choices @(@{ vmId = $script:dkId; option = 'v6' })

        # The plan a 40-disk machine got before this change. Only the count
        # is changed here.
        $planFile = Join-Path $script:dkRun.Mig 'plan.json'
        $plan = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 40
        @($plan.entries)[0].target.size | Should -Be 'Standard_D2s_v6' -Because 'the test needs a planned machine to start from'
        @($plan.entries)[0].assessment.dataDiskCount = 40
        [System.IO.File]::WriteAllText($planFile, ($plan | ConvertTo-Json -Depth 40))
    }
    AfterEach { DkDropDir $script:dkRun.Scan; DkDropDir $script:dkRun.Mig }

    It 'the preview gives the scope reason on every series, the current one too' {
        $r = Set-VmfMachineTarget -RunPath $script:dkRun.Mig -VmId $script:dkId -WhatIf
        $r.Current | Should -Be 'v6'
        foreach ($s in 'v5', 'v6', 'v7') {
            $o = @($r.Options) | Where-Object option -EQ $s
            $o.supported | Should -BeFalse -Because "$s - the machine is outside the scope of this tool"
            @($o.why) | Should -Contain 'too-many-data-disks' -Because $s
        }
    }

    It 'a change is refused in words that say scope, and the plan is not written' {
        $before = Get-Content (Join-Path $script:dkRun.Mig 'plan.json') -Raw
        { Set-VmfMachineTarget -RunPath $script:dkRun.Mig -VmId $script:dkId -Option 'v5' -ChangedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '*40 data disks*outside the scope of this tool*'
        Get-Content (Join-Path $script:dkRun.Mig 'plan.json') -Raw | Should -BeExactly $before
    }
}

Describe 'DISKS-32-1: a new plan does not move the machine, and asks no quota for it (<How>)' -ForEach @(
    @{ How = 'targets saved'; NoChoices = $false }
    @{ How = 'no saved targets, every machine planned on the default series'; NoChoices = $true }
) {
    BeforeEach {
        $script:dkCatalog = @((DkSku 'Standard_D2s_v4' 'V1,V2'), (DkSku 'Standard_D2s_v5' 'V1,V2'), (DkSku 'Standard_D2s_v6'), (DkSku 'Standard_D2s_v7'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:dkCatalog }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardX' }; CurrentValue = 0; Limit = 100 }) }
        $script:dkRun = DkPlanned -Vms @(
            (DkAssessed 'app-01' 'Standard_D2s_v4' 32),
            (DkAssessed 'big-new' 'Standard_D2s_v4' 33 @('too-many-data-disks')),
            (DkAssessed 'big-old' 'Standard_D2s_v4' 64)) `
            -Choices @(@{ vmId = (DkId 'app-01'); option = 'v6' }) -NoChoices:$NoChoices
    }
    AfterEach { DkDropDir $script:dkRun.Scan; DkDropDir $script:dkRun.Mig }

    It 'neither machine with more than 32 is planned to move; the one with 32 is' {
        $plan = Get-Content (Join-Path $script:dkRun.Mig 'plan.json') -Raw | ConvertFrom-Json -Depth 40
        foreach ($n in 'big-new', 'big-old') {
            $e = @($plan.entries) | Where-Object vmId -EQ (DkId $n)
            if ($NoChoices) {
                $e | Should -Not -BeNullOrEmpty -Because "$n - with no saved targets every machine is in the plan"
                $e.path | Should -Be 'MANUAL' -Because $n
                $e.target.size | Should -BeNullOrEmpty -Because $n
                [string]$e.wave | Should -BeIn @('', 'unscheduled') -Because "$n is in no wave"
            }
            else { $e | Should -BeNullOrEmpty -Because "$n has no target to save, so it is not chosen" }
        }
        (@($plan.entries) | Where-Object vmId -EQ (DkId 'app-01')).target.size | Should -Be 'Standard_D2s_v6'
    }

    It 'the quota check writes a record for the machine that moves only' {
        $r = Test-VmfQuota -PlanPath (Join-Path $script:dkRun.Mig 'plan.json') -OutPath $script:dkRun.Mig
        @($r.Claims).Count | Should -Be 1
        @($r.Claims)[0].size | Should -Be 'Standard_D2s_v6'
        @($r.Claims)[0].demand.instances | Should -Be 1
    }
}

Describe 'DISKS-32-1: capacity for a planned machine with more than 32 data disks' {
    BeforeAll {
        function Global:DkEntry([string]$Name, [int]$Disks, [string]$Size, [string]$Gate = 'BestEffort') {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (DkId $Name); wave = 'w1'; path = 'A'
                assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = 'Standard_D2s_v4'; availabilitySetId = ''; dataDiskCount = $Disks }
                target = [pscustomobject]@{ size = $Size; zone = $null }
                policy = [pscustomobject]@{ capacityGate = $Gate; requireApproval = $false } }
        }
        function Global:DkPlan([string]$RunPath, [object[]]$Entries) {
            $file = Join-Path $RunPath 'plan.json'
            @{ schemaVersion = 1; assessmentRunId = 'dk'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding utf8NoBOM
            $file
        }
        function Global:DkState([string]$RunPath, $Entry, [string]$State, [switch]$Started) {
            $doc = [ordered]@{ schemaVersion = 3; vmId = $Entry.vmId; state = $State }
            if ($Started) { $doc.captured = [ordered]@{ startedTarget = [ordered]@{ path = 'A'; target = [ordered]@{ size = $Entry.target.size } } } }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $Entry.vmId; d = $doc } {
                param($rp, $id, $d)
                Write-VmfStoreJson -RunPath $rp -RelPath ('state/' + (Get-VmfVmKey -VmId $id) + '.json') -Document $d -Depth 8
            }
        }
        function Global:DkLeftOut([string]$RunPath, [object[]]$Entries) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; e = $Entries } { param($rp, $e) @(Get-VmfLeftOutVmIds -RunPath $rp -Entries $e) }
        }
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dkc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'dk' | Out-Null }
        $script:big = DkEntry 'big-1' 33 'Standard_D32s_v6'
        $script:app = DkEntry 'app-1' 32 'Standard_D2s_v6'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DkSku 'Standard_D2s_v6'), (DkSku 'Standard_D32s_v6')) }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardX' }; CurrentValue = 0; Limit = 100 }) }
    }
    AfterEach { DkDropDir $script:rp }

    It 'the one test says so: 33 is out of scope, 32 is in' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:big; d = $script:app } {
            param($o, $d)
            Test-VmfEntryOutOfScope -Entry $o | Should -BeTrue
            Test-VmfEntryOutOfScope -Entry $d | Should -BeFalse
        }
    }

    It 'left out while its move has not started, and NEVER once it has' {
        @(DkLeftOut $script:rp @($script:big, $script:app)) | Should -Be @($script:big.vmId)
        DkState $script:rp $script:big 'CONVERTING' -Started
        @(DkLeftOut $script:rp @($script:big, $script:app)) | Should -BeNullOrEmpty -Because 'it finishes the move it started, and uses capacity'
    }

    It 'the quota check writes no record for it' {
        $r = Test-VmfQuota -PlanPath (DkPlan $script:rp @($script:big, $script:app)) -OutPath $script:rp
        @($r.Claims.size) | Should -Be @('Standard_D2s_v6')
    }

    It 'the Reserved gate asks no record for it' {
        $left = DkLeftOut $script:rp @($script:big, $script:app)
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:big; d = $script:app; left = $left } {
            param($o, $d, $left)
            @((Get-VmfReservedCoverageGaps -Claims @() -Entries @($o, $d) -FinishedVmIds $left).VmId) | Should -Be @($d.vmId)
        }
    }

    It 'a wave of ONLY such machines passes the capacity gate, BestEffort and Reserved' {
        DkPlan $script:rp @($script:big) | Out-Null
        foreach ($gate in 'BestEffort', 'Reserved') {
            $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate $gate
            $r.Pass | Should -BeTrue -Because "$gate - $($r.Detail)"
            $r.Detail | Should -Match 'outside the scope of this tool'
        }
    }

    It 'a reservation of a wave of only such machines says the true reason' {
        DkPlan $script:rp @(DkEntry 'big-1' 33 'Standard_D32s_v6' 'Reserved') | Out-Null
        { New-VmfWaveReservation -OutPath $script:rp -Wave 'w1' } | Should -Throw '*outside the scope of this tool*needs no on-demand capacity reservation*'
    }
}

Describe 'DISKS-32-1: PRECHECK stops a machine of an older plan untouched' {
    BeforeAll {
        $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
        function Global:DkLiveVm([int]$Disks) {
            $data = @(for ($i = 0; $i -lt $Disks; $i++) {
                    [pscustomobject]@{ Lun = $i; Name = "vm1-data$i"; Caching = 'None'; CreateOption = 'Attach'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-data$i" } } })
            [pscustomobject]@{
                Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D8s_v4' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os" } }
                    DataDisks = $data; ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        function Global:DkPlanEntry([int]$Disks) {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D8s_v4'; sourceDiskArch = 'diskless'
                    platformManaged = $false; location = 'centralus'; dataDiskCount = $Disks }
                target = [pscustomobject]@{ size = 'Standard_D8s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v6' } }
        }
        # Every function in the Azure boundary that changes something.
        $script:writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
            ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
            Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -in @('Invoke-VmfRunCommand', 'Clear-VmfDiskPerfProperties') })
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dkp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'dkp' | Out-Null }
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
        DkDropDir $script:rp
    }

    It 'the boundary has write functions to watch' {
        $script:writes | Should -Contain 'Stop-VmfVmDeallocated'
        $script:writes | Should -Contain 'Set-VmfVmSizeAndController'
    }

    It 'the plan says 33 data disks: refused before the machine is even read' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { throw 'the machine must not be read' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (DkPlanEntry 33) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'dkp'
            New-VmfStateDoc -RunPath $rp -RunId 'dkp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'tooManyDataDisks'
            $r.Detail | Should -Match '33 data disks'
            $r.Detail | Should -Match 'outside the scope of this tool'
            $r.Detail | Should -Match 'Nothing on the machine changed'
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 0 -Exactly
    }

    It 'the machine got more data disks after its plan was made: refused when it is read' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { DkLiveVm 34 }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (DkPlanEntry 4) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'dkp'
            New-VmfStateDoc -RunPath $rp -RunId 'dkp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'tooManyDataDisks'
            $r.Detail | Should -Match '34 data disks'
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 1 -Because 'the disks the machine has now are read, then refused'
    }

    It 'a machine with 32 data disks, in the plan and now, is not stopped for it' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { DkLiveVm 32 }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (DkPlanEntry 32) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'dkp'
            New-VmfStateDoc -RunPath $rp -RunId 'dkp' -VmId $ctx.VmId | Out-Null
            try { Invoke-VmfStepPrecheck -Context $ctx } catch { @{ Next = 'threw'; Reason = $_.Exception.Message } }
        }
        $r.Reason | Should -Not -Be 'tooManyDataDisks'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 1 -Because 'it went past both checks'
    }

    It 'the stop has guidance: untouched, out of scope, in scope words' {
        $all = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons)
        $reason = $all | Where-Object code -EQ 'tooManyDataDisks'
        $reason | Should -Not -BeNullOrEmpty
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'outOfScope'
        $reason.meaning | Should -Match 'more than 32 data disks'
        $reason.meaning | Should -Match 'outside the scope of this tool'
        $reason.meaning | Should -Not -Match 'cannot|impossible'
    }
}
