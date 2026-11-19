/* The help.js rules and Migrations page helpers a page function calls, for a
 * test that lifts that function alone. The REAL functions, lifted from the
 * pages - a stand-in that answered differently would let a test agree with
 * itself.
 *
 *   help(obj)     adds help.js's rules to a VmfHelp stand-in, and returns it
 *   pageGlobals() puts the Migrations page's restore helpers in global scope
 *
 * REBUILD-REMOVE-ACCEPT-1: the identity rule (IDENTITY-LOSS-1) and the rebuild
 * rule (REBUILD-ACCEPT-1) are gone from help.js with the acceptances that read
 * them, and so are the Migrations page's identity and rebuild lists. What is
 * left: previewNames (TEMP-DISK-PREVIEW-1), which the wave editor and Run it
 * draw, isLearnLink (NO-POPUPS-1), planNotesOf (PLAN-NOTES-RUNPAGE-1), which
 * the acceptance and Run it draw, signOffRiskLines (ROLLBACK-CAPACITY-1), the
 * lines under the settings of a wave at both sign-offs, and the restore
 * dialog's words.
 * REBUILD-REMOVE-RECOVER-1: no restore rebuilds, so the dialog names no
 * identity.
 */
'use strict';
const { lift, liftAll } = require('./_harness');

// SQL-TEMPDB-SIGNOFF-1: and the SQL Server rule signOffRiskLines and Run it ask.
const HELP = liftAll('help.js', ['previewNames', 'isLearnLink', 'planNotesOf', 'signOffRiskLines', 'sqlTempdbRisk', 'sqlTempdbEntries']);

function help(obj) {
  return Object.assign(obj ?? {}, HELP);
}

function pageGlobals() {
  globalThis.restoreSiteRecoveryWords = lift('migrations.html', 'restoreSiteRecoveryWords');
}

module.exports = { help, pageGlobals };
