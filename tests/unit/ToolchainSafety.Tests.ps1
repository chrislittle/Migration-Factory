#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TOOLCHAIN-1 - the tests must not be able to destroy the thing running them.
#
# Written 2026-09-02, after the third time a test run broke the Pester
# install.
#
# Pester's own scope owns $p. A script that calls Invoke-Pester and then WRITES
# through a variable of that name writes over Pester's own source: on
# 2026-08-27 a 1759-line HTML page landed in Pester.ScriptScope.ps1, and every
# test in the next run "failed" with a parse error pointing at Pester source
# and naming nothing of the caller's.
#
# CLAUDE.md has warned about this since the FIRST occurrence, and it has now
# happened twice more. A note that is read after the damage is not a control.
#
# THE RULE IS DELIBERATELY NARROW. 49 files in this tree use $p as a loop
# variable and none of them are dangerous - reading through it can hurt
# nothing. What is dangerous is WRITING through it, and only in the trees that
# run under or beside Pester. A rule that flagged all 49 would be noise, and a
# check that cries wolf is the thing the inert-test detector exists to stop.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
}

Describe 'TOOLCHAIN-1: nothing writes through the variable Pester owns' {

    It 'no file under tests/ or tools/ uses it as a write target' {
        # Remove-Item earns its place: a recursive force-delete through a
        # name you do not own is the worst version of this, not a milder one.
        # infra/ is here because the FIRST version of this rule omitted it and
        # missed a live one: infra/identity-deploy.ps1 assigned $args. A rule
        # is only as good as the tree it is pointed at.
        $writers = 'Set-Content|Add-Content|Out-File|Copy-Item|Move-Item|Remove-Item|New-Item|Export-Csv|Export-Clixml|Tee-Object'
        $bad = foreach ($dir in @('tests', 'tools', 'infra')) {
            $root = Join-Path $script:repoRoot $dir
            if (-not (Test-Path $root)) { continue }
            foreach ($file in Get-ChildItem $root -Recurse -Filter '*.ps1') {
                $lines = Get-Content $file.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # A writer cmdlet whose target is that name. The lookbehind
                    # matters: without it Remove-Item matches on the tail of
                    # Move-Item and the rule reports lines that are fine - it
                    # did exactly that on first run, twice. The rule is also
                    # written so it does not match ITSELF, rather than being
                    # exempted: a checker blind to its own instance of the
                    # thing it looks for is not much of a checker.
                    if ($lines[$i] -match "(?<![\w-])($writers)[^|;]*\`$p\b") {
                        "$($file.Name):$($i + 1)"
                    }
                }
            }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'Pester owns that name, so writing through it overwrites Pester'
    }

    It 'and the runner checks the install before it trusts it' {
        # The damage is invisible until you run tests, and then it reads like a
        # fault in your own change. One line of diagnosis is worth more here
        # than any amount of prevention, because prevention has failed 3 times.
        $runner = Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw
        $runner | Should -Match 'ParseFile'
        $runner | Should -Match 'YOUR PESTER INSTALL IS DAMAGED'
        $runner | Should -Match 'Install-Module Pester -RequiredVersion'
    }

    # PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its own
    # runners (tools/Initialize-VmfCiRunner.ps1). Neither ships, and the public workflows are
    # different files, so there this is skipped.
    It 'and it pins the version CI installs' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) {
        # Two versions are installed on the development machine and a bare
        # Invoke-Pester takes the newest - which is not what CI runs, so a
        # local pass would prove less than it appears to.
        $runner = Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw
        $ci     = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $pinned = [regex]::Match($runner, "PesterVersion = '([\d.]+)'").Groups[1].Value
        $pinned | Should -Not -BeNullOrEmpty
        # CI-RUNNER-1 removed the module CACHE, which is where this used to
        # read the version from - the key was `psmodules-...-pester-5.7.1-...`.
        # A machine we keep already has the modules, so the cache went and the
        # version now lives in the install list. Read it where it actually is,
        # and compare the VERSIONS rather than matching a substring, so this
        # cannot pass on some other mention of the number.
        $ciPester = [regex]::Match($ci, "@\('Pester',\s*'([\d.]+)'\)").Groups[1].Value
        $ciPester | Should -Not -BeNullOrEmpty -Because 'ci.yml must state the Pester version it installs'
        $ciPester | Should -Be $pinned -Because 'the local pin and CI must be the same version'
    }

    # CI-PIN-1, MEASURED 2026-09-26. INSTALLING THE PINNED VERSION IS NOT
    # RUNNING IT. Each workflow step is its own PowerShell process, so the step
    # that makes sure 5.7.1 is installed loads nothing for the steps after it.
    # The Azure runner had only 5.7.1, so the gap never showed. On the development
    # PC, which also has Pester 6.1.0 and PSScriptAnalyzer 1.25.0, the CI log
    # said "Pester v6.1.0": the suite ran under a version CI does not pin, and
    # took four times as long.
    # DEPS-CURRENT-1: the version is the one infra/part-versions.json pins, so
    # a pin moved by tools/Test-VmfPartPinDrift.ps1 -UpdateBaseline needs no
    # edit here.
    # PUBLIC-SYNC-1: this tests this repository's own CI workflows, which run on its own
