/* RESTORE-ROW-1: a restored machine's row is chips and the size it is on.
 *
 * The owner, on a real screen: the status cell carried "Rolling the machine back
 * to the size it started on · 37s ago" under its pills, and the size cell read
 * "Standard_D2s_v4 was on Standard_D2s_v7". No other row talks like that.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
// STATUS-WORDS-1: the row starts from the status of the machine.
const rowStart = SRC.indexOf('const st = v.st;');
const ROW = SRC.slice(rowStart, SRC.indexOf('return `<tr class="vm-row"', rowStart));

test('WAVE-ROW-WORDS-1: nothing beside the pills - no time, no sentence', () => {
  ok(!ROW.includes('stuckNote'), 'the loose time is gone');
  ok(!/putting\.doing \?\? UX_ACT\.puttingBack\)\}\s*&middot;/.test(ROW), 'the old sentence is gone');
  // LAB-UX-1: and a restored machine shows no Migrated pill beside Restored.
  // STATUS-WORDS-1: and ONE pill - no Restoring or Restored beside the state.
  ok(SRC.includes("${notMoved ? notMovedPill(notMoved) : machinePill(doc, st, { since: st.key === 'step' ? st.since : null, stuck, awaits, hold, braked: halted, doing })}${pairWaitTag}</td>"), 'the status cell is pills only');
});

test('the step it is on, and when it started, are hover text on the pill', () => {
  // STATUS-WORDS-1: RUN - the one pill of a restore carries both on hover.
  globalThis.esc = (s) => String(s ?? '');
  globalThis.ago = (iso) => `AGO(${iso})`;
  globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
  globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
  globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
  const { statusPill } = liftAll('migrations.html', ['restoredPill', 'statusWord', 'statusPill']);
  const pill = statusPill({ key: 'restoring', since: '2026-11-04T17:20:00Z' }, { doing: 'Building a disk from the safety copy' });
  ok(pill.includes('title="Building a disk from the safety copy - ' + UX_MISC.startedAgo.replace('{ago}', 'AGO(2026-11-04T17:20:00Z)') + '"'), `on hover: ${pill}`);
  ok(ROW.includes('const doing = putting?.doing ??'), 'the row passes the step it is on');
});

test('a restored row shows only the size it is on', () => {
  const branch = ROW.slice(ROW.indexOf(': putBack'), ROW.indexOf(': rolledBack'));
  ok(branch.length > 0, 'found the branch');
  ok(!/sizeWas|planTo/.test(branch), 'no earlier size');
  ok(!SRC.includes("sizeWas:"), 'and the words are gone from the page');
});

test('the size step words suit a restore as well as a rollback', () => {
  ok(SRC.includes("revertSize:    'Changing the machine back to the size it started on',"), 'neutral');
});

run('restore-row');
