#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WRITE-DEPTH-OPEN-1, the write side of HELD-READ-DEPTH-1.
#
# ConvertTo-Json does not fail on an object deeper than its -Depth. It writes
# the part below that depth as the TYPE NAME in a string
# ("System.Collections.Hashtable") and PowerShell 7 gives only a warning
# ("Resulting JSON is truncated"). The record is saved, and it is wrong. With no
# -Depth at all the depth is 2.
#
# This gate finds every store write in src - the JSON writers (Write-VmfStoreJson,
# Write-VmfStoreJsonExclusive, Write-VmfStoreRootJson, Write-VmfJsonDocument)
# and the text writers (Write-VmfStoreText*, Write-VmfTextDocumentIfVersion,
# Write-VmfStoreRootText*, Add-VmfStoreLine) with the ConvertTo-Json that made
# their text - names the document each one writes, and asks that document's
# JSON schema how deep it can nest (_StoreDocumentDepth.ps1, the read gate's
# own measure). A schema with an open part needs 24. A write whose document or
# whose text it cannot name fails, so a new one cannot slip past.
#
# ConvertTo-Json -Depth N writes a document that nests N + 1 (the root object
# is 1). The gate asks for N >= the nesting, as the read gate does: one level
# more than the least, the same number on both sides.
BeforeAll {
    . (Join-Path $PSScriptRoot '_StoreDocumentDepth.ps1')

    $script:jsonWriters = @{
        # command = the parameter that names the document, its default depth
        'Write-VmfStoreJson'          = @{ Path = 'RelPath'; Default = 24 }
        'Write-VmfStoreJsonExclusive' = @{ Path = 'RelPath'; Default = 24 }
        'Write-VmfStoreRootJson'      = @{ Path = 'Name'; Default = 24 }
        'Write-VmfJsonDocument'       = @{ Path = 'Path'; Default = 24 }
    }
    $script:textWriters = @{
        # command = the parameter that names the document, the parameter that holds the text
        'Write-VmfStoreText'               = @{ Path = 'RelPath'; Text = 'Content' }
        'Write-VmfStoreTextExclusive'      = @{ Path = 'RelPath'; Text = 'Content' }
        'Write-VmfStoreTextIfVersion'      = @{ Path = 'RelPath'; Text = 'Content' }
        'Write-VmfTextDocumentIfVersion'   = @{ Path = 'Path'; Text = 'Content' }
        'Write-VmfStoreRootTextIfVersion'  = @{ Path = 'Name'; Text = 'Content' }
        'Write-VmfStoreRootTextExclusive'  = @{ Path = 'Name'; Text = 'Content' }
        'Add-VmfStoreLine'                 = @{ Path = 'RelPath'; Text = 'Line' }
    }
    # A path that is a parameter of its function (or a field of one): the
    # file, the path text, and the document every caller passes.
    $script:kindByParameter = @{
        'Orchestrator.ps1|$ClaimRelPath'    = 'capacity-claim'
        'CapacityClaim.ps1|$Handle'         = 'capacity-claim'
        'Request-VmfQuota.ps1|$m.Rel'       = 'capacity-claim'
        'MigrationRecord.ps1|$Name'         = 'migration-record'   # $name too: the keys ignore case
        'MigrationRecord.ps1|(Get-VmfStoreItemHandle -RunPath $Scope -RelPath $Name)' = 'migration-record'
        'Resolve-VmfDecision.ps1|$PlanPath' = 'plan'
        'Set-VmfMachineTarget.ps1|$r.Rel'   = 'text-as-read'   # an approval, an acceptance or the plan sign-off, put back as read
    }
    # The store layer itself: it passes a caller's path, text and depth on.
    $script:passThrough = @('StoreApi.ps1')
    # A text this call does not serialize - it writes text it read, or text that
    # is not JSON. The file, the text, and why. Each one is checked by hand.
    $script:textAsGiven = @{
        'GuestOps.ps1|$raw'                 = 'the guest script output, as the guest wrote it'
        'Orchestrator.ps1|$approvalText'    = 'a wave approval put back as the text that was read'
        'New-VmfPlan.ps1|$choicesText'      = 'target-choices.json copied as its stored text'
        'New-VmfPlan.ps1|$machinesText'     = 'machine-choices.json copied as its stored text'
        'New-VmfPlan.ps1|(Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath ''target-advice.json''))' = 'target-advice.json copied as its stored text'
        'New-VmfReport.ps1|$sb.ToString()'  = 'the HTML report, not JSON'
        'Set-VmfMachineTarget.ps1|$r.Text'  = 'a removed approval put back as the text that was read'
        'Set-VmfMachineTarget.ps1|$read.Text' = 'plan.json put back as the text that was read'
    }

    function Script:Get-ConstantDepth($convertCall) {
        # The -Depth of one ConvertTo-Json: 2 when it gives none, $null when it
        # is not a number written in the code.
        $els = $convertCall.CommandElements
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Depth') {
                $v = if ($els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] }
                if ($v -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [int]$v.Value }
                return $null
            }
        }
        2
    }
    function Script:Find-ConvertCalls($node) {
        @($node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-Json' }, $true))
    }
    function Script:Get-NamedArgument($call, [string]$name) {
        for ($i = 0; $i -lt $call.CommandElements.Count - 1; $i++) {
            $e = $call.CommandElements[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq $name) {
                if ($e.Argument) { return $e.Argument }
                return $call.CommandElements[$i + 1]
            }
        }
        $null
    }
    function Script:Get-LastAssignment($assigns, [string]$var, [int]$before) {
        @($assigns | Where-Object { $_.Left.VariablePath.UserPath -eq $var -and $_.Extent.StartOffset -lt $before }) | Select-Object -Last 1
    }

    function Script:Get-StoreWrites {
        $srcRoot = Join-Path $script:repoRoot 'src'
        $files = @(Get-ChildItem $srcRoot -Recurse -File -Include *.ps1, *.psm1)
        $parsed = @{}
        foreach ($item in $files) { $parsed[$item.FullName] = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$null, [ref]$null) }
        # A function in src that makes JSON text: its name, and the least depth
        # of its own ConvertTo-Json. A text writer whose text comes from one
        # (New-VmfDecisionCarryNoteText) is judged by that depth.
        $serializers = @{}
        foreach ($ast in $parsed.Values) {
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $depths = @(Script:Find-ConvertCalls $fn.Body | ForEach-Object { Script:Get-ConstantDepth $_ })
                if ($depths.Count) { $serializers[$fn.Name] = $(if ($depths -contains $null) { $null } else { ($depths | Measure-Object -Minimum).Minimum }) }
            }
        }
        foreach ($item in $files) {
            $ast = $parsed[$item.FullName]
            $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    ($script:jsonWriters.Contains([string]$n.GetCommandName()) -or $script:textWriters.Contains([string]$n.GetCommandName())) }, $true)
            foreach ($c in $calls) {
                $name = $c.GetCommandName()
                $where = '{0}:{1}' -f $item.Name, $c.Extent.StartLineNumber
                $spec = if ($script:jsonWriters.Contains($name)) { $script:jsonWriters[$name] } else { $script:textWriters[$name] }

                # The document: the path text, the last assignment to a path
                # variable above the call, or a parameter of the function.
                $pathArg = Script:Get-NamedArgument $c $spec.Path
                $pathText = if ($pathArg) { $pathArg.Extent.Text } else { '' }
                $kind = $null
                if ($pathArg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $last = Script:Get-LastAssignment $assigns $pathArg.VariablePath.UserPath $c.Extent.StartOffset
                    if ($last) { $pathText = $last.Right.Extent.Text }
                }
                $paramKey = '{0}|{1}' -f $item.Name, $pathText
                if ($script:kindByParameter.Contains($paramKey)) { $kind = $script:kindByParameter[$paramKey] }
                else { foreach ($k in $script:kindByPath.Keys) { if ($pathText -match $k) { $kind = $script:kindByPath[$k]; break } } }

                # The depth: the writer's own -Depth, or the ConvertTo-Json that
                # made the text - in the argument, in the last assignment to the
                # variable it passes, or in the src function that made it.
                $depth = $null; $depthFrom = ''; $asGiven = $null
                if ($script:jsonWriters.Contains($name)) {
                    $d = Script:Get-NamedArgument $c 'Depth'
                    if (-not $d) { $depth = $spec.Default; $depthFrom = 'default' }
                    elseif ($d -is [System.Management.Automation.Language.ConstantExpressionAst]) { $depth = [int]$d.Value; $depthFrom = '-Depth' }
                    else { $depthFrom = $d.Extent.Text }
                }
                else {
                    $text = Script:Get-NamedArgument $c $spec.Text
                    $source = $text
                    if ($text -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $last = Script:Get-LastAssignment $assigns $text.VariablePath.UserPath $c.Extent.StartOffset
                        if ($last) { $source = $last.Right }
                    }
                    if ($source) {
                        $converts = @(Script:Find-ConvertCalls $source)
                        $made = @($source.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $serializers.Contains([string]$n.GetCommandName()) }, $true))
                        if ($converts.Count) {
                            $ds = @($converts | ForEach-Object { Script:Get-ConstantDepth $_ })
                            if ($ds -notcontains $null) { $depth = ($ds | Measure-Object -Minimum).Minimum; $depthFrom = 'ConvertTo-Json' }
                            else { $depthFrom = 'ConvertTo-Json with a depth that is not a number' }
                        }
                        elseif ($made.Count) {
                            $depth = $serializers[$made[0].GetCommandName()]; $depthFrom = $made[0].GetCommandName()
                        }
                    }
                    $textKey = '{0}|{1}' -f $item.Name, $(if ($text) { $text.Extent.Text } else { '' })
                    if ($null -eq $depth -and $script:textAsGiven.Contains($textKey)) { $asGiven = $script:textAsGiven[$textKey] }
                    if (-not $depthFrom) { $depthFrom = $textKey }
                }
                [pscustomobject]@{ Where = $where; File = $item.Name; Command = $name; PathText = $pathText; Kind = $kind
                    Depth = $depth; DepthFrom = $depthFrom; AsGiven = $asGiven }
            }
        }
    }
    $script:writes = @(Script:Get-StoreWrites)
    $script:checked = @($script:writes | Where-Object { $_.File -notin $script:passThrough })
}

