#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SIZE-FALLTHROUGH-NOTE-1: the plan and the targets step say why the d size
# was not taken.
#
# The default transform tries the d size first for a machine with a temporary
# disk, then the size without one (Get-VmfDefaultSizeCandidates). When the d
# size fails a gate, Get-VmfTargetSize takes the next size - and the plan said
# nothing: the reason was default-transform, as for a machine that got its
# first size, and planNotes was empty. On Windows the size without a temporary
# disk changes the kind of temporary disk, so the move is the in-place upgrade
# (Preview) where the d size kept it a plain resize.
#
# Now Get-VmfTargetSize records each size it did not take and the gate
# (NotTaken), Get-VmfPlanEntryNotes puts it in words in planNotes
# (Get-VmfSizeNotTakenNote), and each option of the target advice carries it
# (sizesNotTaken, target-advice v29) for the targets step. These tests hold
# each gate to its own code and words, and a machine that got its first size
# to no note. The catalogs are made for each gate, as in SizeFallThrough.Tests.ps1.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:FnSku {
        param([string]$Name, [int]$Vcpus = 4, [double]$Gb = 16, [object]$TempMb = 0, [string]$Gens = 'V2',
              [int]$Nics = 4, [int]$Disks = 16, [int]$NvmeDisks = 0, [switch]$NoShape)
        $caps = @(
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = [string]$Nics }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = [string]$Disks }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$TempMb })
        if (-not $NoShape) {
            $caps += [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            $caps += [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$Gb }
        }
        if ($NvmeDisks -gt 0) {
            $caps += [pscustomobject]@{ Name = 'NvmeDiskSizeInMiB'; Value = [string](225280 * $NvmeDisks) }
            $caps += [pscustomobject]@{ Name = 'NvmeSizePerDiskInMiB'; Value = '225280' }
        }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }

    # The machine: Standard_D4s_v3 (4 vCPUs, 16 GiB, a temporary disk).
    function Global:FnCatalog {
        param($D6, $D5, [switch]$NoD6)
        $c = @{}
        $c['Standard_D4s_v3'] = FnSku 'Standard_D4s_v3' 4 16 16384 'V1,V2'
        $c['Standard_D2s_v3'] = FnSku 'Standard_D2s_v3' 2 8 16384 'V1,V2'
        if (-not $NoD6) { $c['Standard_D4ds_v6'] = $(if ($D6) { $D6 } else { FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -NvmeDisks 1 }) }
        $c['Standard_D4s_v6'] = FnSku 'Standard_D4s_v6' 4 16 0 'V2'
        $c['Standard_D4ds_v5'] = $(if ($D5) { $D5 } else { FnSku 'Standard_D4ds_v5' 4 16 153600 'V1,V2' })
        $c['Standard_D4s_v5'] = FnSku 'Standard_D4s_v5' 4 16 0 'V1,V2'
        $c['Standard_D8ds_v6'] = FnSku 'Standard_D8ds_v6' 8 32 0 'V2' -NvmeDisks 1
        $c['Standard_D8s_v6'] = FnSku 'Standard_D8s_v6' 8 32 0 'V2'
        $c
    }

    function Global:FnVm {
        param([string]$Size = 'Standard_D4s_v3', [string]$Os = 'Windows', [int]$Disks = 1, [int]$Nics = 1, [string]$Gen = 'V2')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-01"
            name = 'app-01'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = 'SCSI'; dataDiskCount = $Disks; nicCount = $Nics
            acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{}; blockers = @(); prepNeeded = @(); zones = @()
        }
    }
}
AfterAll { Remove-Item 'function:\FnSku', 'function:\FnCatalog', 'function:\FnVm' -ErrorAction SilentlyContinue }

