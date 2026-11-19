// OLD-SKU-1A: the Choose each target page in two areas, a Region column, and
// Export for pricing.
//
// Decided 2026-09-29: keep Generation 1 machines and the old sizes (D v1, DS v1,
// Dv2, DSv2, Av2) in their own area; drop the generation column from the VM
// list; show the region of each VM, which the product rarely shows; and add an
// export once the list of VMs and their targets (by region) is complete (not
// during the run itself), so a customer can hand it to a Microsoft seller to
// get the price of the change. The export is for pricing only, for now.
// TARGETS-AREAS-1 (2026-10-02) brought the Generation column back and titled
// the areas by how the target is chosen; targets-step.test.js holds that.
//
// RUN: the page's own functions, lifted out of wizard.html.
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });
Object.assign(global, require('./_harness').liftAll('wizard.html', ['advSeriesLabel']));

const oldShape = lift('wizard.html', 'oldShape');
const pricingCsv = lift('wizard.html', 'pricingCsv');
const csvCell = lift('wizard.html', 'csvCell');
const exportState = lift('wizard.html', 'exportState');
global.csvCell = csvCell;
global.sizeOf = lift('wizard.html', 'sizeOf');
global.savedSizes = lift('wizard.html', 'savedSizes');
global.savedDisks = lift('wizard.html', 'savedDisks');
global.premiumOf = lift('wizard.html', 'premiumOf');
global.disksOf = lift('wizard.html', 'disksOf');
global.diskChoicesOf = lift('wizard.html', 'diskChoicesOf');
global.osDiskTypes = lift('wizard.html', 'osDiskTypes');
// MANA-LINUX-KERNEL-1: whether the kernel choices are saved is part of the state too.
global.kernelOffered = lift('wizard.html', 'kernelOffered');
global.kernelOf = lift('wizard.html', 'kernelOf');
// TEMP-DISK-PREVIEW-1: and the kind of change of each row.
Object.assign(global, require('./_harness').liftAll('wizard.html', ['tMethodOf', 'previewOn', 'previewOf', 'subOf']));
global.UX = { vDisks3: { keep: 'No change', 'os-standard-ssd': 'OS disk to Standard SSD', os: 'OS disk to Premium SSD', all: 'Every disk to Premium SSD' },
  // HDD-OS-1: the OS disk type now and after.
  vUnknown: 'Unknown', vDiskTypes: { Standard_LRS: 'Standard HDD', StandardSSD_LRS: 'Standard SSD', Premium_LRS: 'Premium SSD' } };
global.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/';
const m = (name, over) => Object.assign({
  vmId: `${SUB}rg-app/providers/Microsoft.Compute/virtualMachines/${name}`, name, gen: 'V2', os: 'Linux',
  location: 'centralus', sourceSize: 'Standard_D2s_v4',
  options: [{ option: 'v6', supported: true, targetSize: 'Standard_D2s_v6' }, { option: 'v5', supported: true, targetSize: 'Standard_D2s_v5' }],
  start: { current: 'v6', extended: 'v5' },
}, over || {});

test('the second area holds Generation 1 machines and the old sizes, and nothing else', () => {
  ok(oldShape(m('g1', { gen: 'V1' })), 'Generation 1');
  for (const size of ['Standard_D2_v2', 'Standard_DS11_v2', 'Standard_D13_v2', 'Standard_A2_v2', 'Standard_A8m_v2', 'Standard_D3', 'Standard_DS2', 'Standard_D2_v2_Promo',
                      'Standard_DS13-4_v2', 'Standard_DS11-1_v2', 'Standard_DS14-8_v2',
                      // OLD-FAM-1: the End of Life B v1, F, Fs and Fsv2 families
                      'Standard_B1s', 'Standard_B20ms', 'Standard_B1ls', 'Standard_F1', 'Standard_F8s', 'Standard_F72s_v2']) {
    ok(oldShape(m('x', { sourceSize: size })), size);
  }
  for (const size of ['Standard_D2s_v3', 'Standard_D2ds_v4', 'Standard_E8s_v5', 'Standard_D2as_v4', 'Standard_E8-4ds_v5', 'Standard_B2s_v2', 'Standard_F4als_v7']) {
    ok(!oldShape(m('x', { sourceSize: size })), size);
  }
  ok(!oldShape(m('u', { gen: null })), 'an unknown generation on a newer size stays in the first area');
});