Describe 'WRITE-DEPTH-OPEN-1: every store write gives a depth its document fits in' {
    It 'finds the store writes (the scan is not empty)' {
        $script:checked.Count | Should -BeGreaterThan 40
        @($script:checked | Where-Object { $_.Kind -eq 'wave-options-acceptance' }).Count | Should -BeGreaterOrEqual 2
        @($script:checked | Where-Object { $_.Kind -eq 'capacity-history' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'names the document of every write, so a new write cannot slip past' {
        $unknown = @($script:checked | Where-Object { -not $_.Kind } | ForEach-Object { '{0} {1} {2}' -f $_.Where, $_.Command, $_.PathText })
        $unknown | Should -BeNullOrEmpty -Because 'each write must map to its schema (kindByPath in _StoreDocumentDepth.ps1, or kindByParameter here)'
    }

    It 'finds the depth of every write, or knows its text is not made here' {
        $loose = @($script:checked | Where-Object { $null -eq $_.Depth -and -not $_.AsGiven } | ForEach-Object { '{0} {1} ({2})' -f $_.Where, $_.Command, $_.DepthFrom })
        $loose | Should -BeNullOrEmpty -Because 'a write gives a -Depth that is a number, or its text is in textAsGiven with the reason'
    }

    It 'writes each document with a depth at least as deep as its schema lets it nest' {
        $short = @(foreach ($w in $script:checked) {
                if (-not $w.Kind -or $null -eq $w.Depth -or $w.Kind -eq 'text-as-read') { continue }
                $required = Script:Get-DocumentDepthNeeded $w.Kind
                if ($w.Depth -lt $required) {
                    '{0} writes {1} at depth {2} ({3}); it needs {4}' -f $w.Where, $w.Kind, $w.Depth, $w.DepthFrom, $required
                }
            })
        $short | Should -BeNullOrEmpty
    }

    It 'measures the documents the item named as open' {
        foreach ($k in 'wave-options-acceptance', 'capacity-history') {
            Script:Get-DocumentDepthNeeded $k | Should -Be 24 -Because "$k has an open part"
        }
    }

    It 'reads the depth a ConvertTo-Json gives, and 2 when it gives none' {
        $one = [System.Management.Automation.Language.Parser]::ParseInput('$x | ConvertTo-Json -Depth 7; $y | ConvertTo-Json -Compress; $z | ConvertTo-Json -Depth:9', [ref]$null, [ref]$null)
        $found = @(Script:Find-ConvertCalls $one | ForEach-Object { Script:Get-ConstantDepth $_ })
        $found | Should -Be @(7, 2, 9)
    }

    It 'ConvertTo-Json really writes a deeper part as its type name (the defect this gate stops)' {
        $doc = @{ a = @{ b = @{ c = 1 } } }
        $text = $doc | ConvertTo-Json -Depth 1 -WarningAction SilentlyContinue
        $text | Should -Match 'System\.Collections\.Hashtable'
        ($doc | ConvertTo-Json -Depth 2) | Should -Not -Match 'System\.Collections'
    }
}

Describe 'WRITE-DEPTH-OPEN-1: the writers the gate trusts give the depth it counts' {
    It 'each JSON writer''s own default depth is the one the gate counts' {
        $defs = @{}
        foreach ($item in Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -File -Include *.ps1, *.psm1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $script:jsonWriters.Contains($n.Name) }, $true)) {
                $param = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Depth' })
                $defs[$fn.Name] = if ($param.Count) { [int]$param[0].DefaultValue.Value }
                else { (@(Script:Find-ConvertCalls $fn.Body | ForEach-Object { Script:Get-ConstantDepth $_ }) | Measure-Object -Minimum).Minimum }
            }
        }
        foreach ($k in $script:jsonWriters.Keys) {
            $defs[$k] | Should -Be $script:jsonWriters[$k].Default -Because "$k writes with this depth when its caller gives none"
        }
    }
}

