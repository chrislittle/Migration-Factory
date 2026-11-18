#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REVIEW-UX-1 - the shared findings renderer, and the rule that makes it shared.
#
# The wizard's review step said "6 can migrate, 2 cannot" and showed neither
# why nor which. The Assessments page was poorly laid out too; the per-VM
# breakout on the run page (where you can roll back) is the model.
#
# One renderer, two callers. The trap a shared renderer falls into is depending
# on the CALLER's stylesheet: `assessment-report.js` first emitted the pages'
# own `.card`/`.cardbody`, which looked right on the Assessments page and ran
# every finding edge-to-edge in the wizard, because the wizard has `.card` but
# no `.cardbody`. A renderer that only looks right in one of its two homes is
# not shared - so it now carries its own classes AND their styles.
#
# The module is EXECUTED here under node with a minimal DOM, so these are
# claims about what it actually produces, not about what its source says.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:module   = Join-Path $script:repoRoot 'src' 'dashboard' 'assessment-report.js'
    $script:node     = Get-Command node -ErrorAction SilentlyContinue
    $script:hasNode  = $null -ne $script:node

    # Just enough DOM for the module to load and render. Deliberately NOT jsdom:
    # a fake this small proves the renderer needs nothing but a head to put a
    # <style> in, which is the property under test.
    function Global:Invoke-VmfReportJs {
        param([string]$Body)
        $harness = @"
const styles = [];
const head = { appendChild: (el) => styles.push(el.textContent || '') };
const made = [];
globalThis.document = {
  head,
  body: { appendChild: (el) => made.push(el) },
  createElement: (tag) => ({ tag, textContent: '', innerHTML: '', id: '',
    classList: { add: () => {}, remove: () => {} },
    setAttribute: () => {}, querySelector: () => ({ addEventListener: () => {}, innerHTML: '' }),
    addEventListener: () => {} }),
  getElementById: () => null,
  querySelectorAll: () => [],
  addEventListener: () => {},
};
globalThis.window = globalThis;
globalThis.fetch = () => Promise.reject(new Error('no network in a unit test'));
$(Get-Content $script:module -Raw)
const CSS = () => styles.join('\n');
$Body
"@
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-report-$([guid]::NewGuid().ToString('N').Substring(0,8)).mjs"
        try {
            Set-Content -LiteralPath $file -Value $harness -Encoding utf8
            $out = & $script:node $file 2>&1
            if ($LASTEXITCODE -ne 0) { throw "node exited $LASTEXITCODE`n$out" }
            ($out -join "`n")
        }
        finally { if (Test-Path $file) { Remove-Item $file -Force } }
    }

    $script:VMS = @'
const VMS = [
  { vmId: '/x/a', name: 'a', classification: 'Blocked', blockers: ['gen1-requires-redeploy'] },
  { vmId: '/x/b', name: 'b', classification: 'Blocked', blockers: ['gen1-requires-redeploy'] },
  { vmId: '/x/c', name: 'c', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme'] },
  { vmId: '/x/d', name: 'd', classification: 'Excluded', blockers: [] },
];
'@
}
AfterAll { Remove-Item 'function:\Invoke-VmfReportJs' -ErrorAction SilentlyContinue }

Describe 'REVIEW-UX-1: the shared report styles itself' {
    It 'every class it emits is one it also styles' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        # `.pill` and `.muted` are the two the pages genuinely share (they are on
        # every page and mean the same thing everywhere). Anything ELSE the
        # report invents must come with its own rule, or it renders unstyled in
        # whichever page did not happen to define it.
        $out = Invoke-VmfReportJs @"
$script:VMS
const html = window.VmfReport.findingsHtml(VMS, { showPrep: true });
const emitted = [...html.matchAll(/class="([^"]+)"/g)].flatMap(m => m[1].split(/\s+/)).filter(Boolean);
const css = CSS();
const shared = ['pill', 'muted', 'bad', 'warn', 'quiet', 'good'];
const unstyled = [...new Set(emitted)].filter(c => !shared.includes(c) && !css.includes('.' + c));
console.log(JSON.stringify({ emitted: [...new Set(emitted)], unstyled }));
"@
        $r = $out | ConvertFrom-Json
        $r.unstyled | Should -BeNullOrEmpty -Because "the report must carry the styles for what it emits; it emitted $($r.emitted -join ', ')"
    }

    It 'does not borrow the pages own card classes' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        # This is the exact regression: `.cardbody` exists on the Assessments
        # page and not in the wizard, so borrowing it gave findings no padding
        # in one of the two places the report is shown.
        $out = Invoke-VmfReportJs @"
$script:VMS
const html = window.VmfReport.findingsHtml(VMS, { showPrep: true });
const borrowed = [...html.matchAll(/class="([^"]+)"/g)]
  .flatMap(m => m[1].split(/\s+/))
  .filter(c => c === 'card' || c === 'cardbody');
console.log(JSON.stringify({ borrowed }));
"@
        ($out | ConvertFrom-Json).borrowed | Should -BeNullOrEmpty
    }

    It 'renders the findings a person needs: the reason, the count, and which machines' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $out = Invoke-VmfReportJs @"
