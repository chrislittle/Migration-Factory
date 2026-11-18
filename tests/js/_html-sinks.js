/* OUTPUT-ESCAPE-1: a reader of the dashboard's code that finds every place a
 * page writes a value into HTML, and says which values are not escaped.
 *
 * WHY. Every page escapes text through one encoder, `esc`, and security passes
 * on single changes found it used where they looked. Nothing checked every
 * page, and no test failed when a new place showed text from a machine or
 * from Azure without it. The content security policy allowed inline script
 * until CSP-INLINE-1, so a missed escape was not caught by the browser
 * either.
 *
 * WHAT IT READS. The page's own script: the one inline <script> block of each
 * page as _page-source.js puts it back (CSP-INLINE-1 moved it to a file with
 * the page's name, which is read through its page and not twice), and the
 * whole of each shared .js file. Comments do not count. The scanner is
 * the same one as tests/unit/_CodeOnly.ps1 (strings, regular expressions,
 * template literals and their ${...} code are told apart the same way), and
 * html-sinks.test.js proves the two agree on every dashboard file.
 *
 * WHAT IT CHECKS. Every value a page writes into HTML:
 *   - each ${...} of a template literal that holds markup, or that sits inside
 *     one (a nested template, a .map(...) row);
 *   - each operand of a + that joins a string holding markup;
 *   - the right-hand side of every innerHTML, outerHTML, insertAdjacentHTML,
 *     srcdoc and document.write.
 * A value passes when it cannot carry markup that somebody else wrote:
 *   - esc(...), a literal, or a template literal (checked on its own);
 *   - a property of the page's own string table (UX, UX_ACT and the like),
 *     or a call of one whose arguments pass;
 *   - a number: .length, Math, Number(...), toFixed, an index;
 *   - a name or a call that resolves, inside the same file, only to values
 *     that pass (a local built from templates, a function whose every return
 *     passes);
 *   - the alternatives of a ?:, ||, ?? (each one), or the right side of &&.
 * Anything else is a FINDING: the place, and the value.
 */
'use strict';
const { pageSource, isPageScript } = require('./_page-source');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');

/* ---------------------------------------------------------------- scanner -- */

const REGEX_BEFORE = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';',
  '+', '-', '*', '%', '>', '~', '^', '\n']);
const REGEX_KEYWORDS = new Set(['return', 'typeof', 'case', 'in', 'of', 'do', 'else',
  'yield', 'await', 'delete', 'void', 'instanceof', 'new']);

/* Scan JavaScript source. Returns:
 *   code      - the source with every comment replaced by one space (newlines
 *               inside a block comment kept), the same output as
 *               Get-VmfCodeOnly -Language CStyle;
 *   mask      - the code with the CONTENT of every string, regular expression
 *               and template quasi replaced by '_' (same length), so an
 *               operator search on it never finds one inside a literal;
 *   templates - each template literal: start, end, its quasis' text, and the
 *               span of each ${...} expression;
 *   strings   - each '...' or "..." literal: start, end, text.
 * Positions are into `code` and `mask`, which have the same length. */
