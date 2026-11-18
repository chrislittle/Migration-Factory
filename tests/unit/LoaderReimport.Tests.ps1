#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LOADER-REIMPORT-1: a second import of the module in the same process must
# reuse the work of the first.
#
# PERF-PROFILE-1 (#713) made the module load its files as ONE script block,
# parsed with Parser.ParseInput. A fresh process got faster. A second
# `Import-Module -Force` in the SAME process got slower: MEASURED on a CI
# runner, 2026-11-03, the old loader 194-258 ms and the new one 528-737 ms.
# The old loader dot-sourced each file, and PowerShell keeps a parsed file in a
# process-wide cache keyed on (path, text) - ExternalScriptInfo.cs, lines 280
# and 318 at v7.4.6. ParseInput does not use that cache.
#
# [scriptblock]::Create(text) DOES use it: ScriptBlock.Create(parser, null,
# text) asks TryGetCachedScriptBlock(null, text) first (CompiledScriptBlock.cs,
# lines 583-670 at v7.4.6, the same on master). So the key is the exact joined
# text - an edited file is a new key - and the cache gives back a Clone() that
# has no session state, so a runspace gets its own functions and its own
# module scope. That is the mechanism the old loader used in every runspace of
# the service; this file holds the loader to it.
#
# Every test runs in a new pwsh: an Import-Module -Force in this process would
# drop the Azure guard's mocks (TEST-AZURE-GUARD-2).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:moduleDir = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:psd1 = Join-Path $script:moduleDir 'VmMigrationFactory.psd1'
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'loaderreimport'

    # Run a script in a new pwsh. The script writes ONE JSON object as its
    # last line of output; this returns it.
    function Global:InvokeLrChild {
        param([Parameter(Mandatory)][string]$Script)
        $file = Join-Path $script:temp ([guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $file -Value ("`$ErrorActionPreference = 'Stop'" + [Environment]::NewLine + $Script)
        $out = @(& pwsh -NoProfile -NonInteractive -File $file 2>&1 | ForEach-Object { [string]$_ })
        $last = $out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
        if (-not $last) { throw ('The child pwsh wrote no JSON: ' + ($out -join [Environment]::NewLine)) }
        $last | ConvertFrom-Json
    }

    # A copy of the module that a test may edit.
    function Global:NewLrModuleCopy {
        param([Parameter(Mandatory)][string]$Name)
        $copy = Join-Path $script:temp $Name
        Copy-Item -LiteralPath $script:moduleDir -Destination $copy -Recurse
        $copy
    }
}
AfterAll {
    Remove-Item 'function:\InvokeLrChild', 'function:\NewLrModuleCopy' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'LOADER-REIMPORT-1: a second import in the same process' {
    It 'gives the same exported functions, and every function works' {
        $r = InvokeLrChild @"
Import-Module '$($script:psd1)' -Force
`$a = @((Get-Module VmMigrationFactory).ExportedFunctions.Keys | Sort-Object)
`$ia = @(& (Get-Module VmMigrationFactory) { Get-ChildItem function: | ForEach-Object Name } | Sort-Object)
Import-Module '$($script:psd1)' -Force
`$b = @((Get-Module VmMigrationFactory).ExportedFunctions.Keys | Sort-Object)
`$ib = @(& (Get-Module VmMigrationFactory) { Get-ChildItem function: | ForEach-Object Name } | Sort-Object)
@{ exportsA = `$a.Count; same = ((`$a -join ',') -eq (`$b -join ',')); inner = ((`$ia -join ',') -eq (`$ib -join ','))
   version = [string](Get-VmfVersion).version
   schema = [int](& (Get-Module VmMigrationFactory) { `$script:VmfPlanSchemaVersion })
   root = [string](& (Get-Module VmMigrationFactory) { `$script:VmfModuleRoot }) } | ConvertTo-Json -Compress
"@
        $r.exportsA | Should -BeGreaterThan 30
        $r.same | Should -BeTrue
        $r.inner | Should -BeTrue -Because 'the private functions must all be there after the second import too'
        $r.version | Should -Not -BeNullOrEmpty
        $r.schema | Should -BeGreaterThan 0
        $r.root | Should -Be $script:moduleDir
    }

    It 'reuses the parse of the first import when no file changed' {
        # A function's Ast is the parse it came from. The same Ast object after
        # the second import proves the second import did not parse again.
        $r = InvokeLrChild @"
Import-Module '$($script:psd1)' -Force
`$a = (Get-Command Get-VmfVersion).ScriptBlock.Ast
`$pa = & (Get-Module VmMigrationFactory) { (Get-Command Get-VmfTargetFamilyData).ScriptBlock.Ast }
Import-Module '$($script:psd1)' -Force
`$b = (Get-Command Get-VmfVersion).ScriptBlock.Ast
`$pb = & (Get-Module VmMigrationFactory) { (Get-Command Get-VmfTargetFamilyData).ScriptBlock.Ast }
@{ public = [object]::ReferenceEquals(`$a, `$b); private = [object]::ReferenceEquals(`$pa, `$pb); notNull = (`$null -ne `$a) } | ConvertTo-Json -Compress
"@
        $r.notNull | Should -BeTrue
        $r.public | Should -BeTrue -Because 'a second import of the same text must not parse it again'
        $r.private | Should -BeTrue
    }

    It 'loads an edited file again: a change of the same length is not served from the first parse' {
        $copy = NewLrModuleCopy -Name 'edit'
        $file = Join-Path $copy 'Private' 'zz-lr-edit.ps1'
        [System.IO.File]::WriteAllText($file, "function Get-LrEdit { 'one' }`n")
        $r = InvokeLrChild @"
`$psd1 = '$(Join-Path $copy 'VmMigrationFactory.psd1')'
Import-Module `$psd1 -Force
`$first = & (Get-Module VmMigrationFactory) { Get-LrEdit }
`$a = (Get-Command Get-VmfVersion).ScriptBlock.Ast
[System.IO.File]::WriteAllText('$file', "function Get-LrEdit { 'two' }``n")
Import-Module `$psd1 -Force
`$second = & (Get-Module VmMigrationFactory) { Get-LrEdit }
`$b = (Get-Command Get-VmfVersion).ScriptBlock.Ast
@{ first = [string]`$first; second = [string]`$second; sameAst = [object]::ReferenceEquals(`$a, `$b) } | ConvertTo-Json -Compress
"@
        $r.first | Should -Be 'one'
        $r.second | Should -Be 'two' -Because 'an edited file must never come from the first parse'
        $r.sameAst | Should -BeFalse -Because 'new text is a new parse'
    }

    It 'a parse error in the second import names the file it is in, and its line in that file' {
        $copy = NewLrModuleCopy -Name 'breaklater'
        $bad = Join-Path $copy 'Private' 'zz-lr-break.ps1'
        [System.IO.File]::WriteAllText($bad, "# line 1`nfunction Get-LrBreak { 1 }`n")
        $r = InvokeLrChild @"
`$psd1 = '$(Join-Path $copy 'VmMigrationFactory.psd1')'
Import-Module `$psd1 -Force
[System.IO.File]::WriteAllText('$bad', "# line 1``n# line 2``nfunction Get-LrBreak { if ( }``n")
`$err = ''
try { Import-Module `$psd1 -Force -ErrorAction Stop } catch { `$err = [string]`$_ }
@{ err = `$err } | ConvertTo-Json -Compress
"@
        $r.err | Should -Match ([regex]::Escape('zz-lr-break.ps1') + ': line 3')
    }

    It 'a parse error in the first import names the file and its line, with the parser message' {
        $copy = NewLrModuleCopy -Name 'breakfirst'
        [System.IO.File]::WriteAllText((Join-Path $copy 'Public' 'zz-lr-bad.ps1'), "# line 1`nfunction Get-LrBad { `$x = @( }`n")
        $r = InvokeLrChild @"
`$err = ''
try { Import-Module '$(Join-Path $copy 'VmMigrationFactory.psd1')' -ErrorAction Stop } catch { `$err = [string]`$_ }
@{ err = `$err } | ConvertTo-Json -Compress
"@
        $r.err | Should -Match ([regex]::Escape('zz-lr-bad.ps1') + ': line 2')
        $r.err | Should -Match '^Failed to load '
        $r.err | Should -Not -Match 'Exception calling' -Because 'the operator sees the parser message, not the .NET wrapper'
    }
}

Describe 'LOADER-REIMPORT-1: runspaces share no module state' {
    It 'two runspaces that import the module at the same time each get their own functions and module scope' {
        $r = InvokeLrChild @"
Import-Module '$($script:psd1)' -Force
`$jobs = foreach (`$name in 'one', 'two') {
    `$rs = [runspacefactory]::CreateRunspace(); `$rs.Open()
    `$ps = [powershell]::Create(); `$ps.Runspace = `$rs
    [void]`$ps.AddScript({
        param(`$Psd1, `$Name)
        `$ErrorActionPreference = 'Stop'
        Import-Module `$Psd1 -Force
        & (Get-Module VmMigrationFactory) { param(`$n) `$script:LrMark = `$n } `$Name
        Start-Sleep -Milliseconds 300
        @{ mark = (& (Get-Module VmMigrationFactory) { `$script:LrMark }); version = [string](Get-VmfVersion).version
           families = (& (Get-Module VmMigrationFactory) { @(Get-VmfTargetFamilyData).Count -gt 0 })
           ast = (Get-Command Get-VmfVersion).ScriptBlock.Ast
           module = (Get-Module VmMigrationFactory) }
    }).AddArgument('$($script:psd1)').AddArgument(`$name)
    [pscustomobject]@{ Name = `$name; Ps = `$ps; Rs = `$rs; Handle = `$ps.BeginInvoke() }
}
`$res = foreach (`$j in `$jobs) { `$o = @(); `$err = @(); try { `$o = `$j.Ps.EndInvoke(`$j.Handle) } catch { `$err += [string]`$_.Exception.InnerException }; `$err += @(`$j.Ps.Streams.Error | ForEach-Object { [string]`$_ }); `$j.Ps.Dispose(); `$j.Rs.Dispose(); [pscustomobject]@{ Name = `$j.Name; Out = `$o[0]; Err = `$err } }
`$here = & (Get-Module VmMigrationFactory) { `$script:LrMark }
@{ one = [string]`$res[0].Out.mark; two = [string]`$res[1].Out.mark; here = [string]`$here
   v1 = `$res[0].Out.version; v2 = `$res[1].Out.version; f1 = `$res[0].Out.families; f2 = `$res[1].Out.families
   errors = @(`$res | ForEach-Object Err) -join ' | '
   sameModule = [object]::ReferenceEquals(`$res[0].Out.module, `$res[1].Out.module)
   sameAst = [object]::ReferenceEquals(`$res[0].Out.ast, `$res[1].Out.ast) } | ConvertTo-Json -Compress
"@
        $r.errors | Should -BeNullOrEmpty
        $r.one | Should -Be 'one'
        $r.two | Should -Be 'two' -Because 'a value one runspace sets in the module scope must not reach the other'
        $r.here | Should -BeNullOrEmpty -Because 'the first runspace sets nothing'
        $r.v1 | Should -Not -BeNullOrEmpty
        $r.v2 | Should -Not -BeNullOrEmpty
        $r.f1 | Should -BeTrue
        $r.f2 | Should -BeTrue
        $r.sameModule | Should -BeFalse
    }
}
