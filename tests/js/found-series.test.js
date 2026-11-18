/* REVIEW-1: the migrations page judges a planned machine against ITS series.
 *
 * V5-GATE-1 made the engine judge the scan's "Blocked" against the plan
 * entry's size series. The page did not: a Generation 1 machine planned - and
 * migrated - in a v5 wave was still listed as "cannot migrate yet" with
 * gen1-requires-redeploy. judgeForSeries is the page's twin of the engine's
 * Resolve-VmfEntryClassification, run here against the real reasons data.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const data = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
global.REASONS = { blockers: data.blockers, prep: data.prep };
const { judgeForSeries } = liftAll('migrations.html', ['judgeForSeries']);

const gen1 = { classification: 'Blocked', blockers: ['gen1-requires-redeploy'], prepNeeded: ['linux-nvme-prep'], diskController: '' };

test('a Generation 1 machine in a v5 wave is not blocked, and its v6-only prep drops away', () => {
  const j = judgeForSeries(gen1, 'v5');
  eq(j.classification, 'ReadyAfterPrep');
  eq(j.blockers.length, 0);
  ok(!j.prep.includes('linux-nvme-prep'), 'NVMe preparation does not apply to v5');
});

test('the same machine in a v6 wave is still blocked, for the same reason', () => {
  const j = judgeForSeries(gen1, 'v6');
  eq(j.classification, 'Blocked');
  eq(j.blockers.join(','), 'gen1-requires-redeploy');
});

test('a v5-only hold blocks a v5 wave', () => {
  eq(judgeForSeries({ classification: 'Blocked', blockers: ['windows-version-not-proven'] }, 'v5').classification, 'Blocked');
});

test('a machine that is not planned keeps the scan\'s own verdict', () => {
  eq(judgeForSeries(gen1, undefined).classification, 'Blocked');
});

test('a code the data does not know counts for every series - never a pass', () => {
  eq(judgeForSeries({ classification: 'Blocked', blockers: ['a-reason-from-a-newer-scan'] }, 'v5').classification, 'Blocked');
});

test('Excluded stays excluded', () => {
  eq(judgeForSeries({ classification: 'Excluded', blockers: [] }, 'v5').classification, 'Excluded');
});

test('the page passes the plan to it', () => {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
  ok(src.includes('renderFound(assessDoc, Boolean(planDoc && (planDoc.entries ?? []).length), planDoc);'), 'renderFound is called with the plan');
});

test('and judges each machine against the series of its own entry', () => {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
  const body = src.slice(src.indexOf('function renderFound('), src.indexOf('function renderFound(') + 1500);
  // ASSESS-COUNT-1: a machine with no series planned is judged across every
  // series (judgeUnplanned, run in assess-count.test.js).
  ok(body.includes('const series = seriesOf.get(v.vmId);') && body.includes('series ? judgeForSeries(v, series, entryOf.get(v.vmId)?.target?.diskArch) : judgeUnplanned(v)'), 'renderFound judges each machine by its planned series');
  // BSV2-TARGET-1 (review): and by its planned temporary disk kind, so a v5 move with none says the page file moves (bsv2-series.test.js runs the rule).
  ok(body.includes("e.policy?.targetGeneration"), 'the series comes from the plan entry');
});

run('found-series');
