/* SCOPE-PICK-1: a scan can name SEVERAL resource groups.
 *
 * The scan step offered one resource group, whole subscriptions, or a
 * management group. A real estate is spread across several groups - the demo
 * estate is six on purpose, because that is what makes grouping by resource
 * group provable - and it fitted none of those. Taking the subscription to
 * reach six groups reads every machine in it, including the ones the customer
 * did not ask about, and then plans waves over them.
 *
 * The layers underneath took a list already: `Invoke-VmfAssessment` has always
 * taken `ResourceGroups` as an array, and SCOPE-RG-LIST-1 made the engine
 * setting and the service agree with it. This is the picker.
 *
 * These drive the page's own startScan, because what matters is the BODY it
 * sends - a page that shows three ticks and posts one name is the defect.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const startScan = lift('wizard.html', 'startScan');

/** Only what startScan touches, with the boxes a person ticked. */
function page(ticked, opts) {
  const options = opts || {};
  const sent = [];
  const fields = {
    '#f-name': { value: options.name ?? 'scan-2026-09-16' },
    '#f-sub': { value: options.sub ?? '/subscriptions/sub-1' },
    '#err': { style: {}, textContent: '' },
    '#go1': { disabled: false },
  };
  global.$ = (sel) => fields[sel] ?? { value: '', style: {}, disabled: false, textContent: '' };
  global.document = {
    querySelectorAll: (sel) => (sel === 'input[name=f-rgs]:checked'
      ? ticked.map(v => ({ value: v }))
      : []),
  };
  global.UX = {
    runNameBad: 'That name will not do.',
    runNameTaken: 'A run called {name} is already here.',
    scopeMissing: 'Choose where to look first.',
  };
  global.form = { scopeType: options.scopeType ?? 'rg', sub: '', rgs: [], subs: [], mg: '' };
  global.projectId = options.projectId ?? 'proj';
  global.runId = null;
  global.step = 1;
  global.STEP = { assess: { findings: 3 } };
  global.blobJson = async () => null;              // the name is not taken
  global.api = async (method, path, body) => { sent.push({ method, path, body }); };
  global.VmfHelp = {
    VmfRun: {
      storePath: (project, run) => (project ? `${project}/${run}` : run),
      routeSegment: (id) => encodeURIComponent(String(id).split('/').pop()),
      withProject: (body, id) => {
        const cut = String(id).indexOf('/');
        return cut > 0 ? { ...body, project: String(id).slice(0, cut) } : body;
      },
    },
  };
  global.history = { replaceState() { } };
  global.location = { href: 'https://localhost/wizard.html', search: '' };
  global.runHref = () => 'wizard.html';
  global.render = () => { };
  global.startPolling = () => { };
  global.failAction = (e) => { sent.push({ failed: e && e.message ? e.message : String(e) }); };
  return { sent };
}

test('THE DEFECT: three ticked groups are all sent, not one', async () => {
  const view = page(['rg-payments', 'rg-reporting', 'rg-core']);
  await startScan();
  const post = view.sent.find(s => s.path && s.path.includes('/engine/assess'));
  ok(post, `no scan was started: ${JSON.stringify(view.sent)}`);
  ok(Array.isArray(post.body.scopeRg), 'scopeRg must be a list, because the service takes one');
  eq(post.body.scopeRg.join(','), 'rg-payments,rg-reporting,rg-core', 'the groups that were ticked');
});

test('one ticked group still works, because that is the common case', async () => {
  const view = page(['rg-core']);
  await startScan();
  const post = view.sent.find(s => s.path && s.path.includes('/engine/assess'));
  eq(post.body.scopeRg.join(','), 'rg-core', 'the one group');
  eq(post.body.scopeSubs.join(','), '/subscriptions/sub-1', 'and the subscription it is in');
});

test('and none ticked is refused, rather than scanning the whole subscription', async () => {
  // The worst possible failure here is a scan that quietly widens. Reading
  // every machine in a work subscription is exactly what the allowlist exists
  // to avoid.
  const view = page([]);
  await startScan();
  const post = view.sent.find(s => s.path && s.path.includes('/engine/assess'));
  ok(!post, 'a scan was started with no resource group chosen');
  ok(view.sent.some(s => s.failed && s.failed.includes('Choose where to look')), 'it must say so');
});

test('the ticks on SCREEN win, not what was remembered', async () => {
  // Changing subscription redraws the list. What the person can see is what
  // they mean, and a remembered tick from another subscription is not that.
  const view = page(['rg-now']);
  global.form.rgs = ['rg-from-the-last-subscription'];
  await startScan();
  const post = view.sent.find(s => s.path && s.path.includes('/engine/assess'));
  eq(post.body.scopeRg.join(','), 'rg-now', 'what is ticked now');
});

test('choosing whole subscriptions instead is untouched', async () => {
  const view = page([], { scopeType: 'subs' });
  global.document.querySelectorAll = (sel) => (sel === 'input[name=f-subs]:checked'
    ? [{ value: '/subscriptions/sub-1' }, { value: '/subscriptions/sub-2' }]
    : []);
  await startScan();
  const post = view.sent.find(s => s.path && s.path.includes('/engine/assess'));
  ok(post, 'the subscription route must still start a scan');
  eq(post.body.scopeSubs.length, 2, 'both subscriptions');
  ok(!post.body.scopeRg, 'and no resource group allowlist');
});

run('scan-scope');
