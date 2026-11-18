/* CAPACITY-WORDS-1: the capacity line of the machine panel, in Azure's words,
 * and the Activity label of the reservation only where the wave makes one.
 *
 * Found 2026-11-08: the line "Capacity: no capacity reservation. Its wave did not ask
 * for one." did not use Azure's name for an ODCR. The
 * same lab run showed that line for a machine IN its own capacity reservation
 * group, and "Creating the on-demand capacity reservation for this wave" for a
 * wave set to None.
 *
 * The words below are the approved words, exact. The test holds them so the
 * page cannot drift from what was approved.
 *
 * RUN: the page's own capacityLine and stepText, with the page's own words.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];

const { capacityLine, stepText } = liftAll('migrations.html', ['capacityLine', 'stepText']);

const OWNER = {
  used:   'On-demand capacity reservation: this machine used one of the reserved slots of its wave.',
  none:   'No on-demand capacity reservation. Its wave does not reserve capacity.',
  group:  'Capacity reservation group: crg-app. The machine stays in this group.',
  avset:  'No on-demand capacity reservation. Azure does not allow one for a machine in an availability set.',
};

const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01';
const OWN = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/crg-app';
const OURS = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-w1-crg';

const reservedClaim = (associated) => ({
  wave: 'w1', state: 'CONSUMED',
  reservation: { groupId: OURS, reservationId: OURS + '/capacityReservations/r1' },
  associatedVmIds: associated ? [VM] : [],
});
const doc = (vmConfig, state) => ({ state: state || 'MIGRATED', captured: vmConfig === undefined ? undefined : { vmConfig } });
const entry = (gate, assessment) => ({ vmId: VM, wave: 'w1', policy: { capacityGate: gate }, assessment: assessment || {} });

test('case 1: the claim names the machine - it used a reserved slot of its wave', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: null }), entry('Reserved'), VM, [reservedClaim(true)]), OWNER.used);
});

test('case 2: a wave set to None, a machine in no group', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: null }), entry('BestEffort'), VM, []), OWNER.none);
});

test('case 2: a plan entry that names no capacity setting is not a Reserved wave', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: null }), { vmId: VM, assessment: {} }, VM, []), OWNER.none);
});

test('case 3: the group PRECHECK recorded, which this migration did not make (the lab machine)', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: OWN }), entry('BestEffort'), VM, []), OWNER.group);
});

test('case 3 in a Reserved wave too: the machine stays in its group and takes no slot', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: OWN }), entry('Reserved'), VM, [reservedClaim(false)]), OWNER.group);
});

test('case 3 before PRECHECK: the group the assessment found, from the plan entry', () => {
  eq(capacityLine(doc(undefined, 'PLANNED'), entry('BestEffort', { capacityReservationGroupId: OWN }), VM, []), OWNER.group);
});

test('OLD-STATE-READERS-PAGE-1: once PRECHECK wrote the capture, only the capture says - never the plan entry (every capture holds the field, vm-state v47)', () => {
  ok(!/hasOwnProperty\.call\(vmConfig, 'capacityReservationGroupId'\)/.test(capacityLine.toString()), 'no reading of a capture with no field');
  eq(capacityLine(doc({ size: 'Standard_D2s_v4' }), entry('BestEffort', { capacityReservationGroupId: OWN }), VM, []), OWNER.none);
});

test('PRECHECK found no group although the assessment did: the record of PRECHECK wins', () => {
  eq(capacityLine(doc({ capacityReservationGroupId: null }), entry('BestEffort', { capacityReservationGroupId: OWN }), VM, []), OWNER.none);
});

test('a group of this migration is not the machine\'s own group, in any letter case', () => {
  const upper = OURS.toUpperCase();
  eq(capacityLine(doc({ capacityReservationGroupId: upper }), entry('Reserved'), VM, [reservedClaim(true)]), OWNER.used);
  // reservationAsked names the group of a run that is still reserving.
  const asked = { wave: 'w1', state: 'RESERVING', reservationAsked: { groupId: OURS }, associatedVmIds: [] };
  eq(capacityLine(doc({ capacityReservationGroupId: OURS }), entry('BestEffort'), VM, [asked]), OWNER.none);
});

test('the group name is the last part of its resource id, and only that', () => {
  const said = capacityLine(doc({ capacityReservationGroupId: OWN }), entry('BestEffort'), VM, []);
  ok(!/subscriptions|resourceGroups/.test(said), said);
});

test('case 4: an availability set, from the capture or from the plan entry', () => {
  eq(capacityLine(doc({ availabilitySetId: '/x/avset1', capacityReservationGroupId: null }), entry('Reserved'), VM, [reservedClaim(false)]), OWNER.avset);
  eq(capacityLine(doc(undefined, 'PLANNED'), entry('BestEffort', { availabilitySetId: '/x/avset1' }), VM, []), OWNER.avset);
});

test('a Reserved wave whose machine took no slot never says its wave does not reserve capacity', () => {
  const done = capacityLine(doc({ capacityReservationGroupId: null }, 'MIGRATED'), entry('Reserved'), VM, [reservedClaim(false)]);
  eq(done, 'No on-demand capacity reservation.');
  // Before the move ends the machine can still join the group of its wave.
  eq(capacityLine(doc({ capacityReservationGroupId: null }, 'CONVERTING'), entry('Reserved'), VM, [reservedClaim(false)]), '');
});

test('the no-slot line shows only where the machine cannot join any more (review finding)', () => {
  const at = (state) => capacityLine(doc({ capacityReservationGroupId: null }, state), entry('Reserved'), VM, [reservedClaim(false)]);
  // Migrated, Not migrated, Rolled back: the rollback leaves the group of the wave.
  for (const state of ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK']) { eq(at(state), 'No on-demand capacity reservation.', state); }
  // Needs a decision: it stopped before any change and resumes after Accept or
  // Try again, so it can still take a slot. Needs attention: it may still be in
  // the group. Neither says "no reservation" yet.
  for (const state of ['NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION', 'PLANNED', 'PRECHECK', 'RESIZING']) { eq(at(state), '', state); }
});

test('the old words are gone from the page', () => {
  const all = JSON.stringify(globalThis.UX_ACT);
  ok(!/did not ask for one/.test(all), 'did not ask for one');
  ok(!/took one of the reserved slots/.test(all), 'took one of the reserved slots');
  ok(!/"Capacity:"/.test(all), 'the Capacity: label');
});

// ---- the Activity label (defect 2) ----

test('the per-machine note of a machine in its own group says its sentence, not "Creating the reservation"', () => {
  const e = { step: 'odcr', outcome: 'info', vmId: VM, detail: "The machine stays in its capacity reservation group 'crg-app'." };
  eq(stepText(e), e.detail);
  ok(stepText(e) !== UX_STEP.reserveCap);
});

test('the per-machine warnings of Path A say their sentence too', () => {
  for (const detail of [
    "The assessment found the machine in the capacity reservation group 'crg-app', so the capacity reservation of the wave holds no place for it. The machine is no longer in that group, so it moves with no capacity reservation.",
    'The wave holds a capacity reservation of Standard_D2s_v6, but none in this machine\'s subscription, region and zone. This machine moves with no capacity reservation.',
  ]) {
    eq(stepText({ step: 'odcr', outcome: 'warn', vmId: VM, detail }), detail);
  }
});

test('the availability-set note of a machine is the engine sentence, as written', () => {
  // MANUAL-REVIEW-1: the engine writes a sentence now, so the page has no label of its own for it.
  const detail = 'The machine is in an availability set, so Azure does not allow an on-demand capacity reservation for it.';
  eq(stepText({ step: 'odcr', outcome: 'warn', vmId: VM, detail }), detail);
  ok(!('noReserve' in UX_STEP), 'no label for a line the engine no longer writes');
});

test('the run that makes the reservation keeps the label, and a release keeps its own', () => {
  eq(stepText({ step: 'odcr', outcome: 'start', detail: 'reserving 2x Standard_D2s_v6 in centralus' }), UX_STEP.reserveCap);
  eq(stepText({ step: 'odcr', outcome: 'ok', detail: 'Azure holds an on-demand capacity reservation for 2 machines of Standard_D2s_v6 in centralus.' }), UX_STEP.reserveCap);
  eq(stepText({ step: 'odcr', outcome: 'ok', detail: 'RELEASED Standard_D2s_v6@centralus' }), UX_STEP.releaseCap);
});

// MANUAL-REVIEW-1: the sample activity line of a made reservation is in the
// form the engine writes (New-VmfWaveReservation), with no region - the
// approved words, exact. Its hover text is what a person reads in demo mode.
test('the sample hover line of a made reservation is the approved text, and the row keeps its label', () => {
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.js'), 'utf8');
  const lines = src.split('\n').filter(l => /step: 'odcr', outcome: 'ok', detail:/.test(l));
  eq(lines.length, 1);
  const m = /detail: '([^']*)'/.exec(lines[0]);
  eq(m[1], 'Azure holds an on-demand capacity reservation for 2 machines of Standard_D2ds_v6.');
  eq(stepText({ step: 'odcr', outcome: 'ok', detail: m[1] }), UX_STEP.reserveCap);
});

run('capacity-words');
