#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN-V5-1 C3: the scan records facts; the PLAN judges them against the wave's
# size series.
#
# Before v5 every blocker was a blocker for every target, so the scan could
# decide "Blocked" once. It cannot now. Generation 1, Azure Disk Encryption,
# Windows older than 2019 and an image that cannot start from NVMe block v6 and
# v7 - and none of them blocks v5, which takes Generation 1, keeps Azure Disk
# Encryption and has no NVMe. So each reason says which series it applies to,
# and the plan asks that question for the series the wave chose.
#
# Decided 2026-09-26: Windows Server 2012 R2 on v5 is held until the lab proves
# it - it ships with PowerShell 4.0, and the product's Windows steps inside the
# machine have only run on 5.1. That is its own reason, on v5 only.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json

    function script:Rec {
        param([string[]]$Blockers = @(), [string[]]$Prep = @(), [string]$Classification = 'ReadyAfterPrep',
              [string]$Controller = 'SCSI', [bool]$PlatformManaged = $false)
        [pscustomobject]@{ classification = $Classification; blockers = @($Blockers); prepNeeded = @($Prep)
                           diskController = $Controller; platformManaged = $PlatformManaged }
    }
}

Describe 'GEN-V5-1 C3: every reason says which series it applies to' {

    It 'the data format moved to version 3' {
        $script:reasons.schemaVersion | Should -Be 3
    }

    It 'every blocker and prep item names a non-empty set of series, from v5, v6 and v7' {
        foreach ($group in 'blockers', 'prep') {
            foreach ($p in $script:reasons.$group.PSObject.Properties) {
                $set = @($p.Value.appliesTo)
                $set.Count | Should -BeGreaterThan 0 -Because "$group.$($p.Name) must say where it applies"
                foreach ($g in $set) { $g | Should -BeIn @('v5', 'v6', 'v7') -Because "$group.$($p.Name)" }
            }
        }
    }

    It '<Code> applies to <Expected>' -ForEach @(
        @{ Group = 'blockers'; Code = 'gen1-requires-redeploy';          Expected = 'v6,v7' }
        @{ Group = 'blockers'; Code = 'image-cannot-boot-nvme';          Expected = 'v6,v7' }
        @{ Group = 'blockers'; Code = 'windows-version-below-2019';      Expected = 'v6,v7' }
        @{ Group = 'blockers'; Code = 'disk-encryption-present';         Expected = 'v6,v7' }
        @{ Group = 'blockers'; Code = 'windows-version-not-proven';      Expected = 'v5' }
        @{ Group = 'blockers'; Code = 'confidential-vm-requires-manual'; Expected = 'v5,v6,v7' }
        @{ Group = 'blockers'; Code = 'image-not-supported';             Expected = 'v5,v6,v7' }
        @{ Group = 'blockers'; Code = 'unmanaged-os-disk';               Expected = 'v5,v6,v7' }
        @{ Group = 'blockers'; Code = 'ephemeral-os-disk';               Expected = 'v5,v6,v7' }
        @{ Group = 'blockers'; Code = 'nva-requires-parallel-deployment'; Expected = 'v5,v6,v7' }
        @{ Group = 'blockers'; Code = 'sap-needs-a-certified-size';      Expected = 'v5,v6,v7' }
        @{ Group = 'prep';     Code = 'stornvme';                        Expected = 'v6,v7' }
        @{ Group = 'prep';     Code = 'linux-nvme-prep';                 Expected = 'v6,v7' }
        @{ Group = 'prep';     Code = 'verify-custom-image-nvme-ready';  Expected = 'v6,v7' }
        @{ Group = 'prep';     Code = 'verify-generation';               Expected = 'v6,v7' }
        # REBUILD-REMOVE-PLAN-1: system-identity-recreated is gone - no move deletes the identity.
        @{ Group = 'prep';     Code = 'mana-kernel-floor';               Expected = 'v5,v6,v7' }
    ) {
        (@($script:reasons.$Group.$Code.appliesTo) -join ',') | Should -Be $Expected
    }
}

