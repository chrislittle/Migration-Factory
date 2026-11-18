/* WAVE-EDITOR-1: the wave editor says what each machine becomes.
 *
 * Seen on the wave editor during the ADVISOR-1 end-to-end run: the wave
 * settings did not say what the target VM is. And "Take out" is not a
 * term this product uses anywhere else.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
global.esc = (s) => String(s ?? '');
const { sizeMove } = liftAll('waves.html', ['sizeMove']);
const UX = liftConst('waves.html', 'UX');

test('a machine shows its size and the size it moves to', () => {
  const s = sizeMove({ assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v7' } });
  ok(s.includes('D2s_v4 &rarr; D2s_v7'), s);
});

test('a machine with no target says nothing, rather than an arrow to nowhere', () => {
  eq(sizeMove({ assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: null } }), '');
});

test('a plan with no current size still shows the target', () => {
  ok(sizeMove({ assessment: {}, target: { size: 'Standard_D2s_v6' } }).includes('&rarr; D2s_v6'));
});

test('every machine row carries it', () => {
  ok(SRC.includes('${sizeMove(e)}'), 'in the row');
});

test('the button says Remove', () => {
  eq(UX.takeOut, 'Remove');
});

run('wave-editor-sizes');
