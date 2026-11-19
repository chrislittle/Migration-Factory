/* QUIET-READS-1: the wizard asks only for files that can exist for the run.
 *
 * A HAR from the ADVISOR-1 end-to-end run: 292 "not found" answers,
 * nearly all the wizard asking an assessment for its plan and a migration for
 * the assessment's approval and target options - on every refresh.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const READ = WIZ.slice(WIZ.indexOf('async function readRun()'), WIZ.indexOf('async function readRun()') + 4000);

test('the kind is remembered from run.json, per run', () => {
  ok(READ.includes("if (m) { runKinds.set(pre, m.kind === 'migration' ? 'migration' : 'assessment'); }"), 'remembered');
  ok(WIZ.includes('const runKinds = new Map();'), 'one map, kept across refreshes');
});

test('an assessment is not asked for a plan or its sign-off', () => {
  ok(READ.includes("skip('migration') ?? readDoc(`${pre}/plan.json`, held)"), 'plan');
  ok(READ.includes("skip('migration') ?? readDoc(`${pre}/plan-approval.json`, held)"), 'sign-off');
});

test('a migration is not asked for the assessment approval or its target options', () => {
  ok(READ.includes("skip('assessment') ?? readDoc(`${pre}/approval.json`, held)"), 'approval');
  ok(READ.includes("skip('assessment') ?? readVersionedDoc(`${pre}/target-advice.json`)"), 'options');
  ok(READ.includes("skip('assessment') ?? readVersionedDoc(`${pre}/target-choices.json`)"), 'choices');
});

test('the first read, before the kind is known, still asks for everything', () => {
  ok(READ.includes('const skip = (want) => (kind && kind !== want) ? Promise.resolve(null) : null;'), 'nothing skipped while the kind is unknown');
});

run('quiet-reads');
