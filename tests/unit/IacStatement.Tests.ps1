#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# IAC-WORDS-1: the statement a person accepts before a run is true for every
# move, and it is one statement.
#
# It said "Migrating a machine changes its size, its disk controller and its
# disk identities." A move to v5 keeps the SCSI disk controller, and a move
# keeps the machine's disks: only a rollback or a restore puts it on new disks.
# What a move DOES change that a definition in code holds - accelerated
# networking, turned on for the primary network interface - it did not say.
#
# And it was four copies: the engine's Get-VmfIacStatement, which said it was
# "defined ONCE", the wizard, the run page, and the engine's refusal - with two
# wordings between them. The engine's is the one a person's acceptance
# records, so the pages are held to it here.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:statement = InModuleScope VmMigrationFactory { Get-VmfIacStatement }
    # IAC-NOTE-LIST-1: the lead ends with a colon, and the list follows it.
    $script:sentences = @($script:statement -split '(?<=[.:])\s+' | Where-Object { $_ })
    # IAC-NOTE-LIST-1: each page shows the note as a lead, a list of changes
    # and a closing line. What a person reads, joined, is the statement the
    # engine records with the acceptance.
    $page = {
        param($file, $prefix)
        $src = Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' $file)
        $one = { param($key) $m = [regex]::Match($src, "$key\s*:\s*'([^']*)'"); if (-not $m.Success) { throw "$file has no $key" }; $m.Groups[1].Value }
        $list = [regex]::Match($src, "$($prefix)Changes\s*:\s*\[([^\]]*)\]")
        if (-not $list.Success) { throw "$file has no $($prefix)Changes" }
        $changes = @([regex]::Matches($list.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
        [pscustomobject]@{
            Changes = $changes
            Text    = ((@(& $one "$($prefix)Lead") + $changes + @(& $one "$($prefix)After")) -join ' ')
        }
    }
    $script:wizardNote = & $page 'wizard.html' 'iac'
    $script:runPageNote = & $page 'migrations.html' 'ack'
    $script:wizard = $script:wizardNote.Text
    $script:runPage = $script:runPageNote.Text
}

Describe 'IAC-WORDS-1: what the statement says is true for every move' {
    It 'the disk controller changes only for v6 and v7, and the sentence says so' {
        $controller = @($script:sentences | Where-Object { $_ -match 'disk controller' })
        $controller.Count | Should -BeGreaterThan 0
        foreach ($s in $controller) {
            $s | Should -Match 'v6 or v7' -Because 'a move to v5 keeps the SCSI disk controller'
            $s | Should -Not -Match 'v5'
        }
    }

    It 'new disks come from a rollback or a restore, never from every move' {
        $disks = @($script:sentences | Where-Object { $_ -match 'new disks|disk identit' })
        $disks.Count | Should -BeGreaterThan 0
        foreach ($s in $disks) {
            $s | Should -Match '^A rollback or a restore puts the machine on new disks' -Because 'only those make new disks'
        }
        $script:statement | Should -Not -Match 'disk identities'
    }

    # LAB-UX-1: the statement said a restore made a new operating system disk.
    # RESTORE-ALL-1 made a restore replace every disk and let it keep the disk
    # names; RESTORE-PB-1 made a restore from the first copy rebuild a machine
    # the move rebuilt. A definition in code sees each of those.
    # REBUILD-REMOVE-RECOVER-1: no restore rebuilds a machine now, so the
    # statement says none does.
    It 'a restore is not limited to the operating system disk, can keep the names, and never rebuilds' {
        $script:statement | Should -Not -Match 'new operating system disk'
        $script:statement | Should -Match 'A restore can keep the disk names\.'
        $script:statement | Should -Not -Match '(?i)rebuild'
    }

    It 'it names accelerated networking, which a move can change' {
        $script:statement | Should -Match 'A move can change accelerated networking\.'
    }

    It 'OLD-SKU-1C and HDD-OS-1: it names the disk type, which a move can change to Standard SSD or Premium SSD' {
        $script:statement | Should -Match 'A move can change the disk type to Standard SSD or Premium SSD\.'
    }

    # REBUILD-REMOVE-RECOVER-1: no move rebuilds a machine, so the sentences of
    # a rebuild and of its new identity are gone; the next apply can still
    # replace the machine.
    It 'it says the next apply can replace the machine, and no longer that a move rebuilds it' {
        @($script:sentences | Where-Object { $_ -match '^A rebuild' }).Count | Should -Be 0
        $script:statement | Should -Match 'or replace the machine'
    }

    It 'every sentence is at most 25 words (ASD-STE100, descriptive)' {
        foreach ($s in $script:sentences) { @($s -split '\s+' | Where-Object { $_ }).Count | Should -BeLessOrEqual 25 -Because $s }
    }
}

Describe 'IAC-WORDS-1: one statement, everywhere it is shown' {
    It 'the wizard shows the engine''s statement, word for word' {
        $script:wizard | Should -Be $script:statement
    }

    # IAC-NOTE-LIST-1, 2026-11-08: the note was one long run-on list of items,
    # and not easy to read. Each change the engine names is one item of
    # the list on each page, and nothing else is.
    It 'each page lists the five changes, one item each' {
        foreach ($note in $script:wizardNote, $script:runPageNote) {
            $note.Changes.Count | Should -Be 5
            $note.Changes[0] | Should -Be 'The size of the machine changes.'
            $note.Changes[4] | Should -Match '^A rollback or a restore puts the machine on new disks'
        }
        ($script:wizardNote.Changes -join '|') | Should -Be ($script:runPageNote.Changes -join '|')
    }

    It 'the run page shows the engine''s statement, word for word' {
        $script:runPage | Should -Be $script:statement
    }

    # GATE-WORDS-1 replaces the fourth copy. The refusal repeated the whole
    # statement, ten sentences, before it said what to do - and since
    # RETRY-GATE-1 it fills the Try this machine again dialog. The statement
    # is shown, word for word, by the dialog the refusal's button opens; the
    # refusal names that button and does not repeat it.
    It 'the engine''s refusal before a run starts names the button, and leaves the statement to the dialog it opens' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-iac-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $gate = InModuleScope VmMigrationFactory -Parameters @{ p = $rp } {
                param($p) Initialize-VmfRun -RunPath $p -RunId 'iac' -Kind 'migration' | Out-Null
                Test-VmfRunAcknowledged -RunPath $p
            }
            $gate.Pass | Should -BeFalse
            $gate.Code | Should -Be 'notAcknowledged'
            foreach ($s in $script:sentences) { $gate.Detail.Contains($s) | Should -BeFalse -Because "the dialog says '$s'" }
            $button = [regex]::Match(((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))), "ackBtn\s*:\s*'([^']*)'").Groups[1].Value
            $button | Should -Not -BeNullOrEmpty
            $gate.Detail | Should -Match ("select " + [regex]::Escape($button))
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'the manual quotes it, and its Finish page names the same changes' {
        # IAC-NOTE-LIST-1: the manual shows the note as the page does - the
        # lead, one list line for each change, then the closing line.
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
        $lead = [regex]::Match((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')), "iacLead\s*:\s*'([^']*)'").Groups[1].Value
        $after = [regex]::Match((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')), "iacAfter\s*:\s*'([^']*)'").Groups[1].Value
        $manual | Should -Match ([regex]::Escape($lead))
        foreach ($c in $script:wizardNote.Changes) { $manual | Should -Match ('(?m)^(> )?- ' + [regex]::Escape($c) + '\s*$') }
        $manual | Should -Match ([regex]::Escape($after))
        $manual | Should -Not -Match 'Migrating a machine changes its size'
        $finish = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'finish.md') -Raw
        $finish | Should -Match 'disk controller for a move to v6 or v7'
        $finish | Should -Match 'a rollback or a restore swapped'
        # OLD-REBUILD-RESTORE-READERS-1: no sentence for a machine an earlier version rebuilt.
        $finish | Should -Not -Match 'without its extensions'
    }

    It 'the stored-record sample and the command''s help carry the current words, not the old ones' {
        (Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'run-acknowledgement.sample.json') -Raw | ConvertFrom-Json).statement | Should -Be $script:statement
        (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Confirm-VmfRunAcknowledgement.ps1') -Raw) | Should -Not -Match 'disk identities'
    }
}
