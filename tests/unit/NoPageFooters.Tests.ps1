#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FOOT-1 - a page footer is not where you tell somebody something.
#
# Jargon was still present in page footers, such as 'Read-only. Nothing on
# this page changes anything.' and 'Every action is made as you, recorded,
# and auditable - technical logs remain available to engineers in the run
# store'. A footer is not the right place to give the customer information.
#
# Every one of those was a REASSURANCE written by an engineer to nobody in
# particular, parked in the strip of the page a person reads last, if ever.
#
# The test that killed them: if a fact matters, it belongs where the decision
# is made; if it does not, it should not be on the page. None survived it, and
# the two that carried real rules were already saying them where they count -
# "those machines always travel in the same wave" sits on the machine, and
# "Waves you changed need to be approved again" appears when you save.
#
# The page header already says what each page is for, which is the honest place
# for "what am I looking at".
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
}

Describe 'FOOT-1: no page has a footer' {

    It 'found the pages, or this file is checking nothing' {
        @($script:pages).Count | Should -BeGreaterThan 5
    }

    It 'no page renders a footer strip' {
        $with = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match '<p class="foot"' -or $text -match "(?m)^\s*foot:\s*'") { $p.Name }
        }
        $with -join ', ' | Should -BeNullOrEmpty -Because 'the footer was where information went to be ignored'
    }

    It 'and the style it used is gone with it' {
        # A rule nothing uses is a rule somebody re-uses later, which is how the
        # footer would come back one page at a time.
        $with = foreach ($p in $script:pages) {
            if (((Get-VmfPageSource -Path $p.FullName)) -match '(?m)^\s*\.foot\{') { $p.Name }
        }
        $with -join ', ' | Should -BeNullOrEmpty
    }

    It 'the facts those footers carried are still said where they matter' {
        # Removing text is only right if nothing true was lost. Both rules the
        # footers carried are stated at the point of the action.
        $waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Match 'always travel in the same wave' -Because 'said on the machine that is in a set'
        # WAVE-APPROVE-1: the line now names the waves that changed, which are
        # the only ones whose approval goes ("needs an approval again").
        $waves | Should -Match 'needs an approval again' -Because 'said when a changed wave is saved'

        $wizard = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $wizard | Should -Match '(?i)only reads' -Because 'said at the step where somebody starts'
    }

    It 'every page still says what it is, in its header' {
        # The footer is gone; the answer to "what am I looking at" must not be.
        foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -notmatch 'UX-STRINGS-BEGIN') { continue }
            $text | Should -Match "(?m)^\s*\w*(Title|Hint|hint|title)\s*:" -Because "$($p.Name) must introduce itself somewhere a person reads"
        }
    }
}
