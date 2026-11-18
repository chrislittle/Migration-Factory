/* WAVE-SAMPLE-RUN-1: the wave editor's sample is the Migrations page's run.
 *
 * Both pages open the sample run pilot-rehearsal-sample with ?demo, and the
 * manual shows each page with it. The Migrations page showed 12 machines in
 * the waves storefront-pilot and billing-apps; the wave editor showed more
 * than 60 other machines in four other waves, under the same run name. Each
 * page kept a sample plan of its own. So a reader could not follow one run
 * from the picture of one page to the picture of the other.
 *
 * The plan is now written once (VmfHelp.sampleRun in help.js), and both pages
 * read it. The wave editor shows it as it was before the run started: the
 * machines and the waves of the run.
 *
 * These tests boot each page in demo mode and compare what each one holds,
 * and they hold the manual's pictures of the wave editor to that run.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, run } = require('./_harness');
const { migrationsSample, wavesSample } = require('./_sample-run');

const REPO = path.join(__dirname, '..', '..');
const nameOf = (id) => String(id).split('/').pop();
const moves = (e) => e && e.path === 'A';
const inWave = (e) => e.wave && e.wave !== 'unscheduled';

let MIG, WAV;
async function both() {
  if (!MIG) { MIG = await migrationsSample(); WAV = await wavesSample(); }
  return { mig: MIG, wav: WAV, plan: MIG.demo['plan.json'] };
}

test('the wave editor opens the run that the Migrations page shows', async () => {
  const { mig, wav } = await both();
  ok(mig.runId, 'the Migrations page shows a run');
  eq(wav.runId, mig.runId, 'the run of the wave editor');
  for (const [k, doc] of Object.entries(mig.demo)) {
    if (doc && typeof doc === 'object' && !Array.isArray(doc) && 'runId' in doc) { eq(doc.runId, mig.runId, `${k} runId`); }
  }
});

test('the wave editor shows every machine that the plan of the Migrations page moves, and no other machine', async () => {
  const { wav, plan } = await both();
  const shown = wav.entries.map(e => nameOf(e.vmId)).sort();
  const moved = plan.entries.filter(moves).map(e => nameOf(e.vmId)).sort();
  eq(shown.join(', '), moved.join(', '), 'the machines of the wave editor');
  ok(moved.length >= 10, `the sample moves ${moved.length} machines`);
});

test('each machine is in the same wave, with the same size now and the same target size, on both pages', async () => {
  const { wav, plan } = await both();
  const byId = new Map(plan.entries.map(e => [e.vmId, e]));
  for (const e of wav.entries) {
    const m = byId.get(e.vmId);
    ok(m, `${nameOf(e.vmId)} is in the plan of the Migrations page`);
    eq(e.wave, m.wave, `${nameOf(e.vmId)} wave`);
    eq(e.assessment.sourceSize, m.assessment.sourceSize, `${nameOf(e.vmId)} size now`);
    eq(e.target.size, m.target.size, `${nameOf(e.vmId)} target size`);
    eq(e.target?.choice?.method ?? null, m.target?.choice?.method ?? null, `${nameOf(e.vmId)} method`);
    eq(e.assessment.os, m.assessment.os, `${nameOf(e.vmId)} operating system`);
  }
});

test('the waves of the wave editor are the waves of the Migrations page, in the same order, with the same machines', async () => {
  const { wav, plan, mig } = await both();
  const order = vm.runInContext('JSON.stringify(planRunOrder(planDoc))', mig.r.sandbox);
  const migOrder = JSON.parse(order);
  eq(wav.layout.map(w => w.name).join(', '), migOrder.join(', '), 'the waves, in order');
  for (const w of wav.layout) {
    const want = plan.entries.filter(e => moves(e) && e.wave === w.name).map(e => nameOf(e.vmId)).sort();
    eq(w.vmIds.map(nameOf).sort().join(', '), want.join(', '), `the machines of ${w.name}`);
  }
});

/* NOT-IN-WAVE-QUEUED-1: a machine that moves but is in no wave, with no state,
 * is not part of the migration. The Migrations page showed it as "Queued"
 * under "Not moved", which was not true; it shows it nowhere now. The sample
 * holds one, prd-lin-d, so the manual's picture of the wave editor shows its
 * left side - and the Migrations page, booted on the same sample, has no row
 * for it. */
