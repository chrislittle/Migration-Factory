#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEMPPOOL-1 - the temporary disks a machine has, and the ones it will have.
#
# A review of the guest script asked why it pools the NVMe temporary disks:
# a pool is not required, and many customers do not use one. Pooling stayed - the disks arrive RAW on every start and a boot task
# rebuilds the pool, so there is nothing to manage. What was missing is the
# INFORMATION, and this is it.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:Sku {
        param([hashtable]$Caps)
        [pscustomobject]@{
            Capabilities = @($Caps.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Name = $_.Key; Value = [string]$_.Value } })
        }
    }
}
AfterAll { Remove-Item 'function:\Sku' -ErrorAction SilentlyContinue }

Describe 'TEMPPOOL-1: counting temporary disks' {
    It 'a SCSI temp size has exactly ONE, whatever its size' {
        # v3/v4/v5 present a single temporary disk at D:. Its capacity varies;
        # the COUNT does not.
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 76800 }) } {
            Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_D8ds_v4' | Should -Be 1
        }
    }

    It 'v6 NVMe counts come out of the published capabilities, measured in centralus' {
        # Straight from the SKU catalog: NvmeDiskSizeInMiB / NvmeSizePerDiskInMiB.
        $cases = @(
            @{ Size = 'Standard_D2ds_v6';  Total = 112640;  Per = 112640; Expect = 1 }
            @{ Size = 'Standard_D64ds_v6'; Total = 3604480; Per = 901120; Expect = 4 }
            @{ Size = 'Standard_E96ds_v6'; Total = 5406720; Per = 901120; Expect = 6 }
        )
        foreach ($c in $cases) {
            $s = Sku @{ MaxResourceVolumeMB = 0; NvmeDiskSizeInMiB = $c.Total; NvmeSizePerDiskInMiB = $c.Per }
            InModuleScope VmMigrationFactory -Parameters @{ s = $s; n = $c.Size; e = $c.Expect } {
                Get-VmfTempDiskCount -SkuEntry $s -SizeName $n | Should -Be $e
            }
        }
    }

    It 'a genuinely diskless size is ZERO' {
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 0 }) } {
            Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_D8s_v6' | Should -Be 0
        }
    }
}

Describe 'TEMPPOOL-1: unknown is NOT zero' {
    # Zero says "this machine has no temporary disk". For a 'd' size that is a
    # claim the data does not support, and it is the exact claim that would send
    # an operator into a migration believing nothing changes. Same rule as
    # NIC-1's MaxNetworkInterfaces and the retail price.

    It 'a size missing from the catalog cannot be counted' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskCount -SkuEntry $null -SizeName 'Standard_D8ds_v6'
            $r | Should -BeNullOrEmpty
            $r | Should -Not -Be 0
        }
    }

    It "a 'd' size whose NVMe capabilities are absent cannot be counted" {
        # The name says it has local disks; the catalog did not size them. That
        # is "cannot tell", and it must not collapse to the diskless answer.
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 0 }) } {
            $r = Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_D8ds_v6'
            $r | Should -BeNullOrEmpty
            $r | Should -Not -Be 0
        }
    }

    It 'a total with no per-disk size cannot be divided' {
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 0; NvmeDiskSizeInMiB = 3604480 }) } {
            Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_D64ds_v6' | Should -BeNullOrEmpty
        }
    }

    It 'an unparseable capability value is unknown, not zero' {
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 'NotAvailable' }) } {
            Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_D8ds_v6' | Should -BeNullOrEmpty
        }
    }
}

