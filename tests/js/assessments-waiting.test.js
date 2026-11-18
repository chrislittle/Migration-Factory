/* WAIT-1: the assessments page never states that you have nothing while it is
 * still looking.
 *
 * Found 2026-09-15: assessments loaded slowly, and nothing said to wait as
 * the overview page does. Every page must show its status while it loads.
 *
 * This page is the worst of the set, because it does not merely look empty -
 * it says "Nothing has been assessed yet. Start by scanning..." in a finished
 * sentence, which is indistinguishable from the truth and sends somebody
 * looking for work they already did.
 *
 * PAGE-SCALE-ASSESSMENTS-1: the list is the shared one (VmfHelp.listMount),
 * so the page's renderTable is RUN here, and what the list shows when it has
 * no row is drawn by help.js's own table.
 *
 * LOADING-LINE-1 (2026-11-08: the rebuilt assessments page showed no sign
 * that it was loading): the sentence sat on the All tile only,
 * and the page opens on To review - which said none waited, while it read.
 * The list is now help.js's own listMount, run here, so what is checked is
 * what a person sees on the tile the page opens on.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.LIST_PAGE_SIZE = Number((HELP.match(/const LIST_PAGE_SIZE = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.LIST_TONES = eval((HELP.match(/const LIST_TONES = (\[[^\]]*\]);/) || [])[1]);
const page = liftAll('assessments.html', ['renderTable', 'assessmentTiles', 'assessmentColumns', 'projectChoices', 'openAskedReport']);
const H = liftAll('help.js', ['listMount', 'listTableHtml', 'listCellClass', 'listCell', 'listView', 'listSort', 'listSortValue', 'listMatches',
  'listDefaultTile', 'listTilesHtml', 'listTone', 'listTag', 'listPagerHtml', 'listRangeText', 'listControlsHtml', 'listTabsHtml',
  'listHref', 'listOpenAttrs', 'listAction', 'listNotePart', 'agoText', 'runLink', 'runParse', 'runStorePath']);

function view() {
  const parts = {};
  const host = {
    id: '#assessments-list',
    set innerHTML(v) { this._html = v; for (const k of Object.keys(parts)) delete parts[k]; },
    get innerHTML() { return this._html; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: () => ({ focus() {} }), setAttribute() {}, removeAttribute() {} }); }
      return { focus() {} };
    },
    addEventListener() {}, contains: () => false,
  };
  global.$ = (sel) => (sel === '#assessments-list' ? host : { id: sel, addEventListener() {} });
  global.esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  global.UX = liftConst('assessments.html', 'UX');
  global.location = { search: '' };
  Object.assign(global, page, H);
  global.VmfHelp = { LIST_LOOSE: '(outside)', listMount: H.listMount };
  global.assessList = null;
  global.onListClick = () => {};
  global.reportAsked = true;
  global.projects = [];
  global.rows = [];
  global.reading = true;
  return { table: () => (parts.table || {}).innerHTML || '' };
}

test('while it is reading it says so on the tile it opens on, and claims nothing about what you have', () => {
  const v = view();
  page.renderTable();
  ok(v.table().includes('Reading your assessments.'), 'the waiting sentence: ' + v.table());
  ok(!v.table().includes('Nothing has been assessed'), 'said you had none before looking');
  ok(!v.table().includes(UX.tileReviewNone), 'said none waits for review before looking: ' + v.table());
});

test('THE DEFECT: the sentence appears only once the store has been read', () => {
  const v = view();
  global.reading = false;
  page.renderTable();
  ok(!v.table().includes('Reading your assessments.'), 'still said it was reading');
  ok(v.table().includes(UX.tileReviewNone), 'the To review tile\'s own sentence, after looking: ' + v.table());
});

test('and it does not offer a scan in the list before it has looked', () => {
  // Offering a scan to somebody who already has twelve assessments is the
  // same mistake in a button. Assess an estate is at the top of the page,
  // always; the list adds nothing while it reads.
  const v = view();
  page.renderTable();
  ok(!/<a\b|<button\b/.test(v.table()), 'offered a control before looking: ' + v.table());
});

run('assessments-waiting');
