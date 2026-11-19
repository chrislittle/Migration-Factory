#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STE-1 - every word this product shows an operator, against ASD-STE100.
#
# Found 2026-09-01 on an assessment finding: the popouts were jargon, wordy,
# and unclear about the data in Microsoft's docs they linked to. "Image cannot
# start on the new disk type" did not say which disk type or why, and a line
# called the finding "Azure's own answer rather than a judgement of ours",
# which means nothing to a reader. The terms were not clear, so the whole
# portal UX and the docs were swept to ASD-STE100 (https://www.asd-ste100.org/).
#
# WHAT WENT WRONG BEFORE. This repo already had a plain-language rule, copied
# into six Describe blocks, and it banned 'NVMe' and 'SCSI' as jargon. So the
# wording had to say "the new disk type" - a phrase that names nothing, explains
# nothing, and sends the reader nowhere. The rule produced the defect.
#
# ASD-STE100 puts the line in the right place. Technical names are APPROVED
# words: 'NVMe' is what Microsoft's own page calls it and what the operator will
# search for. 'stornvme' is a registry key in our own fix, and no operator ever
# needs it. Plus the parts that make text readable under pressure: short
# sentences, active voice, one meaning per word, no idioms, no words that point
# at nothing.
#
# The rules and the vocabulary live in tools/Test-SimplifiedEnglish.ps1 - ONE
# home, so that a page, a reason file and the in-app guide cannot each answer to
# a different bar. This file is the gate.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool     = Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1'
    $script:result   = & $script:tool 6>$null

    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    # HELP-JS-RULE12-1, DEPLOY-MSG-RULE12-1: every command name and tool
    # script that a dashboard file's code holds, less one exemption by name:
    # a sample guest record names the guest script that ran, as data in its
    # script field. Only a script the guest manifest lists, and only there.
    $script:guestScripts = @((Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw |
        ConvertFrom-Json).scripts.name)
    $script:rule12Hits = {
        param([string]$Code)
        foreach ($m in [regex]::Matches($Code, '\b[A-Z][a-z]+-Vmf[A-Za-z]+\b|[\w./-]+\.ps1\b')) {
            $sample = ($script:guestScripts -contains $m.Value) -and
                ($Code.Substring(0, $m.Index) -match '\bscript["'']?\s*:\s*["'']$')
            if (-not $sample) { $m.Value }
        }
    }
}

