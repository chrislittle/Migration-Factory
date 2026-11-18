#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-CALLS-QUERY-1, 2026-11-11. Found by FINAL-LAB-PREP-1 on the lab
# installation.
#
# THE MANUAL'S QUERY FOR THE SERVICE'S CALL TIMES GAVE NO ROWS.
#
#     traces | where message startswith "VMF-CALLS "
#            | extend j = parse_json(substring(message, 10))
#
# On an installation the Functions host puts the level of the stream in front
# of each line the service writes: `INFORMATION: VMF-CALLS {...}`, and
# `WARNING: schedule: ...` for Write-Warning. So `startswith` keeps no line,
# and a fixed offset of 10 does not land on the JSON. The lab's own queries
# (tests/lab/_InstallReading.ps1) use `message has "VMF-CALLS "` and
# `substring(message, indexof(message, "{"))`, and they found 806 lines in the
# same 2 days.
#
# THE RULE: no query the manual (or an open work item) gives may use
# `startswith` on a line the service writes. The lines are read from the
# service's own code - every Write-Host, Write-Warning, Write-Information and
# Write-VmfCallTimingLine in src/facade/app and the call timing code - so a new
# line is covered without a list to keep.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

    # The literal start of each line the service writes to Application
    # Insights: the text before the first variable or format hole.
    $sources = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Recurse -Filter '*.ps1') +
        @(Get-Item (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'CallTimings.ps1'))
    $writers = @('Write-Host', 'Write-Warning', 'Write-Information', 'Write-VmfCallTimingLine')
    $leads = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $sources) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $writers }, $true)
        foreach ($call in $calls) {
            $first = $call.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord') -or
                    $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | Select-Object -First 1
            if (-not $first) { continue }
            $lead = ([string]$first.Value) -replace '[\$\{].*$', ''
            if ($lead.Trim().Length -ge 3) { $leads.Add($lead) }
        }
    }
    $script:serviceLeads = @($leads | Sort-Object -Unique)

    # Every query the manual gives: each fenced kusto block.
    $script:manualQueries = [System.Collections.Generic.List[object]]::new()
    foreach ($page in Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter '*.md') {
        $text = Get-Content -LiteralPath $page.FullName -Raw
        foreach ($m in [regex]::Matches($text, '(?ms)^```kusto\s*$(.*?)^```')) {
            $script:manualQueries.Add([pscustomobject]@{ Page = $page.Name; Query = $m.Groups[1].Value })
        }
    }

    # Every query text an OPEN work item gives: a line with `message startswith`.
    $script:itemLines = [System.Collections.Generic.List[object]]::new()
    # PUBLIC-SYNC-1: the work items do not ship to the public repository.
    $items = Join-Path $script:repoRoot 'docs' 'backlog'
    foreach ($item in @(if (Test-Path $items) { Get-ChildItem $items -Filter '*.md' })) {
        $text = Get-Content -LiteralPath $item.FullName -Raw
        if ($text -notmatch '\*\*OPEN\.\*\*') { continue }
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match 'message\s+startswith') { $script:itemLines.Add([pscustomobject]@{ Page = $item.Name; Query = $line }) }
        }
    }

    function Get-VmfServiceLineStartsWith {
        # The `startswith` texts in a query that a line the service writes
        # could match, if the line had no level word in front of it.
        param([string]$Query, [string[]]$Leads)
        foreach ($m in [regex]::Matches($Query, 'startswith(?:_cs)?\s+"([^"]*)"')) {
            $wanted = $m.Groups[1].Value
            if ($wanted.Length -eq 0) { continue }
            foreach ($lead in $Leads) {
                if ($lead.StartsWith($wanted, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $wanted.StartsWith($lead, [System.StringComparison]::OrdinalIgnoreCase)) { $wanted; break }
            }
        }
    }
}

Describe 'MANUAL-CALLS-QUERY-1: the queries find the lines the service writes' {

    It 'reads the lines the service writes, so this cannot pass by reading nothing' {
        $script:serviceLeads | Should -Contain 'VMF-CALLS '
        @($script:serviceLeads | Where-Object { $_ -like 'VMF start-up:*' }).Count | Should -BeGreaterThan 0
        @($script:serviceLeads | Where-Object { $_ -like 'retention: *' }).Count | Should -BeGreaterThan 0
        @($script:serviceLeads | Where-Object { $_ -like 'schedule: *' }).Count | Should -BeGreaterThan 0
    }

    It 'finds the query for the service''s call times in the manual' {
        @($script:manualQueries | Where-Object { $_.Query -match 'VMF-CALLS' }).Count | Should -BeGreaterThan 0
    }

    It 'the check finds a startswith on a line the service writes' {
        # The form that gave no rows on the lab installation.
        @(Get-VmfServiceLineStartsWith -Query 'traces | where message startswith "VMF-CALLS "' -Leads $script:serviceLeads) | Should -Be @('VMF-CALLS ')
        @(Get-VmfServiceLineStartsWith -Query 'traces | where message startswith "schedule:"' -Leads $script:serviceLeads) | Should -Be @('schedule:')
        # A line the Functions host writes itself has no level word.
        @(Get-VmfServiceLineStartsWith -Query 'traces | where message startswith "Executing ''Functions."' -Leads $script:serviceLeads).Count | Should -Be 0
    }

    It 'no query in the manual uses startswith on a line the service writes' {
        $found = foreach ($q in $script:manualQueries) {
            foreach ($w in @(Get-VmfServiceLineStartsWith -Query $q.Query -Leads $script:serviceLeads)) { '{0}: startswith "{1}"' -f $q.Page, $w }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'no open work item gives a query with startswith on a line the service writes' {
        $found = foreach ($q in $script:itemLines) {
            foreach ($w in @(Get-VmfServiceLineStartsWith -Query $q.Query -Leads $script:serviceLeads)) { '{0}: startswith "{1}"' -f $q.Page, $w }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'no query in the manual reads a line at a fixed offset' {
        # The level word moves the JSON: read it from the first brace.
        $found = @($script:manualQueries | Where-Object { $_.Query -match 'substring\(\s*message\s*,\s*\d' } | ForEach-Object Page)
        $found | Should -BeNullOrEmpty
    }

    It 'the call times query finds the marker anywhere in the line and reads the JSON from its first brace' {
        $q = @($script:manualQueries | Where-Object { $_.Query -match 'VMF-CALLS' })[0].Query
        $q | Should -Match 'message\s+has\s+"VMF-CALLS "'
        $q | Should -Match 'parse_json\(\s*substring\(\s*message\s*,\s*indexof\(\s*message\s*,\s*"\{"\s*\)\s*\)\s*\)'
    }
}
