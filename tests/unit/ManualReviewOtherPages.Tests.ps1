#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-REVIEW-1, area D: the "I do not understand what I am looking at"
# guide (data/operator-guide.json) and the engine and service lines a person
# reads outside Private/engine, checked against the product.
#
# WHAT WAS WRONG (the review of 2026-11-12, verified again on main 5683bb96):
#   - The guide said "A person approves each wave": a wave can be set to need
#     no sign-off, and a scheduled wave starts by itself. It named a "capacity
#     step" the wizard does not have, put the target step first (the machines
#     come first), and said a report "does not change" (a restore and the
#     daily check write it again).
#   - A quota request Azure refused wrote "family=X HTTP 400: {raw body}" into
#     the activity list, which shows a fail line word for word; the plain
#     words were computed one line before and kept out of it.
#   - Restore and assessment refusals named a cmdlet parameter, a choice the
#     dialog does not have ("the default naming"), and "the scanning
#     identity", which is no product noun.
# The page words are held in tests/js/manual-review-other-pages.test.js.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:guide = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'operator-guide.json')) | ConvertFrom-Json
    $script:help = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'help.js'))
    $script:access = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'access.js'))
    # Every sentence the guide shows, one string each.
    $script:guideLines = @(
        foreach ($p in $script:guide.screens.PSObject.Properties) {
            $p.Value.what; @($p.Value.howToRead); $p.Value.nextStep
        }
        @($script:guide.general.points)
    ) | Where-Object { $_ }
    $script:src = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
}

