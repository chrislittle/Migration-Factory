#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-DOCS-1 - the manual still said that a move can rebuild a
# machine.
#
# The owner removed the rebuild around the same disks (Path B) on 2026-11-07.
# Every move is the in-place upgrade, or the in-place upgrade (Preview), and
# no restore rebuilds a machine (REBUILD-REMOVE-PLAN-1, -ACCEPT-1, -ENGINE-1,
# -RECOVER-1, -ROLE-1). The manual still had a page that explained what a
# rebuild changes, a role that "may also stop, resize and rebuild the
# machines", a report that is written "when a machine is restored or rebuilt",
# and a no-warranty line in the README that says the product rebuilds
# virtual machines.
#
# What may still say "rebuild": a sentence about what an EARLIER VERSION did,
# because the product still shows such a plan, stop or record and says what to
# do with it; a sentence that says this version does NOT rebuild; and the
# Linux start-up image, which the product rebuilds in the guest (dracut,
# update-initramfs) - a different thing with the same verb.
#
# OLD-VERSION-READERS-REMOVE-1: reference/stop-reasons.md is read with every
# other page. Its two stops for a rebuild an earlier version planned or
# started are gone with the code that wrote them.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'

    # The sentences of a page: each line split at the end of a sentence. A
    # table row is one unit, so a status label such as Rebuilt is read with
    # the cell that says it is about an earlier version. A code name such as
    # recoveryDisks is a name, not a word an operator reads as a claim,
    # so camelCase names are taken out first. Code blocks are skipped.
    function Get-RebuildDocsSentences {
        param([string]$Text)
        $inCode = $false
        foreach ($line in ($Text -split "`n")) {
            if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
            if ($inCode) { continue }
            $plain = [regex]::Replace($line, '\b[a-z]+[A-Z][A-Za-z]*\b', '')
            $pieces = if ($plain.TrimStart().StartsWith('|')) { @($plain) } else { $plain -split '(?<=[.!?])\s+' }
            foreach ($piece in $pieces) {
                $t = $piece.Trim()
                if ($t) { $t }
            }
        }
    }
    $script:allowed = '(?i)earlier version|does not rebuild|not rebuild a machine|no (new )?(move|restore|plan) (is a rebuild|rebuilds)|no rebuild|start-up image'

    $script:pages = @(Get-ChildItem -Path $script:manual -Recurse -Filter '*.md' |
        Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' })
}

Describe 'REBUILD-REMOVE-DOCS-1: the manual says that every move is in place' {
    It 'has no page that explains the rebuild, and no link to one' {
        Test-Path (Join-Path $script:manual 'understand' 'in-place-or-rebuild.md') | Should -BeFalse
        $linking = @(Get-ChildItem -Path $script:manual -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' -and $_.Extension -in '.md', '.html', '.js', '.json' } |
            Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'in-place-or-rebuild' } |
            ForEach-Object { $_.FullName.Substring($script:manual.Length + 1) })
        $linking | Should -BeNullOrEmpty -Because 'the page is gone, so nothing may link to it'
        $dashboard = @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'dashboard') -File |
            Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'in-place-or-rebuild' } | ForEach-Object Name)
        $dashboard | Should -BeNullOrEmpty -Because 'a help link on a page must not open a page that is gone'
    }

    It 'says rebuild only about an earlier version, or to say that this version does not rebuild' {
        $script:pages.Count | Should -BeGreaterThan 40 -Because 'the manual has its pages'
        $found = foreach ($page in $script:pages) {
            foreach ($s in (Get-RebuildDocsSentences -Text ([System.IO.File]::ReadAllText($page.FullName)))) {
                if ($s -match '(?i)rebuil|recreat' -and $s -notmatch $script:allowed) {
                    '{0}: {1}' -f $page.FullName.Substring($script:manual.Length + 1), $s
                }
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'gives the Assess and migrate role as stop and resize, the rights it now holds' {
        foreach ($rel in @('understand/roles.md', 'use/admin.md', 'use/capacity.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:manual $rel))
            $text | Should -Not -Match '(?i)resize and rebuild' -Because "$rel names the rights of the role"
        }
        $roles = [System.IO.File]::ReadAllText((Join-Path $script:manual 'understand' 'roles.md'))
        $roles | Should -Match 'stop and resize the machines'
    }

    It 'has a README whose no-warranty line says what the product does now' {
        $readme = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'README.md'))
        $readme | Should -Not -Match '(?i)rebuilds virtual machines'
        $readme | Should -Match 'This product stops and resizes virtual machines\.'
    }
}
