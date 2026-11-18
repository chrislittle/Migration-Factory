#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ANALYZER-IEX-1, 2026-11-02. The analyzer rule against Invoke-Expression was
# excluded in PSScriptAnalyzerSettings.psd1, although no script in src, tools
# or lab used it. So a new use passed every check.
#
# Turning the rule on is NOT enough by itself: the analyzer gate in ci.yml and
# in tools/Invoke-VmfTests.ps1 fails only on severity Error, and this rule
# reports a Warning. So a new use would be printed in a table and still pass.
# The last test below scans the same paths the gate scans and fails on any
# finding of this rule - that is what makes a new use fail CI.
#
# The analyzer runs in a child pwsh. It loads its own copy of the Pester
# assembly (see tools/Invoke-VmfTests.ps1), and that must not happen inside
# the process that runs these tests.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:settingsPath = Join-Path $script:repoRoot 'PSScriptAnalyzerSettings.psd1'
    $script:settings = Import-PowerShellDataFile -LiteralPath $script:settingsPath
    $script:rule = 'PSAvoidUsingInvokeExpression'

    # The gate's own list of paths, read from ci.yml so the scan below cannot
    # drift from it.
    # PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
    # With no ci.yml, the list is read from the local runner, which holds the
    # same gate (and reads only the folders that are there: lab/ does not ship).
    $ciYml = Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml'
    # The public ci.yml is a different file; this repository's has its own runner set-up.
    $m = if ((Test-Path $ciYml) -and (Test-Path (Join-Path $script:repoRoot 'tools' 'Initialize-VmfCiRunner.ps1'))) {
        [regex]::Match((Get-Content $ciYml -Raw), "\`$results = (?<paths>@\([^)]*\)) \| ForEach-Object \{\s*Invoke-ScriptAnalyzer -Path")
    } else {
        [regex]::Match((Get-Content (Join-Path $script:repoRoot 'tools' 'Invoke-VmfTests.ps1') -Raw), "\`$found = (?<paths>@\([^)]*\)) \|")
    }
    $script:gatePaths = if ($m.Success) {
        @([regex]::Matches($m.Groups['paths'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { Test-Path (Join-Path $script:repoRoot $_) })
    } else { @() }

    # One child process gives both answers as JSON: what the repository's
    # settings do with a script that uses Invoke-Expression, and what the rule
    # finds in the gate's paths.
    $childScript = @'
param($Root, $Settings, $Rule, $PathsJson)
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force
$probe = @(Invoke-ScriptAnalyzer -ScriptDefinition 'param($x) Invoke-Expression $x' -Settings $Settings |
    Where-Object RuleName -eq $Rule | ForEach-Object { $_.RuleName })
$found = @(ConvertFrom-Json $PathsJson | ForEach-Object {
    Invoke-ScriptAnalyzer -Path (Join-Path $Root $_) -Recurse -IncludeRule $Rule
} | ForEach-Object { '{0}:{1}' -f $_.ScriptPath, $_.Line })
[pscustomobject]@{ probe = $probe; found = $found } | ConvertTo-Json -Compress
'@
    $childFile = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-analyzer-iex-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Set-Content -LiteralPath $childFile -Value $childScript -Encoding utf8
        $pathsJson = ConvertTo-Json -InputObject @($script:gatePaths) -Compress
        $out = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $childFile `
            -Root $script:repoRoot -Settings $script:settingsPath -Rule $script:rule -PathsJson $pathsJson 2>&1 | Out-String
        $script:childExit = $LASTEXITCODE
        $script:childOut = $out
        $script:child = try { ($out.Trim() -split "`n")[-1] | ConvertFrom-Json } catch { $null }
    } finally {
        Remove-Item -LiteralPath $childFile -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ANALYZER-IEX-1: the analyzer rule against Invoke-Expression is on' {

    It 'the settings file does not exclude the rule' {
        @($script:settings.ExcludeRules) | Should -Not -Contain $script:rule
    }

    It 'the settings file keeps the severity the rule reports' {
        @($script:settings.Severity) | Should -Contain 'Warning'
    }

    It 'the gate''s paths were read from ci.yml, or the scan below checks nothing' {
        $script:gatePaths | Should -Contain 'src'
        $script:gatePaths | Should -Contain 'tools'
    }

    It 'the analyzer ran in its own process' {
        $script:childExit | Should -Be 0 -Because $script:childOut
        $script:child | Should -Not -BeNullOrEmpty -Because $script:childOut
    }

    It 'with the repository''s settings, the analyzer reports a use of Invoke-Expression' {
        @($script:child.probe) | Should -Contain $script:rule
    }

    It 'and no script in the paths the gate scans uses Invoke-Expression' {
        @($script:child.found) -join "`n" | Should -BeNullOrEmpty -Because 'the gate fails only on Error, so this test is what stops a new use'
    }
}
