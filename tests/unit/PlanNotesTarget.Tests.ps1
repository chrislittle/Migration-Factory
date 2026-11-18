#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# PLAN-NOTES-TARGET-1: the plan's notes for a machine come from ONE function.
#
# New-VmfPlan wrote the notes of a moved machine (a size the catalog could not
# verify, the retirement warning, the note for a machine already on NVMe) and
# Set-VmfMachineTarget (WAVE-MIX-2) rewrote them with the retirement warning
# alone. So a target changed in the wave editor dropped the others, and the
# Run it step said less than a plan made on that target would. Both writers
# now ask Get-VmfPlanEntryNotes, and a changed target has the notes a plan made
# on it has.
#
# The kernel note of MANA-LINUX-KERNEL-1 is not one of them any more:
# AN-MANA-DRIVER-RULE-1 plans no machine whose release Microsoft does not list
# for MANA on a size that can give MANA, so the plan writes no kernel note.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:PnSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:PnId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:PnVm([string]$Name, [string]$Controller = 'SCSI') {
        [ordered]@{
            vmId = (PnId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); classification = 'ReadyAfterPrep'; gen = 'V2'
            os = 'Linux'; osVersion = '22_04-lts-gen2'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'
            sourceTempDisks = 1; diskController = $Controller
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
            blockers = @(); prepNeeded = @()
        }
    }
    # A migration of one machine, planned on $Series.
    function Global:PnPlanned([string]$Series, [string]$Controller = 'SCSI') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-09-27T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @((PnVm 'app-01' $Controller)) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ p = $rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'target-advice.json')) }
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @(@{ vmId = (PnId 'app-01'); option = $Series }) `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $mig = "$rp-migration"
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $mig | Out-Null
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:PnEntry($mig) {
        @((Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (PnId 'app-01')
    }
}
AfterAll { Remove-Item 'function:\PnSku', 'function:\PnId', 'function:\PnVm', 'function:\PnPlanned', 'function:\PnEntry' -ErrorAction SilentlyContinue }

Describe 'PLAN-NOTES-TARGET-1: Get-VmfPlanEntryNotes gives the notes of one moved machine' {

    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfRetirementWarning { "RETIRES $Size" }
    }

    It 'a machine with no target: the reason it is not moved, and nothing else' {
        InModuleScope VmMigrationFactory {
            $n = @(Get-VmfPlanEntryNotes -Mapping @{ Target = $null; Reason = 'No target was chosen for this machine, so it is not moved.' } `
                    -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D2ds_v4'; diskController = 'NVMe' }) -Controller '' -Path 'MANUAL')
            $n | Should -Be @('No target was chosen for this machine, so it is not moved.')
        }
    }

    It 'a size the catalog could not verify: its reason, then the retirement warning, in that order' {
        InModuleScope VmMigrationFactory {
            $reason = 'default-transform (capacity could not be verified: Azure reported no vCPUs for Standard_D2ds_v6)'
            $n = @(Get-VmfPlanEntryNotes -Mapping @{ Target = 'Standard_D2ds_v6'; Reason = $reason; Code = 'mapped-unverified' } `
                    -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D2ds_v4'; diskController = 'NVMe' }) -Controller 'NVMe' -Path 'A')
            # MANUAL-REVIEW-1: no note about a lab run for a machine already on NVMe.
            $n | Should -Be @($reason, 'RETIRES Standard_D2ds_v4')
        }
    }

    It 'a size that fits: no reason, and the warning of the source size' {
        InModuleScope VmMigrationFactory {
            $n = @(Get-VmfPlanEntryNotes -Mapping ([pscustomobject]@{ Target = 'Standard_D2ds_v5'; Reason = 'default-transform'; Code = 'mapped' }) `
                    -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D2ds_v4'; diskController = 'SCSI' }) -Controller 'SCSI' -Path 'A')
            $n | Should -Be @('RETIRES Standard_D2ds_v4')
        }
    }

    It 'a machine this plan does not move gets no retirement warning' {
        InModuleScope VmMigrationFactory {
            $n = @(Get-VmfPlanEntryNotes -Mapping @{ Target = 'Standard_D2ds_v6'; Reason = 'default-transform' } `
                    -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D2ds_v4'; diskController = 'SCSI' }) -Controller 'NVMe' -Path 'EXCLUDED')
            $n.Count | Should -Be 0
        }
    }

    It 'no notes is an empty list, never a null in it' {
        Mock -ModuleName VmMigrationFactory Get-VmfRetirementWarning { $null }
        InModuleScope VmMigrationFactory {
            $n = @(Get-VmfPlanEntryNotes -Mapping @{ Target = 'Standard_D2ds_v5'; Reason = 'default-transform' } `
                    -Assessment ([pscustomobject]@{ sourceSize = 'Standard_D2ds_v4'; diskController = 'SCSI' }) -Controller 'SCSI' -Path 'A')
            $n.Count | Should -Be 0
        }
    }
}

