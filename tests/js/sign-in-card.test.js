/* SIGNIN-1: ONE sign-in card, built once, for all eight pages.
 *
 * The card was written out by hand on every page, and the copies had drifted:
 *
 *   - reports.html's line never mentioned signing in. It described the page,
 *     under a heading that said "Sign in".
 *   - migrations.html wrote its line into the MARKUP, where the strings gate
 *     cannot see it, and used a different button class - so the button on that
 *     one page did not look like the button on the other seven.
 *   - access.html rendered its line through innerHTML where the other seven
 *     used textContent.
 *   - the card's own CSS was written three times, with two different widths.
 *
 * These drive the real showSignIn against a DOM small enough to be honest
 * about: innerHTML is kept as a string, and a lookup inside it matches on the
 * id written into that string. That is enough to prove what it BUILT and what
 * it HANDED BACK, which is the part a caller depends on.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const HELP = path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js');
const source = fs.readFileSync(HELP, 'utf8');

// The REAL strings, read out of help.js rather than restated here - a test
// that carries its own copy of the words proves only that it can copy.
const TEXT = {};
for (const key of ['signInTitle', 'signInWhat', 'signInBtn']) {
  const m = new RegExp(`${key}:\\s*'((?:[^'\\\\]|\\\\.)*)'`).exec(source);
  if (!m) { throw new Error(`help.js no longer declares TEXT.${key}`); }
  TEXT[key] = m[1];
}
global.TEXT = TEXT;
global.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const showSignIn = lift('help.js', 'showSignIn');

/** A host whose innerHTML is a string, and a lookup that reads that string. */
function makeHost() {
  return {
    innerHTML: '',
    style: {},
    querySelector(sel) {
      const id = sel.replace('#', '');
      return this.innerHTML.includes(`id="${id}"`) ? { id, from: 'card' } : null;
    },
  };
}

function page({ host = makeHost(), nav = { innerHTML: '<a>Overview</a><a>Reports</a>' } } = {}) {
  global.document = {
    querySelector(sel) {
      if (sel === '#login-view') { return host; }
      if (sel === 'nav.topnav') { return nav; }
      return null;
    },
  };
  return { host, nav };
}

test('it builds the button and hands it back, so the caller can wire it', () => {
  // Every page does showSignIn() then addEventListener on the next line. A
  // card drawn without its button would leave eight dead sign-in screens.
  const { host } = page();
  const btn = showSignIn();
  ok(btn, 'a button came back');
  eq(btn.id, 'login-btn', 'and it is the id every page wires');
  ok(host.innerHTML.includes('id="login-btn"'), 'which is the one in the card');
});

test('it shows the card', () => {
  const { host } = page();
  showSignIn();
  eq(host.style.display, 'block');
});

test('the card carries four parts, in order, and the button is the last', () => {
  const { host } = page();
  showSignIn();
  const at = (s) => host.innerHTML.indexOf(s);
  ok(at('signin-mark') >= 0, 'the mark');
  ok(at(TEXT.signInTitle) > at('signin-mark'), 'then the product');
  ok(at(TEXT.signInWhat) > at(TEXT.signInTitle), 'then what it does');
  ok(at(TEXT.signInBtn) > at(TEXT.signInWhat), 'then the way in');
  // SIGNIN-TAGLINE-1: the note under the button is gone, with nothing in its
  // place (2026-11-07: the note added nothing).
  ok(host.innerHTML.trim().endsWith('</button>'), 'nothing comes after the button');
  eq((host.innerHTML.match(/<p\b/g) || []).length, 1, 'one line of words, the tagline');
});

test('the heading names the PRODUCT, and only the button says sign in', () => {
  // The old card said it three times: a heading "Sign in", a line starting
  // "Sign in to see...", and a button "Sign in with Entra ID".
  const { host } = page();
  showSignIn();
  ok(/<h2>[^<]*Migration Factory[^<]*<\/h2>/.test(host.innerHTML), 'the heading is the product');
  eq((host.innerHTML.match(/Sign in/gi) || []).length, 1, 'said once, on the button');
});

test('the button names Microsoft Entra ID, the name Microsoft uses', () => {
  ok(/Microsoft Entra ID/.test(TEXT.signInBtn));
});

test('the navigation goes while the card is up', () => {
  // Every tab leads back to this same card, so a signed-out person could only
  // walk in a circle.
  const { nav } = page();
  showSignIn();
  eq(nav.innerHTML, '', 'emptied');
});

test('a page with no card host is left alone rather than thrown at', () => {
  global.document = { querySelector: () => null };
  eq(showSignIn(), null, 'it returns null');
});

test('a page with no navigation still gets its card', () => {
  const host = makeHost();
  global.document = { querySelector: (s) => (s === '#login-view' ? host : null) };
  const btn = showSignIn();
  eq(btn.id, 'login-btn');
  eq(host.style.display, 'block');
});

test('every string goes through the escaper', () => {
  // The words are ours today. They are also the only thing between this
  // markup and whatever a future edit puts in TEXT - and access.html used to
  // render its line through innerHTML with no escaping at all.
  const { host } = page();
  const real = global.TEXT;
  global.TEXT = {
    signInTitle: '<img src=x onerror=1>', signInWhat: '<b>b</b>',
    signInBtn: '"q"',
  };
  try {
    showSignIn();
    ok(!host.innerHTML.includes('<img'), 'no tag survived the title');
    ok(!host.innerHTML.includes('<b>'), 'nor the line');
    ok(host.innerHTML.includes('&lt;img'), 'it was escaped, not dropped');
    ok(host.innerHTML.includes('&quot;q&quot;'), 'quotes too');
  } finally { global.TEXT = real; }
});

test('the tagline is the approved one', () => {
  // SIGNIN-TAGLINE-1, 2026-11-07: held as the EXACT sentence, because
  // the words were approved exactly. "migrate" is the product's own verb, the
  // one on the Assess and migrate button; Microsoft's "modernize" means a move
  // to PaaS. The old line named only v6 and v7, and the product also moves
  // machines to v5 and Bsv2.
  eq(TEXT.signInWhat, 'Assess and migrate Azure virtual machines.');
  ok(!/moderni[sz]e/i.test(TEXT.signInWhat), 'not the word for a move to PaaS');
});

test('the note under the button is gone from the words too', () => {
  // Removed, with nothing in its place. A string declared and never shown
  // fails the strings gate; one still shown fails the order test above.
  ok(!/signInScope\s*:/.test(source), 'help.js no longer declares it');
  ok(!/signin-scope/.test(source), 'and builds no element for it');
});

run('one sign-in card, for all of them');
