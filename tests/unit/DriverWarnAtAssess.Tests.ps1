#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIVER-WARN-1, 2026-09-23. The assessment says NOTHING about the kernel
# floor, and the first anybody hears of it is mid-migration.
#
# Owner, on a machine parked at VALIDATING with a full red panel about the
# MANA kernel floor: "weirdly I'm not sure I saw this level of warning
# previously in all red prior. this is a huge red issue but in the assessment
# it really didn't have this same level of attention I don't think."
#
# He was right, and it was worse than he thought. `assessment-reasons.json`
# had no code for it at all - not a blocker, not a prep item. So a Linux
# machine that will be stopped by this gate looked clean at assessment time,
# and the first anyone heard was mid-migration with the safety copy taken and
# the guest already prepared.
#
# WHY IT CANNOT SIMPLY MOVE EARLIER. The check reads the kernel from INSIDE
# the machine (`mana-check.sh`). The assessment reads ARM, so it genuinely
# cannot know the kernel version. What it CAN do is say the check is coming
# and what it can do - which is the product's own rule about unknowns: never
# read as a yes, never as a no.
#
# THE ITEM MUST PREDICT THE GATE THAT EXISTS. `Get-VmfDriverJudgement` judges
# the MANA floor for any non-Windows machine heading to an NVMe target,
# whatever its accelerated-networking state - so this is every Linux machine,
# not only the ones with accelerated networking on. An item scoped narrower
# than the gate would let exactly the parked machine through.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw |
        ConvertFrom-Json
    $script:code = 'mana-kernel-floor'

    function Global:NewRow {
        param([string]$Os = 'Windows', [string]$ImagePublisher = 'MicrosoftWindowsServer',
              [string]$ImageSku = '2022-datacenter-g2')
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
            sku = 'Standard_D2ds_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
            imagePublisher = $ImagePublisher; imageSku = $ImageSku; vmssId = ''
            hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $null; identityType = 'None'; identityPrincipalId = ''
        }
    }
    function Global:NewSku {
        [pscustomobject]@{ name = 'Standard_D2ds_v4'; family = 'StandardDDSv4Family'
            capabilities = @(@{ name = 'MaxResourceVolumeMB'; value = '76800' }, @{ name = 'vCPUs'; value = '2' })
            restrictions = @() }
    }
}
AfterAll { Remove-Item -Path 'Function:NewRow', 'Function:NewSku' -ErrorAction SilentlyContinue }

Describe 'DRIVER-WARN-1: the assessment says the kernel is checked later' {

    It 'a Linux machine carries the item' {
        $r = & (Get-Module VmMigrationFactory) { param($v, $s) Get-VmfAssessmentRecord -Vm $v -SkuEntry $s } `
            (NewRow -Os 'Linux' -ImagePublisher 'Canonical' -ImageSku '22_04-lts-gen2') (NewSku)
        @($r.prepNeeded) | Should -Contain $script:code
    }

    It 'a Windows machine does NOT' {
        # Microsoft publishes no minimum driver version for Windows, and the
        # engine records rather than judges it. Saying otherwise here would be
        # inventing a floor - the one thing DRIVER-1 forbids.
        $r = & (Get-Module VmMigrationFactory) { param($v, $s) Get-VmfAssessmentRecord -Vm $v -SkuEntry $s } `
            (NewRow) (NewSku)
        @($r.prepNeeded) | Should -Not -Contain $script:code
    }

    It 'it is PREP, not a blocker - the machine may well be fine' {
        # Unknown must never be read as a fail. Most machines pass this check.
        $script:reasons.prep.PSObject.Properties.Name | Should -Contain $script:code
        $script:reasons.blockers.PSObject.Properties.Name | Should -Not -Contain $script:code
    }
}

Describe 'DRIVER-WARN-1: what it says' {

    BeforeAll { $script:entry = $script:reasons.prep.$($script:code) }

    It 'names what is checked and where' {
        "$($script:entry.meaning)" | Should -Match '(?i)kernel'
        "$($script:entry.meaning)" | Should -Match '(?i)MANA|Microsoft Azure Network Adapter'
    }

    It 'says the check happens when the machine migrates, not now' {
        # The honest part: the assessment cannot read a kernel, so it must not
        # imply it has.
        # ON THE MEANING, not on either sentence. Found by mutation: dropping
        # it from the meaning left "The tool reads the kernel from inside this
        # machine", which implies it ALREADY HAS - and the assessment has not.
        # The other sentence still mentioned the migration, so a check across
        # both passed while the misleading one was in front of the reader.
        "$($script:entry.meaning)" | Should -Match '(?i)when it migrates|at migration|during the migration'
    }

    It 'INVENTS NO FLOOR' {
        # DRIVER-1: the floor is published per distribution and lives in
        # data/driver-floors.json. A number written into a sentence here would
        # be a second copy, and wrong the day the table changes.
        "$($script:entry.meaning) $($script:entry.whatToDo)" |
            Should -Not -Match '\d+\.\d+\.\d+-\d+' -Because 'a kernel version here would be a floor invented in prose'
    }

    It 'tells a person what they can do about it BEFORE they start' {
        # The whole point of moving it earlier: there is something to do.
        "$($script:entry.whatToDo)" | Should -Match '(?i)patch|update|upgrade|check'
        "$($script:entry.whatToDo)" | Should -Not -Match '(?i)do nothing'
    }

    It 'and links to the table it is judged against' {
        "$($script:entry.docs.url)" | Should -Match '^https://learn\.microsoft\.com/'
        "$($script:entry.docs.label)" | Should -Not -BeNullOrEmpty
    }
}