$script:VMS
// No reasons file in a unit test - the CODES must still render, or a fetch
// failure turns the whole report into blank cards.
const html = window.VmfReport.findingsHtml(VMS, { showPrep: true });
console.log(JSON.stringify({
  code: html.includes('gen1-requires-redeploy'),
  grouped: html.includes('2 machines'),
  // VMNAMES-1: each name is its own chip now, so the check is that each one
  // is THERE and is its own element. It used to look for 'a, b' - the joined
  // string - which was the defect: twenty names in one run-on line.
  named: html.includes('class="vmf-chip">a</span>') && html.includes('class="vmf-chip">b</span>'),
  prep: html.includes('stornvme'),
  excluded: html.includes('d'),
}));
"@
        $r = $out | ConvertFrom-Json
        $r.code     | Should -BeTrue -Because 'a missing reasons file must not blank the report'
        $r.grouped  | Should -BeTrue -Because 'two machines blocked for one reason is ONE piece of work'
        $r.named    | Should -BeTrue -Because 'a person has to know WHICH machines'
        $r.prep     | Should -BeTrue
        $r.excluded | Should -BeTrue
    }

    It 'says something rather than nothing when a scan found no machines' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $out = Invoke-VmfReportJs @'
const html = window.VmfReport.findingsHtml([], {});
console.log(JSON.stringify({ len: html.length, text: html.replace(/<[^>]+>/g, '').trim() }));
'@
        $r = $out | ConvertFrom-Json
        $r.text | Should -Not -BeNullOrEmpty
    }

    It 'escapes machine names - they come off an assessment, not out of this file' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $out = Invoke-VmfReportJs @'
const html = window.VmfReport.findingsHtml(
  [{ vmId: '/x/evil', name: '<img src=x onerror=alert(1)>', classification: 'Blocked', blockers: ['<script>'] }], {});
console.log(JSON.stringify({ raw: html.includes('<img'), rawTag: html.includes('<script>'), esc: html.includes('&lt;img') }));
'@
        $r = $out | ConvertFrom-Json
        $r.raw    | Should -BeFalse
        $r.rawTag | Should -BeFalse
        $r.esc    | Should -BeTrue
    }
}

Describe 'REVIEW-UX-1: both pages use it' {
    It 'the wizard and the assessments page load the shared module' {
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        foreach ($f in @('wizard.html', 'assessments.html')) {
            $text = (Get-VmfPageSource -Path (Join-Path $dash $f))
            $text | Should -Match 'src="assessment-report\.js"' -Because "$f draws findings"
            $text | Should -Match 'VmfReport' -Because "$f must call the shared renderer, not its own"
        }
    }

    It 'and neither keeps a private copy of the renderer' {
        # A second copy is how this drifted the first time: the two had
        # different tone on the same card and a different section order.
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        foreach ($f in @('wizard.html', 'assessments.html')) {
            $text = (Get-VmfPageSource -Path (Join-Path $dash $f))
            $text | Should -Not -Match '(?m)^\s*(async\s+)?function\s+(groupByCode|reasonCard|loadReasons)\s*\(' `
                -Because "$f must call the shared renderer rather than redefining it"
        }
    }

    It 'the deploy ships it - a page that cannot load it renders nothing' {
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match "assessment-report\.js" -Because 'the wizard destructures window.VmfReport at parse time'
    }
}

Describe 'IDENTITY-4: the finding says the risk, and carries no research' {
    # What stood here drew the "Where is it used?" answer - a panel listing
    # what a machine's system-assigned identity could reach. It is gone.
    #
    # Since 2026-09-11, the product does not look for every dependency on a
    # system-assigned managed identity in a temp-disk move. It states the risk,
    # and the customer approves it and assesses the impact.
    #
    # This RUNS the renderer, so it measures what the page draws rather than
    # what its source says.
    # OLD-VERSION-READERS-REMOVE-6: the scan gives no retired finding code
    # (REBUILD-REMOVE-PLAN-1 removed system-identity-recreated, and nothing is
    # public before 1.0), so the report keeps no list of codes to drop. Each
    # finding the scan gives has its words in assessment-reasons.json.
    It 'the report keeps no list of retired finding codes, and every code the scan can give has its words' {
        $code = Get-VmfCodeOnly -Path $script:module -Language CStyle
        $code | Should -Not -Match 'RETIRED_CODES|system-identity-recreated'
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        foreach ($group in 'blockers', 'prep', 'warnings') {
            $reasons.$group.PSObject.Properties['system-identity-recreated'] | Should -BeNullOrEmpty -Because $group
        }
    }

    It 'a machine with a system-assigned identity: the object ID is never published on an assessment page' {
        if (-not $script:hasNode) { Set-ItResult -Skipped -Because 'node is not installed'; return }
        $out = Invoke-VmfReportJs @"
const vms = [{ vmId: '/x/a', name: 'a', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['pagefile'], warnings: [],
  identityType: 'SystemAssigned', identityPrincipalId: '11111111-2222-3333-4444-555555555555' }];
const html = window.VmfReport.findingsHtml(vms, { showPrep: true });
console.log(JSON.stringify({ html, cards: (html.match(/class="vmf-finding"/g) ?? []).length }));
"@
        $r = $out | ConvertFrom-Json
        $r.cards | Should -Be 1 -Because 'one card, for the page file'
        $r.html | Should -Not -Match '11111111-2222-3333-4444-555555555555'
    }
}