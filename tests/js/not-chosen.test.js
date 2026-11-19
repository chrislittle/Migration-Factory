// MACHINE-PICK-1: a plan holds only the machines a person chose. The run
// page's list of found machines falls back to the scan for a machine the plan
// has no entry for, so a machine nobody chose read "can migrate" and was
// counted with the machines that move (found by the independent review).
// RUN: the page's own renderFound, with the page's own words.
'use strict';
const { lift, liftConst, test, ok, eq, run } = require('./_harness');

const renderFound = lift('migrations.html', 'renderFound');
// ALREADY-CURRENT-1: renderFound asks the page's Current rule first.
global.foundCurrent = lift('migrations.html', 'foundCurrent');
global.judgeForSeries = lift('migrations.html', 'judgeForSeries');
global.judgeUnplanned = lift('migrations.html', 'judgeUnplanned');
global.UX_FOUND = liftConst('migrations.html', 'UX_FOUND');
global.UX_FOUND_T = new Proxy({}, { get: (_, k) => String(k) });

function draw(assessment, plan) {
  let html = '';
  global.$ = (sel) => sel === '#found' ? { set innerHTML(v) { html = v; } } : null;
  global.esc = (s) => String(s);
  global.reasonText = (c) => c;
  global.REASONS = { blockers: {}, prep: {} };
  global.foundOpen = true;
  renderFound(assessment, Boolean(plan), plan);
  return html;
}
const vm = (name, extra) => Object.assign({ vmId: `/vm/${name}`, name, classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [], diskController: 'SCSI' }, extra || {});
const vms = [vm('chosen'), vm('left-1'), vm('left-2'), vm('aks', { classification: 'Excluded', platformManaged: true })];
const plan = { entries: [{ vmId: '/vm/chosen', path: 'A', policy: { targetGeneration: 'v6' }, planNotes: [] }] };

test('RUN: a machine the plan holds no entry for is "Not in this migration", counted on its own', () => {
  const html = draw({ vms }, plan);
  ok(html.includes(`1 ${UX_FOUND.ReadyAfterPrep[2]}`), 'only the chosen machine can migrate: ' + html.slice(0, 400));
  ok(html.includes(`2 ${UX_FOUND.NotChosen[2]}`), 'the two left out are counted apart');
  eq((html.match(new RegExp(`>${UX_FOUND.NotChosen[0]}<`, 'g')) || []).length, 2, 'and each row says so');
  ok(html.includes(`1 ${UX_FOUND.Excluded[2]}`), 'a machine that is not eligible keeps its own word');
});

test('RUN: before a plan exists, no machine is "Not in this migration"', () => {
  const html = draw({ vms }, null);
  ok(!html.includes(UX_FOUND.NotChosen[2]), html.slice(0, 300));
  ok(html.includes(`3 ${UX_FOUND.ReadyAfterPrep[2]}`));
});

run('not-chosen');
