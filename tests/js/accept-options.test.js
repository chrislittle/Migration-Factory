/* ACCEPT-HASH-1: the acceptance dialog signs the settings it displayed.
 *
 * Accepting a wave's settings is the UNIVERSAL gate - approval is a lever a
 * wave may or may not carry, acceptance is required for every wave, always.
 * The record names a person and says they chose these levers.
 *
 * It drew the table from the CACHED plan - as old as the last refresh tick -
 * and then sent only the wave's name, so the service hashed whatever plan.json
 * held when the request landed. Two ways to record a signature over settings
 * nobody saw:
 *
 *   1. the table was already stale when the dialog opened
 *   2. an operator rewrote the wave while the dialog sat open
 *
 * Both are fixed by the same move: read the plan NOW, draw the table from
 * those exact bytes, and send their hash. So the test that matters is not
 * "does it send a hash" - it is "is the hash over the SAME bytes the person
 * read". A dialog that sent a fresh hash beside a stale table would be worse
 * than the defect, because the signature would then be provably wrong.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');
// WAVE-OPTIONS-DISKS-1: the REAL page function, which asks the real help.js rule.
global.diskChangeTexts = lift('migrations.html', 'diskChangeTexts');

// ---- the page around the function -----------------------------------------
let opened = null, sent = null, shownError = null, planText = null, readCount = 0;

global.DEMO_MODE = false;
global.currentRun = 'run-1';
global.planDoc = null;
global.esc = (s) => String(s);
global.vmName = (id) => String(id).split('/').pop();
global.runSeg = () => encodeURIComponent(global.currentRun);
global.newIdentityNames = () => [];
// AN-PLAN-1: the machines the plan turns accelerated networking on for.
global.anTurnsOnNames = () => [];
// WAVE-AN-NAMES-1: and the machines whose move decides it.
global.anDecidedNames = () => [];
// MANA-LINUX-KERNEL-1: the machines that update their kernel, and the wave's own
// driver setting, read from a machine without a decision of its own.
global.kernelUpdateNames = () => [];
global.leverKeepDays = (n) => `${Number(n ?? 7)} days`;
global.openModal = (opts) => { opened = opts; };
global.apiFetch = async (path, body) => { sent = { path, body }; return {}; };
// PLANVER-2: the page asks for the document AND the version the SERVICE issued
// for it, in one response. The stub moves with it - and it returns a version
// the page could not have computed, which is what proves the page QUOTES the
// service rather than working it out again.
global.source = {
  readVersioned: async () => {
    readCount++;
    if (planText === null) { throw new Error('403: no'); }
    return { text: planText, version: 'issued-by-the-service' };
  },
};
global.$ = () => ({ set textContent(v) { shownError = v; }, get textContent() { return shownError; }, style: {} });
// RUNID-2: the page now asks VmfHelp how a run is addressed. The REAL
// functions are lifted rather than faked - a stub that answers differently
// from the product is how a test agrees with itself.
const { runParse, runStorePath, runRouteSegment, runWithProject, runLink } =
  liftAll('help.js', ['runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink']);
global.VmfHelp = {
  // BSV2-TARGET-1: the wave summary names a Bsv2 size by its series.
  seriesLabel: lift('help.js', 'seriesLabel'),
  // SIGNOFF-NULL-1: the one rule for the sign-off row.
  approvalRequired: lift('help.js', 'approvalRequired'),
  // WAVE-OPTIONS-DISKS-1: the one rule for a machine's disk type change.
  diskUpgradeOf: lift('help.js', 'diskUpgradeOf'),
  // ROLLBACK-CAPACITY-1: the lines under the table, by the one rule.
  // SQL-TEMPDB-SIGNOFF-1: with the SQL Server rule it asks.
  signOffRiskLines: liftAll('help.js', ['signOffRiskLines', 'sqlTempdbEntries', 'sqlTempdbRisk']).signOffRiskLines,
  explainAction: (e) => `explained: ${e.message}`,
  VmfRun: { parse: runParse, storePath: runStorePath, routeSegment: runRouteSegment,
            withProject: runWithProject, link: runLink },
};
// IDENTITY-LOSS-1: the dialog names the machines whose identity it lets a
// rebuild delete, by the real rule and the real page helpers.
require('./_identity').help(global.VmfHelp);
require('./_identity').pageGlobals();

global.UX_LEVER = {
  safetyCopy: 'Safety copy', safetyCopyAlways: 'always',
  capacityGate: 'Capacity', capReserved: 'RESERVED', capOnDemand: 'ON DEMAND',
  requireApproval: 'Approval', yes: 'yes', no: 'no',
  onDDataFound: 'D data', dataProceed: 'go', dataStop: 'stop',
  onDriverBelowFloor: 'Driver', driverStop: 'stop',
  onSystemAssignedIdentity: 'Identity', identityProceed: 'go', identityStop: 'stop',
  identityMachines: 'Machines', identityNone: 'none',
  targetGen: 'Target', genV7: 'v7', genV6: 'v6',
  keepDays: 'Keep', atOnce: 'At once',
};
global.UX_ACT = {
  acceptOptionsTitle: 'Accept', acceptOptionsDesc: 'desc',
  acceptOptionsEdit: 'edit', acceptOptionsConfirm: 'Accept',
  acceptOptionsStale: 'THE WAVE CHANGED',
};

const planWith = (capacityGate, keepSnapshotDays) => JSON.stringify({
  entries: [{ vmId: '/x/vm1', wave: 'w1', path: 'A', assessment: {},
    policy: { capacityGate, keepSnapshotDays, requireApproval: false, targetGeneration: 'v6', throttle: 3 } }],
});

function reset() { opened = null; sent = null; shownError = null; readCount = 0; }

test('the table is drawn from the plan READ NOW, not from the cached one', async () => {
  /* THE DEFECT. The cache says the wave is reserved; the store says it is not.
   * A person reading the dialog must see what the wave will actually run
   * with - and it is what the acceptance is about to be bound to. */
  reset();
  global.planDoc = JSON.parse(planWith('Reserved', 7));
  planText = planWith('BestEffort', 7);
  await askAcceptOptions('w1');
  ok(opened, 'the dialog opened');
  ok(opened.desc.includes('ON DEMAND'), 'it shows what the store holds');
  eq(opened.desc.includes('RESERVED'), false, 'and not what the cache held');
});

