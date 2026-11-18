/* LEAK-1: the wave editor's unassigned pool is a drop target, wired ONCE.
 *
 * render() rewrites the innerHTML of #pool and #waves, so every machine row
 * and wave card is a new node and its listeners die with the old markup. The
 * containers are not replaced - #pool is the same node from first paint to
 * last. wireRows() runs at the end of every render(), so wiring #pool there
 * added a handler every time and removed none.
 *
 * The growth was not only memory. The DOM copies an element's listener list
 * before dispatch, so ONE drop onto the pool ran moveTo once per accumulated
 * handler - and each of those called render(), which wired another. The count
 * DOUBLED per drop, each call re-rendering the whole editor. A few drags in
 * one planning session was enough to wedge the screen, with unsaved wave
 * changes in it.
 *
 * This is tested by RUNNING the two functions against a fake DOM and counting,
 * because the defect was invisible to reading: the line looked exactly like
 * the lines around it, and the only thing separating it from them was which
 * node survives a render.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const wireRows = lift('waves.html', 'wireRows');
const wirePoolDropTarget = lift('waves.html', 'wirePoolDropTarget');

/** A node that counts what was bound to it. */
function fakeNode(name) {
  return { name, listeners: [], addEventListener(type) { this.listeners.push(type); } };
}

/** Fake DOM: every querySelectorAll is empty, so wireRows touches nothing else. */
function install(pool) {
  const asked = [];
  global.document = {
    querySelectorAll: () => [],
    querySelector: () => null,
  };
  global.$ = (sel) => { asked.push(sel); return sel === '#pool' ? pool : fakeNode(sel); };
  // Referenced inside the handlers, never called by these tests.
  global.selection = new Set();
  global.moveTo = () => {};
  global.render = () => {};
  global.started = () => false;
  global.layout = new Map();
  return asked;
}

test('wireRows does not bind anything to the pool, however many times it runs', () => {
  const pool = fakeNode('#pool');
  install(pool);
  for (let i = 0; i < 20; i++) { wireRows(); }
  eq(pool.listeners.length, 0, 'listeners added to #pool by 20 renders');
});

test('wireRows does not even ASK for the pool', () => {
  /* Stronger than counting listeners: if wireRows never reaches for #pool it
   * cannot bind to it by some later edit either. */
  const pool = fakeNode('#pool');
  const asked = install(pool);
  wireRows();
  eq(asked.filter(s => s === '#pool').length, 0, 'times wireRows asked for #pool');
});

test('the pool gets its two drop handlers from the one-time wiring', () => {
  const pool = fakeNode('#pool');
  install(pool);
  wirePoolDropTarget();
  eq(pool.listeners, ['dragover', 'drop'], 'listeners on #pool');
});

test('THE INVARIANT: one start plus many renders leaves exactly two handlers', () => {
  /* This is the whole bug in one assertion. Before the fix this number grew
   * with every render and then doubled on every drop. */
  const pool = fakeNode('#pool');
  install(pool);
  wirePoolDropTarget();          // start() does this once
  for (let i = 0; i < 50; i++) { wireRows(); }   // 50 renders
  eq(pool.listeners.length, 2, 'handlers on #pool after 50 renders');
});

run('pool-drop-target');
