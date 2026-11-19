/* OPT-DROP-1, 2026-09-18. A page asks its blob helper for a document AND the
 * version the service issued for it. The helper has to FORWARD that request.
 *
 * WHAT HAPPENED. PLANVER-2 added `asVersioned` to VmfHelp.storeBlob and added a
 * caller on the Migrations page. The page's own helper between them read only
 * `asText`:
 *
 *     async function blobFetch(path, { asText = false } = {}) {
 *       return VmfHelp.storeBlob(getToken, cfg.apiUrl, path, { asText });
 *     }
 *
 * So the option was dropped in the middle. storeBlob returned a PARSED OBJECT,
 * the caller read `.text` from it and got undefined, and the next line said
 *
 *     "undefined" is not valid JSON
 *
 * on the Approve button. Approve could not open at all. Found on the first
 * click in a real browser, 2026-09-18 - not by 2,900 tests.
 *
 * WHY NOTHING CAUGHT IT. The page tests stub `source.readVersioned` and hand
 * back a well-formed { text, version }. That stub replaces the one link in the
 * chain that was broken. A test that mocks the thing under test measures the
 * mock.
 *
 * So these run the REAL page helper against the REAL storeBlob, with only the
 * network faked. An option a caller passes and a callee drops is the same
 * defect as a parameter never declared: nothing throws, and the next line lies.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const blobFetch = lift('migrations.html', 'blobFetch');

/* The real one from help.js, not a stand-in. storeBlob leans on two siblings
 * in its own closure, so the lifted copy needs them as globals. */
globalThis.storeUrl = lift('help.js', 'storeUrl');
globalThis.storeError = lift('help.js', 'storeError');
globalThis.VmfHelp = { storeBlob: lift('help.js', 'storeBlob') };

globalThis.cfg = { apiUrl: 'https://f/api' };
globalThis.getToken = async () => 'tok';

const DOC = '{"entries":[{"wave":1}]}';

/** A facade that answers with a document and the version it issued for it. */
function facade(body, version, status) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return {
      ok: (status || 200) < 300,
      status: status || 200,
      json: async () => JSON.parse(body),
      text: async () => body,
      headers: { get: (n) => (n === 'x-vmf-document-version' ? (version || null) : null) },
    };
  };
  return calls;
}

test('asVersioned reaches storeBlob, so the text and the version both arrive', async () => {
  facade(DOC, 'plan-9f2a1c');
  const got = await blobFetch('run-1/plan.json', { asVersioned: true });
  /* THE REGRESSION. Before the fix this was a parsed object: `text` was
   * undefined and the caller's JSON.parse said "undefined" is not valid JSON. */
  eq(got.text, DOC, 'the document');
  eq(got.version, 'plan-9f2a1c', 'the version the service issued');
});

test('the version a page quotes is the service\'s, never one computed here', async () => {
  facade(DOC, 'plan-aaaa11');
  const got = await blobFetch('run-1/plan.json', { asVersioned: true });
  /* PLANVER-2: a page that hashes the text it received cannot agree with a
   * service that hashed the bytes it stored. Only the header can. */
  eq(got.version, 'plan-aaaa11');
});

test('a document with no version header reads as empty, not as undefined', async () => {
  facade(DOC, null);
  const got = await blobFetch('run-1/plan.json', { asVersioned: true });
  eq(got.text, DOC);
  eq(got.version, '', 'an absent header must not become undefined');
});

test('asText still returns the text, so the older callers are unharmed', async () => {
  facade(DOC, 'plan-9f2a1c');
  eq(await blobFetch('run-1/steps.log', { asText: true }), DOC);
});

test('no options still returns the parsed document', async () => {
  facade(DOC, 'plan-9f2a1c');
  const got = await blobFetch('run-1/plan.json');
  eq(got.entries[0].wave, 1);
});

test('a document that is not there is null in every mode, not a throw', async () => {
  facade('', null, 404);
  eq(await blobFetch('run-1/approval.json', { asVersioned: true }), null);
  facade('', null, 404);
  eq(await blobFetch('run-1/approval.json'), null);
});

test('the read is sent to the facade, with the bearer token', async () => {
  const calls = facade(DOC, 'v1');
  await blobFetch('run-1/plan.json', { asVersioned: true });
  ok(calls[0].url.startsWith('https://f/api/store/blob?path='), 'through the facade');
  eq(calls[0].init.headers.Authorization, 'Bearer tok');
});

run('blob options');
