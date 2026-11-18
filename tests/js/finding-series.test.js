/* GEN-V5-1: a finding says which size series it holds a machine back from.
 *
 * Before v5 every blocker blocked every target, so a card never needed to say.
 * Now "Generation 1 machine" blocks v6 and v7 and not v5, and the person
 * choosing a wave's series reads this card to decide. The words come from the
 * engine's own reason (appliesTo), never from a list kept here.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const seriesLine = lift('assessment-report.js', 'seriesLine');
global.T = {
  seriesOnly: 'This applies to {series} only.',
  seriesNotV5: 'This applies to {series} only. A move to v5 does not need this.',
};

test('a reason that spares v5 says so', () => {
  eq(seriesLine(['v6', 'v7']), 'This applies to v6 and v7 only. A move to v5 does not need this.', 'v6 and v7');
});

test('a reason for v5 alone says only that', () => {
  eq(seriesLine(['v5']), 'This applies to v5 only.', 'v5');
});

test('a reason for every series says nothing - it is not news', () => {
  eq(seriesLine(['v5', 'v6', 'v7']), '', 'all three');
});

test('an older reasons file, with no series recorded, says nothing rather than guess', () => {
  eq(seriesLine(undefined), '', 'missing');
  eq(seriesLine([]), '', 'empty');
});

run();