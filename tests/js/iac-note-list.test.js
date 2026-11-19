/* IAC-NOTE-LIST-1, 2026-11-08. The note about machines defined in code is a
 * list, not one paragraph.
 *
 * Seen on the Run it step during a lab run: one long run-on list of items,
 * and not easy to read. The note was ten sentences in one
 * paragraph. Every person must accept it before any wave starts, and in that
 * form a person could not see what changes on the machine.
 *
 * These words were approved on 2026-11-08: a lead, one list item for each
 * change, then what to do. They are
 * held here word for word, on BOTH pages - ACK-GATE-1: one question asked in
 * two places must not become two questions.
 *
 * The list is built with DOM nodes and textContent, never with innerHTML, so
 * each item is a real <li> and no word of it is read as markup.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { test, eq, ok, run, liftConst, lift, liftAll } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const UX = liftConst('wizard.html', 'UX');
const UX_ACT = liftConst('migrations.html', 'UX_ACT');

const APPROVED = {
  title: 'Before you start: machines defined in code',
  lead: 'Terraform, Bicep, Pulumi, ARM templates and Ansible keep their own definition of each machine. This migration makes these changes, and those definitions do not know about them:',
  changes: [
    'The size of the machine changes.',
    'A move to v6 or v7 changes the disk controller from SCSI to NVMe.',
    'A move can change accelerated networking.',
    'A move can change the disk type to Standard SSD or Premium SSD.',
    'A rollback or a restore puts the machine on new disks, made from its safety copies. A restore can keep the disk names.',
  ],
  after: 'The next apply can undo these changes, or replace the machine. Reconcile your definitions after the migration.',
  accept: 'I understand, and I will reconcile our definitions after the migration.',
};

/* A small element: enough for createElement, textContent, appendChild and
 * replaceChildren - the calls the note is built with. innerHTML is a trap:
 * a write to it fails the test. */
function element(tag) {
  const el = {
    tagName: tag.toUpperCase(), className: '', textContent: '', children: [],
    appendChild(c) { this.children.push(c); return c; },
    replaceChildren(...c) { this.children = c; },
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return ''; },
    set() { throw new Error('the note must be built with DOM nodes, not innerHTML'); },
  });
  return el;
}
const fakeDocument = () => ({ createElement: element });

/* What a person reads, from the nodes the page built. */
function readNote(nodes) {
  const kinds = nodes.map(n => n.tagName).join(',');
  eq(kinds, 'P,UL,P', 'a lead, the list, then what to do');
  return {
    lead: nodes[0].textContent,
    changes: nodes[1].children.map(li => { eq(li.tagName, 'LI', 'each change is a list item'); return li.textContent; }),
    after: nodes[2].textContent,
  };
}

/* ---- the words ----------------------------------------------------------- */

test('the wizard holds the approved words, one string for each list item', () => {
  eq(UX.iacTitle, APPROVED.title, 'the heading is unchanged');
  eq(UX.iacLead, APPROVED.lead);
  eq(JSON.stringify(UX.iacChanges), JSON.stringify(APPROVED.changes), 'five changes, in order');
  eq(UX.iacAfter, APPROVED.after);
  eq(UX.iacAccept, APPROVED.accept, 'the checkbox is unchanged');
});

test('the Migrations page holds the same words, so the two cannot drift apart', () => {
  ok(Array.isArray(UX_ACT.ackChanges) && UX_ACT.ackChanges.length === 5, 'the Migrations page has the five changes');
  eq(UX_ACT.ackLead, UX.iacLead);
  eq(JSON.stringify(UX_ACT.ackChanges), JSON.stringify(UX.iacChanges));
  eq(UX_ACT.ackAfter, UX.iacAfter);
  eq(UX_ACT.ackAccept, UX.iacAccept);
});

test('no page keeps the paragraph version of the note', () => {
  for (const file of ['wizard.html', 'migrations.html']) {
    const src = pageSource(path.join(DASH, file));
    ok(!/iacStatement|ackStatement/.test(src), `${file}: the paragraph key is gone`);
    ok(!src.includes('Migrating a machine changes its size'), `${file}: the paragraph words are gone`);
    ok(!src.includes('Reconciling them afterwards is yours to do'), `${file}: its last sentence too`);
  }
});

/* ---- the wizard's Run it step -------------------------------------------- */

// Lifted when a test runs, so a page without it fails that test, not the file.
const iacNoteNodes = (...a) => lift('wizard.html', 'iacNoteNodes')(...a);

test('the wizard builds the note as a lead, a list of five items and a closing line', () => {
  globalThis.UX = UX;
  globalThis.document = fakeDocument();
  const note = readNote(iacNoteNodes());
  eq(note.lead, APPROVED.lead);
  eq(JSON.stringify(note.changes), JSON.stringify(APPROVED.changes));
  eq(note.after, APPROVED.after);
});

