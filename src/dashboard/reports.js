'use strict';
const DEMO_MODE = new URLSearchParams(location.search).has('demo');
const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
/* COUNT-1: a count read from the store is not a number until it is made one.
 *
 * Every string on this page goes through esc(). The counts deliberately do
 * not, on the reasoning that arithmetic yields a number - and it does not.
 * `??` only replaces null and undefined, so a string survives it, and
 * `'x' + 0` is concatenation, not addition. A stateCounts value that is not a
 * number therefore reached `<td class="num">${x.migrated}</td>` as markup,
 * on a page whose CSP then allowed inline script and where the access token lives
 * in sessionStorage.
 *
 * Nothing on the way in enforces the schema: run-status.schema.json says
 * these are integers, and the browser never checks. So the page makes them
 * numbers itself, at the point they are computed, rather than escaping them
 * at each of the five places they are rendered - one guard beats five, and a
 * sixth render site added later inherits it.
 *
 * OUTPUT-ESCAPE-1: the render sites now ALSO go through esc(). The page reader
 * (tests/js/html-sinks.test.js) proves a value safe where it is written, and a
 * guard at the point of computing is out of its sight - so both stay.
 */
function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
const vmName = (id) => String(id).split('/').pop();
const PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];

/* ============================ UX-STRINGS-BEGIN ============================
   Same bar as the dashboard: the reader knows what a virtual machine and a
   disk are - nothing else. Linted by tests. */
const UX = {
  // NO-POPUPS-1: the report shows in this page, with a way back and a download.
  reportTitle:    'Migration report',
  reportClose:    'Close the report',
  reportDownload: 'Download the report',
  reportPrint:    'To print the report, download it, then open the file and print it.',
  demoViewer:  'Sample viewer',
  // PAGE-SCALE-REPORTS-1: the page's head, the count tiles, the two tabs and
  // the columns of the one list, in the approved words.
  pageTitle:   'Reports',
  lede:        'The result of each migration, and its full record to download.',
  searchHint:  'Migration or project',
  tabsLabel:   'Report lists',
  tabRuns:     'Migration runs',
  tabRecords:  'Records to download',
  runsIntro:   'Newest first. Select the name of a migration to see its waves, its sign-offs and its issues.',
  tAll:        'Migration runs',
  runsTitle:   'All migration runs',
  tDone:       'Finished',
  tDoneTitle:  'Finished migration runs',
  tDoneNone:   'No migration run is finished.',
  tGoing:      'In progress',
  tGoingTitle: 'Migration runs in progress',
  tGoingNone:  'No migration run is in progress.',
  tAttention:  'Needs attention now',
  tAttentionTitle: 'Migration runs with a machine that waits for a person',
  tAttentionNone:  'No machine waits for a person.',
  setupOnlyTag:  'Not planned',
  tSetupTitle: 'Migrations with no plan',
  tSetupHint:  'A migration with no saved plan. The other counts do not include it.',
  tSetupNone:  'Each migration has a plan.',
  colMigration: 'Migration',
  colProject:  'Project',
  colMachines: 'Machines',
  colOutcome:  'Outcome',
  colChanged:  'Last change',
  // REPORT-THEME-1: the report link is on the row.
  colReport:   'Report',
  // Runs that are in no project.
  loose:       'Outside a project',
  // Rule 11: the detail only shows information, so its way back is Close.
  detailClose: 'Close',
  // OUTCOME-WORDS-1: the outcome column, in words.
  oDone:       'Finished',
  oGoing:      'In progress',
  oAttention:  'Needs attention',
  oMigrated:   '{n} migrated',
  oPutBack:    '{n} restored by a person',
  oRestored:   '{n} rolled back after a failure',
  oWaiting:    '{n} waiting for a person',
  oLeftOut:    '{n} left out',
  oWorking:    '{n} moving now',
  oNotStarted: '{n} not started',
  wavesHead:   'How each wave went',
  wWave:       'Wave',
  wMachines:   'Machines',
  wMigrated:   'Migrated',
  wPutBack:    'Restored',
  wAttention:  'Needs attention',
  wSignoff:    'Sign-off',
  signedBy:    'Approved by',
  noSignoff:   'No approval required',
  // SIGNOFF-READ-1
  noSignoffFound: 'No sign-off found',
  // WAVE-APPROVE-1: a sign-off gives each wave an approval, and a change to
  // the wave removes it.
  signoffAsksAgain: 'Changed after the plan sign-off. Needs an approval again.',
  issuesHead:  'Machines that needed people',
  noIssues:    'No machine needed a person in this run.',
  capacityHead:'Capacity',
  capReserved: 'machines ran on an on-demand capacity reservation',
  // CAPACITY-WORDS-1: the Azure name, as the machine panel says it.
  capOnDemand: 'machines ran with no on-demand capacity reservation',
  openRun:     'Open in the dashboard',
  fullReport:  'Open the full report',
  loadingDetail:'Loading the run...',
  noRuns:      'No migration runs recorded yet.',
  waiting:     'Reading your migrations.',
  // ATTEST-1: the full record of a migration, for administrators.
  recordsTitle: 'Records of each migration',
  recordsHint:  'The full record of a migration: each decision, and each step on each machine, with its time and result. Each record is kept for 90 days, also after the migration is deleted.',
  recordsNone:  'No records are kept yet. A record is kept when a wave finishes, when a machine is restored, when somebody downloads it, and when a migration is deleted.',
  recordsWaiting: 'Reading the records.',
  colRecRun:    'Migration',
  colRecWhy:    'Written because',
  colRecMade:   'Written',
  colRecKept:   'Kept until',
  colRecord:    'Record',
  recRead:      'Download the record',
  recBusy:      'Preparing...',
  recWhy: {
    waveClosed: 'a wave finished',
    // REPORT-AUTO-1: the engine keeps the record with the report after these.
    putBack:    'a machine was restored',
    stopped:    'somebody stopped the migration',
    dailyCheck: 'the daily check found the report out of date',
    downloaded: 'somebody downloaded it',
    deleted:    'the migration was deleted',
  },
  // The downloaded record itself. Times are UTC, as the store keeps them.
  rTitle:      'Migration record',
  rProduct:    'Migration Factory',
  rProject:    'Project',
  rMadeBy:     'Written {when} UTC by {who}, because {why}. Kept until {until} UTC.',
  rFrom:       'Planned from the assessment {a}.',
  rSummary:    'Summary',
  rDecisions:  'Decisions',
  rNoDecisions:'No decision is recorded.',
  rMachines:   'Machines',
  rWhat:       'What',
  rWave:       'Wave',
  rBy:         'By',
  rWhen:       'When (UTC)',
  rNote:       'Note',
  rVersion:    'Version',
  rOutcome:    'Outcome',
  rBefore:     'Before',
  rTarget:     'Target',
  rNow:        'Now',
  rNowFrom:    'The figure for now comes from {basis}.',
  rSize:       'Size',
  rController: 'Disk controller',
  rSteps:      'Steps',
  rStep:       'Step',
  rResult:     'Result',
  rSeconds:    'Seconds',
  rDetail:     'Detail',
  rScripts:    'Scripts run inside the machine',
  rScript:     'Script',
  rHash:       'SHA-256',
  rPutBack:    'Restored {when} UTC by {who}. Size after: {size}.',
  // RETAIN-SHOW-1: the record held this and the document never showed it.
  rCopiesDeleted: '{n} safety copies deleted {when} UTC by {who}. The wave kept them for {days} days.',
  rDailyCleanup:  'the daily cleanup',
  rActivity:   'Activity',
  rRunActivity:'Activity of the migration',
  // REPORT-AUTO-1: what the report used to keep in its engineering appendix.
  rAssessment: 'Assessment',
  rScanned:    'The assessment scanned {n} machines.',
  rScannedOne: 'The assessment scanned 1 machine.',
  rClass:      'Classification',
  // MACHINE-PICK-1: the words the Migrations page uses for these machines.
  rNotChosen:  'Not in this migration',
  rGeneration: 'Generation',
  rDiskArch:   'Disk architecture',
  rIssues:     'Blockers and preparation',
  rPlan:       'Plan',
  rAlternates: 'Other sizes in the plan',
  rPlanNotes:  'Plan notes',
  rCheckpoint: 'Last step it reached',
  rQuota:      'Quota records',
  rRegion:     'Region',
  rZone:       'Zone',
  rFamily:     'Quota family',
  rCores:      'Cores needed',
  rQuotaUse:   'Quota used of limit',
  rState:      'State',
  rNotes:      'Notes',
  outcomeWords: {
    migrated:   'Migrated',
    putBack:    'Restored',
    rolledBack: 'Rolled back after a failure',
    attention:  'Needs a person',
    leftOut:    'Left out',
    working:    'In progress',
    notStarted: 'Not started',
    // RECORD-UNMOVED-1: the Migrations page word for a machine the plan does not move.
    notMoved:   'Not moved',
    unknown:    'Not known',
  },
  stateWords: {
    NEEDS_DECISION:         'Needed a decision',
    FAILED_ROLLED_BACK:     'Rolled back after a failure',
    FAILED_NEEDS_ATTENTION: 'Needed attention',
    PUT_BACK:               'Restored by a person',
    SWAP_LEFT:              'Stopped: finish the restore',
  },
  // RETAIN-UX-1: the safety copies across every migration, and what the
  // daily cleanup will do with them. PAGE-SCALE-REPORTS-1: the card moved here
  // from the Overview with these words, unchanged.
  copiesTitle:  'Safety copies',
  copiesHint:   'A restore of a migrated machine uses these copies. They are kept until its retention ends.',
  // PAGE-SCALE-REPORTS-1 fix round: each count says 1 in the singular
  // (VmfHelp.countWords picks the first word of a pair for 1).
  copiesLine:   '{copies} kept for {machines} across {runs}. {due} due for the next cleanup.',
  copiesNCopies:     ['{n} safety copy', '{n} safety copies'],
  copiesNMachines:   ['{n} machine', '{n} machines'],
  copiesNMigrations: ['{n} migration', '{n} migrations'],
  copiesNone:   'No safety copies are kept right now.',
  copiesUnlocked: '{n} of them carry no lock, so anyone with Contributor rights could delete them.',
  copiesPassNone: 'The daily cleanup has not run since this installation started. It runs every day at 03:30 UTC.',
  copiesPassLine: 'Last daily cleanup {ago}: {examined}, {due}, {started}.',
  copiesNExamined:   ['{n} migration checked', '{n} migrations checked'],
  copiesNExaminedOf: ['{n} of {total} migration checked', '{n} of {total} migrations checked'],
  copiesNDue:        ['{n} machine due', '{n} machines due'],
  copiesNStarted:    ['{n} cleanup started', '{n} cleanups started'],
  copiesPassFail: 'The last daily cleanup reported a problem: {reason}',
  copiesNext:   'Next cleanup at {when}.',
  // RETENTION-CARD-CYCLE-1: the daily cleanup is a cycle of hourly passes.
  copiesPassOpen: 'The daily cleanup that started {ago} is not complete: {examined}, {due}, {started}.',
  copiesNextOpen: 'The next hourly pass continues it at {when}.',
  copiesError:  'The safety copies could not be read: {reason}',
  // LOADING-LINE-1: the box while the safety copies are read.
  copiesReading: 'Reading the safety copies.',
  copiesCol:    'Migration',
  copiesKept:   'Copies kept',
  copiesDue:    'Due next cleanup',
  copiesEarliest: 'Earliest deletion',
  copiesOpen:   'Open',
};
/* ============================= UX-STRINGS-END ============================= */

