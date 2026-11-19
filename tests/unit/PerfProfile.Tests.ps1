#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERF-PROFILE-1: each new service instance or runspace spent about 9 seconds in
# its start-up script (src/facade/app/profile.ps1).
#
# Measured on the lab install (PERF-ANALYSIS-1), the p50 of 109 cold calls:
# 7.0 s importing the two modules up to the first Az message, then 2.3 s in
# Connect-AzAccount -Identity. Microsoft's PowerShell guide for Functions: the
# profile "is run for each runspace created", so a warm instance pays it again
# for every new runspace (188 calls in 7 days, p50 7.4 s).
#
# MEASURED HERE, 2026-11-02, a fresh pwsh each time, three runs:
#   - the module dot-sourced 148 files one at a time: about 1,800 ms;
#   - one file at a time as a script block (no file check): about 1,100 ms;
#   - every file in ONE script block: about 220 ms.
# The cost is per script block, not per byte, so the module now loads its files
# as one script block. Two things change with that, and this file holds both:
#   1. a function has no file of its own, so $PSScriptRoot inside one is empty -
#      every path is built from $script:VmfModuleRoot instead;
#   2. a parse error must still say WHICH file it is in.
#
# And the sign-in. PERF-PROFILE-1 kept a runspace in a signed-in process from
# signing in again: Azure PowerShell keeps its context at process level (the
# same guide), MEASURED here: a context cleared in one runspace is gone in a
# second one, so a second connect REPLACED the context that the other
# runspaces were using in the middle of their calls. FACADE-SIGNIN-COLD-1
# removed the sign-in: the service takes its tokens from the managed identity
# endpoint (AzureOpsToken.ps1), so the script makes no Az call at all.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:moduleDir = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:profilePath = Join-Path $script:repoRoot 'src' 'facade' 'app' 'profile.ps1'
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:moduleDir 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:moduleFiles = @(
        @(Get-ChildItem (Join-Path $script:moduleDir 'Private') -Filter *.ps1 -Recurse) +
        @(Get-ChildItem (Join-Path $script:moduleDir 'Public') -Filter *.ps1 -Recurse))
    $script:temp = New-VmfTestTemp -Prefix 'perfprofile'

    # Run the shipped profile.ps1 in a new pwsh, with every command it may
    # call replaced by a stub that records the call. Returns the record.
    function Global:InvokePpProfile {
        # -InService: the module's Test-VmfTokenFromIdentityEndpoint answers
        # true, as in the web service. -ImportFails: a module does not load.
        param([switch]$InService, [switch]$ImportFails)
        $out = Join-Path $script:temp ([guid]::NewGuid().ToString('N') + '.json')
        $harness = @"
`$ErrorActionPreference = 'Stop'
`$global:ppCalls = [System.Collections.Generic.List[object]]::new()
`$global:ppInfo = [System.Collections.Generic.List[string]]::new()
function global:Import-Module { param([Parameter(Position = 0)]`$Name, `$RequiredVersion) `$global:ppCalls.Add(@{ c = 'Import-Module'; a = [string]`$Name; v = [string]`$RequiredVersion })
    if ('$ImportFails' -eq 'True') { throw 'The module could not load.' } }
