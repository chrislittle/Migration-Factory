#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# COPY-DEPTH-GATE-1, the third store-depth gate, beside HELD-READ-DEPTH-1
# (StoreReadDepth.Tests.ps1, the JSON readers) and WRITE-DEPTH-OPEN-1
# (StoreWriteDepth.Tests.ps1, every store write).
#
# Two kinds of call were checked only by hand:
#
# - A DIRECT READ: ConvertFrom-Json -Depth N of store text read first
#   (Read-VmfStoreText, Read-VmfTextDocument and the other text readers).
#   ConvertFrom-Json THROWS on text that nests deeper than N ("The reader's
#   MaxDepth of N has been exceeded"), and most callers read a throw as "no
#   document" or "cannot read".
# - AN IN-MEMORY COPY: X | ConvertTo-Json -Depth A | ConvertFrom-Json -Depth B.
#   ConvertTo-Json writes a part below A as its TYPE NAME, with only a warning,
#   and the copy is then saved or acted on.
#
# This gate finds EVERY ConvertFrom-Json in src, and traces its input text: to
# a store text reader (a direct read: the document is named from the reader's
# path, by the read gate's own path map), to a ConvertTo-Json (a copy: the
# copied part is named in $copyOf below), or to text that is not a store
# document (an HTTP answer from Azure, or a file in $notStore with the
# reason). An input it cannot trace fails, so a new one cannot slip past. Each
# depth is then asked of the document's JSON schema, with the measure the other
# two gates use (_StoreDocumentDepth.ps1): an open part needs 24.
BeforeAll {
    . (Join-Path $PSScriptRoot '_StoreDocumentDepth.ps1')


    # The store text readers, and the parameter that names the document. A
    # reader with no path parameter (Read-VmfStoreTextMany takes -Items) is
    # named by the whole call's text.
    $script:textReaders = @{
        'Read-VmfStoreText'       = 'RelPath'
        'Read-VmfStoreTextMany'   = ''
        'Read-VmfStoreRootText'   = 'Name'
        'Read-VmfStoreLines'      = 'RelPath'
        'Read-VmfTextDocument'    = 'Path'
        'Read-VmfFileTextShared'  = 'Path'
    }
    # The JSON readers the read gate does not cover, and their own default
    # depth (checked below against the function).
    $script:jsonReaders = @{
        'Read-VmfStoreRootJson' = @{ Path = 'Name'; Default = 24 }
        'Read-VmfJsonDocument'  = @{ Path = 'Path'; Default = 24 }
    }
    # The store layer itself, and the JSON readers the read gate checks: each
    # passes a caller's text and depth on (-Depth $Depth).
    $script:passThrough = @{
        'StoreApi.ps1'      = 'the store layer: Read-VmfStoreJson, Read-VmfStoreRootJson, Read-VmfJsonDocument'
        'DecisionCarry.ps1' = 'Read-VmfCarryRecord, which the read gate checks at its callers'
    }
    # A text that is a parameter of its function: the file, the text, and the
    # document every caller passes.
    $script:kindByParameter = @{
        'ScheduleDue.ps1|$Text'      = 'schedule-due'     # ConvertFrom-VmfScheduleDue: Read-VmfScheduleDue's text
        'CapacityClaim.ps1|$Content' = 'capacity-claim'   # Test-VmfCapacityClaimText: a claim's stored text
        'Orchestrator.ps1|$approvalText' = 'wave-approval' # the judge of each approvals/<wave>.json
    }
    # A reader's path that is a parameter of its function: the file, the path
    # text, and the document every caller passes.
    $script:pathByParameter = @{
        'DecisionCarry.ps1|$PlanPath'  = 'plan'
        'Orchestrator.ps1|$PlanPath'   = 'plan'
        'PlanRun.ps1|$PlanPath'        = 'plan'
        'PlanContract.ps1|$Path'       = 'plan'   # Read-VmfPlanFile, Read-VmfPlanFileVersioned
        'Approve-VmfPlan.ps1|$PlanPath'               = 'plan'
        'Approve-VmfWave.ps1|$PlanPath'               = 'plan'
        'Confirm-VmfWaveOptions.ps1|$PlanPath'        = 'plan'
        'Remove-VmfExpiredSafetyCopies.ps1|$PlanPath' = 'plan'
        'New-VmfPlan.ps1|$AssessmentPath'             = 'assessment'
        'New-VmfTargetAdvice.ps1|$AssessmentPath'     = 'assessment'
        'MigrationRecord.ps1|(Get-VmfStoreItemHandle -RunPath $Scope -RelPath $Name)' = 'migration-record'
    }
    # A copy: the file, the copied expression, and the schema part it copies
    # ('<schema>' for a whole document, '<schema>#<pointer>' for a part).
    $script:copyOf = @{
        'CapacityClaim.ps1|$Claim'                    = 'capacity-claim'
        'OriginalCapture.ps1|$attempt'                = 'vm-state#/properties/captured/properties/vmConfig'
        'StateMachine.ps1|$doc.captured.vmConfig'     = 'vm-state#/properties/captured/properties/vmConfig'
        'StateMachine.ps1|$PlanEntry.target'          = 'plan-entry#/properties/target'
        'StateMachine.ps1|$t'                         = 'plan-entry#/properties/target'   # Get-VmfStartedTargetEntry: the was and is targets
        'StateMachine.ps1|$Started.target'            = 'plan-entry#/properties/target'   # captured.startedTarget.target: the plan entry's target as PRECHECK read it
        'StateMachine.ps1|$PlanEntry'                 = 'plan-entry'
        'PlannedAn.ps1|$PlanEntry'                    = 'plan-entry'
        'DriverReadiness.ps1|$PlanEntry'              = 'plan-entry'
        'ReportHtml.ps1|$Record'                      = 'migration-record'
        'Confirm-VmfWaveOptions.ps1|$_.policy'        = 'plan-entry#/properties/policy'   # one distinct policy set per row
    }
    # A text that is not a store document. The file, the input text, and what
    # it is. An HTTP answer ($x.Content) needs no line here.
    $script:notStore = @{
        'ImageSupport.ps1|Get-Content $file -Raw -Encoding utf8'              = 'data/supported-images.json, shipped with the module'
        'NvaDetection.ps1|Get-Content $file -Raw -Encoding utf8'              = 'a data file shipped with the module'
        'SizesNotRead.ps1|Get-Content -LiteralPath $file -Raw'                = 'a data file shipped with the module'
        'StorageApplianceDetection.ps1|Get-Content $file -Raw -Encoding utf8' = 'a data file shipped with the module'
        'StartGateWords.ps1|Get-Content $file -Raw -Encoding utf8'            = 'a data file shipped with the module'
        'StopReasons.ps1|Get-Content $file -Raw -Encoding utf8'               = 'a data file shipped with the module'
        'EntryClassification.ps1|Get-Content $file -Raw -Encoding utf8'       = 'a data file shipped with the module'
        'TargetFamilies.ps1|Get-Content $file -Raw -Encoding utf8'            = 'data/target-families.json, shipped with the module'
        'DriverReadiness.ps1|Get-Content $file -Raw -Encoding utf8'           = 'data/driver-floors.json, shipped with the module'
        'NvmeLinuxRelease.ps1|Get-Content $file -Raw -Encoding utf8'          = 'data/nvme-linux-releases.json, shipped with the module'
        'ReleaseEndOfLife.ps1|Get-Content $file -Raw -Encoding utf8'          = 'data/linux-release-eol.json, shipped with the module'
        'Disclaimer.ps1|Get-Content -LiteralPath $file -Raw'                  = 'a data file shipped with the module'
        'Permissions.ps1|Get-Content $file -Raw'                              = 'data/rbac-actions.json, shipped with the module'
        'Get-VmfGuestScript.ps1|Get-Content $manifestPath -Raw'               = 'src/guest/manifest.json, shipped with the module'
        'Get-VmfVersion.ps1|Get-Content -LiteralPath $stampPath -Raw'         = 'the build stamp, shipped with the module'
        'FacadeCore.psm1|[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Header))' = 'the sign-in principal header from App Service'
        'AzureOps.ps1|$body'                                                  = 'the body of an Azure error answer'
        'QuotaRequestAnswer.ps1|$Content'                                     = 'the Quota Request Status answer from Azure (Get-VmfQuotaRequestState), QUOTA-REQUEST-POLL-1'

        'AzureOpsToken.ps1|[System.Text.Encoding]::UTF8.GetString([byte[]]$answer.Content)' = 'the token answer from IDENTITY_ENDPOINT'
        'ConvertFrom-VmfGuestOutput.ps1|$t'                                   = 'the guest script output from RunCommand (guest-output, read at 12; checked below)'
    }

    # An HTTP answer read outside azureops and the web service: the file.
    $script:httpOutsideAzureOps = @('Request-VmfQuota.ps1')   # the quota request answer from Azure, through Invoke-VmfAzOperation

    function Script:Get-Arg($call, [string]$name) {
        for ($i = 0; $i -lt $call.CommandElements.Count; $i++) {
            $e = $call.CommandElements[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq $name) {
                if ($e.Argument) { return $e.Argument }
                if ($i + 1 -lt $call.CommandElements.Count) { return $call.CommandElements[$i + 1] }
            }
        }
        $null
    }
    # The -Depth of a ConvertFrom-Json or ConvertTo-Json: the number, the
    # cmdlet's own default when it gives none, $null when it is not a number.
    function Script:Get-Depth($call, [int]$default) {
        # A splatted call (ConvertFrom-Json @a) may give -Depth in the
        # hashtable: the gate cannot read it, so it is not a number.
        if (@($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted }).Count) { return $null }
        $d = Script:Get-Arg $call 'Depth'
        if (-not $d) { return $default }
        if ($d -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [int]$d.Value }
        $null
    }
    function Script:Get-Scope($node) {
        $n = $node.Parent
        while ($n -and -not (($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -or (($n -is [System.Management.Automation.Language.ScriptBlockAst]) -and ($null -eq $n.Parent)))) { $n = $n.Parent }
        $n
    }
    # The last assignment to a variable above a node, in the same function.
    function Script:Get-LastAssign($ast, [string]$var, $before) {
        $scope = Script:Get-Scope $before
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq $var -and $n.Extent.StartOffset -lt $before.Extent.StartOffset }, $true) |
            Where-Object { (Script:Get-Scope $_) -eq $scope }) | Select-Object -Last 1
    }
    # The loop that gives a foreach variable, above a node.
    function Script:Get-ForeachOf($var, $node) {
        $n = $node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq $var) { return $n }
            $n = $n.Parent
        }
        $null
    }
    # The text a ConvertFrom-Json reads: the element before it in its pipeline.
    function Script:Get-Input($call) {
        $pipe = $call.Parent
        if ($pipe -is [System.Management.Automation.Language.PipelineAst]) {
            $i = [array]::IndexOf(@($pipe.PipelineElements), $call)
            if ($i -gt 0) { return $pipe.PipelineElements[$i - 1] }
        }
        Script:Get-Arg $call 'InputObject'
    }
    # Follow an input back to where its text was made: through a variable's
    # last assignment, a foreach loop, $_ in a ForEach-Object, an index or a
    # property of a variable. Gives the expression that made the text, or the
    # variable it could not follow (a parameter).
    function Script:Resolve-Source($ast, $node, [int]$hops = 0) {
        if ($hops -gt 6 -or $null -eq $node) { return $node }
        $inner = $node
        if ($inner -is [System.Management.Automation.Language.CommandExpressionAst]) { $inner = $inner.Expression }
        while ($inner -is [System.Management.Automation.Language.ParenExpressionAst] -or $inner -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            $inner = if ($inner -is [System.Management.Automation.Language.ConvertExpressionAst]) { $inner.Child } else { $inner.Pipeline }
            if ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1) { $inner = $inner.PipelineElements[0] }
            if ($inner -is [System.Management.Automation.Language.CommandExpressionAst]) { $inner = $inner.Expression }
        }
        # A sort or a filter passes its input on: the element before it.
        if ($inner -is [System.Management.Automation.Language.CommandAst] -and $inner.GetCommandName() -in 'Sort-Object', 'Where-Object', 'Select-Object', '?') {
            return Script:Resolve-Source $ast (Script:Get-Input $inner) ($hops + 1)
        }
        # $texts[$i] is a text of $texts; $read.Text a text of $read. An
        # HTTP answer's .Content stays as it is: it names what the text is.
        while ($true) {
            if ($inner -is [System.Management.Automation.Language.IndexExpressionAst]) { $inner = $inner.Target; continue }
            if ($inner -is [System.Management.Automation.Language.MemberExpressionAst] -and $inner.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $inner.Member.Extent.Text -ne 'Content') { $inner = $inner.Expression; continue }
            break
        }
        if ($inner -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $var = $inner.VariablePath.UserPath
            if ($var -in '_', 'PSItem') {
                # $_ in a ForEach-Object: the element before that ForEach-Object.
                $n = $inner.Parent
                while ($n -and -not ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'ForEach-Object', '%')) { $n = $n.Parent }
                if ($n) { return Script:Resolve-Source $ast (Script:Get-Input $n) ($hops + 1) }
                return $inner
            }
            $loop = Script:Get-ForeachOf $var $inner
            if ($loop) { return Script:Resolve-Source $ast $loop.Condition ($hops + 1) }
            $last = Script:Get-LastAssign $ast $var $inner
            if ($last) { return Script:Resolve-Source $ast $last.Right ($hops + 1) }
        }
        $node
    }
    function Script:Get-KindOfPath([string]$pathText) {
        foreach ($k in $script:kindByPath.Keys) { if ($pathText -match $k) { return $script:kindByPath[$k] } }
        $null
    }
    # The document a reader call reads, from its path argument.
    function Script:Get-ReaderKind($ast, $call, [string]$pathParam) {
        $pathText = $call.Extent.Text
        if ($pathParam) {
            $pa = Script:Get-Arg $call $pathParam
            if ($pa) {
                $pathText = $pa.Extent.Text
                if ($pa -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $last = Script:Get-LastAssign $ast $pa.VariablePath.UserPath $call
                    if ($last) { $pathText = $last.Right.Extent.Text }
                }
                $key = '{0}|{1}' -f [System.IO.Path]::GetFileName($call.Extent.File), $pathText
                if ($script:pathByParameter.Contains($key)) { [void]$script:usedKeys.Add("path:$key"); return [pscustomobject]@{ Kind = $script:pathByParameter[$key]; PathText = $pathText } }
            }
        }
        [pscustomobject]@{ Kind = (Script:Get-KindOfPath $pathText); PathText = $pathText }
    }

    function Script:Get-JsonReads {
        $srcRoot = Join-Path $script:repoRoot 'src'
        foreach ($item in Get-ChildItem $srcRoot -Recurse -File -Include *.ps1, *.psm1) {
            if ($item.FullName -like (Join-Path $srcRoot 'guest' '*')) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$null, [ref]$null)
            # The JSON readers the read gate does not cover: a direct read too.
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $script:jsonReaders.Contains([string]$n.GetCommandName()) }, $true)) {
                $spec = $script:jsonReaders[$c.GetCommandName()]
                $named = Script:Get-ReaderKind $ast $c $spec.Path
                [pscustomobject]@{ Where = '{0}:{1}' -f $item.Name, $c.Extent.StartLineNumber; File = $item.Name; Class = 'read'
                    Kind = $named.Kind; From = $named.PathText; Depth = (Script:Get-Depth $c $spec.Default); WriteDepth = $null; Input = $c.Extent.Text }
            }
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertFrom-Json' }, $true)) {
                $where = '{0}:{1}' -f $item.Name, $c.Extent.StartLineNumber
                $depth = Script:Get-Depth $c 1024
                $inEl = Script:Get-Input $c
                $inputText = if ($inEl) { $inEl.Extent.Text } else { '' }
                $source = Script:Resolve-Source $ast $inEl
                $row = [pscustomobject]@{ Where = $where; File = $item.Name; Class = $null; Kind = $null; From = ''; Depth = $depth; WriteDepth = $null; Input = $inputText }
                # The store layer: it passes a caller's text and depth on.
                if ($script:passThrough.Contains($item.Name) -and $null -eq $depth) { $row.Class = 'pass'; $row; continue }

                # A copy: ConvertTo-Json made the text.
                $to = $null
                if ($source -is [System.Management.Automation.Language.CommandAst] -and $source.GetCommandName() -eq 'ConvertTo-Json') { $to = $source }
                elseif ($source) {
                    $tos = @($source.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-Json' }, $true))
                    $perItem = $source -is [System.Management.Automation.Language.CommandAst] -and $source.GetCommandName() -in 'ForEach-Object', '%'
                    if ($tos.Count -eq 1 -and ($perItem -or $source -isnot [System.Management.Automation.Language.CommandAst])) { $to = $tos[0] }
                }
                if ($to) {
                    $row.Class = 'copy'
                    $row.WriteDepth = Script:Get-Depth $to 2
                    $copied = Script:Get-Input $to
                    $copiedText = if ($copied) { $copied.Extent.Text } else { '' }
                    $row.From = $copiedText
                    $key = '{0}|{1}' -f $item.Name, $copiedText
                    if ($script:copyOf.Contains($key)) { $row.Kind = $script:copyOf[$key]; [void]$script:usedKeys.Add("copy:$key") }
                    $row; continue
                }
                # A direct read: a store text reader made the text.
                $readers = if ($source) { @($source.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $script:textReaders.Contains([string]$n.GetCommandName()) }, $true)) } else { @() }
                if ($source -is [System.Management.Automation.Language.CommandAst] -and $script:textReaders.Contains([string]$source.GetCommandName())) { $readers = @($source) }
                if ($readers.Count) {
                    $row.Class = 'read'
                    $named = Script:Get-ReaderKind $ast $readers[0] $script:textReaders[$readers[0].GetCommandName()]
                    $row.Kind = $named.Kind; $row.From = $named.PathText
                    $row; continue
                }
                $srcText = if ($source) { $source.Extent.Text } else { '' }
                $paramKey = '{0}|{1}' -f $item.Name, $srcText
                if ($script:kindByParameter.Contains($paramKey)) {
                    $row.Class = 'read'; $row.Kind = $script:kindByParameter[$paramKey]; $row.From = $srcText; [void]$script:usedKeys.Add("param:$paramKey")
                    $row; continue
                }
                # Not a store document: an HTTP answer, or a named text.
                if ($srcText -match '\.Content\b' -and $srcText -notmatch 'GetString') {
                    $row.Class = 'http'; $row.From = [System.IO.Path]::GetRelativePath($script:repoRoot, $item.FullName).Replace('\', '/'); $row; continue
                }
                foreach ($k in @("$($item.Name)|$srcText", "$($item.Name)|$inputText")) {
                    if ($script:notStore.Contains($k)) { $row.Class = 'other'; $row.From = $script:notStore[$k]; [void]$script:usedKeys.Add("other:$k"); break }
                }
                if (-not $row.Class) { $row.From = $srcText }
                $row
            }
        }
    }
    $script:usedKeys = [System.Collections.Generic.HashSet[string]]::new()
    $script:found = @(Script:Get-JsonReads)

    # How deep a part of a schema can nest: '<schema>' or '<schema>#<pointer>'.
    function Script:Get-PartDepthNeeded([string]$part) {
        $kind, $pointer = $part -split '#', 2
        if (-not $pointer) { return Script:Get-DocumentDepthNeeded $kind }
        $schema = Get-Content (Join-Path $script:schemaDir "$kind.schema.json") -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $node = $schema
        foreach ($step in $pointer.TrimStart('/').Split('/')) {
            while ($node.Contains('$ref')) {
                $ref = [string]$node['$ref']; $node = $schema
                foreach ($r in $ref.Substring(2).Split('/')) { $node = $node[$r] }
            }
            if (-not $node.Contains($step)) { throw "The schema $kind has no '$step' in $pointer" }
            $node = $node[$step]
        }
        $need = Script:Get-SchemaNesting $node $schema @()
        if ($need -ge 99) { return 24 }
        $need
    }
}

