/* RETENTION-CARD-CYCLE-1: the Safety copies card on the Reports page (it was
 * on the Overview until PAGE-SCALE-REPORTS-1 moved it) and
 * on each migration page says when the day's cleanup is unfinished.
 *
 * Since PERF-RETENTION-TIMEOUT-1 the daily cleanup is a cycle of hourly
 * passes, and its record (retention-status.json, schema 2) says where the
 * cycle is. Both cards read only the schema 1 fields: while a cycle had
 * migrations still to examine, they counted those examined so far as a whole
 * day, and named "next cleanup 03:30 tomorrow" for a pass less than an hour
 * away. So an operator could think that expired copies which still bill were
 * examined. These run each page's own sentence builder with its own words
 * against the real VmfHelp.retentionPassFacts.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const NOW = '2026-11-02T09:50:00Z';
const help = liftAll('help.js', ['nextRetentionPassUtc', 'retentionPassFacts']);
globalThis.VmfHelp = { ...(globalThis.VmfHelp || {}), retentionPassFacts: (pass) => help.retentionPassFacts(pass, NOW),
                       nextRetentionPassUtc: () => help.nextRetentionPassUtc(NOW) };
// The time words are each page's own; they are not under test here.
globalThis.ago = (iso) => `AGO(${iso})`;
// The Reports page says the age in the words the Overview used (VmfHelp.agoText).
globalThis.VmfHelp.agoText = (iso) => `AGO(${iso})`;
// PAGE-SCALE-REPORTS-1 fix round: each count says 1 in the singular, by the one rule.
globalThis.VmfHelp.countWords = lift('help.js', 'countWords');
// LOADING-LINE-1: the card says "Reading the safety copies." while it reads.
globalThis.VmfHelp.waitingLine = lift('help.js', 'waitingLine');
globalThis.whenLocal = (iso) => iso ? `AT(${iso})` : '';

const cycle = (extra) => Object.assign({
  schemaVersion: 2, cycleStartedUtc: '2026-11-02T03:30:01Z', lastPassUtc: '2026-11-02T09:30:02Z', finishedUtc: '2026-11-02T09:34:40Z',
  passesInCycle: 7, runsInStore: 40, runsExamined: 23, runsWithCopiesDue: 2, machinesDue: 3,
  executionsStarted: [{ runId: 'p1/mig-a', machines: 3, execution: 'vmf-engine-x' }], failures: [],
  resumeAtRunId: 'p1/mig-q', resumeStops: 0, nextPassUtc: '2026-11-02T10:30:00Z',
}, extra || {});
const done = () => cycle({ resumeAtRunId: null, runsExamined: 40, nextPassUtc: '2026-11-03T03:30:00Z' });

/* ---- the two pages, each with its own words ---- */
const pages = [
  { name: 'Reports page', words: liftConst('reports.html', 'UX'), build: lift('reports.html', 'copiesPassText'),
    key: { open: 'copiesPassOpen', line: 'copiesPassLine', fail: 'copiesPassFail', none: 'copiesPassNone', next: 'copiesNext', nextOpen: 'copiesNextOpen',
           examined: 'copiesNExamined', examinedOf: 'copiesNExaminedOf', due: 'copiesNDue', started: 'copiesNStarted' } },
  { name: 'Migration page', words: liftConst('migrations.html', 'UX_COPIES'), build: lift('migrations.html', 'copiesPassSentence'),
    key: { open: 'passOpen', line: 'passLine', fail: 'passFail', none: 'passNone', next: 'nextPass', nextOpen: 'nextPassOpen',
           examined: 'nExamined', examinedOf: 'nExaminedOf', due: 'nDue', started: 'nStarted' } },
];