Describe 'MANUAL-REVIEW-1: the operator guide says what the product does' {
    It 'names the planning steps of the wizard, in their order, by their labels' {
        $steps = [regex]::Matches([regex]::Match($script:help, "const MIGRATE_STEPS = \[([^\]]*)\]").Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($steps).Count | Should -Be 5
        $said = $script:guide.screens.'wizard.html'.howToRead | Where-Object { $_ -match '^Planning has' }
        $said | Should -Be ("Planning has five steps: {0}, {1}, {2}, {3} and {4}." -f $steps)
    }

    It 'names no step the wizard does not have' {
        # "The capacity step": the wizard has five steps, and none is called that.
        ($script:guideLines -join ' ') | Should -Not -Match '(?i)capacity step'
    }

    It 'never says that a person approves every wave, or that nothing starts by itself' {
        # waves.js: "Someone must sign off before this wave runs" is a choice
        # of each wave, and a scheduled wave starts at its time (Start-VmfWave
        # from the schedule pass).
        $all = $script:guideLines -join ' '
        $all | Should -Not -Match '(?i)approves each wave|has to be approved before it starts|Nothing is started by this app'
        $all | Should -Match 'A wave starts when a person starts it, or at its scheduled time\. A wave can need an approval before it starts\.'
    }

    It 'says a report is built again after a restore and by the daily check' {
        # RunSummary.ps1 (putBack) and RecordAndReport.ps1 (the daily check) write it again.
        $r = $script:guide.screens.'reports.html'.howToRead -join ' '
        $r | Should -Not -Match 'does not change'
        $r | Should -Match 'The engine builds the report when a wave ends and after a restore\. The daily check builds it again when it is out of date\.'
    }

    It 'says a signed-off plan starts each next wave by itself (the plan-run timer, FacadeCore Invoke-VmfFacadePlanRunPass)' {
        $said = 'After you sign off the plan, the product starts each next wave when the wave before it ends. It waits while a machine waits for a person, or while the run is paused.'
        @($script:guide.screens.'migrations.html'.howToRead) | Should -Contain $said
        @($script:guide.general.points) | Should -Contain $said
    }

    It 'names the quota controls by their labels, in the step that has them' {
        $script:guide.screens.'wizard.html'.howToRead | Should -Contain 'In Arrange the waves, select Check the quota and Reserve capacity before the wave starts. Azure accepts or refuses each quota increase request. The answer can come after some days.'
    }

    It 'says a wave can change until it starts, not until the migration starts' {
        # The save refuses a change to a RUNNING wave only (WAVE-EDIT-RUNNING-1).
        $script:guide.screens.'waves.html'.nextStep | Should -Be 'You can change a wave until it starts.'
    }

    It 'says on-demand capacity reservation, the Azure name, every time' {
        foreach ($line in $script:guideLines) {
            foreach ($m in [regex]::Matches($line, '(?i)\breservations?\b')) {
                $before = $line.Substring(0, $m.Index)
                $before | Should -Match '(?i)on-demand capacity $' -Because "'$line'"
            }
        }
    }

    It 'names the four roles of the Admin page' {
        $names = [regex]::Matches($script:access, "'Vmf\.\w+':\s+\['(\w+)'") | ForEach-Object { $_.Groups[1].Value }
        @($names).Count | Should -Be 4
        $line = $script:guide.screens.'access.html'.howToRead[0]
        foreach ($n in $names) { $line | Should -Match "\b$n\b" }
    }
}

Describe 'MANUAL-REVIEW-1: an engine line a person reads is a sentence in the product words' {
    It 'a refused quota request names the quota and its region, never key=value and the raw body of Azure' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'Request-VmfQuota.ps1')
        $fails = [regex]::Matches($code, "-Step 'quotaRequest' -Outcome fail[^\r\n]*-Detail ""([^""]*)""") | ForEach-Object { $_.Groups[1].Value }
        @($fails).Count | Should -BeGreaterThan 3
        foreach ($d in $fails) { $d | Should -Be '${named}: $reason' }
        $code | Should -Match '\$named = "\$quotaName in \$\(\$ref\.region\)"'
        $code | Should -Not -Match 'run Test-VmfQuota first'
    }

    It 'a restore refusal names the choice the dialog shows, and no cmdlet parameter (hard rule 12)' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'Restore-VmfVm.ps1')
        $code | Should -Not -Match 'default naming'
        $code | Should -Not -Match 'Re-run with -AcceptPreserveRisk|Restore with -From'
        $code | Should -Not -Match 'it is DOWN'
        @([regex]::Matches($code, 'select Yes for Keep its current managed disks')).Count | Should -Be 2
        # The dialog of migrations.js has that question.
        [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')) | Should -Match "restoreNaming:'Keep its current managed disks\?'"
    }

    It 'an assessment that cannot read a place names the Admin page choice, not "the scanning identity"' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'Invoke-VmfAssessment.ps1')
        $code | Should -Not -Match 'scanning identity'
        @([regex]::Matches($code, 'On the Admin page, give the product Assess access to this place, then start the scan again\.')).Count | Should -Be 3
    }

    It 'the service says on-demand capacity reservation, and a busy machine without naming the wrong job' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Not -Match 'A restore of this machine runs now'
        $code | Should -Not -Match 'that the reservation holds'
        $code | Should -Not -Match 'engine worker\(s\)'
    }

    It 'a release Azure refused points at the Release button of the Migrations page, not at a hand release' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'New-VmfWaveReservation.ps1')
        $code | Should -Not -Match 'by hand|COULD NOT BE RELEASED'
        $code | Should -Match 'Select Release on the Quota and on-demand capacity reservations card of the Migrations page\.'
        [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')) | Should -Match "titleBoth:\s+'Quota and on-demand capacity reservations'"
    }

    It 'says on-demand capacity reservation in the lines of the capacity files, and keeps capacity reservation group' {
        # MANUAL-REVIEW-1 (2026-11-13): the Azure name, every time.
        $files = @('Private/capacity/CapacityClaim.ps1', 'Private/capacity/ReservedRefusal.ps1', 'Private/capacity/ReservingRead.ps1',
                   'Public/Remove-VmfRun.ps1', 'Public/Invoke-VmfWaveCloseOut.ps1')
        foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:src $f)
            foreach ($q in [regex]::Matches($code, '"[^"\r\n]*"|''[^''\r\n]*''')) {
                $q.Value | Should -Not -Match '(?<!on-demand )\bcapacity reservations?\b(?! group)' -Because "$f says $($q.Value)"
            }
        }
    }

    It 'a refused reservation names the setting and its value No (2026-11-13)' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Private' 'capacity' 'ReservedRefusal.ps1')
        @([regex]::Matches($code, 'set On-demand capacity reservation for this wave to No\.')).Count | Should -Be 2
        $code | Should -Not -Match 'for this wave to None|set the wave to no capacity reservation'
    }

    It 'a close-out that released says only that Azure accepted the release, never that billing stopped' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'Invoke-VmfWaveCloseOut.ps1')
        $code | Should -Not -Match 'stopped billing'
        $code | Should -Match 'finished\. The product released \$releasedSaid, and Azure accepted the release\.'
    }
}
