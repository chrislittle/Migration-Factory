#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ASSESS-PAGE-1 - what an assessment's blockers MEAN, in one place.
#
# The assessment report exists to tell an operator why a machine cannot move
# while there is still time to do something about it. That only works if every
# reason the engine can produce has words a person can act on.
#
# It did not. Two pages carried their own partial copies of the wording - the
# wizard inline, the dashboard as a map - and BOTH were missing five of the
# seven blockers: confidential, image-not-supported, image-cannot-boot-nvme,
# unmanaged-os-disk and nva-requires-parallel-deployment. A machine held back
# for any of those showed the operator the raw code.
#
# So the wording is data now, beside the rules that emit the codes, and this
# file fails when the two drift apart in either direction.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:reasonsPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json'
    $script:reasons = Get-Content $script:reasonsPath -Raw | ConvertFrom-Json
    $script:rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw

    # Derived from the rules themselves: a code the engine can emit is one an
    # operator can be shown, so the list must come from the source rather than
    # from a copy somebody keeps up to date by hand.
    function Global:CodesFrom([string]$Collection) {
        @([regex]::Matches($script:rules, "$Collection\.Add\('([^']+)'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
}
AfterAll { Remove-Item 'function:\CodesFrom' -ErrorAction SilentlyContinue }

Describe 'ASSESS-PAGE-1: every reason the engine emits has words' {

    It 'found the codes in the rules' {
        # A derived check that reads nothing passes everything.
        @(CodesFrom 'blockers').Count | Should -BeGreaterThan 4
        @(CodesFrom 'prep').Count | Should -BeGreaterThan 3
    }

    It 'every BLOCKER the rules can emit is explained' {
        $missing = @(CodesFrom 'blockers' | Where-Object { -not $script:reasons.blockers.PSObject.Properties[$_] })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a machine held back for one of these would show the operator a raw code'
    }

    It 'every PREP item the rules can emit is explained' {
        $missing = @(CodesFrom 'prep' | Where-Object { -not $script:reasons.prep.PSObject.Properties[$_] })
        $missing -join ', ' | Should -BeNullOrEmpty
    }
    It 'every WARNING the rules can emit is explained (DETECT-PATTERNS-1)' {
        @(CodesFrom 'warnings').Count | Should -BeGreaterThan 1 -Because 'the derived list read the rules'
        $missing = @(CodesFrom 'warnings' | Where-Object { -not $script:reasons.warnings.PSObject.Properties[$_] })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'every workload type the rules can give is named (DETECT-PATTERNS-1)' {
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'WorkloadType.ps1') -Raw
        $types = @([regex]::Matches($code, "& \`$result '([a-z-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $types.Count | Should -BeGreaterThan 5
        $missing = @($types | Where-Object { -not $script:reasons.workloadTypes.PSObject.Properties[$_] })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'and nothing is explained that the rules cannot emit' {
        # A stale entry is worse than none: it reads as a considered answer to a
        # question nobody can ask any more.
        $known = @(CodesFrom 'blockers') + @(CodesFrom 'prep') + @(CodesFrom 'warnings')
        $ghosts = @(@($script:reasons.blockers.PSObject.Properties.Name) + @($script:reasons.prep.PSObject.Properties.Name) + @($script:reasons.warnings.PSObject.Properties.Name) |
            Where-Object { $_ -notin $known })
        $ghosts -join ', ' | Should -BeNullOrEmpty -Because 'these explain codes the engine no longer produces'
    }
}

Describe 'ASSESS-PAGE-1: the words are worth reading' {

    It 'each one says what it means AND what to do about it' {
        # "image-not-supported" restated as "the image is not supported" helps
        # nobody. The point of the report is that somebody can act on it.
        foreach ($group in 'blockers', 'prep', 'warnings') {
            foreach ($p in $script:reasons.$group.PSObject.Properties) {
                $p.Value.title     | Should -Not -BeNullOrEmpty -Because "$($p.Name) needs a title"
                $p.Value.meaning   | Should -Not -BeNullOrEmpty -Because "$($p.Name) needs a meaning"
                $p.Value.whatToDo  | Should -Not -BeNullOrEmpty -Because "$($p.Name) must say what to do"
                ($p.Value.meaning.Length + $p.Value.whatToDo.Length) | Should -BeGreaterThan 60 `
                    -Because "$($p.Name) should be an explanation, not a restatement of its own code"
            }
        }
    }

    It 'and never just repeats the code back' {
        foreach ($group in 'blockers', 'prep', 'warnings') {
            foreach ($p in $script:reasons.$group.PSObject.Properties) {
                $p.Value.meaning | Should -Not -Match ([regex]::Escape($p.Name)) `
                    -Because "$($p.Name) must be explained in words, not echoed"
            }
        }
    }

    It 'uses ENGINE words nowhere and TECHNICAL names freely (STE-1)' {
        # This test used to ban 'NVMe' and 'SCSI' as jargon. That is what
        # produced "Image cannot start on the new disk type" - a sentence that
        # names no disk type, explains nothing, and gives a reader nowhere to
        # go: it said neither which disk type nor why.
        #
        # ASD-STE100 draws the line in the right place: TECHNICAL NAMES are
        # approved words. 'NVMe' is what Microsoft's own page calls it and what
        # the operator will search for. 'stornvme' is the name of a registry
        # key in our own fix, and no operator ever needs it.
        #
        # The list lives in tools/Test-SimplifiedEnglish.ps1 so that every
        # source of operator text answers to ONE vocabulary.
        $ste = Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1'
        Test-Path $ste | Should -BeTrue -Because 'the vocabulary has one home'
        $result = & $ste -Source 'assessment-reasons' 6>$null
        @($result.Findings) -join '; ' | Should -BeNullOrEmpty
    }

    It 'and every reason links to Microsoft own page' {
        # The reasons were wordy and unclear about the data in Microsoft's docs.
        # A blocker tells somebody their machine cannot move; the next thing
        # they need is the page that says why, in Microsoft's words rather than
        # ours.
        foreach ($group in 'blockers', 'prep', 'warnings') {
            foreach ($p in $script:reasons.$group.PSObject.Properties) {
                $p.Value.docs       | Should -Not -BeNullOrEmpty -Because "$($p.Name) must link to the guidance"
                $p.Value.docs.url   | Should -Match '^https://learn\.microsoft\.com/' -Because "$($p.Name) must link to Microsoft, not to us"
                $p.Value.docs.label | Should -Not -BeNullOrEmpty -Because "a link says where it goes before you click it"
            }
        }
    }
}

Describe 'ASSESS-PAGE-1: one copy, not three' {

    It 'and there is NO second copy sitting in the dashboard folder' {
        # StopReasons guards its file this way and caught me putting a local
        # copy here for the preview's benefit. It is right: a second copy is the
        # drift, whether or not git tracks it. The cost is that a LOCAL preview
        # shows raw codes rather than the wording, because the file only arrives
        # at deploy time - which is a dev-loop annoyance, not a product defect,
        # and a page that renders codes is the correct fallback anyway.
        Test-Path (Join-Path $script:repoRoot 'src' 'dashboard' 'assessment-reasons.json') |
            Should -BeFalse -Because 'the engine data directory is the only copy'
    }

    It 'the wording ships to the dashboard rather than being retyped there' {
        # stop-reasons.json set this precedent: the page shows what the engine
        # decided, from the engine's own file, copied at deploy time.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match 'assessment-reasons\.json'
    }

    It 'and no page carries its own copy of the blocker wording' {
        # Both copies that existed were incomplete, in different ways. That is
        # what having copies does.
        foreach ($page in 'index.html', 'migrations.html', 'wizard.html', 'assessments.html') {
            $text = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page))
            $text | Should -Not -Match "'gen1-requires-redeploy'\s*:\s*'" `
                -Because "$page must read the shared wording, not restate it"
        }
    }
}