test('the one machine that moves in no wave is on the left side of the wave editor', async () => {
  const { wav, plan } = await both();
  eq(wav.entries.filter(e => !inWave(e)).map(e => nameOf(e.vmId)).join(', '), 'prd-lin-d', 'the left side of the wave editor');
  eq(plan.entries.filter(e => moves(e) && !inWave(e)).map(e => nameOf(e.vmId)).join(', '), 'prd-lin-d', 'the machines of the plan in no wave');
  ok(!('state/prd-lin-d.json' in (await both()).mig.demo), 'and it has no state: it never ran');
});

test('RUN: the Migrations page, booted on the sample, does not show the machine in no wave', async () => {
  const { mig } = await both();
  const groups = JSON.parse(vm.runInContext('JSON.stringify(waveGroups(planDoc, allVms).map(([w, i]) => [w, i.entries.map(e => e.vmId.split("/").pop())]))', mig.r.sandbox));
  const shown = groups.flatMap(([, names]) => names);
  ok(shown.length >= 10, `the waves were drawn: ${JSON.stringify(groups)}`);
  ok(!shown.includes('prd-lin-d'), `prd-lin-d is not in any wave group: ${JSON.stringify(groups)}`);
  ok(shown.includes('old-enc-a'), 'the machine the plan does not move is still shown, with its reason');
  const count = vm.runInContext('machinesInRun(allVms, planDoc)', mig.r.sandbox);
  eq(count, shown.length, 'the Virtual machines tile counts the machines the waves show');
});

test('a machine of the sample keeps its own value of a setting, and the wave editor offers Reset beside it', async () => {
  const { wav } = await both();
  const found = vm.runInContext(`(() => {
    const out = [];
    for (const [name, w] of layout) {
      for (const field of Object.keys(WAVE_DEFAULTS)) {
        if (WAVE_WIDE.includes(field)) continue;
        const key = name + '|' + field;
        ownHelp.add(key);
        const html = ownHint(name, w, field);
        ownHelp.delete(key);
        if (html.includes('data-ownreset')) out.push(key);
      }
    }
    return JSON.stringify(out);
  })()`, wav.r.sandbox);
  ok(JSON.parse(found).length >= 1, `a setting with a machine that can be reset: ${found}`);
});

test('each capacity record of the sample counts the machines of its wave and size, and none of them is in an availability set', async () => {
  const { mig, plan } = await both();
  const records = Object.entries(mig.demo).filter(([k]) => k.startsWith('capacity/'));
  ok(records.length >= 1, 'the sample has capacity records');
  for (const [k, c] of records) {
    const machines = plan.entries.filter(e => moves(e) && e.wave === c.wave && e.target.size === c.size);
    eq(c.demand.instances, machines.length, `${k} machines`);
    const reservable = machines.filter(e => !e.assessment?.availabilitySetId).length;
    eq(c.demand.reservableInstances, reservable, `${k} machines that can use a reservation`);
    eq(reservable, machines.length, `${k}: no machine in an availability set`);
  }
});

/* The pictures of the wave editor (tools/manual-shots.js) open a wave or a
 * machine by name. Each name must be a wave or a machine of the run, or the
 * picture shows nothing, or something of another run. */
test('the manual\'s pictures of the wave editor name only waves and machines of the sample run', async () => {
  const { plan } = await both();
  const text = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
  const blocks = text.split(/\n\s*\{ file: '/).slice(1).filter(b => /^[^']+', url: 'waves\.html/.test(b));
  ok(blocks.length >= 4, `the pictures of the wave editor: ${blocks.length}`);
  const waves = new Set(plan.entries.filter(e => moves(e) && inWave(e)).map(e => e.wave));
  const machines = new Set(plan.entries.filter(moves).map(e => nameOf(e.vmId)));
  for (const b of blocks) {
    const file = b.slice(0, b.indexOf("'"));
    const body = b.split(/\n\s*\/\/ /)[0];
    for (const m of body.matchAll(/data-(?:wave|capcheck)="([^"]+)"/g)) { ok(waves.has(m[1]), `${file}: wave ${m[1]}`); }
    for (const m of body.matchAll(/demoState\.set\('([^']+)'/g)) { ok(waves.has(m[1]), `${file}: wave ${m[1]}`); }
    for (const m of body.matchAll(/x\.wave === '([^']+)'/g)) { ok(waves.has(m[1]), `${file}: wave ${m[1]}`); }
    for (const m of body.matchAll(/data-change\$="\/([^"]+)"/g)) { ok(machines.has(m[1]), `${file}: machine ${m[1]}`); }
  }
});

run('wave-sample-run');
