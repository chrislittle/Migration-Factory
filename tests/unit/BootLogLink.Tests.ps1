#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BOOT-LOG-LINK-1 - the boot initializer that Install-TempDiskInit.ps1 writes
# runs as SYSTEM at every start. It kept its log at a fixed name in
# C:\Windows\Temp and rotated it with Move-Item -Force. Any local user can make
# files, folders and junctions in that folder, so a user could plant
# "NVMeTempDiskInit.log.3" (a folder with a payload) and ".log.4" (a junction
# to a protected folder), and SYSTEM moved the payload there at the next start.
#
# THE RULE: nothing the SYSTEM boot task does may act on a name a standard user
# can create. The log now lives next to the initializer, in the install folder
# that Protect-InstallPath gives a protected DACL (SEC-F1): write for SYSTEM and
# Administrators only, inherited by every file made in it.
#
# Two halves, as in TempDiskInitInstallSafety.Tests.ps1:
#   1. the generated initializer's text, lifted out of the installer by the
#      parser (never a regex over the whole file, which would match comments);
#   2. the initializer RUN under Windows PowerShell 5.1, with every disk cmdlet
#      replaced by a function, to see where its log really lands and rotates.

$script:winPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue


Describe 'BOOT-LOG-LINK-1: the boot initializer uses no path a standard user can create' {
    BeforeAll {
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
        $assign = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$initializerContent'
        }, $false)) | Select-Object -First 1
        $script:initializer = ''
        if ($assign) { $script:initializer = [string]$assign.Right.Expression.Value }

        # The initializer's own code, without its comments.
        $initAst = [System.Management.Automation.Language.Parser]::ParseInput($script:initializer, [ref]$null, [ref]$null)
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:initializer, [ref]$tokens, [ref]$null)
        $script:initCode = (@($tokens | Where-Object {
            $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment }) |
            ForEach-Object { $_.Text }) -join ' '
        $script:initAst = $initAst
    }

    It 'the installer still holds the initializer text the test reads' {
        $script:initializer | Should -Match 'NVMeTempDiskInit\.ps1 - installed by VmMigrationFactory'
        $script:initializer | Should -Match 'Get-PhysicalDisk'
    }

    It 'names no path under the Windows temporary folder or any user temporary folder' {
        $script:initCode | Should -Not -Match '(?i)Windows\\+Temp'
        $script:initCode | Should -Not -Match '(?i)\$env:(TEMP|TMP)\b'
        $script:initCode | Should -Not -Match '(?i)GetTempPath|GetTempFileName'
        $script:initCode | Should -Not -Match '(?i)\\Users\\+Public'
    }

    It 'keeps its log in its own folder, the protected install folder' {
        $script:initCode | Should -Match '\$logFile\s*=\s*Join-Path\s+\$PSScriptRoot\s+[''"]NVMeTempDiskInit\.log[''"]'
    }

    It 'writes no log at all when it cannot name its own folder, rather than falling back to a shared one' {
        $script:initCode | Should -Match 'if\s*\(\s*\$PSScriptRoot\s*\)'
        $logFn = @($script:initAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Log' }, $true))
        $logFn.Count | Should -Be 1
        $logFn[0].Extent.Text | Should -Match 'if\s*\(\s*\$logFile\s*\)'
    }

    It 'names every log file it moves or writes literally, so no wildcard reaches another name' {
        $calls = @($script:initAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -in @('Move-Item', 'Out-File', 'Get-Item', 'Test-Path', 'Remove-Item') -and
            $n.Extent.Text -match 'logFile' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) { $call.Extent.Text | Should -Match '-LiteralPath' -Because $call.Extent.Text }
    }

    It 'rotates at 500 KB, no sooner and no later' {
        # Review note: the measured run below rotates a 520 KB log, so it catches
        # a threshold raised above 520 KB but not one lowered. This pins the
        # one size check the initializer makes.
        $sizeChecks = @($script:initAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $n.Left.Extent.Text -match 'Length' }, $true))
        $sizeChecks.Count | Should -Be 1
        $sizeChecks[0].Operator | Should -Be 'Ige'
        $sizeChecks[0].Right.Extent.Text | Should -Be '500KB'
    }
}

