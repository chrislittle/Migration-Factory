/* WAIT-2, 2026-09-18. The Migrations page says what it is reading.
 *
 * WHAT HAPPENED. The page came up with every table empty and stayed that
 * way for about ten seconds, with nothing on screen saying anything was
 * happening. It looked broken, then it loaded: 10 seconds with no sign of
 * loading.
 *
 * An empty table and a table still being filled look identical, and the first
 * thing somebody does with a page that looks broken is press things.
 *
 * WAIT-1 gave the run PICKER a waiting state and stopped there. Four other
 * pages have one for their body. This page did not.
 *
 * Each region names what IT is reading rather than saying "Loading", because
 * five regions all saying the same word tell nobody which one is slow - the
 * rule help.js sets out beside waitingLine.
 */
'use strict';
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

/* Lifted together, because they read one list between them - that is the
 * point of the list. A test that stubbed the list would stop covering the
 * thing it exists to keep in step. */
// MACHINE-PANEL-STALE-1: clearReadingRun closes the machine panel; machine-panel-stale.test.js runs that.
globalThis.closeDrill = () => { };
const body = liftAll('migrations.html', ['readingRegions', 'showReadingRun', 'clearReadingRun']);
const showReadingRun = body.showReadingRun;
const clearReadingRun = body.clearReadingRun;
// NOT-IN-WAVE-QUEUED-1: renderWaves draws the groups waveGroups gives.
const renderWaves = liftAll('migrations.html', ['waveGroups', 'renderWaves']).renderWaves;

/* The four regions the body fills, plus the tiles. Keyed the way the page
 * selects them, so a region that is renamed shows up as an unpainted region
 * rather than as nothing at all. */
const REGIONS = ['#kpis', '#waves', '#cap-table tbody', '#copies-table tbody', '#event-table tbody'];

function page(opts) {
  const els = {};
  // Enough of an element for the page to write to and then wire up. The DOM
  // harness's rule applies: innerHTML is text, so a lookup inside freshly
  // painted markup finds nothing, and that is what an empty list stands for.
  for (const sel of REGIONS) {
    els[sel] = { innerHTML: 'STALE', querySelectorAll: () => [], appendChild: () => {} };
  }
  // The safety-copies header is built at render time; the page reads its width
  // from it rather than writing the number down twice.
  els['#copies-head'] = { children: { length: (opts && opts.copyCols) || 6 } };
  globalThis.$ = (sel) => els[sel] ?? null;
  globalThis.VmfHelp = {
    waitingLine: (t) => `<p class="muted vmf-waiting">${t}</p>`,
    waitingRow: (t, n) => `<tr><td colspan="${n}" class="muted vmf-waiting">${t}</td></tr>`,
    // WAVE-ORDER-1: the plan's wave order (help.js).
    waveOrder: (p) => [...new Set((p?.entries ?? []).map(e => e.wave).filter(Boolean))],
  };
  globalThis.UX_MISC = {
    readingWaves: 'Reading the machines in this migration run.',
    readingCapacity: 'Reading the quota and the capacity reservations for this run.',
    readingCopies: 'Reading the safety copies for this run.',
    readingActivity: 'Reading the activity for this run.',
  };
  return els;
}

test('every region of the body says it is being read', () => {
  const els = page();
  showReadingRun();
  for (const sel of ['#waves', '#cap-table tbody', '#copies-table tbody', '#event-table tbody']) {
    ok(els[sel].innerHTML.includes('vmf-waiting'), `${sel} shows a waiting state`);
    ok(!els[sel].innerHTML.includes('STALE'), `${sel} no longer shows the run before it`);
  }
});

test('each region says what IT is reading, so a slow one can be told apart', () => {
  const els = page();
  showReadingRun();
  const said = [
    els['#waves'].innerHTML,
    els['#cap-table tbody'].innerHTML,
    els['#copies-table tbody'].innerHTML,
    els['#event-table tbody'].innerHTML,
  ];
  eq(new Set(said).size, 4, 'four regions, four different sentences');
  ok(said[0].includes('machines'), 'the waves region names the machines');
  ok(said[1].includes('capacity'), 'the capacity region names capacity');
  ok(said[2].includes('safety copies'), 'the copies region names the safety copies');
  ok(said[3].includes('activity'), 'the activity region names the activity');
});

