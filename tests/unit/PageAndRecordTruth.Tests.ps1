#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-M10, M13, M14, L3 and L4 - five places where what is written down and
# what is true had drifted apart.
#
# M13 waves.html's help adapter called blobJson, a function that exists only on
#     the wizard. On this page it is a ReferenceError, so "Get help" produced
#     an empty bundle or none at all - from the page somebody is most likely to
#     be stuck on. And help.js compounded it: its per-file .catch() only helps
#     if readJson RETURNED a promise, so a synchronous throw took the whole
#     bundle with it.
# M14 reports.html read openRunId from the URL once and never again. Reports is
#     reached without a ?run= nearly every time, so opening a row - which IS
#     choosing a run - left help with nothing to build for.
# M10 WAVE-2 deleted rings. The wizard still offered "one wave per risk level",
#     kept a dead string about "the risk level below", and rendered an empty
#     <div id="g-ring"> that a sync() function was still toggling.
# L3  assessment.gen is null whenever Azure did not report the generation - a
#     machine deallocated at discovery - which Rules.ps1 handles deliberately.
#     The contract declared it required and enum V1/V2, so those plans were
#     invalid against their own schema.
# L4  Confirm-VmfWaveOptions wrote runId from $plan.runId. A plan has no runId;
#     the field is assessmentRunId. Every acceptance recorded an empty string.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:dashDir = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:help = Get-Content (Join-Path $script:dashDir 'help.js') -Raw
    $script:reports = (Get-VmfPageSource -Path (Join-Path $script:dashDir 'reports.html'))
    $script:wizard = (Get-VmfPageSource -Path (Join-Path $script:dashDir 'wizard.html'))

    # Shared: pull the VmfHelp.install({...}) object out of a page by matching
    # braces, and strip comments. A regex that stops at the first '});' swallows
    # whatever follows, and a test that reads its own explanatory comments finds
    # the very word it is asserting is absent.
    function Script:HelpAdapter([string]$Text) {
        $i = $Text.IndexOf('VmfHelp.install({')
        # PAGE-LOAD-2: the Migrations page builds its adapter in a named function.
        if ($i -lt 0) { $i = $Text.IndexOf('function helpAdapter() {'); if ($i -ge 0) { $i = $Text.IndexOf('return {', $i) } }
        if ($i -lt 0) { return $null }
        $start = $Text.IndexOf('{', $i)
        $depth = 0
        for ($j = $start; $j -lt $Text.Length; $j++) {
            if ($Text[$j] -eq '{') { $depth++ }
            elseif ($Text[$j] -eq '}') { $depth--; if ($depth -eq 0) { break } }
        }
        $body = $Text.Substring($start, $j - $start + 1)
        (Get-VmfCodeOnly -Language CStyle -Text $body)
    }
}

