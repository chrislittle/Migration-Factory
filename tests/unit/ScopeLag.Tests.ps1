#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE-LAG-1, 2026-09-19. The WIRING half.
#
# tests/js/scope-lag.test.js drives scopeRowsWithLag through every combination,
# and that is the logic. It says nothing about whether anything ever CALLS the
# recorder - and mutation proved it: deleting the call in the grant path left
# all ten of those tests passing while the fix did nothing at all.
#
# The logic is tested and the call site is not is a hole with a shape, and this
# file is the other half of it.
#
# Read through Get-VmfCodeOnly, so a comment explaining the mechanism cannot
# satisfy a check about the mechanism.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html') -Language CStyle
}

Describe 'SCOPE-LAG-1: the page records what it just did' {

    It 'the grant keeps the assignment Azure returned, instead of discarding it' {
        # The 201 body IS Azure confirming the grant. The page used to throw it
        # away and ask a list that would not mention it for a minute or two.
        # ACCESS-HALF-1 made the grant a LOOP over both halves of the product,
        # so the single `const created = await arm('PUT'` line is gone. What it
        # protected is not: Azure's own answer for the ENGINE grant is kept and
        # used, rather than thrown away for a list that lags behind.
        $script:code | Should -Match "const madeOne = await arm\('PUT'"
        $script:code | Should -Match 'created = madeOne'
        # ACCESS-LAG-WORDS-1: one record for the grant, naming both halves.
        $script:code | Should -Match "scopeLagNote\('added', \[created\.id, serviceMade\?\.id\]"
        $script:code | Should -Match '\} else \{ serviceMade = madeOne; \}'
    }

    It 'and the removal is recorded too, including when it was already gone' {
        # "A removal must remove" - a row that lingers for two minutes reads as
        # a removal that did not happen. Both exits from the delete record it.
        # ACCESS-LAG-WORDS-1: and each names BOTH assignments it took away.
        # ACCESS-REMOVE-SHARED-1: one exit now - an already-gone engine
        # assignment is absorbed where it is deleted - and the record names the
        # web service assignment only when this removal deleted it. A kept one
        # named here would hide the other grant that uses it
        # (tests/js/access-remove-shared.test.js runs it).
        # ACCESS-SERVICE-ORPHAN-1: a web service only row has no engine
        # assignment, so its record names only what went.
        @([regex]::Matches($script:code, "scopeLagNote\('removed', serviceOnly \? \[step\.remove\] : \[assignmentId, step\.remove\]\)")).Count |
            Should -Be 1 -Because 'the successful delete and the already-gone answer are both removals'
    }

    It 'the list is rendered from the merge, never from the raw Azure rows' {
        # The defect would come straight back if the renderer went back to
        # `rows`, and every JavaScript test here would still pass.
        # ACCESS-LAG-WORDS-1: with the web service's listed assignments, or
        # null when that list could not be read.
        # ACCESS-MG-ROW-TWICE-1: the raw rows, one for each assignment first.
        $script:code | Should -Match 'const merged = scopeRowsWithLag\(scopeRowsOnce\(rows\), scopeLagRead\(\), serviceUnreadable \? null : listedServiceIds\)'
        $script:code | Should -Match 'serviceIds\.push\(a\.id\)'
        $script:code | Should -Match 'listedServiceIds\.push\(\.\.\.\(s\.serviceIds \|\| \[\]\)\)'
        # What is rendered is built FROM merged.rows. SCOPE-COVER-1 added a
        # second pass over it, so this holds the chain rather than one spelling.
        $script:code | Should -Match 'const shown = [^;]*merged\.rows'
        $script:code | Should -Match 'host\.innerHTML = shown\.length'
        $script:code | Should -Not -Match 'host\.innerHTML = rows\.length'
    }

    It 'and what it remembered is written back, so a reload does not lose it' {
        # Without this the row appears, then vanishes on refresh - which is
        # more confusing than never showing it.
        $script:code | Should -Match 'scopeLagWrite\(merged\.keep\)'
    }
}

