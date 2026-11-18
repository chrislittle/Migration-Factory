#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISCARD-ENGINE-1 (GitHub issue 427): the service may only call Az commands
# from the modules it loads.
#
# "Delete this migration" with "Delete the copies as well" failed in the
# service with "The term 'Remove-AzResourceLock' is not recognized". The
# service (src/facade) loads ONE Azure module - Az.Accounts, named in
# src/facade/app/requirements.psd1 - and called the engine module's
# Remove-VmfRun in process, which reached Remove-AzResourceLock (Az.Resources).
# Every unit test passed, because each mocks the Azure call inside the module,
# so a host where the command does not exist was never exercised.
#
# This walks the code instead: every command the service's files call, then
# every module function those reach, and so on. Any Az command reached that is
# not in a module the service loads is a failure the first time it runs.
#
# FACADE-SIGNIN-COLD-1 and PERF-AZ-LOAD-1: THE SERVICE NOW LOADS NO AZ MODULE.
# It takes its tokens from the managed identity endpoint, so there is no
# requirements.psd1 and every Az command it reaches is a failure - except a
# call in the ELSE of `if (Test-VmfTokenFromIdentityEndpoint)` (or the facade
# module's Test-VmfFacadeTokenFromIdentityEndpoint), with no elseif and no
# argument: that test is true in the web service (FacadeSigninCold.Tests.ps1),
# so the else is the engine's and a developer computer's path, never the
# service's. That is the SERVICE SWITCH below, held to code written to defeat
# it like the gates.
#
# A CALL THAT CANNOT REACH AZURE IS NOT A REACH. Two module functions reach a
# delete only behind a switch the service must never pass (or must always
# pass). Those are the GATES below; each is checked twice - every call site on
# the service's reach honours it, BY ITS VALUE, and inside the function every
# call that reaches Azure really is behind it, in a form that can only mean
# "only when the switch is on". A gate is never a way to excuse a call.
#
# The helpers take everything they need as arguments, so the last Describe
# can hold each of them to code written to defeat it.
#
# A call the parser cannot name - `& $command`, a name built from a string, a
# command held in a variable - is NOT seen by this walk; a review must catch it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:facadeRoot = Join-Path $script:repoRoot 'src' 'facade'
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'

    # The commands each module the service may load makes available, written
    # here because CI has no Az module installed. FACADE-SIGNIN-COLD-1: the
    # service loads none, so the list is empty; a module named again in a
    # requirements.psd1 needs its commands here (a test says so).
    $script:moduleCommands = @{}

    # No requirements.psd1 is no module.
    $requirementsPath = Join-Path $script:facadeRoot 'app' 'requirements.psd1'
    $script:requirements = if (Test-Path -LiteralPath $requirementsPath) { Import-PowerShellDataFile $requirementsPath } else { @{} }
    $script:loaded = @($script:requirements.Keys)
    # The service switch: true in the web service, so a call in its else
    # never runs there.
    $script:serviceSwitches = @('Test-VmfTokenFromIdentityEndpoint', 'Test-VmfFacadeTokenFromIdentityEndpoint')
    $script:allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $script:loaded) { foreach ($c in @($script:moduleCommands[$m])) { if ($c) { [void]$script:allowed.Add($c) } } }

    # ---- the helpers ----------------------------------------------------------

    function Global:FamIsAz([string]$Name) { $Name -match '^[A-Za-z]+-Az[A-Z]\w*$' }

    function Global:FamCalls($Ast) {
        @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
    }

    # Is this condition the service switch alone: one command of that name,
    # with no argument, and nothing else in the pipeline?
    function Global:FamIsSwitch($Condition, [string[]]$Switches) {
        if ($Condition -isnot [System.Management.Automation.Language.PipelineAst] -or $Condition.PipelineElements.Count -ne 1) { return $false }
        $c = $Condition.PipelineElements[0]
        ($c -is [System.Management.Automation.Language.CommandAst]) -and $c.CommandElements.Count -eq 1 -and ($c.GetCommandName() -in $Switches)
    }

    # Is this call in the ELSE of `if (<service switch>) { } else { }`, with
    # no elseif? Then the web service never runs it.
    function Global:FamIsOffService($Call, [string[]]$Switches) {
        $node = $Call
        while ($node) {
            $parent = $node.Parent
            if ($parent -is [System.Management.Automation.Language.IfStatementAst] -and $parent.ElseClause -eq $node -and
                $parent.Clauses.Count -eq 1 -and (FamIsSwitch $parent.Clauses[0].Item1 $Switches)) { return $true }
            $node = $parent
        }
        $false
    }

    # The calls the web service can run: every call but those off the service.
    function Global:FamServiceCalls($Ast, [string[]]$Switches) {
        @(FamCalls $Ast | Where-Object { -not (FamIsOffService $_ $Switches) })
    }

    # Every function definition in these files: name -> definition.
    function Global:FamFunctions([string[]]$Files) {
        $map = @{}
        foreach ($file in $Files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            foreach ($fd in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $map[$fd.Name] = $fd }
        }
        $map
    }
    function Global:FamFunctionsFromText([string]$Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $map = @{}
        foreach ($fd in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $map[$fd.Name] = $fd }
        $map
    }

    # How a call binds a switch: absent, true, false, unknown (a variable or
    # any other expression) or splatted (cannot be read).
    function Global:FamBindValue($Call, [string]$Parameter) {
        foreach ($el in $Call.CommandElements) {
            if ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted) { return 'splatted' }
        }
        foreach ($el in $Call.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst] -or $el.ParameterName -ne $Parameter) { continue }
            if (-not $el.Argument) { return 'true' }
            if ($el.Argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
                switch ($el.Argument.VariablePath.UserPath) { 'true' { return 'true' } 'false' { return 'false' } }
            }
            return 'unknown'
        }
        'absent'
    }

    # Does this call stay out of Azure because of its gate?
    function Global:FamGateHolds($Call, $Gate) {
        if (-not $Gate) { return $false }
        if ($Gate.FacadeNeverPasses) { return ((FamBindValue $Call $Gate.FacadeNeverPasses) -in @('absent', 'false')) }
        (FamBindValue $Call $Gate.FacadeAlwaysPasses) -eq 'true'
    }

    # Is this condition true ONLY when the switch is on? The switch alone, or
    # the switch as one operand of an -and chain, in brackets or not.
    function Global:FamIsGuard($Node, [string]$Switch) {
        if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
            if ($Node.PipelineElements.Count -ne 1) { return $false }
            return (FamIsGuard $Node.PipelineElements[0] $Switch)
        }
        if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { return (FamIsGuard $Node.Expression $Switch) }
        if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { return (FamIsGuard $Node.Pipeline $Switch) }
        if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) { return ($Node.VariablePath.UserPath -eq $Switch) }
        if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $Node.Operator -eq [System.Management.Automation.Language.TokenKind]::And) {
            return ((FamIsGuard $Node.Left $Switch) -or (FamIsGuard $Node.Right $Switch))
        }
        $false
    }

    # Is this call inside the body of an if-clause guarded by the switch?
    function Global:FamIsGuarded($Call, $Function, [string]$Switch) {
        $node = $Call
        while ($node -and $node -ne $Function) {
            $parent = $node.Parent
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $parent.Clauses) {
                    if ($clause.Item2 -eq $node -and (FamIsGuard $clause.Item1 $Switch)) { return $true }
                }
            }
            $node = $parent
        }
        $false
    }

    # Which functions reach a forbidden Az command by ANY path. A fixed point
    # over the whole graph, not a memoised recursion: a recursion cut short by
    # a call cycle would store "no" for a function whose answer was not known.
    function Global:FamForbidden($Functions, $Allowed, [string[]]$Switches = @()) {
        $calls = @{}
        foreach ($name in $Functions.Keys) { $calls[$name] = @(FamServiceCalls $Functions[$name].Body $Switches | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }) }
        $hit = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        do {
            $grew = $false
            foreach ($name in $Functions.Keys) {
                if ($hit.Contains($name)) { continue }
                foreach ($c in $calls[$name]) {
                    if (((FamIsAz $c) -and -not $Allowed.Contains($c)) -or $hit.Contains($c)) { [void]$hit.Add($name); $grew = $true; break }
                }
            }
        } while ($grew)
        $hit
    }
    function Global:FamCallReaches($Call, $Forbidden, $Allowed) {
        $n = $Call.GetCommandName()
        if (-not $n) { return $false }
        if (FamIsAz $n) { return (-not $Allowed.Contains($n)) }
        $Forbidden.Contains($n)
    }

    # ---- the walk of the real code -------------------------------------------

    $files = @(Get-ChildItem $script:moduleRoot -Filter *.ps1 -Recurse | ForEach-Object FullName) +
             @(Get-ChildItem (Join-Path $script:facadeRoot 'FacadeCore') -Filter *.psm1 | ForEach-Object FullName)
    $script:functions = FamFunctions $files
    $script:forbidden = FamForbidden $script:functions $script:allowed $script:serviceSwitches

    # The gates. FacadeNeverPasses: a call that does not turn the switch on
    # cannot reach Azure. FacadeAlwaysPasses: only a call that turns it on.
    $script:gates = @{
        'Remove-VmfRun' = @{ FacadeNeverPasses = 'DeleteSafetyCopies'
            Why = 'the copies are deleted only with -DeleteSafetyCopies, and that runs in the engine (DISCARD-ENGINE-1)' }
        'Remove-VmfExpiredSafetyCopies' = @{ FacadeAlwaysPasses = 'WhatIf'
            Why = 'the daily cleanup previews in the service with -WhatIf and starts the engine to delete (REACH-1)' }
    }

    $script:reachedAz = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:reachedFunctions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:offending = [System.Collections.Generic.List[string]]::new()
    $script:gateCalls = [System.Collections.Generic.List[object]]::new()
    # FACADE-SIGNIN-COLD-1: each Az command seen only off the service, so a
    # test can prove the walk saw them and passed them by the switch alone.
    $script:offServiceAz = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Global:FamWalk($Calls, [string[]]$Chain) {
        foreach ($call in $Calls) {
            $name = $call.GetCommandName()
            if (-not $name) { continue }
            if (FamIsOffService $call $script:serviceSwitches) {
                if (FamIsAz $name) { [void]$script:offServiceAz.Add($name) }
                continue
            }
            if (FamIsAz $name) {
                [void]$script:reachedAz.Add($name)
                if (-not $script:allowed.Contains($name)) { $script:offending.Add((@($Chain) + $name) -join ' -> ') }
                continue
            }
            if (-not $script:functions.ContainsKey($name)) { continue }
            if ($script:gates.ContainsKey($name)) {
                $holds = FamGateHolds $call $script:gates[$name]
                $script:gateCalls.Add([pscustomobject]@{ Name = $name; Chain = (@($Chain) + $name) -join ' -> '; Holds = $holds })
                if ($holds) { continue }
                # A call that does not honour its gate is followed like any
                # other - which is how the old discard is found.
                if (@($Chain) -contains $name) { continue }
                FamWalk (FamCalls $script:functions[$name].Body) (@($Chain) + $name)
                continue
            }
            if (-not $script:reachedFunctions.Add($name)) { continue }
            FamWalk (FamCalls $script:functions[$name].Body) (@($Chain) + $name)
        }
    }
    foreach ($f in Get-ChildItem $script:facadeRoot -Recurse -Include *.ps1, *.psm1) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        FamWalk (FamCalls $ast) @($f.FullName.Substring($script:repoRoot.Length + 1))
    }
}
AfterAll {
    Remove-Item 'function:\FamIsAz', 'function:\FamCalls', 'function:\FamFunctions', 'function:\FamFunctionsFromText',
        'function:\FamIsSwitch', 'function:\FamIsOffService', 'function:\FamServiceCalls',
        'function:\FamBindValue', 'function:\FamGateHolds', 'function:\FamIsGuard', 'function:\FamIsGuarded',
        'function:\FamForbidden', 'function:\FamCallReaches', 'function:\FamWalk' -ErrorAction SilentlyContinue
}

