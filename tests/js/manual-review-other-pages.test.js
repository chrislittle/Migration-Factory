/* MANUAL-REVIEW-1, area D: the words of the Admin, Overview, Projects,
 * Assessments, Reports pages and of help.js, checked against the product.
 *
 * WHAT WAS WRONG (the review of 2026-11-12, verified again on main 5683bb96):
 *   - The Admin page said the Assess and migrate choice lets the product "stop
 *     and resize" machines. The VMF Migration role also runs scripts in the
 *     machine, deletes disks and snapshots, writes resource locks, makes
 *     on-demand capacity reservations and requests quota. An administrator
 *     grants it from that sentence.
 *   - The Approver and Operator role lines left out what each role does at a
 *     stopped machine and with an assessment.
 *   - The Assessments page put the preparation cards under "Nothing here needs
 *     doing first", and three of them say what a person must do.
 *   - "Nothing is blocked - every machine found can migrate" showed for a scan
 *     that found only machines the product does not move.
 *   - Get help said "ask for help from any page", and four pages cannot make
 *     the file.
 *   - Error words named an "Admin role" (the role is Administrator) and a
 *     product called the Migration Dashboard (it is Migration Factory).
 *
 * The values are read from the pages (liftConst), so a page that goes back to
 * the old words fails here. The Admin sentence is held to the role itself:
 * each kind of action in data/rbac-actions.json must be said.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
// eslint-disable-next-line no-eval
const TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
const ACCESS = liftConst('access.html', 'UX');
const INDEX = liftConst('index.html', 'UX');
const ASSESS = liftConst('assessments.html', 'UX');
const REPORTS = liftConst('reports.html', 'UX');
const REPORT_JS = fs.readFileSync(path.join(DASH, 'assessment-report.js'), 'utf8');
// eslint-disable-next-line no-eval
const T = eval('(' + REPORT_JS.match(/\n {2}const T = (\{[\s\S]*?\n {2}\});/)[1] + ')');
const RBAC = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'rbac-actions.json'), 'utf8'));

test('the Assess and migrate choice says each kind of action the VMF Migration role holds', () => {
  const actions = new Set(RBAC.operations.filter(o => o.role === 'execute').flatMap(o => o.actions));
  // Each kind of action, and the words that must say it. A new kind in the
  // role with no words here fails the last check below.
  const kinds = [
    [/virtualMachines\/(deallocate|powerOff)\/action$/, /\bstop\b/],
    [/virtualMachines\/start\/action$/, /\bstart\b/],
    [/virtualMachines\/write$/, /\bresize\b/],
    [/virtualMachines\/runCommand\/action$/, /\brun its scripts\b/],
    [/networkInterfaces\/write$/, /\bnetwork interfaces\b/],
    [/snapshots\/(write|delete)$/, /\bsnapshots\b/],
    [/disks\/(write|delete)$/, /\bdisks\b/],
    [/\/delete$/, /\bdelete\b/],
    [/locks\/(write|delete)$/, /\bresource locks\b/],
    [/capacityReservations\/write$/, /\bon-demand capacity reservations\b/],
    [/Microsoft\.Quota\/quotas\/write$/, /\bquota increases\b/],
  ];
  for (const [action, words] of kinds) {
    if ([...actions].some(a => action.test(a))) {
      ok(words.test(ACCESS.scopeMigrate), `scopeMigrate says ${words} for ${action}: ${ACCESS.scopeMigrate}`);
    }
  }
  ok(!/may also stop and resize the machines here\.$/.test(ACCESS.scopeMigrate), 'not the old sentence');
});

test('the Approver and Operator lines say what each role does, and what it cannot', () => {
  const [, approver] = ACCESS.roleWords['Vmf.Approver'];
  const [, operator] = ACCESS.roleWords['Vmf.Operator'];
  // FacadeCore: Approve-assessment, plan and wave sign-off, and the decision of
  // a stopped machine take Vmf.Approver (Invoke-VmfFacadeResolve).
  for (const w of [/accept an assessment/, /sign off a plan or a wave/, /accept a decision for a stopped machine/, /Cannot start, pause or stop/]) {
    ok(w.test(approver), `Approver: ${w}`);
  }
  for (const w of [/assess/, /arrange waves/, /start, pause and resume migrations/, /retry or restore machines/, /Cannot sign off or accept a decision/]) {
    ok(w.test(operator), `Operator: ${w}`);
  }
  ok(!/fix runs/.test(operator), 'no "fix runs": it names no action');
});

test('the Admin page says user, the word Microsoft Entra ID uses, not person', () => {
  for (const k of ['colWho', 'addRoleTip', 'noMatch']) {
    ok(!/\bperson|people\b/i.test(ACCESS[k]), `${k}: ${ACCESS[k]}`);
    ok(/\buser\b/i.test(ACCESS[k]), `${k} says user`);
  }
});

test('the Admin page names the two roles by their names, and sends nobody to a command line', () => {
  ok(/VMF Assessment and VMF Migration/.test(ACCESS.scopeWidenPipeline), ACCESS.scopeWidenPipeline);
  ok(!/command line/i.test(ACCESS.scopeConnectRefused), ACCESS.scopeConnectRefused);
  ok(!('scopeWidenPipelineWarn' in ACCESS), 'no sentence for a pipeline the product does not make');
  ok(!/deliberately/.test(ACCESS.scopeNoPerm), ACCESS.scopeNoPerm);
  ok(!/most accounts/.test(ACCESS.scopeMgDeniedWhy), ACCESS.scopeMgDeniedWhy);
  ok(!/Publish the dashboard/.test(ACCESS.scopeRoleMissing), ACCESS.scopeRoleMissing);
  ok(!/minute or two/.test(ACCESS.scopeLagWhy), ACCESS.scopeLagWhy);
});

test('help.js names the product, the Administrator role and a place where Get help can make the file', () => {
  ok(/Migration Factory/.test(TEXT.noRoleBody) && !/Migration Dashboard/.test(TEXT.noRoleBody), TEXT.noRoleBody);
  ok(!/from any page/.test(TEXT.noRun) && /Migrations page/.test(TEXT.noRun), TEXT.noRun);
  ok(!/Admin role/.test(HELP), 'the role is Administrator; Admin is the page');
  ok(!/released reservations/.test(HELP), 'on-demand capacity reservations, by their Azure name');
  ok(!/up to a minute|It may be starting/.test(TEXT.versionServicePending + TEXT.versionServiceUnknown), 'no guessed time or cause');
  ok(!/The usual cause/.test(HELP), 'no guessed cause');
});

test('how long ago is said in words, with 1 in the singular', () => {
  const H = { TEXT };
  // eslint-disable-next-line no-eval
  const countWords = eval('(' + HELP.match(/function countWords\([\s\S]*?\n {2}\}/)[0] + ')');
  // eslint-disable-next-line no-eval
  const agoText = eval('(' + HELP.match(/function agoText\([\s\S]*?\n {2}\}/)[0] + ')');
  globalThis.TEXT = H.TEXT; globalThis.countWords = countWords;
  const now = Date.parse('2026-11-13T12:00:00Z');
  const at = (mins) => new Date(now - mins * 60000).toISOString();
  eq(agoText(at(1), now), '1 minute ago');
  eq(agoText(at(5), now), '5 minutes ago');
  eq(agoText(at(60), now), '1 hour ago');
  eq(agoText(at(150), now), '2 hours ago');
  eq(agoText(at(1440), now), '1 day ago');
  eq(agoText(at(3 * 1440 + 5), now), '3 days ago');
  // The pages of this area use the one rule, not an abbreviation of their own.
  for (const page of ['assessments.js', 'projects.js', 'reports.js', 'index.js', 'access.js']) {
    const src = fs.readFileSync(path.join(DASH, page), 'utf8');
    ok(!/\}(s|m|h|d) ago`/.test(src), `${page} writes no "5m ago" of its own`);
  }
});

test('the Overview says no assessment waits, also when there is none at all', () => {
  eq(INDEX.reviewNone, ASSESS.tileReviewNone, 'the same sentence as the Assessments tile');
});

test('the preparation cards are not said to need nothing first, on either page', () => {
  ok(!/Nothing here needs doing first/.test(ASSESS.willPrepareWhy), ASSESS.willPrepareWhy);
  eq(T.beforeTheyMove, ASSESS.willPrepare, 'one heading for one list, on the Assessments page and in the wizard');
  ok(/Each card says what the product does, and what you do before the move/.test(ASSESS.willPrepareWhy), 'it sends the reader to each card');
});

test('no stop card is not said to mean every machine can migrate', () => {
  for (const s of [ASSESS.nothingBlocked, T.nothingBlocked]) {
    ok(!/every machine/i.test(s), s);
  }
  eq(T.nothingBlocked, ASSESS.nothingBlocked, 'the same words on both');
  eq(T.notEligibleWhy, ASSESS.notEligibleWhy, 'the same words on both');
  ok(!/leaves these machines alone/.test(ASSESS.notEligibleWhy), ASSESS.notEligibleWhy);
});

test('the review card names its own button', () => {
  ok(ASSESS.notReviewedWhy.includes(ASSESS.reviewBtn), ASSESS.notReviewedWhy);
});

test('every subject the engine writes has its own words, so the catch-all guard is never what a person reads', () => {
  // The catch-all (notReadUnknown) stays as a guard: a subject added to the
  // engine with no words must not vanish. This holds each subject the engine
  // writes today to words of its own.
  const src = path.join(REPO, 'src', 'VmMigrationFactory');
  const files = [path.join(src, 'Public', 'Invoke-VmfAssessment.ps1'), path.join(src, 'Private', 'assess', 'SizesNotRead.ps1')];
  const subjects = new Set(files.flatMap(f => [...fs.readFileSync(f, 'utf8').matchAll(/subject\s*=\s*'([A-Za-z]+)'/g)].map(m => m[1])));
  ok(subjects.size >= 3, `the engine subjects were found: ${[...subjects]}`);
  for (const s of subjects) {
    ok(s === 'sizes' || new RegExp(`\\n\\s+${s}:\\s+'`).test(REPORT_JS.match(/const NOT_READ_WORDS = \{[\s\S]*?\n {2}\};/)[0]), `${s} has its own words`);
  }
  ok(!/RETIRED_CODES/.test(REPORT_JS), 'no filter for a code no 1.0 scan writes');
});

test('the Admin page choice is named, not the role, in the sizes-not-read card', () => {
  ok(/give the product Assess access/.test(T.sizesFixPermission), T.sizesFixPermission);
  ok(!/so this failure stayed/.test(T.sizesFixOther), T.sizesFixOther);
});

test('the Reports setup tile says what it holds: migrations with no plan', () => {
  ok(!/Scanned/.test(REPORTS.tSetupHint), REPORTS.tSetupHint);
  for (const k of ['setupOnlyTag', 'tSetupTitle', 'tSetupNone']) {
    ok(!/got past setup/.test(REPORTS[k]), `${k}: ${REPORTS[k]}`);
  }
});

test('the tidy of old assessments says the 30 days and counts what it removed', () => {
  ok(/30 days/.test(ASSESS.tidyNone) && /30 days/.test(ASSESS.tidyFound), 'the age the engine uses');
  ok(!/takes minutes/.test(ASSESS.tidyFound), 'no time nobody measured');
  ok(Array.isArray(ASSESS.tidyDone) && ASSESS.tidyDone.every(s => s.includes('{n}')), 'a count of what was removed');
});

run('manual-review-other-pages');
