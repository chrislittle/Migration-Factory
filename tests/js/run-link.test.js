/* RUN-LINK-1, found 2026-09-30 in the lab session.
 *
 * Every page links to a migration as `?run=<run>&project=<project>` - that is
 * what VmfRun.link writes. The migrations page compared the bare `run` value
 * with ids the store spells `project/run`, so a link never matched. The page
 * then fell back to the migration looked at last, or the newest one, and
 * showed THAT under the address of another. With one machine in two
 * migrations, a person followed a link and saw the wrong migration's machine.
 *
 * RUN, not read: help.js's own runLink and runFromQuery, and the migrations
 * page's own loadRuns, linkedRunId, selectRun and forgetRun.
 */
'use strict';
const { liftAll, test, eq, ok, run } = require('./_harness');
// PAGE-LOAD-2: the page's one calls fail here, so its reads go to the fake source.
const { perFileHelp, perFileGlobals } = require('./_held');

const help = liftAll('help.js', ['runParse', 'runStorePath', 'runLink', 'runFromQuery', 'runKind']);
// PERF-MIGRATIONS-TICK-1: loadRuns reads a run's status and plan through tickReads.
const page = liftAll('migrations.html', ['linkedRunId', 'loadRuns', 'selectRun', 'forgetRun', 'tickReads', 'listReads']);

/* Two migrations in one project; the OLDER one is the one linked. */
function world({ search, remembered, listed, current } = {}) {
  const times = { 'proj/migration-new': '2026-09-30T16:40:00Z', 'proj/migration-old': '2026-09-30T14:25:00Z',
                  'migration-loose': '2026-09-29T10:00:00Z' };
  const store = { 'vmf-last-run': remembered ?? null };
  const w = { store, replaced: null };
  globalThis.location = { search, href: 'https://dash.example.com/migrations.html' + (search || '') };
  globalThis.history = { replaceState: (_, __, u) => {
    w.replaced = String(u);
    globalThis.location = { search: new URL(w.replaced).search, href: w.replaced };
  } };
  globalThis.localStorage = {
    getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; },
  };
  Object.assign(globalThis, perFileGlobals());
  globalThis.VmfHelp = {
    ...perFileHelp(),
    VmfRun: { parse: help.runParse, storePath: help.runStorePath, link: help.runLink, fromQuery: help.runFromQuery },
    mapLimited: async (items, fn) => Promise.all(items.map(fn)),
    // APPROVE-GROUP-1: the two helpers loadRuns hands its facts to and groups
    // by. OVERVIEW-SUMMARY-1 moved them into help.js.
    runGroup: () => 'Completed',
    runSummaryOf: () => null,
    // RETAIN-KIND-1: loadRuns asks the one rule for what a run is.
    runKind: help.runKind,
  };
  globalThis.source = {
    listRuns: async () => listed ?? ['proj/migration-new', 'proj/migration-old'],
    readJson: async (r, doc) => (doc === 'run-status.json' ? { updatedUtc: times[r] }
      : doc === 'plan.json' ? { entries: [{}] } : { kind: 'migration' }),
    async readVersioned(r, doc) { return { text: JSON.stringify(await this.readJson(r, doc)), version: 'v1' }; },
  };
  globalThis.DEMO_MODE = false;
  globalThis.runKinds = new Map();
  globalThis.listedRuns = null;
  globalThis.tickReads = page.tickReads;
  globalThis.pendingRuns = new Set();
    globalThis.renderRunPanel = () => { };
  globalThis.clearReadingRun = () => { };
  globalThis.currentRun = current ?? null;
  globalThis.runRows = [];
  globalThis.lastListError = null;
  globalThis.linkedRunId = page.linkedRunId;
  return w;
}

test('RUN: the link every page writes is read back as the same migration', () => {
  for (const id of ['proj/migration-old', 'migration-loose']) {
    const href = help.runLink('migrations.html', id);
    eq(help.runFromQuery(href.slice(href.indexOf('?'))), id, `a link to ${id}`);
  }
});

test('RUN: a link to the older migration opens the older migration', async () => {
  world({ search: '?run=migration-old&project=proj' });
  await page.loadRuns();
  eq(globalThis.currentRun, 'proj/migration-old', 'not the newest one');
});

test('RUN: the link wins over the migration looked at last', async () => {
  world({ search: '?run=migration-old&project=proj', remembered: 'proj/migration-new' });
  await page.loadRuns();
  eq(globalThis.currentRun, 'proj/migration-old', 'the address names it, so it is shown');
});

test('RUN: a link with no project finds a migration outside any project', async () => {
  world({ search: '?run=migration-loose', listed: ['proj/migration-new', 'migration-loose'] });
  await page.loadRuns();
  eq(globalThis.currentRun, 'migration-loose', 'the bare id is the whole id');
});

test('RUN: a link that carries the whole id still works, with or without project=', async () => {
  for (const search of ['?run=' + encodeURIComponent('proj/migration-old'),
                        '?run=' + encodeURIComponent('proj/migration-old') + '&project=proj']) {
    world({ search });
    await page.loadRuns();
    eq(globalThis.currentRun, 'proj/migration-old', `a composite id in run= is taken as it is: ${search}`);
  }
});

test('RUN: a link to a migration that is not there falls back as before', async () => {
  world({ search: '?run=migration-gone&project=proj', remembered: 'proj/migration-old' });
  await page.loadRuns();
  eq(globalThis.currentRun, 'proj/migration-old', 'the remembered one, then the newest');
});

test('RUN: a run of the same name in another project is not the linked one', () => {
  world({});
  eq(page.linkedRunId('?run=migration-old&project=other', ['proj/migration-old']), null, 'the project is part of the id');
  eq(page.linkedRunId('?run=migration-old', ['proj/migration-old']), null, 'and a bare name is not a project run');
});

test('RUN: a migration picked on the page is the one a reload shows', async () => {
  const w = world({ search: '?run=migration-old&project=proj' });
  await page.loadRuns();
  page.selectRun('proj/migration-new');
  ok(w.replaced, 'the address is written');
  eq(help.runFromQuery(new URL(w.replaced).search), 'proj/migration-new', 'and names the pick');
  ok(/project=proj/.test(w.replaced), 'project= is kept: it is the list filter');
  globalThis.currentRun = null;   // a reload
  await page.loadRuns();
  eq(globalThis.currentRun, 'proj/migration-new', 'the pick, not the first link');
});

test('RUN: deleting the linked migration clears the address, and only that one', () => {
  let w = world({ search: '?run=' + encodeURIComponent('proj/migration-old') });
  page.forgetRun('proj/migration-old');
  ok(w.replaced && !/run=/.test(w.replaced), 'a whole id in run= is cleared');

  w = world({ search: '?run=migration-old' });
  page.forgetRun('proj/migration-old');
  eq(w.replaced, null, 'a bare run= names another migration, so it stays');

  w = world({ search: '?run=migration-old&project=proj' });
  page.forgetRun('proj/migration-old');
  ok(w.replaced && !/run=|project=/.test(w.replaced), 'the form every link writes is cleared');
});

run('run-link');
