/* WAVES-API-1: no dashboard page calls a function that nobody declares.
 *
 * WHY. The wave editor called `api(...)` - a helper three OTHER pages define
 * and this one never did. The page parsed (UI-PARSE-1 asks only that), and
 * the boot test ran it in demo mode, where the call sat behind
 * `if (!DEMO_MODE)`. So the first time the call ran was on a real install,
 * and it stopped the editor before it showed anything. A name that resolves
 * to nothing is a fact the SOURCE holds; nothing has to run to find it.
 *
 * WHAT IT CHECKS. Every call `name(...)`, `new Name(...)` and tag`...` whose
 * callee is a bare name, in a page's inline scripts and in the shared files
 * the page loads. The name must resolve: to a parameter or declaration in an
 * enclosing scope, to a top-level declaration of ANY script the page loads
 * (classic scripts share one global scope), to a `window.name = ...`
 * assignment, or to a JavaScript or browser global named below.
 *
 * WITH A REAL PARSER. Node carries acorn for its own use; `--expose-internals`
 * opens it, so this needs no install. A regex over the text cannot tell a call
 * from a property, a string or a comment - a test that reads a whole file
 * matches its own comments (CLAUDE.md).
 *
 * WHAT IT DOES NOT CLAIM. Scopes follow the language closely, not exactly: a
 * name is taken as declared through the whole block that declares it (no
 * temporal dead zone), and a function declared inside a block belongs to that
 * block. A call through a property (`VmfHelp.x()`) is not checked - the object
 * is known only when the page runs.
 * A call inside an HTML string (`onclick="foo()"`, in the markup or in markup a
 * script draws) is not seen: it is text to the parser. On 2026-10-31 the
 * dashboard had one, `closeDrill()` on migrations.html, and the page declares it.
 *
 * Run: node --expose-internals tests/js/_page-calls.js [page.html ...]
 *  or: node --expose-internals tests/js/_page-calls.js --sources <file.json>
 * It prints one JSON object, page -> [{ name, file, line }], and exits 1 when
 * any page has a finding.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

let acorn;
try { acorn = require('internal/deps/acorn/acorn/dist/acorn'); }
catch (e) {
  throw new Error('the JavaScript parser did not load. Run this with node --expose-internals: ' + e.message);
}

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');

/* The globals a page may call without declaring them. The language's own
 * come from a fresh context, so the list follows the node that runs this.
 * The browser's are named one by one: a name here is a promise that every
 * browser the product supports has it. */
const LANGUAGE = vm.runInNewContext('Object.getOwnPropertyNames(globalThis)');
const BROWSER = [
  'fetch', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'queueMicrotask',
  'requestAnimationFrame', 'cancelAnimationFrame', 'structuredClone', 'atob', 'btoa',
  'alert', 'confirm', 'prompt', 'getComputedStyle', 'matchMedia', 'open', 'close', 'print',
  'scrollTo', 'scrollBy', 'postMessage', 'getSelection',
  'AbortController', 'URL', 'URLSearchParams', 'Blob', 'File', 'FileReader', 'FormData',
  'Headers', 'Request', 'Response', 'Event', 'CustomEvent', 'KeyboardEvent', 'MouseEvent',
  'MutationObserver', 'ResizeObserver', 'IntersectionObserver', 'Image', 'DOMParser',
  'XMLSerializer', 'TextEncoder', 'TextDecoder', 'BroadcastChannel', 'XMLHttpRequest',
];
const GLOBAL_OBJECTS = new Set(['window', 'globalThis', 'self']);

const PARSE = { ecmaVersion: 'latest', sourceType: 'script', locations: true,
  allowAwaitOutsideFunction: true, allowReturnOutsideFunction: true };

const isNode = (v) => v && typeof v === 'object' && typeof v.type === 'string';
const isFunction = (n) => n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression';