test('the version sent is the one ISSUED WITH the bytes the table was drawn from', async () => {
  /* PLANVER-2 changed WHO computes this, and not what it has to mean.
   *
   * It used to be: the page hashes the text it drew the table from. That was
   * the right property and the wrong mechanism - it required the document to
   * travel byte for byte through a JSON service, and measured against a real
   * install on 2026-09-17, it does not. The page and the service produced
   * different values for the same blob, and the acceptance was refused for ever.
   *
   * Now the SERVICE issues the version over the bytes it read from the store
   * and returns it beside the document. The property is unchanged: the version
   * sent still describes exactly the text the table was drawn from, because
   * both came from ONE response.
   *
   * The stub returns a version the page could not possibly have computed, which
   * is what makes this prove the page QUOTES rather than derives. */
  reset();
  global.planDoc = JSON.parse(planWith('Reserved', 7));
  planText = planWith('BestEffort', 7);
  await askAcceptOptions('w1');
  await opened.onConfirm({});
  eq(sent.body.wave, 'w1', 'the wave');
  eq(sent.body.planHash, 'issued-by-the-service', 'the version the service issued with those bytes');
  ok(opened.desc.includes('ON DEMAND'), 'and the table really was drawn from the text that came with it');
});

test('the plan is read ONCE - the table and the hash cannot come from two reads', async () => {
  /* Reading twice, once to draw and once to hash, would leave a gap between
   * them: a smaller copy of the defect being fixed. */
  reset();
  planText = planWith('BestEffort', 7);
  await askAcceptOptions('w1');
  eq(readCount, 1, 'one read');
});

test('a plan that cannot be read opens NO dialog', async () => {
  /* The plan is what the acceptance signs. With nothing to bind agreement to,
   * the only safe answer is to not ask the question. */
  reset();
  planText = null;   // the read throws
  await askAcceptOptions('w1');
  eq(opened, null, 'no dialog');
  ok(String(shownError).startsWith('explained:'), 'and the action explainer says why');
});

