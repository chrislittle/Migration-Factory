/* WAIT-1: the projects page never reads dead.
 *
 * The owner opened this page on a fresh install and got an empty grey card for
 * several seconds, with nothing saying it was working: "projects (unlike
 * overview) don't show an indicator to wait. this should be everywhere in the
 * app nothing should read dead. it loads eventually."
 *
 * Three rules, from one flag:
 *   1. before the read, the table says what it is reading
 *   2. "No projects yet" appears only after the store has been looked at
 *   3. each project is painted as it lands, not all of them at the end
 *
 * These drive the page's own render() and load() against a store that answers
 * slowly, which is the only way rule 3 can be observed at all.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// PERF-PROBES-1: load asks VmfHelp.storeHolds whether a listing names the project document.
// CLICKS-LOST-1: each project is drawn through drawListWhenFree, which waits
// only while a person holds a control in the list or the form.
// PAGE-SCALE-PROJECTS-1: the page draws through the shared list
// (VmfHelp.listMount), run here as help.js has it; load reads each
// migration's status (migrationWaiting) and the last change (latestTime).
const { pageSource } = require('./_page-source');
const HELP = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
// eslint-disable-next-line no-eval
global.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
global.LIST_PAGE_SIZE = Number((HELP.match(/const LIST_PAGE_SIZE = (\d+);/) || [])[1]);
global.LIST_TONES = eval((HELP.match(/const LIST_TONES = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
const PAGE_FNS = ['render', 'load', 'withMade', 'drawListWhenFree', 'listRegions', 'latestTime', 'migrationWaiting',
  'projectTiles', 'projectRow', 'projectColumns', 'projectSorts', 'waitingTag', 'deleteAction', 'holdsParts', 'holdsNote'];
const pageFns = liftAll('projects.html', PAGE_FNS);
const { render, load } = pageFns;
const shared = liftAll('help.js', ['waitingRow', 'mapLimited', 'runFolderIsRun', 'runKind', 'drawWhenFree', 'controlHeld', 'isTypingControl', 'isPointerControl',
  'runSummaryOf', 'runWaitingCount', 'runParse', 'runStorePath', 'runLink', 'listHref', 'listMatches', 'listView', 'listSort',
  'listSortValue', 'listDefaultTile', 'listRangeText', 'listTone', 'listTag', 'listCell', 'listOpenAttrs', 'listCellClass', 'listAction', 'listNotePart',
  'listTilesHtml', 'listTableHtml', 'listPagerHtml', 'listControlsHtml', 'listMount', 'agoText', 'storeHolds']);
global.heldDraws = new WeakMap();
global.QUIET_DAYS = 30;

/** Only the parts of the page these functions touch; the list host keeps
 *  what the shared list writes into each of its parts. */
function page() {
  const nodes = {};
  const parts = {};
  const listHost = {
    set innerHTML(v) { this._html = v; for (const k of Object.keys(parts)) delete parts[k]; },
    get innerHTML() { return this._html; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: () => ({ focus() {} }) }); }
      return { focus() {} };
    },
    addEventListener() {}, contains: () => false,
  };
  const node = (id) => (id === '#projects-list' ? listHost : (nodes[id] = nodes[id] || {
    textContent: '', innerHTML: '', style: {}, addEventListener() {}, querySelectorAll: () => [],
  }));
  global.$ = (sel) => node(sel);
  global.esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  global.byName = (a, b) => String(a.name).localeCompare(String(b.name));
  global.DEMO_MODE = false;
  global.STORE_READ_LIMIT = 8;
  global.UX = liftConst('projects.html', 'UX');
  global.VmfHelp = Object.assign({}, shared, {
    // PAGE-LOAD-1: the one call fails, so the page reads through the blobList and blobJson this test gives it.
    storeDocs: async () => { throw new Error('per-file reads measured here'); } });
  Object.assign(global, { held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token' });
  Object.assign(global, pageFns, { madeHere: new Map(), loadTurn: 0, projectsList: null, onListClick: () => {} });
  global.projects = [];
  global.loose = [];
  global.reading = true;
  return { table: () => ['tiles', 'title', 'table', 'pager'].map(k => (parts[k] || {}).innerHTML || '').join('') + node('#loose').innerHTML };
}
/** A store that hands over one project at a time, on demand. */
function slowStore(names) {
  const gates = names.map(() => {
    let release;
    const until = new Promise((res) => { release = res; });
    return { until, release };
  });
  global.blobList = async (prefix) => {
    if (prefix === '') { return { prefixes: names.slice(), names: [] }; }
    // PERF-PROBES-1: a project folder's listing names its document, as the
    // service's does; the page reads only what a listing names.
    const folder = String(prefix).replace(/\/$/, '');
    return { prefixes: [], names: names.includes(folder) ? [`${folder}/project.json`] : [] };
  };
  global.blobJson = async (path) => {
    const which = names.findIndex(n => path === `${n}/project.json`);
    if (which < 0) { return null; }
    await gates[which].until;
    return { projectId: names[which], name: names[which], createdUtc: null };
  };
  return gates;
}

test('rule 1: before the read, it says what it is reading', () => {
  const view = page();
  render();
  ok(view.table().includes('Reading your projects.'), 'the waiting sentence');
  ok(!view.table().includes('No projects yet'), 'said there were none before looking');
});

test('rule 2: "no projects yet" waits until the store has been looked at', () => {
  const view = page();
  global.reading = false;                 // the read finished and found nothing
  render();
  ok(view.table().includes('No projects yet'), 'the empty sentence');
  ok(!view.table().includes('Reading your projects.'), 'still claimed to be reading');
});

test('THE DEFECT: an empty table never means both things at once', () => {
  const view = page();
  render();
  const whileReading = view.table();
  global.reading = false;
  render();
  ok(whileReading !== view.table(), 'a person cannot tell the two apart');
});

test('rule 3: each project appears as it lands, not all at the end', async () => {
  const view = page();
  const gates = slowStore(['alpha', 'beta']);
  render();
  const reading = load();

  gates[0].release();
  await new Promise(r => setTimeout(r, 0));
  ok(view.table().includes('alpha'), 'the first project, once it landed');
  ok(!view.table().includes('beta'), 'the second, which has not landed');

  gates[1].release();
  await reading;
  global.reading = false;
  render();
  ok(view.table().includes('alpha') && view.table().includes('beta'), 'both projects');
  ok(!view.table().includes('Reading your projects.'), 'still waiting after the read');
});

test('a folder beside the projects is not listed as a run from before them', async () => {
  const view = page();
  const gates = slowStore(['alpha', 'logs']);
  render();
  const reading = load();
  gates.forEach(g => g.release());
  await reading;
  global.reading = false;
  render();
  ok(!view.table().includes('logs'), 'PROJECT-3b: the event log listed on this page');
});

run('projects-waiting');
