/* RUNPICK-1, 2026-09-18. The run picker says which run you are looking at.
 *
 * WHAT THE PICKER SHOWED, on an install with exactly one run in it:
 *
 *   OTHER
 *   [idle]  vmf-drill-20260918-135309/drill-20260918-135309-migration-2026...
 *
 * Two separate failures, one symptom - a picker with nothing useful to say
 * about the only run there was.
 *
 * 1. THE NAME. A run inside a project is identified as `project/run`, and the
 *    whole string was shown as one line of monospace in a 380px panel, and
 *    again in the header button where it was cut off. Nobody could tell which
 *    run was open.
 *
 * 2. THE GROUP. A run planned and never started matched none of the groups and
 *    fell through to 'Other', shown as 'idle'. On a fresh install that is the
 *    only run there is, and the one somebody is about to act on.
 *
 * And a third that nobody had seen yet, found while fixing the second: a run
 * whose counts were an EMPTY OBJECT read as 'Completed', because every() over
 * no keys is true.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

/* OVERVIEW-SUMMARY-1: the group and the summary are help.js's now, so the
 * overview asks the list's own questions with the list's own code. Lifted
 * together, because runGroup calls runWaitingCount beside it. */
const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup']);
const { runGroup, runSummaryOf } = shared;
const runLabel = lift('migrations.html', 'runLabel');
const runTag = lift('migrations.html', 'runTag');

/* THE PANEL ITSELF, not only the two functions behind it.
 *
 * Twice today a correct function sat behind a caller that did not use it -
 * that is what broke Approve, and what the first machine-count test missed. So
 * the picker is drawn here and read back as markup. */
const picker = liftAll('migrations.html', ['runLabel', 'renderRunPanel']);

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const HELP = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));