test('the CSV counts each target size by region and operating system, then lists every machine', () => {
  const machines = [
    m('app-01'), m('app-02', { location: 'eastus2' }), m('win-01', { os: 'Windows' }), m('app-03'),
    m('none-01', { options: [{ option: 'v6', supported: false }], start: { current: null, extended: null } }),
  ];
  const picks = new Map([[machines[0].vmId, 'v6'], [machines[1].vmId, 'v6'], [machines[2].vmId, 'v5'], [machines[3].vmId, 'v6']]);
  const lines = pricingCsv(machines, picks).split('\r\n');
  eq(lines[0], 'Region,Operating system,Target size,Machines', 'the count table first');
  ok(lines.includes('centralus,Linux,D2s_v6,2'), 'two Linux D2s_v6 in centralus');
  ok(lines.includes('eastus2,Linux,D2s_v6,1'));
  ok(lines.includes('centralus,Windows,D2s_v5,1'), 'Windows counted apart: its price differs');
  const at = lines.indexOf('Machine,Resource group,Region,Operating system,Size now,Size series,Target size,Disks,OS disk type now,OS disk type after');
  ok(at > 0 && lines[at - 1] === '', 'then a blank line and the machine table');
  ok(lines.includes('app-01,rg-app,centralus,Linux,D2s_v4,v6,D2s_v6,No change,Unknown,Unknown'), lines.join(' | '));
  ok(lines.includes('none-01,rg-app,centralus,Linux,D2s_v4,,,,Unknown,Unknown'), 'a machine with no target is listed, with no target');
  ok(!lines.some(l => /^centralus,Linux,,/.test(l)), 'and is not counted');
});

test('a cell is quoted when it must be, and never read as a formula', () => {
  eq(csvCell('plain'), 'plain');
  eq(csvCell('a,b'), '"a,b"');
  eq(csvCell('say "hi"'), '"say ""hi"""');
  eq(csvCell('=HYPERLINK("x")'), '"\'=HYPERLINK(""x"")"', 'a leading = is made text');
  for (const c of ['+1', '-1', '@x', '\tx', '\rx']) { ok(csvCell(c).includes("'" + c[0]), JSON.stringify(c)); }
  eq(csvCell(null), '');
});

// PRICE-EXPORT-1 (issue 423): this test pinned "offered only when every
// target is saved". Save moved the person on to grouping, so the button was
// never seen enabled. The export now SAVES first, so the same comparison no
// longer turns the button off - it decides whether a press saves before it
// downloads. Rewritten to the new rule, case for case.
test('the export knows when the screen holds a target that is not saved, so it saves first', () => {
  const machines = [m('a'), m('b')];
  const saved = { adviceVersion: 'v1', choices: [{ vmId: machines[0].vmId, option: 'v6' }, { vmId: machines[1].vmId, option: 'v5' }] };
  const picks = new Map([[machines[0].vmId, 'v6'], [machines[1].vmId, 'v5']]);
  eq(exportState(machines, picks, saved, 'v1').saved, true, 'all saved, nothing changed: no save');
  eq(exportState(machines, picks, null, 'v1').saved, false, 'nothing saved');
  eq(exportState(machines, picks, saved, 'v2').saved, false, 'saved against older options');
  eq(exportState(machines, new Map([[machines[0].vmId, 'v6'], [machines[1].vmId, 'v6']]), saved, 'v1').saved, false, 'a change on screen');
  const partial = { adviceVersion: 'v1', choices: [saved.choices[0]] };
  eq(exportState(machines, picks, partial, 'v1').saved, false, 'a machine with a target but none saved');
  const none = m('c', { options: [{ option: 'v6', supported: false }], start: { current: null, extended: null } });
  eq(exportState([...machines, none], picks, saved, 'v1').saved, true, 'a machine with no target to choose holds nothing back');
  // The save sends nothing for a machine with no target picked
  // (targetChoicesBody). Read as unsaved, it would make
  // every press save again - and a save names the person who pressed it.
  const unpicked = m('d', { start: { current: null, extended: null } });
  eq(exportState([...machines, unpicked], picks, saved, 'v1').saved, true, 'no target picked: nothing to save');
  eq(exportState([...machines, unpicked], picks, saved, 'v1').ready, undefined, 'no ready flag: the button is never turned off');
  // The default is saved too, and a reload starts from it (review finding 4).
  eq(exportState(machines, picks, saved, 'v1', undefined, undefined, 'current').saved, true, 'no default saved reads as Current');
  eq(exportState(machines, picks, saved, 'v1', undefined, undefined, 'extended').saved, false, 'the default changed on screen');
  eq(exportState(machines, picks, Object.assign({}, saved, { default: 'extended' }), 'v1', undefined, undefined, 'extended').saved, true, 'the default as saved');
});

