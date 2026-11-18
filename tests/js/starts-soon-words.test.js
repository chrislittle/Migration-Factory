/* STARTS-SOON-WORDS-1: a wave of a signed-off plan said "Starts within five
 * minutes". TIMER-PASS-LIMIT-1 made the service's check of a large store take
 * more than one pass, so a wave whose turn comes in a later pass starts later
 * than that. The line now names the event that starts the wave - the next
 * check of the service - and the why is behind a (?) helper: one button, two
 * states (? and Close), and Escape closes it (rule 11).
 *
 * RUN, not read: the page's own waveStartHtml.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.canOperate = () => true;
globalThis.isUnplannedWave = () => false;
globalThis.planRunStatus = null;
// WAVE-ORDER-START-1: planRunOrder is VmfHelp.waveOrder over the moved machines.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { waveOrder: lift('help.js', 'waveOrder') });
globalThis.planRunOrder = lift('migrations.html', 'planRunOrder');
globalThis.planFollowText = lift('migrations.html', 'planFollowText');
globalThis.soonHelpOpen = new Set();
const card = liftAll('migrations.html', ['settledAll', 'vmStateOf', 'startsSoonHtml', 'waveStartHtml']);
const M = globalThis.UX_MISC;

const W1 = [{ vmId: 'a', wave: 'w1', path: 'A' }];
const W2 = [{ vmId: 'b', wave: 'w2', path: 'A' }];
globalThis.planDoc = { entries: [...W1, ...W2] };
globalThis.allVms = [{ vmId: 'a', state: 'MIGRATED' }];
const ctx = { planCovers: true, waveWorking: false, waveDone: false, halted: false, sched: null, startBlockedBy: null };

// WAVE-ORDER-START-1 (lab Session A, finding 24, owner): the line says the
// outcome a person waits for - "Starts within about 5 minutes" - and the (?)
// says that it can take longer. This used to require a line with no time in
// it, which named the service's check instead and read as odd and unclear.
test('the line says about how long, and the why says it can take longer', () => {
  ok(/within about 5 minutes/.test(M.startsSoon), M.startsSoon);
  ok(/can take longer/.test(M.startsSoonHelp), 'a large store can make it later');
});

test('RUN: the next wave says the line, with a closed (?) beside it', () => {
  globalThis.soonHelpOpen = new Set();
  const html = card.waveStartHtml('w2', W2, ctx);
  ok(html.includes(M.startsSoon), html);
  ok(html.includes('data-soonhelp="w2"'), 'the (?) names its wave');
  ok(html.includes('aria-expanded="false"'), 'closed');
  ok(/>\?<\/button>/.test(html), 'the button says ?');
  ok(!html.includes(M.startsSoonHelp), 'the why is not shown until it is selected');
});

test('RUN: open, the (?) shows the why and becomes Close', () => {
  globalThis.soonHelpOpen = new Set(['w2']);
  const html = card.waveStartHtml('w2', W2, ctx);
  ok(html.includes(M.startsSoonHelp), html);
  ok(html.includes('aria-expanded="true"'), 'open');
  ok(html.includes(`>${globalThis.UX_ACT.close}</button>`), 'the same button closes it');
  ok(html.includes('id="soon-help-w2"') && html.includes('aria-controls="soon-help-w2"'), 'the button names the text it opens');
  globalThis.soonHelpOpen = new Set();
});

test('RUN: the why says what the service does, and that a large store can take longer', () => {
  ok(/every 5 minutes/.test(M.startsSoonHelp), M.startsSoonHelp);
  ok(/When many migrations wait, it can take longer\./.test(M.startsSoonHelp), 'a wave can start later');
});

test('RUN: another reason a wave waits gets no (?)', () => {
  globalThis.allVms = [];
  const html = card.waveStartHtml('w2', W2, ctx);
  ok(html.includes(M.startsAfter.replace('{wave}', 'w1')), html);
  ok(!html.includes('data-soonhelp'), 'no (?) on Starts when');
  globalThis.allVms = [{ vmId: 'a', state: 'MIGRATED' }];
});

test('the page wires the (?), and Escape closes it', () => {
  ok(/el\.querySelectorAll\('\[data-soonhelp\]'\)\.forEach\(b => b\.addEventListener\('click'/.test(PAGE), 'a click toggles it');
  ok(/if \(soonHelpOpen\.size\) \{ soonHelpOpen\.clear\(\); renderWaves\(latestHalted\); return; \}/.test(PAGE), 'Escape closes it');
});

run('starts-soon-words');
