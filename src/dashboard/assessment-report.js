/* Shared: what an assessment FOUND, rendered the same way everywhere.
 *
 * The wizard's review step said how many machines could and could not move,
 * and never why - so the only way to find out was to leave the process and
 * open the Assessments page.
 *
 * Right. The step says "somebody has to read this and accept it" and then
 * showed two numbers. You cannot review what you are not shown, and sending a
 * person out of the flow to find it - then back to approve - is the flow being
 * abandoned halfway.
 *
 * So the report lives HERE, once, and both the Assessments page and the wizard
 * draw the same thing. Not copied into the wizard: this codebase has paid
 * repeatedly for a second copy that drifts - two pages carrying partial blocker
 * wording, two guest scripts naming the same facts differently, two d-suffix
 * regexes. One renderer, two callers.
 *
 * The wording for each code comes from the ENGINE's own assessment-reasons.json,
 * copied to the dashboard at deploy time, so a blocker cannot mean one thing in
 * the engine and another on screen.
 */
(function () {
  'use strict';

  const esc = (v) => String(v ?? '').replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const vmName = (id) => String(id).split('/').pop();
  /* OUTPUT-ESCAPE-1: a link from the reasons file always opens an https page.
   * esc() keeps a quote from ending the attribute, but a javascript: address
   * passes it whole, so the address is built from https:// and the rest. */
  const httpsLink = (url) => `https://${String(url ?? '').trim().replace(/^https:\/\//i, '')}`;
  /* NO-POPUPS-1: the product opens no window, with ONE exception: a
   * Microsoft Learn page opens in a new tab, with noopener, so a person keeps
   * the page they read the finding on. An https address whose host is exactly
   * learn.microsoft.com; every other link opens in this tab. The same rule is
   * in docs/manual/index.html. */
  function isLearnLink(url) {
    try {
      const u = new URL(String(url ?? ''));
      return u.protocol === 'https:' && u.hostname === 'learn.microsoft.com';
    } catch (e) { return false; }
  }
  // Empty is a VALID state: the codes still render, which beats a page that
  // will not load because a data file is missing.
  // DETECT-PATTERNS-1: the warnings (the machine may still move) and the
  // names of the workload types come from the same file.
  const REASONS = { blockers: {}, prep: {}, warnings: {}, workloadTypes: {} };
  let loaded = false;

  async function loadReasons() {
    if (loaded) return REASONS;
    try {
      const r = await (await fetch('assessment-reasons.json')).json();
      REASONS.blockers = r.blockers ?? {};
      REASONS.prep = r.prep ?? {};
      REASONS.warnings = r.warnings ?? {};
      REASONS.workloadTypes = r.workloadTypes ?? {};
    } catch { /* codes still render */ }
    loaded = true;
    return REASONS;
  }

  const reasonOf = (code) => REASONS.blockers[code] || REASONS.prep[code] || REASONS.warnings[code] || null;

  // Grouped by REASON, not per machine: twelve machines blocked for one reason
  // is one piece of work, and reading it as twelve rows hides that. Biggest
  // first, because the reason holding back the most machines is the one worth
  // doing something about.
  // ALREADY-CURRENT-1: a machine on a Current size is in no finding - it is
  // not held back, has nothing to prepare and nothing to check. Its scan can
  // still carry codes (a machine the product rebuilt has no image record, so
  // it reads as a custom image), and they said Cannot yet in red.
  function groupByCode(vms, field) {
    const groups = new Map();
    for (const v of vms) {
      if (isCurrent(v)) continue;
      for (const code of (v[field] ?? [])) {
        if (!groups.has(code)) groups.set(code, []);
        groups.get(code).push(v.name || vmName(v.vmId));
      }
    }
    return [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
  }

  const T = {
    whatToDo: 'What to do:',
    oneMachine: '1 machine',
    someMachines: ' machines',
    noWording: 'No explanation is recorded for this one.',
    // GEN-V5-1: which size series a finding holds a machine back from.
    seriesOnly: 'This applies to {series} only.',
    seriesNotV5: 'This applies to {series} only. A move to v5 does not need this.',
    showAllNames: 'Show all {n} machines',
    showFewerNames: 'Show fewer',
    holdingBack: 'What is holding machines back',
    limitsTarget: 'What limits the target',
    nothingBlocked: 'No finding stops a machine.',
    beforeTheyMove: 'Preparation for the move',
    notEligible: 'Not eligible',
    notEligibleWhy: 'The product does not move these machines. Another Azure service manages them, or they are outside the scope of this tool.',
    nothingFound: 'This scan found no machines.',
    // ALREADY-CURRENT-1: the group name and the line for a machine on a Current size.
    grpCurrent: 'Current',
    currentLine: '{size} is in the Current lifecycle stage.',
    couldNotRead: 'What this scan could not read',
    couldNotReadWhy: 'The scan finished without these. Everything else here is not affected.',
    notReadUnknown: 'The scan could not read this: {subject}',
    // SCAN-PARTIAL-SUBS-1: a subscription whose sizes were not read - which,
    // why (Azure's words) and how to fix it. The report says the same
    // (ConvertTo-VmfNotReadReportHtml).
    couldNotReadWhyHeld: 'The scan finished without these. The machines of a subscription in this list are held until a new assessment reads it.',
    sizesWhere: 'Sizes in {location} for subscription {subscription}.',
    sizesHeldOne: '1 machine is held.',
    sizesHeldMany: '{n} machines are held.',
    sizesSaid: 'Azure said: {said}',
    sizesFixPermission: 'Azure refused the read. On the Admin page, give the product Assess access to this subscription. Its {role} role holds {action}. Then start a new assessment.',
    sizesFixNotFound: 'Azure cannot find this subscription. Make sure that it exists and that the product has access to it on the Admin page. Then start a new assessment.',
    sizesFixOther: 'The product tried the read again if the failure was temporary. Read what Azure said and correct the cause. Then start a new assessment.',
    // DETECT-PATTERNS-1: the warnings, and the workload type of each machine.
    checkFirst: 'What to check before the move',
    checkFirstWhy: 'These machines can still move. Check the thing that each finding names before the migration starts.',
    workloadTypes: 'Workload types',
    workloadTypesWhy: 'The type tells you how a machine moves. The facts column shows the Azure field and the value that decided it.',
    workloadFilter: 'Show',
    workloadAll: 'All workload types',
    colMachine: 'Machine',
    colWorkload: 'Workload type',
    colFacts: 'Facts from Azure',
    typeNotChecked: 'Type not checked',
    noFacts: 'No fact in Azure shows another workload type.',
    notReadValue: 'not read',
  };

  /* REPORT-GAP-1: the page supplies the words, the engine supplies the KEY.
   *
   * A scan that carries on with less than it asked for is correct - it must
   * not guess. What was wrong is that it then said nothing, so a customer read
   * an assessment with a subject missing and no way to know it was missing.
   *
   * Keyed, not copied from the engine's sentence: the run log says "could not
   * read accelerated-networking state for the network interfaces (...)", which
   * is written for somebody reading a log. This is written for somebody
   * reading a report about their own estate. */
  const NOT_READ_WORDS = {
    acceleratedNetworking: 'Accelerated networking. This report does not say whether it is on for any machine.',
    // CLUSTER-DETECT-1: the facts that show that a machine may be a cluster node.
    clusterHints: 'Cluster hints. This report does not say whether a machine may be a cluster node, so no machine is called standalone.',
  };

  /* The cards carry their OWN styling, injected once.
   *
   * They used to borrow each page's `.card`/`.cardbody`. That looked right on
   * the Assessments page and wrong in the wizard, which has `.card` but no
   * `.cardbody` - so every finding ran edge to edge with no padding, which is
   * the exact complaint that started this ("poor format"). A shared renderer
   * that depends on the caller's stylesheet is not shared. */
  const REPORT_CSS = `
    .vmf-finding{margin:10px 0;border:1px solid var(--line,#e7ebf2);border-radius:12px;
      background:var(--card,#fff);}
    .vmf-finding-body{padding:12px 14px;}
    /* The wizard's review step has no h4 style of its own, so the report
       brings one. */
    h4.vmf-finding-heading{font-size:12px;text-transform:uppercase;letter-spacing:.5px;
      color:var(--muted,#667085);margin:22px 0 8px;font-weight:600;}
    .vmf-finding-head{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:baseline;}
    /* The wording was long and gave no route to Microsoft's own page. A
       blocker says a machine cannot move; the next thing a person needs is
       Microsoft's own page saying why. */
    /* No pseudo-element arrow here: U+2197 renders as a missing-glyph box in
       the default Windows UI font, and a broken character beside a link reads
       as a fault in the page. */
    .vmf-finding .vmf-doclink{font-size:13px;color:var(--brand,#2563eb);text-decoration:none;
      display:inline-block;}
    .vmf-finding .vmf-doclink:hover{text-decoration:underline;}
    .vmf-finding .vmf-names{margin-top:8px;font-size:12px;overflow-wrap:anywhere;
      font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted,#667085);}
    /* VMNAMES-1: one chip per machine. Twenty names joined by commas is a
       wall, and the reader's job here is to find THEIR machine in it. */
    .vmf-chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px;}
    /* THE TEXT COLOUR IS --ink. The theme has no --text, so naming that one
       fell through to the light-mode fallback and drew near-black names on
       the dark card - invisible, and no error anywhere. Found by looking at
       the page rather than at the file. The fallback is the same colour the
       variable holds in the light theme, so a missing stylesheet still reads.
       --mono for the same reason: the theme owns the typeface.
       NO BACKTICKS IN HERE. This block is inside a template literal, so the
       first one ENDS it and what follows is read as JavaScript: quoting the
       variable names here broke the whole file, and the error named a postfix
       operation on a line that has none. */
    .vmf-chip{font-size:12px;line-height:1.2;padding:4px 9px;border-radius:7px;
      border:1px solid var(--line,#e7ebf2);background:var(--card-2,#f6f8fb);
      color:var(--ink,#101828);
      font-family:var(--mono,ui-monospace,SFMono-Regular,Menlo,monospace);white-space:nowrap;}
    .vmf-chip-more{cursor:pointer;color:var(--brand,#2563eb);background:transparent;
      border-style:dashed;font-family:inherit;}
    /* The wrapper holding the chips past the limit takes no part in the
       layout, so they are flex items of the same row. The [hidden] rule has
       to be here and more specific, because an element's own display beats
       the browser's hidden. */
    .vmf-chips-rest{display:contents;}
    .vmf-chips-rest[hidden]{display:none;}
  `;
  let styled = false;
  function ensureStyles() {
    if (styled) return;
    const el = document.createElement('style');
    el.textContent = REPORT_CSS;
    document.head.appendChild(el);
    styled = true;
    wireNames();
    wireWorkloadFilter();
  }

  /* VMNAMES-1: the machines a finding applies to, as chips.
   *
   * Past this many, the card is longer than the reason it is explaining, and
   * five findings over an estate make a page of names. The rest are still
   * THERE - the control opens them, and closes them again, which is the rule
   * about anything that opens offering a way back. One button with two states
   * is the cheapest shape that obeys it.
   *
   * The button carries the names itself rather than the page keeping a record
   * of which cards are open: this renderer is called fresh by two pages and
   * holds no state of its own. */
  const NAME_LIMIT = 12;

  function chip(name) { return `<span class="vmf-chip">${esc(name)}</span>`; }

  function chipList(names) {
    const shown = names.slice(0, NAME_LIMIT).map(chip).join('');
    if (names.length <= NAME_LIMIT) { return `<div class="vmf-chips">${shown}</div>`; }
    const rest = names.slice(NAME_LIMIT).map(chip).join('');
    const more = esc(T.showAllNames.replace('{n}', String(names.length)));
    // The hidden ones sit in a wrapper that LAYS OUT AS IF IT WERE NOT THERE
    // (display:contents), so the chips inside it are flex items of the same
    // row as the first twelve rather than one box holding a second list.
    return `<div class="vmf-chips" data-names>${shown}` +
      `<span class="vmf-chips-rest" data-more hidden>${rest}</span>` +
      `<button type="button" class="vmf-chip vmf-chip-more" data-show-names ` +
      `data-more-label="${more}" data-less-label="${esc(T.showFewerNames)}">${more}</button>` +
      `</div>`;
  }

  /* The one listener, on the document, for every card both pages ever draw.
   * A listener per card would have to be re-attached on every render, and the
   * render is the thing this file does not control. */
  let wired = false;
  function wireNames() {
    if (wired || typeof document === 'undefined') { return; }
    wired = true;
    document.addEventListener('click', (ev) => {
      const btn = ev.target.closest && ev.target.closest('[data-show-names]');
      if (!btn) { return; }
      const box = btn.parentElement;
      const rest = box && box.querySelector('[data-more]');
      if (!rest) { return; }
      const opening = rest.hidden;
      rest.hidden = !opening;
      btn.textContent = opening ? btn.dataset.lessLabel : btn.dataset.moreLabel;
    });
  }

  // GEN-V5-1: the engine's reason names the size series it applies to
  // (appliesTo). Said on the card, because "Generation 1 machine" blocks v6
  // and v7 and not v5 - and a person choosing a wave's series needs to know.
  // Nothing is said for a reason that applies to every series, or that
  // records none.
  function seriesLine(appliesTo) {
    const set = Array.isArray(appliesTo) ? appliesTo.filter(Boolean) : [];
    if (!set.length || ['v5', 'v6', 'v7'].every(s => set.includes(s))) return '';
    const text = set.includes('v5') ? T.seriesOnly : T.seriesNotV5;
    return text.replace('{series}', set.join(' and '));
  }

  function reasonCard(code, names, tone, notes) {
    ensureStyles();
    const r = reasonOf(code);
    const count = names.length === 1 ? T.oneMachine : names.length + T.someMachines;
    // A note per machine, when the finding has one to give. IDENTITY-4 took
    // the object form away with the "Where is it used?" control: a note is a
    // string or it is nothing.
    const nameLines = notes
      ? names.map(n => `<div class="vmf-names" data-machine-line="${esc(n)}"><b>${esc(n)}</b> - ${esc(notes[n] || '')}</div>`).join('')
      // VMNAMES-1. The note form stays a line per machine - each one carries a
      // sentence, which is not a chip.
      : chipList(names);
    return `<div class="vmf-finding"><div class="vmf-finding-body">
      <div class="vmf-finding-head">
        <b>${esc(r ? r.title : code)}</b><span class="pill ${tone}">${esc(count)}</span>
      </div>
      <div class="muted" style="margin-top:6px">${esc(r ? r.meaning : T.noWording)}</div>
      ${r && seriesLine(r.appliesTo) ? `<div style="margin-top:6px"><b>${esc(seriesLine(r.appliesTo))}</b></div>` : ''}
      ${r && r.whatToDo ? `<div style="margin-top:8px"><b>${esc(T.whatToDo)}</b> ${esc(r.whatToDo)}</div>` : ''}
      ${r && r.docs && r.docs.url ? `<div style="margin-top:8px"><a class="vmf-doclink" ${isLearnLink(httpsLink(r.docs.url)) ? 'target="_blank" rel="noopener noreferrer"' : 'rel="noreferrer"'}
        href="${esc(httpsLink(r.docs.url))}">${esc(r.docs.label || r.docs.url)}</a></div>` : ''}
      ${nameLines}
    </div></div>`;
  }

  /* SERIES-COUNT-1: a machine can migrate when at least one size series is
   * still open to it. The scan says "Blocked" once, for every series, so a
   * Generation 1 machine - blocked for v6 and v7, ready for v5 - was counted
   * as "cannot yet" and drawn in red. Each blocker names the series it applies
   * to (appliesTo); a code this page does not know applies to every series, the
   * same rule as the run page's judgeForSeries and the engine's
   * Resolve-VmfEntryClassification. */
  const SERIES = ['v5', 'v6', 'v7'];
  function blockerSeries(code) {
    const r = REASONS.blockers[code];
    return (r && Array.isArray(r.appliesTo) && r.appliesTo.length) ? r.appliesTo : SERIES;
  }
  /* ALREADY-CURRENT-1: a machine whose CURRENT size
   * Microsoft puts in the Current lifecycle stage (today v6 and v7) is in the
   * group Current. Not red, not in the Cannot yet count, and not selectable.
   * The stage is the scan's (sourceLifecycle, assessment v10), read from the
   * lifecycle data by Get-VmfSizeLifecycleStage - never from the size name. A
   * size the data does not hold has no stage, and is never Current. A
   * machine that is not eligible stays Not eligible. The run page holds the
   * same rule (foundCurrent in migrations.js), held to the same fixture. */
  function isCurrent(vm) {
    return Boolean(vm) && vm.classification !== 'Excluded' && !vm.platformManaged &&
      String(vm.sourceLifecycle?.stage ?? '') === 'Current';
  }
  function currentLine(vm) { return T.currentLine.replace('{size}', String(vm?.sourceSize ?? '')); }
  function openSeries(vm) {
    if (!vm || vm.classification === 'Excluded' || vm.platformManaged || isCurrent(vm)) return [];
    const b = (vm.blockers ?? []).filter(Boolean);
    return SERIES.filter(s => !b.some(c => blockerSeries(c).includes(s)));
  }
  function canMigrate(vm) { return openSeries(vm).length > 0; }
  /* ASSESS-COUNT-1: every count of can / cannot yet, on every page, from this
   * one rule. The Assessments list counted the scan's "Blocked" (and Excluded)
   * as "cannot yet" after SERIES-COUNT-1 taught the report beside it better,
   * so the list said 3 where its own report said 0. Every machine is counted
   * once: ready (a series is open), cannot yet, or excluded. */
  function migrateCounts(vms) {
    const list = Array.isArray(vms) ? vms : [];
    const out = { ready: 0, cannotYet: 0, someTargets: 0, excluded: 0, current: 0 };
    for (const v of list) {
      if (!v || v.classification === 'Excluded' || v.platformManaged) { out.excluded++; continue; }
      if (isCurrent(v)) { out.current++; continue; }
      if (canMigrate(v)) {
        out.ready++;
        if (v.classification === 'Blocked') { out.someTargets++; }
      } else { out.cannotYet++; }
    }
    return out;
  }
  /* ALREADY-CURRENT-1: the group of one machine, by the rule every count
   * uses - excluded, current, can, some or cannot - and the line its row
   * shows: the Current line, or for a machine that cannot yet move, the
   * titles of its findings (lab finding 81: the row said Cannot yet and no
   * reason). Empty for every other group. */
  function machineGroup(vm) {
    if (!vm || vm.classification === 'Excluded' || vm.platformManaged) return 'excluded';
    if (isCurrent(vm)) return 'current';
    if (!canMigrate(vm)) return 'cannot';
    return vm.classification === 'Blocked' ? 'some' : 'can';
  }
  function machineWhy(vm) {
    const g = machineGroup(vm);
    if (g === 'current') return currentLine(vm);
    if (g !== 'cannot') return '';
    return [...new Set((vm.blockers ?? []).filter(Boolean).map(c => (reasonOf(c) || {}).title || String(c)))].join('; ');
  }
  /* The Current group in a report: one line for each machine, in the approved
   * words. Empty when no machine is Current. Grey, never red. */
  function currentHtml(vms) {
    const list = (vms ?? []).filter(isCurrent);
    if (!list.length) return '';
    ensureStyles();
    return `<h4 class="vmf-finding-heading">${esc(T.grpCurrent)}</h4><div class="vmf-finding" data-current-group><div class="vmf-finding-body">
      <div class="vmf-finding-head"><b>${esc(T.grpCurrent)}</b><span class="pill quiet">${esc(list.length === 1 ? T.oneMachine : list.length + T.someMachines)}</span></div>
      ${list.map(v => `<div class="vmf-names" data-machine-line="${esc(v.name || vmName(v.vmId))}"><b>${esc(v.name || vmName(v.vmId))}</b> - ${esc(currentLine(v))}</div>`).join('')}
    </div></div>`;
  }
  /** Blocker groups split: those that stop a machine on every series, and those that close only some. */
  function splitBlockers(vms) {
    const all = groupByCode(vms, 'blockers');
    const everywhere = (code) => SERIES.every(s => blockerSeries(code).includes(s));
    return { stops: all.filter(([c]) => everywhere(c)), limits: all.filter(([c]) => !everywhere(c)) };
  }

  /* The findings, as HTML. `opts.showPrep` includes what has to happen before
   * ready machines can move - useful in the wizard, where the next thing the
   * person does is plan; the Assessments page has its own layout for it. */
  function findingsHtml(vms, opts) {
    const o = opts || {};
    if (!vms || !vms.length) return `<p class="muted">${esc(T.nothingFound)}</p>`;

    const { stops, limits } = splitBlockers(vms);
    const excluded = vms.filter(v => v.classification === 'Excluded')
      .map(v => v.name || vmName(v.vmId));

    ensureStyles();
    const h4 = (t) => `<h4 class="vmf-finding-heading">${esc(t)}</h4>`;
    let html = h4(T.holdingBack);
    html += stops.length
      ? stops.map(([code, names]) => reasonCard(code, names, 'bad')).join('')
      : `<p class="muted">${esc(T.nothingBlocked)}</p>`;
    // SERIES-COUNT-1: a reason that closes only some targets is not red.
    if (limits.length) {
      html += h4(T.limitsTarget) + limits.map(([code, names]) => reasonCard(code, names, 'warn')).join('');
    }
    // ALREADY-CURRENT-1: the machines on a Current size, each with its line.
    html += currentHtml(vms);

    // DETECT-PATTERNS-1: what to check before the move - the machine may still move.
    html += warningsHtml(vms);

    if (o.showPrep) {
      const prep = groupByCode(vms, 'prepNeeded');
      if (prep.length) {
        html += h4(T.beforeTheyMove);
        // IDENTITY-4: this finding used to carry a per-machine note listing
        // what each identity could reach. Every machine now says the same
        // thing - the reason's own words - because the product does not
        // research the customer's estate for them.
        html += prep.map(([code, names]) => reasonCard(code, names, 'warn')).join('');
      }
    }

    if (excluded.length) {
      // Platform-managed machines are not a problem to solve - they are out of
      // scope by design, and saying so stops somebody chasing them.
      html += h4(T.notEligible) + `<div class="vmf-finding"><div class="vmf-finding-body">
        <div class="muted">${esc(T.notEligibleWhy)}</div>
        ${chipList(excluded)}
      </div></div>`;
    }
    return html;
  }


  /* DETECT-PATTERNS-1: what a person checks before the move. The machine may
   * still move - a single SQL Server machine, or a workload type the scan
   * could not check - so these are neither red nor "handled for you".
   * Empty string when no machine has one. */
  function warningsHtml(vms) {
    const groups = groupByCode(vms ?? [], 'warnings');
    if (!groups.length) { return ''; }
    ensureStyles();
    return `<h4 class="vmf-finding-heading">${esc(T.checkFirst)}</h4>` +
      `<p class="muted" style="margin:0 0 8px">${esc(T.checkFirstWhy)}</p>` +
      groups.map(([code, names]) => reasonCard(code, names, 'warn')).join('');
  }

  /* DETECT-PATTERNS-1: the workload type of one machine, by its name. An
   * assessment made before the type existed has none: not checked, never a
   * standalone machine. */
  function workloadType(vm) {
    const t = vm && vm.workload && vm.workload.type;
    return t ? String(t) : 'not-checked';
  }
  function workloadTitle(type) {
    const r = Object.prototype.hasOwnProperty.call(REASONS.workloadTypes, type) ? REASONS.workloadTypes[type] : null;
    if (r && r.title) { return r.title; }
    return type === 'not-checked' ? T.typeNotChecked : type;
  }
  /* The facts that decided it: Azure's field and the value, as Azure gives
   * them. A fact the scan could not read says so. */
  function evidenceText(vm) {
    const ev = (vm && vm.workload && Array.isArray(vm.workload.evidence)) ? vm.workload.evidence : [];
    if (!ev.length) { return workloadType(vm) === 'standalone-vm' ? T.noFacts : ''; }
    return ev.map(e => `${e.field}: ${e.value === null || e.value === undefined ? T.notReadValue : e.value}`).join('; ');
  }

  const hasEvidence = (vm) => Boolean(vm && vm.workload && Array.isArray(vm.workload.evidence) && vm.workload.evidence.length);

  /* The filter: one option per type the machines have, in the order of the
   * engine's list, each with its count. `selected` '' shows every type. */
  function workloadFilterHtml(vms, selected, id) {
    const list = vms ?? [];
    const counts = new Map();
    for (const v of list) { const t = workloadType(v); counts.set(t, (counts.get(t) || 0) + 1); }
    const order = Object.keys(REASONS.workloadTypes);
    const types = [...counts.keys()].sort((a, b) => {
      const ia = order.indexOf(a), ib = order.indexOf(b);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    });
    const opt = (value, label) => `<option value="${esc(value)}"${value === (selected || '') ? ' selected' : ''}>${esc(label)}</option>`;
    return `<label class="muted" for="${esc(id)}" style="margin-right:6px">${esc(T.workloadFilter)}</label>` +
      `<select id="${esc(id)}" data-workload-filter>` + opt('', `${T.workloadAll} (${list.length})`) +
      types.map(t => opt(t, `${workloadTitle(t)} (${counts.get(t)})`)).join('') + `</select>`;
  }

  /* The workload types, one row per machine, with the filter. The filter
   * hides rows on this page; nothing is reloaded and nothing is saved. */
  function workloadTableHtml(vms) {
    const list = vms ?? [];
    if (!list.length) { return ''; }
    ensureStyles();
    const rows = list.map(v => `<tr data-workload-type="${esc(workloadType(v))}">` +
      `<td class="mono" style="white-space:nowrap">${esc(v.name || vmName(v.vmId))}</td><td>${esc(workloadTitle(workloadType(v)))}</td>` +
      // A machine with no fact gets a sentence, which is not code.
      `<td${hasEvidence(v) ? ' class="mono"' : ' class="muted"'} style="overflow-wrap:anywhere">${esc(evidenceText(v))}</td></tr>`).join('');
    return `<h4 class="vmf-finding-heading" data-workload-heading>${esc(T.workloadTypes)}</h4>` +
      `<p class="muted" style="margin:0 0 8px">${esc(T.workloadTypesWhy)}</p>` +
      `<div style="margin:0 0 8px">${workloadFilterHtml(list, '', 'vmf-workload-filter')}</div>` +
      `<table data-workload-table><thead><tr><th>${esc(T.colMachine)}</th><th>${esc(T.colWorkload)}</th><th>${esc(T.colFacts)}</th></tr></thead>` +
      `<tbody>${rows}</tbody></table>`;
  }
  /* One listener on the document, as for the names, because this renderer
   * does not own the page. A row whose type is not the one chosen is hidden. */
  function filterWorkloadRows(select) {
    const table = select && select.closest && select.closest('div') && select.closest('div').nextElementSibling;
    if (!table || !table.hasAttribute || !table.hasAttribute('data-workload-table')) { return; }
    const want = select.value;
    table.querySelectorAll('tr[data-workload-type]').forEach(tr => {
      tr.hidden = Boolean(want) && tr.getAttribute('data-workload-type') !== want;
    });
  }
  let filterWired = false;
  function wireWorkloadFilter() {
    if (filterWired || typeof document === 'undefined') { return; }
    filterWired = true;
    document.addEventListener('change', (ev) => {
      const sel = ev.target;
      if (sel && sel.matches && sel.matches('select[data-workload-filter]') && sel.id === 'vmf-workload-filter') { filterWorkloadRows(sel); }
    });
  }

  /* What the scan asked for and did not get. Empty string when it got
   * everything, so a caller can drop it into a page unconditionally. */
  /* SCAN-PARTIAL-SUBS-1: one subscription and region whose size list the
   * scan could not read. Azure's own words are shown (escaped): the row
   * says WHY it failed and HOW to fix it, and the role and the action
   * come from the engine's permission map, never from this page. */
  function sizesNotReadHtml(x) {
    const n = Number(x.machineCount) || 0;
    // The engine puts Azure's code in front of its words, so the code is said once.
    const code = String(x.errorCode ?? ''); const detail = String(x.detail ?? '');
    const said = code && detail && !detail.includes(code) ? `${code} - ${detail}` : (detail || code);
    const fix = x.reason === 'permission'
      ? T.sizesFixPermission.replace('{role}', String(x.requiredRole ?? '')).replace('{action}', String(x.requiredAction ?? ''))
      : x.reason === 'subscriptionNotFound' ? T.sizesFixNotFound : T.sizesFixOther;
    const where = T.sizesWhere.replace('{location}', String(x.location ?? '')).replace('{subscription}', String(x.subscriptionId ?? ''));
    const held = n === 1 ? T.sizesHeldOne : T.sizesHeldMany.replace('{n}', String(n));
    return `<div class="vmf-finding"><div class="vmf-finding-body"><b>${esc(where)}</b> ${esc(held)}` +
      (said ? `<div style="margin-top:6px">${esc(T.sizesSaid.replace('{said}', said))}</div>` : '') +
      `<div style="margin-top:6px">${esc(fix)}</div></div></div>`;
  }

  function notReadHtml(notRead) {
    const items = (notRead ?? []).filter(x => x && x.subject);
    if (!items.length) { return ''; }
    ensureStyles();
    const held = items.some(x => String(x.subject) === 'sizes');
    const rows = items.map((x) => {
      const key = String(x.subject);
      if (key === 'sizes') { return sizesNotReadHtml(x); }
      // hasOwnProperty, not a bare lookup: a subject called `constructor` or
      // `__proto__` would otherwise return something from the prototype and
      // render a function into the page.
      const words = Object.prototype.hasOwnProperty.call(NOT_READ_WORDS, key)
        ? NOT_READ_WORDS[key]
        : T.notReadUnknown.replace('{subject}', key);
      return `<div class="vmf-finding"><div class="vmf-finding-body">${esc(words)}</div></div>`;
    }).join('');
    return `<h4 class="vmf-finding-heading">${esc(T.couldNotRead)}</h4>` +
      `<p class="muted" style="margin:0 0 8px">${esc(held ? T.couldNotReadWhyHeld : T.couldNotReadWhy)}</p>${rows}`;
  }

  /* THE SIDE PANEL, shared, matching the machine breakout on the migrations
   * page - the one where a put-back can be started.
   *
   * The run page has had this since RUN-LIFECYCLE-1 - a panel that slides in
   * from the right, contained and scrollable - and the Assessments page grew an
   * inline expanding ROW instead, which pushed the table around and ran the
   * cards edge to edge. Same product, two ideas of what "show me the detail"
   * looks like.
   *
   * Defined once here, styles included, so a third page cannot invent a third.
   */
  const PANEL_CSS = `
    #vmf-panel{position:fixed;inset:0 0 0 auto;width:min(620px,94vw);background:var(--card);
      border-left:1px solid var(--line);box-shadow:-12px 0 32px rgba(16,24,40,.18);
      padding:22px 24px;overflow-y:auto;z-index:10;transform:translateX(102%);
      transition:transform .18s ease;visibility:hidden;}
    #vmf-panel.open{transform:none;visibility:visible;}
    @media(prefers-reduced-motion:reduce){#vmf-panel{transition:none;}}
    #vmf-panel .close{float:right;cursor:pointer;border:none;background:#eef1f6;border-radius:8px;
      width:30px;height:30px;font-size:16px;color:var(--muted);}
    #vmf-panel h3{margin:0 0 2px;font-size:17px;}
    #vmf-panel h4{font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--muted);
      margin:22px 0 8px;}
    /* Cards inside the panel sit INSIDE it - the inline version ran them to the
       edge and clipped the machine names. */
    #vmf-panel .card{margin:10px 0;border:1px solid var(--line);border-radius:12px;background:var(--card);}
    #vmf-panel .card .cardbody{padding:12px 14px;}
    #vmf-panel .mono{overflow-wrap:anywhere;}
  `;

  function ensurePanel() {
    let el = document.getElementById('vmf-panel');
    if (el) return el;
    const style = document.createElement('style');
    style.textContent = PANEL_CSS;
    document.head.appendChild(style);
    el = document.createElement('aside');
    el.id = 'vmf-panel';
    el.setAttribute('aria-label', 'Detail');
    el.innerHTML = '<button class="close" type="button" aria-label="Close">&times;</button><div id="vmf-panel-body"></div>';
    el.querySelector('.close').addEventListener('click', closePanel);
    document.body.appendChild(el);
    // Escape closes it, like any panel a person expects to be able to dismiss.
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePanel(); });
    return el;
  }

  function openPanel(html) {
    const el = ensurePanel();
    el.querySelector('#vmf-panel-body').innerHTML = html;
    el.classList.add('open');
    el.scrollTop = 0;
    return el;
  }
  function closePanel() {
    const el = document.getElementById('vmf-panel');
    if (el) el.classList.remove('open');
    document.querySelectorAll('button.chev[aria-expanded="true"]').forEach(c => {
      c.innerHTML = '&rsaquo;'; c.setAttribute('aria-expanded', 'false');
    });
  }

  /* IDENTITY-4, 2026-09-11: the "Where is it used?" control WAS HERE - five
   * reads with the signed-in person's own tokens, answering what a machine's
   * system-assigned identity could reach.
   *
   * The product makes no research or statements about what a rebuilt
   * system-assigned identity reached. It states the risk and asks the customer
   * to approve it, after their own analysis.
   *
   * The control could not answer its own question, and said so: its closing
   * sentence told the reader that a runbook, a pipeline or a linked service
   * holding the client id was invisible to every check it had just run. A
   * panel whose last line concedes it cannot answer what it exists to answer
   * is the wrong panel.
   *
   * What the product does instead: it detects the identity, says plainly that
   * a rebuild destroys it, parks the machine, and an approver accepts that
   * after the CUSTOMER's analysis (DECIDE-1). The account destroyed is
   * recorded and shown in the run report (IDENTITY-4).
   *
   * Removed with it: the AuditLog.Read.All opt-in and its whole apparatus.
   */

  // VMNAMES-1: `chipList` is exported because the Assessments page draws the
  // platform-managed list itself, in its own layout. It was a copy of this
  // file's block, comment and all, down to the joined string - so the report
  // read as chips in the wizard and as a run-on line one page away. A second
  // copy that drifts is the thing this file exists to stop.
  window.VmfReport = { loadReasons, groupByCode, reasonCard, reasonOf, chipList, findingsHtml, canMigrate, migrateCounts, openSeries, splitBlockers, isCurrent, machineGroup, machineWhy, currentHtml, notReadHtml, openPanel, closePanel, REASONS, NOT_READ_WORDS, TEXT: T,
    warningsHtml, workloadType, workloadTitle, evidenceText, workloadFilterHtml, workloadTableHtml, filterWorkloadRows };

})();
