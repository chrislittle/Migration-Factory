/* DECIDE-ROLE-1: the wizard drew Accept these settings for everybody.
 *
 * The Run it step drew the button, and Accept all {n} waves, with no role
 * check. The service accepts a wave's settings only from an operator or an
 * administrator, so a viewer or an approver who is not an operator saw a
 * control that could only be refused. The Migrations page already drew its
 * button on canOperate().
 *
 * These RUN the two functions that draw the controls, with the page's own
 * words, and measure what they paint.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftConst, test, ok, eq, run } = require('./_harness');

globalThis.esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.UX = liftConst('wizard.html', 'UX');

const acceptControl = lift('wizard.html', 'acceptControl');
const acceptAllControl = lift('wizard.html', 'acceptAllControl');
const startControl = lift('wizard.html', 'startControl');
const roleAction = lift('wizard.html', 'roleAction');

const HREF = 'waves.html?run=r1#wave=web-pilot';

test('an operator gets the button, for the wave it names, and the link to change them', () => {
  const html = acceptControl('web-pilot', true, true, HREF);
  ok(html.includes('data-accept="web-pilot"'), 'the button names its wave');
  ok(html.includes(UX.acceptBtn), 'it says Accept these settings');
  ok(html.includes(`href="${HREF}"`), 'the link to change them goes to the wave editor');
  ok(!html.includes(UX.acceptNeedsOperator), 'and no reason, because nothing is missing');
});

test('a user without the operator role gets NO button, and is told who accepts them', () => {
  // A viewer, or an approver who is not an operator: canOperate is false.
  const html = acceptControl('web-pilot', true, false, HREF);
  ok(!html.includes('data-accept'), 'no button the service would refuse');
  ok(!html.includes(UX.acceptBtn), 'and not its words either');
  ok(!html.includes('href='), 'the link to change them is the operator\'s too');
  ok(html.includes(UX.acceptNeedsOperator), 'the reason is ON the screen');
});

test('the reason names the role, in the words the service refuses with', () => {
  ok(/operator role/.test(UX.acceptNeedsOperator), 'it names the operator role');
});

test('Accept all {n} waves: offered to an operator with two or more waves left', () => {
  const html = acceptAllControl(3, true);
  ok(html.includes('data-accept-all'), 'the control is there');
  ok(html.includes(UX.acceptAllBtn.replace('{n}', '3')), 'and counts the waves');
  eq(acceptAllControl(1, true), '', 'one wave left has its own button only');
  eq(acceptAllControl(0, true), '', 'none left, nothing to accept');
});

test('and never to a user without the operator role', () => {
  eq(acceptAllControl(3, false), '', 'no bulk control the service would refuse seven times');
});

test('WIZARD-START-ROLE-1: Start the plan, for an operator only, with what is still missing', () => {
  const ready = startControl(true, true, UX.signFirst);
  ok(/id="go5"/.test(ready.button) && !/disabled/.test(ready.button), 'ready: the button, on');
  eq(ready.note, '', 'and nothing to say');
  const waiting = startControl(false, true, UX.signFirst);
  ok(/id="go5"[^>]*disabled/.test(waiting.button), 'not ready: the button, off');
  ok(waiting.note.includes(UX.signFirst), 'and what is missing');
  for (const r of [true, false]) {
    const other = startControl(r, false, UX.signFirst);
    eq(other.button, '', 'no button for a user without the operator role');
    ok(other.note.includes(UX.startNeedsOperator), 'and who starts it, on the screen');
  }
  ok(/operator role/.test(UX.startNeedsOperator), 'it names the operator role');
});

test('WIZARD-ROLES-2: a step action is a button for the role, and its reason for anybody else', () => {
  const yes = roleAction('make', UX.s0Create, true, UX.stepNeedsOperator);
  ok(/<button[^>]*id="make"/.test(yes) && yes.includes(UX.s0Create), 'allowed: the button');
  ok(!yes.includes(UX.stepNeedsOperator), 'and no reason');
  const no = roleAction('make', UX.s0Create, false, UX.stepNeedsOperator);
  ok(!/<button/.test(no) && !/id="make"/.test(no), 'not allowed: no button, and no element a listener would take for it');
  ok(no.includes(UX.stepNeedsOperator) && /id="make-why"/.test(no), 'the reason, in its place');
  ok(/operator role/.test(UX.stepNeedsOperator), 'the operator reason names the role');
  ok(/approver role/.test(UX.reviewNeedsApprover), 'the approver reason names the role');
});

test('WIZARD-ROLES-2: each step draws its action on the role the service asks for', () => {
  // The facade: projects, machines, targets and engine/plan need an operator
  // or an administrator (canOperate); assessments/approve needs an approver or
  // an administrator (canApprove).
  const fs = require('fs');
  const pagePath = require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html');
  const page = require('./_page-source').pageSource(pagePath);
  const want = [
    ['make', 'UX.s0Create', 'canOperate', 'UX.stepNeedsOperator'],
    ['m-continue', 'UX.mContinue', 'canOperate', 'UX.stepNeedsOperator'],
    ['t-save', 'UX.tSave', 'canOperate', 'UX.stepNeedsOperator'],
    ['go3', 'UX.s3Go', 'canOperate', 'UX.stepNeedsOperator'],
    ['rev', 'UX.aReviewBtn', 'canApprove', 'UX.reviewNeedsApprover'],
  ];
  for (const [id, label, role, why] of want) {
    ok(page.includes(`roleAction('${id}', ${label}, ${role}, ${why})`), `${id} is drawn on ${role}`);
    ok(!new RegExp(`<button[^>]*id="${id}"`).test(page), `and ${id} has no button of its own`);
    ok(page.includes(`$('#${id}')?.addEventListener`), `and its listener allows it to be absent`);
  }
});
test('and the Run it step draws its controls with these two, on the role it read', () => {
  // The two functions above are the rule; this is only that renderStep5 still
  // asks them, with the page's own canOperate, rather than drawing its own.
  const fs = require('fs');
  const path = require('path');
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  const from = src.indexOf('function renderStep5(');
  const body = src.slice(from, src.indexOf('\n}\n', from));
  ok(/acceptControl\(w, isNext, canOperate, /.test(body), 'each wave asks acceptControl');
  ok(/acceptAllControl\(outstanding\.length, canOperate\)/.test(body), 'the bulk row asks acceptAllControl');
  ok(!/data-accept=/.test(body), 'and no accept button is drawn there by hand');
});

run('wizard-accept-role');
