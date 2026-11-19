/* EVENTLOG-1: the dashboard reads a log that is in more than one part.
 *
 * An append blob holds 50,000 blocks and the engine writes one per event, so a
 * long run fills logs/events.jsonl and carries on in logs/events-2.jsonl. Every
 * page that shows the activity log, and the support bundle, read through this.
 *
 * Two things can go wrong and neither shows up as an error:
 *
 *   1. the naming rule drifts from the engine's, so the second part is never
 *      asked for and the console shows the first 50,000 events of a run and
 *      calls that the run
 *   2. the walk does not end, so every refresh reads two hundred documents
 *
 * The first is why the cases come out of tests/fixtures/log-part-names.json -
 * the same file StoreLineParts.Tests.ps1 holds the engine to.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const nextLogPart = lift('help.js', 'nextLogPart');
const readLogParts = lift('help.js', 'readLogParts');
const readLogEvents = lift('help.js', 'readLogEvents');

// The lifted functions close over things the harness cannot see. Take the real
// values out of the source rather than writing them again here - a literal in
// this file would keep passing after somebody changed help.js.
const HELP_SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const MAX_MATCH = HELP_SRC.match(/const LOG_PARTS_MAX = (\d+);/);
if (!MAX_MATCH) { throw new Error('LOG_PARTS_MAX is not declared in help.js'); }
global.LOG_PARTS_MAX = Number(MAX_MATCH[1]);
global.nextLogPart = nextLogPart;
global.readLogParts = readLogParts;

const CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'log-part-names.json'), 'utf8')).cases;

/** A store holding the given parts. Records what was asked for. */
function store(parts) {
  const asked = [];
  const read = async (p) => { asked.push(p); return Object.prototype.hasOwnProperty.call(parts, p) ? parts[p] : null; };
  return { read, asked };
}

const LOG = 'run1/logs/events.jsonl';

test('the naming rule is the engine own', () => {
  ok(CASES.length > 5, 'the fixture loaded');
  for (const c of CASES) { eq(nextLogPart(c.from), c.to, c.why); }
});

test('a log in one part reads as it always did', async () => {
  const s = store({ [LOG]: '{"n":1}\n{"n":2}\n' });
  eq(await readLogParts(s.read, LOG), ['{"n":1}', '{"n":2}'], 'both lines');
});

test('a log in three parts reads all of it, in part order', async () => {
  const s = store({
    [LOG]: '{"n":1}\n',
    'run1/logs/events-2.jsonl': '{"n":2}\n',
    'run1/logs/events-3.jsonl': '{"n":3}\n',
  });
  eq(await readLogEvents(s.read, LOG).then(e => e.map(x => x.n)), [1, 2, 3], 'every part');
});

test('it stops at the first part that is not there', async () => {
  /* The rule that makes the walk end. Parts are made in order and whatever
   * makes one appends to it in the same breath, so a gap is the end - and
   * reading past one would cost two hundred requests on every refresh tick. */
  const s = store({ [LOG]: '{"n":1}\n', 'run1/logs/events-3.jsonl': '{"n":3}\n' });
  eq(await readLogEvents(s.read, LOG).then(e => e.map(x => x.n)), [1], 'part 3 is not reached');
  eq(s.asked, [LOG, 'run1/logs/events-2.jsonl'], 'and it did not keep asking');
});

test('a log that is not there at all is no lines, not an error', async () => {
  const s = store({});
  eq(await readLogParts(s.read, LOG), [], 'nothing');
  eq(s.asked.length, 1, 'one read that found nothing');
});

test('a read that throws ends the walk rather than the page', async () => {
  /* The log is written while it is being read and the facade can be slow, so a
   * failed read is ordinary. The pages that poll this treat an empty answer as
   * nothing to report and ask again on the next tick. */
  const read = async () => { throw new Error('network'); };
  eq(await readLogParts(read, LOG), [], 'no lines, no throw');
});

test('a part that fails mid-walk keeps what was already read', async () => {
  const read = async (p) => {
    if (p === LOG) { return '{"n":1}\n'; }
    throw new Error('network');
  };
  eq(await readLogEvents(read, LOG).then(e => e.map(x => x.n)), [1], 'part one survives');
});

test('a half-written last line is skipped, not thrown', async () => {
  // The engine appends while the page reads. The last line can be partial.
  const s = store({ [LOG]: '{"n":1}\n{"n":2' });
  eq(await readLogEvents(s.read, LOG).then(e => e.map(x => x.n)), [1], 'the whole line only');
  eq(await readLogParts(s.read, LOG), ['{"n":1}', '{"n":2'], 'and readLogParts keeps it as written');
});

test('blank lines and carriage returns do not become events', async () => {
  const s = store({ [LOG]: '{"n":1}\r\n\r\n   \r\n{"n":2}\r\n' });
  eq(await readLogEvents(s.read, LOG).then(e => e.map(x => x.n)), [1, 2], 'two events');
});

test('the walk is bounded', async () => {
  /* Every part answers, so nothing would ever end this on its own. A store
   * that behaved like that would otherwise hold a refresh tick open for ever.
   */
  let reads = 0;
  const read = async () => { reads++; return '{"n":1}\n'; };
  const lines = await readLogParts(read, LOG);
  eq(reads, global.LOG_PARTS_MAX, 'it stopped at the limit');
  eq(lines.length, global.LOG_PARTS_MAX, 'and kept what it read');
});

test('the parts are asked for in order, one at a time', async () => {
  // Not in parallel: a parallel walk has to guess how many parts there are,
  // and guessing high is the cost this is trying to avoid.
  const s = store({
    [LOG]: 'a\n',
    'run1/logs/events-2.jsonl': 'b\n',
    'run1/logs/events-3.jsonl': 'c\n',
  });
  eq(await readLogParts(s.read, LOG), ['a', 'b', 'c'], 'in order');
  eq(s.asked, [LOG, 'run1/logs/events-2.jsonl', 'run1/logs/events-3.jsonl', 'run1/logs/events-4.jsonl'],
    'each one after the one before it');
});

run('log-parts');
