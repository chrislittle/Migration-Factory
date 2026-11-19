/* NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is not shown.
 *
 * The wave editor's Remove puts a machine of the plan in no wave (wave
 * `unscheduled`, path A). The Migrations page listed it under "Not moved" as
 * Queued / In-place upgrade / not started, with no reason - but no wave takes
 * it, so it is not queued. Since 2026-11-12, a machine that is in no wave is
 * not shown on the Migrations page. It stays in the wave
 * editor's list of machines that are not in a wave, where a person adds it
 * back.
 *
 * The rule is ONE answer in two languages (tests/fixtures/entry-outside-run.json):
 * VmfHelp.outsideRun here, Test-VmfEntryOutsideRun in the engine. Every list
 * and every count of the run asks it - the waves, the Virtual machines tile,
 * the machine panel, and the Reports page row - so a count never includes a
 * machine the list hides.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const REPORTS = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'reports.html'));
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'entry-outside-run.json'), 'utf8')).cases;

// eslint-disable-next-line no-eval
globalThis.WORKING_STATES = eval(HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/)[1]);
const outsideRun = lift('help.js', 'outsideRun');
// outcomeCounts calls machineOutcome by name.
globalThis.machineOutcome = lift('help.js', 'machineOutcome');
globalThis.VmfHelp = {
  outsideRun,
  waveOrder: lift('help.js', 'waveOrder'),
  machineOutcome: lift('help.js', 'machineOutcome'),
  outcomeCounts: lift('help.js', 'outcomeCounts'),
  outcomeWaitsOnPerson: lift('help.js', 'outcomeWaitsOnPerson'),
};

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
const entry = (n, wave, p = 'A', extra) => ({ vmId: SUB + n, wave, path: p, ...(extra || {}) });
const doc = (n, state, extra) => ({ vmId: SUB + n, state, ...(extra || {}) });

/* A plan as an operator meets it: one machine in a wave, one a person removed
 * from its wave before it ran, one that rolled back and was then removed, one
 * the plan does not move, one already on its series, and a state document the
 * plan does not mention. */
const PLAN = {
  waveOrder: ['wave-1'],
  entries: [
    entry('in-wave', 'wave-1'),
    entry('removed', 'unscheduled'),
    entry('ran-then-removed', 'unscheduled'),
    entry('manual', 'unscheduled', 'MANUAL', { planNotes: ['This machine uses Azure Disk Encryption.'] }),
    entry('excluded', 'unscheduled', 'EXCLUDED'),
  ],
};
const DOCS = [doc('ran-then-removed', 'FAILED_ROLLED_BACK'), doc('no-entry', 'MIGRATED')];

// ---------- the one rule ----------

test('RUN: every shared case gives the answer the engine gives', () => {
  ok(CASES.length >= 12, 'the fixture loaded');
  for (const c of CASES) { eq(outsideRun(c.entry, c.doc), c.outside, c.name); }
});

test('RUN: no wave is the planner\'s word only - the waves the engine skips', () => {
  /* The engine skips a wave named unscheduled and nothing else (PlanRun,
   * RunSummary). The page's word unplanned names its own bucket for a state
   * document with no plan entry, never an entry's wave - so a wave a person
   * named unplanned runs, and its machines are shown. The wave editor and the
   * service refuse both names for a new wave. */
  for (const w of ['unscheduled', '', undefined, null]) { eq(outsideRun({ path: 'A', wave: w }, null), true, `wave ${JSON.stringify(w)}`); }
  for (const w of ['unplanned', 'Unscheduled', 'wave-1', 'new-wave-2']) { eq(outsideRun({ path: 'A', wave: w }, null), false, `wave ${JSON.stringify(w)}`); }
});

// ---------- the wave editor refuses the names the product uses ----------

test('RUN: the wave editor knows the names the product uses for no wave, in any case', () => {
  const WAVES = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  // eslint-disable-next-line no-eval
  globalThis.RESERVED_WAVE_NAMES = eval(WAVES.match(/const RESERVED_WAVE_NAMES = (\[[^\]]+\]);/)[1]);
  const reservedWaveName = lift('waves.html', 'reservedWaveName');
  for (const n of ['unscheduled', 'Unscheduled', 'UNSCHEDULED', 'unplanned', 'UnPlanned']) { eq(reservedWaveName(n), true, n); }
  for (const n of ['unscheduled-2', 'planned', 'wave-1', '', null]) { eq(reservedWaveName(n), false, String(n)); }
});

