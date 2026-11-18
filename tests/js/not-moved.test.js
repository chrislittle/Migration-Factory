// MANUAL-WHY-1: a machine the plan does not move says why, on the run page.
//
// A plan records every machine it does not move as path MANUAL (or EXCLUDED).
// The run page showed each as "Manual review", with no reason. The reasons
// are where the product already keeps them: the scan's findings for the
// machine's series, the words for a machine that is not eligible or already
// moved, and the plan's notes (planNotes - filled only when there is no size).
//
// RUN: the page's own functions, lifted out of migrations.html, and the whole
// page booted in sample mode.
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

global.esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
global.UX_MISC = liftConst('migrations.html', 'UX_MISC');
global.UX_FOUND = liftConst('migrations.html', 'UX_FOUND');
const UX_PATH = { A: 'In-place upgrade' };
global.REASONS = { blockers: {
  'gen1-requires-redeploy': { title: 'Generation 1 machine', appliesTo: ['v6', 'v7'] },
  'windows-version-below-2019': { title: 'Windows older than 2019', appliesTo: ['v6', 'v7'] } }, prep: {} };
global.reasonText = (code) => (REASONS.blockers[code] || REASONS.prep[code] || {}).title || String(code);
global.judgeForSeries = lift('migrations.html', 'judgeForSeries');
global.NOT_STARTED_STATE = 'PLANNED';
global.PROBLEM_STATES = ['NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'];
const notMovedReasons = lift('migrations.html', 'notMovedReasons');
global.notMovedReasons = notMovedReasons;
const notMovedHtml = lift('migrations.html', 'notMovedHtml');
// FINISH-COUNT-1: vmCategory asks the page's one rule, which asks help.js.
global.WORKING_STATES = [];
global.VmfHelp = Object.assign(global.VmfHelp ?? {}, { machineOutcome: lift('help.js', 'machineOutcome'), outcomeWaitsOnPerson: lift('help.js', 'outcomeWaitsOnPerson') });
global.waitsOnPerson = lift('migrations.html', 'waitsOnPerson');
const vmCategory = lift('migrations.html', 'vmCategory');
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

const entry = (path, assessment, over) => Object.assign({ vmId: 'vm', path, planNotes: [], policy: { targetGeneration: 'v6' },
  assessment: Object.assign({ classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [] }, assessment) }, over || {});

test('THE REVIEW CASE: a Blocked machine with empty notes says its scan finding, for its own series', () => {
  const e = entry('MANUAL', { classification: 'Blocked', blockers: ['windows-version-below-2019'] });
  eq(JSON.stringify(notMovedReasons(e)), JSON.stringify(['Windows older than 2019']));
  const v5 = entry('MANUAL', { classification: 'Blocked', blockers: ['windows-version-below-2019'] }, { policy: { targetGeneration: 'v5' } });
  ok(!notMovedReasons(v5).includes('Windows older than 2019'), 'a finding that does not apply to v5 is not a reason on v5');
});

test('an excluded machine says which kind: not eligible, or already on its series', () => {
  eq(notMovedReasons(entry('EXCLUDED', { classification: 'Excluded', platformManaged: true }))[0], UX_FOUND.Excluded[1]);
  // READY-NOW-REMOVE-1: an older ReadyNow reads as ReadyAfterPrep, already on its series.
  eq(notMovedReasons(entry('EXCLUDED', { classification: 'ReadyNow' }))[0], UX_MISC.notMovedAlready);
  eq(notMovedReasons(entry('EXCLUDED', { classification: 'ReadyAfterPrep' }))[0], UX_MISC.notMovedAlready);
});

test('the plan\'s notes are reasons too, each reason once', () => {
  const note = 'This machine uses Azure Disk Encryption, and its move to v5 changes the kind of temporary disk, which is the in-place upgrade (Preview). The product does not move an encrypted machine that way, so it does not move it.';
  eq(JSON.stringify(notMovedReasons(entry('MANUAL', {}, { planNotes: [note, note] }))), JSON.stringify([note]));
  eq(notMovedReasons(entry('A', {}, { planNotes: ['x'] })), null, 'a machine that moves is not "not moved"');
});

test('the panel lists them, escaped; with none it says the plan records none - never "plan again"', () => {
  const html = notMovedHtml(entry('MANUAL', {}, { planNotes: ['<b>x</b>'] }));
  ok(html.includes(UX_MISC.notMovedTitle) && html.includes('&lt;b&gt;'), html);
  ok(notMovedHtml(entry('MANUAL', {})).includes(UX_MISC.notMovedNoReason));
  ok(!/again/i.test(UX_MISC.notMovedNoReason), 'planning again writes the same notes, so it is no advice');
  eq(notMovedHtml(entry('B', {})), '');
});

test('a machine that does not move is not "waiting to start"', () => {
  eq(vmCategory('PLANNED', entry('MANUAL', {})), 'done');
  eq(vmCategory('PLANNED', entry('A', {})), 'waiting');
  ok(PAGE.includes('vmCategory(v.state, v.entry, v.doc, v.st) === statusFilter'), 'the filter passes the entry');
});

test('the words: Not moved for the path, the group and the report; no action nobody can take', () => {
  eq(UX_MISC.notMoved, 'Not moved');
  ok(PAGE.includes("const UX_PATH = { A: 'In-place upgrade' };"), 'the path words on the page name the in-place upgrade only (OLD-REBUILD-RESTORE-READERS-1)');
  eq(UX_MISC.notInAWave, 'Not moved');
  ok(!/decide/i.test(UX_MISC.notInAWaveWhy), UX_MISC.notInAWaveWhy);
  const report = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Private', 'report', 'ReportHtml.ps1'), 'utf8');
  ok(report.includes("EXCLUDED = 'Not moved'; MANUAL = 'Not moved'"), 'the report says the same');
});

test('the row: Not moved with the reasons on hover, and no method, meter or last change', () => {
  global.UX_PATH = UX_PATH;
  const notMovedPill = lift('migrations.html', 'notMovedPill');
  const pill = notMovedPill(['Windows older than 2019', 'a "quoted" <reason>']);
  ok(pill.includes('>Not moved</span>') && pill.includes('title="Windows older than 2019; a &quot;quoted&quot; &lt;reason&gt;"'), pill);
  ok(notMovedPill([]).includes(`title="${UX_MISC.notMovedNoReason}"`), 'none: the plan records none');
  // Wiring: the row asks for it only for a machine that has not started.
  ok(PAGE.includes('const notMoved = v.state === NOT_STARTED_STATE ? notMovedReasons(v.entry) : null;'));
  // LAB-UX-1: a restored machine's state pill gives way to its Restored pill.
  // STATUS-WORDS-1: the one status pill, from the status of the row.
  ok(PAGE.includes('${notMoved ? notMovedPill(notMoved) : machinePill(doc, st, '), 'the status cell');
  eq((PAGE.match(/\$\{notMoved \? '<span class="muted">-<\/span>'/g) || []).length, 3, 'method, meter and last change');
});
run('not-moved');
