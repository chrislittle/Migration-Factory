#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STARTS-SOON-WORDS-1: three strings promised "five minutes" for a start the
# service makes on its five-minute check. TIMER-PASS-LIMIT-1 made a check of a
# large store take more than one pass, so a wave whose turn comes in a later
# pass starts later, and the promise was not true there:
#
#   migrations.html  startsSoon   "Starts within five minutes"
#   wizard.html      howAllHint   "Each wave starts within five minutes of the one before it finishing."
#   Start-VmfWave    the refusal  "The product checks it again within five minutes."
#
# Each then named the event - the next check of the service - and the two pages
# put the why behind a (?) helper. tests/js/starts-soon-words.test.js RUNS the
# migrations page's control; this holds the words, their use and the manual.
#
# WAVE-ORDER-START-1 (lab Session A, 2026-11-04, finding 24): the owner read
# the line and its why as odd and unclear - they named the service's check,
# not what a person waits for. The two pages now say the outcome, "within
# ABOUT 5 minutes", and the why says that it can take longer when many
# migrations wait. So the rule is no longer "no time at all": it is "never a
# bare promise of a fixed time" - every time is "about", and the why says it
# can be later.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:migFile = Join-Path $script:dash 'migrations.html'
    $script:wizFile = Join-Path $script:dash 'wizard.html'
    $script:startFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1'
    $script:mig = Get-VmfCodeOnly -Path $script:migFile
    $script:wiz = Get-VmfCodeOnly -Path $script:wizFile
    $script:start = Get-VmfCodeOnly -Path $script:startFile
    # A string a page declares, read from its table: `  key: 'text',`.
    $script:declared = {
        param([string]$Code, [string]$Key)
        $m = [regex]::Match($Code, "(?m)^\s*$Key\s*:\s*'([^']*)',")
        if (-not $m.Success) { return $null }
        $m.Groups[1].Value
    }
    # The promise of a fixed time: a number of minutes, in figures or words,
    # with no "about" before it.
    $script:fixedTime = '(?i)\b(within|in|after)\s+(\d+|one|two|three|four|five|ten|fifteen)\s+minutes?\b'
    $script:manualStart = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' 'use' 'start.md'))
}

Describe 'STARTS-SOON-WORDS-1: no page promises a start within a fixed time' {

    It 'WAVE-ORDER-START-1: the migrations page declares a line that says about how long' {
        $line = & $script:declared $script:mig 'startsSoon'
        $line | Should -Not -BeNullOrEmpty -Because 'the page declares startsSoon'
        $line | Should -Be 'Starts within about 5 minutes'
        $line | Should -Not -Match $script:fixedTime
    }

    It 'the migrations page shows that line where a wave follows on its own' {
        $script:mig | Should -Match ([regex]::Escape('return UX_MISC.startsSoon;')) -Because 'planFollowText gives the declared line'
        $script:mig | Should -Match ([regex]::Escape('follows === UX_MISC.startsSoon ? startsSoonHtml(wave)')) -Because 'the wave header puts its (?) beside it'
        $script:mig | Should -Match ([regex]::Escape('${esc(UX_MISC.startsSoon)}'))
    }

    It 'WAVE-ORDER-START-1: the wizard declares a hint that says about how long, and shows it under both places that draw it' {
        $hint = & $script:declared $script:wiz 'howAllHint'
        $hint | Should -Not -BeNullOrEmpty -Because 'the wizard declares howAllHint'
        $hint | Should -Match '(?i)within about 5 minutes'
        $hint | Should -Not -Match $script:fixedTime
        ([regex]::Matches($script:wiz, [regex]::Escape(': UX.howAllHint'))).Count | Should -Be 2 -Because 'the first draw and the change of choice'
    }

    It 'the engine refusal says the next check, not a time' {
        $m = [regex]::Match($script:start, 'throw "Wave \$Wave changed after the (product|service) checked it for this start[^"]*"')
        $m.Success | Should -BeTrue -Because 'Start-VmfWave refuses a wave that changed after the check'
        $m.Value | Should -Not -Match '(?i)minute'
        $m.Value | Should -Match ([regex]::Escape('The service checks the wave again at its next check.'))
        # One noun for one thing: only the service's own start passes -WaveVersion.
        $m.Value | Should -Match ([regex]::Escape('changed after the service checked it for this start'))
        $m.Value | Should -Not -Match 'product'
    }

    It 'nothing of the three says a fixed time any more' {
        foreach ($code in $script:mig, $script:wiz, $script:start) {
            $code | Should -Not -Match '(?i)within five minutes'
        }
        (& $script:declared $script:mig 'startsSoon') | Should -Not -Match $script:fixedTime
        (& $script:declared $script:wiz 'howAllHint') | Should -Not -Match $script:fixedTime
    }
}

Describe 'STARTS-SOON-WORDS-1: the why is behind a (?) on both pages' {

    It 'the two pages give the same why, and it names the 5-minute check and that it can take longer' {
        $migWhy = & $script:declared $script:mig 'startsSoonHelp'
        $wizWhy = & $script:declared $script:wiz 'howCheckHelp'
        $migWhy | Should -Not -BeNullOrEmpty
        $wizWhy | Should -Be $migWhy -Because 'one fact, said one way on both pages'
        $migWhy | Should -Match 'every 5 minutes'
        $migWhy | Should -Match ([regex]::Escape('When many migrations wait, it can take longer.')) -Because 'the "about" is said with its limit'
    }

    It 'the migrations page draws its (?) with the declared label, and Escape closes it' {
        $tip = & $script:declared $script:mig 'startsSoonHelpTip'
        $tip | Should -Not -BeNullOrEmpty
        $script:mig | Should -Match ([regex]::Escape('title="${esc(UX_MISC.startsSoonHelpTip)}"'))
        $script:mig | Should -Match ([regex]::Escape('${esc(UX_MISC.startsSoonHelp)}'))
        $script:mig | Should -Match ([regex]::Escape('if (soonHelpOpen.size) { soonHelpOpen.clear(); renderWaves(latestHalted); return; }'))
    }

    It 'the wizard draws its (?) with the declared label beside the hint, and Escape on the step closes it' {
        $tip = & $script:declared $script:wiz 'howCheckAbout'
        $tip | Should -Not -BeNullOrEmpty
        $script:wiz | Should -Match ([regex]::Escape("tHelpBtn('run-check', UX.howCheckAbout)"))
        $script:wiz | Should -Match ([regex]::Escape("tHelp.has('run-check') ? ``<p class=""muted t-help-text"" id=""t-help-run-check"">`${esc(UX.howCheckHelp)}</p>``"))
        $script:wiz | Should -Match ([regex]::Escape("step === STEP.migrate.run && tHelp.size) { tHelp.clear(); render(); }"))
    }
}

Describe 'STARTS-SOON-WORDS-1: the manual quotes the new words' {

    It 'the start page quotes the line of the migrations page as the page says it' {
        $line = & $script:declared $script:mig 'startsSoon'
        $script:manualStart | Should -Match ([regex]::Escape("**$line**"))
    }

    It 'no manual page promises a wave start within five minutes' {
        $manual = Join-Path $script:repoRoot 'docs' 'manual'
        $bad = Get-ChildItem $manual -Recurse -Filter '*.md' | Where-Object {
            [System.IO.File]::ReadAllText($_.FullName) -match '(?i)starts within five minutes'
        } | ForEach-Object Name
        $bad | Should -BeNullOrEmpty
    }
}
