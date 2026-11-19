/* DOC-4: the manual's screenshots, taken from the dashboard's own pages in
 * sample-data mode, by a headless browser driven over the DevTools protocol.
 *
 * Why not a hand-taken picture: a screenshot that nobody can re-take drifts
 * from the product the moment a screen changes, and a manual whose pictures
 * disagree with the screen is worse than one with no pictures. This is
 * re-run by tools/Export-VmfManualScreenshots.ps1 whenever a page changes.
 *
 * No dependencies: Node 22+ has a WebSocket client built in, and Microsoft
 * Edge is on every Windows machine. Usage (the PowerShell wrapper does this):
 *   node tools/manual-shots.js <edge.exe> <base url> <out dir> [file.png,...]
 *
 * MANUAL-SHOTS-1: the optional last argument names the pictures to take, comma
 * separated, so one shot can be re-taken while it is being written.
 */
'use strict';
const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// SHOTS-EDGE-LEAK-1: Edge starts about ten processes (browser, renderers, GPU,
// crash handler), and on Windows the process this script spawns is only a
// starter: it hands off to the real browser and exits, so the browser's parent
// is gone and neither kill() nor a process-tree kill reaches it. Every run left
// its Edge behind: 460 headless Edge processes and 5 GB on 2026-11-07, slowing
// every suite on the machine. MEASURED the same day: a tree kill of the spawned
// id still left 18. So: ask the browser to close over its debugging connection
// (Browser.close), then stop every Edge process still using THIS run's profile
// folder, which no other run shares. Both run on any exit of this script.
function stopEdgeByProfile(profile) {
  if (!profile) return;
  const name = path.basename(profile);
  if (!/^vmf-shots-[A-Za-z0-9]+$/.test(name)) return;
  try {
    if (process.platform === 'win32') {
      const ps = "Get-CimInstance Win32_Process -Filter \"Name='msedge.exe'\" | Where-Object { $_.CommandLine -like '*" + name + "*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }";
      execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { stdio: 'ignore', timeout: 30000 });
    } else {
      execFileSync('pkill', ['-9', '-f', name], { stdio: 'ignore' });
    }
  } catch { /* nothing left to stop */ }
}

async function closeBrowser(port) {
  if (!port) return;
  try {
    const info = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const ws = new WebSocket(info.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(rej, 3000); });
    ws.send(JSON.stringify({ id: 1, method: 'Browser.close' }));
    await new Promise(res => setTimeout(res, 500));
    try { ws.close(); } catch { /* closed by the browser */ }
  } catch { /* the profile sweep below still runs */ }
}

// SHOTS-EDGE-LEAK-1: a fixed debugging port let a second run, started by another
// builder at the same time, attach to the FIRST run's Edge and drive its page.
// Port 0 lets Edge pick a free port, which it writes to DevToolsActivePort.
async function readDevToolsPort(profile, sleepFn) {
  const file = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100; i++) {
    try {
      const first = fs.readFileSync(file, 'utf8').split(/\r?\n/)[0].trim();
      if (/^\d+$/.test(first) && Number(first) > 0) return Number(first);
    } catch { /* not written yet */ }
    await sleepFn(100);
  }
  return 0;
}

// SHOT-CLOCK-1: a picture taken again must be the same picture unless the
// screen changed. The sample pages build their dates from the clock ("5m ago",
// "Next cleanup" with today's date), and the Migrations header line
// "Updated ... next in ...s" appeared only after the page's one-second timer
// ran - so it was in some pictures and not in others. SAMPLE-COUNTS-1 took six
// pictures again and five differed only by that.
//
// So every page gets one fixed date and time, time zone and locale. The date
// is after every fixed time in the sample data (the latest is 2026-11-06 10:05),
// and the sample builds its other times back from "now", so they read as they
// did. The clock does not move while the page is open: "Updated 0s ago" is the
// same in every picture. And a repeating timer (setInterval) runs its first
// pass once, then holds, and each picture waits for every first pass: the
// header line is always there, and always counts from the same pass.
//
// Where a page waits with a deadline on the clock (help.js watch), the deadline
// never comes under this clock. No picture opens one: a picture that did would
// wait, and is a picture to fix.
const SHOT_CLOCK = { at: '2026-11-06T15:00:00.000Z', timezone: 'UTC', locale: 'en-US' };

/** The script every page runs before its own: the fixed clock, and the
 *  repeating timers that run once. `window.__vmfShotClock.pending` is the
 *  number of first passes still to run. */
function shotClockScript(atIso) {
  const fixed = Date.parse(atIso);
  if (!Number.isFinite(fixed)) throw new Error(`the clock for the pictures is not a date: ${atIso}`);
  return `(() => {
  const FIXED = ${fixed};
  const RealDate = Date;
  function ShotDate(...a) {
    if (!new.target) return new RealDate(FIXED).toString();
    return a.length ? new RealDate(...a) : new RealDate(FIXED);
  }
  ShotDate.prototype = RealDate.prototype;
  ShotDate.now = () => FIXED;
  ShotDate.parse = RealDate.parse;
  ShotDate.UTC = RealDate.UTC;
  Object.defineProperty(ShotDate, 'name', { value: 'Date' });
  globalThis.Date = ShotDate;
  const clock = { pending: 0 };
  const firstPass = new Set();
  const realSetTimeout = globalThis.setTimeout, realClearTimeout = globalThis.clearTimeout;
  const done = (id) => { if (firstPass.delete(id)) clock.pending -= 1; };
  globalThis.setInterval = function (fn, ms, ...args) {
    const id = realSetTimeout(() => {
      done(id);
      if (typeof fn === 'function') fn(...args); else (0, eval)(String(fn));
    }, ms);
    firstPass.add(id);
    clock.pending += 1;
    return id;
  };
  globalThis.clearInterval = function (id) { done(id); realClearTimeout(id); };
  globalThis.clearTimeout = function (id) { done(id); realClearTimeout(id); };
  Object.defineProperty(globalThis, '__vmfShotClock', { value: clock });
  })();`;
}

/** Gives every page the browser opens from now on the fixed clock, and sets
 *  the time zone and locale. A part the browser refuses fails the run. */
async function installShotClock(send, clock) {
  const steps = [
    ['Page.addScriptToEvaluateOnNewDocument', { source: shotClockScript(clock.at) }],
    ['Emulation.setTimezoneOverride', { timezoneId: clock.timezone }],
    ['Emulation.setLocaleOverride', { locale: clock.locale }],
  ];
  for (const [method, params] of steps) {
    const r = await send(method, params);
    if (r && r.error) throw new Error(`${method} failed: ${r.error.message}`);
  }
}

/** Waits until every repeating timer on the page ran its first pass. A page
 *  with no fixed clock, or a pass that does not run in `limitMs`, fails. */
async function waitForTimerPass(send, sleepFn, limitMs = 20000) {
  for (let waited = 0; ; waited += 100) {
    const r = await send('Runtime.evaluate', { returnByValue: true,
      expression: '(window.__vmfShotClock ? window.__vmfShotClock.pending : -1)' });
    const left = r && r.result && r.result.result ? r.result.result.value : undefined;
    if (typeof left !== 'number' || left < 0) throw new Error('the page has no fixed clock. Every picture needs it.');
    if (left === 0) return;
    if (waited >= limitMs) throw new Error(`${left} repeating timer(s) did not run their first pass in ${limitMs / 1000}s.`);
    await sleepFn(100);
  }
}