// eslint-disable-next-line no-eval
const PAGE_GROUPS = eval((PAGE.match(/const RUN_GROUPS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
const PAGE_PILL = eval(`(${(PAGE.match(/const GROUP_PILL = (\{[^}]*\});/) || [])[1]})`);

/* APPROVE-GROUP-1: the code's own list. This test held a copy without
 * FAILED_ROLLED_BACK, so it said a rolled-back run was Other while the page
 * said Needs attention. OVERVIEW-SUMMARY-1: read from help.js, where runGroup
 * lives now. */
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
/* The window, read from the code, so the test cannot drift from it and
 * quietly stop covering the boundary it is about. */
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// APPROVE-GROUP-1: the gates that need a person, and the tags, as the code has them.
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.GROUP_TAG = liftConst('migrations.html', 'GROUP_TAG');
globalThis.VmfHelp = {
  runGateTag: shared.runGateTag,
  VmfRun: {
    parse(id) {
      const s = String(id ?? '');
      const cut = s.indexOf('/');
      if (cut <= 0) { return { project: null, run: s }; }
      return { project: s.slice(0, cut), run: s.slice(cut + 1) };
    },
  },
};

const NOW = Date.parse('2026-09-18T20:00:00Z');
const minutesAgo = (m) => NOW - (m * 60000);

test('the window the picker calls recent is fifteen minutes', () => {
  ok(RUN_ACTIVE_MS > 0, 'the page declares it, and this test read it');
  eq(RUN_ACTIVE_MS, 15 * 60000);
});

/* ---- the name --------------------------------------------------------- */

test('a run in a project shows the run, with the project under it', () => {
  const label = runLabel('vmf-drill-20260918-135309/drill-20260918-135309-migration-20260918-135356');
  eq(label.run, 'drill-20260918-135309-migration-20260918-135356');
  eq(label.project, 'vmf-drill-20260918-135309');
});

test('a run outside a project has no second line, rather than an empty one', () => {
  const label = runLabel('migration-20260918-135356');
  eq(label.run, 'migration-20260918-135356');
  eq(label.project, '', 'nothing to draw');
});

test('only the FIRST slash separates them - a run name may hold more', () => {
  const label = runLabel('proj/a/b');
  eq(label.project, 'proj');
  eq(label.run, 'a/b');
});

test('a run id that is missing does not paint the word undefined', () => {
  eq(runLabel(null).run, '');
  eq(runLabel(undefined).run, '');
  eq(runLabel(null).project, '');
});

/* ---- the group -------------------------------------------------------- */

/* OLD-VERSION-READERS-REMOVE-6: every status document the engine writes holds
 * the summary of the whole migration (Write-VmfRunStatusDocument), so the
 * group is read from it. A run with no status document never started; a
 * document with no summary this page can read cannot say more, and is Other. */
const ended = (counts, extra) => summaryOf('none', null, counts,
  Object.assign({ machines: Object.values(counts).reduce((n, v) => n + v, 0) }, extra || {}));

test('a run that was planned and never started says Planned, not Other', () => {
  /* THE REGRESSION. No status document at all, which is what the store holds
   * for a run nobody has started. It used to read "Other / idle". */
  eq(runGroup(false, null, 0, NOW), 'Planned');
});

test('a run whose machines are all still PLANNED says Planned', () => {
  eq(runGroup(false, { PLANNED: 3 }, minutesAgo(60), NOW, { summary: summaryOf('start', 'w1', { PLANNED: 3 }) }), 'Planned');
});

test('an EMPTY set of counts is not Completed', () => {
  /* The third defect, never reported: the old test was every() over the keys,
   * and every() over no keys is true - so a status written before any machine
   * had a state reported the run finished. */
  eq(runGroup(false, {}, minutesAgo(60), NOW, { summary: summaryOf('none', null, {}) }), 'Other');
});

test('a run with recent activity is In progress, whatever its counts', () => {
  eq(runGroup(false, { PLANNED: 1 }, minutesAgo(5), NOW, { summary: summaryOf('running', 'w1', { PLANNED: 1 }) }), 'In progress');
  eq(runGroup(false, null, minutesAgo(14), NOW), 'In progress');
});

test('activity older than the window no longer counts as in progress', () => {
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(16), NOW, { summary: ended({ MIGRATED: 2 }) }), 'Completed');
});

test('a machine needing a person beats every other group but setup', () => {
  eq(runGroup(false, { NEEDS_DECISION: 1, MIGRATED: 4 }, minutesAgo(60), NOW, { summary: ended({ NEEDS_DECISION: 1, MIGRATED: 4 }) }), 'Needs attention');
  eq(runGroup(false, { FAILED_NEEDS_ATTENTION: 1 }, minutesAgo(60), NOW, { summary: ended({ FAILED_NEEDS_ATTENTION: 1 }) }), 'Needs attention');
  /* Setup still wins: a run with no plan cannot have a machine in any state. */
  eq(runGroup(true, { NEEDS_DECISION: 1 }, minutesAgo(60), NOW, { summary: ended({ NEEDS_DECISION: 1 }) }), 'Still being prepared');
});

test('a finished run is Completed, counting skipped machines as finished', () => {
  eq(runGroup(false, { MIGRATED: 3 }, minutesAgo(60), NOW, { summary: ended({ MIGRATED: 3 }) }), 'Completed');
  eq(runGroup(false, { MIGRATED: 2, SKIPPED: 1 }, minutesAgo(60), NOW, { summary: ended({ MIGRATED: 2, SKIPPED: 1 }) }), 'Completed');
  /* Machines left PLANNED do not stop the rest being finished... */
  eq(runGroup(false, { MIGRATED: 2, PLANNED: 0 }, minutesAgo(60), NOW, { summary: ended({ MIGRATED: 2, PLANNED: 0 }) }), 'Completed');
});

test('a run that stopped part way is Other - it is none of the above', () => {
  eq(runGroup(false, { MIGRATED: 1, MIGRATING: 1 }, minutesAgo(60), NOW, { summary: ended({ MIGRATED: 1, MIGRATING: 1 }) }), 'Other');
  // A machine rolled back is one the page lists under Needs attention.
  eq(runGroup(false, { FAILED_ROLLED_BACK: 1 }, minutesAgo(60), NOW, { summary: ended({ FAILED_ROLLED_BACK: 1 }) }), 'Needs attention');
});

test('a state counted ZERO is not a machine in that state', () => {
  /* A status document lists the states it knows about, not only the ones with
   * machines in them. Reading a zero as presence would call a planned run
   * Other, and a finished one unfinished. */
  eq(runGroup(false, { PLANNED: 2, MIGRATING: 0 }, minutesAgo(60), NOW, { summary: summaryOf('start', 'w1', { PLANNED: 2, MIGRATING: 0 }) }), 'Planned');
  eq(runGroup(false, { MIGRATED: 2, MIGRATING: 0 }, minutesAgo(60), NOW, { summary: ended({ MIGRATED: 2, MIGRATING: 0 }) }), 'Completed');
  eq(runGroup(false, { NEEDS_DECISION: 0, MIGRATED: 1 }, minutesAgo(60), NOW, { summary: ended({ NEEDS_DECISION: 0, MIGRATED: 1 }) }), 'Completed');
});

test('every group the picker can produce is one the picker draws', () => {
  /* A group with no row in RUN_GROUPS is a run that VANISHES from the panel -
   * it is in runRows, matches no section, and is drawn by nothing. */
  const drawn = PAGE.match(/const RUN_GROUPS = \[([^\]]*)\]/);
  ok(drawn, 'RUN_GROUPS was found');
  const groups = drawn[1].split(',').map(s => s.trim().replace(/^'|'$/g, '')).filter(Boolean);
  const produced = [
    runGroup(true, null, 0, NOW),
    runGroup(false, null, 0, NOW, { summary: summaryOf('approval', 'w2', { MIGRATED: 2, PLANNED: 2 }) }),
    runGroup(false, null, 0, NOW),
    runGroup(false, null, minutesAgo(1), NOW),
    runGroup(false, { NEEDS_DECISION: 1 }, 0, NOW, { summary: ended({ NEEDS_DECISION: 1 }) }),
    runGroup(false, { MIGRATED: 1 }, 0, NOW, { summary: ended({ MIGRATED: 1 }) }),
    runGroup(false, { MIGRATING: 1 }, 0, NOW, { summary: ended({ MIGRATING: 1 }) }),
  ];
  eq(new Set(produced).size, 7, 'all seven groups are reachable');
  eq(groups.length, 7, 'and the panel draws no group nothing produces');
  for (const g of produced) { ok(groups.includes(g), `the panel draws '${g}'`); }
});
/* ---- the panel, drawn ------------------------------------------------- */

