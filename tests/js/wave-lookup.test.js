/* RENDER-1: the wave editor looks up instead of scanning.
 *
 * `avsetOf` was `entries.find(...)`, called once per rendered row.
 * `membersOf` checked `vmIds.includes(...)` once per entry per wave.
 *
 * render() is bound to the search box's `input` event, so both ran on EVERY
 * KEYSTROKE, and both grow with the plan - which comes from the store, so it
 * is the size of the customer's fleet.
 *
 * Swapping a scan for an index is only safe if the answer is identical, and
 * one property is easy to lose: membersOf returns entries in PLAN order, not
 * in the order the wave happens to list its machines. Taking the wave's order
 * instead would quietly reshuffle every wave on screen.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const setEntries = lift('waves.html', 'setEntries');
const membersOf = lift('waves.html', 'membersOf');

const entry = (vmId, avset) => ({ vmId, assessment: avset ? { availabilitySetId: avset } : {} });

function install(list, waves) {
  global.entries = [];
  global.entryById = new Map();
  global.planWaveOrder = [];
  global.layout = new Map(Object.entries(waves || {}).map(([k, ids]) => [k, { vmIds: ids }]));
  setEntries(list);
}

test('setEntries indexes what it stores', () => {
  install([entry('a'), entry('b')], {});
  eq(global.entries.length, 2, 'entries kept');
  eq(global.entryById.size, 2, 'and indexed');
  eq(global.entryById.get('b').vmId, 'b', 'by machine id');
});

test('the index is REPLACED, not added to', () => {
  /* The danger of an index beside a list: a second plan load that left the old
   * machines in the index would show rows for machines no longer in the plan. */
  install([entry('a'), entry('b')], {});
  setEntries([entry('c')]);
  eq(global.entryById.size, 1, 'only the new plan');
  eq(global.entryById.has('a'), false, 'the old machines are gone');
});

test('membersOf returns the wave machines, in PLAN order', () => {
  // The wave lists them in a different order on purpose.
  install([entry('a'), entry('b'), entry('c')], { w1: ['c', 'a'] });
  eq(membersOf('w1').map(e => e.vmId), ['a', 'c'], 'plan order, not wave order');
});

test('a wave with no machines, and a wave that does not exist', () => {
  install([entry('a')], { w1: [] });
  eq(membersOf('w1').length, 0, 'empty wave');
  eq(membersOf('nope').length, 0, 'unknown wave');
});

test('a wave naming a machine the plan does not have is ignored', () => {
  // A wave layout can outlive a re-plan. It must not invent a row.
  install([entry('a')], { w1: ['a', 'ghost'] });
  eq(membersOf('w1').map(e => e.vmId), ['a'], 'only real entries');
});

test('a machine listed twice in a wave appears once', () => {
  install([entry('a'), entry('b')], { w1: ['a', 'a', 'b'] });
  eq(membersOf('w1').map(e => e.vmId), ['a', 'b'], 'the plan is walked, so no duplicates');
});

test('waves do not take each other machines', () => {
  install([entry('a'), entry('b'), entry('c')], { w1: ['a'], w2: ['b', 'c'] });
  eq(membersOf('w1').map(e => e.vmId), ['a'], 'w1');
  eq(membersOf('w2').map(e => e.vmId), ['b', 'c'], 'w2');
});

test('a big plan is still answered correctly', () => {
  const many = [];
  for (let i = 0; i < 500; i++) { many.push(entry(`vm${i}`)); }
  install(many, { w1: ['vm499', 'vm0', 'vm250'] });
  eq(membersOf('w1').map(e => e.vmId), ['vm0', 'vm250', 'vm499'], 'plan order across a large plan');
  eq(global.entryById.size, 500, 'and all of it indexed');
});

run('wave-lookup');
