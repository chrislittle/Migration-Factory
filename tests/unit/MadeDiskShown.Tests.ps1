#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MADE-DISK-SHOWN-1. A rollback, Restore this machine and Rebuild this machine
# record each managed disk they make from a safety copy (rollbackDisksDuringRollback,
# restoreDisks, recoveryDisks). A disk that nothing uses bills until the daily
# cleanup deletes it, once the move of the machine has ended - and the app did
# not list it anywhere. A machine that stays in FAILED_NEEDS_ATTENTION or
# NEEDS_DECISION kept such a disk with no end, and no card said so.
#
# The machine's panel now lists each one, with what happens next. The page
# cannot read Azure, so it says what the record says, by the rules of the
# engine. This file holds the page's rule (madeDiskRows, run in
# tests/js/made-disks-shown.test.js) to the engine, case by case, through
# tests/fixtures/made-disks-shown.json:
#   - the disks are exactly Get-VmfDeletableMadeDisks (the one rule of the
#     daily cleanup and the delete of a migration), in its order;
#   - a disk is 'due' exactly when Get-VmfDueMadeDisks lists it;
#   - restoreRuns, finishRuns and restoreStopped are Test-VmfPutBackJobHolds
#     (open or not, by Test-VmfPutBackJobOpen);
#   - 'waits' is a machine whose move has not ended and that nothing holds.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'made-disks-shown.json') -Raw | ConvertFrom-Json
}

Describe 'MADE-DISK-SHOWN-1: the shared fixture is the engine''s rule' {
    It 'has the cases the page is held to' {
        @($script:fixture.cases).Count | Should -BeGreaterThan 12
        foreach ($s in 'due', 'waits', 'restoreRuns', 'finishRuns', 'restoreStopped') {
            @($script:fixture.cases | ForEach-Object { @($_.disks) } | Where-Object { $_.status -eq $s }).Count | Should -BeGreaterThan 0 -Because "a case of status $s"
        }
    }

    It 'lists exactly the disks Get-VmfDeletableMadeDisks gives, in its order, for each case' {
        foreach ($case in $script:fixture.cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $case.doc } { param($d) @(Get-VmfDeletableMadeDisks -StateDoc $d) }
            $want = @($case.disks)
            @($got | ForEach-Object { "$($_.List)|$($_.diskId)" }) -join ';' | Should -Be (@($want | ForEach-Object { "$($_.list)|$($_.diskId)" }) -join ';') -Because $case.why
        }
    }

    It 'says due exactly where the daily cleanup deletes the disk' {
        foreach ($case in $script:fixture.cases) {
            $due = InModuleScope VmMigrationFactory -Parameters @{ d = $case.doc } { param($d) @(Get-VmfDueMadeDisks -StateDocs @($d)) }
            $dueIds = @($due | ForEach-Object { @($_.Disks) } | ForEach-Object { [string]$_.diskId })
            foreach ($disk in @($case.disks)) {
                ([string]$disk.diskId -in $dueIds) | Should -Be ($disk.status -eq 'due') -Because "$($case.why) ($($disk.status))"
            }
        }
    }

    It 'says a job keeps the disk exactly where Test-VmfPutBackJobHolds does, and waits only for a move that has not ended' {
        foreach ($case in $script:fixture.cases) {
            $facts = InModuleScope VmMigrationFactory -Parameters @{ d = $case.doc } {
                param($d)
                [pscustomobject]@{ Holds = (Test-VmfPutBackJobHolds -Doc $d); Open = (Test-VmfPutBackJobOpen -Doc $d); Ended = ([string]$d.state -in $script:VmfRollbackDisksBeforeMoveDueStates) }
            }
            foreach ($disk in @($case.disks)) {
                $isJob = $disk.status -in 'restoreRuns', 'finishRuns', 'restoreStopped'
                $facts.Holds | Should -Be $isJob -Because "$($case.why) ($($disk.status))"
                if ($disk.status -in 'restoreRuns', 'finishRuns') {
                    $facts.Open | Should -BeTrue -Because $case.why
                    ($disk.status -eq 'finishRuns') | Should -Be ([string]$case.doc.putBackJob.kind -eq 'finish') -Because $case.why
                }
                if ($disk.status -eq 'restoreStopped') { $facts.Open | Should -BeFalse -Because $case.why }
                if ($disk.status -eq 'waits') { $facts.Ended | Should -BeFalse -Because $case.why }
                if ($disk.status -eq 'due') { $facts.Ended | Should -BeTrue -Because $case.why }
            }
        }
    }
}

Describe 'MADE-DISK-SHOWN-1: the machine''s panel' {
    BeforeAll {
        $script:page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')
    }

    It 'draws the list of made disks in the panel, under the record of the restore' {
        $script:page | Should -Match ([regex]::Escape('const madeDisks = madeDisksHtml(doc, madeHelpOpen.has(vmId))'))
        $script:page | Should -Match '(?s)\$\{restoredNote\}\s*(\$\{originalDisks\}\s*)?\$\{madeDisks\}'   # ROLLBACK-ORIGINALS-LEFT-1: the original disks of a rollback sit between
    }

    It 'wires the (?) to open and close, and Escape closes it before the panel (rule 11)' {
        $script:page | Should -Match ([regex]::Escape("`$('#madehelp-btn')?.addEventListener('click', () => { toggleMadeHelp(vmId); });"))
        $script:page | Should -Match ([regex]::Escape("if (`$('#drill').classList.contains('open') && madeHelpOpen.has(drillVmId)) { toggleMadeHelp(drillVmId); return; }"))
        # The Escape line for the helper comes before the one that closes the panel.
        $script:page.IndexOf('madeHelpOpen.has(drillVmId)') | Should -BeLessThan $script:page.IndexOf("if (`$('#drill').classList.contains('open')) { closeDrill(); return; }")
    }

    It 'the box itself posts nothing: Delete these disks now goes in its slot, from the shared slide-out (MADE-DISK-DELETE-1)' {
        $fn = [regex]::Match($script:page, '(?s)function madeDisksHtml\(.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Not -Match '<button[^>]*delete'
        $fn | Should -Not -Match 'apiFetch'
        $fn | Should -Match '<span id="madedelete-slot"></span>'
        $script:page | Should -Match ([regex]::Escape("diskDeleteHtml('made', vmId, madeRows.length)"))
    }
}
