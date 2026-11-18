#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-4: the engine reads no state document shape that
# only an earlier version wrote (vm-state v47).
#
# Since 2026-11-11: nobody has an earlier version - nothing is public before 1.0,
# so no store holds a state document an earlier version wrote. Each reader went
# with proof that this version always writes what it read:
#   - captured.original (v16): PRECHECK writes it with the first capture
#     (New-VmfOriginalCaptureRecord, Save-VmfCapturedFacts), in the same write.
#   - capacityReservationGroupId (v24) and patchSettings (v31): Get-VmfVmCapture
#     writes both keys on every capture, null for none.
#   - each disk's encryption (v21): PRECHECK records it on every disk or stops
#     the machine untouched (Add-VmfDiskEncryptionFacts, diskEncryptionNotKnown).
#   - swapPending.operationId (v32): a restore always has a checkpoint with an
#     operation id, and its swap record and its own record carry it.
#   - rollback.sizeAfter (v17): no writer since RETIRE-SCOPE-1.
#
# These fallbacks sat on rollback and restore paths, so none of them turns into
# "nothing to put back": a record that lacks what a 1.0 record always holds
# stops the put-back with a clear line, before anything changes.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
    $script:schema = [System.IO.File]::ReadAllText($script:schemaFile) | ConvertFrom-Json -AsHashtable -Depth 60
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    function Global:Ovr4Capture([string]$Size = 'Standard_D2s_v4', [switch]$NoGroup) {
        $c = [ordered]@{
            vmId = $script:vmId; name = 'vm1'; location = 'centralus'; size = $Size; controller = 'SCSI'
            osDisk = [ordered]@{ name = 'vm1-os'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; skuName = 'Premium_LRS'; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null }
            dataDisks = @(); nics = @(); zones = @(); patchSettings = $null
        }
        if (-not $NoGroup) { $c.capacityReservationGroupId = $null }
        [pscustomobject]$c | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    }
    function Global:Ovr4Doc($Captured, [object[]]$History = @()) {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = $script:vmId; state = 'CONVERTING'; history = @($History); captured = $Captured }
    }
    function Global:Ovr4Valid([string]$Json) {
        try { Test-Json -Json $Json -SchemaFile $script:schemaFile -ErrorAction Stop } catch { $false }
    }
    $script:touched = @([pscustomobject]@{ state = 'SAFETY_PRISTINE'; tsUtc = '2026-11-12T00:00:00Z' })
}
AfterAll { Remove-Item 'function:\Ovr4Capture', 'function:\Ovr4Doc', 'function:\Ovr4Valid' -ErrorAction SilentlyContinue }