test('the retention lever reaches the table, since that is the one that deletes things', async () => {
  // The example that makes this matter: snapshot retention lowered to 0 means
  // the safety copies go in the next daily cleanup.
  reset();
  planText = planWith('BestEffort', 0);
  await askAcceptOptions('w1');
  ok(opened.desc.includes('0 days'), 'the table shows what it will actually do');
});

test('a wave that changed under the person is reported as that, not as a fault', async () => {
  reset();
  planText = planWith('BestEffort', 7);
  await askAcceptOptions('w1');
  global.apiFetch = async () => { throw new Error('409: the wave changed after its settings were shown'); };
  let message = null;
  try { await opened.onConfirm({}); } catch (e) { message = e.message; }
  eq(message, 'THE WAVE CHANGED', 'the page says what happened in its own words');
  global.apiFetch = async (path, body) => { sent = { path, body }; return {}; };
});

test('any other failure keeps its own message', async () => {
  // Turning every failure into "the wave changed" would hide a real one.
  reset();
  planText = planWith('BestEffort', 7);
  await askAcceptOptions('w1');
  global.apiFetch = async () => { throw new Error('403: you do not hold that role'); };
  let message = null;
  try { await opened.onConfirm({}); } catch (e) { message = e.message; }
  eq(message, '403: you do not hold that role', 'passed through');
  global.apiFetch = async (path, body) => { sent = { path, body }; return {}; };
});

test('demo mode asks the store for nothing', async () => {
  // The sample data is the plan in demo mode; there is nothing to read and
  // nothing to sign.
  reset();
  global.DEMO_MODE = true;
  global.planDoc = JSON.parse(planWith('Reserved', 7));
  planText = null;
  await askAcceptOptions('w1');
  eq(readCount, 0, 'no read');
  ok(opened, 'the dialog still opens so the settings can be reviewed offline');
  ok(opened.desc.includes('RESERVED'), 'from the sample data');
  global.DEMO_MODE = false;
});

test('BSV2-TARGET-1: a machine on a Bsv2 size is counted under Bsv2, never v5, in the wave settings', async () => {
  const mk = (id, size) => ({ vmId: id, wave: 'w1', path: 'A', assessment: {}, target: { size },
    policy: { capacityGate: 'BestEffort', keepSnapshotDays: 7, requireApproval: false, targetGeneration: 'v5', throttle: 3 } });
  const was = global.UX_LEVER;
  global.UX_LEVER = Object.assign({}, was, { genV5: 'V5 WORDS', genBsv2: 'BSV2 WORDS', genMixed: 'Mixed: {parts}', genCount: '{n} on {series}' });
  try {
    reset();
    planText = JSON.stringify({ entries: [mk('/x/b1', 'Standard_B2s_v2'), mk('/x/d1', 'Standard_D2s_v5')] });
    await askAcceptOptions('w1');
    ok(opened.desc.includes('1 on Bsv2'), opened.desc);
    ok(opened.desc.includes('1 on v5'), opened.desc);
    reset();
    planText = JSON.stringify({ entries: [mk('/x/b1', 'Standard_B2s_v2')] });
    await askAcceptOptions('w1');
    ok(opened.desc.includes('BSV2 WORDS'), 'one Bsv2 machine alone has its own words');
    ok(!opened.desc.includes('V5 WORDS'), 'and not the words of v5');
  } finally { global.UX_LEVER = was; }
});
/* WAVE-OPTIONS-DISKS-1: the acceptance names each machine whose disk type the
 * move changes, and to which type. Seen in the lab on 2026-10-26: a wave
 * changed an OS disk to Standard SSD, and the dialog did not say so - while
 * the acceptance is recorded with the person's name.
 *
 * The words are the PAGE's own (liftConst), so the test proves what an
 * operator reads, in Azure's names - not a copy the test made. */
