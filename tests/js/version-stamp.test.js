/* VERSION-1: the one description of "which build is this" that the bar, the
 * About dialog and the bug report all draw from.
 *
 * Two facts go in - the dashboard's own stamp and the service's answer - and
 * they arrive at different times: the stamp with the page, the service only
 * after somebody with a role has signed in and the facade has woken up. So
 * every combination is a state the page really shows, and each one has to say
 * something true rather than "undefined".
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const describeVersions = lift('help.js', 'describeVersions');

// The strings, injected: the function must not depend on the page's TEXT.
const T = {
  versionBar: 'Version {v}',
  versionDashboard: 'Dashboard', versionService: 'Service', versionEngine: 'Engine',
  versionBuilt: 'Build {build}, made {when}.',
  versionLocal: 'A local build with no build stamp.',
  versionServiceSignIn: 'Sign in first.',
  versionServicePending: 'Reading it now.',
  versionServiceUnknown: 'The service did not answer.',
  versionEngineDigest: 'The engine runs this image digest.',
  versionEngineUnknown: 'The engine image could not be read.',
  versionSame: 'Same build.',
  versionDiffer: 'Different builds.',
};
const stamped = { version: '0.1.0+1fee594', commit: '1fee594abcdef0123456789', builtUtc: '2026-09-03T12:00:00Z' };
const svc = (v, engine) => ({ service: { version: v, commit: 'aaaaaaa1234', builtUtc: '2026-09-03T12:05:00Z' }, engine });

test('no stamp, no claim: nothing on the bar and nothing to list', () => {
  const d = describeVersions(null, null, T);
  eq(d.bar, null, 'bar');
  eq(d.rows, [], 'rows');
  eq(d.verdict, null, 'verdict');
});

test('the bar and the row show the NUMBER; the build is named as a build, never a commit', () => {
  const d = describeVersions(stamped, null, T);
  eq(d.bar, 'Version 0.1.0', 'bar');
  eq(d.rows[0].value, '0.1.0', 'the row shows the number a person can read');
  eq(d.rows[0].full, '0.1.0+1fee594', 'the full string is kept for bug reports');
  ok(d.rows[0].note.startsWith('Build 1fee594, made '), 'the note names the short build: ' + d.rows[0].note);
  ok(!d.rows[0].note.includes('abcdef'), 'and only the short build');
  ok(!/commit/i.test(d.rows[0].note), 'and never the developer word');
});

test('a local build says so instead of inventing a commit', () => {
  const d = describeVersions({ version: '0.1.0+local', commit: null, builtUtc: null }, null, T);
  eq(d.bar, 'Version 0.1.0', 'bar');
  eq(d.rows[0].note, T.versionLocal, 'local note');
});

test('before anybody with a role has signed in, the service row says to sign in', () => {
  const d = describeVersions(stamped, null, T);
  eq(d.rows[1].label, 'Service', 'service row exists');
  eq(d.rows[1].value, null, 'no value yet');
  eq(d.rows[1].note, T.versionServiceSignIn, 'sign-in note');
  eq(d.verdict, null, 'no verdict on one fact');
});

test('while the service is being asked, the row says so - the cold start is a state, not a mystery', () => {
  const d = describeVersions(stamped, { pending: true }, T);
  eq(d.rows[1].value, null, 'no value yet');
  eq(d.rows[1].note, T.versionServicePending, 'pending note');
  eq(d.verdict, null, 'no verdict yet');
});

test('a service that failed to answer is reported as that', () => {
  const d = describeVersions(stamped, { error: 'HTTP 503' }, T);
  eq(d.rows[1].note, T.versionServiceUnknown, 'unknown note');
  eq(d.verdict, null, 'no verdict without an answer');
});

test('same build on both sides is said in one sentence', () => {
  const d = describeVersions(stamped, svc('0.1.0+1fee594', { digest: 'sha256:0123456789abcdef0123456789abcdef', note: null }), T);
  eq(d.verdict, T.versionSame, 'verdict');
  eq(d.rows[1].value, '0.1.0', 'service number');
  eq(d.rows[1].full, '0.1.0+1fee594', 'service full version');
  eq(d.rows[2].label, 'Engine', 'engine row');
  eq(d.rows[2].value, '0123456789ab', 'digest shortened, sha256: prefix dropped');
  eq(d.rows[2].note, T.versionEngineDigest, 'digest note');
});

test('different builds are called different, which is the fact during a half-finished deploy', () => {
  const d = describeVersions(stamped, svc('0.1.0+9999999', { digest: null, tag: 'dev', note: 'runs a tag' }), T);
  eq(d.verdict, T.versionDiffer, 'verdict');
  eq(d.rows[2].value, 'dev', 'a tag is shown as the tag');
  eq(d.rows[2].note, 'runs a tag', "the service's own note wins over the generic one");
});

test('an engine nobody could read is unknown, never a version', () => {
  const d = describeVersions(stamped, svc('0.1.0+1fee594', { digest: null, tag: null, note: null }), T);
  eq(d.rows[2].value, null, 'no value');
  eq(d.rows[2].note, T.versionEngineUnknown, 'unknown note');
});

test('no update model is said, even when an older service still sends one (PIPELINE-LATER-1)', () => {
  // A person runs every update, so the About dialog has no line about who
  // does. A service deployed before the change still answers updatedBy.
  const older = Object.assign(svc('0.1.0+1fee594', { digest: 'sha256:abc', note: null }), { updatedBy: { model: 'pipeline', principalId: null } });
  eq(Object.keys(describeVersions(stamped, older, T)).sort().join(','), 'bar,rows,verdict', 'an older service');
  eq(Object.keys(describeVersions(stamped, svc('0.1.0+1fee594', {}), T)).sort().join(','), 'bar,rows,verdict', 'a current service');
  eq(Object.keys(describeVersions(stamped, null, T)).sort().join(','), 'bar,rows,verdict', 'before the service has answered');
});

run('version-stamp');
