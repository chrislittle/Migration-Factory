#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RESTORE-POWER-READ-1: a job that reads the power state at its start asked
# Azure for a machine named after the operation.
#
# Get-VmfJobStartPower kept the machine name in $name and read it inside the
# -Operation block of Invoke-VmfAzOperation. That block runs in a child scope
# of Invoke-VmfAzOperation, so $name there is Invoke-VmfAzOperation's own -Name
# ("restore:powerAtStart"). The final lab: Azure answered "not found", and the
# restore left a deallocated machine running. Every test mocked
# Get-VmfPowerState without looking at -Name, so nothing caught it.
#
# The class: a script block passed to a function of the module runs in that
# function's scope, so it reads the function's parameters and variables, not
# the caller's, when the names are the same. The guard below reads every such
# block with the PowerShell parser (comments are not code to it).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:LangNs = 'System.Management.Automation.Language'

    function script:Get-RprAst {
        param([string]$Path, [string]$Text)
        $tokens = $null; $errors = $null
        if ($Path) { return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) }
        [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    }

    function script:Test-RprInsideNestedBlock {
        # True when $Node sits inside a script block expression below $Top.
        param($Node, $Top)
        $up = $Node.Parent
        while ($up -and $up -ne $Top) {
            if ($up -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
            $up = $up.Parent
        }
        $false
    }

    function script:Get-RprSetNames {
        # Every variable name $Node sets: an assignment ($x =, [int]$x =,
        # $a, $b =), a foreach variable, and a -OutVariable, -ErrorVariable,
        # -WarningVariable, -InformationVariable or -PipelineVariable target
        # (and their short names). -TopOnly: not inside a nested script block,
        # which runs in a scope of its own.
        param($Node, [switch]$TopOnly)
        $fromLeft = {
            param($left)
            if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { if ($left.VariablePath.IsUnqualified) { $left.VariablePath.UserPath } }
            elseif ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { & $fromLeft $left.Child }
            elseif ($left -is [System.Management.Automation.Language.ArrayLiteralAst]) { foreach ($el in $left.Elements) { & $fromLeft $el } }
        }
        $varParams = @('OutVariable', 'ov', 'ErrorVariable', 'ev', 'WarningVariable', 'wv', 'InformationVariable', 'iv', 'PipelineVariable', 'pv')
        $names = foreach ($n in $Node.FindAll({ param($a)
                    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                    $a -is [System.Management.Automation.Language.ForEachStatementAst] -or
                    $a -is [System.Management.Automation.Language.CommandParameterAst] }, $true)) {
            if ($TopOnly -and (Test-RprInsideNestedBlock -Node $n -Top $Node)) { continue }
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) { & $fromLeft $n.Left }
            elseif ($n -is [System.Management.Automation.Language.ForEachStatementAst]) { $n.Variable.VariablePath.UserPath }
            elseif ($varParams -contains $n.ParameterName) {
                $arg = if ($n.Argument) { $n.Argument } else {
                    $els = $n.Parent.CommandElements; $at = $els.IndexOf($n); if ($at -ge 0 -and $at + 1 -lt $els.Count) { $els[$at + 1] } }
                if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { ([string]$arg.Value) -replace '^\+', '' }
            }
        }
        @($names | Where-Object { $_ -and $_ -notin @('null', 'true', 'false') })
    }

    function script:Get-RprBlockTargets {
        # Every function in the module that takes a [scriptblock] parameter:
        # its script block parameters, every parameter name, and every
        # variable its body assigns outside a nested script block (those are
        # in its scope when it runs the block).
        param([object[]]$Asts)
        $found = @{}
        foreach ($ast in $Asts) {
            foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $pb = $fn.Body.ParamBlock
                if (-not $pb) { continue }
                $blockParams = @($pb.Parameters | Where-Object { $_.StaticType -eq [scriptblock] } | ForEach-Object { $_.Name.VariablePath.UserPath })
                if (-not $blockParams) { continue }
                $paramNames = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $assigned = @(Get-RprSetNames -Node $fn.Body -TopOnly)
                $found[$fn.Name] = [pscustomobject]@{
                    BlockParams = $blockParams
                    ParamNames  = $paramNames
                    # A parameter the function itself assigns again is a local too.
                    Locals      = @($assigned | Sort-Object -Unique)
                }
            }
        }
        $found
    }

    function script:Get-RprShadowHits {
        # Each read, inside a script block passed to one of $Targets, of a
        # variable that the called function holds itself. Not a hit: a name
        # the block assigns or takes as a parameter itself; a scope-qualified
        # name ($script:x); and a parameter the call passes as the SAME
        # variable (-VmId $VmId) that the function never assigns again - both
        # names then hold one value.
        param($Ast, [hashtable]$Targets, [string]$Label)
        $calls = @($Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $Targets.ContainsKey([string]$a.GetCommandName()) }, $true))
        foreach ($call in $calls) {
            $target = $Targets[[string]$call.GetCommandName()]
            $els = $call.CommandElements
            $boundBlocks = [System.Collections.Generic.List[object]]::new()
            $samePassed = @()
            for ($i = 1; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $arg = if ($el.Argument) { $el.Argument } elseif ($i + 1 -lt $els.Count -and $els[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $els[$i + 1] } else { $null }
                $full = @($target.ParamNames | Where-Object { $_.StartsWith($el.ParameterName, [System.StringComparison]::OrdinalIgnoreCase) })
                if ($full.Count -eq 1 -and $arg -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $arg.VariablePath.IsUnqualified -and $arg.VariablePath.UserPath -eq $full[0]) { $samePassed += $full[0] }
                if (-not ($target.BlockParams | Where-Object { $_.StartsWith($el.ParameterName, [System.StringComparison]::OrdinalIgnoreCase) })) { continue }
                if ($arg -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $boundBlocks.Add($arg) }
                elseif ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    # -Operation $marked: read each block the file assigns to that name.
                    $varName = $arg.VariablePath.UserPath
                    foreach ($asg in $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                                $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.Left.VariablePath.UserPath -eq $varName }, $true)) {
                        foreach ($sbe in $asg.Right.FindAll({ param($a) $a -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true) | Select-Object -First 1) { $boundBlocks.Add($sbe) }
                    }
                }
                else {
                    [pscustomobject]@{ Where = "${Label}:$($el.Extent.StartLineNumber)"; Variable = '(not readable)'; Text = "-$($el.ParameterName) takes no script block the guard can read: pass a script block, or a variable that holds one" }
                }
            }
            # A script block passed by position (Get-VmfCallTimingSafe { ... })
            # goes to a script block parameter: it is read too.
            for ($i = 1; $i -lt $els.Count; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and -not $boundBlocks.Contains($els[$i]) -and
                    -not ($els[$i - 1] -is [System.Management.Automation.Language.CommandParameterAst] -and -not $els[$i - 1].Argument)) {
                    $boundBlocks.Add($els[$i])
                }
            }
            $held = @($target.Locals) + @($target.ParamNames | Where-Object { $samePassed -notcontains $_ -or $target.Locals -contains $_ })
            foreach ($blockExpr in $boundBlocks) {
                $sb = $blockExpr.ScriptBlock
                $own = @(Get-RprSetNames -Node $sb)
                $own += @($sb.FindAll({ param($a) $a -is [System.Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.VariablePath.UserPath })
                foreach ($v in $sb.FindAll({ param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    $path = $v.VariablePath
                    $nm = [string]$path.UserPath
                    if ($nm -like 'local:*') { $nm = $nm.Substring(6) }
                    elseif (-not $path.IsUnqualified) { continue }
                    if ($held -contains $nm -and $own -notcontains $nm) {
                        [pscustomobject]@{ Where = "${Label}:$($v.Extent.StartLineNumber)"; Variable = $nm; Text = $v.Parent.Extent.Text.Split("`n")[0].Trim() }
                    }
                }
            }
        }
    }

    $script:allFiles = @(Get-ChildItem -Path $script:repoRoot -Recurse -File -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' })
    $script:asts = @{}
    foreach ($f in $script:allFiles) { $script:asts[$f.FullName] = Get-RprAst -Path $f.FullName }
    $moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:targets = Get-RprBlockTargets -Asts @($script:asts.Keys | Where-Object { $_.StartsWith($moduleRoot) } | ForEach-Object { $script:asts[$_] })
}

Describe 'RESTORE-POWER-READ-1: the power read at the start of a job asks Azure for the machine' {
    BeforeEach {
        $global:rprAsked = [System.Collections.Generic.List[object]]::new()
        $global:rprPower = 'PowerState/deallocated'
        # A run path outside the repository (LITTER-1).
        $script:rprRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rpr-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:rprRun -Force | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState {
            $global:rprAsked.Add([pscustomobject]@{ Rg = $ResourceGroupName; Name = $Name })
            if ($Name -ne 'vm-r1') { throw "The Resource 'Microsoft.Compute/virtualMachines/$Name' under resource group '$ResourceGroupName' was not found." }
            $global:rprPower
        }
    }
    AfterEach {
        if ($script:rprRun -and (Test-Path $script:rprRun)) { Remove-Item $script:rprRun -Recurse -Force }
        Remove-Variable rprAsked, rprPower -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a <Power> machine: Azure is asked for the machine by its name and group, and the power state comes back as found' -ForEach @(
        @{ Power = 'PowerState/deallocated' }
        @{ Power = 'PowerState/stopped' }
        @{ Power = 'PowerState/running' }) {
        $global:rprPower = $Power
        $vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-r1/providers/Microsoft.Compute/virtualMachines/vm-r1'
        $got = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rprRun; id = $vmId } {
            param($rp, $id)
            Get-VmfJobStartPower -RunPath $rp -VmId $id -Step 'restore' -JobWords 'the restore'
        }
        $global:rprAsked.Count | Should -Be 1
        $global:rprAsked[0].Name | Should -Be 'vm-r1' -Because 'the read names the machine, never the operation (restore:powerAtStart)'
        $global:rprAsked[0].Rg | Should -Be 'rg-r1'
        $got | Should -Be $Power
    }
}

Describe 'RESTORE-POWER-READ-1: an empty LUN gets the disk by its own name' {
    # The same trap, found by the guard: the attach of a disk to an empty LUN
    # read $name inside its -Operation block, so the disk was named after the
    # operation (restore:swapDataDisks).
    BeforeEach {
        $global:rprAttach = [System.Collections.Generic.List[string]]::new()
        $script:rprRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rpr-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $src = if ($DiskId -eq '/d/want') { '/s/copy-d0' } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = $src }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:rprAttach.Add("${DiskId}=${DiskName}")
            if ($DiskId -eq '/d/want') { return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk cannot be attached' } }
            @{ Applied = $true }
        }
    }
    AfterEach {
        if ($script:rprRun -and (Test-Path $script:rprRun)) { Remove-Item $script:rprRun -Recurse -Force }
        Remove-Variable rprAttach -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the disk made from its copy, and the disk the LUN had when that is refused, each go on with its own name' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rprRun } {
            param($rp)
            Invoke-VmfEmptyLunAttach -Context ([pscustomobject]@{ RunPath = $rp; VmId = '/vm1'; Rg = 'rg' }) -VmName 'vm1' -OpName 'restore:swapDataDisks' -ReadOpName 'restore:readDataDisk' `
                -Lun 0 -Want @{ id = '/d/want'; name = 'd0-restored'; snapshotId = '/s/copy-d0' } -Fallback @{ id = '/d/old'; name = 'd0' } -Settings ([pscustomobject]@{ Caching = 'None' })
        }
        $r.Outcome | Should -Be 'fallback'
        @($global:rprAttach | Select-Object -Unique) | Should -Be @('/d/want=d0-restored', '/d/old=d0')
    }
}

Describe 'RESTORE-POWER-READ-1: no script block reads a variable of the function that runs it' {
    It 'the guard reads the module: Invoke-VmfAzOperation is a target, with its parameters and its own variables' {
        $op = $script:targets['Invoke-VmfAzOperation']
        $op | Should -Not -BeNullOrEmpty
        $op.BlockParams | Should -Be @('Operation')
        foreach ($n in 'Operation', 'Name', 'RunPath', 'VmId', 'MaxAttempts', 'BaseDelayMs', 'EventData') { $op.ParamNames | Should -Contain $n }
        foreach ($n in 'attempt', 'result', 'err', 'msg') { $op.Locals | Should -Contain $n }
        # $withEventData's own variables run in a scope of their own, not in the
        # scope the -Operation block runs in.
        foreach ($n in 'all', 'k') { $op.Locals | Should -Not -Contain $n }
        $op.Locals | Should -Not -Contain 'null' -Because '$null = ... is not a variable'
        $calls = 0
        foreach ($a in $script:asts.Values) { $calls += @($a.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Invoke-VmfAzOperation' }, $true)).Count }
        $calls | Should -BeGreaterThan 100 -Because 'the guard must read the real calls, not an empty set'
    }

    It 'the guard finds the line the lab found (Get-VmfJobStartPower before the fix)' {
        $old = @'
function Get-OldPower {
    param($RunPath, $VmId, $Step)
    $rg = ($VmId -split '/')[4]
    $name = ($VmId -split '/')[-1]
    $power = [string](Invoke-VmfAzOperation -Name "${Step}:powerAtStart" -RunPath $RunPath -VmId $VmId -Operation {
            Get-VmfPowerState -ResourceGroupName $rg -Name $name
        })
}
'@
        $hits = @(Get-RprShadowHits -Ast (Get-RprAst -Text $old) -Targets $script:targets -Label 'old')
        $hits.Count | Should -Be 1
        $hits[0].Variable | Should -Be 'name'
        $hits[0].Text | Should -Match 'Get-VmfPowerState'
    }

    It 'the guard finds <Case>' -ForEach @(
        @{ Case = 'a parameter passed with another value'; Code = 'Invoke-VmfAzOperation -Name x -VmId $other -Operation { Get-Thing -Id $VmId }'; Var = 'VmId' }
        @{ Case = 'a variable the function assigns ($result)'; Code = 'Invoke-VmfAzOperation -Name x -Operation { Get-Thing -Id $result }'; Var = 'result' }
        @{ Case = 'a short parameter name (-Op)'; Code = 'Invoke-VmfAzOperation -Name x -Op { Get-Thing -Id $name }'; Var = 'name' }
        @{ Case = 'a local: name'; Code = 'Invoke-VmfAzOperation -Name x -Operation { Get-Thing -Id $local:name }'; Var = 'name' }
        @{ Case = 'a block in a variable'; Code = '$op = { Get-Thing -Id $name }; Invoke-VmfAzOperation -Name x -Operation $op'; Var = 'name' }
        @{ Case = 'a read inside a nested block'; Code = 'Invoke-VmfAzOperation -Name x -Operation { 1 | ForEach-Object { Get-Thing -Id $RunPath } }'; Var = 'RunPath' }
        @{ Case = 'a block passed by position'; Code = 'Invoke-VmfAzOperation { Get-Thing -Id $name } -Name x'; Var = 'name' }
        @{ Case = 'another function that takes a script block (New-VmfOsDiskFromCopy -OnMade)'; Code = 'New-VmfOsDiskFromCopy -Context $c -OpName o -OnMade { param($id) Write-Thing $DiskName }'; Var = 'DiskName' }
        @{ Case = 'a foreach variable of Add-VmfStateTransition ($name)'; Code = 'Add-VmfStateTransition -RunPath r -VmId v -NewState s -Amend { param($d) $d.x = $name }'; Var = 'name' }
        @{ Case = 'a foreach variable of Get-VmfBurstableSizeChoice ($f)'; Code = 'Get-VmfBurstableSizeChoice -Passes { param($s) $f }'; Var = 'f' }
        @{ Case = 'a foreach variable of Invoke-VmfDataDiskRestore ($r)'; Code = 'Invoke-VmfDataDiskRestore -Context $c -OnMade { param($id) $r }'; Var = 'r' }) {
        $hits = @(Get-RprShadowHits -Ast (Get-RprAst -Text $Code) -Targets $script:targets -Label 'case')
        @($hits.Variable) | Should -Contain $Var
    }

    It 'a function holds each name it sets: <Case>' -ForEach @(
        @{ Case = 'a foreach variable'; Var = 'loopVar' }
        @{ Case = 'a typed assignment ([int]$x =)'; Var = 'typed' }
        @{ Case = 'two names in one assignment ($a, $b =)'; Var = 'pairB' }
        @{ Case = '-OutVariable'; Var = 'outLong' }
        @{ Case = '-ov with a plus (append)'; Var = 'outShort' }
        @{ Case = '-ErrorVariable:name'; Var = 'errV' }
        @{ Case = '-PipelineVariable'; Var = 'pipeV' }) {
        $fake = @(
            'function Invoke-RprFake {'
            '    param([scriptblock]$Op)'
            '    foreach ($loopVar in 1) { }'
            '    [int]$typed = 1'
            '    $pairA, $pairB = 1, 2'
            '    Get-Thing -OutVariable outLong'
            '    Get-Thing -ov +outShort'
            '    Get-Thing -ErrorVariable:errV'
            '    Get-Thing -PipelineVariable pipeV | Out-Null'
            '    & $Op'
            '    $nested = { foreach ($innerOnly in 1) { } }'
            '}') -join "`n"
        $fakeTargets = Get-RprBlockTargets -Asts @(Get-RprAst -Text $fake)
        $fakeTargets['Invoke-RprFake'].Locals | Should -Contain $Var
        $fakeTargets['Invoke-RprFake'].Locals | Should -Not -Contain 'innerOnly' -Because 'a nested script block runs in a scope of its own'
        $hits = @(Get-RprShadowHits -Ast (Get-RprAst -Text ('Invoke-RprFake -Op { Write-Thing $' + $Var + ' }')) -Targets $fakeTargets -Label 'fake')
        @($hits.Variable) | Should -Contain $Var
    }

    It 'the guard leaves alone a name the block sets itself with <Case>' -ForEach @(
        @{ Case = 'a typed assignment'; Code = 'Invoke-VmfAzOperation -Name x -Operation { [string]$name = "a"; Get-Thing -Id $name }' }
        @{ Case = 'a foreach'; Code = 'Invoke-VmfAzOperation -Name x -Operation { foreach ($name in 1) { Get-Thing -Id $name } }' }
        @{ Case = '-OutVariable'; Code = 'Invoke-VmfAzOperation -Name x -Operation { Get-Thing -OutVariable name | Out-Null; $name }' }) {
        @(Get-RprShadowHits -Ast (Get-RprAst -Text $Code) -Targets $script:targets -Label 'case') | Should -BeNullOrEmpty
    }

    It 'the guard leaves alone <Case>' -ForEach @(
        @{ Case = 'a variable the block assigns itself'; Code = 'Invoke-VmfAzOperation -Name x -Operation { $name = "a"; Get-Thing -Id $name }' }
        @{ Case = 'a name the block takes as a parameter'; Code = 'Invoke-VmfAzOperation -Name x -Operation { param($name) Get-Thing -Id $name }' }
        @{ Case = 'a script: name'; Code = 'Invoke-VmfAzOperation -Name x -Operation { Get-Thing -Id $script:name }' }
        @{ Case = 'a parameter passed as the same variable'; Code = 'Invoke-VmfAzOperation -Name x -VmId $VmId -Operation { Get-Thing -Id $VmId }' }
        @{ Case = 'a name only the caller holds'; Code = 'Invoke-VmfAzOperation -Name x -Operation { Get-Thing -Id $vmName }' }
        @{ Case = 'a name in a comment'; Code = "Invoke-VmfAzOperation -Name x -Operation {`n  # not `$name`n  Get-Thing -Id `$vmName }" }) {
        @(Get-RprShadowHits -Ast (Get-RprAst -Text $Code) -Targets $script:targets -Label 'case') | Should -BeNullOrEmpty
    }

    It 'no script block in the repository reads a variable of the function that runs it' {
        $hits = foreach ($k in $script:asts.Keys) {
            Get-RprShadowHits -Ast $script:asts[$k] -Targets $script:targets -Label $k.Substring($script:repoRoot.Length + 1)
        }
        @($hits | ForEach-Object { "$($_.Where) `$$($_.Variable): $($_.Text)" }) | Should -BeNullOrEmpty -Because 'inside a script block that a function runs, a name the function holds is the function''s, not the caller''s (name it $vmName, not $name)'
    }
}
