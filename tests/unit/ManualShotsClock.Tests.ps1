#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SHOT-CLOCK-1: a picture of the manual, taken again, differed only by the time
# it showed - the sample pages build their dates from the clock, and the
# Migrations header line "Updated ... next in ...s" appeared only after the
# page's one-second timer ran.
#
# tests/js/shot-clock.test.js runs the parts: the fixed clock the page gets, the
# calls that install it, and the wait for each repeating timer's first pass.
# This holds main() in tools/manual-shots.js to using them in the right order:
# the clock goes in before the first page opens, and every picture waits for
# the first passes after its page opened. It reads the code WITHOUT its comments
# (Get-VmfCodeOnly), so a comment that names a call cannot pass for the call.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'manual-shots.js')
    $start = $code.IndexOf('async function main()')
    $script:main = if ($start -ge 0) { $code.Substring($start) } else { '' }
}

Describe 'SHOT-CLOCK-1: every picture is taken on one fixed clock' {
    It 'main() exists, so the checks below read it' {
        $script:main | Should -Not -BeNullOrEmpty
    }

    It 'installs the fixed clock once, before the first page opens' {
        $install = [regex]::Matches($script:main, 'await installShotClock\(send, SHOT_CLOCK\)')
        $install.Count | Should -Be 1
        $navigate = $script:main.IndexOf("send('Page.navigate'")
        $navigate | Should -BeGreaterThan 0
        $install[0].Index | Should -BeLessThan $navigate
    }

    It 'waits for the first passes after the page opened and after its act, before each picture' {
        $navigate = $script:main.IndexOf("send('Page.navigate'")
        $act = $script:main.IndexOf('if (s.act)')
        $wait = [regex]::Matches($script:main, 'await waitForTimerPass\(send, sleep\)')
        $wait.Count | Should -Be 1
        $act | Should -BeGreaterThan $navigate
        $wait[0].Index | Should -BeGreaterThan $act
        $shots = [regex]::Matches($script:main, "send\('Page\.captureScreenshot'")
        $shots.Count | Should -BeGreaterThan 0
        foreach ($s in $shots) { $wait[0].Index | Should -BeLessThan $s.Index }
    }
}