test('WAVE-OPTIONS-DISKS-1: each machine whose disk type changes is named with its new type; the others are not', async () => {
  const pageLever = liftConst('migrations.html', 'UX_LEVER');
  const was = global.UX_LEVER;
  global.UX_LEVER = Object.assign({}, was, {
    diskMachines: pageLever.diskMachines, diskMachine: pageLever.diskMachine,
    diskStandardSsdOs: pageLever.diskStandardSsdOs, diskPremiumOs: pageLever.diskPremiumOs,
    diskPremiumAll: pageLever.diskPremiumAll, identityNone: pageLever.identityNone,
  });
  const mk = (id, diskUpgrade, path = 'A') => ({ vmId: id, wave: 'w1', path, assessment: {},
    policy: Object.assign({ capacityGate: 'BestEffort', keepSnapshotDays: 7, requireApproval: false, targetGeneration: 'v6', throttle: 3 },
      diskUpgrade === undefined ? {} : { diskUpgrade }) });
  try {
    eq(pageLever.diskMachines, 'Machines whose disks change to Standard SSD or Premium SSD', 'the row says what it lists, in Azure names');
    eq(pageLever.diskStandardSsdOs, 'Standard SSD: OS disk', 'Azure\'s name, and the targets step\'s words');
    eq(pageLever.diskPremiumOs, 'Premium SSD: OS disk', 'Azure\'s name');
    eq(pageLever.diskPremiumAll, 'Premium SSD: every disk', 'Azure\'s name');
    reset();
    planText = JSON.stringify({ entries: [
      mk('/x/hdd', 'os-standard-ssd'), mk('/x/prem', 'os'), mk('/x/every', 'all'),
      mk('/x/kept'), mk('/x/unknown', 'something-else'),
      // A machine that does not move changes nothing, whatever its entry says.
      mk('/x/stays', 'all', 'none'),
    ] });
    await askAcceptOptions('w1');
    const row = opened.desc.split('<tr>').find(r => r.includes(pageLever.diskMachines));
    ok(row, 'the dialog has the row');
    ok(row.includes('hdd (Standard SSD: OS disk)'), row);
    ok(row.includes('prem (Premium SSD: OS disk)'), row);
    ok(row.includes('every (Premium SSD: every disk)'), row);
    eq(row.includes('kept'), false, 'a machine that keeps its disk types is not named');
    eq(row.includes('unknown'), false, 'a value the engine does not act on is not named - the engine keeps the disk types');
    eq(row.includes('stays'), false, 'a machine that does not move is not named');
    eq(row.includes(pageLever.identityNone), false, 'and the row does not also say None');
  } finally { global.UX_LEVER = was; }
});

test('WAVE-OPTIONS-DISKS-1: a wave that changes no disk type says None in this wave', async () => {
  const pageLever = liftConst('migrations.html', 'UX_LEVER');
  const was = global.UX_LEVER;
  global.UX_LEVER = Object.assign({}, was, { diskMachines: pageLever.diskMachines, identityNone: pageLever.identityNone });
  try {
    reset();
    planText = planWith('BestEffort', 7);
    await askAcceptOptions('w1');
    const row = opened.desc.split('<tr>').find(r => r.includes(pageLever.diskMachines));
    ok(row, 'the row is there when nothing changes, so its absence is never read as none');
    ok(row.includes(pageLever.identityNone), row);
  } finally { global.UX_LEVER = was; }
});

test('WAVE-OPTIONS-DISKS-1: the page reads the value the way the engine does (Get-VmfDiskUpgradeValue)', () => {
  /* PowerShell's -in ignores case, so the engine acts on OS as on os. Only
   * the three values are a change; anything else keeps the disk types. */
  const of = global.VmfHelp.diskUpgradeOf;
  eq(of({ policy: { diskUpgrade: 'os-standard-ssd' } }), 'os-standard-ssd', 'Standard SSD');
  eq(of({ policy: { diskUpgrade: 'os' } }), 'os', 'Premium OS');
  eq(of({ policy: { diskUpgrade: 'all' } }), 'all', 'Premium every disk');
  eq(of({ policy: { diskUpgrade: 'OS' } }), 'os', 'case as the engine ignores it');
  eq(of({ policy: { diskUpgrade: 'keep' } }), '', 'keep is no change');
  eq(of({ policy: {} }), '', 'absent is no change');
  eq(of({}), '', 'no policy is no change');
  eq(of(null), '', 'no entry is no change');
});
run('accept-options');
