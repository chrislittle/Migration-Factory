# WAIT-2: the Migrations page says what it is reading, and keeps saying it.
#
# The painting is covered behaviourally by tests/js/reading-run.test.js. What
# that cannot reach is the WIRING inside refresh(), which is 90 lines of awaits
# and cannot be lifted. Two things there decide whether the message is ever
# seen, and both are ORDERING - which no behavioural test of the parts can see:
#
#   1. refresh() must ask for the waiting state when the body is not already
#      showing this run. Without the call, nothing paints and the page is blank
#      for ten seconds again.
#
#   2. `showingRun = currentRun` must be set AFTER the reads that can throw and
#      BEFORE the renders. Both sides of that are load-bearing:
#        * set too early - before a read that fails - and a failed refresh
#          leaves the page claiming to show a run it never got.
#        * set too late - after the renders - and renderWaves, which refuses to
#          draw a run the body is not showing, refuses the very render that is
#          meant to END the wait. The page then sits on the waiting line for
#          ever. THIS WAS WRITTEN WRONG THE FIRST TIME and found by reading.
#
# COMMENT-TRAP-1: this reads Get-VmfCodeOnly output. The comments in that
# function name every symbol below.

. (Join-Path $PSScriptRoot '_CodeOnly.ps1')

$script:vmfPage = Get-VmfCodeOnly -Path (
    Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'migrations.html')

# JUST refresh(), not the whole page. The ordering checks below compare where
# things sit, and renderWaves CALLS ITSELF from its own toggle handlers - so a
# whole-page search found the first of six calls, 20,000 characters before the
# one in refresh, and the ordering check failed on a file that was correct.
# NO BACKSLASH-N IN THIS PATTERN, deliberately. Written through a shell, the
# escape arrived as a REAL NEWLINE inside the string and split the pattern
# across three lines - the exact failure CLAUDE.md records, which produces a
# regex that matches nothing and reports no error. (?m) anchors on line starts
# and needs no escape a shell knows.
# PAGE-WAIT-1: the run's reads moved into refreshRun(). refresh() now only
# decides whether the store walk runs before them or beside them.
$script:vmfRefresh = [regex]::Match(
    $script:vmfPage, '(?m)^async function refreshRun\(reads = tickReads\(\)\) \{[\s\S]*?^\}').Value

# start(), for the same reason: WAIT-3 is entirely about WHERE things happen in
# it, and no behavioural test of the parts can see an ordering.
$script:vmfStart = [regex]::Match(
    $script:vmfPage, '(?m)^async function start\(\) \{[\s\S]*?^\}').Value

