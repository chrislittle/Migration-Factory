/* WAVE-APPROVE-TIMER-WORDS-1, 2026-10-20. The Migrations list says what the
 * plan's timer says.
 *
 * WHAT WAS WRONG. A plan signed off with "Sign off all" runs on its own. When
 * a wave set to need no approval changed after the sign-off, the timer held
 * it with signOffOutOfDate - a start nobody presses rests on an approval, and
 * the change removed it. But the summary in run-status.json said `start`
 * (nothing holds the next wave), so the Migrations list put the migration
 * under Planned - "A wave is ready to start, and nothing waits for a person" -
 * and the overview did not list it at all. Nothing started, and nothing said
 * a person must act.
 *
 * THE RULE. The engine's summary asks the timer's own rule
 * (Get-VmfUnattendedStartRefusal) and records its code, signOffOutOfDate.
 * The pages read that code: the migration is Waiting for approval, and its
 * tag is start, the first word of the button the timer's own words name.
 *
 * WHAT IS TESTED. The list's own loadRuns, run on a status document in the
 * shape the engine writes, and the panel it draws; the overview's own
 * migrationFacts and panel; and the tables, read from the schema and from
 * start-gates.json, so a new reason cannot reach the list without a tag.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// PAGE-LOAD-2: the page's one calls fail here, so its reads go to the fake source.
const { perFileHelp, perFileGlobals } = require('./_held');

const REPO = path.join(__dirname, '..', '..');
const HELP = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const SCHEMA = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'run-status.schema.json'), 'utf8'));
const GATES = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'start-gates.json'), 'utf8'));

// help.js's own code and tables, not copies.
const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup', 'runKind']);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);

// The schema's own list of what the next wave waits for.
const WAITS_FOR = SCHEMA.properties.summary.properties.next.properties.waitsFor.enum;
// The values that do not wait for a person at a start gate: a wave is
// running, every wave ran, a machine waits (Needs attention), a gate the
// engine cannot name, or nothing holds the next wave.
const NOT_A_GATE = ['running', 'none', 'decision', 'unknown', 'start'];

/* A status document in the shape the engine writes (Write-VmfRunStatusDocument):
 * wave-1 finished, wave-2 changed after the sign-off and is next. */
function engineStatus(waitsFor) {
  return {
    schemaVersion: SCHEMA.properties.schemaVersion.const, runId: 'contoso-move',
    summary: {
      writtenUtc: '2026-10-20T10:00:00.0000000Z', reason: 'dailyCheck', halted: false, machines: 4,
      stateCounts: { MIGRATED: 2, PLANNED: 2 }, waitsOnPerson: 0,
      waves: [{ wave: 'wave-1', machines: 2, stateCounts: { MIGRATED: 2 }, waitsOnPerson: 0 }, { wave: 'wave-2', machines: 2, stateCounts: { PLANNED: 2 }, waitsOnPerson: 0 }],
      next: { wave: 'wave-2', waitsFor },
    },
  };
}

/* ---- the Migrations list, run ------------------------------------------ */

// PERF-MIGRATIONS-TICK-1: loadRuns reads a run's status and plan through tickReads.
const list = liftAll('migrations.html', ['loadRuns', 'linkedRunId', 'runLabel', 'runTag', 'renderRunPanel', 'tickReads', 'listReads']);

