/* REBUILD-REMOVE-ACCEPT-1: no page asks a person to accept a rebuild or the
 * loss of a system-assigned identity.
 *
 * The owner removed the rebuild around the same disks on 2026-11-07, and
 * REBUILD-REMOVE-PLAN-1 stopped every new plan from giving one. What stayed on
 * the pages were the acceptances that existed only for the rebuild: the boxes
 * in Accept how this wave will run, Approve this wave and Run it's sign-off,
 * the list of what a rebuild changes, Accept this for one machine with an
 * object ID or a list of extensions, and the wave setting "If a machine would
 * get a new system-assigned identity". All are gone. A plan an earlier version
 * made with a rebuild is refused by the engine, and its words show in the
 * dialog (RebuildRemoveAccept.Tests.ps1 holds the engine to it).
 *
 * RUN: the pages' own dialogs and wave card, and what they send.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
require('./_at-once').install();

const REPO = path.join(__dirname, '..', '..');
const src = (f) => pageSource(path.join(REPO, 'src', 'dashboard', f));

let opened = null, sent = null;
globalThis.openModal = (o) => { opened = o; };
globalThis.apiFetch = (url, body) => { sent = { url, body }; return Promise.resolve({}); };
globalThis.runSeg = () => 'run-1';
globalThis.currentRun = 'run-1';
globalThis.DEMO_MODE = true;
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.noteField = () => ({ id: 'note', required: true });
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.leverKeepDays = lift('migrations.html', 'leverKeepDays');
globalThis.diskChangeTexts = () => [];
globalThis.decideDoneText = lift('migrations.html', 'decideDoneText');
const help = liftAll('help.js', ['seriesLabel', 'approvalRequired', 'keepDaysText', 'anOutcomeRow', 'anOutcomeNames', 'previewNames', 'isLearnLink', 'planNotesOf', 'signOffRiskLines', 'sqlTempdbEntries', 'sqlTempdbRisk']);
globalThis.VmfHelp = { ...help, VmfRun: { link: (p) => p } };
const MIG = src('migrations.html');
for (const name of ['anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames']) {
  const line = MIG.match(new RegExp(`\\nconst ${name} = [\\s\\S]*?;\\n`));
  // eslint-disable-next-line no-eval
  globalThis[name] = eval(line[0].replace(`const ${name} = `, '(').replace(/;\n$/, ')'));
}
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
// An older plan: one machine it rebuilds, with a system-assigned identity, the
// setting Continue and what the scan read for the rebuild - everything that
// used to draw a list and a box.
const olderPlan = { entries: [
  { vmId: SUB + 'app-01', wave: 'w1', path: 'B', target: { size: 'Standard_D4ds_v6', choice: { method: 'rebuild' } },
    assessment: { identityType: 'SystemAssigned', identityPrincipalId: '11111111-2222-3333-4444-555555555555',
      rebuildLinks: { sqlVirtualMachine: true, extensions: [{ name: 'SiteRecovery-Windows', publisher: 'Microsoft.Azure.RecoveryServices.SiteRecovery' }] } },
    policy: { requireApproval: true, onSystemAssignedIdentity: 'proceed' } },
  { vmId: SUB + 'app-02', wave: 'w1', path: 'A', target: { size: 'Standard_D4s_v6' }, assessment: {}, policy: { requireApproval: true } },
] };

test('RUN: Accept how this wave will run has no box and sends no list, even for an older plan', async () => {
  globalThis.planDoc = olderPlan;
  opened = null; sent = null;
  await lift('migrations.html', 'askAcceptOptions')('w1');
  ok(opened, 'the dialog opens');
  eq((opened.fields ?? []).length, 0, 'no box to tick');
  ok(!/identity|rebuild/i.test(opened.desc), 'no row or list of identities or rebuilds');
  await opened.onConfirm({});
  eq(sent.url, 'runs/run-1/waves/accept-options');
  eq(Object.keys(sent.body).sort().join(','), 'planHash,wave', 'the wave and the plan version, nothing else');
});

test('RUN: Approve this wave has no box and sends no list', async () => {
  globalThis.planDoc = olderPlan;
  opened = null; sent = null;
  await lift('migrations.html', 'askApprove')('w1');
  eq(opened.fields.map(f => f.id).join(','), 'note', 'the note only');
  ok(!/identity/i.test(opened.desc), 'no list of identities');
  await opened.onConfirm({ note: 'n' });
  eq(Object.keys(sent.body).sort().join(','), 'note,planHash');
});

test('RUN: Accept this for one machine sends the setting and the note only, never an account or extensions', async () => {
  opened = null; sent = null;
  const doc = { captured: { vmConfig: { identity: { type: 'SystemAssigned', principalId: '1111' } }, extensions: [{ name: 'x' }] } };
  lift('migrations.html', 'askDecide')(SUB + 'app-01', { whatToDo: 'w', decide: { lever: 'acceleratedNetworking', accept: 'ensureOn', namesAccount: 'systemAssignedIdentity', namesRebuild: true } }, doc);
  eq(opened.fields.map(f => f.id).join(','), 'note', 'no box for an account or a rebuild, whatever the reason says');
  await opened.onConfirm({ note: 'n' });
  eq(Object.keys(sent.body).sort().join(','), 'note,policyOverride,vmId');
});

test('the Migrations page has no words for an identity box, a rebuild list or the identity setting', () => {
  for (const k of ['idLossList', 'idAccept', 'idAcceptMissing', 'decideIdAccept', 'decideIdAccount', 'rbTitle', 'rbAccept', 'rbAcceptMissing', 'rbAlways']) eq(UX_ACT[k], undefined, `UX_ACT.${k}`);
  for (const k of ['onSystemAssignedIdentity', 'identityStop', 'identityProceed', 'identityStopHint', 'identityProceedHint', 'identityMachines']) eq(UX_LEVER[k], undefined, `UX_LEVER.${k}`);
});

test('Run it sends no list of machines with an acceptance or a sign-off, and draws no box', () => {
  const wiz = src('wizard.html');
  ok(!/identityLossNamed|rebuildNamed|data-idtick|data-rbtick/.test(wiz), 'no list and no box');
  const ux = liftConst('wizard.html', 'UX');
  for (const k of ['lvRebuild', 'lvIdentity', 'lvIdentityMachines', 'lvIdentityMeans', 'idTick', 'idTickMissing', 'rbAccept', 'rbAcceptMissing']) eq(ux[k], undefined, `UX.${k}`);
});

test('RUN: the wave editor has no identity setting - not on the card, not in a new wave, not in a save', () => {
  const D = require('./_at-once').waveRule.waveSettingDefaults();
  ok(!('onSystemAssignedIdentity' in D), 'no default for it');
  const ux = liftConst('waves.html', 'UX');
  for (const k of ['identityLabel', 'identityStop', 'identityProceed', 'identityTag', 'identityTip', 'changeRebuild', 'rebuildOne', 'rebuildMany', 'rebuildPill']) eq(ux[k], undefined, `UX.${k}`);
  const waves = src('waves.html');
  ok(!/onSystemAssignedIdentity|data-identity|data-idhelp/.test(waves), 'no control, no helper and no field in the save');
});

test('help.js has no identity or rebuild rule left to ask', () => {
  const h = src('help.js');
  for (const n of ['getsNewIdentity', 'identityOutcome', 'identityKeeper', 'identityLossToAccept', 'rebuildToAccept', 'rebuildFollowUps', 'rebuildNames', 'newIdentityNames']) {
    ok(!new RegExp(`function ${n}\\(`).test(h), `help.js still has ${n}`);
  }
});

run('rebuild-remove-accept');
