/* PAGE-LOAD-2: the one-call readers of help.js, for a test that counts the
 * per-file reads a page makes.
 *
 * The Migrations page asks the service ONCE for the list and ONCE for the open
 * run (VmfHelp.storeDocs), and its readers answer from that first. A test
 * written to count the reads a fake `source` answers wants the page to read as
 * it does when that one call fails: `storeDocs` here refuses, and the readers
 * are the real ones from help.js, so every read goes to the fake, as before.
 * tests/js/page-load.test.js measures the one call itself. */
'use strict';
const { liftAll } = require('./_harness');

const held = liftAll('help.js', ['heldDepth', 'heldList', 'heldText', 'heldJson', 'heldHas']);
// STORE-HOLDS-ONE-1: the pages ask help.js whether a listing names a file.
const { storeHolds } = liftAll('help.js', ['storeHolds']);
// WAVE-RUNNING-LEASE-1: the Migrations page keeps the run's leases by machine.
const idKey = (id) => String(id == null ? '' : id).toLowerCase();
globalThis.idKey = globalThis.idKey || idKey;
const { leasesByMachine } = liftAll('help.js', ['leasesByMachine']);

/** VmfHelp members for a page whose one call fails. */
function perFileHelp() {
  return {
    heldList: held.heldList, heldText: held.heldText, heldJson: held.heldJson, heldHas: held.heldHas,
    storeDocs: async () => { throw new Error('per-file reads measured here'); },
    leasesByMachine, storeHolds,
  };
}

/** The globals the Migrations page names its one calls with. */
function perFileGlobals() {
  return { LIST_READS: [], RUN_READS: [], cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token' };
}

module.exports = { held, perFileHelp, perFileGlobals };
