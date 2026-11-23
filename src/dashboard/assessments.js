'use strict';
const DEMO_MODE = new URLSearchParams(location.search).has('demo');
const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const vmName = (id) => String(id).split('/').pop();
const PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];

/* ============================ UX-STRINGS-BEGIN ============================
   Same bar as every other page: plain words, no engine vocabulary. */
const UX = {
  title:      'Assessments',
  // PAGE-SCALE-ASSESSMENTS-1: the words of the approved design.
  lede:       'A migration is planned from an accepted assessment.',
  tileReview:        'To review',
  tileReviewTitle:   'Assessments to review',
  tileReviewNone:    'No assessment waits for a review.',
  tileAccepted:      'Accepted, no migration yet',
  tileAcceptedTitle: 'Accepted assessments with no migration',
  tileAcceptedNone:  'No accepted assessment waits for a migration.',
  tilePlanned:       'Planned',
  tilePlannedTitle:  'Assessments with a migration',
  tilePlannedNone:   'No migration was planned from an assessment yet.',
  tileAll:           'All assessments',
  colName:    'Assessment',
  colProject: 'Project',
  colFound:   'Machines found',
  colReady:   'Can migrate',
  colStatus:  'Status',
  colChanged: 'Last change',
  colAction:  'Action',
  statusReview:   'To review',
  statusAccepted: 'Accepted',
  statusPlanned:  'Planned',
  // The next step of each status, in the Overview's words: Review opens the
  // wizard at its review step, as the Overview's Review does.
  actReview:  'Review',
  actPlan:    'Plan a migration',
  actOpen:    'Open',
  searchHint: 'Assessment or project',
  // The Overview's name for the runs that are in no project.
  loose:      'Outside a project',
  // ALREADY-CURRENT-1: the machines on a size in the Current lifecycle stage.
  colCurrent: 'Current',
  del:        'Delete',
  delTitle:   'Delete this assessment?',
  delDesc:    'This deletes the record of this assessment: what it found, and the log. Your machines are not touched. Nothing is started, stopped or changed.',
  /* PROJ-EMPTY-1: this is READ, under the button, instead of living in a
   * hover on it. PAGE-SCALE-ASSESSMENTS-1: short, so a page of 10 rows stays
   * a page, and the migration it names is a link to it - the way out. */
  delPlanned:     'Delete {what} first.',
  delPlannedOne:  'the migration',
  delPlannedMany: 'the {n} migrations',
  delBusy:    'Deleting...',
  delDone:    'Assessment deleted.',
  delYes:     'Yes, delete',
  tidyYes:    'Yes, remove them',
  cancel:     'Cancel',
  // The report panel: the migrations planned from the assessment, and the
  // wizard again for one more.
  plannedFrom: 'Migrations planned from this assessment',
  openAgain:  'Plan another',
  none:       'Nothing has been assessed yet. Start by scanning for machines that could be migrated.',
  waiting:    'Reading your assessments.',
  scanBtn:    'Assess an estate',
  everywhere: 'everything the product can reach',
  inSubscription:    'in subscription ',
  inSubscriptions:   ' subscriptions',
  inGroup:           'in management group ',
  resourceGroups:    ' resource groups',
  wholeSubscription: 'A whole subscription',
  wholeSubscriptions:' whole subscriptions',
  wholeGroup:        'A whole management group: ',
  whereItLooked:     'Where it looked',
  clsReadyAfterPrep:'Can migrate',
  clsBlocked:       'Cannot yet',
  clsExcluded:      'Not eligible',
  holdingBack:      'What is holding machines back',
  limitsTarget:     'What limits the target',
  clsSomeTargets:   'Some targets only',
  nothingBlocked:   'No finding stops a machine.',
  notEligible:      'Not eligible',
  notEligibleWhy:   'The product does not move these machines. Another Azure service manages them, or they are outside the scope of this tool.',
  willPrepare:      'Preparation for the move',
  willPrepareWhy:   'Each card says what the product does, and what you do before the move.',
  nothingFound:     'This scan found no machines.',
  reviewed:         'Reviewed',
  reviewedBy:       'by',
  notReviewed:      'Not reviewed yet',
  notReviewedWhy:   'Read what this assessment found, then select I have reviewed this. A migration can only be planned from an accepted assessment.',
  reviewBtn:        'I have reviewed this',
  tidyBtn:      'Clear up old scans',
  tidyTip:      'Remove scans that were started and never planned',
  tidyBusy:     'Checking...',
  tidyNone:     'There is nothing to remove. Each scan here has a plan, or is less than 30 days old.',
  tidyFound:    'These scans are older than 30 days and have no plan. Removing them deletes what they found.',
  tidyKept:     'A scan with a plan, a migration or an on-demand capacity reservation stays.',
  tidyDone:     ['{n} scan removed.', '{n} scans removed.'],
  reviewNote:       'Add a note (optional)',
  reviewNoteHint:   'Anything worth recording alongside your name',
  reviewWorking:    'Recording...',
  // ASSESS-APPROVAL-HASH-1: why I have reviewed this is off.
  reviewReading:    'The product reads this scan again. Then you can approve it.',
  reviewReadFailed: 'The product did not read this scan again. Close the report, open it again, then approve the scan.',
};
/* ============================= UX-STRINGS-END ============================= */

// NAME-1: displayed technical lines never show bare path letters.
// PATH-NAME-1: A is Azure's own term for it.
const PATH_WORDS = { A: 'In-place upgrade' };
const techText = (s) => String(s ?? '')
  .replace(/\bPath A\b/g, PATH_WORDS.A);

// MANUAL-REVIEW-1: the one rule of every list (VmfHelp.agoText), in words.
const ago = (iso) => VmfHelp.agoText(iso, Date.now());
const day = (iso) => iso ? new Date(iso).toLocaleDateString() : '';

