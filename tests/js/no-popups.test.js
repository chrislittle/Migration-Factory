/* NO-POPUPS-1: nothing the dashboard shows opens a second window.
 *
 * Since 2026-11-05, the product has NO popups anywhere. Found in the lab:
 * Open the full report opened a new window, and where the browser blocked it
 * the Reports page showed the raw script error "Cannot read properties of null
 * (reading 'document')" - window.open gave null, and the page wrote into it.
 *
 * So the report shows IN the page, in the same frame with an empty sandbox
 * (SEC-REPORT-1), with Close and Escape (rule 11) and a download for the file.
 * The manual and the links open in the same tab, and the manual has a way
 * back to the page it came from.
 *
 * RUN, not read: the page's own functions, lifted.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { extract, lift, liftConst, test, eq, ok, run } = require('./_harness');
const { pageSource } = require('./_page-source');

globalThis.UX = liftConst('reports.html', 'UX');
globalThis.esc = (v) => String(v ?? '');
globalThis.markTheme = lift('reports.html', 'markTheme');
const openReport = lift('reports.html', 'openReport');
const closeReport = lift('reports.html', 'closeReport');
globalThis.closeReport = closeReport;   // reportKey calls it
const downloadReport = lift('reports.html', 'downloadReport');
const reportKey = lift('reports.html', 'reportKey');

const REPORT = '<!DOCTYPE html><html lang="en"><body><p>r</p></body></html>';

/* A page just real enough to hold the report view: the view, its slot, its
 * title, and the two buttons. */
function fakePage() {
  const els = {};
  const mk = (id) => {
    const el = {
      id, hidden: true, textContent: '', children: [], _attrs: {}, style: {}, focused: 0,
      setAttribute(k, v) { this._attrs[k] = v; },
      replaceChildren(...kids) { this.children = kids; },
      focus() { this.focused++; page.active = this; },
    };
    els[id] = el;
    return el;
  };
  ['report-view', 'report-slot', 'report-run', 'report-close', 'report-download'].forEach(mk);
  const classes = new Set();
  const made = [];
  const srcdocs = [];
  const page = {
    els, made, srcdocs, classes, active: null, saved: [],
    document: {
      getElementById: (id) => els[id] || null,
      body: { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) } },
      createElement: (tag) => {
        const el = { tag, style: {}, _attrs: {}, setAttribute(k, v) { this._attrs[k] = v; } };
        Object.defineProperty(el, 'srcdoc', {
          set(v) { srcdocs.push({ v, sandbox: el._attrs.sandbox }); },
          get() { return srcdocs.length ? srcdocs[srcdocs.length - 1].v : ''; },
        });
        made.push(el);
        return el;
      },
    },
  };
  return page;
}

let opens = 0;
function usePage(theme) {
  const page = fakePage();
  globalThis.document = page.document;
  opens = 0;
  globalThis.window = {
    open: () => { opens++; return null; },
    VmfTheme: theme ? { current: () => theme } : undefined,
  };
  globalThis.source = { readText: async (r, rel) => (rel === 'customer-report.html' ? REPORT : null) };
  globalThis.saveFile = (name, text, type) => page.saved.push({ name, text, type });
  globalThis.reportShown = liftConst('reports.html', 'reportShown');
  return page;
}

test('the functions were found in the page', () => {
  for (const fn of [openReport, closeReport, downloadReport, reportKey]) {
    ok(typeof fn === 'function', 'otherwise every assertion below is vacuous');
  }
});

test('THE POINT: the report opens with no second window, so a popup blocker cannot stop it', async () => {
  const page = usePage('light');
  await openReport('r1');
  eq(opens, 0, 'window.open is never called');
  eq(page.els['report-view'].hidden, false, 'the view shows in the page');
  eq(page.els['report-slot'].children.length, 1, 'with one frame in it');
});

test('SEC-REPORT-1 still: the frame has an EMPTY sandbox, set before the report goes in', async () => {
  const page = usePage('dark');
  await openReport('r1');
  const frame = page.els['report-slot'].children[0];
  eq(frame.tag, 'iframe', 'a frame');
  eq(frame._attrs.sandbox, '', 'empty: an opaque origin, no script, no popup, no navigation of this page');
  eq(page.srcdocs.length, 1, 'the report is handed over once');
  eq(page.srcdocs[0].sandbox, '', 'the frame was locked when the report went in');
  ok(page.srcdocs[0].v.includes('<html data-theme="dark" lang="en">'), 'marked with the theme the page shows');
});

