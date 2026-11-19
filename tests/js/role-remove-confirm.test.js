/* ROLE-REMOVE-CONFIRM-1, 2026-11-06. Found by the owner on the Admin page of
 * the lab install.
 *
 * The x on a user's role chip asked "Remove this role?" in the shared
 * confirmation row (POPUP-1). That row is absolutely positioned inside the
 * button's own container (ASKROW-1) - and here the container is the chip, a
 * pill about one word wide. So the row shrank to one word a line, made a tall
 * column over the role column, and floated over the next user's row. It also
 * did not say WHICH role, or from whom.
 *
 * The rule now: the confirmation for a role chip sits in its OWN table row,
 * directly under the user's row, across every column, in the page's flow.
 * Nothing floats over another row. The question names the role and the user,
 * by the display name the row already shows. Focus goes to the confirm;
 * Escape and Cancel take it away and give focus back to the x; Yes runs the
 * removal the page already had, once.
 *
 * Both halves are RUN: help.js's confirmInPlace with a small DOM, and
 * access.js's askRemoveRole with Microsoft Graph stubbed. Nothing here
 * reaches Microsoft Graph.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, extract, liftConst, test, eq, ok, run } = require('./_harness');

const confirmInPlace = lift('help.js', 'confirmInPlace');
const UX = liftConst('access.html', 'UX');

/* A DOM with real parents and siblings, so "under this row" is a fact the
 * test can read rather than a call it trusts. */
function fakeDom() {
  const docHandlers = {};
  const fake = { activeElement: null };
  const make = (tag) => {
    const el = {
      tag, tagName: String(tag).toUpperCase(), children: [], className: '', type: '', textContent: '', colSpan: 1,
      style: new Proxy({}, { get: (t, k) => (k in t ? t[k] : ''), set: (t, k, v) => { t[k] = v; return true; } }),
      hidden: false, handlers: {}, dataset: {}, disabled: false, parentNode: null,
      setAttribute() {},
      focus() { fake.activeElement = this; },
      appendChild(c) { if (c.parentNode) { c.parentNode.removeChild(c); } this.children.push(c); c.parentNode = this; return c; },
      insertBefore(c, ref) {
        if (c.parentNode) { c.parentNode.removeChild(c); }
        const i = ref ? this.children.indexOf(ref) : -1;
        if (i < 0) { this.children.push(c); } else { this.children.splice(i, 0, c); }
        c.parentNode = this; return c;
      },
      removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentNode = null; return c; },
      addEventListener(t, fn) { (this.handlers[t] ||= []).push(fn); },
      querySelectorAll() { return []; },
      closest(sel) {
        const hit = (n) => (sel[0] === '.' ? String(n.className).split(' ').includes(sel.slice(1)) : n.tag === sel);
        let n = this; while (n) { if (hit(n)) { return n; } n = n.parentNode; } return null;
      },
    };
    Object.defineProperty(el, 'nextSibling', { get() {
      if (!el.parentNode) { return null; }
      const sibs = el.parentNode.children; return sibs[sibs.indexOf(el) + 1] || null;
    } });
    Object.defineProperty(el, 'cells', { get() { return el.children.filter(c => c.tag === 'td'); } });
    return el;
  };
  fake.createElement = make;
  fake.addEventListener = (t, fn) => { (docHandlers[t] ||= []).push(fn); };
  fake.removeEventListener = (t, fn) => { docHandlers[t] = (docHandlers[t] || []).filter(x => x !== fn); };
  fake.press = (key) => { for (const fn of [...(docHandlers.keydown || [])]) { fn({ key, preventDefault() {} }); } };
  fake.listenerCount = () => (docHandlers.keydown || []).length;
  return fake;
}

/* The Admin page's table, as the page draws it: two users, each a row of
 * three cells; the first user's role chip holds the x. */
function table() {
  global.document = fakeDom();
  const d = global.document;
  const tbody = d.createElement('tbody');
  const userRow = d.createElement('tr');
  const nextRow = d.createElement('tr');
  for (const r of [userRow, nextRow]) { for (let i = 0; i < 3; i++) { r.appendChild(d.createElement('td')); } tbody.appendChild(r); }
  const chip = d.createElement('span');
  chip.className = 'pill';
  userRow.cells[2].appendChild(chip);
  const x = d.createElement('button');
  x.dataset.del = 'assign-1';
  x.dataset.role = 'Operator';
  x.dataset.who = 'Avery Example (avery@example.com)';
  chip.appendChild(x);
  return { d, tbody, userRow, nextRow, chip, x };
}

const askrowIn = (el) => el.children.find(c => /\baskrow\b/.test(c.className));