function children(node) {
  const out = [];
  for (const key of Object.keys(node)) {
    if (key === 'loc' || key === 'start' || key === 'end') { continue; }
    const v = node[key];
    if (Array.isArray(v)) { for (const x of v) { if (isNode(x)) { out.push(x); } } }
    else if (isNode(v)) { out.push(v); }
  }
  return out;
}

/** Every name a binding pattern declares. */
function patternNames(p, out) {
  if (!p) { return out; }
  switch (p.type) {
    case 'Identifier': out.push(p.name); break;
    case 'ObjectPattern': for (const prop of p.properties) { patternNames(prop.type === 'RestElement' ? prop.argument : prop.value, out); } break;
    case 'ArrayPattern': for (const el of p.elements) { patternNames(el, out); } break;
    case 'AssignmentPattern': patternNames(p.left, out); break;
    case 'RestElement': patternNames(p.argument, out); break;
    default: break;
  }
  return out;
}

/** `var` names, anywhere in a function body but not inside a nested function. */
function hoistVars(node, names) {
  if (node.type === 'VariableDeclaration' && node.kind === 'var') {
    for (const d of node.declarations) { patternNames(d.id, names); }
  }
  for (const c of children(node)) { if (!isFunction(c)) { hoistVars(c, names); } }
  return names;
}

/** The names a list of statements declares in its own block. */
function lexical(statements, names) {
  for (const s of statements) {
    if ((s.type === 'FunctionDeclaration' || s.type === 'ClassDeclaration') && s.id) { names.push(s.id.name); }
    else if (s.type === 'VariableDeclaration' && s.kind !== 'var') {
      for (const d of s.declarations) { patternNames(d.id, names); }
    }
  }
  return names;
}

/** Names a script puts on the window: `window.x = ...`, `globalThis['x'] = ...`. */
function windowNames(node, names) {
  if (node.type === 'AssignmentExpression' && node.left.type === 'MemberExpression'
      && node.left.object.type === 'Identifier' && GLOBAL_OBJECTS.has(node.left.object.name)) {
    const prop = node.left.property;
    if (!node.left.computed && prop.type === 'Identifier') { names.push(prop.name); }
    else if (node.left.computed && prop.type === 'Literal' && typeof prop.value === 'string') { names.push(prop.value); }
  }
  for (const c of children(node)) { windowNames(c, names); }
  return names;
}

class Scope {
  constructor(parent, names) { this.parent = parent; this.names = new Set(names || []); }
  has(name) { for (let s = this; s; s = s.parent) { if (s.names.has(name)) { return true; } } return false; }
}

/** Walk one script and report each bare callee no scope declares. */
function unresolved(program, globalScope, report) {
  const visit = (node, scope) => {
    if (isFunction(node)) {
      const s = new Scope(scope);
      if (node.type === 'FunctionExpression' && node.id) { s.names.add(node.id.name); }
      for (const prm of node.params) { for (const n of patternNames(prm, [])) { s.names.add(n); } }
      for (const prm of node.params) { visit(prm, s); }
      if (node.body.type === 'BlockStatement') {
        for (const n of hoistVars(node.body, [])) { s.names.add(n); }
        for (const n of lexical(node.body.body, [])) { s.names.add(n); }
        for (const st of node.body.body) { visit(st, s); }
      } else { visit(node.body, s); }
      return;
    }
    let s = scope;
    switch (node.type) {
      case 'BlockStatement': case 'StaticBlock':
        s = new Scope(scope, lexical(node.body, [])); break;
      case 'ForStatement': case 'ForInStatement': case 'ForOfStatement': {
        const decl = node.type === 'ForStatement' ? node.init : node.left;
        const names = (decl && decl.type === 'VariableDeclaration' && decl.kind !== 'var')
          ? decl.declarations.flatMap(d => patternNames(d.id, [])) : [];
        s = new Scope(scope, names); break;
      }
      case 'CatchClause': s = new Scope(scope, patternNames(node.param, [])); break;
      case 'SwitchStatement':
        visit(node.discriminant, scope);
        s = new Scope(scope, lexical(node.cases.flatMap(c => c.consequent), []));
        for (const c of node.cases) { visit(c, s); }
        return;
      case 'ClassExpression': if (node.id) { s = new Scope(scope, [node.id.name]); } break;
      case 'CallExpression': case 'NewExpression':
        if (node.callee.type === 'Identifier' && !scope.has(node.callee.name)) { report(node.callee); }
        break;
      case 'TaggedTemplateExpression':
        if (node.tag.type === 'Identifier' && !scope.has(node.tag.name)) { report(node.tag); }
        break;
      default: break;
    }
    for (const c of children(node)) { visit(c, s); }
  };
  for (const st of program.body) { visit(st, globalScope); }
}