const [edgePath, baseUrl, outDir, onlyArg] = process.argv.slice(2);
if (!edgePath || !baseUrl || !outDir) { console.error('usage: node manual-shots.js <edge.exe> <base url> <out dir> [file.png,...]'); process.exit(2); }
fs.mkdirSync(outDir, { recursive: true });

// Every picture the manual shows: the page, an optional script to run on it
// first (open a panel, pick a row), and the file name the manual refers to.
//
// MANUAL-SHOTS-1: `clip` keeps a picture to the part of the screen the page of
// the manual talks about - a dialog, a panel, a card. It is one selector, or
// two, and the picture runs from the top of the first to the bottom of the
// second. A whole page of a dialog's dimmed background tells a reader nothing.
// `maxHeight` stops a long page at that many pixels.
const SHOTS = [
  { file: 'overview.png', url: 'index.html?demo' },
  { file: 'projects.png', url: 'projects.html?demo' },
  { file: 'assessments.png', url: 'assessments.html?demo' },
  { file: 'assessment-report.png', url: 'assessments.html?demo',
    // PAGE-SCALE-ASSESSMENTS-1: the name of an assessment opens its report.
    act: `document.querySelector('[data-tile="planned"]').click();
      document.querySelector('a[data-action="report"][data-value="datacentre-exit/estate-scan-august"]').click()`,
    expect: '#vmf-panel.open', wait: 800 },
  // DETECT-PATTERNS-1: the workload type of each machine, with the filter and
  // the facts from Azure, at the end of the same report.
  { file: 'assessment-workload.png', url: 'assessments.html?demo',
    act: `document.querySelector('[data-tile="planned"]').click();
      document.querySelector('a[data-action="report"][data-value="datacentre-exit/estate-scan-august"]').click();
      for (let i = 0; i < 40 && !document.querySelector('#vmf-panel.open table[data-workload-table]'); i++) await new Promise(r => setTimeout(r, 100));
      document.querySelector('table[data-workload-table]').scrollIntoView({ block: 'end' });`,
    expect: '#vmf-panel.open table[data-workload-table]', wait: 800,
    clip: ['[data-workload-heading]', 'table[data-workload-table]'], clipPad: 12 },
  // assessment-identity.png WAS HERE. IDENTITY-4 removed the "Where is it
  // used?" control on 2026-09-11; its act clicked a button that no longer
  // exists behind an `if (b)` guard, so for eight days this wrote a second
  // copy of assessment-report.png and the manual showed it under a caption
  // about a feature the product no longer has. `expect` below is why that
  // cannot happen again.
  // MANUAL-V5-1: the review step as REVIEW-PAGE-1 made it - one row per
  // machine with the size series still open to it - and the Details of the
  // Generation 1 machine open, so the "Applies to v6 and v7." line shows.
  // demo-run is the older sample, which carries no generation.
  { file: 'wizard-review.png', url: 'wizard.html?demo&run=demo-review',
    act: `document.querySelector('.r-det[data-vm$="/legacy-01"]').click()`,
    expect: 'tr.t-detail', wait: 800 },
  // MANUAL-V5-1: the Choose each target step (ADVISOR-1), with the Details of
  // the Generation 1 machine open: v5, and why v6 and v7 are not available.
  // MACHINE-PICK-1: the Choose the machines step, with the machines shown added.
  { file: 'wizard-machines.png', url: 'wizard.html?demo&run=demo-scan&plan=1',
    act: `document.querySelector('#m-add').click()`,
    expect: '.m-pick:checked', wait: 800 },
  // CLAIM-AT-PLAN-1: a machine another migration holds (?demo&held: web-07),
  // marked with that migration, its box off.
  { file: 'wizard-machines-held.png', url: 'wizard.html?demo&run=demo-scan&plan=1&held',
    expect: '.m-held', clip: ['tr:has(.m-held)', 'tr:has(.m-held)'], wait: 800 },
  // The targets step is the second step now, so it opens on a run whose
  // machines are chosen.
  // REBUILD-REMOVE-PLAN-1: the fleet with its series and kind of change lists -
  // in-place rows, the Windows B v1 machine on its Bsv2 Preview, and web-07 on
  // its v6 Preview (its start under Current), with Same machine. under its
  // series list (TARGETS-ALIGN-1) and its Details open.
  { file: 'wizard-targets.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `await new Promise(r => setTimeout(r, 400));
          document.querySelector('.t-det[data-vm$="/web-07"]').click();`,
    expect: 'tr.t-detail', wait: 800 },
  // TEMP-DISK-PREVIEW-1: the in-place upgrade (Preview). The sample has the
  // preview feature not registered: the amber box of the subscription above
  // the tables (TARGETS-ALIGN-1), with its (?) open - the portal path, the
  // role and the wait.
  { file: 'wizard-targets-preview-off.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `await new Promise(r => setTimeout(r, 500));
          document.querySelector('.t-psub.t-pwarn [data-help^="preview-"]').click();`,
    expect: '.t-psub.t-pwarn .t-phelp', clip: ['.t-psub.t-pwarn', '.t-psub.t-pwarn'], wait: 600 },
  // ...and registered (?demo&previewon): the box of the subscription, once,
  // above the table, down to web-07 on v6: In-place upgrade (Preview) - its
  // start under Current - with Same machine. under its series list.
  { file: 'wizard-targets-preview.png', url: 'wizard.html?demo&run=demo-chosen&plan=1&previewon',
    act: `await new Promise(r => setTimeout(r, 500));`,
    expect: 'tr.t-row:has(select[data-vm$="/web-07"]) .t-pfact', clip: ['.t-psub', 'tr.t-row:has(select[data-vm$="/web-07"])'], wait: 600 },
  // BSV2-INPLACE-1: the Windows B v1 machine starts on Bsv2: In-place upgrade
  // (Preview) when the feature is registered; its Details say so.
  { file: 'wizard-targets-preview-bsv2.png', url: 'wizard.html?demo&run=demo-chosen&plan=1&previewon',
    act: `await new Promise(r => setTimeout(r, 500));
          document.querySelector('.t-det[data-vm$="/web-b01"]').click();`,
    expect: 'tr.t-detail', clip: ['tr.t-row:has(select[data-vm$="/web-b01"])', 'tr.t-detail'], wait: 600 },
  // REBUILD-PICKER-1: the counts of each kind of change above the table, and
  // their facts behind the (?).
  { file: 'wizard-targets-counts.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `document.querySelector('[data-help="method"]').click()`,
    expect: '#t-help-method', clip: ['#t-methods', '#t-help-method'] },
  // KERNEL-UX-1: the network driver choice at the top of the Details of a
  // Linux machine (legacy-02), and the notice above the tables, which stays
  // while the other Linux machines still have their dot.
  { file: 'wizard-targets-kernel.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `document.querySelector('.t-det[data-vm$="/legacy-02"]').click()`,
    expect: 'tr.t-detail .t-ksec', clip: ['.t-kwarn', 'tr.t-detail'] },
  // TEMPDISK-UX-1: a size with no temporary disk - the notice, the tag under
  // the size, and the Details of the Windows B v1 machine on Bsv2 with the
  // temporary disk row marked.
  { file: 'wizard-targets-tempdisk.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `document.querySelector('.t-det[data-vm$="/web-b01"]').click()`,
    expect: 'tr.t-detail tr.t-trow', clip: ['.t-twarn', 'tr.t-detail'] },
  // ADVISE-AN-1 (2026-10-12): the counts under the lifecycle stages and
  // their (?) open - why each group is not on the series of the default.
  { file: 'wizard-targets-summary.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `document.querySelector('[data-help="sum"]').click()`,
    expect: '#t-help-sum', clip: ['#t-def-label', '#t-help-sum'] },  // AN-MANA-DRIVER-RULE-1: api-a04 (AMD, the VM agent reports Ubuntu 18.04)
  // has AMD v5 only: Details say which release to upgrade to, and Other options
  // say why v6 and v7 are not available, with the rule table behind its (?).
  { file: 'wizard-targets-nomana.png', url: 'wizard.html?demo&run=demo-chosen&plan=1',
    act: `document.querySelector('.t-det[data-vm$="/api-a04"]').click();
          await new Promise(r => setTimeout(r, 400));
          document.querySelector('tr.t-detail [data-help^="an-"]')?.click();`,
    expect: 'tr.t-detail', clip: ['tr:has(+ tr.t-detail)', 'tr.t-detail'] },
  // REBUILD-REMOVE-PLAN-1: the picture of a target that deleted the system-assigned
  // identity is gone with the rebuild.
  { file: 'waves.png', url: 'waves.html?demo' },
  { file: 'migration-run.png', url: 'migrations.html?demo' },
  // STOP-STATE-SHOWN-1: a migration a person stopped - the top card and the
  // Wave safety brake card, from the record of the stop the page reads
  // (stopped.json). The sample run has no stop, so the record is set here.
  { file: 'migration-stopped.png', url: 'migrations.html?demo',
    act: `runStop = { schemaVersion: 1, runId: 'sample', stoppedUtc: new Date(Date.now() - 3600000).toISOString(),
            stoppedBy: 'operator@contoso.com', note: 'The second wave is not needed.', wavesNotStarted: [], machines: [], schedulesRemoved: [] };
          renderKpis(allVms, true, runStop); renderNextStep(latestEvents);`,
    expect: '#nextstep .card', clip: '#nextstep', clipPad: 4 },
  { file: 'brake-stopped.png', url: 'migrations.html?demo',
    act: `runStop = { schemaVersion: 1, runId: 'sample', stoppedUtc: new Date(Date.now() - 3600000).toISOString(),
            stoppedBy: 'operator@contoso.com', note: 'The second wave is not needed.', wavesNotStarted: [], machines: [], schedulesRemoved: [] };
          renderKpis(allVms, true, runStop);`,
    expect: '#kpis .kpi:last-child', clip: '#kpis .kpi:last-child', clipPad: 4 },
  { file: 'reports.png', url: 'reports.html?demo' },
  // PAGE-SCALE-REPORTS-1: the second tab, Records to download, which an
  // administrator sees (the sample data is an administrator's view).
  { file: 'report-records.png', url: 'reports.html?demo',
    act: `document.querySelector('[data-tab="records"]').click()`,
    expect: '[data-tab="records"][aria-selected="true"]', clip: '.vmf-list', clipPad: 4 },
  // The manual needs a picture of the Admin page, so this shot creates
  // one. The page answers from a sample table with ?demo.
  { file: 'admin.png', url: 'access.html?demo', wait: 1200 },
  { file: 'admin-add.png', url: 'access.html?demo',
    act: `const s = document.querySelector('#search'); s.value = 'Lee'; s.dispatchEvent(new Event('input'));
          setTimeout(() => { const b = document.querySelector('#results .result'); if (b) { b.click(); } }, 700)`,
    expect: '#results .result', wait: 1500 },

  // DISCLAIMER-1: the full notice a user sees once, at the first sign-in in a
  // browser. The sample data names a viewer and not a user, so it never opens
  // by itself there; the act signs in a sample user the way a page does.
  { file: 'disclaimer.png', url: 'index.html?demo',
    act: `localStorage.removeItem('vmf-disclaimer-seen');
          VmfHelp.identity({ username: 'operator@example.com', name: 'Operator' });`,
    expect: '[role="dialog"]', clip: '[role="dialog"]', clipPad: 0 },

  // MANUAL-SHOTS-1: the screens and dialogs the manual described with no
  // picture. Each one opens the thing it shows, and says what must be on the
  // page afterwards.
  //
  // Where should we look?, the second step of an assessment, with a name and
  // one resource group chosen. A run that does not exist yet opens on it.
  { file: 'wizard-scope.png', url: 'wizard.html?demo&project=contoso-exit&run=billing-first-look',
    act: `await new Promise(r => setTimeout(r, 800));
          document.querySelector('#f-name').value = 'billing-first-look';
          const box = document.querySelector('input[name="f-rgs"][value="rg-billing"]');
          box.checked = true; box.dispatchEvent(new Event('change'));`,
    expect: 'input[name="f-rgs"]:checked', clip: ['#rail', '#step .card'] },
  // How to group them, the third planning step.
  { file: 'wizard-group.png', url: 'wizard.html?demo&run=demo-grouped&plan=1',
    expect: '#go3', clip: ['#rail', '#step .card'] },
  // Run it, the last step of the wizard: each wave read back, one accepted and
  // one still to accept.
  { file: 'wizard-run.png', url: 'wizard.html?demo&run=demo-plan&step=run',
    expect: '[data-accept="web-report-db"]', clip: ['#rail', '#step .sec:has([data-accept])'] },
  // The same step with both waves accepted, so Sign off the plan is offered.
  { file: 'wizard-signoff.png', url: 'wizard.html?demo&run=demo-plan&step=run',
    act: `DEMO['demo-plan/acceptances/web-report-db.json'] = { wave: 'web-report-db', acceptedBy: 'operator@example.com' };
          await readRun(); render();`,
    expect: '#signoff:not([disabled])', clip: ['#step .sec:has(#f-note)', '#go5-why'] },
  // SQL-TEMPDB-SIGNOFF-1: the same step, with the section for SQL Server and the
  // temporary disk - report-01 of the sample moves from a SCSI temporary disk
  // to an NVMe one, and the scan found SQL Server on it.
  { file: 'wizard-sql-tempdb.png', url: 'wizard.html?demo&run=demo-plan&step=run',
    expect: '#f-sql', clip: ['#step .sec:has(#f-sql)'] },
  // WAVE-APPROVE-TIMER-WORDS-1: the same step after the plan was signed off
  // and one wave changed. That wave asks for its sign-off again, the other
  // keeps its approval, and Sign off the plan names the wave that changed.
  // The sample has no sign-off, so the act gives it one of an earlier plan
  // version: version 3, with an approval for web-pilot only.
  { file: 'wizard-signoff-again.png', url: 'wizard.html?demo&run=demo-plan&step=run',
    act: `DEMO['demo-plan/acceptances/web-report-db.json'] = { wave: 'web-report-db', acceptedBy: 'operator@example.com' };
          DEMO['demo-plan/plan-approval.json'] = { schemaVersion: 4, waves: ['web-pilot', 'web-report-db'],
            approvedBy: { identity: 'approver@example.com' }, approvedUtc: new Date().toISOString(), planHash: 'a'.repeat(64) };
          DEMO['demo-plan/approvals/web-pilot.json'] = { schemaVersion: 2, wave: 'web-pilot',
            approvedBy: { identity: 'approver@example.com' }, approvedUtc: new Date().toISOString() };
          await readRun(); planSignoffCurrent = false; render();`,
    expect: '#step .sec .pill.warn', clip: ['#step .sec:has(.pill.warn)', '#step .sec:has(#f-note)'] },
  // The wave editor: Change target open on one machine. WAVE-SAMPLE-RUN-1: the
  // wave editor shows the plan of the run on the Migrations page (help.js,
  // VmfHelp.sampleRun), so these pictures name its waves and machines.
  { file: 'wave-change-target.png', url: 'waves.html?demo',
    act: `document.querySelector('[data-change$="/can-lin-a"]').click()`,
    expect: '.m-change [data-changeapply]', clip: ['.wave[data-wave="storefront-pilot"] .m:has([data-change$="/can-lin-a"])', '.wave[data-wave="storefront-pilot"] .m-change'], clipPad: 0 },
  // WAVE-NOTE-LAYOUT-1: the note box of a wave whose machines take the
  // in-place upgrade (Preview), with the amber notice of a subscription that
  // does not have the feature (the sample answers not registered). In the
  // sample, can-win-a of storefront-pilot moves that way.
  { file: 'wave-preview-note.png', url: 'waves.html?demo',
    wait: 800, expect: '.wave[data-wave="storefront-pilot"] .wnote .wnote-vm',
    clip: ['.wave[data-wave="storefront-pilot"] .wh', '.wave[data-wave="storefront-pilot"] .wpwarn'], clipPad: 0 },
  // WAVE-OWN-PICTURE-1: the ? under a setting opens the list of the machines
  // that do not follow it, each with its value, the cause and the button Use the
  // wave's setting. In the sample, prd-win-b of billing-apps keeps Continue for
  // files found on its temporary disk, from a decision (who accepted it, when).
  { file: 'wave-own-value.png', url: 'waves.html?demo',
    act: `document.querySelector('[data-ownhelp="billing-apps|onDDataFound"]').click()`,
    expect: '[data-ownreset="billing-apps|onDDataFound"]',
    clip: '.wave[data-wave="billing-apps"] label:has([data-data])', clipPad: 8 },
  // The wave editor: a wave whose quota was checked and whose capacity is
  // reserved, with Release beside the reservation. ?demo stages the held
  // reservation the way the page itself does after Reserve capacity.
  { file: 'wave-reserve.png', url: 'waves.html?demo',
    act: `demoState.set('billing-apps', 'held'); await loadClaims();
          // QUOTA-CHECK-SPINNER-1: ?demo has no quota records; one record of a check with room.
          const at = new Date(Date.now() - 120000).toISOString();
          waveDocs = new Map([['billing-apps', [{ wave: 'billing-apps', subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2',
            size: 'Standard_D2ds_v6', vmFamily: 'standardDDSv6Family', state: 'RESERVED', blockReason: null, regionalShort: false,
            demand: { instances: 8, reservableInstances: 8, vcpus: 16, familyVcpus: 16, regionalVcpus: 16, regionalAdds: 16 },
            quota: { limit: 100, used: 20, regionalLimit: 200, regionalUsed: 40, name: 'Standard DDSv6 Family vCPUs', checkedUtc: at } }]]]);
          lastChecked = new Map([['billing-apps', at]]); render();`,
    wait: 1500, expect: '.wave[data-wave="billing-apps"] [data-release]',
    clip: ['.wave[data-wave="billing-apps"] .wh', '.wave[data-wave="billing-apps"] .levers'], clipPad: 0 },
  // QUOTA-CHECK-SPINNER-1: a wave whose quota is short: one line for the quota,
  // what the wave needs and by how much the plan is short. ?demo has no quota
  // records, so the act gives the page one record of a check two minutes ago.
  { file: 'wave-quota-short.png', url: 'waves.html?demo',
    act: `const at = new Date(Date.now() - 120000).toISOString();
          waveDocs = new Map([['billing-apps', [{ wave: 'billing-apps', subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2',
            size: 'Standard_D2ds_v6', vmFamily: 'standardDDSv6Family', state: 'BLOCKED', blockReason: 'quota-shortfall', regionalShort: false,
            demand: { instances: 3, reservableInstances: 3, vcpus: 6, familyVcpus: 10, regionalVcpus: 6, regionalAdds: 6 },
            quota: { limit: 10, used: 6, regionalLimit: 100, regionalUsed: 40, name: 'Standard DDSv6 Family vCPUs', checkedUtc: at } }]]]);
          lastChecked = new Map([['billing-apps', at]]); render();`,
    expect: '.wave[data-wave="billing-apps"] .quota-row .cap-answer.bad',
    clip: '.wave[data-wave="billing-apps"] .quota-row', clipPad: 8 },
  // QUOTA-CHECK-SPINNER-1: the plan-wide quota on the Request a quota increase
  // card: the time and Check the quota in its header, the state of the plan,
  // and the table of every quota the plan uses (a short one first), then the
  // request. The act gives the page the records of a check two minutes ago.
  { file: 'quota-plan-card.png', url: 'waves.html?demo',
    act: `const at = new Date(Date.now() - 120000).toISOString();
          const rec = (wave, family, name, state, limit, used, vcpus, familyVcpus) => ({ wave, subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2',
            size: 'Standard_D2ds_v6', vmFamily: family, state, blockReason: state === 'BLOCKED' ? 'quota-shortfall' : null, regionalShort: false,
            demand: { instances: 1, reservableInstances: 1, vcpus, familyVcpus, regionalVcpus: 16, regionalAdds: vcpus },
            quota: { limit, used, regionalLimit: 100, regionalUsed: 40, name, checkedUtc: at } });
          waveDocs = new Map([['billing-apps', [rec('billing-apps', 'standardDDSv6Family', 'Standard DDSv6 Family vCPUs', 'BLOCKED', 10, 6, 6, 10)]],
            ['storefront-pilot', [rec('storefront-pilot', 'standardDDSv6Family', 'Standard DDSv6 Family vCPUs', 'BLOCKED', 10, 6, 4, 10),
              rec('storefront-pilot', 'standardESv6Family', 'Standard ESv6 Family vCPUs', 'QUOTA_VERIFIED', 20, 4, 2, 2)]]]);
          lastChecked = new Map([['billing-apps', at], ['storefront-pilot', at]]); quotaShort = true; render();`,
    expect: '#quota .cap-short table', clip: '#quota .card', clipPad: 0 },
  // The same card while the check runs: the spinner, and nothing from a result.
  { file: 'quota-plan-card-checking.png', url: 'waves.html?demo',
    act: `checkingWaves.add('billing-apps'); render();`,
    expect: '#quota .spin', clip: '#quota .card', clipPad: 0 },
  // QUOTA-CHECK-SPINNER-1: a wave's row while the check runs: the spinner.
  { file: 'wave-quota-checking.png', url: 'waves.html?demo',
    act: `checkingWaves.add('billing-apps'); render();`,
    expect: '.wave[data-wave="billing-apps"] .quota-row .spin',
    clip: '.wave[data-wave="billing-apps"] .quota-row', clipPad: 8 },
  // QUOTA-CHECK-SPINNER-1: the confirmation of Request an increase, with the
  // column for what the waves need and a sentence for each wave, then the
  // same confirmation after Request: each request with its state and its ID.
  { file: 'quota-confirm.png', url: 'waves.html?demo',
    act: `subscriptionList = { subscriptions: [{ id: '00000000-0000-0000-0000-000000000000', name: 'Contoso Applications' }] };
          quotaConfirm = { phase: 'ready', rows: [{ kind: 'family', family: 'standardDDSv6Family', quotaName: 'Standard DDSv6 Family vCPUs',
            subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2', usage: 6, currentLimit: 10, requestedLimit: 16, free: 4,
            access: 'granted', status: 'WHATIF', waves: [{ wave: 'storefront-pilot', vcpus: 4 }, { wave: 'billing-apps', vcpus: 6 }] }] };
          drawQuotaConfirm();`,
    expect: '#q-modal-back.open #q-request', clip: '#q-modal', clipPad: 0 },
  { file: 'quota-confirm-done.png', url: 'waves.html?demo',
    // QUOTA-REQUEST-POLL-1: with the answers of Azure - one refused, with its
    // code and the support request to open, and one approved.
    act: `quotaConfirm = { phase: 'done', reading: false, rows: [{ kind: 'family', family: 'standardDDSv6Family', quotaName: 'Standard DDSv6 Family vCPUs',
            subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2', requestedLimit: 16, status: 'PENDING', reason: null,
            requestId: '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Compute/locations/eastus2/providers/Microsoft.Quota/quotaRequests/00000000-0000-0000-0000-000000000001',
            answer: 'REFUSED', answerCode: 'QuotaNotAvailableForResource' },
            { kind: 'regional', family: 'cores', quotaName: 'Total Regional vCPUs',
            subscriptionId: '00000000-0000-0000-0000-000000000000', region: 'eastus2', requestedLimit: 40, status: 'PENDING', reason: null,
            requestId: '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Compute/locations/eastus2/providers/Microsoft.Quota/quotaRequests/00000000-0000-0000-0000-000000000002',
            answer: 'APPROVED', answerCode: null }] };
          drawQuotaConfirm();`,
    expect: '#q-modal-back.open td.mono', clip: '#q-modal', clipPad: 0 },
  // The migration's page: Review & accept options on a wave.
  { file: 'accept-settings.png', url: 'migrations.html?demo',
    act: `document.querySelector('[data-accept="billing-apps"]').click()`,
    // REBUILD-REMOVE-ACCEPT-1: no list of rebuilds now; the table of settings
    // alone is taller than the usual window. PLAN-NOTES-RUNPAGE-1: and the
    // plan notes under it. CONFIRM-DIALOG-OUT-OF-VIEW-1: a dialog box is at
    // most 88% of the window high, so the window is taller than the box.
    // ACCEPT-FIRST-MACHINE-1: and under the setting for files on the temporary
    // disk, prd-win-b with its value Continue, in the wave editor's words.
    // MANUAL-REVIEW-1: the driver setting names the kernel minimum, one line longer.
    // EOL-RELEASE-AN-1: and the machines whose Linux release an approver accepted, one row more.
    height: 2400, expect: '#modal-back.open [data-ownrow]', clip: '#modal-back .modal', clipPad: 0 },
  // Approve on a wave.
  { file: 'approve-wave.png', url: 'migrations.html?demo',
    act: `document.querySelector('[data-approve="storefront-pilot"]').click()`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // Start this wave, with At a time I choose picked, so the time and the
  // window show. The page's own dialog, opened by its own function: in the
  // sample, no wave is in the state that offers the button.
  { file: 'start-wave.png', url: 'migrations.html?demo',
    act: `askStartWave('billing-apps');
          const later = document.querySelector('input[name="mf-when"][value="later"]');
          later.checked = true; later.dispatchEvent(new Event('change'));`,
    expect: '#m-fields .mf[data-mf="runAt"]:not([style*="none"])', clip: '#modal-back .modal', clipPad: 0 },
  // Delete this migration, which asks what to do with the safety copies.
  { file: 'delete-migration.png', url: 'migrations.html?demo',
    act: `askDiscardRun()`, expect: '#m-fields .mf[data-mf="copies"]', clip: '#modal-back .modal', clipPad: 0 },
  // A machine that stopped for a decision: See what to do.
  { file: 'machine-decision.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/prd-tmp-a"]').click()`,
    expect: '#drill.open #decide-btn', clip: '#drill-body', clipPad: 20 },
  // The dialog of Accept this and continue, for that machine.
  { file: 'machine-accept-decision.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/prd-tmp-a"]').click();
          await new Promise(r => setTimeout(r, 300));
          document.querySelector('#decide-btn').click();`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // REBUILD-REMOVE-ACCEPT-1: the dialog of Accept this for one machine for a
  // rebuild (machine-accept-rebuild.png) is gone with the acceptance.
  // The dialog of Try this machine again, with when and why it stopped.
  { file: 'machine-retry.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/prd-lin-c"]').click();
          await new Promise(r => setTimeout(r, 300));
          document.querySelector('#resolve-btn').click();`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // The dialog of Leave this machine out.
  { file: 'machine-leave-out.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/prd-tmp-a"]').click();
          await new Promise(r => setTimeout(r, 300));
          document.querySelector('#skip-btn').click();`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // A machine that rolled back: Try this machine again, and the other series.
  { file: 'machine-rolled-back.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/prd-lin-c"]').click()`,
    wait: 1200, height: 1100, expect: '#drill.open [data-retryseries]', clip: '#drill-body', clipPad: 20 },
  // Restore this machine, with No chosen for Keep its current managed disks,
  // so the confirmation names each disk the restore would delete.
  { file: 'machine-restore.png', url: 'migrations.html?demo',
    act: `document.querySelector('tr.vm-row[data-vm$="/can-win-a"]').click();
          await new Promise(r => setTimeout(r, 300));
          document.querySelector('#restore-btn').click();
          const keep = document.querySelector('input[name="mf-diskNaming"][value="preserve"]');
          keep.checked = true; keep.dispatchEvent(new Event('change'));`,
    expect: '#m-fields .mf[data-mf="accept"]:not([style*="none"])', clip: '#modal-back .modal', clipPad: 0 },
  // MANUAL-SHOT-RESTORE-1: Restore this machine for a machine with only its
  // first safety copy - the preparation failed before the second copy, and the
  // rollback did not finish (PREP-ROLLBACK-1). No sample machine is in that
  // state, and one more would change every picture of the sample migration, so
  // the act gives the page's own openDrill the record and clicks the panel's
  // own button. tests/js/manual-shot-restore.test.js runs this act and holds
  // the record to the page's rules.
  { file: 'machine-restore-first-copy.png', url: 'migrations.html?demo',
    act: `const vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso-app/providers/Microsoft.Compute/virtualMachines/prd-lin-a';
          await openDrill({ schemaVersion: 1, runId: 'pilot-rehearsal-sample', vmId, state: 'FAILED_NEEDS_ATTENTION', guestExecutions: [],
            history: [
              { tsUtc: '2026-11-06T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
              { tsUtc: '2026-11-06T10:01:00Z', state: 'SAFETY_PRISTINE', outcome: 'ok' },
              { tsUtc: '2026-11-06T10:04:00Z', state: 'GUEST_PREP', outcome: 'fail' },
              { tsUtc: '2026-11-06T10:06:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed',
                detail: 'GUEST_PREP failed after the preparation changed the machine, AND the rollback also failed (Azure did not make the disk prd-lin-a-osdisk-asitwas from its copy).' }],
            safety: { pristineSnapshotId: '/snap/prd-lin-a-pristine', snapshotId: null, pristineSnapshotLocked: true, snapshotLocked: null, cloneVmId: null, locksAllowed: true,
              pristineDataCopies: [{ lun: 0, snapshotId: '/snap/prd-lin-a-data0-pristine', locked: true }] },
            captured: { vmConfig: { size: 'Standard_D2s_v4', controller: 'SCSI', osDisk: { name: 'prd-lin-a-osdisk' },
              dataDisks: [{ lun: 0, name: 'prd-lin-a-data0', skuName: 'Premium_LRS' }] },
              // PRECHECK writes the first capture with the capture (vm-state v47).
              original: { vmConfig: { size: 'Standard_D2s_v4', controller: 'SCSI', osDisk: { name: 'prd-lin-a-osdisk' },
                dataDisks: [{ lun: 0, name: 'prd-lin-a-data0', skuName: 'Premium_LRS' }] } } } }, null, vmId);
          await new Promise(r => setTimeout(r, 300));
          document.querySelector('#restore-btn').click();`,
    expect: '#modal-back.open .mf[data-mf="diskSource"] .radio-row > label:only-child input[value="pristine"]', clip: '#modal-back .modal', clipPad: 0 },
  // SWAP-REFUSED-AFTER-STOP-1: the dialog of Finish the rollback, for a machine
  // a refused data disk swap left stopped, drawn by the page's own askFinish.
  // FINISH-EMPTY-LUN-WORDS-1: the record says the disk the LUN had is on it.
  { file: 'machine-finish.png', url: 'migrations.html?demo',
    act: `askFinish('/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-can/providers/Microsoft.Compute/virtualMachines/can-win-a',
            { swapPending: { kind: 'rollback', swaps: [{ lun: 1, name: 'can-win-a-data1', diskName: 'can-win-a-data1-d1-asitwas-202610231000', lunHolds: 'had' }] } })`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // POWER-ONLY-CHANGED-1: the panel of a machine left out whose power state the
  // product could not return, and the dialog of Return to the power state, drawn
  // by the page's own openDrill and askPowerBack. No sample machine is owed a
  // power state, so the act gives the panel that record.
  { file: 'machine-power-owed.png', url: 'migrations.html?demo',
    act: `openDrill({ state: 'SKIPPED', history: [
            { tsUtc: '2026-11-06T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'ok', reasonCode: 'rollbackDisksBeforeMoveNotMade', machineState: 'changed', powerNotPutBack: 'PowerState/deallocated',
              detail: 'The move stopped before it changed the machine. The machine was deallocated before the move, and the product could not deallocate it again (OperationNotAllowed), after 3 tries.' },
            { tsUtc: '2026-11-06T10:05:00Z', state: 'SKIPPED', outcome: 'skip', detail: 'left out by operator@example.com: later' }] },
            null, '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/virtualMachines/prd-tmp-a')`,
    wait: 800, expect: '#powerback-btn', clip: '#drill-body', clipPad: 20, maxHeight: 700 },
  { file: 'machine-power-back.png', url: 'migrations.html?demo',
    act: `askPowerBack('/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/virtualMachines/prd-tmp-a',
            { state: 'SKIPPED', history: [{ tsUtc: '2026-11-06T10:00:00Z', state: 'SKIPPED', outcome: 'skip', machineState: 'changed', powerNotPutBack: 'PowerState/deallocated' }] })`,
    expect: '#modal-back.open', clip: '#modal-back .modal', clipPad: 0 },
  // RESTORE-EARLIER-DELETE-1: Delete these disks, for a restore that kept the
  // operating system disk and two data disks. MADE-DISK-DELETE-1: the warning
  // slides open in the panel under the link, drawn by the page's own openDrill
  // as the refresh redraws it (keep), with the slide-out open (diskDelete) - a
  // new open forgets it.
  { file: 'machine-delete-earlier.png', url: 'migrations.html?demo',
    act: `const vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-can/providers/Microsoft.Compute/virtualMachines/can-win-a';
          const disk = (n) => '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-can/providers/Microsoft.Compute/disks/' + n;
          diskDelete = { vmId: vm, kind: 'earlier', sending: false, err: '' };
          openDrill({ state: 'MIGRATED', guestExecutions: [], history: [
            { tsUtc: '2026-11-06T10:00:00Z', state: 'MIGRATED', outcome: 'ok' }],
            restore: { operationId: 'op-1', restoredUtc: '2026-11-06T12:00:00Z', restoredBy: 'operator@example.com', fromCopy: 'prepared',
              diskNaming: 'new', diskIdChanged: true, previousDiskName: 'can-win-a-os', retainedDiskId: disk('can-win-a-os'),
              newDiskId: disk('can-win-a-os-restored-202611070900'), newDiskName: 'can-win-a-os-restored-202611070900',
              dataDisks: [0, 1].map(lun => ({ lun, previousDiskName: 'can-win-a-data' + lun, previousDiskId: disk('can-win-a-data' + lun),
                newDiskId: disk('can-win-a-data' + lun + '-restored-202611070900'), newDiskName: 'can-win-a-data' + lun + '-restored-202611070900' })) } },
            null, vm, { keep: true })`,
    wait: 800, height: 1400, expect: '#earlierdelete-slide', clip: '#drill-body .card:has(#earlierdelete-slide)', clipPad: 8 },
  // MADE-DISK-SHOWN-1: the panel of a machine that needs attention, with the
  // managed disks a rollback made that the record says nothing uses, drawn by
  // the page's own openDrill. No sample machine has such a disk, so the act
  // gives the panel that record. MADE-DISK-DELETE-1: with Delete these disks
  // now open under the table (diskDelete).
  { file: 'machine-made-disks.png', url: 'migrations.html?demo',
    act: `const disk = (n) => '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/disks/' + n;
          diskDelete = { vmId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/virtualMachines/prd-lin-z', kind: 'made', sending: false, err: '' };
          openDrill({ state: 'FAILED_NEEDS_ATTENTION', guestExecutions: [], history: [
            { tsUtc: '2026-11-06T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed',
              detail: 'GUEST_PREP failed after the preparation changed the machine, AND the rollback also failed.' }],
            rollbackDisksDuringRollback: [
              { diskId: disk('prd-lin-z-osdisk-asitwas-202611061000'), diskName: 'prd-lin-z-osdisk-asitwas-202611061000', lun: null, madeUtc: '2026-11-06T10:05:00Z' },
              { diskId: disk('prd-lin-z-data0-d0-asitwas-202611061000'), diskName: 'prd-lin-z-data0-d0-asitwas-202611061000', lun: 0, madeUtc: '2026-11-06T10:05:30Z' }] },
            null, '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/virtualMachines/prd-lin-z', { keep: true })`,
    wait: 800, height: 1400, expect: '#madedelete-slide', clip: '#drill-body .card:has(#madehelp-btn)', clipPad: 8 },
  // ROLLBACK-ORIGINALS-LEFT-1: the panel of a machine that rolled back, with
  // the original disks the rollback swapped off and Delete these disks open
  // under the table (diskDelete), drawn by the page's own openDrill. No sample
  // machine has the record, so the act gives the panel one.
  { file: 'machine-original-disks.png', url: 'migrations.html?demo',
    act: `const vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/virtualMachines/prd-win-z';
          const disk = (n) => '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-prd/providers/Microsoft.Compute/disks/' + n;
          diskDelete = { vmId: vm, kind: 'original', sending: false, err: '' };
          openDrill({ state: 'FAILED_ROLLED_BACK', guestExecutions: [], history: [
            { tsUtc: '2026-11-06T10:00:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', machineState: 'restored', reasonCode: 'validationFailedAfterConversion',
              detail: 'VALIDATING failed; the machine was rolled back to how it was.' }],
            rollback: { rolledBackUtc: '2026-11-06T10:00:00Z', path: 'A', osDisk: { id: disk('prd-win-z-osdisk-asitwas-202611060950'), name: 'prd-win-z-osdisk-asitwas-202611060950' },
              dataDisks: [0, 1].map(lun => ({ lun, diskId: disk('prd-win-z-data' + lun + '-d' + lun + '-asitwas-202611060950'), diskName: 'prd-win-z-data' + lun + '-d' + lun + '-asitwas-202611060950' })) },
            rollbackOriginals: [
              { diskId: disk('prd-win-z-osdisk'), diskName: 'prd-win-z-osdisk', lun: null, detachedUtc: '2026-11-06T09:58:00Z' },
              { diskId: disk('prd-win-z-data0'), diskName: 'prd-win-z-data0', lun: 0, detachedUtc: '2026-11-06T09:59:00Z' },
              { diskId: disk('prd-win-z-data1'), diskName: 'prd-win-z-data1', lun: 1, detachedUtc: '2026-11-06T09:59:00Z' }] },
            null, vm, { keep: true })`,
    wait: 800, height: 1400, expect: '#originaldelete-slide', clip: '#drill-body .card:has(#originaldelete-slide)', clipPad: 8 },
  // The Quota and capacity reservations card on the migration's page.
  { file: 'quota-card.png', url: 'migrations.html?demo',
    expect: '#cap-table tbody tr', clip: '#capacity-card', clipPad: 4 },
  // The Reports page with one migration open, and Download the record.
  // PAGE-SCALE-REPORTS-1: the name of a migration opens its detail below the
  // list, by the function the name's click calls.
  { file: 'report-detail.png', url: 'reports.html?demo',
    act: `openDetail('payments-refresh/pilot-sample', null)`,
    wait: 1200, expect: '#run-detail:not([hidden]) table', clip: '#run-detail', clipPad: 4 },
  // The migration record that Download the record saves, drawn by the page's
  // own function from its sample record, in the report's look. The look comes
  // from the module (Export-VmfManualScreenshots.ps1 puts it beside the pages).
  { file: 'migration-record.png', url: 'reports.html?demo',
    act: `const look = await fetch('manual-report-look.json').then(r => (r.ok ? r.json() : null)).catch(() => null);
          if (!look) { throw new Error('manual-report-look.json is missing'); }
          const html = recordHtml(demoRecord('payments-refresh/pilot-sample'), look, 'light');
          document.open(); document.write(html); document.close();`,
    expect: 'table', maxHeight: 1250 },
  // The Get help menu in the top bar, opened by the function its button calls.
  { file: 'get-help.png', url: 'index.html?demo',
    act: `VmfHelp.open()`, expect: '[role="dialog"] [data-help="manual"]', clip: '[role="dialog"]', clipPad: 0 },
  // The report of a migration, as the module writes it, from a small sample
  // migration (tools/New-VmfManualSampleRun.ps1). Its address has no ?demo
  // because it is not a page: Export-VmfManualScreenshots.ps1 writes it beside
  // the pages for the run, from the sample data, and deletes it afterwards.
  { file: 'report.png', url: 'manual-sample-report.html', expect: 'table', maxHeight: 1845 },
];

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/* MANUAL-SHOTS-1: the three rules below are pure, so tests/js/manual-shots.test.js
 * runs them. */

