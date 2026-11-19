/* ADVISOR-1: the "Choose each target" step of the wizard.
 *
 * RUN, not read, where the logic lives in functions: the page's own
 * advPick / advSummary / advDetailRows / advWhy are driven with the page's own
 * words, against a machine shaped like the engine's target-advice.json.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// SQL-TEMPDB-SIGNOFF-1: tTargetRow asks tSqlFound, which reads the page's
// assessment. None was read here, so no machine has the SQL Server finding.
globalThis.assessment = null;
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['seriesLabel', 'machineStarted']));

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
globalThis.reasonText = (code) => ((reasons.blockers[code] || reasons.prep[code] || {}).title || String(code));
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.shortSize = constArrow('shortSize');
globalThis.fill = constArrow('fill');
const fns = liftAll('wizard.html', ['advSeriesLabel', 'sizeOf', 'advPick', 'advWhy', 'advSummary', 'advGroups', 'tDefSeries', 'advDetailRows', 'deriveStep', 'adviceProgress', 'advGenLabel', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tRecommended']);
globalThis.advPick = fns.advPick;

const opt = (option, supported, extra) => Object.assign({
  option, supported, notSupported: supported ? [] : ['not-in-region'], targetSize: supported ? `Standard_D2ds_${option}` : null,
  move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion', rebuild: false, tempDisksFrom: 1, tempDisksTo: 1,
  targetStage: { stage: option === 'v5' ? 'Extended' : 'Current', basis: 'stated' }, stageChange: option === 'v5' ? 'same' : 'up',
  acceleratedNetworking: { required: false, mayUseMana: true, turnsOn: false }, stops: [] }, extra || {});
const app = { vmId: '/vm/app-01', name: 'app-01', sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', acceleratedNicCount: 1,
  sourceStage: { stage: 'Extended', basis: 'stated' }, options: [opt('v5', true), opt('v6', true), opt('v7', false)],
  start: { current: 'v6', extended: 'v5' } };
const legacy = { vmId: '/vm/legacy-01', name: 'legacy-01', sourceSize: 'Standard_D2s_v4', diskController: '', acceleratedNicCount: 1,
  sourceStage: { stage: 'Extended', basis: 'stated' },
  options: [opt('v5', true), Object.assign(opt('v6', false), { notSupported: ['gen1-requires-redeploy'] }),
            Object.assign(opt('v7', false), { notSupported: ['gen1-requires-redeploy'] })],
  start: { current: 'v5', extended: 'v5' } };
const old = { vmId: '/vm/old-03', name: 'old-03', sourceSize: 'Standard_D2s_v3', options: [opt('v5', false), opt('v6', false)], start: { current: null, extended: null } };

test('each machine starts on the default, and a change overrides only that machine', () => {
  eq(fns.advPick(app, 'current', new Map()), 'v6');
  eq(fns.advPick(app, 'extended', new Map()), 'v5');
  eq(fns.advPick(app, 'current', new Map([['/vm/app-01', 'v5']])), 'v5');
  eq(fns.advPick(old, 'current', new Map()), null);
});

test('v7 is a choice next to v6, not a fallback: listed and pickable wherever it is supported', () => {
  const both = Object.assign({}, app, { options: [opt('v5', true), opt('v6', true), opt('v7', true)] });
  eq(fns.advPick(both, 'current', new Map()), 'v6', 'the default stays v6');
  eq(fns.advPick(both, 'current', new Map([[both.vmId, 'v7']])), 'v7', 'and a person can pick v7');
  // TARGETS-AREAS-1: the row is drawn by tTargetRow, lifted out of renderTargets.
  const render = WIZ.slice(WIZ.indexOf('function tTargetRow('), WIZ.indexOf('function tTargetRow(') + 1200);
  ok(render.includes('const supported = (m.options ?? []).filter(o => o.supported);'), 'the list is every supported option, no series left out');
  const demo = JSON.parse(WIZ.match(/'demo-scan\/target-advice\.json': (\{.*\}),\n/)[1]);
  const gen2 = demo.machines.filter(m => m.gen === 'V2');
  ok(gen2.length && gen2.every(m => m.options.find(o => o.option === 'v6').supported && m.options.find(o => o.option === 'v7').supported),
    'the sample shows v7 next to v6 for every Generation 2 machine');
});

test('the summary counts each target and the machines with none', () => {
  eq(fns.advSummary([app, legacy, old], 'current', new Map()), '3 machines: 1 on v5 · 1 on v6 · 1 with no target.', 'a sentence now (ADVISE-AN-1, 2026-10-12)');
});

test('v4 to v5 stays Extended, says no change, and never says newer', () => {
  const life = fns.advDetailRows(app, 'v5').find(([k]) => k === UX.dLife)[1];
  ok(life.includes('Extended  →  Extended'), life);
  ok(life.includes(UX.vNoChange), life);
  ok(!/newer|upgrade|current/i.test(life), life);
});

test('the details say before and after for every fact, and rollback', () => {
  const rows = fns.advDetailRows(app, 'v6');
  const keys = rows.map(([k]) => k);
  for (const k of [UX.dSize, UX.dKind, UX.dController, UX.dTemp, UX.dAn, UX.dLife, UX.dRollback]) ok(keys.includes(k), k);
  eq(rows.find(([k]) => k === UX.dController)[1], 'SCSI  →  NVMe');
});

test('a move Intel D v5 stops for says so in the details', () => {
  const m = Object.assign({}, app, { acceleratedNicCount: 0, options: [opt('v5', true, {
    acceleratedNetworking: { required: true, mayUseMana: true, turnsOn: true }, stops: ['acceleratedNetworkingRequired'] })] });
  const rows = fns.advDetailRows(m, 'v5');
  eq(rows.find(([k]) => k === UX.dAn)[1], `${UX.vOff}  →  ${UX.vOnRequired}`);
  ok(rows.some(([k, v]) => k === UX.dApproval && v === UX.vApprovalStop), 'the approval stop is shown');
});

test('an option that cannot be chosen shows the fact that stops it', () => {
  eq(fns.advWhy(legacy.options[1]), reasons.blockers['gen1-requires-redeploy'].title);
  eq(fns.advWhy(legacy.options[2]), reasons.blockers['gen1-requires-redeploy'].title);
});

test('every reason the options can carry has words on this page', () => {
  const schema = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'target-advice.schema.json'), 'utf8'));
  for (const code of schema.$defs.reason.enum) {
    const words = UX.whyNot[code] || (reasons.blockers[code] || {}).title;
    ok(Boolean(words), `no words for ${code}`);
  }
});

test('the save sends both versions the service issued', () => {
  // The whole function, up to the next one: ADVISE-AN-1 put the check of the
  // machines still to choose first, and a fixed length cut the POST off.
  const from = WIZ.indexOf('async function saveTargets(');
  const save = WIZ.slice(from, WIZ.indexOf("document.addEventListener('keydown'", from));
  ok(/assessments\/\$\{runSeg\(\)\}\/targets/.test(save), 'posts to the targets endpoint');
  ok(save.includes('adviceVersion, choicesVersion'), 'quotes both versions back');
  // OLD-SKU-1B: the body is built by targetChoicesBody, which saveTargets calls.
  const body = WIZ.slice(WIZ.indexOf('function targetChoicesBody('), WIZ.indexOf('async function saveTargets('));
  ok(save.includes('targetChoicesBody('), 'the body comes from targetChoicesBody');
  ok(body.includes('}).filter(c => c.option);'), 'a machine with no target sends nothing');
});

test('Escape closes the details on this step only, and each Details button turns into Close', () => {
  // OLD-SKU-1A: the same handler closes an open (?) as well.
  ok(WIZ.includes("e.key === 'Escape' && step === STEP.migrate.targets && (tOpen.size || tHelp.size)) { tOpen.clear(); tHelp.clear(); render(); }"), 'an Escape handler held to this step');
  ok(WIZ.includes('open ? UX.tClose : UX.tDetails'), 'one button, two states');
});

test('a saved step leaves nothing open or ticked behind', () => {
  // PRICE-EXPORT-1: the whole function, not its first 900 characters - it grew
  // the export path. tests/js/pricing-export.test.js RUNS this too.
  const save = WIZ.slice(WIZ.indexOf('async function saveTargets('), WIZ.indexOf("document.addEventListener('keydown'", WIZ.indexOf('async function saveTargets(')));
  // ADVISE-AN-1 (2026-10-12): no tick boxes any more, so only Details close.
  ok(save.includes('tOpen = new Set();') && !save.includes('tSelected'), 'Details cleared, and no selection to clear');
});

// ADVISE-AN-1 (2026-10-12): the tick boxes and Change the selected machines
// to are gone - the defaults and each machine's own list replace them.
test('no tick boxes: nothing reads or draws a selection', () => {
  ok(!WIZ.includes('tSelected') && !WIZ.includes('t-pick'), 'no selection and no boxes');
});

test('RUN: the waiting state is read from the log', () => {
  const start = { step: 'engine', outcome: 'start', detail: 'hosted advise started by user@example.com (execution x)' };
  eq(fns.adviceProgress([]).kind, 'none', 'nothing started: offer Make');
  eq(fns.adviceProgress([{ step: 'engine', outcome: 'start', detail: 'hosted assess started by a' }]).kind, 'none', 'a scan is not the options');
  eq(fns.adviceProgress([start]).kind, 'running', 'started: no second job');
  eq(fns.adviceProgress([start, { step: 'engine:advise', outcome: 'info', detail: 'Engine version 0.1.0 started the advise operation.' }]).kind, 'running');
  const f = fns.adviceProgress([start, { step: 'engine:advise', outcome: 'fail', detail: 'boom' }]);
  eq(f.kind, 'failed'); eq(f.detail, 'boom');
  eq(fns.adviceProgress([start, { step: 'engine:advise', outcome: 'refused', detail: 'no' }]).kind, 'failed', 'a refusal is not a job still running');
  eq(fns.adviceProgress([start, { step: 'engine:advise', outcome: 'fail', detail: 'x' }, start]).kind, 'running', 'a new start after a failure runs again');
  eq(fns.adviceProgress([start, { step: 'advice', outcome: 'ok', detail: 'y' }]).kind, 'done');
});

test('Make is hidden while a job runs, and the failure is written as text', () => {
  // TARGET-OPTIONS-WAIT-1: drawn by paintAdviceView, and RUN in
  // tests/js/target-options-wait.test.js.
  const body = WIZ.slice(WIZ.indexOf('function paintAdviceView('), WIZ.indexOf('async function paintAdviceProgress('));
  ok(body.includes("if (make) { make.style.display = 'none'; }"), 'hidden while running');
  ok(body.includes("w.textContent = UX.tFailed.replace('{reason}', () => v.detail);"), 'engine words are never parsed as HTML');
  ok(WIZ.includes('<button class="btn" id="t-make" style="display:none">'), 'hidden until the log says otherwise');
});

// MACHINE-PICK-1 rewrote this test. The migrate journey used to START at this
// step; the machines are chosen first now, so it starts there, and comes here
// once they are chosen - until targets are saved against THAT list.
test('RUN: before a plan, the migrate journey comes to this step once the machines are chosen, until targets are saved', () => {
  globalThis.STEP = liftConst('wizard.html', 'STEP');
  globalThis.readFailed = false; globalThis.journey = 'migrate'; globalThis.plan = null; globalThis.states = new Map();
  globalThis.location = { search: '?run=r&plan=1' };
  globalThis.wantsTargetsStep = constArrow('wantsTargetsStep');
  globalThis.wantsChooseStep = constArrow('wantsChooseStep');
  globalThis.wantsRunStep = constArrow('wantsRunStep');
  globalThis.wantsGroupStep = constArrow('wantsGroupStep');
  // WIZARD-WAVES-STEP-1: is this run a migration (its run.json, or from= in the address).
  globalThis.planningFrom = constArrow('planningFrom'); globalThis.isMigration = constArrow('isMigration');
  globalThis.targetsFitMachines = liftAll('wizard.html', ['targetsFitMachines']).targetsFitMachines;
  globalThis.targetChoices = null; globalThis.manifest = null; globalThis.machineChoices = null; globalThis.machinesVersion = '';
  eq(fns.deriveStep(), STEP.migrate.choose, 'nothing chosen: the machines first');
  globalThis.machineChoices = { machines: ['/vm/a'] }; globalThis.machinesVersion = 'm1';
  eq(fns.deriveStep(), STEP.migrate.targets, 'machines chosen: this step');
  globalThis.manifest = { kind: 'migration' };
  ok(fns.deriveStep() !== STEP.migrate.targets, 'a migration is past this step');
  globalThis.manifest = null;
  globalThis.targetChoices = { choices: [], machinesVersion: 'm1' };
  eq(fns.deriveStep(), STEP.migrate.group, 'targets saved against this list go on to grouping');
  globalThis.targetChoices = { choices: [], machinesVersion: 'm0' };
  eq(fns.deriveStep(), STEP.migrate.targets, 'targets saved against an earlier list come back here');
  globalThis.targetChoices = { choices: [], machinesVersion: 'm1' };
  globalThis.location = { search: '?run=r&plan=1&step=targets' };
  eq(fns.deriveStep(), STEP.migrate.targets, 'and a link can ask for it again');
  // OLD-VERSION-READERS-REMOVE-6: the wizard saves the list before any
  // target, so saved targets never stand for it: with no list the machines
  // step comes first, even when a link names the targets step.
  globalThis.machineChoices = null; globalThis.machinesVersion = ''; globalThis.targetChoices = { choices: [] };
  globalThis.location = { search: '?run=r&plan=1' };
  eq(fns.deriveStep(), STEP.migrate.choose, 'targets with no list: the machines step first');
  globalThis.location = { search: '?run=r&plan=1&step=targets' };
  eq(fns.deriveStep(), STEP.migrate.choose, 'a link that asks for the targets: still the machines first');
  eq(globalThis.targetsFitMachines({ choices: [], machinesVersion: '' }, null, ''), false, 'targets never fit no list');
});

test('planning no longer names one series for every machine', () => {
  const build = WIZ.slice(WIZ.indexOf('async function buildWaves('), WIZ.indexOf('async function buildWaves(') + 1500);
  ok(!/body\.targetGeneration\s*=/.test(build), 'buildWaves must not send a series');
});

test('options from an older version read as not made, so the step offers to make them again', () => {
  ok(WIZ.includes('av.doc?.schemaVersion === TARGET_ADVICE_VERSION ? av.doc : null'), 'an older file is not used');
  // TARGET-OPTIONS-WAIT-1: only for a file that is there (adviceOld); written
  // and not read yet is a wait. RUN in tests/js/target-options-wait.test.js.
  ok(WIZ.includes("p.kind === 'none' || (p.kind === 'done' && oldOnFile)"), 'and Make is offered');
  const ps = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'plan', 'Advice.ps1'), 'utf8');
  const engine = ps.match(/function Get-VmfTargetAdviceSchemaVersion \{ (\d+) \}/)[1];
  ok(WIZ.includes(`const TARGET_ADVICE_VERSION = ${engine};`), 'the page and the engine agree on the version');
});

test('the two defaults are Microsoft lifecycle stages, in words and in values', () => {
  eq(UX.tCurrent, 'Current'); eq(UX.tExtended, 'Extended');
  // From the row and area functions (TARGETS-AREAS-1) to the end of the step.
  ok(!/newest|smallest/i.test(WIZ.slice(WIZ.indexOf('function tHelpBtn('), WIZ.indexOf('async function saveTargets('))), 'no old names in the step');
  ok(WIZ.indexOf('function tHelpBtn(') > 0 && WIZ.indexOf('function tHelpBtn(') < WIZ.indexOf('function renderTargets('), 'the range starts before the step');
});

// TARGETS-AREAS-1 (GitHub issue 422). OLD-SKU-1A titled the two areas by
// generation and took the Generation column off this step. But the split was
// never the generation - oldShape() puts a machine in the second area when it
// is Generation 1 OR on an older size - so a Generation 2 machine on DS2_v2 sat
// under "Generation 1 machines and older sizes". The rule since 2026-10-02: title
// the areas by HOW the target is chosen, and show the generation on every row.
// The test that held "no Generation column on this step" is rewritten to that
// rule. RUN: the page's own row and area functions, with real-shaped machines.
// MANA-LINUX-KERNEL-1: a row draws the kernel choice too (kernelOffered, kernelOf).
// KERNEL-UX-1: in its Details (kernelSectionHtml), and an area counts its machines (tCountText).
const rowFns = liftAll('wizard.html', ['tHelpBtn', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'tAreasHtml', 'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tempLost', 'tDotWhy', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
const resetT = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tSelected = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set(); globalThis.tASeen = new Set(); globalThis.tMethodSel = new Map();
};
const shapeOpt = (option) => Object.assign(opt(option, true), { sizeChoices: [
  { size: `Standard_D2ds_${option}`, family: 'D', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 8, best: true, premiumDisks: true },
  { size: `Standard_E2ds_${option}`, family: 'E', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 16, best: false, premiumDisks: true }] });
// The machine of the issue: Generation 2, on an older size with no v5 twin.
const g2old = { vmId: '/vm/ds2-01', name: 'ds2-01', gen: 'V2', location: 'westus3', sourceSize: 'Standard_DS2_v2', acceleratedNicCount: 1,
  sourceStage: { stage: 'End of Life', basis: 'stated' }, options: [shapeOpt('v5'), shapeOpt('v6'), shapeOpt('v7')], start: { current: 'v6', extended: 'v5' } };
const g2 = Object.assign({}, app, { gen: 'V2', location: 'centralus' });
const g1 = Object.assign({}, legacy, { gen: 'V1', location: 'eastus2' });
const unk = Object.assign({}, app, { vmId: '/vm/unk-01', name: 'unk-01', gen: null, location: 'centralus' });
// Each area as drawn: its title, its column headings, the cells of each
// machine row as text, and the column span of each Details row.
const areasOf = (html) => html.split('<div class="sec t-area"').slice(1).map(a => ({
  title: a.match(/<h3>([^<]*)</)[1].trim(),
  // TARGETS-ALIGN-1: the Details heading carries a class, so a heading may.
  heads: [...a.match(/<thead>([\s\S]*?)<\/thead>/)[1].matchAll(/<th\b[^>]*>([\s\S]*?)<\/th>/g)].map(x => x[1].replace(/<[^>]+>/g, '').trim()),
  // ADVISE-AN-1: a machine row is t-row; the tick box that marked it is gone.
  rows: a.split('<tr').filter(r => r.startsWith(' class="t-row"'))
    .map(r => [...r.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map(x => x[1].replace(/<[^>]+>/g, '').trim())),
  details: [...a.matchAll(/<tr class="t-detail"><td colspan="(\d+)">/g)].map(x => Number(x[1])),
}));

test('RUN: a Generation 2 machine on an older size is under a title that says how its target is chosen, never a generation (TARGETS-AREAS-1)', () => {
  eq(UX.tAreaSame, 'Same size, newer version', 'approved words, 2026-10-12');
  eq(UX.tAreaShape, 'Choose a family and size');
  ok(!('tAreaGen2' in UX) && !('tAreaOld' in UX), 'the titles named for a generation are gone');
  resetT();
  const areas = areasOf(rowFns.tAreasHtml([g2, g2old, g1, unk]));
  eq(areas.map(a => a.title), [UX.tAreaSame, UX.tAreaShape], 'two areas, in this order');
  for (const a of areas) ok(!/generation|\bgen ?[12]\b/i.test(a.title), `an area title names a generation: ${a.title}`);
  const homes = areas.filter(a => a.rows.some(r => r[0] === 'ds2-01'));
  eq(homes.map(a => a.title), [UX.tAreaShape], 'the DS2_v2 machine is in the family-and-size area, and only there');
  eq(areas[0].rows.map(r => r[0]), ['app-01', 'unk-01']);
  eq(areas[1].rows.map(r => r[0]), ['ds2-01', 'legacy-01']);
});

test('RUN: every row in both areas shows the VM generation under a Generation heading (TARGETS-AREAS-1)', () => {
  eq(fns.advGenLabel('V1'), UX.vGen1); eq(fns.advGenLabel('V2'), UX.vGen2);
  eq(fns.advGenLabel(null), UX.vUnknown, 'unknown is said, never guessed');
  resetT(); globalThis.tOpen.add(g2.vmId); globalThis.tOpen.add(g2old.vmId);
  const areas = areasOf(rowFns.tAreasHtml([g2, g2old, g1, unk]));
  eq(areas.length, 2);
  const want = { 'app-01': UX.vGen2, 'unk-01': UX.vUnknown, 'ds2-01': UX.vGen2, 'legacy-01': UX.vGen1 };
  for (const a of areas) {
    const at = a.heads.indexOf(UX.colGen);
    ok(at > 0, `${a.title}: a Generation heading`);
    ok(a.heads.includes(UX.colRegion), `${a.title}: the Region column stays`);
    ok(a.rows.length > 0, `${a.title}: rows drawn`);
    for (const r of a.rows) {
      eq(r.length, a.heads.length, `${a.title}: ${r[0]} has one cell for each heading`);
      eq(r[at], want[r[0]], `${r[0]}: its generation`);
    }
    for (const span of a.details) eq(span, a.heads.length, `${a.title}: the Details row spans every column`);
  }
  eq(areas.map(a => a.details.length), [1, 1], 'an open Details row in each area');
  const regionAt = areas[1].heads.indexOf(UX.colRegion);
  eq(areas[1].rows.find(r => r[0] === 'ds2-01')[regionAt], 'westus3', 'the Region cell is the machine region');
});

test('RUN: the (?) of the family-and-size area opens its text and turns into Close; the first area has none (TARGETS-AREAS-1)', () => {
  resetT();
  const shut = rowFns.tAreasHtml([g2, g2old]);
  ok(shut.includes('data-help="shape"') && !shut.includes('data-help="same"'), 'one (?) only, on the second area');
  ok(!shut.includes('id="t-help-shape"'), 'its text is closed until clicked');
  globalThis.tHelp.add('shape');
  const opened = rowFns.tAreasHtml([g2, g2old]);
  ok(opened.includes(`<p class="muted t-help-text" id="t-help-shape">${esc(UX.tAreaShapeHelp)}</p>`), 'the text is shown');
  ok(opened.includes(`aria-label="${esc(UX.tClose)}"`) && opened.includes(`>${esc(UX.tClose)}</button>`), 'and the button is Close');
});
// AN-ONE-NIC-1, row 31 option 2 (2026-10-10): a machine whose 2-vCPU
// sizes cannot take its accelerated interfaces has no target. Its Details show
// ONE short reason sentence on each option; what to do is behind a (?), as the
// screens show options and keep the explanation behind it.
test('RUN: a 2-vCPU size refused for accelerated networking says why in one sentence, and what to do is behind a (?) (AN-ONE-NIC-1)', () => {
  const anOpt = (option) => Object.assign(opt(option, false), { notSupported: ['one-accelerated-nic'] });
  const anM = { vmId: '/vm/two-nic-01', name: 'two-nic-01', gen: 'V2', location: 'centralus', sourceSize: 'Standard_D2s_v4', acceleratedNicCount: 1,
    sourceStage: { stage: 'Extended', basis: 'stated' }, options: [anOpt('v5'), anOpt('v6'), anOpt('v7')], start: { current: null, extended: null } };
  globalThis.targetAdvice = { machines: [app, anM] };
  resetT(); globalThis.tOpen.add(anM.vmId); globalThis.tOpen.add(app.vmId);
  const shut = rowFns.tTargetRow(anM);
  ok(shut.includes(esc(UX.tNoTarget)), 'no target');
  eq(UX.whyNot['one-accelerated-nic'], 'This size has 2 vCPUs, so Azure allows accelerated networking on one network interface only');
  const sentence = esc(fill(UX.tNotAvailable, { why: UX.whyNot['one-accelerated-nic'] }));
  eq(shut.split(sentence).length - 1, 3, 'one reason sentence on each option');
  eq((shut.match(/data-help="an-1"/g) || []).length, 1, 'one (?) for the reason');
  ok(shut.includes(`aria-label="${esc(UX.tAnAbout)}"`), 'the (?) is named');
  ok(!shut.includes('id="t-help-an-1"') && !shut.includes(esc(UX.tAnHelp)), 'what to do is closed until clicked');
  globalThis.tHelp.add('an-1');
  const opened = rowFns.tTargetRow(anM);
  // ADVISE-AN-1: the help is a block now, which may hold the rule table too.
  ok(opened.includes(`<div class="muted t-help-text" id="t-help-an-1"><p>${esc(UX.tAnHelp)}</p>`), 'what to do is shown');
  ok(opened.includes(`>${esc(UX.tClose)}</button>`), 'and the button is Close');
  ok(/accelerated networking on the other network interfaces/.test(UX.tAnHelp), 'it says to turn it off on the other interfaces');
  ok(!/4 or more vCPUs|bigger|larger/i.test(UX.tAnHelp), 'it never says to choose a bigger size');
  // A machine with no such reason has no such (?).
  ok(!rowFns.tTargetRow(app).includes('data-help="an-'), 'no (?) where the reason is not shown');
});
// Review finding: the (?) id is the place of the machine in the options, as
// the kernel choice's is, so options made again must close it - or the help
// opens on whichever machine now holds that place.
test('RUN: new target options close the (?) of the accelerated networking reason (AN-ONE-NIC-1)', () => {
  const load = liftAll('wizard.html', ['kernelChoicesFrom', 'tLoadSaved']).tLoadSaved;
  Object.assign(globalThis, { adviceVersion: 'v2', tLoadedFrom: 'v1', targetChoices: null, targetAdvice: { machines: [] },
    tOverrides: null, tSizes: null, tDiskSel: null, tOpen: null, tKernelSel: null, tKSeen: null, tTSeen: null });
  globalThis.tHelp = new Set(['an-1', 'kernel-0', 'export']);
  load();
  ok(!globalThis.tHelp.has('an-1'), 'the reason help is closed');
  ok(!globalThis.tHelp.has('kernel-0'), 'the kernel help is closed, as before');
  ok(globalThis.tHelp.has('export'), 'a help that is not about one machine stays as it was');
});
run('targets-step');
