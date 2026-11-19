/* REPORT-THEME-1 (GitHub issue 426): the report follows the dashboard's light
 * or dark choice on screen, the record uses the report's stylesheet, and the
 * report link is on the row. Every file handed over was light until the owner
 * reversed that on 2026-10-02 (REPORT-AUTO-1): the person's theme is honoured
 * everywhere, so the record download carries the theme the person sees.
 *
 * The report is shown in a frame with an EMPTY sandbox (SEC-REPORT-1), so
 * nothing inside it can read the person's choice. The page that opens it
 * writes the choice on the report's root element first. Nothing runs in the
 * frame, and the sandbox stays empty.
 *
 * RUN, not read: the page's own functions, lifted.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// DISCLAIMER-1: the record ends with the short line, which the page reads from
// help.js (VmfHelp.disclaimerLine). tests/js/disclaimer.test.js holds the words.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { disclaimerLine: 'The short line.' });

globalThis.UX = liftConst('reports.html', 'UX');
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const markTheme = lift('reports.html', 'markTheme');
globalThis.markTheme = markTheme;
const recordHtml = lift('reports.html', 'recordHtml');
const openReport = lift('reports.html', 'openReport');
const loadSummaries = lift('reports.html', 'loadSummaries');
globalThis.num = lift('reports.html', 'num');

const REPORT = '<!DOCTYPE html>\n<html lang="en" data-theme="light"><head><meta charset="utf-8"></head><body><p>a "quoted" &amp; report</p></body></html>';

// ---------- markTheme ----------

test('markTheme writes the theme on the root, in place of the mark the file carries', () => {
  const out = markTheme(REPORT, 'dark');
  ok(out.includes('<html data-theme="dark" lang="en">'), out.slice(0, 80));
  ok(!out.includes('data-theme="light"'), 'the stored light mark is replaced, not left beside it');
  eq(out.replace(' data-theme="dark"', ' data-theme="light"').replace('<html data-theme="light" lang="en">', '<html lang="en" data-theme="light">'), REPORT,
     'nothing else in the report changes');
});

test('markTheme writes light for light', () => {
  ok(markTheme(REPORT, 'light').includes('<html data-theme="light" lang="en">'), 'light');
});

test('markTheme writes only one of two words - anything else is light', () => {
  for (const odd of ['system', '', null, undefined, '"><script>alert(1)</script>', 'DARK']) {
    const out = markTheme(REPORT, odd);
    ok(out.includes('<html data-theme="light" lang="en">'), `for ${JSON.stringify(odd)}`);
    ok(!out.includes('<script>'), 'never the value it was given');
  }
});

test('markTheme gives a document with no root element one, after its doctype', () => {
  eq(markTheme('<h1>Sample</h1>', 'dark'), '<html data-theme="dark"><h1>Sample</h1>');
  eq(markTheme('<!doctype html><p>x</p>', 'dark'), '<!doctype html><html data-theme="dark"><p>x</p>');
});

test('markTheme touches the root element only', () => {
  const body = '<!DOCTYPE html><html lang="en"><body><p data-theme="light">x</p></body></html>';
  const out = markTheme(body, 'dark');
  ok(out.includes('<html data-theme="dark" lang="en">'), 'the root');
  ok(out.includes('<p data-theme="light">x</p>'), 'an element in the body is left as it is');
});

// ---------- openReport ----------

/* NO-POPUPS-1: the report shows in the page. `made` is what the page puts in
 * the report view's slot; `written` is anything written to a document or any
 * window opened - neither may happen. */
function fakeWindow(theme) {
  const written = [];
  const made = [];
  const srcdocs = [];
  globalThis.reportShown = { run: null, html: '', opener: null };
  const el = (id) => ({ id, hidden: true, textContent: '', focus() {},
    replaceChildren: (...kids) => { if (id === 'report-slot') { made.length = 0; made.push(...kids); } } });
  const els = Object.fromEntries(['report-view', 'report-slot', 'report-run', 'report-close'].map(id => [id, el(id)]));
  const doc = {
    write: (h) => written.push(h),
    getElementById: (id) => els[id] || null,
    body: { classList: { add() {}, remove() {} } },
    createElement: () => {
      const el = { style: {}, _attrs: {}, setAttribute(k, v) { this._attrs[k] = v; } };
      // Records each srcdoc given, and the sandbox the frame had at that moment.
      Object.defineProperty(el, 'srcdoc', {
        set(v) { srcdocs.push({ v, sandbox: el._attrs.sandbox }); },
        get() { return srcdocs.length ? srcdocs[srcdocs.length - 1].v : ''; },
      });
      return el;
    },
  };
  globalThis.document = doc;
  const win = { open: (...a) => { written.push(`window.open(${a.join(', ')})`); return null; } };
  if (theme) { win.VmfTheme = { current: () => theme, choice: () => 'system' }; }
  return { written, made, srcdocs, win };
}

