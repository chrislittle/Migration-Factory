/* WAVE-NOTE-LAYOUT-1: the Preview note on a wave card was loose text beside a
 * "Preview" pill, with the machine names run into the end of the sentence, so
 * the browser broke a line inside a name ("prev-" / "ds6"). The layout looked
 * wrong. The approved mock-up is a box inside the card:
 * the pill and a short title, the sentence with no names, then "Virtual
 * machines:" and the names, each one never broken inside itself.
 *
 * The names come from Azure, so the box is built with DOM nodes and
 * textContent. The fake document below refuses innerHTML outright.
 *
 * RUN: the page's own previewLine, fillPreviewNote and drawWaveNotes.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WAVES = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
const CSS = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'app.css'), 'utf8');

/* A tree that remembers what was built, and throws on any markup. */
function el(tag) {
  const node = {
    tagName: String(tag).toUpperCase(), className: '', children: [], dataset: {}, _text: '',
    get textContent() { return this.children.length ? this.children.map(c => c.textContent).join('') : this._text; },
    set textContent(v) { this.children = []; this._text = String(v); },
    set innerHTML(v) { throw new Error('innerHTML used: ' + v); },
    get innerHTML() { throw new Error('innerHTML read'); },
    insertAdjacentHTML() { throw new Error('insertAdjacentHTML used'); },
    appendChild(c) { this.children.push(c); return c; },
    append(...cs) { cs.forEach(c => this.children.push(typeof c === 'string' ? { nodeType: 3, textContent: c } : c)); },
    replaceChildren(...cs) { this.children = []; this._text = ''; this.append(...cs); },
  };
  return node;
}
globalThis.document = {
  createElement: el,
  createTextNode: (t) => ({ nodeType: 3, textContent: String(t) }),
  querySelectorAll: () => [],
};

globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['previewNames', 'subscriptionOf', 'previewNeeds']));
globalThis.UX = liftConst('waves.html', 'UX');
globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.wPreview = new Map();
globalThis.wPreviewHelp = new Set();
const page = liftAll('waves.html', ['previewLine', 'previewNoticeHtml', 'fillPreviewNote', 'drawWaveNotes']);

const A = '00000000-0000-0000-0000-000000000000';
const vm = (n, method = 'preview') => ({ vmId: `/subscriptions/${A}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${n}`, wave: 'w1', path: 'A', target: { choice: { method } } });
const kids = (n) => n.children.filter(c => c.tagName);

test('the sentence ends with a full stop and holds no machine names', () => {
  for (const k of ['previewOne', 'previewMany']) {
    ok(!UX[k].includes('{names}'), `${k} has no names`);
    ok(UX[k].endsWith('VMTempDiskResizePreview.'), UX[k]);
  }
  eq(UX.previewOne, '1 machine in this wave takes the in-place upgrade (Preview), which needs the preview feature VMTempDiskResizePreview.');
  eq(UX.previewMany, '{n} machines in this wave take the in-place upgrade (Preview), which needs the preview feature VMTempDiskResizePreview.');
  eq(UX.noteVms, 'Virtual machines:');
});

test('the box: the pill and the title, the sentence, then the names, each in its own node', () => {
  const box = el('div');
  page.fillPreviewNote(box, [vm('web-01'), vm('web-02'), vm('db-01'), vm('plain', 'in-place')]);
  const [head, said, vms] = kids(box);
  eq(kids(box).length, 3, 'three parts');
  eq(head.className, 'wnote-t');
  eq(kids(head)[0].className, 'pill');
  eq(kids(head)[0].textContent, UX.previewPill);
  eq(head.textContent, UX.previewPill + UX.changePreview, 'the pill, then the title');
  eq(said.tagName, 'P');
  eq(said.textContent, UX.previewMany.replace('{n}', '3'));
  eq(vms.className, 'wnote-vms');
  eq(vms.textContent, `${UX.noteVms} web-01, web-02, db-01`);
  const names = kids(vms).filter(c => c.className === 'wnote-vm');
  eq(JSON.stringify(names.map(c => c.textContent)), JSON.stringify(['web-01', 'web-02', 'db-01']), 'one node per name');
  ok(!names.some(c => c.children.length), 'a name is one text, never split');
});

