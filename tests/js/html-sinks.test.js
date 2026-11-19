/* OUTPUT-ESCAPE-1: no text from a customer machine or from Azure can run as
 * script in a dashboard page.
 *
 * Every page escapes text through one encoder, esc(), or writes it with
 * textContent. Security passes on single changes found that true where they
 * looked; nothing looked at every page, and no test failed when a new place
 * wrote such text into HTML without the encoder. The content security policy
 * allowed inline script until CSP-INLINE-1, so a missed escape was not caught
 * by the browser either.
 *
 * READ, then RUN. _html-sinks.js reads the code of every page (comments do not
 * count: its scanner is the one in tests/unit/_CodeOnly.ps1, and
 * HtmlSinks.Tests.ps1 proves the two agree on every file) and follows each
 * value a page writes into HTML back to where it comes from. This file holds
 * the reader to hostile shapes, then holds the dashboard to it.
 * tests/js/output-escape.test.js RUNS the pages' own render functions with
 * hostile values.
 */
'use strict';
const { test, eq, ok, run } = require('./_harness');
const h = require('./_html-sinks');

/* One small page, read by the same reader. */
function findingsOf(src) {
  return h.check([], [new h.Unit('t.html', src, 1)]).findings;
}
const ESC = "const esc = (v) => String(v ?? '').replace(/[&<>\"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c]));\n";
const UX = "const UX = { title: 'Title', count: (n) => `${n} machines` };\n";

// ---------- the scanner ----------

test('the scanner removes comments and keeps strings, regular expressions and template code', () => {
  const s = h.scan("const a = 'x // not a comment'; // trailing note\nconst r = /[\"']/g; /* gone */ const t = `<b>${a /* in code */}</b>`;");
  ok(s.code.includes("'x // not a comment'"), 'a marker inside a string stays');
  ok(!s.code.includes('trailing note'), 'a trailing comment goes');
  ok(s.code.includes('/["\']/g'), 'a regular expression with a quote in it stays whole');
  ok(!s.code.includes('gone') && !s.code.includes('in code'), 'block comments go, inside an interpolation too');
  eq(s.templates.length, 1, 'one template literal');
  eq(s.templates[0].exprs.length, 1, 'with one ${...}');
  eq(s.code.slice(s.templates[0].exprs[0].start, s.templates[0].exprs[0].end).trim(), 'a', 'whose code is the name');
});

test('the scanner finds a template inside a template, and the code of each', () => {
  const s = h.scan('const x = `<ul>${list.map(i => `<li>${i.name}</li>`).join("")}</ul>`;');
  eq(s.templates.length, 2, 'two templates');
  const inner = s.templates.find(t => t.quasis[0] === '<li>');
  ok(inner, 'the inner one');
  eq(s.code.slice(inner.exprs[0].start, inner.exprs[0].end), 'i.name', 'its value');
});

// ---------- where in the markup a value sits ----------

test('the context of a value: text, attribute, link, inline handler, no quotes', () => {
  eq(h.htmlContext('<td>'), 'text', 'between tags');
  eq(h.htmlContext('<td title="'), 'attr', 'in a quoted attribute');
  eq(h.htmlContext('<a href="'), 'url', 'at the start of a link');
  eq(h.htmlContext('<a href="page.html?run='), 'attr', 'later in a link the app started');
  eq(h.htmlContext('<b onclick="go(\''), 'handler', 'in an inline event handler');
  eq(h.htmlContext('<td class='), 'unquoted', 'in an attribute with no quotes');
  eq(h.htmlContext('run='), 'text', 'a query string is not markup');
});

test('a link must start with an address of this app', () => {
  for (const good of ['wizard.html?run=1', 'https://learn.microsoft.com/', '#', '', 'manual/index.html', '?project=a']) {
    ok(h.safeUrlStart(good), `${good} is the app's own`);
  }
  for (const bad of ['javascript:alert(1)', ' JavaScript:alert(1)', 'data:text/html,x', 'vbscript:x', 'http:x']) {
    ok(!h.safeUrlStart(bad), `${bad} is refused`);
  }
});

// ---------- the reader, against the shapes that matter ----------

