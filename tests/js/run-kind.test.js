/* RETAIN-KIND-1: what a run's manifest says the run IS - the browser's half.
 *
 * One rule, in each language. OLD-VERSION-READERS-REMOVE-6: the manifest
 * writer writes the kind on every manifest, so a manifest with none is not
 * known (null) - it is not read as a migration any more:
 * VmfHelp.runKind here, Get-VmfRunKind in the engine
 * (tests/unit/RunKind.Tests.ps1). tests/fixtures/run-kinds.json is the one
 * list of cases both are held to.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, test, eq, run } = require('./_harness');

const runKind = lift('help.js', 'runKind');
const fixture = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'run-kinds.json'), 'utf8'));

for (const c of fixture.cases) {
  test(`${JSON.stringify(c.manifest)} -> ${c.kind} (${c.why})`, () => {
    eq(runKind(c.manifest), c.kind, JSON.stringify(c.manifest));
  });
}

test('the fixture holds a manifest with no kind, and it is not known', () => {
  eq(fixture.cases.some(c => c.manifest && !('kind' in c.manifest) && c.kind === null), true, 'a manifest with no kind');
  eq(fixture.cases.some(c => c.manifest && !c.manifest.kind && c.kind === 'migration'), false, 'never read as a migration');
});

run('run-kind');