// ---------- PRICE-EXPORT-1: the wave, on the Run it step ----------

test('RUN: with a wave for each machine, both tables carry it, and the count is per wave in the order of the plan', () => {
  const machines = [
    m('app-01'), m('app-02'), m('win-01', { os: 'Windows' }), m('app-03'),
    m('none-01', { options: [{ option: 'v6', supported: false }], start: { current: null, extended: null } }),
  ];
  const picks = new Map([[machines[0].vmId, 'v6'], [machines[1].vmId, 'v6'], [machines[2].vmId, 'v5'], [machines[3].vmId, 'v6']]);
  // wave-2 runs first. By the alphabet wave-10 comes first, so the test data
  // can tell the order of the plan from a sort.
  const waves = new Map([[machines[0].vmId, 'wave-2'], [machines[1].vmId, 'wave-10'], [machines[2].vmId, 'wave-10'], [machines[3].vmId, 'wave-2'], [machines[4].vmId, 'unscheduled']]);
  const lines = pricingCsv(machines, picks, undefined, undefined, waves).split('\r\n');
  eq(lines[0], 'Wave,Region,Operating system,Target size,Machines', 'the count table names the wave first');
  ok(lines.includes('wave-2,centralus,Linux,D2s_v6,2'), lines.join(' | '));
  ok(lines.includes('wave-10,centralus,Linux,D2s_v6,1'), 'counted apart from the same size in another wave');
  ok(lines.includes('wave-10,centralus,Windows,D2s_v5,1'));
  ok(lines.indexOf('wave-2,centralus,Linux,D2s_v6,2') < lines.indexOf('wave-10,centralus,Linux,D2s_v6,1'), 'the waves in the order the machines came, not the alphabet');
  const at = lines.indexOf('Wave,Machine,Resource group,Region,Operating system,Size now,Size series,Target size,Disks,OS disk type now,OS disk type after');
  ok(at > 0 && lines[at - 1] === '', 'then a blank line and the machine table, with the wave first');
  ok(lines.includes('wave-2,app-01,rg-app,centralus,Linux,D2s_v4,v6,D2s_v6,No change,Unknown,Unknown'), lines.join(' | '));
  ok(lines.includes('wave-10,win-01,rg-app,centralus,Windows,D2s_v4,v5,D2s_v5,No change,Unknown,Unknown'));
  ok(lines.includes('unscheduled,none-01,rg-app,centralus,Linux,D2s_v4,,,,Unknown,Unknown'), 'a machine with no target is listed with its wave');
  ok(!lines.some(l => l.startsWith('unscheduled,centralus')), 'and is not counted');
});

