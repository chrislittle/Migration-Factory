/* PROJ-EMPTY-1: a project that cannot be emptied, and so cannot be deleted.
 *
 * Found on an install: after the assessment was deleted, the migration that
 * had never run stayed, and the project could not be removed.
 *
 * The row read `Assessments 0`, `Migrations 1`, with a Delete button that
 * refused. Three separate things, and the engine's half is RIGHT:
 * `Remove-VmfProject` refuses while work is inside it, because deleting a
 * migration is its own decision about safety copies and rolling that into a
 * button labelled "delete project" is how a record that still knows how to put
 * a machine back gets lost. That does not change.
 *
 * What was wrong is the two halves the person actually touches:
 *
 *   1. THE REFUSAL LED NOWHERE. The page caught "still holds" and replaced it
 *      with "Delete those first" - true, and it does not say where. The page
 *      already knows what is inside and already links those counts one column
 *      away, so the sentence can carry the route.
 *   2. THE DELETE FOR A MIGRATION WAS ON THE WAVE SAFETY-BRAKE TILE. Right
 *      action, correctly gated, in a place nobody looks for a delete. The page
 *      has a run-actions row for exactly this.
 *
 * Together they were a dead end: the row said what was wrong and offered no
 * way to it.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, eq, run, liftConst, liftAll } = require('./_harness');

const dash = (f) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', f));
const PROJECTS = dash('projects.html');
const MIGRATIONS = dash('migrations.html');
const ASSESSMENTS = dash('assessments.html');
const UX = liftConst('projects.html', 'UX');
const AUX = liftConst('assessments.html', 'UX');

test('the refusal says WHAT is inside, not just that something is', () => {
  // "assessments or migrations" is both of them and neither. The page has the
  // two counts in its hand.
  ok(/\{n\}/.test(UX.delHolds), 'the sentence must carry the number');
  ok(!/assessments or migrations/.test(UX.delHolds),
    'it must name what is actually there, not both possibilities');
});

/* PAGE-SCALE-PROJECTS-1: the row is drawn by the shared list in help.js
 * (VmfHelp.listMount); the page gives it the Delete action and its reason as
 * parts. So the row is RUN here - the page's deleteAction, drawn by help.js's
 * own listAction - and the markup read back, not the source grepped. */
const HELP_SRC = dash('help.js');
// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP_SRC.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
const ROW = liftAll('projects.html', ['deleteAction', 'holdsParts', 'holdsNote', 'holdsHtml']);
const DRAW = liftAll('help.js', ['runParse', 'runStorePath', 'runLink', 'listHref', 'listAction', 'listNotePart']);
const realEsc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const AROW = liftAll('assessments.html', ['deleteAction']);
function drawAssessmentDelete(r) {
  globalThis.UX = AUX;
  globalThis.esc = realEsc;
  globalThis.VmfHelp = { listHref: DRAW.listHref };
  return DRAW.listAction(AROW.deleteAction(r));
}
const esc = realEsc;
function drawDelete(p) {
  globalThis.UX = UX;
  globalThis.esc = realEsc;
  globalThis.VmfHelp = { listHref: DRAW.listHref };
  return DRAW.listAction(ROW.deleteAction(p));
}

test('the reason is ON THE ROW, not only in a hover', () => {
  /* THE ACTUAL DEAD END. The Delete button was ALREADY disabled when a
   * project held work, with the reason in a `title` attribute. A hover has no
   * keyboard, no touch and no screen reader path, so what the owner met was a
   * grey button that did nothing and said nothing.
   *
   * The button stays disabled - it truly cannot work, and an enabled one
   * would be a control that can only be refused. The sentence under it has
   * to be visible. */
  const html = drawDelete({ id: 'pay', assessments: 0, migrations: 1 });
  ok(/<button[^>]* disabled>/.test(html), 'the button must still say it cannot work');
  ok(/<div class="muted vmf-note">Delete <a [^>]*>1 migration<\/a> first\.<\/div>/.test(html), 'and the row must carry the reason where it can be read: ' + html);
  ok(!/title=/.test(html), 'the reason cannot be hidden in a hover');
  const empty = drawDelete({ id: 'e', assessments: 0, migrations: 0 });
  ok(!/disabled/.test(empty) && !/vmf-note/.test(empty), 'an empty project: Delete works, and there is nothing to explain');
});

