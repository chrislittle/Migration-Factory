/* OVERVIEW-SUMMARY-1, 2026-10-04. The overview counts the WHOLE migration.
 *
 * WHAT WAS WRONG. run-status.json was a snapshot of the running wave, and the
 * overview counted that wave only. A machine that stopped in wave 1 vanished
 * from "Waiting for a person" as soon as wave 2 wrote its own counts, and a
 * migration whose next wave waited for approval was not on the overview at
 * all - while the migrations list (APPROVE-GROUP-1) already listed it under
 * Waiting for approval, from the same document.
 *
 * WHAT IS TESTED. The overview's own functions, run against real-shaped
 * status documents, with the list's own grouping code from help.js - not a
 * copy of either. And the panels they paint, read back as markup.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const INDEX = pageSource(path.join(DASH, 'index.html'));

// The shared code, as help.js has it, with the constants it reads.
const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup', 'runTitle']);
// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.VmfHelp = Object.assign({}, shared, { waitingLine: (t) => `<p>${t}</p>` });

// The page's own furniture.
globalThis.UX = liftConst('index.html', 'UX');
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.ago = () => '';
globalThis.runLink = (id) => `migrations.html?run=${encodeURIComponent(id)}`;

const migrationFacts = lift('index.html', 'migrationFacts');
// PAGE-SCALE-OVERVIEW-1: the five tables became four tiles and one list.
const page = liftAll('index.html', ['overviewTiles', 'migrationRow', 'stoppedWaves']);

const NOW = Date.now();
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();

/* A status document as the engine writes it: the live fields of the wave in
 * `wave`, and the summary, with its count of the machines that wait for a
 * person (here the stop states, unless the test gives one). */
const STOPS = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
function doc(live, summary, extra) {
  const counts = (summary && summary.stateCounts) || {};
  const waiting = STOPS.reduce((n, s) => n + (Number(counts[s]) || 0), 0);
  return Object.assign({ schemaVersion: 7, runId: 'm1', wave: 'w2', updatedUtc: iso(60), stateCounts: live,
                         running: [], summary: Object.assign({ writtenUtc: iso(60), reason: 'waveEnded', halted: false,
                                                               machines: 4, waitsOnPerson: waiting, waves: [] }, summary) }, extra || {});
}

/* ---- the counts -------------------------------------------------------- */

test('THE REGRESSION: a machine that stopped in an earlier wave is still counted', () => {
  // Wave 2 ran last and every machine in it migrated. Wave 1 left two waiting.
  const st = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 4, FAILED_ROLLED_BACK: 1, NEEDS_DECISION: 1 },
                                  next: { wave: null, waitsFor: 'decision' } });
  eq(migrationFacts(st, 'running').attention, 2, 'the whole migration, not the last wave');
});

test('the summary wins over the live counts, both ways', () => {
  // The live wave shows a problem the summary has since counted: one number.
  const st = doc({ NEEDS_DECISION: 1, CONVERTING: 1 }, { stateCounts: { MIGRATED: 2, NEEDS_DECISION: 1, CONVERTING: 1 },
                                                       next: { wave: 'w2', waitsFor: 'running' } }, { updatedUtc: iso(1) });
  eq(migrationFacts(st, 'running').attention, 1);
  // And a problem the summary says is resolved is not counted from stale live fields.
  const fixed = doc({ NEEDS_DECISION: 1 }, { stateCounts: { MIGRATED: 4 }, next: { wave: null, waitsFor: 'none' } });
  eq(migrationFacts(fixed, 'finished').attention, 0);
});

