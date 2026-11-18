#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCALE-UX-1 - "How many machines at once" says what it means, how long the
# wave will take, and sizes the engine.
#
# Found 2026-09-03: nothing in the UX said how to scale up more workers, or
# how many machines in a wave can run at the same time. And 2026-09-04: there
# was no simple factor a user chooses, such as machines at once per wave.
#
# The number IS the factor. It sizes the engine's container (facade), and the
# screen shows the sentence, the ceiling and a live estimate. THREE NUMBERS
# appear in three places - the engine's estimate, the facade's cap and the
# screen's constants - and this file holds them to each other.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
    $script:migrations = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    $script:wizard = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
    $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:planner = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1') -Raw
}

Describe 'SCALE-UX-1: one set of numbers, held together' {

    It 'the screen shows no wave time in words, and the engine keeps its own estimate' {
        # MANUAL-REVIEW-1 (2026-11-13): no wave-time figure on a page.
        # The engine's estimate stays, for the change window (Test-VmfWaveWindow).
        $script:planner | Should -Match '\[double\]\$SafetyFactor = 1\.25'
        $script:help | Should -Not -Match 'WAVE_MINUTES_PER_MACHINE|WAVE_SAFETY_FACTOR'
        $script:help | Should -Match 'function waveEstimate\(machines, workers, T\) \{'
    }

    It 'the screen cap and the facade cap are the same number' {
        $script:help | Should -Match 'const WAVE_MAX_WORKERS = 60;'
        $script:core | Should -Match 'if \(\$Workers -gt 60\)'
        $script:core | Should -Match "'400: at most 60 machines at once"
        # The per-container table keeps its own ceiling of 15; the wave's is 60.
        $script:core | Should -Match "'400: at most 15 machines at once"
        # MACHINES-AT-ONCE-RANGE-1: the largest of the four choices is the cap.
        $script:help | Should -Match "\{ id: 'maximum', machines: 60 \}" -Because 'the choices name the same ceiling'
    }
}

