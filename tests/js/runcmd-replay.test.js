/* RUNCMD-REPLAY-1, independent review finding.
 *
 * When the read-only script after a change could not run, the engine wrote
 * its warning under the step of that script. The activity list showed the
 * label of the script - "Reading the machine name, so that Azure cannot run
 * the last change again on copied disks" - and the sentence that said the
 * opposite was only in the hover. The engine now writes it on its own step,
 * which says itself, and the page's real tables are run here.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const { stepText } = liftAll('migrations.html', ['stepText']);
global.STEP_MAP      = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP       = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE      = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
global.SAYS_ITSELF   = liftConst('migrations.html', 'SAYS_ITSELF');

const said = 'The product ran Set-NvmeReady.ps1, then could not run the read-only script Get-NeutralMark.ps1 twice (no answer). This alone does not stop the move.';

test('the warning that the read-only script did not run shows its own sentence', () => {
  eq(stepText({ step: 'neutralMark', outcome: 'warn', detail: said }), said);
});

test('the warning never shows the label that says the protection is there', () => {
  ok(!stepText({ step: 'neutralMark', outcome: 'warn', detail: said }).includes(global.UX_STEP.guestMark));
});

test('a run of the read-only script that worked keeps its label', () => {
  eq(stepText({ step: 'azureops:runcmd:Get-NeutralMark.ps1', outcome: 'ok' }), global.UX_STEP.guestMark);
  eq(stepText({ step: 'runcmd:neutral-mark.sh' }), global.UX_STEP.guestMark);
});

run('runcmd-replay');
