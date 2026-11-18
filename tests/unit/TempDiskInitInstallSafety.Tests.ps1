#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SEC-F1 - Install-TempDiskInit.ps1 registers a scheduled task that runs a
# PowerShell file as SYSTEM at every boot. Whoever can write that file owns the
# machine, so WHERE the file lives and WHO can write it is the whole security
# property of this script.
#
# THE DEFECT. The file went to C:\AdminScripts. A new first-level folder under
# the root of the drive inherits "Authenticated Users: Modify" from C:\, so
# every authenticated user on the machine - a domain user with a session on a
# jump box, a service account, anybody at all - could replace the contents and
# get SYSTEM code execution on the next boot, with persistence. The engine
# installs this on EVERY Windows machine whose target is an nvme-temp size, so
# migration created the weakness fleet-wide.
#
# The tests below are in two halves, on purpose:
#   1. what the source says - the gates exist, and they are in the right ORDER.
#      Order is half the property: a check after the write is not a check.
#   2. what the code DOES, measured by running the script's own functions under
#      Windows PowerShell 5.1 (the interpreter Azure RunCommand uses for a
#      Windows guest script - never pwsh). Reading a DACL out of source text
#      proves nothing about the DACL that lands on disk.
#
# The second half needs powershell.exe. CI runs on windows-latest, which has it.
$script:winPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue

