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

/* ============================ UX-STRINGS-BEGIN ============================
   The whole flow in the reader's words. Same bar as every other page. */
const UX = {
  demoViewer: 'Sample viewer',
  stepsAssess: ['Which work', 'Where to look', 'What the scan found', 'Review it'],

  // PROJECT-1: the entry point for a customer was unclear, and whether a
  // project had to be created first was stated nowhere. Three of the four
  // doors into this wizard skipped projects entirely, so
  // the obvious blue button produced work that belonged to nothing.
  //
  // ONE front door now, and this is its first question. Asked here rather than
  // as a separate errand on another page, and never auto-created - the whole
  // value of a project is that a PERSON names it, which a generated name
  // destroys.
  s0Title:    'Which project is this for?',
  s0Body:     'A project holds one estate - its assessments, and the migrations planned from them.',
  s0Existing: 'Project',
  s0OrNew:    'Or create a new project',
  s0Name:     'Project name',
  s0IdHint:   'Address:',
  s0Create:   'Create and continue',
  s0Pick:     'Continue',
  s0NeedName: 'Enter a project name.',
  s0None:     'You have no projects yet. Create your first one below.',
  // COLD-1: shown while the project list is fetched. The first request after
  // an idle period can take half a minute, and a blank panel reads as broken.
  s0Loading:  'Loading your projects.',
  // WIZARD-PROJECTS-ERROR-1: the list could not be read. This said "You have
  // no projects yet" and offered the create form. The service's own sentence
  // is the page error above, through failRead.
  s0ReadFailed: 'The product could not read the list of projects.',
  s0Retry:      'Try again',
  s2CanMigrate: 'can migrate',
  s2Cannot:     'cannot yet',
  // ALREADY-CURRENT-1: the machines on a size in the Current lifecycle stage.
  s2Current:    'Current',
  aReviewOpenWhere: 'The same report is on the Assessments page whenever you want it again.',
  // TEMPPOOL-1. Information, not a decision - so it sits next to the waves
  // rather than becoming another question to answer.
  tempLoseTitle: 'These machines lose their temporary disk',
  // LAB-UX-1: a Linux machine has no D: drive, so the drive letter is a
  // sentence of its own, shown only when a Windows machine is in the list.
  tempLoseBody:  'Their target size has no local temporary disk, so the machine loses the one it has. Anything that writes there needs another place to write.',
  tempLoseWindows: 'On Windows, the D: drive goes away.',
  tempGainTitle: 'These machines gain extra local drives',
  tempGainBody:  'Their target has more local NVMe disks than the single temporary disk they have now. The product combines them into one temporary disk at every start.',
  tempGainWindows: 'On Windows, that drive is D:.',
  tempUnknown:   'For some machines the size catalog did not report a temporary disk count, so this list may be incomplete.',
  tempCol:       'now / after',
  aReviewTitle: 'Review what the scan found',
  aReviewBody:  'Read what this assessment found, then accept it. A migration can only be planned from an accepted assessment.',
  aReviewOpen:  'Open the full report',
  // "What did you conclude" was a required free-text riddle standing between
  // a person and the next step. The note is
  // worth keeping as a record, but this gate only unlocks PLANNING; the gate
  // that authorises anything destructive is the wave approval, which still
  // requires one. So: optional, and asked plainly.
  aReviewNote:  'Anything to note for whoever picks this up later? Optional.',
  aReviewBtn:   'I have reviewed this',
  aReviewedBy:  'Reviewed by',
  rColTargets:  'Can migrate to',
  rNoTarget:    'None',
  rStops:       'What stops it',
  rFirst:       'What happens first',
  rApplies:     'Applies to {series}.',
  rNothing:     'Nothing stops this machine.',
  // DETECT-PATTERNS-1: the workload type of each machine, its facts, and the warnings.
  rColWorkload: 'Workload type',
  rCheck:       'What to check before the move',
  rFacts:       'How the workload type was found',
  aPlanNext:    'Plan a migration from this',
  aDoneTitle:   'This assessment is ready',
  aDoneBody:    'It has been reviewed, so a migration can be planned from it. Planning is a separate step - nothing here has changed a machine.',
  aBlockedNote: '{n} machines cannot migrate yet. A migration planned from this assessment does not move them.',
  aBlockedNoteOne: '{n} machine cannot migrate yet. A migration planned from this assessment does not move it.',
  s1Title: 'Where does the scan look?',
  s1Body: 'The scan looks for virtual machines that can move to a newer size. It only reads, and it changes nothing.',
  runName: 'Name for this assessment',
  runNameBad: 'Use only lowercase letters, numbers and dashes.',
  acceptTitle:  'How this wave will run',
  /* PLANRUN-1: one sign-off for the plan, and one choice of how it runs.
   * RUNSTEP-1's "Starting wave-2 - the first of 8 waves" and "the other waves
   * wait" described the model this replaces: one wave started here, the rest
   * started by hand. */
  signTitle:   'Sign off the plan',
  /* WAVE-APPROVE-1: the sign-off is one approval for each wave, so a change
   * to one wave asks again for that wave only. */
  signBody:    'The sign-off approves each wave in this plan. If a wave changes after this, that wave needs a sign-off again.',
  signBtn:     'Sign off all {n} waves',
  signBtnOne:  'Sign off the plan',
  signBusy:    'Signing off...',
  signedBy:    'Signed off by {who}',
  signStale:   'These waves changed after the sign-off: {waves}. Sign off the plan again.',
  waveApprovedBy: 'Approved by {who}',
  waveSignStale:  'This wave changed after the sign-off. It needs a sign-off again.',
  signNeedsApprover: 'An approver signs off the plan. Ask a user with the approver role.',
  signFirst:   'Sign off the plan first',
  howTitle:    'How should this run?',
  howAll:      'Run it all now',
  // STARTS-SOON-WORDS-1: the service starts the next wave on a check, and a
  // check of a large store takes more than one pass (TIMER-PASS-LIMIT-1). The
  // why is the migrations page's startsSoonHelp, word for word.
  // WAVE-ORDER-START-1: the outcome, as the Migrations page says it.
  howAllHint:  'When a wave finishes, the next wave starts within about 5 minutes.',
  howCheckAbout: 'About the next check',
  howCheckHelp: 'The service starts the wave at its next check. It checks every 5 minutes. When many migrations wait, it can take longer.',
  howTimes:    'Give some waves a start time',
  howTimesHint:'Waves without a time follow the one before.',
  startsNow:   'starts now',
  followsLine: 'starts when {wave} finishes',
  holdNote:    'If a machine stops and waits for a person, the run stops after its wave until the machine is dealt with.',
  startPlanBtn:'Start the plan',
  // LAB-UX-1: starting the engine can take a minute, and a grey button with
  // no words read as nothing happening.
  startPlanBusy:'Starting the plan...',
  machine:      'machine',
  machines:     'machines',
  // WAVE-FLOW-1: which wave runs when Start is pressed. The others are shown
  // so nothing is hidden, and can be accepted here or when their turn comes.
  waveNext:     'Runs next',
  acceptBtn:    'Accept these settings',
  // ACCEPT-BULK-1: a disabled button that still reads "Accept these settings"
  // looks broken for the three to five seconds the store read takes.
  acceptBusy:   'Accepting...',
  // And seven waves is seven of those. An estate shaped by resource group has
  // one wave per group, so this is the normal shape, not a large one.
  acceptAllBtn:  'Accept all {n} waves',
  acceptAllBusy: 'Accepting {i} of {n}...',
  // The plan IS what an acceptance signs. If it cannot be read there is
  // nothing to bind the agreement to, so say so rather than record agreement
  // to settings nobody read.
  acceptNoPlan: 'The plan for this migration could not be read, so these settings cannot be accepted yet. Open the page again in a moment.',
  acceptEdit:   'Change them first',
  // DECIDE-ROLE-1: the reason there is no accept button, said on the screen.
  acceptNeedsOperator: 'An operator accepts the settings of each wave. Ask a user with the operator role.',
  // WIZARD-START-ROLE-1: the reason there is no Start the plan button.
  startNeedsOperator: 'An operator starts the plan. Ask a user with the operator role.',
  // WIZARD-ROLES-2: the reason a step has no action button.
  stepNeedsOperator: 'An operator does this step. Ask a user with the operator role.',
  reviewNeedsApprover: 'An approver accepts the review. Ask a user with the approver role.',
  // ASSESS-APPROVAL-HASH-1: why I have reviewed this is not offered to an approver.
  aReviewNoVersion: 'The product did not read this scan again. Reload the page, then approve the scan.',
  // WIZARD-ROLES-3: a user without the operator role exports what is saved.
  tExportNoneSaved: 'No targets are saved yet. An operator saves them on this step.',
  tExportNotCurrent: 'The saved targets are not the targets on this step. An operator saves them again.',
  acceptedBy:   'Accepted by',
  acceptFirst:  'Accept the settings above first',
  lvCopy:       'Snapshot of every disk before anything is changed',
  lvCopyAlways: 'Always taken',
  lvCapacity:   'On-demand capacity reservation for this wave',
  // WAVE-WORDS-3: every setting and value by the name the wave editor gives it.
  lvCapOnDemand:'No',
  lvCapReserved:'Yes',
  lvData:       'If files are found on the temporary disk',
  lvDataStop:   'Stop and ask',
  lvDataProceed:'Continue - the files are deleted',
  lvKeep:       'How long the snapshot is kept',
  lvKeepNever:  'Deleted by the next daily cleanup after the machine is migrated',
  lvKeepOne:    '1 day after the machine is migrated',
  lvKeepMany:   '{n} days after the machine is migrated',
  lvAtOnce:     'How many machines at once',
  lvApproval:   'Someone must sign off before this wave runs',
  // REBUILD-REMOVE-ACCEPT-1: the rows for a rebuild and for a new identity are
  // gone with the rebuild. A list of machines, with their names:
  lvNamesOne:   '1 machine: {names}',
  lvNamesMany:  '{n} machines: {names}',
  // TEMP-DISK-PREVIEW-1: the machines of the wave that take the in-place upgrade (Preview).
  lvPreview:    'Machines that need the preview feature VMTempDiskResizePreview',
  lvAn:         'Machines that get accelerated networking turned on',
  lvAnDecides:  'Machines where the move decides accelerated networking',
  lvKernel:     'Machines whose kernel the product updates if it has no MANA driver',
  // WIZARD-OPTIONS-DISKS-1: the words of Review & accept options on the
  // migration's page. Each change is said in the words of tDiskChoice.
  lvDisks:      'Machines whose disks change to Standard SSD or Premium SSD',
  lvDiskMachine: '{name} ({type})',
  lvNone:       'None in this wave',
  // ROLLBACK-CAPACITY-1: one line for a wave that holds a machine whose
  // original size is in a series with restricted capacity (help.js
  // signOffRiskLines). The same words as Review & accept options.
  lvCapacityNoGuarantee: 'Microsoft restricts capacity growth for the original size series of a machine in this wave. The product does not guarantee capacity for the new size. On a rollback, the product does not guarantee capacity for the original size.',
  // FILTER-DRIVER-READ-1: one line for a wave that moves a machine to NVMe
  // (help.js signOffRiskLines). Microsoft's sentence word for word, from its NVMe
  // page for Linux, then what it means for the move.
  lvNvmeThirdParty: 'Microsoft says: "Customized VMs that run third-party software capable of modifying boot-time behavior, storage drivers, filter drivers, or disk enumeration aren\'t currently a supported migration scenario."',
  lvNvmeThirdPartyWhat: 'If such a machine moves to NVMe, the move can fail. Then the product rolls the machine back. To keep SCSI, choose v5 for that machine.',
  // DISK-PATH-READ-1: what the product checks of disk names on a move to NVMe, and what it does not.
  lvNvmeDiskPaths: 'On Linux, the product checks the mounted volumes and the fstab file. The product does not check application settings that name a disk by a device path. Examples are /dev/sdc and a link under /dev/disk/azure/scsi1. Before the move, check these settings. Microsoft tells you to use a UUID in them.',
  // SQL-TEMPDB-SIGNOFF-1: one line for a wave with a machine where the scan
  // found SQL Server that moves to an NVMe temporary disk or none (help.js
  // signOffRiskLines). The same words as Review & accept options.
  lvSqlTempdb: 'SQL Server runs on {names}. The target size of each has an NVMe temporary disk or no temporary disk. If tempdb is on the temporary disk, SQL Server can fail to start after the move.',
  lvYes:        'Yes',
  lvNo:         'No',
  whenPast:     'Pick a time in the future.',

  watching:     'Checking that the wave started...',
  watchingStarted: 'It has started. Opening the run.',
  watchingSlow: 'It has not reported back yet. Open the run page to see where it is.',
  // PROGRESS-1: what the scan is doing, while it does it.
  scanFound:  'Found {n} machines. The scan is finding which of them can move.',
  scanFailed: 'The scan stopped. {reason}',
  // SCAN-FAIL-SHOWN-1: what to do once the scan stopped (scanStoppedHtml).
  scanAgain:  'To start the scan again, select Back, and then select Start looking.',
  // CLAIM-AT-PLAN-1: the words the Migrations page says for a refused start
  // (nextFailed with nextFailedWave), so the two pages say one thing.
  refused:      'The start of a wave did not work. {reason}',
  // LAB-UX-1: the hint states the rule the name is checked against, before
  // a name is refused. It said any name was good.
  runNameHint: 'Use only lowercase letters, numbers and dashes. This name is how you recognise it later.',
  runNameTaken: 'Something is already called {name}. Choose a different name. A name is how you tell two of them apart, and the same name would replace what is there.',
  scopeType: 'Look in',
  scopeRgOpt: 'Resource groups',
  scopeSubsOpt: 'Chosen subscriptions',
  scopeMgOpt: 'Everything under a management group',
  subLabel: 'Subscription',
  rgLabel: 'Resource groups in this subscription',
  subsLabel: 'Subscriptions',
  mgLabel: 'Management group',
  loading: 'Loading...',
  // LOADING-LINE-1: the page while it reads the run a link opened.
  runReading: 'Reading the assessment or the migration that you opened.',
  noneVisible: 'None are visible. The service needs read access before it can list them.',
  scopeMissing: 'Choose where to look first.',
  s1Go: 'Start looking',

  s2Title: 'What the scan found',
  s2Body: 'Everything the scan looked at. Nothing here has been changed.',
  // PROGRESS-1: this used to add "You can leave this page and come back",
  // which argues with the sentence before it - a wait of a minute or two is
  // one to sit through, and sending somebody away at the moment the screen
  // starts reporting what it found is the opposite of what it is for.
  // Leaving still works, because the scan runs in the engine and this page
  // reads the run when it opens. That is reassurance for somebody who already
  // left, not an invitation to go.
  s2Working: 'Looking for machines.',
  colMachine: 'Virtual machine',
  colWhere: 'Resource group and region',
  colSize: 'Current size',
  colCan: 'Can it migrate?',
  colNeeds: 'What it needs',
  s2None: 'This scan found no virtual machines.',
  s2NoneWhere: 'It looked in:',
  s2NoneIn:        'inside subscription ',
  s2NoneInGroup:   'inside management group ',
  s2NoneWholeSub:  'the whole subscription ',
  s2NoneWholeSubs: 'these whole subscriptions: ',
  s2NoneWholeGroup:'the whole management group ',
  s2NoneWhy: 'Either there are none here, or the service cannot see them yet. The service reads as itself, so it finds only the machines you have granted it access to. Select Back and choose another place, or check the access.',
  s2NoneAgain: 'Look somewhere else',
  // MANUAL-SHOTS-1: it opens the review step. It said "Group these into
  // waves" from before assessing and migrating were two journeys, and no wave
  // is made from this step.
  s2Next: 'Review it',

  // MACHINE-PICK-1: the first step of a migration. A large scan finds many
  // machines that are not meant to move. Nothing is chosen at first.
  mTitle: 'Choose the machines',
  mBody: 'The assessment found {n} machines in {subs} subscriptions. Select the machines that this migration moves.',
  mBodyOneSub: 'The assessment found {n} machines in 1 subscription. Select the machines that this migration moves.',
  mSub: 'Subscription',
  mRg: 'Resource group',
  mTag: 'Tag',
  mFind: 'Find by name',
  mAny: 'All',
  mAddShown: 'Add the {n} machines shown',
  mAddShownOne: 'Add the machine shown',
  mRemoveShown: 'Remove the machines shown',
  mCount: '{x} of {y} machines in this migration',
  mColMachine: 'Machine',
  mColTags: 'Tags',
  mColAssess: 'Assessment',
  mPick: 'Select {name}',
  grpCan: 'Can migrate',
  grpSome: 'Some targets only',
  grpCannot: 'Cannot yet',
  grpCurrent: 'Current',
  mNoMatch: 'No machine matches these filters.',
  mEmpty: 'This assessment has no machine that a migration can move.',
  mNoOption: 'The target options have no size for this machine.',
  // CLAIM-AT-PLAN-1: a machine another migration holds, and the start check
  // (Test-VmfVmClaims) would refuse. The way to free it is the engine's own
  // (Get-VmfOtherRunClaimRefusal). A skip or a stop keeps the claim of a machine left changed
  // (SKIP-CHANGED-FREED-1), so the words say "with no change on it".
  mHeld: 'The migration {run} holds this machine. It is free after that migration migrates it, or skips or stops it with no change on it, or after you delete that migration.',
  mHeldUnknown: 'The page could not read which machines other migrations hold. Start checks this again before it changes a machine.',
  mShowMore: 'Show more',
  mShowFewer: 'Show fewer',
  mNone: 'Select at least one machine, then continue.',
  mContinue: 'Continue',
  mSaved: 'The machines are saved.',

  // ADVISOR-1: the second step of a migration. The options only, one line each;
  // the details sit behind a Details button on every row.
  tTitle: 'Choose each target',
  tBody: 'Each machine moves to the target you choose here. Start from a default, then change any machine.',
  tDefault: 'Default lifecycle stage',
  tCurrent: 'Current',
  tExtended: 'Extended',
  // TARGETS-HINTS-1: the hint under each stage, built from T_START_ORDER.
  tStartOrder: 'Each machine starts on the first of {a}, {b} and {c} that it can take.',
  // STAGE-HINT-WORDS-1 (approved words, 2026-11-13): Current's last choice is in
  // the Extended stage, and "the first of v6, v7 and v5" did not say so.
  tStartCurrent: 'Each machine starts on {a}, or on {b} when {a} does not fit. A machine that can take neither starts on {c}, in the Extended stage.',
  tStartBsv2: 'A B v1 machine starts on Bsv2 when a Bsv2 size fits it.',
  tSummary: '{n} machines: {parts}.',
  // ADVISE-AN-1: why each group is not on the default, behind the (?) of the
  // summary - from the advice, never invented.
  tSumAbout: 'About these counts',
  tGroupLine: '{part}: {why}',
  tWhyGen1: 'Generation 1 machines cannot use v6 or v7.',
  tWhyBsv2: 'B v1 machines move to the burstable Bsv2 series.',
  tWhyAn: 'Accelerated networking stops on {series}, and this series keeps it.',
  tWhyPerson: 'You changed the series of these machines in their own list.',
  tWhyNot: '{series} is not available for them: {why}.',
  tWhyNone: 'Details shows the reason for each machine.',
  // A size list that mixes processor makers names the maker of each size.
  tSizeMaker: '{size} ({maker})',
  tOn: '{n} on {series}',
  tNoneCount: '{n} with no target',
  colGen: 'Generation',
  vGen1: 'Generation 1',
  vGen2: 'Generation 2',
  // REBUILD-PICKER-1: the list names the series AND the kind of change, and the
  // text in brackets is the cue without colour. REBUILD-REMOVE-PLAN-1: every
  // kind of change is the in-place upgrade, with or without the preview feature.
  colTarget: 'Series and kind of change',
  tOptionLabel: '{series}: {kind}',
  tOptionPill: '{label} ({pill})',
  tPillRec: 'Recommended',
  // The counts above the table, and the facts behind their (?).
  tCountsInPlace: { one: '1 machine takes an in-place upgrade.', many: '{n} machines take an in-place upgrade.' },
  tMethodAbout: 'About the in-place upgrade and the Preview',
  tMethodHead: { what: 'What happens', carries: 'What carries over', when: 'When', rollback: 'Rollback' },
  tMethodFacts: {
    'in-place': { what: 'The existing machine is changed where it stands.', carries: 'The machine, its extensions and the links from other services.', when: 'The kind of temporary disk stays the same, the machine runs Linux, or it moves between no temporary disk and an NVMe one.' },
    // TEMP-DISK-PREVIEW-1: the in-place upgrade with the preview feature.
    preview: { what: 'The existing machine is changed where it stands, from a SCSI temporary disk to another kind of temporary disk.',
      carries: 'The machine, its extensions and the links from other services.',
      when: 'A Windows machine changes the kind of temporary disk. The preview feature VMTempDiskResizePreview must be registered on the subscription.' },
  },
  // TEMP-DISK-PREVIEW-1: the in-place upgrade with the preview feature
  // VMTempDiskResizePreview, for a Windows machine with a SCSI temporary disk.
  // The product reads the feature and never registers it.
  tPillPreview: 'Preview',
  tPillPreviewOff: 'Preview, feature needed',
  // TARGETS-ALIGN-1: the fact of one row, under its series list. The feature
  // is a fact of the subscription, so it is in the box above the table.
  tPreviewFact: 'Same machine.',
  tPreviewCheck: 'Check again',
  tPreviewReading: 'Reading the preview feature on subscription {sub}.',
  tPreviewAbout: 'About the preview feature',
  // PREVIEW-RG-SCOPE-1: the box of a subscription
  // where the machines' target is the in-place upgrade (Preview) and the
  // product cannot read the feature state (A), or reads it as not registered
  // (B). The steps are list items, numbered by the list.
  tPvNotRead: { one: '1 machine in subscription {sub} moves by the in-place upgrade (Preview). The product cannot read if the preview feature VMTempDiskResizePreview is registered.',
    many: '{n} machines in subscription {sub} move by the in-place upgrade (Preview). The product cannot read if the preview feature VMTempDiskResizePreview is registered.' },
  tPvCode: 'Error code from Azure: {code}.',
  // PREVIEW-ACCESS-WORDS-1: shown only on AuthorizationFailed. It says what
  // Azure did, not that the product needs the subscription: with the roles on
  // one resource group only, the read worked (measured 2026-11-13). Assess on
  // the subscription, the step below, covers the read (TEMP-DISK-PREVIEW-ROLE-1).
  tPvAuthWhy: 'Azure registers a preview feature for the whole subscription. Azure did not let the product read the feature state.',
  tPvAuthStep: 'Open the Admin page. Under Where the product may work, give Assess on subscription {sub}.',
  tPvCheck: 'Select Check again.',
  tPvOff: { one: '1 machine in subscription {sub} moves by the in-place upgrade (Preview). The preview feature VMTempDiskResizePreview is not registered in this subscription.',
    many: '{n} machines in subscription {sub} move by the in-place upgrade (Preview). The preview feature VMTempDiskResizePreview is not registered in this subscription.' },
  tPvWho: 'A user with the Contributor or Owner role on the subscription registers it:',
  tPvReg1: 'In the Azure portal, open Subscriptions, then {sub}.',
  tPvReg2: 'Select Preview features. Find VMTempDiskResizePreview and select Register.',
  tPvReg3: 'Wait about 10 minutes, then select Check again.',
  tPvV5: 'To move these machines without the preview feature, choose a v5 target. A v5 size keeps a SCSI temporary disk and needs no preview feature.',
  // TARGETS-ALIGN-1: the box of a subscription where the feature is registered.
  tPreviewOn: { one: '1 machine takes the in-place upgrade (Preview). It needs the preview feature VMTempDiskResizePreview on subscription {sub}. The feature is registered.',
    many: '{n} machines take the in-place upgrade (Preview). It needs the preview feature VMTempDiskResizePreview on subscription {sub}. The feature is registered.' },

  tPreviewWhat: 'Azure resizes a Windows machine in place from a SCSI temporary disk to another kind of temporary disk only with this preview feature.',
  tPreviewNotTool: 'The product does not register the feature. A user with the Contributor or Owner role on the subscription registers it.',

  tPreviewKeep: 'Keep the feature registered until the move is complete. A rollback to the original size needs it too.',

  tCountsPreview: { one: '1 machine takes an in-place upgrade (Preview).', many: '{n} machines take an in-place upgrade (Preview).' },
  colNewSize: 'Target size',
  tNoTarget: 'No target',
  tDetails: 'Details',
  tClose: 'Close',
  tSave: 'Save the targets',
  // CLICKS-LOST-1: the button says it works at once (SAVE-TARGETS-FEEDBACK-1).
  tSaving: 'Saving the targets...',
  // OLD-SKU-1A: two areas, a Region column, and Export for pricing.
  colRegion: 'Region',
  // TARGETS-AREAS-1: the areas are named for how the target is chosen, not for
  // the generation. A Generation 2 machine on an older size is in the second.
  // The generation is a column on every row.
  tAreaSame: 'Same size, newer version',
  tAreaShape: 'Choose a family and size',
  tAreaShapeHelp: 'Generation 1 machines, and sizes in the B v1, A v1, Av2, Amv2, D and DS v1 and v2, F, Fs and Fsv2 families.',
  tFamily: 'Size family',
  tFamilies: { Bsv2: 'Bsv2 (burstable, with CPU credits)', Dl: 'Dl (general purpose, less memory)', D: 'D (general purpose)', E: 'E (memory optimized)' },
  tConstrained: '{size}, {n} active vCPUs',
  tDisks: 'Disks',
  // HDD-OS-1: Standard SSD for an OS disk that is Standard HDD, on every size.
  tDiskChoice: { keep: 'Keep the disk types', 'os-standard-ssd': 'Standard SSD: OS disk', os: 'Premium SSD: OS disk', all: 'Premium SSD: every disk' },
  // MANA-LINUX-KERNEL-1: what the move does when the kernel of a Linux machine
  // has no MANA driver. KERNEL-UX-1: one choice per machine, in its Details, and
  // a notice with one button for all the machines still to check.
  tKernelChoice: { stop: 'Stop and ask', update: 'Update the kernel' },
  // KERNEL-CHOICE-WORDS-1 (approved words, 2026-11-14): what the product
  // does IF Checking finds the kernel below the minimum - not a finding.
  tKernelAlert: 'The product reads the kernel of each Linux machine at Checking. Choose what it does if the kernel has no MANA driver for the new size.',
  tKernelCheck: 'Network driver choice to check',
  // TEMPDISK-UX-1: a size with no temporary disk, on a machine that has one now -
  // a tag under the size, the same dot on Details, and a notice.
  tTempAlert: 'Temporary disk: a machine with a dot on its Details loses its temporary disk on the size you chose. On Windows, drive D: is removed.',
  tTempCheck: 'Temporary disk to check',
  tTempTag: 'No temporary disk',
  // SIZE-FALLTHROUGH-NOTE-1: why the size with a temporary disk is not the
  // target, behind a (?) on the temporary disk row in Details. One sentence for
  // each code the engine sends in sizesNotTaken (Get-VmfSizeNotTakenNote says the same).
  tNotTakenAbout: 'Why the size has no temporary disk',
  tNotTaken: {
    'not-listed': 'The product did not use {size}, because Microsoft does not list it.',
    'not-in-region': 'The product did not use {size}, because this region does not offer it.',
    'not-approved': 'The product did not use {size}, because it is not a target size that the product offers.',
    'gen1-no-size': 'The product did not use {size}, because it does not take Generation 1 machines.',
    'too-few-nics': 'The product did not use {size}, because it holds fewer network interfaces than this machine has.',
    'too-few-data-disks': 'The product did not use {size}, because it holds fewer data disks than this machine has.',
    'smaller-than-source': 'The product did not use {size}, because it has fewer vCPUs or less memory than this machine.',
    'shape-unknown': 'The product did not use {size}, because the catalog of this region does not give its vCPUs and memory.',
    'one-accelerated-nic': 'The product did not use {size}, because it allows accelerated networking on one network interface only. This machine has accelerated networking on more than one.',
  },
  tNotTakenAny: 'The product did not use {size}.',
  tNotTakenTarget: 'The target is {target}.',
  tNotTakenPreview: 'This size changes the kind of temporary disk, so the move is the in-place upgrade (Preview).',
  // ADVISE-AN-1: a size where the accelerated networking the machine uses now
  // stops working - a tag under the size, the same dot on Details, a notice,
  // and why behind a (?) on the row in Details.
  tAnAlert: 'Accelerated networking: a machine with a dot on its Details loses accelerated networking on the size you chose. Microsoft does not list its Linux release for MANA.',
  tAnCheck: 'Accelerated networking to check',
  tAnTag: 'Accelerated networking off',
  // SQL-TEMPDB-SIGNOFF-1: under the size of a machine where the scan found SQL
  // Server, when that size has an NVMe temporary disk or none (tSqlRisk).
  tSqlTag: 'Check where SQL Server keeps tempdb',
  // ADVISE-AN-1: nothing unknown on this step - where the release of a
  // machine could not be read while it ran, the screen says what to do.
  vStartAssess: 'Start the machine, then assess again.',
  // The rule behind every accelerated networking (?), and its table.
  tAnRule: 'Accelerated networking after the move depends only on the Linux release and on the network adapter of the target size. The number of network interfaces does not change it.',
  tAnRuleHead: { size: 'Target size', adapter: 'Network adapter', listed: 'Release on the MANA list', unlisted: 'Release not on the MANA list', windows: 'Windows' },
  tAnRuleSize: { v6: 'v6', v7: 'v7', amd: 'AMD v5', intel: 'Intel v5', bsv2: 'Bsv2' },
  tAnRuleAdapter: { v6: 'MANA', v7: 'MANA', amd: 'Mellanox', intel: 'MANA or Mellanox, by host', bsv2: 'MANA or Mellanox, by host' },
  tAnRuleNotOffered: 'Not offered',
  tAnRuleNic: 'A size with 2 vCPUs allows accelerated networking on one network interface only. That is a different rule.',
  // AN-MANA-DRIVER-RULE-1: a Linux release with no MANA driver possible gets no
  // size that can give the MANA adapter. Details name the release to upgrade to.
  tManaUpgrade: 'Microsoft does not list {release} for MANA, so this machine cannot move to a size that can give the MANA adapter. Upgrade the operating system to {upgrade} or a later release, then assess again.',
  tManaUpgradeAny: 'Microsoft does not list {release} for MANA, so this machine cannot move to a size that can give the MANA adapter. Upgrade the operating system to a release that Microsoft lists for MANA, then assess again.',
  dProc: 'Processor',
  tAvailableAnOff: 'Available: {size}. Accelerated networking is off on this size.',
  tAnKeepAbout: 'About accelerated networking on this size',
  tAnKeepHelp: {
    unlisted: 'This machine uses accelerated networking. On this size, accelerated networking uses the MANA adapter only. Microsoft does not list {release} for MANA, so accelerated networking does not work after the move. A kernel update does not change the release.',
    host: 'This machine uses accelerated networking. An Intel v5 host gives the MANA adapter or Mellanox, by region and by host. Microsoft does not list {release} for MANA. On a MANA host, accelerated networking does not work.',
    'image-unlisted': 'This machine uses accelerated networking. The machine was stopped during the assessment, so the Azure Linux Agent reported no release. Its image is {release}, which is not on the MANA list. Start the machine, then assess again.',
    'release-unknown': 'This machine uses accelerated networking. The product cannot read its Linux release, because the machine was stopped during the assessment or has no Azure Linux Agent. Start the machine, then assess again.',
    'size-unreadable': 'The product cannot read this size name, so it cannot say which network adapter the size gives.',
  },
  tAnFrom: { agent: 'The Azure Linux Agent in the machine reported this release.', image: 'This release comes from the image of the machine. An upgraded machine can have a later release.' },

  tDistros: { ubuntu: 'Ubuntu', rhel: 'Red Hat Enterprise Linux', sles: 'SUSE Linux Enterprise Server', debian: 'Debian', ol: 'Oracle Linux', almalinux: 'AlmaLinux', rocky: 'Rocky Linux', azurelinux: 'Azure Linux', centos: 'CentOS' },
  tCountOne: '{count} machine',
  tCountMany: '{count} machines',
  tKernelAll: { stop: 'All: stop and ask if the MANA driver is missing', update: 'All: update the kernel if the MANA driver is missing' },
  tKernelTitle: 'MANA network driver for {name}',
  tKernelWhy: 'On this target, accelerated networking can use the MANA adapter. Linux gets the MANA driver from its kernel. A kernel below the minimum version that Microsoft lists has none.',
  tKernelHint: { stop: 'The product does not update the kernel. If the kernel has no MANA driver, the machine stops before anything is changed.', update: 'If the kernel has no MANA driver, the product updates it. If no update is possible, the machine stops before anything is changed. If the update fails, the product rolls the machine back.' },
  tKernelAbout: 'About the kernel update',
  // RHEL-EUS-TARGET-NOTE-1: a machine made from a RHEL image on the EUS
  // repositories (eusImage of the target advice). Neutral: it never tells a
  // person to leave EUS.
  tKernelEus: 'This machine was made from a Red Hat EUS image, {image}, and runs RHEL {release}. EUS repositories hold updates for one minor release only, so Update the kernel finds no RHEL {listed} kernel. MANA needs RHEL {listed} or later. To use this target, move the machine to RHEL {listed} before the move, on EUS or non-EUS repositories.',
  tKernelHelp: 'This choice is for a Linux machine whose target can use MANA. Linux gets the MANA driver from its kernel. A kernel below the minimum version that Microsoft lists counts as one with no MANA driver. With Update the kernel, the product updates the kernel with the package manager of the distribution, after the first safety copy. Then it stops and starts the machine and checks the driver again. If no update is possible, the machine stops before anything is changed. If the update fails or the driver is still missing, the product rolls the machine back from the first safety copy. A Linux release that Microsoft does not list for MANA always stops. The update uses only the repositories that the machine uses. A Red Hat Enterprise Linux pay-as-you-go image for one minor release, such as RHEL 9.4, uses the EUS repositories. They have no kernel of a later minor release. Move such a machine to the RHEL release that Microsoft lists for MANA before the move, on EUS or non-EUS repositories.',
  tAreaHelp: 'About this area',
  tExport: 'Export for pricing',
  tExportHelp: 'This CSV file holds the targets on this page. Before the file downloads, this button saves the targets that are not saved. The file counts each target size by region and operating system. Then it lists each machine with its resource group, region, operating system, size now, series, target size and disks. Give it to your Microsoft account team for the price of the change.',
  tExportAbout: 'About this file',
  tExportChanged: 'Another user saved the targets after this page read them. Load the page again, then export.',
  // PRICE-EXPORT-1: the same file on the Run it step, from the plan, with the wave.
  rExportHelp: 'This CSV file holds the plan. It counts each target size by wave, region and operating system. Then it lists each machine with its wave, resource group, region, operating system, size now, series, target size and disks. A machine that does not move has no target size. Give it to your Microsoft account team for the price of the change.',
  tSaved: 'The targets are saved.',
  tWaiting: 'The product is making the target options.',
  tNotStarted: 'The target options are not made yet for this assessment.',
  tFailed: 'The target options could not be made: {reason}',
  tMake: 'Make the target options',
  tWhatChanges: 'What changes on {series}',
  tOthers: 'Other options',
  tAvailable: 'Available: {size}',
  tNotAvailable: 'Not available: {why}',
  // AN-ONE-NIC-1: what to do about the reason one-accelerated-nic, behind its (?).
  tAnAbout: 'About accelerated networking on a size with 2 vCPUs',
  tAnHelp: 'The move turns on accelerated networking for the primary network interface. The other network interfaces keep their setting. In Azure, turn off accelerated networking on the other network interfaces of this machine. Then assess the machines again.',
  dSize: 'Size',
  dKind: 'Kind of change',
  dController: 'Disk controller',
  dTemp: 'Temporary disk',
  dAn: 'Accelerated networking',
  dLife: 'Lifecycle',
  dRollback: 'Rollback',
  vRollbackInPlace: 'Yes. Back to the original size, same machine.',
  // TEMP-DISK-PREVIEW-1: the rollback to the original size needs the feature too (measured).
  vRollbackPreview: 'Yes. Back to the original size, same machine, while the preview feature stays registered.',

  dApproval: 'Approval',
  dCores: 'vCPUs and memory',
  dDisks: 'Disks',
  dCpu: 'CPU performance',
  // BSV2-TARGET-1: why a B v1 machine has no Bsv2 size on this option.
  dBsv2: 'Bsv2 size',
  vBsv2Why: {
    'no-fit': 'No Bsv2 size in this region has the vCPUs, the memory, the network interfaces, the data disks and the generation of this machine.',
    'disk-encryption-preview': 'The move to Bsv2 changes the kind of temporary disk. The product does not move a machine that uses Azure Disk Encryption that way.',
  },
  kPathA: 'In-place upgrade',
  vNone: 'None',
  vOneDisk: '1 disk',
  vDisks: '{n} disks',
  vUnknown: 'Unknown',
  vOn: 'On',
  vOff: 'Off',
  vOnRequired: 'On (required)',
  vNoChange: '(no change)',
  vNotListed: 'Not listed',
  vScsi: 'SCSI',
  vNvme: 'NVMe',
  vApprovalStop: 'Turned on when you accept the wave settings',
  vCores: '{n} vCPUs, {gb} GiB',
  vDisks3: { keep: 'No change', 'os-standard-ssd': 'OS disk to Standard SSD', os: 'OS disk to Premium SSD', all: 'Every disk to Premium SSD' },
  // HDD-OS-1: Azure's names for the disk types, for the export for pricing.
  vDiskTypes: { Standard_LRS: 'Standard HDD', StandardSSD_LRS: 'Standard SSD', StandardSSD_ZRS: 'Standard SSD (zone-redundant)',
    Premium_LRS: 'Premium SSD', Premium_ZRS: 'Premium SSD (zone-redundant)', PremiumV2_LRS: 'Premium SSD v2', UltraSSD_LRS: 'Ultra Disk' },
  vCoresActive: '{n} vCPUs ({active} active), {gb} GiB',
  vCpuCredits: 'Burstable, with CPU credits',
  vCpuFull: 'Full, all the time',
  whyNot: {
    'not-in-region': 'No size in this region',
    // AN-MANA-DRIVER-RULE-1: every v6 and v7 size, Intel v5 and Bsv2, for a release with no MANA driver possible.
    'no-mana-driver': 'This size can give the MANA adapter, and this Linux release has no MANA driver',
    // TARGET-CAPABILITY-PRECHECK-1: the catalog does not say that the size supports a feature the machine uses.
    'no-encryption-at-host': 'This machine uses encryption at host. Azure does not say that this size supports it.',
    'no-ultra-disk': 'This machine has Ultra Disk compatibility enabled. Azure does not say that this size supports Ultra Disks in the zone or region of this machine.',
    'family-not-in-region': 'No size in this family in this region',
    'not-approved': 'Not a size Microsoft lists as a target',
    'gen1-no-size': 'v6 and v7 sizes take Generation 2 only. v5 takes Generation 1',
    'smaller-than-source': 'Every target size has fewer vCPUs or less memory than this machine',
    'shape-unknown': 'Azure does not give the vCPUs and memory of this size',
    'no-shape-fit': 'No Intel D or E size in this region has the vCPUs and the memory of this machine',
    'no-amd-shape-fit': 'No AMD D or E size in this region has the vCPUs and the memory of this machine',
    'disk-encryption-preview': 'The move to this series changes the kind of temporary disk, and the product does not move a machine that uses Azure Disk Encryption that way',
    // REBUILD-REMOVE-PLAN-1: a move across the kinds of temporary disk that nobody measured.
    'generation-unknown': 'The scan did not read the generation of this machine, and this series changes the kind of temporary disk. Scan the machine again',
    'temp-disk-change-not-measured': 'The product does not make this change of the temporary disk on a Windows machine',
    'too-few-nics': 'Too few network interfaces on this size',
    'too-few-data-disks': 'Too few data disks on this size',
    'one-accelerated-nic': 'This size has 2 vCPUs, so Azure allows accelerated networking on one network interface only',
    'processor-unreadable': 'Processor not known',
    'processor-not-approved': 'Processor not supported',
    'region-not-read': 'Sizes in this region not read',
    'excluded': 'Not in scope',
    'already-on-nvme': 'Already on NVMe',
    'already-on-series': 'Already on this series',
    'source-is-newer': 'Already on a newer size',
    'no-path': 'No migration path',
  },

  s3Title: 'How should they be grouped into waves?',
  // WAVE-TEXT-AVSET-1: waves only. The planner's rules are not listed here;
  // the availability set rule is said on the machine in the wave editor.
  s3Body: 'A wave is a group of machines that move together. You can change the waves after this step.',
  gTags: 'By one of your tags. Machines that share a tag value travel in the same wave.',
  gRg: 'By resource group. Every machine in one resource group travels in the same wave.',
  gSingle: 'One wave for everything. Every machine travels together, and there is no size limit.',
  gNone: 'I will build the waves myself',
  appTag: 'Which tag groups machines that belong together?',
  tagNoneApp: 'Do not group by a tag. Each machine is considered on its own.',
  tagsNone: 'No tags found on these machines',
  s3Go: 'Build the waves',
  // BACKLOOP-1: this step, reached with Back from the wave editor of a
  // migration that already has a plan. Planning always makes a NEW migration,
  // so this step does not plan again from here.
  s3Planned: 'This migration already has a plan, so its machines are in waves. To group them in a different way, select Delete this migration on the Migrations page. Then plan a new migration from the assessment.',
  s3ToWaves: 'Arrange the waves',
  s3Working: 'Building the waves.',
  s3Refused: 'The product did not make the plan. {reason}',
  s3RefusedNext: 'Open the assessment and correct this. Then select Build the waves again.',
  s3Quiet: 'The product did not send a plan or an error in {n} minutes. This page continues to look for the plan.',


  iacTitle: 'Before you start: machines defined in code',
  // IAC-NOTE-LIST-1: approved words (2026-11-08), shown as a lead, a
  // list with one item for each change, and a closing line. Joined, they are
  // the engine statement Get-VmfIacStatement, which the acceptance records.
  iacLead: 'Terraform, Bicep, Pulumi, ARM templates and Ansible keep their own definition of each machine. This migration makes these changes, and those definitions do not know about them:',
  iacChanges: [
    'The size of the machine changes.',
    'A move to v6 or v7 changes the disk controller from SCSI to NVMe.',
    'A move can change accelerated networking.',
    'A move can change the disk type to Standard SSD or Premium SSD.',
    'A rollback or a restore puts the machine on new disks, made from its safety copies. A restore can keep the disk names.',
  ],
  iacAfter: 'The next apply can undo these changes, or replace the machine. Reconcile your definitions after the migration.',
  iacAccept: 'I understand, and I will reconcile our definitions after the migration.',
  iacMissing: 'Please read and accept the note about machines defined in code before starting.',
  // SQL-TEMPDB-SIGNOFF-1 (2026-11-16): only for a plan with a
  // machine where the scan found SQL Server that moves from a SCSI temporary
  // disk to an NVMe temporary disk or none (help.js sqlTempdbEntries).
  sqlTitle: 'Before you sign off: SQL Server and the temporary disk',
  sqlLead: 'The scan found SQL Server on these machines. Each one moves from a SCSI temporary disk to a size with an NVMe temporary disk or no temporary disk:',
  sqlAfter: 'If tempdb is on the temporary disk, SQL Server can fail to start after the move. Check where tempdb is on each machine. If it is on the temporary disk, put tempdb on another disk before the migration. Or, on the step Choose each target, choose a v5 size with a temporary disk.',
  sqlAccept: 'I checked where tempdb is on each of these machines.',
  sqlMissing: 'Tick "I checked where tempdb is on each of these machines." before you sign off.',
  s5Title: 'Run it',
  s5Body: 'Only this step changes anything. Accept each wave, sign off the plan once, then choose how it runs.',

  noteLabel: 'A short note, kept with this run',
  noteMissing: 'Please add a short note - every action is recorded with its reason.',
  // MACHINES-AT-ONCE-RANGE-1: there is no number of machines at once for one
  // start. ATONCE-1 kept "How many machines at once in this start" for the
  // first wave only, and it read as the wave setting asked twice, with a
  // number a later wave did not use. Each wave row above shows its own
  // choice, and this says where it is set.
  atOnceWhere: 'Each wave runs its own number of machines at once, as its settings above show. To change a number, change the settings of that wave.',
  estAllAtOnce:  'This wave has only {machines} machines, so all of them run at once.',
  // LAB-UX-1: the same two sentences for a wave of one machine.
  estAllAtOnceOne: 'This wave has only 1 machine, so a larger number changes nothing.',
  s5Done: 'The wave is starting. Select Open the run to see its progress.',
  openRun: 'Open the run',
  alreadyRunning: 'This migration is already under way - open the run to watch and control it.',

  back: 'Back',
  slow: 'The service did not answer. Try again.',
  needOperator: 'To prepare a migration, you need operator access. Ask an administrator if you need it.',
};
/* ============================= UX-STRINGS-END ============================= */

