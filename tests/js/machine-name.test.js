/* VMID-CASE-1, from the TESTMATRIX-1 lab session, 2026-09-30: the migrations
 * page listed MX-G1W next to mx-o2w in one wave.
 *
 * Azure gives some resource IDs with the resource group, or the machine name,
 * in upper case, and others as they were made. The product keeps a machine's
 * ID as the assessment read it, and every page cut the name a person reads
 * from that ID. The records hold the name itself: the capture read from the
 * machine (captured.vmConfig.name) and the assessment's record (name).
 *
 * RUN, not read: help.js's own functions against the fixture the engine's
 * twin (Get-VmfMachineName) is held to as well, then each page's own wiring.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const read = (f) => pageSource(path.join(DASH, f));
const help = liftAll('help.js', ['machineName', 'machineNames', 'idKey']);
const CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'machine-names.json'), 'utf8')).cases;

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000';
const UPPER = `${SUB}/resourceGroups/VMF-MATRIX-CORE/providers/Microsoft.Compute/virtualMachines/MX-G1W`;
const LOWER = `${SUB}/resourceGroups/vmf-matrix-core/providers/Microsoft.Compute/virtualMachines/mx-o2w`;
const PLANNED = `${SUB}/resourceGroups/VMF-MATRIX-CORE/providers/Microsoft.Compute/virtualMachines/MX-U6A`;

// The records as the store holds them: the state document keeps the ID in the
// case the assessment read, and its capture holds the machine's own name.
const DOCS = [
  { vmId: UPPER, state: 'MIGRATED', captured: { vmConfig: { name: 'mx-g1w' } } },
  { vmId: LOWER, state: 'MIGRATED', captured: { vmConfig: { name: 'mx-o2w' } } },
];
const ASSESSMENT = { vms: [
  { vmId: UPPER, name: 'mx-g1w' },
  { vmId: LOWER, name: 'mx-o2w' },
  // Not started, so no state document: the assessment names it.
  { vmId: PLANNED, name: 'mx-u6a' },
] };

test('RUN: every shared case gives the name the engine gives', () => {
  ok(CASES.length >= 5, 'the fixture must hold the cases');
  for (const c of CASES) {
    const records = [c.captured === null ? null : { captured: { vmConfig: { name: c.captured } } },
                     c.assessed === null ? null : { name: c.assessed }];
    eq(help.machineName(c.vmId, ...records), c.want, c.case);
  }
});

test('RUN: the name is found by the ID in any letter case', () => {
  const nameOf = help.machineNames(DOCS, ASSESSMENT.vms);
  eq(nameOf(UPPER), 'mx-g1w', 'the ID as the assessment read it');
  eq(nameOf(UPPER.toLowerCase()), 'mx-g1w', 'the same ID in lower case');
  eq(nameOf(PLANNED), 'mx-u6a', 'a machine with no state document yet');
  eq(nameOf(`${SUB}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/NEW-01`), 'NEW-01',
    'a machine no record names keeps the last part of its ID');
});

test('RUN: one key for one ID, whatever its letter case', () => {
  eq(help.idKey(UPPER), help.idKey(UPPER.toLowerCase()), 'two spellings of one ID');
  eq(help.idKey(undefined), '', 'no ID is no key');
});

test('help.js gives the three helpers to every page', () => {
  const exported = read('help.js').match(/window\.VmfHelp = \{([\s\S]*?)\};/);
  ok(exported, 'the export block must be found');
  for (const n of ['machineName', 'machineNames', 'idKey']) {
    ok(new RegExp(`\\b${n}\\b`).test(exported[1]), `${n} must be exported`);
  }
});

// Each page that shows plan entries: its own wiring, run.
for (const file of ['migrations.html', 'waves.html', 'wizard.html']) {
  const src = read(file);
  test(`RUN: ${file} names a machine from its records, not from its ID`, () => {
    globalThis.VmfHelp = help;
    globalThis.machineNameOf = null;
    const nameMachines = lift(file, 'nameMachines');
    const arrow = src.match(/\nconst vmName = (\([^\n]*);\n/);
    ok(arrow, `${file} must declare vmName`);
    // eslint-disable-next-line no-eval
    const vmName = eval(arrow[1]);
    nameMachines(DOCS, ASSESSMENT);
    eq(vmName(UPPER), 'mx-g1w', 'a started machine, by its capture');
    eq(vmName(LOWER), 'mx-o2w', 'the machine beside it, in the same case');
    eq(vmName(PLANNED), 'mx-u6a', 'a machine not started, by its assessment');
  });

  test(`${file} names its machines where it reads its records`, () => {
    // Called, not only declared: a declaration nobody calls leaves every name
    // cut from the ID, and the test above would still pass.
    const calls = src.split('\n').filter(l => /nameMachines\(/.test(l) &&
      !/^\s*(\/\/|\*|\/\*)/.test(l) && !/^function nameMachines/.test(l));
    ok(calls.length >= 1, `${file} must call nameMachines after it reads the state documents`);
  });
}

test('RUN: the reports page names the machines in its problem list from their records', async () => {
  const src = read('reports.html');
  const buildDetail = lift('reports.html', 'buildDetail');
  const docs = [
    { vmId: UPPER, state: 'FAILED_ROLLED_BACK', history: [{ state: 'FAILED_ROLLED_BACK', detail: 'x' }],
      captured: { vmConfig: { name: 'mx-g1w' } } },
    { vmId: LOWER, state: 'MIGRATED', restore: { restoredBy: 'operator@example.com' }, history: [],
      captured: { vmConfig: { name: 'mx-o2w' } } },
  ];
  const files = { 'plan.json': { entries: [{ vmId: UPPER, wave: 'w1' }, { vmId: LOWER, wave: 'w1' }] },
                  'state/a.json': docs[0], 'state/b.json': docs[1] };
  globalThis.detailCache = new Map();
  globalThis.source = {
    readJson: async (r, n) => files[n] ?? null,
    listFolder: async (r, folder) => (folder === 'state' ? ['state/a.json', 'state/b.json'] : []),
    exists: async () => false,
  };
  globalThis.VmfHelp = Object.assign({}, help, {
    mapLimited: async (items, fn) => Promise.all(items.map(fn)),
    // NOT-IN-WAVE-QUEUED-1: buildDetail asks help.js's outsideRun.
    outsideRun: lift('help.js', 'outsideRun'),
    machineOutcome: (d) => (d && d.state === 'MIGRATED' ? (d.restore ? 'putBack' : 'migrated') : 'rolledBack'),
  });
  globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  globalThis.reservedInstances = () => 0;
  globalThis.vmName = (id) => String(id).split('/').pop();
  ok(/const detailCache = new Map\(\);/.test(src), 'the page keeps its cache where this test puts it');
  const d = await buildDetail('run-1');
  eq(d.issues.map(i => i.name).sort(), ['mx-g1w', 'mx-o2w'], 'the names on the problem list');
});

// An availability set is one resource. Each machine records the set by its
// own reference, so two members can name one set in two letter cases.
const SET_A = { vmId: UPPER, assessment: { availabilitySetId: `${SUB}/resourceGroups/VMF-MATRIX-CORE/providers/Microsoft.Compute/availabilitySets/AS-1` } };
const SET_B = { vmId: LOWER, assessment: { availabilitySetId: `${SUB}/resourceGroups/vmf-matrix-core/providers/Microsoft.Compute/availabilitySets/as-1` } };
const NO_SET = { vmId: PLANNED, assessment: { availabilitySetId: '' } };

test('RUN: the wave editor moves both members of one set, whatever the letter case', () => {
  const src = read('waves.html');
  const arrow = src.match(/\nconst avsetOf = (\([^\n]*);\n/);
  ok(arrow, 'waves.html must declare avsetOf');
  globalThis.VmfHelp = help;
  globalThis.entries = [SET_A, SET_B, NO_SET];
  globalThis.entryById = new Map(globalThis.entries.map(e => [e.vmId, e]));
  // eslint-disable-next-line no-eval
  globalThis.avsetOf = eval(arrow[1]);
  const expand = lift('waves.html', 'expand');
  eq(expand([UPPER]).sort(), [UPPER, LOWER].sort(), 'moving one member moves the other');
  eq(expand([PLANNED]), [PLANNED], 'a machine in no set moves alone');
});

test('RUN: the run page reads one set as one, whatever the letter case', () => {
  const line = read('migrations.html').split('\n').find(l => /^\s*const avsetOf = /.test(l));
  ok(line, 'migrations.html must declare avsetOf');
  globalThis.VmfHelp = help;
  // eslint-disable-next-line no-eval
  const avsetOf = eval(line.replace(/^\s*const avsetOf = /, '').replace(/;\s*$/, ''));
  eq(avsetOf(SET_A), avsetOf(SET_B), 'two spellings of one set');
  eq(avsetOf(NO_SET), '', 'no set is no set');
});

run('machine-name');
