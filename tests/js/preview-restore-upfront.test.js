/* PREVIEW-RESTORE-UPFRONT-1: the service refuses Restore this machine from
 * the first copy of a move by the in-place upgrade (Preview) with a 400,
 * before a job starts, when the preview feature VMTempDiskResizePreview is
 * not registered (tests/unit/PreviewRestoreUpfront.Tests.ps1). The restore
 * dialog shows that refusal in the engine's words, without the code, and
 * stays open.
 *
 * RUN, not read: the page's own askRestore, and help.js's rules evaluated
 * from the file itself (as retry-gate.test.js takes them).
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const START = 'const ROLE_WORDS';
const END = 'function explainAction(err) { return explainWith(err, true); }';
const from = HELP.indexOf(START);
const to = HELP.indexOf(END);
const slice = (from >= 0 && to > from) ? HELP.slice(from, to + END.length) : '';
// eslint-disable-next-line no-eval
const rules = slice ? eval(`(function () { ${slice}; return { explain, explainAction }; })()`) : null;

// The words Get-VmfPreviewPutBackVerdict gives for a restore (Kind restore),
// feature NotRegistered, machine on its new size.
const SENTENCE = 'This machine took the in-place upgrade (Preview). A rollback or a restore to Standard_D4ds_v4 changes the temporary disk again. ' +
  'Azure allows that only when the preview feature VMTempDiskResizePreview is registered on subscription Applications (00000000-0000-0000-0000-000000000000). ' +
  'Azure gives its state as NotRegistered, and it is not registered. Nothing on the machine changed. ' +
  'Register the preview feature VMTempDiskResizePreview on subscription Applications (00000000-0000-0000-0000-000000000000) again. ' +
  'In the Azure portal, open the subscription, then Settings, then Preview features. Then use Restore this machine again.';
const REFUSAL = `400: ${SENTENCE}`;

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.noteField = () => ({ id: 'note', label: 'Why?', type: 'textarea' });
globalThis.runSeg = () => 'run-1';
globalThis.agoSpan = (s) => `<span data-ago="${s}">ago</span>`;
const page = liftAll('migrations.html', ['restoreShapes', 'shapeWords', 'restoreCopyField',
  'restoreExceptions', 'restoreKeepInstantNote', 'restoreDiskNames', 'putBackRetireNote', 'askRestore', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText',
  'restoreSiteRecoveryWords']);

const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/win-01';
const doc = {
  vmId: VM, state: 'MIGRATED',
  captured: {
    vmConfig: { size: 'Standard_D4ds_v4', controller: 'SCSI', osDisk: { name: 'win-01-os' }, dataDisks: [] },
    startedTarget: { path: 'A', size: 'Standard_D4ds_v6', controller: 'NVMe', target: { choice: { method: 'preview' } } },
  },
  history: [{ tsUtc: '2026-11-03T08:30:00Z', state: 'PRECHECK', outcome: 'ok' }],
  safety: { pristineSnapshotId: '/snap/win-01-pristine', snapshotId: '/snap/win-01' },
};

test('help.js: the service refusal of a Preview restore is said as its sentence, without the code', () => {
  ok(rules, 'the rules were not found in help.js');
  eq(rules.explainAction(new Error(REFUSAL)), SENTENCE);
});

test('Restore this machine: the refusal reaches the dialog - the start is asked once, and its error is not swallowed', async () => {
  let opts = null;
  globalThis.openModal = (o) => { opts = o; };
  page.askRestore(VM, doc);
  ok(opts && typeof opts.onConfirm === 'function', 'the restore dialog opened');
  const calls = [];
  globalThis.apiFetch = async (p, body) => { calls.push({ p, body }); throw new Error(REFUSAL); };
  const copy = (opts.fields.find(f => f && f.id === 'copy') || {});
  const answers = { note: 'Put the machine back.', copy: 'pristine', source: 'pristine', naming: 'new' };
  if (copy.options) { answers.copy = (copy.options.find(o => o.value === 'pristine') || copy.options[0]).value; }
  let thrown = null;
  try { await opts.onConfirm(answers); } catch (e) { thrown = e; }
  eq(calls.length, 1, 'the service was asked once');
  ok(thrown, 'the error goes to the dialog, which shows it with VmfHelp.explainAction');
  eq(rules.explainAction(thrown), SENTENCE);
});

run('preview-restore-upfront');
