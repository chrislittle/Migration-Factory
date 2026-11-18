#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Order matters: the activity feed once showed a shutdown and a start with
# the snapshot between them MISSING - which reads as a different sequence
# than the one that ran.
#
# The engine is the source of truth about order, and it is derivable: every
# step returns `Next = '<STATE>'`, and every Azure call is wrapped with
# `Invoke-VmfAzOperation -Name '<op>'`. So instead of trusting that someone
# remembered to update the dashboard, these tests EXTRACT the engine's real
# vocabulary and check the UI against it.
#
# Three ways the UI can lie about order, all of which have happened:
#   1. a state with no label - the raw internal name shows through
#   2. STATE_SEQ disagreeing with the transitions - every progress bar wrong
#   3. an operation with no phrase - the step vanishes from the activity feed
#      and the reader infers the wrong sequence from what is left
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:engine = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    $script:index = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))

    # Every state the engine can actually move a machine into.
    $script:engineStates = @([regex]::Matches($script:engine, "Next\s*=\s*'([A-Z_]+)'") |
        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

    # Every Azure operation name it logs. Interpolated names keep their literal
    # prefix ("getNic:$nicName" -> "getNic:"), which is what the UI matches on.
    $script:engineOps = @([regex]::Matches($script:engine, "Invoke-VmfAzOperation\s+-Name\s+[""']([^""'\$]*)") |
        ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ } | Sort-Object -Unique

    # The dashboard's own vocabulary.
    $script:labelledStates = @([regex]::Matches($script:index, "(?m)^\s{2}([A-Z_]+):\s*\['") |
        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    $script:stateSeq = @()
    if ($script:index -match "const STATE_SEQ = \[([^\]]+)\]") {
        $script:stateSeq = @($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'") })
    }

    # The event-phrase table: pattern text + flags, turned into .NET regexes.
    $script:techPatterns = @([regex]::Matches($script:index, "\[/((?:[^/\\]|\\.)+)/([a-z]*),\s*'([A-Za-z]+)'\]") |
        ForEach-Object {
            [pscustomobject]@{
                Pattern = $_.Groups[1].Value
                Options = $(if ($_.Groups[2].Value -match 'i') { 'IgnoreCase' } else { 'None' })
                Phrase  = $_.Groups[3].Value
            }
        })
}

Describe 'The dashboard knows every state the engine can reach' {
    It 'found the engine states and the labels to compare them with' {
        @($script:engineStates).Count | Should -BeGreaterThan 5
        @($script:labelledStates).Count | Should -BeGreaterThan 5
    }

    It 'every state the engine can move a machine into has a plain-language label' {
        # Without this the raw name appears on screen, which is how
        # SAFETY_PRISTINE reached the screen.
        $unlabelled = @($script:engineStates | Where-Object { $_ -notin $script:labelledStates })
        $unlabelled -join ', ' | Should -BeNullOrEmpty -Because 'each of these would show its internal name to a customer'
    }
}

Describe 'The progress order matches the order the engine actually follows' {
    It 'every step in the meter is a real engine state' {
        $strays = @($script:stateSeq | Where-Object { $_ -notin $script:engineStates -and $_ -ne 'PLANNED' })
        $strays -join ', ' | Should -BeNullOrEmpty -Because 'a step the engine never enters makes the meter stall'
    }

    It 'the meter agrees with the engine about what follows what' {
        # Pull the real transitions out of the engine and check STATE_SEQ is
        # consistent with them: if the engine goes A -> B, the meter must not
        # claim B comes before A. This is what caught the SAFETY-2 reorder,
        # where the meter still had the old GUEST_PREP -> SAFETY_COPY -> STOPPED.
        $order = @{}
        for ($i = 0; $i -lt $script:stateSeq.Count; $i++) { $order[$script:stateSeq[$i]] = $i }

        # transitions on the happy path, taken from the step functions in order
        $happyPath = @(
            @('PRECHECK', 'SAFETY_PRISTINE'),
            @('SAFETY_PRISTINE', 'GUEST_PREP'),
            @('GUEST_PREP', 'STOPPED'),
            @('STOPPED', 'SAFETY_COPY'),
            @('SAFETY_COPY', 'CONVERTING')
        )
        $wrong = @(foreach ($t in $happyPath) {
            $from, $to = $t
            # only judge pairs the engine really has
            if ($script:engine -notmatch "Next\s*=\s*'$to'") { continue }
            if ($order.ContainsKey($from) -and $order.ContainsKey($to) -and $order[$from] -ge $order[$to]) {
                "$from should come before $to"
            }
        })
        $wrong -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Every Azure step the engine logs has words a person can read' {
    It 'found operations and phrase patterns to compare' {
        @($script:engineOps).Count | Should -BeGreaterThan 10
        @($script:techPatterns).Count | Should -BeGreaterThan 10
    }

    It 'no operation falls through unlabelled' {
        # THE one that bit us: the event is named pristineSnapshot, the pattern
        # was a case-SENSITIVE /snapshot/, so the snapshot vanished from the
        # feed - leaving a shutdown followed by a start, which reads as the
        # copy being taken after the restart. An unlabelled step does not just
        # lose detail, it implies a different sequence.
        $unmatched = @(foreach ($op in $script:engineOps) {
            $subject = "azureops:$op"
            $hit = $false
            foreach ($p in $script:techPatterns) {
                if ([regex]::IsMatch($subject, $p.Pattern, $p.Options)) { $hit = $true; break }
            }
            if (-not $hit) { $op }
        })
        $unmatched -join ', ' | Should -BeNullOrEmpty -Because 'each of these would appear in the activity feed with no explanation'
    }
}

Describe 'A machine part-way through counts as started, everywhere' {
    It 'no in-flight state is missing from the wave editor or the wizard' {
        # A state missing here lets someone move a machine into another wave
        # while it is mid-migration - the exact thing WAVE-1 exists to prevent.
        $terminal = @('MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION')
        $inFlight = @($script:engineStates | Where-Object { $_ -notin $terminal -and $_ -ne 'PLANNED' })
        # WAVES-BUTTON-RUNNING-1: the list is VmfHelp.machineStarted in
        # help.js, and the pages ask it - so the list is checked there, and
        # each page is checked to ask it.
        $helpJs = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $rule = [regex]::Match($helpJs, '(?s)function machineStarted\(state\) \{.*?\}').Value
        $rule | Should -Not -BeNullOrEmpty -Because 'help.js holds the started-state rule'
        $missing = @($inFlight | Where-Object { $rule -notmatch "'$_'" })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'the pages would treat these machines as not yet started'
        foreach ($page in 'waves.html', 'wizard.html') {
            $text = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page))
            $text | Should -Match 'VmfHelp\.machineStarted\(' -Because "$page must ask the one rule"
        }
    }
}

Describe 'The put-back explains itself, step by step' {
    # UiTellsTheTruth only ever read the state machine, so every operation in
    # Restore-VmfVm - the safety net, the path an operator watches hardest -
    # fell through to the generic "Azure call" and nobody noticed.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # The put-back: swapping a disk under a live machine. UX-STUCK-1's
        # operations would otherwise fall through to the generic "Azure call"
        # exactly as the restore's did.
        $script:restoreSrc = @(
            (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw),
            # REBUILD-REMOVE-RECOVER-1: Rebuild this machine and the restore that
            # rebuilds are gone; the resume's delete helper is what is left.
            (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RestoreDiskResume.ps1') -Raw)
        ) -join "`n" 
        $script:restoreOps = @([regex]::Matches($script:restoreSrc, "Invoke-VmfAzOperation\s+-Name\s+[""']([^""'\$]*)") |
            ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ } | Sort-Object -Unique
    }

    It 'found the restore operations' {
        @($script:restoreOps).Count | Should -BeGreaterThan 8
    }

    It 'every step of it has words of its own, not the catch-all' {
        # /^azureops:/ matches everything, so "it matched something" proves
        # nothing here - the step has to match a pattern that is ABOUT it.
        $generic = 'azureCall'
        $unexplained = @(foreach ($op in $script:restoreOps) {
            $subject = "azureops:$op"
            $phrase = $null
            foreach ($p in $script:techPatterns) {
                if ([regex]::IsMatch($subject, $p.Pattern, $p.Options)) { $phrase = $p.Phrase; break }
            }
            if (-not $phrase -or $phrase -eq $generic) { $op }
        })
        $unexplained -join ', ' | Should -BeNullOrEmpty -Because 'the put-back is the step an operator reads most closely'
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
}

Describe 'The AUTOMATIC put-back explains itself too (FAIL-1)' {
    # Seen during the FAIL-1 drill run: the activity feed for
    # the rollback showed one line saying "rollback", then "Working with
    # Azure". Meanwhile the engine had swapped the OS disk under the machine
    # and reverted its hardware - the most consequential work in the entire
    # run, rendered as nothing.
    #
    # Two separate causes, both worth guarding:
    #   1. the rollback's ARM calls did not go through the wrapper at all, so
    #      most of them emitted no event to render
    #   2. the ones that did had no phrase, because the map knew `restore:*`
    #      from RESTORE-1 and nothing about `rollback:*`
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:rollbackFn = [regex]::Match($script:engine, '(?s)function Invoke-VmfRollback.*?\n\}').Value
        # ROLLBACK-CAPACITY-1: the start at the end of the rollback, with its
        # tries for an allocation failure, is Start-VmfRollbackVm - read with it.
        $script:rollbackFn | Should -Match '\bStart-VmfRollbackVm\b'
        $startFile = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackStart.ps1') -Raw
        $script:rollbackFn += "`n" + [regex]::Match($startFile, '(?s)function Start-VmfRollbackVm.*?\n\}').Value
        $script:rollbackOps = @([regex]::Matches($script:rollbackFn, "Invoke-VmfAzOperation\s+-Name\s+[""']([^""'\$]*)") |
            ForEach-Object { $_.Groups[1].Value }) | Where-Object { $_ } | Sort-Object -Unique
    }

    It 'found the rollback and its operations' {
        $script:rollbackFn | Should -Not -BeNullOrEmpty
        # REBUILD-REMOVE-ENGINE-1: the Path B rollback's operations (getVmForRollback,
        # detachVerify, deleteShell, recreate) are gone; stop, swapDisk, revertSize
        # and start stay.
        @($script:rollbackOps).Count | Should -BeGreaterOrEqual 4
    }

    It 'EVERY Azure call in the put-back goes through the wrapper' {
        # Cause 1, and it is not only about the feed: the wrapper is also what
        # retries transient failures and renews the lease. A rollback dying on
        # a throttle is the worst possible moment to have neither.
        $bare = @([regex]::Matches($script:rollbackFn,
            "(?m)^\s{4,8}(Stop-VmfVmDeallocated|Set-VmfVmSizeAndController|Start-VmfVm)\b") |
            ForEach-Object { $_.Value.Trim() })
        $bare -join ', ' | Should -BeNullOrEmpty -Because 'an unwrapped call is silent AND unretried'
    }

    It 'every step of it has words of its own, not the catch-all' {
        $generic = 'azureCall'
        $unexplained = @(foreach ($op in $script:rollbackOps) {
            $subject = "azureops:$op"
            $phrase = $null
            foreach ($p in $script:techPatterns) {
                if ([regex]::IsMatch($subject, $p.Pattern, $p.Options)) { $phrase = $p.Phrase; break }
            }
            if (-not $phrase -or $phrase -eq $generic) { $op }
        })
        $unexplained -join ', ' | Should -BeNullOrEmpty
    }

    It 'the put-back says what it is doing in its own words, not its step name' {
        # The literal one-word line the feed showed. `rollback` matched no
        # pattern, so the feed rendered the raw step name.
        $script:index | Should -Match "e\.step === 'rollback' && e\.detail"
        $script:rollbackFn | Should -Match 'Rolling the machine back'
        $script:rollbackFn | Should -Match 'back as it was'
    }

    It 'and it says the disk went back, which is the part nobody could see' {
        $script:rollbackFn | Should -Match 'The operating system disk was restored from the first safety copy'
    }
}

Describe 'A machine that was put back does not still advertise the move (FAIL-1)' {
    It 'a rolled-back row shows where the machine IS, with no arrow' {
        # Second report for this class: the pill read "Restored"
        # while the size column still read "D2s_v4 -> D2s_v6". putBack only
        # recognised a MANUAL restore record, and an automatic rollback writes
        # none - so the row fell through to rendering the plan.
        $script:index | Should -Match "const rolledBack = v\.state === 'FAILED_ROLLED_BACK'"
        $script:index | Should -Match '(?s): rolledBack.{0,600}esc\(liveSize\)'
    }

    It 'and does not claim it reached the target, which is only sometimes true' {
        # "was on <target>" would be a lie for a rollback out of CONVERTING,
        # where the machine never ran on the new size at all.
        $branch = [regex]::Match($script:index, '(?s): rolledBack.*?`\r?\n').Value
        $branch | Should -Not -Match 'sizeWas'
        $branch | Should -Not -Match 'rarr'
    }
}

Describe 'No phrase silently overwrites another' {
    It 'the wording tables have no duplicate keys' {
        # A duplicate key in a JS object literal is not an error - the last one
        # wins, silently. Adding a phrase that already existed elsewhere would
        # quietly REDEFINE the existing one, changing wording on a screen nobody
        # was looking at. Caught while adding the restore phrases.
        foreach ($table in 'UX_STEP', 'UX_MISC', 'UX_STATE') {
            if ($script:index -notmatch "(?s)const $table = \{(.*?)\n\};") { continue }
            $body = $Matches[1]
            $keys = @([regex]::Matches($body, '(?m)^\s{2}([A-Za-z_][A-Za-z0-9_]*)\s*:') | ForEach-Object { $_.Groups[1].Value })
            $dupes = @($keys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            $dupes -join ', ' | Should -BeNullOrEmpty -Because "$table would silently use the last definition"
        }
    }
}

Describe 'The capacity row says each number once' {
    It 'does not repeat the in-use count beside the column that already shows it' {
        # The row read "Reserved 1", then "1 in use", then a column with 1.
        $script:index | Should -Not -Match '\$\{inUse\} \$\{UX_MISC\.reservedInUse\}'
        # RES-LIST-1: the pill counts what is reserved; Details counts in use and idle, once each.
        $script:index | Should -Match 'String\(Math\.max\(0, reservable - used\)\)'
    }

    It 'and only adds words when they say something the numbers do not' {
        $script:index | Should -Match 'fact \? `<span class="muted">'
    }
}

Describe 'A put-back in progress is visible while it happens' {
    # The row sat frozen on "Migrated" for the whole put-back. Nothing writes to
    # the state doc while a restore runs - the machine stays MIGRATED, and it is
    # STOPPED for most of it - so the row could not tell you anything was
    # happening. The events already say so.
    It 'derives it from the events, not from a new state' {
        $script:index | Should -Match 'function restoreInFlight'
        $script:index | Should -Match "e\.step === 'restore'"
    }

    It 'counts the machine as active, so the clock keeps moving' {
        # STATUS-WORDS-1: the one status says Restoring (help.js machineStatus
        # reads the restore found running), and the tiles count it as in
        # progress. tests/js/machine-status.test.js runs both.
        $script:index | Should -Match 'restoring: doc \? restoreInFlight\(vmId \?\? doc\.vmId, doc\) : null'
        $script:index | Should -Match "const RUNNING_STATUS = \[\s*'step', 'rollingBack', 'restoring'"
    }

    It 'says what it is doing right now, not just that it is busy' {
        # SWAP-REFUSED-AFTER-STOP-1: and the rollback's own calls, for Finish the rollback.
        $script:index | Should -Match 'azureops:\(restore\|rollback\):'
        $script:index | Should -Match 'const doing = putting\?\.doing \?\?'
    }

    It 'and stops saying it once the put-back ends' {
        # PUTBACK-GONE-1: the ENDING outcomes close it - ok, warn, fail - and
        # nothing else. "Any non-start outcome" was the rule here, and it was
        # the defect: the engine writes `info` progress under the same step,
        # so the first note switched "Putting back" off mid-restore. A failed
        # put-back still ends, because the engine ends it with warn or fail;
        # tests/js/putback-gone.test.js holds the page to the engine's list.
        #
        # RENDER-1 replaced the two per-row scans with one index built per set
        # of events, so this no longer matches the old ternary. The RULE is
        # unchanged and is now RUN rather than matched:
        # tests/js/restore-index.test.js drives all five closing outcomes, a
        # second restore after the first ended, and the out-of-order case.
        # This keeps a source anchor so the branch cannot quietly disappear.
        # RESTORE-END-LOST-1 review: keyed by the machine without case (vm = VmfHelp.idKey(e.vmId)).
        # RESTORE-ONE-AT-A-TIME-1 review: the start also starts the clock of the
        # newest line (last), which the buttons wait on.
        $script:index | Should -Match "if \(e\.outcome === 'start'\) \{ open\.set\(vm, e\); last\.set\(vm, e\.tsUtc\); \}"
        $script:index | Should -Match 'else if \(RESTORE_ENDS\.includes\(e\.outcome\)\) \{ open\.delete\(vm\); doing\.delete\(vm\); \}'
    }

    It 'has words for it' {
        $script:index | Should -Match 'puttingBack:'
        $script:index | Should -Match 'puttingBackTip:'
    }
}

Describe 'The size column does not assert an answer it does not have yet' {
    It 'shows the size greyed while a put-back is in flight, with no word after it' {
        # sizeAfter is only written when the restore FINISHES, so for the whole
        # several-minute put-back this column kept stating the new size as fact.
        # WAVE-ROW-WORDS-1: the word "changing" went - the Restoring pill says
        # it - and the size stays greyed.
        $script:index | Should -Not -Match 'sizeChanging'
        # STATUS-WORDS-1: while the status says the machine changes - a
        # restore, a finish or a rollback (OLD-REBUILD-RESTORE-READERS-1: no rebuild).
        $script:index | Should -Match "(?s): \['restoring', 'finishing', 'rollingBack'\]\.includes\(st\.key\)\s*\r?\n(\s*//[^\r\n]*\r?\n)*\s*\? ``<span class=`"mono muted`">\`$\{esc\(liveSize\)\}</span>``"
    }
}