Describe 'SEC-F1: the boot task runs a file only an administrator can write' {
    BeforeAll {
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1'
        $script:source = Get-Content $script:scriptPath -Raw

        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:scriptPath, [ref]$null, [ref]$null)
        $script:functions = @($script:ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))

        # The main flow is the one top-level try. Reading command offsets out of
        # it is how the ORDER tests below stay honest: a regex over the whole
        # file cannot tell "before the write" from "after it".
        $script:mainTry = @($script:ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false)) |
            Select-Object -Last 1
        $script:mainCalls = @($script:mainTry.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { [pscustomobject]@{ Name = $_.GetCommandName(); Offset = $_.Extent.StartOffset } } |
            Where-Object { $_.Name })

        function Script:FirstCall {
            param([string]$Name)
            $hit = @($script:mainCalls | Where-Object { $_.Name -eq $Name } | Sort-Object Offset | Select-Object -First 1)
            if ($hit.Count -eq 0) { return -1 }
            return $hit[0].Offset
        }

        function Script:FunctionText {
            param([string]$Name)
            $hit = @($script:functions | Where-Object { $_.Name -eq $Name })
            if ($hit.Count -eq 0) { return '' }
            return $hit[0].Extent.Text
        }
    }

    It 'does not install into a first-level folder of the system drive' {
        # The finding itself. C:\AdminScripts is a folder any authenticated user
        # can create, and the one they cannot be stopped from modifying once the
        # root of the drive has been inherited from.
        $script:source | Should -Not -Match "InstallPath\s*=\s*'C:\\AdminScripts'"
        Script:FunctionText 'Get-DefaultInstallPath' | Should -Match 'ProgramData'
    }

    It 'creates the folder with an explicit DACL rather than with New-Item' {
        # New-Item takes whatever the parent hands down. CreateDirectory with a
        # DirectorySecurity writes the permissions AS PART OF the create, so
        # there is no moment where the folder exists and is open.
        $protect = Script:FunctionText 'Protect-InstallPath'
        $protect | Should -Match '\[System\.IO\.Directory\]::CreateDirectory\(\$Path, \$security\)'
        $protect | Should -Not -Match 'New-Item'
    }

    It 'switches inheritance off, so nothing the parent grants reaches the folder' {
        Script:FunctionText 'New-ProtectedSecurity' |
            Should -Match 'SetAccessRuleProtection\(\$true, \$false\)'
    }

    It 'gives full control to SYSTEM and Administrators only, and read and execute to Users' {
        $security = Script:FunctionText 'New-ProtectedSecurity'
        $security | Should -Match "SecurityIdentifier\('S-1-5-18'\)"       # SYSTEM
        $security | Should -Match "SecurityIdentifier\('S-1-5-32-544'\)"   # Administrators
        $security | Should -Match "SecurityIdentifier\('S-1-5-32-545'\)"   # Users
        $security | Should -Match '\$readAndRun = \[System\.Security\.AccessControl\.FileSystemRights\]::ReadAndExecute'
        $security | Should -Match '\$usersSid, \$readAndRun'
    }

    It 'refuses a junction or a link at the install path' {
        # Without this the write lands wherever the link points, chosen by
        # whoever made the link - and making one needs no privilege.
        $protect = Script:FunctionText 'Protect-InstallPath'
        $protect | Should -Match 'Get-ReparseProblem'
        Script:FunctionText 'Get-ReparseProblem' | Should -Match 'ReparsePoint'
    }

    It 'refuses an install folder whose owner is not an administrator' {
        # An owner can always give itself permissions again, so a folder an
        # unprivileged principal owns can never be made safe.
        Script:FunctionText 'Protect-InstallPath' | Should -Match 'Get-OwnerProblem'
        Script:FunctionText 'Get-OwnerProblem' | Should -Match 'Test-AdministrativeSid'
    }

    It 'accepts an owner who is a member of the local Administrators group, not only the group SID' {
        # Windows makes the CREATOR the owner. A folder an administrator, an
        # installer or a management agent made is owned by that person's user
        # SID, not by S-1-5-32-544 - and that machine is legitimate. Trusting
        # only the two well-known SIDs stops it at FAILED_NEEDS_ATTENTION.
        $test = Script:FunctionText 'Test-AdministrativeSid'
        $test | Should -Match 'Get-LocalAdminSidList'
        Script:FunctionText 'Get-LocalAdminSidList' | Should -Match 'WinNT://'
        # ...and the group name is localized, so it must be found by SID.
        Script:FunctionText 'Get-LocalAdminSidList' | Should -Match "SecurityIdentifier\('S-1-5-32-544'\)"
    }

    It 'reads the permissions back off the disk instead of assuming the write took' {
        # CreateDirectory(path, security) does NOTHING to a folder that already
        # exists. Without the read-back, a folder created in the moment between
        # the test and the create keeps the permissions its maker chose.
        $protect = Script:FunctionText 'Protect-InstallPath'
        $protect | Should -Match 'Get-DaclProblem'
        $dacl = Script:FunctionText 'Get-DaclProblem'
        $dacl | Should -Match 'AreAccessRulesProtected'
        $dacl | Should -Match 'Test-AdministrativeSid'
    }

    It 'writes nothing until the folder has passed' {
        $protect = Script:FirstCall 'Protect-InstallPath'
        $write = Script:FirstCall 'Write-ProtectedFile'
        $protect | Should -BeGreaterThan -1
        $write | Should -BeGreaterThan -1
        $protect | Should -BeLessThan $write
    }

    It 'registers the task only after the folder and the files have passed' {
        $write = Script:FirstCall 'Write-ProtectedFile'
        $register = Script:FirstCall 'Register-ScheduledTask'
        # Both offsets must be REAL. Comparing against a -1 that means "this
        # call is not in the file" is how an order test passes on a script that
        # has no gate at all.
        $write | Should -BeGreaterThan -1
        $register | Should -BeGreaterThan -1
        $register | Should -BeGreaterThan $write
    }

    It 'ends in BLOCKED when the folder cannot be trusted, and BLOCKED is a value the engine knows' {
        # Fail closed: no file, no task, and a result the state machine reads as
        # a stopped machine rather than a finished step.
        $script:source | Should -Match "Emit -Result 'BLOCKED' -ErrorDetail ""A SYSTEM boot task cannot safely run a file"
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.result.enum | Should -Contain 'BLOCKED'
    }

    It 'runs the full path to powershell.exe, not a name the system PATH resolves' {
        $script:source | Should -Match "\`$powerShellExe = Join-Path \`$env:SystemRoot 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'"
        $script:source | Should -Match 'New-ScheduledTaskAction -Execute \$powerShellExe'
        $script:source | Should -Not -Match "New-ScheduledTaskAction -Execute 'powershell\.exe'"
    }

    It 'gives the same treatment to the old C:\AdminScripts folder before it deletes anything there' {
        # This code runs as SYSTEM. Any authenticated user can create
        # C:\AdminScripts, and a junction needs no privilege, so a delete that
        # follows one is a SYSTEM delete at a path that user chose.
        $legacy = Script:FunctionText 'Remove-LegacyInstall'
        $legacy | Should -Match 'Get-ReparseProblem'
        $legacy | Should -Match 'Get-OwnerProblem'
        # and it removes only a file that carries the line this tool writes
        $legacy | Should -Match 'installed by VmMigrationFactory'
        $legacy.IndexOf('Get-ReparseProblem') | Should -BeLessThan $legacy.IndexOf('Remove-Item')
    }

    It 'cleans up the old folder only after the new task is registered' {
        # Otherwise a BLOCKED run deletes the file while the old task still
        # points at it.
        $register = Script:FirstCall 'Register-ScheduledTask'
        $cleanup = Script:FirstCall 'Remove-LegacyInstall'
        $cleanup | Should -BeGreaterThan -1
        $cleanup | Should -BeGreaterThan $register
    }

    It 'never stops the migration over the old folder' {
        # A user who can create C:\AdminScripts must not thereby be able to stop
        # every migration on the machine. What this script cannot vouch for it
        # leaves alone, and says so.
        $legacy = Script:FunctionText 'Remove-LegacyInstall'
        $legacy | Should -Not -Match 'Emit -Result'
        $legacy | Should -Match "Add-Check 'old install folder' 'WARN'"
        $legacy | Should -Match 'Add-Warning'
    }
}