Describe 'GEN-V5-1 C3: the plan judges a machine against the wave''s series' {

    It 'a Generation 1 machine is Blocked for v6 and ready for v5' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'gen1-requires-redeploy' -Classification 'Blocked') } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Classification | Should -Be 'Blocked'
            $v5 = Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5'
            $v5.Classification | Should -Be 'ReadyAfterPrep'
            @($v5.Blockers).Count | Should -Be 0
        }
    }

    It 'Windows Server 2016 is Blocked for v6 and ready for v5' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'windows-version-below-2019' -Classification 'Blocked') } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Classification | Should -Be 'Blocked'
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5').Classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'Windows Server 2012 R2 is Blocked for both, for a different reason on each' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'windows-version-below-2019', 'windows-version-not-proven' -Classification 'Blocked') } {
            $v6 = Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6'
            $v5 = Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5'
            $v6.Classification | Should -Be 'Blocked'
            $v5.Classification | Should -Be 'Blocked'
            @($v6.Blockers) | Should -Be @('windows-version-below-2019')
            @($v5.Blockers) | Should -Be @('windows-version-not-proven')
        }
    }

    It 'a confidential machine is Blocked for every series' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'confidential-vm-requires-manual' -Classification 'Blocked') } {
            foreach ($g in 'v5', 'v6', 'v7') {
                (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration $g).Classification | Should -Be 'Blocked'
            }
        }
    }

    It 'a machine with a v6 blocker and an all-series blocker is Blocked for v5 by the second alone' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'gen1-requires-redeploy', 'unmanaged-os-disk' -Classification 'Blocked') } {
            $v5 = Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5'
            $v5.Classification | Should -Be 'Blocked'
            @($v5.Blockers) | Should -Be @('unmanaged-os-disk')
        }
    }

    It 'a code the data does not know blocks every series - unknown is never a pass' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Blockers 'a-code-from-a-newer-engine' -Classification 'Blocked') } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5').Classification | Should -Be 'Blocked'
        }
    }

    It 'the prep list keeps only what the series needs' {
        # IDENTITY-LOSS-1: system-identity-recreated was the example of an item
        # on every series; it is a warning now, so mana-kernel-floor is.
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Prep 'stornvme', 'mana-kernel-floor', 'verify-generation') } {
            @((Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5').Prep) | Should -Be @('mana-kernel-floor')
            @((Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Prep).Count | Should -Be 3
        }
    }

    It 'a platform-managed machine stays Excluded on every series' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Classification 'Excluded' -PlatformManaged $true) } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5').Classification | Should -Be 'Excluded'
        }
    }

    It 'a ready machine keeps its own classification' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Classification 'ReadyAfterPrep' -Controller 'NVMe') } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-2: ReadyAfterPrep on NVMe stays ReadyAfterPrep' {
        InModuleScope VmMigrationFactory -Parameters @{ r = (Rec -Classification 'ReadyAfterPrep' -Controller 'NVMe') } {
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Classification | Should -Be 'ReadyAfterPrep'
        }
    }
}

Describe 'GEN-V5-1 C3: the scan records the 2012 R2 hold' {

    BeforeAll {
        function script:Row([string]$Sku) {
            [pscustomobject]@{
                id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/w'
                name = 'w'; resourceGroup = 'rg'; location = 'centralus'; zones = @(); sku = 'Standard_D2s_v3'; os = 'Windows'; gen = 'V1'
                diskController = ''; imagePublisher = 'MicrosoftWindowsServer'; imageSku = $Sku; vmssId = ''
                hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; tags = $null; identityType = 'None'; identityPrincipalId = ''
            }
        }
    }

    It '<Sku>: not proven = <Expected>' -ForEach @(
        @{ Sku = '2012-R2-Datacenter'; Expected = $true }
        @{ Sku = '2008-R2-SP1';        Expected = $true }
        @{ Sku = '2016-Datacenter';    Expected = $false }
        @{ Sku = '2019-Datacenter';    Expected = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ row = (Row $Sku); expected = $Expected } {
            $rec = Get-VmfAssessmentRecord -Vm $row
            (@($rec.blockers) -contains 'windows-version-not-proven') | Should -Be $expected
        }
    }
}

Describe 'GEN-V5-1 C3: the plan uses the judgement' {

    BeforeAll {
        $script:catalog = @{}
        foreach ($n in 'Standard_D2ds_v5', 'Standard_D2ds_v6') {
            $gens = if ($n -like '*_v5') { 'V1,V2' } else { 'V2' }
            $script:catalog[$n] = [pscustomobject]@{ Name = $n; Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $(if ($n -like '*_v5') { '76800' } else { '0' }) },
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $gens }) }
        }
    }

    It 'a Generation 1 Linux machine is MANUAL on a v6 wave and a resize on a v5 wave' {
        $vm = [pscustomobject]@{ vmId = 'x'; sourceSize = 'Standard_D2ds_v4'; os = 'Linux'; classification = 'Blocked'
            blockers = @('gen1-requires-redeploy'); prepNeeded = @('linux-nvme-prep'); sourceDiskArch = 'scsi-temp'
            diskController = ''; nicCount = 1; dataDiskCount = 0; hyperVGeneration = 'V1'; gen = 'V1'; platformManaged = $false }
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm; c = $script:catalog } {
            $v6 = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            $v6.Path | Should -Be 'MANUAL'
            $v6.Classification | Should -Be 'Blocked'
            $v5 = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $v5.Path | Should -Be 'A'
            $v5.Classification | Should -Be 'ReadyAfterPrep'
            $v5.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        }
    }

    It 'the target controller comes from the series: v5 SCSI, v6 NVMe' {
        $vm = [pscustomobject]@{ vmId = 'x'; sourceSize = 'Standard_D2ds_v4'; os = 'Linux'; classification = 'ReadyAfterPrep'
            blockers = @(); prepNeeded = @(); sourceDiskArch = 'scsi-temp'; diskController = 'SCSI'; nicCount = 1; dataDiskCount = 0
            hyperVGeneration = 'V2'; gen = 'V2'; platformManaged = $false }
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm; c = $script:catalog } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5').Controller | Should -Be 'SCSI'
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Controller | Should -Be 'NVMe'
        }
    }

    It 'the plan writes that controller, not a fixed NVMe' {
        foreach ($file in @('New-VmfPlan.ps1')) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $file)
            $code | Should -Not -Match "controller\s*=\s*'NVMe'" -Because "$file must not fix the controller"
            $code | Should -Match '\.Controller' -Because "$file must take it from the target decision"
        }
    }
}
