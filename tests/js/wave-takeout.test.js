/* WAVE-TAKEOUT-1, from the first Azure test, 2026-09-24: a machine put in a
 * wave could only leave it by being dragged back to the list, which nothing
 * on screen said. Hard rule 11: anything that opens must offer a way back.
 *
 * RUN, not read: the page's own row.
 */
'use strict';
const { lift, liftConst, test, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
const machineRow = lift('waves.html', 'machineRow');

function world({ edit = true, startedIds = [], migrating = false } = {}) {
  globalThis.UX = UX;
  globalThis.esc = (s) => String(s);
  globalThis.canEdit = edit;
  globalThis.selection = new Set();
  globalThis.started = (id) => startedIds.includes(id);
  globalThis.avsetOf = () => null;
  globalThis.vmName = (id) => id.split('/').pop();
  globalThis.rgOf = () => 'rg';
  globalThis.filter = { scope: 'all', tagKey: '' };
  globalThis.tagValue = () => '';
  globalThis.newIdentity = () => false;
  // WAVE-EDITOR-TICK-1: the wave a machine is in now (its own test is wave-editor-tick).
  globalThis.layoutWaveOf = () => null;
  globalThis.waveMigrating = () => migrating;
  // WAVE-EDITOR-1: the row's size line (its own test is wave-editor-sizes).
  globalThis.sizeMove = () => '';
  // WAVE-MIX-2: the size series panel (its own test is wave-change).
  globalThis.change = { vmId: null };
  globalThis.changePanel = () => '';
  globalThis.waveStarted = () => false;
}
const vm = { vmId: '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web', wave: 'dev-wave' };

test('a machine in a wave can be taken out', () => {
  world();
  const html = machineRow(vm, true);
  ok(html.includes(`data-takeout="${vm.vmId}"`) && html.includes(UX.takeOut), html);
});

test('not from the list of machines with no wave, where there is nothing to leave', () => {
  world();
  ok(!machineRow(vm, false).includes('data-takeout'));
});

test('not once the machine has started, and not for somebody who cannot edit', () => {
  world({ startedIds: [vm.vmId] });
  ok(!machineRow(vm, true).includes('data-takeout'), 'started');
  world({ edit: false });
  ok(!machineRow(vm, true).includes('data-takeout'), 'no edit right');
});

test('WAVE-EDIT-RUNNING-1: not from a wave that is running - nothing leaves a running wave', () => {
  world({ migrating: true });
  ok(!machineRow(vm, true).includes('data-takeout'));
});

run('wave-takeout');
