#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-PRIMARY-1: the scan records whether the PRIMARY interface has accelerated
# networking, so a machine with several interfaces is understood.
#
# Since 2026-09-26, the scan must understand machines with several network
# interfaces. The engine decides the accelerated networking stop from the
# primary interface (Get-VmfPrimaryNic: the one Azure flags primary, else the
# first). The scan recorded only how many were on, so for several interfaces
# with some on the target options had to say unknown. The scan now records the
# primary's setting by the engine's rule, and the options use it.
#
# The assessment format is closed, so this is a deliberate version: v2. A v1
# assessment still reads - it has no such field, which reads as unknown - and a
# version newer than this build is refused by name, as a plan is.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The shape Resource Graph returns for a machine's interfaces:
    # networkProfile.networkInterfaces[] = { id, properties = { primary } }.
    function Global:ApNic([string]$Id, [object]$Primary) {
        if ($null -eq $Primary) { return [pscustomobject]@{ id = $Id } }
        [pscustomobject]@{ id = $Id; properties = [pscustomobject]@{ primary = [bool]$Primary } }
    }
    function Global:ApRecord([object[]]$Nics, [hashtable]$Map) {
        $vm = [pscustomobject]@{
            id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
            osDiskManagedId = '/s/rg/disks/a'; nicCount = @($Nics).Count; nicIds = @($Nics)
        }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm; m = $Map } { Get-VmfAssessmentRecord -Vm $v -NicAcceleratedMap $m }
    }
    function Global:ApSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Capabilities = @(
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:ApV5Option([int]$Nics, [object]$Count, [object]$Primary) {
        $vm = [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = $Nics; acceleratedNicCount = $Count; primaryNicAccelerated = $Primary
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
        $cat = @{ 'Standard_D2ds_v5' = (ApSku 'Standard_D2ds_v5' '76800' 'V1,V2') }
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'r'; vms = @($vm) }
        $a = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = $cat } { Get-VmfTargetAdvice -Assessment $d -CatalogByLocation @{ centralus = $c } }
        @(@($a.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
    }
}
AfterAll { Remove-Item 'function:\ApNic', 'function:\ApRecord', 'function:\ApSku', 'function:\ApV5Option' -ErrorAction SilentlyContinue }

Describe 'AN-PRIMARY-1: the scan finds the primary interface by the engine''s rule' {

    It 'the interface Azure flags primary - here the second, which is on' {
        $r = ApRecord @((ApNic '/s/nic/one' $false), (ApNic '/s/nic/two' $true)) @{ '/s/nic/one' = $false; '/s/nic/two' = $true }
        $r.primaryNicAccelerated | Should -BeTrue
        $r.acceleratedNicCount | Should -Be 1
    }

    It 'the flagged primary is off, while another interface is on' {
        $r = ApRecord @((ApNic '/s/nic/one' $true), (ApNic '/s/nic/two' $false)) @{ '/s/nic/one' = $false; '/s/nic/two' = $true }
        $r.primaryNicAccelerated | Should -BeFalse
    }

    It 'with no interface flagged, the first one, as the engine takes it' {
        $r = ApRecord @((ApNic '/s/nic/one' $null), (ApNic '/s/nic/two' $null)) @{ '/s/nic/one' = $true; '/s/nic/two' = $false }
        $r.primaryNicAccelerated | Should -BeTrue
    }

    It 'the primary interface could not be read: unknown, never off' {
        $r = ApRecord @((ApNic '/s/nic/one' $true), (ApNic '/s/nic/two' $false)) @{ '/s/nic/two' = $true }
        $null -eq $r.primaryNicAccelerated | Should -BeTrue
    }

    It 'no interfaces were read at all: unknown' {
        $r = ApRecord @((ApNic '/s/nic/one' $true)) $null
        $null -eq $r.primaryNicAccelerated | Should -BeTrue
    }

    It 'an interface id is matched without regard to case, as the count already is' {
        $r = ApRecord @((ApNic '/S/NIC/One' $true)) @{ '/s/nic/one' = $true }
        $r.primaryNicAccelerated | Should -BeTrue
    }
}

Describe 'AN-PRIMARY-1: the target options use it, as the engine does' {

    It 'several interfaces, the primary off: the Intel D v5 stop is certain' {
        $o = ApV5Option -Nics 2 -Count 1 -Primary $false
        $o.acceleratedNetworking.turnsOn | Should -BeTrue
        @($o.stops) | Should -Contain 'acceleratedNetworkingRequired'
    }

    It 'several interfaces, the primary on: no stop' {
        $o = ApV5Option -Nics 2 -Count 1 -Primary $true
        $o.acceleratedNetworking.turnsOn | Should -BeFalse
        @($o.stops).Count | Should -Be 0
    }

    It 'an assessment written before this has no primary reading: still unknown for several interfaces with some on' {
        $o = ApV5Option -Nics 2 -Count 1 -Primary $null
        $null -eq $o.acceleratedNetworking.turnsOn | Should -BeTrue
    }
}

Describe 'AN-PRIMARY-1: the assessment format is version 2, read the way a plan is' {

    It 'one place holds the version, and the scan writes it' {
        # ADVISE-AN-1 made it 3 (the running release), DETECT-PATTERNS-1 4 (the workload type), HDD-OS-1 5, CLUSTER-DETECT-1 6, REBUILD-ACCEPT-1 7, REBUILD-PATCH-MODE-1 8; this item's field is still there.
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion | Should -Be 17 }
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
        $code | Should -Match 'schemaVersion = Get-VmfAssessmentSchemaVersion'
    }

    It 'a version-1 assessment is still accepted, and a later one is refused by name' {
        InModuleScope VmMigrationFactory {
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 1 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 2 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) -Source 'scan-1' } |
                Should -Throw '*scan-1*newer version of the product*version 18*understands up to 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = $null }) } | Should -Throw '*Unsupported*'
        }
    }

    It 'the planner and the target options both read through it' {
        foreach ($f in 'New-VmfPlan.ps1', 'New-VmfTargetAdvice.ps1') {
            $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $f) -Raw
            $code | Should -Match 'Assert-VmfSupportedAssessment' -Because $f
            $code | Should -Not -Match 'schemaVersion -ne 1' -Because "$f must not refuse a version-2 assessment"
        }
    }

    It 'the schema accepts both versions and declares the new field' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 17 -Because 'ADVISE-AN-1 added version 3, DETECT-PATTERNS-1 version 4, HDD-OS-1 version 5, CLUSTER-DETECT-1 version 6, REBUILD-ACCEPT-1 version 7, REBUILD-PATCH-MODE-1 version 8, DCR-READ-1 version 9, ALREADY-CURRENT-1 version 10, READY-NOW-REMOVE-1 version 11, REBUILD-REMOVE-ROLE-1 version 12, CRG-MOVE-DEMAND-1 version 13, SCAN-PARTIAL-SUBS-1 version 14, REBUILD-REMOVE-SCAN-EXT-1 version 15, DRIFT-12 version 16'
        $s.properties.vms.items.properties.primaryNicAccelerated | Should -Not -BeNullOrEmpty
    }

    It 'a record the scan writes validates against the schema' {
        $r = ApRecord @((ApNic '/s/nic/one' $true)) @{ '/s/nic/one' = $true }
        $doc = [ordered]@{ schemaVersion = 17; runId = 'r'; generatedUtc = '2026-09-26T00:00:00Z'; scope = @{ subscriptions = @() }; summary = @{}; vms = @($r) }
        ($doc | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
    }
}
