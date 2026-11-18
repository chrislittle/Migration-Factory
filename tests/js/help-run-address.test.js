/* RUN-ADDR-2, found 2026-09-24 by a sweep for slow reads.
 *
 * The wave editor handed "Get help" the BARE run name. A run inside a project
 * lives at <project>/<run>, so every document the support bundle asked for was
 * read from a folder that does not exist, and the bundle came back empty. The
 * wizard, one page along, already passed the full path.
 *
 * THE CLASS, NOT THE INSTANCE: every page that gives the help menu a reader
 * must also give it the run's full store path - never a variable that the
 * page strips the project off.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const pages = fs.readdirSync(DASH).filter(f => f.endsWith('.html'));
/* Where a page hands help its readers: inline, or (PAGE-LOAD-2, the Migrations
 * page) from a named function a test can run, helpAdapter(). */
const GIVES = /(?:VmfHelp\.install\(\{|function helpAdapter\(\) \{\s*return \{)/;

test('pages that give help a reader are found, so this cannot pass by finding none', () => {
  const withReader = pages.filter(f => new RegExp(GIVES.source + '[\\s\\S]{0,400}readJson:').test(pageSource(path.join(DASH, f))));
  ok(withReader.length >= 3, `found: ${withReader.join(', ')}`);
});

test('each gives the run by its full store path', () => {
  for (const f of pages) {
    const src = pageSource(path.join(DASH, f));
    const m = src.match(new RegExp(GIVES.source + '[\\s\\S]{0,400}?getRunId: \\(\\) => ([^,\\n]+)'));
    if (!m || !/readJson:/.test(src.slice(m.index, m.index + 900))) { continue; }
    ok(!/^runId\b/.test(m[1].trim()), `${f} hands help the bare run name: ${m[1]}`);
  }
});

run('help-run-address');
