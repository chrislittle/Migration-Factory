/* THEME-1 - light and dark, and the person decides.
 *
 * Two themes, dark and light, and a control that lets a person choose
 * between them rather than having one imposed.
 *
 * THIS FILE LOADS SYNCHRONOUSLY IN <head>, BEFORE app.css AND BEFORE THE BODY.
 * That is the whole reason it is separate from help.js, which loads at the end
 * of the page. A theme stamped after first paint is a flash of the wrong
 * colours on every navigation - the defect people call "the white flash", and
 * it is worse on a dashboard somebody leaves open in a dark room.
 *
 * WHAT DECIDES, IN ORDER:
 *   1. the person's own choice, kept in localStorage
 *   2. the operating system, via prefers-color-scheme
 *   3. light
 *
 * Storage can THROW, not just come back empty - a browser set to block site
 * data raises on read. Every access here is guarded, and a failure costs the
 * remembered choice, never the page.
 */
(function () {
  'use strict';

  var KEY = 'vmf-theme';
  var root = document.documentElement;

  function stored() {
    try {
      var v = window.localStorage.getItem(KEY);
      return (v === 'dark' || v === 'light') ? v : null;
    } catch (e) { return null; }
  }

  function remember(v) {
    try { window.localStorage.setItem(KEY, v); } catch (e) { /* private window */ }
  }

  function osPrefers() {
    try {
      return window.matchMedia &&
             window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } catch (e) { return 'light'; }
  }

  function apply(v) {
    root.setAttribute('data-theme', v);
    // Tells the browser which way round its own furniture goes - scrollbars,
    // and the parts of a form control we do not paint ourselves. Without it a
    // dark page keeps light scrollbars.
    root.style.colorScheme = v;
    paintButton();
  }

  function current() { return root.getAttribute('data-theme') === 'dark' ? 'dark' : 'light'; }

  /* WHAT THE PERSON CHOSE: 'light', 'dark', or 'system' when they have not
   * chosen and the operating system is deciding.
   *
   * THEME-2: the control must show the CURRENT theme and let you change to
   * another. A two-state button could not do that. It named
   * the DESTINATION, so it could never show where you were - and once pressed
   * there was no way back to following the operating system, which is the
   * state the app starts in. A picker shows the current setting by definition
   * and has room for that third option. */
  function choice() { return stored() || 'system'; }

  function set(v) {
    if (v === 'system') {
      try { window.localStorage.removeItem(KEY); } catch (e) { /* private window */ }
      apply(osPrefers());
      return;
    }
    if (v !== 'dark' && v !== 'light') { return; }
    remember(v);
    apply(v);
  }

  function toggle() { set(current() === 'dark' ? 'light' : 'dark'); }

  var LABEL = { light: 'Light', dark: 'Dark', system: 'Follow the system' };

  function paintButton() {
    var el = document.getElementById('nav-theme');
    if (!el) { return; }
    var c = choice();
    if (el.tagName === 'SELECT') {
      if (el.value !== c) { el.value = c; }
      el.setAttribute('title', c === 'system'
        ? 'Following the operating system, which is showing the ' + current() + ' theme'
        : 'Showing the ' + c + ' theme');
      return;
    }
    el.textContent = LABEL[c];   // a page still drawing a button gets a label
  }

  /* Follow the operating system for as long as the person has not chosen.
   * Once they have, their choice wins and this stops speaking - which is the
   * behaviour people expect and almost never get. */
  try {
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    var onChange = function (e) { if (!stored()) { apply(e.matches ? 'dark' : 'light'); } };
    if (mq.addEventListener) { mq.addEventListener('change', onChange); }
    else if (mq.addListener) { mq.addListener(onChange); }
  } catch (e) { /* no matchMedia - the stamp below still runs */ }

  apply(stored() || osPrefers());

  /* The bar is drawn later, by help.js. Paint the label again once it exists. */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { paintButton(); });
  }

  window.VmfTheme = { current: current, choice: choice, set: set, toggle: toggle,
                      paintButton: paintButton, LABEL: LABEL };
})();