function drawPicker(rows, current) {
  const panel = { innerHTML: '', querySelector: () => null, querySelectorAll: () => [] };
  const name = { textContent: 'UNSET' };
  const project = { textContent: 'UNSET' };
  globalThis.$ = (sel) => ({
    '#run-panel': panel, '#run-current-name': name, '#run-current-project': project,
  })[sel] ?? null;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.ago = () => 'a while ago';
  globalThis.runIsRecent = () => true;
  globalThis.showOlderRuns = false;
  globalThis.reading = false;
  globalThis.RUN_WINDOW_DAYS = 14;
  globalThis.UX_MISC = {
    waiting: 'Reading your migrations.', noRuns: 'no migrations',
    continueSetup: 'Continue setup', rowProject: 'Project',
  };
  // The page's own tables, not a copy of them.
  globalThis.RUN_GROUPS = PAGE_GROUPS;
  globalThis.GROUP_PILL = PAGE_PILL;
  globalThis.GROUP_TAG = liftConst('migrations.html', 'GROUP_TAG');
  globalThis.runTag = runTag;
  globalThis.VmfHelp.VmfRun.link = (page, id) => `${page}?run=${id}`;
  globalThis.runRows = rows;
  globalThis.currentRun = current;
  picker.renderRunPanel();
  return { html: panel.innerHTML, name: name.textContent, project: project.textContent };
}