function global:Get-Module { param([Parameter(Position = 0)]`$Name) `$global:ppCalls.Add(@{ c = 'Get-Module'; a = [string]`$Name })
    New-Module -Name VmMigrationFactory -ScriptBlock { function Test-VmfTokenFromIdentityEndpoint { '$InService' -eq 'True' } } }
# Every Az command a start-up script ever called, recorded, so a call that
# comes back is seen.
foreach (`$n in 'Connect-AzAccount', 'Disable-AzContextAutosave', 'Get-AzContext', 'Get-AzAccessToken', 'Update-AzConfig', 'Set-VmfAzDataCollectionOff') {
    Set-Item -Path "function:global:`$n" -Value ([scriptblock]::Create("`$global:ppCalls.Add(@{ c = '`$n'; a = '' })"))
}
function global:Write-Host { param([Parameter(Position = 0)]`$Object) `$global:ppInfo.Add([string]`$Object) }
`$failed = ''
try { & '$($script:profilePath)' } catch { `$failed = [string]`$_ }
@{ calls = @(`$global:ppCalls); info = @(`$global:ppInfo); failed = `$failed } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$out'
"@
        $file = Join-Path $script:temp ([guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $file -Value $harness
        $null = & pwsh -NoProfile -NonInteractive -File $file 2>&1
        $r = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        [pscustomobject]@{
            Calls  = @($r.calls | ForEach-Object { [pscustomobject]@{ Command = [string]$_.c; Arguments = [string]$_.a; Version = [string]$_.v } })
            Info   = @($r.info)
            Failed = [string]$r.failed
        }
    }
}
AfterAll {
    Remove-Item 'function:\InvokePpProfile' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'PERF-PROFILE-1: the module loads its files as one script block' {
    It 'the loader dot-sources ONE script block, not one per file' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:moduleDir 'VmMigrationFactory.psm1'), [ref]$null, [ref]$null)
        $dots = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))
        $dots.Count | Should -Be 1 -Because 'one dot-source is the one script block'
        $loop = $dots[0].Parent
        while ($loop -and $loop -isnot [System.Management.Automation.Language.LoopStatementAst]) { $loop = $loop.Parent }
        $loop | Should -BeNullOrEmpty -Because 'a dot-source in a loop is one script block for each file, which cost 1.6 s of 1.8 s'
    }

    It 'every function of every file is in the module after the import' {
        $want = foreach ($f in $script:moduleFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Parent.Parent -is [System.Management.Automation.Language.ScriptBlockAst] -and
                    $null -eq $n.Parent.Parent.Parent }, $true) | ForEach-Object Name
        }
        @($want).Count | Should -BeGreaterThan 300 -Because 'the walk must read the real files'
        $have = InModuleScope VmMigrationFactory { @(Get-ChildItem function: | ForEach-Object Name) }
        $missing = @($want | Where-Object { $_ -notin $have })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'only the Public functions are exported' {
        $public = @(Get-ChildItem (Join-Path $script:moduleDir 'Public') -Filter *.ps1 -Recurse | ForEach-Object BaseName | Sort-Object)
        $exported = @((Get-Module VmMigrationFactory).ExportedFunctions.Keys | Sort-Object)
        $exported | Should -Be $public
    }

    It 'the module-scope values each file sets are set' {
        InModuleScope VmMigrationFactory { $script:VmfPlanSchemaVersion } | Should -BeGreaterThan 0
        InModuleScope VmMigrationFactory { $script:VmfModuleRoot } | Should -Be $script:moduleDir
    }

    It 'no function asks $PSScriptRoot, $PSCommandPath or $MyInvocation for its file: in one script block it has none' {
        $hits = foreach ($f in $script:moduleFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.VariablePath.UserPath -in 'PSScriptRoot', 'PSCommandPath', 'MyInvocation' }, $true) |
                ForEach-Object { '{0}:{1} ${2}' -f $f.Name, $_.Extent.StartLineNumber, $_.VariablePath.UserPath }
        }
        @($hits) -join [Environment]::NewLine | Should -BeNullOrEmpty -Because 'build the path from $script:VmfModuleRoot'
    }

    It 'every path built from $script:VmfModuleRoot with fixed parts is there' {
        $paths = foreach ($f in $script:moduleFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }, $true)) {
                $parts = @($call.CommandElements | Select-Object -Skip 1)
                if ($parts.Count -lt 2) { continue }
                if ($parts[0] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $parts[0].VariablePath.UserPath -ne 'script:VmfModuleRoot') { continue }
                $rest = @($parts | Select-Object -Skip 1)
                if (@($rest | Where-Object { $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] }).Count) { continue }
                [pscustomobject]@{ Where = '{0}:{1}' -f $f.Name, $call.Extent.StartLineNumber; Parts = @($rest | ForEach-Object Value) }
            }
        }
        @($paths).Count | Should -BeGreaterOrEqual 12 -Because 'the ten data files, the worker and the guest folder are built this way'
        foreach ($p in $paths) {
            $full = [System.IO.Path]::GetFullPath((Join-Path $script:moduleDir ($p.Parts -join [System.IO.Path]::DirectorySeparatorChar)))
            Test-Path -LiteralPath $full | Should -BeTrue -Because "$($p.Where) builds $full"
        }
    }

    It 'the functions that read a data file find it' {
        InModuleScope VmMigrationFactory {
            $script:VmfTargetFamilies = $null
            $script:VmfStopReasons = $null
            Get-VmfTargetFamilyData | Should -Not -BeNullOrEmpty
            Get-VmfStopReasons | Should -Not -BeNullOrEmpty
            Test-Path (Join-Path $script:VmfModuleRoot 'Workers' 'worker.ps1') | Should -BeTrue
        }
        (Get-VmfVersion).PSObject.Properties.Name | Should -Contain 'version'
    }

    It 'a parse error names the file it is in, and its line in that file' {
        $copy = Join-Path $script:temp 'broken'
        Copy-Item -LiteralPath $script:moduleDir -Destination $copy -Recurse
        $bad = Join-Path $copy 'Private' 'zz-broken.ps1'
        Set-Content -LiteralPath $bad -Value @('# line 1', '# line 2', 'function Get-Broken { if ( }')
        $err = & pwsh -NoProfile -NonInteractive -Command "try { Import-Module '$(Join-Path $copy 'VmMigrationFactory.psd1')' -ErrorAction Stop; 'LOADED' } catch { [string]`$_ }"
        $text = ($err | Out-String)
        $text | Should -Not -Match 'LOADED'
        $text | Should -Match ([regex]::Escape('zz-broken.ps1'))
        $text | Should -Match 'line 3'
    }

    It 'an error while the files load names the file it is in' {
        $copy = Join-Path $script:temp 'throws'
        Copy-Item -LiteralPath $script:moduleDir -Destination $copy -Recurse
        Set-Content -LiteralPath (Join-Path $copy 'Public' 'zz-throws.ps1') -Value @('# line 1', "throw 'stop here'")
        $err = & pwsh -NoProfile -NonInteractive -Command "try { Import-Module '$(Join-Path $copy 'VmMigrationFactory.psd1')' -ErrorAction Stop; 'LOADED' } catch { [string]`$_ }"
        $text = ($err | Out-String)
        $text | Should -Not -Match 'LOADED'
        $text | Should -Match ([regex]::Escape('zz-throws.ps1') + ': line 2')
        $text | Should -Match 'stop here'
    }

    It 'a file with no last line break does not join the next file' {
        $copy = Join-Path $script:temp 'nolf'
        Copy-Item -LiteralPath $script:moduleDir -Destination $copy -Recurse
        # Private files load first, in name order inside each folder. A comment
        # with no line break at the end would swallow the next file's first line.
        [System.IO.File]::WriteAllText((Join-Path $copy 'Private' 'aaa-nolf.ps1'), '# a comment and no line break')
        [System.IO.File]::WriteAllText((Join-Path $copy 'Private' 'aab-next.ps1'), 'function Get-PpNext { 42 }')
        $r = & pwsh -NoProfile -NonInteractive -Command "Import-Module '$(Join-Path $copy 'VmMigrationFactory.psd1')'; & (Get-Module VmMigrationFactory) { Get-PpNext }"
        ($r | Select-Object -Last 1) | Should -Be '42'
    }
}

Describe 'PERF-PROFILE-1 and FACADE-SIGNIN-COLD-1: the start-up script' {
    It 'outside Azure it loads the two modules, signs in to nothing, and says where the tokens come from' {
        $r = InvokePpProfile
        $r.Failed | Should -BeNullOrEmpty
        $imports = @($r.Calls | Where-Object Command -EQ 'Import-Module' | ForEach-Object Arguments)
        $imports.Count | Should -Be 2
        $imports[0] | Should -BeLike '*Modules*VmMigrationFactory*VmMigrationFactory.psd1'
        $imports[1] | Should -BeLike '*Modules*FacadeCore*FacadeCore.psd1'
        @($r.Calls | Where-Object Command -NotIn 'Import-Module', 'Get-Module').Command | Should -BeNullOrEmpty
        $r.Info.Count | Should -Be 1
        $r.Info[0] | Should -Match '^VMF start-up: the modules loaded in \d+ ms\. Tokens: from the Az context of this computer \(no managed identity endpoint\)\.$'
    }

    It 'in the web service it loads the same two modules, makes no Az call, and says the tokens come from the managed identity endpoint' {
        $r = InvokePpProfile -InService
        $r.Failed | Should -BeNullOrEmpty
        @($r.Calls | Where-Object Command -EQ 'Import-Module').Count | Should -Be 2
        @($r.Calls | Where-Object { $_.Command -match '-Az' -or $_.Arguments -match '^Az\.' }) | Should -BeNullOrEmpty -Because 'no sign-in and no Az module: tokens come from the endpoint'
        $r.Info.Count | Should -Be 1
        $r.Info[0] | Should -Match '^VMF start-up: the modules loaded in \d+ ms\. Tokens: from the managed identity endpoint, with no sign-in\.$'
    }

    It 'asks the module, after it is loaded, which path the tokens take' {
        $r = InvokePpProfile -InService
        $names = @($r.Calls | ForEach-Object Command)
        [array]::LastIndexOf($names, 'Import-Module') | Should -BeLessThan ([array]::IndexOf($names, 'Get-Module'))
    }

    It 'a module that does not load stops the start-up script' {
        $r = InvokePpProfile -ImportFails
        $r.Failed | Should -Match 'could not load'
        $r.Info | Should -BeNullOrEmpty
    }

    It 'the profile has no Az call at all (PERF-PROFILE-1: never a second sign-in in a signed-in process, and now no first one)' {
        $code = Get-VmfCodeOnly -Path $script:profilePath
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
        $az = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-Az' } | Sort-Object -Unique)
        $az | Should -BeNullOrEmpty
    }
}

# PERF-SIGNIN-SUBS-1 named the install's subscription and tenant in the
# sign-in. FACADE-SIGNIN-COLD-1 removed the sign-in itself, so those tests and
# the VMF_TENANT_ID setting went with it (FacadeSigninCold.Tests.ps1 holds
# that the setting is gone).

# FACADE-PASS-SHARE-1 (review): Azure PowerShell's data collection off before
# the first Az call of each process that signs in. Each Az cmdlet call sends
# usage data from a thread-pool thread that waits for the send (MEASURED with
# every outside request held: 302 busy threads and a median store call of
# 1006 ms). The store client turns it off when it is made; the start-up of the
# engine turns it off before it signs in, so even the sign-in sends nothing.
# The web service makes no Az call (FACADE-SIGNIN-COLD-1). Read with the
# parser: a comment never counts.
Describe 'FACADE-PASS-SHARE-1: the data collection is off before the sign-in' {
    BeforeAll {
        # The offset of each command, by name, in a script's code.
        $script:CommandsIn = { param([string]$Path)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { [pscustomobject]@{ Name = [string]$_.GetCommandName(); At = $_.Extent.StartOffset; Text = $_.Extent.Text } } |
                Sort-Object At)
        }
    }

    It 'the web service''s start-up script loads no Az module, so it has no setting to turn off' {
        $cmds = & $script:CommandsIn $script:profilePath
        @($cmds | Where-Object { $_.Name -eq 'Import-Module' -and $_.Text -match '\bAz\.' }) | Should -BeNullOrEmpty
        @($cmds | Where-Object Name -EQ 'Set-VmfAzDataCollectionOff') | Should -BeNullOrEmpty -Because 'with no Az module it would only say notLoaded'
    }

    It 'the engine''s start-up script turns it off after it loads Az.Accounts and the module, before it signs in' {
        $entry = Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'
        $cmds = & $script:CommandsIn $entry
        $off = @($cmds | Where-Object Name -EQ 'Set-VmfAzDataCollectionOff')
        $off.Count | Should -Be 1
        $az = @($cmds | Where-Object { $_.Name -eq 'Import-Module' -and $_.Text -match '\bAz\.Accounts\b' })
        $az.Count | Should -Be 1 -Because 'Connect-AzAccount would load it only at the sign-in, and the setting needs it loaded'
        $vmf = @($cmds | Where-Object { $_.Name -eq 'Import-Module' -and $_.Text -match 'VmMigrationFactory' })
        $off[0].At | Should -BeGreaterThan $az[0].At
        $off[0].At | Should -BeGreaterThan $vmf[0].At
        $connect = @($cmds | Where-Object { $_.Name -match '-Az' -and $_.Name -notin 'Set-VmfAzDataCollectionOff' })
        $connect.Count | Should -BeGreaterThan 0
        $off[0].At | Should -BeLessThan $connect[0].At -Because 'the sign-in is the engine''s first Az call'
    }

    It 'a failure of the setting never stops the engine''s start-up' {
        $file = Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $call = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-VmfAzDataCollectionOff' }, $true)
        $call | Should -Not -BeNullOrEmpty
        $node = $call.Parent; $inTry = $false
        while ($node) { if ($node -is [System.Management.Automation.Language.TryStatementAst] -and $node.CatchClauses.Count -gt 0) { $inTry = $true; break }; $node = $node.Parent }
        $inTry | Should -BeTrue -Because "$file must sign in even when the setting is refused"
    }
}