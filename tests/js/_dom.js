/* TESTPLAN-1 layer 1: enough of a browser to BOOT a dashboard page.
 *
 * WHY THIS EXISTS. tests/js lifts named functions out of a page and runs them,
 * which catches a function that is wired wrongly. It cannot catch a page that
 * throws before it draws anything, because nothing here has ever loaded a
 * page. Every defect of that shape has been found by somebody opening the
 * product.
 *
 * WHAT THIS IS. A small DOM, no dependencies, so a page's whole script can be
 * executed in demo mode - which needs no install, no subscription and no
 * network. It answers one question per page: does it boot, and does it paint?
 *
 * WHAT THIS IS NOT, AND THE LIMIT IS THE POINT. Content assigned to innerHTML
 * is kept as TEXT and never parsed into elements. So a lookup INSIDE freshly
 * painted markup finds nothing, and a page that wires handlers to rows it just
 * drew wires none of them here. That is a real limit, and it is deliberate: a
 * hand-written HTML parser that is subtly wrong would report a page healthy
 * for reasons that have nothing to do with the browser, which is the defect
 * this whole layer exists to stop making.
 *
 * So: assert on what a page PAINTED, as text. Do not assert that a button it
 * drew can be clicked - use the lifting harness for that, where the function
 * is real and the DOM is yours.
 *
 * Elements named by an `id` in the page's STATIC markup are real, because
 * those exist before any script runs and are what a page reads and writes.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');

/** One element. Enough of one for a page to read and write it. */
function makeEl(tag, id) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    id: id || '',
    _html: '',
    textContent: '',
    value: '',
    checked: false,
    disabled: false,
    href: '',
    title: '',
    hidden: false,
    style: {},
    dataset: {},
    attributes: {},
    children: [],
    handlers: {},
    parentElement: null,
    classList: {
      _set: new Set(),
      add(...c) { c.forEach(x => this._set.add(x)); },
      remove(...c) { c.forEach(x => this._set.delete(x)); },
      contains(c) { return this._set.has(c); },
      toggle(c, on) { if (on === undefined) { this._set.has(c) ? this._set.delete(c) : this._set.add(c); } else if (on) { this._set.add(c); } else { this._set.delete(c); } },
    },
    get className() { return [...this.classList._set].join(' '); },
    set className(v) { this.classList._set = new Set(String(v).split(/\s+/).filter(Boolean)); },
    set innerHTML(v) { this._html = String(v); },
    get innerHTML() { return this._html; },
    /* SKIP-ONE-RUNBODY-1: the run page adds rows this way after an action. It
     * is kept as text, like innerHTML; a place outside the element is not
     * drawn here (there is no tree to put it in). */
    insertAdjacentHTML(where, markup) {
      if (where === 'afterbegin') { this.innerHTML = String(markup) + this.innerHTML; }
      else if (where === 'beforeend') { this.innerHTML = this.innerHTML + String(markup); }
    },
    setAttribute(k, v) { this.attributes[k] = String(v); if (k === 'id') { this.id = String(v); } },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
    removeAttribute(k) { delete this.attributes[k]; },
    appendChild(child) { child.parentElement = this; this.children.push(child); return child; },
    insertBefore(child, before) {
      child.parentElement = this;
      const at = this.children.indexOf(before);
      if (at < 0) { this.children.push(child); } else { this.children.splice(at, 0, child); }
      return child;
    },
    removeChild(child) {
      const at = this.children.indexOf(child);
      if (at >= 0) { this.children.splice(at, 1); }
      child.parentElement = null;
      return child;
    },
    remove() { if (this.parentElement) { this.parentElement.removeChild(this); } },
    addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
    removeEventListener(type, fn) {
      const list = this.handlers[type] || [];
      const at = list.indexOf(fn);
      if (at >= 0) { list.splice(at, 1); }
    },
    dispatchEvent() { return true; },
    focus() { },
    click() { for (const fn of (this.handlers.click || [])) { fn({ target: el, preventDefault() { } }); } },
    // Nothing is found inside painted markup - see the header. An empty list is
    // the honest answer, and a page that wires nothing still boots.
    querySelector() { return null; },
    querySelectorAll() { return []; },
    closest() { return null; },
    getBoundingClientRect() { return { top: 0, left: 0, width: 0, height: 0, bottom: 0, right: 0 }; },
    scrollIntoView() { },
    contains() { return false; },
  };
  return el;
}

/** The ids the page's own markup declares, before any script runs. */
function staticIds(html) {
  const ids = new Map();
  for (const m of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g)) {
    if (!ids.has(m[2])) { ids.set(m[2], m[1]); }
  }
  return ids;
}

