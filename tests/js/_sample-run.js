/* WAVE-SAMPLE-RUN-1: the sample run of the Migrations page and of the wave
 * editor, as each page holds it in demo mode.
 *
 * The two pages each kept a sample plan of their own under ONE run name, so
 * the manual's picture of the Migrations page showed 12 machines and its
 * picture of the wave editor more than 60, with other names. The plan is now
 * written once, in help.js (VmfHelp.sampleRun), and each page reads it.
 *
 * These read what each page HOLDS after a demo boot - not the help.js block
 * on its own - so a page that went back to a plan of its own is caught.
 * Each value is copied out of the page's context as JSON, so the tests
 * compare plain values.
 */
'use strict';
const vm = require('vm');
const { bootPage, settle } = require('./_dom');

const copy = (sandbox, expr) => JSON.parse(vm.runInContext(`JSON.stringify(${expr})`, sandbox));

/** The sample documents of the Migrations page, read at once: the page builds
 *  them when its script loads, so nothing needs to settle first. */
function migrationsDemo() {
  return copy(bootPage('migrations.html').sandbox, 'DEMO');
}

/** The Migrations page in demo mode: its sample documents and the run it shows. */
async function migrationsSample() {
  const r = bootPage('migrations.html');
  await settle(r);
  return { demo: copy(r.sandbox, 'DEMO'), runId: copy(r.sandbox, 'currentRun'), r };
}

/** The wave editor in demo mode: the run it opens, its plan, the machines it
 *  shows, and its waves in order with their machines. */
async function wavesSample() {
  const r = bootPage('waves.html');
  await settle(r);
  return {
    runId: copy(r.sandbox, 'runId'),
    plan: copy(r.sandbox, 'DEMO_PLAN'),
    entries: copy(r.sandbox, 'entries'),
    layout: copy(r.sandbox, '[...layout].map(([name, w]) => ({ name, vmIds: w.vmIds }))'),
    r,
  };
}

module.exports = { migrationsDemo, migrationsSample, wavesSample, copy };
