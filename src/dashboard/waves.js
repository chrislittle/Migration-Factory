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
   Plain language, same bar as every other page. */
const UX = {
  demoViewer: 'Sample viewer',
  title: 'Arrange the waves',
  howto: 'Waves decide what moves together and in what order. Tick the machines you want on the left, then choose "Add selected machines" on a wave - or drag them across. Nothing changes until you save.',
  poolEmpty: 'Every machine is in a wave.',
  addWave: 'Add a wave',
  reset: 'Start over',
  arrivedToEdit: 'These are the settings for {wave}. Change what you need, then save the plan.',
  resetConfirm: 'Undo your changes and use the saved plan again?',
  resetYes:    'Yes, discard my changes',
  reserveYes:  'Reserve',
  reserveNoteHint: 'Say why you reserve this capacity.',
  cancel:      'Cancel',
  // CLOSE-NOT-CANCEL-1: an open (?) that only shows information closes with Close.
  close:       'Close',
  resetDone: 'Your changes were undone. This is the saved plan again.',
  resetNothing: 'Nothing to undo - this already matches the saved plan.',
  save: 'Save the plan',
  saving: 'Saving the plan...',
  // CLICKS-LOST-1: a save took about a minute on the lab install, with only
  // the button text to show for it, and was pressed twice.
  savingWait: 'The service saves the plan, then this page reads it again. This can take up to a minute.',
  // SAVE-STUCK-1: the same shape as resetNothing one button along. It says
  // the plan is already saved, not that something failed.
  saveNothing: 'Nothing to save - the plan already matches what is on screen.',
  sendHere: 'Add selected machines',
  deleteWave: 'Delete',
  moveUp:     'Move up',
  moveDown:   'Move down',
  leversHeading: 'How this wave runs',
  waveEmpty: 'No machines yet. Tick machines on the left, then choose "Add selected machines" above.',
  waveEmptyReady: 'Ready to add - choose "Add selected machines" above, or drag them here.',
  capLabel: 'On-demand capacity reservation for this wave',
  // WAVE-WORDS-3: Azure names. The option that makes an on-demand capacity
  // reservation is called that, and the other one makes none. Pay as you go
  // is a way Azure bills, and a reserved machine is billed that way too.
  capOnDemand: 'No',
  capReserved: 'Yes',
  capTip: 'An on-demand capacity reservation holds the capacity for this wave before it starts. Azure bills it until every machine of the wave has ended and the product releases it, or until you select Release. The product makes its capacity reservation group in the resource group and subscription of the machines. A machine in an availability set cannot use an on-demand capacity reservation. A machine in its own capacity reservation group stays in that group.',
  // ODCR-BUTTON-1: the wave plan is where a reservation is asked for, so
  // this is the page that must be able to make one. It does -
  // it is the page that must be able to make one. The lever and the action
  // beside each other, rather than a choice here and a command elsewhere.
  // REACH-2. The gate's answer BEFORE anyone presses Start. The engine
  // refuses a wave whose quota is short, and a reserved wave whose
  // reservation is not held. A pay-as-you-go wave gets no capacity check
  // before it starts - only a reservation guarantees capacity
  // (QUOTA-NOT-CAPACITY-1). Asking the quota question first is the
  // difference between planning around a short quota and discovering one.
  // The endpoint existed and no screen called it.
  // WAVE-FLOW-1: QUOTA, not capacity, and they are different Azure things.
  // What this reads is quota.limit and quota.used -
  // the vCPU limit for a size family in a region. A CAPACITY RESERVATION is a
  // different Azure thing, it is a resource you create and are billed for, and
  // the reserve control below keeps that word because it is the right one.
  capCheck:         'Check the quota',
  // WAVE-QUOTA-ROW-1: its own row, because it is its own Azure thing. A vCPU
  // limit for a size family in a region is not a reservation you create and
  // are billed for.
  quotaRowLabel:    'Quota for these sizes',
  quotaRowTip:      'The permission of the subscription to deploy vCPUs of these size families in this region. A quota does not reserve or guarantee capacity. An on-demand capacity reservation does. It is the row above.',
  // QUOTA-CHECK-SPINNER-1: on a wave, beside the spinner, while the plan is checked.
  capWaveChecking:  'The product checks the quota.',
  // QUOTA-BUTTON-1: the third answer. No records is not a verdict, and it was
  // shown as "not enough", in red.
  capNotChecked:    'Not checked yet',
  // RESERVE-COVER-2: the gate could not read the plan, so it measured nothing.
  // That is not a quota that is too small, so it is not said as one.
  capNoPlan:        'The product could not read the plan of this wave. Select Check the quota again.',
  // QUOTA-CHECK-SPINNER-1: a size Azure does not offer is not a quota that is short.
  // One sentence for each size of the wave that Azure refused, then what to do, once.
  capSizeBlocked:   'The size {size} is not available to subscription {subscription} in region {region}.',
  capSizeBlockedNoSub: 'The size {size} is not available in region {region}.',
  capSizeBlockedDo: 'Select Change target on the machine. Then choose another size.',
  // QUOTA-CHECK-SPINNER-1: the table of the plan on the card, one row for each
  // quota the plan uses. The figures are the engine's (capacity-claim v15), and
  // the headings are those of the Migrations page quota card where they agree.
  capColQuota:      'Quota',
  capColRegion:     'Region',
  capColLimit:      'Limit',
  capColUsed:       'Usage',
  capColPlan:       'All waves need',
  capColShort:      'Short by',
  capRegionalName:  'Total Regional vCPUs',
  capNoFigure:      'Not listed',
  capEnough:        'Enough',
  capPlanWhy:       'All numbers are vCPUs. Each machine keeps its new size after its wave, so the check adds the vCPUs that all waves need.',
  // QUOTA-CHECK-SPINNER-1 (lab walk 2026-11-17): the state of the plan on
  // the card, and one line for each quota on each wave.
  capPlanShort:     'The quota is not enough for all waves of this plan.',
  capPlanEnough:    'The quota is enough for all waves of this plan.',
  // QUOTA-CHECK-SPINNER-1 (review): not green when a wave has no result, or a quota has no figure.
  capPlanNoResult:  'The product has no quota result for these waves: {waves}. Select Check the quota again.',
  capLineShort:     'This wave needs {n} vCPUs of {quota} in {region}. The plan is short by {s}. See Request a quota increase.',
  capLineEnough:    'This wave needs {n} vCPUs of {quota} in {region}. The quota is enough for all waves.',
  capLineUnlisted:  'This wave needs {n} vCPUs of {quota} in {region}. Azure does not list the limit of this quota.',
  capNoAnswer:      'Azure did not answer. Try again.',
  // QUOTA-TRUTH-1: the check reads the SAVED plan. Pressed with unsaved
  // changes, it checked the waves as they were and answered for those. It now
  // saves first, and says so, because inside the flow Save also moves on.
  capSavesFirst:    'Saves your wave changes first, because the quota check reads the saved plan.',
  capSavedFirst:    'Your wave changes were saved, so the quota check reads them.',
  // PAGE-WAIT-1: shown while the page reads the plan.
  readingPlan:      'Reading the plan.',
  capLast:          'Checked {when}',
  capNothing:       'No machine in this wave changes size, so no quota applies.',
  // RESERVE-COVER-1 and RESERVE-COVER-2: a wave cannot start while a machine
  // in it has no quota record, with or without a capacity reservation. The
  // answer names those machines, in place of the words about a quota that is
  // not enough.
  capUncovered:     'These machines have no quota record: {machines}. Check the quota again.',
  capUncoveredOne:  'This machine has no quota record: {machines}. Check the quota again.',
  // WAVE-TAKEOUT-1
  takeOut:          'Remove',
  takeOutTip:       'Moves this machine out of the wave, back to the machines with no wave. Its availability set moves with it.',
  // WAVE-EDIT-RUNNING-1: a running wave is shown, not offered for change.
  runningTag:       'Running',
  runningTip:       'Machines of this wave are migrating. Change the wave when they finish. Pause new work on the Migrations page stops more machines starting.',
  runningMove:      'Wave {wave} is running. Move machines into it when it has finished.',
  runningMoveOut:   'Wave {wave} is running. Move machines out of it when it has finished.',
  // WAVE-RUNNING-LEASE-1: only the hold of a stopped worker on a finished machine
  // keeps the wave locked. The service removes it at its next check.
  endedHoldTag:     'Held',
  endedHoldTip:     'A worker stopped after its machine finished, and its hold stays on the machine. The service removes the hold within about 5 minutes. Then you can change the wave.',
  endedHoldMove:    'A stopped worker still holds a machine of wave {wave}. The service removes the hold within about 5 minutes. Then you can move machines.',
  // WAVE-RUNNING-LEASE-1 review: the leases listing failed. The same sentence as on the Migrations page.
  leasesUnread:     'Could not read which machines a job holds now, so this page does not show which waves run. {reason}',
  // WAVE-EDITOR-TICK-1: a machine selected in a wave moved to another one with no word.
  movedWave:        '{name} moves from wave {from} to wave {to}. Nothing changes until you save.',
  // WAVE-MIX-2: one machine's size series, after planning.
  changeTarget:     'Change target',
  changeTargetTip:  'Changes the size series of this machine. After the change, accept and approve its wave again.',
  changeReading:    'Reading the size series.',
  changeNot:        'Not available',
  // TEMP-DISK-PREVIEW-1: the machines of a wave that take the in-place upgrade
  // with the preview feature. WAVE-NOTE-LAYOUT-1: the names go on their own
  // line after noteVms, so a name never breaks in the middle of the sentence.
  previewOne:       '1 machine in this wave takes the in-place upgrade (Preview), which needs the preview feature VMTempDiskResizePreview.',
  previewMany:      '{n} machines in this wave take the in-place upgrade (Preview), which needs the preview feature VMTempDiskResizePreview.',
  previewPill:      'Preview',
  noteVms:          'Virtual machines:',
  // REBUILD-REMOVE-PLAN-1: the same notice as the targets step, for each
  // subscription whose machines in this wave need the preview feature.
  previewOffOne:    'Subscription {sub} needs the preview feature VMTempDiskResizePreview for 1 machine in this wave. The feature is not registered there.',
  previewOffMany:   'Subscription {sub} needs the preview feature VMTempDiskResizePreview for {n} machines in this wave. The feature is not registered there.',
  previewNotRead:   'The product could not read the preview feature VMTempDiskResizePreview on subscription {sub}.',
  previewReading:   'Reading the preview feature on subscription {sub}.',
  previewThen:      'Register the feature, then select Check again. Checking stops each of these machines before any change until then.',
  previewCheck:     'Check again',
  previewAbout:     'About the preview feature',
  previewWhat:      'Azure resizes a Windows machine in place from a SCSI temporary disk to another kind of temporary disk only with this preview feature.',
  previewNotTool:   'The product does not register the feature. A user with the Contributor or Owner role on the subscription registers it.',
  previewPortal:    'In the Azure portal, open Subscriptions and select the subscription. Select Preview features, search for VMTempDiskResizePreview, select it, then select Register.',
  previewWait:      'Microsoft says that the registration can take about 10 minutes. Then select Check again.',
  changePreview:    'In-place upgrade (Preview)',
  changeApply:      'Apply',
  changeSaveFirst:  'Save your wave changes first. A target change writes to the saved plan.',
  // WAVE-APPROVE-1: an approval signs one wave, so a change asks again for the
  // wave of the machine only. A machine in no wave changes no approval.
  changeDone:       '{name} now moves to {size}. Accept and approve its wave again. The other waves keep their approvals.',
  changeDoneNoWave: '{name} now moves to {size}. The machine is not in a wave, so no approval changes.',
  changeReload:     'The target changed, but this page could not read the plan again. Load the page again.',
  changeStale:      'The plan changed after this page read it. Load the page again, then change the target.',
  // WAVE-FLOW-1: these come from the capacity step, which is gone. That step
  // was the ONLY place a person could request a quota increase, so deleting
  // it without moving this would take the action away entirely.
  // QUOTA-PREVIEW-1: Azure's own term is "request a quota increase"; the
  // English gate refuses the invented "ask Azure".
  quotaTitle:       'Request a quota increase',
  quotaBody:        'The product files a quota increase request for each quota that is too low: a size family, or the Total Regional vCPUs of a region. Azure accepts or refuses each request. The answer can come after some days.',
  quotaBtn:         'Request an increase',
  // QUOTA-NOCHECK-1: said when there is nothing to say it FROM. An all-clear
  // printed here made an unchecked plan read as a checked, healthy one.
  quotaNotChecked:  'The product did not check the quota of this plan yet. Select Check the quota.',
  // QUOTA-CHECK-SPINNER-1: said with the spinner while any wave is checked.
  quotaCardChecking: 'The product checks the quota. The result shows here when the check is complete.',
  // QUOTA-BUTTON-1: checked, and Azure gave no figure to check against.
  quotaUnlisted:    'Azure does not list the quota of some sizes of this plan. The product cannot check that quota before the wave starts.',
  // QUOTA-FILED-WORDS-1: "filed" was said when the engine job STARTED, before
  // Azure was asked. Now it is said after the engine's quotaResult line, and
  // only for the quotas Azure took; each other quota is named with its reason.
  // QUOTA-CHECK-SPINNER-1: beside the spinner, under a title that is not a question.
  quotaSending:     'The product sends the quota increase requests to Azure. This step can take up to 2 minutes. If you close the confirmation, the requests continue. The page then shows the result.',
  quotaFiled:       'The product filed the quota increase request for {quotas}. Azure accepts or refuses each request. The answer can come after some days.',
  quotaNotFiled:    'The product did not file the quota increase request for {quota} in {region}. {reason}',
  // QUOTA-REQUEST-POLL-1: on the page while the product reads the answer of Azure.
  quotaReadingPage: 'The product reads the answer of Azure to each filed request. The answer shows here.',
  quotaNoReason:    'The engine did not give a reason. The activity log shows what the engine did.',
  quotaRequestStopped: 'The engine stopped before it said which quota increase requests are filed: {reason} The activity log shows each request.',
  quotaRequestNoAnswer: 'The engine did not say in 10 minutes which quota increase requests are filed. The activity log shows each request.',
  quotaClose:       'Close',
  // QUOTA-PREVIEW-1: the confirmation Request an increase opens. It lists what
  // the engine's preview says will be requested, with Azure's column names.
  quotaConfirmTitle: 'Request a quota increase?',
  // QUOTA-CHECK-SPINNER-1: the confirmation said too little. The
  // title after Request, the reading line beside a spinner, and under each
  // quota a sentence for each wave, the vCPUs free now and the new limit.
  quotaSentTitle:   'Quota increase requests',
  quotaConfirmLine: 'The product requests these quota increases on subscription {name}. Azure accepts or refuses each request. The answer can come after some days.',
  quotaConfirmWait: 'The product reads the last quota check and calculates the new limits. This step can take up to 1 minute.',
  quotaConfirmBtn:  'Request',
  quotaWaveLine:    'Wave {wave} needs {n} vCPUs of {quota} in {region}.',
  quotaFreeLine:    '{free} vCPUs of this quota are free now.',
  quotaAskLine:     'The product requests a new limit of {limit} vCPUs.',
  // QUOTA-CHECK-SPINNER-1: after Request, one row for each request. The State
  // column is where an answer of Azure goes (quotaRequestStateText).
  quotaColState:    'State',
  quotaColId:       'Request ID',
  quotaStateFiled:  'The product filed the request. Azure did not answer yet.',
  quotaStateApproved: 'Azure accepted the request.',
  quotaStateNotFiled: 'The product did not file the request.',
  // QUOTA-REQUEST-POLL-1: the engine reads each filed request for 2 minutes
  // (Microsoft's Quota Request Status: Succeeded, Failed, Invalid, InProgress,
  // Accepted) and writes one quotaAnswer line for each. These are its answers,
  // in the words approved in a review of the states above.
  quotaStateReading: 'The product filed the request. The product reads the answer of Azure.',
  quotaStateRefused: 'Azure refused the request.',
  quotaStateRefusedCode: 'Azure refused the request, with the code {code}.',
  quotaStateNotRead: 'The product filed the request. The product could not read the answer of Azure.',
  quotaReading:     'The product reads the answer of Azure to each filed request. This step can take up to 3 minutes. If you close the confirmation, the page shows the answer.',
  quotaNextApproved: 'Azure accepted the quota increase request for {quota} in {region}. Select Check the quota on the card Request a quota increase.',
  quotaNextRefused: 'Azure refused the quota increase request for {quota} in {region}.',
  quotaNextRefusedCode: 'Azure refused the quota increase request for {quota} in {region}, with the code {code}.',
  // QUOTA-REQUEST-POLL-1: a request ID is not part of Microsoft's support
  // flow. The next step is Microsoft's own steps, from the two pages
  // the drift check watches (docs/upstream-docs.json, azure/quotas). {page} is
  // the title of the page, shown as a link to it (QUOTA_HELP).
  quotaNextSupport: 'To open an Azure support request for the increase, follow the steps in {page} from Microsoft.',
  quotaNextStepsFamily: 'On the Quotas page of the Azure portal, select Compute. Select the Information icon beside the quota, then select Create a support request.',
  quotaNextStepsRegional: 'On the Quotas page of the Azure portal, select Compute. Select the quota, then select New Quota Request. If Azure does not give the increase, the portal shows a link to open a support request.',
  quotaNextLimit:   'Ask for the new limit of {limit} vCPUs.',
  quotaHelpFamily:  'Increase VM-family vCPU quotas',
  quotaHelpRegional: 'Increase regional vCPU quotas',
  quotaNextWaiting: 'Azure did not answer the quota increase request for {quota} in {region} in 2 minutes. Look again later on the Quotas page of the Azure portal.',
  quotaNextNotRead: 'The product could not read the answer of Azure for {quota} in {region}. Look again later on the Quotas page of the Azure portal.',
  quotaNoId:        'None',
  quotaDoneNext:    'Azure accepts or refuses each filed request. The answer can come after some days. When Azure accepts a request, select Check the quota on the card Request a quota increase.',
  quotaPreviewNone: 'At the last quota check, each size family had enough quota. Nothing is requested.',
  quotaPreviewNoSub: 'Request an increase cannot ask for {families}, because the quota record does not name a subscription. Check the quota again.',
  quotaPreviewNoAnswer: 'The engine did not send the quota limits to request in 5 minutes. The activity log shows what the engine did.',
  quotaColQuota:    'Quota',
  quotaColRegion:   'Region',
  quotaColUsed:     'Usage',
  quotaColLimit:    'Current limit',
  quotaColNeed:     'The waves need',
  quotaColNew:      'New limit',
  quotaNoFigure:    'Not listed',
  // QUOTA-PREVIEW-1: the access the quota check recorded for a quota too low.
  // The role's reach is said as what the product does with it - resize and
  // rebuild - never as a power to change anything.
  quotaNoAccess:    'The product cannot request a quota increase on subscription {name}. That needs the Assess and migrate role on the subscription, which also lets the product stop and resize the machines there. Give the role on the Admin page, or request a quota increase on the Quotas page of the Azure portal.',
  quotaAccessUnknown: 'The product could not read its access on subscription {name}. The request can fail if the product does not have this access.',
  quotaAdminLink:   'Open the Admin page',
  quotaRegional:    'The Total Regional vCPUs quota is not enough in {regions}. Request an increase asks for this quota too.',
  reserveBtn:       'Reserve capacity',
  reserveBusy:      'Reserving...',
  reserveHeld:      'Reserved',
  reserveWorking:   'Reserving...',
  reserveBlocked:   'Not reserved',
  reserveWorkingTip:'Azure is creating the on-demand capacity reservation. This page shows the result when it is done.',
  reserveBlockedTip:'Azure did not make this on-demand capacity reservation. Open the wave on the Migrations page to see why.',
  // RESERVING-STUCK-1: Azure did not answer in time, or the engine stopped.
  reserveUnconfirmed:    'Not confirmed',
  reserveUnconfirmedTip: 'Azure did not confirm this on-demand capacity reservation, and it can still bill. Select Release to delete it.',
  reserveUnconfirmedSaid:'Azure did not confirm the on-demand capacity reservation for {wave}, and it can still bill. Select Release beside it.',
  reserveSaveFirst: 'Save the plan first. The product sizes the on-demand capacity reservation from the saved wave.',
  reserveStarted:   'Reserving capacity for {wave}.',
  reserveDone:      'Capacity is reserved for {wave}. Azure bills it until every machine of the wave has ended and the product releases it, or until you select Release.',
  reserveSlow:      'Reserving {wave} is still running. Open this page again to see the result.',
  reserveFailed:    'Capacity was not reserved for {wave}: ',
  reserveNothing:   'No machine in {wave} uses the on-demand capacity reservation of the wave. Azure does not allow an on-demand capacity reservation for a machine in an availability set. The move keeps a machine in its own capacity reservation group.',
  // AVSET-RESERVE-1: a wave set to Reserved whose machines are all in
  // availability sets. It needs no reservation and starts without one.
  reserveGeneral:   'No on-demand capacity reservation',
  reserveGeneralTip:'Each machine in this wave is in an availability set or in its own capacity reservation group. Azure does not allow an on-demand capacity reservation for a machine in an availability set.',
  reserveDoneGeneral:    '{n} machines in an availability set have no on-demand capacity reservation.',
  reserveDoneGeneralOne: 'One machine in an availability set has no on-demand capacity reservation.',
  // The note is required by the facade, and for a reason: this is the one
  // control on the page that spends money.
  reserveAsk:       'Reserve capacity for wave {wave}?\n\nThis creates an on-demand capacity reservation in the same resource group and subscription as the machines. Azure bills it from the moment it is reserved, whether the wave runs or not. It bills until every machine of the wave has ended and the product releases it, or until you select Release.\n\nType a short note saying why. It is recorded against the run.',
  reserveNoNote:    'A note is needed, because reserving capacity spends money.',
  // WAVE-EDIT-RESERVE-1: close-out releases a reservation after a wave runs.
  // This is for a wave that must change or will not run, and for a close-out
  // that did not release.
  releaseBtn:       'Release',
  releaseTip:       'Releases the on-demand capacity reservation of this wave. Azure stops the charge for it.',
  releaseAsk:       'Release the on-demand capacity reservation for wave {wave}?\n\nAzure stops holding the capacity and stops the charge for it. Machines of the wave that wait for a decision or a retry lose the capacity it held for them. To reserve again, check the quota on the wave, then reserve.\n\nType a short note saying why. It is recorded against the run.',
  releaseNoNote:    'A note is needed, because a release removes capacity that was reserved.',
  releaseNoteHint:  'Say why you release this capacity.',
  releaseBusy:      'Releasing...',
  releaseStarted:   'Releasing the on-demand capacity reservation for {wave}.',
  releaseDone:      'The on-demand capacity reservation for {wave} is released.',
  releaseSlow:      'Releasing {wave} is still running. Open this page again to see the result.',
  releaseFailed:    'The on-demand capacity reservation for {wave} was not released: ',
  approvalOn: 'Someone must sign off before this wave runs',
  approvalLocked: 'Only an Approver can remove the sign-off requirement from a wave. Ask an Approver to change this setting.',
  // DECIDE-2: the three stop-and-ask gates follow the same rule as the
  // sign-off - an operator may put one ON, and only an approver may take it
  // off. Continue accepts a loss for every machine in the wave.
  gateLocked: 'Only an Approver can change a gate to Continue. Continue accepts the loss for every machine in this wave.',
  dataLabel: 'If files are found on the temporary disk',
  dataStop: 'Stop and ask',
  dataProceed: 'Continue - the files are deleted',
  // WAVE-KERNEL-LINE-1: no wave has a kernel setting. The kernel choice is
  // made per machine on the targets step (KERNEL-UX-1), and the card names
  // the machines that chose Update the kernel - in the words of the same row
  // on Run it and on the acceptance of the Migrations page.
  kernelLabel: 'Machines whose kernel the product updates if it has no MANA driver',
  kernelNone: 'None in this wave',
  // REBUILD-REMOVE-ACCEPT-1: the setting for a system-assigned identity, its
  // pill and its helper are gone with the rebuild.
  keepLabel: 'How long the snapshot is kept',
  keepDays: 'days',
  // SCALE-UX-1: how many machines at once, as a lever of the wave.
  atOnceLabel: 'How many machines at once',
  atOnceTip:   'The engine works on this many machines at the same time. Each engine container works on up to 15 machines.',
  estAllAtOnce: 'This wave has only {machines} machines, so all of them run at once.',
  // LAB-UX-1: the same two sentences for a wave of one machine.
  estAllAtOnceOne: 'This wave has only 1 machine, so a larger number changes nothing.',
  // SCALE-2: will the engine's environment hold this many at once?
  capFits:     'This wave needs {n} engine containers, {cores} cores. The environment has {free} of {limit} free.',
  capFitsOne:  'This wave needs {n} engine container, {cores} cores. The environment has {free} of {limit} free.',
  // WORDS-1: engine capacity was a THIRD meaning of capacity on one page,
  // beside the quota on a machine and the capacity reservations Azure holds.
  // These are the containers this product runs its own work in, so they are
  // workers. Raise the quota is dropped as well: it meant the Container Apps
  // quota, not the virtual machine quota the rest of this page is about.
  capTooMany:  'This wave needs {cores} cores for its engine workers, and only {free} of {limit} are free. Start fewer machines at once.',
  capUnknown:  'The engine workers could not be counted: {reason}',
  // WAVE-KEEP-TIP-WORDS-1: a copy is locked only when the identity may place
  // locks (the safetyCopyMissing stop reason says it the same way), and the
  // setting covers both copies of a machine, not only the first.
  keepTip: 'This setting covers both safety copies of each machine: the snapshot before migration and the snapshot just before the resize. The product locks each copy when it takes it, if its identity has the right to place locks. The daily cleanup deletes both copies, and the copies of its data disks, this many days after the machine is migrated.',
  lockedTip: 'This machine has already started migrating, so it cannot be moved',
  lockedTag: 'under way',
  avsetTag: 'moves with its pair',
  avsetTip: 'This machine shares an availability set. Machines in one availability set always travel in the same wave.',
  continueSetup: 'Continue - review how this wave runs',
  // WAVE-FLOW-1: inside the flow this page is a step, so it has the flow's
  // one pair of buttons. "Save the plan" is the product's own words for this
  // action and is already the button here - the flow does not get a softer
  // second name for the same thing, it just also continues.
  back:          'Back',
  savedOk: 'Saved. The plan now matches what you arranged here.',
  savedAcceptCleared: 'The settings for {waves} must be accepted again before those waves can run.',
  savedCapacityCleared: 'The quota check for {waves} was cleared - it described the waves as they were, and the quota is checked again before a wave starts.',
  /* WAVE-APPROVE-1: an approval signs its own wave, so only the waves this
   * save changed lose theirs, and the line names them. */
  savedApprovals: 'Saved. These waves changed, so each needs an approval again before it can run: {waves}.',
  // WAVE-LEVER-OVERRIDE-1: a machine can hold its own value for a setting, and
  // a change on the card does not replace it. The card says how many, and the
  // open ? names each machine with its value and the cause (WAVE-OWN-PICTURE-1).
  ownHelpTip:  'Show the machines that do not follow this setting',
  savedKept:   'Some machines do not follow a setting that you changed. The activity of the migration names each machine.',
  // WAVE-LEVER-RESET-1: a button beside each machine in the open ? helper.
  ownReset:        'Use the wave\'s setting',
  ownResetPending: '{name} uses the wave\'s setting when you save.',
  ownResetLocked:  'Only an approver can give this machine the value Continue.',
  savedReset:      'These machines now use the setting of their wave: {names}.',
  noPlan: 'This run has no plan yet. Build a plan first, then arrange its waves.',
  notAllowedCopy: 'Arranging waves needs operator access. Ask an administrator if you need it.',
  newWaveName: 'new-wave',
  nameChanged: 'A wave name becomes a file name, so it can hold only letters, numbers, dots, dashes and underscores. "{typed}" is saved as "{used}".',
  nameReserved: 'The product uses the name "{typed}" for the machines that are not in a wave. Use a different name.',
  saveNoPlan: 'This page could not read the plan again. Load the page again, then save the waves.',
  filterTitle: 'Find machines to add',
  filterAll: 'Everything',
  filterUnassigned: 'Only machines not in a wave yet',
  byRg: 'In resource group',
  byTag: 'With tag',
  anyRg: 'Any resource group',
  anyTag: 'Any tag',
  anyValue: 'Any value',
  searchPlaceholder: 'Find by name...',
  selectAll: 'Select all shown',
  clearSel: 'Clear selection',
  selectedCount: 'selected',
  // WAVE-EDITOR-TICK-1: a selected machine this list does not show.
  selectedHidden: 'Also selected, not in this list: {names}',
  // The count pills were bare numbers that never said what they counted.
  // A number with
  // no noun is a number the reader has to guess at - and this page already
  // says "2 shown - 0 selected" three inches away.
  machine: 'machine',
  machines: 'machines',
  showingCount: 'shown',
};
/* ============================= UX-STRINGS-END ============================= */

