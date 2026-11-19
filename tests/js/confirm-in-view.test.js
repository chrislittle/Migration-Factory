/* CONFIRM-DIALOG-OUT-OF-VIEW-1 (filed 2026-11-08 from the lab): on the
 * Migrations page, Try this machine again seemed to do nothing. The confirm
 * it opens is the page's one dialog (#modal-back, fixed over the page and the
 * machine panel). Measured in a browser on the page's sample data: at a
 * desktop window it is drawn centred over the panel whatever the panel's
 * scroll position. It goes out of view in one way: a dialog taller than the
 * window. The box is centred in a fixed layer that cannot scroll, so its top
 * and its Cancel and Confirm are cut off and cannot be reached - a Restore
 * dialog of a machine with many disks, or a short window.
 *
 * Now the box has a height limit and scrolls inside itself, the way the
 * Waves page's confirm already does (reuse, not a new control). Each open
 * starts at the top of the box (the box is one element, used again, and
 * would keep the scroll of the dialog before), and the focus goes to the
 * first field - the note box of each confirm the panel opens with a note
 * only - once the box is on the screen.
 *
 * The other confirm the machine panel opens is the slide-out delete of disks
 * (MADE-DISK-DELETE-1), drawn in the panel under its link. A link near the
 * bottom of the panel's view opened it below the view: the same "nothing
 * happened". Now the panel draw that opens it scrolls it into view, one time,
 * the nearest way - the way the page already brings the captured evidence
 * into view - and a later refresh does not move the panel again.
 *
 * RUN, not read: the page's own openModal, toggleDiskDelete, closeDiskDelete
 * and revealDiskDelete against a small DOM of our own.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const HTML = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'migrations.html'), 'utf8');
const CSS = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'app.css'), 'utf8');

/* ---- a small DOM: one element per selector, made on first lookup -------- */
let els = new Map();
let active = null;
function el(sel) {
  const s = new Set();
  return {
    sel, _html: '', textContent: '', value: '', style: {}, dataset: {}, scrollTop: 0, scrolled: [], focusedOpen: null,
    classList: { add: (c) => s.add(c), remove: (c) => s.delete(c), contains: (c) => s.has(c) },
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); },
    addEventListener() { },
    querySelectorAll() { return []; },
    querySelector(q) { return q === 'input,textarea' && this._html.includes('<textarea id="mf-note"') ? $('#mf-note') : null; },
    focus() { active = this; this.focusedOpen = $('#modal-back').classList.contains('open'); this.focusedAtTop = $('#modal-back .modal').scrollTop === 0; },
    scrollIntoView(o) { this.scrolled.push(o); },
  };
}
function $(sel) { if (!els.has(sel)) { els.set(sel, el(sel)); } return els.get(sel); }
function fresh() { els = new Map(); active = null; }

Object.assign(globalThis, {
  $, UX_ACT: liftConst('migrations.html', 'UX_ACT'), esc: (s) => String(s ?? ''),
  document: { querySelector: () => null, querySelectorAll: () => [] },
  VmfHelp: { explainAction: (e) => String(e && e.message) }, followThrough: () => { }, modalMachine: null,
  refreshDrill: () => true, diskDelete: null,
});
const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);
// Lifted when a test asks, so a missing function fails its own tests only.
const lazy = {};
const disk = new Proxy({}, { get: (_, n) => { if (!lazy.f) { lazy.f = liftAll('migrations.html', ['toggleDiskDelete', 'closeDiskDelete', 'revealDiskDelete']); } return lazy.f[n]; } });
const note = { id: 'note', label: 'Why? A short note, recorded with the action', type: 'textarea', required: true };

/* ---- the dialog ----------------------------------------------------------- */

test('the dialog box has a height limit and scrolls inside itself, as the Waves page confirm does', () => {
  const rule = CSS.match(/\.p-migrations \.modal \{([^}]*)\}/);
  ok(rule, 'the Migrations page has its dialog box rule');
  const limit = rule[1].match(/max-height:\s*([0-9.]+vh)/);
  ok(limit, `a height limit from the window: ${rule[1]}`);
  ok(/overflow-y:\s*auto/.test(rule[1]), `it scrolls inside itself: ${rule[1]}`);
  const waves = CSS.match(/\.p-waves \.modal \{([^}]*)\}/);
  ok(waves && waves[1].includes(`max-height:${limit[1]}`), 'the same limit as the Waves page confirm (one look for a confirm)');
  ok(/\.p-migrations #modal-back \{[^}]*position:fixed;[^}]*place-items:center/.test(CSS), 'still a fixed layer over the page and the panel, centred');
  ok(/\.p-migrations #modal-back \{[^}]*z-index:30/.test(CSS) && /\.p-migrations #drill \{[^}]*z-index:10/.test(CSS), 'above the machine panel');
  ok(HTML.indexOf('<div id="modal-back">') > HTML.indexOf('</aside>') && !/<aside id="drill"[\s\S]*?<div id="modal-back">[\s\S]*?<\/aside>/.test(HTML),
    'the dialog is outside the machine panel, so the panel scroll does not move it');
});

