# VERIFY-FP-1 part 3b: the report, as chosen on 2026-09-28
# ("Style A"): a cover with the product's mark and name, then facts in tables -
# results, the moves grouped by size and method, every machine with its
# evidence, the exceptions, and the sign-off. No narrative and no subtitle that
# assumes one kind of move: a run can hold dozens of configurations. It must
# read as a report, not as a block of prose.
#
# Rendered from the migration record (ConvertTo-VmfMigrationRecord), so the
# report and the kept record say the same thing. Pure: no store, no Azure.
#
# The report opens in a sandboxed frame with no script (SEC-REPORT-1) and is
# downloaded as one file, so everything is inline and nothing runs: the
# evidence folds with the browser's own <details>. Every value from the store
# goes through Encode.
#
# REPORT-THEME-1 (issue 426): light and dark, as the dashboard has them, and
# the same three states. The frame runs no script, so the report cannot read
# the person's choice - the page that opens it writes it on the root element:
#   data-theme="light"           light
#   data-theme="dark"            dark
#   no mark                      the operating system decides
# REPORT-AUTO-1 (2026-10-02, reversing REPORT-THEME-1's light print and
# downloads): the person's theme is honoured everywhere. A print follows the
# theme the document shows; the stored report has no mark, because no person
# wrote it; a record download is marked with the theme the person sees when
# they save it. A browser leaves backgrounds out of a print by default, which
# turns light text on a dark ground into white on white - so print asks for
# the colours exactly as shown (review 2). Each palette is written ONCE, here,
# and emitted where
# the cascade needs it; the values are app.css's own, and
# ReportTheme.Tests.ps1 holds them equal. Every rule below the token blocks
# reads a token, so a palette reaches all of it. This one stylesheet is also
# the migration record's (the service gives it to the Reports page).

$script:VmfReportLight = '--bg:#f8f9fa;--card:#ffffff;--card-2:#eeeeee;--line:#dee2e6;--nav:#446e9b;--ink:#2d2d2d;--body:#495057;--muted:#6c6c6c;--quiet-on:#5f5f5f;
--brand:#446e9b;--brand-soft:#dae2eb;--brand-on:#1b2c3e;--good-soft:#d8f0d3;--good-on:#18480d;--warn-soft:#f6e3cc;--warn-on:#552f00;
--bad-soft:#f5cccc;--bad-on:#520100;--on-nav:#ffffff;--on-nav-dim:rgba(255,255,255,.90);--on-nav-line:rgba(255,255,255,.22);color-scheme:light;'
# --quiet-on: --muted on --card-2 is 4.46 on the dark ground, under the floor;
# app.css made the same token for the same chip.
$script:VmfReportDark = '--bg:#222222;--card:#303030;--card-2:#3a3a3a;--line:#444444;--nav:#375a7f;--ink:#ffffff;--body:#dee2e6;--muted:#9aa4b0;--quiet-on:#adb6bf;
--brand:#759bc3;--brand-soft:#31363b;--brand-on:#7ea1c7;--good-soft:#29443d;--good-on:#00c291;--warn-soft:#4b3f2c;--warn-on:#f39c12;
--bad-soft:#4a3432;--bad-on:#ef867c;--on-nav:#ffffff;--on-nav-dim:rgba(255,255,255,.92);--on-nav-line:rgba(255,255,255,.22);color-scheme:dark;'