Describe 'COPY-DEPTH-GATE-1: every ConvertFrom-Json in src is traced' {
    It 'finds the reads and the copies (the scan is not empty)' {
        @($script:found | Where-Object Class -eq 'read').Count | Should -BeGreaterThan 40
        @($script:found | Where-Object Class -eq 'copy').Count | Should -BeGreaterOrEqual 9
        @($script:found | Where-Object { $_.Class -eq 'read' -and $_.Kind -eq 'lease' }).Count | Should -BeGreaterOrEqual 4
        @($script:found | Where-Object { $_.Class -eq 'read' -and $_.Kind -eq 'wave-schedule' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'traces the input of every ConvertFrom-Json, so a new one cannot slip past' {
        $unknown = @($script:found | Where-Object { -not $_.Class } | ForEach-Object { '{0} reads {1}' -f $_.Where, $_.From })
        $unknown | Should -BeNullOrEmpty -Because 'each input must trace to a store reader, a ConvertTo-Json, an HTTP answer, kindByParameter or notStore'
    }

    It 'names the document of every direct read and the part of every copy' {
        $unnamed = @($script:found | Where-Object { $_.Class -in 'read', 'copy' -and -not $_.Kind } | ForEach-Object { '{0} {1} of {2}' -f $_.Where, $_.Class, $_.From })
        $unnamed | Should -BeNullOrEmpty -Because 'a read maps through kindByPath (_StoreDocumentDepth.ps1) or kindByParameter, a copy through copyOf'
    }

    It 'takes an HTTP answer as one only where the Azure calls are' {
        # The azureops boundary (CLAUDE.md rule 3) and the web service, which
        # calls ARM itself. A store read over HTTP lives in StoreApi.ps1.
        $elsewhere = @($script:found | Where-Object { $_.Class -eq 'http' -and $_.From -notmatch '^src/VmMigrationFactory/Private/azureops/|^src/facade/' -and
                $_.File -notin $script:httpOutsideAzureOps } | ForEach-Object { '{0} ({1})' -f $_.Where, $_.Input })
        $elsewhere | Should -BeNullOrEmpty -Because 'a .Content outside azureops may be a store document: trace it, or name it in httpOutsideAzureOps'
    }

    It 'uses every line of its tables, so a line left after its code moved is seen' {
        $tables = @{ param = $script:kindByParameter; path = $script:pathByParameter; copy = $script:copyOf; other = $script:notStore }
        $stale = @(foreach ($t in $tables.Keys) { foreach ($k in $tables[$t].Keys) { if (-not $script:usedKeys.Contains("${t}:$k")) { "${t}: $k" } } })
        $stale | Should -BeNullOrEmpty
    }

    It 'gives a depth that is a number everywhere but the store layer' {
        $loose = @($script:found | Where-Object { $_.Class -in 'read', 'copy' -and ($null -eq $_.Depth -or ($_.Class -eq 'copy' -and $null -eq $_.WriteDepth)) } |
            ForEach-Object { '{0} {1}' -f $_.Where, $_.Input })
        $loose | Should -BeNullOrEmpty
    }
}

Describe 'COPY-DEPTH-GATE-1: every direct read and every copy fits its document' {
    It 'reads each store document directly with a depth at least as deep as its schema lets it nest' {
        $short = @(foreach ($r in @($script:found | Where-Object { $_.Class -eq 'read' -and $_.Kind -and $null -ne $_.Depth })) {
                $required = Script:Get-DocumentDepthNeeded $r.Kind
                if ($r.Depth -lt $required) { '{0} reads {1} at depth {2}; it needs {3}' -f $r.Where, $r.Kind, $r.Depth, $required }
            })
        $short | Should -BeNullOrEmpty
    }

    It 'copies each part with a write depth and a read depth that cover it' {
        $short = @(foreach ($c in @($script:found | Where-Object { $_.Class -eq 'copy' -and $_.Kind -and $null -ne $_.Depth -and $null -ne $_.WriteDepth })) {
                $required = Script:Get-PartDepthNeeded $c.Kind
                if ($c.WriteDepth -lt $required -or $c.Depth -lt $required) {
                    '{0} copies {1} ({2}) at ConvertTo-Json {3} and ConvertFrom-Json {4}; it needs {5}' -f $c.Where, $c.From, $c.Kind, $c.WriteDepth, $c.Depth, $required
                }
            })
        $short | Should -BeNullOrEmpty
    }

    It 'reads the guest output at a depth its schema fits in' {
        $guest = @($script:found | Where-Object { $_.File -eq 'ConvertFrom-VmfGuestOutput.ps1' -and $_.Class -eq 'other' })
        $guest.Count | Should -BeGreaterOrEqual 1
        $required = Script:Get-DocumentDepthNeeded 'guest-output'
        foreach ($g in $guest) { $g.Depth | Should -BeGreaterOrEqual $required -Because "$($g.Where) reads the guest output" }
    }

    It 'each JSON reader''s own default depth is the one the gate counts' {
        $defs = @{}
        foreach ($item in Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -File -Include *.ps1, *.psm1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($item.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $script:jsonReaders.Contains($n.Name) }, $true)) {
                $param = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Depth' })
                $defs[$fn.Name] = [int]$param[0].DefaultValue.Value
            }
        }
        foreach ($k in $script:jsonReaders.Keys) { $defs[$k] | Should -Be $script:jsonReaders[$k].Default -Because "$k reads with this depth when its caller gives none" }
    }
}

Describe 'COPY-DEPTH-GATE-1: the measure' {
    It 'measures the parts the item named' {
        Script:Get-PartDepthNeeded 'plan-entry#/properties/target' | Should -BeLessOrEqual 12 -Because 'the target copies take 12'
        Script:Get-DocumentDepthNeeded 'lease' | Should -Be 1
        Script:Get-DocumentDepthNeeded 'capacity-claim' | Should -BeLessOrEqual 12
    }

    It 'ConvertFrom-Json really throws on text deeper than its depth (the defect a direct read hides)' {
        $text = '{"a":{"b":{"c":1}}}'
        { $text | ConvertFrom-Json -Depth 2 } | Should -Throw
        ($text | ConvertFrom-Json -Depth 3).a.b.c | Should -Be 1
    }

    It 'a copy below its depth keeps the deeper part as its type name' {
        $copy = @{ a = @{ b = @{ c = 1 } } } | ConvertTo-Json -Depth 1 -WarningAction SilentlyContinue | ConvertFrom-Json -Depth 12
        [string]$copy.a.b | Should -Match 'System\.Collections'
    }
}
