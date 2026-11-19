/* MACHINE-PICK-1: the "Choose the machines" step of the wizard.
 *
 * A scan of a resource group, a subscription or a management group finds every
 * machine there, and many are not meant to move. This step comes before the
 * targets: nothing ticked at first, a machine that cannot move cannot be
 * ticked, four filters that combine, Add and Remove for every machine the
 * filters match, a page of rows with Show more, and Continue refused with no
 * machine chosen. The targets step then shows only the chosen machines.
 *
 * RUN, not read: the page's own functions are lifted and driven with machines
 * shaped like the assessment and the target advice, and the markup they draw
 * is what is measured.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  return eval('(' + m[1] + ')');   // eslint-disable-line no-eval
};
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');   // eslint-disable-line no-eval
globalThis.fill = constArrow('fill');
globalThis.M_PAGE = constArrow('M_PAGE');
globalThis.subOfId = constArrow('subOfId');
globalThis.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase() };
const STEP = liftConst('wizard.html', 'STEP');
const fns = liftAll('wizard.html', ['canChoose', 'chooseGroup', 'tagPairs', 'chooseRows', 'manaUpgradeText', 'anReleaseText', 'chooseMatches', 'chooseOptions',
  'chooseAdd', 'chooseRemove', 'chooseStart', 'onlyChosen', 'chooseFiltersHtml', 'chooseListHtml']);

const SUB_A = '00000000-0000-0000-0000-000000000000';
const SUB_B = '11111111-2222-3333-4444-555555555555';
const id = (sub, rg, name) => `/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Compute/virtualMachines/${name}`;
const vm = (sub, rg, name, extra) => Object.assign({ vmId: id(sub, rg, name), name, resourceGroup: rg, classification: 'ReadyAfterPrep',
  blockers: [], tags: {} }, extra || {});
const opt = (option, supported) => ({ option, supported });
const adv = (v, options) => ({ vmId: v.vmId, name: v.name, options });
// The estate: two subscriptions, the same tag in both, every assessment group.
const app = vm(SUB_A, 'rg-app', 'app-01', { tags: { app: 'storefront', env: 'prod' } });
const db = vm(SUB_A, 'rg-app', 'db-01', { tags: { app: 'billing', env: 'prod' } });
const legacy = vm(SUB_A, 'rg-old', 'legacy-01', { classification: 'Blocked', blockers: ['gen1-requires-redeploy'], tags: { app: 'billing' } });
const web = vm(SUB_B, 'rg-web', 'web-07', { tags: { app: 'storefront', env: 'test' } });
const old = vm(SUB_B, 'rg-web', 'old-03', { classification: 'Blocked', blockers: ['gen1-requires-redeploy', 'windows-version-below-2019'] });
const nvme = vm(SUB_B, 'rg-web', 'new-09', { classification: 'ReadyNow' });
const aks = vm(SUB_B, 'rg-aks', 'aks-node-1', { classification: 'Excluded', platformManaged: true });
const VMS = [app, db, legacy, web, old, nvme, aks];
const ADVICE = [adv(app, [opt('v5', true), opt('v6', true)]), adv(db, [opt('v6', true)]),
  adv(legacy, [opt('v5', true), opt('v6', false)]), adv(web, [opt('v6', true)]),
  adv(old, [opt('v5', false), opt('v6', false)]), adv(nvme, [opt('v6', false), opt('v7', false)]),
  adv(aks, [opt('v6', false)])];
const nameOf = (x) => x.split('/').pop();
// The review's rule, as VmfReport.canMigrate gives it for these machines: a
// series is open unless a finding closes every one (old-03's Windows version).
const canMigrate = (v) => v.classification !== 'Excluded' && !v.platformManaged && !(v.blockers ?? []).includes('windows-version-below-2019');
const ROWS = fns.chooseRows(VMS, ADVICE, nameOf, canMigrate);
const NONE = { sub: '', rg: '', tag: '', name: '' };
const subName = (s) => ({ [SUB_A]: 'Applications', [SUB_B]: 'Web' }[s] || s);
const row = (name) => ROWS.find(r => r.name === name);
// The list as drawn: each machine row, its cells as text, and its box.
const drawn = (html) => html.split('<tr>').slice(2).map(r => ({
  cells: [...r.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map(x => x[1].replace(/<[^>]+>/g, '').trim()),
  checked: /class="m-pick"[^>]* checked/.test(r), disabled: /class="m-pick"[^>]* disabled/.test(r),
}));

test('RUN: a machine that is Excluded or platform-managed is not listed; every other one is, with its assessment group', () => {
  eq(ROWS.map(r => r.name).sort(), ['app-01', 'db-01', 'legacy-01', 'new-09', 'old-03', 'web-07']);
  eq(row('app-01').group, 'can'); eq(row('legacy-01').group, 'some'); eq(row('old-03').group, 'cannot'); eq(row('new-09').group, 'can', 'an older ReadyNow (READY-NOW-REMOVE-1)');
  eq([UX.grpCan, UX.grpSome, UX.grpCannot], ['Can migrate', 'Some targets only', 'Cannot yet'], 'the words the review and the Assessments page use');
});

test('RUN: NOTHING is ticked at first, and the count says so', () => {
  const chosen = fns.chooseStart(null, ROWS);
  eq(chosen.size, 0);
  const html = fns.chooseListHtml(ROWS, chosen, NONE, 50, subName);
  const rows = drawn(html);
  eq(rows.length, 6);
  ok(rows.every(r => !r.checked), 'no box is ticked');
  ok(html.includes(fill(UX.mCount, { x: 0, y: 6 })), 'the count: 0 of 6');
});

test('RUN: a machine that cannot move on any series (Cannot yet) cannot be ticked, and the reason is on the row', () => {
  const rows = drawn(fns.chooseListHtml(ROWS, new Set(), NONE, 50, subName));
  const oldRow = rows.find(r => r.cells[1] === 'old-03');
  ok(oldRow.disabled, 'its box is off');
  eq(oldRow.cells[5], UX.grpCannot, 'the Assessment column says why');
  ok(rows.find(r => r.cells[1] === 'new-09').disabled, 'a machine already migrated cannot be ticked either');
  ok(!rows.find(r => r.cells[1] === 'legacy-01').disabled, 'some targets only CAN be ticked');
  ok(!fns.chooseAdd(new Set(), ROWS, NONE).has(old.vmId), 'and Add never takes it');
  ok(!fns.canChoose(ADVICE[4].options), 'a machine with no supported series cannot be chosen');
});

test('RUN: the columns are Machine, Subscription by its name, Resource group, Tags and Assessment', () => {
  const html = fns.chooseListHtml(ROWS, new Set(), NONE, 50, subName);
  const heads = [...html.match(/<thead>([\s\S]*?)<\/thead>/)[1].matchAll(/<th>([\s\S]*?)<\/th>/g)].map(x => x[1]);
  eq(heads, ['', UX.mColMachine, UX.mSub, UX.mRg, UX.mColTags, UX.mColAssess]);
  const w = drawn(html).find(r => r.cells[1] === 'web-07');
  eq(w.cells.slice(1), ['web-07', 'Web', 'rg-web', 'app=storefront, env=test', UX.grpCan]);
});

test('RUN: each filter narrows the list, and they combine', () => {
  eq(fns.chooseMatches(ROWS, { ...NONE, sub: SUB_B }).map(r => r.name), ['new-09', 'old-03', 'web-07'], 'subscription');
  eq(fns.chooseMatches(ROWS, { ...NONE, rg: 'rg-old' }).map(r => r.name), ['legacy-01'], 'resource group');
  eq(fns.chooseMatches(ROWS, { ...NONE, tag: 'app=storefront' }).map(r => r.name), ['app-01', 'web-07'], 'a tag matches in both subscriptions');
  eq(fns.chooseMatches(ROWS, { ...NONE, name: 'WEB' }).map(r => r.name), ['web-07'], 'find by name, any letter case');
  eq(fns.chooseMatches(ROWS, { ...NONE, sub: SUB_A, tag: 'app=billing' }).map(r => r.name), ['db-01', 'legacy-01'], 'subscription and tag');
  eq(fns.chooseMatches(ROWS, { sub: SUB_A, rg: 'rg-app', tag: 'app=billing', name: 'db' }).map(r => r.name), ['db-01'], 'all four');
  eq(fns.chooseMatches(ROWS, { ...NONE, sub: SUB_B, tag: 'app=billing' }).length, 0, 'nothing matches');
  ok(fns.chooseListHtml(ROWS, new Set(), { ...NONE, sub: SUB_B, tag: 'app=billing' }, 50, subName).includes(UX.mNoMatch), 'and it says so');
});

test('RUN: the resource group list narrows to the chosen subscription; the tag list does not', () => {
  eq(fns.chooseOptions(ROWS, NONE).rgs, ['rg-app', 'rg-old', 'rg-web']);
  eq(fns.chooseOptions(ROWS, { ...NONE, sub: SUB_A }).rgs, ['rg-app', 'rg-old']);
  eq(fns.chooseOptions(ROWS, { ...NONE, sub: SUB_A }).tags, fns.chooseOptions(ROWS, NONE).tags);
  const html = fns.chooseFiltersHtml(ROWS, { ...NONE, sub: SUB_A }, subName);
  ok(html.includes('>Applications</option>') && html.includes('>Web</option>'), 'subscriptions by their names');
  const rgList = html.match(/id="m-rg">([\s\S]*?)<\/select>/)[1];
  ok(rgList.includes('>rg-app<') && !rgList.includes('rg-web'), 'no resource group of another subscription');
  eq((html.match(/<select /g) || []).length, 3); ok(html.includes('id="m-find"'), 'three lists and a name box');
});

test('RUN: Add adds EVERY machine the filters match that can be ticked - not only the rows on screen', () => {
  // 120 machines in one resource group; a page shows 50.
  const many = Array.from({ length: 120 }, (_, i) => vm(SUB_A, 'rg-big', `big-${String(i).padStart(3, '0')}`));
  const rows = fns.chooseRows(many.concat([old]), many.map(v => adv(v, [opt('v6', true)])).concat([ADVICE[4]]), nameOf, canMigrate);
  const f = { ...NONE, rg: 'rg-big' };
  const html = fns.chooseListHtml(rows, new Set(), f, 50, subName);
  eq(drawn(html).length, 50, 'a page of rows');
  ok(html.includes(`>${fill(UX.mAddShown, { n: 120 })}<`), 'the button counts all 120');
  eq(fns.chooseAdd(new Set(), rows, f).size, 120);
  eq(fns.chooseAdd(new Set(), rows, NONE).size, 120, 'with no filter, every machine that can move - not old-03');
});

test('RUN: Remove takes out only the machines the filters match', () => {
  const all = fns.chooseAdd(new Set(), ROWS, NONE);
  eq(all.size, 4);
  const left = fns.chooseRemove(all, ROWS, { ...NONE, tag: 'app=storefront' });
  eq([...left].map(nameOf).sort(), ['db-01', 'legacy-01']);
});

test('RUN: Show more adds a page, Show fewer goes back to the first; nothing closes unless clicked', () => {
  const many = Array.from({ length: 120 }, (_, i) => vm(SUB_A, 'rg-big', `big-${String(i).padStart(3, '0')}`));
  const rows = fns.chooseRows(many, many.map(v => adv(v, [opt('v6', true)])), nameOf, canMigrate);
  const at = (shown) => fns.chooseListHtml(rows, new Set(), NONE, shown, subName);
  ok(at(50).includes('id="m-more"') && !at(50).includes('id="m-fewer"'), 'first page: Show more only');
  eq(drawn(at(100)).length, 100);
  ok(at(100).includes('id="m-more"') && at(100).includes('id="m-fewer"'), 'second page: both');
  ok(!at(150).includes('id="m-more"') && at(150).includes('id="m-fewer"'), 'all shown: Show fewer only');
  eq(drawn(at(150)).length, 120);
  ok(!fns.chooseListHtml(ROWS, new Set(), NONE, 50, subName).includes('id="m-more"'), 'a short list has neither');
  ok(WIZ.includes("if (e.key === 'Escape' && journey === 'migrate' && step === STEP.migrate.choose && mShown > M_PAGE) { mShown = M_PAGE; render(); }"),
    'Escape goes back to the first page (rule 11)');
});

test('RUN: a saved list is where the ticks start; with none, nothing is ticked', () => {
  eq([...fns.chooseStart({ machines: [db.vmId.toUpperCase()] }, ROWS)], [db.vmId], 'the saved list, in any letter case');
  // OLD-VERSION-READERS-REMOVE-6: the wizard saves the list before any target,
  // so saved targets never stand for it.
  eq(fns.chooseStart(null, ROWS).size, 0, 'no list: nothing ticked');
  eq(fns.chooseStart.length, 2, 'the saved targets are not asked');
  eq(fns.chooseStart({ machines: [old.vmId] }, ROWS).size, 0, 'a machine that can no longer move is not ticked');
});

// ---------- Continue ----------
const saveMachines = () => lift('wizard.html', 'saveMachines')();
function saveRig({ chosen = [], saved = null, refuse = false } = {}) {
  const calls = [];
  Object.assign(globalThis, {
    STEP, step: STEP.migrate.choose, DEMO_MODE: false, mRefused: false, mChosen: new Set(chosen),
    machineChoices: saved, machinesVersion: saved ? 'm1' : '', adviceVersion: 'a1',
    $: () => ({ disabled: false }), clearErr: () => {}, runSeg: () => 'p/r', runBody: (b) => b, runPrefix: () => 'p/r',
    location: { href: 'https://example.com/wizard.html?run=r&plan=1&step=choose' },
    history: { replaceState: (_s, _t, u) => calls.push(`address ${new URL(String(u)).searchParams.get('step')}`) },
    api: async (method, where, body) => { calls.push(`save ${where}`); calls.body = body; if (refuse) throw new Error('409: x'); },
    said: () => calls.push('said'), readRun: async () => calls.push('read'),
    render: () => calls.push('render'), failAction: (e) => calls.push(`error ${e.message}`),
    // WIZARD-BACK-TARGETS-1: Continue is a step the person chose.
    stepChosen: false, goStep: lift('wizard.html', 'goStep'),
  });
  return calls;
}

test('RUN: Continue with no machine chosen is refused on the screen, and nothing is saved', async () => {
  const calls = saveRig();
  await saveMachines();
  eq(calls, ['render'], 'no save, the step is drawn again');
  ok(globalThis.mRefused, 'with the refusal');
  eq(globalThis.step, STEP.migrate.choose, 'still on this step');
  const html = WIZ.slice(WIZ.indexOf('function renderChoose('), WIZ.indexOf('function paintChooseList('));
  ok(html.includes('${mRefused ? `<p class="m-none" id="m-none" role="alert">${esc(UX.mNone)}</p>` : \'\'}'), 'drawn inline, by the button');
});

test('RUN: Continue saves the list with both versions the service issued, then goes to the targets', async () => {
  const calls = saveRig({ chosen: [app.vmId, legacy.vmId] });
  await saveMachines();
  eq(calls.slice(0, 3), ['save assessments/p/r/machines', 'said', 'read']);
  eq(calls.body, { machines: [app.vmId, legacy.vmId], adviceVersion: 'a1', machinesVersion: '' });
  // Review finding 7: the address names the targets step, so a reload stays there.
  ok(calls.includes('address targets'), calls.join(' | '));
  eq(globalThis.step, STEP.migrate.targets);
});

test('RUN: the same list as the saved one is not saved again - the targets saved against it stay bound', async () => {
  const calls = saveRig({ chosen: [app.vmId], saved: { machines: [app.vmId.toUpperCase()] } });
  await saveMachines();
  ok(!calls.some(c => c.startsWith('save')), calls.join(' | '));
  eq(globalThis.step, STEP.migrate.targets);
});

test('RUN: a refused save stays on the step and says why', async () => {
  const calls = saveRig({ chosen: [app.vmId], refuse: true });
  await saveMachines();
  ok(calls.includes('error 409: x'));
  eq(globalThis.step, STEP.migrate.choose);
});

test('Back on this step goes to the assessment; Back on the targets step comes here', () => {
  const choose = WIZ.slice(WIZ.indexOf('function renderChoose('), WIZ.indexOf('function paintChooseList('));
  ok(choose.includes("$('#b').addEventListener('click', backToAssessment);"));
  const targets = WIZ.slice(WIZ.indexOf('function renderTargets('), WIZ.indexOf('function targetChoicesBody('));
  ok(targets.includes("$('#b').addEventListener('click', toChoose);"));
  const toChoose = WIZ.slice(WIZ.indexOf('function toChoose('), WIZ.indexOf('function toChoose(') + 300);
  ok(toChoose.includes("url.searchParams.set('step', 'choose')") && toChoose.includes('goStep(STEP.migrate.choose)'), 'and names the step in the address');
});

// ---------- the targets step, after ----------
test('RUN: the targets step and Export for pricing show ONLY the chosen machines', () => {
  eq(fns.onlyChosen(ADVICE, { machines: [db.vmId, legacy.vmId] }).map(m => m.name), ['db-01', 'legacy-01'], 'the list');
  // OLD-VERSION-READERS-REMOVE-6: saved targets never stand for the list.
  eq(fns.onlyChosen(ADVICE, null), [], 'no list: none');
  eq(fns.onlyChosen.length, 2, 'the saved targets are not asked');
  // The page's own tMachines, and the areas it draws from it.
  Object.assign(globalThis, { onlyChosen: fns.onlyChosen, targetAdvice: { machines: ADVICE }, machineChoices: { machines: [db.vmId] }, targetChoices: { choices: [{ vmId: app.vmId }] } });
  const tMachines = lift('wizard.html', 'tMachines');
  eq(tMachines().map(m => m.name), ['db-01']);
  const body = WIZ.slice(WIZ.indexOf('function renderTargets('), WIZ.indexOf('function targetChoicesBody('));
  ok(body.includes('const machines = tMachines();') && !body.includes('targetAdvice.machines'), 'renderTargets draws tMachines');
  const exp = WIZ.slice(WIZ.indexOf('async function exportTargets('), WIZ.indexOf('let tHelp = new Set();'));
  ok(!exp.includes('targetAdvice?.machines') && (exp.match(/tMachines\(\)/g) || []).length === 2, 'both exports read tMachines');
});

test('the rail starts with this step, and the step numbers follow it', () => {
  eq(STEP.migrate, { choose: 1, targets: 2, group: 3, waves: 4, run: 5 });
  const help = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
  ok(help.includes("const MIGRATE_STEPS = ['Choose the machines', 'Choose each target', 'How to group them', 'Arrange the waves', 'Run it'];"));
  const waves = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
  ok(waves.includes('VmfHelp.stepRail(VmfHelp.MIGRATE_STEPS, 4)'), 'the wave editor is the fourth');
});

test('the sample has a run that opens on this step and one that opens on the targets', () => {
  const shots = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
  ok(shots.includes("wizard.html?demo&run=demo-scan&plan=1") && shots.includes("wizard.html?demo&run=demo-chosen&plan=1"));
  ok(WIZ.includes("DEMO['demo-chosen/machine-choices.json'] = { machines:"));
});

test('RUN: the Assessment column is the group of the review; a machine the review clears but the target options give no size cannot be ticked, and says why (review finding 5)', () => {
  // The review clears it (no finding), but its region catalog was not read: no supported option.
  const unread = vm(SUB_A, 'rg-app', 'unread-01');
  const rows = fns.chooseRows([unread], [adv(unread, [opt('v5', false), opt('v6', false)])], nameOf, canMigrate);
  eq(rows[0].group, 'can', 'the review says it can migrate');
  ok(!rows[0].tickable, 'the options give it nothing to choose');
  const r = drawn(fns.chooseListHtml(rows, new Set(), NONE, 50, subName))[0];
  ok(r.disabled, 'its box is off');
  eq(r.cells[5], UX.grpCan + UX.mNoOption, 'the column says Can migrate, and the reason it cannot be chosen is on the row');
  ok(!drawn(fns.chooseListHtml(ROWS, new Set(), NONE, 50, subName)).find(x => x.cells[1] === 'old-03').cells[5].includes(UX.mNoOption), 'Cannot yet needs no second reason');
});

test('RUN: a resource group is offered once, whatever the letter case (review note)', () => {
  const a = vm(SUB_A, 'rg-App', 'a-01'), b = vm(SUB_A, 'rg-app', 'b-01');
  const rows = fns.chooseRows([a, b], [adv(a, [opt('v6', true)]), adv(b, [opt('v6', true)])], nameOf, canMigrate);
  eq(fns.chooseOptions(rows, NONE).rgs.length, 1);
  eq(fns.chooseMatches(rows, { ...NONE, rg: fns.chooseOptions(rows, NONE).rgs[0] }).length, 2, 'and the one entry finds both');
});

test('RUN: an assessment with no machine to list says so, not "no machine matches these filters" (review finding 6)', () => {
  const html = fns.chooseListHtml([], new Set(), NONE, 50, subName);
  ok(html.includes(UX.mEmpty) && !html.includes(UX.mNoMatch), html);
});

// Review finding 10: the buttons and boxes are wired as they say. RUN: the
// page's own paintChooseList, with a stand-in for the page.
test('RUN: Add, Remove, Show more, Show fewer and a box each do their own job', () => {
  const els = {};
  const el = (id) => (els[id] ??= { id, innerHTML: '', listeners: {}, addEventListener(e, fn) { this.listeners[e] = fn; }, remove() {} });
  const many = Array.from({ length: 60 }, (_, i) => vm(SUB_A, i < 30 ? 'rg-a' : 'rg-b', `m-${String(i).padStart(2, '0')}`));
  const rows = fns.chooseRows(many, many.map(v => adv(v, [opt('v6', true)])), nameOf, canMigrate);
  let boxes = [];
  Object.assign(globalThis, {
    // A button the list did not draw is not there, as on the page.
    $: (sel) => (['#m-more', '#m-fewer'].includes(sel) && !els['#m-list'].innerHTML.includes(`id="${sel.slice(1)}"`)) ? null : el(sel),
    document: { querySelectorAll: (q) => q === '.m-pick' ? boxes : [] },
    mRows: rows, mChosen: new Set(), mFilter: { ...NONE, rg: 'rg-b' }, mShown: M_PAGE, mRefused: false,
    subDisplayName: subName, chooseListHtml: fns.chooseListHtml, chooseAdd: fns.chooseAdd, chooseRemove: fns.chooseRemove,
    // CLAIM-AT-PLAN-1: the held machines were read, and none is held.
    chooseHeldNote: lift('wizard.html', 'chooseHeldNote'), mHeld: new Map(),
    // WIZARD-ROLES-3: an operator, who may change the list.
    canOperate: true, lockChoices: lift('wizard.html', 'lockChoices'),
  });
  el('#m-list');
  const paint = lift('wizard.html', 'paintChooseList');
  globalThis.paintChooseList = () => {
    paint();
    boxes = [...els['#m-list'].innerHTML.matchAll(/class="m-pick" data-vm="([^"]+)"/g)].map(m => ({ dataset: { vm: m[1] }, checked: false, listeners: {}, addEventListener(e, fn) { this.listeners[e] = fn; } }));
    paint();
  };
  globalThis.paintChooseList();
  els['#m-add'].listeners.click();
  eq(globalThis.mChosen.size, 30, 'Add: the 30 machines of rg-b');
  ok([...globalThis.mChosen].every(x => x.includes('/rg-b/')), 'and only those');
  globalThis.mFilter = { ...NONE, name: 'm-5' };
  els['#m-remove'].listeners.click();
  eq(globalThis.mChosen.size, 20, 'Remove: m-50 to m-59 out, the rest kept');
  globalThis.mFilter = { ...NONE };
  globalThis.paintChooseList();
  const box = boxes.find(b => b.dataset.vm.endsWith('/m-00'));
  box.checked = true; box.listeners.change();
  ok(globalThis.mChosen.has(box.dataset.vm), 'a ticked box adds its machine');
  box.checked = false; box.listeners.change();
  ok(!globalThis.mChosen.has(box.dataset.vm), 'and an unticked one takes it out');
  globalThis.paintChooseList();
  els['#m-more'].listeners.click();
  eq(globalThis.mShown, 2 * M_PAGE, 'Show more adds a page');
  globalThis.paintChooseList();
  els['#m-fewer'].listeners.click();
  eq(globalThis.mShown, M_PAGE, 'Show fewer goes back to the first');
});
// Mutation R14 survived without this: nothing drew the step itself. RUN: the
// page's own renderChoose, with a stand-in for the page.
test('RUN: the step counts every machine the assessment found, in how many subscriptions, and wires Back and Continue', () => {
  const els = {};
  const el = (id) => (els[id] ??= { id, listeners: {}, addEventListener(e, fn) { this.listeners[e] = fn; } });
  const back = () => 'back', save = () => 'save';
  Object.assign(globalThis, {
    $: el, card: (title, body, inner) => `<h2>${title}</h2><p>${body}</p>${inner}`,
    targetAdvice: { machines: ADVICE }, assessment: { vms: VMS }, vmName: nameOf,
    window: { VmfReport: { canMigrate } }, machineChoices: null, targetChoices: null,
    machinesVersion: '', choicesVersion: '', adviceVersion: 'a1', mLoadedFrom: null, mChosen: new Set(), mRefused: false,
    mFilter: { ...NONE }, mShown: M_PAGE, mRows: [], chooseRows: fns.chooseRows, chooseStart: fns.chooseStart,
    chooseFiltersHtml: fns.chooseFiltersHtml, chooseOptions: fns.chooseOptions, subDisplayName: subName,
    paintChooseList: () => {}, backToAssessment: back, saveMachines: save, renderAdviceWait: () => { throw new Error('no wait'); },
    // CLAIM-AT-PLAN-1: the rows as the held machines say, and the read of them.
    chooseRowsNow: lift('wizard.html', 'chooseRowsNow'), mHeld: undefined, readHeld: () => {},
    // WIZARD-ROLES-2: the step's action is drawn on the role; an operator here.
    roleAction: lift('wizard.html', 'roleAction'), canOperate: true,
  });
  const target = { innerHTML: '' };
  lift('wizard.html', 'renderChoose')(target);
  // Seven machines found in two subscriptions; six are listed (aks-node-1 is not eligible).
  ok(target.innerHTML.includes(`<p>${fill(UX.mBody, { n: 7, subs: 2 })}</p>`), target.innerHTML.slice(0, 200));
  eq(globalThis.mRows.length, 6, 'the list leaves out the machine that is not eligible');
  eq(globalThis.mChosen.size, 0, 'nothing ticked');
  eq(els['#b'].listeners.click, back, 'Back goes to the assessment');
  eq(els['#m-continue'].listeners.click, save, 'Continue saves the machines');
});
test('WIZARD-ROLES-3: RUN: a user without the operator role reads the list and changes nothing', () => {
  const lockChoices = lift('wizard.html', 'lockChoices');
  const found = [];
  const fake = (sel) => ({ querySelectorAll: (q) => { found.push(q); return q === sel ? [box1, box2] : []; } });
  const box1 = { disabled: false }, box2 = { disabled: false };
  lockChoices(fake('.m-pick, #m-add, #m-remove'), '.m-pick, #m-add, #m-remove');
  ok(box1.disabled && box2.disabled, 'every choice it finds is turned off');
  lockChoices(null, 'input');   // a step not drawn yet: nothing to do, and no error
  // The list paints through it for a non-operator, and only then.
  const fs = require('fs');
  const page = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  ok(page.includes("if (!canOperate) { lockChoices(list, '.m-pick, #m-add, #m-remove'); }"), 'Choose the machines locks its boxes and its Add and Remove');
  ok(page.includes("if (!canOperate) { lockChoices(el, 'input, select, [data-kall]'); }"), 'Choose each target locks every choice, the kernel All buttons too');
  ok(/data-kall=/.test(page), 'and those buttons are still drawn with that attribute');
  ok(!/lockChoices\([^)]*(m-more|m-fewer|m-find|t-help)/.test(page), 'Show more, the filters and help stay on');
});
// AN-MANA-DRIVER-RULE-1: an Intel Linux machine whose release has no MANA
// driver possible has no target, so it cannot be chosen. Its row says which
// release to upgrade to, in place of the general line.
test('a machine with no MANA driver possible says which release to upgrade to', () => {
  const v = vm(SUB_A, 'rg-app', 'nomana-01');
  const a = { vmId: v.vmId, name: v.name, os: 'Linux', options: [
      { option: 'v5', supported: false, notSupported: ['no-mana-driver'] }, { option: 'v6', supported: false, notSupported: ['no-mana-driver'] }],
    linuxRelease: { distroId: 'ubuntu', version: '18.04', source: 'agent', mana: 'unlisted', manaUpgrade: { distroId: 'ubuntu', version: '22.04' } } };
  const rows = fns.chooseRows([v], [a], nameOf, canMigrate);
  eq(rows[0].tickable, false);
  const html = fns.chooseListHtml(rows, new Set(), NONE, 50, subName);
  ok(html.includes(esc(fill(UX.tManaUpgrade, { release: 'Ubuntu 18.04', upgrade: 'Ubuntu 22.04' }))), html);
  ok(!html.includes(esc(UX.mNoOption)), 'not the general line');
  // Another machine with no option keeps the general line.
  const other = fns.chooseRows([v], [{ vmId: v.vmId, name: v.name, options: [{ option: 'v5', supported: false, notSupported: ['not-in-region'] }] }], nameOf, canMigrate);
  ok(fns.chooseListHtml(other, new Set(), NONE, 50, subName).includes(esc(UX.mNoOption)));
});run('choose-step');
