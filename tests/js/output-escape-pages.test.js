/* OUTPUT-ESCAPE-1, the other pages: text from a customer machine or from
 * Azure is drawn as text.
 *
 * RUN, not read: each page's own render function, with the page's own encoder
 * and words, fed hostile values:
 *   - the wizard's machine list: machine names, resource groups and TAGS, in
 *     the rows and in the filter lists;
 *   - the assessment report: machine names, and the workload evidence - the
 *     EXTENSION names and image PUBLISHER read from Azure - and a link from the
 *     reasons file that is not https;
 *   - the Reports page: the run rows (a run name comes from the store), and
 *     the sign-off cell with the approver's NOTE and account.
 * output-escape-migrations.test.js does the Migrations page.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { liftAll, liftConst, test, ok, eq, run } = require('./_harness');
const H = require('./_hostile');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');

// ---------- the wizard: machine names and tags ----------

test('the wizard machine list draws names, resource groups and tags as text, in the rows and the filters', () => {
  const esc = H.pageEsc('wizard.html');
  globalThis.esc = esc;
  globalThis.UX = liftConst('wizard.html', 'UX');
  globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
  globalThis.M_PAGE = 50;
  const w = liftAll('wizard.html', ['tagPairs', 'chooseMatches', 'chooseOptions', 'chooseFiltersHtml', 'chooseListHtml']);
  globalThis.tagPairs = w.tagPairs;
  globalThis.chooseMatches = w.chooseMatches;
  globalThis.chooseOptions = w.chooseOptions;
  const rows = [
    { vmId: `/s/rg/vm/a${H.TAG}`, name: `web${H.ALL}`, sub: `sub${H.QUOTE}`, rg: `rg${H.ALL}`,
      tags: { [`app${H.ALL}`]: `billing${H.ALL}`, owner: H.QUOTE }, group: 'can', tickable: true },
    { vmId: `/s/rg/vm/b${H.QUOTE}`, name: `db${H.TAG}`, sub: `sub${H.QUOTE}`, rg: 'rg2', tags: {}, group: 'cannot', tickable: false },
  ];
  const f = { sub: '', rg: '', tag: '', name: '' };
  const subName = (s) => `Subscription ${s}`;
  const list = w.chooseListHtml(rows, new Set([rows[0].vmId]), f, 50, subName);
  H.inert(list, 'the machine list');
  H.shownAsText(list, `web${H.ALL}`, esc, 'the machine name');
  H.shownAsText(list, `app${H.ALL}=billing${H.ALL}`, esc, 'the tag');
  const filters = w.chooseFiltersHtml(rows, { ...f, name: H.ALL }, subName);
  H.inert(filters, 'the filters');
  ok(filters.includes(esc(`app${H.ALL}=billing${H.ALL}`)), 'the tag is offered as a filter, as text');
});

// ---------- the assessment report: extension names and publishers ----------

function loadReport() {
  const ctx = { window: {}, document: { getElementById: () => null, querySelectorAll: () => [], addEventListener() { }, createElement: () => ({ style: {}, setAttribute() { } }), head: { appendChild() { } }, body: { appendChild() { } } }, console };
  vm.createContext(ctx);
  vm.runInContext(pageSource(path.join(DASH, 'assessment-report.js')), ctx);
  return ctx.window.VmfReport;
}

test('the assessment report draws workload evidence - extension names, image publishers - as text', () => {
  const R = loadReport();
  const esc = H.pageEsc('assessment-report.js');
  const vms = [{ vmId: `/s/rg/vm/sql${H.TAG}`, name: `sql${H.ALL}`, resourceGroup: `rg${H.ALL}`, classification: 'ReadyNow',
    workload: { type: 'sql', evidence: [
      { field: `extensions.name${H.QUOTE}`, value: `SqlIaasExtension${H.ALL}` },
      { field: 'imageReference.publisher', value: `microsoftsqlserver${H.ALL}` },
      { field: 'imageReference.offer', value: null }] } }];
  const html = R.workloadTableHtml(vms);
  H.inert(html, 'the workload table');
  H.shownAsText(html, `SqlIaasExtension${H.ALL}`, esc, 'the extension name');
  H.shownAsText(html, `microsoftsqlserver${H.ALL}`, esc, 'the image publisher');
});

test('the assessment report draws machine names in a finding as text, and a link from the reasons file only as https', () => {
  const R = loadReport();
  R.REASONS.blockers.weird = { title: `T${H.ALL}`, meaning: H.ALL, whatToDo: H.ALL, docs: { url: H.JSURL, label: H.ALL } };
  const card = R.reasonCard('weird', [`web${H.TAG}`, `db${H.QUOTE}`], 'bad');
  H.inert(card, 'a finding card');
  const hrefs = H.tags(card).flatMap(t => t.attrs).filter(a => a.name === 'href').map(a => a.value);
  eq(hrefs.length, 1, 'one link');
  ok(hrefs[0].startsWith('https://'), `the link opens an https page, not ${hrefs[0]}`);
});

// ---------- the Reports page: run rows, notes ----------

/* PAGE-SCALE-REPORTS-1: the rows are the shared list's now (VmfHelp.listMount
 * draws them with help.js's own encoder), so the page gives values and never
 * builds a row's markup. The run name, the project, the counts and a kept
 * record's reason are each drawn as text. */