function openUnder() {
  const t = table();
  let yesCalls = 0;
  confirmInPlace(t.x, { ask: 'Remove the Operator role from Avery Example?', desc: 'One sentence.',
    yes: 'Yes, remove', cancel: 'Cancel', under: 'tr' }, () => { yesCalls++; });
  const line = t.tbody.children[1];
  const cell = line && line.children[0];
  const row = cell && askrowIn(cell);
  const buttons = row ? row.children.filter(c => c.tag === 'button') : [];
  return { ...t, line, cell, row, yes: buttons[0], no: buttons[1], yesCalls: () => yesCalls };
}

/* ---------- help.js: the confirmation in its own table row ---------- */

test('the confirmation is a table row of its own, directly under the user row', () => {
  const { tbody, userRow, nextRow, line } = openUnder();
  eq(tbody.children.length, 3, 'the table gains one row');
  eq(line.tag, 'tr', 'the new line is a table row');
  ok(tbody.children[0] === userRow && tbody.children[2] === nextRow, 'it sits between the user row and the next row');
});

test('its one cell spans every column of the user row', () => {
  const { cell, userRow } = openUnder();
  eq(cell.tag, 'td');
  eq(cell.colSpan, userRow.cells.length);
});

test('the question is in that cell, in the page flow, not floating in the chip', () => {
  const { chip, row, cell } = openUnder();
  ok(row, 'the question row is in the new cell');
  ok(/\binrow\b/.test(row.className), `the question row is marked to stay in the flow, got "${row.className}"`);
  eq(askrowIn(chip), undefined, 'nothing is put inside the chip');
  eq(chip.style.position, '', 'the chip is not made a positioning context');
  ok(cell.children.includes(row));
});

test('focus moves to the confirm', () => {
  const { d, yes } = openUnder();
  ok(d.activeElement === yes, 'focus is on Yes');
});

test('the x is kept in its chip while the question shows, and hidden', () => {
  const { chip, x } = openUnder();
  ok(chip.children.includes(x));
  eq(x.style.visibility, 'hidden');
});

test('Escape takes the row away, gives the x back, and puts focus on it', () => {
  const { d, tbody, x, yesCalls } = openUnder();
  d.press('Escape');
  eq(tbody.children.length, 2, 'the question row is gone');
  eq(x.style.visibility, '');
  ok(d.activeElement === x, 'focus returns to the x');
  eq(yesCalls(), 0, 'Escape removes nothing');
  eq(d.listenerCount(), 0, 'the Escape listener retires with the row');
});

test('Cancel does the same as Escape', () => {
  const { d, tbody, x, no, yesCalls } = openUnder();
  no.handlers.click[0]();
  eq(tbody.children.length, 2);
  eq(x.style.visibility, '');
  ok(d.activeElement === x);
  eq(yesCalls(), 0);
  eq(d.listenerCount(), 0);
});

test('Yes takes the row away and answers once', () => {
  const { d, tbody, x, yes, yesCalls } = openUnder();
  yes.handlers.click[0]();
  eq(tbody.children.length, 2);
  eq(x.style.visibility, '');
  eq(yesCalls(), 1);
  eq(d.listenerCount(), 0);
});

test('without "under", the row still opens where it always did', () => {
  // Every other caller (projects, assessments, waves) keeps ASKROW-1.
  const t = table();
  confirmInPlace(t.x, { ask: 'Delete this project?', yes: 'Yes', cancel: 'Cancel' }, () => {});
  ok(askrowIn(t.chip), 'the row opens in the button container');
  eq(t.chip.style.position, 'relative');
  eq(t.tbody.children.length, 2, 'no table row is added');
});

/* ---------- app.css: the in-flow row is not positioned ---------- */

test('the stylesheet keeps the in-row confirm in the flow, at full width', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '');
  const m = css.match(/\.askrow\.inrow\s*\{([^}]*)\}/);
  ok(m, 'app.css has a .askrow.inrow rule');
  ok(/position\s*:\s*static/.test(m[1]), 'position:static');
  ok(/max-width\s*:\s*calc\(100cqw/.test(m[1]), 'the width follows the card, not 32 characters');
  ok(/\.card:has\(tr\.askline\)\s*\{[^}]*container-type\s*:\s*inline-size/.test(css),
    'the card is the container the width is read from');
});

/* ---------- access.js: what the x asks, and what Yes does ---------- */