# runners (tools/Initialize-VmfCiRunner.ps1). Neither ships, and the public workflows are
# different files, so there this is skipped.
    It 'the <Step> step loads <Module> <Version> itself, before it runs' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-VmfCiRunner.ps1'))) -ForEach @(
        $pinParts = (Get-Content (Join-Path $PSScriptRoot '..' '..' 'infra' 'part-versions.json') -Raw | ConvertFrom-Json).parts
        @{ Step = 'Pester unit tests'; Module = 'Pester'; Version = ($pinParts | Where-Object key -eq 'psgallery:Pester').version }
        @{ Step = 'PSScriptAnalyzer'; Module = 'PSScriptAnalyzer'; Version = ($pinParts | Where-Object key -eq 'psgallery:PSScriptAnalyzer').version }
    ) {
        $Version | Should -Match '^\d+\.\d+\.\d+$' -Because 'infra/part-versions.json must pin the version'
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $step = [regex]::Match($ci, "(?s)- name: $([regex]::Escape($Step))\s*\n(.*?)(?=\n\s*- name: |\n  [a-z-]+:\s*\n|\z)").Groups[1].Value
        $step | Should -Not -BeNullOrEmpty -Because "ci.yml must have a '$Step' step"
        # REVIEW-1: the step's script with its comments removed by the project's
        # helper, never a line filter (CLAUDE.md) - a filter keeps
        # `$x = 1 # Import-Module ...`, which would pass this test.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $lines = @($step -split "`n")
        $start = [array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -match '^\s*run:\s*\|' })
        $start | Should -BeGreaterThan -1 -Because "the '$Step' step has a run block"
        $script = ($lines[($start + 1)..($lines.Count - 1)]) -join "`n"
        $code = Get-VmfCodeOnly -Text $script -Language powershell
        $code | Should -Match "Import-Module $Module -RequiredVersion $([regex]::Escape($Version))"
        # And loaded BEFORE the step uses it - an import after the run pins nothing.
        $use = if ($Module -eq 'Pester') { 'Invoke-VmfPesterParallel|Invoke-Pester|New-PesterConfiguration' } else { 'Invoke-ScriptAnalyzer' }
        $code.IndexOf("Import-Module $Module -RequiredVersion") | Should -BeLessThan ([regex]::Match($code, $use).Index)
        $ciPinned = [regex]::Match($ci, "@\('$Module',\s*'([\d.]+)'\)").Groups[1].Value
        $ciPinned | Should -Be $Version -Because 'the step must load the version the install list names'
    }
}

Describe 'TOOLCHAIN-1: read-only automatic variables are left alone' {

    It 'nothing assigns the names PowerShell already owns' {
        # The sibling hazard, also in CLAUDE.md and also hit twice in one hour:
        # assigning $script:home in a Pester file kills the WHOLE FILE with
        # "Cannot overwrite variable HOME", and the message names nothing that
        # appears in the test.
        # pid (2026-09-09) and IsLinux / IsWindows / IsMacOS / IsCoreCLR (2026-09-30,
        # two lab scripts that stored the guest's OS in $isLinux and died on
        # 'Cannot overwrite variable IsLinux' before touching a machine).
        $owned = 'home|host|pwd|args|input|pid|isLinux|isWindows|isMacOS|isCoreCLR'
        $bad = foreach ($dir in @('tests', 'tools', 'src', 'lab', 'infra')) {
            $root = Join-Path $script:repoRoot $dir
            if (-not (Test-Path $root)) { continue }
            foreach ($file in Get-ChildItem $root -Recurse -Filter '*.ps1') {
                $lines = Get-Content $file.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match "(?i)^\s*\`$(script:|global:|local:)?($owned)\s*=[^=]") {
                        "$($file.Name):$($i + 1)"
                    }
                }
            }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'they are read-only, and the error names nothing you wrote'
    }
}