Describe 'BOOT-LOG-LINK-1 measured: the initializer under Windows PowerShell 5.1' -Skip:($null -eq $script:winPowerShell) {
    BeforeAll {
        $script:powerShell51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1'
        . (Join-Path $PSScriptRoot '_TempWork.ps1')
        $script:work = New-VmfTestTemp -Prefix 'bootlog'

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
        $assign = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$initializerContent'
        }, $false)) | Select-Object -First 1
        $initializer = [string]$assign.Right.Expression.Value

        # A run of a text that still names a shared folder would WRITE there,
        # on the machine that runs the tests. Never run it: the result stays
        # empty and every test below fails, which is the right answer.
        $script:refusedToRun = ($initializer -match '(?i)Windows\\+Temp|\$env:(TEMP|TMP)\b')
        $script:measured = $null
        $script:harnessOutput = ''
        if (-not $script:refusedToRun) {
            $installDir = Join-Path $script:work 'install'
            New-Item -ItemType Directory -Path $installDir | Out-Null
            $initFile = Join-Path $installDir 'NVMeTempDiskInit.ps1'
            Set-Content -LiteralPath $initFile -Value $initializer -Encoding UTF8

            # A full-size log and three older ones, so this start rotates.
            $logFile = Join-Path $installDir 'NVMeTempDiskInit.log'
            [System.IO.File]::WriteAllBytes($logFile, (New-Object byte[] (520KB)))
            foreach ($i in 1..3) { Set-Content -LiteralPath "$logFile.$i" -Value "old log $i" -Encoding UTF8 }

            # Every disk cmdlet is a function here: no disk on this machine is
            # read or changed, whatever disks the machine has. A function wins
            # over a cmdlet of the same name.
            $probe = @'
param([string]$InitFile, [string]$OutFile)
$ErrorActionPreference = 'Stop'
function Get-PhysicalDisk { @() }
foreach ($name in @('Get-Disk', 'Initialize-Disk', 'New-Partition', 'Set-Partition', 'Get-Partition',
                    'Format-Volume', 'Get-StoragePool', 'New-StoragePool', 'Remove-StoragePool',
                    'Get-VirtualDisk', 'New-VirtualDisk', 'Remove-VirtualDisk', 'Get-StorageSubSystem')) {
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("throw 'the test does not allow $name'"))
}
$global:LASTEXITCODE = 0
& $InitFile
$code = $LASTEXITCODE
$dir = Split-Path -Parent $InitFile
[ordered]@{
    exitCode = $code
    files    = @(Get-ChildItem -LiteralPath $dir -Force | ForEach-Object { $_.Name } | Sort-Object)
    log      = [string](Get-Content -LiteralPath (Join-Path $dir 'NVMeTempDiskInit.log') -Raw -ErrorAction SilentlyContinue)
    log1Size = (Get-Item -LiteralPath (Join-Path $dir 'NVMeTempDiskInit.log.1') -ErrorAction SilentlyContinue).Length
    log4     = [string](Get-Content -LiteralPath (Join-Path $dir 'NVMeTempDiskInit.log.4') -Raw -ErrorAction SilentlyContinue)
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
            $probeFile = Join-Path $script:work 'probe.ps1'
            $resultFile = Join-Path $script:work 'result.json'
            Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8
            $script:harnessOutput = & $script:powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $probeFile -InitFile $initFile -OutFile $resultFile 2>&1 | Out-String
            if (Test-Path -LiteralPath $resultFile) {
                $script:measured = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            }
        }
    }

    AfterAll { Remove-VmfTestTemp }

    It 'runs, finds no NVMe Direct Disk, and ends with exit code 0' {
        $script:refusedToRun | Should -BeFalse -Because 'the initializer names a shared temporary folder'
        $script:measured | Should -Not -BeNullOrEmpty -Because "the harness said: $script:harnessOutput"
        $script:measured.exitCode | Should -Be 0
    }

    It 'writes its log in its own folder' {
        $script:measured.log | Should -Match 'NVMe temp disk initializer started\.'
        $script:measured.log | Should -Match 'No NVMe Direct Disk found'
    }

    It 'rotates the full log inside its own folder, and keeps four old logs' {
        $script:measured.log1Size | Should -BeGreaterOrEqual 520KB
        $script:measured.log4 | Should -Match 'old log 3'
        @($script:measured.files) | Should -Be @('NVMeTempDiskInit.log', 'NVMeTempDiskInit.log.1',
            'NVMeTempDiskInit.log.2', 'NVMeTempDiskInit.log.3', 'NVMeTempDiskInit.log.4', 'NVMeTempDiskInit.ps1')
    }
}