Describe 'SCOPE-LAG-1: remembering cannot become insisting' {

    It 'every record expires, so a stuck one ends with Azure believed' {
        $script:code | Should -Match 'SCOPE_LAG_MS = 600000'
        $script:code | Should -Match 'Date\.now\(\) - \(r\.atMs \|\| 0\)\) < SCOPE_LAG_MS'
    }

    It 'LAG-FLAP-1: expiry is the ONLY thing that forgets a record' {
        # It used to be forgotten the moment Azure's list agreed once. Eventual
        # consistency is not monotonic - a later read can reach an older
        # replica - so a row came back with nothing left to hide it. MEASURED
        # in the product, not reasoned about.
        $script:code | Should -Not -Match 'seen\.has\(p\.id\)\) \{ continue; \}\s*//.*forget'
        $script:code | Should -Match "if \(x\.p\.action === 'removed'\) \{ keep\.push\(x\.p\); continue; \}"
    }

    It 'and the explanation follows what changed the screen, not what is remembered' {
        # A record kept to its cap must not leave the line under a settled
        # table for ten minutes, explaining a lag that is over.
        $script:code | Should -Match 'merged\.acting\.length \?'
        $script:code | Should -Not -Match 'merged\.keep\.length \?'
    }

    It 'and a browser that refuses storage gets the old behaviour, not an error' {
        # Private windows, cleared site data, and a thumbnail capture all throw
        # here. The page must still render.
        $script:code | Should -Match 'function scopeLagRead\(\)[\s\S]{0,600}catch \{ return \[\]; \}'
        $script:code | Should -Match 'function scopeLagWrite\([\s\S]{0,200}catch \{'
    }

    It 'it only remembers the two actions it knows, and only with an id' {
        $script:code | Should -Match "r\.action === 'added' \|\| r\.action === 'removed'"
        $script:code | Should -Match 'if \(!list\.length\) return;'
        # ACCESS-LAG-WORDS-1: a record an older page left names one id, and
        # still reads.
        $script:code | Should -Match 'Array\.isArray\(r\?\.ids\) \? r\.ids : \[r\?\.id\]'
    }
}

# PUBLIC-SYNC-1: the lab drills do not ship to the public repository, so there
# is no drill report to fence, and the public .gitignore names none.
Describe 'REPORT-LEAK-1: a run report never becomes a commit' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' 'lab'))) {

    It 'the names a lab run writes are ignored by git' {
        # A report names the subscription, the resource groups and the machines
        # - that is what makes it useful afterwards, and what makes it a leak
        # the moment somebody runs `git add -A` in the directory they ran the
        # drill in. NoLiveIdentifiers.Tests.ps1 caught one on 2026-09-20; this
        # is the fence rather than the net.
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw
        # RELEASE-404-1: THE CLASS, NOT TWO INSTANCES. This pinned the two
        # prefixes that existed, so the third drill to write a report was not
        # covered and `git add -A` staged one carrying a live subscription id.
        # Naming instances is exactly what failed.
        $ignore | Should -Match '(?m)^vmf-\*\.json$' -Because 'every drill report is named vmf-<what>-<when>.json'
        $ignore | Should -Match 'odcr-probe-\*\.json'
    }

    It 'and every report a drill writes matches one of those names' {
        # The rule, not the instance: a drill that writes its findings to a new
        # name puts them somewhere the fence does not reach.
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $written = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-ChildItem (Join-Path $root 'tests' 'lab') -Filter '*.ps1' -File)) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            # Any name a drill BUILDS, not just a plain literal after
            # Set-Content. The release drill wrote
            # ("vmf-rel404-{0}.json" -f ...), which the old pattern - a quoted
            # literal of lower-case letters on a Set-Content line - could not
            # see at all. So it passed without looking at the one report that
            # had just escaped the fence.
            #
            # THE HAZARD IS A FILE WRITTEN WHERE THE DRILL WAS RUN, which is
            # the repository root, where `git add -A` will find it. So the line
            # has to be one that WRITES or that builds a path from the current
            # directory. A `.json` under lab/fleets is an INPUT this repository
            # tracks on purpose, and reading one is not a leak - the first
            # version of this widening flagged exactly that and was wrong.
            foreach ($line in ($code -split "`r?`n")) {
                if ($line -notmatch 'Set-Content|Out-File|Get-Location|PWD') { continue }
                foreach ($m in [regex]::Matches($line, '[''"]([A-Za-z0-9{}_.\- ]*\.json)[''"]')) {
                    $written.Add("$($f.Name) -> $($m.Groups[1].Value)")
                }
            }
        }
        foreach ($entry in $written) {
            $entry | Should -Match '-> (odcr-probe-|vmf-)' `
                -Because 'a report written under a name the fence does not reach is a leak waiting to happen'
        }
    }
}

Describe 'ACCESS-LAG-WORDS-1: the pending row says what the person chose' {

    It 'both ways into the grant pass the mode, not only the level' {
        # The pending row was built from the LEVEL (sub, rg, mg), so it said
        # "Assess" for every grant. tests/js/access-lag-words.test.js runs the
        # direct path; the widening path goes through a confirmation first.
        $script:code | Should -Match 'await grantScopeNow\(scope, def, null, btn, level, mode\)'
        $script:code | Should -Match '\(\) => grantScopeNow\(scope, def, widen, btn, level, mode\)'
        $script:code | Should -Match 'async function grantScopeNow\(scope, def, widen, btn, level, mode\)'
        $script:code | Should -Match "what: mode === 'migrate' \? UX\.scopeChange : UX\.scopeLook"
        $script:code | Should -Not -Match "what: level === 'migrate'"
    }
}