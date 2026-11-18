// V5-ADE-1: the run page's list of found machines does not call a machine
// ready when the plan does not move it. Judged by its series alone (v5), an
// encrypted machine reads "ready after preparation"; the plan leaves it out
// because its v5 move is a rebuild. RUN: the page's own renderFound.
'use strict';
const { lift, test, ok, run } = require('./_harness');

const judgeForSeries = lift('migrations.html', 'judgeForSeries');
const judgeUnplanned = lift('migrations.html', 'judgeUnplanned');
const renderFound = lift('migrations.html', 'renderFound');
// ALREADY-CURRENT-1: renderFound asks the page's Current rule first.
global.foundCurrent = lift('migrations.html', 'foundCurrent');

test('a MANUAL plan entry shows held back, with the plan reason, where the series says ready', () => {
  let html = '';
  global.$ = (sel) => sel === '#found' ? { set innerHTML(v) { html = v; } } : null;
  global.esc = (s) => String(s);
  global.reasonText = (c) => c;
  global.judgeForSeries = judgeForSeries;
  global.judgeUnplanned = judgeUnplanned;
  global.REASONS = { blockers: { 'disk-encryption-present': { appliesTo: ['v6', 'v7'] } }, prep: {} };
  global.foundOpen = true;
  global.UX_FOUND = { ReadyAfterPrep: ['Yes', '', 'can migrate'], Blocked: ['Not yet', '', 'cannot migrate yet'] };
  global.UX_FOUND_T = new Proxy({}, { get: (_, k) => String(k) });
  const why = 'This machine uses Azure Disk Encryption, and its move to v5 is a rebuild.';
  const vm = { vmId: '/vm/enc', name: 'enc', classification: 'Blocked', blockers: ['disk-encryption-present'], diskController: 'SCSI' };
  renderFound({ vms: [vm] }, true, { entries: [{ vmId: '/vm/enc', path: 'MANUAL', policy: { targetGeneration: 'v5' }, planNotes: [why] }] });
  ok(html.includes('1 cannot migrate yet'), 'held back: ' + html.slice(0, 300));
  ok(html.includes(why), 'with the reason in words');
  // The same machine, planned to move (path A), is ready.
  renderFound({ vms: [vm] }, true, { entries: [{ vmId: '/vm/enc', path: 'A', policy: { targetGeneration: 'v5' }, planNotes: [] }] });
  ok(html.includes('1 can migrate'), 'a planned move reads ready: ' + html.slice(0, 300));
});

run('v5-ade');