const HOSTILE = {
  'a field of a document read from the service': "async function go() { const d = await (await fetch('x')).json(); el.innerHTML = `<td>${d.name}</td>`; }",
  'a row of a list read from the service': "async function go() { const d = await (await fetch('x')).json(); el.innerHTML = `<ul>${d.map(x => `<li>${x.name}</li>`).join('')}</ul>`; }",
  'a value through a helper that does not escape': "function label(m) { return m.name + ' x'; }\nfunction go(m) { el.innerHTML = `<b>${label(m)}</b>`; }\ngo(JSON.parse(x));",
  'an argument of the page\'s own words': UX + "function go(m) { el.innerHTML = `<i>${UX.count(m.n)}</i>`; }\ngo(JSON.parse(x));",
  'markup joined with +': "function go(m) { el.innerHTML = '<b>' + m.name + '</b>'; }\ngo(JSON.parse(x));",
  'an escaped value in an inline handler': ESC + "function go(m) { el.innerHTML = `<b onclick=\"f('${esc(m.name)}')\">x</b>`; }\ngo(JSON.parse(x));",
  'an escaped value as a link': ESC + "function go(m) { el.innerHTML = `<a href=\"${esc(m.url)}\">x</a>`; }\ngo(JSON.parse(x));",
  'a link from data set as a property': "function go(m) { a.href = m.url; }\ngo(JSON.parse(x));",
  'a value with no quotes around it': ESC + "function go(m) { el.innerHTML = `<td class=${esc(m.c)}>x</td>`; }\ngo(JSON.parse(x));",
  'a parameter one caller fills from data': ESC + "function row(t) { return `<td>${t}</td>`; }\nel.innerHTML = row(esc(a)) + row(JSON.parse(b).c);",
  'a local built up from data': "function go(m) { let h = ''; h += `<i>${m.x}</i>`; el.innerHTML = h; }\ngo(JSON.parse(x));",
  'an error message from Azure': "async function go() { try { await f(); } catch (e) { el.innerHTML = `<p>${e.message}</p>`; } }",
  'the page address': "el.innerHTML = `<p>${location.search}</p>`;",
  'a value set with insertAdjacentHTML': "function go(m) { el.insertAdjacentHTML('beforeend', `<tr><td>${m.name}</td></tr>`); }\ngo(JSON.parse(x));",
  'a promise callback': "function draw(m) { el.innerHTML = `<td>${m.name}</td>`; }\nfetch('x').then(r => r.json()).then(d => draw(d));",
  'a function nobody calls by name': "function draw(m) { el.innerHTML = `<td>${m.name}</td>`; }",
  'a property one caller fills from data, through a list': "function cell(f) { return `<td>${f.id}</td>`; }\nfunction draw({ fields = [] }) { el.innerHTML = fields.map(cell).join(''); }\nfunction extra() { return [{ id: JSON.parse(x).id }]; }\ndraw({ fields: [{ id: 'a' }, ...extra()] });",
};
for (const [what, src] of Object.entries(HOSTILE)) {
  test(`the reader finds ${what}`, () => {
    ok(findingsOf(src).length > 0, 'a finding');
  });
}

test('a finding says where the text comes from - the address, a caught error, a call it cannot follow', () => {
  const why = (src) => findingsOf(src).flatMap(f => f.from.map(g => g.why)).join(' | ');
  ok(/read from location/.test(why("el.innerHTML = `<p>${location.search}</p>`;")), 'the page address');
  ok(/read from document/.test(why("el.innerHTML = `<p>${document.querySelector('#q').value}</p>`;")), 'a field on the page');
  ok(/error caught/.test(why(HOSTILE['an error message from Azure'])), 'an error from Azure');
});

// CLAIM-AT-PLAN-1: a function that calls itself with its own list was followed
// for ever, and the reader stopped with a stack overflow - so no page was read.
// The value is then not told, and is checked whole: here it is from JSON, so it
// is a finding, which is the safe way to be wrong.
test('the reader ends on a function that gives its own list to itself again', () => {
  const got = findingsOf("function go(events) { let last = null; for (const e of (events ?? [])) { last = e; } el.innerHTML = `<b>${last.count + 1}</b>`; btn.onclick = () => go(events); }\ngo(JSON.parse(x));");
  eq(got.length, 1, 'it ends, and does not call the value safe');
});

