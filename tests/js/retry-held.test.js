/* ROLLBACK-RETRY-CAPTURE-1: the run page offers Try this machine again only
 * where the engine accepts it.
 *
 * The page offered the retry to a machine its last stop left CHANGED; the
 * engine refused it (SAFETY-RETRY-1), so the button produced a refusal. The
 * rule is now written once in each language and both are held to
 * tests/fixtures/retry-held.json (the engine in RetryCapture.Tests.ps1).
 *
 * RUN, not read: the page's own retryHeld.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
// POWER-ONLY-CHANGED-1: retryHeld asks powerOwed, so both are lifted together.
const { retryHeld } = liftAll('migrations.html', ['powerOwed', 'retryHeld']);

const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'retry-held.json'), 'utf8')).cases;

test('the fixture loaded', () => { ok(CASES.length >= 10, `${CASES.length} cases`); });

test('RUN: every shared case gives the answer the engine gives', () => {
  for (const c of CASES) { eq(retryHeld(c.doc), c.held, c.why); }
});

test('the button is offered only where the engine accepts it, and the reason is said in its place', () => {
  ok(PAGE.includes('const held = (offer.retry || offer.decide) && retryHeld(doc);'), 'the drill asks retryHeld, for both controls');
  // DECIDE-ROLE-1 added a second condition: the park the machine waits at now.
  ok(PAGE.includes('const decideBtn = (offer.decide && !held && decisionWaiting(doc) === lastStop)'), 'no decision where the engine refuses it either');
  ok(PAGE.includes('const resolveBtn = (offer.retry && !held)'), 'no button where it is held');
  // SWAP-REFUSED-AFTER-STOP-1: a refused data disk swap says its own reason.
  ok(PAGE.includes('const heldLine = held ? `<p class="muted" style="margin:6px 0">${esc(doc.swapPending ? UX_ACT.retryHeldSwap : UX_ACT.retryHeld)}</p>` : \'\';'), 'the reason, on the screen');
  ok(PAGE.includes('${heldLine}'), 'and painted');
  ok(/Restore it first/.test(UX_ACT.retryHeld), UX_ACT.retryHeld);
  ok(!/Rebuild this machine/.test(UX_ACT.retryHeld), 'REBUILD-REMOVE-RECOVER-1: no action that is gone');
});

run('retry-held');
