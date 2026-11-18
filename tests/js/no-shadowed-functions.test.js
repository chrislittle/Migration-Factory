/* ACCESS-HALF-1 found this by accident, which is the only reason it is here.
 *
 * Adding a helper called `scopeReach` to access.html was a near-miss: the file
 * ALREADY had a top-level `scopeReach`, meaning something entirely different -
 * it ranks a mode for the overlap tooling (migrate 2, assess 1). Two
 * top-level declarations with one name share one scope, so the second wins and
 * the first silently stops existing. SCOPE-COVER-1's overlap detection would
 * have started comparing the wrong thing, with no error anywhere.
 *
 * It was caught only because the test harness lifts a function BY NAME and
 * lifted the wrong one. Nothing in the product would have said a word.
 *
 * NESTED functions are not this. Two `onKey` helpers inside two different
 * dialogs in help.js are in separate scopes and are fine. Only declarations at
 * COLUMN 0 share a scope per file, so only those are counted.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const DIR = path.join(__dirname, '..', '..', 'src', 'dashboard');

function topLevelFunctions(src) {
  const seen = new Map();
  for (const m of src.matchAll(/(?:^|\n)(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(/g)) {
    seen.set(m[1], (seen.get(m[1]) || 0) + 1);
  }
  return seen;
}

const FILES = fs.readdirSync(DIR).filter(n => /\.(html|js)$/.test(n));

test('there are dashboard files to read, so this cannot pass by reading nothing', () => {
  ok(FILES.length > 5, `only found ${FILES.length} files`);
});

test('the counter really does count, which a census must prove about itself', () => {
  const twice = topLevelFunctions('function a() {}\nfunction a() {}\nfunction b() {}');
  ok(twice.get('a') === 2, 'two at column 0 must count as two');
  const nested = topLevelFunctions('function a() {\n    function inner() {}\n}\n    function inner() {}');
  ok(!nested.has('inner'), 'an indented declaration is a different scope and is not counted');
});

test('no dashboard file declares the same top-level function name twice', () => {
  const offenders = [];
  for (const name of FILES) {
    const seen = topLevelFunctions(fs.readFileSync(path.join(DIR, name), 'utf8'));
    for (const [fn, n] of seen) {
      if (n > 1) { offenders.push(`${name}: ${fn} declared ${n} times`); }
    }
  }
  ok(offenders.length === 0,
    `a second declaration silently replaces the first: ${offenders.join('; ')}`);
});

run('no-shadowed-functions');
