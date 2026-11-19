/* MADE-DISK-SHOWN-1. A rollback and Restore this machine record each managed
 * disk they make from a safety copy (rollbackDisksDuringRollback, restoreDisks). A disk that nothing uses bills
 * until the daily cleanup deletes it, and the app listed it nowhere.
 *
 * The machine's panel now lists each one, with what happens next - from the
 * record, by the engine's rules (madeDiskRows, held to
 * tests/fixtures/made-disks-shown.json, which MadeDiskShown.Tests.ps1 holds to
 * Get-VmfDeletableMadeDisks, Get-VmfDueMadeDisks and Test-VmfPutBackJobHolds).
 * The why is behind a (?): one button, two states (? and Close), and Escape
 * closes it first (rule 11). No delete: that decision stays with the customer.
 *
 * RUN, not read: madeDiskRows, recordedMachineDiskIds, madeDisksHtml and
 * toggleMadeHelp, lifted from the page.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const U = liftConst('migrations.html', 'UX_ACT');
const C = liftConst('migrations.html', 'UX_COPIES');
Object.assign(globalThis, { UX_ACT: U, UX_COPIES: C, esc: (s) => String(s ?? ''), agoSpan: (s) => `<span data-ago="${s}">ago</span>` });
const fixture = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'made-disks-shown.json'), 'utf8'));

let refreshed = 0;
globalThis.refreshDrill = () => { refreshed++; return true; };
globalThis.madeHelpOpen = new Set();
const page = liftAll('migrations.html', ['recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml', 'toggleMadeHelp']);

const D = (n) => `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/${n}`;
const doc = (extra = {}) => ({ vmId: 'vm-1', state: 'MIGRATED', ...extra });

test('madeDiskRows gives each case of the fixture the engine is held to', () => {
  ok(fixture.cases.length > 12, `cases: ${fixture.cases.length}`);
  for (const c of fixture.cases) {
    eq(page.madeDiskRows(c.doc).map(r => ({ diskId: r.diskId, list: r.list, status: r.status })), c.disks, c.why);
  }
});

test('a row carries the name, the LUN and when it was made, from the record', () => {
  const rows = page.madeDiskRows(doc({ rollbackDisksDuringRollback: [
    { diskId: D('a-os'), diskName: 'a-os', lun: null, madeUtc: '2026-11-06T09:00:00Z' },
    { diskId: D('a-d3'), lun: 3, madeUtc: '2026-11-06T09:05:00Z' }] }));
  eq(rows[0].name, 'a-os', 'the recorded name');
  eq(rows[0].lun, null, 'the operating system disk');
  eq(rows[1].name, 'a-d3', 'no name: the last part of the resource ID');
  eq(rows[1].lun, 3, 'the LUN');
  eq(rows[1].madeUtc, '2026-11-06T09:05:00Z', 'when it was made');
  eq(page.madeDiskRows(null), [], 'no record');
});

test('the panel lists each disk with who made it, for what, and what happens next', () => {
  const html = page.madeDisksHtml(doc({
    rollbackDisksDuringRollback: [{ diskId: D('a-os-rb'), diskName: 'a-os-rb', lun: null, madeUtc: '2026-11-06T09:00:00Z' }],
    restoreDisks: [{ diskId: D('a-d2-r'), diskName: 'a-d2-r', lun: 2, madeUtc: '2026-11-06T09:00:00Z' }] }), false);
  ok(html.includes(U.madeTitle) && html.includes(U.madeWhat), 'the title and what these disks are');
  for (const h of [U.madeColDisk, U.madeColBy, U.madeColFor, U.madeColMade]) { ok(html.includes(`<th>${h}</th>`), h); }
  ok(html.includes(`<td class="mono">a-os-rb</td><td>${U.madeByRollback}</td><td>${U.restoredEarlierOs}</td>`), html);
  ok(html.includes(`<td class="mono">a-d2-r</td><td>${U.madeByRestore}</td><td>LUN 2</td>`), html);
  ok(html.includes('<td><span data-ago="2026-11-06T09:00:00Z">ago</span></td></tr>'), 'when it was made');
  eq(html.split(`<b>${U.madeNext}:</b> ${U.madeDue}`).length - 1, 1, 'what happens next, said once for the machine');
  eq(page.madeDisksHtml(doc(), false), '', 'nothing made: no box');
  eq(page.madeDisksHtml(doc({ rollbackDisksDuringRollback: [{ diskId: D('x'), usedUtc: 'x' }] }), false), '', 'nothing free: no box');
});

test('what happens next is said for each case the engine has', () => {
  const one = (extra) => page.madeDisksHtml(doc({ rollbackDisksDuringRollback: [{ diskId: D('x'), diskName: 'x', lun: 0, madeUtc: 'x' }], ...extra }), false);
  const says = (html, words) => html.includes(`<b>${U.madeNext}:</b> ${words}</div>`);
  ok(says(one({}), U.madeDue), 'due');
  ok(says(one({ state: 'FAILED_NEEDS_ATTENTION' }), U.madeWaits), 'waits');
  ok(says(one({ putBackJob: { kind: 'restore' } }), C.statusRestoreRuns), 'a restore runs');
  ok(says(one({ putBackJob: { kind: 'finish' } }), C.statusFinishRuns), 'a finish runs');
  ok(says(one({ putBackJob: { kind: 'restore', ended: { reason: 'gaveUp' } } }), C.statusRestoreStopped), 'stopped');
  eq(U.madeNext, C.colStatus, 'the words of the Safety copies card');
});

test('the why is behind a (?) with two states, ? and Close', () => {
  const d = doc({ rollbackDisksDuringRollback: [{ diskId: D('x'), diskName: 'x', lun: 0, madeUtc: 'x' }] });
  const shut = page.madeDisksHtml(d, false);
  ok(shut.includes('id="madehelp-btn"') && shut.includes('aria-expanded="false"') && shut.includes(`aria-label="${U.madeHelpTip}"`), shut);
  ok(/id="madehelp-btn"[^>]*>\?<\/button>/.test(shut), 'the closed state says ?');
  ok(!shut.includes(U.madeHelp), 'the why is not shown until a person asks');
  const open = page.madeDisksHtml(d, true);
  ok(open.includes('aria-expanded="true"') && open.includes(`>${U.close}</button>`), 'the open state says Close');
  ok(open.includes(U.madeHelp), 'the why');
  eq(U.close, 'Close', 'CLOSE-NOT-CANCEL-1: it only shows information');
});

test('toggleMadeHelp opens and closes the (?) of one machine, and draws the panel again', () => {
  globalThis.madeHelpOpen.clear();
  refreshed = 0;
  page.toggleMadeHelp('vm-1');
  ok(globalThis.madeHelpOpen.has('vm-1'), 'open');
  page.toggleMadeHelp('vm-1');
  ok(!globalThis.madeHelpOpen.has('vm-1'), 'closed');
  eq(refreshed, 2, 'the panel draws again each time');
});

test('a disk name from the record is drawn as text', () => {
  const plain = globalThis.esc;
  globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  try {
    const html = page.madeDisksHtml(doc({ rollbackDisksDuringRollback: [{ diskId: D('x'), diskName: '<img src=x onerror=alert(1)>', lun: 0, madeUtc: 'x' }] }), false);
    ok(!html.includes('<img') && html.includes('&lt;img src=x onerror=alert(1)&gt;'), html);
  } finally { globalThis.esc = plain; }
});

test('the words: product nouns, the record and not a live fact, and no delete', () => {
  ok(/record/.test(U.madeWhat), 'the record says nothing uses it - the page cannot read Azure');
  ok(/safety copies/.test(U.madeWhat), U.madeWhat);
  eq(U.madeByRestore, U.restore, 'the name of the action on the panel');
  ok(/attached/.test(U.madeHelp) && /Delete this migration/.test(U.madeHelp), U.madeHelp);
  ok(/Migrated/.test(U.madeWaits) && /Rolled back/.test(U.madeWaits) && /Not migrated/.test(U.madeWaits), 'the state names the panel shows');
  ok(!/replac|lost/i.test(U.madeTitle + U.madeWhat + U.madeHelp + U.madeDue + U.madeWaits), 'a disk is made and kept; lost only on delete');
});

run('made-disks-shown');
