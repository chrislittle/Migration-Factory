/* PAGE-SCALE-OVERVIEW-1, 2026-11-07. The Overview: four count tiles and one
 * list, in place of five tables one after the other.
 *
 * WHAT WAS WRONG. With real volume, the Overview page was one long scroll,
 * and its layout needed a full redesign. Each
 * table had a row for every item and named a migration by its raw run id.
 *
 * WHAT IS TESTED. The page's own functions, run: which rows each tile holds
 * (the same rules the five tables used), the readable names, what each tile's
 * own column says, the order, the project choices, and that the page mounts
 * the shared list ONCE and gives it the rows on every draw while it reads.
 * The shared piece itself is page-scale-list.test.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const INDEX = pageSource(path.join(DASH, 'index.html'));

// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`); // eslint-disable-line no-eval
const LOOSE = (HELP.match(/const LIST_LOOSE = '([^']*)';/) || [])[1];
const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup', 'runTitle']);
globalThis.VmfHelp = Object.assign({}, shared, { LIST_LOOSE: LOOSE, waitingLine: (t) => `<p>${t}</p>` });

globalThis.UX = liftConst('index.html', 'UX');
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const migrationFacts = lift('index.html', 'migrationFacts');
const page = liftAll('index.html', ['chrome', 'render', 'overviewTiles', 'projectChoices', 'migrationRow', 'stoppedWaves']);

const NOW = Date.now();
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
function doc(summary, extra) {
  return Object.assign({ schemaVersion: 7, runId: 'm', wave: 'w1', updatedUtc: iso(60), stateCounts: {}, running: [],
    summary: Object.assign({ writtenUtc: iso(60), reason: 'waveEnded', halted: false, machines: 4, waitsOnPerson: 0, waves: [],
                             stateCounts: { MIGRATED: 4 }, next: { wave: null, waitsFor: 'none' } }, summary) }, extra || {});
}
const mig = (id, projectId, st, extra) => Object.assign({ id, kind: 'migration', projectId, created: '2026-09-01T10:00:00Z',
                                                          when: iso(30) }, migrationFacts(st, 'running'), extra || {});
const asmt = (id, projectId, approved, found) => ({ id, kind: 'assessment', projectId, approved, found,
                                                    created: '2026-08-20T10:00:00Z', when: iso(90) });
globalThis.T = (m) => iso(m);
const tileOf = (tiles, key) => tiles.find(t => t.key === key);

const STOPPED = doc({ waitsOnPerson: 2, stateCounts: { MIGRATED: 2, NEEDS_DECISION: 1, FAILED_ROLLED_BACK: 1 },
                     waves: [{ wave: 'wave-1', machines: 2, stateCounts: { NEEDS_DECISION: 1, FAILED_ROLLED_BACK: 1 }, waitsOnPerson: 2 },
                             { wave: 'wave-2', machines: 2, stateCounts: { MIGRATED: 2 }, waitsOnPerson: 0 }],
                     next: { wave: null, waitsFor: 'decision' } });
const APPROVE = doc({ stateCounts: { PLANNED: 6 }, machines: 6, next: { wave: 'wave-<1>', waitsFor: 'approval' } });
const RUNNING = doc({ stateCounts: { CONVERTING: 2, PLANNED: 1 }, next: { wave: 'w2', waitsFor: 'running' } },
                   { wave: 'w2', updatedUtc: iso(1), running: [{ vmId: 'a' }, { vmId: 'b' }] });
const DONE = doc({});

function sample() {
  return {
    projects: [{ id: 'pay', name: 'Payments <refresh>', assessments: 2, migrations: 3 }, { id: 'web', name: 'Web tier', assessments: 0, migrations: 1 }],
    loose: ['old-scan'],
    runs: [mig('pay/m-stopped', 'pay', STOPPED), mig('pay/m-approve', 'pay', APPROVE), mig('web/m-run', 'web', RUNNING),
           mig('pay/m-done', 'pay', DONE), mig('old-scan', null, STOPPED, { when: iso(5) }),
           asmt('pay/a-new', 'pay', false, 26), asmt('pay/a-ok', 'pay', true, 9)],
  };
}

/* ---- the tiles: the same rules the five tables used -------------------- */

