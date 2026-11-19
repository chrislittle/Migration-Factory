/* RECORD-DELETE-1: a record download is refused while a delete of the same
 * migration runs - and the person who pressed "Download the record" reads why.
 *
 * The service answers 409 with a sentence: from the service while the engine
 * deletes the migration with its safety copies, and from the engine when a
 * delete has started to remove it. The page must show that sentence, not the
 * code in front of it, save nothing, and give the button back.
 *
 * RUN, not read: the page's own downloadRecord, help.js's own rules (taken from
 * the file the way plan-write-race.test.js takes them), and the two sentences
 * as the service and the engine write them.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const HELP = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const START = 'const ROLE_WORDS';
const END = 'function explainAction(err) { return explainWith(err, true); }';
const from = HELP.indexOf(START);
const to = HELP.indexOf(END);
const slice = (from >= 0 && to > from) ? HELP.slice(from, to + END.length) : '';
// eslint-disable-next-line no-eval
const rules = slice ? eval(`(function () { ${slice}; return { explain, explainAction }; })()`) : null;

// The sentences as the service and the engine throw them.
const FACADE = fs.readFileSync(path.join(REPO, 'src', 'facade', 'FacadeCore', 'FacadeCore.psm1'), 'utf8');
const RECORD = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'report', 'MigrationRecord.ps1'), 'utf8');
const serviceSays = (FACADE.match(/-Refusal '(409: [^']+)'/) || [])[1];
const engineSays = (RECORD.match(/\$deleting = '(409: [^']+)'/) || [])[1];
const racedSays = (RECORD.match(/\$raced = '(409: [^']+)'/) || [])[1];

const downloadRecord = lift('reports.html', 'downloadRecord');

async function pressWhile(refusal, err = { textContent: '', style: { display: 'none' } }) {
  const saved = [];
  globalThis.recordRefusal = globalThis.recordRefusal ?? '';
  globalThis.window = {};
  globalThis.saveFile = (name, text, type) => saved.push({ name, text, type });
  globalThis.reportLook = async () => null;
  globalThis.recordHtml = () => '<html></html>';
  globalThis.recordFileName = () => 'migration-record.html';
  globalThis.$ = (sel) => (sel === '#err' ? err : { textContent: '', style: {} });
  globalThis.VmfHelp = rules;
  globalThis.UX = { recBusy: 'Preparing...' };
  const btn = { textContent: 'Download the record', disabled: false };
  // apiCall throws the service's "error" text as the message.
  await downloadRecord(async () => { throw new Error(refusal); }, btn);
  return { saved, err, btn };
}

test('the sentences were found where the service and the engine throw them', () => {
  ok(rules, 'the rules were not found in help.js');
  ok(serviceSays, 'the service refusal');
  ok(engineSays, 'the engine refusal');
  ok(racedSays, 'the refusal when the record was written again');
});

for (const [who, said] of [['the service, while the engine deletes', () => serviceSays],
                           ['the engine, when a delete has started', () => engineSays],
                           ['the engine, when the record was written again', () => racedSays]]) {
  test(`THE POINT: a refused download shows the sentence from ${who}, without the code`, async () => {
    const { saved, err, btn } = await pressWhile(said());
    eq(err.textContent, said().replace(/^409:\s*/, ''), 'the message on the page');
    eq(err.style.display, 'block', 'and it shows');
    eq(saved.length, 0, 'nothing is saved');
    eq(btn.disabled, false, 'the button comes back');
    eq(btn.textContent, 'Download the record', 'with its own words');
  });
}

test('a download that is not refused still saves the record', async () => {
  const saved = [];
  globalThis.saveFile = (name, text, type) => saved.push({ name, text, type });
  const btn = { textContent: 'Download the record', disabled: false };
  await downloadRecord(async () => ({ runId: 'mig-1' }), btn);
  eq(saved.length, 1, 'one file');
});

test('review 5: a refusal goes when the next download starts, and a download that works leaves none', async () => {
  globalThis.recordRefusal = '';
  const err = { textContent: '', style: { display: 'none' } };
  await pressWhile(serviceSays, err);
  eq(err.style.display, 'block', 'the refusal shows');
  const btn = { textContent: 'Download the record', disabled: false };
  await downloadRecord(async () => ({ runId: 'mig-1' }), btn);
  eq(err.textContent, '', 'and is gone after the download that worked');
  eq(err.style.display, 'none', 'with its box');
});

test('a message that the page load left is not cleared by a download', async () => {
  globalThis.recordRefusal = '';
  const err = { textContent: 'The migration records could not be reached.', style: { display: 'block' } };
  globalThis.$ = (sel) => (sel === '#err' ? err : { textContent: '', style: {} });
  const btn = { textContent: 'Download the record', disabled: false };
  await downloadRecord(async () => ({ runId: 'mig-1' }), btn);
  eq(err.textContent, 'The migration records could not be reached.', 'it stays');
});

run('record-delete');