test('RUN: the Run it step prices the PLAN - each machine as planned, in the order the waves run', () => {
  global.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase(), waveOrder: lift('help.js', 'waveOrder'), seriesLabel: lift('help.js', 'seriesLabel') };
  const id = (name) => `${SUB}rg-app/providers/Microsoft.Compute/virtualMachines/${name}`;
  const plan = {
    waveOrder: ['wave-b', 'wave-a'],
    entries: [
      // HDD-OS-1: Standard SSD for its Standard HDD OS disk (plan-entry v21).
      { vmId: id('a-01'), wave: 'wave-a', path: 'A', assessment: { os: 'Linux', sourceSize: 'Standard_D2s_v4', osDiskType: 'Standard_LRS' },
        target: { size: 'Standard_D2s_v6', choice: { option: 'v6', source: 'default' } }, policy: { diskUpgrade: 'os-standard-ssd' } },
      // A size and a choice, but a path the product does not run: not priced.
      { vmId: id('m-01'), wave: 'wave-a', path: 'MANUAL', assessment: { os: 'Linux', sourceSize: 'Standard_D2s_v4' },
        target: { size: 'Standard_D2s_v6', choice: { option: 'v6', source: 'default' } }, policy: {} },
      { vmId: id('b-01'), wave: 'wave-b', path: 'A', assessment: { os: 'Windows', sourceSize: 'Standard_D4s_v4', osDiskType: 'StandardSSD_LRS' },
        target: { size: 'Standard_D4s_v5', choice: { option: 'v5', source: 'person' } }, policy: { diskUpgrade: 'os' } },
      // The region the plan recorded wins over the assessment record.
      { vmId: id('a-02'), wave: 'wave-a', path: 'A', assessment: { os: 'Linux', sourceSize: 'Standard_E8s_v4', location: 'westus3' },
        target: { size: 'Standard_E8s_v6', choice: { option: 'v6', source: 'wave' } }, policy: {} },
      // Review finding 2: path A with a size, but in no wave - it does not run
      // (planWaves leaves it out), so it is not priced, and the internal word
      // for "no wave" is never written into the file.
      { vmId: id('u-01'), wave: 'unscheduled', path: 'A', assessment: { os: 'Linux', sourceSize: 'Standard_D2s_v4' },
        target: { size: 'Standard_D2s_v6', choice: { option: 'v6', source: 'default' } }, policy: {} },
    ],
  };
  // VMID-CASE-1: Azure spells one ID in two letter cases; the region is still found.
  const vms = [
    { vmId: id('a-01').toUpperCase(), name: 'a-01', location: 'eastus2' },
    { vmId: id('a-02'), name: 'a-02', location: 'eastus2' },
    { vmId: id('b-01'), name: 'b-01', location: 'westus2' },
    { vmId: id('m-01'), name: 'm-01', location: 'centralus' },
    { vmId: id('u-01'), name: 'u-01', location: 'centralus' },
  ];
  const planPricing = lift('wizard.html', 'planPricing');
  const input = planPricing(plan, vms, (vmId) => vmId.split('/').pop());
  const lines = pricingCsv(input.machines, input.picks, input.sizes, input.disks, input.waves).split('\r\n');
  const head = lines.indexOf('Wave,Machine,Resource group,Region,Operating system,Size now,Size series,Target size,Disks,OS disk type now,OS disk type after');
  eq(lines.slice(head + 1, head + 6), [
    'wave-b,b-01,rg-app,westus2,Windows,D4s_v4,v5,D4s_v5,OS disk to Premium SSD,Standard SSD,Premium SSD',
    'wave-a,a-01,rg-app,eastus2,Linux,D2s_v4,v6,D2s_v6,OS disk to Standard SSD,Standard HDD,Standard SSD',
    'wave-a,m-01,rg-app,centralus,Linux,D2s_v4,,,,Unknown,Unknown',
    'wave-a,a-02,rg-app,westus3,Linux,E8s_v4,v6,E8s_v6,No change,Unknown,Unknown',
    ',u-01,rg-app,centralus,Linux,D2s_v4,,,,Unknown,Unknown',
  ], 'the order the waves run, the size the plan holds, the disk change it makes; a machine that does not move is listed with no target');
  eq(lines.slice(1, head - 1), [
    'wave-b,westus2,Windows,D4s_v5,1',
    'wave-a,eastus2,Linux,D2s_v6,1',
    'wave-a,westus3,Linux,E8s_v6,1',
  ], 'only what moves is counted, per wave');
  ok(!lines.join('\n').includes('unscheduled'), 'no internal word in the file');
});

// ---------- PRICE-EXPORT-1: one press on the targets step ----------