Describe 'SEC-F1 measured: the functions run under Windows PowerShell 5.1' -Skip:($null -eq $script:winPowerShell) {
    # Azure RunCommand executes a Windows guest script under Windows PowerShell
    # 5.1 on .NET Framework, so that is the interpreter these run in here. It is
    # also the only way to see the DACL that actually lands on disk.
    BeforeAll {
        # Found again here: a variable set at discovery is not there in the run
        # phase, and -Skip is the only thing the discovery-phase one is for.
        $script:powerShell51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:scriptPath = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1'
        # TEMP-LITTER-1: this folder was always removed. The one the 5.1
        # harness makes was NOT - 459 of them were measured in the temp folder,
        # because the harness builds folders that deny this very account (which
        # is the whole point of the test), Remove-Item was refused every time,
        # and -ErrorAction SilentlyContinue swallowed the refusal. It now lives
        # UNDER this folder, and Remove-VmfTestTemp puts the permission back
        # before removing and throws if anything survives.
        . (Join-Path $PSScriptRoot '_TempWork.ps1')
        $script:work = New-VmfTestTemp -Prefix 'secf1'

        # Take the script's own function definitions and nothing else: the rest
        # of the file registers a scheduled task, which a test must not do.
        $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
        $helpers = (@($sourceAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) |
            ForEach-Object { $_.Extent.Text }) -join "`n`n"

        $harness = @'
$ErrorActionPreference = 'Stop'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:warnings = [System.Collections.Generic.List[string]]::new()
$script:adminSidCache = $null
$out = [ordered]@{}
$root = Join-Path $WorkRoot ("run-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null

function Get-Rules { param($Path)
    @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
        ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" })
}

# a folder this script makes
$fresh = Join-Path $root 'fresh'
$out.freshProblem = [string](Protect-InstallPath -Path $fresh)
$out.freshProtected = (Get-Acl -LiteralPath $fresh).AreAccessRulesProtected
$out.freshRules = Get-Rules $fresh
$out.freshDaclProblem = [string](Get-DaclProblem -Path $fresh)

# a file it writes (in a plain folder: the protected one keeps this very test
# account out, which is the point of it)
$plain = Join-Path $root 'plain'
New-Item -ItemType Directory -Path $plain | Out-Null
$initFile = Join-Path $plain 'NVMeTempDiskInit.ps1'
$out.fileProblem = [string](Write-ProtectedFile -Path $initFile -Content "# NVMeTempDiskInit.ps1 - installed by VmMigrationFactory (Install-TempDiskInit.ps1)")
$out.fileProtected = (Get-Acl -LiteralPath $initFile).AreAccessRulesProtected
$out.fileRules = Get-Rules $initFile

# a junction at the install path
$target = Join-Path $root 'target'
New-Item -ItemType Directory -Path $target | Out-Null
$junction = Join-Path $root 'junction'
cmd.exe /c "mklink /J ""$junction"" ""$target""" | Out-Null
$out.junctionMade = (Test-Path -LiteralPath $junction)
$out.junctionProblem = [string](Protect-InstallPath -Path $junction)

# a folder that inherits from its parent is repaired
$inherited = Join-Path $root 'inherited'
New-Item -ItemType Directory -Path $inherited | Out-Null
$out.inheritedBefore = [string](Get-DaclProblem -Path $inherited)
$out.inheritedProblem = [string](Protect-InstallPath -Path $inherited)
$out.inheritedProtectedAfter = (Get-Acl -LiteralPath $inherited).AreAccessRulesProtected

# A folder owned by an administrator ACCOUNT, rather than by the Administrators
# group. The owner is set here EXPLICITLY instead of being read back from a
# folder this process happened to create, because Windows picks that owner from
# the token's default: an unelevated account owns what it creates, while an
# ELEVATED one creates objects owned by S-1-5-32-544. Reading it back therefore
# measured the runner, not the code, and passed on a workstation while failing
# in CI. Setting a SID the token already holds needs no privilege.
$out.currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ownedFolder = Join-Path $root 'owned-by-account'
New-Item -ItemType Directory -Path $ownedFolder | Out-Null
$ownAcl = Get-Acl -LiteralPath $ownedFolder
$ownAcl.SetOwner([System.Security.Principal.SecurityIdentifier]::new($out.currentUserSid))
Set-Acl -LiteralPath $ownedFolder -AclObject $ownAcl
$out.ownFolderOwnerSid = (Get-Acl -LiteralPath $ownedFolder).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
$out.ownFolderOwnerProblem = [string](Get-OwnerProblem -Path $ownedFolder)

# a name that is already a hard link must not be written through
$victim = Join-Path $root 'victim.txt'
Set-Content -LiteralPath $victim -Value 'ORIGINAL CONTENT'
$linked = Join-Path $plain 'Wait-ForDrive-D.ps1.snippet.txt'
cmd.exe /c "mklink /H ""$linked"" ""$victim""" | Out-Null
$out.hardLinkMade = (Test-Path -LiteralPath $linked)
$out.hardLinkWriteProblem = [string](Write-ProtectedFile -Path $linked -Content 'REPLACED BY THE INSTALLER')
$out.victimContent = (Get-Content -LiteralPath $victim -Raw).Trim()

# what each SID is judged to be
$out.sidVerdicts = [ordered]@{}
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-21-1-2-3-500', 'S-1-5-21-1-2-3-512',
                   'S-1-5-11', 'S-1-1-0', 'S-1-5-21-9-9-9-1234')) {
    $out.sidVerdicts[$sid] = [bool](Test-AdministrativeSid -Sid $sid)
}

# the old folder: a junction must not be followed
$legacyReal = Join-Path $root 'legacy-real'
New-Item -ItemType Directory -Path $legacyReal | Out-Null
$behindJunction = Join-Path $legacyReal 'NVMeTempDiskInit.ps1'
Set-Content -LiteralPath $behindJunction -Value '# NVMeTempDiskInit.ps1 - installed by VmMigrationFactory (Install-TempDiskInit.ps1)'
$legacyLink = Join-Path $root 'legacy-link'
cmd.exe /c "mklink /J ""$legacyLink"" ""$legacyReal""" | Out-Null
$script:checks.Clear()
$script:warnings.Clear()
Remove-LegacyInstall -Path $legacyLink
$out.junctionLegacySurvived = (Test-Path -LiteralPath $behindJunction)
$out.junctionLegacyChecks = @($script:checks | ForEach-Object { "$($_.name)=$($_.status): $($_.detail)" })
$out.junctionLegacyWarnings = @($script:warnings)

# the old folder: ours goes, a stranger's file stays, the folder stays
$legacy = Join-Path $root 'legacy'
New-Item -ItemType Directory -Path $legacy | Out-Null
Set-Content -LiteralPath (Join-Path $legacy 'NVMeTempDiskInit.ps1') -Value '# NVMeTempDiskInit.ps1 - installed by VmMigrationFactory (Install-TempDiskInit.ps1)'
Set-Content -LiteralPath (Join-Path $legacy 'Wait-ForDrive-D.ps1.snippet.txt') -Value '# this file is not ours'
$script:checks.Clear()
Remove-LegacyInstall -Path $legacy
$out.legacyOursGone = -not (Test-Path -LiteralPath (Join-Path $legacy 'NVMeTempDiskInit.ps1'))
$out.legacyStrangerKept = (Test-Path -LiteralPath (Join-Path $legacy 'Wait-ForDrive-D.ps1.snippet.txt'))
$out.legacyFolderKept = (Test-Path -LiteralPath $legacy)
$out.legacyChecks = @($script:checks | ForEach-Object { "$($_.name)=$($_.status)" })

# LAST, because it replaces a function: an owner who is not an administrator.
# The folder must be refused with nothing changed on it.
$stranger = Join-Path $root 'stranger'
New-Item -ItemType Directory -Path $stranger | Out-Null
function Test-AdministrativeSid { param([string]$Sid) return $false }
$out.strangerProblem = [string](Protect-InstallPath -Path $stranger)
$out.strangerProtectedAfter = (Get-Acl -LiteralPath $stranger).AreAccessRulesProtected

# TEMP-LITTER-1: this used to remove $root here with -ErrorAction
# SilentlyContinue, and the removal was REFUSED every time - the folders above
# deny this account on purpose. The caller owns it now: $root sits under the
# work folder, and Remove-VmfTestTemp puts the permission back, removes it, and
# throws if any of it survives. Report what is here so the caller can say so.
$out.rootPath = $root
$out.rootItems = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue).Count
$out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@

        $harnessFile = Join-Path $script:work 'harness.ps1'
        $resultFile = Join-Path $script:work 'result.json'
        Set-Content -LiteralPath $harnessFile -Encoding UTF8 -Value (
            "param([string]`$OutFile, [string]`$WorkRoot)`n`n" + $helpers + "`n`n" + $harness)

        $script:harnessOutput = & $script:powerShell51 -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $harnessFile -OutFile $resultFile -WorkRoot $script:work 2>&1 | Out-String
        $script:measured = $null
        if (Test-Path -LiteralPath $resultFile) {
            $script:measured = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        }
    }

    AfterAll {
        # TEMP-LITTER-1. A throw here fails the container, which is the point:
        # the removal this replaced could not succeed and never said so.
        Remove-VmfTestTemp
    }

    It 'the functions load and run under 5.1 at all' {
        # A .NET Core-only API, a ternary or any pwsh-only syntax dies here,
        # which is the whole reason this runs in powershell.exe.
        $script:measured | Should -Not -BeNullOrEmpty -Because "the harness said: $script:harnessOutput"
    }

    It 'the folder it makes inherits nothing and gives write permission to nobody but SYSTEM and Administrators' {
        $script:measured.freshProblem | Should -BeNullOrEmpty
        $script:measured.freshProtected | Should -BeTrue
        $script:measured.freshDaclProblem | Should -BeNullOrEmpty
        @($script:measured.freshRules) | Should -Contain 'S-1-5-18=FullControl'
        @($script:measured.freshRules) | Should -Contain 'S-1-5-32-544=FullControl'
        foreach ($rule in @($script:measured.freshRules)) {
            $rule | Should -Not -Match '^S-1-5-32-545=.*(FullControl|Modify|Write)'
        }
    }

    It 'the file it writes carries the same permissions' {
        $script:measured.fileProblem | Should -BeNullOrEmpty
        $script:measured.fileProtected | Should -BeTrue
        @($script:measured.fileRules) | Should -Contain 'S-1-5-18=FullControl'
    }

    It 'a junction at the install path is refused' {
        $script:measured.junctionMade | Should -BeTrue -Because 'the test needs a real junction to prove anything'
        $script:measured.junctionProblem | Should -Match 'junction or a link'
    }

    It 'a folder that already exists and inherits from its parent is repaired' {
        $script:measured.inheritedBefore | Should -Match 'still inherits'
        $script:measured.inheritedProblem | Should -BeNullOrEmpty
        $script:measured.inheritedProtectedAfter | Should -BeTrue
    }

    It 'a folder an administrator ACCOUNT created is accepted, not refused' {
        # The regression this exists for: an administrator ACCOUNT owns what it
        # creates, so the owner is that account's own SID and not
        # S-1-5-32-544. Trusting only the group SID stops a legitimate machine.
        # The harness sets the owner explicitly, because whether a created
        # folder comes back owned by the account or by the group depends on
        # whether the process is elevated - which measures the runner, not the
        # code under test.
        $script:measured | Should -Not -BeNullOrEmpty -Because "the harness said: $script:harnessOutput"
        $script:measured.ownFolderOwnerSid | Should -Match '^S-1-5-21-' -Because 'this has to be a real account SID or the test proves nothing'
        $script:measured.ownFolderOwnerSid | Should -Be $script:measured.currentUserSid
        $script:measured.ownFolderOwnerSid | Should -Not -Be 'S-1-5-32-544'
        $script:measured.ownFolderOwnerProblem | Should -BeNullOrEmpty -Because 'this account is a member of the local Administrators group'
    }

    It 'an owner who is not an administrator is refused, with nothing changed on the folder' {
        $script:measured.strangerProblem | Should -Match 'not an administrator'
        $script:measured.strangerProtectedAfter | Should -BeFalse -Because 'the refusal must come BEFORE any change to the folder'
    }

    It 'judges each kind of SID the way an administrator would' {
        $script:measured.sidVerdicts.'S-1-5-18' | Should -BeTrue           # SYSTEM
        $script:measured.sidVerdicts.'S-1-5-32-544' | Should -BeTrue       # Administrators
        $script:measured.sidVerdicts.'S-1-5-21-1-2-3-500' | Should -BeTrue # built-in Administrator
        $script:measured.sidVerdicts.'S-1-5-21-1-2-3-512' | Should -BeTrue # Domain Admins
        $script:measured.sidVerdicts.'S-1-5-11' | Should -BeFalse          # Authenticated Users
        $script:measured.sidVerdicts.'S-1-1-0' | Should -BeFalse           # Everyone
        $script:measured.sidVerdicts.'S-1-5-21-9-9-9-1234' | Should -BeFalse
    }

    It 'a name that is already a hard link is broken rather than written through' {
        $script:measured.hardLinkMade | Should -BeTrue -Because 'the test needs a real hard link to prove anything'
        $script:measured.victimContent | Should -Be 'ORIGINAL CONTENT'
    }

    It 'the old folder is not deleted through a junction' {
        # MEASURED, and the reason this test file exists in this shape: with an
        # unprivileged junction at C:\AdminScripts, a cleanup with no reparse
        # check deletes a file that is not ours, as SYSTEM, at a path the user
        # chose.
        $script:measured.junctionLegacySurvived | Should -BeTrue
        ($script:measured.junctionLegacyChecks -join ' ') | Should -Match 'old install folder=WARN'
        @($script:measured.junctionLegacyWarnings).Count | Should -BeGreaterThan 0
    }

    It 'the old folder loses the file this tool wrote and keeps everything else' {
        $script:measured.legacyOursGone | Should -BeTrue
        $script:measured.legacyStrangerKept | Should -BeTrue -Because 'a file that does not carry our line is somebody else''s file'
        $script:measured.legacyFolderKept | Should -BeTrue -Because 'the folder can hold files this tool did not write'
    }
}

