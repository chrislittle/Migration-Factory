/* RESTORE-COPY-1, 2026-09-18. Which safety copy "Put this machine back" reads.
 *
 * A migration takes TWO copies and they mean different things:
 *
 *   pristine  before anything was touched. It predates the guest preparation
 *             that lets the machine boot on the new hardware, so restoring it
 *             ALSO returns the size and the disk controller to what they were.
 *             It is the real way back.
 *   prepared  taken when the machine was stopped and ready to move. The guest
 *             is already converted, so the machine stays on the new hardware.
 *
 * THE DEFECT, found on a live install after the first real migration. The
 * engine has always been able to read either. Nothing between the page and the
 * engine carried the choice, so every restore from the app used the engine's
 * default - prepared - and the pristine copy could not be asked for at all.
 *
 * And the dialog SAID it would do the other one: "A copy of the disk was taken
 * before this machine was migrated. This puts the machine back to exactly that
 * point." That describes the pristine copy. An operator reaching for "put it
 * back how it was" would have got a machine still on its new size and
 * controller, with a disk that already had the guest changes in it.
 *
 * The words promised one thing and the button did another. That is worse than
 * a missing feature.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// V3-RETIRE-1: askRestore asks putBackRetireNote for the retirement words.
// RESTORE-DIALOG-WORDS-1: and restoreExceptions, restoreShapes and shapeWords.
const r = liftAll('migrations.html', ['restoreCopyField', 'restoreDiskNames', 'restoreKeepInstantNote', 'putBackRetireNote', 'askRestore',
  'restoreExceptions', 'restoreShapes', 'shapeWords',
  // REBUILD-ACCEPT-1: the Site Recovery line of the restore dialog.
  'restoreSiteRecoveryWords']);

/* THE PAGE'S OWN WORDING, read from the page.
 *
 * The first version of this file wrote the sentences out here, and one of them
 * was a truncated copy - so a wording check passed or failed on what the TEST
 * said, not on what an operator reads. Writing the strings down twice is how a
 * test stops covering the thing it is about; this defect WAS a wording defect,
 * so that would have been the whole point missed. RESTORE-DIALOG-WORDS-1: the
 * whole table, as the page declares it (liftConst). */
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();globalThis.noteField = () => ({ id: 'note', label: 'Why?' });
globalThis.runSeg = () => 'migration-1';

/** Open the dialog and capture what it declared, without drawing anything. */
function openWith(doc) {
  let captured = null;
  globalThis.openModal = (opts) => { captured = opts; };
  r.askRestore('/subscriptions/s/rg/a/vm1', doc);
  return captured;
}

/** Run the dialog's confirm with the given answers, and capture the request. */
async function confirmWith(doc, answers) {
  const opts = openWith(doc);
  let sent = null;
  globalThis.apiFetch = async (path, body) => { sent = { path, body }; };
  await opts.onConfirm(answers);
  return sent;
}

const TWO = { safety: { snapshotId: '/snap/vm1', pristineSnapshotId: '/snap/vm1-pristine' } };
const ONE = { safety: { snapshotId: '/snap/vm1' } };

test('a machine with two copies is asked which one', () => {
  const opts = openWith(TWO);
  const field = opts.fields.find(f => f && f.id === 'diskSource');
  ok(field, 'the dialog offers the choice');
  eq(field.options.map(o => o.value), ['pristine', 'prepared']);
});

test('the pristine option SAYS it returns the original size and disk controller', () => {
  /* The whole defect was wording that promised this while doing the other
   * thing. An operator cannot choose between two copies described as the
   * same. */
  const opts = openWith(TWO);
  const field = opts.fields.find(f => f.id === 'diskSource');
  // RESTORE-DIALOG-WORDS-1 changed this on purpose: each copy is a short
  // option with its size from the record, and the first copy says in its ?
  // helper that the machine goes back to that size and disk controller.
  const pristine = field.options.find(o => o.value === 'pristine');
  const prepared = field.options.find(o => o.value === 'prepared');
  ok(/returns to this size and disk controller/.test(pristine.help), 'the real way back says so');
  ok(!prepared.help, 'and the other changes no size, so it says nothing more');
  ok(pristine.label !== prepared.label, 'two options, two names');
});