const STEP = liftConst('wizard.html', 'STEP');
// Lifted at each call, so a function that is missing fails its own tests only.
const saveTargets = (...a) => lift('wizard.html', 'saveTargets')(...a);
const exportTargets = (...a) => lift('wizard.html', 'exportTargets')(...a);
function saveRig({ refuse = false, readFails = false, search = '?run=r&plan=1' } = {}) {
  const calls = [];
  // One element per selector, so a test can read what the save did to it.
  const nodes = {};
  calls.nodes = nodes;
  Object.assign(globalThis, {
    STEP, step: STEP.migrate.targets, readFailed: null, UX: Object.assign({}, global.UX, { tSaved: 'saved', tExportChanged: 'changed' }),
    $: (s) => (nodes[s] = nodes[s] || { style: {}, disabled: false }),
    targetAdvice: { machines: [] }, tDefault: 'current', tOverrides: new Map(), tSizes: new Map(), tDiskSel: new Map(),
    // MANA-LINUX-KERNEL-1: the kernel choices and their default travel with the save.
    tKernelSel: new Map(), tKernelDef: 'stop',
    // TEMP-DISK-PREVIEW-1: and the kind of change each row is on.
    tMethodSel: new Map(),
    adviceVersion: 'a1', choicesVersion: 'c1', tOpen: new Set(['x']),
    // MACHINE-PICK-1: the save sends the chosen machines and the version of their list.
    machinesVersion: 'm1', tMachines: () => [],
    targetChoicesBody: () => [], runSeg: () => 'p/r', runBody: (b) => b,
    // ADVISE-AN-1: no machine still to choose - its own tests are in an-keep-choice.test.js.
    decideMissing: () => '',
    // CLICKS-LOST-1: Save marks itself busy (help.js), and clears its own "choose a target" message.
    markBusy: lift('wizard.html', 'markBusy'), tMissingText: '',
    VmfHelp: Object.assign({}, globalThis.VmfHelp, { markBusy: lift('help.js', 'markBusy') }),
    location: { href: `https://example.com/wizard.html${search}`, search },
    history: { replaceState: (_s, _t, u) => {
      const x = new URL(String(u)); globalThis.location = { href: x.href, search: x.search };
      calls.push(`address ${x.searchParams.get('step')}`);
    } },
    api: async (method, where, body) => {
      calls.push(`save ${where} ${body.adviceVersion} ${body.choicesVersion}`);
      calls.machinesVersion = body.machinesVersion;
      calls.busy = [nodes['#t-save'] && nodes['#t-save'].disabled, nodes['#t-export'] && nodes['#t-export'].disabled];
      if (refuse) { throw new Error('409: somebody saved the targets after this page read them'); }
    },
    said: () => calls.push('said'),
    // A read that fails takes the documents with it, as readRun does.
    readRun: async () => { calls.push('read'); if (readFails) { globalThis.readFailed = new Error('read'); globalThis.targetAdvice = null; } },
    exportPricing: (input) => calls.push(input === undefined ? 'download' : 'download with input'),
    render: () => calls.push('render'),
    failAction: (e) => calls.push(`error ${e.message.slice(0, 3)}`),
    // WIZARD-BACK-TARGETS-1: Save is a step the person chose.
    stepChosen: false, goStep: lift('wizard.html', 'goStep'),
  });
  return calls;
}

test('RUN: Export for pricing saves first - the same save, both versions quoted - then downloads, and stays on the step', async () => {
  const calls = saveRig();
  await saveTargets(true);
  eq(calls, ['save assessments/p/r/targets a1 c1', 'said', 'address targets', 'read', 'download', 'render'], 'save, keep the step in the address, read it back, then the file');
  eq(calls.machinesVersion, 'm1', 'MACHINE-PICK-1: and the version of the machines this page read');
  eq(globalThis.step, STEP.migrate.targets, 'the person stays on the targets step');
});

test('RUN: while the save runs, BOTH buttons wait; a refused save gives both back', async () => {
  // Review finding 5: a second press sent the same version again.
  const calls = saveRig({ refuse: true });
  await saveTargets(true);
  eq(calls.busy, [true, true], 'Save and Export both off during the save');
  eq([calls.nodes['#t-save'].disabled, calls.nodes['#t-export'].disabled], [false, false], 'and both back after a refusal');
});

