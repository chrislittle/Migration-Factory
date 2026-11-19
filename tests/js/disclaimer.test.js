/* DISCLAIMER-1: the app itself says it is not an official Microsoft product.
 *
 * Three things a person meets in the browser, each RUN here rather than read:
 *
 *   1. the short line, at the foot of every page, with a link to the manual
 *      page that holds the full notice - every page is booted and asked;
 *   2. the full notice, ONCE, at the first sign-in in this browser, with an OK,
 *      Escape and the backdrop to close it, and never again after that - also
 *      when the browser refuses storage, where it must not break the page;
 *   3. the short line in each file the browser writes: the migration record,
 *      the file for pricing and the support file.
 *
 * The words come from src/VmMigrationFactory/data/disclaimer.json, the one
 * source; tests/unit/Disclaimer.Tests.ps1 holds that file to the agreed words
 * and help.js's copy to the file.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const WORDS = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'disclaimer.json'), 'utf8'));
const HELP = pageSource(path.join(DASH, 'help.js'));
const PAGES = fs.readdirSync(DASH).filter(f => f.endsWith('.html')).sort();
const escHtml = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// help.js's own key for the "seen" flag, read from the file, so a test that
// set a key of its own could not pass while the page used another.
const KEY = (/const DISCLAIMER_KEY = '([^']+)';/.exec(HELP) || [])[1];

/** Every element under a node, depth first. */
function walk(node, out = []) {
  for (const c of (node.children || [])) { out.push(c); walk(c, out); }
  return out;
}

// ---------- 1. the short line on every page ----------

test('there are eight pages, so the loop below cannot pass by finding none', () => {
  eq(PAGES.length, 8, `pages: ${PAGES.join(', ')}`);
});

for (const page of PAGES) {
  test(`${page} shows the short line at its foot, with a link to the full notice`, async () => {
    const r = await settle(bootPage(page));
    const foot = walk(r.sandbox.document.body).find(el => el.id === 'vmf-disclaimer');
    ok(foot, `${page} has no line at its foot`);
    eq(foot.tagName, 'FOOTER', 'it is the foot of the page');
    ok(foot.innerHTML.includes(escHtml(WORDS.shortLine)), `the agreed words: ${foot.innerHTML}`);
    // NO-POPUPS-1: in this tab, naming the page so the manual can go back to it.
    ok(new RegExp('href="manual/index\\.html\\?from=' + page.replace('.', '\\.') + '[^"#]*#/understand/disclaimer"').test(foot.innerHTML),
       `and it links to the manual page: ${foot.innerHTML}`);
    ok(!/target=/.test(foot.innerHTML), 'in this tab, never a new window');
    ok(!foot.hidden && foot.style.display !== 'none', 'and nothing hides it');
  });
}

test('the line is installed with the file, before any page asks: no page can forget it', () => {
  // It runs where installNav runs - when help.js loads - so a page that never
  // calls VmfHelp still has it. The boot above proves it; this proves WHERE.
  const tail = HELP.slice(HELP.lastIndexOf('installNav();'));
  ok(/^installNav\(\);\s*\n\s*installDisclaimerLine\(\);/.test(tail), 'installDisclaimerLine() runs beside installNav()');
});

test('a second call does not add a second line', () => {
  const installDisclaimerLine = lift('help.js', 'installDisclaimerLine');
  const body = { children: [], appendChild(c) { this.children.push(c); return c; } };
  const made = [];
  global.TEXT = { disclaimerLine: WORDS.shortLine, disclaimerRead: 'Read the disclaimer' };
  global.esc = escHtml;
  global.DISCLAIMER_HASH = '#/understand/disclaimer';
  global.manualHref = (hash) => 'manual/index.html?from=x' + hash;
  global.document = {
    body,
    getElementById: (id) => made.find(e => e.id === id) || null,
    querySelector: () => null,
    createElement: (tag) => { const e = { tagName: tag.toUpperCase(), style: {} }; made.push(e); return e; },
  };
  installDisclaimerLine();
  installDisclaimerLine();
  eq(body.children.length, 1, 'one line');
});

// ---------- 2. the full notice, once, at the first sign-in ----------