const DRILL = 'vmf-drill-20260918-135309/drill-20260918-135309-migration-20260918-135356';

test('the header names the RUN, and the project beside it', () => {
  /* THE REGRESSION. It used to be the whole 75-character id in one span, cut
   * off by the width of the header. */
  const out = drawPicker([{ r: DRILL, t: 0, group: 'Planned', setupOnly: false }], DRILL);
  eq(out.name, 'drill-20260918-135309-migration-20260918-135356');
  eq(out.project, 'vmf-drill-20260918-135309');
});

test('a run outside a project leaves the project label empty', () => {
  const out = drawPicker([{ r: 'migration-1', t: 0, group: 'Planned', setupOnly: false }], 'migration-1');
  eq(out.name, 'migration-1');
  eq(out.project, '', 'no separator is drawn for a project that is not there');
});

test('the header says it is reading before it says there is nothing', () => {
  globalThis.VmfHelp.VmfRun.link = () => '';
  const panel = { innerHTML: '', querySelector: () => null, querySelectorAll: () => [] };
  const name = { textContent: '' }; const project = { textContent: 'STALE' };
  globalThis.$ = (sel) => ({ '#run-panel': panel, '#run-current-name': name, '#run-current-project': project })[sel] ?? null;
  globalThis.runRows = []; globalThis.currentRun = null; globalThis.reading = true;
  picker.renderRunPanel();
  eq(name.textContent, 'Reading your migrations.');
  eq(project.textContent, '', 'the previous run does not linger in the header');
});

test('ONE run is drawn as ONE row, with no project line under it', () => {
  /* RUNROW-1, THE REGRESSION. A run id and its project share their timestamp,
   * so stacking them produced two long near-identical lines that read as two
   * separate runs. With every run in the same project the project tells them
   * apart from nothing, and the header already names it. */
  const out = drawPicker([{ r: DRILL, t: 0, group: 'Planned', setupOnly: false }], DRILL);
  ok(out.html.includes('drill-20260918-135309-migration-20260918-135356'), 'the run name');
  ok(!out.html.includes('class="rp"'), 'and no second line to mistake for a second run');
});

test('several runs in ONE project still draw no project line', () => {
  const out = drawPicker([
    { r: 'proj-a/migration-1', t: 0, group: 'Planned', setupOnly: false },
    { r: 'proj-a/migration-2', t: 0, group: 'Planned', setupOnly: false },
  ], 'proj-a/migration-1');
  ok(!out.html.includes('class="rp"'), 'the project separates nothing here');
});

test('runs from DIFFERENT projects each name their project', () => {
  /* The other half. Without the project these two rows are only told apart by
   * a name that may well repeat across projects. */
  const out = drawPicker([
    { r: 'proj-a/migration-1', t: 0, group: 'Planned', setupOnly: false },
    { r: 'proj-b/migration-1', t: 0, group: 'Planned', setupOnly: false },
  ], 'proj-a/migration-1');
  ok(out.html.includes('<span class="rp">Project proj-a</span>'), 'the first project');
  ok(out.html.includes('<span class="rp">Project proj-b</span>'), 'the second');
});

test('the project line is prefixed, so it cannot read as a run', () => {
  /* The word is the whole point. A bare project name under a run name is what
   * looked like a second entry. */
  const out = drawPicker([
    { r: 'proj-a/migration-1', t: 0, group: 'Planned', setupOnly: false },
    { r: 'proj-b/migration-1', t: 0, group: 'Planned', setupOnly: false },
  ], 'proj-a/migration-1');
  ok(!out.html.includes('<span class="rp">proj-a</span>'), 'never the bare name');
});

test('a run with no project alongside one with a project still separates them', () => {
  /* A loose run and a run in a project are two different things, and the loose
   * one has nothing to print - so the project must appear on the one that has
   * it, or the two rows carry the same amount of information. */
  const out = drawPicker([
    { r: 'proj-a/migration-1', t: 0, group: 'Planned', setupOnly: false },
    { r: 'migration-1', t: 0, group: 'Planned', setupOnly: false },
  ], 'migration-1');
  ok(out.html.includes('<span class="rp">Project proj-a</span>'), 'the one in a project says so');
});

