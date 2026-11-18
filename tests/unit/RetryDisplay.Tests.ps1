#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETRY-UI-1 - a step that RECOVERED still reads as a failure.
#
# Seen in the PERM-2 drill: the run went forward, but the feed showed errors.
# Two red rows over a transient transport error that was retried and succeeded.
# The machine's state document said no step failed; the feed said one did. The
# feed is the thing on screen.
#
# This does NOT regex the page. It EXTRACTS the real recovery block out of
# index.html and runs it in node against fixtures - so if the logic changes, the
# test exercises the changed logic instead of quietly passing on a stale string.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    $script:node = (Get-Command node -ErrorAction SilentlyContinue)?.Source

    # The block is self-contained and depends only on `events`, which is what
    # makes lifting it honest: it is the shipped code, not a copy of it.
    $script:block = [regex]::Match($script:page,
        '(?ms)^  const recovered = new Set\(\);\r?\n  \{.*?^  \}\r?$').Value

    function Global:WhichRecovered {
        param([Parameter(Mandatory)][string]$EventsJson)
        $js = @"
const events = $EventsJson;
$script:block
console.log(JSON.stringify([...recovered].sort((a, b) => a - b)));
"@
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-retry-$([guid]::NewGuid().ToString('N').Substring(0,8)).mjs"
        try {
            Set-Content -LiteralPath $tmp -Value $js -Encoding utf8
            $out = & $script:node $tmp 2>&1
            if ($LASTEXITCODE -ne 0) { throw "node failed: $out" }
            @(($out | Out-String).Trim() | ConvertFrom-Json)
        }
        finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
    }
}
AfterAll { Remove-Item 'function:\WhichRecovered' -ErrorAction SilentlyContinue }

Describe 'RETRY-UI-1: the feed can tell recovered from failed' {
    It 'found the recovery block in the shipped page' {
        # If this regex stops matching, every test below would silently test an
        # empty string. Guard the guard.
        $script:block | Should -Not -BeNullOrEmpty
        $script:block | Should -Match 'lastOk'
    }

    It 'needs node, and does not skip when it is missing' {
        $script:node | Should -Not -BeNullOrEmpty -Because 'a guard that quietly does not run is worse than no guard'
    }

    It 'marks the drill sequence actually seen as recovered' {
        # Chronological, exactly as the run recorded it.
        $events = @'
[ {"vmId":"vm1","step":"azureops:runcmd:mana-check.sh","outcome":"fail"},
  {"vmId":"vm1","step":"GUEST_PREP","outcome":"fail"},
  {"vmId":"vm1","step":"GUEST_PREP","outcome":"start"},
  {"vmId":"vm1","step":"azureops:runcmd:mana-check.sh","outcome":"ok"},
  {"vmId":"vm1","step":"driverCheck","outcome":"info"},
  {"vmId":"vm1","step":"GUEST_PREP","outcome":"ok"} ]
'@
        WhichRecovered $events | Should -Be @(0, 1)
    }

    It 'a failure with no later success STAYS a failure' {
        # The whole point is not to launder real failures.
        $events = @'
[ {"vmId":"vm1","step":"CONVERTING","outcome":"fail"},
  {"vmId":"vm1","step":"SOMETHING_ELSE","outcome":"ok"} ]
'@
        @(WhichRecovered $events).Count | Should -Be 0
    }

    It 'a success BEFORE the failure does not launder it' {
        # An earlier attempt at the same step proves nothing about this one, and
        # reading it as proof would hide the failure that ended the run.
        #
        # Honest note: this asserts the REQUIRED behaviour, but it does not on
        # its own discriminate the `> i` comparison - that condition is always
        # true given the loop's direction. What actually protects the ordering
        # is the direction itself, and reversing it IS caught (by the drill
        # sequence and the fail/recover/fail tests).
        $events = @'
[ {"vmId":"vm1","step":"CONVERTING","outcome":"ok"},
  {"vmId":"vm1","step":"CONVERTING","outcome":"fail"} ]
'@
        @(WhichRecovered $events).Count | Should -Be 0
    }

    It 'another machine succeeding does not launder this one' {
        $events = @'
[ {"vmId":"vm1","step":"CONVERTING","outcome":"fail"},
  {"vmId":"vm2","step":"CONVERTING","outcome":"ok"} ]
'@
        @(WhichRecovered $events).Count | Should -Be 0
    }

    It 'handles a step failing, recovering, then failing again for good' {
        $events = @'
[ {"vmId":"vm1","step":"S","outcome":"fail"},
  {"vmId":"vm1","step":"S","outcome":"ok"},
  {"vmId":"vm1","step":"S","outcome":"fail"} ]
'@
        # The first is recovered; the LAST one stands, because nothing follows it.
        WhichRecovered $events | Should -Be @(0)
    }
}

Describe 'RETRY-UI-1: and it is rendered differently' {
    It 'a recovered failure gets its own wording, not the failure pill' {
        $script:page | Should -Match 'recoveredNote'
        $script:page | Should -Match "wasRecovered"
        # Still VISIBLE - a machine that needed three attempts is worth knowing
        # about. It just must not read as an error that still stands.
        $reco = [regex]::Match($script:page, "recoveredNote:\s*'([^']+)'").Groups[1].Value
        $reco | Should -Not -BeNullOrEmpty
        $reco | Should -Match '(?i)retry|recover|succeeded'
    }

    It 'and a real failure still gets the red one' {
        # RESTORE-END-LOST-1: the words come from feedFailNote, which returns
        # UX_STEP.failedNote or UX_STEP.failedNoteRun (Dashboard.Tests.ps1 pins it).
        $script:page | Should -Match "pill bad.*feedFailNote\(e\)"
    }
}
