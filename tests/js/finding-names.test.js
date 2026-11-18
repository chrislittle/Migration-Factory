/* VMNAMES-1: twenty machine names in one grey run-on line.
 *
 * In the assessment report for a 27-machine estate, the machine names ran
 * on as lines of text, which was hard to read.
 *
 * Every finding card ends with the machines it applies to, joined by commas
 * into one monospace paragraph. With two machines that reads fine; with twenty
 * it is a wall, and the whole point of the card is that the reader can see
 * WHICH machines are affected and go and look at them.
 *
 * Each name becomes its own chip, so the eye can count them and find one. And
 * a finding that names more machines than fit stops at twelve behind a control
 * that opens and CLOSES again - rule 11: a thing that opens offers a way back.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'assessment-report.js'));

test('a machine name is its own element, not part of a joined string', () => {
  // THE DEFECT ITSELF: `names.join(', ')` in one div.
  ok(!/vmf-names">\$\{esc\(names\.join/.test(SRC),
    'the plain name list must not be one joined string');
  ok(/vmf-chip/.test(SRC), 'each name needs a chip of its own');
});

test('and the chips are styled by the report, not by the page around it', () => {
  // The report already learned this: it injects its own CSS because a shared
  // renderer that borrows the caller's stylesheet is not shared - the wizard
  // has `.card` and no `.cardbody`, which is what "poor format" meant.
  const css = SRC.slice(SRC.indexOf('const REPORT_CSS'), SRC.indexOf('let styled'));
  ok(/\.vmf-chip\{/.test(css), 'the chip must be styled in the report\'s own CSS');
});

test('a long list stops, and what stops it can be opened AND closed', () => {
  ok(/NAME_LIMIT/.test(SRC), 'a long list must have a limit');
  /* Rule 11. One button with two states is the cheapest correct shape, so
   * both sets of words have to exist - DECLARED, not merely mentioned.
   *
   * Found by mutation: deleting the "Show fewer" line left `T.showFewerNames`
   * being READ two lines below, so a check for the word passed while the
   * button would have opened the list and then offered "undefined" as the way
   * to close it. A test that matches its own subject's reference to a thing is
   * not testing that the thing is there. */
  const decl = SRC.slice(SRC.indexOf('const T = {'), SRC.indexOf('};', SRC.indexOf('const T = {')));
  ok(/showAllNames:/.test(decl) && /showFewerNames:/.test(decl),
    'both sets of words must be declared, not just read');
  const handler = SRC.slice(SRC.indexOf('function wireNames'), SRC.indexOf('function reasonCard'));
  ok(/moreLabel/.test(handler) && /lessLabel/.test(handler),
    'the button must swap between the two sets of words');
  ok(/\.hidden = /.test(handler), 'and the rest of the names must show and hide');
});

test('the excluded machines are chips too, because they are the same thing', () => {
  // Platform-managed machines are listed the same way and were the same wall.
  const excluded = SRC.slice(SRC.indexOf('T.notEligibleWhy'), SRC.indexOf('T.notEligibleWhy') + 400);
  ok(!/excluded\.join/.test(excluded),
    'the excluded list must not be one joined string either');
});

test('and BOTH pages draw that list the same way', () => {
  /* The Assessments page has its own layout for the report, and its
   * platform-managed block was a copy of this file's - the comment word for
   * word, down to the joined string. So the same report read as chips in the
   * wizard and as a run-on line one page away.
   *
   * This file's opening comment is about exactly that: one renderer, two
   * callers, because this codebase has paid repeatedly for a second copy that
   * drifts. The copy was there the whole time. */
  const page = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'assessments.html'));
  ok(!/excluded\.join\(', '\)/.test(page),
    'the Assessments page must not keep its own joined list');
  ok(/chipList/.test(page), 'it must draw the names with the shared renderer');
  ok(/chipList/.test(SRC.slice(SRC.indexOf('window.VmfReport ='))),
    'which means the renderer has to export it');
});

test('the report names only colours the theme actually defines', () => {
  /* THE ONE THE TESTS DID NOT FIND, and the browser did in a second: the chip
   * asked for `var(--text, #101828)`. There is no `--text` in this product's
   * stylesheet - the token for body text is `--ink` - so every chip fell
   * through to the light-mode fallback and drew near-black machine names on a
   * dark card. Nothing errors. Nothing warns. The names are simply not there.
   *
   * This file injects its own CSS on purpose, which is what puts it out of
   * reach of anything that reads the stylesheet. So the check is here: every
   * variable it asks for must be one `app.css` declares.
   */
  const css = SRC.slice(SRC.indexOf('const REPORT_CSS'), SRC.indexOf('let styled'));
  const appCss = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'));
  const declared = new Set((appCss.match(/--[a-z0-9-]+(?=\s*:)/g) || []));
  const asked = [...new Set((css.match(/var\(\s*(--[a-z0-9-]+)/g) || [])
    .map(v => v.replace(/var\(\s*/, '')))];
  ok(asked.length > 3, 'the report must theme itself through variables');
  const missing = asked.filter(v => !declared.has(v));
  ok(missing.length === 0,
    `the stylesheet declares no ${missing.join(', ')} - it will fall back silently`);
});

test('a name is still escaped on its way into a chip', () => {
  /* A machine name comes from the customer's estate, so it is not trusted
   * text. There is exactly ONE place a raw name becomes markup here - the
   * chip - and every list goes through it, so that is where to look.
   *
   * The first shape of this check read every line mentioning a chip and
   * demanded `esc` on each interpolation. It failed on the correct code,
   * because the line that assembles the chips interpolates chips that are
   * already built and already escaped. A check that cannot tell markup from a
   * value is a check that reports on the wrong thing. */
  const fn = SRC.slice(SRC.indexOf('function chip(name)'), SRC.indexOf('function chipList'));
  ok(/\$\{esc\(name\)\}/.test(fn), 'the chip must escape the name it is given');
  ok(!/\$\{name\}/.test(fn), 'and never put the raw one in');
});

run('finding-names');
