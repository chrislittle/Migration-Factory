/* OUTPUT-ESCAPE-1: the hostile values every output-escape test feeds to a
 * page, and the one question asked of what the page draws: is any of it live
 * markup?
 *
 * A customer machine names itself, reports its own facts and errors, carries
 * its own tags and extensions; Azure writes its own error text; a person
 * types a note. Any of them can hold these.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');

const TAG = '<img src=x onerror=alert(1)>';
const QUOTE = '" onmouseover="alert(2)';
const SQUOTE = "' onfocus='alert(3)";
const SCRIPT = '<script>alert(4)</script>';
const JSURL = 'javascript:alert(5)';
/* One value holding all of them, for a field that takes any text. */
const ALL = `x${TAG}${QUOTE}${SQUOTE}${SCRIPT}`;

/* The page's OWN encoder, as the page wrote it - never a stand-in, so a test
 * proves the page and not a copy of it. */
function pageEsc(file) {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', file));
  const m = /const esc = (\(v\) => String\(v \?\? ''\)\.replace\([\s\S]*?\}\[c\]\)\)?\));/.exec(src);
  if (!m) { throw new Error(`could not find the encoder in ${file}`); }
  // eslint-disable-next-line no-eval
  return eval(m[1]);
}

/* Throws when html holds a payload as markup: the tag, the script, a quote
 * that ends an attribute, or a javascript: link. */
function inert(html, what) {
  const s = String(html ?? '');
  const say = (why) => { throw new Error(`${what}: ${why}\n${s.slice(0, 600)}`); };
  if (s.includes(TAG)) { say('the <img onerror> tag is live markup'); }
  if (s.includes(SCRIPT)) { say('the <script> element is live markup'); }
  if (s.includes(QUOTE)) { say('a double quote ends an attribute'); }
  for (const t of tags(s)) {
    for (const a of t.attrs) {
      if (/^on/i.test(a.name)) { say(`<${t.name}> carries the handler ${a.name}`); }
      if (/^(href|src|action|formaction)$/i.test(a.name) && /^\s*javascript:/i.test(a.value)) { say(`<${t.name} ${a.name}> is a javascript: link`); }
    }
  }
}

/* The elements of a piece of HTML and their attributes, read the way a
 * browser reads them: a quoted value runs to its own quote. */
function tags(s) {
  const out = [];
  const re = /<([a-zA-Z][\w-]*)/g;
  let m;
  while ((m = re.exec(s))) {
    let i = m.index + m[0].length;
    const attrs = [];
    for (;;) {
      while (i < s.length && /\s/.test(s[i])) { i++; }
      if (i >= s.length || s[i] === '>' || s.startsWith('/>', i)) { break; }
      const n = /^[^\s=>/]+/.exec(s.slice(i));
      if (!n) { i++; continue; }
      i += n[0].length;
      let value = '';
      while (i < s.length && /\s/.test(s[i])) { i++; }
      if (s[i] === '=') {
        i++;
        while (i < s.length && /\s/.test(s[i])) { i++; }
        if (s[i] === '"' || s[i] === '\'') { const q = s[i]; const end = s.indexOf(q, i + 1); value = s.slice(i + 1, end < 0 ? s.length : end); i = end < 0 ? s.length : end + 1; }
        else { const v = /^[^\s>]*/.exec(s.slice(i))[0]; value = v; i += v.length; }
      }
      attrs.push({ name: n[0], value });
    }
    out.push({ name: m[1].toLowerCase(), attrs });
    re.lastIndex = i;
  }
  return out;
}

/* Throws unless the text is on the screen, escaped: a person can still read
 * what the machine was called. */
function shownAsText(html, text, esc, what) {
  if (!String(html).includes(esc(text))) { throw new Error(`${what}: ${esc(text)} is not shown as text`); }
}

module.exports = { TAG, QUOTE, SQUOTE, SCRIPT, JSURL, ALL, pageEsc, inert, shownAsText, tags };