async function opened(theme, report = REPORT) {
  const f = fakeWindow(theme);
  globalThis.window = f.win;
  globalThis.source = { readText: async (run, rel) => (run === 'r1' && rel === 'customer-report.html' ? report : null) };
  await openReport('r1');
  return f;
}

test('THE POINT: a dark dashboard gives the frame a report marked dark', async () => {
  const f = await opened('dark');
  eq(f.srcdocs.length, 1, 'the report is handed over once, already marked');
  ok(f.srcdocs[0].v.includes('<html data-theme="dark" lang="en">'), 'marked dark');
  ok(f.srcdocs[0].v.includes('<p>a "quoted" &amp; report</p>'), 'and the report itself, as it was');
});

test('a light dashboard gives it a report marked light', async () => {
  const f = await opened('light');
  ok(f.srcdocs[0].v.includes('<html data-theme="light" lang="en">'), 'marked light');
});

test('"Follow the system" gives the theme the dashboard SHOWS, not the word system', async () => {
  // fakeWindow's choice() says 'system' and current() says what is painted.
  const f = await opened('dark');
  ok(!f.srcdocs[0].v.includes('system'), 'no mark the stylesheet does not know');
});

test('a page with no theme control gives light', async () => {
  const f = await opened(null);
  ok(f.srcdocs[0].v.includes('<html data-theme="light" lang="en">'), 'light');
});

test('SEC-REPORT-1 still: the sandbox is empty, and set before the report goes in', async () => {
  const f = await opened('dark');
  eq(f.made.length, 1, 'one frame');
  eq(f.made[0]._attrs.sandbox, '', 'an empty sandbox: an opaque origin and no script');
  eq(f.srcdocs[0].sandbox, '', 'the frame was locked when the report went in');
  ok(!f.written.join('').includes('quoted'), 'the report never reaches document.write');
});

// ---------- recordHtml ----------

const LOOK = {
  stylesheet: ':root,:root[data-theme="light"]{--bg:#f8f9fa}:root[data-theme="dark"]{--bg:#222222}.sheet{margin:0 auto}',
  logo: '<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M23.6 11.2 L28.4 16 L23.6 20.8"/></svg>',
};
const REC = {
  schemaVersion: 2, runId: 'mig-1', project: 'estate', fromAssessment: null,
  generatedUtc: '2026-10-02T10:00:00Z', generatedBy: 'admin@example.com', reason: 'downloaded', keepUntilUtc: '2026-12-31T10:00:00Z',
  summary: { migrated: 1 }, decisions: [],
  machines: [{ vmId: '/x/web', name: 'web', wave: 'w1', outcome: 'migrated', before: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' },
    now: { size: 'Standard_D2s_v6', basis: 'the plan target' }, steps: [], guestScripts: [], putBack: null, activity: [] }],
  runActivity: [],
};

test('THE POINT: the record carries the report stylesheet it was given, once', () => {
  const html = recordHtml(REC, LOOK);
  eq(html.split(LOOK.stylesheet).length - 1, 1, 'exactly one copy');
  ok(/<head>[\s\S]*<style>[\s\S]*<\/style>[\s\S]*<\/head>/.test(html), 'in the head');
});

/* REPORT-AUTO-1 REWROTE this: it held every download to light. The record is
 * marked with the theme it is given - the one this page shows - and only
 * 'dark' or 'light' is ever written. */
test('the record carries the theme it is given: dark for dark, light for anything else', () => {
  ok(recordHtml(REC, LOOK, 'dark').includes('<html lang="en" data-theme="dark">'), 'marked dark');
  ok(recordHtml(REC, LOOK, 'light').includes('<html lang="en" data-theme="light">'), 'marked light');
  for (const odd of [undefined, 'system', '"><b>x</b>']) {
    const html = recordHtml(REC, LOOK, odd);
    ok(html.includes('<html lang="en" data-theme="light">'), `light for ${JSON.stringify(odd)}`);
    ok(!html.includes('<b>x</b>'), 'never the value it was given');
  }
});