/** The smallest DOM that dialog() touches, with storage that can refuse. */
function noticeDom({ refuse = false, stored = null } = {}) {
  const listeners = [];
  const opened = [];
  const make = (tag) => {
    const el = {
      tag, children: [], isConnected: false, handlers: {}, style: {}, className: '', type: '', textContent: '', _html: '',
      set innerHTML(v) { this._html = v; }, get innerHTML() { return this._html; },
      setAttribute() {},
      appendChild(child) { this.children.push(child); return child; },
      querySelector(sel) { this._q = this._q || {}; if (!this._q[sel]) { this._q[sel] = make('div'); } return this._q[sel]; },
      addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
      remove() { this.isConnected = false; },
    };
    return el;
  };
  const store = new Map(stored ? [[KEY, stored]] : []);
  const storage = {
    getItem(k) { if (refuse) { throw new Error('SecurityError: storage is refused'); } return store.has(k) ? store.get(k) : null; },
    setItem(k, v) { if (refuse) { throw new Error('SecurityError: storage is refused'); } store.set(k, String(v)); },
  };
  global.window = { localStorage: storage };
  global.document = {
    createElement: make,
    body: { appendChild(el) { el.isConnected = true; opened.push(el); return el; } },
    addEventListener(type, fn) { listeners.push({ type, fn }); },
    removeEventListener(type, fn) { const i = listeners.findIndex(l => l.type === type && l.fn === fn); if (i >= 0) { listeners.splice(i, 1); } },
    querySelector: () => null,
  };
  global.esc = escHtml;
  global.TEXT = {
    title: 'Help', disclaimerTitle: WORDS.title,
    disclaimerP1: WORDS.paragraphs[0], disclaimerP2: WORDS.paragraphs[1], disclaimerP3: WORDS.paragraphs[2],
    disclaimerOk: 'OK',
  };
  global.DISCLAIMER_KEY = KEY;
  global.disclaimerState = { shown: false };   // a new page load
  return {
    store, opened, listeners,
    press(key) { for (const l of [...listeners]) { l.fn({ key }); } },
    okButton(back) { return back.querySelector('#vmf-help-actions').children[0]; },
    newPage() { global.disclaimerState = { shown: false }; },
  };
}
const NOTICE = liftAll('help.js', ['dialog', 'disclaimerSeen', 'rememberDisclaimer', 'showDisclaimer', 'disclaimerOnSignIn']);
const ACCOUNT = { username: 'operator@example.com', name: 'Operator' };

test('help.js keeps the flag under a key of its own', () => {
  ok(KEY && /disclaimer/.test(KEY), `the key: ${KEY}`);
});

test('THE POINT: the first sign-in opens the full notice, with the agreed words and an OK', () => {
  const dom = noticeDom();
  const back = NOTICE.disclaimerOnSignIn(ACCOUNT, null);
  ok(back && back.isConnected, 'the notice is open');
  const html = back.innerHTML;
  ok(html.includes(`>${escHtml(WORDS.title)}</h2>`), 'its title');
  let at = -1;
  for (const p of WORDS.paragraphs) {
    const i = html.indexOf(escHtml(p));
    ok(i > at, `each paragraph, in order: ${p}`);
    at = i;
  }
  eq(dom.okButton(back).textContent, 'OK', 'the button');
  ok(dom.okButton(back).className.split(' ').includes('btn'), 'and it is the main button');
});

test('OK closes it', () => {
  const dom = noticeDom();
  const back = NOTICE.disclaimerOnSignIn(ACCOUNT, null);
  for (const fn of dom.okButton(back).handlers.click) { fn(); }
  eq(back.isConnected, false, 'closed');
  eq(dom.listeners.length, 0, 'and its Escape listener is gone with it');
});

test('Escape closes it (rule 11)', () => {
  const dom = noticeDom();
  const back = NOTICE.disclaimerOnSignIn(ACCOUNT, null);
  dom.press('Escape');
  eq(back.isConnected, false, 'closed');
});

test('a click beside it closes it too', () => {
  noticeDom();
  const back = NOTICE.disclaimerOnSignIn(ACCOUNT, null);
  for (const fn of back.handlers.click) { fn({ target: back }); }
  eq(back.isConnected, false, 'closed');
});

test('it does not open again: not later on the same page, and not on the next page', () => {
  const dom = noticeDom();
  NOTICE.disclaimerOnSignIn(ACCOUNT, null);
  eq(dom.store.get(KEY), '1', 'the browser remembers it was seen');
  eq(NOTICE.disclaimerOnSignIn(ACCOUNT, null), null, 'the same page asks again: nothing opens');
  dom.newPage();
  eq(NOTICE.disclaimerOnSignIn(ACCOUNT, null), null, 'the next page: nothing opens');
  eq(dom.opened.length, 1, 'it opened once in all');
});

test('a browser that saw it before does not show it', () => {
  const dom = noticeDom({ stored: '1' });
  eq(NOTICE.disclaimerOnSignIn(ACCOUNT, null), null);
  eq(dom.opened.length, 0);
});

test('nobody signed in, or the sample data: no notice', () => {
  const dom = noticeDom();
  eq(NOTICE.disclaimerOnSignIn(null, null), null, 'no account');
  eq(NOTICE.disclaimerOnSignIn(ACCOUNT, 'Sample viewer'), null, 'the sample data names a viewer, not a user');
  eq(dom.opened.length, 0);
  eq(dom.store.has(KEY), false, 'and nothing is remembered');
});