Describe 'SIZE-FALLTHROUGH-NOTE-1: Get-VmfTargetSize records the size it did not take, and the gate' {

    It 'the first size is the target: nothing is recorded' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 6 -RequiredNics 3
            $r.Target | Should -Be 'Standard_D4ds_v6'
            @($r.NotTaken).Count | Should -Be 0
        }
    }

    It 'a named size has one candidate, so nothing is recorded' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -Size 'Standard_D4s_v6' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            @($r.NotTaken).Count | Should -Be 0
        }
    }

    It 'too few data disks: too-few-data-disks, with what it holds and what the machine has' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 6
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped' -Because 'the code stays the answer for the size planned'
            @($r.NotTaken).Count | Should -Be 1
            $r.NotTaken[0].size | Should -Be 'Standard_D4ds_v6'
            $r.NotTaken[0].why | Should -Be 'too-few-data-disks'
            $r.NotTaken[0].holds | Should -Be 4
            $r.NotTaken[0].needs | Should -Be 6
        }
    }

    It 'too few network interfaces: too-few-nics, with what it holds and what the machine has' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -Nics 2 -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 3
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.NotTaken[0].why | Should -Be 'too-few-nics'
            $r.NotTaken[0].holds | Should -Be 2
            $r.NotTaken[0].needs | Should -Be 3
        }
    }

    It 'not in the region catalog: not-in-region' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -NoD6) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.NotTaken[0].size | Should -Be 'Standard_D4ds_v6'
            $r.NotTaken[0].why | Should -Be 'not-in-region'
        }
    }

    It 'a size Microsoft does not list: not-listed' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -NoD6) } {
            Mock Get-VmfMicrosoftSizeListing { if ($SizeName -eq 'Standard_D4ds_v6') { @{ Listed = $false; Page = $null; ReadUtc = '2026-11-03' } } else { @{ Listed = $true; Page = 'Dsv6'; ReadUtc = '2026-11-03' } } }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.NotTaken[0].why | Should -Be 'not-listed'
        }
    }

    It 'a size the product does not offer: not-approved' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog) } {
            Mock Test-VmfSizeApprovedTarget { @{ Approved = ($SizeName -ne 'Standard_D4ds_v6'); Why = 'scope: test' } }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.NotTaken[0].why | Should -Be 'not-approved'
        }
    }

    It 'a Generation 1 machine, and the d size does not take Generation 1: gen1-no-size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -D5 (FnSku 'Standard_D4ds_v5' 4 16 153600 'V2')) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v5' -HyperVGeneration 'V1'
            $r.Target | Should -Be 'Standard_D4s_v5'
            $r.NotTaken[0].why | Should -Be 'gen1-no-size'
        }
    }

    It 'smaller than the machine: smaller-than-source, with both shapes' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 8 0 'V2' -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.NotTaken[0].why | Should -Be 'smaller-than-source'
            $r.NotTaken[0].vcpus | Should -Be 4
            $r.NotTaken[0].memoryGB | Should -Be 8
            $r.NotTaken[0].sourceVcpus | Should -Be 4
            $r.NotTaken[0].sourceMemoryGB | Should -Be 16
        }
    }

    It 'a shape the catalog does not give, on a size whose number is not its vCPUs: shape-unknown' {
        # Standard_D11_v2: the number 11 is not the vCPU count, so the shape is asked.
        $c = @{}
        $c['Standard_D11_v2'] = FnSku 'Standard_D11_v2' 2 14 102400 'V1,V2'
        $c['Standard_D11d_v5'] = FnSku 'Standard_D11d_v5' -NoShape -TempMb 153600 -Gens 'V1,V2'
        $c['Standard_D11_v5'] = FnSku 'Standard_D11_v5' 2 16 0 'V1,V2'
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            Mock Get-VmfDefaultSizeCandidates { @('Standard_D11d_v5', 'Standard_D11_v5') }
            Mock Test-VmfSizeApprovedTarget { @{ Approved = $true; Why = '' } }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D11_v2' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_D11_v5'
            $r.NotTaken[0].why | Should -Be 'shape-unknown'
        }
    }

    It 'two interfaces with accelerated networking and a 2-vCPU d size: one-accelerated-nic' {
        $c = FnCatalog
        $c['Standard_D2ds_v6'] = FnSku 'Standard_D2ds_v6' 2 8 0 'V2' -NvmeDisks 1
        $c['Standard_D2s_v6'] = FnSku 'Standard_D2s_v6' 4 16 0 'V2'
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 2
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.NotTaken[0].why | Should -Be 'one-accelerated-nic'
            $r.NotTaken[0].vcpus | Should -Be 2
            $r.NotTaken[0].needs | Should -Be 2
        }
    }
}