test('REPORT-AUTO-1: the report as the engine now stores it - no mark - is marked for the frame', () => {
  const stored = '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8"></head><body><p>r</p></body></html>';
  ok(markTheme(stored, 'dark').includes('<html data-theme="dark" lang="en">'), 'dark');
  ok(markTheme(stored, 'light').includes('<html data-theme="light" lang="en">'), 'light');
});

test('the record has the report cover: the mark, the product and the migration', () => {
  const html = recordHtml(REC, LOOK);
  ok(html.includes('<header class="cover">'), 'the cover');
  ok(html.includes(LOOK.logo), 'the mark');
  ok(html.includes(UX.rProduct), 'the product name');
  ok(html.includes('<div class="sheet">'), 'the sheet');
  ok(html.includes('<div class="box"><table>'), 'tables in the report box');
});

test('the record has no style of its own beside the stylesheet', () => {
  const html = recordHtml(REC, LOOK).replace(LOOK.stylesheet, '');
  ok(!/style="/i.test(html), 'no inline style');
  ok(!/#[0-9a-f]{3,8}\b|rgba?\(|font-family/i.test(html), 'no colour or font');
});

test('with no stylesheet from the service, the record is still saved, plain and light', () => {
  const html = recordHtml(REC, null);
  ok(!/<style/i.test(html), 'no empty style block');
  ok(html.includes('<html lang="en" data-theme="light">'), 'still marked light');
  ok(html.includes('Standard_D2s_v6'), 'the data is all there');
});

test('a stylesheet cannot end its own block, and a mark that is not a plain picture is left out', () => {
  const html = recordHtml(REC, { stylesheet: '.a{x:1}</style><script>alert(1)</script>', logo: '<svg onload="alert(1)"></svg>' });
  ok(!html.includes('</style><script>'), 'the stylesheet stays inside its block');
  eq(html.split('</style>').length - 1, 1, 'one end to the block - its own - so the rest is text in it, which never runs');
  ok(!html.includes('onload'), 'a mark with a handler is not used');
});

/* Independent review: the first filter took any <svg> with no "<script" and no
 * " onX=", and three marks got through it - a slash before the handler, a
 * frame inside foreignObject, and a javascript: link. A record is opened from
 * disk, where script runs. Now the mark must be the report's own shape: an
 * svg of g, rect and path, with drawing attributes only. */
test('a mark is used only when it is a plain drawing - every way round the first filter is refused', () => {
  const hostile = [
    '<svg><foreignObject><img src="x"/onerror="alert(1)"></foreignObject></svg>',
    '<svg><foreignObject><iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;"></iframe></foreignObject></svg>',
    '<svg><a href="javascript:alert(1)"><path d="M1 1"/></a></svg>',
    '<svg viewBox="0 0 32 32" aria-hidden="true"><path d="M1 1" onclick="alert(1)"/></svg>',
    '<svg viewBox="0 0 32 32" aria-hidden="true"><use href="https://example.com/x.svg#a"/></svg>',
  ];
  for (const logo of hostile) {
    const html = recordHtml(REC, { stylesheet: '.a{b:c}', logo });
    ok(!html.includes(logo), `refused: ${logo}`);
    ok(!/alert|javascript:|foreignObject|<use/.test(html), `nothing of it: ${logo}`);
  }
});

test('the report mark itself is accepted', () => {
  // The module's own mark, read from $script:VmfReportLogo itself, so this
  // test cannot hold an old copy of it. LOGO-SERVERS-1: it has the drive bays
  // and lights as even-odd holes, so fill-rule must pass the drawing rule.
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Private', 'report', 'ReportHtml.ps1'), 'utf8');
  const own = (/\$script:VmfReportLogo = '([^']*)'/.exec(src) || [])[1] || '';
  ok(own.includes('fill-rule="evenodd"'), 'the module mark is the server-unit drawing');
  ok(recordHtml(REC, { stylesheet: '.a{b:c}', logo: own }).includes(own), 'the mark is on the cover');
});

test('a stylesheet that would load anything from the network is not used', () => {
  for (const css of ['@import "https://example.com/x.css";.a{b:c}', '.a{background:url(https://example.com/x.png)}', '.a{background:URL(x)}']) {
    const html = recordHtml(REC, { stylesheet: css, logo: '' });
    ok(!/example\.com\/x|url\(|@import/i.test(html), `refused: ${css}`);
    ok(html.includes('Standard_D2s_v6'), 'and the record is still saved, plain');
  }
});

// NO-POPUPS-1 REWROTE this: there is no window around the frame any more. The
// view around it is the page's, painted with the theme's own background, and
// the frame is a block that fills it.
test('the view around the report takes the theme, and the frame fills it with no gap', async () => {
  const f = await opened('dark');
  eq(f.written, [], 'no window opened and nothing written to a document');
  eq(f.made[0].className, 'report-frame', 'the frame takes the look app.css gives it');
  const css = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8');
  ok(/\.p-reports \.report-frame \{[^}]*display:block/.test(css), 'a block frame leaves no strip under it');
  ok(/\.p-reports \.report-view \{[^}]*background:var\(--bg\)/.test(css), 'the view is the theme\'s background, so a dark report does not open on a white flash');
  ok(/\.p-reports \.report-view\[hidden\] \{ display:none; \}/.test(css), 'and a hidden view is hidden: display:flex would show it');
});

// ---------- the row ----------

/* PAGE-SCALE-REPORTS-1: the rows are the shared list's now (VmfHelp.listMount
 * draws them), so the page gives each row its actions and listens for the
 * press. The link is still on the row, and opens the report, not the detail. */
const rowPage = liftAll('reports.html', ['outcomeState', 'outcomeTag', 'projectName', 'runRow', 'onListClick']);

test('THE POINT: a migration with a report shows the link on its row, unexpanded', () => {
  globalThis.projects = [];
  globalThis.VmfHelp = { runTitle: () => 'name', VmfRun: { parse: (x) => ({ project: null, run: x }) } };
  const r1 = rowPage.runRow({ r: 'r1', total: 2, migrated: 2, attention: 0, waves: 1, hasReport: true });
  const r2 = rowPage.runRow({ r: 'r2', total: 1, migrated: 0, attention: 0, waves: 1, hasReport: false });
  eq(r1.actions, [{ text: UX.fullReport, action: 'report', value: 'r1' }], 'r1 has the link on its row, in the words the manual uses');
  eq(r2.actions, [], 'r2 has no report, so no link');
});

test('pressing the link opens the report, and not the migration\'s detail', async () => {
  const asked = [], opened = [];
  globalThis.openReport = async (run, btn) => { asked.push([run, btn.id]); };
  globalThis.openDetail = (run) => { opened.push(run); return true; };
  const btn = { id: 'b1', dataset: { value: 'r1' } };
  rowPage.onListClick({ target: { closest: (s) => (s === 'button[data-action="report"]' ? btn : null) }, preventDefault() {} });
  await new Promise(res => setTimeout(res, 0));
  eq(asked, [['r1', 'b1']], 'the report of that migration');
  eq(opened, [], 'the detail does not open');
});
test('reading the runs finds which have a report, so the row can say so', async () => {
  globalThis.rows = [];
  globalThis.byNewest = () => 0;
  globalThis.renderTable = () => {};
  // PERF-MIGRATIONS-TICK-1: the page asks the one rule whether a run is an assessment.
  // PAGE-LOAD-1: the one call fails, so the page reads through `source` below.
  Object.assign(globalThis, { DEMO_MODE: false, held: null, LIST_READS: [], cfg: { apiUrl: 'https://service.example.com/api' },
    getToken: async () => 'token', heldSummary: () => undefined });
  globalThis.VmfHelp = { storeDocs: async () => { throw new Error('per-file reads measured here'); }, runKind: lift('help.js', 'runKind'), mapLimited: async (items, fn, lim, progress) => {
    const out = [];
    for (const i of items) { out.push(await fn(i)); }
    if (progress) { progress(out); }
    return out;
  } };
  globalThis.projects = [];
  globalThis.storeRuns = []; globalThis.assessmentIds = new Set();
  globalThis.source = {
    // PAGE-SCALE-REPORTS-1: the projects come from the same one call; none here.
    listProjects: async () => [],
    listRuns: async () => ['r1', 'r2', 'scan-only'],
    readJson: async (r, rel) => (rel === 'plan.json' ? (r === 'scan-only' ? null : { entries: [{ vmId: 'a', wave: 'w' }] }) : {}),
    summary: async () => ({ outcomes: { migrated: 1 } }),
    exists: async (r, rel) => r === 'r1' && rel === 'customer-report.html',
  };
  await loadSummaries();
  const of = (r) => globalThis.rows.find(x => x.r === r);
  eq(of('r1').hasReport, true, 'r1 has one');
  eq(of('r2').hasReport, false, 'r2 has none');
  eq(of('scan-only').hasReport, false, 'a run never planned has none');
});

run('report-theme');
