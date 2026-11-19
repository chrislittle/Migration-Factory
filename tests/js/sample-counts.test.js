/* SAMPLE-COUNTS-1: the sample migration behind migrations.html?demo is ONE run.
 *
 * The manual's picture of a migration (migration-run.png) showed "Machines we
 * found 4" above a run of 12 machines. The sample assessment was written for
 * an older, smaller sample plan, and each time the plan gained a machine for a
 * new picture, the assessment stayed as it was. A real plan is built from its
 * assessment, so every machine the plan holds was found by the scan first.
 *
 * These tests hold the sample to that: the plan's machines are in the
 * assessment, with the same size, region and resource group, and the run's
 * state documents are for machines in the plan. Then the page's own
 * renderFound is RUN on the sample, and what it paints is counted.
 */
'use strict';
const { migrationsDemo } = require('./_sample-run');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');

/* The sample documents, as the page holds them after it loads. WAVE-SAMPLE-RUN-1:
 * the plan in them is VmfHelp.sampleRun (help.js), which the wave editor
 * shows too, so the block of the page cannot be evaluated on its own. */
const DEMO = migrationsDemo();
const assessment = DEMO['assessment.json'];
const plan = DEMO['plan.json'];
const rgOf = (id) => (String(id).match(/\/resourceGroups\/([^/]+)\//i) || [])[1];
const nameOf = (id) => String(id).split('/').pop();

test('every machine the sample plan holds is in the sample assessment, once', () => {
  const found = assessment.vms.map(v => v.vmId);
  for (const e of plan.entries) {
    eq(found.filter(id => id === e.vmId).length, 1, `${nameOf(e.vmId)} in the assessment`);
  }
  eq(new Set(found).size, found.length, 'no machine found twice');
});

test('each planned machine has the size, region, resource group and tags the plan read from the assessment', () => {
  const byId = new Map(assessment.vms.map(v => [v.vmId, v]));
  for (const e of plan.entries) {
    const v = byId.get(e.vmId);
    ok(v, `${nameOf(e.vmId)} found`);
    eq(v.sourceSize, e.assessment.sourceSize, `${nameOf(e.vmId)} size`);
    eq(v.location, e.assessment.location, `${nameOf(e.vmId)} region`);
    // WAVE-SAMPLE-RUN-1: the wave editor filters the plan by resource group and tag.
    eq(e.assessment.resourceGroup, v.resourceGroup, `${nameOf(e.vmId)} resource group`);
    eq(JSON.stringify(e.assessment.tags ?? {}), JSON.stringify(v.tags ?? {}), `${nameOf(e.vmId)} tags`);
  }
});

test('each found machine is named, and placed in the resource group, by its own id', () => {
  for (const v of assessment.vms) {
    eq(v.name, nameOf(v.vmId), `${v.name} name`);
    eq(v.resourceGroup, rgOf(v.vmId), `${v.name} resource group`);
  }
});

test('every machine the sample run has a state for is a machine of its plan', () => {
  const planned = new Set(plan.entries.map(e => e.vmId));
  const states = Object.keys(DEMO).filter(k => k.startsWith('state/'));
  ok(states.length > 0, 'the sample has state documents');
  for (const k of states) {
    ok(planned.has(DEMO[k].vmId), `${k} is for a planned machine`);
    eq(`state/${nameOf(DEMO[k].vmId)}.json`, k, `${k} is named for its machine`);
  }
});

test('RUN: "Machines we found" counts every machine of the run, and no planned machine reads "not in this migration"', () => {
  const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
  const el = { innerHTML: '' };
  Object.assign(globalThis, {
    $: (sel) => (sel === '#found' ? el : null),
    esc: (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    UX_FOUND: liftConst('migrations.html', 'UX_FOUND'),
    UX_FOUND_T: liftConst('migrations.html', 'UX_FOUND_T'),
    REASONS: { blockers: reasons.blockers ?? {}, prep: reasons.prep ?? {} },
    foundOpen: true,
  });
  globalThis.reasonText = (code) => (globalThis.REASONS.blockers[code] || globalThis.REASONS.prep[code] || {}).title || String(code);
  const F = liftAll('migrations.html', ['renderFound', 'judgeForSeries', 'judgeUnplanned', 'foundCurrent']);
// ALREADY-CURRENT-1: renderFound asks the page's Current rule first.
globalThis.foundCurrent = F.foundCurrent;
  globalThis.judgeForSeries = F.judgeForSeries;
  globalThis.judgeUnplanned = F.judgeUnplanned;
  F.renderFound(structuredClone(assessment), true, structuredClone(plan));

  const head = el.innerHTML.match(/<h2>[^<]*<span class="muted">(\d+)<\/span>([\s\S]*?)<\/h2>/);
  ok(head, 'the heading is painted');
  const total = Number(head[1]);
  ok(total >= plan.entries.length, `found ${total}, and the run holds ${plan.entries.length}`);
  eq(total, assessment.vms.length, 'the heading counts the assessment');
  const pills = [...head[2].matchAll(/>(\d+) ([^<]+)<\/span>/g)].map(m => [Number(m[1]), m[2]]);
  eq(pills.reduce((s, [n]) => s + n, 0), total, 'the counts in the heading add up to the total');
  const notChosen = (pills.find(([, w]) => w === globalThis.UX_FOUND.NotChosen[2]) || [0])[0];
  const outside = assessment.vms.filter(v => !plan.entries.some(e => e.vmId === v.vmId) && v.classification !== 'Excluded').length;
  eq(notChosen, outside, '"not in this migration" counts only the machines the plan does not hold');

  // The rows: one per machine, and no planned machine is "Not in this migration".
  const rows = [...el.innerHTML.matchAll(/<tr>\s*<td class="mono">([^<]+)<\/td>[\s\S]*?<span class="pill[^"]*"[^>]*>([^<]+)<\/span>/g)].map(m => [m[1], m[2]]);
  eq(rows.length, total, 'one row for each machine found');
  const plannedNames = new Set(plan.entries.map(e => nameOf(e.vmId)));
  for (const [name, word] of rows) {
    if (plannedNames.has(name)) { ok(word !== globalThis.UX_FOUND.NotChosen[0], `${name} is in this migration`); }
  }
});

run('sample-counts');
