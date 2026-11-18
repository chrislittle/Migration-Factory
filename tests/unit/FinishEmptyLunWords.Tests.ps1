#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FINISH-EMPTY-LUN-WORDS-1: the record of a swap that is left says what is on
# each LUN, so the Finish dialog says it too.
#
# The Finish dialog said for every row "On LUN n, the disk X is still
# attached". For a LUN with no disk, a LUN the product did not read, and a LUN
# that holds a third disk, that is false. The record now says which one it is
# (swapPending.swaps[].lunHolds, vm-state v38), set where the row is written.
#
# FINISH-TEMP-DISK-LEFT-1 (folded in): keeping the names, a row whose LUN runs
# on the temporary disk made from the copy (step 6 of keeping the names) says
# so (oldTemporary). Finish then records the disk under the old name as the
# disk the LUN had before the restore - as step 6 records it when it takes -
# so the temporary disk is not on the record as a disk the machine runs on,
# and the daily cleanup deletes it once the move has ended.
#
# The words the restore ends on say "after 3 tries" only for a swap Azure
# refused on every try (-Refused), never for a swap that threw or a LUN the
# restore did not swap.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'FINISH-EMPTY-LUN-WORDS-1: each row of a swap that is left says what is on its LUN' {
    It 'New-VmfSwapLeftRow -Holds <Holds>: the row says it' -ForEach @(
        @{ Holds = 'had' }, @{ Holds = 'none' }, @{ Holds = 'notRead' }, @{ Holds = 'other' }) {
        $row = InModuleScope VmMigrationFactory -Parameters @{ h = $Holds } {
            param($h)
            New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }) -OldDiskId '/d/d1' -Holds $h
        }
        $row.lunHolds | Should -Be $Holds
    }
    It 'with no -Holds the row says nothing about the LUN: null, never a guess' {
        $row = InModuleScope VmMigrationFactory { New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }) }
        $row.PSObject.Properties['lunHolds'] | Should -Not -BeNullOrEmpty -Because 'Set-VmfEmptyLunRow sets it on the same row'
        $row.lunHolds | Should -BeNullOrEmpty
        $row.oldTemporary | Should -BeFalse
    }
    It 'any other value is refused' {
        { InModuleScope VmMigrationFactory { New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }) -Holds 'kept' } } | Should -Throw
    }
    It 'FINISH-TEMP-DISK-LEFT-1: -OldTemporary says the disk on the LUN is the temporary disk made from the copy' {
        $row = InModuleScope VmMigrationFactory { New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1-tmp'; diskId = '/d/d1'; diskName = 'd1' }) -OldDiskId '/d/d1-tmp' -Holds 'had' -OldTemporary }
        $row.oldTemporary | Should -BeTrue
        $row.temporary | Should -BeFalse
    }
    It 'Set-VmfEmptyLunRow, <Outcome>: the LUN is said as <Holds>' -ForEach @(
        @{ Outcome = 'empty'; Holds = 'none' }, @{ Outcome = 'unproven'; Holds = 'none' }, @{ Outcome = 'fallback'; Holds = 'had' }) {
        $row = InModuleScope VmMigrationFactory -Parameters @{ o = $Outcome } {
            param($o)
            $r = New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }) -OldDiskId '/d/d1' -Holds 'notRead'
            Set-VmfEmptyLunRow -Row $r -Fill @{ Outcome = $o; Caching = 'ReadOnly' }
        }
        $row.lunHolds | Should -Be $Holds
    }
    # FINISH-ATTACH-UNKNOWN-WORDS-1: an attach that stopped with an error that
    # is not a refusal - which disk is on the LUN is not known.
    It 'Set-VmfEmptyLunRow, an attach with no answer: the LUN is said as notRead, and it keeps the caching for Finish' {
        $row = InModuleScope VmMigrationFactory {
            $r = New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }) -OldDiskId '/d/d1' -Holds 'none'
            Set-VmfEmptyLunRow -Row $r -Fill @{ Outcome = 'empty'; Unknown = $true; Caching = 'ReadOnly' }
        }
        $row.lunHolds | Should -Be 'notRead'
        $row.caching | Should -Be 'ReadOnly'
        $row.diskId | Should -Be '/d/x'
    }
}

Describe 'FINISH-EMPTY-LUN-WORDS-1: "after 3 tries" only for a swap Azure refused on every try' {
    It 'a refused row says after 3 tries; a row from a swap that threw, or one the restore did not swap, does not' {
        $rows = @(
            [pscustomobject]@{ lun = 0; name = 'd0'; diskName = 'd0-new'; why = 'OperationNotAllowed: in use' },
            [pscustomobject]@{ lun = 1; name = 'd1'; diskName = 'd1-new'; why = 'The data disk swap did not finish: the process stopped' })
        $w = InModuleScope VmMigrationFactory -Parameters @{ r = $rows } { param($r) Format-VmfRestoreSwapLeftWords -Swaps $r -Refused @(0) }
        $w | Should -Match "Azure did not swap these data disks back after 3 tries: LUN 0 keeps 'd0', not the disk 'd0-new' made from its copy\. Azure said: OperationNotAllowed: in use\."
        $w | Should -Match "These data disks are not back: LUN 1 keeps 'd1', not the disk 'd1-new' made from its copy\. The data disk swap did not finish: the process stopped\."
        $w | Should -Not -Match "after 3 tries: [^.]*LUN 1"
    }
    It 'no refused row: no "after 3 tries" at all' {
        $w = InModuleScope VmMigrationFactory { Format-VmfRestoreSwapLeftWords -Swaps @([pscustomobject]@{ lun = 0; name = 'd0'; diskName = 'd0-new'; why = 'The restore stopped at an earlier data disk swap.' }) -Refused @() }
        $w | Should -Not -Match 'after 3 tries'
        $w | Should -Match "These data disks are not back: LUN 0 keeps 'd0'"
    }
}

Describe 'FINISH-EMPTY-LUN-WORDS-1: the contract (rule 1)' {
    It 'vm-state v38 declares lunHolds and oldTemporary on each row of a swap that is left (required since v48); the sample validates; another value is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $item = $schema.properties.swapPending.properties.swaps.items
        @($item.properties.lunHolds.enum) | Should -Be @('had', 'none', 'notRead', 'other')
        $item.properties.oldTemporary.type | Should -Be 'boolean'
        @($item.required) | Should -Contain 'lunHolds' -Because 'every row a swap of this version leaves says it (v48)'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 51
        [string](($sample | ConvertFrom-Json).swapPending.swaps[0].lunHolds) | Should -Be 'had'
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $base = { param($r) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"swapPending":{"kind":"restore","leftUtc":"2026-11-06T00:00:00Z","error":"e","swaps":[' + $r + '],"swapped":[],"kept":[]}}' }
        $row = '{"lun":1,"name":"d1","diskId":"/d/x","diskName":"x","snapshotId":"/s/c"'
        foreach ($h in 'had', 'none', 'notRead', 'other') { Test-Json -Json (& $base ($row + ',"lunHolds":"' + $h + '"}')) -SchemaFile $schemaFile | Should -BeTrue }
        Test-Json -Json (& $base ($row + ',"lunHolds":null,"oldTemporary":true}')) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'v48: every row says what is on its LUN'
        Test-Json -Json (& $base ($row + '}')) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'v48: a row that says nothing about the LUN is refused'
        Test-Json -Json (& $base ($row + ',"lunHolds":"kept"}')) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v37 -> v38 \(2026-11-06, FINISH-EMPTY-LUN-WORDS-1\)'
    }
}