function page(opts = {}) {
  const body = extract('access.html', 'askRemoveRole');
  const calls = [];
  const asked = [];
  const flashes = [];
  let loads = 0;
  const env = {
    UX,
    VmfHelp: { confirmInPlace: opts.real
      ? confirmInPlace
      : (b, o, yes) => { asked.push(o); return opts.decline ? undefined : yes(); } },
    graph: async (method, url, bodyArg, interactive) => { calls.push({ method, url, bodyArg, interactive }); return {}; },
    flash: (el, msg) => flashes.push({ el, msg }),
    failAction: (e) => { throw e; },
    loadAssignments: () => { loads++; },
    spId: 'sp-1',
  };
  // eslint-disable-next-line no-eval
  const askRemoveRole = eval(`(function (env) {
    const { UX, VmfHelp, graph, flash, failAction, loadAssignments, spId } = env;
    ${body}
    return askRemoveRole;
  })`)(env);
  return { askRemoveRole, calls, asked, flashes, loads: () => loads };
}

const settle = () => new Promise(r => setTimeout(r, 0));

test('the question names the role and the user the row shows', async () => {
  const t = table();
  const pg = page();
  pg.askRemoveRole(t.x);
  await settle();
  eq(pg.asked.length, 1);
  eq(pg.asked[0].ask, 'Remove the Operator role from Avery Example (avery@example.com)?');
  eq(pg.asked[0].desc, UX.removeAskDesc);
  eq(pg.asked[0].yes, UX.removeYes);
  eq(pg.asked[0].cancel, UX.cancel);
});

test('it asks under the user row', async () => {
  const t = table();
  const pg = page();
  pg.askRemoveRole(t.x);
  await settle();
  eq(pg.asked[0].under, 'tr', 'the confirmation is anchored to the user row');
});

test('a name with a replacement pattern is shown as written', async () => {
  // String.replace reads "$&" in a replacement string as "the match".
  const t = table();
  t.x.dataset.who = 'A $& B';
  t.x.dataset.role = 'Op $1';
  const pg = page();
  pg.askRemoveRole(t.x);
  await settle();
  eq(pg.asked[0].ask, 'Remove the Op $1 role from A $& B?');
});

test('Yes calls the existing removal once, as the signed-in user', async () => {
  const t = table();
  const pg = page();
  pg.askRemoveRole(t.x);
  await settle();
  eq(pg.calls.length, 1);
  eq(pg.calls[0].method, 'DELETE');
  eq(pg.calls[0].url, 'servicePrincipals/sp-1/appRoleAssignedTo/assign-1');
  eq(pg.calls[0].interactive, true);
  eq(pg.flashes[0], { el: '#ok', msg: UX.removed });
  eq(pg.loads(), 1);
});

test('Cancel calls nothing', async () => {
  const t = table();
  const pg = page({ decline: true });
  pg.askRemoveRole(t.x);
  await settle();
  eq(pg.calls.length, 0);
  eq(pg.loads(), 0);
});

test('end to end: Escape on the real confirm removes nothing, Yes removes once', async () => {
  let t = table();
  let pg = page({ real: true });
  pg.askRemoveRole(t.x);
  ok(t.tbody.children.length === 3, 'the question row opened under the user');
  global.document.press('Escape');
  await settle();
  eq(pg.calls.length, 0, 'Escape calls nothing');
  ok(global.document.activeElement === t.x, 'focus is back on the x');

  t = table();
  pg = page({ real: true });
  pg.askRemoveRole(t.x);
  const row = askrowIn(t.tbody.children[1].children[0]);
  row.children.filter(c => c.tag === 'button')[0].handlers.click[0]();
  await settle();
  eq(pg.calls.length, 1, 'Yes calls the removal once');
});

/* ---------- access.js: the chip carries what the question needs ---------- */

test('each x carries the role word and the display name the row shows', () => {
  const body = extract('access.html', 'loadAssignments');
  ok(/data-del="\$\{esc\(a\.id\)\}"[^>]*data-role="\$\{esc\(word\)\}"/.test(body), 'data-role is the chip word');
  ok(/data-del=[^>]*data-who="\$\{esc\(who\)\}"/.test(body), 'the x carries who');
  ok(/const who = p\.signIn \? `\$\{p\.name\} \(\$\{p\.signIn\}\)` : p\.name;/.test(body),
    'who is the display name, with the sign-in name in brackets after it, never run together');
  ok(/data-del[^;]*addEventListener\('click', \(\) => askRemoveRole\(b\)\)/.test(body), 'the x opens askRemoveRole');
});

/* ---------- the class, not the instance: every confirmation in the flow ----------
 *
 * The coordinator's sweep, 2026-11-06: every other confirmInPlace caller had
 * the same shape - an absolute row over whatever was below its button. A
 * table row gets a line of its own; anything else gets the question as a
 * block directly after the element named. */