Describe 'WRITE-DEPTH-OPEN-1: a deep activity line is written whole and kept in the migration record' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
        . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
        Block-VmfAzureCalls -TestFile $PSCommandPath
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wdo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'Write-VmfEvent keeps -Data that nests past 12, and the record reads the line back' {
        $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web'
        $tree = @{ leaf = 'kept' }
        foreach ($i in 1..14) { $tree = @{ inner = $tree } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $id; tree = $tree } {
            Initialize-VmfRun -RunPath $rp -RunId 'mig-1' -Kind 'migration' -FromAssessment 'scan-1' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mig-1' -VmId $id -Wave 'w1' | Out-Null
            Write-VmfEvent -RunPath $rp -Step 'deep' -Outcome info -VmId $id -Data @{ tree = $tree } -WarningVariable script:wdoWarn -WarningAction SilentlyContinue
        }
        @{ schemaVersion = 1; assessmentRunId = 'scan-1'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; path = 'A'
                    assessment = @{ sourceSize = 'Standard_D2s_v4'; os = 'Windows Server 2022' }
                    target = @{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }) } |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:rp 'plan.json')

        $line = Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | Where-Object { $_ -match '"deep"' }
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Not -Match 'System\.Collections' -Because 'a part below the write depth is saved as its type name'
        $line | Should -Match '"leaf":"kept"'

        $record = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Get-VmfMigrationRecordFromStore -RunPath $rp -Reason downloaded -WarningAction SilentlyContinue
        }
        $web = @($record.machines | Where-Object { [string]$_.vmId -eq $id })
        $web.Count | Should -Be 1
        @($web[0].activity | Where-Object { [string]$_.step -eq 'deep' }).Count | Should -Be 1 -Because 'a line the record cannot read at its depth is dropped without a word'
    }
}