/* ATTEST-1 on the Reports page: the migration record, for administrators.
 *
 * The readable record is a document a customer KEEPS and hands to an auditor
 * or a change board. It is built from store data, and notes in it are typed by
 * people - so every value must be escaped. Since REPORT-THEME-1 its only style
 * is the report's own stylesheet, read from the service; it has none of its
 * own (the page rules).
 *
 * RUN, not read: the page's own recordHtml.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, ok, run } = require('./_harness');

// DISCLAIMER-1: the record ends with the short line, which the page reads from
// help.js (VmfHelp.disclaimerLine). tests/js/disclaimer.test.js holds the words.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { disclaimerLine: 'The short line.' });

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'reports.html'));
globalThis.UX = liftConst('reports.html', 'UX');
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const recordHtml = lift('reports.html', 'recordHtml');
const U = globalThis.UX;

const HOSTILE = '<img src=x onerror=alert(1)>';
const rec = {
  schemaVersion: 1, runId: 'mig-1', project: 'estate', fromAssessment: 'scan-1',
  generatedUtc: '2026-09-24T20:00:00Z', generatedBy: 'admin@example.com', reason: 'deleted', keepUntilUtc: '2026-12-23T20:00:00Z',
  summary: { migrated: 1, putBack: 1, rolledBack: 0, attention: 0, leftOut: 0, working: 0, notStarted: 0, unknown: 0 },
  decisions: [{ what: 'signed off the plan', wave: null, by: 'approver@example.com', atUtc: '2026-09-23T15:10:00Z', note: HOSTILE, version: 'abc' }],
  machines: [
    { vmId: '/x/web', name: 'web', wave: 'w1', state: 'MIGRATED', outcome: 'migrated',
      before: { size: 'Standard_D2s_v4', controller: 'SCSI' }, target: { size: 'Standard_D2s_v6', controller: 'NVMe' },
      now: { size: 'Standard_D2s_v6', controller: 'NVMe', basis: 'the plan target, which the machine passed validation against' },
      steps: [{ tsUtc: '2026-09-23T22:00:00Z', state: 'PRECHECK', outcome: 'ok', durationSec: 12, detail: HOSTILE }],
      guestScripts: [{ tsUtc: '2026-09-23T22:03:00Z', script: 'Test-GuestValidation.ps1', version: '1.0.0', result: 'PASS', sha256: 'f'.repeat(64) }],
      putBack: null, activity: [{ tsUtc: '2026-09-23T22:01:00Z', step: 'azureops:deallocate', outcome: 'ok' }] },
    { vmId: '/x/db', name: 'db', wave: 'w1', state: 'MIGRATED', outcome: 'putBack',
      before: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' }, now: { size: 'Standard_D2s_v4', basis: 'the restore record' },
      steps: [], guestScripts: [], putBack: { restoredUtc: '2026-09-24T10:00:00Z', restoredBy: 'operator@example.com', sizeAfter: 'Standard_D2s_v4' }, activity: [] },
    { vmId: '/x/app', name: 'app', wave: 'w1', state: 'MIGRATED', outcome: 'migrated',
      before: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' }, now: { size: 'Standard_D2s_v6', basis: 'the plan target' },
      steps: [], guestScripts: [], putBack: null, activity: [],
      retention: { deletedUtc: '2026-10-01T03:31:00Z', keepDays: 7, deletedSnapshotIds: ['/s/1', '/s/2'], deletedBy: 'retention (scheduled)' } }],
  runActivity: [{ tsUtc: '2026-09-23T15:10:00Z', step: 'approval', outcome: 'ok', detail: 'the plan was signed off' }],
};

test('RUN: nothing typed by a person or read from the store reaches the document as markup', () => {
  const html = recordHtml(rec);
  ok(!html.includes(HOSTILE), 'the hostile note is not in the document as markup');
  ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'), 'it is there, escaped');
});

test('RUN: it says who made it, why, and until when it is kept', () => {
  const html = recordHtml(rec);
  ok(html.includes('admin@example.com'), 'who');
  ok(html.includes(U.recWhy.deleted), 'why - here, because the migration was deleted');
  ok(html.includes('2026-12-23T20:00:00Z'), 'kept until');
});

test('RUN: each machine has its before, target and now - and where the now comes from', () => {
  const html = recordHtml(rec);
  ok(html.includes('Standard_D2s_v4') && html.includes('Standard_D2s_v6'), 'sizes');
  ok(html.includes('the plan target, which the machine passed validation against'), 'the basis is said');
  ok(html.includes(U.outcomeWords.putBack), 'a put-back is named as one');
  ok(html.includes('operator@example.com'), 'with who put it back');
  ok(html.includes('f'.repeat(64)), 'guest scripts carry their hash');
});

test('RUN: the decisions, with who and the version signed', () => {
  const html = recordHtml(rec);
  ok(html.includes('signed off the plan') && html.includes('approver@example.com') && html.includes('abc'), 'the sign-off');
});

/* REPORT-THEME-1 REVERSED the old rule here, on purpose. This test said "no
 * stylesheet and no colour of its own", so the record printed the same
 * everywhere - and looked like a different product from the report. The
 * decision (issue 426): the record uses the report's SAME stylesheet,
 * one copy, read from the service. What still holds is the half that kept it
 * honest: nothing of its OWN - the only style in it is the one it was given. */