// ---------- data source: demo (bundled) or live (blob REST via MSAL) ----------
let cfg = null, msalApp = null, account = null;
// The scopes are a PARAMETER because the access console asks for Graph
// tokens of its own; every other caller takes the default and reads through
// the facade. (IDENTITY-4 removed the other caller that passed its own.)
async function getToken(scopes) {
  const req = { scopes: scopes || [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
/* PAGE-LOAD-1: what ONE call to the service gave this load (VmfHelp.storeDocs):
 * the store listed, and each run.json, assessment.json and approval.json.
 * MEASURED on a lab install: this page sent about 200 calls on one load, one
 * for each document, and took a minute or two. The readers below answer from
 * it first and ask the service only what it cannot answer (unknown means
 * ask). null when the call failed - then every read goes to the service. */
let held = null;
/* PAGE-SCALE-ASSESSMENTS-1: project.json too, for the project's name in each
 * row and in the project choice. It comes in the SAME one call - no read for
 * each row. */
const LIST_READS = ['run.json', 'assessment.json', 'approval.json', 'project.json'];
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
const source = DEMO_MODE ? {
  async listRuns() { return Object.keys(DEMO); },
  async listProjects() { return DEMO_PROJECTS.map(p => Object.assign({}, p)); },
  async readJson(run, rel) { return structuredClone(DEMO[run]?.[rel] ?? null); },
  async readText(run, rel) { return DEMO[run]?.[rel] ?? null; },
  async listFolder(run, folder) { return Object.keys(DEMO[run] ?? {}).filter(k => k.startsWith(folder + '/')); },
  async exists(run, rel) { return Boolean(DEMO[run]?.[rel]); },
} : {
  // PROJECT-1: runs may live inside a project now. One shared rule (help.js).
  async listRuns() { return window.VmfListRuns(blobList); },
  async listProjects() { return listProjects(); },
  async readJson(run, rel) { return blobFetch(`${run}/${rel}`); },
  async readText(run, rel) { return blobFetch(`${run}/${rel}`, { asText: true }); },
  async listFolder(run, folder) { return (await blobList(`${run}/${folder}/`)).names.map(n => n.slice(run.length + 1)); },
  async exists(run, rel) { return (await blobList(`${run}/${rel}`)).names.length > 0; },
};

// Until now this page only read. Approving is the one thing it does, and it
// goes through the facade - the browser's own token cannot write an approval,
// and should not be able to.
async function api(method, path, body) {
  if (DEMO_MODE) { await new Promise(r => setTimeout(r, 250)); return {}; }
  const token = (await msalApp.acquireTokenSilent({ scopes: [`api://${cfg.apiAppId}/access_as_user`], account }))
    .accessToken;
  const r = await fetch(`${cfg.apiUrl}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
  return data;
}

// ---------- assessments ----------
// An object in the store is an assessment or a migration, and its manifest says
// which (ASSESS-PAGE-1). RETAIN-KIND-1: the one rule is VmfHelp.runKind.

// The wording for each code, the grouping and the cards all live in
// assessment-report.js, which the wizard uses too. They were copied here once
// and the copies were already drifting - different tone on the same card,
// different order of sections. One renderer, two callers.
const { loadReasons, groupByCode, reasonCard, chipList, migrateCounts, splitBlockers } = window.VmfReport;

let rows = [];
// PAGE-SCALE-ASSESSMENTS-1: every project, { id, name }, for the rows and the
// project choice.
let projects = [];
/* The projects in the store, by name: each folder at the top that holds a
 * project.json. The listing and the documents come from the one call
 * (held); with no held answer it is one read for each PROJECT, never one for
 * each row. A project document that cannot be read is named by its id. */
async function listProjects() {
  const top = (await blobList('', '/')).prefixes.filter(VmfHelp.runFolderIsRun);
  const out = [];
  await VmfHelp.mapLimited(top, async (p) => {
    // PROJECT-3: the folders beside a project's runs are not runs - the same
    // listing projects.js reads, held to the same rule.
    const inside = await blobList(`${p}/`, '/').then(l => ({ ...l, prefixes: l.prefixes.filter(VmfHelp.runFolderIsRun) })).catch(() => null);
    if (!inside || !inside.names.includes(`${p}/project.json`)) { return; }
    const doc = await blobFetch(`${p}/project.json`).catch(() => null);
    out.push({ id: p, name: (doc && doc.name) || p });
  });
  return out.sort((a, b) => String(a.name).localeCompare(String(b.name)));
}
// WAIT-1: true until the store has been read. The sentence this page shows
// when it has no rows - 'Nothing has been assessed yet' - is correct-looking
// and wrong while it is still looking, which is worse than an empty table.
// LOADING-LINE-1: null once the read FAILED - not reading, and nothing read,
// so the list says the read failed rather than "none".
let reading = true;
async function loadAssessments() {
  // PAGE-LOAD-1: ONE call for the listing and the documents each row draws,
  // read again on every load so an approval made a moment ago is seen.
  if (!DEMO_MODE) { held = await VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { depth: 3, read: LIST_READS }).catch(() => null); }
  // PAGE-SCALE-ASSESSMENTS-1: the projects, by name, for the rows and the
  // project choice - every project, so one with no assessment yet can still
  // be the filter (the Projects page links each project here).
  const [ids, found] = await Promise.all([source.listRuns(), source.listProjects().catch(() => [])]);
  projects = found;
  // STORE-READ-2: one manifest per run in the store, paced.
  const all = await VmfHelp.mapLimited(ids, async id => {
    const manifest = await source.readJson(id, 'run.json').catch(() => null);
    return { id, manifest, kind: VmfHelp.runKind(manifest) };
  });
  // ?project= arrives from the Projects page, where the assessment count is a
  // link. PAGE-SCALE-ASSESSMENTS-1: it sets the list's project filter now
  // (render), so every assessment is read and a person can choose another.
  const assessments = all.filter(x => x.kind === 'assessment');
  // Which assessments have been planned from, and into what. A migration
  // records the assessment it came from, so this is read rather than guessed.
  /* PROJ-EMPTY-1: THE KEY HAS TO BE SPELT THE WAY THE ROW IS.
   *
   * `fromAssessment` holds the BARE run id, and `a.id` below is how the store
   * spells a run - `project/run` for anything inside a project. So in a
   * project the two never matched, this map was always empty, and the guard
   * that refuses to delete an assessment a migration was planned from was
   * never once applied there. In use: an assessment was deleted,
   * the migration stayed, and the project could not be emptied afterwards.
   *
   * Keyed by the MIGRATION's project, because the product only ever plans a
   * migration into the assessment's own project. A plan written into a
   * different one still will not match - the bare id cannot say which project
   * it means, which is a defect in what gets WRITTEN, not here. That case is
   * no worse than it is today and is carried in its own work item.
   */
  const plannedFrom = new Map();
  for (const m of all.filter(x => x.kind === 'migration')) {
    const from = m.manifest && m.manifest.fromAssessment;
    if (!from) continue;
    const key = VmfHelp.VmfRun.storePath(m.manifest.project, VmfHelp.VmfRun.parse(from).run);
    if (!plannedFrom.has(key)) plannedFrom.set(key, []);
    plannedFrom.get(key).push({ id: m.id, created: m.manifest.createdUtc || null });
  }
  // PAGE-SCALE-ASSESSMENTS-1: the newest migration first - Open goes to it -
  // and its time is the assessment's last change when it is the latest.
  const newestFirst = (a, b) => (Date.parse(b.created || 0) || 0) - (Date.parse(a.created || 0) || 0);
  for (const list of plannedFrom.values()) { list.sort(newestFirst); }
  // STORE-READ-2: two reads per assessment, and each document carries the
  // whole estate it scanned, so this is paced too.
  // WAIT-1: each assessment is drawn as it lands rather than held back for the
  // slowest of them. Two reads per assessment, and each document carries the
  // whole estate it scanned, so the last one can be seconds after the first.
  const landed = [];
  // PAGE-SCALE-ASSESSMENTS-1: the latest change first, as the list shows it.
  const byNewest = (a, b) => (Date.parse(lastChange(b) || 0) || 0) - (Date.parse(lastChange(a) || 0) || 0);
  rows = await VmfHelp.mapLimited(assessments, async a => {
    // PAGE-WAIT-1: the two reads go together; they went one after the other.
    const [doc, approval] = await Promise.all([
      source.readJson(a.id, 'assessment.json').catch(() => null),
      // The gate: a migration cannot be planned from an assessment nobody has
      // read. The engine enforces it; this is how the page can SAY so rather
      // than letting somebody press a button that will be refused.
      source.readJson(a.id, 'approval.json').catch(() => null),
    ]);
    const vms = (doc && doc.vms) ? doc.vms : [];
    // ASSESS-COUNT-1: no counts are stored here. "Can migrate" and "Cannot
    // yet" come from migrateCounts when a row is DRAWN - the reasons file it
    // needs is read beside this, so a count made now could be made without it.
    const planned = plannedFrom.get(a.id) || [];
    const row = {
      id: a.id,
      projectId: VmfHelp.VmfRun.parse(a.id).project || null,
      when: (a.manifest && a.manifest.createdUtc) || (doc && doc.generatedUtc) || null,
      // RAW, not pre-rendered: names arrive after the first draw (see
      // SCOPE-NAME-1 above), so the text is made when the row is drawn.
      scope: (a.manifest && a.manifest.scope) || (doc && doc.scope) || null,
      machines: vms.length,
      // The migrations planned from it, newest first, by id.
      planned: planned.map(m => m.id),
      plannedUtc: planned.length ? planned[0].created : null,
      approval,
      vms,
      // REPORT-GAP-1: what the scan asked for and did not get.
      notRead: doc?.notRead ?? [],
    };
    landed.push(row);
    return row;
  }, undefined, () => {
    rows = landed.slice().sort(byNewest);
    renderTable();
  });
  rows.sort(byNewest);
}

/* Where the scan looked, as { what, where }.
 *
 * A scan scoped to a resource group read as though it had covered the whole
 * subscription. The resource group IS in the subscription, so that was
 * factually true and still misleading: say which one was actually scanned.
 *
 * Exactly - the old version joined every level of the scope with commas, so
 * "1 subscription, rg-vmf-uxtest" read as TWO things scanned when it was one
 * resource group that happens to live in a subscription. A person reading that
 * has no way to tell a whole-subscription scan from a single-group one, and
 * those differ by hundreds of machines and a bill.
 *
 * So: the NARROWEST level is what was scanned, and the wider levels are where
 * it sits. Named groups win over the subscription; the subscription wins over
 * the management group. */
/* SCOPE-NAME-1. The assessment records a subscription by ID, and this page
 * printed it: "in subscription aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e". The
 * wizard, one click earlier, had said "inside subscription Contoso-Prod" for the
 * same scan - it resolves the name from the facade's /scopes answer and falls
 * back to the id. This page never asked, so it had nothing but the id.
 *
 * A raw GUID on an operator page is the raw-vocabulary problem in a different
 * coat. Same rule as the wizard: name when known, id when not, never blank.
 *
 * Fetched WITHOUT blocking the page. The facade cold-starts in 20-40 s on a
 * Consumption plan (COLD-1), and a list of assessments that waits on a lookup
 * of subscription names would be the wrong thing held hostage. Rows draw with
 * ids and are redrawn with names when they arrive. */
let scopes = null;
const DEMO_SCOPES = { subscriptions: [{ id: '00000000-0000-0000-0000-000000000000', name: 'Production' }],
                      managementGroups: [{ id: 'mg-root', name: 'Tenant Root Group' }] };
const subName = (id) => (scopes?.subscriptions ?? []).find(x => x.id === id)?.name || id;
const mgName = (id) => (scopes?.managementGroups ?? []).find(x => x.id === id)?.name || id;

function scopeText(scope) {
  if (!scope) return { what: UX.everywhere, where: '' };
  const subs = (scope.subscriptions || []).filter(Boolean);
  const rgs = (scope.resourceGroups || []).filter(Boolean);
  const mg = scope.managementGroup;

  const inSub = subs.length === 1 ? UX.inSubscription + subName(subs[0])
    : subs.length ? subs.length + UX.inSubscriptions
    : mg ? UX.inGroup + mgName(mg) : '';

  if (rgs.length) {
    return {
      what: rgs.length === 1 ? rgs[0] : rgs.length + UX.resourceGroups,
      where: inSub,
      full: rgs.join(', ') + (inSub ? ' ' + inSub : ''),
    };
  }
  if (subs.length) {
    // No groups named, so the WHOLE subscription was in scope - say so, because
    // it is a materially bigger thing than the line above.
    return {
      what: subs.length === 1 ? UX.wholeSubscription : subs.length + UX.wholeSubscriptions,
      where: subs.map(subName).join(', '),
      // The tooltip keeps the ids: a name is for reading, an id is for finding.
      full: subs.map(id => `${subName(id)} (${id})`).join(', '),
    };
  }
  if (mg) return { what: UX.wholeGroup + mg, where: '', full: mg };
  return { what: UX.everywhere, where: '' };
}

/* PAGE-SCALE-ASSESSMENTS-1: the list has no scope column now - the report
 * says where the scan looked, in full. Its line is made when the report is
 * drawn, and made again when the names arrive (SCOPE-NAME-1). */
function scopeLineHtml(row) {
  const sc = scopeText(row.scope);
  // The full text, ids too, is on the element: a name is for reading, an id
  // is for finding.
  const where = sc.where ? ' <span class="mono" style="overflow-wrap:anywhere">' + esc(sc.where) + '</span>' : '';
  return esc(UX.whereItLooked) + ': <span title="' + esc(sc.full || sc.what || '') + '">' + esc(sc.what || '') + where + '</span>';
}
function refreshScopeLine() {
  const line = document.getElementById('report-scope');
  const row = openReportId ? rows.find(x => x.id === openReportId) : null;
  if (line && row) { line.innerHTML = scopeLineHtml(row); }
}

/* PAGE-SCALE-ASSESSMENTS-1: four count tiles and ONE list, in place of one
 * table with a row for every assessment.
 *
 * With many assessments the page was one long scroll with no search and no
 * page, and each assessment showed by its run id. The tiles, the list, its
 * project choice, its search and its pages are the shared piece in help.js
 * (VmfHelp.listMount); this page gives it the rows. Nothing is hidden until a
 * person selects: every tile shows its count, and All assessments holds every
 * row. The list opens on To review, or the first tile with rows. */

/* Where an assessment is: 'planned' when a migration was planned from it,
 * 'accepted' when a person accepted it and nothing was planned yet, else
 * 'review'. The engine refuses to plan from an assessment nobody accepted,
 * so a planned one was accepted - and is counted once, as Planned. */
function assessmentStatus(r) {
  if ((r.planned || []).length) { return 'planned'; }
  return r.approval ? 'accepted' : 'review';
}

/* The latest of when the scan was made, when a person accepted it, and when
 * the newest migration was planned from it - or null when none is a time. */
function lastChange(r) {
  let best = null, bestAt = -Infinity;
  for (const v of [r.when, r.approval && r.approval.approvedUtc, r.plannedUtc]) {
    const at = v ? Date.parse(v) : NaN;
    if (isFinite(at) && at > bestAt) { best = v; bestAt = at; }
  }
  return best;
}

/* Delete is ALWAYS drawn, in the row (DELETE-PATHS: a delete that hides is a
 * feature nobody knows they have). An assessment a migration was planned
 * from cannot be deleted - that migration records where it came from - so
 * the button is disabled and the reason is UNDER it, never in a hover
 * (PROJ-EMPTY-1), and the migration it names is a link to it. */
function deleteAction(r) {
  const action = { text: UX.del, action: 'delete', value: r.id };
  const planned = r.planned || [];
  if (!planned.length) { return action; }
  const what = planned.length === 1
    ? { text: UX.delPlannedOne, dest: { page: 'migrations', run: planned[0] } }
    : { text: UX.delPlannedMany.replace('{n}', String(planned.length)),
        dest: r.projectId ? { page: 'migrations', project: r.projectId } : { page: 'migrations' } };
  const at = UX.delPlanned.indexOf('{what}');
  return Object.assign(action, { disabled: true,
    note: [{ text: UX.delPlanned.slice(0, at) }, what, { text: UX.delPlanned.slice(at + '{what}'.length) }] });
}

/* The next step of a row, in the product's own actions: Review and Plan a
 * migration open the wizard on the assessment (it opens at its review step,
 * and the engine refuses a plan from one nobody accepted); Open goes to the
 * newest migration planned from it. */
function nextAction(r) {
  const status = assessmentStatus(r);
  if (status === 'planned') { return { text: UX.actOpen, dest: { page: 'migrations', run: r.planned[0] } }; }
  return { text: status === 'accepted' ? UX.actPlan : UX.actReview, dest: { page: 'wizard', run: r.id } };
}

const STATUS_TAGS = {
  review: () => ({ text: UX.statusReview, tone: 'warn' }),
  accepted: () => ({ text: UX.statusAccepted, tone: '' }),
  planned: () => ({ text: UX.statusPlanned, tone: 'good' }),
};

/* One assessment as a row of the list. The name is the project and the day
 * of the scan (VmfHelp.runTitle), the run id small under it. It links to this
 * page with the run in the query, and a click opens the report beside the
 * list (openReport) - the same address opens it from another tab. ASSESS-
 * COUNT-1: Can migrate is the shared rule's count, the number the report
 * shows. */
function assessmentRow(r, names) {
  const project = r.projectId ? (names.get(r.projectId) || r.projectId) : UX.loose;
  return {
    id: r.id, projectId: r.projectId || null, project,
    name: VmfHelp.runTitle(project, 'assessment', r.when),
    dest: { page: 'assessments', run: r.id },
    open: { action: 'report', value: r.id },
    found: r.machines,
    can: migrateCounts(r.vms).ready,
    status: STATUS_TAGS[assessmentStatus(r)](),
    changed: lastChange(r),
    actions: [nextAction(r), deleteAction(r)],
  };
}

function assessmentTiles(list) {
  const names = new Map(projects.map(p => [p.id, p.name]));
  const all = list.map(r => assessmentRow(r, names));
  const where = (status) => all.filter((row, i) => assessmentStatus(list[i]) === status);
  return [
    { key: 'review', label: UX.tileReview, title: UX.tileReviewTitle, empty: UX.tileReviewNone, rows: where('review') },
    { key: 'accepted', label: UX.tileAccepted, title: UX.tileAcceptedTitle, empty: UX.tileAcceptedNone, rows: where('accepted') },
    { key: 'planned', label: UX.tilePlanned, title: UX.tilePlannedTitle, empty: UX.tilePlannedNone, rows: where('planned') },
    // WAIT-1, LOADING-LINE-1: while the page reads, the shared list says
    // UX.waiting in place of every tile's empty sentence.
    { key: 'all', label: UX.tileAll, title: UX.tileAll, empty: UX.none, rows: all },
  ];
}

function assessmentColumns() {
  return [
    { head: UX.colName, kind: 'name' },
    { head: UX.colProject, kind: 'text', key: 'project' },
    { head: UX.colFound, kind: 'num', key: 'found' },
    { head: UX.colReady, kind: 'num', key: 'can' },
    { head: UX.colStatus, kind: 'tag', key: 'status' },
    { head: UX.colChanged, kind: 'ago', key: 'changed' },
    { head: UX.colAction, kind: 'actions', key: 'actions' },
  ];
}

/* The project choice: every project by name, then the assessments outside a
 * project, when there are any (the Overview's rule). */
function projectChoices(list) {
  const out = projects.map(p => ({ id: p.id, name: p.name }));
  if (list.some(r => !r.projectId)) { out.push({ id: VmfHelp.LIST_LOOSE, name: UX.loose }); }
  return out;
}

// ---------- the report ----------
/* PAGE-SCALE-ASSESSMENTS-1: the report's heading is the row's own name. */
function reportTitle(row) {
  const name = row.projectId ? ((projects.find(p => p.id === row.projectId) || {}).name || row.projectId) : UX.loose;
  return VmfHelp.runTitle(name, 'assessment', row.when);
}

/* The migrations planned from the assessment, each a link to it, and the
 * wizard again for one more - what the list's Migration column and its Plan
 * another button gave before PAGE-SCALE-ASSESSMENTS-1. Nothing when none was
 * planned: the row's own action plans the first. */
function plannedHtml(row) {
  const planned = row.planned || [];
  if (!planned.length) { return ''; }
  const links = planned.map(m => '<li><a class="mono" href="' + esc(VmfHelp.VmfRun.link('migrations.html', m)) + '">' + esc(m) + '</a></li>').join('');
  return `<h4>${esc(UX.plannedFrom)}</h4><ul>${links}</ul>` +
    '<p><a class="btn small ghost" href="' + esc(VmfHelp.VmfRun.link('wizard.html', row.id)) + '">' + esc(UX.openAgain) + '</a></p>';
}
/* ASSESS-APPROVAL-HASH-1: the reason I have reviewed this is off, beside it -
 * while the scan is read again with its version, or after that read failed.
 * Nothing when the button is on. */
function approveWhy(row) {
  if (row.version || DEMO_MODE) { return ''; }
  return `<span class="muted" id="approve-why" style="margin-left:10px;font-size:12px">${esc(row.versionFailed ? UX.reviewReadFailed : UX.reviewReading)}</span>`;
}
// The point of an assessment is to say what cannot move WHILE THERE IS STILL
// TIME TO DO SOMETHING. So the report leads with what is holding machines back,
// grouped by reason rather than listed per machine: twelve machines blocked for
// one reason is one piece of work, and reading it as twelve rows hides that.
function reportHtml(row) {
  const vms = row.vms ?? [];
  if (!vms.length) return `<p class="muted">${esc(UX.nothingFound)}</p>`;
  // SERIES-COUNT-1: a machine the scan marked Blocked that still has a size
  // series open to it can migrate - to some targets. Only a machine with none
  // left is "cannot yet". ASSESS-COUNT-1: the same rule as the list and the
  // wizard, so the numbers on one screen agree. ALREADY-CURRENT-1: a machine
  // on a Current size is counted once, as Current. Can migrate is every
  // machine that can migrate with no finding that holds it back.
  const counts = migrateCounts(vms);
  const summary = [
    [UX.clsReadyAfterPrep, counts.ready - counts.someTargets, 'good'],
    [UX.clsSomeTargets, counts.someTargets, 'warn'],
    [UX.clsBlocked, counts.cannotYet, 'bad'],
    [UX.colCurrent, counts.current, 'quiet'],
    [UX.clsExcluded, counts.excluded, 'quiet'],
  ].filter(([, n]) => n > 0)
   .map(([label, n, tone]) => `<span class="pill ${tone}">${esc(label)}: ${n}</span>`).join(' ');

  const prep = groupByCode(vms, 'prepNeeded');
  const excluded = vms.filter(v => v.classification === 'Excluded').map(v => v.name || vmName(v.vmId));

  const a = row.approval;
  const approvalBlock = a
    ? `<div class="card" style="margin:10px 0"><div class="cardbody">
         <span class="pill good">${esc(UX.reviewed)}</span>
         <span class="muted" style="margin-left:8px">${esc(UX.reviewedBy)} ${esc((a.approvedBy && a.approvedBy.identity) || '')}
         &middot; ${esc(ago(a.approvedUtc))}</span>
         ${a.note ? `<div style="margin-top:6px">${esc(a.note)}</div>` : ''}
       </div></div>`
    : `<div class="card" style="margin:10px 0"><div class="cardbody">
         <span class="pill warn">${esc(UX.notReviewed)}</span>
         <div class="muted" style="margin-top:6px">${esc(UX.notReviewedWhy)}</div>
         <label class="muted" style="display:block;margin-top:10px;font-size:12px" for="approve-note">${esc(UX.reviewNote)}</label>
         <input id="approve-note" type="text" maxlength="200" placeholder="${esc(UX.reviewNoteHint)}"
                style="width:100%;margin-top:4px;padding:7px 10px;border:1px solid var(--line);border-radius:8px;font:inherit;font-size:13px">
         <div style="margin-top:10px"><button type="button" class="btn" data-approve="${esc(row.id)}"${row.version || DEMO_MODE ? '' : ' disabled'}>${esc(UX.reviewBtn)}</button>${approveWhy(row)}</div>
       </div></div>`;

  // No .detail wrapper: this is drawn INSIDE the shared panel now, which
  // supplies its own padding and containment.
  // The panel is wide, so the scope is spelled out here in full - including the
  // subscription id the table cell has to truncate.
  const scopeLine = `<div class="muted" id="report-scope" style="margin:2px 0 10px">${scopeLineHtml(row)}</div>`;
  // PAGE-SCALE-ASSESSMENTS-1: the name the list shows, the run id under it.
  let html = `<h3>${esc(reportTitle(row))}</h3><div class="mono muted vmf-sub">${esc(row.id)}</div>${scopeLine}<div style="margin:10px 0">${summary}</div>${approvalBlock}${plannedHtml(row)}`;

  const { stops, limits } = splitBlockers(vms);
  html += `<h4>${esc(UX.holdingBack)}</h4>`;
  html += stops.length
    ? stops.map(([code, names]) => reasonCard(code, names, 'bad')).join('')
    : `<p class="muted">${esc(UX.nothingBlocked)}</p>`;
  // SERIES-COUNT-1: a reason that closes only some targets is not red.
  if (limits.length) {
    html += `<h4>${esc(UX.limitsTarget)}</h4>` + limits.map(([code, names]) => reasonCard(code, names, 'warn')).join('');
  }
  // ALREADY-CURRENT-1: the machines on a Current size, each with its line.
  html += window.VmfReport.currentHtml(vms);

  // DETECT-PATTERNS-1: what a person checks before the move. These machines
  // can still move, so the section is neither red nor handled for you.
  html += window.VmfReport.warningsHtml(vms);

  if (excluded.length) {
    // Platform-managed machines are not a problem to solve - they are out of
    // scope by design, and saying so stops somebody chasing them.
    html += `<h4>${esc(UX.notEligible)}</h4><div class="card" style="margin:10px 0"><div class="cardbody">
      <div class="muted">${esc(UX.notEligibleWhy)}</div>
      ${chipList(excluded)}
    </div></div>`;
  }

  if (prep.length) {
    html += `<h4>${esc(UX.willPrepare)}</h4>`;
    html += `<p class="muted">${esc(UX.willPrepareWhy)}</p>`;
    // IDENTITY-4: this finding used to carry a per-machine note listing what
    // each identity could reach, and a control to ask the wider question. Both
    // are gone - the product says the risk and the customer assesses the
    // impact - so every machine here says the reason's own words.
    html += prep.map(([code, names]) => reasonCard(code, names, 'quiet')).join('');
  }

  // DETECT-PATTERNS-1: every machine's workload type, with a filter, and the
  // Azure facts that decided it - excluded machines too, because the type is
  // what tells a person how the service that owns one moves it.
  html += window.VmfReport.workloadTableHtml(vms);

  // REPORT-GAP-1: last, because it is about the report itself rather than
  // about a machine - and empty when the scan read everything it asked for.
  html += window.VmfReport.notReadHtml(row.notRead);

  return html;
}

/* REAPER-1: clearing up scans nobody finished.
 *
 * The wizard has to create the run at step one - the scan is the first real
 * action and takes minutes - so abandoning the wizard leaves a scan for ever.
 * This asks the engine what WOULD go, shows it, and only then removes.
 *
 * The engine keeps anything with a plan, anything recent, and anything whose
 * age it cannot read. None of those rules are restated here.
 */
async function tidyAbandoned(btn) {
  const label = btn.textContent;
  btn.disabled = true;
  btn.textContent = UX.tidyBusy;
  try {
    const preview = await api('POST', 'maintenance/abandoned', { olderThanDays: 30 });
    const candidates = preview.Candidates ?? preview.candidates ?? [];
    if (!candidates.length) {
      $('#err').textContent = UX.tidyNone;
      $('#err').style.display = 'block';
      return;
    }
    // POPUP-1: the list is shown IN the page, with the question, and the
    // removal runs only from its Yes.
    const names = candidates.map(c => `${c.Id ?? c.id} (${c.AgeDays ?? c.ageDays} days old)`);
    btn.disabled = false;
    btn.textContent = label;
    VmfHelp.confirmInPlace(btn, { ask: UX.tidyFound, lines: names, desc: UX.tidyKept, yes: UX.tidyYes, cancel: UX.cancel, under: '.pagehead' },
      () => tidyAbandonedNow(btn, label));
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
}

async function tidyAbandonedNow(btn, label) {
  btn.disabled = true;
  btn.textContent = UX.tidyBusy;
  try {
    const done = await api('POST', 'maintenance/abandoned', { olderThanDays: 30, apply: true });
    const removed = done.Removed ?? done.removed ?? [];
    await loadAssessments();
    renderTable();
    const ok = $('#err');
    ok.textContent = VmfHelp.countWords(removed.length, UX.tidyDone);
    ok.style.background = 'var(--good-soft)';
    ok.style.color = 'var(--good)';
    ok.style.display = 'block';
    setTimeout(() => { ok.style.display = 'none'; ok.style.background = ''; ok.style.color = ''; }, 4000);
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
}

/* Deleting an assessment. The facade refuses anything still working on a
 * machine, and this page refuses one a migration was planned from - that
 * migration records where it came from, and an assessment deleted underneath
 * it leaves a record pointing at nothing. */
function discardAssessment(id, btn) {
  // POPUP-1: asked in the row, not in a browser box.
  VmfHelp.confirmInPlace(btn, { ask: UX.delTitle, desc: UX.delDesc, yes: UX.delYes, cancel: UX.cancel, under: 'tr' },
    () => discardAssessmentNow(id, btn));
}

async function discardAssessmentNow(id, btn) {
  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = UX.delBusy;
  try {
    // RUNID-2: this page split the id by hand, correctly, and was the only one
    // that did. The rule lives in help.js now.
    await api('POST', `runs/${VmfHelp.VmfRun.routeSegment(id)}/discard`,
      VmfHelp.VmfRun.withProject({ note: 'deleted from the assessments page' }, id));
    window.VmfReport.closePanel();
    await loadAssessments();
    renderTable();
    // The page has one message area. Say it happened - a row that silently
    // vanishes leaves a person wondering whether they pressed anything.
    const ok = $('#err');
    ok.textContent = UX.delDone;
    ok.style.background = 'var(--good-soft)';
    ok.style.color = 'var(--good)';
    ok.style.display = 'block';
    setTimeout(() => { ok.style.display = 'none'; ok.style.background = ''; ok.style.color = ''; }, 4000);
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
    btn.disabled = false;
    btn.textContent = label;
  }
}

/* PAGE-SCALE-ASSESSMENTS-1: the list is mounted ONCE. The page draws again
 * as each assessment lands (WAIT-1), and a list drawn again from nothing would
 * throw away the tile, the project, the search and the page a person chose.
 * ?project= (from the Projects page) is the project filter to start with. */
let assessList = null;
// The run whose report is open in the panel, or null.
let openReportId = null;
// ASSESS-APPROVAL-HASH-1: the version of the scan that panel shows, or ''.
let openReportVersion = '';
// ?run= opens that report once, after the store is read.
let reportAsked = false;

function renderTable() {
  if (!assessList) {
    const host = $('#assessments-list');
    // A project from the Projects page asks for that project's assessments:
    // the list opens on All assessments, not on a tile it may have no row in.
    const project = new URLSearchParams(location.search).get('project') || '';
    assessList = VmfHelp.listMount(host, { id: 'as', preferred: project ? 'all' : 'review', searchHint: UX.searchHint,
      project, columns: assessmentColumns(), waiting: UX.waiting });
    host.addEventListener('click', onListClick);
  }
  assessList.update({ tiles: assessmentTiles(rows), projects: projectChoices(rows), reading: reading === true, failed: reading === null });
  openAskedReport();
}

/* A row's controls are the shared list's; the page listens for their click.
 * Delete asks in the row (POPUP-1). The name opens the report beside the list
 * (one report at a time: two side by side read as one long page of reasons).
 * A click that asks for a new tab or window keeps the address, which opens
 * the same report there. */
function onListClick(e) {
  const del = e.target.closest('button[data-action="delete"]');
  if (del) { if (!del.disabled) { discardAssessment(del.dataset.value, del); } return; }
  const link = e.target.closest('a[data-action="report"]');
  if (!link) { return; }
  if (e.button > 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) { return; }
  if (openReport(link.dataset.value)) { e.preventDefault(); }
}

/* Opens the report of one assessment in the SHARED side panel - the same one
 * the run page uses for a machine. It has a Close button and Escape closes it
 * (rule 11); the keyboard goes to Close, and comes back to the row's name
 * when the panel closes. false when the page holds no such assessment. */
function openReport(id, redraw) {
  const data = rows.find(x => x.id === id);
  if (!data) { return false; }
  // ASSESS-APPROVAL-HASH-1: a person who opens the report asks again after a
  // failed read; the redraw after the read (redraw) does not.
  if (!redraw) { data.versionFailed = false; }
  window.VmfReport.closePanel();
  const panel = window.VmfReport.openPanel(reportHtml(data));
  openReportId = id;
  // ASSESS-APPROVAL-HASH-1: the version of the scan this panel shows. A
  // reload of the list (Clear up old scans) makes new rows and leaves the
  // panel as drawn, so the approval quotes the panel's version, not a row's.
  openReportVersion = data.version || '';
  const btn = panel.querySelector('[data-approve]');
  if (btn) { btn.addEventListener('click', () => approve(btn.dataset.approve, btn)); }
  // ASSESS-APPROVAL-HASH-1: the scan this report shows, with its version.
  if (!redraw && !data.approval && !data.version && !DEMO_MODE) { loadReportVersion(id); }
  const close = panel.querySelector('.close');
  if (close) {
    if (!close.dataset.vmfReturn) { close.dataset.vmfReturn = '1'; close.addEventListener('click', reportClosed); }
    close.focus();
  }
  return true;
}

/* ASSESS-APPROVAL-HASH-1: an approval names the scan the person read, by the
 * version the service issued for it (PLANVER-2) - the service refuses another
 * one, and planning holds to the scan an approval names. The list comes from
 * one call that gives no version (VmfHelp.storeDocs), so the report of an
 * assessment nobody approved reads assessment.json again WITH its version,
 * and is drawn again from that text. Approve stays off until then. The note
 * typed meanwhile is kept. */
async function loadReportVersion(id) {
  const row = rows.find(x => x.id === id);
  if (!row) { return; }
  try {
    const v = await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, `${id}/assessment.json`, { asVersioned: true });
    if (!v || !v.text || !v.version) { throw new Error(UX.reviewReadFailed); }
    const doc = JSON.parse(v.text);
    row.vms = (doc && doc.vms) ? doc.vms : [];
    row.machines = row.vms.length;
    row.notRead = doc?.notRead ?? [];
    row.version = v.version;
  } catch (e) {
    // The reason goes beside the button that stays off, and the error in the
    // page's message area.
    row.versionFailed = true;
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
  }
  if (openReportId !== id || row.approval) { return; }
  const field = document.getElementById('approve-note');
  const note = field ? field.value : '';
  openReport(id, true);
  const again = document.getElementById('approve-note');
  if (again) { again.value = note; }
}

/* The panel closed: the keyboard goes back to the name that opened it. */
function reportClosed() {
  if (!openReportId) { return; }
  const id = openReportId;
  openReportId = null;
  openReportVersion = '';
  const host = $('#assessments-list');
  const link = host ? [...host.querySelectorAll('a[data-action="report"]')].find(a => a.dataset.value === id) : null;
  if (link) { link.focus(); }
}
function onReportKey(e) {
  if (e.key !== 'Escape' || !openReportId) { return; }
  window.VmfReport.closePanel();
  reportClosed();
}

/* The report ?run= names (an address from another tab, or a link), opened
 * once the store is read - the reason texts are read by then too. */
function openAskedReport() {
  if (reading || reportAsked) { return; }
  reportAsked = true;
  const id = VmfHelp.VmfRun.fromQuery(location.search);
  if (id) { openReport(id); }
}

// The one thing on this page that changes anything, and it changes a DECISION
// rather than a machine. Approving is what lets a migration be planned - the
// engine refuses without it, so this is not a button that merely records an
// opinion.
/* Approving is the one thing on this page that changes anything.
 *
 * It used to open a browser prompt box demanding "What did you conclude?" -
 * "What did you conclude" was a required riddle. The note is
 * optional now (cmdlet, facade and schema all agree), so it belongs as a field
 * next to the button, in the panel where the findings are, not as a modal that
 * blocks the page and cannot be read while you type into it. */
async function approve(id, btn) {
  const field = document.getElementById('approve-note');
  const note = (field ? field.value : '').trim();
  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = UX.reviewWorking;
  try {
    // PROJECT-1: ids are now `project/run` for anything inside a project, and a
    // slash does not survive the route. Split it and send the project in the
    // body, the same shape the engine dispatch uses.
    // ASSESS-APPROVAL-HASH-1: and the version of the scan the report showed
    // (loadReportVersion). The service refuses another version with 409.
    const shown = openReportId === id ? openReportVersion : '';
    await api('POST', `assessments/${VmfHelp.VmfRun.routeSegment(id)}/approve`,
      VmfHelp.VmfRun.withProject({ note, assessmentHash: shown }, id));
    await loadAssessments();
    renderTable();
    // PAGE-SCALE-ASSESSMENTS-1: the report shows what was recorded, not the
    // button it was recorded with.
    if (openReportId === id) { openReport(id); }
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
    btn.disabled = false;
    btn.textContent = label;
  }
}

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  VmfHelp.identity(account);
  $('#list-title').textContent = UX.title;
  $('#lede').textContent = UX.lede;
  $('#assess-btn').textContent = UX.scanBtn;
  const tidy = $('#tidy-btn');
  tidy.textContent = UX.tidyBtn;
  tidy.title = UX.tidyTip;
  tidy.addEventListener('click', () => tidyAbandoned(tidy));
  // Rule 11: Escape closes the report, and the keyboard goes back to its row.
  document.addEventListener('keydown', onReportKey);
  $('#app').style.display = 'block';
  // SCOPE-NAME-1: kicked off here and NOT awaited. Redraws the table when the
  // names land; until then the rows show ids, which is what they showed
  // before and is never wrong, only less readable.
  if (DEMO_MODE) { scopes = DEMO_SCOPES; }
  else {
    api('GET', 'scopes')
      .then(d => { scopes = d; refreshScopeLine(); })
      .catch(() => { /* ids stay; the facade being asleep is not this page's failure */ });
  }
  // WAIT-1: paint before reading, so the page says what it is reading rather
  // than saying nothing has been assessed while it is still looking.
  renderTable();
  // PAGE-WAIT-1: the reason texts are a file beside the page, needed only to
  // draw - read beside the assessments, not before them.
  // LOADING-LINE-1: a failed read ends the read too, so the list is drawn
  // in the finally; the error itself still reaches the page's error message.
  try { await Promise.all([loadReasons(), loadAssessments()]); reading = false; }
  catch (e) { reading = null; throw e; }
  finally { renderTable(); }
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
const T = (minAgo) => new Date(Date.now() - minAgo * 60000).toISOString();
const sampleVm = (n, cls, blockers, prep) => ({
  vmId: '/subscriptions/0/resourceGroups/rg-sample/providers/Microsoft.Compute/virtualMachines/' + n,
  name: n, classification: cls, blockers: blockers || [], prepNeeded: prep || [] });
// DETECT-PATTERNS-1: the workload type and the facts behind it, and a warning.
const typed = (vm, type, evidence, warnings) => Object.assign(vm, { workload: { type, evidence: evidence || [] }, warnings: warnings || [] });
const SAMPLE_DISK = '/subscriptions/0/resourceGroups/rg-sample/providers/Microsoft.Compute/disks/';
/* PAGE-SCALE-ASSESSMENTS-1: sample projects, and enough sample assessments in
 * them to fill more than one page of the list: some to review, some accepted
 * with no migration, some planned, and one outside a project. */
const DEMO_PROJECTS = [
  { id: 'datacentre-exit', name: 'Datacentre exit' }, { id: 'payments-refresh', name: 'Payments platform refresh' },
  { id: 'web-tier', name: 'Web tier' }, { id: 'data-platform', name: 'Data platform' },
  { id: 'branch-offices', name: 'Branch offices' }, { id: 'retail-stores', name: 'Retail stores' },
];
const DEMO = {
  'datacentre-exit/estate-scan-august': {
    'run.json': { schemaVersion: 8, kind: 'assessment', runId: 'estate-scan-august', project: 'datacentre-exit', createdUtc: T(2880),
                  scope: { subscriptions: ['00000000-0000-0000-0000-000000000000'], managementGroup: null, resourceGroups: [] } },
    'assessment.json': { schemaVersion: 4, runId: 'estate-scan-august', generatedUtc: T(2880),
      vms: [typed(sampleVm('prd-web-a', 'ReadyAfterPrep', [], ['stornvme', 'pagefile']), 'standalone-vm'),
            typed(sampleVm('prd-web-b', 'ReadyAfterPrep', [], ['stornvme', 'pagefile']), 'standalone-vm'),
            // A Windows machine with a system-assigned identity. REBUILD-REMOVE-PLAN-1:
            // the scan gives it no identity finding now - its move keeps the identity.
            typed(Object.assign(sampleVm('prd-ebs-a', 'ReadyAfterPrep', [], ['stornvme', 'pagefile']), {
              identityType: 'SystemAssigned', identityPrincipalId: '11111111-2222-3333-4444-555555555555' }), 'standalone-vm'),
            // ALREADY-CURRENT-1: a machine already on a size in the Current
            // lifecycle stage. It is counted as Current, not as Cannot yet.
            typed(Object.assign(sampleVm('prd-web-v6', 'ReadyAfterPrep'), {
              sourceSize: 'Standard_D2ds_v6', sourceLifecycle: { stage: 'Current', basis: 'stated' } }), 'standalone-vm'),
            typed(sampleVm('prd-sql-a', 'ReadyAfterPrep', [], ['stornvme']), 'cluster-or-database',
              [{ field: 'Microsoft.SqlVirtualMachine/sqlVirtualMachines', value: '/subscriptions/0/resourceGroups/rg-sample/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/prd-sql-a' }],
              ['sql-server-agree-downtime']),
            typed(sampleVm('prd-fs-a', 'Blocked', ['shared-disk-cluster-node'], ['stornvme']), 'cluster-or-database',
              [{ field: 'disk.maxShares', value: '2 (' + SAMPLE_DISK + 'quorum-01)' }]),
            typed(sampleVm('bkp-vault-1', 'Blocked', ['storage-appliance-needs-vendor', 'image-not-supported']), 'vendor-appliance',
              [{ field: 'imageReference.publisher', value: 'veeam' }, { field: 'imageReference.offer', value: 'veeam-backup-replication' }]),
            typed(sampleVm('legacy-gen1', 'Blocked', ['gen1-requires-redeploy']), 'standalone-vm'),
            typed(sampleVm('legacy-win-a', 'Blocked', ['gen1-requires-redeploy', 'windows-version-below-2019']), 'standalone-vm'),
            typed(Object.assign(sampleVm('aks-node-1', 'Excluded'), { platformManaged: true }), 'node-pool-or-scale-set',
              [{ field: 'resourceGroup.managedBy', value: '/subscriptions/0/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod' }])] },
  },
  'datacentre-exit/estate-scan-august-migration-20260830-0900': {
    'run.json': { schemaVersion: 8, kind: 'migration', runId: 'estate-scan-august-migration-20260830-0900', project: 'datacentre-exit',
                  createdUtc: T(2700), fromAssessment: 'estate-scan-august' },
  },
  'payments-refresh/finance-scan': {
    'run.json': { schemaVersion: 8, kind: 'assessment', runId: 'finance-scan', project: 'payments-refresh', createdUtc: T(120),
                  scope: { subscriptions: [], managementGroup: null, resourceGroups: ['rg-finance'] } },
    'assessment.json': { schemaVersion: 1, runId: 'finance-scan', generatedUtc: T(120),
      vms: [sampleVm('fin-app-a', 'ReadyAfterPrep', [], ['stornvme']),
            sampleVm('fin-conf-a', 'Blocked', ['confidential-vm-requires-manual']),
            sampleVm('fin-old-disk', 'Blocked', ['unmanaged-os-disk'])] },
  },
};
DEMO['datacentre-exit/estate-scan-august']['approval.json'] = { approvedBy: { identity: 'sam@contoso.com' }, approvedUtc: T(2760), note: null };
// One assessment outside a project: the list names it Outside a project.
DEMO['scan-before-projects'] = {
  'run.json': { schemaVersion: 8, kind: 'assessment', runId: 'scan-before-projects', createdUtc: T(80640) },
  'assessment.json': { schemaVersion: 1, runId: 'scan-before-projects', generatedUtc: T(80640),
    vms: [sampleVm('old-app-a', 'ReadyAfterPrep', [], ['stornvme'])] },
};
// Each of the others: [project, minutes ago, machines, blocked, 'review' | 'accepted' | 'planned'].
[['web-tier', 300, 12, 1, 'review'], ['data-platform', 900, 7, 0, 'review'], ['retail-stores', 1500, 22, 3, 'accepted'],
 ['web-tier', 4320, 9, 0, 'planned'], ['branch-offices', 5760, 4, 1, 'accepted'], ['data-platform', 7200, 15, 2, 'planned'],
 ['retail-stores', 8640, 18, 0, 'planned'], ['payments-refresh', 10080, 6, 1, 'accepted'], ['branch-offices', 11520, 3, 0, 'planned'],
 ['web-tier', 14400, 11, 2, 'planned'], ['data-platform', 20160, 8, 0, 'accepted'], ['retail-stores', 28800, 20, 4, 'planned'],
 ['datacentre-exit', 40320, 31, 5, 'planned'], ['branch-offices', 50400, 5, 0, 'review']].forEach(([project, ago, machines, blocked, status], i) => {
  const runId = `assessment-${String(i + 1).padStart(2, '0')}`;
  const vms = Array.from({ length: machines }, (_, k) => k < blocked
    ? sampleVm(`${project}-${i + 1}-${k + 1}`, 'Blocked', ['confidential-vm-requires-manual'])
    : sampleVm(`${project}-${i + 1}-${k + 1}`, 'ReadyAfterPrep', [], ['stornvme']));
  const run = { 'run.json': { schemaVersion: 8, kind: 'assessment', runId, project, createdUtc: T(ago),
                              scope: { subscriptions: [], managementGroup: null, resourceGroups: [`rg-${project}`] } },
                'assessment.json': { schemaVersion: 4, runId, generatedUtc: T(ago), vms } };
  if (status !== 'review') { run['approval.json'] = { approvedBy: { identity: 'sam@contoso.com' }, approvedUtc: T(ago - 60), note: null }; }
  DEMO[`${project}/${runId}`] = run;
  if (status === 'planned') {
    const mig = `${runId}-migration`;
    DEMO[`${project}/${mig}`] = { 'run.json': { schemaVersion: 8, kind: 'migration', runId: mig, project, createdUtc: T(ago - 120), fromAssessment: runId } };
  }
});

// The help button is DRAWN by installNav() in help.js, but its click handler is
// attached by install(). A page that skips this gets a tab that looks like a
// control and behaves like a dead link to '#'.
if (window.VmfHelp) VmfHelp.install({ getMsal: () => msalApp, getRunId: () => null });

boot().catch(e => { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; });