let cfg = null, msalApp = null, account = null, runId = null;
// RUNID-2: this page had NO concept of a project, so every path it built was
// `run/...` - and a run inside a project lives at `project/run/...`. It could
// not read one at all, and the 404 that followed was shown as "the migration
// records could not be found at the configured address", which sent a person
// looking at their storage account for a path missing one segment.
let projectId = null;
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
// PROJECT-2: a GET has no body, so the project travels in the query. The
// service reads it from either.
function runQuery(join) {
  const project = VmfHelp.VmfRun.parse(runFullId()).project;
  return project ? `${join}project=${encodeURIComponent(project)}` : '';
}
function runHref(page, extra) {
  return VmfHelp.VmfRun.link(page, runFullId(), extra);
}
// APPR-LEVER-1: canEdit arranges the waves; canSignOff is a DIFFERENT role.
// The facade refuses a layout that takes the sign-off requirement off a wave
// unless the caller is an Approver, so the page must not offer that.
let entries = [], states = new Map(), layout = new Map(), original = '', canEdit = false, canSignOff = false;
// WAVE-RUNNING-LEASE-1: the run's leases by machine, read with the machines.
let leases = new Map();
let selection = new Set();

async function getToken(scopes) {
  /* TOKEN-SCOPE-1: the store reads call this with no scope. MSAL v2 gave the
     service's token anyway; v5 gives a sign-in token, and the service answers
     401 to it. The service scope is the only one this page asks for. */
  const req = { scopes: scopes || [`api://${cfg.apiAppId}/access_as_user`], account };
  /* POPUP-3: silently, or by leaving for the directory and coming back. The
     second path does not return - the browser navigates away. */
  return VmfHelp.tokenOrRedirect(msalApp, req);
}
async function blobFetch(path, { asText = false } = {}) {
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, path, { asText });
}
async function blobList(prefix) {
  /* STORE-READ-1: through the facade, not blob storage. A browser cannot be
   * admitted by a network security perimeter - it is not in a subscription. */
  return (await VmfHelp.storeList(() => getToken(), cfg.apiUrl, prefix)).names;
}
/* WAVE-RUNNING-LEASE-1: the run's leases, by machine (VmfHelp.leasesByMachine).
 * A held lease keeps a wave running, here as in the engine. ONE call
 * (PAGE-LOAD-1, storeDocs): the leases folder and each lease in it. What the
 * call cannot say - it failed, or a lease is not in what came back - is read
 * as before: a listing, then each lease (unknown means ask). A lease its job
 * removed after the listing is gone.
 * PAGE-LOAD-3: `held`, when given, is the load's one call for the whole run
 * (readMigration), and this asks for nothing it holds. */
async function readLeases(held) {
  const prefix = `${runPrefix()}/leases/`;
  if (held === undefined) {
    try { held = await VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix, depth: 1, read: ['*.lease'] }); }
    catch { held = null; }
  }
  const listed = VmfHelp.heldList(held, prefix);
  // A listing that fails is NOT KNOWN, never "no leases": the page stops with
  // these words, as the Migrations page does, and offers no wave as free.
  let all;
  try { all = listed ? listed.names : await blobList(prefix); }
  catch (e) { throw new Error(UX.leasesUnread.replace('{reason}', VmfHelp.explain(e))); }
  const names = all.filter(n => n.endsWith('.lease'));
  const docs = await VmfHelp.mapLimited(names, async (n) => {
    const known = VmfHelp.heldJson(held, n);
    if (known) { return known.value; }
    try { return await blobFetch(n); } catch { return null; }
  });
  return VmfHelp.leasesByMachine(docs);
}
/* PAGE-LOAD-3: a document from the load's one call, or read by itself when
 * the call cannot say (VmfHelp.heldJson: unknown means ask). */
async function heldOrFetch(held, path) {
  const known = VmfHelp.heldJson(held, path);
  return known ? known.value : blobFetch(path);
}
/* PAGE-LOAD-3: what the wave editor reads of the migration in ONE call
 * (store/docs, the run as the prefix). It read each machine record, each
 * quota record and each lease one call each - about N + 6 calls a load. No
 * plan: the plan is read with the version the service issued for it, which
 * a save quotes back (PLANVER-2, readPlan). */
const RUN_READS = ['assessment.json', 'state/*.json', 'capacity/*.json', 'leases/*.lease'];
/* The plan, the machine records, the assessment and the leases, with the
 * quota records loaded (loadClaims). A call that fails leaves `held` null,
 * and each reader reads as before. */