/** The shots a run takes: every one, or the ones the last argument names. A
 *  name that is not a shot fails, so a typing mistake cannot pass as a run. */
function selectShots(shots, onlyArg) {
  const only = onlyArg ? new Set(String(onlyArg).split(',').map(x => x.trim()).filter(Boolean)) : null;
  if (only) { for (const f of only) { if (!shots.some(s => s.file === f)) throw new Error(`no shot is named ${f}`); } }
  return shots.filter(s => !only || only.has(s.file));
}

/** The area to capture for a clipped shot, from the box the page measured:
 *  { x, y, w, h } in page pixels, whether it is inside a fixed panel, and the
 *  height of the window. A box that does not fit its window is a cut-off
 *  picture, so it fails: a dialog needs a taller `height`, and a box on the
 *  page that the window could not grow to hold says so. */
function clipArea(box, pad, pageWidth) {
  // CONFIRM-DIALOG-OUT-OF-VIEW-1: a box that scrolls inside itself (cut) with
  // more than it shows fits the window, and is still a cut-off picture.
  if (box.fixed && (box.cut || box.y < -1 || box.y + box.h > box.vh + 1)) {
    throw new Error(`is ${Math.round(box.h)} pixels and the window is ${box.vh}. Give the shot a larger height.`);
  }
  if (!box.fixed && box.y + box.h > box.vh + 1) {
    throw new Error(`ends ${Math.round(box.y + box.h - box.vh)} pixels below the window, and the window could not grow to hold it.`);
  }
  const x = Math.max(0, Math.floor(box.x - pad)), y = Math.max(0, Math.floor(box.y - pad));
  return { x, y, width: Math.min(pageWidth - x, Math.ceil(box.w + 2 * pad)), height: Math.min(box.vh - y, Math.ceil(box.h + 2 * pad)) };
}

