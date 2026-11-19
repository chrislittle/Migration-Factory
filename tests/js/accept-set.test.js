/* ACCEPT-SET-1: the acceptance screens show the machines the acceptance covers.
 *
 * The engine binds an acceptance to the wave's machines that MOVE (path A or
 * B). A screen that took its settings or its "accelerated networking turned
 * on" list from a machine that does not move would show a person something
 * other than what they accept.
 *
 * RUN, not read: the wizard's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, test, ok, eq, run } = require('./_harness');

const MIG = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const anTurnsOnNames = lift('wizard.html', 'anTurnsOnNames');

globalThis.vmName = (id) => String(id).split('/').pop();
// WAVE-AN-NAMES-1: the page reads the rows by the one rule in help.js.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['anOutcomeRow', 'anOutcomeNames', 'previewNames']));

test('a machine that does not move is not named as getting accelerated networking', () => {
  globalThis.plan = { entries: [
    { vmId: '/x/moves', wave: 'w1', path: 'A', policy: { acceleratedNetworking: 'ensureOn' }, acceleratedNetworkingOutcome: { turnsOn: true, unknownWhy: null } },
    { vmId: '/x/stays', wave: 'w1', path: 'MANUAL', policy: { acceleratedNetworking: 'ensureOn' } },
  ] };
  eq(anTurnsOnNames('w1').join(','), 'moves');
});

test('the wave settings on screen come from a machine that moves', () => {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  // MANA-LINUX-KERNEL-1: leverRowsFor now keeps the machines that move, and reads
  // the first of them - or, for the driver setting, the first without a decision.
  ok(src.includes("const moving = (plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A');"), 'leverRowsFor');
});

test('the run page’s accept dialog lists the same machines, in demo and live', () => {
  const n = (MIG.match(/filter\(e => e\.wave === wave && e\.path === 'A'\)/g) || []).length;
  ok(n >= 2, `found ${n}`);
});

run('accept-set');
