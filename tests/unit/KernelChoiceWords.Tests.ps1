#Requires -Modules Pester
# KERNEL-CHOICE-WORDS-1 (approved words, 2026-11-14): the kernel choice
# says what the product does IF Checking finds the kernel below the minimum.
# The old words ("Update the kernel. This was chosen on ...") read as a
# finding on a machine that then passed Checking.
#
# tests/js/kernel-choice.test.js holds the page words exactly and RUNS the
# notice. This file holds the manual to the same words: each quote in the
# manual is the page's own string, read from the page source, so a change to
# one side alone fails here.

BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    function Get-KcwPageString([string]$File, [string]$Key) {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repo $File))
        $m = [regex]::Match($text, "(?m)^\s*$([regex]::Escape($Key)):\s*'([^']*)',")
        if (-not $m.Success) { throw "no string $Key in $File" }
        $m.Groups[1].Value
    }
    function Get-KcwManual([string]$Page) {
        [System.IO.File]::ReadAllText((Join-Path $script:repo "docs/manual/$Page"))
    }
}

Describe 'KERNEL-CHOICE-WORDS-1: the kernel choice is said as a condition' {
    It 'WAVE-KERNEL-LINE-1: the line of each machine went with the wave kernel setting, and the manual quotes the row that replaced it' {
        $help = [System.IO.File]::ReadAllText((Join-Path $script:repo 'src/dashboard/help.js'))
        $help | Should -Not -Match '(?m)^\s*ownRowKernel:'
        $row = Get-KcwPageString 'src/dashboard/waves.js' 'kernelLabel'
        $row | Should -Be 'Machines whose kernel the product updates if it has no MANA driver'
        $manual = Get-KcwManual 'use/wave-settings.md'
        $manual | Should -Match ([regex]::Escape("**$row**"))
        $manual | Should -Not -Match 'the product updates the kernel\. Chosen on the Choose each target step'
    }

    It 'the targets step notice says the product reads the kernel at Checking, and the manual quotes it' {
        $alert = Get-KcwPageString 'src/dashboard/wizard.js' 'tKernelAlert'
        $alert | Should -Be 'The product reads the kernel of each Linux machine at Checking. Choose what it does if the kernel has no MANA driver for the new size.'
        (Get-KcwManual 'use/plan.md') | Should -Match ([regex]::Escape("**$alert**"))
    }

    It 'the wave editor row that names these machines says the update as a condition' {
        (Get-KcwPageString 'src/dashboard/waves.js' 'kernelLabel') | Should -BeLike '*updates if it has no MANA driver'
    }
}
