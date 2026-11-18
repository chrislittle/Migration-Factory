#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NAMES-WRAP-1: a machine's name is never cut to "vm-...", and a wave's header
# never runs past its card.
#
# The owner, testing the Waves page: the list of machines to add showed
# "vm-..." for every machine in an availability set. The row gave its tags and
# buttons a fixed column, and "moves with its pair" plus Change target took
# almost all of the 340px list. On the Migrations page a wave's labels - who
# accepted, who signed off, the schedule - were each one line that never broke.
#
# Measured in the page (demo data, 2026-09-28): after the fix no name in the
# list is cut, the narrowest has 259px, and a header with three long labels at
# 1000px wide does not overflow. These checks hold the rules that made that so.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:css = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'app.css')
    $script:waves = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html')
    $script:migrations = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
    $script:rule = { param($selector)
        $m = [regex]::Match($script:css, '(?m)^' + [regex]::Escape($selector) + '\s*\{([^}]*)\}')
        $m.Groups[1].Value }
}

Describe 'NAMES-WRAP-1: the machine list' {
    It 'the row wraps, so the tags and buttons move under the name instead of squeezing it' {
        & $script:rule '.p-waves .m' | Should -Match 'flex-wrap:\s*wrap'
        & $script:rule '.p-waves .m' | Should -Not -Match 'grid-template-columns'
    }

    It 'the name keeps a width of its own before anything shares its line' {
        & $script:rule '.p-waves .m .who' | Should -Match 'flex:\s*1 1 180px'
    }

    It 'the tags and buttons are one group the row can move' {
        $script:waves | Should -Match '<span class="acts">'
        & $script:rule '.p-waves .m .acts' | Should -Match 'flex-wrap:\s*wrap'
    }

    It 'the name has a colour of its own, not the top bar''s pale one' {
        # The page-wide .who is the signed-in user in the dark top bar. It
        # reached these rows, and in the light theme every name was pale text
        # on a white card - found in the manual's own screenshot.
        & $script:rule '.who' | Should -Match 'color:\s*var\(--on-nav-dim\)' -Because 'this is the rule the row must override'
        & $script:rule '.p-waves .m .who' | Should -Match 'color:\s*var\(--ink\)'
    }

    It 'the whole name is on hover when it is still too long' {
        $script:waves | Should -Match '<span class="nm" title="\$\{esc\(vmName\(e\.vmId\)\)\}">'
    }
}

Describe 'NAMES-WRAP-1: a wave''s header' {
    It 'the wave cards, and the found-machines card of the same shape, are the ones these rules reach' {
        ([regex]::Matches($script:migrations, '<div class="card wrap-head">')).Count | Should -Be 2
    }

    It 'the labels break onto more lines, and the progress bar moves under them' {
        & $script:rule '.p-migrations .wrap-head .ch' | Should -Match 'flex-wrap:\s*wrap'
        & $script:rule '.p-migrations .wrap-head .ch h2' | Should -Match 'flex-wrap:\s*wrap'
        & $script:rule '.p-migrations .wrap-head .ch h2' | Should -Match 'min-width:\s*0'
        & $script:rule '.p-migrations .wrap-head .ch h2 .pill' | Should -Match 'white-space:\s*normal'
    }
}