test('and the reason is a link to the work that is blocking it', () => {
  // The counts one column away already link to the filtered list, so the
  // route out is the one already on the row.
  const html = drawDelete({ id: 'pay', assessments: 2, migrations: 1 });
  ok(html.includes('<a href="assessments.html?project=pay">2 assessments</a>'), 'the assessments: ' + html);
  ok(html.includes('<a href="migrations.html?project=pay">1 migration</a>'), 'the migration');
});

test('the row and the refusal of the service cannot disagree', () => {
  // Two spellings of the same fact is how one of them goes stale. The row's
  // reason and the refusal's sentence are built from one function.
  ok(/function holdsParts/.test(PROJECTS), 'the words come from one place');
  const note = PROJECTS.slice(PROJECTS.indexOf('function holdsNote'), PROJECTS.indexOf('function holdsHtml'));
  ok(/holdsParts\(p\)/.test(note) && /UX\.delHolds\b/.test(note), 'the row builds its words from the shared ones');
  const html = PROJECTS.slice(PROJECTS.indexOf('function holdsHtml'), PROJECTS.indexOf('function deleteProject('));
  ok(/holdsNote\(p\)/.test(html), 'and the refusal from the row\'s own parts');
  /* RUN, not only read: the same project gives the same words both ways. */
  globalThis.projects = [{ id: 'pay', assessments: 1, migrations: 2 }];
  const row = drawDelete(globalThis.projects[0]).replace(/^[\s\S]*?<div class="muted vmf-note">/, '').replace(/<\/div>$/, '');
  eq(ROW.holdsHtml('pay'), row, 'the refusal is the row\'s sentence');
});

test('a project id still cannot become markup', () => {
  /* The reason is HTML where it used to be text, and a project id comes from
   * the store. Both the row and the refusal are run with a hostile id. */
  const bad = 'x"><img src=x onerror=alert(1)>';
  const html = drawDelete({ id: bad, assessments: 1, migrations: 1 });
  ok(!/<img/i.test(html), 'the row: ' + html);
  globalThis.projects = [{ id: bad, assessments: 1, migrations: 0 }];
  ok(!/<img/i.test(ROW.holdsHtml(bad)), 'the refusal: ' + ROW.holdsHtml(bad));
});
test('the delete for a migration is a run action, not part of the brake', () => {
  /* It sat inside the KPI tile that reports whether the wave safety brake is
   * on - which is where the halt and resume buttons belong, and they stay.
   * Stopping or deleting the run is not the brake. */
  const kpi = MIGRATIONS.slice(MIGRATIONS.indexOf('Wave safety brake'),
    MIGRATIONS.indexOf('renderRunActions();'));
  ok(!/discard-run-btn/.test(kpi), 'the delete must leave the brake tile');
  ok(!/stop-run-btn/.test(kpi), 'and so must stopping the run');
  ok(/halt-btn/.test(kpi), 'the brake itself stays on the brake');

  const actions = MIGRATIONS.slice(MIGRATIONS.indexOf('function renderRunActions'),
    MIGRATIONS.indexOf('let runAck = null'));
  ok(/discard-run-btn/.test(actions), 'it belongs with the other run actions');
  ok(/stop-run-btn/.test(actions), 'with stopping the run beside it');
  /* AND IT HAS TO BE DRAWN. Found by mutation: dropping the button from the
   * row's markup left its definition sitting in the same function, so a check
   * for the name passed while the page showed no delete anywhere - which is
   * worse than where it started. */
  const paint = actions.slice(actions.indexOf('host.innerHTML'));
  ok(/\$\{lifeBtn\}/.test(paint), 'the button must actually be put on the row');
  ok(/addEventListener/.test(actions.slice(actions.indexOf('discard-run-btn'))),
    'and be wired to something');
});

