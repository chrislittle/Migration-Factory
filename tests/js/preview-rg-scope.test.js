/* PREVIEW-RG-SCOPE-1: the Preview box on the step Choose each target says
 * what is wrong and what to do, in the words approved on
 * 2026-11-11.
 *
 * STATE A - the product cannot read the feature state: the first line, then
 * the error code from Azure when it gave one. AuthorizationFailed (A1) says
 * that Azure did not let the product read the feature (PREVIEW-ACCESS-WORDS-1)
 * and gives the steps; any
 * other code (A2), or none, says "Select Check again.".
 * The sentence "The product has access to resource groups only in this
 * subscription." is NOT shown: this page cannot read where the product has
 * access (the Admin page reads the role assignments with the signed-in
 * user's own Azure token; the web service has no role assignment read).
 *
 * STATE B - read, not registered: who registers it and the steps in the
 * Azure portal; then the v5 way, only when every machine in the box has a v5
 * size that moves in place (it keeps a SCSI temporary disk). An F machine,
 * for example, has no v5 option (target-families.json: v5 is D and E).
 *
 * No HTTP status shows. The (?) keeps what the feature is, that the product
 * does not register it, and to keep it registered - not the portal steps,
 * which are in the box.
 *
 * RUN: the page's own functions, with machines shaped like target-advice.json.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = require('./_identity').help(Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['seriesLabel', 'machineStarted'])));

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.shortSize = constArrow('shortSize');
globalThis.fill = constArrow('fill');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.reasonText = (c) => String(c);
const fns = liftAll('wizard.html', ['tHelpBtn', 'sizeOf', 'advPick', 'tMethodOf', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered',
  'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tPreviewV5Way', 'tPreviewMoreHtml', 'tPreviewNoticeHtml']);
const SUB_APPS = '00000000-0000-0000-0000-000000000000';
globalThis.assessment = { vms: [] };
const resetT = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tHelp = new Set(); globalThis.tPreview = new Map();
};
const opt = (option, preview, extra) => Object.assign({
  option, supported: true, notSupported: [], targetSize: `Standard_D2ds_${option}`,
  move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion', preview, path: 'A', tempDisksFrom: 1, tempDisksTo: 1,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up',
  acceleratedNetworking: { required: false, mayUseMana: true, turnsOn: false }, stops: [] }, extra || {});
// A Windows D2ds_v4 that starts on v6, the Preview; its v5 is D2ds_v5, in place.
const win = (name, options) => ({ vmId: `/subscriptions/${SUB_APPS}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${name}`, name, os: 'Windows',
  sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', gen: 'V2', sourceStage: { stage: 'Extended', basis: 'stated' },
  options: options ?? [opt('v5', false), opt('v6', true), opt('v7', true)], start: { current: 'v6', extended: 'v5' } });
const w1 = win('win-01'), w2 = win('win-02');
// A Windows F2s_v2: F is offered on v7 only.
const f1 = Object.assign(win('app-f1', [opt('v5', false, { supported: false, notSupported: ['series-not-offered'], targetSize: null, path: 'MANUAL' }),
  opt('v7', true, { targetSize: 'Standard_F2as_v7' })]), { sourceSize: 'Standard_F2s_v2', start: { current: 'v7', extended: 'v7' } });
const notRead = (code) => tPreview.set(SUB_APPS, { read: false, registered: false, state: null, name: 'Applications', code });
// A read gives no code; one here proves the box never shows a code once the feature was read.
const off = () => tPreview.set(SUB_APPS, { read: true, registered: false, state: 'NotRegistered', name: 'Applications', code: 'AuthorizationFailed' });

test('THE APPROVED WORDS (2026-11-11)', () => {
  eq(UX.tPvNotRead.one, '1 machine in subscription {sub} moves by the in-place upgrade (Preview). The product cannot read if the preview feature VMTempDiskResizePreview is registered.');
  eq(UX.tPvNotRead.many, '{n} machines in subscription {sub} move by the in-place upgrade (Preview). The product cannot read if the preview feature VMTempDiskResizePreview is registered.');
  eq(UX.tPvCode, 'Error code from Azure: {code}.');
  eq(UX.tPvAuthWhy, 'Azure registers a preview feature for the whole subscription. Azure did not let the product read the feature state.');
  eq(UX.tPvAuthStep, 'Open the Admin page. Under Where the product may work, give Assess on subscription {sub}.');
  eq(UX.tPvCheck, 'Select Check again.');
  eq(UX.tPvOff.one, '1 machine in subscription {sub} moves by the in-place upgrade (Preview). The preview feature VMTempDiskResizePreview is not registered in this subscription.');
  eq(UX.tPvOff.many, '{n} machines in subscription {sub} move by the in-place upgrade (Preview). The preview feature VMTempDiskResizePreview is not registered in this subscription.');
  eq(UX.tPvWho, 'A user with the Contributor or Owner role on the subscription registers it:');
  eq(UX.tPvReg1, 'In the Azure portal, open Subscriptions, then {sub}.');
  eq(UX.tPvReg2, 'Select Preview features. Find VMTempDiskResizePreview and select Register.');
  eq(UX.tPvReg3, 'Wait about 10 minutes, then select Check again.');
  eq(UX.tPvV5, 'To move these machines without the preview feature, choose a v5 target. A v5 size keeps a SCSI temporary disk and needs no preview feature.');
});

test('A1: not read, AuthorizationFailed - the line, the code, why, and the two steps; no resource group sentence', () => {
  resetT(); notRead('AuthorizationFailed');
  const html = fns.tPreviewNoticeHtml([w1, w2]);
  ok(html.includes(esc(fill(UX.tPvNotRead.many, { n: 2, sub: 'Applications' })) + ' ' + esc('Error code from Azure: AuthorizationFailed.')), html);
  ok(html.includes(esc(UX.tPvAuthWhy)), 'why');
  ok(html.includes(`<ol><li>${esc(fill(UX.tPvAuthStep, { sub: 'Applications' }))}</li><li>${esc(UX.tPvCheck)}</li></ol>`), html);
  ok(!/resource groups only/.test(html), 'this page cannot know where the product has access');
  ok(html.includes('t-pwarn'), 'amber: not read is not a yes');
  ok(!/HTTP/.test(html), 'no HTTP status');
});

test('A2: not read, another code - the line, the code, then Select Check again; no steps', () => {
  resetT(); notRead('FeatureNotFound');
  const html = fns.tPreviewNoticeHtml([w1]);
  ok(html.includes(esc(fill(UX.tPvNotRead.one, { n: 1, sub: 'Applications' })) + ' ' + esc('Error code from Azure: FeatureNotFound.')), html);
  ok(html.includes(esc(UX.tPvCheck)) && !html.includes('<ol>') && !html.includes(esc(UX.tPvAuthWhy)), html);
});

test('A with no code: no code sentence, then Select Check again', () => {
  resetT(); notRead('');
  const html = fns.tPreviewNoticeHtml([w1]);
  ok(!html.includes('Error code from Azure'), html);
  ok(html.includes(esc(UX.tPvCheck)) && !html.includes(esc(UX.tPvAuthWhy)), html);
  tPreview.set(SUB_APPS, { read: false, registered: false, state: null, name: 'Applications' });
  ok(!fns.tPreviewNoticeHtml([w1]).includes('Error code from Azure'), 'no code at all');
});

test('B: read, not registered - who registers it, the three steps, and the v5 way', () => {
  resetT(); off();
  const html = fns.tPreviewNoticeHtml([w1, w2]);
  ok(html.includes(esc(fill(UX.tPvOff.many, { n: 2, sub: 'Applications' }))), html);
  ok(html.includes(esc(UX.tPvWho)), 'who');
  ok(html.includes(`<ol><li>${esc(fill(UX.tPvReg1, { sub: 'Applications' }))}</li><li>${esc(UX.tPvReg2)}</li><li>${esc(UX.tPvReg3)}</li></ol>`), html);
  ok(html.includes(esc(UX.tPvV5)), 'the v5 way');
  ok(!html.includes('Error code from Azure') && !html.includes(esc(UX.tPvAuthWhy)), 'no A words');
});

test('B: the v5 way shows only when every machine in the box has a v5 size that moves in place', () => {
  resetT(); off();
  ok(!fns.tPreviewNoticeHtml([w1, f1]).includes(esc(UX.tPvV5)), 'an F machine has no v5 target');
  eq(fns.tPreviewV5Way([f1]), false);
  eq(fns.tPreviewV5Way([w1]), true);
  // A v5 option whose size is a Preview, with an in-place choice that keeps a temporary disk.
  const b = win('web-b01', [opt('v5', true, { targetSize: 'Standard_B2ls_v2', tempDisksTo: 0, sizeChoices: [
    { size: 'Standard_B2ls_v2', preview: true, tempDisksTo: 0 }, { size: 'Standard_D2lds_v5', preview: false, tempDisksTo: 1 }] })]);
  eq(fns.tPreviewV5Way([b]), true, 'the D2lds_v5 choice moves in place');
  const bOnly = win('web-b02', [opt('v5', true, { targetSize: 'Standard_B2ls_v2', tempDisksTo: 0, sizeChoices: [{ size: 'Standard_B2ls_v2', preview: true, tempDisksTo: 0 }] })]);
  eq(fns.tPreviewV5Way([bOnly]), false, 'only a Preview on v5');
  const noTemp = win('win-03', [opt('v5', false, { tempDisksTo: 0 }), opt('v6', true)]);
  eq(fns.tPreviewV5Way([noTemp]), false, 'a v5 size with no temporary disk does not keep a SCSI temporary disk');
  const v5Preview = win('win-04', [opt('v5', true, { tempDisksTo: 1 }), opt('v6', true)]);
  eq(fns.tPreviewV5Way([v5Preview]), false, 'a v5 size that is itself a Preview needs the feature');
});

test('REGISTERED and READING say no step', () => {
  resetT();
  tPreview.set(SUB_APPS, { read: true, registered: true, state: 'Registered', name: 'Applications', code: '' });
  let html = fns.tPreviewNoticeHtml([w1]);
  ok(html.includes(esc(fill(UX.tPreviewOn.one, { n: 1, sub: 'Applications' }))) && !html.includes('t-pmore') && !html.includes('t-pwarn'), html);
  tPreview.set(SUB_APPS, { loading: true, read: false, code: 'AuthorizationFailed' });
  html = fns.tPreviewNoticeHtml([w1]);
  ok(html.includes(esc(fill(UX.tPreviewReading, { sub: SUB_APPS }))) && !html.includes('t-pmore'), html);
});

test('a code from the service is escaped like every word of the box', () => {
  resetT(); notRead('<b>x</b>');
  const html = fns.tPreviewNoticeHtml([w1]);
  ok(!html.includes('<b>x</b>') && html.includes('&lt;b&gt;x&lt;/b&gt;'), html);
});

test('RUN: tPreviewLoad keeps the code the service gives, and no HTTP status', async () => {
  resetT();
  globalThis.api = async () => ({ read: false, registered: false, state: null, subscriptionName: 'Applications', httpStatus: 403, errorCode: 'AuthorizationFailed' });
  globalThis.render = () => {}; globalThis.STEP = { migrate: { targets: 't' } }; globalThis.step = 't';
  const { tPreviewLoad } = liftAll('wizard.html', ['tPreviewLoad', 'previewOffered', 'subOf']);
  await tPreviewLoad([w1]);
  const p = tPreview.get(SUB_APPS);
  eq([p.read, p.registered, p.code, 'status' in p], [false, false, 'AuthorizationFailed', false]);
  globalThis.api = async () => { throw new Error('500'); };
  await tPreviewLoad([w1], SUB_APPS);
  const q = tPreview.get(SUB_APPS);
  eq([q.read, q.code], [false, ''], 'the page could not reach the service: no code');
});

test('THE HELP keeps what the feature is, that the product does not register it, and to keep it - not the portal steps, no role sentence', () => {
  for (const k of ['tPreviewPortal', 'tPreviewWait', 'tPreviewRole', 'tPreviewAnswer', 'tPreviewOff', 'tPreviewNotRead', 'tPreviewThen']) eq(UX[k], undefined, k);
  resetT(); off(); tHelp.add('preview-sub-0');
  const html = fns.tPreviewNoticeHtml([w1]);
  const help = html.slice(html.indexOf('t-phelp'));
  for (const k of ['tPreviewWhat', 'tPreviewNotTool', 'tPreviewKeep']) ok(help.includes(esc(UX[k])), k);
  ok(!help.includes('Preview features') && !/must be on the subscription|covers this read/.test(WIZ), help);
});

run('preview-rg-scope');