function block() {
  global.document = fakeDom();
  const d = global.document;
  const wave = d.createElement('div');
  const levers = d.createElement('div');
  levers.className = 'levers';
  const after = d.createElement('div');
  wave.appendChild(levers); wave.appendChild(after);
  const label = d.createElement('label');
  levers.appendChild(label);
  const btn = d.createElement('button');
  label.appendChild(btn);
  return { d, wave, levers, after, label, btn };
}

test('outside a table, the question is a block right after the element named', () => {
  const b = block();
  confirmInPlace(b.btn, { ask: 'Reserve capacity for wave 1?', yes: 'Reserve', cancel: 'Cancel', under: '.levers' }, () => {});
  const row = b.wave.children[1];
  ok(row && /\baskrow\b/.test(row.className), 'the question follows the levers');
  ok(/\binrow\b/.test(row.className) && /\baskblock\b/.test(row.className), `in the flow, as a block: "${row.className}"`);
  ok(b.wave.children[2] === b.after, 'what came after the levers comes after the question');
  eq(askrowIn(b.label), undefined, 'nothing is put in the label');
  eq(b.label.style.position, '');
  ok(b.d.activeElement && b.d.activeElement.tag === 'button', 'focus moves into the question');
});

test('and Escape takes the block away and gives focus back to the button', () => {
  const b = block();
  confirmInPlace(b.btn, { ask: 'Reserve?', yes: 'Reserve', cancel: 'Cancel', under: '.levers' }, () => {});
  b.d.press('Escape');
  eq(b.wave.children.length, 2);
  ok(b.d.activeElement === b.btn);
  eq(b.btn.style.visibility, '');
});

test('a selector that finds nothing falls back to the row beside the button', () => {
  const b = block();
  confirmInPlace(b.btn, { ask: 'Reserve?', yes: 'Reserve', cancel: 'Cancel', under: 'tr' }, () => {});
  ok(askrowIn(b.label), 'the old placement, not nothing');
});

test('the stylesheet gives the block its own width and space', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '');
  const m = css.match(/\.askrow\.askblock\s*\{([^}]*)\}/);
  ok(m, 'app.css has a .askrow.askblock rule');
  ok(/width\s*:\s*auto/.test(m[1]) && /margin\s*:/.test(m[1]), 'width:auto and a margin');
});

/* Every caller on the dashboard, and the element it asks under. A caller
 * added without one fails here. */
const CALLERS = [
  ['access.js', 'function askRemoveRole(', 'tr'],
  ['access.js', 'function askTidyRoles(', 'tr'],
  ['access.js', 'function revokeScope(', 'tr'],
  ['access.js', 'ask: UX.scopeWidenAsk', 'div'],
  // PAGE-SCALE-ASSESSMENTS-1: the button is in the page head now.
  ['assessments.js', 'async function tidyAbandoned(', '.pagehead'],
  ['assessments.js', 'function discardAssessment(', 'tr'],
  ['projects.js', 'function deleteProject(', 'tr'],
  ['waves.js', 'function reserveCapacity(', '.levers'],
  ['waves.js', 'function releaseCapacity(', '.levers'],
  ['waves.js', "$('#reset').addEventListener", '.bar'],
];
const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/.*$/gm, '$1');
/* The options of one call: from `confirmInPlace(` to the end of its first
 * argument list's object, by bracket depth, stepping over quoted text. */
function optionsOf(src, at) {
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === "'" || ch === '"' || ch === '`') {
      const end = src.indexOf(ch, i + 1);
      i = end < 0 ? src.length : end;
      continue;
    }
    if (ch === '{') { depth++; } else if (ch === '}') { depth--; if (!depth) { return src.slice(at, i + 1); } }
  }
  return src.slice(at);
}