# SEC-F1-FLAKE-1, CLOSED 2026-09-09. It was never a flaky test.
#
# The block above failed in 3 of 8 full suite runs and never when this file ran
# alone. It was mentioned four times, filed once, and read as flakiness five
# times - by me, an hour before this was written. Nobody had read the error.
#
# The error was:
#   Remove-Item : Cannot remove item ...\legacy\NVMeTempDiskInit.ps1:
#   The process cannot access the file ... it is being used by another process.
#
# A sharing violation on a file the script had just written: the antivirus
# scanner still had it open. A full suite writes thousands of files and the
# scanner falls behind, which is exactly why it needed a busy machine to show.
#
# And the delete is PRODUCT CODE, in a guest script that runs on customers'
# machines during a migration, under $ErrorActionPreference = 'Stop'. Every
# other failure in that function warns and continues. That one line ended the
# script.
#
# This Describe makes the race deterministic: hold the file open, then run the
# same function. What used to happen one run in three now happens every time.
Describe 'SEC-F1-FLAKE-1: a locked file warns, it does not end the script' {

    BeforeAll {
        $script:pwsh51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:guest = Join-Path $script:root 'src' 'guest' 'windows' 'Install-TempDiskInit.ps1'
    }

    It 'the delete retries rather than giving up on the first refusal' {
        $text = Get-Content $script:guest -Raw
        $text | Should -Match 'for \(\$attempt = 1; \$attempt -le 5; \$attempt\+\+\)'
        $text | Should -Match 'Remove-Item -LiteralPath \$file -Force -ErrorAction Stop'
    }

    It 'and a delete that never succeeds warns and carries on' {
        # The same shape as every other failure in that function.
        $text = Get-Content $script:guest -Raw
        $text | Should -Match 'if \(-not \$removed\) \{'
        $text | Should -Match 'left as it is: \$lastProblem'
        $text | Should -Match 'did not remove \$\{file\}: \$lastProblem'
    }

    It 'MEASURED: a file held open by another process does not end the script' -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        # The deterministic version of the race. A FileStream with no sharing
        # is what the scanner does to a file it is reading.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("vmf-lock-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            $file = Join-Path $work 'NVMeTempDiskInit.ps1'
            Set-Content -LiteralPath $file -Value '# installed by VmMigrationFactory' -Encoding UTF8

            # Take the function definitions the same way the block above does.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:guest, [ref]$null, [ref]$null)
            $helpers = (@($ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) |
                ForEach-Object { $_.Extent.Text }) -join "`n`n"

            $probe = @'
$ErrorActionPreference = 'Stop'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:warnings = [System.Collections.Generic.List[string]]::new()
$script:adminSidCache = $null
Remove-LegacyInstall -Path $Folder
[ordered]@{
    checks   = @($script:checks | ForEach-Object { "$($_.name)=$($_.status)" })
    warnings = @($script:warnings)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
            $harnessFile = Join-Path $work 'probe.ps1'
            $outFile = Join-Path $work 'out.json'
            Set-Content -LiteralPath $harnessFile -Encoding UTF8 -Value (
                "param([string]`$Folder, [string]`$OutFile)`n`n" + $helpers + "`n`n" + $probe)

            # FileShare.Read, NOT None. This matters, and the first version of
            # this test got it wrong: with None the script's own Get-Content
            # check throws first, takes the existing $fileProblem branch and
            # never reaches the delete - so the test passed with the retry
            # mutated away. Caught by the mutation, not by reading.
            #
            # FileShare.Read is also what a scanner actually does: the file
            # stays readable, and only the delete is refused.
            $stream = [System.IO.File]::Open($file, 'Open', 'Read', 'Read')
            try {
                $out = & $script:pwsh51 -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                    -File $harnessFile -Folder $work -OutFile $outFile 2>&1 | Out-String
                (Test-Path -LiteralPath $outFile) | Should -BeTrue -Because "the script must finish, not throw. It said: $out"
                $res = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
                @($res.warnings) -join ' ' | Should -Match 'did not remove'
                @($res.checks) | Should -Contain 'old file NVMeTempDiskInit.ps1=WARN'
            }
            finally { $stream.Dispose() }
        }
        finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