$script:VmfReportCss = @"
:root{--font:'Segoe UI',-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif;--mono:Consolas,'Cascadia Mono',ui-monospace,monospace;}
:root,:root[data-theme="light"]{$script:VmfReportLight}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){$script:VmfReportDark}}
:root[data-theme="dark"]{$script:VmfReportDark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--body);font-family:var(--font);font-size:14px;line-height:1.45;}
.sheet{max-width:1000px;margin:0 auto;padding:24px 16px 48px;}
.cover{background:var(--nav);color:var(--on-nav);border-radius:10px;padding:24px 28px;display:grid;gap:16px;}
.brandline{display:flex;align-items:center;gap:10px;font-weight:600;color:var(--on-nav-dim);font-size:13px;}
.brandline svg{width:26px;height:26px;color:var(--on-nav);}
.cover h1{margin:0;font-size:28px;color:var(--on-nav);font-weight:600;}
.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px 24px;border-top:1px solid var(--on-nav-line);padding-top:14px;margin:0;}
.meta dt{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--on-nav-dim);}
.meta dd{margin:2px 0 0;color:var(--on-nav);font-weight:600;overflow-wrap:anywhere;}
section{margin-top:30px;}
h2{color:var(--ink);font-size:17px;margin:30px 0 10px;display:flex;align-items:baseline;gap:10px;}
h2 .no{font-family:var(--mono);color:var(--brand);font-size:13px;}
h3{color:var(--ink);font-size:14px;margin:18px 0 8px;}
h4{color:var(--ink);font-size:13px;margin:14px 0 6px;}
p{max-width:75ch;}
.box{background:var(--card);border:1px solid var(--line);border-radius:8px;overflow-x:auto;}
table{border-collapse:collapse;width:100%;font-size:13px;background:var(--card);}
th{text-align:left;font-size:10.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:600;padding:8px 12px;border-bottom:1px solid var(--line);}
td{padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top;}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;}
.mono{font-family:var(--mono);font-size:12.5px;color:var(--ink);}
.nm{font-family:var(--mono);font-weight:600;color:var(--ink);white-space:nowrap;}
.os{color:var(--muted);font-size:12px;}
.arr{color:var(--brand);padding:0 4px;}
.pill{display:inline-block;font-size:11.5px;font-weight:700;border-radius:999px;padding:2px 10px;white-space:nowrap;}
.pill.good,.pill.ok{background:var(--good-soft);color:var(--good-on);}.pill.warn{background:var(--warn-soft);color:var(--warn-on);}
.pill.bad{background:var(--bad-soft);color:var(--bad-on);}.pill.info{background:var(--brand-soft);color:var(--brand-on);}
.pill.quiet{background:var(--card-2);color:var(--quiet-on);}
.results{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));}
.res{padding:12px 16px;border-right:1px solid var(--line);}.res:last-child{border-right:0;}
.res b{display:block;font-size:26px;color:var(--ink);font-variant-numeric:tabular-nums;}
.res span{font-size:12px;color:var(--muted);}
tr.wave td{background:var(--card-2);color:var(--ink);font-weight:600;font-size:12.5px;}
tr.wave .w{color:var(--quiet-on);font-weight:400;margin-left:8px;}
tr.evrow td{padding:0 12px 10px 28px;}
summary{cursor:pointer;color:var(--brand);font-weight:600;font-size:12.5px;padding:4px 0;}
.ev{margin-top:6px;border:1px solid var(--line);border-radius:6px;overflow-x:auto;}
.ev table{font-size:12.5px;}.ev td,.ev th{padding:5px 10px;}
.ev tr.grp td{background:var(--card-2);font-weight:600;color:var(--ink);font-size:11.5px;}
.ev td.v{font-family:var(--mono);font-size:12px;color:var(--ink);overflow-wrap:anywhere;}
.key,.muted{font-size:12px;color:var(--muted);}
.foot{margin-top:36px;padding-top:12px;border-top:1px solid var(--line);font-size:12px;color:var(--muted);display:flex;flex-wrap:wrap;gap:6px 18px;justify-content:space-between;}
.disclaimer{margin:8px 0 0;font-size:12px;color:var(--muted);}
@media print{:root{print-color-adjust:exact;-webkit-print-color-adjust:exact}body{background:var(--card)}.box{break-inside:avoid}.box{overflow:visible}td{overflow-wrap:anywhere}details{display:block}}
"@

function Get-VmfReportLook {
    <#
    .SYNOPSIS
        REPORT-THEME-1: the report's stylesheet and its mark - the same text
        the report carries, for the migration record the Reports page saves.
        One copy of the look: the service returns this (GET report-style).
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{ stylesheet = $script:VmfReportCss; logo = $script:VmfReportLogo }
}

