#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AVSET-NOTE-MANUAL-1 - the manual did not say what the availability set notes
# mean.
#
# At Checking, a machine that shares an availability set gets a line in the
# activity from Get-VmfAvailabilitySetNote (AVSET-NOTE-1), and a machine whose
# set Azure did not give the other machines of gets one from
# Get-VmfAvailabilitySetUnknownNote (MISSING-READ-2). No page of the manual
# described either. The page that explains Checking now quotes each line the
# engine can write, says which lines the activity marks as a note, and quotes
# Microsoft's resize page for the rule behind them.
#
# This file holds the page to the code, not to a copy of it:
#   - each note is MADE by the engine's own function, with the example values
#     the page states, and must appear word for word in the page;
#   - the row that quotes it says "marked note" exactly when the engine writes
#     it as a warning - the word is read from the dashboard (warnNote), which
#     is what puts it on the activity line;
#   - every quote of Microsoft in the section must be in the PINNED text of the
#     resize page (docs/upstream-docs, the drift baseline). A re-pin after
#     Microsoft changes the page then fails here until the page is read again.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $pagePath = Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'how-a-machine-moves.md'
    $page = [System.IO.File]::ReadAllText($pagePath)
    $s = [regex]::Match($page, '(?ms)^## A machine in an availability set\s*$(.*?)(?=^## |^<!-- next:begin)')
    $script:section = if ($s.Success) { $s.Groups[1].Value } else { $null }

    $pinned = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'resize-vm.md'
    $script:pinnedText = [System.IO.File]::ReadAllText($pinned)

    $js = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js'))
    $m = [regex]::Match($js, "(?m)^\s*warnNote:\s*'([^']+)'")
    $script:warnWord = if ($m.Success) { $m.Groups[1].Value } else { $null }

    # The example the page states, so the quoted lines can be made by the code.
    $script:example = @{ Others = 1; Names = 'vm-app-02'; Running = 1; Target = 'Standard_D4ds_v6'; Other = 'Standard_D4ds_v5' }

    function Global:Get-AvsetManualCase {
        param([string]$Case)
        $x = $script:example
        & (Get-Module VmMigrationFactory) {
            param($Case, $x)
            switch ($Case) {
                'offered' { Get-VmfAvailabilitySetNote -Others $x.Others -Names $x.Names -Running $x.Running -TargetSize $x.Target -OfferedSizes @($x.Target, $x.Other) }
                'notOffered' { Get-VmfAvailabilitySetNote -Others $x.Others -Names $x.Names -Running $x.Running -TargetSize $x.Target -OfferedSizes @($x.Other) }
                # AVSET-NOT-OFFERED-STOP-1: the stop, with the sentence the
                # engine adds to it (Invoke-VmfStepPrecheck).
                'notOfferedRunning' {
                    $n = Get-VmfAvailabilitySetNote -Others $x.Others -Names $x.Names -Running $x.Running -DefinitelyRunning $x.Running -TargetSize $x.Target -OfferedSizes @($x.Other)
                    [pscustomobject]@{ Outcome = $n.Outcome; Detail = "$($n.Detail) Nothing on the machine changed." }
                }
                'sizesUnknown' { Get-VmfAvailabilitySetNote -Others $x.Others -Names $x.Names -Running $x.Running -TargetSize $x.Target -OfferedSizes $null }
                'membersUnknownOffered' { Get-VmfAvailabilitySetUnknownNote -TargetSize $x.Target -OfferedSizes @($x.Target) }
                'membersUnknown' { Get-VmfAvailabilitySetUnknownNote -TargetSize $x.Target -OfferedSizes $null }
            }
        } $Case $x
    }

    # The table row of the section that holds a text, or $null.
    function Global:Get-AvsetManualRow {
        param([string]$Text)
        @(($script:section -split "`n") | Where-Object { $_.StartsWith('|') -and $_.Contains($Text) }) | Select-Object -First 1
    }
}

AfterAll {
    Remove-Item Function:\Get-AvsetManualCase, Function:\Get-AvsetManualRow -ErrorAction SilentlyContinue
}

Describe 'AVSET-NOTE-MANUAL-1: the manual explains the availability set notes of Checking' {

    It 'has a section for a machine in an availability set on the page that explains Checking' {
        $script:section | Should -Not -BeNullOrEmpty
    }

    It 'states the example values that the quoted lines use' {
        $script:section | Should -Match ([regex]::Escape($script:example.Names))
        $script:section | Should -Match ([regex]::Escape($script:example.Target))
    }

    It 'reads the word the activity puts on a warning line from the dashboard' {
        $script:warnWord | Should -Not -BeNullOrEmpty
    }

    It 'quotes the <case> line word for word, in a row of its own' -ForEach @(
        @{ case = 'offered' }, @{ case = 'notOffered' }, @{ case = 'notOfferedRunning' }, @{ case = 'sizesUnknown' },
        @{ case = 'membersUnknownOffered' }, @{ case = 'membersUnknown' }
    ) {
        $note = Get-AvsetManualCase -Case $case
        $note.Detail | Should -Not -BeNullOrEmpty
        Get-AvsetManualRow -Text $note.Detail | Should -Not -BeNullOrEmpty -Because "the manual must quote what the engine writes: $($note.Detail)"
    }

    It 'marks the <case> row as a note exactly when the engine writes it as a warning' -ForEach @(
        @{ case = 'offered' }, @{ case = 'notOffered' }, @{ case = 'notOfferedRunning' }, @{ case = 'sizesUnknown' },
        @{ case = 'membersUnknownOffered' }, @{ case = 'membersUnknown' }
    ) {
        $note = Get-AvsetManualCase -Case $case
        $row = Get-AvsetManualRow -Text $note.Detail
        $row | Should -Not -BeNullOrEmpty
        $marked = $row.Contains("Marked **$($script:warnWord)**")
        $marked | Should -Be ($note.Outcome -eq 'warn') -Because "the engine writes this line as '$($note.Outcome)'"
        if ($note.Outcome -eq 'info') { $row | Should -Match 'Not marked' }
        # AVSET-NOT-OFFERED-STOP-1: a stop says the machine stops, and names
        # the stop by its title in the stop list.
        $stops = $row.Contains('stops the machine at **Checking**')
        $stops | Should -Be ($note.Outcome -eq 'stop') -Because "the engine gives this case as '$($note.Outcome)'"
        if ($note.Outcome -eq 'stop') {
            $title = (@((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons) |
                Where-Object code -EQ 'availabilitySetSizeNotOffered').title
            $row | Should -Match ([regex]::Escape("**$title**"))
        }
    }

    It 'quotes Microsoft, and every quote is in the pinned text of the resize page' {
        $quotes = @([regex]::Matches($script:section, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $quotes.Count | Should -BeGreaterThan 0
        foreach ($q in $quotes) {
            $script:pinnedText.Contains($q) | Should -BeTrue -Because "the quote must be in the pinned resize page: $q"
        }
    }

    It 'names the resize page it quotes, as Microsoft titles it' {
        $script:pinnedText | Should -Match '^# Resize a virtual machine'
        $script:section | Should -Match 'Resize a virtual machine'
    }
}