let cfg = null, msalApp = null, account = null, canOperate = false, canApprove = false;
let runId = new URLSearchParams(location.search).get('run');
// PROJECT-1: which piece of work this belongs to. Carried in the address like
// the run, so leaving the page and coming back keeps it. Null means the scan is
// outside any project, which stays legal - the command line can make one.
let projectId = new URLSearchParams(location.search).get('project');
// Everything the wizard reads lives under the project when there is one. ONE
// place computes that, because a prefix applied in some reads and not others
// is a page that half-loads.
// RUNID-2: ONE normalisation, here. A link may carry the composite id in
// ?run= (the lists the service returns hold composite ids) or the two parts
// separately. Reading them both ways at every call site is how a page ends up
// composing `project/project/run` in one place and a bare run in another.
{
  const parts = VmfHelp.VmfRun.parse(runId);
  if (parts.project && !projectId) { projectId = parts.project; }
  if (parts.project) { runId = parts.run; }
}
// The identity, and the three ways of writing it. Nothing below spells any of
// them by hand - see the note in help.js, and RunAddress.Tests.ps1, which
// refuses a page that does.
function runFullId() {
  return VmfHelp.VmfRun.storePath(projectId, runId);
}
function runPrefix() {
  return runFullId();
}
function runSeg() {
  return VmfHelp.VmfRun.routeSegment(runId);
}
function runBody(body) {
  return VmfHelp.VmfRun.withProject(body, runFullId());
}

function runHref(page, extra) {
  return VmfHelp.VmfRun.link(page, runFullId(), extra);
}
let step = 1, poll = null, acknowledged = false;
/* WIZARD-BACK-TARGETS-1: true while the step on screen is one the person chose
 * with a button - Back, Continue, Save. The poll never moves a person off such a
 * step: on the lab walk, Back from "How to group them" drew "Choose each target"
 * and the next poll went forward again, because the saved targets derive the
 * later step. Cleared only by waitOn, when the step waits for the engine. */
let stepChosen = false;
function goStep(n) {
  step = n; stepChosen = true; render();
}
// The step waits for the engine (the scan, the plan): the poll moves it on.
function waitOn(n) {
  step = n; stepChosen = false;
}
// Where the poll leaves the person: a chosen step stays; a waiting step moves
// on to what the run shows, and never back.
function pollStep(shown, derived, chosen) {
  if (chosen) return shown;
  return derived > shown ? derived : shown;
}
/* POLL-1: is a tick still running? setInterval does not wait for an async
 * callback, so without this a tick that takes longer than the interval is
 * simply joined by the next one. Each tick re-reads the run - one request per
 * machine among them - so on the fleet sizes where a tick IS slow, the work in
 * flight grew with elapsed time instead of staying flat. */
let pollBusy = false;
// SCAN-FAIL-SHOWN-1 review: the reason the scan stopped, or null. STATE, not a
// one-time paint: the findings step is drawn again by render() (a step change,
// a read of the run), and that redraw showed the spinner again with the poll
// already cleared - a wait that looked alive and never moved.
let scanStopped = null;
// NAMED STEPS. Every one of these used to be a bare number scattered across the
// render functions, with TWO journeys sharing one counter - so inserting the
// project question at the front silently broke six places that no longer meant
// what they said. The first showed within a minute of opening the page.
//
// A number is not a name. With these, inserting a step is one edit here.
const STEP = {
  assess:  { project: 1, scope: 2, findings: 3, review: 4 },
  // WAVE-FLOW-1: three. The editor IS step 2 and lives on its own page,
  // and capacity folded into the wave card beside the reservation it drives.
  // ADVISOR-1: choosing each machine's target comes first - Microsoft's order
  // is assess, then each machine's target, then waves.
  // MACHINE-PICK-1: and which machines move comes before their targets.
  migrate: { choose: 1, targets: 2, group: 3, waves: 4, run: 5 },
  running: 9,   // already under way - setup is over, go and watch it
};
let assessment = null, plan = null, states = new Map(), approvals = new Map();
// The default used to be migration-<today>, so a SECOND scan on the same day
// walked straight into the first run and the wizard announced that the
// migration was already under way - which it was, just not this one.
// The name now carries the time.
// ASSESS-PAGE-1: this names an ASSESSMENT now, not a migration - the wizard
// starts by scanning, and the migration is created later with a name derived
// from the assessment it came from.
// What a blocker or prep item MEANS comes from the engine's own file, through
// the SHARED renderer - the same one that draws the findings on this page and
// on Assessments. This page used to keep its own loader and its own REASONS
// map beside it, which is how two pages end up disagreeing about what a code
// means. Empty is still a valid state: the codes render without their
// explanation, which beats a page that will not load because a file is missing.
const { loadReasons, reasonOf } = window.VmfReport;
const reasonText = (code) => (reasonOf(code) || {}).title || String(code);
const reasonDetail = (code) => reasonOf(code);

function suggestedRunName() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `assessment-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

const form = { scopeType: 'rg', sub: '', rgs: [], subs: [], mg: '', strategy: 'tags', appTag: '' };
let scopes = null;
// PROJECT-1 aftermath, found on the first run: the scope pickers
// hung on "Loading..." for ever. The loader below re-rendered only `if (step ===
// 1)`, which was true when the scope question WAS step one - and stopped being
// true the moment the project question was inserted in front of it. The data
// arrived and nothing redrew.
//
// So the SCREEN records that it is waiting, rather than a step number standing
// in for it. Insert another step tomorrow and this still works.
let awaitingScopes = false;

async function getToken(scopes_) {
  /* TOKEN-SCOPE-1: the store reads call this with no scope. MSAL v2 gave the
     service's token anyway; v5 gives a sign-in token, and the service answers
     401 to it. The service scope is the only one this page asks for. */
  const req = { scopes: scopes_ || [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
async function blobJson(path) {
  if (DEMO_MODE) return DEMO[path] ?? null;
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path);
}
/* PLANVER-2: the document AND the version the service issued for it, together.
 * See VmfHelp.storeBlob for why a caller must not compute one itself. */
async function blobVersioned(path) {
  if (DEMO_MODE) return null;
  try { return await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asVersioned: true }); }
  catch { return null; }
}
async function blobText(path) {
  if (DEMO_MODE) return null;
  try { return await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asText: true }); }
  catch { return null; }
}
async function blobList(prefix) {
  if (DEMO_MODE) return Object.keys(DEMO).filter(k => k.startsWith(prefix));
  try { return (await VmfHelp.storeList(() => getToken(), cfg.apiUrl, prefix)).names; }
  catch { return []; }
}
// CLAIM-AT-PLAN-1: `query` is for a GET, which carries the project in its
// query (PROJECT-4) - through the one helper that writes a query.
async function api(method, path, body, query) {
  if (DEMO_MODE) { await new Promise(r => setTimeout(r, 350)); return demoApi(method, path); }
  const token = await getToken([`api://${cfg.apiAppId}/access_as_user`]);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 45000);
  try {
    const r = await fetch(query ? VmfHelp.storeUrl(cfg.apiUrl, path, query) : `${cfg.apiUrl}/${path}`, {
      method, signal: ctl.signal,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
    return data;
  } catch (e) {
    throw new Error(e.name === 'AbortError' ? UX.slow : e.message);
  } finally { clearTimeout(timer); }
}
const fail = (e) => { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; };
// Something the PERSON did. Never blames Azure RBAC - the facade refuses
// an action on APP ROLE, and its storage permission is not involved.
// WIZARD-START-ERROR-OUT-OF-VIEW-1: a refused action is said where the person
// looks. The error line is at the top of the page and the buttons are at the
// bottom of a long step, so a 409, a 403 or a network failure on Start the
// plan, Sign off or Accept looked like a button that did nothing. The line
// comes into view the nearest way and takes the focus (tabindex="-1" and
// role="alert" in wizard.html), so a screen reader says it too.
function failAction(e) {
  const box = $('#err');
  box.textContent = VmfHelp.explainAction(e);
  box.style.display = 'block';
  box.focus({ preventScroll: true });
  box.scrollIntoView({ block: 'nearest' });
}
/* READ-1: what the page says when it could not READ the run, rather than
 * deciding the run is not there. It is a read, not an action, so it names no
 * button - and it leaves the person where they are. */
const failRead = (e) => { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; };
// LAB-UX-1: an error about what was typed goes once the action it was about
// is on its way. "Please add a short note" stayed on screen after the plan was
// signed off and started with a note.
function clearErr() {
  $('#err').style.display = 'none';
  clearFieldErr();
}
/* WIZARD-START-ERROR-OUT-OF-VIEW-1 / SIGNOFF-NOTE-ERROR-1: an error about one
 * field shows BESIDE that field, and the focus goes to it. Start the plan and
 * Sign off the plan wrote "Please add a short note" into the error line at
 * the top of the page, out of view, so the button seemed to do nothing (lab,
 * 2026-11-14, after a reload left the note box empty). The box is the field's
 * id plus "-err", drawn under the field (role="alert", hidden); the Migrations
 * page dialog shows its note error beside its note the same way (#m-err). A
 * field with no box falls back to the page error, so the reason is never lost. */
function failField(input, msg) {
  const box = input ? document.getElementById(`${input.id}-err`) : null;
  if (!box) { fail(new Error(msg)); return; }
  clearErr();
  box.textContent = msg;
  box.hidden = false;
  input.setAttribute('aria-invalid', 'true');
  input.focus();
  box.scrollIntoView({ block: 'nearest' });
}
/* The error of one field goes (the person typed, or ticked), or, with no
 * field, every field error of the step goes. */
function clearFieldErr(input) {
  const boxes = input
    ? [document.getElementById(`${input.id}-err`)].filter(Boolean)
    : [...document.querySelectorAll('.f-err')];
  for (const box of boxes) {
    box.hidden = true;
    box.textContent = '';
    document.getElementById(box.id.replace(/-err$/, ''))?.removeAttribute('aria-invalid');
  }
}
// Something worked. The page had a line for failure and none for success, so
// an action that succeeded looked identical to one that did nothing.
const said = (msg) => { $('#ok').textContent = msg; $('#ok').style.display = 'block'; };

// ---------- the step is DERIVED from the run, never remembered ----------
let runExists = false, manifest = null, approval = null, journey = 'assess';
/* READ-1: a document that is NOT THERE is null - the service answers 404 for
 * an approval nobody has written yet, deliberately, and says so in a comment.
 * A document that could not be READ throws.
 *
 * This page then wrote `.catch(() => null)` on every read, which made the two
 * the same thing. MEASURED 2026-09-15: four reads 404d because the link had
 * dropped the project, the page concluded the run had never been created, and
 * sent the person to the start of the wizard - silently, with no message and
 * nothing to retry. A slow first request on the Consumption plan does the same
 * thing, which is why it looked random.
 *
 * So a failure is REMEMBERED, and the page says so rather than deciding the
 * run does not exist. */
let readFailed = null;
/* PAGE-LOAD-3: `from`, when given, is the read's one call for the run (or the
 * promise of it), and a document it holds - or says is not there - is not
 * asked for again. What it cannot say is read as before (unknown means ask). */
async function readDoc(path, from) {
  const known = VmfHelp.heldJson(await from, path);
  if (known) return known.value;
  try { return await blobJson(path); }
  catch (e) { readFailed = readFailed ?? e; return null; }
}
// PAGE-LOAD-3: the names in a folder, from the one call when it can say.
async function readNames(prefix, from) {
  const known = VmfHelp.heldList(await from, prefix);
  return known ? known.names : blobList(prefix);
}
/* PAGE-LOAD-3: what a step reads of the run in ONE call (store/docs, the run
 * as the prefix). It read a dozen documents and three folders, then each
 * document the folders named - one call each, on every step and every tick.
 * No document a save quotes back: the target options, the targets and the
 * machines chosen are read with the version the service issued for them
 * (PLANVER-2, readVersionedDoc), and so is the plan the sign-off names. */
const RUN_READS = ['run.json', 'approval.json', 'assessment.json', 'plan.json', 'plan-approval.json', 'state/*.json', 'approvals/*.json', 'acceptances/*.json', 'acknowledgements/infrastructure-as-code.json'];
let acceptances = new Map();
// PLANRUN-1: the plan's sign-off, and whether it is for the plan as it stands.
let planSignoff = null, planSignoffCurrent = false;
// ADVISOR-1: the target options and the targets saved from them, each WITH the
// version the service issued for it (PLANVER-2). A save quotes both back; the
// page never computes a version or compares a date.
let targetAdvice = null, adviceVersion = '', targetChoices = null, choicesVersion = '';
// TARGET-OPTIONS-WAIT-1: a target-advice.json is there, from an earlier version.
let adviceOld = false;
// MACHINE-PICK-1: the machines chosen for the migration, and the version the
// service issued for that list. The targets save quotes it back too.
let machineChoices = null, machinesVersion = '';
// ASSESS-APPROVAL-HASH-1: the version the service issued for the assessment
// the review step shows (PLANVER-2). The approval quotes it back, and the
// service refuses another one. '' when the assessment is approved, or read
// without its version.
let assessmentVersion = '';
// QUIET-READS-1: the kind of each run read so far - run prefix -> 'assessment' | 'migration'.
const runKinds = new Map();
const TARGET_ADVICE_VERSION = 34;   // Get-VmfTargetAdviceSchemaVersion
// READ-1, as readDoc: a document that is not there is null; one that could not
// be READ is remembered, so the page stays where it is and says so rather than
// taking a failed read for "no options" or "no targets saved".
async function readVersionedDoc(path) {
  if (DEMO_MODE) { const d = DEMO[path]; return d ? { doc: d, version: 'demo' } : null; }
  try {
    const v = await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asVersioned: true });
    if (!v || !v.text) return null;
    return { doc: JSON.parse(v.text), version: v.version || '' };
  } catch (e) { readFailed = readFailed ?? e; return null; }
}
/* ASSESS-APPROVAL-HASH-1: the assessment the review step shows, and the
 * version the service issued for it. The run's documents come from one call
 * that gives no version (VmfHelp.storeDocs), so while nobody has approved the
 * assessment it is read again WITH its version (readVersionedDoc), and the
 * review shows that text: the approval names the scan the person read, and
 * planning holds to it. Once approved, or on a migration, the one call's copy
 * is kept and there is no version. A read that fails keeps that copy too,
 * with no version, and the page says the read failed (readFailed). */