Describe 'STE-1: the operator-facing words' {

    It 'the checker exists and reads real text - a check that reads nothing passes everything' {
        Test-Path $script:tool | Should -BeTrue
        $sources = & $script:tool -ListSources 6>$null
        # Every page, both reason files and the in-app guide, all non-empty.
        @($sources).Count | Should -BeGreaterThan 8
        ($sources -join "`n") | Should -Not -Match '\b0 string'
    }

    It 'has no findings anywhere' {
        $detail = @($script:result.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join "`n"
        $script:result.Count | Should -Be 0 -Because "ASD-STE100:`n$detail"
    }
}

Describe 'STE-1: the rules themselves' {
    # The checker is the thing every other test now defers to, so it has to be
    # provably awake. Each of these feeds it text that breaks one rule.
    It 'catches engine vocabulary' {
        # A word from our own machinery, in a real source, must fail. Proven by
        # temporarily writing one into a copy of the page and checking the tool
        # reports it - never by trusting that the list is used.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ste-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            Copy-Item (Join-Path $script:repoRoot 'src') $tmp -Recurse
            # CSP-INLINE-1: the page's strings are in its own script file.
            $page = Join-Path $tmp 'dashboard' 'projects.js'
            $text = [System.IO.File]::ReadAllText($page)
            $text = $text -replace '(UX-STRINGS-BEGIN[\s\S]{0,200}?\n)', "`$1  steProbe: 'The azureops layer writes an ETag.',`n"
            Set-Content $page $text -NoNewline

            $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-steroot-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $fake -Force | Out-Null
            Move-Item $tmp (Join-Path $fake 'src')

            $r = & $script:tool -Path $fake -Source 'projects' 6>$null
            @($r.Findings).Rule | Should -Contain 'jargon' -Because 'the guard must actually run its own list'
        }
        finally {
            foreach ($d in $tmp, $fake) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
        }
    }

    It 'GATE-WORDS-1: reads the start gate reasons the engine gives, and catches a command or a lever in them' {
        # The engine's start gate reasons reach the Try this machine again
        # dialog. They named Confirm-VmfRunAcknowledgement and the wave's
        # "levers", and nothing checked them, because the gate read no engine
        # text. The words moved to data/start-gates.json so that it can.
        $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'start-gates.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $want = 2 * @($doc.reasons.PSObject.Properties).Count + @($doc.lines.PSObject.Properties).Count
        ((& $script:tool -ListSources 6>$null) -match '^start-gates\s') | Should -Match "\b$want string" -Because 'every reason has two sentences, and every line one'

        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stegate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $data = Join-Path $fake 'src' 'VmMigrationFactory' 'data'
            New-Item -ItemType Directory -Path $data -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $fake 'src' 'dashboard') -Force | Out-Null
            $doc.reasons.notAccepted.toDo = 'Review the levers of the wave, or run Confirm-VmfWaveOptions.'
            $doc | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $data 'start-gates.json') -Encoding utf8NoBOM
            $r = & $script:tool -Path $fake -Source 'start-gates' 6>$null
            $said = @($r.Findings | Where-Object { $_.Id -eq 'start-gates.json:notAccepted.toDo' } | ForEach-Object { $_.Detail }) -join "`n"
            $said | Should -Match "engine vocabulary 'lever'"
            $said | Should -Match "names the command 'Confirm-VmfWaveOptions'"
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'FILTER-DRIVER-READ-1: a sentence of Microsoft''s, quoted byte for byte from one pinned page, is not read; any other quote is' {
        $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'start-gates.json'
        $quote = 'Customized VMs that run third-party software capable of modifying boot-time behavior, storage drivers, filter drivers, or disk enumeration aren''t currently a supported migration scenario.'
        # A sentence with a phrasal verb, which only the term rules read.
        $setUp = 'Before you resize the machine, set up a backup of the OS disk and of every data disk.'
        foreach ($case in @(
                @{ Pinned = $true; Said = "Microsoft says: ""$quote"""; Want = 0 },
                # Not on a pinned page: one word changed.
                @{ Pinned = $true; Said = "Microsoft says: ""$($quote.Replace('currently', 'today'))"""; Want = 1 },
                # No pinned page holds it.
                @{ Pinned = $false; Said = "Microsoft says: ""$quote"""; Want = 1 },
                # A short quote is read as usual, even when the page holds it.
                @{ Pinned = $true; Said = 'Microsoft says: "aren''t currently a supported migration scenario."'; Want = 1 },
                # Byte for byte: a page that breaks the line inside the sentence does not hold it.
                @{ Pinned = $true; PageText = "Note`n`n$($quote.Replace(' disk enumeration', "`ndisk enumeration"))"; Said = "Microsoft says: ""$quote"""; Want = 1 },
                # Byte for byte: another case is another text.
                @{ Pinned = $true; Said = "Microsoft says: ""$($quote.Replace('Customized VMs', 'customized VMs'))"""; Want = 1 },
                # Byte for byte: two spaces where the page has one is another text.
                @{ Pinned = $true; Said = "Microsoft says: ""$($quote.Replace('storage drivers', 'storage  drivers'))"""; Want = 1 },
                # The term rules (a phrasal verb) do not read inside it either.
                @{ Pinned = $true; PageText = "Note`n`n$setUp Examples include certain backup products."; Said = "Microsoft says: ""$setUp"""; Want = 0 },
                @{ Pinned = $false; Said = "Microsoft says: ""$setUp"""; Want = 1 },
                # One page: a quote made of the end of one page and the start of another is not on a page.
                @{ Pinned = $true; Split = $true; Said = "Microsoft says: ""$quote"""; Want = 1 })) {
            $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stequote-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                $data = Join-Path $fake 'src' 'VmMigrationFactory' 'data'
                New-Item -ItemType Directory -Path $data -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $fake 'src' 'dashboard') -Force | Out-Null
                if ($case.Pinned) {
                    $up = Join-Path $fake 'docs' 'upstream-docs' 'azure'
                    New-Item -ItemType Directory -Path $up -Force | Out-Null
                    if ($case.Split) {
                        $cut = $quote.IndexOf(' storage drivers')
                        [System.IO.File]::WriteAllText((Join-Path $up 'a.md'), "Note`n`n$($quote.Substring(0, $cut))")
                        [System.IO.File]::WriteAllText((Join-Path $up 'b.md'), "$($quote.Substring($cut + 1)) Examples include certain backup products.")
                    } else {
                        $pageText = if ($case.PageText) { $case.PageText } else { "Note`n`n$quote Examples include certain backup products." }
                        [System.IO.File]::WriteAllText((Join-Path $up 'nvme-linux.md'), $pageText)
                    }
                }
                $doc = Get-Content $file -Raw | ConvertFrom-Json
                $doc.reasons.notAccepted.toDo = $case.Said
                $doc | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $data 'start-gates.json') -Encoding utf8NoBOM
                $r = & $script:tool -Path $fake -Source 'start-gates' 6>$null
                $found = @($r.Findings | Where-Object { $_.Id -eq 'start-gates.json:notAccepted.toDo' })
                [bool]$found.Count | Should -Be ([bool]$case.Want) -Because "$($case.Said) gave: $(@($found.Detail) -join '; ')"
            }
            finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
        }
    }

    It 'HELP-JS-RULE12-1: reads help.js - every TEXT string, joined, and every FAILURES sentence' {
        # help.js holds the words every page shares: the sign-in card, the
        # Get help menu, and the sentence that replaces an error. The gate read
        # only the pages, so one of those sentences told a person to run a tool
        # script (hard rule 12) and nothing caught it.
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stehelp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dash = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $dash -Force | Out-Null
            $probe = @'
(function () {
  const TEXT = {
    plain: 'Sign out',
    joined: 'The first part is here. ' +
      'Run Test-VmfProbe to see it.',
    escaped: 'It isn\'t here.',
    goBtn: 'Press this button to open the next page of the dashboard, then read every line on it before you press it again.',
  };
  const FAILURES = [
    // It used to say 'Run Test-VmfHealth here.' and a comment is not shown.
    { when: /it is 'Stop-VmfProbe'|it's/i,
      say: 'Run tools/Probe-Thing.ps1 to find out why the service refused this call before the product saw it, and then reload this page again.' },
    { when: /403: (x)/,
      say: (m) => `It needs ${m[1]}, so run Start-VmfProbe now.` },
  ];
})();
'@
            [System.IO.File]::WriteAllText((Join-Path $dash 'help.js'), $probe)

            # @(): one source gives one line, and -match on one line gives $true.
            (@(& $script:tool -Path $fake -ListSources 6>$null) -match '^help\s') | Should -Match '\b6 string' -Because 'four TEXT strings and two FAILURES sentences, and the comment is not one'

            $r = & $script:tool -Path $fake -Source 'help' 6>$null
            $by = @{}
            foreach ($f in @($r.Findings)) { $by[$f.Id] = "$($by[$f.Id])`n$($f.Detail)" }
            $by['help.js:TEXT.joined'] | Should -Match "names the command 'Test-VmfProbe'" -Because 'the second line of a joined string is part of it'
            $by['help.js:TEXT.escaped'] | Should -Match "'isn't' - use the full form" -Because 'an escaped quote is read as the quote it shows'
            # 22 words each: a button and an error's sentence tell a person
            # what to do, so the instruction limit of 20 applies to both.
            $by['help.js:TEXT.goBtn'] | Should -Match '22 words \(limit 20 for instruction\)'
            $by['help.js:FAILURES.1'] | Should -Match '22 words \(limit 20 for instruction\)'
            $by['help.js:FAILURES.1'] | Should -Match "names the script 'tools/Probe-Thing.ps1'" -Because 'a quote inside the regular expression must not hide the sentence'
            $by['help.js:FAILURES.2'] | Should -Match "names the command 'Start-VmfProbe'" -Because 'a sentence built by a function is read too'
            ($by.Values -join "`n") | Should -Not -Match 'Test-VmfHealth' -Because 'a comment is never shown'
            ($by.Values -join "`n") | Should -Not -Match 'Stop-VmfProbe' -Because 'a quote inside a regular expression is not a sentence'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'HELP-JS-RULE12-1: the real help.js is read, all of it' {
        $line = @(& $script:tool -ListSources 6>$null) -match '^help\s'
        $line | Should -Not -BeNullOrEmpty
        # TEXT held 55 strings and FAILURES 11 sentences when this was written.
        [int]([regex]::Match([string]$line, '(\d+) string').Groups[1].Value) | Should -BeGreaterThan 60
        $said = (& $script:tool -Source 'help' 6>$null)
        $said.Count | Should -Be 0 -Because ((@($said.Findings) | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join "`n")
    }

    It 'HELP-JS-RULE12-1, DEPLOY-MSG-RULE12-1: no dashboard page sends anybody to a command or a tool script' {
        # Hard rule 12. Every string in every page and shared script, not only
        # the strings blocks the wording gate reads: a sentence built anywhere
        # in the file is shown. It read only help.js, so two errors on two
        # pages still said to run Deploy-VmfFacade.ps1 and
        # Deploy-VmfDashboard.ps1, and nothing caught them.
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        $files = @(Get-ChildItem $dash -File | Where-Object { $_.Extension -in '.html', '.js' -and $_.Name -notlike '*.min.js' })
        # Eight pages and three shared scripts when this was written.
        $files.Count | Should -BeGreaterThan 9
        foreach ($name in 'help.js', 'access.html', 'migrations.html') { @($files.Name) | Should -Contain $name }
        $hits = foreach ($file in $files) {
            foreach ($v in (& $script:rule12Hits (Get-VmfCodeOnly -Path $file.FullName))) { "$($file.Name): $v" }
        }
        @($hits) -join ', ' | Should -BeNullOrEmpty -Because 'name the page in the app that does it, or say to install the product again'
    }

    It 'DEPLOY-MSG-RULE12-1: the sample guest record exemption takes only a guest script, and only in a script field' {
        $probe = @(
            "const a = { script: 'Set-NvmeReady.ps1' };"
            'const b = ''{"script":"Test-GuestValidation.ps1"}'';'
            "const c = { note: 'Set-NvmeReady.ps1' };"
            "const d = { script: 'tools/Deploy-Thing.ps1' };"
            "throw new Error('Run Set-NvmeReady.ps1 inside the machine, or Deploy-VmfFacade.');"
        ) -join "`n"
        $kept = @(& $script:rule12Hits (Get-VmfCodeOnly -Text $probe -Language CStyle))
        $kept | Should -Be @('Set-NvmeReady.ps1', 'tools/Deploy-Thing.ps1', 'Set-NvmeReady.ps1', 'Deploy-VmfFacade')
    }

    It 'DEPLOY-MSG-RULE12-1: the two start errors come from the strings block, so the wording gate reads them' {
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        $access = Get-VmfCodeOnly -Path (Join-Path $dash 'access.html')
        $access | Should -Match 'throw new Error\(UX\.noApi\)'
        $runs = Get-VmfCodeOnly -Path (Join-Path $dash 'migrations.html')
        $runs | Should -Match 'throw new Error\(UX_MISC\.msalMissing\)'
        # And the gate reads both: a copy of each page with an aside and a
        # tool script written into the sentence gets a finding on that key.
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stedeploy-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $copy = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $copy -Force | Out-Null
            foreach ($pair in @(@('access', 'noApi'), @('migrations', 'msalMissing'))) {
                # CSP-INLINE-1: the page and its own script file, with the
                # sentence changed in the script file, where it is.
                Copy-Item (Join-Path $dash "$($pair[0]).html") (Join-Path $copy "$($pair[0]).html")
                $text = [System.IO.File]::ReadAllText((Join-Path $dash "$($pair[0]).js"))
                $bad = [regex]::Replace($text, "(?m)^(\s*$($pair[1]):\s*)'[^']*'", "`$1'No API - run Deploy-VmfFacade.ps1 first.'")
                $bad | Should -Not -Be $text -Because "the page must hold the key $($pair[1])"
                [System.IO.File]::WriteAllText((Join-Path $copy "$($pair[0]).js"), $bad)
                $r = & $script:tool -Path $fake -Source $pair[0] 6>$null
                $said = @($r.Findings | Where-Object Id -eq "$($pair[0]).html:$($pair[1])" | ForEach-Object Detail) -join "`n"
                $said | Should -Match 'Deploy-VmfFacade' -Because "the gate must read $($pair[1])"
            }
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'allows technical names - the rule the old lint got wrong' {
        # 'NVMe' appears throughout the reason wording now, deliberately, and
        # must not be a finding.
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw
        $reasons | Should -Match 'NVMe' -Because 'the correct word for the thing is the correct word'
        @($script:result.Findings | Where-Object { $_.Id -like 'assessment-reasons*' }) | Should -BeNullOrEmpty
    }

    It 'QUOTA-PREVIEW-1: catches "ask Azure", in any case, and names the Azure term' {
        # Since 2026-10-26: nobody "asks Azure"; you request a quota
        # increase, in Azure's terms. Azure's own name for the action is a
        # quota increase request, and an Azure support request where support
        # is the channel.
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-steask-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dash = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $dash -Force | Out-Null
            $probe = @(
                '<script>'
                '// UX-STRINGS-BEGIN'
                'const UX = {'
                "  askTitle:  'Ask Azure to raise the quota for this size family.',"
                "  askLower:  'If the reason is NotAvailableForSubscription, ask azure support to remove the restriction.',"
                "  azureTerm: 'Request a quota increase on the Quotas page of the Azure portal.',"
                '};'
                '// UX-STRINGS-END'
                '</script>'
            ) -join "`n"
            Set-Content (Join-Path $dash 'probe.html') $probe -NoNewline

            $r = & $script:tool -Path $fake -Source 'probe' 6>$null
            $asks = @($r.Findings | Where-Object { $_.Rule -eq 'product-word' -and $_.Detail -match 'request a quota increase' })
            @($asks.Id) | Should -Contain 'probe.html:askTitle'
            @($asks.Id) | Should -Contain 'probe.html:askLower' -Because 'the match ignores case'
            @($r.Findings | Where-Object Id -eq 'probe.html:azureTerm') | Should -BeNullOrEmpty -Because 'the Azure term is the fix, not a finding'
        }
        finally {
            if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
        }
    }

    It 'CLUSTER-DETECT-1: "cluster node" is the name failover clustering gives, and a bare "node" still means machine' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stenode-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dash = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $dash -Force | Out-Null
            $probe = @(
                '<script>'
                '// UX-STRINGS-BEGIN'
                'const UX = {'
                "  bareNode:    'The node stops for a short time.',"
                "  clusterNode: 'This tool does not move a cluster node.',"
                "  nodePool:    'Add a new node pool at the new size.',"
                '};'
                '// UX-STRINGS-END'
                '</script>'
            ) -join "`n"
            Set-Content (Join-Path $dash 'probe.html') $probe -NoNewline

            $r = & $script:tool -Path $fake -Source 'probe' 6>$null
            $words = @($r.Findings | Where-Object { $_.Rule -eq 'one-word' })
            @($words.Id) | Should -Contain 'probe.html:bareNode' -Because 'this product says machine'
            @($words.Id) | Should -Not -Contain 'probe.html:clusterNode' -Because 'cluster node is the technical name'
            @($words.Id) | Should -Not -Contain 'probe.html:nodePool' -Because 'node pool is the Azure name'
        }
        finally {
            if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
        }
    }

    It 'BATCH-CYCLECLOUD-SIGNAL-1: "Azure Batch" is the name of an Azure service, and a bare "batch" still means wave' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stebatch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dash = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $dash -Force | Out-Null
            $probe = @(
                '<script>'
                '// UX-STRINGS-BEGIN'
                'const UX = {'
                "  bareBatch:  'Start the next batch.',"
                "  azureBatch: 'A machine in an Azure Batch pool is a scale set member.',"
                '};'
                '// UX-STRINGS-END'
                '</script>'
            ) -join "`n"
            Set-Content (Join-Path $dash 'probe.html') $probe -NoNewline

            $r = & $script:tool -Path $fake -Source 'probe' 6>$null
            $words = @($r.Findings | Where-Object { $_.Rule -eq 'product-word' -and $_.Detail -match "'wave'" })
            @($words.Id) | Should -Contain 'probe.html:bareBatch' -Because 'this product says wave'
            @($words.Id) | Should -Not -Contain 'probe.html:azureBatch' -Because 'Azure Batch is the Azure name'
        }
        finally {
            if (Test-Path $fake) { Remove-Item $fake -Recurse -Force }
        }
    }
}