async function readMigration() {
  const runHeld = (async () => {
    try { return await VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${runPrefix()}/`, depth: 2, read: RUN_READS }); }
    catch { return null; }
  })();
  const stateRead = (async () => {
    const held = await runHeld;
    const prefix = `${runPrefix()}/state/`;
    const listed = VmfHelp.heldList(held, prefix);
    const names = listed ? listed.names : await blobList(prefix);
    // STORE-READ-2: one state document per machine in the run, paced.
    return (await VmfHelp.mapLimited(names.filter(n => n.endsWith('.json')), n => heldOrFetch(held, n))).filter(Boolean);
  })();
  // VMID-CASE-1: the assessment names the machines that have no state
  // document yet. Without it, a name is cut from the ID.
  const assessRead = (async () => heldOrFetch(await runHeld, `${runPrefix()}/assessment.json`))().catch(() => null);
  // WAVE-RUNNING-LEASE-1: the leases beside the machines.
  const [plan, stateDocs, , assessment, leasesRead] = await Promise.all([readPlan(), stateRead,
    runHeld.then(held => loadClaims(held)), assessRead, runHeld.then(held => readLeases(held))]);
  return { plan, stateDocs, assessment, leases: leasesRead };
}
/* REACH-2: the GET twin of apiPost. Same token, same timeout, same error
 * shape - a second way to spell those would be a second place to keep them
 * right. The demo stages a plausible answer so the control is not dead there. */
async function apiGet(path) {
  if (DEMO_MODE) {
    await new Promise(r => setTimeout(r, 400));
    // REBUILD-REMOVE-PLAN-1: the preview feature, not registered in the sample.
    if (/^preview-feature\?subscriptionId=/.test(path)) {
      return { read: true, registered: false, state: 'NotRegistered', subscriptionName: '' };
    }
    if (/^engine\/capacity\?/.test(path)) {
      // SCALE-2: the sample environment - 100 cores, 12 in use by a wave
      // that is running. Above 15 the containers multiply.
      const n = Math.max(1, Number(path.split('atOnce=')[1]) || 1);
      const containers = Math.ceil(n / 15);
      const cores = Array.from({ length: containers }, (_, i) => {
        const share = Math.ceil((n - i) / containers);
        return share <= 3 ? 1 : share <= 7 ? 2 : 4;
      }).reduce((a, b) => a + b, 0);
      return { workers: n, containers, coresNeeded: cores, coresInUse: 12, coresLimit: 100, coresFree: 88, fits: cores <= 88 };
    }
    return { Pass: true, Gate: 'BestEffort', Claims: 3,
             Detail: 'all 3 claims satisfy BestEffort (QUOTA_VERIFIED/RESERVED/CONSUMED)' };
  }
  const token = await getToken([`api://${cfg.apiAppId}/access_as_user`]);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 45000);
  try {
    const r = await fetch(`${cfg.apiUrl}/${path}`, {
      method: 'GET', signal: ctl.signal,
      headers: { Authorization: `Bearer ${token}` },
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
    return data;
  } finally { clearTimeout(timer); }
}

async function apiPost(path, body) {
  if (DEMO_MODE) { await new Promise(r => setTimeout(r, 400)); return { ApprovalsInvalidated: [] }; }
  const token = await getToken([`api://${cfg.apiAppId}/access_as_user`]);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 45000);
  try {
    const r = await fetch(`${cfg.apiUrl}/${path}`, {
      method: 'POST', signal: ctl.signal,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error ?? `HTTP ${r.status}`);
    return data;
  } finally { clearTimeout(timer); }
}

// ---------- model ----------
// WAVES-BUTTON-RUNNING-1: the started states live in help.js, so the
// Migrations page asks the same rule before it offers this editor.
const started = (vmId) => VmfHelp.machineStarted(states.get(vmId));

/* RENDER-1: look up, do not scan.
 *
 * avsetOf was `entries.find(...)`, called once per rendered row, and
 * membersOf checked `vmIds.includes(...)` once per entry per wave. render()
 * is bound to the search box's `input` event, so both ran on EVERY KEYSTROKE,
 * and both grow with the plan - which comes from the store, so it is the size
 * of the customer's fleet.
 *
 * The index is rebuilt where `entries` is assigned, and nowhere else: an index
 * that can be older than the thing it indexes is worse than the scan it
 * replaced. setEntries is the only way in.
 */
let entryById = new Map();
// WAVE-ORDER-1: the plan's own order of its waves, set with its entries.
let planWaveOrder = [];
function setEntries(list, order) {
  entries = list;
  entryById = new Map(entries.map(e => [e.vmId, e]));
  planWaveOrder = order ?? [];
}
// VMID-CASE-1: in one letter case - two members can record one set in two.
const avsetOf = (vmId) => VmfHelp.idKey(entryById.get(vmId)?.assessment?.availabilitySetId);
function waveNames() { return [...layout.keys()]; }
/** WAVE-ORDER-1: the layout with one wave moved one place up (-1) or down (1). */
function moveWave(map, name, delta) {
  const keys = [...map.keys()];
  const i = keys.indexOf(name), j = i + delta;
  if (i < 0 || j < 0 || j >= keys.length) return map;
  [keys[i], keys[j]] = [keys[j], keys[i]];
  return new Map(keys.map(k => [k, map.get(k)]));
}
function membersOf(name) {
  const ids = layout.get(name)?.vmIds;
  if (!ids || !ids.length) { return []; }
  // A Set for the membership test, but still walked in ENTRIES order - the
  // rows are displayed in plan order, and taking them in vmIds order instead
  // would quietly reshuffle every wave on screen.
  const want = new Set(ids);
  return entries.filter(e => want.has(e.vmId));
}
function unassigned() { const all = new Set([...layout.values()].flatMap(w => w.vmIds)); return entries.filter(e => !all.has(e.vmId)); }
function snapshot() {
  // WAVE-LEVER-RESET-1: a reset not saved is a change, so Save writes it.
  return JSON.stringify([...layout.entries()].map(([n, w]) => [n, w.capacityGate, w.requireApproval, w.onDDataFound, w.keepSnapshotDays, w.throttle, [...w.vmIds].sort(),
    Object.entries(resetOf(w)).sort(([a], [b]) => a.localeCompare(b)).map(([f, ids]) => [f, [...ids].sort()])]));
}

/* WAVE-LEVER-OVERRIDE-1: what a wave card shows, and which machines do not
 * follow a setting of their wave. ACCEPT-FIRST-MACHINE-1: the rule is in
 * help.js, so the acceptance on the Migrations page and the Run it step show
 * the same values and the same machines as this card. tests/fixtures/
 * wave-own-settings.json holds it and the service (Get-VmfWaveSettingWrites)
 * to one set of cases. */
const WAVE_DEFAULTS = VmfHelp.waveSettingDefaults();
/* Three settings belong to the WAVE: the engine reads one value for the whole
 * wave. Their card shows that reading, every machine follows it, and a change
 * is written to every machine. */
const WAVE_WIDE = VmfHelp.waveWideSettings();
const { leverValue, ownDecision, keepsOwn, waveCard } = VmfHelp;/** The machines of a wave on screen that keep their own value for a setting. */
function ownOf(name, w, field) {
  return membersOf(name).filter(e => keepsOwn(e, field, w.drawn?.[field], e.wave === name));
}
/* The card says how many machines do not follow a setting - a fact, in one
 * short line - and the ? helper names each one with its value and the cause
 * (screens show options, not narration). The helper is one button with two states, ? and
 * Close, and Escape closes it too (rule 11). CLOSE-NOT-CANCEL-1: while it
 * holds a reset not saved, closing it cancels that reset, so it says Cancel. */
const ownHelp = new Set();
function ownHint(name, w, field) {
  const own = ownOf(name, w, field);
  if (!own.length) return '';
  const key = `${name}|${field}`;
  const open = ownHelp.has(key);
  // ACCEPT-FIRST-MACHINE-1: in the words of help.js, which the acceptance shows too.
  const said = VmfHelp.ownCountText(own.length);
  // WAVE-LEVER-RESET-1: a Reset beside each machine, only where the person
  // can change the wave and the wave is not running (the engine refuses it).
  const resettable = canEdit && !waveMigrating(name);
  const shut = (w?.reset?.[field] ?? []).length ? UX.cancel : UX.close;
  return `<span class="hint" data-own="${esc(key)}">${esc(said)} <button type="button" class="btn small ghost" data-ownhelp="${esc(key)}"
      aria-expanded="${open}" aria-label="${esc(open ? shut : UX.ownHelpTip)}" title="${esc(open ? shut : UX.ownHelpTip)}">${open ? esc(shut) : '?'}</button></span>${open
    ? own.map(e => ownRow(name, w, field, e, resettable)).join('') : ''}`;
}

/* WAVE-LEVER-RESET-1: give a machine back the value of its wave.
 *
 * A machine keeps its own value for a setting against every change of its
 * wave's card (WAVE-LEVER-OVERRIDE-1), and the only way back was to plan it
 * again. The open ? helper now lists each such machine with a Reset beside it.
 * Reset becomes Cancel (one button, two states); the helper's own Cancel and
 * Escape cancel every reset not saved (rule 11). A reset is sent with the next
 * save (`reset`: setting -> machines), through the same service call as any
 * change: the plan version this page read, the refusal for a running wave,
 * the role checks on what is written, and the wave loses its acceptance. */
function resetPending(w, field, vmId) { return (w?.reset?.[field] ?? []).includes(vmId); }
function toggleReset(name, field, vmId) {
  const w = layout.get(name);
  if (!w) return;
  w.reset = w.reset ?? {};
  const ids = new Set(w.reset[field] ?? []);
  if (ids.has(vmId)) ids.delete(vmId); else ids.add(vmId);
  if (ids.size) w.reset[field] = [...ids]; else delete w.reset[field];
}
/** Cancel the resets not saved: of one helper (wave|setting), or of every wave. */
function clearResets(key) {
  const cut = key ? key.lastIndexOf('|') : -1;
  for (const [name, w] of layout) {
    if (!w.reset) continue;
    if (!key) { w.reset = {}; continue; }
    if (key.slice(0, cut) === name) delete w.reset[key.slice(cut + 1)];
  }
}
/** What a save sends: the machines still in the wave, never a setting of the wave. */
function resetOf(w) {
  const out = {};
  for (const [field, ids] of Object.entries(w?.reset ?? {})) {
    if (WAVE_WIDE.includes(field)) continue;
    const kept = (ids ?? []).filter(id => (w.vmIds ?? []).includes(id));
    if (kept.length) out[field] = kept;
  }
  return out;
}
/** DECIDE-2: a reset to Continue accepts a loss, as a change on the card does. */
function resetLocked(w, e, field) {
  const gates = ['onDDataFound'];
  return !canSignOff && gates.includes(field) && String(w[field]) === 'proceed' && leverValue(e, field) !== 'proceed';
}
/* One machine that does not follow a setting, in the open helper: its value,
 * and the cause where the plan records one (WAVE-OWN-PICTURE-1) - in the
 * words of help.js ownRowText, which the acceptance on the Migrations page
 * and the Run it step show too (ACCEPT-FIRST-MACHINE-1). A reset not saved
 * says what the save does instead. */
function ownRow(name, w, field, e, resettable) {
  const key = `${name}|${field}`;
  const pending = resetPending(w, field, e.vmId);
  const said = pending ? UX.ownResetPending.replace('{name}', () => vmName(e.vmId)) : VmfHelp.ownRowText(field, e, vmName);
  if (!resettable) return `<span class="hint" data-ownrow>${esc(said)}</span>`;
  const locked = !pending && resetLocked(w, e, field);
  return `<span class="hint" data-ownrow>${esc(said)} <button type="button" class="btn small ghost" data-ownreset="${esc(key)}" data-resetvm="${esc(e.vmId)}"
      aria-pressed="${pending}"${locked ? ` title="${esc(UX.ownResetLocked)}" disabled` : ''}>${esc(pending ? UX.cancel : UX.ownReset)}</button>${locked
    ? ` <span class="hint">${esc(UX.ownResetLocked)}</span>` : ''}</span>`;
}/** The ? helper opens and closes; closing it cancels its resets not saved. */
function toggleOwnHelp(key) {
  if (ownHelp.has(key)) { ownHelp.delete(key); clearResets(key); } else ownHelp.add(key);
  render();
}
/* WAVE-KERNEL-LINE-1: the machines of a wave that update their kernel when it
 * has no MANA driver, on one row of the card. Each chose it on the targets
 * step, so the row shows and changes nothing: no wave has a kernel setting. */
function kernelRow(name) {
  const names = membersOf(name).filter(e => e?.policy?.onDriverBelowFloor === 'updateKernel').map(e => vmName(e.vmId));
  return `<div class="kernelrow"><span class="lv">${esc(UX.kernelLabel)}</span><span class="keep">${esc(names.join(', ') || UX.kernelNone)}</span></div>`;
}
/** Escape closes what is open: the size series panel, or a ? helper. */
function onEscape(ev) {
  if (ev.key !== 'Escape') return;
  if (change.vmId) { closeChange(); return; }
  // WAVE-LEVER-RESET-1: a reset lives in an open helper, so it goes with it.
  // REBUILD-REMOVE-PLAN-1: and the ? helper of a preview notice.
  const pv = typeof wPreviewHelp === 'undefined' ? null : wPreviewHelp;
  if (ownHelp.size || pv?.size) { if (ownHelp.size) clearResets(); ownHelp.clear(); pv?.clear(); render(); }
}
/** The settings changed on a card since it was drawn, each with the value it showed. */
function changedOf(w) {
  const out = {};
  if (!w.drawn) return out;   // a new wave: every machine joins it and takes its card
  for (const field of Object.keys(WAVE_DEFAULTS)) {
    if (String(w[field]) !== String(w.drawn[field])) out[field] = w.drawn[field];
  }
  return out;
}

function buildLayoutFromPlan() {
  layout = new Map();
  // WAVE-ORDER-1: the waves in the plan's order, so the editor shows the order
  // that runs, and saving sends it back.
  const orderedEntries = [...entries];
  const rank = VmfHelp.waveOrder({ entries, waveOrder: planWaveOrder });
  orderedEntries.sort((a, b) => rank.indexOf(a.wave) - rank.indexOf(b.wave));
  for (const e of orderedEntries) {
    const name = e.wave;
    if (!name || name === 'unscheduled') continue;
    if (!layout.has(name)) layout.set(name, { vmIds: [] });
    layout.get(name).vmIds.push(e.vmId);
  }
  // WAVE-LEVER-OVERRIDE-1: each card from all its machines, and what it showed
  // kept beside it (drawn) - a save sends only what differs from that.
  for (const [name, w] of layout) {
    const { values } = waveCard(membersOf(name));
    Object.assign(w, values, { drawn: { ...values } });
  }
  original = snapshot();
}
// Moving one availability-set member moves them all.
function expand(vmIds) {
  const out = new Set(vmIds);
  for (const id of vmIds) {
    const av = avsetOf(id);
    if (!av) continue;
    entries.filter(e => avsetOf(e.vmId) === av).forEach(e => out.add(e.vmId));
  }
  return [...out];
}
// The wave a machine is in on this page now - unsaved changes included.
function layoutWaveOf(vmId) {
  for (const [name, w] of layout) { if (w.vmIds.includes(vmId)) return name; }
  return null;
}
function moveTo(waveName, vmIds) {
  // WAVE-EDITOR-TICK-1: a line says only what THIS move did.
  $('#moved').textContent = ''; $('#moved').style.display = 'none';
  // WAVE-EDIT-RUNNING-1: nothing moves into or out of a running wave. Its
  // workers would never take a machine added, nor leave the plan as it was.
  // WAVE-RUNNING-LEASE-1: a wave held only by a stopped worker's hold says
  // that the service removes the hold.
  if (waveName && waveMigrating(waveName)) {
    $('#warnbar').textContent = (waveHoldOf(waveName) === 'endedHold' ? UX.endedHoldMove : UX.runningMove).replace('{wave}', waveName);
    $('#warnbar').style.display = 'block';
    return;
  }
  const savedWave = new Map(entries.map(e => [e.vmId, e.wave]));
  const asked = expand(vmIds);
  const heldBy = asked.map(id => savedWave.get(id)).find(w => w && waveMigrating(w));
  const ids = asked.filter(id => !started(id) && !waveMigrating(savedWave.get(id)));
  if (heldBy) {
    $('#warnbar').textContent = (waveHoldOf(heldBy) === 'endedHold' ? UX.endedHoldMove : UX.runningMoveOut).replace('{wave}', heldBy);
    $('#warnbar').style.display = 'block';
  }
  /* WAVE-EDITOR-TICK-1: a machine can be selected where the list does not
   * show it - a row in a wave card selects on a click. Moving it to another
   * wave is allowed, and the page says so: in the lab it moved with no word. */
  const from = new Map(ids.map(id => [id, layoutWaveOf(id)]));
  const moved = waveName ? ids.filter(id => from.get(id) && from.get(id) !== waveName) : [];
  for (const w of layout.values()) w.vmIds = w.vmIds.filter(id => !ids.includes(id));
  if (waveName) layout.get(waveName).vmIds.push(...ids);
  if (moved.length) {
    $('#moved').textContent = moved.map(id => UX.movedWave.replace('{name}', vmName(id))
      .replace('{from}', from.get(id)).replace('{to}', waveName)).join(' ');
    $('#moved').style.display = 'block';
  }
  selection.clear();
  render();
}

// ---------- filters: add machines by tag, by resource group, or by picking ----------
const filter = { search: '', scope: 'unassigned', rg: '', tagKey: '', tagVal: '' };
const tagsOf = (e) => e.assessment?.tags ?? {};
const tagValue = (e, key) => {
  const t = tagsOf(e);
  const k = Object.keys(t).find(x => x.toLowerCase() === String(key).toLowerCase());
  return k ? String(t[k]) : '';
};
const rgOf = (e) => e.assessment?.resourceGroup ?? '';
function allTagKeys() {
  const s = new Set();
  entries.forEach(e => Object.keys(tagsOf(e)).forEach(k => s.add(k)));
  return [...s].sort();
}
function tagValuesFor(key) {
  const s = new Set();
  entries.forEach(e => { const v = tagValue(e, key); if (v) s.add(v); });
  return [...s].sort();
}
function shownMachines() {
  const assigned = new Set([...layout.values()].flatMap(w => w.vmIds));
  return entries.filter(e => {
    if (filter.scope === 'unassigned' && assigned.has(e.vmId)) return false;
    if (filter.search && !vmName(e.vmId).toLowerCase().includes(filter.search)) return false;
    if (filter.rg && rgOf(e) !== filter.rg) return false;
    if (filter.tagKey) {
      const v = tagValue(e, filter.tagKey);
      if (!v) return false;
      if (filter.tagVal && v !== filter.tagVal) return false;
    }
    return true;
  });
}
function renderFilters() {
  const opt = (v, label, sel) => `<option value="${esc(v)}"${sel === v ? ' selected' : ''}>${esc(label)}</option>`;
  $('#f-search').placeholder = UX.searchPlaceholder;
  $('#f-scope').innerHTML = opt('unassigned', UX.filterUnassigned, filter.scope) + opt('all', UX.filterAll, filter.scope);
  const rgs = [...new Set(entries.map(rgOf).filter(Boolean))].sort();
  $('#f-rg').innerHTML = opt('', UX.anyRg, filter.rg) + rgs.map(r => opt(r, `${UX.byRg}: ${r}`, filter.rg)).join('');
  const keys = allTagKeys();
  $('#f-tagkey').innerHTML = opt('', UX.anyTag, filter.tagKey) + keys.map(k => opt(k, `${UX.byTag}: ${k}`, filter.tagKey)).join('');
  const vals = filter.tagKey ? tagValuesFor(filter.tagKey) : [];
  $('#f-tagval').innerHTML = opt('', UX.anyValue, filter.tagVal) + vals.map(v => opt(v, v, filter.tagVal)).join('');
  $('#f-tagval').disabled = !filter.tagKey;
  $('#f-all').textContent = UX.selectAll;
  $('#f-none').textContent = UX.clearSel;
  $('#f-count').textContent = selectionCount();
}
/* WAVE-EDITOR-TICK-1: the count says what this list shows. The lab read
 * "3 shown · 4 selected": the fourth was in a wave, and Add selected moved it.
 * A selected machine the list does not show is named, not counted. */
function selectionCount() {
  const shown = new Set(shownMachines().map(e => e.vmId));
  const picked = [...selection];
  const hidden = picked.filter(id => !shown.has(id)).map(id => vmName(id));
  const count = `${shown.size} ${UX.showingCount} · ${picked.length - hidden.length} ${UX.selectedCount}`;
  return hidden.length ? `${count} · ${UX.selectedHidden.replace('{names}', hidden.join(', '))}` : count;
}
// LEAK-1: the unassigned pool is a drop target for the whole life of the page.
// It is the one element in the editor that render() does NOT replace - render()
// rewrites its innerHTML, so the machine rows inside it are new every time but
// the container is the same node from first paint to last. Wiring it from
// wireRows() therefore ADDED a handler on every render and removed none.
//
// The growth was not only memory. The DOM copies an element's listener list
// before dispatch, so one drop onto the pool ran moveTo once per accumulated
// handler - and each of those called render(), which wired another. The count
// DOUBLED with every drop, and each call re-rendered the whole editor. A few
// drags into the pool during one planning session was enough to make the
// screen stop responding, with unsaved wave changes in it.
//
// Called once from start(), like every other listener on a static element.
function wirePoolDropTarget() {
  const poolEl = $('#pool');
  poolEl.addEventListener('dragover', (e) => e.preventDefault());
  poolEl.addEventListener('drop', (e) => { e.preventDefault(); moveTo(null, [...selection]); });
}

function wireFilters() {
  $('#f-search').addEventListener('input', (e) => { filter.search = e.target.value.trim().toLowerCase(); render(); });
  $('#f-scope').addEventListener('change', (e) => { filter.scope = e.target.value; render(); });
  $('#f-rg').addEventListener('change', (e) => { filter.rg = e.target.value; render(); });
  $('#f-tagkey').addEventListener('change', (e) => { filter.tagKey = e.target.value; filter.tagVal = ''; render(); });
  $('#f-tagval').addEventListener('change', (e) => { filter.tagVal = e.target.value; render(); });
  $('#f-all').addEventListener('click', () => {
    shownMachines().filter(e => !started(e.vmId)).forEach(e => selection.add(e.vmId));
    render();
  });
  $('#f-none').addEventListener('click', () => { selection.clear(); render(); });
}

// SCALE-2: will the engine's environment hold this many at once? Asked of
// the facade (which reads the environment live) for each wave on render and
// again as the number is typed; debounced so typing 40 does not ask four
// times. The answer is one sentence beside the estimate, and the start or
// the schedule refuses with the same numbers when it does not fit.
const capacityAsk = new Map();
function showEngineCapacity(name, n) {
  const out = document.querySelector(`[data-caphint="${CSS.escape(name)}"]`);
  if (!out) return;
  const w = layout.get(name);
  const machines = w ? w.vmIds.length : 0;
  const workers = Math.max(1, Math.min(Number(n) || 1, machines || 1));
  clearTimeout(capacityAsk.get(name));
  capacityAsk.set(name, setTimeout(async () => {
    try {
      const c = await apiGet(`engine/capacity?atOnce=${workers}`);
      // MANUAL-REVIEW-1: one container or several, never container(s).
      const words = c.fits ? VmfHelp.countWords(c.containers, [UX.capFitsOne, UX.capFits]) : UX.capTooMany;
      out.textContent = words.replace('{containers}', c.containers).replace('{cores}', c.coresNeeded)
        .replace('{free}', c.coresFree).replace('{limit}', c.coresLimit);
      out.classList.toggle('bad', !c.fits);
    }
    catch (e) { out.textContent = UX.capUnknown.replace('{reason}', e && e.message ? e.message : String(e)); }
  }, 350));
}

// ---------- render ----------
function machineRow(e, inWave) {
  const isStarted = started(e.vmId);
  const av = avsetOf(e.vmId);
  return `<div class="m ${selection.has(e.vmId) ? 'sel' : ''}" data-vm="${esc(e.vmId)}"
      ${(canEdit && !isStarted && !waveMigrating(e.wave)) ? 'draggable="true"' : ''}>
    ${(canEdit && !isStarted && !inWave)
      ? `<input type="checkbox" class="pick" tabindex="-1" ${selection.has(e.vmId) ? 'checked' : ''} aria-label="${esc(vmName(e.vmId))}">`
      : '<span class="pick-sp"></span>'}
    <!-- ROW-SQUEEZE-1: the name and its resource group share ONE column, the
         group on the line under the name. Side by side, on the narrow list, a
         tag like "moves with its pair" left the group a sliver of width and
         it broke into one fragment per line. -->
    <span class="who"><span class="nm" title="${esc(vmName(e.vmId))}">${esc(vmName(e.vmId))}</span>
    <span class="meta" title="${esc(rgOf(e))}">${esc(rgOf(e))}${layoutWaveOf(e.vmId) && filter.scope === 'all' ? ` &middot; ${esc(layoutWaveOf(e.vmId))}` : ''}${sizeMove(e)}
      ${filter.tagKey && tagValue(e, filter.tagKey) ? ` &middot; ${esc(tagValue(e, filter.tagKey))}` : ''}</span></span>
    <span class="acts">${isStarted ? `<span class="lock" title="${esc(UX.lockedTip)}">${esc(UX.lockedTag)}</span>`
      : av ? `<span class="pill quiet" title="${esc(UX.avsetTip)}">${esc(UX.avsetTag)}</span>` : ''}
      ${(canEdit && !isStarted && !waveStarted(e.wave)) ? `<button type="button" class="btn small ghost" data-change="${esc(e.vmId)}" aria-expanded="${change.vmId === e.vmId}"
          title="${esc(UX.changeTargetTip)}">${esc(change.vmId === e.vmId ? UX.cancel : UX.changeTarget)}</button>` : ''}
      ${(canEdit && !isStarted && inWave && !waveMigrating(e.wave)) ? `<button type="button" class="btn small ghost" data-takeout="${esc(e.vmId)}" title="${esc(UX.takeOutTip)}">${esc(UX.takeOut)}</button>` : ''}</span>
  </div>${change.vmId === e.vmId && !isStarted ? changePanel(e) : ''}`;
}

/* WAVE-MIX-2: change ONE machine's size series after planning.
 *
 * The engine decides everything - which series the machine can take, the size
 * each one gives, and what the change clears. This panel shows its answer and
 * sends the choice back with the plan version this page read (PLANVER-2).
 * It opens with Change target, and Cancel or Escape closes it (rule 11). */
let planVersion = '';
const change = { vmId: null, answer: null, pick: null, busy: false, err: '' };
// The engine refuses a change once any machine in the wave has started, because
// the wave's workers hold the plan they read. The button follows the same rule.
function waveStarted(wave) {
  return !!wave && wave !== 'unscheduled' && entries.some(x => x.wave === wave && states.has(x.vmId));
}
// WAVE-EDIT-RESERVE-1: a machine of the wave has a state and is not in a final
// one - it may be using the wave's reservation right now. PLANNED counts: the
// engine writes it when a worker takes the machine (WAVE-MIX-2). The same rule
// as the engine's Get-VmfWaveReleaseRefusal, which is the guard that holds;
// this only hides the button. WAVE-RUNNING-PLANNED-1: the rule is in help.js,
// and the Migrations page asks the same one. states holds only machines with a
// state document, so a machine that waits for a slot reads as not at work.
// WAVE-RUNNING-LEASE-1: and with each machine's lease, as the engine reads it:
// a machine a worker holds before it writes PLANNED, or a hold a stopped
// worker left, keeps the wave running.
function waveMigrating(wave) {
  return waveHoldOf(wave) !== 'none';
}
/* WAVE-RUNNING-LEASE-1: the hold of a wave (VmfHelp.waveHold): 'working',
 * 'endedHold' when only a stopped worker's hold on a finished machine keeps it
 * running - the service removes that hold at its next check - or 'none'. */
function waveHoldOf(wave) {
  return VmfHelp.waveHold(entries.filter(x => x.wave === wave), (id) => states.get(id),
    (id) => leases.get(VmfHelp.idKey(id)), Date.now());
}
function changePanel(e) {
  const a = change.answer;
  if (!a) {
    return `<div class="m-change">${change.err ? `<p class="err-inline">${esc(change.err)}</p>`
      : `<p class="muted"><span class="spin"></span>${esc(UX.changeReading)}</p>`}</div>`;
  }
  const short = (s) => String(s ?? '').replace(/^Standard_/, '');
  const pick = change.pick ?? a.Current;
  // Options, not narration: the series, its size, and a tag when the move is a
  // rebuild. Why a series is not available is on the targets step's Details.
  const rows = (a.Options ?? []).map(o => `<label class="m-opt${o.supported ? '' : ' off'}">
      <input type="radio" name="m-series" value="${esc(o.option)}"${o.option === pick ? ' checked' : ''}${o.supported ? '' : ' disabled'}>
      <span class="mono">${esc(VmfHelp.seriesLabel(o.option, o.targetSize))}</span>
      <span>${o.supported ? `<span class="mono">${esc(short(o.targetSize))}</span>${o.preview ? ` <span class="pill quiet">${esc(UX.changePreview)}</span>` : ''}`
        : `<span class="muted">${esc(UX.changeNot)}</span>`}</span></label>`).join('');
  const blocked = dirty();
  const same = pick === a.Current;
  return `<div class="m-change" role="group" aria-label="${esc(UX.changeTarget)} ${esc(vmName(e.vmId))}">
    ${rows}
    ${change.err ? `<p class="err-inline">${esc(change.err)}</p>` : ''}
    <div class="m-change-nav">
      <button type="button" class="btn small ghost" data-changecancel>${esc(UX.cancel)}</button>
      <button type="button" class="btn small" data-changeapply${(blocked || same || change.busy) ? ' disabled' : ''}
        ${blocked ? `title="${esc(UX.changeSaveFirst)}"` : ''}>${esc(UX.changeApply)}</button>
    </div></div>`;
}
function closeChange() { Object.assign(change, { vmId: null, answer: null, pick: null, busy: false, err: '' }); render(); }
async function openChange(vmId) {
  if (change.vmId === vmId) { closeChange(); return; }
  Object.assign(change, { vmId, answer: null, pick: null, busy: false, err: '' });
  render();
  try {
    const a = DEMO_MODE ? demoChangeAnswer(vmId)
      : await apiPost(`runs/${runSeg()}/plan/target`, runBody({ vmId, preview: true }));
    if (change.vmId !== vmId) return;          // closed, or another opened, while it read
    change.answer = a;
  } catch (e) { if (change.vmId === vmId) change.err = VmfHelp.explainAction(e); }
  render();
}
async function applyChange() {
  const a = change.answer, pick = change.pick;
  if (!a || !pick || pick === a.Current || dirty()) return;
  // No version means the page no longer knows which plan it shows.
  if (!DEMO_MODE && !planVersion) { change.err = UX.changeStale; render(); return; }
  change.busy = true; change.err = ''; render();
  let r;
  try {
    r = DEMO_MODE ? demoChangeApply(a, pick)
      : await apiPost(`runs/${runSeg()}/plan/target`, runBody({ vmId: a.VmId, option: pick, planVersion }));
  } catch (e) {
    change.busy = false;
    change.err = /^409/.test(String(e?.message ?? '')) ? UX.changeStale : VmfHelp.explainAction(e);
    render();
    return;
  }
  // The change is made. From here a failure is about THIS PAGE, never offered
  // as a reason to apply again.
  const name = vmName(a.VmId), size = String(r?.CurrentSize ?? '').replace(/^Standard_/, '');
  const inWave = a.Wave && a.Wave !== 'unscheduled';
  Object.assign(change, { vmId: null, answer: null, pick: null, busy: false, err: '' });
  $('#ok').textContent = (inWave ? UX.changeDone : UX.changeDoneNoWave).replace('{name}', name).replace('{size}', size);
  $('#ok').style.display = 'block';
  if (!DEMO_MODE) {
    // The wave's quota check was removed with the change, so the claims are read again too.
    try { await reloadPlan(); await loadClaims(); }
    catch { planVersion = ''; $('#warnbar').textContent = UX.changeReload; $('#warnbar').style.display = 'block'; }
  }
  render();
}
// A series is picked without drawing the page again, so keyboard focus stays on it.
function pickSeries(value) {
  change.pick = value; change.err = '';
  const apply = document.querySelector('[data-changeapply]');
  if (apply) apply.disabled = dirty() || change.busy || value === change.answer?.Current;
  const err = document.querySelector('.m-change .err-inline');
  if (err) err.remove();
}
// ?demo: the same answer the engine gives, for a sample plan with no engine.
function demoChangeAnswer(vmId) {
  const e = entries.find(x => x.vmId === vmId);
  const current = e?.target?.choice?.option ?? e?.policy?.targetGeneration ?? 'v6';
  const base = String(e?.assessment?.sourceSize ?? '').replace(/_v\d$/, '');
  return { VmId: vmId, Wave: e?.wave, Current: current, CurrentSize: e?.target?.size,
    Options: ['v5', 'v6', 'v7'].map(s => ({ option: s, supported: true, current: s === current, targetSize: `${base}_${s}`, why: [] })) };
}
function demoChangeApply(a, pick) {
  const e = entries.find(x => x.vmId === a.VmId);
  const o = a.Options.find(x => x.option === pick);
  e.target = { ...(e.target ?? {}), size: o.targetSize, choice: { option: pick, source: 'person' } };
  e.policy = { ...(e.policy ?? {}), targetGeneration: pick };
  return { CurrentSize: o.targetSize };
}
// WAVE-EDITOR-1: each machine's current size and the size it moves to, in the
// same form as the run page's size column. The editor never said what a
// machine becomes, so arranging waves meant opening each machine elsewhere.
function sizeMove(e) {
  const short = (s) => String(s ?? '').replace(/^Standard_/, '');
  const from = e.assessment?.sourceSize, to = e.target?.size;
  if (!to) return '';
  // A plan always records the size a machine is on; a hand-made one may not.
  if (!from) return ` &middot; <span class="mono">&rarr; ${esc(short(to))}</span>`;
  return ` &middot; <span class="mono">${esc(short(from))} &rarr; ${esc(short(to))}</span>`;
}
/* TEMP-DISK-PREVIEW-1: how many machines of a wave take the in-place upgrade
 * (Preview), with their names, by the rule the sign-off on Run it asks
 * (help.js). Checking stops a machine whose subscription does not have the
 * preview feature. Nothing when none does.
 *
 * WAVE-NOTE-LAYOUT-1: the note was loose text beside the pill, with the names
 * run into the sentence, so a line broke inside a name. It is now a box (the
 * approved mock-up): the pill and a short title, the sentence, then
 * "Virtual machines:" and the names. The card markup holds only the empty
 * box; drawWaveNotes fills it with DOM nodes, because the names come from
 * Azure and never go into markup. */
function previewLine(members, wave) {
  if (!VmfHelp.previewNames(members, vmName).length) return '';
  return `<div class="wnote" data-wnote="${esc(wave)}"></div>${previewNoticeHtml(members)}`;
}
/** Fill a wave card's note box: the pill and the title, the sentence, then one node per name. */
function fillPreviewNote(box, members) {
  const names = VmfHelp.previewNames(members, vmName);
  const head = document.createElement('div');
  head.className = 'wnote-t';
  const pill = document.createElement('span');
  pill.className = 'pill';
  pill.textContent = UX.previewPill;
  head.append(pill, UX.changePreview);
  const said = document.createElement('p');
  said.textContent = (names.length === 1 ? UX.previewOne : UX.previewMany).replace('{n}', String(names.length));
  const vms = document.createElement('p');
  vms.className = 'wnote-vms';
  const label = document.createElement('b');
  label.textContent = UX.noteVms;
  vms.append(label, ' ');
  names.forEach((n, i) => {
    if (i) vms.append(', ');
    const one = document.createElement('span');
    one.className = 'wnote-vm';
    one.textContent = n;
    vms.append(one);
  });
  box.replaceChildren(head, said, vms);
}
/** After the wave cards are drawn: fill each note box with the machines of its wave. */
function drawWaveNotes() {
  for (const box of document.querySelectorAll('[data-wnote]')) fillPreviewNote(box, membersOf(box.dataset.wnote));
}
/* REBUILD-REMOVE-PLAN-1: the notice of the targets step, in the wave editor. For
 * each subscription whose machines of this wave take the in-place upgrade
 * (Preview) and where the feature is not registered (help.js previewNeeds): the
 * subscription, how many machines, what to do, a ? helper with the steps in the
 * Azure portal (one button, ? and Close, and Escape closes it - rule 11) and
 * Check again, which reads the feature again with no reload. The product never
 * registers the feature, and gives no command to run elsewhere (rule 12). */
const wPreview = new Map(), wPreviewHelp = new Set();
function previewNoticeHtml(members) {
  return VmfHelp.previewNeeds(members, vmName, (s) => wPreview.get(s) ?? null).map(({ sub, read, names }) => {
    const r = read, name = r?.name || sub;
    const words = !r || r.loading ? UX.previewReading.replace('{sub}', name)
      : !r.read ? UX.previewNotRead.replace('{sub}', name)
      : (names.length === 1 ? UX.previewOffOne : UX.previewOffMany).replace('{n}', String(names.length)).replace('{sub}', name);
    const key = `${(members[0] ?? {}).wave ?? ''}|${sub}`;
    const open = wPreviewHelp.has(key);
    const help = open ? `<div class="muted wphelp"><p>${esc(UX.previewWhat)}</p><p>${esc(UX.previewNotTool)}</p><p>${esc(UX.previewPortal)}</p><p>${esc(UX.previewWait)}</p></div>` : '';
    return `<div class="hint wpwarn">${esc(words)}${!r || r.loading ? '' : ' ' + esc(UX.previewThen)}
      <button type="button" class="btn small ghost" data-wphelp="${esc(key)}" aria-expanded="${open}" aria-label="${esc(open ? UX.close : UX.previewAbout)}" title="${esc(UX.previewAbout)}">${open ? esc(UX.close) : '?'}</button>
      <button type="button" class="btn small ghost" data-wpcheck="${esc(sub)}"${r?.loading ? ' disabled' : ''}>${esc(UX.previewCheck)}</button>${help}</div>`;
  }).join('');
}
/* Read the feature of each subscription that holds a Preview machine, once -
 * and again for one on Check again (force). A read that fails is not checked. */
async function wPreviewLoad(force) {
  const subs = new Set(entries.filter(e => e && e.path === 'A' && e.target?.choice?.method === 'preview').map(e => VmfHelp.subscriptionOf(e.vmId)));
  for (const s of subs) {
    if (!s || (force ? s !== force : wPreview.has(s))) continue;
    wPreview.set(s, { ...(wPreview.get(s) ?? {}), loading: true });
    if (force) render();
    let answer;
    try {
      const r = await apiGet(`preview-feature?subscriptionId=${encodeURIComponent(s)}`);
      answer = { read: r?.read === true, registered: r?.registered === true, name: r?.subscriptionName || '' };
    } catch { answer = { read: false, registered: false, name: wPreview.get(s)?.name || '' }; }
    wPreview.set(s, answer);
    render();
  }
}

// Arriving from the wizard's "change them first" must land on the settings it
// was talking about, not at the top of a page of machines.
function focusWaveFromHash() {
  const m = location.hash.match(/^#wave=(.+)$/);
  if (!m) return;
  const name = decodeURIComponent(m[1]);
  const el = document.querySelector(`.wave[data-wave="${CSS.escape(name)}"]`);
  if (!el) return;
  el.classList.add('focus');
  const levers = el.querySelector('.levhead');
  (levers ?? el).scrollIntoView({ behavior: 'smooth', block: 'center' });
  // Say WHY this wave is highlighted - arriving highlighted with no
  // explanation is its own small mystery.
  $('#ok').textContent = UX.arrivedToEdit.replace('{wave}', name);
  $('#ok').style.display = 'block';
  setTimeout(() => el.classList.remove('focus'), 4000);
}

/* WAVE-NAME-1: make the name usable AS IT IS TYPED.
 *
 * A wave name becomes a file name - approvals/<wave>.json - and it keys the
 * quota record and the schedule too, so Set-VmfWavePlan refuses anything
 * outside [A-Za-z0-9._-] that does not start with a letter or a number.
 *
 * That refusal used to arrive at SAVE. The editor let a person type "First
 * Five", arrange every machine, and only then said the name was not usable -
 * with the work already done. Waves appeared to be renameable, because demo
 * mode never calls the service - so the rule fired for nobody who was looking.
 *
 * This is the same rule as the service's, and it must STAY the same: a
 * unit test reads the pattern out of Set-VmfWavePlan.ps1 and fails if the two
 * ever disagree.
 */
function sanitiseWaveName(raw) {
  let name = String(raw == null ? '' : raw).trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')   // a run of anything else becomes ONE dash
    .replace(/^[^A-Za-z0-9]+/, '');      // it has to start with a letter or a number
  if (name.length > 63) { name = name.slice(0, 63); }
  return name.replace(/[-.]+$/, '');     // never end on the character we added
}

/* NOT-IN-WAVE-QUEUED-1: the names the product uses for no wave, in any case.
 * The engine skips a wave named unscheduled, and the Migrations page uses
 * unplanned for its own group, so a wave with either name would not run, or
 * would show no Start. Set-VmfWavePlan refuses the same names. */
const RESERVED_WAVE_NAMES = ['unscheduled', 'unplanned'];
function reservedWaveName(name) {
  return RESERVED_WAVE_NAMES.includes(String(name == null ? '' : name).toLowerCase());
}

// A wave name is operator-typed, so it is not safe to drop into a selector.
const cssEscape = (v) => (window.CSS && CSS.escape) ? CSS.escape(String(v))
  : String(v).replace(/["\\]/g, '\\$&');

// The same short form the run pages use.
function ago(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 90) return `${Math.round(s)}s ago`;
  if (s < 5400) return `${Math.round(s / 60)}m ago`;
  if (s < 129600) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

/* CLICKS-LOST-1: the parts of the editor render() replaces. A draw that a
 * watch asks for - not the person's own press - waits while the person holds
 * a control in one of them (VmfHelp.drawWhenFree): on the lab install the
 * reservation watch drew the editor again every few seconds and replaced the
 * button under the pointer. */
function editorRegions() {
  return ['#pool', '#waves', '#quota'].map(s => $(s)).filter(Boolean);
}
function drawEditorWhenFree() {
  VmfHelp.drawWhenFree(editorRegions(), render);
}

function render() {
  renderFilters();
  const pool = shownMachines();
  const poolN = unassigned().length;
  $('#pool-count').textContent = poolN + ' ' + (poolN === 1 ? UX.machine : UX.machines);
  $('#pool').innerHTML = pool.length ? pool.map(e => machineRow(e, false)).join('')
    : `<p class="empty">${esc(UX.poolEmpty)}</p>`;

  const order = waveNames();
  $('#waves').innerHTML = order.map((name, wi) => {
    const w = layout.get(name);
    const members = membersOf(name);
    // An empty option here read as "Leave as planned", which says nothing to
    // somebody setting the plan for the FIRST time, to whom it means nothing.
    // The choice is now always a real value, and an unset wave shows
    // the default it would actually run with.
    const capNow = w.capacityGate || 'BestEffort';
    // APPR-LEVER-1: an operator may put the sign-off requirement ON a wave,
    // and only an approver may take it off. The tick that is already on is
    // read-only for everybody else, and says why.
    const apprLocked = w.requireApproval && !canSignOff;
    // WAVE-EDIT-RUNNING-1: a running wave does not change - the engine refuses it,
    // and its workers would leave a changed machine untouched. Shown, not offered.
    const running = waveMigrating(name);
    const editable = canEdit && !running;
    const capOpt = (v, label) => `<option value="${v}"${capNow === v ? ' selected' : ''}>${esc(label)}</option>`;
    // DECIDE-2: the ACCEPTING option, not the whole control. Putting a gate
    // back ON takes nothing away and stays an operator action, so disabling
    // the select would make the safe direction need a signature too. A gate
    // already on Continue is left alone - nothing is being accepted again.
    const gateShut = !canSignOff;
    const stopOpt = (cur, v, label) => {
      const locked = gateShut && v === 'proceed' && (cur ?? 'stop') !== 'proceed';
      return `<option value="${v}"${(cur ?? 'stop') === v ? ' selected' : ''}${locked ? ' disabled' : ''}>${esc(label)}</option>`;
    };
    const gateHint = gateShut ? `<span class="hint">${esc(UX.gateLocked)}</span>` : '';
    // WAVE-QUOTA-ROW-1: A QUOTA IS NOT A CAPACITY RESERVATION. The quota row
    // below has its own label: its button sat INSIDE the label of the
    // reservation lever, so a quota check read as part of the reservation
    // control. The words were always right; the nesting said otherwise. This
    // note sat in the template as an HTML comment, where the word check reads
    // it as page text (MANUAL-REVIEW-1).
    return `<div class="wave" data-wave="${esc(name)}">
      <div class="wh">
        <input class="name" value="${esc(name)}" data-rename="${esc(name)}" ${editable ? '' : 'disabled'} aria-label="wave name">
        <span class="pill quiet">${members.length} ${esc(members.length === 1 ? UX.machine : UX.machines)}</span>
        ${running ? `<span class="pill warn" title="${esc(waveHoldOf(name) === 'endedHold' ? UX.endedHoldTip : UX.runningTip)}">${esc(waveHoldOf(name) === 'endedHold' ? UX.endedHoldTag : UX.runningTag)}</span>` : ''}
        <span class="spacer"></span>
        ${canEdit ? `<button class="btn small ghost" data-waveup="${esc(name)}" ${wi === 0 ? 'disabled' : ''}>${esc(UX.moveUp)}</button>
        <button class="btn small ghost" data-wavedown="${esc(name)}" ${wi === order.length - 1 ? 'disabled' : ''}>${esc(UX.moveDown)}</button>
        ${running ? '' : `<button class="btn small ghost" data-moveto="${esc(name)}" ${selection.size ? '' : 'disabled'}>${esc(UX.sendHere)}</button>
        <button class="btn small danger" data-del="${esc(name)}">${esc(UX.deleteWave)}</button>`}` : ''}
      </div>
      ${previewLine(members, name)}
      <div class="levhead">${esc(UX.leversHeading)}</div>
      <div class="levers">
        <label title="${esc(UX.capTip)}"><span class="lv">${esc(UX.capLabel)}</span>
          <select data-cap="${esc(name)}" ${editable ? '' : 'disabled'}>
            ${capOpt('BestEffort', UX.capOnDemand)}${capOpt('Reserved', UX.capReserved)}
          </select>
          ${!canEdit || (capNow !== 'Reserved' && !billingWaves.has(name)) ? '' : reserveControl(name)}
          </label>
        ${quotaControl(name)}
        <label><span class="lv">${esc(UX.dataLabel)}</span>
          <select data-data="${esc(name)}" ${editable ? '' : 'disabled'}>
            ${stopOpt(w.onDDataFound, 'stop', UX.dataStop)}${stopOpt(w.onDDataFound, 'proceed', UX.dataProceed)}
          </select>${gateHint}${ownHint(name, w, 'onDDataFound')}</label>
        ${kernelRow(name)}
        <label title="${esc(UX.keepTip)}"><span class="lv">${esc(UX.keepLabel)}</span>
          <span class="keep"><input type="number" min="0" max="90" step="1" style="width:4.5rem" data-keep="${esc(name)}"
                 value="${Number(w.keepSnapshotDays ?? 7)}" ${editable ? '' : 'disabled'}> ${esc(UX.keepDays)}</span>${ownHint(name, w, 'keepSnapshotDays')}</label>
        <!-- SCALE-UX-1: how many at once, beside the machines it counts; the
             facade sizes the engine containers from the number when the wave
             starts. MACHINES-AT-ONCE-RANGE-1: four choices, each with its
             number and its engine containers, and a sentence for the chosen
             one, then the estimate and the cores. ATONCE-EARLIER-1: every
             writer writes a choice, so another number selects an empty
             option, never a choice it does not hold. -->
        <label class="atonce" title="${esc(UX.atOnceTip)}"><span class="lv">${esc(UX.atOnceLabel)}</span>
          <select data-thr="${esc(name)}" ${editable ? '' : 'disabled'}>
            ${VmfHelp.atOnceChoice(w.throttle).tier ? '' : '<option value="" selected disabled hidden></option>'}
            ${VmfHelp.WAVE_TIERS.map(t => `<option value="${t.machines}"${Number(w.throttle) === t.machines ? ' selected' : ''}>${esc(VmfHelp.atOnceChoice(t.machines).label)}</option>`).join('')}
          </select>
          <span class="hint">${esc(VmfHelp.atOnceChoice(w.throttle).meaning)}</span>
          <span class="hint">${esc(VmfHelp.waveEstimate(members.length, w.throttle, UX) || '')}</span>
          <span class="hint" data-caphint="${esc(name)}"></span></label>
        <label class="chk"${apprLocked ? ` title="${esc(UX.approvalLocked)}"` : ''}><input type="checkbox" data-appr="${esc(name)}" ${w.requireApproval ? 'checked' : ''} ${editable && !apprLocked ? '' : 'disabled'}>
          <span class="lv">${esc(UX.approvalOn)}</span>${apprLocked ? `<span class="hint">${esc(UX.approvalLocked)}</span>` : ''}</label>
      </div>
      <div class="body">${members.length ? members.map(e => machineRow(e, true)).join('')
        : `<p class="empty">${esc(selection.size ? UX.waveEmptyReady : UX.waveEmpty)}</p>`}</div>
    </div>`;
  }).join('') || `<p class="muted">${esc(UX.waveEmpty)}</p>`;
  // WAVE-NOTE-LAYOUT-1: the note boxes hold machine names, so DOM nodes fill them.
  drawWaveNotes();

  /* WAVE-FLOW-1: asking Azure to raise a quota lived on the capacity step,
   * which this page replaces. It is plan-wide rather than per wave.
   *
   * QUOTA-PLACE-1: and so it goes ABOVE the waves, in a slot of its own.
   * It used to be appended AFTER the wave cards, on the argument that it
   * belonged beside the per-wave check that finds the shortfall. That holds
   * at one wave. At eight it is two pages down, where a reader in the lab
   * hardly saw it.
   *
   * A quota increase can take Azure days. If this plan needs one, that
   * is the first thing to know, not the last. */
  drawQuotaCard();

  /* SAVE-STUCK-1: "nothing has changed" is NOT a reason to disable this.
   *
   * Inside the flow this button is step 2's only way to step 3, so a person
   * who reads the default grouping and agrees with it was stuck - the way
   * forward was to change something they did not want to change. That
   * happened in use, with no tooltip to say why.
   *
   * It is a reason not to WRITE, which save() handles. The page already had
   * this shape one button along: Reset is always enabled and says there was
   * nothing to undo. */
  $('#save').disabled = !canEdit;
  wireRows();
}

function wireRows() {
  document.querySelectorAll('.m').forEach(el => {
    el.addEventListener('click', () => {
      const id = el.dataset.vm;
      if (started(id)) return;
      if (selection.has(id)) selection.delete(id); else selection.add(id);
      render();
    });
    el.addEventListener('dragstart', (e) => {
      const id = el.dataset.vm;
      if (!selection.has(id)) { selection.clear(); selection.add(id); }
      e.dataTransfer.setData('text/plain', 'vmf');
    });
  });
  document.querySelectorAll('.wave').forEach(el => {
    el.addEventListener('dragover', (e) => { e.preventDefault(); el.classList.add('drop'); });
    el.addEventListener('dragleave', () => el.classList.remove('drop'));
    el.addEventListener('drop', (e) => { e.preventDefault(); el.classList.remove('drop'); moveTo(el.dataset.wave, [...selection]); });
  });
  // LEAK-1: #pool's OWN listeners are NOT wired here. Everything else in this
  // function hangs off an element that render() replaced, so those listeners
  // die with the markup - but #pool is the static container and survives every
  // render. Adding to it here added one more handler per render, for the life
  // of the page. See wirePoolDropTarget(), called once at start.

  /* WAVE-TAKEOUT-1: a machine in a wave could only leave it by dragging it
   * back to the list, which nothing on the screen said. A button on the row
   * is the way back. Its click must not reach the row, which would select it. */
  document.querySelectorAll('[data-takeout]').forEach(b =>
    b.addEventListener('click', (ev) => { ev.stopPropagation(); moveTo(null, [b.dataset.takeout]); }));
  // WAVE-MIX-2. The button sits in the row, so its click must not select it.
  document.querySelectorAll('[data-change]').forEach(b =>
    b.addEventListener('click', (ev) => { ev.stopPropagation(); openChange(b.dataset.change); }));
  document.querySelectorAll('input[name="m-series"]').forEach(r =>
    r.addEventListener('change', () => pickSeries(r.value)));
  document.querySelectorAll('[data-changecancel]').forEach(b => b.addEventListener('click', closeChange));
  // WAVE-LEVER-OVERRIDE-1: the ? helper of a setting opens and closes. It sits
  // in the label of the setting, so the click must not reach the control.
  // WAVE-LEVER-RESET-1: closing it cancels its resets not saved.
  document.querySelectorAll('[data-ownhelp]').forEach(b => b.addEventListener('click', (ev) => {
    ev.preventDefault(); ev.stopPropagation();
    toggleOwnHelp(b.dataset.ownhelp);
  }));
  // WAVE-LEVER-RESET-1: Reset beside a machine, and Cancel on the same button.
  document.querySelectorAll('[data-ownreset]').forEach(b => b.addEventListener('click', (ev) => {
    ev.preventDefault(); ev.stopPropagation();
    const key = b.dataset.ownreset;
    const cut = key.lastIndexOf('|');
    toggleReset(key.slice(0, cut), key.slice(cut + 1), b.dataset.resetvm);
    render();
  }));
  // REBUILD-REMOVE-PLAN-1: the preview notice's ? helper, and Check again.
  document.querySelectorAll('[data-wphelp]').forEach(b => b.addEventListener('click', (ev) => {
    ev.preventDefault(); ev.stopPropagation();
    const k = b.dataset.wphelp;
    if (wPreviewHelp.has(k)) wPreviewHelp.delete(k); else wPreviewHelp.add(k);
    render();
  }));
  document.querySelectorAll('[data-wpcheck]').forEach(b => b.addEventListener('click', (ev) => {
    ev.preventDefault(); ev.stopPropagation(); wPreviewLoad(b.dataset.wpcheck);
  }));
  document.querySelectorAll('[data-changeapply]').forEach(b => b.addEventListener('click', applyChange));
  document.querySelectorAll('[data-moveto]').forEach(b =>
    b.addEventListener('click', () => moveTo(b.dataset.moveto, [...selection])));
  // WAVE-ORDER-1: the order is the plan's order - it decides which wave runs first.
  document.querySelectorAll('[data-waveup]').forEach(b =>
    b.addEventListener('click', () => { layout = moveWave(layout, b.dataset.waveup, -1); render(); }));
  document.querySelectorAll('[data-wavedown]').forEach(b =>
    b.addEventListener('click', () => { layout = moveWave(layout, b.dataset.wavedown, 1); render(); }));
  document.querySelectorAll('[data-del]').forEach(b =>
    b.addEventListener('click', () => { layout.delete(b.dataset.del); render(); }));
  document.querySelectorAll('[data-cap]').forEach(s =>
    s.addEventListener('change', () => { layout.get(s.dataset.cap).capacityGate = s.value; render(); }));
  document.querySelectorAll('[data-appr]').forEach(c =>
    c.addEventListener('change', () => { layout.get(c.dataset.appr).requireApproval = c.checked; render(); }));
  document.querySelectorAll('[data-data]').forEach(s =>
    s.addEventListener('change', () => { layout.get(s.dataset.data).onDDataFound = s.value; render(); }));

  // SCALE-2: the capacity sentence for every wave on screen.
  document.querySelectorAll('[data-caphint]').forEach(h => showEngineCapacity(h.dataset.caphint, layout.get(h.dataset.caphint)?.throttle ?? VmfHelp.WAVE_DEFAULT_WORKERS));
  document.querySelectorAll('[data-keep]').forEach(i =>
    i.addEventListener('change', () => {
      const n = Math.max(0, Math.min(90, Math.round(Number(i.value))));
      layout.get(i.dataset.keep).keepSnapshotDays = Number.isFinite(n) ? n : 7;
      render();
    }));
  // MACHINES-AT-ONCE-RANGE-1: a choice is taken as it is made; the drawing
  // that follows says what it means, the estimate and the cores.
  document.querySelectorAll('[data-thr]').forEach(s =>
    s.addEventListener('change', () => { layout.get(s.dataset.thr).throttle = Number(s.value); render(); }));
  document.querySelectorAll('[data-reserve]').forEach(b =>
    b.addEventListener('click', () => reserveCapacity(b.dataset.reserve, b)));
  document.querySelectorAll('[data-release]').forEach(b =>
    b.addEventListener('click', () => releaseCapacity(b.dataset.release, b)));
  document.querySelectorAll('[data-capcheck]').forEach(b =>
    b.addEventListener('click', () => checkCapacity(b.dataset.capcheck)));
  document.querySelectorAll('[data-rename]').forEach(i =>
    i.addEventListener('change', () => {
      const from = i.dataset.rename;
      const typed = i.value.trim();
      const to = sanitiseWaveName(typed);
      // Nothing usable was typed - keep the name it had rather than clearing it.
      if (!to) { i.value = from; render(); return; }
      // NOT-IN-WAVE-QUEUED-1: a name the product uses for no wave - keep the
      // name it had, and say why.
      if (reservedWaveName(to)) {
        i.value = from;
        render();
        $('#warnbar').textContent = UX.nameReserved.replace('{typed}', to);
        $('#warnbar').style.display = 'block';
        return;
      }
      // Say what happened, once, and only when the text actually changed.
      const note = to === typed ? '' : UX.nameChanged.replace('{typed}', typed).replace('{used}', to);
      i.value = to;
      if (to === from || layout.has(to)) {
        render();
        if (note) { $('#warnbar').textContent = note; $('#warnbar').style.display = 'block'; }
        return;
      }
      const rebuilt = new Map();
      for (const [n, w] of layout) rebuilt.set(n === from ? to : n, w);
      layout = rebuilt;
      render();
      if (note) { $('#warnbar').textContent = note; $('#warnbar').style.display = 'block'; }
    }));
}

/* ODCR-BUTTON-1: which waves already hold a reservation.
 *
 * Read from the run's own quota records rather than from a flag on the plan,
 * because the claim is what the engine acts on. A plan that SAYS reserved and a
 * claim that is not RESERVED is exactly the state this button exists to
 * resolve, and a flag on the plan would hide it. */
const dirty = () => snapshot() !== original;
/* One control, four states. Kept out of the template so that adding a state
 * means adding a branch here rather than another nested ternary. */
function reserveControl(name) {
  const st = claims.get(name);
  // WAVE-EDIT-RESERVE-1: a reservation that bills stops a save that would
  // change this wave, so the way out sits beside it - whatever the wave's
  // worst answer, because a partly blocked wave keeps the parts it reserved.
  // Not while machines of the wave are migrating and may be using it (the
  // engine refuses then too); after the wave it is still offered, because a
  // close-out that did not release leaves it billing.
  const release = (canEdit && billingWaves.has(name) && !waveMigrating(name))
    ? ` <button class="btn small ghost lever-act" data-release="${esc(name)}" title="${esc(UX.releaseTip)}">${esc(UX.releaseBtn)}</button>` : '';
  if (st === 'held') {
    return `<span class="pill good lever-act">${esc(UX.reserveHeld)}</span>${release}`;
  }
  if (st === 'working') {
    return `<span class="pill warn lever-act" title="${esc(UX.reserveWorkingTip)}">${esc(UX.reserveWorking)}</span>${release}`;
  }
  if (st === 'unconfirmed') {
    return `<span class="pill bad lever-act" title="${esc(UX.reserveUnconfirmedTip)}">${esc(UX.reserveUnconfirmed)}</span>${release}`;
  }
  if (st === 'blocked') {
    return `<span class="pill bad lever-act" title="${esc(UX.reserveBlockedTip)}">${esc(UX.reserveBlocked)}</span>${release}`;
  }
  // AVSET-RESERVE-1: nothing in this wave can hold a reservation, so there is
  // no Reserve to offer - pressing it reserved nothing and said so too late.
  if (st === 'general') {
    return `<span class="pill quiet lever-act" title="${esc(UX.reserveGeneralTip)}">${esc(UX.reserveGeneral)}</span>${release}`;
  }
  const off = dirty() ? ` disabled title="${esc(UX.reserveSaveFirst)}"` : '';
  return `<button class="btn small ghost lever-act" data-reserve="${esc(name)}"${off}>${esc(UX.reserveBtn)}</button>`;
}

/* ODCR-VERIFY-1: the claim state, not a yes/no.
 *
 * The pill did not move to a pending state while the reservation was being
 * created - there was no in-flight state at all, so a reload
 * during the minutes Azure takes brought the Reserve button back and a second
 * press would have paid twice. capacity-claim v7 adds RESERVING for this. */
let claims = new Map();      // wave -> 'held' | 'working' | 'unconfirmed' | 'blocked' | 'general'
let billingWaves = new Set(); // WAVE-EDIT-RESERVE-1: waves with a reservation that bills and can be released
// AVSET-RESERVE-1: wave -> machines that move on general capacity because they
// are in an availability set.
let generalByWave = new Map();
// QUOTA-TRUTH-1: wave -> when its quota was last read from Azure. "The quota is
// enough" printed before anybody pressed the button, with nothing to say it
// was a reading from earlier, read as an answer to a question not yet asked.
let lastChecked = new Map();
/* QUOTA-CHECK-SPINNER-1: the row said "Checked 5s ago" and no result after a
 * render, because the answer lived only in the DOM of the press. Now:
 * waveDocs     wave -> its quota records, as loadClaims reads them; the row
 *              draws its result and the table of what is short from them.
 * checkingWaves the waves whose check runs now: the row and the card show the
 *              spinner, whatever draws them.
 * capAnswers   wave -> { text, cls, at, stamp } the answer of a press, kept
 *              for the check it belongs to (at = its checkedUtc). */
let waveDocs = new Map();
// QUOTA-CHECK-SPINNER-1: raised by each loadClaims, so only the newest read started fills the page.
let claimsTurn = 0;
const checkingWaves = new Set();
const capAnswers = new Map();

/* QUOTA-PREVIEW-1: Request an increase asks first, and the access is known at plan time.
 *
 * The first version had a check box for a preview, which was not clear. Now
 * the one button opens a confirmation: it gets the engine's preview (one
 * quotaPreview line in the run's activity log), lists exactly what will be
 * requested with Azure's column names, and files nothing until Request.
 * Cancel, Escape and a click outside close it (rule 11).
 *
 * And a missing access showed only at the click. The quota check now records,
 * per quota too low, whether the product may request it (quota.requestAccess).
 * With no access the card has no button, and says where to give it (rule 12). */
// Subscription (lower case) -> 'granted' | 'missing' | 'unknown', from the records too low.
let quotaAccess = new Map();
// The subscriptions the signed-in user can see, for their names. Null until read.
let subscriptionList = null;
const subName = (id) => (subscriptionList?.subscriptions ?? []).find(x => String(x.id).toLowerCase() === String(id).toLowerCase())?.name || id;
// The confirmation: { phase: 'wait' | 'ready' | 'error', rows, error }, or null when closed.
let quotaConfirm = null;
// Raised by every open and close, so an answer for a closed confirmation is dropped.
let quotaConfirmTurn = 0;

/** What the quota check recorded about the access, per subscription. The worst answer wins. */
function quotaAccessFrom(docs) {
  const rank = { granted: 1, unknown: 2, missing: 3 };
  const out = new Map();
  for (const d of docs) {
    // REGIONAL-QUOTA-REQUEST-1: Request an increase asks for the Total Regional vCPUs quota too.
    if (!VmfHelp.claimBlocked(String(d?.state ?? '').toUpperCase()) || !['quota-shortfall', 'regional-quota-shortfall'].includes(d.blockReason)) { continue; }
    const said = d.quota?.requestAccess;
    if (!rank[said]) { continue; }
    const sub = String(d.subscriptionId ?? '').toLowerCase();
    if (!out.has(sub) || rank[said] > rank[out.get(sub)]) { out.set(sub, said); }
  }
  return out;
}

/* QUOTA-CHECK-SPINNER-1 (review): the state of the plan, as sentences. Green
 * only when it is true of the whole plan: every wave that has machines has a
 * result (records, or "no machine changes size"), no wave holds a check that
 * failed or that found machines with no record, and no quota lacks a figure.
 * Otherwise each true fact: short; the waves with no result; a quota Azure
 * does not list. Nothing checked at all is said as that. */
function quotaPlanState(rows) {
  const waves = waveNames().filter(n => membersOf(n).length);
  const kept = (w) => { const k = capAnswers.get(w); return k && k.at === (lastChecked.get(w) ?? null) ? k : null; };
  const noResult = waves.filter(w => {
    const k = kept(w);
    if (k) { return k.text !== UX.capNothing; }
    return !(waveDocs.get(w) ?? []).length;
  });
  if (!rows.length && !waves.some(w => kept(w))) { return [{ cls: 'muted', text: UX.quotaNotChecked }]; }
  const said = [];
  if (rows.some(r => r.short)) { said.push({ cls: 'err-inline', text: UX.capPlanShort }); }
  if (noResult.length) { said.push({ cls: 'err-inline', text: UX.capPlanNoResult.replace('{waves}', () => noResult.join(', ')) }); }
  if (rows.some(r => !r.short && r.shortBy === null)) { said.push({ cls: 'muted', text: UX.quotaUnlisted }); }
  if (!said.length) { said.push({ cls: 'ok-inline', text: UX.capPlanEnough }); }
  return said;
}

/* The card that holds the plan-wide quota and requests a quota increase.
 * QUOTA-CHECK-SPINNER-1 (lab walk 2026-11-17): the time of the last
 * check and Check the quota in its header; the state of the plan; the table of
 * every quota the plan uses; then the request, when a quota is short. */
function quotaCardHtml() {
  const said = [...quotaAccess];
  const missing = said.filter(([, a]) => a === 'missing').map(([s]) => s).sort();
  const unknown = said.filter(([, a]) => a === 'unknown').map(([s]) => s).sort();
  // No button only when every subscription with a quota too low has no access.
  const canRequest = !(said.length && missing.length === said.length);
  const access = missing.map(s => `<p class="err-inline">${esc(UX.quotaNoAccess.replace('{name}', subName(s)))}</p>`).join('')
    + unknown.map(s => `<p class="muted">${esc(UX.quotaAccessUnknown.replace('{name}', subName(s)))}</p>`).join('');
  const checking = checkingWaves.size > 0;
  const times = [...lastChecked.values()].map(t => Date.parse(t)).filter(Number.isFinite);
  const when = times.length ? new Date(Math.max(...times)).toISOString() : null;
  const off = (dirty() && canEdit) ? ` title="${esc(UX.capSavesFirst)}"` : '';
  const head = `<div class="ch"><h2>${esc(UX.quotaTitle)}</h2><span class="spacer"></span>${when && !checking
    ? `<span class="hint">${agoHtml(UX.capLast, when)}</span>` : ''}<button class="btn small ghost" id="q-check"${off}${checking ? ' disabled' : ''}>${esc(UX.capCheck)}</button></div>`;
  // A result is coming, so the card shows the spinner and offers nothing from the result before it.
  if (checking) {
    return `<div class="card" style="margin-bottom:14px">${head}
    <div class="cb"><p class="muted working"><span class="spin"></span>${esc(UX.quotaCardChecking)}</p></div></div>`;
  }
  const rows = planQuotaRows();
  const fig = (v) => esc(v === null ? UX.capNoFigure : String(v));
  const state = quotaPlanState(rows).map(s => `<p class="${s.cls}">${esc(s.text)}</p>`).join('');
  const heads = [UX.capColQuota, UX.capColRegion, UX.capColLimit, UX.capColUsed, UX.capColPlan, UX.capColShort]
    .map((h, i) => `<th${i > 1 ? ' class="num"' : ''}>${esc(h)}</th>`).join('');
  const table = rows.length ? `<div class="cap-short"><table><thead><tr>${heads}</tr></thead><tbody>${rows.map(r =>
    `<tr${r.short ? ' class="short"' : ''}><td>${esc(r.quota)}</td><td>${esc(r.region)}</td><td class="num">${fig(r.limit)}</td><td class="num">${fig(r.used)}</td><td class="num">${fig(r.planNeed)}</td><td class="num">${
      r.short ? fig(r.shortBy) : r.shortBy === null ? esc(UX.capNoFigure) : esc(UX.capEnough)}</td></tr>`).join('')
  }</tbody></table><span class="hint">${esc(UX.capPlanWhy)}</span></div>` : '';
  return `<div class="card" style="margin-bottom:14px">${head}
    <div class="cb">${state}${table}${quotaShort
      ? `<p class="muted">${esc(UX.quotaBody)}</p>${access}
         <div class="rowact">${canRequest ? `<button class="btn" id="q-go">${esc(UX.quotaBtn)}</button>` : ''}${missing.length
           ? `<a class="btn ghost" id="q-admin" href="access.html#scope-title">${esc(UX.quotaAdminLink)}</a>` : ''}</div>` : ''}${regionalShortRegions.size
      ? `<p class="err-inline">${esc(UX.quotaRegional.replace('{regions}', [...regionalShortRegions].sort().join(', ')))}</p>` : ''}</div></div>`;
}

/** The confirmation's content: what will be requested, one row per quota, per subscription. */
function quotaConfirmHtml(c) {
  const figure = (v) => (v === null || v === undefined || v === '') ? UX.quotaNoFigure : String(v);
  const rows = c.phase === 'ready' ? [].concat(c.rows ?? []).filter(Boolean) : [];
  const asks = rows.filter(r => r.status === 'WHATIF');
  const known = (v) => !(v === null || v === undefined || v === '');
  let body = '';
  // QUOTA-CHECK-SPINNER-1: each wait shows the product's spinner and says what
  // the engine does. The reading took 35 seconds on the lab install, with one
  // line and nothing moving.
  if (c.phase === 'wait') { body = `<p class="desc working"><span class="spin"></span>${esc(UX.quotaConfirmWait)}</p>`; }
  else if (c.phase === 'sending') { body = `<p class="desc working"><span class="spin"></span>${esc(UX.quotaSending)}</p>`; }
  else if (c.phase === 'done') {
    // QUOTA-FILED-WORDS-1: the engine's answer to Request. QUOTA-CHECK-SPINNER-1:
    // one row for each request, with its state and the ID Azure gave it.
    const list = [].concat(c.rows ?? []).filter(Boolean);
    const said = quotaResultLines(list);
    const id = (r) => (r.requestId ? String(r.requestId).split('/').filter(Boolean).pop() : UX.quotaNoId);
    body = list.length ? `<table><thead><tr><th>${esc(UX.quotaColQuota)}</th><th>${esc(UX.quotaColRegion)}</th><th class="num">${esc(UX.quotaColNew)}</th><th>${esc(UX.quotaColState)}</th><th>${esc(UX.quotaColId)}</th></tr></thead><tbody>${
      list.map(r => `<tr><td>${esc(r.quotaName || r.family || '')}</td><td>${esc(r.region ?? '')}</td><td class="num">${esc(figure(r.requestedLimit))}</td><td>${esc(quotaRequestStateText({ ...r, reading: c.reading === true }))}</td><td class="mono q-id">${esc(id(r))}</td></tr>`).join('')}</tbody></table>` : '';
    // QUOTA-REQUEST-POLL-1: under the table, what to do for each answer of
    // Azure, and the spinner while the product reads the answers.
    const next = quotaAnswerLines(list);
    body += said.notFiled.map(t => `<p class="err-inline">${esc(t)}</p>`).join('')
      + next.map(n => `<p class="${n.bad ? 'err-inline' : 'desc'}">${quotaAnswerLineHtml(n)}</p>`).join('')
      + (c.reading ? `<p class="desc working"><span class="spin"></span>${esc(UX.quotaReading)}</p>` : '')
      + (quotaUnanswered(list).length && !c.reading ? `<p class="desc">${esc(UX.quotaDoneNext)}</p>` : '')
      + (said.none ? `<p class="desc">${esc(said.none)}</p>` : '');
  }
  else if (c.phase === 'error') { body = `<div class="m-err" style="display:block">${esc(c.error)}</div>`; }
  else {
    const subs = [...new Set(asks.map(r => String(r.subscriptionId ?? '')))];
    // QUOTA-CHECK-SPINNER-1: what the waves need, as a column and as a sentence for each wave.
    const need = (r) => {
      const list = [].concat(r.waves ?? []).filter(Boolean).map(w => Number(w.vcpus));
      return list.length && list.every(Number.isFinite) ? list.reduce((a, b) => a + b, 0) : null;
    };
    const lines = (r) => {
      const quota = String(r.quotaName || r.family || '');
      const region = String(r.region ?? '');
      const waves = [].concat(r.waves ?? []).filter(Boolean).map(w => UX.quotaWaveLine.replace(/\{(wave|n|quota|region)\}/g,
        (_, k) => ({ wave: String(w.wave ?? ''), n: figure(w.vcpus), quota, region })[k]));
      if (known(r.free)) { waves.push(UX.quotaFreeLine.replace('{free}', () => String(r.free))); }
      if (known(r.requestedLimit)) { waves.push(UX.quotaAskLine.replace('{limit}', () => String(r.requestedLimit))); }
      return waves.map(t => `<div class="hint">${esc(t)}</div>`).join('');
    };
    body = subs.map(s => `<p class="desc">${esc(UX.quotaConfirmLine.replace('{name}', () => subName(s)))}</p>
      <table><thead><tr><th>${esc(UX.quotaColQuota)}</th><th>${esc(UX.quotaColRegion)}</th><th class="num">${esc(UX.quotaColUsed)}</th><th class="num">${esc(UX.quotaColLimit)}</th><th class="num">${esc(UX.quotaColNeed)}</th><th class="num">${esc(UX.quotaColNew)}</th></tr></thead><tbody>${
      asks.filter(r => String(r.subscriptionId ?? '') === s).map(r => `<tr><td>${esc(r.quotaName || r.family || '')}</td><td>${esc(r.region ?? '')}</td><td class="num">${esc(figure(r.usage))}</td><td class="num">${esc(figure(r.currentLimit))}</td><td class="num">${esc(figure(need(r)))}</td><td class="num">${esc(figure(r.requestedLimit))}</td></tr>
        <tr class="q-waves"><td colspan="6">${lines(r)}</td></tr>`).join('')}</tbody></table>`).join('');
    const noSub = rows.filter(r => r.status === 'FAILED').map(r => String(r.quotaName || r.family || ''));
    const noAccess = [...new Set(rows.filter(r => r.status === 'NOACCESS').map(r => String(r.subscriptionId ?? '')))];
    body += noAccess.map(s => `<p class="err-inline">${esc(UX.quotaNoAccess.replace('{name}', subName(s)))}</p>`).join('');
    if (noSub.length) { body += `<p class="err-inline">${esc(UX.quotaPreviewNoSub.replace('{families}', noSub.join(', ')))}</p>`; }
    if (!rows.length) { body = `<p class="desc">${esc(UX.quotaPreviewNone)}</p>`; }
  }
  // Once Request is sent, closing takes nothing back, so the button says Close.
  const sent = c.phase === 'sending' || c.phase === 'done' || c.sent === true;
  const closeWord = sent ? UX.quotaClose : UX.cancel;
  // QUOTA-CHECK-SPINNER-1: after Request the title is not a question.
  return `<h3 id="q-m-title">${esc(sent ? UX.quotaSentTitle : UX.quotaConfirmTitle)}</h3>${body}
    <div class="m-actions"><button type="button" class="btn ghost" id="q-cancel">${esc(closeWord)}</button>${asks.length
      ? `<button type="button" class="btn" id="q-request">${esc(UX.quotaConfirmBtn)}</button>` : ''}</div>`;
}

/** Draw the quota card and wire it. Called by render, and when the subscription names arrive. */
function drawQuotaCard() {
  $('#quota').innerHTML = quotaCardHtml();
  $('#q-go')?.addEventListener('click', openQuotaConfirm);
  // QUOTA-CHECK-SPINNER-1: one check for the plan, from the card.
  $('#q-check')?.addEventListener('click', checkPlan);
}

/** Show the confirmation as it stands, or hide it when it is closed. */
function drawQuotaConfirm() {
  if (!quotaConfirm) { $('#q-modal-back').classList.remove('open'); $('#q-modal').innerHTML = ''; return; }
  $('#q-modal').innerHTML = quotaConfirmHtml(quotaConfirm);
  $('#q-modal-back').classList.add('open');
  $('#q-cancel')?.addEventListener('click', closeQuotaConfirm);
  $('#q-request')?.addEventListener('click', sendQuotaRequest);
}

/** Request an increase: open the confirmation and get the engine's preview. Nothing is filed. */
async function openQuotaConfirm() {
  const turn = ++quotaConfirmTurn;
  const wanted = () => turn === quotaConfirmTurn;
  quotaConfirm = { phase: 'wait' };
  document.removeEventListener('keydown', quotaConfirmKey);
  document.addEventListener('keydown', quotaConfirmKey);
  drawQuotaConfirm();
  try {
    // The window opens before the request, so a fast engine line is inside it.
    const since = Date.now() - 5000;
    await apiPost(`runs/${runSeg()}/engine/quota`, runBody({ whatIfOnly: true }));
    const verdict = await watchQuotaPreview(since, wanted);
    if (!wanted()) { return; }
    if (!verdict) { throw new Error(UX.quotaPreviewNoAnswer); }
    if (verdict.failure) { throw new Error(VmfHelp.explain(new Error(String(verdict.failure.detail ?? '')))); }
    quotaConfirm = { phase: 'ready', rows: [].concat(verdict.preview.requests ?? []) };
  } catch (e) {
    if (!wanted()) { return; }
    quotaConfirm = { phase: 'error', error: VmfHelp.explainAction(e) };
  }
  drawQuotaConfirm();
}

/* QUOTA-FILED-WORDS-1: Request waits for Azure's answer, the way the preview does.
 *
 * Request closed the confirmation and said "filed" when the service answered
 * 202 - the engine job STARTED, and nothing was asked of Azure yet. A request
 * Azure refused was then said only in the activity log. Now the page waits for
 * the engine's ONE quotaResult line, and says "filed" only for the quotas Azure
 * took (APPROVED, PENDING), and names each other quota with its reason. Closed
 * while it waits (Close, Escape), the answer goes to the page instead. */
async function sendQuotaRequest() {
  const turn = quotaConfirmTurn;
  const stillOpen = () => turn === quotaConfirmTurn && !!quotaConfirm;
  if ($('#q-request')) { $('#q-request').disabled = true; }
  quotaConfirm = { phase: 'sending' };
  drawQuotaConfirm();
  let result;
  // The window opens before the request, so a fast engine line is inside it.
  // QUOTA-REQUEST-POLL-1: the answer lines are read from the same window.
  const since = Date.now() - 5000;
  try {
    await apiPost(`runs/${runSeg()}/engine/quota`, runBody({ whatIfOnly: false }));
    const verdict = await watchQuotaRequest(since);
    if (!verdict) { throw new Error(UX.quotaRequestNoAnswer); }
    if (verdict.failure) {
      const reason = VmfHelp.explain(new Error(String(verdict.failure.detail ?? '')));
      throw new Error(UX.quotaRequestStopped.replace('{reason}', () => reason));
    }
    result = { phase: 'done', rows: [].concat(verdict.result.requests ?? []).filter(Boolean) };
  } catch (e) {
    // QUOTA-CHECK-SPINNER-1: sent, so the title is not a question any more.
    result = { phase: 'error', error: VmfHelp.explainAction(e), sent: true };
  }
  // QUOTA-REQUEST-POLL-1: a request Azure took for later is read by the
  // engine for 2 minutes; the page shows the spinner until its answer line.
  const toRead = result.phase === 'done' ? quotaRowsToRead(result.rows) : [];
  if (toRead.length) { result.reading = true; }
  if (stillOpen()) { quotaConfirm = result; drawQuotaConfirm(); }
  else { showQuotaResult(result); }
  // The engine moved the quotas it filed to QUOTA_REQUESTED. A failed read
  // here must not hide the answer above.
  try { await loadClaims(); drawEditorWhenFree(); } catch { /* the next refresh reads them */ }
  if (!toRead.length) { return; }
  let answers = new Map();
  try { answers = await watchQuotaAnswers(since, toRead.map(r => r.requestId)); } catch { /* each row says Azure did not answer */ }
  const done = { ...result, rows: mergeQuotaAnswers(result.rows, answers), reading: false };
  // Still open on this answer: into the confirmation. Closed: onto the page.
  if (turn === quotaConfirmTurn && quotaConfirm === result) { quotaConfirm = done; drawQuotaConfirm(); }
  else { showQuotaResult(done); }
}

/* QUOTA-REQUEST-POLL-1: the answer of Azure to each filed request.
 *
 * A request Azure took with HTTP 202 showed "Filed. Azure has not answered
 * yet." for ever: nothing read it again. Now the engine reads each one for 2
 * minutes and writes one quotaAnswer line with its request ID and the answer:
 * APPROVED, REFUSED (with Azure's code), WAITING (no answer in the time) or
 * NOTREAD (the product could not read it). */

/** The key of a request ID: its last part (the GUID), in lower case. */
function quotaAnswerKey(id) {
  return String(id ?? '').split('/').filter(Boolean).pop()?.toLowerCase() ?? '';
}

/** The filed requests the engine reads: PENDING, with an ID. */
function quotaRowsToRead(rows) {
  return [].concat(rows ?? []).filter(r => r && r.status === 'PENDING' && quotaAnswerKey(r.requestId));
}

/** The filed requests with no answer and nothing that reads them. */
function quotaUnanswered(rows) {
  return [].concat(rows ?? []).filter(r => r && r.status === 'PENDING' && !r.answer);
}

/** Each row with the answer of its line. A row the engine read but no line came for: Azure did not answer. */
function mergeQuotaAnswers(rows, answers) {
  return [].concat(rows ?? []).filter(Boolean).map(r => {
    if (r.status !== 'PENDING' || !quotaAnswerKey(r.requestId)) { return r; }
    const e = answers.get(quotaAnswerKey(r.requestId));
    const said = ['APPROVED', 'REFUSED', 'WAITING', 'NOTREAD'].includes(e?.answer) ? e.answer : 'WAITING';
    return { ...r, answer: said, answerCode: e?.code ? String(e.code) : null };
  });
}

/* QUOTA-REQUEST-POLL-1: Microsoft's pages for a quota increase that needs
 * Azure support. Watched for change by tools/Test-DocsDrift.ps1. */
const QUOTA_HELP = {
  family: 'per-vm-quota-requests',
  regional: 'regional-quota-requests',
};

/** What to do for each answer of Azure, as sentences. A refusal and an answer not read are errors.
 * A refusal carries the Microsoft page to follow: help = { title, page }, the page in learn.microsoft.com/azure/quotas. */
function quotaAnswerLines(rows) {
  const out = [];
  for (const r of [].concat(rows ?? []).filter(Boolean)) {
    const regional = r.kind === 'regional' || String(r.family ?? '').toLowerCase() === 'cores';
    const help = regional ? { title: UX.quotaHelpRegional, page: QUOTA_HELP.regional } : { title: UX.quotaHelpFamily, page: QUOTA_HELP.family };
    const v = { quota: String(r.quotaName || r.family || ''), region: String(r.region ?? ''),
      limit: String(r.requestedLimit ?? UX.quotaNoFigure), code: String(r.answerCode ?? ''), page: help.title };
    const fill = (text) => text.replace(/\{(quota|region|limit|code|page)\}/g, (_, k) => v[k]);
    const said = r.status === 'APPROVED' ? 'APPROVED' : (r.status === 'PENDING' ? r.answer : null);
    if (said === 'APPROVED') { out.push({ text: fill(UX.quotaNextApproved), bad: false }); }
    else if (said === 'REFUSED') {
      // The new limit only when the request names one: a sentence never shows a missing figure.
      out.push({ text: [fill(r.answerCode ? UX.quotaNextRefusedCode : UX.quotaNextRefused), fill(UX.quotaNextSupport),
        fill(regional ? UX.quotaNextStepsRegional : UX.quotaNextStepsFamily),
        (r.requestedLimit ?? '') !== '' ? fill(UX.quotaNextLimit) : ''].filter(Boolean).join(' '), bad: true, help });
    }
    else if (said === 'WAITING') { out.push({ text: fill(UX.quotaNextWaiting), bad: false }); }
    else if (said === 'NOTREAD') { out.push({ text: fill(UX.quotaNextNotRead), bad: true }); }
  }
  return out;
}

/** One next-step sentence as HTML: the title of the Microsoft page is a link to it
 * (NO-POPUPS-1: a Learn page opens in a new tab, with noopener). */
function quotaAnswerLineHtml(n) {
  const text = esc(n.text);
  // The address starts with Learn in the markup itself, and the page is only a name of letters and dashes.
  if (!n.help || !/^[a-z-]+$/.test(String(n.help.page ?? ''))) { return text; }
  const title = esc(n.help.title);
  const at = text.indexOf(title);
  if (at < 0) { return text; }
  return `${text.slice(0, at)}<a href="https://learn.microsoft.com/azure/quotas/${esc(n.help.page)}" target="_blank" rel="noopener noreferrer">${title}</a>${text.slice(at + title.length)}`;
}

/** Wait for the engine's quotaAnswer line of each request, or until the time ends. Gives what came. */
async function watchQuotaAnswers(since, ids) {
  const want = new Set([].concat(ids ?? []).map(quotaAnswerKey).filter(Boolean));
  const got = new Map();
  await VmfHelp.watchRun({
    readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
    sinceMs: since,
    // The engine reads for 2 minutes after it files; the page waits longer.
    timeoutMs: 300000,
    pollMs: 5000,
    scan: (events) => {
      for (const e of events) {
        const key = quotaAnswerKey(e.requestId);
        if (String(e.step ?? '') === 'quotaAnswer' && want.has(key)) { got.set(key, e); }
      }
      return got.size >= want.size ? { answered: true } : null;
    },
  });
  return got;
}

/** The answer to Request, as sentences: the quotas filed, and each quota not filed with its reason. */
function quotaResultLines(rows) {
  const list = [].concat(rows ?? []).filter(Boolean);
  if (!list.length) { return { filed: '', notFiled: [], none: UX.quotaPreviewNone }; }
  const name = (r) => String(r.quotaName || r.family || '');
  const filed = list.filter(r => r.status === 'APPROVED' || r.status === 'PENDING');
  const fill = (text, values) => text.replace(/\{(quotas|quota|region|reason)\}/g, (_, k) => values[k]);
  return {
    filed: filed.length ? fill(UX.quotaFiled, { quotas: filed.map(r => `${name(r)} in ${String(r.region ?? '')}`).join(', ') }) : '',
    notFiled: list.filter(r => !filed.includes(r)).map(r => fill(UX.quotaNotFiled,
      { quota: name(r), region: String(r.region ?? ''), reason: r.reason ? VmfHelp.explain(new Error(String(r.reason))) : UX.quotaNoReason })),
    none: '',
  };
}

/* QUOTA-CHECK-SPINNER-1: the State column of one request after Request. The
 * engine's status says only what the request did: APPROVED (Azure approved it
 * at once), PENDING (filed, and Azure has not answered), or not filed. This is
 * the ONE place a later answer of Azure about a filed request goes: a reader
 * of that answer adds it to the row, and this function says it. */
function quotaRequestStateText(r) {
  if (r.status === 'APPROVED') { return UX.quotaStateApproved; }
  if (r.status === 'PENDING') {
    // QUOTA-REQUEST-POLL-1: the answer the engine read.
    if (r.answer === 'APPROVED') { return UX.quotaStateApproved; }
    if (r.answer === 'REFUSED') { return r.answerCode ? UX.quotaStateRefusedCode.replace('{code}', () => String(r.answerCode)) : UX.quotaStateRefused; }
    if (r.answer === 'NOTREAD') { return UX.quotaStateNotRead; }
    if (!r.answer && r.reading) { return UX.quotaStateReading; }
    return UX.quotaStateFiled;
  }
  return UX.quotaStateNotFiled;
}

/** The answer to Request on the page, when the confirmation was closed while it waited. */
function showQuotaResult(result) {
  const said = result.phase === 'done' ? quotaResultLines(result.rows) : { filed: '', notFiled: [result.error], none: '' };
  // QUOTA-REQUEST-POLL-1: and the answer of Azure to each filed request, when it came.
  const next = result.phase === 'done' ? quotaAnswerLines(result.rows) : [];
  const open = result.phase === 'done' ? quotaUnanswered(result.rows) : [];
  const good = [open.length ? said.filed : '', result.reading ? UX.quotaReadingPage : '', said.none,
    ...next.filter(n => !n.bad).map(n => n.text), open.length && !result.reading ? UX.quotaDoneNext : ''].filter(Boolean).join(' ');
  const bad = [...said.notFiled, ...next.filter(n => n.bad).map(n => n.text)];
  $('#ok').textContent = good; $('#ok').style.display = good ? 'block' : 'none';
  $('#err').textContent = bad.join(' '); $('#err').style.display = bad.length ? 'block' : 'none';
}

/** Wait for the engine's answer to Request in the run's activity log, or its failure. */
async function watchQuotaRequest(since) {
  return VmfHelp.watchRun({
    readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
    sinceMs: since,
    // Each request can be retried with a wait between (Invoke-VmfAzOperation).
    timeoutMs: 600000,
    pollMs: 5000,
    scan: (events) => {
      const result = events.find(e => String(e.step ?? '') === 'quotaResult');
      if (result) { return { result }; }
      // One quota's fail line does not end the wait: the result line follows it.
      const failure = events.find(e => (e.outcome === 'fail' || e.outcome === 'refused') && String(e.step ?? '').startsWith('engine'));
      return failure ? { failure } : null;
    },
  });
}

/** Wait for the engine's preview line in the run's activity log, or its failure. */
async function watchQuotaPreview(since, stillWanted) {
  return VmfHelp.watchRun({
    readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
    sinceMs: since,
    timeoutMs: 300000,
    pollMs: 5000,
    // A closed confirmation stops the polling.
    onTick: () => (stillWanted && !stillWanted()) ? { cancelled: true } : null,
    scan: (events) => {
      const preview = events.find(e => String(e.step ?? '') === 'quotaPreview');
      if (preview) { return { preview }; }
      // A family whose record names no subscription writes its own fail line
      // and the preview still follows, so only the engine failing ends the wait.
      const failure = events.find(e => (e.outcome === 'fail' || e.outcome === 'refused') && String(e.step ?? '').startsWith('engine'));
      return failure ? { failure } : null;
    },
  });
}

/** Close the confirmation (rule 11): Cancel, Escape, or a click outside it. */
function closeQuotaConfirm() {
  quotaConfirm = null;
  quotaConfirmTurn++;
  document.removeEventListener('keydown', quotaConfirmKey);
  drawQuotaConfirm();
}
function quotaConfirmKey(ev) {
  if (ev.key === 'Escape' && quotaConfirm) { closeQuotaConfirm(); }
}

/* QUOTA-CHECK-SPINNER-1: a sentence with {when}, as HTML, the time in a span
 * that tickAgo updates. "Checked 5s ago" stood still on the lab install. */
function agoHtml(text, iso) {
  const [before, ...rest] = String(text).split('{when}');
  return `${esc(before)}<span data-ago="${esc(iso)}">${esc(ago(iso))}</span>${esc(rest.join('{when}'))}`;
}
/** Every time on the page, again, from its own data-ago. Once a second, as on the Migrations page. */
function tickAgo() {
  document.querySelectorAll('[data-ago]').forEach(s => { s.textContent = ago(s.dataset.ago); });
}

/* QUOTA-CHECK-SPINNER-1 (lab walk 2026-11-17): the quota belongs to the
 * PLAN. One check covers every wave, the Request a quota increase card shows the
 * plan-wide table, and each wave says in one line what it needs of each quota.
 *
 * Which quota is short is the engine's answer, never the page's: a record
 * blocked on its family (quota-shortfall) or on the region (claimRegionalShort),
 * and a record whose increase request waits (QUOTA_REQUESTED keeps its
 * blockReason; claimRegionalRequested) - a request that waits is not more
 * quota. The figures are the record's (capacity-claim v15): all waves need is
 * demand.familyVcpus or demand.regionalVcpus, a wave needs the vCPUs of its own
 * records (demand.vcpus, demand.regionalAdds). A figure the record does not
 * give is null, never 0. Only the newest check of each quota counts. */
function quotaShortFamily(d) {
  const st = String(d?.state ?? '').toUpperCase();
  return d?.blockReason === 'quota-shortfall' && (VmfHelp.claimBlocked(st) || st === 'QUOTA_REQUESTED');
}
function quotaShortRegion(d) {
  return VmfHelp.claimRegionalShort(d) || VmfHelp.claimRegionalRequested(d);
}
/* The quotas of these records, one entry for each quota family and region and
 * one for the Total Regional vCPUs of each region, from the newest check of
 * each. A record for a size Azure refused (sku-restricted, size-missing) reads
 * no family quota, and a released record is history. */
function quotaGroups(docs) {
  const num = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v))) ? null : Number(v);
  const at = (d) => Date.parse(d?.quota?.checkedUtc ?? 0) || 0;
  const groups = new Map();
  const add = (key, d, base, need, short) => {
    const g = groups.get(key);
    if (!g || at(d) > g.at) { groups.set(key, { ...base, at: at(d), need, short }); return; }
    if (at(d) === g.at) {
      g.need = (g.need === null || need === null) ? null : g.need + need;
      g.short = g.short || short;
    }
  };
  for (const d of docs) {
    const st = String(d?.state ?? '').toUpperCase();
    if (st === 'RELEASED') { continue; }
    if (VmfHelp.claimBlocked(st) && ['sku-restricted', 'size-missing'].includes(d.blockReason)) { continue; }
    const q = d.quota || {}, dem = d.demand || {};
    const sub = String(d.subscriptionId ?? ''), region = String(d.region ?? '');
    if (d.vmFamily) {
      add(`f|${sub}|${region}|${d.vmFamily}`, d, { regional: false, quota: String(q.name || d.vmFamily), region,
        limit: num(q.limit), used: num(q.used), planNeed: num(dem.familyVcpus) }, num(dem.vcpus), quotaShortFamily(d));
    }
    add(`r|${sub}|${region}`, d, { regional: true, quota: UX.capRegionalName, region,
      limit: num(q.regionalLimit), used: num(q.regionalUsed), planNeed: num(dem.regionalVcpus) }, num(dem.regionalAdds), quotaShortRegion(d));
  }
  // Rows with a problem first: short, then not listed, then the ones with room.
  const rank = (g) => (g.short ? 0 : g.limit === null ? 1 : 2);
  return [...groups.values()]
    .map(({ at: _at, ...g }) => ({ ...g,
      shortBy: (g.limit === null || g.used === null || g.planNeed === null) ? null : Math.max(0, g.planNeed - (g.limit - g.used)) }))
    .sort((a, b) => (rank(a) - rank(b)) || (Number(a.regional) - Number(b.regional)) || `${a.region}|${a.quota}`.localeCompare(`${b.region}|${b.quota}`));
}

/** The rows of the plan-wide table on the card: every quota the plan uses. */
function planQuotaRows() {
  return quotaGroups([...waveDocs.values()].flat());
}

/* What one wave needs of each quota, one line each, from its own records. The
 * Total Regional vCPUs line is said only when that quota is short: a wave always
 * uses its region, and a line for each would say nothing. */
function waveQuotaLines(wave) {
  const fig = (v) => (v === null ? UX.capNoFigure : String(v));
  return quotaGroups(waveDocs.get(wave) ?? [])
    .filter(g => !g.regional || g.short)
    .map(g => {
      const text = g.short ? UX.capLineShort : g.limit === null ? UX.capLineUnlisted : UX.capLineEnough;
      return { text: text.replace(/\{(n|quota|region|s)\}/g, (_, k) => ({ n: fig(g.need), quota: g.quota, region: g.region, s: fig(g.shortBy) })[k]),
        cls: g.short ? 'bad' : g.limit === null ? '' : 'good' };
    });
}

/* The sizes of this wave that Azure refused, each with its subscription (by the
 * name the page shows) and its region, then what to do, once. '' when none. */
function waveRefusedText(wave) {
  const refused = (waveDocs.get(wave) ?? []).filter(d => VmfHelp.claimBlocked(String(d.state ?? '').toUpperCase()) && ['sku-restricted', 'size-missing'].includes(d.blockReason));
  if (!refused.length) { return ''; }
  const said = [...new Set(refused.map(d => {
    const fill = (text) => text.replace(/\{(size|subscription|region)\}/g, (_, k) =>
      ({ size: String(d.size ?? ''), subscription: subName(d.subscriptionId), region: String(d.region ?? '') })[k]);
    return d.subscriptionId ? fill(UX.capSizeBlocked) : fill(UX.capSizeBlockedNoSub);
  }))].sort();
  return [...said, UX.capSizeBlockedDo].join(' ');
}

/* The wave's part of the quota: while a check runs, the spinner. After it: the
 * sizes Azure refused, the answer of the check when it is not about the
 * figures (no record for a machine, no plan to read, no machine changes size,
 * an error), and a line for each quota. No engine text, in the row or in a
 * hover. With nothing to say, "Not checked yet". */
function quotaStateHtml(name) {
  if (checkingWaves.has(name)) {
    return `<span class="cap-answer working"><span class="spin"></span>${esc(UX.capWaveChecking)}</span>`;
  }
  const lines = [];
  const refused = waveRefusedText(name);
  if (refused) { lines.push({ text: refused, cls: 'bad' }); }
  const kept = capAnswers.get(name);
  if (kept && kept.at === (lastChecked.get(name) ?? null)) { lines.push(kept); }
  lines.push(...waveQuotaLines(name));
  if (!lines.length) { lines.push({ text: UX.capNotChecked, cls: '' }); }
  return lines.map(l => `<span class="cap-answer${l.cls ? ' ' + esc(l.cls) : ''}">${esc(l.text)}</span>`).join('');
}

/* QUOTA-CHECK-SPINNER-1: the quota row of a wave, drawn again by drawQuotaRow.
 * It has no button: one check covers the plan, from the card. It is not a
 * label (a label passes a click on its words to a control in it). */
function quotaControl(name) {
  return `<div class="quota-row" data-caprow="${esc(name)}"><span class="lv" title="${esc(UX.quotaRowTip)}">${esc(UX.quotaRowLabel)}</span>
          ${quotaStateHtml(name)}</div>`;
}

/** QUOTA-CHECK-SPINNER-1: draw one wave's quota row again. */
function drawQuotaRow(wave) {
  const row = document.querySelector(`[data-caprow="${cssEscape(wave)}"]`);
  if (row) { row.outerHTML = quotaControl(wave); }
}

/* QUOTA-CHECK-SPINNER-1: Check the quota on the card checks every wave that has
 * machines, at once (the engine names the wave in each answer, QUOTA-TRUTH-1).
 * QUOTA-TRUTH-1, measured against Azure 2026-09-24: the engine checks the SAVED
 * plan, so changes not saved are saved first, once. Save cannot come first by
 * hand: inside the flow, Save also moves on to the next step. */
async function checkPlan() {
  const waves = waveNames().filter(n => membersOf(n).length);
  if (!waves.length || checkingWaves.size) { return; }
  if (canEdit && !DEMO_MODE && dirty()) {
    try {
      const saved = await writeLayout();
      $('#ok').textContent = UX.capSavedFirst;
      if ((saved?.ApprovalsInvalidated ?? []).length) { $('#ok').textContent += ' ' + UX.savedApprovals.replace('{waves}', saved.ApprovalsInvalidated.join(', ')); }
      $('#ok').style.display = 'block';
    } catch (e) {
      $('#err').textContent = VmfHelp.explainAction(e);
      $('#err').style.display = 'block';
      return;
    }
  }
  await Promise.all(waves.map(w => checkCapacity(w)));
  // The checks overlap, and only the newest read fills the page (claimsTurn):
  // a wave whose own read was dropped drew its row from the records before.
  // So every row and the card are drawn again, from the records now held.
  for (const w of waveNames()) { drawQuotaRow(w); }
  drawQuotaCard();
}
// WAVE-FLOW-1: is any size family short of quota? Null until the claims are read.
let quotaShort = false;
// QUOTA-NOCHECK-1: has ANY quota actually been read? An empty capacity folder
// used to fall through to "Every size family has enough quota" - the all-clear
// printed when nothing was checked at all, which is the state of every new plan.
let quotaChecked = false;
// QUOTA-BUTTON-1: waves whose quota WAS checked and Azure listed no figure for -
// the s-suffix v6 listing gap. Neither "enough" nor "not checked" is true of them.
let unlistedWaves = new Set();
// REGIONAL-VCPU-QUOTA-1: the waves, and the regions, whose records the engine
// blocked on the Total Regional vCPUs quota. Read from blockReason - the engine
// judged it, and the page does not judge the figures again.
let regionalShortWaves = new Set();
let regionalShortRegions = new Set();
// WAVE-FLOW-1: is this page being shown AS step 2 of the flow? The same screen
// is also reached from a migration later, to change waves after the plan
// exists. Two entrances, one screen, and only the buttons and the strip differ.
const inFlow = () => new URLSearchParams(location.search).has('flow');
const demoState = new Map(); // ?demo: the same, staged in the browser

/* PAGE-LOAD-3: `held` is the load's one call for the run. With none, the
 * quota records are ONE call of their own (store/docs): the reservation watch
 * reads them every 6 seconds. What the call cannot say is read as before. */
/* QUOTA-CHECK-SPINNER-1: Check the quota checks every wave at once, and each
 * check ends with this read, so reads overlap. Each read builds everything it
 * fills in its own variables (they shadow the page's), and the page takes them
 * all together when the read is complete - and only from the newest read
 * started (claimsTurn). Two reads that filled the page's maps as they went
 * counted a machine twice in generalByWave, and a read that failed emptied
 * what a newer read had just filled. Before, a row drawn while a read waited
 * showed nothing. */
async function loadClaims(held) {
  const turn = ++claimsTurn;
  const read = await (async () => {
  let claims = new Map();
  let billingWaves = new Set();
  let generalByWave = new Map();
  // A failed or skipped read must not leave an earlier "checked" standing.
  let quotaChecked = false;
  let unlistedWaves = new Set();
  let regionalShortWaves = new Set();
  let regionalShortRegions = new Set();
  let quotaAccess = new Map();
  let quotaShort = false;
  const pack = (ok, rest) => ({ ok, claims, billingWaves, generalByWave, quotaChecked, unlistedWaves,
    regionalShortWaves, regionalShortRegions, quotaAccess, quotaShort, ...rest });
  if (DEMO_MODE) {
    for (const [w, v] of demoState) { claims.set(w, v); if (v === 'held') billingWaves.add(w); }
    return pack(true, { waveDocs: new Map(), lastChecked: new Map() });
  }
  try {
    const prefix = `${runPrefix()}/capacity/`;
    if (held === undefined) {
      try { held = await VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix, depth: 1, read: ['*.json'] }); }
      catch { held = null; }
    }
    const listed = VmfHelp.heldList(held, prefix);
    const names = listed ? listed.names : await blobList(prefix);
    // STORE-READ-2: paced. The reservation watch re-runs this every 6 seconds
    // for up to 5 minutes, so an unbounded fan-out here was multiplied by ~50.
    const docs = (await VmfHelp.mapLimited(names.filter(n => n.endsWith('.json')), n => heldOrFetch(held, n))).filter(Boolean);
    // WAVE-FLOW-1: the same documents say whether any family is SHORT of
    // quota, which is what decides whether there is an increase to ask for.
    // This was read on the capacity step and thrown away here.
    // A reading with no limit is the s-suffix listing gap - not a check.
    quotaChecked = docs.some(d => d.quota && d.quota.limit !== null && d.quota.limit !== undefined);
    unlistedWaves = new Set(docs.filter(d => String(d.state).toUpperCase() === 'QUOTA_VERIFIED' &&
      (!d.quota || d.quota.limit === null || d.quota.limit === undefined)).map(d => d.wave));
    quotaAccess = quotaAccessFrom(docs);
    quotaShort = docs.some(d => {
      const q = d.quota || {};
      if (q.limit === null || q.limit === undefined || q.used === null || q.used === undefined) { return false; }
      return (Number(q.limit) - Number(q.used)) < Number((d.demand || {}).vcpus || 0);
    }) || docs.some(d => VmfHelp.claimBlocked(String(d.state).toUpperCase()) && d.blockReason === 'regional-quota-shortfall');
    const anyReservable = new Map();   // wave -> does any claim have a machine a reservation can hold
    // QUOTA-CHECK-SPINNER-1: built here, and given to the page when the read is complete.
    const byWave = new Map();
    const checkedAt = new Map();
    for (const d of docs) {
      // QUOTA-CHECK-SPINNER-1: the row draws its result and its table from these.
      if (!byWave.has(d.wave)) { byWave.set(d.wave, []); }
      byWave.get(d.wave).push(d);
      const at = d.quota && d.quota.checkedUtc;
      if (at && (!checkedAt.has(d.wave) || Date.parse(at) > Date.parse(checkedAt.get(d.wave)))) { checkedAt.set(d.wave, at); }
      const st = String(d.state).toUpperCase();
      // REGIONAL-QUOTA-BOTH-1: a record blocked on its family keeps that reason,
      // and the engine records beside it that the region is short too. The card
      // names the region for both, because Request an increase asks for it: one
      // rule, the one the engine's request reads (REGIONAL-QUOTA-BOTH-PAGE-1).
      if (VmfHelp.claimRegionalShort(d) && d.region) { regionalShortRegions.add(String(d.region)); }
      // The wave gets the regional words only when the region is all that is
      // short. A wave whose family is short keeps the family words.
      if (VmfHelp.claimBlocked(st) && d.blockReason === 'regional-quota-shortfall') { regionalShortWaves.add(d.wave); }
      // A wave has several claims - one per size and zone - so the WORST
      // answer wins. One size still creating means the wave is not reserved,
      // and one blocked means it is not going to be.
      // RESERVING-STUCK-1: a RESERVING claim nobody is making any more is
      // not "Reserving...". It may bill, so it offers Release.
      // It outranks Not reserved, because it is the one that may bill.
      const stuck = VmfHelp.claimReservingStuck(d);
      // AVSET-RESERVE-1: the engine rule (Test-VmfClaimReservable), held to
      // the same cases: a claim that SAYS, in a whole number, that none of its
      // machines is reservable needs no reservation. Any other claim does.
      const dem = d.demand || {};
      const reservableN = claimCount(dem.reservableInstances);
      const reservable = reservableN === null || reservableN > 0;
      // A blocked claim with no reservable machine is a QUOTA answer, not a
      // reservation that failed - the quota row says it, and the engine
      // refuses to reserve the rest of the wave while it stands.
      const blockedHere = VmfHelp.claimBlocked(st) && (reservable || d.blockReason === 'reservation-failed');
      if (stuck) { claims.set(d.wave, 'unconfirmed'); }
      else if (blockedHere && claims.get(d.wave) !== 'unconfirmed') { claims.set(d.wave, 'blocked'); }
      else if (st === 'RESERVING' && !['blocked', 'unconfirmed'].includes(claims.get(d.wave))) { claims.set(d.wave, 'working'); }
      else if (['RESERVED', 'CONSUMED'].includes(st) && !claims.has(d.wave)) { claims.set(d.wave, 'held'); }
      // WAVE-EDIT-RESERVE-1: a wave with ANY claim that bills and can be
      // released, whatever its worst answer - a partly blocked wave keeps
      // the parts it did reserve, and those bill.
      if (['RESERVED', 'CONSUMED'].includes(st)) { billingWaves.add(d.wave); }
      if (stuck) { billingWaves.add(d.wave); }
      if (!anyReservable.has(d.wave)) { anyReservable.set(d.wave, false); }
      if (reservable) { anyReservable.set(d.wave, true); }
      const instancesN = claimCount(dem.instances);
      if (reservableN !== null && instancesN !== null) {
        // CRG-MOVE-DEMAND-1: a machine that stays in its own capacity
        // reservation group is not in an availability set, and it moves on
        // its own group - so it is not counted with them.
        const own = Array.isArray(dem.ownGroupVmIds) ? dem.ownGroupVmIds.filter(x => typeof x === 'string' && x).length : 0;
        const off = Math.max(0, instancesN - Math.max(0, reservableN) - own);
        generalByWave.set(d.wave, (generalByWave.get(d.wave) ?? 0) + off);
      }
    }
    // CRG-MOVE-DEMAND-1: the groups this migration made - the engine's
    // Get-VmfProductReservationGroupIds, read from the same records.
    const productGroups = new Set(docs.flatMap(d => [d.reservation?.groupId, d.reservationAsked?.groupId])
      .filter(g => typeof g === 'string' && g).map(g => g.toLowerCase()));
    // A wave with claims and nothing reservable in any of them needs no
    // reservation - when the PLAN agrees that no machine of it can use the
    // wave's reservation (an availability set, or its own capacity
    // reservation group). The records can be a partial set while a quota check
    // writes them one by one, and a Reserve button hidden then would hide the
    // only way to reserve the ordinary machines. Any other answer above is
    // stronger, and stays.
    for (const [w, any] of anyReservable) {
      if (!any && !claims.has(w) && waveNoneReservable(w, productGroups)) { claims.set(w, 'general'); }
    }
    return pack(true, { waveDocs: byWave, lastChecked: checkedAt });
  } catch (e) { return pack(false, { claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), waveDocs: new Map(), lastChecked: new Map() }); }   // a read failure must not hide the button
  })();
  // A newer read started while this one waited: the newer one decides.
  if (turn !== claimsTurn) { return read.ok; }
  ({ claims, billingWaves, generalByWave, quotaChecked, unlistedWaves, regionalShortWaves, regionalShortRegions, quotaAccess, waveDocs, lastChecked } = read);
  // A failed read says nothing about the quota, so the request card keeps what it had.
  if (read.ok) { quotaShort = read.quotaShort; }
  return read.ok;
}

/* The one control on this page that spends money.
 *
 * It refuses while the plan is dirty: a reservation is sized from the wave AS
 * SAVED, so reserving against unsaved levers would hold capacity for a shape
 * that does not exist yet.
 *
 * A native prompt, like every other action on this page that has to be
 * confirmed - it states the cost, and Cancel and Escape both return null. */
/* EVAL-H14: every page that starts an engine job watches for a refusal.
 *
 * The engine refuses AFTER the POST returns 202, so a page that reports
 * success on the reply is reporting that a job was accepted and calling it a
 * result. migrations.html has its own watcher over the event log; this one
 * watches the CAPACITY CLAIM as well, because for this operation the claim is
 * the authoritative answer - all-or-nothing means a half-done run leaves no
 * claim at all, which the event log alone would not make obvious.
 *
 * The two watchers should become one in help.js. Left apart deliberately for
 * now: merging them means changing the run page's failure handling in the
 * same breath as adding a button, and that is two changes. */
/* AVSET-RESERVE-1: a count from a quota record, or null when it does not say
 * one. Only a whole number says - the same rule as Get-VmfClaimDemandCounts,
 * held to the rule cases in tests/fixtures/reserve-nothing-events.json. */
function claimCount(v) {
  if (typeof v === 'number') { return Number.isInteger(v) ? v : null; }
  if (typeof v === 'string' && /^\s*[+-]?\d+\s*$/.test(v)) { return parseInt(v, 10); }
  return null;
}

/* AVSET-RESERVE-1: does the saved plan give no moving machine of this wave a
 * place in the wave's reservation? False for a wave with none - unknown is not
 * yes. The engine's one rule, Test-VmfEntryReservable: a machine in an
 * availability set, or (CRG-MOVE-DEMAND-1) one the assessment found in a
 * capacity reservation group this migration did not make - its own group,
 * which the move keeps it in. A plan entry whose assessment found no group is
 * reservable. productGroups: the groups of this migration, lower case. */
function waveNoneReservable(wave, productGroups) {
  const moving = entries.filter(e => e.wave === wave && e.path === 'A');
  const ownGroup = (a) => {
    if (!a) { return false; }
    // No group (null) is not a string, so not its own group.
    const g = a.capacityReservationGroupId;
    return typeof g === 'string' && g !== '' && !(productGroups && productGroups.has(g.toLowerCase()));
  };
  return moving.length > 0 && moving.every(e => Boolean(e.assessment?.availabilitySetId) || ownGroup(e.assessment));
}
/* What the log says about a Reserve run on this wave, or null for "the claim
 * decides". A failure or a refusal is the news a person must see, so it wins.
 *
 * AVSET-RESERVE-1: a wave whose machines are ALL in availability sets has
 * no machine a reservation can hold, and no claim is ever coming, so waiting for one timed
 * out and said "still running". The engine writes ONE event for it, after
 * every cell, with the wave and a code. This used to look for words that only
 * the claim note carried - it never matched. The cases both sides are held to
 * are in tests/fixtures/reserve-nothing-events.json. */
function reserveScan(events, wave) {
  let failure = null, nothing = null;
  for (const e of events) {
    const step = String(e.step ?? '');
    // LOG-SAYS-WHY-1: a REFUSAL counts here too. This panel answers "why
    // did my wave not start", and the commonest answer is a gate saying
    // no on purpose. Reading only 'fail' would have made this fix HIDE
    // the very reason it exists to show.
    if ((e.outcome === 'fail' || e.outcome === 'refused')
        && ['odcr', 'capacity', 'engine'].some(p => step.startsWith(p))) { failure = e; }
    if (step === 'odcr' && e.code === 'nothingReservable' && e.wave === wave) { nothing = e; }
  }
  if (failure) { return { failure }; }
  return nothing ? { nothing } : null;
}

/* AVSET-RESERVE-1: "reserved" for a wave that holds a reservation, and how
 * many of its machines move on general capacity, so nobody reads a mixed wave
 * as fully reserved. */
function reserveDoneText(wave) {
  const done = UX.reserveDone.replace('{wave}', wave);
  const n = generalByWave.get(wave) ?? 0;
  if (n <= 0) { return done; }
  return done + ' ' + (n === 1 ? UX.reserveDoneGeneralOne : UX.reserveDoneGeneral.replace('{n}', String(n)));
}

// NOT watchForRefusal, which is what this was called. It watches a capacity
// CLAIM and reads the event log only as a faster way to hear bad news - a
// different question from the one the run page and the wizard ask, and sharing
// their name hid that.
async function watchReservation(wave) {
  const verdict = await VmfHelp.watchRun({
    readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
    sinceMs: Date.now() - 5000,
    timeoutMs: 300000,
    pollMs: DEMO_MODE ? 200 : 6000,
    // The claim is the real answer; the log is only ever faster.
    onTick: async () => {
      await loadClaims();
      drawEditorWhenFree();           // show Reserving... while it runs
      const st = claims.get(wave);
      // BLOCKED is written when Azure refuses; a claim Azure did not
      // confirm in time shows Not confirmed. Both are terminal here.
      return (st === 'held' || st === 'blocked' || st === 'unconfirmed') ? { claim: st } : null;
    },
    scan: (events) => reserveScan(events, wave),
  });

  if (verdict && verdict.claim === 'held') {
    $('#ok').textContent = reserveDoneText(wave);
    return;
  }
  if (verdict && verdict.claim === 'unconfirmed') {
    $('#ok').style.display = 'none';
    $('#err').textContent = UX.reserveUnconfirmedSaid.replace('{wave}', wave);
    $('#err').style.display = 'block';
    return;
  }
  if (verdict && verdict.claim === 'blocked') {
    $('#ok').style.display = 'none';
    $('#err').textContent = UX.reserveFailed.replace('{wave}', wave) + UX.reserveBlockedTip;
    $('#err').style.display = 'block';
    return;
  }
  if (verdict && verdict.nothing) {
    $('#ok').textContent = UX.reserveNothing.replace('{wave}', wave);
    render();
    return;
  }
  if (verdict && verdict.failure) {
    $('#ok').style.display = 'none';
    $('#err').textContent = UX.reserveFailed.replace('{wave}', wave) + (verdict.failure.detail ?? '');
    $('#err').style.display = 'block';
    render();
    return;
  }
  // Neither held nor refused inside the window. Say that, rather than leaving
  // a message that claims something finished.
  $('#ok').textContent = UX.reserveSlow.replace('{wave}', wave);
  render();
}

// The event log, as objects. blobFetch already knows the container, the
// token scope and the version header - a second fetch here would be a
// second place to keep those right.
// EVENTLOG-1: and the log can be in parts once it has filled one. help.js
// walks them, so this asks for the name it always asked for.
async function blobLines(path) {
  if (DEMO_MODE) { return []; }
  return VmfHelp.readLogEvents(p => blobFetch(p, { asText: true }), path);
}

/* REACH-2: ask the capacity gate what it would say about this wave.
 *
 * READ-ONLY - it reads the wave's claims and applies the gate, calls nothing in
 * Azure and writes nothing, so any role may ask. It is not gated on canEdit for
 * that reason: a viewer being unable to SEE whether a wave will fit would hide
 * a fact, not protect one.
 *
 * The gate asked for is the wave's OWN setting. Asking BestEffort of a wave the
 * operator set to Reserved would answer a question nobody asked and pass when
 * the real gate would refuse.
 *
 * The engine's Detail is precise and is not a sentence - "2 claim(s) below the
 * BestEffort gate: D2s_v6@centralus [PLANNED]". The headline is a sentence.
 * QUOTA-CHECK-SPINNER-1: and the Detail is no longer the tooltip either - it
 * was the only explanation of "not enough". The table under the
 * row says what is short, from the records.
 */
/* QUOTA-BUTTON-1: wait for the engine's quota check to finish. Test-VmfQuota
 * writes ONE `capacity` event when it is done - ok, or warn when something is
 * short - and an engine that could not run writes a failure. Anything before
 * `since` is somebody else's news. */
/* QUOTA-TRUTH-1: and only THIS wave's answer. Two checks started together
 * each took the first "claims=" line they saw, so the second wave read the
 * first wave's answer. The engine now names the wave in that line. */
function quotaCheckDone(e, wave) {
  if (String(e.step ?? '') !== 'capacity' || !['ok', 'warn'].includes(e.outcome)) { return false; }
  const words = String(e.detail ?? '').split(' ');
  return words[0].startsWith('claims=') && words.includes(`wave=${wave}`);
}
async function watchQuotaCheck(since, wave) {
  return VmfHelp.watchRun({
    readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
    sinceMs: since,
    timeoutMs: 300000,
    pollMs: 5000,
    scan: (events) => {
      for (const e of events) {
        const step = String(e.step ?? '');
        if (quotaCheckDone(e, wave)) { return { done: e }; }
        // LOG-SAYS-WHY-1: a refusal ends the check too, and its reason is the answer.
        if ((e.outcome === 'fail' || e.outcome === 'refused')
            && ['capacity', 'engine'].some(p => step.startsWith(p))) { return { failure: e }; }
      }
      return null;
    },
  });
}

/* RESERVE-COVER-1: the machines the capacity gate found with no quota record,
 * as one sentence, or '' when there are none. Each is its name and its size. */
function uncoveredText(list) {
  const named = [].concat(list ?? []).filter(m => m && m.Name)
    .map(m => (m.Size ? `${m.Name} (${m.Size})` : String(m.Name)));
  if (!named.length) { return ''; }
  return (named.length === 1 ? UX.capUncoveredOne : UX.capUncovered).replace('{machines}', named.join(', '));
}

async function checkCapacity(wave) {
  const gate = (layout.get(wave) || {}).capacityGate || 'BestEffort';
  // QUOTA-CHECK-SPINNER-1: the answer, kept for the check it belongs to. While
  // the check runs the row and the card show the spinner, whatever draws them.
  let said = null;
  checkingWaves.add(wave);
  capAnswers.delete(wave);
  drawQuotaRow(wave);
  drawQuotaCard();
  try {
    /* QUOTA-BUTTON-1: ASK AZURE, then read the answer.
     *
     * This called only the READ of the wave's stored quota records - and saving
     * the waves clears those, because they described the waves as they were.
     * So on a plan somebody had just arranged, the button found no records and
     * said "The quota is not enough", in red, in about a second, having asked
     * nobody. The check itself is the engine's: it reads the SKU catalog and
     * the quota usage in Azure, reserves nothing, and never replaces a record
     * of a reservation. A person who may not start engine work still gets the
     * read, and the read now says "not checked yet" when that is the truth. */
    if (canEdit && !DEMO_MODE) {
      // QUOTA-TRUTH-1: the engine checks the SAVED plan. checkPlan saves the
      // changes once, before it starts the check of each wave.
      const since = Date.now() - 5000;
      await apiPost(`runs/${runSeg()}/engine/quotacheck`, runBody({ wave }));
      const verdict = await watchQuotaCheck(since, wave);
      if (!verdict) { throw new Error(UX.capNoAnswer); }
      if (verdict.failure) { throw new Error(VmfHelp.explain(new Error(String(verdict.failure.detail ?? '')))); }
      /* QUOTA-TRUTH-1: zero records is an ANSWER. It was read back as "no
       * records", and shown as "Not checked yet" straight after a check. */
      if (String(verdict.done.detail ?? '').split(' ')[0] === 'claims=0') {
        said = { text: UX.capNothing, cls: '' };
        return;
      }
    }
    // PAGE-WAIT-1: the gate's answer and the records are read together.
    const [r] = await Promise.all([
      apiGet(`runs/${runSeg()}/waves/${encodeURIComponent(wave)}/capacity?gate=${encodeURIComponent(gate)}${runQuery('&')}`),
      loadClaims(),
    ]);
    // CLICKS-LOST-1: the plan-wide quota panel reads the same records, so it
    // is drawn again with them (in finally). It said "No quota has been checked
    // for this plan yet" beside a wave that had just said "The quota is enough".
    const pass = r.Pass ?? r.pass;
    const detail = String(r.Detail ?? r.detail ?? '');
    // No records is NOT a verdict. It was shown as "not enough", in red.
    const unchecked = !pass && /no quota records/i.test(detail);
    // RESERVE-COVER-2: a gate with no plan to read measured nothing.
    const noPlan = !pass && /plan could not be read/i.test(detail);
    // RESERVE-COVER-1: the gate names the machines that have no quota record.
    // That is not a quota that is too small, so it is not said as one.
    const uncovered = pass ? '' : uncoveredText(r.Uncovered ?? r.uncovered);
    // QUOTA-CHECK-SPINNER-1: short or enough is said by the lines of the wave,
    // from the records. Only an answer that is not about the figures is kept.
    said = unchecked ? { text: UX.capNotChecked, cls: '' } : noPlan ? { text: UX.capNoPlan, cls: '' }
      : uncovered ? { text: uncovered, cls: 'bad' } : null;
  } catch (e) {
    // No time beside an error: the time would be of an earlier check.
    said = { text: VmfHelp.explainAction(e) || UX.capNoAnswer, cls: 'bad' };
  } finally {
    checkingWaves.delete(wave);
    if (said) { capAnswers.set(wave, { ...said, at: lastChecked.get(wave) ?? null }); }
    drawQuotaRow(wave);
    drawQuotaCard();
  }
}

function reserveCapacity(wave, btn) {
  // POPUP-1: the note is asked for IN the page. A browser prompt box could
  // not be styled, could not refuse an empty answer beside the field, and
  // could not be cancelled with Escape.
  VmfHelp.confirmInPlace(btn, { ask: UX.reserveAsk.replace('{wave}', wave),
    field: { placeholder: UX.reserveNoteHint, required: true, missing: UX.reserveNoNote },
    yes: UX.reserveYes, cancel: UX.cancel, under: '.levers' }, (note) => reserveCapacityNow(wave, btn, note));
}

async function reserveCapacityNow(wave, btn, note) {
  $('#err').style.display = 'none'; $('#ok').style.display = 'none';
  btn.disabled = true; btn.textContent = UX.reserveBusy;
  try {
    // ?demo stages the SEQUENCE Azure actually goes through - reserving,
    // then reserved - because a demo that answers instantly teaches that
    // the real one does, and it does not: creating a reservation takes
    // minutes. Short enough to watch, long enough to be honest.
    if (DEMO_MODE) {
      demoState.set(wave, 'working');
      setTimeout(() => demoState.set(wave, 'held'), 6000);
    }
    else { await apiPost(`runs/${runSeg()}/engine/reserve`, runBody({ wave, note: note.trim() })); }
    // THE POST RETURNS 202 AND NOTHING ELSE. The engine runs the reservation
    // in a container afterwards, so the reply says the job was ACCEPTED and
    // says nothing about whether capacity was held. Reading a result out of
    // it was fiction - and New-VmfWaveReservation is all-or-nothing per
    // wave, so a run that fails halfway RELEASES what it took and leaves
    // nothing. The claim is the only honest answer, so wait for it.
    $('#ok').textContent = UX.reserveStarted.replace('{wave}', wave);
    $('#ok').style.display = 'block';
    await watchReservation(wave);
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
  } finally {
    btn.disabled = false; btn.textContent = UX.reserveBtn;
    render();
  }
}

/* WAVE-EDIT-RESERVE-1: release a wave's reservation before it runs. The same
 * shape as reserving: a note asked for in the page (Cancel and Escape close
 * it), an engine job that answers 202, and the CLAIM as the only honest answer
 * - so the page waits for the claim to stop reading as held. */
function releaseCapacity(wave, btn) {
  VmfHelp.confirmInPlace(btn, { ask: UX.releaseAsk.replace('{wave}', wave),
    field: { placeholder: UX.releaseNoteHint, required: true, missing: UX.releaseNoNote },
    yes: UX.releaseBtn, cancel: UX.cancel, under: '.levers' }, (note) => releaseCapacityNow(wave, btn, note));
}

async function releaseCapacityNow(wave, btn, note) {
  $('#err').style.display = 'none'; $('#ok').style.display = 'none';
  btn.disabled = true; btn.textContent = UX.releaseBusy;
  try {
    if (DEMO_MODE) { setTimeout(() => demoState.delete(wave), 3000); }
    else { await apiPost(`runs/${runSeg()}/engine/release`, runBody({ wave, note: note.trim() })); }
    $('#ok').textContent = UX.releaseStarted.replace('{wave}', wave);
    $('#ok').style.display = 'block';
    // The same watcher as reserving: a read that fails is not an answer, and
    // the engine's refusal or failure is read from the log, not waited out.
    const verdict = await VmfHelp.watchRun({
      readLines: () => blobLines(`${runPrefix()}/logs/events.jsonl`),
      sinceMs: Date.now() - 5000,
      timeoutMs: 300000,
      pollMs: DEMO_MODE ? 1000 : 6000,
      onTick: async () => ((await loadClaims()) && !billingWaves.has(wave)) ? { released: true } : null,
      scan: (events) => {
        const bad = [...events].reverse().find(e => (e.outcome === 'fail' || e.outcome === 'refused') && String(e.step ?? '').startsWith('odcr'));
        return bad ? { failure: bad } : null;
      },
    });
    if (verdict && verdict.released) { $('#ok').textContent = UX.releaseDone.replace('{wave}', wave); }
    else if (verdict && verdict.failure) {
      $('#ok').style.display = 'none';
      $('#err').textContent = UX.releaseFailed.replace('{wave}', wave) + (verdict.failure.detail ?? '');
      $('#err').style.display = 'block';
    }
    else { $('#ok').textContent = UX.releaseSlow.replace('{wave}', wave); }
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e);
    $('#err').style.display = 'block';
  } finally {
    render();
  }
}

/* Write the layout on screen to the plan. The Save button uses it, and so does
 * the quota check (QUOTA-TRUTH-1), which must check the waves as shown. */
async function writeLayout() {
  // WAVE-EDIT-RUNNING-1: a running wave sends its machines and NO settings. A
  // machine can hold its own value (a decision's per-machine answer), and the
  // engine refuses any change to a running wave - so a value sent for it could
  // refuse a save of ANOTHER wave. A setting left out is not written.
  // WAVE-LEVER-OVERRIDE-1: every other wave sends what its card shows AND the
  // settings the person changed on it, each with the value the card showed
  // (changed). A machine that stays in its wave is written only for those;
  // a machine joining the wave takes its card; a decision is never written over.
  const waves = [...layout.entries()].map(([name, w]) => waveMigrating(name) ? { name, vmIds: w.vmIds } : ({
    name, capacityGate: w.capacityGate || 'BestEffort',
    requireApproval: w.requireApproval,
    onDDataFound: w.onDDataFound,
    keepSnapshotDays: w.keepSnapshotDays,
    throttle: w.throttle,
    vmIds: w.vmIds,
    changed: changedOf(w),
    // WAVE-LEVER-RESET-1: the machines given back the value of the wave.
    reset: resetOf(w),
  }));
  // PLAN-WRITE-RACE-1: the plan version this page read goes with the save, so
  // a save built on a page read before somebody else's change is refused
  // rather than written over it.
  // A page that holds no plan version - its read of the plan after the last
  // save or target change failed - does not save. The service would judge the
  // save against whatever plan is current, and a layout is the complete set of
  // waves (WAVE-REMOVE-NOT-SAVED-1): a machine a new plan added would go to no
  // wave. The page must read the plan again first.
  if (!DEMO_MODE && !planVersion) { throw new Error(UX.saveNoPlan); }  let r = await apiPost(`runs/${runSeg()}/plan/waves`, runBody({ waves, planVersion }));
  // WAVE-OWN-PICTURE-1: the sample has no service, so it writes the save into
  // its own plan by the service's rule, and says what the service would say.
  if (DEMO_MODE) { r = { ...(r ?? {}), ...demoWritePlan(waves) }; }
  original = snapshot();
  // WAVE-MIX-2: a save writes a new plan version. A target change after it
  // must quote the plan as saved, not the plan the page first read.
  // A failed read leaves no version, and the service then refuses a change
  // rather than accepting one against a plan nobody read.
  // WAVE-LEVER-OVERRIDE-1: and every card is drawn again from the plan as
  // saved, so the next save compares with what the cards show now - not with
  // what they showed before this save. Until it is read, the cards show what
  // was sent.
  // WAVE-LEVER-RESET-1: a reset saved is not sent again.
  for (const w of layout.values()) { w.drawn = Object.fromEntries(Object.keys(WAVE_DEFAULTS).map(f => [f, w[f]])); w.reset = {}; }
  // WAVE-OWN-PICTURE-1: the sample page reads its plan again too, so a save
  // shows at once there as it does on a real run.
  try { await reloadPlan(); } catch { planVersion = ''; }
  if (!DEMO_MODE && !planVersion) { $('#warnbar').textContent = UX.saveNoPlan; $('#warnbar').style.display = 'block'; }
  return r;
}

/* WAVE-MIX-2 / PLANVER-2: the plan AND the version the service issued for it,
 * from one response. A target change quotes the version back. */
async function readPlan() {
  // WAVE-OWN-PICTURE-1: the sample reads the plan it holds, as its save wrote it.
  if (DEMO_MODE) { planVersion = ''; return DEMO_PLAN; }
  const v = await VmfHelp.storeBlob(() => getToken(), cfg.apiUrl, `${runPrefix()}/plan.json`, { asVersioned: true });
  if (!v || !v.text) { planVersion = ''; return null; }
  planVersion = v.version || '';
  return JSON.parse(v.text);
}
// After a target change: the entries changed, and the layout on screen was
// saved (a change is refused while it is not), so it is rebuilt from the plan.
async function reloadPlan() {
  const plan = await readPlan();
  if (!plan) return;
  setEntries((plan.entries ?? []).filter(e => e.path === 'A'), plan.waveOrder);
  buildLayoutFromPlan();
  wPreviewLoad();
}

async function save() {
  $('#err').style.display = 'none'; $('#ok').style.display = 'none'; $('#warnbar').style.display = 'none'; $('#moved').style.display = 'none';
  // CLICKS-LOST-1: a sign at once, before anything is asked of the service.
  const undoBusy = VmfHelp.markBusy($('#save'), UX.saving);
  /* SAVE-STUCK-1: an unchanged plan is not written again.
   *
   * Writing an identical plan is not harmless - it bumps the plan version,
   * and an acceptance is bound to the version it was shown (ACCEPT-HASH-1),
   * so it would quietly ask somebody to accept every wave a second time for
   * no change at all.
   *
   * Inside the flow, saving IS continuing, so an unchanged plan goes straight
   * on. Outside it, say what happened: silence is indistinguishable from a
   * broken button, which is the reason Reset says the same thing. */
  if (!dirty()) {
    if (inFlow()) { location.href = runHref('wizard.html', { step: 'run' }); return; }
    $('#ok').textContent = UX.saveNothing;
    $('#ok').style.display = 'block';
    undoBusy();
    const contSame = $('#continue');
    contSame.textContent = UX.continueSetup;
    contSame.href = runHref('wizard.html');
    contSame.style.display = '';
    return;
  }
  // CLICKS-LOST-1: and the wait, said beside the button.
  const wait = $('#save-wait');
  wait.textContent = UX.savingWait; wait.style.display = '';
  try {
    const r = await writeLayout();
    const invalidated = r?.ApprovalsInvalidated ?? [];
    // EVAL-H7/H8: a save can also void accepted settings and delete capacity
    // checks - for a wave already through the runway, that check was the only
    // record of a paid reservation. The page used to mention none of it, and
    // the word "capacity" never appeared here at all.
    const acceptCleared = r?.AcceptancesCleared ?? [];
    const capCleared = r?.CapacityChecksCleared ?? [];
    if (invalidated.length) { $('#warnbar').textContent = UX.savedApprovals.replace('{waves}', invalidated.join(', ')); $('#warnbar').style.display = 'block'; }
    else { $('#ok').textContent = UX.savedOk; $('#ok').style.display = 'block'; }
    const extra = [];
    if (acceptCleared.length) { extra.push(UX.savedAcceptCleared.replace('{waves}', acceptCleared.join(', '))); }
    if (capCleared.length) { extra.push(UX.savedCapacityCleared.replace('{waves}', capCleared.join(', '))); }
    // WAVE-LEVER-OVERRIDE-1: a change a machine kept its own value against.
    if ((r?.KeptOwnSettings ?? []).length) { extra.push(UX.savedKept); }
    // WAVE-LEVER-RESET-1: the machines given back the value of their wave.
    const resetNames = [...new Set((r?.ResetToWave ?? []).map(x => x.Machine))];
    if (resetNames.length) { extra.push(UX.savedReset.replace('{names}', resetNames.join(', '))); }
    // Shown in both cases: when approvals were cleared the warning bar carries
    // that, and these lines were added to a hidden line.
    if (extra.length) {
      $('#ok').textContent = (invalidated.length ? '' : $('#ok').textContent + ' ') + extra.join(' ');
      $('#ok').style.display = 'block';
    }
    // UX-WAVE-3(a): saving used to leave the person here with nowhere to go,
    // and then with only a text link, which read as an afterthought beside
    // the blue buttons everywhere else. Arranging the waves is
    // a STEP; the next step is accepting how they run, back in the wizard.
    // The next step is reviewing how the wave runs - so it sits with the other
    // actions, and the run page is not offered here at all: it is not next.
    // WAVE-FLOW-1: inside the flow, saving IS continuing. Revealing a second
    // button afterwards is what made this screen offer two ways to commit -
    // and the one that reads as finishing was the one that did not.
    if (inFlow()) {
      location.href = runHref('wizard.html', { step: 'run' });
      return;
    }
    const cont = $('#continue');
    cont.textContent = UX.continueSetup;
    cont.href = runHref('wizard.html');
    cont.style.display = '';
  } catch (e) {
    $('#err').textContent = VmfHelp.explainAction(e); $('#err').style.display = 'block';
  }
  wait.style.display = 'none';
  undoBusy();
  render();
}

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  if (inFlow()) {
    // The strip says this is step 2 of 3. Without it the page reads as a
    // destination somebody was thrown to - and "Save the plan" then looks like
    // the finish line, so they stop one step short of accepting anything.
    // ADVISOR-1: step 3 now - choosing each target came in front.
    // MACHINE-PICK-1: the fourth step, after the machines, the targets and the grouping.
    $('#rail').innerHTML = VmfHelp.stepRail(VmfHelp.MIGRATE_STEPS, 4);
    $('#rail').style.display = '';
    // ONE pair of buttons. "Start over" is the editor's own way to discard,
    // and inside the flow Back is that way - a screen that offers two ways to
    // leave is a screen somebody leaves by the one that does not save.
    $('#reset').style.display = 'none';
    const backBtn = $('#back');
    backBtn.textContent = UX.back;
    backBtn.style.display = '';
    // BACKLOOP-1: NAME the step. With no step, the wizard derived "the waves"
    // from the plan - which is this page - and sent the person straight back.
    backBtn.addEventListener('click', () => { location.href = runHref('wizard.html', { step: 'group' }); });
  }
  runId = new URLSearchParams(location.search).get('run') ?? (DEMO_MODE ? VmfHelp.sampleRun.runId : null);
  projectId = new URLSearchParams(location.search).get('project');
  // ONE normalisation, as in the wizard: a link may carry the composite id.
  {
    const parts = VmfHelp.VmfRun.parse(runId);
    if (parts.project && !projectId) { projectId = parts.project; }
    if (parts.project) { runId = parts.run; }
  }
  $('#title').textContent = UX.title;
  $('#runid').textContent = runId ?? '';
  $('#howto').textContent = UX.howto;
  $('#pool-title').textContent = UX.filterTitle;
  $('#add-wave').textContent = UX.addWave;
  $('#reset').textContent = UX.reset;
  $('#save').textContent = UX.save;
  VmfHelp.identity(account, DEMO_MODE ? UX.demoViewer : null);

  let plan, stateDocs = [], assessment = null;
  if (DEMO_MODE) { plan = DEMO_PLAN; canEdit = true; canSignOff = true; }
  else {
    /* PAGE-WAIT-1: these went one after another - the plan, the machines,
     * the sign-in, the quota records - before anything was drawn. None needs
     * another, so they go together. And the page says it is reading: a blank
     * page for seconds reads as a page that is broken. */
    /* LOADING-LINE-1: and where a person can SEE it. This line was written
     * into #waves, inside #app, which stays hidden until the reads end - so it
     * was never seen. #plan-reading is outside #app. */
    const readingLine = $('#plan-reading');
    readingLine.textContent = UX.readingPlan;
    readingLine.hidden = false;
    const roleRead = (async () => {
      try {
        const tok = await getToken([`api://${cfg.apiAppId}/access_as_user`]);
        const roles = JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).roles ?? [];
        canEdit = roles.includes('Vmf.Operator') || roles.includes('Vmf.Admin');
        canSignOff = roles.includes('Vmf.Approver') || roles.includes('Vmf.Admin');
      } catch { canEdit = false; canSignOff = false; }
    })();
    // PAGE-LOAD-3: the migration's documents in one call (readMigration).
    try {
      const [got] = await Promise.all([readMigration(), roleRead]);
      ({ plan, stateDocs, assessment, leases } = got);
    } finally { readingLine.hidden = true; readingLine.textContent = ''; }
  }
  if (!plan) {
    $('#gate-title').textContent = UX.title; $('#gate-copy').textContent = UX.noPlan;
    $('#gate-view').style.display = 'block';
    return;
  }
  if (DEMO_MODE) { await loadClaims(); }
  setEntries((plan.entries ?? []).filter(e => e.path === 'A'), plan.waveOrder);
  states = new Map(stateDocs.map(d => [d.vmId, d.state]));
  nameMachines(stateDocs, assessment);
  buildLayoutFromPlan();
  // REBUILD-REMOVE-PLAN-1: read the preview feature of the subscriptions that need it.
  wPreviewLoad();
  if (!canEdit) { $('#warnbar').textContent = UX.notAllowedCopy; $('#warnbar').style.display = 'block'; }

  $('#add-wave').addEventListener('click', () => {
    let n = UX.newWaveName, i = 2;
    while (layout.has(n)) { n = `${UX.newWaveName}-${i++}`; }
    layout.set(n, { capacityGate: 'BestEffort', requireApproval: true, onDDataFound: 'stop',
                    keepSnapshotDays: 7, throttle: VmfHelp.WAVE_DEFAULT_WORKERS, vmIds: [] });
    render();
  });
  $('#reset').addEventListener('click', (e) => {
    const hadChanges = dirty();
    const doReset = () => {
      buildLayoutFromPlan(); selection.clear(); $('#moved').style.display = 'none'; render();
      // Silence is indistinguishable from a broken button, so say which of the
      // two things just happened.
      $('#ok').textContent = hadChanges ? UX.resetDone : UX.resetNothing;
      $('#ok').style.display = 'block';
    };
    // POPUP-1: asked beside the button, not in a browser box.
    if (hadChanges) { VmfHelp.confirmInPlace(e.currentTarget, { ask: UX.resetConfirm, yes: UX.resetYes, cancel: UX.cancel, under: '.bar' }, doReset); }
    else { doReset(); }
  });
  $('#save').addEventListener('click', save);
  wireFilters();
  wirePoolDropTarget();   // LEAK-1: once, not once per render
  // WAVE-MIX-2, rule 11: Escape closes the size series panel. Once, like the above.
  // WAVE-LEVER-OVERRIDE-1: and a ? helper on a wave card.
  document.addEventListener('keydown', onEscape);
  // QUOTA-PREVIEW-1, rule 11: a click outside the quota confirmation closes it. Once.
  $('#q-modal-back').addEventListener('click', (e) => { if (e.target === e.currentTarget) closeQuotaConfirm(); });
  // The quota card and its confirmation name each subscription once the names
  // arrive. Until then they show the id, which is never wrong.
  if (!DEMO_MODE) {
    // WAVES-API-1: this page's own reader. `api` is another page's helper.
    apiGet('scopes')
      .then(d => { subscriptionList = d; drawQuotaCard(); if (quotaConfirm) { drawQuotaConfirm(); } })
      .catch(() => { /* ids stay */ });
  }
  $('#app').style.display = 'block';
  render();
  // QUOTA-CHECK-SPINNER-1: every "... ago" on the page moves. Once, like the above.
  setInterval(tickAgo, 1000);
  // Arriving from "change them first" carries #wave=<name>; this is what makes
  // that link land on the settings instead of the top of the page.
  focusWaveFromHash();
}

