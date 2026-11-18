/* QUOTA-NOCHECK-1: "every size family has enough quota" when nothing was
 * checked.
 *
 * The card offered a Check quota button just below a line that said quota
 * was checked, which was unclear.
 *
 * The card read the run's capacity records. With none - a new plan - nothing
 * was short, so it printed the all-clear. That is what it said when NOTHING
 * had been checked, word for word what it said when every wave passed.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run, liftConst } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const UX = liftConst('waves.html', 'UX');

test('nothing checked and checked-and-fine do not read the same', () => {
  ok(UX.quotaNotChecked, 'there must be words for "nothing has been checked"');
  ok(UX.quotaNotChecked !== UX.quotaNoNeed, 'and they must differ from the all-clear');
  ok(!/enough quota/i.test(UX.quotaNotChecked), 'and must not claim there is enough');
});

test('the card chooses between them on what was actually READ', () => {
  // Painted, not declared - read where the card is built.
  // QUOTA-CHECK-SPINNER-1: the all-clear is the plan-wide sentence, chosen on
  // the rows the records give: no row is "not checked", never "enough".
  const fn = PAGE.slice(PAGE.indexOf('function quotaPlanState'));
  const card = fn.slice(0, fn.indexOf('\n}'));
  ok(/if \(!rows\.length && !waves\.some\(w => kept\(w\)\)\) \{ return \[\{ cls: 'muted', text: UX\.quotaNotChecked \}\]; \}/.test(card),
    'the all-clear must be shown only when a quota was read');
  ok(/UX\.capPlanEnough/.test(card) && /UX\.capPlanShort/.test(card), 'enough, or short');
});

test('a reading with no limit is not a check', () => {
  // The s-suffix listing gap: Azure reported no limit, so nothing was measured.
  const fn = PAGE.slice(PAGE.indexOf('async function loadClaims'));
  const body = fn.slice(0, fn.indexOf('\n}'));
  ok(/quotaChecked = docs\.some\(d => d\.quota && d\.quota\.limit !== null/.test(body),
    'only a reading with a real limit counts as checked');
});

test('a failed read does not leave an earlier "checked" standing', () => {
  const fn = PAGE.slice(PAGE.indexOf('async function loadClaims'));
  const reset = fn.indexOf('quotaChecked = false');
  const read = fn.indexOf('await blobList');
  ok(reset >= 0 && reset < read, 'it must be cleared before anything is read');
});

run('quota-nocheck');