Describe 'TERMS-AUDIT-1: banned terms and phrasal verbs, from one data file' {
    # Found 2026-11-04: the line "Checking the network is running on accelerated
    # hardware" was one of many such lines, so a full check was needed before
    # 1.0; and "Tidying up the disk it left behind" was not ASD-STE100 either.
    # The gate passed both: it knew a short list of
    # invented words and no phrasal verb, and it read no engine string at all.
    BeforeAll {
        $script:termsFile = Join-Path $script:repoRoot 'tools' 'ste-terms.json'
        $script:terms = Get-Content $script:termsFile -Raw | ConvertFrom-Json
        $script:allTerms = @(
            foreach ($t in @($script:terms.bannedPhrases)) { $t | Add-Member -NotePropertyName Rule -NotePropertyValue 'banned-term' -PassThru -Force }
            foreach ($t in @($script:terms.phrasalVerbs)) { $t | Add-Member -NotePropertyName Rule -NotePropertyValue 'phrasal-verb' -PassThru -Force }
        )
        # A probe page holds every example and every allowed sentence from the
        # data file, one string each, so the tool reads them as it reads a page.
        $script:probeRun = {
            param([string[]]$Sentences)
            $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-steterms-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $dash = Join-Path $fake 'src' 'dashboard'
            New-Item -ItemType Directory -Path $dash -Force | Out-Null
            $lines = for ($i = 0; $i -lt $Sentences.Count; $i++) { "  s${i}: '$($Sentences[$i])'," }
            $probe = @('<script>', '// UX-STRINGS-BEGIN', 'const UX = {') + $lines + @('};', '// UX-STRINGS-END', '</script>')
            [System.IO.File]::WriteAllText((Join-Path $dash 'probe.html'), ($probe -join "`n"))
            # The term file goes with the copy: the tool reads it from beside itself.
            try { & $script:tool -Path $fake -Source 'probe' 6>$null }
            finally { Remove-Item $fake -Recurse -Force }
        }
    }

    It 'every entry has a pattern, the word to use, a source, an example it catches and one it leaves alone' {
        @($script:terms.bannedPhrases).Count | Should -BeGreaterOrEqual 5
        @($script:terms.phrasalVerbs).Count | Should -BeGreaterThan 10
        foreach ($t in $script:allTerms) {
            $t.pattern | Should -Not -BeNullOrEmpty
            { [regex]::new([string]$t.pattern) } | Should -Not -Throw
            $t.use | Should -Not -BeNullOrEmpty -Because "$($t.pattern) must say what to write instead"
            $t.source | Should -Not -BeNullOrEmpty -Because "$($t.pattern) must say where the rule comes from"
            @($t.examples).Count | Should -BeGreaterThan 0 -Because "$($t.pattern) needs a sentence it must catch"
            @($t.allowed).Count | Should -BeGreaterThan 0 -Because "$($t.pattern) needs a sentence it must not catch"
            # An exception is a name somebody else gave. Each one is proven by
            # an allowed sentence that holds it, and the pattern must match the
            # exception itself, or the exception is not needed.
            foreach ($x in @($t.except | Where-Object { $_ })) {
                (@($t.allowed) -join "`n") | Should -Match ([regex]::Escape($x)) -Because "the exception '$x' needs an allowed sentence"
                $x | Should -Match ([string]$t.pattern) -Because "an exception the pattern never matches is not one"
            }
        }
    }

    It 'is seeded from the item: each invented term and each phrasal verb the lab found' {
        $said = @($script:allTerms | ForEach-Object { @($_.examples) }) -join "`n"
        foreach ($seen in 'general capacity', 'accelerated hardware', 'new hardware', 'new disk hardware', 'The tool',
                          'Tidying up', 'Winding', 'ended up', 'left behind', 'going back to') {
            $said | Should -Match ([regex]::Escape($seen)) -Because "the lab saw '$seen' on the install"
        }
    }

    It 'catches every example, and names the word to use' {
        $examples = @($script:allTerms | ForEach-Object { @($_.examples) })
        $r = & $script:probeRun $examples
        for ($i = 0; $i -lt $examples.Count; $i++) {
            $hit = @($r.Findings | Where-Object { $_.Id -eq "probe.html:s$i" -and $_.Rule -in 'banned-term', 'phrasal-verb' })
            $hit.Count | Should -BeGreaterThan 0 -Because "'$($examples[$i])' must be a finding"
            $hit[0].Detail | Should -Match 'write ' -Because 'a finding says what to write instead'
        }
    }

    It 'leaves every allowed sentence alone - a rule that cries wolf is ignored' {
        $allowed = @($script:allTerms | ForEach-Object { @($_.allowed) })
        $r = & $script:probeRun $allowed
        $wrong = @($r.Findings | Where-Object { $_.Rule -in 'banned-term', 'phrasal-verb' } |
            ForEach-Object { "$($allowed[[int]($_.Id -replace '^probe\.html:s', '')]) -> $($_.Detail)" })
        $wrong -join "`n" | Should -BeNullOrEmpty
    }

    It 'reads the string literals of the engine, the service and the engine start script, and never their comments' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-steengine-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $priv = Join-Path $fake 'src' 'VmMigrationFactory' 'Private' 'capacity'
            $facade = Join-Path $fake 'src' 'facade' 'FacadeCore'
            $docker = Join-Path $fake 'docker'
            $dash = Join-Path $fake 'src' 'dashboard'
            foreach ($d in $priv, $facade, $docker, $dash) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $priv 'Probe.ps1'), @'