test('a browser that refuses storage: the page goes on, and the notice opens once on that page', () => {
  const dom = noticeDom({ refuse: true });
  let back = null;
  try { back = NOTICE.disclaimerOnSignIn(ACCOUNT, null); } catch (e) { ok(false, `it threw: ${e.message}`); }
  ok(back && back.isConnected, 'it opens - a notice that cannot be remembered is shown, not dropped');
  eq(NOTICE.disclaimerOnSignIn(ACCOUNT, null), null, 'and not twice on one page');
  eq(dom.opened.length, 1);
});

test('identity() is where it opens, so every page that signs somebody in shows it', () => {
  // identity() is what each of the eight pages calls once it knows who is
  // signed in, and the role gate calls it too. Read as code, then run.
  const body = /function identity\(account, demoLabel\) \{([\s\S]*?)\n  \}/.exec(HELP);
  ok(body && /disclaimerOnSignIn\(account, demoLabel\);/.test(body[1]), 'identity() asks for the notice');
  for (const page of PAGES) {
    const src = pageSource(path.join(DASH, page));
    ok(/VmfHelp\.identity\(account/.test(src), `${page} calls VmfHelp.identity`);
  }
});

// ---------- 3. the short line in each file the browser writes ----------

test('the migration record a person downloads carries the line', () => {
  globalThis.UX = liftConst('reports.html', 'UX');
  globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { disclaimerLine: WORDS.shortLine });
  global.esc = escHtml;
  const recordHtml = lift('reports.html', 'recordHtml');
  const html = recordHtml({ runId: 'r1', machines: [], decisions: [], summary: {} }, null, 'light');
  ok(html.includes(`<p class="disclaimer">${escHtml(WORDS.shortLine)}</p>`), 'the line');
  ok(html.indexOf(escHtml(WORDS.shortLine)) > html.indexOf('</section>'), 'at the end of the record');
});

test('the file for pricing carries the line, as the last row', () => {
  const exportPricing = lift('wizard.html', 'exportPricing');
  const files = [];
  const realTimeout = globalThis.setTimeout, realUrl = globalThis.URL;
  Object.assign(globalThis, {
    pricingCsv: () => 'Region,Machines\r\ncentralus,1\r\n', CSV_BOM: '', runId: 'r1',
    csvCell: lift('wizard.html', 'csvCell'),
    Blob: function Blob(parts) { files.push(parts.join('')); },
    URL: { createObjectURL: () => 'blob:x', revokeObjectURL: () => {} },
    document: { createElement: () => ({ click() {}, remove() {} }), body: { appendChild() {} } },
    setTimeout: () => 0,
  });
  globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { disclaimerLine: WORDS.shortLine });
  try {
    exportPricing({ machines: [], picks: new Map(), sizes: new Map(), disks: new Map() });
    const lines = files[0].split('\r\n');
    eq(lines.slice(0, 2), ['Region,Machines', 'centralus,1'], 'the table first, as it was');
    eq(lines[lines.length - 2], `"${WORDS.shortLine}"`, 'then the line, in one cell');
    eq(lines[lines.length - 1], '', 'and the file ends on a line break');
  } finally { globalThis.setTimeout = realTimeout; globalThis.URL = realUrl; }
});

test('the support file carries the line', async () => {
  const buildBundle = lift('help.js', 'buildBundle');
  Object.assign(globalThis, {
    adapter: { readJson: async () => null, listFolder: async () => [], readLines: async () => [] },
    mapLimited: async (items, fn) => Promise.all(items.map(fn)),
    // PAGE-LOAD-2: the bundle's one limit, and its readers of a call it did not make.
    readLimiter: () => (read) => read(), heldJson: () => undefined, heldList: () => undefined,
    EVENT_CAP: 5000, clientErrors: [], build: null, service: null,
    location: { pathname: '/migrations.html' },
  });
  global.TEXT = { disclaimerLine: WORDS.shortLine };
  const bundle = await buildBundle('run-1');
  eq(bundle.disclaimer, WORDS.shortLine, 'the line, in the file a person sends');
  eq(Object.keys(bundle).indexOf('disclaimer') < Object.keys(bundle).indexOf('status'), true, 'near the top, before the data');
});

test('the pages read the line from help.js, and carry no copy of it', () => {
  for (const page of PAGES) {
    const src = pageSource(path.join(DASH, page));
    ok(!src.includes('not an official Microsoft product'), `${page} has its own copy`);
  }
  ok(/disclaimerLine: TEXT\.disclaimerLine/.test(HELP), 'VmfHelp hands the line to the pages');
});

run('disclaimer');