Describe 'SCALE-UX-1: the number sizes the engine, everywhere a wave starts' {

    It 'a wave start is sized from the worker count; other operations keep the job size' {
        # SCALE-2: the number is split over containers first; each container is sized from its share.
        $script:core | Should -Match "\`$split = if \(\`$Operation -eq 'wave'\) \{ Get-VmfFacadeWaveContainers -Workers \`$Throttle"
        $script:core | Should -Match '\$sized = Get-VmfFacadeEngineResources -Workers \$share'
        $script:core | Should -Match 'resources = \$s\.resources'
    }

    It 'a schedule is checked when it is made' {
        $sched = [regex]::Match($script:core, '(?s)function Invoke-VmfFacadeSchedule.*?\n\}').Value
        $sched | Should -Match 'Get-VmfFacadeWaveContainers -Workers \$Throttle \| Out-Null'
        $sched.IndexOf('Get-VmfFacadeWaveContainers') | Should -BeLessThan $sched.IndexOf('Set-VmfWaveSchedule @params')
    }

    It 'a resumed wave keeps the worker count it was started with' {
        # MACHINES-AT-ONCE-RANGE-1: that is the wave's own number, which the
        # start reads (no start carries one, and a running wave cannot be
        # edited), never a number of the resume's own.
        $resume = [regex]::Match($script:core, '(?s)function Invoke-VmfFacadeResumeStalledWaves.*?\n\}').Value
        $resume | Should -Match "-Operation 'wave' -RunId \`$RunId -Wave \`$wave -Note"
        $resume | Should -Not -Match '-Throttle'
    }

    It 'the size is a documented table, by the consumption plan steps' {
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeEngineResources.*?\n\}').Value
        $fn | Should -Match "cpu = '1'; memory = '2Gi'"
        $fn | Should -Match "cpu = '2'; memory = '4Gi'"
        $fn | Should -Match "cpu = '4'; memory = '8Gi'"
        $fn | Should -Match '2,410 MB' -Because 'the measurement the table rests on is written where the table is'
        $fn | Should -Match '\$Workers -le 3\b'
        $fn | Should -Match '\$Workers -le 7\b'
    }

    It 'the largest tier needs a workload-profiles environment, so the template declares one and the job names it' {
        # MEASURED 2026-09-04 by the scale drill: a Consumption-only (legacy)
        # environment refused 4 CPU / 8 GiB: "[cpu: 2.0, memory: 4.0Gi]" is
        # its largest step. Microsoft's docs say workload profiles go beyond
        # 2 CPU / 4 GiB.
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $bicep | Should -Match "workloadProfileType: 'Consumption'"
        $bicep | Should -Match "workloadProfileName: 'Consumption'"
        $bicep.IndexOf("workloadProfileType: 'Consumption'") | Should -BeLessThan $bicep.IndexOf("workloadProfileName: 'Consumption'")
    }

    It 'the run page words what the engine says about itself, and hides the once-a-minute readings' {
        # Seen 2026-09-04 during the drill: stray messages in the feed -
        # "engine:memory" printed as a step name in the activity feed.
        $script:migrations | Should -Match "engineStarted:\s+'Engine version \{v\} started this operation\.'"
        $script:migrations | Should -Match "engineMemoryPeak:\s+'Memory peak: one worker used \{max\} MB, with \{n\} workers running at the same time\.'"
        $script:migrations | Should -Match "if \(e\.engineVersion\) return UX_STEP\.engineStarted\.replace\('\{v\}', e\.engineVersion\);"
        $script:migrations | Should -Match "if \(e\.peakWorkerMB\) return UX_STEP\.engineMemoryPeak"
        $script:migrations | Should -Match "if \(e\.step === 'engine:memory' && e\.peakWorkerMB === undefined\) continue;"
    }

    It 'SCALE-2: the wave editor asks whether the environment holds the containers, and says so beside the estimate' {
        $script:waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $script:waves | Should -Match 'data-caphint="\$\{esc\(name\)\}"'
        $script:waves | Should -Match 'apiGet\(`engine/capacity\?atOnce=\$\{workers\}`\)'
        $script:waves | Should -Match "capFits:\s+'This wave needs \{n\} engine containers, \{cores\} cores\. The environment has \{free\} of \{limit\} free\.'"
        # WORDS-1: the property is that the refusal names the three numbers an
        # operator needs - what it wants, what is free, what the ceiling is.
        $script:waves | Should -Match "capTooMany:\s+'This wave needs \{cores\} cores"
        $script:waves | Should -Match 'engine workers'
        $script:waves | Should -Match '\{free\} of \{limit\} are free'
        $script:waves | Should -Match 'showEngineCapacity\(h\.dataset\.caphint, layout\.get\(h\.dataset\.caphint\)\?\.throttle'
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $bicep | Should -Match "(?s)module acaEnv .*?roleAssignments: \[\s*\{\s*principalId: facade\.outputs\.systemAssignedMIPrincipalId!\s*principalType: 'ServicePrincipal'\s*roleDefinitionIdOrName: roleReader" -Because 'the facade must be able to read the environment usages'
        $script:core | Should -Match "Assert-VmfFacadeEngineCapacity -Workers \`$Throttle -Job \`$job"
        $script:core | Should -Match "Assert-VmfFacadeEngineCapacity -Workers \`$Throttle -Job \`$schedJob"
    }

    It 'and on the legacy kind the facade says 10 is the most, in a sentence, before Azure is asked' {
        $script:core | Should -Match "'400: at most 7 machines at once on this installation"
        $script:core | Should -Match '-ConsumptionOnly:\(Test-VmfFacadeConsumptionOnly -Job \$job\)'
    }
}

