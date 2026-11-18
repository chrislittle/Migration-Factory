/* EOL-RELEASE-AN-1 (review, 2026-11-15): the settings table of a wave on the
 * Migrations page names each machine whose Linux release an approver accepted
 * at Checking after the end of standard support (plan value
 * onReleaseEndOfLife = proceed, written by the decision), the way it names the
 * machines whose kernel the product updates.
 *
 * RUN, not read: the row's own expression, lifted out of migrations.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const SRC = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const UX_LEVER = liftConst('migrations.html', 'UX_LEVER');

const rowLine = SRC.split(/\r?\n/).find(l => l.includes('[UX_LEVER.eolMachines,'));

test('the page declares the words of the row', () => {
  eq(UX_LEVER.eolMachines, 'Machines whose Linux release an approver accepted after the end of standard support');
});

test('the settings table has the row, beside the machines whose kernel the product updates', () => {
  ok(rowLine, 'a row of the acceptance table');
  const kernelAt = SRC.indexOf('[UX_LEVER.kernelMachines,');
  ok(kernelAt > 0 && SRC.indexOf('[UX_LEVER.eolMachines,') > kernelAt, 'after the kernel row');
});

test('the row names each accepted machine, and None when there is none', () => {
  const expr = rowLine.trim().replace(/^\[UX_LEVER\.eolMachines,\s*/, '').replace(/\],\s*$/, '');
  const value = new Function('entries', 'vmName', 'UX_LEVER', `return (${expr});`);
  const vmName = (id) => String(id).split('/').pop();
  const entries = [
    { vmId: '/s/rg/vm-a', policy: { onReleaseEndOfLife: 'proceed' } },
    { vmId: '/s/rg/vm-b', policy: { onReleaseEndOfLife: 'stop' } },
    { vmId: '/s/rg/vm-c', policy: {} },
    { vmId: '/s/rg/vm-d', policy: { onReleaseEndOfLife: 'proceed' } },
  ];
  eq(value(entries, vmName, UX_LEVER), 'vm-a, vm-d');
  eq(value([entries[1], entries[2]], vmName, UX_LEVER), UX_LEVER.identityNone);
  eq(value(undefined, vmName, UX_LEVER), UX_LEVER.identityNone);
});

run('eol-release-accepted');
