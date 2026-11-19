#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STRINGS-GATE-1: the dead-string gate, run against real pages.
#
# WHY THIS FILE EXISTS. The gate has a rule called `unused-string` and a
# fixture that exercises it, and that fixture passed every day. On 2026-09-16
# WAVE-FLOW-1 deleted two screens and left 34 strings that nothing reads, and
# the gate answered "nothing is declared unread" over all of them.
#
# The cause: handing the whole string table to a shared helper -
# `waveEstimate(machines, value, UX)` - made it give up on key-level analysis
# for the WHOLE page. One such call on the wizard switched dead-string
# detection off for every string that page declares.
#
# A fixture cannot find that, because the fixture does not hand its object to
# anything. So these plant a dead string in a COPY of the real pages and check
# the gate says so. A gate that reports clean is worse than no gate, because
# its silence is read as an answer.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-UxStrings.ps1'
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'

    # A throwaway copy, so a planted string never touches the real pages.
    function Script:NewDashboardCopy {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ux-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($file in (Get-ChildItem $script:dash -File)) {
            Copy-Item $file.FullName (Join-Path $dir $file.Name) -Force
        }
        $dir
    }
    # Guarded: only ever a directory this file made, under the temp path.
    function Script:DropCopy {
        param([string]$Dir)
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $full = [System.IO.Path]::GetFullPath($Dir)
        if ($full.StartsWith($temp) -and (Split-Path $full -Leaf).StartsWith('vmf-ux-')) {
            [System.IO.Directory]::Delete($full, $true)
        }
    }
    # 6>&1 as well as 2>&1: the gate says its verdict with Write-Host, so a
    # capture of the output and error streams alone gets an empty string - and
    # a -Match against an empty string fails for a reason that has nothing to
    # do with what the gate found.
    function Script:RunGate {
        param([string]$Path)
        & $script:tool -DashboardPath $Path -Detailed 6>&1 2>&1 | Out-String
    }
}

Describe 'ADVISOR-1: the gate finds a key declared twice' {
    It 'a second declaration of a key on a real page is a finding' {
        # JavaScript keeps the last one silently, so an older table's words change.
        $dir = Script:NewDashboardCopy
        try {
            # CSP-INLINE-1: the page's strings are in its own script file.
            $wiz = Join-Path $dir 'wizard.js'
            $text = [System.IO.File]::ReadAllText($wiz)
            $anchor = "  tTitle: 'Choose each target',"
            $text.Contains($anchor) | Should -BeTrue -Because 'the plant must land, or this proves nothing'
            [System.IO.File]::WriteAllText($wiz, $text.Replace($anchor, $anchor + "`n  colSize: 'Size now',"))
            $out = Script:RunGate -Path $dir
            $out | Should -Match 'duplicate-key'
            $out | Should -Match 'UX\.colSize is declared 2 times'
        }
        finally { Script:DropCopy -Dir $dir }
    }
}

Describe 'STRINGS-GATE-1: the gate finds a dead string on every page' {

    It 'the real pages are clean to start with' {
        $dir = Script:NewDashboardCopy
        try { (Script:RunGate -Path $dir) | Should -Match 'nothing is declared unread' }
        finally { Script:DropCopy -Dir $dir }
    }

    It 'THE DEFECT: and a string nothing reads is found, on EVERY page' {
        # Planted in every string table a page declares, so a page whose first
        # table is a lookup read by a computed key - which genuinely cannot be
        # checked key by key - is not mistaken for a page that is blind.
        $dir = Script:NewDashboardCopy
        try {
            $pages = @(Get-ChildItem $dir -Filter '*.html')
            $pages.Count | Should -BeGreaterThan 5 -Because 'this must not pass by finding no pages'
            foreach ($file in $pages) {
                # CSP-INLINE-1: planted in the page's own script file, where the
                # strings are, so the gate is proven to read that file.
                $own = [System.IO.Path]::ChangeExtension($file.FullName, '.js')
                $text = [System.IO.File]::ReadAllText($own)
                $planted = [regex]::Replace($text, "(?m)^(const UX[A-Za-z_]* = \{\s*\r?\n)",
                    "`$1  vmfPlantedDeadString: 'nothing reads this',`n")
                $planted | Should -Not -Be $text -Because "the plant must land in $([System.IO.Path]::GetFileName($own))"
                Set-Content $own -Value $planted -Encoding utf8NoBOM -NoNewline
            }
            $out = Script:RunGate -Path $dir
            foreach ($file in $pages) {
                $out | Should -Match ([regex]::Escape($file.Name) + '.*vmfPlantedDeadString') `
                    -Because "$($file.Name) must not be blind to a string nothing reads"
            }
        }
        finally { Script:DropCopy -Dir $dir }
    }
}

Describe 'STRINGS-GATE-1: handing the table to a helper does not excuse the page' {
    # The exact shape that switched the wizard off. Built rather than borrowed,
    # so it still says what it means when the real pages change.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:fake = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ux-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:fake -Force | Out-Null
        $help = @'
function spanText(minutes, T) {
  return minutes < 60 ? T.estMinutes : T.estHours;
}
'@
        Set-Content (Join-Path $script:fake 'help.js') -Value $help -Encoding utf8NoBOM
        $page = @'
<script>
const UX = {
  estMinutes: '{n} minutes',
  estHours:   '{n} hours',
  livingOne:  'This one is read',
  deadOne:    'Nothing reads this',
};
$('#a').textContent = UX.livingOne;
$('#b').textContent = spanText(90, UX);
</script>
'@
        Set-Content (Join-Path $script:fake 'page.html') -Value $page -Encoding utf8NoBOM
    }
    AfterAll {
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $full = [System.IO.Path]::GetFullPath($script:fake)
        if ($full.StartsWith($temp) -and (Split-Path $full -Leaf).StartsWith('vmf-ux-fake-')) {
            [System.IO.Directory]::Delete($full, $true)
        }
    }

    It 'the keys the helper reads are not reported dead' {
        $out = & $script:tool -DashboardPath $script:fake -Detailed 6>&1 2>&1 | Out-String
        $out | Should -Not -Match 'estMinutes' -Because 'the helper reads it through its own parameter name'
        $out | Should -Not -Match 'estHours'
        $out | Should -Not -Match 'livingOne'
    }

    It 'and the key NOTHING reads still is' {
        $out = & $script:tool -DashboardPath $script:fake -Detailed 6>&1 2>&1 | Out-String
        $out | Should -Match 'deadOne' -Because 'one whole-object call must not excuse the rest of the page'
    }
}
