#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-STALE-POLICY-1 - nothing writes the two failure settings FAIL-1 removed.
#
# FAIL-1 removed `bootFailure` and `validationFailure` from the plan: a machine
# that fails after the change always goes back, so there is nothing left for
# them to choose. The engine reads neither. Five unit tests and two lab drills
# still wrote them, which told a reader the engine still read them.
#
# ONE place writes a setting on purpose: the StateMachine test "a stale plan
# asking for the removed hold STILL rolls back". A plan written before FAIL-1
# still carries the key, and that test proves it cannot bring the hold back.
# This file also checks that the test still writes it, so the proof cannot go
# quietly with the noise.
#
# The words stay allowed in COMMENTS (the history of why they went), so every
# file is read through Get-VmfCodeOnly - never a line filter (COMMENT-TRAP-1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:removedSetting = '\b(bootFailure|validationFailure)\b'
    $script:exemptTestName = 'a stale plan asking for the removed hold STILL rolls back'
    $script:exemptFile = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'tests' 'unit' 'StateMachine.Tests.ps1'))
    # This file names the settings in its own code, to look for them.
    $script:selfFile = [System.IO.Path]::GetFullPath($PSCommandPath)

    # The extents, in the CODE-ONLY text, of every It block with the exempt
    # name. The code-only text is still PowerShell, so the parser finds them.
    function script:Get-ExemptExtent {
        param([string]$Code)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
        @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'It' -and
            $node.CommandElements.Count -ge 2 -and
            $node.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.CommandElements[1].Value -eq $script:exemptTestName
        }, $true) | ForEach-Object { $_.Extent })
    }

    # Every place a file's code names a removed setting, outside the exempt
    # test. Returns one line for each, so a failure names the place.
    function script:Find-RemovedSetting {
        param([string]$Path, [switch]$AsStateMachineTests)
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -eq $script:selfFile) { return @() }
        $code = Get-VmfCodeOnly -Path $full
        $found = @([regex]::Matches($code, $script:removedSetting))
        if (-not $found) { return @() }
        $exempt = @()
        if ($AsStateMachineTests -or $full -eq $script:exemptFile) { $exempt = @(script:Get-ExemptExtent -Code $code) }
        @($found | Where-Object {
            $at = $_.Index
            -not ($exempt | Where-Object { $at -ge $_.StartOffset -and $at -lt $_.EndOffset })
        } | ForEach-Object {
            # About the line: a block comment that spans lines becomes one space.
            $line = [regex]::Matches($code.Substring(0, $_.Index), '\n').Count + 1
            $shown = $full
            if ($full.StartsWith($script:repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $shown = $full.Substring($script:repoRoot.Length) }
            '{0}, about line {1}: {2}' -f $shown, $line, $_.Value
        })
    }

    # Where a plan can come from: the tests and lab drills, the shipped
    # samples and schemas, the product, the lab builder and the tools.
    $script:scanned = @(foreach ($dir in 'tests', 'schemas', 'src', 'lab', 'tools') {
        $root = Join-Path $script:repoRoot $dir
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1', '*.json', '*.js' |
                Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } |
                ForEach-Object { $_.FullName }
        }
    })
}

Describe 'TEST-STALE-POLICY-1: no plan writes bootFailure or validationFailure' {

    It 'reads the files a plan can come from, the unit tests and lab drills among them' {
        $script:scanned.Count | Should -BeGreaterThan 100
        $script:scanned | Should -Contain $script:exemptFile
        # PUBLIC-SYNC-1: the lab drills do not ship to the public repository.
        if (Test-Path (Join-Path $script:repoRoot 'tests' 'lab')) {
            $script:scanned | Should -Contain ([System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'tests' 'lab' 'Invoke-ConversionDrill.ps1')))
            # REBUILD-REMOVE-LEDGER-1 deleted the second drill this named,
            # Invoke-WindowsSeedRedo: it drove only the rebuild.
            $script:scanned | Should -Contain ([System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'tests' 'lab' 'Invoke-V5Drill.ps1')))
        }
    }

    It 'no file names a removed setting in its code, outside the one deliberate stale-plan test' {
        $hits = @(foreach ($file in $script:scanned) { script:Find-RemovedSetting -Path $file })
        $hits | Should -BeNullOrEmpty -Because 'FAIL-1 removed both settings and the engine reads neither'
    }

    It 'the deliberate stale-plan test still gives its plan the removed hold' {
        $code = Get-VmfCodeOnly -Path $script:exemptFile
        $extents = @(script:Get-ExemptExtent -Code $code)
        $extents.Count | Should -Be 1 -Because 'exactly one test may write a removed setting'
        $extents[0].Text | Should -Match "-Policy\s+@\{\s*bootFailure\s*=\s*'hold'\s*\}"
        $extents[0].Text | Should -Match "Should -Be 'FAILED_ROLLED_BACK'"
    }
}

Describe 'TEST-STALE-POLICY-1: the check finds what it is for' {

    BeforeAll {
        $script:probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('test-stale-policy-1-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:probeDir
    }
    AfterAll {
        Remove-Item -LiteralPath $script:probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'finds a setting written as a hashtable key in a PowerShell plan' {
        $file = Join-Path $script:probeDir 'probe-key.ps1'
        Set-Content -LiteralPath $file -Value '$plan = @{ policy = @{ validationFailure = ''hold'' } }'
        @(script:Find-RemovedSetting -Path $file).Count | Should -Be 1
    }

    It 'finds a setting written as a property in a JSON plan' {
        $file = Join-Path $script:probeDir 'probe.json'
        Set-Content -LiteralPath $file -Value '{ "policy": { "bootFailure": "autoRollback" } }'
        @(script:Find-RemovedSetting -Path $file).Count | Should -Be 1
    }

    It 'lets the deliberate stale-plan test write the hold, and only that test' {
        $file = Join-Path $script:probeDir 'probe-exempt.ps1'
        Set-Content -LiteralPath $file -Value @(
            "It '$($script:exemptTestName)' {"
            "    `$plan = Script:NewPlanEntry -Policy @{ bootFailure = 'hold' }"
            '}'
            "It 'another test' {"
            "    `$plan = Script:NewPlanEntry -Policy @{ validationFailure = 'hold' }"
            '}'
        )
        $hits = @(script:Find-RemovedSetting -Path $file -AsStateMachineTests)
        $hits.Count | Should -Be 1
        $hits[0] | Should -Match 'about line 5: validationFailure$'
        # The exemption belongs to the StateMachine tests, not to any file
        # that copies the test name.
        @(script:Find-RemovedSetting -Path $file).Count | Should -Be 2
    }

    It 'ignores a setting named only in a comment, even a trailing one' {
        $file = Join-Path $script:probeDir 'probe-comment.ps1'
        Set-Content -LiteralPath $file -Value @(
            '# FAIL-1 removed bootFailure.'
            '$policy = @{} # validationFailure is gone'
        )
        @(script:Find-RemovedSetting -Path $file) | Should -BeNullOrEmpty
    }
}
