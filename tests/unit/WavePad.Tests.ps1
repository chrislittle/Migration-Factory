#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-PAD-1: the wave's collapsed line and its Hide machines line sit in line
# with the machines table.
#
# A card has no padding of its own - its header and its table cells do. The two
# lines WAVE-TOGGLE-1 made sat on the card's edge, so "6 machines" touched the
# rounded border and Hide machines stood left of every column above it.

BeforeAll {
    $script:css = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'app.css') -Raw
    # The side padding of a rule's `padding: <vertical> <side> ...` value.
    function Global:WpSide([string]$Selector) {
        $m = [regex]::Match($script:css, "(?m)^$([regex]::Escape($Selector))\s*\{[^}]*?padding:\s*([^;}]+)")
        if (-not $m.Success) { return $null }
        $parts = @($m.Groups[1].Value.Trim() -split '\s+')
        if ($parts.Count -ge 2) { $parts[1] } else { $parts[0] }
    }
}
AfterAll { Remove-Item function:WpSide -ErrorAction SilentlyContinue }

Describe 'WAVE-PAD-1: the wave lines line up with the machines table' {
    It 'found the table cells'' side padding' {
        WpSide 'th,td' | Should -Match '^\d+px$'
    }
    It 'the collapsed line has the same side padding as a table cell' {
        WpSide '.p-migrations .wave-collapsed' | Should -Be (WpSide 'th,td')
    }
    It 'the Hide machines line has the same side padding as a table cell' {
        WpSide '.p-migrations .wave-hide' | Should -Be (WpSide 'th,td')
    }
}