test('one machine: the one-machine sentence and one name', () => {
  const box = el('div');
  page.fillPreviewNote(box, [vm('prev-ds6')]);
  const [, said, vms] = kids(box);
  eq(said.textContent, UX.previewOne);
  eq(vms.textContent, `${UX.noteVms} prev-ds6`);
});

test('a name with markup in it stays text (names come from Azure)', () => {
  const box = el('div');
  const bad = '<img src=x onerror=alert(1)>';
  page.fillPreviewNote(box, [vm(bad)]);
  const name = kids(kids(box)[2]).find(c => c.className === 'wnote-vm');
  eq(name.textContent, bad);
});

test('a second fill replaces the box, never adds to it', () => {
  const box = el('div');
  page.fillPreviewNote(box, [vm('a1'), vm('a2')]);
  page.fillPreviewNote(box, [vm('a1')]);
  eq(kids(box).length, 3);
  eq(kids(box)[2].textContent, `${UX.noteVms} a1`);
});

test('the card holds an empty box for the note, named by its wave, and only when a machine takes the Preview', () => {
  const html = page.previewLine([vm('a1')], 'w<1>');
  ok(html.includes('<div class="wnote" data-wnote="w&lt;1&gt;"></div>'), html);
  ok(!html.includes('a1'), 'no name in the markup');
  ok(!page.previewLine([vm('plain', 'in-place')], 'w1').includes('wnote'), 'no Preview machine, no box');
  ok(!WAVES.includes("class=\"hint wpreview\""), 'the loose line is gone');
});

test('render fills each box after it draws the cards', () => {
  ok(WAVES.includes('${previewLine(members, name)}'), 'the card calls it with its wave');
  const at = WAVES.indexOf("$('#waves').innerHTML = order.map(");
  const fill = WAVES.indexOf('drawWaveNotes();', at);
  const next = WAVES.indexOf('drawQuotaCard();', at);
  ok(at > 0 && fill > at && fill < next, 'drawWaveNotes runs right after the cards are drawn');
  const boxes = [el('div'), el('div')];
  boxes[0].dataset.wnote = 'w1'; boxes[1].dataset.wnote = 'w2';
  const waves = { w1: [vm('a1')], w2: [vm('b1'), vm('b2')] };
  globalThis.membersOf = (w) => waves[w] ?? [];
  globalThis.document.querySelectorAll = (sel) => (sel === '[data-wnote]' ? boxes : []);
  page.drawWaveNotes();
  eq(kids(boxes[0])[2].textContent, `${UX.noteVms} a1`);
  eq(kids(boxes[1])[2].textContent, `${UX.noteVms} b1, b2`);
});

/* The CSS rule of one selector, as written in app.css. */
function rule(sel) {
  const at = CSS.indexOf(sel + ' {');
  ok(at >= 0, `no rule for ${sel}`);
  return CSS.slice(at, CSS.indexOf('}', at));
}

test('a name never breaks inside itself; the line wraps between names', () => {
  ok(/white-space:\s*nowrap/.test(rule('.p-waves .wave .wnote-vm')), 'nowrap per name');
  ok(!/white-space:\s*nowrap/.test(rule('.p-waves .wave .wnote-vms')), 'the line itself wraps');
  ok(!/background|border|padding/.test(rule('.p-waves .wave .wnote-vm')), 'plain text: no pill or box on a name');
});

test('the box: a border, a left accent line, the card background, the card left edge, body size, theme tokens only', () => {
  const box = rule('.p-waves .wave .wnote');
  ok(/border:\s*1px solid var\(--line\)/.test(box), 'border');
  ok(/border-left:\s*3px solid var\(--brand\)/.test(box), 'left accent line');
  ok(/background:\s*var\(--card\)/.test(box), 'card background');
  ok(/margin:\s*10px 14px/.test(box), 'the 14px left edge of the card header and settings');
  ok(/font-size:\s*14px/.test(box), 'body size');
  ok(!/#[0-9a-f]{3,6}\b/i.test(box + rule('.p-waves .wave .wnote-t') + rule('.p-waves .wave .wnote-vm')), 'no fixed colour: light and dark through the tokens');
});

run('wave-note-layout');
