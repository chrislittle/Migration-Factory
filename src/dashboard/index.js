const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const DEMO_MODE = new URLSearchParams(location.search).has('demo');

// OVERVIEW-SUMMARY-1: which machine states wait for a person, and what a
// migration waits for, are not decided on this page. They are VmfHelp's
// (help.js) - the same code the migrations list groups by - so the two pages
// cannot disagree about one migration.

/* ============================ UX-STRINGS-BEGIN ============================
   ASD-STE100: short sentences, active voice, one meaning per word, technical
   names used rather than avoided. */
const UX = {
  title:      'Overview',
  lede:       'What is waiting for you, and what runs now.',
  assessBtn:  'Assess an estate',

  // PAGE-SCALE-OVERVIEW-1: the four count tiles, and what each list says when
  // it has no row. OVERVIEW-SUMMARY-1: the first two are the groups of the
  // same names in the migrations list.
  personTitle:  'Waiting for a person',
  personHint:   'A machine stopped. A person must make a decision.',
  personNone:   'No migration waits for a person.',
  approvalTitle: 'Waiting for approval',
  approvalHint:  'The next wave cannot start until a person acts.',
  approvalNone:  'No migration waits for approval.',
  runningTitle: 'Running now',
  runningHint:  'Machines move now.',
  runningNone:  'No migration is running.',
  reviewTitle:  'Assessments to review',
  reviewHint:   'Accept an assessment to plan a migration from it.',
  reviewNone:   'No assessment waits for a review.',

  // The columns of the list. The third column is the tile's own.
  colMigration:  'Migration',
  colAssessment: 'Assessment',
  colProject:    'Project',
  colStopped:    'Stopped at',
  colNext:       'Next action',
  colWave:       'Wave',
  colMachines:   'Machines',
  colMoving:     'Machines moving',
  colFound:      'Machines found',
  colWhen:       'Last change',
  searchHint:    'Migration or project',
  // OVERVIEW-SUMMARY-1: a status whose summary cannot be read.
  attentionUnknown: 'Not known',
  // The tag the migrations list shows (accept, approve or start), and its wave.
  approvalTag:  '{tag} {wave}',
  reviewOpen:   'Review',
  waiting:      'Reading your projects and migrations.',

  firstTitle: 'Start here',
  firstBody:  'A project holds one estate. It holds the assessments of that estate, and the migrations planned from them.',
  firstThen:  'Create a project first. Then assess the machines in it.',
  firstBtn:   'Create a project',

  working:    'Reading what you can see...',
  // Runs that are in no project.
  loose:      'Outside a project',
};
/* ============================= UX-STRINGS-END ============================= */

let cfg = null, msalApp = null, account = null;

