/* ADVISE-AN-1: the Choose each target step shows, at the choice, that the size
 * a machine goes to turns off the accelerated networking it uses today - and
 * why, behind a (?).
 *
 * The engine decides it (Get-VmfAnKeptOn) and records it on each option and
 * each size choice: acceleratedNetworking.keptOn and keptOnWhy. The page reads
 * those facts; it never works them out again from a size name or a release.
 *
 * Three marks from one rule (anLost: keptOn is false), as TEMPDISK-UX-1 has for
 * the temporary disk: a tag under the chosen size, the one amber dot on Details
 * until they are opened, and a notice above the tables. The Details row of
 * accelerated networking is marked and says Off; an answer that is not known
 * says Unknown, never On. The other options say which one turns it off.
 *
 * RUN, not read: the page's own functions, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const hasLine = (code) => WIZ.split(/\r?\n/).some(l => l.trimStart().startsWith(code));
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
globalThis.reasonText = (code) => String(code);

const F = liftAll('wizard.html', ['anKept', 'anLost', 'anToCheck', 'anNoticeHtml', 'anReleaseText', 'anHelpText',
  'advSummary', 'anRuleHtml', 'advGroups', 'tDefSeries', 'advWhy',
  'tempLost', 'tempToCheck', 'tempNoticeHtml', 'tDotWhy', 'tMarkSeen', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText',
  'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);

const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tSelected = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set();
  globalThis.tASeen = new Set();
  globalThis.targetAdvice = { machines: [] };
};

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/';
const an = (mayUseMana, keptOn, keptOnWhy, required) => ({ required: required ?? false, mayUseMana, turnsOn: false, keptOn, keptOnWhy });
const option = (opt, targetSize, anFacts, extra) => Object.assign({ option: opt, supported: true, notSupported: [], targetSize,
  move: opt === 'v5' ? 'scsi-resize' : 'nvme-conversion', path: 'A', rebuild: false, tempDisksFrom: 0, tempDisksTo: 0,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up', acceleratedNetworking: anFacts, stops: [], premiumDisks: true,
  sizeChoices: [] }, extra || {});
const release = (distroId, version, source, mana) => ({ distroId, version, source, mana });
const machine = (name, os, sourceSize, options, start, rel) => ({ vmId: SUB + name, name, os, gen: 'V2', location: 'centralus', sourceSize,
  diskController: 'SCSI', acceleratedNicCount: 1, linuxRelease: rel === undefined ? null : rel,
  sourceStage: { stage: 'Extended', basis: 'stated' }, options, start: start || { current: 'v6', extended: 'v5' } });

// Ubuntu 18.04 on Intel D2s_v4: v6 turns it off, Intel v5 depends on the host.
const intel = machine('api-03', 'Linux', 'Standard_D2s_v4', [
  option('v5', 'Standard_D2s_v5', an(true, null, 'host', true)),
  option('v6', 'Standard_D2s_v6', an(true, false, 'unlisted'))], { current: 'v6', extended: 'v5' },
  release('ubuntu', '18.04', 'image', 'unlisted'));
// Ubuntu 18.04 on AMD D2as_v4: the engine started it on AMD v5, which keeps it.
// DRIFT-11-OTHER-OPTIONS-1: v6 is not offered to it (every v6 size requires
// accelerated networking), so the size that turns it off is AMD v7.
const amd = machine('api-a04', 'Linux', 'Standard_D2as_v4', [
  option('v5', 'Standard_D2as_v5', an(false, true, null)),
  option('v7', 'Standard_D2as_v7', an(true, false, 'unlisted'))], { current: 'v5', extended: 'v5' },
  release('ubuntu', '18.04', 'agent', 'unlisted'));
// Ubuntu 22.04: v6 keeps it.
const listed = machine('app-01', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, true, null))], null,
  release('ubuntu', '22.04', 'image', 'listed'));
// A Linux release nobody could read: unknown.
const unread = machine('unk-01', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, null, 'release-unknown'))], null,
  release(null, null, null, 'unknown'));
// Windows: kept.
const win = machine('web-07', 'Windows', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, true, null))]);
// Advice from before ADVISE-AN-1 has no keptOn: no mark, and the old reading.
const old = machine('old-01', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', { required: false, mayUseMana: true, turnsOn: false })]);

test('RUN: the size a machine goes to turns accelerated networking off only where the engine says false', () => {
  ok(F.anLost(intel, 'v6', new Map()), 'Ubuntu 18.04 on v6');
  ok(F.anLost(amd, 'v7', new Map()), 'and on AMD v7');
  ok(!F.anLost(amd, 'v5', new Map()), 'AMD v5 keeps it');
  ok(!F.anLost(intel, 'v5', new Map()), 'Intel v5 is unknown, never a loss');
  ok(!F.anLost(unread, 'v6', new Map()), 'unknown release: no loss');
  ok(!F.anLost(win, 'v6', new Map()), 'Windows keeps it');
  ok(!F.anLost(old, 'v6', new Map()), 'an older document says nothing');
  ok(!F.anLost(intel, null, new Map()), 'no target');
});

test('RUN: a size choice answers for itself', () => {
  const shape = machine('ds2-01', 'Linux', 'Standard_DS2_v2', [option('v5', 'Standard_D2s_v5', an(true, null, 'host'), {
    sizeChoices: [
      { size: 'Standard_D2s_v5', family: 'D', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 8, best: true, acceleratedNetworking: an(true, null, 'host') },
      { size: 'Standard_E2s_v5', family: 'E', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 16, best: false, acceleratedNetworking: an(true, false, 'unlisted') }] })]);
  ok(!F.anLost(shape, 'v5', new Map()), 'the best choice');
  ok(F.anLost(shape, 'v5', new Map([[shape.vmId, 'Standard_E2s_v5']])), 'the other choice, by its own facts');
  eq(F.anKept(shape, 'v5', new Map([[shape.vmId, 'Standard_E2s_v5']])).keptOnWhy, 'unlisted');
});

const dotted = (html) => /class="btn small ghost t-det t-kdot"/.test(html);
const tagged = (html) => html.includes(`<span class="pill warn">${esc(UX.tAnTag)}</span>`);

test('RUN: the row of a machine that loses it has the tag and the dot, with words for a screen reader', () => {
  reset(); globalThis.targetAdvice = { machines: [intel, amd] };
  globalThis.tKSeen = new Set([intel.vmId, amd.vmId]);   // the network driver dot is not this test
  const html = F.tTargetRow(intel);
  ok(tagged(html), 'the tag under the chosen size');
  ok(dotted(html), 'the dot on Details');
  ok(html.includes(`title="${esc(UX.tAnCheck)}" aria-label="${esc(UX.tDetails)}: ${esc(UX.tAnCheck)}"`), html.match(/<button[^>]*t-det[^>]*>/)[0]);
  const kept = F.tTargetRow(amd);
  ok(!tagged(kept) && !dotted(kept), 'AMD v5 picked: no tag, no dot');
  globalThis.tOverrides = new Map([[amd.vmId, 'v7']]);
  ok(tagged(F.tTargetRow(amd)), 'a person picks v7 for it: the tag');
});

test('RUN: one dot for every reason, and the label names each', () => {
  eq(F.tDotWhy(true, true, true), `${UX.tKernelCheck}. ${UX.tTempCheck}. ${UX.tAnCheck}`);
  eq(F.tDotWhy(false, false, true), UX.tAnCheck);
  eq(F.tDotWhy(true, false), UX.tKernelCheck, 'the two-reason call still works');
});

test('RUN: opening Details clears the dot - the tag, the marked row and its (?) stay', () => {
  reset(); globalThis.targetAdvice = { machines: [intel] };
  globalThis.tKSeen = new Set([intel.vmId]);
  globalThis.tOpen.add(intel.vmId);
  F.tMarkSeen([intel]);
  ok(globalThis.tASeen.has(intel.vmId), 'seen once its open Details show the loss');
  const html = F.tTargetRow(intel);
  ok(!dotted(html), 'no dot');
  ok(tagged(html), 'the tag stays');
  const row = html.match(/<tr class="t-trow">([\s\S]*?)<\/tr>/);
  ok(row, 'the accelerated networking row is marked');
  ok(row[1].includes(esc(UX.dAn)) && row[1].includes(`${esc(UX.vOn)}  →  ${esc(UX.vOff)}`), row && row[1]);
  ok(row[1].includes('data-help="an-keep-0"'), 'its (?) is on the row');
});

test('RUN: the (?) says why, with the release and where it was read', () => {
  eq(F.anReleaseText(intel), 'Ubuntu 18.04');
  eq(F.anReleaseText(machine('r', 'Linux', 'x', [], null, release('rhel', '8.10', 'image', 'unlisted'))), 'Red Hat Enterprise Linux 8.10');
  eq(F.anReleaseText(machine('r', 'Linux', 'x', [], null, release('contosolinux', '1', 'agent', 'unlisted'))), 'contosolinux 1', 'a name with no words of its own is shown as it is');
  const off = F.anHelpText(intel, 'unlisted');
  ok(off.startsWith(fill(UX.tAnKeepHelp.unlisted, { release: 'Ubuntu 18.04' })), off);
  ok(off.endsWith(UX.tAnFrom.image), 'and that it came from the image');
  ok(F.anHelpText(amd, 'unlisted').endsWith(UX.tAnFrom.agent), 'or from the VM agent');
  eq(F.anHelpText(unread, 'release-unknown'), UX.tAnKeepHelp['release-unknown'], 'no release: nothing to say where it came from');
  reset(); globalThis.targetAdvice = { machines: [intel] };
  globalThis.tKSeen = new Set([intel.vmId]);
  globalThis.tOpen.add(intel.vmId); globalThis.tHelp.add('an-keep-0');
  const html = F.tTargetRow(intel);
  ok(html.includes(`id="t-help-an-keep-0"><p>${esc(off)}</p>`), 'the text shows when the (?) is open');
  ok(html.includes(F.anRuleHtml()), 'and the rule, as a table (2026-10-12)');
  ok(html.includes(`aria-label="${esc(UX.tClose)}"`), 'and the (?) becomes Close');
});

test('RUN: Details say Off, Unknown or the old reading, from the facts', () => {
  const anRow = (m, opt) => F.advDetailRows(m, opt, undefined).find(r => r[0] === UX.dAn)[1];
  eq(anRow(intel, 'v6'), `${UX.vOn}  →  ${UX.vOff}`);
  eq(anRow(intel, 'v5'), `${UX.vOn}  →  ${UX.vUnknown}`, 'Intel v5: the host decides, even where Microsoft requires it');
  // Since 2026-10-12: nothing unknown - the screen says what to do.
  eq(anRow(unread, 'v6'), `${UX.vOn}  →  ${UX.vStartAssess}`);
  eq(anRow(amd, 'v5'), `${UX.vOn}  →  ${UX.vOn}`);
  eq(anRow(win, 'v6'), `${UX.vOn}  →  ${UX.vOn}`);
  eq(anRow(old, 'v6'), `${UX.vOn}  →  ${UX.vOn}`, 'an older document: as before');
});

test('RUN: the other options say which one turns it off, and the (?) on their heading says why', () => {
  reset(); globalThis.targetAdvice = { machines: [amd] };
  globalThis.tOpen.add(amd.vmId);
  const html = F.tTargetRow(amd);
  ok(html.includes(esc(fill(UX.tAvailableAnOff, { size: 'D2as_v7' }))), 'v7 is listed, marked off');
  ok(html.includes('data-help="an-0"'), 'the (?) on Other options');
  globalThis.tHelp.add('an-0');
  ok(F.tTargetRow(amd).includes(esc(F.anHelpText(amd, 'unlisted'))), 'it explains the release');
  reset(); globalThis.targetAdvice = { machines: [listed] };
  globalThis.tOpen.add(listed.vmId);
  ok(!F.tTargetRow(listed).includes('data-help="an-'), 'nothing turned off: no (?)');
});

test('RUN: the notice shows while a machine still has a dot, names no machine, and goes when none has', () => {
  reset();
  const all = [intel, amd, listed, unread, win, old];
  const check = () => F.anToCheck(all, 'current', new Map(), new Map(), globalThis.tASeen);
  eq(check().map(m => m.name), ['api-03']);
  const html = F.anNoticeHtml(check());
  ok(html.includes(`<span class="t-kdotx" aria-hidden="true"></span>${esc(UX.tAnAlert)}`), html);
  ok(html.includes('class="t-kwarn t-awarn"'), 'the look of the other notices');
  ok(!/api-03|api-a04|app-01/.test(html), 'no machine named');
  globalThis.tASeen.add(intel.vmId);
  eq(F.anNoticeHtml(check()), '', 'none to check: no notice');
  eq(F.anToCheck([amd], 'current', new Map([[amd.vmId, 'v7']]), new Map(), new Set()).length, 1, 'a person picks v7: to check');
});

test('the step draws the notice, keeps what was seen per options version, and marks what open Details show', () => {
  ok(hasLine('${anNoticeHtml(anToCheck(machines, tDefault, tOverrides, tSizes, tASeen))}'), 'renderTargets draws it');
  ok(/tKernelSel = new Map\(\); tKSeen = new Set\(\); tTSeen = new Set\(\); tASeen = new Set\(\);/.test(WIZ), 'new options start with every dot');
  ok(hasLine('if (tOpen.has(m.vmId) && anLost(m, advPick(m, tDefault, tOverrides), tSizes)) tASeen.add(m.vmId);'), 'tMarkSeen marks it');
  ok(hasLine('let tASeen = new Set();'), 'declared once');
});

test('every word is declared, and the demo shows both machines', () => {
  for (const k of ['tAnAlert', 'tAnCheck', 'tAnTag', 'tAvailableAnOff', 'tAnKeepAbout']) ok(typeof UX[k] === 'string' && UX[k], k);
  for (const k of ['unlisted', 'host', 'release-unknown', 'size-unreadable']) ok(UX.tAnKeepHelp[k], k);
  for (const k of ['agent', 'image']) ok(UX.tAnFrom[k], k);
  ok(WIZ.includes('"name":"api-03"') && WIZ.includes('"name":"api-a04"'), 'the targets sample has an Intel and an AMD Ubuntu 18.04 machine');
});

// REBUILD-REMOVE-PLAN-1: OWNER-QUESTIONS-1 row 33's machine that waited for a choice
// (the engine's decide) is gone: no machine waits for one. Its tests were here.
test('RUN: a release only the image gives marks the size, never turns it Off (review finding 1)', () => {
  const img = machine('api-05', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, null, 'image-unlisted'))], null,
    release('ubuntu', '18.04', 'image', 'unlisted'));
  reset(); globalThis.targetAdvice = { machines: [img] };
  ok(!F.anLost(img, 'v6', new Map()), 'no loss');
  const html = F.tTargetRow(img);
  // Since 2026-10-12: the tag says what to do.
  ok(html.includes(`<span class="pill warn">${esc(UX.vStartAssess)}</span>`) && !html.includes(esc(UX.tAnTag) + '<'), 'the action, never off');
  eq(F.advDetailRows(img, 'v6', undefined).find(r => r[0] === UX.dAn)[1], `${UX.vOn}  →  ${UX.vStartAssess}`);
  ok(F.anHelpText(img, 'image-unlisted').includes('Ubuntu 18.04'), 'the (?) names the image release');
  for (const k of ['image-unlisted']) ok(UX.tAnKeepHelp[k], k);
});
// Rule since 2026-10-12: the screen never offers what is not possible. Where
// the VM agent reports a release Microsoft does not list for MANA, no kernel
// update gives it MANA, so Update the kernel is not offered - no section, no
// dot, no notice, and the All buttons pass it by. An image release or an
// unknown one keeps today's behaviour.
test('RUN: no Update the kernel where the agent reports a release Microsoft does not list', () => {
  globalThis.kernelOffered = F.kernelOffered;
  const k = liftAll('wizard.html', ['kernelOffered', 'kernelOf', 'kernelToCheck', 'kernelSetAll', 'setKernelChoice', 'advPick', 'sizeOf']);
  const agent = machine('k-agent', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, false, 'unlisted'))], null, release('ubuntu', '18.04', 'agent', 'unlisted'));
  const image = machine('k-image', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, null, 'image-unlisted'))], null, release('ubuntu', '18.04', 'image', 'unlisted'));
  const listedM = machine('k-listed', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, true, null))], null, release('ubuntu', '22.04', 'agent', 'listed'));
  const unknown = machine('k-unknown', 'Linux', 'Standard_D2s_v4', [option('v6', 'Standard_D2s_v6', an(true, null, 'release-unknown'))], null, release(null, null, null, 'unknown'));
  ok(!k.kernelOffered(agent, 'v6', new Map()), 'not offered: it cannot work');
  ok(k.kernelOffered(image, 'v6', new Map()) && k.kernelOffered(listedM, 'v6', new Map()) && k.kernelOffered(unknown, 'v6', new Map()), 'offered as before elsewhere');
  const toCheck = k.kernelToCheck([agent, image, listedM, unknown], 'current', new Map(), new Map(), new Map(), new Set());
  eq(toCheck.map(m => m.name), ['k-image', 'k-listed', 'k-unknown'], 'nothing asks for a choice that cannot be made');
  const kernels = new Map(); const seen = new Set();
  k.kernelSetAll(toCheck, 'update', kernels, seen);
  ok(!kernels.has(agent.vmId), 'the All button passes it by');
  eq(k.kernelOf(agent, 'v6', new Map(), new Map([[agent.vmId, 'update']]), 'update'), '', 'and an old choice for it counts for nothing');
  reset(); globalThis.targetAdvice = { machines: [agent] }; globalThis.tOpen.add(agent.vmId);
  const html = F.tTargetRow(agent);
  ok(!html.includes('t-ksec') && !html.includes(UX.tKernelCheck), 'no section and no dot');
});
run('an-keep-choice');