/**
 * Check a set of scripts that share one page.
 * sources: [{ file, code, lineOffset, check }] - `check: false` contributes
 * declarations but is not reported on.
 * Returns [{ name, file, line }].
 */
function findUndefinedCalls(sources) {
  const parsed = sources.map(src => ({ ...src, ast: acorn.parse(src.code, PARSE) }));
  const globals = new Set([...LANGUAGE, ...BROWSER, ...GLOBAL_OBJECTS]);
  for (const p of parsed) {
    for (const n of hoistVars(p.ast, [])) { globals.add(n); }
    for (const n of lexical(p.ast.body, [])) { globals.add(n); }
    for (const n of windowNames(p.ast, [])) { globals.add(n); }
  }
  const scope = new Scope(null, globals);
  const found = [];
  for (const p of parsed) {
    if (p.check === false) { continue; }
    unresolved(p.ast, scope, (id) => found.push({ name: id.name, file: p.file, line: id.loc.start.line + (p.lineOffset || 0) }));
  }
  return found;
}

/** The scripts of one dashboard page, in the order it loads them. */
function pageSources(pageFile) {
  const html = pageSource(path.join(DASH, pageFile));
  const sources = [];
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
    const src = /\bsrc="([^"]+)"/.exec(m[1]);
    if (src) {
      const file = src[1];
      // The minified MSAL files declare nothing at top level (measured): they
      // put `msal` on the window through an expression, and no page calls it
      // as a bare name.
      if (!/^[\w.-]+\.js$/.test(file) || /\.min\.js$/.test(file)) { continue; }
      const full = path.join(DASH, file);
      if (!fs.existsSync(full)) { throw new Error(`${pageFile} loads ${file}, which is not in src/dashboard`); }
      sources.push({ file, code: fs.readFileSync(full, 'utf8'), lineOffset: 0 });
    } else {
      // The line of the block's first character, so a finding names the page's own line.
      const before = html.slice(0, m.index + m[0].indexOf('>') + 1);
      sources.push({ file: pageFile, code: m[2], lineOffset: before.split('\n').length - 1 });
    }
  }
  return sources;
}

function checkPage(pageFile) { return findUndefinedCalls(pageSources(pageFile)); }

module.exports = { findUndefinedCalls, pageSources, checkPage };

if (require.main === module && process.argv[2] === '--sources') {
  /* The gate's own test: sources from a JSON file, [{ file, code, check }],
   * checked as one page. Prints the findings. */
  const sources = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  process.stdout.write(JSON.stringify(findUndefinedCalls(sources)));
  process.exit(0);
}

if (require.main === module) {
  const pages = process.argv.slice(2).length
    ? process.argv.slice(2)
    : fs.readdirSync(DASH).filter(f => f.endsWith('.html')).sort();
  const result = {};
  let any = false;
  for (const page of pages) {
    result[page] = checkPage(page);
    if (result[page].length) { any = true; }
  }
  process.stdout.write(JSON.stringify(result));
  process.exit(any ? 1 : 0);
}
