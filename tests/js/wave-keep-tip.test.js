/* WAVE-KEEP-TIP-WORDS-1, 2026-10-26: the help on "How long the snapshot is
 * kept" in the wave editor says what the product does with the copies.
 *
 * It said each copy "is locked when it is taken". A copy is locked only when
 * the product identity has the right to place locks; without it the copy is
 * taken unlocked and the dashboard says Not locked. And it named one copy
 * ("the safety copy of each machine as it was before migration") where each
 * machine has two, and the retention covers both.
 *
 * The lock sentence is the one the stop reason safetyCopyMissing says, read
 * from stop-reasons.json, so the two cannot drift apart.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const UX = liftConst('waves.html', 'UX');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
const REASONS = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));
const LOCK = 'The product locks each copy when it takes it, if its identity has the right to place locks.';

function findReason(node) {
  if (!node || typeof node !== 'object') { return null; }
  if (Array.isArray(node)) {
    for (const n of node) { const r = findReason(n); if (r) { return r; } }
    return null;
  }
  if (node.safetyCopyMissing) { return node.safetyCopyMissing; }
  if (node.code === 'safetyCopyMissing' || node.id === 'safetyCopyMissing' || node.key === 'safetyCopyMissing') { return node; }
  for (const k of Object.keys(node)) { const r = findReason(node[k]); if (r) { return r; } }
  return null;
}

test('the stop reason safetyCopyMissing says the lock this way', () => {
  const reason = findReason(REASONS);
  ok(reason, 'safetyCopyMissing in stop-reasons.json');
  ok(String(reason.meaning).includes(LOCK), 'the stop reason says: ' + LOCK);
});

test('the tip says the lock the same way as the stop reason', () => {
  ok(UX.keepTip.includes(LOCK), 'keepTip says: ' + LOCK + ' It says: ' + UX.keepTip);
});

test('the tip never says that every copy is locked', () => {
  eq(/is locked when it is taken/i.test(UX.keepTip), false, 'keepTip says the copy is always locked');
  eq(/(^|\. )It is locked/.test(UX.keepTip), false, 'keepTip says the copy is always locked');
});

test('the tip says the setting covers both safety copies of each machine', () => {
  ok(/both safety copies of each machine/.test(UX.keepTip), 'keepTip names both safety copies: ' + UX.keepTip);
  ok(/before migration/.test(UX.keepTip), 'keepTip names the first copy');
  ok(/just before the resize/.test(UX.keepTip), 'keepTip names the second copy, with the words of Restore this machine');
  ok(/deletes both copies/.test(UX.keepTip), 'keepTip says the cleanup deletes both copies');
  // Retention deletes the data disk copies on the same setting (Get-VmfSafetyCopyIds).
  ok(/the copies of its data disks/.test(UX.keepTip), 'keepTip says the cleanup also deletes the data disk copies');
});

test('the tip is on the retention setting of the wave editor', () => {
  ok(/<label title="\$\{esc\(UX\.keepTip\)\}"><span class="lv">\$\{esc\(UX\.keepLabel\)\}<\/span>/.test(PAGE),
    'the label of the retention setting carries keepTip');
});

test('each sentence of the tip is 25 words or fewer', () => {
  for (const s of UX.keepTip.split(/(?<=\.)\s+/)) {
    ok(s.split(/\s+/).length <= 25, 'sentence too long: ' + s);
  }
});

run('wave-keep-tip');