async function loadList(status) {
  const panel = { innerHTML: '', querySelector: () => null, querySelectorAll: () => [] };
  const name = { textContent: '' }; const project = { textContent: '' };
  globalThis.$ = (sel) => ({ '#run-panel': panel, '#run-current-name': name, '#run-current-project': project })[sel] ?? null;
  globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  globalThis.ago = () => 'a while ago';
  globalThis.runIsRecent = () => true;
  globalThis.showOlderRuns = false;
  globalThis.reading = false;
  globalThis.RUN_WINDOW_DAYS = 14;
  globalThis.UX_MISC = { waiting: 'Reading your migrations.', noRuns: 'no migrations', continueSetup: 'Continue setup', rowProject: 'Project' };
  // eslint-disable-next-line no-eval
  globalThis.RUN_GROUPS = eval((PAGE.match(/const RUN_GROUPS = (\[[^\]]*\]);/) || [])[1]);
  // eslint-disable-next-line no-eval
  globalThis.GROUP_PILL = eval(`(${(PAGE.match(/const GROUP_PILL = (\{[^}]*\});/) || [])[1]})`);
  globalThis.GROUP_TAG = liftConst('migrations.html', 'GROUP_TAG');
  globalThis.runTag = list.runTag;
  globalThis.runLabel = list.runLabel;
    globalThis.linkedRunId = list.linkedRunId;
  globalThis.renderRunPanel = list.renderRunPanel;
  globalThis.pendingRuns = new Set();
  globalThis.lastListError = null;
  globalThis.runRows = [];
  globalThis.currentRun = null;
  globalThis.location = { search: '' };
  globalThis.localStorage = { getItem: () => null };
  Object.assign(globalThis, perFileGlobals());
  globalThis.VmfHelp = Object.assign({}, shared, perFileHelp(), {
    mapLimited: (items, fn) => Promise.all(Array.from(items).map(fn)),
    VmfRun: {
      parse(id) { const s = String(id ?? ''); const cut = s.indexOf('/'); return cut <= 0 ? { project: null, run: s } : { project: s.slice(0, cut), run: s.slice(cut + 1) }; },
      fromQuery: () => null,
      link: (page, id) => `${page}?run=${id}`,
    },
  });
  const plan = { entries: ['a', 'b', 'c', 'd'].map((n, i) => ({ vmId: `/vm/${n}`, path: 'A', wave: i < 2 ? 'wave-1' : 'wave-2' })) };
  const docs = { 'run.json': { runId: 'contoso-move', kind: 'migration' }, 'run-status.json': status, 'plan.json': plan };
  globalThis.source = {
    listRuns: async () => ['contoso-move'],
    readJson: async (r, rel) => structuredClone(docs[rel] ?? null),
    readVersioned: async (r, rel) => (docs[rel] ? { text: JSON.stringify(docs[rel]), version: 'v1' } : null),
  };
  globalThis.DEMO_MODE = false;
  // A new page each time: what the last one learned about the run is not kept.
  globalThis.runKinds = new Map();
  globalThis.listedRuns = null;
  globalThis.tickReads = list.tickReads;
  await list.loadRuns();
  return { rows: globalThis.runRows, html: panel.innerHTML };
}

test('THE REGRESSION: a wave the timer holds with signOffOutOfDate is Waiting for approval, tagged start - not Planned', async () => {
  const out = await loadList(engineStatus('signOffOutOfDate'));
  eq(out.rows.length, 1);
  eq(out.rows[0].group, 'Waiting for approval', 'a person must act before the wave starts');
  eq(out.rows[0].waitsFor, 'signOffOutOfDate', 'the code the engine recorded, as it recorded it');
  ok(out.html.includes('>Waiting for approval</div>'), 'the group heading is drawn');
  ok(out.html.includes('>start</span>'), 'the row says what to do: start the wave');
  ok(!out.html.includes('>Planned</div>'), 'and it is not listed as a wave ready to start with nobody needed');
});

test('a wave nothing holds is still Planned, tagged planned', async () => {
  const out = await loadList(engineStatus('start'));
  eq(out.rows[0].group, 'Planned');
  ok(out.html.includes('>planned</span>'));
});

test('a paused migration is Other, whatever the timer would say', async () => {
  const st = engineStatus('signOffOutOfDate');
  st.summary.halted = true;
  eq((await loadList(st)).rows[0].group, 'Other');
});

/* ---- the overview, run ------------------------------------------------- */

test('the overview lists it with the same tag, from the same code', () => {
  globalThis.VmfHelp = Object.assign({}, shared);
  const migrationFacts = lift('index.html', 'migrationFacts');
  const facts = migrationFacts(engineStatus('signOffOutOfDate'), 'running');
  eq(facts.waits, { wave: 'wave-2', tag: 'start' });
  globalThis.UX = liftConst('index.html', 'UX');
  // PAGE-SCALE-OVERVIEW-1: the Waiting for approval tile's row says the tag.
  globalThis.VmfHelp.runTitle = (p) => p;
  const { migrationRow } = liftAll('index.html', ['migrationRow', 'stoppedWaves']);
  const r = migrationRow({ id: 'contoso-move', kind: 'migration', projectId: null, waits: facts.waits, when: null }, new Map());
  ok(r.next.text.startsWith('start '), 'the overview row shows the tag');
});

/* ---- the tables, held to the engine ------------------------------------ */

test('every value the schema allows is either a gate with a tag, or one that waits for no person', () => {
  for (const w of WAITS_FOR) {
    if (NOT_A_GATE.includes(w)) {
      ok(!RUN_GATE_WAITS.includes(w), `${w} is not a gate a person passes`);
    } else {
      ok(RUN_GATE_WAITS.includes(w), `${w} puts the migration under Waiting for approval`);
      ok(typeof RUN_GATE_TAG[w] === 'string' && RUN_GATE_TAG[w], `${w} has a tag`);
    }
  }
  for (const w of RUN_GATE_WAITS) { ok(WAITS_FOR.includes(w), `${w} is a value the engine can write`); }
});

test("the tag of signOffOutOfDate is the button the timer's own words name", () => {
  const reason = GATES.reasons.signOffOutOfDate;
  ok(reason, 'start-gates.json has the reason the list reads');
  ok(/select Start this wave/.test(reason.toDo), 'the timer says to select Start this wave');
  eq(RUN_GATE_TAG.signOffOutOfDate, 'start');
});

run('timer words');