for (const pg of pages) {
  const W = (k) => pg.words[pg.key[k]];
  const say = (pass) => { globalThis.UX = pg.words; globalThis.UX_COPIES = pg.words; return pg.build(pass); };
  // PAGE-SCALE-REPORTS-1 fix round: a count is a pair of words, the first for 1.
  const N = (k, n, by) => VmfHelp.countWords(n, W(k), { total: by, by: by === undefined ? n : by });

  test(`${pg.name}: an unfinished cycle says the cleanup is not complete, how many of the migrations it examined, and the next hourly pass`, () => {
    const text = say(cycle());
    const open = W('open').replace('{ago}', 'AGO(2026-11-02T03:30:01Z)').replace('{examined}', N('examinedOf', 23, 40))
      .replace('{due}', N('due', 3)).replace('{started}', N('started', 1));
    const next = W('nextOpen').replace('{when}', 'AT(2026-11-02T10:30:00.000Z)');
    eq(text, `${open} ${next}`, 'the unfinished sentence and the next hourly pass');
    ok(!text.includes('2026-11-03T03:30'), 'not 03:30 tomorrow');
    ok(!text.includes(W('line').split('{')[0]), 'not the sentence of a finished day');
  });

  test(`${pg.name}: an unfinished cycle with a failure names the failure too, and is still unfinished`, () => {
    const text = say(cycle({ failures: [{ runId: 'p1/mig-c', reason: 'stopped twice' }] }));
    ok(text.startsWith(W('open').split('{')[0]), 'it says the cleanup is not complete');
    ok(text.includes(W('fail').replace('{reason}', 'stopped twice')), 'and names the failure');
    ok(text.endsWith(W('nextOpen').replace('{when}', 'AT(2026-11-02T10:30:00.000Z)')), 'and the next hourly pass');
  });

  test(`${pg.name}: a complete cycle reads as before, with the next pass from the record`, () => {
    const line = W('line').replace('{ago}', 'AGO(2026-11-02T09:30:02Z)').replace('{examined}', N('examined', 40)).replace('{due}', N('due', 3)).replace('{started}', N('started', 1));
    eq(say(done()), `${line} ${W('next').replace('{when}', 'AT(2026-11-03T03:30:00.000Z)')}`, 'the finished-day sentence');
  });

  test(`${pg.name}: a schema 1 record and no record read as before`, () => {
    const old = { schemaVersion: 1, lastPassUtc: '2026-11-02T03:30:02Z', runsExamined: 3, machinesDue: 1, executionsStarted: [], failures: [] };
    const line = W('line').replace('{ago}', 'AGO(2026-11-02T03:30:02Z)').replace('{examined}', N('examined', 3)).replace('{due}', N('due', 1)).replace('{started}', N('started', 0));
    const next = W('next').replace('{when}', 'AT(2026-11-03T03:30:00.000Z)');
    eq(say(old), `${line} ${next}`, 'schema 1');
    eq(say(null), `${W('none')} ${next}`, 'no record');
    eq(say({ schemaVersion: 1, lastPassUtc: '2026-11-02T03:30:02Z', failures: [{ reason: 'no list' }] }),
       `${W('fail').replace('{reason}', 'no list')} ${next}`, 'a finished day that failed');
  });

  test(`${pg.name}: the new words carry every placeholder the sentence fills`, () => {
    for (const ph of ['{ago}', '{examined}', '{due}', '{started}']) { ok(W('open').includes(ph), `${pg.key.open} has ${ph}`); }
    ok(W('examinedOf').every(w => w.includes('{n}') && w.includes('{total}')), 'the migrations examined of those in the store');
    ok(W('nextOpen').includes('{when}'), `${pg.key.nextOpen} has {when}`);
  });
}

/* PAGE-SCALE-REPORTS-1 fix round (owner): 1 in the singular, on both pages,
 * in the finished-day line and in the unfinished one. */
for (const pg of pages) {
  const say = (pass) => { globalThis.UX = pg.words; globalThis.UX_COPIES = pg.words; return pg.build(pass); };
  test(`${pg.name}: a count of 1 is in the singular - 1 migration checked, 1 machine due, 1 cleanup started`, () => {
    const one = { schemaVersion: 1, lastPassUtc: '2026-11-02T03:30:02Z', runsExamined: 1, machinesDue: 1,
                  executionsStarted: [{ runId: 'p1/mig-a', machines: 1, execution: 'x' }], failures: [] };
    ok(say(one).includes(': 1 migration checked, 1 machine due, 1 cleanup started.'), say(one));
    ok(say(cycle({ runsInStore: 1, runsExamined: 0, machinesDue: 1, executionsStarted: [] }))
      .includes(': 0 of 1 migration checked, 1 machine due, 0 cleanups started.'), 'the unfinished line, chosen by the total');
    ok(say(cycle()).includes(': 23 of 40 migrations checked, 3 machines due, 1 cleanup started.'), say(cycle()));
  });
}
test('both pages say the same thing in the same words', () => {
  eq(pages[0].words.copiesPassOpen, pages[1].words.passOpen, 'the unfinished sentence');
  eq(pages[0].words.copiesNextOpen, pages[1].words.nextPassOpen, 'the next hourly pass');
  eq(pages[0].words.copiesPassLine, pages[1].words.passLine, 'the finished-day sentence');
  for (const [a, b] of [['copiesNExamined', 'nExamined'], ['copiesNExaminedOf', 'nExaminedOf'], ['copiesNDue', 'nDue'], ['copiesNStarted', 'nStarted']]) {
    eq(pages[0].words[a], pages[1].words[b], `the count words ${a}`);
  }
});

/* The cards themselves draw the sentence: each one run with an unfinished
 * cycle, so a card that dropped the call, or drew the old words, fails here. */
