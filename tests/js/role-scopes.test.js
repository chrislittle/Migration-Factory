/* ROLES-1 part 2: the Admin page covers a scope before it grants at it.
 *
 * The question was whether a role scoped at a subscription stops working
 * when a management group is added. It does not - measured in Azure on
 * 2026-09-07 - because a role's list of places can GROW and its id does not
 * move. This is the browser half of that: before granting, make sure the role
 * reaches the scope, and widen it if it does not.
 *
 * The three things worth holding are all here:
 *
 *   1. Reach is a PATH question for subscriptions and resource groups, and is
 *      NOT a path question for a management group. A subscription beneath a
 *      group shares no prefix with it, so a string test must answer "no" and
 *      let the caller ask Azure. Answering "yes" would skip a widening that
 *      was needed; answering "no" and stopping would widen forever.
 *   2. Azure permits only ONE management group per role. Refusing a second one
 *      here, with the two real ways forward, beats an ARM error that names a
 *      limit and no route out.
 *   3. Nothing is duplicated and nothing is dropped. A deployment states a
 *      property rather than adding to one, so the whole list travels.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const scopeCoveredBy = lift('access.html', 'scopeCoveredBy');
const widenScopes = lift('access.html', 'widenScopes');
const isManagementGroupScope = lift('access.html', 'isManagementGroupScope');
const subscriptionIdOf = lift('access.html', 'subscriptionIdOf');

const SUB = '/subscriptions/1111';
const RG = '/subscriptions/1111/resourceGroups/rg-app';
const MG = '/providers/Microsoft.Management/managementGroups/landing-zones';
const MG2 = '/providers/Microsoft.Management/managementGroups/other';

global.isManagementGroupScope = isManagementGroupScope;
global.UX = {
  scopeNoRole: 'NOROLE',
  scopeSecondGroup: 'ONE GROUP ONLY: have {have} want {want}',
};

// --- what reach means -------------------------------------------------------

test('a scope is covered by itself', () => {
  ok(scopeCoveredBy(SUB, [SUB]), 'the subscription itself');
  ok(scopeCoveredBy(MG, [MG]), 'the group itself');
});

test('a resource group is covered by its subscription', () => {
  ok(scopeCoveredBy(RG, [SUB]), 'beneath is covered');
});

test('a subscription is NOT covered by one of its own resource groups', () => {
  ok(!scopeCoveredBy(SUB, [RG]), 'reach goes down, never up');
});

test('a lookalike name is not a parent', () => {
  // '/subscriptions/1111' must not cover '/subscriptions/11112'.
  ok(!scopeCoveredBy('/subscriptions/11112', [SUB]), 'a prefix of the STRING is not a prefix of the PATH');
});

test('case does not matter, because Azure resource ids do not care', () => {
  ok(scopeCoveredBy(RG.toUpperCase(), [SUB]), 'upper case still covered');
});

test('a subscription under a management group reads as NOT covered by the string test', () => {
  // This is the one that matters and the easy one to get wrong. A subscription
  // beneath a group has a path of /subscriptions/..., which shares nothing with
  // /providers/.../managementGroups/... - so no string test can answer it, and
  // this one must not pretend to. scopeIsCovered asks Azure instead.
  ok(!scopeCoveredBy(SUB, [MG]), 'strings cannot see the tree');
});

test('an empty scope is never covered, and an empty list covers nothing', () => {
  ok(!scopeCoveredBy('', [SUB]), 'no scope');
  ok(!scopeCoveredBy(SUB, []), 'no reach');
  ok(!scopeCoveredBy(SUB, ['']), 'a blank entry is not a wildcard');
});

// --- widening ---------------------------------------------------------------

test('widening adds the new place and keeps every old one', () => {
  const r = widenScopes([SUB], RG);
  eq(r.scopes.join(' | '), `${SUB} | ${RG}`, 'the whole list travels');
  eq(r.error, undefined, 'no error');
});

test('a place already listed is not added twice', () => {
  const r = widenScopes([SUB, RG], RG);
  eq(r.scopes.length, 2, 'no duplicate');
});

test('the first management group is allowed', () => {
  const r = widenScopes([SUB], MG);
  eq(r.scopes.join(' | '), `${SUB} | ${MG}`, 'group added');
});

test('a SECOND management group is refused, and both are named', () => {
  const r = widenScopes([SUB, MG], MG2);
  eq(r.scopes, undefined, 'nothing to write');
  ok(r.error.includes(MG) && r.error.includes(MG2), 'says which it has and which was asked for');
});

test('re-adding the SAME management group is not a second one', () => {
  const r = widenScopes([SUB, MG], MG);
  eq(r.error, undefined, 'no refusal');
  eq(r.scopes.length, 2, 'unchanged');
});

test('a trailing slash is not a different place', () => {
  const r = widenScopes([SUB], SUB + '/');
  eq(r.scopes.length, 1, 'the same subscription');
});

test('an empty scope is refused rather than written as a blank entry', () => {
  eq(widenScopes([SUB], '').error, 'NOROLE', 'refused');
});

// --- the small helpers the flow depends on ---------------------------------

test('a management group scope is recognised whatever its case', () => {
  ok(isManagementGroupScope(MG), 'plain');
  ok(isManagementGroupScope(MG.toUpperCase()), 'upper case');
  ok(!isManagementGroupScope(SUB), 'a subscription is not one');
  ok(!isManagementGroupScope(''), 'nothing is not one');
});

test('the subscription id is read out of any scope beneath it', () => {
  eq(subscriptionIdOf(SUB), '1111', 'from a subscription');
  eq(subscriptionIdOf(RG), '1111', 'from a resource group');
  eq(subscriptionIdOf(MG), '', 'a group has none');
  eq(subscriptionIdOf(''), '', 'nothing has none');
});

run('role-scopes');