test('choosing pristine sends it - the defect was that nothing was sent', () => {
  return confirmWith(TWO, { diskSource: 'pristine', diskNaming: 'new', note: 'rolling back' })
    .then(sent => {
      eq(sent.body.diskSource, 'pristine');
      eq(sent.body.diskNaming, 'new');
      eq(sent.path, 'runs/migration-1/engine/restore');
    });
});

test('choosing prepared sends that, rather than relying on a default', () => {
  /* A default that happens to match is not the same as an answer. The state
   * document records what was asked for. */
  return confirmWith(TWO, { diskSource: 'prepared', diskNaming: 'new', note: 'n' })
    .then(sent => { eq(sent.body.diskSource, 'prepared'); });
});

test('a machine with ONE copy is not offered a choice it cannot honour', () => {
  /* A wave policy may take only the pre-move copy. Offering "before anything
   * was changed" there would fail in the engine, after the press.
   * RESTORE-DIALOG-WORDS-1: the one copy is shown, alone, in the same short
   * form, under its own question. */
  const opts = openWith(ONE);
  const field = opts.fields.find(f => f && f.id === 'diskSource');
  eq(field.options.map(o => o.value), ['prepared'], 'only the copy that exists');
  eq(field.label, UX_ACT.restoreOnlyCopy, 'and the dialog says why');
});

test('and no copy is invented for it in the request', () => {
  return confirmWith(ONE, { diskNaming: 'new', note: 'n' })
    .then(sent => {
      eq(Object.prototype.hasOwnProperty.call(sent.body, 'diskSource'), false,
         'the field is absent, not guessed');
    });
});

test('the destructive disk option still needs its own acceptance', () => {
  /* Unchanged by this, and checked because the two choices now sit in one
   * dialog: picking a copy must not become a way past the delete warning. */
  return confirmWith(TWO, { diskSource: 'pristine', diskNaming: 'preserve', note: 'n', accept: [] })
    .then(() => { throw new Error('it should have refused'); })
    .catch(e => { eq(String(e.message), UX_ACT.restoreRiskMissing, 'refused, with the page own sentence'); });
});

test('accepting the delete lets it through, with both answers', async () => {
  const sent = await confirmWith(TWO,
    { diskSource: 'pristine', diskNaming: 'preserve', note: 'n', accept: ['yes'] });
  eq(sent.body.acceptPreserveRisk, true);
  eq(sent.body.diskSource, 'pristine');
});

test('restoreCopyField is null when no copy exists, and has one option per copy', () => {
  eq(r.restoreCopyField({}), null);
  eq(r.restoreCopyField(null), null);
  eq(r.restoreCopyField(ONE).options.length, 1);
  eq(r.restoreCopyField(TWO).options.length, 2);
});

/* PREP-ROLLBACK-1 (review F5): a machine stopped before its second copy, whose
 * rollback could not finish, has the first copy only. The dialog says so, asks
 * no choice, and sends 'pristine' - the engine default is the second copy,
 * which does not exist. */
const FIRST_ONLY = { safety: { pristineSnapshotId: '/snap/vm1-pristine', snapshotId: null } };

test('the first copy only: no choice, its own words, and pristine is sent', () => {
  const opts = openWith(FIRST_ONLY);
  const field = opts.fields.find(f => f && f.id === 'diskSource');
  eq(field.options.map(o => o.value), ['pristine'], 'no choice of one');
  eq(field.label, UX_ACT.restoreOnlyCopy);
  ok(/returns to this size and disk controller/.test(field.options[0].help), 'it says the size goes back');
  return confirmWith(FIRST_ONLY, { diskNaming: 'new', note: 'put it back' }).then(sent => eq(sent.body.diskSource, 'pristine'));
});

test('the second copy only still sends nothing: the engine default is that copy', () => {
  return confirmWith(ONE, { diskNaming: 'new', note: 'x' }).then(sent => eq(sent.body.diskSource, undefined));
});

run('restore copy');