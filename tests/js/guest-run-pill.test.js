/* PREP-ROLLBACK-1 (review F3): the run page's pill for each script run
 * inside the machine. A script that changes the guest is put on record as
 * STARTED before it runs; an entry left STARTED never answered, so it can have
 * changed the machine. It must never read "OK" - that was the shape of the
 * defect: a stop that said nothing was changed. */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, ok, run } = require('./_harness');

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const word = (name) => PAGE.match(new RegExp(name + ": *'([^']*)'"))[1];

globalThis.esc = (s) => String(s ?? '');
globalThis.UX_MISC = {
  guestReading: word('guestReading'), guestReadingTip: word('guestReadingTip'),
  guestStarted: word('guestStarted'), guestStartedTip: word('guestStartedTip'),
  guestRunning: word('guestRunning'), guestRunningTip: word('guestRunningTip'),
};
const guestRunPill = lift('migrations.html', 'guestRunPill');

test('a script that never answered is a problem pill with its own words, never OK', () => {
  const html = guestRunPill({ result: 'STARTED' });
  ok(html.includes(UX_MISC.guestStarted), html);
  ok(html.includes('pill bad'), html);
  ok(!html.includes('>OK<'), html);
});

test('review 2: the newest entry of a machine at work is a script running now, not a problem', () => {
  const html = guestRunPill({ result: 'STARTED' }, true);
  ok(html.includes(UX_MISC.guestRunning), html);
  ok(!html.includes('pill bad'), html);
});

test('the other results keep their pills', () => {
  ok(guestRunPill({ result: 'FIXED' }).includes('>OK<'));
  ok(guestRunPill({ result: 'BLOCKED' }).includes('>Problem<'));
  ok(guestRunPill({ result: 'READING' }).includes(UX_MISC.guestReading));
});

run('guest run pill');