test('the view says which migration it shows, and puts the focus on Close', async () => {
  const page = usePage('light');
  await openReport('2026-11-05-wave');
  eq(page.els['report-run'].textContent, '2026-11-05-wave', 'the run');
  eq(page.active, page.els['report-close'], 'focus on the way back (rule 11)');
  ok(page.classes.has('report-open'), 'the page under it does not scroll');
});

test('Close hides the view, takes the report out of the page, and gives the focus back', async () => {
  const page = usePage('light');
  const opener = { focus() { page.active = opener; } };
  await openReport('r1', opener);
  closeReport();
  eq(page.els['report-view'].hidden, true, 'hidden');
  eq(page.els['report-slot'].children.length, 0, 'the frame is gone, not only hidden');
  ok(!page.classes.has('report-open'), 'the page scrolls again');
  eq(page.active, opener, 'focus back on the button that opened it');
});

test('Escape closes it, and only while it is open', async () => {
  const page = usePage('light');
  let prevented = 0;
  const esc = { key: 'Escape', preventDefault() { prevented++; } };
  eq(reportKey(esc), false, 'nothing open: Escape is left to the page');
  eq(prevented, 0, 'and not taken');
  await openReport('r1');
  eq(reportKey({ key: 'Enter', preventDefault() { prevented++; } }), false, 'another key does nothing');
  eq(page.els['report-view'].hidden, false, 'still open');
  eq(reportKey(esc), true, 'Escape is taken');
  eq(page.els['report-view'].hidden, true, 'and the view is closed');
  eq(prevented, 1, 'once');
});

test('the download is the report, marked with the theme, as a web page file named for the run', async () => {
  const page = usePage('dark');
  await openReport('proj/r 1');
  downloadReport();
  eq(page.saved.length, 1, 'one file');
  eq(page.saved[0].type, 'text/html', 'a web page');
  ok(page.saved[0].text.includes('<html data-theme="dark" lang="en">'), 'the same report the view shows');
  eq(page.saved[0].name, 'migration-report-proj-r-1.html', 'a file name with nothing a file system refuses');
});

test('a download with no report open saves nothing', async () => {
  const page = usePage('light');
  await openReport('r1');
  closeReport();
  downloadReport();
  eq(page.saved.length, 0, 'nothing');
});

test('a second report replaces the first; the page holds one frame', async () => {
  const page = usePage('light');
  await openReport('r1');
  await openReport('r2');
  eq(page.els['report-slot'].children.length, 1, 'one frame');
  eq(page.els['report-run'].textContent, 'r2', 'the second run');
});

test('a report that cannot be read leaves the view closed, so the page can say why', async () => {
  const page = usePage('light');
  globalThis.source = { readText: async () => { throw new Error('403'); } };
  let threw = false;
  try { await openReport('r1'); } catch (e) { threw = true; }
  ok(threw, 'the error reaches the caller, which shows it on the page');
  eq(page.els['report-view'].hidden, true, 'no empty view');
});

// ---------- help.js: the manual opens in this tab ----------

test('the manual link names the page it came from, with its query', () => {
  globalThis.MANUAL_URL = 'manual/index.html';
  globalThis.currentPage = () => 'waves.html';
  globalThis.location = { search: '?run=r1&flow=1' };
  const manualHref = lift('help.js', 'manualHref');
  eq(manualHref(), 'manual/index.html?from=' + encodeURIComponent('waves.html?run=r1&flow=1'), 'the manual, and the way back');
  eq(manualHref('#/understand/disclaimer'),
     'manual/index.html?from=' + encodeURIComponent('waves.html?run=r1&flow=1') + '#/understand/disclaimer', 'a page of it');
});

test('opening the manual goes there in this tab', () => {
  globalThis.manualHref = () => 'manual/index.html?from=x';
  globalThis.location = { href: 'waves.html' };
  globalThis.window = { open: () => { opens++; return null; } };
  opens = 0;
  lift('help.js', 'openManual')();
  eq(location.href, 'manual/index.html?from=x', 'same tab');
  eq(opens, 0, 'no window');
});

// ---------- docs/manual/index.js: the way back ----------
// CSP-INLINE-1: the manual's script is index.js; read the page as the browser puts it together.

