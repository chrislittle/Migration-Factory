'use strict';
const DEMO_MODE = new URLSearchParams(location.search).has('demo');
const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

/* ============================ UX-STRINGS-BEGIN ============================
   Plain words, no ENGINE vocabulary - which is what that rule was ever about.
   It is not a licence to invent euphemisms for ordinary ones. This page first
   called a project a "piece of work", assessments "times looked at" and
   Continue "carry on". That contradicted the app's own navigation and read as
   baby talk. Project, assessment and migration ARE the words:
   they are what Azure Migrate uses and what an operator already knows. */
const UX = {
  listTitle:  'Projects',
  // PAGE-SCALE-PROJECTS-1: the words of the approved design.
  lede:       'A project holds the assessments and migrations of one estate.',
  newBtn:     'New project',
  newHelp:    'A project holds one estate - its assessments, and the migrations planned from them.',
  lName:      'Project name',
  lNote:      'Description (optional)',
  idHint:     'Address:',
  createBtn:  'Create project',
  cancelBtn:  'Cancel',
  colName:    'Project',
  colAssess:  'Assessments',
  colMigr:    'Migrations',
  colWaiting: 'Waiting for a person',
  colChanged: 'Last change',
  colAction:  'Action',
  lookBtn:    'New assessment',
  tileAll:        'All projects',
  tileWaiting:    'With a machine waiting for a person',
  tileWaitingTitle: 'Projects with a machine waiting for a person',
  tileWaitingNone:  'No project has a machine that waits for a person.',
  tileQuiet:      'No change in 30 days',
  tileQuietTitle: 'Projects with no change in 30 days',
  tileQuietNone:  'Each project changed in the last 30 days.',
  sortChanged: 'Last change',
  sortName:    'Name',
  sortWaiting: 'Waiting for a person',
  searchHint:  'Project name',
  waitOne:     '{n} machine',
  waitMany:    '{n} machines',
  waitNone:    'None',
  waitUnknown: 'Not known',
  del:        'Delete',
  delConfirm: 'Delete this project?',
  delDesc:    'This deletes the project and its name. Your machines are not touched.',
  delBusy:    'Deleting...',
  // PROJ-EMPTY-1: it used to say "assessments or migrations", which is both of
  // them and neither, and then "Delete those first" with no way to them. The
  // page holds the two counts, so it can say which and take you there.
  // PAGE-SCALE-PROJECTS-1: short, so the reason under a disabled Delete is one
  // line and a page of 10 rows stays a page. It names what is inside and the
  // counts are links to it.
  delHolds:   'Delete {n} first.',
  delHoldsAssess: '{n} assessment',
  delHoldsAssessMany: '{n} assessments',
  delHoldsMigr:   '{n} migration',
  delHoldsMigrMany: '{n} migrations',
  delHoldsAnd: ' and ',
  delYes:     'Yes, delete',
  cancel:     'Cancel',
  empty:      'No projects yet. Create one to get started.',
  waiting:    'Reading your projects.',
  created:    'Project created. Start an assessment in it.',
  // CLICKS-LOST-1: the button says it works at once.
  creating:   'Creating the project...',
  needName:   'Enter a project name.',
  loose:      'Not in a project',
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
 * the store listed, and each project.json and run.json. The readers below
 * answer from it first and ask the service only what it cannot answer
 * (unknown means ask). null when the call failed - then every read goes to
 * the service, as before. */
let held = null;
/* PAGE-SCALE-PROJECTS-1: run-status.json too, for the machines that wait for
 * a person and the last change. It comes in the SAME one call - no read for
 * each row (PERF-PROJECTS-LIST-1 is the service's list, and this adds nothing
 * to it). A migration at setup has none, and the listing says so. */
const LIST_READS = ['project.json', 'run.json', 'run-status.json'];
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
// Creating a project WRITES, so it goes through the facade. The browser's own
// token cannot write to the store, and should not be able to.
async function api(method, path, body) {
  if (DEMO_MODE) { await new Promise(r => setTimeout(r, 250)); return {}; }
  const token = (await msalApp.acquireTokenSilent({ scopes: [`api://${cfg.apiAppId}/access_as_user`], account })).accessToken;
  const r = await fetch(`${cfg.apiUrl}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
  return data;
}

let projects = [], loose = [];
// WAIT-1: true until the store has been read. It decides one thing - whether
// an empty table means 'there is nothing' or 'I have not looked yet'.
// LOADING-LINE-1: null once the read FAILED - not reading, and nothing read,
// so the list says the read failed rather than "none".
let reading = true;
const byName = (a, b) => String(a.name).localeCompare(String(b.name));
/* CLICKS-LOST-1: the projects made on this page since it opened, by id. On
 * the lab install the page said "Project created" and the project was not in
 * the list until a reload: the walk of the store that had started before the
 * create finished after it, and put back the list it had read. A project made
 * here stays in the list until a walk of the store names it. */
let madeHere = new Map();
// And only the latest walk sets the list: an older one that ends later would
// put back a project deleted since, or leave out one made since.
let loadTurn = 0;
function withMade(list) {
  const out = list.slice();
  for (const [id, p] of madeHere) {
    if (out.some(x => x.id === id)) { madeHere.delete(id); } else { out.push(p); }
  }
  return out.sort(byName);
}
async function load() {
  if (DEMO_MODE) { projects = withMade(DEMO_PROJECTS); loose = ['estate-scan-august']; return; }
  const turn = ++loadTurn;
  // PAGE-LOAD-1: ONE call for the listing and every document the list draws,
  // read again on every load so a project made a moment ago is seen.
  held = await storeRead(() => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { depth: 3, read: LIST_READS })).catch(() => null);
  // PROJECT-3: the claim registry and an event log are not runs and not
  // projects. Without this a folder beside them is listed as a run made before
  // projects existed - which is the one thing this page says to reassure
  // somebody that their migration has not vanished.
  const top = (await blobList('', '/')).prefixes.filter(VmfHelp.runFolderIsRun);
  const nextProjects = [], nextLoose = [];
  // STORE-READ-2: projects x runs, paced rather than all in flight at once.
  await VmfHelp.mapLimited(top, async (p) => {
    /* PERF-PROBES-1: the folder listing FIRST, and the project document only
     * when the listing names it. PAGE-WAIT-1 asked for both together, so every
     * run outside a project was asked for a project document its own listing
     * showed was not there. A project's runs are named by the same listing,
     * so they are read BESIDE its document: still two round trips. */
    // PROJECT-3: the folders beside the runs are not runs, so they are left out
    // of the listing at once.
    const listFolder = () => blobList(`${p}/`, '/').then(l => ({ ...l, prefixes: l.prefixes.filter(VmfHelp.runFolderIsRun) }));
    const listing = await listFolder().catch(() => null);
    const listed = VmfHelp.storeHolds(listing, `${p}/project.json`);
    const docRead = listed ? blobJson(`${p}/project.json`).catch(() => null) : Promise.resolve(null);
    // COUNTED from what is actually in the store, never from a tally kept on
    // the project document - a count maintained beside the things it counts is
    // a count that drifts from them.
    // PAGE-SCALE-PROJECTS-1: and, for each migration, the machines that wait
    // for a person (its summary, by the Overview's rule) and the last change.
    const count = async (inside) => {
      const kids = inside.prefixes.filter(VmfHelp.runFolderIsRun);
      const c = { assessments: 0, migrations: 0, waiting: 0, waitingUnknown: false, changed: null };
      await VmfHelp.mapLimited(kids, async (k) => {
        const m = await blobJson(`${k}/run.json`).catch(() => null);
        if (!m) return;
        c.changed = latestTime(c.changed, m.createdUtc);
        if (VmfHelp.runKind(m) === 'assessment') { c.assessments++; return; }
        c.migrations++;
        const status = await blobJson(`${k}/run-status.json`).catch(() => null);
        const n = migrationWaiting(status);
        if (n === null) { c.waitingUnknown = true; } else { c.waiting += n; }
        c.changed = latestTime(c.changed, status && status.updatedUtc);
      });
      return c;
    };
    const counting = listing && listed ? count(listing) : null;
    const doc = await docRead;
    if (!doc) { if (counting) { await counting; } nextLoose.push(p); return; }
    const c = await (counting || count(listing ?? await listFolder()));
    nextProjects.push({ id: doc.projectId, name: doc.name, created: doc.createdUtc,
                        by: doc.createdBy, note: doc.note, assessments: c.assessments, migrations: c.migrations,
                        waiting: c.waiting, waitingUnknown: c.waitingUnknown,
                        changed: latestTime(doc.createdUtc, c.changed) });
  }, undefined, () => {
    // WAIT-1: draw each project as it lands rather than holding them all back
    // for the slowest. This is what the overview already does, and it is why
    // the overview is the one page that reads as working.
    if (turn !== loadTurn) { return; }
    projects = withMade(nextProjects);
    // CLICKS-LOST-1: not while the person types a new project, or under the pointer.
    drawListWhenFree();
  });
  if (turn !== loadTurn) { return; }
  projects = withMade(nextProjects);
  loose = nextLoose.sort();
}
/* CLICKS-LOST-1: the list draws in pieces as the walk reads the store, each
 * project in its place by name - so a row moved under the pointer, and the
 * list moved while a person typed a new project. A draw the walk asks for
 * waits while the person holds a control in the form or the list. */
function listRegions() {
  return ['#new-form', '#projects-list'].map(s => $(s)).filter(Boolean);
}
function drawListWhenFree() {
  VmfHelp.drawWhenFree(listRegions(), render);
}

/* PAGE-SCALE-PROJECTS-1: the machines of one migration that wait for a
 * person, from its run-status.json - or null, NOT KNOWN.
 *
 * The Overview's rule (index.js, migrationFacts), on the same shared pieces:
 * the summary's count (summary.waitsOnPerson, VmfHelp.runWaitingCount). A
 * status whose summary cannot be read is not known: its live counts are one
 * wave's, so they are never read for the migration. A migration at setup has
 * no status, and no machine has started. */
function migrationWaiting(status) {
  if (!status) { return 0; }
  const summary = VmfHelp.runSummaryOf(status);
  return summary ? VmfHelp.runWaitingCount(summary) : null;
}

/* The later of two ISO times, as written; a value that is not a time does
 * not count. null when neither is one. */
function latestTime(a, b) {
  const at = (v) => (v ? Date.parse(v) : NaN);
  const x = at(a), y = at(b);
  if (!isFinite(x)) { return isFinite(y) ? b : null; }
  if (!isFinite(y)) { return a; }
  return y > x ? b : a;
}

const QUIET_DAYS = 30;

/* PAGE-SCALE-PROJECTS-1: three count tiles and ONE list, in place of one
 * table with a row for every project.
 *
 * With many projects the page was one long scroll with no search and no
 * page. The tiles, the list, its sort, its search and its pages are the shared
 * piece in help.js (VmfHelp.listMount); this page gives it the rows. Nothing
 * is hidden until a person selects: the list opens on All projects. */
function projectTiles(list, nowMs) {
  const rows = list.map(projectRow);
  const quietBefore = nowMs - QUIET_DAYS * 86400000;
  const quiet = (r) => { const at = r.changed ? Date.parse(r.changed) : NaN; return isFinite(at) && at < quietBefore; };
  return [
    // WAIT-1, LOADING-LINE-1: while the page reads, the shared list says
    // UX.waiting in place of every tile's empty sentence.
    { key: 'all', label: UX.tileAll, title: UX.tileAll, empty: UX.empty, rows },
    // A count that is NOT KNOWN is listed, never dropped as if it were zero.
    { key: 'waiting', label: UX.tileWaiting, title: UX.tileWaitingTitle, empty: UX.tileWaitingNone,
      rows: rows.filter(r => r.waitingRank > 0) },
    { key: 'quiet', label: UX.tileQuiet, title: UX.tileQuietTitle, empty: UX.tileQuietNone, rows: rows.filter(quiet) },
  ];
}

function projectColumns() {
  return [
    { head: UX.colName, kind: 'name' },
    { head: UX.colAssess, kind: 'count', key: 'assessments' },
    { head: UX.colMigr, kind: 'count', key: 'migrations' },
    { head: UX.colWaiting, kind: 'tag', key: 'waiting' },
    { head: UX.colChanged, kind: 'ago', key: 'changed' },
    { head: UX.colAction, kind: 'actions', key: 'actions' },
  ];
}

function projectSorts() {
  return [
    { key: 'changed', label: UX.sortChanged, field: 'changed', type: 'time', order: 'desc' },
    { key: 'name', label: UX.sortName, field: 'name', type: 'text', order: 'asc' },
    { key: 'waiting', label: UX.sortWaiting, field: 'waitingRank', type: 'number', order: 'desc' },
  ];
}

/* What the Waiting for a person column says: a red count of machines, None,
 * or Not known. */
function waitingTag(p) {
  if (p.waitingUnknown) { return { text: UX.waitUnknown, tone: 'muted' }; }
  if (p.waiting > 0) { return { text: (p.waiting === 1 ? UX.waitOne : UX.waitMany).replace('{n}', String(p.waiting)), tone: 'bad' }; }
  return { text: UX.waitNone, tone: 'muted' };
}

/* One project as a row of the list.
 *
 * PROJ-LINK-1: a count you cannot open is not information, so each count
 * links to the page that lists the thing counted, filtered to this project
 * (a count of 0 is not a link). The name opens the project's assessments -
 * the work of an estate starts there, and each assessment shows the
 * migrations planned from it. */
function projectRow(p) {
  const id = p.id;
  return {
    id, name: p.name, note: p.note || '', projectId: id, project: '',
    dest: { page: 'assessments', project: id },
    assessments: { n: p.assessments, dest: { page: 'assessments', project: id } },
    migrations: { n: p.migrations, dest: { page: 'migrations', project: id } },
    waiting: waitingTag(p),
    // The waiting sort: the most first, and a count NOT KNOWN above none.
    waitingRank: (Number(p.waiting) || 0) + (p.waitingUnknown ? 0.5 : 0),
    changed: p.changed || p.created || null,
    actions: [{ text: UX.lookBtn, dest: { page: 'wizard', project: id } }, deleteAction(p)],
  };
}

/* The delete control is ALWAYS drawn. A control that appears only in the
 * case nobody is in is a feature nobody knows exists. The engine refuses a
 * project that holds work - deleting a project is deleting a NAME, and
 * deleting the work inside it is a series of separate decisions - so the
 * button is disabled and says why.
 *
 * PROJ-EMPTY-1: THE REASON IS ON THE ROW, not in a tooltip. A hover has no
 * keyboard, no touch and no screen reader path, so to a user a disabled
 * button with the reason in `title` was a grey button that did nothing and
 * said nothing. The sentence under it names what is inside, and each part is a
 * link to it. */
function deleteAction(p) {
  const action = { text: UX.del, action: 'delete', value: p.id };
  if ((p.assessments + p.migrations) === 0) { return action; }
  return Object.assign(action, { disabled: true, note: holdsNote(p) });
}

// What is inside, in words: "1 migration", "2 assessments and 1 migration".
// One function, so the row and the refusal cannot disagree.
function holdsParts(p) {
  const parts = [];
  if (p.assessments) {
    parts.push({ text: (p.assessments === 1 ? UX.delHoldsAssess : UX.delHoldsAssessMany).replace('{n}', String(p.assessments)),
                 page: 'assessments' });
  }
  if (p.migrations) {
    parts.push({ text: (p.migrations === 1 ? UX.delHoldsMigr : UX.delHoldsMigrMany).replace('{n}', String(p.migrations)),
                 page: 'migrations' });
  }
  return parts;
}


/* The sentence as parts for the shared list (VmfHelp.listMount escapes them):
 * each thing inside links to the same filtered list its count links to, so
 * the route out is the one already on the row. Empty when the page counts
 * nothing inside. */
function holdsNote(p) {
  const parts = holdsParts(p);
  if (!parts.length) { return []; }
  const sentence = UX.delHolds;
  const at = sentence.indexOf('{n}');
  const out = [{ text: sentence.slice(0, at) }];
  parts.forEach((part, i) => {
    if (i) { out.push({ text: UX.delHoldsAnd }); }
    out.push({ text: part.text, dest: { page: part.page, project: p.id } });
  });
  out.push({ text: sentence.slice(at + 3) });
  return out;
}

/* The same sentence as markup for the refusal of the service - or NULL when
 * this page's counts say the project is empty and the service says it is not.
 *
 * That disagreement is possible: somebody else added an assessment since this
 * page last read. Writing "still holds 0" would be the page reporting a thing
 * it did not measure, so it hands back nothing and the caller shows what the
 * service actually said. */
function holdsHtml(id) {
  const p = projects.find(x => x.id === id) ?? {};
  const note = holdsNote(p);
  if (!note.length) { return null; }
  return note.map(part => (part.dest ? `<a href="${esc(VmfHelp.listHref(part.dest))}">${esc(part.text)}</a>` : esc(part.text))).join('');
}

// Deleting is the one thing this page changes. The engine refuses a project
// that still holds work and says what it holds, so this reports that answer
// rather than pre-judging it.
function deleteProject(id, btn) {
  // POPUP-1: asked in the row, not in a browser box.
  VmfHelp.confirmInPlace(btn, { ask: UX.delConfirm, desc: UX.delDesc, yes: UX.delYes, cancel: UX.cancel, under: 'tr' },
    () => deleteProjectNow(id, btn));
}

async function deleteProjectNow(id, btn) {
  btn.disabled = true;
  btn.textContent = UX.delBusy;
  try {
    await api('POST', `projects/${encodeURIComponent(id)}/delete`,
      { note: 'deleted from the projects page' });
    madeHere.delete(id);   // CLICKS-LOST-1: a deleted project is not kept in the list
    // load() READS; render() DRAWS. Calling only the first left the row on
    // screen with its button stuck on "Deleting..." while the project was
    // already gone from the store.
    await load();
    render();
  } catch (e) {
    const msg = $('#err');
    /* PROJ-EMPTY-1: the refusal LEADS SOMEWHERE. The engine is right to
     * refuse - deleting a migration is its own decision about the safety
     * copies that can put a machine back. Nothing is parsed out of the
     * message: the counts are already on the row. Reading the sentence the
     * service wrote would tie this page to that wording. */
    const holds = /still holds/i.test(e.message) ? holdsHtml(id) : null;
    if (holds) { msg.innerHTML = holds; } else { msg.textContent = e.message; }
    msg.style.display = 'block';
    btn.disabled = false;
    btn.textContent = UX.del;
  }
}

// A row's buttons are the shared list's; the page listens for their click.
function onListClick(e) {
  const btn = e.target.closest('button[data-action="delete"]');
  if (btn && !btn.disabled) { deleteProject(btn.dataset.value, btn); }
}

// The list is mounted ONCE. The page draws again as each project lands
// (WAIT-1), and a list drawn again from nothing would throw away the sort, the
// search and the page a person chose.
let projectsList = null;

function render() {
  $('#list-title').textContent = UX.listTitle;
  $('#lede').textContent = UX.lede;
  $('#new-btn').textContent = UX.newBtn;
  if (!projectsList) {
    projectsList = VmfHelp.listMount($('#projects-list'), { id: 'pj', preferred: 'all', searchHint: UX.searchHint,
      projectFilter: false, sorts: projectSorts(), columns: projectColumns(), waiting: UX.waiting });
    $('#projects-list').addEventListener('click', onListClick);
  }
  projectsList.update({ tiles: projectTiles(projects, Date.now()), projects: [], reading: reading === true, failed: reading === null });
  // Runs outside any project (the command line can make one). Shown rather
  // than hidden: they still work, and pretending they are not there is how
  // somebody concludes their migration has vanished.
  const out = $('#loose');
  if (loose.length) {
    out.innerHTML = `<b>${esc(UX.loose)}</b><br>${loose.map(l => `<span class="mono">${esc(l)}</span>`).join(', ')}`;
    out.style.display = 'block';
  } else {
    out.innerHTML = '';
    out.style.display = 'none';
  }
}
// The short name is DERIVED from what they typed, so nobody has to think about
// path rules - but it stays editable, because they may want a different one.
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64);

function wireForm() {
  $('#new-help').textContent = UX.newHelp;
  $('#l-name').textContent = UX.lName;
  $('#l-note').textContent = UX.lNote;
  $('#create-btn').textContent = UX.createBtn;
  $('#cancel-btn').textContent = UX.cancelBtn;

  $('#new-btn').addEventListener('click', () => {
    const f = $('#new-form');
    f.style.display = f.style.display === 'none' ? 'block' : 'none';
    if (f.style.display === 'block') $('#f-name').focus();
  });
  $('#cancel-btn').addEventListener('click', () => { $('#new-form').style.display = 'none'; });
  // Rule 11: Escape does what Cancel does, and the focus goes back to the
  // button that opened the form.
  $('#new-form').addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') { return; }
    $('#new-form').style.display = 'none';
    $('#new-btn').focus();
  });
  $('#f-name').addEventListener('input', () => {
    const id = slug($('#f-name').value);
    $('#idhint').textContent = id ? `${UX.idHint} ${id}` : '';
  });

  $('#create-btn').addEventListener('click', createProject);
}

async function createProject() {
  const name = $('#f-name').value.trim();
  const id = slug(name);
  const note = $('#f-note').value.trim();
  if (!name) return fail(new Error(UX.needName));
  if (!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(id)) return fail(new Error(UX.needName));
  // CLICKS-LOST-1: a sign at once, before the service is asked.
  const undoBusy = VmfHelp.markBusy($('#create-btn'), UX.creating);
  try {
    await api('POST', 'projects', { projectId: id, name, note });
    // CLICKS-LOST-1: in the list at once, from what the service accepted -
    // the walk of the store that follows takes a minute on a large store.
    const now = new Date().toISOString();
    madeHere.set(id, { id, name, created: now, note: note || null, assessments: 0, migrations: 0,
                       waiting: 0, waitingUnknown: false, changed: now });
    projects = withMade(projects);
    $('#ok').textContent = UX.created; $('#ok').style.display = 'block';
    $('#new-form').style.display = 'none';
    $('#f-name').value = ''; $('#f-note').value = ''; $('#idhint').textContent = '';
    render();
    load().then(drawListWhenFree, () => { /* the list stays as drawn; a reload reads it again */ });
  } catch (e) { failAction(e); }
  finally { undoBusy(); }
}

function fail(e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }
// Something the PERSON did. Never blames Azure RBAC - the facade refuses
// an action on APP ROLE, and its storage permission is not involved.
function failAction(e) { $('#err').textContent = VmfHelp.explainAction(e); $('#err').style.display = 'block'; }

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  $('#app').style.display = 'block';
  VmfHelp.identity(account);
  wireForm();
  // WAIT-1: paint before reading, so the page says what it is doing rather
  // than showing an empty table for the seconds the walk takes.
  render();
  try { await load(); }
  // LOADING-LINE-1: a failed read ends the read too - the list is drawn
  // again, so its Reading line gives way to the failure beside the error.
  catch (e) { reading = null; fail(e); render(); return; }
  reading = false;
  drawListWhenFree();
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
/* PAGE-SCALE-PROJECTS-1: enough sample projects to fill more than one page of
 * the list, with some that wait for a person and some with no change in 30
 * days. */
const DEMO_PROJECTS = [
  { id: 'contoso-datacentre-exit', name: 'Contoso datacentre exit', created: T(20160), by: 'sam@contoso.com',
    note: 'Everything leaving Slough before the lease ends in March.', assessments: 2, migrations: 1, waiting: 2, changed: T(35) },
  { id: 'payments-refresh', name: 'Payments platform refresh', created: T(4320), by: 'sam@contoso.com',
    note: null, assessments: 1, migrations: 0, changed: T(4320) },
].concat([
  ['web-tier', 'Web tier', 3, 2, 0, 180], ['data-platform', 'Data platform', 2, 1, 1, 600],
  ['branch-offices', 'Branch offices', 1, 0, 0, 2880], ['hr-systems', 'HR systems', 2, 2, 0, 50400],
  ['retail-stores', 'Retail stores', 4, 3, 3, 90], ['build-servers', 'Build servers', 1, 1, 0, 11520],
  ['shared-services', 'Shared services', 2, 1, 0, 64800], ['partner-portal', 'Partner portal', 1, 0, 0, 1440],
  ['analytics', 'Analytics', 3, 2, 0, 7200], ['identity', 'Identity', 1, 1, 0, 46080],
  ['monitoring', 'Monitoring', 2, 0, 0, 20160],
].map(([id, name, assessments, migrations, waiting, ago]) =>
  ({ id, name, created: T(ago + 1440), note: null, assessments, migrations, waiting, changed: T(ago) })));

// The help button is DRAWN by installNav() in help.js, but its click handler
  // is attached by install(). A page that skips this gets a tab that looks like
  // a control and behaves like a dead link to '#'. Found on Overview;
  // two older pages had the same gap.
  if (window.VmfHelp) VmfHelp.install({ getMsal: () => msalApp, getRunId: () => null });

boot().catch(e => fail(e));
