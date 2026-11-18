/* STORE-READ-1, 2026-09-10. The dashboard reads the run store THROUGH THE
 * FACADE now, because a browser can never be admitted by a network security
 * perimeter - it is not in a subscription.
 *
 * These hold the properties the seven pages depend on. Their own helpers keep
 * their names and signatures and delegate here, so a change in shape here is a
 * change in every page at once.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const storeUrl = lift('help.js', 'storeUrl');
const storeList = lift('help.js', 'storeList');
const storeBlob = lift('help.js', 'storeBlob');
const storeError = lift('help.js', 'storeError');

/* The harness evals each function on its own, so a lifted function cannot see
 * its siblings. In help.js they share one closure; give the test the same, or
 * storeList cannot call storeUrl. */
globalThis.storeUrl = storeUrl;
globalThis.storeError = storeError;

const token = async () => 'tok';

function fakeFetch(reply) {
  const calls = [];
  globalThis.fetch = async (url, init) => { calls.push({ url, init }); return reply; };
  return calls;
}
const json = (status, body) => ({
  ok: status >= 200 && status < 300, status,
  json: async () => body, text: async () => JSON.stringify(body),
});

test('an EMPTY prefix is kept, because it lists the top of the container', () => {
  eq(storeUrl('https://f/api', 'store/list', { prefix: '', delimiter: undefined }),
     'https://f/api/store/list?prefix=');
});

test('null and undefined are dropped, so no empty parameters are sent', () => {
  eq(storeUrl('https://f/api', 'store/list', { prefix: 'a/', delimiter: null, marker: undefined }),
     'https://f/api/store/list?prefix=a%2F');
});

test('every value is encoded, so a path cannot smuggle a parameter', () => {
  eq(storeUrl('https://f/api', 'store/blob', { path: 'run 1/a&b=c.json' }),
     'https://f/api/store/blob?path=run%201%2Fa%26b%3Dc.json');
});

test('the list sends a bearer token and returns the browser shape', async () => {
  const calls = fakeFetch(json(200, { names: ['a.json'], prefixes: ['run-1'], truncated: false }));
  const r = await storeList(token, 'https://f/api', 'run-1/', '/');
  eq(r.names[0], 'a.json');
  eq(r.prefixes[0], 'run-1');
  eq(r.truncated, false);
  eq(calls[0].init.headers.Authorization, 'Bearer tok');
});

test('a truncated listing is reported, never silently short', async () => {
  fakeFetch(json(200, { names: [], prefixes: [], truncated: true }));
  const r = await storeList(token, 'https://f/api', '', null);
  eq(r.truncated, true);
});

test('a listing with no arrays reads as empty, not undefined', async () => {
  fakeFetch(json(200, {}));
  const r = await storeList(token, 'https://f/api', '', null);
  eq(r.names.length, 0);
  eq(r.prefixes.length, 0);
});

test('a missing document is null, not an error', async () => {
  // The pages ask for an approval before anyone approved.
  fakeFetch(json(404, { error: 'not found' }));
  eq(await storeBlob(token, 'https://f/api', 'run-1/approval.json'), null);
});

test('a document comes back parsed, or as text when asked', async () => {
  fakeFetch(json(200, { schemaVersion: 1 }));
  eq((await storeBlob(token, 'https://f/api', 'run-1/plan.json')).schemaVersion, 1);
  fakeFetch(json(200, { schemaVersion: 1 }));
  eq(typeof await storeBlob(token, 'https://f/api', 'run-1/plan.json', { asText: true }), 'string');
});

test('a refusal shows what the facade SAID, not just a number', async () => {
  // The facade explains a bad path or a missing role. Throwing "HTTP 400"
  // would drop the only useful part.
  fakeFetch(json(400, { error: '400 the path must not go up a level' }));
  let message = '';
  try { await storeBlob(token, 'https://f/api', '../x'); } catch (e) { message = e.message; }
  eq(message, '400 the path must not go up a level');
});

test('and falls back to the status when there is no message', async () => {
  fakeFetch({ ok: false, status: 503, json: async () => { throw new Error('no body'); } });
  let message = '';
  try { await storeList(token, 'https://f/api', 'run-1/'); } catch (e) { message = e.message; }
  ok(message.includes('503'), 'the status survives when the body does not');
});

test('both reads are uncached, or a poll freezes on what it first saw', async () => {
  // migrations.html carried cache: 'no-store' and the other six pages did not.
  // Now the one client does, so every page gets it.
  let calls = fakeFetch(json(200, { names: [], prefixes: [] }));
  await storeList(token, 'https://f/api', 'run-1/');
  eq(calls[0].init.cache, 'no-store');
  calls = fakeFetch(json(200, {}));
  await storeBlob(token, 'https://f/api', 'run-1/plan.json');
  eq(calls[0].init.cache, 'no-store');
});

run('store-client');
