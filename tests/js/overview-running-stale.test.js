/* OVERVIEW-RUNNING-STALE-1, 2026-11-13. Running now asks the list's question.
 *
 * WHAT WAS WRONG. A migration of one wave and one machine finished its move.
 * The Overview still listed it under Running now, with Machines moving 1, and
 * the tile counted 1. The page counted the `running` list of the status
 * document and nothing else: the engine's last write of the wave listed the
 * machine (its worker still held the lease while it deleted the rollback
 * disks), and nothing writes the live fields again after a wave ends. So a
 * list written once stayed true for the page for ever.
 *
 * The Migrations page asks VmfHelp.runGroup, which says In progress only when
 * the engine wrote in the last fifteen minutes. The Overview now asks the same
 * question: a migration is under Running now only when runGroup says In
 * progress and the status lists a machine moving.
 *
 * WHAT IS TESTED. The overview's own functions, with the list's own grouping
 * code from help.js - not a copy of either.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));

const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup', 'runTitle']);
// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.VmfHelp = Object.assign({}, shared, { waitingLine: (t) => `<p>${t}</p>` });
globalThis.UX = liftConst('index.html', 'UX');
globalThis.esc = (v) => String(v ?? '');

const migrationFacts = lift('index.html', 'migrationFacts');
const page = liftAll('index.html', ['overviewTiles', 'migrationRow', 'stoppedWaves']);

ok(RUN_ACTIVE_MS > 0, 'the fifteen minutes were read from help.js');

const NOW = Date.now();
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();

/* The lab migration: one wave, one machine, MIGRATED, with the machine
 * still in `running` - what the engine's last write held. */
function finished(minAgo, extra) {
  return Object.assign({
    schemaVersion: 8, runId: 'm1', wave: 'wave-demo', updatedUtc: iso(minAgo),
    stateCounts: { MIGRATED: 1 },
    running: [{ vmId: 'vm-1', state: 'MIGRATED', workerId: 'w1' }],
    summary: { writtenUtc: iso(minAgo), reason: 'waveEnded', halted: false, machines: 1,
               restoredStops: 0, waitsOnPerson: 0, waves: [],
               stateCounts: { MIGRATED: 1 }, next: { wave: null, waitsFor: 'none' } },
  }, extra || {});
}
/* A wave on its way: one machine converting, written `minAgo` minutes ago. */
function moving(minAgo) {
  return {
    schemaVersion: 8, runId: 'm2', wave: 'wave-1', updatedUtc: iso(minAgo),
    stateCounts: { CONVERTING: 1, PLANNED: 1 },
    running: [{ vmId: 'vm-2', state: 'CONVERTING', workerId: 'w1' }],
    summary: { writtenUtc: iso(minAgo), reason: 'waveRunning', halted: false, machines: 2,
               restoredStops: 0, waitsOnPerson: 0, waves: [],
               stateCounts: { CONVERTING: 1, PLANNED: 1 }, next: { wave: 'wave-1', waitsFor: 'running' } },
  };
}

function tiles(runs) {
  const st = { projects: [{ id: 'p', name: 'P' }], loose: [], runs };
  const out = {};
  for (const t of page.overviewTiles(st)) { out[t.key] = t.rows; }
  return out;
}
const row = (id, st) => Object.assign({ id, kind: 'migration', projectId: 'p', when: st && st.updatedUtc }, migrationFacts(st));
const group = (st) => VmfHelp.runGroup(false, st.stateCounts, Date.parse(st.updatedUtc), Date.now(), { summary: VmfHelp.runSummaryOf(st) });

test('THE REGRESSION: a status written 20 minutes ago that lists a machine is not Running now', () => {
  const st = finished(20);
  eq(group(st), 'Completed', 'the Migrations page puts it under Completed');
  eq(migrationFacts(st).running, 0, 'no machine moving');
  const t = tiles([row('p/m-done', st)]);
  eq(t.running.length, 0, 'not under Running now');
  eq(t.person.length, 0, 'and not under Waiting for a person');
  eq(t.approval.length, 0, 'and not under Waiting for approval: a finished migration leaves the Overview');
});

test('a wave that stopped writing 20 minutes ago with a machine on its way is not Running now either', () => {
  const st = moving(20);
  ok(group(st) !== 'In progress', 'the Migrations page does not say In progress');
  eq(tiles([row('p/m-quiet', st)]).running.length, 0);
});

test('a fresh status that lists a machine moving is Running now, with its count', () => {
  const st = moving(1);
  eq(group(st), 'In progress');
  const t = tiles([row('p/m-live', st)]);
  eq(t.running.map(r => r.id), ['p/m-live']);
  eq(t.running[0].moving, 1, 'Machines moving');
  eq(t.running[0].wave, 'wave-1');
});

test('a fresh status with no machine listed is not Running now', () => {
  const st = finished(1, { running: [] });
  eq(tiles([row('p/m-empty', st)]).running.length, 0);
});

test('Running now holds a migration exactly when runGroup says In progress and a machine is listed', () => {
  const ages = [0.5, 5, 14, 16, 20, 120];
  const docs = [];
  for (const a of ages) {
    docs.push(finished(a));
    docs.push(moving(a));
    docs.push(finished(a, { running: [] }));
    // A next wave waiting for approval: the list puts it there, never under
    // Running now, whatever the live fields still list.
    const waits = finished(a);
    waits.summary = Object.assign({}, waits.summary, { machines: 2, stateCounts: { MIGRATED: 1, PLANNED: 1 },
                                                       next: { wave: 'wave-2', waitsFor: 'approval' } });
    docs.push(waits);
  }
  docs.forEach((st, i) => {
    const r = row(`p/m${i}`, st);
    const t = tiles([r]);
    const expected = group(st) === 'In progress' && st.running.length > 0;
    eq(t.running.length === 1, expected, `${group(st)} ${st.updatedUtc}`);
    if (group(st) === 'Waiting for approval') { eq(t.running.length, 0, 'never in both'); eq(t.approval.length, 1, 'approval holds it'); }
  });
});

test('the overview asks runGroup for Running now, not the live list alone', () => {
  const src = pageSource(path.join(DASH, 'index.html'));
  const facts = src.match(/function migrationFacts\([\s\S]*?\n\}/)[0];
  ok(/group === 'In progress'/.test(facts), 'running counts only while the list says In progress');
});

run('overview-running-stale');
