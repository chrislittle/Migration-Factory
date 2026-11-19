#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-WRITES-OUTSIDE-TESTDRIVE-1: no unit test writes at the root of a drive.
#
# FOUND 2026-11-13 on a Windows PC: C:\before\bin\bicep.exe and
# C:\bin\bicep.exe, each a 7-byte fake bicep. CiPool.Tests.ps1 set
# AZURE_CONFIG_DIR to 'C:\before', and its stand-in az.cmd wrote
# "%AZURE_CONFIG_DIR%\bin\bicep.exe". The function under test sets the
# variable first, so a green run writes inside the test folder - but a run
# where the function did not set it (a mutation check, a defect) wrote to
# whatever the process held: C:\before in one test, and "\bin" - the root of
# the current drive - in the tests that set nothing.
#
# So a unit test may set an environment variable or write a file only at a
# path it made: under TestDrive, or under the temporary folder. This file
# reads every PowerShell file in tests/unit through the parser (comments
# removed with Get-VmfCodeOnly) and fails on:
#
#   1. an environment variable set to a literal drive-root path
#      ($env:X = 'C:\...', [Environment]::SetEnvironmentVariable, Set-Item env:);
#   2. a command or .NET call that writes, given a literal drive-root path;
#   3. a command or .NET call that writes, given a variable the same file set
#      to a literal drive-root path;
#   4. a redirection (> or >>) to a literal drive-root path.
#
# A literal drive-root path is 'C:\...' (any drive letter) or '\name', which
# Windows reads as the root of the current drive. Reading such a path
# ($env:SystemRoot, 'C:\Windows\...') is allowed, and so is a value that is
# only data (a profile path in a fake listing, a value a test compares).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # 'C:\x' or 'C:/x', and '\x' (not '\\server', not a regex like '\b(').
    $script:driveRootPattern = '^(?:[A-Za-z]:[\\/]|\\[A-Za-z0-9_.\-]+(?:\\|$))'

    # Commands that write, create, move or delete at the path they are given.
    $script:writeCommands = @(
        'New-Item', 'ni', 'mkdir', 'md', 'Set-Content', 'Add-Content', 'Out-File',
        'Set-Item', 'si', 'Copy-Item', 'copy', 'cp', 'cpi', 'Move-Item', 'move', 'mv', 'mi',
        'Rename-Item', 'ren', 'rni', 'Remove-Item', 'rm', 'del', 'erase', 'rd', 'rmdir', 'ri',
        'Export-Csv', 'Export-Clixml', 'Tee-Object', 'tee', 'Expand-Archive', 'Compress-Archive',
        'Start-Transcript', 'Clear-Content')

    # .NET types whose static methods write at a path, and the methods that do.
    $script:writeTypes = @('IO.File', 'System.IO.File', 'IO.Directory', 'System.IO.Directory')
    $script:writeMethodPattern = '^(Write|Append|Create|Copy|Move|Delete|Replace|Open(?!Read|Text))'

    function script:Test-VmfDriveRootLiteral {
        param($Ast)
        if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return ([string]$Ast.Value -match $script:driveRootPattern)
        }
        return $false
    }

    function script:Get-VmfLiteralOf {
        # The string a right-hand side is, when it is one plain string.
        param($Ast)
        if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) { $Ast = $Ast.Expression }
        if ($Ast -is [System.Management.Automation.Language.PipelineAst] -and $Ast.PipelineElements.Count -eq 1 -and
            $Ast.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $Ast = $Ast.PipelineElements[0].Expression
        }
        if ($Ast -is [System.Management.Automation.Language.ConvertExpressionAst]) { $Ast = $Ast.Child }
        if (Test-VmfDriveRootLiteral $Ast) { return $Ast }
        return $null
    }

    function script:Get-VmfVariableName {
        param([System.Management.Automation.Language.VariableExpressionAst]$Ast)
        $name = $Ast.VariablePath.UserPath
        return ($name -replace '^(script|global|local|private):', '').ToLowerInvariant()
    }

    function script:Find-VmfDriveRootWrite {
        <#
        .SYNOPSIS
            Each place in PowerShell code that sets an environment variable,
            or writes, at a literal drive-root path. One line per finding.
        #>
        param([string]$Code, [string]$Name = 'code', [string[]]$SourceLines)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
        $found = [System.Collections.Generic.List[string]]::new()
        # Get-VmfCodeOnly turns a block comment into one space, so a line
        # number in the code is not the line in the file: find it there.
        $at = {
            param($node)
            $line = $node.Extent.StartLineNumber
            if ($SourceLines) {
                $first = ($node.Extent.Text -split "`n")[0].Trim()
                for ($i = 0; $i -lt $SourceLines.Count; $i++) {
                    if ($SourceLines[$i].Contains($first)) { $line = $i + 1; break }
                }
            }
            "${Name}:${line}: $($node.Extent.Text -replace '\s+', ' ')"
        }

        # Variables this code sets to a literal drive-root path.
        $rootVars = @{}
        foreach ($asg in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $left = $asg.Left
            if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
            $literal = Get-VmfLiteralOf $asg.Right
            if (-not $literal -or $left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ($left.VariablePath.IsDriveQualified -and $left.VariablePath.DriveName -eq 'env') {
                $found.Add("$(& $at $asg) - sets an environment variable to a drive-root path")
            }
            else {
                $rootVars[(Get-VmfVariableName $left)] = $true
            }
        }

        $usesRootVar = {
            param($node)
            foreach ($v in $node.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                if ($rootVars.ContainsKey((Get-VmfVariableName $v))) { return $true }
            }
            return $false
        }

        # Commands that write.
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cmdName = $cmd.GetCommandName()
            if (-not $cmdName -or $script:writeCommands -notcontains $cmdName) { continue }
            $cmdArgs = @($cmd.CommandElements | Select-Object -Skip 1)
            $isEnv = @($cmdArgs | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$_.Value -match '^env:' }).Count -gt 0
            foreach ($arg in $cmdArgs) {
                if ($arg -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($arg.Argument) { $arg = $arg.Argument } else { continue }
                }
                if (Test-VmfDriveRootLiteral $arg) {
                    $what = if ($isEnv) { 'sets an environment variable to a drive-root path' } else { 'writes at a drive-root path' }
                    $found.Add("$(& $at $cmd) - $what")
                    break
                }
                if (& $usesRootVar $arg) {
                    $found.Add("$(& $at $cmd) - writes at a path this file set to a drive-root path")
                    break
                }
            }
        }

        # .NET calls that write, and [Environment]::SetEnvironmentVariable.
        foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static }, $true)) {
            $typeName = if ($call.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $call.Expression.TypeName.FullName } else { '' }
            $member = if ($call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [string]$call.Member.Value } else { '' }
            $callArgs = @($call.Arguments)
            if ($typeName -in @('Environment', 'System.Environment') -and $member -eq 'SetEnvironmentVariable') {
                if ($callArgs.Count -ge 2 -and ((Test-VmfDriveRootLiteral $callArgs[1]) -or (& $usesRootVar $callArgs[1]))) {
                    $found.Add("$(& $at $call) - sets an environment variable to a drive-root path")
                }
                continue
            }
            if ($script:writeTypes -notcontains $typeName -or $member -notmatch $script:writeMethodPattern) { continue }
            foreach ($arg in $callArgs) {
                if ((Test-VmfDriveRootLiteral $arg) -or (& $usesRootVar $arg)) {
                    $found.Add("$(& $at $call) - writes at a drive-root path")
                    break
                }
            }
        }

        # Redirections to a file.
        foreach ($redir in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
            if ((Test-VmfDriveRootLiteral $redir.Location) -or (& $usesRootVar $redir.Location)) {
                $found.Add("$(& $at $redir) - redirects to a drive-root path")
            }
        }
        # Not ", $found.ToArray()": that hands back an empty array as ONE
        # item, so @(...).Count is 1 with no finding, and every "finds" test
        # below passed with the check removed (found by its mutation check).
        return $found.ToArray()
    }
}