test('RUN: a read that fails after the save cannot carry the person on to grouping', async () => {
  // Review finding 1: the failed read drew the waiting view, and its polling
  // followed the saved targets on to grouping on the next good read.
  const constArrow = (name) => {
    const m = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html')).match(new RegExp(`const ${name} = ([^;]+);`));
    return eval('(' + m[1] + ')');   // eslint-disable-line no-eval
  };
  saveRig({ readFails: true });
  await saveTargets(true);
  Object.assign(globalThis, {
    readFailed: null, journey: 'migrate', plan: null, states: new Map(), manifest: null, STARTED: [],
    targetChoices: { choices: [] }, wantsTargetsStep: constArrow('wantsTargetsStep'),
    // MACHINE-PICK-1: targets saved against no version of this list.
    machineChoices: { machines: [] }, machinesVersion: 'm1', wantsChooseStep: constArrow('wantsChooseStep'),
    targetsFitMachines: lift('wizard.html', 'targetsFitMachines'),
    wantsRunStep: constArrow('wantsRunStep'), wantsGroupStep: constArrow('wantsGroupStep'),
    // WIZARD-WAVES-STEP-1: is this run a migration (its run.json, or from= in the address).
    planningFrom: constArrow('planningFrom'), isMigration: constArrow('isMigration'),
  });
  eq(lift('wizard.html', 'deriveStep')(), STEP.migrate.targets, 'the next good read still derives this step');
});

test('RUN: Save from a link that asked for this step takes the request off the address, so a reload goes on', async () => {
  const calls = saveRig({ search: '?run=r&plan=1&step=targets' });
  await saveTargets();
  ok(calls.includes('address null'), calls.join(' | '));
  const plain = saveRig();
  await saveTargets();
  ok(!plain.some(c => c.startsWith('address')), 'an address with no step is left alone');
});

test('RUN: Save keeps its own job - save and move on to grouping, with no file', async () => {
  const calls = saveRig();
  await saveTargets();
  ok(!calls.includes('download'), 'no file');
  eq(globalThis.step, STEP.migrate.group, 'on to grouping');
  // ADVISE-AN-1 (2026-10-12): no tick boxes any more; Details close.
  eq(globalThis.tOpen.size, 0, 'nothing left open behind');
});

test('RUN: a refused save downloads nothing and shows why', async () => {
  const calls = saveRig({ refuse: true });
  await saveTargets(true);
  ok(!calls.some(c => c.startsWith('download')), 'no file from a save that did not happen');
  ok(calls.includes('error 409'), 'the refusal is on the screen');
  eq(globalThis.step, STEP.migrate.targets, 'still on the step');
});

test('RUN: a save that could not be read back downloads nothing - the file is what was saved, never a guess', async () => {
  const calls = saveRig({ readFails: true });
  await saveTargets(true);
  ok(!calls.some(c => c.startsWith('download')), 'no file');
  ok(calls.includes('render'), 'the page draws again, and says it could not read');
});

test('RUN: when everything on the screen is saved, the press only downloads - no second save in the name of the person who pressed', async () => {
  saveRig();
  const done = [];
  const one = m('a');   // starts on v6 under Current, v5 under Extended
  let stored = { doc: {}, version: 'c1' };
  Object.assign(globalThis, {
    advPick: lift('wizard.html', 'advPick'), exportState, clearErr: () => {},
    targetAdvice: { machines: [one] }, adviceVersion: 'a1', choicesVersion: 'c1',
    // MACHINE-PICK-1: the page's own filter to the chosen machines.
    tMachines: lift('wizard.html', 'tMachines'), onlyChosen: lift('wizard.html', 'onlyChosen'), machineChoices: { machines: [one.vmId] },
    targetsFitMachines: lift('wizard.html', 'targetsFitMachines'), machinesVersion: 'm1',
    targetChoices: { adviceVersion: 'a1', default: 'current', machinesVersion: 'm1', choices: [{ vmId: one.vmId, option: 'v6' }] },
    runPrefix: () => 'p/r',
    readVersionedDoc: async (where) => { done.push(`ask ${where}`); return stored; },
    saveTargets: (andExport) => done.push(`save ${andExport}`),
    exportPricing: (input) => done.push(input === undefined ? 'download' : 'download with input'),
    failAction: (e) => done.push(`error ${e.message}`),
    render: () => done.push('render'),
    canOperate: true,
  });
  await exportTargets();
  eq(done, ['ask p/r/target-choices.json', 'download'], 'saved already, and still the stored version: the file only');
  // Review finding 3: "saved" is what the page READ. A newer save by another
  // user, which the PLANVER-2 version shows, downloads nothing.
  done.length = 0; stored = { doc: {}, version: 'c2' };
  await exportTargets();
  eq(done, ['ask p/r/target-choices.json', `error ${UX.tExportChanged}`], 'a newer save: no file, and why');
  done.length = 0; stored = null; globalThis.readFailed = new Error('read');
  await exportTargets();
  eq(done, ['ask p/r/target-choices.json', 'render'], 'the version could not be read: no file, and the read error is drawn');
  // The real comparison decides, not a stand-in (review: the stub hid it).
  done.length = 0; globalThis.readFailed = null; globalThis.tDefault = 'extended';
  await exportTargets();
  eq(done, ['save true'], 'a change on screen: the one save, told to stay and download');
  // MACHINE-PICK-1 review finding 8: targets saved against an earlier list of
  // machines are not "saved" for this one, though every pick matches.
  done.length = 0; globalThis.tDefault = 'current';
  const helpWas = globalThis.VmfHelp;
  globalThis.VmfHelp = Object.assign({}, helpWas, { idKey: (x) => String(x).toLowerCase() });
  globalThis.machineChoices = { machines: [one.vmId] }; globalThis.machinesVersion = 'm2';
  globalThis.targetChoices = { adviceVersion: 'a1', default: 'current', machinesVersion: 'm1', choices: [{ vmId: one.vmId, option: 'v6' }] };
  await exportTargets();
  eq(done, ['save true'], 'saved against another list: save first');
  done.length = 0; globalThis.targetChoices.machinesVersion = 'm2'; stored = { doc: {}, version: 'c1' };
  await exportTargets();
  eq(done, ['ask p/r/target-choices.json', 'download'], 'saved against this list: the file only');
  globalThis.machineChoices = null; globalThis.machinesVersion = ''; globalThis.VmfHelp = helpWas;
});