async function reviewedScan(onAssessment, appr, asmt, path) {
  if (!onAssessment || appr || !asmt) { return { doc: asmt, version: '' }; }
  const v = await readVersionedDoc(path);
  return v ? { doc: v.doc, version: v.version } : { doc: asmt, version: '' };
}
async function readRun() {
  readFailed = null;
  if (!runId) { runExists = false; assessment = null; plan = null; states = new Map(); return; }
  /* PAGE-WAIT-1, found on the first Azure install: the page sat blank for about
   * ten seconds between steps. This made about a dozen reads ONE AFTER
   * ANOTHER - each a round trip to the service - before anything was drawn,
   * and it runs again on every poll tick. None of them depends on another, so
   * they go together: the documents and the folder lists first, then what the
   * lists name.
   *
   * The quota records were read here too, into a variable nothing used, by a
   * path that doubled the folder - so every one of those reads failed, on
   * every tick. They are gone. */
  const pre = runPrefix();
  // PAGE-LOAD-3: the run's documents in one call. A call that fails leaves
  // `held` null, and each read below is made as before.
  const held = DEMO_MODE ? Promise.resolve(null)
    : VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${pre}/`, depth: 2, read: RUN_READS }).catch(() => null);
  const docOf = async (n) => { const known = VmfHelp.heldJson(await held, n); return known ? known.value : blobJson(n); };
  const docsIn = (names) => VmfHelp.mapLimited(names.filter(n => n.endsWith('.json')), n => docOf(n).catch(() => null));
  // QUIET-READS-1: an assessment never has a plan, and a migration never has
  // the assessment's approval or its target options. Asked anyway on every
  // refresh, each was a "not found" - 292 of them in one session of the
  // end-to-end run. The kind is known from the first read of run.json and
  // does not change, so later refreshes ask only for what can exist.
  const kind = runKinds.get(pre);
  const skip = (want) => (kind && kind !== want) ? Promise.resolve(null) : null;
  const [m, appr, asmt, pl, pa, stateNames, apprNames, accNames, av, cv, mv, ack] = await Promise.all([
    // A link to a run that was never created must start the flow, not spin
    // forever waiting for a scan nobody asked for.
    readDoc(`${pre}/run.json`, held),
    // The gate: planning is refused without this, so the wizard reads it
    // rather than offering a step the engine will turn down.
    skip('assessment') ?? readDoc(`${pre}/approval.json`, held),
    readDoc(`${pre}/assessment.json`, held),
    skip('migration') ?? readDoc(`${pre}/plan.json`, held),
    // PLANRUN-1: one sign-off for the whole plan.
    skip('migration') ?? readDoc(`${pre}/plan-approval.json`, held),
    readNames(`${pre}/state/`, held),
    readNames(`${pre}/approvals/`, held),
    // WAVE-2: the engine refuses a wave whose options nobody accepted. The
    // wizard used to walk straight past that gate and only meet it as a
    // failure at the last step, which reads as though the gate can be bypassed.
    readNames(`${pre}/acceptances/`, held),
    // ADVISOR-1: the target options and the targets saved from them, beside
    // an ASSESSMENT, each with the version the service issued (PLANVER-2).
    skip('assessment') ?? readVersionedDoc(`${pre}/target-advice.json`),
    skip('assessment') ?? readVersionedDoc(`${pre}/target-choices.json`),
    // MACHINE-PICK-1: and the machines chosen, the same way.
    skip('assessment') ?? readVersionedDoc(`${pre}/machine-choices.json`),
    // CODE-NOTE-ACK-SAVED-1: the note about machines defined in code, once
    // accepted, is not asked for again.
    skip('migration') ?? readDoc(`${pre}/acknowledgements/infrastructure-as-code.json`, held),
  ]);
  if (m) { runKinds.set(pre, m.kind === 'migration' ? 'migration' : 'assessment'); }
  const onAssessment = !m || m.kind !== 'migration';
  // An options file from an older version names its defaults differently:
  // read as not made, so the step offers to make them again.
  targetAdvice = onAssessment && av && av.doc?.schemaVersion === TARGET_ADVICE_VERSION ? av.doc : null; adviceVersion = onAssessment && av ? av.version : '';
  // TARGET-OPTIONS-WAIT-1: a file this page cannot read is one an earlier
  // version made - the only "written" that offers Make again.
  adviceOld = Boolean(onAssessment && av && av.doc?.schemaVersion !== TARGET_ADVICE_VERSION);
  targetChoices = onAssessment && cv ? cv.doc : null; choicesVersion = onAssessment && cv ? cv.version : '';
  machineChoices = onAssessment && mv ? mv.doc : null; machinesVersion = onAssessment && mv ? mv.version : '';
  manifest = m; runExists = Boolean(manifest);
  approval = appr; assessment = asmt; plan = pl; planSignoff = pa;
  acknowledged = ackGiven(ack);
  // STORE-READ-2: one read per machine in the run, paced - the largest cost.
  // The sign-off is only for the plan version it was given for, and an edit
  // drops it. The service issues the version (PLANVER-2), so the plan is read
  // versioned only when there is a sign-off to compare it with.
  const [docs, apprDocs, accDocs, pv, rv] = await Promise.all([
    docsIn(stateNames),
    VmfHelp.mapLimited(apprNames.filter(n => n.endsWith('.json')),
      async n => [n.split('/').pop().replace(/\.json$/, ''), await docOf(n).catch(() => null)]),
    docsIn(accNames),
    planSignoff ? blobVersioned(`${pre}/plan.json`) : Promise.resolve(null),
    // ASSESS-APPROVAL-HASH-1: an assessment nobody approved yet is read again
    // with its version, and the review shows that text (reviewedScan).
    reviewedScan(onAssessment, appr, asmt, `${pre}/assessment.json`),
  ]);
  assessment = rv.doc; assessmentVersion = rv.version;
  states = new Map(docs.filter(Boolean).map(d => [d.vmId, d.state]));
  nameMachines(docs.filter(Boolean), assessment);
  approvals = new Map(apprDocs.filter(([, v]) => v));
  acceptances = new Map(accDocs.filter(Boolean).map(a => [a.wave, a]));
  planSignoffCurrent = Boolean(planSignoff) && (DEMO_MODE || Boolean(pv && pv.version && pv.version === planSignoff.planHash));
}
// ASSESS-PAGE-1: no path that starts at "assess an estate" may end at "run
// it". Assessing an estate and migrating one are two
// pieces of work, and the wizard used to run them together - so the button
// said assess and the last step said run.
//
// Two journeys now. Assessing ends when the assessment has been reviewed;
// migrating is entered deliberately from an approved assessment, which is what
// ?plan=1 in the address says. Derived rather than remembered, like the step.
const wantsPlan = () => new URLSearchParams(location.search).has('plan');
// WAVE-FLOW-1: the editor is step 2 and lives on another page, so it says
// where it sent the person back to. Without this, returning from a saved plan
// lands on step 2 again - which now means being sent straight back to the
// editor, in a loop.
const wantsRunStep = () => new URLSearchParams(location.search).get('step') === 'run';
// BACKLOOP-1: and the same for the FIRST step. Back on the wave editor sent
// the person to wizard.html with no step; with a plan in place that derives
// step 2, which IS the editor, so they landed where they started. Step 1 was
// unreachable once a plan existed, because nothing could ask for it.
const wantsGroupStep = () => new URLSearchParams(location.search).get('step') === 'group';
const wantsTargetsStep = () => new URLSearchParams(location.search).get('step') === 'targets';
// MACHINE-PICK-1: and the step before the targets, which Back on the targets step names.
const wantsChooseStep = () => new URLSearchParams(location.search).get('step') === 'choose';
// WIZARD-WAVES-STEP-1: the assessment a migration is being planned from, which
// Build the waves puts in the address. The migration has no run.json until the
// engine's container starts - measured on the lab install at well over 30
// seconds - so a reload in that time has nothing else that names it.
const planningFrom = () => new URLSearchParams(location.search).get('from');
// A migration: its run.json says so, or Build the waves named its assessment
// and nothing has been written yet.
const isMigration = () => manifest ? manifest.kind === 'migration' : Boolean(planningFrom());
// Whether the saved targets were saved against the machines chosen now
// (PLANVER-2: the version the service issued, quoted by the targets save). The
// engine refuses to plan otherwise. With no list nothing fits: the wizard saves
// the list before any target (OLD-VERSION-READERS-REMOVE-6).
function targetsFitMachines(targets, machines, version) {
  return Boolean(machines) && Boolean(targets) && (targets.machinesVersion ?? '') === version;
}
function deriveJourney() {
  if (isMigration()) return 'migrate';
  if (wantsPlan() && approval) return 'migrate';
  return 'assess';
}

function deriveAssessStep() {
  // PROJECT-1: which piece of work, first. A run that already exists WITHOUT a
  // project (the command line can make one) is opened as it is - it must not
  // be held hostage by a question that did not apply when it started.
  if (!projectId && !runId) return STEP.assess.project;
  if (!runId || !runExists) return STEP.assess.scope;
  if (!assessment) return STEP.assess.findings;
  // A scan that found NOTHING has nothing to review, so it stops where the
  // answer is rather than offering an approval of an empty result.
  if (!(assessment.vms ?? []).length) return STEP.assess.findings;
  return STEP.assess.review;
}

function deriveStep() {
  /* READ-1: a read that FAILED says nothing about where this run has got to.
   * Deriving a step from it is how a person pressing "Plan a migration from
   * this" was returned to the start of the wizard: four documents could not be
   * read, so the page decided the run had never been created. Stay where we
   * are and say so - failRead has already put the reason on screen. */
  if (readFailed) { return step; }
  if (journey === 'assess') return deriveAssessStep();
  // Migrating: grouping is chosen while still on the assessment, and planning
  // is what creates the migration.
  // ADVISOR-1: no plan without a target for each machine - the engine refuses
  // it too. Once targets are saved, grouping them is next.
  // MACHINE-PICK-1: and no targets without the machines.
  if (!plan || !(plan.entries ?? []).length) {
    // Only an ASSESSMENT has machines and targets to choose. A migration with
    // no plan yet (being written, or planning failed) goes on waiting at grouping.
    if (!isMigration()) {
      // With no list the machines come first, whatever a link asks for.
      if (wantsChooseStep() || !machineChoices) return STEP.migrate.choose;
      if (wantsTargetsStep() || !targetChoices || !targetsFitMachines(targetChoices, machineChoices, machinesVersion)) return STEP.migrate.targets;
    }
    return STEP.migrate.group;
  }
  if ([...states.values()].some(s => VmfHelp.machineStarted(s))) return STEP.running;
  if (wantsRunStep()) { return STEP.migrate.run; }
  if (wantsGroupStep()) { return STEP.migrate.group; }
  return step >= STEP.migrate.run ? STEP.migrate.run : STEP.migrate.waves;
}
const planWaves = () => {
  const m = new Map();
  for (const e of (plan?.entries ?? [])) {
    if (!e.wave || e.wave === 'unscheduled' || e.path !== 'A') continue;
    if (!m.has(e.wave)) m.set(e.wave, { n: 0, approval: false });
    m.get(e.wave).n++;
  }
  // SIGNOFF-NULL-1: as the engine's gate reads it - any machine OF THE WAVE
  // that requires it, whether the plan moves it or not.
  for (const e of (plan?.entries ?? [])) {
    if (m.has(e.wave) && VmfHelp.approvalRequired(e)) m.get(e.wave).approval = true;
  }
  // WAVE-ORDER-1: the order that runs - the first of these is the wave "Run it" starts.
  const rank = VmfHelp.waveOrder(plan);
  return [...m.entries()].sort(([a], [b]) => rank.indexOf(a) - rank.indexOf(b));
};

// ---------- rendering ----------
function renderRail() {
  const labels = journey === 'assess' ? UX.stepsAssess : VmfHelp.MIGRATE_STEPS;
  $('#rail').innerHTML = VmfHelp.stepRail(labels, step);
}
const card = (title, body, inner) =>
  `<div class="card"><div class="ch"><h2>${esc(title)}</h2><p>${esc(body)}</p></div><div class="cb">${inner}</div></div>`;
const opt = (v, label, sel) => `<option value="${esc(v)}"${sel === v ? ' selected' : ''}>${esc(label)}</option>`;

function render() {
  // READ-1: say it every time the page draws, because a read fails again on
  // every poll until whatever refused it stops refusing.
  if (readFailed) { failRead(readFailed); }
  renderRail();
  const el = $('#step');
  if (step === STEP.running) {
    el.innerHTML = card(UX.s5Title, UX.alreadyRunning,
      `<a class="btn" style="text-decoration:none" href="${runHref('migrations.html')}">${esc(UX.openRun)}</a>`);
    return;
  }
  if (journey === 'assess') {
    if (step === STEP.assess.project)  return void renderProjectPick(el).catch(fail);
    if (step === STEP.assess.scope)    return renderStep1(el);
    if (step === STEP.assess.findings) return renderStep2(el);
    return void renderReview(el).catch(fail);
  }
  if (step === STEP.migrate.choose)   return renderChoose(el);
  if (step === STEP.migrate.targets)  return renderTargets(el);
  if (step === STEP.migrate.group)    return renderStep3(el);
  if (step === STEP.migrate.waves)    return renderStep4(el);
  return renderStep5(el);                    // run it
}

// REVIEW-PAGE-1: the review as one row per machine - what it is, the targets
// still open to it - with the reasons behind a Details button, the same shape
// as the targets step. The grouped report stays on the Assessments page.
let rOpen = new Set(), reviewNote = '', rWorkload = '';
function reviewDetail(v) {
  const reason = (code) => window.VmfReport.reasonOf(code);
  const line = (code, withSeries) => {
    const r = reason(code);
    const applies = withSeries && Array.isArray(r?.appliesTo) && r.appliesTo.length && r.appliesTo.length < 3
      ? ` ${UX.rApplies.replace('{series}', r.appliesTo.join(' and '))}` : '';
    return `<tr><td>${esc(r ? r.title : code)}${esc(applies)}</td><td>${esc(r ? (r.whatToDo || r.meaning || '') : '')}</td></tr>`;
  };
  // ALREADY-CURRENT-1: a machine on a Current size is in no finding, as in the
  // report (groupByCode); its Details say its line instead.
  const current = window.VmfReport.isCurrent(v);
  const codes = (list) => current ? [] : (list ?? []).filter(Boolean);
  const stops = codes(v.blockers), first = codes(v.prepNeeded);
  const check = codes(v.warnings), facts = window.VmfReport.evidenceText(v);
  return `${stops.length ? `<div class="sec"><h3>${esc(UX.rStops)}</h3><table class="facts">${stops.map(c => line(c, true)).join('')}</table></div>`
                         : `<p class="muted">${esc(current ? window.VmfReport.machineWhy(v) : UX.rNothing)}</p>`}
    ${check.length ? `<div class="sec"><h3>${esc(UX.rCheck)}</h3><table class="facts">${check.map(c => line(c, false)).join('')}</table></div>` : ''}
    ${first.length ? `<div class="sec"><h3>${esc(UX.rFirst)}</h3><table class="facts">${first.map(c => line(c, false)).join('')}</table></div>` : ''}
    ${facts ? `<div class="sec"><h3>${esc(UX.rFacts)}</h3><p class="${(v.workload?.evidence ?? []).length ? 'mono' : 'muted'}" style="overflow-wrap:anywhere">${esc(facts)}</p></div>` : ''}`;
}
function reviewTable(vms) {
  const short = (s) => String(s ?? '').replace(/^Standard_/, '');
  const shown = vms.filter(v => v.classification !== 'Excluded' && !v.platformManaged);
  // DETECT-PATTERNS-1: the filter by workload type. '' shows every type.
  const rows = shown.filter(v => !rWorkload || window.VmfReport.workloadType(v) === rWorkload).map(v => {
    const open = window.VmfReport.openSeries(v);
    const isOpen = rOpen.has(v.vmId);
    return `<tr><td class="mono">${esc(v.name || vmName(v.vmId))}</td><td class="mono">${esc(short(v.sourceSize))}</td>
      <td>${esc(advGenLabel(v.gen))}</td>
      <td>${esc(window.VmfReport.workloadTitle(window.VmfReport.workloadType(v)))}</td>
      <td>${open.length ? esc(open.join(', ')) : `<span class="muted">${esc(window.VmfReport.machineWhy(v) || UX.rNoTarget)}</span>`}</td>
      <td><button type="button" class="btn small ghost r-det" data-vm="${esc(v.vmId)}" aria-expanded="${isOpen}">${esc(isOpen ? UX.tClose : UX.tDetails)}</button></td></tr>
      ${isOpen ? `<tr class="t-detail"><td colspan="6">${reviewDetail(v)}</td></tr>` : ''}`;
  }).join('');
  return `<div style="margin:0 0 8px">${window.VmfReport.workloadFilterHtml(shown, rWorkload, 'r-workload')}</div>
    <table><thead><tr><th>${esc(UX.colMachine)}</th><th>${esc(UX.colSize)}</th><th>${esc(UX.colGen)}</th><th>${esc(UX.rColWorkload)}</th><th>${esc(UX.rColTargets)}</th><th></th></tr></thead>
    <tbody>${rows}</tbody></table>`;
}

// The end of the assess journey. It does NOT offer to run anything - migrating
// is a separate piece of work, entered deliberately from here.
/* ASSESS-APPROVAL-HASH-1: I have reviewed this, or the reason it is not there.
 * The approval quotes the version of the scan the step shows; with none (the
 * versioned read failed) the service could only refuse it. PURE. */
function reviewAction(allowed, version) {
  if (allowed && !version) { return roleAction('rev', UX.aReviewBtn, false, UX.aReviewNoVersion); }
  return roleAction('rev', UX.aReviewBtn, allowed, UX.reviewNeedsApprover);
}
async function renderReview(el) {
  // The wording comes from the engine's own file. Load it BEFORE drawing, or
  // every card shows a raw code like 'gen1-requires-redeploy'.
  await window.VmfReport.loadReasons();
  const vms = assessment?.vms ?? [];
  // SERIES-COUNT-1: can migrate = at least one size series is open to it.
  // ASSESS-COUNT-1: the one rule every page counts by.
  // ALREADY-CURRENT-1: a machine on a Current size is counted as Current.
  const { ready, cannotYet: blocked, current } = window.VmfReport.migrateCounts(vms);
  if (approval) {
    el.innerHTML = card(UX.aDoneTitle, UX.aDoneBody, `
      <p class="muted">${esc(UX.aReviewedBy)} ${esc(approval.approvedBy?.identity ?? '')}</p>
      ${blocked ? `<p class="muted">${esc(VmfHelp.countWords(blocked, [UX.aBlockedNoteOne, UX.aBlockedNote]))}</p>` : ''}
      <div class="nav"><a class="btn ghost" style="text-decoration:none" href="assessments.html">${esc(UX.aReviewOpen)}</a>
        <span class="sp"></span>
        <a class="btn" style="text-decoration:none" href="${runHref('wizard.html', { plan: 1 })}">${esc(UX.aPlanNext)}</a></div>`);
    return;
  }
  // THE FINDINGS, HERE. Nothing said why or what, so a person had to leave
  // this process and open the Assessments page to find out.
  // The same renderer the Assessments page uses - one report, two callers.
  el.innerHTML = card(UX.aReviewTitle, UX.aReviewBody, `
    <p><b>${ready}</b> ${esc(UX.s2CanMigrate)} &middot; <b>${blocked}</b> ${esc(UX.s2Cannot)}${current ? ` &middot; <b>${current}</b> ${esc(UX.s2Current)}` : ''}</p>
    <div id="findings">${reviewTable(vms)}${window.VmfReport.notReadHtml(assessment?.notRead)}</div>
    <p class="muted">${esc(UX.aReviewOpenWhere)}</p>
    <label class="f" for="f-rev">${esc(UX.aReviewNote)}</label>
    <textarea id="f-rev" rows="2">${esc(reviewNote)}</textarea>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      ${reviewAction(canApprove, assessmentVersion)}</div>`);
  // A Details click redraws the step; the note being typed must survive it.
  $('#f-rev').addEventListener('input', (e) => { reviewNote = e.target.value; });
  $('#r-workload')?.addEventListener('change', (e) => { rWorkload = e.target.value; render(); });
  document.querySelectorAll('.r-det').forEach(b => b.addEventListener('click', () => {
    const id = b.dataset.vm; if (rOpen.has(id)) rOpen.delete(id); else rOpen.add(id); render();
  }));
  $('#b').addEventListener('click', () => { goStep(STEP.assess.findings); });
  $('#rev')?.addEventListener('click', async () => {
    const note = $('#f-rev').value.trim();
    try {
      $('#rev').disabled = true;
      // The project travels in the body: a slash does not survive this route.
      // ASSESS-APPROVAL-HASH-1: and the version of the assessment the step
      // shows. The service refuses another version with 409.
      await api('POST', `assessments/${runSeg()}/approve`,
        runBody({ note, assessmentHash: assessmentVersion }));
      await readRun();
      render();
    } catch (e) { failAction(e); $('#rev').disabled = false; }
  });
}

// PROJECT-1 step one: which piece of work. The entry point for a customer was
// unclear, and whether a project had to exist first was stated nowhere.
// Three of the four doors into this wizard skipped
// projects entirely, so the obvious blue button produced work belonging to
// nothing at all.
//
// ONE front door now, and this is its first question. Asked HERE rather than as
// an errand on another page, and never auto-created: the whole value of a
// project is that a PERSON names it ("Contoso datacentre exit"), which a
// generated name destroys.
let projects = [];
let projectsReadError = null;
async function renderProjectPick(el) {
  if (!projects.length) {
    // COLD-1. Draw the step FIRST, then ask. The project list comes from the
    // facade, and the facade is a PowerShell function on a Consumption plan:
    // after a few idle minutes the next request boots a worker from nothing,
    // which takes 20-40 seconds. This used to fill the panel only after that
    // answer came back, so for the whole wait the step header sat over an
    // EMPTY body and the wizard read as broken.
    //
    // The first step took about 30 seconds, with nothing on screen.
    //
    // The wait is a hosting decision, deferred to INSTALL-1. The blank screen
    // was ours, and it is what made the wait feel like a fault.
    el.innerHTML = card(UX.s0Title, UX.s0Body, `<p class="muted">${esc(UX.s0Loading)}</p>`);
    projectsReadError = null;
    try { projects = (await api('GET', 'projects')).projects ?? []; }
    catch (e) { projects = []; projectsReadError = e; }
  }
  // WIZARD-PROJECTS-ERROR-1: a list that could not be read is not an empty
  // list. Say why (READ-1's failRead) and offer Try again - never "no projects
  // yet" and the create form, which is a false statement.
  if (projectsReadError) {
    failRead(projectsReadError);
    el.innerHTML = card(UX.s0Title, UX.s0Body, `
      <p class="muted">${esc(UX.s0ReadFailed)}</p>
      <div class="nav"><span class="sp"></span>
        <button class="btn" id="p-retry">${esc(UX.s0Retry)}</button></div>`);
    $('#p-retry').addEventListener('click', () => {
      clearErr();
      return renderProjectPick(el).catch(fail);
    });
    return;
  }
  const opts = projects.map(p =>
    `<option value="${esc(p.projectId)}">${esc(p.name)}</option>`).join('');
  el.innerHTML = card(UX.s0Title, UX.s0Body, `
    ${projects.length ? `
      <label class="f" for="f-proj">${esc(UX.s0Existing)}</label>
      <select id="f-proj">${opts}</select>
      <div class="nav" style="margin-bottom:18px"><span class="sp"></span>
        <button class="btn" id="pick">${esc(UX.s0Pick)}</button></div>
      <h3 style="font-size:13px;font-weight:800;margin:18px 0 6px">${esc(UX.s0OrNew)}</h3>`
    : `<p class="muted">${esc(UX.s0None)}</p>`}
    <label class="f" for="f-pname">${esc(UX.s0Name)}</label>
    <input type="text" id="f-pname">
    <p class="muted" id="idhint" style="margin:4px 0 0"></p>
    <div class="nav"><span class="sp"></span>
      ${roleAction('make', UX.s0Create, canOperate, UX.stepNeedsOperator)}</div>`);

  // The id is DERIVED and shown, never asked. It is a path segment, and making
  // somebody think about lower case and hyphens before they can start work is
  // the product's problem leaking into their job.
  const slug = (v) => String(v).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64);
  $('#f-pname').addEventListener('input', () => {
    const id = slug($('#f-pname').value);
    $('#idhint').textContent = id ? `${UX.s0IdHint} ${id}` : '';
  });

  $('#pick')?.addEventListener('click', () => {
    projectId = $('#f-proj').value;
    history.replaceState(null, '', `wizard.html?project=${encodeURIComponent(projectId)}`);
    goStep(STEP.assess.scope);
  });
  $('#make')?.addEventListener('click', async () => {
    const name = $('#f-pname').value.trim();
    const id = slug(name);
    if (!name) return fail(new Error(UX.s0NeedName));
    if (!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(id)) return fail(new Error(UX.s0NeedName));
    try {
      $('#make').disabled = true;
      await api('POST', 'projects', { projectId: id, name });
      projects = [];                       // re-read rather than trust a local copy
      projectId = id;
      history.replaceState(null, '', `wizard.html?project=${encodeURIComponent(projectId)}`);
      goStep(STEP.assess.scope);
    } catch (e) { failAction(e); $('#make').disabled = false; }
  });
}

function renderStep1(el) {
  const subs = scopes?.subscriptions ?? [];
  const mgs = scopes?.managementGroups ?? [];
  el.innerHTML = card(UX.s1Title, UX.s1Body, `
    <label class="f" for="f-name">${esc(UX.runName)}</label>
    <input type="text" id="f-name" value="${esc(runId ?? suggestedRunName())}">
    <p class="muted" style="margin:4px 0 0">${esc(UX.runNameHint)}</p>
    <label class="f">${esc(UX.scopeType)}</label>
    <div class="choices">
      <label><input type="radio" name="sc" value="rg"${form.scopeType === 'rg' ? ' checked' : ''}><span>${esc(UX.scopeRgOpt)}</span></label>
      <label><input type="radio" name="sc" value="subs"${form.scopeType === 'subs' ? ' checked' : ''}><span>${esc(UX.scopeSubsOpt)}</span></label>
      <label><input type="radio" name="sc" value="mg"${form.scopeType === 'mg' ? ' checked' : ''}><span>${esc(UX.scopeMgOpt)}</span></label>
    </div>
    <div id="sc-rg" style="display:${form.scopeType === 'rg' ? '' : 'none'}">
      <label class="f" for="f-sub">${esc(UX.subLabel)}</label>
      <select id="f-sub">${subs.length ? subs.map(s => opt(s.id, s.name, form.sub)).join('') : opt('', scopes ? UX.noneVisible : UX.loading)}</select>
      <label class="f">${esc(UX.rgLabel)}</label>
      <div class="checks" id="f-rgs"><p class="muted">${esc(UX.loading)}</p></div>
    </div>
    <div id="sc-subs" style="display:${form.scopeType === 'subs' ? '' : 'none'}">
      <label class="f">${esc(UX.subsLabel)}</label>
      <div class="checks">${subs.length ? subs.map(s =>
        `<label><input type="checkbox" name="f-subs" value="${esc(s.id)}"${form.subs.includes(s.id) ? ' checked' : ''}>
           <span>${esc(s.name)}<span class="sub mono">${esc(s.id)}</span></span></label>`).join('')
        : `<p class="muted">${esc(scopes ? UX.noneVisible : UX.loading)}</p>`}</div>
    </div>
    <div id="sc-mg" style="display:${form.scopeType === 'mg' ? '' : 'none'}">
      <label class="f" for="f-mg">${esc(UX.mgLabel)}</label>
      <select id="f-mg">${mgs.length ? mgs.map(m => opt(m.id, m.name ?? m.id, form.mg)).join('') : opt('', scopes ? UX.noneVisible : UX.loading)}</select>
    </div>
    <div class="nav">${runId ? '' : `<button class="btn ghost" id="pback">${esc(UX.back)}</button>`}<span class="sp"></span><button class="btn" id="go1"${canOperate ? '' : ' disabled'}>${esc(UX.s1Go)}</button></div>
    ${canOperate ? '' : `<p class="muted" style="margin-top:10px">${esc(UX.needOperator)}</p>`}`);

  // Drawn with no scopes yet: this screen is showing "Loading..." and needs a
  // redraw when they land.
  awaitingScopes = !scopes;

  document.querySelectorAll('input[name=sc]').forEach(r => r.addEventListener('change', (e) => {
    form.scopeType = e.target.value;
    $('#sc-rg').style.display = form.scopeType === 'rg' ? '' : 'none';
    $('#sc-subs').style.display = form.scopeType === 'subs' ? '' : 'none';
    $('#sc-mg').style.display = form.scopeType === 'mg' ? '' : 'none';
  }));
  // SCOPE-PICK-1: SEVERAL resource groups, not one. A real estate is spread
  // across them - the demo estate is six on purpose, because that is what makes
  // grouping by resource group provable - and the only other choice was the
  // whole subscription, which reads machines nobody asked about.
  const loadRgs = async (subId) => {
    if (!subId) return;
    $('#f-rgs').innerHTML = `<p class="muted">${esc(UX.loading)}</p>`;
    try {
      const d = await api('GET', `scopes?subscriptionId=${encodeURIComponent(subId)}`);
      const rgs = d.resourceGroups ?? [];
      $('#f-rgs').innerHTML = rgs.length ? rgs.map(g =>
        `<label><input type="checkbox" name="f-rgs" value="${esc(g.id)}"${form.rgs.includes(g.id) ? ' checked' : ''}>
           <span>${esc(g.name)}</span></label>`).join('')
        : `<p class="muted">${esc(UX.noneVisible)}</p>`;
      $('#f-rgs').querySelectorAll('input[name=f-rgs]').forEach(box => box.addEventListener('change', () => {
        // Held OUTSIDE the DOM, because changing subscription redraws this list
        // and a tick lost to a redraw reads as the box not working.
        form.rgs = [...document.querySelectorAll('input[name=f-rgs]:checked')].map(x => x.value);
      }));
    } catch (e) { $('#f-rgs').innerHTML = `<p class="muted">${esc(VmfHelp.explainAction(e))}</p>`; }
  };
  if (subs.length) { form.sub = form.sub || subs[0].id; loadRgs(form.sub); }
  $('#f-sub')?.addEventListener('change', (e) => { form.sub = e.target.value; loadRgs(form.sub); });
  $('#pback')?.addEventListener('click', () => { goStep(STEP.assess.project); });
  $('#go1').addEventListener('click', startScan);
}

async function startScan() {
  try {
    $('#err').style.display = 'none';
    const name = $('#f-name').value.trim();
    if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(name)) throw new Error(UX.runNameBad);
    // A name that is already in use is a DIFFERENT migration. Starting here
    // would attach this scan to it, which is how the wizard came to announce
    // that a brand-new run was already under way.
    if (!runId) {
      const taken = await blobJson(`${projectId ? projectId + '/' : ''}${name}/run.json`).catch(() => null);
      if (taken) throw new Error(UX.runNameTaken.replace('{name}', name));
    }
    const body = {};
    if (form.scopeType === 'rg') {
      form.sub = $('#f-sub').value;
      // SCOPE-PICK-1: read from the boxes, not from what was remembered - the
      // list is redrawn when the subscription changes, and the ticks on screen
      // are what the person means.
      form.rgs = [...document.querySelectorAll('input[name=f-rgs]:checked')].map(x => x.value);
      if (!form.rgs.length || !form.sub) throw new Error(UX.scopeMissing);
      body.scopeRg = form.rgs; body.scopeSubs = [form.sub];
    } else if (form.scopeType === 'subs') {
      form.subs = [...document.querySelectorAll('input[name=f-subs]:checked')].map(x => x.value);
      if (!form.subs.length) throw new Error(UX.scopeMissing);
      body.scopeSubs = form.subs;
    } else {
      form.mg = $('#f-mg').value;
      if (!form.mg) throw new Error(UX.scopeMissing);
      body.scopeMg = form.mg;
    }
    $('#go1').disabled = true;
    // RUNID-2: the project travels in the BODY, not the path - the route is
    // runs/{runId}/engine/{op} and a slash in the id matches nothing. This was
    // written by hand here, correctly, and by hand elsewhere, wrongly.
    const newId = VmfHelp.VmfRun.storePath(projectId, name);
    await api('POST', `runs/${VmfHelp.VmfRun.routeSegment(newId)}/engine/assess`,
              VmfHelp.VmfRun.withProject(body, newId));
    runId = name;
    // SCAN-FAIL-SHOWN-1 review: a new start waits again.
    scanStopped = null;
    history.replaceState(null, '', runHref('wizard.html'));
    waitOn(STEP.assess.findings); render(); startPolling();
  } catch (e) { failAction(e); $('#go1').disabled = false; }
}

function foundRows() {
  const WORDS = {
    ReadyAfterPrep: ['Yes', ''],
    Blocked: ['Not yet', 'bad'], Excluded: ['Not eligible', 'quiet'],
    SomeTargets: ['Some targets only', 'warn'],
    Current: [UX.grpCurrent, 'quiet'],
  };
  // ASSESS-PAGE-1: the wording comes from the engine's own
  // assessment-reasons.json, copied here by the deploy. This used to be an
  // inline list, and it was missing five of the seven blockers - a machine held
  // back as confidential, or for an unsupported image, showed the raw code.
  return (assessment?.vms ?? []).map(v => {
    // ASSESS-COUNT-1: the scan says Blocked once for every series; a machine
    // with a series still open is "some targets only", as the review counts it.
    // ALREADY-CURRENT-1: a machine on a Current size is Current, with its line.
    const current = window.VmfReport.isCurrent(v);
    const own = v.classification;
    const shown = current ? 'Current' : own === 'Blocked' && window.VmfReport.canMigrate(v) ? 'SomeTargets' : own;
    const [word, cls] = WORDS[shown] ?? [v.classification, 'quiet'];
    const why = current ? window.VmfReport.machineWhy(v) : [...(v.blockers ?? []), ...(v.prepNeeded ?? [])].map(reasonText).join('; ');
    return `<tr><td class="mono">${esc(v.name)}</td><td class="muted">${esc(v.resourceGroup)}</td>
      <td class="mono">${esc(v.sourceSize)}</td><td><span class="pill ${esc(cls)}">${esc(word)}</span></td>
      <td class="muted">${esc(why)}</td></tr>`;
  }).join('');
}

/* Same rule as the Assessments page: the NARROWEST level is what was scanned,
 * the wider ones are where it sits. Flattening them into one comma list made a
 * single resource group read as a resource group AND a whole subscription -
 * which is the difference between eight machines and eight hundred. */
function scopeSummary() {
  const sc = assessment?.scope;
  if (!sc) return '';
  const subName = (id) => (scopes?.subscriptions ?? []).find(x => x.id === id)?.name || id;
  const subs = (sc.subscriptions ?? []).filter(Boolean);
  // WIZARD-SCOPE-NULL-1: a scan saved before SCAN-SCOPE-NULL-1 holds
  // resourceGroups [null] for "no group filter". Take the nulls out, as the
  // Assessments page does, or it names a blank group inside the subscription.
  const rgs = (sc.resourceGroups ?? []).filter(Boolean);
  const inside = subs.length === 1 ? ` ${UX.s2NoneIn}${subName(subs[0])}`
    : subs.length ? ` ${UX.s2NoneIn}${subs.map(subName).join(', ')}`
    : sc.managementGroup ? ` ${UX.s2NoneInGroup}${sc.managementGroup}` : '';

  let what;
  if (rgs.length) what = rgs.join(', ') + inside;
  else if (subs.length) what = (subs.length === 1 ? UX.s2NoneWholeSub : UX.s2NoneWholeSubs) + subs.map(subName).join(', ');
  else if (sc.managementGroup) what = UX.s2NoneWholeGroup + sc.managementGroup;
  else return '';
  return `<p class="muted">${esc(UX.s2NoneWhere)} ${esc(what)}</p>`;
}

function renderStep2(el) {
  if (!assessment) {
    el.innerHTML = card(UX.s2Title, UX.s2Body, scanWaitHtml(scanStopped));
    wireScanBack();
    return;
  }
  const n = (assessment.vms ?? []).length;
  el.innerHTML = card(UX.s2Title, UX.s2Body, n ? `
    <table><thead><tr><th>${esc(UX.colMachine)}</th><th>${esc(UX.colWhere)}</th><th>${esc(UX.colSize)}</th>
      <th>${esc(UX.colCan)}</th><th>${esc(UX.colNeeds)}</th></tr></thead><tbody>${foundRows()}</tbody></table>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      <button class="btn" id="n">${esc(UX.s2Next)}</button></div>`
    : `<p><strong>${esc(UX.s2None)}</strong></p>
       ${scopeSummary()}
       <p class="muted">${esc(UX.s2NoneWhy)}</p>
       <div class="nav"><button class="btn" id="b">${esc(UX.s2NoneAgain)}</button></div>`);
  $('#b')?.addEventListener('click', () => { goStep(STEP.assess.scope); });
  $('#n')?.addEventListener('click', () => { goStep(STEP.assess.review); });
}

function renderStep3(el) {
  // BACKLOOP-1: a migration that already has a plan. Planning again from here
  // would not re-group THIS migration - the engine makes a new one from the
  // assessment every time - so the step says what is true and offers both
  // ways out: forward to the waves, and Back to the assessment.
  if (plan && (plan.entries ?? []).length) {
    el.innerHTML = card(UX.s3Title, UX.s3Planned, `
      <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
        <a class="btn" id="to-waves" href="${esc(runHref('waves.html', { flow: 1 }))}">${esc(UX.s3ToWaves)}</a></div>`);
    $('#b').addEventListener('click', backToAssessment);
    return;
  }
  // WIZARD-WAVES-STEP-1: a MIGRATION with no plan yet is one the engine is
  // planning now - the grouping was chosen on the assessment. A load of this
  // address while it plans (a sign-in, a tab the browser discarded, a reload)
  // drew the grouping form here, with nothing watching for the plan; and Build
  // the waves on a migration would be refused. So it waits, and watches.
  // WIZARD-PLAN-FAIL-1: the engine refused this migration's plan. Asked first:
  // until the next read, the record held is still the assessment's.
  if (planRefused && planRefused.migrationId === runId) { renderPlanRefused(el); return; }
  if (isMigration()) {
    renderPlanWait(el);
    if (!poll) { startPolling(); }
    watchPlanRefusal();
    return;
  }
  // MACHINE-PICK-1: the tags of the machines in this migration.
  const chosenVms = onlyChosen(assessment?.vms, machineChoices);
  const keys = [...new Set((chosenVms.length ? chosenVms : (assessment?.vms ?? [])).flatMap(v => Object.keys(v.tags ?? {})))].sort();
  const noTags = !keys.length;
  const tagOpts = (none) => noTags ? opt('', UX.tagsNone) : opt('', none) + keys.map(k => opt(k, k, '')).join('');
  el.innerHTML = card(UX.s3Title, UX.s3Body, `
    <div class="choices">
      <label><input type="radio" name="g" value="tags"${form.strategy === 'tags' ? ' checked' : ''}><span>${esc(UX.gTags)}</span></label>
      <label><input type="radio" name="g" value="resourceGroup"${form.strategy === 'resourceGroup' ? ' checked' : ''}><span>${esc(UX.gRg)}</span></label>
      <label><input type="radio" name="g" value="singleWave"${form.strategy === 'singleWave' ? ' checked' : ''}><span>${esc(UX.gSingle)}</span></label>
      <label><input type="radio" name="g" value="none"${form.strategy === 'none' ? ' checked' : ''}><span>${esc(UX.gNone)}</span></label>
    </div>
    <div id="g-tags">
      <label class="f" for="f-apptag">${esc(UX.appTag)}</label><select id="f-apptag">${tagOpts(UX.tagNoneApp)}</select>
    </div>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      ${roleAction('go3', UX.s3Go, canOperate, UX.stepNeedsOperator)}</div>`);
  const sync = () => {
    $('#g-tags').style.display = form.strategy === 'tags' ? '' : 'none';
  };
  document.querySelectorAll('input[name=g]').forEach(r => r.addEventListener('change', (e) => { form.strategy = e.target.value; sync(); }));
  sync();
  // ADVISOR-1: choosing each target is the step before this one now, so Back
  // goes there. WIZARD-BACK-TARGETS-1: and the poll leaves the person there.
  $('#b').addEventListener('click', () => { goStep(STEP.migrate.targets); });
  $('#go3')?.addEventListener('click', buildWaves);
}
// WIZARD-WAVES-STEP-1: the step while the engine writes the plan. One view for
// the page that pressed Build the waves and for a page loaded while it plans,
// with Back to the assessment, as the planned migration offers.
function renderPlanWait(el) {
  el.innerHTML = card(UX.s3Title, UX.s3Body, `<div class="working" id="plan-wait"><span class="spin"></span>${esc(UX.s3Working)}</div>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button></div>`);
  $('#b').addEventListener('click', backToAssessment);
}
// WIZARD-PLAN-FAIL-1: the engine refused to plan. Nothing more is coming, so
// no spinner: the engine's reason, what to do, and Back to the assessment -
// where the machines and their targets are chosen again.
function renderPlanRefused(el) {
  el.innerHTML = card(UX.s3Title, UX.s3Body, `<p id="plan-refused" style="color:var(--bad)">${esc(UX.s3Refused.replace('{reason}', planRefused.detail))}</p>
    <p>${esc(UX.s3RefusedNext)}</p>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button></div>`);
  $('#b').addEventListener('click', backToAssessment);
}

/* WIZARD-PLAN-FAIL-1: A REFUSED PLAN WAITED FOR EVER.
 *
 * The engine plans from the ASSESSMENT (VMF_RUN_ID), so when it refuses - no
 * target saved, targets saved for another list of machines - its fail line
 * goes in the assessment's log (docker/entrypoint.ps1), and the migration may
 * never get a run.json. The watch for the plan reads only the migration, so
 * this reads the assessment's log beside it, through WATCH-1's loop.
 *
 * WHICH LINE IS THE ANSWER. The engine names the migration it was planning on
 * its fail line. A refusal of an earlier plan of the same assessment names
 * another migration, so it is never this one's answer - and that holds on a
 * reload, where the page has no time of its own to count from. A clock
 * window would have to guess one.
 *
 * NO FALSE FAILURE. When nothing arrives in PLAN_QUIET_MIN minutes, the page
 * says so and goes on looking: a slow engine is not a refusal.
 *
 * PURE: the events, and the migration being waited for.
 */
function planRefusal(events, migrationId) {
  if (!migrationId) { return null; }
  let failure = null;
  for (const e of (events ?? [])) {
    // LOG-SAYS-WHY-1: a refusal is an answer as much as a failure. The engine's
    // catch writes 'fail' today; a 'refused' line would say the same to this step.
    if (e && String(e.step) === 'engine:plan' && (e.outcome === 'fail' || e.outcome === 'refused') && e.migrationId === migrationId) { failure = e; }
  }
  return failure ? { failure } : null;
}
// Still the page that waits for THIS migration's plan, with no plan and no refusal.
function planStillWaiting(watch) {
  return planWatch === watch && runId === watch.migrationId && journey === 'migrate'
    && step === STEP.migrate.group && !(plan && (plan.entries ?? []).length) && !planRefused;
}
async function watchPlanRefusal() {
  const from = (manifest && manifest.fromAssessment) || plannedFrom || planningFrom();
  if (DEMO_MODE || !from || !runId) { return; }
  if (planWatch && planWatch.migrationId === runId) { return; }   // one watch per migration
  const watch = { migrationId: runId, logPath: `${VmfHelp.VmfRun.storePath(projectId, from)}/logs/events.jsonl` };
  planWatch = watch;
  watch.done = (async () => {
    // Rounds of WATCH-1's loop, each with its deadline: the quiet notice after
    // the first. The log is read for as long as the page waits for the plan,
    // as the watch for the plan itself is (no deadline there, see
    // startPolling) - a refusal after a slow job start is still this answer.
    // It ends when the plan lands, the refusal is shown, or the page moves on.
    for (let round = 0; ; round++) {
      const verdict = await VmfHelp.watchRun({
        readLines: async () => VmfHelp.readLogEvents(blobText, watch.logPath),
        timeoutMs: PLAN_QUIET_MIN * 60000,
        // The plan landed, or the person left: this watch has no answer to give.
        onTick: async () => (planStillWaiting(watch) ? null : { gone: true }),
        scan: (events) => planRefusal(events, watch.migrationId),
      });
      if (!planStillWaiting(watch)) { return; }
      if (verdict && verdict.failure) {
        // The plan wins. The capacity check runs after New-VmfPlan writes
        // plan.json, and its failure is a fail line of this plan too - but a
        // plan exists, so "no plan was made" would be false. The watch for the
        // plan opens it. A read that fails is not an answer: ask again.
        let landed;
        try { landed = await blobJson(`${VmfHelp.VmfRun.storePath(projectId, watch.migrationId)}/plan.json`); }
        catch (e) { continue; }
        if ((landed?.entries ?? []).length || !planStillWaiting(watch)) { return; }
        planRefused = { migrationId: watch.migrationId, detail: String(verdict.failure.detail ?? '') };
        if (poll) { clearInterval(poll); poll = null; }
        renderPlanRefused($('#step'));
        return;
      }
      if (round === 0) {
        const wait = $('#plan-wait');
        if (wait) { wait.innerHTML = `<span class="spin"></span>${esc(UX.s3Quiet.replace('{n}', String(PLAN_QUIET_MIN)))}`; }
      }
    }
  })();
  return watch.done;
}

// ---------- MACHINE-PICK-1: choose the machines ----------
// A scan of a resource group, a subscription or a management group finds every
// machine there, and many are not meant to move. This step comes first: the
// machines the review lists, NOTHING ticked at first, four filters that combine,
// and a list saved with the version the service issued (PLANVER-2). Only the
// chosen machines get a target and a wave. The functions below take what they
// need as arguments, so tests/js/choose-step.test.js RUNS them.
const M_PAGE = 50;
let mChosen = new Set(), mLoadedFrom = null, mShown = M_PAGE, mRefused = false, mRows = [];
// CLAIM-AT-PLAN-1: the machines another migration holds (heldFrom): undefined
// before the read, null when it could not be read. mHeldFor: the run it is for.
let mHeld, mHeldFor = '';
const mFilter = { sub: '', rg: '', tag: '', name: '' };
const subOfId = (id) => (String(id ?? '').match(/\/subscriptions\/([^/]+)/i) ?? [])[1] ?? '';
// The rule the engine holds too (Set-VmfMachineChoice): a machine can be chosen
// when the target options give it a supported series. ALREADY-CURRENT-1: and
// when the size it is on now is not in the Current lifecycle stage (the
// options' sourceStage, Get-VmfAdviceStage).
function canChoose(adv) {
  return adv?.sourceStage?.stage !== 'Current' && (adv?.options ?? []).some(o => o.supported);
}
// The assessment group of a machine, in the words of the review and the
// Assessments page.
// The review decides the group (canMigrate is VmfReport.canMigrate, the rule
// every page counts by); the target options decide whether it can be ticked.
// ALREADY-CURRENT-1: `report` is VmfReport; its isCurrent puts a machine on a
// Current size in the group Current, before every other group.
// A machine on NVMe that is not on a Current size (Ebsv5, Ebdsv5) is in the
// group of any other machine.
function chooseGroup(vm, canMigrate, report) {
  if (report?.isCurrent?.(vm)) return 'current';
  if (canMigrate(vm)) return vm?.classification === 'Blocked' ? 'some' : 'can';
  return 'cannot';
}
function tagPairs(tags) {
  return Object.entries(tags ?? {}).filter(([k]) => k).map(([k, v]) => `${k}=${v ?? ''}`);
}
// One row for each machine the review lists: never one that is Excluded or
// platform-managed (VmfReport.openSeries has the same rule).
// CLAIM-AT-PLAN-1: `held` (heldFrom) names the migration that holds a machine;
// such a machine cannot be ticked - the start check would refuse it.
// ALREADY-CURRENT-1: `report` (VmfReport) gives each row its line - the
// Current line, or the reasons of a machine that cannot yet move.
function chooseRows(vms, adviceMachines, nameOf, canMigrate, held, report) {
  const advOf = new Map((adviceMachines ?? []).map(m => [VmfHelp.idKey(m.vmId), m]));
  return (vms ?? []).filter(v => v && v.classification !== 'Excluded' && !v.platformManaged).map(v => {
    const adv = advOf.get(VmfHelp.idKey(v.vmId));
    const heldBy = held?.get(VmfHelp.idKey(v.vmId)) ?? '';
    const group = chooseGroup(v, canMigrate, report);
    return { vmId: adv?.vmId ?? v.vmId, name: v.name || nameOf(v.vmId), sub: subOfId(v.vmId), rg: String(v.resourceGroup ?? ''),
      tags: v.tags ?? {}, group, why: report?.machineWhy?.(v) ?? '',
      tickable: group !== 'current' && canChoose(adv) && !heldBy, heldBy,
      // AN-MANA-DRIVER-RULE-1: a Linux release with no MANA driver possible says what to do.
      upgrade: adv ? manaUpgradeText(adv) : '' };
  }).sort((a, b) => a.sub.localeCompare(b.sub) || a.rg.localeCompare(b.rg) || a.name.localeCompare(b.name));
}
// CLAIM-AT-PLAN-1: the machines another live migration holds, from the run
// summary (Get-VmfHeldMachines - the start check's own rule): the machine's
// key -> the migration that holds it. null when the service could not read the
// claims, or gave no list: unknown is never read as free.
function heldFrom(summary) {
  if (!summary || !Array.isArray(summary.held)) return null;
  return new Map(summary.held.filter(h => h && h.vmId).map(h => [VmfHelp.idKey(h.vmId), String(h.heldBy ?? '')]));
}
// The line under the list when the held machines could not be read. Nothing
// before the read (undefined) or after a good one.
function chooseHeldNote(held) {
  return held === null ? `<p class="muted" id="m-held-unknown">${esc(UX.mHeldUnknown)}</p>` : '';
}
// The four filters together. A tag is one name and value, and matches in any
// subscription; a name matches any part of the machine name.
function chooseMatches(rows, f) {
  const name = String(f.name ?? '').trim().toLowerCase();
  return rows.filter(r => (!f.sub || r.sub === f.sub)
    && (!f.rg || r.rg.toLowerCase() === String(f.rg).toLowerCase())
    && (!f.tag || tagPairs(r.tags).includes(f.tag))
    && (!name || String(r.name).toLowerCase().includes(name)));
}
// What each filter offers. The resource groups are those of the chosen
// subscription; the tags are those of every machine.
function chooseOptions(rows, f) {
  // Once each, whatever the letter case: Azure resource group names ignore it.
  const uniq = (list) => [...new Map(list.map(v => [String(v).toLowerCase(), v])).values()].sort((a, b) => a.localeCompare(b));
  return {
    subs: uniq(rows.map(r => r.sub)),
    rgs: uniq(rows.filter(r => !f.sub || r.sub === f.sub).map(r => r.rg).filter(Boolean)),
    tags: uniq(rows.flatMap(r => tagPairs(r.tags))),
  };
}
// Add and Remove act on EVERY machine the filters match, not only the rows on
// screen. Add takes only a machine that can be chosen.
function chooseAdd(chosen, rows, f) {
  const out = new Set(chosen);
  for (const r of chooseMatches(rows, f)) { if (r.tickable) out.add(r.vmId); }
  return out;
}
function chooseRemove(chosen, rows, f) {
  const out = new Set(chosen);
  for (const r of chooseMatches(rows, f)) out.delete(r.vmId);
  return out;
}
// Where the ticks start: the saved list; else nothing. Saved targets never
// stand for the list: the wizard saves it before any target.
function chooseStart(saved, rows) {
  const ids = saved ? (saved.machines ?? []) : [];
  const keys = new Set(ids.map(VmfHelp.idKey));
  return new Set(rows.filter(r => r.tickable && keys.has(VmfHelp.idKey(r.vmId))).map(r => r.vmId));
}
// The machines the targets step and Export for pricing show: the saved list.
// None before it.
function onlyChosen(adviceMachines, machines) {
  const ids = machines ? (machines.machines ?? []) : null;
  if (!ids) return [];
  const keys = new Set(ids.map(VmfHelp.idKey));
  return (adviceMachines ?? []).filter(m => keys.has(VmfHelp.idKey(m.vmId)));
}
function chooseFiltersHtml(rows, f, subName) {
  const o = chooseOptions(rows, f);
  const sel = (id, label, list, cur, show) => `<label>${esc(label)}<select id="${id}"><option value="">${esc(UX.mAny)}</option>${list.map(v =>
    `<option value="${esc(v)}"${v === cur ? ' selected' : ''}>${esc(show ? show(v) : v)}</option>`).join('')}</select></label>`;
  return `<div class="m-filters">${sel('m-sub', UX.mSub, o.subs, f.sub, subName)}${sel('m-rg', UX.mRg, o.rgs, f.rg)}${sel('m-tag', UX.mTag, o.tags, f.tag)}
    <label>${esc(UX.mFind)}<input type="text" id="m-find" value="${esc(f.name)}" autocomplete="off"></label></div>`;
}
// The buttons, the count and a page of rows. Show more adds a page; Show fewer
// goes back to the first one. Nothing closes unless it is clicked.
function chooseListHtml(rows, chosen, f, shown, subName) {
  const match = chooseMatches(rows, f);
  const n = match.filter(r => r.tickable).length;
  const words = { can: UX.grpCan, some: UX.grpSome, cannot: UX.grpCannot, current: UX.grpCurrent };
  const tone = { can: 'good', some: 'warn', cannot: 'bad', current: 'quiet' };
  const body = match.slice(0, shown).map(r => `<tr><td><input type="checkbox" class="m-pick" data-vm="${esc(r.vmId)}" aria-label="${esc(fill(UX.mPick, { name: r.name }))}"${chosen.has(r.vmId) ? ' checked' : ''}${r.tickable ? '' : ' disabled'}></td>
      <td class="mono">${esc(r.name)}</td><td>${esc(subName(r.sub))}</td><td>${esc(r.rg)}</td><td class="m-tags">${esc(tagPairs(r.tags).join(', '))}</td>
      <td><span class="pill ${tone[r.group]}">${esc(words[r.group])}</span>${r.heldBy ? `<div class="muted m-why m-held">${esc(fill(UX.mHeld, { run: r.heldBy }))}</div>`
        : !r.tickable && (r.group === 'can' || r.group === 'some') ? `<div class="muted m-why">${esc(r.upgrade || UX.mNoOption)}</div>`
        : r.why && (r.group === 'current' || r.group === 'cannot') ? `<div class="muted m-why">${esc(r.why)}</div>` : ''}</td></tr>`).join('');
  const head = `<thead><tr><th></th><th>${esc(UX.mColMachine)}</th><th>${esc(UX.mSub)}</th><th>${esc(UX.mRg)}</th><th>${esc(UX.mColTags)}</th><th>${esc(UX.mColAssess)}</th></tr></thead>`;
  return `<div class="rowact m-bulk">
      <button type="button" class="btn small ghost" id="m-add"${n ? '' : ' disabled'}>${esc(n === 1 ? UX.mAddShownOne : fill(UX.mAddShown, { n }))}</button>
      <button type="button" class="btn small ghost" id="m-remove"${match.length ? '' : ' disabled'}>${esc(UX.mRemoveShown)}</button>
      <span class="sp"></span><span class="muted" id="m-count">${esc(fill(UX.mCount, { x: chosen.size, y: rows.length }))}</span></div>
    ${match.length ? `<table>${head}<tbody>${body}</tbody></table>` : `<p class="muted">${esc(rows.length ? UX.mNoMatch : UX.mEmpty)}</p>`}
    ${match.length > shown || shown > M_PAGE ? `<div class="rowact">
      ${match.length > shown ? `<button type="button" class="btn small ghost" id="m-more">${esc(UX.mShowMore)}</button>` : ''}
      ${shown > M_PAGE ? `<button type="button" class="btn small ghost" id="m-fewer">${esc(UX.mShowFewer)}</button>` : ''}</div>` : ''}`;
}
// The name a subscription has on the scope step, when the service gave one.
function subDisplayName(id) {
  return (scopes?.subscriptions ?? []).find(x => x.id === id)?.name || id;
}
// The rows as the run and the held machines say now. CLAIM-AT-PLAN-1: a machine
// another migration holds is never left chosen - the start would refuse it.
function chooseRowsNow() {
  mRows = chooseRows(assessment?.vms, targetAdvice.machines, vmName, window.VmfReport.canMigrate, mHeld, window.VmfReport);
  for (const r of mRows) { if (r.heldBy) mChosen.delete(r.vmId); }
}
// CLAIM-AT-PLAN-1: which machines other migrations hold, from the run summary,
// once for each run this step shows. held=1 asks the service for that list;
// a plain summary does not read the claims. The list is drawn again when it lands.
async function readHeld() {
  const run = runFullId();
  if (mHeldFor === run) return;
  mHeldFor = run;
  let got = null;
  try { got = heldFrom(await api('GET', `runs/${runSeg()}/summary`, null, VmfHelp.VmfRun.withProject({ held: 1 }, run))); }
  catch { got = null; }
  if (mHeldFor !== run) return;
  mHeld = got;
  if (step === STEP.migrate.choose && targetAdvice && $('#m-list')) { chooseRowsNow(); paintChooseList(); }
}
function renderChoose(el) {
  if (!targetAdvice) { renderAdviceWait(el, UX.mTitle, '', backToAssessment); return; }
  chooseRowsNow();
  // The saved list, once for each version of it this page reads.
  const from = `${machinesVersion}|${adviceVersion}`;
  if (mLoadedFrom !== from) { mLoadedFrom = from; mChosen = chooseStart(machineChoices, mRows); }
  readHeld();
  // Every machine the assessment found, as the review counts them.
  const found = assessment?.vms ?? [];
  const subs = new Set(found.map(v => subOfId(v.vmId))).size;
  el.innerHTML = card(UX.mTitle, fill(subs === 1 ? UX.mBodyOneSub : UX.mBody, { n: found.length, subs }), `
    ${chooseFiltersHtml(mRows, mFilter, subDisplayName)}
    <div id="m-list"></div>
    ${mRefused ? `<p class="m-none" id="m-none" role="alert">${esc(UX.mNone)}</p>` : ''}
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      ${roleAction('m-continue', UX.mContinue, canOperate, UX.stepNeedsOperator)}</div>`);
  const pick = (key) => (e) => {
    mFilter[key] = e.target.value;
    // A resource group the chosen subscription does not hold is not a filter.
    if (key === 'sub' && mFilter.rg && !chooseOptions(mRows, mFilter).rgs.includes(mFilter.rg)) mFilter.rg = '';
    mShown = M_PAGE; render();
  };
  $('#m-sub').addEventListener('change', pick('sub'));
  $('#m-rg').addEventListener('change', pick('rg'));
  $('#m-tag').addEventListener('change', pick('tag'));
  // Typing redraws the list only, so the box keeps its focus.
  $('#m-find').addEventListener('input', (e) => { mFilter.name = e.target.value; mShown = M_PAGE; paintChooseList(); });
  $('#b').addEventListener('click', backToAssessment);
  $('#m-continue')?.addEventListener('click', saveMachines);
  paintChooseList();
}
function paintChooseList() {
  const list = $('#m-list');
  if (!list) return;
  list.innerHTML = chooseListHtml(mRows, mChosen, mFilter, mShown, subDisplayName) + chooseHeldNote(mHeld);
  // WIZARD-ROLES-3: only an operator saves the machines.
  if (!canOperate) { lockChoices(list, '.m-pick, #m-add, #m-remove'); }
  const changed = () => { if (mChosen.size && mRefused) { mRefused = false; $('#m-none')?.remove(); } paintChooseList(); };
  $('#m-add').addEventListener('click', () => { mChosen = chooseAdd(mChosen, mRows, mFilter); changed(); });
  $('#m-remove').addEventListener('click', () => { mChosen = chooseRemove(mChosen, mRows, mFilter); changed(); });
  $('#m-more')?.addEventListener('click', () => { mShown += M_PAGE; paintChooseList(); });
  $('#m-fewer')?.addEventListener('click', () => { mShown = M_PAGE; paintChooseList(); });
  document.querySelectorAll('.m-pick').forEach(c => c.addEventListener('change', () => {
    if (c.checked) mChosen.add(c.dataset.vm); else mChosen.delete(c.dataset.vm);
    changed();
  }));
}
// Continue: refused on the screen with no machine chosen. A list the same as
// the saved one is not saved again - a save records the person who made it,
// and the saved targets are bound to the version of the list.
async function saveMachines() {
  if (!mChosen.size) { mRefused = true; render(); return; }
  const ids = [...mChosen];
  const same = Boolean(machineChoices) && (machineChoices.machines ?? []).length === ids.length
    && ids.every(id => (machineChoices.machines ?? []).some(x => VmfHelp.idKey(x) === VmfHelp.idKey(id)));
  const btn = $('#m-continue');
  try {
    clearErr();
    if (btn) btn.disabled = true;
    if (!same) {
      await api('POST', `assessments/${runSeg()}/machines`, runBody({ machines: ids, adviceVersion, machinesVersion }));
      // The sample has no service to keep the list, so the page keeps it.
      if (DEMO_MODE) DEMO[`${runPrefix()}/machine-choices.json`] = { machines: ids };
      said(UX.mSaved);
      await readRun();
    }
    const url = new URL(location.href);
    // The address names the targets step, so a reload stays there - the person
    // came to check the targets (BACKLOOP-1). Save the targets takes it off.
    url.searchParams.set('step', 'targets'); history.replaceState(null, '', url);
    mRefused = false;
    goStep(STEP.migrate.targets);
  } catch (e) { failAction(e); if (btn) btn.disabled = false; }
}
// Back on the targets step. The address names this step, so a reload stays here.
function toChoose() {
  const url = new URL(location.href);
  url.searchParams.set('step', 'choose'); history.replaceState(null, '', url);
  goStep(STEP.migrate.choose);
}

// ---------- ADVISOR-1: choose each target ----------
// The options come from the engine (target-advice.json), made when the review
// was approved. The screen shows the options only - the default at the top, one
// row per machine, a list of the options THAT machine can take - and the facts
// behind a Details button on every row. The save quotes back the versions the
// service issued (PLANVER-2).
let tDefault = 'current', tOverrides = new Map(), tSizes = new Map(), tDiskSel = new Map(), tOpen = new Set(), tLoadedFrom = null;
// MANA-LINUX-KERNEL-1: each machine whose kernel choice differs from Stop and ask.
// KERNEL-UX-1: the page offers no default any more, so the default is always
// Stop and ask (KERNEL-DEFAULT-EARLIER-1: the service refuses another one).
// tKSeen: the machines whose Details were opened, or that an All button set,
// in this session.
const tKernelDef = 'stop';
let tKernelSel = new Map(), tKSeen = new Set();
// TEMPDISK-UX-1: the machines whose Details were opened while the size they go
// to has no temporary disk (tempLost), in this session.
let tTSeen = new Set();
// ADVISE-AN-1: the same, while the size turns off accelerated networking (anLost).
let tASeen = new Set();
const shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
const fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
// Azure reports a machine's VM generation as V1 or V2; unknown is never a guess.
function advGenLabel(gen) { return gen === 'V1' ? UX.vGen1 : gen === 'V2' ? UX.vGen2 : UX.vUnknown; }
// BSV2-TARGET-1: the series a person reads for a machine on an option - Bsv2
// for a Bsv2 size, which the engine plans on v5 because it follows the v5
// rules, and the option otherwise. By the size the machine goes to there.
function advSeriesLabel(m, option, sizes) {
  return VmfHelp.seriesLabel(option, sizeOf(m, option, sizes));
}
// TARGETS-HINTS-1: the order each default starts a machine on - the engine's
// $currentOrder and $extendedOrder (Get-VmfTargetAdvice), which
// tests/js/targets-hints.test.js holds this to. A B v1 machine starts on
// Bsv2 first under both, which the engine offers on v5.
const T_START_ORDER = {
  current: ['v6', 'v7', 'v5'],
  extended: ['v5', 'v6', 'v7'],
};
// REBUILD-REMOVE-PLAN-1 review (hard rule 12): the help gives the steps in the Azure
// portal only. TEMP-DISK-PREVIEW-1 also listed Azure CLI and PowerShell commands to
// copy, which handed the person a command to run elsewhere.
// The series of a default: the first of its order. Anything but Extended
// reads as Current, as a saved default does.
function tDefSeries(def) {
  return T_START_ORDER[def === 'extended' ? 'extended' : 'current'][0];
}
// The hint under a lifecycle stage: what that default gives.
// STAGE-HINT-WORDS-1: Current says its last choice is in the Extended stage.
function tStartHint(def) {
  const extended = def === 'extended';
  const [a, b, c] = T_START_ORDER[extended ? 'extended' : 'current'];
  return `${fill(extended ? UX.tStartOrder : UX.tStartCurrent, { a, b, c })} ${UX.tStartBsv2}`;
}
function advPick(m, def, overrides) {
  return overrides.has(m.vmId) ? overrides.get(m.vmId) : (m.start?.[def] ?? null);
}
function advWhy(o) {
  return (o.notSupported ?? []).map(c => UX.whyNot[c] ?? reasonText(c)).join(', ');
}
// ADVISE-AN-1: each machine's group - the series a person reads, and why it is
// not on the series of the default. Every reason comes from the advice: the
// person's own change, a Bsv2 size, accelerated networking kept, or the
// default's option refused with its own reason. A machine still to choose,
// and one with no target, are groups of their own.
function advGroups(machines, def, overrides, sizes) {
  const defSeries = tDefSeries(def);
  const out = [];
  for (const m of machines ?? []) {
    const p = advPick(m, def, overrides);
    if (!p) { out.push({ kind: 'none', label: '', why: 'none' }); continue; }
    const label = advSeriesLabel(m, p, sizes);
    let why = '';
    if (label !== defSeries) {
      const d = (m.options ?? []).find(x => x.option === defSeries);
      const picked = (m.options ?? []).find(x => x.option === p);
      if (overrides.has(m.vmId) && overrides.get(m.vmId) !== (m.start?.[def] ?? null)) why = 'person';
      else if (label === 'Bsv2') why = 'bsv2';
      else if (d && d.supported && d.acceleratedNetworking?.keptOn === false && picked?.acceleratedNetworking?.keptOn === true) why = 'an';
      else if (d && !d.supported && (d.notSupported ?? []).includes('gen1-requires-redeploy')) why = 'gen1';
      else if (d && !d.supported) why = 'not:' + advWhy(d);
    }
    out.push({ kind: 'on', label, why });
  }
  return out;
}
function advSummary(machines, def, overrides, sizes) {
  const groups = advGroups(machines, def, overrides, sizes);
  const counts = new Map();
  for (const g of groups) if (g.kind === 'on') counts.set(g.label, (counts.get(g.label) ?? 0) + 1);
  const parts = [...counts.entries()].sort(([a, x], [b, y]) => (y - x) || a.localeCompare(b))
    .map(([s, n]) => fill(UX.tOn, { n, series: s }));
  const none = groups.filter(g => g.kind === 'none').length;
  if (none) parts.push(fill(UX.tNoneCount, { n: none }));
  // REBUILD-REMOVE-PLAN-1: no machine waits for a choice, and no target
  // deletes a system-assigned identity, so neither is counted.
  return fill(UX.tSummary, { n: (machines ?? []).length, parts: parts.join(' · ') });
}
// The text behind the (?) of the summary: one line for each group that is not
// on the default, with its reason. Empty when every machine is on it.
function advSummaryHelpHtml(machines, def, overrides, sizes) {
  const defSeries = tDefSeries(def);
  const lines = new Map();
  for (const g of advGroups(machines, def, overrides, sizes)) {
    if (g.kind === 'on' && !g.why) continue;
    const key = `${g.kind}|${g.label}|${g.why}`;
    const entry = lines.get(key) ?? { g, n: 0 };
    entry.n++;
    lines.set(key, entry);
  }
  const whyText = (g, n) => g.why === 'none' ? UX.tWhyNone : g.why === 'person' ? UX.tWhyPerson : g.why === 'bsv2' ? UX.tWhyBsv2
    : g.why === 'gen1' ? UX.tWhyGen1 : g.why === 'an' ? fill(UX.tWhyAn, { series: defSeries })
    : fill(UX.tWhyNot, { series: defSeries, why: g.why.slice(4) });
  const items = [...lines.values()].map(({ g, n }) => {
    const part = g.kind === 'none' ? fill(UX.tNoneCount, { n }) : fill(UX.tOn, { n, series: g.label });
    return `<li>${esc(fill(UX.tGroupLine, { part, why: whyText(g, n) }))}</li>`;
  });
  return items.length ? `<ul class="muted t-help-text" id="t-help-sum">${items.join('')}</ul>` : '';
}
// The method of the size a machine goes to on an option (REBUILD-PICKER-1,
// TEMP-DISK-PREVIEW-1): 'preview' where the engine says the move is the
// in-place upgrade (Preview) - its preview fact, of the size choice or else of
// the option - and 'in-place' for every other move; null with no option.
// REBUILD-REMOVE-PLAN-1: never 'rebuild', and never a person's choice: the
// Preview is the one move of its shape, so the method is a fact of the size.
function tMethodOf(m, option, sizes) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  if (!o) return null;
  const size = sizeOf(m, option, sizes);
  const f = (o.sizeChoices ?? []).find(x => x.size === size) ?? o;
  return f.preview === true ? 'preview' : 'in-place';
}
// TEMP-DISK-PREVIEW-1: the subscription of a machine, from its resource id,
// and what the service read about the preview feature there. The feature is
// registered per subscription, so the answer is kept per subscription.
let tPreview = new Map();
function subOf(m) {
  return ((String(m?.vmId ?? '').match(/\/subscriptions\/([^/]+)/i) ?? [])[1] ?? '').toLowerCase();
}
function previewOf(m) { return (typeof tPreview === 'undefined' ? null : tPreview.get(subOf(m))) ?? null; }
// Choosable only on Registered, as Azure gives it. Not read is not a yes.
function previewOn(m) { const p = previewOf(m); return Boolean(p && p.read === true && p.registered === true); }
// The subscription by its name, as the service read it; else its id.
function previewSubName(m) { return previewOf(m)?.name || subOf(m); }
// Whether a machine has a Preview anywhere among its options: a size whose
// move is the in-place upgrade (Preview). Only such a machine needs the
// feature read.
function previewOffered(m) {
  return (m?.options ?? []).some(o => o.supported && (o.preview === true || (o.sizeChoices ?? []).some(c => c.preview === true)));
}
// The series list of one machine: one item for each supported option, with
// the method of the size the machine goes to there. The value is the option.
// A Preview is chosen only while its subscription reads Registered; the item
// the machine is on stays on the screen as it is, so the notice above the
// tables can say what to do (REBUILD-REMOVE-PLAN-1).
function tSeriesItems(m, sizes, def) {
  const pick = advPick(m, def, tOverrides);
  return (m.options ?? []).filter(x => x.supported).map(o => {
    const method = tMethodOf(m, o.option, sizes);
    return { option: o.option, method, value: o.option, selected: o.option === pick,
      disabled: method === 'preview' && !previewOn(m) && o.option !== pick };
  });
}
// (Recommended) goes on the one option the machine starts on under this
// default - the option at its own size, which is where it starts - and only
// when it upgrades the machine in place with no preview feature. A Preview
// says Preview, and another size of that option is the person's choice, not
// the start.
function tRecommended(m, option, sizes, def) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  return Boolean(o) && option === (m?.start?.[def] ?? null) && sizeOf(m, option, sizes) === o.targetSize && tMethodOf(m, option, sizes) === 'in-place';
}
// The text of one option of the series list: the series, the kind of change
// and, in brackets, its pill - the cue that works without colour.
// TEMP-DISK-PREVIEW-1: method names the item; with none, the method the
// machine takes there. A Preview says Preview, or Preview, feature needed
// while its subscription does not have the feature.
function tOptionLabel(m, option, sizes, def, method) {
  const kind = method ?? tMethodOf(m, option, sizes);
  const label = fill(UX.tOptionLabel, { series: advSeriesLabel(m, option, sizes), kind: UX.kPathA });
  const pill = kind === 'preview' ? (previewOn(m) ? UX.tPillPreview : UX.tPillPreviewOff)
    : tRecommended(m, option, sizes, def) ? UX.tPillRec : '';
  return pill ? fill(UX.tOptionPill, { label, pill }) : label;
}
// The fact under the series list of a row on the Preview. Nothing for a row
// that upgrades in place with no feature.
function tUnderRowHtml(m, pick) {
  return tMethodOf(m, pick, tSizes) === 'preview' ? tPreviewLineHtml(m) : '';
}
// TARGETS-ALIGN-1: the fact of the row only, inside the series cell - the
// same machine. The feature, its (?) and Check again are facts of the
// subscription, in its one box above the table (tPreviewNoticeHtml). Before,
// a second table row under each Preview row said the subscription again on
// every row and ran past the Details column.
function tPreviewLineHtml(m) {
  return `<div class="t-pfact">${esc(UX.tPreviewFact)}</div>`;
}
// Check again: one button with one action - it reads, then the step is drawn
// again. While it reads, it says so.
function tPreviewCheckBtn(m) {
  const p = previewOf(m);
  return `<button type="button" class="btn small ghost t-pcheck" data-psub="${esc(subOf(m))}"${p?.loading ? ' disabled' : ''}>${esc(UX.tPreviewCheck)}</button>`;
}
// Behind the (?): the feature and why, that the product does not register it,
// and to keep it registered. PREVIEW-RG-SCOPE-1: the steps are in the box, so
// the help does not repeat them. No command to copy (hard rule 12).
function tPreviewHelpHtml(m, id) {
  return `<div class="muted t-help-text t-phelp" id="t-help-${esc(id)}"><p>${esc(UX.tPreviewWhat)}</p><p>${esc(UX.tPreviewNotTool)}</p><p>${esc(UX.tPreviewKeep)}</p></div>`;
}
// PREVIEW-RG-SCOPE-1: may the box say "choose a v5 target"? Only when EVERY
// machine in it has a supported v5 option with a size that moves in place
// and keeps a temporary disk - the SCSI temporary disk it has now, because a
// Windows move to another kind of temporary disk is the Preview. Not always
// so: v5 is D and E only (target-families.json), so an F machine has none, and
// a B v1 machine's v5 option can hold only its Bsv2 size by the Preview.
function tPreviewV5Way(list) {
  const keeps = (x) => x && x.preview !== true && Number(x.tempDisksTo) > 0;
  return (list ?? []).length > 0 && list.every(m => (m?.options ?? []).some(o =>
    o.option === 'v5' && o.supported && (keeps(o) || (o.sizeChoices ?? []).some(keeps))));
}
// PREVIEW-RG-SCOPE-1: what to do under the first line of the box. State A
// (not read): the error code Azure gave goes on the first line; on
// AuthorizationFailed, that Azure did not let the product read the feature,
// and the steps, else "Select Check again.". State B (not registered): who
// registers it, the portal steps, and the v5 way when it is true. This page
// cannot read where the product has access (the Admin page reads that with
// the signed-in user's own Azure token), so it never says "resource groups
// only".
function tPreviewMoreHtml(list, p, sub) {
  const li = (ws) => `<ol>${ws.map(w => `<li>${esc(w)}</li>`).join('')}</ol>`;
  if (!p.read) {
    if (String(p.code ?? '') === 'AuthorizationFailed') {
      return `<p>${esc(UX.tPvAuthWhy)}</p>${li([fill(UX.tPvAuthStep, { sub }), UX.tPvCheck])}`;
    }
    return `<p>${esc(UX.tPvCheck)}</p>`;
  }
  return `<p>${esc(UX.tPvWho)}</p>${li([fill(UX.tPvReg1, { sub }), UX.tPvReg2, UX.tPvReg3])}${
    tPreviewV5Way(list) ? `<p>${esc(UX.tPvV5)}</p>` : ''}`;
}
// The box above the tables, one for each subscription where a machine's
// target is the in-place upgrade (Preview) (REBUILD-REMOVE-PLAN-1: the product
// guides the customer on each subscription, and never registers the feature).
// TARGETS-ALIGN-1: the feature is a fact of the subscription, so it shows
// here once, also when it is registered - never on each row. The box holds the
// Preview pill, the sentence - registered, not registered, not read, or being
// read - then the (?), which holds the steps in the Azure portal, and Check
// again at the right edge. Amber while the feature is not registered or not
// read. Nothing when no machine's target is the Preview.
function tPreviewNoticeHtml(machines) {
  const bySub = new Map();
  for (const m of machines ?? []) {
    if (tMethodOf(m, advPick(m, tDefault, tOverrides), tSizes) !== 'preview') continue;
    const s = subOf(m);
    if (!bySub.has(s)) bySub.set(s, []);
    bySub.get(s).push(m);
  }
  return [...bySub.values()].map((list, i) => {
    const m = list[0], p = previewOf(m), n = list.length;
    const loading = !p || p.loading;
    const on = !loading && previewOn(m);
    const pick = (w) => n === 1 ? w.one : w.many;
    const sub = previewSubName(m);
    const code = !loading && !p.read ? String(p.code ?? '') : '';
    const words = loading ? fill(UX.tPreviewReading, { sub })
      : fill(pick(on ? UX.tPreviewOn : p.read ? UX.tPvOff : UX.tPvNotRead), { n, sub }) + (code ? ' ' + fill(UX.tPvCode, { code }) : '');
    // The help id is the place of the subscription in this list, a number.
    const id = `preview-sub-${Number(i)}`;
    const more = loading || on ? '' : `<div class="t-pmore">${tPreviewMoreHtml(list, p, sub)}</div>`;
    return `<div class="t-psub${on ? '' : ' t-pwarn'}" data-psub="${esc(subOf(m))}"><span class="pill">${esc(UX.tPillPreview)}</span><span class="t-ptxt">${esc(words)}</span><span class="t-pact">${
      tHelpBtn(id, UX.tPreviewAbout)} ${tPreviewCheckBtn(m)}</span>${more}${tHelp.has(id) ? tPreviewHelpHtml(m, id) : ''}</div>`;
  }).join('');
}

// Read the preview feature of each subscription that needs it, once - and
// again for one subscription on Check again (force). The step is drawn again
// when an answer comes. A read that fails is not checked: read false.
async function tPreviewLoad(machines, force) {
  const subs = new Set();
  for (const m of machines ?? []) if (previewOffered(m)) subs.add(subOf(m));
  for (const s of subs) {
    if (!s || (force ? s !== force : tPreview.has(s))) continue;
    tPreview.set(s, { ...(tPreview.get(s) ?? {}), loading: true });
    if (force) render();
    let answer;
    try {
      const r = await api('GET', `preview-feature?subscriptionId=${encodeURIComponent(s)}`);
      // PREVIEW-RG-SCOPE-1: the error code of a read that failed; the page
      // shows no HTTP status.
      answer = { read: r?.read === true, registered: r?.registered === true, state: r?.state ?? null, name: r?.subscriptionName || '',
        code: String(r?.errorCode ?? '') };
    } catch (e) {
      answer = { read: false, registered: false, state: null, name: tPreview.get(s)?.name || '', code: '' };
    }
    tPreview.set(s, answer);
    if (step === STEP.migrate.targets) render();
  }
}
// The counts above the table: how many machines take each method, from the
// size each one goes to. Its (?) opens the facts of the two methods.
function tMethodCountsHtml(machines) {
  let a = 0, p = 0;
  for (const m of machines ?? []) {
    const method = tMethodOf(m, advPick(m, tDefault, tOverrides), tSizes);
    if (method === 'in-place') a++; else if (method === 'preview') p++;
  }
  const words = (w, n) => fill(n === 1 ? w.one : w.many, { n });
  // TARGETS-ALIGN-1: a kind of change is counted only when a machine takes
  // it - never "0 machines take an in-place upgrade." With none, no line.
  if (!a && !p) return '';
  return `<p class="muted" id="t-methods">${a ? esc(words(UX.tCountsInPlace, a)) : ''}${a && p ? ' ' : ''}${p ? esc(words(UX.tCountsPreview, p)) : ''} ${tHelpBtn('method', UX.tMethodAbout)}</p>
    ${tHelp.has('method') ? tMethodHelpHtml() : ''}`;
}
// The facts of the two kinds of change, in the shape of Microsoft's table
// that chooses an execution method: the in-place upgrade, and the in-place
// upgrade (Preview). REBUILD-REMOVE-PLAN-1: the rebuild column is gone.
function tMethodHelpHtml() {
  const f = UX.tMethodFacts, h = UX.tMethodHead;
  const row2 = (k, a, p) => `<tr><td>${esc(h[k])}</td><td>${esc(a)}</td><td>${esc(p)}</td></tr>`;
  return `<div class="muted t-help-text" id="t-help-method"><table class="facts t-methods"><thead><tr><th></th><th>${esc(UX.kPathA)}</th><th>${
    esc(fill(UX.tOptionPill, { label: UX.kPathA, pill: UX.tPillPreview }))}</th></tr></thead><tbody>${
    ['what', 'carries', 'when'].map(k => row2(k, f['in-place'][k], f.preview[k])).join('')}${row2('rollback', UX.vRollbackInPlace, UX.vRollbackPreview)}</tbody></table></div>`;
}
// REBUILD-PICKER-1: def is the migration default, for the (Recommended) pill
// on the kind of change; without it no pill is shown.
function advDetailRows(m, option, size, disks, def) {
  const o = (m.options ?? []).find(x => x.option === option);
  if (!o) return [];
  const to = size || o.targetSize;
  const shape = (o.sizeChoices ?? []).find(c => c.size === to);
  // A size choice carries the facts that follow from its own size.
  const f = shape ?? o;
  const temp = (n) => n == null ? UX.vUnknown : n === 0 ? UX.vNone : n === 1 ? UX.vOneDisk : fill(UX.vDisks, { n });
  const stage = (s) => s ? s.stage : UX.vNotListed;
  const anBefore = m.acceleratedNicCount == null ? UX.vUnknown : (m.acceleratedNicCount > 0 ? UX.vOn : UX.vOff);
  // ADVISE-AN-1: Off where the engine found it stops working on this size, and
  // Unknown where it could not tell - never On for a size whose host decides.
  const kept = f.acceleratedNetworking ?? {};
  const anAfter = kept.keptOn === false ? UX.vOff
    : kept.keptOn == null && ['image-unlisted', 'release-unknown'].includes(kept.keptOnWhy) ? UX.vStartAssess
    : kept.keptOn == null && ['host', 'size-unreadable'].includes(kept.keptOnWhy) ? UX.vUnknown
    : f.acceleratedNetworking?.required ? UX.vOnRequired
    // BSV2-NOTES-1: the engine turns it on for a move to a size that does not
    // require it too (a Bsv2 size), so the move is read, not only the size.
    // The move never turns off an interface that has it, so On stays On.
    : f.acceleratedNetworking?.turnsOn === true ? UX.vOn
    : f.acceleratedNetworking?.turnsOn == null && (f.acceleratedNetworking?.required == null || anBefore !== UX.vOn) ? UX.vUnknown : anBefore;
  // BSV2-NOTES-1: the kind of change is the name of the path, as the wave
  // editor and the report name it. It said Resize, rebuilt around the same
  // disks for a rebuild. The Disk controller row below says NVMe.
  // REBUILD-PICKER-1: and the pill of the method, as the series list says it.
  const method = tMethodOf(m, option, new Map([[m.vmId, to]]));
  // TEMP-DISK-PREVIEW-1: and Preview for the in-place upgrade with the preview feature.
  const kindPill = method === 'preview' ? UX.tPillPreview : (def && tRecommended(m, option, new Map([[m.vmId, to]]), def) ? UX.tPillRec : '');
  const kind = kindPill ? fill(UX.tOptionPill, { label: UX.kPathA, pill: kindPill }) : UX.kPathA;
  const rows = [
    [UX.dSize, `${shortSize(m.sourceSize)}  →  ${shortSize(to)}`],
    ...(shape ? [[UX.dCores, shape.activeVcpus < shape.vcpus
      ? fill(UX.vCoresActive, { n: shape.vcpus, active: shape.activeVcpus, gb: shape.memoryGB })
      : fill(UX.vCores, { n: shape.vcpus, gb: shape.memoryGB })]] : []),
    // OLD-FAM-4: a B size runs on CPU credits; a D or E target has full CPU
    // performance. BSV2-TARGET-1: a Bsv2 target keeps the credits. Read from
    // the size the machine goes to, which can differ from the option's own.
    ...(f.burstableEnds === true ? [[UX.dCpu, `${UX.vCpuCredits}  →  ${UX.vCpuFull}`]] : []),
    ...(f.burstableKept === true ? [[UX.dCpu, `${UX.vCpuCredits}  →  ${UX.vCpuCredits} ${UX.vNoChange}`]] : []),
    ...(UX.vBsv2Why[o.burstableTarget] ? [[UX.dBsv2, UX.vBsv2Why[o.burstableTarget]]] : []),
    [UX.dKind, kind],
    [UX.dController, `${m.diskController || UX.vScsi}  →  ${o.move === 'nvme-conversion' ? UX.vNvme : UX.vScsi}`],
    // ADVISE-AN-1: shown where the size changes the processor maker.
    ...(o.processorChange === true ? [[UX.dProc, `${m.processor}  →  ${o.processor}`]] : []),
    [UX.dTemp, `${temp(o.tempDisksFrom)}  →  ${temp(f.tempDisksTo)}`],
    [UX.dAn, `${anBefore}  →  ${anAfter}`],
    // BSV2-TARGET-1: the stage of that size - Bsv2 is Current, D and E v5 Extended.
    [UX.dLife, `${stage(m.sourceStage)}  →  ${stage(f.targetStage)}${f.stageChange === 'same' ? ' ' + UX.vNoChange : ''}`],
    // TEMP-DISK-PREVIEW-1: a rollback or a restore of a Preview needs the feature too.
    [UX.dRollback, method === 'preview' ? UX.vRollbackPreview : UX.vRollbackInPlace],
  ];
  // OLD-SKU-1C: shown where a disk choice can be made - a size that takes Premium SSD.
  // HDD-OS-1: or any size, for an OS disk that is Standard HDD.
  if ((f.premiumDisks === true || m.osDiskType === 'Standard_LRS') && disks !== undefined) rows.push([UX.dDisks, UX.vDisks3[disks || 'keep']]);
  if ((f.stops ?? []).includes('acceleratedNetworkingRequired')) rows.push([UX.dApproval, UX.vApprovalStop]);
  return rows;
}
// Where the options are, read from the run's own log - the way the scan wait
// reads it (paintScanProgress). The service writes "hosted advise started"
// when it starts them, the engine writes engine:advise when its container
// starts and when it fails, and "advice" when it has written them.
function adviceProgress(events) {
  let state = { kind: 'none' };
  for (const e of events ?? []) {
    const s = String(e.step ?? '');
    if (s === 'engine' && e.outcome === 'start' && /^hosted advise\b/.test(String(e.detail ?? ''))) { state = { kind: 'running' }; }
    else if (s === 'engine:advise') { state = (e.outcome === 'fail' || e.outcome === 'refused') ? { kind: 'failed', detail: String(e.detail ?? '') } : { kind: 'running' }; }
    else if (s === 'advice' && e.outcome === 'ok') { state = { kind: 'done' }; }
  }
  return state;
}
// TARGET-OPTIONS-WAIT-1: what the wait shows. 'wait' is the spinner and no
// Make; 'failed' is the reason and Make; 'make' is "not made yet" and Make.
// Make only when no advise runs and none made options this page can read.
// "Written" with no file read yet is a wait: the file is written before the
// line (New-VmfTargetAdvice), so this refresh read the store before the
// engine wrote it, and the next refresh reads it. Only a file an earlier
// version made (oldOnFile) is offered again.
function adviceWaitView(p, oldOnFile) {
  if (p.kind === 'failed') { return { show: 'failed', detail: p.detail }; }
  if (p.kind === 'none' || (p.kind === 'done' && oldOnFile)) { return { show: 'make' }; }
  return { show: 'wait' };
}
function paintAdviceView(v) {
  const w = $('#t-wait');
  if (!w) { return; }
  const make = $('#t-make');
  if (v.show === 'wait') {
    w.style.color = '';
    w.innerHTML = `<span class="spin"></span>${esc(UX.tWaiting)}`;
    if (make) { make.style.display = 'none'; }
    return;
  }
  if (v.show === 'failed') {
    // textContent: this carries a message the ENGINE wrote. A function, so a
    // "$&" in it stays as written.
    w.textContent = UX.tFailed.replace('{reason}', () => v.detail);
    w.style.color = 'var(--bad)';
  } else {
    w.style.color = '';
    w.textContent = UX.tNotStarted;
  }
  // Enabled again: a start that worked leaves it disabled and hidden.
  if (make) { make.style.display = ''; make.disabled = false; }
}
async function paintAdviceProgress() {
  if (!$('#t-wait')) { return; }
  // TARGET-OPTIONS-WAIT-1: a part of the log that could not be read is no
  // answer (WATCH-1). blobText gives null for it, which readLogEvents takes
  // for the end of the log - and no lines read as "never started".
  let readBad = false;
  const readPart = async (part) => {
    try { return await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, part, { asText: true }); }
    catch { readBad = true; return null; }
  };
  let events = [];
  try { events = DEMO_MODE ? [] : await VmfHelp.readLogEvents(readPart, `${runPrefix()}/logs/events.jsonl`); }
  catch { return; }   // one bad read of a log being written is not an answer (WATCH-1)
  if (readBad) { return; }
  paintAdviceView(adviceWaitView(adviceProgress(events), adviceOld));
}
function tLoadSaved() {
  // Start from what was saved against THESE options, once per options version.
  if (tLoadedFrom === adviceVersion) return;
  tLoadedFrom = adviceVersion; tOverrides = new Map(); tSizes = new Map(); tDiskSel = new Map(); tOpen = new Set();
  tKernelSel = new Map(); tKSeen = new Set(); tTSeen = new Set(); tASeen = new Set();
  // A help id of the network driver choice, or of the accelerated networking
  // reason (AN-ONE-NIC-1), is the place of the machine in the options, so new
  // options close it - or it would open on another machine.
  for (const id of [...tHelp]) { if (id.startsWith('kernel-') || id.startsWith('an-') || id.startsWith('preview-') || id.startsWith('nt-')) tHelp.delete(id); }
  if (targetChoices && targetChoices.adviceVersion === adviceVersion) {
    tDefault = targetChoices.default === 'extended' ? 'extended' : 'current';
    for (const c of targetChoices.choices ?? []) {
      const m = (targetAdvice.machines ?? []).find(x => x.vmId === c.vmId);
      if (m && (m.start?.[tDefault] ?? null) !== c.option) tOverrides.set(c.vmId, c.option);
      if (c.size) tSizes.set(c.vmId, c.size);
      if (c.disks) tDiskSel.set(c.vmId, c.disks);
    }
    tKernelSel = kernelChoicesFrom(targetChoices, targetAdvice.machines);
  }
}
// KERNEL-UX-1: each machine's kernel choice from a saved file, as the page
// keeps it - only where it is Update the kernel, and only for a machine the
// target options hold. KERNEL-DEFAULT-EARLIER-1: the saved default is always
// Stop and ask, so a machine with no choice of its own has none.
function kernelChoicesFrom(saved, machines) {
  const known = new Set((machines ?? []).map(m => m.vmId));
  const out = new Map();
  for (const c of saved?.choices ?? []) {
    if (c.kernel === 'update' && known.has(c.vmId)) out.set(c.vmId, 'update');
  }
  return out;
}
// MANA-LINUX-KERNEL-1: whether "Update the kernel" can be chosen for a machine
// on this option - a Linux machine whose target can use MANA: every NVMe move,
// and a v5 resize unless its size cannot (AMD v5). Unknown is offered, as the
// engine judges it (Test-VmfKernelUpdateOffered).
function kernelOffered(m, option, sizes) {
  if (!/^linux$/i.test(String(m?.os ?? ''))) return false;
  // ADVISE-AN-1: not where the VM agent reports a release Microsoft does not
  // list for MANA - no kernel update gives it one, and the engine refuses it
  // (Test-VmfReleaseKnownUnlisted). An image release, or none, as before.
  if (m.linuxRelease?.source === 'agent' && m.linuxRelease?.mana === 'unlisted') return false;
  const o = option ? (m.options ?? []).find(x => x.option === option) : null;
  if (!o) return false;
  if (o.move === 'nvme-conversion') return true;
  if (o.move !== 'scsi-resize') return false;
  const size = sizeOf(m, option, sizes);
  const c = (o.sizeChoices ?? []).find(x => x.size === size);
  return (c ? c.acceleratedNetworking?.mayUseMana : o.acceleratedNetworking?.mayUseMana) !== false;
}
// The kernel choice that counts for a machine: its own, else the default -
// and none where the choice is not offered.
function kernelOf(m, option, sizes, kernels, def) {
  if (!kernelOffered(m, option, sizes)) return '';
  const own = kernels?.get(m.vmId);
  return own === 'stop' || own === 'update' ? own : (def === 'update' ? 'update' : 'stop');
}
// OLD-SKU-1B: the size a machine goes to on an option - the one chosen from
// the option's size choices, or else the option's own target size.
function sizeOf(m, option, sizes) {
  const o = option ? (m.options ?? []).find(x => x.option === option) : null;
  if (!o) return '';
  const want = sizes?.get(m.vmId);
  return want && (o.sizeChoices ?? []).some(c => c.size === want) ? want : (o.targetSize ?? '');
}
// TEMPDISK-UX-1: whether the size a machine goes to on this option has no
// temporary disk while the machine has one now. Read from the facts the engine
// took from Azure's size catalog - tempDisksFrom (the scan's sourceTempDisks)
// and tempDisksTo of the chosen size, else of the option - never from the size
// name: B v1, Dv2, Dv3 and Dav4 sizes have no d and have a temporary disk.
// Unknown on either side is no loss: the marks say only what is known.
function tempLost(m, option, sizes) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  if (!o || !(o.tempDisksFrom > 0)) return false;
  const size = sizeOf(m, option, sizes);
  const c = (o.sizeChoices ?? []).find(x => x.size === size);
  return (c ? c.tempDisksTo : o.tempDisksTo) === 0;
}
// SQL-TEMPDB-SIGNOFF-1: the scan found SQL Server on this machine - its warning
// sql-server-agree-downtime in the assessment (the SQL IaaS Agent record, or a
// SQL Server image). The engine's twin is Test-VmfSqlServerFound, which writes
// assessment.sqlServerDetected on the plan entry. The ID in any letter case
// (VMID-CASE-1, the rule of VmfHelp.idKey).
function tSqlFound(vmId) {
  const key = String(vmId ?? '').toLowerCase();
  const vm = (assessment?.vms ?? []).find(v => String(v?.vmId ?? '').toLowerCase() === key);
  return Array.isArray(vm?.warnings) && vm.warnings.includes('sql-server-agree-downtime');
}
// SQL-TEMPDB-SIGNOFF-1: whether the size a machine goes to on this option can
// stop SQL Server from starting - the scan found SQL Server on the machine
// (tSqlFound), it has a SCSI temporary disk now, and the size has an NVMe
// temporary disk (a move to v6 or v7) or none. The same rule as the plan
// sign-off (help.js sqlTempdbRisk), read from the target options; a size whose
// temporary disk is not known gets no tag. Only where SQL Server was found:
// "make sure its ONLY if we detect SQL".
function tSqlRisk(m, option, sizes) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  if (!o || !(o.tempDisksFrom > 0)) return false;
  const changes = o.move === 'nvme-conversion' || (o.move === 'scsi-resize' && tempLost(m, option, sizes));
  return changes && tSqlFound(m?.vmId);
}
// SIZE-FALLTHROUGH-NOTE-1: why the size a machine goes to on this option is not
// the size the default tried first - most often the d size, so the temporary
// disk goes. From sizesNotTaken, which the engine recorded with the gate that
// refused each size (Get-VmfTargetSize NotTaken). Only for the size of the
// option itself: a size chosen from the size choices was not a fall-through.
// An option with no list (none, or empty) says nothing, and is never an error.
function tNotTakenText(m, option, sizes) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  const list = Array.isArray(o?.sizesNotTaken) ? o.sizesNotTaken.filter(n => n && n.size) : [];
  if (!list.length || !o.targetSize || sizeOf(m, option, sizes) !== o.targetSize) return '';
  const parts = list.map(n => fill(UX.tNotTaken[n.why] ?? UX.tNotTakenAny, { size: shortSize(n.size) }));
  parts.push(fill(UX.tNotTakenTarget, { target: shortSize(o.targetSize) }));
  if (tMethodOf(m, option, sizes) === 'preview') parts.push(UX.tNotTakenPreview);
  return parts.join(' ');
}
// ADVISE-AN-1: the accelerated networking facts of the size a machine goes to on
// this option - the chosen size choice, else the option. The engine decided
// them (Get-VmfAnKeptOn); the page never works them out again.
function anKept(m, option, sizes) {
  const o = option ? (m?.options ?? []).find(x => x.option === option) : null;
  if (!o) return null;
  const size = sizeOf(m, option, sizes);
  const c = (o.sizeChoices ?? []).find(x => x.size === size);
  return (c ?? o).acceleratedNetworking ?? null;
}
// The machine uses accelerated networking now, and it stops working on that
// size. Unknown is no loss: the marks say only what is known.
function anLost(m, option, sizes) {
  return anKept(m, option, sizes)?.keptOn === false;
}
// The Linux release the facts were made from, in the words of its maker.
function anReleaseText(m) {
  const r = m?.linuxRelease;
  if (!r?.distroId) return '';
  return `${UX.tDistros[r.distroId] ?? r.distroId} ${r.version ?? ''}`.trim();
}
// ADVISE-AN-1: the one rule behind every accelerated
// networking (?) - the release and the adapter of the size, never the number
// of interfaces - as a table. The words are declared; nothing is worked out.
function anRuleHtml() {
  const h = UX.tAnRuleHead;
  const row = (k, listed, unlisted) => `<tr><td>${esc(UX.tAnRuleSize[k])}</td><td>${esc(UX.tAnRuleAdapter[k])}</td><td>${esc(listed)}</td><td>${esc(unlisted)}</td><td>${esc(UX.vOn)}</td></tr>`;
  return `<p>${esc(UX.tAnRule)}</p><table class="facts t-anrule"><thead><tr><th>${esc(h.size)}</th><th>${esc(h.adapter)}</th><th>${esc(h.listed)}</th><th>${esc(h.unlisted)}</th><th>${esc(h.windows)}</th></tr></thead><tbody>${
    row('v6', UX.vOn, UX.tAnRuleNotOffered)}${row('v7', UX.vOn, UX.tAnRuleNotOffered)}${row('amd', UX.vOn, UX.vOn)}${row('intel', UX.vOn, UX.tAnRuleNotOffered)}${row('bsv2', UX.vOn, UX.tAnRuleNotOffered)}</tbody></table><p>${esc(UX.tAnRuleNic)}</p>`;
}
// AN-MANA-DRIVER-RULE-1: the line in Details for a machine whose Linux release
// has no MANA driver possible - an option the engine refused for it
// (no-mana-driver) - with the release to upgrade to, as the engine recorded it
// (linuxRelease.manaUpgrade). '' for every other machine. Nothing is worked out.
function manaUpgradeText(m) {
  if (!(m?.options ?? []).some(o => (o.notSupported ?? []).includes('no-mana-driver'))) return '';
  const up = m.linuxRelease?.manaUpgrade;
  const upgrade = up?.distroId ? `${UX.tDistros[up.distroId] ?? up.distroId} ${up.version ?? ''}`.trim() : '';
  return fill(upgrade ? UX.tManaUpgrade : UX.tManaUpgradeAny, { release: anReleaseText(m), upgrade });
}
// Why, for the (?): the reason, then where the release was read.
function anHelpText(m, why) {
  const base = fill(UX.tAnKeepHelp[why] ?? '', { release: anReleaseText(m) });
  const from = m?.linuxRelease?.distroId ? (UX.tAnFrom[m.linuxRelease.source] ?? '') : '';
  return [base, from].filter(Boolean).join(' ');
}
// REBUILD-REMOVE-PLAN-1: the choice a machine waited for (the engine's decide,
// IDENTITY-LOSS-1: a target that keeps the system-assigned identity, or one
// that a rebuild deletes it on) and the notices and facts of the identity are
// gone with the rebuild. An in-place upgrade keeps the identity.// The option's own target size is kept as no choice, as the engine keeps it.
function setSize(sizes, m, option, size) {
  const o = (m.options ?? []).find(x => x.option === option);
  if (!o || !size || size === o.targetSize) sizes.delete(m.vmId); else sizes.set(m.vmId, size);
}
// OLD-SKU-1C: whether the size a machine goes to takes Premium SSD disks -
// the option's own, or the chosen size choice's. Unknown is not a yes.
function premiumOf(m, option, sizes) {
  const o = option ? (m.options ?? []).find(x => x.option === option) : null;
  if (!o) return false;
  const size = sizeOf(m, option, sizes);
  const c = (o.sizeChoices ?? []).find(x => x.size === size);
  return (c ? c.premiumDisks : o.premiumDisks) === true;
}
// The disk choice that counts: only on a size that takes Premium SSD.
// HDD-OS-1: Standard SSD for the OS disk counts on any size - every size takes
// it - and only where the scan read the OS disk as Standard HDD.
function disksOf(m, option, sizes, disks) {
  const d = disks?.get(m.vmId);
  if (d === 'os-standard-ssd') return m.osDiskType === 'Standard_LRS' && Boolean(option) ? d : '';
  return (d === 'os' || d === 'all') && premiumOf(m, option, sizes) ? d : '';
}
// The disk choices a machine is offered, in the order the list shows them:
// Premium SSD in the second area on a size that takes it (OLD-SKU-1C), and
// Standard SSD for a Standard HDD OS disk in both areas (HDD-OS-1). One item
// only - Keep the disk types - means no list.
function diskChoicesOf(m, option, sizes) {
  const keys = ['keep'];
  if (option && m.osDiskType === 'Standard_LRS') keys.push('os-standard-ssd');
  if (oldShape(m) && premiumOf(m, option, sizes)) keys.push('os', 'all');
  return keys;
}
// HDD-OS-1: the type of the OS disk now and after the move, in Azure's names,
// for the export for pricing. Unknown when the scan could not read it.
function osDiskTypes(m, choice) {
  const now = m.osDiskType;
  if (!now) return [UX.vUnknown, UX.vUnknown];
  const premium = { Standard_LRS: 'Premium_LRS', StandardSSD_LRS: 'Premium_LRS', StandardSSD_ZRS: 'Premium_ZRS' };
  const after = choice === 'os-standard-ssd' && now === 'Standard_LRS' ? 'StandardSSD_LRS'
    : (choice === 'os' || choice === 'all') && premium[now] ? premium[now] : now;
  const word = (s) => UX.vDiskTypes[s] ?? s;
  return [word(now), word(after)];
}
// ADVISE-AN-1: whether one size list mixes processor makers - then each size
// says its maker, from the advice (each size choice's processor).
function sizeListMixed(choices) {
  return new Set((choices ?? []).map(c => c.processor).filter(Boolean)).size > 1;
}
// CONSTRAINED-DEFAULT-1: the size a family starts on when a person chooses
// it. The best choice when it is in that family. Else, when the best choice
// is a constrained vCPU size, the size of the family with the same active
// vCPUs, so a switch to D and back to E keeps E8-4ds_v5 (4 active) and never
// lands on E8ds_v5 (8 active). Else the first size of the family.
function familyStartSize(choices, family) {
  const inFamily = (choices ?? []).filter(c => c.family === family);
  const best = (choices ?? []).find(c => c.best);
  if (best && best.family === family) return best;
  const keep = best && best.activeVcpus < best.vcpus ? inFamily.find(c => c.activeVcpus === best.activeVcpus) : null;
  return keep ?? inFamily[0] ?? null;
}
function sizeChoiceLabel(c) {
  return c.variant === 'constrained' ? fill(UX.tConstrained, { size: shortSize(c.size), n: c.activeVcpus }) : shortSize(c.size);
}
// OLD-SKU-1A: the second area. Generation 1 machines, and the sizes older than
// v3 that have no size of the same name on v5: D v1, DS v1, Dv2, DSv2 and Av2 -
// and, since OLD-FAM-1, the End of Life B v1, F, Fs and Fsv2 families.
function oldShape(m) {
  if (m.gen === 'V1') return true;
  // The constrained DSv2 sizes too (DS13-4_v2), as the planner's own rule
  // for these families has it (SIZE-FIT-1, Planner.ps1).
  return /^Standard_((A|D|DS)\d+(-\d+)?m?(_v2)?(_Promo)?|B\d+(ls|s|ms)|F\d+s?(_v2)?)$/i.test(String(m.sourceSize ?? ''));
}
// One CSV cell: quoted when it must be, and never read as a formula by a
// spreadsheet (a leading = + - @ is made text).
function csvCell(v) {
  let s = v == null ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
  return /[",\r\n']/.test(s) && s !== '' ? '"' + s.replace(/"/g, '""') + '"' : s;
}
// Export for pricing: the count a seller prices from first - each target size
// by region and operating system, which prices differently - then every
// machine. A machine with no target is listed and not counted.
// PRICE-EXPORT-1: given `waves` (each machine's wave, from the plan), both
// tables start with the wave and the count is per wave - in the order the
// machines come, which is the order the waves run, never the alphabet.
function pricingCsv(machines, picks, sizes, disks, waves) {
  const counts = new Map();
  const rows = [];
  const waveRank = new Map();
  for (const m of machines) {
    const option = picks.get(m.vmId) ?? '';
    const size = shortSize(sizeOf(m, option, sizes));
    const rg = (String(m.vmId).match(/\/resourceGroups\/([^/]+)/i) ?? [])[1] ?? '';
    const wave = waves ? [waves.get(m.vmId) ?? ''] : [];
    if (waves && !waveRank.has(wave[0])) waveRank.set(wave[0], waveRank.size);
    // OLD-SKU-1C: disk types price differently too.
    // BSV2-TARGET-1: the series a person reads - Bsv2, not the v5 it is planned on.
    // HDD-OS-1: and the type of the OS disk now and after, which prices differently.
    const choice = size ? disksOf(m, option, sizes, disks) : '';
    rows.push([...wave, m.name, rg, m.location, m.os, shortSize(m.sourceSize), option ? advSeriesLabel(m, option, sizes) : option, size, size ? UX.vDisks3[choice || 'keep'] : '', ...osDiskTypes(m, choice)]);
    if (size) {
      const k = [...wave, m.location, m.os, size].join('\u0000');
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
  }
  const line = (cells) => cells.map(csvCell).join(',');
  const rankOf = (k) => waves ? waveRank.get(k.split('\u0000')[0]) : 0;
  const countLines = [...counts.entries()].sort(([a], [b]) => (rankOf(a) - rankOf(b)) || a.localeCompare(b))
    .map(([k, n]) => line([...k.split('\u0000'), n]));
  const waveHead = waves ? ['Wave'] : [];
  return [line([...waveHead, 'Region', 'Operating system', 'Target size', 'Machines']), ...countLines, '',
    line([...waveHead, 'Machine', 'Resource group', 'Region', 'Operating system', 'Size now', 'Size series', 'Target size', 'Disks', 'OS disk type now', 'OS disk type after']),
    ...rows.map(line)].join('\r\n') + '\r\n';
}
// PRICE-EXPORT-1: the Run it step prices the PLAN. The plan is what runs, and
// the wave editor can change one machine after planning (WAVE-MIX-2), so the
// saved targets can be older than it. Each entry becomes what pricingCsv
// reads: one option, the size the plan holds, and its disk change. A machine
// that does not move - not on path A or B, with no size, or in no wave - is
// listed with no target. A machine in no wave does not run (planWaves leaves
// it out), and its wave cell is empty: "unscheduled" is the store's word, not
// one a person reads. The machines come in the order the waves run
// (WAVE-ORDER-1).
function planPricing(plan, vms, nameOf) {
  const order = VmfHelp.waveOrder(plan);
  const rank = (w) => { const i = order.indexOf(w); return i < 0 ? order.length : i; };
  const vmOf = new Map((vms ?? []).map(v => [VmfHelp.idKey(v.vmId), v]));
  const machines = [], picks = new Map(), disks = new Map(), waves = new Map();
  for (const e of [...(plan?.entries ?? [])].sort((a, b) => rank(a.wave) - rank(b.wave))) {
    const inWave = Boolean(e.wave) && e.wave !== 'unscheduled';
    const option = inWave && e.path === 'A' && e.target?.size ? (e.target?.choice?.option ?? '') : '';
    machines.push({
      // The region the plan recorded; else the assessment record.
      vmId: e.vmId, name: nameOf(e.vmId), location: e.assessment?.location || (vmOf.get(VmfHelp.idKey(e.vmId))?.location ?? ''),
      os: e.assessment?.os ?? '', sourceSize: e.assessment?.sourceSize ?? '',
      // HDD-OS-1: the OS disk's type as the scan read it (plan-entry v21).
      osDiskType: e.assessment?.osDiskType ?? null,
      options: option ? [{ option, supported: true, targetSize: e.target.size, premiumDisks: Boolean(e.policy?.diskUpgrade) }] : [],
    });
    if (option) picks.set(e.vmId, option);
    if (e.policy?.diskUpgrade) disks.set(e.vmId, e.policy.diskUpgrade);
    waves.set(e.vmId, inWave ? e.wave : '');
  }
  return { machines, picks, sizes: new Map(), disks, waves };
}
// A byte-order mark first, so a spreadsheet reads a resource group name in any
// language as the text it is.
const CSV_BOM = '\uFEFF';
function savedSizes(saved) {
  return new Map((saved?.choices ?? []).filter(c => c.size).map(c => [c.vmId, c.size]));
}
function savedDisks(saved) {
  return new Map((saved?.choices ?? []).filter(c => c.disks).map(c => [c.vmId, c.disks]));
}
// Whether everything Save would send is SAVED, against these options. The file
// is what was saved, never a draft. PRICE-EXPORT-1: this turned the button off,
// and Save moved the person on, so the button was never seen live. Now it says
// whether a press must save first. A machine with no target sends nothing
// (targetChoicesBody), so nothing is unsaved.
// The default is saved too, and a reload starts from it (tLoadSaved).
function exportState(machines, picks, saved, version, sizes, disks, def, kernels, kernelDef) {
  if (!saved || saved.adviceVersion !== version) return { saved: false };
  if (def && (saved.default === 'extended' ? 'extended' : 'current') !== def) return { saved: false };
  // MANA-LINUX-KERNEL-1: each machine's kernel choice too. KERNEL-UX-1: as the
  // choice that counts for the machine, never the default itself, which is
  // always Stop and ask (KERNEL-DEFAULT-EARLIER-1).
  const savedKernelDef = 'stop';
  const savedKernels = new Map((saved.choices ?? []).filter(c => c.kernel).map(c => [c.vmId, c.kernel]));
  const savedPick = new Map((saved.choices ?? []).map(c => [c.vmId, c.option]));
  const savedSize = savedSizes(saved);
  for (const m of machines) {
    const choosable = (m.options ?? []).some(o => o.supported);
    if (!choosable) continue;
    const pick = picks.get(m.vmId) ?? null;
    const sends = pick || null;
    if ((savedPick.get(m.vmId) ?? null) !== sends) return { saved: false };
    if (!sends) continue;
    if (sizeOf(m, sends, savedSize) !== sizeOf(m, sends, sizes)) return { saved: false };
    if (disksOf(m, sends, savedSize, savedDisks(saved)) !== disksOf(m, sends, sizes, disks)) return { saved: false };
    if (kernels && kernelOf(m, sends, savedSize, savedKernels, savedKernelDef) !== kernelOf(m, sends, sizes, kernels, kernelDef ?? savedKernelDef)) return { saved: false };
  }
  return { saved: true };
}
// PRICE-EXPORT-1: one press on the targets step. What the screen holds and has
// not saved is saved first - by saveTargets, the one save, with its version
// check - and the person stays on this step. When nothing changed, nothing is
// saved again: a save records the person who made it. But "saved" is what the
// page READ, so the version the service issues for the stored document is
// asked first (PLANVER-2): a newer save by another user downloads nothing.
async function exportTargets() {
  // MACHINE-PICK-1: the chosen machines only, as the step shows them.
  const machines = tMachines();
  const picks = new Map(machines.map(m => [m.vmId, advPick(m, tDefault, tOverrides)]));
  // WIZARD-ROLES-3: the service saves targets only for an operator. Anybody
  // else downloads what an operator saved, only while it is current, and
  // nothing is saved first.
  if (!canOperate && !targetChoices) { failAction(new Error(UX.tExportNoneSaved)); return; }
  // MACHINE-PICK-1: and saved against the machines chosen now.
  const current = exportState(machines, picks, targetChoices, adviceVersion, tSizes, tDiskSel, tDefault, tKernelSel, tKernelDef).saved
    && targetsFitMachines(targetChoices, machineChoices, machinesVersion);
  if (!current) {
    if (canOperate) { return saveTargets(true); }
    failAction(new Error(UX.tExportNotCurrent)); return;
  }
  clearErr();
  const now = await readVersionedDoc(`${runPrefix()}/target-choices.json`);
  if (!now && readFailed) { render(); return; }
  if (!now || now.version !== choicesVersion) { failAction(new Error(UX.tExportChanged)); return; }
  exportPricing();
}
// The Run it step: the plan, with the wave of each machine.
function exportPlan() {
  exportPricing(planPricing(plan, assessment?.vms, vmName));
}
// PRICE-EXPORT-1: the one download, for both steps. With no input it is the
// targets step: what was SAVED, from the saved document - never the screen.
function exportPricing(input) {
  const src = input ?? {
    machines: tMachines(),
    picks: new Map((targetChoices?.choices ?? []).map(c => [c.vmId, c.option])),
    sizes: savedSizes(targetChoices), disks: savedDisks(targetChoices),
  };
  // DISCLAIMER-1: the file leaves the app, so its last row is the short line,
  // after a blank row, where a spreadsheet keeps it out of the tables.
  const notice = '\r\n' + csvCell(VmfHelp.disclaimerLine) + '\r\n';
  const blob = new Blob([CSV_BOM + pricingCsv(src.machines, src.picks, src.sizes, src.disks, src.waves) + notice], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = `${String(runId || 'assessment').replace(/[^A-Za-z0-9._-]/g, '-')}-targets-for-pricing.csv`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
let tHelp = new Set();
// TARGETS-AREAS-1: the rows and the two areas are drawn here, outside
// renderTargets, so tests/js/targets-step.test.js can RUN them with machines
// shaped like the target advice.
// One button, two states (rule 11): "?" opens the text, Close closes it.
function tHelpBtn(id, label) {
  return `<button type="button" class="btn small ghost t-help" data-help="${id}" aria-expanded="${tHelp.has(id)}" aria-controls="t-help-${id}" aria-label="${esc(tHelp.has(id) ? UX.tClose : label)}" title="${esc(label)}">${tHelp.has(id) ? esc(UX.tClose) : '?'}</button>`;
}
function tTargetRow(m) {
  const pick = advPick(m, tDefault, tOverrides);
  const supported = (m.options ?? []).filter(o => o.supported);
  const target = supported.length
    ? `<select class="t-series" data-vm="${esc(m.vmId)}" aria-label="${esc(UX.colTarget)} ${esc(m.name)}">${tSeriesItems(m, tSizes, tDefault).map(x =>
        `<option value="${esc(x.value)}"${x.selected ? ' selected' : ''}${x.disabled ? ' disabled' : ''}>${esc(tOptionLabel(m, x.option, tSizes, tDefault, x.method))}</option>`).join('')}</select>`
    : `<span class="muted">${esc(UX.tNoTarget)}</span>`;
  const o = pick ? (m.options ?? []).find(x => x.option === pick) : null;
  const open = tOpen.has(m.vmId);
  // OLD-SKU-1B: an option with size choices shows the family and the size.
  const size = sizeOf(m, pick, tSizes);
  const choices = o?.sizeChoices ?? [];
  let sizeCell = o ? esc(shortSize(size)) : '';
  const cur = choices.find(c => c.size === size);
  if (cur) {
    const fams = [...new Set(choices.map(c => c.family))];
    // V3-TEMPDISK-1: a v3 machine chooses between two sizes of one family
    // (with a temporary disk or without), so a family list would offer one item.
    sizeCell = `${fams.length > 1 ? `<select class="t-fam" data-fvm="${esc(m.vmId)}" aria-label="${esc(UX.tFamily)} ${esc(m.name)}">${fams.map(f =>
        `<option value="${esc(f)}"${f === cur.family ? ' selected' : ''}>${esc(UX.tFamilies[f] ?? f)}</option>`).join('')}</select>` : ''}
      <select class="t-size" data-svm="${esc(m.vmId)}" aria-label="${esc(UX.colNewSize)} ${esc(m.name)}">${(() => {
        const list = choices.filter(c => c.family === cur.family);
        const mixed = sizeListMixed(list);
        return list.map(c => `<option value="${esc(c.size)}"${c.size === cur.size ? ' selected' : ''}>${esc(mixed ? fill(UX.tSizeMaker, { size: sizeChoiceLabel(c), maker: c.processor }) : sizeChoiceLabel(c))}</option>`).join('');
      })()}</select>`;
  }
  // OLD-SKU-1C: the disks, in the second area, on a size that takes Premium SSD.
  // HDD-OS-1: and in both areas for an OS disk that is Standard HDD.
  const diskKeys = diskChoicesOf(m, pick, tSizes);
  if (diskKeys.length > 1) {
    const d = disksOf(m, pick, tSizes, tDiskSel) || 'keep';
    sizeCell += `
      <select class="t-disks" data-dvm="${esc(m.vmId)}" aria-label="${esc(UX.tDisks)} ${esc(m.name)}">${diskKeys.map(k =>
        `<option value="${k}"${k === d ? ' selected' : ''}>${esc(UX.tDiskChoice[k])}</option>`).join('')}</select>`;
  }
  // TEMPDISK-UX-1: a tag under a size that has no temporary disk, on a machine
  // that has one now. It stays after Details are opened; the dot goes.
  const tLost = tempLost(m, pick, tSizes);
  if (tLost) sizeCell += `<div class="t-ttag"><span class="pill warn">${esc(UX.tTempTag)}</span></div>`;
  // ADVISE-AN-1: the same tag where the size turns off accelerated networking.
  const aLost = anLost(m, pick, tSizes);
  if (aLost) sizeCell += `<div class="t-ttag"><span class="pill warn">${esc(UX.tAnTag)}</span></div>`;
  // Review finding 1: a release only the image gives cannot prove the loss, so
  // the start stays and the size says it can be off; Details say Unknown and why.
  else if (['image-unlisted', 'release-unknown'].includes(anKept(m, pick, tSizes)?.keptOnWhy)) sizeCell += `<div class="t-ttag"><span class="pill warn">${esc(UX.vStartAssess)}</span></div>`;
  // SQL-TEMPDB-SIGNOFF-1: one tag under the size of a SQL Server machine whose
  // size has an NVMe temporary disk or none. Run it asks for the sign-off.
  if (tSqlRisk(m, pick, tSizes)) sizeCell += `<div class="t-ttag"><span class="pill warn">${esc(UX.tSqlTag)}</span></div>`;
  // AN-MANA-DRIVER-RULE-1: no target changes the processor maker now, so the tag
  // that said so under the size is gone.
  // MANA-LINUX-KERNEL-1: the kernel choice, for a Linux machine whose target can use MANA.
  const kernel = kernelOf(m, pick, tSizes, tKernelSel, tKernelDef);
  // KERNEL-UX-1: the choice lives in Details. Until someone opens them, the
  // Details of a machine it applies to carries an amber dot.
  const kCheck = kernel && !tKSeen.has(m.vmId);
  // TEMPDISK-UX-1: the same one dot for a temporary disk to check, and its
  // words say each reason it shows.
  const dotWhy = tDotWhy(kCheck, tLost && !tTSeen.has(m.vmId), aLost && !tASeen.has(m.vmId));
  // TARGETS-AREAS-1: the VM generation on every row, in the words of the review step.
  let html = `<tr class="t-row">
    <td class="mono">${esc(m.name)}</td><td>${esc(m.location ?? '')}</td><td class="mono">${esc(shortSize(m.sourceSize))}</td><td class="t-gen">${esc(advGenLabel(m.gen))}</td><td>${target}${o ? tUnderRowHtml(m, pick) : ''}</td>
    <td class="mono">${sizeCell}</td>
    <td class="t-detcell"><button type="button" class="btn small ghost t-det${dotWhy ? ' t-kdot' : ''}" data-vm="${esc(m.vmId)}" aria-expanded="${open}"${dotWhy ? ` title="${esc(dotWhy)}" aria-label="${esc(UX.tDetails)}: ${esc(dotWhy)}"` : ''}>${esc(open ? UX.tClose : UX.tDetails)}</button></td></tr>`;
  // TARGETS-ALIGN-1: a row is one table row. The fact of a Preview row is
  // inside its series cell, above; nothing is drawn under the row or past
  // its last column.

  if (open) {
    // The place of the machine in the options, asked only when an id needs it.
    const idxOf = () => (targetAdvice?.machines ?? []).indexOf(m);
    // ADVISE-AN-1: why accelerated networking is off or unknown on this size,
    // behind a (?) on its row. Each machine has its own id.
    const keepWhy = anKept(m, pick, tSizes)?.keptOnWhy;
    const keepId = keepWhy ? `an-keep-${idxOf()}` : '';
    // TEMPDISK-UX-1: the temporary disk row is marked while the size has none.
    // ADVISE-AN-1: and the accelerated networking row while it turns it off.
    // SIZE-FALLTHROUGH-NOTE-1: why the size with a temporary disk is not the
    // target, behind a (?) on the temporary disk row.
    const ntText = tNotTakenText(m, pick, tSizes);
    const ntId = ntText ? `nt-${idxOf()}` : '';
    const factRow = ([k, v]) => {
      const help = keepId && k === UX.dAn ? ' ' + tHelpBtn(keepId, UX.tAnKeepAbout)
        : ntId && k === UX.dTemp ? ' ' + tHelpBtn(ntId, UX.tNotTakenAbout) : '';
      return (tLost && k === UX.dTemp) || (aLost && k === UX.dAn)
        ? `<tr class="t-trow"><td><span class="t-kdotx" aria-hidden="true"></span>${esc(k)}${help}</td><td>${esc(v)}</td></tr>`
        : `<tr><td>${esc(k)}${help}</td><td>${esc(v)}</td></tr>`;
    };
    const keepHelp = keepId && tHelp.has(keepId) ? `<div class="muted t-help-text" id="t-help-${keepId}"><p>${esc(anHelpText(m, keepWhy))}</p>${anRuleHtml()}</div>` : '';
    const ntHelp = ntId && tHelp.has(ntId) ? `<p class="muted t-help-text" id="t-help-${ntId}">${esc(ntText)}</p>` : '';
    const facts = pick ? `<div class="sec"><h3>${esc(fill(UX.tWhatChanges, { series: advSeriesLabel(m, pick, tSizes) }))}</h3>
      <table class="facts">${advDetailRows(m, pick, size, diskChoicesOf(m, pick, tSizes).length > 1 ? disksOf(m, pick, tSizes, tDiskSel) : undefined, tDefault).map(factRow).join('')}</table>${ntHelp}${keepHelp}</div>` : '';
    // ADVISE-AN-1: an option that turns off accelerated networking says so.
    const others = (m.options ?? []).filter(x => x.option !== pick).map(x =>
      `<tr><td>${esc(advSeriesLabel(m, x.option))}</td><td>${esc(x.supported
        ? fill(x.acceleratedNetworking?.keptOn === false ? UX.tAvailableAnOff : UX.tAvailable, { size: shortSize(x.targetSize) })
        : fill(UX.tNotAvailable, { why: advWhy(x) }))}</td></tr>`).join('');
    // Each machine has its own (?) help, so two open Details never share one id.
    const kSec = kernel ? kernelSectionHtml(m, kernel, `kernel-${idxOf()}`) : '';
    // AN-ONE-NIC-1: a 2-vCPU size refused for accelerated networking. Each row
    // says why in one sentence; what to do is behind one (?) on the heading.
    const anWhy = (m.options ?? []).some(x => x.option !== pick && (x.notSupported ?? []).includes('one-accelerated-nic'));
    // ADVISE-AN-1: the same (?) says why an other option turns it off.
    const offOther = (m.options ?? []).find(x => x.option !== pick && x.supported && x.acceleratedNetworking?.keptOn === false);
    // AN-MANA-DRIVER-RULE-1: and the rule table for a release with no MANA driver.
    const noMana = Boolean(manaUpgradeText(m));
    const anId = anWhy || offOther || noMana ? `an-${idxOf()}` : '';
    const anText = [anWhy ? UX.tAnHelp : '', offOther ? anHelpText(m, offOther.acceleratedNetworking.keptOnWhy) : ''].filter(Boolean).join(' ');
    const anHelp = anId && tHelp.has(anId) ? `<div class="muted t-help-text" id="t-help-${anId}">${anText ? `<p>${esc(anText)}</p>` : ''}${offOther || noMana ? anRuleHtml() : ''}</div>` : '';

    // AN-MANA-DRIVER-RULE-1: what to do for a release with no MANA driver, first.
    const upgrade = manaUpgradeText(m);
    const uSec = upgrade ? `<div class="sec"><p>${esc(upgrade)}</p></div>` : '';
    html += `<tr class="t-detail"><td colspan="7">${uSec}${kSec}${facts}${others ? `<div class="sec"><h3>${esc(UX.tOthers)}${anId ? ' ' + tHelpBtn(anId, anWhy ? UX.tAnAbout : UX.tAnKeepAbout) : ''}</h3>${anHelp}<table class="facts">${others}</table></div>` : ''}</td></tr>`;
  }
  return html;
}
// OLD-SKU-1A, TARGETS-AREAS-1: two areas, split by oldShape and named for how
// the target is chosen. The first holds the machines whose target is the newer
// version of their size. The second holds Generation 1 machines and the older
// sizes, where a person chooses the family and the size; its explanation is
// behind a (?) that Escape closes.
function tAreasHtml(machines) {
  const head = `<thead><tr><th>${esc(UX.colMachine)}</th><th>${esc(UX.colRegion)}</th><th>${esc(UX.colSize)}</th><th>${esc(UX.colGen)}</th><th>${esc(UX.colTarget)}</th><th>${esc(UX.colNewSize)}</th><th class="t-detcell"></th></tr></thead>`;
  const area = (id, title, list, help) => list.length ? `<div class="sec t-area" id="t-area-${id}">
      <h3>${esc(title)} <span class="pill quiet t-count">${esc(tCountText(list.length))}</span>${help ? ' ' + tHelpBtn(id, UX.tAreaHelp) : ''}</h3>
      ${help && tHelp.has(id) ? `<p class="muted t-help-text" id="t-help-${id}">${esc(help)}</p>` : ''}
      <table>${head}<tbody>${list.map(tTargetRow).join('')}</tbody></table></div>` : '';
  return `${area('same', UX.tAreaSame, machines.filter(m => !oldShape(m)), '')}
    ${area('shape', UX.tAreaShape, machines.filter(oldShape), UX.tAreaShapeHelp)}`;
}
// PRICE-EXPORT-1: the one handler for every (?), on the targets step and the Run it step.
function helpWire() {
  document.querySelectorAll('.t-help').forEach(b => b.addEventListener('click', () => {
    const id = b.dataset.help; if (tHelp.has(id)) tHelp.delete(id); else tHelp.add(id); render();
  }));
}
// The wait for the target options, on the step that needs them. MACHINE-PICK-1:
// the machines step needs them too, to know which machines can move.
function renderAdviceWait(el, title, body, back) {
    // Offered only when nothing is making them: while a job runs, a second one
    // would rewrite the options under another open page.
    el.innerHTML = card(title, body, `
      <div class="working" id="t-wait"><span class="spin"></span>${esc(UX.tWaiting)}</div>
      <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
        <button class="btn" id="t-make" style="display:none">${esc(UX.tMake)}</button></div>`);
    $('#b').addEventListener('click', back);
    $('#t-make').addEventListener('click', async () => {
      try {
        $('#t-make').disabled = true;
        await api('POST', `runs/${runSeg()}/engine/advise`, runBody({}));
        paintAdviceView({ show: 'wait' });
        startPolling();
      } catch (e) { failAction(e); $('#t-make').disabled = false; }
    });
    paintAdviceProgress();
    startPolling();
}
// MACHINE-PICK-1: the targets step shows the chosen machines only.
function tMachines() {
  return onlyChosen(targetAdvice?.machines, machineChoices);
}
function renderTargets(el) {
  if (!targetAdvice) { renderAdviceWait(el, UX.tTitle, UX.tBody, toChoose); return; }
  tLoadSaved();
  const machines = tMachines();
  tMarkSeen(machines);
  // ADVISE-AN-1: why each group is not on the default, behind the (?).
  const sumHelp = advSummaryHelpHtml(machines, tDefault, tOverrides, tSizes);
  el.innerHTML = card(UX.tTitle, UX.tBody, `
    <label class="f" id="t-def-label">${esc(UX.tDefault)}</label>
    <div class="choices" role="radiogroup" aria-labelledby="t-def-label">
      <label><input type="radio" name="t-def" value="current"${tDefault === 'current' ? ' checked' : ''}><span>${esc(UX.tCurrent)}<span class="sub">${esc(tStartHint('current'))}</span></span></label>
      <label><input type="radio" name="t-def" value="extended"${tDefault === 'extended' ? ' checked' : ''}><span>${esc(UX.tExtended)}<span class="sub">${esc(tStartHint('extended'))}</span></span></label>
    </div>
    <p class="muted" id="t-sum">${esc(advSummary(machines, tDefault, tOverrides, tSizes))}${sumHelp ? ' ' + tHelpBtn('sum', UX.tSumAbout) : ''}</p>
    ${sumHelp && tHelp.has('sum') ? sumHelp : ''}
    ${kernelNoticeHtml(kernelToCheck(machines, tDefault, tOverrides, tSizes, tKernelSel, tKSeen))}
    ${tempNoticeHtml(tempToCheck(machines, tDefault, tOverrides, tSizes, tTSeen))}
    ${anNoticeHtml(anToCheck(machines, tDefault, tOverrides, tSizes, tASeen))}

    ${tPreviewNoticeHtml(machines)}
    ${tMethodCountsHtml(machines)}
    ${tAreasHtml(machines)}
    ${tHelp.has('export') ? `<p class="muted t-help-text" id="t-help-export">${esc(UX.tExportHelp)}</p>` : ''}
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      <button class="btn ghost" id="t-export">${esc(UX.tExport)}</button>
      ${tHelpBtn('export', UX.tExportAbout)}
      ${roleAction('t-save', UX.tSave, canOperate, UX.stepNeedsOperator)}</div>`);
  // WIZARD-ROLES-3: only an operator saves the targets.
  if (!canOperate) { lockChoices(el, 'input, select, [data-kall]'); }
  helpWire();
  $('#t-export').addEventListener('click', exportTargets);
  document.querySelectorAll('input[name=t-def]').forEach(r => r.addEventListener('change', (e) => {
    // ADVISE-AN-1: a machine a person changed keeps its change; the others
    // follow the new default.
    tDefault = e.target.value; render();
  }));
  // An item is the option; its method follows from its size.
  document.querySelectorAll('select[data-vm]').forEach(s => s.addEventListener('change', (e) => {
    tOverrides.set(e.target.dataset.vm, String(e.target.value));
    render();
  }));
  // TEMP-DISK-PREVIEW-1: read the preview feature of the subscriptions that
  // need it, and again on Check again - never a reload.
  tPreviewLoad(machines);
  document.querySelectorAll('.t-pcheck').forEach(b => b.addEventListener('click', () => { tPreviewLoad(machines, b.dataset.psub); }));

  // A new family starts on its default size (familyStartSize): the best
  // choice, or the size that keeps the active vCPUs of a constrained vCPU
  // best choice, else the fewest vCPUs that fit.
  document.querySelectorAll('select[data-fvm]').forEach(s => s.addEventListener('change', (e) => {
    const m = machines.find(x => x.vmId === e.target.dataset.fvm); const pick = m && advPick(m, tDefault, tOverrides);
    const o = m && (m.options ?? []).find(x => x.option === pick);
    const first = familyStartSize(o?.sizeChoices, e.target.value);
    if (m && first) { setSize(tSizes, m, pick, first.size); render(); }
  }));
  document.querySelectorAll('select[data-dvm]').forEach(s => s.addEventListener('change', (e) => {
    const id = e.target.dataset.dvm;
    if (['os', 'all', 'os-standard-ssd'].includes(e.target.value)) tDiskSel.set(id, e.target.value); else tDiskSel.delete(id);
    render();
  }));
  // MANA-LINUX-KERNEL-1: a machine keeps its own choice only where it is not
  // Stop and ask.
  document.querySelectorAll('input.t-kernel').forEach(s => s.addEventListener('change', (e) => {
    const kvm = e.target.dataset.kvm, value = e.target.value;
    setKernelChoice(tKernelSel, kvm, value, tKernelDef); render();
    // The step is drawn again: focus stays on the radio button that was chosen.
    [...document.querySelectorAll('input.t-kernel')].find(r => r.dataset.kvm === kvm && r.value === value)?.focus();
  }));
  // KERNEL-UX-1: one choice for every machine still to check, which marks each
  // one checked. A machine can still be changed in its Details afterwards.
  document.querySelectorAll('[data-kall]').forEach(b => b.addEventListener('click', () => {
    kernelSetAll(kernelToCheck(machines, tDefault, tOverrides, tSizes, tKernelSel, tKSeen), b.dataset.kall, tKernelSel, tKSeen);
    render();
    // The button is gone with the notice: focus goes to the first Details.
    document.querySelector('.t-det')?.focus();
  }));
  document.querySelectorAll('select[data-svm]').forEach(s => s.addEventListener('change', (e) => {
    const m = machines.find(x => x.vmId === e.target.dataset.svm);
    if (m) { setSize(tSizes, m, advPick(m, tDefault, tOverrides), e.target.value); render(); }
  }));
  document.querySelectorAll('.t-det').forEach(b => b.addEventListener('click', () => {
    const id = b.dataset.vm; if (tOpen.has(id)) tOpen.delete(id); else tOpen.add(id); render();
  }));
  // MACHINE-PICK-1: the machines are the step before this one now.
  $('#b').addEventListener('click', toChoose);
  $('#t-save')?.addEventListener('click', () => saveTargets());
}
// What Save sends for each machine: its option, and its size only when that is
// not the option's own (the engine keeps the option's own size as none).
// MANA-LINUX-KERNEL-1: and the kernel choice of a machine whose own choice
// differs from the migration default (kernelDef), where it is offered.
function targetChoicesBody(machines, def, overrides, sizes, disks, kernels, kernelDef) {
  return machines.map(m => {
    const option = advPick(m, def, overrides);
    const o = (m.options ?? []).find(x => x.option === option);
    const size = sizeOf(m, option, sizes);
    const body = o && size && size !== o.targetSize ? { vmId: m.vmId, option, size } : { vmId: m.vmId, option };
    // REBUILD-PICKER-1: the method the list showed - preview where the row is
    // on the Preview (TEMP-DISK-PREVIEW-1); the service refuses any other
    // than the method of that size.
    if (o) body.method = tMethodOf(m, option, sizes);
    const d = disksOf(m, option, sizes, disks);
    if (d) body.disks = d;
    const k = kernelOf(m, option, sizes, kernels, kernelDef);
    if (k && k !== (kernelDef === 'update' ? 'update' : 'stop')) body.kernel = k;
    return body;
  }).filter(c => c.option);
}
// One machine's kernel choice: kept only where it differs from the default.
function setKernelChoice(kernels, vmId, value, def) {
  const k = value === 'update' ? 'update' : 'stop';
  if (k === (def === 'update' ? 'update' : 'stop')) kernels.delete(vmId); else kernels.set(vmId, k);
}
// KERNEL-UX-1: the machines whose network driver choice is still to check - a
// Linux machine whose target can use MANA (kernelOf), whose Details nobody
// opened in this session and that no All button set.
function kernelToCheck(machines, def, overrides, sizes, kernels, seen) {
  return (machines ?? []).filter(m => kernelOf(m, advPick(m, def, overrides), sizes, kernels, 'stop') && !seen.has(m.vmId));
}
// The notice above the tables, while a machine is still to check: what the dot
// means, and one button for each choice. It names no machine.
function kernelNoticeHtml(toCheck) {
  if (!toCheck.length) return '';
  return `<div class="t-kwarn"><span class="t-kdotx" aria-hidden="true"></span>${esc(UX.tKernelAlert)}
    <div class="rowact t-kall">${['stop', 'update'].map(k => `<button type="button" class="btn small ghost" data-kall="${k}">${esc(UX.tKernelAll[k])}</button>`).join('')}</div></div>`;
}
// An All button: the one choice on each machine still to check, and each one
// counts as checked.
function kernelSetAll(toCheck, value, kernels, seen) {
  for (const m of toCheck) { setKernelChoice(kernels, m.vmId, value, 'stop'); seen.add(m.vmId); }
}
// TEMPDISK-UX-1: the machines whose temporary disk is still to check - the size
// they go to has none while they have one now (tempLost), and nobody opened
// their Details in this session.
function tempToCheck(machines, def, overrides, sizes, seen) {
  return (machines ?? []).filter(m => tempLost(m, advPick(m, def, overrides), sizes) && !seen.has(m.vmId));
}
// The notice above the tables, while a machine is still to check: what the dot
// means. It names no machine, and it has no button - nothing is chosen here.
function tempNoticeHtml(toCheck) {
  if (!toCheck.length) return '';
  return `<div class="t-kwarn t-twarn"><span class="t-kdotx" aria-hidden="true"></span>${esc(UX.tTempAlert)}</div>`;
}
// ADVISE-AN-1: the machines whose accelerated networking is still to check -
// the size they go to turns it off (anLost), and nobody opened their Details
// in this session.
function anToCheck(machines, def, overrides, sizes, seen) {
  return (machines ?? []).filter(m => anLost(m, advPick(m, def, overrides), sizes) && !seen.has(m.vmId));
}
// The notice above the tables, while a machine is still to check. It names no
// machine, and it has no button - the choice is the size series of each row.
function anNoticeHtml(toCheck) {
  if (!toCheck.length) return '';
  return `<div class="t-kwarn t-awarn"><span class="t-kdotx" aria-hidden="true"></span>${esc(UX.tAnAlert)}</div>`;
}
// The words of the one dot on Details: each reason it shows, in one label.
function tDotWhy(kCheck, tCheck, aCheck) {
  return [kCheck ? UX.tKernelCheck : '', tCheck ? UX.tTempCheck : '', aCheck ? UX.tAnCheck : ''].filter(Boolean).join('. ');
}
// KERNEL-UX-1: the network driver choice, first in the Details of a machine it
// applies to: a title with its (?) help, why it is asked, and the two choices
// as radio buttons, each with what it does.
// RHEL-EUS-TARGET-NOTE-1: the note of a machine made from a RHEL image on the
// EUS repositories, or '' - from the target advice (Get-VmfEusImage).
function eusImageText(m) {
  const e = m?.eusImage;
  if (!e || !e.image || !e.release || !e.listedFrom) return '';
  return fill(UX.tKernelEus, { image: e.image, release: e.release, listed: e.listedFrom });
}
function kernelSectionHtml(m, kernel, helpId) {
  const title = fill(UX.tKernelTitle, { name: m.name });
  const eus = eusImageText(m);
  return `<div class="sec t-ksec">
      <h3>${esc(title)} ${tHelpBtn(helpId, UX.tKernelAbout)}</h3>
      <p class="muted">${esc(UX.tKernelWhy)}</p>
      ${tHelp.has(helpId) ? `<p class="muted t-help-text" id="t-help-${helpId}">${esc(UX.tKernelHelp)}</p>` : ''}
      ${eus ? `<p class="t-eus">${esc(eus)}</p>` : ''}
      <div class="choices" role="radiogroup" aria-label="${esc(title)}">${['stop', 'update'].map(k =>
        `<label><input type="radio" name="t-k-${esc(m.vmId)}" class="t-kernel" data-kvm="${esc(m.vmId)}" value="${k}"${k === kernel ? ' checked' : ''}><span>${esc(UX.tKernelChoice[k])}<span class="sub">${esc(UX.tKernelHint[k])}</span></span></label>`).join('')}</div>
    </div>`;
}
// A machine counts as checked once its open Details show the network driver
// choice - not when Details open with no choice in them: a machine whose
// target cannot use MANA keeps its dot for later, when another series or size
// can. Run before each drawing of the step, so the notice and the dot agree.
function tMarkSeen(machines) {
  for (const m of machines ?? []) {
    if (tOpen.has(m.vmId) && kernelOf(m, advPick(m, tDefault, tOverrides), tSizes, tKernelSel, 'stop')) tKSeen.add(m.vmId);
    // TEMPDISK-UX-1: the same rule - open Details count once they show the loss.
    if (tOpen.has(m.vmId) && tempLost(m, advPick(m, tDefault, tOverrides), tSizes)) tTSeen.add(m.vmId);
    // ADVISE-AN-1: and once they show that accelerated networking is turned off.
    if (tOpen.has(m.vmId) && anLost(m, advPick(m, tDefault, tOverrides), tSizes)) tASeen.add(m.vmId);
  }
}
// KERNEL-UX-1: the count of an area, as its heading shows it.
function tCountText(n) {
  return fill(n === 1 ? UX.tCountOne : UX.tCountMany, { count: n });
}
// PRICE-EXPORT-1: the one save, for both buttons. Save moves on to grouping.
// Export for pricing (andExport) downloads what was saved and stays on this
// step. A refused save, or one that could not be read back, downloads nothing.
async function saveTargets(andExport) {
  // Both buttons wait for the save: a second press would send the same
  // version again, and be refused in the name of the person who pressed.
  const btns = ['#t-save', '#t-export'].map(s => $(s)).filter(Boolean);
  // CLICKS-LOST-1: a sign at once; Save the targets gave none for seconds.
  const undoBusy = markBusy($('#t-save'), UX.tSaving);
  const giveBack = () => { undoBusy(); btns.forEach(b => { b.disabled = false; }); };
  try {
    $('#err').style.display = 'none';
    btns.forEach(b => { b.disabled = true; });
    const choices = targetChoicesBody(tMachines(), tDefault, tOverrides, tSizes, tDiskSel, tKernelSel, tKernelDef);
    // MACHINE-PICK-1: and the version of the machines this page read.
    // MANA-LINUX-KERNEL-1: and the kernel default.
    await api('POST', `assessments/${runSeg()}/targets`, runBody({
      default: tDefault, kernelDefault: tKernelDef, adviceVersion, choicesVersion, machinesVersion, choices }));
    said(UX.tSaved);
    // The address names the step, as a Back link does (BACKLOOP-1). A read
    // that fails after the save draws the waiting view, and its polling would
    // otherwise follow the saved targets on to grouping.
    const url = new URL(location.href);
    if (andExport) {
      url.searchParams.set('step', 'targets'); history.replaceState(null, '', url);
      await readRun();
      if (!readFailed) exportPricing();
      render(); return;
    }
    // And Save takes that request off again, so a reload goes on to grouping.
    if (url.searchParams.get('step') === 'targets') { url.searchParams.delete('step'); history.replaceState(null, '', url); }
    tOpen = new Set();
    await readRun();
    goStep(STEP.migrate.group);
  } catch (e) { failAction(e); giveBack(); }
}
// REBUILD-REMOVE-PLAN-1: CLICKS-LOST-1 took "Choose a target for these
// machines first" away once each machine was chosen. No machine waits for a
// choice now (the engine's decide is gone), so neither the message nor its
// sync is left.// Anything that opens must offer a way back (CLAUDE.md rule 11): Escape closes
// every open Details row.
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && step === STEP.migrate.targets && (tOpen.size || tHelp.size)) { tOpen.clear(); tHelp.clear(); render(); }
  // MACHINE-PICK-1: Show more opens more rows; Escape closes them, as Show fewer does.
  if (e.key === 'Escape' && journey === 'migrate' && step === STEP.migrate.choose && mShown > M_PAGE) { mShown = M_PAGE; render(); }
  if (e.key === 'Escape' && journey === 'migrate' && step === STEP.migrate.run && tHelp.size) { tHelp.clear(); render(); }
  if (e.key === 'Escape' && journey === 'assess' && step === STEP.assess.review && rOpen.size) { rOpen.clear(); render(); }
});

// WIZARD-WAVES-STEP-1: the assessment Build the waves planned from. Until the
// engine writes the migration's run.json, nothing read names it.
let plannedFrom = null;
// WIZARD-PLAN-FAIL-1: the watch of the assessment's log for a refused plan,
// and the refusal it found. Minutes with no answer before the page says so.
let planWatch = null, planRefused = null;
const PLAN_QUIET_MIN = 10;
function backToAssessment() {
  const from = (manifest && manifest.fromAssessment) || plannedFrom || planningFrom();
  if (from) {
    location.href = VmfHelp.VmfRun.link('wizard.html', VmfHelp.VmfRun.storePath(projectId, from));
  } else {
    location.href = 'assessments.html';
  }
}

async function buildWaves() {
  try {
    $('#err').style.display = 'none';
    $('#go3').disabled = true;
    const body = { waveStrategy: form.strategy };
    if (form.strategy === 'tags') {
      if ($('#f-apptag').value) body.appGroupTag = $('#f-apptag').value;
    }
    // ADVISOR-1 reverses GEN-ONCE-1: no series for the whole plan. Each machine
    // is planned on the target saved for it in the step before, and the engine
    // refuses a plan from the app without them.
    // ASSESS-PAGE-1: planning creates a MIGRATION from this assessment - a
    // different object with its own id. Follow it, or the wizard sits watching
    // the assessment for a plan being written somewhere else.
    const started = await api('POST', `runs/${runSeg()}/engine/plan`, runBody(body));
    if (started && started.migrationId) {
      plannedFrom = runId;
      runId = started.migrationId;
      const url = new URL(location.href);
      url.searchParams.set('run', runId);
      // WIZARD-WAVES-STEP-1: so a reload before the migration's run.json
      // exists still knows what it is, and where Back goes.
      url.searchParams.set('from', plannedFrom);
      history.replaceState(null, '', url);
    }
    plan = null;
    // WIZARD-BACK-TARGETS-1: the step now waits for the plan, so the poll moves it on.
    waitOn(STEP.migrate.group);
    renderPlanWait($('#step'));
    startPolling();
    watchPlanRefusal();
  } catch (e) { failAction(e); $('#go3').disabled = false; }
}

function renderStep4(el) {
  // WAVE-FLOW-1: THE EDITOR IS THIS STEP. It is a different page, so this
  // hands over to it rather than drawing anything.
  //
  // What stood here was a read-only table of wave, machines and sign-off, with
  // a yes button - and the screen where the work happens sat behind a link
  // called "Rearrange these waves", which reads as a layout tool - so the flow
  // looked as though it had no wave screen in it at all.
  //
  // `flow=1` is what the editor reads to know it is a step: it shows the strip,
  // and its buttons become the flow's one pair.
  location.href = runHref('waves.html', { flow: 1 });
}

// TEMPPOOL-1, moved here by WAVE-FLOW-1 from the step above, which is now the
// editor. This is a consequence of the plan rather than a setting, and the last
// screen before anything runs is where it is read.
function tempSections() {
  // TEMPPOOL-1: a review asked why the NVMe temporary disks use a pool, when
  // many customers do not use one. The pooling stayed - the disks arrive RAW
  // on every start and a boot task rebuilds it, so there is nothing to manage -
  // but the CHANGE was invisible until now. A v3 machine moving to a non-'d' v6
  // size loses its temporary disk entirely; a D16ds and up gains three to five
  // more. Both are worth knowing before the wave runs, and neither is a choice.
  //
  // Unknown is not zero: an entry whose count the catalog could not report is
  // excluded from both lists and admitted to, rather than being quietly counted
  // as "no change".
  const tempRows = (plan?.entries ?? []).map(e => ({
    name: vmName(e.vmId),
    from: e.assessment?.sourceTempDisks,
    to:   e.target?.tempDisks,
    windows: e.assessment?.os === 'Windows',
  }));
  const known = tempRows.filter(r => Number.isInteger(r.from) && Number.isInteger(r.to));
  const lose  = known.filter(r => r.from > 0 && r.to === 0);
  const gain  = known.filter(r => r.to > r.from);
  const anyUnknown = tempRows.length !== known.length;
  // LAB-UX-1: the D: drive is named only when a Windows machine is listed.
  const tempList = (title, body, windowsLine, rows, tone) => rows.length ? `
    <div class="sec">
      <h3>${esc(title)}</h3>
      <p class="muted">${esc(rows.some(r => r.windows) ? `${body} ${windowsLine}` : body)}</p>
      <table><thead><tr><th>${esc(UX.colMachine)}</th><th>${esc(UX.tempCol)}</th></tr></thead>
        <tbody>${rows.map(r => `<tr><td class="mono">${esc(r.name)}</td>
          <td><span class="pill ${esc(tone)}">${esc(r.from)} / ${esc(r.to)}</span></td></tr>`).join('')}</tbody></table>
    </div>` : '';
  return tempList(UX.tempLoseTitle, UX.tempLoseBody, UX.tempLoseWindows, lose, 'warn') +
         tempList(UX.tempGainTitle, UX.tempGainBody, UX.tempGainWindows, gain, 'quiet') +
         (anyUnknown && (lose.length || gain.length) ? `<p class="muted">${esc(UX.tempUnknown)}</p>` : '');
}
// What the person has entered on the Run it step, kept OUTSIDE the DOM so a
// redraw cannot discard it. Accepting settings or approving the wave both
// re-render, and losing a ticked box to a redraw reads as the button not
// working, so it took two clicks.
// PLANRUN-1: how the plan runs - every wave in turn now, or some at a time -
// and the start time typed for each wave, kept across a re-render.
// SQL-TEMPDB-SIGNOFF-1: sqlChecked, the box for SQL Server and the temporary disk.
const runForm = { note: '', ack: false, sqlChecked: false, how: 'all', times: {} };
// REBUILD-REMOVE-ACCEPT-1: no box accepts the loss of an identity or a rebuild,
// at a wave or at the sign-off. No plan of this version rebuilds a machine.

// WAVE-FLOW-1: the settings of ONE wave, as a table a person can read.
// Every one of these was decided in the editor, on the wave card. This is
// where they are read back before anything runs.
// RUN-IT-1: what each machine in the wave becomes, above what the wave does -
// so the last screen before Start says it, not only the targets step.
// MANA-WIN-3: and under each machine, the notes the plan wrote for it
// (planNotes), for example that the move can download the MANA driver from
// download.microsoft.com - before this they showed only after the move.
function sizeRowsFor(wave) {
  const short = (s) => String(s ?? '').replace(/^Standard_/, '');
  return (plan?.entries ?? [])
    .filter(e => e.wave === wave && e.path === 'A')
    .map(e => `<tr><td class="mono">${esc(vmName(e.vmId))}</td><td class="mono">${
      esc(e.assessment?.sourceSize ? `${short(e.assessment.sourceSize)}  →  ${short(e.target?.size)}` : short(e.target?.size))}</td></tr>` +
      VmfHelp.planNotesOf(e)
        .map(n => `<tr><td colspan="2" class="muted">${esc(n)}</td></tr>`).join(''))
    .join('');
}
// AN-PLAN-1: named where the settings are accepted - see migrations.html.
// WAVE-AN-NAMES-1: every machine whose move turns it on, and on their own row
// the machines whose move decides, by the rule of the acceptance (help.js).
function anTurnsOnNames(wave) {
  // ACCEPT-SET-1: the machines that move - the set the acceptance covers.
  return VmfHelp.anOutcomeNames((plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A'), 'on', vmName);
}
function anDecidedNames(wave) {
  return VmfHelp.anOutcomeNames((plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A'), 'decides', vmName);
}
// TEMP-DISK-PREVIEW-1: the machines of the wave that take the in-place upgrade
// (Preview), by the rule the wave editor asks (help.js previewNames).
function previewText(wave) {
  const names = VmfHelp.previewNames((plan?.entries ?? []).filter(e => e.wave === wave), vmName);
  return !names.length ? UX.lvNone : (names.length === 1 ? UX.lvNamesOne : UX.lvNamesMany).replace('{n}', String(names.length)).replace('{names}', names.join(', '));
}
// MANA-LINUX-KERNEL-1: the machines that update their kernel when it has no
// MANA driver - each one chose it on the targets step, as its own decision.
function kernelUpdateNames(wave) {
  return (plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A' && e.policy?.onDriverBelowFloor === 'updateKernel').map(e => vmName(e.vmId));
}
// WIZARD-OPTIONS-DISKS-1: each machine of the wave whose move changes the type
// of its disks, with the type it changes to - by the rule of the acceptance on
// the migration's page (help.js), so both places show the same names.
function diskChangeTexts(wave) {
  return (plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A' && VmfHelp.diskUpgradeOf(e))
    .map(e => UX.lvDiskMachine.replace('{name}', vmName(e.vmId)).replace('{type}', UX.tDiskChoice[VmfHelp.diskUpgradeOf(e)]));
}
function leverRowsFor(wave) {
  const moving = (plan?.entries ?? []).filter(e => e.wave === wave && e.path === 'A');
  // ACCEPT-FIRST-MACHINE-1: the settings of the wave by the wave editor's rule
  // (help.js waveCard), never the first machine; under a setting, each machine
  // that does not follow it, in the editor's words - as on the acceptance of
  // the Migrations page. No button: this step shows, the wave editor changes.
  const waveAll = (plan?.entries ?? []).filter(e => e.wave === wave);
  const card = VmfHelp.waveCard(waveAll);
  const lever = card.values;
  const ownOf = (field) => {
    const own = waveAll.filter(e => (card.own[field] ?? []).includes(e.vmId));
    if (!own.length) return '';
    return `<div class="muted hint" style="font-size:12px;margin-top:6px">${esc(VmfHelp.ownCountText(own.length))}</div>` +
      own.map(e => `<div class="hint" data-ownrow style="font-size:12px">${esc(VmfHelp.ownRowText(field, e, vmName))}</div>`).join('');
  };
  // WAVE-KERNEL-LINE-1: no row for a kernel setting of the wave - there is
  // none. The machines that update their kernel are named on their own row.
  return [
    [UX.lvCopy, UX.lvCopyAlways],
    [UX.lvCapacity, lever.capacityGate === 'Reserved' ? UX.lvCapReserved : UX.lvCapOnDemand],
    [UX.lvData, lever.onDDataFound === 'proceed' ? UX.lvDataProceed : UX.lvDataStop, 'onDDataFound'],
    [UX.lvKeep, VmfHelp.keepDaysText(lever.keepSnapshotDays, UX.lvKeepNever, UX.lvKeepOne, UX.lvKeepMany), 'keepSnapshotDays'],
    // MACHINES-AT-ONCE-RANGE-1: the choice, its machines and engine
    // containers, and how long the wave takes - by the engine's own rule.
    [UX.lvAtOnce, [VmfHelp.atOnceChoice(VmfHelp.waveAtOnce(moving)).label,
      VmfHelp.waveEstimate(moving.length, VmfHelp.waveAtOnce(moving), UX)].filter(Boolean).join('. ')],
    // SIGNOFF-NULL-1: every machine of the wave, as the engine's gate reads it.
    [UX.lvApproval, (plan?.entries ?? []).filter(e => e.wave === wave).some(VmfHelp.approvalRequired) ? UX.lvYes : UX.lvNo],
    // TEMP-DISK-PREVIEW-1: the machines that need the preview feature.
    // REBUILD-REMOVE-ACCEPT-1: no row for a rebuild or a new identity.
    [UX.lvPreview, previewText(wave)],
    [UX.lvAn, anTurnsOnNames(wave).join(', ') || UX.lvNone],
    [UX.lvAnDecides, anDecidedNames(wave).join(', ') || UX.lvNone],
    [UX.lvKernel, kernelUpdateNames(wave).join(', ') || UX.lvNone],
    // WIZARD-OPTIONS-DISKS-1: the row Review & accept options shows, in the same place.
    [UX.lvDisks, diskChangeTexts(wave).join(', ') || UX.lvNone],
  ].map(([k, v, field]) => `<tr><td class="muted">${esc(k)}</td><td>${esc(v)}${field ? ownOf(field) : ''}</td></tr>`).join('');
}

/* DECIDE-ROLE-1: the control that accepts the settings of one wave, or the
 * reason there is none. The service accepts them only from an operator or an
 * administrator, so a button drawn for anybody else could only be refused. The
 * Migrations page draws its button on canOperate() for the same reason. The
 * link to change the settings goes with it: arranging the waves is the
 * operator's too. PURE, so a test can run it. */
function acceptControl(wave, isNext, canOperateNow, editHref) {
  if (!canOperateNow) {
    return `<p class="muted" style="margin:12px 0 0">${esc(UX.acceptNeedsOperator)}</p>`;
  }
  return `<div class="rowact">
             <button class="btn${isNext ? '' : ' ghost'}" data-accept="${esc(wave)}">${esc(UX.acceptBtn)}</button>
             <a href="${editHref}">${esc(UX.acceptEdit)}</a>
           </div>`;
}
/* ACCEPT-BULK-1: one click for the lot, when there is more than one left -
 * and, by DECIDE-ROLE-1, only for a user the service lets accept them. The
 * reason is said once beside each wave, so this row says nothing. PURE. */
function acceptAllControl(outstandingCount, canOperateNow) {
  if (!canOperateNow || outstandingCount < 2) { return ''; }
  return `<div class="rowact" style="margin-bottom:14px"><button class="btn" data-accept-all="1">${
    esc(UX.acceptAllBtn.replace('{n}', String(outstandingCount)))}</button></div>`;
}

/* WIZARD-ROLES-3: a step that a user without the operator role can read but
 * not change. Every choice on it is turned off, so nothing they set looks as
 * if it will be saved; help, filters and Show more stay on. PURE on the
 * element it is given, so a test can run it. */
function lockChoices(root, selector) {
  if (!root) { return; }
  root.querySelectorAll(selector).forEach(x => { x.disabled = true; });
}

/* WIZARD-ROLES-2: a step's action button, or the reason there is none. The
 * service refuses the call for a user without the role, so a button drawn for
 * anybody else could only be refused. The reason takes the button's place, so
 * the step still shows who can do it. PURE, so a test can run it. */
function roleAction(id, label, allowed, why) {
  if (!allowed) { return `<span class="muted" id="${id}-why">${esc(why)}</span>`; }
  return `<button class="btn" id="${id}">${esc(label)}</button>`;
}

/* WIZARD-START-ROLE-1: Start the plan, or the reason there is none. The
 * service starts a wave, records the infrastructure-as-code acknowledgement
 * and sets the start times only for an operator or an administrator, so a
 * button drawn for anybody else could only be refused - and an approver who
 * is not an operator signs off the plan on this same screen. The reason under
 * the button says what is still missing. PURE, so a test can run it. */
function startControl(ready, canOperateNow, notReadyWhy) {
  const why = (text) => `<p class="muted" id="go5-why" style="text-align:right;margin:6px 0 0">${esc(text)}</p>`;
  if (!canOperateNow) { return { button: '', note: why(UX.startNeedsOperator) }; }
  return {
    button: `<button class="btn" id="go5"${ready ? '' : ' disabled'}>${esc(UX.startPlanBtn)}</button>`,
    note: ready ? '' : why(notReadyWhy),
  };
}

/* WAVE-APPROVE-1: the sign-off state of one wave on the Run it step.
 * "Sign off all" writes one approval per wave, each signing its own wave, and
 * every plan writer removes an approval its change made stale - so an approval
 * file that exists is current, the same reading the Migrations page makes.
 * 'signed' - the wave has its own approval, or the sign-off of the plan
 *            version on screen covers it;
 * 'asks'   - the plan was signed off, and this wave changed after it;
 * 'none'   - nothing was signed yet. PURE, so a test can run it. */
function waveSignState(wave, approvalsByWave, signoff, signoffCurrent) {
  if (approvalsByWave && approvalsByWave.get(wave)) { return 'signed'; }
  if (signoff && signoffCurrent) { return 'signed'; }
  return signoff ? 'asks' : 'none';
}

/* CODE-NOTE-ACK-SAVED-1: the stored acknowledgement counts when it names who
 * accepted it - the Migrations page's rule (runAcknowledged) and the engine's
 * (Test-VmfRunAcknowledged). PURE, so a test can run it. */
function ackGiven(doc) {
  return Boolean(doc && doc.acknowledgedBy);
}

/* CODE-NOTE-ACK-SAVED-1: save the ticked note about machines defined in code.
 * Only Start the plan saved it, so a plan signed off with the box ticked and
 * started later - by its start times, or from the Migrations page - had no
 * acknowledgement, and the engine refused every wave for it. Sign off and
 * Start both call this. Nothing is sent when the box is not ticked, when the
 * note is already accepted (the store keeps who accepted it first), or for
 * somebody the service would refuse. Returns whether it saved. */
async function saveIacAck() {
  if (acknowledged || !canOperate || !runForm.ack) { return false; }
  await api('POST', `runs/${runSeg()}/acknowledge`, runBody({ topic: 'infrastructure-as-code' }));
  acknowledged = true;
  return true;
}

/* IAC-NOTE-LIST-1: the note about machines defined in code, in its approved
 * form - a lead, a list with one item for each change, and a closing
 * line. It was one paragraph of ten sentences: one long run-on list of
 * items, and not easy to read. DOM nodes and textContent only, so no word
 * of it is read as markup. The Migrations page builds the same note. */
function iacNoteNodes() {
  const lead = document.createElement('p');
  lead.textContent = UX.iacLead;
  const list = document.createElement('ul');
  for (const change of UX.iacChanges) {
    const item = document.createElement('li');
    item.textContent = change;
    list.appendChild(item);
  }
  const after = document.createElement('p');
  after.textContent = UX.iacAfter;
  return [lead, list, after];
}

/* SQL-TEMPDB-SIGNOFF-1: the words of the section for SQL Server and the
 * temporary disk, as DOM nodes - a lead, one list item for each machine by
 * name, and what to check. textContent only, so no machine name is read as
 * markup. The shape of the note about machines defined in code. */
function sqlNoteNodes(ids) {
  const lead = document.createElement('p');
  lead.textContent = UX.sqlLead;
  const list = document.createElement('ul');
  for (const id of ids) {
    const item = document.createElement('li');
    item.textContent = machineNameOf(id);
    list.appendChild(item);
  }
  const after = document.createElement('p');
  after.textContent = UX.sqlAfter;
  return [lead, list, after];
}

function renderStep5(el) {
  const waves = planWaves();
  const [first] = waves[0] ?? [null, null];
  if (!first) { el.innerHTML = card(UX.s5Title, UX.s2None, ''); return; }

  /* PLANRUN-1: sign off the PLAN, once, and let it run.
   *
   * This step approved the FIRST wave and started it. Every later wave then
   * waited for a person to approve and start it from the Migrations page -
   * while the person believed they had signed off the plan, and three approved
   * waves sat idle because nothing was coming for them. And the one button
   * slot did two jobs in turn - "Approve wave-2", then "Start wave-2" in the
   * same place - so it had to be pressed twice (START-TWICE-1).
   *
   * Now: accept each wave's settings, sign off the plan once - bound to the
   * plan version, so an edit drops it - choose how it runs, and start. Each
   * control does one job, and each says why it is waiting.
   *
   * WAVE-APPROVE-1: the sign-off is one approval per wave, so an edit drops
   * the approval of the wave it changed and no other. The plan is signed when
   * every wave is, and each wave says which it is. */
  const signState = new Map(waves.map(([w]) => [w, waveSignState(w, approvals, planSignoff, planSignoffCurrent)]));
  const asking = waves.map(([w]) => w).filter(w => signState.get(w) === 'asks');
  // The consent to run on comes from the sign-off record itself - the rule of
  // the engine (Test-VmfPlanRunConsent) and of the Migrations page
  // (planStartsWave). Wave approvals alone, made one by one, start nothing.
  const consent = Boolean(planSignoff);
  const signed = consent && waves.length > 0 && waves.every(([w]) => signState.get(w) === 'signed');
  const signedWho = planSignoff?.approvedBy?.identity ?? '?';
  const waveSignLine = (w) => {
    const a = approvals.get(w);
    if (a) { return `<p class="muted" style="margin:6px 0 0">${esc(UX.waveApprovedBy.replace('{who}', a.approvedBy?.identity ?? '?'))}</p>`; }
    return signState.get(w) === 'asks' ? `<p style="margin:6px 0 0"><span class="pill warn">${esc(UX.waveSignStale)}</span></p>` : '';
  };

  // ROLLBACK-CAPACITY-1, FILTER-DRIVER-READ-1 and DISK-PATH-READ-1: the lines
  // under the settings of a wave, each only for a wave it is true of, by the
  // one rule of help.js that Review & accept options on the Migrations page
  // asks too.
  // SQL-TEMPDB-SIGNOFF-1: and the SQL Server machines of the wave whose target
  // has an NVMe temporary disk or none, by name.
  const riskLines = (w) => VmfHelp.signOffRiskLines((plan?.entries ?? []).filter(e => e.wave === w),
    { capacity: UX.lvCapacityNoGuarantee, nvme: [UX.lvNvmeThirdParty, UX.lvNvmeThirdPartyWhat, UX.lvNvmeDiskPaths], sql: UX.lvSqlTempdb }, (id) => machineNameOf(id))
    .map(t => `<p class="muted" data-waverisk style="margin:10px 0 0">${esc(t)}</p>`).join('');

  // WAVE-FLOW-1: EVERY wave, not only the first - each with its own settings.
  const waveSections = waves.map(([w, wInfo]) => {
    const wAccepted = acceptances.get(w);
    const isNext = w === first;
    return `<div class="sec">
      <h3>${esc(UX.acceptTitle)} &middot; <span class="mono">${esc(w)}</span>${isNext ? ` <span class="pill quiet">${esc(UX.waveNext)}</span>` : ''}</h3>
      <p class="muted" style="margin:0 0 10px">${esc(wInfo.n)} ${wInfo.n === 1 ? esc(UX.machine) : esc(UX.machines)}</p>
      <table class="facts" style="margin-bottom:12px">${sizeRowsFor(w)}</table>
      <table class="facts">${leverRowsFor(w)}</table>
      ${riskLines(w)}
      ${wAccepted
        ? `<p class="muted" style="margin:12px 0 0">${esc(UX.acceptedBy)} ${esc(wAccepted.acceptedBy ?? '?')}</p>`
        : acceptControl(w, isNext, canOperate, `${runHref('waves.html')}#wave=${encodeURIComponent(w)}`)}
      ${waveSignLine(w)}
    </div>`;
  }).join('');

  // ACCEPT-BULK-1: one click for the lot, when there is more than one left.
  const outstanding = waves.filter(([w]) => !acceptances.get(w)).map(([w]) => w);
  const allAccepted = outstanding.length === 0;
  const acceptAllRow = acceptAllControl(outstanding.length, canOperate);

  const signSection = `<div class="sec">
      <h3>${esc(UX.signTitle)}</h3>
      <p class="muted" style="margin:0 0 10px">${esc(UX.signBody)}</p>
      <label class="f" for="f-note">${esc(UX.noteLabel)}</label><textarea id="f-note" rows="2" aria-required="true" aria-describedby="f-note-err">${esc(runForm.note)}</textarea>
      <p class="f-err" id="f-note-err" role="alert" hidden></p>
      ${signed
        ? `<p style="margin:10px 0 0"><span class="pill good">${esc(UX.signedBy.replace('{who}', signedWho))}</span></p>`
        : canApprove
          ? `<div class="rowact" style="margin-top:10px"><button class="btn" id="signoff"${allAccepted ? '' : ' disabled'}>${
              esc(waves.length > 1 ? UX.signBtn.replace('{n}', String(waves.length)) : UX.signBtnOne)}</button></div>
             ${allAccepted ? '' : `<p class="muted" style="margin:8px 0 0">${esc(UX.acceptFirst)}</p>`}`
          : `<p class="muted" style="margin:10px 0 0">${esc(UX.signNeedsApprover)}</p>`}
      ${asking.length ? `<p class="muted" style="margin:8px 0 0">${esc(UX.signStale.replace('{waves}', asking.join(', ')))}</p>` : ''}
    </div>`;

  // Beside each wave: what starts it, as the person has set it so far.
  const followText = (i) => {
    const [w] = waves[i];
    if (runForm.how === 'times' && runForm.times[w]) { return ''; }
    return i === 0 ? UX.startsNow : UX.followsLine.replace('{wave}', waves[i - 1][0]);
  };
  // WIZARD-ROLES-2: only the start sends these, and only an operator starts,
  // so for anybody else they show the order and take no input.
  const off = canOperate ? '' : ' disabled';
  const howSection = `<div class="sec">
      <h3>${esc(UX.howTitle)}</h3>
      <div class="choices">
        <label><input type="radio" name="how" value="all"${runForm.how === 'times' ? '' : ' checked'}${off}><span>${esc(UX.howAll)}</span></label>
        <label><input type="radio" name="how" value="times"${runForm.how === 'times' ? ' checked' : ''}${off}><span>${esc(UX.howTimes)}</span></label>
      </div>
      <p class="muted" style="margin:8px 0 0"><span id="how-hint">${esc(runForm.how === 'times' ? UX.howTimesHint : UX.howAllHint)}</span> ${tHelpBtn('run-check', UX.howCheckAbout)}</p>
      ${tHelp.has('run-check') ? `<p class="muted t-help-text" id="t-help-run-check">${esc(UX.howCheckHelp)}</p>` : ''}
      <!-- RUN-ORDER-1: the order is shown under BOTH choices. It was shown
           only with the start times, so "Run all waves in order" never said
           which wave went first. The time field is the only part that hides. -->
      <table class="facts" id="how-times" style="margin-top:10px">${
        waves.map(([w], i) => `<tr><td class="mono">${i + 1}. ${esc(w)}</td>
          <td data-timecell style="display:${runForm.how === 'times' ? '' : 'none'}"><input type="datetime-local" data-time="${esc(w)}" value="${esc(runForm.times[w] ?? '')}" aria-label="${esc(w)}"${off}></td>
          <td class="muted" data-follow="${i}">${esc(followText(i))}</td></tr>`).join('')}</table>
      <p class="muted" style="margin:12px 0 0">${esc(UX.atOnceWhere)}</p>
      <p class="muted" style="margin:12px 0 0">${esc(UX.holdNote)}</p>
    </div>`;

  // SQL-TEMPDB-SIGNOFF-1 (2026-11-16): the machines where the
  // scan found SQL Server that move from a SCSI temporary disk to an NVMe
  // temporary disk or none (help.js sqlTempdbEntries, the twin of the
  // engine's Test-VmfSqlTempdbRisk), and the box the approver ticks before
  // the sign-off - the shape of the note about machines defined in code.
  // Nothing at all for a plan with no such machine ("make sure its ONLY if we
  // detect SQL"), or once it is signed off (the sign-off recorded the box).
  // Only an approver signs off, so only an approver gets the box; everybody
  // else reads the list.
  const sqlIds = signed ? [] : VmfHelp.sqlTempdbEntries(plan?.entries).map(e => e.vmId);
  const sqlSection = sqlIds.length ? `<div class="sec">
      <h3>${esc(UX.sqlTitle)}</h3>
      <div class="muted iac-note" id="sql-note"></div>
      ${canApprove
        ? `<label class="ackrow"><input type="checkbox" id="f-sql" aria-describedby="f-sql-err"${runForm.sqlChecked ? ' checked' : ''}><span>${esc(UX.sqlAccept)}</span></label>
           <p class="f-err" id="f-sql-err" role="alert" hidden></p>`
        : ''}
    </div>` : '';

  const ready = allAccepted && signed;
  const start = startControl(ready, canOperate, !allAccepted ? UX.acceptFirst : UX.signFirst);
  el.innerHTML = card(UX.s5Title, UX.s5Body, `
    ${acceptAllRow}
    ${waveSections}
    ${tempSections()}
    ${sqlSection}

    ${acknowledged ? '' : `<div class="sec">
      <h3>${esc(UX.iacTitle)}</h3>
      <div class="muted iac-note" id="iac-note"></div>
      ${canOperate
        ? `<label class="ackrow"><input type="checkbox" id="f-ack" aria-describedby="f-ack-err"${runForm.ack ? ' checked' : ''}><span>${esc(UX.iacAccept)}</span></label>
          <p class="f-err" id="f-ack-err" role="alert" hidden></p>`
        : ''}
    </div>`}

    ${signSection}
    ${howSection}

    ${tHelp.has('run-export') ? `<p class="muted t-help-text" id="t-help-run-export">${esc(UX.rExportHelp)}</p>` : ''}
    <p id="s5-failed" role="alert" style="color:var(--bad);display:none"></p>
    <div class="nav"><button class="btn ghost" id="b">${esc(UX.back)}</button><span class="sp"></span>
      <button class="btn ghost" id="r-export">${esc(UX.tExport)}</button>
      ${tHelpBtn('run-export', UX.tExportAbout)}
      ${start.button}</div>
    ${start.note}`);
  // IAC-NOTE-LIST-1: the note is built with DOM nodes, not markup.
  el.querySelector('#iac-note')?.replaceChildren(...iacNoteNodes());
  el.querySelector('#sql-note')?.replaceChildren(...sqlNoteNodes(sqlIds));
  // PRICE-EXPORT-1: the plan, with the wave of each machine.
  helpWire();
  $('#r-export').addEventListener('click', exportPlan);
  // CLAIM-AT-PLAN-1: a start the engine refused is said above Start, also after
  // the page is opened again - the press itself may be long gone.
  paintStartFailure();

  document.querySelectorAll('input[name=how]').forEach(r => r.addEventListener('change', () => {
    runForm.how = document.querySelector('input[name=how]:checked').value;
    el.querySelectorAll('[data-timecell]').forEach(td => { td.style.display = runForm.how === 'times' ? '' : 'none'; });
    $('#how-hint').textContent = runForm.how === 'times' ? UX.howTimesHint : UX.howAllHint;
    el.querySelectorAll('[data-follow]').forEach(td => { td.textContent = followText(Number(td.dataset.follow)); });
  }));
  el.querySelectorAll('[data-time]').forEach(inp => inp.addEventListener('input', () => {
    runForm.times[inp.dataset.time] = inp.value;
    el.querySelectorAll('[data-follow]').forEach(td => { td.textContent = followText(Number(td.dataset.follow)); });
  }));
  $('#f-note')?.addEventListener('input', (e) => { runForm.note = e.target.value; clearFieldErr($('#f-note')); });

  $('#f-ack')?.addEventListener('change', (e) => { runForm.ack = e.target.checked; clearFieldErr($('#f-ack')); });
  $('#f-sql')?.addEventListener('change', (e) => { runForm.sqlChecked = e.target.checked; clearFieldErr($('#f-sql')); });


  // One handler for every wave on the screen, not one for the first.
  el.querySelectorAll('[data-accept]').forEach(btn => btn.addEventListener('click', async () => {
    const was = btn.textContent;
    // WIZARD-START-ERROR-OUT-OF-VIEW-1: an old error goes when a new try starts.
    clearErr();
    try {
      btn.disabled = true;
      btn.textContent = UX.acceptBusy;
      // ACCEPT-HASH-1 / PLANVER-2: say WHICH plan is agreed to - the version
      // the SERVICE issued beside the document.
      const pv = DEMO_MODE ? null : await blobVersioned(`${runPrefix()}/plan.json`);
      if (!DEMO_MODE && !(pv && pv.version)) { throw new Error(UX.acceptNoPlan); }
      const body = { wave: btn.dataset.accept };
      if (pv) { body.planHash = pv.version; }
      await api('POST', `runs/${runSeg()}/waves/accept-options`, runBody(body));
      await readRun(); render();
    } catch (e) { failAction(e); btn.disabled = false; btn.textContent = was; }
  }));
  // ACCEPT-BULK-1: the plan is read ONCE, and every wave agrees to that version.
  el.querySelector('[data-accept-all]')?.addEventListener('click', async (ev) => {
    const btn = ev.currentTarget;
    const was = btn.textContent;
    const todo = Array.from(el.querySelectorAll('[data-accept]')).map(b => b.dataset.accept);
    clearErr();
    btn.disabled = true;
    try {
      btn.textContent = UX.acceptAllBusy.replace('{i}', '1').replace('{n}', String(todo.length));
      const pv = DEMO_MODE ? null : await blobVersioned(`${runPrefix()}/plan.json`);
      if (!DEMO_MODE && !(pv && pv.version)) { throw new Error(UX.acceptNoPlan); }

      for (let i = 0; i < todo.length; i++) {
        btn.textContent = UX.acceptAllBusy.replace('{i}', String(i + 1)).replace('{n}', String(todo.length));
        const body = { wave: todo[i] };
        if (pv) { body.planHash = pv.version; }
        await api('POST', `runs/${runSeg()}/waves/accept-options`, runBody(body));
      }
      await readRun(); render();
    } catch (e) { failAction(e); btn.disabled = false; btn.textContent = was; }
  });
  // WAVE-FLOW-1: back is the editor, which IS the step before this one.
  $('#b').addEventListener('click', () => { location.href = runHref('waves.html', { flow: 1 }); });

  // PLANRUN-1: ONE signature for every wave, for the plan version on screen.
  $('#signoff')?.addEventListener('click', async () => {
    const note = $('#f-note').value.trim();
    if (!note) return failField($('#f-note'), UX.noteMissing);
    // SQL-TEMPDB-SIGNOFF-1: the machines on screen; the service refuses the
    // sign-off too, by name, for one it does not get. Said under the box.
    if (sqlIds.length && !runForm.sqlChecked) return failField($('#f-sql'), UX.sqlMissing);
    clearErr();
    try {
      $('#signoff').disabled = true;
      $('#signoff').textContent = UX.signBusy;
      const pv = DEMO_MODE ? null : await blobVersioned(`${runPrefix()}/plan.json`);
      if (!DEMO_MODE && !(pv && pv.version)) { throw new Error(UX.acceptNoPlan); }
      const body = { note };
      if (pv) { body.planHash = pv.version; }
      if (sqlIds.length) { body.sqlTempdbChecked = sqlIds; }
      await api('POST', `runs/${runSeg()}/approve-plan`, runBody(body));
      // CODE-NOTE-ACK-SAVED-1: the plan may start later, without this page.
      await saveIacAck();
      await readRun(); render();
    } catch (e) { failAction(e); render(); }
  });

  $('#go5')?.addEventListener('click', async () => {
    const note = $('#f-note').value.trim();
    if (!note) return failField($('#f-note'), UX.noteMissing);
    // IAC-2: the engine requires this for the run; asking here means the person
    // is told BEFORE they start. The engine is still the gate.
    if (!acknowledged && !$('#f-ack')?.checked) return failField($('#f-ack'), UX.iacMissing);
    clearErr();
    const startedAtUtc = new Date().toISOString();
    const undoBusy = markBusy($('#go5'), UX.startPlanBusy);
    try {
      await saveIacAck();

      const timed = runForm.how === 'times'
        ? waves.map(([w]) => [w, runForm.times[w]]).filter(([, t]) => t)
        : [];
      for (const [, t] of timed) { if (!(new Date(t) > new Date())) throw new Error(UX.whenPast); }
      // The start times first, so the plan's own timer sees them before the
      // first wave can finish. MACHINES-AT-ONCE-RANGE-1: no number goes with
      // a start or a schedule - every wave runs at its own number, which the
      // service reads from the plan when the wave starts.
      for (const [w, t] of timed) {
        await api('POST', `runs/${runSeg()}/waves/${encodeURIComponent(w)}/schedule`,
          runBody({ runAtUtc: new Date(t).toISOString(), note }));
      }
      const firstTimed = timed.some(([w]) => w === first);
      if (!firstTimed) {
        await api('POST', `runs/${runSeg()}/engine/wave`, runBody({ wave: first, note }));
      }
      // RUN-GO-1: the run page is where the plan is watched now, so go there.
      // With nothing starting this minute there is nothing to wait for here.
      if (firstTimed) { location.href = runHref('migrations.html'); return; }
      $('#step').innerHTML = card(UX.s5Title, UX.s5Done,
        `<p class="muted working" id="s5-watch"><span class="spin"></span>${esc(UX.watching)}</p>
         <a class="btn" style="text-decoration:none" href="${runHref('migrations.html')}">${esc(UX.openRun)}</a>`);
      // The engine runs elsewhere and can refuse AFTER this returns.
      watchForRefusal(startedAtUtc);
    } catch (e) { failAction(e); undoBusy(); }
  });
}

// CLAIM-AT-PLAN-1: the last start of a wave, read from the run's own log. One
// bad read of a log being written is not an answer (WATCH-1): nothing is said.
async function paintStartFailure() {
  if (DEMO_MODE) { return; }
  let events;
  try { events = await VmfHelp.readLogEvents(blobText, `${runPrefix()}/logs/events.jsonl`); }
  catch { return; }
  const failure = waveStartFailure(events);
  const el = $('#s5-failed');
  if (!el || !failure) { return; }
  el.textContent = startFailedText(failure.detail);
  el.style.display = '';
}

/* LAB-UX-1: a button that starts something slow says so at once. Start the
 * plan went grey and said nothing while the service started the engine, which
 * can take a minute - so the plan looked as if it had not started. Returns the
 * way back, for a start that fails. */
// CLICKS-LOST-1: the rule is shared now (help.js), with the turning circle.
function markBusy(btn, text) {
  return VmfHelp.markBusy(btn, text);
}

/* CLAIM-AT-PLAN-1: the start of a wave the engine refused, by the Migrations
 * page's rule (lastEngineFailure) for that one operation: the LATEST line of
 * step engine:wave, when it failed or was refused, with a reason. A later
 * start clears an older refusal. null otherwise. PURE, so a test can run it
 * beside the Migrations page's own rule. */
function waveStartFailure(events) {
  let last = null;
  for (const e of events ?? []) {
    if (String(e?.step ?? '') === 'engine:wave') { last = e; }
    // CLICKS-LOST-1: the service's line for a new start of a wave clears the
    // refusal before it, as the Migrations page does (lastEngineFailure).
    if (e?.step === 'engine' && ['start', 'warn'].includes(e.outcome) && e.operation === 'wave') { last = null; }
  }
  return last && (last.outcome === 'fail' || last.outcome === 'refused') && last.detail ? last : null;
}
// The Migrations page's words for it (nextFailed with nextFailedWave).
function startFailedText(detail) {
  return UX.refused.replace('{reason}', String(detail ?? ''));
}
// What the watch after a start decides from the lines since the press. A
// failure beats a start - if both land in the same tick the run is not going
// anywhere, and saying "it started" would be the last thing this screen said.
function startWatchVerdict(events) {
  const failure = waveStartFailure(events);
  if (failure) { return { failure }; }
  return (events ?? []).some(e => { const step = String(e.step ?? ''); return step === 'wave' || step.startsWith('PRECHECK'); })
    ? { started: true } : null;
}

// The engine may refuse after the start call has already succeeded. It records
// the reason in the run log (docker/entrypoint.ps1); this is the half that
// puts it in front of the person who pressed the button.
async function watchForRefusal(sinceUtc) {
  // WATCH-1: the loop is VmfHelp.watchRun.
  const watchFor = (timeoutMs) => VmfHelp.watchRun({
    // EVENTLOG-1: a filled log carries on in a second document. help.js walks
    // the parts.
    readLines: async () => VmfHelp.readLogEvents(blobText, `${runPrefix()}/logs/events.jsonl`),
    sinceMs: Date.parse(sinceUtc),
    timeoutMs,
    scan: startWatchVerdict,
  });
  let verdict = await watchFor(180000);        // three minutes covers most job starts
  let watch = $('#s5-watch');
  if (!watch) { return; }
  // CLAIM-AT-PLAN-1: a container can take longer than that to start, and the
  // engine refuses only once it runs. The page says it has not heard yet, and
  // keeps watching, so a refusal that comes later is still said here.
  if (!verdict) {
    watch.innerHTML = `<span class="spin"></span>${esc(UX.watchingSlow)}`;
    verdict = await watchFor(720000);
    watch = $('#s5-watch');
    if (!watch) { return; }
  }
  if (verdict && verdict.failure) {
    watch.textContent = startFailedText(verdict.failure.detail);
    watch.style.color = 'var(--bad)';
    return;
  }
  // RUN-GO-1: it KNOWS the wave began, so it goes to the run rather than asking
  // for one more click on "Open the run".
  if (verdict && verdict.started) { watch.textContent = UX.watchingStarted; location.href = runHref('migrations.html'); return; }
  watch.textContent = UX.watchingSlow;
}

/* PROGRESS-1: what the scan is doing, from what the engine already says.
 *
 * A spinner and nothing else cannot tell anybody whether a scan is working or
 * dead, and this page watches with no deadline - deliberately, because a scan
 * is a few Resource Graph queries whatever the estate holds, so a long wait
 * means something is WRONG rather than big. The honest answer to a long wait
 * is to show what is happening, and the engine already writes it into the run
 * log this page can read:
 *
 *   assessment start  - the scope
 *   assessment info   - discovered N VMs, with the count in a FIELD
 *   assessment warn   - something it could not read, and carried on
 *   assessment fail   - it stopped, with the reason
 *   assessment ok     - finished (the poll moves the wizard on)
 *
 * A WARNING IS NOT SHOWN HERE. The engine emits one: it could not read the
 * accelerated-networking state, so the report will not mention it rather than
 * guess. That matters - it is a gap in the REPORT - but a person watching a
 * spinner wants to know the scan is alive, and a paragraph of engine wording
 * under it reads as a fault when nothing is wrong. Report completeness belongs
 * where the report is read, not in a progress line. Recorded as its own item.
 *
 * PURE, so every combination is run in tests/js/scan-progress.test.js rather
 * than reasoned about. The newest count wins, and a failure beats everything,
 * because once a scan has stopped nothing else on screen is true any more.
 */
function scanProgress(events) {
  let found = null, failed = null;
  for (const e of (events ?? [])) {
    if (!e) { continue; }
    const s = String(e.step);
    // SCAN-FAIL-SHOWN-1: Back, then Start looking, starts the scan again in
    // the same run, and the log keeps what the first scan wrote. So the
    // service's start line of a scan (written before the page polls) begins
    // again: only what came after it counts.
    if (s === 'engine' && e.outcome === 'start' && (e.operation === 'assess' || /^hosted assess\b/.test(String(e.detail ?? '')))) { found = null; failed = null; continue; }
    // SCAN-FAIL-SHOWN-1: an error the scan does not catch is written by the
    // engine entrypoint under engine:assess, and a job that stopped with no
    // line at all gets the same line from the service's five-minute pass
    // (Invoke-VmfFacadeEndSilentScan). Its version line (info) is no answer.
    if (s === 'engine:assess') { if (e.outcome === 'fail' || e.outcome === 'refused') { failed = e; } continue; }
    if (s !== 'assessment') { continue; }
    if (e.outcome === 'fail') { failed = e; }
    else if (e.outcome === 'info' && typeof e.discovered === 'number') { found = e; }
  }
  if (failed) { return { kind: 'failed', detail: String(failed.detail ?? '') }; }
  if (found) { return { kind: 'found', count: found.discovered }; }
  return null;
}

/* SCAN-FAIL-SHOWN-1: what the wait shows once the scan has stopped - why, what
 * to do, and Back to the scope step, where Start looking starts the scan again
 * in the same run (scanProgress then reads only the lines after that start).
 * The reason is a sentence the engine or the service wrote, so it is escaped,
 * and put in with a function, so a "$&" in it is shown as written. */
function scanStoppedHtml(detail) {
  return `<p id="scan-stopped" style="color:var(--bad)">${esc(UX.scanFailed.replace('{reason}', () => String(detail ?? '')))}</p>`
    + `<p>${esc(UX.scanAgain)}</p>`
    + `<div class="nav"><button class="btn ghost" id="scan-back">${esc(UX.back)}</button></div>`;
}

/* SCAN-FAIL-SHOWN-1 review: the wait of the findings step, from the state -
 * the spinner while the scan runs, the stopped view once it stopped. Used by
 * renderStep2 and by paintScanProgress, so a redraw keeps what the page knows. */
function scanWaitHtml(stopped) {
  if (stopped === null || stopped === undefined) {
    return `<div class="working" id="wait"><span class="spin"></span>${esc(UX.s2Working)}</div>`;
  }
  return `<div id="wait">${scanStoppedHtml(stopped)}</div>`;
}
function wireScanBack() {
  $('#scan-back')?.addEventListener('click', () => { goStep(STEP.assess.scope); });
}

// Paint what scanProgress decided. Reads the run log, which the watch is
// already entitled to read; one blob a tick, and one more for each part the
// log has rolled into (EVENTLOG-1).
async function paintScanProgress() {
  const w = $('#wait');
  if (!w) { return; }
  let events = [];
  try {
    events = await VmfHelp.readLogEvents(blobText, `${runPrefix()}/logs/events.jsonl`);
  } catch (e) {
    // WATCH-1's rule, and it applies here too: one bad read is not an answer.
    // The log is written while it is being read, so a half-written line and a
    // slow blob both look like failures and neither is one.
    return;
  }
  const p = scanProgress(events);
  if (!p) { return; }
  if (p.kind === 'failed') {
    // SCAN-FAIL-SHOWN-1: why, what to do, and Back. Escaped markup
    // (scanStoppedHtml): this carries a message the ENGINE or the service wrote.
    // Kept as state (scanStopped), so a later render() of the step keeps it.
    scanStopped = p.detail;
    w.outerHTML = scanWaitHtml(scanStopped);
    wireScanBack();
    // Nothing more is coming. Asking every six seconds for ever would be
    // pretending otherwise.
    if (poll) { clearInterval(poll); poll = null; }
    return;
  }
  w.innerHTML = `<span class="spin"></span>${esc(UX.scanFound.replace('{n}', String(p.count)))}`;
}

// While the engine works, the page watches the run itself rather than guessing.
function startPolling() {
  if (poll) clearInterval(poll);
  pollBusy = false;
  poll = setInterval(async () => {
    // POLL-1: skip this tick rather than run it alongside the last one. The
    // clearInterval above stops a second INTERVAL; it cannot stop two ticks of
    // the same interval overlapping, because the callback is async and
    // setInterval never awaits it.
    //
    // NO DEADLINE HERE, for two reasons.
    //
    // WATCH-1 keeps the one loop that owns deadlines in help.js, so a page
    // must not grow its own - a test refuses any page that works out its own
    // expiry from the clock, because the subtle rules live in that loop and
    // were triplicated once already.
    //
    // And a scan does not get slower per machine: it is a few Resource Graph
    // queries whatever the estate holds, and a thousand machines is assessed
    // in minutes (docs/manual/technical/scale.md). So a long wait does not
    // mean a big estate, it means something is WRONG - and the answer to that
    // is to show what the engine is reporting, not to stop looking. The engine
    // already writes it: assessment start, "discovered N VMs", then ok or
    // fail with a reason.
    if (pollBusy) { return; }
    pollBusy = true;
    try {
      await readRun();
      // PROGRESS-1: only while the scan is the thing being waited for. Once
      // the assessment has landed the wizard moves on, and the plan step has
      // no progress to show - the engine writes one event for a plan, at the
      // end of it.
      if (!assessment) { await paintScanProgress(); }
      // WIZARD-BACK-TARGETS-1: never off a step the person chose (pollStep).
      const s = pollStep(step, deriveStep(), stepChosen);
      if (s !== step) { step = s; render(); }
      // The scan lands while the FINDINGS step is waiting for it.
      // WIZARD-WAVES-STEP-1: on the ASSESS journey only. A step is a number,
      // and findings is 3 - the number of "how to group them" when migrating.
      // The engine copies assessment.json into the migration before it writes
      // the plan, so this redrew the grouping form and stopped the watch
      // while the plan was being written, and the page stayed on that form.
      // WIZARD-POLL-STOP-1: the landed scan ENDS the wait, wherever the line
      // above left the page. This asked for the findings step, which the step
      // rule had already moved to the review, so the poll ran on for as long
      // as the tab stayed open. Only the findings step is drawn again here: a
      // step the person chose with Back (the scope) keeps what they typed.
      if (journey === 'assess' && assessment) {
        if (step === STEP.assess.findings) { render(); }
        clearInterval(poll); poll = null;
      }
      // ADVISOR-1: the target options land while their step is waiting. Drawn
      // once and the polling stops, so nothing redraws under a person's choices.
      if (targetAdvice && step === STEP.migrate.targets && !$('#t-save') && !$('#t-save-why')) { render(); clearInterval(poll); poll = null; }
      // MACHINE-PICK-1: the machines step waits for the same options.
      else if (targetAdvice && step === STEP.migrate.choose && !$('#m-continue') && !$('#m-continue-why')) { render(); clearInterval(poll); poll = null; }
      else if (!targetAdvice && (step === STEP.migrate.targets || step === STEP.migrate.choose)) { await paintAdviceProgress(); }
      // The plan lands while "how to group them" is waiting; move to the waves.
      // This said step 3 -> 4, which in the migrate journey is capacity -> run:
      // it would have jumped a person past both the waves AND the capacity step
      // the moment their plan appeared.
      // BACKLOOP-1: unless the person ASKED for this step. Without the guard,
      // the next poll after arriving by Back moved them straight on again.
      // WIZARD-POLL-STOP-1: and the landed plan ENDS the wait, wherever the
      // step rule left the page - the waves, Run it, or "already under way".
      // The stop asked for grouping, which the step rule had already moved
      // on, so the poll ran on. Nothing after grouping waits on this poll:
      // Run it watches its own start (watchForRefusal).
      if (plan && (plan.entries ?? []).length) {
        if (step === STEP.migrate.group && !wantsGroupStep() && !stepChosen) { step = STEP.migrate.waves; render(); }
        clearInterval(poll); poll = null;
      }
    } catch { /* keep waiting */ }
    finally { pollBusy = false; }
  }, 6000);
}

/* The readers this page hands the help menu, for the support bundle.
 * PAGE-LOAD-3: runDocs reads the run's documents in ONE call (store/docs with
 * the run as the prefix), as the Migrations page does; the bundle answers from
 * it and asks the readers below only what it cannot say. ?demo has no
 * service, so it has no runDocs. */
function helpAdapter() {
  return { getMsal: () => msalApp,
    getRunId: () => runFullId() || null,
    readJson: (run, rel) => blobJson(`${run}/${rel}`),
    listFolder: async (run, folder) => (await blobList(`${run}/${folder}/`)).map(n => n.slice(run.length + 1)),
    readLines: async () => [],   // this page has no text reader; the log comes from the run page
    runDocs: DEMO_MODE ? undefined
      : (run, read) => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${run}/`, depth: 2, read }),
  };
}
async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  // Guarded: a missing shared file must cost the help option, not the page.
  if (window.VmfHelp) VmfHelp.install(helpAdapter());
  VmfHelp.identity(account, DEMO_MODE ? UX.demoViewer : null);
  if (DEMO_MODE) { canOperate = true; canApprove = true; scopes = DEMO_SCOPES; }
  else {
    try {
      const tok = await getToken([`api://${cfg.apiAppId}/access_as_user`]);
      const roles = JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).roles ?? [];
      canOperate = roles.includes('Vmf.Operator') || roles.includes('Vmf.Admin');
      // PLANRUN-1: signing the plan off is an approver's act, as a wave approval was.
      canApprove = roles.includes('Vmf.Approver') || roles.includes('Vmf.Admin');
    } catch { canOperate = false; }
    api('GET', 'scopes')
      // MACHINE-PICK-1: the machines step names each subscription once the names arrive.
      // A person typing a name keeps the box: then only the rows are drawn again.
      .then(d => { scopes = d; if (awaitingScopes) render(); else if (journey === 'migrate' && step === STEP.migrate.choose) { if (document.activeElement?.id === 'm-find') paintChooseList(); else render(); } })
      .catch(() => { scopes = { subscriptions: [], managementGroups: [] }; if (awaitingScopes) render(); });
  }
  // LOADING-LINE-1: the page is on screen, and says what it reads, BEFORE
  // the run is read - the reads take seconds, and an empty page reads as
  // broken. render() writes the step over the line.
  if (runId) {
    $('#step').innerHTML = VmfHelp.waitingLine(UX.runReading);
    $('#app').style.display = 'block';
  }
  await readRun();
  journey = deriveJourney();
  step = deriveStep();
  $('#app').style.display = 'block';
  render();
  // On reload: if the findings step is up with nothing to show yet, the scan is
  // still running. This said step 2 - the SCOPE step - so a reload mid-scan
  // never resumed polling and the wizard sat there for ever.
  if (step === STEP.assess.findings && !assessment) startPolling();
}

