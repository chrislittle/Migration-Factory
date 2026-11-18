/* PLANHASH-1: every gate that agrees to a plan must say WHICH plan.
 *
 * MEASURED by the owner on a 27-machine estate, the day before a demo:
 *
 *     400: the plan version being approved is required
 *
 * THIS IS THE THIRD TIME. ACCEPT-HASH-1 taught the wizard's ACCEPT button to
 * send the plan version. ACCEPT-HASH-2 found the same defect had sat in the
 * Migrations page's accept from the day it was written. Nobody then looked at
 * the button NEXT TO IT, and the wizard's APPROVE has been sending only a note
 * ever since.
 *
 * So this stops testing buttons and tests the RULE. The list of routes comes
 * from the FACADE - the code that does the refusing - so a fourth instance
 * cannot hide behind whoever remembers to add it here.
 *
 * TWO ROUTES END IN /approve AND ONLY ONE NEEDS A PLAN VERSION:
 * `runs/{id}/waves/{wave}/approve` does, `assessments/{id}/approve` does not.
 * The first version of this test matched both and reported a page that was
 * right - a census with a false positive is worse than no census, because the
 * next person turns it off.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const FACADE = path.join(REPO, 'src', 'facade', 'app');

/** Facade routes that refuse a body with no planHash, read from the facade. */
function routesNeedingPlanHash() {
  const out = [];
  for (const dir of fs.readdirSync(FACADE)) {
    const runFile = path.join(FACADE, dir, 'run.ps1');
    const fnFile = path.join(FACADE, dir, 'function.json');
    if (!fs.existsSync(runFile) || !fs.existsSync(fnFile)) { continue; }
    if (!/if \(-not \$body\.planHash\)/.test(fs.readFileSync(runFile, 'utf8'))) { continue; }
    const route = (fs.readFileSync(fnFile, 'utf8').match(/"route"\s*:\s*"([^"]+)"/) || [])[1];
    if (route) { out.push({ dir, route }); }
  }
  return out;
}

/* A route as it appears in page code: the template segments are values there,
 * so they become a loose match while the LITERAL segments stay exact. That is
 * what keeps waves/.../approve apart from assessments/.../approve. */
function routeMatcher(route) {
  const parts = route.split('/').map(seg => (/^\{.*\}$/.test(seg) ? '[^/`\'"]+' : seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  return new RegExp(parts.join('\\/'));
}

/* Every POST call in a page, with the handler it sits in - so a planHash set
 * ten lines ABOVE the call still counts. The first version looked only
 * forwards from the call and reported the accept handler, which sets it on a
 * body object first. */
function postCalls(src) {
  const calls = [];
  const re = /\bapi\w*\(\s*'POST'/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    calls.push({ at: m.index, own: src.slice(m.index, m.index + 200), context: src.slice(Math.max(0, m.index - 1500), m.index + 500) });
  }
  return calls;
}

const NEEDS = routesNeedingPlanHash();

test('the facade refuses without one in more than one place, and this reads it from there', () => {
  ok(NEEDS.length >= 2, `found ${NEEDS.length} routes needing planHash`);
  ok(NEEDS.some(r => /waves\/\{wave\}\/approve/.test(r.route)), 'the wave approve must be among them');
  ok(NEEDS.some(r => /accept-options/.test(r.route)), 'the accept must be among them');
});

test('and an assessment approval is NOT one of them, so this cannot flag a page that is right', () => {
  ok(!NEEDS.some(r => /^assessments\//.test(r.route)), 'assessments/{id}/approve needs no plan version');
});

test('every page that posts to one of them sends the plan version', () => {
  const offenders = [];
  for (const name of fs.readdirSync(DASH).filter(n => n.endsWith('.html'))) {
    const src = pageSource(path.join(DASH, name));
    for (const { route } of NEEDS) {
      const matcher = routeMatcher(route);
      for (const call of postCalls(src)) {
        // The route is in the call's OWN arguments. Searching the 1,500 characters
        // before it blamed PLANRUN-1's Start calls for the sign-off call above them.
        if (!matcher.test(call.own)) { continue; }
        if (!/planHash/.test(call.context)) {
          offenders.push(`${name} posts to ${route} without a plan version`);
        }
      }
    }
  }
  ok(offenders.length === 0, offenders.join('; '));
});

run('plan-hash');