Describe 'DISCARD-ENGINE-1: the service calls only Az commands it loads' {
    It 'the walk really read the service and the module, so this cannot pass by reading nothing' {
        $script:functions.Count | Should -BeGreaterThan 200
        $script:reachedFunctions | Should -Contain 'Invoke-VmfFacadeDiscardRun'
        $script:reachedFunctions | Should -Contain 'Write-VmfEvent'
        $script:reachedFunctions | Should -Contain 'Invoke-VmfArmHttpRequest' -Because 'the service calls ARM, with a token from the managed identity endpoint'
        $script:reachedFunctions | Should -Contain 'Get-VmfIdentityEndpointToken'
        foreach ($az in 'Invoke-AzRestMethod', 'Get-AzAccessToken', 'Get-AzContext', 'Update-AzConfig') {
            $script:offServiceAz | Should -Contain $az -Because "the walk saw $az, and passed it by only because it is in the else of the service switch"
        }
        $script:forbidden | Should -Contain 'Unlock-VmfSnapshot' -Because 'the module does reach Az.Resources, from the engine'
    }

    It 'FACADE-SIGNIN-COLD-1: the service loads no Az module and reaches no Az command' {
        $script:loaded | Should -BeNullOrEmpty -Because 'the service takes no module from managed dependencies'
        @($script:reachedAz) | Should -BeNullOrEmpty -Because 'every Az command is behind the service switch, in the path of the engine and of a developer computer'
    }

    It 'FACADE-SIGNIN-COLD-1: each service switch is a function of the module or of the facade module' {
        foreach ($s in $script:serviceSwitches) {
            $script:functions.ContainsKey($s) | Should -BeTrue -Because "$s must be the real test, not a name nothing defines"
            # A switch must be the managed identity endpoint test, or ask it: a
            # broader test (only "this is the Functions host") would excuse an
            # Az call the service makes when the endpoint is missing.
            $body = $script:functions[$s].Body
            $calls = @(FamCalls $body | ForEach-Object { $_.GetCommandName() })
            $vars = @($body.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
            $asksEndpoint = ($calls -contains 'Test-VmfTokenFromIdentityEndpoint') -or (($vars -contains 'env:IDENTITY_ENDPOINT') -and ($vars -contains 'env:IDENTITY_HEADER'))
            $asksEndpoint | Should -BeTrue -Because "$s must read IDENTITY_ENDPOINT and IDENTITY_HEADER, or ask Test-VmfTokenFromIdentityEndpoint"
        }
    }

    It 'no command the service runs in process reaches an Az command from a module it does not load' {
        $script:offending -join [Environment]::NewLine | Should -BeNullOrEmpty -Because (
            "the service loads only $($script:loaded -join ', ') (src/facade/app/requirements.psd1). " +
            'Start the engine for this action instead - it holds the modules and the rights')
    }

    It 'every gated call on the service reach honours its gate' {
        $broken = @($script:gateCalls | Where-Object { -not $_.Holds } | ForEach-Object { $_.Chain })
        $broken -join [Environment]::NewLine | Should -BeNullOrEmpty
        @($script:gateCalls | Where-Object Name -EQ 'Remove-VmfRun').Count | Should -BeGreaterThan 0 `
            -Because 'the service still deletes a migration that keeps its copies, in process'
    }

    It 'inside a never-passed gate, every call that reaches Azure is behind that switch' {
        foreach ($name in @($script:gates.Keys | Where-Object { $script:gates[$_].FacadeNeverPasses })) {
            $switch = $script:gates[$name].FacadeNeverPasses
            $fd = $script:functions[$name]
            $risky = @(FamServiceCalls $fd.Body $script:serviceSwitches | Where-Object { FamCallReaches $_ $script:forbidden $script:allowed })
            $risky.Count | Should -BeGreaterThan 0 -Because "$name is a gate only because it can reach Azure"
            foreach ($call in $risky) {
                (FamIsGuarded $call $fd $switch) | Should -BeTrue -Because "$name calls $($call.GetCommandName()) outside 'if (`$$switch ...)'"
            }
        }
    }

    It 'inside an always-passed WhatIf gate, every call that reaches Azure comes after ShouldProcess' {
        foreach ($name in @($script:gates.Keys | Where-Object { $script:gates[$_].FacadeAlwaysPasses -eq 'WhatIf' })) {
            $fd = $script:functions[$name]
            $fd.Body.ParamBlock.Attributes.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
            $ask = @($fd.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $args[0].Member.Extent.Text -eq 'ShouldProcess' }, $true))
            $ask.Count | Should -BeGreaterThan 0
            $first = ($ask | Measure-Object -Property { $_.Extent.StartOffset } -Minimum).Minimum
            foreach ($call in @(FamServiceCalls $fd.Body $script:serviceSwitches | Where-Object { FamCallReaches $_ $script:forbidden $script:allowed })) {
                $call.Extent.StartOffset | Should -BeGreaterThan $first -Because "$name calls $($call.GetCommandName()) before it asks ShouldProcess"
            }
        }
    }

    It 'the service loads only modules this test knows the commands of' {
        foreach ($m in $script:loaded) {
            $script:moduleCommands.ContainsKey($m) | Should -BeTrue -Because "add the commands of $m to this test"
        }
    }

}