const MANUAL = pageSource(path.join(__dirname, '..', '..', 'docs', 'manual', 'index.html'));
function liftManual(name) {
  const m = MANUAL.match(new RegExp(`\\n(\\s*)function ${name}\\s*\\([\\s\\S]*?\\n\\1\\}`));
  if (!m) { throw new Error(`could not lift ${name} from the manual`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[0].trim()})`);
}
const manualBackHref = liftManual('manualBackHref');
const escapeLeaves = liftManual('escapeLeaves');

test('the manual goes back to the page that opened it, with its query', () => {
  eq(manualBackHref('?from=' + encodeURIComponent('waves.html?run=r1&flow=1')), '../waves.html?run=r1&flow=1', 'that page');
  eq(manualBackHref('?from=reports.html'), '../reports.html', 'with no query');
});

test('with no page, or one that is not a dashboard page, it goes to the start page', () => {
  for (const bad of ['', '?x=1', '?from=', '?from=https%3A%2F%2Fexample.com%2F', '?from=%2F%2Fexample.com%2Fa.html',
    '?from=..%2Fx.html', '?from=javascript%3Aalert(1)', '?from=a%2Fb.html', '?from=waves.htm', null, undefined]) {
    eq(manualBackHref(bad), '../index.html', `for ${JSON.stringify(bad)}`);
  }
});

test('Escape leaves the manual, except while a person types or a picture is open', () => {
  const doc = (zoomed) => ({ querySelector: () => (zoomed ? {} : null) });
  eq(escapeLeaves({ key: 'Escape', target: { tagName: 'DIV' } }, doc(false)), true, 'on the page');
  eq(escapeLeaves({ key: 'Enter', target: { tagName: 'DIV' } }, doc(false)), false, 'another key');
  eq(escapeLeaves({ key: 'Escape', target: { tagName: 'INPUT' } }, doc(false)), false, 'in the search field, Escape is the field\'s');
  eq(escapeLeaves({ key: 'Escape', target: { tagName: 'DIV', isContentEditable: true } }, doc(false)), false, 'in an edit area');
  eq(escapeLeaves({ key: 'Escape', target: { tagName: 'DIV' } }, doc(true)), false, 'a zoomed picture closes first');
  eq(escapeLeaves({ key: 'Escape', defaultPrevented: true, target: { tagName: 'DIV' } }, doc(false)), false, 'taken by something else');
});

// ---------- the one exception: Microsoft Learn opens a new tab ----------
// Since 2026-11-05, a Microsoft Learn link opens a new tab.

const learnRules = { 'assessment-report.js': lift('assessment-report.js', 'isLearnLink'), 'manual/index.js': liftManual('isLearnLink'),
  // The copy the dashboard pages use (VmfHelp.isLearnLink): the rebuild list's link to the patch orchestration modes.
  'help.js': lift('help.js', 'isLearnLink') };

test('both copies of the rule take exactly an https address on learn.microsoft.com', () => {
  const yes = ['https://learn.microsoft.com/azure/virtual-machines/sizes', 'https://learn.microsoft.com/'];
  const no = ['http://learn.microsoft.com/azure', 'https://notlearn.microsoft.com/x', 'https://x.learn.microsoft.com/', 'https://learn.microsoft.com.example.com/x', 'https://example.com/learn.microsoft.com/',
    'https://evil.example/?u=https://learn.microsoft.com/', 'javascript:alert(1)//learn.microsoft.com', 'https://github.com/x', '', null, 'not a url'];
  for (const [file, rule] of Object.entries(learnRules)) {
    for (const u of yes) { eq(rule(u), true, `${file}: ${u}`); }
    for (const u of no) { eq(rule(u), false, `${file}: ${JSON.stringify(u)}`); }
  }
});

test('the manual gives a Learn link its new tab with noopener, and leaves every other link in this tab', () => {
  globalThis.isLearnLink = learnRules['manual/index.js'];
  const learnLinksInNewTab = liftManual('learnLinksInNewTab');
  const links = [{ href: 'https://learn.microsoft.com/azure/x' }, { href: 'https://github.com/x', target: '_self' }, { href: 'http://localhost/manual/index.html#/use/waves' }];
  learnLinksInNewTab({ querySelectorAll: (sel) => { eq(sel, 'a[href]', 'every link'); return links; } });
  eq(links[0].target, '_blank', 'Learn: a new tab');
  eq(links[0].rel, 'noopener noreferrer', 'with noopener');
  eq(links[1].target, '_self', 'another site: this tab');
  eq(links[1].rel, undefined, 'untouched');
  eq(links[2].target, undefined, 'a page of the manual: untouched');
});

test('a finding link to Learn opens a new tab with noopener; any other address stays in this tab', () => {
  const vm = require('vm');
  const ctx = { console, URL, window: {}, fetch: async () => ({ ok: false }),
    document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} } };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'assessment-report.js'), 'utf8'), ctx);
  const R = ctx.window.VmfReport;
  Object.assign(R.REASONS.blockers, {
    A: { title: 'a', meaning: 'm', docs: { url: 'https://learn.microsoft.com/azure/x', label: 'LearnPage' } },
    B: { title: 'b', meaning: 'm', docs: { url: 'https://example.com/x', label: 'OtherPage' } } });
  const link = (code, label) => (R.reasonCard(code, ['vm1'], 'bad').match(new RegExp(`<a [^>]*>${label}</a>`)) || [''])[0];
  const learn = link('A', 'LearnPage');
  const other = link('B', 'OtherPage');
  ok(/target="_blank"/.test(learn) && /rel="noopener noreferrer"/.test(learn), `Learn link: ${learn}`);
  ok(other && !/target=/.test(other), `other link: ${other}`);
});

// ---------- the second exception: this product's GitHub issue page ----------
// Since 2026-11-05, a new tab is the choice - Get help's bug report and
// feature request open in a new tab, so the dashboard stays open.
//
// help.js's REPO is a constant inside its module, and the harness has a REPO
// of its own (the checkout's path), so these are evaluated with the page's
// REPO handed in, read from the page itself.

const HELP = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8');
const PAGE_REPO = (HELP.match(/const REPO = '([^']+)';/) || [])[1];
function liftIssue(names, extra) {
  const bodies = names.map((n) => extract('help.js', n)).join('\n');
  // eslint-disable-next-line no-new-func
  return new Function('REPO', 'versionSummary', `${bodies}\nreturn { ${names.join(', ')} };`)(PAGE_REPO, extra);
}

test('the page names its repository, or the tests below prove nothing', () => {
  ok(/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(PAGE_REPO || ''), `REPO: ${PAGE_REPO}`);
});

test('the issue rule takes exactly this product\'s new-issue page over https', () => {
  const { isIssueLink } = liftIssue(['isIssueLink']);
  const p = new URL(PAGE_REPO).pathname;
  // A user name and password in the address, built rather than written, so no
  // text in this file has the shape of an email address (PII-1).
  const withLogin = new URL(PAGE_REPO + '/issues/new');
  withLogin.username = 'user'; withLogin.password = 'pw';
  const yes = [PAGE_REPO + '/issues/new', PAGE_REPO + '/issues/new?template=bug_report.md&title=x&body=y'];
  const no = ['http://github.com' + p + '/issues/new', PAGE_REPO + '/issues', PAGE_REPO + '/issues/new/x', PAGE_REPO + '/pulls',
    'https://github.com/someone-else/repo/issues/new', 'https://github.com.example.com' + p + '/issues/new',
    withLogin.href, 'https://github.com:8443' + p + '/issues/new',
    'https://learn.microsoft.com/azure/x', 'javascript:alert(1)', '', null, 'not a url'];
  for (const u of yes) { eq(isIssueLink(u), true, u); }
  for (const u of no) { eq(isIssueLink(u), false, JSON.stringify(u)); }
});

test('the bug report link names the page, the version and the open migration', () => {
  const { issueHref, isIssueLink } = liftIssue(['issueUrl', 'issueHref', 'isIssueLink'], () => 'dashboard 0.4.0');
  const bugHref = issueHref('bug', 'waves.html', 'r1');
  ok(isIssueLink(bugHref), 'it is a link the rule opens in a new tab');
  const bug = new URL(bugHref);
  eq(bug.searchParams.get('template'), 'bug_report.md', 'the bug template');
  eq(bug.searchParams.get('title'), '[waves.html] ', 'the page in the title');
  ok(bug.searchParams.get('body').includes('Migration: r1'), 'the run');
  ok(bug.searchParams.get('body').includes('Version: dashboard 0.4.0'), 'the version');
  const idea = new URL(issueHref('idea', 'waves.html', ''));
  eq(idea.searchParams.get('template'), 'feature_request.md', 'the feature template');
  eq(idea.searchParams.get('title'), '', 'no title');
});

run('no-popups');