function scan(src) {
  const n = src.length;
  const code = [];
  const mask = [];
  const templates = [];
  const strings = [];
  let i = 0;

  const put = (ch, m) => { code.push(ch); mask.push(m === undefined ? ch : m); };

  function scanCode(stopAtBrace) {
    let braces = 0;
    let prevSig = '\n';
    let word = '';
    let lastWord = '';
    while (i < n) {
      const c = src[i];
      const nx = src[i + 1];
      if (c === '/' && nx === '/') {
        put(' ');
        while (i < n && src[i] !== '\n') { i++; }
        continue;
      }
      if (c === '/' && nx === '*') {
        put(' ');
        i += 2;
        while (i < n) {
          if (src[i] === '*' && src[i + 1] === '/') { i += 2; break; }
          if (src[i] === '\n') { put('\n'); }
          i++;
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        const start = code.length;
        put(c);
        i++;
        let text = '';
        while (i < n) {
          const d = src[i];
          if (d === '\\') { put(d, '_'); put(src[i + 1], '_'); text += d + src[i + 1]; i += 2; continue; }
          if (d === c) { put(d); i++; break; }
          put(d, '_');
          text += d;
          i++;
        }
        strings.push({ start, end: code.length, text });
        prevSig = c;
        if (word) { lastWord = word; }
        word = '';
        continue;
      }
      if (c === '`') {
        scanTemplate();
        prevSig = '`';
        if (word) { lastWord = word; }
        word = '';
        continue;
      }
      const wordish = /[A-Za-z0-9_$]/.test(prevSig);
      if (c === '/' && (REGEX_BEFORE.has(prevSig) || (wordish && REGEX_KEYWORDS.has(lastWord)))) {
        put(c);
        i++;
        let inClass = false;
        while (i < n) {
          const r = src[i];
          if (r === '\n') { break; }
          if (r === '\\') { put(r, '_'); put(src[i + 1], '_'); i += 2; continue; }
          if (r === '[') { inClass = true; } else if (r === ']') { inClass = false; } else if (r === '/' && !inClass) { put(r); i++; break; }
          put(r, '_');
          i++;
        }
        while (i < n && /[a-z]/.test(src[i])) { put(src[i]); i++; }
        prevSig = ')';
        word = '';
        lastWord = '';
        continue;
      }
      if (c === '{') { braces++; }
      if (c === '}') {
        if (stopAtBrace && braces === 0) { return; }
        braces--;
      }
      put(c);
      if (/[A-Za-z0-9_$]/.test(c)) { word += c; } else { if (word) { lastWord = word; } word = ''; }
      if (c === '\n') { prevSig = '\n'; } else if (!/\s/.test(c)) { prevSig = c; }
      i++;
    }
  }

  function scanTemplate() {
    const t = { start: code.length, end: 0, quasis: [''], exprs: [] };
    put('`');
    i++;
    while (i < n) {
      const c = src[i];
      if (c === '\\') { put(c, '_'); put(src[i + 1], '_'); t.quasis[t.quasis.length - 1] += c + src[i + 1]; i += 2; continue; }
      if (c === '`') { put(c); i++; break; }
      if (c === '$' && src[i + 1] === '{') {
        put('$'); put('{');
        i += 2;
        const es = code.length;
        scanCode(true);
        const ee = code.length;
        t.exprs.push({ start: es, end: ee });
        if (i < n) { put('}'); i++; }
        t.quasis.push('');
        continue;
      }
      put(c, c === '\n' ? '\n' : '_');
      t.quasis[t.quasis.length - 1] += c;
      i++;
    }
    t.end = code.length;
    templates.push(t);
  }

  while (i < n) {
    const before = i;
    scanCode(false);
    if (i < n && i === before) { put(src[i]); i++; }
    else if (i < n && src[i] === '}') { put('}'); i++; }
  }
  return { code: code.join(''), mask: mask.join(''), templates, strings };
}

/* The script of a dashboard file: the whole of a .js file, or the one inline
 * <script> block of a page (the src= ones are other files). Returned with the
 * line it starts on, so a finding names the page's own line. */
function scriptsOf(file) {
  const text = pageSource(path.join(DASH, file));
  if (file.endsWith('.js')) { return [{ text, line: 1 }]; }
  const out = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m;
  while ((m = re.exec(text))) {
    const offset = m.index + m[0].indexOf('>') + 1;
    out.push({ text: m[1], line: text.slice(0, offset).split('\n').length });
  }
  return out;
}

/* -------------------------------------------------------------- analyzer -- */

const OPENERS = { '(': ')', '[': ']', '{': '}' };
const CLOSERS = { ')': '(', ']': '[', '}': '{' };
const IDENT = /[A-Za-z0-9_$]/;
const TAG = /<\/?[A-Za-z!]/;

function closeOf(M, i) {
  let d = 0;
  for (let k = i; k < M.length; k++) {
    const c = M[k];
    if (OPENERS[c]) { d++; } else if (CLOSERS[c]) { d--; if (d === 0) { return k; } }
  }
  return -1;
}
function openOf(M, i) {
  let d = 0;
  for (let k = i; k >= 0; k--) {
    const c = M[k];
    if (CLOSERS[c]) { d++; } else if (OPENERS[c]) { d--; if (d === 0) { return k; } }
  }
  return -1;
}
/* The bracket that encloses k, looking back. */
function enclosingOpen(M, k) {
  let d = 0;
  for (let j = k; j >= 0; j--) {
    const c = M[j];
    if (CLOSERS[c]) { d++; } else if (OPENERS[c]) { if (d === 0) { return j; } d--; }
  }
  return -1;
}
/* Every index in [s, e) at bracket depth 0, in order. */
function tops(M, s, e) {
  const out = [];
  let d = 0;
  for (let k = s; k < e; k++) {
    const c = M[k];
    if (d === 0) { out.push(k); }
    if (OPENERS[c]) { d++; } else if (CLOSERS[c]) { d--; }
  }
  return out;
}
function trim(M, s, e) {
  while (s < e && /\s/.test(M[s])) { s++; }
  while (e > s && /\s/.test(M[e - 1])) { e--; }
  return [s, e];
}
function prevSig(M, k) { k--; while (k >= 0 && /\s/.test(M[k])) { k--; } return k < 0 ? '' : M[k]; }
function nextSigAt(M, k) { while (k < M.length && /\s/.test(M[k])) { k++; } return k; }
function reName(name) { return name.replace(/\$/g, '\\$'); }

/* Split [s, e) at every depth-0 occurrence of a two-character operator. */
function splitOn(M, s, e, op) {
  const cuts = [];
  for (const k of tops(M, s, e)) {
    if (M[k] === op[0] && M[k + 1] === op[1] && M[k + 2] !== '=' && M[k - 1] !== op[0] && M[k + 2] !== op[0]) { cuts.push(k); }
  }
  if (!cuts.length) { return null; }
  const parts = [];
  let from = s;
  for (const k of cuts) { parts.push([from, k]); from = k + 2; }
  parts.push([from, e]);
  return parts;
}

function isTernaryMark(M, k) { return M[k] === '?' && M[k + 1] !== '.' && M[k + 1] !== '?' && M[k - 1] !== '?'; }
/* The depth-0 ?: of [s, e), as [cond, yes, no] spans, or null. */
function ternary(M, s, e) {
  const t = tops(M, s, e);
  const q = t.find(k => isTernaryMark(M, k));
  if (q === undefined) { return null; }
  let depth = 0;
  for (const k of t) {
    if (k <= q) { continue; }
    if (isTernaryMark(M, k)) { depth++; }
    else if (M[k] === ':') { if (depth === 0) { return [[s, q], [q + 1, k], [k + 1, e]]; } depth--; }
  }
  return null;
}

function endsOperand(c) { return Boolean(c) && (IDENT.test(c) || ')]}\'"`'.includes(c)); }

/* A depth-0 binary + (not ++, not +=, not unary): the operand spans, or null. */
function plusParts(M, s, e) {
  const cuts = [];
  for (const k of tops(M, s, e)) {
    if (M[k] !== '+' || M[k + 1] === '+' || M[k - 1] === '+' || M[k + 1] === '=') { continue; }
    if (endsOperand(prevSig(M, k))) { cuts.push(k); }
  }
  if (!cuts.length) { return null; }
  const parts = [];
  let from = s;
  for (const k of cuts) { parts.push([from, k]); from = k + 1; }
  parts.push([from, e]);
  return parts;
}

/* A depth-0 operator whose result is a number or a boolean, whatever went in:
 * a comparison, - * / %, instanceof, in. */
function numericOp(M, s, e) {
  for (const k of tops(M, s, e)) {
    if (k === s) { continue; }
    const c = M[k], n = M[k + 1], b = M[k - 1];
    if ((c === '=' && n === '=' && b !== '=' && b !== '!') || (c === '!' && n === '=')) { return true; }
    if ((c === '<' || c === '>') && b !== '=' && n !== c && b !== c) { return true; }
    if ((c === '-' && n !== '-' && b !== '-' && n !== '=') || (c === '*' && n !== '=') || (c === '%' && n !== '=') || (c === '/' && n !== '=')) {
      if (endsOperand(prevSig(M, k)) && !'\'"`'.includes(prevSig(M, k))) { return true; }
    }
    if (/\s/.test(c) && /^(instanceof|in)\s/.test(M.slice(k + 1, k + 13)) && endsOperand(prevSig(M, k + 1))) { return true; }
  }
  return false;
}

/* A postfix chain: a root, then .name / ?.name / [..] / (..) segments.
 * null when [s, e) is not one. */
function chain(M, s, e) {
  let k = s;
  let root;
  if (/^new\s/.test(M.slice(k, k + 4))) {
    const m = /^new\s+([A-Za-z_$][\w$.]*)/.exec(M.slice(k, e));
    if (!m) { return null; }
    root = { kind: 'new', name: m[1], s: k, e: k + m[0].length };
    k += m[0].length;
  } else if (IDENT.test(M[k]) && !/[0-9]/.test(M[k])) {
    let j = k; while (j < e && IDENT.test(M[j])) { j++; }
    root = { kind: 'ident', name: M.slice(k, j), s: k, e: j };
    k = j;
  } else if (M[k] === '(' || M[k] === '[') {
    const c = closeOf(M, k);
    if (c < 0 || c >= e) { return null; }
    root = { kind: M[k] === '(' ? 'group' : 'array', s: k, e: c + 1 };
    k = c + 1;
  } else if (M[k] === '`' || M[k] === '\'' || M[k] === '"') {
    let j = k + 1;
    if (M[k] === '`') {
      while (j < e) {
        if (M[j] === '`') { break; }
        if (M[j] === '$' && M[j + 1] === '{') { j = closeOf(M, j + 1) + 1; continue; }
        j++;
      }
    } else { while (j < e && M[j] !== M[k]) { j++; } }
    root = { kind: M[k] === '`' ? 'template' : 'string', s: k, e: j + 1 };
    k = j + 1;
  } else { return null; }
  const segs = [];
  for (;;) {
    let j = nextSigAt(M, k);
    if (j >= e) { k = j; break; }
    let opt = false;
    if (M[j] === '?' && M[j + 1] === '.') { opt = true; j += 2; }
    else if (M[j] === '.') { j++; }
    else if ((M[j] === '(' || M[j] === '[') && j === k) { /* a call or an index right after */ }
    else { break; }
    j = nextSigAt(M, j);
    if (M[j] === '(' || M[j] === '[') {
      const c = closeOf(M, j);
      if (c < 0 || c >= e) { return null; }
      segs.push({ kind: M[j] === '(' ? 'call' : 'index', s: j + 1, e: c });
      k = c + 1;
    } else if (IDENT.test(M[j])) {
      let q = j; while (q < e && IDENT.test(M[q])) { q++; }
      segs.push({ kind: 'member', name: M.slice(j, q), s: j, e: q });
      k = q;
    } else { return null; }
  }
  if (nextSigAt(M, k) < e) { return null; }
  return { root, segs };
}

/* The depth-0 comma-separated pieces of [s, e). */
function args(M, s, e) {
  const out = [];
  let from = s;
  for (const k of tops(M, s, e)) { if (M[k] === ',') { out.push(trim(M, from, k)); from = k + 1; } }
  const last = trim(M, from, e);
  if (last[1] > last[0]) { out.push(last); }
  return out;
}

/* Where an expression that starts at s ends: the first , ; ) ] } at depth 0. */
function exprEnd(M, s) {
  let d = 0;
  for (let k = s; k < M.length; k++) {
    const c = M[k];
    if (OPENERS[c]) { d++; continue; }
    if (CLOSERS[c]) { if (d === 0) { return k; } d--; continue; }
    if (d === 0 && (c === ',' || c === ';')) { return k; }
  }
  return M.length;
}

/* Where the receiver of a method call that ends at `end` starts: walks back
 * over .name, ?.name, (...) and [...] to the value they hang from. */
function receiverStart(M, end) {
  let k = end - 1;
  for (;;) {
    while (k >= 0 && /\s/.test(M[k])) { k--; }
    if (M[k] === ')' || M[k] === ']') {
      const open = openOf(M, k);
      const before = prevSig(M, open);
      // a call or an index hangs from what is before it; a group or an array stands alone
      if (before && (IDENT.test(before) || ')]`\'"'.includes(before)) && !/(^|[^\w$])(return|typeof|await|in|of|new|case)$/.test(M.slice(Math.max(0, open - 8), open).trimEnd())) {
        k = open - 1;
        continue;
      }
      return open;
    }
    let start;
    if (M[k] === '`' || M[k] === '\'' || M[k] === '"') {
      const q = M[k]; k--; while (k >= 0 && M[k] !== q) { k--; }
      start = k;
    } else if (IDENT.test(M[k])) {
      while (k >= 0 && IDENT.test(M[k])) { k--; }
      start = k + 1;
    } else { return k + 1; }
    let j = start - 1; while (j >= 0 && /\s/.test(M[j])) { j--; }
    if (M[j] === '.' && M[j - 1] !== '.') { k = j - 1; if (M[k] === '?') { k--; } continue; }
    return start;
  }
}
const ARRAY_CALLBACK = new Set(['map', 'forEach', 'filter', 'flatMap', 'some', 'every', 'find', 'findIndex', 'findLast', 'sort', 'reduce']);
/* A member whose value is a number or a boolean whatever it is read from. */
const NUMBER_RESULT = new Set(['length', 'size', 'indexOf', 'lastIndexOf', 'findIndex', 'getTime', 'toFixed', 'toPrecision',
  'getFullYear', 'getMonth', 'getDate', 'getDay', 'getHours', 'getMinutes', 'getSeconds', 'getUTCFullYear', 'getUTCMonth',
  'getUTCDate', 'getUTCHours', 'getUTCMinutes', 'localeCompare', 'includes', 'some', 'every', 'has', 'test', 'startsWith',
  'endsWith', 'isArray', 'isInteger', 'isFinite', 'isNaN', 'toISOString', 'toUTCString', 'toDateString', 'toTimeString',
  'toLocaleDateString', 'toLocaleTimeString']);
/* A method whose answer is made of what it is called on (and, for some, of
 * its arguments, which are checked too). */
const SAME_TEXT = new Set(['trim', 'trimStart', 'trimEnd', 'toUpperCase', 'toLowerCase', 'toLocaleUpperCase', 'toLocaleLowerCase',
  'slice', 'substring', 'substr', 'at', 'charAt', 'normalize', 'toString', 'repeat', 'valueOf',
  'filter', 'sort', 'reverse', 'flat', 'pop', 'shift', 'find', 'findLast', 'split', 'toLocaleString', 'toSorted', 'get']);
const WITH_ARGS = new Set(['replace', 'replaceAll', 'concat', 'padStart', 'padEnd']);
/* Names whose value cannot carry markup, whatever they are given. */
const SAFE_ROOTS = /^(Math|Number|parseInt|parseFloat|Boolean|isNaN|isFinite|encodeURIComponent|Date)$/;
/* Names that hold what somebody else typed: the address, storage, the page. */
const OUTSIDE = /^(JSON|location|document|navigator|sessionStorage|localStorage|history|event)$/;

class Unit {
  constructor(file, text, line) {
    this.file = file;
    this.line = line;
    Object.assign(this, scan(text));
    const M = this.mask;
    this.templateAt = new Map(this.templates.map(t => [t.start, t]));
    this.functions = [];
    for (const m of M.matchAll(/\bfunction\b\s*\*?\s*([A-Za-z_$][\w$]*)?\s*\(/g)) {
      const ps = m.index + m[0].length - 1;
      const pe = closeOf(M, ps);
      const bs = nextSigAt(M, pe + 1);
      if (M[bs] !== '{') { continue; }
      this.functions.push({ name: m[1] || this.nameBefore(m.index), params: this.paramNames(ps + 1, pe), s: m.index, bodyS: bs, e: closeOf(M, bs) + 1, block: true });
    }
    for (let k = M.indexOf('=>'); k >= 0; k = M.indexOf('=>', k + 2)) {
      let p = k - 1; while (p >= 0 && /\s/.test(M[p])) { p--; }
      let ps, pe, start;
      if (M[p] === ')') { pe = p; ps = openOf(M, p) + 1; start = ps - 1; }
      else { let q = p; while (q >= 0 && IDENT.test(M[q])) { q--; } ps = q + 1; pe = p + 1; start = ps; }
      let pre = start - 1; while (pre >= 0 && /\s/.test(M[pre])) { pre--; }
      if (M.slice(pre - 4, pre + 1) === 'async') { start = pre - 4; }
      const bs = nextSigAt(M, k + 2);
      let be, block = false;
      if (M[bs] === '{') { be = closeOf(M, bs) + 1; block = true; } else { be = exprEnd(M, bs); }
      this.functions.push({ name: this.nameBefore(start), params: this.paramNames(ps, pe), s: start, bodyS: bs, e: be, block, arrow: true });
    }
    for (const m of M.matchAll(/(^|[,{\n;])\s*(?:async\s+)?([A-Za-z_$][\w$]*)\s*\(/g)) {
      const name = m[2];
      if (/^(if|for|while|switch|catch|function|return|typeof|await|new|with|do|else)$/.test(name)) { continue; }
      const ps = m.index + m[0].length - 1;
      const pe = closeOf(M, ps);
      if (pe < 0) { continue; }
      const bs = nextSigAt(M, pe + 1);
      if (M[bs] !== '{') { continue; }
      const s = m.index + m[1].length;
      if (this.functions.some(f => f.bodyS === bs)) { continue; }
      this.functions.push({ name, params: this.paramNames(ps + 1, pe), s, bodyS: bs, e: closeOf(M, bs) + 1, block: true, method: true });
    }
    this.functions.sort((a, b) => a.s - b.s);
    this.tables = new Set();
    for (const m of M.matchAll(/(?:^|\n)\s*const ([A-Z][A-Z0-9_]*) = \{/g)) {
      const os = m.index + m[0].length - 1;
      if (this.isStringTable(os + 1, closeOf(M, os))) { this.tables.add(m[1]); }
    }
    for (const m of M.matchAll(/(?:^|\n)\s*const ([A-Z][A-Z0-9_]*) = ([A-Z][A-Z0-9_]*);/g)) {
      if (this.tables.has(m[2])) { this.tables.add(m[1]); }
    }
  }
  /* A literal of the page's own words: every value a string, a template
   * with nothing in it, a list of strings, or a function. */
  isLiteral(s, e) {
    const M = this.mask;
    [s, e] = trim(M, s, e);
    const ch = chain(M, s, e);
    if (ch && !ch.segs.length && ch.root.kind === 'string') { return true; }
    if (ch && !ch.segs.length && ch.root.kind === 'template') { return !this.templateAt.get(s).exprs.length; }
    const parts = plusParts(M, s, e);
    return Boolean(parts) && parts.every(([a, b]) => this.isLiteral(a, b));
  }
  isStringTable(s, e) {
    const M = this.mask;
    for (const [ps, pe] of args(M, s, e)) {
      const colon = tops(M, ps, pe).find(k => M[k] === ':');
      if (colon === undefined) {
        // a method: name(...) { ... }
        if (/^(async\s+)?[A-Za-z_$][\w$]*\s*\(/.test(M.slice(ps, pe))) { continue; }
        return false;
      }
      const [vs, ve] = trim(M, colon + 1, pe);
      if (this.isLiteral(vs, ve)) { continue; }
      if (M[vs] === '[' && closeOf(M, vs) === ve - 1 && args(M, vs + 1, ve - 1).every(([a, b]) => this.isLiteral(a, b))) { continue; }
      if (/^(async\s*)?(\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>/.test(M.slice(vs, ve)) || /^function\b/.test(M.slice(vs, ve))) { continue; }
      return false;
    }
    return true;
  }
  nameBefore(start) {
    const before = this.mask.slice(Math.max(0, start - 80), start);
    const m = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?$/.exec(before)
      || /([A-Za-z_$][\w$]*)\s*:\s*(?:async\s*)?$/.exec(before)
      || /(?<![.\w$])([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?$/.exec(before);
    return m ? m[1] : null;
  }
  paramNames(s, e) {
    return args(this.mask, s, e).map(([a, b]) => {
      const t = this.mask.slice(a, b);
      if (/^[{[]/.test(t)) { return { destructured: t.slice(0, closeOf(this.mask, a) - a + 1) }; }
      return { name: (/^(?:\.\.\.)?([A-Za-z_$][\w$]*)/.exec(t) || [])[1] };
    });
  }
  lineOf(pos) { return this.line + (this.code.slice(0, pos).match(/\n/g) || []).length; }
  /* The functions whose body holds pos, innermost first. */
  enclosing(pos) { return this.functions.filter(f => f.bodyS <= pos && pos < f.e).sort((a, b) => b.bodyS - a.bodyS); }
}

/* Append without spreading into a call: a long list would overflow the stack. */
function add(out, list) { for (const x of list) { out.push(x); } return out; }
/* One finding once. */
function dedupe(list) {
  const seen = new Set();
  return list.filter(f => { const id = `${f.file}:${f.line}:${f.expr}:${f.why}`; if (seen.has(id)) { return false; } seen.add(id); return true; });
}

class Analyzer {
  constructor(units, allow) {
    this.units = units;
    this.allow = allow || [];
    this.used = new Set();
    this.memo = new Map();
    this.busy = new Set();
    this.binds = [];
  }
  find(unit, s, e, why) {
    const text = unit.code.slice(s, e).replace(/\s+/g, ' ').trim();
    return [{ file: unit.file, line: unit.lineOf(s), expr: text.length > 140 ? `${text.slice(0, 137)}...` : text, why, trail: this.trail ? this.trail.slice() : undefined }];
  }
  memoed(kind, unit, s, e, fn) {
    const key = `${kind}:${unit.file}:${s}:${e}${this.ctxOf(unit, s)}`;
    if (this.memo.has(key)) { return this.memo.get(key); }
    // A value that depends on itself: what the last pass found for it (none
    // on the first). check() runs passes until nothing changes, so a value is
    // never cleared by the order the pages happen to be read in.
    if (this.busy.has(key)) { return (this.prev && this.prev.get(key)) || []; }
    this.busy.add(key);
    if (this.trail) { this.trail.push(`${kind} ${unit.file}:${unit.lineOf(s)} ${unit.code.slice(s, Math.min(e, s + 60)).replace(/\s+/g, ' ')}`); }
    const out = dedupe(fn());
    if (this.trail) { this.trail.pop(); }
    this.busy.delete(key);
    this.memo.set(key, out);
    return out;
  }

  /* Can the value of [s, e) carry markup that somebody else wrote? [] when it
   * cannot; else the findings that say where it comes from. */
  value(unit, s, e) {
    [s, e] = trim(unit.mask, s, e);
    if (s >= e) { return []; }
    return this.memoed('v', unit, s, e, () => this.valueOf(unit, s, e));
  }
  valueOf(unit, s, e) {
    const M = unit.mask;
    while (M[s] === '(' && closeOf(M, s) === e - 1) { [s, e] = trim(M, s + 1, e - 1); }
    // a function is not text; what it gives back is checked where it is called
    if (this.functionAt(unit, s, e)) { return []; }
    if (/^await\s/.test(M.slice(s, s + 6))) { return this.value(unit, s + 6, e); }
    if (M.startsWith('...', s)) { return this.value(unit, s + 3, e); }
    const t3 = ternary(M, s, e);
    if (t3) { return [...this.value(unit, ...t3[1]), ...this.value(unit, ...t3[2])]; }
    for (const op of ['||', '??']) {
      const parts = splitOn(M, s, e, op);
      if (parts) { return parts.flatMap(([a, b]) => this.value(unit, a, b)); }
    }
    const and = splitOn(M, s, e, '&&');
    if (and) { return this.value(unit, ...and[and.length - 1]); }
    if (numericOp(M, s, e)) { return []; }
    const plus = plusParts(M, s, e);
    if (plus) { return plus.flatMap(([a, b]) => this.value(unit, a, b)); }
    const text = M.slice(s, e);
    if (/^(!|typeof\s|void\s|-(?!-)|\+(?!\+))/.test(text)) { return []; }
    if (/^(true|false|null|undefined|NaN|Infinity)$/.test(text) || /^[0-9.]/.test(text)) { return []; }
    // a function is not text; what it gives back is checked where it is called
    if (this.functionAt(unit, s, e)) { return []; }
    // an object literal: every value in it
    if (M[s] === '{' && closeOf(M, s) === e - 1) { return this.objectValues(unit, s, e); }
    const ch = chain(M, s, e);
    if (!ch) { return this.find(unit, s, e, 'an expression this check cannot read'); }
    return this.chainValue(unit, ch, s, e);
  }

  /* The function written at [s, e), if that span is exactly one. */
  functionAt(unit, s, e) {
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    if (/^async\s/.test(M.slice(s, s + 6))) { s = nextSigAt(M, s + 5); }
    return unit.functions.find(f => f.s === s && (f.e === e || trim(M, f.s, f.e)[1] === e) && !f.method) || null;
  }
  /* Every value of an object literal whose braces are at s and e - 1. With
   * `prop`, only that property's value (none when it is not there and no
   * spread could bring it). */
  objectValues(unit, s, e, prop, fv) {
    const M = unit.mask;
    const out = [];
    for (const [ps, pe] of args(M, s + 1, e - 1)) {
      const val = fv || ((u2, a2, b2) => this.value(u2, a2, b2));
      if (M.startsWith('...', ps)) { add(out, val(unit, ps + 3, pe)); continue; }
      const m = /^(?:(['"])?([A-Za-z_$][\w$]*)\1?|\[)\s*/.exec(M.slice(ps, pe));
      const colon = tops(M, ps, pe).find(k => M[k] === ':');
      if (colon === undefined) {
        if (/^(async\s+)?[A-Za-z_$][\w$]*\s*\(/.test(M.slice(ps, pe))) { continue; }
        if (prop && m && m[2] !== prop) { continue; }
        add(out, val(unit, ps, pe));
        continue;
      }
      if (prop && m && m[2] && unit.code.slice(ps, colon).replace(/['"\s]/g, '') !== prop) { continue; }
      add(out, val(unit, colon + 1, pe));
    }
    return out;
  }
  /* The functions a callee at [s, e) can be: a function written there, a
   * function by that name, or what a parameter or a name was given. null when
   * it cannot be told. */
  callees(unit, s, e, depth) {
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    depth = depth || 0;
    if (depth > 6) { return null; }
    while (M[s] === '(' && closeOf(M, s) === e - 1) { [s, e] = trim(M, s + 1, e - 1); }
    const here = this.functionAt(unit, s, e);
    if (here) { return [{ unit, fn: here }]; }
    const ch = chain(M, s, e);
    if (!ch || ch.root.kind !== 'ident') { return null; }
    if (ch.segs.length === 1 && ch.segs[0].kind === 'call') {
      // a call that gives back a function: what it returns
      const inner = this.callees(unit, ch.root.s, ch.root.e, depth + 1);
      if (!inner) { return null; }
      const out = [];
      for (const g of inner) {
        const rets = this.returnSpans(g.unit, g.fn);
        for (const [a, b] of rets) { const got = this.callees(g.unit, a, b, depth + 1); if (!got) { return null; } add(out, got); }
      }
      return out;
    }
    if (!ch.segs.length) {
      const own = this.functionsNamed(unit, ch.root.name, s);
      if (own.length) { return own; }
      // a name a function was put in
      const n = reName(ch.root.name);
      const holder = unit.enclosing(s).find(f => new RegExp(`(?<![\\w$.])(let|const|var)\\s+${n}\\s*=`).test(M.slice(f.bodyS, f.e)));
      const [hs, he] = holder ? [holder.bodyS, holder.e] : [0, M.length];
      const isParam = unit.enclosing(s).some(f => f.params.some(p => p.name === ch.root.name));
      if (!isParam) {
        const rhs = [...M.slice(hs, he).matchAll(new RegExp(`(?<![\\w$.])${n}\\s*=(?![=>])`, 'g'))].map(m => hs + m.index + m[0].length);
        if (rhs.length) {
          const out = [];
          for (const vs of rhs) { const got = this.callees(unit, vs, exprEnd(M, vs), depth + 1); if (!got) { return null; } add(out, got); }
          return out;
        }
      }
      for (const fn of unit.enclosing(s)) {
        const idx = fn.params.findIndex(p => p.name === ch.root.name);
        if (idx < 0) { continue; }
        if (!fn.name) { return null; }
        const sites = this.callSites(unit, fn);
        if (sites.bare.length || sites.elements.length) { return null; }
        const out = [];
        for (const c of sites.calls) {
          const a = args(c.unit.mask, c.s, c.e)[idx];
          if (!a) { continue; }
          const got = this.callees(c.unit, a[0], a[1], depth + 1);
          if (!got) { return null; }
          add(out, got);
        }
        return out;
      }
      return null;
    }
    const ex = this.exportedCall(unit, { root: ch.root, segs: ch.segs.concat([{ kind: 'call', s: e, e }]) });
    if (ex && ex.fn.fn && ex.at === ch.segs.length - 1) { return [ex.fn]; }
    return null;
  }

  /* A template literal: each ${...} in the HTML context its text gives it. */
  template(unit, t) {
    const out = [];
    for (let i = 0; i < t.exprs.length; i++) { add(out, this.templateExpr(unit, t, i)); }
    return out;
  }
  templateExpr(unit, t, i) {
    const ctx = htmlContext(t.quasis.slice(0, i + 1).join('\u0001'));
    const x = t.exprs[i];
    if (ctx === 'url') { return this.url(unit, x.start, x.end); }
    if (ctx === 'handler') { return this.find(unit, x.start, x.end, 'a value inside an inline event handler'); }
    if (ctx === 'unquoted') { return this.find(unit, x.start, x.end, 'a value in an attribute with no quotes'); }
    return this.value(unit, x.start, x.end);
  }

  chainValue(unit, ch, s, e) {
    const M = unit.mask;
    const { root, segs } = ch;
    if (root.kind === 'string') { return this.methods(unit, segs, s, e, []); }
    if (root.kind === 'template') { return this.methods(unit, segs, s, e, this.template(unit, unit.templateAt.get(root.s)), root); }
    if (root.kind === 'group') { return this.methods(unit, segs, s, e, this.value(unit, root.s + 1, root.e - 1), root); }
    if (root.kind === 'array') { return this.methods(unit, segs, s, e, args(M, root.s + 1, root.e - 1).flatMap(([a, b]) => this.value(unit, a, b)), root); }
    if (root.kind === 'new') {
      if (/^(Map|Set|Array|WeakMap)$/.test(root.name)) {
        const call = segs[0] && segs[0].kind === 'call' ? segs[0] : null;
        const own = call ? args(M, call.s, call.e).flatMap(([a, b]) => this.value(unit, a, b)) : [];
        return this.methods(unit, call ? segs.slice(1) : segs, s, e, own);
      }
      if (/^(Date|Intl\.\w+|URLSearchParams)$/.test(root.name) && root.name !== 'URLSearchParams') { return []; }
      return this.find(unit, s, e, `a value made by new ${root.name}`);
    }
    const name = root.name;
    const first = segs[0];
    if (name === 'esc' && first && first.kind === 'call') { return []; }
    if (SAFE_ROOTS.test(name)) { return []; }
    if (name === 'window' && first && first.kind === 'member' && /^Vmf/.test(first.name)) {
      return this.chainValue(unit, { root: { kind: 'ident', name: first.name, s: first.s, e: first.e }, segs: segs.slice(1) }, s, e);
    }
    // Object.keys/values/entries/assign/fromEntries, Array.from, Promise.resolve/all: made of what they are given
    if (/^(Object|Array|Promise)$/.test(name) && first && first.kind === 'member' && segs[1] && segs[1].kind === 'call') {
      if (/^(keys|values|entries|assign|fromEntries|from|resolve|all|allSettled|of)$/.test(first.name)) {
        return this.methods(unit, segs.slice(2), s, e, args(M, segs[1].s, segs[1].e).flatMap(([a, b]) => this.value(unit, a, b)));
      }
    }
    if (unit.tables.has(name)) {
      return segs.filter(g => g.kind === 'call').flatMap(g => args(M, g.s, g.e).flatMap(([a, b]) => this.value(unit, a, b)));
    }
    if (name === 'String' && first && first.kind === 'call') {
      return this.methods(unit, segs.slice(1), s, e, this.value(unit, first.s, first.e));
    }
    if (OUTSIDE.test(name) || name === 'window') {
      if (segs.some(g => g.kind === 'member' && NUMBER_RESULT.has(g.name))) { return []; }
      return this.find(unit, s, e, `a value read from ${name}`);
    }
    if (first && first.kind === 'call') {
      const fns = this.callees(unit, root.s, root.e);
      if (fns && fns.length) { return this.methods(unit, segs.slice(1), s, e, fns.flatMap(f => this.callWith(f.unit, f.fn, unit, args(M, first.s, first.e), first.s))); }
    }
    const exported = this.exportedCall(unit, ch) || this.importedCall(unit, ch);
    if (exported) {
      const { fn, at } = exported;
      const rest = segs.slice(at + 1);
      if (fn.table) { return rest.filter(g => g.kind === 'call').flatMap(g => args(M, g.s, g.e).flatMap(([a, b]) => this.value(unit, a, b))); }
      if (fn.value) { return this.methods(unit, rest, s, e, this.value(fn.unit, ...fn.value)); }
      if (rest[0] && rest[0].kind === 'call') { return this.methods(unit, rest.slice(1), s, e, this.callWith(fn.unit, fn.fn, unit, args(M, rest[0].s, rest[0].e), rest[0].s)); }
    }
    if (first && first.kind === 'call') {
      return this.find(unit, s, e, 'a call this check cannot follow');
    }
    // name.prop: when the name holds object literals, only that property
    if (first && first.kind === 'member') {
      const got = this.nameProp(unit, name, first.name, root.s, 0);
      if (got) { return this.methods(unit, segs.slice(1), s, e, got, root); }
    }
    return this.methods(unit, segs, s, e, this.nameValue(unit, name, root.s), root);
  }

  /* What name.prop can hold, when every value the name is given is an object
   * literal (or a list of them it loops over): that property of each. null
   * when that cannot be told, and the whole value is checked instead. */
  nameProp(unit, name, prop, pos, depth, fv) {
    if (depth > 4) { return null; }
    const M = unit.mask;
    for (const fn of unit.enclosing(pos)) {
      const idx = fn.params.findIndex(p => p.name === name);
      if (idx >= 0) {
        if (fn.params[idx].destructured) { return null; }
        const open = enclosingOpen(M, fn.s - 1);
        const m = open >= 0 && M[open] === '(' ? /\.(map|forEach|filter|flatMap|some|every|find)\s*$/.exec(M.slice(Math.max(0, open - 30), open)) : null;
        if (m) {
          if (idx !== 0) { return null; }
          const r = open - m[0].length;
          return this.elementProp(unit, receiverStart(M, r), r, prop, depth + 1, fv);
        }
        // a named function: the property of what each caller gives it
        if (!fn.name) { return null; }
        const bound = [...this.binds].reverse().find(b => b.fn === fn && b.unit === unit);
        if (bound) { const a = bound.args[idx]; return a ? this.exprProp(bound.callUnit, a[0], a[1], prop, depth + 1, fv) : []; }
        const sites = this.callSites(unit, fn);
        if (sites.bare.length || (!sites.calls.length && !sites.elements.length)) { return null; }
        const out = [];
        for (const x of sites.elements) { const got = this.elementProp(x.unit, x.s, x.e, prop, depth + 1, fv); if (!got) { return null; } add(out, got); }
        for (const c of sites.calls) {
          const a = args(c.unit.mask, c.s, c.e)[idx];
          if (!a) { continue; }
          const got = this.exprProp(c.unit, a[0], a[1], prop, depth + 1, fv);
          if (!got) { return null; }
          add(out, got);
        }
        return out;
      }
      const d = this.declarations(unit, fn).get(name);
      if (d) { return this.declProp(unit, name, d, fn.bodyS, fn.e, prop, depth, fv); }
    }
    const d = this.declarations(unit, null).get(name);
    return d ? this.declProp(unit, name, d, 0, M.length, prop, depth, fv) : null;
  }
  declProp(unit, name, decls, s, e, prop, depth, fv) {
    // reassigned or filled later: not told here
    if (new RegExp(`(?<![\\w$.])${reName(name)}\\s*(\\+=|=(?![=>])|\\.push\\(|\\[)`).test(unit.mask.slice(s, e).replace(new RegExp(`(?:const|let|var)\\s+${reName(name)}\\s*=`, 'g'), ''))) { return null; }
    const out = [];
    for (const d of decls) {
      let got = null;
      if (d.kind === 'init') { got = this.exprProp(unit, d.s, d.e, prop, depth + 1, fv); }
      else if (d.kind === 'of') { got = this.elementProp(unit, d.s, d.e, prop, depth + 1, fv); }
      if (!got) { return null; }
      add(out, got);
    }
    return out;
  }
  exprProp(unit, s, e, prop, depth, fv) {
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    while (M[s] === '(' && closeOf(M, s) === e - 1) { [s, e] = trim(M, s + 1, e - 1); }
    // nothing there has the property
    if (s >= e || /^(null|undefined|false|true|[0-9.]+)$/.test(M.slice(s, e))) { return []; }
    if (M[s] === '{' && closeOf(M, s) === e - 1) { return this.objectValues(unit, s, e, prop, fv); }
    const t3 = ternary(M, s, e);
    if (t3) { const a = this.exprProp(unit, ...t3[1], prop, depth, fv), b = this.exprProp(unit, ...t3[2], prop, depth, fv); return a && b ? [...a, ...b] : null; }
    for (const op of ['||', '??']) {
      const parts = splitOn(M, s, e, op);
      if (parts) { const got = parts.map(([a, b]) => this.exprProp(unit, a, b, prop, depth, fv)); return got.every(Boolean) ? got.flat() : null; }
    }
    const ch = chain(M, s, e);
    if (ch && ch.root.kind === 'ident' && !ch.segs.length) { return this.nameProp(unit, ch.root.name, prop, s, depth + 1, fv); }
    // f(...): that property of what the function gives back
    if (ch && ch.root.kind === 'ident' && ch.segs.length === 1 && ch.segs[0].kind === 'call' && depth < 6) {
      const fns = this.callees(unit, ch.root.s, ch.root.e);
      if (!fns || !fns.length) { return null; }
      const out = [];
      for (const g of fns) {
        for (const [a, b] of this.returnSpans(g.unit, g.fn)) { const got = this.exprProp(g.unit, a, b, prop, depth + 1, fv); if (!got) { return null; } add(out, got); }
      }
      return out;
    }
    return null;
  }
  elementProp(unit, s, e, prop, depth, fv) {
    // CLAIM-AT-PLAN-1: a bound, as nameProp has. A function that calls itself
    // with its own parameter (renderNextStep(events) on the Migrations page)
    // was followed for ever once a value reached it, and the reader stopped
    // with a stack overflow. Past the bound the value is not told here, and
    // the whole value is checked instead.
    if (depth > 12) { return null; }
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    while (M[s] === '(' && closeOf(M, s) === e - 1) { [s, e] = trim(M, s + 1, e - 1); }
    if (s >= e || /^(null|undefined|false)$/.test(M.slice(s, e))) { return []; }
    const t3 = ternary(M, s, e);
    if (t3) { const a = this.elementProp(unit, ...t3[1], prop, depth, fv), b = this.elementProp(unit, ...t3[2], prop, depth, fv); return a && b ? [...a, ...b] : null; }
    for (const op of ['||', '??']) {
      const parts = splitOn(M, s, e, op);
      if (parts) { const got = parts.map(([a, b]) => this.elementProp(unit, a, b, prop, depth, fv)); return got.every(Boolean) ? got.flat() : null; }
    }
    const ch = chain(M, s, e);
    if (!ch) { return null; }
    // f(...): the elements of what the function gives back
    if (ch.root.kind === 'ident' && ch.segs.length === 1 && ch.segs[0].kind === 'call') {
      const fns = this.callees(unit, ch.root.s, ch.root.e);
      if (!fns || !fns.length) { return null; }
      const out = [];
      for (const g of fns) {
        for (const [a, b] of this.returnSpans(g.unit, g.fn)) { const got = this.elementProp(g.unit, a, b, prop, depth + 1, fv); if (!got) { return null; } add(out, got); }
      }
      return out;
    }
    // .filter(...) / .slice(...) / .sort(...) keep the elements they are given
    let segs = ch.segs;
    while (segs.length >= 2 && segs[segs.length - 1].kind === 'call' && /^(filter|slice|sort|reverse)$/.test(segs[segs.length - 2].name || '')) { segs = segs.slice(0, -2); }
    if (segs.length) { return null; }
    if (ch.root.kind === 'array') {
      const out = [];
      for (const [a, b] of args(M, ch.root.s + 1, ch.root.e - 1)) {
        const got = M.startsWith('...', a) ? this.elementProp(unit, a + 3, b, prop, depth + 1, fv) : this.exprProp(unit, a, b, prop, depth, fv);
        if (!got) { return null; }
        add(out, got);
      }
      return out;
    }
    if (ch.root.kind === 'ident') {
      for (const fn of [...unit.enclosing(s), null]) {
        // a parameter: the list each caller gives it (or names, in an object)
        const nm = ch.root.name;
        const idx = fn ? fn.params.findIndex(p => p.name === nm || (p.destructured && new RegExp(`(?<![\\w$])${reName(nm)}(?![\\w$])`).test(p.destructured))) : -1;
        if (idx >= 0) {
          if (!fn.name) { return null; }
          const named = Boolean(fn.params[idx].destructured);
          const bound = [...this.binds].reverse().find(b => b.fn === fn && b.unit === unit);
          let given;
          if (bound) { given = bound.args[idx] ? [{ unit: bound.callUnit, a: bound.args[idx] }] : []; }
          else {
            const sites = this.callSites(unit, fn);
            if (sites.bare.length || sites.elements.length || !sites.calls.length) { return null; }
            given = sites.calls.map(c => ({ unit: c.unit, a: args(c.unit.mask, c.s, c.e)[idx] })).filter(x => x.a);
          }
          const out = [];
          for (const g of given) {
            let span = g.a;
            if (named) {
              const gm = g.unit.mask;
              if (gm[span[0]] !== '{' || closeOf(gm, span[0]) !== span[1] - 1) { return null; }
              if (args(gm, span[0] + 1, span[1] - 1).some(([x]) => gm.startsWith('...', x))) { return null; }
              const v = objectProp(g.unit, span[0], span[1] - 1, nm);
              if (!v) { continue; }
              span = v;
            }
            const got = this.elementProp(g.unit, span[0], span[1], prop, depth + 1, fv);
            if (!got) { return null; }
            add(out, got);
          }
          return out;
        }
        const d = this.declarations(unit, fn).get(ch.root.name);
        if (!d) { continue; }
        if (d.length !== 1 || d[0].kind !== 'init') { return null; }
        const [bs, be] = fn ? [fn.bodyS, fn.e] : [0, M.length];
        if (new RegExp(`(?<![\\w$.])${reName(ch.root.name)}\\s*(\\+=|=(?![=>])|\\.push\\()`).test(M.slice(bs, be).replace(new RegExp(`(?:const|let|var)\\s+${reName(ch.root.name)}\\s*=`), ''))) { return null; }
        return this.elementProp(unit, d[0].s, d[0].e, prop, depth + 1, fv);
      }
    }
    return null;
  }

  /* const { a, b: c } = window.VmfReport (or VmfHelp): `a(...)` is the
   * exported function of that name. */
  importedCall(unit, ch) {
    const name = ch.root.name;
    const re = new RegExp(`(?:const|let|var)\\s+\\{([^}]*)\\}\\s*=\\s*(?:window\\.)?(Vmf\\w+)\\s*;`, 'g');
    for (const m of unit.mask.matchAll(re)) {
      for (const part of m[1].split(',')) {
        const [from, to] = part.split(':').map(x => x.trim());
        if ((to || from) === name) {
          const r = this.exportedCall(unit, { root: { kind: 'ident', name: m[2] }, segs: [{ kind: 'member', name: from }, ...ch.segs] });
          if (r) { return { ...r, at: r.at - 1 }; }
        }
      }
    }
    return null;
  }

  /* The methods after a value: which keep its text, which make a number. */
  methods(unit, segs, s, e, base, root) {
    const M = unit.mask;
    let out = base;
    for (let i = 0; i < segs.length; i++) {
      const g = segs[i];
      const call = segs[i + 1] && segs[i + 1].kind === 'call' ? segs[i + 1] : null;
      if (g.kind === 'member' && NUMBER_RESULT.has(g.name)) { return []; }
      if (g.kind === 'member' && (g.name === 'map' || g.name === 'flatMap') && call) {
        const fnArg = args(M, call.s, call.e)[0];
        out = fnArg ? this.callbackReturns(unit, fnArg[0], fnArg[1], s) : [];
        i++;
        continue;
      }
      if (g.kind === 'member' && g.name === 'join' && call) {
        const sep = args(M, call.s, call.e)[0];
        out = [...out, ...(sep ? this.value(unit, sep[0], sep[1]) : [])];
        i++;
        continue;
      }
      if (g.kind === 'member' && WITH_ARGS.has(g.name) && call) {
        const a = args(M, call.s, call.e);
        const rest = g.name === 'concat' ? a : a.slice(1);
        out = [...out, ...rest.flatMap(([x, y]) => this.functionAt(unit, x, y) ? this.callbackReturns(unit, x, y, s) : this.value(unit, x, y))];
        i++;
        continue;
      }
      if (g.kind === 'member' && g.name === 'reduce' && call) {
        const a = args(M, call.s, call.e);
        out = [...(a[0] ? this.callbackReturns(unit, a[0][0], a[0][1], s) : []), ...(a[1] ? this.value(unit, a[1][0], a[1][1]) : [])];
        i++;
        continue;
      }
      if (g.kind === 'member' && (g.name === 'then' || g.name === 'catch' || g.name === 'finally') && call) {
        const a = args(M, call.s, call.e);
        if (g.name === 'then') { out = a[0] ? this.callbackReturns(unit, a[0][0], a[0][1], s) : out; }
        else if (g.name === 'catch' && a[0]) { out = [...out, ...this.callbackReturns(unit, a[0][0], a[0][1], s)]; }
        i++;
        continue;
      }
      if (g.kind === 'member' && SAME_TEXT.has(g.name)) { if (call) { i++; } continue; }
      if (g.kind === 'member' && /^(entries|values|keys)$/.test(g.name) && call) { i++; continue; }
      if (g.kind === 'member' && call) {
        // a method this check does not know, on a value it trusts: what it is
        // given must be trusted too
        if (out.length) { return this.find(unit, s, e, 'a call this check cannot follow'); }
        const given = args(M, call.s, call.e).flatMap(([a, b]) => this.functionAt(unit, a, b) ? [] : this.value(unit, a, b));
        if (given.length) { return given; }
        i++;
        continue;
      }
      if (g.kind === 'index' || g.kind === 'member') { continue; }
      if (g.kind === 'call') {
        if (!out.length) { continue; }
        return this.find(unit, s, e, 'a call this check cannot follow');
      }
    }
    void root;
    return out;
  }

  /* The spans of what a function gives back. */
  returnSpans(fu, fn) {
    const M = fu.mask;
    if (!fn.block) { return [[fn.bodyS, fn.e]]; }
    const out = [];
    for (const m of M.slice(fn.bodyS, fn.e).matchAll(/\breturn\b/g)) {
      const at = fn.bodyS + m.index;
      if (fu.enclosing(at)[0] !== fn) { continue; }
      out.push([at + 6, exprEnd(M, at + 6)]);
    }
    return out;
  }

  /* What a function gives back: every return of its own, or the arrow's
   * expression. */
  /* The calls being followed that bind the parameters of a function around
   * pos: part of a memo key, so one call's arguments never answer for another. */
  ctxOf(unit, pos) {
    let sig = '';
    for (const b of this.binds) { if (b.unit === unit && b.fn.bodyS <= pos && pos < b.fn.e) { sig += `#${b.id}`; } }
    return sig;
  }
  /* What a call gives back, with the function's parameters bound to THIS
   * call's arguments - so a builder like card(title, body, inner) is judged
   * by what each caller hands it, not by the worst of all callers. */
  callWith(fu, fn, callUnit, argSpans, at) {
    if (this.binds.length >= 6 || this.binds.some(b => b.fn === fn && b.unit === fu)) { return this.returns(fu, fn); }
    this.binds.push({ id: `${callUnit.file}:${at}`, fn, unit: fu, callUnit, args: argSpans });
    try { return this.returns(fu, fn); } finally { this.binds.pop(); }
  }

  returns(fu, fn) {
    return this.memoed('r', fu, fn.bodyS, fn.e, () => {
      const M = fu.mask;
      if (!fn.block) { return this.value(fu, fn.bodyS, fn.e); }
      const out = [];
      for (const m of M.slice(fn.bodyS, fn.e).matchAll(/\breturn\b/g)) {
        const at = fn.bodyS + m.index;
        if (fu.enclosing(at)[0] !== fn) { continue; }
        add(out, this.value(fu, at + 6, exprEnd(M, at + 6)));
      }
      return out;
    });
  }

  /* A .map callback's answer. */
  callbackReturns(unit, s, e, at) {
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    const fns = this.callees(unit, s, e);
    if (fns && fns.length) { return fns.flatMap(f => this.returns(f.unit, f.fn)); }
    const ch = chain(M, s, e);
    if (ch) {
      const ex = this.exportedCall(unit, { root: ch.root, segs: [...ch.segs] });
      if (ex && ex.fn.fn) { return this.returns(ex.fn.unit, ex.fn.fn); }
    }
    return this.find(unit, s, e, 'a callback this check cannot follow');
  }

  /* The function a name means at pos: the one declared in the nearest scope
   * around pos (a page has several local helpers called `line` or `row`). */
  functionsNamed(unit, name, pos) {
    const all = unit.functions.filter(f => f.name === name && !f.method);
    if (pos === undefined || all.length < 2) { return all.map(fn => ({ unit, fn })); }
    const scopes = [...unit.enclosing(pos), null];
    for (const sc of scopes) {
      const here = all.filter(f => (unit.enclosing(f.s)[0] || null) === sc);
      if (here.length) { return here.map(fn => ({ unit, fn })); }
    }
    return [];
  }

  /* window.VmfHelp = { a, b: c } in another file, and the objects it names. */
  exportedCall(unit, ch) {
    const { root, segs } = ch;
    let u = null, objS = -1, objE = -1;
    for (const other of this.units) {
      const m = new RegExp(`window\\.${reName(root.name)}\\s*=\\s*\\{`).exec(other.mask);
      if (m) { u = other; objS = m.index + m[0].length - 1; objE = closeOf(other.mask, objS); break; }
    }
    if (!u) { return null; }
    for (let i = 0; i < segs.length; i++) {
      const g = segs[i];
      if (g.kind !== 'member') { return null; }
      const val = objectProp(u, objS, objE, g.name);
      if (!val) { return null; }
      const [vs, ve] = trim(u.mask, ...val);
      const text = u.mask.slice(vs, ve);
      if (/^[A-Za-z_$][\w$]*$/.test(text)) {
        const fn = u.functions.find(f => f.name === text && !f.method && u.enclosing(f.s).length <= 1);
        if (fn) { return { fn: { unit: u, fn }, at: i }; }
        if (u.tables.has(text)) { return { fn: { table: true }, at: i }; }
        const decl = new RegExp(`const ${reName(text)} = \\{`).exec(u.mask);
        if (decl) { objS = decl.index + decl[0].length - 1; objE = closeOf(u.mask, objS); continue; }
        return { fn: { unit: u, value: [vs, ve] }, at: i };
      }
      if (u.mask[vs] === '{') { objS = vs; objE = closeOf(u.mask, vs); continue; }
      return { fn: { unit: u, value: [vs, ve] }, at: i };
    }
    return null;
  }

  /* The names a scope declares (const, let, var, catch), with what each is
   * given: an initial value, a list it loops over, or a pattern it is taken
   * out of. A declaration inside a nested function belongs to that function. */
  declarations(unit, fn) {
    this.decls = this.decls || new Map();
    const key = `${unit.file}:${fn ? fn.s : 'top'}`;
    if (this.decls.has(key)) { return this.decls.get(key); }
    const M = unit.mask;
    const [s, e] = fn ? [fn.bodyS, fn.e] : [0, M.length];
    const out = new Map();
    const put = (name, d) => { if (!out.has(name)) { out.set(name, []); } out.get(name).push(d); };
    const mine = (k) => (unit.enclosing(k)[0] || null) === fn;
    for (const m of M.slice(s, e).matchAll(/(?<![\w$.])(const|let|var)\s+/g)) {
      const k = s + m.index;
      if (!mine(k)) { continue; }
      let j = k + m[0].length;
      for (;;) {
        j = nextSigAt(M, j);
        let names;
        if (M[j] === '{' || M[j] === '[') {
          const pe = closeOf(M, j);
          names = [...M.slice(j, pe + 1).matchAll(/(?<![\w$.])([A-Za-z_$][\w$]*)(?![\w$])(?!\s*:)/g)].map(x => x[1]);
          j = pe + 1;
        } else {
          const id = /^[A-Za-z_$][\w$]*/.exec(M.slice(j));
          if (!id) { break; }
          names = [id[0]];
          j += id[0].length;
        }
        const after = nextSigAt(M, j);
        let d = { kind: 'none' };
        if (M[after] === '=' && M[after + 1] !== '=') {
          const ve = exprEnd(M, after + 1);
          d = { kind: 'init', s: after + 1, e: ve };
          j = ve;
        } else if (/^(of|in)\s/.test(M.slice(after, after + 3))) {
          const open = enclosingOpen(M, k - 1);
          d = { kind: M[after] === 'o' ? 'of' : 'in', s: after + 2, e: closeOf(M, open) };
          j = d.e;
        } else { j = after; }
        for (const nm of names) { put(nm, d); }
        if (M[nextSigAt(M, j)] === ',' && d.kind !== 'of' && d.kind !== 'in') { j = nextSigAt(M, j) + 1; continue; }
        break;
      }
    }
    for (const m of M.slice(s, e).matchAll(/\bcatch\s*\(\s*([A-Za-z_$][\w$]*)\s*\)/g)) {
      if (mine(s + m.index)) { put(m[1], { kind: 'caught', s: s + m.index, e: s + m.index + m[0].length }); }
    }
    this.decls.set(key, out);
    return out;
  }

  /* Everything a name is given, where it is visible from pos. */
  nameValue(unit, name, pos) {
    const n = reName(name);
    for (const fn of unit.enclosing(pos)) {
      const idx = fn.params.findIndex(p => p.name === name || (p.destructured && new RegExp(`(?<![\\w$])${n}(?![\\w$])`).test(p.destructured)));
      if (idx >= 0) { return this.paramValue(unit, fn, idx, pos, Boolean(fn.params[idx].destructured)); }
      const d = this.declarations(unit, fn).get(name);
      if (d) { return this.declared(unit, name, d, fn.bodyS, fn.e); }
    }
    const d = this.declarations(unit, null).get(name);
    if (d) { return this.declared(unit, name, d, 0, unit.mask.length); }
    if (unit.functions.some(f => f.name === name)) { return []; }
    return this.find(unit, pos, pos + name.length, 'a name this check cannot trace');
  }

  /* What a declared name holds: its declarations, and every assignment in its
   * scope - name = x, name += x, name.push(x), name.set(k, x), name[k] = x. */
  declared(unit, name, decls, s, e) {
    const M = unit.mask;
    const n = reName(name);
    const out = [];
    for (const d of decls) {
      if (d.kind === 'init' || d.kind === 'of') { add(out, this.value(unit, d.s, d.e)); }
      else if (d.kind === 'in') { add(out, this.value(unit, d.s, d.e)); }
      else if (d.kind === 'caught') { add(out, this.find(unit, d.s, d.e, 'an error caught from a call')); }
    }
    const body = M.slice(s, e);
    for (const m of body.matchAll(new RegExp(`(?<![\\w$.])${n}\\s*(\\+=|\\|\\|=|\\?\\?=|=(?![=>]))`, 'g'))) {
      const at = s + m.index;
      if (/(const|let|var)\s+$/.test(M.slice(Math.max(0, at - 6), at))) { continue; }
      const vs = at + m[0].length;
      add(out, this.value(unit, vs, exprEnd(M, vs)));
    }
    for (const m of body.matchAll(new RegExp(`(?<![\\w$.])${n}\\.(push|unshift|set|add)\\(`, 'g'))) {
      const cs = s + m.index + m[0].length - 1;
      add(out, args(M, cs + 1, closeOf(M, cs)).flatMap(([a, b]) => this.value(unit, a, b)));
    }
    for (const m of body.matchAll(new RegExp(`(?<![\\w$.])${n}\\s*\\[`, 'g'))) {
      const bs = s + m.index + m[0].length - 1;
      const eq = nextSigAt(M, closeOf(M, bs) + 1);
      if (M[eq] === '=' && M[eq + 1] !== '=') { add(out, this.value(unit, eq + 1, exprEnd(M, eq + 1))); }
    }
    return out;
  }
  /* A parameter: an array callback's element, or what every caller passes. */
  paramValue(unit, fn, idx, pos, destructured) {
    const M = unit.mask;
    const open = enclosingOpen(M, fn.s - 1);
    if (open >= 0 && M[open] === '(') {
      const m = /\.(\w+)\s*$/.exec(M.slice(Math.max(0, open - 30), open));
      if (m && ARRAY_CALLBACK.has(m[1])) {
        const r = open - m[0].length;
        const receiver = () => this.value(unit, receiverStart(M, r), r);
        if (m[1] === 'reduce') {
          if (idx === 2) { return []; }
          if (idx === 0) {
            const a = args(M, open + 1, closeOf(M, open));
            return [...this.returns(unit, fn), ...(a[1] ? this.value(unit, a[1][0], a[1][1]) : [])];
          }
          return receiver();
        }
        if (m[1] === 'sort' || idx !== 1) { return receiver(); }
        return [];
      }
    }
    // a call being followed: its own argument
    for (let k = this.binds.length - 1; k >= 0; k--) {
      const b = this.binds[k];
      if (b.fn !== fn || b.unit !== unit) { continue; }
      const a = b.args[idx];
      if (!a) { return []; }
      const prop = destructured ? (/^[A-Za-z_$][\w$]*/.exec(M.slice(pos)) || [])[0] : null;
      const cm = b.callUnit.mask;
      if (prop && cm[a[0]] === '{' && closeOf(cm, a[0]) === a[1] - 1) { return this.objectValues(b.callUnit, a[0], a[1], prop); }
      return this.value(b.callUnit, a[0], a[1]);
    }
    let sites;
    if (fn.name) { sites = this.callSites(unit, fn); }
    else {
      // promise.then(v => ...): v is what the promise gives
      if (open >= 0 && M[open] === '(' && idx === 0) {
        const mt = /\.then\s*$/.exec(M.slice(Math.max(0, open - 10), open));
        if (mt) { const r = open - mt[0].length; return this.value(unit, receiverStart(M, r), r); }
      }
      sites = { calls: [], bare: [], elements: [] };
      this.use(unit, fn.s, fn.e - fn.s, sites, 0);
    }
    const prop = destructured ? (/^[A-Za-z_$][\w$]*/.exec(M.slice(pos)) || [])[0] : null;
    const out = [];
    for (const x of sites.bare) { add(out, this.find(x.unit, x.s, x.e, `${fn.name || 'a callback'} is passed where this check cannot follow it, so what it is given cannot be traced`)); }
    for (const x of sites.elements) { if (idx !== 1) { add(out, this.value(x.unit, x.s, x.e)); } }
    for (const c of sites.calls) {
      const a = args(c.unit.mask, c.s, c.e)[idx];
      if (!a) { continue; }
      const cm = c.unit.mask;
      if (prop && cm[a[0]] === '{' && closeOf(cm, a[0]) === a[1] - 1) { add(out, this.objectValues(c.unit, a[0], a[1], prop)); }
      else { add(out, this.value(c.unit, a[0], a[1])); }
    }
    if (!sites.calls.length && !sites.bare.length && !sites.elements.length) {
      add(out, this.find(unit, pos, pos + 1, `nothing calls ${fn.name} by its name, so what it is given cannot be traced`));
    }
    return out;
  }

  callSites(unit, fn) {
    const key = `${unit.file}:${fn.s}`;
    this.sites = this.sites || new Map();
    if (this.sites.has(key)) { return this.sites.get(key); }
    const out = { calls: [], bare: [], elements: [] };
    this.sites.set(key, out);
    const names = new Set();
    if (/window\.\w+\s*=\s*\{/.test(unit.mask)) {
      for (const m of unit.mask.matchAll(new RegExp(`(?<![\\w$.])([A-Za-z_$][\\w$]*)\\s*:\\s*${reName(fn.name)}(?![\\w$])`, 'g'))) { names.add(m[1]); }
      if (new RegExp(`[{,]\\s*${reName(fn.name)}\\s*[,}]`).test(unit.mask)) { names.add(fn.name); }
    }
    const look = [{ u: unit, re: new RegExp(`(?<![\\w$.])${reName(fn.name)}(?![\\w$])`, 'g'), own: true }];
    for (const nm of names) { for (const u of this.units) { look.push({ u, re: new RegExp(`\\.${reName(nm)}(?![\\w$])`, 'g'), own: false }); } }
    for (const { u, re, own } of look) {
      for (const m of u.mask.matchAll(re)) {
        const at = m.index + (own ? 0 : 1);
        const len = m[0].length - (own ? 0 : 1);
        if (u === unit && at >= fn.s && at < fn.bodyS) { continue; }
        if (own && this.shadowed(u, fn.name, at, fn)) { continue; }
        const before = u.mask.slice(Math.max(0, at - 12), at);
        if (own && (/function\s*\*?\s*$/.test(before) || /(const|let|var)\s+$/.test(before))) { continue; }
        // the name of a property in an object literal, not a use of the function
        const next = u.mask[nextSigAt(u.mask, at + len)];
        const prev = prevSig(u.mask, at);
        if (u.mask[enclosingOpen(u.mask, at - 1)] === '{' && (prev === ',' || prev === '{') && next === ':') { continue; }
        // window.VmfHelp = { name, ... } / { a: name }: the export itself
        if (u === unit && u.mask[enclosingOpen(u.mask, at - 1)] === '{' && (prev === ',' || prev === '{' || prev === ':') && (next === ',' || next === '}')) {
          if (/window\.\w+\s*=\s*$/.test(u.mask.slice(Math.max(0, enclosingOpen(u.mask, at - 1) - 40), enclosingOpen(u.mask, at - 1)))) { continue; }
          if (/(?:const|let|var)\s+\w+\s*=\s*$/.test(u.mask.slice(Math.max(0, enclosingOpen(u.mask, at - 1) - 40), enclosingOpen(u.mask, at - 1)))) { continue; }
        }
        this.use(u, at, len, out, 0);
      }
    }
    return out;
  }

  /* Is `name` at pos another thing of the same name - a parameter or a
   * declaration of a function around pos? */
  shadowed(unit, name, pos, own) {
    const home = own ? (unit.enclosing(own.s)[0] || null) : undefined;
    // a parameter list declares its names
    if (unit.functions.some(f => f !== own && f.s <= pos && pos < f.bodyS)) { return true; }
    for (const fn of unit.enclosing(pos)) {
      if (fn === home) { return false; }
      if (fn.params.some(p => p.name === name || (p.destructured && new RegExp(`(?<![\\w$])${reName(name)}(?![\\w$])`).test(p.destructured)))) { return true; }
      if (this.declarations(unit, fn).has(name)) { return true; }
    }
    return false;
  }

  /* What happens to a function where its name is used at [at, at + len):
   * called there (a call site), handed to an array method (called with each
   * element), handed to a function this check can follow (called wherever
   * that function calls the parameter), or anything else (bare: untraceable). */
  use(u, at, len, out, depth) {
    const M = u.mask;
    const after = nextSigAt(M, at + len);
    if (M[after] === '(') { out.calls.push({ unit: u, s: after + 1, e: closeOf(M, after) }); return; }
    if (M.startsWith('?.(', after)) { out.calls.push({ unit: u, s: after + 3, e: closeOf(M, after + 2) }); return; }
    // VmfHelp.idKey: the whole member expression is what is passed
    if (prevSig(M, at) === '.') { const st = receiverStart(M, at + len); len = at + len - st; at = st; }
    const prev = prevSig(M, at);
    const next = M[after];
    const open = enclosingOpen(M, at - 1);
    if (depth < 4 && open >= 0 && M[open] === '(' && (prev === '(' || prev === ',') && (next === ')' || next === ',')) {
      const mm = /\.(\w+)\s*$/.exec(M.slice(Math.max(0, open - 30), open));
      if (mm && ARRAY_CALLBACK.has(mm[1]) && mm[1] !== 'reduce' && prev === '(') {
        const r = open - mm[0].length;
        out.elements.push({ unit: u, s: receiverStart(M, r), e: r });
        return;
      }
      const k = args(M, open + 1, closeOf(M, open)).findIndex(([a]) => a === at);
      const callee = trim(M, receiverStart(M, open), open);
      const gs = k >= 0 ? this.callees(u, callee[0], callee[1]) : null;
      if (gs && gs.length) {
        let ok = true;
        for (const g of gs) {
          const p = g.fn.params[k];
          if (!p || !p.name) { ok = false; break; }
          const body = g.unit.mask.slice(g.fn.bodyS, g.fn.e);
          for (const m of body.matchAll(new RegExp(`(?<![\\w$.])${reName(p.name)}(?![\\w$])`, 'g'))) {
            const pos = g.fn.bodyS + m.index;
            // a use inside a nested function that has its own parameter by this name is not this one
            const inner = g.unit.enclosing(pos)[0];
            if (inner !== g.fn && inner.params.some(q => q.name === p.name)) { continue; }
            this.use(g.unit, pos, p.name.length, out, depth + 1);
          }
        }
        if (ok) { return; }
      }
    }
    out.bare.push({ unit: u, s: at, e: at + len });
  }  /* A value written into a URL attribute: HTML-safe, and it starts with the
   * app's own address. */
  url(unit, s, e) { return [...this.value(unit, s, e), ...this.urlStart(unit, s, e)]; }

  urlStart(unit, s, e) {
    const M = unit.mask;
    [s, e] = trim(M, s, e);
    if (s >= e) { return []; }
    return this.memoed('u', unit, s, e, () => {
      while (M[s] === '(' && closeOf(M, s) === e - 1) { [s, e] = trim(M, s + 1, e - 1); }
      const t3 = ternary(M, s, e);
      if (t3) { return [...this.urlStart(unit, ...t3[1]), ...this.urlStart(unit, ...t3[2])]; }
      for (const op of ['||', '??']) { const parts = splitOn(M, s, e, op); if (parts) { return parts.flatMap(([a, b]) => this.urlStart(unit, a, b)); } }
      const and = splitOn(M, s, e, '&&');
      if (and) { return this.urlStart(unit, ...and[and.length - 1]); }
      const plus = plusParts(M, s, e);
      if (plus) { return this.urlStart(unit, ...plus[0]); }
      const ch = chain(M, s, e);
      if (!ch) { return this.find(unit, s, e, 'a link whose start this check cannot prove'); }
      const { root, segs } = ch;
      if (root.kind === 'string') { return safeUrlStart(unit.code.slice(root.s + 1, root.e - 1)) ? [] : this.find(unit, s, e, 'a link that does not start with an address of this app'); }
      if (root.kind === 'template') {
        const t = unit.templateAt.get(root.s);
        if (t.quasis[0] && safeUrlStart(t.quasis[0])) { return []; }
        if (!t.quasis[0] && t.exprs.length) { return this.urlStart(unit, t.exprs[0].start, t.exprs[0].end); }
        return this.find(unit, s, e, 'a link that does not start with an address of this app');
      }
      if (root.kind !== 'ident') { return this.find(unit, s, e, 'a link whose start this check cannot prove'); }
      if (root.name === 'esc' && segs[0] && segs[0].kind === 'call') { return this.urlStart(unit, segs[0].s, segs[0].e); }
      if (root.name === 'URL' && segs[0] && segs[0].name === 'createObjectURL') { return []; }
      if (unit.tables.has(root.name) && !segs.some(g => g.kind === 'call')) { return []; }
      if (segs[0] && segs[0].kind === 'call') {
        const fns = this.functionsNamed(unit, root.name, s);
        if (fns.length) { return fns.flatMap(f => this.urlReturns(f.unit, f.fn)); }
      }
      const ex = this.exportedCall(unit, ch);
      if (ex && ex.fn.fn) { return this.urlReturns(ex.fn.unit, ex.fn.fn); }
      if (ex && ex.fn.value) { return this.urlStart(ex.fn.unit, ...ex.fn.value); }
      // item.href where item holds object literals: that property of each
      if (segs.length === 1 && segs[0].kind === 'member') {
        const got = this.nameProp(unit, root.name, segs[0].name, s, 0, (u2, a2, b2) => this.urlStart(u2, a2, b2));
        if (got) { return got; }
      }
      // list[i]: every value put in the list
      if (segs.length === 1 && segs[0].kind === 'index') {
        const n = reName(root.name);
        const scope = unit.enclosing(s).find(g => this.declarations(unit, g).has(root.name));
        const [bs, be] = scope ? [scope.bodyS, scope.e] : [0, M.length];
        const puts = [...M.slice(bs, be).matchAll(new RegExp(`(?<![\\w$.])${n}\\.push\\(`, 'g'))];
        const lit = new RegExp(`(?<![\\w$.])(?:const|let|var)\\s+${n}\\s*=\\s*\\[`).exec(M.slice(bs, be));
        if (lit) {
          const os = bs + lit.index + lit[0].length - 1;
          const out = [];
          for (const [a, b] of args(M, os + 1, closeOf(M, os))) { add(out, this.urlStart(unit, a, b)); }
          for (const m of puts) {
            const cs = bs + m.index + m[0].length - 1;
            for (const [a, b] of args(M, cs + 1, closeOf(M, cs))) { add(out, this.urlStart(unit, a, b)); }
          }
          return out;
        }
      }
      if (!segs.length) {
        for (const fn of unit.enclosing(s)) {
          const idx = fn.params.findIndex(p => p.name === root.name);
          if (idx >= 0 && fn.name) {
            const sites = this.callSites(unit, fn);
            return [...sites.bare.flatMap(x => this.find(x.unit, x.s, x.e, 'a link builder passed as a value')),
              ...sites.calls.flatMap(c => { const a = args(c.unit.mask, c.s, c.e)[idx]; return a ? this.urlStart(c.unit, a[0], a[1]) : []; })];
          }
          if (idx >= 0) { break; }
          const d = new RegExp(`(?<![\\w$.])(?:const|let|var)\\s+${reName(root.name)}\\s*=`).exec(M.slice(fn.bodyS, fn.e));
          if (d) { const vs = fn.bodyS + d.index + d[0].length; return this.urlStart(unit, vs, exprEnd(M, vs)); }
        }
        const d = new RegExp(`(?<![\\w$.])(?:const|let|var)\\s+${reName(root.name)}\\s*=`).exec(M);
        if (d) { const vs = d.index + d[0].length; return this.urlStart(unit, vs, exprEnd(M, vs)); }
      }
      return this.find(unit, s, e, 'a link whose start this check cannot prove');
    });
  }
  urlReturns(fu, fn) {
    const M = fu.mask;
    if (!fn.block) { return this.urlStart(fu, fn.bodyS, fn.e); }
    const out = [];
    for (const m of M.slice(fn.bodyS, fn.e).matchAll(/\breturn\b/g)) {
      const at = fn.bodyS + m.index;
      if (fu.enclosing(at)[0] !== fn) { continue; }
      add(out, this.urlStart(fu, at + 6, exprEnd(M, at + 6)));
    }
    return out;
  }
}

/* A link the app wrote itself: a page of the app, a fragment, a query, a
 * relative path, or https. Never javascript:, data: or any other scheme. */
function safeUrlStart(text) {
  const t = text.trim().toLowerCase();
  // an empty address is this page (about:blank for window.open)
  if (t === '') { return true; }
  if (/^(https:\/\/|#|\?|\.\/)/.test(t)) { return true; }
  if (/^[a-z][a-z0-9+.-]*:/.test(t)) { return false; }
  return /^[a-z0-9_.-]+(\/|\.html\b|$)/.test(t);
}

/* Where a ${...} sits in the markup before it: text, a quoted attribute, a
 * URL attribute, an inline event handler, or an attribute with no quotes.
 * \u0001 stands for an earlier ${...}. */
function htmlContext(before) {
  const lt = before.lastIndexOf('<');
  const gt = before.lastIndexOf('>');
  if (lt < 0 || gt > lt) {
    // a fragment that starts inside a tag: ` title="${x}` - an attribute only
    // when it opens a quoted one
    if (lt < 0 && gt < 0) { return /[\w:-]+\s*=\s*["'][^"']*$/.test(before) ? attrContext(before, true) : 'text'; }
    return 'text';
  }
  return attrContext(before.slice(lt));
}
function attrContext(tag, fragment) {
  const open = /([\w:-]+)\s*=\s*(["'])((?:(?!\2)[^])*)$/.exec(tag);
  if (open) {
    // is that quote really still open? count the quotes after the =
    const attr = open[1].toLowerCase();
    if (/^on/.test(attr)) { return 'handler'; }
    if (/^(href|src|action|formaction|xlink:href|srcdoc|poster)$/.test(attr)) { return open[3].trim() === '' ? 'url' : 'attr'; }
    return 'attr';
  }
  if (!fragment && /(^|\s)[\w:-]+\s*=\s*$/.test(tag)) { return 'unquoted'; }
  return 'text';
}

/* The value of `prop` in the object literal whose braces are at os and oe. */
function objectProp(unit, os, oe, prop) {
  const M = unit.mask;
  for (const [ps, pe] of args(M, os + 1, oe)) {
    const m = /^([A-Za-z_$][\w$]*)\s*(:)?/.exec(M.slice(ps, pe));
    if (!m || m[1] !== prop) { continue; }
    if (m[2]) { return [ps + m[0].length, pe]; }
    return [ps, ps + m[1].length];
  }
  return null;
}

/* ------------------------------------------------------------------ sinks -- */

/* Every place a dashboard file writes into HTML, and what it writes. */
function sinks(unit) {
  const M = unit.mask;
  const out = [];
  for (const t of unit.templates) {
    if (TAG.test(t.quasis.join(''))) { out.push({ kind: 'template', t, s: t.start }); }
  }
  for (const str of unit.strings) {
    if (!TAG.test(str.text)) { continue; }
    const before = prevSig(M, str.start);
    const after = M[nextSigAt(M, str.end)];
    if (before !== '+' && after !== '+') { continue; }
    let s = str.start;
    for (let k = str.start - 1, d = 0; k >= 0; k--) {
      const c = M[k];
      if (CLOSERS[c]) { d++; s = k; continue; }
      if (OPENERS[c]) { if (d === 0) { break; } d--; s = k; continue; }
      if (d === 0 && (c === ',' || c === ';' || isTernaryMark(M, k) || c === ':' || (c === '=' && M[k - 1] !== '=' && M[k - 1] !== '!' && M[k + 1] !== '=') || (c === '|' && M[k - 1] === '|') || (c === '&' && M[k - 1] === '&') || (c === '>' && M[k - 1] === '='))) { break; }
      if (d === 0 && /(^|[^\w$])return$/.test(M.slice(Math.max(0, k - 6), k + 1))) { s = k + 1; break; }
      if (!/\s/.test(c) || d > 0) { s = k; }
    }
    let e = str.end;
    for (let k = str.end, d = 0; k < M.length; k++) {
      const c = M[k];
      if (OPENERS[c]) { d++; e = k + 1; continue; }
      if (CLOSERS[c]) { if (d === 0) { break; } d--; e = k + 1; continue; }
      if (d === 0 && (c === ',' || c === ';' || isTernaryMark(M, k) || c === ':' || (c === '|' && M[k + 1] === '|') || (c === '&' && M[k + 1] === '&') || (c === '?' && M[k + 1] === '?'))) { break; }
      if (!/\s/.test(c) || d > 0) { e = k + 1; }
    }
    out.push({ kind: 'concat', s, e });
  }
  for (const m of M.matchAll(/\.(innerHTML|outerHTML)\s*\+?=(?!=)/g)) {
    const vs = m.index + m[0].length;
    out.push({ kind: m[1], s: vs, e: exprEnd(M, vs) });
  }
  for (const m of M.matchAll(/\.srcdoc\s*=(?!=)/g)) {
    const vs = m.index + m[0].length;
    out.push({ kind: 'srcdoc', s: vs, e: exprEnd(M, vs) });
  }
  for (const m of M.matchAll(/\.(insertAdjacentHTML|write|writeln|createContextualFragment|parseFromString)\s*\(/g)) {
    const cs = m.index + m[0].length - 1;
    const a = args(M, cs + 1, closeOf(M, cs));
    const which = m[1] === 'insertAdjacentHTML' ? a[1] : a[0];
    if (which) { out.push({ kind: m[1], s: which[0], e: which[1] }); }
  }
  for (const m of M.matchAll(/\.(href|src|action)\s*=(?!=)/g)) {
    const vs = m.index + m[0].length;
    out.push({ kind: 'url', s: vs, e: exprEnd(M, vs) });
  }
  for (const m of M.matchAll(/\.(assign|replace|open)\s*\(/g)) {
    const before = M.slice(Math.max(0, m.index - 9), m.index);
    if (!/(location|window)$/.test(before)) { continue; }
    const cs = m.index + m[0].length - 1;
    const a = args(M, cs + 1, closeOf(M, cs))[0];
    if (a) { out.push({ kind: 'url', s: a[0], e: a[1] }); }
  }
  for (const m of M.matchAll(/\.setAttribute\s*\(/g)) {
    const cs = m.index + m[0].length - 1;
    const a = args(M, cs + 1, closeOf(M, cs));
    if (a.length < 2) { continue; }
    const name = unit.code.slice(a[0][0], a[0][1]).replace(/['"`]/g, '').toLowerCase();
    if (/^on/.test(name)) { out.push({ kind: 'handler', s: a[1][0], e: a[1][1] }); }
    else if (name === 'srcdoc') { out.push({ kind: 'srcdoc', s: a[1][0], e: a[1][1] }); }
    else if (/^(href|src|action|formaction)$/.test(name)) { out.push({ kind: 'url', s: a[1][0], e: a[1][1] }); }
  }
  return out;
}

// CSP-INLINE-1: a page's own script is read through its page, not twice.
const FILES = fs.readdirSync(DASH).filter(f => /\.(html|js)$/.test(f) && !/\.min\.js$/.test(f) && !isPageScript(f)).sort();

function unitsOf(files) {
  const units = [];
  for (const f of files) { for (const sc of scriptsOf(f)) { units.push(new Unit(f, sc.text, sc.line)); } }
  return units;
}

/* Run the check. `allow` lists values a person has read and judged safe for
 * a reason this reader cannot see: { file, expr, why }, where expr is the
 * value as the page writes it into the HTML. Returns each value that is
 * written unescaped (file, line, the value, and where its text comes from),
 * and each allowance that matched nothing (a stale one). */
function check(allow, units) {
  units = units || unitsOf(FILES);
  allow = allow || [];
  const all = units.map(u => ({ u, list: sinks(u) }));
  let places = [];
  let prev = null;
  let sig = '';
  let converged = false;
  for (let pass = 0; pass < 12; pass++) {
    const a = new Analyzer(units);
    a.prev = prev;
    places = [];
    for (const { u, list } of all) {
      for (const k of list) {
        if (k.kind === 'template') {
          k.t.exprs.forEach((x, i) => places.push({ u, s: x.start, e: x.end, kind: 'template', got: a.templateExpr(u, k.t, i) }));
        } else {
          let got;
          if (k.kind === 'url') { got = a.urlStart(u, k.s, k.e); }
          else if (k.kind === 'handler') { got = a.find(u, k.s, k.e, 'a value set as an event handler'); }
          else { got = a.value(u, k.s, k.e); }
          places.push({ u, s: k.s, e: k.e, kind: k.kind, got });
        }
      }
    }
    const now = [...a.memo.entries()].map(([k, v]) => `${k}=${v.length}`).sort().join('|');
    if (now === sig) { converged = true; break; }
    sig = now;
    prev = a.memo;
  }
  // Inner first, so a value is named where it is written, not again as part
  // of every larger value around it.
  places.sort((x, y) => (x.e - x.s) - (y.e - y.s));
  const idOf = g => `${g.file}:${g.line}:${g.expr}:${g.why}`;
  const reported = [];
  const findings = [];
  const used = new Set();
  for (const p of places) {
    if (!p.got.length) { continue; }
    const covered = new Set();
    for (const r of reported) {
      if (r.u === p.u && r.s >= p.s && r.e <= p.e) { for (const id of r.ids) { covered.add(id); } }
    }
    const left = p.got.filter(g => !covered.has(idOf(g)));
    reported.push({ u: p.u, s: p.s, e: p.e, ids: new Set(p.got.map(idOf)) });
    if (!left.length) { continue; }
    const expr = p.u.code.slice(p.s, p.e).replace(/\s+/g, ' ').trim();
    const allowance = allow.find(x => x.file === p.u.file && x.expr === expr);
    if (allowance) { used.add(allowance); continue; }
    findings.push({ file: p.u.file, line: p.u.lineOf(p.s), expr: expr.length > 160 ? `${expr.slice(0, 157)}...` : expr, sink: p.kind, from: left });
  }
  findings.sort((x, y) => x.file.localeCompare(y.file) || x.line - y.line);
  return { findings, unused: allow.filter(x => !used.has(x)), sinkCount: places.length, units, converged };
}

/* One line per finding, for a test's failure message. */
function describe(f) {
  const from = f.from.slice(0, 2).map(g => `${g.why}: ${g.file}:${g.line} ${g.expr}`).join('; ');
  return `${f.file}:${f.line} writes ${f.expr} into HTML (${f.sink}) unescaped - ${from}`;
}
module.exports = { scan, scriptsOf, DASH, FILES, check, describe, unitsOf, htmlContext, safeUrlStart, sinks, Unit, Analyzer };

/* `node _html-sinks.js --code-only` prints, for every dashboard script, its
 * text and the code this scanner keeps: OutputEscape.Tests.ps1 holds that to
 * Get-VmfCodeOnly, the scanner every other test uses. */
if (require.main === module && process.argv[2] === '--code-only') {
  const out = [];
  for (const f of FILES) { scriptsOf(f).forEach((sc, i) => out.push({ file: f, index: i, text: sc.text, code: scan(sc.text).code })); }
  process.stdout.write(JSON.stringify(out));
}

