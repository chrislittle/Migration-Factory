#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LAB-AZ-QUERY-1: no PowerShell script in tests/lab, tools or lab passes az a
# --query that the az.cmd shim breaks on Windows.
#   * a double quote inside the query: az.cmd drops it. MEASURED 2026-11-05,
#     Session A: `--query 'tags."vmf-lab"'` reached az as tags.vmf-lab and
#     failed ("invalid jmespath_type value"), so four drills could not read
#     their own group's tag back;
#   * a [? filter: cmd eats it (CLAUDE.md, 2026-08-30), and what comes back is
#     an error string a script then takes as a value.
# Read the json and filter in PowerShell instead. Plain projections and an
# index like [0] are fine. Code only: a comment that explains the trap is not
# a call (Get-VmfCodeOnly, then the PowerShell parser).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # Each --query value a script passes, as the PowerShell parser reads it.
    function Global:AqQueries([string]$Code) {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$t, [ref]$e)
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $el = @($cmd.CommandElements)
            for ($i = 0; $i -lt $el.Count - 1; $i++) {
                if ($el[$i].Extent.Text -ne '--query') { continue }
                $next = $el[$i + 1]
                $value = if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                             $next -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { [string]$next.Value }
                         else { $next.Extent.Text }
                [pscustomobject]@{ Value = $value }
            }
        }
    }
    function Global:AqBroken([string]$Value) { $Value.Contains('"') -or $Value.Contains('[?') }

    # A script that runs on a Windows PC, where az is az.cmd.
    # PUBLIC-SYNC-1: lab/ and tests/lab do not ship to the public repository;
    # there tools is read. tools must be here.
    $script:hasLab = Test-Path (Join-Path $script:repoRoot 'lab')
    $script:files = foreach ($dir in 'tests/lab', 'tools', 'lab') {
        if ($dir -eq 'tools' -or (Test-Path (Join-Path $script:repoRoot $dir))) {
            Get-ChildItem (Join-Path $script:repoRoot $dir) -Recurse -File -Filter *.ps1
        }
    }
    # A known break, each tracked as its own item. Each entry must still be
    # there, so a fix removes the exemption too.
    # GRANT-QUERY-SHIM-1 fixed the last one (tools/Grant-VmfAccess.ps1).
    $script:exempt = @()
}

AfterAll { Remove-Item 'function:\AqQueries', 'function:\AqBroken' -ErrorAction SilentlyContinue }

Describe 'LAB-AZ-QUERY-1: the reader finds what az would be given' {
    It 'finds a double quote and a filter, and passes a projection or an index' {
        $found = @(AqQueries @'
$a = az group show -n $g --query 'tags."vmf-lab"' -o tsv
$b = az ad app list --query 'value[?displayName==`x`].appId' -o tsv
$c = az vm show -g $g -n $n --query hardwareProfile.vmSize -o tsv
$d = az vm get-instance-view -g $g -n $n `
    --query "instanceView.vmAgent.statuses[0].displayStatus" -o tsv
'@)
        $found.Count | Should -Be 4
        @($found | Where-Object { AqBroken $_.Value }).Count | Should -Be 2
        $found[3].Value | Should -Be 'instanceView.vmAgent.statuses[0].displayStatus'
    }
    It 'reads code only: a comment that names the trap is no call' {
        $code = Get-VmfCodeOnly -Language PowerShell -Text @'
# never: az group show --query 'tags."vmf-lab"'
$tag = (az group show -n $g -o json | ConvertFrom-Json).tags.'vmf-lab' # not --query 'tags[?x]'
'@
        @(AqQueries $code).Count | Should -Be 0
    }
}

Describe 'LAB-AZ-QUERY-1: no script gives az a --query the shim breaks' {
    It 'checks the scripts in tests/lab, tools and lab' {
        # tools alone holds about 30 scripts; with the lab, more than 50.
        @($script:files).Count | Should -BeGreaterThan $(if ($script:hasLab) { 50 } else { 20 })
    }
    It 'has no double quote and no [? filter in any --query' {
        $bad = foreach ($f in $script:files) {
            $rel = [System.IO.Path]::GetRelativePath($script:repoRoot, $f.FullName).Replace('\', '/')
            foreach ($q in @(AqQueries (Get-VmfCodeOnly -Path $f.FullName))) {
                if (-not (AqBroken $q.Value)) { continue }
                if ($script:exempt | Where-Object { $_.File -eq $rel -and $_.Value -eq $q.Value }) { continue }
                "${rel}: --query $($q.Value)"
            }
        }
        @($bad) | Should -BeNullOrEmpty -Because 'az.cmd drops a double quote and cmd eats [? - read -o json and filter in PowerShell'
    }
    It 'every exemption is still there, and names an item file' {
        foreach ($x in $script:exempt) {
            $values = @(AqQueries (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $x.File))).Value
            $values | Should -Contain $x.Value -Because "$($x.File) was fixed: remove its exemption"
            @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'backlog') -Filter "$($x.Item.ToLowerInvariant())-*.md").Count | Should -Be 1
        }
    }
}
