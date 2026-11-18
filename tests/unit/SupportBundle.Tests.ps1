#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DIAG-1: the support bundle.
#
# When something goes wrong that we cannot reproduce, the evidence lives in the
# run - the events, the per-machine records, what the plan said, what capacity
# was claimed. Every drill this week found its defect from exactly that trail.
# Without a way to send it, the first real customer failure gets diagnosed by
# asking someone to run PowerShell down a phone line.
#
# Two halves: the dashboard builds it client-side from reads the viewer already
# has, and a script does the same from the run store for when the dashboard is
# the thing that is broken.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Get-Content (Join-Path $script:repoRoot 'tools' 'Export-VmfSupportBundle.ps1') -Raw
    $script:ui = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    # The bundle implementation is SHARED now - one copy, in help.js, opened
    # by the help menu on every page. migrations.html kept a second copy
    # until 2026-09-02, and wiring both to one nav tab is what made the
    # cancelled dialog reappear.
    $script:helpShared = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
}

Describe 'DIAG-1: what the bundle carries, and what it must not' {
    It 'says both, in the bundle itself and not only in the UI' {
        # The person sending it needs to know what they are sending BEFORE they
        # send it, and the person receiving it needs to know what to expect.
        foreach ($src in $script:tool, $script:helpShared) {
            $src | Should -Match 'whatItContains'
            $src | Should -Match 'whatItDoesNotContain|whatItDoesNotContain'
        }
    }

    It 'states plainly that there are no tokens or keys in it' {
        $script:tool | Should -Match '(?i)no tokens, keys'
        $script:helpShared | Should -Match '(?i)no passwords, keys or tokens'
    }

    It 'and the claim is true - neither half reads a credential' {
        # A bundle that quietly carried a token would be a credential emailed to
        # support. Both halves read with the caller's own sign-in.
        foreach ($src in $script:tool, $script:helpShared) {
            $src | Should -Not -Match '(?i)AccountKey|SharedAccessSignature|client_secret'
        }
        $script:tool | Should -Not -Match 'Get-AzAccessToken'
    }

    It 'lists guest evidence by name rather than inlining it' {
        # Those files can be large, and support can ask for the one it wants.
        $script:tool | Should -Match "evidenceFiles = @\(Get-NamesSafely 'evidence'\)"
    }
}

Describe 'DIAG-1: the bundle keeps its shape' {
    It 'collections stay collections even when there is exactly one' {
        # Found by exporting a real single-machine run: a pipeline emitting one
        # object returns a SCALAR, so ConvertTo-Json wrote `machines` as an
        # OBJECT. A one-machine run then produced a differently shaped bundle
        # than a fleet, and anything parsing machines[] would find nothing.
        $script:tool | Should -Match '\$machines\s+= @\(@\(foreach'
        $script:tool | Should -Match 'machines\s+= @\(\$machines\)'
        foreach ($k in 'capacityClaims = @\(\$claims\)', 'approvals\s+= @\(\$approvals\)',
                       'schedules\s+= @\(\$schedules\)', 'events\s+= @\(\$events\)') {
            $script:tool | Should -Match $k
        }
    }

    It 'and the reason is written down where the next person will look' {
        $script:tool | Should -Match '(?i)returns a SCALAR'
    }
}

Describe 'DIAG-1: the activity log is capped honestly' {
    It 'keeps the NEWEST entries, which are the ones that explain a failure' {
        $script:tool | Should -Match '\$events\[-\$EventLimit\.\.-1\]'
        # The shared implementation names its own cap.
        $script:helpShared | Should -Match 'events\.slice\(-EVENT_CAP\)'
    }

    It 'and records that it truncated, with the real total' {
        foreach ($src in $script:tool, $script:helpShared) {
            $src | Should -Match 'eventsTruncated'
            $src | Should -Match 'eventsTotal'
        }
    }
}

Describe 'DIAG-1: Log Analytics queries are handed over, not run' {
    It 'ships the queries support will ask for' {
        foreach ($q in 'ContainerAppConsoleLogs_CL', 'AppRequests', 'AppExceptions') {
            $script:tool | Should -Match $q
        }
    }

    It 'as TEXT, because running them here could return an empty answer' {
        # This script may not have workspace access, and an empty result set
        # looks like an answer. A query someone can paste is more useful.
        $script:tool | Should -Match '(?i)empty result set looks like an answer|an empty result set looks like an answer'
        $script:tool | Should -Not -Match 'Invoke-AzOperationalInsightsQuery'
    }

    It 'and the bundle does not send the person to open the perimeter' {
        # STORE-LOGS-NSP-1 put the workspace in the run store's perimeter, and
        # this note said to open it before a query. The workspace left the
        # perimeter on 2026-11-06 (STORE-LOGS-WORKSPACE-PERIMETER-1), so a
        # pasted query works with the person's own role, and a note that says
        # otherwise sends them to change a perimeter for nothing.
        $note = [regex]::Match($script:tool, "(?m)^\s*note\s*=\s*'(?<n>[^']+)'").Groups['n'].Value
        $note | Should -Not -BeNullOrEmpty
        $note | Should -Not -Match '(?i)perimeter'
    }
}

Describe 'DIAG-1: the dashboard half' {
    # REPOINTED 2026-09-02. These used to read migrations.html, which carried
    # its OWN copy of the support bundle from before the shared help menu
    # existed. Two implementations of one feature, and that page wired BOTH to
    # the same nav tab - so one click opened the shared menu and the page's own
    # download dialog behind it, and cancelling the menu left the download box
    # sitting there. Seen twice: Cancel on the Get help menu, and the page
    # still asked to download files.
    #
    # The duplicate is gone. These now pin the implementation that actually
    # runs, which is the one in help.js - shared by every page.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:helpJs = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
    }

    It 'offers it from the top navigation, reachable from any page state' {
        # The moment someone needs this is the moment something has gone wrong,
        # so it cannot live behind a working view. One bar for every page.
        $script:helpJs | Should -Match 'id="nav-help"'
        $script:helpJs | Should -Match 'function bundleDialog'
        $script:helpJs | Should -Match "if \(kind === 'failure'\) \{ bundleDialog\(\); return; \}"
    }

    It 'and NO page keeps a second copy of it' {
        # The duplication is what made the double-handler possible.
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        foreach ($page in Get-ChildItem $dash -Filter '*.html') {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Not -Match 'function buildSupportBundle' -Because "$($page.Name) must use the shared bundle"
            $text | Should -Not -Match 'function askSupportBundle' -Because "$($page.Name) must use the shared dialog"
        }
    }

    It 'builds it in the browser from reads the viewer already has' {
        # No new access path, no new permission, nothing server-side.
        $script:helpJs | Should -Match 'async function buildBundle'
        $script:helpJs | Should -Match 'adapter\.readJson\(run'
        $script:helpJs | Should -Match 'URL\.createObjectURL'
    }

    It 'names the file after the run and the time, so two bundles never collide' {
        $script:helpJs | Should -Match "'vmf-support-'"
        $script:helpJs | Should -Match 'toISOString\(\)\.replace'
    }

    It 'does not revoke the download URL before the browser has read it' {
        # Revoking synchronously cancels the download in some browsers.
        $script:helpJs | Should -Match 'setTimeout\(\(\) => URL\.revokeObjectURL'
    }

    It 'the button says what it does, rather than "Confirm"' {
        $script:helpShared | Should -Match 'label: TEXT\.download'
        $script:helpShared | Should -Match "download:\s*'Download the file'"
    }
}
