/* PUTBACK-GONE-1: "Putting back" vanished while the put-back was still running.
 *
 * Seen in the lab: the page showed "putting back" in yellow for a while, then
 * stopped showing it, though the put-back ran for a few more minutes.
 *
 * The item guessed at a log window. It was not that - the page reads every part
 * of the log. It was that the page ended a put-back on ANY restore event other
 * than the start, and the engine writes progress under the same step.
 *
 * RUN: the page's own restoreIndex, driven with the sequence the engine
 * actually writes - and the engine's list of outcomes READ FROM ITS SOURCE, so
 * the page and the engine cannot drift apart silently.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const ENGINE = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Public', 'Restore-VmfVm.ps1'), 'utf8');

// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
globalThis.stepText = (e) => e.step;
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: eval('(' + pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
const { restoreIndex, restoreRecordEnds, restoreInFlight } = liftAll('migrations.html', ['restoreIndex', 'restoreRecordEnds', 'restoreInFlight']);

const VM = '/x/vm1';
const ev = (min, step, outcome) => ({ tsUtc: new Date(Date.UTC(2026, 8, 23, 22, min)).toISOString(), vmId: VM, step, outcome });

test('RUN: the lab put-back - still "putting back" after the progress notes', () => {
  const events = [
    ev(0, 'restore', 'start'),
    ev(1, 'azureops:restore:deallocate', 'ok'),
    ev(2, 'restore', 'info'),                   // left the reserved capacity
    ev(3, 'azureops:restore:createDisk', 'ok'),
    ev(5, 'restore', 'info'),                   // reverted to the captured size
    ev(6, 'azureops:restore:start', 'start'),
  ];
  const open = restoreIndex(events).get(VM);
  ok(open, 'the machine is still shown as putting back');
  eq(open.doing, 'azureops:restore:start', 'with the newest step under it');
});

test('RUN: and it ends on each way the engine ends one', () => {
  for (const end of ['ok', 'warn', 'fail']) {
    const idx = restoreIndex([ev(0, 'restore', 'start'), ev(2, 'restore', 'info'), ev(9, 'restore', end)]);
    ok(!idx.has(VM), `ended by ${end}`);
  }
});

test('every outcome the engine writes for a put-back is known to the page', () => {
  /* Read from Restore-VmfVm.ps1. A new outcome the page does not know would
   * either end the indicator early (the defect) or never end it - so it has to
   * be classified here, on purpose, before it ships. */
  const written = [...ENGINE.matchAll(/-Step 'restore' -Outcome (\w+)/g)].map(m => m[1]);
  ok(written.length >= 4, `found the engine's restore events, got ${written.length}`);
  const known = new Set(['start', 'info', ...RESTORE_ENDS]);
  for (const o of written) { ok(known.has(o), `the page knows what "${o}" means`); }
  for (const o of RESTORE_ENDS) { ok(written.includes(o), `"${o}" really is written by the engine`); }
});

test('STEP-LOG-2: a restore whose last line was lost is ended by the machine\'s record of it', () => {
  const open = restoreIndex([ev(0, 'restore', 'start'), ev(2, 'restore', 'info')]).get(VM);
  ok(open, 'the log alone still shows it open');
  const at = (min) => new Date(Date.UTC(2026, 8, 23, 22, min)).toISOString();
  ok(restoreRecordEnds(open, { restore: { restoredUtc: at(9) } }), 'a record written after the start ends it');
  ok(!restoreRecordEnds(open, { restore: { restoredUtc: '2026-09-01T00:00:00Z' } }), 'an earlier restore\'s record does not');
  ok(!restoreRecordEnds(open, { state: 'MIGRATED' }), 'no record: still open');
  ok(!restoreRecordEnds(null, { restore: { restoredUtc: at(9) } }), 'nothing open: nothing to end');
});

test('STEP-LOG-2: the row asks the record, so "Restoring" ends for a machine whose restore is recorded', () => {
  globalThis.restoresInFlight = restoreIndex([ev(0, 'restore', 'start')]);
  ok(restoreInFlight(VM, { state: 'MIGRATED' }), 'no record: Restoring');
  ok(!restoreInFlight(VM, { restore: { restoredUtc: new Date(Date.UTC(2026, 8, 23, 22, 9)).toISOString() } }), 'recorded: not Restoring');
});

/* RESTORE-END-LOST-1: a FAILED restore writes no record, so the record cannot
 * end it. Every failure of Restore-VmfVm throws, and the engine's own catch
 * (docker/entrypoint.ps1) then writes `engine:restore` / `fail` with the reason.
 * That line names the machine, so it ends "Restoring" for that machine when the
 * restore's own fail or warn line was lost. */
const ENTRY = fs.readFileSync(path.join(__dirname, '..', '..', 'docker', 'entrypoint.ps1'), 'utf8');