test('four tiles, in the order of the design, each with its own key', () => {
  const tiles = page.overviewTiles(sample());
  eq(tiles.map(t => t.key), ['person', 'approval', 'running', 'review']);
  eq(tiles.map(t => t.label), [UX.personTitle, UX.approvalTitle, UX.runningTitle, UX.reviewTitle]);
  ok(tiles.every(t => t.hint && t.empty), 'each has a hint and an empty sentence');
  eq(tileOf(tiles, 'person').tone, 'bad');
  eq(tileOf(tiles, 'approval').tone, 'warn');
});

test('each tile holds the rows its table held', () => {
  const tiles = page.overviewTiles(sample());
  eq(tileOf(tiles, 'person').rows.map(r => r.id).sort(), ['old-scan', 'pay/m-stopped'], 'a machine waits for a person');
  eq(tileOf(tiles, 'approval').rows.map(r => r.id), ['pay/m-approve'], 'the next wave waits for approval');
  eq(tileOf(tiles, 'running').rows.map(r => r.id), ['web/m-run'], 'machines move now');
  eq(tileOf(tiles, 'review').rows.map(r => r.id), ['pay/a-new'], 'an assessment nobody accepted');
});

test('a "not known" count is LISTED under Waiting for a person, and says so - never a number', () => {
  // A status document with no summary this page can read.
  const none = { schemaVersion: 7, wave: 'w1', updatedUtc: iso(60), stateCounts: { NEEDS_DECISION: 3, MIGRATED: 1 } };
  const st = { projects: [{ id: 'p', name: 'P' }], loose: [], runs: [mig('p/m-old', 'p', none)] };
  const r = tileOf(page.overviewTiles(st), 'person').rows[0];
  ok(r, 'listed');
  eq(r.machines, { text: UX.attentionUnknown, tone: 'muted' });
  eq(r.stopped, { text: UX.attentionUnknown, tone: 'muted' });
});

test('newest change first, in every tile', () => {
  const rows = tileOf(page.overviewTiles(sample()), 'person').rows;
  eq(rows.map(r => r.id), ['old-scan', 'pay/m-stopped']);
});

/* ---- the readable names ------------------------------------------------ */

test('a row is named by its project and its date, with the run id kept for the line under it', () => {
  const r = tileOf(page.overviewTiles(sample()), 'person').rows.find(x => x.id === 'pay/m-stopped');
  eq(r.name, VmfHelp.runTitle('Payments <refresh>', 'migration', '2026-09-01T10:00:00Z'));
  eq(r.project, 'Payments <refresh>');
  eq(r.projectId, 'pay');
  eq(r.dest, { page: 'migrations', run: 'pay/m-stopped' });
});

test('a run outside a project is named and filtered as outside a project', () => {
  const r = tileOf(page.overviewTiles(sample()), 'person').rows.find(x => x.id === 'old-scan');
  eq(r.project, UX.loose);
  eq(r.projectId, null);
  ok(r.name.startsWith(UX.loose), r.name);
});

test('an assessment opens its review, by its name and by its Review link', () => {
  const r = tileOf(page.overviewTiles(sample()), 'review').rows[0];
  eq(r.dest, { page: 'wizard', run: 'pay/a-new' });
  eq(r.next, { text: UX.reviewOpen, page: 'wizard', run: 'pay/a-new' });
  eq(r.machines, 26, 'the machines it found');
  eq(r.name, VmfHelp.runTitle('Payments <refresh>', 'assessment', '2026-08-20T10:00:00Z'));
});

/* ---- each tile's own column -------------------------------------------- */