test('the header still names the project, whatever the rows do', () => {
  /* It is left off the rows BECAUSE the header carries it. If that stopped
   * being true the project would vanish from the page entirely. */
  const out = drawPicker([{ r: DRILL, t: 0, group: 'Planned', setupOnly: false }], DRILL);
  eq(out.project, 'vmf-drill-20260918-135309');
  eq(out.name, 'drill-20260918-135309-migration-20260918-135356');
});

test('a planned run is drawn under Planned and tagged planned, not idle', () => {
  const out = drawPicker([{ r: DRILL, t: 0, group: 'Planned', setupOnly: false }], DRILL);
  ok(out.html.includes('>Planned</div>'), 'the group heading');
  ok(out.html.includes('>planned</span>'), 'the tag');
  ok(!out.html.includes('>idle</span>'), 'no longer idle');
});

test('the run being looked at is marked as selected', () => {
  /* "i can't tell which i'm on" - with more than one row this is the only
   * thing that says so. */
  const other = 'proj/migration-2';
  const out = drawPicker([
    { r: DRILL, t: 0, group: 'Planned', setupOnly: false },
    { r: other, t: 0, group: 'Planned', setupOnly: false },
  ], other);
  const rows = out.html.split('<button').filter(x => x.includes('data-run='));
  eq(rows.length, 2);
  eq(rows.filter(x => x.includes('class="row sel"')).length, 1, 'exactly one row is marked');
  ok(rows.find(x => x.includes(`data-run="${other}"`)).includes('sel'), 'and it is the one being looked at');
});

/* ---- APPROVE-GROUP-1: the summary of the whole migration ------------------
 *
 * WHAT WAS WRONG. The status document was a snapshot of ONE wave. A migration
 * whose wave 1 finished and whose wave 2 waited for approval read "every
 * machine MIGRATED" and was listed as Completed. One waiting for approval
 * before any wave ran had no document and was listed as Planned, beside
 * migrations nobody needs to touch. */

// The engine counts the machines that wait for a person (waitsOnPerson); here
// the stop states, unless a test gives its own count.
function summaryOf(waitsFor, wave, stateCounts, extra) {
  const stops = ["FAILED_ROLLED_BACK", "FAILED_NEEDS_ATTENTION", "NEEDS_DECISION"]
    .reduce((n, s) => n + (Number((stateCounts || {})[s]) || 0), 0);
  return Object.assign({ halted: false, machines: 4, stateCounts, waitsOnPerson: stops, waves: [], next: { wave, waitsFor } }, extra || {});
}

test('THE REGRESSION: wave 1 finished, wave 2 waits for approval - not Completed', () => {
  // The old document: wave 1's counts only, written when wave 1 ended.
  const waveOne = { MIGRATED: 2 };
  const s = summaryOf('approval', 'w2', { MIGRATED: 2, PLANNED: 2 });
  eq(runGroup(false, waveOne, minutesAgo(60), NOW, { summary: s }), 'Waiting for approval');
  // And the same document with no summary this page can read: it cannot tell.
  eq(runGroup(false, waveOne, minutesAgo(60), NOW), 'Other');
});

test('a migration whose first wave waits for approval is not Planned', () => {
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('approval', 'w1', { PLANNED: 4 }) }), 'Waiting for approval');
});

test('each gate that needs a person is Waiting for approval, and nothing else is', () => {
  for (const gate of ['acknowledgement', 'acceptance', 'approval']) {
    eq(runGroup(false, null, 0, NOW, { summary: summaryOf(gate, 'w1', { PLANNED: 4 }) }), 'Waiting for approval', gate);
  }
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('start', 'w1', { PLANNED: 4 }) }), 'Planned', 'ready to start');
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('unknown', 'w1', { PLANNED: 4 }) }), 'Planned', 'a gate it cannot name');
});