/** Two pictures with the same bytes: [file, earlier file], or null. Given
 *  [file, digest] pairs in order. */
function duplicatePair(digests) {
  const seen = new Map();
  for (const [file, sum] of digests) {
    if (seen.has(sum)) return [file, seen.get(sum)];
    seen.set(sum, file);
  }
  return null;
}

async function main() {
  const profile = fs.mkdtempSync(path.join(require('os').tmpdir(), 'vmf-shots-'));
  const edge = spawn(edgePath, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, `--disk-cache-dir=${path.join(profile, 'cache')}`,
    '--window-size=1400,900', 'about:blank',
  ], { stdio: 'ignore' });
  // Any way this script ends - an error, Ctrl+C, the caller stopping it - stops Edge too.
  const stopOnExit = () => stopEdgeByProfile(profile);
  process.on('exit', stopOnExit);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { stopOnExit(); process.exit(1); });
  let port = 0;
  try {
    port = await readDevToolsPort(profile, sleep);
    if (!port) throw new Error('Edge did not write its debugging port.');
    // Wait for the debugger to answer.
    let targets = null;
    for (let i = 0; i < 50 && !targets; i++) {
      try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch { await sleep(200); }
    }
    if (!targets) throw new Error('Edge did not open its debugging port.');
    const page = targets.find(t => t.type === 'page');
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    let id = 0;
    const pending = new Map();
    const events = [];
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
      else if (msg.method) {
        events.push(msg.method);
        // A page that throws while its picture is taken is a picture of a
        // broken page. Say so, loudly, rather than shipping it.
        if (msg.method === 'Runtime.exceptionThrown') console.error('page exception:', msg.params?.exceptionDetails?.exception?.description || msg.params?.exceptionDetails?.text);
        if (msg.method === 'Runtime.consoleAPICalled' && msg.params?.type === 'error') console.error('page console.error:', (msg.params.args || []).map(a => a.value || a.description).join(' '));
      }
    };
    const send = (method, params) => new Promise((res) => { const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id: n, method, params: params || {} })); });
    await send('Page.enable');
    await send('Runtime.enable');
    // NEVER from a cache. Found 2026-09-05: Edge served a stale copy of
    // access.html from its cache (transferSize 0, deliveryType 'cache') in a
    // profile created seconds earlier, and the picture showed an error bar
    // from a version of the page that no longer existed on disk. A picture
    // of the product must be a picture of the file that ships.
    await send('Network.enable');
    await send('Network.setCacheDisabled', { cacheDisabled: true });
    await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
  // LOGO-SERVERS-1: the header mark moves once when a page opens. With reduced
  // motion it is the finished drawing at once, so no picture holds a frame of it.
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
    // SHOT-CLOCK-1: one fixed clock for every page this run opens.
    await installShotClock(send, SHOT_CLOCK);

    const taking = selectShots(SHOTS, onlyArg);
    for (const s of taking) {
      events.length = 0;
      // MANUAL-SHOTS-1: a clipped shot may have grown the window; every shot
      // starts from the same one.
      // `height` is a taller window for a dialog that holds more than 900
      // pixels: a dialog is held to the window, and would be cut off.
      await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: s.height ?? 900, deviceScaleFactor: 1, mobile: false });
      await send('Page.navigate', { url: `${baseUrl}/${s.url}` });
      for (let i = 0; i < 50 && !events.includes('Page.loadEventFired'); i++) await sleep(100);
      await sleep(900);   // the pages fetch their sample data and draw
      if (s.act) {
        // MANUAL-SHOTS-1: run as the body of an async function, so an act can
        // wait for the page between two clicks - and an act that throws fails
        // the run, rather than leaving a picture of the page before it.
        const ran = await send('Runtime.evaluate', { expression: `(async () => { ${s.act}\n})()`, awaitPromise: true });
        if (ran.result?.exceptionDetails) {
          throw new Error(`${s.file}: its act threw: ${ran.result.exceptionDetails.exception?.description || ran.result.exceptionDetails.text}`);
        }
        await sleep(s.wait || 600);
      }
      // SHOT-CLOCK-1: every repeating timer has run its first pass, so a line
      // it writes (the Migrations header) is in every picture of its page.
      await waitForTimerPass(send, sleep);
      // An `act` that did nothing is the failure this check exists for. A shot
      // that opens a panel or picks a row says what the page must show
      // afterwards, and a missing element fails the run instead of writing a
      // picture of the page as it was before. MEASURED 2026-09-19: without
      // this, a shot whose control had been deleted eight days earlier wrote a
      // byte-for-byte copy of the shot above it, and the manual published it.
      if (s.expect) {
        const seen = await send('Runtime.evaluate', {
          expression: `Boolean(document.querySelector(${JSON.stringify(s.expect)}))`, returnByValue: true });
        if (!seen.result?.result?.value) {
          throw new Error(`${s.file}: after its act, the page has no ${s.expect}. The control it clicks has probably been removed - fix or delete this shot.`);
        }
      }
      // The dashboard shows its errors in #err. A screenshot of an error bar
      // must fail the run, never land in the manual.
      const bar = await send('Runtime.evaluate', { expression: `(() => { const e = document.querySelector('#err'); return e && e.offsetParent !== null ? e.textContent : ''; })()`, returnByValue: true });
      if (bar.result?.result?.value) {
        // What the page actually loaded, and from where: this is how the
        // stale-cache case above was found, so it stays in the message.
        const where = await send('Runtime.evaluate', { expression: `JSON.stringify({ href: location.href, document: performance.getEntriesByType('navigation').map(e => e.deliveryType || 'network'), loaded: performance.getEntriesByType('resource').map(e => e.name + ' ' + (e.responseStatus || '')) })`, returnByValue: true });
        throw new Error(`${s.file}: the page shows an error: ${bar.result.result.value}\n${where.result?.result?.value}`);
      }
      let shot, size;
      if (s.clip) {
        // MANUAL-SHOTS-1: the part of the screen the manual talks about. The
        // page is never scrolled, so a box is in page coordinates. A box that
        // runs below the window grows the window to hold it, because a capture
        // beyond the window lays the page out again and a dialog centred in
        // the window would then move. A box inside a fixed panel (a dialog, the
        // machine panel) is held to the window instead.
        const clipBox = async () => (await send('Runtime.evaluate', { returnByValue: true, expression: `(() => {
          const sels = ${JSON.stringify([].concat(s.clip))};
          const els = sels.map(q => document.querySelector(q));
          if (els.some(e => !e)) return { missing: sels[els.indexOf(null)] };
          const boxes = els.map(e => e.getBoundingClientRect());
          const fixed = els.some(e => { for (let n = e; n && n.nodeType === 1; n = n.parentElement) { if (getComputedStyle(n).position === 'fixed') return true; } return false; });
          const top = Math.min(...boxes.map(b => b.top)), bottom = Math.max(...boxes.map(b => b.bottom));
          const left = Math.min(...boxes.map(b => b.left)), right = Math.max(...boxes.map(b => b.right));
          const cut = els.some(e => ['auto', 'scroll', 'hidden'].includes(getComputedStyle(e).overflowY) && e.scrollHeight > e.clientHeight + 1);
          return { x: left + scrollX, y: top + scrollY, w: right - left, h: bottom - top, fixed, cut, vh: innerHeight };
        })()` })).result?.result?.value;
        const pad = s.clipPad ?? 16;
        let box = await clipBox();
        if (!box || box.missing) throw new Error(`${s.file}: the page has no ${box?.missing ?? s.clip} to keep the picture to.`);
        // A page laid out to the window height can move the box again when
        // the window grows, so it grows with room to spare, and checks again.
        for (let tries = 0; !box.fixed && box.y + box.h + pad > box.vh && tries < 4; tries++) {
          await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: Math.min(4000, Math.ceil(box.y + box.h + pad + 200)), deviceScaleFactor: 1, mobile: false });
          await sleep(400);
          box = await clipBox();
        }
        // A box that does not fit its window is a cut-off picture of it.
        let area;
        try { area = clipArea(box, pad, 1400); } catch (e) { throw new Error(`${s.file}: ${s.clip} ${e.message}`); }
        shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false, clip: { ...area, scale: 1 } });
        size = `${area.width}x${area.height}px`;
      } else {
        const metrics = await send('Page.getLayoutMetrics');
        const height = Math.min(Math.ceil(metrics.result.cssContentSize.height), s.maxHeight ?? 2400);
        shot = await send('Page.captureScreenshot', {
          format: 'png', captureBeyondViewport: true,
          clip: { x: 0, y: 0, width: 1400, height, scale: 1 },
        });
        size = `${height}px`;
      }
      fs.writeFileSync(path.join(outDir, s.file), Buffer.from(shot.result.data, 'base64'));
      console.log(`${s.file} ${size}`);
    }
    ws.close();

    // Two identical pictures mean one shot did not do what it says. This is
    // the backstop under `expect`: it needs no selector to be kept current,
    // and it catches a duplicate however it arose.
    // MANUAL-SHOTS-1: the pictures just taken, then every other picture of
    // this tool already on disk - so a run of one picture is still compared
    // with the rest.
    const taken = taking.map(s => s.file);
    const files = [...taken, ...SHOTS.map(s => s.file).filter(f => !taken.includes(f) && fs.existsSync(path.join(outDir, f)))];
    const pair = duplicatePair(files.map(f => [f, require('crypto').createHash('sha256').update(fs.readFileSync(path.join(outDir, f))).digest('hex')]));
    if (pair) throw new Error(`${pair[0]} is byte-for-byte identical to ${pair[1]}. One of the two shots did not do what it says.`);
  }
  finally {
    await closeBrowser(port);
    stopEdgeByProfile(profile);
    await sleep(300);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* a locked temp profile is harmless */ }
  }
}

main().catch(e => { console.error(e.message || e); process.exit(1); });
