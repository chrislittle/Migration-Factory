// The diagrams: a ```mermaid block becomes a <div class="mermaid">, and
// mermaid draws it after each page renders. Written here rather than
// taken from a plugin, because the published plugin calls an entry point
// mermaid 11 no longer has.
// The dashboard's own palette (src/dashboard/app.css), so a diagram
// looks like the product it describes rather than like a default.
mermaid.initialize({
  startOnLoad: false, securityLevel: 'strict', theme: 'base',
  themeVariables: {
    fontFamily: "'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, Helvetica, Arial, sans-serif",
    fontSize: '14px',
    primaryColor: '#dae2eb', primaryTextColor: '#2d2d2d', primaryBorderColor: '#446e9b',
    secondaryColor: '#ffffff', secondaryBorderColor: '#446e9b', secondaryTextColor: '#2d2d2d',
    tertiaryColor: '#f8f9fa', tertiaryBorderColor: '#dee2e6', tertiaryTextColor: '#495057',
    lineColor: '#446e9b', textColor: '#495057',
    clusterBkg: '#f8f9fa', clusterBorder: '#dee2e6', titleColor: '#2d2d2d',
    edgeLabelBackground: '#ffffff',
    actorBkg: '#dae2eb', actorBorder: '#446e9b', actorTextColor: '#2d2d2d', actorLineColor: '#dee2e6',
    signalColor: '#446e9b', signalTextColor: '#495057',
    labelBoxBkgColor: '#ffffff', labelBoxBorderColor: '#446e9b', labelTextColor: '#2d2d2d',
    noteBkgColor: '#f6e3cc', noteBorderColor: '#ac5f00', noteTextColor: '#552f00',
    activationBkgColor: '#dae2eb', activationBorderColor: '#446e9b',
    sequenceNumberColor: '#ffffff',
  },
  flowchart: { padding: 12, nodeSpacing: 40, rankSpacing: 50, curve: 'basis' },
  sequence: { actorMargin: 60, messageMargin: 40, mirrorActors: false },
});
const escapeHtml = (s) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// NO-POPUPS-1: the dashboard opens the manual in its own tab, never a new
// one, because the product opens no popup. So the manual offers the way
// back (rule 11): a link on every page, and Escape.
// `from` is the dashboard page and its query; anything else - another
// site, a path, a script address - goes to the start page instead.
function manualBackHref(search) {
  let from = '';
  try { from = new URLSearchParams(search || '').get('from') || ''; } catch (e) { from = ''; }
  return /^[a-z][a-z0-9-]*\.html(?:\?[^#]*)?$/i.test(from) ? '../' + from : '../index.html';
}
// Escape is the search field's while a person types in it, and a zoomed
// picture's while one is open (the zoom closes on the same key).
function escapeLeaves(e, doc) {
  if (e.key !== 'Escape' || e.defaultPrevented) { return false; }
  const t = e.target || {};
  if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || '')) { return false; }
  return !doc.querySelector('.medium-zoom--opened, .medium-zoom-image--opened');
}
// The one exception: a Microsoft Learn page opens in a new tab, with
// noopener, so the reader keeps the page of the manual. An https address
// whose host is exactly learn.microsoft.com. Every other link to another
// site opens in this tab (externalLinkTarget below). The same rule is in
// src/dashboard/assessment-report.js.
function isLearnLink(url) {
  try {
    const u = new URL(String(url ?? ''));
    return u.protocol === 'https:' && u.hostname === 'learn.microsoft.com';
  } catch (e) { return false; }
}
function learnLinksInNewTab(root) {
  root.querySelectorAll('a[href]').forEach(function (a) {
    if (isLearnLink(a.href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
  });
}
window.$docsify = {
  // BRAND-1: the mark and the name, the same lockup the dashboard wears.
  // docsify puts this inside the sidebar's <h1><a>, as HTML. The mark is
  // mark.svg used as a CSS mask, so it is painted in the banner's own
  // colour - one drawing, and the manual keeps its copy beside it because
  // a manual that needs another folder to render is not self-contained.
  name: '<span class="m-logo" aria-hidden="true"></span>' +
        '<span class="m-name"><span class="m-title">' +
        '<span class="b-1">Migration</span><span class="b-2">Factory</span></span>' +
        '<span class="m-sub">Manual</span></span>',
  repo: '',
  loadSidebar: true,
  // One sidebar for the whole manual: without this, docsify asks for a
  // _sidebar.md in every folder and logs a 404 for each.
  alias: { '/.*/_sidebar.md': '/_sidebar.md' },
  subMaxLevel: 2,
  auto2top: true,
  // Links and pictures in a page are written relative to THAT page
  // (install/choices.md says update.md; use/watch.md says
  // ../images/...). Found live: false resolved them from the root, and
  // the first link opened was a 404.
  relativePath: true,
  // NO-POPUPS-1: a link to another site opens in this tab. docsify's
  // default is a new one.
  externalLinkTarget: '_self',
  notFoundPage: true,
  search: {
    placeholder: 'Search the manual',
    noData: 'Nothing found.',
    depth: 3,
  },
  markdown: {
    renderer: {
      code(code, lang) {
        if (lang === 'mermaid') { return `<div class="mermaid">${escapeHtml(code)}</div>`; }
        return this.origin.code.apply(this, arguments);
      },
    },
  },
  plugins: [
    // NO-POPUPS-1: the link back to the dashboard, on every page.
    function (hook) {
      hook.mounted(function () {
        const back = document.createElement('a');
        back.className = 'm-back';
        back.href = manualBackHref(location.search);
        back.textContent = 'Back to the dashboard';
        document.body.appendChild(back);
        document.addEventListener('keydown', function (e) {
          if (escapeLeaves(e, document)) { location.href = back.href; }
        });
      });
      hook.doneEach(function () {
        const section = document.querySelector('.markdown-section');
        if (section) { learnLinksInNewTab(section); }
      });
    },
    function (hook) {
      hook.doneEach(function () {
        const nodes = document.querySelectorAll('.mermaid:not([data-processed])');
        if (nodes.length) { mermaid.run({ nodes }).catch(() => { /* the text stays readable */ }); }
      });
    },
  ],
};