// NAME-1: displayed technical lines never show bare path letters.
// PATH-NAME-1: A is Azure's own term for it.
const PATH_WORDS = { A: 'In-place upgrade' };
const techText = (s) => String(s ?? '')
  .replace(/\bPath A\b/g, PATH_WORDS.A);


const day = (iso) => iso ? new Date(iso).toLocaleDateString() : '';

// ---------- data source: demo (bundled) or live (blob REST via MSAL) ----------
let cfg = null, msalApp = null, account = null;
async function getToken() {
  const req = { scopes: [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
/* PAGE-LOAD-1: what ONE call to the service gave this load (VmfHelp.storeDocs):
 * the store listed, and each run.json, run-status.json, plan.json and machine
 * record. The readers below answer from it first and ask the service only what
 * it cannot answer (unknown means ask). null when the call failed - then every
 * read goes to the service, as before. */
let held = null;
/* PAGE-SCALE-REPORTS-1: project.json too, for the project's name in each row
 * and in the project choice, and the daily cleanup's record for the Safety
 * copies card. They come in the SAME one call - no read for each row, and no
 * second call for the card (on the Overview it was one more). */
const LIST_READS = ['run.json', 'run-status.json', 'plan.json', 'state/*.json', 'project.json', 'retention-status.json'];
async function blobFetch(path, { asText = false } = {}) {
  const known = asText ? undefined : VmfHelp.heldJson(held, path);
  if (known) { return known.value; }
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asText });
}
async function blobList(prefix, delimiter) {
  const known = VmfHelp.heldList(held, prefix, delimiter);
  if (known) { return known; }
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return VmfHelp.storeList(() => getToken(), cfg.apiUrl, prefix, delimiter);
}
/* COUNT-TRUTH-1: what the MACHINES say happened, for the whole run.
 *
 * The run row used to read `stateCounts` from run-status.json. That document
 * is the engine's feed for the wave it is running - it counts ONE WAVE - so a
 * six-machine run in three waves read "Migrated 2" once its last wave ended.
 * It was never stale; it answered a different question.
 *
 * The service reads each machine's own record and counts by the one
 * definition (Get-VmfMachineOutcome), so the row, the tiles and the wave table
 * below all ask the same question of the same records. The sample data is
 * counted by help.js's twin of that definition, in the same shape. */
function summaryFromDocs(entries, docs) {
  // VMID-CASE-1: one key for one machine, whatever the letter case of its ID -
  // the service keys its count the same way (a PowerShell hashtable ignores
  // case), and PAGE-LOAD-1 counts here what the service counted before.
  const key = (id) => String(id ?? '').toLowerCase();
  const byId = new Map(docs.map(d => [key(d.vmId), d]));
  const waves = new Map();
  // LAB-UX-1: outcomes are counted for the machines the plan MOVES, as the
  // service counts them. A machine given no target is in the plan as MANUAL,
  // never gets a state, and must not read as "not started" on a finished run.
  const moves = (e) => e.path === 'A';
  // NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is not part of
  // the migration, as the service counts it (Test-VmfEntryOutsideRun). It
  // counted as not started, and a finished migration read as going.
  entries = (entries || []).filter(e => e && !VmfHelp.outsideRun(e, byId.get(key(e.vmId)) ?? null));
  for (const e of entries) {
    if (!waves.has(e.wave)) waves.set(e.wave, []);
    waves.get(e.wave).push(e);
  }
  const docsOf = (list) => list.filter(moves).map(e => byId.get(key(e.vmId)) ?? null);
  return {
    total: entries.length,
    outcomes: VmfHelp.outcomeCounts(docsOf(entries)),
    waves: [...waves].map(([wave, list]) => ({ wave, total: list.length, outcomes: VmfHelp.outcomeCounts(docsOf(list)) })),
  };
}
async function liveSummary(run) {
  // PROJECT-4: the bare run in the route, the project beside it - here in the
  // query, because this is a GET - through the one rule that knows how.
  const url = VmfHelp.storeUrl(cfg.apiUrl, `runs/${VmfHelp.VmfRun.routeSegment(run)}/summary`,
    VmfHelp.VmfRun.withProject({}, run));
  const token = await getToken();
  const r = await fetch(url, { cache: 'no-store', headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) { throw new Error(`summary ${run}: HTTP ${r.status}`); }
  return r.json();
}

/* PAGE-SCALE-REPORTS-1: the projects in the store, by name - each folder at
 * the top that holds a project.json (the Assessments page's rule). The listing
 * and the documents come from the one call (held); with no held answer it is
 * one read for each PROJECT, never one for each row. A project document that
 * cannot be read is named by its id. */
async function listProjects() {
  const top = (await blobList('', '/')).prefixes.filter(VmfHelp.runFolderIsRun);
  const out = [];
  await VmfHelp.mapLimited(top, async (p) => {
    // PROJECT-3: the folders beside a project's runs are not runs - the same
    // listing the Projects and Assessments pages read, held to the same rule.
    const inside = await blobList(`${p}/`, '/').then(l => ({ ...l, prefixes: l.prefixes.filter(VmfHelp.runFolderIsRun) })).catch(() => null);
    if (!inside || !inside.names.includes(`${p}/project.json`)) { return; }
    const doc = await blobFetch(`${p}/project.json`).catch(() => null);
    out.push({ id: p, name: (doc && doc.name) || p });
  });
  return out.sort((a, b) => String(a.name).localeCompare(String(b.name)));
}

const source = DEMO_MODE ? {
  async summary(run) {
    const files = DEMO[run] ?? {};
    const docs = Object.keys(files).filter(k => k.startsWith('state/')).map(k => files[k]);
    return summaryFromDocs(files['plan.json']?.entries ?? [], docs);
  },
  async listRuns() { return Object.keys(DEMO); },
  async listProjects() { return DEMO_PROJECTS.map(p => Object.assign({}, p)); },
  async readJson(run, rel) { return structuredClone(DEMO[run]?.[rel] ?? null); },
  async readText(run, rel) { return DEMO[run]?.[rel] ?? null; },
  async listFolder(run, folder) { return Object.keys(DEMO[run] ?? {}).filter(k => k.startsWith(folder + '/')); },
  async exists(run, rel) { return Boolean(DEMO[run]?.[rel]); },
} : {
  summary: liveSummary,
  // PROJECT-1: runs may live inside a project now. One shared rule (help.js).
  async listRuns() { return window.VmfListRuns(blobList); },
  async listProjects() { return listProjects(); },
  async readJson(run, rel) { return blobFetch(`${run}/${rel}`); },
  async readText(run, rel) { return blobFetch(`${run}/${rel}`, { asText: true }); },
  async listFolder(run, folder) { return (await blobList(`${run}/${folder}/`)).names.map(n => n.slice(run.length + 1)); },
  // PAGE-LOAD-1: the listing the page holds says it, when it went this deep.
  async exists(run, rel) {
    const known = VmfHelp.heldHas(held, `${run}/${rel}`);
    if (known !== undefined) { return known; }
    return (await blobList(`${run}/${rel}`)).names.length > 0;
  },
};

// ---------- ATTEST-1: the full record of a migration, for administrators ----------
/* A customer asked for a full log with results, in a readable format, for
 * attestation. The rulings: for the Administrator role - engineering
 * and change management; correct data, not tamper-proofing; kept for 90 days,
 * also after the migration is deleted.
 *
 * The SERVICE builds the record (Export-VmfMigrationRecord) from the store, by
 * the same definitions every other count uses, and keeps it in vmf-records/.
 * This page only asks for it and hands it over as a readable document that
 * prints to PDF (REPORT-AUTO-1 removed the data form: it held nothing more). The one write this page causes is keeping that
 * record - it changes nothing about any migration. */
let isAdmin = false;

async function apiCall(method, route, params, body) {
  const token = await getToken();
  const r = await fetch(VmfHelp.storeUrl(cfg.apiUrl, route, params), {
    method, cache: 'no-store',
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) {
    let detail = '';
    try { detail = (await r.json()).error || ''; } catch { detail = ''; }
    throw new Error(detail || `${route}: HTTP ${r.status}`);
  }
  return r.json();
}

/** The record of one migration, built now. PROJECT-4: the run alone in the
 *  route, the project in the body. */
async function fetchRecord(run) {
  if (DEMO_MODE) { return demoRecord(run); }
  return apiCall('POST', `runs/${VmfHelp.VmfRun.routeSegment(run)}/record`, null, VmfHelp.VmfRun.withProject({}, run));
}
async function fetchKeptRecords() {
  if (DEMO_MODE) { return demoKeptRecords(); }
  return (await apiCall('GET', 'records')).records || [];
}
async function fetchKeptRecord(name) {
  if (DEMO_MODE) { return demoRecord(name.replace(/\.json$/, '')); }
  return apiCall('GET', `records/${encodeURIComponent(name)}`);
}

/** A file handed to the browser to save - nothing opened, nothing run. */
function saveFile(fileName, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a');
  a.href = url; a.download = fileName;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const recordFileName = (rec, ext) =>
  `migration-record-${String((rec.project ? rec.project + '-' : '') + rec.runId).replace(/[^A-Za-z0-9-]/g, '-')}-${String(rec.generatedUtc).slice(0, 10)}.${ext}`;

/* REPORT-THEME-1: the report's stylesheet and mark, asked of the service once.
 * The record looks like the report, and there is ONE copy of that look - the
 * module's. Sample data has no service, and an installation not yet updated
 * has no such route: both give null, and the record is saved plain. The data
 * is the point, so the download never fails for its look. */
let lookAsked = null;
function reportLook() {
  if (DEMO_MODE) { return Promise.resolve(null); }
  if (!lookAsked) {
    lookAsked = apiCall('GET', 'report-style').catch(() => { lookAsked = null; return null; });
  }
  return lookAsked;
}

/* The readable record. EVERY value goes through esc(): the record is built
 * from store data, and notes are typed by people.
 * REPORT-THEME-1: it uses the report's own stylesheet (look.stylesheet) and
 * its cover, sections and tables, and has no style of its own.
 * REPORT-AUTO-1: it is marked with the theme the person sees when they save
 * it, so it opens and prints as they saw it. Only 'dark' or 'light' is ever
 * written - the guard markTheme uses - and anything else is light.
 * DISCLAIMER-1: a record leaves the app, so it ends with the short line,
 * which help.js holds for every page. */
function recordHtml(rec, look, theme) {
  const table = (heads, rows) => rows.length
    ? `<div class="box"><table><tr>${heads.map(h => `<th>${esc(h)}</th>`).join('')}</tr>${
        rows.map(r => `<tr>${r.map(v => `<td>${esc(v ?? '')}</td>`).join('')}</tr>`).join('')}</table></div>`
    : '';
  // The element is named through a variable: the page gate reads the raw file
  // for the tag, and this page carries no rules of its own - it only passes
  // on the service's. A "</" in it would end the block early; in a stylesheet
  // the escaped form means the same.
  // A saved record is opened from disk, so nothing in it may load from the
  // network: a stylesheet with an import or a url() is not used.
  const sheetTag = 'style';
  const sheet = look && typeof look.stylesheet === 'string' && look.stylesheet
    && !/@import|url\s*\(/i.test(look.stylesheet)
    ? `<${sheetTag}>${look.stylesheet.replace(/<\//g, '<\\/')}</${sheetTag}>` : '';
  // The mark is the report's own shape or nothing: an svg of g, rect and path
  // elements with drawing attributes only. A record opened from disk runs
  // script, and a filter that looks for bad things missed three ways in -
  // this one names the only things it lets through.
  const drawing = /^<svg viewBox="[0-9. ]+" aria-hidden="true">(?:<\/?(?:g|rect|path)(?:\s+(?:fill-rule|fill|stroke|stroke-width|stroke-linecap|stroke-linejoin|x|y|width|height|rx|opacity|d)="[-0-9A-Za-z .]*")*\s*\/?>)*<\/svg>$/;
  const logo = look && typeof look.logo === 'string' && drawing.test(look.logo) ? look.logo : '';
  const s = rec.summary || {};
  const summaryRows = Object.keys(UX.outcomeWords).filter(k => Number(s[k]) > 0).map(k => [UX.outcomeWords[k], String(s[k])]);
  const decisions = (rec.decisions || []).map(d => [d.what, d.wave, d.by, d.atUtc, d.note, d.version]);
  const list = (v) => (Array.isArray(v) ? v : []).join(', ');
  // REPORT-AUTO-1: the facts the report's engineering appendix held. The
  // record holds no assessment when the run holds none, and then shows none.
  const assessed = rec.assessment
    ? `<section><h2>${esc(UX.rAssessment)}</h2><p class="muted">${esc(Number(rec.assessment.machines) === 1 ? UX.rScannedOne : UX.rScanned.replace('{n}', String(Number(rec.assessment.machines) || 0)))}</p>${
        table([UX.rClass, UX.rMachines], [...Object.keys(rec.assessment.byClassification || {}).map(k => [k, String(rec.assessment.byClassification[k])]),
          [UX.rNotChosen, String(Number(rec.assessment.notInMigration) || 0)]])}</section>`
    : '';
  const quota = (rec.quotaRecords || []).length
    ? `<section><h2>${esc(UX.rQuota)}</h2>${table([UX.rWave, UX.rRegion, UX.rZone, UX.rSize, UX.rFamily, UX.rCores, UX.rQuotaUse, UX.rState, UX.rNotes],
        rec.quotaRecords.map(q => [q.wave, q.region, q.zone, q.size, q.family, q.vcpus == null ? '' : String(q.vcpus),
          q.quotaLimit == null ? '' : `${q.quotaUsed ?? ''} / ${q.quotaLimit}`, q.state, list(q.notes)]))}</section>`
    : '';
  const machines = (rec.machines || []).map(m => {
    const put = m.putBack ? `<p>${esc(UX.rPutBack.replace('{when}', m.putBack.restoredUtc ?? '').replace('{who}', m.putBack.restoredBy ?? '')
      .replace('{size}', m.putBack.sizeAfter ?? ''))}</p>` : '';
    // The scheduled pass signs as an account, not a person: say what it is.
    const r = m.retention;
    const gone = r && r.deletedUtc ? `<p>${esc(UX.rCopiesDeleted.replace('{n}', String((r.deletedSnapshotIds ?? []).length))
      .replace('{when}', r.deletedUtc).replace('{who}', r.deletedBy === 'retention (scheduled)' ? UX.rDailyCleanup : (r.deletedBy ?? ''))
      .replace('{days}', String(r.keepDays ?? '')))}</p>` : '';
    return `<h3>${esc(m.name)} &middot; ${esc(UX.outcomeWords[m.outcome] ?? m.outcome)}</h3>
      <p class="os">${esc(m.vmId)}${m.wave ? ' &middot; ' + esc(UX.rWave) + ' ' + esc(m.wave) : ''}</p>
      ${table(['', UX.rSize, UX.rController], [
        [UX.rBefore, m.before?.size, m.before?.controller], [UX.rTarget, m.target?.size, m.target?.controller], [UX.rNow, m.now?.size, m.now?.controller]])}
      <p class="key">${esc(UX.rNowFrom.replace('{basis}', m.now?.basis ?? ''))}</p>
      ${m.assessment ? `<h4>${esc(UX.rAssessment)}</h4>` + table([UX.rClass, UX.rGeneration, UX.rDiskArch, UX.rIssues],
        [[m.assessment.classification, m.assessment.generation, m.assessment.diskArchitecture, list(m.assessment.issues)]]) : ''}
      ${list(m.sizeAlternates) || list(m.planNotes) || m.pathCheckpoint ? `<h4>${esc(UX.rPlan)}</h4>` + table([UX.rAlternates, UX.rPlanNotes, UX.rCheckpoint],
        [[list(m.sizeAlternates), list(m.planNotes), m.pathCheckpoint]]) : ''}
      ${put}
      ${gone}
      ${(m.steps || []).length ? `<h4>${esc(UX.rSteps)}</h4>` + table([UX.rWhen, UX.rStep, UX.rResult, UX.rSeconds, UX.rDetail],
        m.steps.map(x => [x.tsUtc, x.state, x.outcome, x.durationSec == null ? '' : String(x.durationSec), x.detail])) : ''}
      ${(m.guestScripts || []).length ? `<h4>${esc(UX.rScripts)}</h4>` + table([UX.rWhen, UX.rScript, UX.rVersion, UX.rResult, UX.rHash],
        m.guestScripts.map(x => [x.tsUtc, x.script, x.version, x.result, x.sha256])) : ''}
      ${(m.activity || []).length ? `<h4>${esc(UX.rActivity)}</h4>` + table([UX.rWhen, UX.rStep, UX.rResult, UX.rDetail],
        m.activity.map(x => [x.tsUtc, x.step, x.outcome, x.detail])) : ''}`;
  }).join('');
  const made = UX.rMadeBy.replace('{when}', rec.generatedUtc ?? '').replace('{who}', rec.generatedBy ?? '')
    .replace('{why}', UX.recWhy[rec.reason] ?? rec.reason ?? '').replace('{until}', rec.keepUntilUtc ?? '');
  const mark = theme === 'dark' ? 'dark' : 'light';
  // Joined as text, as markTheme does: the attribute is for the stylesheet
  // in the saved file, not a binding on this page.
  const root = '<html lang="en" data-theme="' + mark + '">';
  return `<!doctype html>${root}<head><meta charset="utf-8"><title>${esc(UX.rTitle)} - ${esc(rec.runId)}</title>${sheet}</head>
<body><div class="sheet"><header class="cover"><div class="brandline">${logo} ${esc(UX.rProduct)}</div><h1>${esc(UX.rTitle)}</h1><dl class="meta">
<div><dt>${esc(UX.colRecRun)}</dt><dd class="mono">${esc(rec.runId)}</dd></div>
${rec.project ? `<div><dt>${esc(UX.rProject)}</dt><dd>${esc(rec.project)}</dd></div>` : ''}
</dl></header>
<section><p class="muted">${esc(made)}</p>
${rec.fromAssessment ? `<p class="muted">${esc(UX.rFrom.replace('{a}', rec.fromAssessment))}</p>` : ''}</section>
<section><h2>${esc(UX.rSummary)}</h2>${table([UX.rOutcome, UX.rMachines], summaryRows)}</section>
<section><h2>${esc(UX.rDecisions)}</h2>${decisions.length ? table([UX.rWhat, UX.rWave, UX.rBy, UX.rWhen, UX.rNote, UX.rVersion], decisions) : `<p class="muted">${esc(UX.rNoDecisions)}</p>`}</section>
${assessed}
${quota}
<section><h2>${esc(UX.rMachines)}</h2>${machines}</section>
${(rec.runActivity || []).length ? `<section><h2>${esc(UX.rRunActivity)}</h2>` + table([UX.rWhen, UX.rStep, UX.rResult, UX.rDetail],
  rec.runActivity.map(x => [x.tsUtc, x.step, x.outcome, x.detail])) + '</section>' : ''}
<p class="disclaimer">${esc(VmfHelp.disclaimerLine)}</p>
</div></body></html>`;
}

/** The record, as the readable page that prints to PDF. REPORT-AUTO-1: the
 *  one download - the data form of the same record held nothing more. Marked
 *  with the theme this page SHOWS when the person saves it: VmfTheme.current()
 *  is light or dark even when they follow the system. */
async function downloadRecord(getRecord, btn) {
  const was = btn.textContent;
  // RECORD-DELETE-1: the message an earlier download left goes when the next
  // download starts. A message the page load left stays.
  const err = $('#err');
  if (recordRefusal && err.textContent === recordRefusal) { err.textContent = ''; err.style.display = 'none'; }
  recordRefusal = '';
  btn.disabled = true; btn.textContent = UX.recBusy;
  try {
    const rec = await getRecord();
    const theme = window.VmfTheme ? window.VmfTheme.current() : 'light';
    saveFile(recordFileName(rec, 'html'), recordHtml(rec, await reportLook(), theme), 'text/html');
  } catch (e) {
    // RECORD-DELETE-1: a press is an action, so a refusal shows its sentence,
    // not its code - the service refuses a download while a delete runs.
    recordRefusal = VmfHelp.explainAction(e);
    err.textContent = recordRefusal; err.style.display = 'block';
  }
  finally { btn.disabled = false; btn.textContent = was; }
}
/** The message the last download left on the page, or nothing. */
let recordRefusal = '';
function recordButton(attr, value) {
  return `<button type="button" class="btn small" ${attr}="${esc(value)}">${esc(UX.recRead)}</button>`;
}

/* PAGE-SCALE-REPORTS-1: the kept records, as the second tab of the one list
 * (an administrator's only). They are read once, beside the walk of every run;
 * the list escapes every value. */
let kept = [];
// Why the records could not be read, or nothing.
let keptError = '';
// True while the records are read.
let keptReading = false;

async function loadRecords() {
  // ATTEST-1: the records are the Administrator role's - engineering and
  // change management. The service refuses anybody else; this only decides
  // whether to offer them.
  isAdmin = DEMO_MODE || (await VmfHelp.myRoles(cfg, getToken, msalApp)).roles.includes('Vmf.Admin');
  if (!isAdmin) { return; }
  keptReading = true;
  renderTable();
  try { kept = await fetchKeptRecords(); keptError = ''; }
  catch (e) { kept = []; keptError = VmfHelp.explain(e); }
  finally { keptReading = false; }
  renderTable();
}

/* One kept record as a row of the list. A record outlives its migration (90
 * days, also after a delete), so its name has no address: a deleted migration
 * has no page to open. It is named by the day the migration was made, when the
 * page holds that migration. */
function recordRow(k, created) {
  const projectId = k.Project || null;
  const id = VmfHelp.VmfRun.storePath(projectId, k.RunId);
  return {
    id, projectId, project: projectName(projectId),
    name: VmfHelp.runTitle(projectName(projectId), 'migration', created.get(id) || null),
    why: UX.recWhy[k.Reason] ?? k.Reason,
    written: day(k.GeneratedUtc),
    kept: day(k.KeepUntilUtc),
    actions: [{ text: UX.recRead, action: 'record', value: k.Name }],
  };
}

/** The records, newest first, as rows. */
function recordRows(list) {
  const created = new Map((list || []).map(x => [x.r, x.createdUtc]));
  return kept.slice().sort((a, b) => String(b.GeneratedUtc).localeCompare(String(a.GeneratedUtc)))
    .map(k => recordRow(k, created));
}

function recordColumns() {
  return [
    { head: UX.colRecRun, kind: 'name' },
    { head: UX.colRecWhy, kind: 'text', key: 'why' },
    { head: UX.colRecMade, kind: 'text', key: 'written' },
    { head: UX.colRecKept, kind: 'text', key: 'kept' },
    { head: UX.colRecord, kind: 'actions', key: 'actions' },
  ];
}

/* The two tabs: the migration runs (the tiles' rows) and the records. Only an
 * administrator has the records, so anybody else has no tabs - the list is
 * the runs, as it was. */
function reportTabs(list) {
  if (!isAdmin) { return []; }
  return [
    { key: 'runs', label: UX.tabRuns, intro: UX.runsIntro },
    { key: 'records', label: UX.tabRecords,
      list: { title: UX.recordsTitle, intro: UX.recordsHint, rows: recordRows(list), columns: recordColumns(),
              empty: keptError || (keptReading ? UX.recordsWaiting : UX.recordsNone) } },
  ];
}

/* MANUAL-SHOTS-1: ?demo: the size and disk controller of a sample machine
 * before, as the target, and now - from its plan entry, and from a restore. */
function demoSizes(entry, doc) {
  const controller = (size) => (/_v[67]$/.test(String(size ?? '')) ? 'NVMe' : 'SCSI');
  const before = { size: entry?.assessment?.sourceSize, controller: controller(entry?.assessment?.sourceSize) };
  const target = { size: entry?.target?.size, controller: controller(entry?.target?.size) };
  const nowSize = doc?.restore?.sizeAfter ?? (doc?.state === 'MIGRATED' ? target.size : before.size);
  return { before, target, now: { size: nowSize, controller: controller(nowSize), basis: 'sample data' } };
}
/* ?demo: a record built from the sample data, so the sample shows what a real
 * one looks like. The real one is the service's. */
function demoRecord(run) {
  const files = DEMO[run] ?? {};
  const docs = Object.keys(files).filter(k => k.startsWith('state/')).map(k => files[k]);
  const entries = files['plan.json']?.entries ?? [];
  const s = summaryFromDocs(entries, docs);
  return {
    schemaVersion: 3, runId: VmfHelp.VmfRun.parse(run).run, project: VmfHelp.VmfRun.parse(run).project || null,
    fromAssessment: null, createdUtc: files['run.json']?.createdUtc,
    generatedUtc: new Date().toISOString(), generatedBy: UX.demoViewer, reason: 'downloaded',
    keepUntilUtc: new Date(Date.now() + 90 * 864e5).toISOString(), summary: s.outcomes,
    decisions: Object.keys(files).filter(k => k.startsWith('approvals/')).map(k => ({ what: 'approved the wave',
      wave: k.slice(10, -5), by: files[k].approvedBy?.identity, atUtc: files[k].approvedUtc, note: files[k].note, version: null })),
    machines: docs.map(d => ({ vmId: d.vmId, name: VmfHelp.machineName(d.vmId, d), wave: entries.find(e => e.vmId === d.vmId)?.wave,
      state: d.state, outcome: VmfHelp.machineOutcome(d), ...demoSizes(entries.find(e => e.vmId === d.vmId), d),
      steps: (d.history ?? []).map(h => ({ tsUtc: '', state: h.state, outcome: '', detail: h.detail })), guestScripts: [],
      putBack: d.restore ?? null, retention: d.retention ?? null, activity: [] })),
    runActivity: [], assessment: null, quotaRecords: [],
  };
}

// ---------- summary loading ----------
let rows = [];
let openRunId = VmfHelp.VmfRun.fromQuery(location.search);
// WAIT-1: true until the store has been read.
// LOADING-LINE-1: null once the read FAILED - not reading, and nothing read,
// so the list says the read failed rather than "none".
let reading = true;
const byNewest = (a, b) =>
  (Date.parse(b.updatedUtc ?? b.createdUtc ?? 0) || 0) - (Date.parse(a.updatedUtc ?? a.createdUtc ?? 0) || 0);

/* PAGE-LOAD-1: a migration's counts from the machine records the page holds,
 * by the rule the service counts by (summaryFromDocs; VmfHelp.outcomeCounts
 * and the service's Get-VmfOutcomeCounts are held to one fixture,
 * tests/fixtures/machine-outcomes.json). It was one call to the service for
 * each migration on every load. undefined when the page does not hold every
 * record of the run, so the service is asked, as before. */
function heldSummary(run, entries) {
  const folder = `${run}/state/`;
  const listing = VmfHelp.heldList(held, folder);
  if (!listing) { return undefined; }
  const docs = [];
  // The service reads the documents straight inside state/ (Get-VmfStoreNames).
  for (const n of listing.names.filter(x => x.endsWith('.json') && !x.slice(folder.length).includes('/'))) {
    const doc = VmfHelp.heldJson(held, n);
    if (!doc) { return undefined; }
    if (doc.value) { docs.push(doc.value); }
  }
  return summaryFromDocs(entries, docs);
}

async function loadSummaries() {
  // PAGE-LOAD-1: ONE call for the listing and every document a row draws.
  if (!DEMO_MODE) { held = await VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { depth: 4, read: LIST_READS }).catch(() => null); }
  // PAGE-SCALE-REPORTS-1: the projects, by name, for the rows and the project
  // choice - from the same one call.
  const [runs, found] = await Promise.all([source.listRuns(), source.listProjects().catch(() => [])]);
  projects = found;
  // The Safety copies box walks every run that is not an assessment, also one
  // whose documents could not be read (copiesRunIds).
  storeRuns = runs.slice();
  assessmentIds = new Set();
  // STORE-READ-2: one read per run across every run in the store, paced - then
  // two more for a migration (its status and its plan), and two more for one
  // with a plan (its counts and whether it has a report), never more than two
  // at once for one run.
  rows = (await VmfHelp.mapLimited(runs, async r => {
    try {
      /* PERF-MIGRATIONS-TICK-1: the manifest first. An assessment never has
       * run-status.json or plan.json, so both reads answered 404 - and with no
       * plan it was shown here as a migration that never got past setup. It
       * is not a migration (ASSESS-PAGE-1), so it is left out, by the one rule
       * the Migrations page and the daily check ask (RETAIN-KIND-1). */
      const manifest = await source.readJson(r, 'run.json');
      if (VmfHelp.runKind(manifest) === 'assessment') { assessmentIds.add(r); return null; }
      const [status, plan] = await Promise.all([
        source.readJson(r, 'run-status.json'),
        source.readJson(r, 'plan.json'),
      ]);
      const entries = plan?.entries ?? [];
      // RUN-LIFECYCLE-1: a run with no plan was only ever scanned. It is not
      // a migration that happened, so it must not be counted as one - and
      // there is nothing to ask the service about.
      const setupOnly = !entries.length;
      // REPORT-THEME-1: whether the migration has a report, beside its
      // counts, so the row can offer it without being opened.
      const [s, hasReport] = setupOnly ? [null, false] : await Promise.all([
        Promise.resolve((DEMO_MODE ? undefined : heldSummary(r, entries)) ?? source.summary(r)),
        source.exists(r, 'customer-report.html').catch(() => false),
      ]);
      const o = s?.outcomes ?? {};
      return {
        r, createdUtc: manifest?.createdUtc, updatedUtc: status?.updatedUtc,
        setupOnly, hasReport: hasReport === true,
        // NOT-IN-WAVE-QUEUED-1: the machines the summary counts - not a
        // machine in no wave that never ran.
        total: Number.isInteger(s?.total) ? s.total : entries.length,
        waves: new Set(entries.map(e => e.wave)).size,
        migrated: num(o.migrated),
        putBack: num(o.putBack),
        restored: num(o.rolledBack),
        attention: num(o.attention),
        leftOut: num(o.leftOut),
        working: num(o.working),
        notStarted: num(o.notStarted),
      };
    } catch { return null; }
  }, undefined, (done) => {
    // WAIT-1: each run drawn as it lands. Up to five reads per run across every
    // run in the store, so the last is well after the first on a real estate.
    rows = done.filter(Boolean).slice().sort(byNewest);
    renderTable();
  })).filter(Boolean);
  rows.sort(byNewest);
}

/* OUTCOME-WORDS-1: words, not a bar. The column answers "how did it end?",
 * and a bar answers "how far along is it?". Its grey part was put back AND not
 * started yet, so a finished migration with one machine put back read as 83%
 * of the way through. The state leads, so 5 of 6 is not read as unfinished,
 * and the counts say the rest. */
function outcomeState(x) {
  if (!x.total) { return null; }
  if (x.working > 0 || x.notStarted > 0) { return 'going'; }
  if (x.attention > 0) { return 'attention'; }
  return 'done';
}
/* PAGE-SCALE-REPORTS-1: the outcome as the list's tag, the counts behind it
 * as the note after it. The tiles that counted machines across every run are
 * gone, so each row says how many waited for a person too. */
function outcomeTag(x) {
  const st = outcomeState(x);
  if (!st) { return null; }
  const parts = [];
  const add = (n, words) => { if (n) { parts.push(words.replace('{n}', n)); } };
  add(x.migrated, UX.oMigrated); add(x.putBack, UX.oPutBack); add(x.restored, UX.oRestored);
  add(x.attention, UX.oWaiting); add(x.leftOut, UX.oLeftOut); add(x.working, UX.oWorking); add(x.notStarted, UX.oNotStarted);
  const tag = st === 'done' ? { text: UX.oDone, tone: 'good' }
    : st === 'attention' ? { text: UX.oAttention, tone: 'bad' } : { text: UX.oGoing, tone: 'quiet' };
  return Object.assign(tag, { note: parts.join(', ') });
}

/* ---------- PAGE-SCALE-REPORTS-1: count tiles and ONE list ----------
 *
 * With many migrations the page was one long scroll: a table with a row for
 * every migration, then a table with a row for every kept record, each by its
 * raw run id, with no search and no pages. The tiles, the list, its tabs, its
 * project choice, its search and its pages are the shared piece in help.js
 * (VmfHelp.listMount); this page gives it the rows. Nothing is hidden until a
 * person selects: every tile shows its count, and Migration runs holds every
 * migration. */

// PAGE-SCALE-REPORTS-1: every project, { id, name }, for the rows and the
// project choice.
let projects = [];

/** A project's name, by its id - or the words for a run outside a project. */
function projectName(projectId) {
  if (!projectId) { return UX.loose; }
  return (projects.find(p => p.id === projectId) || {}).name || projectId;
}

/* One run as a row of the list. The name is the project and the day the
 * migration was made (VmfHelp.runTitle), the run id small under it. It links
 * to this page with the run in the query, and a click opens the migration's
 * detail below the list (openDetail) - the same address opens it from another
 * tab. RUN-LIFECYCLE-1: a run that never got past setup is not a migration, so
 * it has no count and no report. */
function runRow(x) {
  const projectId = VmfHelp.VmfRun.parse(x.r).project || null;
  const project = projectName(projectId);
  return {
    id: x.r, projectId, project,
    name: VmfHelp.runTitle(project, 'migration', x.createdUtc),
    dest: { page: 'reports', run: x.r },
    open: { action: 'detail', value: x.r },
    outcome: x.setupOnly ? { text: UX.setupOnlyTag, tone: 'quiet' } : outcomeTag(x),
    machines: x.setupOnly ? '' : x.total,
    changed: x.updatedUtc || x.createdUtc || null,
    // REPORT-THEME-1: the report is on the row, when the migration has one.
    actions: x.hasReport && !x.setupOnly ? [{ text: UX.fullReport, action: 'report', value: x.r }] : [],
  };
}

/* The tiles. Migration runs, Finished and In progress count REAL migrations
 * (RUN-LIFECYCLE-1); a run scanned and never planned has its own tile, so it
 * is listed without inflating the numbers somebody reports upwards. Needs
 * attention now holds every migration with a machine that waits for a person,
 * in a run that is still going too. */
function runTiles(list) {
  const real = list.filter(x => !x.setupOnly);
  const of = (keep) => real.filter(keep).map(runRow);
  return [
    // WAIT-1, LOADING-LINE-1: while the page reads, the shared list says UX.waiting.
    { key: 'all', label: UX.tAll, title: UX.runsTitle, empty: UX.noRuns, rows: real.map(runRow) },
    { key: 'done', label: UX.tDone, title: UX.tDoneTitle, empty: UX.tDoneNone, tone: 'good', rows: of(x => outcomeState(x) === 'done') },
    { key: 'going', label: UX.tGoing, title: UX.tGoingTitle, empty: UX.tGoingNone, rows: of(x => outcomeState(x) === 'going') },
    { key: 'attention', label: UX.tAttention, title: UX.tAttentionTitle, empty: UX.tAttentionNone, tone: 'bad', rows: of(x => x.attention > 0) },
    { key: 'setup', label: UX.setupOnlyTag, title: UX.tSetupTitle, hint: UX.tSetupHint, empty: UX.tSetupNone, tone: 'quiet',
      rows: list.filter(x => x.setupOnly).map(runRow) },
  ];
}

function runColumns() {
  return [
    { head: UX.colMigration, kind: 'name' },
    { head: UX.colProject, kind: 'text', key: 'project' },
    { head: UX.colOutcome, kind: 'tag', key: 'outcome' },
    { head: UX.colMachines, kind: 'num', key: 'machines' },
    { head: UX.colChanged, kind: 'ago', key: 'changed' },
    { head: UX.colReport, kind: 'actions', key: 'actions' },
  ];
}

/* The project choice: every project by name, then the runs and records
 * outside a project, when there are any (the Overview's rule). */
function projectChoices(list) {
  const out = projects.map(p => ({ id: p.id, name: p.name }));
  const loose = (list || []).some(x => !VmfHelp.VmfRun.parse(x.r).project) || kept.some(k => !k.Project);
  if (loose) { out.push({ id: VmfHelp.LIST_LOOSE, name: UX.loose }); }
  return out;
}

/* REPORT-THEME-1: the theme goes on the report's root element as a mark.
 *
 * The report runs in a frame with no script (SEC-REPORT-1), so nothing in it
 * can read the person's choice - this page writes it there before the frame
 * gets the report. Only 'dark' or 'light' is ever written; anything else is
 * light. A mark the stored file carries is replaced, not left beside the new
 * one: REPORT-AUTO-1 stores it with none, and a file written before that is
 * marked light. A document with no root element gets one, after
 * its doctype. Nothing else in the report changes. */
function markTheme(html, theme) {
  // The attribute is for the report's stylesheet, not a control on this
  // page, so it is joined as text rather than written as a page binding.
  const marked = '<html data-theme="' + (theme === 'dark' ? 'dark' : 'light') + '"';
  const text = String(html ?? '');
  const root = /<html\b[^>]*>/i;
  if (!root.test(text)) {
    return text.replace(/^(\s*<!doctype[^>]*>)?/i, (doctype) => doctype + marked + '>');
  }
  return text.replace(root, (tag) => tag
    .replace(/\sdata-theme\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/gi, '')
    .replace(/^<html\b/i, marked));
}

/* SEC-REPORT-1. The report is fetched with the viewer's token because the blob
 * is private, and then shown in a SANDBOXED frame.
 *
 * It used to be written straight into the new window:
 *     const w = window.open('', '_blank'); w.document.write(html);
 * A window opened on an empty URL inherits THIS origin, so the report ran as
 * the dashboard - and the dashboard's origin is where MSAL keeps the access
 * token (sessionStorage) and where the CSP then allowed inline script. The report is
 * a document GENERATED from run data by New-VmfReport, so anything that
 * reached it unescaped would have been script running with the viewer's token
 * in reach.
 *
 * Nothing reaches it unescaped today - that was checked field by field. The
 * point is that it was one forgotten Encode away, in a document that gains a
 * section whenever the report grows.
 *
 * `sandbox` with NO tokens is the maximum restriction: a unique opaque origin,
 * and scripting off. It costs nothing, because the report is static - no
 * script, no form, no handler - so it renders and prints exactly as before.
 * Built through the DOM rather than written as markup. DARK-1 says a page
 * holds markup and behaviour, never appearance, so a stylesheet block in this
 * file would be the page carrying CSS - and the gate caught the first cut of
 * this doing exactly that. (It reads the raw file, so it also catches the tag
 * NAMED in a comment, which is why this one describes it instead of spelling
 * it.)
 *
 * REPORT-THEME-1: the report follows the theme this page SHOWS -
 * VmfTheme.current(), which is light or dark even when the person follows the
 * system. choice() can say "system", which is not a palette. The stylesheet
 * reads the mark, and a print follows it (REPORT-AUTO-1).
 *
 * NO-POPUPS-1: the report shows IN THIS PAGE. It opened a new window, and a
 * browser that blocks popups gave window.open null - the page then showed the
 * raw script error that the null caused. Many work tenants block popups, and
 * the product opens none. The frame and its empty sandbox are the same; the window
 * around them is now a view on this page, with Close and Escape (rule 11) and
 * Download the report for the file. The empty sandbox also stops the report
 * from opening a window or moving this page somewhere else. */
const reportShown = {
  run: null, html: '', opener: null,
};

async function openReport(run, opener) {
  const html = await source.readText(run, 'customer-report.html');
  const theme = window.VmfTheme ? window.VmfTheme.current() : 'light';
  const frame = document.createElement('iframe');
  // An EMPTY sandbox attribute is the maximum restriction: a unique opaque
  // origin, and scripting off. Naming any token here - allow-scripts, or
  // allow-same-origin - gives back what this is for.
  frame.setAttribute('sandbox', '');
  frame.setAttribute('title', UX.reportTitle);
  // The look is app.css's (.report-frame): a block frame, no border.
  frame.className = 'report-frame';
  // One frame: a second report takes the place of the first.
  document.getElementById('report-slot').replaceChildren(frame);
  // srcdoc as a PROPERTY, so the report never has to survive attribute
  // escaping on its way in. Marked first: the frame never shows it unmarked.
  frame.srcdoc = markTheme(html, theme);
  reportShown.run = run;
  // The file Download the report saves: the same report, marked the same way.
  reportShown.html = markTheme(html, theme);
  reportShown.opener = opener || null;
  document.getElementById('report-run').textContent = run;
  document.getElementById('report-view').hidden = false;
  document.body.classList.add('report-open');
  document.getElementById('report-close').focus();
}

/** Close the report: the view hides, the frame leaves the page, and the focus
 *  goes back to the button that opened it. */
function closeReport() {
  const view = document.getElementById('report-view');
  if (view.hidden) { return; }
  view.hidden = true;
  document.getElementById('report-slot').replaceChildren();
  document.body.classList.remove('report-open');
  const back = reportShown.opener;
  reportShown.run = null;
  reportShown.html = '';
  reportShown.opener = null;
  if (back && back.focus) { back.focus(); }
}

/** Escape closes the open report. True when it took the key. A key pressed
 *  while the focus is IN the report goes to the frame, which runs no script
 *  and so cannot pass it on - Close is always there, and gets the focus. */
function reportKey(e) {
  if (e.key !== 'Escape') { return false; }
  if (document.getElementById('report-view').hidden) { return false; }
  e.preventDefault();
  closeReport();
  return true;
}

/** The report as a file: the one the view shows, marked with the same theme.
 *  To print it, open the file - a frame in a page prints only what fits in
 *  its box. */
function downloadReport() {
  if (!reportShown.run) { return; }
  saveFile(`migration-report-${String(reportShown.run).replace(/[^A-Za-z0-9-]/g, '-')}.html`,
    reportShown.html, 'text/html');
}

/* PAGE-SCALE-REPORTS-1: the list is mounted ONCE. The page draws again as
 * each run lands (WAIT-1) and when the records arrive, and a list drawn again
 * from nothing would throw away the tile, the tab, the project, the search and
 * the page a person chose. It opens on every migration, as the design shows. */
let reportList = null;
// ?run= opens that migration's detail once, after the store is read.
let detailAsked = false;

function renderTable() {
  if (!reportList) {
    const host = $('#reports-list');
    reportList = VmfHelp.listMount(host, { id: 'rp', preferred: 'all', searchHint: UX.searchHint,
      tabsLabel: UX.tabsLabel, columns: runColumns(), waiting: UX.waiting });
    host.addEventListener('click', onListClick);
  }
  reportList.update({ tiles: runTiles(rows), tabs: reportTabs(rows), projects: projectChoices(rows), reading: reading === true, failed: reading === null });
  openAskedDetail();
}

/* A row's controls are the shared list's; the page listens for their click.
 * REPORT-THEME-1: Open the full report is on the row, and shows the report
 * over this page (NO-POPUPS-1). ATTEST-1: Download the record saves a kept
 * record. The name opens the migration's detail below the list; a click that
 * asks for a new tab or window keeps the address, which opens the same detail
 * there. */
function onListClick(e) {
  const report = e.target.closest('button[data-action="report"]');
  if (report) {
    openReport(report.dataset.value, report).catch(err => {
      $('#err').textContent = VmfHelp.explain(err); $('#err').style.display = 'block';
    });
    return;
  }
  const record = e.target.closest('button[data-action="record"]');
  if (record) { downloadRecord(() => fetchKeptRecord(record.dataset.value), record); return; }
  const link = e.target.closest('a[data-action="detail"]');
  if (!link) { return; }
  if (e.button > 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) { return; }
  if (openDetail(link.dataset.value, link)) { e.preventDefault(); }
}

/* The migration ?run= names (an address from another tab, or the link a row
 * gives), opened once the store is read. */
function openAskedDetail() {
  if (reading || detailAsked) { return; }
  detailAsked = true;
  const id = VmfHelp.VmfRun.fromQuery(location.search);
  if (id) { openDetail(id, null); }
}

/* ---------- the detail of one migration ----------
 * PAGE-SCALE-REPORTS-1: the per-run detail the row opened in the table before
 * - the waves, the machines that needed people, the capacity, and the links -
 * now in a card below the list, opened by the migration's name. It only shows
 * information, so its way back is Close (rule 11), and Escape does the same.
 * The keyboard goes to Close, and comes back to the name when it closes. */
let detailOpener = null;
// The run the detail shows, to find its name in the list after a redraw.
let detailRun = null;

/** The heading of the detail: the row's own name. */
function detailTitle(x) {
  const projectId = VmfHelp.VmfRun.parse(x.r).project || null;
  return VmfHelp.runTitle(projectName(projectId), 'migration', x.createdUtc);
}

/** Open the detail of one migration. false when the page holds no such run. */
function openDetail(run, opener) {
  const x = rows.find(r => r.r === run);
  if (!x) { return false; }
  // EVAL-M14: opening a migration IS choosing a run, so Get help offers it.
  openRunId = run;
  detailOpener = opener || null;
  detailRun = run;
  $('#detail-title').textContent = detailTitle(x);
  $('#detail-run').textContent = run;
  const close = $('#detail-close');
  close.textContent = UX.detailClose;
  $('#detail-body').innerHTML = `<p class="muted">${esc(UX.loadingDetail)}</p>`;
  $('#run-detail').hidden = false;
  close.focus();
  showDetail(run).catch(() => { });
  return true;
}

/** Close the detail: the keyboard goes back to the name that opened it, and
 *  Get help offers whatever the address says. The list draws its rows again
 *  as the page reads (the records arrive later), so the link that opened the
 *  detail can be gone: the name is found in the list as it is now. With no
 *  name on the page shown (an address with ?run=, or another page of the
 *  list), the keyboard goes to the page heading. */
function closeDetail() {
  const card = $('#run-detail');
  if (card.hidden) { return; }
  card.hidden = true;
  $('#detail-body').innerHTML = '';
  openRunId = VmfHelp.VmfRun.fromQuery(location.search);
  const kept = detailOpener && detailOpener.isConnected !== false ? detailOpener : null;
  const now = detailRun ? [...document.querySelectorAll('#reports-list a[data-action="detail"]')].find(a => a.dataset.value === detailRun) : null;
  detailOpener = null;
  detailRun = null;
  const back = now || kept || $('#page-title');
  if (back && back.focus) { back.focus(); }
}

/** Escape closes the open detail. True when it took the key. */
function detailKey(e) {
  if (e.key !== 'Escape') { return false; }
  if ($('#run-detail').hidden) { return false; }
  e.preventDefault();
  closeDetail();
  return true;
}

/** One Escape closes one thing: the report over the page first, then the
 *  detail. */
function onKey(e) {
  if (reportKey(e)) { return; }
  detailKey(e);
}

// ---------- per-run detail (loaded on first expand, then cached) ----------
const detailCache = new Map();
async function buildDetail(run) {
  if (detailCache.has(run)) return detailCache.get(run);
  // REPORT-THEME-1: whether a report exists is read with the runs now, for
  // the row - not here.
  const [plan, stateNames, capNames, apprNames, planApproval, histNames] = await Promise.all([
    source.readJson(run, 'plan.json'),
    source.listFolder(run, 'state').catch(() => []),
    source.listFolder(run, 'capacity').catch(() => []),
    source.listFolder(run, 'approvals').catch(() => []),
    // SIGNOFF-READ-1: PLANRUN-1's sign-off covers every wave in the plan, and
    // is kept beside the plan, not in approvals/. This page read approvals/
    // only, so waves that ran on the plan sign-off showed "Sign-off?".
    source.readJson(run, 'plan-approval.json').catch(() => null),
    // REPORT-RELEASED-1: released reservations whose records were cleared.
    source.listFolder(run, 'capacity-history').catch(() => []),
  ]);
  // STORE-READ-2: one document per machine, paced rather than all at once.
  // PAGE-WAIT-1: the three folders share ONE pacing, instead of waiting for
  // each other in turn.
  const json = (names) => names.filter(n => n.endsWith('.json'));
  const tagged = [...json(stateNames).map(n => ['vm', n]), ...json(capNames).map(n => ['cap', n]),
                  ...json(apprNames).map(n => ['appr', n]), ...json(histNames).map(n => ['hist', n])];
  const read = await VmfHelp.mapLimited(tagged, ([, n]) => source.readJson(run, n));
  const of = (kind) => tagged.map(([k, n], i) => [k, n, read[i]]).filter(([k, , d]) => k === kind && d);
  const docs = of('vm').map(([, , d]) => d);
  const claims = of('cap').map(([, , d]) => d);
  const approvals = new Map(of('appr').map(([, n, d]) => [n.split('/').pop().replace(/\.json$/, ''), d]));

  const byId = new Map(docs.map(d => [d.vmId, d]));
  // NOT-IN-WAVE-QUEUED-1: not a machine in no wave that never ran - the rule
  // the row above counts by (summaryFromDocs).
  const entries = (plan?.entries ?? []).filter(e => e && !VmfHelp.outsideRun(e, byId.get(e.vmId) ?? null));
  const waves = [...entries.reduce((m, e) => {
    if (!m.has(e.wave)) m.set(e.wave, { vms: [] });
    m.get(e.wave).vms.push(e);
    return m;
  }, new Map()).entries()];

  const issues = docs.filter(d => PROBLEM_STATES.includes(d.state) ||
      (d.history ?? []).some(h => PROBLEM_STATES.includes(h.state)))
    .map(d => {
      const h = [...(d.history ?? [])].reverse().find(h => PROBLEM_STATES.includes(h.state)) ?? {};
      // VMID-CASE-1: named from its capture, as Azure spells it on the machine.
      // STATUS-WORDS-1: a stop that a restore ended is no longer open - the
      // restore has its own line below. A restore that worked still showed
      // the stop as open, red, as if a person had to act.
      return { name: VmfHelp.machineName(d.vmId, d), state: h.state ?? d.state, detail: h.detail ?? '',
               open: PROBLEM_STATES.includes(d.state) && VmfHelp.machineOutcome(d) !== 'putBack' };
    });
  // REPORT-RESTORED-1: a put-back a person chose is a different event from the
  // product restoring a machine after a failure, and a reader must be able to
  // tell which happened. It never passes through a problem state, so the list
  // above cannot see it.
  for (const doc of docs.filter(x => VmfHelp.machineOutcome(x) === 'putBack')) {
    const r = doc.restore ?? {};
    issues.push({ name: VmfHelp.machineName(doc.vmId, doc), state: 'PUT_BACK',
                  detail: [r.restoredBy, r.note].filter(Boolean).join(' - '), open: false });
  }
  // FINISH-COUNT-1: a restore that Azure refused a data disk swap left the
  // machine stopped (swapPending). The one definition counts it as waiting
  // for a person, so the put-back loop above does not find it, and its state
  // is not a problem state. It is open until Finish the restore.
  for (const doc of docs.filter(x => VmfHelp.machineOutcome(x) === 'attention' && !PROBLEM_STATES.includes(x.state))) {
    issues.push({ name: VmfHelp.machineName(doc.vmId, doc), state: 'SWAP_LEFT',
                  detail: String(doc.swapPending?.error ?? ''), open: true });
  }
  const reserved = reservedInstances(claims, of('hist').map(([, , d]) => d));
  const onDemand = Math.max(0, entries.length - reserved);
  const d = { waves, byId, issues, reserved, onDemand, approvals, planApproval, total: entries.length };
  detailCache.set(run, d);
  return d;
}

/* REPORT-RELEASED-1: machines placed on a capacity reservation - the live claims,
 * and released reservations kept as history when their records were cleared.
 * A history record counts the machines that USED its reservation
 * (consumedInstances): one released before its wave ran served nobody. It is
 * left out where a live claim still shows the same reservation, or where a
 * live reservation covers the same wave, subscription, region, size and zone -
 * so a wave reserved again is not counted twice. History records are the
 * capacity-history contract: the claim is under .claim. */
function reservedInstances(claims, history) {
  // RESERVING-STUCK-1: a RELEASED claim with no creation time was released
  // before Azure confirmed it, so it held nobody.
  const held = (c) => c && ['RESERVED', 'CONSUMED', 'RELEASED'].includes(c.state) && c.reservation
    && !(c.state === 'RELEASED' && !c.reservation.createdUtc);
  const key = (c) => [c.wave, c.subscriptionId ?? '', c.region ?? '', c.size, c.zone ?? ''].join('|');
  const live = (claims || []).filter(held);
  const covered = new Set(live.map(key));
  const liveIds = new Set(live.map(c => c.reservation.reservationId).filter(Boolean));
  let total = live.reduce((a, c) => a + num(c.demand?.reservableInstances), 0);
  for (const h of (history || []).map(d => d && d.claim).filter(held)) {
    if (liveIds.has(h.reservation.reservationId) || covered.has(key(h))) continue;
    covered.add(key(h));
    total += num(h.reservation.consumedInstances);
  }
  return total;
}

/* SIGNOFF-READ-1: who approved a wave. A wave's own approval first, then the
 * plan sign-off when it names the wave. A plan sign-off with no list of waves
 * is read as covering them all, as the engine reads it.
 * None found is plain text, not a pill: a pill ending in "?" looked like a
 * button, and it did nothing when pressed. */
function signoffCell(d, w, info) {
  const ap = d.approvals.get(w);
  if (ap) {
    return `<span class="pill good" title="${esc(ap.note ?? '')}">${esc(UX.signedBy)} ${esc(ap.approvedBy?.identity ?? '?')}</span>`;
  }
  const pa = d.planApproval;
  const planWaves = Array.isArray(pa?.waves) ? pa.waves : null;
  // SIGNOFF-NULL-1: the engine's rule - a machine that says nothing requires it.
  const requires = info.vms.some(VmfHelp.approvalRequired);
  if (pa && (!planWaves || planWaves.includes(w))) {
    /* WAVE-APPROVE-1: the sign-off wrote this wave its own approval
     * (Approve-VmfPlan writes only v4). With that approval gone, the wave
     * changed after the sign-off, and the sign-off no longer covers it. */
    return requires ? `<span class="warn-text">${esc(UX.signoffAsksAgain)}</span>` : `<span class="muted">${esc(UX.noSignoff)}</span>`;
  }
  return requires ? `<span class="warn-text">${esc(UX.noSignoffFound)}</span>` : `<span class="muted">${esc(UX.noSignoff)}</span>`;
}

/* The waves, the machines that needed people and the capacity of one
 * migration, drawn into the open detail. A detail opened for another run while
 * this one read is left alone. */
async function showDetail(run) {
  const body = $('#detail-body');
  try {
    const d = await buildDetail(run);
    if (openRunId !== run || $('#run-detail').hidden) { return; }
    const waveRows = d.waves.map(([w, info]) => {
      // COUNT-TRUTH-1: the same definition as the row in the list and the tiles.
      const outcomeOf = (vmId) => VmfHelp.machineOutcome(d.byId.get(vmId) ?? null);
      const mig = info.vms.filter(e => outcomeOf(e.vmId) === 'migrated').length;
      const back = info.vms.filter(e => outcomeOf(e.vmId) === 'putBack').length;
      const att = info.vms.filter(e => outcomeOf(e.vmId) === 'attention').length;
      const sign = signoffCell(d, w, info);
      return `<tr><td>${esc(w)}</td>
        <td class="num">${info.vms.length}</td><td class="num">${mig}</td>
        <td class="num">${back ? `<span class="pill warn">${back}</span>` : '0'}</td>
        <td class="num">${att ? `<span class="pill bad">${att}</span>` : '0'}</td><td>${sign}</td></tr>`;
    }).join('');
    const issueList = d.issues.length ? d.issues.map(i =>
      `<p class="issue" title="${esc(i.state)}${i.detail ? ' - ' + esc(i.detail) : ''}">
         <span class="mono">${esc(i.name)}</span>
         <span class="pill ${i.open ? 'bad' : 'quiet'}">${esc(UX.stateWords[i.state] ?? i.state)}</span>
         ${i.detail ? `<span class="tech" title="${esc(i.detail)}">${esc(techText(i.detail))}</span>` : ''}</p>`).join('')
      : `<p class="muted">${esc(UX.noIssues)}</p>`;
    const capLine = `<p class="issue">${esc(d.reserved)} ${esc(UX.capReserved)} &middot; ${esc(d.onDemand)} ${esc(UX.capOnDemand)}</p>`;
    body.innerHTML = `
      <h4>${esc(UX.wavesHead)}</h4>
      <div class="vmf-scroll"><table><thead><tr><th>${esc(UX.wWave)}</th><th class="num">${esc(UX.wMachines)}</th>
        <th class="num">${esc(UX.wMigrated)}</th><th class="num">${esc(UX.wPutBack)}</th><th class="num">${esc(UX.wAttention)}</th><th>${esc(UX.wSignoff)}</th></tr></thead>
        <tbody>${waveRows}</tbody></table></div>
      <h4>${esc(UX.issuesHead)}</h4>${issueList}
      <h4>${esc(UX.capacityHead)}</h4>${capLine}
      <p style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">
        <a class="btn small ghost" href="${VmfHelp.VmfRun.link('migrations.html', run)}" style="text-decoration:none">${esc(UX.openRun)}</a>
        ${isAdmin ? recordButton('data-record', run) : ''}</p>`;
    // ATTEST-1: the migration's full record, built now, for an administrator.
    // REPORT-THEME-1: the report link is on the row in the list, not here.
    body.querySelectorAll('[data-record]').forEach(b => b.addEventListener('click', () =>
      downloadRecord(() => fetchRecord(b.dataset.record), b)));
  } catch (e) {
    if (openRunId === run) { body.innerHTML = `<p class="muted">${esc(e.message)}</p>`; }
  }
}

/* The readers this page hands the help menu, for the support bundle.
 * The reports page is about every run, so help offers the one whose row is
 * open, and otherwise says to pick one.
 * PAGE-LOAD-4: runDocs reads the run's documents in ONE call (store/docs with
 * the run as the prefix), as the Migrations, Waves and Assess and migrate
 * pages do; the bundle answers from it and asks the readers below only what
 * it cannot say. ?demo has no service, so it has no runDocs. */
function helpAdapter() {
  return {
    getMsal: () => msalApp,
    getRunId: () => openRunId,
    readJson: (run, rel) => source.readJson(run, rel),
    listFolder: (run, folder) => source.listFolder(run, folder),
    /* EVENTLOG-1: a log that filled carries on in a second document, and the
     * support bundle is the one place that must have all of it. readLogParts,
     * not readLogEvents: a line this cannot parse is kept as it was written,
     * because the bundle is read by somebody who is already stuck and a line
     * nobody can parse is evidence, not rubbish.
     * PAGE-LOAD-4: `held` is the bundle's one call for the run; each part it
     * holds - or says is not there - is not asked for again (unknown means ask). */
    readLines: async (run, rel, held) => (await VmfHelp.readLogParts((p) => {
      const known = VmfHelp.heldText(held, `${run}/${p}`);
      return known ? known.value : source.readText(run, p);
    }, rel)).map(l => { try { return JSON.parse(l); } catch { return { raw: l }; } }),
    runDocs: DEMO_MODE ? undefined
      : (run, read) => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${run}/`, depth: 2, read }),
  };
}

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  // The reports page is about every run, so help offers the one whose row is
  // open, and otherwise says to pick one.
  // Guarded: a missing shared file must cost the help option, not the page.
  if (window.VmfHelp) VmfHelp.install(helpAdapter());
  // PAGE-SCALE-REPORTS-1: the page's head, and the detail's way back.
  $('#page-title').textContent = UX.pageTitle;
  $('#lede').textContent = UX.lede;
  $('#detail-close').textContent = UX.detailClose;
  $('#detail-close').addEventListener('click', closeDetail);
  // NO-POPUPS-1: the report view's words, and its two ways out (rule 11).
  $('#report-title').textContent = UX.reportTitle;
  $('#report-print').textContent = UX.reportPrint;
  $('#report-close').textContent = UX.reportClose;
  $('#report-download').textContent = UX.reportDownload;
  $('#report-close').addEventListener('click', closeReport);
  $('#report-download').addEventListener('click', downloadReport);
  // One Escape closes one thing: the report first, then the detail.
  document.addEventListener('keydown', onKey);
  VmfHelp.identity(account, DEMO_MODE ? UX.demoViewer : null);
  // WAIT-1: the page appears FIRST and says what it is reading. It used to
  // stay hidden until every run in the store had been read three times, so
  // the wait was spent on a page that was not there yet.
  renderTable();
  $('#app').style.display = 'block';
  // PAGE-WAIT-1: the records are asked BESIDE the walk of every run, not
  // after it - they need none of it.
  const records = loadRecords();
  records.catch(() => { });   // awaited below; this only stops an early failure going unreported twice
  // LOADING-LINE-1: a failed read ends the read too, so the list is drawn
  // in the finally; the error itself still reaches the page's error message.
  try { await loadSummaries(); reading = false; }
  catch (e) { reading = null; throw e; }
  finally { renderTable(); }
  // PAGE-SCALE-REPORTS-1: the Safety copies card, from what the one call gave.
  await safetyPanel();
  await records;
}

/* ---------- the Safety copies card ----------
 * PAGE-SCALE-REPORTS-1: MOVED here from the Overview (ruled 2026-11-07).
 * The box then got the same treatment as the rest of the page,
 * because it can get very long: its table is the shared
 * list (VmfHelp.listMount), with no tiles, pages of 10, a Search and a Project
 * choice for its own rows, and the readable name of each migration. Its
 * summary, its lock warning and the cleanup line stay above the table. The
 * Safety copies card on each migration's page stays as it is. */
function whenLocal(iso) { return iso ? new Date(iso).toLocaleString() : ''; }
/* RETAIN-UX-1, RETENTION-CARD-CYCLE-1: what the daily cleanup did, and when
 * its next pass runs, from its record (VmfHelp.retentionPassFacts). The day's
 * cleanup is a cycle of hourly passes: while the cycle has migrations still to
 * examine, the card says the cleanup is not complete, counts the migrations
 * examined of those in the store, and names the next hourly pass - not 03:30
 * tomorrow, and not the count of a finished day. The migration page says the
 * same in the same words (copiesPassSentence). The age is in the words the
 * Overview used (VmfHelp.agoText). A count of 1 is in the singular
 * (VmfHelp.countWords). */
function copiesPassText(pass) {
  const since = (iso) => VmfHelp.agoText(iso, Date.now());
  const count = VmfHelp.countWords;
  const f = VmfHelp.retentionPassFacts(pass);
  const fail = f.ran && f.failures.length ? UX.copiesPassFail.replace('{reason}', f.failures.join('; ')) : '';
  const due = count(f.due, UX.copiesNDue), started = count(f.started, UX.copiesNStarted);
  if (f.unfinished) {
    const open = UX.copiesPassOpen.replace('{ago}', since(f.startedUtc))
      .replace('{examined}', count(f.examined, UX.copiesNExaminedOf, { total: f.inStore, by: f.inStore }))
      .replace('{due}', due).replace('{started}', started);
    return [open, fail, UX.copiesNextOpen.replace('{when}', whenLocal(f.nextUtc))].filter(Boolean).join(' ');
  }
  const said = !f.ran ? UX.copiesPassNone
    : fail || UX.copiesPassLine.replace('{ago}', since(pass.lastPassUtc)).replace('{examined}', count(f.examined, UX.copiesNExamined))
        .replace('{due}', due).replace('{started}', started);
  return said + ' ' + UX.copiesNext.replace('{when}', whenLocal(f.nextUtc));
}

/** The summary line: copies, machines and migrations, 1 in the singular. */
function copiesLineText(totals, migrations) {
  const count = VmfHelp.countWords;
  return UX.copiesLine.replace('{copies}', count(totals.copies, UX.copiesNCopies))
    .replace('{machines}', count(totals.machines, UX.copiesNMachines))
    .replace('{runs}', count(migrations, UX.copiesNMigrations)).replace('{due}', totals.due);
}

/* The migrations the box walks: every run in the store that is not an
 * assessment - also a run whose manifest, status or plan could not be read,
 * which the list leaves out. Its machine documents can still hold copies, and
 * the Overview counted them (review finding). */
let storeRuns = [];
let assessmentIds = new Set();
function copiesRunIds() {
  return storeRuns.filter(r => !assessmentIds.has(r));
}

/* RETAIN-UX-1: the safety copies of each migration, read the way the engine
 * reads them (plan entries and state documents, through
 * VmfHelp.safetyCopyLedger), and the pass record the daily cleanup leaves at
 * the store root. PAGE-SCALE-REPORTS-1: every document it reads came in the
 * page's one call (LIST_READS), so it asks the service nothing more. When that
 * call failed, each read goes to the service, and ONE limit holds the whole
 * walk (PERF-ONE-LIMIT-1: the walk inside a walk is not two limits). */
async function copiesFacts() {
  if (DEMO_MODE) { return { per: DEMO_COPIES.runs, pass: DEMO_COPIES.pass }; }
  const limited = VmfHelp.readLimiter();
  const passRead = limited(() => blobFetch('retention-status.json')).catch(() => null);
  const per = await VmfHelp.mapLimited(copiesRunIds(), async (id) => {
    /* PERF-PROBES-1: the machine documents first. A copy is only ever on a
     * machine document, so a migration with none has no copy to count, and
     * its plan - which a run at setup does not have - is not read. Where
     * there are documents the plan is read BESIDE them. */
    const names = await limited(() => blobList(`${id}/state/`)).then(l => l.names).catch(() => []);
    const docNames = names.filter(n => n.endsWith('.json'));
    if (!docNames.length) { return { id, summary: VmfHelp.safetyCopySummary(VmfHelp.safetyCopyLedger([], [], null)) }; }
    const [plan, read] = await Promise.all([
      limited(() => blobFetch(`${id}/plan.json`)).catch(() => null),
      VmfHelp.mapLimited(docNames, n => limited(() => blobFetch(n)).catch(() => null)),
    ]);
    const docs = read.filter(Boolean);
    const ledger = VmfHelp.safetyCopyLedger(docs, plan ? plan.entries : [], null);
    return { id, summary: VmfHelp.safetyCopySummary(ledger) };
  });
  return { per, pass: await passRead };
}

/* One migration with copies as a row of the box: the readable name with the
 * run id under it (the migration list's form), the copies kept, those due at
 * the next cleanup, the earliest deletion, and Open. The name and Open both go
 * to the migration's own page, where its own Safety copies card is. */
function copiesRow(p, created) {
  const projectId = VmfHelp.VmfRun.parse(p.id).project || null;
  const project = projectName(projectId);
  const dest = { page: 'migrations', run: p.id };
  const due = num(p.summary.due);
  return {
    id: p.id, projectId, project,
    name: VmfHelp.runTitle(project, 'migration', created.get(p.id) || null),
    dest,
    kept: num(p.summary.copies),
    due: due ? { text: String(due), tone: 'warn' } : 0,
    earliest: whenLocal(p.summary.earliestDueUtc),
    actions: [{ text: UX.copiesOpen, dest }],
  };
}

function copiesColumns() {
  return [
    { head: UX.copiesCol, kind: 'name' },
    { head: UX.copiesKept, kind: 'num', key: 'kept' },
    { head: UX.copiesDue, kind: 'num', key: 'due' },
    { head: UX.copiesEarliest, kind: 'text', key: 'earliest' },
    { head: '', kind: 'actions', key: 'actions' },
  ];
}

/* The box, drawn into its host: the shared list with no tiles, and above its
 * table the hint, the summary with its lock warning, and the cleanup line.
 * With no copies the list's own empty sentence says so, and the summary is
 * not said twice. */
function drawCopies(host, per, pass) {
  const withCopies = per.filter(p => num(p.summary.copies) > 0);
  const totals = withCopies.reduce((t, p) => ({ copies: t.copies + num(p.summary.copies), machines: t.machines + num(p.summary.machines),
                                                due: t.due + num(p.summary.due), unlocked: t.unlocked + num(p.summary.unlocked) }),
                                   { copies: 0, machines: 0, due: 0, unlocked: 0 });
  const created = new Map(rows.map(x => [x.r, x.createdUtc]));
  const list = VmfHelp.listMount(host, { id: 'cp', tiles: false, searchHint: UX.searchHint, columns: copiesColumns() });
  const line = withCopies.length
    ? `<p>${esc(copiesLineText(totals, withCopies.length))}${totals.unlocked ? ' <span class="pill warn">' + esc(UX.copiesUnlocked.replace('{n}', totals.unlocked)) + '</span>' : ''}</p>`
    : '';
  list.lead().innerHTML = `<div class="cardbody"><p class="muted">${esc(UX.copiesHint)}</p>${line}<p class="muted">${esc(copiesPassText(pass))}</p></div>`;
  const tableRows = withCopies.map(p => copiesRow(p, created));
  const choices = projects.map(p => ({ id: p.id, name: p.name }));
  if (tableRows.some(x => !x.projectId)) { choices.push({ id: VmfHelp.LIST_LOOSE, name: UX.loose }); }
  list.update({ tiles: [{ key: 'copies', label: UX.copiesTitle, empty: UX.copiesNone, rows: tableRows }], projects: choices });
  return list;
}

async function safetyPanel() {
  const card = document.getElementById('copies-card');
  if (!card || !copiesRunIds().length) return;
  // LOADING-LINE-1: the box says what it reads until the list is drawn over it.
  card.innerHTML = `<section class="card"><div class="ch"><h2>${esc(UX.copiesTitle)}</h2></div>`
    + `<div class="cardbody">${VmfHelp.waitingLine(UX.copiesReading)}</div></section>`;
  try {
    const { per, pass } = await copiesFacts();
    drawCopies(card, per, pass);
  }
  catch (e) {
    card.className = 'card';
    card.innerHTML = `<div class="ch"><h2>${esc(UX.copiesTitle)}</h2></div>
      <div class="cardbody"><p class="muted">${esc(UX.copiesError.replace('{reason}', e && e.message ? e.message : String(e)))}</p></div>`;
  }
}

async function boot() {
  if (DEMO_MODE) { $('#demo-tag').style.display = 'inline-block'; await start(); return; }
  if (typeof msal === 'undefined') throw new Error('msal-browser.min.js failed to load - redeploy the dashboard.');
  cfg = VmfHelp.checkedConfig(await (await fetch('dashboard.config.json')).json());
  msalApp = new msal.PublicClientApplication({
    auth: { clientId: cfg.clientId, authority: `https://login.microsoftonline.com/${cfg.tenantId}`,
            redirectUri: location.origin + location.pathname },
    cache: { cacheLocation: 'sessionStorage' },
  });
  await msalApp.initialize();
  /* POPUP-3: takes the account a sign-in redirect brought back, when this load
     IS the return from one. Throws if the directory refused, and remembers the
     attempt, so the page cannot ask again and loop. */
  const accounts = await VmfHelp.accountsAfterReturn(msalApp);
  if (accounts.length) { account = accounts[0]; await start(); }
  else {
    VmfHelp.showSignIn();
    $('#login-btn').addEventListener('click', async () => {
      try {
        /* POPUP-3: leaves for the directory. Nothing follows - the browser navigates away here. */
        await VmfHelp.signInRedirect(msalApp, [`api://${cfg.apiAppId}/access_as_user`]);

      } catch (e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }
    });
  }
}

// ---------- bundled sample data ----------
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sample/providers/Microsoft.Compute/virtualMachines/';
const T = (minAgo) => new Date(Date.now() - minAgo * 60000).toISOString();
function sampleRun(name, createdMin, updatedMin, entries, docs, extras = {}) {
  const files = {
    'run.json': { runId: name, createdUtc: T(createdMin) },
    'run-status.json': { updatedUtc: T(updatedMin), stateCounts: docs.reduce((m, d) => { m[d.state] = (m[d.state] ?? 0) + 1; return m; }, {}) },
    'plan.json': { entries },
    ...extras,
  };
  for (const d of docs) files[`state/${vmName(d.vmId)}.json`] = d;
  return files;
}
// MANUAL-SHOTS-1: each machine carries the size it moves from and to, so the
// sample record shows its sizes rather than empty tables.
const mk = (n, wave, req) => ({ vmId: SUB + n, wave, path: 'A', assessment: { sourceSize: 'Standard_D2s_v4' },
  target: { size: 'Standard_D2s_v6' }, ...(req ? { policy: { requireApproval: true } } : {}) });
const doc = (n, state, hist = []) => ({ vmId: SUB + n, state, history: hist });
// PAGE-SCALE-REPORTS-1: the sample is in projects, with enough migrations to
// fill a second page of the list, as an estate at volume does - the manual's
// picture is taken from this (tools/manual-shots.js).
const DEMO_PROJECTS = [
  { id: 'contoso-datacentre-exit', name: 'Contoso datacentre exit' },
  { id: 'payments-refresh', name: 'Payments platform refresh' },
  { id: 'web-tier', name: 'Web tier' },
];
const DEMO = {
  'payments-refresh/pilot-sample': sampleRun('pilot-sample', 4000, 2900,
    [mk('can-a', 'storefront-pilot'), mk('can-b', 'storefront-pilot'), mk('prd-a', 'billing-apps', true), mk('prd-b', 'billing-apps', true)],
    [doc('can-a', 'MIGRATED'),
     // A person put this one back: the state stays MIGRATED and gains `restore`.
     { ...doc('can-b', 'MIGRATED'), restore: { restoredUtc: T(3000), restoredBy: 'sam@example.com',
                                               note: 'application owner asked for more testing', sizeAfter: 'Standard_D2s_v4' } },
     doc('prd-a', 'MIGRATED'),
     doc('prd-b', 'MIGRATED', [{ state: 'NEEDS_DECISION', detail: 'a person chose to continue after review' }])],
    { 'approvals/billing-apps.json': { approvedBy: { identity: 'sam@example.com' }, approvedUtc: T(3200), note: 'reviewed with app owners' },
      'customer-report.html': '<h1>Sample run report</h1><p>This is the bundled sample of the full report.</p>' }),
  'web-tier/wave-sample': sampleRun('wave-sample', 6000, 5200,
    [mk('web-a', 'storefront-pilot'), mk('web-b', 'storefront-pilot'), mk('db-a', 'storefront-pilot')],
    [doc('web-a', 'MIGRATED'), doc('web-b', 'MIGRATED'),
     doc('db-a', 'FAILED_ROLLED_BACK', [{ state: 'FAILED_ROLLED_BACK', detail: 'did not start on the new size - automatically restored' }])]),
  'payments-refresh/live-sample': sampleRun('live-sample', 90, 2,
    [mk('app-a', 'billing-apps'), mk('app-b', 'billing-apps')],
    [doc('app-a', 'MIGRATED'), doc('app-b', 'FAILED_NEEDS_ATTENTION', [{ state: 'FAILED_NEEDS_ATTENTION', detail: 'final health checks did not pass - paused for an engineer' }])]),
  // A migration still moving machines, and one scanned and never planned.
  'web-tier/migration-2026-11-06': sampleRun('migration-2026-11-06', 1500, 6,
    [mk('cdn-a', 'edge'), mk('cdn-b', 'edge'), mk('cdn-c', 'edge')],
    [doc('cdn-a', 'MIGRATED'), doc('cdn-b', 'CONVERTING'), doc('cdn-c', 'PLANNED')]),
  'web-tier/migration-2026-11-07': sampleRun('migration-2026-11-07', 30, 30, [], []),
  // Eleven finished migrations of one estate: enough for a second page.
  ...Object.fromEntries(Array.from({ length: 11 }, (_, i) => {
    const name = `migration-2026-10-${String(27 - i * 2).padStart(2, '0')}`;
    const vms = ['a', 'b', 'c'].slice(0, (i % 3) + 1).map(s => `dc${i}-${s}`);
    return [`contoso-datacentre-exit/${name}`, sampleRun(name, 1440 * (i * 2 + 12), 1440 * (i * 2 + 10),
      vms.map(n => mk(n, `wave-${(i % 2) + 1}`)), vms.map(n => doc(n, 'MIGRATED')),
      i % 2 ? {} : { 'customer-report.html': '<h1>Sample run report</h1><p>This is the bundled sample of the full report.</p>' })];
  })),
};
/* ?demo: the kept records, one for each sample migration, and one of a
 * migration that was deleted - its name has no address. */
function demoKeptRecords() {
  const made = (r) => DEMO[r]['run-status.json'].updatedUtc;
  const list = Object.keys(DEMO).filter(r => DEMO[r]['plan.json'].entries.length).map(r => ({
    Name: `${r}.json`, RunId: VmfHelp.VmfRun.parse(r).run, Project: VmfHelp.VmfRun.parse(r).project, Reason: 'waveClosed',
    GeneratedUtc: made(r), KeepUntilUtc: new Date(Date.parse(made(r)) + 90 * 864e5).toISOString() }));
  list.push({ Name: 'contoso-datacentre-exit/migration-2026-09-14.json', RunId: 'migration-2026-09-14', Project: 'contoso-datacentre-exit',
    Reason: 'deleted', GeneratedUtc: T(1440 * 40), KeepUntilUtc: T(1440 * -50) });
  return list;
}
// RETAIN-UX-1: what the Safety copies card shows on the demo page.
const DEMO_COPIES = {
  runs: [
    { id: 'payments-refresh/pilot-sample',
      summary: { machines: 4, copies: 7, waiting: 4, due: 2, inUse: 1, unreadable: 0, unlocked: 2, deleted: 2, earliestDueUtc: T(-60) } },
  ],
  pass: { schemaVersion: 1, lastPassUtc: T(500), runsExamined: 3, runsWithCopiesDue: 1, machinesDue: 1,
          executionsStarted: [{ runId: 'payments-refresh/pilot-sample', machines: 1, execution: 'vmf-engine-sample-r1' }], failures: [] },
};

boot().catch(e => { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; });