Describe 'TEST-WRITES-OUTSIDE-TESTDRIVE-1: no unit test writes at the root of a drive' {

    It 'reads the unit test files, or it checks nothing' {
        @(Get-ChildItem (Join-Path $script:repoRoot 'tests' 'unit') -Filter '*.ps1').Count | Should -BeGreaterThan 100
    }

    It 'no unit test file sets an environment variable, or writes, at a literal drive-root path' {
        $all = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'tests' 'unit') -Filter '*.ps1') {
            $code = Get-VmfCodeOnly -Path $file.FullName -Language PowerShell
            $lines = [IO.File]::ReadAllLines($file.FullName)
            foreach ($finding in (Find-VmfDriveRootWrite -Code $code -Name $file.Name -SourceLines $lines)) { $finding }
        }
        @($all) | Should -BeNullOrEmpty -Because 'a test path goes under TestDrive or the temporary folder; a drive-root path writes on the PC that runs the tests'
    }
}

Describe 'TEST-WRITES-OUTSIDE-TESTDRIVE-1: what the check finds' {

    It 'finds an environment variable set to C:\ - the CiPool case' {
        @(Find-VmfDriveRootWrite -Code '$env:AZURE_CONFIG_DIR = ''C:\before''').Count | Should -Be 1
    }

    It 'finds an environment variable set to a path at the root of the current drive' {
        @(Find-VmfDriveRootWrite -Code '$env:X = ''\bin''').Count | Should -Be 1
        @(Find-VmfDriveRootWrite -Code '$env:X = "C:\a\$name"').Count | Should -Be 1
    }

    It 'finds [Environment]::SetEnvironmentVariable and Set-Item env: with a drive-root path' {
        @(Find-VmfDriveRootWrite -Code '[Environment]::SetEnvironmentVariable(''X'', ''C:\a'')').Count | Should -Be 1
        @(Find-VmfDriveRootWrite -Code 'Set-Item -Path env:X -Value ''D:\a''').Count | Should -Be 1
    }

    It 'finds a command that writes at a literal drive-root path' {
        foreach ($line in @(
                'New-Item -ItemType Directory -Path ''C:\rv''',
                'mkdir ''\rv''',
                '''x'' | Set-Content -LiteralPath ''C:\a.txt''',
                'Copy-Item $src -Destination ''C:\bin''',
                'Remove-Item ''C:\before'' -Recurse')) {
            @(Find-VmfDriveRootWrite -Code $line).Count | Should -Be 1 -Because $line
        }
    }

    It 'finds a .NET call that writes at a literal drive-root path' {
        @(Find-VmfDriveRootWrite -Code '[IO.File]::WriteAllText(''C:\a\b.txt'', ''x'')').Count | Should -Be 1
        @(Find-VmfDriveRootWrite -Code '[System.IO.Directory]::CreateDirectory(''\rv'')').Count | Should -Be 1
    }

    It 'finds a write to a variable the file set to a drive-root path' {
        @(Find-VmfDriveRootWrite -Code "`$script:dir = 'C:\rv'`nNew-Item -ItemType Directory -Path `$dir").Count | Should -Be 1
        @(Find-VmfDriveRootWrite -Code "`$d = 'C:\rv'`n[IO.File]::WriteAllText((Join-Path `$d 'a'), 'x')").Count | Should -Be 1
        @(Find-VmfDriveRootWrite -Code "`$d = 'C:\rv'`n'x' | Out-File `"`$d\a.txt`"").Count | Should -Be 1
    }

    It 'finds a redirection to a drive-root path' {
        @(Find-VmfDriveRootWrite -Code '''x'' > ''C:\a.txt''').Count | Should -Be 1
    }

    It 'allows a path under TestDrive or the temporary folder' {
        @(Find-VmfDriveRootWrite -Code '$env:AZURE_CONFIG_DIR = Join-Path $TestDrive ''before''') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code '$env:X = "$TestDrive\a"') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code 'New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ''vmf-a'')') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code '[IO.File]::WriteAllText("$env:TEMP\a.txt", ''x'')') | Should -BeNullOrEmpty
    }

    It 'allows a read of a real path, and a value that is only data' {
        @(Find-VmfDriveRootWrite -Code '$env:X = $env:SystemRoot') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code 'Get-Content ''C:\Windows\win.ini''') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code '$profilePath = ''C:\Users\vmfrunner''; $profilePath | Should -Be ''C:\Users\vmfrunner''') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code '$pattern = ''\b(a|b)\b''') | Should -BeNullOrEmpty
        @(Find-VmfDriveRootWrite -Code '$env:X = ''\\server\share''') | Should -BeNullOrEmpty
    }

    It 'does not read a comment as code' {
        $code = Get-VmfCodeOnly -Language PowerShell -Text "# `$env:AZURE_CONFIG_DIR = 'C:\before'`n`$kept = 1"
        @(Find-VmfDriveRootWrite -Code $code) | Should -BeNullOrEmpty
    }
}