Describe 'TEMPPOOL-1: it asks the existing rule about the name' {
    It "handles the constrained-vCPU name a fresh 'd' regex gets wrong" {
        # Standard_E8-4ds_v5 inserts -4 before the capability letters. This is
        # why the code calls Get-VmfDiskArchitecture instead of carrying its own
        # regex: two rules for one question is how they drift.
        InModuleScope VmMigrationFactory -Parameters @{ s = (Sku @{ MaxResourceVolumeMB = 0 }) } {
            Get-VmfTempDiskCount -SkuEntry $s -SizeName 'Standard_E8-4ds_v5' | Should -BeNullOrEmpty
        }
    }

    It 'and there is only ONE d-suffix rule in the module' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'TempDisks.ps1') -Raw
        $src | Should -Match 'Get-VmfDiskArchitecture'
        $src | Should -Not -Match "\[a-z\]\*" -Because 'a second d-suffix regex here is the drift this avoided'
    }
}

Describe 'TEMPPOOL-1: both halves reach the operator before anything runs' {
    It 'the assessment record carries the SOURCE count' {
        $rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
        $rules | Should -Match 'sourceTempDisks\s*=\s*Get-VmfTempDiskCount'
        $rules | Should -Match 'sourceTempDisks\s*=\s*\$sourceTempDisks'
    }

    It 'the plan entry carries the TARGET count, which only the plan knows' {
        # The target SIZE is chosen at plan time - the assessment cannot know
        # it. The COUNT is derived in Resolve-VmfEntryTarget now (GEN-WAVE-1),
        # because changing a wave's generation changes the target size and must
        # change everything that follows from it, by the same code.
        $derive = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'EntryTarget.ps1') -Raw
        $derive | Should -Match 'tempDisks\s*=\s*Get-VmfTempDiskCount'

        $plan = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $plan | Should -Match 'Resolve-VmfEntryTarget'
        $plan | Should -Match 'tempDisks\s*=\s*\$p\.targetTempDisks'

    }

    It 'and the contract allows null but never a negative' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        $t = $schema.properties.target.properties.tempDisks
        $t | Should -Not -BeNullOrEmpty
        @($t.type) | Should -Contain 'null'
        @($t.type) | Should -Contain 'integer'
        $t.minimum | Should -Be 0
    }

    It 'the sample still validates against the bumped schema' {
        $doc = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw
        { Test-Json -Json $doc -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'and the version was actually bumped, in every place that carries it' {
        # A schema bumped in the file but not in the writer produces documents
        # that fail their own contract.
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        $contract = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'PlanContract.ps1') -Raw
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json
        $v = $schema.properties.schemaVersion.const
        $contract | Should -Match "VmfPlanSchemaVersion = $v"
        $sample.schemaVersion | Should -Be $v
    }

    It 'and the bump ships with a migration note' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        $v = $schema.properties.schemaVersion.const
        $notes | Should -Match "plan-entry v$($v - 1) -> v$v"
    }
}

Describe 'TEMPPOOL-1: and the operator actually sees it' {
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) }

    It 'the wave step names the machines that LOSE their temporary disk' {
        # The v3 -> non-'d' v6 case. Nothing stored there survives a restart
        # today either, but anything that WRITES there needs somewhere to go.
        $script:wiz | Should -Match 'tempLoseTitle'
        $script:wiz | Should -Match 'r\.from > 0 && r\.to === 0'
    }

    It 'and the ones that GAIN drives' {
        $script:wiz | Should -Match 'tempGainTitle'
        $script:wiz | Should -Match 'r\.to > r\.from'
    }

    It 'excludes machines it cannot count, and says the list may be incomplete' {
        # Counting an unknown as "no change" is the failure this whole item is
        # about - it would tell an operator nothing happens when it might.
        $script:wiz | Should -Match 'Number\.isInteger\(r\.from\) && Number\.isInteger\(r\.to\)'
        $script:wiz | Should -Match 'anyUnknown'
        $script:wiz | Should -Match 'tempUnknown'
    }

    It 'and it is information, not another question to answer' {
        # PLANTIME-1 moved DECISIONS earlier. This is not one, so it must not
        # have grown a button.
        $block = [regex]::Match($script:wiz, '(?ms)const tempRows =.*?const tempList = .*?\n').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Not -Match 'addEventListener|<button'
    }
}