const renderStep5 = lift('wizard.html', 'renderStep5');
function paintStep5({ acked, operator = true }) {
  const host = element('div');
  const node = () => ({ addEventListener() {}, style: {}, value: '', textContent: '', querySelectorAll: () => [] });
  Object.assign(globalThis, {
    UX, planWaves: () => [['w1', { n: 1 }]], plan: { entries: [{ wave: 'w1', policy: {} }] },
    runForm: { note: '', throttle: 3, throttleTouched: false, ack: false, how: 'all', times: {} },
    acceptances: new Map([['w1', { acceptedBy: 'operator@example.com' }]]), planSignoff: null, planSignoffCurrent: true,
    approvals: new Map(), waveSignState: lift('wizard.html', 'waveSignState'), canApprove: true, canOperate: operator,
    acceptControl: lift('wizard.html', 'acceptControl'), acceptAllControl: lift('wizard.html', 'acceptAllControl'),
    startControl: lift('wizard.html', 'startControl'), acknowledged: acked,
    esc: (v) => String(v == null ? '' : v), card: (t, b, inner) => `<h2>${t}</h2><p>${b}</p>${inner}`,
    leverRowsFor: () => '', tempSections: () => '', sizeRowsFor: () => '', runHref: (x) => x,
    VmfHelp: require('./_identity').help({ WAVE_MAX_WORKERS: 60, waveEstimate: () => '' }),
    $: () => node(), tHelpBtn: lift('wizard.html', 'tHelpBtn'), helpWire: () => {}, exportPlan: () => {},
    paintStartFailure: () => {}, tHelp: new Set(), iacNoteNodes,
  });
  globalThis.document = Object.assign(fakeDocument(), { querySelectorAll: () => [], querySelector: () => node() });
  const el = { innerHTML: '', querySelectorAll: () => [], querySelector: (sel) => (sel === '#iac-note' && el.innerHTML.includes('id="iac-note"') ? host : null) };
  renderStep5(el);
  return { html: el.innerHTML, host };
}

test('the Run it step fills its note host with the list, in the same place, before the checkbox', () => {
  const { html, host } = paintStep5({ acked: false });
  const at = html.indexOf('id="iac-note"');
  ok(at > html.indexOf(UX.iacTitle), 'under the heading');
  ok(at < html.indexOf('id="f-ack"'), 'and above the checkbox');
  const note = readNote(host.children);
  eq(JSON.stringify(note.changes), JSON.stringify(APPROVED.changes), 'the list is on the screen');
  ok(!html.includes(APPROVED.changes[0]), 'no item is written into the markup as text');
});

test('a person who cannot operate still reads the list, with nothing to tick', () => {
  const { html, host } = paintStep5({ acked: false, operator: false });
  ok(html.includes('id="iac-note"'));
  eq(readNote(host.children).changes.length, 5);
  ok(!html.includes('id="f-ack"'));
});

test('once the note is accepted, the step shows no note', () => {
  const { html, host } = paintStep5({ acked: true });
  ok(!html.includes('id="iac-note"'));
  eq(host.children.length, 0, 'nothing filled');
});

/* ---- the Migrations page's dialog ---------------------------------------- */

test('Accept and let this run start shows the same list in its dialog', () => {
  const gate = liftAll('migrations.html', ['askAcknowledge', 'ackNoteNodes']);
  const desc = element('div');
  let captured = null;
  Object.assign(globalThis, {
    UX_ACT, openModal: (o) => { captured = o; }, noteField: () => ({ id: 'note' }),
    $: (sel) => (sel === '#m-desc' ? desc : null),
  });
  globalThis.document = fakeDocument();
  gate.askAcknowledge();
  eq(captured.title, UX_ACT.ackTitle);
  ok(!captured.rawDesc, 'no markup goes into the dialog');
  const note = readNote(desc.children);
  eq(note.lead, UX.iacLead, 'the lead the wizard shows');
  eq(JSON.stringify(note.changes), JSON.stringify(UX.iacChanges), 'the list the wizard shows');
  eq(note.after, UX.iacAfter, 'the closing line the wizard shows');
  eq(captured.fields[0].options[0].label, UX.iacAccept, 'and the same checkbox');
});

test('the dialog holder is a div, so a list inside it is valid HTML', () => {
  const html = pageSource(path.join(DASH, 'migrations.html'));
  ok(/<div class="desc" id="m-desc"><\/div>/.test(html), 'a <ul> cannot sit inside a <p>');
});

run('machines defined in code note');
