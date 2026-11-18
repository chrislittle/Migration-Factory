#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WHERE-1 - "where it looked" must not read as a bigger scan than it was.
#
# Seen on a scan of one resource group: it read like a scan of the whole
# subscription. The group is in that subscription, so it was not false, but the
# words must be clear that the scope was one resource group inside it.
#
# The cell said "1 subscription, rg-vmf-uxtest" - every level of the scope
# joined with commas, so one resource group read as two separate things scanned.
# That is not cosmetic: a whole-subscription scan and a one-group scan differ by
# hundreds of machines, and the operator's next decision is whether the numbers
# in that row are the whole estate.
#
# The rule, on both pages that show a scope: the NARROWEST level is WHAT was
# scanned; wider levels are WHERE it sits, and read as context.
#
# These tests EXECUTE the real functions out of the shipped pages - lifted by
# name, never re-typed - so a page that changes its wording either keeps the
# rule or fails here.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:node     = Get-Command node -ErrorAction SilentlyContinue

    # Pull one named function out of a page, braces balanced.
    function Global:Get-VmfJsFunction {
        param([string]$File, [string]$Name)
        $text = (Get-VmfPageSource -Path $File)
        $start = $text.IndexOf("function $Name(")
        if ($start -lt 0) { throw "function $Name not found in $File - was it renamed?" }
        $i = $text.IndexOf('{', $start); $depth = 0
        for ($j = $i; $j -lt $text.Length; $j++) {
            if ($text[$j] -eq '{') { $depth++ }
            elseif ($text[$j] -eq '}') { $depth--; if ($depth -eq 0) { return $text.Substring($start, $j - $start + 1) } }
        }
        throw "unbalanced braces reading $Name from $File"
    }
    function Global:Get-VmfUxBlock {
        param([string]$File)
        $text = (Get-VmfPageSource -Path $File)
        if ($text -notmatch '(?s)const UX = \{(.*?)\r?\n\};') { throw "no UX block in $File" }
        "const UX = {$($Matches[1])`n};"
    }
    function Global:Invoke-VmfJs {
        param([string]$Script)
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scope-$([guid]::NewGuid().ToString('N').Substring(0,8)).mjs"
        try {
            Set-Content -LiteralPath $file -Value $Script -Encoding utf8
            $out = & $script:node $file 2>&1
            if ($LASTEXITCODE -ne 0) { throw "node exited $LASTEXITCODE`n$out" }
            ($out -join "`n")
        }
        finally { if (Test-Path $file) { Remove-Item $file -Force } }
    }
}
AfterAll {
    Remove-Item 'function:\Get-VmfJsFunction', 'function:\Get-VmfUxBlock', 'function:\Invoke-VmfJs' -ErrorAction SilentlyContinue
}

Describe 'WHERE-1: the assessments page' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:file = Join-Path $script:dash 'assessments.html'
        # SCOPE-NAME-1: scopeText now resolves ids to names through two const
        # helpers that read a page-level `scopes`. Lifted from the page by
        # pattern (they are arrows, not `function`s), never re-typed, so a page
        # that changes them changes this. `scopes` starts null, exactly as it
        # does on the page before the facade answers - so every case below
        # that asserts on the id is asserting the FALLBACK, which is what a
        # viewer sees for the first second and for ever if the facade is down.
        $pageText = Get-VmfPageSource -Path $script:file
        $helpers = @([regex]::Matches($pageText, '(?m)^const (subName|mgName) = \(id\) =>.*$') | ForEach-Object { $_.Value })
        if ($helpers.Count -ne 2) { throw "expected subName and mgName on the page, found $($helpers.Count)" }
        $script:harness = @(
            (Get-VmfUxBlock -File $script:file)
            'const esc = (v) => String(v ?? "");'
            'let scopes = null;'
            $helpers
            (Get-VmfJsFunction -File $script:file -Name 'scopeText')
            # PAGE-SCALE-ASSESSMENTS-1: the list has no scope column now; the
            # report's line says where the scan looked (scopeLineHtml).
            (Get-VmfJsFunction -File $script:file -Name 'scopeLineHtml')
            'const lineOf = (scope) => scopeLineHtml({ scope });'
        ) -join "`n"
        $script:SUB = '11111111-2222-3333-4444-555555555555'
        $script:hasNode = $null -ne $script:node
    }

    It 'a resource-group scan does NOT claim a subscription was scanned' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $r = Invoke-VmfJs @"
$script:harness
console.log(lineOf(({ subscriptions: ['$script:SUB'], resourceGroups: ['rg-vmf-uxtest'], managementGroup: null })));
"@
        $r | Should -BeLike '*rg-vmf-uxtest*' -Because 'the group is what was scanned'
        $r | Should -BeLike "*$script:SUB*"   -Because 'the reader must see which subscription it sits in'
        $r | Should -Match '(?i)in subscription' -Because 'the subscription must read as WHERE, not as a second target'
        $r | Should -Not -Match '1 subscription,' -Because 'that is the exact string that misread'
    }

    It 'a subscription-wide scan says so plainly' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $r = Invoke-VmfJs @"