Describe 'SCALE-UX-1: both screens say what the number means' {

    It 'the migration start dialog says the wave''s choice and an estimate' {
        # MACHINES-AT-ONCE-RANGE-1: no number field - the wave's own choice.
        $script:migrations | Should -Match "UX_ACT\.atOnceStart\.replace\('\{choice\}', VmfHelp\.atOnceChoice\(atOnce\)\.label\)"
        $script:migrations | Should -Match 'VmfHelp\.waveEstimate\(waveEntries\.length, atOnce, UX_ACT\)'
        $script:migrations | Should -Match "const waveEntries = \(planDoc\?\.entries \?\? \[\]\)\.filter\(e => e\.wave === wave\)"
    }

    It 'and the modal paints a field hint live, as the value is typed' {
        $script:migrations | Should -Match "input\.addEventListener\('input', paint\)"
        $script:migrations | Should -Match 'mf-\$\{f\.id\}-hint'
    }

    It 'the wizard says each wave''s choice and an estimate, in the wave''s row' {
        $script:wizard | Should -Not -Match 'id="f-thr"'
        $script:wizard | Should -Match 'VmfHelp\.waveEstimate\(moving\.length, VmfHelp\.waveAtOnce\(moving\), UX\)'
    }

    It 'neither sends a number of its own' {
        $script:migrations | Should -Match 'engine/wave`, \{ wave, note: v\.note \}'
        $script:wizard | Should -Match "runBody\(\{ wave: first, note \}\)"
    }
}

Describe 'SCALE-UX-1 (wave editor): the number is a lever of the wave' {
    # The wave editor showed nothing new; the number belongs in the wave
    # editor. It is a decision of the wave, so it lives with the
    # other levers, is accepted with them, and is the default for every start.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
    }

    It 'the contract declares it, the four choices up to 60 (SCALE-2 widened it from 20; ATONCE-EARLIER-1 left only the choices), with a note' {
        $t = $script:schema.properties.policy.properties.throttle
        @($t.enum) | Should -Be @(5, 15, 30, 60)
        # The note for SCALE-2's own bump, which is a fact about the past and
        # stays true. The CURRENT plan version is not this test's subject -
        # TempDiskCount.Tests.ps1 holds the schema, the module and the sample
        # to one number, and requires a note for whatever that number is.
        Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw | Should -Match 'plan-entry v11 -> v12'
    }

    It 'the wave editor shows it beside the machines it counts, with the estimate live' {
        $script:waves | Should -Match 'data-thr="\$\{esc\(name\)\}"'
        # MACHINES-AT-ONCE-RANGE-1: four choices, then what it means and the estimate.
        $script:waves | Should -Match '<select data-thr='
        $script:waves | Should -Match '<span class="hint">\$\{esc\(VmfHelp\.waveEstimate\(members\.length, w\.throttle, UX\)'
    }

    It 'is saved with the wave, and counts as a change when it changes' {
        $script:waves | Should -Match 'throttle: w\.throttle,'
        $script:waves | Should -Match 'w\.keepSnapshotDays, w\.throttle, \[\.\.\.w\.vmIds\]\.sort\(\)'
        # WAVE-LEVER-OVERRIDE-1: the default is in the page's one table, and the
        # card reads how many at once as the engine does for the wave - the
        # first machine that has a number.
        # ACCEPT-FIRST-MACHINE-1: that table and the reading are in help.js,
        # which the acceptance asks too; the page names the table from there.
        $script:waves | Should -Match ([regex]::Escape('const WAVE_DEFAULTS = VmfHelp.waveSettingDefaults();'))
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match "throttle: WAVE_DEFAULT_WORKERS,"
        $help | Should -Match ([regex]::Escape("if (field === 'throttle') { return waveAtOnce(members); }"))
    }

    It 'both review tables show what was accepted' {
        $script:migrations | Should -Match "\[UX_LEVER\.atOnce, VmfHelp\.atOnceChoice\(VmfHelp\.waveAtOnce\(entries\)\)\.label\]"
        $script:wizard | Should -Match "\[UX\.lvAtOnce, \[VmfHelp\.atOnceChoice\(VmfHelp\.waveAtOnce\(moving\)\)\.label"
    }

    It 'and every start uses it: the dialog shows it, and the service reads it for every start' {
        $script:migrations | Should -Match "const atOnce = VmfHelp\.waveAtOnce\(waveEntries\)"
        $script:core | Should -Match "\`$Throttle = Get-VmfFacadeWaveThrottle -StorePath \(Get-VmfFacadeStorePath -RunId \`$planRunId\) -Wave \`$Wave"
    }
}
