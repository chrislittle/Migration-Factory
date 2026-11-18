/* CSP-INLINE-1: a page's source, as the browser puts it together.
 *
 * The dashboard pages, and the manual's index.html, kept their script in one
 * inline block each. The content security policy now refuses inline script
 * (src/dashboard/web.config: script-src 'self'), so each page's script moved
 * to a file with the page's own name: wizard.html loads wizard.js.
 *
 * Most tests read a page and lift a function, a string table or a call out
 * of it. Read alone, the .html no longer holds any of that. So a test reads
 * the page through this: the markup, with the tag that loads the page's own
 * script replaced by that script, inline, where the browser runs it. At the
 * move, the text was the text the page held before, except for what
 * CSP-INLINE-1 changed on purpose: two comment lines in reports.js, and the
 * close-button listener added to migrations.js in place of an onclick=.
 *
 * Only the page's OWN script goes in; the shared files stay as their tags.
 * The twin of tests/unit/_PageSource.ps1, and held to it by
 * page-source.test.js. CspInline.Tests.ps1 reads the RAW page.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');

/** The page's text with its own script inline. `file` is a name in
 *  src/dashboard, or a full path. A file that is not .html is returned as is. */
function pageSource(file) {
  const full = path.isAbsolute(file) ? file : path.join(DASH, file);
  const text = fs.readFileSync(full, 'utf8');
  if (!/\.html?$/i.test(full)) { return text; }
  const name = path.basename(full).replace(/\.html?$/i, '') + '.js';
  const tag = `<script src="${name}"></script>`;
  const at = text.indexOf(tag);
  if (at < 0) { return text; }
  const own = path.join(path.dirname(full), name);
  if (!fs.existsSync(own)) { throw new Error(`${path.basename(full)} loads ${name}, which is not beside it.`); }
  if (text.indexOf(tag, at + tag.length) >= 0) { throw new Error(`${path.basename(full)} loads ${name} twice.`); }
  return text.slice(0, at) + '<script>\n' + fs.readFileSync(own, 'utf8') + '</script>' + text.slice(at + tag.length);
}

/** True for a page's own script (wizard.js beside wizard.html). A check that
 *  reads every file in a folder reads it through its page, never twice. */
function isPageScript(name, dir = DASH) {
  return /\.js$/i.test(name) && fs.existsSync(path.join(dir, name.replace(/\.js$/i, '.html')));
}

module.exports = { pageSource, isPageScript, DASH };