test('RESTORE-END-LOST-1: the engine\'s own fail line ends a restore whose last line was lost', () => {
  // The engine gives its operation one id (correlationId): on the restore's
  // start line and on its own fail line.
  const start = (min, op, vmId = VM) => ({ ...ev(min, 'restore', 'start'), vmId, correlationId: op });
  const engineLine = (min, step, outcome, vmId, op = 'op-1') => ({ ...ev(min, step, outcome), vmId, correlationId: op, detail: 'The restore did not complete.' });
  const lost = [start(0, 'op-1'), ev(1, 'azureops:restore:deallocate', 'ok'), ev(2, 'restore', 'info')];
  ok(restoreIndex(lost).has(VM), 'with the last line lost, the log alone shows it open');
  ok(!restoreIndex([...lost, engineLine(9, 'engine:restore', 'fail', VM)]).has(VM), 'the engine\'s fail line for this restore ends it');
  ok(!restoreIndex([...lost, engineLine(9, 'engine:restore', 'refused', VM)]).has(VM), 'a refusal of the operation ends it too');
  ok(restoreIndex([...lost, engineLine(9, 'engine:restore', 'fail', '/x/vm2')]).has(VM), 'a fail line for another machine does not');
  ok(restoreIndex([...lost, engineLine(9, 'engine:restore', 'fail', undefined)]).has(VM), 'a fail line that names no machine cannot end one');
  ok(restoreIndex([...lost, engineLine(9, 'engine:restore', 'info', VM)]).has(VM), 'the engine\'s start line is not an end');
  ok(restoreIndex([...lost, engineLine(9, 'engine:rebuild', 'fail', VM)]).has(VM), 'another operation\'s fail line is not the end of a restore');
  ok(restoreIndex([...lost, engineLine(9, 'engine:restore', 'fail', VM, null)]).has(VM), 'a fail line with no operation id cannot say which restore it ends');
  ok(restoreIndex([ev(0, 'restore', 'start'), engineLine(9, 'engine:restore', 'fail', VM)]).has(VM), 'nor a start line with none');
  ok(restoreIndex([ev(0, 'restore', 'start'), { ...ev(9, 'engine:restore', 'fail'), vmId: VM }]).has(VM), 'nor two lines that both have none');
});

test('RESTORE-END-LOST-1 review: a second restore that fails does not end the first', () => {
  const start = (min, op) => ({ ...ev(min, 'restore', 'start'), correlationId: op });
  const engineFail = (min, op) => ({ ...ev(min, 'engine:restore', 'fail'), correlationId: op, detail: 'x' });
  // The first restore runs with the machine stopped; a second one for the same
  // machine is refused before its own start line.
  ok(restoreIndex([start(0, 'op-1'), ev(1, 'azureops:restore:deallocate', 'ok'), engineFail(3, 'op-2')]).has(VM),
    'the first restore still shows Restoring');
  // The first fails, then a second starts at once: the second shows.
  const idx = restoreIndex([start(0, 'op-1'), engineFail(3, 'op-1'), start(4, 'op-2')]);
  ok(idx.has(VM), 'the second restore shows Restoring');
  eq(idx.get(VM).since, ev(4).tsUtc, 'from its own start');
  ok(!restoreIndex([start(0, 'op-1'), engineFail(3, 'op-1'), start(4, 'op-2'), engineFail(6, 'op-2')]).has(VM), 'and its own fail line ends it');
});

test('RESTORE-END-LOST-1 review: the machine is matched without case', () => {
  /* The restore's lines carry the id as the run's record spells it
   * (Resolve-VmfRecordedVmId); the engine's line carries the id the page sent. */
  const start = { ...ev(0, 'restore', 'start'), vmId: '/X/Vm1', correlationId: 'op-1' };
  const fail = { ...ev(3, 'engine:restore', 'fail'), vmId: '/x/vm1', correlationId: 'op-1' };
  ok(restoreIndex([start]).size === 1, 'open before the fail line');
  ok(restoreIndex([start, fail]).size === 0, 'the fail line in another case ends it');
  globalThis.restoresInFlight = restoreIndex([start]);
  ok(restoreInFlight('/x/VM1', { state: 'MIGRATED' }), 'and the row asks in any case');
});

test('RESTORE-END-LOST-1: the engine names the machine and the operation on its fail line', () => {
  /* The page can end only the restore the line names. Read from the catch
   * that writes the line (EngineEntrypoint.Tests.ps1 runs it). */
  const at = ENTRY.search(/^catch \{/m);
  ok(at >= 0, 'found the engine\'s catch');
  const caught = ENTRY.slice(at);
  ok(/engine:\$\(\$env:VMF_OPERATION\)/.test(caught), 'it writes the engine\'s fail line');
  ok(/-Outcome fail -Detail \$why -VmId \$vm -CorrelationId \$cid\b/.test(caught), 'with -VmId and -CorrelationId');
  ok(/\[string\]\$env:VMF_VM_ID/.test(caught), 'the machine is the one the operation was given');
  ok(/\$engineRunId\b/.test(caught), 'and the id is the operation\'s own');
});
test('RESTORE-END-LOST-1: the Activity does not send a person to the machine for the engine\'s reason', () => {
  /* The engine's line carries its reason in the row, and the machine's panel
   * does not show the run's log. */
  globalThis.UX_STEP = { failedNote: 'machine', failedNoteRun: 'run' };
  const feedFailNote = liftAll('migrations.html', ['feedFailNote']).feedFailNote;
  eq(feedFailNote({ step: 'engine:restore', outcome: 'fail', vmId: VM }), 'run', 'an engine line with a machine');
  eq(feedFailNote({ step: 'engine:wave', outcome: 'fail' }), 'run', 'an engine line without one');
  eq(feedFailNote({ step: 'restore', outcome: 'fail', vmId: VM }), 'machine', 'a machine\'s own step');
  eq(feedFailNote({ step: 'schedule', outcome: 'fail' }), 'run', 'a run step');
});

run('putback-gone');
