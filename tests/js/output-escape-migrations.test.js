/* OUTPUT-ESCAPE-1, the Migrations page: text from a customer machine or from
 * Azure is drawn as text.
 *
 * RUN, not read: the page's own machine panel (openDrill and the cards it
 * draws), its activity feed (renderEvents) and the three dialogs that write
 * their description as markup (rawDesc: askAcceptOptions, askApprove,
 * askResolve), with the page's own encoder and words, fed hostile values in
 * every field a machine, Azure or a person fills:
 *   the machine name, what the guest scripts report (script, version, result,
 *   evidence), Azure's error text in a step's detail, a person's note on a
 *   restore, the account that did it.
 * html-sinks.test.js reads every page; this proves the reading on the screens
 * that show the most outside text.
 */
'use strict';
// MADE-DISK-SHOWN-1: the machines whose (?) of the made disks is open.
globalThis.madeHelpOpen = new Set();
const { lift, liftAll, liftConst, test, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();
const identity = require('./_identity');
const H = require('./_hostile');

const esc = H.pageEsc('migrations.html');
globalThis.esc = esc;
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
// REBUILD-PATCH-MODE-1: the line of a rebuild's list, with its link.
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.CHECKPOINT_TEXT = liftConst('migrations.html', 'CHECKPOINT_TEXT');
globalThis.UX_PATH = { A: 'In place', B: 'Rebuild' };
globalThis.STEP_MAP = [];
globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];
globalThis.stopReasons = new Map([['permissionsMissing', { code: 'permissionsMissing', title: 'A permission is missing', whatToDo: 'Grant it.' }]]);
globalThis.retryLines = {};