/* The readers this page hands the help menu, for the support bundle.
 * PAGE-LOAD-3: runDocs reads the run's documents in ONE call (store/docs with
 * the run as the prefix), as the Migrations page does; the bundle answers from
 * it and asks the readers below only what it cannot say. ?demo has no
 * service, so it has no runDocs. */
function helpAdapter() {
  return { getMsal: () => msalApp,
    // RUN-ADDR-2: the run's FULL store path. The bare run name read every
    // document of a run inside a project from the wrong folder, so the bundle
    // came back empty - the thing EVAL-M13 below says it must never do.
    getRunId: () => runFullId() || null,
    // EVAL-M13: this said blobJson, which exists only on the wizard. On this
    // page it is a ReferenceError, so "Get help" here produced either an empty
    // bundle or nothing at all - and the one thing a support bundle must never
    // do is come back empty from the page somebody is stuck on.
    readJson: (run, rel) => blobFetch(`${run}/${rel}`),
    listFolder: async (run, folder) => (await blobList(`${run}/${folder}/`)).map(n => n.slice(run.length + 1)),
    readLines: async () => [],   // this page has no text reader; the log comes from the run page
    runDocs: DEMO_MODE ? undefined
      : (run, read) => VmfHelp.storeDocs(() => getToken(), cfg.apiUrl, { prefix: `${run}/`, depth: 2, read }),
  };
}

