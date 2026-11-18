/* WAVE-EDIT-RUNNING-1: the wave editor moves nothing into or out of a running
 * wave (2026-09-28: refuse). The engine refuses the save too; the page
 * does not offer what the engine would refuse.
 *
 * RUN, not read: the page's own moveTo.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, ok, eq, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const UX = liftConst('waves.html', 'UX');
const moveTo = lift('waves.html', 'moveTo');

function world(runningWaves) {
  const bar = { textContent: '', style: { display: 'none' } };
  // WAVE-EDITOR-TICK-1: the line that names a machine moved out of another wave.
  const moved = { textContent: '', style: { display: 'none' } };
  globalThis.UX = UX;
  globalThis.$ = (s) => (s === '#warnbar' ? bar : s === '#moved' ? moved : null);
  globalThis.vmName = (id) => id;
  globalThis.layoutWaveOf = lift('waves.html', 'layoutWaveOf');
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'b', wave: 'w1' }, { vmId: 'c', wave: 'w2' }];
  globalThis.layout = new Map([['w1', { vmIds: ['a', 'b'] }], ['w2', { vmIds: ['c'] }]]);
  globalThis.selection = new Set();
  globalThis.expand = (ids) => ids;
  globalThis.started = () => false;
  globalThis.render = () => {};
  globalThis.waveMigrating = (w) => runningWaves.includes(w);
  // WAVE-RUNNING-LEASE-1: a worker at work, not a stopped worker's hold.
  globalThis.waveHoldOf = (w) => (runningWaves.includes(w) ? 'working' : 'none');
  return bar;
}

// WAVE-LEVER-OVERRIDE-1: writeLayout lists the settings changed on each card
// (changedOf) and draws each card again after a save (WAVE_DEFAULTS).
globalThis.changedOf = () => ({});
// WAVE-LEVER-RESET-1: and the machines reset to the value of the wave (resetOf).
globalThis.resetOf = () => ({});
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
test('nothing moves INTO a running wave, and the page says why', () => {
  const bar = world(['w1']);
  moveTo('w1', ['c']);
  eq(layout.get('w1').vmIds.join(','), 'a,b');
  eq(layout.get('w2').vmIds.join(','), 'c');
  ok(bar.textContent.includes('w1') && bar.style.display === 'block', bar.textContent);
});

test('nothing moves OUT of a running wave, and the page says why', () => {
  const bar = world(['w1']);
  moveTo('w2', ['b', 'c']);
  eq(layout.get('w1').vmIds.join(','), 'a,b', 'b stays in the running wave');
  ok(bar.textContent === UX.runningMoveOut.replace('{wave}', 'w1') && bar.style.display === 'block', bar.textContent);
});

test('a save sends a running wave with its machines and NO settings', async () => {
  world(['w1']);
  const lever = { capacityGate: 'BestEffort', requireApproval: true, onDDataFound: 'stop', onDriverBelowFloor: 'stop',
    onSystemAssignedIdentity: 'stop', keepSnapshotDays: 7, throttle: 3 };
  layout.get('w1').vmIds = ['a', 'b']; Object.assign(layout.get('w1'), lever);
  Object.assign(layout.get('w2'), lever, { onDDataFound: 'proceed' });
  let sent = null;
  globalThis.apiPost = async (_u, body) => { sent = body; return {}; };
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => b;
  globalThis.snapshot = () => 's';
  globalThis.original = '';
  // WAVE-OWN-PICTURE-1: the save of a real run, which reads the plan again.
  globalThis.DEMO_MODE = false;
  globalThis.reloadPlan = async () => {};
  // PLAN-WRITE-RACE-1: the save quotes the plan version the page read.
  globalThis.planVersion = 'ver-1';
  await lift('waves.html', 'writeLayout')();
  const w1 = sent.waves.find(w => w.name === 'w1');
  const w2 = sent.waves.find(w => w.name === 'w2');
  eq(Object.keys(w1).sort().join(','), 'name,vmIds', 'a running wave sends no setting - one would change a machine holding its own');
  eq(w1.vmIds.join(','), 'a,b');
  eq(w2.onDDataFound, 'proceed', 'a wave that is not running sends its settings as before');
  eq(w2.throttle, 3);
});

test('between waves that are not running, machines move as before', () => {
  world([]);
  moveTo('w2', ['b']);
  eq(layout.get('w1').vmIds.join(','), 'a');
  eq(layout.get('w2').vmIds.join(','), 'c,b');
});

test('a running wave’s settings are shown, not offered: every control on the card follows one editable flag', () => {
  ok(SRC.includes('const editable = canEdit && !running;'));
  // Each control, from its data attribute to the end of its tag.
  // REBUILD-REMOVE-ACCEPT-1: no identity control - the setting is gone with the rebuild.
  for (const attr of ['rename', 'cap', 'data', 'keep', 'thr', 'appr']) {
    const at = SRC.indexOf(`data-${attr}="\${esc(name)}"`);
    ok(at > 0, `the card has its ${attr} control`);
    const tag = SRC.slice(at, SRC.indexOf('>', SRC.indexOf('}', SRC.indexOf('disabled', at)) ) + 1);
    ok(/\$\{editable( && !apprLocked)? \? '' : 'disabled'\}/.test(tag), `${attr} is disabled by editable: ${tag}`);
  }
});

test('a running wave shows its tag, and offers no Send here, no Delete, no Remove and no drag', () => {
  // WAVE-RUNNING-LEASE-1: Held, in place of Running, for a stopped worker's hold alone.
  ok(SRC.includes("${running ? `<span class=\"pill warn\" title=\"${esc(waveHoldOf(name) === 'endedHold' ? UX.endedHoldTip : UX.runningTip)}\">${esc(waveHoldOf(name) === 'endedHold' ? UX.endedHoldTag : UX.runningTag)}</span>` : ''}"), 'the Running tag');
  ok(/\$\{running \? '' : `<button class="btn small ghost" data-moveto=[\s\S]*?data-del=[\s\S]*?`\}/.test(SRC), 'Send here and Delete are left out');
  ok(SRC.includes('inWave && !waveMigrating(e.wave)) ? `<button type="button" class="btn small ghost" data-takeout='), 'Remove is left out');
  ok(SRC.includes("(canEdit && !isStarted && !waveMigrating(e.wave)) ? 'draggable=\"true\"'"), 'a waiting machine of a running wave cannot be dragged');
});

run('wave-running');
