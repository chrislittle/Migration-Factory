/* WAVE-FLOW-1: the last step shows EVERY wave, and shows each one its own
 * settings.
 *
 * It used to summarise waves[0] and nothing else. That was survivable while
 * grouping quietly put the whole estate in one wave; WAVE-GROUP-1 fixed the
 * grouping, so an estate across three resource groups now has three waves,
 * each with its own eight settings - and showing one of them is the same
 * defect this step exists to fix, one level down.
 */
'use strict';
const { lift, liftAll, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

// MANA-LINUX-KERNEL-1: the table names the machines that update their kernel too.
// WAVE-AN-NAMES-1: and the machines whose move decides accelerated networking.
const { leverRowsFor, tempSections, anTurnsOnNames, anDecidedNames, kernelUpdateNames } = liftAll('wizard.html', ['leverRowsFor', 'tempSections', 'anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames', 'previewText']);
global.anTurnsOnNames = anTurnsOnNames;
global.anDecidedNames = anDecidedNames;
global.kernelUpdateNames = kernelUpdateNames;
// SIGNOFF-NULL-1: the sign-off row is read by the one rule in help.js.
global.VmfHelp = Object.assign(global.VmfHelp ?? {}, { approvalRequired: lift('help.js', 'approvalRequired'),
  // WAVE-WORDS-3: the retention words, and the rule for a new identity.
  keepDaysText: lift('help.js', 'keepDaysText'),
  // WAVE-AN-NAMES-1: the accelerated networking rows.
  ...liftAll('help.js', ['anOutcomeRow', 'anOutcomeNames', 'previewNames']) });
global.newIdentityNames = () => [];
// WIZARD-OPTIONS-DISKS-1: the disk row is tested in run-it-disks.test.js.
global.diskChangeTexts = () => [];

function world(entries) {
  global.plan = { entries };
  global.esc = (s) => String(s ?? '');
  global.vmName = (id) => String(id).split('/').pop();
  global.UX = {
    lvCopy: 'Safety copy', lvCopyAlways: 'Always taken',
    lvCapacity: 'On-demand capacity reservation for this wave',
    lvCapOnDemand: 'No', lvCapReserved: 'Yes',
    lvData: 'If files are on the temporary disk', lvDataProceed: 'Go on', lvDataStop: 'Stop and ask',
    lvKernel: 'Machines whose kernel the product updates',
    lvIdentity: 'If a new identity appears', lvIdentityProceed: 'Go on', lvIdentityStop: 'Stop and ask',
    lvKeep: 'How long the snapshot is kept', lvKeepNever: 'never', lvKeepOne: '1 day', lvKeepMany: '{n} days',
    lvIdentityMachines: 'Machines that get a new identity',
    lvAtOnce: 'How many machines at once',
    // MANUAL-REVIEW-1: no wave time in words; only the all-at-once sentence.
    estAllAtOnce: 'This wave has only {machines} machines, so all of them run at once.', estAllAtOnceOne: 'This wave has only 1 machine, so a larger number changes nothing.',
    lvApproval: 'Someone must sign off', lvYes: 'Yes', lvNo: 'No',
    lvAn: 'Machines that get accelerated networking turned on', lvNone: 'None in this wave',
    lvAnDecides: 'Machines where the move decides accelerated networking',
    tempLoseTitle: 'These lose their temporary disk', tempLoseBody: 'body',
    tempGainTitle: 'These gain temporary disks', tempGainBody: 'body',
    tempUnknown: 'Some could not be read.', colMachine: 'Machine', tempCol: 'Temporary disks',
  };
}

/** Two waves that disagree about every setting they can disagree about. */
const twoWaves = [
  { vmId: '/vm/a', wave: 'wave-1', path: 'A', policy: {
      capacityGate: 'Reserved', onDDataFound: 'proceed', onDriverBelowFloor: 'proceed',
      onSystemAssignedIdentity: 'proceed', keepSnapshotDays: 30, throttle: 30, requireApproval: true } },
  { vmId: '/vm/b', wave: 'wave-2', path: 'A', policy: {
      capacityGate: 'BestEffort', onDDataFound: 'stop', onDriverBelowFloor: 'stop',
      onSystemAssignedIdentity: 'stop', keepSnapshotDays: 3, throttle: 5, requireApproval: false } },
];

test('THE DEFECT: the second wave shows its OWN settings, not the first wave one', () => {
  world(twoWaves);
  const one = leverRowsFor('wave-1');
  const two = leverRowsFor('wave-2');
  ok(one !== two, 'both waves rendered the same settings');
  // MACHINES-AT-ONCE-RANGE-1: each wave's own choice, with its containers.
  ok(one.includes('30 days') && one.includes('Large: 30 machines at once, 2 engine containers'), 'wave-1 kept 30 days and Large');
  ok(two.includes('3 days') && two.includes('Pilot: 5 machines at once, 1 engine container'), 'wave-2 kept 3 days and Pilot');
});

// REBUILD-REMOVE-ACCEPT-1: the setting for a new system-assigned identity is
// gone with the rebuild, and no row names it. WAVE-KERNEL-LINE-1: six - no wave
// has a kernel setting; the kernel row names machines, and none here.
test('every one of the six settings is on the table, and no identity row', () => {
  world(twoWaves);
  const rows = leverRowsFor('wave-1');
  for (const label of ['Safety copy', 'On-demand capacity reservation for this wave',
                       'If files are on the temporary disk',
                       'How long the snapshot is kept',
                       'How many machines at once', 'Someone must sign off']) {
    ok(rows.includes(label), `missing: ${label}`);
  }
  ok(!rows.includes('If a new identity appears') && !rows.includes('Machines that get a new identity'), 'no identity row');
});

/** The rendered table as label -> value, so a check names the row it means. */
function pairs(html) {
  const out = {};
  for (const m of html.matchAll(/<td class="muted">([^<]*)<\/td><td>([^<]*)<\/td>/g)) { out[m[1]] = m[2]; }
  return out;
}

test('a wave with no settings of its own reads as the safe answer, not as blank', () => {
  // EACH row against its OWN label. Three of these settings share the words
  // "Stop and ask", so asking whether the phrase appears anywhere passes while
  // one of the three quietly says "Go on" - which is the one answer that turns
  // a stop into a migration nobody agreed to.
  world([{ vmId: '/vm/c', wave: 'wave-9', path: 'A' }]);
  const row = pairs(leverRowsFor('wave-9'));
  eq(row['If files are on the temporary disk'], 'Stop and ask', 'files on the temporary disk');
  eq(row['Machines whose kernel the product updates'], 'None in this wave', 'no machine updates its kernel');
  eq(row['How long the snapshot is kept'], '7 days', 'the default retention');
  eq(row['On-demand capacity reservation for this wave'], 'No', 'no reservation');
  // SIGNOFF-NULL-1: the safe answer for the sign-off is Yes - the engine's
  // gate refuses a wave whose machine says nothing about it. This said No.
  eq(row['Someone must sign off'], 'Yes', 'sign-off');
});

test('and a wave that DID choose to go on says so, for each one separately', () => {
  world(twoWaves);
  const row = pairs(leverRowsFor('wave-1'));
  eq(row['If files are on the temporary disk'], 'Go on', 'files on the temporary disk');
  // WAVE-KERNEL-LINE-1: no kernel setting of the wave - an old 'proceed' on a
  // machine shows nothing, and the machine is not named as one that updates.
  eq(row['Machines whose kernel the product updates'], 'None in this wave', 'no kernel row reads proceed');
  eq(row['Someone must sign off'], 'Yes', 'sign-off');
});

test('the temporary-disk warning survived the move off the deleted step', () => {
  world([
    { vmId: '/vm/loses', wave: 'wave-1', path: 'A', assessment: { sourceTempDisks: 1 }, target: { tempDisks: 0 } },
    { vmId: '/vm/gains', wave: 'wave-1', path: 'A', assessment: { sourceTempDisks: 1 }, target: { tempDisks: 4 } },
  ]);
  const out = tempSections();
  ok(out.includes('loses') && out.includes('These lose their temporary disk'), 'the losing machine');
  ok(out.includes('gains') && out.includes('These gain temporary disks'), 'the gaining machine');
});

test('and a machine the catalog could not report is admitted to, not counted as no change', () => {
  world([
    { vmId: '/vm/loses', wave: 'wave-1', path: 'A', assessment: { sourceTempDisks: 1 }, target: { tempDisks: 0 } },
    { vmId: '/vm/unknown', wave: 'wave-1', path: 'A', assessment: {}, target: {} },
  ]);
  const out = tempSections();
  ok(out.includes('Some could not be read.'), 'unknown was silently treated as no change');
  ok(!out.includes('unknown'), 'a machine with no reading must not be listed as losing or gaining');
});

// WAVE-AN-NAMES-1 rewrote this test to the new rule: a machine is named from
// the record the engine writes (acceleratedNetworkingOutcome), not only from
// an ensureOn setting. lin moves with nothing turned on, so it is on neither
// row; an entry from before v20 with no setting is decided by the move.
test('AN-PLAN-1: the machines the plan turns accelerated networking on for are named, per wave', () => {
  world([
    { vmId: '/vm/g1', wave: 'wave-1', path: 'A', policy: { acceleratedNetworking: 'ensureOn' }, acceleratedNetworkingOutcome: { turnsOn: true, unknownWhy: null } },
    { vmId: '/vm/lin', wave: 'wave-1', path: 'A', policy: {}, acceleratedNetworkingOutcome: { turnsOn: false, unknownWhy: null } },
    { vmId: '/vm/win', wave: 'wave-2', path: 'B', policy: { acceleratedNetworking: 'ensureOn' } },
  ]);
  const row = pairs(leverRowsFor('wave-1'));
  eq(row['Machines that get accelerated networking turned on'], 'g1');
  eq(row['Machines where the move decides accelerated networking'], 'None in this wave');
  ok(!leverRowsFor('wave-1').includes('win'), 'another wave is not named');
  world([{ vmId: '/vm/dec', wave: 'wave-1', path: 'A', policy: {}, acceleratedNetworkingOutcome: { turnsOn: null, unknownWhy: 'nics' } }]);
  const dec = pairs(leverRowsFor('wave-1'));
  eq(dec['Machines that get accelerated networking turned on'], 'None in this wave', 'none says so');
  eq(dec['Machines where the move decides accelerated networking'], 'dec', 'a record that does not know is decided by the move - never a no');
});

run('wave-flow');
