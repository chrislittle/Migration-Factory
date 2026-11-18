/* MANUAL-SHOTS-1: the tool that takes the manual's pictures.
 *
 * A picture that does not show what its page says is worse than no picture,
 * and the tool's checks are what stop one being written. So the checks are
 * pure functions, and this runs them: a dialog taller than its window, a box
 * the window could not grow to hold, two pictures with the same bytes, and a
 * name that is not a shot. It also holds the list of shots to its own rules:
 * every shot that acts on a page says what the page must show afterwards,
 * and every picture comes from sample data or from a file the export writes.
 *
 * RUN, not read: the functions are lifted out of tools/manual-shots.js and
 * called. The file starts Edge when it is run, so it is not required.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const SRC = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
const lift = (name) => {
  const m = SRC.match(new RegExp(`(?:^|\\n)function ${name}\\s*\\([\\s\\S]*?\\n\\}`));
  if (!m) { throw new Error(`could not lift ${name}`); }
  return eval(`(${m[0].trim()})`);   // eslint-disable-line no-eval
};
const SHOTS = (() => {
  const m = SRC.match(/\nconst SHOTS = (\[[\s\S]*?\n\]);/);
  if (!m) { throw new Error('could not read SHOTS'); }
  return eval(m[1]);   // eslint-disable-line no-eval
})();
const clipArea = lift('clipArea');
const duplicatePair = lift('duplicatePair');
const selectShots = lift('selectShots');
const throwsWith = (fn, text) => {
  try { fn(); } catch (e) { return String(e.message).includes(text); }
  return false;
};

test('a dialog taller than its window fails, rather than writing a cut-off picture', () => {
  ok(throwsWith(() => clipArea({ x: 470, y: -30, w: 460, h: 961, fixed: true, vh: 900 }, 0, 1400), 'Give the shot a larger height'));
  ok(throwsWith(() => clipArea({ x: 470, y: 10, w: 460, h: 961, fixed: true, vh: 900 }, 0, 1400), 'Give the shot a larger height'));
  // CONFIRM-DIALOG-OUT-OF-VIEW-1: a dialog box now has a height limit and
  // scrolls inside itself, so it always fits its window - and a box with more
  // than it shows is a cut-off picture too.
  ok(throwsWith(() => clipArea({ x: 470, y: 54, w: 460, h: 792, fixed: true, vh: 900, cut: true }, 0, 1400), 'Give the shot a larger height'));
  ok(!throwsWith(() => clipArea({ x: 470, y: 54, w: 460, h: 792, fixed: true, vh: 900, cut: false }, 0, 1400), 'Give the shot a larger height'), 'a box that shows all of it passes');
});

test('a box on the page that the window could not grow to hold fails', () => {
  ok(throwsWith(() => clipArea({ x: 40, y: 3800, w: 900, h: 400, fixed: false, vh: 4000 }, 16, 1400), 'could not grow'));
});

test('a box that fits gives the area with its padding, held to the page and the window', () => {
  eq(JSON.stringify(clipArea({ x: 100.4, y: 200.6, w: 300, h: 100, fixed: false, vh: 900 }, 16, 1400)),
    JSON.stringify({ x: 84, y: 184, width: 332, height: 132 }));
  // At the edge: the padding is cut at the page and the window, never below 0.
  eq(JSON.stringify(clipArea({ x: 5, y: 3, w: 1395, h: 897, fixed: true, vh: 900 }, 16, 1400)),
    JSON.stringify({ x: 0, y: 0, width: 1400, height: 900 }));
});

test('two pictures with the same bytes are named, the later one first', () => {
  eq(JSON.stringify(duplicatePair([['a.png', '1'], ['b.png', '2'], ['c.png', '1']])), JSON.stringify(['c.png', 'a.png']));
  eq(duplicatePair([['a.png', '1'], ['b.png', '2']]), null);
});

test('a run takes every shot, or the named ones, and a name that is not a shot fails', () => {
  eq(selectShots(SHOTS, undefined).length, SHOTS.length);
  eq(JSON.stringify(selectShots(SHOTS, 'report.png, waves.png').map(s => s.file)), JSON.stringify(['waves.png', 'report.png']));
  ok(throwsWith(() => selectShots(SHOTS, 'no-such.png'), 'no shot is named no-such.png'));
});

test('every shot is a distinct picture of sample data, and every act says what it must open', () => {
  const files = SHOTS.map(s => s.file);
  eq(new Set(files).size, files.length, 'no picture is listed twice');
  for (const s of SHOTS) {
    ok(/\.png$/.test(s.file), s.file);
    // The report is not a page: the export writes it from the sample migration.
    ok(/[?&]demo\b/.test(s.url) || s.url === 'manual-sample-report.html', `${s.file} comes from sample data`);
    if (s.act) { ok(Boolean(s.expect), `${s.file} acts on the page, so it says what the page must show afterwards`); }
    if (s.clip) { ok([].concat(s.clip).length <= 2, `${s.file} clips to one element, or from one to another`); }
  }
  const exportScript = fs.readFileSync(path.join(REPO, 'tools', 'Export-VmfManualScreenshots.ps1'), 'utf8');
  ok(exportScript.includes("'manual-sample-report.html'"), 'the export writes the report the shot reads');
  ok(exportScript.includes("'manual-report-look.json'"), 'and the look the record shot reads');
});

test('every picture the tool takes is shown on a page of the manual', () => {
  const manual = path.join(REPO, 'docs', 'manual');
  const pages = [];
  const walk = (dir) => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory() && e.name !== 'vendor') { walk(p); } else if (e.name.endsWith('.md')) { pages.push(fs.readFileSync(p, 'utf8')); }
  } };
  walk(manual);
  const all = pages.join('\n');
  for (const s of SHOTS) { ok(all.includes(`../images/${s.file})`), `${s.file} is shown on a page`); }
});

run('manual-shots');
