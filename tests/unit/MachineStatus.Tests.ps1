#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
STATUS-WORDS-1: what a machine is now.

The run page's status rule (VmfHelp.machineStatus) and its end results are held
to tests/fixtures/machine-status.json. The end result of every case is what the
service counts too: Get-VmfMachineOutcome must give the same outcome for the
same state document, or the Reports page and the Migrations page disagree.

Found on a lab install: after a restore that worked, a machine that had needed
attention still said "Needs attention" in its row, in the tile, and in the
report's list of failures. A restore as new as the stop ends the stop - the
rule the panel's stop box, the decision gate and Leave this machine out already
use for the same records (currentStop, Get-VmfDecisionWaiting,
Get-VmfSkipMachineState).
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'machine-status.json') -Raw |
        ConvertFrom-Json).cases
}

Describe 'Get-VmfMachineOutcome, held to the status fixture' {
    It 'gives every case the outcome the run page gives' {
        @($script:cases).Count | Should -BeGreaterOrEqual 25 -Because 'the fixture loaded'
        foreach ($c in $script:cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { Get-VmfMachineOutcome -StateDoc $d }
            $got | Should -Be $c.outcome -Because "$($c.name): $($c.why)"
        }
    }

    It 'reads the times of a hashtable as text the same way' {
        # The facade gets hashtables (BODY-HASH-1), and their times stay text.
        InModuleScope VmMigrationFactory {
            $stop = @{ tsUtc = '2026-11-04T17:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'rollbackFailed' }
            Get-VmfMachineOutcome -StateDoc @{ state = 'FAILED_NEEDS_ATTENTION'; history = @($stop); restore = @{ restoredUtc = '2026-11-04T18:00:00Z' } } |
                Should -Be 'putBack'
            Get-VmfMachineOutcome -StateDoc @{ state = 'FAILED_NEEDS_ATTENTION'; history = @($stop); restore = @{ restoredUtc = '2026-11-04T16:00:00Z' } } |
                Should -Be 'attention'
            Get-VmfMachineOutcome -StateDoc @{ state = 'NEEDS_DECISION'; history = @(@{ tsUtc = '2026-11-04T17:00:00Z'; state = 'NEEDS_DECISION' }); restore = @{ restoredUtc = '2026-11-04T17:00:00Z' } } |
                Should -Be 'putBack' -Because 'as new as the stop is enough, as in Get-VmfSkipMachineState'
            Get-VmfMachineOutcome -StateDoc @{ state = 'FAILED_ROLLED_BACK'; history = @(@{ tsUtc = '2026-11-04T17:00:00Z'; state = 'FAILED_ROLLED_BACK' }); restore = @{ restoredUtc = $null } } |
                Should -Be 'rolledBack' -Because 'a restore with no time is not a yes'
        }
    }

    It 'keeps a migrated machine with a restore record of no readable time as restored' {
        # COUNT-TRUTH-1's cases write restoredUtc = 'x': a restore record on a
        # migrated machine was always a put-back, and still is unless a newer
        # step shows the machine moved again.
        InModuleScope VmMigrationFactory {
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; restore = @{ restoredUtc = 'x' }; history = @(@{ tsUtc = '2026-11-04T17:00:00Z'; state = 'MIGRATED' }) } |
                Should -Be 'putBack'
        }
    }

    It 'gives the report the size the restore gave, for a stop that a restore ended' {
        # Get-VmfRecordOutcome and the size it runs on now both read the move
        # outcome, so the report's row and its size agree.
        InModuleScope VmMigrationFactory {
            $doc = @{ state = 'FAILED_NEEDS_ATTENTION'
                history = @(@{ tsUtc = '2026-11-04T17:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackFailed' })
                restore = @{ restoredUtc = '2026-11-04T18:00:00Z'; sizeAfter = 'Standard_D2s_v4' } }
            Get-VmfMachineMoveOutcome -StateDoc $doc | Should -Be 'putBack'
            Get-VmfRecordOutcome -StateDoc $doc -Entry @{ path = 'A' } | Should -Be 'putBack'
        }
    }
}