Describe 'EVAL-M13: every page''s help adapter calls functions that page has' {
    It 'no adapter names a helper its own page does not define' {
        # Derived, because the defect was a copy-paste between two pages whose
        # blob readers happen to have different names.
        $browserGlobals = @('fetch', 'Promise', 'String', 'Number', 'Boolean', 'Date', 'JSON', 'Array',
                            'Object', 'Error', 'setTimeout', 'encodeURIComponent', 'decodeURIComponent',
                            'URLSearchParams', 'map', 'filter', 'slice', 'split', 'join', 'catch', 'then',
                            'async', 'await', 'if', 'for', 'while', 'switch', 'return', 'typeof')
        $offenders = foreach ($page in (Get-ChildItem $script:dashDir -Filter '*.html')) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $adapter = Script:HelpAdapter $text
            if (-not $adapter) { continue }
            $called = @([regex]::Matches($adapter, '(?<![.\w$])([a-zA-Z_]\w*)\s*\(') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            foreach ($fn in $called) {
                if ($fn -in $browserGlobals) { continue }
                $defined = $text -match "(?m)^\s*(async\s+)?function\s+$([regex]::Escape($fn))\s*\(" -or
                           $text -match "(?m)(const|let|var)\s+$([regex]::Escape($fn))\s*=" -or
                           $script:help -match "(?m)^\s*(async\s+)?function\s+$([regex]::Escape($fn))\s*\("
                if (-not $defined) { "$($page.Name) help adapter calls '$fn', which that page does not define" }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }

    It 'the extraction really is finding adapters - guard the guard' {
        $found = @(foreach ($page in (Get-ChildItem $script:dashDir -Filter '*.html')) {
            if (Script:HelpAdapter ((Get-VmfPageSource -Path $page.FullName))) { $page.Name }
        })
        @($found).Count | Should -BeGreaterThan 2 -Because 'if this found nothing, the test above proves nothing'
        $found | Should -Contain 'migrations.html' -Because 'its adapter is in helpAdapter()'
    }

    It 'waves.html specifically uses its own reader' {
        $adapter = Script:HelpAdapter ((Get-VmfPageSource -Path (Join-Path $script:dashDir 'waves.html')))
        $adapter | Should -Match 'blobFetch'
        $adapter | Should -Not -Match 'blobJson'
    }
}

Describe 'EVAL-M13: a support bundle degrades to what it could gather' {
    It 'a reader that throws SYNCHRONOUSLY does not take the bundle with it' {
        # .catch() on the result only helps when there IS a result. The typo
        # threw before a promise existed.
        $script:help | Should -Match 'const readOne = async \(rel\) =>'
        # PAGE-LOAD-2: through the one call first, then the adapter, inside the same try.
        $script:help | Should -Match 'try \{ return await readJson\(rel\); \}'
        $script:help | Should -Match 'limit\(\(\) => adapter\.readJson\(run, rel\)\)'
        $script:help | Should -Not -Match 'map\(n => adapter\.readJson\(run, n\)\.catch'
    }

    It 'and the bundle SAYS what it could not read, rather than looking complete' {
        $script:help | Should -Match 'couldNotRead'
        $script:help | Should -Match 'gaps\.push'
    }

    It 'the gap list is collected before anything can push to it' {
        $decl = $script:help.IndexOf('const gaps = []')
        $firstPush = $script:help.IndexOf('gaps.push')
        $decl | Should -BeGreaterThan 0
        $decl | Should -BeLessThan $firstPush
    }
}

Describe 'EVAL-M14: opening a report row is choosing a run' {
    # PAGE-SCALE-REPORTS-1: the name of a migration opens its detail below the
    # list (openDetail), and Close or Escape closes it (closeDetail).
    It 'the row handler records which run is open' {
        $fn = [regex]::Match($script:reports, '(?s)\nfunction openDetail\(run, opener\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match 'openRunId = run'
    }

    It 'and closing it puts the choice back to whatever the URL said' {
        $fn = [regex]::Match($script:reports, '(?s)\nfunction closeDetail\(\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        # RUN-LINK-1: through the one reader of a run's address, as the store spells it.
        $fn | Should -Match 'openRunId = VmfHelp\.VmfRun\.fromQuery\(location\.search\)'
    }

    It 'help on this page asks for the open run' {
        $script:reports | Should -Match 'getRunId: \(\) => openRunId'
    }
}

Describe 'EVAL-M10: nothing in the dashboard still speaks of rings' {
    It 'no page offers a risk level' {
        $offenders = foreach ($f in (Get-ChildItem $script:dashDir -Include '*.html', '*.js' -Recurse)) {
            if ($f.Name -like '*.min.js') { continue }
            if (((Get-VmfPageSource -Path $f.FullName)) -match '(?i)risk level') { $f.Name }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'WAVE-2 removed rings; waves are customer-named'
    }

    It 'the all-at-once option describes what it actually does' {
        # singleWave puts EVERY machine in one wave (Planner: "everything in
        # one wave, no size cap"). The label said "one wave per risk level".
        $script:wizard | Should -Match 'gSingle:'
        # The substance: EVERY machine, ONE wave, no size cap - not the
        # sentence that says it.
        $m = [regex]::Match($script:wizard, "gSingle:\s*'([^']*)'")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '(?i)one wave'
        $m.Groups[1].Value | Should -Match '(?i)every machine'
        $m.Groups[1].Value | Should -Match '(?i)no size limit'
        $m.Groups[1].Value | Should -Not -Match '(?i)ring'
    }

    It 'the empty ring container and its toggle are gone' {
        $script:wizard | Should -Not -Match 'g-ring'
    }

    It 'and no dead ring string is left behind' {
        $script:wizard | Should -Not -Match 'tagNoneRing'
        $script:reports | Should -Not -Match 'wRing'
    }
}

Describe 'EVAL-L3: a generation Azure did not report is a valid plan' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:planSchema = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        $script:schema = Get-Content $script:planSchema -Raw | ConvertFrom-Json
    }

    It 'the contract admits null, because the assessment produces it' {
        @($script:schema.properties.assessment.properties.gen.enum) | Should -Contain $null
    }

    It 'an entry for a machine deallocated at discovery validates' {
        $entry = [ordered]@{
            schemaVersion = (InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion })
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            wave = 'w1'; path = 'A'
            assessment = [ordered]@{
                classification = 'ReadyAfterPrep'; gen = $null; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                prepNeeded = @('verify-generation')
            }
            target = [ordered]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            policy = [ordered]@{ onDDataFound = 'stop' }
        }
        Test-Json -Json ($entry | ConvertTo-Json -Depth 20) -SchemaFile $script:planSchema -ErrorAction Stop |
            Should -BeTrue
    }

    It 'the assessment still asks a person to check it, rather than guessing' {
        $rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
        $rules | Should -Match "verify-generation"
        # It must never resolve towards V2: Gen1 is a hard blocker.
        $rules | Should -Not -Match "else \{ 'V2' \}"
    }

    It 'the writer and the version gate read the same declaration' {
        $writer = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $writer | Should -Match 'schemaVersion = Get-VmfPlanSchemaVersion'
        $declared = InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion }
        $script:schema.properties.schemaVersion.const | Should -Be $declared
    }
}

Describe 'EVAL-L4: an acceptance records which run it belongs to' {
    BeforeEach {
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-acc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'acc-test' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 20 -Document ([ordered]@{
                schemaVersion = 4; assessmentRunId = 'acc-test'
                entries = @([ordered]@{ schemaVersion = (Get-VmfPlanSchemaVersion); vmId = $vm; wave = 'w1'; path = 'A'
                    policy = [ordered]@{ onDDataFound = 'stop'; capacityGate = 'BestEffort' } }) })
        }
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'writes the run it came from, not an empty string' {
        Confirm-VmfWaveOptions -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') `
            -Wave 'w1' -AcceptedBy 'sam@contoso.com' -Confirm:$false | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Read-VmfStoreJson -RunPath $rp -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave 'w1') }
        $doc.runId | Should -Be 'acc-test'
        $doc.runId | Should -Not -BeNullOrEmpty
    }

    It 'the record it writes satisfies its own contract' {
        Confirm-VmfWaveOptions -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') `
            -Wave 'w1' -AcceptedBy 'sam@contoso.com' -Confirm:$false | Out-Null
        $raw = Get-Content (Join-Path $script:run (InModuleScope VmMigrationFactory { Get-VmfWaveOptionsAcceptancePath -Wave 'w1' })) -Raw
        Test-Json -Json $raw -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') `
            -ErrorAction Stop | Should -BeTrue
    }

    It 'and the contract now REFUSES the blank identity it used to permit' {
        # runId was the one optional, unconstrained field while every
        # neighbour carried a minLength or a pattern. That is what let a
        # record which cannot say what it belongs to look valid.
        $bad = @{
            schemaVersion = 2; runId = ''; wave = 'w1'; acceptedBy = 'sam@contoso.com'
            acceptedUtc = '2026-08-29T00:00:00Z'; machineCount = 1; optionsHash = ('a' * 64)
            levers = @(@{ onDDataFound = 'stop' })
        } | ConvertTo-Json -Depth 8
        { Test-Json -Json $bad -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') -ErrorAction Stop } |
            Should -Throw
    }

    It 'a plan that cannot say which run it came from is refused, not recorded blank' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'orphan.json' -Depth 20 -Document ([ordered]@{
                schemaVersion = 4; assessmentRunId = ''
                entries = @([ordered]@{ schemaVersion = (Get-VmfPlanSchemaVersion); vmId = $vm; wave = 'w1'; path = 'A'
                    policy = [ordered]@{ onDDataFound = 'stop' } }) })
        }
        { Confirm-VmfWaveOptions -RunPath $script:run -PlanPath (Join-Path $script:run 'orphan.json') `
            -Wave 'w1' -AcceptedBy 'sam@contoso.com' -Confirm:$false } |
            Should -Throw '*does not say which assessment run*'
    }

    It 'and matches what the sibling approval writer records' {
        # They write the same fact about the same plan; one of them was wrong.
        $accept = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Confirm-VmfWaveOptions.ps1') -Raw
        $approve = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Approve-VmfWave.ps1') -Raw
        $accept | Should -Match '\$plan\.assessmentRunId'
        $approve | Should -Match '\$plan\.assessmentRunId'
    }
}