async function boot() {
  // Guarded: a missing shared file must cost the help option, not the page.
  if (window.VmfHelp) VmfHelp.install(helpAdapter());
  if (DEMO_MODE) { $('#demo-tag').style.display = 'inline-block'; await start(); return; }
  if (typeof msal === 'undefined') throw new Error('msal-browser.min.js failed to load - redeploy the dashboard.');
  cfg = VmfHelp.checkedConfig(await (await fetch('dashboard.config.json')).json());
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

      } catch (e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }
    });
  }
}

// ---------- bundled sample ----------
// WAVE-SAMPLE-RUN-1: the plan of the sample run that the Migrations page shows
// too, written once in help.js (VmfHelp.sampleRun). This page kept a plan of
// its own under the same run name - more than 60 other machines in four other
// waves - so the manual's pictures of the two pages showed two migrations.
// The editor shows the plan as it was before the run started.
const DEMO_PLAN = DEMO_MODE ? VmfHelp.sampleRun.plan() : null;

/* WAVE-OWN-PICTURE-1: a save on the sample page, written into the sample plan.
 *
 * The real page sends the save to the service and reads the plan again
 * (reloadPlan). The sample has no service: a save changed nothing, so a
 * machine given the value of its wave still showed in the list of machines
 * with their own value until the page was loaded again. This writes the save
 * the way Set-VmfWavePlan does: each machine goes to the wave it was sent in,
 * and each setting is written by the rule of Get-VmfWaveSettingWrites, judged
 * against the plan as stored before any machine moves. A machine sent in no
 * wave goes to no wave, as there (WAVE-REMOVE-NOT-SAVED-1: a saved layout is
 * the complete set of waves). tests/js/wave-own-picture.test.js
 * holds it to the cases the engine is held to
 * (tests/fixtures/wave-own-settings.json). Returns what the save result says
 * of the machines kept and reset. */