test('every confirmInPlace caller names where its question goes', () => {
  const files = fs.readdirSync(DASH).filter(n => n.endsWith('.js') && n !== 'help.js' && !n.endsWith('.min.js'));
  let calls = 0;
  for (const n of files) {
    const src = strip(fs.readFileSync(path.join(DASH, n), 'utf8'));
    const re = /confirmInPlace\(/g;
    let m;
    while ((m = re.exec(src))) {
      calls++;
      const opts = optionsOf(src, m.index);
      ok(/\bunder:\s*'[^']+'/.test(opts), `${n}: a confirmInPlace call has no under: ${opts.slice(0, 80)}`);
    }
  }
  eq(calls, CALLERS.length, 'the list above names every caller');
});

for (const [file, near, sel] of CALLERS) {
  test(`${file} ${near} asks under ${sel}`, () => {
    const src = strip(fs.readFileSync(path.join(DASH, file), 'utf8'));
    const at = src.indexOf(near);
    ok(at >= 0, `${near} is in ${file}`);
    // The scope-widen question is found by its own ask, which sits inside the call.
    const call = near.startsWith('ask:') ? src.lastIndexOf('confirmInPlace(', at) : src.indexOf('confirmInPlace(', at);
    ok(call >= 0, `a confirmInPlace call follows ${near}`);
    const opts = optionsOf(src, call);
    ok(opts.includes(`under: '${sel}'`), `${near}: under '${sel}', got ${opts.slice(0, 160)}`);
  });
}

/* ---------- access.js: "Remove n already covered" ---------- */

function tidyPage(opts = {}) {
  const body = extract('access.html', 'askTidyRoles');
  const calls = [];
  const asked = [];
  let loads = 0;
  const env = {
    UX,
    VmfHelp: { confirmInPlace: (b, o, yes) => { asked.push(o); return opts.decline ? undefined : yes(); } },
    graph: async (method, url, bodyArg, interactive) => { calls.push({ method, url, interactive }); return {}; },
    flash: () => {},
    failAction: (e) => { throw e; },
    loadAssignments: () => { loads++; },
    spId: 'sp-1',
  };
  // eslint-disable-next-line no-eval
  const askTidyRoles = eval(`(function (env) {
    const { UX, VmfHelp, graph, flash, failAction, loadAssignments, spId } = env;
    ${body}
    return askTidyRoles;
  })`)(env);
  return { askTidyRoles, calls, asked, loads: () => loads };
}

function tidyTable() {
  const t = table();
  const b = global.document.createElement('button');
  b.dataset.tidy = 'user-1';
  b.dataset.ids = 'a-viewer,a-operator';
  b.dataset.who = 'Avery Example (avery@example.com)';
  t.userRow.cells[2].appendChild(b);
  // The cell's text runs the name and the sign-in name together, as the
  // browser's textContent does: the question must not read it.
  t.userRow.cells[0].textContent = 'Avery Exampleavery@example.com';
  const pill = (txt) => ({ textContent: txt });
  t.userRow.querySelectorAll = (sel) => (sel === '.pill.quiet' ? [pill('Viewer\u00d7'), pill('Operator\u00d7')] : []);
  t.userRow.querySelector = (sel) => (sel === '.pill:not(.quiet)' ? pill('Administrator\u00d7') : null);
  return { ...t, b };
}

test('the covered-roles question names the user, with the sign-in name kept apart', async () => {
  const t = tidyTable();
  const pg = tidyPage();
  pg.askTidyRoles(t.b);
  await settle();
  const first = pg.asked[0].ask.split('\n')[0];
  eq(first, 'Remove these roles from Avery Example (avery@example.com)?');
  ok(pg.asked[0].ask.includes('Viewer, Operator'), 'it lists the roles');
  ok(pg.asked[0].ask.includes('the Administrator role'), 'it names the role that covers them');
  eq(pg.asked[0].under, 'tr');
});

test('a name with a replacement pattern is shown as written in the covered-roles question', async () => {
  const t = tidyTable();
  t.b.dataset.who = 'A $& B';
  const pg = tidyPage();
  pg.askTidyRoles(t.b);
  await settle();
  eq(pg.asked[0].ask.split('\n')[0], 'Remove these roles from A $& B?');
});
test('Yes removes each covered role once, as the signed-in user', async () => {
  const t = tidyTable();
  const pg = tidyPage();
  pg.askTidyRoles(t.b);
  await settle();
  eq(pg.calls.map(c => `${c.method} ${c.url} ${c.interactive}`),
    ['DELETE servicePrincipals/sp-1/appRoleAssignedTo/a-viewer true',
     'DELETE servicePrincipals/sp-1/appRoleAssignedTo/a-operator true']);
  eq(pg.loads(), 1);
});

test('Cancel on the covered-roles question calls nothing', async () => {
  const t = tidyTable();
  const pg = tidyPage({ decline: true });
  pg.askTidyRoles(t.b);
  await settle();
  eq(pg.calls.length, 0);
});

test('the tidy button carries who, and opens askTidyRoles', () => {
  const body = extract('access.html', 'loadAssignments');
  ok(/data-tidy="\$\{esc\(p\.id\)\}"[\s\S]*?data-who="\$\{esc\(who\)\}"/.test(body), 'data-who on the tidy button');
  ok(/data-tidy[^;]*addEventListener\('click', \(\) => askTidyRoles\(b\)\)/.test(body), 'the tidy button opens askTidyRoles');
});
run('ROLE-REMOVE-CONFIRM-1: the role removal asks in its own row, by name');