async function boot() {
  // PAGE-WAIT-1: the two files this page starts from are fetched together.
  const configRead = DEMO_MODE ? null : fetch('dashboard.config.json').then(r => r.json());
  configRead?.catch(() => { });   // awaited below, where its failure is reported
  await loadReasons();
  if (DEMO_MODE) { $('#demo-tag').style.display = 'inline-block'; runId = runId ?? 'demo-run'; await start(); return; }
  if (typeof msal === 'undefined') throw new Error('msal-browser.min.js failed to load - redeploy the dashboard.');
  cfg = VmfHelp.checkedConfig(await configRead);
  msalApp = new msal.PublicClientApplication({
    auth: { clientId: cfg.clientId, authority: `https://login.microsoftonline.com/${cfg.tenantId}`, redirectUri: location.origin + location.pathname },
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
      /* POPUP-3: leaves for the directory; nothing follows. */
      try { await VmfHelp.signInRedirect(msalApp, [`api://${cfg.apiAppId}/access_as_user`]); } catch (e) { fail(e); }

    });
  }
}

// ---------- bundled sample ----------
/* MANUAL-SHOTS-1: ?demo has no service, so every call answers with nothing.
 * The resource groups of a subscription are the one answer the scope step
 * draws from, so the sample gives some, in the shape the service gives. */
