/* OLD-FAM-4: a B v1 machine is told its target has no CPU credits.
 *
 * The B sizes are the only Azure sizes that run on CPU credits; every target
 * this product plans is a D or E size with full CPU performance all the time.
 * The target advice says so per option (burstableEnds), and the targets step
 * shows it as one row of an option's details - from the page's own function.
 */
'use strict';
const { lift, liftConst, test, ok, eq, run } = require('./_harness');

globalThis.UX = liftConst('wizard.html', 'UX');
// The two one-line helpers the function reads, as the page writes them.
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
const advDetailRows = lift('wizard.html', 'advDetailRows');
// REBUILD-PICKER-1: the method rule the details read.
Object.assign(global, require('./_harness').liftAll('wizard.html', ['tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tRecommended', 'sizeOf']));

const option = (extra) => Object.assign({
  option: 'v5', supported: true, targetSize: 'Standard_D2lds_v5', move: 'scsi-resize', rebuild: false,
  tempDisksFrom: 1, tempDisksTo: 1, targetStage: { stage: 'Extended' }, stageChange: 'up',
  acceleratedNetworking: { required: true, mayUseMana: true, turnsOn: false }, stops: [], sizeChoices: [], premiumDisks: true,
}, extra);
const machine = (o) => ({ sourceSize: 'Standard_B2s', diskController: 'SCSI', acceleratedNicCount: 1,
  sourceStage: { stage: 'End of Life' }, options: [o] });

test('a burstable machine shows the CPU change, from credits to full performance', () => {
  const rows = advDetailRows(machine(option({ burstableEnds: true })), 'v5', null, undefined);
  const row = rows.find(r => r[0] === UX.dCpu);
  ok(row, 'there must be a CPU performance row');
  eq(row[1], `${UX.vCpuCredits}  →  ${UX.vCpuFull}`, 'before and after');
  ok(!/undefined/.test(row[1]), 'every word is declared');
});

test('any other machine shows no CPU row - nothing changes', () => {
  for (const v of [false, null, undefined]) {
    const rows = advDetailRows(machine(option({ burstableEnds: v })), 'v5', null, undefined);
    ok(!rows.some(r => r[0] === UX.dCpu), `no row for ${v}`);
  }
});

run('cpu-credits');
