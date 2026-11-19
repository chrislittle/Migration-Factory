/* REVIEW-PAGE-1 (draft): the review is one row per machine with Details.
 *
 * The owner, on the review during the ADVISOR-1 end-to-end run: it needs the
 * format of the per-machine target choice, with the details behind a button -
 * "its getting too long & bulky".
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { liftAll, liftConst, test, ok, eq, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} }, console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
Object.assign(ctx.window.VmfReport.REASONS.blockers, reasons.blockers);
Object.assign(ctx.window.VmfReport.REASONS.prep, reasons.prep ?? {});
global.window = ctx.window;
global.UX = liftConst('wizard.html', 'UX');
global.esc = (s) => String(s ?? '');
global.vmName = (id) => String(id).split('/').pop();
const f = liftAll('wizard.html', ['advGenLabel', 'reviewDetail', 'reviewTable']);
global.advGenLabel = f.advGenLabel; global.reviewDetail = f.reviewDetail;
global.rOpen = new Set();
// DETECT-PATTERNS-1: the review table filters by workload type; '' shows all.
global.rWorkload = '';

const g1 = { vmId: '/vm/g1', name: 'g1', sourceSize: 'Standard_D2s_v4', gen: 'V1', classification: 'Blocked', blockers: ['gen1-requires-redeploy', 'image-cannot-boot-nvme'], prepNeeded: [] };
const lin = { vmId: '/vm/lin', name: 'lin', sourceSize: 'Standard_D2s_v4', gen: 'V2', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [] };

test('one row per machine: size, generation, the targets still open', () => {
  const html = f.reviewTable([g1, lin]);
  ok(html.includes('g1') && html.includes('D2s_v4') && html.includes(UX.vGen1) && html.includes('<td>v5</td>'), html);
  ok(html.includes('<td>v5, v6, v7</td>'), 'a ready machine is open to all');
});

test('Details shows what stops it, and which series each reason closes', () => {
  global.rOpen = new Set(['/vm/g1']);
  const html = f.reviewTable([g1]);
  ok(html.includes(UX.rStops) && html.includes(reasons.blockers['gen1-requires-redeploy'].title), 'the reason');
  ok(html.includes('Applies to v6 and v7.'), 'the series');
  // CLOSE-NOT-CANCEL-1: Details only show information, so the open button says Close.
  ok(new RegExp(`class="btn small ghost r-det"[^>]*aria-expanded="true">${UX.tClose}</button>`).test(html), 'the button turns into Close');
  global.rOpen = new Set();
});

test('Escape closes it, on the review step only', () => {
  ok(WIZ.includes("if (e.key === 'Escape' && journey === 'assess' && step === STEP.assess.review && rOpen.size) { rOpen.clear(); render(); }"));
});

test('the note being typed survives a Details click', () => {
  ok(WIZ.includes('<textarea id="f-rev" rows="2">${esc(reviewNote)}</textarea>') && WIZ.includes("$('#f-rev').addEventListener('input', (e) => { reviewNote = e.target.value; });"));
});

run('review-page');