function demoApi(method, path) {
  if (method === 'GET' && /^scopes\?subscriptionId=/.test(String(path))) {
    // The service gives the name as the id (Get-VmfFacadeResourceGroupList).
    return { resourceGroups: ['rg-apps', 'rg-billing', 'rg-legacy', 'rg-web']
      .map(name => ({ id: name, name, location: 'eastus2' })) };
  }
  // TEMP-DISK-PREVIEW-1: the preview feature, as the service reads it. The
  // sample has it not registered; ?demo&previewon has it registered, so the
  // manual can show both.
  if (method === 'GET' && /^preview-feature\?subscriptionId=/.test(String(path))) {
    const sub = decodeURIComponent(String(path).split('=')[1] ?? '');
    const on = new URLSearchParams(location.search).has('previewon');
    const name = (DEMO_SCOPES.subscriptions.find(s => s.id === sub) ?? {}).name ?? sub;
    return { subscriptionId: sub, subscriptionName: name, namespace: 'Microsoft.Compute', feature: 'VMTempDiskResizePreview',
      read: true, registered: on, state: on ? 'Registered' : 'NotRegistered' };
  }
  // CLAIM-AT-PLAN-1: the run summary's held machines. ?demo&held has web-07
  // held by an earlier migration, so the manual can show the mark.
  if (method === 'GET' && /^runs\/[^/?]+\/summary$/.test(String(path))) {
    const held = new URLSearchParams(location.search).has('held')
      ? [{ vmId: '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/web-07',
          name: 'web-07', heldBy: 'demo-earlier-migration' }]
      : [];
    return { runId: runId, held };
  }
  return {};
}
const DEMO_SCOPES = { subscriptions: [{ id: '00000000-0000-0000-0000-000000000001', name: 'Production' }, { id: '00000000-0000-0000-0000-000000000000', name: 'Applications' }, { id: '11111111-2222-3333-4444-555555555555', name: 'Web' }],
                      managementGroups: [{ id: 'mg-root', name: 'Tenant Root Group' }] };