test('A STATUS WITH NO SUMMARY IT CAN READ IS "NOT KNOWN", and one wave is never counted as the migration', () => {
  // OLD-VERSION-READERS-REMOVE-6: the engine writes the summary in every
  // status document. A document without one says nothing about the
  // migration, whatever its live counts say, either way.
  const none = { schemaVersion: 7, runId: 'm1', wave: 'w1', updatedUtc: iso(60), stateCounts: { NEEDS_DECISION: 1, MIGRATED: 3 } };
  eq(migrationFacts(none, 'running').attention, null, 'not known');
  const quiet = { schemaVersion: 7, runId: 'm1', wave: 'w1', updatedUtc: iso(60), stateCounts: { MIGRATED: 3 } };
  eq(migrationFacts(quiet, 'running').attention, null, 'no stop in the live counts is not a 0 either');
  const damaged = { schemaVersion: 7, wave: 'w1', stateCounts: { FAILED_NEEDS_ATTENTION: 2 }, summary: { next: {} } };
  eq(migrationFacts(damaged, 'running').attention, null);
  // A summary with no count of its own is not counted from its stop states.
  const noCount = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 3, NEEDS_DECISION: 1 }, next: { wave: null, waitsFor: 'decision' } });
  delete noCount.summary.waitsOnPerson;
  eq(migrationFacts(noCount, 'running').attention, null);
});

test('no status at all is nothing to show, not an error', () => {
  const f = migrationFacts(null, 'setup');
  eq(f.attention, 0);
  eq(f.waits, null);
  eq(f.running, 0);
});

test('Machines moving is still the running wave, from the live fields', () => {
  const st = doc({ CONVERTING: 2, PLANNED: 1 }, { stateCounts: { MIGRATED: 5, CONVERTING: 2, PLANNED: 1 },
                                                next: { wave: 'w2', waitsFor: 'running' } },
               { updatedUtc: iso(1), running: [{ vmId: 'a', state: 'CONVERTING' }, { vmId: 'b', state: 'CONVERTING' }] });
  const f = migrationFacts(st, 'running');
  eq(f.running, 2);
  eq(f.wave, 'w2');
});

/* ---- waiting for approval ---------------------------------------------- */

test('a migration whose next wave waits for approval is shown, with the action', () => {
  const st = doc(undefined, { stateCounts: { PLANNED: 4 }, next: { wave: 'w1', waitsFor: 'approval' } },
               { updatedUtc: undefined, wave: undefined });
  eq(migrationFacts(st, 'planned').waits, { wave: 'w1', tag: 'approve' });
  const accept = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 2, PLANNED: 2 }, next: { wave: 'w2', waitsFor: 'acceptance' } });
  eq(migrationFacts(accept, 'running').waits, { wave: 'w2', tag: 'accept' });
  const note = doc(undefined, { stateCounts: { PLANNED: 4 }, next: { wave: 'w1', waitsFor: 'acknowledgement' } });
  eq(migrationFacts(note, 'planned').waits.tag, 'accept');
});

test('nothing waits for a person: not shown', () => {
  for (const waitsFor of ['start', 'unknown', 'none', 'running']) {
    const st = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 2, PLANNED: 2 }, next: { wave: 'w2', waitsFor } });
    eq(migrationFacts(st, 'running').waits, null, waitsFor);
  }
});

test('a paused migration, or one with a machine stopped, is not waiting for approval', () => {
  const paused = doc({ MIGRATED: 2 }, { halted: true, stateCounts: { MIGRATED: 2, PLANNED: 2 }, next: { wave: 'w2', waitsFor: 'approval' } });
  eq(migrationFacts(paused, 'running').waits, null, 'approving it starts nothing');
  const stopped = doc({ MIGRATED: 1 }, { stateCounts: { MIGRATED: 1, FAILED_ROLLED_BACK: 1, PLANNED: 2 },
                                        next: { wave: 'w2', waitsFor: 'approval' } });
  const f = migrationFacts(stopped, 'running');
  eq(f.waits, null, 'the stopped machine is the more urgent thing');
  eq(f.attention, 1, 'and it is counted');
});

test('a status with no summary cannot say a wave waits for approval, so it says nothing', () => {
  const none = { schemaVersion: 7, wave: 'w1', updatedUtc: iso(60), stateCounts: { MIGRATED: 2 } };
  eq(migrationFacts(none, 'running').waits, null);
});