test('a rename to such a name keeps the name the wave had, and says why', () => {
  const WAVES = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  const at = WAVES.indexOf("document.querySelectorAll('[data-rename]')");
  const handler = WAVES.slice(at, WAVES.indexOf('}));', at));
  ok(/if \(reservedWaveName\(to\)\) \{\s*i\.value = from;/.test(handler), `the rename handler refuses it: ${handler.slice(0, 400)}`);
  ok(/UX\.nameReserved/.test(handler), 'and shows the words that say why');
  const UXW = liftConst('waves.html', 'UX');
  ok(/\{typed\}/.test(UXW.nameReserved), 'the words name what was typed');
});

// ---------- the waves of the Migrations page ----------

const waveGroups = lift('migrations.html', 'waveGroups');
const ids = (groups) => groups.map(([w, info]) => `${w}:${info.entries.map(e => e.vmId.split('/').pop()).join(',')}`);

test('RUN: a machine in no wave with no state document is not in any wave group', () => {
  const groups = waveGroups(PLAN, DOCS);
  const all = groups.flatMap(([, info]) => info.entries.map(e => e.vmId));
  ok(!all.includes(SUB + 'removed'), `the removed machine is not listed: ${ids(groups).join(' | ')}`);
});

test('RUN: a machine with a state document is shown, also in no wave - its history matters', () => {
  const groups = waveGroups(PLAN, DOCS);
  eq(ids(groups).join(' | '), 'wave-1:in-wave | unscheduled:ran-then-removed,manual,excluded | unplanned:no-entry');
});

test('RUN: MANUAL and EXCLUDED machines stay under Not moved', () => {
  const groups = waveGroups(PLAN, []);
  eq(ids(groups).join(' | '), 'wave-1:in-wave | unscheduled:manual,excluded');
});

test('RUN: a group with only hidden machines is not drawn at all', () => {
  const groups = waveGroups({ entries: [entry('a', 'wave-1'), entry('b', 'unscheduled')] }, []);
  eq(ids(groups).join(' | '), 'wave-1:a', 'no empty Not moved card');
});

test('RUN: the waves keep the order that runs, and machines not in a wave come last', () => {
  const plan = { waveOrder: ['w2', 'w1'], entries: [entry('a', 'w1'), entry('m', 'unscheduled', 'MANUAL'), entry('b', 'w2')] };
  eq(ids(waveGroups(plan, [doc('z', 'MIGRATED')])).join(' | '), 'w2:b | w1:a | unscheduled:m | unplanned:z');
});

test('RUN: no plan yet is not a crash', () => {
  eq(ids(waveGroups(null, [doc('a', 'MIGRATED')])).join(' | '), 'unplanned:a');
  eq(waveGroups(null, []).length, 0);
});

test('renderWaves draws the groups waveGroups gives', () => {
  const at = PAGE.indexOf('function renderWaves(');
  const body = PAGE.slice(at, PAGE.indexOf('\n}\n', at));
  ok(/const waves = waveGroups\(planDoc, allVms\);/.test(body), 'renderWaves builds its waves with waveGroups');
  ok(!/byWave\.set/.test(body), 'and builds no list of its own');
});

// ---------- the reasons of a machine the plan does not move ----------

test('RUN: a MANUAL machine still says why it is not moved', () => {
  globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
  globalThis.UX_FOUND = { Excluded: ['Excluded', 'Outside the scope of this tool.'] };
  globalThis.judgeForSeries = () => ({ classification: 'Blocked', blockers: [] });
  globalThis.reasonText = (r) => String(r);
  const notMovedReasons = lift('migrations.html', 'notMovedReasons');
  eq(notMovedReasons(PLAN.entries[3]).join(' | '), 'This machine uses Azure Disk Encryption.');
  eq(notMovedReasons(PLAN.entries[4]).join(' | '), globalThis.UX_MISC.notMovedAlready);
  eq(notMovedReasons(PLAN.entries[1]), null, 'the removed machine has no reason row: it is not drawn');
});

// ---------- the Virtual machines tile ----------

const kpis = liftAll('migrations.html', ['machinesInRun', 'renderKpis']);
function shownTile(vms, plan) {
  const el = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#kpis' ? el : null);
  globalThis.canOperate = () => false;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.UX_ACT = {};
  globalThis.renderRunActions = () => {};
  globalThis.statusCounts = () => ({ migrated: 0, restored: 0, rolledBack: 0, moving: 0, waiting: 0 });
  globalThis.machineStatusOf = () => ({ key: 'queued' });
  globalThis.planDoc = plan;
  kpis.renderKpis(vms, false);
  const m = el.innerHTML.match(/Virtual machines<\/div><div class="val">([^<]*)</);
  ok(m, 'the Virtual machines tile was painted and could be read');
  return m[1];
}

test('RUN: the count leaves out the machine the list leaves out', () => {
  // in-wave, ran-then-removed, manual, excluded, no-entry: five. Not six.
  eq(kpis.machinesInRun(DOCS, PLAN), 5);
});

test('RUN: the Virtual machines tile agrees with the waves', () => {
  const listed = waveGroups(PLAN, DOCS).reduce((n, [, info]) => n + info.entries.length, 0);
  eq(shownTile(DOCS, PLAN), String(listed), 'the tile and the rows count the same machines');
  eq(listed, 5);
});

// ---------- the machine panel ----------

test('RUN: an open panel of a machine that left the run closes on the next refresh', () => {
  const drill = { open: true, classList: { contains: () => drill.open } };
  globalThis.$ = (sel) => (sel === '#drill' ? drill : null);
  const drawn = [];
  globalThis.closeDrill = () => { drill.open = false; drawn.push('closed'); };
  globalThis.openDrill = (d, e, id) => { drawn.push('drawn ' + id.split('/').pop()); };
  const refreshDrill = lift('migrations.html', 'refreshDrill');
  globalThis.currentRun = 'p/r'; globalThis.drillRun = 'p/r';
  globalThis.planDoc = PLAN; globalThis.allVms = DOCS;

  globalThis.drillVmId = SUB + 'removed';
  eq(refreshDrill(), false);
  eq(drawn.join(','), 'closed', 'the panel of the removed machine closes');

  drawn.length = 0; drill.open = true;
  globalThis.drillVmId = SUB + 'ran-then-removed';
  eq(refreshDrill(), true);
  eq(drawn.join(','), 'drawn ran-then-removed', 'a machine with history keeps its panel');
});

// ---------- the Reports page row ----------

const summaryFromDocs = lift('reports.html', 'summaryFromDocs');

test('RUN: the Reports page counts neither the machine nor a "not started" for it', () => {
  const s = summaryFromDocs(PLAN.entries, DOCS);
  eq(s.total, 4, 'the four plan machines that are shown; the state document with no entry is not a plan machine');
  eq(s.outcomes.notStarted, 1, 'only in-wave waits to start');
  eq(s.outcomes.rolledBack, 1, 'the machine with history is counted');
  ok(!s.waves.some(w => w.total === 0), 'no wave of nothing');
});

test('RUN: a finished migration with a removed machine reads done, not going', () => {
  globalThis.UX = {};
  const outcomeState = lift('reports.html', 'outcomeState');
  const s = summaryFromDocs([entry('a', 'w1'), entry('b', 'unscheduled')], [doc('a', 'MIGRATED')]);
  eq(outcomeState({ total: s.total, working: s.outcomes.working, notStarted: s.outcomes.notStarted, attention: s.outcomes.attention }), 'done');
});

test('the Reports row takes its machine count from the summary', () => {
  const load = REPORTS.slice(REPORTS.indexOf('async function loadSummaries'), REPORTS.indexOf('function outcomeState'));
  ok(/total: Number\.isInteger\(s\?\.total\) \? s\.total : entries\.length/.test(load), 'the row reads the summary total');
});

test('RUN: the detail of a migration on the Reports page leaves the machine out of its waves and its total', async () => {
  const buildDetail = lift('reports.html', 'buildDetail');
  const files = { 'plan.json': PLAN, 'state/ran-then-removed.json': DOCS[0] };
  globalThis.detailCache = new Map();
  globalThis.source = {
    readJson: async (r, n) => files[n] ?? null,
    listFolder: async (r, folder) => (folder === 'state' ? ['state/ran-then-removed.json'] : []),
  };
  globalThis.VmfHelp.mapLimited = async (items, fn) => Promise.all(items.map(fn));
  globalThis.VmfHelp.machineName = (id) => String(id).split('/').pop();
  globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  globalThis.reservedInstances = () => 0;
  const d = await buildDetail('run-1');
  const listed = d.waves.flatMap(([, info]) => info.vms.map(e => e.vmId.split('/').pop()));
  ok(!listed.includes('removed'), `the removed machine is in no wave of the detail: ${listed.join(', ')}`);
  ok(listed.includes('ran-then-removed') && listed.includes('manual'), 'the others stay');
  eq(d.total, 4, 'its total');
  eq(d.onDemand, 4, 'and the machines it says run on demand');
});

// ---------- WAVE-REMOVE-NOT-SAVED-1: the wave editor's save ----------

const vmCtx = require('vm');
const { bootPage, settle } = require('./_dom');
async function wavesPage() {
  const r = bootPage('waves.html');
  await settle(r);
  vmCtx.runInContext('setTimeout = (fn) => { Promise.resolve().then(fn); return 0; };', r.sandbox);
  return r;
}
const inWaves = async (r, body) => JSON.parse(await vmCtx.runInContext(`(async () => { ${body} })()`, r.sandbox));

test('RUN: on the sample page, Remove then Save leaves the machine on the left, in no wave', async () => {
  const r = await wavesPage();
  const out = await inWaves(r, `
    const id = entries.find(e => e.vmId.endsWith('/prd-lin-c')).vmId;
    moveTo(null, [id]);
    await save();
    return JSON.stringify({ wave: DEMO_PLAN.entries.find(e => e.vmId === id).wave,
      left: unassigned().map(e => e.vmId.split('/').pop()),
      inCard: [...layout.values()].some(w => w.vmIds.includes(id)), dirty: dirty() });`);
  eq(out.wave, 'unscheduled', 'the saved plan has it in no wave');
  ok(out.left.includes('prd-lin-c'), `it is on the left after the page reads the plan again: ${out.left.join(', ')}`);
  ok(!out.inCard, 'and in no card');
  eq(out.dirty, false, 'nothing is left to save');
});

test('RUN: on the sample page, Delete of a wave then Save puts its machines on the left', async () => {
  const r = await wavesPage();
  const out = await inWaves(r, `
    const ids = layout.get('storefront-pilot').vmIds.slice();
    layout.delete('storefront-pilot');
    await save();
    return JSON.stringify({ waves: ids.map(id => DEMO_PLAN.entries.find(e => e.vmId === id).wave),
      left: unassigned().map(e => e.vmId), ids, cards: [...layout.keys()] });`);
  ok(out.ids.length >= 3, 'the wave had machines');
  ok(out.waves.every(w => w === 'unscheduled'), `each is in no wave: ${out.waves.join(', ')}`);
  ok(out.ids.every(id => out.left.includes(id)), 'and each is on the left');
  ok(!out.cards.includes('storefront-pilot'), 'the wave is gone');
});

test('RUN: on the sample page, Delete of every wave then Save sends no wave, and every machine is on the left', async () => {
  const r = await wavesPage();
  const out = await inWaves(r, `
    let sent = null;
    const post = apiPost;
    apiPost = async (p, body) => { if (/plan\\/waves$/.test(p)) { sent = body.waves; } return post(p, body); };
    const before = entries.map(e => e.vmId);
    for (const name of [...layout.keys()]) { layout.delete(name); }
    render();
    const saveOff = document.querySelector('#save').disabled === true;
    await save();
    return JSON.stringify({ sent, saveOff, cards: [...layout.keys()],
      waves: [...new Set(DEMO_PLAN.entries.filter(e => e.path === 'A').map(e => e.wave))],
      left: unassigned().map(e => e.vmId).sort(), before: before.sort(),
      err: document.querySelector('#err').style.display === 'block' ? document.querySelector('#err').textContent : '' });`);
  eq(JSON.stringify(out.sent), '[]', 'the save sends an empty list of waves');
  eq(out.saveOff, false, 'Save can be selected with no wave on the page');
  eq(out.err, '', 'no error');
  eq(out.cards.length, 0, 'no card');
  eq(out.waves.join(','), 'unscheduled', 'every machine to move is in no wave in the saved plan');
  eq(out.left.join(','), out.before.join(','), 'and every machine is on the left');
});

test('RUN: a save is refused while the page holds no plan version, and the service is not asked', async () => {
  const W = liftAll('waves.html', ['writeLayout']);
  const asked = [];
  Object.assign(globalThis, {
    DEMO_MODE: false, planVersion: '', layout: new Map([['wave-1', { vmIds: ['a'] }]]),
    waveMigrating: () => false, changedOf: () => ({}), resetOf: () => ({}),
    apiPost: async (p) => { asked.push(p); return {}; }, runSeg: () => 'r', runBody: (b) => b,
    UX: liftConst('waves.html', 'UX'),
  });
  let msg = '';
  try { await W.writeLayout(); } catch (e) { msg = e.message; }
  eq(msg, globalThis.UX.saveNoPlan, 'the page says why');
  eq(asked.length, 0, 'and nothing is sent');
});

test('a re-read of the plan that fails after a save says so, with the same words', () => {
  const WAVES = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  const at = WAVES.indexOf('async function writeLayout()');
  const body = WAVES.slice(at, WAVES.indexOf('\n}\n', at));
  ok(/if \(!DEMO_MODE && !planVersion\) \{ throw new Error\(UX\.saveNoPlan\); \}/.test(body), 'the refusal comes before the save is sent');
  ok(body.indexOf('UX.saveNoPlan') < body.indexOf("apiPost(`runs/${runSeg()}/plan/waves`"), 'before');
  ok(/if \(!DEMO_MODE && !planVersion\) \{ \$\('#warnbar'\)\.textContent = UX\.saveNoPlan;/.test(body), 'the warning after a failed re-read');
});

run('not-in-wave-queued');
