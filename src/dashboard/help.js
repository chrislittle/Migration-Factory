// Get help, on every page, without leaving the page you are on.
//
// Help used to link back to one page, which took a person out of the page
// they were on. That was a way of avoiding four copies of the bundle builder;
// this is the way of having ONE copy that every page uses in place.
//
// Each page hands over the three things only it knows how to do - read a
// document, list a folder, read the log - and this file does the rest,
// including its own dialog, so it never depends on a page's modal.
(function () {
  'use strict';

  const EVENT_CAP = 5000;

  /* CLIENT-ERR-1: why there is no browser telemetry service here, and what
   * replaces it.
   *
   * Browser telemetry would be data nobody reads. The
   * dashboard is static pages in the CUSTOMER'S subscription; an operator sees
   * the error on screen, and a customer is not going to open Application
   * Insights. Sign-in and every API call are already recorded at the facade,
   * which is where the security boundary is.
   *
   * But something WAS missing. A defect in this page produced a browser error
   * that existed only on one screen, and "Report a problem" would not have
   * included it - the support bundle held everything about the MIGRATION and
   * nothing about the PAGE.
   *
   * So the page remembers its own recent errors, and offers them in the bundle
   * the person already chooses to send and can edit first. Nothing leaves the
   * browser on its own, no new resource, nothing on the customer's ingestion
   * bill, and no third-party script.
   *
   * Errors thrown before this file loads are not caught. That is a real limit,
   * and better than a wrong claim of completeness.
   */
  const CLIENT_ERROR_CAP = 25;
  const clientErrors = [];

  // Takes its buffer and its cap rather than closing over them, so the rules
  // below can be tested by lifting this one function out of the file - which
  // is the only way this project trusts a behaviour (ASSESS-LIST-1).
  function recordClientError(list, cap, page, kind, message, source, line, col, stack) {
    // A page left open all day must not grow without end, and the NEWEST
    // errors are the ones that explain what somebody is reporting.
    while (list.length >= cap) { list.shift(); }
    list.push({
      atUtc: new Date().toISOString(),
      kind,
      page,
      message: String(message == null ? '' : message).slice(0, 500),
      // The file name, never the full URL: a page address can carry a run id
      // or a query string, and support needs the file, not the address.
      source: source ? String(source).split('/').pop().split('?')[0] : null,
      line: (line === 0 || line) ? Number(line) : null,
      column: (col === 0 || col) ? Number(col) : null,
      // The first few frames say where it happened. The whole stack is longer
      // than it is useful and carries the same addresses.
      stack: stack ? String(stack).split('\n').slice(0, 6).join('\n').slice(0, 1000) : null,
    });
    return list;
  }

  // HOME-1 counts the places that fall back to the default document and
  // asserts they agree, because a blanket rename once turned that fallback
  // into migrations.html and the root address opened the wrong page. So this
  // uses the helper that already exists rather than adding a fourth copy.
  // It is safe to call from here: these listeners only fire after the whole
  // file has run, long after currentPage is defined.
  window.addEventListener('error', function (e) {
    recordClientError(clientErrors, CLIENT_ERROR_CAP, currentPage(), 'error',
      e && e.message, e && e.filename, e && e.lineno, e && e.colno,
      e && e.error && e.error.stack);
  });
  window.addEventListener('unhandledrejection', function (e) {
    const r = e && e.reason;
    recordClientError(clientErrors, CLIENT_ERROR_CAP, currentPage(), 'unhandledrejection',
      (r && r.message) || r, null, null, null, r && r.stack);
  });

  let adapter = null;
  /* SIGNOUT-1: the MSAL app as the ROLE GATE saw it.
   *
   * signOut() reached MSAL only through `adapter`, which install() sets. Three
   * pages - migrations, reports and wizard - call gateOnRole() BEFORE
   * install(), and the gate returns early for somebody with no role. So on
   * exactly the screen whose Sign out button is the documented way back out,
   * `adapter` was null and the button did nothing at all: no app, no
   * exception, so not even the sessionStorage fallback ran.
   *
   * gateOnRole is handed the MSAL app already. Keeping it here is what lets
   * the gate's own button perform a REAL sign-out - ending the Entra session -
   * rather than only dropping the local token cache. */
  let gateMsal = null;
  // VERSION-1: the two facts the version display is built from (see below).
  let build = null;      // { version, commit, builtUtc } from dashboard.config.json
  let service = null;    // the facade's /version answer; { pending } in flight; { error } when it failed; null until asked
  let aboutBox = null;   // the About dialog while it is open, so an answer that lands late still shows

  /* ---------- SCALE-UX-1: what "how many machines at once" means ----------
   *
   * One factor controls this, and the operator chooses it per wave: how many
   * machines move at the same time.
   *
   * The number becomes the worker count in
   * the engine's container, and the facade sizes the container from it
   * (Get-VmfFacadeEngineResources), so the operator never sees a CPU or a
   * gigabyte. The screen's job is to say what the number means. MANUAL-REVIEW-1:
   * no wave time in words on a page. The engine's own
   * estimate (Get-VmfWaveDurationEstimate) stays, for the change window. */
  // SCALE-2: 15 workers fit one 8 GiB container (measured); above that the
  // facade starts more containers on the same wave, up to four.
  const WAVE_MAX_WORKERS = 60;
  const WAVE_PER_CONTAINER = 15;
  /* MACHINES-AT-ONCE-RANGE-1: four choices, not a number
   * field. Pilot 5, Standard 15 (the default: one engine container), Large 30
   * (two containers) and Maximum 60 (four). The module holds the same list
   * (Get-VmfThrottleTiers), and MachinesAtOnceRange.Tests.ps1 holds the two
   * to each other. */
  const WAVE_TIERS = [
    { id: 'pilot', machines: 5 },
    { id: 'standard', machines: 15 },
    { id: 'large', machines: 30 },
    { id: 'maximum', machines: 60 },
  ];
  const WAVE_DEFAULT_WORKERS = 15;

  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // HELP-2: help is not one thing.
  // Somebody stuck on a failed machine needs the support bundle; somebody who
  // has spotted a broken screen needs a bug report; somebody who wants a
  // feature needs neither. This used to do only the first, from every entry
  // point, so two of the three had nowhere to go.
  //
  // The app FILES NOTHING. Each branch hands back a pre-filled GitHub link the
  // person opens themselves. That keeps their name on their own issue, keeps
  // this page free of any token, and - the part that matters - lets them SEE
  // what is being sent before it goes, because the support bundle contains
  // their resource ids and machine names.
  const REPO = 'https://github.com/chrislittle/Migration-Factory';
  // DOC-4: the manual travels with the dashboard (Deploy-VmfDashboard.ps1
  // copies docs/manual beside the pages), so it is a relative address.
  const MANUAL_URL = 'manual/index.html';
  function issueUrl(kind, title, body) {
    const q = new URLSearchParams({ template: kind, title: title, body: body });
    return `${REPO}/issues/new?${q.toString()}`;
  }

  /* NO-POPUPS-1: the manual, and every other link, opens in THIS tab. The
   * product opens no popup: a blocked window does nothing, or shows a script
   * error. `from` names this page and its query,
   * so the manual's "Back to the dashboard" and Escape return here
   * (docs/manual/index.html, manualBackHref). */
  function manualHref(hash) {
    const from = currentPage() + location.search;
    return MANUAL_URL + '?from=' + encodeURIComponent(from) + (hash || '');
  }

  function openManual() {
    location.href = manualHref();
  }

  const TEXT = {
    nav: 'Get help',
    // SIGNOUT-1. "Sign out" is the word Entra and Microsoft 365 use, so it is
    // the word a person arriving from those has already learnt. Not "Log out".
    signOut: 'Sign out',
    themeLabel: 'Theme',
    // MACHINES-AT-ONCE-RANGE-1: each choice of how many machines at once says
    // its number and its engine containers, and what it means.
    atOnceName: { pilot: 'Pilot', standard: 'Standard', large: 'Large', maximum: 'Maximum' },
    atOnceLabelOne: '{name}: {n} machines at once, {c} engine container',
    atOnceLabelMany: '{name}: {n} machines at once, {c} engine containers',
    atOnceMeaning: {
      pilot: 'Pilot moves a small number of machines, for a first wave or a test. The engine runs one container.',
      standard: 'Standard is the default. The engine runs 15 machines at once in one container.',
      large: 'The engine runs two containers, with 15 machines in each. Each container uses cores in the engine environment.',
      maximum: 'The engine runs four containers, with 15 machines in each. The wave editor checks that the engine environment has the cores.' },
    // WAVE-OWN-PICTURE-1 / ACCEPT-FIRST-MACHINE-1: a machine that does not
    // follow a setting of its wave - its value, and the cause where the plan
    // records one. The wave editor, the acceptance on the Migrations page and
    // the Run it step show these words (ownRowText). Each value says the label
    // of the setting's own control on the wave editor.
    ownOne:        '1 machine does not follow this setting.',
    ownMany:       '{n} machines do not follow this setting.',
    ownRowValue:   '{name}: {value}.',
    ownRowDecided: '{name}: {value}. {by} accepted this for the machine on {date}.',
    ownRowDecidedNoDate: '{name}: {value}. {by} accepted this for the machine.',
    // WAVE-KERNEL-LINE-1: no wave has a kernel setting, so no machine "does
    // not follow" one; the pages name the machines that update their kernel
    // on a row of their own.
    ownDataStop:    'Stop and ask',
    ownDataProceed: 'Continue - the files are deleted',
    ownDayOne:      '1 day',
    ownDays:        '{n} days',
    // ROLE-GATE-1. It says what to ask for and where, because the person
    // reading it cannot fix it themselves and there is no control here that
    // would.
    /* SIGNIN-1: the sign-in card, said ONCE.
     *
     * Eight pages each carried their own copy of it, and they had drifted:
     * one page's line never mentioned signing in at all (it described the page,
     * under a heading that said "Sign in"); one had its line written into the
     * markup where the strings gate could not see it, with a different button
     * class so the button looked different; one rendered its line through
     * innerHTML while the other seven used textContent.
     *
     * The words: the heading names the PRODUCT, because the button already
     * says "Sign in" and a card of three parts said it three times. The line
     * says what the product does, in its own nouns and Azure's. "Microsoft
     * Entra ID" is the name Microsoft uses, so it is the name a person
     * arriving from Azure has already learnt.
     *
     * The line is a tagline under the name. Its verb is migrate, the
     * product's own, as on the Assess and migrate button - not modernize,
     * which means a move to PaaS. Nothing follows the button.
     */
    signInTitle: 'Migration Factory',
    signInWhat:  'Assess and migrate Azure virtual machines.',
    signInBtn:   'Sign in with Microsoft Entra ID',
    noRoleTitle: 'You do not have access to this app yet',
    // Named separately because it is the sentence that ends the confusion:
    // somebody turned away is usually signed in as the wrong person.
    noRoleWho: 'You are signed in as {who}. Sign out to use a different account.',
    noRoleBody: 'You are signed in, but nobody has given you a role in Migration Factory. '
      + 'An administrator can add one on the Admin page.',
    signOutTip: 'Sign out, and remove your account from this browser.',
    menuTitle: 'What do you need help with?',
    menuFailure: 'A machine did not migrate',
    menuFailureSub: 'Builds a file describing this migration that you can send to support.',
    menuBug: 'Something on this screen is wrong',
    menuBugSub: 'Opens a bug report on GitHub in a new tab, with the page and version filled in.',
    menuIdea: 'I want to suggest something',
    menuIdeaSub: 'Opens a feature request on GitHub in a new tab.',
    menuLost: 'I do not understand what I am looking at',
    menuLostSub: 'Explains this screen, without leaving it.',
    // DOC-4: the manual ships with the dashboard, under manual/.
    menuManual: 'Read the manual',
    menuManualSub: 'From installing to a finished migration, every page and every setting.',
    // DOC-3
    guideWhatIs: 'What this screen is',
    guideHowRead: 'How to read it',
    guideNext: 'What to do next',
    guideGeneral: 'Read the manual',
    guideMissing: 'The guide could not be loaded. The manual is under Get help.',
    openGithub: 'Read the manual',
    title: 'Send us what happened',
    desc: 'This puts everything this dashboard can see about the migration into one file that you can send to support. '
      + 'It holds the activity log, one record per machine, the plan, the capacity the migration claimed, and any errors this page hit in your browser. '
      + 'It is built here in your browser from what you can already see. '
      + 'It contains the names of runs and machines, and no passwords, keys or tokens. This page holds none.',
    noRun: 'Open the migration on the Migrations page. Then select Get help again.',
    download: 'Download the file',
    cancel: 'Cancel',
    // VERSION-1
    versionBar: 'Version {v}',
    versionTip: 'Shows which build of the dashboard, the service and the engine you use.',
    versionTitle: 'About this dashboard',
    versionDashboard: 'Dashboard',
    versionService: 'Service',
    versionEngine: 'Engine',
    // "Build", never "commit". A commit hash is the source revision, which is
    // developer language and means nothing to an operator. The build number is
    // what support asks for, and that sentence says so.
    versionBuilt: 'Build {build}, made {when}.',
    versionWhatBuild: 'The build names the source code each part was made from. Quote it when you report a problem.',
    versionLocal: 'A local build with no build stamp.',
    // Two different "not yet"s. His first screenshot said "answers after you
    // sign in" while he WAS signed in: the service was cold-starting.
    versionServiceSignIn: 'Sign in with a role to read the service version.',
    versionServicePending: 'Reading the service version.',
    versionServiceUnknown: 'The service did not answer.',
    versionEngineDigest: 'The container image the engine runs. Each run records the engine version in its activity log.',
    versionEngineUnknown: 'The engine image could not be read.',
    versionSame: 'The dashboard and the service are the same build.',
    versionDiffer: 'The dashboard and the service are different builds. A deployment may be in progress, or one part did not deploy.',
    close: 'Close',
    working: 'Building the file...',
    failed: 'The file could not be built: ',
    // DISCLAIMER-1: the agreed words. Their one source is the engine's
    // data/disclaimer.json; tests/unit/Disclaimer.Tests.ps1 holds this copy
    // equal to it. Change them only there, and only by agreement.
    disclaimerLine: 'Migration Factory is not an official Microsoft product. Microsoft does not support or endorse it. It is provided as is, with no warranty.',
    disclaimerRead: 'Read the disclaimer',
    disclaimerTitle: 'Disclaimer',
    disclaimerP1: 'Migration Factory is not an official Microsoft product. Microsoft does not support, sponsor or endorse it.',
    disclaimerP2: 'Do not open an Azure support request for the product. Report a problem with the product on its GitHub repository.',
    disclaimerP3: 'The product is provided as is, with no warranty, under the Apache License 2.0. You are responsible for the changes it makes in your subscriptions. Test it on machines that are not in production first.',
    disclaimerOk: 'OK',
    // PAGE-SCALE-OVERVIEW-1: the words of the count tiles and the one list
    // (listMount). A page gives its own tile names, column names and empty
    // sentences; these are the same on every page.
    listTiles: 'Select a count to show its list.',
    listProject: 'Project',
    listAllProjects: 'All projects',
    listSearch: 'Search',
    listRange: '{from} to {to} of {total}',
    listPrevious: 'Previous',
    listNext: 'Next',
    listNoMatch: 'No row matches the project or the search.',
    // LOADING-LINE-1: a list whose read failed. The reason is in the page's error message.
    listReadFailed: 'The list could not be read. The message at the top of the page gives the reason.',
    // TILE-COUNT-READING-1: a count tile's words in place of its number while
    // the page reads, and after a read that failed.
    listCountReading: 'Reading',
    listCountFailed: 'Not known',
    // PAGE-SCALE-PROJECTS-1: the label of the sort choice a page can give.
    listSort: 'Sort',
    // PAGE-SCALE-REPORTS-1: the name of the tabs, when a page gives none.
    listTabs: 'Lists',
    // A tile counts every row; the list can show fewer. The range says why.
    listRangeFiltered: '{from} to {to} of {total} that match the filter',
    // A run's readable name: its project and the day it was made. The run id
    // shows small under it, so two runs of one day are still told apart.
    runTitleMigration: '{project} · migration of {date}',
    runTitleAssessment: '{project} · assessment of {date}',
    runTitleMigrationNoDate: '{project} · migration',
    runTitleAssessmentNoDate: '{project} · assessment',
    agoNow: 'just now',
    agoMinutes: ['{n} minute ago', '{n} minutes ago'],
    agoHours: ['{n} hour ago', '{n} hours ago'],
    agoDays: ['{n} day ago', '{n} days ago'],
  };

  // Which page this is. ONE definition: the menu and the guide both need it,
  // and the guide referencing the menu's local copy was an undefined variable
  // that no syntax check would have caught.
  // The DEFAULT DOCUMENT, not a page link: an address ending in a slash is
  // served by index.html. This said 'migrations.html' for an hour after the
  // rename (HOME-1), so the root highlighted the wrong tab and opened the
  // wrong help topic - a blanket rename turning a fallback into a link.
  const currentPage = () => (location.pathname.split('/').pop() || 'index.html');

  // DOC-3: the guide for the screen the person is actually on. Falls back to
  // GitHub if it cannot be loaded - a help button that does nothing is worse
  // than one that sends you somewhere.
  async function guideDialog() {
    let guide = null;
    try {
      const r = await fetch('operator-guide.json', { cache: 'no-cache' });
      if (r.ok) { guide = await r.json(); }
    } catch (e) { guide = null; }

    const screen = guide && guide.screens ? guide.screens[currentPage()] : null;
    if (!screen) {
      dialog(`<p>${esc(TEXT.guideMissing)}</p>`, [
        { label: TEXT.openGithub, primary: true, onClick: (d) => { d.remove(); openManual(); } },
        // CLOSE-NOT-CANCEL-1: the guide only shows information, so Close.
        { label: TEXT.close, onClick: (d) => d.remove() },
      ], TEXT.nav);
      return;
    }

    const list = (items) => `<ul style="margin:6px 0 0;padding-left:18px">${
      (items || []).map((t) => `<li style="margin:4px 0">${esc(t)}</li>`).join('')}</ul>`;
    const general = guide.general && guide.general.points ? `
      <h3 style="margin:16px 0 0;font-size:13px;font-weight:800">${esc(guide.general.title)}</h3>
      ${list(guide.general.points)}` : '';

    dialog(`
      <h3 style="margin:0 0 2px;font-size:13px;font-weight:800">${esc(TEXT.guideWhatIs)}</h3>
      <p style="margin:0 0 10px">${esc(screen.what)}</p>
      <h3 style="margin:0 0 2px;font-size:13px;font-weight:800">${esc(TEXT.guideHowRead)}</h3>
      ${list(screen.howToRead)}
      <h3 style="margin:14px 0 2px;font-size:13px;font-weight:800">${esc(TEXT.guideNext)}</h3>
      <p style="margin:0">${esc(screen.nextStep)}</p>
      ${general}`, [
      { label: TEXT.guideGeneral, onClick: (d) => { d.remove(); openManual(); } },
      { label: TEXT.close, primary: true, onClick: (d) => d.remove() },
    ], screen.title);
  }

  function dialog(bodyHtml, buttons, titleText) {
    const back = document.createElement('div');
    back.setAttribute('style', 'position:fixed;inset:0;background:rgba(15,23,42,.45);display:flex;' +
      'align-items:center;justify-content:center;z-index:9999;padding:20px;');
    // DIALOG-1: this ignored the light and dark themes. It painted a white
    // card, slate text and a blue button of its own - on every help dialog
    // since HELP-2 - because DARK-1 moved the PAGES to tokens and never
    // reached this file. Tokens now, and the page's own buttons.
    back.innerHTML = '<div role="dialog" aria-modal="true" style="background:var(--card);color:var(--ink);border:1px solid var(--line);' +
      'border-radius:14px;max-width:560px;width:100%;box-shadow:var(--shadow);font-size:14px;line-height:1.5">' +
      '<div style="padding:18px 20px 0"><h2 style="margin:0 0 8px;font-size:16px;font-weight:800">' + esc(titleText || TEXT.title) + '</h2>' +
      '<div id="vmf-help-body">' + bodyHtml + '</div></div>' +
      '<div id="vmf-help-actions" style="display:flex;gap:10px;justify-content:flex-end;padding:16px 20px 18px"></div></div>';
    /* LEAK-2: the Escape listener is on `document`, so it outlives the dialog
     * node unless something takes it off.
     *
     * It used to be removed on ONE path: the Escape branch itself. Every other
     * way a dialog closes - the backdrop click, and every button whose
     * onClick does d.remove() - detached the node and left the listener
     * installed, holding a closure over the whole detached dialog. One more
     * per help menu, guide, About or bundle dialog opened and closed, on a
     * page meant to be left open all day.
     *
     * Three ways out, because a caller's own onClick is not ours to change:
     * close() retires it, a button that removed the node retires it, and a
     * keypress arriving after the node is gone retires it. */
    const close = () => { document.removeEventListener('keydown', onKey); back.remove(); };
    function onKey(e) {
      if (!back.isConnected) { document.removeEventListener('keydown', onKey); return; }
      if (e.key === 'Escape') { close(); }
    }

    const actions = back.querySelector('#vmf-help-actions');
    for (const b of buttons) {
      const el = document.createElement('button');
      el.type = 'button';
      el.textContent = b.label;
      el.className = b.primary ? 'btn' : 'btn ghost';
      el.addEventListener('click', () => {
        b.onClick(back);
        // Most callers close by removing the node themselves.
        if (!back.isConnected) { document.removeEventListener('keydown', onKey); }
      });
      actions.appendChild(el);
    }
    back.addEventListener('click', (e) => { if (e.target === back) close(); });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(back);
    return back;
  }

  /* PAGE-LOAD-2: what the support bundle reads, in ONE call for the run
   * (store/docs with the run as the prefix). Before, it was six folder walks
   * side by side, up to 48 reads at once (PERF-ONE-LIMIT-2). */
  const BUNDLE_READS = ['run-status.json', 'plan.json', 'assessment.json', 'state/*.json', 'capacity/*.json',
    'capacity-history/*.json', 'approvals/*.json', 'schedules/*.json', 'acceptances/*.json', 'logs/events*.jsonl'];

  async function buildBundle(run) {
    const gaps = [];
    /* PAGE-LOAD-2: the run's documents in one call, when the page can make it
     * (adapter.runDocs). Each reader below answers from it first, and asks
     * the page's own reader only what it cannot say (unknown means ask). A
     * call that fails leaves `held` null, and the bundle reads as before. */
    let held = null;
    if (adapter.runDocs) {
      try { held = await adapter.runDocs(run, BUNDLE_READS); } catch (e) { held = null; }
    }
    /* PERF-ONE-LIMIT-2: every read the bundle still sends takes a slot from
     * ONE limit, so the six walks together send at most STORE_READ_LIMIT at
     * once, not 8 each. A slot is held for one read (see readLimiter). */
    const limit = readLimiter();
    const readJson = (rel) => {
      const known = heldJson(held, `${run}/${rel}`);
      return known ? known.value : limit(() => adapter.readJson(run, rel));
    };
    const readOr = async (rel, fallback) => { try { return await readJson(rel); } catch (e) { gaps.push(`${rel}: ${e && e.message ? e.message : String(e)}`); return fallback; } };
    const listOr = async (folder) => {
      try {
        const known = heldList(held, `${run}/${folder}/`);
        if (known) { return known.names.map(n => n.slice(run.length + 1)); }
        return await limit(() => adapter.listFolder(run, folder));
      } catch (e) { gaps.push(`${folder}/: ${e && e.message ? e.message : String(e)}`); return []; }
    };

    // PAGE-WAIT-1: the log is read beside the documents, not after them.
    // PAGE-LOAD-2: the page's reader is given the run's documents too, so the
    // log comes from the same call; one slot covers the walk of its parts.
    const eventsRead = (async () => { try { return await limit(() => adapter.readLines(run, 'logs/events.jsonl', held)); } catch { return []; } })();
    // REPORT-RELEASED-1: released on-demand capacity reservations kept as history travel too.
    const [status, plan, assessment, stateNames, capNames, apprNames, schedNames, accNames, histNames] = await Promise.all([
      readOr('run-status.json', null), readOr('plan.json', null), readOr('assessment.json', null),
      listOr('state'), listOr('capacity'), listOr('approvals'), listOr('schedules'), listOr('acceptances'),
      listOr('capacity-history'),
    ]);
    // EVAL-M13: .catch() only helps if readJson RETURNED a promise. A host
    // page whose adapter throws synchronously - a typo'd function name, which
    // is exactly what happened - blew straight past this and took the whole
    // bundle with it. A support bundle must degrade to the parts it could
    // gather, never to nothing, because it is collected by someone already
    // stuck. Note what was missed rather than pretending it was empty.
    const readOne = async (rel) => {
      try { return await readJson(rel); }
      catch (e) { gaps.push(`${rel}: ${e && e.message ? e.message : String(e)}`); return null; }
    };
    // STORE-READ-2: paced, not truncated. A support bundle for a fleet-scale
    // run reads one document per machine; all of them still arrive.
    const readAll = async (names) => (await mapLimited(
      (names || []).filter(n => n.endsWith('.json')), n => readOne(n))).filter(Boolean);

    const events = (await eventsRead) || [];
    const truncated = events.length > EVENT_CAP;
    // Newest are the ones that explain a failure, so keep the TAIL and say so.
    const included = truncated ? events.slice(-EVENT_CAP) : events;

    const [machines, capacity, approvals, schedules, acceptances, capacityHistory] =
      await Promise.all([readAll(stateNames), readAll(capNames), readAll(apprNames), readAll(schedNames), readAll(accNames), readAll(histNames)]);

    return {
      bundle: 'vmf.support/1',
      generatedUtc: new Date().toISOString(),
      run,
      builtOn: location.pathname.split('/').pop() || 'index.html',
      // VERSION-1: which builds made this file. Support's first question.
      dashboardVersion: (build && build.version) || null,
      serviceVersion: (service && service.service && service.service.version) || null,
      whatThisIs: 'Everything this dashboard can see about one migration run, assembled in the browser so it can be sent to support.',
      // DISCLAIMER-1: the file leaves the app, so it says what the app says.
      disclaimer: TEXT.disclaimerLine,
      whatItContains: [
        'the run status, the plan, and the assessment it came from',
        'one record per machine: its state, history, checkpoints and what ran inside it',
        'the activity log' + (truncated ? ' (the most recent ' + EVENT_CAP + ' entries of ' + events.length + ')' : ''),
        'quota records, released on-demand capacity reservations kept as history, approvals, accepted settings and schedules',
        'which build of the dashboard and of the service made this file',
        // CLIENT-ERR-1: say it plainly, and say when there are none. "recent
        // errors from this page" with an empty list underneath reads as a
        // failure to collect them.
        clientErrors.length
          ? 'the ' + clientErrors.length + ' most recent error(s) this page hit in your browser'
          : 'no errors in this page since it was opened',
      ],
      // What it does NOT hold, IN THE FILE - not only in the dialog that
      // offered it. Whoever receives this needs to know what is safe about it
      // without having to trust a screen they never saw. The engine's own
      // Export-VmfSupportBundle has said both halves from the start; the
      // browser copy said only the first.
      whatItDoesNotContain: [
        "no tokens, keys, connection strings or SAS - the store is read with the viewer's own Azure sign-in, and this page holds no secret of any kind",
        'no passwords and no guest credentials',
        'guest evidence files are named rather than inlined; ask support which one is wanted',
      ],
      status, plan, assessment, machines, capacity, capacityHistory, approvals, schedules, acceptances,
      events: included, eventsTruncated: truncated, eventsTotal: events.length,
      // CLIENT-ERR-1: what the PAGE hit, beside what the migration did. A copy
      // rather than the array itself, so editing the bundle cannot reach back
      // into the recorder.
      clientErrors: clientErrors.slice(),
      // Empty on a healthy page. Non-empty means this bundle is PARTIAL and
      // says which parts are missing and why - which is worth far more to
      // whoever reads it than a bundle that quietly left things out.
      couldNotRead: gaps,
    };
  }

  function download(bundle, run) {
    const name = 'vmf-support-' + String(run || 'run').replace(/[^A-Za-z0-9._-]/g, '-') +
      '-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json';
    const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    // Revoke on a later turn: revoking straight away can cancel the download
    // in some browsers before it has finished reading the blob.
    setTimeout(() => URL.revokeObjectURL(url), 30000);
  }

  /* NO-POPUPS-1: the two GitHub choices. A bug report is worth more with the
   * page and the run on it, and those are things the person can see and
   * remove before sending. */
  function issueHref(kind, page, run) {
    const body = kind === 'bug'
      ? `Page: ${page}
Version: ${versionSummary()}
Migration: ${run || '(none open)'}

What I did:

What I expected:

What happened instead:
`
      : `What I would like to be able to do:

Why:
`;
    return issueUrl(kind === 'bug' ? 'bug_report.md' : 'feature_request.md',
      kind === 'bug' ? `[${page}] ` : '', body);
  }

  function menu() {
    const page = currentPage();
    const run = adapter && adapter.getRunId ? adapter.getRunId() : '';
    const look = `style="display:block;width:100%;box-sizing:border-box;text-align:left;text-decoration:none;` +
      `background:var(--card-2);border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:0 0 8px;cursor:pointer;font:inherit"`;
    const inner = (label, sub) => `<strong style="color:var(--ink)">${esc(label)}</strong><br>` +
      `<span style="color:var(--muted);font-size:12.5px">${esc(sub)}</span>`;
    const item = (id, label, sub) => `<button type="button" data-help="${id}" ${look}>${inner(label, sub)}</button>`;
    // NO-POPUPS-1: the
    // GitHub issue page is a LINK that opens in a new tab, so the dashboard
    // stays open. A link the person clicks, never a window.open: a popup
    // blocker does not stop it. Only this product's own issue page qualifies
    // (isIssueLink).
    const issueItem = (id, label, sub) => {
      const href = issueHref(id, page, run);
      const tab = isIssueLink(href) ? 'target="_blank" rel="noopener noreferrer"' : 'rel="noreferrer"';
      return `<a data-help="${id}" href="${esc(href)}" ${tab} ${look}>${inner(label, sub)}</a>`;
    };
    const box = dialog(
      `<p style="margin:0 0 10px;color:var(--muted)">${esc(TEXT.menuTitle)}</p>` +
      item('failure', TEXT.menuFailure, TEXT.menuFailureSub) +
      issueItem('bug', TEXT.menuBug, TEXT.menuBugSub) +
      issueItem('idea', TEXT.menuIdea, TEXT.menuIdeaSub) +
      item('lost', TEXT.menuLost, TEXT.menuLostSub) +
      item('manual', TEXT.menuManual, TEXT.menuManualSub),
      [{ label: TEXT.cancel, onClick: (d) => d.remove() }], TEXT.nav);

    box.querySelectorAll('[data-help]').forEach((b) => b.addEventListener('click', () => {
      const kind = b.dataset.help;
      // The link opens its tab; the menu closes after the click has done it.
      if (kind === 'bug' || kind === 'idea') { setTimeout(() => box.remove(), 0); return; }
      box.remove();
      if (kind === 'failure') { bundleDialog(); return; }
      // DOC-3: the documentation belongs IN the app.
      // This used to open the GitHub README in a new tab, which sends somebody
      // mid-migration out of the product to read about the product. The guide
      // now ships WITH the app (copied at deploy
      // from the engine's own file, never a second copy) and opens here.
      if (kind === 'lost') { guideDialog(); return; }
      // DOC-4: the manual is served by the dashboard itself, so it opens
      // even when nothing outside the subscription can be reached.
      if (kind === 'manual') { openManual(); return; }
    }));
    return box;
  }

  function bundleDialog() {
    const run = adapter && adapter.getRunId ? adapter.getRunId() : null;
    if (!run) {
      dialog('<p style="margin:0;color:var(--muted)">' + esc(TEXT.noRun) + '</p>',
        [{ label: TEXT.close, onClick: (d) => d.remove() }]);
      return;
    }
    const box = dialog('<p style="margin:0;color:var(--muted)">' + esc(TEXT.desc) + '</p>' +
      '<p id="vmf-help-state" style="margin:10px 0 0;color:var(--muted)"></p>', [
      { label: TEXT.cancel, onClick: (d) => d.remove() },
      {
        label: TEXT.download, primary: true, onClick: async (d) => {
          const state = d.querySelector('#vmf-help-state');
          state.textContent = TEXT.working;
          try {
            download(await buildBundle(run), run);
            d.remove();
          } catch (e) {
            state.textContent = TEXT.failed + (e && e.message ? e.message : String(e));
          }
        }
      }]);
    return box;
  }

  function open() { return menu(); }

  function install(a) {
    // The adapter is refreshed every time - the caller may know a different run
    // now than it did on the last render, and getRunId is read at open time.
    adapter = a;
    const link = document.querySelector('#nav-help');
    if (!link) return;
    link.textContent = TEXT.nav;
    link.setAttribute('href', '#');
    link.setAttribute('role', 'button');

    // BUT THE HANDLER IS ATTACHED ONCE. The symptom was that cancelling the
    // help dialog appeared to reopen it as a different dialog.
    //
    // migrations.html calls install() from renderActMenu(), which re-runs on every
    // render. addEventListener does not replace, it ADDS - so after N renders
    // one click called open() N times and stacked N dialogs on top of each
    // other. Cancelling removed the top one and revealed the next, which looks
    // exactly like the dialog reopening itself. The longer a page had been
    // sitting there, the more times it happened.
    //
    // A flag on the element rather than a module variable, because the element
    // is what the handler is on: if the page ever replaces its own nav, the
    // new link legitimately needs a handler and gets one.
    if (link.dataset.vmfHelpBound === '1') return;
    link.dataset.vmfHelpBound = '1';
    link.addEventListener('click', (e) => { e.preventDefault(); open(); });
  }

  // ---------- the navigation bar, in ONE place ----------
  //
  // The tabs used to disagree with each other: the same tab was named one
  // thing on one page and something else on the next.
  //
  // Because every page carried its own copy of the labels - six of them - so
  // the same tab was whatever each page happened to say. Adding a page meant
  // editing six files, and changing one word meant remembering all six. Two had
  // already drifted: the new page called it "Migrations" while five said
  // "Runs", and index called Admin "Manage access".
  //
  // So the bar is rendered from here, by the one file every page already loads.
  // A page cannot disagree with the others about a label it does not hold, and
  // adding a tab is one line in one place.

  // PROJECT-1: what RUNS exist in the store, now that they may live inside a
  // project. ONE definition, shared - three pages each had their own one-liner,
  // which was fine while every run was top-level and is precisely what breaks
  // the moment one is not.
  //
  // A top-level prefix is either a RUN (it has run.json) or a PROJECT (it has
  // project.json and its runs are one level down). Both are listed, and a run
  // inside a project keeps its full "project/run" id so every existing lookup
  // still resolves.
  //
  // Derived from the store rather than an index: an index of projects is a
  // second source of truth that can disagree with the projects.
  /* PLANVER-2: THE BROWSER NO LONGER COMPUTES A PLAN VERSION, and the function
   * that did is DELETED rather than left exported.
   *
   * It hashed the plan text the page had fetched. That is the right property -
   * name the plan you were shown - by a mechanism that quietly required the
   * document to travel BYTE FOR BYTE through a JSON service. Nobody wrote that
   * requirement down and the platform does not honour it.
   *
   * MEASURED 2026-09-17 against a real install: the same blob, at the same
   * path, produced one version in the service and another here. No candidate
   * reading - a byte-order mark, a trailing newline - closed the gap, and the
   * acceptance was refused for ever, on both pages.
   *
   * The SERVICE issues it now, over the bytes it read from the store, beside
   * the document in ONE response. See storeBlob's `asVersioned`. A page quotes
   * it back and nothing downstream recomputes anything, so how the body
   * travels stops mattering.
   *
   * A function that computes a value callers must not compute is a trap: it
   * keeps looking correct, and the next person who needs a version finds it.
   */
  /* WAVE-FLOW-1: the migrate journey, and the strip that shows where you are.
   *
   * THREE STEPS, and the middle one is the wave editor - a different page.
   * That is the whole reason this lives here rather than on the wizard: two
   * pages draw the same strip, and a journey whose steps are written down
   * twice is a journey that comes to disagree with itself.
   *
   * It used to be four. Two of them did nothing: a read-only summary of waves
   * with a yes button, and a capacity step that usually said there was nothing
   * to check - while the screen where the work happens sat behind a button
   * called "Rearrange these waves", which reads as a layout tool.
   */
  // ADVISOR-1: each machine's target is chosen before the waves.
  /**
   * WAVE-ORDER-1: the waves of a plan in the order they run - the plan's own
   * waveOrder, then any wave it does not name in the order it first appears.
   * The engine's Get-VmfPlanWaveOrder is the same rule, so a page shows the
   * order that runs. Every page used its own before: the run page sorted by
   * name, the others by the order of the machines.
   */
  function waveOrder(plan) {
    const present = [];
    for (const e of (plan?.entries ?? [])) {
      const w = e?.wave;
      if (w && w !== 'unscheduled' && !present.includes(w)) present.push(w);
    }
    const out = (plan?.waveOrder ?? []).filter((w, i, all) => present.includes(w) && all.indexOf(w) === i);
    for (const w of present) if (!out.includes(w)) out.push(w);
    return out;
  }

  // MACHINE-PICK-1: which machines move comes first.
  const MIGRATE_STEPS = ['Choose the machines', 'Choose each target', 'How to group them', 'Arrange the waves', 'Run it'];

  /** The strip, with `current` (1-based) lit and everything before it ticked. */
  function stepRail(labels, current) {
    return (labels || []).map((label, i) => {
      const n = i + 1;
      const cls = current > n ? 'done' : current === n ? 'now' : '';
      return `<div class="st ${cls}"><span class="n">${current > n ? '&#10003;' : n}</span>${esc(label)}</div>`;
    }).join('');
  }
  /* WAIT-1: what a page shows in the seconds before its first read lands.
   *
   * Every page reveals its shell, reads the store, then paints. The reads are
   * not fast - a page walks the store for every project, then every run inside
   * it, then documents inside those, paced eight at a time. For those seconds
   * a person saw an empty table, an empty card, or worse, a finished sentence
   * saying the thing they were waiting for does not exist.
   *
   * THE SENTENCE IS THE WORST OF THE THREE, because it is indistinguishable
   * from the truth. "Nothing has been assessed yet" is correct-looking and
   * wrong, and somebody who reads it goes looking for what they lost.
   *
   * So a page holds its empty message until it has looked, and shows one of
   * these instead. The words name what is being read, not that something is
   * happening: five pages all saying "Loading" tell nobody which one is slow.
   *
   * These two exist so the shape and the class are the same everywhere. What
   * the sentence SAYS belongs to the page, in its own UX strings.
   */
  function waitingLine(text) {
    return `<p class="muted vmf-waiting">${esc(text)}</p>`;
  }

  /** The same, for a table that has not been filled in yet. */
  function waitingRow(text, columns) {
    const span = Math.max(1, Number(columns) || 1);
    return `<tr><td colspan="${span}" class="muted vmf-waiting">${esc(text)}</td></tr>`;
  }

  /* PAGE-SCALE-OVERVIEW-1: the count tiles and the one list, said ONCE.
   *
   * With many migrations, the Overview was one long scroll: it drew a table
   * for each thing it counted, one after the other, each with a row for every item. Projects,
   * Assessments and Reports have the same shape (PAGE-SCALE-PROJECTS-1,
   * -ASSESSMENTS-1, -REPORTS-1), so the piece that replaces the tables is here,
   * and each page gives it only what it alone knows.
   *
   * THE SHAPE A PAGE GIVES. listMount(host, cfg) draws into `host` and gives
   * back { update(data), state() }. cfg: { id (unique on the page; the ids of
   * the controls start with it), preferred (the tile to show first when it has
   * rows), searchHint, columns, tilesLabel, sorts, projectFilter, waiting }.
   * data: { tiles, projects, tabs, reading }.
   *   waiting, reading (LOADING-LINE-1) the page's own "Reading ..."
   *           sentence, and whether the page still reads. From the mount
   *           until an update says the read ended, a tile with no row to
   *           show says the sentence, never its "none" sentence, and the
   *           pager says no "0 to 0 of 0". An update with no `reading` is a
   *           finished read, so a page cannot leave the sentence up for ever.
   *           A tab with a list of its own keeps its own empty sentence.
   *   failed  (LOADING-LINE-1) true when the page's read failed: a tile
   *           with no row says the read failed (TEXT.listReadFailed),
   *           never its "none" sentence, and the pager says nothing.
   *   tabs    (PAGE-SCALE-REPORTS-1) [{ key, label, intro, list }]: two or
   *           more draw a tablist above the list (role="tab", the arrow keys
   *           move between them). A tab with no `list` shows the selected
   *           tile's rows, and pressing a tile selects it; a tab with a list
   *           { title, empty, intro, rows, columns } shows those rows, and no
   *           tile is pressed. `intro` is a sentence above the table. The
   *           project, the search and the pages apply to every tab.
   *   sorts   (PAGE-SCALE-PROJECTS-1) [{ key, label, field, type, order }]:
   *           a Sort choice, the first the default. type is text, number or
   *           time (an ISO time); order is asc or desc. A row with no value
   *           goes last, and rows of the same value go by name. No sorts: no
   *           Sort choice, and the rows stay in the order the page gave.
   *   projectFilter  false: no project choice (a list whose rows ARE the
   *           projects).
   *   tabsLabel (PAGE-SCALE-REPORTS-1) the name a screen reader gives the
   *           tabs (data.tabs).
   *   project (PAGE-SCALE-ASSESSMENTS-1) a project id: the project filter
   *           to start with, set once the projects the page gives hold it
   *           (they arrive as the page reads). A person's own choice wins.
   *   tile    { key, label, hint, tone, title, empty, rows, columns }. `rows` is
   *           every row of the tile; the count is its length. `columns`, when
   *           given, replaces cfg.columns for this tile. `title` heads the
   *           list (else the label) and `empty` is said when it has no row.
   *   row     { id, name, projectId (null: outside a project), project, dest,
   *           and the fields its columns name }. The search reads name, id and
   *           project; the project filter reads projectId.
   *   column  { head, kind, key }. kind: name (row.name, linked by row.dest,
   *           with row.id small under it, and row.note under that when
   *           given; row.open { action, value } puts data-action and
   *           data-value on the link too, so the page can open the row in
   *           place and the address still works in a new tab), text, num, tag ({ text, tone }), ago (an ISO time),
   *           link ({ text, page, run }), count ({ n, dest }: a link when n is
   *           more than 0, else a muted 0), actions (a list of { text, dest }
   *           links and { text, action, value, disabled, note } buttons; note
   *           is a list of { text, dest } parts shown UNDER the button, so a
   *           disabled one says why where it can be read). A button carries
   *           data-action and data-value; the page listens for the click.
   *   dest    { page, run } or { page, project }: page is a page of this app
   *           by name (listHref), and the run or the project goes in the
   *           query as every page reads it.
   * Every value is escaped here, so a page never builds the markup of a row.
   *
   * NOTHING HIDES UNTIL A PERSON SELECTS (the rule: main content never
   * collapses by state). Every tile is always drawn, with its count, and the
   * list shows one tile's rows. The default is `preferred` when it has rows,
   * else the first tile with rows - and once a person selects a tile, the page
   * reading more rows does not move them off it. */
  const LIST_PAGE_SIZE = 10;
  // The project filter's value for a run outside any project. A project id is
  // lowercase letters, numbers and dashes, so it can never be this.
  const LIST_LOOSE = '(outside)';
  const LIST_TONES = ['bad', 'warn', 'good', 'quiet', 'muted'];

  function listMatches(row, project, query) {
    if (project) {
      const pid = (row.projectId === null || row.projectId === undefined || row.projectId === '') ? LIST_LOOSE : String(row.projectId);
      if (pid !== project) { return false; }
    }
    const q = String(query ?? '').trim().toLowerCase();
    if (!q) { return true; }
    return [row.name, row.id, row.project].some(v => String(v ?? '').toLowerCase().includes(q));
  }

  /* PAGE-SCALE-PROJECTS-1: the value a row sorts by, or null when it has none
   * that reads as its type. */
  function listSortValue(row, spec) {
    const v = row ? row[spec.field] : null;
    if (v === null || v === undefined || v === '') { return null; }
    if (spec.type === 'number') { const n = Number(v); return isFinite(n) ? n : null; }
    if (spec.type === 'time') { const at = Date.parse(v); return isFinite(at) ? at : null; }
    return String(v);
  }

  /* The rows in the order a sort gives, as a new list. A row with no value
   * goes last whatever the order, and rows of one value go by name, so the
   * order never changes between two draws of the same rows. */
  function listSort(rows, spec) {
    const list = (rows || []).slice();
    if (!spec || !spec.field) { return list; }
    const dir = spec.order === 'desc' ? -1 : 1;
    const byName = (a, b) => String(a.name ?? '').localeCompare(String(b.name ?? ''), undefined, { sensitivity: 'base' });
    return list.sort((a, b) => {
      const x = listSortValue(a, spec), y = listSortValue(b, spec);
      if (x === null || y === null) { return x === y ? byName(a, b) : (x === null ? 1 : -1); }
      const c = typeof x === 'string' ? x.localeCompare(y, undefined, { sensitivity: 'base' }) : (x < y ? -1 : (x > y ? 1 : 0));
      return c ? c * dir : byName(a, b);
    });
  }

  /** The rows that match, in the order of the sort, and the page of them to
   *  show (0-based, kept inside the pages there are). */
  function listView(rows, opts) {
    const o = opts || {};
    const size = LIST_PAGE_SIZE;
    const all = listSort((rows || []).filter(r => listMatches(r, o.project, o.query)), o.sort);
    const pages = Math.max(1, Math.ceil(all.length / size));
    const page = Math.min(Math.max(0, Math.floor(Number(o.page) || 0)), pages - 1);
    const shown = all.slice(page * size, page * size + size);
    return { rows: shown, total: all.length, page, pages,
             from: all.length ? page * size + 1 : 0, to: page * size + shown.length };
  }

  function listDefaultTile(tiles, preferred) {
    const list = tiles || [];
    const want = list.find(t => t.key === preferred);
    if (want && (want.rows || []).length) { return want.key; }
    const first = list.find(t => (t.rows || []).length);
    if (first) { return first.key; }
    if (want) { return want.key; }
    return list.length ? list[0].key : null;
  }

  function listRangeText(view, filtered) {
    return (filtered ? TEXT.listRangeFiltered : TEXT.listRange)
      .replace('{from}', view.from).replace('{to}', view.to).replace('{total}', view.total);
  }

  /* A link a row carries, as an address of THIS app only: the page by name,
   * the run in the query as runLink writes it. Anything else is '#'. */
  function listHref(dest) {
    const l = dest || {};
    // PAGE-SCALE-PROJECTS-1: a project alone goes in the query the way the
    // Assessments, Migrations and wizard pages read it (?project=).
    const q = l.project ? `?project=${encodeURIComponent(l.project)}` : '';
    // Each page is written out: the check of every link a page writes
    // (tests/js/_html-sinks.js) proves an address by its literal start.
    switch (l.page) {
      case 'migrations': return l.run ? runLink('migrations.html', l.run) : 'migrations.html' + q;
      case 'wizard': return l.run ? runLink('wizard.html', l.run) : 'wizard.html' + q;
      case 'assessments': return l.run ? runLink('assessments.html', l.run) : 'assessments.html' + q;
      case 'projects': return l.run ? runLink('projects.html', l.run) : 'projects.html' + q;
      case 'reports': return l.run ? runLink('reports.html', l.run) : 'reports.html' + q;
      default: return '#';
    }
  }

  function listTone(tone) {
    return LIST_TONES.includes(tone) ? tone : '';
  }

  function listTag(tag) {
    const tone = listTone(tag && tag.tone);
    const text = tag ? tag.text : '';
    if (tone === 'muted') { return `<span class="muted">${esc(text)}</span>`; }
    return `<span class="pill${tone ? ' ' + esc(tone) : ''}">${esc(text)}</span>`;
  }

  /* PAGE-SCALE-PROJECTS-1: one part of the reason under a button - text, or
   * a link to the thing it names. */
  function listNotePart(part) {
    if (!part) { return ''; }
    return part.dest ? `<a href="${esc(listHref(part.dest))}">${esc(part.text)}</a>` : esc(part.text);
  }

  /* One action of a row: a link when it has a dest, else a button the page
   * listens for by data-action. A disabled button shows its reason under it,
   * never in a hover: a hover has no keyboard, touch or screen reader path
   * (PROJ-EMPTY-1). */
  function listAction(a) {
    if (!a) { return ''; }
    if (a.dest) { return `<a class="btn ghost small" href="${esc(listHref(a.dest))}">${esc(a.text)}</a>`; }
    const note = a.disabled && Array.isArray(a.note) && a.note.length
      ? `<div class="muted vmf-note">${a.note.map(listNotePart).join('')}</div>` : '';
    return `<button type="button" class="btn ghost small" data-action="${esc(a.action)}" data-value="${esc(a.value)}"${a.disabled ? ' disabled' : ''}>${esc(a.text)}</button>${note}`;
  }

  /* PAGE-SCALE-ASSESSMENTS-1: what a name link carries when the page opens
   * the row in place (the Assessments page opens its report panel). */
  function listOpenAttrs(open) {
    if (!open || !open.action) { return ''; }
    return ` data-action="${esc(open.action)}" data-value="${esc(open.value)}"`;
  }

  /* The class of a column's head and cells: numbers on the right, and the
   * actions on one line. */
  function listCellClass(col) {
    if (col.kind === 'num' || col.kind === 'count') { return ' class="num"'; }
    if (col.kind === 'actions') { return ' class="vmf-actions"'; }
    return '';
  }

  function listCell(col, row) {
    const v = row ? row[col.key] : null;
    switch (col.kind) {
      case 'name':
        // PAGE-SCALE-REPORTS-1: a row with no address (a record of a deleted
        // migration has no page) names itself as text, not as a dead link.
        return (row.dest ? `<a class="vmf-name" href="${esc(listHref(row.dest))}"${listOpenAttrs(row.open)}>${esc(row.name)}</a>` : `<span class="vmf-name">${esc(row.name)}</span>`) +
          `<div class="mono muted vmf-sub">${esc(row.id)}</div>` +
          (row.note ? `<div class="muted vmf-desc">${esc(row.note)}</div>` : '');
      case 'count': {
        const n = v && Number.isFinite(Number(v.n)) ? Number(v.n) : 0;
        return n > 0 ? `<a href="${esc(listHref(v.dest))}">${esc(n)}</a>` : '<span class="muted">0</span>';
      }
      case 'actions': return Array.isArray(v) ? v.map(listAction).join(' ') : '';
      // PAGE-SCALE-REPORTS-1: a tag can carry a note after it (the counts
      // behind an outcome).
      case 'tag': return v ? listTag(v) + (v.note ? ` <span class="outcome-note">${esc(v.note)}</span>` : '') : '';
      case 'num':
        if (v === null || v === undefined || v === '') { return ''; }
        return typeof v === 'object' ? listTag(v) : esc(v);
      case 'ago': return `<span class="muted">${esc(agoText(v, Date.now()))}</span>`;
      case 'link': return v ? `<a class="btn ghost small" href="${esc(listHref(v))}">${esc(v.text)}</a>` : '';
      default: return esc(v);
    }
  }

  /* TILE-COUNT-READING-1: state is 'reading' while the page reads and
   * 'failed' after a read that failed. Then a tile shows words, never a
   * number: a count of rows read so far, or of a store nobody could read, is
   * not the count. */
  function listTilesHtml(tiles, selected, state) {
    const words = state === 'reading' ? TEXT.listCountReading : (state === 'failed' ? TEXT.listCountFailed : '');
    return (tiles || []).map(t => {
      const tone = listTone(t.tone);
      return `<button type="button" class="kpi vmf-tile${tone ? ' t-' + esc(tone) : ''}" data-tile="${esc(t.key)}" aria-pressed="${t.key === selected ? 'true' : 'false'}">` +
        (words ? `<span class="val vmf-waiting">${esc(words)}</span>` : `<span class="val">${esc((t.rows || []).length)}</span>`) +
        `<span class="label">${esc(t.label)}</span>` +
        `${t.hint ? `<span class="sub">${esc(t.hint)}</span>` : ''}</button>`;
    }).join('');
  }

  function listTableHtml(columns, view, emptyText) {
    const cols = columns || [];
    const head = cols.map(c => `<th scope="col"${listCellClass(c)}>${esc(c.head)}</th>`).join('');
    const body = view.rows.length
      ? view.rows.map(r => `<tr>${cols.map(c => `<td${listCellClass(c)}>${listCell(c, r)}</td>`).join('')}</tr>`).join('')
      : `<tr><td colspan="${Math.max(1, cols.length)}" class="muted vmf-waiting">${esc(emptyText)}</td></tr>`;
    return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
  }

  function listPagerHtml(view, filtered) {
    const first = view.page <= 0, last = view.page >= view.pages - 1;
    return `<span class="vmf-range" aria-live="polite">${esc(listRangeText(view, filtered))}</span>` +
      `<span class="vmf-pages"><button type="button" class="btn ghost small" data-page="prev"${first ? ' disabled' : ''}>${esc(TEXT.listPrevious)}</button>` +
      `<button type="button" class="btn ghost small" data-page="next"${last ? ' disabled' : ''}>${esc(TEXT.listNext)}</button></span>`;
  }

  function listControlsHtml(cfg, projects, st) {
    const id = esc(cfg.id);
    // PAGE-SCALE-PROJECTS-1: the Sort choice, when the page gives sorts.
    const sorts = cfg.sorts || [];
    const sort = sorts.length
      ? `<label class="vmf-ctl">${esc(TEXT.listSort)} <select id="${id}-sort" data-list="sort">` +
        sorts.map(s => `<option value="${esc(s.key)}"${s.key === st.sort ? ' selected' : ''}>${esc(s.label)}</option>`).join('') +
        '</select></label>'
      : '';
    const opts = [`<option value="">${esc(TEXT.listAllProjects)}</option>`]
      .concat((projects || []).map(p => `<option value="${esc(p.id)}"${p.id === st.project ? ' selected' : ''}>${esc(p.name)}</option>`))
      .join('');
    const project = cfg.projectFilter === false ? ''
      : `<label class="vmf-ctl">${esc(TEXT.listProject)} <select id="${id}-project" data-list="project">${opts}</select></label>`;
    return sort + project +
      `<label class="vmf-ctl">${esc(TEXT.listSearch)} <input type="search" id="${id}-search" data-list="search" placeholder="${esc(cfg.searchHint || '')}" value="${esc(st.query)}"></label>`;
  }

  /* PAGE-SCALE-REPORTS-1: the tabs that choose a list, when a page gives
   * two or more. Each is a real tab: role="tab", aria-selected, the panel it
   * controls, and only the selected one in the keyboard order (the arrow keys
   * move between them, as the ARIA tabs pattern says). */
  function listTabsHtml(cfg, tabs, selected) {
    const id = esc(cfg.id);
    return (tabs || []).map(t => {
      const on = t.key === selected;
      return `<button type="button" role="tab" id="${id}-tab-${esc(t.key)}" data-tab="${esc(t.key)}" aria-selected="${on ? 'true' : 'false'}" aria-controls="${id}-panel" tabindex="${on ? '0' : '-1'}">${esc(t.label)}</button>`;
    }).join('');
  }

  function listMount(host, cfg) {
    const id = esc(cfg.id);
    const sorts = cfg.sorts || [];
    const firstSort = sorts.length ? String(sorts[0].key) : '';
    const st = { tile: null, project: '', query: '', page: 0, sort: firstSort, tab: null };
    let picked = false;
    // PAGE-SCALE-ASSESSMENTS-1: the project to start with, until the projects
    // hold it or a person chooses.
    let wantProject = cfg.project ? String(cfg.project) : '';
    let data = { tiles: [], projects: [], tabs: [] };
    let projectsKey = null;
    // PAGE-SCALE-REPORTS-1: whether the panel is a tab panel now, so a page
    // with no tabs never has its panel touched.
    let tabbed = false;
    // LOADING-LINE-1: the page's "Reading ..." sentence, and whether the page
    // still reads. A list given a sentence reads from the moment it mounts.
    const waiting = cfg.waiting ? String(cfg.waiting) : '';
    let reading = !!waiting;
    let failed = false;
    // PAGE-SCALE-REPORTS-1: a list with no tiles (the Safety copies box) hides
    // the group; the list is its one tile's rows.
    host.innerHTML = `<div class="kpis vmf-tiles" data-part="tiles" role="group" aria-label="${esc(TEXT.listTiles)}"${cfg.tiles === false ? ' hidden' : ''}></div>` +
      `<section class="card vmf-list" aria-labelledby="${id}-title"><div class="ch">` +
      `<div class="vmf-tabs" data-part="tabs" role="tablist" aria-label="${esc(cfg.tabsLabel || TEXT.listTabs)}" hidden></div>` +
      `<h2 id="${id}-title" data-part="title"></h2>` +
      `<div class="vmf-ctls" data-part="controls"></div></div>` +
      // PAGE-SCALE-REPORTS-1: lines the page writes above the table (lead()).
      `<div class="vmf-lead" data-part="lead"></div>` +
      `<div id="${id}-panel" data-part="panel"><p class="muted vmf-intro" data-part="intro" hidden></p>` +
      `<div class="vmf-scroll" data-part="table"></div><div class="vmf-pager" data-part="pager"></div></div></section>`;
    const part = (name) => host.querySelector(`[data-part="${name}"]`);
    // The tabs a page gives, when it gives two or more; one tab is no choice.
    const tabsNow = () => (data.tabs.length > 1 ? data.tabs : []);
    // The tab the tiles' rows show in: the first that has no list of its own.
    const tilesTab = () => { const t = tabsNow(); const own = t.find(x => !x.list) || t[0]; return own ? own.key : null; };

    function drawControls() {
      part('controls').innerHTML = listControlsHtml(cfg, data.projects, st);
    }
    function draw(focus) {
      const tabs = tabsNow();
      const tab = tabs.find(t => t.key === st.tab) || null;
      const own = tab && tab.list ? tab.list : null;
      const tile = data.tiles.find(t => t.key === st.tile) || data.tiles[0] || { rows: [] };
      // The rows of the selected tab's own list, else of the selected tile.
      const shown = own || tile;
      const view = listView(shown.rows, { project: st.project, query: st.query, page: st.page,
                                          sort: sorts.find(s => s.key === st.sort) || null });
      st.page = view.page;
      const filtered = !!(st.project || String(st.query).trim());
      // LOADING-LINE-1: nothing to show while the page still reads is "not
      // read yet", never "none" - more rows can still arrive.
      const waitNow = reading && !own && !view.total;
      // And nothing to show after a failed read is a failure, never "none".
      const failNow = failed && !own && !view.total;
      // No tile is pressed while a tab shows a list of its own.
      part('tiles').innerHTML = listTilesHtml(data.tiles, own ? null : st.tile, reading ? 'reading' : (failed ? 'failed' : ''));
      part('title').textContent = shown.title || shown.label || '';
      part('table').innerHTML = listTableHtml(shown.columns || cfg.columns, view,
        waitNow ? waiting : (failNow ? TEXT.listReadFailed : (filtered && (shown.rows || []).length ? TEXT.listNoMatch : shown.empty)));
      part('pager').innerHTML = waitNow || failNow ? '' : listPagerHtml(view, filtered);
      drawTabs(tabs, tab, own);
      // A button drawn again loses the focus: give it back to the one used.
      if (focus === 'tile') { part('tiles').querySelector(`[data-tile="${esc(st.tile)}"]`).focus(); }
      if (focus === 'tab') { part('tabs').querySelector(`[data-tab="${esc(st.tab)}"]`).focus(); }
      if (focus === 'next' || focus === 'prev') {
        const lastPage = view.page >= view.pages - 1, firstPage = view.page <= 0;
        const keep = focus === 'next' ? (lastPage ? 'prev' : 'next') : (firstPage ? 'next' : 'prev');
        part('pager').querySelector(`[data-page="${keep}"]`).focus();
      }
    }
    /* PAGE-SCALE-REPORTS-1: the tabs, the panel they name, and the intro of
     * the selected tab. With tabs, the tabs name the lists, so the title is
     * not shown twice (it still names the card for a screen reader). */
    function drawTabs(tabs, tab, own) {
      const intro = tab ? ((own && own.intro) || tab.intro || '') : '';
      const introPart = part('intro');
      introPart.innerHTML = esc(intro);
      introPart.hidden = !intro;
      const tabsPart = part('tabs');
      tabsPart.innerHTML = tab ? listTabsHtml(cfg, tabs, tab.key) : '';
      tabsPart.hidden = !tab;
      part('title').hidden = !!tab;
      if (tab) {
        const panel = part('panel');
        panel.setAttribute('role', 'tabpanel');
        panel.setAttribute('aria-labelledby', `${id}-tab-${esc(tab.key)}`);
        tabbed = true;
      } else if (tabbed) {
        const panel = part('panel');
        panel.removeAttribute('role');
        panel.removeAttribute('aria-labelledby');
        tabbed = false;
      }
    }
    function chooseTab(key) {
      st.tab = key; st.page = 0;
      draw('tab');
    }

    host.addEventListener('keydown', (e) => {
      const tab = e.target && e.target.closest ? e.target.closest('[data-tab]') : null;
      if (!tab) { return; }
      const keys = tabsNow().map(t => t.key);
      const at = keys.indexOf(tab.dataset.tab);
      if (at < 0) { return; }
      const to = { ArrowRight: (at + 1) % keys.length, ArrowLeft: (at - 1 + keys.length) % keys.length,
                   Home: 0, End: keys.length - 1 }[e.key];
      if (to === undefined) { return; }
      e.preventDefault();
      chooseTab(keys[to]);
    });
    host.addEventListener('click', (e) => {
      const tabBtn = e.target.closest('[data-tab]');
      if (tabBtn) { chooseTab(tabBtn.dataset.tab); return; }
      const tile = e.target.closest('[data-tile]');
      // PAGE-SCALE-REPORTS-1: a tile shows its rows in the tiles' tab.
      if (tile) { st.tile = tile.dataset.tile; picked = true; st.page = 0; if (tabsNow().length) { st.tab = tilesTab(); } draw('tile'); return; }
      const step = e.target.closest('[data-page]');
      if (step && !step.disabled) {
        const dir = step.dataset.page === 'next' ? 'next' : 'prev';
        st.page += dir === 'next' ? 1 : -1;
        draw(dir);
      }
    });
    host.addEventListener('input', (e) => {
      if (e.target.matches('[data-list="search"]')) { st.query = e.target.value; st.page = 0; draw(); }
    });
    host.addEventListener('change', (e) => {
      if (e.target.matches('[data-list="project"]')) { st.project = e.target.value; wantProject = ''; st.page = 0; draw(); }
      if (e.target.matches('[data-list="sort"]')) {
        // A sort the page did not give is the first one.
        st.sort = sorts.some(s => s.key === e.target.value) ? e.target.value : firstSort;
        st.page = 0; draw();
      }
    });

    // LOADING-LINE-1: a list given a sentence says it at once, before the
    // page's first update - an empty card says nothing about why it is empty.
    if (reading) { draw(); }

    return {
      update(next) {
        data = { tiles: (next && next.tiles) || [], projects: (next && next.projects) || [], tabs: (next && next.tabs) || [] };
        // LOADING-LINE-1: no `reading` is a finished read.
        reading = !!(waiting && next && next.reading === true);
        failed = !!(next && next.failed === true);
        if (!picked || !data.tiles.some(t => t.key === st.tile)) { st.tile = listDefaultTile(data.tiles, cfg.preferred); }
        // PAGE-SCALE-REPORTS-1: the tabs can arrive after the rows (a role is
        // read after them). A tab that is not there now is the tiles' tab.
        if (!tabsNow().some(t => t.key === st.tab)) { st.tab = tilesTab(); }
        if (st.project && !data.projects.some(p => p.id === st.project)) { st.project = ''; }
        if (wantProject && data.projects.some(p => p.id === wantProject)) { st.project = wantProject; wantProject = ''; projectsKey = null; }
        // The controls are drawn again only when the projects change, so a
        // person typing in the search box keeps it while the page reads.
        const key = JSON.stringify(data.projects.map(p => [p.id, p.name]));
        if (key !== projectsKey) { projectsKey = key; drawControls(); }
        // The page draws again as each project's runs land. A tile or pager
        // button that has the keyboard focus is drawn again too, so the focus
        // goes back to the same button, not to the top of the page.
        const active = typeof document !== 'undefined' ? document.activeElement : null;
        const had = active && active.dataset && host.contains(active)
          ? (active.dataset.tile ? { part: 'tiles', sel: `[data-tile="${esc(active.dataset.tile)}"]` }
            : active.dataset.page ? { part: 'pager', sel: `[data-page="${esc(active.dataset.page)}"]` }
            : active.dataset.tab ? { part: 'tabs', sel: `[data-tab="${esc(active.dataset.tab)}"]` } : null)
          : null;
        draw();
        if (had) {
          const again = part(had.part).querySelector(had.sel);
          if (again && !again.disabled) { again.focus(); }
        }
      },
      state() { return { tile: st.tile, project: st.project, query: st.query, page: st.page, sort: st.sort, tab: st.tab }; },
      // PAGE-SCALE-REPORTS-1: where the page writes its own lines, escaped by
      // the page, above the table (the Safety copies box's summary).
      lead() { return part('lead'); },
    };
  }

  /* PAGE-SCALE-REPORTS-1: a count in words, the one form for 1 and the other
   * for every other number: countWords(1, ['{n} machine due', '{n} machines
   * due']) is "1 machine due". extra fills more placeholders, and extra.by,
   * when given, is the number that chooses ("0 of 1 migration checked"). */
  function countWords(n, pair, extra) {
    const o = extra || {};
    const by = Number(o.by !== undefined ? o.by : n);
    let text = String((by === 1 ? pair[0] : pair[1]) ?? '').replace('{n}', () => String(n));
    for (const k of Object.keys(o)) { if (k !== 'by') { text = text.replace(`{${k}}`, () => String(o[k])); } }
    return text;
  }

  /* A run's readable name: its project and the day it was made, in the
   * viewer's own date format. */
  function runTitle(project, kind, createdIso) {
    const at = createdIso ? Date.parse(createdIso) : NaN;
    const assessment = kind === 'assessment';
    if (!isFinite(at)) {
      return (assessment ? TEXT.runTitleAssessmentNoDate : TEXT.runTitleMigrationNoDate).replace('{project}', () => String(project ?? ''));
    }
    const date = new Date(at).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
    return (assessment ? TEXT.runTitleAssessment : TEXT.runTitleMigration).replace('{project}', () => String(project ?? '')).replace('{date}', () => date);
  }

  /* How long ago a change was, in words, with 1 in the singular. */
  function agoText(iso, nowMs) {
    if (!iso) { return ''; }
    const mins = Math.floor((nowMs - Date.parse(iso)) / 60000);
    if (!isFinite(mins)) { return ''; }
    if (mins < 1) { return TEXT.agoNow; }
    if (mins < 60) { return countWords(mins, TEXT.agoMinutes); }
    const h = Math.floor(mins / 60);
    if (h < 24) { return countWords(h, TEXT.agoHours); }
    return countWords(Math.floor(h / 24), TEXT.agoDays);
  }

  /* PROJECT-3: is this store folder a run, or something that merely sits
   * beside the runs?
   *
   * `vmf-claims` is the claim registry. `logs` is an event log, and the
   * product writes it itself - an event recorded against a path that holds no
   * run leaves one beside the runs rather than inside one. MEASURED on a live
   * install, 2026-09-16: the retention pass took a PROJECT for a run before
   * PROJECT-2 and left such a folder behind. PROJECT-2 fixed the walk and left
   * the folder, which then counted as a fourth run in a project that holds
   * three, and which the overview asked for a run record on every load.
   *
   * The service has the twin of this in Test-VmfFacadeRunFolder, because the
   * service walks the store for the timers and this walks it for the pages.
   * tests/fixtures/not-a-run-folders.json is the one list of cases they are
   * both held to. The folder NAME is matched whole: `logs-of-war` is a run.
   */
  function runFolderIsRun(path) {
    const leaf = String(path ?? '').split('/').pop();
    return leaf !== 'vmf-claims' && leaf !== 'logs' && leaf !== 'vmf-records';
  }

  /* RETAIN-KIND-1: what a run's manifest (run.json) says the run is -
   * 'migration', 'assessment', or null when there is no manifest or it names
   * no kind. The manifest writer (Initialize-VmfRun) writes the kind on every
   * manifest, so a manifest with none is not known, never a guess
   * (OLD-VERSION-READERS-REMOVE-6). The engine has the twin of this in
   * Get-VmfRunKind, which the daily check asks; tests/fixtures/run-kinds.json
   * is the one list of cases both are held to. A kind nobody knows is given
   * back as written.
   */
  function runKind(manifest) {
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) return null;
    const k = manifest.kind;
    return (k === undefined || k === null || k === '') ? null : String(k);
  }
  async function listRunsAcrossProjects(blobList) {
    const top = (await blobList('', '/')).prefixes;
    const out = [];
    // STORE-READ-2: one listing per top-level prefix, paced. This runs on
    // page load for three pages, so an unbounded fan-out here was paid by
    // every viewer before anything was drawn.
    await mapLimited(top, async (p) => {
      // PROJECT-3: the claim registry and an event log are not runs, at the
      // top or beside a project's runs.
      if (!runFolderIsRun(p)) return;
      const inside = await blobList(`${p}/`, '/');
      const isProject = inside.names.some(n => n === `${p}/project.json`);
      if (!isProject) { out.push(p); return; }
      for (const child of inside.prefixes) { if (runFolderIsRun(child)) out.push(child); }
    });
    return out.sort();
  }
  window.VmfListRuns = listRunsAcrossProjects;

  const NAV = [
    // HOME-1: the front door. It used to be the migrations page, so the name
    // of the whole tool opened one of its five areas and a first-time visitor
    // landed in the middle of the thing.
    { id: 'home',    href: 'index.html',      label: 'Overview' },
    { id: 'projects', href: 'projects.html',   label: 'Projects' },
    { id: 'assess',  href: 'assessments.html', label: 'Assessments' },
    { id: 'runs',    href: 'migrations.html',       label: 'Migrations' },
    { id: 'reports', href: 'reports.html',     label: 'Reports' },
    { id: 'access',  href: 'access.html',      label: 'Admin' },
  ];

  /* SIGNIN-1: builds the sign-in card and shows it. ONE card, on all of them.
   *
   * The same argument the navigation above is built on: eight copies of a
   * control is eight controls. These eight had already drifted apart in the
   * words, in the markup and in the button.
   *
   * It BUILDS the button rather than finding one, so a page cannot show the
   * card without it - and it is built before this returns, so the caller's
   * addEventListener on the line after finds it.
   *
   * The navigation goes while the card is up. Every tab leads to this same
   * card, so a signed-out person could only walk in a circle.
   */
  function showSignIn() {
    const host = document.querySelector('#login-view');
    if (!host) { return null; }
    const nav = document.querySelector('nav.topnav');
    if (nav) { nav.innerHTML = ''; }
    host.innerHTML =
      '<span class="signin-mark" aria-hidden="true"></span>' +
      `<h2>${esc(TEXT.signInTitle)}</h2>` +
      `<p class="signin-what">${esc(TEXT.signInWhat)}</p>` +
      `<button id="login-btn" class="btn signin-btn" type="button">${esc(TEXT.signInBtn)}</button>`;
    host.style.display = 'block';
    return host.querySelector('#login-btn');
  }

  /* ---------- DISCLAIMER-1: the app says it is not a Microsoft product ----------
   *
   * The repository can say it, but a person who only uses the installed app
   * never reads the repository. So the app says it in two sizes:
   *
   *   - the SHORT LINE, at the foot of every page, always. Drawn here, when
   *     this file loads, for the reason the navigation is: eight copies of a
   *     line is eight lines, and a page cannot forget one it never wrote. It
   *     is outside <main>, so the role gate, which hides main's children,
   *     never hides it. It links to the manual page with the full notice.
   *   - the FULL NOTICE, once, at the first sign-in in this browser. Nothing is
   *     recorded for the service: a flag in this browser says it was seen.
   *     Storage can THROW, not only come back empty (theme.js says the same),
   *     so a refusal costs the memory of it, never the page - and a notice
   *     that cannot be remembered is shown once on each page, never dropped.
   *
   * There is no switch to hide either one. */
  const DISCLAIMER_KEY = 'vmf-disclaimer-seen';
  // NO-POPUPS-1: a page of the manual, opened in this tab like the rest of it.
  const DISCLAIMER_HASH = '#/understand/disclaimer';
  // One page load shows the notice once, also when storage is refused: the
  // role gate and the page both call identity().
  const disclaimerState = { shown: false };

  function installDisclaimerLine() {
    // By id, not by selector: the line is the page's, and there is one.
    if (document.getElementById('vmf-disclaimer')) { return null; }
    const foot = document.createElement('footer');
    foot.id = 'vmf-disclaimer';
    foot.className = 'vmf-foot';
    foot.innerHTML = `<span>${esc(TEXT.disclaimerLine)}</span> ` +
      `<a href="${esc(manualHref(DISCLAIMER_HASH))}">${esc(TEXT.disclaimerRead)}</a>`;
    const main = document.querySelector('main');
    if (main && main.insertAdjacentElement) { main.insertAdjacentElement('afterend', foot); }
    else { document.body.appendChild(foot); }
    return foot;
  }

  function disclaimerSeen() {
    try { return window.localStorage.getItem(DISCLAIMER_KEY) === '1'; } catch (e) { return false; }
  }

  function rememberDisclaimer() {
    try { window.localStorage.setItem(DISCLAIMER_KEY, '1'); } catch (e) { /* storage refused */ }
  }

  // The full notice, in the help dialog every page already has: Escape and a
  // click beside it close it, and OK is the visible way out (rule 11).
  function showDisclaimer() {
    const body = [TEXT.disclaimerP1, TEXT.disclaimerP2, TEXT.disclaimerP3]
      .map(p => `<p style="margin:0 0 10px">${esc(p)}</p>`).join('');
    return dialog(body, [{ label: TEXT.disclaimerOk, primary: true, onClick: (d) => d.remove() }], TEXT.disclaimerTitle);
  }

  // Asked by identity(), which each page calls once it knows who is signed
  // in. A user only: the sample data names a viewer, and nobody signed in is
  // nobody to tell. Remembered when it opens, so however it is closed - OK,
  // Escape, a click beside it, or leaving the page - it does not open again.
  function disclaimerOnSignIn(account, demoLabel) {
    if (!account || demoLabel || disclaimerState.shown || disclaimerSeen()) { return null; }
    disclaimerState.shown = true;
    rememberDisclaimer();
    return showDisclaimer();
  }

  /* LOGO-SERVERS-1: the header mark, drawn inline so its parts can move.
   *
   * A CSS mask paints a drawing as one still shape, so it cannot move the
   * moving unit or draw the arrow head. These are the drawing elements of
   * mark.svg, which stays the source: the sign-in card and the manual banner
   * use that file as a still mask, and Brand.Tests.ps1 holds this copy equal
   * to it. app.css runs the motion once when the page opens, and not at all
   * for a person who asks the browser for reduced motion.
   *
   * Drawn here, once, for the reason the navigation is: eight copies of a
   * drawing is eight drawings, and every page already has the empty span. */
  const MARK_DRAWING =
    '<g class="vmf-mark-wait" opacity=".55">' +
    '<path fill-rule="evenodd" d="M4.1 4.4H16.1A1.5 1.5 0 0 1 17.6 5.9V9.5A1.5 1.5 0 0 1 16.1 11H4.1A1.5 1.5 0 0 1 2.6 9.5V5.9A1.5 1.5 0 0 1 4.1 4.4ZM4.9 6H5.5A0.5 0.5 0 0 1 6 6.5V8.9A0.5 0.5 0 0 1 5.5 9.4H4.9A0.5 0.5 0 0 1 4.4 8.9V6.5A0.5 0.5 0 0 1 4.9 6ZM7.5 6H8.1A0.5 0.5 0 0 1 8.6 6.5V8.9A0.5 0.5 0 0 1 8.1 9.4H7.5A0.5 0.5 0 0 1 7 8.9V6.5A0.5 0.5 0 0 1 7.5 6ZM10.1 6H10.7A0.5 0.5 0 0 1 11.2 6.5V8.9A0.5 0.5 0 0 1 10.7 9.4H10.1A0.5 0.5 0 0 1 9.6 8.9V6.5A0.5 0.5 0 0 1 10.1 6ZM13.75 7.7A1.25 1.25 0 1 0 16.25 7.7A1.25 1.25 0 1 0 13.75 7.7Z"/>' +
    '<path fill-rule="evenodd" d="M4.1 21H16.1A1.5 1.5 0 0 1 17.6 22.5V26.1A1.5 1.5 0 0 1 16.1 27.6H4.1A1.5 1.5 0 0 1 2.6 26.1V22.5A1.5 1.5 0 0 1 4.1 21ZM4.9 22.6H5.5A0.5 0.5 0 0 1 6 23.1V25.5A0.5 0.5 0 0 1 5.5 26H4.9A0.5 0.5 0 0 1 4.4 25.5V23.1A0.5 0.5 0 0 1 4.9 22.6ZM7.5 22.6H8.1A0.5 0.5 0 0 1 8.6 23.1V25.5A0.5 0.5 0 0 1 8.1 26H7.5A0.5 0.5 0 0 1 7 25.5V23.1A0.5 0.5 0 0 1 7.5 22.6ZM10.1 22.6H10.7A0.5 0.5 0 0 1 11.2 23.1V25.5A0.5 0.5 0 0 1 10.7 26H10.1A0.5 0.5 0 0 1 9.6 25.5V23.1A0.5 0.5 0 0 1 10.1 22.6ZM13.75 24.3A1.25 1.25 0 1 0 16.25 24.3A1.25 1.25 0 1 0 13.75 24.3Z"/>' +
    '</g>' +
    '<path class="vmf-mark-move" fill-rule="evenodd" d="M7.9 12.7H19.9A1.5 1.5 0 0 1 21.4 14.2V17.8A1.5 1.5 0 0 1 19.9 19.3H7.9A1.5 1.5 0 0 1 6.4 17.8V14.2A1.5 1.5 0 0 1 7.9 12.7ZM8.7 14.3H9.3A0.5 0.5 0 0 1 9.8 14.8V17.2A0.5 0.5 0 0 1 9.3 17.7H8.7A0.5 0.5 0 0 1 8.2 17.2V14.8A0.5 0.5 0 0 1 8.7 14.3ZM11.3 14.3H11.9A0.5 0.5 0 0 1 12.4 14.8V17.2A0.5 0.5 0 0 1 11.9 17.7H11.3A0.5 0.5 0 0 1 10.8 17.2V14.8A0.5 0.5 0 0 1 11.3 14.3ZM13.9 14.3H14.5A0.5 0.5 0 0 1 15 14.8V17.2A0.5 0.5 0 0 1 14.5 17.7H13.9A0.5 0.5 0 0 1 13.4 17.2V14.8A0.5 0.5 0 0 1 13.9 14.3ZM17.55 16A1.25 1.25 0 1 0 20.05 16A1.25 1.25 0 1 0 17.55 16Z"/>' +
    '<path class="vmf-mark-head" d="M23.6 11.2 L28.4 16 L23.6 20.8" pathLength="100" fill="none" stroke="currentColor" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/>';

  function installMark() {
    document.querySelectorAll('.brand .logo').forEach((span) => {
      if (span.querySelector('svg')) { return; }
      // HTML gives an inline svg its namespace, so it needs no xmlns.
      span.innerHTML = '<svg viewBox="0 0 32 32" fill="currentColor" focusable="false" aria-hidden="true">' +
        MARK_DRAWING + '</svg>';
    });
  }
  function installNav() {
    const nav = document.querySelector('nav.topnav');
    if (!nav) return;
    // The active tab is DERIVED from the address, not declared per page - a
    // page that names its own active tab is a page that can name the wrong one.
    const here = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    const links = NAV.map(n => {
      const active = n.href.toLowerCase() === here ? ' class="active"' : '';
      return `<a href="${n.href}" id="nav-${n.id}"${active}>${n.label}</a>`;
    }).join('');
    nav.innerHTML = links + `<a id="nav-help" href="#" role="button">${TEXT.nav}</a>`;
    installRight();
  }

  /* THEME-1 and SIGNOUT-1 - the two controls that belong to the PERSON rather
   * than to a page, so they live at the right-hand end of the bar next to who
   * they are signed in as.
   *
   * Drawn here, once, for the same reason the tabs are: eight copies of a
   * control is eight controls, and three pages had already forgotten to call
   * VmfHelp.install(). */
  function installRight() {
    const bar = document.querySelector('.topbar');
    if (!bar) { return; }

    // BUILT, NOT FOUND. The theme control and Sign out vanished on the Admin
    // page, and the signed-in name moved to the wrong side of the bar.
    //
    // Because this used to look for `.topbar .right` and RETURN QUIETLY when a
    // page did not have one - and access.html did not. So the admin page had
    // no theme button, no sign-out, and its name sat wherever the nav left it
    // instead of at the far right. The bar was shared right up to the point
    // where it depended on eight pages having written the same markup.
    //
    // A shared control cannot ask the page for somewhere to live.
    let right = bar.querySelector('.right');
    if (!right) {
      right = document.createElement('span');
      right.className = 'right';
      bar.appendChild(right);
    }
    if (right.querySelector('#nav-theme')) { return; }

    // NAV-1: the navigation bar on Migrations sat out of line with every
    // other page once a migration was running and the row filled up.
    //
    // The bar is one wrapping row. A page that puts its own controls in the
    // right-hand group - Migrations: the run chip, the refresh state, its
    // actions - fills the row past its width, and the overflow drops to a
    // second row that starts under the tabs. So the second row is now
    // DELIBERATE and shared: the bar keeps the brand, the tabs and who you
    // are; whatever a page wrote into the group before this ran moves to a
    // toolbar row under the bar. A page with no controls of its own gets no
    // row. Done here, once, for the reason the group itself is built here.
    const own = Array.from(right.children).filter(el => el.id !== 'who');
    if (own.length) {
      let toolbar = document.querySelector('.toolbar');
      if (!toolbar) {
        toolbar = document.createElement('div');
        toolbar.className = 'toolbar';
        bar.insertAdjacentElement('afterend', toolbar);
      }
      for (const el of own) { toolbar.appendChild(el); }
    }

    // #who is ours too, appended LAST so the order is the same on every page:
    // any page's own controls, then theme, then sign out, then who you are.
    let who = right.querySelector('#who');
    if (!who) {
      who = document.createElement('span');
      who.id = 'who';
      who.className = 'who';
    }
    right.appendChild(who);

    // THEME-2: the control must show the CURRENT theme, and let you change to
    // another one.
    //
    // A select does that by definition - the closed control IS the current
    // setting - where the button it replaces named the DESTINATION and so
    // could never show where you were. It also has room for the state the app
    // starts in, following the operating system, which a two-state button had
    // no way back to once pressed.
    const theme = document.createElement('select');
    theme.id = 'nav-theme';
    theme.className = 'navsel';
    theme.setAttribute('aria-label', TEXT.themeLabel);
    const labels = (window.VmfTheme && window.VmfTheme.LABEL) ||
                   { light: 'Light', dark: 'Dark', system: 'Follow the system' };
    for (const v of ['light', 'dark', 'system']) {
      const o = document.createElement('option');
      o.value = v; o.textContent = labels[v];
      theme.appendChild(o);
    }
    theme.addEventListener('change', () => { if (window.VmfTheme) { window.VmfTheme.set(theme.value); } });

    // SIGNOUT-1: there was no way to sign out, which anyone testing the roles
    // with a second account needs, and anyone signed in wrongly needs more.
    const out = document.createElement('button');
    out.id = 'nav-signout';
    out.type = 'button';
    out.className = 'navbtn';
    out.textContent = TEXT.signOut;
    out.title = TEXT.signOutTip;
    out.hidden = true;                       // until somebody is signed in
    out.addEventListener('click', signOut);

    // VERSION-1: the build, first in the row. A control rather than a label,
    // because it opens the About dialog with the service and engine builds.
    // Hidden until the stamp has been read: no stamp, no claim.
    const stamp = document.createElement('button');
    stamp.id = 'nav-build';
    stamp.type = 'button';
    stamp.className = 'navbtn';
    stamp.title = TEXT.versionTip;
    stamp.hidden = true;
    stamp.addEventListener('click', versionDialog);

    right.insertBefore(stamp, who);
    right.insertBefore(theme, who);
    right.insertBefore(out, who);
    if (window.VmfTheme) { window.VmfTheme.paintButton(); }
    stampBuild();
  }

  /* ONE SENTENCE FOR A FAILURE THE READER CAN DO SOMETHING ABOUT.
   *
   * A viewer with an app role but no Azure RBAC met an immediate 403, and what
   * the page showed was `list : HTTP 403` - engine text, on the first screen a
   * new person ever sees, saying nothing about what was refused or what to ask
   * for.
   *
   * The right words already existed, on ONE page: the migrations first-run
   * panel has explained this exact failure since it was written. Every other
   * page printed e.message. So this is not new wording, it is the wording
   * moved somewhere every page can reach - the same fault, and the same fix,
   * as the navigation bar and the signed-in identity before it.
   *
   * A store 403 is the common one and it is NOT a bug: the dashboard reads
   * blob storage with the viewer's OWN token, so an app role alone does not
   * grant it. Those are two separate permissions and people are given one
   * without the other all the time.
   */
  /* TWO DIFFERENT 403s, AND TELLING SOMEBODY THE WRONG ONE IS WORSE THAN
   * TELLING THEM NOTHING.
   *
   * The first version of this mapped ANY 403 to the storage message. But a
   * ROLE refusal from the facade is also a 403, so the moment somebody with a
   * Viewer role tried to act they would be told they needed Storage Blob Data
   * Reader - a permission they already had, on a thing that was not the
   * problem. Caught before anyone hit it, on a step that was about to run.
   *
   * The facade's own refusal is already the best sentence available: it names
   * the roles that WOULD work and the roles the person actually holds. So it
   * is rewritten into plain words rather than replaced.
   */
  const ROLE_WORDS = {
    'Vmf.Viewer': 'Viewer', 'Vmf.Approver': 'Approver',
    'Vmf.Operator': 'Operator', 'Vmf.Admin': 'Administrator',
  };
  const asWords = (csv) => String(csv || '')
    .split(',').map(r => r.trim()).filter(Boolean)
    .map(r => ROLE_WORDS[r] || r)
    .join(' or ');

  const FAILURES = [
    /* CONSENT-UX-1: THE DIRECTORY REFUSED, and it is not about a role.
     *
     * The Admin page asks Microsoft Entra for permission to read the directory
     * and to give and remove roles. Entra reserves those for a directory
     * administrator: no user can approve them for themselves, in any tenant.
     * A person who cannot get that approval saw the bare word `access_denied`
     * in a red bar and nothing else.
     *
     * TWO THINGS MATTER IN THE ANSWER. The first is that this is one page, not
     * the product: everything else works on the approval a person can give
     * themselves, and somebody who reads `access_denied` on the Admin page has
     * no way of knowing that. The second is that they cannot fix it alone, so
     * the sentence has to send them to somebody who can.
     *
     * IT DOES NOT CLAIM WHICH CAUSE. `access_denied` is also what comes back
     * when a person closes the sign-in without finishing, so the wording holds
     * for both and the last line covers the second.
     *
     * Placed first: these carry no status code, so nothing below would match
     * them, and the general answer would be the raw error.
     */
    /* Asked once, refused, and asked again. The one-ask guard stops a refused
       redirect bouncing the page for ever; this is how a person learns that,
       instead of pressing a button that does nothing. */
    { when: /vmf_asked_already/i,
      say: 'Your directory was already asked once in this session, and it said no. ' +
           'Sign out and sign in again to try once more.' },
    { when: /access_denied|consent_required|AADSTS65001|AADSTS90094/i,
      say: 'The Admin page needs a directory administrator to approve it once. ' +
           'No user can approve this permission for themselves. ' +
           'Every other page works without it. ' +
           'If you closed the sign-in before it finished, try again.' },
    /* A sign-in address this page is not registered at. Every page returns to
     * itself, so each one must be a registered address. An install made before
     * all of them were registered gives this on the pages that were missing,
     * and the Azure message names a URL rather than saying what to do. */
    { when: /AADSTS50011|redirect_uri|reply url/i,
      say: 'Microsoft Entra ID does not accept this page as a sign-in address for the product. ' +
           'Install the product again, then sign in here.' },
    // A ROLE refusal. Most specific of the status-code rules, so it is first.
    { when: /403:\s*requires one of \[([^\]]*)\][\s\S]*?holds \[([^\]]*)\]/i,
      say: (m) => {
        const need = asWords(m[1]);
        const has = asWords(m[2]);
        return has
          ? `Your role does not allow this. It needs ${need}, and you have ${has}.`
          : `Your role does not allow this. It needs ${need}, and you have no role in this app yet.`;
      } },
    // A STORE refusal. Azure RBAC on the storage account, not an app role -
    // the dashboard reads blob directly with the viewer's own token.
    //
    // readOnly: THIS RULE IS NEVER APPLIED TO SOMETHING SOMEBODY DID.
    // No action may report a storage permission, whatever the role. It must
    // say which APP ROLE is required, not name some underlying Azure thing.
    //
    // That is not a wording preference - it is a correctness
    // rule. Reading the records can fail on Azure RBAC. An ACTION goes through
    // the facade, which refuses on APP ROLE and never touches the viewer's
    // storage permission, so naming storage there is always false and sends
    // somebody to fix a permission that is not the problem.
    // STORE-READ-1: this used to send a reader to the subscription
    // administrator for Storage Blob Data Reader, because reading the records
    // needed a SECOND permission in Azure. It does not any more - the service
    // reads them with its own identity - so a refusal here means the role in
    // the product, which the Admin page gives.
    /* SIGN-IN-MSG-1: THREE DIFFERENT FAILURES USED TO SHARE ONE SENTENCE.
     *
     * The service's front door refuses a call before any of this product's
     * code runs, and App Service answers with its own words. Read as a role
     * refusal, that sent an administrator holding Vmf.Admin looking for a role
     * he already had, for hours.
     *
     * The three are told apart by what came back, most specific first:
     *   the front door's own text   -> the service refused the call outright
     *   401                          -> a sign-in, not a role
     *   403                          -> a role
     *
     * The order below is the fix. The comment under the 401 rule said "401
     * FIRST" and the rule sat second, under one matching `HTTP 40[13]` - which
     * matches 401 as well - so for a READ it never ran at all.
     *
     * HELP-JS-RULE12-1: this sent the person to a tool script, which breaks
     * hard rule 12, and the app has no page that checks an install. It names
     * the cause measured on a live service instead (EASYAUTH-403-1): the
     * sign-in settings on the service, which the platform template states and
     * an install writes again - the same answer as the sign-in address rule.
     */
    { when: /do not have permission to view this directory or page/i,
      say: 'The service refused this call before the product read it. This is not about your role. ' +
           'Install the product again to set the sign-in settings on the service, then reload this page.' },
    // PLAN-WRITE-RACE-1: a conflict - somebody changed the plan first. The
    // engine's own sentence says what to do; only the code comes off it.
    // RETRY-GATE-1: both anchored rules sit ABOVE the unanchored 401 and 404
    // rules. A refusal names a machine, a wave and a date, and a machine
    // called web401 read as "Your sign-in was not accepted" (found by the
    // review of RETRY-GATE-1).
    { actionOnly: true, when: /^409:\s*([\s\S]+)$/,
      say: (m) => m[1] },
    // RETRY-GATE-1: an action the engine refused, with its reason - a retry
    // in a wave that cannot start names the missing step. The sentence is the
    // answer; the code in front of it is not for a person.
    { actionOnly: true, when: /^400:\s*([\s\S]+)$/,
      say: (m) => m[1] },
    { when: /401/,
      say: 'Your sign-in was not accepted. Sign out and sign in again.' },
    { readOnly: true,
      when: /HTTP 403|AuthorizationPermissionMismatch/i,
      say: 'You are signed in, but you have not been given a role in the product. ' +
           'A user with the Administrator role can give you one on the Admin page.' },
    // Any other refusal of an action. Reached only when the facade did not
    // give its usual role-shaped answer, so it says the true general thing
    // rather than guessing at a specific one.
    { actionOnly: true, when: /403|forbidden/i,
      say: 'Your role does not allow this. Ask a user with the Administrator role for the role that covers it, on the Admin page.' },
    /* RUNID-2: this said "the dashboard may be pointed at the wrong storage
     * account", which is the most alarming answer and almost never the true
     * one. MEASURED 2026-09-15: the record was exactly where it belonged and
     * the page asked for it one path segment short, because the link it came
     * from had dropped the project. A person read that sentence and went to
     * look at their storage account. */
    { when: /404|NotFound/i,
      say: 'That record is not there. If it belongs to a project, open it from the Assessments page or the Migrations page. Those pages name the project in the link.' },
    { when: /Failed to fetch|NetworkError|ERR_/i,
      say: 'The migration records could not be reached. Check the network, then reload this page.' },
  ];

  /* forAction: true when the person PRESSED something, false when the page was
   * reading. The only difference is which rules may apply - a read may blame
   * Azure RBAC, an action may not, and an action has a general answer of its
   * own for a refusal the facade did not explain. */
  function explainWith(err, forAction) {
    const raw = String((err && (err.message ?? err.error_description)) ?? err ?? '');
    for (const f of FAILURES) {
      if (f.readOnly && forAction) { continue; }
      if (f.actionOnly && !forAction) { continue; }
      const m = raw.match(f.when);
      if (m) { return typeof f.say === 'function' ? f.say(m) : f.say; }
    }
    return raw;
  }

  function explain(err) { return explainWith(err, false); }
  function explainAction(err) { return explainWith(err, true); }

  /* WATCH-1: WAIT FOR THE RUN TO ANSWER, ON THREE PAGES THAT ASK DIFFERENT
   * QUESTIONS.
   *
   * Three copies of a function called watchForRefusal existed. Only two were
   * the same function - migrations and the wizard both watch the event log for
   * an engine failure - and the third, on waves, watches a CAPACITY CLAIM and
   * only reads events as a faster way to hear bad news. A name that describes
   * one of the three is its own hazard, so that one is now watchReservation.
   *
   * What is genuinely shared is the LOOP, and the loop is where the subtle
   * rules live:
   *
   *   - A READ FAILURE KEEPS WATCHING. The run store is the same place the
   *     answer comes from, so one bad read proves nothing. Treat it as a
   *     verdict and a slow blob write becomes "it failed".
   *   - events BEFORE the moment we started are somebody else's news.
   *   - a deadline, so a page that is never answered says so rather than
   *     spinning for ever.
   *   - the poll interval, which the demo shortens so the staged sequence is
   *     watchable.
   *
   * What is NOT shared is which events matter and what to do about them, so
   * `scan` receives the events for this tick - already parsed and already
   * trimmed to the window - and returns a verdict or null. Every page keeps
   * its own precedence, which genuinely differs: waves prefers "nothing to
   * reserve" over a failure, the wizard prefers a failure over "it started".
   *
   * `onTick` runs before the read for a page whose real answer is somewhere
   * else - waves polls the claim - and short-circuits when it has one.
   */
  async function watchRun(opts) {
    const readLines = opts.readLines;
    const scan = opts.scan;
    const sinceMs = opts.sinceMs ?? 0;
    const pollMs = opts.pollMs ?? 6000;
    const deadline = Date.now() + (opts.timeoutMs ?? 180000);

    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, pollMs));

      // PAGE-WAIT-1: the log is read BESIDE onTick, not after it. onTick's
      // answer still wins; the log read is only used when it has none.
      // Through a promise, so a reader that throws at once is still caught below.
      const linesRead = Promise.resolve().then(() => readLines());
      linesRead.catch(() => { });   // read below; one bad read is not an answer
      if (opts.onTick) {
        const early = await opts.onTick();
        if (early) { return early; }
      }

      try {
        const all = await linesRead;
        const fresh = sinceMs
          ? all.filter(e => !(Date.parse(e.tsUtc) < sinceMs))
          : all;
        const verdict = scan(fresh);
        if (verdict) { return verdict; }
      } catch (e) {
        // Deliberate. See the note above: one bad read is not an answer.
      }
    }
    return null;
  }

  /* ROLE-GATE-1: DOES THIS PERSON HAVE ANY ROLE IN THIS APP AT ALL?
   *
   * Somebody with NO role could sign in and still see things.
   *
   * Revocation itself worked - the app role and the
   * storage read were both gone. What did not stop was ARRIVING. Five of the
   * eight pages never looked at app roles: signing in needs no role, and
   * whether anything appeared depended entirely on Azure RBAC, a different
   * system. So a person with no role got the full navigation, the page
   * furniture, and whatever the storage account still let them read.
   *
   * That is the same fault as the Admin page granting half of what "access"
   * means: two permission systems, and the app driving only one of them.
   *
   * THE ROLES ARE IN THE API TOKEN, not the storage one - reading blob needs a
   * storage-scoped token that carries no app roles at all, which is why five
   * pages could not have checked even if they had tried.
   *
   * `checked` matters as much as `roles`. A deployment with no facade has no
   * app roles to hold, and gating on an unanswerable question would lock
   * everybody out of a dashboard that is working as configured. Unknown is not
   * "no role", the same rule the engine follows everywhere else.
   */
  async function myRoles(cfg, getToken, msalApp) {
    if (!cfg || !cfg.apiAppId) { return { checked: false, roles: [] }; }
    try {
      // SILENT when the page hands over its MSAL app. Every page's getToken
      // falls back to a POPUP, and a person with no role would get an Entra
      // error window thrown at them before the panel that explains it. Asking
      // whether somebody has a role must not be an interaction.
      const scopes = [`api://${cfg.apiAppId}/access_as_user`];
      const acct = msalApp && msalApp.getAllAccounts && msalApp.getAllAccounts()[0];
      const t = (msalApp && acct)
        ? (await msalApp.acquireTokenSilent({ scopes, account: acct })).accessToken
        : await getToken(scopes);
      const claims = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      return { checked: true, roles: claims.roles ?? [] };
    } catch (e) {
      // "UNKNOWN IS NOT NO" IS RIGHT, AND I APPLIED IT TOO WIDELY.
      //
      // The API app has appRoleAssignmentRequired = true, so Entra refuses to
      // issue this token AT ALL to somebody with no role - AADSTS50105. That
      // refusal is not "cannot tell": it is Entra answering the question
      // definitively, in the only way it can. Treating it as unknown let a
      // person with no role straight through, which is exactly the hole this
      // gate was added to close.
      //
      // The storage message appeared where the no-access panel should have
      // been, so the gate was failing open and the old text showed through.
      // EVERY field, joined - not the first truthy one. MSAL sets errorCode
      // to 'interaction_required' and puts AADSTS50105 in errorMessage, so
      // `errorCode || errorMessage` reads the generic word and never sees the
      // code that carries the answer. Found in the browser, driving the real
      // gate: the version before this failed open on exactly the error it was
      // written to catch.
      const why = [e && e.errorCode, e && e.errorMessage, e && e.message,
                   e && e.subError, String(e || '')].filter(Boolean).join(' ');
      if (/AADSTS50105|not assigned to a role|invalid_grant.*assign/i.test(why)) {
        return { checked: true, roles: [] };
      }
      // Anything else - offline, popup blocked, no facade - genuinely cannot
      // be answered, and locking somebody out on a question we could not ask
      // is the other way to get this wrong.
      return { checked: false, roles: [] };
    }
  }

  /* Show the "no access" panel and return false when they hold nothing.
   *
   * Built rather than found, like the rest of the bar: five of these pages had
   * no gate markup, and asking each one to add some is how five pages end up
   * with four different gates and one that was forgotten. */
  async function gateOnRole(cfg, getToken, msalApp) {
    // SIGNOUT-1: before anything can return early. The gate's own Sign out
    // button needs this on the pages that gate before they install().
    if (msalApp) { gateMsal = msalApp; }
    const { checked, roles } = await myRoles(cfg, getToken, msalApp);
    // VERSION-1: somebody with a role may ask the service its version. NOT
    // awaited - the facade cold-starts in 20-40 s and the page must not wait.
    if (checked && roles.length) { loadServiceVersion(cfg, msalApp); }
    if (!checked || roles.length) { return true; }

    const main = document.querySelector('main') || document.body;
    // BOTH, and the inline style is the one that matters.
    //
    // `hidden` alone did not hide: the browser's [hidden] rule is display:none
    // at the lowest precedence, and these pages set `#app`'s display inline,
    // which beats it. app.css carries an !important rule now, but a BLOCK MUST
    // NOT DEPEND ON A STYLESHEET HAVING LOADED - a gate that fails open when a
    // CSS file is slow or cached is not a gate. Measured: the panel appeared
    // and the whole dashboard stayed on screen behind it.
    for (const el of main.children) { el.hidden = true; el.style.display = 'none'; }
    const gate = document.createElement('div');
    gate.id = 'norole-view';
    gate.className = 'card';
    gate.innerHTML = `<div class="cardbody" style="max-width:60ch">
      <h2 style="margin:0 0 10px">${esc(TEXT.noRoleTitle)}</h2>
      <p class="muted" style="margin:0">${esc(TEXT.noRoleBody)}</p></div>`;
    main.appendChild(gate);

    /* AND A WAY BACK OUT. Once the gate worked, the screen was a trap: there
     * was no way off it except closing the browser.
     *
     * Almost everybody who lands here is signed in as the WRONG
     * ACCOUNT - that is the whole reason to have a second identity - and the
     * one thing they need is to leave. Closing the browser is not a control.
     * CLAUDE.md rule 11: anything that opens must offer a way back.
     *
     * The sign-out button already existed and was HIDDEN: it is revealed by
     * identity(), which every page calls AFTER this gate returns. So the one
     * screen that most needs it was the only screen that never got it.
     */
    installRight();
    const acct = msalApp && msalApp.getAllAccounts && msalApp.getAllAccounts()[0];
    identity(acct);

    // Saying WHO they are matters more here than anywhere else in the app: it
    // is the fact that tells somebody they are on the wrong account, and it is
    // the question they are actually asking when they get turned away.
    const nameOf = acct && (acct.username || acct.name);
    if (nameOf) {
      const asWho = document.createElement('p');
      asWho.className = 'muted';
      asWho.style.margin = '10px 0 0';
      asWho.textContent = TEXT.noRoleWho.replace('{who}', nameOf);
      gate.querySelector('.cardbody').appendChild(asWho);
    }

    // In the panel as well as the bar. A control somebody has to go hunting
    // for on the screen that exists to tell them they are stuck is no better
    // than no control.
    const leave = document.createElement('button');
    leave.type = 'button';
    leave.className = 'btn';
    leave.style.marginTop = '14px';
    leave.textContent = TEXT.signOut;
    leave.addEventListener('click', signOut);
    gate.querySelector('.cardbody').appendChild(leave);

    return false;
  }

  /* ---------- VERSION-1: which build is this ----------
   *
   * A customer cannot update from a build nobody can name.
   * Nothing on any screen could say which build it was, and this menu had
   * promised "the page and version filled in" since HELP-2 while filling in no
   * version. An update needs something to update FROM, and a bug report needs
   * to say which build it is about.
   *
   * TWO FACTS, ARRIVING AT DIFFERENT TIMES. The dashboard's own stamp comes
   * with the page, in dashboard.config.json, written at deploy time from the
   * module's version. The service's answer to /version comes later - only once
   * somebody with a role is signed in, and only after the facade has woken up,
   * which takes 20-40 s from cold (COLD-1). So the service is asked OFF the
   * critical path, and the bar shows what it knows when it knows it.
   *
   * describeVersions is PURE - strings injected, no DOM - so every combination
   * of known / not yet / failed is run in tests/js/version-stamp.test.js. */
  function describeVersions(build, service, T = TEXT) {
    const out = { bar: null, rows: [], verdict: null };
    if (!build || !build.version) { return out; }        // no stamp, no claim
    // A row shows the NUMBER; the build goes in the note, named as a build.
    // `full` is the whole semver string, for the bug report and the bundle.
    const numberOf = (v) => String(v).split('+')[0];
    out.bar = T.versionBar.replace('{v}', numberOf(build.version));
    const built = (b) => (b && b.commit
      ? T.versionBuilt
          .replace('{build}', String(b.commit).slice(0, 7))
          .replace('{when}', b.builtUtc
            ? new Date(b.builtUtc).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '?')
      : T.versionLocal);
    out.rows.push({ label: T.versionDashboard, value: numberOf(build.version), full: String(build.version), note: built(build) });
    if (!service) {
      out.rows.push({ label: T.versionService, value: null, full: null, note: T.versionServiceSignIn });
      return out;
    }
    if (service.pending) {
      out.rows.push({ label: T.versionService, value: null, full: null, note: T.versionServicePending });
      return out;
    }
    if (service.error || !service.service || !service.service.version) {
      out.rows.push({ label: T.versionService, value: null, full: null, note: T.versionServiceUnknown });
      return out;
    }
    const svc = service.service;
    out.rows.push({ label: T.versionService, value: numberOf(svc.version), full: String(svc.version), note: built(svc) });
    const eng = service.engine || {};
    const engValue = eng.digest ? String(eng.digest).replace(/^sha256:/, '').slice(0, 12) : (eng.tag || null);
    out.rows.push({
      label: T.versionEngine, value: engValue, full: engValue,
      note: eng.note || (eng.digest ? T.versionEngineDigest : T.versionEngineUnknown),
    });
    out.verdict = String(svc.version) === String(build.version) ? T.versionSame : T.versionDiffer;
    return out;
  }

  function paintBuild() {
    const stamp = document.querySelector('#nav-build');
    if (!stamp) { return; }
    const bar = describeVersions(build, service, TEXT).bar;
    stamp.textContent = bar || '';
    stamp.hidden = !bar;
    // An answer that lands while the dialog is open is shown, not lost:
    // his first screenshot was a dialog opened during the cold start.
    if (aboutBox && document.body.contains(aboutBox)) {
      const body = aboutBox.querySelector('#vmf-help-body');
      if (body) { body.innerHTML = versionBodyHtml(); }
    }
  }

  // The page's own stamp. Read here rather than handed over by the page: the
  // bar is drawn before any page has loaded its configuration, and eight pages
  // passing the same value is eight chances to pass nothing.
  async function stampBuild() {
    try {
      const r = await fetch('dashboard.config.json', { cache: 'no-cache' });
      if (!r.ok) { return; }
      const cfg = await r.json();
      if (!cfg || !cfg.version) { return; }
      build = { version: String(cfg.version), commit: cfg.commit || null, builtUtc: cfg.builtUtc || null };
    } catch (e) { return; }
    paintBuild();
  }

  /* CONFIG-HOST-1: THE ADDRESS THE DASHBOARD WAS TOLD TO TRUST.
   *
   * cfg.apiUrl decides where an Entra access token goes. It is read from a
   * file that sits beside the pages, and until this was written the shipped
   * sample of that file pre-filled it with an example address on a host
   * NOBODY OWNED - a name anyone could register, while every other value in
   * the sample was an obvious row of zeroes. It was the one field that looked
   * already done, and the file's own note said to rename it and deploy.
   *
   * The sample now carries an empty address, which is the real fix. This is
   * the second half: a token must never leave over a connection that is not
   * encrypted. It cannot check that the address is the RIGHT one - the facade
   * belongs to the customer and only they know its name - so it checks the
   * one thing that is true everywhere.
   *
   * A refused address is EMPTIED rather than repaired. Every page already
   * treats a missing address as "no service is deployed" and draws no action
   * controls, so the app falls back to read-only instead of handing a token to
   * whoever answers. The reason travels to the one place that already reports
   * why there is no service.
   */
  let configRefusal = null;

  /** True if an access token may ride on this address. */
  function tokenMayGoTo(apiUrl) {
    let url;
    // Parsed with NO base on purpose. Judged against the page's own address
    // instead, every piece of rubbish becomes a same-origin path and passes -
    // an empty string resolves to the page itself, and the word "null"
    // resolves to a page called null. The facade is always named in full.
    try { url = new URL(String(apiUrl)); } catch (e) { return false; }
    if (url.protocol === 'https:') { return true; }
    // http is allowed exactly where the browser itself counts the page as
    // secure: a service on the operator's own machine.
    return url.protocol === 'http:' &&
      (url.hostname === 'localhost' || url.hostname === '127.0.0.1' || url.hostname === '[::1]');
  }

  /** The page's configuration, with an address no token may use taken out. */
  function checkedConfig(cfg) {
    configRefusal = null;
    if (!cfg || !cfg.apiUrl) { return cfg; }
    if (tokenMayGoTo(cfg.apiUrl)) { return cfg; }
    configRefusal = 'the configured service address is not https, so no token was sent to it';
    return Object.assign({}, cfg, { apiUrl: '' });
  }

  // The service's answer, with the API token and SILENTLY - a version read must
  // never throw an Entra window at anybody. Never awaited by a page.
  async function loadServiceVersion(cfg, msalApp) {
    if (!cfg || !cfg.apiUrl || !cfg.apiAppId) {
      service = { error: configRefusal || 'no service configured' };
      return;
    }
    service = { pending: true };
    paintBuild();
    try {
      const scopes = [`api://${cfg.apiAppId}/access_as_user`];
      const acct = msalApp && msalApp.getAllAccounts && msalApp.getAllAccounts()[0];
      if (!acct) { service = { error: 'not signed in' }; return; }
      const t = (await msalApp.acquireTokenSilent({ scopes, account: acct })).accessToken;
      const r = await fetch(`${cfg.apiUrl}/version`, { headers: { Authorization: `Bearer ${t}` } });
      service = r.ok ? await r.json() : { error: `HTTP ${r.status}` };
    } catch (e) {
      service = { error: e && e.message ? e.message : String(e) };
    }
    paintBuild();
  }

  // One line for a bug report: "dashboard 0.1.0+1fee594; service 0.1.0+1fee594".
  function versionSummary() {
    const parts = describeVersions(build, service, TEXT).rows
      .filter(r => r.value).map(r => `${r.label.toLowerCase()} ${r.full || r.value}`);
    return parts.length ? parts.join('; ') : 'unknown';
  }

  function versionBodyHtml() {
    const d = describeVersions(build, service, TEXT);
    const rows = d.rows.map(r =>
      `<tr><th style="text-align:left;vertical-align:top;padding:6px 14px 6px 0;white-space:nowrap">${esc(r.label)}</th>` +
      `<td style="padding:6px 0"><code>${esc(r.value || '-')}</code><br><span style="color:var(--muted)">${esc(r.note || '')}</span></td></tr>`).join('');
    return `<table style="border-collapse:collapse;margin:0 0 6px">${rows}</table>` +
      (d.verdict ? `<p style="margin:8px 0 0">${esc(d.verdict)}</p>` : '') +
      `<p style="margin:8px 0 0;color:var(--muted)">${esc(TEXT.versionWhatBuild)}</p>`;
  }

  function versionDialog() {
    aboutBox = dialog(versionBodyHtml(), [{ label: TEXT.close, onClick: (back) => back.remove() }], TEXT.versionTitle);
  }

  /* ---------- CLICKS-LOST-1: a press gets a sign, and a redraw waits for the person ----------
   *
   * Lab install, 2026-11-04 and 2026-11-05. Save the plan took about a minute
   * with only its own text changed, so it looked as if nothing happened and
   * was pressed twice. And a page that drew again on its timer replaced the
   * button under the pointer: a press on the old button let go over the new
   * one is no click, so Show what the scan found did nothing while the
   * Migrations page loaded.
   *
   * markBusy: AT ONCE, before any request, the button is disabled, says what
   * it does, and carries aria-busy, which app.css draws as a turning circle.
   * It returns the way back, for a press that fails. */
  function markBusy(btn, text) {
    if (!btn) { return () => {}; }
    const was = btn.textContent;
    btn.disabled = true;
    btn.textContent = text;
    if (typeof btn.setAttribute === 'function') { btn.setAttribute('aria-busy', 'true'); }
    return () => {
      btn.disabled = false;
      btn.textContent = was;
      if (typeof btn.removeAttribute === 'function') { btn.removeAttribute('aria-busy'); }
    };
  }
  /* A control a person types in. Focus there holds a redraw; focus on a button
   * or a check box does not - those keep focus after a click, and holding for
   * them would stop a page drawing until the person clicked somewhere else. */
  function isTypingControl(node) {
    if (!node) { return false; }
    if (node.isContentEditable) { return true; }
    const tag = String(node.tagName ?? '').toUpperCase();
    if (tag === 'TEXTAREA') { return true; }
    if (tag !== 'INPUT') { return false; }
    return !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color']
      .includes(String(node.type || 'text').toLowerCase());
  }
  /* A control a press lands on: the node, or one it sits inside, up to the region. */
  function isPointerControl(node, region) {
    for (let n = node; n && n !== region; n = n.parentElement) {
      const tag = String(n.tagName ?? '').toUpperCase();
      if (['BUTTON', 'SELECT', 'INPUT', 'TEXTAREA', 'LABEL', 'SUMMARY'].includes(tag)) { return true; }
      if (tag === 'A' && typeof n.hasAttribute === 'function' && n.hasAttribute('href')) { return true; }
      if (typeof n.getAttribute === 'function' && n.getAttribute('role') === 'button') { return true; }
    }
    return false;
  }
  /* HOW LONG A HOLD LASTS. A hold counts only while the person is ACTIVE: the
   * pointer moved or pressed, or a key went into a field, in the last 10
   * seconds. A still pointer is not a person about to press. After a Start or
   * a Stop the page's own drawing puts a new button under the pointer where it
   * rests, and with no bound every region of the Migrations page stopped
   * drawing until the mouse moved - while the live dot kept ticking. And on a
   * touch screen :hover stays on the last element tapped. 10 seconds is
   * longer than any press (pointer down to up, under a second) and than
   * moving onto a button after reading it, and shorter than the Migrations
   * page refresh (15 seconds): a still pointer costs at most one tick. */
  const HOLD_MS = 10000;
  const lastSeen = { pointer: 0, typing: 0 };
  if (typeof document !== 'undefined' && document && typeof document.addEventListener === 'function') {
    const seen = (kind) => () => { lastSeen[kind] = Date.now(); };
    for (const t of ['pointermove', 'pointerdown']) { document.addEventListener(t, seen('pointer'), { capture: true, passive: true }); }
    for (const t of ['keydown', 'input']) { document.addEventListener(t, seen('typing'), { capture: true, passive: true }); }
  }
  function recentlyActive(kind) { return (Date.now() - lastSeen[kind]) < HOLD_MS; }
  /* Does the person hold a control in this region now - the pointer on one,
   * or focus in a field they type in - and are they active (HOLD_MS)? */
  function controlHeld(region) {
    if (!region || typeof region.contains !== 'function') { return false; }
    const active = region.ownerDocument ? region.ownerDocument.activeElement : null;
    if (active && region.contains(active) && isTypingControl(active) && recentlyActive('typing')) { return true; }
    if (typeof region.querySelectorAll !== 'function' || !recentlyActive('pointer')) { return false; }
    const hovered = region.querySelectorAll(':hover');
    const inner = hovered && hovered.length ? hovered[hovered.length - 1] : null;
    return Boolean(inner && isPointerControl(inner, region));
  }
  /* drawWhenFree: a draw that a timer or a watch asks for (never a person's
   * own press) runs at once, unless the person holds a control in one of the
   * regions it replaces. Then it waits, and the LATEST draw asked for runs
   * once the pointer leaves the control, focus leaves the field, or the
   * person has been still for HOLD_MS. Nothing is lost: the page's data is
   * already new, only the drawing waits. Returns true when it drew now. */
  const heldDraws = new WeakMap();
  function drawWhenFree(regions, draw) {
    const list = [].concat(regions ?? []).filter(Boolean);
    if (!list.some(controlHeld)) {
      for (const r of list) { heldDraws.delete(r); }
      draw();
      return true;
    }
    // A draw already waits here: its listeners take this one instead.
    const had = list.map(r => heldDraws.get(r)).find(Boolean);
    if (had) {
      had.draw = draw;
      for (const r of list) { heldDraws.set(r, had); }
      return false;
    }
    const entry = { draw };
    for (const r of list) { heldDraws.set(r, entry); }
    let timer = null;
    const listen = (on) => {
      for (const r of list) {
        const fn = on ? r.addEventListener : r.removeEventListener;
        if (typeof fn === 'function') { fn.call(r, 'pointerout', retry); fn.call(r, 'focusout', retry); }
      }
      if (!on && timer) { clearTimeout(timer); timer = null; }
    };
    // Draws when nothing is held; true when the wait is over either way.
    function check() {
      // A draw that ran at once since then took this one's place.
      if (!list.some(r => heldDraws.get(r) === entry)) { listen(false); return true; }
      if (list.some(controlHeld)) { return false; }
      listen(false);
      for (const r of list) { if (heldDraws.get(r) === entry) { heldDraws.delete(r); } }
      entry.draw();
      return true;
    }
    // After the event, so the browser has moved the pointer and the focus.
    function retry() { setTimeout(check, 0); }
    // And with no event at all: a still person stops holding after HOLD_MS.
    const tick = () => { timer = null; if (!check()) { timer = setTimeout(tick, Math.max(50, HOLD_MS / 10)); } };
    listen(true);
    timer = setTimeout(tick, Math.max(50, HOLD_MS / 10));
    return false;
  }
  /* ---------- POPUP-1: a question asked IN the page, never a browser box ----------
   *
   * A browser popup is not required to ask a question, and the confirmation
   * reads better in the page than in a box the browser drew.
   *
   * Nine places asked with the browser's own confirm or prompt box: a box the
   * theme cannot reach, that cannot hold a field, and that reads as an alarm.
   * Rule 11 already named the right shape - one control with two states - and
   * this is that control, shared. The button becomes a short row: the question,
   * an optional description or list, an optional field, Yes and Cancel. Escape
   * cancels. On Yes the ORIGINAL button is put back before the caller's work
   * runs, so every caller's "Deleting..." status keeps working unchanged.
   *
   * opts: ask (the question), desc (one sentence under it), lines (a list),
   *       field { placeholder, required, missing }, yes, cancel,
   *       under (a selector for an element around the button: the question
   *       goes in the page flow right after it - a row of its own after a
   *       table row, a block after anything else).
   * onYes(value): value is the field's text, trimmed, or null without a field. */
  function confirmInPlace(btn, opts, onYes) {
    if (!btn || !btn.parentNode) { return; }
    const host = btn.parentNode;
    const hadPosition = host.style.position;
    const hadVisibility = btn.style.visibility;
    const row = document.createElement('span');
    row.className = 'askrow';
    row.setAttribute('role', 'group');
    row.setAttribute('aria-label', String(opts.ask || '').split('\n')[0]);

    // A question written for the browser box may carry its explanation as
    // further paragraphs (the reservation note does). The FIRST line is the
    // question; the rest is description, shown under it with its breaks kept.
    let askText = String(opts.ask || '');
    let descText = opts.desc ? String(opts.desc) : '';
    const cut = askText.indexOf('\n');
    if (cut > 0) {
      descText = [askText.slice(cut).trim(), descText].filter(Boolean).join('\n\n');
      askText = askText.slice(0, cut).trim();
    }
    const ask = document.createElement('span');
    ask.className = 'ask';
    ask.textContent = askText;
    row.appendChild(ask);
    if (descText) {
      const d = document.createElement('span');
      d.className = 'muted';
      d.textContent = descText;
      row.appendChild(d);
    }
    if (opts.lines && opts.lines.length) {
      const ul = document.createElement('ul');
      for (const l of opts.lines) {
        const li = document.createElement('li');
        li.textContent = l;
        ul.appendChild(li);
      }
      row.appendChild(ul);
    }
    let field = null;
    if (opts.field) {
      field = document.createElement('input');
      field.type = 'text';
      field.placeholder = opts.field.placeholder || '';
      field.setAttribute('aria-label', opts.ask);
      row.appendChild(field);
    }
    const missing = document.createElement('span');
    missing.className = 'muted';
    missing.hidden = true;
    row.appendChild(missing);

    const yes = document.createElement('button');
    yes.type = 'button';
    yes.className = 'btn small';
    yes.textContent = opts.yes;
    const no = document.createElement('button');
    no.type = 'button';
    no.className = 'btn small ghost';
    no.textContent = opts.cancel;
    row.appendChild(yes);
    row.appendChild(no);

    /* ROLE-REMOVE-CONFIRM-1: a button inside something narrow - a role chip
     * on the Admin page - anchored the row to a container one word wide, and
     * the question became a tall column floating over the next row. With
     * `under`, the question gets a table row of its own directly under that
     * row, one cell across every column, in the page's flow. The same was
     * true of every caller - each row floated over what was below its
     * button - so `under` names, by selector, the element the question
     * follows: a table row gets a row of its own, anything else a block. */
    const anchor = typeof opts.under === 'string' && btn.closest ? btn.closest(opts.under) : null;
    const under = anchor && anchor.parentNode ? anchor : null;
    let line = null;
    if (under && String(under.tagName).toUpperCase() === 'TR') {
      row.className = 'askrow inrow';
      line = document.createElement('tr');
      line.className = 'askline';
      const cell = document.createElement('td');
      cell.colSpan = (under.cells && under.cells.length) || 1;
      cell.appendChild(row);
      line.appendChild(cell);
    } else if (under) {
      row.className = 'askrow inrow askblock';
      line = row;
    }
    // The way back (rule 11): Cancel, Escape, and the button returns with
    // focus on it, exactly as it was.
    const putBack = () => {
      document.removeEventListener('keydown', onKey);
      if (line && line.parentNode) { line.parentNode.removeChild(line); }
      if (row.parentNode) { row.parentNode.removeChild(row); }
      // ASKROW-1: the button stayed where it was, hidden, so the cell kept its
      // width while the confirmation was open. Give it back.
      btn.style.visibility = hadVisibility;
      host.style.position = hadPosition;
    };
    const cancel = () => { putBack(); btn.focus(); };
    function onKey(e) { if (e.key === 'Escape') { e.preventDefault(); cancel(); } }
    no.addEventListener('click', cancel);
    yes.addEventListener('click', () => {
      const value = field ? field.value.trim() : null;
      if (field && opts.field.required && !value) {
        // An empty answer is refused HERE, beside the field, not after the
        // row has gone.
        missing.textContent = opts.field.missing || '';
        missing.hidden = false;
        field.focus();
        return;
      }
      putBack();
      onYes(value);
    });
    if (field) {
      field.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); yes.click(); } });
    }
    document.addEventListener('keydown', onKey);
    /* ASKROW-1: the row used to REPLACE the button, so it grew rightwards from
     * wherever the button sat - out of the card, which clips. It is anchored to
     * the button's own container now, and the button stays in place, hidden, so
     * the cell does not collapse while the question is on screen. */
    btn.style.visibility = 'hidden';
    if (line) {
      under.parentNode.insertBefore(line, under.nextSibling);
    } else {
      host.style.position = 'relative';
      host.insertBefore(row, btn);
    }
    (field || yes).focus();
  }

  /* The sentence beside the number of machines at once, or null. PURE -
   * strings injected - so it is run in tests/js/wave-estimate.test.js.
   * MANUAL-REVIEW-1: no wave time in words. What stays:
   * on a wave with fewer machines than the number, changing the number
   * appears to do nothing, because the engine never runs more workers than
   * there are machines. Say so, or the field looks dead. One machine is said
   * in the singular (LAB-UX-1). */
  function waveEstimate(machines, workers, T) {
    const m = Math.max(0, Math.floor(Number(machines) || 0));
    const w = Math.max(1, Math.floor(Number(workers) || 1));
    if (!m || w <= m) { return null; }
    return (m === 1 ? T.estAllAtOnceOne : T.estAllAtOnce).replace('{machines}', String(m));
  }

  /* MACHINES-AT-ONCE-RANGE-1: how many machines at once a wave runs, by the
   * engine's rule (Get-VmfWaveThrottle): the first machine with a whole
   * number above 0, else the default of a new plan. PURE, so it is run in
   * tests/js/machines-at-once.test.js. */
  function waveAtOnce(entries, fallback = WAVE_DEFAULT_WORKERS) {
    for (const e of (entries ?? [])) {
      const v = e?.policy?.throttle;
      const n = (typeof v === 'number' || (typeof v === 'string' && /^\s*\d+\s*$/.test(v))) ? Number(v) : NaN;
      if (Number.isInteger(n) && n > 0) { return n; }
    }
    return fallback;
  }

  /* MACHINES-AT-ONCE-RANGE-1: what one number of machines at once means, as
   * the screens say it: the choice, its machines and its engine containers,
   * and a sentence. ATONCE-EARLIER-1: every writer writes one of the four
   * choices, so another number has no words and no choice - never a guess of
   * one. PURE: the words, the choices and the containers are parameters
   * with the page's own values as defaults. */
  function atOnceChoice(n, T = TEXT, tiers = WAVE_TIERS, perContainer = WAVE_PER_CONTAINER) {
    const num = Number(n);
    const tier = tiers.find(t => t.machines === num) ?? null;
    if (!tier) {
      return { tier: null, machines: num, label: '', meaning: '' };
    }
    const containers = Math.ceil(tier.machines / perContainer);
    const label = (containers === 1 ? T.atOnceLabelOne : T.atOnceLabelMany)
      .replace('{name}', T.atOnceName[tier.id]).replace('{n}', String(tier.machines)).replace('{c}', String(containers));
    return { tier: tier.id, machines: tier.machines, label, meaning: T.atOnceMeaning[tier.id] };
  }

  /* ACCEPT-FIRST-MACHINE-1: the settings of a wave, read by ONE rule.
   *
   * WAVE-LEVER-OVERRIDE-1 wrote it for the wave editor's card: the card was
   * drawn from the FIRST machine of the wave, and a decision for one machine
   * (for example Continue when files are found on its temporary disk) then
   * spread to the whole wave or was written over. The acceptance on the
   * Migrations page and the Run it step kept reading the first machine, so a
   * person could accept "Stop and ask" for a wave where one machine
   * continues, or the reverse. Now all three ask this one rule.
   *
   * The value of a wave is the value most machines WITHOUT a decision of
   * their own hold (the first machine wins a tie). A machine does not follow
   * the setting when a decision for it set the setting, or when it holds
   * another value. Three settings belong to the whole wave: the engine reads
   * one value for it, and every machine follows it. The service applies the
   * same rule (Get-VmfWaveSettingWrites); tests/fixtures/wave-own-settings.json
   * holds both sides to it. PURE, so the tests run it. */
  function waveSettingDefaults() {
    return {
      capacityGate: 'BestEffort',
      requireApproval: true,
      onDDataFound: 'stop',
      // WAVE-KERNEL-LINE-1: no kernel setting. The kernel choice belongs to
      // each machine (KERNEL-UX-1), so a wave has none to show.
      keepSnapshotDays: 7,
      // MACHINES-AT-ONCE-RANGE-1: Standard, as the planner writes it. A machine
      // with no number reads as this too, as the engine reads it.
      throttle: WAVE_DEFAULT_WORKERS,
    };
  }
  /** The settings the engine reads once for the whole wave: the capacity gate
   *  from its first machine, how many at once from the first machine with a
   *  number, and the sign-off from every machine (any one that requires it). */
  function waveWideSettings() { return ['capacityGate', 'requireApproval', 'throttle']; }
  /** One setting of one machine, read the way the engine reads it. */
  function leverValue(e, field) {
    // APPR-LEVER-1 / SIGNOFF-NULL-1: absent means REQUIRED - the one rule
    // every page and the engine use.
    if (field === 'requireApproval') { return approvalRequired(e); }
    const v = e?.policy?.[field] ?? waveSettingDefaults()[field];
    // DECIDE-ROLE-1: a choice is read as one of its own values. A value that
    // differs only in case is read as that value; anything else as the safe
    // default.
    const choices = { capacityGate: ['BestEffort', 'Reserved'], onDDataFound: ['stop', 'proceed'] }[field];
    if (choices && !choices.includes(v)) {
      const same = typeof v === 'string' ? choices.find(c => c.toLowerCase() === v.toLowerCase()) : undefined;
      return same ?? waveSettingDefaults()[field];
    }
    // A count reads as a number: 7 and "7" are one value, as in the engine.
    if (field === 'keepSnapshotDays' || field === 'throttle') { return /^\s*[+-]?\d+\s*$/.test(String(v)) ? Number(v) : String(v); }
    return v;
  }
  /** Did a decision for this one machine set this setting (plan entry `decisions`)? */
  function ownDecision(e, field) {
    return (e?.decisions ?? []).some(d => d && d.setting === field);
  }
  /** Does this machine not follow the setting when its wave shows `shown`? */
  function keepsOwn(e, field, shown, staying) {
    if (waveWideSettings().includes(field)) { return false; }
    return ownDecision(e, field) || (staying && shown !== undefined && String(leverValue(e, field)) !== String(shown));
  }
  /** A setting of the whole wave, read as the engine reads it for the wave. */
  function waveWideValue(members, field) {
    if (!members.length) { return waveSettingDefaults()[field]; }
    if (field === 'requireApproval') { return members.some(e => leverValue(e, field) === true); }
    // MACHINES-AT-ONCE-RANGE-1: the engine's own rule.
    if (field === 'throttle') { return waveAtOnce(members); }
    return leverValue(members[0], field);
  }
  /** The settings of a wave drawn from its machines: the values, and the
   *  machines (vmId) that do not follow each one. */
  function waveCard(members) {
    const values = {}, own = {};
    for (const field of Object.keys(waveSettingDefaults())) {
      if (waveWideSettings().includes(field)) { values[field] = waveWideValue(members, field); own[field] = []; continue; }
      const plain = members.filter(e => !ownDecision(e, field));
      const pool = plain.length ? plain : members;
      // Map keeps the order of insertion, so on a tie the first machine wins.
      const counts = new Map();
      for (const e of pool) { const k = JSON.stringify(leverValue(e, field)); counts.set(k, (counts.get(k) ?? 0) + 1); }
      let best = null, most = 0;
      for (const [k, n] of counts) { if (n > most) { best = k; most = n; } }
      values[field] = best === null ? waveSettingDefaults()[field] : JSON.parse(best);
      own[field] = members.filter(e => keepsOwn(e, field, values[field], true)).map(e => e.vmId);
    }
    return { values, own };
  }
  /** A machine's value of a setting, in the words of the setting's own control. */
  function ownValueText(field, v, T = TEXT) {
    if (field === 'onDDataFound') { return v === 'proceed' ? T.ownDataProceed : T.ownDataStop; }
    if (field === 'keepSnapshotDays') { return Number(v) === 1 ? T.ownDayOne : T.ownDays.replace('{n}', () => String(v)); }
    return String(v);
  }
  /** The newest decision for this one machine that set this setting, or null. */
  function ownDecisionOf(e, field) {
    const at = (d) => { const n = Date.parse(d?.utc); return isFinite(n) ? n : -Infinity; };
    return (e?.decisions ?? []).filter(d => d && d.setting === field).reduce((a, d) => (!a || at(d) >= at(a) ? d : a), null);
  }
  /** A day in the viewer's own date format, as a run title shows it (runTitle). */
  function dayText(iso) {
    const at = Date.parse(iso);
    return isFinite(at) ? new Date(at).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : '';
  }
  /** How many machines do not follow a setting, as one short line. */
  function ownCountText(n, T = TEXT) {
    return Number(n) === 1 ? T.ownOne : T.ownMany.replace('{n}', () => String(n));
  }
  /* WAVE-OWN-PICTURE-1: one machine that does not follow a setting - its
   * value, and the cause where the plan records one. A decision for the
   * machine names who accepted it and when; any other value is said with no
   * cause, because the plan records none. `nameOf` is the page's machine name. */
  function ownRowText(field, e, nameOf, T = TEXT) {
    const fill = (text, o) => Object.keys(o).reduce((s, k) => s.replace(`{${k}}`, () => String(o[k])), text);
    const name = nameOf(e.vmId);
    const decided = ownDecisionOf(e, field);
    const value = ownValueText(field, leverValue(e, field), T);
    const day = decided ? dayText(decided.utc) : '';
    if (decided && decided.by && day) { return fill(T.ownRowDecided, { name, value, by: decided.by, date: day }); }
    if (decided && decided.by) { return fill(T.ownRowDecidedNoDate, { name, value, by: decided.by }); }
    return fill(T.ownRowValue, { name, value });
  }

  /* ONE ANSWER TO "WHO AM I SIGNED IN AS".
   *
   * This was computed six different ways across eight pages - `account.username`
   * on two, `account?.name ?? account?.username` on four, a third spelling on
   * assessments - so the admin page showed a display name while the overview
   * showed the address. Same person, same session, two answers.
   *
   * THE ADDRESS WINS, and that is not a style choice. Two different Entra
   * users can carry the same first and last name, which is exactly the case
   * when somebody keeps a second account to test roles with. A display name
   * cannot tell them apart; a UPN always can. The display name goes in the
   * tooltip, where it costs nothing.
   */
  function identity(account, demoLabel) {
    // DISCLAIMER-1: the full notice, at the first sign-in in this browser.
    // First, so a page with no name to show still shows it.
    disclaimerOnSignIn(account, demoLabel);
    const who = document.querySelector('#who');
    if (!who) { return; }
    if (demoLabel) {
      who.textContent = demoLabel;
      who.title = '';
    } else {
      who.textContent = (account && (account.username || account.name)) || '';
      who.title = (account && account.name) || '';
    }
    const out = document.querySelector('#nav-signout');
    if (out) { out.hidden = !who.textContent.trim(); }
  }

  /* MSAL is built by the page, so the page hands it over through the adapter.
   * logoutRedirect clears BOTH the token cache and the Entra session - clearing
   * only our own storage would sign the person back in silently on the next
   * click, which is the opposite of what somebody testing two roles needs.
   *
   * NO-POPUPS-SIGNOUT-1: by REDIRECT, the way POPUP-3 took sign-in and every
   * token request. This was logoutPopup, the last window the product opened;
   * where the browser blocks windows it failed, and only the local cache was
   * cleared while the Entra session stayed open. The library "will clear local
   * cache of user tokens then redirect the window to the server signout page"
   * (lib/msal-browser/docs/logout.md, Microsoft's library repository). */
  async function signOut() {
    // SIGNOUT-1: the role gate's app is the fallback, because three pages gate
    // BEFORE they install the adapter - and that gate screen is the one place
    // a person most needs to sign out, since almost everybody who lands there
    // is signed in as the wrong account.
    const app = (adapter && adapter.getMsal && adapter.getMsal()) || gateMsal;
    try {
      if (app && app.getAllAccounts().length) {
        /* Back to THIS page, with no query. Left to itself the library
           returns to the whole current address, query and all, and Entra
           returns only to an address the app registration lists - each page,
           with no query (infra/identity.bicep), the same address sign-in
           comes back to. */
        await app.logoutRedirect({ account: app.getAllAccounts()[0],
                                   postLogoutRedirectUri: location.origin + location.pathname });
        /* The browser is leaving for Microsoft. The library's promise settles
           while it goes, and a reload here would stop the trip and keep the
           Entra session. So nothing more happens on this page. */
        return;
      }
    } catch (e) {
      // A refused sign-out must not leave them signed in with a dead button.
    }
    // SIGNOUT-1: if no sign-out actually happened - no MSAL app reachable, no
    // account, or a sign-out the library refused before it left - dropping the
    // token cache is the least this button may do. It was only ever reached
    // from the catch, so the ONE case where MSAL was missing entirely fell
    // through in silence: the button reloaded the page and the session, and
    // the Entra cookie behind it, survived for the next person at that browser.
    // Every page configures MSAL with cacheLocation sessionStorage, so this is
    // the token cache and not somebody's theme choice, which lives in
    // localStorage and is not a credential.
    try { sessionStorage.clear(); } catch (e2) { /* nothing else to try */ }
    location.reload();
  }

  // Runs as soon as this file loads. Every page includes it after the header,
  // so the bar exists; a page that somehow does not have one is left alone.
  installMark();
  installNav();
  installDisclaimerLine();

  /* RETAIN-UX-1: what the daily cleanup will do, computed on the page from
   * the same record the engine reads (state documents and plan entries), so
   * the card never says something the engine would not do. Mirrors
   * Get-VmfExpiredSafetyCopies: a machine's copies are due once it has been
   * MIGRATED for its wave's keepSnapshotDays (absent = the default of 7); a
   * machine that is not migrated keeps its copies, because they are the way
   * back; an unreadable retention keeps them and says so.
   *
   * It exists because nothing anywhere traced what the cleanup was about to
   * do, so a person could not tell what was pending or when. */
  const RETENTION_DEFAULT_DAYS = 7;
  function safetyCopyLedger(docs, entries, nowUtc) {
    const byId = new Map((entries || []).filter(e => e && e.vmId).map(e => [String(e.vmId), e]));
    const now = nowUtc ? new Date(nowUtc) : new Date();
    const rows = [];
    for (const doc of (docs || [])) {
      if (!doc || !doc.safety) { continue; }
      // SAFETY-RETRY-1: the earlier attempts' copies count too - retention
      // deletes them with the current ones.
      const earlier = Array.isArray(doc.safety.earlierCopies) ? doc.safety.earlierCopies : [];
      const all = [doc.safety, ...earlier];
      // SAFETY-ALL-1: every data disk's copies count too, on this attempt and
      // an earlier one - both hold the same records.
      const dataRecords = c => [...(Array.isArray(c && c.pristineDataCopies) ? c.pristineDataCopies : []),
                                ...(Array.isArray(c && c.dataCopies) ? c.dataCopies : [])].filter(d => d && d.snapshotId);
      const ids = all.flatMap(c => [c && c.pristineSnapshotId, c && c.snapshotId,
                                    ...dataRecords(c).map(d => d.snapshotId)]).filter(Boolean);
      if (!ids.length) { continue; }
      const entry = byId.get(String(doc.vmId));
      const wave = entry ? String(entry.wave || '') : String(doc.wave || '');
      const locked = all.flatMap(c => [c && c.pristineSnapshotId && c.pristineSnapshotLocked,
                      c && c.snapshotId && c.snapshotLocked,
                      ...dataRecords(c).map(d => d.locked === true)]).filter(Boolean).length;
      const row = { vmId: String(doc.vmId), wave, copies: ids.length, locked, keepDays: null,
                    migratedUtc: null, dueUtc: null, status: 'inUse' };
      if (doc.retention && doc.retention.deletedUtc) {
        row.status = 'deleted'; row.deletedUtc = doc.retention.deletedUtc; rows.push(row); continue;
      }
      /* RESTORE-END-JOB-1 and RESUME-GIVEUP-KEEP-1: the engine keeps the
       * copies while a restore of the machine runs or starts
       * again (restoreRuns), and while one stopped and did not finish, until
       * a restore of it finishes (restoreStopped) - the rule of
       * Test-VmfPutBackJobHolds. */
      const job = doc.putBackJob;
      if (job) {
        const ended = job.ended;
        /* FINISH-END-JOB-1: a finish keeps the same checkpoint, and says so
         * as a finish, never as a restore. */
        if (!ended) { row.status = job.kind === 'finish' ? 'finishRuns' : 'restoreRuns'; rows.push(row); continue; }
        if (ended.reason === 'gaveUp' || job.held) { row.status = 'restoreStopped'; rows.push(row); continue; }
      }
      const raw = entry && entry.policy ? entry.policy.keepSnapshotDays : undefined;
      const keepDays = (raw === undefined || raw === null || raw === '') ? RETENTION_DEFAULT_DAYS : Number(raw);
      row.keepDays = Number.isInteger(keepDays) && keepDays >= 0 ? keepDays : null;
      const hit = doc.state === 'MIGRATED'
        ? (doc.history || []).filter(h => h && h.state === 'MIGRATED').slice(-1)[0] : null;
      const migrated = hit && hit.tsUtc ? new Date(hit.tsUtc) : null;
      if (!migrated || Number.isNaN(migrated.getTime())) { rows.push(row); continue; }
      row.migratedUtc = migrated.toISOString();
      if (row.keepDays === null) { row.status = 'unreadable'; rows.push(row); continue; }
      const due = new Date(migrated.getTime() + row.keepDays * 86400000);
      row.dueUtc = due.toISOString();
      row.status = due <= now ? 'due' : 'waiting';
      rows.push(row);
    }
    return rows;
  }

  /* One line's worth of numbers for a card: how many copies wait, how many
   * are due for the next pass, how many belong to machines still mid-flight,
   * how many of the kept copies carry no lock, and the earliest due date. */
  function safetyCopySummary(rows) {
    const kept = (rows || []).filter(r => r.status !== 'deleted');
    const sum = (list) => list.reduce((n, r) => n + r.copies, 0);
    const dueDates = kept.filter(r => r.dueUtc).map(r => r.dueUtc).sort();
    return {
      machines: kept.length,
      copies: sum(kept),
      waiting: sum(kept.filter(r => r.status === 'waiting')),
      due: sum(kept.filter(r => r.status === 'due')),
      inUse: sum(kept.filter(r => r.status === 'inUse')),
      unreadable: sum(kept.filter(r => r.status === 'unreadable')),
      unlocked: kept.reduce((n, r) => n + (r.copies - r.locked), 0),
      deleted: sum((rows || []).filter(r => r.status === 'deleted')),
      earliestDueUtc: dueDates.length ? dueDates[0] : null,
    };
  }

  /* When the daily pass next runs: 03:30 UTC (the timer's schedule). */
  function nextRetentionPassUtc(nowUtc) {
    const now = nowUtc ? new Date(nowUtc) : new Date();
    const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 3, 30, 0));
    if (next <= now) { next.setUTCDate(next.getUTCDate() + 1); }
    return next.toISOString();
  }

  /* RETENTION-CARD-CYCLE-1: what the daily cleanup's record says, for the
   * Safety copies card on the Reports page and on each migration page.
   *
   * The day's cleanup is a CYCLE of hourly passes (PERF-RETENTION-TIMEOUT-1,
   * schemas/retention-status.schema.json, schema 2). resumeAtRunId names the
   * migration the next pass starts at, and is null once the cycle examined
   * every migration; nextPassUtc is the next pass with work to do. The card
   * read only the schema 1 fields, so an unfinished cycle read as a finished
   * day, and named 03:30 tomorrow for a pass less than an hour away.
   *
   * A schema 1 record has no cycle: it is a finished day, and its next pass is
   * the next 03:30 UTC (nextRetentionPassUtc), as the engine reads it
   * (Get-VmfRetentionPassAction). A next pass the record names that has gone
   * by - the host stopped the pass, or the page was open for a long time - is
   * replaced by the rule the record was written from
   * (Get-VmfRetentionNextPassUtc): half past the next hour while the cycle is
   * unfinished, else the next 03:30 UTC. Facts only; each page holds its own
   * words. */
  function retentionPassFacts(pass, nowUtc) {
    const now = nowUtc ? new Date(nowUtc) : new Date();
    if (!pass || !pass.lastPassUtc) {
      return { ran: false, unfinished: false, nextUtc: nextRetentionPassUtc(now.toISOString()) };
    }
    const cycles = Number(pass.schemaVersion) >= 2;
    const unfinished = cycles && typeof pass.resumeAtRunId === 'string' && pass.resumeAtRunId !== '';
    const stored = cycles && pass.nextPassUtc ? new Date(pass.nextPassUtc) : null;
    let nextUtc;
    if (stored && !isNaN(stored.getTime()) && stored > now) { nextUtc = stored.toISOString(); }
    else if (unfinished) {
      const next = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours(), 30, 0));
      if (next <= now) { next.setUTCHours(next.getUTCHours() + 1); }
      nextUtc = next.toISOString();
    }
    else { nextUtc = nextRetentionPassUtc(now.toISOString()); }
    return {
      ran: true,
      unfinished,
      startedUtc: (cycles && pass.cycleStartedUtc) || pass.lastPassUtc,
      examined: Number(pass.runsExamined) || 0,
      inStore: Number(pass.runsInStore) || 0,
      due: Number(pass.machinesDue) || 0,
      started: Array.isArray(pass.executionsStarted) ? pass.executionsStarted.length : 0,
      failures: Array.isArray(pass.failures) ? pass.failures.map(f => f && f.reason) : [],
      nextUtc,
    };
  }

  /* STORE-READ-1: every page reads the run store THROUGH THE FACADE.
   *
   * Each page used to call blob storage itself, with the signed-in person's own
   * token. That cannot survive a locked-down store: a browser is not in a
   * subscription, so no subscription rule in a network security perimeter can
   * ever name it, and a store with public network access disabled admits
   * nothing else.
   *
   * So the read happens in the facade, with its managed identity, from inside
   * Azure - and the shapes returned here are the ones the pages' own helpers
   * already produced, so nothing above them changed.
   *
   * One copy, not seven. All seven pages load this file.
   */

  /* The query string, built once. An EMPTY prefix is legitimate - it lists the
   * top of the container - so only null and undefined are dropped.
   *
   * The CALLER passes the WHOLE route, rather than the last part of it onto a
   * head this function owns. REACH-2 reads the repository for the route a page
   * calls, and a route assembled from two halves is one it cannot find - so a
   * split here would have made both store endpoints look like endpoints
   * nobody calls. Write the route the way its function.json spells it. */
  /* ---------- RUNID-2: a run has ONE identity, written three ways -----------
   *
   * A run inside a project lives at `project/run` in the store. That string is
   * its identity, and it CANNOT be spelled the same way everywhere:
   *
   *   the store      project/run       a path, so the slash belongs
   *   the API route  runs/{runId}      ONE segment, so the slash cannot fit
   *   a page link    ?run=..&project=  two parameters, or the page loses one
   *
   * MEASURED, twice on 2026-09-01 and again on 2026-09-15: a slash in a route
   * segment does not survive. Encoded, IIS rejects it; raw, it matches no
   * route. Both times the answer is a 404 that reads like a missing record,
   * and the page then decides the run was never created.
   *
   * The two fixes on 2026-09-01 were local - one endpoint, one page - and the
   * commit that made the second was titled "the same slash, the same fix". The
   * rule was understood and never written down, so every call site added after
   * it repeated the defect. This is the rule, written down once.
   *
   * These are plain functions so each one can be lifted and run by
   * tests/js/_harness.js. The VmfRun object below is how the pages say it.
   */
  function runParse(id) {
    const s = String(id ?? '');
    const cut = s.indexOf('/');
    if (cut <= 0) { return { project: null, run: s }; }
    return { project: s.slice(0, cut), run: s.slice(cut + 1) };
  }
  /* The identity, as the store spells it, and where its documents live. */
  function runStorePath(project, run) {
    const p = project ? String(project) : '';
    return p ? `${p}/${run}` : String(run ?? '');
  }
  /* What goes in `runs/{runId}` - the BARE run, encoded. A composite id handed
   * to this is split rather than refused, because the lists the service
   * returns carry composite ids and every page reads them. */
  function runRouteSegment(id) {
    return encodeURIComponent(runParse(id).run);
  }
  /* The project travels in the BODY, which is the shape the engine dispatch
   * and the assessment approval already use. */
  function runWithProject(body, id) {
    const project = runParse(id).project;
    return project ? { ...(body || {}), project } : (body || {});
  }
  /* RUN-LINK-1: the run a page's address names, as the store spells it, or
   * null. runLink writes `run=<run>&project=<project>`; a `run=` that already
   * holds the whole id is taken as it is. The reverse of runLink - every page
   * that reads `run=` reads it through this. */
  function runFromQuery(search) {
    const q = new URLSearchParams(search);
    const r = q.get('run');
    if (!r) { return null; }
    return r.includes('/') ? r : runStorePath(q.get('project'), r);
  }
  /* A link to a page about this run. The project cannot be forgotten, because
   * the caller never writes the query string. */
  function runLink(page, id, extra) {
    const parts = runParse(id);
    const q = [`run=${encodeURIComponent(parts.run)}`];
    if (parts.project) { q.push(`project=${encodeURIComponent(parts.project)}`); }
    for (const [k, v] of Object.entries(extra || {})) {
      if (v === undefined || v === null) { continue; }
      q.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
    }
    return `${page}?${q.join('&')}`;
  }
  const VmfRun = { parse: runParse, storePath: runStorePath, routeSegment: runRouteSegment,
                   withProject: runWithProject, link: runLink, fromQuery: runFromQuery };
  function storeUrl(apiUrl, route, params) {
    const pairs = Object.entries(params || {})
      .filter(([, v]) => v !== undefined && v !== null)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
    return `${apiUrl}/${route}${pairs.length ? '?' + pairs.join('&') : ''}`;
  }

  /* The facade's error body carries a sentence worth showing. Fall back to the
   * status only when it does not. */
  async function storeError(response, what) {
    let detail = '';
    try { detail = (await response.json()).error || ''; } catch { detail = ''; }
    return new Error(detail || `${what}: HTTP ${response.status}`);
  }

  /* STORE-READ-2: how many store reads may be in flight at once.
   *
   * Every page did `Promise.all(names.map(read))` over a folder listing. The
   * facade pages a listing up to 50 x 5,000, so that is one authenticated
   * request per machine in the run - thousands at once from one tab, each one
   * a Function invocation - and on migrations.html the whole fan-out repeats
   * every refreshSeconds. It is not a browser problem alone: the facade is
   * shared, so one operator's tab degrades it for everybody else.
   *
   * 8 is a working number, not a measured one: enough that a page with a
   * hundred documents still paints quickly, low enough that a fleet-scale run
   * cannot open a thousand sockets. The browser itself caps connections per
   * host around 6, so past that the requests only queue in the browser instead
   * - the queue moves into OUR code, where the cost is visible.
   *
   * NOTHING IS DROPPED. This paces the reads; it does not truncate them. A
   * page that showed 2,000 machines still shows 2,000 machines. Hiding part of
   * a fleet from the console that migrates it would be a worse defect than the
   * one being fixed.
   */
  const STORE_READ_LIMIT = 8;

  /** Run fn over items with at most `limit` in flight. Results keep input order. */
  async function mapLimited(items, fn, limit, onEach) {
    const list = Array.from(items ?? []);
    const out = new Array(list.length);
    const width = Math.max(1, Math.min(limit || STORE_READ_LIMIT, list.length));
    let next = 0;
    let done = 0;
    const worker = async () => {
      for (;;) {
        const i = next++;
        if (i >= list.length) { return; }
        out[i] = await fn(list[i], i);
        done++;
        /* WAIT-1: told after each one lands, with everything that has landed so
         * far, so a page can draw what it has instead of holding it all back
         * for the slowest. The array still has a hole where a slot has not
         * finished - a caller draws what is there, it does not count. A throw
         * here is the caller's own fault and must not lose the whole fan-out,
         * which is the read of every run in the store. */
        if (onEach) { try { onEach(out.filter(v => v !== undefined), done, list.length); } catch { /* drawing is not reading */ } }
      }
    };
    await Promise.all(Array.from({ length: width }, () => worker()));
    return out;
  }

  /* PERF-ONE-LIMIT-1: ONE LIMIT FOR A WHOLE PAGE, NOT ONE PER WALK.
   *
   * mapLimited limits ONE walk. The Overview and Projects pages walk the
   * projects and, inside each, walk its runs - each walk with its own 8, so
   * up to 8 x 8 = 64 reads were in flight. MEASURED (PERF-ANALYSIS-1): 275 of
   * 320 cold starts in 7 days began less than 5 s after another call - the
   * service adding instances during a page load - and a read sent to a new
   * instance waited 13.9 s (p50) for it to start.
   *
   * This gives back a function that runs ONE read with at most `limit` (by
   * default STORE_READ_LIMIT) in flight across everything that shares it. A
   * page makes one and sends every read through it.
   *
   * A SLOT IS HELD FOR ONE READ, NEVER ACROSS A WAIT FOR ANOTHER. That is why
   * nested walks cannot deadlock: an outer walk waiting for its inner walk
   * holds nothing. A pool that let a project keep a slot while its runs were
   * read would stop with every slot held by a project. So never pass work
   * that itself reads through the same limiter - pass the read.
   *
   * Nothing is dropped and nothing is reordered: a read waits its turn, first
   * come first served, and its answer or its error reaches its caller. */
  function readLimiter(limit) {
    const width = Math.max(1, limit || STORE_READ_LIMIT);
    let live = 0;
    const waiting = [];
    const release = () => {
      // The slot goes straight to the next read, so `live` does not change.
      const next = waiting.shift();
      if (next) { next(); } else { live--; }
    };
    return async function limited(read) {
      if (live < width) { live++; } else { await new Promise((go) => waiting.push(go)); }
      try { return await read(); } finally { release(); }
    };
  }

  /* EVENTLOG-1: A RUN LOG CAN BE IN MORE THAN ONE PART.
   *
   * An append blob holds 50,000 blocks and the engine writes one per event, so
   * a long run fills the first document and carries on in the next. The first
   * part keeps its name - logs/events.jsonl, which is what every run ever
   * written is called and what every reader already asks for - and the parts
   * after it are logs/events-2.jsonl, then -3, and so on.
   *
   * READING STOPS AT THE FIRST PART THAT IS NOT THERE. Parts are made in
   * order, and whatever makes one writes to it in the same breath, so a gap
   * means the end. A run that never filled a part pays one read that finds
   * nothing.
   *
   * POSITION IS NOT TIME. Several workers append at once (SCALE-2), so a line
   * in part 2 can be older than a line in part 3 - exactly as two lines inside
   * one part can already be out of order. Anything that cares WHEN something
   * happened reads the timestamp, never the position.
   *
   * The engine has the twin of nextLogPart in PowerShell, because it does the
   * naming and this does the reading. tests/fixtures/log-part-names.json is
   * the one list of cases they are both held to.
   */
  const LOG_PARTS_MAX = 200;

  /** logs/events.jsonl -> logs/events-2.jsonl -> logs/events-3.jsonl */
  function nextLogPart(path) {
    const s = String(path);
    const slash = s.lastIndexOf('/');
    const dot = s.lastIndexOf('.');
    // Only a dot in the NAME is an extension. A folder called 2026.09 must not
    // turn a log into a part of something else.
    const cut = dot > slash + 1 ? dot : s.length;
    const stem = s.slice(0, cut), ext = s.slice(cut);
    const m = stem.match(/^(.*)-(\d+)$/);
    return m ? `${m[1]}-${Number(m[2]) + 1}${ext}` : `${stem}-2${ext}`;
  }

  /** Every part of a line document, first part first, as trimmed text lines. */
  async function readLogParts(readPartText, basePath) {
    const lines = [];
    let part = basePath;
    for (let i = 0; i < LOG_PARTS_MAX; i++) {
      let text = null;
      // A read that fails is not proof the part is absent, but it is all this
      // can know. The pages that poll this treat one empty answer as nothing
      // to report and ask again on the next tick.
      try { text = await readPartText(part); } catch (e) { text = null; }
      if (!text) { break; }
      for (const line of String(text).split(/\r?\n/)) {
        if (line.trim()) { lines.push(line); }
      }
      part = nextLogPart(part);
    }
    return lines;
  }

  /** The same, parsed. A half-written last line is skipped, not thrown. */
  async function readLogEvents(readPartText, basePath) {
    return (await readLogParts(readPartText, basePath))
      .map(l => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter(Boolean);
  }

  async function storeList(getToken, apiUrl, prefix, delimiter) {
    const token = await getToken();
    /* cache: 'no-store' on BOTH reads. The pages poll the same url every time,
     * and a cached answer freezes the list on whatever it first saw - which
     * only a hard reload then escapes. migrations.html carried this and the
     * other six pages did not; here they all do. */
    const r = await fetch(storeUrl(apiUrl, 'store/list', { prefix: prefix || '', delimiter: delimiter || undefined }),
      { cache: 'no-store', headers: { Authorization: `Bearer ${token}` } });
    if (!r.ok) { throw await storeError(r, `list ${prefix || '(top)'}`); }
    const data = await r.json();
    /* truncated is new. The browser never paged, so a run past 5,000 blobs was
     * silently short by whatever it held. The facade pages; this says when even
     * that ran out. */
    return { names: data.names || [], prefixes: data.prefixes || [], truncated: !!data.truncated };
  }

  /* PERF-PROBES-1, STORE-HOLDS-ONE-1: does a listing a page holds show the
   * file is there? A read of a file that is not there is still a call to the
   * service, and 26% of the store reads measured in a week were. A listing
   * that was not read, or that the service cut short, cannot say no - so the
   * answer is yes, and the page asks (unknown means ask). The Overview,
   * Projects and Migrations ask this one copy (tests/js/perf-probes.test.js). */
  function storeHolds(listing, path) {
    if (!listing || listing.truncated) { return true; }
    return (listing.names || []).includes(path);
  }

  /* PLANVER-2: `asVersioned` returns { text, version } - the document AND the
   * version THE SERVICE ISSUED for it, from the same response.
   *
   * A page that needs to name the version of a plan it is agreeing to used to
   * compute it here, from the text it received. That requires the document to
   * travel BYTE FOR BYTE through a JSON service, which nobody wrote down and
   * the platform does not honour: measured 2026-09-17 against a real install,
   * the same blob hashed to one value in the service and another in the
   * caller, and no candidate reading closed the gap.
   *
   * The version comes back in a header beside the body, so it describes the
   * document the page is about to render - not a second call that could race
   * the first. That is what keeps the gate meaning what it says: an acceptance
   * names the plan the person was SHOWN.
   */
  async function storeBlob(getToken, apiUrl, path, opts) {
    const asText = !!(opts && opts.asText);
    const asVersioned = !!(opts && opts.asVersioned);
    const token = await getToken();
    const r = await fetch(storeUrl(apiUrl, 'store/blob', { path }),
      { cache: 'no-store', headers: { Authorization: `Bearer ${token}` } });
    /* A document that is not there yet is not an error: the pages ask for an
     * approval before anyone approved, a plan before anyone planned. */
    if (r.status === 404) { return null; }
    if (!r.ok) { throw await storeError(r, `read ${path}`); }
    if (asVersioned) {
      return { text: await r.text(), version: r.headers.get('x-vmf-document-version') || '' };
    }
    return asText ? r.text() : r.json();
  }

  /* PAGE-LOAD-1: THE DOCUMENTS A PAGE DRAWS, IN ONE CALL.
   *
   * MEASURED on a lab install, 2026-11-06: one load of the Overview or the
   * Assessments page sent about 200 calls to the service - one for each store
   * document, every run.json, assessment.json, approval.json and
   * run-status.json - and the page waited for all of them. Each call cost 30
   * ms to 2 s, and a load took a minute or two.
   *
   * storeDocs asks the service ONCE (store/docs): the store listed down to a
   * depth, and the text of each document whose name the page names. It
   * follows the service's pages (`next`) up to STORE_DOCS_PAGES_MAX calls.
   * The page keeps what comes back for that one load, and its own readers ask
   * heldList and heldJson first:
   *
   *   an answer   the listing or the document, from what came back;
   *   undefined   this cannot say - the page asks the service as before.
   *
   * UNKNOWN MEANS ASK. A listing the service cut short, a level deeper than
   * the call went, a document the call did not name, one past the last page
   * read, or one the store refused to read: each is undefined, so the page
   * reads it the way it always did. The page never shows less than before
   * because of this; at worst it makes the calls it made before.
   *
   * A document that is empty or not JSON is undefined too (PAGE-LOAD-2 fix
   * round): the page reads it itself and gets that read's error. NO VERSION comes back: a page that saves a document
   * reads it with storeBlob(..., { asVersioned }) (PLANVER-2). */
  const STORE_DOCS_PAGES_MAX = 20;

  async function storeDocs(getToken, apiUrl, opts) {
    const o = opts || {};
    const prefix = String(o.prefix || '');
    const depth = Number(o.depth) || 3;
    const read = (o.read || []).join(',');
    const docs = new Map();
    let names = [], folders = [], truncated = false, complete = false, after = '';
    for (let page = 0; page < STORE_DOCS_PAGES_MAX; page++) {
      const token = await getToken();
      const r = await fetch(storeUrl(apiUrl, 'store/docs', { depth, read, prefix: prefix || undefined, after: after || undefined }),
        { cache: 'no-store', headers: { Authorization: `Bearer ${token}` } });
      if (!r.ok) { throw await storeError(r, 'read documents'); }
      const data = await r.json();
      // The listing comes with the first page only.
      if (!after) { names = data.names || []; folders = data.folders || []; truncated = !!data.truncated; }
      for (const d of (data.docs || [])) { if (d && d.path) { docs.set(String(d.path), d); } }
      if (!data.next) { complete = true; break; }
      after = String(data.next);
    }
    return { prefix, depth, names: new Set(names.map(String)), folders: folders.map(String), truncated, complete, docs };
  }

  /* How many folders down a path is from where the call listed, or -1 when it
   * is not under it. 'a/b/c.json' under '' is 3. */
  function heldDepth(held, path) {
    const p = String(path ?? '');
    if (!p.startsWith(held.prefix)) { return -1; }
    return p.slice(held.prefix.length).split('/').filter(Boolean).length;
  }

  /* The listing storeList would give for (prefix, delimiter), or undefined. */
  function heldList(held, prefix, delimiter) {
    if (!held || held.truncated) { return undefined; }
    const p = String(prefix || '');
    // A prefix that is part of a name, not a folder, is the service's to answer.
    if (p && !p.endsWith('/')) { return undefined; }
    const level = heldDepth(held, p);
    if (level < 0) { return undefined; }
    const under = (x) => x.startsWith(p) && x.length > p.length;
    if (delimiter === '/') {
      // One level: the documents and the folders straight inside this one.
      if (level + 1 > held.depth) { return undefined; }
      return {
        names: [...held.names].filter(n => under(n) && !n.slice(p.length).includes('/')),
        prefixes: held.folders.filter(f => under(f) && !f.slice(p.length).includes('/')),
        truncated: false,
      };
    }
    if (delimiter) { return undefined; }
    // Every document below: only when none can be deeper than the call went -
    // a folder AT the depth holds documents one level past it.
    if (level >= held.depth) { return undefined; }
    if (held.folders.some(f => under(f) && heldDepth(held, f) >= held.depth)) { return undefined; }
    return { names: [...held.names].filter(under), prefixes: [], truncated: false };
  }

  /* Is this document in the store? true or false from the listing, or
   * undefined when the listing did not go this deep. */
  function heldHas(held, path) {
    if (!held || held.truncated) { return undefined; }
    const level = heldDepth(held, path);
    if (level < 1 || level > held.depth) { return undefined; }
    return held.names.has(String(path));
  }

  /* PAGE-LOAD-2: { value } for a document as TEXT - null when it is not in the
   * store, or was gone when the call read it - or undefined when the page must
   * ask the service. A log part is text, and the Migrations page and the
   * support bundle read the log from the same call as the rest of the run. */
  function heldText(held, path) {
    if (!held || held.truncated) { return undefined; }
    const p = String(path ?? '');
    const level = heldDepth(held, p);
    if (level < 1 || level > held.depth) { return undefined; }
    const doc = held.docs.get(p);
    if (doc) {
      // The store refused this read: not an answer.
      if (doc.error) { return undefined; }
      if (doc.text === null || doc.text === undefined || doc.text === '') { return { value: null }; }
      return { value: String(doc.text) };
    }
    // Not in a listing that went this deep: not in the store.
    if (!held.names.has(p)) { return { value: null }; }
    // In the store, but not read by the call.
    return undefined;
  }

  /* { value } for a document - null when it is not in the store, or is not
   * JSON - or undefined when the page must ask the service. */
  function heldJson(held, path) {
    const known = heldText(held, path);
    if (!known) { return undefined; }
    /* PAGE-LOAD-2 fix round: a document the store HOLDS whose text is empty
     * or not JSON is not an answer. Taken as null it vanished without a word -
     * a damaged machine record left the Migrations page by its filter, and the
     * support bundle left it out of couldNotRead. Undefined, so the page reads
     * it itself and gets the error that read gives, as it did before. */
    if (known.value === null) { return held.docs.has(String(path ?? '')) ? undefined : known; }
    try { return { value: JSON.parse(known.value) }; } catch (e) { return undefined; }
  }

  /* ---------- POPUP-3: signing in never opens a window ----------------------
   *
   * The pages sign in and ask for tokens by REDIRECT, never through a popup
   * window. A browser that blocks popups made the whole product unusable: MSAL
   * reports `empty_window_error: window.open returned null`, and there is
   * nothing the person can do about it from inside the page.
   *
   * This is a different thing from POPUP-1, which removed browser BOXES
   * (confirm, alert, prompt). These are MSAL's own sign-in windows.
   *
   * A blocker does not refuse them evenly. A popup opened FROM A CLICK is
   * usually allowed; one opened while a page loads is not. So sign-in appeared
   * to work and a page that asks for a second permission as it loads did not -
   * a failure that arrives only when it matters.
   *
   * The flow is redirect everywhere, with no popup left to fall back to. One
   * path, not two.
   *
   * THE GUARD IS THE PART THAT MATTERS. A popup that fails leaves the page
   * standing. A redirect that fails comes BACK to the page, and a page that
   * asks again on load leaves again - a loop nobody can stop, on a permission
   * that may never be grantable. The Admin page asks for directory permissions
   * only an administrator can approve, which is exactly where that would
   * happen.
   *
   * One interactive attempt per session. A silent token that works clears it,
   * so a person who is refused is refused once.
   */
  const INTERACTIVE_TRIED = 'vmfInteractiveTried';

  /** The accounts to work with, after a return from a sign-in redirect.
   *  Call it where getAllAccounts() used to be called, straight after
   *  initialize(). It answers with the account the redirect brought back, or
   *  with whatever is already cached. */
  async function accountsAfterReturn(msalApp) {
    let returned = null;
    try {
      returned = await msalApp.handleRedirectPromise();
    }
    catch (e) {
      /* THE RETURN CARRIED AN ERROR - the directory refused. Do not ask again:
       * asking again is the loop. Remember the attempt and let the page show
       * what happened. */
      sessionStorage.setItem(INTERACTIVE_TRIED, '1');
      throw e;
    }
    if (returned && returned.account) {
      sessionStorage.removeItem(INTERACTIVE_TRIED);
      return [returned.account];
    }
    return msalApp.getAllAccounts();
  }

  /** A token, silently if the session already holds one, and otherwise by
   *  leaving for the directory and coming back. THE SECOND PATH DOES NOT
   *  RETURN: the browser navigates away, and the page runs again from the top
   *  with the answer. Callers get the original failure instead, so nothing
   *  waits on a promise that can never settle. */
  async function tokenOrRedirect(msalApp, req) {
    /* TOKEN-SCOPE-1: a request with no scope is a page fault, not a sign-in
       question. MSAL v5 answers it with a sign-in token that the service
       refuses with 401, and the page then tells the person to sign in again,
       which cannot help. Refuse it here, before the library sees it. */
    if (!req || !Array.isArray(req.scopes) || req.scopes.length === 0) {
      throw new Error('vmf_no_scope: the page asked for a token with no scope');
    }
    try {
      const r = await msalApp.acquireTokenSilent(req);
      sessionStorage.removeItem(INTERACTIVE_TRIED);
      return r.accessToken;
    }
    catch (e) {
      if (sessionStorage.getItem(INTERACTIVE_TRIED)) {
        /* SAY SO. Refusing silently leaves a button that does nothing, which
           is the trap rule 11 forbids. */
        const asked = new Error('vmf_asked_already: asked once already in this session');
        asked.cause = e;
        throw asked;
      }
      sessionStorage.setItem(INTERACTIVE_TRIED, '1');
      await msalApp.acquireTokenRedirect(req);
      throw e;
    }
  }

  /** Sign in. Leaves the page; the answer arrives at accountsAfterReturn(). */
  async function signInRedirect(msalApp, scopes) {
    sessionStorage.setItem(INTERACTIVE_TRIED, '1');
    await msalApp.loginRedirect({ scopes, prompt: 'select_account' });
  }

  /* BLOCKED-NAME-1: is this quota record blocked? The state is BLOCKED, and
   * blockReason says why - only reservation-failed is about capacity. Every
   * writer gives BLOCKED (OLD-VERSION-READERS-REMOVE-8). One function,
   * because two pages ask this question and two copies is one place to
   * forget. The engine's twin is Test-VmfClaimBlocked. */
  function claimBlocked(state) {
    return String(state == null ? '' : state).trim().toUpperCase() === 'BLOCKED';
  }
  /* RESERVING-STUCK-1: a RESERVING claim nobody is making any more - Azure
   * did not confirm it in time, or it has been RESERVING longer than any
   * create takes, or it cannot say since when. The engine's twin is
   * Test-VmfClaimReservingStuck, with the same number of minutes.
   * ODCR-STATUS-1: the five-minute pass of the service reads a RESERVING
   * claim from Azure once no reserve job runs, and marks one Azure still
   * makes as not confirmed - so the 60 minutes apply only to a claim the
   * service cannot read from Azure. */
  const RESERVING_STUCK_MINUTES = 60;
  function claimReservingStuck(doc, nowMs) {
    if (!doc || String(doc.state || '').toUpperCase() !== 'RESERVING') { return false; }
    if (doc.reservationUnconfirmedUtc) { return true; }
    const since = Date.parse(doc.reservingSinceUtc || '');
    if (!Number.isFinite(since)) { return true; }
    const now = Number.isFinite(nowMs) ? nowMs : Date.now();
    return (now - since) >= RESERVING_STUCK_MINUTES * 60000;
  }
  /* REGIONAL-QUOTA-BOTH-PAGE-1: is this quota record short of the Total
   * Regional vCPUs quota? Blocked on it, or blocked on its family with the
   * quota check's answer beside it that the region is short for the same
   * machines (regionalShort, capacity-claim v14). The engine decided both;
   * nothing here judges the figures. The engine's twin is
   * Test-VmfClaimRegionalShort, which puts the record in its region's quota
   * increase request, and both are held to tests/fixtures/regional-short.json. */
  function claimRegionalShort(doc) {
    if (!doc || !claimBlocked(doc.state)) { return false; }
    return doc.blockReason === 'regional-quota-shortfall' ||
      (doc.blockReason === 'quota-shortfall' && doc.regionalShort === true);
  }
  /* REGIONAL-QUOTA-REQUESTED-PAGE-1: does an increase of the Total Regional
   * vCPUs quota wait for this record? Request-VmfQuota writes the answer: the
   * request of the record's own reason moves it to QUOTA_REQUESTED and keeps
   * its blockReason, and a regional request filed beside a family request
   * writes quota.regionalRequestedUtc - always, where regionalRequestId is
   * written only when Azure gives an id (an approval at once gives none), so
   * the time is what is read. A record whose family was refused
   * stays blocked with the regional request beside it. Any other state is
   * history for the request: a quota check writes the record again. The
   * engine has no reader of this, so no twin; the records it writes are held
   * to tests/fixtures/regional-requested.json. */
  function claimRegionalRequested(doc) {
    if (!doc) { return false; }
    const filedText = (v) => typeof v === 'string' && v.trim() !== '';
    const q = doc.quota || {};
    const besideFamily = filedText(q.regionalRequestedUtc);
    if (doc.state === 'QUOTA_REQUESTED') {
      return doc.blockReason === 'regional-quota-shortfall' || besideFamily;
    }
    return claimBlocked(doc.state) && besideFamily;
  }
  /* COUNT-TRUTH-1: what happened to one machine, in one place.
   *
   * Every count of "migrated" asked its own question, and they did not agree:
   * after a six-machine run with one put back, the Reports page showed 4, 6
   * and "restored 0" on one screen. A machine put back keeps MIGRATED and
   * gains `restore`; SKIPPED is a machine LEFT OUT and was counted as migrated.
   *
   * The service has the twin of this (Get-VmfMachineOutcome), and both are held
   * to tests/fixtures/machine-outcomes.json. */
  const WORKING_STATES = ['PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED',
                          'CONVERTING', 'STARTING', 'VALIDATING'];
  /* NOT-IN-WAVE-QUEUED-1: is this plan machine left out of the migration as
   * the pages show it? True when it is in no wave (no wave name, or the
   * planner's 'unscheduled' - the only wave the engine skips; the page's
   * 'unplanned' names its own group, never an entry), the plan would move it (any path
   * but MANUAL or EXCLUDED), and it has no state document. No wave takes it:
   * the wave editor's Remove put it there, and the wave editor still lists
   * it. It is not part of the migration, so it is never shown with it. A
   * machine with a state document has history and is always
   * shown; a MANUAL or EXCLUDED one says why the plan does not move it.
   * The service has the twin (Test-VmfEntryOutsideRun), and both are held to
   * tests/fixtures/entry-outside-run.json. */
  function outsideRun(entry, doc) {
    if (!entry || doc) { return false; }
    const w = entry.wave;
    const noWave = !w || w === 'unscheduled';
    return noWave && !['MANUAL', 'EXCLUDED'].includes(entry.path);
  }
  /* DELETE-UNSTARTED-WAVE-1: where a migration is in its life - setup,
   * planned, running or finished - by the service's own rule
   * (Get-VmfRunStage). The service refuses Delete this migration while it says
   * running, so the page shows Stop this migration then. They asked two
   * questions: between two waves the service said running and the page showed
   * Delete, which the service refused. Only machines the plan moves (path A)
   * count, and not one in no wave that never ran (outsideRun). running: at
   * least one machine started (a state that is not PLANNED, settled ones
   * included) and not every machine settled. A machine's state document is
   * found by its ID in any letter case. Both are held to
   * tests/fixtures/run-stage.json. Returns { stage, machines, settled }. */
  function runStage(plan, docs) {
    const settledStates = ['MIGRATED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED'];
    let entries = ((plan && plan.entries) || []).filter(e => e && e.path === 'A');
    if (!entries.length) { return { stage: 'setup', machines: 0, settled: 0 }; }
    const byId = new Map();
    for (const d of (docs || [])) { if (d && d.vmId) { byId.set(idKey(d.vmId), d); } }
    const planned = entries.length;
    entries = entries.filter(e => !outsideRun(e, byId.get(idKey(e.vmId)) ?? null));
    let started = 0;
    let settled = 0;
    for (const e of entries) {
      const state = byId.get(idKey(e.vmId))?.state;
      if (settledStates.includes(state)) { settled++; started++; }
      else if (state && state !== 'PLANNED') { started++; }
    }
    if (started === 0) { return { stage: 'planned', machines: planned, settled: 0 }; }
    if (settled >= entries.length) { return { stage: 'finished', machines: entries.length, settled }; }
    return { stage: 'running', machines: entries.length, settled };
  }
  function machineOutcome(doc) {
    if (!doc) { return 'notStarted'; }
    // FINISH-COUNT-1: a put-back that Azure refused a data disk swap left
    // stopped (swapPending, SWAP-REFUSED-AFTER-STOP-1) waits for a person to
    // use Finish the restore or Finish the rollback - whatever the state and
    // the restore record say. Only a record counts: no value, an empty object
    // or a list names no swap. A step still running keeps 'working': the wave
    // worker's rollback writes the swap before it records its stop.
    const sp = doc.swapPending;
    if (sp && typeof sp === 'object' && !Array.isArray(sp) && Object.keys(sp).length > 0
        && !WORKING_STATES.includes(doc.state)) { return 'attention'; }
    // STATUS-WORDS-1: a restore as new as the stop ends the stop - the rule
    // the panel's stop box (currentStop), the decision gate and Leave this
    // machine out already use. After a restore that worked, a machine that
    // had needed attention still said Needs attention, and the report put it
    // under the failures. A migrated machine keeps its put-back unless a later
    // step shows that it moved again after the restore.
    // ends: true - the restore is as new as every step on record (or no step
    // has a time); false - a later step is on record; null - no restore, or
    // its time cannot be read. Unknown is not a yes.
    const ms = (v) => ((v === null || v === undefined || v === '') ? NaN : Date.parse(String(v)));
    const ends = (() => {
      const r = doc.restore;
      if (!r || typeof r !== 'object') { return null; }
      const at = ms(r.restoredUtc);
      if (!Number.isFinite(at)) { return null; }
      let last = NaN;
      for (const h of (Array.isArray(doc.history) ? doc.history : [])) {
        const t = ms(h && h.tsUtc);
        if (Number.isFinite(t) && !(t <= last)) { last = t; }
      }
      return Number.isFinite(last) ? at >= last : true;
    })();
    switch (doc.state) {
      case 'MIGRATED':               return (doc.restore && ends !== false) ? 'putBack' : 'migrated';
      case 'FAILED_ROLLED_BACK':     return ends === true ? 'putBack' : 'rolledBack';
      case 'NEEDS_DECISION':         return ends === true ? 'putBack' : 'attention';
      case 'FAILED_NEEDS_ATTENTION': return ends === true ? 'putBack' : 'attention';
      case 'SKIPPED':                return 'leftOut';
      case 'PLANNED':                return 'notStarted';
      default:                       return WORKING_STATES.includes(doc.state) ? 'working' : 'unknown';
    }
  }
  /* RUN-SUMMARY-SWAP-1: which outcome waits for a person - a stop, a decision,
   * a swap a put-back left (attention) and a rollback (rolledBack). An outcome
   * this version does not know waits for nobody. The Migrations page's
   * Waiting on people card asks this, and the engine counts
   * run-status.json's summary.waitsOnPerson by its twin
   * (Test-VmfOutcomeWaitsOnPerson); both are held to
   * tests/fixtures/machine-outcomes.json. */
  function outcomeWaitsOnPerson(outcome) {
    return ['attention', 'rolledBack'].includes(outcome);
  }
  /* STATUS-WORDS-1: what a machine IS NOW - one status for the row, the panel,
   * the badges, the counters and the wave line of the run page.
   *
   * Seen on a lab install: the status said the step that failed during the
   * whole rollback, "Preparing" for 13 minutes while the machine was moved,
   * "Migrated" beside "Restoring", "Restored" while the restore waited for
   * Finish, and "Needs attention" after a restore that worked. Each place
   * asked its own question of the state alone.
   *
   * It reads the state document AND the latest step. live.events: the lines
   * of the run history for this machine, in any order; live.restoring: a
   * restore (kind 'restore') or a finish (kind 'finish') the page found
   * running in those lines ({ since, last, kind }). The checkpoints the engine
   * writes say the same on the document: rollbackPending (written before a
   * rollback changes anything, removed with its stop) and putBackJob (written
   * before a restore or a finish changes anything; ended or removed when it
   * ends).
   *
   * Returns { key, step, finishes, state, since, at, bar }:
   *   key   - queued, step, rollingBack, restoring, finishing,
   *           finishRestore, finishRollback, decision, attention,
   *           migrated, rolledBack, restored, leftOut, unknown;
   *   step  - for key step, the step that runs now (a working state);
   *   since - when this status began; at - its newest change: the newest
   *           line of the machine while it works, the end itself once it
   *           ended (a later line, such as a deleted copy, is no change);
   *   bar   - run (how far the move got), done (green, Migrated only), none.
   * The end results are machineOutcome's, which the service twins; both are
   * held to tests/fixtures/machine-status.json. PURE. */
  function machineStatus(doc, live) {
    const l = live || {};
    const ms = (v) => ((v === null || v === undefined || v === '') ? NaN : Date.parse(String(v)));
    const evs = (Array.isArray(l.events) ? l.events : [])
      .filter(e => e && Number.isFinite(ms(e.tsUtc)))
      .slice().sort((a, b) => ms(a.tsUtc) - ms(b.tsUtc));
    const out = (key, extra) => Object.assign({ key, step: null, finishes: null, state: doc ? (doc.state ?? null) : null,
                                                since: null, at: null, bar: 'none' }, extra);
    // The newest line at or after a time, else that time.
    const newestFrom = (since) => {
      const s = ms(since);
      if (!Number.isFinite(s)) { return since ?? null; }
      let at = since, best = s;
      for (const e of evs) { const t = ms(e.tsUtc); if (t >= best) { best = t; at = e.tsUtc; } }
      return at;
    };
    if (!doc) { return out('queued'); }
    let lastAt = null;
    for (const h of (Array.isArray(doc.history) ? doc.history : [])) {
      if (h && Number.isFinite(ms(h.tsUtc)) && (lastAt === null || ms(h.tsUtc) >= ms(lastAt))) { lastAt = h.tsUtc; }
    }
    const isRecord = (v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length > 0;
    // A restore or a finish that runs: the page's lines, or the
    // job's own checkpoint while it has not ended.
    const job = (isRecord(doc.putBackJob) && !isRecord(doc.putBackJob.ended)) ? doc.putBackJob : null;
    const jobKind = job ? String(job.kind ?? '') : '';
    const sp = isRecord(doc.swapPending) ? doc.swapPending : null;
    const restoring = l.restoring || null;
    const busy = (key, run, extra) => {
      const since = (run && run.since) || (job && job.startedUtc) || null;
      return out(key, Object.assign({ since, at: (run && run.last) || newestFrom((job && job.phaseUtc) || since) }, extra));
    };
    if ((restoring && restoring.kind === 'finish') || jobKind === 'finish') {
      const finishes = (job && job.options && job.options.finishes) || (sp && sp.kind) || 'restore';
      return busy('finishing', restoring, { finishes: finishes === 'rollback' ? 'rollback' : 'restore' });
    }
    if (restoring || jobKind === 'restore') { return busy('restoring', restoring); }
    const outcome = machineOutcome(doc);
    if (outcome === 'working') {
      // A rollback writes its checkpoint before its first change and removes
      // it in the same write as its stop.
      if (isRecord(doc.rollbackPending)) {
        const since = doc.rollbackPending.startedUtc ?? lastAt;
        return out('rollingBack', { since, at: newestFrom(since) });
      }
      // The step that runs: the state document, unless the lines show a step
      // that started after its newest entry - a page that read the document
      // before the step moved on still says the step that runs now.
      let step = doc.state, since = lastAt;
      for (const e of evs) {
        if (e.outcome !== 'start' || !WORKING_STATES.includes(e.step)) { continue; }
        if (lastAt === null || ms(e.tsUtc) >= ms(lastAt)) { step = e.step; since = e.tsUtc; }
      }
      return out('step', { step, since, at: newestFrom(since), bar: 'run' });
    }
    const ended = (key, since, bar) => out(key, { since: since ?? null, at: since ?? null, bar: bar || 'none' });
    switch (outcome) {
      case 'attention': {
        if (sp && sp.kind === 'restore') { return ended('finishRestore', sp.leftUtc ?? lastAt); }
        if (sp && sp.kind === 'rollback') { return ended('finishRollback', sp.leftUtc ?? lastAt); }
        return ended(doc.state === 'NEEDS_DECISION' ? 'decision' : 'attention', lastAt);
      }
      case 'putBack':    return ended('restored', Number.isFinite(ms(doc.restore && doc.restore.restoredUtc)) ? doc.restore.restoredUtc : lastAt);
      case 'migrated':   return ended('migrated', lastAt, 'done');
      case 'rolledBack': return ended('rolledBack', lastAt);
      case 'leftOut':    return ended('leftOut', lastAt);
      case 'notStarted': return out('queued');
      default:           return ended('unknown', lastAt);
    }
  }
  /** Every outcome present, at zero when nothing has it. */
  function outcomeCounts(docs) {
    const c = { migrated: 0, putBack: 0, rolledBack: 0, attention: 0,
                leftOut: 0, working: 0, notStarted: 0, unknown: 0 };
    for (const d of (docs || [])) { c[machineOutcome(d)]++; }
    return c;
  }

  /* APPROVE-GROUP-1, OVERVIEW-SUMMARY-1: what a migration's run status says,
   * in one place. The migrations list groups its migrations by it and the
   * overview counts by it. Two copies would be two pages that disagree about
   * one migration - and the overview is the screen a person trusts before
   * any other.
   *
   * run-status.json holds a summary of the WHOLE migration: every wave, its
   * machines and their states, what the next wave waits for, and the machines
   * that wait for a person. The engine writes it in every status document
   * (Write-VmfRunStatusDocument). The live fields beside it (stateCounts,
   * running, wave) are the running wave's only, and are never read in its
   * place: a document whose summary cannot be read says nothing about the
   * migration (runSummaryOf gives null), and a caller says it cannot tell.
   *
   * The machine states that wait for a person. Each page that keeps its own
   * copy of this list is held to this one by tests/js/overview-summary.test.js. */
  const PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  // A status written in the last fifteen minutes is a migration in progress.
  const RUN_ACTIVE_MS = 900000;
  // What the next wave waits for, when that is a person.
  // WAVE-APPROVE-TIMER-WORDS-1: signOffOutOfDate is the plan timer's own
  // refusal code, which the engine's summary now records: the wave changed
  // after the plan was signed off, so the timer does not start it, and a
  // person selects Start this wave. The summary said start, and the list put
  // the migration under Planned, where nothing waits for a person.
  const RUN_GATE_WAITS = ['acknowledgement', 'acceptance', 'approval', 'signOffOutOfDate'];
  // And the word on the button that person presses: the tag a row shows.
  const RUN_GATE_TAG = { acknowledgement: 'accept', acceptance: 'accept', approval: 'approve', signOffOutOfDate: 'start' };

  /* The summary of a status document, when it has one a page can read.
   * Anything else - a document with no summary, a damaged one, or one with no
   * count of the machines that wait for a person - is null, which every
   * caller reads as "cannot tell". */
  function runSummaryOf(status) {
    const s = status ? status.summary : null;
    if (!s || typeof s !== 'object') { return null; }
    if (!s.next || typeof s.next.waitsFor !== 'string') { return null; }
    if (!s.stateCounts || typeof s.stateCounts !== 'object') { return null; }
    if (runWaitingCount(s) === null) { return null; }
    return s;
  }

  /* RUN-SUMMARY-SWAP-1: the machines of a whole migration (or of one of its
   * waves) that wait for a person, or null when there is no count to read.
   * The engine counts them by the one definition (waitsOnPerson:
   * Get-VmfMachineOutcome, attention or rolledBack), which counts a machine a
   * restore left stopped - its state stays MIGRATED - and leaves out a stop a
   * restore ended. A count that is not a whole number is not read, and the
   * stop states are never counted in its place (OLD-VERSION-READERS-REMOVE-6). */
  function runWaitingCount(summary) {
    if (!summary || typeof summary !== 'object') { return null; }
    const n = summary.waitsOnPerson;
    return Number.isInteger(n) && n >= 0 ? n : null;
  }

  /* The tag for what the next wave waits for: accept, approve or start, or null when
   * it waits for no person. */
  function runGateTag(waitsFor) {
    return Object.prototype.hasOwnProperty.call(RUN_GATE_TAG, waitsFor) ? RUN_GATE_TAG[waitsFor] : null;
  }

  /* RUNPICK-1: which group of the migrations list a migration belongs in.
   *
   * TWO DEFECTS LIVED IN THE EXPRESSION THIS REPLACED, and both showed the
   * same symptom - a run the list had nothing useful to say about.
   *
   * 1. A RUN THAT WAS PLANNED AND NEVER STARTED matched nothing. It is not
   *    being set up, nothing has happened in the last fifteen minutes, no
   *    machine has a problem and none is finished - so it fell through to
   *    'Other' and was shown as 'idle'. On a fresh install that is the ONLY
   *    run there is, and it is the one somebody is about to act on.
   *
   * 2. A RUN WITH AN EMPTY SET OF COUNTS READ AS 'Completed'. The old test was
   *    `Object.keys(counts).every(...)`, and every() over no keys is TRUE.
   *
   * Both are fixed by asking what has MOVED rather than what is absent: a
   * machine past PLANNED. No machine has moved and it is planned; the ones
   * that moved all ended well and it is complete.
   *
   * APPROVE-GROUP-1: THE COUNTS WERE ONE WAVE'S. The status document was a
   * snapshot of the wave that ran last, so a migration whose wave 1 finished
   * and whose wave 2 waited for approval counted wave 1 only - every machine
   * MIGRATED - and was listed as Completed. With the summary (run-status v3)
   * the counts are the whole migration's, a wave still to run is never
   * Completed, and a wave that waits for a person to accept or approve it is
   * Waiting for approval. Without a summary it can read the page cannot tell
   * what any wave did: a run with no status document never started (Planned),
   * and one with a document is Other. The live counts of one wave are never
   * read for the migration (OLD-VERSION-READERS-REMOVE-6).
   *
   * OVERVIEW-SUMMARY-1: moved here from the migrations page, so the overview
   * asks the same question with the same code. Pure, so it is tested alone. */
  function runGroup(setupOnly, counts, updatedMs, nowMs, facts) {
    if (setupOnly) { return 'Still being prepared'; }
    const summary = (facts && facts.summary) || null;
    // RUN-SUMMARY-SWAP-1: the summary's count by the one definition.
    const problem = (runWaitingCount(summary) || 0) > 0;
    // A person is needed before the next wave can start. This comes before the
    // fifteen minutes below: the wave that just ended is not still in progress.
    // Not for a paused migration - an approval starts nothing there - and not
    // over a machine that stopped, which is the more urgent thing to see.
    if (summary && !summary.halted && !problem && RUN_GATE_WAITS.includes(summary.next.waitsFor)) { return 'Waiting for approval'; }
    if (updatedMs && (nowMs - updatedMs) < RUN_ACTIVE_MS) { return 'In progress'; }
    if (problem) { return 'Needs attention'; }
    // No status document at all: the run never started. A document with no
    // summary this page can read: nothing here can say more.
    if (!summary) { return counts ? 'Other' : 'Planned'; }
    // Paused or stopped: a person did that, and the run does not go on alone.
    if (summary.halted) { return 'Other'; }
    // A plan that moves no machine in a wave is planned, as it was before.
    if (!Number(summary.machines)) { return 'Planned'; }
    // The engine said a machine was on its way, and has not written for
    // fifteen minutes. That is not progress, and nothing here can say more.
    if (summary.next.waitsFor === 'running') { return 'Other'; }
    // A wave is still to run, and nothing in it waits for a person.
    if (summary.next.waitsFor !== 'none') { return 'Planned'; }
    const moved = Object.entries(summary.stateCounts).filter(([state, n]) => state !== 'PLANNED' && n > 0);
    // RESTORED-HOLD-1: a stop that a restore ended has ended, as a migrated
    // machine put back has.
    const unfinished = moved.filter(([state]) => !['MIGRATED', 'SKIPPED'].includes(state))
      .reduce((n, [, v]) => n + (Number(v) || 0), 0);
    return moved.length > 0 && unfinished <= (Number(summary.restoredStops) || 0) ? 'Completed' : 'Other';
  }

  /* VMID-CASE-1: a machine's name as Azure spells it on the machine.
   *
   * Azure gives some resource IDs with the resource group or the machine name
   * in upper case, and others as they were made. The ID is kept as the
   * assessment read it, so a name cut from the ID showed MX-G1W beside mx-o2w
   * in one wave. The records hold the name itself: the capture read from the
   * machine (captured.vmConfig.name), then the assessment (name). A recorded
   * name is used only when it is the last part of the ID, ignoring case, so a
   * record of another machine can never rename this one.
   *
   * The engine's twin is Get-VmfMachineName, and both are held to
   * tests/fixtures/machine-names.json. */
  function machineName(vmId, ...records) {
    const leaf = String(vmId == null ? '' : vmId).split('/').pop();
    const fits = (n) => typeof n === 'string' && n !== '' && (!leaf || n.toLowerCase() === leaf.toLowerCase());
    const found = records.filter(Boolean);
    for (const r of found) {
      const n = r.captured && r.captured.vmConfig && r.captured.vmConfig.name;
      if (fits(n)) { return n; }
    }
    for (const r of found) { if (fits(r.name)) { return r.name; } }
    return leaf;
  }
  /** VMID-CASE-1: one key for one Azure resource ID, whatever its letter case. */
  function idKey(id) { return String(id == null ? '' : id).toLowerCase(); }
  /** VMID-CASE-1: a name for each machine from lists of records (state
   *  documents, assessment records), found by the ID in any letter case. */
  function machineNames(...lists) {
    const byId = new Map();
    for (const list of lists) {
      for (const r of (list || [])) {
        if (!r || !r.vmId) { continue; }
        const k = idKey(r.vmId);
        if (!byId.has(k)) { byId.set(k, []); }
        byId.get(k).push(r);
      }
    }
    return (vmId) => machineName(vmId, ...(byId.get(idKey(vmId)) || []));
  }
  /** Has a machine in this state started its migration? Every state the
   *  engine writes after PLANNED, settled ones included. The wave editor
   *  locks a started machine (no drag, no Remove, no Change target), and the
   *  Migrations page asks the same rule to know whether the editor can still
   *  change anything (WAVES-BUTTON-RUNNING-1). No state reads as not started. */
  function machineStarted(state) {
    return ['PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING',
      'MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'].includes(state);
  }
  /** WAVE-RUNNING-LEASE-1: the engine's lease limit, in seconds
   *  ($script:VmfMachineLeaseTimeoutSeconds). A wave worker's hold older than
   *  this belongs to a worker that stopped. A test holds the two equal. */
  const LEASE_LIMIT_SECONDS = 900;
  /** WAVE-RUNNING-LEASE-1: does a machine keep its wave running, and why?
   *  'none', 'working' or 'endedHold'. The engine's rule (Get-VmfMachineHold,
   *  which Get-VmfWaveRunningDetail and the service's removal of a stopped
   *  worker's hold ask), held to tests/fixtures/machine-hold.json in both
   *  languages:
   *    working    a lease is held - a wave worker or a restore -
   *               or the stored state is not final. PLANNED counts, because a
   *               worker writes it when it TAKES the machine (WAVE-MIX-2).
   *    endedHold  a WAVE WORKER's lease older than the limit on a machine
   *               whose state is final: the worker stopped after the move
   *               ended, and the service removes the hold at its next check.
   *    none       no lease, and no state document or a final one.
   *  Both 'working' and 'endedHold' keep the wave running: the engine refuses
   *  an edit and a release of it. Pass the state DOCUMENT's state, or nothing
   *  when the machine has none (a machine that only waits for a slot has
   *  none, so never pass a PLANNED stand-in), and the machine's lease
   *  document, or nothing. A heartbeat that is not a time is not old. */
  function machineHold(storedState, lease, nowMs) {
    const settled = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
    const final = Boolean(storedState) && settled.includes(storedState);
    if (lease) {
      const now = Number.isFinite(nowMs) ? nowMs : Date.now();
      const beat = Date.parse(String(lease.heartbeatUtc ?? ''));
      const old = Number.isFinite(beat) && beat < now - LEASE_LIMIT_SECONDS * 1000;
      const putBack = /^restore:/.test(String(lease.workerId ?? ''));
      return (final && old && !putBack) ? 'endedHold' : 'working';
    }
    return (storedState && !final) ? 'working' : 'none';
  }
  /** WAVE-RUNNING-PLANNED-1, WAVE-RUNNING-LEASE-1: does a machine keep its
   *  wave running? machineHold is not 'none'. The wave editor and the
   *  Migrations page both ask this, with the machine's lease. */
  function machineAtWork(storedState, lease, nowMs) {
    return machineHold(storedState, lease, nowMs) !== 'none';
  }
  /** WAVE-RUNNING-LEASE-1: the hold of a wave - 'working' when any machine
   *  is at work, else 'endedHold' when a stopped worker still holds one, else
   *  'none'. stateOf gives a machine's state document's state, leaseOf its
   *  lease document; both take the plan's machine ID. */
  function waveHold(entries, stateOf, leaseOf, nowMs) {
    let ended = false;
    for (const e of (entries || [])) {
      if (!e) { continue; }
      const hold = machineHold(stateOf(e.vmId), leaseOf ? leaseOf(e.vmId) : undefined, nowMs);
      if (hold === 'working') { return 'working'; }
      if (hold === 'endedHold') { ended = true; }
    }
    return ended ? 'endedHold' : 'none';
  }
  /** WAVE-RUNNING-LEASE-1: the run's lease documents, by the machine ID each
   *  one names (idKey). A lease's file name is not read: that would be a
   *  second copy of the engine's Get-VmfVmKey. */
  function leasesByMachine(docs) {
    const byId = new Map();
    for (const d of (docs || [])) { if (d && d.vmId) { byId.set(idKey(d.vmId), d); } }
    return byId;
  }
  /** BSV2-TARGET-1: the size series a person reads for a target - the option
   *  (v5, v6, v7) the engine plans it on, except a Bsv2 size, which is planned
   *  on v5 because it follows the v5 rules, and is not a v5 size. The engine
   *  reads a Bsv2 size by its series from target-families.json
   *  (Get-VmfBurstableTarget); tests hold both to tests/fixtures/bsv2-size-names.json. */
  function seriesLabel(option, size) {
    return /^Standard_B\d+[lt]?s_v2$/i.test(String(size ?? '')) ? 'Bsv2' : String(option ?? '');
  }
  /** SIGNOFF-NULL-1: does this plan entry require a person's sign-off before
   *  its wave runs? Fails safe: only a stored boolean false turns it off - a
   *  missing key, null, 0 or any other value reads as required, as the
   *  engine's gate reads it (Test-VmfApprovalRequired). Every page asks this,
   *  and a wave needs a sign-off when ANY of its machines does. Tests hold
   *  both to tests/fixtures/approval-required.json. */
  function approvalRequired(entry) {
    return entry?.policy?.requireApproval !== false;
  }
  /* REBUILD-REMOVE-ACCEPT-1: the identity rule (getsNewIdentity,
   * identityOutcome, identityKeeper, identityLossToAccept, newIdentityNames)
   * and the rebuild rule (rebuildExtensionNames, rebuildFollowUps,
   * rebuildFollowUpLines, rebuildToAccept, rebuildNames) are gone: no target,
   * no acceptance and no sign-off names a rebuild or a new identity any more. */
  /** WAVE-2 lever 7, WAVE-WORDS-3: the retention of a wave in words, the
   *  same at Run it and in the acceptance dialog. Each page gives its own
   *  three strings; `many` holds {n}. No number reads as the default, 7. */
  function keepDaysText(days, never, one, many) {
    const n = Number.isFinite(Number(days ?? 7)) ? Number(days ?? 7) : 7;
    return n === 0 ? never : n === 1 ? one : String(many).replace('{n}', n);
  }
  /** TEMP-DISK-PREVIEW-1: the names of the machines in `entries` whose move is
   *  the in-place upgrade with the preview feature VMTempDiskResizePreview -
   *  Path A with the method preview, as the plan recorded it. The wave editor
   *  and the sign-off on Run it both ask this one rule. */
  function previewNames(entries, nameOf) {
    return (entries ?? []).filter(e => e && e.path === 'A' && e.target?.choice?.method === 'preview').map(e => nameOf(e.vmId));
  }
  /** ROLLBACK-CAPACITY-1, FILTER-DRIVER-READ-1 and DISK-PATH-READ-1: the
   *  lines under the settings of a wave at sign-off - the wizard's Run it and
   *  Review & accept options on the Migrations page both ask this one rule,
   *  each with its own words (`words.capacity`, a string, and `words.nvme`, a
   *  list), as keepDaysText does. Only the machines that move (path A) count:
   *   - the capacity line when one has an original size in a series whose
   *     capacity growth Microsoft restricts (assessment.sourceCapacityRestricted,
   *     written by the engine from data, plan-entry v35). Only a stored true:
   *     false and null (not known) show no line;
   *   - the NVMe lines when one goes to NVMe (a v6 or v7 size,
   *     target.controller NVMe - the engine's move kind nvme). A move to v5 or
   *     Bsv2 is a resize on SCSI and shows none.
   *  Capacity first. The page escapes and draws each line. */
  function signOffRiskLines(entries, words, nameOf) {
    const moving = (entries ?? []).filter(e => e && e.path === 'A');
    const lines = [];
    if (moving.some(e => e.assessment?.sourceCapacityRestricted === true)) { lines.push(words.capacity); }
    if (moving.some(e => e.target?.controller === 'NVMe')) { lines.push(...words.nvme); }
    // SQL-TEMPDB-SIGNOFF-1: last, and only for a wave with a machine where the
    // scan found SQL Server that moves to an NVMe temporary disk or none - it
    // names them. A page that gives no words for it shows none.
    if (words.sql) {
      const sql = sqlTempdbEntries(moving);
      if (sql.length) { lines.push(words.sql.replace('{names}', sql.map(e => nameOf(e.vmId)).join(', '))); }
    }
    return lines;
  }
  /** SQL-TEMPDB-SIGNOFF-1 (decided 2026-11-16): a plan entry that
   *  moves (path A), where the scan found SQL Server
   *  (assessment.sqlServerDetected, plan-entry v37 - a stored true only), from
   *  a SCSI temporary disk (assessment.sourceDiskArch scsi-temp) to an NVMe
   *  temporary disk or none (target.diskArch nvme-temp or diskless). On such a
   *  size, SQL Server can fail to start when tempdb is on the temporary disk.
   *  The engine's twin is Test-VmfSqlTempdbRisk, and the plan sign-off is
   *  refused until the approver names each such machine. "make sure its ONLY
   *  if we detect SQL": a machine with no SQL Server finding is never one. */
  function sqlTempdbRisk(e) {
    return Boolean(e) && e.path === 'A' && e.assessment?.sqlServerDetected === true &&
      e.assessment?.sourceDiskArch === 'scsi-temp' && ['nvme-temp', 'diskless'].includes(e.target?.diskArch);
  }
  /** The entries for which sqlTempdbRisk is true, in plan order. */
  function sqlTempdbEntries(entries) {
    return (entries ?? []).filter(sqlTempdbRisk);
  }
  /** REBUILD-REMOVE-PLAN-1: the subscription of a machine, from its resource
   *  id, in lower case - the feature is registered per subscription. '' when
   *  the id names none. */
  function subscriptionOf(vmId) {
    return ((String(vmId ?? '').match(/\/subscriptions\/([^/]+)/i) ?? [])[1] ?? '').toLowerCase();
  }
  /** REBUILD-REMOVE-PLAN-1: for each subscription that holds a machine of
   *  `entries` on the in-place upgrade (Preview) and where the preview feature
   *  is not registered, as `readOf(sub)` gives it ({ read, registered,
   *  loading } or null - not read yet), its machines. Registered is the only
   *  yes: not read is not registered. The wave editor draws one notice for
   *  each, as the targets step does. */
  function previewNeeds(entries, nameOf, readOf) {
    const bySub = new Map();
    for (const e of entries ?? []) {
      if (!(e && e.path === 'A' && e.target?.choice?.method === 'preview')) continue;
      const sub = subscriptionOf(e.vmId);
      const r = readOf(sub);
      if (r && r.read === true && r.registered === true) continue;
      if (!bySub.has(sub)) bySub.set(sub, { sub, read: r ?? null, names: [] });
      bySub.get(sub).names.push(nameOf(e.vmId));
    }
    return [...bySub.values()];
  }
  /** WAVE-AN-NAMES-1: on which row of the wave settings is this machine named
   *  for accelerated networking? 'on' (its move turns it on for the primary
   *  network interface), 'decides' (the scan did not read the interface, so
   *  the move reads it first; AN-MANA-DRIVER-RULE-1: a Linux kernel with no
   *  MANA driver never keeps it off - the machine stops before any change) or
   *  'none'. The engine works this out and records it on the plan entry
   *  (acceleratedNetworkingOutcome) on every entry that moves; this only
   *  reads it. An entry with no record is one that does not move, so nothing
   *  turns on - its own setting is not read in place of the record
   *  (OLD-VERSION-READERS-REMOVE-6). Held to tests/fixtures/an-outcome.json
   *  with the engine (Get-VmfPlannedAnOutcome). */
  function anOutcomeRow(entry) {
    const o = entry?.acceleratedNetworkingOutcome;
    if (o && typeof o === 'object') { return o.turnsOn === true ? 'on' : o.turnsOn === false ? 'none' : 'decides'; }
    return 'none';
  }
  /** The names of the machines in `entries` on one row ('on' or 'decides'). */
  function anOutcomeNames(entries, row, nameOf) {
    return (entries ?? []).filter(e => anOutcomeRow(e) === row).map(e => nameOf(e.vmId));
  }
  /** WAVE-OPTIONS-DISKS-1: the disk type change the move makes to this plan
   *  entry, read the way the engine reads it (Get-VmfDiskUpgradeValue):
   *  'os-standard-ssd' (Standard SSD for the OS disk), 'os' (Premium SSD for
   *  the OS disk), 'all' (Premium SSD for every disk), or '' when the disk
   *  types are kept. PowerShell's -in ignores case, so this does too. */
  function diskUpgradeOf(entry) {
    const v = String(entry?.policy?.diskUpgrade ?? '').toLowerCase();
    return ['os-standard-ssd', 'os', 'all'].includes(v) ? v : '';
  }
  /** PLAN-NOTES-RUNPAGE-1: the notes the plan wrote for one entry
   *  (planNotes), as text, in their order - every note, whatever it says, so
   *  a note the planner adds later shows with no change here. The wizard's
   *  Run it step and the acceptance on the Migrations page both read them
   *  by this rule. */
  function planNotesOf(entry) {
    return (Array.isArray(entry?.planNotes) ? entry.planNotes : []).filter(Boolean).map(String);
  }

  /* NO-POPUPS-1: the product opens no window, with ONE exception: a
   * Microsoft Learn page opens in a new tab, with noopener. An https address
   * whose host is exactly learn.microsoft.com. The pages that load this file
   * use this copy (the rebuild list's link to the patch orchestration modes);
   * assessment-report.js and docs/manual/index.js hold the same rule. */
  function isLearnLink(url) {
    try {
      const u = new URL(String(url ?? ''));
      return u.protocol === 'https:' && u.hostname === 'learn.microsoft.com';
    } catch (e) { return false; }
  }
  /* NO-POPUPS-1, the second exception: the Get help
   * menu's bug report and feature request open this product's GitHub issue
   * page in a new tab. Exactly that page: https, host github.com, the path
   * REPO + /issues/new, nothing else on GitHub. */
  function isIssueLink(url) {
    try {
      const u = new URL(String(url ?? ''));
      const want = new URL(REPO + '/issues/new');
      return u.protocol === 'https:' && u.hostname === want.hostname && u.port === '' &&
        u.username === '' && u.password === '' && u.pathname === want.pathname;
    } catch (e) { return false; }
  }
  /* WAVE-SAMPLE-RUN-1: the plan of the sample run, written ONCE.
   *
   * migrations.html?demo and waves.html?demo both open the run
   * pilot-rehearsal-sample, and the manual shows each page with it. Each page
   * kept a plan of its own: the Migrations page 12 machines in storefront-pilot
   * and billing-apps, the wave editor more than 60 other machines in four other
   * waves. So the picture of one page and the picture of the other showed two
   * migrations under one name. Both pages now read this plan, and
   * tests/js/wave-sample-run.test.js holds them to it.
   *
   * The Migrations page adds the documents of the run as it runs (state,
   * approvals, capacity); the wave editor shows the plan as it was before the
   * run started, so each of its controls can be shown. Names, ids and
   * addresses are placeholders. plan() gives a new copy each time: a page
   * changes the entries it shows.
   *
   * What each machine shows:
   *   - every Windows machine that goes from a SCSI temporary disk (D2ds_v4,
   *     D4ds_v4, E2bds_v5) to an NVMe one moves by the in-place upgrade
   *     (Preview): path A with the method preview, as New-VmfPlan records it.
   *     No machine is planned on path B (REBUILD-REMOVE-DOCS-1).
   *   - acceleratedNetworkingOutcome is the record the engine writes: turned
   *     on, not, or decided by the move (prd-lin-a) - WAVE-AN-NAMES-1.
   *   - prd-win-b keeps its own value of onDDataFound: a person decided
   *     Continue for it when Checking found files on its temporary disk. The
   *     wave editor names it under that setting, with Reset.
   *   - prd-lin-d moves, and is in no wave: a person took it out of its wave.
   *     The wave editor shows it on its left side. The Migrations page does
   *     not show it: no wave takes it, and it has no state (NOT-IN-WAVE-QUEUED-1).
   *   - old-enc-a is not moved (MANUAL), with the reason New-VmfPlan writes. */
  const sampleRun = (() => {
    const runId = 'pilot-rehearsal-sample';
    const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso-app/providers/Microsoft.Compute/virtualMachines/';
    const storefront = { service: 'storefront', owner: 'retail', env: 'prod' };
    const billing = { service: 'billing', owner: 'finance', env: 'prod' };
    const policy = (extra) => ({ requireApproval: true, onDDataFound: 'stop', onDriverBelowFloor: 'stop', keepSnapshotDays: 7, ...extra, targetGeneration: 'v6' });
    const reserved = (extra) => policy({ capacityGate: 'Reserved', ...extra });
    const preview = { option: 'v6', source: 'default', chosenBy: null, method: 'preview' };
    const at = (vm, wave, assessment, target, an, pol, more) => ({ vmId: SUB + vm, wave, path: 'A',
      assessment: { resourceGroup: 'rg-contoso-app', location: 'eastus2', ...assessment },
      target: { zone: null, ...target }, acceleratedNetworkingOutcome: { turnsOn: an, unknownWhy: an === null ? 'kernel' : null }, policy: pol, ...(more || {}) });
    const manaDownload = 'If the Windows driver store of this machine has no MANA driver, the move downloads one from download.microsoft.com. Make sure that the machine can connect to download.microsoft.com over HTTPS. If the download fails, the machine stops with the reason that the MANA driver could not be installed. It keeps its current size.';
    const plan = () => ({ schemaVersion: 1, entries: [
      at('can-win-a', 'storefront-pilot', { identityType: 'SystemAssigned', os: 'Windows', osVersion: '2022-datacenter-g2', sourceSize: 'Standard_D2ds_v4', tags: storefront },
        { size: 'Standard_D2ds_v6', choice: preview }, true, policy()),
      at('can-lin-a', 'storefront-pilot', { os: 'Linux', osVersion: '22_04-lts-gen2', sourceSize: 'Standard_D2s_v4', tags: storefront },
        { size: 'Standard_D2s_v6' }, false, policy()),
      at('can-lin-b', 'storefront-pilot', { os: 'Linux', osVersion: '15-sp5', sourceSize: 'Standard_D2s_v4', tags: storefront },
        { size: 'Standard_D2s_v6' }, false, policy()),
      at('prd-win-a', 'billing-apps', { os: 'Windows', osVersion: '2022-datacenter-g2', sourceSize: 'Standard_D2ds_v4', tags: billing },
        { size: 'Standard_D2ds_v6', choice: preview }, true, reserved()),
      at('prd-win-b', 'billing-apps', { os: 'Windows', osVersion: '2019-datacenter-g2', sourceSize: 'Standard_D2ds_v4', tags: billing },
        { size: 'Standard_D2ds_v6', choice: preview }, false, reserved({ onDDataFound: 'proceed' }),
        { planNotes: [manaDownload], decisions: [{ setting: 'onDDataFound', by: 'operator@example.com', utc: '2026-11-02T09:40:00Z' }] }),
      // An Intel machine keeps Intel: E2bds_v5 goes to E2bds_v6 (target-families.json, ebdsv6-series).
      at('prd-ebs-a', 'billing-apps', { identityType: 'SystemAssigned', os: 'Windows', osVersion: '2022-datacenter-g2', sourceSize: 'Standard_E2bds_v5', tags: billing },
        { size: 'Standard_E2bds_v6', choice: preview }, false, reserved({ diskUpgrade: 'os' })),
      at('prd-lin-a', 'billing-apps', { os: 'Linux', osVersion: '22_04-lts-gen2', sourceSize: 'Standard_D2s_v4', tags: billing },
        { size: 'Standard_D2s_v6' }, null, reserved()),
      at('prd-lin-b', 'billing-apps', { os: 'Linux', osVersion: 'rhel-9_4', sourceSize: 'Standard_D2s_v4', tags: billing },
        { size: 'Standard_D2s_v6' }, false, reserved()),
      at('prd-tf-a', 'billing-apps', { os: 'Linux', osVersion: '22_04-lts-gen2', sourceSize: 'Standard_D2s_v4', tags: billing },
        { size: 'Standard_D2s_v6' }, false, reserved()),
      at('prd-tmp-a', 'billing-apps', { os: 'Windows', osVersion: '2022-datacenter-g2', sourceSize: 'Standard_D4ds_v4', tags: billing },
        { size: 'Standard_D4ds_v6', choice: preview }, true, reserved()),
      at('prd-lin-c', 'billing-apps', { os: 'Linux', osVersion: '22_04-lts-gen2', sourceSize: 'Standard_D4s_v4', tags: billing },
        { size: 'Standard_D4s_v6' }, false, reserved()),
      // NOT-IN-WAVE-QUEUED-1: a person took this machine out of its wave
      // before the run. The wave editor lists it on its left side; the
      // Migrations page does not show it.
      at('prd-lin-d', 'unscheduled', { os: 'Linux', osVersion: '22_04-lts-gen2', sourceSize: 'Standard_D2s_v4', tags: billing },
        { size: 'Standard_D2s_v6' }, false, policy()),
      { vmId: SUB + 'old-enc-a', wave: 'unscheduled', path: 'MANUAL',
        assessment: { resourceGroup: 'rg-contoso-app', location: 'eastus2', os: 'Windows', osVersion: '2019-datacenter', sourceSize: 'Standard_D2ds_v4', tags: billing },
        target: { size: null, zone: null }, policy: {},
        // The reason New-VmfPlan writes (Resolve-VmfEntryTarget, disk-encryption-preview).
        planNotes: ['This machine uses Azure Disk Encryption, and its move to v5 changes the kind of temporary disk, which is the in-place upgrade (Preview). The product does not move an encrypted machine that way, so it does not move it.'] },
    ] });
    return Object.freeze({ runId, plan });
  })();

  window.VmfHelp = { isLearnLink, install, open, installNav, showSignIn, identity, explain, explainAction, claimBlocked, claimReservingStuck,
                   machineOutcome, outsideRun, runStage, outcomeWaitsOnPerson, machineStatus, outcomeCounts, machineName, machineNames, idKey, seriesLabel, machineStarted, machineAtWork, waveHold, leasesByMachine, approvalRequired, previewNames, signOffRiskLines, sqlTempdbRisk, sqlTempdbEntries, subscriptionOf, previewNeeds, anOutcomeRow, anOutcomeNames, diskUpgradeOf, keepDaysText,
                   runSummaryOf, runWaitingCount, runGateTag, runGroup, PROBLEM_STATES, RUN_ACTIVE_MS, RUN_GATE_WAITS,
                   myRoles, gateOnRole, watchRun, confirmInPlace, markBusy, drawWhenFree,
                   // PLAN-NOTES-RUNPAGE-1: the notes the plan wrote for a machine.
                   planNotesOf,
                   waveEstimate, WAVE_MAX_WORKERS,
                   waveAtOnce, atOnceChoice, WAVE_TIERS, WAVE_DEFAULT_WORKERS, WAVE_PER_CONTAINER,
                   // ACCEPT-FIRST-MACHINE-1: the settings of a wave, by one rule.
                   waveSettingDefaults, waveWideSettings, leverValue, ownDecision, keepsOwn, waveWideValue, waveCard, ownValueText, ownDecisionOf, dayText, ownCountText, ownRowText,
                   safetyCopyLedger, safetyCopySummary, nextRetentionPassUtc, retentionPassFacts, RETENTION_DEFAULT_DAYS,
                   storeUrl, storeList, storeBlob, mapLimited, readLimiter, STORE_READ_LIMIT, VmfRun, runFolderIsRun, runKind, waitingLine, waitingRow, MIGRATE_STEPS, stepRail,
                   // STORE-HOLDS-ONE-1: does a listing name a store file.
                   storeHolds,
                   // PAGE-LOAD-1: the documents a page draws, in one call.
                   storeDocs, heldList, heldJson, heldHas, heldText, STORE_DOCS_PAGES_MAX,
                   // PAGE-SCALE-OVERVIEW-1: the count tiles and the one list.
                   listMount, listTabsHtml, listView, countWords, listMatches, listDefaultTile, listRangeText, listHref, listSort, runTitle, agoText, LIST_PAGE_SIZE, LIST_LOOSE,
                   nextLogPart, readLogParts, readLogEvents, LOG_PARTS_MAX, waveOrder,
                   checkedConfig, tokenMayGoTo, claimRegionalShort,
                   // REGIONAL-QUOTA-REQUESTED-PAGE-1
                   claimRegionalRequested,
                   accountsAfterReturn, tokenOrRedirect, signInRedirect,
                   // DISCLAIMER-1: the short line, for the files a page writes.
                   disclaimerLine: TEXT.disclaimerLine,
                   // WAVE-SAMPLE-RUN-1: the plan of the sample run (?demo).
                   sampleRun };
})();
