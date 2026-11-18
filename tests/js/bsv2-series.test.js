/* BSV2-TARGET-1: Bsv2 is the default target of a B v1 machine.
 *
 * The engine offers a B v1 machine its Bsv2 size on the v5 option, because
 * Bsv2 follows the v5 rules (SCSI, Generation 1 and 2). It is not a v5 size,
 * so every page names it by its own series. The machine here is the B v1
 * machine of the sample options, which the engine itself made
 * (schemas/samples/target-advice.sample.json).
 *
 * RUN: the pages' own functions, lifted out of help.js and wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const seriesLabel = lift('help.js', 'seriesLabel');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel });
globalThis.tLinksOf = () => ({ extensions: [], sqlVirtualMachine: false, dataCollectionRuleAssociations: [] });
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
const W = liftAll('wizard.html', ['advSeriesLabel', 'sizeOf', 'advPick', 'advSummary', 'advGroups', 'tDefSeries', 'advWhy', 'advDetailRows', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tRecommended']);

const sample = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'samples', 'target-advice.sample.json'), 'utf8'));
const machine = () => JSON.parse(JSON.stringify(sample.machines.find(m => m.sourceSize === 'Standard_B2ms')));

test('the page reads a size as Bsv2 exactly where the engine does (tests/fixtures/bsv2-size-names.json)', () => {
  const fx = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'bsv2-size-names.json'), 'utf8'));
  ok(fx.sizes.length > 10, 'the list is read');
  for (const s of fx.sizes) eq(seriesLabel('v5', s.size), s.bsv2 ? 'Bsv2' : 'v5', s.size || '(no size)');
  eq(seriesLabel('v6', 'Standard_D2ds_v6'), 'v6', 'any other size keeps its option');
});

test('the sample holds a B v1 machine that starts on Bsv2, so this file tests what the engine writes', () => {
  const m = machine();
  const o = m.options.find(x => x.option === 'v5');
  eq(o.targetSize, 'Standard_B2s_v2');
  eq(o.burstableTarget, 'offered');
  eq(m.start.current, 'v5'); eq(m.start.extended, 'v5');
  eq(o.sizeChoices[0].family, 'Bsv2', 'Bsv2 is first');
});

test('the series is Bsv2 for the Bsv2 size, and v5 once a person chooses a D size', () => {
  const m = machine();
  eq(W.advSeriesLabel(m, 'v5', new Map()), 'Bsv2');
  eq(W.advSeriesLabel(m, 'v5', new Map([[m.vmId, 'Standard_D2ds_v5']])), 'v5');
  eq(W.advSeriesLabel(m, 'v6', new Map()), 'v6');
});

test('the summary counts Bsv2 machines as Bsv2', () => {
  const m = machine();
  const d = Object.assign(machine(), { vmId: m.vmId + '-2' });
  const text = W.advSummary([m, d], 'current', new Map(), new Map([[d.vmId, 'Standard_D2ds_v5']]));
  ok(text.includes(fill(UX.tOn, { n: 1, series: 'Bsv2' })), text);
  ok(text.includes(fill(UX.tOn, { n: 1, series: 'v5' })), text);
});

test('Details: on Bsv2 the machine keeps its CPU credits and goes to Current; on a D size it ends them and goes to Extended', () => {
  const m = machine();
  const row = (rows, k) => (rows.find(r => r[0] === k) ?? [])[1];
  const b = W.advDetailRows(m, 'v5', 'Standard_B2s_v2');
  eq(row(b, UX.dCpu), `${UX.vCpuCredits}  →  ${UX.vCpuCredits} ${UX.vNoChange}`);
  eq(row(b, UX.dLife), 'End of Life  →  Current');
  eq(row(b, UX.dTemp), `${UX.vOneDisk}  →  ${UX.vNone}`, 'Bsv2 has no temporary disk');
  eq(b.filter(r => r[0] === UX.dCpu).length, 1, 'one CPU row');
  const d = W.advDetailRows(m, 'v5', 'Standard_D2ds_v5');
  eq(row(d, UX.dCpu), `${UX.vCpuCredits}  →  ${UX.vCpuFull}`);
  eq(row(d, UX.dLife), 'End of Life  →  Extended');
  ok(!d.some(r => r[0] === UX.dBsv2), 'no Bsv2 reason where Bsv2 is offered');
});

// BSV2-NOTES-1: the engine turns accelerated networking on for a Bsv2 move,
// which does not require it, and Details said Off -> Off. Read from turnsOn.
test('Details: a move that turns accelerated networking on says On, where the size does not require it', () => {
  const row = (rows, k) => (rows.find(r => r[0] === k) ?? [])[1];
  const withAn = (an, count = 0) => {
    const m = machine();
    m.acceleratedNicCount = count;
    const o = m.options.find(x => x.option === 'v5');
    for (const f of [o, ...o.sizeChoices]) f.acceleratedNetworking = Object.assign({ required: false, mayUseMana: true, keptOn: null, keptOnWhy: null }, an);
    return row(W.advDetailRows(m, 'v5', 'Standard_B2s_v2'), UX.dAn);
  };
  eq(withAn({ turnsOn: true }), `${UX.vOff}  →  ${UX.vOn}`, 'it turns on');
  eq(withAn({ turnsOn: false }), `${UX.vOff}  →  ${UX.vOff}`, 'it stays off');
  eq(withAn({ turnsOn: null }), `${UX.vOff}  →  ${UX.vUnknown}`, 'unknown is said, never Off');
  eq(withAn({ turnsOn: true, required: true }), `${UX.vOff}  →  ${UX.vOnRequired}`, 'a size that requires it says so');
  eq(withAn({ turnsOn: null }, 2), `${UX.vOn}  →  ${UX.vOn}`, 'the primary not read: the move turns no interface off');
  eq(withAn({ turnsOn: null, required: null }, 2), `${UX.vOn}  →  ${UX.vUnknown}`, 'a size that cannot be read');
});

// BSV2-NOTES-1 (lead, 2026-10-23): a Path B move was "Resize, rebuilt around
// the same disks". The kind of change is the name of the path, as the wave
// editor and the report name it (UX_PATH in migrations.html).
// REBUILD-REMOVE-PLAN-1: no target is a rebuild now. The kind of change is the
// in-place upgrade, with the Preview pill where the move is one.
test('Details: the kind of change is the name of the path - In-place upgrade, with (Preview) where it is one', () => {
  const pm = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html')).match(/const UX_PATH = \{ A: '([^']+)' \};/);
  ok(pm, 'migrations.html declares UX_PATH');
  const UX_PATH = { A: pm[1] };
  const row = (rows, k) => (rows.find(r => r[0] === k) ?? [])[1];
  for (const preview of [false, true]) {
    const m = machine();
    const o = m.options.find(x => x.option === 'v5');
    for (const f of [o, ...o.sizeChoices]) { f.path = 'A'; f.preview = preview; }
    const kind = row(W.advDetailRows(m, 'v5', 'Standard_B2s_v2'), UX.dKind);
    eq(kind, preview ? `${UX_PATH.A} (${UX.tPillPreview})` : UX_PATH.A, String(preview));
    ok(!/rebuil/i.test(kind), kind);
  }
  const m = machine();
  const v6 = m.options.find(x => x.option === 'v6');
  v6.path = 'A'; v6.rebuild = false;
  eq(row(W.advDetailRows(m, 'v6', v6.targetSize), UX.dKind), UX_PATH.A, 'an NVMe move by path too');
  ok(/NVMe/.test(row(W.advDetailRows(m, 'v6', v6.targetSize), UX.dController)), 'the disk controller row names NVMe');
});

// Review, 2026-10-23: the B v1 machine of the sample is Linux on a release
// Microsoft lists. Its kernel is not read before the run, and a kernel with no
// MANA driver keeps the primary off (AN-KEEP-1), so the engine writes unknown.
test('the sample says what the engine writes: the Linux B v1 machine on Bsv2 is unknown - the kernel decides', () => {
  const m = machine();
  const o = m.options.find(x => x.option === 'v5');
  eq(m.acceleratedNicCount, 0);
  eq(m.os, 'Linux');
  eq(o.acceleratedNetworking.turnsOn, null);
  eq(o.sizeChoices.find(c => c.size === 'Standard_B2s_v2').acceleratedNetworking.turnsOn, null);
  const row = (rows, k) => (rows.find(r => r[0] === k) ?? [])[1];
  eq(row(W.advDetailRows(m, 'v5', 'Standard_B2s_v2'), UX.dAn), `${UX.vOff}  →  ${UX.vUnknown}`, 'Details never promise On');
});

// REBUILD-REMOVE-PLAN-1: the test that an option refused as a rebuild named
// the rebuild is gone - no option is a rebuild, and the advice has no field
// rebuild.

test('Details say why a B v1 machine has no Bsv2 size, in declared words', () => {
  for (const why of ['no-fit', 'disk-encryption-preview']) {
    const m = machine();
    const o = m.options.find(x => x.option === 'v5');
    o.burstableTarget = why;
    o.sizeChoices = o.sizeChoices.filter(c => c.family !== 'Bsv2');
    o.sizeChoices.find(c => c.size === 'Standard_D2ds_v5').best = true;
    o.targetSize = 'Standard_D2ds_v5';
    const r = W.advDetailRows(m, 'v5', null).find(x => x[0] === UX.dBsv2);
    ok(r, why);
    eq(r[1], UX.vBsv2Why[why]);
    ok(!/undefined/.test(r[1]), why);
  }
});

test('the page names the page file move of a v5 move with no temporary disk, as the engine does (tests/fixtures/prep-by-target.json)', () => {
  const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
  globalThis.REASONS = { blockers: reasons.blockers, prep: reasons.prep };
  const judgeForSeries = lift('migrations.html', 'judgeForSeries');
  const fx = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'prep-by-target.json'), 'utf8'));
  ok(fx.cases.length > 5, 'the cases are read');
  for (const c of fx.cases) {
    const j = judgeForSeries({ classification: 'ReadyAfterPrep', blockers: [], prepNeeded: c.prepNeeded, diskController: 'SCSI' }, c.series, c.targetDiskArch);
    eq([...j.prep].sort().join(','), [...c.prep].sort().join(','), c.name);
  }
});

test('the family list names Bsv2 for what it is', () => {
  ok(/CPU credits/.test(UX.tFamilies.Bsv2), UX.tFamilies.Bsv2);
});

run('bsv2-series');