test('the Reports page draws a run row and a record row - names and counts from the store - as text', () => {
  const HELP_ESC = H.pageEsc('help.js');
  globalThis.esc = HELP_ESC;
  // eslint-disable-next-line no-eval
  globalThis.TEXT = eval('(' + pageSource(path.join(DASH, 'help.js')).match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
  globalThis.LIST_TONES = ['bad', 'warn', 'good', 'quiet', 'muted'];
  const shared = liftAll('help.js', ['runParse', 'runStorePath', 'runLink', 'listHref', 'listTone', 'listTag', 'listCell', 'listOpenAttrs',
    'listCellClass', 'listAction', 'listNotePart', 'listTableHtml', 'agoText', 'runTitle']);
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun: { parse: shared.runParse, storePath: shared.runStorePath, link: shared.runLink } });
  globalThis.UX = liftConst('reports.html', 'UX');
  globalThis.projects = [{ id: `p${H.QUOTE}`, name: `Payments${H.ALL}` }];
  globalThis.day = (s) => String(s);
  const r = liftAll('reports.html', ['num', 'outcomeState', 'outcomeTag', 'projectName', 'runRow', 'runColumns', 'recordRow', 'recordColumns']);
  const hostileRun = { r: `p${H.QUOTE}/mig${H.ALL}`, createdUtc: H.ALL, updatedUtc: H.ALL, total: H.TAG, migrated: H.QUOTE, attention: H.TAG,
    waves: H.ALL, putBack: H.TAG, restored: 0, working: 0, notStarted: 0, hasReport: true, setupOnly: false };
  const runs = shared.listTableHtml(r.runColumns(), { rows: [r.runRow(hostileRun), r.runRow({ ...hostileRun, r: `setup${H.ALL}`, setupOnly: true })] }, 'none');
  H.inert(runs, 'the run rows');
  H.shownAsText(runs, `Payments${H.ALL}`, HELP_ESC, 'the project name');
  H.shownAsText(runs, `p${H.QUOTE}/mig${H.ALL}`, HELP_ESC, 'the run id');
  const rec = { Name: `n${H.ALL}`, RunId: `mig${H.ALL}`, Project: `p${H.QUOTE}`, Reason: `why${H.ALL}`, GeneratedUtc: H.ALL, KeepUntilUtc: H.TAG };
  const recs = shared.listTableHtml(r.recordColumns(), { rows: [r.recordRow(rec, new Map())] }, 'none');
  H.inert(recs, 'the record rows');
  H.shownAsText(recs, `why${H.ALL}`, HELP_ESC, 'a reason the page has no words for');
  globalThis.projects = [];
});
test('the Reports page draws the sign-off - the approver\'s note and account - as text', () => {
  globalThis.esc = H.pageEsc('reports.html');
  globalThis.UX = liftConst('reports.html', 'UX');
  globalThis.VmfHelp = { approvalRequired: () => true };
  const { signoffCell } = liftAll('reports.html', ['signoffCell']);
  const wave = `w1${H.QUOTE}`;
  const one = signoffCell({ approvals: new Map([[wave, { note: `ok ${H.ALL}`, approvedBy: { identity: `a${H.ALL}@example.com` } }]]) }, wave, { vms: [] });
  H.inert(one, 'a wave sign-off');
  const plan = signoffCell({ approvals: new Map(), planApproval: { schemaVersion: 2, note: H.ALL, approvedBy: { identity: H.ALL } } }, wave, { vms: [{}] });
  H.inert(plan, 'a plan sign-off');
});

run('output-escape-pages');