test('Reports page: the Safety copies card draws the unfinished sentence', async () => {
  const words = liftConst('reports.html', 'UX');
  const panel = liftAll('reports.html', ['whenLocal', 'copiesPassText', 'copiesLineText', 'copiesRow', 'copiesColumns', 'copiesRunIds', 'copiesFacts', 'drawCopies', 'safetyPanel', 'projectName', 'num']);
  // The box is the shared list now; it writes its lines above the table.
  const lead = { innerHTML: '' };
  const card = { innerHTML: '', querySelector: (s) => (s === '[data-part="lead"]' ? lead : { innerHTML: '', textContent: '', querySelector: () => ({}) }), addEventListener() {} };
  Object.assign(globalThis, {
    UX: words, DEMO_MODE: true, DEMO_COPIES: { runs: [], pass: cycle() }, rows: [{ r: 'p1/mig-a' }], storeRuns: ['p1/mig-a'], assessmentIds: new Set(), projects: [],
    document: { getElementById: (id) => (id === 'copies-card' ? card : null) }, esc: (s) => String(s),
  });
  globalThis.VmfHelp.retentionPassFacts = (pass) => help.retentionPassFacts(pass, NOW);
  globalThis.VmfHelp.listMount = (host) => ({ lead: () => lead, update() {} });
  globalThis.VmfHelp.VmfRun = { parse: (x) => ({ project: String(x).split('/')[0], run: String(x).split('/').pop() }) };
  globalThis.VmfHelp.runTitle = () => 'name';
  await panel.safetyPanel();
  ok(lead.innerHTML.includes(words.copiesPassOpen.split('{')[0]), 'the card says the cleanup is not complete');
  ok(lead.innerHTML.includes(' 23 of 40 '), 'and how many of the migrations it examined');
  ok(!lead.innerHTML.includes(words.copiesNext.split('{')[0]), 'and not the next cleanup of a finished day');
});

test('Migration page: the Safety copies card draws the unfinished sentence', () => {
  const words = liftConst('migrations.html', 'UX_COPIES');
  const page = liftAll('migrations.html', ['copiesPassSentence', 'copiesWaveRows', 'renderSafetyCopies']);
  const store = {};
  globalThis.$ = (sel) => ({ set innerHTML(v) { store[sel] = v; }, get innerHTML() { return store[sel] ?? ''; },
                              set textContent(v) { store[sel] = v; }, get textContent() { return store[sel] ?? ''; },
                              querySelectorAll: () => [] });
  Object.assign(globalThis, { UX_COPIES: words, esc: (s) => String(s), copiesOpen: new Set() });
  Object.assign(globalThis.VmfHelp, { safetyCopyLedger: () => [], safetyCopySummary: () => ({ copies: 0, machines: 0, unlocked: 0 }),
                                      retentionPassFacts: (pass) => help.retentionPassFacts(pass, NOW) });
  page.renderSafetyCopies([], { entries: [] }, cycle());
  ok(store['#copies-pass'].includes(words.passOpen.split('{')[0]), 'the card says the cleanup is not complete');
  ok(store['#copies-pass'].includes(' 23 of 40 '), 'and how many of the migrations it examined');
  ok(!store['#copies-pass'].includes(words.nextPass.split('{')[0]), 'and not the next cleanup of a finished day');
});

/* The sentence tests lift the helper by its text, so a name dropped from the
 * export list passes them, and both cards then show their error line. The
 * export list, read as code (the overview-summary pattern). */
test('help.js exports the helper both cards call, and both cards call it', () => {
  const { pageSource } = require('./_page-source');
  const path = require('path');
  const dash = path.join(__dirname, '..', '..', 'src', 'dashboard');
  const block = (pageSource(path.join(dash, 'help.js')).match(/window\.VmfHelp = \{([\s\S]*?)\};/) || [])[1] || '';
  const names = block.split(',').map(s => s.trim()).filter(Boolean);
  ok(names.length > 20, 'the export list was read');
  ok(names.includes('retentionPassFacts'), 'VmfHelp.retentionPassFacts is exported');
  for (const [file, fn] of [['reports.html', 'copiesPassText'], ['migrations.html', 'copiesPassSentence']]) {
    const src = pageSource(path.join(dash, file));
    const at = src.indexOf(`function ${fn}(`);
    ok(at >= 0 && /VmfHelp\.retentionPassFacts\(/.test(src.slice(at, at + 600)), `${file} ${fn} reads VmfHelp.retentionPassFacts`);
    ok(!/VmfHelp\.nextRetentionPassUtc\(/.test(src), `${file} no longer names 03:30 for every record`);
  }
});

run('retention-card-cycle');
