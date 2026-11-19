#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ADE-2, 2026-09-19. Raised by the upstream documentation drift of 2026-07-24,
# read on 2026-09-19.
#
# WHAT WAS WRONG. The product told an operator, in the stop reason and in the
# manual: "Decrypt the disks, or leave this machine out of the run." Microsoft
# now states that Azure Disk Encryption is not available on the v6 or v7 series
# for EITHER operating system, that it retires on 2028-09-15, and that its
# replacement - encryption at host - CANNOT BE ENABLED on a machine that has
# ever had Azure Disk Encryption. The restriction survives decryption,
# snapshots and disk copies. So the advice sent somebody through a long,
# disruptive decryption that did not make the machine eligible, and that
# permanently cost the machine the feature it would need afterwards.
#
# WHAT ELSE CHANGED. The engine learned this from the VM EXTENSIONS at the
# moment the wave ran, so a machine stopped in the middle of a migration that
# somebody had planned days earlier. The scan now reads the setting from the
# machine record too.
#
# THE TRAP THIS FILE GUARDS. Azure records the setting PER DISK, and the
# inventory reads the OS disk. So 'true' is an answer and FALSE IS NOT - a
# machine encrypted on its data disks alone reads false, and the run-time
# extension check is what covers it. A rule that read false as "not encrypted"
# would be the UNKNOWN-as-a-pass defect this repository has a rule against.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:AdeRow {
        param($Ade = $null, [switch]$NoField)
        $row = [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
            name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            imagePublisher = 'MicrosoftWindowsServer'; imageSku = '2022-datacenter-g2'; vmssId = ''
            hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = $Ade
        }
        if ($NoField) { $row.PSObject.Properties.Remove('adeOsDiskEnabled') }
        $row
    }
    function Global:AdeSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' },
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            )
            Restrictions = @()
        }
    }

    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
}
AfterAll { Remove-Item 'function:\AdeRow', 'function:\AdeSku' -ErrorAction SilentlyContinue }

Describe 'ADE-2: the scan says so, days before the wave would have' {

    It 'an encrypted operating system disk is a blocker in the report' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (AdeRow -Ade 'true') -SkuEntry (AdeSku)
            $rec.blockers | Should -Contain 'disk-encryption-present'
            $rec.classification | Should -Be 'Blocked'
        }
    }

    It 'and the same machine without it is not blocked, so the rule is doing the work' {
        # The control case. Without this the rule above could be passing
        # because every machine of this shape is blocked for another reason.
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (AdeRow -Ade 'false') -SkuEntry (AdeSku)
            $rec.blockers | Should -Not -Contain 'disk-encryption-present'
            $rec.classification | Should -Not -Be 'Blocked'
        }
    }
}

Describe 'ADE-2: the scan actually asks Azure for it' {

    It 'the inventory query reads the setting AND carries it through the projection' {
        # A rule that reads a field the query never selects is a rule that can
        # never fire, and nothing else here would notice: every assessment case
        # would simply come back clean.
        $discovery = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1') -Raw
        $discovery | Should -Match 'adeOsDiskEnabled = tostring\(properties\.storageProfile\.osDisk\.encryptionSettings\.enabled\)'
        # The projection is a second list, and a field missing from it is
        # dropped after being computed.
        $projection = [regex]::Match($discovery, '(?s)\| project (.+?)\| order by').Groups[1].Value
        $projection | Should -Not -BeNullOrEmpty
        $projection | Should -Match 'adeOsDiskEnabled'
    }
}

Describe 'ADE-2: false is not an answer' {
    # Azure records the setting per disk and the inventory reads the OS disk.
    # Every one of these means "the scan did not see it on the OS disk", which
    # is not the same as "this machine is not encrypted" - and the engine's
    # extension check before the wave is what settles it.

    It 'no value, an empty value, and a machine scanned before this field all pass the scan' {
        InModuleScope VmMigrationFactory {
            $cases = @(
                @{ What = 'false';   Vm = (AdeRow -Ade 'false') }
                @{ What = 'empty';   Vm = (AdeRow -Ade '') }
                @{ What = 'null';    Vm = (AdeRow -Ade $null) }
                @{ What = 'absent';  Vm = (AdeRow -NoField) }
            )
            $checked = 0
            foreach ($c in $cases) {
                $rec = Get-VmfAssessmentRecord -Vm $c.Vm -SkuEntry (AdeSku)
                $rec.blockers | Should -Not -Contain 'disk-encryption-present' -Because "a $($c.What) value is not a statement that the machine is clean"
                $checked++
            }
            $checked | Should -Be 4 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'and the engine still asks Azure before the wave, which is what covers a data disk' {
        # The scan is an EARLIER answer, never a replacement. If this check
        # ever goes, an encrypted data disk reaches the conversion.
        # ADE-DETECT-ANY-NAME-1: by the extension's publisher and type, and by
        # each disk's own setting.
        $engine = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PrecheckExtensions.ps1')
        $engine | Should -Match 'AzureDiskEncryptionForLinux'
        $engine | Should -Match "'AzureDiskEncryption'"
        $engine | Should -Match "'Microsoft\.Azure\.Security'"
        $ops = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $ops | Should -Match 'encryptionSettingsCollection'
    }
}

Describe 'ADE-2: the words do not send anybody to decrypt a disk' {

    It 'the assessment reason exists and says what it costs' {
        $r = $script:reasons.blockers.'disk-encryption-present'
        $r | Should -Not -BeNullOrEmpty
        $r.meaning | Should -Match '(?i)has ever had'
        $r.meaning | Should -Match '(?i)encryption at host'
        $r.whatToDo | Should -Match '(?i)does not make it eligible'
    }

    It 'and neither reason tells anybody that decryption is the way through' {
        # The defect itself, as an inverted rule. "Decrypt the disks" was the
        # first instruction in the stop reason; it must never come back.
        $present = $script:stops.reasons | Where-Object code -eq 'diskEncryptionPresent'
        $unknown = $script:stops.reasons | Where-Object code -eq 'diskEncryptionUnknown'
        $present | Should -Not -BeNullOrEmpty
        $unknown | Should -Not -BeNullOrEmpty

        foreach ($text in @($present.whatToDo, $unknown.whatToDo, $script:reasons.blockers.'disk-encryption-present'.whatToDo)) {
            $text | Should -Not -Match '(?i)decrypt the disk'
            $text | Should -Not -Match '(?i)until the encryption is removed'
        }
    }

    It 'and the reason stops claiming this is about the NVMe disk type' {
        # It is not a disk-type incompatibility. Microsoft withdrew the feature
        # from the series, for both operating systems.
        $present = $script:stops.reasons | Where-Object code -eq 'diskEncryptionPresent'
        $present.meaning | Should -Not -Match '(?i)NVMe disk type is not supported'
        $present.meaning | Should -Match '(?i)v6 and v7'
    }
}