test('WIZARD-ROLES-3: RUN: a user without the operator role downloads what is saved, and never saves', async () => {
  const done = [];
  const one = m('a');
  Object.assign(globalThis, {
    advPick: lift('wizard.html', 'advPick'), exportState, clearErr: () => {},
    targetAdvice: { machines: [one] }, adviceVersion: 'a1', choicesVersion: 'c1',
    tMachines: lift('wizard.html', 'tMachines'), onlyChosen: lift('wizard.html', 'onlyChosen'), machineChoices: { machines: [one.vmId] },
    targetsFitMachines: lift('wizard.html', 'targetsFitMachines'), machinesVersion: 'm1',
    targetChoices: { adviceVersion: 'a1', default: 'current', machinesVersion: 'm1', choices: [{ vmId: one.vmId, option: 'v6' }] },
    runPrefix: () => 'p/r', readFailed: null,
    readVersionedDoc: async (where) => { done.push(`ask ${where}`); return { doc: {}, version: 'c1' }; },
    saveTargets: (andExport) => done.push(`save ${andExport}`),
    exportPricing: (input) => done.push(input === undefined ? 'download' : 'download with input'),
    failAction: (e) => done.push(`error ${e.message}`),
    render: () => done.push('render'),
    canOperate: false, tDefault: 'current',   // the screen is what is saved
  });
  const pageUx = require('./_harness').liftConst('wizard.html', 'UX');
  global.UX = Object.assign({}, global.UX, { tExportNoneSaved: pageUx.tExportNoneSaved, tExportNotCurrent: pageUx.tExportNotCurrent });
  await exportTargets();
  eq(done, ['ask p/r/target-choices.json', 'download'], 'what an operator saved, with no save first');
  // Review: not current - a screen that differs, or targets saved against an
  // earlier list of machines - is never saved by a non-operator.
  done.length = 0; globalThis.tDefault = 'extended';
  await exportTargets();
  eq(done, [`error ${UX.tExportNotCurrent}`], 'the screen differs: no file, no save, and why');
  done.length = 0; globalThis.tDefault = 'current';
  const helpWas = globalThis.VmfHelp;
  globalThis.VmfHelp = Object.assign({}, helpWas, { idKey: (x) => String(x).toLowerCase() });
  globalThis.machineChoices = { machines: [one.vmId] }; globalThis.machinesVersion = 'm2';
  globalThis.targetChoices = { adviceVersion: 'a1', default: 'current', machinesVersion: 'm1', choices: [{ vmId: one.vmId, option: 'v6' }] };
  await exportTargets();
  eq(done, [`error ${UX.tExportNotCurrent}`], 'saved against another list of machines: no file, no save, and why');
  ok(pageUx.tExportNotCurrent && /operator/.test(pageUx.tExportNotCurrent), 'the page has the words, and they name the operator');
  globalThis.machineChoices = null; globalThis.machinesVersion = ''; globalThis.VmfHelp = helpWas;
  done.length = 0; globalThis.targetChoices = null;
  await exportTargets();
  const words = require('./_harness').liftConst('wizard.html', 'UX').tExportNoneSaved;
  ok(words && /operator/.test(words), 'the page has the words, and they name the operator');
  eq(done, [`error ${UX.tExportNoneSaved}`], 'nothing saved: no file, no save, and who saves them');
  globalThis.canOperate = true; globalThis.tDefault = 'current';
});
// ---------- PRICE-EXPORT-1: one CSV builder for both steps ----------

