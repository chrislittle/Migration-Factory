/* STATUS-WORDS-1: help.js's status rule, for a test that draws the run page's
 * row or panel with a stand-in VmfHelp. The rule is lifted with the
 * machineOutcome it closes over, from help.js itself - never a copy here, which
 * would keep passing after help.js changed. */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll } = require('./_harness');

function statusRule() {
  if (!globalThis.WORKING_STATES) {
    const help = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
    const ws = help.match(/const WORKING_STATES = (\[[^\]]+\]);/);
    if (!ws) { throw new Error('WORKING_STATES is not declared in help.js'); }
    // eslint-disable-next-line no-eval
    globalThis.WORKING_STATES = eval(ws[1]);
  }
  return liftAll('help.js', ['machineOutcome', 'machineStatus']).machineStatus;
}

module.exports = { statusRule };