test('waiting for approval wins over the fifteen minutes after a wave ended', () => {
  // The wave's last write was a minute ago. The wave is over; the next waits.
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(1), NOW, { summary: summaryOf('approval', 'w2', { MIGRATED: 2, PLANNED: 2 }) }),
    'Waiting for approval');
  // But a wave that is running is In progress.
  eq(runGroup(false, { CONVERTING: 1 }, minutesAgo(1), NOW, { summary: summaryOf('running', 'w2', { MIGRATED: 2, CONVERTING: 1, PLANNED: 1 }) }),
    'In progress');
});

test('a wave still to run is never Completed', () => {
  const s = summaryOf('start', 'w2', { MIGRATED: 2, PLANNED: 2 });
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(60), NOW, { summary: s }), 'Planned');
});

test('every wave run and every machine finished is Completed', () => {
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(60), NOW, { summary: summaryOf('none', null, { MIGRATED: 3, SKIPPED: 1 }) }), 'Completed');
});

test('the summary counts the WHOLE migration - a problem in an earlier wave is seen', () => {
  // The live counts are the last wave's, all MIGRATED. Wave 1 had a machine stop.
  const s = summaryOf('none', null, { MIGRATED: 3, FAILED_ROLLED_BACK: 1 });
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(60), NOW, { summary: s }), 'Needs attention');
  // A machine waiting for a decision holds the run: that is Needs attention, not approval.
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('decision', 'w2', { NEEDS_DECISION: 1, MIGRATED: 1, PLANNED: 2 }) }), 'Needs attention');
});

test('a stopped or paused migration is Other, as the manual says', () => {
  const stopped = summaryOf('none', null, { MIGRATED: 1, SKIPPED: 3 }, { halted: true });
  eq(runGroup(false, null, 0, NOW, { summary: stopped }), 'Other');
  const paused = summaryOf('start', 'w2', { MIGRATED: 2, PLANNED: 2 }, { halted: true });
  eq(runGroup(false, null, 0, NOW, { summary: paused }), 'Other');
});

test('the engine said running and stopped writing: Other, not Planned', () => {
  eq(runGroup(false, { CONVERTING: 1 }, minutesAgo(60), NOW, { summary: summaryOf('running', 'w1', { CONVERTING: 1, PLANNED: 3 }) }), 'Other');
});

test('a paused migration whose next wave waits is Other - approving it starts nothing', () => {
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('approval', 'w2', { MIGRATED: 2, PLANNED: 2 }, { halted: true }) }), 'Other');
});

test('a machine that stopped is seen before an approval the next wave waits for', () => {
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('approval', 'w2', { MIGRATED: 1, FAILED_ROLLED_BACK: 1, PLANNED: 2 }) }), 'Needs attention');
});

test('a plan that moves no machine in a wave is Planned, as before', () => {
  eq(runGroup(false, null, 0, NOW, { summary: summaryOf('none', null, {}, { machines: 0 }) }), 'Planned');
});

test('setup still wins over a summary', () => {
  eq(runGroup(true, null, 0, NOW, { summary: summaryOf('approval', 'w1', { PLANNED: 1 }) }), 'Still being prepared');
});

test('OLD-VERSION-READERS-REMOVE-6: without a summary, no document is Planned and a document is Other - never Completed', () => {
  eq(runGroup(false, null, 0, NOW), 'Planned', 'no status document: the run never started');
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(60), NOW), 'Other', 'a document with no summary it can read');
  eq(runGroup(false, { MIGRATED: 2 }, minutesAgo(60), NOW, { planMachines: 2 }), 'Other', 'a plan count does not stand for a summary');
  eq(runGroup(false, { NEEDS_DECISION: 1 }, minutesAgo(60), NOW), 'Other', 'the live counts of one wave are not read for a stop');
});

