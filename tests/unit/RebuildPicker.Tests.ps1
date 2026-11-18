#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-PICKER-1: recommend the in-place upgrade, and start every machine on it.
#
# A Windows Standard_D4ds_v4 (SCSI temporary disk) with NO system-assigned
# identity started on Standard_D4ds_v6 under the Current default. The v6 size
# has an NVMe temporary disk, so the move is a rebuild around the same disks,
# which deletes the VM definition with its extensions and links. D4ds_v5 keeps
# the SCSI temporary disk and upgrades it in place. Only a machine with a
# system-assigned identity started there (IDENTITY-LOSS-1).
#
# Since 2026-11-01: every machine whose move would rebuild it starts on the
# in-place option. A person can still choose the rebuild.
#
# And the method is recorded: target-choices v7 and plan-entry v23 carry
# method (in-place, rebuild, preview), so the plan never rebuilds a machine
# whose person saved an in-place upgrade.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:RpSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '4' }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = '16' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:RpCatalog([switch]$NoV5) {
        $c = @{}
        $sizes = @((RpSku 'Standard_D4ds_v4' '153600'), (RpSku 'Standard_D4ds_v6' '0'), (RpSku 'Standard_D4s_v6' '0'))
        if (-not $NoV5) { $sizes += @((RpSku 'Standard_D4ds_v5' '153600' 'V1,V2'), (RpSku 'Standard_D4s_v5' '0' 'V1,V2')) }
        foreach ($s in $sizes) { $c[$s.Name] = $s }
        $c
    }
    function Global:RpVm([string]$Os = 'Windows', [string]$Identity = 'None', [string]$Name = 'app-01') {
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
            osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = 'Standard_D4ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 0; primaryNicAccelerated = $false
            platformManaged = $false; blockers = @(); prepNeeded = @()
            identityType = $Identity; identityPrincipalId = $(if ($Identity -match 'SystemAssigned') { '11111111-2222-3333-4444-555555555555' } else { '' })
        }
    }
    function Global:RpAdvise([object[]]$Vms, [hashtable]$Catalog = (RpCatalog)) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    function Global:RpOption([string]$Name, [bool]$Rebuild, [object]$KeptOn = $null, [object]$ProcessorChange = $false, [bool]$Supported = $true) {
        [pscustomobject]@{ option = $Name; supported = $Supported; targetSize = "Standard_D4ds_$Name"; rebuild = $Rebuild
            identity = 'none'; processorChange = $ProcessorChange; burstableKept = $false
            acceleratedNetworking = [pscustomobject]@{ keptOn = $KeptOn }; sizeChoices = @() }
    }
    function Global:RpSelect([object[]]$Options, [string]$Start, [string[]]$Order = @('v6', 'v7', 'v5')) {
        InModuleScope VmMigrationFactory -Parameters @{ o = $Options; s = $Start; r = $Order } {
            param($o, $s, $r) Select-VmfInPlaceStart -Options $o -Start $s -Order $r
        }
    }
}
AfterAll { Remove-Item 'function:\RpSku', 'function:\RpCatalog', 'function:\RpVm', 'function:\RpAdvise', 'function:\RpOption', 'function:\RpSelect' -ErrorAction SilentlyContinue }

# REBUILD-REMOVE-PLAN-1 (2026-11-07): the rebuild around the same disks is
# removed, so the start rule that moved a machine off a rebuild (Select-VmfInPlaceStart)
# and the method rebuild are gone. The tests that pinned them were here; the method
# of a move, the contracts and the save-to-plan flow are tested in their new shape in
# RebuildRemovePlan.Tests.ps1. The review below still guards the engine words that
# remain until the engine half of the removal.

Describe 'REBUILD-PICKER-1 review (PR #690): the engine says identity and object ID, never account' {
    It 'no message of <Name> calls a system-assigned identity an account' -ForEach @(
        @{ Name = 'RestoreRebuild.ps1'; Rel = 'Private/engine/RestoreRebuild.ps1' }
        @{ Name = 'RebuildFidelity.ps1'; Rel = 'Private/validate/RebuildFidelity.ps1' }
        @{ Name = 'New-VmfReport.ps1'; Rel = 'Public/New-VmfReport.ps1' }
        @{ Name = 'Resolve-VmfDecision.ps1'; Rel = 'Public/Resolve-VmfDecision.ps1' }
        @{ Name = 'Orchestrator.ps1'; Rel = 'Private/engine/Orchestrator.ps1' }
    ) {
        $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $Rel
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errs)
        $said = @($tokens | Where-Object { $_.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable' } | ForEach-Object { $_.Text } |
            Where-Object { $_ -match '(?i)identit|object ID' -and ($_ -replace '(?i)storage account', '' -replace '\$\w+', '') -match '(?i)\baccount\b' })
        $said | Should -BeNullOrEmpty
    }
}