test('a run at setup is never waiting for approval', () => {
  const st = doc(undefined, { stateCounts: { PLANNED: 1 }, next: { wave: 'w1', waitsFor: 'approval' } });
  eq(migrationFacts(st, 'setup').waits, null);
});

/* ---- the same answer as the migrations list ---------------------------- */

test('the overview shows exactly what the list\'s own call puts under Waiting for approval', () => {
  // The list's own call, as loadRuns makes it: the live counts, the live time,
  // and the summary. Both sides run the ONE runGroup, so this proves the
  // overview hands it the same facts the list does and reads its answer - the
  // single copy is what makes the two pages agree.
  const listGroup = (st) => VmfHelp.runGroup(false, st?.stateCounts ?? null,
    st?.updatedUtc ? Date.parse(st.updatedUtc) : 0, Date.now(), { summary: VmfHelp.runSummaryOf(st) });
  const cases = [];
  for (const waitsFor of ['running', 'none', 'decision', 'acknowledgement', 'acceptance', 'approval', 'unknown', 'start']) {
    for (const halted of [false, true]) {
      for (const counts of [{ PLANNED: 4 }, { MIGRATED: 2, PLANNED: 2 }, { MIGRATED: 1, NEEDS_DECISION: 1, PLANNED: 2 }]) {
        for (const minutes of [1, 60]) {
          cases.push(doc({ MIGRATED: 2 }, { halted, stateCounts: counts, next: { wave: 'w2', waitsFor } }, { updatedUtc: iso(minutes) }));
        }
      }
    }
  }
  cases.push(null, { schemaVersion: 7, stateCounts: { MIGRATED: 2 }, updatedUtc: iso(60) });
  let waiting = 0;
  for (const st of cases) {
    const listed = listGroup(st) === 'Waiting for approval';
    if (listed) { waiting++; }
    eq(Boolean(migrationFacts(st, 'running').waits), listed, JSON.stringify(st && st.summary));
  }
  ok(waiting > 0, 'the cases include some the list calls Waiting for approval');
});

test('every page that keeps its own list of states that need a person keeps help.js\'s', () => {
  // help.js holds the list runGroup uses. Four pages keep a copy for their own
  // tables; a copy that drifted would be a page that disagrees with the list.
  const want = JSON.stringify(PROBLEM_STATES);
  ok(PROBLEM_STATES.length === 3, 'help.js declares it');
  for (const name of fs.readdirSync(DASH).filter(n => n.endsWith('.html'))) {
    const m = pageSource(path.join(DASH, name)).match(/const PROBLEM_STATES = (\[[^\]]*\]);/);
    // eslint-disable-next-line no-eval
    if (m) { eq(JSON.stringify(eval(m[1])), want, name); }
  }
});

/* Review finding 1: every test above lifts the functions straight from the
 * source, so a name dropped from the export list passed them all - and both
 * pages would then throw at run time, the list listing nothing and the
 * overview never finishing. The export list, read as code. */