const SAFE = {
  'an escaped field': ESC + "function go(m) { el.innerHTML = `<td>${esc(m.name)}</td>`; }\ngo(JSON.parse(x));",
  'the page\'s own words': UX + ESC + "function go(m) { el.innerHTML = `<b>${UX.title}</b><i>${UX.count(esc(m.n))}</i>`; }\ngo(JSON.parse(x));",
  'a count': "function go(m) { el.innerHTML = `<b>${m.list.length}</b><i>${m.list.filter(Boolean).length + 1}</i>`; }\ngo(JSON.parse(x));",
  'rows built from escaped values': ESC + "function go(d) { el.innerHTML = `<ul>${d.map((x, i) => `<li data-i=\"${i}\">${esc(x.name)}</li>`).join('')}</ul>`; }\ngo(JSON.parse(x));",
  'a helper that escapes': ESC + "function cell(v) { return `<td>${esc(v)}</td>`; }\nfunction go(m) { el.innerHTML = `<tr>${cell(m.a)}${cell(m.b)}</tr>`; }\ngo(JSON.parse(x));",
  'a link of this app': ESC + "function go(m) { el.innerHTML = `<a href=\"wizard.html?run=${encodeURIComponent(m.id)}\">${esc(m.id)}</a>`; }\ngo(JSON.parse(x));",
  'a choice between constants': "function go(m) { el.innerHTML = `<span class=\"pill ${m.ok ? 'good' : 'bad'}\">x</span>`; }\ngo(JSON.parse(x));",
  'a property every caller fills with a constant, through a list': "function cell(f) { return `<td>${f.id}</td>`; }\nfunction draw({ fields = [] }) { el.innerHTML = fields.map(cell).join(''); }\nfunction extra(ok) { return ok ? [{ id: 'b', data: JSON.parse(x) }] : null; }\ndraw({ fields: [{ id: 'a' }, ...extra(true)] });\ndraw({ title: 'x' });",
  'markup from a builder of escaped parts': ESC + "const card = (title, inner) => `<div><h2>${esc(title)}</h2>${inner}</div>`;\nfunction go(m) { el.innerHTML = card(m.t, `<p>${esc(m.p)}</p>`); }\ngo(JSON.parse(x));",
};
for (const [what, src] of Object.entries(SAFE)) {
  test(`the reader accepts ${what}`, () => {
    const got = findingsOf(src);
    eq(got.map(h.describe), [], 'no finding');
  });
}

// ---------- the dashboard ----------

/* Values the reader cannot prove safe, each read by a person and judged safe
 * for the reason given. `expr` is the value as the page writes it. Keep this
 * list short: a value that CAN go through esc() goes through it instead. */
const ALLOW = [
  { file: 'migrations.html', expr: 'desc',
    why: 'openModal writes desc as HTML only when rawDesc is true, and the three dialogs that set it build it from esc() parts; output-escape.test.js opens each with hostile values. Every other dialog goes to textContent.' },
  { file: 'migrations.html', expr: 'evidence',
    why: 'The evidence block this panel already shows, read back from the page and put back when the panel is drawn again. It was written with esc() (openDrill).' },
  { file: 'reports.html', expr: 'sheet',
    why: 'The report stylesheet from the service, used only when it has no @import or url( and with every </ written as <\\/, so it cannot end its block; report-theme.test.js.' },
  { file: 'reports.html', expr: 'logo',
    why: 'The report mark from the service, used only when it is an svg of g, rect and path with drawing attributes alone; report-theme.test.js.' },
  { file: 'reports.html', expr: 'markTheme(html, theme)',
    why: 'The report document, shown in a frame whose sandbox attribute is empty: an opaque origin with script off (SEC-REPORT-1, report-sandbox.test.js). The engine escapes every value in it (New-VmfReport).' },
];

const result = h.check(ALLOW);

test('the reader read every page and every script, and found the places they write HTML', () => {
  const files = [...new Set(result.units.map(u => u.file))].sort();
  for (const f of ['access.html', 'assessment-report.js', 'assessments.html', 'help.js', 'index.html',
    'migrations.html', 'projects.html', 'reports.html', 'waves.html', 'wizard.html']) {
    ok(files.includes(f), `${f} was read`);
  }
  ok(result.sinkCount > 1500, `it found ${result.sinkCount} values written into HTML - a reader that finds few has stopped reading`);
  ok(result.converged, 'the reader followed every value to the end: a value that depends on itself settled');
});

test('THE POINT: no page writes a value from outside the page into HTML without esc()', () => {
  ok(result.findings.length === 0,
    `${result.findings.length} value(s) reach HTML unescaped:\n  ${result.findings.map(h.describe).join('\n  ')}`);
});

test('every allowance still matches a value on a page, and says why it is safe', () => {
  eq(result.unused.map(a => `${a.file}: ${a.expr}`), [], 'no stale allowance');
  for (const a of ALLOW) { ok(a.why && a.why.length > 20, `${a.file}: ${a.expr} says why`); }
  ok(ALLOW.length <= 12, `${ALLOW.length} allowances - a value that can go through esc() goes through it`);
});

run('html-sinks');