async function getToken() {
  const req = { scopes: [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
/* PERF-ONE-LIMIT-1: ONE limit for every read this page sends to the service.
 * The projects and their runs are walked one inside the other, and each walk
 * had its own 8, so up to 64 reads were in flight and the service added cold
 * instances during the load. Every read below takes a slot from this one. */
const storeRead = VmfHelp.readLimiter();
/* PAGE-LOAD-1: what ONE call to the service gave this load (VmfHelp.storeDocs):
 * the store listed, and every document the panels draw. MEASURED on a lab
 * install: this page sent about 200 calls on one load, one for each document,
 * and took a minute or two. blobList and blobJson answer from it first, and
 * ask the service only what it cannot answer (unknown means ask). null when
 * the call failed - then every read goes to the service, as before. */
let held = null;
// The documents the panels draw. PAGE-SCALE-REPORTS-1: the Safety copies
// card, and the second call it made for its deeper documents, moved to the
// Reports page, which reads them in its own one call.
const PANEL_READS = ['project.json', 'run.json', 'run-status.json', 'assessment.json', 'approval.json'];
async function readHeld(depth, read) {
  return storeRead(() => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { depth, read })).catch(() => null);
}
async function blobList(prefix, delimiter) {
  const known = VmfHelp.heldList(held, prefix, delimiter);
  if (known) { return known; }
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return storeRead(() => VmfHelp.storeList(() => getToken(), cfg.apiUrl, prefix, delimiter));
}
async function blobJson(path) {
  const known = VmfHelp.heldJson(held, path);
  if (known) { return known.value; }
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  try { return await storeRead(() => VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path)); }
  catch { return null; }
}

/* RUN-404-1: a run at setup has no plan, so it has no run-status.json, and
 * this page once asked for it fourteen to twenty-one times a session. It asked
 * the service which runs had started (GET /runs) to avoid that. PAGE-LOAD-1:
 * the listing that comes with the page's one call already says whether the
 * document is there, so a run at setup is never asked for it, and the list of
 * runs is not asked for at all. */
/* Read everything once, then let each panel take what it needs.
 *
 * The shape here is deliberately the same one Projects and Assessments use:
 * a run is a prefix holding a run.json that says its kind, and a project is a
 * prefix holding a project.json. Nothing on this page keeps a tally of its
 * own - every number is counted from the documents, so it cannot drift from
 * the page that owns it. */
let state = { projects: [], loose: [], runs: [] };
// WAIT-1: true until the store has been read. It decides one thing - whether
// an empty overview means 'you have nothing' or 'I have not looked yet'.
// TILE-COUNT-READING-1: null once the read FAILED - not reading, and nothing
// known, so the tiles say Not known and the list says the read failed.
let reading = true;

async function load() {
  if (DEMO_MODE) { state = DEMO_STATE; return; }

  // PAGE-LOAD-1: ONE call for the listing and every document the panels draw.
  // The walk below is the walk it always was; its reads are answered from
  // what this call gave, and only what it could not say goes to the service.
  held = await readHeld(3, PANEL_READS);
  // PROJECT-3: the claim registry and an event log are not runs. The same rule
  // the service walks by, so a folder beside the runs is never asked for a run
  // record it cannot have.
  const listing = await blobList('', '/');
  const top = listing.prefixes.filter(VmfHelp.runFolderIsRun);
  const projects = [], loose = [], runs = [];
  const show = () => {
    // WAIT-1: this page already paints its panels as they resolve. This
    // carries it one level in, so a project's runs appear as they land.
    state = { projects: projects.slice(), loose: loose.slice(), runs: runs.filter(Boolean) };
    render();
  };
  const take = async (path, manifest, projectId) => {
    runs.push(await readRun(path, manifest, projectId));
  };

  // STORE-READ-2: projects x runs, paced. This runs before the overview paints
  // anything, so every viewer paid the unbounded version on every visit.
  await VmfHelp.mapLimited(top, async (p) => {
    /* PERF-PROBES-1: a prefix is a project or a run. PAGE-WAIT-1 asked for
     * project.json and run.json together, and one of the two is always not
     * there. Now ONE listing of the folder says which it holds, and only that
     * file is read. A project needed this listing anyway, for its runs, so
     * its document is now read BESIDE its runs' manifests: two round trips
     * for a project where there were three, and one call fewer. A run outside
     * a project takes two round trips where it took one - those are few. */
    // PROJECT-3: the folders beside the runs are not runs, so they are left out
    // of the listing at once.
    const listFolder = () => blobList(`${p}/`, '/').then(l => ({ ...l, prefixes: l.prefixes.filter(VmfHelp.runFolderIsRun) }));
    const listing = await listFolder().catch(() => null);
    const has = (rel) => VmfHelp.storeHolds(listing, `${p}/${rel}`);
    const projectRead = has('project.json') ? blobJson(`${p}/project.json`) : Promise.resolve(null);
    // With no listing, both questions are asked at once, as before.
    const manifestRead = () => (has('run.json') ? blobJson(`${p}/run.json`) : Promise.resolve(null));
    const looseRead = listing ? null : manifestRead();
    let assessments = 0, migrations = 0;
    const walkRuns = (inside) => VmfHelp.mapLimited(inside.prefixes.filter(VmfHelp.runFolderIsRun), async (k) => {
      const manifest = await blobJson(`${k}/run.json`).catch(() => null);
      const project = await projectRead;
      if (!manifest || !project) return;
      if (VmfHelp.runKind(manifest) === 'assessment') { assessments++; } else { migrations++; }
      await take(k, manifest, project.projectId);
    }, undefined, show);
    const runsRead = listing && has('project.json') ? walkRuns(listing) : null;
    const project = await projectRead;
    // A prefix with a run.json IS a run, sitting outside any project (the
    // command line can make one), and hiding it is how somebody concludes
    // their migration has vanished.
    if (!project) {
      if (runsRead) { await runsRead; }
      const manifest = await (looseRead || manifestRead());
      if (manifest) { loose.push(p); await take(p, manifest, null); }
      return;
    }
    await (runsRead || walkRuns(listing ?? await listFolder()));
    projects.push({ id: project.projectId, name: project.name, created: project.createdUtc,
                    assessments, migrations });
  });


  state = {
    projects: projects.sort((a, b) => String(a.name).localeCompare(String(b.name))),
    loose: loose.sort(),
    runs: runs.filter(Boolean),
  };
}

// One run, with only what a panel here needs. A migration's status is the
// engine's own run-status.json; an assessment's review state is its
// approval.json. Both are read, never guessed.
async function readRun(path, manifest, projectId) {
  // RETAIN-KIND-1: the one rule, which the daily check asks too.
  const kind = VmfHelp.runKind(manifest);
  const id = String(path);
  if (kind === 'assessment') {
    const [doc, approval] = await Promise.all([
      blobJson(`${path}/assessment.json`).catch(() => null),
      blobJson(`${path}/approval.json`).catch(() => null),
    ]);
    const created = (manifest && manifest.createdUtc) || (doc && doc.generatedUtc) || null;
    // PAGE-SCALE-OVERVIEW-1: `created` names the run (VmfHelp.runTitle).
    return { id, kind, projectId, approved: !!approval,
             found: ((doc && doc.vms) || []).length,
             created, when: created };
  }
  // RUN-404-1: a run at setup has no plan, so it has no status document. The
  // listing the page holds says so, and blobJson then asks nothing.
  const status = await blobJson(`${path}/run-status.json`).catch(() => null);
  // No stage: the only group a panel shows, Waiting for approval, comes from
  // the summary in this document, which a run at setup does not have.
  const created = (manifest && manifest.createdUtc) || null;
  return { id, kind, projectId, status, ...migrationFacts(status), created,
           when: (status && status.updatedUtc) || created };
}

/* OVERVIEW-SUMMARY-1: what the panels need from one migration's status, from
 * the ONE document read above.
 *
 * The status document was a snapshot of the running wave, so this page counted
 * that wave only: a migration with a stopped machine in wave 1 and wave 2
 * running showed wave 2's problems, and one waiting for approval of its next
 * wave was not shown at all. The same document holds a summary of the WHOLE
 * migration, and the migrations list groups by it. This asks the list's own
 * questions (VmfHelp.runGroup), so the two cannot differ.
 *
 *   attention  machines across the whole migration that wait for a person
 *              (the summary's waitsOnPerson); 0 with no status document (no
 *              machine started); or null - NOT KNOWN - when the document has
 *              no summary this page can read. The live counts are one wave's,
 *              so they are never read for the migration
 *              (OLD-VERSION-READERS-REMOVE-6).
 *   waits      the next wave and the tag (accept, approve or start), when the list
 *              puts this migration under Waiting for approval.
 *   running    the machines the running wave is moving: the live fields,
 *              which v3 keeps for exactly this - and only while the list puts
 *              the migration under In progress (OVERVIEW-RUNNING-STALE-1).
 *              Nothing writes the live fields again after a wave ends, so a
 *              list the engine wrote last stayed on Running now for ever: a
 *              finished migration showed Machines moving 1. runGroup says In
 *              progress only for a status written in the last fifteen
 *              minutes, which is the Migrations page's own answer. */
function migrationFacts(status, stage) {
  const summary = VmfHelp.runSummaryOf(status);
  const live = (status && status.stateCounts) || null;
  const updatedMs = status && status.updatedUtc ? Date.parse(status.updatedUtc) : 0;
  const group = VmfHelp.runGroup(stage === 'setup', live, updatedMs, Date.now(), { summary });
  const attention = summary
    // RESTORED-HOLD-1: a machine whose stop a restore ended waits for nobody.
    // RUN-SUMMARY-SWAP-1: and a machine a restore left stopped waits, though
    // its state is MIGRATED - the summary's count by the one definition.
    ? VmfHelp.runWaitingCount(summary)
    : (status ? null : 0);
  const waits = group === 'Waiting for approval'
    ? { wave: summary.next.wave || '', tag: VmfHelp.runGateTag(summary.next.waitsFor) }
    : null;
  return { summary, attention, waits,
           running: group === 'In progress' ? ((status && status.running) || []).length : 0,
           wave: status && status.wave };
}


/* The page's own furniture - the things that are true before any data is
 * read. A viewer with no store access saw `list : HTTP 403` and an EMPTY
 * BLUE PILL underneath it.
 *
 * The pill was #assess-btn. Its label was set inside render(), render() runs
 * only after load() succeeds, and load() had thrown - so the button existed,
 * was styled, and said nothing. A failure must not leave a half-drawn page:
 * whatever does not depend on the data gets drawn before the data is asked
 * for. */
function chrome() {
  $('#h1').textContent = UX.title;
  $('#lede').textContent = UX.lede;
  $('#assess-btn').textContent = UX.assessBtn;
}

/* PAGE-SCALE-OVERVIEW-1: four count tiles and ONE list, in place of five
 * tables one after the other.
 *
 * With many migrations the page was one long scroll. Each table had a row
 * for every item, so the
 * migration that waited for a person could be screens down the page. The
 * tiles, the list, its search, its project filter and its pages are the
 * shared piece in help.js (VmfHelp.listMount); this page gives it the rows.
 *
 * Which migration goes in which tile is the rule each table used, unchanged:
 * a count that waits for a person (or NOT KNOWN), the list's Waiting for
 * approval group, machines moving now, an assessment nobody accepted. The
 * Projects table left the page: the Projects page owns it, and one line goes
 * there and to Reports. */
let overviewList = null;

function render() {
  chrome();

  // Nothing at all: a first visit. Say what to do, once, and stop - a wall of
  // empty panels tells somebody nothing except that the product is empty.
  // WAIT-1: and not before the store has been read. This card welcomes
  // somebody to an empty product. Showing it to a returning customer while
  // their estate is still being read tells them their work is gone.
  if (reading && !state.projects.length && !state.runs.length) {
    overviewList = null;
    $('#panels').innerHTML = `<div class="card"><div class="cardbody">
      ${VmfHelp.waitingLine(UX.waiting)}</div></div>`;
    return;
  }
  // TILE-COUNT-READING-1: and never after a read that failed - nothing was
  // read, so the product is not known to be empty.
  if (reading !== null && !state.projects.length && !state.runs.length) {
    // The formatting was poor: centred
    // body copy at a narrow measure, so a two-line sentence wrapped to leave
    // "in it." alone on a third line, under a centred heading, in a card the
    // full width of the page.
    //
    // Left-aligned, one comfortable measure, and the button under the text
    // where a person's eye already is.
    overviewList = null;
    $('#panels').innerHTML = `<div class="card"><div class="cardbody empty">
      <h2>${esc(UX.firstTitle)}</h2>
      <p class="muted">${esc(UX.firstBody)}</p>
      <p class="muted">${esc(UX.firstThen)}</p>
      <a class="btn" href="projects.html">${esc(UX.firstBtn)}</a>
    </div></div>`;
    return;
  }

  // The list is mounted ONCE. The page draws again as each project's runs
  // land (WAIT-1), and a list drawn again from nothing would throw away what
  // a person typed in its search box or the page they were on.
  if (!overviewList) {
    $('#panels').innerHTML = '<div id="ov-list"></div>';
    // LOADING-LINE-1: the list says UX.waiting, not a tile's "none", while the page still reads.
    overviewList = VmfHelp.listMount($('#ov-list'), { id: 'ov', preferred: 'person', searchHint: UX.searchHint, waiting: UX.waiting });
  }
  overviewList.update({ tiles: overviewTiles(state), projects: projectChoices(state), reading: reading === true, failed: reading === null });
}

/* The project filter's choices: every project by name, then the runs outside
 * a project, when there are any. */
function projectChoices(st) {
  const out = st.projects.map(p => ({ id: p.id, name: p.name }));
  if (st.runs.some(r => !r.projectId)) { out.push({ id: VmfHelp.LIST_LOOSE, name: UX.loose }); }
  return out;
}

/* OVERVIEW-SUMMARY-1, RUN-SUMMARY-SWAP-1: the waves of a migration with a
 * machine that waits for a person - the wave's own count, which the engine
 * writes for every wave. */
function stoppedWaves(summary) {
  return ((summary && summary.waves) || []).filter(w => (VmfHelp.runWaitingCount(w) || 0) > 0).map(w => w.wave);
}

/* One run as a row of the list: the readable name, the run id under it, and
 * the facts each tile's own column shows. */
function migrationRow(r, names) {
  const project = r.projectId ? (names.get(r.projectId) || r.projectId) : UX.loose;
  const row = { id: r.id, projectId: r.projectId || null, project, when: r.when,
                name: VmfHelp.runTitle(project, r.kind, r.created) };
  if (r.kind === 'assessment') {
    return Object.assign(row, { dest: { page: 'wizard', run: r.id }, machines: r.found,
                                next: { text: UX.reviewOpen, page: 'wizard', run: r.id } });
  }
  const unknown = { text: UX.attentionUnknown, tone: 'muted' };
  const waves = stoppedWaves(r.summary);
  return Object.assign(row, {
    dest: { page: 'migrations', run: r.id },
    stopped: r.attention === null || !waves.length ? unknown : { text: waves.join(', '), tone: 'bad' },
    waiting: r.attention === null ? unknown : { text: String(r.attention), tone: 'bad' },
    next: r.waits ? { text: UX.approvalTag.replace('{tag}', () => r.waits.tag || '').replace('{wave}', () => r.waits.wave || ''), tone: 'warn' } : null,
    planned: r.summary ? r.summary.machines : null,
    wave: r.wave || '', moving: r.running,
  });
}

function overviewTiles(st) {
  const names = new Map(st.projects.map(p => [p.id, p.name]));
  const newest = (a, b) => String(b.when || '').localeCompare(String(a.when || ''));
  const migrations = st.runs.filter(r => r.kind === 'migration');
  const assessments = st.runs.filter(r => r.kind === 'assessment');
  const rows = (list) => list.slice().sort(newest).map(r => migrationRow(r, names));
  const name = { head: UX.colMigration, kind: 'name' };
  const project = { head: UX.colProject, kind: 'text', key: 'project' };
  const when = { head: UX.colWhen, kind: 'ago', key: 'when' };
  // OVERVIEW-SUMMARY-1: null attention is "not known" - a status whose
  // summary cannot be read - so it is listed, never dropped as if it were zero.
  const person = rows(migrations.filter(m => m.attention === null || m.attention > 0))
    .map(r => Object.assign(r, { machines: r.waiting }));
  const approval = rows(migrations.filter(m => m.waits)).map(r => Object.assign(r, { machines: r.planned }));
  return [
    { key: 'person', label: UX.personTitle, hint: UX.personHint, empty: UX.personNone, tone: 'bad', rows: person,
      columns: [name, project, { head: UX.colStopped, kind: 'tag', key: 'stopped' }, { head: UX.colMachines, kind: 'num', key: 'machines' }, when] },
    { key: 'approval', label: UX.approvalTitle, hint: UX.approvalHint, empty: UX.approvalNone, tone: 'warn', rows: approval,
      columns: [name, project, { head: UX.colNext, kind: 'tag', key: 'next' }, { head: UX.colMachines, kind: 'num', key: 'machines' }, when] },
    { key: 'running', label: UX.runningTitle, hint: UX.runningHint, empty: UX.runningNone, rows: rows(migrations.filter(m => m.running > 0)),
      columns: [name, project, { head: UX.colWave, kind: 'text', key: 'wave' }, { head: UX.colMoving, kind: 'num', key: 'moving' }, when] },
    { key: 'review', label: UX.reviewTitle, hint: UX.reviewHint, empty: UX.reviewNone, rows: rows(assessments.filter(a => !a.approved)),
      columns: [{ head: UX.colAssessment, kind: 'name' }, project, { head: UX.colNext, kind: 'link', key: 'next' }, { head: UX.colFound, kind: 'num', key: 'machines' }, when] },
  ];
}

function fail(e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  $('#app').style.display = 'block';
  VmfHelp.identity(account);
  chrome();
  $('#panels').innerHTML = `<div class="card"><div class="working"><span class="spin"></span>${esc(UX.working)}</div></div>`;
  // WAIT-1: say what is being read before the walk, not after it.
  render();
  try { await load(); reading = false; render(); }
  // TILE-COUNT-READING-1: a failed read keeps the tiles and the list, which
  // say Not known and that the read failed; the banner gives the reason.
  catch (e) { reading = null; fail(e); render(); }
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

      } catch (e) { fail(e); }
    });
  }
}