test('only a summary this page can read is used - anything else is "cannot tell"', () => {
  const good = { schemaVersion: 7, summary: summaryOf('approval', 'w1', { PLANNED: 1 }) };
  ok(runSummaryOf(good), 'the summary the engine writes');
  eq(runSummaryOf({ schemaVersion: 7, stateCounts: { MIGRATED: 1 } }), null, 'a document with no summary');
  eq(runSummaryOf(null), null, 'no document');
  eq(runSummaryOf({ schemaVersion: 7, summary: { next: {} } }), null, 'a damaged one');
  eq(runSummaryOf({ schemaVersion: 7, summary: { next: { waitsFor: 'none' } } }), null, 'one with no counts');
  // OLD-VERSION-READERS-REMOVE-6: the engine writes the count of the machines
  // that wait for a person in every summary; a summary without a whole number
  // there is not read, and its stop states are not counted in its place.
  for (const bad of [undefined, null, -1, 1.5, '1']) {
    const s = Object.assign({}, good.summary, { waitsOnPerson: bad });
    eq(runSummaryOf({ schemaVersion: 7, summary: s }), null, `waitsOnPerson ${JSON.stringify(bad)}`);
  }
});

test('the tag says which thing to do: accept or approve', () => {
  eq(runTag('Waiting for approval', 'approval'), 'approve');
  eq(runTag('Waiting for approval', 'acceptance'), 'accept');
  eq(runTag('Waiting for approval', 'acknowledgement'), 'accept');
  eq(runTag('Planned', 'start'), 'planned');
  eq(runTag('Nonsense', null), 'idle');
});

test('a migration waiting for approval is drawn under its group, tagged with the action', () => {
  const out = drawPicker([
    { r: 'proj/migration-1', t: 0, group: 'Waiting for approval', setupOnly: false, waitsFor: 'approval' },
    { r: 'proj/migration-2', t: 0, group: 'Waiting for approval', setupOnly: false, waitsFor: 'acceptance' },
    { r: 'proj/migration-3', t: 0, group: 'Planned', setupOnly: false, waitsFor: 'start' },
  ], 'proj/migration-1');
  ok(out.html.includes('>Waiting for approval</div>'), 'the group heading');
  ok(out.html.includes('>approve</span>'), 'approve');
  ok(out.html.includes('>accept</span>'), 'accept');
  ok(out.html.indexOf('>Waiting for approval</div>') < out.html.indexOf('>Planned</div>'), 'above Planned');
});

test('age never hides a migration waiting for approval', () => {
  const runIsRecent = lift('migrations.html', 'runIsRecent');
  globalThis.currentRun = 'other';
  globalThis.RUN_WINDOW_DAYS = 14;
  const old = Date.now() - 60 * 86400000;
  ok(runIsRecent({ r: 'x', t: old, group: 'Waiting for approval' }), 'kept');
  ok(!runIsRecent({ r: 'x', t: old, group: 'Completed' }), 'a finished one of that age is hidden');
});

/* The page reads the summary from the status it already reads - no extra
 * read per run (STORE-READ-2) - and hands runGroup the summary only.
 * PERF-MIGRATIONS-TICK-1: the reads themselves are counted by running the
 * list in tests/js/migrations-tick.test.js; this holds the hand-over. */
test('the list hands runGroup the summary, from the reads it already makes', () => {
  const load = PAGE.slice(PAGE.indexOf('async function loadRuns('), PAGE.indexOf('async function start()'));
  ok(load.length > 1000, 'found loadRuns');
  ok(/const summary = VmfHelp\.runSummaryOf\(st\);/.test(load), 'the summary of the status');
  ok(!/planMachines|planMovingCount/.test(load), 'no plan count stands for the summary');
  ok(/VmfHelp\.runGroup\(setupOnly, counts, t, Date\.now\(\), \{ summary \}\)/.test(load), 'the summary');
  eq((load.match(/source\.readJson\(/g) || []).length, 1, 'the manifest only: the status and the plan come from the tick\'s reader');
});

run('run picker');