test('the tiles are cleared, never left showing the run before this one', () => {
  /* A count from the previous run standing over a table being read is the
   * disagreement KPI-COUNT-1 was about, arriving a different way. */
  const els = page();
  showReadingRun();
  eq(els['#kpis'].innerHTML, '');
});

test('a waiting row spans the table it sits in', () => {
  /* QUOTA-FAMILY-1 changed this from five. The capacity card is one row per
   * quota family now, with six columns, and two more only when a wave in view
   * reserves - so its width is read from the header the page built, like the
   * copies one, and six is the card before any header is built. */
  const els = page({ copyCols: 7 });
  showReadingRun();
  ok(els['#cap-table tbody'].innerHTML.includes('colspan="6"'), 'capacity has six columns before a header is built');
  const built = page({ copyCols: 7 });
  built['#cap-head'] = { children: { length: 8 } };
  showReadingRun();
  ok(built['#cap-table tbody'].innerHTML.includes('colspan="8"'),
     'the capacity width is read from the header the page built');
  ok(els['#copies-table tbody'].innerHTML.includes('colspan="7"'),
     'the copies width is read from the header the page built');
});

test('a missing copies header does not stop the page saying it is reading', () => {
  const els = page();
  delete els['#copies-head'];
  globalThis.$ = (sel) => els[sel] ?? null;
  showReadingRun();
  ok(els['#copies-table tbody'].innerHTML.includes('vmf-waiting'));
});

/* ---- the guard that keeps the message on screen -------------------------- */

test('typing while the page loads does not wipe the waiting line', () => {
  /* The search box and the status chips re-render the waves on a keystroke.
   * During the first read there is nothing to render, so without this the
   * person who types is left with the blank page all over again. */
  const els = page();
  showReadingRun();
  const waiting = els['#waves'].innerHTML;
  globalThis.showingRun = null;
  globalThis.currentRun = 'proj/migration-1';
  renderWaves(false);
  eq(els['#waves'].innerHTML, waiting, 'the waves region is untouched');
});

test('once the body is showing the run, the waves render normally', () => {
  /* The other half of the same guard. If it refused here too, the read would
   * finish and the page would sit on the waiting line for ever. */
  const els = page();
  showReadingRun();
  globalThis.showingRun = 'proj/migration-1';
  globalThis.currentRun = 'proj/migration-1';
  globalThis.planDoc = null;
  globalThis.allVms = [];
  globalThis.searchTerm = '';
  globalThis.statusFilter = 'all';
  renderWaves(false);
  eq(els['#waves'].innerHTML, '', 'it drew, and this run has no waves');
});

/* ---- taking it down again ----------------------------------------------- */

test('a store with no runs does not sit saying it is reading for ever', () => {
  /* WAIT-3: the message is painted BEFORE the store is read, so an empty store
   * has to take it down. Otherwise the page explains that there are no
   * migrations while four tables underneath claim to be loading some. */
  const els = page();
  showReadingRun();
  ok(els['#waves'].innerHTML.includes('vmf-waiting'), 'it was up');
  clearReadingRun();
  for (const sel of ['#waves', '#cap-table tbody', '#copies-table tbody', '#event-table tbody']) {
    eq(els[sel].innerHTML, '', `${sel} is empty, not waiting`);
  }
});

test('both halves cover the SAME regions, because they read one list', () => {
  /* The pair is the trap: a region painted by one and left behind by the
   * other. They share a list so that cannot happen, and this proves the list
   * is really what they both read. */
  const els = page();
  showReadingRun();
  const painted = Object.keys(els).filter(k => k !== '#copies-head' && els[k].innerHTML !== 'STALE');
  clearReadingRun();
  const cleared = Object.keys(els).filter(k => k !== '#copies-head' && els[k].innerHTML === '');
  eq(painted.sort().join(','), cleared.sort().join(','), 'every region shown is a region cleared');
});

run('reading a run');
