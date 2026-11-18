/* TEMPDISK-UX-1: the Choose each target step shows, at the choice, that the
 * size a machine goes to has no temporary disk while the machine has one now.
 * Before this, the loss was in a Details row only, and the Run it step was the
 * first place that said so - after the plan was built.
 *
 * Three marks, from one rule (tempLost): a tag under the chosen size, an amber
 * dot on Details until they are opened (the kernel dot of KERNEL-UX-1, shared),
 * and a notice above the tables while any machine still has a dot. The Details
 * row of the temporary disk is marked too.
 *
 * The rule reads the facts the engine recorded from Azure's catalog - the
 * machine's temporary disks now (tempDisksFrom, the scan's sourceTempDisks)
 * and those of the size it goes to (tempDisksTo) - never the size name: B v1,
 * Dv2, Dv3 and Dav4 sizes have no d in their names and have a temporary disk.
 * Unknown on either side is no loss: a mark says what is known.
 *
 * RUN, not read: the page's own functions, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// SQL-TEMPDB-SIGNOFF-1: tTargetRow asks tSqlFound, which reads the page's
// assessment. None was read here, so no machine has the SQL Server finding.
globalThis.assessment = null;
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });
globalThis.tLinksOf = () => ({ extensions: [], sqlVirtualMachine: false, dataCollectionRuleAssociations: [] });

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
// A line of code, not a comment (CLAUDE.md, "a test that reads a whole file
// matches its own comments") - as kernel-choice.test.js reads the page.
const hasLine = (code) => WIZ.split(/\r?\n/).some(l => l.trimStart().startsWith(code));
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
globalThis.reasonText = (code) => String(code);

const F = liftAll('wizard.html', ['tempLost', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed', 'tempToCheck', 'tempNoticeHtml', 'tDotWhy', 'tMarkSeen', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'tAreasHtml',
  'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);

const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tSelected = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set(); globalThis.tASeen = new Set();
  globalThis.targetAdvice = { machines: [] };
};

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/';
const an = (mayUseMana) => ({ required: false, mayUseMana, turnsOn: false });
const choice = (size, family, best, temp, extra) => Object.assign({ size, family, variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 4, best,
  path: 'A', rebuild: false, tempDisksTo: temp, sizeUnverified: false, acceleratedNetworking: an(true), stops: [], premiumDisks: true,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up' }, extra || {});
const option = (opt, targetSize, from, to, choices, extra) => Object.assign({ option: opt, supported: true, notSupported: [], targetSize,
  move: opt === 'v5' ? 'scsi-resize' : 'nvme-conversion', path: 'A', rebuild: false, tempDisksFrom: from, tempDisksTo: to,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up', acceleratedNetworking: an(true), stops: [], premiumDisks: true,
  sizeChoices: choices || [] }, extra || {});
const machine = (name, os, sourceSize, gen, options, start) => ({ vmId: SUB + name, name, os, gen, location: 'centralus', sourceSize,
  diskController: 'SCSI', acceleratedNicCount: 0, sourceStage: { stage: 'End of Life', basis: 'stated' }, options,
  start: start || { current: 'v6', extended: 'v5' } });

// Windows on B2s (a temporary disk, no d in the name): Bsv2 has none, a Dl v5
// size has one, v6 keeps one.
const winB = machine('web-b01', 'Windows', 'Standard_B2s', 'V2', [
  option('v5', 'Standard_B2ls_v2', 1, 0, [choice('Standard_B2ls_v2', 'Bsv2', true, 0, { path: 'B', rebuild: true }),
    choice('Standard_D2lds_v5', 'Dl', false, 1)], { path: 'B', rebuild: true }),
  option('v6', 'Standard_D2lds_v6', 1, 1, [], { path: 'B', rebuild: true })], { current: 'v5', extended: 'v5' });
// Linux on DS2_v2 (a temporary disk, not a B size): every v5 size offered has none.
const ds2 = machine('ds2-01', 'Linux', 'Standard_DS2_v2', 'V1', [
  option('v5', 'Standard_D2s_v5', 1, 0, [choice('Standard_D2s_v5', 'D', true, 0), choice('Standard_E2s_v5', 'E', false, 0)])],
  { current: 'v5', extended: 'v5' });
// Linux on D2ds_v4: keeps its temporary disk on v5; v6 cannot be read.
const keep = machine('app-01', 'Linux', 'Standard_D2ds_v4', 'V2', [
  option('v5', 'Standard_D2ds_v5', 1, 1), option('v6', 'Standard_D2ds_v6', 1, null)]);
// Linux on D2s_v4: has no temporary disk to lose.
const none = machine('db-01', 'Linux', 'Standard_D2s_v4', 'V2', [option('v6', 'Standard_D2s_v6', 0, 0)]);
// The scan could not read the temporary disk of the size now.
const unread = machine('unk-01', 'Windows', 'Standard_D2s_v4', 'V2', [option('v6', 'Standard_D2s_v6', null, 0)]);

test('RUN: a size with no temporary disk, on a machine that has one now, is a loss', () => {
  ok(F.tempLost(winB, 'v5', new Map()), 'B2s to B2ls_v2: Bsv2 has no temporary disk');
  ok(F.tempLost(ds2, 'v5', new Map()), 'DS2_v2 to D2s_v5: not a B size, and no d in the name of either');
  ok(F.tempLost(ds2, 'v5', new Map([[ds2.vmId, 'Standard_E2s_v5']])), 'the other size of the option, the same');
});

test('RUN: a size with a temporary disk, or a machine with none now, is no loss', () => {
  ok(!F.tempLost(winB, 'v6', new Map()), 'v6 D2lds_v6 has one');
  ok(!F.tempLost(winB, 'v5', new Map([[winB.vmId, 'Standard_D2lds_v5']])), 'the Dl size chosen in place of Bsv2 has one');
  ok(!F.tempLost(keep, 'v5', new Map()), 'D2ds_v4 to D2ds_v5 keeps it');
  ok(!F.tempLost(none, 'v6', new Map()), 'nothing to lose');
  ok(!F.tempLost(winB, null, new Map()), 'no target');
  ok(!F.tempLost(winB, 'v7', new Map()), 'an option the machine does not have');
});

test('RUN: unknown on either side is no loss', () => {
  ok(!F.tempLost(keep, 'v6', new Map()), 'the size it goes to cannot be read');
  ok(!F.tempLost(unread, 'v6', new Map()), 'the size it is on cannot be read');
  const missing = machine('old-01', 'Linux', 'Standard_D2s_v3', 'V2', [{ option: 'v6', supported: true, targetSize: 'Standard_D2s_v6', sizeChoices: [] }]);
  ok(!F.tempLost(missing, 'v6', new Map()), 'advice with no temporary disk fields');
});

test('RUN: the facts decide, never the size name', () => {
  // A size whose name has no d, and that the catalog says has a temporary disk.
  const odd = machine('odd-01', 'Linux', 'Standard_D2as_v4', 'V2', [option('v6', 'Standard_D2as_v6', 1, 1)]);
  ok(!F.tempLost(odd, 'v6', new Map()), 'the catalog says one: no loss, whatever the name');
  // A size whose name has a d, and that the catalog says has none.
  const odd2 = machine('odd-02', 'Linux', 'Standard_D2ds_v4', 'V2', [option('v6', 'Standard_D2ds_v6', 1, 0)]);
  ok(F.tempLost(odd2, 'v6', new Map()), 'the catalog says none: a loss, whatever the name');
  // The chosen size's own fact wins over the option's.
  const mixed = machine('mix-01', 'Linux', 'Standard_D4s_v3', 'V2', [option('v6', 'Standard_D4ds_v6', 1, 1,
    [choice('Standard_D4ds_v6', 'D', true, 1), choice('Standard_D4s_v6', 'D', false, 0)])]);
  ok(!F.tempLost(mixed, 'v6', new Map()), 'the d size, first');
  ok(F.tempLost(mixed, 'v6', new Map([[mixed.vmId, 'Standard_D4s_v6']])), 'the size without one, chosen');
});

const dotted = (html) => /class="btn small ghost t-det t-kdot"/.test(html);
const tagged = (html) => html.includes(`<span class="pill warn">${esc(UX.tTempTag)}</span>`);

test('RUN: the row of a machine that loses its temporary disk has the tag and the dot, with words for a screen reader', () => {
  reset(); globalThis.targetAdvice = { machines: [winB, keep] };
  const html = F.tTargetRow(winB);
  ok(tagged(html), 'the tag under the chosen size');
  ok(dotted(html), 'the dot on Details');
  ok(html.includes(`title="${esc(UX.tTempCheck)}" aria-label="${esc(UX.tDetails)}: ${esc(UX.tTempCheck)}"`), 'the tooltip and the label');
  // app-01 is Linux on v6, so it has the network driver dot - and no other.
  const plain = F.tTargetRow(keep);
  ok(!tagged(plain) && !plain.includes(UX.tTempCheck), 'a machine that keeps its temporary disk: no tag, no temporary disk on the dot');
  ok(plain.includes(`aria-label="${esc(UX.tDetails)}: ${esc(UX.tKernelCheck)}"`), 'its dot names the network driver only');
  globalThis.tSizes = new Map([[winB.vmId, 'Standard_D2lds_v5']]);
  const dl = F.tTargetRow(winB);
  ok(!tagged(dl) && !dotted(dl), 'the Dl size chosen: neither');
});

test('RUN: one dot when both apply, and the label names both', () => {
  reset(); globalThis.targetAdvice = { machines: [ds2] };
  const html = F.tTargetRow(ds2);
  eq((html.match(/t-kdot/g) || []).length, 1, 'one dot');
  const both = `${UX.tKernelCheck}. ${UX.tTempCheck}`;
  ok(html.includes(`title="${esc(both)}" aria-label="${esc(UX.tDetails)}: ${esc(both)}"`), html.match(/<button[^>]*t-det[^>]*>/)[0]);
  eq(F.tDotWhy(true, false), UX.tKernelCheck);
  eq(F.tDotWhy(false, true), UX.tTempCheck);
  eq(F.tDotWhy(false, false), '');
  globalThis.tKSeen.add(ds2.vmId);
  ok(F.tTargetRow(ds2).includes(`aria-label="${esc(UX.tDetails)}: ${esc(UX.tTempCheck)}"`), 'the kernel checked: the temporary disk still to check');
});

test('RUN: opening Details clears the dot - the tag and the marked row stay', () => {
  reset(); globalThis.targetAdvice = { machines: [winB] };
  globalThis.tOpen.add(winB.vmId);
  F.tMarkSeen([winB]);
  ok(globalThis.tTSeen.has(winB.vmId), 'seen once its open Details show the loss');
  const html = F.tTargetRow(winB);
  ok(!dotted(html), 'no dot');
  ok(!/aria-label="[^"]*: /.test(html.match(/<button[^>]*t-det[^>]*>/)[0]), 'and no label for one');
  ok(tagged(html), 'the tag stays');
  const row = html.match(/<tr class="t-trow">([\s\S]*?)<\/tr>/);
  ok(row, 'the temporary disk row is marked');
  ok(row[1].includes(`<span class="t-kdotx" aria-hidden="true"></span>${esc(UX.dTemp)}`), row && row[1]);
  eq((html.match(/class="t-trow"/g) || []).length, 1, 'that row only');
});

test('RUN: Details opened on a size that keeps the temporary disk are not a check of the loss', () => {
  reset(); globalThis.targetAdvice = { machines: [winB] };
  globalThis.tOverrides = new Map([[winB.vmId, 'v6']]);
  globalThis.tOpen.add(winB.vmId);
  F.tMarkSeen([winB]);
  ok(!globalThis.tTSeen.has(winB.vmId), 'v6 keeps it: not seen');
  ok(!F.tTargetRow(winB).includes('class="t-trow"'), 'and no marked row');
  globalThis.tOverrides = new Map(); globalThis.tOpen = new Set();
  ok(dotted(F.tTargetRow(winB)), 'back on Bsv2 with Details closed: the dot');
});

test('RUN: the notice shows while a machine still has a dot, names no machine, and goes when none has', () => {
  reset();
  const all = [winB, ds2, keep, none, unread];
  const check = () => F.tempToCheck(all, 'current', new Map(), new Map(), globalThis.tTSeen);
  eq(check().map(m => m.name), ['web-b01', 'ds2-01']);
  const html = F.tempNoticeHtml(check());
  ok(html.includes(`<span class="t-kdotx" aria-hidden="true"></span>${esc(UX.tTempAlert)}`), html);
  ok(html.includes('class="t-kwarn t-twarn"'), 'the look of the network driver notice');
  ok(!/web-b01|ds2-01|app-01|db-01|unk-01/.test(html), 'no machine named');
  globalThis.tTSeen.add(winB.vmId);
  eq(check().map(m => m.name), ['ds2-01'], 'one opened, one still to check');
  ok(F.tempNoticeHtml(check()).includes(esc(UX.tTempAlert)), 'the notice stays');
  globalThis.tTSeen.add(ds2.vmId);
  eq(F.tempNoticeHtml(check()), '', 'none to check: no notice');
  eq(F.tempNoticeHtml(F.tempToCheck([keep, none, unread], 'current', new Map(), new Map(), new Set())), '', 'no loss anywhere: no notice');
  eq(F.tempToCheck([winB], 'current', new Map(), new Map([[winB.vmId, 'Standard_D2lds_v5']]), new Set()).length, 0, 'the size choice counts');
});

test('the step draws the notice, keeps what was seen per options version, and marks what open Details show', () => {
  ok(hasLine('${tempNoticeHtml(tempToCheck(machines, tDefault, tOverrides, tSizes, tTSeen))}'), 'renderTargets draws it');
  ok(hasLine('tKernelSel = new Map(); tKSeen = new Set(); tTSeen = new Set();'), 'new options start with every dot');
  ok(hasLine('if (tOpen.has(m.vmId) && tempLost(m, advPick(m, tDefault, tOverrides), tSizes)) tTSeen.add(m.vmId);'), 'tMarkSeen marks it');
  ok(hasLine('let tTSeen = new Set();'), 'declared once');
});

test('the approved words', () => {
  // REBUILD-REMOVE-PLAN-1: the machine is no longer rebuilt, so the notice no longer says so.
  eq(UX.tTempAlert, 'Temporary disk: a machine with a dot on its Details loses its temporary disk on the size you chose. On Windows, drive D: is removed.');
  eq(UX.tTempTag, 'No temporary disk');
  eq(UX.tTempCheck, 'Temporary disk to check');
  ok(!/\bd\b/i.test(UX.tTempAlert.replace('D:', '')), 'no "choose a size with a d" sentence');
});

// The sample data the manual's picture is taken from: two B v1 machines, one
// Windows and one Linux, each on Bsv2 under both defaults, so the picture
// shows the tag, the dots and the notice. The step after it keeps its list.
test('RUN: the targets sample has two B v1 machines that lose the temporary disk on Bsv2, and the grouping sample is unchanged', () => {
  globalThis.DEMO = (() => {
    const start = WIZ.indexOf('const DEMO = {');
    const end = WIZ.indexOf('// MANUAL-SHOTS-1: a planned migration of two waves');
    ok(start > 0 && end > start, 'the sample block');
    // eslint-disable-next-line no-eval
    return eval(`(() => { ${WIZ.slice(start, end)}; return DEMO; })()`);
  })();
  const advice = DEMO['demo-chosen/target-advice.json'];
  const chosen = new Set(DEMO['demo-chosen/machine-choices.json'].machines);
  const b = ['web-b01', 'app-b02'].map(n => advice.machines.find(m => m.name === n));
  ok(b.every(Boolean), 'both machines');
  eq(b.map(m => [m.os, m.sourceSize]), [['Windows', 'Standard_B2s'], ['Linux', 'Standard_B2ms']]);
  for (const m of b) {
    ok(chosen.has(m.vmId), `${m.name} is chosen`);
    for (const def of ['current', 'extended']) {
      const pick = F.advPick(m, def, new Map());
      eq(F.sizeOf(m, pick, new Map()).replace(/^Standard_/, '').replace(/^B\d+l?s_v2$/, 'Bsv2'), 'Bsv2', `${m.name} on Bsv2 (${def})`);
      ok(F.tempLost(m, pick, new Map()), `${m.name} loses it (${def})`);
    }
    ok(DEMO['demo-chosen/assessment.json'].vms.some(v => v.vmId === m.vmId), `${m.name} is in the assessment`);
  }
  // The engine's rule (Get-VmfPathSelection): Windows leaving a size with a
  // temporary disk for one with none is the in-place upgrade (Preview)
  // (REBUILD-REMOVE-PLAN-1; a rebuild before); Linux resizes.
  const v5 = (m) => m.options.find(o => o.option === 'v5');
  eq([v5(b[0]).path, v5(b[0]).preview], ['A', true], 'Windows on Bsv2: the Preview');
  eq([v5(b[1]).path, v5(b[1]).preview], ['A', false], 'Linux on Bsv2: resized');
  const grouped = DEMO['demo-grouped/machine-choices.json'].machines;
  ok(!grouped.some(id => /\/(web-b01|app-b02)$/.test(id)), 'the grouping sample keeps its list');
  eq(DEMO['demo-grouped/target-advice.json'], DEMO['demo-scan/target-advice.json'], 'and its options');
});

test('the marks have their look in app.css, from the amber pair of both themes', () => {
  const css = pageSource(path.join(REPO, 'src', 'dashboard', 'app.css'));
  ok(/^\.p-wizard \.t-ttag \{[^}]*font-family:var\(--font\)/m.test(css), 'the tag is not in the mono face of the size cell');
  ok(/^\.p-wizard \.facts tr\.t-trow td \{ background:var\(--warn-soft\);color:var\(--warn-on\);/m.test(css), 'the marked row');
});

test('the manual has a picture of it', () => {
  const shots = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
  ok(shots.includes("file: 'wizard-targets-tempdisk.png'"), 'the shot is listed');
  ok(shots.includes(`expect: 'tr.t-detail tr.t-trow'`), 'and waits for the marked row');
  const plan = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'plan.md'), 'utf8');
  ok(plan.includes('(../images/wizard-targets-tempdisk.png)'), 'the plan page shows it');
  ok(plan.includes(`**${UX.tTempTag}**`), 'and names the tag');
  ok(fs.existsSync(path.join(REPO, 'docs', 'manual', 'images', 'wizard-targets-tempdisk.png')), 'the picture exists');
});

run('tempdisk-choice');