const T = (minAgo) => new Date(Date.now() - minAgo * 60000).toISOString();
// PAGE-SCALE-OVERVIEW-1: enough migrations that wait for a person to fill a
// second page of the list, as an estate at volume does - the manual's picture
// is taken from this (tools/manual-shots.js).
const DEMO_STATE = {
  projects: [
    { id: 'contoso-datacentre-exit', name: 'Contoso datacentre exit', created: T(20160), assessments: 2, migrations: 12 },
    { id: 'payments-refresh', name: 'Payments platform refresh', created: T(4320), assessments: 1, migrations: 2 },
    { id: 'web-tier', name: 'Web tier', created: T(8640), assessments: 1, migrations: 1 },
  ],
  loose: ['estate-scan-august'],
  runs: [
    ...Array.from({ length: 12 }, (_, i) => ({
      id: `contoso-datacentre-exit/migration-2026-10-${String(28 - i).padStart(2, '0')}`, kind: 'migration',
      projectId: 'contoso-datacentre-exit', created: T(1440 * (i + 10)), when: T(60 * (i + 1)),
      attention: (i % 3) + 1, running: 0, wave: 'wave-1',
      summary: { machines: 6, waves: [{ wave: i % 2 ? 'wave-2' : 'wave-1', stateCounts: {}, waitsOnPerson: (i % 3) + 1 }] },
    })),
    { id: 'payments-refresh/migration-2026-09-01', kind: 'migration', projectId: 'payments-refresh', created: T(96000),
      attention: 0, running: 3, wave: 'wave-2', when: T(4), summary: { machines: 9, waves: [] } },
    // OVERVIEW-SUMMARY-1: a migration whose next wave waits for approval.
    { id: 'payments-refresh/migration-2026-09-20', kind: 'migration', projectId: 'payments-refresh', created: T(70000),
      attention: 0, running: 0, waits: { wave: 'wave-1', tag: 'approve' }, when: T(180), summary: { machines: 14, waves: [] } },
    { id: 'web-tier/migration-2026-10-02', kind: 'migration', projectId: 'web-tier', created: T(52000),
      attention: 0, running: 0, waits: { wave: 'wave-3', tag: 'accept' }, when: T(300), summary: { machines: 5, waves: [] } },
    { id: 'payments-refresh/assessment-2026-09-01', kind: 'assessment', projectId: 'payments-refresh', created: T(96500),
      approved: false, found: 26, when: T(95) },
    { id: 'estate-scan-august', kind: 'assessment', projectId: null, created: T(120000),
      approved: false, found: 41, when: T(120000) },
  ],
};

// The help button is DRAWN by installNav() in help.js, but its click handler
  // is attached by install(). A page that skips this gets a tab that looks like
  // a control and behaves like a dead link to '#'. It was found on Overview;
  // two older pages had the same gap.
  if (window.VmfHelp) VmfHelp.install({ getMsal: () => msalApp, getRunId: () => null });

boot().catch(e => fail(e));
