/* REBUILD-REMOVE-PLAN-1 review: the wave editor named the machines of a wave
 * that take the in-place upgrade (Preview), and said nothing when their
 * subscription did not have the preview feature VMTempDiskResizePreview. It
 * now draws the notice of the targets step, for each subscription: the count,
 * what to do, a ? helper with the steps in the Azure portal (Escape closes it,
 * rule 11), and Check again. No command to run elsewhere (rule 12).
 *
 * RUN: help.js previewNeeds, and the page's own previewLine.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WAVES = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
const help = liftAll('help.js', ['previewNames', 'subscriptionOf', 'previewNeeds']);
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, help);
globalThis.UX = liftConst('waves.html', 'UX');
globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.vmName = (id) => String(id).split('/').pop();
const page = liftAll('waves.html', ['previewLine', 'previewNoticeHtml']);

const A = '00000000-0000-0000-0000-000000000000', B = '11111111-2222-3333-4444-555555555555';
const vm = (sub, n, method = 'preview') => ({ vmId: `/subscriptions/${sub}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${n}`, wave: 'w1', path: 'A', target: { choice: { method } } });
const members = [vm(A, 'a1'), vm(A, 'a2'), vm(B, 'b1'), vm(A, 'plain', 'in-place')];
const reset = (map) => { globalThis.wPreview = new Map(Object.entries(map)); globalThis.wPreviewHelp = new Set(); };

test('previewNeeds: one group per subscription not registered, only Preview machines, not read is not a yes', () => {
  const read = { [A]: { read: true, registered: false }, [B]: { read: true, registered: true } };
  const got = help.previewNeeds(members, vmName, (s) => read[s] ?? null);
  eq(JSON.stringify(got.map(g => [g.sub, g.names])), JSON.stringify([[A, ['a1', 'a2']]]));
  eq(help.previewNeeds(members, vmName, () => null).length, 2, 'not read yet is not registered');
  eq(help.previewNeeds(members, vmName, () => ({ read: false, registered: false })).length, 2, 'a failed read is not a yes');
  eq(help.subscriptionOf(members[0].vmId), A);
});

test('the wave card: the names line, then a notice for the subscription without the feature, with what to do and Check again', () => {
  reset({ [A]: { read: true, registered: false, name: 'Applications' }, [B]: { read: true, registered: true } });
  const html = page.previewLine(members);
  ok(html.includes(esc(UX.previewOffMany.replace('{n}', '2').replace('{sub}', 'Applications'))), html);
  ok(html.includes(esc(UX.previewThen)), 'what to do');
  ok(html.includes(`data-wpcheck="${A}"`) && html.includes(UX.previewCheck), 'Check again');
  eq((html.match(/wpwarn/g) ?? []).length, 1, 'the registered subscription has none');
  ok(!html.includes('class="muted wphelp"'), 'the helper is closed until clicked');
});

test('the ? helper opens with the steps in the Azure portal, turns into Close, and holds no command (rules 11 and 12)', () => {
  reset({ [A]: { read: true, registered: false, name: 'Applications' } });
  globalThis.wPreviewHelp.add(`w1|${A}`);
  const html = page.previewLine([vm(A, 'a1')]);
  ok(html.includes(esc(UX.previewPortal)) && html.includes(esc(UX.previewWait)), html);
  ok(/aria-expanded="true"[^>]*>Close</.test(html.replace(/\s+/g, ' ')), 'Close');
  ok(!/az feature|Register-Az|t-copy|<pre/.test(html), 'no command');
  ok(WAVES.includes('pv?.clear();'), 'Escape closes it');
});

test('not read and being read say so; registered everywhere draws no notice', () => {
  reset({ [A]: { read: false, registered: false } });
  ok(page.previewLine([vm(A, 'a1')]).includes(esc(UX.previewNotRead.replace('{sub}', A))));
  reset({ [A]: { loading: true } });
  ok(page.previewLine([vm(A, 'a1')]).includes(esc(UX.previewReading.replace('{sub}', A))));
  reset({ [A]: { read: true, registered: true } });
  ok(!page.previewLine([vm(A, 'a1')]).includes('wpwarn'));
});

test('the page reads the feature with a GET and never registers it', () => {
  ok(WAVES.includes('apiGet(`preview-feature?subscriptionId=${encodeURIComponent(s)}`)'));
  ok(!/apiPost\([^)]*(feature|register)/i.test(WAVES));
  ok(WAVES.includes("document.querySelectorAll('[data-wpcheck]')"), 'Check again is wired');
});

test('RUN: Escape closes the ? helper of a preview notice (rule 11)', () => {
  const { onEscape } = liftAll('waves.html', ['onEscape']);
  let drawn = 0;
  Object.assign(globalThis, { change: { vmId: null }, ownHelp: new Set(), idHelp: new Set(), render: () => { drawn++; }, clearResets: () => {} });
  globalThis.wPreviewHelp = new Set([`w1|${A}`]);
  onEscape({ key: 'Escape' });
  eq(globalThis.wPreviewHelp.size, 0);
  eq(drawn, 1, 'drawn again, closed');
});

run('wave-preview-notice');