Describe 'SIZE-FALLTHROUGH-NOTE-1: the plan note says which size was not taken, and why' {

    It 'each gate gives its own words, with the size not taken and the target' {
        InModuleScope VmMigrationFactory {
            $cases = [ordered]@{
                'not-listed'          = @(@{ size = 'Standard_D4ds_v6'; why = 'not-listed' }, 'Microsoft does not list it')
                'not-in-region'       = @(@{ size = 'Standard_D4ds_v6'; why = 'not-in-region' }, 'this region does not offer it')
                'not-approved'        = @(@{ size = 'Standard_D4ds_v6'; why = 'not-approved' }, 'not a target size that the product offers')
                'gen1-no-size'        = @(@{ size = 'Standard_D4ds_v6'; why = 'gen1-no-size' }, 'does not take Generation 1 machines')
                'too-few-nics'        = @(@{ size = 'Standard_D4ds_v6'; why = 'too-few-nics'; holds = 2; needs = 3 }, 'holds 2 network interfaces, and this machine has 3')
                'too-few-data-disks'  = @(@{ size = 'Standard_D4ds_v6'; why = 'too-few-data-disks'; holds = 4; needs = 6 }, 'holds 4 data disks, and this machine has 6')
                'smaller-than-source' = @(@{ size = 'Standard_D4ds_v6'; why = 'smaller-than-source'; vcpus = 4; memoryGB = 8; sourceVcpus = 4; sourceMemoryGB = 16 }, 'it has 4 vCPUs and 8 GiB, and this machine has 4 vCPUs and 16 GiB')
                'shape-unknown'       = @(@{ size = 'Standard_D4ds_v6'; why = 'shape-unknown' }, 'does not give its vCPUs and memory')
                'one-accelerated-nic' = @(@{ size = 'Standard_D2ds_v6'; why = 'one-accelerated-nic'; vcpus = 2; needs = 2 }, 'it has 2 vCPUs, and Azure allows accelerated networking on one network interface only')
            }
            $seen = @{}
            foreach ($k in $cases.Keys) {
                $note = Get-VmfSizeNotTakenNote -NotTaken @($cases[$k][0]) -Target 'Standard_D4s_v6'
                $note | Should -Match ([regex]::Escape($cases[$k][1])) -Because $k
                $note | Should -Match ([regex]::Escape("The product did not use $($cases[$k][0].size) because")) -Because $k
                $note | Should -Match ([regex]::Escape('The target is Standard_D4s_v6.')) -Because $k
                $seen.ContainsKey($note) | Should -BeFalse -Because "$k must have words of its own"
                $seen[$note] = $true
            }
        }
    }

    It 'no list, an empty list, or a code it does not know gives no note' {
        InModuleScope VmMigrationFactory {
            Get-VmfSizeNotTakenNote -NotTaken $null -Target 'Standard_D4s_v6' | Should -BeNullOrEmpty
            Get-VmfSizeNotTakenNote -NotTaken @() -Target 'Standard_D4s_v6' | Should -BeNullOrEmpty
            Get-VmfSizeNotTakenNote -NotTaken @(@{ size = 'Standard_D4ds_v6'; why = 'later-code' }) -Target 'Standard_D4s_v6' | Should -BeNullOrEmpty
        }
    }

    It 'the plan entry notes carry it for a machine that fell through, first, and not for one that got its first size' {
        $fell = FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = $fell; ok = (FnCatalog); vm = (FnVm -Disks 6 -Os 'Linux') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            $n = @(Get-VmfPlanEntryNotes -Mapping $t.Mapping -Assessment $vm -Controller ([string]$t.Controller) -Path ([string]$t.Path))
            $n[0] | Should -Be 'The product did not use Standard_D4ds_v6 because it holds 4 data disks, and this machine has 6. The target is Standard_D4s_v6.'

            $t2 = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $ok -TargetGeneration 'v6'
            $n2 = @(Get-VmfPlanEntryNotes -Mapping $t2.Mapping -Assessment $vm -Controller ([string]$t2.Controller) -Path ([string]$t2.Path))
            ($n2 -join ' ') | Should -Not -Match 'did not use' -Because 'a machine that got its first size has no note'
        }
    }

    It 'a machine with no target gets its refusal, never a not-taken note' {
        InModuleScope VmMigrationFactory {
            $n = @(Get-VmfPlanEntryNotes -Mapping @{ Target = $null; Reason = 'no target'; NotTaken = @(@{ size = 'Standard_D4ds_v6'; why = 'not-in-region' }) } -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D4s_v3' }))
            $n | Should -Be @('no target')
        }
    }

    It 'New-VmfPlan writes the note into planNotes' {
        $fell = FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = $fell; vm = (FnVm -Disks 6 -Os 'Linux') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            # The same call New-VmfPlan and Set-VmfMachineTarget make (PLAN-NOTES-TARGET-1).
            $src = (Get-Command New-VmfPlan).ScriptBlock.ToString() + (Get-Command Set-VmfMachineTarget).ScriptBlock.ToString()
            ([regex]::Matches($src, 'Get-VmfPlanEntryNotes -Mapping')).Count | Should -Be 2
            @($t.Mapping.NotTaken).Count | Should -Be 1
        }
    }
}

