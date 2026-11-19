/* WAVE-NAME-1: a wave name is made usable as it is typed.
 *
 * A wave name becomes a file name - approvals/<wave>.json - and it keys the
 * quota record and the schedule, so the service refuses anything outside
 * [A-Za-z0-9._-] that does not start with a letter or a number.
 *
 * That refusal used to arrive at SAVE, after the arranging was done. The owner
 * could not see it at all: "I can edit them fine in the demo view" - and he
 * could, because demo mode never calls the service.
 *
 * These hold the rule itself. ManualNavigation-style drift is covered
 * separately: a Pester test reads the pattern out of Set-VmfWavePlan.ps1 and
 * fails if the two ever disagree.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const sanitiseWaveName = lift('waves.html', 'sanitiseWaveName');

// The service's own rule, restated here so a case cannot be "fixed" into
// something the service would still refuse.
const SERVICE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/;
const usable = (s) => SERVICE.test(s);

test('the case that started it: a space becomes a dash', () => {
  eq(sanitiseWaveName('First Five'), 'First-Five', 'the owner\u2019s example');
  ok(usable(sanitiseWaveName('First Five')), 'and the service would take it');
});

test('a run of rubbish becomes ONE dash, not one each', () => {
  eq(sanitiseWaveName('wave   one'), 'wave-one', 'three spaces, one dash');
  eq(sanitiseWaveName('a  /  b'), 'a-b', 'punctuation and spaces together');
});

test('it must start with a letter or a number', () => {
  eq(sanitiseWaveName('  -leading'), 'leading', 'the dash we would have added is dropped too');
  eq(sanitiseWaveName('!!!prod'), 'prod', 'and so is anything else');
});

test('it never ends on the character we added', () => {
  eq(sanitiseWaveName('trailing '), 'trailing', 'a trailing space leaves no dash');
  eq(sanitiseWaveName('wave-'), 'wave', 'nor does one the person typed');
});

test('what is already usable is left exactly alone', () => {
  for (const name of ['prod-1', 'wave.2', 'canary_A', 'a', 'A1._-b']) {
    eq(sanitiseWaveName(name), name, `${name} is untouched`);
    ok(usable(name), `${name} is usable to begin with`);
  }
});

test('nothing usable gives nothing back, so the caller can keep the old name', () => {
  for (const junk of ['', '   ', '!!!', '---', null, undefined]) {
    eq(sanitiseWaveName(junk), '', `${JSON.stringify(junk)} yields nothing`);
  }
});

test('it stops at the length the service accepts, and still not on a dash', () => {
  const long = 'a'.repeat(80);
  eq(sanitiseWaveName(long).length, 63, 'cut to 63');
  ok(usable(sanitiseWaveName(long)), 'and still usable');
  // The cut must not leave the name ending on a character we introduced.
  const cutOnDash = 'a'.repeat(63) + ' tail';
  ok(!sanitiseWaveName(cutOnDash).endsWith('-'), 'no trailing dash after the cut');
  ok(usable(sanitiseWaveName(cutOnDash)), 'still usable after the cut');
});

test('EVERY result the service would refuse is a bug here', () => {
  const typed = ['First Five', 'a b c', '  spaced  ', '!!!x', 'x'.repeat(200),
                 'wave/one', 'wave:one', 'ünïcode name', 'tab\tname', '9lives'];
  for (const t of typed) {
    const out = sanitiseWaveName(t);
    if (out === '') { continue; }          // nothing usable is a valid answer
    ok(usable(out), `"${t}" became "${out}", which the service would refuse`);
  }
});

run('wave-name');
