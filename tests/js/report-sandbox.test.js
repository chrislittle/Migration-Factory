/* SEC-REPORT-1: the customer report is shown in a SANDBOXED frame.
 *
 * It used to go straight into the new window:
 *
 *     const w = window.open('', '_blank');
 *     w.document.write(html);
 *
 * A window opened on an empty URL inherits the OPENER's origin. So the report
 * rendered as the dashboard - and the dashboard's origin is where MSAL keeps
 * the access token (sessionStorage, on every page) and where the CSP allows
 * 'unsafe-inline'. The report is a document GENERATED from run data by
 * New-VmfReport, so anything reaching it unescaped was script with the
 * viewer's token in reach.
 *
 * Nothing reached it unescaped - that was checked field by field, and two
 * composed strings were fixed at the same time. The point is that it was one
 * forgotten Encode away, in a document that gains a section whenever the
 * report grows.
 *
 * An EMPTY sandbox attribute gives a unique opaque origin and no scripting,
 * and it costs nothing here: the report has no script, no form, no handler.
 *
 * REPORT-THEME-1: the handler is the function openReport now, because the
 * link moved onto the run's row; this lifts the function instead of matching
 * the old inline handler. The report also gains a mark on its root element -
 * the dashboard's theme - so "verbatim" is now "verbatim apart from that mark".
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const openReport = lift('reports.html', 'openReport');
globalThis.markTheme = lift('reports.html', 'markTheme');
globalThis.esc = (x) => String(x ?? '');
globalThis.UX = { reportTitle: 'Migration report' };
globalThis.reportShown = { run: null, html: '', opener: null };

/* NO-POPUPS-1: the report shows in the page, so this is the PAGE just real
 * enough to record what the handler does to it. Anything written to a
 * document, and any window opened, is recorded too: neither may happen. */
function fakeWindow() {
  const written = [];
  const made = [];
  const el = (id) => ({ id, hidden: true, textContent: '', focus() {},
    replaceChildren: (...kids) => { if (id === 'report-slot') { made.length = 0; made.push(...kids); } } });
  const els = Object.fromEntries(['report-view', 'report-slot', 'report-run', 'report-close'].map(id => [id, el(id)]));
  globalThis.document = {
    write: (h) => written.push(h),
    getElementById: (id) => els[id] || null,
    body: { classList: { add() {}, remove() {} } },
    createElement: () => ({ style: {}, _attrs: {}, srcdoc: null,
      setAttribute(k, v) { this._attrs[k] = v; } }),
  };
  return { written, made, open: (...a) => { written.push(`window.open(${a.join(', ')})`); return null; } };
}

async function runHandler(report) {
  const w = fakeWindow();
  globalThis.window = { open: w.open, VmfTheme: { current: () => 'light' } };
  globalThis.source = { readText: async () => report };
  await openReport('r1');
  return w;
}

test('the function was found in the page', () => {
  ok(typeof openReport === 'function', 'otherwise every assertion below is vacuous');
});

test('THE POINT: the report never reaches document.write', async () => {
  const REPORT = '<h1>report</h1><script>steal(sessionStorage)</script>';
  const w = await runHandler(REPORT);
  const all = w.written.join('');
  ok(!all.includes('steal(sessionStorage)'),
     'the report must not be written into a window that shares the dashboard origin');
  ok(!all.includes('<h1>report</h1>'), 'none of it, not just the script');
  ok(!all.includes('window.open'), 'NO-POPUPS-1: and no window is opened for it');
});

test('it goes into a frame with an EMPTY sandbox attribute', async () => {
  const w = await runHandler('<p>x</p>');
  eq(w.made.length, 1, 'exactly one element is added');
  const frame = w.made[0];
  eq(frame._attrs.sandbox, '',
     'empty means every restriction: opaque origin, no scripting');
  ok(!/allow-scripts|allow-same-origin/.test(String(frame._attrs.sandbox)),
     'naming either token would give back what this is for');
});

test('and the report is handed over as srcdoc, verbatim apart from the theme mark on its root', async () => {
  const REPORT = '<!DOCTYPE html><html lang="en"><p>a "quoted" & <angled> report</p></html>';
  const w = await runHandler(REPORT);
  eq(w.made[0].srcdoc, '<!DOCTYPE html><html data-theme="light" lang="en"><p>a "quoted" & <angled> report</p></html>',
     'as a property, with nothing escaped or rewritten');
});

// REPORT-AUTO-1: the engine stores the report with no theme mark. A dark
// dashboard marks it dark on the way into the frame, and changes nothing else.
test('a report stored with no mark is marked with the theme the dashboard shows', async () => {
  const w = fakeWindow();
  globalThis.window = { open: w.open, VmfTheme: { current: () => 'dark' } };
  globalThis.source = { readText: async () => '<!DOCTYPE html><html lang="en"><p>r</p></html>' };
  await openReport('r1');
  eq(w.made[0].srcdoc, '<!DOCTYPE html><html data-theme="dark" lang="en"><p>r</p></html>', 'marked dark, nothing else changed');
  eq(w.made[0]._attrs.sandbox, '', 'and the sandbox is still empty');
});

run();
