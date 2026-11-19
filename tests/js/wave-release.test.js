/* WAVE-EDIT-RESERVE-1: a reserved wave that has not run offers Release.
 *
 * Close-out releases a reservation after a wave runs. Before that, a held
 * reservation stops a save that would change the wave (it is the only record
 * of something that bills), so the way out has to be on the screen - the
 * engine's release operation had no control since the Capacity step went.
 *
 * RUN, not read: the page's own control.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const UX = liftConst('waves.html', 'UX');
const reserveControl = lift('waves.html', 'reserveControl');

function world({ state = 'held', edit = true, migrating = false, billing = true } = {}) {
  globalThis.UX = UX;
  globalThis.esc = (s) => String(s ?? '');
  globalThis.claims = new Map([['w1', state]]);
  globalThis.billingWaves = new Set(billing ? ['w1'] : []);
  globalThis.canEdit = edit;
  globalThis.waveMigrating = () => migrating;
  globalThis.dirty = () => false;
}

test('a held reservation shows Reserved and Release', () => {
  world();
  const html = reserveControl('w1');
  ok(html.includes(UX.reserveHeld) && html.includes('data-release="w1"'), html);
});

test('not while machines of the wave are mid-migration and may be using it', () => {
  world({ migrating: true });
  ok(!reserveControl('w1').includes('data-release'));
});

test('migrating means a machine of THIS wave with a state that is not final - PLANNED counts, the engine writes it when a worker takes the machine', () => {
  // WAVE-RUNNING-PLANNED-1: the rule is help.js's, which the page loads.
  // WAVE-RUNNING-LEASE-1: with the leases, which none of these machines has.
  globalThis.VmfHelp = Object.assign(liftAll('help.js', ['machineHold', 'machineAtWork', 'waveHold']), { idKey: (id) => String(id).toLowerCase() });
  globalThis.leases = new Map();
  const { waveMigrating } = liftAll('waves.html', ['waveMigrating', 'waveHoldOf']);
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'b', wave: 'w1' }, { vmId: 'c', wave: 'w2' }];
  globalThis.states = new Map([['a', 'MIGRATED'], ['b', 'PLANNED'], ['c', 'CONVERTING']]);
  ok(waveMigrating('w1'), 'a machine taken by a worker reads PLANNED');
  ok(waveMigrating('w2'), 'a machine converting is');
  globalThis.states = new Map([['a', 'MIGRATED'], ['b', 'NEEDS_DECISION']]);
  ok(!waveMigrating('w1'), 'finished and parked machines are not using it');
  globalThis.states = new Map([['a', 'MIGRATED']]);
  ok(!waveMigrating('w1'), 'a machine waiting for a slot has no state yet');
});

test('not for somebody who cannot edit', () => {
  world({ edit: false });
  ok(!reserveControl('w1').includes('data-release'));
});

test('nothing to release while it is being made and nothing bills yet, or when nothing is held', () => {
  world({ state: 'working', billing: false });
  ok(!reserveControl('w1').includes('data-release'), 'reserving');
  world({ state: null, billing: false });
  ok(!reserveControl('w1').includes('data-release'), 'none');
});

test('a partly blocked wave still bills for the parts it reserved, so it offers Release too', () => {
  world({ state: 'blocked', billing: true });
  const html = reserveControl('w1');
  ok(html.includes(UX.reserveBlocked) && html.includes('data-release="w1"'), html);
});

test('the control shows for a wave that holds a reservation even when its setting now reads on demand', () => {
  ok(SRC.includes("(capNow !== 'Reserved' && !billingWaves.has(name))"), 'driven by the claim, not the lever');
});

test('it asks for a note in the page, and waits for the records - a failed read is not an answer', () => {
  ok(/function releaseCapacity\([\s\S]*?confirmInPlace\([\s\S]*?required: true/.test(SRC), 'a note, with Cancel and Escape');
  ok(SRC.includes('engine/release'), 'the engine operation');
  ok(SRC.includes('((await loadClaims()) && !billingWaves.has(wave))'), 'released only on a read that worked');
  ok(/releaseFailed/.test(SRC), 'an engine refusal is shown');
});

run('wave-release');