Describe 'SIZE-FALLTHROUGH-NOTE-1: the targets step gets the sizes not taken (target-advice v29)' {

    It 'an option that fell through carries sizesNotTaken: size and code' {
        $fell = FnCatalog -D6 (FnSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = $fell; vm = (FnVm -Disks 6) } {
            $o = Get-VmfAdviceOption -Vm $vm -Series 'v6' -RegionCatalog $c
            $o.targetSize | Should -Be 'Standard_D4s_v6'
            @($o.sizesNotTaken).Count | Should -Be 1
            $o.sizesNotTaken[0].size | Should -Be 'Standard_D4ds_v6'
            $o.sizesNotTaken[0].why | Should -Be 'too-few-data-disks'
            @($o.sizesNotTaken[0].Keys) | Should -Be @('size', 'why') -Because 'the schema allows these two only'
        }
    }

    It 'an option on its first size, and an option with no target, carry an empty list' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FnCatalog); vm = (FnVm -Disks 6) } {
            $o = Get-VmfAdviceOption -Vm $vm -Series 'v6' -RegionCatalog $c
            $o.targetSize | Should -Be 'Standard_D4ds_v6'
            @($o.sizesNotTaken).Count | Should -Be 0
            $none = Get-VmfAdviceOption -Vm $vm -Series 'v6' -RegionCatalog $null
            @($none.sizesNotTaken).Count | Should -Be 0
            $none.Keys | Should -Contain 'sizesNotTaken'
        }
    }

    It 'the version is 29, the schema requires the field, and the sample passes it' {
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
        $schemaPath = Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json'
        $s = Get-Content $schemaPath -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 34
        @($s.'$defs'.option.required) | Should -Contain 'sizesNotTaken'
        @($s.'$defs'.option.properties.sizesNotTaken.items.properties.why.enum) | Should -Be @('not-listed', 'not-in-region', 'not-approved', 'gen1-no-size', 'too-few-nics', 'too-few-data-disks', 'smaller-than-source', 'shape-unknown', 'one-accelerated-nic')
        Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'target-advice.sample.json') -Raw | Test-Json -SchemaFile $schemaPath | Should -BeTrue
    }

    It 'every code Get-VmfTargetSize can record is in the schema list and has plan words' {
        # The codes are read from the function's own source, so a new gate that
        # records a code the schema does not hold fails here.
        $src = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $codes = @([regex]::Matches($src, "notTaken\.Add\(\[ordered\]@\{ size = \`$candidate; why = '([a-z0-9-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $codes.Count | Should -Be 9
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $enum = @($schema.'$defs'.option.properties.sizesNotTaken.items.properties.why.enum)
        foreach ($code in $codes) { $enum | Should -Contain $code }
    }
}

