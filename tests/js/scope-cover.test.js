/* SCOPE-COVER-1, 2026-09-19.
 *
 * Asked whether removing a grant on ONE RESOURCE GROUP would scope the tool
 * down without disturbing subscription access. It would not, and the card gave
 * no way to know: a grant at the subscription above it already reached that
 * resource group, so the smaller row added nothing and removing it changed
 * nothing.
 *
 * Role assignments do not narrow one another. Two rows on this card can be two
 * permissions or one permission written twice, and the card said nothing about
 * which. The roles card ON THE SAME PAGE has marked a covered role for months.
 *
 * scopeRowsWithCoverage is pure, so every combination is driven here.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');

const { scopeRowsWithCoverage, scopeCovers, scopeIsUnder } =
  liftAll('access.html', ['scopeRowsWithCoverage', 'scopeCovers', 'scopeIsUnder',
                          'scopeReach', 'scopeNormalize', 'subscriptionIdOf']);

// The two placeholders NoLiveIdentifiers.Tests.ps1 permits in a subscription
// position. Anything else fails that gate, invented or not.
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000';
const RG = `${SUB}/resourceGroups/rg-scan`;
const OTHER = '/subscriptions/11111111-2222-3333-4444-555555555555';
const MG = '/providers/Microsoft.Management/managementGroups/root';

// The MODE a row carries, which is what scopeReach ranks. Deliberately not
// the displayed words: ranking permission by a display string would break the
// day somebody rewords the column.
const MIGRATE = 'migrate';
const ASSESS = 'assess';

const row = (scope, name, mode = MIGRATE, extra = {}) => ({ scope, name, mode, stale: false, ...extra });
const marks = (rows, d) => scopeRowsWithCoverage(rows, d).map(r => `${r.name}:${r.coveredBy || '-'}`).join(' ');

test('a resource group inside a granted subscription is marked, and named', () => {
  const out = scopeRowsWithCoverage([row(SUB, 'Sub One'), row(RG, 'rg-scan')]);
  eq(out.find(r => r.name === 'rg-scan').coveredBy, 'Sub One',
     'the smaller row says which grant already covers it');
  eq(out.find(r => r.name === 'Sub One').coveredBy, undefined,
     'the wider row is not marked by the one inside it');
});

test('a resource group in a DIFFERENT subscription is left alone', () => {
  // The defect this guards: a prefix test that is not anchored would call any
  // resource group covered by any subscription grant.
  eq(marks([row(OTHER, 'Sub Two'), row(RG, 'rg-scan')]), 'Sub Two:- rg-scan:-');
});

test('two subscriptions do not cover each other', () => {
  eq(marks([row(SUB, 'Sub One'), row(OTHER, 'Sub Two')]), 'Sub One:- Sub Two:-');
});

test('a wider place with a NARROWER permission covers nothing', () => {
  // Assess at the subscription, assess and migrate on one resource group: the
  // small row is the only thing that can migrate. It adds a great deal.
  eq(marks([row(SUB, 'Sub One', ASSESS), row(RG, 'rg-scan', MIGRATE)]),
     'Sub One:- rg-scan:-');
});

test('but assess and migrate above covers assess below, because it includes it', () => {
  eq(marks([row(SUB, 'Sub One', MIGRATE), row(RG, 'rg-scan', ASSESS)]),
     'Sub One:- rg-scan:Sub One');
});

test('assess at the SAME place as assess and migrate is already covered too', () => {
  const out = scopeRowsWithCoverage([row(SUB, 'Sub One', MIGRATE), row(SUB, 'Sub One', ASSESS)]);
  eq(out[1].coveredBy, 'Sub One', 'the narrower of the two is marked');
  eq(out[0].coveredBy, undefined, 'and the wider is not');
});

test('the same place with the same permission twice does not mark itself', () => {
  // Azure refuses a duplicate, but a row must never mark ITSELF - that would
  // put the pill on a grant that is the only one there.
  eq(marks([row(SUB, 'Sub One')]), 'Sub One:-');
});

test('a management group covers a subscription only when Azure says so', () => {
  const rows = [row(MG, 'Root group'), row(SUB, 'Sub One')];
  eq(marks(rows), 'Root group:- Sub One:-',
     'with nothing read, a management group proves nothing');
  const known = new Map([[MG.toLowerCase(), new Set([SUB.toLowerCase()])]]);
  eq(marks(rows, known), 'Root group:- Sub One:Root group',
     'and with the descendants read, it does');
});

test('a descendants call that failed leaves the children unmarked', () => {
  // Unknown is not a yes. An empty map is what a failed read passes.
  eq(marks([row(MG, 'Root group'), row(SUB, 'Sub One')], new Map()),
     'Root group:- Sub One:-');
});

test('a resource group under a management group is reached through its subscription', () => {
  const known = new Map([[MG.toLowerCase(), new Set([SUB.toLowerCase()])]]);
  eq(scopeRowsWithCoverage([row(MG, 'Root group'), row(RG, 'rg-scan')], known)
       .find(r => r.name === 'rg-scan').coveredBy, 'Root group');
});

test('a chain names the OUTERMOST grant, not whichever came back first', () => {
  const known = new Map([[MG.toLowerCase(), new Set([SUB.toLowerCase()])]]);
  const out = scopeRowsWithCoverage(
    [row(SUB, 'Sub One'), row(RG, 'rg-scan'), row(MG, 'Root group')], known);
  eq(out.find(r => r.name === 'rg-scan').coveredBy, 'Root group',
     'the top of the chain');
  eq(out.find(r => r.name === 'Sub One').coveredBy, 'Root group');
  eq(out.find(r => r.name === 'Root group').coveredBy, undefined);
});

test('a place that no longer exists keeps its own mark and gains no other', () => {
  const out = scopeRowsWithCoverage([row(SUB, 'Sub One'), row(RG, 'rg-gone', MIGRATE, { stale: true })]);
  eq(out.find(r => r.name === 'rg-gone').coveredBy, undefined,
     'a deleted place is already explained');
});

test('a row with no scope is never marked and never marks', () => {
  eq(marks([row(SUB, 'Sub One'), { name: 'Mystery', mode: MIGRATE, stale: false }]),
     'Sub One:- Mystery:-');
});

test('it survives being handed nothing at all', () => {
  eq(scopeRowsWithCoverage(undefined, undefined).length, 0);
  eq(scopeRowsWithCoverage([], null).length, 0);
});

test('the case Azure happens to return does not hide a grant', () => {
  // Azure is inconsistent about resourceGroups / resourcegroups in an id, and
  // a case-sensitive compare would mark a covered row as uncovered.
  eq(marks([row(SUB.toUpperCase(), 'Sub One'),
            row(`${SUB}/RESOURCEGROUPS/rg-scan`, 'rg-scan')]),
     'Sub One:- rg-scan:Sub One');
});

test('a trailing slash does not hide a grant', () => {
  eq(marks([row(SUB + '/', 'Sub One'), row(RG, 'rg-scan')]), 'Sub One:- rg-scan:Sub One');
});

test('a resource group whose name merely STARTS with another is not covered by it', () => {
  // /resourceGroups/rg-scan must not cover /resourceGroups/rg-scan-two.
  eq(scopeIsUnder(`${SUB}/resourceGroups/rg-scan-two`, RG), false);
  eq(scopeIsUnder(`${RG}/providers/x/y`, RG), true, 'but a thing truly inside it is');
});

test('the page declares the mark and the reason, and shows both', () => {
  const page = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'access.html'));
  ok(/scopeCoveredBy:\s*'Already covered by the grant on \{place\}'/.test(page), 'the mark is declared');
  ok(/scopeCoveredWhy:\s*'A grant on a subscription also applies/.test(page),
     'and the one line saying how a grant applies');
  ok(!/scopeCoveredWhy:\s*'[^']*remove the wider one/.test(page), 'and no advice to remove the wider grant');
  ok(page.includes('UX.scopeCoveredBy.replace'), 'the mark names the place');
  ok(page.includes("shown.some(r => r.coveredBy)"), 'the reason shows only when a row carries it');
});

test('scopeCovers refuses a pair with no scopes rather than calling them equal', () => {
  eq(scopeCovers({ mode: MIGRATE }, { mode: ASSESS }), false);
  eq(scopeCovers(null, row(RG, 'x')), false);
});

run('a scope already covered says so');
