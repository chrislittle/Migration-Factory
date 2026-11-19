#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ODCR-BUTTON-1 - the page that asks for a reservation can make one.
#
# The reservation worked, but no screen offered it. The wave plan does offer
# the choice - the capacity lever has lived on the wave plan for days. What was missing was the
# ACTION beside the choice, so an operator picked "on-demand capacity
# reservation", saved, and then found a wave that refused to start with no
# control anywhere that would fix it.
#
# The gap was never in the engine. New-VmfWaveReservation has created the
# group and the reservation since CAPRG-1 on 2026-08-30, the facade has
# accepted the operation behind a spend guard, and the hosted engine has
# dispatched it. Every part existed except the button.
#
# WHY REACHABILITY DID NOT CATCH IT: `Reachability.Tests` defines the app
# surface as the facade plus the hosted engine, and by that definition the
# command was reachable. To the operator it was not. An operation the facade
# accepts and no screen offers is a PowerShell command with extra steps.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:waves    = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
    $script:facade   = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:startWv  = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
    $script:capOps   = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1') -Raw
    $script:runway   = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1') -Raw
    $script:claimSch = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw

    # CODE, not text. A rule that greps the raw file is satisfied by a line
    # somebody commented out - both of the assertions below passed with the
    # call commented out until this was added, which mutation-testing found and
    # reading never would.
    function Remove-Comments([string]$Text) {
        (($Text -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
    $script:capOpsCode = Remove-Comments $script:capOps
    $script:runwayCode = Remove-Comments $script:runway
    $script:wavesCode  = Remove-Comments ($script:waves -replace '(?m)^\s*//.*$', '')
}

Describe 'ODCR-VERIFY-1: Reserved means Azure confirmed it' {

    It 'the engine waits for a terminal provisioningState' {
        # An ODCR can complete or fail, as Azure decides, and the code assumed
        # it worked. That was an assumption.
        #
        # THE ASSUMPTION TURNED OUT TO BE CORRECT. Measured against Azure on
        # 2026-09-02 (tests/lab/Invoke-OdcrDrill.ps1): the Az cmdlet BLOCKS
        # until provisioningState is terminal, returning Succeeded after ~34s.
        # So this wait is insurance rather than a repair, and the code it
        # replaced was very likely fine on this path.
        #
        # The rule stays because the guarantee should be explicit and costs one
        # API call - an Az version, size or region that returned early would
        # otherwise write RESERVED for nothing. It does NOT stay on a story
        # about a defect that the evidence does not support.
        $script:capOpsCode | Should -Match 'function Wait-VmfReservationProvisioned'
        $script:capOpsCode | Should -Match "ProvisioningState"
        $script:capOpsCode | Should -Match "\`$last -eq 'Succeeded'"
        $script:capOpsCode | Should -Match "'Failed', 'Canceled'"
    }

    It 'and it is called before the ids are handed back' {
        # Single-quoted: $ is already literal in PowerShell, so the regex
        # escape is \$ and a backtick here would look for a literal backtick.
        $script:capOpsCode | Should -Match '(?s)Wait-VmfReservationProvisioned.*?GroupId = \[string\]\$group\.Id'
    }

    It 'and it throws rather than returning, so the claim lands on BLOCKED' {
        # Throwing is the design: the runway already catches and writes
        # BLOCKED with reservation-failed, so a reservation that never
        # provisions ends in the state that exists for it.
        $script:capOps | Should -Match 'The capacity was not held'
        $script:runway | Should -Match "'BLOCKED'"
        $script:runway | Should -Match "'reservation-failed'"
    }

    It 'the docstring no longer claims creation is the guarantee' {
        $script:capOps | Should -Not -Match 'Creation succeeding IS the capacity guarantee'
    }
}

Describe 'ODCR-VERIFY-1: and there is a state for while it is happening' {

    It 'capacity-claim v7 has RESERVING' {
        # The pill should show pending, then reserved, while the CRG is
        # created. It did not - there was no in-flight state at all.
        $script:claimSch | Should -Match '"const": (7|8|9|[1-9]\d)'
        $script:claimSch | Should -Match '"RESERVING"'
    }

    It 'the runway writes it BEFORE it calls Azure, and persists it' {
        # In memory would not survive the thing it exists for: a page reload in
        # somebody else's browser during the minutes Azure takes.
        # RESERVING-STUCK-1: written with its version, so a second run cannot.
        $script:runwayCode | Should -Match "(?s)\`$claim\.state = 'RESERVING'.*?Write-VmfClaimIfVersion.*?try \{"
        $script:runwayCode | Should -Match 'reservingSinceUtc'
        $script:runwayCode | Should -Match "-Outcome start"
    }

    It 'the page shows it, and offers no button while it runs' {
        # A reload used to bring the Reserve button back, and a second press
        # would have paid twice for one guarantee.
        $script:waves | Should -Match "st === 'working'"
        $script:waves | Should -Match 'reserveWorking:'
        $script:waves | Should -Match "st === 'blocked'"
        $script:waves | Should -Match 'reserveBlocked:'
    }

    It 'and the worst claim in a wave decides what the wave shows' {
        # A wave has one claim per size and zone. One still creating means the
        # wave is not reserved; one blocked means it is not going to be.
        $script:waves | Should -Match 'VmfHelp\.claimBlocked\(st\)'
        $script:waves | Should -Match "\['blocked', 'unconfirmed'\]\.includes\(claims\.get\(d\.wave\)\)"
    }

    It 'the demo stages the sequence rather than answering instantly' {
        # A demo that answers in 500ms teaches that the real one does.
        $script:waves | Should -Match "demoState\.set\(wave, 'working'\)"
        $script:waves | Should -Match "setTimeout\(\(\) => demoState\.set\(wave, 'held'\), 6000\)"
    }
}

Describe 'ODCR-BUTTON-1: the control is where the choice is' {

    It 'the wave plan offers it, on the wave, next to the capacity lever' {
        $script:waves | Should -Match 'data-reserve='
        $script:waves | Should -Match 'reserveBtn:\s*''Reserve capacity'''
        # Beside the lever it belongs to, not in a corner of the page: the
        # control is rendered inside the same label as the capacity select.
        $script:waves | Should -Match '(?s)data-cap=.{0,500}?reserveControl'
        $script:waves | Should -Match 'function reserveControl'
    }

    It 'and only when that wave actually asked for a reservation' {
        # A reserve button on a wave set to standard allocation would offer to
        # spend money on something nobody asked for.
        $script:waves | Should -Match "capNow !== 'Reserved'"
    }

    It 'and only to somebody who may edit the plan' {
        # WAVE-EDIT-RESERVE-1: also shown for a wave that HOLDS a reservation
        # whatever its setting now reads, so it can be released - but still only
        # to somebody who may edit.
        $script:waves | Should -Match "!canEdit \|\| \(capNow !== 'Reserved' && !billingWaves\.has\(name\)\)"
    }

    It 'it posts the operation the facade already accepts' {
        $script:waves | Should -Match 'engine/reserve'
        $script:facade | Should -Match "'reserve', 'release'"
    }
}

Describe 'ODCR-BUTTON-1: and it fits where it is put' {

    It 'the control is STACKED under its lever, not placed beside it' {
        # A screenshot showed the button out of place.
        #
        # It was in the `.keep` wrapper, which lays a control BESIDE the select.
        # That works for the generation lever, whose select is "v6" wide. The
        # capacity select says "On-demand capacity reservation", so the pair
        # overflowed a minmax(215px,1fr) grid cell into the lever next to it and
        # the button was half-covered.
        #
        # AND THE CHECK I RAN MISSED IT: scrollWidth > clientWidth asks whether
        # an element clips its OWN text. It cannot see an element overflowing
        # its grid cell, which is what was happening. The right question is
        # whether the control stays inside its cell.
        $script:waves | Should -Match 'data-reserve=[^>]*class=|class="[^"]*lever-act[^"]*"[^>]*data-reserve='
        $script:waves | Should -Match 'lever-act'
        # The capacity lever must not wrap its select in .keep again.
        $script:waves | Should -Not -Match '(?s)<span class="keep">\s*<select data-cap'
    }

    It 'and the stacking rule lives in the stylesheet, sized not to stretch' {
        $css = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'app.css') -Raw
        $css | Should -Match '\.p-waves \.wave \.levers \.lever-act \{[^}]*align-self:flex-start'
    }
}

Describe 'ODCR-BUTTON-1: it spends money, so it behaves like it' {

    It 'it asks first, and says what it will cost' {
        # The message has to carry the fact that billing starts immediately,
        # because that is the part somebody would not otherwise expect: the
        # reservation bills whether the wave runs or not.
        $script:waves | Should -Match 'reserveAsk:'
        $script:waves | Should -Match 'Azure bills it from the moment it is reserved'
        $script:waves | Should -Match 'whether the wave runs or not'
    }

    It 'Cancel and Escape both do nothing at all' {
        # RULE 11 - anything that opens must offer a way back. POPUP-1 moved
        # the question from a browser prompt box into the page: the shared
        # control (VmfHelp.confirmInPlace) offers Cancel and Escape, and the
        # request runs only from its Yes.
        $script:waves | Should -Match '(?s)function reserveCapacity\(wave, btn\) \{.*?VmfHelp\.confirmInPlace\(btn'
        # ROLE-REMOVE-CONFIRM-1: the options may also say where the question goes.
        $script:waves | Should -Match 'cancel: UX\.cancel(, under: ''[^'']+'')? \}, \(note\) => reserveCapacityNow\(wave, btn, note\)'
    }

    It 'and a note is required, because the facade requires one' {
        # Not politeness: the facade throws 400 without it, so a caller that
        # did not ask would produce an error the operator cannot act on. The
        # control refuses an empty answer beside the field (required: true).
        $script:waves | Should -Match 'reserveNoNote:'
        $script:waves | Should -Match 'field: \{ placeholder: UX\.reserveNoteHint, required: true, missing: UX\.reserveNoNote \}'
        $script:facade | Should -Match 'reserving capacity bills from the moment it is reserved'
    }

    It 'it refuses while the plan has unsaved changes' {
        # A reservation is sized from the wave AS SAVED. Reserving against
        # unsaved levers would hold capacity for a shape that does not exist,
        # and the money would be real either way.
        $script:waves | Should -Match 'const dirty = \(\) => snapshot\(\) !== original;'
        $script:waves | Should -Match "dirty\(\) \? .{0,24}disabled title="
        $script:waves | Should -Match 'reserveSaveFirst:'
    }
}

Describe 'ODCR-BUTTON-1: it tells the truth about what happened' {

    It 'it reads the CLAIM, not a flag on the plan' {
        # A plan that says reserved and a claim that is not RESERVED is exactly
        # the state this button exists to resolve. A flag on the plan would
        # report the intention and hide the gap.
        $script:waves | Should -Match "\['RESERVED', 'CONSUMED'\]"
        $script:waves | Should -Match 'async function loadClaims'
    }

    It 'and a failed read shows the button rather than hiding it' {
        # If the claims cannot be read, the safe state is OFFERING the action -
        # hiding it would look identical to "already reserved".
        # WAVE-EDIT-RESERVE-1: the release watch also needs to know the read
        # failed, so it says so rather than taking an empty map as "released".
        # AVSET-RESERVE-1: and the count of machines on general capacity is
        # cleared with them, so a failed read leaves no half-counted wave.
        # QUOTA-CHECK-SPINNER-1: a read builds its state locally and the page takes it at the end, so the
        # failed read returns that cleared state, and loadClaims returns false.
        $script:waves | Should -Match '(?s)catch \(e\) \{ return pack\(false, \{ claims: new Map\(\), billingWaves: new Set\(\), generalByWave: new Map\(\), waveDocs: new Map\(\), lastChecked: new Map\(\) \}\); \}'
        $script:waves | Should -Match '(?s)\(\{ claims, billingWaves, generalByWave, [^}]*waveDocs, lastChecked \} = read\);'
    }

    It 'the POST returning 202 is not treated as a result' {
        # THE DEFECT THIS TEST EXISTS FOR. The first version of this button
        # read Reserved and AllOrNothing out of the reply and announced
        # success. The reply is 202 Accepted and carries neither - the engine
        # runs the reservation in a container afterwards. It was reporting that
        # a job had been ACCEPTED and calling it capacity.
        $script:waves | Should -Not -Match 'AllOrNothing' -Because 'that field is not in a 202 body'
        $script:waves | Should -Match 'reserveStarted:'
        # WATCH-1: renamed. This one watches a capacity CLAIM and reads the
        # event log only as a faster way to hear bad news - a different
        # question from the one the run page and the wizard ask, and sharing
        # their name hid that.
        $script:waves | Should -Match 'await watchReservation\(wave\)'
        $script:waves | Should -Not -Match 'function watchForRefusal'
    }

    It 'and it separates held, nothing-to-reserve, refused and still-running' {
        # New-VmfWaveReservation is ALL OR NOTHING per wave: a run that fails
        # halfway releases what it took, so "no claim" covers both refused and
        # rolled back - which is why the claim, not the reply, is the answer.
        foreach ($k in 'reserveDone', 'reserveNothing', 'reserveFailed', 'reserveSlow') {
            $script:waves | Should -Match "$k`:"
        }
        # A wave of availability-set members has nothing to reserve, and the
        # engine says so in one event with a code rather than by creating a
        # claim. AVSET-RESERVE-1: this pinned the words 'no reservable demand',
        # which only the claim note carried - the page matched nothing the
        # engine wrote, and this test passed. The page's reading is now RUN
        # against the engine's own events (tests/js/reserve-nothing.test.js,
        # tests/fixtures/reserve-nothing-events.json); here, only that the
        # page no longer reads words for it.
        $script:wavesCode | Should -Match "e\.code === 'nothingReservable'"
        $script:waves | Should -Not -Match 'no reservable demand'
    }

    It 'and the engine refusal now names the control instead of a cmdlet' {
        # CLAUDE.md rule 12: never hand back a command to run elsewhere.
        # ODCR-STATE-1 moved the words into Get-VmfReservedCapacityRefusal, so
        # that a test can drive every claim state instead of reading a phrase.
        # Read the CODE, so the explanation in a comment cannot satisfy this.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $refusal = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' `
            'Private' 'capacity' 'ReservedRefusal.ps1')
        # RESERVE-COVER-1 review: the page is called the wave editor everywhere else.
        $refusal | Should -Match 'use Reserve capacity on the wave in the wave editor'
        $refusal | Should -Not -Match 'no screen offers it yet'
        $refusal | Should -Not -Match 'New-VmfWaveReservation'
    }
}
