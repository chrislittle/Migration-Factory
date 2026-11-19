/* PROJECT-3: a folder beside the runs is not a run - the browser's half.
 *
 * The service walks the store for the timers; these walk it for the pages.
 * When they disagree, one of them reports a run that is not there: the
 * overview asked `test2/logs` for a run record on every load and got a 404,
 * and the assessments, migrations and waves pages listed it as a run.
 *
 * tests/fixtures/not-a-run-folders.json is the one list of cases both halves
 * are held to. Test-VmfFacadeRunFolder answers it in PowerShell
 * (tests/unit/TimerPasses.Tests.ps1); runFolderIsRun answers it here.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, run } = require('./_harness');

// listRunsAcrossProjects paces itself through mapLimited, which reads a
// constant rather than taking one - so the constant comes from the source
// too, never a copy of the number that could drift from it.
const helpSrc = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
global.STORE_READ_LIMIT = Number(/STORE_READ_LIMIT = (\d+)/.exec(helpSrc)[1]);

// listRunsAcrossProjects calls mapLimited, so both come across together.
const { runFolderIsRun, listRunsAcrossProjects } =
  liftAll('help.js', ['runFolderIsRun', 'listRunsAcrossProjects', 'mapLimited']);

const fixture = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'not-a-run-folders.json'), 'utf8'));

for (const c of fixture.cases) {
  test(`${c.path} -> ${c.isRun ? 'a run' : 'not a run'} (${c.why})`, () => {
    eq(runFolderIsRun(c.path), c.isRun, c.path);
  });
}

/** A lab store, 2026-09-16: one project holding three runs and the
 *  `logs` folder the old retention pass left beside them. */
function ownerStore() {
  const tree = {
    '': { prefixes: ['test2', 'vmf-claims'], names: [] },
    'test2/': {
      prefixes: ['test2/assessment-1829', 'test2/assessment-1829-migration-2239',
                 'test2/assessment-1829-migration-2243', 'test2/logs'],
      names: ['test2/project.json'],
    },
  };
  const asked = [];
  return {
    asked,
    blobList: async (prefix) => { asked.push(prefix); return tree[prefix] || { prefixes: [], names: [] }; },
  };
}

test('THE DEFECT: three runs in the project, not four', async () => {
  const store = ownerStore();
  const runs = await listRunsAcrossProjects(store.blobList);
  eq(runs.length, 3, 'runs found');
  eq(runs.includes('test2/logs'), false, 'the event log counted as a run');
});

test('the claim registry is never opened at all', async () => {
  const store = ownerStore();
  await listRunsAcrossProjects(store.blobList);
  eq(store.asked.includes('vmf-claims/'), false, 'listed the claim registry');
});

test('a run whose name merely contains the word is still a run', async () => {
  const store = ownerStore();
  const runs = await listRunsAcrossProjects(async (prefix) => {
    if (prefix === '') { return { prefixes: ['test2'], names: [] }; }
    if (prefix === 'test2/') {
      return { prefixes: ['test2/logs', 'test2/logs-of-war', 'test2/my-logs'], names: ['test2/project.json'] };
    }
    return { prefixes: [], names: [] };
  });
  eq(runs.join(','), 'test2/logs-of-war,test2/my-logs', 'runs found');
});

run('run-folders');