Describe 'WAIT-2: the page says what it is reading' -ForEach @(
    @{ Code = $script:vmfPage; Refresh = $script:vmfRefresh; Start = $script:vmfStart }
) {

    It 'the page was read, so nothing below can pass on an empty string' {
        $Code.Length | Should -BeGreaterThan 20000 -Because 'migrations.html is a large page'
        # THE VACUITY GUARD. Every ordering check below reads $Refresh. If that
        # match ever comes back empty - a renamed function, a reformatted
        # signature - every IndexOf returns -1 and the comparisons would pass or
        # fail for reasons that have nothing to do with the page.
        $Refresh.Length | Should -BeGreaterThan 1000 -Because 'refresh() was found and is the function it looks like'
        $Refresh | Should -Match 'renderWaves\(halted\);' -Because 'this is the refresh that draws the page'
    }

    It 'refresh asks for the waiting state when the body is not showing this run' {
        # The guard and the call together. The call alone would blank the page
        # on every fifteen-second tick, which is worse than the defect.
        $Refresh | Should -Match 'if \(showingRun !== currentRun\) \{ showReadingRun\(\); \}' `
            -Because 'a first load and a run somebody just switched to both need it, and a refresh tick does not'
    }

    It 'the waiting state is painted before the reads, not after them' {
        $callAt = $Refresh.IndexOf('showReadingRun();')
        $readAt = $Refresh.IndexOf('reads.status(currentRun, runRead)')
        $callAt | Should -BeGreaterThan 0
        $readAt | Should -BeGreaterThan 0
        $callAt | Should -BeLessThan $readAt `
            -Because 'a message shown after the wait is over has nothing to say'
    }

    It 'the body is marked as showing the run AFTER every read that can throw' {
        # If this moves above the reads, a refresh that fails leaves the page
        # claiming to show a run it never got.
        $markAt = $Refresh.IndexOf('showingRun = currentRun;')
        # PERF-PROBES-1: the folders come from the one listing of the run now,
        # through folder(); the pause flag is still the last read in the list.
        $lastRead = $Refresh.IndexOf("doc('halt.flag')")
        $markAt | Should -BeGreaterThan 0
        $lastRead | Should -BeGreaterThan 0
        $markAt | Should -BeGreaterThan $lastRead
    }

    It 'and BEFORE the renders, or the wait never ends' {
        # renderWaves refuses to draw a run the body is not showing - that is
        # what stops a keystroke wiping the waiting line. Marked after the
        # renders, that guard refuses the render that ends the wait, and the
        # page sits on the waiting line for ever.
        $markAt = $Refresh.IndexOf('showingRun = currentRun;')
        $drawAt = $Refresh.IndexOf('renderWaves(halted);')
        $markAt | Should -BeGreaterThan 0
        $drawAt | Should -BeGreaterThan 0
        $markAt | Should -BeLessThan $drawAt
    }

    It 'renderWaves refuses to draw a run the body is not showing' {
        $Code | Should -Match 'function renderWaves[\s\S]{0,600}?if \(showingRun !== currentRun\) \{ return; \}' `
            -Because 'a keystroke during the first read must not wipe the waiting line'
    }
    It 'start() was read, so the ordering checks below mean something' {
        $Start.Length | Should -BeGreaterThan 500 -Because 'start() was found'
        # MIGRATIONS-LOAD-1: the reads begin in firstLoad - the list and the
        # named run together - so that call is where the walk starts.
        $Start | Should -Match 'await asOneLoad\(\(\) => firstLoad\(tickReads\(\)\)\)' -Because 'this is the boot that reads the store'
    }

    It 'WAIT-3: the body is on screen BEFORE the slow walk, not after it' {
        # WAIT-2 painted a waiting state that was never seen: it lives inside
        # refresh(), and the app was display:none for the whole of loadRuns() -
        # measured at twenty-five seconds of blank page on a real install.
        $showAt = $Start.IndexOf("`$('#app').style.display = 'block';")
        $walkAt = $Start.IndexOf('firstLoad(tickReads())')
        $showAt | Should -BeGreaterThan 0 -Because 'start() shows the body'
        $walkAt | Should -BeGreaterThan 0
        $showAt | Should -BeLessThan $walkAt `
            -Because 'a waiting state hidden during the wait is not a waiting state'
    }

    It 'and the message is painted before the walk too' {
        $sayAt = $Start.IndexOf('showReadingRun();')
        $walkAt = $Start.IndexOf('firstLoad(tickReads())')
        $sayAt | Should -BeGreaterThan 0 -Because 'start() paints the waiting state'
        $sayAt | Should -BeLessThan $walkAt
    }

    It 'the body is shown exactly once, so it cannot be shown late as well' {
        @([regex]::Matches($Start, [regex]::Escape("`$('#app').style.display = 'block';"))).Count |
            Should -Be 1 -Because 'two places to show it is one place to show it too late'
    }

    It 'a store with no runs takes the waiting state down' {
        # The message is painted before the store is read, so an empty store
        # must clear it - or the page explains there are no migrations while
        # four tables underneath claim to be loading some.
        $Refresh | Should -Match 'clearReadingRun\(\);[\s\S]{0,120}?renderFirstRun\(\)' `
            -Because 'it comes down before the empty-store explanation goes up'
    }

    It 'both halves of the waiting state read ONE list of regions' {
        # A region painted by one and left behind by the other is the defect
        # shape this page has now been fixed for three times in two days.
        $Code | Should -Match 'function readingRegions'
        @([regex]::Matches($Code, 'readingRegions\(\)')).Count |
            Should -BeGreaterOrEqual 3 -Because 'declared once, and read by both halves'
    }
}