# LOGO-SERVERS-1: the mark of src/dashboard/mark.svg, STILL - a report is a
# document, so the motion hooks (class, pathLength) are left out. The module
# ships without the dashboard folder, so it holds this copy; Brand.Tests.ps1
# derives the expected text from mark.svg, so the two cannot drift.
$script:VmfReportLogo = '<svg viewBox="0 0 32 32" aria-hidden="true"><g fill="currentColor"><g opacity=".55"><path fill-rule="evenodd" d="M4.1 4.4H16.1A1.5 1.5 0 0 1 17.6 5.9V9.5A1.5 1.5 0 0 1 16.1 11H4.1A1.5 1.5 0 0 1 2.6 9.5V5.9A1.5 1.5 0 0 1 4.1 4.4ZM4.9 6H5.5A0.5 0.5 0 0 1 6 6.5V8.9A0.5 0.5 0 0 1 5.5 9.4H4.9A0.5 0.5 0 0 1 4.4 8.9V6.5A0.5 0.5 0 0 1 4.9 6ZM7.5 6H8.1A0.5 0.5 0 0 1 8.6 6.5V8.9A0.5 0.5 0 0 1 8.1 9.4H7.5A0.5 0.5 0 0 1 7 8.9V6.5A0.5 0.5 0 0 1 7.5 6ZM10.1 6H10.7A0.5 0.5 0 0 1 11.2 6.5V8.9A0.5 0.5 0 0 1 10.7 9.4H10.1A0.5 0.5 0 0 1 9.6 8.9V6.5A0.5 0.5 0 0 1 10.1 6ZM13.75 7.7A1.25 1.25 0 1 0 16.25 7.7A1.25 1.25 0 1 0 13.75 7.7Z"/><path fill-rule="evenodd" d="M4.1 21H16.1A1.5 1.5 0 0 1 17.6 22.5V26.1A1.5 1.5 0 0 1 16.1 27.6H4.1A1.5 1.5 0 0 1 2.6 26.1V22.5A1.5 1.5 0 0 1 4.1 21ZM4.9 22.6H5.5A0.5 0.5 0 0 1 6 23.1V25.5A0.5 0.5 0 0 1 5.5 26H4.9A0.5 0.5 0 0 1 4.4 25.5V23.1A0.5 0.5 0 0 1 4.9 22.6ZM7.5 22.6H8.1A0.5 0.5 0 0 1 8.6 23.1V25.5A0.5 0.5 0 0 1 8.1 26H7.5A0.5 0.5 0 0 1 7 25.5V23.1A0.5 0.5 0 0 1 7.5 22.6ZM10.1 22.6H10.7A0.5 0.5 0 0 1 11.2 23.1V25.5A0.5 0.5 0 0 1 10.7 26H10.1A0.5 0.5 0 0 1 9.6 25.5V23.1A0.5 0.5 0 0 1 10.1 22.6ZM13.75 24.3A1.25 1.25 0 1 0 16.25 24.3A1.25 1.25 0 1 0 13.75 24.3Z"/></g><path fill-rule="evenodd" d="M7.9 12.7H19.9A1.5 1.5 0 0 1 21.4 14.2V17.8A1.5 1.5 0 0 1 19.9 19.3H7.9A1.5 1.5 0 0 1 6.4 17.8V14.2A1.5 1.5 0 0 1 7.9 12.7ZM8.7 14.3H9.3A0.5 0.5 0 0 1 9.8 14.8V17.2A0.5 0.5 0 0 1 9.3 17.7H8.7A0.5 0.5 0 0 1 8.2 17.2V14.8A0.5 0.5 0 0 1 8.7 14.3ZM11.3 14.3H11.9A0.5 0.5 0 0 1 12.4 14.8V17.2A0.5 0.5 0 0 1 11.9 17.7H11.3A0.5 0.5 0 0 1 10.8 17.2V14.8A0.5 0.5 0 0 1 11.3 14.3ZM13.9 14.3H14.5A0.5 0.5 0 0 1 15 14.8V17.2A0.5 0.5 0 0 1 14.5 17.7H13.9A0.5 0.5 0 0 1 13.4 17.2V14.8A0.5 0.5 0 0 1 13.9 14.3ZM17.55 16A1.25 1.25 0 1 0 20.05 16A1.25 1.25 0 1 0 17.55 16Z"/><path d="M23.6 11.2 L28.4 16 L23.6 20.8" fill="none" stroke="currentColor" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></g></svg>'