test('help.js exports what both pages call', () => {
  const block = (HELP.match(/window\.VmfHelp = \{([\s\S]*?)\};/) || [])[1] || '';
  const names = block.split(',').map(s => s.trim()).filter(Boolean);
  ok(names.length > 20, 'the export list was read');
  for (const want of ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup']) {
    ok(names.includes(want), `VmfHelp.${want} is exported`);
  }
  // OLD-VERSION-READERS-REMOVE-6: the stop states of a status are not counted
  // in place of the engine's count any more.
  ok(!names.includes('runProblemCount'), 'no count from the stop states');
  // And every VmfHelp.run... call on the two pages is to an exported name.
  for (const file of ['index.html', 'migrations.html']) {
    const src = pageSource(path.join(DASH, file));
    for (const m of src.matchAll(/VmfHelp\.(run[A-Z]\w*)\(/g)) {
      ok(names.includes(m[1]), `${file} calls VmfHelp.${m[1]}, which help.js exports`);
    }
  }
});

test('the overview decides nothing itself: no list of its own, and the shared code is called', () => {
  ok(!/const PROBLEM_STATES/.test(INDEX), 'no second copy of the states');
  const facts = INDEX.slice(INDEX.indexOf('function migrationFacts('), INDEX.indexOf('const ago ='));
  ok(/VmfHelp\.runGroup\(/.test(facts), 'the list\'s grouping');
  ok(/VmfHelp\.runSummaryOf\(/.test(facts), 'the list\'s summary check');
});

test('and it reads one document per migration, as before - the status it already read', () => {
  const read = INDEX.slice(INDEX.indexOf('async function readRun('), INDEX.indexOf('function migrationFacts('));
  // Everything after the assessment branch returns: the migration's path.
  // PAGE-LOAD-1: the status is read with no stage check before it; the
  // listing the page holds says when it is not there (run-404.test.js).
  const cut = read.indexOf('const status = await blobJson(');
  ok(cut > 0, 'the migration part was found');
  const afterAssessment = read.slice(cut);
  eq((afterAssessment.match(/blobJson\(/g) || []).length, 1, 'one read for a migration');
  ok(/run-status\.json/.test(afterAssessment), 'and it is the status');
});

/* ---- the tiles, filled -------------------------------------------------
 * PAGE-SCALE-OVERVIEW-1: the five tables became four tiles and one list
 * (page-scale-overview.test.js). What each tile holds is still the rule each
 * table used. */

function tiles(runs) {
  const st = { projects: [{ id: 'p', name: 'P', assessments: 0, migrations: runs.length }], loose: [], runs };
  const out = {};
  for (const t of page.overviewTiles(st)) { out[t.key] = t.rows; }
  return out;
}
const row = (id, st) => Object.assign({ id, kind: 'migration', projectId: 'p', when: null }, migrationFacts(st, 'running'));

test('the overview lists a migration waiting for approval, with its wave and action', () => {
  const st = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 2, PLANNED: 2 }, next: { wave: 'wave-<2>', waitsFor: 'approval' } });
  const t = tiles([row('p/m-approve', st)]);
  eq(t.approval.map(r => r.id), ['p/m-approve'], 'the tile');
  eq(t.approval[0].next.text, UX.approvalTag.replace('{tag}', 'approve').replace('{wave}', 'wave-<2>'), 'the action and the wave');
  eq(t.person.length, 0, 'and not under Waiting for a person');
});

test('a "not known" count is LISTED and says so - never dropped, never a number', () => {
  const none = { schemaVersion: 7, wave: 'w1', updatedUtc: iso(60), stateCounts: { NEEDS_DECISION: 3, MIGRATED: 1 } };
  const t = tiles([row('p/m-old', none)]);
  eq(t.person.length, 1, 'listed under Waiting for a person');
  eq(t.person[0].machines, { text: UX.attentionUnknown, tone: 'muted' }, 'not known, not the count of one wave');
});

test('the count of the whole migration is what Waiting for a person shows', () => {
  const st = doc({ MIGRATED: 2 }, { stateCounts: { MIGRATED: 4, FAILED_ROLLED_BACK: 1, NEEDS_DECISION: 1 },
                                  next: { wave: null, waitsFor: 'decision' } });
  eq(tiles([row('p/m-two', st)]).person[0].machines, { text: '2', tone: 'bad' });
});

test('nothing waiting: neither tile holds it', () => {
  const st = doc({ MIGRATED: 4 }, { stateCounts: { MIGRATED: 4 }, next: { wave: null, waitsFor: 'none' } });
  const t = tiles([row('p/m-done', st)]);
  eq(t.approval.length, 0, 'not waiting for approval');
  eq(t.person.length, 0, 'not waiting for a person');
});

run('overview-summary');