test('Try this machine again: the dialog opens at the top of its box, with the focus on the note box', () => {
  fresh();
  $('#modal-back .modal').scrollTop = 480;   // the dialog before was scrolled down
  modal.openModal({ title: UX_ACT.resolve, desc: 'd', fields: [note], onConfirm: async () => undefined });
  ok($('#modal-back').classList.contains('open'), 'the dialog is open');
  eq($('#modal-back .modal').scrollTop, 0, 'the box starts at its top');
  eq(active && active.sel, '#mf-note', 'the focus is on the note box');
  eq(active.focusedOpen, true, 'the focus moves after the dialog is on the screen (a hidden box takes no focus)');
  eq(active.focusedAtTop, true, 'and after the box is back at its top');
});

test('rule 11: Cancel and Escape still close the dialog', () => {
  ok(PAGE.includes("$('#m-cancel').addEventListener('click', closeModal);"), 'Cancel');
  ok(PAGE.includes("if ($('#modal-back').classList.contains('open')) { if (closeModalHelp()) return; closeModal(); return; }"), 'Escape');
  fresh();
  modal.openModal({ title: 't', desc: 'd', fields: [note], onConfirm: async () => undefined });
  eq($('#m-cancel').textContent, UX_ACT.cancel, 'the button says Cancel');
  modal.closeModal();
  ok(!$('#modal-back').classList.contains('open'), 'closed');
});

test('every confirm the machine panel opens goes through the one dialog or the slide-out delete', () => {
  for (const id of ['resolve', 'decide', 'restore', 'finish', 'powerback', 'skip']) {
    ok(new RegExp(`\\$\\('#${id}-btn'\\)\\?\\.addEventListener\\('click', \\(\\) => panelDialog\\(`).test(PAGE), `${id}: panelDialog`);
  }
  ok(PAGE.includes('b.addEventListener(\'click\', () => panelDialog(vmId, () => askRetrySeries('), 'retry on another series: panelDialog');
  const panelDialog = extract('migrations.html', 'panelDialog');
  ok(/\n\s*open\(\);/.test(panelDialog), 'panelDialog opens the dialog the ask function builds');
  ok(!/window\.confirm|\bconfirm\(/.test(PAGE.replace(/confirmDiskDelete\(|confirmBtn|confirmLabel/g, '')), 'no browser confirm box');
});

/* ---- the slide-out delete of disks ---------------------------------------- */

test('click 1 opens the slide-out; the draw that shows it scrolls it into view, the nearest way', () => {
  fresh();
  globalThis.diskDelete = null;
  disk.toggleDiskDelete('vm-1', 'made');
  disk.revealDiskDelete();
  eq($('#madedelete-slide').scrolled, [{ block: 'nearest' }], 'scrolled into view one time');
});

test('a later draw (the refresh) does not move the panel again', () => {
  fresh();
  globalThis.diskDelete = null;
  disk.toggleDiskDelete('vm-1', 'earlier');
  disk.revealDiskDelete();
  disk.revealDiskDelete();
  disk.revealDiskDelete();
  eq($('#earlierdelete-slide').scrolled.length, 1, 'one time only');
});

test('a closed slide-out, or none, scrolls nothing', () => {
  fresh();
  globalThis.diskDelete = null;
  disk.revealDiskDelete();
  disk.toggleDiskDelete('vm-1', 'made');
  disk.toggleDiskDelete('vm-1', 'made');
  disk.revealDiskDelete();
  eq($('#madedelete-slide').scrolled.length, 0, 'closed by the link');
  disk.toggleDiskDelete('vm-1', 'original');
  disk.closeDiskDelete();
  disk.revealDiskDelete();
  eq($('#originaldelete-slide').scrolled.length, 0, 'closed by Cancel');
});

test('the panel draw asks for it after its controls are wired', () => {
  const body = extract('migrations.html', 'openDrill');
  ok(/\n\s*revealDiskDelete\(\);/.test(body), 'openDrill calls revealDiskDelete');
  ok(body.indexOf('revealDiskDelete();') > body.indexOf('refocusDrill();') || /refocusDrill\(\);\s*\n\s*revealDiskDelete\(\);/.test(body),
    'after the focus is put back');
});

run('confirm-in-view');
