/* RUNID-2 and READ-1, tested by RUNNING the page's own helpers.
 *
 * FOUR MUTATIONS SURVIVED the first version of these guards, which read the
 * pages as text. Each one moved the defect up one level, where a check that
 * matches call sites cannot see it:
 *
 *   1. runHref builds `${page}?run=...` itself   - no literal `.html?run=`
 *   2. runSeg encodes the FULL id                - no literal at a call site
 *   3. readDoc swallows a failure again          - covered by nothing at all
 *   4. deriveStep moves somebody after a failure - covered by nothing at all
 *
 * A guard that only knows the shape of a call site is a guard against copying,
 * not against the defect. These run the functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');
const fs = require('fs');
const path = require('path');
const REPO_DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');

const { runParse, runStorePath, runRouteSegment, runWithProject, runLink } =
  liftAll('help.js', ['runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink']);
// PAGE-LOAD-3: readDoc asks the one call first; here there is none, so each document is read.
global.VmfHelp = { ...require('./_held').perFileHelp(),
  VmfRun: { parse: runParse, storePath: runStorePath, routeSegment: runRouteSegment,
            withProject: runWithProject, link: runLink },
  explain: (e) => `explained: ${e && e.message}`,
};

/* The page's own helpers, from the page, in one scope - they call each other. */
function pageHelpers(file) {
  const { runFullId, runPrefix, runSeg, runBody, runHref } =
    liftAll(file, ['runFullId', 'runPrefix', 'runSeg', 'runBody', 'runHref']);
  return { runFullId, runPrefix, runSeg, runBody, runHref };
}

/* EVERY page that has a runSeg, FOUND BY LOOKING. This list used to be
 * ['wizard.html', 'waves.html'], written by hand - and migrations.html, the
 * main operator page, was not on it. Its runSeg encoded the WHOLE id, so all
 * fifteen of its actions answered "That record is not there" for any run
 * inside a project, and no test here could see it because no test here ran it.
 *
 * The static guard could not see it either: it bans a raw encodeURIComponent
 * in a route, and this page had moved that one level up into its own helper.
 * A rule that reads call sites cannot follow a defect that moves into a
 * function - only running the function can. So the pages are discovered. */
const pagesWithRunSeg = fs.readdirSync(REPO_DASH)
  .filter(f => f.endsWith('.html'))
  .filter(f => /\bfunction runSeg\s*\(/.test(pageSource(path.join(REPO_DASH, f))));

test('the pages were FOUND, and the main operator page is among them', () => {
  ok(pagesWithRunSeg.length >= 3, `found ${pagesWithRunSeg.length}: ${pagesWithRunSeg}`);
  ok(pagesWithRunSeg.includes('migrations.html'), `migrations.html must be driven: ${pagesWithRunSeg}`);
});

/* THE ONE INVARIANT EVERY PAGE SHARES: a route segment never carries the
 * project. Run on every page that has a runSeg, whatever else it has - this is
 * the check migrations.html would have failed, and the only one it CAN take,
 * because it holds no other helper of this family. A loop that demands the
 * whole family is a loop that skips the page with one of them. */
for (const file of pagesWithRunSeg) {
  const runSegOf = lift(file, 'runSeg');

  test(`${file}: THE DEFECT - the route segment drops the project`, () => {
    global.projectId = 'test2'; global.runId = 'assess-1';
    global.currentRun = 'test2/assess-1';
    const seg = runSegOf();
    ok(!seg.includes('/'), `a raw slash matches no route: ${seg}`);
    ok(!/%2f/i.test(seg), `an encoded slash is rejected: ${seg}`);
    eq(seg, 'assess-1');
  });
}

/* And the pages that carry the WHOLE family, also found by looking. */
const pagesWithRunBody = pagesWithRunSeg.filter(
  f => /\bfunction runBody\s*\(/.test(pageSource(path.join(REPO_DASH, f))));

test('the pages with the full family were found', () => {
  ok(pagesWithRunBody.length >= 2, `found ${pagesWithRunBody.length}: ${pagesWithRunBody}`);
});

for (const file of pagesWithRunBody) {
  const h = pageHelpers(file);

  test(`${file}: the store path keeps the project`, () => {
    global.projectId = 'test2'; global.runId = 'assess-1';
    eq(h.runPrefix(), 'test2/assess-1');
  });

  test(`${file}: THE DEFECT - the route segment drops it`, () => {
    global.projectId = 'test2'; global.runId = 'assess-1';
    const seg = h.runSeg();
    ok(!seg.includes('/'), `a raw slash matches no route: ${seg}`);
    ok(!/%2f/i.test(seg), `an encoded slash is rejected: ${seg}`);
    eq(seg, 'assess-1');
  });

  test(`${file}: and the project travels in the body instead`, () => {
    global.projectId = 'test2'; global.runId = 'assess-1';
    eq(h.runBody({ note: 'n' }).project, 'test2');
  });

  test(`${file}: THE OTHER HALF - a link carries the project`, () => {
    global.projectId = 'test2'; global.runId = 'assess-1';
    const href = h.runHref('waves.html');
    ok(href.includes('project=test2'), href);
    ok(href.includes('run=assess-1'), href);
  });

  test(`${file}: a run with no project is addressed the same way`, () => {
    global.projectId = null; global.runId = 'assess-1';
    eq(h.runPrefix(), 'assess-1');
    eq(h.runSeg(), 'assess-1');
    eq(h.runHref('waves.html'), 'waves.html?run=assess-1');
    eq(Object.prototype.hasOwnProperty.call(h.runBody({}), 'project'), false);
  });
}

/* READ-1: the wizard's reader, and the step it derives. */
const readDoc = lift('wizard.html', 'readDoc');
const deriveStep = lift('wizard.html', 'deriveStep');

test('a document that is NOT THERE is null, and is not a failure', () => {
  global.readFailed = null;
  global.blobJson = async () => null;      // the service answers 404 as null
  return readDoc('x/run.json').then(v => {
    eq(v, null);
    eq(global.readFailed, null, 'absence is not a failure');
  });
});

test('THE DEFECT: a read that FAILED is remembered, not swallowed', () => {
  global.readFailed = null;
  global.blobJson = async () => { throw new Error('HTTP 403'); };
  return readDoc('x/run.json').then(v => {
    eq(v, null);
    ok(global.readFailed, 'the failure must survive the read');
    eq(global.readFailed.message, 'HTTP 403');
  });
});

test('and the FIRST failure is the one kept', () => {
  global.readFailed = null;
  global.blobJson = async () => { throw new Error('HTTP 403'); };
  return readDoc('a').then(() => {
    global.blobJson = async () => { throw new Error('HTTP 500'); };
    return readDoc('b').then(() => eq(global.readFailed.message, 'HTTP 403'));
  });
});

test('THE BOUNCE: a failed read never moves the person', () => {
  // He pressed "Plan a migration from this" and landed at step 1, because the
  // page derived a step from four documents it could not read.
  global.readFailed = new Error('HTTP 403');
  global.step = 4;
  global.journey = 'assess';
  eq(deriveStep(), 4, 'the step must not be recomputed from nothing');
});

run('RUNID-2 and READ-1: the pages own helpers');