# The words a person reads, in one place. The same words the dashboard uses.
$script:VmfReportOutcome = @{
    migrated = @('Migrated', 'good'); putBack = @('Restored', 'quiet'); rolledBack = @('Rolled back', 'bad')
    attention = @('Needs attention', 'bad'); leftOut = @('Left out', 'quiet'); working = @('In progress', 'info')
    notStarted = @('Not started', 'quiet'); unknown = @('Unknown', 'quiet')
    # RECORD-UNMOVED-1: the run page's word for a machine the plan does not move.
    notMoved = @('Not moved', 'quiet')
}
# MANUAL-WHY-1: the run page's word for a machine the plan does not move.
$script:VmfReportMethod = @{ A = 'In-place upgrade'; EXCLUDED = 'Not moved'; MANUAL = 'Not moved' }
$script:VmfReportEvidenceResult = [ordered]@{
    same = @('Same', 'good'); planned = @('Changed as planned', 'info'); changed = @('Changed', 'warn'); notRead = @('Not read', 'quiet')
}
$script:VmfReportEvidenceGroup = [ordered]@{ azure = 'Azure'; imds = 'Instance Metadata Service'; guest = 'Guest' }

function ConvertTo-VmfRecordUtc {
    <#
    .SYNOPSIS
        A time from a record as a UTC date value, or $null. ConvertFrom-Json
        turns an ISO time into a date value (PLANVER-2), so a time here may be
        either; it is never read through its culture text. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Value)
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    try { ([datetimeoffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture)).UtcDateTime } catch { $null }
}