/** Everything between <script> tags that is not a src= include. */
function inlineScripts(html) {
  return [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
}

/**
 * Boot one page in demo mode.
 *
 * Returns { errors, unhandled, painted, fetched, byId, ran } - `painted` is every
 * innerHTML the page assigned, as text, which is what to assert on.
 */
function bootPage(pageFile, opts) {
  const options = opts || {};
  const html = pageSource(path.join(DASH, pageFile));
  const ids = staticIds(html);
  const byId = new Map();
  const loose = new Map();   // selectors that name an id and reach further
  for (const [id, tag] of ids) { byId.set(id, makeEl(tag, id)); }

  const errors = [];
  const unhandled = [];
  const painted = [];
  const fetched = [];        // the page's own data files, served from disk

  // Every assignment to innerHTML is recorded, wherever it lands. This is the
  // evidence a page painted, and the only thing worth asserting on.
  const watchPaint = (el) => {
    let held = '';
    Object.defineProperty(el, 'innerHTML', {
      get() { return held; },
      set(v) { held = String(v); painted.push({ id: el.id, html: held }); },
      configurable: true,
    });
    return el;
  };

  const doc = {
    title: '',
    readyState: 'complete',
    getElementById: (id) => byId.get(id) || null,
    createElement: (tag) => makeEl(tag),
    createTextNode: (t) => ({ textContent: String(t) }),
    addEventListener() { },
    removeEventListener() { },
    /* A selector that NAMES AN ID gets an element, even when it reaches
     * further - `#projects-table tbody` is a place the page writes, and the
     * page writing there is the thing being checked.
     *
     * Returning null instead made three pages paint NOTHING and swallow the
     * failure in their own error handler, so a boot looked clean while the
     * page had rendered no rows. Found while writing this: the first version
     * of this file reported exactly that. The element is memoised per selector
     * so the page finds the same one twice, as it would in a browser. What is
     * NOT claimed is that the element sits where the selector says.
     */
    querySelector(sel) {
      const key = String(sel).trim();
      const exact = /^#([\w-]+)$/.exec(key);
      if (exact && byId.has(exact[1])) { return byId.get(exact[1]); }
      if (!/#[\w-]+/.test(key)) { return null; }      // names no id: nothing to stand in for
      if (!loose.has(key)) { loose.set(key, watchPaint(makeEl('div', key))); }
      return loose.get(key);
    },
    querySelectorAll() { return []; },
    get documentElement() { return this._root || (this._root = makeEl('html')); },
    get head() { return this._head || (this._head = makeEl('head')); },
    get body() { return this._body || (this._body = makeEl('body')); },
  };

  for (const el of byId.values()) { watchPaint(el); }

  /* LOADING-LINE-1, opt-in (options.parts): the shared list (VmfHelp.listMount)
   * draws its skeleton into a host and then writes into each part by
   * `[data-part="name"]`. With no parts, a page that uses it throws at its
   * first draw, so nothing it draws can be checked. This answers ONLY that
   * selector, with one recorded element per host and part - the same rule as
   * a selector that names an id above: what the page writes there is the
   * thing checked, not where the element sits. Each part's paint is recorded
   * with the id `<host id> <part>`. Off by default, so every other boot sees
   * the DOM it always saw. */
  if (options.parts) {
    const withParts = (el) => {
      const kept = new Map();
      el.querySelector = (sel) => {
        const m = /^\[data-part="([\w-]+)"\]$/.exec(String(sel).trim());
        if (!m) { return null; }
        if (!kept.has(m[1])) { kept.set(m[1], withParts(watchPaint(makeEl('div', `${el.id} ${m[1]}`)))); }
        return kept.get(m[1]);
      };
      return el;
    };
    for (const el of byId.values()) { withParts(el); }
    const looseGet = doc.querySelector;
    doc.querySelector = (sel) => { const el = looseGet.call(doc, sel); if (el && !el._parts) { el._parts = true; withParts(el); } return el; };
  }

  // WAVES-API-1: a boot may start with what an earlier visit stored.
  const store = new Map(Object.entries(options.storage || {}));
  const storage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: (k) => { store.delete(k); },
    clear: () => { store.clear(); },
  };

  const sandbox = {
    console: { log() { }, warn() { }, error(...a) { errors.push(a.join(' ')); }, info() { }, debug() { } },
    setTimeout: (fn) => { void fn; return 0; },          // nothing polls in a boot
    clearTimeout() { },
    setInterval: () => 0,
    clearInterval() { },
    queueMicrotask: (fn) => Promise.resolve().then(fn),
    Promise, Date, Math, JSON, Map, Set, WeakMap, Array, Object, String, Number,
    Boolean, RegExp, Error, TypeError, isFinite, isNaN, parseInt, parseFloat,
    URL, URLSearchParams, TextEncoder, TextDecoder, structuredClone,
    // WAVES-API-1: a boot outside demo mode reads a token and asks the
    // service, which needs these as a browser has them.
    atob, btoa, AbortController,
    document: doc,
    localStorage: storage,
    sessionStorage: storage,
    location: {
      href: `https://localhost/${pageFile}${options.search || '?demo'}`,
      origin: 'https://localhost',
      pathname: `/${pageFile}`,
      search: options.search || '?demo',
      hash: options.hash || '',
      assign() { }, replace() { }, reload() { },
    },
    history: { replaceState() { }, pushState() { } },
    navigator: { userAgent: 'vmf-boot', clipboard: { writeText: () => Promise.resolve() } },
    CSS: { escape: (s) => String(s).replace(/["\\]/g, '\\$&') },
    matchMedia: () => ({ matches: false, addEventListener() { }, removeEventListener() { } }),
    /* A page may fetch its OWN shipped data files - the stop reasons and the
     * assessment findings are deployed beside it, and it reads them in demo
     * mode too. Those are served from disk, because refusing them tests
     * nothing and makes two pages look broken.
     *
     * Anything else is the API, and reaching it during a demo boot is a
     * FAILURE rather than a stub that quietly answers. Demo mode exists so a
     * page needs no service; a page that calls one anyway is the defect.
     */
    fetch: (u, init) => {
      /* WAVES-API-1: a boot OUTSIDE demo mode gives its own stand-in service.
       * It answers first; what it does not answer falls through to the rules
       * below, so the network is still refused. */
      if (options.fetch) {
        const answer = options.fetch(String(u), init || {});
        if (answer !== undefined) { return Promise.resolve(answer); }
      }
      const name = String(u).split('?')[0];
      if (/^[\w.-]+\.json$/.test(name)) {
        /* Two of these are not IN src/dashboard: the assessment findings and
         * the stop reasons are the ENGINE's data files, and Deploy-VmfDashboard
         * copies them in beside the pages so two copies cannot disagree. A boot
         * from the source tree has to look where the deploy takes them from, or
         * three pages appear to reach the network for a file they ship with. */
        const full = [path.join(DASH, name), path.join(REPO, 'src', 'VmMigrationFactory', 'data', name)]
          .find(p => fs.existsSync(p));
        if (full) {
        const body = fs.readFileSync(full, 'utf8');
        fetched.push(name);
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(JSON.parse(body)), text: () => Promise.resolve(body) });
        }
      }
      errors.push(`reached the network during a demo boot: ${u}`);
      return Promise.reject(new Error('no network in a boot'));
    },
    alert() { errors.push('alert() during a boot'); },
    confirm() { errors.push('confirm() during a boot'); return false; },
    addEventListener() { },
    removeEventListener() { },
    requestAnimationFrame: (fn) => { void fn; return 0; },
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;

  const ctx = vm.createContext(sandbox);
  const ran = [];
  const run = (code, label) => {
    try { vm.runInContext(code, ctx, { filename: label, timeout: 10000 }); ran.push(label); }
    catch (e) { errors.push(`${label}: ${e && e.message ? e.message : String(e)}`); }
  };

  // The shared files a page includes, in the order it includes them.
  for (const m of html.matchAll(/<script[^>]*\bsrc="([^"]+)"[^>]*>/g)) {
    const file = m[1];
    if (!/^[\w.-]+\.js$/.test(file)) { continue; }
    const full = path.join(DASH, file);
    if (!fs.existsSync(full)) { continue; }          // msal is not here, and demo mode does not need it
    run(fs.readFileSync(full, 'utf8'), file);
  }
  /* WAVES-API-1: stand-ins a boot outside demo mode needs (MSAL), put in
   * AFTER the shared files, so the stand-in replaces the library. */
  Object.assign(sandbox, options.globals || {});
  for (const [i, code] of inlineScripts(html).entries()) { run(code, `${pageFile}#${i + 1}`); }

  return { errors, unhandled, painted, fetched, byId, ran, sandbox };
}

/** Wait for whatever the page started, then report. A boot is asynchronous. */
async function settle(result, turns = 50) {
  for (let i = 0; i < turns; i++) { await Promise.resolve(); }
  await new Promise(r => setImmediate(r));
  for (let i = 0; i < turns; i++) { await Promise.resolve(); }
  return result;
}

module.exports = { bootPage, settle, makeEl };
