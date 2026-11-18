/* NAV-HOVER-1, 2026-09-25: on the Migrations page, "Assess an estate" and
 * "Refresh now" sat on the navigation bar with the ordinary button style - the
 * bar's own blue in the light theme - so they read as plain text and did not
 * change on hover the way the menu items beside them do.
 *
 * THE CLASS: every button or link in any page's top bar that is not a menu
 * item uses .navbtn, the style made for sitting on the bar in every theme.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const pages = fs.readdirSync(DASH).filter(f => f.endsWith('.html'));

test('the pages have top bars to check, so this cannot pass by finding none', () => {
  const withHeader = pages.filter(f => /<header[\s\S]*?<\/header>/.test(pageSource(path.join(DASH, f))));
  ok(withHeader.length >= 5, `found: ${withHeader.join(', ')}`);
});

test('every button in a top bar uses the navigation-bar style', () => {
  const wrong = [];
  for (const f of pages) {
    const header = (pageSource(path.join(DASH, f)).match(/<header[\s\S]*?<\/header>/) || [''])[0];
    for (const m of header.matchAll(/<(button|a)\b[^>]*class="([^"]*)"/g)) {
      const cls = m[2].split(/\s+/);
      // The run picker's own button carries "current"; menu links are built
      // by help.js into the empty <nav>, not written here.
      if (cls.includes('navbtn') || cls.includes('current')) { continue; }
      wrong.push(`${f}: <${m[1]} class="${m[2]}">`);
    }
  }
  ok(wrong.length === 0, `not in the navigation-bar style: ${wrong.join('; ')}`);
});

run('header-buttons');
