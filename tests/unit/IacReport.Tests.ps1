#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# IAC-REPORT-1: the customer's report shows, for EVERY machine the product
# changed, what changed that a definition in code holds.
#
# The old "Terraform reconciliation" section waited for an iacManaged mark
# nothing has written since IAC-2, so it never showed. Since 2026-09-29: a
# table for every machine. The facts are read from what the product recorded;
# a fact it did not record says so.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # A machine as the engine records it. ARM reports Primary=false on a
    # machine with one network interface, so that is the default here.
    function Global:IrDoc([string]$Name, [string]$State, [string]$Path = 'A', [string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe',
        [object]$AnBefore = $false, [string]$Policy = 'ensureOn', [object]$Primary = $false) {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r'; vmId = "/s/rg/vm/$Name"; state = $State; history = @()
            captured = [pscustomobject]@{
                vmConfig = [pscustomobject]@{ size = 'Standard_D2s_v4'; controller = 'SCSI'
                    osDisk = [pscustomobject]@{ name = "$Name-os"; managedDiskId = "/s/rg/disks/$Name-os"; skuName = 'StandardSSD_LRS' }
                    dataDisks = @([pscustomobject]@{ lun = 0; name = "$Name-d0"; managedDiskId = "/s/rg/disks/$Name-d0"; skuName = 'Standard_LRS' })
                    nics = @([pscustomobject]@{ id = 'n0'; primary = $Primary; acceleratedNetworking = $AnBefore }) }
                startedTarget = [pscustomobject]@{ path = $Path; size = $Size; controller = $Controller; acceleratedNetworking = $Policy }
                acceleratedNetworking = [pscustomobject]@{ policy = $Policy; expectFabric = $true } } }
    }
    function Global:IrAdd($doc, [string]$Name, $Value) { $doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force; $doc }
    function Global:IrRows($docs) {
        foreach ($one in @($docs)) { $null = Complete-VmfTestCapture $one }
        InModuleScope VmMigrationFactory -Parameters @{ d = @($docs) } { param($d) @(Get-VmfIacChangeRows -StateDocs $d) }
    }
}
AfterAll { Remove-Item function:IrDoc, function:IrAdd, function:IrRows -ErrorAction SilentlyContinue }