Describe 'PLAN-NOTES-TARGET-1: both plan writers ask the one function' {

    It '<name> writes planNotes only from Get-VmfPlanEntryNotes' -ForEach @(
        @{ name = 'New-VmfPlan' }, @{ name = 'Set-VmfMachineTarget' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' "$name.ps1")
        $code | Should -Match 'Get-VmfPlanEntryNotes'
        $code | Should -Not -Match 'Get-VmfRetirementWarning' -Because 'the retirement warning comes through the one function'
        $code | Should -Not -Match 'Get-VmfNvmeSourceNote' -Because 'the NVMe note comes through the one function'
        $code | Should -Not -Match 'could not be verified' -Because 'the unverified size note comes through the one function'
    }
}

Describe 'PLAN-NOTES-TARGET-1: a target changed in the wave editor has the notes a plan made on it has' {

    BeforeEach {
        $script:catalog = @((PnSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (PnSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (PnSku 'Standard_D2ds_v6'), (PnSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        # A source size in its last 12 months, so the plan has a note to keep.
        Mock -ModuleName VmMigrationFactory Get-VmfRetirementWarning { "RETIRES $Size" }
        $script:runs = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach {
        foreach ($r in $script:runs) { foreach ($d in $r.Scan, $r.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }
    }

    It '<from> to <to>, disk controller <controller> now: the notes equal those of a plan made on <to>' -ForEach @(
        @{ from = 'v6'; to = 'v5'; controller = 'SCSI' }
        @{ from = 'v5'; to = 'v6'; controller = 'SCSI' }
        @{ from = 'v5'; to = 'v6'; controller = 'NVMe' }
        @{ from = 'v6'; to = 'v5'; controller = 'NVMe' }) {
        $changed = PnPlanned $from $controller; $script:runs.Add($changed)
        $direct = PnPlanned $to $controller; $script:runs.Add($direct)
        (Set-VmfMachineTarget -RunPath $changed.Mig -VmId (PnId 'app-01') -Option $to -ChangedBy 'operator@example.com' -Confirm:$false).Applied |
            Should -BeTrue
        $want = @((PnEntry $direct.Mig).planNotes)
        $got = @((PnEntry $changed.Mig).planNotes)
        $want | Should -Contain 'RETIRES Standard_D2ds_v4' -Because 'the case must hold a note to lose'
        ($got | ConvertTo-Json -Compress) | Should -BeExactly ($want | ConvertTo-Json -Compress)
    }

    It 'MANUAL-REVIEW-1: a machine on NVMe, planned or changed in the wave editor, has no note about a lab run' {
        $changed = PnPlanned 'v5' 'NVMe'; $script:runs.Add($changed)
        (@((PnEntry $changed.Mig).planNotes) -join ' ') | Should -Not -Match '(?i)\blab\b'
        Set-VmfMachineTarget -RunPath $changed.Mig -VmId (PnId 'app-01') -Option v6 -ChangedBy 'operator@example.com' -Confirm:$false | Out-Null
        (@((PnEntry $changed.Mig).planNotes) -join ' ') | Should -Not -Match '(?i)\blab\b'
        @((PnEntry $changed.Mig).planNotes) | Should -Contain 'RETIRES Standard_D2ds_v4' -Because 'the other notes stay'
    }

    It 'a size the catalog cannot verify is never a changed target: refused, and the plan is as it was' {
        $changed = PnPlanned 'v6'; $script:runs.Add($changed)
        # The v5 size now reports no vCPU count and no network interface limit.
        $script:catalog = @(([pscustomobject]@{ Name = 'Standard_D2ds_v5'; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
                    Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' }
                        [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }) }),
            (PnSku 'Standard_D2s_v5' '0' 'V1,V2'), (PnSku 'Standard_D2ds_v6'), (PnSku 'Standard_D2s_v6'))
        $before = Get-Content (Join-Path $changed.Mig 'plan.json') -Raw
        { Set-VmfMachineTarget -RunPath $changed.Mig -VmId (PnId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false `
                -CatalogBySize (& { $c = @{}; foreach ($s in $script:catalog) { $c[$s.Name] = $s }; $c }) } |
            Should -Throw '400: app-01 cannot move to v5*size-unverified*'
        Get-Content (Join-Path $changed.Mig 'plan.json') -Raw | Should -BeExactly $before
    }
}
