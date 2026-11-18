/* LAB-UX-1: "These machines lose their temporary disk ... the D: drive goes
 * away" was shown on the Run it step for a Linux machine, which has no D:
 * drive. The drive letter is named only when a Windows machine is listed.
 *
 * RUN, not read: the wizard's own tempSections, with its own strings.
 */
'use strict';
const { lift, liftConst, test, ok, run } = require('./_harness');

globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
const tempSections = lift('wizard.html', 'tempSections');
const U = globalThis.UX;

const entry = (name, os, from, to) => ({ vmId: `/s/rg/vm/${name}`, wave: 'w1', path: 'A',
  assessment: { os, sourceTempDisks: from }, target: { tempDisks: to } });

test('a Linux machine that loses its temporary disk is not told about a D: drive', () => {
  globalThis.plan = { entries: [entry('lin1', 'Linux', 1, 0)] };
  const html = tempSections();
  ok(html.includes(U.tempLoseTitle), 'the section is shown');
  ok(html.includes(U.tempLoseBody), 'with the temporary disk sentence');
  ok(!html.includes('D:'), `no drive letter for Linux: ${html}`);
});

test('a Windows machine that loses its temporary disk is told the D: drive goes away', () => {
  globalThis.plan = { entries: [entry('win1', 'Windows', 1, 0)] };
  ok(tempSections().includes(U.tempLoseWindows), 'the Windows sentence');
});

test('a list with both names the D: drive, because a Windows machine is in it', () => {
  globalThis.plan = { entries: [entry('lin1', 'Linux', 1, 0), entry('win1', 'Windows', 1, 0)] };
  ok(tempSections().includes(U.tempLoseWindows), 'the Windows sentence');
});

test('the same rule for machines that gain local drives', () => {
  globalThis.plan = { entries: [entry('lin2', 'Linux', 1, 4)] };
  const html = tempSections();
  ok(html.includes(U.tempGainBody) && !html.includes('D:'), `no drive letter for Linux: ${html}`);
  globalThis.plan = { entries: [entry('win2', 'Windows', 1, 4)] };
  ok(tempSections().includes(U.tempGainWindows), 'the Windows sentence');
});

test('the shared sentences name no drive letter', () => {
  ok(!U.tempLoseBody.includes('D:') && !U.tempGainBody.includes('D:'), 'the letter is only in the Windows sentences');
});

run('temp-disk-words');