Describe 'IAC-REPORT-1: what changed, per machine' {
    It 'a v6 move: size, controller and accelerated networking changed; the disks did not' {
        $r = (IrRows (IrDoc 'web' 'MIGRATED' -Path 'A' -Size 'Standard_D2ds_v6'))[0]
        $r.name | Should -Be 'web'
        $r.size | Should -Be 'Standard_D2s_v4 to Standard_D2ds_v6'
        $r.controller | Should -Be 'SCSI to NVMe'
        $r.acceleratedNetworking | Should -Be 'On for the primary network interface'
        $r.PSObject.Properties.Name | Should -Not -Contain 'machine' -Because 'no move deletes the machine resource (OLD-REBUILD-RESTORE-READERS-1)'
        $r.disks | Should -Be 'No change'
    }

    It 'REVIEW: a machine with ONE network interface - which ARM does not mark primary - is read, not "Not recorded"' {
        (IrRows (IrDoc 'one' 'MIGRATED' -Primary $false))[0].acceleratedNetworking | Should -Be 'On for the primary network interface'
    }

    It 'REVIEW: a v5 move names no controller change - never "to SCSI" from nothing' {
        $doc = IrDoc 'db' 'MIGRATED' -Size 'Standard_D2s_v5' -Controller '' -AnBefore $true
        $doc.captured.vmConfig.controller = ''
        (IrRows $doc)[0].controller | Should -Be 'No change'
        $doc2 = IrDoc 'db2' 'MIGRATED' -Size 'Standard_D2s_v5' -Controller 'SCSI' -AnBefore $true
        $doc2.captured.vmConfig.PSObject.Properties.Remove('controller')
        (IrRows $doc2)[0].controller | Should -Be 'No change' -Because 'an unrecorded controller on a Generation 1 machine is SCSI'
        (IrRows $doc)[0].acceleratedNetworking | Should -Be 'No change' -Because 'it was on already'
    }


    It 'a fact the product did not record says so - never a guess' {
        (IrRows (IrDoc 'old' 'MIGRATED' -AnBefore $null))[0].acceleratedNetworking | Should -Be 'Not recorded'
    }

    It 'a rollback goes back to the size the machine had: no size change (RETIRE-SCOPE-1; vm-state v47 has no rollback.sizeAfter)' {
        $plain = IrAdd (IrDoc 'app' 'FAILED_ROLLED_BACK' -Path 'A') 'rollback' ([pscustomobject]@{ rolledBackUtc = 'x'; path = 'A'; osDisk = $null; dataDisks = @() })
        (IrRows $plain)[0].size | Should -Be 'No change'
    }

    It 'REVIEW: a rollback names the disks the rollback RECORDED making' {
        $doc = IrAdd (IrDoc 'app' 'FAILED_ROLLED_BACK' -Path 'A') 'rollback' ([pscustomobject]@{ rolledBackUtc = 'x'; path = 'A'
                osDisk = [pscustomobject]@{ id = '/s/rg/disks/app-os-asitwas'; name = 'app-os-asitwas' }
                dataDisks = @([pscustomobject]@{ lun = 0; diskId = '/s/rg/disks/app-d0-asitwas'; diskName = 'app-d0-asitwas' }) })
        $doc.captured.PSObject.Properties.Remove('startedTarget')
        $r = (IrRows $doc)[0]
        $r.size | Should -Be 'No change'
        $r.controller | Should -Be 'No change'
        $r.acceleratedNetworking | Should -Be 'No change'
        $r.disks | Should -Be 'New OS disk: app-os-asitwas; New data disk on LUN 0: app-d0-asitwas'
    }

    It 'PREP-ROLLBACK-1 (review F6): a machine put back by its disks before the move names its new disks' {
        $doc = IrAdd (IrDoc 'prep' 'FAILED_ROLLED_BACK' -Path 'A') 'rollback' ([pscustomobject]@{ rolledBackUtc = 'x'; path = 'disks'
                osDisk = [pscustomobject]@{ id = '/s/rg/disks/prep-os-asitwas'; name = 'prep-os-asitwas' }; dataDisks = @() })
        $doc.history = @([pscustomobject]@{ state = 'GUEST_PREP'; outcome = 'ok' }, [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; outcome = 'fail' })
        $r = (IrRows $doc)[0]
        $r.disks | Should -Be 'New OS disk: prep-os-asitwas'
    }

    It 'REVIEW: a rollback with no copy on record made no disk, and says none' {
        $doc = IrAdd (IrDoc 'nc' 'FAILED_ROLLED_BACK') 'rollback' ([pscustomobject]@{ rolledBackUtc = 'x'; path = 'A'; osDisk = $null; dataDisks = @() })
        (IrRows $doc)[0].disks | Should -Be 'No change'
    }

    It 'REVIEW: a machine that rolled back and then migrated runs on the disks the rollback made' {
        $doc = IrAdd (IrDoc 'again' 'MIGRATED') 'rollback' ([pscustomobject]@{ rolledBackUtc = 'x'; path = 'A'
                osDisk = [pscustomobject]@{ id = '/s/rg/disks/again-os-asitwas'; name = 'again-os-asitwas' }; dataDisks = @() })
        (IrRows $doc)[0].disks | Should -Be 'New OS disk: again-os-asitwas'
    }

    It 'a restore from the first copy: the size it ended on, and the new OS disk by name; the second copy keeps the move' {
        $first = IrAdd (IrDoc 'api' 'MIGRATED') 'restore' ([pscustomobject]@{ fromCopy = 'pristine'; sizeAfter = 'Standard_D2s_v4'; newDiskName = 'api-os-restored'; diskIdChanged = $true })
        $r = (IrRows $first)[0]
        $r.size | Should -Be 'No change'
        $r.controller | Should -Be 'No change'
        $r.acceleratedNetworking | Should -Be 'No change'
        $r.disks | Should -Be 'New OS disk: api-os-restored'
        $second = IrAdd (IrDoc 'api2' 'MIGRATED') 'restore' ([pscustomobject]@{ fromCopy = 'prepared'; sizeAfter = 'Standard_D2s_v6'; newDiskName = 'api2-os'; diskIdChanged = $false })
        $r2 = (IrRows $second)[0]
        $r2.size | Should -Be 'Standard_D2s_v4 to Standard_D2s_v6'
        $r2.disks | Should -Be 'New OS disk, with the same name: api2-os'
    }

    It 'FINISH-COUNT-1: a data disk swap a restore left changes no row - the machine keeps the size and controller the restore gave it' {
        # Get-VmfMachineOutcome counts such a machine as waiting for a person;
        # the table says where it runs, which the swap left does not change.
        $mk = { param($n) IrAdd (IrDoc $n 'MIGRATED' -Path 'A') 'restore' ([pscustomobject]@{ fromCopy = 'prepared'; sizeAfter = 'Standard_D2s_v6'; newDiskName = "$n-os"; diskIdChanged = $false }) }
        $plain = (IrRows (& $mk 'sw'))[0]
        $left = (IrRows (IrAdd (& $mk 'sw') 'swapPending' ([pscustomobject]@{ kept = @(); kind = 'restore'; swaps = @([pscustomobject]@{ lun = 0 }); swapped = @() })))[0]
        $plain.controller | Should -Be 'SCSI to NVMe' -Because 'the case reads the move'
        foreach ($k in 'size', 'controller', 'acceleratedNetworking', 'disks') { $left.$k | Should -Be $plain.$k -Because "the swap left does not change $k" }
    }

    It 'the size a restore RECORDED it ended on wins over what the copy implies' {
        $doc = IrAdd (IrDoc 'odd' 'MIGRATED') 'restore' ([pscustomobject]@{ fromCopy = 'prepared'; sizeAfter = 'Standard_D2s_v4'; newDiskName = 'odd-os'; diskIdChanged = $true })
        (IrRows $doc)[0].size | Should -Be 'No change'
    }

    It 'REVIEW: disks changed to Premium SSD by the move are named; one set back, or replaced by a copy, is not' {
        $doc = IrAdd (IrDoc 'prem' 'MIGRATED') 'diskTypeChanges' @(
            [pscustomobject]@{ diskId = '/s/rg/disks/prem-os'; from = 'StandardSSD_LRS'; to = 'Premium_LRS'; by = 'move'; utc = 'x' }
            [pscustomobject]@{ diskId = '/s/rg/disks/prem-d0'; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move'; utc = 'x' }
            [pscustomobject]@{ diskId = '/s/rg/disks/prem-d0'; from = 'Premium_LRS'; to = 'Standard_LRS'; by = 'restore'; utc = 'x' })
        (IrRows $doc)[0].disks | Should -Be 'prem-os: Standard SSD to Premium SSD'
        $rolled = IrAdd (IrAdd (IrDoc 'prb' 'FAILED_ROLLED_BACK') 'diskTypeChanges' @(
                [pscustomobject]@{ diskId = '/s/rg/disks/prb-os'; from = 'StandardSSD_LRS'; to = 'Premium_LRS'; by = 'move'; utc = 'x' })) 'rollback' ([pscustomobject]@{
                rolledBackUtc = 'x'; path = 'B'; osDisk = [pscustomobject]@{ id = '/s/rg/disks/prb-os-asitwas'; name = 'prb-os-asitwas' }; dataDisks = @() })
        (IrRows $rolled)[0].disks | Should -Be 'New OS disk: prb-os-asitwas' -Because 'the Premium SSD disk is no longer the machine''s'
    }

    It 'only machines the product changed' {
        $rows = IrRows @((IrDoc 'a' 'PLANNED'), (IrDoc 'b' 'NEEDS_DECISION'), (IrDoc 'c' 'SKIPPED'), (IrDoc 'd' 'MIGRATED'))
        @($rows.name) | Should -Be @('d')
    }
}

Describe 'IAC-REPORT-1: the rollback records the disks it makes' {
    It 'the engine writes the record next to the retry-state clear, and the schema holds it' {
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        # The last one: the rollback's own (Complete-VmfRollback and the start-only
        # path clear it too, earlier in the file).
        $clear = $sm.LastIndexOf("Clear-VmfRetryState -RunPath `$Context.RunPath -VmId `$Context.VmId -From 'PRECHECK'")
        # PREP-ROLLBACK-1: the final write is Set-VmfRollbackRecord -Done (the record is
        # also written after each swap, before this).
        # SAFETY-ULTRA-1: with the data disks it did not put back (keptDataDisks).
        $write = $sm.LastIndexOf('Set-VmfRollbackRecord -Context $Context -Path $recordPath -OsDisk $madeOs -DataDisks $madeData -KeptDataDisks @($keptList) -Done')
        $clear | Should -BeGreaterThan 0
        # PREP-ROLLBACK-1 (review 2, finding 5): the record and the checkpoint's 'done'
        # are written right after the last Azure call, BEFORE the retry state is
        # cleared - which re-reads the document, so the record stays.
        $write | Should -BeGreaterThan 0
        $write | Should -BeLessThan $clear
        # The version the store writes now, so a later version does not break this.
        $doc = [ordered]@{ schemaVersion = (& (Get-Module VmMigrationFactory) { $script:VmfStateDocSchemaVersion }); runId = 'r'; vmId = 'v'; state = 'FAILED_ROLLED_BACK'; history = @()
            rollback = [ordered]@{ rolledBackUtc = '2026-09-29T00:00:00Z'; path = 'A'; osDisk = [ordered]@{ id = '/d'; name = 'd' }
                dataDisks = @([ordered]@{ lun = 0; diskId = '/d0'; diskName = 'd0' }) } }
        ($doc | ConvertTo-Json -Depth 10) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') | Should -BeTrue
    }
}

Describe 'IAC-REPORT-1: in the customer''s report' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-iac-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'state') -Force | Out-Null
        @{ schemaVersion = 9; kind = 'migration'; runId = 'r1'; createdUtc = '2026-11-01T09:00:00Z' } | ConvertTo-Json | Set-Content (Join-Path $script:rp 'run.json')
        @{ schemaVersion = 1; assessmentRunId = 'r1'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/<img src=x>web'; wave = 'w1'; path = 'B'; assessment = @{ sourceSize = 'Standard_D2s_v4'; location = 'centralus'; iacManaged = $false }
                   target = @{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; planNotes = @() }) } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json')
        Complete-VmfTestCapture (IrDoc '<img src=x>web' 'MIGRATED' -Path 'B' -Size 'Standard_D2ds_v6') | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'state' 'web.json')
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE DEFECT: a machine nobody marked as defined in code still gets its row' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $table = [regex]::Match($html, '(?s)Changes to match in your infrastructure code.*?</table>').Value
        $table | Should -Match 'Standard_D2s_v4 to Standard_D2ds_v6'
        $table | Should -Not -Match 'Deleted and created again|Machine resource'
    }

    It 'every cell of the table is encoded' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $table = [regex]::Match($html, '(?s)Changes to match in your infrastructure code.*?</table>').Value
        $table | Should -Match '<tr><td>&lt;img src=x&gt;web</td>'
        $table | Should -Not -Match '<img src=x>'
    }

    It 'nothing reads the iacManaged mark any more, and the machine list has no code column' {
        $src = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfReport.ps1')
        $src | Should -Not -Match 'iacManaged'
        $src | Should -Not -Match '<th>IaC</th>'
    }
}
