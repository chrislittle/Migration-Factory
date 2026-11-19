/* BLOCKED-NAME-1, the browser half.
 *
 * These pages read the quota records DIRECTLY from the store. The state is
 * BLOCKED, and blockReason says why. Every writer gives BLOCKED, and nothing
 * is public before 1.0, so no store holds the name before BLOCKED-NAME-1
 * (OLD-VERSION-READERS-REMOVE-8): the pages read BLOCKED only.
 *
 * TWO PAGES ASK THIS QUESTION, and it is one function in help.js, so the
 * census below fails if a second copy appears.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, test, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const claimBlocked = lift('help.js', 'claimBlocked');

test('the value this build writes is blocked', () => {
  ok(claimBlocked('BLOCKED'), 'BLOCKED');
});

test('the name before BLOCKED-NAME-1 is not read', () => {
  ok(!claimBlocked('CAPACITY_BLOCKED'), 'CAPACITY_BLOCKED must not read as blocked');
});

test('it reads the value as the store spells it, whatever the case', () => {
  // waves.html upper-cases before asking; migrations.html does not. The
  // function cannot depend on which page called it.
  for (const spelling of ['blocked', 'Blocked', '  BLOCKED  ']) {
    ok(claimBlocked(spelling), spelling);
  }
});

test('no other state is blocked', () => {
  for (const state of ['FORECAST', 'QUOTA_VERIFIED', 'QUOTA_REQUESTED',
                       'RESERVING', 'RESERVED', 'CONSUMED', 'RELEASED']) {
    ok(!claimBlocked(state), `${state} must not read as blocked`);
  }
});

test('and a missing state is not blocked either', () => {
  // An unreadable claim is an unreadable claim. Calling it blocked would
  // assert a cause nobody measured, which is the defect this item is about.
  for (const nothing of [null, undefined, '', '   ']) {
    ok(!claimBlocked(nothing), String(nothing));
  }
});

test('no page names the earlier state', () => {
  // THE CENSUS: help.js included, since no page reads it any more.
  const dir = path.join(REPO, 'src', 'dashboard');
  const offenders = [];
  for (const name of fs.readdirSync(dir)) {
    if (!/\.(html|js)$/.test(name)) { continue; }
    if (fs.readFileSync(path.join(dir, name), 'utf8').includes('CAPACITY_BLOCKED')) {
      offenders.push(name);
    }
  }
  ok(offenders.length === 0, `these name the earlier state: ${offenders.join(', ')}`);
});

run('blocked-state');