test('RUN: both steps build the file through one function - the targets step from what was saved, the Run it step from the plan', () => {
  const exportPricing = lift('wizard.html', 'exportPricing');
  const exportPlan = lift('wizard.html', 'exportPlan');
  const files = [];
  const realTimeout = globalThis.setTimeout, realUrl = globalThis.URL;
  Object.assign(globalThis, {
    pricingCsv, CSV_BOM: '', runId: 'r1',
    Blob: function Blob(parts) { files.push(parts.join('')); },
    URL: { createObjectURL: () => 'blob:x', revokeObjectURL: () => {} },
    document: { createElement: () => ({ click() {}, remove() {} }), body: { appendChild() {} } },
    setTimeout: () => 0,
  });
  try {
    const one = m('app-01');
    globalThis.targetAdvice = { machines: [one] };
    globalThis.targetChoices = { choices: [{ vmId: one.vmId, option: 'v5' }] };
    globalThis.machineChoices = { machines: [one.vmId] };
    exportPricing();
    ok(files[0].includes('app-01,rg-app,centralus,Linux,D2s_v4,v5,D2s_v5,No change'), `the saved target, not the screen: ${files[0]}`);
    ok(!files[0].includes('Wave'), 'no wave before there is a plan');
    globalThis.plan = { entries: [{ vmId: one.vmId, wave: 'wave-1', path: 'A', assessment: { os: 'Linux', sourceSize: 'Standard_D2s_v4' },
      target: { size: 'Standard_D2s_v6', choice: { option: 'v6', source: 'default' } }, policy: {} }] };
    globalThis.assessment = { vms: [{ vmId: one.vmId, name: 'app-01', location: 'centralus' }] };
    globalThis.vmName = (vmId) => vmId.split('/').pop();
    globalThis.planPricing = lift('wizard.html', 'planPricing');
    globalThis.exportPricing = exportPricing;
    exportPlan();
    ok(files[1].includes('wave-1,app-01,rg-app,centralus,Linux,D2s_v4,v6,D2s_v6,No change'), `the plan, with its wave: ${files[1]}`);
  } finally { globalThis.setTimeout = realTimeout; globalThis.URL = realUrl; }
});

test('each (?) turns into Close while its text is open, and names the text it opens (rule 11)', () => {
  const src = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  ok(src.includes("${tHelp.has(id) ? esc(UX.tClose) : '?'}</button>"), 'the button shows Close when open');
  ok(src.includes('aria-controls="t-help-${id}"'), 'and points at the text it opens');
});

test('RUN: the (?) is drawn by one function, for both steps', () => {
  // PRICE-EXPORT-1: the Run it step has its own (?) beside its export.
  global.esc = (v) => String(v == null ? '' : v);
  global.UX = Object.assign({}, global.UX, { tClose: 'Close' });
  const helpBtn = lift('wizard.html', 'tHelpBtn');
  global.tHelp = new Set();
  const shut = helpBtn('run-export', 'About this file');
  ok(shut.includes('>?</button>') && shut.includes('aria-expanded="false"') && shut.includes('aria-controls="t-help-run-export"'), shut);
  global.tHelp = new Set(['run-export']);
  const open = helpBtn('run-export', 'About this file');
  ok(open.includes('>Close</button>') && open.includes('aria-expanded="true"'), 'open: a visible Close');
});

run('pricing-export');