test('and it is still offered only to somebody who can do it', () => {
  // The brake tile was gated on canOperate(). The run-actions row admits an
  // approver too, so moving the button there without a gate of its own would
  // put a delete in front of somebody the service refuses.
  const actions = MIGRATIONS.slice(MIGRATIONS.indexOf('function renderRunActions'),
    MIGRATIONS.indexOf('let runAck = null'));
  ok(/canOperate\(\)[\s\S]{0,400}?(discard-run-btn|stop-run-btn)/.test(actions),
    'the delete must be behind canOperate()');
});

test('and only one of stopping and deleting is offered at a time', () => {
  // A run still working on machines cannot be deleted - the service refuses
  // it - so offering both is offering one that cannot work.
  const actions = MIGRATIONS.slice(MIGRATIONS.indexOf('function renderRunActions'),
    MIGRATIONS.indexOf('let runAck = null'));
  ok(/runIsWorking\(\)/.test(actions),
    'which one is offered depends on where the run is');
});

test('the guard on an assessment is keyed the way a run is SPELT', () => {
  /* HOW THE ORPHAN WAS MADE, and it is not in this file's headline defect.
   *
   * The Assessments page already refuses to delete an assessment a migration
   * was planned from. It built its map keyed on `fromAssessment`, which holds
   * the BARE run id, and looked it up by `a.id`, which is how the store spells
   * a run: `project/run` for anything inside a project.
   *
   * So INSIDE A PROJECT the two never matched. The map was always empty, the
   * guard never once applied, and the owner deleted an assessment out from
   * under the migration planned from it - which is the migration that then
   * could not be found and kept the project undeletable. */
  const build = ASSESSMENTS.slice(ASSESSMENTS.indexOf('const plannedFrom = new Map()'),
    ASSESSMENTS.indexOf('const landed = []'));
  ok(/VmfRun\.storePath\(/.test(build),
    'the key must be built the way the store spells a run');
  ok(!/plannedFrom\.set\(from,/.test(build),
    'the bare id cannot be the key - it never matches a run in a project');
});

test('and that assessment says why, where it can be read', () => {
  /* Same dead end as the Projects page, one step in: the reason was a hover
   * on a disabled button.
   *
   * It does NOT repeat the migration's name. The Migration column one cell
   * over already shows it as a link, and a run id is long enough that a
   * second copy in the narrowest column wraps into a paragraph - measured in
   * the page, not guessed. The sentence says why the button cannot work; the
   * way out is already on the row. */
  // PAGE-SCALE-ASSESSMENTS-1: the row is the shared list's, so it is RUN -
  // the page's deleteAction, drawn by help.js's own listAction.
  const html = drawAssessmentDelete({ id: 'pay/a1', projectId: 'pay', planned: ['pay/m1'] });
  ok(/disabled/.test(html), 'the button is disabled: ' + html);
  ok(html.includes('class="muted vmf-note"') && html.includes(esc(AUX.delPlannedOne)), 'the row must show the reason, not only the button');
  ok(!/title="/.test(html), 'and it cannot go back to being a hover');
  ok(html.includes('href="migrations.html?run=m1&amp;project=pay"'), 'and the migration in the way is a link to it');
});

test('a reason added to a row can WRAP, or it cannot be read at all', () => {
  /* MEASURED IN THE PAGE, and it is the hover defect in a different costume.
   *
   * Both action cells are `white-space: nowrap` - they hold buttons that must
   * stay on one line - and a block put inside one inherits that. So the
   * sentence became a single unbreakable line, the table grew past its
   * wrapper, and the wrapper is `overflow-x: hidden`: it CLIPS rather than
   * scrolls. 1322px of table in a 1230px box, with the end of the reason
   * unreachable by any means.
   *
   * Which is exactly what the tooltip did. A reason nobody can read is the
   * defect, whatever is hiding it. */
  // PAGE-SCALE-PROJECTS-1: the Projects reason is the shared list's .vmf-note,
  // held to the same two rules in app.css.
  const css = dash('app.css');
  const note = (css.match(/\.vmf-note\s*\{([^}]*)\}/) || [])[1] || '';
  ok(/white-space:\s*normal/.test(note), 'projects.html: the reason must be allowed to wrap');
  ok(/max-width/.test(note), 'projects.html: and be held to the width of its cell');
  ok(drawDelete({ id: 'p', assessments: 1, migrations: 0 }).includes('class="muted vmf-note"'), 'and the Projects reason carries that class');
  ok(drawAssessmentDelete({ id: 'p/a', projectId: 'p', planned: ['p/m'] }).includes('class="muted vmf-note"'), 'and so does the Assessments reason');
});

test('the page still links the migration an assessment was planned into', () => {
  // PAGE-SCALE-ASSESSMENTS-1: the reason under Delete links it, the row's
  // Open goes to it, and the report lists each one. If those links stop, the
  // reason above becomes a dead end again.
  ok(/VmfRun\.link\('migrations\.html', m\)/.test(ASSESSMENTS), 'the report links each migration');
  ok(/page: 'migrations', run: planned\[0\]/.test(ASSESSMENTS), 'the reason links the migration in the way');
});

/* ---- what the row actually DRAWS -------------------------------------- *
 *
 * Everything above reads source text, and source text is how a check comes to
 * pass for the wrong reason - three of the mutations on this work item beat a
 * grep that matched a definition while the value was never painted. So the
 * row is RUN, with the page's own function, and the markup is read back. */
const page = liftAll('migrations.html', ['renderRunActions']);
const str = (n) => {
  const m = MIGRATIONS.match(new RegExp(n + ": *'([^']*)'"));
  if (!m) { throw new Error('could not read UX_ACT.' + n); }
  return m[1];
};
globalThis.UX_ACT = {
  ackBtn: str('ackBtn'),
  stopRun: str('stopRun'), discardRun: str('discardRun'),
};
globalThis.esc = (v) => String(v == null ? '' : v);
globalThis.runAcknowledged = () => true;

function drawActions({ operator = true, approver = false, working = false }) {
  const host = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#run-actions' ? host : { addEventListener: () => {} });
  globalThis.currentRun = 'demolab/migration-1';
  globalThis.canOperate = () => operator;
  globalThis.canApprove = () => approver;
  globalThis.runIsWorking = () => working;

  globalThis.askStopRun = () => {};
  globalThis.askDiscardRun = () => {};
  globalThis.askAcknowledge = () => {};
  // DISCARD-ENGINE-1: the row reads whether the engine is deleting the run.
  globalThis.discardInFlight = null;
  page.renderRunActions();
  return host.innerHTML;
}

test('DRAWN: an operator can delete a run that is not working', () => {
  const html = drawActions({ working: false });
  ok(html.includes(UX_ACT.discardRun), 'the delete must be on the row');
  ok(!html.includes(UX_ACT.stopRun), 'there is nothing to stop');
});

test('DRAWN: a run still working offers to be stopped, not deleted', () => {
  // The record is what knows how to put those machines back.
  const html = drawActions({ working: true });
  ok(html.includes(UX_ACT.stopRun), 'stopping is the action here');
  ok(!html.includes(UX_ACT.discardRun), 'a delete the service would refuse is not offered');
});

test('DRAWN: an approver is offered neither', () => {
  // This row admits an approver, and the service refuses both to them.
  const html = drawActions({ operator: false, approver: true, working: false });
  ok(!html.includes(UX_ACT.discardRun), 'not the delete');
  ok(!html.includes(UX_ACT.stopRun), 'nor stopping');
  // REPORT-AUTO-1: the report button was the one thing left for them here.
  // The engine writes the report now, so an approver is offered an empty row
  // - which is not drawn.
  ok(html === '', 'nothing to draw');
});

run('project-empty');
