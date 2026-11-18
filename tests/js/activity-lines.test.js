/* ACTIVITY-LINES-1: the Activity list of the Migrations page shows a step
 * attempt that the engine tried again as one line, never as red.
 *
 * MEASURED on the lab install, 2026-11-04: the stop step of a machine failed on
 * attempt 1 with a connection reset and went on. The Activity list drew two red
 * "Open the machine to see why this step failed." lines: the Azure call's line
 * and the step's line, for one event. The engine now writes the step's
 * attempt as a retry line with the cause (ActivityLines.Tests.ps1), and the
 * list shows the Azure call's line of the same attempt and the same cause as
 * that one line.
 *
 * RUN, not read: the page's own renderEvents, stepText and words.
 */
'use strict';
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.ago = () => '5 minutes ago';

// The helpers this item adds are lifted when the page has them, so the tests
// below fail on what the page DOES before the change, not on a missing name.
// STATUS-WORDS-1: the list also says what follows a failure (rollbackFollows).
globalThis.UX_RAN = liftConst('migrations.html', 'UX_RAN');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: (id) => String(id == null ? '' : id).toLowerCase() });
const helpers = ['foldedCallLines', 'retriedText', 'stepRetried', 'rollbackFollows', 'activityLines'].filter(n => { try { extract('migrations.html', n); return true; } catch { return false; } });
const page = liftAll('migrations.html', ['stepText', 'renderEvents', 'feedFailNote', ...helpers]);

const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1';
const CAUSE = '104 - An error occurred while sending the request. -> Unable to read data from the transport connection: Connection reset by peer.';

/** The rows the Activity list draws for these events, as HTML strings. */
function rows(events, whole) {
  const drawn = [];
  const tbody = { set innerHTML(v) { drawn.length = 0; if (v) { drawn.push(v); } }, get innerHTML() { return drawn.join(''); },
    insertAdjacentHTML(_where, html) { drawn.push(html); } };
  const el = () => ({ classList: { toggle() { } }, hidden: false, textContent: '' });
  const parts = { '#event-table tbody': tbody, '#event-scroll': el(), '#ev-toggle': el(), '#ev-count': el() };
  globalThis.$ = (sel) => parts[sel];
  globalThis.FEED_RECENT = 30;
  globalThis.showWholeLog = Boolean(whole);
  globalThis.toggleWholeLog = () => { };
  page.renderEvents(events);
  return drawn.filter(r => r.startsWith('<tr'));
}
const at = (min, sec) => `2026-11-04T22:${String(min).padStart(2, '0')}:${String(sec ?? 0).padStart(2, '0')}Z`;

/* The lab's stop step, as the engine writes it now. */
const recovered = [
  { tsUtc: at(24, 50), step: 'STOPPED', outcome: 'start', vmId: VM },
  { tsUtc: at(25, 20), step: 'azureops:runcmd:Test-NvmeReady.ps1', outcome: 'fail', vmId: VM, detail: CAUSE, attempt: 1, transient: false },
  { tsUtc: at(25, 21), step: 'STOPPED', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 2 },
  { tsUtc: at(25, 22), step: 'STOPPED', outcome: 'start', vmId: VM },
  { tsUtc: at(25, 57), step: 'azureops:deallocate', outcome: 'ok', vmId: VM },
  { tsUtc: at(25, 58), step: 'STOPPED', outcome: 'ok', vmId: VM, detail: 'deallocated' },
];

test('the page has the helpers of this item', () => {
  // STATUS-WORDS-1 added rollbackFollows: a failure a rollback follows says so.
  // RESTORE-PANEL-TIMELINE-1 added activityLines: the one line rule of the table and the machine panel.
  eq(helpers, ['foldedCallLines', 'retriedText', 'stepRetried', 'rollbackFollows', 'activityLines'], 'helpers lifted from the page');
});

test('THE DEFECT: a stop step tried again and gone on shows ONE line, with the cause, and no red', () => {
  const r = rows(recovered);
  eq(r.filter(x => x.includes('pill bad')).length, 0, 'red lines');
  const withCause = r.filter(x => x.includes('Connection reset by peer'));
  eq(withCause.length, 1, 'lines that name the cause');
  ok(withCause[0].includes(page.retriedText({ attempt: 1, maxAttempts: 2 })), 'the line says the engine tries the step again');
  ok(withCause[0].includes('Attempt 1 of 2 failed. The product tries the step again.'), 'the words of the line');
  ok(!withCause[0].includes(UX_STEP.failedNote), 'never "Open the machine to see why this step failed."');
});

test('the whole log shows both lines the engine wrote, and neither is red', () => {
  const r = rows(recovered, true);
  const withCause = r.filter(x => x.includes('Connection reset by peer'));
  eq(withCause.length, 2, 'the Azure call line and the step line');
  eq(r.filter(x => x.includes('pill bad')).length, 0, 'red lines');
  ok(withCause.every(x => x.includes('Attempt 1 of 2 failed')), 'both say the attempt was tried again');
});

test('the attempt that ends the step is ONE red line, with the cause', () => {
  const ended = [
    { tsUtc: at(30), step: 'STOPPED', outcome: 'start', vmId: VM },
    { tsUtc: at(30, 30), step: 'azureops:deallocate', outcome: 'fail', vmId: VM, detail: CAUSE },
    { tsUtc: at(30, 31), step: 'STOPPED', outcome: 'fail', vmId: VM, detail: CAUSE, attempt: 2, maxAttempts: 2 },
  ];
  const r = rows(ended);
  const red = r.filter(x => x.includes('pill bad'));
  eq(red.length, 1, 'red lines');
  ok(red[0].includes('Connection reset by peer'), 'the red line has the cause');
  ok(red[0].includes(UX_STEP.failedNote), 'and says where to look');
  eq(rows(ended, true).filter(x => x.includes('pill bad')).length, 2, 'the whole log keeps the Azure call line, red');
});

