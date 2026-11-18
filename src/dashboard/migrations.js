'use strict';
const DEMO_MODE = new URLSearchParams(location.search).has('demo');
const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
/* VMID-CASE-1: a machine's name as Azure spells it on the machine, from the
 * records this page read - its state document, then its assessment record.
 * Cut from the ID alone, it showed MX-G1W beside mx-o2w in one wave. */
let machineNameOf = (id) => VmfHelp.machineName(id);
const vmName = (id) => machineNameOf(id);
function nameMachines(docs, assessment) {
  machineNameOf = VmfHelp.machineNames(docs, assessment?.vms);
}
// What each state says when it has FINISHED, as opposed to when it began.
// Without this the feed repeats the action word at completion, so a state that
// ended reads as one starting - which put "Starting the virtual machine" after
// "Running checks inside the machine" and made a correct sequence look wrong.
const UX_STATE_DONE = {
  PLANNED:         'Ready to begin',
  PRECHECK:        'Confirmed this machine is safe to migrate',
  GUEST_PREP:      'Finished preparing the operating system inside the machine',
  STOPPED:         'The machine is shut down',
  SAFETY_COPY:     'Safety copy taken, with the machine stopped',
  CONVERTING:      'Moved to the new size',
  STARTING:        'The machine is running again',
  VALIDATING:      'Checks passed',
};

const PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
const TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...PROBLEM_STATES];
// SAFETY-2 reordered this: both safety copies are now taken on a STOPPED
// machine, so the pristine one comes before prep and the prepared one after
// the shutdown. The progress meter reads percentages straight off this list,
// so it has to match what the engine actually does.
const STATE_SEQ = ['PLANNED','PRECHECK','SAFETY_PRISTINE','GUEST_PREP','STOPPED','SAFETY_COPY','CONVERTING','STARTING','VALIDATING','MIGRATED'];
// WAVE-2: rings are gone - waves are customer-named and sort by name.

/* ============================ UX-STRINGS-BEGIN ============================
   Every string below can be read by someone who knows what a virtual machine
   and a disk are - and NOTHING else. No engine vocabulary. The raw record
   stays available as tooltips and in the technical logs. Linted by tests. */
const UX_STATE = {
  PLANNED:               ['Queued',            'Waiting for its turn in the wave'],
  PRECHECK:              ['Checking',          'Confirming this machine is safe to migrate'],
  // The internal state name was showing through. Both copies
  // say "Backing up" - what differs is WHEN, and the description carries that.
  SAFETY_PRISTINE:       ['Backing up',        'Taking a safety copy of the machine exactly as it is now, before anything is changed'],
  GUEST_PREP:            ['Preparing',         'Preparing the operating system for the new size'],
  STOPPED:               ['Shutting down',     'Stopping the machine so it can be moved'],
  SAFETY_COPY:           ['Backing up',        'Taking a second safety copy now the machine is stopped and ready to move'],
  CONVERTING:            ['Moving',            'Moving the machine to the new size'],
  STARTING:              ['Starting up',       'Starting the machine on the new size'],
  // This claimed to check "applications", and it does not.
  // What VALIDATING actually does is check the guest: every fstab entry is
  // mounted, no stale device paths remain, the boot disk is on the expected
  // bus, every network interface came back on its own slot, every data disk
  // is on its original LUN with its cache mode, and the accelerated networking is
  // bound. Nothing application-level is checked unless the operator supplies
  // a workload probe, which is off by default. Say what it does.
  VALIDATING:            ['Verifying',         'Checking that every disk is mounted and that the network works'],
  MIGRATED:              ['Migrated',          'Running and verified on the new size'],
  NEEDS_DECISION:        ['Needs a decision',  'Paused for a human decision before anything is changed'],
  FAILED_ROLLED_BACK:    ['Rolled back',       'A step failed, and the product rolled the machine back to its original size and power state.'],
  FAILED_NEEDS_ATTENTION:['Needs attention',   'The machine stopped. Open the machine to see why and what to do.'],
  SKIPPED:               ['Not migrated',      'Excluded from this wave'],
};
const UX_STEP = {
  resizeVm:      'Switching the virtual machine to its new size',
  updateDisks:   'Updating the settings of the disks for the new size',
  stopVm:        'Shutting the virtual machine down',
  startVm:       'Starting the virtual machine',
  snapshotPristine: 'Taking a safety copy of the machine exactly as it is now, before anything is changed',
  // SAFETY-3: a rollback or a restore uses the copies, so what happens to them is said.
  lockCopy:       'Locked the safety copy so nobody can delete it before its retention ends.',
  lockCopySkipped: "The safety copy was not locked. The product's managed identity cannot place locks, so nothing prevents the deletion of the copy.",
  unlockCopy:     'Removed the lock from the safety copy, so that the copy can be deleted.',
  // TERMS-AUDIT-1: the read before an unlock, in a delete of a migration.
  readCopy:       'Checked whether Azure still has the safety copy.',
  verifyCopies:   'Checked that the safety copies are still there, before the machine is changed.',
  verifyCopiesFailed: 'A safety copy is missing. The migration stopped before changing the machine.',
  deleteCopy:     'Deleted the safety copy.',
  pristineTaken:  'Took a safety copy of the machine exactly as it was. The machine was stopped, and nothing had been changed yet.',
  pristineAlready: 'The copy was already taken earlier in this migration. There is nothing to do.',
  snapshotDisk:  'Taking a safety copy of every disk, now the machine is stopped',
  reserveCap:    'Creating the on-demand capacity reservation for this wave',
  releaseCap:    'Releasing the on-demand capacity reservation (machines keep running)',
  joinReserve:   'Placing the machine in the capacity reservation group of its wave',
  leaveReserve:  'Removing the machine from its capacity reservation group (it keeps running)',
  checkReserve:  'Checking which capacity reservation group this machine is in',
  readSizeNow:   'Reading the size the machine is on now',
  waitAgent:     'Waiting for the machine to answer from inside',
  readDisk:      'Reading which disk the machine is on',
  revertSize:    'Changing the machine back to the size it started on',
  swapBackDisk:  'Attaching the operating system disk that the machine returns to',
  swapBackDataDisks: 'Attaching the data disks that the machine returns to',
  makeDiskFromCopy: 'Building a disk from the safety copy',
  setAn:        'Setting accelerated networking back on a network interface',
  // DISK-TYPE-WORDS-1: the type comes from the event (skuName); with none, words true for every type.
  setDiskType:  'Changing the type of a disk',
  setDiskTypeTo: 'Changing a disk to {type}',
  setDiskTypeBack: 'Setting a disk back to the type it had',
  setDiskTypeBackTo: 'Setting a disk back to {type}',
  diskTypes: { Standard_LRS: 'Standard HDD', StandardSSD_LRS: 'Standard SSD', StandardSSD_ZRS: 'Standard SSD (zone-redundant)',
               Premium_LRS: 'Premium SSD', Premium_ZRS: 'Premium SSD (zone-redundant)' },
  readDiskType: 'Reading the type of a disk',
  allowNvme:    'Setting NVMe support on the new disk',
  tidyDisk:      'Deleting a disk that the product made from a safety copy and that nothing uses',
  // RESTORE-DIALOG-WORDS-1: a restore that keeps the disk names deletes each current disk.
  deleteCurrentDisk: 'Deleting the current disk to use its name again',
  deleteTempDisk: 'Deleting the temporary disk that the machine used while the name was free',
  // RESTORE-ORIGINAL-DELETE-RESTART-1: Azure refused the delete, so the original OS disk goes back.
  swapOriginalBack: 'Putting the original OS disk back on the machine',
  recoverStart:  'Starting it again after the restore could not finish',
  lockCheck:     'Checking that no resource lock prevents changes',
  readSize:      'Reading the size of the machine after the change',
  reserveZero:   'Setting the on-demand capacity reservation to zero instances',
  guestCheck:    'Running checks inside the machine',
  guestPrepOs:   'Preparing the operating system for NVMe',
  guestPagefile: 'Moving the Windows page file off the temporary disk',
  guestTempDisk: 'Installing the task that prepares the temporary disk at each start',
  // MANA-LINUX-KERNEL-1: the kernel update a person chose for this machine.
  guestKernel:   'Updating the Linux kernel with the package manager of the distribution',
  guestSeed:     'Writing test data to the data disks (rehearsal only)',
  guestVerify:   'Confirming the test data survived the move intact',
  // RUNCMD-REPLAY-1: the read-only script that runs straight after a script that changes the machine.
  guestMark:     'Running a read-only check, so that a restore cannot repeat the last change',
  wavePaused:    'The wave paused itself automatically after repeated failures',
  waveResumed:   'The wave was resumed by an operator',
  waveProgress:  'Wave progress update',
  workerPickup:  'A migration worker started work on this machine',
  workerRecover: 'A worker stopped. Another worker continues its machine.',
  // RESUME-1: the timer started the engine again after an execution stopped.
  waveRestarted: 'The run stopped before this wave finished. The engine was started again.',
  // VERSION-1 / SCALE-UX-1: what the engine says about itself. During a scale
  // drill the feed printed raw step names that read as stray noise -
  // "engine:memory" - because nothing here
  // had words for it. The once-a-minute readings stay in the store for a
  // support bundle and are not shown; the peak is one line a wave.
  engineStarted:    'Engine version {v} started this operation.',
  engineMemoryPeak: 'Memory peak: one worker used {max} MB, with {n} workers running at the same time.',
  decisionMade:  'An operator made the pending decision',
  // MIGRATIONS-DECISION-WORDS-1: the button the operator selected (choice on
  // the decision line). The words were approved 2026-11-14.
  decisionRetry:  'An operator selected Try this machine again.',
  decisionAccept: 'An operator selected Accept this and continue.',
  planStep:      'Planning and assessment',
  // BLOCKED-NAME-1: quota and capacity had no label of their own, so they
  // borrowed the one above and a quota check reported itself as planning.
  // Every event the engine writes under this step is about one of the two:
  // the quota check, stale quota records cleared when sizes change, the
  // capacity gate, and capacity Azure could not give.
  capacityStep:  'Quota and capacity',
  // QUOTA-TRUTH-1: a finished quota check says its result. The heading above
  // hid the one number that mattered when a check found nothing to count.
  quotaAllOk:    'Quota check for {what}: {n} sizes checked, and each has enough quota.',
  quotaShort:    'Quota check for {what}: {short} of {n} sizes do not have enough quota.',
  quotaNone:     'Quota check for {what}: the saved plan has no machine here that changes size.',
  quotaWhatWave: 'wave {wave}',
  quotaWhatPlan: 'the whole plan',
  // STEP-WORDS-1: the fallback for a step that says what it says. Used only
  // when the event carries no sentence of its own, which the engine always
  // writes today - these exist so the raw engine word can never come back.
  acceptedOptions:  'An operator accepted the wave settings',
  targetKept:       'The machine finished the move it started',
  powerReturned:    'The product returned the machine to its power state from before the move',
  // VOLUMES-RESTORE-MIGRATED-1: the line of Check the volumes says the result and who asked.
  volumesChecked:   'The product checked the volumes inside the machine',
  // RESTORE-EARLIER-DELETE-1: the line of Delete these disks names each disk and who asked.
  earlierDisksDeleted: 'The product deleted the earlier managed disks of a restore',
  // MADE-DISK-DELETE-1: the line of Delete these disks now names each disk, each disk kept and why, and who asked.
  madeDisksDeleted: 'The product deleted the managed disks made from the safety copies',
  // ROLLBACK-ORIGINALS-LEFT-1: the line of Delete these disks under Original disks, not in use.
  originalDisksDeleted: 'The product deleted the original disks that a rollback left',
  ackedDrift:       'An operator acknowledged that infrastructure code manages these machines',
  approvedByPerson: 'An operator approved a wave or an assessment',
  targetOptions:    'The engine wrote the target options for each machine',
  targetsSaved:     'An operator saved the target for each machine',
  // MACHINE-PICK-1
  machinesSaved:    'An operator chose the machines for the migration',
  claimChanged:     'A machine changed hands between runs',
  driverChecked:    'The engine checked the network driver',
  precheckNote:     'The engine checked this machine before migrating it',
  putBackNote:      'The product checked the retirement date of the size that the machine returns to',
  rearmed:          'The machine was set to start again from an earlier step',
  copiesReviewed:   'The safety copies were reviewed for deletion',
  copiesKept:       'The safety copies of the earlier attempt were kept',
  runStopped:       'An operator stopped the run',
  // DISCARD-ENGINE-1: the delete of a migration and its safety copies.
  migrationDeleting: 'An operator started to delete this migration and its safety copies',
  copyNotDeleted:   'The engine worked on one safety copy of this migration',
  // SKIP-ONE-1: the event carries who and why, so the detail IS the sentence.
  // This is the fallback for a record that lost its detail.
  vmLeftOut:        'An operator left this machine out of the migration',
  scheduleChanged:  'The wave schedule changed',
  reportStep:    'The engine wrote the report of the migration',
  recordStep:    'The product wrote the record of the migration',
  // APPROVE-GROUP-1: the status the list of migrations reads.
  statusStep:    'The engine wrote the status of the migration for the list of migrations',
  quotaStep:     'A quota increase was requested',
  quotaPreviewStep: 'The engine made a preview of the quota increase requests. It filed no request.',
  // QUOTA-FILED-WORDS-1: the answer to Request, which the wave editor waits for.
  quotaResultStep: 'The engine sent the quota increase requests to Azure.',
  // QUOTA-REQUEST-POLL-1: the answer of Azure to one filed request.
  quotaAnswerStep: 'The engine read the answer of Azure to a quota increase request.',
  netFabric:     'Checking that accelerated networking is in use',
  failedNote:    'Open the machine to see why this step failed.',
  // A run-level failure has no machine to open: the timer that releases
  // schedules or restarts stopped waves writes these. Without this, two red
  // "schedule" lines pointed at a machine that was not there.
  //
  // LOG-SAYS-WHY-1: it used to read "this failed. The line says what
  // happened." Two sentences where one belongs, and "the line" named nothing
  // - it pointed the reader at the line they were already reading. The reason
  // is now always shown beside it, so the pill only has to say what it is.
  failedNoteRun: 'This step failed.',
  // STATUS-WORDS-1: a failure that a rollback follows says what happens next.
  rollsBackNote: 'The product now rolls the machine back. You do not need to do anything.',
  // LOG-SAYS-WHY-1: a gate that refuses is this product working. It must not
  // wear the badge a breakage wears.
  refusedNote:   'This product refused this action.',
  // RETRY-UI-1. Kept VISIBLE - a machine that needed three attempts is worth
  // knowing about - but it must not read as an error that still stands.
  recoveredNote: 'failed once, then succeeded on retry',
  // ACTIVITY-LINES-1: an attempt of a step that the engine tries again. It is
  // information, never a failure: the step goes on.
  retriedNote:     'Attempt {n} of {max} failed. The product tries the step again.',
  retriedNoteBare: 'This attempt failed. The product tries the step again.',
  warnNote:      'note',
  progressMark:  'The engine recorded that this step of the move is complete',
  restoreDone:   'The machine was restored from the safety copy taken before it was migrated',
  restoreStart:  'Restoring the machine from the safety copy taken before it was migrated',
  restoreWarn:   'The restore did not finish. The machine was restarted and is running.',
  restoreFailed: 'The restore failed, and the machine could not be restarted. It needs attention.',
  // SWAP-REFUSED-AFTER-STOP-1: Finish the rollback, or Finish the restore.
  finishStart:   'Swapping the data disks that are left back to the disks made from their copies',
  finishDone:    'The data disks that were left are back, and the machine started',
  finishFailed:  'Azure did not swap every data disk back. The machine is still stopped.',
  azureCall:     'Working with Azure',
};
const UX_PATH = { A: 'In-place upgrade' };
// MANUAL-WHY-1: a machine the plan does not move says why. The reasons are
// where the product already keeps them: the findings of the scan for the
// series of the machine (judgeForSeries, as the found-machines table reads
// them), the words for a machine that is not eligible or already moved, and
// the notes of the plan (planNotes) - one list, each reason once.
function notMovedReasons(entry) {
  if (!entry || !['MANUAL', 'EXCLUDED'].includes(entry.path)) return null;
  const a = entry.assessment ?? {};
  const j = judgeForSeries(a, entry.policy?.targetGeneration);
  const out = [];
  if (j.classification === 'Excluded') out.push(UX_FOUND.Excluded[1]);
  else if (entry.path === 'EXCLUDED') out.push(UX_MISC.notMovedAlready);
  out.push(...[...(j.blockers ?? [])].map(reasonText));
  out.push(...(entry.planNotes ?? []).map(String));
  return [...new Set(out.filter(Boolean))];
}
// The status in the row for such a machine: Not moved, the reasons on hover.
function notMovedPill(reasons) {
  return `<span class="pill quiet" title="${esc(reasons.join('; ') || UX_MISC.notMovedNoReason)}">${esc(UX_MISC.notMoved)}</span>`;
}
function notMovedHtml(entry) {
  const why = notMovedReasons(entry);
  if (!why) return '';
  return `<div class="card"><div class="pad"><strong>${esc(UX_MISC.notMovedTitle)}</strong>
    ${why.length ? `<ul>${why.map(r => `<li>${esc(r)}</li>`).join('')}</ul>` : `<div class="muted">${esc(UX_MISC.notMovedNoReason)}</div>`}</div></div>`;
}
// WAVE-2: the levers, in plain words. Shown in the acceptance modal so a
// person reads what they are agreeing to before they agree. (No apostrophes
// in these comments - the plain-language lint pairs single quotes.)
const UX_LEVER = {
  safetyCopy:      'Snapshot of every disk before anything is changed',
  // WAVE-WORDS-3: each setting and each value has the name the wave editor
  // gives it, on this dialog and at Run it. The longer answer is helper text
  // under the value (the ...Hint strings), never a second name.
  safetyCopyAlways:'Always taken',
  safetyCopyHint:  'Any failure rolls the machine back to exactly how it was.',
  capacityGate:    'On-demand capacity reservation for this wave',
  // WORDS-1, 2026-09-21: On-demand is the Azure name for a capacity
  // RESERVATION, so it names the option that makes one. WAVE-WORDS-3: the
  // option with no reservation is No, and the option that makes one is Yes. Pay as you go is a way Azure bills,
  // and a machine on a reservation is billed that way too.
  capOnDemand:     'No',
  capOnDemandHint: 'Azure allocates the machines when the wave runs, and can refuse when it has no capacity for the size.',
  capReserved:     'Yes',
  capReservedHint: 'The product reserves the capacity before the wave starts. Azure bills it until every machine of the wave has ended and the product releases it, or until you select Release.',
  requireApproval: 'Someone must sign off before this wave runs',
  yes:             'Yes',
  no:              'No',
  onDDataFound:    'If files are found on the temporary disk',
  dataStop:        'Stop and ask',
  dataStopHint:    'The machine stops with a decision for a person. Nothing is lost unless a person decides.',
  dataProceed:     'Continue - the files are deleted',
  // REBUILD-REMOVE-ACCEPT-1: the setting for a system-assigned identity and
  // its list of machines are gone with the rebuild. The word for an empty row
  // stays: the other lists of machines use it.
  identityNone:     'None in this wave',
  anMachines:       'Machines that get accelerated networking turned on',

  // WAVE-AN-NAMES-1: the machines whose move decides it, named on their own row.
  anDecidesMachines: 'Machines where the move decides accelerated networking',
  // AN-MANA-DRIVER-RULE-1: no kernel keeps it off now; only interfaces the scan did not read.
  anDecidesHint:    'The scan did not read the network interfaces of these machines. The move reads them, then turns accelerated networking on for the primary network interface.',
  // MANA-LINUX-KERNEL-1: chosen per machine on the targets step.
  kernelMachines:   'Machines whose kernel the product updates if it has no MANA driver',
  // EOL-RELEASE-AN-1: an approver accepted the release of these machines at Checking.
  eolMachines:      'Machines whose Linux release an approver accepted after the end of standard support',
  // WAVE-OPTIONS-DISKS-1: the type the move of each machine changes its disks to,
  // in the names Azure uses - the words of the targets step.
  diskMachines:      'Machines whose disks change to Standard SSD or Premium SSD',
  diskMachine:       '{name} ({type})',
  diskStandardSsdOs: 'Standard SSD: OS disk',
  diskPremiumOs:     'Premium SSD: OS disk',
  diskPremiumAll:    'Premium SSD: every disk',
  // PLAN-NOTES-RUNPAGE-1: the notes the plan wrote for each machine that
  // moves - the name the migration record gives them.
  planNotes:         'Plan notes',
  // ROLLBACK-CAPACITY-1 and FILTER-DRIVER-READ-1: the lines under the table,
  // each only for a wave it is true of - the words of Run it in the wizard.
  capacityNoGuarantee: 'Microsoft restricts capacity growth for the original size series of a machine in this wave. The product does not guarantee capacity for the new size. On a rollback, the product does not guarantee capacity for the original size.',
  nvmeThirdParty:    'Microsoft says: "Customized VMs that run third-party software capable of modifying boot-time behavior, storage drivers, filter drivers, or disk enumeration aren\'t currently a supported migration scenario."',
  nvmeThirdPartyWhat: 'If such a machine moves to NVMe, the move can fail. Then the product rolls the machine back. To keep SCSI, choose v5 for that machine.',
  // DISK-PATH-READ-1: the words of Run it in the wizard.
  nvmeDiskPaths:     'On Linux, the product checks the mounted volumes and the fstab file. The product does not check application settings that name a disk by a device path. Examples are /dev/sdc and a link under /dev/disk/azure/scsi1. Before the move, check these settings. Microsoft tells you to use a UUID in them.',
  // SQL-TEMPDB-SIGNOFF-1: the words of Run it in the wizard.
  sqlTempdb:         'SQL Server runs on {names}. The target size of each has an NVMe temporary disk or no temporary disk. If tempdb is on the temporary disk, SQL Server can fail to start after the move.',
  targetGen:       'Machine size series the machines move to',
  genV5:           'v5 - a resize that keeps the SCSI disk controller.',
  genV6:           'v6 - the current series',
  // ADVISOR-1: a wave can hold machines on several series.
  genMixed: 'Mixed: {parts}',
  genCount: '{n} on {series}',
  genV7:           'v7 - the newest series, where the region has it.',
  // BSV2-TARGET-1: a B v1 machine on a Bsv2 size, planned on v5.
  genBsv2:         'Bsv2 - a burstable size with CPU credits, on the SCSI disk controller.',
  keepDays:        'How long the snapshot is kept',
  atOnce:          'How many machines at once',
  keepDaysNever:   'Deleted by the next daily cleanup after the machine is migrated',
  keepDayOne:      '1 day after the machine is migrated',
  keepDaysMany:    '{n} days after the machine is migrated',
};

// RETAIN-UX-1: the safety copies, and what the daily cleanup will do with
// them. Nothing anywhere traced what was pending, so a person could not tell
// what the cleanup would remove or when.
const UX_COPIES = {
  title:        'Safety copies',
  hint:         'A rollback or a restore of a machine uses these copies. They are kept until its wave\'s retention ends, then deleted by the daily cleanup.',
  colWave:      'Wave',
  /* TABLE-SCALE-1: the table is one row per wave now, so the machine column
   * became a count, and the machines themselves sit behind a control that
   * opens AND closes. `colMachine` went with it - the per-machine rows carry
   * the name in the wave's own first column. */
  colMachines:  'Machines',
  showMachines: 'Show',
  hideMachines: 'Hide',
  keepVaries:   'varies by machine',
  statusVaries: '{n} different outcomes - open the wave',
  // PAGE-SCALE-REPORTS-1 fix round: each count says 1 in the singular
  // (VmfHelp.countWords picks the first word of a pair for 1).
  summary:      '{copies} for {machines}. {protected}',
  nCopies:      ['{n} copy', '{n} copies'],
  nMachines:    ['{n} machine', '{n} machines'],
  summaryAllLocked:    'All are protected.',
  summarySomeUnlocked: ['{n} is not protected.', '{n} are not protected.'],
  colCopies:    'Copies',
  colLocked:    'Protected',
  colKeep:      'Kept for',
  colStatus:    'What happens next',
  none:         'No safety copies are kept for this migration.',
  keepDaysUnit: '{n} days',
  keepUnknown:  'unreadable',
  lockedAll:    'Locked',
  lockedNone:   'Not locked',
  lockedPart:   '{n} of {m} locked',
  lockedTip:    'A lock stops a person or a script with Contributor rights from deleting the copy. The product removes it when the retention ends.',
  unlockedTip:  'This copy carries no lock. Anyone with Contributor rights can delete it.',
  statusWaiting:    'Kept until {date}. Then the daily cleanup deletes it.',
  statusDue:        'Due. The next daily cleanup deletes it.',
  statusInUse:      'In use. The machine is not migrated yet, so its copies stay.',
  statusUnreadable: 'Kept. The retention setting for this wave could not be read.',
  statusRestoreRuns: 'Kept. A restore of this machine runs, or starts again after its job stopped.',
  statusFinishRuns: 'Kept. Finish the rollback or Finish the restore of this machine runs, or starts again after its job stopped.',
  statusRestoreStopped: 'Kept. A restore of this machine stopped and did not finish, and the machine needs a person. Look at it in Azure, then restore it.',
  statusDeleted:    'Deleted on {date}.',
  passNone:     'The daily cleanup has not run since this installation started. It runs every day at 03:30 UTC.',
  passLine:     'Last daily cleanup {ago}: {examined}, {due}, {started}.',
  // The same words as the Safety copies box on the Reports page.
  nExamined:    ['{n} migration checked', '{n} migrations checked'],
  nExaminedOf:  ['{n} of {total} migration checked', '{n} of {total} migrations checked'],
  nDue:         ['{n} machine due', '{n} machines due'],
  nStarted:     ['{n} cleanup started', '{n} cleanups started'],
  passFail:     'The last daily cleanup reported a problem: {reason}',
  nextPass:     'Next cleanup at {when}.',
  // RETENTION-CARD-CYCLE-1: the daily cleanup is a cycle of hourly passes.
  passOpen:     'The daily cleanup that started {ago} is not complete: {examined}, {due}, {started}.',
  nextPassOpen: 'The next hourly pass continues it at {when}.',
};
// QUOTA-FAMILY-1: the quota card. One row for each quota family and region,
// because that is what one quota is. The headings are built at render time,
// as the copies headings are, because the reservation columns come and go.
const UX_CAP = {
  colFamily:      'Quota family and region',
  colSizes:       'Sizes',
  sizeInZone:     '{size} in zone {zone}',
  colNeeded:      'vCPUs needed',
  colNeededTip:   'The vCPUs that the plan needs from this quota in this region, at the newest quota check. For Total Regional vCPUs, it is the vCPUs that the machines add to their old sizes.',
  colFree:        'vCPUs free',
  colFreeTip:     'The quota limit minus the vCPUs in use, at the same quota check.',
  colQuota:       'Quota',
  // RES-LIST-1: the card title and its lists, with the name Azure uses: on-demand
  // capacity reservation. With no wave in view that uses one, the card is Quota.
  titleBoth:      'Quota and on-demand capacity reservations',
  hintBoth:       'A quota limits how much you may run. An on-demand capacity reservation holds hardware for you. Rows with a problem come first.',
  titleQuota:     'Quota',
  hintQuota:      'A quota limits how much you may run. One row for each quota family and region, and one for the Total Regional vCPUs of each region. Rows with a problem come first.',
  quotaListHint:  'One row for each quota family and region, and one for the Total Regional vCPUs of each region.',
  resTitle:       'On-demand capacity reservations',
  resHint:        'One row for each wave and size.',
  colWave:        'Wave',
  colSize:        'Size',
  colState:       'State',
  colFact:        'Details',
  sizeInRegion:   '{size} in {region}',
  familyUnknown:  'Quota family not known',
  familyUnknownHint: 'Azure did not give a quota family for this size in this region. The product does not guess a family from the size name.',
  inSubscription: 'subscription {id}',
  // REGIONAL-VCPU-QUOTA-1: the name Azure gives the quota of all vCPUs in a region.
  regionalName:   'Total Regional vCPUs',
  regionalHint:   'The quota of the subscription for all vCPUs in this region, for each size family together. Each machine adds the vCPUs of its new size minus the vCPUs of its old size.',
  regionalUnknown: 'Quota not known',
  regionalUnknownHint: 'Azure did not report the Total Regional vCPUs quota of this region, so the product did not check it.',
  none:           'No capacity records for this run.',
};

// Lever 7: the retention is only a promise if something enforces it. It does
// now - so this row states the real number of days, and 0 says plainly what
// zero means rather than reading as "kept".
// WAVE-WORDS-3: the rule is in help.js, so Run it says the same words.
function leverKeepDays(days) {
  return VmfHelp.keepDaysText(days, UX_LEVER.keepDaysNever, UX_LEVER.keepDayOne, UX_LEVER.keepDaysMany);
}

// FIRSTRUN-1: the three prerequisites, in plain words. Every one of them is
// something this page can actually CHECK, which is what makes this an answer
// rather than a leaflet.
const UX_FIRST = {
  title: 'Nothing to show yet',
  body: 'No migration has started here. Three things must be true before migrations show on this page. Each item below shows its status.',
  chkSignedIn: 'You are signed in',
  fixSignedIn: 'Sign in with the account your organisation gave access to.',
  chkRole: 'You have been given a role in the product',
  fixRole: 'A user with the Administrator role gives you a role on the Admin page. The install gives the Administrator role only to the user who runs the install.',
  chkStore: 'You can read the migration records',
  // STORE-READ-1: this used to name Storage Blob Data Reader, because a person
  // needed a SECOND permission in Azure to read the records. They no longer do
  // - the service reads them, with its own identity - so the role above is the
  // only thing that decides. What is left here is an ordinary failure: the
  // service did not answer.
  fixStore: 'The service did not answer. Wait a moment and open this page again. If it keeps happening, tell an administrator.',
  allGood: 'All three are in place. Start a migration to see it here.',
  notYet: 'Until each item above has a check mark, this page stays empty, even when migrations exist.',
};

const UX_MISC = {
  // DEPLOY-MSG-RULE12-1: it said to run Deploy-VmfDashboard.ps1 (hard rule 12).
  msalMissing:   'The sign-in file msal-browser.min.js did not load. Install the product again, or make sure that your browser does not block this file.',
  // WAIT-1: the run picker reads the whole store, one manifest per run.
  // Until that lands it named a count it had not counted, which is a
  // statement about what somebody has, made before looking.
  waiting:       'Reading your migrations.',
  noRuns:        'no migrations',
  /* WAIT-2: the page body, not only the picker.
   *
   * WAIT-1 gave the run PICKER a waiting state and stopped there. The body
   * stayed empty for as long as the read took - measured at ten seconds on a
   * real install, 2026-09-18 - with no sign that anything was happening.
   *
   * An empty table and a table that is still being filled look the same, and
   * the first thing somebody does with a page that looks broken is press
   * things. So each region says what IT is reading, because five regions all
   * saying "Loading" tell nobody which one is slow - the rule help.js sets out
   * beside waitingLine. */
  readingWaves:    'Reading the machines in this migration run.',
  readingCapacity: 'Reading the quota and the on-demand capacity reservations for this run.',
  readingCopies:   'Reading the safety copies for this run.',
  readingActivity: 'Reading the activity for this run.',
  /* RUNROW-1: the word that stops a project reading as a run of its own. */
  rowProject:      'Project',
  // LOG-1: the footer under the activity feed.
  logShowAll:    'Show the whole log',
  logShowRecent: 'Show the latest {n}',
  logRecentOf:   'The latest {n} of {total} lines',
  logAllOf:      'All {total} lines, newest first',
  optionsAcceptedBy: 'Options accepted by',
  optionsNotAccepted: 'Options not yet reviewed',
  optionsChanged: 'Settings changed since they were accepted',
  /* WAVE-GATE-1: "Not in a wave yet" reads as an oversight - it looked as if
   * two machines had "snuck through". Nothing snuck: `New-VmfPlan` gives a
   * wave only to a machine with an executable path and parks the rest here on
   * purpose. Say that, so the next action is clear. */
  /* AVSET-WAIT-1: the wave editor already calls these machines "moves with
   * its pair". This is the same fact on the run page, with the part the
   * editor has no need to say - that this one is waiting for the other. */
  pairWait: 'waits for its pair',
  pairWaitTip: 'This machine shares an availability set with one that is migrating now. The product moves them one at a time, so both are never down together.',
  // PUTBACK-COUNT-1: a put-back is not a migration, and it is the most
  // important safety outcome this product has, so it is counted, not hidden.
  putBackCount: '{n} restored',
  // PUTBACK-TILE-1: its own tile, beside Migrated.
  putBackTile: 'Restored',
  putBackTileSub: 'restored from a safety copy by a person',
  // PLANRUN-1: a signed-off plan starts its next wave on its own.
  planSignedBy: 'Plan signed off by {who}',
  startsAfter:  'Starts when {wave} finishes',
  // STARTS-SOON-WORDS-1: the service starts it on a check, every 5 minutes,
  // and a check of a large store takes more than one pass (TIMER-PASS-LIMIT-1).
  // WAVE-ORDER-START-1 (lab Session A, finding 24): the line says when, and
  // the note says the outcome - not how the service divides its checks.
  // "About" and "can take longer" keep it true for a large store.
  startsSoon:   'Starts within about 5 minutes',
  startsSoonHelp: 'The service starts the wave at its next check. It checks every 5 minutes. When many migrations wait, it can take longer.',
  startsSoonHelpTip: 'About the next check',
  // WAVE-ORDER-START-1 (finding 17): a machine a decision sent back waits
  // for the next check of the service; nothing works on it until then.
  waitsCheck:   "Waits for the service's next check",
  waitsCheckTip: 'Nothing works on this machine now. The service starts it again at its next check.',
  // RETRY-WAIT-SAYS-WHY-1 (final lab, 2026-11-16): the service starts no wave
  // while a worker of another wave or a restore holds the run, nor a wave that
  // fails a start gate. Its resume line says which (Write-VmfResumeHoldLine),
  // and these say it in place of the 5 minutes. {reason} is the words of the gate.
  waitsWave:    'Waits for wave {wave} to finish',
  waitsWaveTip: 'Nothing works on this machine now. When wave {wave} finishes, the service starts this machine again at its next check.',
  waitsAnyWave: 'Waits for a running wave to finish',
  waitsAnyWaveTip: 'Nothing works on this machine now. When the running wave finishes, the service starts this machine again at its next check.',
  waitsRestore: 'Waits for a restore to finish',
  waitsRestoreTip: 'Nothing works on this machine now. When the restore finishes, the service starts this machine again at its next check.',
  waitsGate:    'Wave {wave} cannot start yet',
  waitsGateTip: '{reason} Then the service starts this machine again at its next check.',
  // BRAKE-WAIT-WORDS-1: the same wait while the wave safety brake holds the
  // migration. The check of the service starts nothing then: only Resume does.
  waitsResume:  'Waits for Resume',
  waitsResumeTip: 'The wave safety brake paused this migration. Nothing starts this machine until an operator selects Resume on the Wave safety brake card.',
  // WAVE-RUNNING-LEASE-1: a worker stopped after its machine finished, and its
  // hold stays. The engine refuses a change to the wave until the service
  // removes the hold at its next check (STALE-WAVE-HOLD-1).
  endedHold:    "Waits for the service to remove a stopped worker's hold",
  // WAVE-RUNNING-LEASE-1 review: the leases listing failed, so the page does
  // not know which waves run. The same sentence as on the wave editor.
  leasesUnread: 'Could not read which machines a job holds now, so this page does not show which waves run. {reason}',
  planHeld:     'Waits until a machine in this plan that needs a person is dealt with',
  notInAWave: 'Not moved',
  notMoved: 'Not moved',
  notMovedTitle: 'Why this machine is not moved',
  notMovedNoReason: 'The plan records no reason for this machine.',
  notMovedAlready: 'This machine is on the size series of its target already.',
  notInAWaveWhy: 'The plan does not move these machines. Each one says why.',
  continueSetup: 'Continue setup',
  reserved:   'Reserved',
  // WAVE-WORDS-4: a record that stands for no reservation in Azure says what the
  // wave is set to. No is the value name, UX_LEVER.capOnDemand, as in the wave
  // editor. A wave set to reserve that has no reservation yet says Not reserved.
  bestEffortHint: 'On-demand capacity reservation for this wave is No. Azure allocates the machines when the wave runs.',
  notReserved: 'Not reserved',
  // The pill of a wave whose setting is No: its own string, so a change to one pill never changes the other.
  bestEffortPill: 'Not reserved',
  notReservedHint: 'On-demand capacity reservation for this wave is Yes, and Azure holds no on-demand capacity reservation for it. Select Reserve capacity in the wave editor.',
  notReservedBlockedHint: 'On-demand capacity reservation for this wave is Yes, and Azure holds no on-demand capacity reservation for it. First correct what the Quota column shows.',
  capacityGateUnknown: 'The plan has no machine in this wave, so the page cannot show its capacity reservation setting.',
  quotaWhen:      'checked',
  reservedIdleHint: 'An on-demand capacity reservation bills whether or not a machine is using it. If the wave has finished, release it.',
  reservedInUseHint: 'Machines of this wave use the on-demand capacity reservation.',
  released:   'Released',
  // RESERVING-STUCK-1: a create still running, and one nobody is making any more.
  reserving:  'Reserving...',
  reservingHint: 'Azure is creating the on-demand capacity reservation.',
  unconfirmed: 'Not confirmed',
  // ODCR-STATUS-1: the fact is in the cell, beside the pill, and Release is
  // beside it for an operator while no machine of the wave is at work. The
  // hover says why, with the quota fact measured 2026-11-11.
  unconfirmedHint: 'Azure did not report this on-demand capacity reservation as made. An on-demand capacity reservation uses vCPU quota and bills, also when no machine uses it.',
  unconfirmedNote: 'Azure did not confirm it. It can still bill.',
  // RES-LIST-1: the shortest form of the counts of a reservation that Azure holds.
  reservedCounts: '{used} in use, {idle} idle',
  releaseBtn: 'Release',
  releaseTip: 'Releases the on-demand capacity reservation of this wave. Azure stops the charge for it.',
  quotaOk:    'Headroom verified',
  quotaReq:   'Increase requested',
  quotaShort: 'Not enough quota',
  // REGIONAL-VCPU-QUOTA-1: the size family has the vCPUs, and the region does not.
  quotaRegionalShort: 'Not enough Total Regional vCPUs quota',
  osUnknown: 'operating system not reported',
  osUnknownVersion: '(version not reported)',
  showSettled: 'settled machines',
  showThem: 'Show them',
  hideSettled: 'Hide settled',
  collapseWave: 'Hide machines',
  expandWave: 'Show machines',
  waveAllSettled: 'nothing here needs anyone',
  quotaRestricted: 'This size is restricted here',
  quotaSizeMissing: 'This size is not offered here',
  quotaReservationFailed: 'On-demand capacity reservation failed',
  // BLOCK-SAY-1. THIS IS THE FALLBACK, and it must not name a cause.
  //
  // Every reason the engine writes has its own words below, so this is
  // reached only by a record that carries NO reason - an older one, or a
  // damaged one. It said "Capacity blocked": vague, and true. WORDS-1 made it
  // "Not enough quota", which is a specific claim about something nobody
  // measured, and wrong for a record blocked by a failed reservation.
  //
  // Vague is not the failure here. Saying a thing you did not measure is.
  quotaBlocked: 'Blocked, reason not recorded',
  quotaUnknown: 'Quota not known',
  quotaUnknownHint: 'Azure did not report this quota family, so the product could not read the available vCPUs.',
  // CRG-MOVE-DEMAND-1: a machine the assessment found in a capacity
  // reservation group this migration did not make. {names} are the machines.
  ownGroupNoteOne: '1 machine stays in its own capacity reservation group: {names}.',
  ownGroupNote:    '{n} machines stay in their own capacity reservation group: {names}.',
  ownGroupHint:    'The move keeps a machine in the capacity reservation group it is in. The on-demand capacity reservation of the wave holds no place for it.',
  servedNote: 'Used by {n} before the release.',
  approvedBy: 'Approved by',
  waitingApproval: 'Waiting for approval',
  gateText:   'Approval gate. The next wave starts only after this wave is reviewed and signed off.',
  // PLANRUN-1: a signed-off plan has no gate between waves - one follows the next.
  // Not "the wave above": this page sorts waves by name, which is not the order of the plan.
  gateTextPlan: 'The plan is signed off. Each wave starts when the wave before it in the plan finishes.',
  stuckHint:  'in this step for more than 15 minutes',
  // WAVE-ROW-WORDS-1: when a step started, on the hover of the pill.
  startedAgo: 'Started {ago}',
  // VERIFY-FP-1 part 3: a guest run that only read the machine for the record.
  guestReading:    'Reading',
  guestReadingTip: 'The product read the machine before the move, for the evidence record. This reading is not a check.',
  guestRunning:    'Running',
  guestRunningTip: 'This script runs inside the machine now.',
  guestStarted:    'No answer',
  guestStartedTip: 'The product started this script and received no answer. The script can have changed the machine.',
  // STATUS-WORDS-1: what a machine is now, during a rollback or a restore.
  // The status said the step that failed for the whole rollback.
  statusRollingBack:    'Rolling back',
  statusRollingBackTip: 'A step failed. The product rolls this machine back to how it was before the migration.',
  statusFinishingRestore:  'Finishing the restore',
  statusFinishingRollback: 'Finishing the rollback',
  statusFinishingTip:   'The product swaps the data disks that are left back, then starts the machine.',
  statusFinishRollback:    'Stopped: finish the rollback',
  statusFinishRollbackTip: 'Azure did not swap every data disk back, so this machine is stopped. Open it and use Finish the rollback.',
  // STATUS-WORDS-1: a wave that ended with a machine rolled back. It waits
  // for nobody, and the next wave does not wait for it.
  waveFinishedRolledBack: 'Finished: {n} rolled back',
  // STOP-STATE-SHOWN-1: a wave and the Wave safety brake card of a migration
  // that a person stopped (stopped.json, schemas/run-stop.schema.json).
  waveStoppedBeforeStart: 'Stopped before it started',
  waveStopped:  'Stopped',
  brakeStopped: 'Stopped',
  brakeStoppedSub: 'an operator stopped this migration',
  waveRolledBackNames:    'Rolled back: {names}. Open a machine to choose what to do with it.',
  rolledBackTile:    'Rolled back',
  rolledBackTileSub: 'back as they were, after a step failed',
  // STATUS-WORDS-1: a time on the timeline is the time of the step before
  // the line. "Shutting down took 765s" was 13 minutes of checks on a
  // running machine; the shutdown took 36 seconds.
  tookStep: '{step} took {n} s',
};
/* STATUS-WORDS-1: the work that a duration on the timeline measures, by the
 * step that ran. A line of the timeline names the step that starts, and its
 * duration is the time the step before it took. Only a step of the move has
 * a duration worth a line: the time a machine waited for its turn is none. */
const UX_RAN = {
  PRECHECK:        'Checking',
  SAFETY_PRISTINE: 'Taking the first safety copy',
  GUEST_PREP:      'Checking and preparing the machine',
  STOPPED:         'Shutting down',
  SAFETY_COPY:     'Taking the second safety copy',
  CONVERTING:      'Moving',
  STARTING:        'Starting up',
  VALIDATING:      'Verifying',
};
const UX_ACT = {
  // STRING-SWEEP-1: these three live HERE because every read of them says
  // UX_ACT. They were declared in UX_MISC, so all three were undefined at
  // runtime - the refusal watcher threw on .replace() instead of reporting
  // the refusal, and startBlockedBy went falsy, which put a Start button on
  // an unaccepted wave with no reason beside it. That is EVAL-H9 again,
  // undone by a key in the wrong object.
  /* ACK-GATE-1: the FIRST thing the engine checks, and the page did not know
   * about it. The statement is the wizard's, word for word - one question
   * asked in two places must not be two different questions. */
  startNeedsAck: 'Someone must accept the note about machines defined in code before any wave can start',
  ackTitle:     'Machines defined in code',
  // IAC-NOTE-LIST-1: the same words as iacLead, iacChanges and iacAfter in the wizard, word for
  // word (approved 2026-11-08); iac-note-list.test.js holds them equal.
  ackLead:      'Terraform, Bicep, Pulumi, ARM templates and Ansible keep their own definition of each machine. This migration makes these changes, and those definitions do not know about them:',
  ackChanges: [
    'The size of the machine changes.',
    'A move to v6 or v7 changes the disk controller from SCSI to NVMe.',
    'A move can change accelerated networking.',
    'A move can change the disk type to Standard SSD or Premium SSD.',
    'A rollback or a restore puts the machine on new disks, made from its safety copies. A restore can keep the disk names.',
  ],
  ackAfter:     'The next apply can undo these changes, or replace the machine. Reconcile your definitions after the migration.',
  ackAccept:    'I understand, and I will reconcile our definitions after the migration.',
  ackMissing:   'Select the checkbox to accept the note before this run can start.',
  ackBtn:       'Accept and let this run start',
  ackDone:      'Accepted. The waves in this run can be started now.',
  startNeedsAccept: 'Review and accept the settings before this wave can start',
  startNeedsApproval: 'This wave needs sign-off before it can start',
  // WAVE-GATE-1: a state to wait out, not a gate to satisfy. The other three
  // sentences tell a person what to go and do; this one must not, or it sends
  // them to fix a thing that is not broken.
  startAlreadyRunning: 'This wave is running now',
  refused: 'It did not start: {reason}',

  menuBtn:      'Assess an estate',
  enableBtn:    'Turn on approvals and controls',
  newRun:       'Scan for machines to migrate',
  buildPlan:    'Build the migration plan',
  approve:      'Approve',
  acceptOptions: 'Review & accept options',
  acceptOptionsTitle: 'Accept how this wave will run',
  acceptOptionsEdit: 'Change these settings instead',
  acceptOptionsConfirm: 'Accept',
  acceptOptionsDesc: 'These are the settings this wave will run with. Accepting them is recorded with your name - and if the wave is edited afterwards, it must be accepted again.',
  // ACCEPT-HASH-1: the table is read at the moment the dialog opens, and the
  // acceptance is bound to those exact settings. This is what a person sees
  // when somebody changed the wave while they read it.
  acceptOptionsStale: 'The wave changed while you read it. The settings are not accepted. Look at the wave again, then accept it.',
  approveTitle: 'Approve this wave',
  approveDesc:  'Your sign-off lets this wave proceed. Your name and note are recorded with the approval.',
  // APPR-2: say what is being signed. The approver could only see a table that
  // is as new as the last refresh; this count is read at the moment the dialog
  // opens, and it is the count the signature is bound to.
  approveCovers: 'You approve {n} machines in wave {w}.',
  // REBUILD-REMOVE-RECOVER-1: no restore rebuilds a machine, so no restore
  // deletes an identity and none asks to accept that.
  restoreSiteRecovery: 'Site Recovery replicates this machine. A restore that swaps disks stops this replication. After the restore, disable replication and enable it again.',
  approveStale:  'The plan changed while you read it. The wave is not approved. Look at the wave again, then approve it.',
  startWave:    'Start this wave',
  startWaveDesc:'Begins migrating the machines in this wave, a few at a time. Progress appears here as it happens.',
  pause:        'Pause new work',
  stopRun:      'Stop this migration',
  stopRunTitle: 'Stop this migration',
  stopRunDesc:  'This ends the migration of every machine that has not finished, so that you can delete the migration. It changes nothing in Azure, with one exception. When the product changed only the power state of a machine, it returns the machine to that power state. Machines that already finished keep their result. A wave that did not start does not start after this. Its machines are left out, and the product does not change them. Every other machine is free for another migration. A machine that is not as it was before the move is not free for another migration.',
  discardRun:   'Delete this migration',
  discardRunTitle: 'Delete this migration',
  discardRunDesc:  'This deletes the record of this migration: what was planned, what happened to each machine, and the log. Your machines are not touched: none is started, stopped or changed. It cannot be undone.',
  discardCopies:   'Some things here are in Azure. Before each machine moved, the product took a safety copy of it, so that it can roll the machine back. A rollback and a restore also make disks from the copies. The copies, and those disks that no machine uses, cost money. This record is the only thing that knows they exist.',
  discardKeepCopies:   'Keep the copies. I will find them, and the disks made from them, and remove them myself.',
  discardDeleteCopies: 'Delete the copies as well. The product also deletes each disk made from them that no machine uses. Nothing will be left to restore a machine from.',
  /* DELETE-CHANGED-FREED-1 (ruling 2026-11-06): said only when a
   * machine of the migration is left changed (machineLeftChanged). The engine
   * keeps its safety copies whichever choice is made (Test-VmfRunDiscardable). */
  discardChanged: 'These machines are not as they were before the move: {names}. The product keeps their safety copies, also if you select Delete the copies as well.',
  pauseDesc:    'No new machines will start. Machines that are moving finish their current step.',
  // ODCR-STATUS-1: Release beside a capacity reservation nobody confirmed. The
  // release operation of the engine, as the wave editor starts it.
  releaseTitle:   'Release the on-demand capacity reservation',
  releaseDesc:    'The product releases each on-demand capacity reservation of wave {wave}. Azure stops holding the capacity and stops the charge for it. Machines of the wave that wait for a decision or a retry lose the capacity it held for them. To reserve again, check the quota on the wave, then reserve.',
  releaseStarted: 'The engine releases the on-demand capacity reservation of wave {wave}. The Quota and on-demand capacity reservations card shows the result when the engine ends.',
  resume:       'Resume',
  resumeDesc:   'New machines can start again where the run left off.',
  rowDecide:    'See what to do',
  resolve:      'Try this machine again',
  // SAFETY-RETRY-1: when it stopped and why, then what a retry does.
  resolveDesc:  'The whole move runs again from the first step, with new safety copies.',
  // VOLUMES-RETRY-CHECK-1: said in place of resolveDesc while the record owes a check of the volumes.
  resolveVolumesFirst: 'The product first checks that every volume mounted before the move is mounted again. Only then does the move run again, with new safety copies.',
  resolveStopped: 'Stopped',
  resolveReason:  'Reason',
  // ROLLBACK-RETRY-CAPTURE-1: said in place of Try this machine again, which the engine refuses here.
  retryHeld:      'The last stop left this machine changed. Restore it first, then you can try it again.',
  // SWAP-REFUSED-AFTER-STOP-1: said in its place when a refused data disk swap keeps the machine stopped.
  retryHeldSwap:  'Azure did not swap every data disk back, so this machine is stopped. Use Finish the rollback or Finish the restore first.',
  // RETRY-SERIES-1: a rolled-back machine, given another size series.
  retrySeries:     'Change to {series}',
  retrySeriesTip:  'Changes the target of this machine to another size series, so you can try it again on that series.',
  retrySeriesDesc: 'The target of this machine changes to {size}. The plan changes, so every wave approval and the plan sign-off must be given again.',
  retrySeriesDone: 'The target changed. Accept the wave settings, get the sign-off again, then select Try this machine again.',
  // ROLLBACK-SIZE-REFUSED-SERIES-1: after Azure refused the original size, the
  // next step is the restore onto the new size, then the retry.
  retrySeriesDoneRestore: 'The target changed. Select Restore this machine, and choose the copy Before the migration. Then accept the wave settings, get the sign-off again, and select Try this machine again.',
  // ROLLBACK-SIZE-REFUSED-SERIES-1: the restore dialog says the size the first copy goes onto.
  restoreOntoTarget: 'Azure refused the original size {original}. The restore changes the machine to {size}, the {series} size in the plan. Every later rollback and restore returns the machine to {size}.',
  // DECIDE-1: a different control, because it is a different action. "Try this
  // machine again" re-ran the same check against the same setting and stopped
  // again, for ever - there was nothing to correct between the two attempts.
  /* SKIP-ONE-1: the choice that was missing. Every other control at a parked
   * machine is about making it migrate; this one is "I will deal with this
   * one later", and without it the wave cannot finish past it. */
  skipVm:       'Leave this machine out',
  skipTitle:    'Leave this machine out of the migration',
  /* SKIP-PREPARED-WORDS-1: leaving a machine out changes nothing in AZURE.
   * Where the machine IS, the stop that parked it recorded (machineState,
   * FAIL-1), and one of the next four sentences says it (skipMachineState).
   * The dialog said "prepared" whenever the history held GUEST_PREP - false
   * on a machine that rolled back, which runs from its first safety copy. */
  skipDesc:     'This machine does not migrate in this run. Nothing in Azure changes for it, and the rest of the wave goes on.',
  // POWER-ONLY-CHANGED-1: said in place of skipDesc when the product returns the power state.
  skipDescPower: 'This machine does not migrate in this run, and the rest of the wave goes on.',
  skipUntouched: 'Nothing on this machine was changed.',
  skipRunsAsBefore: 'This machine runs as it was before the move.',
  skipChanged:  'This machine is not as it was before the move. It stays this way when you leave it out. Do the steps in Why it stopped before you plan it again in a new migration.',
  /* RETRY-LATER-WORDS-1 (ruling, 2026-11-04): a later change window is
   * a NEW migration - a new scan, targets, waves and sign-off. There is no
   * later wave of this migration for it. Said after the sentence about the
   * machine, wherever the machine can move later as it is. */
  skipLater:    'To move this machine in a later change window, plan it again in a new migration.',
  /* SKIP-CHANGED-FREED-1: said only of a machine left changed. This
   * migration keeps the machine, so the first safety copy of another
   * migration never takes the changed machine as the machine as it was. */
  skipClaimKept: 'No other migration can take this machine until you restore it.',
  // POWER-ONLY-CHANGED-1: said of a machine whose only change is its power state.
  skipPowerBack: 'Only the power state of this machine is not as it was. The product returns it to the power state {power}, and then the machine is free.',
  skipConfirm:  'Leave it out',
  decide:       'Accept this and continue',
  decideTitle:  'Accept this for one machine',
  decideDesc:   'You accept this for this machine only. Every other machine in the wave keeps its setting. Your name and note are recorded.',
  decideConfirm:'Accept and continue',
  decideApprovalGone: 'The approval of wave {wave} signed the plan before this change. Approve the wave again.',
  decideApprovalCovered: 'The approval of wave {wave} signed the plan before this change, so it was removed. The wave can still start without it.',
  resolveRevalidate:'This machine is already on its new size, so only its health checks will be repeated.',
  // RETRY-1: what stopped it, and what a person can do about it.
  whyTitle:     'Why it stopped',
  whyDo:        'What to do',
  whyUntouched: 'Nothing on this machine was changed.',
  whyPutBack:   'The product rolled this machine back to how it was.',
  whyNotBack:   'This machine is not as it was. Read this before you try again.',
  // POWER-ONLY-CHANGED-1: said when only the power state is not as it was.
  whyPowerNotBack: 'The power state of this machine is not as it was before the move. Nothing else changed.',
  whyPowerMeaning: 'The product changed the power state of this machine, and Azure refused to return it to the power state that it had before the move.',
  whyPowerDo: 'Try this machine again: the product first returns the machine to its power state. Leave this machine out also returns the machine to its power state.',
  // POWER-ONLY-CHANGED-1: a machine whose power state is owed, on its panel, in any state.
  powerBack: 'Return to the power state',
  powerBackTitle: 'Return this machine to its power state',
  powerBackDesc: 'The product returns this machine to the power state that it had before the move: {power}. Nothing else on the machine changes.',
  powerBackLine: 'The power state of this machine is not as it was before the move. It was {power}.',
  powerBackDone: 'The product starts the return now. The panel then says if the machine is in its power state again.',
  // VOLUMES-RESTORE-MIGRATED-1: Check the volumes - the check of the retry, with no move.
  volumesCheck: 'Check the volumes',
  volumesCheckTitle: 'Check the volumes of this machine',
  volumesCheckDesc: 'The product runs a check inside the machine. The check compares the mounted volumes with the volumes that were mounted before the move. On Linux, the product first updates the LVM devices file and mounts the volumes that the fstab file names. On Windows, the product changes the status of a data disk to Online if it was Online before the move. If the machine is not in the power state Running, the product starts it for the check. Then the product returns it to its power state. If every volume is mounted again, the product records the machine as restored.',
  volumesCheckDone: 'The product starts the check now. The panel then shows the result.',
  volumesCheckLineMissing: 'At the last check, a volume that was mounted before the move was not mounted. Mount it inside the machine. Then select Check the volumes.',
  volumesCheckLineUnknown: 'At the last check, the product could not check the volumes inside this machine. Select Check the volumes to check them again.',
  // VOLUMES-CHECK-JOB-STOP-1: a check of the volumes started the machine, and its job stopped before the return.
  volumesStartedStopped: 'The product started this machine for a check of the volumes. The check did not finish. The machine is in the power state Running. Before the check, it was {power}. The service starts the check again, and the check returns the machine to that power state.',
  volumesStartedGaveUp: 'The product started this machine for a check of the volumes. The check did not finish. The machine is in the power state Running. Before the check, it was {power}. The service started the check again. The check did not finish. Select Check the volumes to start it again.',
  powerRunning: 'Running',
  powerStopped: 'Stopped',
  powerDeallocated: 'Stopped (deallocated)',
  // LAB-UX-1: the line for each retry kind moved to stop-reasons.json
  // (retryLines), so the migration record says the same words as this panel.
  whyDecideWho:      'Only an approver can accept this. Ask a user with the Approver role.',
  noteLabel:    'Why? A short note, recorded with the action',
  noteOptional: 'Note (optional)',
  noteMissing:  'Please add a short note - every action is recorded with its reason.',
  doneWave:     'The wave is starting. Each machine shows here when its migration starts.',
  nextTitle:    'What happens next',
  nextNoRun:    'Nothing has been scanned yet. Start by looking for machines that could be migrated.',
  nextWorking:  'Working on it - this page updates itself, so you can leave it open.',
  nextNoPlan:   'The machines have been found. Next, turn them into a plan of waves - still nothing is changed.',
  nextPlanned:  'The plan is ready. Review the waves below, then approve and start the first one.',
  // MIGRATIONS-WORDS-LAB-1 (words approved 2026-11-13): said in
  // place of the line above when the first wave is signed off and waits for its
  // scheduled start. The two buttons are cancelSchedule and startWave.
  nextScheduled: '{wave} is signed off. It starts by itself at {time}. To start it now, select Cancel the scheduled start, then select Start this wave.',
  // LAB-UX-1: said when every wave has run, in place of the line above.
  nextAllRan:   'Every wave in this plan has run. Read the result of each machine below.',
  // STOP-STATE-SHOWN-1: the migration a person stopped.
  stoppedTitle: 'Stopped',
  stoppedBy:    '{who} stopped this migration on {when}.',
  stoppedNote:  'The note says: {note}',
  nextStopped:  'No wave starts after this. To remove the migration, select Delete this migration.',
  // PANEL-OLD-STOP-1: said while a wave runs, and between waves.
  nextRunning:  'A wave is running now. This page updates itself, so you can keep it open.',
  nextBetween:  'At least one wave has run. Review the waves below, then approve and start the next wave.',
  // WAVE-ORDER-START-1: after a decision, before the next check of the service;
  // and after Start, before the engine begins the machines.
  nextWaitsCheck: "A machine waits for the service's next check. Then the service starts it again. This page updates itself, so you can keep it open.",
  // RETRY-WAIT-SAYS-WHY-1: the line above, when the service said what holds the machine.
  nextWaitsWave: 'A machine waits for wave {wave} to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.',
  nextWaitsAnyWave: 'A machine waits for a running wave to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.',
  nextWaitsRestore: 'A machine waits for a restore to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.',
  nextWaitsGate: 'A machine waits, because wave {wave} cannot start yet. {reason}',
  nextStarting: 'A wave starts within about 5 minutes. This page updates itself, so you can keep it open.',
  // BRAKE-WAIT-WORDS-1: either of the two lines above, while the wave safety
  // brake holds the migration. Nothing starts until Resume.
  nextWaitsResume: 'The wave safety brake paused this migration. Nothing starts until an operator selects Resume on the Wave safety brake card.',
  // WAVE-RUNNING-LEASE-1: nothing works, and the hold of a stopped worker stays on
  // a finished machine. The service removes it at its next check.
  nextEndedHold: 'A worker stopped after its machine finished, and its hold stays on the machine. The service removes the hold within about 5 minutes. This page updates itself, so you can keep it open.',
  /* FAILSHOW-1: what the page says when the last thing somebody asked for did
   * not work. The operation is named, because "it failed" is what an operator
   * can already see; which one and why is what they cannot. */
  nextFailedTitle: 'The last action did not work',
  nextFailed:      'The {what} did not work. {reason}',
  nextFailedWave:  'start of a wave',
  nextFailedRestore: 'restore of a machine',
  nextFailedPlan:  'plan',
  nextFailedAssess: 'scan',
  nextFailedDiscard: 'delete of this migration and its safety copies',
  nextFailedOther: 'last action',
  /* FAILBRIEF-1: the whole reason, on demand. FAILSHOW-1 printed the engine's
   * detail word for word, which reads well when the reason IS a sentence and
   * badly when it is a raw Azure error - six hundred characters, the same
   * message twice because Azure repeats itself, and a client id. */
  nextFailedShow:  'Show the whole reason',
  nextFailedHide:  'Hide the whole reason',
  arrangeWaves: 'Arrange the waves',
  // WAVES-BUTTON-RUNNING-1: the same button while a wave runs. The editor
  // refuses a change to a running wave only, so it says which waves change.
  arrangeNotRunning: 'Change the waves that are not running',
  nextNoAccess: 'Ask an operator to start the next step.',
  forRun:       'For the run',
  // SLOW-DELETE-1: the page stopped waiting; it does not know whether the action
  // happened. "Try again" claimed it had not, and on a delete that was wrong.
  slowService:  'The service did not answer in time. The action can still be in progress. Look at the page again before you do it again.',
  discardDone:  'The migration is deleted.',
  // DISCARD-ENGINE-1: the engine deletes the safety copies, then the migration.
  discardQueued: 'The engine is deleting the safety copies. The migration goes from the list when all copies are deleted.',
  discardWorking: 'The engine is deleting this migration and its safety copies. The delete started {ago}.',
  discardUnknown: 'The service did not answer in time, and the migration is still in the list. The delete can still be in progress. Wait one minute, then look again before you delete it again.',
  // MACHINES-AT-ONCE-RANGE-1: the start takes the number of the wave, set in
  // one place. This dialog had its own number field, the same words as the
  // wave setting with another value; now it says the choice and where to
  // change it.
  atOnceStart:  'The wave settings set how many machines at once: {choice}. To change it, edit the wave settings.',
  estAllAtOnce:  'This wave has only {machines} machines, so all of them run at once.',
  // LAB-UX-1: the same two sentences for a wave of one machine.
  estAllAtOnceOne: 'This wave has only 1 machine, so a larger number changes nothing.',
  confirm:      'Confirm',
  cancel:       'Cancel',
  // CLOSE-NOT-CANCEL-1: an open (?) only shows information, so it closes with Close.
  close:        'Close',
  /* DIALOG-STALE-1: said in a dialog opened from the side panel when the
   * refresh reads a new state document for its machine. */
  dialogStale:  'This machine changed after you opened this dialog. Its state is now:',
  dialogGone:   'The product has no state record for this machine now. The last refresh did not find one.',
  dialogStaleWhat: 'Read the side panel before you continue. The service refuses an action that is not correct for the new state.',
  working:      'Working...',
  /* ACTFEED-1: it no longer asks somebody to wait and watch. The page follows
   * the action through instead - see followThrough. */
  done:         'Done. The page is catching up with it.',
  restore:      'Restore this machine',
  puttingBack:  'Restoring',
  // RESTORE-DIALOG-WORDS-1: it starts only when every disk is back (SWAP-REFUSED-AFTER-STOP-1).
  puttingBackTip: 'This machine is being restored from a safety copy now. It starts again when every disk is attached. If Azure does not attach a data disk, the machine stays stopped.',
  // CAPACITY-WORDS-1: approved words, exact; capacityLine picks one.
  capOdcrUsed:    'On-demand capacity reservation: this machine used one of the reserved slots of its wave.',
  capNoneWave:    'No on-demand capacity reservation. Its wave does not reserve capacity.',
  capOwnGroup:    'Capacity reservation group: {group}. The machine stays in this group.',
  capAvset:       'No on-demand capacity reservation. Azure does not allow one for a machine in an availability set.',
  capNoneSlot:    'No on-demand capacity reservation.',
  placementTip:   'An on-demand capacity reservation makes sure that the new size is available when the machine starts. A machine in its own capacity reservation group stays in that group. Azure does not allow an on-demand capacity reservation for a machine in an availability set.',
  /* RESTORE-ONE-AT-A-TIME-1: why Restore this machine is not on the panel.
   */
  putBackBusy:  'A restore of this machine is in progress. Restore this machine shows again when the restore ends.',
  restoreMidMove: 'The move of this machine has not ended, so Restore this machine is not shown. The wave rolls the machine back if the move fails. To get the machine back now, select Stop this migration, then restore the machine.',
  /* RESTORE-DIALOG-WORDS-1: two plain questions, in the words of the product
   * and of Azure. A restore MAKES a new managed disk from each snapshot and
   * SWAPS it onto the machine. The current disk stays, detached, unless the
   * operator chose to delete it - so no word here says a disk is replaced, and
   * data is lost only with that choice. The options are on the screen; the why
   * is behind a ? helper. RESTORE-COPY-1 is why each copy is its own option. */
  restoreTitle: 'Restore {machine} from a safety copy',
  restoreDesc:  'The product makes a new managed disk from each snapshot, swaps it onto the machine, and restarts the machine. The new disks do not have data written after the snapshot.',
  // Said only for a machine whose record shows the disk.
  restoreShared: 'A shared disk stays as it is.',
  restoreInstant: 'If Azure cannot use the snapshot of a Premium SSD v2 or Ultra Disk now, the restore stops before it changes the machine.',
  restoreWhich: 'Which safety copy?',
  restoreOnlyCopy: 'This machine has only one safety copy.',
  restoreFromPristine: 'Before the migration',
  restoreFromPrepared: 'Just before the resize',
  // The size and the disk controller of a copy, from the record of the machine.
  restoreShape: '{size}, {controller} disk controller',
  optionHelpTip: 'More about this choice',
  restorePristineHelp: 'The machine returns to this size and disk controller. Accelerated networking also returns to how it was.',
  // RETIRE-SCOPE-1: a return to the size the machine had, when Microsoft retires it.
  retireWarn:   'Microsoft retires {size}, the size this machine had before the move, on {date}. From one day before that date, the product does not return a machine to that size.',
  retireRefused: 'Microsoft retires {size}, the size this machine had before the move, on {date}. From one day before that date, a return to that size is outside the scope of this tool, so the product refuses it.',
  restoreNaming:'Keep its current managed disks?',
  // No promise to undo: the app has no action that puts the current disks back.
  restoreNew:   'Yes. Keep them, detached, in Azure. This is the recommended choice.',
  restoreKeep:  'No. Delete them, and give the new disks their names. Data written after the snapshot is lost.',
  // RESTORE-DELETE-EXCEPTION-1: under the delete choice, only for a machine
  // whose record has such a disk with a copy (restoreKeepInstantNote).
  restoreKeepInstant: 'The product does not delete a Premium SSD v2 or Ultra Disk while an instant access snapshot of it is not complete. That disk stays as it is.',
  restoreKeepHelp: 'Use this choice when something refers to a disk by its name or resource ID. Each new disk gets the name and resource ID of the current disk. The product does not copy its tags, role assignments or backup. The safety copies are then the only copies, and the daily cleanup deletes them when the retention of the wave ends.',
  restoreRisk:  'I understand that the product deletes these managed disks:',
  restoreRiskMissing: 'Select the checkbox to delete the current managed disks. Or keep them.',
  restoreBtn:   'Restore',
  restoreDone:  'Restoring the machine now. The run history shows what happens.',
  /* SWAP-REFUSED-AFTER-STOP-1: a rollback or a restore whose data disk swap
   * Azure refused, also when the product tried again, left the machine stopped. */
  finishRollback: 'Finish the rollback',
  finishRestore:  'Finish the restore',
  finishDesc:     'Azure did not swap every data disk back, so the machine is stopped.',
  finishDisk:     'On LUN {lun}, the disk {name} is still attached, and the disk {disk} made from its copy waits.',
  /* FINISH-EMPTY-LUN-WORDS-1: each LUN as the record says it is (lunHolds,
   * vm-state v38): the disk it had, no disk, not read, or another disk. */
  finishDiskEmpty: 'LUN {lun} has no disk. The disk {disk} made from its copy waits to go on it.',
  finishDiskEmptyUnproven: 'LUN {lun} has no disk, and the record does not prove which disk goes on it. This stops before it changes the machine.',
  finishDiskOther: 'LUN {lun} has a disk that is not {name} and not {disk}. This reads the LUN again, and changes nothing if that disk is still on it.',
  finishDiskNotRead: 'The product did not read which disk is on LUN {lun} after the swap stopped.',
  finishDiskReadFirst: 'This reads the LUN first. It puts the disk {disk} on it only when the LUN has the disk {name} or no disk.',
  // FINISH-TEMP-DISK-LEFT-1: keeping the names, the LUN runs on its temporary disk.
  finishDiskTemp: 'The disk {name} is the temporary disk made from the copy. After this, it is not attached, and the daily cleanup deletes it when the move of this machine ends.',
  finishWhat:     'This swaps only those data disks, then starts the machine. It makes no disk and deletes no disk.',
  finishWhatAttach: 'This swaps or attaches only those data disks, then starts the machine. It makes no disk and deletes no disk.',
  finishDone:     'Finishing now. The machine starts when every data disk is back, and the run history shows what happened.',
  wasRestored:  'Restored',
  // SWAP-REFUSED-AFTER-STOP-1: a restore that left a data disk swap keeps the machine stopped.
  finishPill:   'Stopped: finish the restore',
  finishPillTip: 'Azure did not swap every data disk back, so this machine is stopped. Open it and use Finish the restore.',
  wasRestoredTip: 'This machine was restored from a safety copy',
  restoredFrom: 'Restored from its safety copy',
  restoredWhen: 'when',
  restoredBy:   'by',
  restoredDisk: 'Its operating system disk',
  restoredDataDisks: 'Its data disks',
  restoredDataIdChanged: 'are new disks. Update anything that referred to the old ones.',
  // RESTORE-DIALOG-WORDS-1: the name and the resource ID come back; nothing else of the earlier disk does.
  restoredDataIdSame: 'have the names and resource IDs of the earlier disks. The product did not copy their tags, role assignments or backup.',
  restoredDataKept: 'Data disks left as they were',
  restoredIdChanged: 'is a new disk. Update anything that referred to the old one.',
  restoredIdSame: 'has the name and resource ID of the earlier disk. The product did not copy its tags, role assignments or backup.',
  // RESTORE-DIALOG-WORDS-1: the disks a restore with new names kept, from its own record.
  restoredEarlier: 'Its earlier managed disks',
  restoredEarlierWhat: 'They are detached and kept in Azure. They hold the data that the machine wrote after the snapshot. Each costs money until you delete it.',
  restoredEarlierOs: 'Operating system disk',
  restoredEarlierLun: 'LUN {lun}',
  // RESTORE-EARLIER-DELETE-1: Delete these disks, with the confirmation approved 2026-10-25.
  restoredEarlierDelete: 'Delete these disks',
  restoredEarlierDeleteAsk: 'This deletes {n} managed disks. What the machine wrote after the move is lost. The machine and its new disks are not touched.',
  restoredEarlierDeleteAskOne: 'This deletes 1 managed disk. What the machine wrote after the move is lost. The machine and its new disks are not touched.',
  restoredEarlierDeleteDone: 'The product deletes the disks now. It does not delete a disk that is attached to a machine, and the list then shows that disk.',
  // MADE-DISK-SHOWN-1: the managed disks a put-back made from a copy that the record says nothing uses.
  madeTitle: 'Managed disks made from the safety copies',
  madeWhat: 'The product made these disks from the safety copies. The record of this machine says that no machine uses them. Each costs money until it is deleted.',
  madeColDisk: 'Disk',
  madeColBy: 'Made by',
  madeColFor: 'Made for',
  madeColMade: 'Made',
  madeNext: 'What happens next',
  madeByRollback: 'Rollback',
  madeByRestore: 'Restore this machine',
  madeDue: 'The next daily cleanup deletes these disks.',
  madeWaits: 'Kept. The daily cleanup deletes these disks only after the machine is Migrated, Rolled back or Not migrated.',
  madeHelpTip: 'About the delete of these disks',
  madeHelp: 'The daily cleanup reads each disk in Azure before it deletes it. It keeps a disk that is attached to a machine. It keeps every disk while a wave or a restore works on the machine, or when Azure does not show the machine. Delete this migration also deletes these disks when you select to delete the copies as well. An operator can delete them now with Delete these disks now, by the same rules.',
  // MADE-DISK-DELETE-1 (2026-11-08): the two-step slide-out under the table.
  madeDelete: 'Delete these disks now',
  madeDeleteAsk: 'This deletes {n} disks. It cannot be undone.',
  madeDeleteAskOne: 'This deletes 1 disk. It cannot be undone.',
  madeDeleteDone: 'The product deletes the disks now. It does not delete a disk that is attached to a machine, and the record then says that a machine uses that disk.',
  // MADE-DISK-DELETE-1: the red button of each slide-out delete of disks on the panel.
  diskDeleteGo: 'Delete {n} disks',
  diskDeleteGoOne: 'Delete 1 disk',
  // ROLLBACK-ORIGINALS-LEFT-1 (words approved 2026-11-08): the disks a
  // rollback swapped off. The button and the line after the delete are the
  // words of the restore (restoredEarlierDelete, restoredEarlierDeleteDone).
  originalTitle: 'Original disks, not in use',
  originalWhat: 'These are the disks {vm} had before the migration. The rollback did not put them back. It put the machine on new disks, made from the snapshot taken before the migration changed anything. These disks are detached, and each costs money until you delete it.',
  originalColUsedAs: 'Used as',
  originalColDetached: 'Detached',
  originalKept: 'Kept until you delete them.',
  originalDeleteAsk: 'This deletes {n} disks. It cannot be undone. The disks {vm} uses now are not touched.',
  originalDeleteAskOne: 'This deletes 1 disk. It cannot be undone. The disks {vm} uses now are not touched.',
  /* TRAIL-1: the put-back belongs IN the list of what happened to a machine.
   * It was recorded and shown in its own box, so the trail underneath ended at
   * "Migrated" while the newest thing that had happened was a put-back. */
  restoredStep:     'Restored from its safety copy',
  // STATUS-WORDS-1: until Finish the restore ends, the restore is not done.
  restoreNotDone:   'The restore did not finish',
  restoredFromPristine: 'From the safety copy taken before the migration. The machine is back on its original size and disk controller, and accelerated networking is as it was.',
  restoredFromPrepared: 'From the safety copy taken just before the resize. The machine keeps its current size and disk controller.',
  whenLabel:    'When should it start?',
  whenNow:      'Now',
  whenLater:    'At a time I choose',
  whenAt:       'Start at (your local time)',
  windowLabel:  'How long is the window? (minutes, leave blank for no limit)',
  windowHint:   'The product does not start a wave whose estimate is longer than the time left in the window.',
  whenPast:     'Pick a time in the future.',
  doneScheduled:'Scheduled. It will start at the time you chose - unless it still needs sign-off, in which case it waits for that.',
  scheduledFor: 'Scheduled for',
  scheduledBy:  'set by',
  // SCHEDULE-START-SHOWN-1: a schedule whose start is on record (state
  // starting or started). The words the page already uses after Start, doneWave.
  scheduleStarting: 'The wave is starting.',
  cancelSchedule:'Cancel the scheduled start',
  cancelDone:   'The scheduled start was cancelled.',
  // FREE-MACHINE-GONE-1: "Free this machine" is gone. It released the claim
  // and never the lease, so it freed no machine a worker held.
};
const UX_FOUND_T = {
  title:      'Machines that the scan found',
  hint:       'Everything the scan looked at. Nothing here has been changed.',
  hide:       'Hide',
  show:       'Show what the scan found',
  colMachine: 'Virtual machine',
  colWhere:   'Resource group and region',
  colNowSize: 'Current size',
  colOutlook: 'Can it migrate?',
  colWhy:     'What it needs',
  none:       'The scan found no virtual machines in the place you chose.',
  // ALREADY-CURRENT-1: the line for a machine on a Current size, as the shared report has it.
  currentLine: '{size} is in the Current lifecycle stage.',
};
// What the scan concluded about each machine, and why - in real words.
// [ answer in the "Can it migrate?" column, the why, how it reads as a
//   standalone count ] - "Yes 1" made sense in the column and nowhere else.
const UX_FOUND = {
  // ALREADY-CURRENT-1: a machine on a size in the Current lifecycle stage.
  Current:        ['Current',           '',                                                                  'Current'],
  ReadyAfterPrep: ['Yes',               'It can migrate. The product prepares it during the move.',         'can migrate'],
  Blocked:        ['Not yet',           'A finding stops this machine. The row says which.',                'cannot migrate yet'],
  Excluded:       ['Not eligible',      'The product does not move this machine. Another Azure service manages it, or it is outside the scope of this tool.','not eligible'],
  SomeTargets:    ['Some targets only', 'A finding holds this machine back from some size series. At least one other series stays open to it.', 'some targets only'],
  // MACHINE-PICK-1: a plan holds only the machines a person chose.
  NotChosen:      ['Not in this migration', 'This machine was not chosen for this migration. It stays in the assessment.', 'not in this migration'],
};
const UX_FILTER = {
  all:       'All',
  attention: 'Needs attention',
  moving:    'In progress',
  waiting:   'Waiting to start',
  done:      'Finished',
};
const UX_WHO = { demoViewer: 'Sample viewer' };
/* ============================= UX-STRINGS-END ============================= */

// ASSESS-PAGE-1: what a blocker or prep item MEANS comes from the engine's own
// assessment-reasons.json, copied here by the deploy - the same arrangement as
// stop-reasons.json. This page and the wizard each used to keep their own list,
// and BOTH were missing five of the seven blockers, so a machine held back as
// confidential or for an unsupported image showed the operator a raw code.
const REASONS = { blockers: {}, prep: {} };
const reasonText = (code) =>
  (REASONS.blockers[code] || REASONS.prep[code] || {}).title || String(code);
// V5-GATE-1, on the page: the scan decides "Blocked" once, for every size
// series. Once a machine is planned, it is judged against ITS entry's series,
// by the same rule the engine uses (Resolve-VmfEntryClassification): only the
// reasons whose appliesTo names that series count. A code the data does not
// know counts for every series - a reason from a newer scan is not a pass.
// BSV2-TARGET-1 (review): with the planned temporary disk kind, a v5 move to a
// size with no temporary disk (Bsv2, or D4s_v5) moves the page file too - the
// engine rule, held to tests/fixtures/prep-by-target.json.
function judgeForSeries(v, series, targetDiskArch) {
  const own = v.classification;
  if (!series) return { classification: own, blockers: v.blockers ?? [], prep: v.prepNeeded ?? [] };
  const applies = (group, code) => {
    const r = REASONS[group][code];
    return !r || !Array.isArray(r.appliesTo) || r.appliesTo.includes(series);
  };
  const blockers = (v.blockers ?? []).filter(c => c && applies('blockers', c));
  const prep = (v.prepNeeded ?? []).filter(c => c && applies('prep', c));
  if (series === 'v5' && targetDiskArch && targetDiskArch !== 'scsi-temp' &&
      (v.prepNeeded ?? []).includes('pagefile') && !prep.includes('pagefile')) prep.push('pagefile');
  const classification = (own === 'Excluded' || v.platformManaged) ? 'Excluded'
    : blockers.length ? 'Blocked'
    : own === 'Blocked' ? 'ReadyAfterPrep'
    : own;
  return { classification, blockers, prep };
}
// ALREADY-CURRENT-1: the rule of the shared report (VmfReport.isCurrent,
// which this page does not load), held to tests/fixtures/already-current.json
// beside it: a machine whose size the scan found in the Current lifecycle
// stage (sourceLifecycle, assessment v10). Never read from the size name.
function foundCurrent(v) {
  return Boolean(v) && v.classification !== 'Excluded' && !v.platformManaged &&
    String(v.sourceLifecycle?.stage ?? '') === 'Current';
}
// ASSESS-COUNT-1: a machine with no series planned yet. The scan says Blocked
// once for every series; one with a series still open to it is "some targets
// only", the word the assessment report counts it by.
function judgeUnplanned(v) {
  const j = judgeForSeries(v, undefined);
  if (j.classification !== 'Blocked' || v.platformManaged) return j;
  const open = ['v5', 'v6', 'v7'].some(s => judgeForSeries(v, s).classification !== 'Blocked');
  return open ? { ...j, classification: 'SomeTargets' } : j;
}
async function loadReasons() {
  try {
    const r = await (await fetch('assessment-reasons.json')).json();
    REASONS.blockers = r.blockers ?? {};
    REASONS.prep = r.prep ?? {};
  } catch { /* the codes still render; an explanation is better than a broken page */ }
}

/* STEP-WORDS-1: steps that SAY WHAT THEY SAY.
 *
 * stepText is the only text in an activity row - e.detail reaches a person
 * nowhere but the tooltip. These twelve steps reached the feed as the raw
 * engine word ("rearm", "claim", "acknowledgement"), so a row read, in full,
 * "approval", while the sentence beside it - who approved which wave, and the
 * note they left - was discarded one line later.
 *
 * A LABEL WOULD NOT HAVE FIXED IT. A label REPLACES the detail, so "An
 * operator approved a wave" still throws away who. Every one of these records
 * what a PERSON did, and the engine already writes a whole sentence saying
 * who and why - the driver check's contract says so in as many words:
 * `Detail = <plain language>`. An audit trail that hides who did something
 * behind a generic heading is worse than no heading.
 *
 * Same rule LOG-SAYS-WHY-1 applied to a refusal: a label is a convenience for
 * a step nobody has to act on.
 *
 * The value is the FALLBACK, used only when an event carries no detail, so
 * the raw engine word can never come back. */
const SAYS_ITSELF = {
  // DISK-TYPE-WORDS-1: the change's summary, and a shared disk that kept its type.
  diskType:        'setDiskType',
  acceptance:      'acceptedOptions',
  // V3-RETIRE-1: a put-back to a size Microsoft retires, refused or warned.
  putBack:         'putBackNote',
  // STATE-TARGET-1: a resume that finished the move it started, not a changed plan.
  targetKept:      'targetKept',
  // POWER-ONLY-CHANGED-1: the engine operation powerback says what it did to the power state.
  powerBack:       'powerReturned',
  // VOLUMES-RESTORE-MIGRATED-1: the engine operation checkvolumes says what the check found.
  volumesCheck:    'volumesChecked',
  // RESTORE-EARLIER-DELETE-1: each earlier disk deleted, each skipped and why, and who asked.
  earlierDelete:   'earlierDisksDeleted',
  // MADE-DISK-DELETE-1: each disk deleted, each kept and why, and who asked.
  madeDelete:      'madeDisksDeleted',
  // ROLLBACK-ORIGINALS-LEFT-1: each original disk deleted, each kept and why, and who asked.
  originalDelete:  'originalDisksDeleted',
  acknowledgement: 'ackedDrift',
  approval:        'approvedByPerson',
  advice:          'targetOptions',
  targets:         'targetsSaved',
  machines:        'machinesSaved',
  claim:           'claimChanged',
  driverCheck:     'driverChecked',
  precheck:        'precheckNote',
  rearm:           'rearmed',
  // REPORT-AUTO-1: a record warning is its own sentence. REPORT-RECORD-LINE-1:
  // a record that was kept also leaves an ok line, read in stepText.
  record:          'recordStep',
  // APPROVE-GROUP-1: written only to say the status for the list could not be written - its own sentence.
  status:          'statusStep',
  retention:       'copiesReviewed',
  // SAFETY-RETRY-1: a retry keeps the earlier attempt's copies on record.
  safetyCopy:      'copiesKept',
  run:             'runStopped',
  // DISCARD-ENGINE-1: who started the delete, and each copy that was not deleted.
  discard:         'migrationDeleting',
  // Review 2 item 1: one copy the engine did not delete, or is about to unlock.
  discardCopy:     'copyNotDeleted',
  skip:            'vmLeftOut',
  schedule:        'scheduleChanged',
  // RUNCMD-REPLAY-1: the read-only script after a change did not run - which script Azure can run again.
  neutralMark:     'guestMark',
  // QUOTA-PREVIEW-1: a preview of a quota increase. It requested nothing, so
  // it is not the quotaRequest label "A quota increase was requested".
  quotaPreview:    'quotaPreviewStep',
  // QUOTA-FILED-WORDS-1: how many quota increase requests Azure took. It is not
  // one request, so not the quotaRequest label either.
  quotaResult:     'quotaResultStep',
  // QUOTA-REQUEST-POLL-1: Azure approved, refused or did not answer one request, with its request ID.
  quotaAnswer:     'quotaAnswerStep',
};

const STEP_MAP = [
  // SAFETY-3: the lock, the check, the unlock and the delete come BEFORE the
  // snapshot patterns below, which would otherwise read "lockSnapshot" as
  // taking a copy - and did read "removeSnapshot" that way.
  // TERMS-AUDIT-1: the unlock FIRST - /lockSnapshot/ also matches unlockSnapshot,
  // so every unlock, in retention and in the delete of a migration, read
  // "Locked the safety copy". And the read before it is not a new copy.
  [/unlockSnapshot/,              'unlockCopy'],
  [/lockSnapshot/,                'lockCopy'],
  [/readSnapshot/,                'readCopy'],
  [/verifySafetyCopies/,          'verifyCopies'],
  [/removeSnapshot/,              'deleteCopy'],
  [/restore:sizeBefore/,          'readSizeNow'],
  [/resize/,                      'resizeVm'],
  [/diskPatch/,                   'updateDisks'],
  // OLD-SKU-1C: the type of a disk changed, and set back. DISK-TYPE-WORDS-1: stepText names the type.
  [/(rollback|restore):diskType$/, 'setDiskTypeBack'],
  [/diskTypeRead/,                'readDiskType'],
  [/diskType$/,                   'setDiskType'],
  [/deallocate|^STOPPED/,         'stopVm'],
  [/azureops:start|^STARTING/,    'startVm'],
  // The activity feed showed a shutdown then a start with NO
  // snapshot between them, which reads as "we restarted it and then took the
  // copy". The order was right; this table was wrong. The event is named
  // pristineSnapshot and this pattern was case-SENSITIVE, so it never matched
  // and the single most important action in the step went unlabelled. The
  // most specific pattern has to come first.
  [/pristineSnapshot/i,           'snapshotPristine'],
  [/snapshot/i,                   'snapshotDisk'],
  [/odcrRelease/,                 'releaseCap'],
  [/odcrQuantityZero/,            'reserveZero'],
  [/odcrAssociate/,               'joinReserve'],
  [/odcrDisassociate/,            'leaveReserve'],
  [/runcmd:(Set-NvmeReady|nvme-fix)/,        'guestPrepOs'],
  [/runcmd:Move-Pagefile/,        'guestPagefile'],
  [/runcmd:Install-TempDiskInit/, 'guestTempDisk'],
  [/runcmd:kernel-update/,        'guestKernel'],
  [/runcmd:(Get-NeutralMark|neutral-mark)/, 'guestMark'],
  [/runcmd:.*seed/i,              'guestSeed'],
  [/runcmd:.*(verify|DataDiskSeed)/i, 'guestVerify'],
  [/runcmd:/,                     'guestCheck'],
  [/^GUEST_PREP|^PRECHECK|^VALIDATING|^SAFETY_PRISTINE|^SAFETY_COPY|^CONVERTING|^PLANNED/, null], // state steps: use UX_STATE
  [/^resume$/,                    'waveRestarted'],
  [/watchdog/,                    'workerRecover'],
  [/^worker$/,                    'workerPickup'],
  [/^decision$/,                  'decisionMade'],
  // BLOCKED-NAME-1: `capacity` used to sit in the pattern below and so read as
  // "Planning and assessment". It has to come first - the two are tested in
  // order, and a step matches the first pattern that takes it.
  [/^capacity$/,                  'capacityStep'],
  [/^(assessment|plan)$/,         'planStep'],
  [/^report$/,                    'reportStep'],
  [/quotaRequest/,                'quotaStep'],
  [/^validate$/,                  'netFabric'],
  [/checkpoint/,                  'progressMark'],
  // The put-back is the safety net, and every step of it fell through to the
  // generic "Azure call" - so the one path an operator watches most closely was
  // the least explained. These come before the catch-all.
  [/restore:stop/,                'stopVm'],
  [/restore:start$|restore:start\b/, 'startVm'],
  [/restore:agentReady/,          'waitAgent'],
  [/osDiskInfo/,                  'readDisk'],
  // RESTORE-ALL-1: the data disks of a person's restore - before the OS disk
  // patterns, which would otherwise take swapTempData as the OS disk swap.
  [/restore:(dataDiskInfo|readDataDisk)/, 'readDisk'],
  [/restore:(createDataDisk|createTempData)/, 'makeDiskFromCopy'],
  [/restore:(swapDataDisks|swapTempData|swapFinalData)/, 'swapBackDataDisks'],
  [/restore:leaveReservation/,    'leaveReserve'],
  [/restore:readReservation/,     'checkReserve'],
  [/restore:revertHardware/,      'revertSize'],
  [/restore:swapDiskBack/,        'swapOriginalBack'],
  [/restore:(swapDisk|swapTemp)/, 'swapBackDisk'],
  [/restore:(createDisk|createTemp)/, 'makeDiskFromCopy'],
  [/restore:allowNvme/,           'allowNvme'],
  [/restore:removeOriginal/,      'deleteCurrentDisk'],
  [/restore:removeTemp/,          'deleteTempDisk'],
  [/restore:recoverStart/,        'recoverStart'],
  [/restore:lockCheck/,           'lockCheck'],
  [/restore:sizeAfter/,           'readSize'],
  // FAIL-1, seen while watching the drill: the AUTOMATIC put-back
  // narrated almost nothing. It shares the manual restore's vocabulary but
  // not its step names, so every one of its steps fell through to the generic
  // "Working with Azure" - on the single path an operator watches hardest.
  [/rollback:stop/,               'stopVm'],
  [/rollback:start/,              'startVm'],
  [/rollback:(createDisk|createDataDisk)/, 'makeDiskFromCopy'],
  [/rollback:swapDisk/,           'swapBackDisk'],
  [/rollback:swapDataDisks/,      'swapBackDataDisks'],
  [/rollback:readDataDisk/,       'readDisk'],
  [/(rollback|restore):nicAccelNet/, 'setAn'],
  [/rollback:revertSize/,         'revertSize'],
  [/rollback:readReservation/,    'checkReserve'],
  [/rollback:leaveReservation/,   'leaveReserve'],
  // ROLLBACK-DISKS-FIRST-1: the rollback disks, made before the move
  // changes anything, read before a put-back stops the machine, and deleted
  // when nothing needs them.
  [/putBack:(createDisk|createDataDisk)/, 'makeDiskFromCopy'],
  [/putBack:(readDataDisk|readDisk)|:readRollbackDisksBeforeMove$/, 'readDisk'],
  [/:deleteRollbackDisksBeforeMove$/,         'tidyDisk'],
  [/putBack:ensureRunning/,       'startVm'],
  [/^azureops:/,                  'azureCall'],
];

function stepText(e) {
  // LOG-SAYS-WHY-1, MEASURED on a live run 2026-09-21. THE REASON WAS THROWN
  // AWAY EXACTLY WHEN IT MATTERED.
  //
  // Every case below maps a step to a LABEL for the ordinary case, and the
  // labels are deliberately generic - `capacity` shares "Planning and
  // assessment" with `plan` and `assessment`. That is fine for a step that
  // went well. For one that did not, the label REPLACED the detail, so the
  // page showed a red row that said, in full:
  //
  //     Planning and assessment
  //
  // The refusal it was reporting - which names the wave, the reason and the
  // control to press - was in e.detail, discarded one line later.
  //
  // THE RULE, NOT THE INSTANCE: a label is a convenience for a step nobody
  // needs to act on. A step that FAILED or was REFUSED is the one the reader
  // opened the log for, so it says what it says. This is first, so no later
  // case can take it back.
  if ((e.outcome === 'fail' || e.outcome === 'refused') && e.detail) { return e.detail; }
  // ACTIVITY-LINES-1: an attempt of a step of the move that the engine tries
  // again says its cause, as the attempt that ends the step does.
  // (The rule of stepRetried, written here so stepText stands alone.)
  if (e.outcome === 'retry' && e.vmId && e.detail && Object.prototype.hasOwnProperty.call(UX_STATE, String(e.step ?? ''))) { return e.detail; }
  // COPY-DELETE-LOCK-RACE-1: an Azure call that the product tries again says
  // its cause too. Under the label, a refused safety copy delete read
  // "Deleted the safety copy." The step pill stays off (ACTIVITY-LINES-1).
  if (e.outcome === 'retry' && /^azureops:/.test(String(e.step ?? '')) && e.detail) { return e.detail; }
  // FAIL-1: the put-back writes its own plain-language detail - "Putting the
  // machine back...", "Disk restored from the copy taken before anything was
  // changed...". Before this, the step matched nothing and the feed rendered
  // the raw step name: a single line reading "rollback", for the most
  // consequential thing the run does.
  if (e.step === 'rollback' && e.detail) { return e.detail; }
  // VOLUMES-RETRY-CHECK-1: the check before a retry stopped the machine again
  // (Invoke-VmfVolumesCheckBeforeRetry). The stop is written as the closing
  // line of Checking, and under the label the volumes it names were only in
  // the hover.
  if (e.step === 'PRECHECK' && e.vmId && /^The product did not try this machine again\. /.test(String(e.detail ?? ''))) { return e.detail; }
  // PLANRUN-1: the signed-off plan's own line - "wave X finished, so wave Y
  // starts", or why it waits. The engine writes it as a sentence.
  if (e.step === 'planrun' && e.detail) { return e.detail; }
  // DECIDE-APPROVAL-STALE-1: a decision that removed wave approvals says which
  // waves, and whether each must be approved again. Under the label the
  // sentence was only in the hover, so a person who approved a wave found it
  // unapproved with nothing on the screen saying why.
  if (e.step === 'decision' && e.outcome === 'ok' && e.detail
      && (Array.isArray(e.approvalsCleared) ? e.approvalsCleared.length : Boolean(e.approvalsCleared))) { return e.detail; }
  // MIGRATIONS-DECISION-WORDS-1: after the check above, so a decision that
  // removed approvals still says so. A line with no choice keeps the label.
  if (e.step === 'decision' && e.outcome === 'ok' && e.choice === 'retry') { return UX_STEP.decisionRetry; }
  if (e.step === 'decision' && e.outcome === 'ok' && e.choice === 'accept') { return UX_STEP.decisionAccept; }
  // QUOTA-TRUTH-1: a finished quota check, in words. The engine line is
  // "claims=N blocked=M", and a one-wave check adds "wave=NAME". The label
  // alone hid a check that counted nothing.
  if (e.step === 'capacity' && /^claims=\d+ blocked=\d+/.test(String(e.detail ?? ''))) {
    const kv = Object.fromEntries(String(e.detail).split(' ').map(w => w.split('=')).filter(p => p.length === 2));
    const what = kv.wave ? UX_STEP.quotaWhatWave.replace('{wave}', kv.wave) : UX_STEP.quotaWhatPlan;
    const n = Number(kv.claims), short = Number(kv.blocked);
    const text = n === 0 ? UX_STEP.quotaNone : short > 0 ? UX_STEP.quotaShort : UX_STEP.quotaAllOk;
    return text.replace('{what}', what).replace('{n}', String(n)).replace('{short}', String(short));
  }
  // PLAIN-LOG-1: a quota NOTE says what a person should know - that a check
  // was removed because the waves changed, and what to do. It showed only the
  // heading "Quota and capacity", and the sentence was behind a hover.
  if (e.step === 'capacity' && e.outcome === 'warn' && e.detail) { return e.detail; }
  // AVSET-RESERVE-1: a capacity reservation the wave has no use for, and a
  // Reserved wave that starts with machines on general capacity. Each writes
  // a sentence and names its wave; under the label the first read as
  // "Creating the on-demand capacity reservation", the opposite of the event.
  if ((e.step === 'odcr' || e.step === 'capacity') && e.wave && (e.outcome === 'warn' || e.outcome === 'info') && e.detail) { return e.detail; }
  // REPORT-AUTO-1: the engine writes the record and the report by itself
  // after a wave and a restore. When it cannot, its warning says
  // why and that the next one writes them again - the label alone would say
  // a report was written when none was.
  if ((e.step === 'report' || e.step === 'record') && e.outcome === 'warn' && e.detail) { return e.detail; }
  // REPORT-RECORD-LINE-1: a record that was kept leaves an ok line whose
  // detail is where it went - a file name or a storage address, not words.
  if (e.step === 'record' && e.outcome === 'ok') { return UX_STEP.recordStep; }
  // wave events carry their own meaning in the detail
  if (e.step === 'wave') {
    if (/HALT CLEARED/i.test(e.detail ?? '')) return UX_STEP.waveResumed;
    if (/HALTED/i.test(e.detail ?? '')) return UX_STEP.wavePaused;
    return UX_STEP.waveProgress;
  }
  // The facade's timers write their own plain sentence when a release or a
  // restart FAILS; it is the one thing to show. Success and the halt words
  // keep their own sentences below.
  if ((e.step === 'schedule' || e.step === 'resume') && e.outcome === 'fail' && e.detail) { return e.detail; }
  // RETRY-WAIT-SAYS-WHY-1: the service says, once, why it does not start a
  // wave again. Its sentence is the line, not "The engine was started again".
  if (e.step === 'resume' && e.code === 'held' && e.detail) { return e.detail; }
  // IDENTITY-UX-1: PRECHECK writes its own sentence when a wave proceeds by
  // choice past a system-assigned identity - naming the account being lost.
  if (e.step === 'precheck' && e.outcome === 'warn' && e.detail) { return e.detail; }
  // SWAP-REFUSED-AFTER-STOP-1: Finish the rollback, or Finish the restore.
  if (e.step === 'finish') {
    if (e.outcome === 'fail') return UX_STEP.finishFailed;
    if (e.outcome === 'start') return UX_STEP.finishStart;
    if (e.outcome === 'info' && e.detail) return e.detail;
    return UX_STEP.finishDone;
  }
  if (e.step === 'restore') {
    if (e.outcome === 'fail') return UX_STEP.restoreFailed;
    if (e.outcome === 'warn') return UX_STEP.restoreWarn;
    if (e.outcome === 'start') return UX_STEP.restoreStart;
    // RESTORE-WARN-ENDS-1: an info line comes in the middle of a restore and
    // says what it did, or what it could not put back. The finished-restore
    // words here made it read as the end.
    if (e.outcome === 'info' && e.detail) return e.detail;
    return UX_STEP.restoreDone;
  }
  // Seen in the live feed: SAFETY_PRISTINE was labelled "Taking a
  // safety copy of the machine exactly as it is now" WHETHER OR NOT it took
  // one. On a wave whose policy is a clean copy the step skips in a second, so
  // the feed asserted the safety net had run when nothing had happened - and
  // the feed correctly showed no shutdown around it, because there
  // was nothing to shut down for.
  //
  // A state's NAME is not its OUTCOME. Where a step can decline to act, the
  // feed has to read the detail and say which it was.
  // SAFETYCOPY-CLEAN-1, MANUAL-REVIEW-1: the engine never skips this step (it
  // refuses a plan without the first copy at PRECHECK), and nothing is public
  // before 1.0, so no run holds a line for a copy that was not asked for.
  if (e.step === 'SAFETY_PRISTINE' && e.outcome === 'ok') {
    if (/already taken/i.test(e.detail ?? '')) return UX_STEP.pristineAlready;
    return UX_STEP.pristineTaken;
  }
  if (e.step === 'odcr') {
    // CAPACITY-WORDS-1: a line about ONE machine is Path A's own sentence - it
    // stays in its group, or moves with no capacity reservation. The label
    // said a reservation was being made for a wave set to None (measured in the lab).
    if (e.vmId && e.detail) return e.detail;
    if (/RELEASED/i.test(e.detail ?? '')) return UX_STEP.releaseCap;
    return UX_STEP.reserveCap;
  }
  if (/verifySafetyCopies/.test(e.step ?? '') && e.outcome === 'fail') return UX_STEP.verifyCopiesFailed;
  // TERMS-AUDIT-1 review: /lockSnapshot/ also matches unlockSnapshot, as it did in the label map.
  if (/(^|:)lockSnapshot\b/.test(e.step ?? '') && e.outcome === 'warn') return UX_STEP.lockCopySkipped;
  if (/^engine:/.test(e.step ?? '')) {
    if (e.engineVersion) return UX_STEP.engineStarted.replace('{v}', e.engineVersion);
    if (e.peakWorkerMB) return UX_STEP.engineMemoryPeak.replace('{max}', e.peakWorkerMB).replace('{n}', e.workersAtPeak);
    // the engine's refusals write their own sentence (an unapproved wave,
    // a missing acknowledgement); it is the one thing to show.
    if (e.outcome === 'fail' && e.detail) return e.detail;
  }

  // STEP-WORDS-1: the steps that say what they say. Before the table, so a
  // generic heading can never take a sentence's place.
  if (Object.prototype.hasOwnProperty.call(SAYS_ITSELF, e.step ?? '')) {
    return e.detail ? e.detail : UX_STEP[SAYS_ITSELF[e.step]];
  }
  for (const [re, id] of STEP_MAP) {
    if (re.test(e.step)) {
      if (id === null) { const s = UX_STATE[e.step.replace(/^azureops:/, '')]; return s ? s[1] : e.step; }
      // DISK-TYPE-WORDS-1: the change said "Premium SSD" for every type, also
      // a change to Standard SSD. The engine puts the type it sets on the line.
      if (id === 'setDiskType' || id === 'setDiskTypeBack') {
        const type = Object.prototype.hasOwnProperty.call(UX_STEP.diskTypes, e.skuName ?? '') ? UX_STEP.diskTypes[e.skuName] : null;
        if (type) return UX_STEP[`${id}To`].replace('{type}', type);
      }
      return UX_STEP[id];
    }
  }
  // "Starting the virtual machine" appeared AFTER "Running checks
  // inside the machine", which reads as checks running on a stopped machine.
  // The engine order was right - start, then checks - but the state's
  // COMPLETION event carried the same words as its BEGINNING, so finishing
  // looked like starting again.
  //
  // A state has two moments and they are not the same sentence.
  const s = UX_STATE[e.step];
  if (s && e.outcome === 'ok' && UX_STATE_DONE[e.step]) return UX_STATE_DONE[e.step];
  return s ? s[1] : e.step;
}

// NAME-1: engine records carry the internal path letter ("Path A") - displayed
// technical lines get the real name; the untouched raw string moves into the
// tooltip.
const techText = (s) => String(s ?? '')
  .replace(/\bPath A\b/g, UX_PATH.A);

const CHECKPOINT_TEXT = {
  'A:diskPatched':   UX_STEP.updateDisks,
};

// ---------- time helpers ----------
function ago(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 90) return `${Math.round(s)}s ago`;
  if (s < 5400) return `${Math.round(s / 60)}m ago`;
  if (s < 129600) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
const STUCK_SECONDS = 900;

// ---------- data source: demo (bundled) or live (blob REST via MSAL) ----------
let cfg = null, msalApp = null, account = null;
// RETRY-1: code -> {title, meaning, whatToDo, touched, retry}, filled at load
// from the engine's own stop-reasons.json. Empty is a valid state.
const stopReasons = new Map();
// LAB-UX-1: retry kind -> the line shown after whatToDo, from the same file.
let retryLines = {};
async function getToken() {
  const req = { scopes: [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
async function blobFetch(path, { asText = false, asVersioned = false } = {}) {
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription.
   *
   * OPT-DROP-1: asVersioned is forwarded, and it was not. PLANVER-2 added a
   * caller that passes it; this function destructured only asText and passed
   * only asText, so the option was SILENTLY DROPPED - storeBlob returned a
   * parsed object, `.text` was undefined, and the next line reported
   * `"undefined" is not valid JSON` from JSON.parse. Approve could not open.
   *
   * MEASURED IN THE BROWSER, 2026-09-18, on the first click. No test saw it:
   * the page tests stub `source.readVersioned`, so the one link in the chain
   * that was broken - this function - was never run.
   *
   * An option a caller passes and a callee drops is the same defect as a
   * parameter that was never declared: nothing fails, and the next line lies. */
  return VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asText, asVersioned });
}
async function blobList(prefix, delimiter) {
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return VmfHelp.storeList(() => getToken(), cfg.apiUrl, prefix, delimiter);
}
/* PERF-PROBES-1: the files of one folder of a run, from a listing of the whole
 * run, named as source.listFolder names them (from the run, not the store).
 * null when the listing cannot say, and the folder is then listed itself. */
function runListed(listing, run, folder) {
  if (!listing || listing.truncated) { return null; }
  const at = `${run}/${folder}/`;
  return (listing.names || []).filter(n => n.startsWith(at)).map(n => n.slice(run.length + 1));
}
const source = DEMO_MODE ? {
  async listRuns() { return [VmfHelp.sampleRun.runId]; },
  async readJson(run, rel) { return structuredClone(DEMO[rel] ?? null); },
  async readRoot(rel) { return structuredClone(DEMO_ROOT[rel] ?? null); },
  async readText(run, rel) { return DEMO_TEXT[rel] ?? null; },
  async readVersioned(run, rel) { return { text: DEMO_TEXT[rel] ?? null, version: 'demo' }; },
  async listFolder(run, folder) { return Object.keys(DEMO).filter(k => k.startsWith(folder + '/')); },
  // PERF-PROBES-1: the demo has no listing, so it reads everything, as before.
  async listRun() { return null; },
  async readLines(run, rel) { return (DEMO[rel] ?? []).slice(); },
} : {
  // PROJECT-1: runs may live inside a project now. One shared rule (help.js).
  // PAGE-LOAD-2: `held`, when given, is the tick's one call for the list, and
  // a listing it holds is not asked for again.
  async listRuns(held) {
    return window.VmfListRuns((prefix, delimiter) => VmfHelp.heldList(held, prefix, delimiter) || blobList(prefix, delimiter));
  },
  async readJson(run, rel) { return blobFetch(`${run}/${rel}`); },
  // RETAIN-UX-1: the daily cleanup's pass record lives at the store root.
  async readRoot(rel) { return blobFetch(rel); },
  async readText(run, rel) { return blobFetch(`${run}/${rel}`, { asText: true }); },
  /* PLANVER-2: the document AND the version the SERVICE issued for it, from one
   * response. See VmfHelp.storeBlob for why a caller must not compute its own. */
  async readVersioned(run, rel) { return blobFetch(`${run}/${rel}`, { asVersioned: true }); },
  async listFolder(run, folder) { return (await blobList(`${run}/${folder}/`)).names.map(n => n.slice(run.length + 1)); },
  // PERF-PROBES-1: every file of the run, at every depth, in one call.
  async listRun(run) { return blobList(`${run}/`); },
  /* EVENTLOG-1: a log that filled carries on in a second document, and a third.
   * help.js walks the parts; this page asks for the log by the name it always
   * used and gets all of it. It also no longer throws on a line that is still
   * being written - that used to take the whole refresh with it.
   * PERF-PROBES-1: `listing`, when given, is a listing of the run, and a part
   * it does not name is not read - the walk ends there, as it does on a part
   * that is not there, without the call that finds nothing. */
  async readLines(run, rel, listing, held) {
    // PAGE-LOAD-2: `held`, when given, is one call for the run, and each part
    // it holds - or says is not there - is not asked for again.
    return VmfHelp.readLogEvents((p) => {
      const known = VmfHelp.heldText(held, p);
      if (known) { return known.value; }
      return VmfHelp.storeHolds(listing, p) ? blobFetch(p, { asText: true }) : null;
    }, `${run}/${rel}`);
  },
};

// ---------- actions (S3-5): POST to the facade AS the signed-in user ----------
// The facade + engine are the real gate (roles, approval binding, audit); the
// checks here only decide what to RENDER. Demo mode shows every control and
// simulates success so the UX can be reviewed offline.
let myRoles = [], apiTokenOk = false, needInteractive = false;
const hasRole = (...r) => DEMO_MODE || r.some(x => myRoles.includes(x));
const actionsReady = () => DEMO_MODE || (Boolean(cfg?.apiUrl && cfg?.apiAppId) && apiTokenOk);
const canApprove = () => actionsReady() && hasRole('Vmf.Approver', 'Vmf.Admin');
const canOperate = () => actionsReady() && hasRole('Vmf.Operator', 'Vmf.Admin');

async function getApiToken(interactive) {
  const req = { scopes: [`api://${cfg.apiAppId}/access_as_user`], account };
  try { return (await msalApp.acquireTokenSilent(req)).accessToken; }
  catch (e) { if (!interactive) throw e; return VmfHelp.tokenOrRedirect(msalApp, req); }
}
function adoptApiToken(tok) {
  apiTokenOk = true; needInteractive = false;
  try { myRoles = JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).roles ?? []; }
  catch { myRoles = []; }
}
async function initActions() {
  if (DEMO_MODE || !cfg?.apiUrl || !cfg?.apiAppId) return;
  try { adoptApiToken(await getApiToken(false)); }
  catch { needInteractive = true; }   // popups need a user gesture: offer a button instead
}
async function apiFetch(path, body, { timeoutMs = 45000 } = {}) {
  if (DEMO_MODE) { await new Promise(r => setTimeout(r, 400)); return demoAnswer(path, body); }
  const token = await getApiToken(true);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  /* PROJECT-4: ONE PLACE THAT KNOWS. Fifteen actions on this page post to a
   * run route, and not one of them carried the project - so all fifteen were
   * broken together. Adding it to fifteen call sites would be fifteen chances
   * to forget it again, and the sixteenth action somebody writes would forget
   * it for certain.
   *
   * The service composes the other half of this in exactly one function, for
   * exactly the same reason: "a right answer written out four times is a wrong
   * answer thirteen times."
   *
   * Only a `runs/` route takes a run id. A project route names its project in
   * the address already, and adding one to it would be noise. */
  const sent = path.startsWith('runs/') ? VmfHelp.VmfRun.withProject(body, currentRun) : body;
  try {
    const r = await fetch(`${cfg.apiUrl}/${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(sent ?? {}),
      signal: ctl.signal,
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
    return data;
  } catch (e) {
    // SLOW-DELETE-1: say WHICH kind of failure, so a caller that can find out
    // what really happened - a delete can look at the list - does so.
    const err = new Error(e.name === 'AbortError' ? UX_ACT.slowService : e.message);
    err.timedOut = e.name === 'AbortError';
    throw err;
  } finally { clearTimeout(timer); }
}
// The scopes list is stable within a session; fetch it once, and warm it when
// the Start-work menu opens so the scan dialog usually has it immediately.
let scopesPromise = null;
// sample data for the scan dialog's pickers (code-side, not UX copy)
const DEMO_API = { scopes: [
  { id: '00000000-0000-0000-0000-000000000001', name: 'Production' },
  { id: '00000000-0000-0000-0000-000000000002', name: 'Development' },
] };

// One confirm dialog for every action: says what will happen, requires a note.
// Every option row is exactly TWO grid items - the control and one span for
// all its words - or the columns break.
const checkOption = (fieldId, o) =>
  `<label><input type="checkbox" name="mf-${fieldId}" value="${esc(o.value)}"><span class="opt">${esc(o.label)}${o.sub ? `<span class="sub">${esc(o.sub)}</span>` : ''}</span></label>`;
const selectOptions = (opts) => opts.map(o => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('');
// LAB-UX-1: the dialog error goes with the dialog.
// DIALOG-STALE-1: a closed dialog is of no machine, and its notice goes.
function closeModal() {
  $('#modal-back').classList.remove('open');
  $('#m-err').style.display = 'none';
  modalMachine = null;
  $('#m-stale').style.display = 'none';
}
/* DIALOG-STALE-1: the machine whose side panel opened the dialog on the
 * screen, or null. Set by panelDialog, cleared by every openModal, so a
 * dialog of the run or a wave never reads as one of a machine. */
let modalMachine = null;
/* Open a dialog from a machine's side panel. The ask function builds the
 * dialog one time, from the state document the panel held, so the dialog
 * keeps its machine: the refresh then tells it when that machine changes. */
function panelDialog(vmId, open) {
  open();
  modalMachine = vmId;
}
/* DIALOG-STALE-1: the refresh read a new state document for vmId. It asks
 * nothing of its own: openDrill calls it only when the panel's change check
 * (drawDrill, with the "... ago" texts left out) found a change. When the
 * dialog on the screen is of this machine, it says the machine changed and
 * shows the new state. The fields, the typed note, the focus and Confirm are
 * not touched, and the dialog stays open: Cancel and Escape still close it
 * (rule 11). Returns true when it said so. */
function markDialogStale(vmId, doc) {
  if (!vmId || modalMachine !== vmId) { return false; }
  const now = doc ? `${esc(UX_ACT.dialogStale)} ${machinePill(doc, machineStatusOf(vmId, doc))}` : esc(UX_ACT.dialogGone);
  const box = $('#m-stale');
  box.innerHTML = `<p>${now}</p><p>${esc(UX_ACT.dialogStaleWhat)}</p>`;
  box.style.display = 'block';
  return true;
}
/* RESTORE-DIALOG-WORDS-1: an option says what it is on the screen, and the
 * why is behind a ? helper (screens show options, not narration). One button
 * with two states, ? and Close, and Escape closes it first (rule 11): the
 * pattern of the wave editor and the targets step. */
function modalHelpHtml(id) {
  return `<button type="button" class="btn small ghost m-help" data-mhelp="${id}" aria-expanded="false" aria-controls="${id}" aria-label="${esc(UX_ACT.optionHelpTip)}" title="${esc(UX_ACT.optionHelpTip)}">?</button>`;
}
/* The words the ? opens, under the sub line of the option. */
function modalHelpText(id, text) {
  return `<span class="m-help-text" id="${id}" hidden>${esc(text)}</span>`;
}
function toggleModalHelp(btn) {
  const text = document.getElementById(btn.dataset.mhelp);
  if (!text) { return; }
  const open = text.hidden;
  text.hidden = !open;
  btn.setAttribute('aria-expanded', String(open));
  btn.setAttribute('aria-label', open ? UX_ACT.close : UX_ACT.optionHelpTip);
  btn.textContent = open ? UX_ACT.close : '?';
}
/* Escape asks this first: true when it closed an open helper, and then the
 * dialog stays open. */
function closeModalHelp() {
  let closed = false;
  document.querySelectorAll('#m-fields [data-mhelp]').forEach(b => {
    if (b.getAttribute('aria-expanded') === 'true') { toggleModalHelp(b); closed = true; }
  });
  return closed;
}
/* One field of the dialog. Every option row is exactly TWO grid items - the
 * control and one span for all its words - or the columns break. */
function modalFieldHtml(f) {
  let inner;
  if (f.type === 'radio') inner = `<label>${esc(f.label)}</label><div class="radio-row">` +
    f.options.map((o, i) => `<label><input type="radio" name="mf-${f.id}" value="${esc(o.value)}"${i === 0 ? ' checked' : ''}><span class="opt">${esc(o.label)}${o.help ? modalHelpHtml(`mf-${f.id}-help-${i}`) : ''}${o.sub ? `<span class="sub">${esc(o.sub)}</span>` : ''}${o.help ? modalHelpText(`mf-${f.id}-help-${i}`, o.help) : ''}</span></label>`).join('') + '</div>';
  // WAVE-WORDS-3: a box that says its own sentence needs no label above it,
  // or the dialog says the sentence twice.
  else if (f.type === 'checks') inner = (f.label ? `<label>${esc(f.label)}</label>` : '') + '<div class="radio-row">' +
    (f.options.length ? f.options.map(o => checkOption(f.id, o)).join('')
      : `<p class="muted">${esc(f.empty ?? '')}</p>`) + '</div>';
  else if (f.type === 'select') inner = `<label for="mf-${f.id}">${esc(f.label)}</label>` +
    `<select id="mf-${f.id}">` + (f.options ?? []).map(o =>
      `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('') + '</select>';
  else if (f.type === 'textarea') inner = `<label for="mf-${f.id}">${esc(f.label)}</label><textarea id="mf-${f.id}" rows="2"></textarea>`;
  else inner = `<label for="mf-${f.id}">${esc(f.label)}</label><input id="mf-${f.id}" type="${f.type ?? 'text'}" value="${esc(f.value ?? '')}"` +
    `${f.min != null ? ` min="${esc(f.min)}"` : ''}${f.max != null ? ` max="${esc(f.max)}"` : ''}>` +
    // SCALE-UX-1: a field may carry a sentence under it, and a live estimate.
    (f.hint || f.live ? `<div class="hint" id="mf-${f.id}-hint"></div>` : '');
  return `<div class="mf" data-mf="${esc(f.id)}">${inner}</div>`;
}
function openModal({ title, desc, fields = [], onConfirm, doneMessage, confirmLabel, rawDesc = false }) {
  modalMachine = null;
  $('#m-stale').style.display = 'none';
  $('#m-stale').innerHTML = '';
  $('#m-title').textContent = title;
  // rawDesc: the caller renders markup of its own (the WAVE-2 acceptance
  // lists the levers in a table). Every interpolated value must be esc()'d
  // by that caller - nothing user-typed reaches here unescaped.
  if (rawDesc) { $('#m-desc').innerHTML = desc; } else { $('#m-desc').textContent = desc; }
  $('#m-err').style.display = 'none';
  $('#m-cancel').textContent = UX_ACT.cancel;
  const confirmBtn = $('#m-confirm');
  // DIAG-1: "Confirm" is the right word for an action with consequences. For a
  // download it says nothing, so a caller may name its own button.
  confirmBtn.textContent = confirmLabel ?? UX_ACT.confirm;
  confirmBtn.disabled = false;
  $('#m-fields').innerHTML = fields.map(modalFieldHtml).join('');
  $('#m-fields').querySelectorAll('[data-mhelp]').forEach(b => b.addEventListener('click', (ev) => { ev.preventDefault(); toggleModalHelp(b); }));
  // SCALE-UX-1: the sentence under a field, and an estimate that follows the
  // value as it is typed - so the answer is on the screen before Confirm.
  for (const f of fields) {
    if (!f.hint && !f.live) continue;
    const input = $(`#mf-${f.id}`);
    const out = $(`#mf-${f.id}-hint`);
    const paint = () => { out.textContent = [f.hint, f.live ? f.live(input.value) : ''].filter(Boolean).join(' '); };
    input.addEventListener('input', paint);
    paint();
  }
  // Conditional fields: shown only while the controlling radio holds the value.
  const syncVis = () => {
    for (const f of fields) {
      if (!f.showWhen) continue;
      const v = document.querySelector(`input[name="mf-${f.showWhen.id}"]:checked`)?.value;
      const match = f.showWhen.valueIn ? f.showWhen.valueIn.includes(v) : v === f.showWhen.value;
      $(`#m-fields .mf[data-mf="${f.id}"]`).style.display = match ? '' : 'none';
    }
  };
  $('#m-fields').querySelectorAll('input[type=radio]').forEach(r => r.addEventListener('change', syncVis));
  syncVis();
  // CONFIRM-DIALOG-OUT-OF-VIEW-1: the box scrolls inside itself when it is
  // taller than the window (app.css), and it is one box for every dialog, so
  // each open starts at its top, once it is on the screen. Then the focus
  // goes to the first field.
  $('#modal-back').classList.add('open');
  const box = $('#modal-back .modal');
  if (box) { box.scrollTop = 0; }
  $('#m-fields').querySelector('input,textarea')?.focus();
  const showErr = (m) => { $('#m-err').textContent = m; $('#m-err').style.display = 'block'; };
  confirmBtn.onclick = async () => {
    const values = {};
    for (const f of fields) {
      values[f.id] = f.type === 'radio'
        ? document.querySelector(`input[name="mf-${f.id}"]:checked`)?.value
        : f.type === 'checks'
        ? [...document.querySelectorAll(`input[name="mf-${f.id}"]:checked`)].map(x => x.value)
        : f.type === 'select'
        ? $(`#mf-${f.id}`)?.value
        : $(`#mf-${f.id}`)?.value.trim();
    }
    const noteField = fields.find(f => f.id === 'note');
    if (noteField && noteField.required !== false && !values.note) { showErr(UX_ACT.noteMissing); return; }
    // LAB-UX-1: the note is there now, so the error that asked for it goes -
    // it stayed on screen while the action it was about went through.
    $('#m-err').style.display = 'none';
    confirmBtn.disabled = true; confirmBtn.innerHTML = UX_ACT.working;
    try {
      // EVAL-M11: the handler's own return value wins. Scheduling a wave set
      // the correct "Scheduled for..." message and this line overwrote it
      // unconditionally with "The wave is starting", so an operator scheduling
      // a production wave for 02:00 read, in the page's only confirmation,
      // that machines were moving now - and the page contradicted itself
      // seconds later with a "Scheduled for" pill.
      const handlerMessage = await onConfirm(values);
      closeModal();
      $('#err').style.display = 'none';   // CLICKS-LOST-1: a new start clears the old error
      $('#ok').textContent = (typeof handlerMessage === 'string' && handlerMessage)
        ? handlerMessage : (doneMessage ?? UX_ACT.done);
      $('#ok').style.display = 'block';
      setTimeout(() => { $('#ok').style.display = 'none'; }, 12000);
      followThrough();
    } catch (e) {
      // Every action on this page comes through this one catch, so this is
      // the only place the action explainer belongs - and the only place it
      // could have been missed. A facade refusal is about APP ROLE and must
      // never be reported as an Azure storage permission.
      showErr(VmfHelp.explainAction(e));
      confirmBtn.disabled = false; confirmBtn.textContent = confirmLabel ?? UX_ACT.confirm;
    }
  };
}
// A reason is required for actions that CHANGE something; scanning and
// planning read and compute only.
const noteField = (required = true) =>
  ({ id: 'note', label: required ? UX_ACT.noteLabel : UX_ACT.noteOptional, type: 'textarea', required });
/* PROJECT-4: a run inside a project is `project/run`, and the two halves go to
 * DIFFERENT PLACES - the run alone in the address, the project in the body.
 * This page did neither. It put the whole id in the address with the slash
 * escaped, which no route matches, and it never sent the project at all, so
 * every action on this page answered "That record is not there" for any run
 * inside a project - which is every run the product makes now.
 *
 * MEASURED IN THE BROWSER, 2026-09-17, on a corporate install, by
 * pressing Accept and reading what came back.
 *
 * The helper is the one the wizard and the waves editor already use.
 *
 * Written as a DECLARATION, not an arrow constant, because that is what makes
 * it testable: the harness lifts a named function out of a page and runs it,
 * and an arrow held in a const cannot be lifted. The page that could not be
 * driven is the page whose defect survived. */
function runSeg() {
  return VmfHelp.VmfRun.routeSegment(currentRun);
}

// AN-PLAN-1: the machines the plan turns accelerated networking on for. Named
// in the acceptance, so accepting is the one approval - the move no longer
// stops to ask. WAVE-AN-NAMES-1: EVERY machine whose move turns it on, not
// only those whose size requires it, from the record the engine writes on
// each entry; the machines whose move decides are named on their own row. The
// rule is in help.js, and Run it asks the same one.
const anTurnsOnNames = (entries) => VmfHelp.anOutcomeNames(entries, 'on', vmName);
const anDecidedNames = (entries) => VmfHelp.anOutcomeNames(entries, 'decides', vmName);
// MANA-LINUX-KERNEL-1: the machines that update their kernel when it has no
// MANA driver. Each chose it on the targets step, as its own decision; no wave
// has a kernel setting (WAVE-KERNEL-LINE-1).
const kernelUpdateNames = (entries) => (entries ?? [])
  .filter(e => e.policy?.onDriverBelowFloor === 'updateKernel')
  .map(e => vmName(e.vmId));

// WAVE-OPTIONS-DISKS-1: each machine whose move changes the type of a disk, with the
// type it changes to. Named in the acceptance, so nobody accepts a wave
// without seeing it. The rule is in help.js.
function diskChangeTexts(entries) {
  const typeOf = { 'os-standard-ssd': UX_LEVER.diskStandardSsdOs, os: UX_LEVER.diskPremiumOs, all: UX_LEVER.diskPremiumAll };
  return (entries ?? []).filter(e => VmfHelp.diskUpgradeOf(e))
    .map(e => UX_LEVER.diskMachine.replace('{name}', vmName(e.vmId)).replace('{type}', typeOf[VmfHelp.diskUpgradeOf(e)]));
}


// WAVE-2: the acceptance modal LISTS the levers - clicking "accept" on
// options you were never shown is the checkbox this rule exists to kill.
//
// ACCEPT-HASH-1: and it has to be the SAME levers all the way through. This
// used to draw the table from the cached plan - as old as the last refresh
// tick - and then send only the wave's name, so the service hashed whatever
// plan.json held when the request landed. Two ways to record a signature over
// settings nobody saw: the table was stale on arrival, or a Vmf.Operator
// rewrote the wave while the dialog sat open.
//
// So the plan is read again NOW, the table is drawn from those exact bytes,
// and their hash travels with the acceptance. The service refuses if it moved
// again. Acceptance is the UNIVERSAL gate - approval is a lever a wave may or
// may not carry - so this matters more than the approval guard it copies.
async function askAcceptOptions(wave) {
  // SIGNOFF-NULL-1: waveAll is every machine of the wave - the set the
  // engine's approval gate reads.
  let planHash = null, entries = [], waveAll = [];
  if (DEMO_MODE) {
    // ACCEPT-SET-1: the machines that move - the set the acceptance covers.
    entries = (planDoc?.entries ?? []).filter(e => e.wave === wave && e.path === 'A');
    waveAll = (planDoc?.entries ?? []).filter(e => e.wave === wave);
  } else {
    try {
      const plan = await source.readVersioned(currentRun, 'plan.json');
      const planText = plan.text;
      planHash = plan.version;
      const all = (JSON.parse(planText).entries) ?? [];
      entries = all.filter(e => e.wave === wave && e.path === 'A');
      waveAll = all.filter(e => e.wave === wave);
    } catch (err) {
      // The plan IS what the acceptance signs. If it cannot be read there is
      // nothing to bind an agreement to, so refuse to open the dialog rather
      // than record agreement to settings that were never read. This read goes
      // through the facade, so it is the ACTION explainer that answers
      // (FAIL-TEXT-2).
      $('#err').textContent = VmfHelp.explainAction(err);
      $('#err').style.display = 'block';
      return;
    }
  }
  // ACCEPT-FIRST-MACHINE-1: the settings of the wave by the wave editor's rule
  // (help.js waveCard), over every machine of the wave as the editor reads
  // them - never the first machine. Under a setting, each machine that does
  // not follow it, in the editor's words (help.js ownRowText). No button: this
  // dialog shows, and the wave editor changes.
  const card = VmfHelp.waveCard(waveAll);
  const lever = card.values;
  const ownOf = (field) => {
    const own = waveAll.filter(e => (card.own[field] ?? []).includes(e.vmId));
    if (!own.length) return '';
    return `<div class="muted hint" style="font-size:12px;margin-top:6px">${esc(VmfHelp.ownCountText(own.length))}</div>` +
      own.map(e => `<div class="hint" data-ownrow style="font-size:12px">${esc(VmfHelp.ownRowText(field, e, vmName))}</div>`).join('');
  };

  const waveSeriesText = (es) => {
    const counts = new Map();
    // BSV2-TARGET-1: by the series a person reads - a Bsv2 size is planned on v5.
    for (const e of es) { const s = VmfHelp.seriesLabel(e.policy?.targetGeneration ?? 'v6', e.target?.size); counts.set(s, (counts.get(s) ?? 0) + 1); }
    const name = (s) => ({ v5: UX_LEVER.genV5, v7: UX_LEVER.genV7, Bsv2: UX_LEVER.genBsv2 })[s] ?? UX_LEVER.genV6;
    if (counts.size <= 1) return name([...counts.keys()][0] ?? 'v6');
    return UX_LEVER.genMixed.replace('{parts}', [...counts.entries()].sort(([a], [b]) => a.localeCompare(b))
      .map(([s, n]) => UX_LEVER.genCount.replace('{n}', n).replace('{series}', s)).join(', '));
  };
  const rows = [
    [UX_LEVER.safetyCopy, UX_LEVER.safetyCopyAlways, UX_LEVER.safetyCopyHint],
    (lever.capacityGate === 'Reserved') ? [UX_LEVER.capacityGate, UX_LEVER.capReserved, UX_LEVER.capReservedHint]
                                        : [UX_LEVER.capacityGate, UX_LEVER.capOnDemand, UX_LEVER.capOnDemandHint],
    // SIGNOFF-NULL-1: as the engine's gate reads it - any machine of the wave that requires it.
    [UX_LEVER.requireApproval, waveAll.some(VmfHelp.approvalRequired) ? UX_LEVER.yes : UX_LEVER.no],
    (lever.onDDataFound === 'proceed') ? [UX_LEVER.onDDataFound, UX_LEVER.dataProceed, '', 'onDDataFound'] : [UX_LEVER.onDDataFound, UX_LEVER.dataStop, UX_LEVER.dataStopHint, 'onDDataFound'],
    // WAVE-KERNEL-LINE-1: no row for a kernel setting of the wave - there is
    // none. The machines that update their kernel are named on their own row.
    // REBUILD-REMOVE-ACCEPT-1: no row for a system-assigned identity - no
    // move rebuilds a machine, so every machine keeps its identity.
    [UX_LEVER.anMachines, anTurnsOnNames(entries).join(', ') || UX_LEVER.identityNone],

    // The sentence explains the names, so a row that says None has none.
    [UX_LEVER.anDecidesMachines, anDecidedNames(entries).join(', ') || UX_LEVER.identityNone, anDecidedNames(entries).length ? UX_LEVER.anDecidesHint : ''],
    [UX_LEVER.kernelMachines, kernelUpdateNames(entries).join(', ') || UX_LEVER.identityNone],
    // EOL-RELEASE-AN-1: each machine an approver accepted at Checking
    // (linuxReleaseEndOfLife), by the plan value the decision wrote.
    [UX_LEVER.eolMachines, (entries ?? []).filter(e => e.policy?.onReleaseEndOfLife === 'proceed').map(e => vmName(e.vmId)).join(', ') || UX_LEVER.identityNone],
    [UX_LEVER.diskMachines, diskChangeTexts(entries).join(', ') || UX_LEVER.identityNone],
    // GEN-V5-1: every series by name - v5 was shown as v6. ADVISOR-1: counted
    // over the wave's machines, which each have their own series, rather than
    // read off the first one.
    [UX_LEVER.targetGen, waveSeriesText(entries)],
    [UX_LEVER.keepDays, leverKeepDays(lever.keepSnapshotDays), '', 'keepSnapshotDays'],
    // MACHINES-AT-ONCE-RANGE-1: the choice, its machines and its engine
    // containers, by the engine's own rule.
    [UX_LEVER.atOnce, VmfHelp.atOnceChoice(VmfHelp.waveAtOnce(entries)).label],
  ].map(([k, v, hint, field]) => `<tr><td class="muted">${esc(k)}</td><td>${esc(v)}${hint ? `<div class="muted hint" style="font-size:12px">${esc(hint)}</div>` : ''}${field ? ownOf(field) : ''}</td></tr>`).join('');
  // PLAN-NOTES-RUNPAGE-1: each machine that moves, by name, with the notes
  // the plan wrote for it under it - every note, by the rule Run it reads
  // (help.js planNotesOf). Before this, a person who accepted a wave here was
  // never told, for example, that the move downloads the MANA driver.
  const notes = entries.map(e => [e, VmfHelp.planNotesOf(e)]).filter(([, n]) => n.length)
    .map(([e, n]) => `<div class="mono">${esc(vmName(e.vmId))}</div>` +
      n.map(t => `<div style="margin:0 0 4px 12px">${esc(t)}</div>`).join('')).join('');
  const notesRow = `<tr><td class="muted">${esc(UX_LEVER.planNotes)}</td><td>${notes || esc(UX_LEVER.identityNone)}</td></tr>`;
  // ROLLBACK-CAPACITY-1, FILTER-DRIVER-READ-1 and DISK-PATH-READ-1: the lines
  // under the table, each only for a wave it is true of, by the one rule of
  // help.js that Run it in the wizard asks too.
  // SQL-TEMPDB-SIGNOFF-1: and the SQL Server machines whose target has an NVMe
  // temporary disk or none, by name.
  const riskLines = VmfHelp.signOffRiskLines(entries, { capacity: UX_LEVER.capacityNoGuarantee,
    nvme: [UX_LEVER.nvmeThirdParty, UX_LEVER.nvmeThirdPartyWhat, UX_LEVER.nvmeDiskPaths], sql: UX_LEVER.sqlTempdb }, vmName)
    .map(t => `<p data-waverisk style="margin:10px 0 0">${esc(t)}</p>`).join('');
  // This dialog used to ask "why?", which is the wrong question: accepting is
  // not a justification, it is agreement. What the record needs is WHO and WHEN, and
  // it already has both. So there is no note here, and the other way out of
  // the dialog is the one a person actually wants: change the settings.
  const editHref = `${VmfHelp.VmfRun.link('waves.html', currentRun)}#wave=${encodeURIComponent(wave)}`;
  // REBUILD-REMOVE-ACCEPT-1: no list of machines a rebuild moves or whose
  // identity it deletes, and no box for them.
  openModal({ title: UX_ACT.acceptOptionsTitle,
    desc: `${UX_ACT.acceptOptionsDesc}<div class="tablebox" style="margin-top:8px"><table><tbody>${rows}${notesRow}</tbody></table></div>${riskLines}` +
          `<p style="margin:10px 0 0"><a href="${editHref}">${esc(UX_ACT.acceptOptionsEdit)}</a></p>`,
    rawDesc: true,
    confirmLabel: UX_ACT.acceptOptionsConfirm,
    onConfirm: () => apiFetch(`runs/${runSeg()}/waves/accept-options`, { wave, planHash })
      .catch(e => { throw new Error(/^409/.test(e.message) ? UX_ACT.acceptOptionsStale : e.message); }) });
}
// APPR-2: the same SHA-256 the engine computes over plan.json, in the same
// shape - hex, lower case. crypto.subtle needs a secure context, which https
// and localhost both are.

// APPR-2: an approval is only worth something if it signs the plan the
// approver LOOKED AT. This dialog used to send a note and nothing else, so the
// facade hashed whatever plan.json held when the request landed. The wave
// table behind the dialog is as new as the last refresh tick, and a
// Vmf.Operator may rewrite a wave - membership and levers, with no approver
// involved - in the seconds the dialog is open. So read the plan again NOW,
// sign those exact bytes, and let the facade refuse if it moves again.
async function askApprove(wave) {
  let planHash = null, covered = 0, moving = [];
  // MANUAL-SHOTS-1: ?demo counts the machines from its sample plan, so the
  // dialog does not say it approves no machines.
  if (DEMO_MODE) {
    covered = (planDoc?.entries ?? []).filter(e => e.wave === wave).length;
    moving = (planDoc?.entries ?? []).filter(e => e.wave === wave && e.path === 'A');
  }
  if (!DEMO_MODE) {
    try {
      const plan = await source.readVersioned(currentRun, 'plan.json');
      const planText = plan.text;
      planHash = plan.version;
      const all = (JSON.parse(planText).entries) ?? [];
      covered = all.filter(e => e.wave === wave).length;
      moving = all.filter(e => e.wave === wave && e.path === 'A');
    } catch (err) {
      // The plan IS what the approval signs. If it cannot be read there is
      // nothing to bind a signature to, so refuse to open the dialog rather
      // than approve blind. This read goes through the facade, so it is the
      // ACTION explainer that answers - a role refusal here is about the app
      // role, never about storage (FAIL-TEXT-2).
      $('#err').textContent = VmfHelp.explainAction(err);
      $('#err').style.display = 'block';
      return;
    }
  }
  // REBUILD-REMOVE-ACCEPT-1: no list of identities to accept - no move
  // rebuilds a machine.
  openModal({ title: UX_ACT.approveTitle,
    desc: `${esc(UX_ACT.approveDesc)} ${esc(UX_ACT.approveCovers.replace('{n}', covered).replace('{w}', wave))}`,
    rawDesc: true,
    fields: [noteField()],
    onConfirm: v => apiFetch(`runs/${runSeg()}/waves/${encodeURIComponent(wave)}/approve`, { note: v.note, planHash })
      .catch(e => { throw new Error(/^409/.test(e.message) ? UX_ACT.approveStale : e.message); }) });
}
// REACH-1: the actions that used to be commands somebody ran outside this
// app, rather than sending a person to run PowerShell commands outside it.
function askHalt() {
  openModal({ title: UX_ACT.pause, desc: UX_ACT.pauseDesc, fields: [noteField()],
    onConfirm: v => apiFetch(`runs/${runSeg()}/halt`, { note: v.note }) });
}
function askResume() {
  openModal({ title: UX_ACT.resume, desc: UX_ACT.resumeDesc, fields: [noteField()],
    onConfirm: v => apiFetch(`runs/${runSeg()}/resume`, { note: v.note }) });
}
/* PANEL-OLD-STOP-2: the newest stop with a reason code in the machine's
 * CURRENT attempt, or null. The side panel's buttons take their rules from it
 * (stopControls), and the stop box builds on it (currentStop).
 * A retry starts an attempt: it re-arms the machine at a step of the move and
 * writes that step (Resolve-VmfDecision), so any later entry in a state that
 * is not a stop belongs to a later attempt, and the older stop no longer
 * governs. A machine that then stops with no reason code gets the default
 * controls of a stopped machine - an old notSupported or outOfScope reason
 * must not hide Try this machine again.
 * A restore does NOT start an attempt (it writes no step), so an
 * old notSupported stop still governs after one: there, a retry is theatre.
 * PURE. */
function attemptStop(doc) {
  const history = doc?.history ?? [];
  let at = -1;
  for (let i = history.length - 1; i >= 0; i--) { if (history[i] && history[i].reasonCode) { at = i; break; } }
  if (at < 0) { return null; }
  if (history.slice(at + 1).some(h => h && h.state && !PROBLEM_STATES.includes(h.state))) { return null; }
  return history[at];
}
/* PANEL-OLD-STOP-1: the stop that still describes the machine, or null.
 * The newest entry with a reason code is not always it: a retry writes
 * entries with none, so a machine that migrated after a retry showed the
 * stop of its first attempt - "This account cannot finish the migration",
 * on a machine that had. A stop is current only while:
 *   - the machine is still in a stopped state (PROBLEM_STATES);
 *   - no later entry moved it on: it is the stop of the current attempt
 *     (attemptStop);
 *   - no restore is as new as it - the rule decisionWaiting and
 *     retryHeld use for the same records.
 * The timeline still shows every stop: it is the record. PURE. */
function currentStop(doc) {
  if (!PROBLEM_STATES.includes(doc?.state)) { return null; }
  // The stop of the current attempt (attemptStop, PANEL-OLD-STOP-2).
  const stop = attemptStop(doc);
  if (!stop) { return null; }
  const later = [doc.restore?.restoredUtc].filter(Boolean);
  if (later.length) {
    const stoppedAt = Date.parse(stop.tsUtc ?? '');
    if (Number.isNaN(stoppedAt)) { return null; }
    if (later.some(s => { const t = Date.parse(s); return Number.isNaN(t) || t >= stoppedAt; })) { return null; }
  }
  return stop;
}

/* STOP-HEADLINE-CHECK-1: the failed check's own sentence in the detail of a
 * rolled-back stop, or null. The engine writes the whole stop as one string
 * (Complete-VmfRollback): "The Verifying step failed, and the product rolled the machine back to
 * how it was: " + why + a note on the power state + a note on the data disks
 * and the capacity reservation group. Only a why that is a sentence written
 * for an operator is taken: the two failures of the Instance Metadata Service
 * check (Test-VmfImdsOutcome), and the wait for the accelerated networking
 * adapter that ran out (AN-AMDV7-VF-GAP-1), with no adapter or with an adapter
 * that carried no traffic (AN-TRAFFIC-VERIFY-1). Any other why - "Guest validation FAILED: ...",
 * "Boot bus mismatch: ...", an error of Azure, anything not known - gives
 * null, and the stop box keeps the whole detail at the bottom, as before.
 * rest is what follows the check (the notes), or ''. PURE. */
const STOP_CHECK = {
  prefix: 'The Verifying step failed, and the product rolled the machine back to how it was: ',
  sentences: [
    /^The Instance Metadata Service answered before the move and does not answer now\. It answers only on the primary network interface, so that interface does not work as it did before the move\./,
    /^The machine reports the size [A-Za-z0-9_-]+, and the plan's target is [A-Za-z0-9_-]+\./,
    // AN-AMDV7-VF-GAP-1: the wait for the accelerated networking adapter ran out (Wait-VmfAcceleratedAdapter).
    /^The accelerated networking adapter did not become ready in \d+ minutes\. The product checked it \d+ times, and found no MANA interface and no SR-IOV virtual function\./,
    // AN-TRAFFIC-VERIFY-1: the adapter was present and carried no traffic for the whole wait.
    /^The accelerated networking adapter is present, but its packet counters showed no traffic in \d+ minutes\. The product checked it \d+ times\./
  ]
};
function stopCheckSentence(detail) {
  const text = String(detail ?? '');
  if (!text.startsWith(STOP_CHECK.prefix)) { return null; }
  const why = text.slice(STOP_CHECK.prefix.length);
  for (const re of STOP_CHECK.sentences) {
    const m = why.match(re);
    if (m) { return { check: m[0], rest: why.slice(m[0].length).trim() }; }
  }
  return null;
}

// RETRY-1: the last thing that failed, and what a person can do about it.
// Returns '' when there is no stop, or when the code has no guidance - an
// unresolved code must never become an invented explanation.
// PANEL-OLD-STOP-1: only the stop that still describes the machine.
function whyStoppedCard(doc) {
  const stop = currentStop(doc);
  if (!stop) return '';
  const g = stopReasons.get(stop.reasonCode);
  // TERMS-AUDIT-1: the code is the technical record, so a tooltip on the
  // title - never a line of its own in code font under the reason.
  const detail = stop.detail ? `<div class="muted" style="margin-top:6px">${esc(stop.detail)}</div>` : '';
  if (!g) return `<div class="card" style="margin:10px 0"><div class="cardbody">
      <b title="${esc(stop.reasonCode)}">${esc(UX_ACT.whyTitle)}</b>${detail}</div></div>`;

  // Where this left the machine. It used to be a boolean that conflated "was
  // it changed" with "is it back", and printed the reassuring half - a machine
  // HELD on its new hardware after a failed health check read as "put back as
  // it was", which is the one fact an operator cannot be told wrongly.
  // FAIL-1: the RECORDED value wins. The same cause can leave a machine
  // untouched at precheck and restored after a rollback, so the branch that
  // knew wrote it down; the table's value is only the fallback for a stop
  // that records none.
  // POWER-ONLY-CHANGED-1: a stop that changed only the power state names it.
  // While it is owed, the retry returns the machine to it first - not a
  // machine to restore, and the reason's own words (a cluster node: "Trying
  // again changes nothing", "Nothing on the machine was changed") are not
  // true of it. Once the product returned it, the machine is as it was.
  const powerFlag = stop.machineState === 'changed' && ['PowerState/deallocated', 'PowerState/stopped', 'PowerState/running'].includes(stop.powerNotPutBack);
  const powerOnly = powerFlag && !!powerOwed(doc);
  const machine = (powerFlag && !powerOnly) ? 'untouched' : (stop.machineState ?? g.machine);
  const stateLine = powerOnly ? UX_ACT.whyPowerNotBack
    : ({ untouched: UX_ACT.whyUntouched, restored: UX_ACT.whyPutBack,
         changed: UX_ACT.whyNotBack }[machine] ?? '');
  const meaning = powerOnly ? UX_ACT.whyPowerMeaning : g.meaning;
  const whatToDo = powerOnly ? UX_ACT.whyPowerDo : g.whatToDo;
  // LAB-UX-1: from stop-reasons.json, the table the migration record reads.
  const retryLine = powerOnly ? '' : (retryLines[g.retry] ?? '');
  // DECIDE-1: an operator who cannot make the decision must be told WHY there
  // is no control, rather than shown a panel with nothing on it. A missing
  // button with no sentence reads as a product that forgot.
  const whoLine = (!!g.decide && !canApprove()) ? `<p class="muted" style="margin:6px 0">${esc(UX_ACT.whyDecideWho)}</p>` : '';
  const warn = (machine === 'changed');
  // STOP-HEADLINE-CHECK-1: a reason whose stop names the check that failed
  // (detailFirst in stop-reasons.json) puts the check's own sentence directly
  // under the title, in normal text, and not again at the bottom. That check
  // is the fact a person acts on; it was in small print under the meaning.
  // Only a sentence written for an operator moves (stopCheckSentence); the
  // notes after it stay at the bottom. Any other detail stays as it was.
  const check = g.detailFirst === true ? stopCheckSentence(stop.detail) : null;
  const checkLine = check ? `<p style="margin:6px 0">${esc(check.check)}</p>` : '';
  const bottom = !check ? detail
    : (check.rest ? `<div class="muted" style="margin-top:6px">${esc(check.rest)}</div>` : '');
  return `<div class="card" style="margin:10px 0${warn ? ';border-color:var(--bad);background:var(--bad-soft)' : ''}">
    <div class="cardbody">
      <b title="${esc(stop.reasonCode)}">${esc(g.title)}</b>
      ${checkLine}
      <p style="margin:6px 0">${esc(meaning)}</p>
      <p style="margin:6px 0"><b>${esc(UX_ACT.whyDo)}:</b> ${esc(whatToDo)} ${esc(retryLine)}</p>
      <div class="muted">${esc(stateLine)}</div>
      ${whoLine}
      ${bottom}
    </div></div>`;
}

/* RESTORE-PANEL-TIMELINE-1: the end of the newest restore of the machine,
 * when it did not finish and nothing came after it, or null. lines: the
 * machine's lines of the run history. Final lab, 2026-11-16: after a restore
 * that Azure refused, the main block of the panel still showed the stop
 * before it, with its What to do. A restore writes no history, so the stop
 * box (currentStop) cannot know that it ran.
 * Its end is every end line after its start line: restore with warn or fail,
 * and the engine's own fail or refused line of the same operation
 * (restoreIndex reads the same lines). Null when:
 *   - no restore started, or it has not ended (the status says Restoring);
 *   - it ended with ok, or its record is as new as its start - the restore
 *     box (restoredNoteHtml) says that, also a swap that waits for Finish;
 *   - the history has an entry after its start: a retry or Leave this
 *     machine out came later, and the machine shows that. PURE. */
function restoreEndAfter(doc, lines) {
  const ms = (v) => Date.parse(v ?? '');
  let start = null;
  for (const e of (lines ?? [])) {
    if (e && e.step === 'restore' && e.outcome === 'start' && (!start || ms(e.tsUtc) >= ms(start.tsUtc))) { start = e; }
  }
  if (!start || !Number.isFinite(ms(start.tsUtc))) { return null; }
  const from = ms(start.tsUtc);
  const ends = (lines ?? []).filter(e => e && ms(e.tsUtc) >= from && (
    (e.step === 'restore' && RESTORE_ENDS.includes(e.outcome)) ||
    (e.step === 'engine:restore' && ['fail', 'refused'].includes(e.outcome) && e.correlationId && e.correlationId === start.correlationId)))
    .sort((a, b) => ms(a.tsUtc) - ms(b.tsUtc));
  if (!ends.length || ends.some(e => e.outcome === 'ok')) { return null; }
  if (ms(doc?.restore?.restoredUtc) >= from) { return null; }
  if ((doc?.history ?? []).some(h => h && ms(h.tsUtc) >= from)) { return null; }
  return { since: start.tsUtc, lines: ends };
}
/* RESTORE-PANEL-TIMELINE-1: the box for that end, in the place of the stop
 * box: that the restore did not finish, and each thing its end lines say -
 * where it left the machine, and why. '' with no end. */
function restoreEndCard(end) {
  if (!end) { return ''; }
  const said = [];
  for (const e of end.lines) {
    for (const s of [stepText(e), e.detail]) { if (s && !said.includes(s)) { said.push(s); } }
  }
  return `<div class="card" style="margin:10px 0;border-color:var(--bad);background:var(--bad-soft)"><div class="cardbody">
      <b>${esc(UX_ACT.restoreNotDone)}</b>
      ${said.map(s => `<p style="margin:6px 0">${esc(s)}</p>`).join('')}
    </div></div>`;
}

/* SAFETY-RETRY-1: when a machine stopped, and the stop's reason in the
 * product's words. PURE, so a test can run it. */
function retryFacts(doc) {
  const stop = [...(doc?.history ?? [])].reverse().find(h => h && (h.reasonCode || h.outcome === 'fail' || h.outcome === 'refused'));
  if (!stop || !stop.tsUtc) return null;
  return { when: stop.tsUtc, reason: stopReasons.get(stop.reasonCode)?.title ?? '' };
}
function askResolve(vmId, doc) {
  // RETRY-1: the operator used to choose between "run the safety checks again"
  // and "only repeat the final health checks". That was engine vocabulary as a
  // question, and the engine already knows the answer - so it decides, and the
  // page only SAYS which it will be. `returnTo` is deliberately not sent.
  const revalidateOnly = doc?.state === 'FAILED_NEEDS_ATTENTION'
    && [...(doc.history ?? [])].reverse().find(h => h.outcome === 'fail')?.reasonCode === 'validationFailedAfterConversion';
  // SAFETY-RETRY-1: the stop's own time and reason first, so a retry days
  // later reads as days later. Built from the record, escaped part by part.
  const f = retryFacts(doc);
  const facts = f ? '<p>' + `<b>${esc(UX_ACT.resolveStopped)}</b> ${esc(new Date(f.when).toLocaleString())} &middot; ${esc(ago(f.when))}`
    + (f.reason ? `<br><b>${esc(UX_ACT.resolveReason)}</b> ${esc(f.reason)}` : '') + '</p>' : '';
  openModal({ title: UX_ACT.resolve, rawDesc: true,
    // VOLUMES-RETRY-CHECK-1: a retry that owes a check of the volumes first
    // checks them, and may stop again with nothing changed.
    desc: facts + `<p>${esc(revalidateOnly ? UX_ACT.resolveRevalidate : doc?.volumesCheckOwed?.reason ? UX_ACT.resolveVolumesFirst : UX_ACT.resolveDesc)}</p>`,
    fields: [noteField()],
    onConfirm: v => apiFetch(`runs/${runSeg()}/vms/resolve`, { vmId, note: v.note }) });
}

/* RETRY-SERIES-1: a machine that rolled back, given another size series so it
 * can be tried again on it. The service says which series the machine may
 * take - the targets step's answer, saved with the plan - and the page offers
 * only those. The machine stays rolled back: Try this machine again runs it,
 * once its wave is accepted and approved again. */
function retrySeriesOptions(answer) {
  return (answer?.Options ?? []).filter(o => o.supported && !o.current && o.targetSize);
}
// MACHINE-PANEL-STALE-1: cacheKey names the run, machine, plan entry and state
// the answer is for. A redraw of the panel (reuse) with the same key uses the
// last answer, with no call to the service. A selected row asks again.
// ROLLBACK-SIZE-REFUSED-SERIES-1: restoreNext - Azure refused the original
// size, so the restore onto the new size is the next step (sizeRefusedStop).
async function fillRetrySeries(vmId, cacheKey, reuse, restoreNext = false) {
  const slot = $('#retryseries-slot');
  if (!slot) return;
  let answer;
  if (reuse && retrySeriesCache && retrySeriesCache.key === cacheKey) {
    answer = retrySeriesCache.answer;
  } else {
    try { answer = await apiFetch(`runs/${runSeg()}/plan/target`, { vmId, preview: true, afterRollback: true }); }
    catch (e) {
      // Say why - a reservation held for the wave, another machine migrating -
      // rather than show nothing.
      if ($('#retryseries-slot') === slot) slot.innerHTML = `<span class="muted">${esc(VmfHelp.explainAction(e))}</span>`;
      return;
    }
    retrySeriesCache = { key: cacheKey, answer };
  }
  // The panel may show another machine by now.
  if ($('#retryseries-slot') !== slot) return;
  // A stable id per series, so the focus can come back to it after a redraw.
  slot.innerHTML = retrySeriesOptions(answer).map(o =>
    `<button type="button" class="btn ghost" id="retryseries-${esc(String(o.option).replace(/[^A-Za-z0-9_-]/g, '_'))}" data-retryseries="${esc(o.option)}" title="${esc(UX_ACT.retrySeriesTip)}">${esc(UX_ACT.retrySeries.replace('{series}', o.option))}</button>`).join('');
  slot.querySelectorAll('[data-retryseries]').forEach(b =>
    b.addEventListener('click', () => panelDialog(vmId, () => askRetrySeries(vmId, answer, b.dataset.retryseries, restoreNext))));
}
function askRetrySeries(vmId, answer, series, restoreNext = false) {
  const o = retrySeriesOptions(answer).find(x => x.option === series);
  if (!o) return;
  // PLANVER-2: the version the options were judged against is quoted back, so
  // a plan changed since is refused rather than changed blind.
  openModal({ title: UX_ACT.retrySeries.replace('{series}', series),
    desc: UX_ACT.retrySeriesDesc.replace('{size}', String(o.targetSize).replace(/^Standard_/, '')),
    // ROLLBACK-SIZE-REFUSED-SERIES-1: the restore onto that size comes next.
    doneMessage: restoreNext ? UX_ACT.retrySeriesDoneRestore : UX_ACT.retrySeriesDone,
    onConfirm: () => apiFetch(`runs/${runSeg()}/plan/target`,
      { vmId, option: series, planVersion: answer.PlanVersion, afterRollback: true }) });
}

/* POWER-ONLY-CHANGED-1: the power state a stop could not put back, while
 * nothing has put it back since - 'PowerState/deallocated',
 * 'PowerState/stopped', 'PowerState/running', or null. The last entry that says where it left the
 * machine decides: changed, with powerNotPutBack. The line of a put-back that
 * worked says untouched, and so ends it. The engine asks the same rule
 * (Get-VmfPowerOwed). PURE: held to tests/fixtures/retry-held.json. */
function powerOwed(doc) {
  const last = [...(doc?.history ?? [])].reverse().find(h => h && h.machineState);
  if (!last || last.machineState !== 'changed') { return null; }
  return ['PowerState/deallocated', 'PowerState/stopped', 'PowerState/running'].includes(last.powerNotPutBack) ? last.powerNotPutBack : null;
}

/* ROLLBACK-RETRY-CAPTURE-1: is Try this machine again refused here, because
 * the last stop left the machine CHANGED and nothing has mended it since? The
 * engine refuses that retry (SAFETY-RETRY-1, Test-VmfRetryHeld): a new "as it
 * was" copy of a changed machine would be wrong. A restore later
 * than the stop mends it. A machine on its new size whose final checks failed
 * repeats the checks only, which the rule does not stop. PURE: held to
 * tests/fixtures/retry-held.json, the cases the engine is held to. */
function retryHeld(doc) {
  // SWAP-REFUSED-AFTER-STOP-1: a refused data disk swap keeps the machine
  // stopped, whatever its last stop or restore record says.
  if (doc?.swapPending) { return true; }
  const history = doc?.history ?? [];
  if (doc?.state === 'FAILED_NEEDS_ATTENTION'
      && [...history].reverse().find(h => h && h.outcome === 'fail')?.reasonCode === 'validationFailedAfterConversion') { return false; }
  const lastChange = [...history].reverse().find(h => h && h.machineState);
  if (!lastChange || lastChange.machineState !== 'changed') { return false; }
  // POWER-ONLY-CHANGED-1: changed only in its power state. The retry puts the
  // power state back first, and there may be no copy to restore.
  if (powerOwed(doc)) { return false; }
  // VOLUMES-RETRY-CHECK-1: a volume not mounted after a rollback or a restore.
  // The retry first checks that every volume mounted before the move is
  // mounted again, so it is offered - only while the record that owes that
  // check is there (volumesCheckOwed), as the engine decides.
  // VOLUMES-NOT-CHECKED-WORDS-1: and a stop of that check that could not run.
  if (['volumesNotBack', 'volumesNotChecked'].includes(lastChange.reasonCode) && doc?.volumesCheckOwed?.reason) { return false; }
  const at = (s) => (s ? Date.parse(s) : NaN);
  const changedAt = at(lastChange.tsUtc);
  const mended = [doc?.restore?.restoredUtc]
    .map(at).filter(t => !Number.isNaN(t) && (Number.isNaN(changedAt) || t > changedAt));
  return mended.length === 0;
}

// DECIDE-2: which controls a stopped machine offers. PURE, so a test can run
// it - the harness rule in tests/js/_harness.js: reading source tells you what
// you meant, only running it tells you what happens. This lived inline in
// openDrill, where nothing could reach it, and the tests matched the source.
//
// Two SEPARATE questions, which DECIDE-1 ran together:
//
//   a CHOICE - a loss a person may accept for this machine. All three of the
//     wave's "stop and ask" gates carry one. It belongs to the approver, and
//     the facade refuses anyone else, so offering it to an operator would only
//     produce a 403. DECIDE-ROLE-1: the approver role ALONE is enough - the
//     facade asks for no operator role here, so canOperateNow is not asked.
//
//   a RETRY - running the machine again. That helps only if something can be
//     corrected. Two of the three gates have a real correction - move the
//     files off the temporary disk, patch the kernel - and there the retry is
//     usually the BETTER answer, so it stays on the panel beside the choice.
//     Only the identity stop has nothing to correct, and there it is theatre:
//     it re-ran the same check against the same setting and parked the machine
//     again.
//
// POWER-ONLY-CHANGED-1: a stop that could not put back the power state the
// machine was found in (powerOwed) always offers the retry: the retry puts
// that power state back first, whatever the stop. A cluster node is outside
// the scope of this tool, and still goes back to its power state that way.
function stopControls(state, guidance, canOperateNow, canApproveNow, powerNotBack) {
  const kind = guidance && guidance.retry;
  const retryStates = ['NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK'];
  return {
    decide: state === 'NEEDS_DECISION' && !!(guidance && guidance.decide) && !!canApproveNow,
    retry: retryStates.includes(state) && (!!powerNotBack || !['notSupported', 'outOfScope', 'decision'].includes(kind)) && !!canOperateNow,
  };
}

/* DECIDE-ROLE-1: the park a machine waits at NOW, or null. The newest entry
 * with a reason code is not always it. The park is the LAST entry, a
 * NEEDS_DECISION entry with a reason code, with no restore as new as it. The engine asks
 * the same rule before it accepts a decision (Get-VmfWaitingDecisionStop).
 * PURE: held to tests/fixtures/decision-waiting.json, the cases the engine is
 * held to. */
function decisionWaiting(doc) {
  if (doc?.state !== 'NEEDS_DECISION') { return null; }
  const history = doc.history ?? [];
  const last = history[history.length - 1];
  if (!last || last.state !== 'NEEDS_DECISION' || !last.reasonCode) { return null; }
  const later = [doc.restore?.restoredUtc].filter(Boolean);
  if (later.length) {
    const parkedAt = Date.parse(last.tsUtc ?? '');
    if (Number.isNaN(parkedAt)) { return null; }
    if (later.some(s => { const t = Date.parse(s); return Number.isNaN(t) || t >= parkedAt; })) { return null; }
  }
  return last;
}

/* SKIP-PREPARED-WORDS-1: where the stop that parked this machine left it -
 * 'untouched', 'restored', 'changed', or null for no claim. The value the
 * engine RECORDED on the stop that still describes the machine (currentStop,
 * the stop the Why it stopped card shows), never the steps the history holds:
 * a preparation that changed the guest is rolled back before the machine
 * parks (PREP-ROLLBACK-1), so GUEST_PREP in the history says nothing about
 * the machine now. A data disk swap that is left keeps the machine stopped
 * with disks from two moments, whatever the stop says. PURE; the engine's
 * Get-VmfSkipMachineState is held to the same tests/fixtures/skip-machine-state.json. */
function skipMachineState(doc) {
  if (doc?.swapPending) { return 'changed'; }
  const stop = currentStop(doc);
  // POWER-ONLY-CHANGED-1: a power state the product returned since the stop.
  if (stop?.machineState === 'changed' && ['PowerState/deallocated', 'PowerState/stopped', 'PowerState/running'].includes(stop.powerNotPutBack) && !powerOwed(doc)) { return 'untouched'; }
  return stop?.machineState || null;
}

/* SKIP-ONE-1: leave ONE machine out.
 *
 * It says what is TRUE of the machine afterwards rather than implying a clean
 * slate, and nothing more (SKIP-PREPARED-WORDS-1): a machine the stop left
 * changed is said to be changed, with no promise that it can migrate later
 * as it is; with no recorded value, nothing is said about the machine. */
function askSkipVm(vmId, doc) {
  // POWER-ONLY-CHANGED-1: a machine whose only change is its power state is
  // returned to it by the engine when it is left out, and then it is free.
  const owed = powerOwed(doc);
  const where = owed ? `${UX_ACT.skipPowerBack.replace('{power}', powerName(owed))} ${UX_ACT.skipLater}`
    : ({ untouched: `${UX_ACT.skipUntouched} ${UX_ACT.skipLater}`,
         restored: `${UX_ACT.skipRunsAsBefore} ${UX_ACT.skipLater}`,
         changed: `${UX_ACT.skipChanged} ${UX_ACT.skipClaimKept}` }[skipMachineState(doc)] ?? UX_ACT.skipLater);
  openModal({ title: UX_ACT.skipTitle,
    desc: `${owed ? UX_ACT.skipDescPower : UX_ACT.skipDesc} ${where}`,
    confirmLabel: UX_ACT.skipConfirm,
    fields: [noteField()],
    // SKIP-ONE-RUNBODY-1: a plain body. apiFetch adds the project (PROJECT-4);
    // `runBody` is a helper of waves.html, and here it threw.
    onConfirm: v => apiFetch(`runs/${runSeg()}/vms/skip`, { vmId, note: v.note }) });
}

// DECIDE-1: the stop that is a CHOICE, decided for ONE machine.
//
// The engine has always supported this - a stop's setting is a plan
// lever, and the resolve endpoint takes a policyOverride - and this page never
// sent one. So the only control on a machine parked by this stop was "Try this
// machine again", which re-ran the same check against the same setting and
// parked it again. The one way through from the app was to change the setting
// for the WHOLE WAVE, which also cleared that wave's approval and dropped the
// same protection from every other machine in it.
//
// The lever and the accepting value come from the stop reason itself, so this
// function never names a setting. A decision added to stop-reasons.json gets a
// working control here without a change to this page.
function askDecide(vmId, g, doc) {
  const lever = g?.decide?.lever, accept = g?.decide?.accept;
  if (!lever || !accept) return;
  // REBUILD-REMOVE-ACCEPT-1: no decision accepts a rebuild or names the
  // account of an identity any more (namesRebuild and namesAccount are gone).
  openModal({ title: UX_ACT.decideTitle,
    desc: `${g.whatToDo} ${UX_ACT.decideDesc}`,
    confirmLabel: UX_ACT.decideConfirm,
    fields: [noteField()],
    onConfirm: async v => decideDoneText(await apiFetch(`runs/${runSeg()}/vms/resolve`,
      { vmId, note: v.note, policyOverride: { [lever]: accept } })) });
}
/* DECIDE-APPROVAL-STALE-1: what a decision says when it is done. A decision
 * writes the plan, and an approval signs the whole plan, so the service removes
 * every wave approval the write made out of date and names those waves - and,
 * of those, the ones that cannot start without a new approval. The plan
 * sign-off still covers the others, and the page offers no Approve for them.
 * A person who approved one of them is told here, where the decision's result
 * is shown, and the activity says the same. Null when it removed none, so the
 * dialog says its usual line. */
function decideDoneText(answer) {
  const list = (raw) => (Array.isArray(raw) ? raw : (raw ? [raw] : [])).filter(Boolean);
  const waves = list(answer?.ApprovalsCleared);
  if (!waves.length) { return null; }
  const renew = list(answer?.ApprovalsToRenew);
  return [UX_ACT.done, ...waves.map(w => (renew.includes(w) ? UX_ACT.decideApprovalGone : UX_ACT.decideApprovalCovered)
    .replace('{wave}', w))].join(' ');
}
// DIAG-1: the support bundle. When something goes wrong that we cannot
// reproduce, the evidence lives in this run - the events, the per-machine
// records, what the plan said, what capacity was claimed. Every drill this week
// found its defect from exactly that trail. Without a way to send it, the first
// real customer failure gets diagnosed by asking someone to run PowerShell down
// a phone line.
//
// Assembled CLIENT-SIDE from reads the viewer already has, so it needs no new
// access path, no new permission, and nothing server-side. It carries run ids
// and machine NAMES - that is the point of it - and no tokens or keys, because
// there are none to carry: every read here is made with the viewer's own
// identity.
const BUNDLE_EVENT_CAP = 2000;

/* RESTORE-COPY-1: which safety copy a restore reads.
 *
 * A migration takes TWO copies, and they mean different things:
 *
 *   pristine  before anything was touched. It predates the guest preparation
 *             that lets the machine boot on the new hardware, so restoring it
 *             ALSO returns the size and the disk controller to what they were.
 *             This is the real rollback.
 *   prepared  taken when the machine was stopped and ready to move. The guest
 *             is already converted, so the machine stays on the new hardware.
 *
 * The engine has always been able to read either. Nothing between this page and
 * the engine carried the choice, so every restore from the app used the
 * engine's default - prepared - and the pristine copy was unreachable. Meanwhile
 * this dialog told the operator it would put the machine back to how it was
 * before the migration, which is the OTHER copy.
 *
 * A wave policy may take only the pre-move copy, in which case there is nothing
 * to choose and the dialog says so rather than offering an option that cannot
 * work. */
/* RESTORE-DIALOG-WORDS-1: a size and a disk controller in the words of the
 * dialog - "D2s_v4, SCSI disk controller". No size, no words: unknown shows no
 * size. A Generation 1 machine has no disk controller on record, so its size
 * stands alone. */
function shapeWords(shape) {
  const size = String(shape?.size ?? '').replace(/^Standard_/i, '');
  if (!size) { return ''; }
  const controller = String(shape?.controller ?? '');
  return controller ? UX_ACT.restoreShape.replace('{size}', size).replace('{controller}', controller) : size;
}

/* RESTORE-DIALOG-WORDS-1: the size and the disk controller of each copy, from
 * the record of the machine - never invented.
 *
 *   before  what the first copy puts the machine back on: the FIRST capture
 *           (Get-VmfPutBackCapture reads the same - its size, else the size of
 *           this attempt, and its controller, also when empty).
 *   now     what the machine is on, which the second copy keeps: the capture
 *           of this attempt, then each record of this attempt that set the
 *           size, oldest first - the resize (CONVERTING ok), a rollback after
 *           it, a restore. A rollback before the move did not
 *           change the size. null when the record cannot say: the resize of
 *           this attempt started and nothing set the machine after it.
 */
function restoreShapes(doc) {
  const vm = doc?.captured?.vmConfig;
  // OLD-STATE-READERS-PAGE-1: PRECHECK writes the first capture with the
  // capture (vm-state v47), so a capture without it says no size.
  const first = doc?.captured?.original?.vmConfig;
  if (!vm || !first) { return { before: null, now: null }; }
  const before = { size: first.size || '', controller: first.controller ?? '' };
  const at = (s) => (s ? Date.parse(s) : 0);
  // A record from an earlier attempt says nothing about now: the attempt
  // starts at its capture.
  const since = at(vm.capturedUtc);
  const started = doc?.captured?.startedTarget;
  const resize = (doc?.history ?? []).filter(h => h?.state === 'CONVERTING' && at(h.tsUtc) >= since);
  const resized = resize.filter(h => h.outcome === 'ok').sort((a, b) => at(b.tsUtc) - at(a.tsUtc))[0];
  // controller undefined: the record keeps the controller the machine had.
  const sets = [
    resized && { at: at(resized.tsUtc), size: started?.size, controller: started?.controller },
    doc?.rollback && doc.rollback.path !== 'disks' && { at: at(doc.rollback.rolledBackUtc), size: before.size, controller: before.controller },
    doc?.restore && { at: at(doc.restore.restoredUtc), size: doc.restore.sizeAfter, controller: doc.restore.fromCopy === 'pristine' ? before.controller : undefined },
  ].filter(r => r && r.at >= since).sort((a, b) => a.at - b.at);
  let now = { size: vm.size || '', controller: vm.controller ?? '' };
  for (const r of sets) {
    now = { size: r.size || '', controller: r.controller === undefined ? now.controller : (r.controller ?? '') };
  }
  const lastSet = sets.length ? sets[sets.length - 1].at : 0;
  if (resize.some(h => h.outcome !== 'ok' && at(h.tsUtc) > lastSet)) { now = null; }
  return { before, now };
}

/* RESTORE-COPY-1: which safety copy a restore reads - each copy that exists,
 * as one short option with its size and disk controller from the record.
 * RESTORE-DIALOG-WORDS-1: a machine with one copy is shown that one only, in
 * the same short form (PREP-ROLLBACK-1: a machine stopped before the second
 * copy has the first one only; a wave policy can take the second one only).
 * What the first copy also does is behind its ? helper: accelerated
 * networking. null when no copy exists. */
function restoreCopyField(doc) {
  const pristine = Boolean(doc?.safety?.pristineSnapshotId);
  const prepared = Boolean(doc?.safety?.snapshotId);
  if (!pristine && !prepared) { return null; }
  const shapes = restoreShapes(doc);
  const options = [
    pristine && { value: 'pristine', label: UX_ACT.restoreFromPristine, sub: shapeWords(shapes.before),
      help: UX_ACT.restorePristineHelp },
    prepared && { value: 'prepared', label: UX_ACT.restoreFromPrepared, sub: shapeWords(shapes.now) },
  ].filter(Boolean);
  return { id: 'diskSource', label: options.length > 1 ? UX_ACT.restoreWhich : UX_ACT.restoreOnlyCopy, type: 'radio', options };
}

/* RESTORE-DIALOG-WORDS-1: the exceptions, said only for a machine whose
 * record shows the disk - in either capture. A shared disk stays as it is
 * (the restore leaves it, by design). A Premium SSD v2 or Ultra Disk whose
 * copy Azure cannot use now stops the restore before it changes the machine
 * (Assert-VmfDataDisksAllBack) - it does NOT stay as it is. */
function restoreExceptions(doc) {
  const disks = [...(doc?.captured?.vmConfig?.dataDisks ?? []), ...(doc?.captured?.original?.vmConfig?.dataDisks ?? [])].filter(Boolean);
  return [
    disks.some(d => Number(d.maxShares) > 1) && UX_ACT.restoreShared,
    disks.some(d => /^(PremiumV2_LRS|UltraSSD_LRS)$/i.test(String(d.skuName ?? ''))) && UX_ACT.restoreInstant,
  ].filter(Boolean);
}
/* RESTORE-DELETE-EXCEPTION-1: the sentence under "No. Delete them", for a
 * machine whose record has a Premium SSD v2 or Ultra Disk data disk (either
 * capture) with a copy on its LUN - the copies the engine reads before it
 * deletes anything (Get-VmfInstantAccessCopyReadiness -Kind all, earlier
 * attempts too). Keeping the names, the engine leaves such a disk as it is
 * while a copy of it is not complete (Get-VmfOperatorDataRestorePlan). The
 * page cannot read the copy's state, so it says the rule; the engine names
 * each disk it leaves. { sub } or nothing. PURE. */
function restoreKeepInstantNote(doc) {
  const s = doc?.safety ?? {};
  const copies = [...(s.pristineDataCopies ?? []), ...(s.dataCopies ?? []),
    ...(s.earlierCopies ?? []).flatMap(e => [...(e?.pristineDataCopies ?? []), ...(e?.dataCopies ?? [])])];
  const copied = new Set(copies.filter(c => c?.snapshotId).map(c => Number(c.lun)));
  const disks = [...(doc?.captured?.vmConfig?.dataDisks ?? []), ...(doc?.captured?.original?.vmConfig?.dataDisks ?? [])].filter(Boolean);
  const has = disks.some(d => /^(PremiumV2_LRS|UltraSSD_LRS)$/i.test(String(d.skuName ?? '')) && copied.has(Number(d.lun)));
  return has ? { sub: UX_ACT.restoreKeepInstant } : {};
}
/* RESTORE-ALL-1: the disks a restore that keeps the names can delete, named
 * one by one in the confirmation - "the current disks" is not something a
 * person can check. They are the disks on the machine now, as its record
 * knows them (a rollback or an earlier restore gave some new names), for
 * every LUN a copy exists for. SAFETY-ULTRA-1: a disk on Premium SSD v2 or
 * Ultra Disk is restored too now, so it is named. The page cannot read whether
 * Azure can use its copy, so it may name a disk the engine then leaves - never
 * the other way round. The engine names each disk it really deletes. */
function restoreDiskNames(doc) {
  const vm = doc?.captured?.vmConfig ?? {};
  let os = vm.osDisk?.name ?? '';
  const names = new Map((vm.dataDisks ?? []).map(d => [Number(d.lun), d.name ?? '']));
  const at = (s) => (s ? Date.parse(s) : 0);
  // Each record that made disks, oldest first, so the newest names what is
  // there now: a rollback and a restore.
  const made = [
    doc?.rollback && { at: at(doc.rollback.rolledBackUtc), os: doc.rollback.osDisk?.name,
      data: (doc.rollback.dataDisks ?? []).map(d => [d.lun, d.diskName]) },
    doc?.restore && { at: at(doc.restore.restoredUtc), os: doc.restore.newDiskName,
      data: (doc.restore.dataDisks ?? []).map(d => [d.lun, d.newDiskName]) },
  ].filter(Boolean).sort((a, b) => a.at - b.at);
  for (const m of made) {
    if (m.os) os = m.os;
    for (const [lun, name] of m.data) names.set(Number(lun), name);
  }
  const copied = new Set([...(doc?.safety?.pristineDataCopies ?? []), ...(doc?.safety?.dataCopies ?? [])]
    .filter(c => c?.snapshotId).map(c => Number(c.lun)));
  const data = (vm.dataDisks ?? [])
    .filter(d => copied.has(Number(d.lun)))
    .map(d => names.get(Number(d.lun)));
  return [os, ...data].filter(Boolean);
}

/* RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): the words for a return to
 * a size Microsoft retires, from what PRECHECK recorded on the machine
 * (captured.putBackRetirement: size, retiresUtc, warnFromUtc). The engine
 * decides the dates; the page compares them with today, as text in the form
 * yyyy-mm-dd. From one day before the date the return is outside the scope of
 * the product, and the service and the engine refuse it; within the 12 months
 * before, it is a warning. No other size is named: a record from V3-RETIRE-1
 * may carry currentSize, and it is not read. Empty when the size has no
 * retirement, the date is more than 12 months away, or the machine started
 * before the record existed.
 */
function putBackRetireNote(doc, today) {
  const r = doc?.captured?.putBackRetirement;
  if (!r?.retiresUtc || !r?.warnFromUtc) { return ''; }
  const day = String(today ?? new Date().toISOString()).slice(0, 10);
  // The engine refuses from one day before the date: a restore started the
  // evening before could reach the old size after midnight.
  const next = new Date(Date.parse(day + 'T00:00:00Z') + 86400000).toISOString().slice(0, 10);
  const words = { size: String(r.size ?? '').replace(/^Standard_/, ''), date: String(r.retiresUtc).slice(0, 10) };
  const fillIn = (t) => t.replace('{size}', words.size).replace('{date}', words.date);
  if (next >= words.date) { return fillIn(UX_ACT.retireRefused); }
  if (day >= String(r.warnFromUtc).slice(0, 10)) { return fillIn(UX_ACT.retireWarn); }
  return '';
}

// ROLLBACK-SIZE-REFUSED-SERIES-1: onto - restoreOntoTarget, from the panel.
function askRestore(vmId, doc, onto = null) {
  // RESTORE-1 in the UX: the disaster path belongs where the failure is
  // visible. The destructive option cannot be softer here than on the command
  // line, so it needs the same explicit acknowledgement.
  // RESTORE-DIALOG-WORDS-1: two questions - which safety copy, and keep the
  // current managed disks or not - and the button says Restore. The first
  // option of each is the one checked: keeping the disks is the default.
  const copyField = restoreCopyField(doc);
  const copies = (copyField?.options ?? []).map(o => o.value);
  const choice = copies.length > 1;
  const onlyFirst = copies.length === 1 && copies[0] === 'pristine';
  const deletes = restoreDiskNames(doc);
  // V3-RETIRE-1: said only where the first copy can be chosen - the other
  // copy keeps the size the machine has now.
  const retire = copies.includes('pristine') ? putBackRetireNote(doc) : '';
  // ROLLBACK-SIZE-REFUSED-SERIES-1: the size the first copy goes onto, when
  // Azure refused the original size and the plan has another series now. A
  // refused one is the service's 400, said in place of the dialog's result.
  const ontoWords = (copies.includes('pristine') && onto && !onto.refused) ? UX_ACT.restoreOntoTarget.replace('{original}', onto.originalSize.replace(/^Standard_/, ''))
    .replace(/\{size\}/g, onto.size.replace(/^Standard_/, '')).replace('{series}', onto.option) : '';
  openModal({ title: UX_ACT.restoreTitle.replace('{machine}', vmName(vmId)),
    desc: [UX_ACT.restoreDesc, ontoWords, ...restoreExceptions(doc), retire, ...restoreSiteRecoveryWords(doc)].filter(Boolean).join(' '),
    confirmLabel: UX_ACT.restoreBtn,
    fields: [
      ...(copyField ? [copyField] : []),
      { id: 'diskNaming', label: UX_ACT.restoreNaming, type: 'radio', options: [
        { value: 'new', label: UX_ACT.restoreNew },
        { value: 'preserve', label: UX_ACT.restoreKeep, help: UX_ACT.restoreKeepHelp, ...restoreKeepInstantNote(doc) }] },
      { id: 'accept', type: 'checks',
        options: [{ value: 'yes', label: `${UX_ACT.restoreRisk} ${deletes.join(', ')}` }],
        showWhen: { id: 'diskNaming', value: 'preserve' } },
      noteField()],
    doneMessage: UX_ACT.restoreDone,
    onConfirm: async (v) => {
      const preserve = v.diskNaming === 'preserve';
      if (preserve && !(v.accept ?? []).length) throw new Error(UX_ACT.restoreRiskMissing);
      await apiFetch(`runs/${runSeg()}/engine/restore`, {
        vmId, note: v.note, diskNaming: v.diskNaming,
        // Sent when there was a choice, or when the first copy is the only
        // one (it is the only copy the engine can read). The prepared copy
        // alone sends nothing: the engine default is that copy.
        ...(choice ? { diskSource: v.diskSource } : onlyFirst ? { diskSource: 'pristine' } : {}),
        ...(preserve ? { acceptPreserveRisk: true } : {}),
      });
    } });
}
/* REBUILD-ACCEPT-1: a restore swaps disks, and Site Recovery then stops replicating: measured, "One or more
 * disk(s) have been restored from backup". Said only for a machine whose
 * capture holds the Site Recovery mobility service extension - never to a
 * machine without it. PURE. */
function restoreSiteRecoveryWords(doc) {
  const has = (doc?.captured?.extensions ?? []).some(x => /siterecovery/i.test(String(x?.publisher ?? '')));
  return has ? [UX_ACT.restoreSiteRecovery] : [];
}
/* ROLLBACK-SIZE-REFUSED-SERIES-1: the newest history entry that stopped the
 * machine for a person - a stop state with a reason code. A retry adds an
 * entry after it. The engine asks the same rule (Get-VmfLastStopEntry). PURE. */
function lastStopEntry(doc) {
  const stops = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  return [...(doc?.history ?? [])].reverse().find(h => h && stops.includes(h.state) && h.reasonCode) ?? null;
}
/* The rollbackSizeRefused stop the machine waits at, with no restore since,
 * or null (Get-VmfSizeRefusedStop). PURE. */
function sizeRefusedStop(doc) {
  const stop = lastStopEntry(doc);
  if (!stop || stop.reasonCode !== 'rollbackSizeRefused') { return null; }
  const restored = Date.parse(doc?.restore?.restoredUtc ?? '');
  const stoppedAt = Date.parse(stop.tsUtc ?? '');
  if (!Number.isNaN(restored) && (Number.isNaN(stoppedAt) || restored > stoppedAt)) { return null; }
  return stop;
}
/* ROLLBACK-SIZE-REFUSED-SERIES-1: does Restore this machine from the copy
 * Before the migration go onto the target size of the plan - Azure refused
 * the original size, and a person selected Change to v5? null, or
 * { size, option, originalSize, refused }. The engine decides the same
 * (Get-VmfRestoreOntoTarget); both are held to
 * tests/fixtures/restore-onto-target.json. PURE. */
function restoreOntoTarget(doc, entry, from = 'pristine') {
  if (from !== 'pristine' || !entry || !doc || !sizeRefusedStop(doc)) { return null; }
  if (entry.path !== 'A' || entry.target?.controller === 'NVMe') { return null; }
  const first = doc.captured?.original?.vmConfig ?? {};
  const originalSize = String(first.size ?? '');
  const size = String(entry.target?.size ?? '');
  if (!size || size === originalSize) { return null; }
  const option = String(entry.target?.choice?.option || entry.policy?.targetGeneration || '');
  const startedMethod = doc.captured?.startedTarget ? doc.captured.startedTarget.target?.choice?.method : entry.target?.choice?.method;
  const refused = !!first.capacityReservationGroupId || startedMethod === 'preview' || entry.target?.choice?.method === 'preview';
  return { size, option, originalSize, refused };
}

/* SWAP-REFUSED-AFTER-STOP-1: Finish the rollback, or Finish the restore. The
 * dialog names each data disk the machine record says is left, and the engine
 * swaps only those, then starts the machine. openModal gives it Cancel and
 * Escape (hard rule 11). */
/* FINISH-EMPTY-LUN-WORDS-1: one row of the swap record in words - what is on
 * its LUN as the record says (lunHolds, vm-state v38), never a disk the LUN
 * does not have. MIGRATIONS-PAGE-OLD-READERS-1: every writer records it, so a
 * row without it is said as not read - the engine reads every LUN before it
 * changes one. FINISH-TEMP-DISK-LEFT-1:
 * a LUN that runs on its temporary disk says that disk is free after this. */
function finishDiskLine(s) {
  const fill = (text) => text.replace(/\{lun\}/g, String(s.lun)).replace(/\{name\}/g, String(s.name ?? '')).replace(/\{disk\}/g, String(s.diskName ?? ''));
  const parts = [];
  if (s.lunHolds === 'had') { parts.push(UX_ACT.finishDisk); }
  // OLD-STATE-READERS-FINISH-1: a row that names no copy proves nothing, and
  // Finish stops before it changes the machine.
  else if (s.lunHolds === 'none' && (!s.diskId || !s.snapshotId)) { parts.push(UX_ACT.finishDiskEmptyUnproven); }
  else if (s.lunHolds === 'none') { parts.push(UX_ACT.finishDiskEmpty); }
  else if (s.lunHolds === 'other') { parts.push(UX_ACT.finishDiskOther); }
  else { parts.push(UX_ACT.finishDiskNotRead, UX_ACT.finishDiskReadFirst); }
  if (s.oldTemporary) { parts.push(UX_ACT.finishDiskTemp); }
  return parts.map(fill).join(' ');
}
function askFinish(vmId, doc) {
  const sp = doc?.swapPending ?? {};
  const title = sp.kind === 'restore' ? UX_ACT.finishRestore : UX_ACT.finishRollback;
  const disks = (sp.swaps ?? []).map(finishDiskLine).join(' ');
  const what = (sp.swaps ?? []).some(s => s.lunHolds === 'none') ? UX_ACT.finishWhatAttach : UX_ACT.finishWhat;
  openModal({ title, desc: `${UX_ACT.finishDesc} ${disks} ${what}`, confirmLabel: title,
    fields: [noteField()],
    doneMessage: UX_ACT.finishDone,
    onConfirm: async (v) => {
      await apiFetch(`runs/${runSeg()}/engine/finish`, { vmId, note: v.note });
    } });
}

/* POWER-ONLY-CHANGED-1: Return to the power state - the engine operation
 * powerback, for a machine whose power state the product changed and did not
 * return. Offered in any state that no job works on (a machine left out has
 * no retry). openModal gives it Cancel and Escape (hard rule 11). */
function powerName(power) {
  return { 'PowerState/running': UX_ACT.powerRunning, 'PowerState/stopped': UX_ACT.powerStopped,
           'PowerState/deallocated': UX_ACT.powerDeallocated }[power] ?? '';
}
function askPowerBack(vmId, doc) {
  openModal({ title: UX_ACT.powerBackTitle, desc: UX_ACT.powerBackDesc.replace('{power}', powerName(powerOwed(doc))),
    confirmLabel: UX_ACT.powerBack,
    fields: [noteField()],
    doneMessage: UX_ACT.powerBackDone,
    onConfirm: async (v) => {
      await apiFetch(`runs/${runSeg()}/engine/powerback`, { vmId, note: v.note });
    } });
}

/* VOLUMES-RESTORE-MIGRATED-1: Check the volumes - the engine operation
 * checkvolumes, for a machine whose record owes a check of its volumes
 * (volumesCheckOwed). Restore this machine on a migrated machine can leave a
 * volume not mounted, and a migrated machine has no Try this machine again.
 * Offered to an operator in any state that no job works on, with no data disk
 * swap left - the engine refuses it then (Get-VmfVolumesCheckRefusal). The
 * line says what to do only where no stop card says it. PURE, so a test can
 * run it. openModal gives the dialog Cancel and Escape (hard rule 11). */
function volumesCheckOffer(doc, canOp, busy) {
  const reason = doc?.volumesCheckOwed?.reason;
  const started = volumesCheckStarted(doc);
  if ((!reason && !started) || VmfHelp.machineAtWork(doc.state)) { return { button: false, line: '' }; }
  const stopCard = ['NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'].includes(doc.state);
  const line = (stopCard || !reason) ? '' : (reason === 'volumesNotBack' ? UX_ACT.volumesCheckLineMissing : UX_ACT.volumesCheckLineUnknown);
  return { button: !!(canOp && !busy && !doc.swapPending), line };
}
/* VOLUMES-CHECK-JOB-STOP-1: the record of a start for the check of the volumes
 * that the return did not end (captured.volumesCheckPower, status started), or
 * null. PURE. */
function volumesCheckStarted(doc) {
  const rec = doc?.captured?.volumesCheckPower;
  return (rec && rec.status === 'started') ? rec : null;
}
/* VOLUMES-CHECK-JOB-STOP-1: the line that says the machine runs because a check
 * of the volumes started it and did not finish - only once the service found
 * that no job runs on it (stoppedUtc), so a check that runs now says nothing.
 * PURE. */
function volumesStartedLine(doc) {
  const rec = volumesCheckStarted(doc);
  if (!rec || !rec.stoppedUtc || VmfHelp.machineAtWork(doc.state)) { return ''; }
  return (rec.gaveUp ? UX_ACT.volumesStartedGaveUp : UX_ACT.volumesStartedStopped).replace('{power}', powerName(rec.power));
}
function askVolumesCheck(vmId) {
  openModal({ title: UX_ACT.volumesCheckTitle, desc: UX_ACT.volumesCheckDesc,
    confirmLabel: UX_ACT.volumesCheck,
    doneMessage: UX_ACT.volumesCheckDone,
    onConfirm: async () => {
      await apiFetch(`runs/${runSeg()}/engine/checkvolumes`, { vmId });
    } });
}

function askStartWave(wave) {
  // SCHED-1: starting later is the same decision as starting now, taken at a
  // different time - so it lives in the same dialog, not a separate feature.
  const local = new Date(Date.now() + 3600000);
  const asLocalInput = new Date(local.getTime() - local.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  // SCALE-UX-1: the estimate needs the wave's size; the plan says it.
  // MACHINES-AT-ONCE-RANGE-1: the number is the wave's own, read by the
  // engine's rule, and said here - the service reads it again at the start.
  const waveEntries = (planDoc?.entries ?? []).filter(e => e.wave === wave);
  const atOnce = VmfHelp.waveAtOnce(waveEntries);
  const atOnceLine = [UX_ACT.atOnceStart.replace('{choice}', VmfHelp.atOnceChoice(atOnce).label),
    VmfHelp.waveEstimate(waveEntries.length, atOnce, UX_ACT)].filter(Boolean).join(' ');
  openModal({ title: UX_ACT.startWave, desc: `${UX_ACT.forRun} ${currentRun}. ${UX_ACT.startWaveDesc} ${atOnceLine}`, fields: [
      { id: 'when', label: UX_ACT.whenLabel, type: 'radio', options: [
        { value: 'now', label: UX_ACT.whenNow },
        { value: 'later', label: UX_ACT.whenLater }] },
      { id: 'runAt', label: UX_ACT.whenAt, type: 'datetime-local', value: asLocalInput,
        showWhen: { id: 'when', value: 'later' } },
      { id: 'windowMinutes', label: `${UX_ACT.windowLabel} - ${UX_ACT.windowHint}`, type: 'number', value: '',
        showWhen: { id: 'when', value: 'later' } },

      noteField()],
    doneMessage: UX_ACT.doneWave,
    onConfirm: async (v) => {

      if (v.when === 'later') {
        const at = new Date(v.runAt);
        if (!(at > new Date())) throw new Error(UX_ACT.whenPast);
        await apiFetch(`runs/${runSeg()}/waves/${encodeURIComponent(wave)}/schedule`,
          { runAtUtc: at.toISOString(), note: v.note,
            ...(Number(v.windowMinutes) ? { windowMinutes: Number(v.windowMinutes) } : {}) });
        return UX_ACT.doneScheduled;
      }
      const started = await apiFetch(`runs/${runSeg()}/engine/wave`, { wave, note: v.note });
      // EVAL-H14: the POST only launches a container job, which can refuse
      // afterwards - the wizard learned to watch for that and this page, which
      // starts every wave after the first, did not.
      watchForRefusal(wave);
      // ENGINE-START-PART-1: Azure started only some of the wave's containers.
      // The wave runs, so the service says which, in its own words.
      return started?.partStart ? started.message : undefined;
    } });
}

function askCancelSchedule(wave) {
  openModal({ title: UX_ACT.cancelSchedule, desc: `${UX_ACT.forRun} ${currentRun}.`, fields: [noteField()],
    doneMessage: UX_ACT.cancelDone,
    onConfirm: v => apiFetch(`runs/${runSeg()}/waves/${encodeURIComponent(wave)}/schedule`,
      { cancel: true, note: v.note }) });
}

// The other pages link here with #help rather than duplicating the bundle
// builder, so the option is in the same place on every page - the dashboard
// options have to stay consistent across all of them.
function openHelpFromHash() {
  if (location.hash !== '#help') return;
  history.replaceState(null, '', location.pathname + location.search);
  try { VmfHelp.open(); } catch { }
}

// A machine mid-move is the only thing that makes a run un-closable. Waiting
// for a person is not "working" - a run once got stuck in that state.
// RUNPAGE-1: which waves the viewer has collapsed or expanded, and which have
// had their settled tail opened. Session-only and per run - a preference this
// small is not worth persisting, and a stale one would be worse than none.
const waveCollapsed = new Map();
const settledHidden = new Set();
const SETTLED_STATES = ['MIGRATED', 'SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'];
// EVAL-M15: this tested for 'QUEUED', which no engine writes - the first state
// is PLANNED. So a run that had only been planned reported itself as working,
// and the controls that key off this read the opposite of the truth.
const NOT_STARTED_STATE = 'PLANNED';
/* DELETE-UNSTARTED-WAVE-1: and whenever the service's own rule says running
 * (VmfHelp.runStage, the twin of Get-VmfRunStage), because the service
 * refuses Delete this migration then. Between two waves no machine works,
 * but the machines of the next wave have not settled: the page showed Delete,
 * the service refused it and named Stop this migration, which was not there. */
function runIsWorking() {
  return allVms.some(v => v.state && v.state !== NOT_STARTED_STATE && !SETTLED_STATES.includes(v.state))
    || VmfHelp.runStage(planDoc, allVms).stage === 'running';
}

function askStopRun() {
  openModal({ title: UX_ACT.stopRunTitle, desc: UX_ACT.stopRunDesc,
    fields: [noteField(true)],
    onConfirm: v => apiFetch(`runs/${runSeg()}/stop`, { note: v.note }) });
}

/* DELETE-CHANGED-FREED-1: is this machine left CHANGED, with nothing that
 * mended it since? A stopped machine: skipMachineState says 'changed'. A
 * machine left out (SKIPPED): the same question, asked of the record as the
 * machine stood when it was left out - the history before its SKIPPED lines,
 * and the state it had then - with a SKIPPED line that says where Stop this
 * migration left it (STOP-MIDMOVE-FREED-1) read as the stop. PURE; the
 * engine's Test-VmfMachineLeftChanged is held to the same
 * tests/fixtures/machine-left-changed.json. */
function machineLeftChanged(doc) {
  if (!doc) { return false; }
  if (doc.state !== 'SKIPPED') { return skipMachineState(doc) === 'changed'; }
  const history = (doc.history ?? []).filter(Boolean);
  let end = history.length;
  while (end > 0 && history[end - 1].state === 'SKIPPED') { end--; }
  let before = history.slice(0, end);
  let then = before.length ? before[before.length - 1].state : 'PLANNED';
  const said = history.slice(end).filter(h => h.machineState).pop();
  if (said) {
    before = [...before, { tsUtc: said.tsUtc, state: 'FAILED_NEEDS_ATTENTION', reasonCode: 'runStopped', machineState: said.machineState }];
    then = 'FAILED_NEEDS_ATTENTION';
  }
  return skipMachineState(Object.assign({}, doc, { state: then, history: before })) === 'changed';
}

function askDiscardRun() {
  /* DELETE-CHANGED-FREED-1: the dialog names each machine left changed, and
   * says its safety copies stay. */
  const changed = allVms.filter(machineLeftChanged).map(v => String(v.vmId ?? '').split('/').pop());
  const desc = changed.length
    ? `${UX_ACT.discardRunDesc} ${UX_ACT.discardChanged.replace('{names}', changed.join(', '))}`
    : UX_ACT.discardRunDesc;
  openModal({ title: UX_ACT.discardRunTitle, desc,
    fields: [
      { id: 'copies', label: UX_ACT.discardCopies, type: 'radio', options: [
        { value: 'keep', label: UX_ACT.discardKeepCopies },
        { value: 'delete', label: UX_ACT.discardDeleteCopies }] },
      noteField(true)],
    onConfirm: v => discardRun(currentRun, v) });
}

/* SLOW-DELETE-1: a delete walks the whole run in the store and can remove
 * safety copies in Azure. It is not in the same class as accepting a wave's
 * options, and 45 seconds - the ceiling for everything else here - was shorter
 * than a real delete took. Under Azure's own 230-second limit on a request. */
const DISCARD_TIMEOUT_MS = 150000;

async function discardRun(removing, v) {
  try {
    const answer = await apiFetch(`runs/${runSeg()}/discard`,
      { note: v.note, deleteSafetyCopies: v.copies === 'delete' }, { timeoutMs: DISCARD_TIMEOUT_MS });
    /* DISCARD-ENGINE-1: with safety copies to delete, the service starts the
     * engine and answers at once. The migration is still there - the engine
     * removes it only after every copy is gone - so it is not forgotten. */
    if (answer && answer.queued) { return UX_ACT.discardQueued; }
  } catch (e) {
    if (!e.timedOut) { throw e; }
    /* The page gave up waiting; the service may have finished. A tested
     * delete DID work and the page said to try again - a second press on a
     * destructive action. So look, and say what is true. */
    const listed = await source.listRuns().catch(() => null);
    if (listed === null || listed.includes(removing)) { throw new Error(UX_ACT.discardUnknown); }
  }
  forgetRun(removing);
  return UX_ACT.discardDone;
}

/* DISCARD-ENGINE-1: a delete of this migration and its safety copies that the
 * engine is doing now, read from the events - no new state.
 *
 * The service writes `discard` / `start` when it starts the engine. The engine
 * ends it by removing the whole migration (and this page with it), or with
 * `engine:discard` / `fail` and the reason. A `discard` / `fail` from the
 * service (the engine did not start) or from the engine's second check also
 * ends it. A copy that was not deleted writes `discardCopy`, which does NOT:
 * the engine goes on with the other copies.
 *
 * Shown while the job works, however long that is: the engine writes a line
 * for every Azure call, seconds apart. A job the platform stops gives no word
 * at all, so with no line for DISCARD_IDLE_MS - longer than any one step,
 * the container start included - the page offers the delete again; the
 * service refuses a second one while Azure still lists the first. */
const DISCARD_IDLE_MS = 900000;
function discardIndex(events, nowMs) {
  let open = null;
  let last = null;
  for (const e of (events ?? [])) {
    if (!e) { continue; }
    if (e.step === 'discard' && e.outcome === 'start') { open = e; last = e; continue; }
    if ((e.step === 'discard' || e.step === 'engine:discard') && (e.outcome === 'fail' || e.outcome === 'refused')) { open = null; continue; }
    if (open) { last = e; }
  }
  if (!open) { return null; }
  const lastMs = Date.parse(last.tsUtc ?? '');
  if (!Number.isFinite(lastMs) || (nowMs - lastMs) > DISCARD_IDLE_MS) { return null; }
  return { since: open.tsUtc };
}
let discardInFlight = null;

/* Restore this machine is offered only from copies that exist: the copy step
 * was reached, and no cleanup or delete of the migration recorded them gone
 * (review 2 item 4 - a delete that stopped part way records each machine
 * whose copies it removed). */
function restoreCopiesThere(doc, operator) {
  if (!operator || doc?.retention?.deletedUtc) { return false; }
  if (doc?.safety?.snapshotId) { return true; }
  // PREP-ROLLBACK-1: a stop before the second copy that left the machine
  // changed - a rollback that could not finish - is put back from the first
  // copy. A machine nothing changed is not offered a restore it does not need.
  const lastChange = [...(doc?.history ?? [])].reverse().find(h => h && h.machineState);
  return Boolean(doc?.safety?.pristineSnapshotId && lastChange?.machineState === 'changed');
}
/* RESTORE-MID-MOVE-1 (2026-10-19): and only after the move of
 * the machine ended. A machine whose move has not ended belongs to its wave,
 * also when the wave stopped: the service and the engine refuse a restore of
 * it, and Stop this migration is the way to get it back now. The rule is
 * VmfHelp.machineAtWork - the engine's list of final states. */
function restoreOffered(doc, operator) {
  return restoreCopiesThere(doc, operator) && !VmfHelp.machineAtWork(doc?.state);
}
/* RESTORE-MID-MOVE-1: copies to restore from, and a move that has not ended -
 * the panel says why Restore this machine is not there. */
function restoreWaitsForMove(doc, operator) {
  return restoreCopiesThere(doc, operator) && VmfHelp.machineAtWork(doc?.state);
}

/* PREP-ROLLBACK-1: the pill for one script run inside the machine. READING
 * only read the machine (VERIFY-FP-1). STARTED is on record before a script
 * that changes the machine runs: while the machine is at work it is running
 * now; otherwise it never answered, so it can have changed the machine. */
function guestRunPill(g, running) {
  if (g?.result === 'READING') { return `<span class="pill quiet" title="${esc(UX_MISC.guestReadingTip)}">${esc(UX_MISC.guestReading)}</span>`; }
  if (g?.result === 'STARTED' && running) { return `<span class="pill quiet" title="${esc(UX_MISC.guestRunningTip)}">${esc(UX_MISC.guestRunning)}</span>`; }
  if (g?.result === 'STARTED') { return `<span class="pill bad" title="${esc(UX_MISC.guestStartedTip)}">${esc(UX_MISC.guestStarted)}</span>`; }
  const ok = !['BLOCKED', 'FAIL'].includes(g?.result);
  return `<span class="pill ${ok ? 'good' : 'bad'}">${esc(ok ? 'OK' : 'Problem')}</span>`;
}

/* DELETE-STALE-1: a deleted run leaves the page completely.
 *
 * The run stayed selected in the page's memory - and in the address and in the
 * remembered last run - so the refreshes after the delete kept asking for it,
 * and the "nothing to show" card was drawn BESIDE the deleted run's buttons.
 * A fresh load was right; only this page's memory was wrong. */
function forgetRun(id) {
  pendingRuns.delete(id);
  try { if (localStorage.getItem('vmf-last-run') === id) { localStorage.removeItem('vmf-last-run'); } } catch { }
  const url = new URL(location.href);
  if (linkedRunId(url.search, [id]) === id) {
    url.searchParams.delete('run');
    url.searchParams.delete('project');
    history.replaceState(null, '', url);
  }
  if (currentRun === id) { currentRun = null; }
  clearReadingRun();
}

/* The readers this page hands the help menu, for the support bundle.
 * PAGE-LOAD-2: runDocs reads the run's documents in ONE call (store/docs with
 * the run as the prefix); the bundle answers from it and asks the readers
 * below only what it cannot say. ?demo has no service, so it has no runDocs. */
function helpAdapter() {
  return {
    getMsal: () => msalApp,
    getRunId: () => currentRun,
    readJson: (run, rel) => source.readJson(run, rel),
    listFolder: (run, folder) => source.listFolder(run, folder),
    readLines: (run, rel, held) => source.readLines(run, rel, null, held),
    runDocs: DEMO_MODE ? undefined
      : (run, read) => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${run}/`, depth: 2, read }),
  };
}

function renderActMenu() {
  const wrap = $('#act-wrap');
  // One consistent top nav on every page: Runs · Reports ·
  // Admin, current page highlighted. Admin is visible to everyone - the
  // access page explains itself to non-admins and the directory is the gate.
/* The support bundle lives in help.js, with the help menu that opens it.
 *
 * This page carried its OWN copy - askSupportBundle() and buildSupportBundle()
 * - from before the shared menu existed. Two implementations of one feature,
 * and the page wired BOTH to the same nav tab, so one click opened the shared
 * menu and the page's own download dialog behind it. Cancelling the menu left
 * the download box sitting there. That was reported twice.
 *
 * The shared version does everything this one did: builds the file in the
 * browser from reads the viewer already has, names it after the run and the
 * time, and revokes the object URL on a later turn. This page hands it the
 * readers through VmfHelp.install().
 */

  // DIAG-1: reachable from every page state, including a broken one - the
  // moment someone needs it is the moment something has gone wrong.
  const helpLink = $('#nav-help');
  if (helpLink) {
    // One implementation of help, shared by every page, so the option behaves
    // the same wherever somebody needs it - it used to send you to another
    // page. This page hands over its own way of reading the store.
    openHelpFromHash();
    // Guarded: a missing shared file must cost the help option, not the page.
    if (window.VmfHelp) VmfHelp.install(helpAdapter());
  }
  if (needInteractive) {   // signed in, but the action token needs a click
    wrap.style.display = 'inline-flex';
    $('#act-menu-btn').textContent = UX_ACT.enableBtn;
    $('#act-menu-btn').onclick = async () => {
      try { adoptApiToken(await getApiToken(true)); renderActMenu(); refresh(); }
      catch (e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }
    };
    return;
  }
  if (!canOperate()) { wrap.style.display = 'none'; return; }
  wrap.style.display = 'inline-flex';
  // WIZARD-1: setting up a migration is ONE guided flow, not a menu of the
  // engine's operations - nobody thinks "I will now perform an assessment".
  //
  // ENTRY-1: this was once the only page offering "assess an estate",
  // because it used to BE the front door. It is
  // still a reasonable place to start the next estate from, but it is no
  // longer the ONLY one: the Overview and the Assessments page offer the same
  // action under the same name.
  $('#act-menu-btn').textContent = UX_ACT.menuBtn;
  $('#act-panel').innerHTML = '';
  $('#act-menu-btn').onclick = () => { location.href = 'wizard.html'; };
}

// ---------- rendering ----------
function statePill(state, opts = {}) {
  // WAVE-ORDER-START-1: a machine a decision sent back, that waits for the
  // service's next check (awaitsServiceCheck). Nothing works on it, so it
  // does not say Checking, and nothing spins.
  if (opts.awaits) {
    // BRAKE-WAIT-WORDS-1: while the wave safety brake holds the migration
    // (braked), the service's check starts nothing - only Resume does.
    if (opts.braked) {
      return `<span class="pill warn" title="${esc(`${UX_MISC.waitsResumeTip} (${state})`)}">${esc(UX_MISC.waitsResume)}</span>`;
    }
    // RETRY-WAIT-SAYS-WHY-1: what the service said holds it, when it did.
    const held = opts.hold ? holdWords(opts.hold) : null;
    if (held) {
      return `<span class="pill quiet" title="${esc(`${held.tip} (${state})`)}">${esc(held.pill)}</span>`;
    }
    return `<span class="pill quiet" title="${esc(`${UX_MISC.waitsCheckTip} (${state})`)}">${esc(UX_MISC.waitsCheck)}</span>`;
  }
  const [label] = UX_STATE[state] ?? [state];
  const cls = state === 'MIGRATED' ? 'good'
    : ['FAILED_ROLLED_BACK','FAILED_NEEDS_ATTENTION'].includes(state) ? 'bad'
    : state === 'NEEDS_DECISION' ? 'warn'
    : ['PLANNED','SKIPPED'].includes(state) ? 'quiet' : '';
  const spin = (!TERMINAL_STATES.includes(state) && state !== 'PLANNED' && opts.active) ? '<span class="spin"></span>' : '';
  /* WAVE-ROW-WORDS-1: a machine row shows its activity in the pill and
   * nowhere else. When the step started is on hover; a step that runs long
   * carries the hourglass inside the pill, where the loose "4m ago" and
   * "33m" used to sit beside it. The pill keeps its own colour: a slow step
   * is a hint, not an error. */
  const when = opts.since ? ` - ${UX_MISC.startedAgo.replace('{ago}', ago(opts.since))}` : '';
  const title = `${UX_STATE[state]?.[1] ?? ''} (${state})${when}${opts.stuck ? ` - ${UX_MISC.stuckHint}` : ''}`;
  const mark = opts.stuck ? '<span aria-hidden="true">&#9203;</span>' : spin;
  return `<span class="pill ${cls}" title="${esc(title)}">${mark}${esc(label)}</span>`;
}

/* KPI-COUNT-1: how many machines this run covers.
 *
 * THE DEFECT, seen on a real install 2026-09-18: the tile read
 * "VIRTUAL MACHINES 0 / in this run" while the table underneath it listed one
 * machine, waiting for approval.
 *
 * Both numbers were correct about different things. The wave table is built
 * from the PLAN, and a machine with no state document renders as PLANNED. The
 * tile counted STATE DOCUMENTS, and the engine writes one only when it first
 * touches a machine. So before a run starts there are none, and the tile
 * answered a question nobody asked.
 *
 * A run covers what its plan covers. A state document with no plan entry counts
 * too - renderWaves already shows those, as 'unplanned' - so this is the union
 * by machine, never one side alone.
 *
 * Kept apart from renderKpis so it can be tested without a page.
 *
 * NOT-IN-WAVE-QUEUED-1: and not a machine the waves leave out - one in no
 * wave that never ran (VmfHelp.outsideRun, the rule waveGroups draws by).
 */
function machinesInRun(vms, plan) {
  const ids = new Set();
  const docIds = new Set((vms || []).filter(d => d && d.vmId).map(d => d.vmId));
  for (const entry of ((plan && plan.entries) || [])) {
    if (entry && entry.vmId && !VmfHelp.outsideRun(entry, docIds.has(entry.vmId) ? { vmId: entry.vmId } : null)) ids.add(entry.vmId);
  }
  for (const id of docIds) { ids.add(id); }
  return ids.size;
}

/* The plan is read here rather than passed in, and that is deliberate.
 *
 * Passing it added a wire nothing covered: mutation showed the call site could
 * drop the argument and the tile would quietly read 0 again, with every test
 * still passing. EVAL-M12 in this same file is the same lesson pointing the
 * same way - a value that travels from a call site gets out of step with the
 * one thing that sets it. planDoc is set immediately before this runs. */
/* PUTBACK-COUNT-1: ONE definition of "migrated right now", used by every count
 * on this page, so the tile and the wave cannot disagree about it.
 * COUNT-TRUTH-1: and it is the SAME one the Reports page and the service use -
 * help.js holds it, because two pages that each wrote their own is how the
 * Reports page came to count a put-back as migrated.
 * STATUS-WORDS-1: the counts read the status now (statusCounts), whose end
 * results are that same definition; a machine being restored is not counted
 * migrated. This one is left for the progress point (shownState). */
const isPutBack = (doc) => VmfHelp.machineOutcome(doc) === 'putBack';
/* LAB-UX-1: a machine a person restored keeps the state MIGRATED, so its row
 * said Migrated beside Restored, of a machine a person had restored. The
 * counts above already call it restored, not
 * migrated; the row and the panel say the same. Its state pill gives way to
 * the Restored pill, and the move's last progress point is not shown. */
function shownState(doc) {
  // FINISH-COUNT-1: nor a machine a restore left stopped - its pill says
  // Stopped: finish the restore, and it is not restored yet.
  return !isPutBack(doc) && doc?.swapPending?.kind !== 'restore';
}
/* FINISH-COUNT-1: does this machine wait for a person? A stopped state, or
 * what help.js's one definition calls attention - which includes a machine a
 * restore left stopped (swapPending), whose state is still MIGRATED. Every
 * place on this page that asks it asks this. */
function waitsOnPerson(doc) {
  // STATUS-WORDS-1: by the one rule - a stop that a restore ended waits for
  // nobody (FAILED_ROLLED_BACK is rolledBack, which still offers its choices).
  // RUN-SUMMARY-SWAP-1: help.js's rule, which the engine's count for the
  // overview and the migrations list also uses.
  return VmfHelp.outcomeWaitsOnPerson(VmfHelp.machineOutcome(doc));
}
function restoredPill() {
  return `<span class="pill warn" title="${esc(UX_ACT.wasRestoredTip)}">${esc(UX_ACT.wasRestored)}</span>`;
}
/* STATUS-WORDS-1: the status groups. Every status the rule gives is in one
 * of them, or is queued or unknown. */
const RUNNING_STATUS = [
  'step', 'rollingBack', 'restoring', 'finishing',
];
const WAITING_STATUS = [
  'decision', 'attention', 'finishRestore', 'finishRollback',
];
const ENDED_STATUS = [
  'migrated', 'restored', 'rolledBack', 'leftOut',
];
/* STATUS-WORDS-1: what this machine is now, by help.js's one rule, from its
 * state document AND its latest step: the lines of the run history this page
 * read, and a restore or a finish found running in them. */
function machineStatusOf(vmId, doc) {
  const key = VmfHelp.idKey(vmId ?? doc?.vmId);
  const events = key ? latestEvents.filter(e => e && VmfHelp.idKey(e.vmId) === key) : [];
  return VmfHelp.machineStatus(doc ?? null, {
    events,
    restoring: doc ? restoreInFlight(vmId ?? doc.vmId, doc) : null,
  });
}
/* STATUS-WORDS-1: the word of a status - in the pill, the last change column
 * and the timeline. PURE. */
function statusWord(st) {
  switch (st.key) {
    case 'step':           return UX_STATE[st.step]?.[0] ?? st.step;
    case 'rollingBack':    return UX_MISC.statusRollingBack;
    case 'restoring':      return UX_ACT.puttingBack;
    case 'finishing':      return st.finishes === 'rollback' ? UX_MISC.statusFinishingRollback : UX_MISC.statusFinishingRestore;
    case 'finishRestore':  return UX_ACT.finishPill;
    case 'finishRollback': return UX_MISC.statusFinishRollback;
    case 'restored':       return UX_ACT.wasRestored;
    case 'decision':       return UX_STATE.NEEDS_DECISION[0];
    case 'attention':      return UX_STATE.FAILED_NEEDS_ATTENTION[0];
    case 'migrated':       return UX_STATE.MIGRATED[0];
    case 'rolledBack':     return UX_STATE.FAILED_ROLLED_BACK[0];
    case 'leftOut':        return UX_STATE.SKIPPED[0];
    case 'queued':         return UX_STATE.PLANNED[0];
    default:               return st.state ?? '';
  }
}
/* STATUS-WORDS-1: the ONE pill of a status. A machine had two answers side by
 * side - "Migrated" and "Restoring". opts: active,
 * stuck, awaits (as statePill takes them) and doing, the step a restore or a
 * rollback runs now, for the hover. PURE. */
function statusPill(st, opts) {
  const o = opts || {};
  const since = st.since ? ` - ${UX_MISC.startedAgo.replace('{ago}', ago(st.since))}` : '';
  const busy = (word, tip) => `<span class="pill warn" title="${esc(`${o.doing ?? tip}${since}`)}"><span class="spin"></span>${esc(word)}</span>`;
  const still = (cls, word, tip) => `<span class="pill ${cls}" title="${esc(tip)}">${esc(word)}</span>`;
  switch (st.key) {
    case 'rollingBack':    return busy(UX_MISC.statusRollingBack, UX_MISC.statusRollingBackTip);
    case 'restoring':      return busy(UX_ACT.puttingBack, UX_ACT.puttingBackTip);
    case 'finishing':      return busy(statusWord(st), UX_MISC.statusFinishingTip);
    case 'finishRestore':  return still('bad', UX_ACT.finishPill, UX_ACT.finishPillTip);
    case 'finishRollback': return still('bad', UX_MISC.statusFinishRollback, UX_MISC.statusFinishRollbackTip);
    case 'restored':       return restoredPill();
    case 'step':           return statePill(st.step, { ...o, active: true });
    case 'queued':         return statePill('PLANNED', o);
    case 'decision':       return statePill('NEEDS_DECISION', o);
    case 'attention':      return statePill('FAILED_NEEDS_ATTENTION', o);
    case 'migrated':       return statePill('MIGRATED', o);
    case 'rolledBack':     return statePill('FAILED_ROLLED_BACK', o);
    case 'leftOut':        return statePill('SKIPPED', o);
    default:               return statePill(st.state ?? '', o);
  }
}
/* The one status pill for a machine, in its row and in its panel. */
function machinePill(doc, st, opts) {
  return statusPill(st ?? machineStatusOf(doc?.vmId, doc), opts);
}
/* STATUS-WORDS-1: the Last change column - the word of the status and the
 * time of its newest change. It said "Preparing 13m ago" while the activity
 * moved every minute, and "Migrated 26m ago" after a restore. PURE. */
function statusLastChange(st) {
  if (st.key === 'queued' || !st.at) { return '<span class="muted">not started</span>'; }
  return `${esc(statusWord(st))} <span class="muted">${ago(st.at)}</span>`;
}
/* STATUS-WORDS-1: the Progress column. The bar shows how far the move got
 * only while it runs, and green and full only for Migrated. A machine that
 * ended any other way shows one neutral mark - a restored machine had a full
 * green bar and a rolled-back one an empty bar, and both were back. PURE. */
function statusBar(st) {
  if (st.bar === 'done') { return '<div class="mini-meter done" title="100%"><i style="width:100%"></i></div>'; }
  if (st.bar === 'run') {
    const pct = Math.round(Math.max(0, STATE_SEQ.indexOf(st.step)) / (STATE_SEQ.length - 1) * 100);
    return `<div class="mini-meter " title="${pct}%"><i style="width:${pct}%"></i></div>`;
  }
  return `<span class="muted" title="${esc(statusWord(st))}">&ndash;</span>`;
}
/* STATUS-WORDS-1: the counts of the tiles and of a wave, each machine once by
 * its status. A machine being restored counted as Migrated, and a rolled-back
 * one as Waiting on people. PURE. */
function statusCounts(sts) {
  const n = (keys) => sts.filter(s => keys.includes(s.key)).length;
  return { migrated: n(['migrated']), restored: n(['restored']), rolledBack: n(['rolledBack']),
           moving: n(RUNNING_STATUS), waiting: n(WAITING_STATUS) };
}
function checkpointLine(doc) {
  if (!doc || !doc.pathCheckpoint || !CHECKPOINT_TEXT[doc.pathCheckpoint] || !shownState(doc)) { return ''; }
  return `<p class="muted" title="${esc(doc.pathCheckpoint)}">Last saved progress point: ${esc(CHECKPOINT_TEXT[doc.pathCheckpoint])}</p>`;
}

function renderKpis(vms, halted, stop) {
  // PUTBACK-COUNT-1: a machine put back keeps the state MIGRATED and gains
  // `restore`. Counting it here said "verified on new hardware" of a machine
  // sitting on its old size.
  // PUTBACK-TILE-1: and a put-back is a number of its own, not a clause of
  // grey text under another one. It is the product's safety action working,
  // so the tile appears whenever there is one - and not before, so a run
  // nobody put back is not handed a tile reading 0.
  // STATUS-WORDS-1: each machine once, by its status - a machine being
  // restored is in progress, not migrated, and a rolled-back one has its own
  // tile, not Waiting on people.
  const n = statusCounts(vms.map(v => machineStatusOf(v.vmId, v)));
  const migrated = n.migrated;
  const putBack = n.restored;
  const problems = n.waiting;
  const moving = n.moving;
  const rolledBack = n.rolledBack;
  /* STOP-STATE-SHOWN-1: the brake of a migration a person stopped. Stop writes
   * the pause, and the card read every pause as the brake after repeated
   * failures, in red, with Resume. Nothing failed, and Resume starts nothing:
   * every machine the stop closed out stays closed out. So it says Stopped,
   * and offers no Resume and no Pause new work. */
  const brake = stop
    ? { tone: 'b4', ic: '&#9632;', val: UX_MISC.brakeStopped, sub: UX_MISC.brakeStoppedSub, btn: null }
    : halted
      ? { tone: 'alert', ic: '&#9208;', val: 'Paused', sub: 'paused after repeated failures - an operator must resume', btn: UX_ACT.resume }
      : { tone: 'b4', ic: '&#9654;', val: 'Normal', sub: 'watching for repeated failures', btn: UX_ACT.pause };
  const k = $('#kpis');
  k.innerHTML = `
    <div class="kpi b1"><div class="ic">&#128187;</div><div class="label">Virtual machines</div><div class="val">${machinesInRun(vms, planDoc)}</div><div class="sub">in this run</div></div>
    <div class="kpi b5"><div class="ic">&#10003;</div><div class="label">Migrated</div><div class="val">${migrated}</div><div class="sub">verified on the new size</div></div>${putBack ? `
    <div class="kpi b6"><div class="ic">&#8630;</div><div class="label">${esc(UX_MISC.putBackTile)}</div><div class="val">${putBack}</div><div class="sub">${esc(UX_MISC.putBackTileSub)}</div></div>` : ''}${rolledBack ? `
    <div class="kpi b6"><div class="ic">&#8630;</div><div class="label">${esc(UX_MISC.rolledBackTile)}</div><div class="val">${rolledBack}</div><div class="sub">${esc(UX_MISC.rolledBackTileSub)}</div></div>` : ''}
    <div class="kpi b2"><div class="ic">&#8635;</div><div class="label">In progress</div><div class="val">${moving}</div><div class="sub">being worked on now</div></div>
    <div class="kpi ${problems ? 'alert' : 'b3'}"><div class="ic">&#9888;</div><div class="label">Waiting on people</div><div class="val">${problems}</div><div class="sub">decisions or attention needed</div></div>
    <div class="kpi ${brake.tone}"><div class="ic">${brake.ic}</div><div class="label">Wave safety brake</div><div class="val" style="font-size:19px">${esc(brake.val)}</div><div class="sub">${esc(brake.sub)}</div>${(canOperate() && brake.btn) ? `<div style="margin-top:9px"><button type="button" class="btn small ${halted ? '' : 'ghost'}" id="halt-btn">${esc(brake.btn)}</button>` +
      // PROJ-EMPTY-1: stopping the run and deleting it USED TO BE HERE, beside
      // the brake. They are not the brake - pausing a wave and removing the
      // whole record are different sizes of decision - and a delete on a
      // status tile is a delete nobody finds. A tester did not: the tester
      // could not empty a project because the one control that removes a migration was
      // on the tile that reports whether the brake is on. They are run
      // actions, and there is a row for run actions.
      `</div>` : ''}</div>`;
  $('#halt-btn')?.addEventListener('click', halted ? askResume : askHalt);
  renderRunActions();
}

/* ACK-GATE-1: accept the note from HERE.
 *
 * It was collected in the wizard and nowhere else, so a run that reached this
 * page without it could never be started and there was no way to fix that from
 * the app. The only way was a wizard URL built by reading source -
 * which is REACH-1 broken, the rule that every operator action is reachable
 * from the app.
 *
 * It is one question, so it must read the same in both places: the statement
 * and the acceptance are the wizard's own words.
 *
 * IAC-NOTE-LIST-1: the note is a lead, a list with one item for each change,
 * and a closing line, built with DOM nodes in the dialog's description. */
function ackNoteNodes() {
  const lead = document.createElement('p');
  lead.textContent = UX_ACT.ackLead;
  const list = document.createElement('ul');
  for (const change of UX_ACT.ackChanges) {
    const item = document.createElement('li');
    item.textContent = change;
    list.appendChild(item);
  }
  const after = document.createElement('p');
  after.textContent = UX_ACT.ackAfter;
  return [lead, list, after];
}

function askAcknowledge() {
  openModal({ title: UX_ACT.ackTitle, desc: '', fields: [
      { id: 'accept', type: 'checks',
        options: [{ value: 'yes', label: UX_ACT.ackAccept }] },
      noteField()],
    doneMessage: UX_ACT.ackDone,
    onConfirm: async (v) => {
      if (!(v.accept ?? []).length) { throw new Error(UX_ACT.ackMissing); }
      await apiFetch(`runs/${runSeg()}/acknowledge`, { topic: 'infrastructure-as-code', note: v.note });
    } });
  $('#m-desc').replaceChildren(...ackNoteNodes());
}

function renderRunActions() {
  const host = $('#run-actions');
  if (!host) return;
  if (!currentRun || !(canOperate() || canApprove())) { host.innerHTML = ''; return; }
  // ACK-GATE-1: offered only while it is missing, and only to somebody who
  // could act on it. A button for something already done is noise.
  const ackBtn = (canOperate() && !runAcknowledged())
    ? `<button type="button" class="btn small" id="ack-btn">${esc(UX_ACT.ackBtn)}</button>` : '';
  /* PROJ-EMPTY-1: RUN-LIFECYCLE-1's two buttons live here now.
   *
   * Gated on canOperate() of their own, because this row admits an approver
   * as well and the service refuses both to anybody else - a button that can
   * only be refused is worse than no button.
   *
   * Which one is offered still depends on where the run is: a run working on
   * machines cannot be deleted (that record is what knows how to put them
   * back), and a run that is not working has nothing to stop. */
  /* DISCARD-ENGINE-1: while the engine deletes this migration, the page says
   * so in place of the delete button - pressing it again would only be refused. */
  const lifeBtn = !canOperate() ? ''
    : discardInFlight
      ? `<span class="muted" id="discard-working">${esc(UX_ACT.discardWorking.replace('{ago}', ago(discardInFlight.since)))}</span>` +
        (runIsWorking() ? `<button type="button" class="btn small ghost" id="stop-run-btn">${esc(UX_ACT.stopRun)}</button>` : '')
    : runIsWorking()
      ? `<button type="button" class="btn small ghost" id="stop-run-btn">${esc(UX_ACT.stopRun)}</button>`
      : `<button type="button" class="btn small danger" id="discard-run-btn">${esc(UX_ACT.discardRun)}</button>`;
  // REPORT-AUTO-1: the report button left this row - the engine writes the
  // report by itself. An approver may have nothing here now, and an empty
  // row is not drawn.
  host.innerHTML = (ackBtn || lifeBtn)
    ? `<div style="margin:0 0 12px;display:flex;gap:8px;flex-wrap:wrap">${ackBtn}${lifeBtn}</div>` : '';
  $('#ack-btn')?.addEventListener('click', askAcknowledge);
  $('#stop-run-btn')?.addEventListener('click', askStopRun);
  $('#discard-run-btn')?.addEventListener('click', askDiscardRun);
}

/* ACK-GATE-1: the run-level acceptance, read from the store like everything
 * else on this page. null means "not read yet or not there", and both of those
 * block a start - the engine does the same, and a page that guessed would put
 * a button back in front of somebody it cannot work for. */
let runAck = null;
/* STOP-STATE-SHOWN-1: the record of Stop this migration (stopped.json,
 * schemas/run-stop.schema.json), or null when nobody stopped the run. */
let runStop = null;
const runAcknowledged = () => Boolean(runAck && runAck.acknowledgedBy);

let allVms = [], planDoc = null, approvals = new Map(), acceptances = new Map(), schedules = new Map(), statusFilter = 'all', searchTerm = '';
// During a put-back the row sat frozen on "Migrated". The state
// doc is not touched while a restore runs - the machine stays MIGRATED the
// whole time, and it is STOPPED for most of it - so the one thing the row could
// not tell you was that anything was happening at all. The events already say
// so, and they are already loaded, so keep them where the rows can read them.
let latestEvents = [];
// DECIDE-KEEP-1: did the engine refuse this wave because its settings changed
// after they were accepted? The engine logs that with the wave and a code. An
// acceptance made or amended AFTER the refusal answers it.
function acceptanceRefused(acc, events, wave) {
  if (!acc) return false;
  const since = Math.max(Date.parse(acc.acceptedUtc) || 0, ...(acc.amendments ?? []).map(a => Date.parse(a.utc) || 0));
  return (events ?? []).some(e => e && e.step === 'acceptance' && e.outcome === 'refused' && e.code === 'optionsChanged'
    && e.wave === wave && (Date.parse(e.tsUtc) || 0) > since);
}
// EVAL-M12: the halt state was a LOCAL of the refresh function, and the two
// interactive re-renders passed the literal false. So after the circuit
// breaker tripped, typing in the search box - precisely what an operator does
// when a run goes wrong - turned red "Paused" pills into "Waiting to start"
// and made a Start button appear, while the KPI tile beside it still read
// "Wave safety brake: Paused". Pressing it launched a job that granted no
// leases. It lives at module scope now, like the events and claims already do.
let latestHalted = false;
// COCK-4 follow-up: the capacity table keeps the aggregate planning maths per
// wave x size, which is the right place for it. What was missing is the
// PER-MACHINE answer: did THIS machine consume a reserved slot, or not. The
// claims already record it in associatedVmIds; they just were not kept where
// the machine's own panel could read them.
let latestClaims = [];
// WAVE-RUNNING-LEASE-1: the run's leases, by machine (VmfHelp.leasesByMachine),
// from the open run's one call. A held lease keeps a wave running, here as in
// the engine.
let latestLeases = new Map();
let lastAssessment = null;   // so the plan dialog can offer the fleet's real tag keys
// Real status filter, since status is what we track. A problems-first sort
// is not a filter.
function vmCategory(state, entry, doc, st) {
  // MANUAL-WHY-1: a machine the plan does not move is not waiting to start.
  if (state === NOT_STARTED_STATE && notMovedReasons(entry)) return 'done';
  // STATUS-WORDS-1: a restore, a finish or a rollback that runs
  // is work in progress, whatever state the machine keeps meanwhile.
  if (st && RUNNING_STATUS.includes(st.key)) return 'moving';
  if (waitsOnPerson(doc ?? { state })) return 'attention';
  // A stop that a restore ended is settled (VmfHelp.machineOutcome).
  if (['MIGRATED', 'SKIPPED'].includes(state) || VmfHelp.machineOutcome(doc ?? { state }) === 'putBack') return 'done';
  if (state === 'PLANNED') return 'waiting';
  return 'moving';
}
/* STATUS-WORDS-1: the pill of a wave, from the status of each machine.
 * A wave that ended with a machine rolled back said "Waiting on people": it
 * named no machine and no choice, and the next wave did not wait for it. It
 * says Finished and how many rolled back, and waveRolledBackLine names them.
 * FINISH-COUNT-1 still holds: a machine a restore left stopped is waiting.
 * PURE. */
function waveStatus(sts, halted, stop) {
  const n = statusCounts(sts);
  if (n.waiting) return ['Waiting on people', 'warn'];
  // STOP-STATE-SHOWN-1: a wave a person's stop ended (stopOfWave) is not
  // Complete: every machine it closed out reads as ended.
  if (stop === 'notStarted') return [UX_MISC.waveStoppedBeforeStart, 'quiet'];
  if (stop === 'closed') return [UX_MISC.waveStopped, 'quiet'];
  if (sts.every(s => ENDED_STATUS.includes(s.key))) {
    return n.rolledBack ? [UX_MISC.waveFinishedRolledBack.replace('{n}', String(n.rolledBack)), 'warn'] : ['Complete', 'good'];
  }
  if (halted) return ['Paused', 'bad'];
  if (sts.some(s => RUNNING_STATUS.includes(s.key) || s.key === 'unknown')) return ['In progress', ''];
  return ['Waiting to start', 'quiet'];
}
/* STOP-STATE-SHOWN-1: what the stop of the migration did to this wave, from
 * the record of the stop (stopped.json): 'notStarted' when no machine of the
 * wave had started, 'closed' when the stop closed out a machine of it, or
 * null - no stop, or a wave that ended before it. Machines are found by their
 * ID in any letter case. PURE. */
function stopOfWave(wave, entries, stop) {
  if (!stop) { return null; }
  if ((stop.wavesNotStarted ?? []).includes(wave)) { return 'notStarted'; }
  const closed = new Set((stop.machines ?? []).map(VmfHelp.idKey));
  return (entries ?? []).some(e => e && closed.has(VmfHelp.idKey(e.vmId))) ? 'closed' : null;
}
/* STOP-STATE-SHOWN-1: who stopped the migration, when, and the note. PURE. */
function stoppedLine(stop) {
  const said = UX_ACT.stoppedBy.replace('{who}', String(stop.stoppedBy ?? ''))
    .replace('{when}', new Date(stop.stoppedUtc).toLocaleString());
  const note = String(stop.note ?? '').trim();
  return note ? `${said} ${UX_ACT.stoppedNote.replace('{note}', note)}` : said;
}
/* STATUS-WORDS-1: the machines of a wave that rolled back, by name, and what
 * to do. '' when none did. rows: { name, st }. PURE. */
function waveRolledBackLine(rows) {
  const names = rows.filter(r => r.st.key === 'rolledBack').map(r => r.name);
  if (!names.length) { return ''; }
  return `<p class="muted" style="margin:0 18px 8px">${esc(UX_MISC.waveRolledBackNames.replace('{names}', names.join(', ')))}</p>`;
}

// The machines a scan found, BEFORE any plan exists - otherwise a scan
// produces nothing visible and the flow makes no sense.
// Once a plan exists the waves are the main view, so this collapses to a
// toggle rather than disappearing.
let foundOpen = false;
function renderFound(assessment, planned, plan) {
  const el = $('#found');
  if (!assessment) { el.innerHTML = ''; return; }
  const seriesOf = new Map((plan?.entries ?? []).map(e => [e.vmId, e.policy?.targetGeneration]));
  const entryOf = new Map((plan?.entries ?? []).map(e => [e.vmId, e]));
  // MACHINE-PICK-1: a plan holds only the machines a person chose, so a
  // machine the plan has no entry for is not in this migration - never "can
  // migrate". An eligible machine only: one that is not eligible keeps that word.
  const hasPlan = (plan?.entries ?? []).length > 0;
  const vms = (assessment.vms ?? []).map(v => {
    // ALREADY-CURRENT-1: Current first - planned or not, nothing moves it.
    if (foundCurrent(v)) return { ...v, classification: 'Current', blockers: [], prepNeeded: [], currentLine: UX_FOUND_T.currentLine.replace('{size}', String(v.sourceSize ?? '')) };
    if (hasPlan && !entryOf.has(v.vmId) && v.classification !== 'Excluded' && !v.platformManaged) {
      return { ...v, classification: 'NotChosen', blockers: [], prepNeeded: [] };
    }
    const series = seriesOf.get(v.vmId);
    const j = series ? judgeForSeries(v, series, entryOf.get(v.vmId)?.target?.diskArch) : judgeUnplanned(v);
    // V5-ADE-1: the plan does not move this machine, although the series
    // alone would. Its reason is the plan's own, in words.
    const e = entryOf.get(v.vmId);
    if (e && e.path === 'MANUAL' && String(j.classification).startsWith('Ready')) {
      return { ...v, classification: 'Blocked', blockers: [], prepNeeded: [], planNotes: e.planNotes ?? [] };
    }
    return { ...v, classification: j.classification, blockers: j.blockers, prepNeeded: j.prep };
  });
  const counts = vms.reduce((m, v) => { m[v.classification] = (m[v.classification] ?? 0) + 1; return m; }, {});
  const pillFor = (c) => c === 'Blocked' ? 'bad' : c === 'SomeTargets' ? 'warn' : c === 'Excluded' || c === 'NotChosen' || c === 'Current' ? 'quiet' : '';
  const summary = Object.entries(counts).map(([c, n]) =>
    `<span class="pill ${pillFor(c)}" title="${esc(UX_FOUND[c]?.[1] ?? '')}">${n} ${esc(UX_FOUND[c]?.[2] ?? c)}</span>`).join(' ');
  const show = planned ? foundOpen : true;
  const rows = vms.map(v => {
    const [word, why] = UX_FOUND[v.classification] ?? [v.classification, ''];
    const reasons = v.currentLine ? [v.currentLine] : [...[...(v.blockers ?? []), ...(v.prepNeeded ?? [])].map(reasonText), ...(v.planNotes ?? [])];
    return `<tr>
      <td class="mono">${esc(v.name)}</td>
      <td class="muted">${esc(v.resourceGroup)} &middot; ${esc(v.location)}</td>
      <td class="mono">${esc(v.sourceSize)}</td>
      <td><span class="pill ${pillFor(v.classification)}" title="${esc(why)}">${esc(word)}</span></td>
      <td class="muted">${reasons.length ? esc(reasons.join('; ')) : ''}</td></tr>`;
  }).join('');
  el.innerHTML = `<div class="card wrap-head">
      <div class="ch"><h2>${esc(UX_FOUND_T.title)} <span class="muted">${vms.length}</span> ${summary}</h2>
        <span class="wave-head-right"><span class="hint">${esc(UX_FOUND_T.hint)}</span>
        ${planned ? `<button type="button" class="btn small ghost" id="found-toggle">${esc(show ? UX_FOUND_T.hide : UX_FOUND_T.show)}</button>` : ''}</span></div>
      ${show ? `<table><thead><tr><th>${esc(UX_FOUND_T.colMachine)}</th><th>${esc(UX_FOUND_T.colWhere)}</th><th>${esc(UX_FOUND_T.colNowSize)}</th><th>${esc(UX_FOUND_T.colOutlook)}</th><th>${esc(UX_FOUND_T.colWhy)}</th></tr></thead>
        <tbody>${rows || `<tr><td colspan="5" class="muted">${esc(UX_FOUND_T.none)}</td></tr>`}</tbody></table>` : ''}
    </div>`;
  const t = $('#found-toggle');
  if (t) t.addEventListener('click', () => { foundOpen = !foundOpen; renderFound(assessment, planned, plan); });
}

// "What do I do next?" - derived from the run's real state, so the page never
// leaves someone staring at an empty screen.
// The wizard owns scanning and planning now, so this panel ROUTES there.
// askNewRun() and askBuildPlan() used to live here and had become unreachable -
// declared, never called, and still carrying their own dialogs. Deleted rather
// than left to look like features.
// EVAL-H14: the engine can refuse AFTER the start call returns 202 - five
// pre-flight gates on a wave, four on a restore - and it writes the reason into
// the run log (docker/entrypoint.ps1). The wizard watches for that; this page,
// which starts every wave after the first and every restore, did
// not, and printed "The wave is starting" regardless.
async function watchForRefusal(subject) {
  // WATCH-1: the loop is VmfHelp.watchRun; this says only what THIS page is
  // waiting for. A later failure supersedes an earlier one, so the last match
  // in the tick wins.
  const failure = await VmfHelp.watchRun({
    readLines: () => source.readLines(currentRun, 'logs/events.jsonl'),
    sinceMs: Date.now() - 5000,
    scan: (events) => events.reduce((found, e) =>
      (e.outcome === 'fail' && String(e.step ?? '').startsWith('engine')) ? e : found, null),
  });
  if (!failure) { return; }
  $('#ok').style.display = 'none';
  $('#err').textContent = UX_ACT.refused
    .replace('{what}', subject ?? '')
    .replace('{reason}', failure.detail ?? '');
  $('#err').style.display = 'block';
  refresh();
}

// FAILBRIEF-1: is the whole reason open? A person's choice, so it survives the
// fifteen-second refresh - a panel that closed itself under somebody reading it
// would be its own defect.
let failShown = false;

/* FAILSHOW-1: the most recent engine operation that ended in failure and has
 * not been retried since.
 *
 * THE DEFECT, on a live install 2026-09-18. Two operations failed - a wave that
 * could not start because the run was never acknowledged, and a put-back
 * refused by Azure for a missing permission - and in BOTH cases the banner
 * whose whole job is to say what happens next read:
 *
 *   "The plan is ready. Review the waves below, then approve and start the
 *    first one."
 *
 * It told the operator to do the thing that had just failed, and said nothing
 * about the failure. renderNextStep had branches for not-scanned, not-planned,
 * working and planned - and none for "the last thing you asked for did not
 * work", which is the one state where a person needs telling.
 *
 * THE REASON WAS ALREADY THERE. The engine writes it into the run's event log
 * and the activity feed renders it. It sat at the bottom of a long page while
 * the top of the page gave confident, wrong advice.
 *
 * Grouped by operation, and only the LATEST event of each counts: a wave that
 * failed and was then started successfully is not a failure any more, and a
 * page that kept saying so would be the same defect pointing the other way.
 */
function lastEngineFailure(events) {
  const latest = new Map();
  for (const e of (events ?? [])) {
    const step = String(e?.step ?? '');
    /* DISCARD-ENGINE-1: a new delete supersedes the last delete that failed,
     * so its old reason does not stand over the delete now running. */
    if (step === 'discard' && e.outcome === 'start') { latest.delete('engine:discard'); continue; }
    /* CLICKS-LOST-1: and the service's line for a new start of an operation
     * (Invoke-VmfFacadeStartEngine: step engine, with the operation) clears
     * that operation's failure before it. The old refusal stayed above "The
     * wave is starting" until the engine wrote its own first line. */
    if (step === 'engine' && ['start', 'warn'].includes(e.outcome) && e.operation) { latest.delete(`engine:${e.operation}`); continue; }
    if (!step.startsWith('engine:')) { continue; }
    latest.set(step, e);
  }
  // LOG-SAYS-WHY-1: a refusal is what the reader needs here as much as a
  // breakage - both answer "why did this not happen".
  const failed = [...latest.values()].filter(e => (e.outcome === 'fail' || e.outcome === 'refused') && e.detail);
  if (!failed.length) { return null; }
  return failed.reduce((worst, e) =>
    (Date.parse(e.tsUtc ?? 0) >= Date.parse(worst.tsUtc ?? 0) ? e : worst));
}

/** The operator's name for an engine operation, for the sentence above. */
function engineOperationName(step) {
  const op = String(step ?? '').replace(/^engine:/, '');
  return ({ wave: UX_ACT.nextFailedWave, restore: UX_ACT.nextFailedRestore,
            plan: UX_ACT.nextFailedPlan, assess: UX_ACT.nextFailedAssess,
            discard: UX_ACT.nextFailedDiscard })[op]
         ?? UX_ACT.nextFailedOther;
}

/* FAILBRIEF-1: the first sentence of a failure, and the rest.
 *
 * FAILSHOW-1 showed the engine's detail word for word. That is right when the
 * reason is a sentence - "This run has not been acknowledged: Migrating a
 * machine changes its size..." reads perfectly. It is wrong when the reason is
 * a raw Azure error.
 *
 * MEASURED on a live install, 2026-09-18: a refused put-back filled the top of
 * the page with about six hundred characters, carrying the SAME message twice
 * because Azure repeats it in a second field, plus two client ids, an operation
 * id, a status code and a reason phrase - unreadable, and it dominated the
 * page it was meant to inform.
 *
 * Nothing is dropped. The first sentence is what somebody reads at a glance,
 * and the rest is one button away - one button with two states, which is the
 * cheapest shape that always offers a way back.
 *
 * NO PARSING OF AZURE ERRORS. Splitting on the first sentence is a rule about
 * English, not about any service's error format. Anything cleverer would be a
 * guess that breaks the first time a message is shaped differently.
 */
function splitFailure(detail) {
  const whole = String(detail ?? '').trim();
  if (!whole) { return { first: '', rest: '' }; }
  /* A full stop FOLLOWED BY A SPACE, which is what makes this safe without
   * knowing anything about the text. A version number - "v1.2.3 of the engine"
   * - has no space after its stops, so it is not a sentence end and is not
   * treated as one. An earlier attempt guarded that with a minimum length
   * instead, and cut nothing at all from a short message. */
  const at = whole.indexOf('. ');
  if (at < 0 || at + 2 >= whole.length) { return { first: whole, rest: '' }; }
  return { first: whole.slice(0, at + 1), rest: whole.slice(at + 2).trim() };
}

/* WAVES-BUTTON-RUNNING-1: the wave editor button of "What happens next" - its
 * label, or null for no button. PURE, so a test can run it.
 *
 * The engine refuses a change to a RUNNING wave only (WAVE-EDIT-RUNNING-1):
 * the save asks Get-VmfWaveRunningDetail of each wave it touches. The editor
 * draws a running wave with no controls, and locks every machine that has
 * started - settled ones too (VmfHelp.machineStarted, the editor's started()).
 * So while a wave runs, the editor can still move a machine with no wave, or
 * a machine that has not started in a wave that is not running. The button
 * says which waves change when such a machine exists, and goes when none
 * does. No button when every wave has run (LAB-UX-1).
 * WAVE-RUNNING-PLANNED-1: storedStateOf gives the state document's state, or
 * nothing when there is none, as wavesInFlight needs. */
function nextWaveButton(entries, storedStateOf) {
  const waved = (entries || []).filter(e => e && e.wave && e.wave !== 'unscheduled');
  if (settledAll(waved, storedStateOf)) { return null; }
  const running = new Set([...new Set(waved.map(e => e.wave))]
    .filter(w => wavesInFlight(waved.filter(e => e.wave === w), storedStateOf)));
  if (!running.size) { return UX_ACT.arrangeWaves; }
  return (entries || []).some(e => e && !running.has(e.wave) && !VmfHelp.machineStarted(storedStateOf(e.vmId)))
    ? UX_ACT.arrangeNotRunning : null;
}

/* "What happens next", for a plan, in words. PURE, so a test can run it.
 * WAVE-ORDER-START-1: a wave whose only machines at work wait for the
 * service's next check does not "run now", and a wave the service has started
 * and the engine not yet begun is starting - not "ready to approve and
 * start".
 * WAVE-RUNNING-LEASE-1: when nothing works and a stopped worker's hold stays
 * on a finished machine, the engine still refuses an edit of its wave until
 * the service removes the hold - so that is said first. */
function nextStepSaid(o) {
  // STOP-STATE-SHOWN-1: a person stopped the migration. Nothing else here is
  // true: "every wave has run" was said of a wave the stop ended.
  if (o.stopped) { return UX_ACT.nextStopped; }
  if (o.endedHoldOnly) { return UX_ACT.nextEndedHold; }
  if (o.ran) { return UX_ACT.nextAllRan; }
  // BRAKE-WAIT-WORDS-1: a wait for the service, or a start on its way, while
  // the wave safety brake holds the migration waits for Resume instead.
  // RETRY-WAIT-SAYS-WHY-1: o.hold, what the service said holds the machines
  // that wait (waitingHold), says why in place of the 5 minutes.
  if (o.inFlight) {
    if (!o.onlyWaiting) { return UX_ACT.nextRunning; }
    if (o.halted) { return UX_ACT.nextWaitsResume; }
    return (o.hold ? holdWords(o.hold)?.next : null) ?? UX_ACT.nextWaitsCheck;
  }
  if (o.starting) { return o.halted ? UX_ACT.nextWaitsResume : UX_ACT.nextStarting; }
  // MIGRATIONS-WORDS-LAB-1: a signed-off first wave that waits for its
  // scheduled start (scheduledFirstWave) - nothing is left to approve.
  if (!o.begun && o.scheduled) {
    return UX_ACT.nextScheduled.replace('{wave}', o.scheduled.wave).replace('{time}', o.scheduled.time);
  }
  return o.begun ? UX_ACT.nextBetween : UX_ACT.nextPlanned;
}

/* MIGRATIONS-WORDS-LAB-1: the first wave of a plan nothing ran in, when it is
 * signed off and waits for its scheduled start - { wave, time } - or null.
 * PURE, so a test can run it.
 *
 * Final lab, 2026-11-13: the plan was signed off and the first wave had a
 * start time, and What happens next still said to approve and start it.
 * Each fact is the one the wave card reads, from the same documents:
 *  - the first wave is planRunOrder's first, which a person starts
 *    (planFollowText gives no follow line for it);
 *  - the schedule waits: a start on record is not waiting (waveScheduleHtml),
 *    and it has no window, whose fit only the service can judge;
 *  - signed off: its own approval, or a sign-off of the plan version on
 *    screen (the approval chip);
 *  - the start gates pass that the card's Start this wave asks, so after
 *    Cancel the scheduled start the card shows Start this wave: the run
 *    acknowledgement, the accepted settings (DECIDE-KEEP-1), and no wave
 *    safety brake. A start the engine refuses is not promised. */
function scheduledFirstWave(o) {
  if (o.halted || !o.acknowledged) { return null; }
  const wave = planRunOrder(o.plan)[0];
  if (!wave) { return null; }
  const sched = o.schedules && o.schedules.get(wave);
  if (!sched || !sched.runAtUtc || ['starting', 'started'].includes(sched.state)) { return null; }
  // A schedule with a window: the service's scheduled start holds a wave that
  // will not fit it (Test-VmfWaveWindow, asked when windowMinutes is set), and
  // the page cannot judge the fit, so no start is promised.
  if (sched.windowMinutes) { return null; }
  const acc = o.acceptances && o.acceptances.get(wave);
  if (!acc || acceptanceRefused(acc, o.events, wave)) { return null; }
  if (!(o.planCovers || (o.approvals && o.approvals.get(wave)))) { return null; }
  return { wave, time: scheduleTimeText(sched) };
}

function renderNextStep(events) {
  const el = $('#nextstep');
  /* FAILSHOW-1: a failure outranks every other thing this banner could say.
   * Nothing else here is true while the last action is still broken. */
  const failure = lastEngineFailure(events);
  if (failure) {
    // FAILBRIEF-1: the sentence first, the rest behind one button.
    const said = splitFailure(failure.detail);
    const more = said.rest
      ? `<button type="button" class="btn small ghost" id="fail-more">${esc(failShown ? UX_ACT.nextFailedHide : UX_ACT.nextFailedShow)}</button>`
      : '';
    const restBlock = (said.rest && failShown)
      ? `<div class="muted" style="flex-basis:100%;margin-top:10px;white-space:pre-wrap;word-break:break-word">${esc(said.rest)}</div>`
      : '';
    el.innerHTML = `<div class="card alert"><div class="cardbody" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
        <b style="font-size:13.5px">${esc(UX_ACT.nextFailedTitle)}</b>
        <span style="flex:1;min-width:240px">${esc(UX_ACT.nextFailed
            .replace('{what}', engineOperationName(failure.step))
            .replace('{reason}', said.first))}</span>${more}${restBlock}</div></div>`;
    $('#fail-more')?.addEventListener('click', () => { failShown = !failShown; renderNextStep(events); });
    return;
  }
  const recentEngine = [...events].reverse().find(e =>
    e.step === 'engine' && (Date.now() - Date.parse(e.tsUtc)) < 900000);
  const scanned = events.some(e => e.step === 'assessment' && e.outcome === 'ok');
  const planned = Boolean(planDoc && (planDoc.entries ?? []).length);
  let text, action = null;
  if (recentEngine && !planned) { text = UX_ACT.nextWorking; }
  else if (!scanned && !planned) { text = UX_ACT.nextNoRun; action = ['newrun', UX_ACT.newRun]; }
  else if (!planned) { text = UX_ACT.nextNoPlan; action = ['plan', UX_ACT.buildPlan]; }
  else {
    // A plan exists: the waves speak for themselves, but arranging them is
    // the step people reach for next.
    // LAB-UX-1: unless every wave has run. "Approve and start the first one"
    // was shown after the last wave had finished, with a button to arrange
    // waves that had all run.
    const waved = (planDoc.entries ?? []).filter(e => e && e.wave && e.wave !== 'unscheduled');
    // WAVE-RUNNING-PLANNED-1: the stored state tells a machine a worker took
    // at PLANNED from one that waits with no state document.
    const storedOf = (id) => allVms.find(v => v.vmId === id)?.state;
    const stateOf = (id) => storedOf(id) ?? NOT_STARTED_STATE;
    const ran = settledAll(waved, stateOf);
    // PANEL-OLD-STOP-1: "approve and start the first one" was shown while a
    // wave ran - a retried wave in the BGINFO-PERM-1 drill. A running wave is
    // said from the rule the wave card uses; between waves, the next wave is
    // the one to start. The first-wave line stays for a plan nothing ran in.
    const begun = waved.some(e => e.path === 'A' && !['PLANNED', 'SKIPPED'].includes(stateOf(e.vmId)));
    // WAVE-ORDER-START-1: the rules the wave cards use, so the banner and the
    // cards say one thing - and over the run history the cards read
    // (latestEvents, which the refresh sets to `events` just before this).
    const now = Date.now();
    const said = nextStepSaid({
      // STOP-STATE-SHOWN-1: the record of a person's stop.
      stopped: Boolean(runStop),
      // WAVE-RUNNING-LEASE-1: the engine's rule, over every wave.
      endedHoldOnly: VmfHelp.waveHold(waved, storedOf, leaseOf, now) === 'endedHold',
      ran,
      inFlight: wavesInFlight(waved, storedOf),
      onlyWaiting: waitingOnlyForCheck(waved, (id) => allVms.find(v => v.vmId === id), latestEvents),
      // RETRY-WAIT-SAYS-WHY-1: and what the service said holds them.
      hold: waitingHold(waved, (id) => allVms.find(v => v.vmId === id), latestEvents),
      starting: [...new Set(waved.map(e => e.wave))].some(w => waveStartRequested(w, latestEvents, now)),
      begun,
      // BRAKE-WAIT-WORDS-1: the value the Wave safety brake card shows.
      halted: latestHalted,
      // MIGRATIONS-WORDS-LAB-1: the documents the wave cards read.
      scheduled: scheduledFirstWave({ plan: planDoc, schedules, approvals, acceptances, planCovers: Boolean(planSignoff && planSignoffCurrent), acknowledged: runAcknowledged(), halted: latestHalted, events: latestEvents }),
    });
    /* STOP-STATE-SHOWN-1: a stopped migration says so at the top, to every
     * reader - who stopped it, when, the note - and what happens next. On the
     * lab install nothing on the page said that the migration was stopped. */
    if (runStop) {
      el.innerHTML = `<div class="card"><div class="cardbody" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
          <b style="font-size:13.5px">${esc(UX_ACT.stoppedTitle)}</b>
          <span style="flex:1;min-width:240px">${esc(stoppedLine(runStop))}</span></div>
        <div class="cardbody" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
          <b style="font-size:13.5px">${esc(UX_ACT.nextTitle)}</b>
          <span class="muted" style="flex:1;min-width:240px">${esc(said)}</span></div></div>`;
      return;
    }
    const label = nextWaveButton(planDoc.entries ?? [], storedOf);
    el.innerHTML = canOperate()
      ? `<div class="card"><div class="cardbody" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
          <b style="font-size:13.5px">${esc(UX_ACT.nextTitle)}</b>
          <span class="muted" style="flex:1;min-width:240px">${esc(said)}</span>
          ${label ? `<a class="btn small ghost" style="text-decoration:none" href="${VmfHelp.VmfRun.link('waves.html', currentRun)}">${esc(label)}</a>` : ''}</div></div>`
      : '';
    return;
  }
  const btn = (action && canOperate())
    ? `<a class="btn small" style="text-decoration:none" href="wizard.html${currentRun ? '?run=' + encodeURIComponent(currentRun) : ''}">${esc(action[1])}</a>`
    : (action ? `<span class="muted">${esc(UX_ACT.nextNoAccess)}</span>` : '');
  el.innerHTML = `<div class="card"><div class="cardbody" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">
      <b style="font-size:13.5px">${esc(UX_ACT.nextTitle)}</b>
      <span class="muted" style="flex:1;min-width:240px">${esc(text)}</span>${btn}</div></div>`;
  return;
}

/* A put-back in progress, read from the events - no new state, no schema change.
 * The step is 'restore' with outcome 'start'; anything else on that step ends it.
 *
 * RENDER-1: built ONCE per set of events, not once per row.
 *
 * This used to walk the whole event log for each machine, and twice for a
 * machine with a restore open. renderWaves calls it per row, and renderWaves
 * runs on every 15-second refresh, every keystroke in the search box, every
 * filter chip and every wave toggle - so the cost was machines x events, and
 * BOTH grow: the log has no cap, and every operator action appends to it.
 *
 * One pass over the events, in order, answering it for every machine at once.
 */
/* PUTBACK-GONE-1: only these END a put-back.
 *
 * "Any restore event that is not the start" used to end it. But Restore-VmfVm
 * writes PROGRESS under the same step - `info` when it leaves the reserved
 * capacity, and again when it reverts the size - so the first of those switched
 * "Putting back" off while the machine was still down and the work went on for
 * minutes, with nothing live on the page but the activity log. The engine
 * ends a put-back with ok, with warn (it failed and
 * the machine was restarted), or with fail. tests/js/putback-gone.test.js reads
 * the engine's own list of outcomes, so a new one cannot slip in unnoticed. */
const RESTORE_ENDS = ['ok', 'warn', 'fail'];

function restoreIndex(events) {
  const open = new Map();      // vmId -> the start event still standing
  const doing = new Map();     // vmId -> the newest azureops step under it
  const last = new Map();      // vmId -> the newest line of the machine since the start
  for (const e of (events ?? [])) {
    if (!e || !e.vmId) { continue; }
    /* RESTORE-END-LOST-1 review: the machine without case. The restore's lines
     * spell the id as the run's record does (Resolve-VmfRecordedVmId); the
     * engine's line spells it as the page sent it. */
    const vm = VmfHelp.idKey(e.vmId);
    if (open.has(vm)) { last.set(vm, e.tsUtc); }
    /* RESTORE-END-LOST-1: a failed restore writes no record, and its own fail
     * or warn line can be lost. Every failure throws, and the engine's catch
     * then writes this line, naming the machine - so it ends the restore too.
     * A refusal of the operation ends it the same way, as for a delete.
     * ONLY the restore whose start line carries the same operation id: a
     * second restore of the machine that fails before its start line must not
     * end the first, which still works on a stopped machine. */
    /* SWAP-REFUSED-AFTER-STOP-1: Finish the rollback or Finish the restore
     * holds the machine the way a restore does, under its own step. */
    if ((e.step === 'engine:restore' || e.step === 'engine:finish') && (e.outcome === 'fail' || e.outcome === 'refused')) {
      const now = open.get(vm);
      if (now && e.correlationId && now.correlationId === e.correlationId) { open.delete(vm); doing.delete(vm); }
      continue;
    }
    if (e.step === 'restore' || e.step === 'finish') {
      if (e.outcome === 'start') { open.set(vm, e); last.set(vm, e.tsUtc); }
      else if (RESTORE_ENDS.includes(e.outcome)) { open.delete(vm); doing.delete(vm); }
      continue;
    }
    // Only counts while a restore is open for that machine, and only for a
    // step that started at or after it - the same test the two passes made.
    const started = open.get(vm);
    if (started && /^azureops:(restore|rollback):/.test(e.step ?? '') &&
        Date.parse(e.tsUtc) >= Date.parse(started.tsUtc)) {
      doing.set(vm, e);
    }
  }
  const out = new Map();
  for (const [vmId, start] of open) {
    const d = doing.get(vmId);
    // STATUS-WORDS-1: kind - a restore, or Finish (VmfHelp.machineStatus).
    out.set(vmId, { since: start.tsUtc, doing: d ? stepText(d) : null, last: last.get(vmId) ?? start.tsUtc, kind: start.step });
  }
  return out;
}

let restoresInFlight = new Map();
/* STEP-LOG-2: the restore's last line can be lost when the run history
 * cannot be written. The machine's record of a finished restore, written
 * after the start, ends the put-back too, so it never shows for ever. */
function restoreRecordEnds(open, doc) {
  const done = doc?.restore?.restoredUtc;
  return Boolean(open && done && Date.parse(done) >= Date.parse(open.since));
}
function restoreInFlight(vmId, doc) {
  const open = restoresInFlight.get(VmfHelp.idKey(vmId)) ?? null;
  return restoreRecordEnds(open, doc) ? null : open;
}
/* STATUS-WORDS-1: the step a rollback runs now, in words, for the hover of
 * its pill - the newest rollback line of the machine since the rollback
 * began, or null. The status never showed that a rollback ran, nor its step. */
function rollbackDoing(vmId, since) {
  const key = VmfHelp.idKey(vmId);
  const from = Date.parse(since ?? '');
  let found = null;
  for (const e of latestEvents) {
    if (!e || VmfHelp.idKey(e.vmId) !== key || e.outcome === 'start') { continue; }
    if (!(e.step === 'rollback' || /^azureops:rollback:/.test(String(e.step ?? '')))) { continue; }
    const t = Date.parse(e.tsUtc ?? '');
    if (Number.isFinite(from) && !(t >= from)) { continue; }
    if (!found || t >= Date.parse(found.tsUtc)) { found = e; }
  }
  return found ? stepText(found) : null;
}

/* RESTORE-ONE-AT-A-TIME-1: Restore this machine is not offered while a
 * restore of the machine runs - the service and the engine refuse a second
 * one. The page shows what it read when it
 * loaded, so a refusal can still come back: the dialog shows its sentence.
 * busy says why both buttons are gone, on the screen.
 *
 * Review: a job killed hard (out of memory, a time limit, an eviction) writes
 * no end line. Without a limit both buttons were gone for ever, on a machine
 * that may be stopped. So a restore whose newest line is older
 * than PUTBACK_HOLD_MS no longer counts as running - the time after which the
 * engine takes the machine from a job that stopped (MachineLease.ps1, one
 * value: RestoreOneAtATime.Tests.ps1 holds the two equal). A live job that is
 * quiet for longer is refused by the service, with its sentence. */
const PUTBACK_HOLD_MS = 900000;
/* SWAP-REFUSED-AFTER-STOP-1: which finish a machine waits for - 'rollback',
 * 'restore', or null. Its record names each data disk a refused swap left. */
function finishOffered(doc) {
  const sp = doc?.swapPending;
  if (!sp) { return null; }
  return sp.kind === 'restore' ? 'restore' : 'rollback';
}
function putBackControls(doc, vmId, operate, nowMs = Date.now()) {
  // A time that cannot be read is not a running job: the buttons come back,
  // and the service still refuses a job that is alive (as discardIndex).
  const live = (o) => {
    if (!o) { return false; }
    const lastMs = Date.parse(o.last ?? o.since);
    return Number.isFinite(lastMs) && (nowMs - lastMs) <= PUTBACK_HOLD_MS;
  };
  const busy = live(restoreInFlight(vmId, doc));
  // SWAP-REFUSED-AFTER-STOP-1: a machine a refused swap left stopped offers
  // the one action that finishes it. The engine refuses a restore then.
  const finish = finishOffered(doc);
  return {
    busy,
    restore: !busy && !finish && restoreOffered(doc, operate),
    finish: (!busy && operate && finish) || null,
  };
}

// OSLOGO-1: a per-machine statement of the operating
// system, as TEXT. No logos - distro marks are trademarks with licensing
// implications, and "Ubuntu 22.04" tells an operator more than a swirl does.
//
// Everything here comes from the plan entry the assessment already wrote, so
// there is no new contract. osVersion is the IMAGE SKU, which is honest but
// unfriendly ('22_04-lts-gen2'), so the well-known ones get a readable name and
// everything else falls through to the raw sku - which is still true, just
// uglier. A machine whose image was never reported says so rather than being
// shown as a bare "Linux", which would imply we know more than we do.
const OS_SKU_NAMES = [
  [/^(\d{2})_(\d{2})[-_]lts/i,        (m) => `Ubuntu ${m[1]}.${m[2]} LTS`],
  [/^(\d{2})_(\d{2})/,                (m) => `Ubuntu ${m[1]}.${m[2]}`],
  [/^rhel[-_]?(\d+)[-_]?(\d+)?/i,     (m) => `Red Hat ${m[1]}${m[2] ? '.' + m[2] : ''}`],
  [/^(\d+)[-_]?sp(\d+)/i,             (m) => `SLES ${m[1]} SP${m[2]}`],
  [/^sles[-_]?(\d+)/i,                 (m) => `SLES ${m[1]}`],
  [/^centos[-_]?(\d+)/i,               (m) => `CentOS ${m[1]}`],
  [/^debian[-_]?(\d+)/i,               (m) => `Debian ${m[1]}`],
  [/^(\d{4})[-_]datacenter/i,          (m) => `Windows Server ${m[1]}`],
  [/^(\d{4})[-_]/i,                    (m) => `Windows Server ${m[1]}`],
];
function osText(entry) {
  const os = entry?.assessment?.os ?? '';
  const sku = String(entry?.assessment?.osVersion ?? '').trim();
  // SEC-REPORT-1: this path interpolated `os` RAW while the one below
  // escapes it. Not exploitable - `os` is osDisk.osType, which Azure fills
  // with Windows or Linux - but a field that is escaped on one branch and not
  // the other is a trap for whoever widens it next.
  if (!sku) return os ? `${esc(os)} <span class="muted">${esc(UX_MISC.osUnknownVersion)}</span>` : `<span class="muted">${esc(UX_MISC.osUnknown)}</span>`;
  for (const [re, fmt] of OS_SKU_NAMES) {
    const m = sku.match(re);
    if (m) return esc(fmt(m));
  }
  return `${esc(os)} <span class="mono muted">${esc(sku)}</span>`;
}

/* LAB-UX-1: have these machines all run? Only the machines the plan MOVES
 * (path A or B) count - a machine it does not move never gets a state, and
 * would keep a finished wave "not started" for ever. The states are the ones
 * the engine takes no further (Get-VmfNextWaveVm's terminal list). */
function settledAll(entries, stateOf) {
  const moving = (entries || []).filter(e => e && e.path === 'A');
  return moving.length > 0 && moving.every(e => SETTLED_STATES.includes(stateOf(e.vmId)));
}
/* WAVE-GATE-1, PANEL-OLD-STOP-1: is a machine of these entries at work now -
 * started, and not yet in a state the engine takes no further? The wave card
 * says "This wave is running now" from it, and "What happens next" says the
 * same. One rule, so the two cannot disagree. PURE.
 * WAVE-RUNNING-PLANNED-1: the rule is the engine's and the wave editor's,
 * VmfHelp.machineAtWork, so a machine a worker took at PLANNED counts.
 * storedStateOf gives the state DOCUMENT's state, or nothing when there is
 * none - never the PLANNED stand-in, which would make every waiting machine
 * read as taken.
 * WAVE-RUNNING-LEASE-1: and with the machine's lease (leaseFor), so a machine
 * a worker holds before it writes PLANNED counts, and so does a hold a stopped
 * worker left - the engine refuses an edit of the wave for both. */
function wavesInFlight(entries, storedStateOf, leaseFor = leaseOf) {
  const now = Date.now();
  return (entries || []).some(e => Boolean(e) && VmfHelp.machineAtWork(storedStateOf(e.vmId), leaseFor(e.vmId), now));
}
/* WAVE-RUNNING-LEASE-1: a machine's lease document as this page last read it,
 * or nothing. Found by the ID the lease names, in any letter case. */
function leaseOf(id) {
  return latestLeases.get(VmfHelp.idKey(id));
}
/* WAVE-RUNNING-LEASE-1: why a running wave cannot start, in words. PURE.
 * A wave held only by a stopped worker's hold on a finished machine waits for
 * the service to remove that hold (VmfHelp.waveHold, the engine's rule); one
 * whose only machines at work wait for the service's next check says that
 * (WAVE-ORDER-START-1); any other runs now. */
function waveRunningSaid(entries, storedStateOf, docOf, events, leaseFor = leaseOf) {
  if (VmfHelp.waveHold(entries, storedStateOf, leaseFor, Date.now()) === 'endedHold') { return UX_MISC.endedHold; }
  if (!waitingOnlyForCheck(entries, docOf, events, leaseFor)) { return UX_ACT.startAlreadyRunning; }
  // RETRY-WAIT-SAYS-WHY-1: what the service said holds the wave, when it did.
  return holdWords(waitingHold(entries, docOf, events, leaseFor))?.pill ?? UX_MISC.waitsCheck;
}
/* WAVE-RUNNING-PLANNED-1: a machine's state DOCUMENT's state, or nothing when
 * it has none. A machine waiting for a slot has none; a worker that takes a
 * machine writes PLANNED. Only this tells the two apart - vmStateOf below
 * gives PLANNED for both. */
function storedStateOf(id) {
  return allVms.find(v => v.vmId === id)?.state;
}
/* A machine's state as this page last read it; PLANNED when it has none. */
function vmStateOf(id) {
  return allVms.find(v => v.vmId === id)?.state ?? NOT_STARTED_STATE;
}
/* WAVE-APPROVE-1: does the signed-off plan start this wave on its own?
 * A sign-off of the plan version on screen covers every wave. A sign-off of
 * an EARLIER plan version is still the consent, but the timer starts a wave
 * only on its own approval that still stands - also a wave set to need no
 * approval, because a start nobody presses must rest on something an approver
 * signed (the engine: Test-VmfPlanRunConsent and Test-VmfPlanRunWaveSigned).
 * PURE, so a test can run it. */
function planStartsWave(signoff, signoffCurrent, approved) {
  if (!signoff) { return false; }
  if (signoffCurrent) { return true; }
  return Boolean(approved);
}
/* SCHED-1 and SCHEDULE-START-SHOWN-1: the wave card's schedule chip and its
 * cancel, from schedules/<wave>.json (schemas/wave-schedule.schema.json).
 * The service's schedule pass writes the start into the document ('starting',
 * then 'started') before it removes it, and the removal can wait for the next
 * pass. This showed every document as "Scheduled for" with a cancel, and the
 * service refuses a cancel while a start is on record (409,
 * Get-VmfScheduleStartRefusal). So the page asks the same state: a start on
 * record says the wave is starting, with no cancel. Any other document - a
 * pending one - waits for its time, and a cancel goes through. PURE: the schedule and the role in, HTML out. */
/* MIGRATIONS-WORDS-LAB-1: the start time of a schedule, as the wave card and
 * What happens next both show it. */
function scheduleTimeText(sched) {
  return new Date(sched.runAtUtc).toLocaleString();
}
function waveScheduleHtml(wave, sched, canOp, stopped) {
  // STOP-STATE-SHOWN-1: a stopped migration starts no wave. The stop removes
  // every schedule; one read before that is not shown.
  if (!sched || stopped) { return { chip: '', cancel: '' }; }
  const startMade = ['starting', 'started'].includes(sched.state);
  const when = `${esc(UX_ACT.scheduledFor)} ${esc(scheduleTimeText(sched))} &middot; ${esc(UX_ACT.scheduledBy)} ${esc(sched.scheduledBy ?? '')}`;
  const chip = startMade
    ? `<span class="pill quiet" title="${esc(sched.note ?? '')}">${esc(UX_ACT.scheduleStarting)} ${when}</span>`
    : `<span class="pill warn" title="${esc(sched.note ?? '')}">${when}</span>`;
  const cancel = (!startMade && canOp)
    ? `<button type="button" class="btn small ghost" data-cancelsched="${esc(wave)}">${esc(UX_ACT.cancelSchedule)}</button>` : '';
  return { chip, cancel };
}
/* The wave card's start control: a start time, a Start button, the reason it
 * cannot start, or nothing. Named so a test can run it.
 * LAB-UX-1: a wave whose every machine has run is finished, whatever the
 * outcome. waveDone counts only migrated and left-out machines, so a wave with
 * a machine rolled back was offered "Starts within five minutes" - and Start,
 * which could take no machine: the engine leases none of them.
 * PLANRUN-1: a wave that will start ON ITS OWN says so, instead of offering a
 * Start button that would race the plan's timer. The first wave, and every
 * wave of a plan nobody signed off, is still started by hand. */
function waveStartHtml(wave, entries, o) {
  const waveRan = settledAll(entries, vmStateOf);
  // WAVE-ORDER-START-1: a start the service took, and the engine has not yet
  // taken a machine of (waveStartRequested). The wave has no machine at work,
  // so it offered Start again - signed off or not - and right after Start the
  // plan the page read as if nothing had started.
  if (o.starting && !o.waveWorking && !o.waveDone && !waveRan && !o.halted) { return startsSoonHtml(wave); }
  const follows = (o.planCovers && !o.waveWorking && !o.waveDone && !waveRan && !o.sched)
    ? planFollowText(wave, planDoc, vmStateOf, planRunStatus, (id) => allVms.find(v => v.vmId === id)) : null;
  // BRAKE-WAIT-WORDS-1: the plan starts no wave while the wave safety brake
  // holds the migration (Get-VmfNextPlanWave: halted), so no time is promised.
  if (follows && o.halted) { return `<span class="muted" title="${esc(UX_MISC.waitsResumeTip)}">${esc(UX_MISC.waitsResume)}</span>`; }
  if (follows) { return follows === UX_MISC.startsSoon ? startsSoonHtml(wave) : `<span class="muted">${esc(follows)}</span>`; }
  const open = canOperate() && !o.waveDone && !waveRan && !o.halted && !o.sched && !isUnplannedWave(wave);
  if (open && !o.startBlockedBy) { return `<button type="button" class="btn small ghost" data-start="${esc(wave)}">${esc(UX_ACT.startWave)}</button>`; }
  if (open) { return `<span class="muted" title="${esc(o.startBlockedBy)}">${esc(o.startBlockedBy)}</span>`; }
  return '';
}
/* WAVE-ORDER-START-1: is a start of this wave on its way - the service
 * started the engine for it, and the engine has not yet begun the machines?
 * From the run history: the service's start line names the operation and the
 * wave (Invoke-VmfFacadeStartEngine). The start ends with the engine's own
 * end of the wave, or with a refusal or failure after the start. Ten minutes
 * is the limit: an engine container starts in one or two, so a start older
 * than that which took no machine is not said to be coming, and Start comes
 * back. PURE: events and the time in, a yes or no out. */
function waveStartRequested(wave, events, nowMs) {
  const START_REQUEST_MS = 600000;
  const list = events || [];
  let since = null;
  for (const e of list) {
    if (e && e.step === 'engine' && ['start', 'warn'].includes(e.outcome) && e.operation === 'wave' && e.wave === wave) {
      const t = Date.parse(e.tsUtc);
      if (t && (since === null || t > since)) { since = t; }
    }
  }
  if (since === null || nowMs - since > START_REQUEST_MS) { return false; }
  return !list.some(e => {
    const t = Date.parse(e && e.tsUtc);
    if (!t || t <= since) { return false; }
    if (e.step === 'wave' && e.wave === wave && ['ok', 'fail', 'refused'].includes(e.outcome)) { return true; }
    return ['fail', 'refused'].includes(e.outcome) && (/^engine/.test(String(e.step)) || ['wave', 'capacity'].includes(e.step));
  });
}
/* WAVE-ORDER-START-1: a machine that a person's decision sent back to Checking
 * (or Verifying), and that no engine has taken since. Resolve-VmfDecision
 * writes the state and its 'decision' line; nothing works on the machine until
 * the service's next check starts the engine for it - about 4 minutes on the
 * lab install, while the machine said Checking and the page "A wave is running
 * now". Any line of the machine after the decision (the worker's lease, the
 * service's resume) means something works on it. A machine with no decision
 * line is said as before. PURE. */
function awaitsServiceCheck(doc, events) {
  if (!doc || !['PRECHECK', 'VALIDATING'].includes(doc.state)) { return false; }
  const since = awaitsSince(doc);
  if (!since) { return false; }
  const key = VmfHelp.idKey(doc.vmId);
  const mine = (events || []).filter(e => e && e.vmId && VmfHelp.idKey(e.vmId) === key && (Date.parse(e.tsUtc) || 0) >= since);
  return mine.some(e => e.step === 'decision' && e.outcome === 'ok' && e.returnTo === doc.state)
    && mine.every(e => e.step === 'decision');
}
/* WAVE-ORDER-START-1: when the last step of the machine's history wrote its
 * state - the decision that sent it back - or NaN. PURE. */
function awaitsSince(doc) {
  const last = ((doc && doc.history) || []).slice(-1)[0];
  return last && last.state === doc.state ? Date.parse(last.tsUtc) : NaN;
}
/* RETRY-WAIT-SAYS-WHY-1: the service's line that says why it does not start
 * this wave again (step 'resume', code 'held', Write-VmfResumeHoldLine), or
 * null. Only a line written at or after `since` (the retry) counts, and a
 * later 'resumed' line of the wave - the service started it - ends it. The
 * line names no machine, so awaitsServiceCheck still reads the machine as
 * waiting. PURE. */
function serviceHoldLine(wave, since, events) {
  if (!wave || !since) { return null; }
  const key = String(wave).toLowerCase();
  let found = null;
  for (const e of events || []) {
    if (!e || e.step !== 'resume' || e.vmId || String(e.wave ?? '').toLowerCase() !== key) { continue; }
    if ((Date.parse(e.tsUtc) || 0) < since) { continue; }
    if (e.code === 'held') { found = e; } else if (e.code === 'resumed') { found = null; }
  }
  return found;
}
/* RETRY-WAIT-SAYS-WHY-1: why a machine that waits for the service's next
 * check waits - the line of its wave - or null when it does not wait, or the
 * service said nothing yet. PURE. */
function retryHoldOf(doc, wave, events) {
  return awaitsServiceCheck(doc, events) ? serviceHoldLine(wave, awaitsSince(doc), events) : null;
}
/* RETRY-WAIT-SAYS-WHY-1: the hold of the machines of these entries that wait
 * for the service, when the service said one for EVERY one of them - the
 * first - or null, and the page says the next check as before. PURE. */
function waitingHold(entries, docOf, events, leaseFor = leaseOf) {
  const waiting = (entries || []).filter(e => e && !leaseFor(e.vmId) && awaitsServiceCheck(docOf(e.vmId), events));
  if (!waiting.length) { return null; }
  const holds = waiting.map(e => retryHoldOf(docOf(e.vmId), e.wave, events));
  return holds.every(Boolean) ? holds[0] : null;
}
/* RETRY-WAIT-SAYS-WHY-1: the words of a hold line - the pill, its hover, and
 * the What happens next line - or null for a line the page does not know.
 * A wave worker of a wave the line does not name is "a running wave"; a gate
 * shows the gate's own words (data/start-gates.json) as the reason. PURE. */
function holdWords(hold) {
  if (!hold) { return null; }
  const fill = (s, wave, reason = '') => s.replace('{wave}', () => wave).replace('{reason}', () => reason);
  const by = hold.holdBy;
  const holder = String(hold.holdWave ?? '');
  if (by === 'wave' && holder) {
    return { pill: fill(UX_MISC.waitsWave, holder), tip: fill(UX_MISC.waitsWaveTip, holder), next: fill(UX_ACT.nextWaitsWave, holder) };
  }
  if (by === 'wave') { return { pill: UX_MISC.waitsAnyWave, tip: UX_MISC.waitsAnyWaveTip, next: UX_ACT.nextWaitsAnyWave }; }
  if (by === 'restore') { return { pill: UX_MISC.waitsRestore, tip: UX_MISC.waitsRestoreTip, next: UX_ACT.nextWaitsRestore }; }
  const reason = String(hold.reason ?? '');
  const wave = String(hold.wave ?? '');
  if (by === 'gate' && reason && wave) {
    return { pill: fill(UX_MISC.waitsGate, wave), tip: fill(UX_MISC.waitsGateTip, wave, reason), next: fill(UX_ACT.nextWaitsGate, wave, reason) };
  }
  return null;
}
/* WAVE-ORDER-START-1: is every machine of these entries that is at work only
 * waiting for the service's next check? Then the wave and "What happens next"
 * say that, not that it runs. docOf gives a machine's state document.
 * WAVE-RUNNING-LEASE-1: a machine with a lease is held by a job, so it does
 * not only wait - and a lease alone, with no state document, is at work. */
function waitingOnlyForCheck(entries, docOf, events, leaseFor = leaseOf) {
  const working = (entries || []).filter(e => e && VmfHelp.machineAtWork(docOf(e.vmId)?.state, leaseFor(e.vmId)));
  return working.length > 0 && working.every(e => !leaseFor(e.vmId) && awaitsServiceCheck(docOf(e.vmId), events));
}
/* STARTS-SOON-WORDS-1: the line of a wave the service starts, with the why
 * behind a (?): one button, two states (? and Close), and Escape closes it
 * (rule 11). The waves whose (?) is open stay open over the refresh. */
const soonHelpOpen = new Set();
function startsSoonHtml(wave) {
  const open = soonHelpOpen.has(wave);
  const id = `soon-help-${wave}`;
  return `<span class="muted">${esc(UX_MISC.startsSoon)}</span> <button type="button" class="btn small ghost" data-soonhelp="${esc(wave)}" aria-expanded="${open}" aria-controls="${esc(id)}" aria-label="${esc(open ? UX_ACT.close : UX_MISC.startsSoonHelpTip)}" title="${esc(UX_MISC.startsSoonHelpTip)}">${open ? esc(UX_ACT.close) : '?'}</button>${open
    ? `<span class="muted" id="${esc(id)}" style="display:block;font-weight:400;font-size:13px;margin-top:4px">${esc(UX_MISC.startsSoonHelp)}</span>` : ''}`;
}
/* PLANRUN-1: the order a signed-off plan runs its waves in. It is the engine's
 * Get-VmfPlanWaveOrder: the plan's own waveOrder (WAVE-ORDER-1), then any wave
 * it does not name in the order it first appears, and only waves with a
 * machine the engine moves (paths A and B).
 * WAVE-ORDER-START-1: this read the order the machines first appear in, while
 * the cards were drawn in the plan's order (VmfHelp.waveOrder). The machines
 * are sorted by name, so on the lab install the second wave of the editor was
 * "first" here: it had the Start button, and the first wave said "Starts when
 * new-wave-2 finishes". One rule now, VmfHelp.waveOrder, over the moved
 * machines only. */
function planRunOrder(plan) {
  const moved = ((plan && plan.entries) || []).filter(e => e && e.path === 'A' && e.wave && e.wave !== 'unscheduled');
  return VmfHelp.waveOrder({ entries: moved, waveOrder: (plan && plan.waveOrder) || [] });
}
/* What starts a wave of a signed-off plan that has not begun, in words - or
 * null when a person starts it (the first wave) or it is not in the order.
 * stateOf(vmId) gives a machine's state; status is the timer's plan-run.json;
 * docOf(vmId) gives its record, when the caller has it. */
function planFollowText(wave, plan, stateOf, status, docOf) {
  const order = planRunOrder(plan);
  const i = order.indexOf(wave);
  if (i < 0) { return null; }
  const entries = ((plan && plan.entries) || []).filter(e => e.path === 'A' && e.wave && e.wave !== 'unscheduled');
  // Nothing has begun: the first wave is started by a person, and every other
  // wave follows it.
  const begun = entries.some(e => !['PLANNED', 'SKIPPED'].includes(stateOf(e.vmId)));
  if (!begun && i === 0) { return null; }
  const prev = order[i - 1];
  const prevDone = !prev || entries.filter(e => e.wave === prev).every(e => SETTLED_STATES.includes(stateOf(e.vmId)));
  if (!prevDone) { return UX_MISC.startsAfter.replace('{wave}', prev); }
  // The run HOLDS on a machine that waits for a person - said from the machines,
  // not only from the timer's last pass, which can be five minutes old.
  // RESTORED-HOLD-1: a machine whose stop a restore ended keeps the state of
  // the stop and waits for nobody (VmfHelp.machineOutcome: putBack) - the
  // engine's timer asks the same rule (Get-VmfNextPlanWave -Settled).
  const putBack = (id) => !!docOf && VmfHelp.machineOutcome(docOf(id)) === 'putBack';
  if (entries.some(e => ['NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION'].includes(stateOf(e.vmId)) && !putBack(e.vmId))) { return UX_MISC.planHeld; }
  if (status && ['held', 'gate'].includes(status.reason) && status.detail) { return status.detail; }
  return UX_MISC.startsSoon;
}
/* The waves the page draws, in the order they run: [wave, { entries }] pairs.
 * PURE, so tests/js can run it. docs: the run's state documents.
 *
 * NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is left out
 * (VmfHelp.outsideRun). The wave editor's Remove puts a machine there, and
 * this page showed it under Not moved as Queued, In-place upgrade, not
 * started - but no wave takes it, so it is not part of the migration and is
 * not shown. The wave editor still lists it, where a person puts it in a
 * wave again. A machine with a
 * state document keeps its row, and MANUAL and EXCLUDED machines keep theirs
 * with their reasons. machinesInRun counts by the same rule. */
function waveGroups(plan, docs) {
  const entries = (plan && Array.isArray(plan.entries)) ? plan.entries.filter(Boolean) : [];
  const docOf = new Map((docs || []).filter(d => d && d.vmId).map(d => [d.vmId, d]));
  const byWave = new Map();
  for (const e of entries) {
    if (VmfHelp.outsideRun(e, docOf.get(e.vmId))) continue;
    if (!byWave.has(e.wave)) byWave.set(e.wave, { entries: [] });
    byWave.get(e.wave).entries.push(e);
  }
  for (const v of docOf.values()) {   // state docs with no plan entry (pre-plan seeding)
    if (!entries.some(e => e.vmId === v.vmId)) {
      if (!byWave.has('unplanned')) byWave.set('unplanned', { entries: [] });
      // WAVE-GATE-1: the machine goes IN. This made the bucket and never put
      // anything in it, so a run with a machine the plan does not mention drew
      // an empty "Not in a wave yet" card - a card about nothing, which reads
      // as the page having lost something. Found reading it, not reported.
      // A plan-shaped entry, because every reader below expects `vmId`.
      byWave.get('unplanned').entries.push({ vmId: v.vmId });
    }
  }
  // WAVE-ORDER-1: the order that runs, from the plan - not the names sorted.
  // Machines not in a wave come last.
  const rank = VmfHelp.waveOrder(plan);
  const place = (w) => (w === 'unplanned' ? 1e9 : (rank.indexOf(w) < 0 ? 1e8 : rank.indexOf(w)));
  return [...byWave.entries()].sort((a, b) => place(a[0]) - place(b[0]) ||
    String(a[0]).localeCompare(String(b[0]), undefined, { numeric: true }));
}
function renderWaves(halted) {
  /* WAIT-2: the search box and the status chips re-render the waves on a
   * keystroke. During the first read there is nothing to render, so a person
   * who types while the page is still loading would wipe the line telling them
   * it is loading and be left with the blank page again. */
  if (showingRun !== currentRun) { return; }
  const el = $('#waves');
  el.innerHTML = '';
  const waves = waveGroups(planDoc, allVms);

  waves.forEach(([wave, info], wi) => {
    let vms = info.entries.map(e => {
      const doc = allVms.find(v => v.vmId === e.vmId);
      // STATUS-WORDS-1: what the machine is now, once, for every reader below.
      return { entry: e, doc, name: vmName(e.vmId), state: doc?.state ?? 'PLANNED', st: machineStatusOf(e.vmId, doc) };
    });
    if (searchTerm) vms = vms.filter(v => v.name.toLowerCase().includes(searchTerm));
    if (statusFilter !== 'all') vms = vms.filter(v => vmCategory(v.state, v.entry, v.doc, v.st) === statusFilter);
    if ((searchTerm || statusFilter !== 'all') && !vms.length) return;   // hide waves with nothing to show
    const total = info.entries.length;
    // STATUS-WORDS-1: the wave counts and its pill read the status of every
    // machine of the wave, whatever the filter shows.
    const waveRows = info.entries.map(e => ({ name: vmName(e.vmId), st: machineStatusOf(e.vmId, allVms.find(v => v.vmId === e.vmId)) }));
    const sts = waveRows.map(r => r.st);
    const waveCounts = statusCounts(sts);
    const migrated = waveCounts.migrated;
    const putBackHere = waveCounts.restored;
    const [stLabel, stCls] = waveStatus(sts, halted, stopOfWave(wave, info.entries, runStop));

    /* AVSET-WAIT-1: which availability sets are busy IN THIS WAVE.
     *
     * The worker takes one lock per availability set - "one conversion per
     * AvSet at a time" (Orchestrator) - so a second machine in the same set
     * is passed over until the first is done. That is what stops both halves
     * of an availability set being down at once, and the page said nothing
     * about it: it showed one machine moving, a wave set to three at
     * once, and the rest on a bare "Queued".
     *
     * Per wave, because the lock is taken per wave run. A machine whose pair
     * is migrating in a DIFFERENT wave is not what holds this one up.
     *
     * VMID-CASE-1: in one letter case, as the worker names its lock - two
     * members can record one set in two cases.
     */
    const avsetOf = (e) => VmfHelp.idKey(e?.assessment?.availabilitySetId);
    const avsetBusy = new Set(info.entries
      .filter(e => {
        const s = allVms.find(v => v.vmId === e.vmId)?.state;
        return avsetOf(e) && s && s !== NOT_STARTED_STATE && !SETTLED_STATES.includes(s);
      })
      .map(avsetOf));

    // SIGNOFF-NULL-1: the gate's own rule. This read only `true`, so for a
    // machine that said nothing the gate's refusal named Approve and this page
    // showed no Approve button.
    const needsApproval = info.entries.some(VmfHelp.approvalRequired);
    const appr = approvals.get(wave);
    // WAVE-2: defaults exist, but every wave's options must be
    // reviewed and ACCEPTED by a person before it can run - and an edit
    // after acceptance voids it, so the chip goes back to amber.
    const acc = acceptances.get(wave);
    // DECIDE-KEEP-1: an acceptance the engine refused as out of date is not an
    // acceptance. This chip used to trust a file that exists, so a wave the
    // engine refused offered no way to accept it again.
    const accStale = acceptanceRefused(acc, latestEvents, wave);
    const accChip = isUnplannedWave(wave) ? '' : (acc && !accStale)
      ? `<span class="pill good" title="${esc(acc.note ?? '')}">${esc(UX_MISC.optionsAcceptedBy)} ${esc(acc.acceptedBy ?? '?')} &middot; ${esc(ago(acc.acceptedUtc))}</span>`
      : `<span class="pill warn">${esc(accStale ? UX_MISC.optionsChanged : UX_MISC.optionsNotAccepted)}</span>`;
    const acceptBtn = ((!acc || accStale) && canOperate() && !isUnplannedWave(wave))
      ? `<button type="button" class="btn small" data-accept="${esc(wave)}">${esc(UX_ACT.acceptOptions)}</button>` : '';
    // WAVE-GATE-1: and neither is a group nobody can run WAITING for an
    // approval. Same reason the acceptance chip is withheld from it: a chip
    // that names a missing step implies the step would help.
    // PLANRUN-1: one sign-off covers every wave of the plan it was given for.
    const planCovers = Boolean(planSignoff && planSignoffCurrent) && !isUnplannedWave(wave);
    const apprChip = (!needsApproval || isUnplannedWave(wave)) ? '' : (!appr && planCovers)
      ? `<span class="pill good">${esc(UX_MISC.planSignedBy.replace('{who}', planSignoff.approvedBy?.identity ?? '?'))}</span>`
      : appr
      ? `<span class="pill good" title="${esc(appr.note ?? '')}">${esc(UX_MISC.approvedBy)} ${esc(appr.approvedBy?.identity ?? '?')} &middot; ${esc(ago(appr.approvedUtc))}</span>`
      : `<span class="pill warn">${esc(UX_MISC.waitingApproval)}</span>`;
    // Role-gated wave actions (S3-5): approve when the gate is open for you;
    // start once the wave is approved (or needs no approval) and not finished.
    const waveDone = info.entries.every(e => ['MIGRATED', 'SKIPPED'].includes(allVms.find(v => v.vmId === e.vmId)?.state ?? 'PLANNED'));
    const approveBtn = (needsApproval && !appr && !planCovers && canApprove() && !isUnplannedWave(wave))
      ? `<button type="button" class="btn small" data-approve="${esc(wave)}">${esc(UX_ACT.approve)}</button>` : '';
    const sched = schedules.get(wave);
    const { chip: schedChip, cancel: cancelSchedBtn } = waveScheduleHtml(wave, sched, canOperate(), Boolean(runStop));
    // EVAL-H9: this checked approval but not ACCEPTANCE - two lines below the
    // code that renders the amber "Options not yet reviewed" chip. An operator
    // saw the warning and a blue Start button side by side, pressed Start, and
    // was told the wave was starting. Nothing started: the engine refuses an
    // unaccepted wave, and its refusal reached the container log. Gate on what
    // the engine gates on, and say why the button is not there.
    /* ACK-GATE-1: the run-level gate comes FIRST, because that is the order
     * the engine checks them in - Start-VmfWave tests the acknowledgement
     * before it looks at the wave at all. A page that named a later gate
     * would send somebody to fix the wrong thing.
     *
     * THE RULE ABOVE WAS ALREADY WRITTEN, for the wave-options gate, after an
     * operator pressed a Start button that could not work. It was never
     * pointed at this gate. On 2026-09-18 an operator pressed Start on a run
     * that had never been acknowledged - because it came from the drill, which
     * does not acknowledge - and got the same outcome the comment above
     * describes: a confident button, a refusal in a container log. */
    /* WAVE-GATE-1: AND THE ONE NOBODY POINTED IT AT - the wave is already
     * running. `waveDone` above only hides Start once every machine has
     * FINISHED, so a wave in flight fell between the two: an operator watched
     * wave-2 shutting three machines down with a live Start button beside it.
     * Pressing it starts a SECOND engine container. Machine leases are
     * exclusive so nothing is corrupted, but it picks up the machines not yet
     * started and runs more at once than the wave was set to.
     *
     * It is named FIRST although the engine checks it late, and that does not
     * break ACK-GATE-1's rule. The rule is that a page must not send somebody
     * to fix the wrong thing - and a wave cannot be running unless every gate
     * before it already passed, so none of them can be the thing to fix.
     * It is also not a gate to satisfy: it is a state to wait out. */
    const waveWorking = wavesInFlight(info.entries, storedStateOf);
    // WAVE-ORDER-START-1: a wave whose only machines at work wait for the
    // service's next check says that, not that it runs. WAVE-RUNNING-LEASE-1:
    // and one held only by a stopped worker says the service removes the hold.
    const startBlockedBy = waveWorking
      ? waveRunningSaid(info.entries, storedStateOf, (id) => allVms.find(v => v.vmId === id), latestEvents)
      : !runAcknowledged() ? UX_ACT.startNeedsAck
      : !acc ? UX_ACT.startNeedsAccept
      : (needsApproval && !appr && !planCovers) ? UX_ACT.startNeedsApproval : null;
    // PLANRUN-1 and LAB-UX-1: which start control the card shows - see waveStartHtml.
    // WAVE-APPROVE-1: the timer starts this wave only when the plan consents
    // AND the wave's own approval stands - a wave that changed after the
    // sign-off shows Approve and a reason, not "Starts when".
    const planStarts = planStartsWave(planSignoff, planSignoffCurrent, appr) && !isUnplannedWave(wave);
    // WAVE-ORDER-START-1: a start the service took, that the engine has not
    // yet begun.
    const starting = waveStartRequested(wave, latestEvents, Date.now());
    const startBtn = waveStartHtml(wave, info.entries, { planCovers: planStarts, waveWorking, waveDone, halted, sched, startBlockedBy, starting });
    // RUNPAGE-1: at a hundred machines this page was one very
    // long list. Nothing was wrong with it - there was just no way to put down
    // the parts nobody needed to read. Two things change that, and both are
    // DERIVED from what the page already computes rather than a new preference
    // to keep in sync:
    //
    //   - machines that need a person come FIRST, then those in flight, then
    //     the settled ones. "Needs attention" is already a computed fact
    //     (PROBLEM_STATES); it just was not driving the order.
    //   - the settled tail collapses behind a count, and a wave where NOTHING
    //     needs anyone collapses entirely.
    //
    // A filter or a search always wins: if somebody asked for specific
    // machines, showing them a collapsed list would be answering a different
    // question.
    const filtering = Boolean(searchTerm) || statusFilter !== 'all';
    // FINISH-COUNT-1: by the one rule, so a machine a restore left stopped
    // comes first, not with the settled ones.
    // STATUS-WORDS-1: by the status - a machine that a restore or a rollback
    // works on is in flight, and one that a restore ended is settled.
    const rank = (v) => (WAITING_STATUS.includes(v.st.key) || v.st.key === 'rolledBack') ? 0
      : (RUNNING_STATUS.includes(v.st.key) || v.st.key === 'unknown') ? 1 : 2;
    if (!filtering) vms = [...vms].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));

    const needsSomeone = vms.filter(v => rank(v) === 0).length;
    const inFlight = vms.filter(v => rank(v) === 1).length;
    const settledCount = vms.length - needsSomeone - inFlight;
    // WAVES-OPEN-1: a wave and its machines are the page's main content, so
    // nothing here hides on its own. A wave starts open and closes only when a
    // person clicks. (The page used to close a finished wave, and the finished
    // rows of a busy one, by itself - a person looked for a machine and it was
    // not there.)
    const waveKey = `${currentRun}::${wave}`;
    const collapsed = waveCollapsed.has(waveKey) ? waveCollapsed.get(waveKey) : false;
    // DEMO-POLISH-1: a hidden wave says nothing needs anyone only when that is
    // true of the WHOLE wave - never counted from a filtered list, and never
    // while a restore runs on one of its machines (its state stays MIGRATED).
    const quietWave = !filtering && needsSomeone === 0 && inFlight === 0
      && !vms.some(v => restoreInFlight(v.entry.vmId, v.doc));
    // The control to hide the settled tail is offered when the tail is long
    // and something else is worth reading. The tail hides only on a click.
    const offerSettledToggle = !filtering && !collapsed && settledCount > 8 && (needsSomeone + inFlight) > 0;
    const settledHiddenNow = offerSettledToggle && settledHidden.has(waveKey);
    const shownVms = settledHiddenNow
      ? vms.slice(0, needsSomeone + inFlight)
      : vms;

    const rows = (collapsed ? [] : shownVms).map(v => {
      const doc = v.doc;
      /* STATUS-WORDS-1: ONE status - the pill, the Last change column and the
       * Progress column all read it (VmfHelp.machineStatus). The pill said
       * the step that failed during a rollback, the step the state document
       * last named while the activity moved on, and "Migrated" beside
       * "Restoring". A
       * machine that a restore works on still has no size word: its size
       * column below greys it.
       * RESTORE-ROW-1, then WAVE-ROW-WORDS-1: the step it is on, and when it
       * started, are on the hover of the pill. */
      const st = v.st;
      const putting = st.key === 'restoring' || st.key === 'finishing' ? restoreInFlight(v.entry.vmId, doc) : null;
      const elapsed = (st.key === 'step' && st.since) ? (Date.now() - Date.parse(st.since)) / 1000 : 0;
      // WAVE-ORDER-START-1: sent back by a decision, and not yet taken. The
      // pill then says that, with no hourglass.
      const awaits = awaitsServiceCheck(doc, latestEvents);
      // RETRY-WAIT-SAYS-WHY-1: and why, when the service said it.
      const hold = awaits ? retryHoldOf(doc, v.entry.wave, latestEvents) : null;
      const stuck = elapsed > STUCK_SECONDS;
      const doing = putting?.doing ?? (st.key === 'rollingBack' ? rollbackDoing(v.entry.vmId, st.since) : null);
      /* AVSET-WAIT-1: this machine is not stalled - its pair is moving.
       *
       * Only on a machine that has not started: one already working is not
       * waiting for anything, and the set is busy BECAUSE of it. */
      const pairWaitTag = (v.state === NOT_STARTED_STATE && avsetBusy.has(avsetOf(v.entry)))
        ? ` <span class="pill quiet" title="${esc(UX_MISC.pairWaitTip)}">${esc(UX_MISC.pairWait)}</span>` : '';
      // The row said what would HAPPEN but never what the
      // machine is or what it becomes. The sizes are the first thing anyone
      // checks, and they were only reachable by opening the detail panel.
      // A row that announces a problem and offers no way to act
      // on it is a dead end. The decision and restore controls live in the
      // detail panel, and the only hint they existed was a chevron. Say what
      // clicking does, on the rows where something needs doing.
      const needsPerson = rank(v) === 0;
      // MANUAL-WHY-1: the plan does not move it - its state, not a queue.
      const notMoved = v.state === NOT_STARTED_STATE ? notMovedReasons(v.entry) : null;
      const goCell = needsPerson
        ? `<span class="rowact">${esc(UX_ACT.rowDecide)} &rsaquo;</span>`
        : '<span aria-hidden="true">&rsaquo;</span>';
      // This showed the PLAN - source arrow target - and called
      // it the size. After a put-back the machine is on the old size again and
      // the column still claimed it was moving to the new one. Show what the
      // machine IS, and keep the plan as context only while it still applies.
      const planFrom = v.entry.assessment?.sourceSize ?? '';
      const planTo = v.entry.target?.size ?? '';
      const arrived = ['MIGRATED', 'VALIDATING', 'STARTING'].includes(v.state);
      const putBack = doc?.restore?.sizeAfter ?? null;
      // Second time for this class: the pill said "Restored"
      // while the size column still read "D2s_v4 -> D2s_v6", because putBack
      // only ever recognised a MANUAL restore. An automatic rollback writes no
      // `restore` record, so the row fell through to rendering the PLAN - an
      // arrow promising a move that had already been undone.
      const rolledBack = v.state === 'FAILED_ROLLED_BACK';
      // A rollback always goes back to the size the machine had (RETIRE-SCOPE-1).
      const liveSize = putBack || (arrived ? planTo : planFrom);
      const sizeCell = !liveSize ? '<span class="muted">-</span>'
        // sizeAfter is only written when the put-back FINISHES, so
        // for the several minutes it runs this column kept asserting the machine
        // was on the new size. It is mid-change and we do not know yet - say so
        // rather than state the old answer with a straight face.
        : ['restoring', 'finishing', 'rollingBack'].includes(st.key)
          // WAVE-ROW-WORDS-1: greyed, and no word after it - the Restoring
          // pill says it is changing. STATUS-WORDS-1: and a rollback, which
          // changes it too.
          ? `<span class="mono muted">${esc(liveSize)}</span>`
        : putBack
          // RESTORE-ROW-1: it was restored - the size it is on, and nothing
          // else. The Restored pill says it came back; the panel has the size
          // it had reached.
          ? `<span class="mono">${esc(liveSize)}</span>`
        : rolledBack
          // Put back automatically. The live size is the truth and the pill
          // already says "Restored". No arrow - that would claim it is still
          // going there - and no "was on", which would claim it got there,
          // true only for some failures.
          ? `<span class="mono">${esc(liveSize)}</span>`
        : arrived
          // it arrived: one size, no arrow implying it is still moving
          ? `<span class="mono">${esc(liveSize)}</span>`
          // still to come: the plan, as a plan
          : `<span class="mono">${esc(liveSize)}</span>${planTo ? ` <span class="muted">&rarr;</span> <span class="mono">${esc(planTo)}</span>` : ''}`;
      return `<tr class="vm-row" data-vm="${esc(v.entry.vmId)}">
        <td><span class="mono">${esc(v.name)}</span><br><span class="osline">${osText(v.entry)}</span></td>
        <td>${notMoved ? notMovedPill(notMoved) : machinePill(doc, st, { since: st.key === 'step' ? st.since : null, stuck, awaits, hold, braked: halted, doing })}${pairWaitTag}</td>
        <td>${sizeCell}</td>
        <td>${notMoved ? '<span class="muted">-</span>' : esc(UX_PATH[v.entry.path] ?? '')}</td>
        <td>${notMoved ? '<span class="muted">-</span>' : statusBar(st)}</td>
        <td>${notMoved ? '<span class="muted">-</span>' : statusLastChange(st)}</td>
        <td class="rowgo">${goCell}</td></tr>`;
    }).join('');

    el.insertAdjacentHTML('beforeend', `
      ${wi > 0 ? `<div class="gate"><span class="bar"></span><span class="txt">${esc(planStarts ? UX_MISC.gateTextPlan : UX_MISC.gateText)}</span><span class="bar" style="flex:1"></span></div>` : ''}
      <div class="card wrap-head">
        <div class="ch">
          <h2>${esc(waveLabel(wave))} ${isUnplannedWave(wave) ? `<span class="muted" style="font-weight:400;font-size:13px">${esc(UX_MISC.notInAWaveWhy)}</span>`
            : `<span class="pill ${stCls}">${esc(stLabel)}</span>`} ${accChip} ${apprChip} ${schedChip} ${acceptBtn} ${approveBtn} ${startBtn} ${cancelSchedBtn}</h2>
          ${isUnplannedWave(wave) ? '' : `<span class="wave-head-right">
            <span class="wave-meter"><i style="width:${total ? Math.round(migrated / total * 100) : 0}%"></i></span>
            <span class="wave-count">${migrated} of ${total} migrated${putBackHere ? ' &middot; ' + esc(UX_MISC.putBackCount.replace('{n}', String(putBackHere))) : ''}</span>
          </span>`}
        </div>
        ${isUnplannedWave(wave) ? '' : waveRolledBackLine(waveRows)}
        ${collapsed
          ? `<p class="muted wave-collapsed">${vms.length} ${vms.length === 1 ? 'machine' : 'machines'}${quietWave ? ` &middot; ${esc(UX_MISC.waveAllSettled)}` : ''} <button type="button" class="btn small ghost" data-wavetoggle="${esc(waveKey)}">${esc(UX_MISC.expandWave)}</button></p>`
          : `<table><thead><tr><th>Virtual machine</th><th>Status</th><th title="The size the machine is on now. An arrow means it has not moved yet.">Size</th><th>Migration method</th><th>Progress</th><th>Last change</th><th title="Select a machine to see its full story">Details</th></tr></thead>
        <tbody>${rows || `<tr><td colspan="7" class="muted">No machines match.</td></tr>`}
        ${settledHiddenNow
          ? `<tr class="settled-row"><td colspan="7" class="muted">${settledCount} ${esc(UX_MISC.showSettled)} <button type="button" class="btn small ghost" data-settled="${esc(waveKey)}">${esc(UX_MISC.showThem)}</button></td></tr>`
          : (offerSettledToggle ? `<tr class="settled-row"><td colspan="7" class="muted"><button type="button" class="btn small ghost" data-settled="${esc(waveKey)}">${esc(UX_MISC.hideSettled)}</button></td></tr>` : '')}
        </tbody></table>
        ${!collapsed && vms.length > 5 ? `<p class="wave-hide"><button type="button" class="btn small ghost" data-wavetoggle="${esc(waveKey)}">${esc(UX_MISC.collapseWave)}</button></p>` : ''}`}
      </div>`);
  });
  // RUNPAGE-1 toggles. They re-render rather than mutating the DOM, so the
  // counts and the ordering stay consistent with what is actually there.
  el.querySelectorAll('[data-wavetoggle]').forEach(b => b.addEventListener('click', (e) => {
    e.stopPropagation();
    const k = b.dataset.wavetoggle;
    const current = waveCollapsed.has(k) ? waveCollapsed.get(k) : false;
    waveCollapsed.set(k, !current);
    renderWaves(halted);
  }));
  el.querySelectorAll('[data-settled]').forEach(b => b.addEventListener('click', (e) => {
    e.stopPropagation();
    const k = b.dataset.settled;
    if (settledHidden.has(k)) { settledHidden.delete(k); } else { settledHidden.add(k); }
    renderWaves(halted);
  }));
  el.querySelectorAll('tr.vm-row').forEach(r => r.addEventListener('click', () => {
    const doc = allVms.find(v => v.vmId === r.dataset.vm);
    const entry = planDoc?.entries.find(e => e.vmId === r.dataset.vm);
    openDrill(doc, entry, r.dataset.vm);
  }));
  el.querySelectorAll('[data-approve]').forEach(b => b.addEventListener('click', () => askApprove(b.dataset.approve)));
  el.querySelectorAll('[data-accept]').forEach(b => b.addEventListener('click', () => askAcceptOptions(b.dataset.accept)));
  el.querySelectorAll('[data-start]').forEach(b => b.addEventListener('click', () => askStartWave(b.dataset.start)));
  el.querySelectorAll('[data-soonhelp]').forEach(b => b.addEventListener('click', () => {
    const w = b.dataset.soonhelp;
    if (soonHelpOpen.has(w)) { soonHelpOpen.delete(w); } else { soonHelpOpen.add(w); }
    renderWaves(halted);
  }));
  el.querySelectorAll('[data-cancelsched]').forEach(b => b.addEventListener('click', () => askCancelSchedule(b.dataset.cancelsched)));
}

// EVAL-M9: this tested for ONE blockReason string and fell through to a green
// "Headroom verified" pill for everything else - so a BLOCKED claim
// whose reason was reservation-failed, sku-restricted or size-missing rendered
// as ready. Worse, the green branch is also where an UNREADABLE quota reading
// landed: limit == null meant the figures were simply omitted and the pill
// still said verified, which is the one thing it must never say about a
// reading that was not taken. Drive it off the STATE, and let unknown look
// unknown.
const BLOCK_TEXT = {
  'quota-shortfall':    () => UX_MISC.quotaShort,
  'regional-quota-shortfall': () => UX_MISC.quotaRegionalShort,
  'sku-restricted':     () => UX_MISC.quotaRestricted,
  'size-missing':       () => UX_MISC.quotaSizeMissing,
  'reservation-failed': () => UX_MISC.quotaReservationFailed,
};
function quotaFacet(c) {
  if (VmfHelp.claimBlocked(c.state)) {
    const text = (BLOCK_TEXT[c.blockReason] ?? (() => UX_MISC.quotaBlocked))();
    return `<span class="pill bad">${esc(text)}</span>`;
  }
  if (c.state === 'QUOTA_REQUESTED') return `<span class="pill warn">${esc(UX_MISC.quotaReq)}</span>`;
  // This looked live and is not. used/limit is read ONCE, when
  // the wave was planned, so it sat unchanged while the migration consumed
  // cores. Say when it was taken rather than implying it is current.
  const when = c.quota?.checkedUtc ? ` <span class="muted">${esc(UX_MISC.quotaWhen)} ${ago(c.quota.checkedUtc)}</span>` : '';
  if (c.quota?.limit == null) {
    // The documented s-suffix v6 listing bug: Azure did not report this
    // family, so there is no headroom figure. Saying "verified" here would be
    // claiming a check that never happened.
    return `<span class="pill warn" title="${esc(UX_MISC.quotaUnknownHint)}">${esc(UX_MISC.quotaUnknown)}</span>${when}`;
  }
  const q = ` <span class="muted mono">${esc(c.quota.used)}/${esc(c.quota.limit)}</span>`;
  return `<span class="pill good">${esc(UX_MISC.quotaOk)}</span>${q}${when}`;
}
/* WAVE-WORDS-4: the capacity setting of each wave, from the plan. A wave is
 * set to reserve when any machine of it says Reserved (as
 * claimUsesReservation reads it), and to None when its machines say
 * BestEffort or nothing, which the planner and the editor read as BestEffort.
 * A wave with no machine in the plan gives null: its setting is not known, and
 * the card never shows a guess as a value. */
function capacityGateOf(plan) {
  const gates = new Map();
  for (const e of plan?.entries ?? []) {
    if (gates.get(e.wave) === 'Reserved') { continue; }
    gates.set(e.wave, e.policy?.capacityGate === 'Reserved' ? 'Reserved' : 'BestEffort');
  }
  return (wave) => gates.get(wave) ?? null;
}
/* ODCR-STATUS-1: may this person release the capacity reservation of this
 * wave from the Quota and on-demand capacity reservations card now? An operator, while
 * no machine of the wave is at work - the rule the wave editor hides its
 * Release by (VmfHelp.waveHold), and the engine's release operation refuses
 * then (Get-VmfWaveReleaseRefusal). */
function reservationReleasable(wave, plan) {
  if (!canOperate()) { return false; }
  const ofWave = (plan?.entries ?? []).filter(e => e && e.wave === wave);
  const storedOf = (id) => allVms.find(v => v.vmId === id)?.state;
  return VmfHelp.waveHold(ofWave, storedOf, leaseOf, Date.now()) === 'none';
}
/* ODCR-STATUS-1: Release beside a capacity reservation nobody confirmed. The
 * page's own dialog (Cancel and Escape close it, rule 11), a note the engine
 * requires, and the engine's release operation for the wave - the one the
 * wave editor starts. The card shows the claim as the engine leaves it. */
function askReleaseReservation(wave) {
  openModal({ title: UX_ACT.releaseTitle,
    desc: UX_ACT.releaseDesc.replace('{wave}', () => wave),
    confirmLabel: UX_MISC.releaseBtn,
    fields: [noteField()],
    onConfirm: async (v) => {
      await apiFetch(`runs/${runSeg()}/engine/release`, { wave, note: v.note });
      return UX_ACT.releaseStarted.replace('{wave}', () => wave);
    } });
}
/* RES-LIST-1: the Capacity reservations list of the card, one row for each
 * wave and size. The state is the pill; the fact beside it is one short
 * sentence or nothing. The card does not name machines of an availability
 * set. */
function reservationFacet(c, gate) {
  const total = c.demand?.instances ?? 0;
  const reservable = c.demand?.reservableInstances ?? total;
  // CRG-MOVE-DEMAND-1: the machines that stay in their own capacity
  // reservation group (capacity-claim v15).
  const own = Array.isArray(c.demand?.ownGroupVmIds) ? c.demand.ownGroupVmIds.filter(x => typeof x === 'string' && x) : [];
  if (c.state === 'RELEASED') {
    return `<span class="pill quiet">${esc(UX_MISC.released)}</span>`;
  }
  if (VmfHelp.claimReservingStuck(c)) {
    return `<span class="pill bad" title="${esc(UX_MISC.unconfirmedHint)}">${esc(UX_MISC.unconfirmed)}</span>`;
  }
  if (c.state === 'RESERVING') {
    return `<span class="pill warn" title="${esc(UX_MISC.reservingHint)}">${esc(UX_MISC.reserving)}</span>`;
  }
  if (c.state === 'RESERVED' || c.state === 'CONSUMED') {
    // Green only once something uses it: a reservation with nothing on it is
    // paid for.
    const idle = (c.reservation?.consumedInstances ?? 0) === 0;
    return `<span class="pill ${idle ? 'warn' : 'good'}" title="${esc(idle ? UX_MISC.reservedIdleHint : UX_MISC.reservedInUseHint)}">${esc(UX_MISC.reserved)} ${reservable}</span>`;
  }
  // Azure refused the reservation of this wave and size: a reservation fact,
  // so it is said here and not in the Quota list.
  if (VmfHelp.claimBlocked(c.state) && c.blockReason === 'reservation-failed') {
    return `<span class="pill bad">${esc(UX_MISC.quotaReservationFailed)}</span>`;
  }
  // WAVE-WORDS-4: no reservation in Azure. Say what the wave is set to.
  if (gate === 'BestEffort') {
    return `<span class="pill quiet" title="${esc(UX_MISC.bestEffortHint)}">${esc(UX_MISC.bestEffortPill)}</span>`;
  }
  if (gate === 'Reserved') {
    const hint = VmfHelp.claimBlocked(c.state) ? UX_MISC.notReservedBlockedHint : UX_MISC.notReservedHint;
    if (reservable > 0) { return `<span class="pill warn" title="${esc(hint)}">${esc(UX_MISC.notReserved)}</span>`; }
    return own.length > 0
      ? `<span class="pill quiet" title="${esc(UX_MISC.ownGroupHint)}">${esc(UX_MISC.notReserved)}</span>`
      : `<span class="pill quiet">${esc(UX_MISC.notReserved)}</span>`;
  }
  return `<span class="muted" title="${esc(UX_MISC.capacityGateUnknown)}">-</span>`;
}
/* RES-LIST-1: the one short fact of a reservation row, or ''. */
function reservationFact(c) {
  if (c.state === 'RELEASED') {
    const used = Number(c.reservation?.consumedInstances ?? 0);
    return used > 0 ? UX_MISC.servedNote.replace('{n}', String(used)) : '';
  }
  if (VmfHelp.claimReservingStuck(c)) { return UX_MISC.unconfirmedNote; }
  if (c.state === 'RESERVED' || c.state === 'CONSUMED') {
    const reservable = c.demand?.reservableInstances ?? c.demand?.instances ?? 0;
    const used = Number(c.reservation?.consumedInstances ?? 0);
    return UX_MISC.reservedCounts.replace('{used}', String(used)).replace('{idle}', String(Math.max(0, reservable - used)));
  }
  const own = Array.isArray(c.demand?.ownGroupVmIds) ? c.demand.ownGroupVmIds.filter(x => typeof x === 'string' && x) : [];
  if (own.length > 0 && c.state !== 'RESERVING') {
    const words = own.length === 1 ? UX_MISC.ownGroupNoteOne : UX_MISC.ownGroupNote;
    return words.replace('{n}', String(own.length)).replace('{names}', own.map(id => id.split('/').pop()).join(', '));
  }
  return '';
}
/* RES-LIST-1: a reservation row with a problem sorts first: one nobody
 * confirmed, which can bill, and one Azure refused. */
function reservationProblem(c) {
  return VmfHelp.claimReservingStuck(c) || (VmfHelp.claimBlocked(c.state) && c.blockReason === 'reservation-failed');
}
/* RES-LIST-1: may the row offer Release? The reservation bills (one nobody
 * confirmed, or one Azure holds) and the page says this person may release
 * the wave now (reservationReleasable). */
function reservationBills(c) {
  return VmfHelp.claimReservingStuck(c) || c.state === 'RESERVED' || c.state === 'CONSUMED';
}
// 'unscheduled' and 'unplanned' are OUR words for "nobody has put this in a
// wave". Printing them as if they were a wave somebody named is confusing
// wherever it happens - it was seen in the capacity table.
/* WAVE-GATE-1: ONE test for "this is not a real wave".
 *
 * There were two readings of it. This label knew all three spellings; every
 * button beside it compared the wave to one spelling by hand. The planner's word
 * is `'unscheduled'` - `New-VmfPlan` gives a wave only to a machine with an
 * executable path and parks the rest there - so the group was LABELLED
 * correctly and GATED wrongly, and the page offered Accept, Approve and Start
 * on machines that can never run.
 *
 * Two readings of the same question is how they come to disagree. There is
 * one now, and the label uses it too. */
const isUnplannedWave = (w) => !w || w === 'unscheduled' || w === 'unplanned';
const waveLabel = (w) => isUnplannedWave(w) ? UX_MISC.notInAWave : w;

// RETAIN-UX-1: the safety copies and what the daily cleanup will do with
// them, from the same record the engine reads (VmfHelp.safetyCopyLedger),
// plus the pass record the timer leaves at the store root.
const whenLocal = (iso) => iso ? new Date(iso).toLocaleString() : '';
/* RETENTION-CARD-CYCLE-1: the day's cleanup is a cycle of hourly passes. While
 * the cycle has migrations still to examine, the card says the cleanup is not
 * complete, counts the migrations examined of those in the store, and names
 * the next hourly pass from the record (VmfHelp.retentionPassFacts) - not
 * 03:30 tomorrow. The Overview says the same in the same words
 * (copiesPassText in index.js). */
function copiesPassSentence(pass) {
  const count = VmfHelp.countWords;
  const f = VmfHelp.retentionPassFacts(pass);
  const fail = f.ran && f.failures.length ? UX_COPIES.passFail.replace('{reason}', f.failures.join('; ')) : '';
  const due = count(f.due, UX_COPIES.nDue), started = count(f.started, UX_COPIES.nStarted);
  if (f.unfinished) {
    const open = UX_COPIES.passOpen.replace('{ago}', ago(f.startedUtc))
      .replace('{examined}', count(f.examined, UX_COPIES.nExaminedOf, { total: f.inStore, by: f.inStore }))
      .replace('{due}', due).replace('{started}', started);
    return [open, fail, UX_COPIES.nextPassOpen.replace('{when}', whenLocal(f.nextUtc))].filter(Boolean).join(' ');
  }
  const next = UX_COPIES.nextPass.replace('{when}', whenLocal(f.nextUtc));
  if (!f.ran) { return `${UX_COPIES.passNone} ${next}`; }
  if (fail) { return `${fail} ${next}`; }
  return UX_COPIES.passLine
    .replace('{ago}', ago(pass.lastPassUtc))
    .replace('{examined}', count(f.examined, UX_COPIES.nExamined))
    .replace('{due}', due)
    .replace('{started}', started) + ' ' + next;
}
function copiesLockedCell(r) {
  if (r.status === 'deleted') { return ''; }
  if (r.locked >= r.copies) { return `<span class="pill ok" title="${esc(UX_COPIES.lockedTip)}">${esc(UX_COPIES.lockedAll)}</span>`; }
  if (r.locked === 0) { return `<span class="pill warn" title="${esc(UX_COPIES.unlockedTip)}">${esc(UX_COPIES.lockedNone)}</span>`; }
  return `<span class="pill warn" title="${esc(UX_COPIES.unlockedTip)}">${esc(UX_COPIES.lockedPart.replace('{n}', r.locked).replace('{m}', r.copies))}</span>`;
}
function copiesStatusCell(r) {
  switch (r.status) {
    case 'waiting': return UX_COPIES.statusWaiting.replace('{date}', whenLocal(r.dueUtc));
    case 'due': return UX_COPIES.statusDue;
    case 'inUse': return UX_COPIES.statusInUse;
    case 'restoreRuns': return UX_COPIES.statusRestoreRuns;
    case 'finishRuns': return UX_COPIES.statusFinishRuns;
    case 'restoreStopped': return UX_COPIES.statusRestoreStopped;
    case 'deleted': return UX_COPIES.statusDeleted.replace('{date}', whenLocal(r.deletedUtc));
    default: return UX_COPIES.statusUnreadable;
  }
}
/* TABLE-SCALE-1: one row per WAVE, and the machines behind a control.
 *
 * It was one row per machine, and on a 31-machine migration that was not
 * half done, the safety copies section already filled the page.
 *
 * Retention is a per-wave setting and nearly every column repeated down the
 * page, so the wave is the unit. The machines are still there - `Show` opens
 * them AND closes them again (rule 11) - and one summary line above answers
 * what most people came for: how many copies there are, whether they are
 * protected, and when the first one goes.
 *
 * NOTHING IS CLAIMED OF A WHOLE WAVE THAT IS NOT TRUE OF EVERY COPY IN IT.
 * "all locked" is a claim about each one; where they differ the row falls
 * back to the count, the same words a single machine used. */
let copiesOpen = new Set();

function copiesWaveRows(rows) {
  const byWave = new Map();
  for (const r of rows) {
    if (!byWave.has(r.wave)) { byWave.set(r.wave, []); }
    byWave.get(r.wave).push(r);
  }
  return [...byWave.entries()]
    .map(([wave, list]) => ({ wave, list: list.slice().sort((a, b) => a.vmId.localeCompare(b.vmId)) }))
    .sort((a, b) => a.wave.localeCompare(b.wave, undefined, { numeric: true }));
}

const copyKeepText = (r) => r.status === 'deleted' ? ''
  : r.keepDays === null ? UX_COPIES.keepUnknown
  : UX_COPIES.keepDaysUnit.replace('{n}', r.keepDays);

/* COPIES-ROW-1: what one wave's copies will do next, said once when every
 * machine agrees.
 *
 * This compared the SENTENCES, and a sentence carries its exact time: two
 * machines whose copies were due seven seconds apart read "2 different
 * outcomes - open the wave" for one outcome. The thing being compared is the
 * KIND (waiting, due, in use, deleted, unreadable), which the ledger already
 * carries. When they agree, the row gives the EARLIEST date - the first copy
 * the cleanup takes, or the first one it took. */
function copiesWaveStatus(list) {
  const kinds = [...new Set(list.map(r => r.status))];
  if (kinds.length !== 1) { return UX_COPIES.statusVaries.replace('{n}', String(kinds.length)); }
  const when = (r) => Date.parse(r.status === 'deleted' ? r.deletedUtc : r.dueUtc) || Infinity;
  const first = list.slice().sort((a, b) => when(a) - when(b))[0];
  return copiesStatusCell(first);
}

function copiesMachineRow(r, indent) {
  /* COPIES-ROW-1: SIX cells, the shape of the table. The machine sits under
   * Wave, and the Machines cell is empty for a machine - it had five, so every
   * column under an opened wave sat one to the left of its heading. */
  return `<tr${indent ? ' class="sub"' : ''}>
      <td class="mono"${indent ? ' style="padding-left:26px"' : ''}>${esc(vmName(r.vmId))}</td>
      <td></td>
      <td class="num">${esc(r.copies)}</td>
      <td>${copiesLockedCell(r)}</td>
      <td>${esc(copyKeepText(r))}</td>
      <td>${esc(copiesStatusCell(r))}</td></tr>`;
}

function renderSafetyCopies(docs, plan, pass) {
  $('#copies-title').textContent = UX_COPIES.title;
  $('#copies-hint').textContent = UX_COPIES.hint;
  $('#copies-head').innerHTML = [UX_COPIES.colWave, UX_COPIES.colMachines, UX_COPIES.colCopies, UX_COPIES.colLocked, UX_COPIES.colKeep, UX_COPIES.colStatus]
    .map((h, i) => `<th${i === 1 || i === 2 ? ' class="num"' : ''}>${esc(h)}</th>`).join('');
  const rows = VmfHelp.safetyCopyLedger(docs, plan ? plan.entries : [], null);
  const sum = VmfHelp.safetyCopySummary(rows);
  const lines = [copiesPassSentence(pass)];
  if (rows.length) {
    lines.unshift(UX_COPIES.summary
      .replace('{copies}', VmfHelp.countWords(sum.copies, UX_COPIES.nCopies))
      .replace('{machines}', VmfHelp.countWords(sum.machines, UX_COPIES.nMachines))
      .replace('{protected}', sum.unlocked === 0 ? UX_COPIES.summaryAllLocked
        : VmfHelp.countWords(sum.unlocked, UX_COPIES.summarySomeUnlocked)));
  }
  $('#copies-pass').textContent = lines.filter(Boolean).join(' ');
  const groups = copiesWaveRows(rows);
  const tb = $('#copies-table tbody');
  tb.innerHTML = groups.length ? '' : `<tr><td colspan="6" class="muted">${esc(UX_COPIES.none)}</td></tr>`;
  for (const g of groups) {
    const open = copiesOpen.has(g.wave);
    /* COUNTED ON THE SAME BASIS AS THE SUMMARY ABOVE, which is copies that
     * still EXIST - `safetyCopySummary` drops the deleted ones. Counting the
     * deleted ones here made the rows total 7 copies while the sentence above
     * them said 5. Two places counting the same thing is how they come to
     * disagree; caught by reading the page, not the code.
     *
     * A deleted copy is still listed when the wave is opened, with its own
     * "Deleted on ..." line - it is gone, not hidden. */
    const kept = g.list.filter(r => r.status !== 'deleted');
    const copies = kept.reduce((n, r) => n + r.copies, 0);
    const locked = kept.reduce((n, r) => n + r.locked, 0);
    // A claim about every copy, checked against every copy.
    const allLocked = copies > 0 && locked === copies;
    const keeps = [...new Set(kept.map(copyKeepText))];
    tb.insertAdjacentHTML('beforeend', `<tr>
      <td>${esc(waveLabel(g.wave))} <button type="button" class="btn small ghost" data-copies="${esc(g.wave)}">${
        esc(open ? UX_COPIES.hideMachines : UX_COPIES.showMachines)}</button></td>
      <td class="num">${kept.length}</td>
      <td class="num">${esc(copies)}</td>
      <td><span class="pill ${allLocked ? 'good' : 'warn'}" title="${esc(UX_COPIES.lockedTip)}">${
        esc(allLocked ? UX_COPIES.lockedAll : UX_COPIES.lockedPart.replace('{n}', String(locked)).replace('{m}', String(copies)))}</span></td>
      <td>${esc(keeps.length <= 1 ? (keeps[0] ?? '') : UX_COPIES.keepVaries)}</td>
      <td>${esc(copiesWaveStatus(g.list))}</td></tr>`);
    if (open) {
      for (const r of g.list) { tb.insertAdjacentHTML('beforeend', copiesMachineRow(r, true)); }
    }
  }
  tb.querySelectorAll('[data-copies]').forEach(b => b.addEventListener('click', () => {
    const w = b.dataset.copies;
    if (copiesOpen.has(w)) { copiesOpen.delete(w); } else { copiesOpen.add(w); }
    renderSafetyCopies(docs, plan, pass);
  }));
}

/* QUOTA-FAMILY-1 (issue 425): one row per QUOTA FAMILY and region.
 *
 * TABLE-SCALE-1 made it one row per size and region, after one row per wave
 * AND size drew eight rows of `0/100` that read as eight allowances. A wave
 * that mixed many sizes still drew a long card, and a SIZE is not what a quota
 * is either: Azure gives one allowance per family, per region, per
 * subscription, and every size in the family draws on it. Rows per size hid
 * the sum - which is the thing Test-VmfQuota judges (ODCR-FAMILY-1).
 *
 * THE FAMILY IS THE RECORD'S, NEVER THE SIZE NAME'S. `vmFamily` is what
 * Test-VmfQuota read from the SKU catalog, and s-suffix v6 sizes bill under
 * the general d_v6 family, so a name says nothing reliable. A record with NO
 * family is its own row - one per record - and says the family is not known.
 * Putting it beside another record because the size names match would be the
 * page guessing a family.
 *
 * VCPUS NEEDED IS THE ENGINE'S NUMBER (`demand.familyVcpus`, capacity-claim
 * v10): the family total Test-VmfQuota judged the headroom against. The first
 * version of this card added up the records it could see, and the review
 * found it wrong - a finished wave's records are never rewritten, so the sum
 * counted moved machines for ever, beside a reading whose `used` already held
 * them. Two places deciding one number is how they come to disagree.
 *
 * QUOTA-ROW-TWICE-1: ONE READING PER ROW, THE NEWEST CHECK'S. The Quota cell,
 * vCPUs needed and vCPUs free all come from the records of the newest quota
 * check (newestCheckOf), so the three cannot disagree. TABLE-SCALE-1 showed
 * every distinct reading, and one row said 2/20 and 0/20:
 * the start of wave-3 checks only wave-3 (RESERVE-COVER-2), so wave-2's
 * record kept the reading from planning. Both are readings of ONE quantity,
 * the family's usage in the region, and the newer replaces the older - as
 * Request-VmfQuota reads it ("the reading of the newest check"). A block and a
 * pass: the newest check wins, both ways. Every check totals the family over
 * every wave of the plan (QUOTA-BUTTON-1), so a newer pass has judged the
 * older block's machines, and a newer block always replaces an older pass. A
 * row where the check carries no total - a v9 record, or no family - shows
 * the number as not known, never a sum. */

/* QUOTA-ROW-TWICE-1: a size that is restricted, or not offered, is a fact
 * about the SIZE, not a reading of the quota: it sits beside its size, and it
 * is never the reading of the row. */
function claimSizeBlocked(c) {
  return VmfHelp.claimBlocked(c.state) &&
    (c.blockReason === 'sku-restricted' || c.blockReason === 'size-missing');
}
/* QUOTA-ROW-TWICE-1: the records of the NEWEST quota check, in the order
 * given. Test-VmfQuota stamps one checkedUtc on every record of one call, so
 * the records of one check share it. Records with no time cannot be put in
 * order, and are all the newest when no record has a time. */
function newestCheckOf(claims) {
  const at = (c) => Date.parse(c.quota?.checkedUtc ?? 0) || 0;
  const newest = Math.max(...claims.map(at));
  return claims.filter(c => at(c) === newest);
}

/* A quota row with a problem sorts first: not enough quota (blocked, or an
 * increase still waiting), a restricted size, or a quota or family that
 * cannot be verified. A RELEASED record is history and is not a problem. The
 * engine has decided each of these already - this reads its states and does
 * not judge the figures a second time.
 * QUOTA-ROW-TWICE-1: the quota answer is the newest check's (`current`). A
 * restricted size is a fact about one record, so every live record still
 * counts for it.
 * RES-LIST-1: a reservation Azure refused, or one nobody confirmed, is a fact
 * of the Capacity reservations list (reservationProblem), not of the quota. */
function quotaBlockedHere(c) {
  return VmfHelp.claimBlocked(c.state) && c.blockReason !== 'reservation-failed';
}
function capacityRowProblem(claims, family, current = claims) {
  if (!family) { return true; }
  const live = (c) => c.state !== 'RELEASED';
  return current.some(c => live(c) && (
    quotaBlockedHere(c) || c.state === 'QUOTA_REQUESTED' || c.quota?.limit == null)) ||
    claims.some(c => live(c) && claimSizeBlocked(c));
}
/* RES-LIST-1: the quota reading of a record for the Quota list. A record that
 * Azure refused a reservation for still holds its quota reading, and the
 * refusal is said in the Capacity reservations list. */
function quotaListFacet(c) {
  return (VmfHelp.claimBlocked(c.state) && c.blockReason === 'reservation-failed')
    ? quotaFacet({ ...c, state: 'QUOTA_VERIFIED', blockReason: null }) : quotaFacet(c);
}
function capacityFamilyRows(claims) {
  const rows = new Map();
  claims.forEach((c, i) => {
    const family = c.vmFamily ? String(c.vmFamily) : null;
    const key = family ? `${c.subscriptionId ?? ''}|${c.region}|${family}` : `no-family|${i}`;
    if (!rows.has(key)) {
      rows.set(key, { key, family, region: c.region, subscriptionId: c.subscriptionId ?? '', claims: [] });
    }
    rows.get(key).claims.push(c);
  });
  return [...rows.values()].map(r => {
    const bySize = new Map();
    for (const c of r.claims) {
      const k = `${c.size}|${c.zone ?? ''}`;
      if (!bySize.has(k)) { bySize.set(k, { size: c.size, zone: c.zone ?? null, claims: [] }); }
      bySize.get(k).claims.push(c);
    }
    const sizes = [...bySize.values()].sort((a, b) =>
      `${a.size} ${a.zone ?? ''}`.localeCompare(`${b.size} ${b.zone ?? ''}`, undefined, { numeric: true }));
    // QUOTA-ROW-TWICE-1: the records that read the quota; a row of only
    // restricted sizes keeps the family total its records carry.
    const readers = r.claims.filter(c => !claimSizeBlocked(c));
    const current = newestCheckOf(readers.length ? readers : r.claims);
    const total = r.family ? current.find(c => Number.isFinite(c.demand?.familyVcpus)) : null;
    const reading = current.find(c => c.quota?.limit != null && c.quota?.used != null);
    // The Quota cell shows no reading for a row whose records read no quota.
    const quotaCurrent = readers.length ? current : [];
    return { ...r, sizes, current: quotaCurrent,
      neededVcpus: total ? Number(total.demand.familyVcpus) : null,
      freeVcpus: reading ? Number(reading.quota.limit) - Number(reading.quota.used) : null,
      problem: capacityRowProblem(r.claims, r.family, quotaCurrent) };
  }).sort((a, b) => (Number(b.problem) - Number(a.problem)) ||
    `${a.family ?? ''}|${a.region}|${a.subscriptionId}|${a.sizes[0]?.size ?? ''}`
      .localeCompare(`${b.family ?? ''}|${b.region}|${b.subscriptionId}|${b.sizes[0]?.size ?? ''}`));
}

/* REGIONAL-VCPU-QUOTA-1: one row for each subscription and region, for the
 * Total Regional vCPUs quota - the quota of all vCPUs there, beside each
 * family's. Test-VmfQuota reads it from the same usage list and judges the
 * vCPUs the machines ADD (new size minus old size), so vCPUs needed is the
 * engine's number (`demand.regionalVcpus`, capacity-claim v11), never a page
 * sum. MIGRATIONS-PAGE-OLD-READERS-1: Test-VmfQuota writes it on every
 * record, so every record has its row.
 *
 * The row is a problem when a record of it is short of this quota, or when
 * Azure did not report it - the engine decided both. A record blocked on its
 * family can be short of the region too (regionalShort, capacity-claim v14):
 * VmfHelp.claimRegionalShort answers both, as Request an increase does
 * (REGIONAL-QUOTA-BOTH-PAGE-1).
 *
 * REGIONAL-QUOTA-REQUESTED-PAGE-1: once Request an increase files the
 * regional request, the record is not blocked, and the row said Headroom
 * verified with the old usage while the request waited. A record whose
 * regional request waits (VmfHelp.claimRegionalRequested) says Increase
 * requested, as its family row does, and makes the row a problem. It comes
 * before "short": a record whose family was refused stays blocked, and its
 * regional request is already filed. */
function regionalFacet(c) {
  if (VmfHelp.claimRegionalRequested(c)) {
    return `<span class="pill warn">${esc(UX_MISC.quotaReq)}</span>`;
  }
  if (VmfHelp.claimRegionalShort(c)) {
    return `<span class="pill bad">${esc(UX_MISC.quotaRegionalShort)}</span>`;
  }
  const when = c.quota?.checkedUtc ? ` <span class="muted">${esc(UX_MISC.quotaWhen)} ${ago(c.quota.checkedUtc)}</span>` : '';
  if (c.quota?.regionalLimit == null || c.quota?.regionalUsed == null) {
    return `<span class="pill warn" title="${esc(UX_CAP.regionalUnknownHint)}">${esc(UX_CAP.regionalUnknown)}</span>${when}`;
  }
  const q = ` <span class="muted mono">${esc(c.quota.regionalUsed)}/${esc(c.quota.regionalLimit)}</span>`;
  return `<span class="pill good">${esc(UX_MISC.quotaOk)}</span>${q}${when}`;
}
function capacityRegionalRows(claims) {
  const rows = new Map();
  for (const c of claims) {
    const key = `${c.subscriptionId ?? ''}|${c.region}`;
    if (!rows.has(key)) { rows.set(key, { key, regional: true, family: null, region: c.region, subscriptionId: c.subscriptionId ?? '', claims: [] }); }
    rows.get(key).claims.push(c);
  }
  return [...rows.values()].map(r => {
    const live = r.claims.filter(c => c.state !== 'RELEASED');
    // A RELEASED record is history: its figures are used only when no live
    // record of the region carries any.
    // QUOTA-ROW-TWICE-1: one reading, the newest check's, as on a family row.
    const current = newestCheckOf(live.length ? live : r.claims);
    const total = current.find(c => Number.isFinite(c.demand?.regionalVcpus));
    const reading = current.find(c => c.quota?.regionalLimit != null && c.quota?.regionalUsed != null);
    const sizes = [...new Set(r.claims.map(c => c.size))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    return { ...r, sizes, current,
      neededVcpus: total ? Number(total.demand.regionalVcpus) : null,
      freeVcpus: reading ? Number(reading.quota.regionalLimit) - Number(reading.quota.regionalUsed) : null,
      problem: live.length > 0 && (current.some(c => VmfHelp.claimRegionalShort(c) || VmfHelp.claimRegionalRequested(c)) ||
        !reading) };
  }).sort((a, b) => (Number(b.problem) - Number(a.problem)) ||
    `${a.region}|${a.subscriptionId}`.localeCompare(`${b.region}|${b.subscriptionId}`));
}

/* RES-LIST-1: does this record belong in the On-demand capacity reservations
 * list? Its wave is set to reserve, or it stands for a reservation in Azure
 * (being made, held, in use, released, or refused) - one that bills is never
 * hidden. A wave set to None, or one the plan does not show, has no row. */
function claimUsesReservation(c, gateOf) {
  const held = ['RESERVING', 'RESERVED', 'CONSUMED', 'RELEASED'];
  return held.includes(String(c.state ?? '').toUpperCase()) || c.blockReason === 'reservation-failed' || gateOf(c.wave) === 'Reserved';
}

// The distinct renderings of one facet across a group. One entry when they
// agree, which is the ordinary case; more when they do not, and then the row
// shows all of them rather than choosing.
/* QUOTA-FACET-1: group on the PILL, and gather the notes beside it.
 *
 * This used to de-duplicate on the whole rendered string - pill AND note - so
 * two claims that both said "None", only one of which had machines
 * in an availability set, drew two identical pills with one note between
 * them. It read as the page drawing something twice.
 *
 * Still NOT merged where the pills themselves differ - "Reserved" beside "Not
 * reserved" is a real disagreement and both stay. That is the point of
 * showing every reading. What changes is only that the note is no longer
 * compared as if it were the state.
 *
 * Every facet on this page starts with its pill span, so the pill is
 * everything up to the first closing tag. */
function mergeFacets(rendered) {
  const groups = new Map();
  for (const html of rendered) {
    const cut = html.indexOf('</span>');
    const pill = cut >= 0 ? html.slice(0, cut + 7) : html;
    const note = cut >= 0 ? html.slice(cut + 7).trim() : '';
    if (!groups.has(pill)) { groups.set(pill, new Set()); }
    if (note) { groups.get(pill).add(note); }
  }
  return [...groups.entries()].map(([pill, notes]) => pill + (notes.size ? ' ' + [...notes].join(' ') : ''));
}
/* QUOTA-ONCE-1: a size used by two waves printed its quota twice, the same
 * figures a second apart. Quota belongs to the size family in the region, not
 * to a wave, so both waves' records carry the same reading. Readings that agree
 * on everything but WHEN they were taken show once, with the newest time. A
 * real disagreement in the figures still shows both. QUOTA-ROW-TWICE-1: the
 * card gives it only the records of the newest check (newestCheckOf). */
function quotaFacetsOf(claims, facet = quotaFacet) {
  const newestFirst = [...claims].sort((a, b) =>
    (Date.parse(b.quota?.checkedUtc ?? 0) || 0) - (Date.parse(a.quota?.checkedUtc ?? 0) || 0));
  const seen = new Set();
  const out = [];
  for (const c of newestFirst) {
    // The same facet drawn without its time is the reading itself.
    const reading = facet({ ...c, quota: c.quota && { ...c.quota, checkedUtc: undefined } });
    if (seen.has(reading)) { continue; }
    seen.add(reading);
    out.push(facet(c));
  }
  return out;
}
/* RES-LIST-1: the card is TWO lists. One cell that held the quota, every
 * reservation of the row and the In use count together could not be read.
 *   Quota                  one row for each quota family and region, and one
 *                          for the Total Regional vCPUs of each region. No
 *                          reservation data.
 *   Capacity reservations  one row for each wave and size: the state, one short
 *                          fact, and Release where it applies now. Shown when
 *                          a wave in view uses one (claimUsesReservation).
 * releasable(wave): may this person release the wave now - the page passes
 * reservationReleasable; asked once for each wave, and only for a row that
 * bills. */
function renderCapacity(claims, plan, releasable = () => false) {
  const gateOf = capacityGateOf(plan);
  // QUOTA-CARD-LAYOUT-1: a class for each column, on its heading and its
  // cells, that app.css lays out: the Quota cell (the pill and its reading)
  // never wraps, a figure is as narrow as its heading, and the Sizes column
  // takes what is left and wraps between names inside it.
  const heads = [
    { text: UX_CAP.colFamily }, { text: UX_CAP.colSizes, cls: 'cap-sizes' },
    { text: UX_CAP.colNeeded, num: true, tip: UX_CAP.colNeededTip },
    { text: UX_CAP.colFree, num: true, tip: UX_CAP.colFreeTip },
    { text: UX_CAP.colQuota, cls: 'cap-quota' },
  ];
  const headHtml = (list) => list.map(h => {
    const cls = [h.num ? 'num' : '', h.cls ?? ''].filter(Boolean).join(' ');
    return `<th${cls ? ` class="${cls}"` : ''}${h.tip ? ` title="${esc(h.tip)}"` : ''}>${esc(h.text)}</th>`;
  }).join('');
  $('#cap-head').innerHTML = headHtml(heads);
  const tb = $('#cap-table tbody');
  const rows = capacityFamilyRows(claims);
  // REGIONAL-VCPU-QUOTA-1: a regional row that is short comes first, as a
  // family row with a problem does; one that is fine comes after the families.
  const regional = capacityRegionalRows(claims);
  tb.innerHTML = rows.length ? '' : `<tr><td colspan="${heads.length}" class="muted">${esc(UX_CAP.none)}</td></tr>`;
  // The subscription is named only when the card holds more than one, which
  // is the only time two rows could otherwise read the same.
  const manySubs = new Set(claims.map(c => c.subscriptionId ?? '')).size > 1;
  const subNote = (id) => (manySubs && id ? ` <span class="muted">${esc(UX_CAP.inSubscription.replace('{id}', id))}</span>` : '');
  // A restricted size, or one not offered here, is a fact about the SIZE. In a
  // row of several sizes, "This size is restricted here" on the family quota
  // names no size, so it sits beside the size it is about.
  const sizeName = (s) => s.zone ? UX_CAP.sizeInZone.replace('{size}', s.size).replace('{zone}', s.zone) : s.size;
  const regionalRow = (r) => {
    tb.insertAdjacentHTML('beforeend', `<tr>${[
      `<td><span class="mono cap-size" title="${esc(UX_CAP.regionalHint)}">${esc(UX_CAP.regionalName)} @ ${esc(r.region)}</span>${subNote(r.subscriptionId)}</td>`,
      `<td class="cap-sizes">${r.sizes.map(s => `<span class="nowrap mono">${esc(s)}</span>`).join(', ')}</td>`,
      `<td class="num">${r.neededVcpus == null ? '-' : esc(r.neededVcpus)}</td>`,
      `<td class="num">${r.freeVcpus == null ? '-' : esc(r.freeVcpus)}</td>`,
      `<td class="cap-quota">${quotaFacetsOf(r.current, regionalFacet).join('<br>')}</td>`,
    ].join('')}</tr>`);
  };
  regional.filter(r => r.problem).forEach(regionalRow);
  for (const r of rows) {
    const name = r.family
      ? `<span class="mono cap-size">${esc(r.family)} @ ${esc(r.region)}</span>${subNote(r.subscriptionId)}`
      : `<span class="pill warn" title="${esc(UX_CAP.familyUnknownHint)}">${esc(UX_CAP.familyUnknown)}</span> <span class="mono cap-size">@ ${esc(r.region)}</span>${subNote(r.subscriptionId)}`;
    const sizes = r.sizes.map(s => {
      const blocks = mergeFacets(s.claims.filter(claimSizeBlocked).map(quotaFacet));
      return `<span class="nowrap"><span class="mono">${esc(sizeName(s))}</span>${blocks.length ? ' ' + blocks.join(' ') : ''}</span>`;
    }).join(', ');
    // QUOTA-ROW-TWICE-1: the newest check's reading. RES-LIST-1: a refused
    // reservation is said in the Capacity reservations list, not here.
    const quotaFacets = quotaFacetsOf(r.current, quotaListFacet);
    tb.insertAdjacentHTML('beforeend', `<tr>${[
      `<td>${name}</td>`,
      `<td class="cap-sizes">${sizes}</td>`,
      `<td class="num">${r.neededVcpus == null ? '-' : esc(r.neededVcpus)}</td>`,
      `<td class="num">${r.freeVcpus == null ? '-' : esc(r.freeVcpus)}</td>`,
      `<td class="cap-quota">${quotaFacets.length ? quotaFacets.join('<br>') : '-'}</td>`,
    ].join('')}</tr>`);
  }
  regional.filter(r => !r.problem).forEach(regionalRow);

  // ---- On-demand capacity reservations ----
  // Only the waves that use one: a wave set to reserve, or a record that
  // stands for a reservation in Azure. The card is Quota when there is none.
  const section = $('#res-section');
  const used = claims.filter(c => claimUsesReservation(c, gateOf));
  const show = used.length > 0;
  section.style.display = show ? '' : 'none';
  $('#cap-title').textContent = show ? UX_CAP.titleBoth : UX_CAP.titleQuota;
  $('#cap-hint').textContent = show ? UX_CAP.hintBoth : UX_CAP.hintQuota;
  $('#cap-quota-sub').style.display = show ? '' : 'none';
  $('#cap-quota-title').textContent = UX_CAP.titleQuota;
  $('#cap-quota-hint').textContent = UX_CAP.quotaListHint;
  $('#res-title').textContent = UX_CAP.resTitle;
  $('#res-hint').textContent = UX_CAP.resHint;
  const rtb = $('#res-table tbody');
  if (!show) { $('#res-head').innerHTML = ''; rtb.innerHTML = ''; return; }
  $('#res-head').innerHTML = headHtml([{ text: UX_CAP.colWave }, { text: UX_CAP.colSize }, { text: UX_CAP.colState }, { text: UX_CAP.colFact, cls: 'cap-fact' }, { text: '', cls: 'cap-act' }]);
  const manyRegions = new Set(claims.map(c => c.region)).size > 1;
  const releaseOf = new Map();
  const mayRelease = (w) => { if (!releaseOf.has(w)) { releaseOf.set(w, !!releasable(w)); } return releaseOf.get(w); };
  const resRows = [...used].sort((a, b) =>
    (Number(reservationProblem(b)) - Number(reservationProblem(a))) ||
    String(waveLabel(a.wave)).localeCompare(String(waveLabel(b.wave))) ||
    String(a.size).localeCompare(String(b.size)) || String(a.zone ?? '').localeCompare(String(b.zone ?? '')));
  rtb.innerHTML = '';
  // ONE Release for each wave - it acts on every reservation of the wave - on
  // the wave's first row, problem rows first, when a row of the wave bills.
  const billsInWave = new Set(resRows.filter(reservationBills).map(c => c.wave));
  const releaseDrawn = new Set();
  for (const c of resRows) {
    const size = sizeName({ size: c.size, zone: c.zone });
    const sizeText = manyRegions ? UX_CAP.sizeInRegion.replace('{size}', size).replace('{region}', c.region) : size;
    const fact = reservationFact(c);
    // ODCR-STATUS-1: Release only where it applies now - the reservation
    // bills, and this person may release the wave now.
    const first = !releaseDrawn.has(c.wave);
    releaseDrawn.add(c.wave);
    const release = (first && billsInWave.has(c.wave) && mayRelease(c.wave))
      ? `<button type="button" class="btn small ghost" data-releasewave="${esc(c.wave)}" title="${esc(UX_MISC.releaseTip)}">${esc(UX_MISC.releaseBtn)}</button>` : '';
    rtb.insertAdjacentHTML('beforeend', `<tr>${[
      `<td><span class="nowrap">${esc(waveLabel(c.wave))}</span></td>`,
      `<td><span class="nowrap mono">${esc(sizeText)}</span>${subNote(c.subscriptionId)}</td>`,
      `<td>${reservationFacet(c, gateOf(c.wave))}</td>`,
      `<td class="cap-fact">${fact ? `<span class="muted">${esc(fact)}</span>` : ''}</td>`,
      `<td class="cap-act">${release}</td>`,
    ].join('')}</tr>`);
  }
  rtb.querySelectorAll('[data-releasewave]').forEach(b => b.addEventListener('click', () => askReleaseReservation(b.dataset.releasewave)));
}
// PLANTIME-1: the reserve, release and quota controls that used to
// sit here have moved into the wizard's Capacity step, where the plan is made.
// A quota increase takes DAYS and a reservation wants creating a day or two
// ahead; both were on the screen you open when you are about to press start,
// where finding out is already too late to act on.
//
// This card still SHOWS the capacity picture, because watching it is a run-time
// concern. It just no longer offers decisions that belong earlier.

// LOG-1: how much of the log the feed shows. The latest 30 by default;
// the whole thing on request, in a box that scrolls.
const FEED_RECENT = 30;
let showWholeLog = false;
function toggleWholeLog() {
  showWholeLog = !showWholeLog;
  if (latestEvents) { renderEvents(latestEvents); }
}

function renderEvents(events) {
  const tb = $('#event-table tbody');
  const recent = activityLines(events, showWholeLog, showWholeLog ? Infinity : FEED_RECENT);
  // LOG-1: the footer says what is shown, and the button offers the rest.
  const total = events.filter(e => e.outcome !== 'start' && !(e.step === 'engine:memory' && e.peakWorkerMB === undefined)).length;
  $('#event-scroll').classList.toggle('all', showWholeLog);
  const tog = $('#ev-toggle');
  tog.hidden = total <= FEED_RECENT && !showWholeLog;
  tog.textContent = showWholeLog ? UX_MISC.logShowRecent.replace('{n}', FEED_RECENT) : UX_MISC.logShowAll;
  tog.onclick = toggleWholeLog;
  $('#ev-count').textContent = !total ? '' : showWholeLog
    ? UX_MISC.logAllOf.replace('{total}', total)
    : UX_MISC.logRecentOf.replace('{n}', Math.min(FEED_RECENT, total)).replace('{total}', total);
  tb.innerHTML = recent.length ? '' : '<tr><td colspan="3" class="muted">Nothing yet.</td></tr>';
  for (const { e, wasRecovered, stepLine, rollsBackNow } of recent) {
    const raw = `${e.step}${e.outcome ? ' [' + e.outcome + ']' : ''}${e.detail ? ' - ' + e.detail : ''}`;
    // ACTIVITY-LINES-1: an attempt the engine tries again is information,
    // and so is the Azure call line of that attempt in the whole log.
    const retried = stepRetried(e) ? e : (stepLine && stepRetried(stepLine) ? stepLine : null);
    const flag = retried ? `<span class="pill quiet">${esc(retriedText(retried))}</span><br>`
               : (e.outcome === 'fail' && wasRecovered)
                   ? `<span class="pill warn">${esc(UX_STEP.recoveredNote)}</span><br>`
               // LOG-SAYS-WHY-1: a refusal is amber, not red. A gate that
               // stops a wave is this product working as designed, and it sat
               // in the feed wearing the same badge as an engine crash.
               : e.outcome === 'refused' ? `<span class="pill warn">${esc(UX_STEP.refusedNote)}</span><br>`
               : e.outcome === 'fail' ? `<span class="pill bad">${esc(feedFailNote(e))}</span><br>`
               : e.outcome === 'warn' ? `<span class="pill warn">${esc(UX_STEP.warnNote)}</span> ` : '';
    tb.insertAdjacentHTML('beforeend', `<tr title="${esc(raw)}">
      <td class="muted" style="white-space:nowrap">${esc(ago(e.tsUtc))}</td>
      <td class="mono">${e.vmId ? esc(vmName(e.vmId)) : ''}</td>
      <td>${flag}${esc(stepText(e))}${rollsBackNow ? ` <span class="muted">${esc(UX_STEP.rollsBackNote)}</span>` : ''}</td></tr>`);
  }
}

/* RESTORE-PANEL-TIMELINE-1: the lines the Activity table shows, newest first,
 * as { e, wasRecovered, stepLine, rollsBackNow }. ONE rule for the table and
 * for the machine panel's "What happened, newest first": the panel built its
 * own list from the state document's history, and a restore writes no
 * history, so after Restore this machine the panel showed none of it (final
 * lab, 2026-11-17). whole: the whole log (nothing folded or collapsed); cap:
 * the most lines to give. PURE. */
function activityLines(events, whole, cap) {
  events = events ?? [];
  // ONE user-visible line per step - the feed used to look like the same
  // step over and over. A single step produces several technical
  // records - a start marker, the Azure-level record, the stage completion -
  // so: start markers are skipped (the row appears when the step finishes or
  // fails), and rows that render to the same sentence for the same machine
  // within a short window are collapsed. The full record stays in the
  // machine's drill panel and in row tooltips.
  // RETRY-UI-1, spotted in the PERM-2 drill: the run went forward but
  // showed errors. Two red rows, over a transient transport error
  // that was retried and succeeded.
  //
  // The two records DISAGREED: the machine's state document said no step
  // failed - correctly - while the feed said one did, in red, and never said
  // it was recovered. The feed is the thing on screen. Teaching operators that
  // red can be ignored is worse than showing nothing.
  //
  // Derived, not stored: a fail is recovered when the SAME step on the SAME
  // machine LATER reports ok. Order matters - an ok BEFORE the failure is a
  // previous attempt at the same step and proves nothing about this one, and
  // reading it as proof would launder the failure that ended the run.
  //
  // The ordering comes from the DIRECTION of this loop, not from a comparison:
  // walking backwards, lastOk can only ever hold an index greater than i, so by
  // the time a fail is examined the only successes on record are ones that come
  // after it. The `> i` below is therefore always true - it is kept as an
  // assertion of that invariant, so flipping this loop cannot silently start
  // laundering failures. (Verified: reversing the direction breaks two tests.)
  // COPY-DELETE-LOCK-RACE-1, MEASURED on the lab install 2026-11-14: a safety
  // copy line has no machine, so the delete of ANOTHER copy that worked marked
  // a refused delete "failed once, then succeeded on retry". The key holds the
  // copy too.
  const recovered = new Set();
  {
    const lastOk = new Map();
    for (let i = events.length - 1; i >= 0; i--) {
      const e = events[i];
      const k = `${e.vmId ?? ''}|${e.step ?? ''}|${e.snapshotId ?? ''}`;
      if (e.outcome === 'ok') { if (!lastOk.has(k)) lastOk.set(k, i); }
      else if (e.outcome === 'fail' && lastOk.has(k) && lastOk.get(k) > i) { recovered.add(i); }
    }
  }
  // ACTIVITY-LINES-1: the Azure call line that the step's own line repeats.
  const folded = foldedCallLines(events);
  // STATUS-WORDS-1: the failures a rollback follows say what happens next.
  const rollsBack = rollbackFollows(events);
  const shownAt = new Map();
  const recent = [];
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (e.outcome === 'start') continue;
    if (!whole && folded.has(i)) continue;
    if (e.step === 'engine:memory' && e.peakWorkerMB === undefined) continue;   // a reading, not news
    // ACTIVITY-LINES-1 (review): each attempt that is tried again is its own
    // line - two attempts with the same cause are not one repeat.
    const key = `${e.vmId ?? ''}|${stepText(e)}|${e.outcome === 'fail' ? 'fail' : stepRetried(e) ? `retry${e.attempt ?? ''}` : ''}`;
    const t = Date.parse(e.tsUtc) || 0;
    // The whole log collapses nothing: a person who asked for all of it
    // wants every line the engine wrote, repeats included.
    if (!whole && shownAt.has(key) && Math.abs(shownAt.get(key) - t) < 180000) continue;
    shownAt.set(key, t);
    recent.push({ e, wasRecovered: recovered.has(i), stepLine: folded.has(i) ? events[folded.get(i)] : null, rollsBackNow: rollsBack.has(i) });
    if (recent.length >= cap) break;
  }
  return recent;
}

/* STATUS-WORDS-1: the failure lines that an automatic rollback follows, by
 * their place in events. The failure of Verifying ("The Instance Metadata
 * Service answered before the move and does not answer now") did not say that
 * the product now rolls the machine back on its own, and that the person does
 * nothing. A line counts when it is the failure of a step of the move (the
 * attempt that ends the step, never one the engine tries again) and the same
 * machine's rollback started at or after it - a rollback the product refused
 * writes no start line, so no line promises it. PURE. */
function rollbackFollows(events) {
  const starts = new Map();
  for (const e of (events ?? [])) {
    if (!e || e.step !== 'rollback' || e.outcome !== 'start' || !e.vmId) { continue; }
    const k = VmfHelp.idKey(e.vmId);
    const t = Date.parse(e.tsUtc ?? '');
    if (Number.isFinite(t)) { starts.set(k, [...(starts.get(k) ?? []), t]); }
  }
  const out = new Set();
  (events ?? []).forEach((e, i) => {
    if (!e || e.outcome !== 'fail' || !e.vmId || !Object.prototype.hasOwnProperty.call(UX_RAN, String(e.step ?? ''))) { return; }
    const t = Date.parse(e.tsUtc ?? '');
    if (Number.isFinite(t) && (starts.get(VmfHelp.idKey(e.vmId)) ?? []).some(s => s >= t)) { out.add(i); }
  });
  return out;
}

/* RESTORE-END-LOST-1: the engine's fail line now names the machine of a
 * restore or a rebuild, and it carries its reason in the row. The machine's
 * panel does not show the run's log, so "Open the machine" would send a person
 * to a place without the reason. */
function feedFailNote(e) {
  return (e.vmId && !/^engine:/.test(String(e.step ?? ''))) ? UX_STEP.failedNote : UX_STEP.failedNoteRun;
}

/* ACTIVITY-LINES-1: the line of an attempt of a step of the move that the
 * engine tries again (the engine writes it since this item; an attempt that
 * ends the step is a fail line). An Azure call's own retry line is not one. */
function stepRetried(e) {
  return Boolean(e) && e.outcome === 'retry' && Boolean(e.vmId)
    && Object.prototype.hasOwnProperty.call(UX_STATE, String(e.step ?? ''));
}
/** The words of that line: which attempt failed, and that the step goes on. */
function retriedText(e) {
  const n = Number(e?.attempt), max = Number(e?.maxAttempts);
  return (n > 0 && max > 0) ? UX_STEP.retriedNote.replace('{n}', String(n)).replace('{max}', String(max)) : UX_STEP.retriedNoteBare;
}
/* ACTIVITY-LINES-1, MEASURED on the lab install 2026-11-04: a failed Azure
 * call and the step attempt it ended are ONE event, and the Activity list drew
 * two red lines for it - the call's line and the step's line, with the same
 * cause. The step's line (a retry or a fail line of a step of the move) takes
 * the Azure call lines of the same machine in the same attempt - after the
 * step's last start line - that failed with the same words. Returns a Map:
 * the index of a call line -> the index of its step line. The list shows the
 * step line; the whole log shows both. PURE. */
function foldedCallLines(events) {
  const folded = new Map();
  const list = events ?? [];
  for (let i = 0; i < list.length; i++) {
    const e = list[i];
    if (!e || !e.vmId || !e.detail || !(e.outcome === 'retry' || e.outcome === 'fail')) continue;
    const step = String(e.step ?? '');
    if (!Object.prototype.hasOwnProperty.call(UX_STATE, step)) continue;
    for (let j = i - 1; j >= 0; j--) {
      const c = list[j];
      if (!c || c.vmId !== e.vmId) continue;
      if (String(c.step ?? '') === step && c.outcome === 'start') break;
      if (String(c.step ?? '').startsWith('azureops:') && c.outcome === 'fail' && c.detail === e.detail && !folded.has(j)) { folded.set(j, i); }
    }
  }
  return folded;
}
/* TRAIL-1: everything that happened to a machine, newest first.
 *
 * THE DEFECT, seen on a live install 2026-09-18. The trail is built from the
 * machine's migration history, and a PUT-BACK is not a migration state - it is
 * recorded separately, in its own field, and drawn in its own box above. So
 * after a successful put-back the list headed "What happened, newest first"
 * ended at "Migrated", while the newest thing that had happened to that machine
 * was the put-back sitting a few lines higher.
 *
 * The trail is the record of what happened to a machine. A thing that happened
 * to it belongs in that record, whatever field it is stored in.
 *
 * Merged by TIME rather than appended, so it lands where it happened - a
 * put-back is usually newest but need not be, and a machine migrated again
 * after one would otherwise read out of order.
 *
 * Kept apart from the drawing so the ordering can be tested without a page.
 *
 * RESTORE-PANEL-TIMELINE-1, final lab 2026-11-16 and 2026-11-17: the list was
 * still built from the history, with the restore RECORD added. A restore
 * writes no history, and its record says only that it ended, so after Restore
 * this machine the list showed none of its steps ("Building a disk from the
 * safety copy", the names of the restored data disks), and a restore that
 * failed left nothing at all - the steps were only in the Activity table.
 *
 * So the list IS the machine's lines of the run history, by the rule the
 * Activity table uses (activityLines): a move, a rollback, a retry, a restore,
 * Finish, Leave this machine out - everything the engine wrote for the
 * machine. Only the ENDS of the history are added: an entry in a state where
 * the machine stopped or finished (TERMINAL_STATES). The engine writes some
 * of them in the state document only (the stop after a rollback, and Stop
 * this migration), and they carry the stop's whole sentence and its captured
 * evidence. A line that says a stop's detail again is not repeated. PURE.
 */
function machineTimeline(doc, events) {
  const key = VmfHelp.idKey(doc?.vmId);
  const mine = key ? (events ?? []).filter(e => e && VmfHelp.idKey(e.vmId) === key) : [];
  const ends = [];
  for (const h of (doc?.history ?? [])) {
    if (!h || !TERMINAL_STATES.includes(h.state)) { continue; }
    const [label, desc] = UX_STATE[h.state] ?? [h.state, ''];
    // The time on such an entry is the step before it (STATUS-WORDS-1): its
    // own closing line says it, so the end carries none.
    ends.push({ tsUtc: h.tsUtc, kind: 'state', label, desc, outcome: h.outcome, state: h.state,
                ran: null, detail: h.detail, evidenceRef: h.evidenceRef });
  }
  const said = new Set(ends.map(h => h.detail).filter(Boolean));
  const lines = activityLines(mine, false, Infinity)
    .filter(({ e }) => !said.has(stepText(e)))
    .map(l => timelineLine(l, said));
  // Newest first; at the same time, the end above the line that led to it.
  return [...lines, ...ends].filter(h => !Number.isNaN(Date.parse(h.tsUtc ?? '')))
    .sort((a, b) => (Date.parse(b.tsUtc) - Date.parse(a.tsUtc)) || ((a.kind === 'state' ? 0 : 1) - (b.kind === 'state' ? 0 : 1)));
}
/* RESTORE-PANEL-TIMELINE-1: one line of the run history in the panel's step
 * format - a heading, the sentence under it, and the engine's detail when the
 * sentence does not already say it (said: the details of the ends). A step of
 * the move keeps its name as the heading (Checking, Verifying), and the time
 * on its closing line is that step's own (ran). The end of a restore keeps
 * the headings the panel gave it. PURE. */
function timelineLine(l, said) {
  const e = l.e;
  const text = stepText(e);
  const isStep = Object.prototype.hasOwnProperty.call(UX_STATE, String(e.step ?? ''));
  let kind = 'line', label = text, desc = '';
  if (isStep) {
    label = UX_STATE[e.step][0];
    desc = stepRetried(e) ? retriedText(e) : text;
  } else if (e.step === 'restore' && RESTORE_ENDS.includes(e.outcome)) {
    kind = 'restore';
    label = e.outcome === 'ok' ? UX_ACT.restoredStep : UX_ACT.restoreNotDone;
    desc = text;
  }
  if (l.wasRecovered && e.outcome === 'fail') { desc = `${desc} ${UX_STEP.recoveredNote}`.trim(); }
  if (l.rollsBackNow) { desc = `${desc} ${UX_STEP.rollsBackNote}`.trim(); }
  const detail = (e.detail && !label.includes(e.detail) && !desc.includes(e.detail) && !said.has(e.detail)) ? e.detail : '';
  return { tsUtc: e.tsUtc, kind, label, desc, outcome: l.wasRecovered ? 'ok' : e.outcome, step: e.step,
           ran: isStep ? e.step : null, durationSec: e.durationSec, detail };
}
/* STATUS-WORDS-1: the duration on a line of the timeline, naming the work it
 * measures (machineTimeline's ran). '' when the line has no duration, or the
 * step was no step of the move. PURE. */
function timelineDuration(h) {
  if (!h || !h.durationSec || !UX_RAN[h.ran]) { return ''; }
  return `<span class="muted"> &middot; ${esc(UX_MISC.tookStep.replace('{step}', UX_RAN[h.ran]).replace('{n}', String(Math.round(h.durationSec))))}</span>`;
}

/* MACHINE-PANEL-STALE-1: the machine the side panel shows, the run it belongs
 * to, and the markup it last drew. The panel was drawn ONE time, when its row
 * was selected, so in the BGINFO-PERM-1 drill it kept "Needs a decision", the
 * stop box and Try this machine again on a machine a retry had migrated. The
 * refresh now draws it again from the fresh state document (refreshDrill). */
let drillVmId = null, drillRun = null, drillDrawn = null;
/* The id of the panel control that held the focus before a redraw, until
 * refocusDrill puts it back; null when nothing is to be put back. */
let drillFocusId = null;
/* RETRY-SERIES-1 answer for the panel on the screen, so a redraw of the same
 * machine with the same plan entry and state asks the service nothing. */
let retrySeriesCache = null;

/* MACHINE-PANEL-STALE-1: a time in the panel said as "4 minutes ago". That
 * text changes by itself, so it is marked: the redraw check leaves it out
 * (drillKey), and a refresh with nothing else new only writes the times
 * again (drawDrill). */
function agoSpan(iso) {
  return `<span data-ago="${esc(iso ?? '')}">${esc(ago(iso))}</span>`;
}
/** The panel markup without the "... ago" texts: what a redraw compares. */
function drillKey(html) {
  return String(html).replace(/(<span data-ago="[^"]*">)[^<]*(<\/span>)/g, '$1$2');
}

/* CAPACITY-WORDS-1: the capacity line of the machine panel, in approved
 * words. Azure's names: an on-demand capacity reservation, and a
 * capacity reservation group.
 *   - Its own group first, by the engine's rule (Get-VmfOwnReservationGroup):
 *     the group PRECHECK recorded in captured.vmConfig.capacityReservationGroupId
 *     (vm-state v24), when no quota record of this migration names it. The move
 *     keeps the machine there, and it takes no slot of its wave. Before
 *     PRECHECK the plan entry's assessment says (OLD-STATE-READERS-PAGE-1:
 *     every capture holds the field, vm-state v47).
 *   - A slot of its wave: the claim names the machine (associatedVmIds).
 *   - An availability set: Azure allows no capacity reservation.
 *   - A wave that does not reserve capacity.
 *   - A Reserved wave whose machine took no slot: only the fact, and only in
 *     a state where it cannot join any more: Migrated, Not migrated, or Rolled
 *     back (the rollback leaves the group of the wave). A machine that waits for
 *     a decision stopped before any change and resumes, so it can still join;
 *     one that needs attention may still be in the group. '' is no line. */
function capacityLine(doc, entry, vmId, claims) {
  const all = (claims || []).filter(Boolean);
  const ours = new Set(all.flatMap(c => [c.reservation?.groupId, c.reservationAsked?.groupId])
    .filter(g => typeof g === 'string' && g).map(g => g.toLowerCase()));
  const vmConfig = doc?.captured?.vmConfig;
  const group = vmConfig ? vmConfig.capacityReservationGroupId : entry?.assessment?.capacityReservationGroupId;
  if (typeof group === 'string' && group && !ours.has(group.toLowerCase())) {
    return UX_ACT.capOwnGroup.replace('{group}', group.split('/').pop());
  }
  if (all.some(c => (c.associatedVmIds ?? []).includes(vmId))) { return UX_ACT.capOdcrUsed; }
  if (vmConfig?.availabilitySetId || entry?.assessment?.availabilitySetId) { return UX_ACT.capAvset; }
  if (entry?.policy?.capacityGate !== 'Reserved') { return UX_ACT.capNoneWave; }
  return ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK'].includes(doc?.state) ? UX_ACT.capNoneSlot : '';
}

// opts.keep: a redraw of the panel on the screen, from the refresh - see drawDrill.
async function openDrill(doc, entry, vmId, opts) {
  const name = vmName(vmId);
  const keep = Boolean(opts && opts.keep);
  if (!keep) { diskDelete = null; madeHelpOpen.clear(); }
  if (!doc) {
    // MANUAL-WHY-1: a machine the plan does not move is not queued.
    if (drawDrill(`<h3 class="mono">${esc(name)}</h3>${notMovedReasons(entry) ? notMovedHtml(entry) : '<p class="muted">Queued - nothing has happened yet.</p>'}`, vmId, keep)) {
      // DIALOG-STALE-1: the refresh found no state document for a machine
      // that had one - a dialog this panel opened says so.
      markDialogStale(vmId, doc);
      refocusDrill();
    }
    return;
  }
  const hist = machineTimeline(doc, latestEvents).map(h => {
    const cls = h.kind === 'restore' || h.kind === 'identity' ? 'fail'
      : h.outcome === 'fail' ? 'fail' : ['MIGRATED'].includes(h.state) ? 'done' : '';
    const dur = timelineDuration(h);
    const detail = h.detail ? `<div class="tech" title="${esc(h.detail)}">${esc(techText(h.detail))}</div>` : '';
    const evd = h.evidenceRef ? `<div><span class="evlink" data-ev="${esc(h.evidenceRef.startsWith('evidence/') ? h.evidenceRef : 'evidence/' + h.evidenceRef)}">view the captured evidence</span></div>` : '';
    return `<li class="${cls}"><b>${esc(h.label)}</b>${dur}<div class="muted">${esc(h.desc)}</div><div class="when">${esc(new Date(h.tsUtc).toLocaleString())}</div>${detail}${evd}</li>`;
  }).join('');
  const guest = [...(doc.guestExecutions ?? [])].reverse().map((g, i) => {
    const friendly = stepText({ step: `runcmd:${g.script}` });
    // The newest entry of a machine still at work can be a script running now.
    const running = i === 0 && !TERMINAL_STATES.includes(doc.state);
    const pill = guestRunPill(g, running);
    // PREP-ROLLBACK-1: a script that runs now has no output yet.
    const evd = (g.evidenceRef && !(g.result === 'STARTED' && running)) ? `<span class="evlink" data-ev="${esc(g.evidenceRef)}">evidence</span>` : '';
    return `<tr title="${esc(g.script)} v${esc(g.version)} = ${esc(g.result)}"><td>${esc(friendly)}</td>
      <td>${pill}</td>
      <td class="muted" style="white-space:nowrap">${agoSpan(g.tsUtc)}</td><td>${evd}</td></tr>`;
  }).join('');
  // COCK-4: what happened to THIS machine's capacity, in one line. The
  // aggregate maths stays in the capacity table; this answers the question an
  // operator asks while looking at one machine.
  const placement = capacityLine(doc, entry, vmId, latestClaims);
  const placementLine = placement ? `<p class="muted" title="${esc(UX_ACT.placementTip)}">${esc(placement)}</p>` : '';

  const cp = checkpointLine(doc);
  // RETRY-1: FAILED_ROLLED_BACK is offered too - a machine that was put back
  // automatically is the best retry candidate in the system, and it used to be
  // the one state with no control at all. Withheld only where the reason says
  // this engine cannot migrate the machine, where a retry is theatre.
  const lastStop = attemptStop(doc);
  const lastGuidance = stopReasons.get(lastStop?.reasonCode);
  // DECIDE-2: the rule is in stopControls, above, where a test can run it.
  // POWER-ONLY-CHANGED-1: and a power state not put back always offers the retry.
  const offer = stopControls(doc.state, lastGuidance, canOperate(), canApprove(), !!powerOwed(doc));
  // ROLLBACK-RETRY-CAPTURE-1: both controls re-arm the machine through the
  // same engine call, so both are offered only where the engine accepts it.
  // Where it would refuse, the reason is said in their place - a missing
  // button with no sentence reads as a product that forgot.
  const held = (offer.retry || offer.decide) && retryHeld(doc);
  // DECIDE-ROLE-1: the decision is offered only for the park the machine
  // waits at now - the engine refuses any other.
  const decideBtn = (offer.decide && !held && decisionWaiting(doc) === lastStop)
    ? `<button type="button" class="btn" id="decide-btn">${esc(UX_ACT.decide)}</button>` : '';
  const resolveBtn = (offer.retry && !held)
    ? `<button type="button" class="btn" id="resolve-btn">${esc(UX_ACT.resolve)}</button>` : '';
  const heldLine = held ? `<p class="muted" style="margin:6px 0">${esc(doc.swapPending ? UX_ACT.retryHeldSwap : UX_ACT.retryHeld)}</p>` : '';
  // Offered only where a safety copy actually exists - a machine that never
  // reached that step has not been changed, so there is nothing to put back.
  // RESTORE-ONE-AT-A-TIME-1: not while a restore of it runs.
  const putBack = putBackControls(doc, vmId, canOperate());
  const restoreBtn = putBack.restore
    ? `<button type="button" class="btn ghost" id="restore-btn">${esc(UX_ACT.restore)}</button>` : '';
  // SWAP-REFUSED-AFTER-STOP-1: Finish the rollback, or Finish the restore.
  const finishBtn = putBack.finish
    ? `<button type="button" class="btn" id="finish-btn">${esc(putBack.finish === 'restore' ? UX_ACT.finishRestore : UX_ACT.finishRollback)}</button>` : '';
  // Said on the screen, not in a title: the reason the button is gone.
  const putBackBusyLine = (putBack.busy && canOperate()) ? `<p class="muted" style="margin:6px 0">${esc(UX_ACT.putBackBusy)}</p>` : '';
  // RESTORE-MID-MOVE-1: said on the screen, not in a title - why Restore this
  // machine is not there while the move has not ended, and the rollback now.
  const midMoveLine = (restoreWaitsForMove(doc, canOperate())) ? `<p class="muted" style="margin:6px 0">${esc(UX_ACT.restoreMidMove)}</p>` : '';
  // FREE-MACHINE-GONE-1: a machine whose worker stopped is freed by the
  // engine: the wave watchdog removes a lease whose heartbeat is older than
  // the limit, and the service starts a stopped wave again.
  /* SKIP-ONE-1: leave THIS machine out, so the wave can finish.
   *
   * A machine parked below the MANA kernel floor held its wave, and there was
   * no control to skip the machine in this wave.
   * The three controls were rebuild it, accept the risk, or try again -
   * every one of them about making it migrate. "I will deal with this one
   * later" was not among them, anywhere in the product.
   *
   * Offered only on a machine somebody can actually decide about. One a
   * worker is driving is refused by the engine, so a button here would only
   * produce a refusal. */
  const skipBtn = (['NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'].includes(doc.state)
    && canOperate())
    ? `<button type="button" class="btn ghost" id="skip-btn">${esc(UX_ACT.skipVm)}</button>` : '';
  // RETRY-SERIES-1: beside Retry, one button per other series the machine may
  // take. Filled once the service answers, so a machine with no other series
  // shows none.
  // ROLLBACK-SIZE-REFUSED-SERIES-1: and a machine whose rollback Azure refused
  // its original size - another series is its way forward, from the first
  // safety copy (the engine takes the same stop, Set-VmfMachineTarget).
  const retrySlot = ((doc.state === 'FAILED_ROLLED_BACK' && offer.retry) ||
      (doc.state === 'FAILED_NEEDS_ATTENTION' && lastStopEntry(doc)?.reasonCode === 'rollbackSizeRefused' && canOperate()))
    ? '<span id="retryseries-slot" style="display:contents"></span>' : '';
  // POWER-ONLY-CHANGED-1: Return to the power state, while it is owed and no
  // job works on the machine - said on the screen, with the power state.
  const owedPower = (powerOwed(doc) && !VmfHelp.machineAtWork(doc.state)) ? powerOwed(doc) : null;
  const powerBackLine = owedPower ? `<p class="muted" style="margin:6px 0">${esc(UX_ACT.powerBackLine.replace('{power}', powerName(owedPower)))}</p>` : '';
  const powerBackBtn = (owedPower && canOperate())
    ? `<button type="button" class="btn" id="powerback-btn">${esc(UX_ACT.powerBack)}</button>` : '';
  // VOLUMES-RESTORE-MIGRATED-1: Check the volumes, while the record owes the
  // check - said on the screen where no stop card says what to do.
  const volumesOffer = volumesCheckOffer(doc, canOperate(), putBack.busy);
  const volumesStarted = volumesStartedLine(doc);
  const volumesCheckLine = (volumesStarted ? `<p class="muted" style="margin:6px 0">${esc(volumesStarted)}</p>` : '')
    + (volumesOffer.line ? `<p class="muted" style="margin:6px 0">${esc(volumesOffer.line)}</p>` : '');
  const volumesCheckBtn = volumesOffer.button
    ? `<button type="button" class="btn" id="volumescheck-btn">${esc(UX_ACT.volumesCheck)}</button>` : '';
  const actionRow = (finishBtn || decideBtn || resolveBtn || restoreBtn || skipBtn || powerBackBtn || volumesCheckBtn)
    ? `<p style="display:flex;gap:8px;flex-wrap:wrap">${finishBtn}${powerBackBtn}${volumesCheckBtn}${decideBtn}${resolveBtn}${retrySlot}${restoreBtn}${skipBtn}</p>` : '';
  // If it HAS been put back, say so prominently - the wave row alone would
  // still read "Migrated".
  // RESTORE-EARLIER-DELETE-1: Delete these disks, under the list of the
  // earlier managed disks, for an operator, while no job works on the
  // machine - the service and the engine refuse it then too.
  // MADE-DISK-DELETE-1: both deletes of disks on the panel are the one
  // slide-out (diskDeleteHtml), for an operator, while no job works on the
  // machine and no refused swap waits - the engine refuses them then.
  const diskDeleteFree = () => !doc.swapPending && canOperate() && !putBack.busy && !VmfHelp.machineAtWork(doc.state);
  const earlierN = restoreEarlierDisks(doc.restore).length;
  const earlierDeleteBtn = (earlierN && diskDeleteFree()) ? diskDeleteHtml('earlier', vmId, earlierN) : '';
  const restoredNote = restoredNoteHtml(doc.restore, doc).replace('<span id="earlierdelete-slot"></span>', () => earlierDeleteBtn);
  // MADE-DISK-SHOWN-1: the disks a put-back made that the record says nothing uses.
  // MADE-DISK-DELETE-1: not while a restore or a finish holds them (restoreRuns,
  // finishRuns, restoreStopped): the engine refuses then.
  const madeRows = madeDiskRows(doc);
  const madeDeleteBtn = (madeRows.length && ['due', 'waits'].includes(madeRows[0].status) && diskDeleteFree()) ? diskDeleteHtml('made', vmId, madeRows.length) : '';
  const madeDisks = madeDisksHtml(doc, madeHelpOpen.has(vmId)).replace('<span id="madedelete-slot"></span>', () => madeDeleteBtn);
  // ROLLBACK-ORIGINALS-LEFT-1: the disks a rollback swapped off, under the
  // restore box, with the same delete by the same rule.
  const originalRows = rollbackOriginalDisks(doc);
  const originalDeleteBtn = (originalRows.length && diskDeleteFree()) ? diskDeleteHtml('original', vmId, originalRows.length, name) : '';
  const originalDisks = rollbackOriginalsHtml(doc, name).replace('<span id="originaldelete-slot"></span>', () => originalDeleteBtn);
  // RESTORE-PANEL-TIMELINE-1: the main block says what the machine is NOW,
  // as the header does. While a restore or Finish runs, no stop box: the
  // stop before it is in the list. After a restore that did not finish, its
  // end takes the place of the stop box.
  const status = machineStatusOf(vmId, doc);
  const vmKey = VmfHelp.idKey(vmId);
  const restoreEnd = restoreEndAfter(doc, latestEvents.filter(e => e && VmfHelp.idKey(e.vmId) === vmKey));
  const stopBox = ['restoring', 'finishing'].includes(status.key) ? ''
    : restoreEnd ? restoreEndCard(restoreEnd) : whyStoppedCard(doc);
  const html = `
    <h3 class="mono">${esc(name)}</h3>
    <p>${machinePill(doc, machineStatusOf(vmId, doc), { awaits: awaitsServiceCheck(doc, latestEvents), hold: retryHoldOf(doc, entry?.wave, latestEvents), braked: latestHalted })} ${entry ? `<span class="muted">&middot; ${esc(UX_PATH[entry.path] ?? UX_MISC.notMoved)} &middot; wave ${esc(entry.wave)}</span>` : ''}</p>
    ${placementLine}
    ${notMovedHtml(entry)}
    ${stopBox}
    ${heldLine}
    ${putBackBusyLine}
    ${midMoveLine}
    ${powerBackLine}
    ${volumesCheckLine}
    ${actionRow}
    ${restoredNote}
    ${originalDisks}
    ${madeDisks}
    ${cp}
    <h4>What happened, newest first</h4><ul class="timeline">${hist}</ul>
    <h4>Work done inside the machine</h4>
    <table><tbody>${guest || '<tr><td class="muted">none yet</td></tr>'}</tbody></table>
    <div id="ev-holder"></div>`;
  // A redraw with nothing new draws nothing, and wires nothing again.
  if (!drawDrill(html, vmId, keep)) { return; }
  // DIALOG-STALE-1: a redraw from the refresh is a new state document - a
  // dialog this panel opened says so. A selected row cannot have one open.
  markDialogStale(vmId, doc);
  $('#resolve-btn')?.addEventListener('click', () => panelDialog(vmId, () => askResolve(vmId, doc)));
  // MACHINE-PANEL-STALE-1: a redraw with the same plan entry and state uses
  // the answer it already has - no service call, and the buttons are there
  // at once, so the focus can go back to one of them.
  fillRetrySeries(vmId, JSON.stringify([currentRun, vmId, entry ?? null, doc.state]), keep, !!sizeRefusedStop(doc));
  $('#decide-btn')?.addEventListener('click', () => panelDialog(vmId, () => askDecide(vmId, lastGuidance, doc)));
  $('#restore-btn')?.addEventListener('click', () => panelDialog(vmId, () => askRestore(vmId, doc, restoreOntoTarget(doc, entry))));
  $('#finish-btn')?.addEventListener('click', () => panelDialog(vmId, () => askFinish(vmId, doc)));
  $('#powerback-btn')?.addEventListener('click', () => panelDialog(vmId, () => askPowerBack(vmId, doc)));
  $('#volumescheck-btn')?.addEventListener('click', () => panelDialog(vmId, () => askVolumesCheck(vmId)));
  // MADE-DISK-DELETE-1: the slide-out deletes of disks: click 1, Cancel, click 2.
  for (const kind of ['earlier', 'made', 'original']) {
    $(`#${kind}delete-btn`)?.addEventListener('click', () => toggleDiskDelete(vmId, kind));
    $(`#${kind}delete-cancel`)?.addEventListener('click', () => closeDiskDelete());
    $(`#${kind}delete-go`)?.addEventListener('click', () => confirmDiskDelete(vmId, kind));
  }
  $('#madehelp-btn')?.addEventListener('click', () => { toggleMadeHelp(vmId); });
  $('#skip-btn')?.addEventListener('click', () => panelDialog(vmId, () => askSkipVm(vmId, doc)));
  $('#drill-body').querySelectorAll('.evlink').forEach(a => a.addEventListener('click', async () => {
    $('#ev-holder').innerHTML = '<p class="muted">loading&hellip;</p>';
    // MACHINE-PANEL-STALE-1: the refresh can draw the panel again while this
    // loads, so the answer goes into the holder on the screen - and only while
    // the panel still shows this machine.
    const put = (h) => { const holder = $('#ev-holder'); if (holder && drillVmId === vmId) { holder.innerHTML = h; return holder; } return null; };
    try {
      const txt = await source.readText(currentRun, a.dataset.ev);
      put(`<h4>Captured evidence <span class="tech">${esc(a.dataset.ev)}</span></h4><pre class="evidence">${esc(txt ?? '(not found)')}</pre>`)
        ?.scrollIntoView({ behavior: 'smooth' });
    } catch (e) { put(`<p class="muted">could not load evidence: ${esc(e.message)}</p>`); }
  }));
  refocusDrill();
  revealDiskDelete();
}

/* The card of the last restore on the machine panel: which copy, when, by
 * whom, and whether the new disks have new names. A restore with new names
 * kept the disks the machine had, detached (RESTORE-DIALOG-WORDS-1): the card
 * lists each one from the record of the restore - its operating system disk
 * (retainedDiskId) and each data disk it swapped - so a person can find them,
 * and knows they cost money. A restore that kept the names deleted them, and
 * lists none. '' with no restore.
 * RESTORE-EARLIER-DELETE-1: the list is restoreEarlierDisks, and under it a
 * slot (#earlierdelete-slot) that openDrill fills with Delete these disks for
 * an operator, when no job works on the machine. */
function restoredNoteHtml(r, doc) {
  if (!r) { return ''; }
  // STATUS-WORDS-1: while the restore waits for Finish the restore, the box
  // says it did not finish, and makes no claim about where the machine is.
  const left = doc?.swapPending?.kind === 'restore';
  const fromCopy = left ? UX_ACT.finishDesc
    : r.fromCopy === 'pristine' ? UX_ACT.restoredFromPristine : r.fromCopy === 'prepared' ? UX_ACT.restoredFromPrepared : '';
  const earlier = restoreEarlierDisks(r)
    .map(d => [d.lun === null ? UX_ACT.restoredEarlierOs : UX_ACT.restoredEarlierLun.replace('{lun}', String(d.lun)), d.name]);
  return `<div class="card" style="margin:10px 0;border-color:var(--bad);background:var(--bad-soft)">
      <div class="cardbody">
        <b>${esc(left ? UX_ACT.restoreNotDone : UX_ACT.restoredFrom)}</b>
        <div class="muted">${esc(UX_ACT.restoredWhen)} ${agoSpan(r.restoredUtc)} &middot; ${esc(UX_ACT.restoredBy)} ${esc(r.restoredBy ?? '')}${r.note ? ' &middot; ' + esc(r.note) : ''}</div>
        ${fromCopy ? `<div class="muted" style="margin-top:6px">${esc(fromCopy)}</div>` : ''}
        <div class="muted" style="margin-top:6px">${esc(UX_ACT.restoredDisk)} <span class="mono">${esc(r.newDiskName ?? '')}</span>
          ${r.diskIdChanged ? esc(UX_ACT.restoredIdChanged) : esc(UX_ACT.restoredIdSame)}</div>
        ${(r.dataDisks ?? []).length ? `<div class="muted" style="margin-top:6px">${esc(UX_ACT.restoredDataDisks)} <span class="mono">${esc(r.dataDisks.map(d => d.newDiskName).join(', '))}</span>
          ${r.diskIdChanged ? esc(UX_ACT.restoredDataIdChanged) : esc(UX_ACT.restoredDataIdSame)}</div>` : ''}
        ${(r.dataDisksKept ?? []).length ? `<div class="muted" style="margin-top:6px">${esc(UX_ACT.restoredDataKept)} <span class="mono">${esc(r.dataDisksKept.map(d => d.name).join(', '))}</span></div>` : ''}
        ${earlier.length ? `<div style="margin-top:8px"><b>${esc(UX_ACT.restoredEarlier)}</b>
          <div class="muted">${esc(UX_ACT.restoredEarlierWhat)}</div>
          <table><tbody>${earlier.map(([where, name]) => `<tr><td>${esc(where)}</td><td class="mono">${esc(name)}</td></tr>`).join('')}</tbody></table>
          ${left ? '' : '<span id="earlierdelete-slot"></span>'}</div>` : ''}
      </div></div>`;
}
/* RESTORE-EARLIER-DELETE-1: the earlier managed disks of a restore that kept
 * them and are not deleted yet - ONE rule with the engine
 * (Get-VmfRestoreEarlierDisks), held to tests/fixtures/restore-earlier-disks.json
 * in both languages. Only a restore with diskIdChanged: retainedDiskId, then
 * each dataDisks[].previousDiskId; never a disk the record says the machine
 * runs on now (newDiskId), never one on earlierDisksDeleted, one disk once.
 * Resource IDs compare in any letter case. Each is { diskId, name, lun }, with
 * lun null for the operating system disk. */
function restoreEarlierDisks(r) {
  if (!r || !r.diskIdChanged) { return []; }
  const key = (id) => String(id ?? '').toLowerCase();
  const leaf = (id) => String(id).split('/').pop();
  const data = (r.dataDisks ?? []).filter(Boolean);
  const skip = new Set([r.newDiskId, ...data.map(d => d.newDiskId), ...(r.earlierDisksDeleted ?? []).filter(Boolean).map(x => x.diskId)]
    .filter(Boolean).map(key));
  const found = [];
  const take = (id, name, lun) => {
    if (!id || skip.has(key(id))) { return; }
    skip.add(key(id));
    found.push({ diskId: id, name: name || leaf(id), lun });
  };
  take(r.retainedDiskId, r.previousDiskName, null);
  for (const d of data) { take(d.previousDiskId, d.previousDiskName, Number(d.lun)); }
  return found;
}
/* ROLLBACK-ORIGINALS-LEFT-1: the disk ids this machine runs on, as its record
 * knows them - the engine's Get-VmfDisksInUseByRecord, step for step: the
 * captured disks, then each rollback and restore from a copy that
 * made disks, oldest first, so the newest names what is on each place now. */
function recordDiskIdsInUse(doc) {
  const vm = doc?.captured?.vmConfig ?? {};
  let os = vm.osDisk?.managedDiskId ?? '';
  const data = new Map([].concat(vm.dataDisks ?? []).filter(Boolean).map(d => [Number(d.lun), d.managedDiskId ?? '']));
  const at = (s) => { const t = s ? Date.parse(s) : NaN; return Number.isNaN(t) ? -Infinity : t; };
  const rb = doc?.rollback, rs = doc?.restore;
  const made = [
    rb && { at: at(rb.rolledBackUtc), os: rb.osDisk?.id || null, data: [].concat(rb.dataDisks ?? []).filter(Boolean).map(d => [d.lun, d.diskId]) },
    rs?.newDiskId && { at: at(rs.restoredUtc), os: rs.newDiskId, data: [].concat(rs.dataDisks ?? []).filter(Boolean).map(d => [d.lun, d.newDiskId]) },
  ].filter(Boolean).sort((a, b) => a.at - b.at);
  for (const m of made) {
    if (m.os) { os = m.os; }
    for (const [lun, id] of m.data) { data.set(Number(lun), id ?? ''); }
  }
  return [os, ...data.values()].filter(Boolean).map(String);
}
/* ROLLBACK-ORIGINALS-LEFT-1: the original disks a rollback left that are not
 * deleted - ONE rule with the engine (Get-VmfRollbackOriginalDisks), held to
 * tests/fixtures/rollback-originals.json in both languages. The record is
 * rollbackOriginals, which every writer of the rollback record writes in the
 * same write (OLD-STATE-READERS-PAGE-1: nothing comes from the captures). Never a disk marked
 * deleted, one the record says the machine uses now, an earlier disk of a
 * restore (its own part lists it), or one disk twice. Resource IDs compare in
 * any letter case. Each is { diskId, name, lun, detachedUtc }, lun null for
 * the operating system disk. */
function rollbackOriginalDisks(doc) {
  if (!doc) { return []; }
  const key = (id) => String(id ?? '').toLowerCase();
  const leaf = (id) => String(id).split('/').pop();
  const entries = [].concat(doc.rollbackOriginals ?? []).filter(e => e && e.diskId);
  if (!entries.length) { return []; }
  const skip = new Set(recordDiskIdsInUse(doc).map(key));
  const rs = doc.restore;
  if (rs) {
    for (const id of [rs.retainedDiskId, ...[].concat(rs.dataDisks ?? []).filter(Boolean).map(d => d.previousDiskId)]) {
      if (id) { skip.add(key(id)); }
    }
  }
  const found = [];
  for (const e of entries) {
    if (e.deletedUtc || skip.has(key(e.diskId))) { continue; }
    skip.add(key(e.diskId));
    found.push({ diskId: String(e.diskId), name: e.diskName || leaf(e.diskId),
      lun: (e.lun === null || e.lun === undefined) ? null : Number(e.lun), detachedUtc: e.detachedUtc ?? null });
  }
  return found;
}
/* ROLLBACK-ORIGINALS-LEFT-1: the part on the machine's panel, in the words
 * approved 2026-11-08 - a table (Disk, Used as, Detached), under it a
 * slot (#originaldelete-slot) that openDrill fills with Delete these disks
 * (diskDeleteHtml) for an operator, and what happens next. '' when there is no
 * such disk. vm is the machine's name. */
function rollbackOriginalsHtml(doc, vm) {
  const rows = rollbackOriginalDisks(doc);
  if (!rows.length) { return ''; }
  const heads = [UX_ACT.madeColDisk, UX_ACT.originalColUsedAs, UX_ACT.originalColDetached];
  return `<div class="card" style="margin:10px 0"><div class="cardbody">
      <b>${esc(UX_ACT.originalTitle)}</b>
      <div class="muted">${esc(UX_ACT.originalWhat.replace('{vm}', () => String(vm ?? '')))}</div>
      <table><thead><tr>${heads.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(r => `<tr><td class="mono">${esc(r.name)}</td><td>${
        esc(r.lun === null ? UX_ACT.restoredEarlierOs : UX_ACT.restoredEarlierLun.replace('{lun}', String(r.lun)))}</td><td>${r.detachedUtc ? agoSpan(r.detachedUtc) : ''}</td></tr>`).join('')}</tbody></table>
      <span id="originaldelete-slot"></span>
      <div style="margin-top:6px"><b>${esc(UX_ACT.madeNext)}:</b> ${esc(UX_ACT.originalKept)}</div>
    </div></div>`;
}/* MADE-DISK-DELETE-1: the two-step delete under a list of disks on the
 * machine's panel - ONE control for Delete these disks under Its earlier
 * managed disks (RESTORE-EARLIER-DELETE-1, engine operation deleteearlier) and
 * Delete these disks now under Managed disks made from the safety copies
 * (deletemade), so both look and work the same. Design A, approved
 * 2026-11-08: a quiet text link with a chevron; click 1 slides
 * open, in place, the warning, a red Delete {n} disks and Cancel; click 2
 * starts the engine operation. No pop-up dialog, and nothing shows until it
 * is clicked. Cancel, the link again, and Escape close it (rule 11; Escape
 * closes it before the panel). The warning is the product's in-page question
 * row (askrow, POPUP-1). It is drawn from diskDelete, not added to the screen
 * the way VmfHelp.confirmInPlace adds it: the panel draws itself again on the
 * refresh (MACHINE-PANEL-STALE-1), and a row added by hand would go with that
 * draw while its Escape listener stayed. Each entry names the engine
 * operation and the UX_ACT keys of its words. */
const DISK_DELETE = {
  earlier: { op: 'deleteearlier', label: 'restoredEarlierDelete', ask: 'restoredEarlierDeleteAsk', askOne: 'restoredEarlierDeleteAskOne', done: 'restoredEarlierDeleteDone' },
  made: { op: 'deletemade', label: 'madeDelete', ask: 'madeDeleteAsk', askOne: 'madeDeleteAskOne', done: 'madeDeleteDone' },
  // ROLLBACK-ORIGINALS-LEFT-1: the original disks of a rollback - the same
  // engine operation as the earlier disks of a restore, with the set it deletes.
  original: { op: 'deleteearlier', set: 'rollback', label: 'restoredEarlierDelete', ask: 'originalDeleteAsk', askOne: 'originalDeleteAskOne', done: 'restoredEarlierDeleteDone' },
};
/* The open slide-out, or null: { vmId, kind, sending, err }. One at a time,
 * and it stays open over the refresh. */
let diskDelete = null;
/* The link, and under it the open slide-out, for n disks. vm is the name
 * of the machine, for a warning that names it ({vm}). */
function diskDeleteHtml(kind, vmId, n, vm) {
  const k = DISK_DELETE[kind];
  const open = Boolean(diskDelete && diskDelete.vmId === vmId && diskDelete.kind === kind);
  const link = `<button type="button" class="linkbtn diskdel-link" id="${kind}delete-btn" aria-expanded="${open}" aria-controls="${kind}delete-slide">${esc(UX_ACT[k.label])} <span class="chev" aria-hidden="true">&rsaquo;</span></button>`;
  if (!open) { return `<div class="diskdel">${link}</div>`; }
  const ask = (n === 1 ? UX_ACT[k.askOne] : UX_ACT[k.ask].replace('{n}', String(n))).replace('{vm}', () => String(vm ?? ''));
  const go = diskDelete.sending ? UX_ACT.working : n === 1 ? UX_ACT.diskDeleteGoOne : UX_ACT.diskDeleteGo.replace('{n}', String(n));
  return `<div class="diskdel">${link}
      <div class="askrow inrow askblock diskdel-slide" id="${kind}delete-slide" role="group" aria-label="${esc(UX_ACT[k.label])}">
        <span class="ask">${esc(ask)}</span>
        ${diskDelete.err ? `<span class="muted" role="alert">${esc(diskDelete.err)}</span>` : ''}
        <button type="button" class="btn small danger-fill" id="${kind}delete-go"${diskDelete.sending ? ' disabled aria-busy="true"' : ''}>${esc(go)}</button>
        <button type="button" class="btn small ghost" id="${kind}delete-cancel">${esc(UX_ACT.cancel)}</button>
      </div></div>`;
}
/* Click 1: open the slide-out of this delete, or close it when it is open. */
function toggleDiskDelete(vmId, kind) {
  const open = Boolean(diskDelete && diskDelete.vmId === vmId && diskDelete.kind === kind);
  diskDelete = open ? null : { vmId, kind, sending: false, err: '', reveal: true };
  refreshDrill();
}
/* CONFIRM-DIALOG-OUT-OF-VIEW-1: the panel draw that shows a slide-out just
 * opened brings it into view, the nearest way, one time - a link near the
 * bottom of the panel's view opened it below the view, and the click seemed
 * to do nothing. A later draw (the refresh) does not move the panel again. */
function revealDiskDelete() {
  if (!diskDelete || !diskDelete.reveal) { return; }
  diskDelete.reveal = false;
  $(`#${diskDelete.kind}delete-slide`)?.scrollIntoView({ block: 'nearest' });
}
/* Cancel and Escape: close it. Nothing was sent. */
function closeDiskDelete() {
  diskDelete = null;
  refreshDrill();
}
/* Click 2: start the engine operation for the machine - the engine reads
 * which disks from the record. Only the slide-out that is open, and once. A
 * refusal stays in the slide-out, in the words of the service. */
async function confirmDiskDelete(vmId, kind) {
  const mine = diskDelete;
  if (!mine || mine.vmId !== vmId || mine.kind !== kind || mine.sending) { return; }
  const k = DISK_DELETE[kind];
  mine.sending = true;
  mine.err = '';
  refreshDrill();
  try {
    await apiFetch(`runs/${runSeg()}/engine/${k.op}`, k.set ? { vmId, diskSet: k.set } : { vmId });
    if (diskDelete === mine) { diskDelete = null; }
    $('#err').style.display = 'none';
    $('#ok').textContent = UX_ACT[k.done];
    $('#ok').style.display = 'block';
    setTimeout(() => { $('#ok').style.display = 'none'; }, 12000);
    followThrough();
  } catch (e) {
    mine.sending = false;
    mine.err = VmfHelp.explainAction(e);
  }
  refreshDrill();
}
/* MADE-DISK-SHOWN-1: every id the record of a machine names as a disk it runs
 * on or ran on - the engine's Get-VmfRecordedMachineDiskIds, step for step: in
 * captured, rollback and restore, each string field whose name ends
 * in "id" or "ids", and each string in a list whose name ends in "ids"; no
 * deeper than 12 levels. One more id kept is never a disk lost. */
function recordedMachineDiskIds(doc) {
  const found = [];
  const walk = (node, depth) => {
    if (node === null || node === undefined || depth > 12 || typeof node !== 'object') { return; }
    if (Array.isArray(node)) { for (const i of node) { walk(i, depth + 1); } return; }
    for (const [name, value] of Object.entries(node)) {
      if (typeof value === 'string') {
        if (/ids?$/i.test(name) && value) { found.push(value); }
        continue;
      }
      if (/ids$/i.test(name) && Array.isArray(value)) {
        for (const v of value) { if (typeof v === 'string' && v) { found.push(v); } }
        continue;
      }
      walk(value, depth + 1);
    }
  };
  // ROLLBACK-ORIGINALS-LEFT-1: and the original disks a rollback swapped off.
  for (const name of ['captured', 'rollback', 'restore', 'rollbackOriginals']) { walk(doc ? doc[name] : null, 0); }
  return found;
}
/* MADE-DISK-SHOWN-1: the managed disks a rollback (rollbackDisksDuringRollback) and Restore
 * this machine (restoreDisks) made
 * from a safety copy that the record says nothing uses, and what the daily
 * cleanup does with each. ONE rule with the engine, held to
 * tests/fixtures/made-disks-shown.json in both languages:
 *   - the disks are Get-VmfDeletableMadeDisks: not marked used or deleted,
 *     not one a refused swap waits to put on the machine or swapped
 *     (swapPending), not one the record says the machine runs on or ran on;
 *     resource IDs compare in any letter case;
 *   - status: restoreRuns or finishRuns while a job has not ended, and
 *     restoreStopped while one gave up or a later one holds
 *     (Test-VmfPutBackJobHolds); else due once the move has ended (MIGRATED,
 *     FAILED_ROLLED_BACK, SKIPPED: Get-VmfDueMadeDisks), and waits before.
 * The page cannot read Azure: the cleanup reads each disk first and keeps an
 * attached one, which the (?) says. Each row is { diskId, name, lun, list,
 * madeUtc, status }, lun null for the operating system disk. */
function madeDiskRows(doc) {
  if (!doc) { return []; }
  const key = (id) => String(id ?? '').toLowerCase();
  const pending = doc.swapPending || {};
  const waits = new Set([...[].concat(pending.swaps ?? []), ...[].concat(pending.swapped ?? [])]
    .filter(Boolean).map(s => key(s.diskId)).filter(Boolean));
  const onRecord = new Set(recordedMachineDiskIds(doc).map(key));
  const job = doc.putBackJob;
  const status = (job && !job.ended) ? (job.kind === 'finish' ? 'finishRuns' : 'restoreRuns')
    : (job && (job.ended.reason === 'gaveUp' || job.held)) ? 'restoreStopped'
    : ['MIGRATED', 'FAILED_ROLLED_BACK', 'SKIPPED'].includes(doc.state) ? 'due' : 'waits';
  const rows = [];
  for (const list of ['rollbackDisksDuringRollback', 'restoreDisks']) {
    for (const d of [].concat(doc[list] ?? [])) {
      if (!d || !d.diskId || d.usedUtc || d.deletedUtc) { continue; }
      if (waits.has(key(d.diskId)) || onRecord.has(key(d.diskId))) { continue; }
      rows.push({ diskId: String(d.diskId), name: d.diskName || String(d.diskId).split('/').pop(),
        lun: (d.lun === null || d.lun === undefined) ? null : Number(d.lun), list, madeUtc: d.madeUtc || null, status });
    }
  }
  return rows;
}
/* MADE-DISK-SHOWN-1: the box on the machine's panel - a table, one row for
 * each disk, and what happens next under it, in the words of the Safety
 * copies card. What happens next is decided for the machine, so it is the
 * same for every disk: one line says it once (a column said it again on each
 * row of a narrow panel). The why is behind a (?): one button, two states
 * (? and Close), and Escape closes it before the panel (rule 11).
 * MADE-DISK-DELETE-1: right under the table, a slot (#madedelete-slot) that
 * openDrill fills with Delete these disks now (diskDeleteHtml) for an
 * operator, where the engine deletes them. '' when there is no such disk. */
function madeDisksHtml(doc, helpOpen) {
  const rows = madeDiskRows(doc);
  if (!rows.length) { return ''; }
  const by = { rollbackDisksDuringRollback: UX_ACT.madeByRollback, restoreDisks: UX_ACT.madeByRestore };
  const next = { due: UX_ACT.madeDue, waits: UX_ACT.madeWaits, restoreRuns: UX_COPIES.statusRestoreRuns,
    finishRuns: UX_COPIES.statusFinishRuns, restoreStopped: UX_COPIES.statusRestoreStopped };
  const heads = [UX_ACT.madeColDisk, UX_ACT.madeColBy, UX_ACT.madeColFor, UX_ACT.madeColMade];
  return `<div class="card" style="margin:10px 0"><div class="cardbody">
      <b>${esc(UX_ACT.madeTitle)}</b> <button type="button" class="btn small ghost" id="madehelp-btn" aria-expanded="${helpOpen ? 'true' : 'false'}" aria-controls="madehelp-text" aria-label="${esc(helpOpen ? UX_ACT.close : UX_ACT.madeHelpTip)}" title="${esc(UX_ACT.madeHelpTip)}">${helpOpen ? esc(UX_ACT.close) : '?'}</button>
      <div class="muted">${esc(UX_ACT.madeWhat)}</div>
      <table><thead><tr>${heads.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(r => `<tr><td class="mono">${esc(r.name)}</td><td>${esc(by[r.list])}</td><td>${
        esc(r.lun === null ? UX_ACT.restoredEarlierOs : UX_ACT.restoredEarlierLun.replace('{lun}', String(r.lun)))}</td><td>${r.madeUtc ? agoSpan(r.madeUtc) : ''}</td></tr>`).join('')}</tbody></table>
      <span id="madedelete-slot"></span>
      <div style="margin-top:6px"><b>${esc(UX_ACT.madeNext)}:</b> ${esc(next[rows[0].status])}</div>
      ${helpOpen ? `<div class="muted" id="madehelp-text" style="margin-top:4px">${esc(UX_ACT.madeHelp)}</div>` : ''}
    </div></div>`;
}
/* MADE-DISK-SHOWN-1: open or close the (?) of one machine's made disks. The
 * machines whose (?) is open stay open over the refresh. */
const madeHelpOpen = new Set();
function toggleMadeHelp(vmId) {
  if (madeHelpOpen.has(vmId)) { madeHelpOpen.delete(vmId); } else { madeHelpOpen.add(vmId); }
  refreshDrill();
}
/* MACHINE-PANEL-STALE-1: put the panel's markup on the screen, and open it.
 * A selected row always draws. A redraw (keep, only from refreshDrill, of the
 * machine already shown) does not draw when the markup is the same apart
 * from its "... ago" texts (drillKey): it writes those texts again and stops,
 * so the fifteen-second refresh does not rebuild a panel somebody is reading.
 * When it does draw, it keeps what the person had: the evidence they opened,
 * the scroll position, and the focus - refocusDrill puts it on the same
 * button if it is still there, else on the panel's close button, never the
 * page. A focus outside the panel is not touched.
 * A dialog opened from the panel is #modal-back, outside it, and no draw here
 * writes it - so its typed note and its focus survive (rule 11 is unchanged:
 * the dialog's Cancel and Escape, the panel's close button and Escape).
 * Returns false when it drew nothing. */
function drawDrill(html, vmId, keep) {
  const panel = $('#drill'), body = $('#drill-body');
  const key = drillKey(html);
  if (keep && key === drillDrawn) {
    body.querySelectorAll('[data-ago]').forEach(s => { s.textContent = ago(s.dataset.ago); });
    return false;
  }
  const evidence = keep ? ($('#ev-holder')?.innerHTML ?? '') : '';
  const top = panel.scrollTop;
  const active = document.activeElement;
  const hadFocus = keep && Boolean(active) && body.contains(active);
  drillFocusId = hadFocus ? (active.id || '') : null;
  body.innerHTML = html;
  drillVmId = vmId; drillRun = currentRun; drillDrawn = key;
  panel.classList.add('open');
  if (keep) {
    const holder = $('#ev-holder');
    if (holder && evidence) { holder.innerHTML = evidence; }
    panel.scrollTop = top;
  }
  return true;
}
/* Put the focus back after a redraw, once the panel's controls are wired. */
function refocusDrill() {
  if (drillFocusId === null) { return; }
  const id = drillFocusId;
  drillFocusId = null;
  ((id && document.getElementById(id)) || $('#drill').querySelector('.close'))?.focus({ preventScroll: true });
}

/* MACHINE-PANEL-STALE-1: the refresh's part. The open panel is drawn again
 * from the state document the refresh just read - the pill, the stop box, the
 * buttons and the timeline - and stays open. A panel of another run is
 * closed, because the machine it shows is not in the run on the screen.
 * Returns true when it asked for a redraw. */
function refreshDrill() {
  if (!drillVmId || !$('#drill').classList.contains('open')) { return false; }
  if (drillRun !== currentRun) { closeDrill(); return false; }
  const doc = allVms.find(v => v.vmId === drillVmId);
  const entry = planDoc?.entries?.find(e => e.vmId === drillVmId);
  // NOT-IN-WAVE-QUEUED-1: and so is a panel of a machine that left the run -
  // in no wave, never started. Its row is gone (waveGroups).
  if (VmfHelp.outsideRun(entry, doc)) { closeDrill(); return false; }
  openDrill(doc, entry, drillVmId, { keep: true });
  return true;
}
// Written on more than one line, so tests/js can lift it alone.
function closeDrill() {
  $('#drill').classList.remove('open');
  // MADE-DISK-DELETE-1 review: nothing opens unless it is clicked. A closed
  // panel forgets its open slide-out delete of disks and its open (?), so the
  // panel opened again shows only the links - never a delete one click away.
  diskDelete = null;
  madeHelpOpen.clear();
}
/* The one document click listener: a click outside an open panel closes it.
 * DISK-DELETE-CLICK-1 (lab install, 2026-11-09): the button "Delete these disks" closed
 * the whole machine panel. The control's own listener runs first and draws
 * the panel body again, so here the click's target has left the page, and
 * target.closest('#drill') of a detached node is null - the click read as
 * outside. So "inside" is read from the click's path, which the browser fixes
 * before any listener runs: a node later removed is still in it. A click
 * that really was outside, and that redraws its own part, still closes the
 * panel. */
function dismissOnOutsideClick(e) {
  const at = e.composedPath();
  const inside = (sel) => at.some(n => typeof n.matches === 'function' && n.matches(sel));
  if (!inside('#run-panel')) {
    $('#run-panel').classList.remove('open');
    $('#run-current').setAttribute('aria-expanded', 'false');
  }
  if (!inside('#act-panel')) {
    $('#act-panel').classList.remove('open');
    $('#act-menu-btn').setAttribute('aria-expanded', 'false');
  }
  // The detail panel dismisses like any panel: click anywhere outside it
  // It used to appear without explanation, and only the small close
  // button dismissed it.
  if ($('#drill').classList.contains('open') &&
      !inside('#drill') && !inside('tr.vm-row') && !inside('#modal-back')) {
    closeDrill();
  }
}

// ---------- refresh loop ----------
let currentRun = null, lastUpdated = null, nextRefresh = 0;
// PLANRUN-1: the plan's sign-off, whether it is current, and what the signed-off
// plan is doing next (the timer's plan-run.json).
let planSignoff = null, planSignoffCurrent = false, planRunStatus = null;
// FIRSTRUN-1: no forced wizard - it would be a
// thing to click past, and everything it could set up happens OUTSIDE this app,
// in Azure, where a wizard cannot do it for anybody. What an empty app owes a
// new operator is not instructions but an ANSWER: here are the three things
// that must be true before this works, and here is whether each one is true FOR
// YOU. Checkable beats instructional, and it fails loudly for the person who
// deployed the platform and never granted themselves a role - which is the
// actual first-run failure, and one a wizard would have sailed straight past.
async function renderFirstRun() {
  const el = $('#waves');
  const signedIn = Boolean(account) || DEMO_MODE;
  const hasAnyRole = DEMO_MODE || myRoles.length > 0;
  // The store check is the one that cannot be answered from the token: try to
  // read, and let the failure say which failure it is.
  let storeOk = DEMO_MODE, storeWhy = '';
  if (!DEMO_MODE) {
    // STORE-READ-1: no 403 special case any more. A refusal used to mean the
    // person held the app role and not the Azure one; those are one permission
    // now, and the role check above already answers it. What must NOT happen is
    // the raw error landing in the list - that is the `list : HTTP 403` fault
    // FAIL-TEXT-1 exists for - so the shared explainer says it in words.
    // PAGE-WAIT-1: the answer the run list just got, not a second listing.
    if (lastListError) { storeWhy = window.VmfHelp.explain(lastListError); }
    else { storeOk = true; }
  }
  const row = (ok, label, fix) =>
    `<li style="margin:0 0 10px;list-style:none;display:flex;gap:10px;align-items:flex-start">
       <span style="font-size:15px;line-height:1.2">${ok ? '&#9989;' : '&#10060;'}</span>
       <span><strong>${esc(label)}</strong>${ok ? '' : `<br><span class="muted">${esc(fix)}</span>`}</span></li>`;
  // .cardbody, like every other card on this page. Without it the text is a
  // direct child of .card, which has no padding and DOES have overflow:hidden -
  // so the copy started flush against the left edge and was cut off at the
  // right, rather than letting the text be cut off.
  el.innerHTML = `<div class="card"><div class="ch"><h2>${esc(UX_FIRST.title)}</h2></div>
    <div class="cardbody">
      <p class="muted" style="margin:0 0 14px">${esc(UX_FIRST.body)}</p>
      <ul style="margin:0;padding:0">
        ${row(signedIn, UX_FIRST.chkSignedIn, UX_FIRST.fixSignedIn)}
        ${row(hasAnyRole, UX_FIRST.chkRole, UX_FIRST.fixRole)}
        ${row(storeOk, UX_FIRST.chkStore, storeWhy || UX_FIRST.fixStore)}
      </ul>
      <p style="margin:14px 0 0">${signedIn && hasAnyRole && storeOk
        ? `<span class="muted">${esc(UX_FIRST.allGood)}</span>`
        : `<span class="muted">${esc(UX_FIRST.notYet)}</span>`}</p>
    </div></div>`;
}

/* WAIT-2: the run whose documents are painted right now.
 *
 * It decides whether the body is showing THIS run or something else - nothing
 * yet on a first load, or the run that was open before somebody switched. It
 * is set only after a successful read, so a read that fails does not leave the
 * page claiming to show a run it could not get. */
let showingRun = null;

/* Say what each region is reading, and leave nothing looking finished.
 *
 * Only ever called when the body is not already showing this run, so the
 * once-every-fifteen-seconds refresh never blanks a page somebody is reading.
 */
/* WAIT-3: the regions the waiting state fills. One list, so a region can never
 * be painted by one of the pair and left behind by the other. */
/* WAIT-3: ONE list, read by both halves.
 *
 * ONE list, and both halves read it. They used to be written out separately, which is a region painted by one
 * and left behind by the other waiting to happen - the defect shape that has
 * cost this page three fixes in two days. `cols` says a region is a table and
 * how wide, so a waiting row spans it; no `cols` is a line of text.
 *
 * The safety-copies width is READ from the header the page builds at render
 * time, rather than written down a second time here. */
function readingRegions() {
  return [
    { sel: '#waves', text: UX_MISC.readingWaves },
    // QUOTA-FAMILY-1: the width is read from the header, as the copies one
    // is - the reservation columns come and go. Six is the card without them.
    { sel: '#cap-table tbody', text: UX_MISC.readingCapacity,
      cols: $('#cap-head')?.children?.length || 6 },
    { sel: '#copies-table tbody', text: UX_MISC.readingCopies,
      cols: $('#copies-head')?.children?.length || 6 },
    { sel: '#event-table tbody', text: UX_MISC.readingActivity, cols: 3 },
  ];
}

/* CLICKS-LOST-1: every region a refresh of the run draws again (refreshRun),
 * and the open machine panel. A refresh waits while the person holds a
 * control in one of them. The search box above the waves is not one: a
 * refresh never replaces it, so typing there holds nothing. */
function runRegions() {
  return ['#kpis', '#run-actions', '#nextstep', '#found', '#waves', '#cap-table tbody', '#copies-table tbody',
    '#event-table tbody', '#drill-body'].map(s => $(s)).filter(Boolean);
}

/** Take the waiting state down, for a store that holds no run at all.
 *  DELETE-STALE-1: and EVERYTHING drawn for a run, not only the waiting rows.
 *  The run's own buttons, its "What happens next" card and its "Machines we
 *  found" line were left standing beside the empty-store card after a delete,
 *  still offering to delete the run that was gone. */
function clearReadingRun() {
  // MACHINE-PANEL-STALE-1: the panel of a machine in the run that is gone.
  closeDrill();
  $('#kpis').innerHTML = '';
  for (const sel of ['#run-actions', '#nextstep', '#found']) {
    const el = $(sel);
    if (el) { el.innerHTML = ''; }
  }
  showingRun = null;
  for (const region of readingRegions()) {
    const el = $(region.sel);
    if (el) { el.innerHTML = ''; }
  }
}

/** Say what each region is reading, and leave nothing looking finished. */
function showReadingRun() {
  $('#kpis').innerHTML = '';
  for (const region of readingRegions()) {
    const el = $(region.sel);
    if (!el) { continue; }
    el.innerHTML = region.cols
      ? VmfHelp.waitingRow(region.text, region.cols)
      : VmfHelp.waitingLine(region.text);
  }
}

/* PERF-MIGRATIONS-TICK-1: the reads of ONE tick, each sent once.
 *
 * The list and the open run both need the open run's run-status.json and
 * plan.json, and they run side by side. Each read them for itself, so the
 * open run's two documents went to the service twice every 15 seconds. One
 * reader is made per tick (and one for the first load, which is start()'s walk
 * and its first draw) and handed to both: the first to ask sends the read, the
 * second gets the same answer. A reader is never kept past its tick - the
 * next tick must read the store again, or the page stops refreshing.
 *
 * The plan is read versioned, because the run's sign-off is compared with
 * that version (PLANVER-2), and the list only needs the document.
 *
 * PAGE-LOAD-2: AND EACH HALF IS ONE CALL. MEASURED on the lab install: this
 * page sent about 185 calls when it opened and about 25 every 15 seconds - a
 * listing of each project, run.json, run-status.json and plan.json of each
 * run, then each document of the open run. Now the list is ONE call a tick
 * (`list`: the store listed down to a run's documents, with LIST_READS) and
 * the open run is ONE call (`run`: its folder, with RUN_READS). The readers
 * answer from them first (VmfHelp.heldJson, heldList, heldHas, heldText) and
 * ask the service only what they cannot say: unknown means ask. A call that
 * fails is null, and every read is made as before. The plan is never one of
 * them: it is read through store/blob with its version (PLANVER-2). */
// PAGE-LOAD-2: what the list draws, and what the open run draws. The plan is
// in neither: it is read with its version (PLANVER-2). At most 12 names.
// WAVE-RUNNING-LEASE-1: the leases too, so 'plan-*.json' names both
// plan-approval.json and plan-run.json (plan.json has no '-', so it is not read).
const LIST_READS = ['run.json', 'run-status.json'];
/* MIGRATIONS-LIST-READS-1: A TICK ASKS THE LIST ONLY FOR WHAT CAN CHANGE.
 *
 * MEASURED on the lab install, 2026-11-08: the list's call read 188 to 192
 * documents and took 1.5 to 14.2 s, every 15 seconds, and about half were
 * run.json - for runs whose kind the page already held (runKinds). A run's
 * kind never changes, so once the page knows the kind of every run the last
 * list held, the list names run-status.json only. A run that is new on a tick
 * is in the listing, and loadRuns reads its manifest alone, as it reads any
 * manifest the call did not hold. While any listed run's kind is not known -
 * before the first list, or a manifest the store refused - the list names
 * run.json again (unknown means ask). */
let listedRuns = null;   // the runs the last list held, or null before one was read
function listReads() {
  const known = Array.isArray(listedRuns) && listedRuns.every(r => runKinds.has(r));
  return known ? LIST_READS.filter(n => n !== 'run.json') : LIST_READS;
}
const RUN_READS = ['run-status.json', 'assessment.json', 'plan-*.json', 'leases/*.lease', 'halt.flag', 'acknowledgements/infrastructure-as-code.json', 'state/*.json', 'capacity/*.json', 'schedules/*.json', 'approvals/*.json', 'acceptances/*.json', 'logs/events*.jsonl'];
function tickReads() {
  const held = new Map();
  const once = (run, rel, read) => {
    const key = JSON.stringify([run, rel]);
    if (!held.has(key)) { held.set(key, read()); }
    return held.get(key);
  };
  const docs = (opts) => (DEMO_MODE ? Promise.resolve(null)
    : (async () => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, opts))().catch(() => null));
  return {
    list: () => once('', 'store/docs', () => docs({ depth: 3, read: listReads() })),
    run: (run) => once(run, 'store/docs', () => docs({ prefix: `${run}/`, depth: 2, read: RUN_READS })),
    /* `from` is the call the asker holds (or its promise). The first to ask
     * for a run's status decides where it comes from; both calls hold the
     * same document, read in the same tick. */
    status: (run, from) => once(run, 'run-status.json', async () => {
      const known = VmfHelp.heldJson(await from, `${run}/run-status.json`);
      return known ? known.value : source.readJson(run, 'run-status.json');
    }),
    plan: (run) => once(run, 'plan.json', async () => {
      const pv = await source.readVersioned(run, 'plan.json');
      // ?demo keeps its plan as an object, not as text with a version.
      const doc = pv && pv.text ? JSON.parse(pv.text) : (DEMO_MODE ? await source.readJson(run, 'plan.json') : null);
      return { pv, doc };
    }),
  };
}

/* MIGRATIONS-LIST-READS-1: ONE LOAD AT A TIME FOR THE CLOCK AND THE BUTTON.
 *
 * Nothing stopped a tick while the one before it was still being read, so with
 * a slow list (14 s measured) the calls piled up, each one making the store
 * slower for the next. And the Refresh button, wired before the first load
 * (MIGRATIONS-LOAD-1), started a second load beside the first. Now every load
 * - a refresh, and start()'s first load - is counted while it runs:
 *   - a TICK while a load runs is skipped, not queued: the load running now
 *     draws what the tick would, and the next tick reads again;
 *   - a REFRESH PRESS while a load runs joins it, and starts nothing;
 *   - a refresh a person starts in another way - another run chosen, the
 *     follow-up of an action - is never skipped: it reads what changed.
 * A load running longer than LOAD_HOLDS_MS holds nothing back: a call that
 * never answers must not stop the page refreshing. */
const LOAD_HOLDS_MS = 120000;
const loadsRunning = new Set();
function asOneLoad(work) {
  const load = { startedMs: Date.now(), done: null };
  loadsRunning.add(load);
  load.done = (async () => {
    try { return await work(); }
    finally { loadsRunning.delete(load); }
  })();
  return load.done;
}
/** The loads now running that are not yet past LOAD_HOLDS_MS. */
function loadsHolding() {
  const now = Date.now();
  return [...loadsRunning].filter(l => now - l.startedMs < LOAD_HOLDS_MS);
}
/** The clock's refresh: skipped while a load runs. */
function tickRefresh() {
  if (loadsHolding().length) { return null; }
  return refresh();
}
/** The Refresh button: joins a running load, else reads now. */
function refreshPressed() {
  nextRefresh = cfg?.refreshSeconds ?? 15;
  const running = loadsHolding();
  if (running.length) { return Promise.all(running.map(l => l.done.catch(() => { }))).then(() => { }); }
  return refresh();
}

/** Every refresh, whoever starts it: counted while it runs. */
function refresh(opts) {
  return asOneLoad(() => refreshOnce(opts));
}

async function refreshOnce(opts) {
  // Pick up NEW runs without a page reload; leave the panel
  // alone while it is open so the list doesn't shift under the pointer.
  // PAGE-WAIT-1: not straight after start() walked the store - that walked it
  // twice, back to back, before anything was drawn. And with a run already
  // chosen, the walk runs BESIDE this run's reads rather than before them.
  // PERF-MIGRATIONS-TICK-1: both halves share this tick's reads.
  const reads = (opts && opts.reads) || tickReads();
  const walkRuns = !(opts && opts.runsFresh) && !$('#run-panel').classList.contains('open');
  let walk = null;
  if (walkRuns && !currentRun) { await loadRuns(reads).catch(() => { }); }
  else if (walkRuns) { walk = loadRuns(reads).catch(() => { }); }
  try { await refreshRun(reads); }
  finally { if (walk) { await walk; } }
}

async function refreshRun(reads = tickReads()) {
  if (!currentRun) {
    // WAIT-3: there is nothing to read, so nothing may still say it is
    // reading. renderFirstRun explains the empty store; the regions below it
    // would otherwise hold the waiting rows painted before the walk began.
    clearReadingRun();
    await renderFirstRun();
    return;
  }
  // WAIT-2: a first load, or a run somebody just switched to. Either way what
  // is on screen is not this run, and the read that follows takes seconds.
  if (showingRun !== currentRun) { showReadingRun(); }
  try {
    $('#err').style.display = 'none';
    /* PAGE-WAIT-1: about fourteen of these went one after another, on load and
     * again on every refresh tick - each a round trip to the service. None
     * needs another's answer, except a folder's documents needing its list.
     * So: every document and every list together, then every list's
     * documents together. The plan is read ONCE, versioned, and the version
     * is what the sign-off is compared with (PLANVER-2).
     * PERF-MIGRATIONS-TICK-1: the status and the plan through this tick's
     * reader, which the run list shares - so they are sent once a tick.
     * PERF-PROBES-1: ONE listing of the whole run a tick, beside the status
     * and the plan. The pause flag, the acknowledgement, the sign-off and
     * plan-run.json are not there for most of a run's life, and each was a
     * call that found nothing every 15 seconds; so was the log part past the
     * last. Now a file is read only when the listing names it, and the five
     * folders come from the same listing instead of a listing each. The
     * listing replaces the read past the last log part, so the documents are
     * in hand after as many round trips as before. A listing that fails or is
     * cut short is not known, and every read is made as before. */
    const run = currentRun;
    /* PAGE-LOAD-2: ONE call for the run's folder: its listing, and every
     * document below that this page draws but the plan. The listing of the
     * run (PERF-PROBES-1) is asked for only when that call failed. */
    const runRead = reads.run(run);
    const listingRead = runRead.then(h => (h ? null : source.listRun(run))).catch(() => null);
    // A document: from the call, else as before - read when the listing names it.
    const doc = (rel) => runRead.then((h) => {
      const known = VmfHelp.heldJson(h, `${run}/${rel}`);
      if (known) { return known.value; }
      return listingRead.then(l => (VmfHelp.storeHolds(l, `${run}/${rel}`) ? source.readJson(run, rel) : null));
    });
    const folder = (name) => runRead.then((h) => {
      const known = VmfHelp.heldList(h, `${run}/${name}/`);
      if (known) { return known.names.map(n => n.slice(run.length + 1)); }
      return listingRead.then(l => runListed(l, run, name) ?? source.listFolder(run, name));
    });
    const [status, stateNames, capNames, events, planRead, ack, signoff, planRun, assessDoc,
           schedNames, apprNames, accNames, haltFlag, retention, leaseNames, stopDoc] = await Promise.all([
      reads.status(currentRun, runRead),
      folder('state'),
      folder('capacity'),
      Promise.all([runRead, listingRead]).then(([h, l]) => source.readLines(run, 'logs/events.jsonl', l, h)),
      reads.plan(currentRun),
      // ACK-GATE-1: the gate the engine checks before it looks at a wave at all.
      doc('acknowledgements/infrastructure-as-code.json').catch(() => null),
      // PLANRUN-1: the plan's one sign-off - for the plan as it stands only.
      doc('plan-approval.json').catch(() => null),
      doc('plan-run.json').catch(() => null),
      doc('assessment.json').catch(() => null),
      folder('schedules').catch(() => []),
      folder('approvals').catch(() => []),
      folder('acceptances').catch(() => []),
      // Absent unless the run is paused, which is the usual answer.
      doc('halt.flag'),
      source.readRoot('retention-status.json').catch(() => null),
      // WAVE-RUNNING-LEASE-1: the leases, from the same call. A held lease keeps
      // a wave running, here as in the engine. A listing that fails is NOT
      // KNOWN, never "no leases": taken as empty, a held wave read as free and
      // its controls were offered. The refresh fails with these words, and
      // nothing is drawn from it - the wave editor does the same (readLeases).
      folder('leases').catch((e) => { throw new Error(UX_MISC.leasesUnread.replace('{reason}', VmfHelp.explain(e))); }),
      // STOP-STATE-SHOWN-1: the record of Stop this migration. Absent unless a
      // person stopped the migration, which reads as null. No catch, as for
      // halt.flag: a read that fails is not "not stopped", which would draw a
      // stopped migration as Complete with a red brake and Resume.
      doc('stopped.json'),
    ]);
    /* MIGRATIONS-LOAD-1: another run was chosen while this one was read - the
     * list chose another (firstLoad), or a person switched. This run's
     * documents are not kept: the refresh for the run now chosen draws its
     * own. Kept, they stood under the other run's name until the next tick. */
    if (run !== currentRun) { return; }
    const pv = planRead.pv;
    planDoc = planRead.doc;
    runAck = ack;
    runStop = stopDoc && stopDoc.stoppedUtc ? stopDoc : null;
    planSignoff = signoff;
    planSignoffCurrent = Boolean(planSignoff) && (DEMO_MODE || Boolean(pv && pv.version && pv.version === planSignoff.planHash));
    planRunStatus = planRun;
    lastAssessment = assessDoc;
    // STORE-READ-2: paced, not truncated - one request per document, at most
    // eight at a time. The five folders share ONE pacing, so together they
    // never open more than one folder did before.
    const tagged = [
      ...schedNames.filter(n => n.endsWith('.json')).map(n => ['sched', n]),
      // WAVE-2: the options acceptance per wave, keyed by the wave name inside
      // the document (the filename is sanitised, so it cannot be the key).
      ...accNames.filter(n => n.startsWith('acceptances/wave-options-') && n.endsWith('.json')).map(n => ['acc', n]),
      ...apprNames.filter(n => n.endsWith('.json')).map(n => ['appr', n]),
      // One document per machine in the run. This is the largest of them.
      ...stateNames.filter(n => n.endsWith('.json')).map(n => ['vm', n]),
      ...capNames.filter(n => n.endsWith('.json')).map(n => ['cap', n]),
      ...leaseNames.filter(n => n.endsWith('.lease')).map(n => ['lease', n]),
    ];
    // PAGE-LOAD-2: each from the run's one call, when it holds it.
    const runHeld = await runRead;
    const readOne = (n) => {
      const known = VmfHelp.heldJson(runHeld, `${run}/${n}`);
      return known ? Promise.resolve(known.value) : source.readJson(run, n);
    };
    const read = await VmfHelp.mapLimited(tagged, ([kind, n]) =>
      // WAVE-RUNNING-LEASE-1: a lease its job removed after the listing is gone.
      (kind === 'acc' || kind === 'lease' ? readOne(n).catch(() => null) : readOne(n)));
    if (run !== currentRun) { return; }   // MIGRATIONS-LOAD-1: as above
    const of = (kind) => tagged.map(([k, n], i) => [k, n, read[i]]).filter(([k]) => k === kind);
    const leaf = (n) => n.split('/').pop().replace(/\.json$/, '');
    schedules = new Map(of('sched').filter(([, , d]) => d).map(([, n, d]) => [leaf(n), d]));
    acceptances = new Map(of('acc').map(([, , d]) => d).filter(Boolean).map(a => [a.wave, a]));
    approvals = new Map(of('appr').filter(([, , d]) => d).map(([, n, d]) => [leaf(n), d]));
    allVms = of('vm').map(([, , d]) => d).filter(Boolean);
    nameMachines(allVms, lastAssessment);
    latestClaims = of('cap').map(([, , d]) => d).filter(Boolean);
    latestLeases = VmfHelp.leasesByMachine(of('lease').map(([, , d]) => d));
    const halted = Boolean(status?.breaker?.halted) || Boolean(haltFlag);
    latestHalted = halted;   // EVAL-M12: so a keystroke cannot un-pause the page
    /* WAIT-2: this run's documents are all in hand, and what follows is
     * drawing. Set BEFORE the renders, not after: renderWaves refuses to draw
     * a run the body is not showing, which is what stops a keystroke wiping
     * the waiting line - and that guard would otherwise refuse the very render
     * that ends the wait.
     *
     * Still after every read that can throw, so a failed refresh leaves the
     * waiting state standing and the next attempt does not skip it. */
    showingRun = currentRun;
    // DISCARD-ENGINE-1: before the tiles, which draw the run actions that read it.
    discardInFlight = discardIndex(events, Date.now());
    latestEvents = events;
    // RENDER-1: rebuilt with the events, never per row. Set here and nowhere
    // else, beside the thing it is derived from - an index that can be older
    // than its source is worse than the scan it replaced.
    restoresInFlight = restoreIndex(events);
    /* CLICKS-LOST-1: the data above is new at once; the DRAWING waits while
     * the person holds a control the drawing would replace (runRegions). On
     * the lab install Show what the scan found did nothing while the page
     * loaded: each refresh replaced the button between the press and the
     * release. A later refresh's drawing takes the place of one still waiting. */
    VmfHelp.drawWhenFree(runRegions(), () => {
      // A drawing that waited is for THIS run: another run chosen since draws its own.
      if (run !== currentRun) { return; }
      renderKpis(allVms, halted, runStop);
      renderNextStep(events);
      renderFound(assessDoc, Boolean(planDoc && (planDoc.entries ?? []).length), planDoc);
      renderWaves(halted);
      refreshDrill();   // MACHINE-PANEL-STALE-1: the open panel, from the same documents
      renderCapacity(latestClaims, planDoc, (w) => reservationReleasable(w, planDoc));
      renderSafetyCopies(allVms, planDoc, retention);
      renderEvents(events);
      // What "Updated ... ago" says is when the screen was drawn.
      lastUpdated = Date.now();
    });
    const latest = events.length ? events[events.length - 1].tsUtc : status?.updatedUtc;
    const fresh = latest && (Date.now() - Date.parse(latest)) < 180000;
    $('#live-ind').className = 'livedot' + (fresh ? '' : ' idle');
    $('#live-ind').title = latest ? `last activity ${ago(latest)}` : 'no activity recorded';
  } catch (e) {
    $('#err').textContent = `Could not refresh: ${VmfHelp.explain(e)}`;
    $('#err').style.display = 'block';
  }
}
/* ACTFEED-1: follow an action through, instead of asking somebody to wait.
 *
 * WHAT HAPPENED. A user approved a wave. The dialog did its job - the button
 * disabled, said "Working...", the banner said it was done. Then the row
 * underneath still read "Waiting for approval" for ten to fifteen seconds, and
 * only a full refresh showed it.
 *
 * The page refreshed once, IMMEDIATELY, and read a store the service had not
 * finished writing. So the refresh was real and the answer was stale. After
 * that nothing happened until the fifteen-second tick.
 *
 * The page said two things at once - a banner saying it worked and a row saying
 * it had not - which is the same disagreement as a machine count that
 * contradicts the table above it. And the message apologised for it:
 * "It can take a few seconds to appear in the view."
 *
 * A PRODUCT THAT KNOWS ITS VIEW IS BEHIND SHOULD CATCH UP, NOT APOLOGISE.
 *
 * Bounded on purpose. Four reads, over about eleven seconds, then the ordinary
 * tick takes over: enough to cover the lag that was measured, and it cannot
 * become a loop that outlives the thing it is waiting for. Anything cleverer -
 * polling until the state changes - needs a definition of "changed" for every
 * action on this page, and would run for ever on the one action where the
 * engine failed.
 *
 * Only one runs at a time. Two actions in quick succession would otherwise
 * stack their timers and read the store eight times for no reason.
 */
const FOLLOW_THROUGH_MS = [0, 1500, 3500, 6000];
let followTimers = [];

function followThrough(schedule) {
  for (const t of followTimers) { clearTimeout(t); }
  followTimers = [];
  const when = schedule ?? FOLLOW_THROUGH_MS;
  for (const ms of when) {
    followTimers.push(setTimeout(() => { refresh(); }, ms));
  }
  return followTimers.length;
}

function tickLoop() {
  const period = cfg?.refreshSeconds ?? 15;
  setInterval(() => {
    // This used to `return` until lastUpdated was set, and
    // lastUpdated is only set AFTER a run's data loads - while refresh()
    // itself bails early when no run is selected. So with nothing selected,
    // or when the selected run failed to load, the countdown never advanced
    // and the loop was DEAD: new runs never appeared until a page reload.
    // The clock runs regardless; only the wording depends on having data.
    nextRefresh -= 1;
    // MIGRATIONS-LIST-READS-1: skipped while a load is still running.
    if (nextRefresh <= 0) { nextRefresh = period; tickRefresh(); }
    $('#tick').textContent = lastUpdated
      ? `Updated ${ago(new Date(lastUpdated).toISOString())} · next in ${nextRefresh}s`
      : `Looking for migrations · next in ${nextRefresh}s`;
  }, 1000);
  nextRefresh = period;
}

// ---------- run picker (module scope: the list refreshes with the data,
// no page reload needed, and the last-viewed run is remembered) ----------
let runRows = [];
/* RUNPICK-1: the picker's groups, in the order they are shown, with the class
 * and the short tag for each. This was a chain of ternaries inside the row
 * markup, which is why 'Planned' had to be added in three places at once.
 *
 * 'Planned' is new. A run that was planned and never started matched none of
 * the others and fell through to 'Other', where it is shown as 'idle' - so the
 * one run on a fresh install, the one waiting for somebody to act on it, was
 * the one the picker had nothing to say about. */
/* APPROVE-GROUP-1: 'Waiting for approval' is new, above 'Planned', because a
 * person is needed - and needing a person is why such a migration has stopped.
 * The row's tag says which thing to do: accept (the note about machines
 * defined in code, or the settings of the next wave) or approve (the next
 * wave). The page's own words for the two buttons. WAVE-APPROVE-TIMER-WORDS-1
 * added start: the next wave changed after the plan was signed off, so the
 * plan's timer does not start it, and a person selects Start this wave. */
const RUN_GROUPS = ['Still being prepared', 'Waiting for approval', 'Planned', 'In progress', 'Needs attention', 'Completed', 'Other'];
const GROUP_PILL = { 'Waiting for approval': 'warn', 'In progress': '', 'Needs attention': 'warn', 'Completed': 'good', 'Other': 'quiet' };
const GROUP_TAG = {
  'Still being prepared': 'setup', 'Waiting for approval': 'approve', 'Planned': 'planned', 'In progress': 'live',
  'Needs attention': '!', 'Completed': 'done', 'Other': 'idle',
};
// What the next wave waits for, from the summary, and the tag of each: the
// one table in help.js, which the overview reads too.
function runTag(group, waitsFor) {
  const gate = VmfHelp.runGateTag(waitsFor);
  if (group === 'Waiting for approval' && gate) { return gate; }
  return GROUP_TAG[group] ?? 'idle';
}
function selectRun(name) {
  currentRun = name;
  try { localStorage.setItem('vmf-last-run', name); } catch { }
  // RUN-LINK-1: the address names what the page shows. A link now wins over
  // the remembered run, so a pick that left the old address behind came back
  // as the linked run on a reload, and a copied address opened that one. The
  // whole id goes in run=, and project= is left alone: it is the list's filter.
  try {
    const url = new URL(location.href);
    url.searchParams.set('run', name);
    history.replaceState(null, '', url);
  } catch { }
  renderRunPanel();
}
// The picker must not become an endless scroll as runs pile up.
// Rule: age only ever hides things that are FINISHED OR IDLE. Anything live or
// needing attention stays visible however old it is - hiding a stuck machine
// because it happens to be from last month is exactly the wrong behaviour.
const RUN_WINDOW_DAYS = 14;
let showOlderRuns = false;
function runIsRecent(x) {
  // APPROVE-GROUP-1: a migration waiting for a person is never hidden by age.
  if (x.group === 'In progress' || x.group === 'Needs attention' || x.group === 'Waiting for approval') return true;
  if (x.r === currentRun) return true;
  // A run has no timestamp until run-status.json exists, which means a run
  // created SECONDS ago looks identical to one abandoned last year. Hiding
  // what we cannot date was wrong: it hid brand-new runs, which are the ones
  // a person is most likely looking for. Show it, and let the window hide
  // only what we can positively date as old.
  if (!x.t) return true;
  return (Date.now() - x.t) < RUN_WINDOW_DAYS * 86400000;
}
/* RUNPICK-1: a run and the piece of work it belongs to, as two things.
 *
 * A run inside a project is identified as `project/run`, and the picker showed
 * that whole string - up to about 75 characters of two timestamps - as one
 * line of monospace, in a panel 380 pixels wide, and the same string again in
 * the header button where it was cut off. So the one question the picker
 * exists to answer, WHICH RUN AM I LOOKING AT, was the one it could not.
 *
 * The run is what distinguishes one row from the next, so the run leads and
 * the project sits under it, quiet. A run outside a project has no second
 * line rather than an empty one. */
function runLabel(id) {
  const parsed = VmfHelp.VmfRun.parse(id);
  return { project: parsed.project || '', run: parsed.run || String(id ?? '') };
}

function renderRunPanel() {
  // WAIT-1: 'no migrations' is a statement about what somebody has. It must
  // not be made before the store has been read.
  const current = currentRun ? runLabel(currentRun) : null;
  $('#run-current-name').textContent = current ? current.run : (reading ? UX_MISC.waiting : UX_MISC.noRuns);
  $('#run-current-project').textContent = current ? current.project : '';
  const visible = showOlderRuns ? runRows : runRows.filter(runIsRecent);
  const hidden = runRows.length - visible.length;
  /* RUNROW-1: the project is drawn on a row only when it TELLS RUNS APART.
   *
   * RUNPICK-1 put the project under every run's name. On the install it was
   * written for, that produced this:
   *
   *   [planned]  drill-20260918-135309-migration-20260918-135356
   *              vmf-drill-20260918-135309
   *
   * One run. A reader took it for two different items, and that reading was
   * fair - two long strings that begin with the same timestamp,
   * stacked, with nothing saying which is which. A run id and its project SHARE
   * their timestamp, so they look like siblings.
   *
   * When every run on offer is in the same project, the project cannot tell one
   * row from another, and the header already names it. So it is left out. When
   * runs come from more than one project it is the thing that tells them apart,
   * so it is drawn - and prefixed with the product's own noun, which is what
   * stops it reading as a run of its own.
   */
  const showProject = new Set(visible.map(x => runLabel(x.r).project)).size > 1;
  $('#run-panel').innerHTML = RUN_GROUPS.map(g => {
    const members = visible.filter(x => x.group === g);
    if (!members.length) return '';
    return `<div class="grp">${esc(g)}</div>` + members.map(({ r, t, setupOnly, waitsFor }) => {
      const label = runLabel(r);
      return `<button type="button" class="row ${r === currentRun ? 'sel' : ''}" role="option" data-run="${esc(r)}">
         <span class="pill ${GROUP_PILL[g] ?? 'quiet'}">${esc(runTag(g, waitsFor))}</span>
         <span class="rn">${esc(label.run)}${showProject && label.project ? `<span class="rp">${esc(UX_MISC.rowProject)} ${esc(label.project)}</span>` : ''}</span>
         <span class="when">${setupOnly
            ? `<a href="${VmfHelp.VmfRun.link('wizard.html', r)}">${esc(UX_MISC.continueSetup)}</a>`
            : (t ? esc(ago(new Date(t).toISOString())) : '')}</span>
       </button>`;
    }).join('');
  }).join('') + (hidden > 0
    ? `<button type="button" class="row run-more" data-more="1">
         <span class="rn">Show ${hidden} older run${hidden === 1 ? '' : 's'}</span>
         <span class="when">older than ${RUN_WINDOW_DAYS} days</span>
       </button>`
    : (showOlderRuns && runRows.length
        ? `<button type="button" class="row run-more" data-more="0">
             <span class="rn">Show only the last ${RUN_WINDOW_DAYS} days</span>
           </button>`
        : ''));
  const more = $('#run-panel').querySelector('.run-more');
  if (more) more.addEventListener('click', (e) => {
    e.stopPropagation();
    showOlderRuns = more.dataset.more === '1';
    renderRunPanel();
  });
  $('#run-panel').querySelectorAll('.row:not(.run-more)').forEach(b => b.addEventListener('click', () => {
    selectRun(b.dataset.run);
    $('#run-panel').classList.remove('open');
    $('#run-current').setAttribute('aria-expanded', 'false');
    refresh();
  }));
}
/* RUNPICK-1, APPROVE-GROUP-1: which group a migration belongs in, and the
 * summary of the whole migration it is judged by, are VmfHelp.runGroup and
 * VmfHelp.runSummaryOf (help.js). OVERVIEW-SUMMARY-1 moved them there, so
 * the overview asks the same question with the same code. */

// A run just started may not be listable yet; keep it visible until the store
// catches up, or the next refresh silently drops it and no run appears to be
// created at all.
const pendingRuns = new Set();
// WAIT-1: true until the store has been read.
let reading = true;
let lastListError = null;
/* RUN-LINK-1: the migration the address names, when it is one of `ids`.
 * VmfRun.link writes `run=<run>&project=<project>`, and the store's ids are
 * `project/run` - comparing the bare run with those ids never matched, so a
 * link opened the last or the newest migration instead. */
function linkedRunId(search, ids) {
  const id = VmfHelp.VmfRun.fromQuery(search);
  return id && ids.includes(id) ? id : null;
}
/* PERF-MIGRATIONS-TICK-1: what each run's manifest (run.json) said it is, for
 * the life of the page. The engine writes the manifest once, when it makes the
 * run, and never writes it again (StateStore.ps1: "NOT re-written when it
 * already exists"), so its kind cannot change under the page. */
const runKinds = new Map();
/* MIGRATIONS-LOAD-1: THE OPEN RUN IS DRAWN WITHOUT WAITING FOR THE LIST.
 *
 * MEASURED on the lab install, 2026-11-08 (the service's call-timing lines):
 * the list call - the whole store listed, with run.json and run-status.json
 * of every run, 188 to 192 documents - took 1.5 to 14.2 s; the open run's
 * call took 40 ms to 3.0 s. start() sent the run's call only after the list
 * answered, so the first draw waited for both, one after the other.
 *
 * When the page already knows which run it opens - a ?run= link, else the run
 * looked at last - it reads that run BESIDE the list, and draws it as soon as
 * its own documents are in and its manifest says it is a migration. The list
 * still decides when it cannot: nothing named, an assessment, a run that is
 * gone, a run outside ?project=. A run the list then does not hold is not
 * kept: loadRuns chooses another run, and firstLoad draws that one. */

/** The run this load opens if the list agrees, or null. The same order
 *  loadRuns chooses in: a ?run= link wins, then the run looked at last. */
function namedRun() {
  let id = VmfHelp.VmfRun.fromQuery(location.search);
  if (!id) {
    try { id = localStorage.getItem('vmf-last-run'); } catch { id = null; }
  }
  const onlyProject = new URLSearchParams(location.search).get('project');
  if (!id || (onlyProject && !String(id).startsWith(onlyProject + '/'))) { return null; }
  return id;
}

/** Read and draw the named run beside the list. Draws nothing unless its
 *  manifest says it is a migration, and nothing if the list has chosen
 *  another run first. */
async function drawNamedRun(reads) {
  const run = namedRun();
  if (!run) { return; }
  // PAGE-LOAD-2's one call for the run, sent now, beside its manifest:
  // refreshRun takes the same answer from this load's reader.
  reads.run(run);
  let manifest = null;
  try { manifest = await source.readJson(run, 'run.json'); } catch { return; }
  // ASSESS-PAGE-1, RETAIN-KIND-1: the one rule for a run's kind. No manifest
  // is not known here, so the list decides (unknown means ask).
  const kind = VmfHelp.runKind(manifest);
  if (!kind || kind === 'assessment') { return; }
  if (currentRun && currentRun !== run) { return; }
  currentRun = run;
  await refreshRun(reads);
}

/** start()'s reads: the list and the named run together, then the run the
 *  list chose, when that is not the run already drawn. */
async function firstLoad(reads) {
  const early = drawNamedRun(reads);
  try { await loadRuns(reads); }
  finally { reading = false; renderRunPanel(); }
  await early;
  if (!currentRun || showingRun !== currentRun) { await refresh({ runsFresh: true, reads }); }
}

async function loadRuns(reads = tickReads()) {
  // ?project= arrives from the Projects page, where the migration count is a
  // link. Ids inside a project are `project/migration-...`, so the filter is
  // the prefix.
  const onlyProject = new URLSearchParams(location.search).get('project');
  // PAGE-WAIT-1: the listing's own failure is kept, so the empty-store card
  // can say why without listing the whole store a second time.
  /* PAGE-LOAD-2: ONE call for the list - the store listed down to each run's
   * documents, with every run.json and run-status.json. The walk below is the
   * walk it always was; what that call holds is not asked for again. */
  const held = await reads.list();
  let listed;
  try { listed = await source.listRuns(held); lastListError = null; }
  catch (e) { lastListError = e; throw e; }
  const runs = [...new Set([...listed, ...pendingRuns])]
    .filter(r => !onlyProject || String(r).startsWith(onlyProject + '/'));
  // MIGRATIONS-LIST-READS-1: the next list names run.json while one of these has no known kind.
  listedRuns = runs;
  // STORE-READ-2: one manifest read per run in the store, paced.
  const planOf = (r) => reads.plan(r).then(x => x.doc).catch(() => null);
  const withStatus = await VmfHelp.mapLimited(runs, async r => {
    /* PERF-MIGRATIONS-TICK-1: a run's kind never changes, so the page reads
     * run.json once and keeps what it says. An assessment then costs this
     * list no read at all: it never has run-status.json or plan.json, and
     * asking for them every 15 seconds was two answers of 404 a tick, for
     * every assessment in the store. A manifest that could not be read
     * teaches nothing, so it is asked for again (unknown means ask). */
    const known = runKinds.get(r);
    if (known === 'assessment') return null;
    // PAGE-LOAD-2: the manifest from the one call, when it holds it. Then the
    // kind is known before any other read, and the plan is read only where
    // the status cannot count the machines, as on a later tick.
    const heldManifest = known ? undefined : VmfHelp.heldJson(held, `${r}/run.json`);
    // PAGE-WAIT-1: while the kind is not known, the three reads for a run go
    // together, as they did. They went one after another, for every run in
    // the store, on load and on every tick.
    const [manifest, st, firstPlan] = await Promise.all([
      known ? null : (heldManifest ? heldManifest.value : source.readJson(r, 'run.json').catch(() => null)),
      reads.status(r, held).catch(() => null),
      known || heldManifest ? undefined : planOf(r),
    ]);
    // ASSESS-PAGE-1: this page is MIGRATIONS. An assessment is a different
    // thing with its own page - leaving them here is what made a scan look
    // like an abandoned migration.
    // RETAIN-KIND-1: the one rule, which the daily check asks too.
    const kind = known || VmfHelp.runKind(manifest);
    if (kind && !known) { runKinds.set(r, kind); }
    if (kind === 'assessment') return null;
    const t = st?.updatedUtc ? Date.parse(st.updatedUtc) : 0;
    const counts = st?.stateCounts ?? null;
    // APPROVE-GROUP-1: the summary of the whole migration, read with the
    // status - no further read per run.
    const summary = VmfHelp.runSummaryOf(st);
    /* PERF-MIGRATIONS-TICK-1: the summary counts the machines the plan moves
     * (run-status v3 and later), so a later tick reads the whole plan only
     * when the summary cannot answer: no summary, or one that counts no
     * machine - a plan that moves none may still have entries, and a run with
     * no entries is still being set up. A summary is written only for a run
     * with a plan (Update-VmfRunSummary), so one that counts a machine proves
     * the plan has entries. */
    const counted = summary ? Number(summary.machines) || 0 : 0;
    // PERF-SETUP-RUNS-1: a plan the listing says is not there is not asked for
    // (a migration scanned and never planned has neither document).
    const planThere = VmfHelp.heldHas(held, `${r}/plan.json`);
    const planned = firstPlan !== undefined ? firstPlan
      : (counted > 0 || planThere === false ? null : await planOf(r));
    // RUN-LIFECYCLE-1: a run with no plan was only scanned. It must not sit in
    // the list looking like one somebody is migrating with - and it needs a
    // way back into the wizard where it was abandoned.
    const setupOnly = firstPlan !== undefined || counted === 0 ? !((planned?.entries ?? []).length) : false;
    const group = VmfHelp.runGroup(setupOnly, counts, t, Date.now(), { summary });
    return { r, t, group, setupOnly, waitsFor: summary ? summary.next.waitsFor : null };
  });
  // Drop the assessments BEFORE sorting - the comparator dereferences .t, and
  // a null in the array would throw before anything rendered.
  const migrations = withStatus.filter(Boolean);
  migrations.sort((a, b) => b.t - a.t);   // newest activity first within groups
  runRows = migrations;
  if (!currentRun || !runRows.some(x => x.r === currentRun)) {
    // A ?run= link wins; then the run you looked at last; otherwise the newest.
    const linked = linkedRunId(location.search, runRows.map(x => x.r));
    let remembered = null;
    try { remembered = localStorage.getItem('vmf-last-run'); } catch { }
    currentRun = linked ? linked
      : (remembered && runRows.some(x => x.r === remembered)) ? remembered
      : (runRows[0]?.r ?? null);
  }
  renderRunPanel();
}

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  await initActions();
  /* WAIT-3: the body is on screen, and says what it is reading, BEFORE the
   * slow part - not after it.
   *
   * WAIT-2 gave every region of the body a waiting state and it was NEVER SEEN.
   * It is painted inside refresh(), and refresh() runs after `#app` is shown,
   * which used to be forty lines below here. The slow part is loadRuns() - one
   * manifest read per run in the store - and the whole app was still
   * display:none for all of it.
   *
   * MEASURED on a real install, 2026-09-18: about twenty-five seconds of a
   * completely empty page, with the only sign of life the picker's own line in
   * the header, which is small and grey.
   *
   * A waiting state that is hidden during the wait is not a waiting state. So
   * the body is shown first, holding the message, and the reads follow. */
  $('#app').style.display = 'block';
  showReadingRun();
  // WAIT-1: the picker says what it is reading before the walk begins.
  renderRunPanel();
  /* MIGRATIONS-LOAD-1: the controls and their Escape and Close handlers are
   * wired BEFORE the reads, not after the list of runs: the open run can now
   * be drawn while the list is still being read (firstLoad), and a panel
   * opened from it must close with Escape from the first moment. */
  renderActMenu();
  VmfHelp.identity(account, DEMO_MODE ? UX_WHO.demoViewer : null);
  $('#status-chips').innerHTML = Object.entries(UX_FILTER).map(([k, label]) =>
    `<button type="button" data-filter="${esc(k)}" class="${k === 'all' ? 'on' : ''}">${esc(label)}</button>`).join('');
  $('#status-chips').querySelectorAll('button').forEach(b => b.addEventListener('click', () => {
    statusFilter = b.dataset.filter;
    $('#status-chips').querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b));
    renderWaves(latestHalted);
  }));
  $('#run-current').addEventListener('click', (e) => {
    e.stopPropagation();
    const open = $('#run-panel').classList.toggle('open');
    $('#run-current').setAttribute('aria-expanded', String(open));
  });
  document.addEventListener('click', dismissOnOutsideClick);
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if ($('#modal-back').classList.contains('open')) { if (closeModalHelp()) return; closeModal(); return; }
    // MADE-DISK-DELETE-1: an open slide-out delete of disks closes first.
    if ($('#drill').classList.contains('open') && $('#drill-body .diskdel-slide')) { closeDiskDelete(); return; }
    if ($('#drill').classList.contains('open') && madeHelpOpen.has(drillVmId)) { toggleMadeHelp(drillVmId); return; }
    if ($('#drill').classList.contains('open')) { closeDrill(); return; }
    if (soonHelpOpen.size) { soonHelpOpen.clear(); renderWaves(latestHalted); return; }
    $('#run-panel').classList.remove('open');
    $('#act-panel').classList.remove('open');
  });
  $('#m-cancel').addEventListener('click', closeModal);
  // CSP-INLINE-1: the policy refuses an onclick= attribute, so the panel's
  // close button is wired here like every other control.
  $('#drill-close').addEventListener('click', closeDrill);
  $('#modal-back').addEventListener('click', (e) => { if (e.target === e.currentTarget) closeModal(); });
  // MIGRATIONS-LIST-READS-1: a press while a load runs joins it.
  $('#refresh-btn').addEventListener('click', () => { refreshPressed(); });
  $('#vm-search').addEventListener('input', (e) => { searchTerm = e.target.value.toLowerCase(); renderWaves(latestHalted); });
  // PERF-MIGRATIONS-TICK-1: the walk and the first draw are one load, so they
  // share one reader, and the run chosen here is read once, not twice.
  // MIGRATIONS-LIST-READS-1: a load, so a Refresh press during it joins it.
  await asOneLoad(() => firstLoad(tickReads()));
  tickLoop();
}

async function boot() {
  // RETRY-1: guidance for stop codes, deployed from the engine's own data file.
  // Loaded before the demo/live branch, because a stop needs explaining in
  // both. Best effort on purpose - if it is missing the page shows the raw
  // engine detail rather than inventing an explanation for a code it cannot
  // resolve.
  // PAGE-WAIT-1: the three files this page starts from are fetched together.
  const configRead = DEMO_MODE ? null : fetch('dashboard.config.json').then(r => r.json());
  configRead?.catch(() => { });   // awaited below, where its failure is reported
  await Promise.all([
    (async () => {
      try {
        const sr = await (await fetch('stop-reasons.json')).json();
        for (const r of (sr.reasons ?? [])) stopReasons.set(r.code, r);
        retryLines = sr.retryLines ?? {};
      } catch { /* no guidance available; details still render */ }
    })(),
    loadReasons(),
  ]);
  // NOTHING WIRES #nav-help HERE ANY MORE.
  //
  // This block predates the shared help menu and was never removed when
  // VmfHelp arrived, so THIS page attached a SECOND click handler to the same
  // tab. One click then opened the shared menu AND the support-bundle dialog
  // behind it - cancel the menu and the download box was still sitting there.
  //
  // Cancelling the help dialog still asked to download files, after an
  // earlier fix for the same symptom. That fix stopped the SHARED
  // installer from binding twice; it could not stop a page adding its own.
  //
  // The bundle is still one click away: the shared menu's first option, "A
  // machine did not migrate", opens exactly this dialog. VmfHelp.install()
  // above hands it the readers it needs.
  if (DEMO_MODE) {
    $('#demo-tag').style.display = 'inline-block';
    cfg = { refreshSeconds: 3600 };
    await start();
    return;
  }
  if (typeof msal === 'undefined') {
    throw new Error(UX_MISC.msalMissing);
  }
  cfg = VmfHelp.checkedConfig(await configRead);
  msalApp = new msal.PublicClientApplication({
    auth: { clientId: cfg.clientId, authority: `https://login.microsoftonline.com/${cfg.tenantId}`,
            redirectUri: location.origin + location.pathname },
    cache: { cacheLocation: 'sessionStorage' },
  });
  await msalApp.initialize();
  /* POPUP-3: takes the account a sign-in redirect brought back, when this load
     IS the return from one. Throws if the directory refused, and remembers the
     attempt, so the page cannot ask again and loop. */
  const accounts = await VmfHelp.accountsAfterReturn(msalApp);
  if (accounts.length) { account = accounts[0]; await start(); }
  else {
    VmfHelp.showSignIn();
    $('#login-btn').addEventListener('click', async () => {
      try {
        /* POPUP-3: leaves for the directory. Nothing follows - the browser navigates away here. */
        await VmfHelp.signInRedirect(msalApp, [`api://${cfg.apiAppId}/access_as_user`]);

      } catch (e) {
        $('#err').textContent = `Sign-in failed: ${e.errorCode ?? ''} ${e.message}`;
        $('#err').style.display = 'block';
      }
    });
  }
}

/* MANUAL-SHOTS-1: ?demo has no service, so every action answers with nothing.
 * The one answer that draws a control is the size series a rolled-back machine
 * may take, so the sample answers it - in the shape the service gives - and the
 * panel shows its Change to buttons. */
function demoAnswer(path, body) {
  if (/\/plan\/target$/.test(String(path)) && body?.preview) {
    const e = (planDoc?.entries ?? []).find(x => x.vmId === body.vmId);
    const base = String(e?.target?.size ?? '').replace(/_v\d$/, '');
    const now = e?.policy?.targetGeneration ?? 'v6';
    // The fields Set-VmfMachineTarget answers a preview with.
    return { VmId: body.vmId, Name: vmName(body.vmId), Wave: e?.wave, Current: now, CurrentSize: e?.target?.size,
      Applied: false, PlanVersion: 'demo',
      Options: ['v5', 'v6', 'v7'].map(s => ({ option: s, supported: true, current: s === now, targetSize: `${base}_${s}`, why: [] })) };
  }
  return {};
}

// ---------- bundled sample data (REH-2-shaped: two named waves) ----------
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso-app/providers/Microsoft.Compute/virtualMachines/';
const now = Date.now();
const T0 = (minAgo) => new Date(now - minAgo * 60000).toISOString();
function demoDoc(name, state, history, extras = {}) {
  return { schemaVersion: 1, runId: VmfHelp.sampleRun.runId, vmId: SUB + name, state, history, guestExecutions: [], ...extras };
}
const DEMO = {
  // MACHINE-PICK-1: each machine carries its id, as a real assessment does, so the
  // list of found machines can tell the planned ones from the ones left out.
  'assessment.json': { schemaVersion: 1, scope: { subscriptions: ['00000000-0000-0000-0000-000000000000'] }, vms: [
    { vmId: SUB + 'can-win-a', name: 'can-win-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'storefront', owner: 'retail', env: 'prod' } },
    { vmId: SUB + 'can-lin-a', name: 'can-lin-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'storefront', owner: 'retail', env: 'prod' } },
    // SAMPLE-COUNTS-1: every machine the plan below holds, as the scan found
    // it. A plan is built from its assessment, and the picture of this page
    // showed "Machines we found 4" above a run of 12. sample-counts.test.js
    // holds the two together.
    { vmId: SUB + 'can-lin-b', name: 'can-lin-b', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'storefront', owner: 'retail', env: 'prod' } },
    { vmId: SUB + 'prd-win-a', name: 'prd-win-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-win-b', name: 'prd-win-b', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-ebs-a', name: 'prd-ebs-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_E2bds_v5', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-lin-a', name: 'prd-lin-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep', 'mana-kernel-floor'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-lin-b', name: 'prd-lin-b', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-tf-a', name: 'prd-tf-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-tmp-a', name: 'prd-tmp-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D4ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-lin-c', name: 'prd-lin-c', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D4s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'prd-lin-d', name: 'prd-lin-d', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    { vmId: SUB + 'old-enc-a', name: 'old-enc-a', resourceGroup: 'rg-contoso-app', location: 'eastus2', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'billing', owner: 'finance', env: 'prod' } },
    // Two machines the plan does not hold: one not chosen, one not eligible.
    // Each id names the resource group the machine is in.
    { vmId: SUB.replace('/rg-contoso-app/', '/rg-legacy/') + 'old-win-b', name: 'old-win-b', resourceGroup: 'rg-legacy', location: 'eastus2', sourceSize: 'Standard_D2_v3', classification: 'Blocked', blockers: ['gen1-requires-redeploy'], prepNeeded: [] },
    { vmId: SUB.replace('/rg-contoso-app/', '/MC_aks-rg/') + 'aks-node-1', name: 'aks-node-1', resourceGroup: 'MC_aks-rg', location: 'eastus2', sourceSize: 'Standard_D4s_v5', classification: 'Excluded', blockers: [], prepNeeded: [] },
  ]},
  // WAVE-SAMPLE-RUN-1: the plan is the one the wave editor shows too, written
  // once in help.js (VmfHelp.sampleRun) - it says what each machine shows.
  'plan.json': VmfHelp.sampleRun.plan(),
  'approvals/billing-apps.json': { schemaVersion: 1, runId: VmfHelp.sampleRun.runId, wave: 'billing-apps',
    approvedBy: { identity: 'approver@example.com', tenantId: 't' }, approvedUtc: T0(58),
    planHash: 'a'.repeat(64), note: 'storefront-pilot report reviewed with app owners - approved to proceed' },
  'run-status.json': { schemaVersion: 1, runId: VmfHelp.sampleRun.runId, wave: 'billing-apps', updatedUtc: T0(1),
    stateCounts: {}, running: [], breaker: { halted: false, consecutiveFailures: 0, recentFailureRate: 0 }, throttle: { limit: 15 } },
  'state/can-win-a.json': demoDoc('can-win-a', 'MIGRATED', [
    { tsUtc: T0(95), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(90), state: 'GUEST_PREP', outcome: 'ok', durationSec: 170 },
    { tsUtc: T0(88), state: 'SAFETY_COPY', outcome: 'ok', durationSec: 45 }, { tsUtc: T0(86), state: 'STOPPED', outcome: 'ok', durationSec: 66 },
    { tsUtc: T0(82), state: 'CONVERTING', outcome: 'ok', durationSec: 150 }, { tsUtc: T0(79), state: 'STARTING', outcome: 'ok', durationSec: 121 },
    { tsUtc: T0(76), state: 'VALIDATING', outcome: 'ok', durationSec: 98 }, { tsUtc: T0(75), state: 'MIGRATED', outcome: 'ok' }],
    { pathCheckpoint: 'A:diskPatched', guestExecutions: [
      { script: 'Set-NvmeReady.ps1', version: '1.0.0', result: 'FIXED', tsUtc: T0(91), evidenceRef: 'evidence/sample-guest-output.txt' },
      { script: 'Test-GuestValidation.ps1', version: '1.0.0', result: 'PASS', tsUtc: T0(76) }] }),
  'state/can-lin-a.json': demoDoc('can-lin-a', 'MIGRATED', [
    { tsUtc: T0(94), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(85), state: 'CONVERTING', outcome: 'ok', durationSec: 90 },
    { tsUtc: T0(80), state: 'MIGRATED', outcome: 'ok' }]),
  'state/can-lin-b.json': demoDoc('can-lin-b', 'MIGRATED', [
    { tsUtc: T0(93), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(83), state: 'MIGRATED', outcome: 'ok' }]),
  'state/prd-win-a.json': demoDoc('prd-win-a', 'MIGRATED', [
    { tsUtc: T0(50), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(30), state: 'MIGRATED', outcome: 'ok' }],
    { pathCheckpoint: 'A:diskPatched',
      safety: { snapshotId: '/subscriptions/x/snapshots/prd-win-a-snap' },
      restore: { restoredUtc: T0(12), restoredBy: 'operator@example.com', note: 'application would not start',
                 newDiskName: 'prd-win-a-osdisk-restored-202608261400', diskIdChanged: true } }),
  // WAVE-SAMPLE-RUN-1: Checking found files on its temporary disk, and a person
  // decided Continue for this machine (its plan entry records the decision).
  'state/prd-win-b.json': demoDoc('prd-win-b', 'CONVERTING', [
    { tsUtc: T0(52), state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: T0(51), state: 'NEEDS_DECISION', outcome: 'fail', machineState: 'untouched',
      reasonCode: 'dataOnTempDrive',
      detail: 'The temporary disk holds 1 file that is not a system file, in the folder cache.' },
    { tsUtc: T0(41), state: 'PRECHECK', outcome: 'ok',
      detail: 'Decision resolved by operator@example.com: The files in the folder cache can be lost. The setting onDDataFound of this machine is now proceed. The machine returns to Checking.' },
    { tsUtc: T0(40), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(20), state: 'STOPPED', outcome: 'ok' },
    { tsUtc: T0(4), state: 'CONVERTING', outcome: 'ok' }], { pathCheckpoint: 'converting:started' }),
  'state/prd-ebs-a.json': demoDoc('prd-ebs-a', 'FAILED_NEEDS_ATTENTION', [
    { tsUtc: T0(45), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(28), state: 'VALIDATING', outcome: 'ok' },
    { tsUtc: T0(25), state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail',
      reasonCode: 'validationFailedAfterConversion',
      detail: 'The Verifying step failed after 3 attempts: The check of accelerated networking failed: accelerated networking is not in use on nic0.', evidenceRef: 'sample-guest-output.txt' }]),
  'state/prd-lin-a.json': demoDoc('prd-lin-a', 'GUEST_PREP', [
    { tsUtc: T0(35), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(33), state: 'GUEST_PREP', outcome: 'ok' }]),
  'state/prd-lin-b.json': demoDoc('prd-lin-b', 'PLANNED', [{ tsUtc: T0(35), state: 'PLANNED', outcome: 'ok' }]),
  'state/prd-tf-a.json': demoDoc('prd-tf-a', 'NEEDS_DECISION', [
    { tsUtc: T0(34), state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: T0(33), state: 'NEEDS_DECISION', outcome: 'fail',
      reasonCode: 'targetTooFewNics',
      detail: 'This machine has 3 network interfaces; the target size Standard_D2ds_v6 holds 2.' }]),
  'state/prd-tmp-a.json': demoDoc('prd-tmp-a', 'NEEDS_DECISION', [
    { tsUtc: T0(31), state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: T0(29), state: 'NEEDS_DECISION', outcome: 'fail', machineState: 'untouched',
      reasonCode: 'dataOnTempDrive',
      detail: 'The temporary disk holds 2 files that are not system files, in the folder exports.' }]),
  'state/prd-lin-c.json': demoDoc('prd-lin-c', 'FAILED_ROLLED_BACK', [
    { tsUtc: T0(48), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: T0(44), state: 'GUEST_PREP', outcome: 'ok' },
    { tsUtc: T0(42), state: 'STOPPED', outcome: 'ok' }, { tsUtc: T0(39), state: 'CONVERTING', outcome: 'ok' },
    { tsUtc: T0(37), state: 'STARTING', outcome: 'ok' }, { tsUtc: T0(36), state: 'VALIDATING', outcome: 'fail' },
    { tsUtc: T0(27), state: 'FAILED_ROLLED_BACK', outcome: 'fail', machineState: 'restored',
      reasonCode: 'validationFailedAfterConversion',
      // The stop as Complete-VmfRollback writes it, with Test-VmfImdsOutcome's sentence.
      detail: 'The Verifying step failed, and the product rolled the machine back to how it was: The Instance Metadata Service answered before the move and does not answer now. It answers only on the primary network interface, so that interface does not work as it did before the move.' }]),
  'capacity/storefront-pilot-d2s.json': { schemaVersion: 2, wave: 'storefront-pilot', region: 'eastus2', zone: null, size: 'Standard_D2s_v6',
    vmFamily: 'StandardDsv6Family', state: 'QUOTA_VERIFIED', blockReason: null,
    demand: { instances: 2, reservableInstances: 2, vcpus: 4, familyVcpus: 10, regionalVcpus: 4 }, quota: { limit: 10, used: 0, regionalLimit: 40, regionalUsed: 14, checkedUtc: T0(120) } },
  'capacity/billing-apps-d2s.json': { schemaVersion: 2, wave: 'billing-apps', region: 'eastus2', zone: null, size: 'Standard_D2s_v6',
    vmFamily: 'StandardDsv6Family', state: 'RESERVED', blockReason: null,
    demand: { instances: 3, reservableInstances: 3, vcpus: 6, familyVcpus: 6, regionalVcpus: 6 }, quota: { limit: 10, used: 4, regionalLimit: 40, regionalUsed: 18, checkedUtc: T0(65) },
    reservation: { createdUtc: T0(60), releasedUtc: null, consumedInstances: 0 } },
  'capacity/billing-apps-d2ds.json': { schemaVersion: 2, wave: 'billing-apps', region: 'eastus2', zone: null, size: 'Standard_D2ds_v6',
    vmFamily: 'StandardDdsv6Family', state: 'RESERVED', blockReason: null,
    demand: { instances: 2, reservableInstances: 2, vcpus: 4, familyVcpus: 4, regionalVcpus: 6 }, quota: { limit: 10, used: 2, regionalLimit: 40, regionalUsed: 18, checkedUtc: T0(65) },
    reservation: { createdUtc: T0(60), releasedUtc: null, consumedInstances: 1 } },
  'logs/events.jsonl': [
    { tsUtc: T0(75), step: 'wave', outcome: 'ok', detail: 'storefront-pilot complete' },
    // The row shows UX_STEP.reserveCap; the detail is the hover text, and a
    // sample names no region (MANUAL-REVIEW-1).
    { tsUtc: T0(60), step: 'odcr', outcome: 'ok', detail: 'Azure holds an on-demand capacity reservation for 2 machines of Standard_D2ds_v6.' },
    { tsUtc: T0(33), step: 'PRECHECK', outcome: 'ok', vmId: SUB + 'prd-tf-a' },
    { tsUtc: T0(30), step: 'azureops:odcrAssociate', outcome: 'ok', vmId: SUB + 'prd-win-a' },
    { tsUtc: T0(25), step: 'validate', outcome: 'fail', vmId: SUB + 'prd-ebs-a', detail: 'network fabric check' },
    { tsUtc: T0(8), step: 'azureops:diskPatch', outcome: 'ok', vmId: SUB + 'prd-win-b' },
    { tsUtc: T0(4), step: 'checkpoint', outcome: 'info', vmId: SUB + 'prd-win-b', detail: 'converting:started' },
    { tsUtc: T0(2), step: 'worker', outcome: 'info', vmId: SUB + 'prd-lin-a', detail: 'leased by worker-3' },
  ],
};
// RETAIN-UX-1: the sample machines carry safety copies, so the card has
// something to say on the demo page - one of each state.
(() => {
  const S = (name, locked = true) => ({ pristineSnapshotId: `/snap/${name}-pristine`, snapshotId: `/snap/${name}`,
                                        pristineSnapshotLocked: locked, snapshotLocked: locked, cloneVmId: null, locksAllowed: true });
  DEMO['state/can-win-a.json'].safety = S('can-win-a');                                   // kept, locked
  // MANUAL-SHOTS-1: the disks the machine had, and a copy of its data disk, so
  // Restore this machine names each disk that keeping the names would delete.
  DEMO['state/can-win-a.json'].safety.pristineDataCopies = [{ lun: 0, snapshotId: '/snap/can-win-a-data0-pristine', locked: true }];
  DEMO['state/can-win-a.json'].safety.dataCopies = [{ lun: 0, snapshotId: '/snap/can-win-a-data0', locked: true }];
  // IDENTITY-LOSS-1: its system-assigned identity. The move was in place, so it kept that account.
  DEMO['state/can-win-a.json'].captured = { vmConfig: { size: 'Standard_D2ds_v4', identityType: 'SystemAssigned',
    identity: { type: 'SystemAssigned', principalId: '11111111-2222-3333-4444-555555555555', userAssignedIds: [] },
    osDisk: { name: 'can-win-a-osdisk' }, dataDisks: [{ lun: 0, name: 'can-win-a-data0', skuName: 'Premium_LRS' }] } };
  DEMO['state/can-lin-a.json'].safety = S('can-lin-a');
  DEMO['state/can-lin-a.json'].retention = { deletedUtc: T0(30), deletedBy: 'retention (scheduled)', keepDays: 0 };
  DEMO['state/prd-win-a.json'].safety = S('prd-win-a', false);                            // kept, no lock
  DEMO['state/prd-win-b.json'].safety = { pristineSnapshotId: '/snap/prd-win-b-pristine', snapshotId: null,
                                          pristineSnapshotLocked: true, snapshotLocked: null, cloneVmId: null, locksAllowed: true };
})();// RESTORE-PANEL-TIMELINE-1: the machine panel lists the machine's lines of the
// run history, so the sample log has the closing line of each step that the
// sample histories record, as Invoke-VmfStateMachine writes it: a history
// entry is written when a step ends, so the step before it closes at its time.
(() => {
  const lines = DEMO['logs/events.jsonl'];
  for (const [key, doc] of Object.entries(DEMO)) {
    if (!key.startsWith('state/') || !Array.isArray(doc?.history)) { continue; }
    doc.history.forEach((h, i) => {
      const before = doc.history[i - 1];
      if (!before || !Object.prototype.hasOwnProperty.call(UX_RAN, before.state)) { return; }
      // A step fails only into a stop; a sample entry marked fail on the way is a step that went on.
      const failed = h.outcome === 'fail' && TERMINAL_STATES.includes(h.state);
      lines.push({ tsUtc: h.tsUtc, step: before.state, outcome: failed ? 'fail' : 'ok', vmId: doc.vmId });
    });
  }
  lines.sort((a, b) => Date.parse(a.tsUtc) - Date.parse(b.tsUtc));
})();
const DEMO_ROOT = {
  'retention-status.json': { schemaVersion: 1, lastPassUtc: T0(500), runsExamined: 3, runsWithCopiesDue: 1, machinesDue: 1,
                             executionsStarted: [{ runId: VmfHelp.sampleRun.runId, machines: 1, execution: 'vmf-engine-sample-r1' }], failures: [] },
};
const DEMO_TEXT = {
  'evidence/sample-guest-output.txt': '{"schema":"vmf.guest/1","script":"Set-NvmeReady.ps1","version":"1.0.0","result":"FIXED","checks":[{"name":"boot driver","status":"FIXED","detail":"enabled on every configuration set"}]}',
};

boot().catch(e => { $('#err').textContent = `The dashboard could not start: ${VmfHelp.explain(e)}`; $('#err').style.display = 'block'; });
