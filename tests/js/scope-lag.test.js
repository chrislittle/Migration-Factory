/* SCOPE-LAG-1, 2026-09-19. A subscription added on the Admin page took about
 * two minutes of refreshes to show, which confused the user.
 *
 * The page was not slow. Azure's roleAssignments LIST is eventually consistent
 * - a grant made seconds ago is absent from it for a minute or two - and the
 * page asked that list while throwing away the only authoritative answer it
 * had: the PUT that creates the assignment returns 201 WITH THE CREATED
 * OBJECT.
 *
 * The same lag hides a REMOVAL, which is worse. A row that lingers for two
 * minutes reads as a removal that did not happen, against the standing ruling
 * that a removal must remove.
 *
 * scopeRowsWithLag is pure, so every combination is driven here rather than
 * asserted about the source.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');

// ACCESS-LAG-WORDS-1: a record names every assignment it covers, read by
// scopeLagIds, so the two are lifted together.
const { scopeRowsWithLag } = liftAll('access.html', ['scopeRowsWithLag', 'scopeLagIds']);

const listed = (id, name) => ({ id, name, level: 'subscription', what: 'Assess and migrate', stale: false });
const added = (id, name) => ({
  action: 'added', id, atMs: Date.now(),
  row: { name, level: 'subscription', what: 'Assess and migrate', stale: false },
});
const removed = (id) => ({ action: 'removed', id, atMs: Date.now() });
const ids = (rows) => rows.map(r => r.id).sort();

test('with nothing pending, it shows exactly what Azure listed', () => {
  const out = scopeRowsWithLag([listed('/a', 'Sub A'), listed('/b', 'Sub B')], []);
  eq(ids(out.rows).join(','), '/a,/b', 'both listed rows');
  eq(out.keep.length, 0, 'nothing to remember');
});

test('a grant Azure has not listed yet still appears, marked as just added', () => {
  const out = scopeRowsWithLag([listed('/a', 'Sub A')], [added('/new', 'Sub New')]);
  eq(ids(out.rows).join(','), '/a,/new', 'the new grant is shown at once');
  const fresh = out.rows.find(r => r.id === '/new');
  eq(fresh.justAdded, true, 'marked, so the row is explicable');
  eq(fresh.name, 'Sub New', 'and named');
  eq(out.keep.map(k => k.id).join(','), '/new', 'still remembered for the next reload');
});

test('and loses its mark the moment Azure lists it, but is NOT forgotten', () => {
  // LAG-FLAP-1. The mark goes, because the row is Azure's now. The RECORD
  // stays until it expires: eventual consistency is not monotonic, and a later
  // read can reach an older replica that has not caught up yet.
  const out = scopeRowsWithLag(
    [listed('/a', 'Sub A'), listed('/new', 'Sub New')], [added('/new', 'Sub New')]);
  eq(out.rows.filter(r => r.id === '/new').length, 1, 'never doubled');
  eq(out.rows.find(r => r.id === '/new').justAdded, undefined,
     'unmarked, because Azure is the one saying it now');
  eq(out.keep.map(k => k.id).join(','), '/new', 'still remembered, in case Azure says otherwise again');
  eq(out.acting.length, 0, 'but it is not changing anything on screen');
});

test('a removal Azure still lists is hidden, because the removal happened', () => {
  const out = scopeRowsWithLag([listed('/a', 'Sub A'), listed('/b', 'Sub B')], [removed('/b')]);
  eq(ids(out.rows).join(','), '/a', 'the removed row is gone immediately');
  eq(out.keep.map(k => k.id).join(','), '/b', 'remembered until Azure agrees');
});

test('and is kept once Azure stops listing it, because Azure may say it again', () => {
  // THE DEFECT THIS ITEM EXISTS FOR, measured in the product: this record was
  // dropped here as "Azure caught up". A later read reached an older replica,
  // the row came back, and nothing was left to hide it.
  const out = scopeRowsWithLag([listed('/a', 'Sub A')], [removed('/b')]);
  eq(ids(out.rows).join(','), '/a', 'unchanged');
  eq(out.keep.map(k => k.id).join(','), '/b', 'the record survives one quiet read');
  eq(out.acting.length, 0, 'it is hiding nothing right now, so nothing is explained');
});

test('and it hides the row AGAIN when a later read brings it back', () => {
  // The whole point, in one case: gone, then back, then hidden again.
  const pending = [removed('/b')];
  const quiet = scopeRowsWithLag([listed('/a', 'Sub A')], pending);
  eq(ids(quiet.rows).join(','), '/a');
  const flap = scopeRowsWithLag([listed('/a', 'Sub A'), listed('/b', 'Sub B')], quiet.keep);
  eq(ids(flap.rows).join(','), '/a', 'the older replica does not put it back');
  eq(flap.acting.length, 1, 'and the page says why a row is missing');
});

test('an add and a remove in flight at once are both honoured', () => {
  const out = scopeRowsWithLag(
    [listed('/a', 'Sub A'), listed('/b', 'Sub B')],
    [added('/new', 'Sub New'), removed('/b')]);
  eq(ids(out.rows).join(','), '/a,/new', 'one added, one taken away');
  eq(out.keep.map(k => k.id).sort().join(','), '/b,/new', 'both still remembered');
  eq(out.acting.length, 2, 'and both are changing what is on screen');
});

test('removing something that was only just added takes it straight back off', () => {
  // Add, change your mind, remove - all inside the lag window. The add record
  // is still there, and must not put the row back.
  const out = scopeRowsWithLag([], [added('/new', 'Sub New'), removed('/new')]);
  eq(out.rows.length, 0, 'a scope removed after being added is not shown');
  eq(out.keep.map(k => k.action).join(','), 'removed',
     'and the removal alone is remembered - it says everything the pair said');
});

test('an empty list with nothing pending shows nothing, not a phantom row', () => {
  const out = scopeRowsWithLag([], []);
  eq(out.rows.length, 0, 'no rows');
  eq(out.keep.length, 0, 'no records');
});

test('it survives being handed nothing at all', () => {
  const out = scopeRowsWithLag(undefined, undefined);
  eq(out.rows.length, 0, 'no rows');
  eq(out.keep.length, 0, 'no records');
});

test('the reason is shown for what is happening NOW, not for what is remembered', () => {
  // A record kept to its cap must not leave the explanation under a settled
  // table for ten minutes, explaining a lag that is over.
  const page = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'access.html'));
  ok(page.includes('merged.acting.length ?'), 'the line follows acting');
  ok(!page.includes('merged.keep.length ?'), 'not what is merely remembered');
});

test('the page shows the reason a row can be ahead of Azure', () => {
  // A row that appears before Azure repeats it needs one sentence saying why,
  // or it looks like the page inventing access.
  const page = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'access.html'));
  // MANUAL-REVIEW-1: no time nobody measured.
  ok(/scopeLagWhy:\s*'[^']*Azure can take some time to list a change/.test(page),
     'the explanation is declared');
  ok(page.includes('UX.scopeLagWhy'), 'and shown');
  ok(page.includes('merged.acting.length ?'), 'only while something is pending');
});

run('access list shows what you just did');
