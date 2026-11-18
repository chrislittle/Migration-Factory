/* RUNID-2: a run has one identity, and three ways of writing it.
 *
 * MEASURED 2026-09-15 on a lab install. "Plan a migration from this" landed
 * back at the start of the wizard. The browser console:
 *
 *   GET  .../api/store/blob?path=...run.json         404
 *   GET  .../api/store/blob?path=...approval.json    404
 *   GET  .../api/store/blob?path=...assessment.json  404
 *   GET  .../api/store/blob?path=...plan.json        404
 *   POST .../api/runs/test2%2Fassess...              404
 *
 * Two different faults, one cause. The link carried `?run=` and not
 * `?project=`, so the page composed the store path without the project and
 * every read missed. And where the composite id DID survive, it went into
 * `runs/{runId}` - one route segment - where a slash cannot fit.
 *
 * This ran once as source-reading tests and passed. These RUN the code.
 */
'use strict';
const { liftAll, test, eq, ok, run } = require('./_harness');

const { runParse, runStorePath, runRouteSegment, runWithProject, runLink } =
  liftAll('help.js', ['runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink']);

test('a composite id splits into its project and its run', () => {
  const p = runParse('test2/assessment-2026-09-15-1600');
  eq(p.project, 'test2');
  eq(p.run, 'assessment-2026-09-15-1600');
});

test('a bare id has no project, and is not mistaken for one', () => {
  const p = runParse('assessment-2026-09-15-1600');
  eq(p.project, null);
  eq(p.run, 'assessment-2026-09-15-1600');
});

test('a leading slash does not invent an empty project', () => {
  eq(runParse('/thing').project, null);
  eq(runParse('/thing').run, '/thing');
});

test('nothing at all is answered, not thrown', () => {
  eq(runParse(null).run, '');
  eq(runParse(undefined).project, null);
});

test('the store path keeps the project, because that is where it lives', () => {
  eq(runStorePath('test2', 'assess-1'), 'test2/assess-1');
  eq(runStorePath(null, 'assess-1'), 'assess-1');
  eq(runStorePath('', 'assess-1'), 'assess-1');
});

test('THE DEFECT: a route segment never carries a slash', () => {
  // runs/test2%2Fassess-1 answered 404 on the live service. Encoded, IIS
  // rejects it; raw, it matches no route.
  const seg = runRouteSegment('test2/assess-1');
  eq(seg, 'assess-1');
  ok(!seg.includes('/'), 'a raw slash would match no route');
  ok(!/%2f/i.test(seg), 'an encoded slash is rejected before routing');
});

test('and a bare id goes through the same door unchanged', () => {
  eq(runRouteSegment('assess-1'), 'assess-1');
});

test('a run name that needs encoding still gets it', () => {
  eq(runRouteSegment('proj/a b'), 'a%20b');
});

test('the project travels in the body instead', () => {
  eq(runWithProject({ note: 'x' }, 'test2/assess-1').project, 'test2');
  eq(runWithProject({ note: 'x' }, 'test2/assess-1').note, 'x');
  eq(runWithProject(null, 'test2/assess-1').project, 'test2');
});

test('and a run with no project sends no project field', () => {
  eq(Object.prototype.hasOwnProperty.call(runWithProject({ n: 1 }, 'assess-1'), 'project'), false);
});

test('THE OTHER HALF: a link cannot lose the project', () => {
  // wizard.html?run=...&plan=1 was the link he pressed. No project, so the
  // page read the wrong path and decided the run did not exist.
  const href = runLink('wizard.html', 'test2/assess-1', { plan: 1 });
  ok(href.includes('run=assess-1'), href);
  ok(href.includes('project=test2'), href);
  ok(href.includes('plan=1'), href);
});

test('a run with no project produces no empty project parameter', () => {
  const href = runLink('wizard.html', 'assess-1');
  eq(href, 'wizard.html?run=assess-1');
});

test('an extra with no value is left out rather than sent empty', () => {
  eq(runLink('waves.html', 'assess-1', { wave: null }), 'waves.html?run=assess-1');
});

test('the link and the store path agree about the same run', () => {
  // The round trip that was broken: read the id back out of the link and it
  // must name the same documents.
  const id = 'test2/assess-1';
  const href = runLink('wizard.html', id);
  const q = new URLSearchParams(href.slice(href.indexOf('?')));
  eq(runStorePath(q.get('project'), q.get('run')), id);
});

run('RUNID-2: a run has one identity');