test('Stopped at: the waves with a machine that waits, and the count of the whole migration', () => {
  const r = tileOf(page.overviewTiles(sample()), 'person').rows.find(x => x.id === 'pay/m-stopped');
  eq(r.stopped, { text: 'wave-1', tone: 'bad' });
  eq(r.machines, { text: '2', tone: 'bad' });
});

test('Stopped at reads the count of each wave, never its stop states', () => {
  // OLD-VERSION-READERS-REMOVE-6: the engine writes waitsOnPerson for every
  // wave, so a wave without one is not counted from its stop states.
  eq(page.stoppedWaves({ waves: [{ wave: 'a', stateCounts: { NEEDS_DECISION: 1 }, restoredStops: 1 },
                                 { wave: 'b', stateCounts: { FAILED_NEEDS_ATTENTION: 1 } }] }), []);
  eq(page.stoppedWaves({ waves: [{ wave: 'a', stateCounts: {}, waitsOnPerson: 1 }, { wave: 'b', stateCounts: { NEEDS_DECISION: 2 }, waitsOnPerson: 0 }] }),
     ['a'], 'the count, not the states');
  eq(page.stoppedWaves(null), []);
});

test('a count with no wave to name says "not known" at Stopped at, not an empty cell', () => {
  // A summary whose waves count no machine that waits, while the whole count does.
  const st = doc({ waitsOnPerson: 1, stateCounts: { MIGRATED: 4 }, waves: [{ wave: 'w1', machines: 4, stateCounts: { MIGRATED: 4 }, waitsOnPerson: 0 }],
                  next: { wave: null, waitsFor: 'decision' } });
  const r = page.migrationRow(mig('p/m', 'p', st), new Map([['p', 'P']]));
  eq(r.stopped, { text: UX.attentionUnknown, tone: 'muted' });
  eq(r.waiting, { text: '1', tone: 'bad' });
});

test('Next action: the tag and the wave of a migration waiting for approval, and its machines', () => {
  const r = tileOf(page.overviewTiles(sample()), 'approval').rows[0];
  eq(r.next, { text: UX.approvalTag.replace('{tag}', 'approve').replace('{wave}', 'wave-<1>'), tone: 'warn' });
  eq(r.machines, 6);
});

test('Wave: the running wave, and the machines it moves now', () => {
  const r = tileOf(page.overviewTiles(sample()), 'running').rows[0];
  eq(r.wave, 'w2');
  eq(r.moving, 2);
});

test('each tile names its own columns, and every one of them is a column the shared list knows', () => {
  const tiles = page.overviewTiles(sample());
  const heads = (k) => tileOf(tiles, k).columns.map(c => c.head);
  eq(heads('person'), [UX.colMigration, UX.colProject, UX.colStopped, UX.colMachines, UX.colWhen]);
  eq(heads('approval'), [UX.colMigration, UX.colProject, UX.colNext, UX.colMachines, UX.colWhen]);
  eq(heads('running'), [UX.colMigration, UX.colProject, UX.colWave, UX.colMoving, UX.colWhen]);
  eq(heads('review'), [UX.colAssessment, UX.colProject, UX.colNext, UX.colFound, UX.colWhen]);
  for (const t of tiles) {
    for (const c of t.columns) { ok(['name', 'text', 'num', 'tag', 'ago', 'link'].includes(c.kind), `${t.key}: ${c.head}`); }
  }
});

/* ---- the project choices ----------------------------------------------- */

test('the project choices: every project by name, then outside a project when a run is', () => {
  eq(page.projectChoices(sample()), [{ id: 'pay', name: 'Payments <refresh>' }, { id: 'web', name: 'Web tier' }, { id: LOOSE, name: UX.loose }]);
  eq(page.projectChoices({ projects: [{ id: 'a', name: 'A' }], loose: [], runs: [] }), [{ id: 'a', name: 'A' }]);
});

/* ---- the page, drawn --------------------------------------------------- */