Describe 'FACADE-SIGNIN-COLD-1: the service switch cannot be talked round' {
    BeforeAll {
        $script:sw = @('Test-VmfTokenFromIdentityEndpoint')
        function Global:FamAzCallIn([string]$Text) {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
            @(FamCalls $ast | Where-Object { $_.GetCommandName() -eq 'Get-AzAccessToken' })[0]
        }
    }
    AfterAll { Remove-Item 'function:\FamAzCallIn' -ErrorAction SilentlyContinue }

    It 'only the else of the switch alone is off the service: <Text> -> <Off>' -ForEach @(
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint) { 1 } else { Get-AzAccessToken }'; Off = $true }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint) { 1 } else { if ($x) { Get-AzAccessToken } }'; Off = $true }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint) { Get-AzAccessToken } else { 1 }'; Off = $false }
        @{ Text = 'if (-not (Test-VmfTokenFromIdentityEndpoint)) { 1 } else { Get-AzAccessToken }'; Off = $false }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint -Force) { 1 } else { Get-AzAccessToken }'; Off = $false }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint | Out-Null) { 1 } else { Get-AzAccessToken }'; Off = $false }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint) { 1 } elseif ($y) { 2 } else { Get-AzAccessToken }'; Off = $false }
        @{ Text = 'if (Test-VmfOtherThing) { 1 } else { Get-AzAccessToken }'; Off = $false }
        @{ Text = 'if (Test-VmfTokenFromIdentityEndpoint) { 1 }; Get-AzAccessToken'; Off = $false }
        @{ Text = 'Get-AzAccessToken'; Off = $false }) {
        (FamIsOffService (FamAzCallIn $Text) $script:sw) | Should -Be $Off
    }

    It 'a function that reaches Azure only off the service is not forbidden; one that reaches it on the service is' {
        $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $fns = FamFunctionsFromText ('function Tok { if (Test-VmfTokenFromIdentityEndpoint) { Get-Endpoint } else { Get-AzAccessToken } }; ' +
            'function Leak { if (Test-VmfTokenFromIdentityEndpoint) { Get-AzAccessToken } else { 1 } }; function UsesTok { Tok }; function UsesLeak { Leak }')
        $hit = FamForbidden $fns $allowed $script:sw
        $hit.Contains('Tok') | Should -BeFalse
        $hit.Contains('UsesTok') | Should -BeFalse
        $hit.Contains('Leak') | Should -BeTrue
        $hit.Contains('UsesLeak') | Should -BeTrue
        (FamForbidden $fns $allowed).Contains('Tok') | Should -BeTrue -Because 'with no switch named, an else is a reach like any call'
    }
}