# These machines move on general capacity, which this comment may say.
function Get-Probe {
    <# .SYNOPSIS The tool tidies up the disk. #>
    $n = 2
    Write-Host "$n machines move on general capacity."
    'Tidying up the disk.'
    "$(if ($n -eq 1) { 'one machine' } else { 'two machines' }) moves on general capacity."
}
'@)
            [System.IO.File]::WriteAllText((Join-Path $facade 'FacadeCore.psm1'), "function F { throw 'The tool cannot read it.' }")
            [System.IO.File]::WriteAllText((Join-Path $docker 'entrypoint.ps1'), "Write-Host 'reserve: every machine moves on general capacity'")
            [System.IO.File]::WriteAllText((Join-Path $dash 'probe.js'), "// the tool says general capacity`nconst x = ""Winding a capacity reservation down to zero, isn't it"";")

            $sources = @(& $script:tool -Path $fake -ListSources 6>$null)
            ($sources -match '^engine-strings\s') | Should -Match '\b6 string' -Because 'five PowerShell strings and one script string: no comment, and a string inside a string is read with it'
            $r = & $script:tool -Path $fake -Source 'engine-strings' 6>$null
            $ids = @($r.Findings | ForEach-Object { "$($_.Id) $($_.Rule)" })
            $ids | Should -Contain 'src/VmMigrationFactory/Private/capacity/Probe.ps1:5 banned-term'
            $ids | Should -Contain 'src/VmMigrationFactory/Private/capacity/Probe.ps1:6 phrasal-verb'
            $ids | Should -Contain 'src/VmMigrationFactory/Private/capacity/Probe.ps1:7 banned-term'
            $ids | Should -Contain 'src/facade/FacadeCore/FacadeCore.psm1:1 banned-term'
            $ids | Should -Contain 'docker/entrypoint.ps1:1 banned-term'
            $ids | Should -Contain 'src/dashboard/probe.js:2 phrasal-verb'
            @($r.Findings | Where-Object { $_.Id -match 'Probe\.ps1:(1|3)$' }) | Should -BeNullOrEmpty -Because 'a comment and the help are never shown'
            @($r.Findings | Where-Object { $_.Id -match 'probe\.js:1$' }) | Should -BeNullOrEmpty -Because 'a comment is never shown'
            @($r.Findings | Where-Object { $_.Rule -notin 'banned-term', 'phrasal-verb' }) | Should -BeNullOrEmpty -Because 'engine strings answer to the term rules only, not the sentence rules'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'MANUAL-REVIEW-1: is seeded with the catch list - a bare reservation, a lab word, a region and a lab resource group' {
        # Since 2026-11-12: the term is "on-demand capacity reservation", never
        # "reservation" alone; no lab numbers, lab names or regions in shipped
        # docs. Both have a shape, so the gate holds them.
        $said = @($script:allTerms | ForEach-Object { @($_.examples) }) -join "`n"
        foreach ($seen in 'A reservation holds', 'reservation group', 'rg-vmf-lab', 'centralus', 'Central US', 'No lab run', 'The drill') {
            $said | Should -Match ([regex]::Escape($seen)) -Because "the catch list names '$seen'"
        }
        $allowed = @($script:allTerms | ForEach-Object { @($_.allowed) }) -join "`n"
        foreach ($kept in 'An on-demand capacity reservation', 'The capacity reservation group', 'Azure Reservations', 'label') {
            $allowed | Should -Match ([regex]::Escape($kept)) -Because "'$kept' is Azure's own name, or no lab word"
        }
    }

    It 'MANUAL-REVIEW-1: reads a table row of a manual page for the term rules, and the sentence rules leave it alone' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stetable-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dir = Join-Path $fake 'docs' 'manual' 'reference'
            foreach ($d in $dir, (Join-Path $fake 'src' 'dashboard')) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $long = (1..40 | ForEach-Object { 'word' }) -join ' '
            [System.IO.File]::WriteAllText((Join-Path $dir 'probe.md'), (@(
                '# Probe', '', '| Limit | Value |', '|---|---|',
                '| Capacity | A reservation holds capacity for the wave. |',
                "| Long | $long. |", '') -join "`n"))
            $r = & $script:tool -Path $fake -Source 'manual/reference/probe.md' 6>$null
            @($r.Findings | Where-Object { $_.Id -eq 'probe.md:5' -and $_.Rule -eq 'banned-term' }).Count | Should -Be 1 -Because 'a term in a table is still a term'
            @($r.Findings | Where-Object { $_.Id -eq 'probe.md:6' }) | Should -BeNullOrEmpty -Because 'a table row is not a sentence'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'MANUAL-REVIEW-1: a rawText rule reads code and fenced code on a manual page, and gives one finding for a line' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-steraw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dir = Join-Path $fake 'docs' 'manual' 'technical'
            foreach ($d in $dir, (Join-Path $fake 'src' 'dashboard')) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $dir 'probe.md'), (@(
                '# Probe', '',
                'Open `rg-vmf-lab` in the portal.', '',
                '```', 'az group show --name rg-vmf-drill-1', '```', '',
                'The engine ran in Central US.', '',
                'A reservation holds capacity for the wave.', '') -join "`n"))
            $r = & $script:tool -Path $fake -Source 'manual/technical/probe.md' 6>$null
            $hits = @($r.Findings | Where-Object Rule -EQ 'banned-term')
            @($hits | Where-Object Id -EQ 'probe.md:3').Count | Should -Be 1 -Because 'inline code is read as written'
            @($hits | Where-Object Id -EQ 'probe.md:6').Count | Should -Be 1 -Because 'fenced code is read as written'
            @($hits | Where-Object Id -EQ 'probe.md:9').Count | Should -Be 1 -Because 'a sentence gives one finding, from its raw line only'
            @($hits | Where-Object Id -EQ 'probe.md:11').Count | Should -Be 1 -Because 'a rule with no rawText reads the sentence'
            # A paragraph's sentence item takes the line number where it ends, so a
            # second finding from it would not share an Id with the raw line.
            $hits.Count | Should -Be 4 -Because 'one finding for each line, never one from the raw line and one from the sentence'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    # MANUAL-REVIEW-1 area B: the list ends empty. Areas A, C and D rewrote
    # their files and B cleared what was left, so a waiver now would only hide
    # a finding. The tool still reads the key, so a later review can use it.
    It 'MANUAL-REVIEW-1: the pending list of ste-terms.json is empty' {
        $script:terms.PSObject.Properties.Name | Should -Contain 'pending'
        $left = @($script:terms.pending | Where-Object { $_ })
        $left.Count | Should -Be 0 -Because "a waiver hides a finding: fix the text, then remove the entry ($(@($left | ForEach-Object { "$($_.source) $($_.idPrefix)" }) -join '; '))"
    }

    # The mechanism, against a copy of the tool beside a terms file that holds
    # one entry - the real list is empty (above).
    It 'MANUAL-REVIEW-1: a pending entry waives its own source only, and reports what it waived' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stepend-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $dir = Join-Path $fake 'docs' 'manual' 'use'
            $toolDir = Join-Path $fake 'tools'
            $unitDir = Join-Path $fake 'tests' 'unit'
            foreach ($d in $dir, (Join-Path $fake 'src' 'dashboard'), $toolDir, $unitDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            Copy-Item $script:tool $toolDir
            Copy-Item (Join-Path $script:repoRoot 'tests' 'unit' '_*.ps1') $unitDir
            $rule = $script:terms.bannedPhrases | Where-Object { $_.pattern -match 'reservations' } | Select-Object -First 1
            $rule | Should -Not -BeNullOrEmpty
            $copy = Get-Content $script:termsFile -Raw | ConvertFrom-Json
            $copy.pending = @([pscustomobject]@{ source = 'manual/use/capacity.md'; idPrefix = ''; pattern = $rule.pattern; owner = 'test' })
            [System.IO.File]::WriteAllText((Join-Path $toolDir 'ste-terms.json'), ($copy | ConvertTo-Json -Depth 20))
            foreach ($n in 'capacity.md', 'other.md') {
                [System.IO.File]::WriteAllText((Join-Path $dir $n), "# Probe`n`nA reservation holds capacity for the wave.`n")
            }
            $fakeTool = Join-Path $toolDir 'Test-SimplifiedEnglish.ps1'
            $r = & $fakeTool -Path $fake -Source 'manual/use/capacity.md' 6>$null
            $r.Count | Should -Be 0
            @($r.Waived | Where-Object { $_.Source -eq 'manual/use/capacity.md' }).Count | Should -Be 1
            $r = & $fakeTool -Path $fake -Source 'manual/use/other.md' 6>$null
            @($r.Findings | Where-Object Rule -EQ 'banned-term').Count | Should -Be 1 -Because 'the waiver names one page, not every page'
        }
        finally { if (Test-Path $fake) { Remove-Item $fake -Recurse -Force } }
    }

    It 'MANUAL-REVIEW-1: every pending entry still waives a finding - the owner removes it with the fix' {
        foreach ($p in @($script:terms.pending)) {
            $p.owner | Should -Not -BeNullOrEmpty
            $used = @($script:result.Waived | Where-Object {
                    $_.Source -eq $p.source -and $_.Pattern -eq $p.pattern -and
                    (-not $p.idPrefix -or $_.Id.StartsWith([string]$p.idPrefix, [StringComparison]::Ordinal)) })
            $used.Count | Should -BeGreaterThan 0 -Because "the entry for $($p.source) $($p.idPrefix) waives nothing now: remove it"
        }
    }

    It 'the real engine strings are read, and there are many' {
        $line = @(& $script:tool -ListSources 6>$null) -match '^engine-strings\s'
        [int]([regex]::Match([string]$line, '(\d+) string').Groups[1].Value) | Should -BeGreaterThan 2000
    }
}

Describe 'STE-1: one vocabulary, not eight copies' {

    It 'no test file carries its own banned-word list' {
        # Six copies lived in Dashboard.Tests.ps1 alone, and they had already
        # drifted from each other - one banned 'ETag', another had never heard
        # of it. A rule with eight copies is eight rules.
        $hits = foreach ($f in Get-ChildItem (Join-Path $script:repoRoot 'tests') -Filter '*.Tests.ps1' -Recurse) {
            if ($f.Name -eq 'SimplifiedEnglish.Tests.ps1') { continue }
            $text = (Get-VmfPageSource -Path $f.FullName)
            if ($text -match "banned\s*=\s*@?\(?\s*'") { $f.Name }
        }
        $hits -join ', ' | Should -BeNullOrEmpty -Because 'the vocabulary lives in tools/Test-SimplifiedEnglish.ps1'
    }

    # PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its own
# runners (tools/Initialize-VmfCiRunner.ps1). Neither ships, and the public workflows are
# different files, so there this is skipped.
    It 'and CI runs the sweep' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match 'Test-SimplifiedEnglish' -Because 'wording drifts back the moment nothing checks it'
    }
}