test('RUN: the report stylesheet it was given, and no colour of its own beside it', () => {
  const look = { stylesheet: ':root{--bg:#f8f9fa}.sheet{margin:0}', logo: '<svg viewBox="0 0 32 32"></svg>' };
  const html = recordHtml(rec, look);
  ok(html.split(look.stylesheet).length === 2, 'the given stylesheet, once');
  const own = html.replace(look.stylesheet, '');
  ok(!/#[0-9a-f]{3,6}\b|rgb\(|hsl\(/i.test(own), 'no colour literal of its own');
  ok(!/style="/i.test(own), 'no inline style');
  ok(!/<style/i.test(recordHtml(rec)), 'and with none given, no style block at all');
});

test('only an administrator is offered it, and the service is asked with the project in the body', () => {
  ok(/isAdmin = DEMO_MODE \|\| \(await VmfHelp\.myRoles\(cfg, getToken, msalApp\)\)\.roles\.includes\('Vmf\.Admin'\);/.test(PAGE), 'the role decides');
  ok(/\$\{isAdmin \? recordButton\('data-record', run\) : ''\}/.test(PAGE), 'the run detail offers it to an administrator only');
  ok(/if \(!isAdmin\) \{ return \[\]; \}/.test(PAGE), 'and so does the records tab (PAGE-SCALE-REPORTS-1)');
  ok(/apiCall\('POST', `runs\/\$\{VmfHelp\.VmfRun\.routeSegment\(run\)\}\/record`, null, VmfHelp\.VmfRun\.withProject\(\{\}, run\)\)/.test(PAGE), 'PROJECT-4');
});

// RETAIN-SHOW-1: a machine whose safety copies were deleted says so, with
// when, by whom, how many and after how many days. The record already held it
// and the readable document never showed it.
test('RUN: deleted safety copies are in the record - when, by whom, how many, after how long', () => {
  const html = recordHtml(rec);
  ok(html.includes('2026-10-01T03:31:00Z'), 'when');
  ok(html.includes(U.rDailyCleanup), 'by the daily cleanup, in words - not its account name');
  ok(!html.includes('retention (scheduled)'), 'the account name is not shown as a person');
  ok(html.includes('2 safety copies deleted '), 'how many');
  ok(/7 days/.test(html), 'after how many days');
});

test('RUN: a person who deleted them is named', () => {
  const one = JSON.parse(JSON.stringify(rec));
  one.machines[2].retention.deletedBy = 'custodian@example.com';
  ok(recordHtml(one).includes('custodian@example.com'), 'the person');
});

test('RUN: a machine whose copies are still kept says nothing about deletion', () => {
  const html = recordHtml(rec);
  const web = html.slice(html.indexOf('>web &middot;'), html.indexOf('>db &middot;'));
  ok(web.length > 20 && !web.includes(' safety copies deleted '), 'no deletion line for web');
});

run('migration-record');