function demoWritePlan(waves) {
  const stored = new Map(entries.map(e => [e.vmId, e]));
  const same = (e, field, v) => v !== undefined && String(leverValue(e, field)) === String(v);
  const writes = [], kept = [];
  for (const w of waves) {
    for (const id of w.vmIds ?? []) {
      const e = stored.get(id);
      if (!e) continue;
      const joining = e.wave !== w.name;
      const machine = String(id).split('/').pop();
      // A running wave sends its machines and no setting (WAVE-EDIT-RUNNING-1).
      for (const field of Object.keys(WAVE_DEFAULTS).filter(f => f in w)) {
        const to = w[field];
        // WAVE-LEVER-RESET-1: the value of the wave, over the machine's own,
        // and the record of a decision for that setting goes.
        if ((w.reset?.[field] ?? []).includes(id)) {
          if (same(e, field, to) && !ownDecision(e, field)) continue;
          writes.push({ e, field, to, reset: true, machine, wave: w.name });
          continue;
        }
        // A setting the person did not change is not written on a machine
        // that stays in its wave.
        if (!joining && w.changed && !(field in w.changed)) continue;
        if (same(e, field, to)) continue;
        if (!WAVE_WIDE.includes(field)) {
          if (ownDecision(e, field)) { kept.push({ Wave: w.name, VmId: id, Machine: machine, Setting: field, Value: leverValue(e, field), Reason: 'decision' }); continue; }
          if (!joining && w.changed && !same(e, field, w.changed[field])) { kept.push({ Wave: w.name, VmId: id, Machine: machine, Setting: field, Value: leverValue(e, field), Reason: 'own' }); continue; }
        }
        writes.push({ e, field, to, reset: false, machine, wave: w.name });
      }
    }
  }
  const named = new Set();
  for (const w of waves) { for (const id of w.vmIds ?? []) { const e = stored.get(id); if (e) { e.wave = w.name; named.add(id); } } }
  // WAVE-REMOVE-NOT-SAVED-1: every machine on a moving path that no wave
  // names goes to no wave; a MANUAL or EXCLUDED machine is never touched.
  for (const e of stored.values()) {
    if (named.has(e.vmId) || ['MANUAL', 'EXCLUDED'].includes(e.path) || !e.wave || e.wave === 'unscheduled') continue;
    e.wave = 'unscheduled';
  }
  const reset = [];
  for (const x of writes) {
    x.e.policy = { ...(x.e.policy ?? {}), [x.field]: x.to };
    if (!x.reset) continue;
    if (Array.isArray(x.e.decisions)) x.e.decisions = x.e.decisions.filter(d => !d || d.setting !== x.field);
    reset.push({ Wave: x.wave, VmId: x.e.vmId, Machine: x.machine, Setting: x.field, Value: x.to });
  }
  // WAVE-ORDER-1: the order sent, then the waves it did not name; each wave
  // that still holds a machine.
  const all = DEMO_PLAN.entries ?? entries;
  const order = [];
  for (const name of [...waves.map(w => w.name), ...(DEMO_PLAN.waveOrder ?? [])]) {
    if (name && !order.includes(name) && all.some(e => e.wave === name)) order.push(name);
  }
  DEMO_PLAN.waveOrder = order;
  return { KeptOwnSettings: kept, ResetToWave: reset };
}

boot().catch(e => { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; });
