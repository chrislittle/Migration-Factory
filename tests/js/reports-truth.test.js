/* SIGNOFF-READ-1 and OUTCOME-WORDS-1, from the first Azure test, 2026-09-24.
 *
 * 1. Waves that ran on the PLAN sign-off showed "Sign-off?" in the Reports
 *    page, in a pill that looked like a button and did nothing. The page read
 *    per-wave approvals only; PLANRUN-1 keeps the plan's beside the plan.
 * 2. The outcome column was a bar whose grey part was "put back" AND "not
 *    started yet", so a finished migration with one machine put back read as
 *    one still under way.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('reports.html', 'UX');
globalThis.UX = UX;
globalThis.esc = (s) => String(s);
// SIGNOFF-NULL-1: whether a wave needs a sign-off is the one rule in help.js.
globalThis.VmfHelp = { approvalRequired: lift('help.js', 'approvalRequired') };
// PAGE-SCALE-REPORTS-1: the outcome is the shared list's tag now, with the counts as its note.
const page = liftAll('reports.html', ['signoffCell', 'outcomeState', 'outcomeTag']);

const wave = (requireApproval = true) => ({ vms: [{ vmId: 'a', policy: { requireApproval } }] });
const detail = (o) => Object.assign({ approvals: new Map(), planApproval: null }, o);

test('MIGRATIONS-PAGE-OLD-READERS-1: the sign-off is read with no version - Approve-VmfPlan writes only v4, with one approval per wave', () => {
  eq(UX.planSignedBy, undefined, 'the words for a sign-off with no wave approvals are gone');
  ok(!/schemaVersion/.test(page.signoffCell.toString()), 'signoffCell reads no schemaVersion');
  const d = detail({ planApproval: { waves: ['dev-wave', 'prod-wave'], approvedBy: { identity: 'approver@example.com' } } });
  ok(page.signoffCell(d, 'dev-wave', wave()).includes(UX.signoffAsksAgain), 'a covered wave with no approval of its own asks again');
});

test('a plan sign-off that does not name the wave does not cover it', () => {
  const d = detail({ planApproval: { waves: ['prod-wave'], approvedBy: { identity: 'approver@example.com' } } });
  ok(page.signoffCell(d, 'dev-wave', wave()).includes(UX.noSignoffFound));
});

test('a wave\'s own approval still wins', () => {
  const d = detail({ approvals: new Map([['dev-wave', { approvedBy: { identity: 'wave@example.com' } }]]),
                     planApproval: { waves: ['dev-wave'], approvedBy: { identity: 'plan@example.com' } } });
  ok(page.signoffCell(d, 'dev-wave', wave()).includes('wave@example.com'));
});

test('WAVE-APPROVE-1: a wave whose own approval went after a version 3 sign-off is not shown as signed off', () => {
  const d = detail({ planApproval: { schemaVersion: 3, waves: ['dev-wave'], approvedBy: { identity: 'approver@example.com' } } });
  const said = page.signoffCell(d, 'dev-wave', wave());
  ok(said.includes(UX.signoffAsksAgain), said);
});

test('none found is plain text, not something that looks pressable', () => {
  const said = page.signoffCell(detail({}), 'dev-wave', wave());
  ok(!/pill/.test(said), `no pill: ${said}`);
  ok(!/\?/.test(said), 'and no question mark');
});

const row = (o) => Object.assign({ total: 6, migrated: 0, putBack: 0, restored: 0, attention: 0, leftOut: 0, working: 0, notStarted: 0 }, o);

test('five migrated and one put back is FINISHED, with the put-back named', () => {
  const x = row({ migrated: 5, putBack: 1 });
  eq(page.outcomeState(x), 'done');
  const said = page.outcomeTag(x);
  eq(said.text, UX.oDone);
  ok(said.note.includes('5 migrated') && said.note.includes('1 restored by a person'), said.note);
});

test('a machine not started yet makes it in progress, not finished', () => {
  eq(page.outcomeState(row({ migrated: 3, notStarted: 3 })), 'going');
  eq(page.outcomeState(row({ migrated: 3, working: 1, notStarted: 2 })), 'going');
});

test('a machine waiting on a person is said first', () => {
  eq(page.outcomeState(row({ migrated: 5, attention: 1 })), 'attention');
});

run('reports-truth');
