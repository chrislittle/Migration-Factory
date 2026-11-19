#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PRICE-EXPORT-1 (issue 423): Export for pricing could never be used.
#
# The button on the Choose each target step was enabled only once every target
# was saved - and Save moved the person straight on to grouping, so nobody ever
# saw it enabled. Now one press saves (the same save as Save, the same version
# check) and downloads, and the person stays on the step. The Run it step offers
# the export too, with the wave of each machine, from the plan the page holds.
#
# The BEHAVIOUR is run in tests/js/pricing-export.test.js and
# tests/js/run-step.test.js. This file holds the rules about the page's shape,
# read from its CODE with the comments removed - so a comment that names a
# function can never satisfy a check that it is called (COMMENT-TRAP-1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:wizard = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html') -Language CStyle

    # The text of one top-level function of the page: from its declaration to
    # the next declaration at the start of a line.
    function Script:FunctionText([string]$Name) {
        $at = $script:wizard.IndexOf("function $Name(")
        if ($at -lt 0) { return '' }
        $next = [regex]::Match($script:wizard.Substring($at + 10), '(?m)^(async function|function|const|let) ')
        if (-not $next.Success) { return $script:wizard.Substring($at) }
        return $script:wizard.Substring($at, $next.Index + 10)
    }
}

Describe 'PRICE-EXPORT-1: one CSV builder, reached from both steps' {

    It 'the page builds the file in one place: pricingCsv is called once, inside exportPricing' {
        @([regex]::Matches($script:wizard, 'pricingCsv\(')).Count | Should -Be 2 -Because 'its declaration and one call'
        FunctionText 'exportPricing' | Should -Match 'pricingCsv\('
    }

    It 'the targets step wires its button to the one-press export, and never draws it turned off' {
        $render = FunctionText 'renderTargets'
        $render | Should -Match ([regex]::Escape("`$('#t-export').addEventListener('click', exportTargets)"))
        $render | Should -Match 'id="t-export">'
        $render | Should -Not -Match 'id="t-export"\$\{'
    }

    It 'the one-press export uses THE save - no second request to the targets endpoint' {
        @([regex]::Matches($script:wizard, 'assessments/\$\{runSeg\(\)\}/targets')).Count | Should -Be 1
        FunctionText 'saveTargets' | Should -Match 'assessments/\$\{runSeg\(\)\}/targets'
        FunctionText 'exportTargets' | Should -Match 'saveTargets\(true\)'
    }

    It 'the Run it step wires its button to the plan export, which goes through the same function' {
        FunctionText 'renderStep5' | Should -Match ([regex]::Escape("`$('#r-export').addEventListener('click', exportPlan)"))
        FunctionText 'exportPlan' | Should -Match ([regex]::Escape('exportPricing(planPricing(plan, assessment?.vms, vmName))'))
    }

    It 'Escape closes an open (?) on the Run it step too (rule 11)' {
        # The journey too: step 4 of the assess journey is its review.
        $script:wizard | Should -Match ([regex]::Escape("e.key === 'Escape' && journey === 'migrate' && step === STEP.migrate.run && tHelp.size) { tHelp.clear(); render(); }"))
    }

    It 'both steps draw the (?) with the one helper, and wire it with the one handler' {
        FunctionText 'renderTargets' | Should -Match 'helpWire\(\)'
        FunctionText 'renderStep5' | Should -Match 'helpWire\(\)'
        FunctionText 'renderStep5' | Should -Match ([regex]::Escape("tHelpBtn('run-export', UX.tExportAbout)"))
    }
}