// The page's own small helpers.
const page = liftAll('migrations.html', ['openDrill', 'capacityLine', 'agoSpan', 'drillKey', 'machineTimeline', 'attemptStop', 'currentStop',
  'whyStoppedCard', 'stopControls', 'powerOwed', 'volumesCheckOffer', 'volumesCheckStarted', 'volumesStartedLine', 'powerName', 'retryHeld', 'decisionWaiting', 'putBackControls', 'finishOffered', 'machinePill',
  'shownState', 'restoredPill', 'statePill', 'checkpointLine', 'restoredNoteHtml', 'restoreEarlierDisks', 'recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml', 'recordDiskIdsInUse', 'rollbackOriginalDisks', 'rollbackOriginalsHtml', 'diskDeleteHtml', 'machineStatusOf', 'statusWord', 'statusPill', 'timelineDuration', 'activityLines', 'timelineLine', 'restoreEndAfter', 'restoreEndCard', 'guestRunPill', 'stepText',
  'renderEvents', 'feedFailNote', 'foldedCallLines', 'rollbackFollows', 'stepRetried', 'retriedText', 'retryFacts', 'askResolve', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords']);
for (const [k, v] of Object.entries(page)) { if (k !== 'openDrill' && k !== 'renderEvents') { globalThis[k] = v; } }

// The machine name is whatever Azure says the machine is called.
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.techText = (s) => String(s ?? '');
globalThis.ago = () => '5 minutes ago';
globalThis.notMovedReasons = () => null;
globalThis.notMovedHtml = () => '';
globalThis.latestClaims = [];
globalThis.latestEvents = [];
// BRAKE-WAIT-WORDS-1: the wave safety brake, as the refresh keeps it.
globalThis.latestHalted = false;
globalThis.canOperate = () => true;
globalThis.canApprove = () => true;
globalThis.restoreInFlight = () => null;
globalThis.rebuildInFlight = () => null;
globalThis.restoreOffered = () => true;
globalThis.restoreWaitsForMove = () => false;
globalThis.VmfHelp = identity.help({
  machineOutcome: (d) => (d?.restore ? 'putBack' : d?.state === 'MIGRATED' ? 'migrated' : 'other'),
  seriesLabel: lift('help.js', 'seriesLabel'), approvalRequired: lift('help.js', 'approvalRequired'),
  explainAction: (e) => e.message, VmfRun: { link: (p) => p }, idKey: (id) => String(id == null ? '' : id).toLowerCase(),
});
identity.pageGlobals();
globalThis.isPutBack = (d) => VmfHelp.machineOutcome(d) === 'putBack';
// STATUS-WORDS-1: the pill of the panel asks help.js's status rule.
globalThis.VmfHelp.machineStatus = require('./_status').statusRule();
// RESTORE-EARLIER-DELETE-1: Delete these disks asks help.js whether a job works on the machine.
globalThis.VmfHelp.machineAtWork = liftAll('help.js', ['machineHold', 'machineAtWork']).machineAtWork;
globalThis.UX_RAN = liftConst('migrations.html', 'UX_RAN');
// MADE-DISK-DELETE-1: the slide-out delete of disks on the panel, closed.
globalThis.DISK_DELETE = liftConst('migrations.html', 'DISK_DELETE');
globalThis.diskDelete = null;
globalThis.markDialogStale = () => false;
globalThis.refocusDrill = () => { };
globalThis.revealDiskDelete = () => { };
globalThis.fillRetrySeries = () => { };
globalThis.currentRun = 'run-1';
globalThis.runSeg = () => 'run-1';
globalThis.noteField = () => ({ id: 'note', required: true });
let drawn = '';
globalThis.drawDrill = (html) => { drawn = html; return false; };

// A name has no slash in it - the id is cut at the last one.
const NAME = `web${H.TAG}${H.QUOTE}${H.SQUOTE}<b>`;
const VMID = `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${NAME}`;

test('the machine panel draws the name, the guest output and Azure\'s error text as text', () => {
  const doc = {
    vmId: VMID, state: 'NEEDS_DECISION',
    history: [
      { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok', evidenceRef: `evidence/pre${H.ALL}.json` },
      { tsUtc: '2026-10-24T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'permissionsMissing',
        machineState: 'untouched', detail: `(AuthorizationFailed) ${H.ALL}` },
    ],
    guestExecutions: [
      { script: `prep${H.ALL}`, version: H.QUOTE, result: `PASS${H.TAG}`, tsUtc: '2026-10-24T10:00:30Z', evidenceRef: `evidence/g${H.ALL}.json` },
      { script: 'validate', version: '1', result: 'FAIL', tsUtc: '2026-10-24T10:00:40Z', evidenceRef: H.JSURL },
    ],
    captured: { vmConfig: { availabilitySetId: H.ALL } },
  };
  drawn = '';
  page.openDrill(doc, { vmId: VMID, wave: `w1${H.ALL}`, path: 'B' }, VMID);
  ok(drawn.length > 200, 'the panel was drawn');
  H.inert(drawn, 'the machine panel');
  H.shownAsText(drawn, NAME, esc, 'the machine name');
  H.shownAsText(drawn, `(AuthorizationFailed) ${H.ALL}`, esc, 'the Azure error');
});

test('the restore card draws the person\'s note and the account as text', () => {
  const doc = {
    vmId: VMID, state: 'MIGRATED',
    history: [{ tsUtc: '2026-10-24T10:00:00Z', state: 'MIGRATED', outcome: 'ok' }],
    restore: { restoredUtc: '2026-10-24T12:00:00Z', restoredBy: `ops${H.ALL}@example.com`, note: `put it back ${H.ALL}`,
      fromCopy: 'pristine', sizeAfter: `Standard_D2s_v4${H.QUOTE}`, diskIdChanged: true, retainedDiskId: `/x/disks/os${H.ALL}`,
      previousDiskName: `os${H.ALL}`, dataDisks: [{ previousDiskName: `data${H.ALL}`, previousDiskId: 'a', newDiskId: 'b' }] },
    recovery: { diskSource: 'pristine', sizeAfter: H.ALL, controllerAfter: H.ALL, recoveredUtc: '2026-10-24T12:00:00Z', recoveredBy: H.ALL },
    guestExecutions: [],
  };
  drawn = '';
  page.openDrill(doc, { vmId: VMID, wave: 'w1', path: 'A' }, VMID);
  H.inert(drawn, 'the restore card');
  H.shownAsText(drawn, `put it back ${H.ALL}`, esc, 'the note');
});

test('the activity feed draws Azure\'s error text, the machine and the step as text', () => {
  const rows = [];
  const tbody = { set innerHTML(v) { rows.length = 0; if (v) { rows.push(v); } }, get innerHTML() { return rows.join(''); },
    insertAdjacentHTML(_where, html) { rows.push(html); } };
  const el = () => ({ classList: { toggle() { } }, hidden: false, textContent: '' });
  const parts = { '#event-table tbody': tbody, '#event-scroll': el(), '#ev-toggle': el(), '#ev-count': el() };
  globalThis.$ = (sel) => parts[sel];
  globalThis.FEED_RECENT = 50;
  globalThis.showWholeLog = false;
  globalThis.toggleWholeLog = () => { };
  page.renderEvents([
    { tsUtc: '2026-10-24T10:00:00Z', step: `precheck${H.ALL}`, outcome: 'fail', vmId: VMID, detail: `(Conflict) ${H.ALL}` },
    { tsUtc: '2026-10-24T10:01:00Z', step: 'rollback', outcome: 'ok', vmId: VMID, detail: `Put back. ${H.ALL}` },
    { tsUtc: '2026-10-24T10:02:00Z', step: 'capacity', outcome: 'refused', detail: `Wave ${H.ALL} waits.` },
    { tsUtc: '2026-10-24T10:03:00Z', step: `x${H.ALL}`, outcome: 'warn', vmId: VMID },
  ]);
  const html = rows.join('');
  ok(rows.length >= 4, 'four rows');
  H.inert(html, 'the activity feed');
  H.shownAsText(html, `(Conflict) ${H.ALL}`, esc, 'the Azure error');
});

/* The three dialogs that write their description as markup (rawDesc). The
 * page reader allows `desc` on the strength of these. */
let modal = null;
globalThis.openModal = (o) => { modal = o; };
globalThis.apiFetch = async () => ({});
globalThis.DEMO_MODE = false;
globalThis.leverKeepDays = (n) => `${Number(n ?? 7)} days`;
globalThis.newIdentityNames = (entries) => (entries ?? []).map(e => vmName(e.vmId));
globalThis.anTurnsOnNames = (entries) => (entries ?? []).map(e => vmName(e.vmId));
globalThis.anDecidedNames = (entries) => (entries ?? []).map(e => vmName(e.vmId));
globalThis.kernelUpdateNames = (entries) => (entries ?? []).map(e => vmName(e.vmId));
globalThis.diskChangeTexts = (entries) => (entries ?? []).map(e => `${vmName(e.vmId)}: ${H.ALL}`);
globalThis.driverLeverOf = (entries) => ((entries ?? [])[0])?.policy ?? {};
globalThis.decideDoneText = lift('migrations.html', 'decideDoneText');
globalThis.source = { readVersioned: async () => ({ text: planText, version: 'v-1' }) };
const entryOf = (name, principal) => ({ vmId: `/s/rg/vm/${name}`, wave: 'w1', path: 'B',
  assessment: { identityType: 'SystemAssigned', identityPrincipalId: principal, sourceSize: `Standard_D2s_v4${H.QUOTE}` },
  target: { size: `Standard_D2s_v6${H.TAG}`, series: `v6${H.QUOTE}` },
  policy: { requireApproval: true, onSystemAssignedIdentity: 'proceed', capacityGate: 'Reserved' } });
const planText = JSON.stringify({ entries: [entryOf(`app${H.ALL}`, `11111111${H.ALL}`)] });

test('Accept how this wave will run: machine names and accounts are text in the markup description', async () => {
  modal = null;
  await (lift('migrations.html', 'askAcceptOptions'))(`w1`);
  ok(modal && modal.rawDesc === true, 'a markup description');
  H.inert(modal.desc, 'Accept how this wave will run');
});

test('Approve this wave: machine names and accounts are text in the markup description', async () => {
  modal = null;
  await (lift('migrations.html', 'askApprove'))('w1');
  ok(modal && modal.rawDesc === true, 'a markup description');
  H.inert(modal.desc, 'Approve this wave');
});

test('Try this machine again: the stop reason is text in the markup description', () => {
  modal = null;
  globalThis.stopReasons = new Map([['x', { code: 'x', title: `A reason ${H.ALL}` }]]);
  page.askResolve(VMID, { vmId: VMID, state: 'NEEDS_DECISION',
    history: [{ tsUtc: '2026-10-24T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'x', detail: H.ALL }] });
  ok(modal && modal.rawDesc === true, 'a markup description');
  H.inert(modal.desc, 'Try this machine again');
});

run('output-escape-migrations');
