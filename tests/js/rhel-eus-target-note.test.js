/* RHEL-EUS-TARGET-NOTE-1: the targets step says, in the network driver choice
 * of a Red Hat machine, that it was made from an image on the EUS
 * repositories - what the scan read (the image), never which repositories the
 * machine uses now. Update the kernel stays offered.
 *
 * ONE fixture, tests/fixtures/rhel-eus-target-note.json: the engine is held to
 * its "expect" (tests/unit/RhelEusTargetNote.Tests.ps1), and this page, given
 * a machine with that eusImage, to its words.
 *
 * RUN, not read: the page's own functions, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
const F = liftAll('wizard.html', ['kernelSectionHtml', 'tHelpBtn', 'eusImageText']);
globalThis.tHelp = new Set();

const FIXTURE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'rhel-eus-target-note.json'), 'utf8'));
const machine = (eusImage) => ({ vmId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/rh-01',
  name: 'rh-01', os: 'Linux', eusImage });

for (const c of FIXTURE.cases) {
  test(`RUN: ${c.name}`, () => {
    const m = machine(c.expect);
    const html = F.kernelSectionHtml(m, 'update', 'kernel-0');
    // The choice stays offered whatever the note says.
    ok(html.includes('value="update"') && html.includes('value="stop"'), 'both choices are there');
    if (!c.expect) {
      eq(F.eusImageText(m), '', 'no note');
      ok(!html.includes('t-eus'), 'no note in the section');
      return;
    }
    const text = F.eusImageText(m);
    ok(text.includes(c.expect.image), `the image: ${text}`);
    ok(text.includes(`RHEL ${c.expect.release}`), `the release: ${text}`);
    ok(text.includes(`RHEL ${c.expect.listedFrom}`), `the lowest listed release: ${text}`);
    ok(html.includes(`<p class="t-eus">${esc(text)}</p>`), 'the note is in the section');
    // Beside the choice: after the reason for it, before the two answers.
    ok(html.indexOf('t-eus') > html.indexOf(esc(UX.tKernelWhy)), 'after the reason for the choice');
    ok(html.indexOf('t-eus') < html.indexOf('role="radiogroup"'), 'before the two answers');
  });
}

test('the words: the approved note, exactly, and neutral about EUS (2026-11-11)', () => {
  eq(UX.tKernelEus, 'This machine was made from a Red Hat EUS image, {image}, and runs RHEL {release}. EUS repositories hold updates for one minor release only, so Update the kernel finds no RHEL {listed} kernel. MANA needs RHEL {listed} or later. To use this target, move the machine to RHEL {listed} before the move, on EUS or non-EUS repositories.');
  ok(!/switch/i.test(UX.tKernelEus), 'never tells a person to leave EUS');
  ok(!/Update Manager|Satellite|Ansible/i.test(UX.tKernelEus), 'no customer tool');
});

test('a machine with no eusImage shows no note', () => {
  eq(F.eusImageText({ name: 'x' }), '');
});

run();
