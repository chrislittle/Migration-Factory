/* CSP-INLINE-1: the page source the tests read is the page the browser puts
 * together - its markup, with its own script file put back where the page
 * loads it. The twin of tests/unit/_PageSource.ps1, held to the same rule here
 * and in CspInline.Tests.ps1. */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource, isPageScript, DASH } = require('./_page-source');
const { extract, test, eq, ok, run } = require('./_harness');

const PAGES = fs.readdirSync(DASH).filter(f => f.endsWith('.html')).sort();

test('every page loads its own script file, once, and the source puts it back inline', () => {
  ok(PAGES.length >= 8, `only found ${PAGES.length} pages`);
  for (const page of PAGES) {
    const raw = fs.readFileSync(path.join(DASH, page), 'utf8');
    const name = page.replace(/\.html$/, '.js');
    const tag = `<script src="${name}"></script>`;
    eq(raw.split(tag).length - 1, 1, `${page} loads ${name} once`);
    const own = fs.readFileSync(path.join(DASH, name), 'utf8');
    eq(pageSource(page), raw.replace(tag, () => '<script>\n' + own + '</script>'), `${page}: the source is the page with ${name} inline`);
    eq(pageSource(path.join(DASH, page)), pageSource(page), `${page}: a name and a full path read the same`);
  }
});

test('a shared file stays as its tag, and a file that is not a page is read as it is', () => {
  const src = pageSource('wizard.html');
  ok(src.includes('<script src="help.js"></script>'), 'help.js stays a tag');
  ok(!src.includes('<script src="wizard.js"></script>'), 'the page\'s own tag is replaced');
  eq(pageSource('help.js'), fs.readFileSync(path.join(DASH, 'help.js'), 'utf8'), 'a .js file is read as it is');
});

test('the manual\'s page reads the same way', () => {
  const page = path.join(__dirname, '..', '..', 'docs', 'manual', 'index.html');
  const src = pageSource(page);
  ok(/window\.\$docsify = \{/.test(src), 'the docsify settings are in the manual\'s source');
  ok(!src.includes('<script src="index.js"></script>'), 'its own tag is replaced');
});

test('a function a test lifts from a page comes from the page\'s own script', () => {
  ok(/^function closeDrill\(\)/.test(extract('migrations.html', 'closeDrill')), 'closeDrill is lifted from migrations.html');
});

test('a page\'s own script is told from a shared one', () => {
  ok(isPageScript('wizard.js'), 'wizard.js belongs to wizard.html');
  ok(!isPageScript('help.js'), 'help.js is shared');
  ok(!isPageScript('wizard.html'), 'a page is not a script');
});

run('page-source');