Describe 'DISCARD-ENGINE-1 N4: the guard cannot be talked round' {
    BeforeAll {
        function Global:FamCall([string]$Text) {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
            @(FamCalls $ast)[0]
        }
        $script:never = @{ FacadeNeverPasses = 'DeleteSafetyCopies' }
        $script:always = @{ FacadeAlwaysPasses = 'WhatIf' }
    }
    AfterAll { Remove-Item 'function:\FamCall' -ErrorAction SilentlyContinue }

    It 'a switch is read by its VALUE: <Text> -> <Holds>' -ForEach @(
        @{ Text = 'Remove-VmfRun -RunPath $p -KeepSafetyCopies'; Gate = 'never'; Holds = $true }
        @{ Text = 'Remove-VmfRun -RunPath $p -DeleteSafetyCopies:$false'; Gate = 'never'; Holds = $true }
        @{ Text = 'Remove-VmfRun -RunPath $p -DeleteSafetyCopies'; Gate = 'never'; Holds = $false }
        @{ Text = 'Remove-VmfRun -RunPath $p -DeleteSafetyCopies:$true'; Gate = 'never'; Holds = $false }
        @{ Text = 'Remove-VmfRun -RunPath $p -DeleteSafetyCopies:$delCopies'; Gate = 'never'; Holds = $false }
        @{ Text = 'Remove-VmfRun @params'; Gate = 'never'; Holds = $false }
        @{ Text = 'Remove-VmfExpiredSafetyCopies -RunPath $p -WhatIf'; Gate = 'always'; Holds = $true }
        @{ Text = 'Remove-VmfExpiredSafetyCopies -RunPath $p -WhatIf:$true'; Gate = 'always'; Holds = $true }
        @{ Text = 'Remove-VmfExpiredSafetyCopies -RunPath $p -WhatIf:$false'; Gate = 'always'; Holds = $false }
        @{ Text = 'Remove-VmfExpiredSafetyCopies -RunPath $p -WhatIf:$preview'; Gate = 'always'; Holds = $false }
        @{ Text = 'Remove-VmfExpiredSafetyCopies -RunPath $p'; Gate = 'always'; Holds = $false }) {
        $g = if ($Gate -eq 'never') { $script:never } else { $script:always }
        (FamGateHolds (FamCall $Text) $g) | Should -Be $Holds
    }

    It 'only a real guard counts: <Condition> -> <Guarded>' -ForEach @(
        @{ Condition = '$DeleteSafetyCopies'; Guarded = $true }
        @{ Condition = '$snaps.Count -gt 0 -and $DeleteSafetyCopies'; Guarded = $true }
        @{ Condition = '($DeleteSafetyCopies) -and $x'; Guarded = $true }
        @{ Condition = '$DeleteSafetyCopies -or $true'; Guarded = $false }
        @{ Condition = '-not $DeleteSafetyCopies'; Guarded = $false }
        @{ Condition = '$DeleteSafetyCopies -eq $false'; Guarded = $false }
        @{ Condition = '$KeepSafetyCopies'; Guarded = $false }
        @{ Condition = '$x -or ($y -and $DeleteSafetyCopies)'; Guarded = $false }) {
        $fns = FamFunctionsFromText "function G { param([switch]`$DeleteSafetyCopies) if ($Condition) { Remove-AzResourceLock -Force } }"
        $fd = $fns['G']
        $call = @(FamCalls $fd.Body | Where-Object { $_.GetCommandName() -eq 'Remove-AzResourceLock' })[0]
        (FamIsGuarded $call $fd 'DeleteSafetyCopies') | Should -Be $Guarded
    }

    It 'a call in the ELSE of a guard is not guarded' {
        $fns = FamFunctionsFromText 'function G { param([switch]$DeleteSafetyCopies) if ($DeleteSafetyCopies) { } else { Remove-AzResourceLock -Force } }'
        $call = @(FamCalls $fns['G'].Body | Where-Object { $_.GetCommandName() -eq 'Remove-AzResourceLock' })[0]
        (FamIsGuarded $call $fns['G'] 'DeleteSafetyCopies') | Should -BeFalse
    }

    It 'a call cycle does not hide a reach, whichever function is asked first' {
        $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($order in @('function A { B }; function B { A; C }; function C { Remove-AzResourceLock }',
                             'function C { Remove-AzResourceLock }; function B { A; C }; function A { B }')) {
            $hit = FamForbidden (FamFunctionsFromText $order) $allowed
            @('A', 'B', 'C' | Where-Object { $hit.Contains($_) }).Count | Should -Be 3
        }
        (FamForbidden (FamFunctionsFromText 'function A { B }; function B { A }') $allowed).Count | Should -Be 0
    }
}
