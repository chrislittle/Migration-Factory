#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# V7-UX-1 - a setting you can SEE and cannot SET.
#
# No screen offered a choice between v6 and v7 for a move from the old sizes.
#
# It was not missed - it was half built, which is worse. The chain was:
#
#   New-VmfPlan -TargetGeneration        exists, ValidateSet v6/v7, default v6
#   Get-VmfTargetSize uses it            yes
#   the plan records policy.targetGeneration   yes
#   the run page DISPLAYS it             yes - "v6 - the current generation"
#   docker/entrypoint.ps1 passes it      NO
#   the facade has a parameter for it    NO
#   any page offers a choice             NO
#
# So every migration run from the app planned v6, while the run page showed the
# generation as though somebody had chosen it. Reaching v7 meant calling
# New-VmfPlan from PowerShell - exactly what hard rule 10 forbids.
#
# The Reachability guard missed it because it checks whether COMMANDS are
# reachable from the app, not whether their OPTIONS are. The last Describe here
# closes that for the options that actually change what happens.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
    $script:core  = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:start = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Raw
    $script:wiz   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
    $script:plan  = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
}

Describe 'V7-UX-1: the choice reaches the planner' {
    It 'the engine passes what it is given' {
        $script:entry | Should -Match 'VMF_TARGET_GENERATION'
        $script:entry | Should -Match '\$planParams\.TargetGeneration = \$env:VMF_TARGET_GENERATION'
    }

    It 'the facade takes it and forwards it as an override' {
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match "\[ValidateSet\('v5', 'v6', 'v7'\)\]\[string\]\`$TargetGeneration"
        $fn | Should -Match "name = 'VMF_TARGET_GENERATION'"
    }

    It 'and VALIDATES it rather than trusting the request body' {
        # It becomes a size suffix. An unchecked value produces a target that
        # does not exist and a refusal nobody could explain.
        $fn = [regex]::Match($script:core, '(?ms)^function Invoke-VmfFacadeStartEngine \{(.*?)^\}').Groups[1].Value
        $fn | Should -Match "ValidateSet\('v5', 'v6', 'v7'\)"
    }

    It 'the handler binds it' {
        $script:start | Should -Match '\$body\.targetGeneration'
        $script:start | Should -Match '\$params\.TargetGeneration'
    }

    It 'and New-VmfPlan still defaults to v6 when nobody says' {
        # Opt-in, as ruled. A tool that silently moved everyone to
        # the Current default would be making the decision for them.
        $script:plan | Should -Match "\[ValidateSet\('v5', 'v6', 'v7'\)\]\[string\]\`$TargetGeneration = 'v6'"
    }
}

Describe 'V7-UX-1 / GEN-ONCE-1: a person can choose it, in ONE place' {
    # GEN-ONCE-1, 2026-09-25: the wizard asked v6 or v7 for the whole plan,
    # and the wave editor later let each wave change it - "is that duplication?"
    # It was: the same decision twice, and the first time before a single target
    # size was on screen. The choice now lives in the wave editor only, where it
    # shows what would change. The plan is built as v6.
    # WAVE-SERIES-GONE-1: ADVISOR-1 moved the choice to each machine, before
    # the waves, and the per-wave control that could replace them all is gone.
    It 'the wave editor no longer offers a series - it belongs to each machine' {
        $waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Not -Match 'data-gen='
        $waves | Should -Not -Match 'data-genapply='
    }

    It 'the wizard no longer asks it' {
        $script:wiz | Should -Not -Match 'name="tg"'
        $script:wiz | Should -Not -Match 'genTitle'
    }

    # ADVISOR-1 REVERSES GEN-ONCE-1 (2026-09-26): the series is not one
    # decision for the whole plan any more - it is chosen for EACH machine, in
    # the wizard's first migrate step, and saved. So the wizard must not name a
    # series when it plans, and the decision it records is the saved target of
    # each machine, not an absence. Same strength as the test it replaces.
    It 'and plans from the target saved for each machine, never one series for all' {
        # Code only, and ANY mention of the key: an object literal
        # ({ targetGeneration: 'v6' }) sends it as surely as an assignment.
        . (Join-Path $script:repoRoot 'tests' 'unit' '_CodeOnly.ps1')
        $build = [regex]::Match($script:wiz, '(?s)async function buildWaves\(\).*?\n\}').Value
        $build | Should -Not -BeNullOrEmpty
        (Get-VmfCodeOnly -Text $build -Language CStyle) | Should -Not -Match 'targetGeneration'
        $script:wiz | Should -Match 'assessments/\$\{runSeg\(\)\}/targets'
    }

    It 'and the run page still shows what was chosen' {
        # The display was never the problem - it was the only honest part. It
        # must keep working now that it reflects a real decision.
        $index = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        # GEN-V5-1: every series by name, v5 included.
        $index | Should -Match "v5: UX_LEVER\.genV5, v7: UX_LEVER\.genV7"
    }
}

Describe 'V7-UX-1: an option that changes the outcome must be reachable' {
    # The guard the Reachability test could not be. It checks COMMANDS; this
    # checks the OPTIONS of the one command that decides what a migration does.
    # Each of these changes the plan materially, so each needs a way in.
    It 'every plan-shaping parameter of New-VmfPlan can be set from the app' {
        $block = [regex]::Match($script:plan, '(?ms)^    param\((.*?)^    \)').Groups[1].Value
        $block | Should -Not -BeNullOrEmpty
        $declared = @([regex]::Matches($block, '(?m)\]\$(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        # Paths and identity are not choices a person makes on a form.
        $notChoices = 'AssessmentPath', 'OutPath', 'OnBehalfOf', 'RunId'
        $choices = @($declared | Where-Object { $_ -notin $notChoices })
        @($choices).Count | Should -BeGreaterThan 3 -Because 'the parameter block must actually have been read'

        # Reachable means the engine can be TOLD: it reads an env override the
        # facade sets. That is the only path the app has.
        $unreachable = @($choices | Where-Object {
            $n = [regex]::Escape($_)
            $script:entry -notmatch "\`$planParams\.$n\s*=" })
        ($unreachable -join ', ') | Should -BeNullOrEmpty -Because 'a parameter the engine never sets can only be reached by running PowerShell by hand, which hard rule 10 forbids'
    }
}