test('an Azure call line with another cause is its own line', () => {
  const two = [
    { tsUtc: at(40), step: 'STOPPED', outcome: 'start', vmId: VM },
    { tsUtc: at(40, 10), step: 'azureops:runcmd:Test-NvmeReady.ps1', outcome: 'fail', vmId: VM, detail: 'HTTP 403 AuthorizationFailed - no' },
    { tsUtc: at(40, 11), step: 'STOPPED', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 2 },
  ];
  const r = rows(two);
  eq(r.filter(x => x.includes('AuthorizationFailed')).length, 1, 'the call line with its own cause stays');
});

test('an Azure call line of an EARLIER attempt is not taken into a later attempt', () => {
  const earlier = [
    { tsUtc: at(41), step: 'STOPPED', outcome: 'start', vmId: VM },
    { tsUtc: at(41, 10), step: 'azureops:deallocate', outcome: 'fail', vmId: VM, detail: CAUSE },
    { tsUtc: at(45), step: 'STOPPED', outcome: 'start', vmId: VM },
    { tsUtc: at(45, 10), step: 'STOPPED', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 2 },
  ];
  eq(page.foldedCallLines(earlier).size, 0, 'nothing taken across the start of the attempt');
});

test('another machine: its call line is not taken into this machine\'s line', () => {
  const other = [
    { tsUtc: at(42), step: 'STOPPED', outcome: 'start', vmId: VM },
    { tsUtc: at(42, 10), step: 'azureops:deallocate', outcome: 'fail', vmId: VM + '2', detail: CAUSE },
    { tsUtc: at(42, 11), step: 'STOPPED', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 2 },
  ];
  eq(page.foldedCallLines(other).size, 0, 'another machine');
});

test('finding 21: Verifying tried again and then failed shows both attempts, each once', () => {
  const v = [
    { tsUtc: at(50), step: 'VALIDATING', outcome: 'start', vmId: VM },
    { tsUtc: at(50, 30), step: 'VALIDATING', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 2 },
    { tsUtc: at(50, 31), step: 'VALIDATING', outcome: 'start', vmId: VM },
    { tsUtc: at(51), step: 'VALIDATING', outcome: 'fail', vmId: VM, detail: CAUSE, attempt: 2, maxAttempts: 2 },
  ];
  const r = rows(v);
  eq(r.filter(x => x.includes('Connection reset by peer')).length, 2, 'attempt 1 and attempt 2');
  eq(r.filter(x => x.includes('pill bad')).length, 1, 'only the attempt that ended the step is red');
});

test('a retry line with no attempt numbers still says the engine tries again', () => {
  const r = rows([{ tsUtc: at(55), step: 'GUEST_PREP', outcome: 'retry', vmId: VM, detail: CAUSE }]);
  ok(r[0].includes(UX_STEP.retriedNoteBare), 'the words without numbers');
});

test('an Azure call that Azure only asked to wait (its own retry line) reads as before', () => {
  const r = rows([{ tsUtc: at(56), step: 'azureops:deallocate', outcome: 'retry', vmId: VM, detail: '429 throttled', attempt: 1 }]);
  ok(!r[0].includes('pill bad') && !r[0].includes('pill quiet') && !r[0].includes(UX_STEP.retriedNoteBare), 'no step pill on a call retry');
  eq(page.stepRetried({ step: 'azureops:deallocate', outcome: 'retry', vmId: VM }), false, 'an Azure call is not a step of the move');
  eq(page.stepRetried({ step: 'STOPPED', outcome: 'retry', vmId: VM }), true, 'a step of the move');
});

test('review: a step with three attempts shows attempt 1 and attempt 2, each once, in the default list', () => {
  const three = [
    { tsUtc: at(58), step: 'GUEST_PREP', outcome: 'start', vmId: VM },
    { tsUtc: at(58, 20), step: 'GUEST_PREP', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 1, maxAttempts: 3 },
    { tsUtc: at(58, 21), step: 'GUEST_PREP', outcome: 'start', vmId: VM },
    { tsUtc: at(58, 50), step: 'GUEST_PREP', outcome: 'retry', vmId: VM, detail: CAUSE, attempt: 2, maxAttempts: 3 },
    { tsUtc: at(58, 51), step: 'GUEST_PREP', outcome: 'start', vmId: VM },
    { tsUtc: at(59, 30), step: 'GUEST_PREP', outcome: 'ok', vmId: VM },
  ];
  const r = rows(three);
  eq(r.filter(x => x.includes('Attempt 1 of 3 failed')).length, 1, 'attempt 1');
  eq(r.filter(x => x.includes('Attempt 2 of 3 failed')).length, 1, 'attempt 2');
});

/* LOG-1, held since RESTORE-PANEL-TIMELINE-1 moved the line rule into
 * activityLines: the table shows the newest FEED_RECENT lines, and the whole
 * log every line. */
test('the table shows the newest 30 lines, and the whole log shows every line', () => {
  const many = Array.from({ length: 35 }, (_, i) => ({ tsUtc: at(30, i), step: 'restore', outcome: 'info', vmId: VM, detail: `line ${i}` }));
  const recent = rows(many);
  eq(recent.length, 30, 'the newest 30');
  ok(recent[0].includes('line 34') && !recent.some(r => r.includes('line 4<')), 'newest first, the oldest left out');
  eq(rows(many, true).length, 35, 'the whole log');
});

run('activity-lines');
