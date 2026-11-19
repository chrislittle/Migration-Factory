/* REBUILD-PICKER-1: the targets step names the method of each option, and
 * recommends the in-place upgrade.
 *
 * Before: the series list said "v5", "v6", "v7" and nothing said which one
 * rebuilt the machine, except an "Identity replaced" tag for a machine with a
 * system-assigned identity. Details said "Rollback: Yes" for a rebuild, which
 * is not true as a person reads it: a rollback rebuilds the VM again around
 * new disks, and what the first rebuild removed does not come back.
 *
 * The layout chosen on 2026-11-01 (mock-up B): the series list names
 * the series AND the method, "(Recommended)" only on the option the machine
 * starts on, "(Not recommended)" on every rebuild. A line under the row only
 * for a rebuild. Counts above the table. Nothing opens on its own.
 *
 * RUN: the page's own functions, with machines shaped like target-advice.json.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = require('./_identity').help(Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['seriesLabel', 'machineStarted', 'previewNames'])));

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const WAVES = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.shortSize = constArrow('shortSize');
globalThis.fill = constArrow('fill');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.reasonText = (c) => String(c);
// REBUILD-REMOVE-PLAN-1 (2026-11-07): the targets step offers no rebuild, so the
// tests of its rebuild items, pills, lines, counts and Details that were here are gone;
// tests/js/rebuild-remove-targets.test.js holds the step to the new rule.
// REBUILD-REMOVE-ACCEPT-1: and the sign-off row and the wave editor's line that named
// the machines an earlier plan rebuilds are gone with the acceptances. The engine
// refuses such a plan; tests/js/rebuild-remove-accept.test.js holds the pages to it.

test('the wave editor and the sign-off name no machine that rebuilds any more', () => {
  eq(typeof VmfHelp.rebuildNames, 'undefined', 'help.js has no rebuildNames');
  ok(!WIZ.includes('VmfHelp.rebuildNames(') && !WIZ.includes('UX.lvRebuild'), 'the sign-off asks no such rule');
  ok(!WAVES.includes('VmfHelp.rebuildNames(') && !WAVES.includes('rebuildLine('), 'the wave editor asks no such rule');
});

test('RUN: the sign-off row of the Preview still counts and names its machines', () => {
  globalThis.vmName = (id) => String(id).split('/').pop();
  const prev = (n, w) => ({ vmId: `/x/${n}`, wave: w, path: 'A', target: { choice: { method: 'preview' } } });
  globalThis.plan = { entries: [prev('a', 'w1'), { vmId: '/x/b', wave: 'w1', path: 'A' }, prev('c', 'w2'), prev('d', 'w2')] };
  const previewText = liftAll('wizard.html', ['previewText']).previewText;
  eq(previewText('w1'), '1 machine: a');
  eq(previewText('w2'), '2 machines: c, d');
  eq(previewText('w3'), UX.lvNone);
});

// From the PR #690 review: a system-assigned identity is an identity, and its
// access is role assignments - never an account, on any screen.
test('the identity words say identity, object ID and role assignments, never account, on every page and in every reason', () => {
  const tables = [['wizard.html', 'UX'], ['waves.html', 'UX'], ['migrations.html', 'UX_LEVER'], ['migrations.html', 'UX_ACT'], ['migrations.html', 'UX_MISC']];
  const bad = [];
  for (const [file, name] of tables) {
    const table = liftConst(file, name);
    for (const [k, v] of Object.entries(table)) {
      const text = typeof v === 'string' ? v : JSON.stringify(v);
      if (/identit|^id[A-Z]|Id[A-Z]|^lvIdentity|decideId|restoreId/.test(k + ' ' + text) && /\baccount\b/i.test(text.replace(/storage account/gi, ''))) bad.push(`${file}:${name}.${k}`);
    }
  }
  const data = (f) => JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', f), 'utf8'));
  const flat = (o, at, out) => { if (typeof o === 'string') { out.push([at, o]); } else if (o && typeof o === 'object') { for (const [k, v] of Object.entries(o)) flat(v, `${at}.${k}`, out); } return out; };
  for (const f of ['stop-reasons.json', 'assessment-reasons.json']) {
    // fields describes the file for its authors; nobody reads it on a screen.
    for (const [at, s] of flat(data(f), f, []).filter(([at]) => !at.startsWith(`${f}.fields.`))) {
      if (/system-assigned identity/i.test(s) && /\baccount\b/i.test(s.replace(/storage account/gi, ''))) bad.push(at);
    }
  }
  eq(bad.join(', '), '');
});

run('rebuild-picker');