function Get-VmfRecordLastChange {
    <#
    .SYNOPSIS
        REPORT-AUTO-1: the newest time a migration record holds for a change,
        as a UTC date value - or $null when it holds none. The report shows it
        instead of the time it was written, so two writes of an unchanged
        migration are the same file. Pure.
    .DESCRIPTION
        A change is a step, a decision, a restore, a rebuild, a deletion of
        safety copies, or any line of activity - a capacity release the engine
        logged, an Azure call on a machine (review 8: the footer lagged the
        content without them). Writing the report or the record, and an engine
        operation starting, are NOT changes: counting them would make every
        write differ from the one before.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $times = [System.Collections.Generic.List[datetime]]::new()
    $add = { param($v) $d = ConvertTo-VmfRecordUtc $v; if ($d) { $times.Add($d) } }
    $addActivity = { param($list)
        foreach ($ev in @($list)) {
            if (-not $ev) { continue }
            $step = [string](& $f $ev 'step')
            if ($step -in @('report', 'record') -or $step -like 'engine:*') { continue }
            & $add (& $f $ev 'tsUtc')
        }
    }
    foreach ($m in @(& $f $Record 'machines')) {
        if (-not $m) { continue }
        foreach ($s in @(& $f $m 'steps')) { if ($s) { & $add (& $f $s 'tsUtc') } }
        & $addActivity (& $f $m 'activity')
        & $add (& $f (& $f $m 'putBack') 'restoredUtc')
        & $add (& $f (& $f $m 'retention') 'deletedUtc')
    }
    foreach ($d in @(& $f $Record 'decisions')) { if ($d) { & $add (& $f $d 'atUtc') } }
    & $addActivity (& $f $Record 'runActivity')
    if ($times.Count) { ($times | Sort-Object)[-1] } else { $null }
}
function ConvertTo-VmfReportHtml {
    <#
    .SYNOPSIS
        The report's cover and its five sections, from a migration record.
        Pure. Returns the HTML from <body> content: the cover through the
        sign-off. The caller adds anything it keeps after that.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Record,
        # A title the caller gave. The cover says "Migration report" without one.
        [Parameter()][string]$Title
    )
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $pill = { param($pair) "<span class=`"pill $($pair[1])`">$(& $enc $pair[0])</span>" }
    # ConvertFrom-Json turns an ISO time into a date value (CLAUDE.md, PLANVER-2),
    # so a time here may be either; never read one through its culture text.
    $utc = { param($v) if (-not $v) { return $null }; if ($v -is [datetime]) { return $v.ToUniversalTime() }
        try { ([datetimeoffset]::Parse([string]$v, [cultureinfo]::InvariantCulture)).UtcDateTime } catch { $null } }
    $hm = { param($d) if ($d) { $d.ToString('HH:mm', [cultureinfo]::InvariantCulture) } else { '' } }
    $day = { param($d) if ($d) { $d.ToString('d MMM yyyy', [cultureinfo]::InvariantCulture) } else { '' } }
    $short = { param($s) ([string]$s -replace '^Standard_', '') }
    $plural = { param([int]$n, $one, $many) "$n $(if ($n -eq 1) { $one } else { $many })" }
    # TEMP-DISK-PREVIEW-1: a Path A move the plan recorded as preview is the
    # in-place upgrade with the preview feature, and says so.
    $methodOf = { param($p, $machine)
        $name = if ($script:VmfReportMethod.ContainsKey([string]$p)) { $script:VmfReportMethod[[string]$p] } else { 'Not moved' }
        if ([string]$p -eq 'A' -and $machine -and $machine.target -and $machine.target.PSObject.Properties['method'] -and [string]$machine.target.method -eq 'preview') { "$name (Preview)" } else { $name } }
    # A controller Azure did not report, or a machine not read yet, is "Not
    # read" - never a guess.
    $ctlOf = { param($v) if ([string]$v) { [string]$v } else { 'Not read' } }

    # A record just built holds ordered tables; one read back holds objects.
    # One shape for everything below.
    $Record = $Record | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $machines = @($Record.machines | Where-Object { $_ })
    # When each machine's move ran: its first step after PLANNED to its last.
    $spanOf = { param($m)
        $times = @(@($m.steps) | Where-Object { $_ -and [string]$_.state -ne 'PLANNED' } | ForEach-Object { & $utc $_.tsUtc } | Where-Object { $_ } | Sort-Object)
        if ($times.Count) { @($times[0], $times[-1]) } else { $null } }
    $allTimes = @(foreach ($m in $machines) { $s = & $spanOf $m; if ($s) { $s } }) | Sort-Object
    $window = if ($allTimes.Count) {
        $a = $allTimes[0]; $b = $allTimes[-1]
        if ($a.Date -eq $b.Date) { "$(& $day $a), $(& $hm $a)&ndash;$(& $hm $b) UTC" } else { "$(& $day $a) $(& $hm $a) &ndash; $(& $day $b) $(& $hm $b) UTC" }
    } else { 'Not started' }
    $waves = @($machines | ForEach-Object { [string]$_.wave } | Where-Object { $_ } | Select-Object -Unique)
    $subs = @($machines | ForEach-Object { if ([string]$_.vmId -match '(?i)/subscriptions/([^/]+)/') { $Matches[1] } } | Select-Object -Unique)

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<div class="sheet"><header class="cover">')
    $heading = if ($Title) { $Title } else { 'Migration report' }
    $null = $sb.AppendLine("<div class=`"brandline`">$script:VmfReportLogo Migration Factory</div><h1>$(& $enc $heading)</h1><dl class=`"meta`">")
    $null = $sb.AppendLine("<div><dt>Migration</dt><dd class=`"mono`">$(& $enc $Record.runId)</dd></div>")
    if ($Record.project) { $null = $sb.AppendLine("<div><dt>Project</dt><dd>$(& $enc $Record.project)</dd></div>") }
    $null = $sb.AppendLine("<div><dt>Change window</dt><dd>$window</dd></div>")
    $null = $sb.AppendLine("<div><dt>Scope</dt><dd>$(& $plural $machines.Count 'machine' 'machines') &middot; $(& $plural $waves.Count 'wave' 'waves') &middot; $(& $plural $subs.Count 'subscription' 'subscriptions')</dd></div>")
    $null = $sb.AppendLine('</dl></header>')

    # 1. Results.
    $count = { param($o) @($machines | Where-Object { [string]$_.outcome -eq $o }).Count }
    $durations = @(foreach ($m in @($machines | Where-Object { [string]$_.outcome -eq 'migrated' })) { $s = & $spanOf $m; if ($s) { ($s[1] - $s[0]).TotalMinutes } })
    $null = $sb.AppendLine('<section><h2><span class="no">1</span> Results</h2><div class="box results">')
    $null = $sb.AppendLine("<div class=`"res`"><b>$(& $count 'migrated')</b><span>Migrated</span></div>")
    foreach ($o in 'putBack', 'rolledBack', 'attention', 'working', 'notStarted', 'notMoved', 'leftOut', 'unknown') {
        $n = & $count $o
        if ($n) { $null = $sb.AppendLine("<div class=`"res`"><b>$n</b><span>$(& $enc $script:VmfReportOutcome[$o][0])</span></div>") }
    }
    if ($durations.Count) { $null = $sb.AppendLine("<div class=`"res`"><b>$([math]::Round(($durations | Measure-Object -Average).Average)) min</b><span>Average time for each migrated machine</span></div>") }
    $null = $sb.AppendLine('</div></section>')

    # 2. Moves: each combination of size, target and method, with how many.
    $null = $sb.AppendLine('<section><h2><span class="no">2</span> Moves</h2><div class="box"><table>')
    $null = $sb.AppendLine('<tr><th>From</th><th>To</th><th>Disk controller</th><th>Kind of change</th><th class="n">Machines</th><th class="n">Migrated</th></tr>')
    # Grouped on what each row SHOWS, so one move is never two identical rows.
    $groups = $machines | Group-Object { "$($_.before.size)|$($_.target.size)|$(& $ctlOf $_.before.controller)|$(& $ctlOf $_.target.controller)|$(& $methodOf $_.path $_)" } | Sort-Object Name
    foreach ($g in $groups) {
        $m = $g.Group[0]
        $from = & $ctlOf $m.before.controller
        $to = & $ctlOf $m.target.controller
        $method = & $methodOf $m.path $m
        $done = @($g.Group | Where-Object { [string]$_.outcome -eq 'migrated' }).Count
        $null = $sb.AppendLine("<tr><td class=`"mono`">$(& $enc $m.before.size)</td><td class=`"mono`">$(& $enc $m.target.size)</td><td>$(& $enc $from) <span class=`"arr`">&rarr;</span> $(& $enc $to)</td><td>$(& $enc $method)</td><td class=`"n`">$($g.Count)</td><td class=`"n`">$done</td></tr>")
    }
    $null = $sb.AppendLine('</table></div></section>')

    # 3. Machines, by wave, each with its evidence.
    $null = $sb.AppendLine('<section><h2><span class="no">3</span> Machines</h2><div class="box"><table>')
    $null = $sb.AppendLine('<tr><th>Machine</th><th>Size</th><th>Kind of change</th><th>Time (UTC)</th><th>Result</th></tr>')
    # Waves in the order they ran; a wave that has not started goes last.
    $firstOf = { param($grp) $ts = @(foreach ($m in $grp.Group) { $s = & $spanOf $m; if ($s) { $s[0] } }) | Sort-Object; if ($ts.Count) { $ts[0] } else { [datetime]::MaxValue } }
    foreach ($w in @($machines | Group-Object { [string]$_.wave } | Sort-Object { & $firstOf $_ }, Name)) {
        $wt = @(foreach ($m in $w.Group) { $s = & $spanOf $m; if ($s) { $s } }) | Sort-Object
        $wWhen = if ($wt.Count) { " &middot; $(& $hm $wt[0])&ndash;$(& $hm $wt[-1])" } else { '' }
        $wName = if ($w.Name) { $w.Name } else { 'Not in a wave' }
        $null = $sb.AppendLine("<tr class=`"wave`"><td colspan=`"5`">$(& $enc $wName)<span class=`"w`">$(& $plural $w.Count 'machine' 'machines')$wWhen</span></td></tr>")
        foreach ($m in @($w.Group | Sort-Object name)) {
            $out = if ($script:VmfReportOutcome.ContainsKey([string]$m.outcome)) { $script:VmfReportOutcome[[string]$m.outcome] } else { $script:VmfReportOutcome.unknown }
            $os = (@($m.before.os, $(if ($m.before.PSObject.Properties['osVersion']) { $m.before.osVersion })) | Where-Object { $_ }) -join ' '
            $size = if ([string]$m.outcome -eq 'migrated' -and $m.now.size -and $m.now.size -ne $m.before.size) {
                "$(& $enc (& $short $m.before.size))<span class=`"arr`">&rarr;</span>$(& $enc (& $short $m.now.size))"
            } else { & $enc (& $short $(if ($m.now.size) { $m.now.size } else { $m.before.size })) }
            $method = & $methodOf $m.path $m
            $s = & $spanOf $m
            $when = if ($s) { if ($s[0] -eq $s[1]) { & $hm $s[0] } else { "$(& $hm $s[0])&ndash;$(& $hm $s[1])" } } else { '&mdash;' }
            $null = $sb.AppendLine("<tr><td><div class=`"nm`">$(& $enc $m.name)</div><div class=`"os`">$(& $enc $os)</div></td><td class=`"mono`">$size</td><td>$(& $enc $method)</td><td>$when</td><td>$(& $pill $out)</td></tr>")
            $ev = if ($m.PSObject.Properties['evidence']) { $m.evidence } else { $null }
            $rows = @(if ($ev) { @($ev.rows) | Where-Object { $_ } })
            if ($rows.Count) {
                $tally = @($script:VmfReportEvidenceResult.Keys | ForEach-Object { $k = $_; $n = @($rows | Where-Object { [string]$_.result -eq $k }).Count; if ($n) { "$n $($script:VmfReportEvidenceResult[$k][0].ToLowerInvariant())" } }) -join ', '
                $null = $sb.AppendLine("<tr class=`"evrow`"><td colspan=`"5`"><details><summary>Evidence: $($rows.Count) readings, $(& $enc $tally)</summary><div class=`"ev`"><table>")
                $null = $sb.AppendLine('<tr><th>Reading</th><th>Before</th><th>After</th><th>Result</th></tr>')
                foreach ($grp in $script:VmfReportEvidenceGroup.Keys) {
                    $inGroup = @($rows | Where-Object { [string]$_.group -eq $grp })
                    if (-not $inGroup.Count) { continue }
                    $null = $sb.AppendLine("<tr class=`"grp`"><td colspan=`"4`">$(& $enc $script:VmfReportEvidenceGroup[$grp])</td></tr>")
                    foreach ($r in $inGroup) {
                        $res = if ($script:VmfReportEvidenceResult.Contains([string]$r.result)) { $script:VmfReportEvidenceResult[[string]$r.result] } else { $script:VmfReportEvidenceResult.notRead }
                        $b = if ($null -ne $r.before) { & $enc $r.before } else { '&mdash;' }; $a = if ($null -ne $r.after) { & $enc $r.after } else { '&mdash;' }
                        $null = $sb.AppendLine("<tr><td>$(& $enc $r.label)</td><td class=`"v`">$b</td><td class=`"v`">$a</td><td>$(& $pill $res)</td></tr>")
                    }
                }
                $null = $sb.AppendLine('</table></div></details></td></tr>')
            }
        }
    }
    $null = $sb.AppendLine('</table></div><p class="key">Same: the reading after the move is equal to the reading before. Changed as planned: the plan changes this reading. Changed: the reading is different, and the plan does not change it. Not read: the product could not read it on one side. A reading that fails its check stops the move and restores the machine.</p></section>')

    # 4. Exceptions.
    # REPORT-AUTO-1 review 6: in name order, so two writes give the same file.
    $exceptions = @($machines | Where-Object { [string]$_.outcome -in @('putBack', 'rolledBack', 'attention') } | Sort-Object { [string]$_.name }, { [string]$_.vmId })
    $null = $sb.AppendLine('<section><h2><span class="no">4</span> Exceptions</h2>')
    if ($exceptions.Count) {
        $null = $sb.AppendLine('<div class="box"><table><tr><th>Machine</th><th>Result</th><th>Reason</th><th>By</th><th>At (UTC)</th><th>Next step</th></tr>')
        foreach ($m in $exceptions) {
            $out = $script:VmfReportOutcome[[string]$m.outcome]
            $steps = @(@($m.steps) | Where-Object { $_ })
            $last = $steps | Select-Object -Last 1
            $coded = @($steps | Where-Object { $_.PSObject.Properties['reasonCode'] -and $_.reasonCode }) | Select-Object -Last 1
            $guide = if ($coded) { Get-VmfStopGuidance -Code ([string]$coded.reasonCode) } else { $null }
            $kept = @($steps | Where-Object { $_.PSObject.Properties['evidenceRef'] -and $_.evidenceRef }) | Select-Object -Last 1
            $r = if ($m.PSObject.Properties['putBack']) { $m.putBack } else { $null }
            switch ([string]$m.outcome) {
                'putBack' {
                    $reason = if ($r -and $r.PSObject.Properties['note'] -and $r.note) { [string]$r.note } else { 'No reason was given.' }
                    $by = if ($r -and $r.PSObject.Properties['restoredBy']) { [string]$r.restoredBy } else { '' }
                    $at = if ($r -and $r.PSObject.Properties['restoredUtc']) { & $utc $r.restoredUtc } else { $null }
                    $next = 'Migrate the machine again in a new change window.'
                }
                default {
                    # The words the product already shows for this stop - its
                    # title and what to do - not the engine's own message.
                    $reason = if ($guide) { [string]$guide.title } elseif ([string]$m.outcome -eq 'rolledBack') { 'A step failed, and the product restored the machine.' } else { 'A step stopped, and the machine needs a person.' }
                    $by = 'The product'; $at = if ($last) { & $utc $last.tsUtc } else { $null }
                    # LAB-UX-1: with the retry line the Migrations page adds, from one table.
                    $next = if ($guide -and $guide.whatToDo) { Get-VmfStopNextStep -Guidance $guide } else { 'Open the machine on the Migrations page to see the details.' }
                }
            }
            $file = if ($kept) { "<div class=`"os`">Evidence file: <span class=`"mono`">$(& $enc $kept.evidenceRef)</span></div>" } else { '' }
            $atText = if ($at) { "$(& $day $at) $(& $hm $at)" } else { '&mdash;' }
            $null = $sb.AppendLine("<tr><td class=`"nm`">$(& $enc $m.name)</td><td>$(& $pill $out)</td><td>$(& $enc $reason)$file</td><td>$(& $enc $by)</td><td>$atText</td><td>$(& $enc $next)</td></tr>")
        }
        $null = $sb.AppendLine('</table></div>')
    }
    else { $null = $sb.AppendLine('<p class="muted">No exceptions.</p>') }
    $null = $sb.AppendLine('</section>')

    # 5. Sign-off.
    $null = $sb.AppendLine('<section><h2><span class="no">5</span> Sign-off</h2><div class="box"><table><tr><th>Approval</th><th>By</th><th>At (UTC)</th></tr>')
    foreach ($d in @($Record.decisions | Where-Object { $_ })) {
        $what = switch ([string]$d.what) {
            'signed off the plan' { 'Plan' }
            'approved the wave' { "Wave $($d.wave)" }
            'approved the wave by signing off the plan' { "Wave $($d.wave), in the plan sign-off" }
            "accepted the wave's settings" { "Settings of wave $($d.wave)" }
            'accepted the note about machines defined in code' { 'Machines defined in code' }
            # SQL-TEMPDB-SIGNOFF-1: with the plan sign-off; the note names the machines.
            'checked where tempdb is on the SQL Server machines' { "SQL Server and the temporary disk: $($d.note)" }
            default { [string]$d.what }
        }
        $at = & $utc $d.atUtc
        $null = $sb.AppendLine("<tr><td>$(& $enc $what)</td><td>$(& $enc $d.by)</td><td>$(if ($at) { "$(& $day $at), $(& $hm $at)" } else { '&mdash;' })</td></tr>")
    }
    # REPORT-AUTO-1: no row for the report itself. It was the "Produce the
    # report" dialog's optional note, signed in the name of whoever pressed
    # the button. The engine writes the report now, and nobody signs it; the
    # decisions above are every sign-off the product records.
    if (-not @($Record.decisions | Where-Object { $_ }).Count) {
        $null = $sb.AppendLine('<tr><td colspan="3" class="muted">No approval is recorded.</td></tr>')
    }
    $null = $sb.AppendLine('</table></div></section>')

    $sb.ToString()
}
