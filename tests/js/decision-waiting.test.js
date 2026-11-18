/* DECIDE-ROLE-1: the park a machine waits at now.
 *
 * The run page offers Accept this and continue only for the park the machine
 * waits at now, and the engine accepts a decision from the approver alone only
 * for that park. Both are held to one fixture, so they cannot drift apart.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const decisionWaiting = lift('migrations.html', 'decisionWaiting');
const FX = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'decision-waiting.json'), 'utf8'));

test('the fixture has the cases that matter', () => {
  ok(FX.cases.length > 5, 'cases');
});

for (const c of FX.cases) {
  test(c.name, () => {
    const got = decisionWaiting(c.doc);
    eq(got ? got.reasonCode : null, c.expect, c.name);
  });
}

run('decision-waiting');
