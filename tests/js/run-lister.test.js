/* ASSESS-LIST-1: does an assessment actually APPEAR in the app?
 *
 * The original report: no assessments showed in the portal. OPERATOR-PATH-1
 * answered the half that could be answered by driving the facade - a project was
 * created, a scan started, the manifest came back kind=assessment, an approval
 * was recorded. Every one of those is an ENDPOINT returning a status code.
 *
 * None of them is the Assessments page listing anything, and the working example
 * that was "left in the store deliberately" so somebody could look has since
 * been cleared. So the operator-visible half stayed unproven.
 *
 * listRunsAcrossProjects is what decides it. Everything the Assessments and
 * Migrations pages show comes through this one function, and it had NO TESTS at
 * all - which is how "no assessments in the portal" happened the first time.
 *
 * Its job is a discrimination that is easy to get subtly wrong: a top-level
 * prefix is either a RUN or a PROJECT that contains runs, and the only thing
 * telling them apart is whether project.json sits inside it.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, run } = require('./_harness');

/* STORE-READ-2: this function now paces its listings through mapLimited, which
 * the harness lifts one function at a time and so cannot see. Lift the real
 * one - and the real limit it reads - rather than substituting a plain
 * Promise.all here, which would test a version of the code that does not ship.
 */
const HELP_SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const LIMIT_MATCH = HELP_SRC.match(/const STORE_READ_LIMIT = (\d+);/);
if (!LIMIT_MATCH) { throw new Error('STORE_READ_LIMIT is not declared in help.js'); }
global.STORE_READ_LIMIT = Number(LIMIT_MATCH[1]);
global.mapLimited = lift('help.js', 'mapLimited');
// PROJECT-3: and the rule that tells a run from the folders beside it.
global.runFolderIsRun = lift('help.js', 'runFolderIsRun');

const listRuns = lift('help.js', 'listRunsAcrossProjects');

/** A fake blob container. `store` is a list of blob names. */
function fakeBlobList(store) {
  return async (prefix, delimiter) => {
    const rest = store
      .filter(n => n.startsWith(prefix))
      .map(n => n.slice(prefix.length));
    if (!delimiter) {
      return { names: store.filter(n => n.startsWith(prefix)), prefixes: [] };
    }
    const names = [];
    const prefixes = new Set();
    for (const r of rest) {
      const i = r.indexOf('/');
      if (i === -1) { names.push(prefix + r); }
      else { prefixes.add(prefix + r.slice(0, i)); }
    }
    return { names, prefixes: [...prefixes] };
  };
}

test('a TOP-LEVEL assessment is listed', async () => {
  // The shape OPERATOR-PATH-1 would produce without a project.
  const store = ['estate-scan/run.json', 'estate-scan/assessment.json'];
  eq(await listRuns(fakeBlobList(store)), ['estate-scan']);
});

test('an assessment INSIDE a project is listed as project/child', async () => {
  // The shape that run actually produced: lab-estate/estate-scan/run.json.
  const store = [
    'lab-estate/project.json',
    'lab-estate/estate-scan/run.json',
    'lab-estate/estate-scan/assessment.json',
  ];
  eq(await listRuns(fakeBlobList(store)), ['lab-estate/estate-scan']);
});

test('a project is never listed as a run in its own right', async () => {
  // If it were, the pages would try to read project.json as a manifest and
  // show a row for something that is not a run.
  const store = ['lab-estate/project.json', 'lab-estate/estate-scan/run.json'];
  const got = await listRuns(fakeBlobList(store));
  eq(got.includes('lab-estate'), false, 'project listed as a run');
});

test('an EMPTY project contributes nothing, rather than a phantom row', async () => {
  // OPERATOR-PATH-1 found the facade auditing to the container root, "leaving a
  // phantom empty run in the operator's list for every scan". A project with no
  // runs in it is the same shape of mistake waiting to happen.
  const store = ['lab-estate/project.json'];
  eq(await listRuns(fakeBlobList(store)), []);
});

test('the claim registry is not a run', async () => {
  const store = ['vmf-claims/deletions.jsonl', 'vmf-claims/logs/events.jsonl'];
  eq(await listRuns(fakeBlobList(store)), []);
});

test('and it is excluded by NAME, so a run may not be called vmf-claims', async () => {
  // Pinning the actual rule rather than the outcome: the exclusion is a name
  // check, so this is the one id the store can never show.
  const store = ['vmf-claims/run.json', 'real-run/run.json'];
  eq(await listRuns(fakeBlobList(store)), ['real-run']);
});

test('a mixed store lists every run, sorted, across both shapes', async () => {
  const store = [
    'vmf-claims/deletions.jsonl',
    'estate-scan/run.json',                       // top-level assessment
    'lab-estate/project.json',                    // a project...
    'lab-estate/wave-one/run.json',               // ...with two runs
    'lab-estate/estate-scan/run.json',
    'payments/project.json',
    'payments/scan-2/run.json',
  ];
  eq(await listRuns(fakeBlobList(store)), [
    'estate-scan',
    'lab-estate/estate-scan',
    'lab-estate/wave-one',
    'payments/scan-2',
  ]);
});

test('a run whose name merely resembles a project is still a run', async () => {
  // The discrimination is project.json, not the name or the nesting.
  const store = ['project-alpha/run.json', 'project-alpha/logs/events.jsonl'];
  eq(await listRuns(fakeBlobList(store)), ['project-alpha']);
});

run('run-lister');
