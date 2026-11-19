/* CLAIM-AT-PLAN-1: a machine another migration holds, and a start it refused.
 *
 * Lab install, 2026-11-05: a new migration let a person add a machine that an
 * earlier migration still held, choose its target, check the quota, accept,
 * sign off and press Start. Only then did the service refuse it - and the Run
 * it step kept showing "Checking that it really started..." while the
 * Migrations page said the start did not work.
 *
 * Two halves, both RUN here, not read:
 *   - Choose the machines marks a held machine with the migration that holds
 *     it, from the run summary's `held` list (Get-VmfHeldMachines, the start
 *     check's own rule). It cannot be ticked, Add never takes it, and the
 *     mark says how to free it. A list the service could not read is said.
 *   - Run it reads the start's result by the Migrations page's rule
 *     (lastEngineFailure) and shows it in the Migrations page's words.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  return eval('(' + m[1] + ')');   // eslint-disable-line no-eval
};
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');   // eslint-disable-line no-eval
globalThis.fill = constArrow('fill');
globalThis.M_PAGE = constArrow('M_PAGE');
globalThis.subOfId = constArrow('subOfId');
globalThis.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase() };
const fns = liftAll('wizard.html', ['canChoose', 'chooseGroup', 'tagPairs', 'chooseRows', 'manaUpgradeText', 'anReleaseText', 'chooseMatches', 'chooseOptions',
  'chooseAdd', 'chooseRemove', 'chooseStart', 'chooseListHtml', 'heldFrom', 'chooseHeldNote', 'waveStartFailure', 'startFailedText', 'startWatchVerdict']);
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const lastEngineFailure = lift('migrations.html', 'lastEngineFailure');

const SUB = '00000000-0000-0000-0000-000000000000';
const id = (rg, name) => `/subscriptions/${SUB}/resourceGroups/${rg}/providers/Microsoft.Compute/virtualMachines/${name}`;
const vm = (name) => ({ vmId: id('rg-app', name), name, resourceGroup: 'rg-app', classification: 'ReadyAfterPrep', blockers: [], tags: {} });
const app = vm('app-01'), db = vm('db-01'), web = vm('web-07');
const ADVICE = [app, db, web].map(v => ({ vmId: v.vmId, name: v.name, options: [{ option: 'v6', supported: true }] }));
const canMigrate = () => true;
const nameOf = (x) => x.split('/').pop();
const NONE = { sub: '', rg: '', tag: '', name: '' };
// The summary as the service gives it: the id in another letter case than the
// assessment wrote it, which the page must still match.
const SUMMARY = { runId: 'new-scan', held: [{ vmId: db.vmId.replace('/rg-app/', '/RG-APP/'), name: 'db-01', heldBy: 'older-migration' }] };
const drawn = (html) => html.split('<tr>').slice(2).map(r => ({
  name: ([...r.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)][1] || [])[1],
  text: r.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(),
  disabled: /class="m-pick"[^>]* disabled/.test(r),
}));

test('RUN: the summary gives each held machine and its migration; no list is unknown, an empty list is none', () => {
  const held = fns.heldFrom(SUMMARY);
  eq(held.get(VmfHelp.idKey(db.vmId)), 'older-migration', 'matched whatever the letter case');
  eq(held.size, 1);
  eq(fns.heldFrom({ runId: 'x', held: [] }).size, 0, 'nothing held');
  eq(fns.heldFrom({ runId: 'x', held: null }), null, 'the service could not read the claims');
  eq(fns.heldFrom({ runId: 'x' }), null, 'an older service gives no list');
  eq(fns.heldFrom(null), null, 'no summary');
});

test('RUN: a held machine is marked with the migration that holds it, and cannot be ticked', () => {
  const rows = fns.chooseRows([app, db, web], ADVICE, nameOf, canMigrate, fns.heldFrom(SUMMARY));
  const dbRow = rows.find(r => r.name === 'db-01');
  eq(dbRow.heldBy, 'older-migration');
  eq(dbRow.tickable, false, 'a held machine cannot be chosen');
  eq(rows.find(r => r.name === 'app-01').tickable, true, 'a free one can');
  const list = drawn(fns.chooseListHtml(rows, new Set(), NONE, 50, (s) => s));
  const shown = list.find(r => r.name === 'db-01');
  ok(shown.disabled, 'its box is off');
  ok(shown.text.includes(fill(UX.mHeld, { run: 'older-migration' })), 'the row names the migration and says how to free it');
  ok(!list.find(r => r.name === 'app-01').text.includes('older-migration'), 'a free row says nothing of it');
  ok(UX.mHeld.includes('{run}'), 'the words name the migration');
});

test('RUN: Add never takes a held machine, and a saved list does not tick it again', () => {
  const rows = fns.chooseRows([app, db, web], ADVICE, nameOf, canMigrate, fns.heldFrom(SUMMARY));
  const added = fns.chooseAdd(new Set(), rows, NONE);
  ok(!added.has(db.vmId), 'Add leaves it out');
  eq(added.size, 2);
  const start = fns.chooseStart({ machines: [app.vmId, db.vmId] }, rows);
  ok(!start.has(db.vmId) && start.has(app.vmId), 'a machine saved before another migration took it is not ticked');
  const html = fns.chooseListHtml(rows, new Set(), NONE, 50, (s) => s);
  ok(html.includes(fill(UX.mAddShown, { n: 2 })), 'the Add button counts only the machines it can add');
});

test('RUN: with no held list every machine is as before, and an unknown list is said', () => {
  const rows = fns.chooseRows([app, db, web], ADVICE, nameOf, canMigrate);
  ok(rows.every(r => r.tickable && !r.heldBy), 'no list: nothing is marked');
  eq(fns.chooseHeldNote(new Map()), '', 'nothing to say when the list was read');
  ok(fns.chooseHeldNote(null).includes(esc(UX.mHeldUnknown)), 'the page says it could not check');
  eq(fns.chooseHeldNote(undefined), '', 'not asked yet: nothing to say');
});

test('RUN: the step asks the run summary once, with the project, and draws the list again when it lands', async () => {
  const calls = [];
  let painted = 0;
  const STEP = liftConst('wizard.html', 'STEP');
  Object.assign(globalThis, {
    runFullId: () => 'proj-a/new-scan', runSeg: () => 'new-scan', step: STEP.migrate.choose, STEP,
    targetAdvice: { machines: ADVICE }, $: (sel) => (sel === '#m-list' ? {} : null),
    heldFrom: fns.heldFrom, mHeld: undefined, mHeldFor: '',
    chooseRowsNow: () => {}, paintChooseList: () => { painted++; },
    api: async (...args) => { calls.push(args); return SUMMARY; },
  });
  globalThis.VmfHelp = { ...globalThis.VmfHelp, VmfRun: { withProject: (b, full) => ({ ...b, project: full.split('/')[0] }) } };
  const readHeld = lift('wizard.html', 'readHeld');
  await readHeld();
  eq(calls.length, 1);
  eq(calls[0], ['GET', 'runs/new-scan/summary', null, { held: 1, project: 'proj-a' }], 'the summary route, asking for the held list (held=1), the project in the query');
  eq(globalThis.mHeld.get(VmfHelp.idKey(db.vmId)), 'older-migration');
  eq(painted, 1, 'the list is drawn again with the marks');
  await readHeld();
  eq(calls.length, 1, 'once for each run, not at every drawing of the step');
  globalThis.mHeldFor = '';
  globalThis.api = async () => { throw new Error('HTTP 500'); };
  await readHeld();
  eq(globalThis.mHeld, null, 'a failed read is unknown, never free');
});

test('RUN: a machine ticked before the held list landed is taken out when it lands', () => {
  Object.assign(globalThis, {
    assessment: { vms: [app, db, web] }, targetAdvice: { machines: ADVICE }, vmName: nameOf,
    window: { VmfReport: { canMigrate } }, chooseRows: fns.chooseRows,
    mChosen: new Set([app.vmId, db.vmId]), mHeld: fns.heldFrom(SUMMARY), mRows: [],
  });
  lift('wizard.html', 'chooseRowsNow')();
  ok(!globalThis.mChosen.has(db.vmId), 'the held machine is no longer chosen');
  ok(globalThis.mChosen.has(app.vmId), 'the free one stays');
  eq(globalThis.mRows.find(r => r.name === 'db-01').heldBy, 'older-migration', 'and its row is marked');
});

// ---------- Run it: the start's result ----------
const at = (s) => new Date(Date.UTC(2026, 10, 5, 12, 20, s)).toISOString();
const REFUSAL = "Wave 'wave-1' cannot start: These machines are already part of another migration and cannot be in two at once: db-01 (in 'older-migration'). Finish or discard that one, or take them over deliberately.";
// The lines a refused start writes, in order: the service's start line, the
// engine's own start line, and the entrypoint's failure.
const REFUSED = [
  { tsUtc: at(1), step: 'engine', outcome: 'start', operation: 'wave', wave: 'wave-1', detail: 'hosted wave started by operator@example.com: go' },
  { tsUtc: at(40), step: 'engine:wave', outcome: 'start', detail: 'engine version' },
  { tsUtc: at(41), step: 'engine:wave', outcome: 'fail', detail: REFUSAL },
];

test('RUN: a refused start is found by the Migrations page rule, with the same event', () => {
  const f = fns.waveStartFailure(REFUSED);
  ok(f, 'the refusal is found');
  eq(f.detail, REFUSAL);
  eq(f, lastEngineFailure(REFUSED), 'the same event the Migrations page shows');
});

test('RUN: a refusal the product made counts too; a later start clears an older failure', () => {
  const refused = [{ tsUtc: at(2), step: 'engine:wave', outcome: 'refused', detail: 'no capacity' }];
  eq(fns.waveStartFailure(refused).detail, 'no capacity');
  eq(fns.waveStartFailure(refused), lastEngineFailure(refused));
  const again = [...REFUSED, { tsUtc: at(59), step: 'engine:wave', outcome: 'start', detail: 'engine version' }];
  eq(fns.waveStartFailure(again), null, 'the start after it is not refused yet');
  eq(lastEngineFailure(again), null, 'and the Migrations page agrees');
});

test('RUN: only the start of a wave - another operation that failed is not this start', () => {
  const restore = [{ tsUtc: at(3), step: 'engine:restore', outcome: 'fail', detail: 'refused put-back' }];
  eq(fns.waveStartFailure(restore), null);
  eq(fns.waveStartFailure([{ tsUtc: at(3), step: 'engine:wave', outcome: 'fail' }]), null, 'a failure with no reason is not shown, as on the Migrations page');
});

test('RUN: the words are the Migrations page words for a failed start of a wave', () => {
  const migrationsSays = UX_ACT.nextFailed.replace('{what}', UX_ACT.nextFailedWave).replace('{reason}', REFUSAL);
  eq(fns.startFailedText(REFUSAL), migrationsSays);
  ok(!fns.startFailedText(REFUSAL).includes(UX.watching), 'never "checking that it really started"');
});

test('RUN: the watch after Start says the refusal, and a start still beats nothing', () => {
  const verdict = fns.startWatchVerdict(REFUSED);
  ok(verdict && verdict.failure, 'the refusal is the verdict');
  eq(verdict.failure.detail, REFUSAL);
  eq(fns.startWatchVerdict([...REFUSED, { tsUtc: at(42), step: 'wave', outcome: 'start' }]).failure.detail, REFUSAL, 'a failure beats a start');
  eq(fns.startWatchVerdict([{ tsUtc: at(42), step: 'PRECHECK', outcome: 'start' }]), { started: true });
  eq(fns.startWatchVerdict(REFUSED.slice(0, 2)), null, 'the engine started and said nothing yet');
});

// The watch itself, with the page's surroundings stood in: the first window
// ends with no answer, the engine's refusal comes in the second.
test('RUN: after three minutes with no answer the page keeps watching, and says the refusal that comes later', async () => {
  const watch = { textContent: '', innerHTML: '', style: {} };
  const asked = [];
  const env = {
    $: (sel) => (sel === '#s5-watch' ? watch : null),
    esc, UX, blobText: async () => null, runPrefix: () => 'p/new-migration', location: {},
    VmfHelp: {
      readLogEvents: async () => [],
      watchRun: async (o) => { asked.push(o.timeoutMs); return asked.length === 1 ? null : { failure: { detail: REFUSAL } }; },
    },
  };
  const src = ['waveStartFailure', 'startFailedText', 'startWatchVerdict', 'watchForRefusal']
    .map(n => require('./_harness').extract('wizard.html', n)).join('\n');
  // eslint-disable-next-line no-new-func
  const watchForRefusal = new Function(...Object.keys(env), `${src}\nreturn watchForRefusal;`)(...Object.values(env));
  await watchForRefusal(at(0));
  eq(asked.length, 2, 'a second window after the first');
  ok(asked[1] > asked[0], 'and a longer one');
  eq(watch.textContent, fns.startFailedText(REFUSAL), 'the refusal is said where "Checking" was');
  eq(watch.style.color, 'var(--bad)');
});

test('RUN: Run it says a refused start when it is drawn again, above Start', async () => {
  const line = { textContent: '', style: { display: 'none' } };
  Object.assign(globalThis, {
    DEMO_MODE: false, runPrefix: () => 'p/new-migration', blobText: async () => null,
    $: (sel) => (sel === '#s5-failed' ? line : null),
    waveStartFailure: fns.waveStartFailure, startFailedText: fns.startFailedText,
  });
  globalThis.VmfHelp = { ...globalThis.VmfHelp, readLogEvents: async () => REFUSED };
  const paint = lift('wizard.html', 'paintStartFailure');
  await paint();
  eq(line.textContent, fns.startFailedText(REFUSAL));
  eq(line.style.display, '', 'shown');
  const quiet = { textContent: '', style: { display: 'none' } };
  globalThis.$ = (sel) => (sel === '#s5-failed' ? quiet : null);
  globalThis.VmfHelp.readLogEvents = async () => REFUSED.slice(0, 2);
  await paint();
  eq(quiet.style.display, 'none', 'nothing refused: nothing said');
  globalThis.VmfHelp.readLogEvents = async () => { throw new Error('502'); };
  await paint();
  eq(quiet.style.display, 'none', 'one bad read is not an answer');
  // The step draws the line's place and fills it at each drawing.
  const body = WIZ.slice(WIZ.indexOf('function renderStep5('), WIZ.indexOf('function markBusy('));
  ok(/id="s5-failed" role="alert"/.test(body), 'the place, as an alert');
  ok(/\n\s*paintStartFailure\(\);/.test(body), 'filled at each drawing of the step');
});

run('claim-at-plan');