const DEMO = {
  'demo-run/run.json': { runId: 'demo-run' },
  'demo-run/assessment.json': { vms: [
    { name: 'web-a', resourceGroup: 'rg-web', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme'], tags: { service: 'storefront' } },
    // A Windows machine with a system-assigned identity (REBUILD-REMOVE-PLAN-1: no identity finding now).
    { name: 'ebs-a', resourceGroup: 'rg-apps', sourceSize: 'Standard_D2ds_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['stornvme', 'pagefile'], tags: { service: 'storefront' },
      identityType: 'SystemAssigned', identityPrincipalId: '11111111-2222-3333-4444-555555555555' },
    { name: 'db-a', resourceGroup: 'rg-apps', sourceSize: 'Standard_D2s_v4', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: ['linux-nvme-prep'], tags: { service: 'billing' } },
    { name: 'old-a', resourceGroup: 'rg-legacy', sourceSize: 'Standard_D2_v3', classification: 'Blocked', blockers: ['gen1-requires-redeploy'], prepNeeded: [], tags: {} },
  ]},
  // ADVISOR-1: a reviewed assessment waiting for its targets - open
  // wizard.html?demo&run=demo-scan&plan=1. The options are the engine's own
  // output for these machines.
  'demo-scan/run.json': { runId: 'demo-scan', kind: 'assessment' },
  'demo-scan/approval.json': { assessmentId: 'demo-scan' },
  'demo-scan/assessment.json': { vms: [{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01","name":"app-01","resourceGroup":"rg-app","sourceSize":"Standard_D2ds_v4","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"storefront","env":"prod"},"gen":"V2"},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/db-01","name":"db-01","resourceGroup":"rg-app","sourceSize":"Standard_D2s_v4","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"billing","env":"prod"},"gen":"V2"},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/legacy-01","name":"legacy-01","resourceGroup":"rg-app","sourceSize":"Standard_D2s_v4","classification":"Blocked","blockers":["gen1-requires-redeploy","image-cannot-boot-nvme"],"prepNeeded":[],"tags":{"app":"billing","env":"test"},"gen":"V1"},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/legacy-02","name":"legacy-02","resourceGroup":"rg-app","sourceSize":"Standard_DS2_v2","classification":"Blocked","blockers":["gen1-requires-redeploy"],"prepNeeded":[],"tags":{"app":"billing","env":"test"},"gen":"V1"},{"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/web-07","name":"web-07","resourceGroup":"rg-web","sourceSize":"Standard_D2s_v3","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"storefront","env":"test"},"gen":"V2"},{"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/old-03","name":"old-03","resourceGroup":"rg-web","sourceSize":"Standard_D2s_v3","classification":"Blocked","blockers":["gen1-requires-redeploy","windows-version-below-2019","windows-version-not-proven"],"prepNeeded":[],"tags":{},"gen":"V1"}] },
  'demo-scan/target-advice.json': {"schemaVersion":34,"assessmentId":"demo-scan","assessmentHash":null,"generatedUtc":"2026-09-26T18:00:00Z","regions":[{"location":"eastus2","read":true}],"machines":[{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01","name":"app-01","os":"Linux","osVersion":"22_04-lts-gen2","gen":"V2","location":"eastus2","sourceSize":"Standard_D2ds_v4","diskController":"SCSI","osDiskType":"Standard_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"identityType":"None","acceleratedNicCount":1,"linuxRelease":{"distroId":"ubuntu","version":"22.04","source":"image","mana":"listed","manaUpgrade":null},"eusImage":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null}],"start":{"current":"v6","extended":"v5"}},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/db-01","name":"db-01","os":"Linux","osVersion":"8_10","gen":"V2","location":"eastus2","sourceSize":"Standard_D2s_v4","diskController":"SCSI","osDiskType":"Premium_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"identityType":"None","acceleratedNicCount":0,"linuxRelease":{"distroId":"rhel","version":"8.10","source":"image","mana":"unlisted","manaUpgrade":null},"eusImage":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null}],"start":{"current":"v6","extended":"v5"}},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/legacy-01","name":"legacy-01","os":"Windows","osVersion":"2019-Datacenter","gen":"V1","location":"eastus2","sourceSize":"Standard_D2s_v4","diskController":null,"osDiskType":"Standard_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"identityType":"None","acceleratedNicCount":1,"linuxRelease":null,"eusImage":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D2s_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","burstableEnds":false,"burstableKept":false,"prep":[]},{"size":"Standard_E2s_v5","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","burstableEnds":false,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null},{"option":"v7","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null}],"start":{"current":"v5","extended":"v5"}},{"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/legacy-02","name":"legacy-02","os":"Linux","osVersion":"8_10","gen":"V1","location":"eastus2","sourceSize":"Standard_DS2_v2","diskController":null,"osDiskType":"StandardSSD_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"identityType":"None","acceleratedNicCount":1,"linuxRelease":{"distroId":"rhel","version":"8.10","source":"image","mana":"unlisted","manaUpgrade":null},"eusImage":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":1,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"sizeChoices":[{"size":"Standard_D2s_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","burstableEnds":false,"burstableKept":false,"prep":[]},{"size":"Standard_E2s_v5","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","burstableEnds":false,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null},{"option":"v7","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null}],"start":{"current":"v5","extended":"v5"}},{"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/web-07","name":"web-07","os":"Windows","osVersion":"2022-datacenter-g2","gen":"V2","location":"eastus2","sourceSize":"Standard_D2s_v3","diskController":"SCSI","osDiskType":"Premium_LRS","sourceStage":{"stage":"End of Life","basis":"stated"},"identityType":"SystemAssigned","acceleratedNicCount":1,"linuxRelease":null,"eusImage":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D2ds_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":[]},{"size":"Standard_D2s_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":true,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":["pagefile"]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":true,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D2ds_v6","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":[]},{"size":"Standard_D2s_v6","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":true,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":true,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D2ds_v7","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":[]},{"size":"Standard_D2s_v7","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":true,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":false,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null}],"start":{"current":"v6","extended":"v5"}},{"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/old-03","name":"old-03","os":"Windows","osVersion":"2012-R2-Datacenter","gen":"V1","location":"eastus2","sourceSize":"Standard_D2s_v3","diskController":null,"osDiskType":"Standard_LRS","sourceStage":{"stage":"End of Life","basis":"stated"},"identityType":"None","acceleratedNicCount":1,"linuxRelease":null,"eusImage":null,"options":[{"option":"v5","supported":false,"notSupported":["windows-version-not-proven"],"targetSize":"Standard_D2s_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["windows-version-not-proven"],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":1,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null},{"option":"v6","supported":false,"notSupported":["gen1-requires-redeploy","windows-version-below-2019"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy","windows-version-below-2019"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null},{"option":"v7","supported":false,"notSupported":["gen1-requires-redeploy","windows-version-below-2019"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy","windows-version-below-2019"],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null}],"start":{"current":null,"extended":null}}]},
  'demo-run/plan.json': { entries: [
    { vmId: '/vm/web-a', wave: 'first-five', path: 'A', policy: { requireApproval: false } },
    { vmId: '/vm/db-a', wave: 'first-five', path: 'A', policy: { requireApproval: false } },
  ]},
};
// REVIEW-PAGE-1: the same scan, not yet reviewed - so ?demo&run=demo-review
// opens on the review step.
DEMO['demo-review/run.json'] = { runId: 'demo-review', kind: 'assessment' };
// DETECT-PATTERNS-1: the workload type of each sample machine, and the facts
// behind it. db-01 runs SQL Server: a warning, and it can still move.
for (const v of DEMO['demo-scan/assessment.json'].vms) {
  Object.assign(v, v.name === 'db-01'
    ? { workload: { type: 'cluster-or-database', evidence: [{ field: 'Microsoft.SqlVirtualMachine/sqlVirtualMachines', value: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/db-01' }] }, warnings: ['sql-server-agree-downtime'] }
    : { workload: { type: 'standalone-vm', evidence: [] }, warnings: [] });
}
// ALREADY-CURRENT-1: a machine already on a size in the Current lifecycle
// stage. It is in the group Current on every step, and cannot be chosen.
DEMO['demo-scan/assessment.json'].vms.push({ vmId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-05',
  name: 'app-05', resourceGroup: 'rg-app', sourceSize: 'Standard_D2ds_v6', sourceLifecycle: { stage: 'Current', basis: 'stated' },
  classification: 'ReadyAfterPrep', diskController: 'NVMe', blockers: [], prepNeeded: [], tags: { app: 'storefront', env: 'prod' }, gen: 'V2',
  workload: { type: 'standalone-vm', evidence: [] }, warnings: [] });
DEMO['demo-review/assessment.json'] = DEMO['demo-scan/assessment.json'];
// MACHINE-PICK-1: the same scan with its machines chosen, so
// ?demo&run=demo-chosen&plan=1 opens on the targets step.
DEMO['demo-chosen/run.json'] = { runId: 'demo-chosen', kind: 'assessment' };
DEMO['demo-chosen/approval.json'] = DEMO['demo-scan/approval.json'];
// ADVISE-AN-1: and three Ubuntu 18.04 machines with accelerated networking on.
// api-03 (Intel D2s_v4, the VM agent reports 18.04) has no start: a person
// chooses between the processor and accelerated networking. api-a04 (AMD
// D2as_v4, the same) starts on AMD v5, which keeps both. api-05 (Intel, only its
// image says 18.04) stays on v6, marked: start the machine, then assess again.
// api-g1 (Generation 1 Intel, the agent reports 18.04) has one target, the AMD
// size, and still needs a choice: the processor maker never changes alone.
// Made by Get-VmfTargetAdvice.
// TEMPDISK-UX-1: and two B v1 machines, a Windows B2s and a Linux B2ms, each on
// Bsv2 - which has no temporary disk - so the step shows the tag, the dot and
// the notice. Made from the machine of the engine's own sample
// (target-advice.sample.json). Only this sample has them: the other steps keep
// the pictures they give.
DEMO['demo-chosen/assessment.json'] = { vms: [...DEMO['demo-scan/assessment.json'].vms,
  {"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/web-b01","name":"web-b01","resourceGroup":"rg-web","sourceSize":"Standard_B2s","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"storefront","env":"test"},"gen":"V2"},
  {"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/app-b02","name":"app-b02","resourceGroup":"rg-web","sourceSize":"Standard_B2ms","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"tools","env":"test"},"gen":"V2"},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-03","name":"api-03","resourceGroup":"rg-app","sourceSize":"Standard_D2s_v4","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"api","env":"prod"},"gen":"V2"},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-a04","name":"api-a04","resourceGroup":"rg-app","sourceSize":"Standard_D2as_v4","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"api","env":"prod"},"gen":"V2"},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-05","name":"api-05","resourceGroup":"rg-app","sourceSize":"Standard_D2s_v4","classification":"ReadyAfterPrep","blockers":[],"prepNeeded":[],"tags":{"app":"api","env":"test"},"gen":"V2"},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-g1","name":"api-g1","resourceGroup":"rg-app","sourceSize":"Standard_DS2_v2","classification":"Blocked","blockers":["gen1-requires-redeploy"],"prepNeeded":[],"tags":{"app":"api","env":"prod"},"gen":"V1"}] };
DEMO['demo-chosen/target-advice.json'] = { ...DEMO['demo-scan/target-advice.json'], machines: [...DEMO['demo-scan/target-advice.json'].machines,
  {"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/web-b01","name":"web-b01","os":"Windows","osVersion":"2022-datacenter-g2","gen":"V2","location":"eastus2","sourceSize":"Standard_B2s","diskController":"SCSI","osDiskType":"Premium_LRS","sourceStage":{"stage":"End of Life","basis":"stated"},"acceleratedNicCount":0,"linuxRelease":null,"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_B2ls_v2","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":["pagefile"],"move":"scsi-resize","preview":true,"tempDisksFrom":1,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"derived"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_B2ls_v2","family":"Bsv2","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":4,"best":true,"path":"A","preview":true,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"derived"},"stageChange":"up","burstableEnds":false,"burstableKept":true,"prep":["pagefile"]},{"size":"Standard_D2lds_v5","family":"Dl","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":4,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v5","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":true,"burstableTarget":"offered"},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2lds_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":true,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"sizeChoices":[{"size":"Standard_D2lds_v6","family":"Dl","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":4,"best":true,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v6","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v6","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":true,"burstableKept":false,"burstableTarget":null},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2lds_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":true,"tempDisksFrom":1,"tempDisksTo":1,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D2lds_v7","family":"Dl","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":4,"best":true,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v7","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v7","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":true,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":true,"burstableKept":false,"burstableTarget":null}],"start":{"current":"v5","extended":"v5"}},
  {"vmId":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-web/providers/Microsoft.Compute/virtualMachines/app-b02","name":"app-b02","os":"Linux","osVersion":"22_04-lts-gen2","gen":"V2","location":"eastus2","sourceSize":"Standard_B2ms","diskController":"SCSI","osDiskType":"StandardSSD_LRS","sourceStage":{"stage":"End of Life","basis":"stated"},"acceleratedNicCount":0,"linuxRelease":{"distroId":"ubuntu","version":"22.04","source":"image","mana":"listed","manaUpgrade":null},"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_B2s_v2","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"scsi-resize","preview":false,"tempDisksFrom":1,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"derived"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_B2s_v2","family":"Bsv2","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":0,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"derived"},"stageChange":"up","burstableEnds":false,"burstableKept":true,"prep":[]},{"size":"Standard_D4lds_v5","family":"Dl","variant":"default","vcpus":4,"activeVcpus":4,"memoryGB":8,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v5","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v5","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":1,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":false,"burstableKept":true,"burstableTarget":"offered"},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"sizeChoices":[{"size":"Standard_D4lds_v6","family":"Dl","variant":"default","vcpus":4,"activeVcpus":4,"memoryGB":8,"best":false,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v6","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v6","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":true,"keptOn":null,"keptOnWhy":null},"stops":["acceleratedNetworkingRequired"],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":true,"burstableKept":false,"burstableTarget":null},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2ds_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":[],"move":"nvme-conversion","preview":false,"tempDisksFrom":1,"tempDisksTo":null,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[{"size":"Standard_D4lds_v7","family":"Dl","variant":"default","vcpus":4,"activeVcpus":4,"memoryGB":8,"best":false,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_D2ds_v7","family":"D","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":8,"best":true,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]},{"size":"Standard_E2ds_v7","family":"E","variant":"default","vcpus":2,"activeVcpus":2,"memoryGB":16,"best":false,"path":"A","preview":false,"tempDisksTo":null,"sizeUnverified":false,"acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"premiumDisks":true,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","burstableEnds":true,"burstableKept":false,"prep":[]}],"premiumDisks":true,"burstableEnds":true,"burstableKept":false,"burstableTarget":null}],"start":{"current":"v5","extended":"v5"}},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-03","name":"api-03","os":"Linux","osVersion":"18.04-LTS","gen":"V2","location":"eastus2","sourceSize":"Standard_D2s_v4","processor":"Intel","diskController":"SCSI","osDiskType":"Standard_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"acceleratedNicCount":1,"linuxRelease":{"distroId":"ubuntu","version":"18.04","source":"agent","mana":"unlisted","manaUpgrade":{"distroId":"ubuntu","version":"22.04"}},"options":[{"option":"v5","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["mana-kernel-floor"],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null},{"option":"v6","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null},{"option":"v7","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null}],"start":{"current":null,"extended":null}},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-a04","name":"api-a04","os":"Linux","osVersion":"18.04-LTS","gen":"V2","location":"eastus2","sourceSize":"Standard_D2as_v4","processor":"AMD","diskController":"SCSI","osDiskType":"Premium_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"acceleratedNicCount":1,"linuxRelease":{"distroId":"ubuntu","version":"18.04","source":"agent","mana":"unlisted","manaUpgrade":{"distroId":"ubuntu","version":"22.04"}},"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2as_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":["mana-kernel-floor"],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":false,"mayUseMana":false,"turnsOn":false,"keptOn":true,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null,"processorChange":false,"processor":"AMD"},{"option":"v6","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null},{"option":"v7","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null}],"start":{"current":"v5","extended":"v5"}},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-05","name":"api-05","os":"Linux","osVersion":"18.04-LTS","gen":"V2","location":"eastus2","sourceSize":"Standard_D2s_v4","processor":"Intel","diskController":"SCSI","osDiskType":"Premium_LRS","sourceStage":{"stage":"Extended","basis":"stated"},"acceleratedNicCount":1,"linuxRelease":{"distroId":"ubuntu","version":"18.04","source":"image","mana":"unlisted","manaUpgrade":null},"options":[{"option":"v5","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v5","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":["mana-kernel-floor"],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Extended","basis":"stated"},"stageChange":"same","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null,"processorChange":false,"processor":"Intel"},{"option":"v6","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v6","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":true,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null,"processorChange":false,"processor":"Intel"},{"option":"v7","supported":true,"notSupported":[],"targetSize":"Standard_D2s_v7","sizeUnverified":false,"sizesNotTaken":[],"path":"A","blockers":[],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":0,"targetStage":{"stage":"Current","basis":"stated"},"stageChange":"up","acceleratedNetworking":{"required":false,"mayUseMana":true,"turnsOn":false,"keptOn":null,"keptOnWhy":"image-unlisted"},"stops":[],"sizeChoices":[],"premiumDisks":true,"burstableEnds":false,"burstableKept":false,"burstableTarget":null,"processorChange":false,"processor":"Intel"}],"start":{"current":"v6","extended":"v5"}},
  {"vmId":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/api-g1","name":"api-g1","os":"Linux","osVersion":"18.04-LTS","gen":"V1","location":"eastus2","sourceSize":"Standard_DS2_v2","processor":"Intel","diskController":"SCSI","osDiskType":"Standard_LRS","sourceStage":{"stage":"End of Life","basis":"stated"},"acceleratedNicCount":1,"linuxRelease":{"distroId":"ubuntu","version":"18.04","source":"agent","mana":"unlisted","manaUpgrade":{"distroId":"ubuntu","version":"22.04"}},"options":[{"option":"v5","supported":false,"notSupported":["no-mana-driver"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":[],"prep":["mana-kernel-floor"],"move":"scsi-resize","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null},{"option":"v6","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null},{"option":"v7","supported":false,"notSupported":["gen1-requires-redeploy"],"targetSize":null,"sizeUnverified":false,"sizesNotTaken":[],"path":"MANUAL","blockers":["gen1-requires-redeploy"],"prep":["linux-nvme-prep","mana-kernel-floor"],"move":"nvme-conversion","preview":false,"tempDisksFrom":0,"tempDisksTo":null,"targetStage":null,"stageChange":"unknown","acceleratedNetworking":{"required":null,"mayUseMana":null,"turnsOn":null,"keptOn":null,"keptOnWhy":null},"stops":[],"sizeChoices":[],"premiumDisks":null,"burstableEnds":null,"burstableKept":null,"burstableTarget":null,"processorChange":null,"processor":null}],"start":{"current":null,"extended":null}}] };
DEMO['demo-chosen/machine-choices.json'] = { machines: DEMO['demo-chosen/target-advice.json'].machines
  .filter(m => m.options.some(o => o.supported)).map(m => m.vmId) };
// MANUAL-SHOTS-1: the same scan with its targets saved too, so
// ?demo&run=demo-grouped&plan=1 opens on How to group them. The targets were
// saved for this list of machines, which is what the step checks.
DEMO['demo-grouped/run.json'] = { runId: 'demo-grouped', kind: 'assessment' };
DEMO['demo-grouped/approval.json'] = DEMO['demo-scan/approval.json'];
DEMO['demo-grouped/assessment.json'] = DEMO['demo-scan/assessment.json'];
DEMO['demo-grouped/target-advice.json'] = DEMO['demo-scan/target-advice.json'];
DEMO['demo-grouped/machine-choices.json'] = { machines: DEMO['demo-scan/target-advice.json'].machines
  .filter(m => m.options.some(o => o.supported)).map(m => m.vmId) };
DEMO['demo-grouped/target-choices.json'] = { machinesVersion: 'demo', machines: [] };
// MANUAL-SHOTS-1: a planned migration of two waves, the first one accepted, so
// ?demo&run=demo-plan&step=run opens on the Run it step. One machine moves to a
// v5 size that requires accelerated networking, one takes the in-place upgrade
// (Preview), and one loses its temporary disk. WAVE-AN-NAMES-1: the Preview
// machine gets accelerated networking turned on too, and the move decides it
// for one Linux machine. REBUILD-REMOVE-ACCEPT-1: no machine is rebuilt.
// SQL-TEMPDB-SIGNOFF-1: the scan found SQL Server on report-01, which moves from
// a SCSI temporary disk to an NVMe one, so Run it asks for the box.
{
  const vm = (n) => `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing/providers/Microsoft.Compute/virtualMachines/${n}`;
  const pol = (extra) => ({ requireApproval: true, capacityGate: 'BestEffort', onDDataFound: 'stop', onDriverBelowFloor: 'stop',
    keepSnapshotDays: 7, throttle: 5, ...extra });
  const row = (n, wave, path, os, from, to, gen, extra = {}) => ({ vmId: vm(n), wave, path,
    assessment: { os, sourceSize: from, sourceTempDisks: extra.fromTemp ?? 0, ...(extra.sql ? { sqlServerDetected: true, sourceDiskArch: 'scsi-temp' } : {}) },
    // REBUILD-REMOVE-PLAN-1: the method the targets step saved (preview: the in-place upgrade (Preview)).
    target: { size: to, tempDisks: extra.toTemp ?? 0, ...(extra.method ? { choice: { method: extra.method } } : {}), ...(extra.sql ? { diskArch: 'nvme-temp' } : {}) }, policy: pol({ targetGeneration: gen, ...(extra.an ? { acceleratedNetworking: 'ensureOn' } : {}),
      // WIZARD-OPTIONS-DISKS-1: a disk type change, named at Run it.
      ...(extra.disks ? { diskUpgrade: extra.disks } : {}) }),
    // WAVE-AN-NAMES-1: the record the engine writes - turned on, not, or decided by the move.
    acceleratedNetworkingOutcome: extra.anOut ?? { turnsOn: Boolean(extra.an), unknownWhy: null } });
  DEMO['demo-plan/run.json'] = { runId: 'demo-plan', kind: 'migration' };
  DEMO['demo-plan/plan.json'] = { entries: [
    row('web-01', 'web-pilot', 'A', 'Linux', 'Standard_D2s_v4', 'Standard_D2s_v6', 'v6'),
    row('web-02', 'web-pilot', 'A', 'Linux', 'Standard_D2s_v4', 'Standard_D2s_v6', 'v6'),
    row('web-03', 'web-pilot', 'A', 'Linux', 'Standard_D2ds_v4', 'Standard_D2s_v6', 'v6', { fromTemp: 1, toTemp: 0 }),
    row('web-04', 'web-report-db', 'A', 'Linux', 'Standard_D2s_v4', 'Standard_D2s_v6', 'v6', { anOut: { turnsOn: null, unknownWhy: 'kernel' } }),
    row('report-01', 'web-report-db', 'A', 'Windows', 'Standard_D4ds_v4', 'Standard_D4ds_v6', 'v6', { fromTemp: 1, toTemp: 1, method: 'preview', sql: true, anOut: { turnsOn: true, unknownWhy: null } }),
    row('db-01', 'web-report-db', 'A', 'Windows', 'Standard_D4s_v4', 'Standard_D4s_v5', 'v5', { an: true, disks: 'os' }),
  ] };
  DEMO['demo-plan/acceptances/web-pilot.json'] = { wave: 'web-pilot', acceptedBy: 'operator@example.com' };
}

boot().catch(fail);