Describe 'OLD-VERSION-READERS-REMOVE-4: the first capture (captured.original) is always on record' {
    It 'Get-VmfOriginalCapture gives only the first capture, never this attempt''s capture in its place' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture) })
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfOriginalCapture -Doc $d } | Should -BeNullOrEmpty
    }

    It 'a put-back capture of a record with no first capture stops with a clear sentence, never this attempt''s capture' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture 'Standard_D2s_v6') })
        { InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPutBackCapture -Doc $d } } |
            Should -Throw 'The record of this machine holds no first capture, so the product does not change the machine.'
    }

    It 'a first capture that does not say its capacity reservation group stops the put-back, never "in no group"' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture 'Standard_D2s_v6'); original = [pscustomobject]@{ vmConfig = (Ovr4Capture -NoGroup) } })
        { InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPutBackCapture -Doc $d } } |
            Should -Throw 'The first capture of this machine does not say its capacity reservation group, so the product does not change the machine.'
    }

    It 'a full record gives the shape from the first capture' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture 'Standard_D2s_v6'); original = [pscustomobject]@{ vmConfig = (Ovr4Capture) } })
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPutBackCapture -Doc $d }).size | Should -Be 'Standard_D2s_v4'
    }

    It 'PRECHECK never takes a capture of a touched machine as its first capture' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture) }) -History $script:touched
        { InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Ovr4Capture 'Standard_D2s_v6') } { param($d, $c) New-VmfOriginalCaptureRecord -Doc $d -Capture $c } } |
            Should -Throw '*holds no first capture*does not start this attempt*'
    }

    It 'PRECHECK takes this capture as the first while the product never touched the machine' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture) })
        $rec = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Ovr4Capture 'Standard_D2s_v6') } { param($d, $c) New-VmfOriginalCaptureRecord -Doc $d -Capture $c }
        $rec.vmConfig.size | Should -Be 'Standard_D2s_v6'
    }

    It 'a rollback of a record with no first capture says why in the run history and asks Azure for nothing' {
        $doc = Ovr4Doc ([pscustomobject]@{ vmConfig = (Ovr4Capture 'Standard_D2s_v6') })
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } {
            param($d)
            $script:ovr4Lines = [System.Collections.Generic.List[object]]::new()
            Mock Read-VmfStateDoc { $d }
            Mock Write-VmfStepLine { $script:ovr4Lines.Add([pscustomobject]@{ Outcome = $Outcome; Detail = $Detail }) }
            Mock Invoke-VmfAzOperation { throw 'no Azure call is expected' }
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-ovr4-nowrite'); VmId = $d.vmId; Rg = 'rg-app'; VmName = 'vm1'; RunId = 'r1'; Plan = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v6' } } }
            { Invoke-VmfRollback -Context $ctx } | Should -Throw '*holds no first capture*'
            Should -Invoke Invoke-VmfAzOperation -Times 0 -Exactly
            @($script:ovr4Lines | Where-Object { $_.Outcome -eq 'fail' -and $_.Detail -like 'The record of this machine holds no first capture, so the product does not change the machine.' }).Count | Should -Be 1
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: the capacity reservation group a put-back returns to is always known' {
    It 'a put-back plan for a capture that does not say its group stops, and leaves no group in silence' {
        InModuleScope VmMigrationFactory {
            { Get-VmfReservationPutBackPlan -CurrentGroupId '/g/ours' -Captured @{ Known = $false; GroupId = $null } -ProductGroupIds @('/g/ours') } |
                Should -Throw 'The record of this machine does not say its capacity reservation group, so the product does not change the machine.'
        }
    }

    It 'a capture that says no group: the put-back leaves the group the move left it in' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfReservationPutBackPlan -CurrentGroupId '/g/ours' -Captured @{ Known = $true; GroupId = $null } -ProductGroupIds @('/g/ours')
            $p.Leave | Should -BeTrue
            @($p.Words).Count | Should -Be 0
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: a disk made from a copy always has its encryption on record' {
    It 'an OS disk whose encryption is not on record is not made, and the sentence names the copy and the disk' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfAzOperation { throw 'no Azure call is expected' }
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-ovr4-nowrite'); VmId = '/v'; Rg = 'rg' }
            { New-VmfOsDiskFromCopy -Context $ctx -OpName 'rollback:osDisk' -ResourceGroupName 'rg' -DiskName 'vm1-os-asitwas' -SnapshotId '/s/p' -Location 'centralus' -Disk ([pscustomobject]@{ name = 'vm1-os' }) } |
                Should -Throw "The encryption of the disk that the copy '/s/p' was taken of is not on record, so the product did not make the disk 'vm1-os-asitwas'."
            Should -Invoke Invoke-VmfAzOperation -Times 0 -Exactly
        }
    }

    It 'a data disk whose encryption is not on record is not made, and the old disk stays' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfAzOperation { throw 'no Azure call is expected' }
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-ovr4-nowrite'); VmId = '/v'; Rg = 'rg' }
            $row = [pscustomobject]@{ lun = 1; snapshotId = '/s/d1'; skuName = 'Premium_LRS'; encryption = $null }
            $r = New-VmfDataDiskFromCopy -Context $ctx -Row $row -DiskName 'vm1-d1-asitwas' -ResourceGroupName 'rg' -Location 'centralus' -OpName 'rollback:dataDisk'
            $r.Id | Should -BeNullOrEmpty
            $r.Why | Should -Be "The encryption of the disk that the copy '/s/d1' was taken of is not on record, so the product did not make the disk 'vm1-d1-asitwas'."
            Should -Invoke Invoke-VmfAzOperation -Times 0 -Exactly
        }
    }

    It 'a made disk with no encryption on record to compare with is refused, never used without a compare' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfAzOperation { throw 'no Azure call is expected' }
            Mock Write-VmfStepLine { }
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-ovr4-nowrite'); VmId = '/v'; Rg = 'rg' }
            Confirm-VmfMadeDiskEncryption -Context $ctx -OpName 'rollback:osDisk' -DiskId '/d/new' -DiskName 'vm1-os-asitwas' -Want $null |
                Should -Be "The encryption of the disk that 'vm1-os-asitwas' replaces is not on record, so the product does not use 'vm1-os-asitwas'."
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: the words name no earlier version' {
    It 'no rollback disks on record is said plainly - the rollback still makes its own' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ schemaVersion = 47; safety = [pscustomobject]@{ pristineSnapshotId = '/s/p' } }
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-ovr4-nowrite'); VmId = '/v'; Rg = 'rg' }
            (Get-VmfRollbackDisksBeforeMoveSet -Context $ctx -Doc $doc -Shape 'full' -FromSnapshotId '/s/p').Why | Should -Be 'No rollback disks are on record for this safety copy.'
        }
    }

    It 'a Premium SSD v2 disk with no IOPS on record is left as it is, and the words do not name an earlier move' {
        InModuleScope VmMigrationFactory {
            $why = Get-VmfInstantAccessRestoreRefusal -FirstType 'PremiumV2_LRS' -AttemptType 'PremiumV2_LRS' -Facts ([pscustomobject]@{}) -SnapshotId '/s/d1' -CopyReadiness @{}
            $why | Should -BeLike 'Its disk type is *, and its IOPS, throughput, sector size are not on record. Its copy is ''/s/d1''.'
            $why | Should -Not -Match 'started before'
        }
    }

    It 'no engine file says a record is from an earlier version in an operator sentence' {
        foreach ($rel in @('Private/engine/ReservationPutBack.ps1', 'Private/engine/DiskEncryption.ps1', 'Private/engine/SafetyAllDisks.ps1', 'Private/engine/RollbackDisksBeforeMove.ps1', 'Private/validate/RebuildSettings.ps1')) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $rel)
            $code | Should -Not -Match 'older than the record|move started before|from before the move does not hold|before the product (made|recorded)' -Because $rel
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: a restore''s swap record is matched by its operation only' {
    It 'a restore record and a swap record that name no operation are not taken as this restore''s' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ restore = [pscustomobject]@{ restoredUtc = 'x' }; swapPending = [pscustomobject]@{ kind = 'restore'; swaps = @() } }
            Get-VmfSwapRestoreRecord -Doc $doc | Should -BeNullOrEmpty
        }
    }

    It 'a swap record that names no operation takes no checkpoint, so Finish says the record is missing' {
        InModuleScope VmMigrationFactory {
            $job = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; ended = [pscustomobject]@{ utc = 'x' } }
            $doc = [pscustomobject]@{ putBackJob = $job; swapPending = [pscustomobject]@{ kind = 'restore'; swaps = @() } }
            Get-VmfSwapRestoreJob -Doc $doc | Should -BeNullOrEmpty
            Test-VmfFinishWritesRestoreRecord -Doc $doc | Should -BeFalse
        }
    }

    It 'the same operation on both records is this restore''s record' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ restore = [pscustomobject]@{ operationId = 'op-1' }; swapPending = [pscustomobject]@{ kind = 'restore'; operationId = 'op-1'; swaps = @() } }
            (Get-VmfSwapRestoreRecord -Doc $doc).operationId | Should -Be 'op-1'
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: Verifying always compares the settings of the machine' {
    It 'a capture with no patch settings field fails the compare, never UNKNOWN' {
        InModuleScope VmMigrationFactory {
            $r = Test-VmfRebuildSettingsFidelity -Captured ([pscustomobject]@{ name = 'vm1' }) -Live ([pscustomobject]@{})
            $r.Ok | Should -BeFalse
            $r.Verdict | Should -Be 'MISMATCH'
            $r.Detail | Should -Be 'the record of the machine before the move does not hold its patch, Spot, boot diagnostics, encryption at host, disk and network interface settings, so the product cannot compare them'
        }
    }

    It 'no capture fails the compare too' {
        InModuleScope VmMigrationFactory { (Test-VmfRebuildSettingsFidelity -Captured $null -Live $null).Ok | Should -BeFalse }
    }

    It 'Verifying has no UNKNOWN verdict to warn about' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Not -Match "settingsCheck\.Verdict -in @\('UNKNOWN'"
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'RebuildSettings.ps1') | Should -Not -Match "'UNKNOWN'"
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: rollback.sizeAfter is gone' {
    It 'the infrastructure-as-code report does not read it: a rollback is to the size the machine had' {
        InModuleScope VmMigrationFactory -Parameters @{ v = $script:vmId; cap = (Ovr4Capture) } {
            param($v, $cap)
            $doc = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); vmId = $v; state = 'FAILED_ROLLED_BACK'; history = @()
                captured = [pscustomobject]@{ vmConfig = $cap; original = [pscustomobject]@{ vmConfig = $cap } }
                rollback = [pscustomobject]@{ rolledBackUtc = '2026-11-12T00:00:00Z'; path = 'A'; sizeAfter = 'Standard_D2ds_v5'; osDisk = $null; dataDisks = @() } }
            $rows = @(Get-VmfIacChangeRows -StateDocs @($doc))
            $rows[0].size | Should -Be 'No change'
        }
    }

    It 'no engine or page code reads rollback.sizeAfter' {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'report' 'IacChanges.ps1') | Should -Not -Match 'rollback\s*''sizeAfter''|rollback\.sizeAfter'
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js') | Should -Not -Match 'rollback\??\.sizeAfter'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4: vm-state v47 holds what a 1.0 record always holds' {
    It 'the contract, the engine and the sample are version 47' {
        $script:schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion } | Should -Be 51
        $sample = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json'))
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 51
        Ovr4Valid $sample | Should -BeTrue
    }

    It 'a rollback record has no sizeAfter' {
        $script:schema.properties.rollback.properties.ContainsKey('sizeAfter') | Should -BeFalse
        Ovr4Valid '{"schemaVersion":51,"runId":"r","vmId":"v","state":"FAILED_ROLLED_BACK","history":[],"rollback":{"rolledBackUtc":"2026-11-12T00:00:00Z","path":"A","sizeAfter":"Standard_D2ds_v5","osDisk":null,"dataDisks":[]}}' | Should -BeFalse
    }

    It 'a capture of this attempt needs the first capture beside it' {
        $cap = '{"capacityReservationGroupId":null,"patchSettings":null}'
        Ovr4Valid ('{"schemaVersion":51,"runId":"r","vmId":"v","state":"PRECHECK","history":[],"captured":{"vmConfig":' + $cap + '}}') | Should -BeFalse
        Ovr4Valid ('{"schemaVersion":51,"runId":"r","vmId":"v","state":"PRECHECK","history":[],"captured":{"vmConfig":' + $cap + ',"original":null}}') | Should -BeFalse
        Ovr4Valid ('{"schemaVersion":51,"runId":"r","vmId":"v","state":"PRECHECK","history":[],"captured":{"vmConfig":' + $cap + ',"original":{"vmConfig":' + $cap + '}}}') | Should -BeTrue
    }

    It 'every capture says its capacity reservation group and its patch settings' {
        foreach ($missing in 'capacityReservationGroupId', 'patchSettings') {
            $h = [ordered]@{ capacityReservationGroupId = $null; patchSettings = $null }
            $h.Remove($missing)
            $cap = $h | ConvertTo-Json -Compress
            $full = '{"capacityReservationGroupId":null,"patchSettings":null}'
            Ovr4Valid ('{"schemaVersion":51,"runId":"r","vmId":"v","state":"PRECHECK","history":[],"captured":{"vmConfig":' + $cap + ',"original":{"vmConfig":' + $full + '}}}') | Should -BeFalse -Because "vmConfig without $missing"
            Ovr4Valid ('{"schemaVersion":51,"runId":"r","vmId":"v","state":"PRECHECK","history":[],"captured":{"vmConfig":' + $full + ',"original":{"vmConfig":' + $cap + '}}}') | Should -BeFalse -Because "original.vmConfig without $missing"
        }
    }

    It 'the migration note names v47' {
        [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'schema-migrations.md')) | Should -Match 'vm-state v46 -> v47'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-4 review: one record the product cannot read never stops a report for every machine' {
    BeforeAll {
        function Global:Ovr4ReportDocs {
            $good = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/good"; state = 'MIGRATED'; history = @()
                captured = [pscustomobject]@{ vmConfig = (Ovr4Capture); original = [pscustomobject]@{ vmConfig = (Ovr4Capture) }
                    startedTarget = [pscustomobject]@{ path = 'A'; size = 'Standard_D2s_v6'; controller = 'NVMe' } } }
            $bad = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/bad"; state = 'MIGRATED'; history = @()
                captured = [pscustomobject]@{ vmConfig = (Ovr4Capture)
                    startedTarget = [pscustomobject]@{ path = 'A'; size = 'Standard_D2s_v6'; controller = 'NVMe' } } }
            @($bad, $good)
        }
    }
    AfterAll { Remove-Item 'function:\Ovr4ReportDocs' -ErrorAction SilentlyContinue }

    It 'the infrastructure-as-code report shows that machine as not recorded, and every other machine as it is' {
        $rows = InModuleScope VmMigrationFactory -Parameters @{ d = @(Ovr4ReportDocs) } { param($d) @(Get-VmfIacChangeRows -StateDocs $d) }
        $rows.Count | Should -Be 2
        $bad = $rows | Where-Object name -EQ 'bad'
        $bad.size | Should -Be 'Not recorded'
        $bad.controller | Should -Be 'Not recorded'
        $bad.disks | Should -Be 'Not recorded'
        ($rows | Where-Object name -EQ 'good').size | Should -Be 'Standard_D2s_v4 to Standard_D2s_v6'
    }

    It 'the migration record leaves only that machine''s size before empty - never the plan''s size in its place' {
        $docs = @(Ovr4ReportDocs)
        $plan = [pscustomobject]@{ entries = @(foreach ($d in $docs) { [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $d.vmId; wave = 'w1'; path = 'A'
                    assessment = [pscustomobject]@{ sourceSize = 'Standard_E2s_v3' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' } } }) }
        $record = InModuleScope VmMigrationFactory -Parameters @{ d = $docs; p = $plan } {
            param($d, $p) ConvertTo-VmfMigrationRecord -Manifest ([pscustomobject]@{ runId = 'r1' }) -Plan $p -StateDocs $d -GeneratedBy 'operator@example.com' -Reason 'downloaded' }
        @($record.machines).Count | Should -Be 2
        (@($record.machines) | Where-Object { $_.vmId -like '*/bad' }).before.size | Should -BeNullOrEmpty
        (@($record.machines) | Where-Object { $_.vmId -like '*/good' }).before.size | Should -Be 'Standard_D2s_v4'
    }
}