function boot(st, isReading) {
  const els = {};
  const mounts = [];
  globalThis.$ = (sel) => (els[sel] = els[sel] || { textContent: '', innerHTML: '' });
  globalThis.state = st;
  globalThis.reading = !!isReading;
  globalThis.overviewList = null;
  globalThis.VmfHelp.listMount = (host, cfg) => {
    const m = { host, cfg, updates: [], update(d) { this.updates.push(d); } };
    mounts.push(m);
    return m;
  };
  return { els, mounts };
}

test('the page mounts the shared list ONCE, and gives it the tiles and projects on every draw', () => {
  const { els, mounts } = boot(sample(), true);
  page.render();
  page.render();
  globalThis.reading = false;
  page.render();
  eq(mounts.length, 1, 'mounted once');
  eq(mounts[0].updates.length, 3, 'updated on each draw');
  eq(mounts[0].cfg.preferred, 'person', 'Waiting for a person first');
  eq(mounts[0].cfg.searchHint, UX.searchHint);
  eq(mounts[0].updates[2].tiles.length, 4);
  eq(mounts[0].updates[2].projects.length, 3);
  ok(els['#panels'].innerHTML.includes('id="ov-list"'), 'the place it is mounted');
});

test('LOADING-LINE-1: once the first project lands, the list is given the Reading sentence and told the page still reads', () => {
  // Before this the list opened on "Waiting for a person" and said nothing
  // waits, while the page still read every other project.
  const { mounts } = boot(sample(), true);
  page.render();
  eq(mounts[0].cfg.waiting, UX.waiting, 'the sentence');
  eq(mounts[0].updates[0].reading, true, 'reading');
  globalThis.reading = false;
  page.render();
  eq(mounts[0].updates[1].reading, false, 'the read ended');
});

test('the Projects table has left the page, and no line below the list points to other pages', () => {
  // OVERVIEW-MORE-LINE-1, 2026-11-09: the Overview had a line of prose that no
  // other page has. Projects and Reports are in the top navigation.
  const { els } = boot(sample(), false);
  page.render();
  const html = els['#panels'].innerHTML;
  ok(!html.includes('href="projects.html"') && !html.includes('href="reports.html"'), html);
  ok(!html.includes('vmf-more'), 'no line below the list');
  ok(!('moreText' in UX) && !('moreProjects' in UX) && !('moreReports' in UX), 'no words for it');
  ok(!html.includes('<table'), 'no table of its own');
  ok(!/function projectsPanel|function attentionPanel|function approvalPanel|function runningPanel|function reviewPanel/.test(INDEX),
     'none of the five tables is left');
});

test('before anything is read it says what it reads, and the first visit still says where to start', () => {
  let b = boot({ projects: [], loose: [], runs: [] }, true);
  page.render();
  ok(b.els['#panels'].innerHTML.includes(UX.waiting), 'reading');
  eq(b.mounts.length, 0);
  b = boot({ projects: [], loose: [], runs: [] }, false);
  page.render();
  ok(b.els['#panels'].innerHTML.includes(UX.firstTitle), 'start here');
  eq(b.mounts.length, 0);
});

test('an empty page after a full one mounts the list again when rows come back', () => {
  const b = boot(sample(), false);
  page.render();
  globalThis.state = { projects: [], loose: [], runs: [] };
  page.render();
  globalThis.state = sample();
  page.render();
  eq(b.mounts.length, 2, 'the first-visit card replaced the list, so it is mounted again');
});

test('the sample page shows each tile with rows, and enough stopped migrations for a second page', () => {
  // The manual's picture is taken from ?demo (tools/manual-shots.js).
  const demo = liftConst('index.html', 'DEMO_STATE');
  const tiles = page.overviewTiles(demo);
  ok(tiles.every(t => t.rows.length > 0), tiles.map(t => `${t.key}:${t.rows.length}`).join(' '));
  ok(tileOf(tiles, 'person').rows.length > 10, 'a second page');
});

run('page-scale-overview');
