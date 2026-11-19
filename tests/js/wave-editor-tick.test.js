/* WAVE-EDITOR-TICK-1: a machine selected out of sight moves with no word.
 *
 * Lab install, 2026-11-04. In the wave editor a machine was added to wave 1.
 * The list then said "3 shown · 4 selected" - one selected machine was not in
 * the list at all - and the next "Add selected machines" on wave 2 MOVED that
 * machine from wave 1 to wave 2. Nothing on the screen said so.
 *
 * A machine can be selected where the list does not show it: a row inside a
 * wave card selects on a click (that is how it is dragged to another wave),
 * a tick stays when a filter hides its row, and "Everything" shows machines
 * that are already in a wave. Moving such a machine is allowed. Doing it with
 * no word is the defect, and so is a count that counts what is not there.
 *
 * RUN, not read: the page's own moveTo, its count and its row.
 */
'use strict';
const { extract, lift, liftAll, liftConst, test, ok, eq, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
const page = liftAll('waves.html', ['expand', 'moveTo', 'shownMachines', 'selectionCount', 'layoutWaveOf', 'renderFilters', 'allTagKeys', 'tagValuesFor']);
const machineRow = lift('waves.html', 'machineRow');

const id = (n) => `/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${n}`;
const A = id('l26-w3'), B = id('l26-w4'), C = id('l26-w1'), D = id('l26-w2');

/** A stand-in for the page's boxes: each keeps what the page wrote to it. */
function world({ waves = { 'new-wave': [], 'new-wave-2': [] }, scope = 'unassigned', search = '', avsets = {} } = {}) {
  const boxes = new Map();
  const box = (sel) => {
    if (!boxes.has(sel)) { boxes.set(sel, { textContent: '', innerHTML: '', style: { display: 'none' } }); }
    return boxes.get(sel);
  };
  globalThis.$ = box;
  globalThis.UX = UX;
  globalThis.esc = (s) => String(s ?? '');
  globalThis.entries = [A, B, C, D].map(v => ({ vmId: v, wave: null }));
  globalThis.layout = new Map(Object.entries(waves).map(([n, ids]) => [n, { vmIds: [...ids] }]));
  globalThis.selection = new Set();
  globalThis.filter = { search, scope, rg: '', tagKey: '', tagVal: '' };
  globalThis.started = () => false;
  globalThis.waveMigrating = () => false;
  globalThis.waveStarted = () => false;
  globalThis.avsetOf = (v) => avsets[v] ?? null;
  globalThis.vmName = (v) => v.split('/').pop();
  globalThis.rgOf = () => 'rg';
  globalThis.tagValue = () => '';
  globalThis.tagsOf = () => ({});
  globalThis.sizeMove = () => '';
  globalThis.newIdentity = () => false;
  globalThis.canEdit = true;
  globalThis.change = { vmId: null };
  globalThis.layoutWaveOf = page.layoutWaveOf;   // machineRow is lifted alone
  globalThis.renders = 0;
  globalThis.render = () => { globalThis.renders++; };
  return { box };
}

test('THE LAB: add a machine to wave 1, then Add selected on wave 2 - the first machine stays in wave 1', () => {
  world();
  selection.add(A);
  page.moveTo('new-wave', [...selection]);
  eq(selection.size, 0, 'machines still selected after Add selected machines');
  selection.add(B);
  page.moveTo('new-wave-2', [...selection]);
  eq(layout.get('new-wave').vmIds, [A], 'wave 1');
  eq(layout.get('new-wave-2').vmIds, [B], 'wave 2');
});

test('a machine selected in a wave and added to another wave: the page says it moves, and from where', () => {
  const { box } = world({ waves: { 'new-wave': [A], 'new-wave-2': [] } });
  selection.add(A);                       // a click on its row inside the wave card
  page.moveTo('new-wave-2', [...selection]);
  eq(layout.get('new-wave-2').vmIds, [A], 'wave 2');
  const said = box('#moved');
  ok(said.textContent.includes('l26-w3'), `the line names the machine: "${said.textContent}"`);
  ok(said.textContent.includes('new-wave-2'), `the line names the wave it goes to: "${said.textContent}"`);
  eq(said.textContent, UX.movedWave.replace('{name}', 'l26-w3').replace('{from}', 'new-wave').replace('{to}', 'new-wave-2'), 'the line');
  eq(said.style.display, 'block', 'the line is shown');
});

test('a machine from the list (in no wave) goes in with no line - nothing moved out of a wave', () => {
  const { box } = world();
  selection.add(A);
  page.moveTo('new-wave', [...selection]);
  eq(box('#moved').textContent, '', 'the line');
  eq(box('#moved').style.display, 'none', 'the line is hidden');
});

test('one line for each machine that leaves a wave, among others that do not', () => {
  const { box } = world({ waves: { 'new-wave': [A], 'new-wave-2': [C], 'w3': [] } });
  [A, B, C].forEach(v => selection.add(v));
  page.moveTo('w3', [...selection]);
  const text = box('#moved').textContent;
  ok(text.includes('l26-w3') && text.includes('l26-w1'), `both machines that left a wave are named: "${text}"`);
  ok(!text.includes('l26-w4'), `the machine from the list is not named: "${text}"`);
});

test('a machine already in the wave it is added to does not "move"', () => {
  const { box } = world({ waves: { 'new-wave': [A] } });
  selection.add(A);
  page.moveTo('new-wave', [...selection]);
  eq(box('#moved').textContent, '', 'the line');
  eq(layout.get('new-wave').vmIds, [A], 'wave 1');
});

test('an availability-set partner pulled out of another wave is named too', () => {
  const { box } = world({ waves: { 'new-wave': [B], 'new-wave-2': [] }, avsets: { [A]: 'av1', [B]: 'av1' } });
  selection.add(A);
  page.moveTo('new-wave-2', [...selection]);
  ok(box('#moved').textContent.includes('l26-w4'), `the partner is named: "${box('#moved').textContent}"`);
});

test('the next move takes the earlier line away', () => {
  const { box } = world({ waves: { 'new-wave': [A], 'new-wave-2': [] } });
  selection.add(A);
  page.moveTo('new-wave-2', [...selection]);
  ok(box('#moved').textContent, 'the first line');
  selection.add(B);
  page.moveTo('new-wave', [...selection]);
  eq(box('#moved').textContent, '', 'the line after a move from the list');
  eq(box('#moved').style.display, 'none', 'the line is hidden');
});

test('THE COUNT: a selected machine the list does not show is not counted as selected there, and is named', () => {
  world({ waves: { 'new-wave': [A] } });
  selection.add(A);   // in wave 1, so not in "Only machines not in a wave yet"
  selection.add(B);
  const text = page.selectionCount();
  ok(text.startsWith(`3 ${UX.showingCount} · 1 ${UX.selectedCount}`), `the count: "${text}"`);
  ok(text.includes(UX.selectedHidden.replace('{names}', 'l26-w3')), `the hidden machine is named: "${text}"`);
});

test('THE COUNT: a tick hidden by the name filter is named too', () => {
  world({ search: 'w4' });
  selection.add(C);
  const text = page.selectionCount();
  ok(text.startsWith(`1 ${UX.showingCount} · 0 ${UX.selectedCount}`), `the count: "${text}"`);
  ok(text.includes('l26-w1'), `the hidden machine is named: "${text}"`);
});

test('THE COUNT: with every selected machine in the list, nothing more is said', () => {
  world();
  selection.add(A);
  eq(page.selectionCount(), `4 ${UX.showingCount} · 1 ${UX.selectedCount}`, 'the count');
});

test('the count above the list is the one selectionCount gives', () => {
  const { box } = world({ waves: { 'new-wave': [A] } });
  selection.add(A);
  page.renderFilters();
  eq(box('#f-count').textContent, page.selectionCount(), 'the count the page shows');
  ok(box('#f-count').textContent.includes('l26-w3'), 'the count names the machine in the wave');
});

test('the list under Everything names the wave a machine is in NOW, not the one saved', () => {
  world({ waves: { 'new-wave': [A] }, scope: 'all' });
  entries[0].wave = 'old-wave';   // what the plan saved
  const html = machineRow(entries[0], false);
  ok(html.includes('new-wave'), 'the row names the wave the machine is in now');
  ok(!html.includes('old-wave'), 'the row does not name the saved wave');
  eq(page.layoutWaveOf(B), null, 'a machine in no wave');
});

/* The line says what the last move did, until the plan is saved or reset.
 * After that "Nothing changes until you save" is no longer true. */
test('a save takes the line away', async () => {
  const saver = liftAll('waves.html', ['writeLayout', 'save']);
  const { box } = world({ waves: { 'new-wave': [A], 'new-wave-2': [] } });
  selection.add(A);
  page.moveTo('new-wave-2', [...selection]);
  eq(box('#moved').style.display, 'block', 'the line before the save');
  Object.assign(globalThis, {
    dirty: () => false, inFlow: () => false, snapshot: () => 'x', original: 'x',
    buildLayoutFromPlan: () => {}, VmfHelp: { explainAction: (e) => String(e), markBusy: lift('help.js', 'markBusy') },
    runHref: () => 'about:blank', runSeg: () => 'run-1', runBody: (b) => b,
  });
  await saver.save();
  eq(box('#moved').style.display, 'none', 'the line after the save');
});

test('Reset takes the line away', () => {
  const start = extract('waves.html', 'start');
  ok(/buildLayoutFromPlan\(\); selection\.clear\(\); \$\('#moved'\)\.style\.display = 'none';/.test(start),
    'the reset in start() hides the line');
});

run('wave-editor-tick');
