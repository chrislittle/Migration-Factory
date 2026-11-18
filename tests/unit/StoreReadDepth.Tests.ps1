#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# HELD-READ-DEPTH-1. Final lab, 2026-11-13: the run summary read assessment.json
# with a depth of 4. A real assessment nests vms[].workload.evidence[] six deep,
# so ConvertFrom-Json threw "The reader's MaxDepth of 4 has been exceeded" on
# every read, the catch made the held list null, and Choose the machines showed
# "The page could not read which machines other migrations hold" on every plan.
# The unit test passed because its assessment had no workload at all.
#
# The class: a store read that gives a depth smaller than its document can
# nest. This gate finds every Read-VmfStoreJson, Read-VmfCarryRecord and
# Read-VmfPlanDocument in src, names the document each one reads, and asks
# that document's JSON schema how deep it can nest. A schema with an open part
# (an object with no "additionalProperties": false) can nest to any depth, so
# its reads must take the full default depth of 24.
BeforeAll {
    # The schema-depth measure, the documents with no schema and the path map
    # are shared with the write gate (StoreWriteDepth.Tests.ps1).
    . (Join-Path $PSScriptRoot '_StoreDocumentDepth.ps1')
    # A RelPath that is a parameter of its function: the file, the parameter,
    # and the document every caller passes.
    $script:kindByParameter = @{
        'Orchestrator.ps1|$ClaimRelPath'     = 'capacity-claim'
        'MigrationRecord.ps1|$n'             = 'migration-record'
        'Get-VmfMigrationRecord.ps1|$Name'   = 'migration-record'
    }
    # The two functions that pass a caller's -RelPath and -Depth on unchanged.
    $script:passThrough = @('StoreApi.ps1', 'PlanContract.ps1')
    $script:defaultDepth = @{ 'Read-VmfStoreJson' = 24; 'Read-VmfCarryRecord' = 8; 'Read-VmfPlanDocument' = 24 }

    function Script:Get-StoreReads {
        $srcRoot = Join-Path $script:repoRoot 'src'
        foreach ($item in Get-ChildItem $srcRoot -Recurse -File -Include *.ps1, *.psm1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$null, [ref]$null)
            $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @($script:defaultDepth.Keys) }, $true)
            foreach ($c in $calls) {
                $name = $c.GetCommandName()
                $rel = $null; $depth = $null
                for ($i = 0; $i -lt $c.CommandElements.Count - 1; $i++) {
                    $e = $c.CommandElements[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($e.ParameterName -eq 'RelPath') { $rel = $c.CommandElements[$i + 1] }
                        if ($e.ParameterName -eq 'Depth') { $depth = $c.CommandElements[$i + 1] }
                    }
                }
                $where = '{0}:{1}' -f $item.Name, $c.Extent.StartLineNumber
                $relText = if ($rel) { $rel.Extent.Text } elseif ($name -eq 'Read-VmfPlanDocument') { "'plan.json'" } else { '' }
                # A variable path: the last assignment to it above the call.
                if ($rel -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $var = $rel.VariablePath.UserPath
                    $last = @($assigns | Where-Object { $_.Left.VariablePath.UserPath -eq $var -and $_.Extent.StartOffset -lt $c.Extent.StartOffset }) | Select-Object -Last 1
                    if ($last) { $relText = $last.Right.Extent.Text }
                    elseif ($script:kindByParameter.Contains("$($item.Name)|`$$var")) { $relText = "param:$($script:kindByParameter["$($item.Name)|`$$var"])" }
                }
                $kind = $null
                if ($relText -like 'param:*') { $kind = $relText.Substring(6) }
                elseif ($relText -eq "'plan.json'") { $kind = 'plan' }
                else { foreach ($k in $script:kindByPath.Keys) { if ($relText -match $k) { $kind = $script:kindByPath[$k]; break } } }
                $depthValue = if (-not $depth) { $script:defaultDepth[$name] }
                elseif ($depth -is [System.Management.Automation.Language.ConstantExpressionAst]) { [int]$depth.Value }
                else { $null }
                [pscustomobject]@{ Where = $where; File = $item.Name; Command = $name; RelPath = $relText; Kind = $kind; Depth = $depthValue; DepthText = $(if ($depth) { $depth.Extent.Text } else { '' }) }
            }
        }
    }
    $script:reads = @(Script:Get-StoreReads)
    $script:nesting = @{}
    foreach ($k in @($script:reads | Where-Object { $_.Kind } | ForEach-Object { $_.Kind } | Sort-Object -Unique)) {
        $script:nesting[$k] = Script:Get-DocumentNesting $k
    }
}

Describe 'HELD-READ-DEPTH-1: every store read takes a depth its document fits in' {
    It 'finds the store reads (the scan is not empty)' {
        $script:reads.Count | Should -BeGreaterThan 50
        @($script:reads | Where-Object { $_.RelPath -match 'assessment\.json' }).Count | Should -BeGreaterOrEqual 3
    }

    It 'names the document of every read, so a new read cannot slip past' {
        $unknown = @($script:reads | Where-Object { -not $_.Kind -and $_.File -notin $script:passThrough } |
            ForEach-Object { '{0} {1}' -f $_.Where, $_.RelPath })
        $unknown | Should -BeNullOrEmpty -Because 'each read must map to its schema in this file (kindByPath or kindByParameter)'
    }

    It 'gives a fixed depth everywhere but the two pass-through readers' {
        $loose = @($script:reads | Where-Object { $null -eq $_.Depth -and $_.File -notin $script:passThrough } |
            ForEach-Object { '{0} -Depth {1}' -f $_.Where, $_.DepthText })
        $loose | Should -BeNullOrEmpty
    }

    It 'reads each document with a depth at least as deep as its schema lets it nest' {
        $short = @(foreach ($r in $script:reads) {
                if (-not $r.Kind -or $null -eq $r.Depth) { continue }
                $need = $script:nesting[$r.Kind]
                $required = if ($need -ge 99) { 24 } else { $need }
                if ($r.Depth -lt $required) {
                    '{0} reads {1} at depth {2}; it needs {3}' -f $r.Where, $r.Kind, $r.Depth, $(if ($need -ge 99) { '24 (the schema has an open part)' } else { $need })
                }
            })
        $short | Should -BeNullOrEmpty
    }

    It 'measures the assessment as open, and a real one past depth 4' {
        $script:nesting['assessment'] | Should -Be 99 -Because 'the assessment schema root has no additionalProperties: false'
        $vmItems = (Get-Content (Join-Path $script:schemaDir 'assessment.schema.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
        $workload = Script:Get-SchemaNesting $vmItems['properties']['vms']['items']['properties']['workload'] $vmItems @()
        (2 + 1 + $workload) | Should -BeGreaterThan 4 -Because 'vms[] (2), a machine (3), workload and its evidence below it'
    }

    It 'measures a closed schema to its real depth' {
        $script:nesting['run-manifest'] | Should -Be 3 -Because 'run.json: root, scope, scope.subscriptions[]'
        $script:nesting['lease'] | Should -Be 1
    }
}
