/* RETRY-SERIES-1: a machine that rolled back, given another size series so it
 * can be tried again on it - on the run page, beside the machine (owner,
 * 2026-09-28).
 *
 * RUN, not read: the page's own retrySeriesOptions, fillRetrySeries and
 * askRetrySeries.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
// MACHINE-PANEL-STALE-1: the page's own answer cache, which fillRetrySeries keeps.
globalThis.retrySeriesCache = null;
// DIALOG-STALE-1: a series button opens its dialog through panelDialog.
globalThis.modalMachine = null;
const page = liftAll('migrations.html', ['retrySeriesOptions', 'fillRetrySeries', 'askRetrySeries', 'panelDialog']);

// What the service answers for a machine planned on v6 that may also take v5.
const ANSWER = {
  Current: 'v6', PlanVersion: 'ver-1',
  Options: [
    { option: 'v5', current: false, supported: true, targetSize: 'Standard_D2ds_v5' },
    { option: 'v6', current: true, supported: true, targetSize: 'Standard_D2ds_v6' },
    { option: 'v7', current: false, supported: false, targetSize: null },
  ],
};

function world(answer = ANSWER, { fails, swapSlot } = {}) {
  const listeners = [];
  const slot = {
    innerHTML: '',
    querySelectorAll: () => {
      const found = [...slot.innerHTML.matchAll(/data-retryseries="([^"]+)"/g)].map(m => ({
        dataset: { retryseries: m[1] },
        addEventListener: (_e, fn) => listeners.push({ series: m[1], fn }),
      }));
      return found;
    },
  };
  const calls = [];
  const w = { slot, listeners, calls, modal: null };
  globalThis.UX_ACT = UX_ACT;
  globalThis.esc = (s) => String(s ?? '');
  globalThis.runSeg = () => 'run-1';
  // swapSlot: the panel shows another machine by the time the service answers.
  let asked = 0;
  globalThis.$ = (sel) => (sel === '#retryseries-slot' ? ((swapSlot && asked++ > 0) ? { innerHTML: '' } : slot) : null);
  globalThis.apiFetch = async (p, body) => {
    calls.push({ p, body });
    if (fails) throw new Error(fails);
    return body.preview ? answer : {};
  };
  globalThis.VmfHelp = { explainAction: (e) => String(e && e.message ? e.message : e) };
  globalThis.openModal = (m) => { w.modal = m; };
  return w;
}

test('only a series the machine may take, and not the one it has', () => {
  eq(page.retrySeriesOptions(ANSWER).map(o => o.option).join(','), 'v5');
  eq(page.retrySeriesOptions({}).length, 0, 'no answer offers nothing');
});

test('the buttons come from the service, asked for a rolled-back machine', async () => {
  const w = world();
  await page.fillRetrySeries('vm-1');
  eq(w.calls.length, 1);
  eq(w.calls[0].p, 'runs/run-1/plan/target');
  ok(w.calls[0].body.preview === true && w.calls[0].body.afterRollback === true, JSON.stringify(w.calls[0].body));
  ok(w.slot.innerHTML.includes(UX_ACT.retrySeries.replace('{series}', 'v5')), w.slot.innerHTML);
  ok(!w.slot.innerHTML.includes('data-retryseries="v6"'), 'never the series it has');
  ok(!w.slot.innerHTML.includes('data-retryseries="v7"'), 'never a series it may not take');
});

test('a machine with no other series shows no button', async () => {
  const w = world({ Current: 'v6', Options: [{ option: 'v6', current: true, supported: true, targetSize: 'Standard_D2ds_v6' }] });
  await page.fillRetrySeries('vm-1');
  eq(w.slot.innerHTML, '');
});

test('the button confirms, then sends the series and the plan version it was shown, and says what comes next', async () => {
  const w = world();
  await page.fillRetrySeries('vm-1');
  w.listeners.find(l => l.series === 'v5').fn();
  ok(w.modal, 'a dialog opens - it has Cancel and Escape');
  eq(w.modal.title, UX_ACT.retrySeries.replace('{series}', 'v5'));
  ok(w.modal.desc.includes('D2ds_v5') && !w.modal.desc.includes('Standard_'), w.modal.desc);
  eq(w.modal.doneMessage, UX_ACT.retrySeriesDone);
  await w.modal.onConfirm({});
  const sent = w.calls[1].body;
  eq(JSON.stringify(sent), JSON.stringify({ vmId: 'vm-1', option: 'v5', planVersion: 'ver-1', afterRollback: true }));
});

test('a refusal is said in place of the buttons - a reservation held, another machine migrating', async () => {
  const w = world(ANSWER, { fails: '400: Wave w1 is running (vm-2 is CONVERTING), so the target of vm-1 cannot change now.' });
  await page.fillRetrySeries('vm-1');
  ok(w.slot.innerHTML.includes('Wave w1 is running'), w.slot.innerHTML);
  ok(!w.slot.innerHTML.includes('data-retryseries'), 'no button');
});

test('an answer for a machine the panel no longer shows is dropped', async () => {
  const w = world(ANSWER, { swapSlot: true });
  await page.fillRetrySeries('vm-1');
  eq(w.slot.innerHTML, '', 'the old slot is not written');
});

test('offered only beside a machine that rolled back, and only where Retry is', () => {
  ok(PAGE.includes("const retrySlot = ((doc.state === 'FAILED_ROLLED_BACK' && offer.retry) ||"), 'the slot is only for a rolled-back machine');
  // ROLLBACK-SIZE-REFUSED-SERIES-1: and for a machine whose rollback Azure
  // refused its original size, for an operator (the engine takes that stop).
  ok(PAGE.includes("(doc.state === 'FAILED_NEEDS_ATTENTION' && lastStopEntry(doc)?.reasonCode === 'rollbackSizeRefused' && canOperate()))"), 'and the size Azure refused');
  ok(PAGE.includes('${resolveBtn}${retrySlot}'), 'beside Retry');
});

run('retry-series');
