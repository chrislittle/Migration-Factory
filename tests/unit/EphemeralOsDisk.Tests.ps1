#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EPHEMERAL-1, 2026-09-19. Found by comparing this product's Azure Resource
# Graph inventory against the one Microsoft published in the 24 July rewrite -
# finding 5 of the drift evaluation.
#
# THE OTHER MACHINE WITH NO MANAGED OS DISK. ASSESS-2(a) added a blocker for an
# unmanaged (blob VHD) OS disk, and its comment describes the whole class:
#
#   "cannot be migrated by it at all, and today it gets as far as PRECHECK
#    before failing on a capture that assumes a managed disk. Saying so in the
#    report turns a confusing mid-run failure into a plain answer at the start."
#
# It only ever fired on a VHD uri. An EPHEMERAL OS disk has neither a uri nor a
# disk resource - the disk lives on the host - so it passed every check, was
# assessed as migratable, entered a wave, and failed at its FIRST SAFETY COPY
# on a null disk id, with an error naming nothing about ephemeral disks. The
# machine was untouched, which is why nobody had met it yet.
#
# A rule written for the case that produced it, never pointed at the case
# beside it. The same shape as every defect found on the first real install.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:EphRow {
        param([string]$Diff = '', [string]$ManagedId = '/subscriptions/x/disks/vm1-os', [string]$Vhd = '')
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
            name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter-g2'
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = $ManagedId; osDiskVhdUri = $Vhd
            osDiskDiffOption = $Diff
        }
    }
    function Global:EphSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' },
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            )
            Restrictions = @()
        }
    }
}
AfterAll { Remove-Item 'function:\EphRow', 'function:\EphSku' -ErrorAction SilentlyContinue }

Describe 'EPHEMERAL-1: an ephemeral OS disk is named at the scan' {

    It 'a machine whose OS disk lives on the host is blocked' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (EphRow -Diff 'Local') -SkuEntry (EphSku)
            $rec.blockers | Should -Contain 'ephemeral-os-disk'
            $rec.classification | Should -Be 'Blocked'
        }
    }

    It 'and the note says why, in words about the disk rather than the engine' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (EphRow -Diff 'Local') -SkuEntry (EphSku)
            ($rec.notes -join ' ') | Should -Match '(?i)lives on the host'
        }
    }

    It 'the inventory query reads it AND carries it through the projection' {
        # A rule reading a field the query never selects can never fire, and
        # every machine would simply come back clean.
        $discovery = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1') -Raw
        $discovery | Should -Match 'osDiskDiffOption = tostring\(properties\.storageProfile\.osDisk\.diffDiskSettings\.option\)'
        $projection = [regex]::Match($discovery, '(?s)\| project (.+?)\| order by').Groups[1].Value
        $projection | Should -Match 'osDiskDiffOption'
    }
}

Describe 'EPHEMERAL-1: it cannot fire on an ordinary machine' {
    # A blocker has no way past, so only Azure's one value for "ephemeral" may
    # raise it.

    It 'an ordinary managed OS disk is not blocked' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (EphRow) -SkuEntry (EphSku)
            $rec.blockers | Should -Not -Contain 'ephemeral-os-disk'
            $rec.classification | Should -Not -Be 'Blocked'
        }
    }

    It 'and neither is an empty value, a missing field, or any word but Local' {
        InModuleScope VmMigrationFactory {
            $cases = @(
                @{ What = 'empty';        Vm = (EphRow -Diff '') }
                @{ What = 'None';         Vm = (EphRow -Diff 'None') }
                @{ What = 'a substring';  Vm = (EphRow -Diff 'NotLocalAtAll') }
                @{ What = 'CacheDisk';    Vm = (EphRow -Diff 'CacheDisk') }
            )
            $checked = 0
            foreach ($c in $cases) {
                $rec = Get-VmfAssessmentRecord -Vm $c.Vm -SkuEntry (EphSku)
                $rec.blockers | Should -Not -Contain 'ephemeral-os-disk' -Because "$($c.What) does not mean the disk is on the host"
                $checked++
            }
            $checked | Should -Be 4 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'and a machine scanned before this field existed still reads' {
        InModuleScope VmMigrationFactory {
            $old = EphRow
            $old.PSObject.Properties.Remove('osDiskDiffOption')
            $rec = Get-VmfAssessmentRecord -Vm $old -SkuEntry (EphSku)
            $rec.blockers | Should -Not -Contain 'ephemeral-os-disk'
        }
    }
}

Describe 'EPHEMERAL-1: the older rule it sits beside still works' {
    # The two are different machines with different advice: a VHD is converted
    # to a managed disk, an ephemeral one is deployed again. Neither rule may
    # swallow the other.

    It 'an unmanaged blob VHD still raises its own blocker, and not this one' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (EphRow -ManagedId '' -Vhd 'https://sa.blob.core.windows.net/vhds/vm1.vhd') -SkuEntry (EphSku)
            $rec.blockers | Should -Contain 'unmanaged-os-disk'
            $rec.blockers | Should -Not -Contain 'ephemeral-os-disk'
        }
    }

    It 'and the two reasons give different advice' {
        $reasons = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $eph = $reasons.blockers.'ephemeral-os-disk'
        $vhd = $reasons.blockers.'unmanaged-os-disk'
        $eph | Should -Not -BeNullOrEmpty
        $eph.whatToDo | Should -Match '(?i)deploy this machine again'
        $vhd.whatToDo | Should -Not -Be $eph.whatToDo
    }
}