$script:harness
console.log(lineOf(({ subscriptions: ['$script:SUB'], resourceGroups: [], managementGroup: null })));
"@
        $r | Should -Match '(?i)whole subscription' -Because 'this one really did scan everything in the subscription'
        $r | Should -BeLike "*$script:SUB*"
    }

    It 'the narrow and the wide scan read differently - the entire point' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $r = Invoke-VmfJs @"
$script:harness
const rg   = scopeText({ subscriptions: ['$script:SUB'], resourceGroups: ['rg-one'], managementGroup: null });
const wide = scopeText({ subscriptions: ['$script:SUB'], resourceGroups: [], managementGroup: null });
console.log(JSON.stringify({ same: rg.what === wide.what }));
"@
        ($r | ConvertFrom-Json).same | Should -BeFalse
    }

    It 'SCOPE-NAME-1: once /scopes has answered, the subscription reads by NAME, and the id stays on hover' {
        # Seen on screen: the wizard said "inside subscription
        # Contoso-Prod"; this page said the GUID. Executed, not grepped: same
        # scope, scopes populated, the cell must carry the name and the tooltip
        # must still carry the id - a name is for reading, an id is for finding.
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $r = Invoke-VmfJs @"
$script:harness
scopes = { subscriptions: [{ id: '$script:SUB', name: 'Contoso-Prod' }], managementGroups: [] };
const rg = lineOf(({ subscriptions: ['$script:SUB'], resourceGroups: ['rg-vmf-lab'], managementGroup: null }));
const wide = scopeText({ subscriptions: ['$script:SUB'], resourceGroups: [], managementGroup: null });
console.log(JSON.stringify({ rg, wideWhere: wide.where, wideFull: wide.full }));
"@
        $o = $r | ConvertFrom-Json
        $o.rg        | Should -Match 'in subscription Contoso-Prod' -Because 'the name, once known'
        $o.rg        | Should -Not -Match $script:SUB             -Because 'the cell no longer prints the GUID'
        $o.wideWhere | Should -Be 'Contoso-Prod'
        $o.wideFull  | Should -BeLike "*$script:SUB*"             -Because 'the id is kept where a finder needs it'
    }

    It 'no scope at all still says something a person can read' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $r = Invoke-VmfJs @"
$script:harness
console.log(lineOf((null)));
console.log(lineOf(({ subscriptions: [], resourceGroups: [], managementGroup: null })));
"@
        $r.Trim() | Should -Not -BeNullOrEmpty
        $r | Should -Not -Match '(?i)undefined|NaN|\[object'
    }

    It 'escapes everything it renders - scope values come off a run manifest' {
        # A resource group name cannot carry a bracket, but this cell also
        # renders a management group name and a subscription id read from
        # storage. Assert the cell ROUTES through esc rather than interpolating.
        $src = Get-VmfJsFunction -File $script:file -Name 'scopeLineHtml'
        $bare = [regex]::Matches($src, '\$\{\s*(?!esc\()') | ForEach-Object { $_.Value }
        $bare | Should -BeNullOrEmpty -Because 'every interpolation in the cell must be escaped'
    }
}

Describe 'WHERE-1: the wizard says it the same way' {
    It 'does not flatten resource groups and subscriptions into one list' {
        # The wizard shows the scope when a scan found NOTHING - exactly when a
        # person asks "did it look in the right place?" - so it must not answer
        # with the same ambiguity.
        $src = Get-VmfJsFunction -File (Join-Path $script:dash 'wizard.html') -Name 'scopeSummary'
        $src | Should -Not -Match 'bits\.push\(\.\.\.sc\.resourceGroups\)' -Because 'that was the flattening'
        $src | Should -Match 's2NoneIn|s2NoneWholeSub' -Because 'it must tell inside-a-subscription from the whole thing'
    }

    It 'a group scan does not read as a subscription scan there either' {
        if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'node is not installed'; return
        }
        # Run the real function with the page state it reads stubbed around it.
        $wiz = Join-Path $script:dash 'wizard.html'
        $harness = @(
            (Get-VmfUxBlock -File $wiz)
            'const esc = (v) => String(v ?? "");'
            "const scopes = { subscriptions: [{ id: 'sub-1', name: 'Contoso lab' }] };"
            'let assessment = null;'
            (Get-VmfJsFunction -File $wiz -Name 'scopeSummary')
        ) -join "`n"

        $out = Invoke-VmfJs @"
$harness
assessment = { scope: { subscriptions: ['sub-1'], resourceGroups: ['rg-vmf-uxtest'], managementGroup: null } };
console.log('NARROW ' + scopeSummary());
assessment = { scope: { subscriptions: ['sub-1'], resourceGroups: [], managementGroup: null } };
console.log('WIDE ' + scopeSummary());
"@
        $narrow = ($out -split "`n" | Where-Object { $_ -like 'NARROW*' }) -join ''
        $wide   = ($out -split "`n" | Where-Object { $_ -like 'WIDE*'   }) -join ''

        $narrow | Should -BeLike '*rg-vmf-uxtest*'
        $narrow | Should -Match '(?i)inside subscription' -Because 'the subscription is where the group SITS'
        $wide   | Should -Match '(?i)whole subscription'  -Because 'that one really did scan the lot'
        # The two must not say the same thing - the failure this whole item is about.
        ($narrow -replace '^NARROW ') | Should -Not -Be ($wide -replace '^WIDE ')
    }
}
