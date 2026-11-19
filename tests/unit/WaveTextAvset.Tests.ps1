#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-TEXT-AVSET-1 - the grouping step named one wave-planning rule only.
#
# The wizard's step "How should they be grouped into waves?" said: "A wave is
# a batch that moves together. Machines in the same availability set always
# stay in one wave, whichever grouping you pick". The page states no other
# rule the planner applies, so naming only this one was out of balance. The
# ruling (2026-11-05): drop the availability set sentence and describe
# waves only.
#
# The rule stays in the planner, and it is still said where it applies: on the
# machine in the wave editor ("moves with its pair"), and in the manual, where
# each group - a tag value, a resource group or an availability set - becomes
# one wave (WAVE-SIZE-REMOVE-1 removed the size limit it was the exception to).
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dashDir = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:wizard = Get-VmfPageSource -Path (Join-Path $script:dashDir 'wizard.html')
    $script:waves = Get-VmfPageSource -Path (Join-Path $script:dashDir 'waves.html')
    $m = [regex]::Match($script:wizard, "(?m)^\s*s3Body:\s*'([^']*)'")
    $script:s3Body = if ($m.Success) { $m.Groups[1].Value } else { $null }

    # The manual's section for this step, from its heading to the next one.
    $plan = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md'))
    $s = [regex]::Match($plan, '(?ms)^## Step: how to group the machines into waves\s*$(.*?)(?=^## )')
    $script:section = if ($s.Success) { $s.Groups[1].Value } else { $null }
}

Describe 'WAVE-TEXT-AVSET-1: the grouping step describes waves, and no single rule' {

    It 'found the step text, or this file checks nothing' {
        $script:s3Body | Should -Not -BeNullOrEmpty
    }

    It 'says what a wave is' {
        $script:s3Body | Should -Match '(?i)\bwave is a group of machines that move together\b'
    }

    It 'says the waves can be changed after this step' {
        $script:s3Body | Should -Match '(?i)change the waves after this step'
    }

    It 'names no availability set' {
        $script:s3Body | Should -Not -Match '(?i)availability set' -Because 'the page states no other planning rule, so it states none'
    }

    It 'the rule is still said on the machine it applies to, in the wave editor' {
        $script:waves | Should -Match "avsetTip:\s*'[^']*availability set[^']*always travel in the same wave"
    }
}

Describe 'WAVE-TEXT-AVSET-1: the manual page for this step says the same' {

    It 'found the section, or this file checks nothing' {
        $script:section | Should -Not -BeNullOrEmpty
    }

    It 'opens with the same description of a wave as the step' {
        $first = ($script:section.Trim() -split '\r?\n')[0]
        $first | Should -Match '(?i)^A wave is a group of machines that move together\.'
        $first | Should -Not -Match '(?i)availability set'
    }

    It 'gives the availability set rule only in the paragraph that says each group is one wave' {
        # WAVE-SIZE-REMOVE-1 (2026-11-08): the size limit is gone, and
        # an availability set is no longer its exception. It is one of the
        # groups that each become one wave. No other paragraph names it.
        $paras = @($script:section -split '(\r?\n){2,}' | Where-Object { $_ -match '(?i)availability set' })
        $paras.Count | Should -Be 1
        $paras[0] | Should -Match '(?i)availability set becomes one wave, whatever its number of machines'
        $script:section | Should -Not -Match '(?i)Most machines in one wave' -Because 'the setting is removed'
    }
}
