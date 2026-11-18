/* WAVE-MIX-2: change one machine's size series in the wave editor.
 *
 * RUN, not read: the page's own row and panel. The engine decides what is
 * available; these prove the page shows its answer, opens with a way back
 * (hard rule 11), and never offers Apply over unsaved wave changes.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, ok, eq, run } = require('./_harness');
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const UX = liftConst('waves.html', 'UX');
const machineRow = lift('waves.html', 'machineRow');
const changePanel = lift('waves.html', 'changePanel');

const vm = { vmId: '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web', wave: 'dev-wave' };
const answer = {
  VmId: vm.vmId, Current: 'v6', CurrentSize: 'Standard_D2ds_v6',
  Options: [
    { option: 'v5', supported: true, targetSize: 'Standard_D2ds_v5', rebuild: false },
    { option: 'v6', supported: true, current: true, targetSize: 'Standard_D2ds_v6', rebuild: false },
    { option: 'v7', supported: false, targetSize: null, why: ['not-in-region'] },
  ],
};

function world({ edit = true, startedIds = [], open = null, pick = null, isDirty = false, a = answer, running = false, migrating = false } = {}) {
  globalThis.waveStarted = () => running;
  globalThis.UX = UX;
  globalThis.esc = (s) => String(s ?? '');
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
  globalThis.sizeMove = () => '';
  globalThis.dirty = () => isDirty;
  globalThis.change = { vmId: open, answer: open ? a : null, pick, busy: false, err: '' };
  globalThis.changePanel = changePanel;
}

test('a machine that has not started offers Change target, in a wave and in the list', () => {
  world();
  ok(machineRow(vm, true).includes(`data-change="${vm.vmId}"`), 'in a wave');
  ok(machineRow(vm, false).includes(`data-change="${vm.vmId}"`), 'in the list');
});

test('not once the machine has started, and not for somebody who cannot edit', () => {
  world({ startedIds: [vm.vmId] });
  ok(!machineRow(vm, true).includes('data-change'), 'started');
  world({ edit: false });
  ok(!machineRow(vm, true).includes('data-change'), 'no edit right');
});

test('not while any machine in its wave has started - the engine refuses that too', () => {
  world({ running: true });
  ok(!machineRow(vm, true).includes('data-change'));
});

test('waveStarted asks the saved states of the machines in the SAME wave, and never for the machines with no wave', () => {
  const waveStarted = lift('waves.html', 'waveStarted');
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'b', wave: 'w1' }, { vmId: 'c', wave: 'w2' }, { vmId: 'd', wave: 'unscheduled' }];
  globalThis.states = new Map([['b', 'PLANNED']]);
  ok(waveStarted('w1'), 'b has a state, even PLANNED');
  ok(!waveStarted('w2'), 'another wave');
  globalThis.states = new Map([['d', 'MIGRATED']]);
  ok(!waveStarted('unscheduled'));
});

test('open, the button reads Cancel and the panel has a Cancel too', () => {
  world({ open: vm.vmId });
  const html = machineRow(vm, true);
  ok(html.includes('aria-expanded="true"') && html.includes(`>${UX.cancel}</button>`), 'the button is the way back');
  ok(html.includes('data-changecancel'), 'the panel has its own Cancel');
});

test('each series shows its size; one the engine refused is disabled and says Not available', () => {
  world({ open: vm.vmId });
  const html = changePanel(vm);
  ok(html.includes('D2ds_v5') && html.includes('D2ds_v6'), html);
  ok(/value="v7" disabled/.test(html), 'v7 cannot be picked');
  ok(html.includes(UX.changeNot), 'said as the product says it');
});

test('Apply is off until another series is picked, and off over unsaved wave changes', () => {
  world({ open: vm.vmId });
  ok(/data-changeapply disabled/.test(changePanel(vm)), 'the current series is not a change');
  world({ open: vm.vmId, pick: 'v5' });
  ok(!/data-changeapply disabled/.test(changePanel(vm)), 'a different series may be applied');
  world({ open: vm.vmId, pick: 'v5', isDirty: true });
  const html = changePanel(vm);
  ok(/data-changeapply disabled/.test(html) && html.includes(UX.changeSaveFirst), 'save first, and it says so');
});

// REBUILD-REMOVE-ACCEPT-1: no option is a rebuild (target-advice v28), so the
// panel has no rebuild pill and no words for one, even from older advice.
test('no option says it rebuilds the machine, even one from older advice that carries rebuild', () => {
  const a = { ...answer, Options: answer.Options.map(o => o.option === 'v5' ? { ...o, rebuild: true } : o) };
  world({ open: vm.vmId, a });
  ok(!/[Rr]ebuild/.test(changePanel(vm)), 'no rebuild words in the panel');
  eq(UX.changeRebuild, undefined, 'the page has no words for a rebuild option');
});

test('Escape closes it, and an apply quotes the plan version the page read', () => {
  // WAVE-LEVER-OVERRIDE-1: the handler became onEscape, which also closes a ?
  // helper on a wave card; tests/js/wave-lever-override.test.js runs it.
  ok(/if \(change\.vmId\) \{ closeChange\(\); return; \}/.test(SRC) && SRC.includes("addEventListener('keydown', onEscape)"), 'Escape handler');
  ok(SRC.includes('runBody({ vmId: a.VmId, option: pick, planVersion })'), 'the version travels');
  ok(SRC.includes("{ asVersioned: true }"), 'the version the service issued');
});

// BSV2-TARGET-1: a B v1 machine on v5 goes to a Bsv2 size. The series a
// person reads is Bsv2, not v5, which is only the option the engine plans it on.
test('a Bsv2 size is shown under its own series, Bsv2, never as v5', () => {
  const b = { VmId: vm.vmId, Current: 'v5', CurrentSize: 'Standard_B2s_v2', Options: [
    { option: 'v5', supported: true, current: true, targetSize: 'Standard_B2s_v2', rebuild: false },
    { option: 'v6', supported: true, targetSize: 'Standard_D2ds_v6', rebuild: false },
    { option: 'v7', supported: false, targetSize: null, why: ['not-in-region'] }] };
  world({ open: vm.vmId, a: b });
  const html = changePanel(vm);
  ok(html.includes('<span class="mono">Bsv2</span>'), 'the Bsv2 size is under Bsv2');
  ok(!html.includes('<span class="mono">v5</span>'), 'and not under v5');
  ok(html.includes('value="v5"'), 'the option it sends is still v5');
  ok(html.includes('<span class="mono">v6</span>'), 'every other series keeps its name');
});
run('wave-change');
