# Schema migration notes

## run-stop v1 new (2026-11-17, STOP-STATE-SHOWN-1)

**Change.** Stop this migration (`Stop-VmfRun`) writes a new record at the
top of the run, `stopped.json` (`schemas/run-stop.schema.json`), created once - a second stop keeps the first record - when the stop
goes ahead and before it closes out any machine: `runId`, `stoppedUtc`,
`stoppedBy` (the signed-in identity), `note`, `wavesNotStarted` (the waves in
which no machine had a state past PLANNED), `machines` (the resource IDs it
closed out) and `schedulesRemoved`. The stop also removes every scheduled
start of the run (`schedules/<wave>.json`), and writes no `HALTED` line in the
activity. The Migrations page reads the record: the top card says Stopped,
who, when and the note; a wave of `wavesNotStarted` says Stopped before it
started, and a wave with a machine of `machines` says Stopped; the Wave safety
brake card says Stopped, with no Resume and no Pause new work; no scheduled
start is shown.

**Why.** Before it, a stop left only the pause (`halt.flag`), which has no
field that says who wrote it, and the page read every pause as the brake
after repeated failures. On the lab install (2026-11-17) a stopped migration
showed both waves Complete, a red brake card with Resume, "The wave paused
itself automatically after repeated failures", and the scheduled start of a
wave the stop ended, with Cancel the scheduled start.

**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a stop without the record. A run with no `stopped.json` is read as not
stopped, as every run was before. The tests are
`tests/unit/StopStateShown.Tests.ps1` and `tests/js/stop-state-shown.test.js`,
and `tests/unit/SamplesConform.Tests.ps1` holds the sample to its schema.


## plan-entry v36 -> v37 and plan-approval v3 -> v4 (2026-11-16, SQL-TEMPDB-SIGNOFF-1)

**Change.** A plan entry gains `assessment.sqlServerDetected` (boolean):
`true` when the scan found SQL Server on the machine - its warning
`sql-server-agree-downtime`, from the SQL IaaS Agent record or a SQL Server
image (`Test-VmfSqlServerFound`). `New-VmfPlan` writes it, true or false; a
target change keeps it with the rest of the assessment block. The plan
sign-off (`plan-approval.json`) gains `sqlTempdbChecked`: the machine ids of
each machine that moves (path A) with `sqlServerDetected` true, from a SCSI
temporary disk (`sourceDiskArch` `scsi-temp`) to an NVMe temporary disk or
none (`target.diskArch` `nvme-temp` or `diskless`) - `Test-VmfSqlTempdbRisk`.
`Approve-VmfPlan` refuses the sign-off (400) until the approver names every
such machine (`-SqlTempdbChecked`, the body field `sqlTempdbChecked` of
`POST runs/{run}/approve-plan`), and records them; a plan with no such machine
records nothing new. `Approve-VmfWave` refuses a wave with such a machine that
the sign-off does not name. The migration record gains one decision for it,
"checked where tempdb is on the SQL Server machines", with no change to its
shape.

**Why.** On a size with a raw NVMe temporary disk, SQL Server fails to come
online when tempdb is on that disk (Microsoft, "Fix SQL Server on Azure VM
deployment and startup failures"), and a size with no temporary disk has no
D:. The lab saw SQL Server fail to create tempdb on every start after a move
to a v6 size, while the move said Migrated. The decision: no check inside the
machine and no new Azure read - document the risk and ask for a sign-off, and
only where the scan found SQL Server.

**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v36 entry or a v3 sign-off; the plan reader refuses an entry of an
earlier version, and `plan-approval` holds 4 only. The tests are
`tests/unit/SqlTempdbSignoff.Tests.ps1` and `tests/js/sql-tempdb-signoff.test.js`,
with the version pins updated in the files that hold them.

## vm-state v50 -> v51 (2026-11-15, ROLLBACK-NO-CAPACITY-OTHER-SERIES-1 and ROLLBACK-SIZE-REFUSED-SERIES-1)

**Change.** Four fields, all optional:
- `captured.startOnTarget` (object: `size`, `target`, `power`, `stopUtc`,
  `tsUtc`). A retry after `rollbackNoCapacity` of a move onto v5 or Bsv2
  starts the machine on the new size, with no start on its original size.
  Checking writes it before anything changes; it belongs to the stop in
  `stopUtc`, and a park of that attempt before any change carries it on.
- `captured.original.sizeReplaced` (object: `size`, `by`, `reasonCode`,
  `operationId`, `utc`). After a `rollbackSizeRefused` stop and Change to v5,
  Restore this machine puts the first safety copy on the target size of the
  plan; that size becomes `captured.original.vmConfig.size`, and this keeps
  the size Azure refused.
- `restore.ontoTarget` (object: `option`, `size`, `originalSize`,
  `reasonCode`): the same restore, on its record.
- `putBackJob.options.ontoSize`, `ontoOption`, `ontoOriginal`: the size that
  restore decided when it started, for a resume.
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v50 document. `New-VmfStateDoc` writes v51. ROLLBACK-CAPACITY-1 took
plan-entry v35 (PR 1021); this change takes no plan-entry version. The tests are
`tests/unit/RollbackOtherSeries.Tests.ps1`, `tests/unit/RetrySeries.Tests.ps1`
and `tests/js/rollback-other-series.test.js`.

## plan-entry v35 -> v36, guest-output vmf.guest/6 -> vmf.guest/7 (2026-11-14, VF-UNMANAGED-CONFIG-1)

**Change (plan-entry).** `policy.onSriovUnmanagedMissing`, `stop` or
`proceed`. Only `Resolve-VmfDecision` writes it, when an approver accepts the
move of one Linux machine that stopped at Checking with `sriovNotUnmanaged` or
`sriovUnmanagedNotChecked`, always with a record in `decisions`. It is never a
wave setting. Absent reads as `stop`.

**Change (guest-output).** The `schema` field accepts `vmf.guest/7`, and the
facts object declares the facts of `sriov-unmanaged-check.sh`:
`networkManager`, `networkd`, `wicked`, `ifupdown`, `systemdVersion`,
`cloudInitVersion`, `cloudInitNetwork`, `sriovUdevLines`,
`sriovNetworkFiles` and `nmUnmanagedDevices`. A v2 to v6 output is a valid
v7 one without them.

**Why.** Microsoft: "Accelerated Networking requires configuring the SR-IOV
drivers as unmanaged devices in your network settings." Checking now reads
this on a Linux move with accelerated networking on after it, and a machine
without the setting waits for a decision.

**Migrating.** Nothing is rewritten: nothing is public before 1.0, so no store
holds a plan from an earlier version. The tests are
`tests/unit/SriovUnmanaged.Tests.ps1`, with the version pins updated in the
files that hold them.

## guest-output vmf.guest/5 -> vmf.guest/6 (2026-11-14, KERNEL-OFFER-EDGES-1, KERNEL-FLOOR-UPLOAD-1)

**Change.** The `schema` field accepts `vmf.guest/6`, and the facts object
declares two optional facts. `releaseverLock`: on Red Hat, Alma, Rocky, CentOS
and Oracle Linux, the first line of `/etc/dnf/vars/releasever`, else
`/etc/yum/vars/releasever` (for example `9.4`), or `none`.
`kernelPackageVersion`: on Ubuntu and Debian, the version of the package of
the running kernel, `dpkg-query -W -f='${Version}' linux-image-$(uname -r)`
(for example `5.15.0-1096.105`), or `unknown`. `mana-check.sh` (1.3.0; 1.4.0 with AN-TRAFFIC-VERIFY-1) emits
v6. It also reads a MANA driver built into the kernel from
`/lib/modules/$(uname -r)/modules.builtin`, as Microsoft's own check does
(MANA-BUILTIN-READ-1); that changes no field.

**Why.** KERNEL-OFFER-EDGES-1: the EUS, SAP and HA RHUI clients lock
releasever to one minor release (Microsoft, RHUI certificate page), so an
update stays on it and cannot reach the kernel of the later minor release
Microsoft lists for MANA. The engine now refuses that update before any
change (`kernelUpdateCannotReachMinimum`). KERNEL-FLOOR-UPLOAD-1: Ubuntu's
`uname -r` has no upload number (`5.15.0-1096-azure`) and Microsoft's minimum
has one (`5.15.0-1096.105`), so a kernel exactly at the minimum read below it.
`Get-VmfDriverJudgement` now compares the package version there, and says
UNKNOWN, never below, when the machine did not report it.

**Migrating.** Nothing to rewrite. A v2 to v5 output is a valid v6 output
without the facts. Without `releaseverLock` the update runs as before; without
`kernelPackageVersion` a kernel equal to the minimum as far as uname goes is
UNKNOWN. The tests are `tests/unit/KernelOfferEdges.Tests.ps1`,
`tests/unit/KernelUpdate.Tests.ps1`, `tests/unit/GuestOutputContract.Tests.ps1`
and `tests/linux/mana-check.test.sh`.

## assessment v16 -> v17, target-advice v32 -> v33 (2026-11-14, TARGET-CAPABILITY-PRECHECK-1)

**Change.** Each machine of the assessment gains `encryptionAtHost` and
`ultraSsdEnabled`, read by the scan's Resource Graph query from
`properties.securityProfile.encryptionAtHost` and
`properties.additionalCapabilities.ultraSSDEnabled`. Azure leaves the
property out when it is not set, which the scan records as `false`; a
discovery row with no such column leaves the field out, which is unknown. The
sample is version 17. `target-advice.json` gains the reasons
`no-encryption-at-host` and `no-ultra-disk`: `Resolve-VmfEntryTarget` (the
target advice, the plan and the wave editor) does not offer a size whose
catalog entry does not say it supports encryption at host
(`EncryptionAtHostSupported`), or Ultra Disks in the zone of the machine
(`LocationInfo.ZoneDetails`, Microsoft's read for a zonal machine) or in its
region for a machine with no zone (`UltraSSDAvailable`), to a machine that
uses it. Checking asks the live catalog again before any change, and stops
the machine untouched with the new stop reason `targetFeatureNotSupported`;
it also asks for Premium Storage (`PremiumIO`) for each Premium SSD v2 or
Ultra Disk the machine has.

**Why.** The capture recorded both features, and only Verifying compared
them - after the move. Azure refused the resize in Moving, after the stop, and
the rollback put the machine back and discarded every write since the first
copy.

**Migrating.** Nothing is rewritten. An assessment of version 16 is refused
by name (`Assert-VmfSupportedAssessment`) - scan again; a v32
`target-advice.json` is refused and made again. Nothing is public before 1.0,
so no store holds either. A plan entry's copy of the assessment does not carry
the two fields, and asks nothing; Checking reads the machine itself. The tests
are `tests/unit/TargetCapabilityPrecheck.Tests.ps1`, with the version pins
updated in the files that hold them.

## plan-entry v34 -> v35 (2026-11-14, ROLLBACK-CAPACITY-1)

**Change.** `assessment.sourceCapacityRestricted` (boolean or null). `true`
when Microsoft restricts capacity growth for the series of `sourceSize`
(`target-families.json` `lifecycle.capacityRestrictions`, read from the page
retirements-and-capacity-restrictions, section Impacted VM series), `false`
when it does not, `null` when the size cannot be read. `New-VmfPlan` writes it
from the data (`Test-VmfSizeCapacityRestricted`); `Set-VmfMachineTarget`
keeps the entry's assessment, so the value stays. The wizard's Run it and the
acceptance on the Migrations page show one line for a wave when any machine of
the wave that moves has `true`: the product gives no guarantee of capacity for
the new size or, on a rollback, for the original size.
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v34 entry; the plan reader refuses an entry of an earlier version
(make the plan again). The tests are `tests/unit/RollbackCapacity.Tests.ps1`
and `tests/js/rollback-capacity.test.js`.

## plan-entry v33 -> v34 (2026-11-14, EOL-RELEASE-AN-1)

**Change.** `policy.onReleaseEndOfLife` (stop, proceed). Checking stops a
Linux machine whose release, as the Azure Linux Agent reported it to the scan,
is past its vendor's end of standard support (`data/linux-release-eol.json`)
with the stop `linuxReleaseEndOfLife`, until an approver accepts it for that
machine: Resolve-VmfDecision writes `proceed`, with a record in `decisions`.
No planner and no wave save writes it; absent reads as stop.
**Why.** Microsoft supports accelerated networking on endorsed Linux
distributions only while the vendor has not marked the release end of life
(2026-11-14).
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v33 plan; the engine reads the current version only, and
`New-VmfPlan` writes v34. The tests are `tests/unit/ReleaseEndOfLife.Tests.ps1`,
with the version pins updated in the files that hold them.

## target-advice v31 -> v32 (2026-11-14, IMAGE-SCRIPT-MATCH-1)

**Change.** The reason `linux-release-not-on-nvme-list`. The scan holds a
Linux machine whose release is not on Microsoft's list of Linux images that
support NVMe (`data/nvme-linux-releases.json`, read from the page
enable-nvme-interface) from v6 and v7 with the blocker of that name, and the
target options copy each blocker of the scan as a reason. The release is the
one the VM agent reports, else the image's. An unknown release is the warning
`linux-release-nvme-not-read`; the assessment's `warnings` holds any string,
so it has no new version.
**Why.** Windows followed the Windows half of that page
(`windows-version-below-2019`); Linux was asked only for its publisher and
Azure's DiskControllerTypes (2026-11-14).
**Migrating.** Nothing is rewritten. A v31 `target-advice.json` is refused by
name and made again, as for every earlier version (the targets step and
`Set-VmfTargetChoice`). The tests are `tests/unit/NvmeLinuxRelease.Tests.ps1`,
with the version pins updated in the files that hold them.

## guest-output vmf.guest/4 -> vmf.guest/5 (2026-11-14, ORACLE-UEK-UPDATE-1)

**Change.** The `schema` field accepts `vmf.guest/5`, and the facts object
declares one optional fact: `uekRepositories`, the ids of the enabled
repositories whose id has UEK in it, separated by one space (for example
`ol9_UEKR7 ol9_UEKR8`), `none`, or `unknown`. `mana-check.sh` (1.2.0) emits
v5, and reports the fact on Oracle Linux only, read from the repository files
in `/etc/yum.repos.d`.

**Why.** Lab 2026-11-14: an Oracle Linux 9.7 machine set to start UEK R7, with
the UEK R8 repository `ol9_UEKR8` enabled and Update the kernel chosen, stopped
with `uekKernelNotListedForMana`, whose words said the machine needed that
repository. The engine had no way to know which repositories were enabled. Now
`Resolve-VmfKernelUpdate` runs the update for a UEK kernel below UEK R8 when
the UEK R8 repository of the release is in the list, and the stop says when it
is not enabled or could not be read.

**Migrating.** Nothing to rewrite. A v2, v3 or v4 output is a valid v5 output
without the fact; read without it, a UEK kernel stops as before, and the words
say the product could not read the repositories. The tests are
`tests/unit/GuestOutputContract.Tests.ps1`, `tests/unit/KernelUpdate.Tests.ps1`
and `tests/linux/mana-check.test.sh`.

## vm-state v49 -> v50 (2026-11-14, VOLUMES-RETRY-CHECK-1)

**Change.** `volumesCheckOwed` (object: `reason` volumesNotBack or
notChecked, `kind` rollback or restore, `tsUtc`). A rollback or a Restore this
machine whose check of the volumes found a volume not mounted, or could not
run, writes it in the same write as its stop; a check that finds every volume
removes it. While it stands, Try this machine again is allowed after
`volumesNotBack`, and the service re-arms the machine at Checking without the
new attempt. The first step of Checking is the same check: every volume
mounted, the engine takes the new attempt (new safety copies) and removes the
record in that write; not every volume, or not known, the stop
`volumesNotBack` again with nothing changed in Azure.
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v49 document. `New-VmfStateDoc` writes v50. The tests are
`tests/unit/VolumesRetryCheck.Tests.ps1`.

## vm-state v48 -> v49 (2026-11-13, VOLUMES-ONLINE-1)

**Change.** `rollbackPending.volumes` and `putBackJob.volumes` (object or
null: `verdict` MATCH, MISSING or UNKNOWN, `words`, `detail`, `tsUtc`). After
a rollback and after Restore this machine, the engine checks the volumes
inside the machine - on Linux it refreshes the LVM devices file first - and
compares them with the reading before the move. The result goes on the
checkpoint of the put-back before the machine returns to the power state it
was found in, so a worker or a job that stops after that return uses the
result and never asks a stopped machine. MISSING records the stop
`volumesNotBack` with the machine changed.
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds a v48 document. `New-VmfStateDoc` writes v49. The tests are
`tests/unit/VolumesOnline.Tests.ps1`.

## plan-entry v33 narrowed: no policy.bootableClone (2026-11-13, MANUAL-REVIEW-1)

**Change.** No version bump: no writer gave the field. `policy.bootableClone`
leaves the contract. No page wrote it, and its one reader parked the machine
with `bootableCloneNotImplemented`, a stop for a feature that was never built.
That stop reason is gone. So is `safetyCopyNotPristine`: `policy.safetyCopy`
holds `pristine` only, and the one guard for a value the contract does not
list (`Get-VmfPlanPolicyRefusal`, `policyNotKnown`) now refuses any other
value, at Checking and at the wave's acceptance.
**Migrating.** Nothing is rewritten. Nothing is public before 1.0, so no store
holds an entry with the field. The tests are
`tests/unit/ManualReviewRunLines.Tests.ps1`.

## vm-state v47 -> v48, run-status v7 -> v8, target-choices v8 -> v9, capacity-claim v15 narrowed, plan-entry v33 read as v33 only (2026-11-12, the engine half of the old-record sweep: OLD-VERSION-READERS-REMOVE-7, OLD-VERSION-READERS-REMOVE-8, RUN-STATUS-OLD-SUMMARY-1, TARGETS-NO-LIST-1, OLD-STATE-READERS-FINISH-1)

**Why.** Nothing is public before 1.0 (2026-11-11), so no store holds a
record an earlier version wrote. Each reader of such a record is gone, and
each contract holds only what this version writes.

**plan-entry (no bump).** `ConvertTo-VmfSupportedPlan` refuses an entry of an
earlier version, or with no version, as it refused a newer one: "make the
plan again with this version". Every writer (`New-VmfPlan`,
`Set-VmfMachineTarget`, the wave settings, a decision) writes the current
version on each entry. The unit tests build hand-made entries with the shared
helper `tests/unit/_RecordVersion.ps1`, so the next bump changes one line.

**vm-state v47 -> v48.**
- `Read-VmfStateDoc` reads the current version only, and no writer raises a
  document's version field by field: `New-VmfStateDoc` writes the current
  version, and every later write keeps it.
- `swapPending.kept` is required, and each row of `swapPending.swaps` requires
  `snapshotId` (a text, never null) and `lunHolds` (never null). Finish counts
  the swap record's own kept list only, and stops before any change on a swap
  record with none. The empty LUN proof (`Test-VmfEmptyLunWant`) proves
  nothing for a row with no copy: it no longer attaches a disk because it
  exists and no machine holds it.
- `captured.putBackRetirement` holds `size`, `retiresUtc` and `warnFromUtc`
  only (`Get-VmfMoveRetirementRecord`), or null.
- The capture contract names no `purchasePlan`, of the machine or of a disk.
- The accelerated networking decision is the one GUEST_PREP saved
  (`captured.acceleratedNetworking`); `Get-VmfAcceleratedNetworkingDecision`
  takes no plan entry, and throws for a record with none. The
  infrastructure-as-code report reads no plan entry: a record with no saved
  decision, capture or started move is "Not recorded".

**run-status v7 -> v8.** The summary and each wave require `restoredStops`
and `waitsOnPerson`. `Update-VmfRunSummaryWave` patches only a summary that
holds both counts, for the summary and every wave; any other summary is built
again from the store. The empty summary of a status write holds both.

**target-choices v8 -> v9.** `Set-VmfTargetChoice` saves no target before the
list of machines (machine-choices.json): it refuses with 400. So
`machinesVersion` is required and never null, and so are `kernelDefault` and
each choice's `size`, `disks`, `method` (in-place or preview) and `kernel`,
null for none (`kernelDefault` is `stop`, KERNEL-DEFAULT-EARLIER-1). `New-VmfPlan` reads a v9 file only, and refuses targets saved
with no list, with or without `-RequireMachineChoice`: saved targets never
stand for the list.

**capacity-claim v15 narrowed (no bump; the shape the engine writes did not
change).** `demand` requires `ownGroupVmIds`, `familyVcpus`, `regionalVcpus`
and `regionalAdds`, which `New-VmfCapacityClaim` always writes, and
`overlapWithSource` is gone (nothing wrote it since PATH-C-1). The state
`CAPACITY_BLOCKED` is read by nothing: `Test-VmfClaimBlocked` and the page's
`claimBlocked` know BLOCKED only, and `Get-VmfClaimStateName` is gone. A
record with no reservable count is still reservable, the safe side for a
Reserved wave, and `New-VmfWaveReservation` refuses to reserve for it, never
for all its machines.

**wave-schedule v1 narrowed (no bump).** The field `throttle` is gone: an
earlier version wrote it, nothing reads it (a scheduled wave starts at the
number of machines at once its plan holds), and nothing of this version
writes it.

**Descriptions only (no shape change, no bump).** The descriptions in
assessment, capacity-claim, plan-entry, vm-state and wave-options-acceptance
no longer say what a record "from before vN", "absent before vN" or "written
before vN" means: no 1.0 install writes such a record.
**Migrating.** Nothing is rewritten. The tests are
`tests/unit/OldRecordSweepEngine.Tests.ps1`, with the version pins moved.

## plan-approval v3, plan-entry v33 and target-choices v8 narrowed (2026-11-12, the old-record sweep, pages half)

**Change.** No version bump: the shape each writer gives did not change.

- **plan-approval** `schemaVersion` holds 3 only (MIGRATIONS-PAGE-OLD-READERS-1).
  `Approve-VmfPlan` is the one writer, and it writes v3. The consent to run on
  (`Test-VmfPlanRunConsent`, `planStartsWave` on the Migrations page and the
  Run it step of the wizard) no longer reads the version, and a decision
  (`Invoke-VmfDecisionCarryForward`) moves a sign-off only with the wave
  approval, writing it as v3. A v1 or v2 sign-off was the consent only while
  the plan was the text it signed; nothing writes one.
- **plan-entry** `policy.throttle` holds 5, 15, 30 or 60 only (ATONCE-EARLIER-1).
  The planner writes 15, and `Set-VmfWavePlan` and a decision write a choice
  (`Test-VmfThrottleTier`). `ConvertTo-VmfWaveLayout` now refuses any other
  number from the wave editor, where it took 1 to 60 so that a card could send
  back a number from before the four choices. The wave editor shows no
  option and no words for such a number.
  PRECHECK and the wave's acceptance (`Get-VmfPlanPolicyRefusal`) refuse it
  too, where they took 1 to 60.
- **target-choices** `kernelDefault` holds `stop` only (KERNEL-DEFAULT-EARLIER-1).
  The targets step offers no default and always saves `stop`.
  `Set-VmfTargetChoice` and the service refuse another value, `New-VmfPlan`
  plans a machine on its own kernel choice only, and the page no longer reads
  a saved default of `update` into each machine.
- **run-manifest** `project`: description only. A null project is a run
  outside any project, which the command line can make (LOOSE-RUNS-WORDS-1).

**Why.** Nothing is public before 1.0 (2026-11-11), so no store holds a
record an earlier version wrote.

**Migrating.** Nothing is rewritten. The tests are
`tests/unit/OldRecordSweepPages.Tests.ps1` and, for the pages,
`tests/js/plan-follow.test.js`, `tests/js/run-step.test.js`,
`tests/js/machines-at-once.test.js` and `tests/js/kernel-choice.test.js`.
## vm-state v46 -> v47 (2026-11-12, OLD-VERSION-READERS-REMOVE-4)

**Change.** The vm-state contract holds what a record of this version always
holds, and no shape that only an earlier version wrote:

- `rollback.sizeAfter` is gone (not written since RETIRE-SCOPE-1). The
  infrastructure-as-code report and the run page no longer read it: a
  rollback always goes back to the size the machine had.
- `captured.vmConfig` needs `captured.original` beside it
  (`dependentRequired`), and `original` is never null. PRECHECK writes both in
  one write.
- Both captures (`captured.vmConfig`, `captured.original.vmConfig`) hold
  `capacityReservationGroupId` and `patchSettings`, null for none.
  `Get-VmfVmCapture` writes both keys on every capture.

**The engine's readers.** Each fallback for a record without these went, and
none became "nothing to put back":

- No first capture: `Get-VmfOriginalCapture` gives $null, never this attempt's
  capture. `Get-VmfPutBackCapture` throws, and the rollback says why in the run
  history and stops before anything changes (`Get-VmfPutBackRecordGap`).
  PRECHECK never takes a capture of a touched machine as its first capture.
- A first capture that does not say its capacity reservation group stops the
  put-back the same way; `Get-VmfReservationPutBackPlan` refuses an unknown
  group instead of leaving only the product's group.
- A disk with no encryption on record (v21) is not made from its copy
  (`New-VmfOsDiskFromCopy`, `New-VmfDataDiskFromCopy`); a made disk with
  nothing to compare with is refused (`Confirm-VmfMadeDiskEncryption`).
- A restore's swap record that names no operation (v32) matches no restore
  record and no checkpoint: Finish says the record is missing.
- Verifying fails a capture with no patch settings field (v31) - never
  UNKNOWN.
- Words that named a record from an earlier version are gone (the rollback
  disks, the Premium SSD v2 and Ultra Disk values).

**Why.** Nothing is public before 1.0 (2026-11-11), so no store holds a
state document an earlier version wrote.

**Migrating.** Nothing is rewritten. The tests are
`tests/unit/OldVersionReadersRemove4.Tests.ps1`, with the version pins moved to
47.


## capacity-claim v15 narrowed (2026-11-12, OLD-VERSION-READERS-REMOVE-5)

**Change.** A quota record at `RESERVING` must hold `reservationAsked` (an
`allOf` rule in `schemas/capacity-claim.schema.json`). No version bump: the
shape the engine writes did not change. `New-VmfWaveReservation`, the only
writer of `RESERVING`, records `reservationAsked` in the same save, before
Azure is asked.

`Get-VmfReservationNames` gives no names to a record that recorded no ask.
It used to give it the group name of the rule from before CLAIM-NAME-1 (no
code after the name). Now the release of a stuck record
(`Remove-VmfCapacityReservations`) refuses it with a step line, and asks Azure
nothing; the read of a record being made (`Update-VmfReservingClaimFromAzure`)
throws, and reads and writes nothing. A release by a made-up name could delete
an on-demand capacity reservation of another wave.

The comments that said "written before v14" and "before v15" now name what
the current writer gives: `regionalShort` and `demand.regionalAdds` are null
when the quota check did not work them out.

**Why.** Nothing is public before 1.0 (2026-11-11), so no store holds a
record an earlier version wrote.

**Migrating.** Nothing is rewritten. The tests are
`tests/unit/OldVersionReadersRemove5.Tests.ps1`.
## plan-entry v32 -> v33 (2026-11-12, OLD-VERSION-READERS-REMOVE-3)

**Change.** The plan-entry contract no longer holds a value or a field that no
writer of this version gives:

- `assessment.classification` ReadyNow (the scan has not written it since
  assessment v11);
- `policy.onDriverBelowFloor` proceed (not written since AN-PROCEED-NETVSC-1);
- `policy.acceleratedNetworking` ensureOff (not written since
  AN-MANA-DRIVER-RULE-1), and the `allOf` rule that refused it on an NVMe
  target;
- `target.rollbackSize` (not written since RETIRE-SCOPE-1).

The plan reader (`ConvertTo-VmfSupportedPlan`) still takes an earlier
version: taking the current version only moved to OLD-VERSION-READERS-REMOVE-7,
because about 1,050 unit tests hold plan fixtures with an earlier version or
with none. An earlier entry that holds one of the removed policy values is
refused in PRECHECK (below). The engine's readers of ensureOff are gone (`Get-VmfNicAnPlan` changes nothing for
any value but ensureOn, and `Get-VmfAcceleratedNicsAfter` has no `-OthersOff`).

**Hardening (security pass finding).** Every policy value the engine reads
from a plan entry fails closed. `Get-VmfPlanPolicyRefusal` holds the values the
contract lists (`Get-VmfStoredPolicyValues`, held to this schema by a test);
PRECHECK stops a machine whose policy holds any other value, untouched, before
the first Azure call (stop reason `policyNotKnown`), and
`Confirm-VmfWaveOptions` refuses its wave. The temporary disk check goes on
only for exactly `proceed`, the kernel update runs only for exactly
`updateKernel`, and the capacity gate is BestEffort only when the entry says
exactly that or says nothing (`Get-VmfCapacityGate`).

**Why.** Nothing is public before 1.0 (2026-11-11), so no store holds a
plan an earlier version wrote, and no code reads its shape.

**Migrating.** Nothing is rewritten. The tests are
`tests/unit/PolicyFailClosed.Tests.ps1` and
`tests/unit/OldVersionReadersRemove3.Tests.ps1`, with the version pins moved
to 33.

## vm-state v45 -> v46 (2026-11-12, RENAME-WAY-BACK-1)

**Change.** Since 2026-11-12, the words "the way back" are not used; the operator
term is "rollback disk" for both kinds of disk a rollback can use, and the
names say when each was made. Three names change, and nothing else:

- `safety.putBackDisks` (and `safety.earlierCopies[].putBackDisks`, and
  `$defs/putBackDisks`) is `safety.rollbackDisksBeforeMove`: the disks made
  from the first safety copy at the end of SAFETY_PRISTINE, before the move
  changes anything (ROLLBACK-DISKS-FIRST-1).
- The top-level `rollbackDisks` is `rollbackDisksDuringRollback`: the disks a
  rollback makes itself from a copy when it cannot use the first kind
  (PREP-ROLLBACK-1, MADE-DISK-RECORD-1). It stays in the list of made disks
  with `restoreDisks`.
- The stop reason `putBackDiskNotMade` is `rollbackDisksBeforeMoveNotMade`
  (`history[].reasonCode`, `stop-reasons.json`).

The code follows: `New-VmfPutBackDisks` is `New-VmfRollbackDisksBeforeMove`
(file `RollbackDisksBeforeMove.ps1`), every `*-VmfPutBackDisk*` function is
`*-VmfRollbackDisksBeforeMove*`, the verdict properties `PutBackDisks` and
`PutBackDisksDeleted` are `RollbackDisksBeforeMove` and
`RollbackDisksBeforeMoveDeleted`, `New-VmfRollbackDisks` is
`New-VmfRollbackDisksDuringRollback`, `Add-VmfRollbackDiskRecord` is
`Add-VmfRollbackDiskDuringRollbackRecord`, and the web service's answer to
Delete this migration says `rollbackDisksBeforeMove` where it said
`wayBackDisks`.

**Why.** Before this, "rollback disks" in the code meant the second kind
while the words on the pages meant the first, and the first was named
"put back", the word the product uses for a restore.

**Migrating.** Nothing is rewritten, and no reader takes the old names:
nothing is public before 1.0, so no store holds a record with them. The
tests are `tests/unit/RenameWayBack.Tests.ps1`, with the version pins updated
in the files that hold them.

## plan-entry v31 -> v32 (2026-11-12, PLAN-HIBERNATION-UNUSED-1)

**Change.** A plan entry has no `assessment.hibernationEnabled`. `New-VmfPlan`
no longer writes it, and the property left `schemas/plan-entry.schema.json`
and its sample. The assessment keeps its own `hibernationEnabled`: the scan's
rule reads it.

**Why.** Nothing read the plan entry's copy. A machine with hibernation
enabled is outside the scope of this tool: the scan excludes it, so no plan
entry could hold true, and Checking reads the machine again
(`Get-VmfHostHibernationStop`) before any change.

**Migrating.** Nothing is rewritten, and no reader takes the old field:
nothing is public before 1.0, so no store holds a plan from an earlier
version. The tests are `tests/unit/PlanHibernationUnused.Tests.ps1`, with the
version pins updated in the files that hold them.

## assessment v16 narrowed (2026-11-12, OLD-VERSION-READERS-REMOVE-2)

**Change.** The classification enum and the summary no longer hold ReadyNow,
and the `allOf` rule that refused it from v11 on is gone with it. No version
bump: the shape the scan writes did not change, and
`Assert-VmfSupportedAssessment` already takes version 16 only (DRIFT-12). No reader takes
ReadyNow (`ConvertTo-VmfOwnClassification` and the pages' twins are gone).

The same item removes, with no contract change, the readers of: the plan
value `park` (renamed to `stop` long before 1.0), a wave approval with no
`waveVersion`, an acceptance under its name from before ACCEPT-NAME-1, and a
quota record under its name from before CLAIM-NAME-1.

**Why.** No flow of this version writes any of them, and nothing is public
before 1.0.

**Migrating.** Nothing is rewritten, and no reader takes the old shape. The
tests are `tests/unit/OldVersionReadersRemove2.Tests.ps1`.

## assessment v15 -> v16 (2026-11-12, DRIFT-12)

**Change.** The assessment's `scope` has no `acceptedImages`, and the scan
takes no list of accepted images: `Invoke-VmfAssessment`,
`Get-VmfAssessmentRecord` and `Get-VmfImageSupport` lose the parameter
`AcceptedImages`, and no machine gets the status `accepted-by-operator`. The
property left `schemas/assessment.schema.json`, whose scope refuses any other
property. The sample is version 16.

**Why.** Found 2026-11-12: the image override was hidden. No page, no
service call and no engine operation passed `AcceptedImages`, so the words
that told an operator to accept an image named an action the product does not
have. The blocking stays: an unknown publisher, an unknown offer, an image
on the list as not supported and a custom image all keep the blocker
`image-not-supported`, and each reason says the fact and that the product
does not move the machine.

**Migrating.** Nothing is rewritten, and no reader takes the old field:
nothing is public before 1.0, so no store holds an assessment from an earlier
version. `Assert-VmfSupportedAssessment` takes version 16 only, and an
assessment of version 15 is refused by name - scan again. The tests are
`tests/unit/ImageNoOverride.Tests.ps1`, with the version pins updated in the
files that hold them.

## vm-state v44 -> v45, migration-record v4 -> v5, run-status v6 -> v7 (2026-11-12, OLD-REBUILD-RESTORE-READERS-1)

**Change.** The contracts drop every record of a rebuild that an earlier
version made:

- vm-state v45: no `recovery`, no `recoveryDisks`, no `restore.rebuilt`; a
  `putBackJob` is of kind `restore` or `finish` only, with no `rebuild`, no
  options `diskSource`, `as`, `diskSku` or `acceptIdentityLoss`, no
  `before.planPath`, and none of the steps `rebuildRead`, `shellDeleted`,
  `rebuilt` and `renameStopped`; a `diskTypeChanges` entry is by `move`,
  `rollback` or `restore` (no `recover`).
- migration-record v5: no reason `rebuilt` and no `machines[].rebuilt`.
- run-status v7: no reason `rebuilt`.

The engine stops reading them: the refusal of a restore from the first copy
of a machine an earlier version rebuilt (`Get-VmfRestoreOldRebuildRefusal`),
the service's give-up of a job of kind `rebuild`, the lease holder
`rebuild:`, the disk list `recoveryDisks`, the `recovery` record in the
restore, the cleanup, the stop readers, the report's table for
infrastructure code (its column for the machine resource) and the method
label `B`. The pages lose the statuses Rebuilding and Rebuilt and the list of
disks Rebuild this machine made.

**Why.** No flow of this version writes any of these: `New-VmfPutBackJob`
and `Get-VmfMachineLeaseHolder` take `restore` (and `finish`) only, no code
writes `recovery`, `recoveryDisks` or a step `recovery`, and the restore
record has written no `rebuilt` that can be true since REBUILD-REMOVE-RECOVER-1.
Nothing is public before 1.0, so no store holds such a record.

**Migrating.** Nothing is rewritten, and no reader takes the old shape. The
tests are `tests/unit/OldRebuildRestoreReaders.Tests.ps1` and
`tests/js/old-rebuild-restore-readers.test.js`, with the version pins updated
in the files that hold them.

## vm-state v43 -> v44 (2026-11-12, VERIFY-HOST-HIBERNATION-UNUSED-1)

**Change.** `captured.vmConfig` (and `captured.original.vmConfig`) no longer
holds `hostId`, `hostGroupId` or `hibernationEnabled`. The capture
(`Get-VmfVmCapture`) does not write them, and Verifying
(`Test-VmfRebuildSettingsFidelity`) does not compare them. Its words for a
match are now "No machine setting changed."

**Why.** A machine on an Azure Dedicated Host, or with hibernation enabled, is
outside the scope of this tool (REBUILD-MOVE-HOST-1). The scan excludes it,
and Checking stops it untouched before the capture
(`Get-VmfHostHibernationStop`, which still reads the three settings from the
machine). So no capture holds one, and the two comparisons could not fire.
They were written for the rebuild around the same disks, which is removed.

**Migrating.** Nothing is rewritten, and no reader takes the old fields.
Nothing is public before 1.0, so no store holds a v43 document. The tests are
in `tests/unit/RebuildProps.Tests.ps1`, with the version pins updated in the
files that hold them.

## vm-state v42 -> v43 (2026-11-12, RESTORE-ORIGINAL-DELETE-RESTART-1)

**Change.** The checkpoint of a restore (`putBackJob`) gains `originalKept`
(`why`: Azure's words) and three steps between `osOnTemp` and
`originalRemoved`: `originalKept`, `originalBack` and `originalStarted`.
Keeping the names, when Azure refuses to delete the original OS disk after
the lock check passed, the restore saves `originalKept`, puts the original OS
disk back on the machine (`originalBack`), starts the machine as it was
(`originalStarted`), returns it to the power state the restore found, deletes
the temporary disks made for the restore, and ends without its record. The
words it ends with are on the checkpoint as `ended.why`
(`Invoke-VmfRestoreOriginalBack`).

**Why.** The restore started the machine on the temporary OS disk - the
moment of the safety copy - with the data disks as they were: disks from two
moments. The restore now puts the original OS disk back instead
(2026-11-11): Azure did not delete it, and no data disk is touched before
that delete.

**Migrating.** Nothing is rewritten. A v42 checkpoint has none of the new
steps and no `originalKept`, and resumes as before. The steps come before
`originalRemoved`, so a resume from one of them never goes on to make the
disk under the name. The tests are `tests/unit/RestoreEndJob.Tests.ps1`
(every kill point of the way back), with the version pins updated in the
files that hold them.

## plan-entry v30 -> v31, wave-options-acceptance v8 -> v9, wave-approval v4 -> v5, vm-state v41 -> v42, assessment v15 narrowed (2026-11-11, OLD-VERSION-READERS-REMOVE-1)

**Change.** The contracts drop every field of the rebuild around the same
disks (Path B) that a record of an earlier version could hold:

- plan-entry v31: `path` has no `B`; `target.choice.method` has no `rebuild`;
  no `assessment.rebuildLinks`; no `policy.onSystemAssignedIdentity`; a
  decision has only `setting`, `by` and `utc` (no `extensions`,
  `sqlVirtualMachine`, `dataCollectionRuleAssociations` or `principalId`).
- wave-options-acceptance v9: `schemaVersion` is 9 only; no `identityLoss` and
  no `rebuild`.
- wave-approval v5: `schemaVersion` is 5 only; no `identityLoss`, and
  `waveVersion` is required.
- vm-state v42: no `captured.sqlVirtualMachine` and no
  `captured.dataCollectionRuleAssociations`.
- assessment: `schemaVersion` is 15 only, with no version bump - the data
  shape did not change. The two `allOf` rules for v11 and v14 now apply to
  every document, and `Assert-VmfSupportedAssessment` refuses any version but
  15. The sample is version 15.

The engine stops reading these records: the PRECHECK refusal of a plan entry
with path B (`rebuildNotSupported`), the stop of a machine an earlier version
started to rebuild (`oldRebuildNotResumed`), the stop for a path other than A
or B (`pathNotExecutable`), the refusals of a rebuild in the acceptance, the
approval and the sign-off, the run report sections for the identities a
rebuild deleted and the follow-ups after a rebuild, and the service's
refusals of the fields only an earlier page sent. A wave runs only path A.

**Why.** Since 2026-11-11: no installation runs an earlier version - nothing is public
before 1.0, so no store holds a record that an earlier version wrote. No
writer of this version gave any of these fields: path B and method rebuild
since plan-entry v29 (`Get-VmfPathSelection` gives A, MANUAL or EXCLUDED),
`rebuildLinks` since v29, the decision fields and the acceptance lists since
REBUILD-REMOVE-ACCEPT-1, the two captures since REBUILD-REMOVE-ACCEPT-1, and
an approval without `waveVersion` since WAVE-APPROVE-1.

**Migrating.** Nothing is rewritten, and no reader takes the old shape. A
record of an earlier version no longer passes its schema. The tests are
`tests/unit/OldVersionReadersRemove.Tests.ps1`, with the version pins updated
in the files that hold them.
## target-advice v30 -> v31 (2026-11-11, RHEL-EUS-TARGET-NOTE-1)

**Change.** Each machine of `target-advice.json` gains `eusImage`: `null`, or
`image` (publisher:offer:SKU), `release` (the RHEL minor release of the image)
and `listedFrom` (the lowest RHEL release of that major that Microsoft lists
for MANA). `Get-VmfEusImage` sets it for a Linux machine made from the image
publisher `RedHat`, offer `RHEL`, with no licence type (or `None`), whose SKU
has a minor version (`Get-VmfImageRelease`), that runs that same minor release
(`Get-VmfLinuxRelease`), and whose release Microsoft's MANA table covers only
by a later minor release (`Find-VmfManaTableEntry`). The targets step shows a
note in that machine's network driver choice. Nothing else changes: Update the
kernel stays offered, and no option, start or reason changes.

**Why.** Microsoft, Red Hat Update Infrastructure: an image with a minor
version in its SKU is connected to the EUS repositories, which give no later
minor release. A machine made from `RedHat:RHEL:94_gen2` that chose Update the
kernel stopped with `kernelNotInRepositories` (measured 2026-11-08), and the
targets step said nothing about that machine before the run.

**Migrating.** Nothing is rewritten. A v30 `target-advice.json` is refused by
name and made again, as for every earlier version (the targets step and
`Set-VmfTargetChoice`); nothing is converted. The tests are
`tests/unit/RhelEusTargetNote.Tests.ps1` and
`tests/js/rhel-eus-target-note.test.js`, with the version pins updated in the
files that hold them.

## assessment v14 -> v15 (2026-11-11, REBUILD-REMOVE-SCAN-EXT-1)

**Change.** A machine record has no `rebuildLinks`, and `notRead` has no
subject `rebuildLinks`. The scan no longer lists the extensions of every
machine (`Get-VmfVmExtensionsByVm`, a Resource Graph read), no longer asks
each subscription's effective permissions to judge an empty answer
(`Test-VmfExtensionReadHeld`), and no longer reads the patch mode in its
inventory query. The `rebuildLinks` property and the v12 `allOf` rule that
named it left `schemas/assessment.schema.json`. The run report and the
dashboard's assessment report lose the line "Extensions. The acceptance of a
rebuild says that the extensions of each machine were not checked."

**Why.** Only the acceptance of a rebuild used the list, the SQL virtual
machine flag and the patch mode in `rebuildLinks`. The rebuild and its
acceptance are removed (REBUILD-REMOVE-ACCEPT-1, 2026-11-07), and the
plan stopped carrying `rebuildLinks` (plan-entry v29). The read made Azure
calls that drove no work, and the report named a screen that does not exist.
The permission map keeps `Microsoft.Compute/virtualMachines/extensions/read`:
Azure Disk Encryption, the SAP extension, the SQL IaaS Agent hint and
PRECHECK's list of extensions use it. No role changes.

**Migrating.** Nothing is rewritten, and no reader takes the old field.
Nothing is installed before 1.0 (2026-11-11), so no store holds an
assessment from an earlier version. An assessment from v7 to v14 that holds
`rebuildLinks` no longer passes the schema. The tests are
`tests/unit/RebuildRemoveScanExt.Tests.ps1`, with the version pins updated in
the files that hold them.
## schedule-status v1 -> v2, schedule-due v1 new (2026-11-10, SCHEDULE-PASS-DUE-1)

**Change.** The service's five-minute schedule pass checks only the runs of a
new record at the top of the store, `schedule-due.json`
(`schemas/schedule-due.schema.json`): one entry for each run (`runId`, a
`markId` that changes at every mark, `reason`, `markedUtc`, `holdUntilUtc`,
`nextUtc`). The cmdlet that writes the fact adds a run - an engine start of a
wave, a restore or a finish (held 15 minutes), a schedule saved, a plan
sign-off, a decision or a retry of a machine, and Resume - through one
function, `Add-VmfRunScheduleDue`, which the service also calls for its engine
start. The pass removes a
run when none of its checks acts on it (`Get-VmfRunScheduleNeed`), in one
version-checked write that removes an entry only while it holds the mark id the
pass read (`Update-VmfScheduleDue`). Once an hour the pass checks every run
(the sweep) and adds any run it finds a fact for. `schedule-status.json` goes
to schema 2: it adds `runsDue`, `checkingRunId` (the run the pass is on,
written before each run), `checkingStops`, `sweepStartedUtc` and
`lastSweepUtc`, and removes `resumeStops`; `resumeAtRunId` is now the place of
an open sweep, which goes to the end of the list and does not go round.

**Why.** Every pass read every run - about 530 store calls and its whole
210-second budget - though almost no run had anything due (2026-11-10).
Measured on a test store of 20 runs with one run due
(`tests/unit/ScheduleDue.Tests.ps1`): 351 store calls for a pass that checks
every run, 26 for the pass after it, 4 for a pass with nothing due.

**Migrating.** Nothing is rewritten by hand. A `schedule-status.json` of
schema 1 is read as no record (`Get-VmfSchedulePassCursor`), and no
`schedule-due.json` is there, so the first pass of this version checks every
run, writes `schedule-due.json` with each run a check acts on, and writes
`schedule-status.json` of schema 2 over the old one. A `schedule-due.json`
that cannot be used starts a sweep at once and is written over. Only the
product reads either document. The tests are
`tests/unit/ScheduleDue.Tests.ps1` and `tests/unit/SchedulePass.Tests.ps1`,
and `tests/unit/SamplesConform.Tests.ps1` holds both samples to their
schemas.

## vm-state v40 -> v41 (2026-11-08, ROLLBACK-ORIGINALS-LEFT-1)

**Change.** The state document gains `rollbackOriginals`: one entry for each
disk a rollback swapped off the machine - the disks it had before the
migration (`diskId`, `diskName`, `lun` with `null` for the OS disk,
`detachedUtc`, and once **Delete these disks** deleted it `deletedUtc`,
`deletedBy` and `gone`). The rollback writes each entry in the same write as
the disk it put on, after each swap (`Set-VmfRollbackRecord`), and **Finish
the rollback** does the same (`Add-VmfSwapFinished`). The disk swapped off at a
place is the one this attempt's capture (`captured.vmConfig`) names there. The
list is kept across attempts: **Try this machine again** does not clear it,
and a later rollback adds to it. The engine operation `deleteearlier` takes
`diskSet: rollback` (`Remove-VmfRestoreEarlierDisks -Set rollback`) and marks
each disk it deletes (`Add-VmfRollbackOriginalDeleted`).

**Why.** Since the put-back disks, a rollback puts the machine on new disks
made from the first safety copy, and the original disks stayed in Azure,
detached and costing money, with nothing that named them and nothing that
deleted them. The machine's panel now lists them under **Original disks, not
in use** (`Get-VmfRollbackOriginalDisks`, twinned in the page and held to
`tests/fixtures/rollback-originals.json`).

**Migrating.** Nothing is rewritten. A v40 document has no field. Its
original disks then come from the captures: at each place the last rollback
put a new disk on (`rollback.osDisk`, `rollback.dataDisks`), the disk the
first capture (`captured.original.vmConfig`) and this attempt's capture name
there, when it is not the new disk, detached at `rollback.rolledBackUtc`. The
first v41 write - the next rollback, Finish the rollback, or a delete - records
those entries, so no disk left before the change is lost. The daily cleanup
counts every disk on the list as a disk of the machine
(`Get-VmfRecordedMachineDiskIds`), so it never deletes one. The tests are
`tests/unit/RollbackOriginals.Tests.ps1` and
`tests/js/rollback-originals.test.js`, with the version pins updated in the
files that hold them.

## assessment v13 -> v14, target-advice v29 -> v30 (2026-11-08, SCAN-PARTIAL-SUBS-1)

**Change.** A subscription and region whose size list the scan could not read
no longer stops the scan. `Invoke-VmfAssessment` passes `-NotRead` and the new
`-NotReadError` to `Read-VmfMachineCatalogs`, so the other subscriptions
finish. `notRead` gains one entry with `subject: 'sizes'` for each
subscription and region not read (`Get-VmfSizesNotRead`): `subscriptionId`,
`location`, `reason` (`permission`, `subscriptionNotFound` or `other`, from
`Get-VmfReadFailureReason`), `statusCode`, `errorCode`, `detail` (Azure's
words, from `Resolve-VmfOperationError`), `machineCount`, and `requiredRole`,
`requiredAction` and `scope` - the role and action the permission map
(`data/rbac-actions.json`) gives `Get-AzComputeResourceSku`, on the
subscription. From v14 a `sizes` entry must carry `subscriptionId`,
`location`, `reason` and `machineCount` (the allOf rule). Each machine of that
subscription and region gets the blocker `sizes-not-read`, so it is Blocked:
in the assessment, never shown as able to move, and never planned from a size
nobody read. The target options copy each blocker of the scan as a reason, so
`target-advice` gains the reason `sizes-not-read` (v30).

**Why.** One subscription the scan identity could not read (AuthorizationFailed
on the size list) stopped the scan of every subscription, and no assessment
was saved. A temporary failure was, and still is, tried again by
`Invoke-VmfAzOperation`; nothing else was ever retried.

**Migrating.** Nothing is rewritten. A v13 assessment has no `sizes` entry:
its scan stopped instead of finishing without a subscription, so it never
holds a machine whose sizes were not read. The other `notRead` subjects keep
their shape. A v29 `target-advice.json` is refused by name and made again, as
for every earlier version (the targets step and `Set-VmfTargetChoice`); nothing
is converted. The tests are `tests/unit/ScanPartialSubs.Tests.ps1`, with the
version pins updated in the files that hold them.

## vm-state v39 -> v40 (2026-11-07, RESTORE-EARLIER-DELETE-1)

**Change.** The `restore` record gains `earlierDisksDeleted`: one row for
each earlier managed disk of that restore that **Delete these disks** deleted
(`diskId`, `deletedUtc`, `deletedBy`, and `gone` when Azure had no such disk
when the product read it). The engine operation `deleteearlier`
(`Remove-VmfRestoreEarlierDisks`) writes each row the moment it deletes the
disk (`Add-VmfRestoreEarlierDeleted`), only on the restore whose
`operationId` it read, and only for a disk that restore names as an earlier
disk (`Get-VmfRestoreEarlierDisks`: `retainedDiskId`, and each
`dataDisks[].previousDiskId` of a restore with `diskIdChanged`). A disk a
put-back made is marked `deletedUtc` on its own list in the same write.

**Why.** A restore that kept the earlier disks left them in Azure, costing
money, and only the Azure portal could delete them (hard rule 12). The
machine's panel lists them from the restore's record, so the record has to
say which are deleted for the list to empty, and a job that stops part way
must know what it already deleted (rule 4).

**Migrating.** Nothing is rewritten. A v39 document has no field, which
reads as no disk deleted: every earlier disk of its restore is listed, as
before. A later restore replaces the whole `restore` record, its earlier
disks and this list with it. The tests are
`tests/unit/RestoreEarlierDelete.Tests.ps1` and
`tests/js/restore-earlier-delete.test.js`, with the version pins updated in
the files that hold them.

## target-advice v28 -> v29 (2026-11-07, SIZE-FALLTHROUGH-NOTE-1)

**Change.** Each option gains `sizesNotTaken`: each size the default
transform tried before `targetSize`, and the gate that refused it, as
`{ size, why }`. `why` is one of `not-listed`, `not-in-region`,
`not-approved`, `gen1-no-size`, `too-few-nics`, `too-few-data-disks`,
`smaller-than-source`, `shape-unknown`, `one-accelerated-nic`. The list is
empty when the first size is the target, when the size was named (a size
choice, a size by shape), and when the option has no target. It comes from
`Get-VmfTargetSize`, which now returns `NotTaken` with the facts of each gate.
The targets step puts it in words behind a (?) on the Temporary disk row of
Details (`tNotTakenText`). The plan entry does not change: the same reason
goes into the existing `planNotes` (`Get-VmfSizeNotTakenNote`), so plan-entry
stays at v30.

**Why.** For a machine with a temporary disk the default transform tries the
d size first, then the size without one. When the d size failed a gate, the
plan and the targets step showed the size without one and said nothing about
why; on Windows that size changes the kind of temporary disk, which makes the
move the in-place upgrade (Preview).

**Migrating.** As for every earlier version of the target advice, a v28 file
is refused by name and made again (`Set-VmfTargetChoice`,
`Set-VmfMachineChoice`, `New-VmfPlan`; the targets step waits for new
options). Nothing is converted. The page reads an option with no
`sizesNotTaken` as no note, never as an error, and a plan made before this
version has no note. The tests are `tests/unit/SizeFallThroughNote.Tests.ps1`
and `tests/js/size-fallthrough-note.test.js`, with the version pins updated in
the files that hold them.

## assessment v12 -> v13, plan-entry v29 -> v30, capacity-claim v14 -> v15 (2026-11-07, CRG-MOVE-DEMAND-1)

**Change.** The scan records `capacityReservationGroupId` on each machine:
the resource id of the capacity reservation group the machine is in, from
Azure Resource Graph (`properties.capacityReservation.capacityReservationGroup.id`),
and `null` for a machine in no group (assessment v13). `New-VmfPlan` carries
it into the plan entry's `assessment` block (plan-entry v30), only when the
record has it. The quota record gains `demand.ownGroupVmIds` (capacity-claim
v15): the machines of the record that the assessment found in a capacity
reservation group this migration did not make. `reservableInstances` leaves
them out, as it leaves out an availability set member, so the reserved count
and the price count only the places the wave's machines use.

One rule decides it: `Test-VmfEntryReservable` (now with a required
`-ProductGroupIds`) asks CRG-MOVE-1's `Get-VmfOwnReservationGroup` of the
plan entry's assessment. Check the quota, the Reserved gate, the start's line
and CONVERTING all ask it. CONVERTING takes the wave's reservation only for a
machine the rule counted: a machine the assessment found in its own group
that is in no group at the move moves with no capacity reservation, and the
activity says why.

**Why.** CRG-MOVE-1 keeps such a machine in its own group through the move,
but the quota check counted it, so the wave reserved and billed for a place,
and took quota for it, until the release at the end of the wave.

**Migrating.** Nothing is rewritten. A v12 assessment and a v29 entry have no
field: the machine's group is unknown, and it is counted for a reservation as
before (unknown is never a no). Plan again from a new assessment to get the
field. A v14 quota record has no `ownGroupVmIds`, which reads as none: every
machine it leaves out is an availability set member, as it said. The tests
are `tests/unit/CrgMoveDemand.Tests.ps1`, with the version pins updated in the
files that hold them.
## lease v1, new schema (2026-11-07, WAVE-RUNNING-LEASE-1)

**Change.** `leases/<machine key>.lease` now has a schema,
`schemas/lease.schema.json`, with a sample, and `New-VmfLease` writes
`schemaVersion: 1` into it. The fields are the four it always wrote: `vmId`,
`workerId`, `acquiredUtc` and `heartbeatUtc`. A renewal rewrites the lease it
read, so it keeps the version.

**Why.** Hard rule 1: the Migrations page and the wave editor now read the
leases, so the document crosses a component boundary. A held lease keeps a
wave running there, as it does in the engine (`Get-VmfMachineHold`).

**Migrating.** Nothing to rewrite. A lease lives only while its job runs; one
an earlier engine wrote has no `schemaVersion`, and every reader reads its four
fields as before. The test is `tests/unit/WaveRunningLease.Tests.ps1`: a new
lease and a renewed lease are valid, and a lease with no holder is refused.

## assessment v11 -> v12 (2026-11-07, REBUILD-REMOVE-ROLE-1)

**Change.** The scan no longer writes
`rebuildLinks.dataCollectionRuleAssociations`, and no longer reads the data
collection rule associations of each machine. From version 12, an `allOf`
rule in the schema refuses the field. The property stays in the schema, so
an older assessment that holds it stays valid.

**Why.** Since 2026-11-07, the rebuild around the same disks (Path B) is
removed. Only the acceptance of a rebuild showed the associations, and the
rebuild was the only move that deleted them. The read cost one call per
machine on every scan, and both roles held
`Microsoft.Insights/dataCollectionRuleAssociations/read` for it. That
action left `data/rbac-actions.json`, and with it both roles, with the
same change: `Microsoft.Compute/virtualMachines/delete` (Remove-AzVM) and
the New-AzVM entry left too. `Microsoft.Network/networkInterfaces/join/action`
stays, on the Update-AzVM entry: a resize sends the machine's network
interfaces, and Azure checks the join on each one.

**Migrating.** Nothing to rewrite. Every reader takes a v9 to v11 assessment
as it is: no remaining reader uses the list. An installation keeps the old
actions in its two custom roles until the next `azd up`, which updates the
role definitions in place (the same role ids, so every assignment keeps
working). The extra actions do nothing on such an installation: no code asks
for them. The test is `tests/unit/RebuildRemoveRole.Tests.ps1`, with the
version pins updated in the files that hold them.

## run-status v5 -> v6 (2026-11-07, RUN-SUMMARY-SWAP-1)

**Change.** The summary gains `waitsOnPerson`, and each wave of it gains its
own `waitsOnPerson`: the machines whose outcome waits for a person -
`Get-VmfMachineOutcome` says `attention` or `rolledBack`
(`Test-VmfOutcomeWaitsOnPerson`, twinned in help.js as `outcomeWaitsOnPerson`
and held to `tests/fixtures/machine-outcomes.json`). It counts a machine that
Restore this machine left stopped with a data disk swap left (`swapPending`),
whose state stays MIGRATED. `stateCounts` and `restoredStops` are unchanged.
The quick path keeps a wave's counts only when its stored `waitsOnPerson` is 0,
so a v5 wave, and a wave with a machine that waits, is read again. The wave's
ten-second write keeps the other waves' count, and moves the running wave's
count by the change in its stop states; over a v5 summary it writes no count.
The engine's restore operation now writes the summary in a `finally`, so a
restore that leaves a swap and throws writes it too.

**Why.** The overview and the migrations list counted the summary by state,
so a migration with a machine a restore left stopped was not under Needs
attention, and the overview said no machine needs attention.

**Migrating.** Nothing is converted on read. A v5 summary has no count, and
the pages (`runWaitingCount`, `runGroup`, the Overview) read it by the stop
states less `restoredStops` - as they did. The writer builds a v5 document
again in full at the next write, and the daily check writes every migration,
so an installation is all v6 a day after `azd up`. The tests are
`tests/unit/RunSummarySwap.Tests.ps1` (the rule, the count, the quick path,
the ten-second write, a v5 summary patched, the restore operation, the
contract sample) and `tests/js/run-summary-swap.test.js` (the rule, the list
and the Overview, run, on v6 and v5 summaries).

## wave-schedule v1, description only (2026-11-07, SCHEDULE-WAVE-VERSION-1)

**Change.** The file description and the `state` description now say that a
scheduled start carries the version of the wave the pass judged, and that the
engine run of that start removes the schedule when its read of the wave is
that version, or puts a `starting` or `started` schedule back to `pending`
with no start on record when it is not (`Reset-VmfScheduleStartRecord
-StartId`). The service no longer removes a `started` schedule while an engine
run of its start goes on. Both writes give documents that already had a valid
shape. No field, type or rule changed, so `schemaVersion` stays 1 and nothing
is rewritten.

**Test.** `ScheduleWaveVersion.Tests.ps1`: the engine's put-back, from
`starting` and from `started`, writes a document valid against the schema,
with the fields of the pending schedule as written.

## wave-schedule v1, description only (2026-11-07, SCHEDULE-STARTING-STUCK-1)

**Change.** The file description and the `state` description now say that a
start that was not made, and that a check then stops (the window, the
approval, a change after the sign-off), goes back to `pending` with no start
on record (`Reset-VmfScheduleStartRecord`). The service now writes that; a
pending schedule already had that shape. No field, type or rule changed, so
`schemaVersion` stays 1 and nothing is rewritten.

**Test.** `WaveScheduleContract.Tests.ps1`: the put-back writes a valid
pending document with the fields that were written, and never writes over
another version, a pending, a started or a removed schedule.

## wave-schedule v1, new schema (2026-11-07, SCHEDULE-SCHEMA-1)

**Change.** `schedules/<wave>.json` now has a schema,
`schemas/wave-schedule.schema.json`, with a sample. The document already
carried `schemaVersion: 1`; the schema describes it as it is: the states
`pending`, `starting` and `started`, and the start record of
SCHEDULE-START-ONCE-1 (`startId`, `startingUtc`, `executions`, `startedUtc`),
which a pending schedule does not have and a start on record must have. It
also declares `throttle`, the number of machines at once that
`Set-VmfWaveSchedule` wrote from SCHED-1 until MACHINES-AT-ONCE-RANGE-1: an
optional integer that nothing reads (a scheduled wave starts at its own number
from the plan), kept so a schedule written then stays valid, also after the
start record is written into it. No other field was ever written (the history
of `Set-VmfWaveSchedule` and of the start record). Every
time is UTC, as the round-trip text. `Get-VmfWaveScheduleSchemaVersion` gives
the version that `Set-VmfWaveSchedule` writes. Two writes that broke the shape
are closed: `Set-VmfWaveSchedule` refuses a negative time window (the
migration page sent the number as it was typed, and the wave then never fitted
the window and never started), and writes `unknown` when the service gives no
name of who scheduled it. A start whose answer named no execution is now
written as `started` with an empty list; before, the call that writes it threw
on the empty list, and the schedule was removed from `starting`.

**Why.** Hard rule 1: the document crosses a component boundary (the service
writes it; the service, the plan continue rule and the migration page read it),
and SCHEDULE-START-ONCE-1 added two states and four fields with nothing to
check them.

**Migrating.** Nothing to rewrite, and the version stays 1: every document the
service wrote is valid, with or without `throttle`, except one with a negative
time window. Such a
schedule never started; cancel it and schedule the wave again. The test is
`tests/unit/WaveScheduleContract.Tests.ps1`: what each writer writes is valid,
a document that breaks a state's rule is refused, and each field a reader
names is a field the schema declares.

## wave-options-acceptance v7 -> v8, wave-approval v3 -> v4 (2026-11-07, REBUILD-REMOVE-ACCEPT-1)

**Change.** The acceptances that existed only for the rebuild around the same
disks (Path B) are removed. wave-options-acceptance: `identityLoss` and
`rebuild` are no longer written. wave-approval: `identityLoss` is no longer
written; the per-wave approvals that the sign-off of the plan writes are v4
too. Both properties stay in the schemas, with no allOf rule: a v4 to v7
acceptance, or a v3 approval, still reads, and a decision's amendment that
stamps such a record with the current version keeps them (the shape of
plan-entry v29). `Confirm-VmfWaveOptions`, `Approve-VmfWave` and
`Approve-VmfPlan` take no `-IdentityLossNamed` or `-RebuildNamed`, and
`Resolve-VmfDecision` takes no `-IdentityLossPrincipalId` or
`-RebuildExtensions`. The wave setting `onSystemAssignedIdentity` is no longer
written: a wave save does not carry it, and a decision refuses it by name, as
it refuses `rebuild`. A plan entry and a decision that hold them still read
(plan-entry v22 to v28), with no plan-entry change.

**Why.** The decision of 2026-11-07 removed the rebuild, and
REBUILD-REMOVE-PLAN-1 stopped every new plan from giving it. With no rebuild,
nothing is left for a person to accept: the identity is always kept, and so are
the extensions, the SQL virtual machine resource and the data collection rule
associations.

**Migrating.** Nothing to rewrite. A plan an earlier version wrote can still
hold Path B, or the method `rebuild`. It is never accepted and never dropped
in silence: the acceptance of its wave, the approval of its wave and the
sign-off of the plan refuse it by name (`400: Nothing was recorded. The plan
rebuilds ...`), and PRECHECK stops such a machine untouched with the new reason
`rebuildNotSupported` (retry `notSupported`) - plan it again. The reasons
`systemIdentityCannotSurvive`, `rebuildNotAccepted`, `captureNotReproducible`,
`sqlVirtualMachineNotRead` and `dataCollectionRuleAssociationsNotRead` are
gone; a machine an earlier version parked at one shows its stop with the
generic title and its detail, and a retry stops it at `rebuildNotSupported`.
No installation runs in the wild. The test is
`tests/unit/RebuildRemoveAccept.Tests.ps1`, with the version pins updated in
the files that hold them.

## assessment v10 -> v11 (2026-11-06, READY-NOW-REMOVE-1)

**Change.** The scan no longer writes the classification `ReadyNow`, on a
machine record or as a key of `summary`. A machine on the NVMe disk
controller with no blocker is `ReadyAfterPrep`, like any other machine with
none. The schema holds it: from version 11, an `allOf` rule refuses
`ReadyNow` in `vms[].classification` and in `summary`. The enum keeps the
value, so an older assessment stays valid. A machine already on NVMe keeps
the preparation `stornvme` or `linux-nvme-prep`: the engine runs both NVMe
scripts for it, which are idempotent.

**Why.** Decided 2026-11-06. `ReadyNow` went to every machine on NVMe and
read **Already on a target size** and **Already migrated**, with no move
offered. After ALREADY-CURRENT-1 shows a machine on a Current size as
Current, the only machines left with it were the v5 sizes with NVMe, Ebsv5
and Ebdsv5, which are in the Extended stage and have Ebsv6 as their
successor. Such a machine is now assessed like any other: Can migrate when a
target exists, else Cannot yet with its reason. The plan finds a path to v6
or v7 for a machine on NVMe only when the lifecycle data puts its size in a
stage that is not Current (`Test-VmfAlreadyOnNvmeTarget`).

**Migrating.** Nothing to rewrite. Every reader takes an older `ReadyNow` as
`ReadyAfterPrep`: the engine through `ConvertTo-VmfOwnClassification`
(`Resolve-VmfEntryClassification`, the migration record's counts and its
per-machine classification), and the pages by the same rule (the wizard's
found list, the run page's `judgeForSeries`, the shared counts). The plan
entry is unchanged: its schema still allows the value, and a plan built from
this version never holds it: `New-VmfPlan` reads an older `ReadyNow` as
`ReadyAfterPrep` too.

## target-advice v27 -> v28, target-choices v7 -> v8, plan-entry v28 -> v29 (2026-11-07, REBUILD-REMOVE-PLAN-1)

**Change.** The rebuild around the same disks (Path B) is removed from the
target options and the plan. target-advice: no option and no size choice has
`path` `B`; the fields `rebuild` and `identity` of each option and size
choice, and `identityPrincipalId` and `decide` of each machine, are gone;
`preview` says the move is the in-place upgrade (Preview), for Generation 1
too; the reason `disk-encryption-rebuild` is now `disk-encryption-preview`
(also as a value of `burstableTarget`); the reasons `generation-unknown` and
`temp-disk-change-not-measured` are new. The start of each machine is the
first supported option in the order of its default (only the accelerated
networking rule of ADVISE-AN-1 and the Bsv2 start of BSV2-TARGET-1 still move
it). target-choices: `method` is `in-place` or `preview`; an allOf rule holds
a version-8 file to that. plan-entry: no new entry has `path` `B` or
`target.choice.method` `rebuild`, and `assessment.rebuildLinks` is no longer
written. A Windows machine whose move changes the kind of temporary disk is
Path A with method `preview`. A Windows machine with no temporary disk that
moves to an NVMe temporary disk, or back, is Path A with method `in-place`:
measured on 2026-11-07 both ways with the feature not registered, because
Azure reports that NVMe disk as `MaxResourceVolumeMB` 0.

**Why.** The decision of 2026-11-07: every move is the in-place
upgrade, or the in-place upgrade (Preview) with Microsoft's preview feature
`VMTempDiskResizePreview`. Fourteen checks that day (with eight from
2026-11-01 and 2026-11-02, docs/research/temp-disk-in-place-preview.md)
measured Generation 1 and F, so the Preview covers every shape the defaults
give. A shape nobody measured has no move at all (MANUAL, with the reason) -
never worse than a rebuild, which deleted the VM definition with its
system-assigned identity and its extensions. A machine with Azure Disk
Encryption whose move changes the kind of temporary disk stays refused.

**Migrating.** Nothing to rewrite. A target-advice v27 file offers rebuilds,
so it is refused by name and made again, as every earlier version is; the
targets saved against it are then saved again. A target-choices file of v7 or
older still passes the schema, `rebuild` included, and `New-VmfPlan` refuses a
saved `rebuild` by name. A plan entry written before v29 still reads, `path`
`B`, `method` `rebuild` and `rebuildLinks` included, and every engine and page
path that handles them stays until its own removal (REBUILD-REMOVE-ACCEPT-1,
-ENGINE-1, -RECOVER-1). `B` and `rebuild` stay in the plan-entry enums, with
no allOf rule: a later save (the wave settings, accelerated networking) stamps
an older entry with the current version and keeps its path. No installation
runs in the wild. The tests are `tests/unit/RebuildRemovePlan.Tests.ps1` and
`tests/js/rebuild-remove-targets.test.js`, with the version pins updated in the
files that hold them.

## assessment v9 -> v10 (2026-11-06, ALREADY-CURRENT-1)

**Change.** Each machine record gains `sourceLifecycle`: `{ stage, basis }`,
Microsoft's lifecycle stage of the size the machine is on now, read from the
lifecycle data in `target-families.json` by `Get-VmfSizeLifecycleStage`
(through `Get-VmfAdviceStage`, the shape the target advice already writes for
a size). `basis` is `stated` when Microsoft names the stage and `derived` when
it follows from Microsoft's own definitions. `null` when the data holds no
stage for the size. The field is optional: a v9 record has none.

**Why.** Lab finding 81 (2026-11-05): machines already on D2ds_v6 read a red
**Cannot yet** on Choose the machines and in the assessment, and were counted
with the machines that cannot move. The rule since 2026-11-06: a machine whose
current size Microsoft puts in the Current lifecycle stage is in the group
**Current**, with the line "<size> is in the Current lifecycle stage.", not
red, not in the Cannot yet count, and not selectable. The pages read the stage
from the record, so no page holds a copy of the size rules.

**Migrating.** Nothing to rewrite. A v9 assessment has no stage, so its
machines are grouped as they were until the estate is assessed again. No page
reads the stage from the size name.

## vm-state v38 -> v39 (2026-11-06, POWER-AFTER-MOVE-1)

**Change (vm-state).** A new top-level object, `powerReturnPending`
(`power`: `PowerState/deallocated` or `PowerState/stopped`; `next`:
`MIGRATED`; `startedUtc`). The engine writes it when a move passed every
check of Verifying on a machine that Checking found Stopped (deallocated) or
Stopped (`captured.clusterCheckPower`), BEFORE it returns the machine to that
power state (`Set-VmfPowerReturnPending`), and removes it in the same write
as MIGRATED (`Complete-VmfPowerReturn`). A worker that stops in between
leaves it, and the next worker finishes the return first - it never runs
Verifying again on a machine that may be deallocated. A writer of the field
raises the document to v39.

And two fields on records a restore writes (POWER-FOUND-AGE-1, folded in;
2026-11-06): `putBackJob.powerAtStart` and `swapPending.powerAtStart`
(`PowerState/running`, `PowerState/deallocated`, `PowerState/stopped` or
null). Restore this machine reads the power state of the machine before it
changes anything (`Get-VmfJobStartPower`) and keeps it in its checkpoint, so a
resume returns the machine to that reading and never reads a machine the job
started; a swap it leaves keeps it for Finish the restore, and the restore record keeps it (`restore.powerAtStart`). Rebuild this machine, which finds no machine, keeps the newest power state on record in `putBackJob.powerAtStart`. A job written
before v39 has neither: the machine runs at its end, as before.

Behaviour that writes no new field: a rollback, Restore this machine, Rebuild
this machine, Finish the rollback and Finish the restore also end with the
machine in the power state Checking found; a return Azure refuses at every
try is owed with the v37 field (`history[].powerNotPutBack`), now also on
MIGRATED and FAILED_ROLLED_BACK. `Add-VmfStateTransition` writes `changed`
with the power state still owed for a later stop that says `restored`, as it
did for `untouched`.

**Why.** Since 2026-11-06, a machine ends in the power state it had at the
start, on or off. A machine found turned off ran, and billed, after its
move or its rollback.

**Migrating.** Nothing to rewrite. A v38 document has no checkpoint: a move
that ended before v39 left a machine found turned off running, and the
record says nothing is owed. Readers that do not know the field ignore it;
the state is VALIDATING while it stands, which every reader already knows.

## run-status v4 -> v5 (2026-11-06, RESTORED-HOLD-1)

**Change.** The summary gains `restoredStops`, and each wave of it gains its
own `restoredStops`: the machines counted in `stateCounts` under a stop state
(`FAILED_ROLLED_BACK`, `FAILED_NEEDS_ATTENTION`, `NEEDS_DECISION`) whose stop
a restore ended - `Get-VmfMachineOutcome` says `putBack`, the rule of
STATUS-WORDS-1. `stateCounts` is unchanged: each machine stays under its own
state, and no state is added. `summary.reason` takes one more value, `putBack`:
the engine writes the summary after a restore and after a finish of a restore
or a rollback (`Update-VmfRunSummaryAfterPutBack`). The wave's ten-second
write keeps the other waves' count and gives the running wave none until the
wave's last write builds the summary from the store.

**Why.** A restore does not change the state, so a migration whose only
stopped machine was restored stayed under Needs attention on the Migrations
list, the Overview's card counted the machine as waiting for a person, and the
summary said its next wave waits for a decision.

**Migrating.** Nothing is converted on read. A v4 summary has no count, and
the pages (`runGroup`, `runProblemCount`, the Overview) read it as none - as
they did. The writer builds a v4 document again in full at the next write, and
the daily check writes every migration, so an installation is all v5 a day
after `azd up`. The tests are `tests/unit/RestoredHold.Tests.ps1` (the count,
the quick path, the ten-second write, a v4 summary patched, the contract
sample), `tests/unit/RunSummary.Tests.ps1` (the schema and the engine agree),
and `tests/js/restored-list.test.js` (the list and the Overview, run, on v5
and v4 summaries).

## target-advice v26 -> v27, plan-entry v27 -> v28 (2026-11-06, AN-MANA-DRIVER-RULE-1)

**Change.** target-advice: the reason `no-mana-driver` replaces
`an-required-no-mana` and `an-intel-v5`. Every size that can give the MANA
adapter (every v6 and v7 size, Intel and AMD, Intel v5 and Bsv2) is not
offered to a machine whose VM agent reports a Linux release with no MANA
driver possible, whether it uses accelerated networking today or not. Each
`linuxRelease` gains `manaUpgrade`, the release to upgrade to (null for every
other machine). The decide reason `processor-or-an`, with `keepsProcessor` and
`keepsAn`, is gone: no option offers an Intel machine an AMD size.
plan-entry: the contract refuses `policy.acceleratedNetworking` = `ensureOff`
on an NVMe target (v6, v7). And `policy.onDriverBelowFloor` = `proceed` is no
longer written (AN-PROCEED-NETVSC-1, 2026-11-06: a machine whose network
cannot work on accelerated networking is not allowed to continue): the wave save and the plan levers allow
only `stop` (and `updateKernel`, per machine, from the targets step), and the
stop `driverBelowFloor` has no decision. The enum keeps `proceed` so an earlier
plan still reads; the engine stops such a machine untouched all the same.

**Why.** The design of 2026-11-06: a target that can give MANA needs
a machine with a MANA driver. MEASURED the same day (centralus, Ubuntu 22.04,
one region, one day): with the interface's accelerated networking set to
false, Azure still attached the virtual function on Intel v5, Bsv2, AMD v6,
Intel v6 and v7 and AMD v7; only AMD v5 gave none. So "off" is not off on
those sizes, and the machine ran on the synthetic interface. The product used
to plan exactly that: the Intel v7 card with `ensureOff`, and a v7 start that
kept a machine's accelerated networking off.

**Migrating.** Nothing to rewrite. A target-advice v26 file can offer Intel
v7 with accelerated networking off, or an AMD size to an Intel machine, so it
is refused by name and made again, as every earlier version is. A plan entry
written before v28 still reads; one that holds `ensureOff` on a size that can
give MANA (or `preserve` on a primary that is off) is stopped untouched in
Checking (`acceleratedNetworkingRequired`) for an approver to accept
accelerated networking. No installation runs in the wild. The tests are
`tests/unit/AnManaDriverRule.Tests.ps1` and
`tests/js/an-mana-driver-rule.test.js`, held to
`tests/fixtures/an-mana-driver-rule.json`, with the version pins updated in
the files that hold them.

## vm-state v37 -> v38 (2026-11-06, FINISH-EMPTY-LUN-WORDS-1)

**Change (vm-state).** Each row of `swapPending.swaps` can carry two more
fields:

- `lunHolds` - what is on the LUN, as the product last found it: `had` (the
  disk the row names, `name` and `oldDiskId`), `none` (no disk: a swap stopped
  between its two updates), `notRead` (the product did not read the LUN after
  a swap that did not finish), or `other` (a disk that is neither the disk it
  had nor the disk made from the copy). Written where the row is written
  (`New-VmfSwapLeftRow -Holds`, `Set-VmfEmptyLunRow`), and again by Finish the
  rollback or Finish the restore when Azure refuses a disk again.
- `oldTemporary` (FINISH-TEMP-DISK-LEFT-1) - keeping the names, the disk on
  the LUN is the temporary disk made from the copy, and the disk that waits is
  the disk made under the old name (step 6). `name` is now the temporary
  disk's name for such a row; it was the old name, which is the name of the
  disk that waits.

**Why.** The Finish dialog said for every row "On LUN n, the disk X is still
attached". For a LUN with no disk, a LUN the product did not read and a LUN
that holds a third disk, that is false, and the page had no way to know which
it was. And after Finish put the disk under the old name on a LUN that ran on
its temporary disk, the restore's record named the temporary disk as the disk
the LUN had, so the daily cleanup never deleted it and it billed until a
person found it. Now Finish records the disk under the old name as the disk
the LUN had (the same name and id step 6 records), names the temporary disk
as free, and the daily cleanup deletes it once the move has ended.

**Migrating.** Nothing to rewrite. A v37 row has neither field: the Finish
dialog says the record does not say which disk is on the LUN, and that Finish
reads it first - which Finish always does. A v37 row of step 6 still names the
temporary disk as the disk the LUN had when Finish ends it, as before.

## vm-state v36 -> v37 (2026-11-06, POWER-ONLY-CHANGED-1)

**Change (vm-state).** `history[].powerNotPutBack` (`PowerState/deallocated`
or `PowerState/stopped`), only on a stop with `machineState` `changed`: the
machine is changed ONLY in its power state. Azure refused, at every try, to
put back the power state Checking found (`Invoke-VmfPowerPutBack`, through
`Invoke-VmfAzOperation`). The cluster check, every stop that puts the power
state back (STOP-POWER-AS-FOUND-1), Stop this migration (for a machine that
Checking started and nothing else changed), and a retry whose put-back is
refused again (the new stop reason `powerNotPutBack`) write it. A writer of
the field raises the document to v37. `Add-VmfStateTransition` writes
`changed` with the power state still owed for any later stop that says
`untouched`, except the line of a put-back that worked.

**Why.** A stop whose put-back Azure refused was recorded `changed`, and its
retry and claim were held until a restore or a rebuild - but its disks, size,
controller and network were as they were, and a stop at Checking has no
safety copy to restore. The rule since 2026-11-06: the product must put the
machine back to its power state.

**Migrating.** Nothing to rewrite. A v36 document has no field, so a stop
whose put-back was refused before v37 stays held, as it was, until a restore
or a rebuild. Readers that do not know the field read the stop as
`changed`, which is the cautious answer.

## plan-entry v26 -> v27 (2026-11-06, MACHINES-AT-ONCE-RANGE-1)

**Change.** `policy.throttle` - how many machines at once - is written as one
of four choices: 5, 15, 30 or 60 (Pilot, Standard, Large and Maximum;
2026-11-06). A new plan gets 15, one engine container; it was 3. The planner,
the wave editor (`Set-VmfWavePlan`) and a policy override
(`Test-VmfPolicyOverride`) write only a choice. The limit is 60, which the
engine has run since SCALE-2 (four containers of 15): the schema already said
`maximum: 60`, but its description and the lever table still said 20.

**No start carries a number of its own.** The Run it step and the start
dialog each set a number for one start (the first wave only, on Run it). The
service now reads the wave's own number for every start - from a page, a
schedule, the signed-off plan or a resume - by one rule,
`Get-VmfWaveThrottle`: the first machine of the wave with a number, else the
default. `Set-VmfWaveSchedule` and `Test-VmfWaveWindow` lost `-Throttle`, and
a schedule document no longer holds `throttle` (an older one that does is
read, and the field is ignored).

**Reading an older entry.** Unchanged: it keeps the number it holds, any
whole number 1 to 60, and the engine runs it. The wave editor shows that
number as it is and saves it while nobody changes it; a change, or a machine
that joins that wave, needs one of the four choices first. An entry with no
number at all (written before v12) now reads as 15, the default, where it
read as 3 - the same reading `Get-VmfPolicy` gives every missing setting. No
installation holds a plan from before v12.

**Test.** `tests/unit/MachinesAtOnceRange.Tests.ps1` and
`tests/js/machines-at-once.test.js`.

## assessment v8 -> v9, vm-state v35 -> v36, plan-entry v25 -> v26, wave-options-acceptance v6 -> v7 (2026-11-06, DCR-READ-1)

**Change (assessment).** `rebuildLinks.dataCollectionRuleAssociations`: the
names of the machine's data collection rule associations, listed by the
machine (`GET <vm id>/providers/Microsoft.Insights/dataCollectionRuleAssociations`,
Microsoft's operation Data Collection Rule Associations - List By Resource);
an empty list for none, null when the read failed. It is optional: a v8
record has none.

**Change (vm-state).** `captured.dataCollectionRuleAssociations` (a list of
names): what PRECHECK read before a rebuild (Path B), with the scan's read,
in the operation wrapper. A capture that writes it raises the document to
v36. A read that fails is never written: the machine stops untouched with the
new reason `dataCollectionRuleAssociationsNotRead`.

**Change (plan-entry).** A decision for the setting `rebuild` may carry
`dataCollectionRuleAssociations`: the names Checking read before the stop,
which the stop named and the dialog listed. `Resolve-VmfDecision` writes it
from the capture, only when Checking found any.

**Change (wave-options-acceptance).** A follow-up in `rebuild[].followUps`
may have the kind `dataCollectionRuleAssociations`, with `names`, and a
`notChecked` follow-up may have the item `dataCollectionRuleAssociations`.
Nothing makes the kind `monitorAgent` any more; the schema still accepts it,
so an older record stays valid.

**Change (permissions).** The VMF Assessment role gains
`Microsoft.Insights/dataCollectionRuleAssociations/read`, and so the VMF
Migration role, which holds every action of the assessment role. Checking
requires it only of a rebuild (`requiredFor: rebuild` in
`data/rbac-actions.json`).

**Why.** A rebuild deletes the machine's definition, and Azure deletes its
data collection rule associations with it (measured 2026-11-01,
`docs/research/rebuild-impact-2026-11-01.md`). The acceptance said so only
when the machine had the Azure Monitor Agent extension (the follow-up
`monitorAgent`), and nothing read the associations. A machine with the agent
and no association was given a false warning, and associations with no agent
were deleted with nobody told (lab install, 2026-11-05).

**Migrating.** Nothing to rewrite. A v8 assessment has no list: the lists
before the move say the associations were not checked, and Checking reads
them before the rebuild. A v35 state document has no list: the decision
records none, the line after the delete uses the scan's list, and the next
PRECHECK reads them. A v25 rebuild decision has no list: it accepts the
associations the scan found, as the page showed them then; an association
made after the scan stops the machine (`rebuildNotAccepted`). A v6 wave
acceptance names no association: an association Checking finds stops the
machine, and an approver accepts it for the machine alone. An installation
whose role predates the read stops each rebuild untouched (`permissionsMissing`,
naming the action) until it is updated; a resize in place is not affected.

## vm-state v34 -> v35, plan-entry v24 -> v25 (2026-11-05, SQLVM-REREAD-1)

**Change (vm-state).** `captured.sqlVirtualMachine` (boolean): whether the
machine had a SQL virtual machine resource
(`Microsoft.SqlVirtualMachine/sqlVirtualMachines`) when PRECHECK read it,
before a rebuild (Path B). PRECHECK reads it with the scan's read
(`Get-VmfVmSqlVirtualMachine` over `Get-VmfSqlVirtualMachines`) and writes it
with the rest of the capture. A capture that writes it raises the document to
v35. A read that fails is never written: the machine stops untouched with the
new reason `sqlVirtualMachineNotRead`.

**Change (plan-entry).** A decision for the setting `rebuild` may carry
`sqlVirtualMachine: true`: the person accepted the rebuild of the machine
while Checking had read a SQL virtual machine resource, which the stop named.
`Resolve-VmfDecision` writes it from `captured.sqlVirtualMachine`.

**Why.** A rebuild deletes the machine's definition, and Azure deletes the
SQL virtual machine resource with it (measured 2026-11-01,
`docs/research/rebuild-impact-2026-11-01.md`). The acceptance of a rebuild
named that resource only when the scan found it, and Checking never read it
again. A machine registered with the SQL IaaS Agent after the scan lost the
resource in a rebuild that nobody accepted. Now the rebuild gate stops such a
machine unless a record showed the resource: the decision recorded it, the
scan found it (the page listed it), or the follow-ups of the wave's
acceptance list it.

**Migrating.** Nothing to rewrite. A v34 state document has no
`sqlVirtualMachine`: the decision records none, the line after the delete
uses the scan's fact, and the next PRECHECK reads it. A v24 rebuild decision
has no `sqlVirtualMachine`: it accepts the resource only when the scan found
it, as the page showed it then; a machine registered after the scan stops
again and is accepted once more. The tests are
`tests/unit/SqlVmReread.Tests.ps1`, `tests/unit/RebuildAccept.Tests.ps1` and
`tests/js/rebuild-follow-ups.test.js`, with the version pins updated in the
files that hold them.

## target-advice v25 -> v26 (2026-11-05, DRIFT-11-OTHER-OPTIONS-1)

**Change.** The reason list gains `an-required-no-mana`: the target size
requires accelerated networking and can give the MANA adapter (every v6 size,
and Intel D and E v5), and the VM agent of the machine reports a Linux release
that Microsoft does not list for MANA. Such a size is not offered: the option
is not supported, and a size choice with that size is left out.

**Why.** Lab install, 2026-11-05, an Ubuntu 18.04 machine: the targets step
said "v6 Available: D2s_v6. Accelerated networking is off on this size", and
the series list offered v6. Since 2026-10-27 every v6 size requires
accelerated networking (DRIFT-11). On v6 the plan cannot turn it off, and the
release has no MANA driver, so the move stopped in Preparing
(`driverBelowFloor`); a machine with it off stopped in Checking first. The
same case was ruled out for Intel v5 on 2026-10-12 (`an-intel-v5`). One
rule (`Test-VmfAnRequiredWithoutMana`), asked in `Resolve-VmfEntryTarget`, so
the target advice, the plan and the wave editor agree.

**Migrating.** Nothing to rewrite. A target-advice v25 file can offer v6 to
such a machine, so it is refused by name and made again (`Set-VmfTargetChoice`,
`Set-VmfMachineChoice`, `New-VmfPlan`, the targets step), as every earlier
version is. A plan built before this change keeps its entries; a machine
planned on v6 stops in Checking or Preparing for an approver, untouched, as
before. The wave editor (`Test-VmfPlannedTargetAgrees`) no longer gives such
an entry back. The tests are `tests/unit/Drift11OtherOptions.Tests.ps1` and
`tests/js/drift11-other-options.test.js`, with the version pins updated in the
files that hold them.

## assessment v7 -> v8, wave-options-acceptance v5 -> v6 (2026-11-04, REBUILD-PATCH-MODE-1)

**Change (assessment).** `rebuildLinks` gains `patchMode`: the patch mode of
the VM (`osProfile.windowsConfiguration.patchSettings.patchMode`, or the
`linuxConfiguration` one), read in the same Resource Graph query as the rest
of the machine; null when the VM has none. It is optional: a v7 record has
none.

**Change (wave-options-acceptance).** A follow-up in `rebuild[].followUps`
may have the kind `patchMode`: the patch mode AutomaticByPlatform, which a
rebuild removes.

**Change (plan-entry).** None in the schema: `assessment.rebuildLinks` is
carried as it is, and `patchMode` comes with it.

**Why.** Measured in the lab on 2026-11-04: a rebuild of a Windows machine
with the patch mode AutomaticByPlatform failed after the definition was
deleted, because Azure refused the patch mode on the rebuilt machine.
Microsoft: AutomaticByPlatform "is only supported for VMs that are created
using the supported OS platform images", and a rebuilt machine is created
around its attached OS disk. A rebuild no longer asks for it, and the
acceptance of a rebuild names it.

**Migrating.** Nothing to rewrite. A v7 assessment has no `patchMode`: the
lists before the move do not name it, and the move still says it, from the
patch settings the capture read, just after the definition is deleted. A v5
acceptance has no `patchMode` follow-up and is read as before. The tests are
`tests/unit/RebuildPatchMode.Tests.ps1`, `tests/unit/RebuildAccept.Tests.ps1`
and `tests/js/rebuild-follow-ups.test.js`, with the version pins updated in
the files that hold them.

## vm-state v33 -> v34, target-advice v24 -> v25 (2026-11-03, NO-PLAN-SCOPE-1)

**Change (vm-state).** The capture no longer writes `purchasePlan`, on
`captured.vmConfig` or on `captured.vmConfig.osDisk`. The schema keeps both
fields, described as v31 to v33 only, so a record from those versions is
still valid. Nothing reads them.

**Change (target-advice).** The reason list gains
`purchase-plan-out-of-scope`: a machine with a Marketplace purchase plan is
outside the scope of this tool on every series.

**Why.** Since 2026-11-03, a machine with a Marketplace purchase plan is
outside the scope of this tool, for 1.0, because no edition with a plan was
ever tested. The scan blocks it (`purchase-plan-out-of-scope`), and Checking
stops it untouched (`purchasePlan`) from the plan of the machine or of its OS
disk. So no capture past Checking has a plan, and REBUILD-PROPS-1's plan
carry-over (the capture of the plan, the plan on the rebuilt definition, the
restore's reads of the disk plan and the comparison in Verifying) is removed.

**Migrating.** Nothing to rewrite. A target-advice v24 file is refused by
name and made again (`Set-VmfTargetChoice`, the targets step), as for every
earlier version. A vm-state record from v31 to v33 that holds a plan comes
only from a machine moved before this change, by an installation that no
customer has: its rebuild no longer sends the plan, and Azure refuses the
create (VMMarketplaceInvalidInput, measured 2026-11-01). The tests are
`tests/unit/NoPlanScope.Tests.ps1`.
## vm-state v32 -> v33 (2026-11-02, FINISH-END-JOB-1)

**Change:** `putBackJob.kind` gains `finish`, `putBackJob.options` gains
`finishes` (`rollback` or `restore`), and `putBackJob.prior` (object or null)
holds, whole, the record of a restore or a rebuild that the finish stands
over.

**Why:** Finish the rollback and Finish the restore (`Complete-VmfDataDiskSwap`)
run as an engine job once. A job the platform stopped left the machine
stopped, and nothing started it again. Now a finish writes the checkpoint a
restore writes (RESTORE-END-JOB-1) before it asks Azure anything, saves
`dataSwapped` and `started`, and removes it in the same write as the swap
record (`swapPending`). The service's timer starts a finish whose job stopped
again with the same operation id (`VMF_RESUME_ID`), as it starts a restore.
A machine has one `putBackJob`, so the record of an earlier restore (one the
service gave up on keeps a hold, and Finish the restore writes the restore's
record from it - FINISH-NO-RESTORE-RECORD-1) goes inside the finish as
`prior`. Its readers look under the finish (`Get-VmfPutBackJobBehind`), and
every end of the finish puts it back as it was, or ends it by the rule of
`Save-VmfFinishedRestore`.

**Migrating:** nothing to rewrite. A document from before v33 has no finish
checkpoint, and a finish then writes one. A finish started by an engine
from before v33 has none, so it is not started again if its job stops - a
person presses Finish again, as before. The tests are
`tests/unit/FinishEndJob.Tests.ps1`.

## capacity-claim v13 -> v14 (2026-11-06, REGIONAL-QUOTA-BOTH-1 and REGIONAL-QUOTA-WAVES-1)

**Change:** four new fields, all nullable.
- `regionalShort` (beside `blockReason`): the quota check's answer to whether
  the machines of the record are short of the Total Regional vCPUs quota,
  whatever `blockReason` says. True when the region has fewer vCPUs free than
  `demand.regionalVcpus` and the record's machines add some; false when they
  fit or add none; null when it was not judged (no regional reading, or the
  record was blocked on its size first).
- `demand.regionalAdds`: the vCPUs THIS record's machines add to the region,
  its own part of `demand.regionalVcpus`, by the same rule. Null when the size
  is not offered in the region.
- `quota.regionalRequestId` and `quota.regionalRequestedUtc`: the regional
  request filed beside the family request for a record blocked with
  `quota-shortfall` and `regionalShort` true. `requestId` keeps the request of
  the record's own reason.

**Why:** a record whose size family was short kept `quota-shortfall` when the
region was short too, so Request an increase asked only for the family. Only
the check after Azure granted it blocked the record on the region, and the
wave waited for two requests one after the other, each of which can take
days (REGIONAL-QUOTA-BOTH-1). Now `Request-VmfQuota` puts such a record in
its family's request AND its region's, in one press. The request of the
record's own reason moves it to `QUOTA_REQUESTED`; the regional request
beside it does not. And the confirmation **Request a quota increase?** had no
line for each wave under the Total Regional vCPUs row, because the record
held only the whole plan's figure (REGIONAL-QUOTA-WAVES-1). The regional row
now has one line for each wave, the sum of `demand.regionalAdds` of the
wave's records - never `demand.vcpus`, which is the whole new size.

**Migrating v13 claims:** nothing to rewrite. A v13 record has no
`regionalShort`, so `Request-VmfQuota` does not put it in a regional request,
as before; and no `regionalAdds`, so a regional row with such a record has no
wave lines rather than a wrong figure. The next quota check of a wave writes
v14 records.

**Tests:** `RegionalQuotaBoth.Tests.ps1` (the check records both answers for a
record short on both, false for a family short alone and for a record that
adds nothing, null with no reading, each wave's own figure; one press files
both requests, the record keeps the family request as its own, a family
refused leaves the record blocked, a family short alone and a v13 record file
no regional request, one regional request for two records, no access asks for
neither, the preview has both rows; the regional row's wave lines, from
`regionalAdds`, and none from a v13 record), `tests/js/regional-quota.test.js`
(the wave editor names the region of such a record) and
`tests/js/quota-preview.test.js` (the regional row's wave lines).

## capacity-claim v12 -> v13 (2026-11-02, REGIONAL-QUOTA-REQUEST-1)

**Change:** no new field. `quota.requestAccess` is now also written on a record
blocked with `regional-quota-shortfall`. Test-VmfQuota reads it as it does for
`quota-shortfall`: the identity's effective permissions on the SUBSCRIPTION
against the Microsoft.Quota actions of `data/rbac-actions.json`.

**Why:** Request an increase now asks for the Total Regional vCPUs quota too, so
the operator is no longer sent to the Quotas page of the Azure portal (hard
rule 12). `Request-VmfQuota` files ONE request per subscription and region for
the records blocked on it, through the same Microsoft.Quota PUT as a family
request (`Request-VmfQuotaIncrease`), with the resource name `cores`. PROBED
2026-11-02, read only, in a lab subscription (id redacted), centralus:
`GET /subscriptions/<subscription>/providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/quotas/cores?api-version=2023-02-01`
returned name `cores`, localizedValue `Total Regional vCPUs`,
`isQuotaApplicable` true, limit `LimitValue` / `Independent`, unit `Count`.
Microsoft's Quota API page (Quota - Get, api-version 2023-02-01) says to use the
`name` the GET returns when requesting quota. The new limit is
`quota.regionalUsed + demand.regionalVcpus` plus the headroom asked for. No
request of either kind asks for less than the present limit
(`Get-VmfQuotaRequestLimit`). The regional request needs the same access as a
family request, so the record carries the same field, and the wave editor reads
it from both reasons.

**Also changed, with no field:** the `quotaPreview` activity log line's rows
carry `kind` (`family` or `regional`). A regional row has `family` `cores`,
`quotaName` `Total Regional vCPUs`, the regional usage and limit, and an empty
`waves` list: what each wave adds to the region is not on the record. The
`quotaRequest` lines of a regional request name `quota=cores region=<region>`.

**Migrating v12 claims:** nothing to rewrite. A v12 record blocked on the
regional quota has no `requestAccess`; the wave editor keeps Request an
increase, and Azure decides. The next quota check of a wave writes v13 records.

**Tests:** `RegionalQuotaRequest.Tests.ps1` (one regional request per
subscription and region, sized from the regional figures, never below the
present limit, a family request beside it, no regional reading, no access, a
refusal, the preview row, the access recorded on a regional record and the
record against the schema); `RegionalVcpuQuota.Tests.ps1`;
`tests/js/quota-preview.test.js` (the card and the confirmation for a regional
row).
## assessment v6 -> v7, plan-entry v23 -> v24, wave-options-acceptance v4 -> v5 (2026-11-01, REBUILD-ACCEPT-1)

**Change (assessment).** Each machine gains `rebuildLinks`: `extensions`
(each extension of the VM, with name, publisher and type, or null when the
read failed) and `sqlVirtualMachine` (true, false, or null when the read
failed). The scan reads them with the access it already has: virtual machine
extensions through Resource Graph, and the SQL virtual machine resources it
already lists. `notRead` can name the subject `rebuildLinks`.

**Change (plan-entry).** `assessment.rebuildLinks` is carried onto the entry.
A decision may have the setting `rebuild`, with `extensions`: the names of the
extensions the person saw when they accepted the rebuild of this one machine.
`rebuild` is not a setting: it has no value in the policy.

**Change (wave-options-acceptance).** `rebuild`: each machine of the wave that
a rebuild around the same disks moves (Path B), with `extensions` (null when
the scan did not read them) and `followUps`. The acceptance is refused unless
it names every such machine.

**Why.** A rebuild deletes the VM and creates it again. Measured on
2026-11-01 (docs/research/rebuild-impact-2026-11-01.md): every extension is
removed, Site Recovery stops replicating, the SQL virtual machine resource is
deleted. PRECHECK now rebuilds a machine only when the acceptance of its wave
or its own decision names it and every extension Azure reports then.

**Migrating.** Nothing to rewrite. An older assessment has no `rebuildLinks`:
the acceptance says both reads were not checked. An older plan entry reads the
same. An acceptance of v4 or older names no rebuild, so PRECHECK stops each
Path B machine of that wave (`rebuildNotAccepted`, untouched) until a person
accepts the wave's settings again or accepts the rebuild for that machine.
The tests are `tests/unit/RebuildAccept.Tests.ps1` and
`tests/js/rebuild-follow-ups.test.js`, with the version pins updated in the
files that hold them.

## target-advice v22 -> v23, target-choices v6 -> v7, plan-entry v22 -> v23 (2026-11-01, REBUILD-PICKER-1)

**Change (target-advice).** No field changes. A machine whose move would
rebuild it starts on an option that upgrades it in place, when one loses
nothing more (`Select-VmfInPlaceStart`). Before, only a machine with a
system-assigned identity did (IDENTITY-LOSS-1).

**Change (target-choices).** Each choice records `method`: `in-place`,
`rebuild` or `preview`. The save records the method of the chosen size (its
`rebuild` fact). A request that names another method is refused with 400.
`preview` is the in-place upgrade that needs the subscription's preview
feature (TEMP-DISK-PREVIEW-1). The contract allows it now so that the preview
needs no other version, and no size has it as its method yet, so a save that
names it is refused.

**Change (plan-entry).** `target.choice.method`, the same three values, on
every entry the plan moves: `rebuild` on Path B and `in-place` on Path A. The
wave editor's change of one machine (`Set-VmfMachineTarget`) writes it too.

**Why.** Since 2026-11-01, the app must tell users clearly the risks of the
rebuild around the same disks. A rebuild deletes the VM
definition with its extensions and the links other services hold to it, and a
rollback does not bring them back. The default must not choose it when an
in-place upgrade exists, and a plan must never rebuild a machine whose person
saved an in-place upgrade: `New-VmfPlan` refuses a saved method that the rules
no longer give, by name.

**Migrating.** A target-advice v22 file can start a machine on the rebuild, so
it is refused by name and made again, as every earlier version is: the targets
save and the machines save answer 409, the plan refuses targets chosen on it,
and the page reads it as not made. A target-choices v6 file has no method: the
plan takes the method of the planned path and checks nothing (a v6 file is
always refused anyway, because it was saved on a v22 advice file). A plan
entry older than v23 has no method; its `path` says it, and the plan reader
accepts every earlier version. The tests are
`tests/unit/RebuildPicker.Tests.ps1`, `tests/js/rebuild-picker.test.js`, and
the version pins in `AdviseAn.Tests.ps1`, `Gen1RouteGone.Tests.ps1`,
`HddOsDisk.Tests.ps1`, `IdentityLoss.Tests.ps1`, `IdentityLossGate.Tests.ps1`,
`PlanV5.Tests.ps1` and `WaveAnNames.Tests.ps1`.

## target-advice v23 -> v24 (2026-11-02, TEMP-DISK-PREVIEW-1)

**Change (target-advice).** Each option and each size choice gains `preview`
(boolean): the move is a rebuild around the same disks, and Azure also allows
it as an in-place upgrade when the subscription has the preview feature
`Microsoft.Compute/VMTempDiskResizePreview` registered. It is true only for a
Windows machine with a SCSI temporary disk on Generation 2
(`Test-VmfPreviewShape`), the shapes measured in
`docs/research/temp-disk-in-place-preview.md`, and never for a rebuild that
the tool refuses (an encrypted machine). Starts do not change.

**No change (target-choices v7, plan-entry).** Both already carried
`method` with the value `preview` (REBUILD-PICKER-1). The save now accepts
`preview` where the chosen size's rebuild has `preview: true`, and refuses it
everywhere else. `New-VmfPlan` plans a saved `preview` on Path A
(`Get-VmfPathSelection -Method preview`, the one exception to the rule that a
Windows change of temporary disk is Path B) and records `target.choice.method`
`preview`. A saved `preview` that the rules no longer give is refused by name,
like any other method. PRECHECK reads the feature again for an entry whose
method is `preview`, and stops the machine untouched
(`previewFeatureNotRegistered`) when it is not registered or cannot be read.
The migration record adds `target.method` to each machine; `target` is
open-shaped in `migration-record.schema.json`, so that version does not change.

**Why.** A rebuild deletes the machine definition, with its system-assigned
identity, extensions and links. With the feature, Azure resizes the same
machine in place, forward and back (measured on eight shapes), and the product
offers it (2026-11-02): read the feature, never register it.

**Migrating.** A target-advice v23 file has no `preview`, so a save could not
accept one: it is refused by name and made again, as every earlier version
is. A target-choices v7 file and a plan entry written before this change
never hold `preview` (the save refused it), so they are read as before. The
tests are `tests/unit/TempDiskPreview.Tests.ps1`,
`tests/js/temp-disk-preview.test.js`, and the version pins in
`AdviseAn.Tests.ps1`, `AmdShape.Tests.ps1`, `Bsv2Target.Tests.ps1`,
`Dav4TempDisk.Tests.ps1`, `Gen1RouteGone.Tests.ps1`, `HddOsDisk.Tests.ps1`,
`IdentityLoss.Tests.ps1`, `RebuildPicker.Tests.ps1`, `RetireScope.Tests.ps1`,
`TargetAdvice.Tests.ps1` and `V3TempDisk.Tests.ps1`.

## vm-state v31 -> v32 (2026-11-02, FINISH-NO-RESTORE-RECORD-1)

**Change:** three optional fields.

- `restore.operationId` (string or null): the engine operation of the restore
  that wrote the record - the id its checkpoint (`putBackJob.operationId`)
  carries.
- `swapPending.operationId` (string or null): the same id, on the record of a
  swap a restore left. A rollback writes none.
- `restore.writtenByFinish` (`{ by, utc }` or null): Finish the restore wrote
  this record, because the restore's job stopped before it wrote it. `by` is
  who asked for Finish the restore; `restoredBy` stays who asked for the
  restore.

**Why:** Restore this machine writes the record of a refused swap
(`swapPending`) before its own record (`restore`), which goes with the removal
of its checkpoint (`putBackJob`). A job killed between the two writes, whose
resume the service gave up on (RESUME-GIVEUP-KEEP-1), left no restore record.
Finish the restore then started the machine on its restored disks and left
it with no restore record - the panel, the reports and the counts did not say
it was restored - and with the checkpoint marked `gaveUp`, so retention kept
the safety copies and every disk made for the machine. And it added each disk
it swapped to whatever restore record was on the machine, also an earlier
restore's. Now Finish the restore adds only to the record of the restore that
left the swap (`Get-VmfSwapRestoreRecord`, by `operationId`), and its last
write (`Save-VmfFinishedRestore`) writes that record from the checkpoint and
the swap record when the restore did not, marks it `writtenByFinish`, and
removes the checkpoint, with the swap record, in one write. The activity line
of the finish says that Finish the restore wrote the record.

**Migrating:** nothing to rewrite. A record from before v32 names no
operation: then a restore whose checkpoint is still on the machine did not
write its record, so a restore record that names no operation is taken as an
earlier restore's, and Finish writes this restore's record from the
checkpoint. With no checkpoint, the record on the machine is the restore's,
as before. A document that gets one of the fields says v32. The tests are in
`tests/unit/RestoreEndJob.Tests.ps1` (the kill-resume of each restore path,
the pure rule, and the contract) and the shipped sample.
## vm-state v30 -> v31 (2026-11-01, REBUILD-PROPS-1)

**Change:** the capture (`captured.vmConfig`, and so `captured.original.vmConfig`)
records the settings a rebuild dropped before.

- `purchasePlan` (`{ name, publisher, product, promotionCode }` or null): the
  machine's Marketplace purchase plan.
- `osDisk.purchasePlan` (same shape or null): the OS disk's own plan, written
  by PRECHECK from the disk read SAFETY-CMK-1 already makes
  (`Add-VmfDiskEncryptionFacts`), and by a restore that rebuilds from the disk
  it made from a copy (`Set-VmfCapturePlanFromDisk`).
- `patchSettings` (object or null): `os`, `patchMode`, `assessmentMode`,
  `enableHotpatching`, `rebootSetting`,
  `bypassPlatformSafetyChecksOnUserSchedule`.
- `userDataPresent` (boolean): THAT the machine has user data. The value is
  never written.
- `hostId`, `hostGroupId` (string or null), `hibernationEnabled` (boolean).
- `evictionPolicy` (string or null), `maxPrice` (number or null): a Spot
  machine's eviction policy and maximum price.
- `osDisk.caching`, `osDisk.writeAcceleratorEnabled`,
  `dataDisks[].writeAcceleratorEnabled`, `nics[].deleteOption`. The OS disk
  and data disk delete options were already recorded and are now sent.

**Why:** every rebuild from a capture (the Path B move, its rollback, a
restore that rebuilds, Rebuild this machine) created the machine again
without these. MEASURED 2026-11-01: a machine from a Marketplace image with a
purchase plan was refused (VMMarketplaceInvalidInput) after its definition
was deleted, and left a Failed definition holding the disk; the patch
settings were lost, so Azure Update Manager stopped patching the machine.
Now the rebuild sends the plan (the machine's, else the OS disk's), each
caching, delete option and Write Accelerator setting, the boot diagnostics
storage account, the dedicated host, host group, hibernation and the Spot
settings, and sets the patch settings after the create
(`Set-VmfVmPatchSettings`, read back). Verifying compares every one
(`Test-VmfRebuildSettingsFidelity`). A rebuild MOVE refuses at PRECHECK a
machine with user data, a dedicated host, a host group, hibernation or Write
Accelerator (`captureNotReproducible`): the new size may not take them, and
user data cannot be put back.

**Migrating:** nothing to rewrite. A capture from before v31 has none of
these fields. That is UNKNOWN, never "none": Verifying says the settings
cannot be compared (a warning line, never a pass or a fail), and a rebuild
from such a capture sends what it did before. A capture with the fields
raises the document to v31. The tests are
`tests/unit/RebuildProps.Tests.ps1` (the capture, the rebuild, the PRECHECK
refusal, the patch settings with a kill-resume, Verifying, and the contract)
and the shipped sample, whose capture has patch settings and an OS disk plan.

## decision-carry v1, new (2026-11-02, DECIDE-CARRY-KILL-1)

**What:** `decision-carry/<machine key>.json` in the run, the note of the
carry a decision is about to do. `Resolve-VmfDecision` writes it before it
writes the decision into the plan, and removes it after it carries the wave's
accepted settings, its approval and the plan sign-off onto the plan it wrote.
Fields: the machine, its wave, who decided and when, the change, whether the
wave's approval moves (an approver's acceptance only), what the records had to
sign before the decision (`before.optionsHash`, `before.planVersion`,
`before.waveVersion`) and the version of the plan text written
(`afterPlanVersion`).

**Why:** a process that stopped between the plan write and the carry left the
records signing the plan from before the decision. The wave could not start,
and the decision made again was refused by that gate, so the person had to
accept the wave's settings and approve the wave again. The next decision call
for the machine now finishes the carry the note names, only while the stored
plan's version is still `afterPlanVersion`.

**Migration:** none. A new document; no earlier run has one, and a run with no
note behaves as before. The engine writes and reads it; no page reads it.

## assessment v5 -> v6, guest-output vmf.guest/3 -> vmf.guest/4 (2026-10-31, CLUSTER-DETECT-1)

**Change (assessment).** The workload type gains `may-be-cluster-node`, and
the warnings gain `cluster-node-confirm`. Both come from three cluster hints
the scan reads with the access it already has: a network interface in a load
balancer backend pool, more than one IP configuration on a network interface,
and the SQL IaaS Agent extension (`SqlIaaSAgent`, `SqlIaaSAgentLinux`). The
evidence of a hint is `ipConfigurations.loadBalancerBackendAddressPools`,
`networkInterface.ipConfigurations` or `extensions.type`. A hint the scan
could not read is evidence with a null value, and makes the type
`not-checked`. `notRead` can name the subject `clusterHints`. No new field
and no new blocker.

**Change (guest-output).** The `schema` field accepts `vmf.guest/4`, and the
facts object declares five optional facts: `clusterService` (`running`,
`installed`, `absent`), `clusterKey` and `sqlHadr` (`yes` or `no`),
`pacemaker` and `corosync` (what `systemctl is-active` says). The two new
cluster scripts emit v4.

**Why.** A cluster node that Azure has no record of was moved as if it were
alone (the item has the ruling). The scan now warns, and Checking
reads inside the machine and stops a cluster node before anything changes.

**Migrating.** Nothing to rewrite. A v5 or older assessment has no hint: its
machines keep their type, and Checking still runs the check inside each
machine, so a plan from it cannot move a cluster node. A v2 or v3 guest
output is a valid v4 output without the cluster facts. The tests are
`tests/unit/ClusterDetect.Tests.ps1`, and the version pins in
`AnPrimary.Tests.ps1`, `AdviseAn.Tests.ps1`, `HddOsDisk.Tests.ps1`,
`WorkloadPatterns.Tests.ps1` and `GuestOutputContract.Tests.ps1`.

## target-advice v21 -> v22 (2026-10-31, GEN1-ROUTE-GONE-1)

**Change:** the option `gen1Route` is gone. The series enum is `v5`, `v6`,
`v7`; the move `gen1-route` and the reason `not-built-yet` are gone with it.
A Generation 1 machine has the options v5, v6 and v7, as every machine has:
v5 when a v5 size fits it, and v6 and v7 not supported, with the reason
`gen1-requires-redeploy`.

**Why:** since 2026-10-31, the product does not support Generation 1 to Generation 2
at all (GEN1-UPGRADE-1 was decided not built on 2026-10-05). The targets step showed
every Generation 1 machine "Microsoft Generation 1 route: Not available: Not
built yet", which says a route is coming. The option is removed, not hidden:
the engine does not write it, the schema does not allow it, and the page has
no words for it.

**Reading an older document:** a target-advice v21 file, which can hold the
option, is refused by name and made again, as every earlier version is: the
targets save and the machines save answer 409 (`Set-VmfTargetChoice`,
`Set-VmfMachineChoice`), the plan refuses targets chosen on it
(`New-VmfPlan`), and the page reads it as not made and offers to make the
target options again - so the route is never shown. Nothing is converted.
Target choices never held the option (the page never sent it, and the save
refused it as not supported), so target-choices, plan entries and the state
documents do not change. The tests are `tests/unit/Gen1RouteGone.Tests.ps1`.

## target-advice v20 -> v21, plan-entry v21 -> v22, wave-options-acceptance v3 -> v4, wave-approval v2 -> v3, vm-state v29 -> v30 (2026-10-30, IDENTITY-LOSS-1)

**Change:**

- **target-advice v21**: each option and each size choice carries
  `identity` - what the move to that size does to the machine's
  system-assigned identity (`lost`, `kept`, `unknown`, `none`; null with no
  target), from `Get-VmfIdentityOutcome`. Each machine carries `identityType`
  and `identityPrincipalId` as the scan read them (null when not read). A
  machine with a system-assigned identity starts on a target that keeps it
  where one does, under both defaults; `decide` may give the reason
  `identity`, with `current` and `extended` each naming the start that loses
  it (`loses`) and the first target that keeps it (`keeps`, with `also`: what
  else that target changes).
- **plan-entry v22**: a `decisions` item may carry `principalId` - for
  `onSystemAssignedIdentity`, the account the person accepted to lose.
- **wave-options-acceptance v4** and **wave-approval v3**: `identityLoss`, a
  list of `{ vmId, principalId }` - each machine of the wave whose
  system-assigned identity a rebuild deletes, with the setting Continue. The
  acceptance, the approval and the plan sign-off are refused unless the person
  names every one (`Assert-VmfIdentityLossNamed`).
- **vm-state v30**: a restore job's `options` may carry `acceptIdentityLoss`.

**Why:** a rebuild around the same disks deletes a system-assigned identity
for good, and the safety copies hold disks only. The Current default started a
Windows machine with a SCSI temporary disk on a v6 size that rebuilds it,
although a v5 size resizes it in place; the wave setting Continue let every
such machine of a wave lose its identity, and no record named a machine or its
account. PRECHECK now goes on only when the machine's own decision or its
wave's acceptance names the machine and the account Azure reports
(`Get-VmfIdentityLossGate`); a restore that rebuilds goes on only with
`acceptIdentityLoss`.

**Reading an older document:** a target-advice v20 file is refused by name
and made again, as every earlier version is. A plan entry v21 or earlier, an
acceptance v3 or earlier, and an approval v2 or earlier read as before; none
names an account, so PRECHECK stops each machine whose identity a rebuild would
delete and asks a person to accept it for that machine. A vm-state v29 job has
no `acceptIdentityLoss`: a resume of a restore that rebuilds a machine with a
system-assigned identity stops before the delete. The tests are
`tests/unit/IdentityLoss.Tests.ps1`, `tests/unit/IdentityLossGate.Tests.ps1`
and `tests/unit/IdentityLossRestore.Tests.ps1`.
## vm-state v28 -> v29 (2026-10-25, FINISH-KEPT-DISKS-1)

**Change:** one optional field on `swapPending`: `kept`, a list of
`{ lun, name, why }` - each data disk the rollback or the restore keeps as it
is by design (a shared disk, a disk with no copy, a disk Azure cannot make from
its copy now). Every writer of `swapPending` writes it, in the same write as
the swaps: the rollback (`Invoke-VmfDataSwapBatches` and both paths of
`Invoke-VmfRollback`) and Restore this machine (`Restore-VmfVm`, when it
records the waiting swap, in its catch, and with its own record).

**Why:** Finish the rollback and Finish the restore (`Complete-VmfDataDiskSwap`)
start the machine only when the record accounts for every data disk the
capture names. A kept disk was accounted for only by the rollback's or the
restore's own record (`rollback.keptDataDisks`, `restore.dataDisksKept`).
Restore this machine writes `swapPending` first and its own record after it,
so a job killed between the two writes left a record without the kept disk,
and Finish the restore refused the machine: a person had to attach each disk
in Azure, outside the app. The same happened when the data restore threw part
way: its own record named no kept disk. Now the record Finish reads is
complete on its own, and the restore record takes its kept disks from the
plan when the data restore gave no result.

**Migrating:** nothing to rewrite. A record written before v29 has no `kept`;
it stays valid, and Finish counts the rollback's or the restore's own kept
list as before. Finish counts both lists when both exist. The tests are
`tests/unit/SwapRefusedAfterStop.Tests.ps1` (the contract, each writer, and
Finish), `tests/unit/RestoreEndJob.Tests.ps1` (the kill between the two
writes, then a resume or Finish after the service gave up) and the shipped
sample, whose `swapPending` names its kept disk.

## assessment v4 -> v5, target-advice v19 -> v20, target-choices v5 -> v6, plan-entry v20 -> v21 (2026-10-25, HDD-OS-1)

**Change:**

- **assessment v5**: each machine record gains `osDiskType` - the type of
  its OS disk, read from the DISK resource (`sku.name`) by the scan's
  existing disk read (`Get-VmfDiskShareMap`, which now also returns
  `Types`). Null when the scan could not read the disk. A machine whose OS
  disk is `Standard_LRS` (Standard HDD) gets the warning
  `os-disk-standard-hdd` (assessment-reasons.json): never a blocker.
- **target-advice v20**: each machine carries `osDiskType` from the
  assessment (required, null allowed).
- **target-choices v6**: a choice's `disks` may be `os-standard-ssd` -
  Standard SSD for an OS disk that is Standard HDD. The save refuses it for
  a machine whose `osDiskType` is not `Standard_LRS`, or not known, and
  allows it on any size: every size takes Standard SSD.
- **plan-entry v21**: `policy.diskUpgrade` may be `os-standard-ssd`, and
  `assessment.osDiskType` carries the type the scan read.

**Reading an older document:** an assessment v1 to v4 is read as before; its
records have no `osDiskType`, which reads as not known, so the targets step
offers nothing. A target-advice v19 file is refused by name and made again,
as every earlier version is (`Set-VmfTargetChoice`, the targets step): it has
no OS disk type, so it could offer nothing. A target-choices file v1 to v5
plans as before. A plan entry v20 or older reads as before: it has no
`os-standard-ssd`, and the export for pricing says the OS disk type is not
known.

**The engine:** `os-standard-ssd` reuses the OLD-SKU-1C change
(`Invoke-VmfDiskTypeUpgrade`): while the machine is stopped, by the disk's
resource id, recorded in `diskTypeChanges` before it is made, after the
resize on Path A and after the shell is deleted on Path B. Only the OS disk,
and only from `Standard_LRS` to `StandardSSD_LRS`; a data disk keeps its
type. PRECHECK asks the target size about Premium SSD only for `os` and
`all`; the 24-hour limit applies to every choice. Every put-back sets the
type back before the size, as before. A disk whose type Azure did not set
back stops a put-back to a size that takes no Premium SSD only when the type
it kept is a Premium SSD type, or not known (`Assert-VmfSizeTakesKeptDisks
-KeptTypes`): every size takes Standard SSD. No vm-state change.

**Why:** Microsoft retires Standard HDD as the type of an OS disk on
8 September 2028, and then converts each one that is left to Standard SSD of
the same size (disks-hdd-os-retirement, pinned under the docs drift check).
The decision of 2026-10-23: offer the change during the size move, which already
stops the machine, so the customer does not stop it again later.

## vm-state v27 -> v28 (2026-10-25, FINISH-EMPTY-LUN-PROOF-1)

**Change:** one optional field on each row of `swapPending.swaps`:
`snapshotId` (string or null), the copy the disk that waits (`diskId`) was
made from. A rollback and a restore write it on every row they leave - the
disk made from its copy, the disk made for the way back, and, keeping the
names, the temporary disk and the disk under the old name, which are all made
from the LUN's copy.

**Why:** Finish the rollback and Finish the restore (`Complete-VmfDataDiskSwap`)
attach the disk that waits to a LUN with no disk. The restore's own resume did
that only when the disk exists, no machine holds it, and Azure says it was made
from the recorded copy (`creationData.sourceResourceId`). Finish passed no copy,
so it checked only the first two: a weaker rule for the same act. Now both ask
one check (`Test-VmfEmptyLunWant`), before anything changes and again at the
attach, and a disk made from another copy is refused with the machine stopped.

**Migrating:** nothing to rewrite. A row written before v28 has no
`snapshotId`; it stays valid, and Finish keeps the check it had for it (the
disk exists and no machine holds it) and writes a line in the run's history
that says so. A restore checkpoint (`putBackJob.made`) written before v28 holds
disks with no copy, so a row a resume of it leaves names none either, and gets
the same check. The tests are `tests/unit/SwapRefusedAfterStop.Tests.ps1`,
`tests/unit/RestoreEndJob.Tests.ps1` and the shipped sample, whose
`swapPending` row names its copy.

## vm-state v26 -> v27 (2026-10-24, RESTORE-END-JOB-1)

**Change:** one optional top-level field, `putBackJob`: the checkpoint of a
Restore this machine or a Rebuild this machine that has not ended.

- `kind` (`restore` or `rebuild`), `operationId` (the engine operation's id -
  on the start line, in the lease holder `<kind>:<id>`, and on the engine's
  own fail line), `startedUtc`, `startedBy`, `note`.
- `options`: what the person asked for (a restore: `from`, `diskNaming`,
  `acceptPreserveRisk`, `snapshotId`; a rebuild: `diskSource`, `as`,
  `diskSku`). A resume uses these, never the request that started it again.
- `stamp`: the time in the name of every disk the job makes, so a resume asks
  Azure for the same names and gets the disks the first job made
  (`New-VmfDiskFromSnapshot` returns the disk of that name) - never a second
  set.
- `phase`: the last step that ended (`begun` ... `started`, in the order
  `$script:VmfPutBackJobPhases` holds them), and `phaseUtc`.
- `before`, `made`, `rebuild`, `os`, `result`: what the steps found or made
  that later steps need - above all the machine as it was before the job
  changed it, and, for a restore that rebuilds the machine, the machine read
  before its definition was deleted. The engine alone reads them.
- `resumes`, `resumedUtc`: how many times the service's timer started it again.
- `ended`: the job ended with an answer it said (`outcome` `fail`, `why`), or the service gave up on it (`reason` `gaveUp`, RESUME-GIVEUP-KEEP-1).
- `held`: this job started over a record the service gave up on, and carries that mark (`operationId`, `sinceUtc`, `why`) until it finishes.

**Why:** a restore's or a rebuild's job runs once. When the platform stopped it
part way (out of memory, the time limit, a restart), nothing started it again:
the machine could stay stopped, or without a definition in Azure, and the
Migrations page said "Restoring" for ever. The decision (2026-10-19,
again 2026-10-24): it resumes from its last checkpoint, as a wave does. The
service's timer finds a record that has not ended, with no live hold on the
machine and no job of it running in Azure, and starts the engine again with
the same operation id (`VMF_RESUME_ID`), at most three times; then it ends the
row with the engine's fail line and keeps the record, marked `gaveUp`. A
`gaveUp` record refuses nothing, and retention keeps the machine's safety
copies and every disk made for it until a restore or a rebuild of the machine
finishes - the rule that a machine can always get back.

**Migrating:** nothing to rewrite. A v26 or older document has no
`putBackJob`, and a restore or rebuild running across the upgrade simply has
no checkpoint to resume from (as before). The record is removed in the same
write as the `restore` or `recovery` record that ends the job, so a finished
machine never carries one. While one stands and has not ended, a new restore,
rebuild or finish of the machine is refused, and retention keeps the machine's
safety copies, its disks made for the way back and the disks a put-back made.
The tests are `tests/unit/RestoreEndJob.Tests.ps1` and the shipped sample,
which holds a `putBackJob`.

## plan-entry v19 -> v20 (2026-10-24, WAVE-AN-NAMES-1)

**Change:** one optional top-level field on a plan entry that moves (path A
or B), `acceleratedNetworkingOutcome`: `turnsOn` (true, false or null) and
`unknownWhy` (`kernel`, `nics` or null) - does the move turn accelerated
networking on for the primary network interface?

The engine works it out from the entry (`Get-VmfPlannedAnOutcome`): the
setting (`ensureOff` and `preserve` turn nothing on, `ensureOn` turns it on),
the move (a SCSI reversion keeps it as it was), the primary interface the scan
read (unread is `nics`; on already is false), and, with no setting, the target
advice's own rule (`Get-VmfAnTurnsOn`): every other move turns it on, except a
Linux kernel with no MANA driver on a size that can give MANA (AN-KEEP-1).
Guest preparation reads the kernel, so that is `kernel` - on a release
Microsoft does not list for MANA too, where a kernel of 6.14 or later has a
driver (the review of WAVE-AN-NAMES-1). The target advice gives the same
answer (`acceleratedNetworking.turnsOn` null), with no version change: null
was already one of its values. `New-VmfPlan`,
`Set-VmfMachineTarget` and `Resolve-VmfDecision` (when it sets accelerated
networking) write it; an entry that gains it says v20.

**Why:** the wave settings named under **Machines that get accelerated
networking turned on** only the entries that SET `ensureOn` - the sizes that
require it (AN-PLAN-1). The engine's default turns the primary on for every
other move but a SCSI reversion (`Get-VmfPolicy`), so in the lab run of
2026-10-11 two Bsv2 moves turned it on and the row said None. The
decision of 2026-10-23: the row names every machine whose move turns it on.
The pages read this record (`VmfHelp.anOutcomeRow`); a machine whose move
decides is named on its own row, **Machines where the move decides
accelerated networking**.

**The acceptance:** `Get-VmfWaveOptionsHash` adds the record to an entry's
line when the entry has one, so a change to it voids the wave's acceptance as
a change to a setting does. An entry with no record hashes exactly as before,
so no acceptance written before this version is voided.

**Migrating:** nothing to rewrite. A v19 or older entry has no record, and
reads as it is (the plan reader accepts every earlier entry). The pages then
name an entry that sets `ensureOn` as turned on, an entry that sets
`ensureOff` or `preserve` nowhere, and any other entry as decided by the move.
Plan the migration again to record every answer. The tests are
`tests/unit/WaveAnNames.Tests.ps1`, `tests/js/wave-an-names.test.js`, the
shared cases in `tests/fixtures/an-outcome.json`, and the shipped sample.

## vm-state v25 -> v26 (2026-10-23, MADE-DISK-RECORD-1)

**Change:** one optional top-level list, `restoreDisks`, and two optional
fields on each entry of `rollbackDisks`, `recoveryDisks` and `restoreDisks`
(one shared definition now, `$defs/madeDisk`).

- `restoreDisks[]` (`diskId`, `diskName`, `lun` - null for the OS disk -
  `madeUtc`): every disk Restore this machine made from a safety copy,
  recorded the moment Azure made it, as `rollbackDisks` is for a rollback and
  `recoveryDisks` for Rebuild this machine. Every disk a restore makes comes
  through `New-VmfOsDiskFromCopy` or `New-VmfDataDiskFromCopy` with an Azure
  call named `restore:...`, and those record it (`Add-VmfRestoreDiskRecord`).
- `usedUtc`: a put-back put the disk on a machine (a rollback after each swap,
  in `Set-VmfRollbackRecord`; a restore and a rebuild once the disk is on), or
  the daily cleanup found it attached. It is the machine's own disk from then
  on, and nothing deletes it.
- `deletedUtc`: the restore that made it deleted it (a temporary disk of a
  restore that keeps the names), or the daily cleanup did, or found Azure no
  longer has it.

A marked entry is off the list: no stop names it (`Get-VmfUnusedMadeDisks`)
and no cleanup asks for it. The entries stay, so the record still says what
each put-back made.

**Why:** a restore named the disks it made only from a list in memory, so a
restore that died after Azure made them left them on no record. No cleanup
knew any disk a rollback, a restore or a rebuild made and did not use; each
billed until a person deleted it. The decision of 2026-10-23: the
daily cleanup deletes such a disk once the machine's move has ended
(`Get-VmfDueMadeDisks`) - reading each disk first, never one that is
attached, never one that `swapPending` names, and never one the record says
the machine runs on or ran on.

**Migrating:** nothing to rewrite. A v25 or older document has no
`restoreDisks`, and its `rollbackDisks` and `recoveryDisks` entries have no
marks. The cleanup then decides from the record (`Get-VmfRecordedMachineDiskIds`:
the capture and the last rollback, restore and rebuild) and from Azure (a disk
attached to anything is kept and marked used). A writer of a field raises the
document to v26; the reader accepts every older version. The tests are
`tests/unit/MadeDiskRecord.Tests.ps1` and the shipped sample, which holds
`restoreDisks` with both marks.

## vm-state v24 -> v25 (2026-10-23, SWAP-REFUSED-AFTER-STOP-1)

**Change:** one optional top-level field, `swapPending`: a rollback or a
Restore this machine whose data-disk swap Azure refused after the stop, also
when the product tried it again (three tries).

- `kind` (`rollback` or `restore`), `leftUtc`, `error` (Azure's words), and
  `usedBy` (the mark a disk made for the way back gets when it goes on).
- `swaps`: each data disk that is not back - the LUN, the disk it still holds
  (`name`, `oldDiskId`), the disk made from its copy that waits (`diskId`,
  `diskName`), its caching, whether it is a Premium SSD v2 or Ultra Disk
  (`instantAccess`), whether that disk is the temporary one of a restore that
  keeps the names (`temporary`), and `why`.
- `swapped`: each data disk the put-back did swap back.
- `stop` (a rollback only): the stop the rollback would have recorded with
  every disk back. Finish the rollback records it.

**Why:** a refused swap put the old disk back on its LUN, and the rollback or
the restore then started the machine with the other disks back from the copy -
disks from two moments, which the full rollback rule forbids. The rule since
2026-10-23: a machine always gets back to its original state. Now the machine stays
stopped (deallocated), its record names every disk, and Finish the rollback or
Finish the restore (`Complete-VmfDataDiskSwap`, the engine's `finish`
operation) swaps only those disks, then starts the machine. A rollback that
leaves one records the stop `dataDiskSwapRefused`, with the machine changed.

**Migrating:** nothing to rewrite. A v24 or older document has no field, and
no swap is left on it: a refused swap before this version started the machine
and wrote its disk under `rollback.keptDataDisks` or `restore.dataDisksKept`,
as before. A writer of the field raises the document to v25; the reader
accepts every older version. The tests are
`tests/unit/SwapRefusedAfterStop.Tests.ps1` and the shipped sample, which
holds one.

## assessment v3 -> v4, target-advice v18 -> v19 (2026-10-23, DETECT-PATTERNS-1)

**Change (assessment).** Each machine gains:

- `planPublisher`, `planProduct` - the Marketplace purchase plan Azure keeps
  on the machine (`plan.publisher`, `plan.product`); empty when there is none.
- `galleryImageId` - the community or shared gallery image the machine was
  made from; empty for any other image.
- `workload` - `{ type, evidence[] }`: the workload type (one of the seven in
  `data/assessment-reasons.json` `workloadTypes`) and each Azure field and
  value that decided it. A value of `null` is a fact the scan could not read.
- `warnings` - codes in `assessment-reasons.json` `warnings`: what a person
  checks before the move, while the machine may still move
  (`sql-server-agree-downtime`, `workload-type-not-checked`).

Four new blocker codes, every series: `storage-appliance-needs-vendor`,
`managed-application-needs-vendor`, `shared-disk-cluster-node`,
`sql-availability-group-member`. A machine in a resource group whose
`managedBy` is any service other than a managed application is now Excluded
(platform-managed), as AKS and Databricks groups already were.

**Change (target-advice).** The reason enum gains the four blocker codes, so
the advice can give them as `notSupported`. Nothing else.

**Why.** The decisions on the workloads that must not move like an
ordinary machine (the item records them): storage and backup appliances,
failover cluster nodes on a shared disk and SQL Server availability group
members are refused, outside the scope of this tool; a single SQL Server
machine is a warning; and every machine shows its workload type, with a
filter and the facts behind it.

**Migrating.** Nothing is rewritten. A v1, v2 or v3 assessment is still read:
a machine with no `workload` shows "Type not checked" (never "Standalone
machine"), and one with no `warnings` has none. Such an assessment has none of
the new blockers, so it does not refuse an appliance or a cluster node: scan
again to get them. A v18 target-advice file is refused by name and made again
(the targets step), as every earlier version is. Needs `azd up` to update an
installation: the engine, the dashboard and the VMF Assessment role, which
gains `Microsoft.SqlVirtualMachine/sqlVirtualMachines/read`. The engine and the
role change in the same `azd up`. A scan identity without the permission is
refused by Azure for every subscription, so the scan refuses and names it.

**Tests:** `tests/unit/WorkloadPatterns.Tests.ps1` (every signal, with
Resource Graph and ARM fixtures, and its negative); `AssessmentContract`
(the sample is v4); `AdviseAn` and `AnPrimary` hold the assessment version;
`TargetAdvice`, `AdviseAn`, `AmdShape`, `Bsv2Target`, `Dav4TempDisk`,
`RetireScope`, `V3TempDisk` and `SafetyCopyClean` read v19;
`tests/js/workload-type.test.js` (the column, the filter, the facts, the
warnings).

## run-status v3 -> v4 (2026-10-20, WAVE-APPROVE-TIMER-WORDS-1)

**Change.** `summary.next.waitsFor` takes one more value, `signOffOutOfDate`:
the next wave passes every start gate, but it changed after the plan was
signed off (a version 3 sign-off of an earlier plan version) and its own
approval is gone, so the plan's timer and a start time do not start it. A
person starts it with Start this wave, or an approver approves it again. The
value is the timer's own refusal code: the summary asks the timer's rule
(`Get-VmfUnattendedStartRefusal`), in the order the timer asks it, for the
next wave only - a wave on its way with no worker is restarted by the resume
watchdog on its start gates alone, as before. Nothing else changes.

**Why.** The summary said `start` for such a wave, so the Migrations list put
the migration under Planned ("nothing waits for a person") and the overview
left it out, while the timer held it until a person acted. WAVE-APPROVE-1
filed it.

**Migrating.** Nothing is converted on read. The pages take a v3 or later
summary, and a v3 one never holds the new value. The writer builds a v3
document again in full at the next write, and the daily check writes every
migration, so an installation is all v4 a day after `azd up`. The tests are
`tests/unit/WaveApprovePerWave.Tests.ps1` (the summary and the timer give one
code, and the watchdog's wave is not asked the rule), the contract sample,
`tests/unit/RunSummary.Tests.ps1` (the schema and the engine agree), and
`tests/js/timer-words.test.js` (the list and the overview, run).

## vm-state v23 -> v24 (2026-10-19, ROLLBACK-CRG-1)

**Change:** the capture records the machine's capacity reservation group, and
a rollback records a group it did not put the machine back in.

- `captured.vmConfig.capacityReservationGroupId` (string or null): the
  resource id of the capacity reservation group the machine was in when
  PRECHECK read it; null for no group. Written in every capture
  (`Get-VmfVmCapture`), so `captured.original.vmConfig` has it too.
- `rollback.reservationGroupNotBack` (`groupId`, `why`): the group Azure did
  not put the machine back in, with Azure's words. Absent when the machine is
  back in its group, or had none.
- `rollback.reservationGroupLeft` (`groupId`): a group the rollback took the
  machine out of that it was not in before the move and that this migration
  did not make. Absent for the migration's own group.

**Why:** every put-back left whatever group the machine was in, because the
product's group holds only the new size and Azure refuses to start a machine
whose size has no reservation in its group (SAFETY-2). With nothing recorded,
a machine in the customer's own group came back without it, and nothing said so.
Now a put-back leaves only a group the machine was not in before the move, and
puts it back in the group it was in, after the size is back. When Azure
refuses that, the put-back says so and goes on.

**Migrating:** nothing to rewrite. A v23 or older capture has no field, and
that is UNKNOWN, never "in no group" (`Get-VmfCapturedReservationGroup`
returns `Known = $false`). For such a machine a put-back leaves only a group
that a quota record of this migration names (the product joins no other), puts
no group back, and says that the record does not say which group the machine
was in. A group that is not of this migration is kept. A rebuild builds the
machine in no group, as before. The state reader accepts every older version;
a capture with the field raises the document to v24.

**Readers:** `Get-VmfPutBackCapture` (from the first capture; a first capture
without the field makes the put-back group unknown), `Get-VmfReservationPutBack`
(the rollback and Restore this machine), `Invoke-VmfRebuildInReservationGroup`
(the Path B rollback, the restore that rebuilds, Rebuild this machine as it
was), `Test-VmfReservationJoinPermissions` (PRECHECK), and
`Complete-VmfRollback` (the stop says `reservationGroupNotBack`).

**Tests:** `RollbackCrg.Tests.ps1` (the capture, the decision, the rollback on
both paths and before the move, a refusal said and not failed, a record from
before v24, kill and resume, the restore, the permission check, the contract);
the sample shows both fields.

## vm-state v22 -> v23 (2026-10-19, RECOVER-ALL-DISKS-1)

**Change:** Rebuild this machine, from the copy, records the data disks it
made and the data disks it kept.

- `recovery.dataDisks[]` (`lun`, `diskId`, `diskName`): each data disk the
  rebuild made from its copy, or a disk made for the way back that it used.
- `recovery.keptDataDisks[]` (`lun`, `name`, `why`): each data disk it did not
  make from its copy - a shared disk, or a disk with no copy - which stays on
  its LUN as it was. The same shape as `rollback.keptDataDisks`.
- `recoveryDisks[]` (`diskId`, `diskName`, `lun` - null for the OS disk -
  `madeUtc`): every disk the rebuild made from a copy, written the moment Azure
  made it, as `rollbackDisks` is for a rollback. A rebuild that stopped, or a
  process that died, leaves disks that bill; the next rebuild names each one
  the machine does not run on (`Get-VmfUnusedRecoveryDisks`).
- The first two are written only for a rebuild from the copy (`diskSource`
  `pristine`). A rebuild from its disks makes no disk, and writes neither.

**Why:** the full rollback rule (2026-10-10): every disk goes back to
its copy, or the product refuses before any change. The rebuild from the copy
made only the OS disk, so the machine came back with disks from two moments.
It now makes every disk with the put-back's rules (`New-VmfRecoveryDisks`)
before anything changes, and a disk that cannot come back from its copy
refuses the rebuild.

**Migrating:** nothing to rewrite. A v22 or older record of a rebuild from the
copy has no `dataDisks`: that rebuild kept the data disks the machine ran on,
and `Get-VmfDisksInUseByRecord` reads it that way, as before. The state reader
accepts every older version. The rebuild raises the document it writes to v23.

**Readers:** `Get-VmfDisksInUseByRecord` (the disks the machine runs on),
`Get-VmfKnownDataDiskIds` (the disks a restore may replace), the page's
`restoreDiskNames` (the disks a restore that keeps the names deletes), and
`Get-VmfIacChangeRows` (the changes report).

**Tests:** `RecoverAllDisks.Tests.ps1` (every disk made before any change, a
refused disk changes nothing, the disks made for the way back, shared and
no-copy disks kept and named, the record, the contract), `IacReport.Tests.ps1`,
`tests/js/restore-all.test.js`; the sample shows both fields.

## vm-state v21 -> v22 (2026-10-11, ROLLBACK-DISKS-FIRST-1)

**Change:** the disks made for the way back before the move changes anything.

- `safety.putBackDisks` (`$defs/putBackDisks`): `stamp` (the time at the end
  of every disk name), `pristineSnapshotId` (the copy they were made from),
  `zone`, `complete`, `disks[]` (`lun` - null for the OS disk - `name`,
  `diskId`, `diskName`, `snapshotId`, `skuName`, `instantAccess`, `madeUtc`,
  `usedUtc`, `usedBy` - which put-back put it on, so a worker that finishes the same rollback may swap the same disks again - `deletedUtc`) and `kept[]` (a shared data disk every put-back
  leaves). Written at the end of SAFETY_PRISTINE by `New-VmfPutBackDisks`,
  before the first disk is made, and per disk the moment Azure made it.
- `safety.earlierCopies[].putBackDisks`: a person's retry (`-NewAttempt`)
  moves the record there with the copies it was made from
  (`Clear-VmfRetryState`), as SAFETY-RETRY-1 does for the copies.
- One stop reason in `stop-reasons.json`: `putBackDiskNotMade`
  (SAFETY_PRISTINE, untouched) - Azure did not make a disk for the way back,
  or made one that differs. The disks made are deleted, or named.

**Why:** the decision of 2026-10-11: a put-back must never be blocked and must
be fully safe, so it must never depend on Azure accepting a
new disk request at put-back time. Every put-back from the first copy now
only swaps these disks in (`Get-VmfPutBackDiskSet`).

**Migrating:** nothing to rewrite. A v21 or older document has no record, so
its put-back makes its disks from the copies before it stops the machine, as
before (`New-VmfRollbackDisks`, the restore's own disks) and says why in the
run history. The state reader accepts every older version. A machine in
flight across the upgrade past SAFETY_PRISTINE keeps that fallback; one
before it writes v22 at its SAFETY_PRISTINE.

**Readers:** `Get-VmfPutBackDiskRecord` (this attempt),
`Get-VmfPutBackDiskEntries` (every attempt - the sibling of
`Get-VmfSafetyCopyIds`), `Get-VmfDuePutBackDisks` (retention),
`Test-VmfRunDiscardable` (run deletion).

**Tests:** `PutBackDisks.Tests.ps1` (made before any change, a refusal
untouched and cleaned up, kill-resume, every put-back uses them, the fallback,
the cleanup, retention, run deletion, the contract); the sample
(`SamplesConform.Tests.ps1`, `StateContract.Tests.ps1`).

## target-advice v17 -> v18 (2026-10-11, ADVISE-AN-1)

**Change:** each option's and each size choice's `acceleratedNetworking`
gains `keptOn` and `keptOnWhy`; each machine gains `linuxRelease`
(`distroId`, `version`, `source` agent or image, `mana` listed, unlisted or
unknown, or null for a machine that is not Linux). `keptOn` says, for a
machine whose primary interface has accelerated networking today, whether it
keeps working on that size: true where the operating system drives the
adapter the size can give (Mellanox on AMD v5; MANA on v6, v7 and Intel v5,
which Windows and a Linux release Microsoft lists drive), false on v6 or v7
for a Linux release Microsoft's MANA table does not list, null otherwise,
with the reason in `keptOnWhy` (`unlisted`, `image-unlisted`, `host`,
`release-unknown`, `size-unreadable`). Only a release the VM agent reports can
make `keptOn` false: an image release is `image-unlisted` and null, because
the image cannot prove the release that runs. The pure rules are in
`Private/plan/AdviceAn.ps1`.

Each machine also gains `decide` (decision of 2026-10-11,
OWNER-QUESTIONS-1 row 33): for an Intel machine whose running Linux release
Microsoft does not list, which keeps either its processor maker or accelerated
networking, never both, `decide` names the option of each default that keeps
the processor and the AMD v5 size that keeps accelerated networking, and
`start` is null under both defaults. That AMD size is the v5 option's own
size, with `processorChange: true` - the one exception to AMD-SHAPE-1. No
Intel v5 size is offered to such a machine (2026-10-12): with no AMD
size, v5 is not supported with the reason `an-intel-v5`. A Generation 1
machine whose only target is that AMD size gets `decide` too, with
`keepsProcessor.current` and `.extended` null. The targets save and the plan
refuse until each such machine has a saved choice. `decide` is null for every
other machine.

Each option also gains `processor` (the maker of its target size) and
`processorChange`, and each machine `processor` (the maker of its size now),
all from `Get-VmfSizeProcessor`; null where there is no target.

`start` changes in two cases: the one above, and when the option a machine would start on has
`keptOn` false, it starts on the first supported option, in the same order,
whose `keptOn` is true (`Select-VmfAnKeepingStart`). With none, it stays.

**Why a bump:** since 2026-10-10, the advice recommends a size that always keeps
accelerated networking. A v17 file can start an Ubuntu 18.04 machine on v6, where its move
stops at GUEST_PREP or loses the accelerated path, and the page could not
mark it.

**Migrating:** target-advice is made again from the assessment; a v17 file is
refused by the targets save as any older version is. A saved target-choices
file is not rewritten, but it names the v17 options version, so the plan
refuses it and the targets are chosen again on the new options, as for every
earlier version (New-VmfPlan). The plan-entry version does not change: the
plan writes the network setting of a machine that kept its processor as its
own decision (`decisions`, an existing field), and its `assessment` block,
which is open-shaped, carries the release fields. GUEST_PREP still reads the
kernel, as before. Needs `azd up` to update an installation.

**Tests:** `AdviseAn.Tests.ps1`; `TargetAdvice.Tests.ps1`, `AmdShape.Tests.ps1`,
`Bsv2Target.Tests.ps1`, `Dav4TempDisk.Tests.ps1`, `V3TempDisk.Tests.ps1` and
`RetireScope.Tests.ps1` read v18; the page constant, its demo documents and
`tests/js/an-keep-choice.test.js`; the sample (`SamplesConform.Tests.ps1`).

## assessment v2 -> v3 (2026-10-11, ADVISE-AN-1)

**Change:** each machine gains `runningOsName` and `runningOsVersion` - the
operating system the VM agent reports as running, from Resource Graph's
`instanceView.osName` and `instanceView.osVersion` (Microsoft's own
assessment query in `sizes-v6-v7-modernization-assess` reads the second).
Both are empty when the machine was deallocated or has no agent. `osVersion`
keeps its meaning: the image SKU.

**Why:** the target advice needs the Linux release to know whether a v6 size
keeps accelerated networking. The image says the release a machine was MADE
from; an in-place upgrade changes the running release and not the image.

**Migrating v1 and v2 assessments:** nothing to rewrite. The schema accepts
1, 2 and 3; a machine with no running reading uses the release of its image
(`Get-VmfLinuxRelease`), and one with neither has an unknown release, which
changes no start.

**Tests:** `AdviseAn.Tests.ps1` (the query, the record, the version);
`AnPrimary.Tests.ps1` holds the version; the sample is version 3.
## vm-state v20 -> v21 (2026-10-11, SAFETY-CMK-1)

**Change:** the encryption of every disk, so a disk made from a safety copy
gets the key of the disk it replaces.

- `captured.vmConfig.osDisk` (now described by `$defs/capturedOsDisk`, still
  open) and each `captured.vmConfig.dataDisks[]` (`$defs/capturedDataDisk`)
  gain `encryptionType` (`EncryptionAtRestWithPlatformKey`,
  `EncryptionAtRestWithCustomerKey` or
  `EncryptionAtRestWithPlatformAndCustomerKeys`) and `diskEncryptionSetId`
  (a resource id, or null for a platform key). PRECHECK reads them from each
  disk by its id (`Get-VmfManagedDiskFacts`, `Add-VmfDiskEncryptionFacts`).
  `captured.original.vmConfig` is a copy of the first one, so it holds them
  too.
- One stop reason in `stop-reasons.json`: `diskEncryptionNotKnown`
  (PRECHECK, untouched) - Azure did not answer for a disk, or returned a type
  this tool does not know, a type that takes a set with no set, or a platform
  key with a set. A missing permission on a disk encryption set uses the
  existing `permissionsMissing`.

**Why:** the rule of 2026-10-10: a machine must always be able to go back
fully to its safety copies. No copy and no disk made from one named a disk encryption
set, so a disk with a customer-managed key could come back on a platform key.

**Migrating:** nothing to rewrite. A v20 or older document has no encryption
on its capture. Its copies are taken, and its disks made from them, as
before, with no encryption named - and each disk made says in the log that
its key was not compared (`Confirm-VmfMadeDiskEncryption`). The state reader
accepts every older version. A machine in flight across the upgrade writes
v21 at its next PRECHECK (`Save-VmfCapturedFacts`).

**Tests:** `SafetyCmk.Tests.ps1` (the boundary, the record, the refusals,
the permission, every copy, every way back, an old document, the contract);
the sample (`SamplesConform.Tests.ps1`, `StateContract.Tests.ps1`).

## vm-state v19 -> v20 (2026-10-10, SAFETY-ULTRA-1)

**Change:** what a put-back needs to make a Premium SSD v2 or Ultra Disk data
disk again from its copy, and the record of every data disk a rollback did not
put back.

- `captured.vmConfig.dataDisks[]` (now described by `$defs/capturedDataDisk`,
  still open): on a Premium SSD v2 or Ultra Disk data disk only, PRECHECK
  writes `diskIOPSReadWrite`, `diskMBpsReadWrite`, `logicalSectorSize`,
  `diskZones`, `maxShares` and `completionPercent`, read from the disk by its
  id (`Get-VmfManagedDiskFacts`), and sets `sizeGB` to the disk's own size.
  `captured.original.vmConfig` is a copy of the first one, so it holds them
  too. The read-only IOPS and throughput of a shared disk are not recorded:
  a shared disk is always left as it is.
- `$defs/dataCopy` gains `instantAccessMinutes` and `takenUtc`, on the first
  copy of these disks - evidence only. Every decision reads the copy again
  from Azure (`Get-VmfSnapshotAccess`), never a stored date.
- `rollback.keptDataDisks`: each data disk the rollback did not put back -
  `lun`, `name`, `why`. The stop that ends the rollback says them too.
- Three stop reasons in `stop-reasons.json`: `dataDiskFilling` (PRECHECK),
  `safetyCopyNotReady` (SAFETY_PRISTINE), `safetyCopyWindowShort`
  (CONVERTING, before any change).

**Why:** the rule of 2026-10-10: a machine must always be able to go back
fully to its safety copies. Until now a put-back left these disks as they were,
because the capture had no IOPS or throughput and a copy of them could not
make a disk until Azure finished copying it.

**Migrating:** nothing to rewrite. A v19 or older document has none of the
new fields. Its Premium SSD v2 and Ultra Disk data disks are then left as
they are on a put-back or a restore, as before, with the reason that their
values are not on record (`Get-VmfInstantAccessRestoreRefusal`). Its copies
have no evidence fields, which no decision reads. Its rollback record has no
`keptDataDisks`, which reads as none recorded. The state reader accepts every
older version. A machine in flight across the upgrade writes v20 at its next
write of a new field (`Save-VmfCapturedFacts`, `Set-VmfDataCopyRecord`,
`Set-VmfRollbackRecord`).

**Tests:** `SafetyUltra.Tests.ps1` (the record, the copy check, the wait,
the check before the move, the put-back, the restore, the stop and resume
tests, and an old document); `SafetyAllDisks.Tests.ps1` (rewritten where it
pinned "left as it is"); the sample (`SamplesConform.Tests.ps1`,
`StateContract.Tests.ps1`).

## wave-approval v1 -> v2, and plan-approval v2 -> v3 (2026-10-10, WAVE-APPROVE-1)

**Change:** a wave approval signs its own wave. v2 adds `waveVersion`
(required from v2): `Get-VmfWaveVersion` of the plan text at approval time -
SHA-256 over the plan's format version and assessment, the wave's name, and
every entry of the wave, each written by the product's own canonical
serializer (`ConvertTo-VmfCanonicalJson`: the stored text read with
System.Text.Json, keys sorted ordinally, dates as instants, numbers in one
form - never a runtime's JSON writer; a golden-hash test pins the form).
`planHash` stays, as the plan version the approver was shown (APPR-2). v2 also
adds `amendments`: an approver's acceptance of the one decision a machine waits
for, recorded when it carried the approval forward (as DECIDE-KEEP-1 did for
the acceptance); any other decision leaves the wave asking again. The plan
sign-off adds no field:
v3 means `Approve-VmfPlan` wrote one wave approval per wave with it, and that
the record stays the consent for the run to carry on after a change to one
wave (`Test-VmfPlanRunConsent`).

**Why a bump:** a v1 approval's gate is `planHash` (the whole plan), a v2
approval's is `waveVersion`. A v2 sign-off cannot be read as a v3 one: it wrote
no wave approvals, so read as v3 it would consent to run on with every wave's
gate resting on a plan version that no longer matches.

**Migrating:** nothing is rewritten. A v1 wave approval is current only while
`planHash` is the plan's version now - the one case where it provably signs its
wave as it is - so any change to the plan asks again for it, once
(`Test-VmfWaveApprovalCurrent`), and the writers remove it and name it as
before. A v1 or v2 sign-off passes every wave, and is the consent to run on,
only while its `planHash` is the plan's version - exactly as written. A
decision that carries a v1 or v2 sign-off forward keeps its version (at least
2), never 3. A decision moves a v3 sign-off only together with the wave's
approval - an approver accepting the one decision the machine waits for
(the rule of 2026-10-10): moved past any other decision, a sign-off of
the exact plan would pass the decided wave at the gate with its approval
removed. Engine change: needs `azd up` to update an installation.

**Tests:** `WaveApprovePerWave.Tests.ps1` (the version's scope, the flow, Sign
off all, v1 records, the decision carry, the worker check, the contract);
`SamplesConform.Tests.ps1` (the v2 and v3 samples).

## target-advice v16 -> v17 (2026-10-10, AN-ONE-NIC-1)

**Change:** the reason list gains `one-accelerated-nic`: after the move more
than one network interface of the machine has accelerated networking (the
move turns it on for the primary interface and keeps it on the others), and
Azure allows it on one network interface only of a size with 2 vCPUs (NIC-1).
A 2-vCPU size is no longer an option or a size choice for such a machine,
and no bigger size takes its place - for a machine chosen by shape either
(2026-10-10, OWNER-QUESTIONS-1 row 31): the option is not supported.
No field is added. The count comes from the scan's `acceleratedNicCount` and
`primaryNicAccelerated`; where the scan does not say, the size is planned as
unverified (`sizeUnverified`), never refused and never a plain fit.

**Why a bump:** a v16 file can hold a supported option on a 2-vCPU size for
such a machine, and its move fails after the stop on every attempt. Refusing
v16 makes the options again under the new rule.

**Migrating:** target-advice is made again from the assessment; a v16 file is
refused by the targets save as any older version is. The target rules
(`Resolve-VmfEntryTarget`) read the counts on every call, so the options, the
plan and the wave editor agree. A plan made before this change is stopped at
PRECHECK, untouched (stop reasons `targetOneAcceleratedNic` and
`targetAcceleratedNicsUnknown`), needing `azd up` to update an installation.

**Tests:** `AnOneNic.Tests.ps1`; `TargetAdvice.Tests.ps1`, `RetireScope.Tests.ps1`,
`V3TempDisk.Tests.ps1`, `Dav4TempDisk.Tests.ps1`, `AmdShape.Tests.ps1` and
`Bsv2Target.Tests.ps1` read v17; the page constant and its demo document
(`tests/js/targets-step.test.js`, `tests/js/v3-size-choice.test.js`); the
sample (`SamplesConform.Tests.ps1`).

## target-advice v15 -> v16 (2026-10-10, DISKS-32-1)

**Change:** the reason list gains `too-many-data-disks`: the machine has more
than 32 data disks, which is outside the scope of this tool on every series
(a scope decision, 2026-10-05). No field is added. `assessment-reasons.json`
gains the same blocker, and the scan records it. The isolated E104i v5 sizes
are no longer an approved target (`Test-VmfSizeApprovedTarget`), so no option
or size choice can name one.

**Why a bump:** a v15 file can hold a supported v6 or v7 option for a machine
with more than 32 data disks - a size that takes 64. Refusing v15 makes the
options again under the new rule.

**Migrating:** target-advice is made again from the assessment; a v15 file is
refused by the targets save as any older version is, and the targets step asks
for the options again. An assessment made before this change has no
`too-many-data-disks` blocker until the machines are scanned again - but the
target rules (`Resolve-VmfEntryTarget`) read the data disk count on every
call, so the options, the plan and the wave editor refuse the machine either
way. A plan made before this change is stopped at PRECHECK, untouched (stop
reason `tooManyDataDisks`), and the quota check and the Reserved gate leave
the machine out while its move has not started (`Test-VmfEntryOutOfScope`).

**Tests:** `Disks32.Tests.ps1`; `TargetAdvice.Tests.ps1`, `RetireScope.Tests.ps1`,
`V3TempDisk.Tests.ps1`, `Dav4TempDisk.Tests.ps1`, `AmdShape.Tests.ps1` and
`Bsv2Target.Tests.ps1` read v16; `tests/js/targets-step.test.js` and
`tests/js/v3-size-choice.test.js` hold the page and its demo to the engine's
version; the sample (`SamplesConform.Tests.ps1`).

## target-advice v14 -> v15 (2026-10-09, BSV2-TARGET-1)

**Change:** a machine on a B v1 size (B1ls to B20ms) is offered its Bsv2 size
on the v5 option: `sizeChoices` gains the family `Bsv2`, first in the list and
marked `best` - the smallest Bsv2 size with at least the vCPUs and the memory
of the machine that passes every gate. The Dl, D and E sizes by shape stay as
the other choices. That machine `start`s on the option whose target is its
Bsv2 size under both defaults. Each option gains `burstableKept` (the machine
is on a burstable size and so is the target: it keeps its CPU credits) and
`burstableTarget` (`offered`, `no-fit`, `disk-encryption-rebuild`, or null
where the question does not arise). Each size choice gains its own
`targetStage`, `stageChange`, `burstableEnds` and `burstableKept`, because a
Bsv2 choice (Current, keeps the credits) and a D choice (Extended, ends them)
differ on one option. And each size choice gains its own `prep`: a Windows
machine whose temporary disk the size takes away has `pagefile`, on v5 too
(a Bsv2 size, or D4s_v5 for a v3 machine), where the scan names it for v6 and
v7 only. Basv2 and Bpsv2 are never offered.

**Why a bump:** a v14 file offers no Bsv2, and the save checks a chosen size
against the file's `sizeChoices`. Refusing v14 makes the options again under
the new rule.

**Migrating:** target-advice is made again from the assessment; a v14 file is
refused by the targets save as any older version is. Target choices saved on
v14 options are refused by the next plan as a whole (they were made on an
earlier options version), so the targets are chosen again. A plan made before
this change on a D or E size for a B v1 machine is not changed: that size is
still one of its choices, so the wave editor still agrees with it. A B v1
machine planned with no saved size now gets its Bsv2 size when the plan is
made again. No plan-entry field changes: a Bsv2 size is planned on v5
(`policy.targetGeneration`), and the engine moves it as a SCSI resize
(`Get-VmfMoveKind`), needing `azd up` to update an installation.

**Tests:** `Bsv2Target.Tests.ps1`; `TargetAdvice.Tests.ps1`, `RetireScope.Tests.ps1`,
`V3TempDisk.Tests.ps1`, `Dav4TempDisk.Tests.ps1` and `AmdShape.Tests.ps1` read
v15; the page constant and its demo document (`tests/js/v3-size-choice.test.js`);
the sample (`SamplesConform.Tests.ps1`), which now holds a B v1 machine.
## target-advice v13 -> v14 (2026-10-09, AMD-SHAPE-1)

**Change:** a machine sized by shape keeps its processor maker. The
`sizeChoices` of an AMD machine (a Generation 1 machine on a Dav4, Dasv4, Eav4
or Easv4 size, for example) hold AMD sizes only - Dasv5, Dadsv5, Easv5,
Eadsv5, and on v6 and v7 the AMD D, Dl and E sizes - never Intel. The reason
list gains `no-amd-shape-fit`: the region has no AMD size with the machine's
vCPUs and memory, so the machine has no target on that series. No field is
added. `no-shape-fit` keeps its code; it now means no Intel size fits, which is
all it could mean before, because an Intel machine was never offered AMD.

**Why a bump:** a v13 file can offer an AMD machine an Intel size, and the save
checks a chosen size against the file's `sizeChoices`. Refusing v13 makes the
options again under the new rule.

**Migrating:** target-advice is made again from the assessment; a v13 file is
refused by the targets save as any older version is. Target choices saved on
v13 options are refused by the next plan as a whole (they were made on an
earlier options version), so the targets are chosen again; only a choices file
with no options version reaches a machine, and its saved Intel size is then
refused as `chosen-size-gone`. A plan made before this change on an Intel size
for an AMD machine is not changed: the wave editor finds that its size is no
longer one the rules give (`plan-disagrees`).

**Tests:** `AmdShape.Tests.ps1`; `TargetAdvice.Tests.ps1`, `RetireScope.Tests.ps1`,
`V3TempDisk.Tests.ps1` and `Dav4TempDisk.Tests.ps1` read v14; the page constant
and its demo document (`tests/js/v3-size-choice.test.js`); the sample
(`SamplesConform.Tests.ps1`).

## target-advice v12 -> v13 (2026-10-09, GPU-SCOPE-1)

**Change:** the reason list gains `gpu-size`: the machine is on a GPU size
(the NC, ND, NG and NV families), which is outside the scope of this tool on
every series. No field is added. `assessment-reasons.json` gains the same
blocker, and the scan records it.

**Why a bump:** a v12 file can hold a supported v5 option for a Generation 1
GPU machine - a D or E v5 size chosen by its vCPUs and memory, which has no
GPU. Refusing v12 makes the options again under the new rule.

**Migrating:** target-advice is made again from the assessment; a v12 file is
refused by the targets save as any older version is, and the targets step asks
for the options again. An assessment made before this change has no `gpu-size`
blocker until the machines are scanned again - but the target rules
(`Resolve-VmfEntryTarget`) now ask the size name themselves, so the options,
the plan and the wave editor refuse a GPU machine either way.

**Tests:** `GpuScope.Tests.ps1`; `TargetAdvice.Tests.ps1`, `RetireScope.Tests.ps1`,
`V3TempDisk.Tests.ps1`, `Dav4TempDisk.Tests.ps1` and `tests/js/v3-size-choice.test.js`
read v13; the sample (`SamplesConform.Tests.ps1`).

## vm-state v18 -> v19 (2026-10-05, PREP-ROLLBACK-1)

**Change:** three things a rollback writes, so it can be finished and its
disks found.

- `rollbackPending` (object): the checkpoint every automatic rollback writes
  BEFORE its first change - `kind` (`disks`: a stop before CONVERTING, the
  disks from the first copy only; `full`: FAIL-1, the disks plus the original
  size and controller), `state`, `reasonCode`, `detail`, `evidenceRef`,
  `change` (`changed` or `mayHaveChanged`), `stopState`, `startedUtc`, `done`.
  The stop that ends the rollback removes it in the same write
  (`Add-VmfStateTransition -ClearProperty`). A worker that finds it finishes
  the rollback before any step runs; one marked `done` only records the stop.
- `rollbackDisks` (array): every disk an automatic rollback made, recorded the
  moment Azure made it - `diskId`, `diskName`, `lun` (null for the OS disk),
  `madeUtc`. Kept across attempts. A rollback that failed afterwards used to
  leave disks that billed and that no record named.
- `rollback.path` gains the value `disks` (the disks-only rollback), and the
  `rollback` record is now written after EACH swap, not only at the end, so a
  rollback that stops part way still names the disk the machine runs on.
- `guestExecutions[].result` gains the value `STARTED` (the field was always a
  free string, so the schema only describes it): a script that changes the
  guest is on record before it runs, and the same entry takes its result after.

**Why:** the independent review of PREP-ROLLBACK-1. A worker that stopped in
the middle of a rollback resumed the step that FAILED, and went on to
CONVERTING on a half rolled-back machine (reproduced). The kernel update's
review (MANA-LINUX-KERNEL-1, item 7) recorded the same gap: "a worker killed
during the put-back runs the whole rollback again".

**Migrating:** nothing to rewrite. A v18 or older document has no checkpoint,
which reads as no rollback in progress; no `rollbackDisks`, which reads as
none made; and a `rollback.path` of `A` or `B`, read as before. The state
reader accepts every older version.

**Tests:** `PrepRollback.Tests.ps1` (the kill and resume tests, the records),
`StateContract.Tests.ps1` (a document in the middle of a rollback validates),
the sample (`SamplesConform.Tests.ps1`), `GuestOps.Tests.ps1` (STARTED).
## plan-entry v18 -> v19, target-choices v4 -> v5, vm-state v17 -> v18 (2026-10-05, MANA-LINUX-KERNEL-1)

**Change:** a person can choose, per machine on the targets step, that the
product updates the kernel of a Linux machine whose kernel has no MANA driver.

- **target-choices v5** adds `kernelDefault` (`stop` or `update`), the
  migration's default, and `choices[].kernel` (`stop`, `update` or null), a
  machine's own choice. Null or absent means the default; an absent default
  means `stop`. `Set-VmfTargetChoice` refuses `update` for a machine that is
  not Linux, or whose chosen size cannot give MANA (AMD v5), from the same
  target-advice facts the screen shows.
- **plan-entry v19** adds `updateKernel` to `policy.onDriverBelowFloor`.
  `New-VmfPlan` writes it, from the saved choice, for a Linux machine that
  moves to a target that can give MANA - always with a `decisions` record
  (`setting` onDriverBelowFloor, `by` the person who saved the targets, `utc`
  in whole seconds), so a wave save never writes over it. A wave save and a
  decision still write only `stop` and `proceed`.
  **And SAFETYCOPY-CLEAN-1's two removals:** `clean` leaves
  `policy.safetyCopy.enum` (now `pristine` only) and `assessment.osDiskData`
  leaves the schema and its sample.
- **vm-state v18** declares `captured.kernelUpdate`: `result` (`running`,
  `updated`, `failed`, `stopped`), `kernelBefore`, `kernelInstalled`, `kernelAfter`,
  `package`, `packageManager`, `scriptResult`, `error`, `startedUtc`,
  `finishedUtc`, `putBackUtc`. GUEST_PREP writes it, and the writer raises the
  document to v18. A person's new attempt at or before GUEST_PREP removes it.
  `captured` stays an open object; the record is declared so its shape is
  part of the contract.

**Migrating:** nothing to rewrite.

- A target-choices v4 file or older has no kernel choice: every machine reads
  as `stop`, as before.
- An older plan reads as before (the plan reader accepts every earlier entry).
  An entry that holds `safetyCopy: clean` still reads, and PRECHECK refuses it
  with `safetyCopyNotPristine`; an entry that holds `assessment.osDiskData`
  still reads (`assessment` is an open object), and nothing reads the field.
- An older state document has no `captured.kernelUpdate` and reads as it is;
  the state reader accepts every earlier version.

**Tests:** `KernelUpdate.Tests.ps1`, `tests/linux/kernel-update.test.sh`,
`tests/js/kernel-choice.test.js`; `PlanV5.Tests.ps1` (the version);
`SafetyCopyClean.Tests.ps1` (the two removals, now in force); the three
samples (`SamplesConform.Tests.ps1`).

## plan-entry: `policy.safetyCopy: clean` refused, `assessment.osDiskData` unread (2026-10-04, SAFETYCOPY-CLEAN-1) - no version change

**Change:** the engine refuses a plan entry whose `policy.safetyCopy` is
anything other than `pristine` (no value reads as the default, `pristine`).
PRECHECK stops it untouched with the reason `safetyCopyNotPristine`, the wave's
acceptance refuses a wave holding one, a decision may not write it, and
SAFETY_PRISTINE no longer reads the setting. `assessment.osDiskData` is in the
contract and the sample, and nothing writes or reads it.

**Not bumped, on purpose (2026-10-04):** the schema still accepts
`clean` and `osDiskData`, so every older plan stays readable. **The next
plan-entry change must remove both** - `clean` from `policy.safetyCopy.enum`
(and the ring wording from its description), and `assessment.osDiskData` from
the schema and its sample - and say here how an older entry holding either
reads. `SafetyCopyClean.Tests.ps1` fails on that change if either is left.

**Migrating:** nothing to rewrite. A plan holding `clean` still reads; its wave
cannot be accepted, and a machine that starts with it stops untouched. Plan
the machine again: the planner always writes `pristine`.

**Tests:** `SafetyCopyClean.Tests.ps1`; `SafetyCopy.Tests.ps1` (the skip test
rewritten to the new rule).
## No version change: fields V3-RETIRE-1 added are no longer written (2026-10-04, RETIRE-SCOPE-1)

**Change:** this reverses the part of V3-RETIRE-1 that sent a rollback to
the nearest current size when Microsoft retires a machine's size. From one day
before the retirement date a machine on that size is outside the scope of this
tool, and every rollback goes to the machine's own size. So:

- plan-entry v18 `target.rollbackSize` is **no longer written, and not read**.
  The planner and the wave editor leave it out; PRECHECK ignores it.
- vm-state v17 `rollback.sizeAfter` is **no longer written**. The run page and
  the infrastructure-as-code report still read it on a record that has it, and
  read an absent field as the machine's own size, as before.
- `captured.putBackRetirement` (open, no version) keeps `size`, `retiresUtc` and
  `warnFromUtc` for the restore and rebuild dialogs. `currentSize` and
  `rollbackSize` are no longer written, and a record that has them is read for
  its dates alone.
- target-advice v12 (OLD-FAM-4) `size-retired` now also covers the day before a
  retirement date, as does the scan's `size-retired` blocker. The stop reason
  `putBackSizeRetired` is replaced by `sizeRetired` (`retry: notSupported`).

**Why no version bump:** no field becomes forbidden, and no field a reader acts
on changes its meaning. Every document written in the one day these fields were
written (2026-10-03 to 2026-10-04) still meets its schema and reads; its
`rollbackSize` or `currentSize` is simply not used, and a machine it names is
refused at PRECHECK if its size is retired. Bumping would refuse those
documents for nothing. `size-retired` keeps its meaning - the machine is on a
retired size, so this tool does not move it - with the line drawn one day
earlier.

**Migrating:** nothing to rewrite. **Tests:** `RetireScope.Tests.ps1` (old
documents carrying the fields still validate and read; the planner writes no
`rollbackSize`; the rollback writes no `sizeAfter`), `OldFamilies.Tests.ps1`
(the margin), `tests/js/putback-retire.test.js`.
## target-advice v11 -> v12 (2026-10-04, OLD-FAM-4)

**Change:** each option carries `burstableEnds` (boolean or null): true when
the machine is on a burstable size, which runs on CPU credits (the B family,
`target-families.json` `burstableFamilies`), and the option's target size is
not; false when the target is known and nothing changes; null when the option
has no target. The reason list gains `size-retired`: the scan's blocker for a
size past its retirement date (`lifecycle.retirements`), which cannot start.

**Also, without a format change:** `target-families.json` gains
`burstableFamilies`, `burstableWhy`, three sources (the A v1 retirement page,
the modernization guide, the B family page), the A v1 retirement row
(2024-08-31, size series `A`, Basic sizes read as A too) and the A v1 lifecycle
row (Retired). `assessment-reasons.json` gains `size-retired`.

**Migrating:** target-advice is made again from the assessment; a v11 file is
refused by the targets save as any older version is, and the targets step asks
for the options again. An assessment made before this change has no
`size-retired` blocker until the machines are scanned again; until then an A v1
machine still shows the old reason, and has no target either way.

**Tests:** `OldFamilies.Tests.ps1`, `tests/js/cpu-credits.test.js`;
`TargetAdvice.Tests.ps1` and `V3TempDisk.Tests.ps1` read v12.

## target-advice v10 -> v11 (2026-10-04, DAV4-TEMPDISK-1)

**Change:** no field is added. A machine on an AMD v4 size (Dav4, Dasv4,
Eav4, Easv4) now goes to the AMD d size on v5, v6 and v7 (D4as_v4 and D4a_v4
to D4ads_v6, E8as_v4 to E8ads_v6), and each of those options carries
`sizeChoices` while both sizes fit the machine: the d size (`best`) and the AMD
size without a temporary disk.
Before, D4as_v4 went to D4as_v6, and D4a_v4 and E8a_v4 tried only sizes that
do not exist (D4a_v6, E8a_v6).

**Why:** the rule changed what an option's `targetSize` is for an AMD v4
machine. A choice saved with no size takes the option's own size, so targets
saved on v10 options would be planned on a size the screen never showed.

**Migrating:** nothing is converted. A v10 file is refused by name and made
again (`Set-VmfTargetChoice`, the targets step), and `New-VmfPlan` refuses
targets saved on v10 options, as V3-TEMPDISK-1 made it do.

**Also:** `target-families.json` gains four `replacements` rows, one for each
AMD v4 series, with `basis: derived` and a `how` (Microsoft gives no v4
table), and four size pages as sources, read 2026-10-04. The v3 rows gain
`basis: stated`. No format change. The drift check now watches the four pages.

**Tests:** `Dav4TempDisk.Tests.ps1`; `V3TempDisk.Tests.ps1` and
`TargetAdvice.Tests.ps1` rewritten to the new version and rule; the sample,
checked by `SamplesConform.Tests.ps1`.

## plan-entry v17 -> v18, vm-state v16 -> v17, and `captured.putBackRetirement` (2026-10-03, V3-RETIRE-1)

**Change:** when Microsoft retires a machine's size, its rollback, restore from
the first copy and rebuild as it was use the nearest current size of the same
shape from one day before the date (a design decision). Two records carry
that size so nothing decides it after the machine is stopped:

- plan-entry v18 adds `target.rollbackSize` (string or null): the size the plan
  gives a machine's rollback when its own size is already retired at planning;
  null or absent for its own size. The wave's acceptance names these machines.
- PRECHECK records `captured.putBackRetirement` - `size`, `retiresUtc`,
  `warnFromUtc` (text in the form yyyy-mm-dd), `currentSize` (the nearest
  current size, or null when none takes the machine) and `rollbackSize` (the
  size this move's rollback uses: its own, or the current size) - when the
  machine's size has a retirement entry; null otherwise. The automatic rollback
  reads `rollbackSize`; the dialogs read the dates and `currentSize`.

- vm-state v17 adds `rollback.sizeAfter` (string or null): the size the
  automatic rollback put the machine on. The infrastructure-as-code report and
  the run page read it, so a machine rolled back onto the current size is not
  shown as "No change" or as its old size.

`captured` is declared open, as for `captured.startedTarget` below, so the
record there needs no bump. plan-entry and vm-state bump because `target` and
`rollback` are closed.

**Migrating:** nothing to rewrite. An older plan is read as before (the plan
reader accepts older entries); a v17 or older entry has no `rollbackSize`, which reads as
its own size, and PRECHECK decides the size again from the data. A machine that
started before this has no record: its automatic rollback uses its own size, as
before, and a restore or rebuild decides the size when it starts. A rollback
record written before v17 has no `sizeAfter`, which reads as its own size; the
state reader accepts every older version.

**Also:** `target-families.json` gains `lifecycle.retirementsWhy` and, on each
retirement row, `sizeSeries` (how a size name reads as a series), plus three
rows for the 2028 retirements - without a format change.

**Tests:** `V3Retire.Tests.ps1`, `V3RetireRollbackSize.Tests.ps1`,
`V3RetireEngine.Tests.ps1`, `PlanV5.Tests.ps1` (the version), the sample
(`SamplesConform.Tests.ps1`), `tests/js/putback-retire.test.js`.
## vm-state v15 -> v16 (2026-10-03, ROLLBACK-RETRY-CAPTURE-1)

**Change.** `captured.original`: the capture of the machine from before the
product first touched it - `{ vmConfig, extensions, sourceAcceleratedNetworking,
capturedUtc }`. Written by PRECHECK, refreshed by each later PRECHECK while the
machine is untouched (`Test-VmfMachineTouched`: no copy taken, no guest
prepared, nothing changed, put back or rebuilt), and never written again after
(`Save-VmfCapturedFacts` replaces it only when PRECHECK asks). `captured.vmConfig` keeps its meaning: the capture of
the CURRENT attempt, which its safety copies and its rebuild use.

**Why.** Every put-back read `captured.vmConfig` as "how the machine was", and
every PRECHECK wrote over it. A retry after a failed rollback and a rebuild as
the TARGET captured the machine on the target size, without its extensions,
and a later rollback or restore returned it there. A put-back now takes the
machine's shape - size, disk controller, accelerated networking on each
interface, each disk's type - from `captured.original`, and the disks from
`captured.vmConfig` (`Get-VmfPutBackCapture`): each attempt's copies are of
the disks that attempt found (SAFETY-RETRY-1).

**Migrating v15 documents.** Nothing to rewrite. A document with no
`captured.original` reads as before - its one capture is the original. The
first PRECHECK that writes the field on such a document keeps the capture the
document ALREADY holds as the first (the earliest it still knows), not the one
being taken (when the machine was touched). New documents get it at their first
PRECHECK. A document is written as v16 when the field is first added. A v15
document the defect already reached - a retry that already captured the machine
on the target size - stays wrong: that capture is the earliest it knows.

**Tests.** `RetryCapture.Tests.ps1` (the put-back capture, written once, the
contract, the restores and the reports), `StateMachine.Tests.ps1`
(ROLLBACK-RETRY-CAPTURE-1 context: kept through a kill and resume and a retry;
a rollback after a retry on Path A and Path B).
## target-advice v9 -> v10 (2026-10-03, V3-TEMPDISK-1)

**Change:** no field is added. A machine on a v3 size (Dv3, Dsv3, Ev3, Esv3)
now goes to the d size on v6 and v7 too (D4s_v3 to D4ds_v6, D4_v3 to D4ds_v6,
E4s_v3 to E4ds_v6), as it already did on v5, and each of its v5, v6 and v7
options carries `sizeChoices`: the d size (`best`) and the size without a
temporary disk. Before, `sizeChoices` held only machines chosen by shape.

**Why:** the rule changed what an option's `targetSize` is for a v3 machine.
A choice saved with no size takes the option's own size, so targets saved on v9
options would be planned on a size the screen never showed.

**Migrating:** nothing is converted. A v9 file is refused by name and made
again, as every earlier version is (`Set-VmfTargetChoice`, the targets step).
New in this version: `New-VmfPlan` refuses targets saved on options of another
version too - before, it checked only that the options had not been made again
since the save.

**Also:** `target-families.json` gains `replacements`, Microsoft's v3
replacement table with its page and the date it was read, without a format
change.

**Tests:** `V3TempDisk.Tests.ps1`; the sample, which gains a v3 machine, is
checked by `SamplesConform.Tests.ps1`.

---
## run-status v2 -> v3 (2026-10-03, APPROVE-GROUP-1)

**Change.** A new required `summary`: the WHOLE migration - `machines`,
`stateCounts` across every wave, `waves[]` {wave, machines, stateCounts} in the
order the waves run, `halted`, and `next` {wave, waitsFor}, where `waitsFor` is
`running`, `none`, `decision`, `acknowledgement`, `acceptance`, `approval`,
`unknown` or `start`. `writtenUtc` and `reason` say when and why it was written.
`updatedUtc` and `stateCounts` are no longer required: a migration whose waves
have not run yet has a document with the summary only. The live fields keep
their meaning - the wave that is running, or ran last - and a summary write
never changes them or their time.

**Why.** The document meant "a snapshot of the running wave", so the
migrations list could not tell a migration waiting for a person from one
nobody needs to touch, and listed a migration whose wave 2 waited as Completed
because wave 1's counts were all it had. This changes what the document MEANS,
not only its fields: it is now the summary of the migration, written at every
change the list shows, by one compare-and-swap writer.

**Migrating.** Nothing is converted on read. Every reader still takes a v1 or
v2 document, and an absent or older one has no summary, which reads as
"cannot tell": the picker calls such a run Completed only when its counts hold
every machine the plan moves, and never Waiting for approval. The next change
to a migration writes v3, keeping the live fields it finds; the daily timer
writes it for every migration that has a plan, so an installation is all v3 a
day after `azd up`. The tests are `tests/unit/RunSummary.Tests.ps1` (the
summary, every writer, the compare-and-swap, an older document kept), the
contract sample, and `tests/js/run-picker.test.js` (v2 and absent documents).
## plan-entry v16 -> v17 (2026-10-03, WAVE-LEVER-OVERRIDE-1)

**Change:** an entry may carry `decisions`: one record per setting a person
decided for that machine alone - `setting`, `by`, `utc`.
`Resolve-VmfDecision` writes one for each setting its `-PolicyOverride`
changes (a later decision for the same setting replaces it) and raises that
entry to v17. `New-VmfPlan` writes v17 entries with no records.

**Why:** a decision's answer is written to one machine's policy, and nothing
said it was that machine's own. The wave editor drew each wave from its first
machine and sent every setting on every save, so the next save wrote the card
over the answer, or spread it to the whole wave, and cleared the wave's
acceptance, approval and quota check. `Set-VmfWavePlan` now never writes over a
setting recorded here, and the wave editor names the machines that hold one.
The record is outside `policy`, so it is not part of the hash a wave's
acceptance is bound to; the setting's value is.

**Migrating:** nothing is rewritten. A v16 entry has no records, and reads as
no decision. A decision made before this change is NOT protected: it has no
record, so the next change of that setting on its wave's card writes over it.
(A machine that stays in its wave is written only when it held the value the
card showed; for a stop gate, which has two values, that is always so when the
change goes against the decision.) A decision made from now on is recorded.

Three settings belong to the wave, not to a machine - `capacityGate`,
`requireApproval`, `throttle` - because the engine reads one value for the
wave. No decision is recorded for one, and a change writes every machine.

**Tests:** `WaveLeverOverride.Tests.ps1` (the record, the save rule through the
service, the role checks, the shared fixture
`tests/fixtures/wave-own-settings.json`), `PlanV5.Tests.ps1` (the version),
`SamplesConform.Tests.ps1` (the sample carries a record),
`tests/js/wave-lever-override.test.js`.

## machine-choices v1 (new), target-choices v3 -> v4 (2026-10-02, MACHINE-PICK-1)

**Change:** a new document, `machine-choices.json`, beside a reviewed
assessment (`schemas/machine-choices.schema.json`). `Set-VmfMachineChoice`
writes it from the first step of the migrate flow, **Choose the machines**: the
vmId of each machine the migration moves, who saved the list, the scan it is
bound to (`assessmentHash`) and the target options it was drawn from
(`adviceVersion`). `New-VmfPlan` copies it into the migration as the stored
text, as it does `target-choices.json`.

`target-choices.json` v4 adds one field, `machinesVersion`: the document
version (PLANVER-2) of the `machine-choices.json` the targets were saved
against, or null when there is none.

**Why:** a scan of a resource group, a subscription or a management group finds
every machine there, and every machine that could move went into the migration
- the only way to leave one out was to take it out of a wave. Now only a chosen
machine may have a target (`Set-VmfTargetChoice`, 400), a plan holds only the
chosen machines (a machine left out gets no plan entry, so no target and no
wave, and stays in the assessment and its report; the run page and the report
call it "Not in this migration"), and the engine's `plan` operation refuses
without a list on every request, one that names a series included
(`New-VmfPlan -RequireMachineChoice`, set by `docker/entrypoint.ps1`). The targets record the
version of the list, so a plan refuses targets saved before the machines were
chosen again: a machine added since would have no target, and one taken out
would still have one.

**Migrating:** nothing is rewritten. **An assessment with saved targets and no
`machine-choices.json` - made before this change - counts every machine with a
saved target as chosen**: the engine's plan operation accepts it and the plan
holds those machines. The wizard opens the machines step for it, ticked from
those targets, so a person sees what moves before planning again. One thing
differs for such an assessment when it is planned again: a machine with no
saved target used to be a MANUAL plan entry with "No target was chosen"; now it
has no entry, because it was not chosen. Plans already written are not changed.
The first save of a list on such an assessment makes its targets older than the
list, so the targets step must be saved again - the wizard goes there next.
A v3 `target-choices.json` has no `machinesVersion` and reads as saved against
no list. A command-line `New-VmfPlan` with neither document plans every
machine, as before.

**Tests:** `MachineChoice.Tests.ps1` (the cmdlet, the schema, the 409 version
checks and the single-step write, the facade endpoint and its role gate, the
plan holding only chosen machines, the plan operation refusing without a list,
the backward-compatibility rule); `SamplesConform.Tests.ps1` (both samples);
`TargetChoice.Tests.ps1` and `MachineTarget.Tests.ps1` (three tests rewritten
to the new rule, with the reason); `tests/js/choose-step.test.js`.
## capacity-claim v11 -> v12 (2026-10-25, QUOTA-PREVIEW-1)

**Change:** two optional fields in `quota`. `quota.name` (string or null) is
Azure's own name for the quota, as the usage list gives it (`LocalizedValue`,
for example "Standard DDSv6 Family vCPUs"). `quota.requestAccess` (`granted`,
`missing`, `unknown` or null) says whether the identity that ran the quota
check may request the quota. Test-VmfQuota asks only when it finds the quota
too low (`blockReason` `quota-shortfall`): it reads its effective permissions
on the SUBSCRIPTION (`Get-VmfEffectivePermissions`, the read the pre-move
permission check makes) and compares them with the Microsoft.Quota actions of
`data/rbac-actions.json` (`Get-VmfQuotaRequestActions`). `unknown` is a read
that failed.

**Why:** the design for Request an increase. The confirmation shows
Azure's column names, and Quota is Azure's name for the quota, not the family
code. And the access must be known at plan time, not at the click: a quota
belongs to a subscription, and an Azure role given on a resource group never
reaches the subscription (Microsoft, "Understand scope for Azure RBAC"). With
`missing`, the wave editor shows no request button and says to give the tool
access on the Admin page; `Request-VmfQuota` does not ask Azure for that quota.
`unknown` keeps the button, and Azure decides.

**Also changed, with no field:** `Request-VmfQuota` files ONE request per
quota (subscription, region, family) for the usage plus the vCPUs the whole
plan needs of the family (`demand.familyVcpus`, the number the check judged;
the sum of the records' `demand.vcpus` when no record carries it). It filed one
per record before, each for that record's vCPUs only. Every record of the quota
moves to `QUOTA_REQUESTED`. The `quotaPreview` activity log line (no schema)
now has one row per quota: `family`, `quotaName`, `subscriptionId`, `region`,
`usage`, `currentLimit`, `requestedLimit`, `free` (the current limit less the
usage, never below 0), `access`, `status` (`WHATIF`, `FAILED`, `NOACCESS`) and
`waves` (each wave's vCPUs of the quota).

**Migrating v11 claims:** nothing to rewrite. A v11 claim has neither field.
The wave editor shows the family code in the Quota column and says nothing
about access, and `Request-VmfQuota` asks Azure as before. The next quota check
of a wave writes v12 records. `New-VmfWaveReservation` raises a claim's version
when it writes it, and keeps whatever `quota` holds.

**Tests:** `QuotaRequestAccess.Tests.ps1` (the access read at the subscription,
granted, missing, a NotActions, a failed read, one read per subscription, no
read when the quota fits, the name, the record on disk against the schema, the
actions from the map); `QuotaPreview.Tests.ps1` (one row per quota, the family
total, what the limit leaves, NOACCESS, one request per quota);
`SamplesConform.Tests.ps1` (the sample); `tests/js/quota-preview.test.js` (the
confirmation and the card's access states).
## capacity-claim v10 -> v11 (2026-10-19, REGIONAL-VCPU-QUOTA-1)

**Change:** three optional fields and one block reason.
`demand.regionalVcpus` (integer or null) is the vCPUs the whole plan ADDS to
the subscription's Total Regional vCPUs quota in the record's region: each
machine's new size less its old size, never below 0. A machine that
continues a move and is not on its new size yet adds its whole new size, and
so does a machine a capacity reservation holds in a Reserved wave (the
reservation needs quota as a VM create does, while the old machine counts).
`quota.regionalLimit` and `quota.regionalUsed` (integer or null) are the
reading of that quota, `cores` in the usage list Test-VmfQuota already reads.
Null when Azure did not list it. `blockReason` gains
`regional-quota-shortfall`: the size family has the vCPUs, and the region does
not.

**Why:** Azure holds a quota for all vCPUs of a subscription in a region,
beside each family's, and refuses a resize or a rebuild on either. Only the
family was judged, so a wave whose families each fitted could stop a machine
and roll it back on the regional quota inside its change window. It is a
reason of its own, not `quota-shortfall`, because Request an increase raises a
FAMILY limit: a family request sized from such a record could ask for less
than the family has.

**Migrating v10 claims:** nothing to rewrite. A v10 claim has none of the
three fields; the migration page draws no Total Regional vCPUs row for it, and
the next quota check of a wave writes v11 records. `New-VmfWaveReservation`
raises a claim's version when it writes it, and keeps whatever `demand` and
`quota` hold. A reader that does not know `regional-quota-shortfall` treats
the record as blocked (`Test-VmfClaimBlocked` reads the state), which is the
safe side.

**Tests:** `RegionalVcpuQuota.Tests.ps1` (the check, the record on disk
against the schema, the release netting, an unlisted regional quota, Request
an increase leaving the reason alone, the start's words);
`CapacityContract.Tests.ps1` (a claim with and without the fields validates,
and the new reason); `ReserveCover.Tests.ps1` and `GateWords.Tests.ps1` (the two
new start-gate codes); `tests/js/regional-quota.test.js` (the migration page's
row and the wave editor's words).

## capacity-claim v9 -> v10 (2026-10-02, QUOTA-FAMILY-1)

**Change:** one optional field in `demand`: `familyVcpus`, an integer or
null. It is the vCPUs the whole plan asks of the record's quota family, in its
subscription and region, when the quota was checked - the number
Test-VmfQuota judges the headroom against (ODCR-FAMILY-1). Null when the
record has no family.

**Why:** the quota card on a migration's page is one row per quota family now
(issue 425), with vCPUs needed against vCPUs free. The page first added up the
records it could see, and the independent review found that number wrong: a
finished wave's records are never rewritten (its machines leave the plan's
demand), so the sum counted moved machines for ever, beside a quota reading
whose `used` already held them. The engine already works out the right number;
deciding it a second time in the page is the defect AGENTS.md item 8 names. So
the engine writes it, and the page shows it.

**Migrating v9 claims:** nothing to rewrite. A v9 claim has no `familyVcpus`,
and the page shows the vCPUs needed as not known for a row where no record
carries one. The next quota check of a wave writes v10 records for it.
`New-VmfWaveReservation` raises a claim's version when it writes it, and keeps
whatever `demand` holds.

**Tests:** `CapacityContract.Tests.ps1` (a claim with and without the field
validates); `AssessAndPlan.Tests.ps1`, ODCR-FAMILY-1 (every record carries
its family total, a migrated machine is not in it, a size with no family has
none); `tests/js/quota-family.test.js` (the card shows the newest record's
total, and never a page sum).

## guest-output vmf.guest/2 -> vmf.guest/3 (2026-09-28, VERIFY-FP-1)

**Change:** five optional facts - `imdsReached` (`yes` or `no`),
`imdsVmSize`, `imdsSecurityType`, `imdsSecureBoot`, `imdsVtpm` - what the
Instance Metadata Service answered from inside the guest. The `schema` field
accepts `vmf.guest/2` and `vmf.guest/3`; the two IMDS scripts emit v3.

**Why:** the facts object is closed, so a new fact is a contract change (hard
rule 1). These are the first facts added since v2 was made.

**Migrating v2 output:** nothing to rewrite. A v2 output is a valid v3 output
without these facts, and the engine reads a missing IMDS reading as unknown,
which never fails a move.

## vm-state v8 -> v9 (2026-09-28, SAFETY-RETRY-1)

**Change:** one optional array in `safety`: `earlierCopies`, each item
`{ pristineSnapshotId, pristineSnapshotLocked, snapshotId, snapshotLocked,
keptUtc }`.

**Why:** a person's retry from the first step kept the first attempt's copy
ids, so the new attempt took no copies of its own, and a second rollback put
back a system disk from before the first attempt - every write since was lost.
A retry now moves the earlier copies here and the new attempt takes new ones.
They stay on record so retention and run deletion still find them
(`Get-VmfSafetyCopyIds`).

**Migrating v8 documents:** nothing to rewrite. An absent list means no
earlier attempt kept copies. A document is written as v9 when a retry first
adds the list; new documents start at v9.

## vm-state: `captured.startedTarget` (2026-09-28, STATE-TARGET-1) - no version change

**Change:** PRECHECK records `captured.startedTarget` - `path`, `size`,
`controller`, `diskArch`, `series` - the target the machine starts on, after
every check that can park and before anything changes.

**Why no bump:** `captured` is declared open (`additionalProperties: true`,
"pre-mutation facts"), so the document's shape does not change and every
reader already accepts it. The vm-state version stays 8.

**Migrating:** nothing to rewrite. A machine that started before this has no
record, and a resume behaves as it always did.

**Tests:** `StateMachine.Tests.ps1` (STATE-TARGET-1 context: the record, and a
resume after the entry changed), `RecoverShell.Tests.ps1`.

## plan document v4 -> v5 (2026-09-27, WAVE-ORDER-1)

**Change:** the plan document gains `waveOrder`, the names of its waves in the
order they run. `New-VmfPlan` writes it; `Set-VmfWavePlan` writes the order the
wave editor sends. Entries are unchanged (plan-entry stays v15).

**Why:** the run order was the order the waves first appeared among the
machines, which is alphabetical by machine name, and each page showed its own
order.

**Migrating:** nothing to rewrite. A plan without `waveOrder` runs in
first-appearance order, as before (`Get-VmfPlanWaveOrder`, `VmfHelp.waveOrder`).

**Tests:** `WaveOrder.Tests.ps1`, `tests/js/wave-order.test.js`.

## wave-options-acceptance v2 -> v3, and plan-approval v1 -> v2 (2026-09-27, DECIDE-KEEP-1)

**Change:** both records gain optional `amendments`: each is a decision an
approver made after the record, with who, when, the one machine and the
settings it changed (`name=value`). When a decision writes a setting into one
plan entry, `Resolve-VmfDecision` moves the wave's acceptance
(`optionsHash`) and the plan sign-off (`planHash`) to the plan as it is after
the decision - only if each was current just before it - and appends the
amendment. The versions live in `Get-VmfWaveOptionsAcceptanceSchemaVersion` and
`Get-VmfPlanApprovalSchemaVersion`.

**Why:** a decision used to void both records, so the engine refused the wave,
the sign-off stopped counting, and the page offered no way to accept again
(the first ADVISOR-1 end-to-end run).

**Migrating:** nothing to rewrite. The schemas accept the older version too
(`enum`), and an older record simply has no amendments. A record that is out of
date stays out of date; `Test-VmfWaveOptionsAccepted` now returns a `Code`
(`notAccepted`, `changed`, `current`), and `Start-VmfWave` logs a `changed`
refusal with `wave` and `code = optionsChanged` so the page offers the
acceptance again.

**Tests:** `DecisionKeeps.Tests.ps1`, `tests/js/decide-keep.test.js`.

## plan-entry v14 -> v15, and target-choices v1 (2026-09-26, ADVISOR-1)

**Change:** `target.choice` records where a machine's size series came from:
`default` (the option it started on under the migration's default), `person`
(somebody changed it), `plan` (the plan was built on one series for every
machine, as before) or `wave` (a wave's series change moved it), with who
chose it. Null when targets were chosen and none was chosen for the machine,
which is then not moved. `policy.targetGeneration` is now the machine's own
series. `schemas/target-choices.schema.json` v1 is new: the choices, saved
beside the assessment by `Set-VmfTargetChoice` and copied into the migration.

**Why:** the size series belongs to the machine, chosen before the waves
(ADVISOR-1). A Generation 1 machine the scan blocked for v6 is planned on v5
and placed in a wave (GEN-V5-2), beside machines planned on v6.

**No time is copied into the plan.** It stays in `target-choices.json`: a date
re-read from JSON is a date value, not the text that was written (CLAUDE.md,
PLANVER-2).

**Migrating v14 plans:** nothing to rewrite. `choice` is optional, and a v14
entry without it was planned on one series for the whole plan.

**Tests:** `TargetChoice.Tests.ps1`; `PlanV5.Tests.ps1` holds the version.

## assessment v1 -> v2 (2026-09-26, AN-PRIMARY-1)

**Change:** each machine gains `primaryNicAccelerated` - whether its primary
network interface has accelerated networking (true, false, or null when it
could not be read), picked by the engine's own rule: the interface Azure flags
primary, else the first.

**Why:** the engine decides the accelerated networking stop from the primary
interface. The assessment recorded only how many interfaces had it on, so for a
machine with several interfaces and some on, the target options could not say
whether a move to Intel D v5 would stop. The product must understand
machines with several network interfaces.

**The version is now held in one place** (`Get-VmfAssessmentSchemaVersion`, in
`Private/assess/AssessmentContract.ps1`), the way the plan's is, and read through
`Assert-VmfSupportedAssessment`: older versions are accepted, a newer one is
refused by name. `New-VmfPlan` and `New-VmfTargetAdvice` used to refuse anything
but 1.

**Migrating v1 assessments:** nothing to rewrite. The schema accepts 1 and 2; a
v1 machine has no `primaryNicAccelerated`, which reads as unknown - the options
then fall back to the count, as before.

**Tests:** `AnPrimary.Tests.ps1`; the sample is version 2.

---
## target-advice v1 -> v2 (2026-09-26, ADVISOR-1)

**Change:** `start` names the two defaults after Microsoft's lifecycle stages:
`current` (v6, else v7, else v5) and `extended` (v5, else v6, else v7), where
v1 said `newest` and `smallest`. `target-choices.default` uses the same two
words. The version lives in `Get-VmfTargetAdviceSchemaVersion`.

**Migrating:** none in place. `Set-VmfTargetChoice` refuses a v1 file with 409
and says to make the options again; the page reads a v1 file as not made and
offers **Make the target options**. The `advise` operation writes v2.

## target-advice v1 - a new document (2026-09-26, ADVISOR-1)

**Change:** `schemas/target-advice.schema.json`, written by the engine beside a
reviewed assessment as `target-advice.json`. For each machine: every size
series with its facts and whether this product supports it, and the option the
machine starts on under each of the migration's two defaults.

**Migrating:** nothing - it is new, and nothing older reads it. An assessment
approved before this change has none; starting the `advise` operation writes one.

**Also:** `target-families.json` gains a DS row (DS-series and DSv2, End of
Life, as Microsoft lists them) without a format change.

**Tests:** `TargetAdvice.Tests.ps1`; the sample is checked by `SamplesConform.Tests.ps1`.

---

## plan-entry v13 -> v14 (2026-09-26, GEN-V5-1)

**Change:** `policy.targetGeneration` accepts `v5` as well as `v6` and `v7`.
`target.controller` was always `NVMe` or `SCSI`; a v5 entry now carries `SCSI`,
taken from the size series rather than written as a fixed `NVMe`.

**Why:** Microsoft's rewritten guide (2026-09-25) and its new "Modernize to the
v5 VM series" page give v5 as the smoothest step for existing workloads, and
as the first step for the retiring v3 series. Since 2026-09-26, customers
can choose a less disruptive change. A v5 move is a plain
resize on SCSI, and v5 takes Generation 1 machines.

**Migrating v13 plans:** nothing to rewrite. A v13 plan can only hold `v6` or
`v7`, which v14 accepts, and `ConvertTo-VmfSupportedPlan` refuses only plans
NEWER than the reader.

**Two data files changed format with it**, neither under `/schemas`:
`target-families.json` v2 (each size series names its controller, the machine
generations it takes, where accelerated networking is required and which
processors can give MANA, plus Microsoft's lifecycle stages) and
`assessment-reasons.json` v3 (each reason names the size series it applies to).
Both ship inside the module and are read only by this build.

**Tests:** `PlanV5.Tests.ps1` - the version on both sides, the enum, the lever
table, a v13 plan still reading, every place a series is taken, and a machine moved between waves keeping
its own series and target size.

---
## vm-state v9 -> v10 and migration-record v1 -> v2 (2026-09-28, VERIFY-FP-1 part 3)

vm-state adds `evidence` {takenUtc, before, after}: each machine read before
the move and after it. migration-record adds a per-machine `evidence`
{takenUtc, rows[]} - each reading with its value before and after and what it
is: `same`, `planned` (the move is meant to change it), `changed` or
`notRead`. Never a pass or a fail.

**Why.** VALIDATING read everything below, judged it, and threw it away; the
record said "The product keeps no reading of the machine taken after the
move". The readings are now kept for attestation and for supporting a
customer later. Scope set 2026-09-28: what the product already reads
- Azure's view of the machine (`Get-VmfVmCapture`, the same function on both
sides), the Instance Metadata Service, and the guest's boot bus, NVMe driver,
volumes, storage pools or volume groups, temporary disk, page file and
accelerated networking driver. Listening ports and services were dropped.

**The before guest reading is new.** Guest prep now runs the same read-only
validation script VALIDATING runs, once, on the untouched machine
(`captured.guestBefore`; `captured` is an open object, so no version for
that). A retry armed at guest prep or earlier reads it again.

**A reading that cannot be taken never stops a move**, and a record that
cannot be written is said and the machine is still MIGRATED. A lost lease
still stops, as everywhere.

**The record's `now`** for a migrated machine with evidence is now the size
Azure reported after the move (`basis`: "read from Azure after the move");
without evidence it is the plan target, as before.

**One version, one place.** `$script:VmfStateDocSchemaVersion` in
StateStore.ps1: the create, the reader's accepted range, and every writer of a
newer field use it. SAFETY-RETRY-1's writer set 9 as a literal; it now uses
the constant.

**Migrating:** nothing to rewrite. A v9 document has no `evidence`, and a v1
record has no `evidence` per machine - both are true of every machine moved
before this. Readers accept both.

**Tests:** `EvidenceRecord.Tests.ps1`; `SafetyRetry.Tests.ps1` derives the
version instead of pinning 9; the shipped `vm-state.sample.json` is v10 with a
record.

---
## capacity-claim v8 -> v9 (2026-09-28, RESERVING-STUCK-1)

Adds `reservationAsked` (the resource ids of the group and reservation, and
when they were asked for), `reservationUnconfirmedUtc`, and declares
`reservingSinceUtc`.

**Why.** The engine learned a reservation's ids only from Azure's answer. So
an engine that stopped between writing RESERVING and that answer left a claim
at RESERVING for ever, with no Release, and a create whose wait ran out was
written BLOCKED - "nothing is held" - while Azure could still finish it and
bill for it. Now the ids are recorded BEFORE Azure is asked, a wait that runs
out stays RESERVING (which bills in the product's rule) with
`reservationUnconfirmedUtc` set, and the release takes such a claim by its
recorded RESOURCE IDS - subscription, resource group and names all read from
the one id, because a name alone is unique only inside one resource group of
one subscription. An id in another subscription than its claim is refused.

**`reservingSinceUtc` was undeclared.** v7 wrote it with RESERVING and never
added it to the contract, whose `additionalProperties: false` made every
RESERVING claim invalid. It is declared now.

**Stuck** means: RESERVING and not confirmed, or RESERVING for 60 minutes or
more, or RESERVING with no start time. One rule on each side:
`Test-VmfClaimReservingStuck` and `VmfHelp.claimReservingStuck`, with the same
number of minutes.

**Migrating v8 claims:** nothing to rewrite. A v8 claim at RESERVING has no
`reservationAsked`; its ids are rebuilt from the rule reserving has always used
(`Get-VmfReservationNames`), from the claim's own subscription and resource
group. A v8 claim that a timeout wrote BLOCKED stays BLOCKED - whether Azure
finished that reservation later cannot be read from the claim.

**Tests:** `ReservingStuck.Tests.ps1`.

---
## capacity-claim v7 -> v8 (2026-09-22, BLOCKED-NAME-1)

**Change:** the state `CAPACITY_BLOCKED` becomes `BLOCKED`. Nothing else moves.

**Why:** it named a cause it was wrong about three times in four. The state
covers four situations and `blockReason` already says which:

| reason | is it about capacity? |
|---|---|
| `quota-shortfall` | no - a quota is a LIMIT, and Azure had the hardware |
| `sku-restricted` | no - the size is restricted in that region |
| `size-missing` | no - the size is not offered there at all |
| `reservation-failed` | **yes** - Azure had no capacity to hold |

So three times in four the state contradicted the field beside it. This is the
same defect BLOCK-SAY-1 fixed one level up, where a fallback LABEL asserted
"not enough quota" for a record whose cause was never measured.

**Migrating v7 claims: nothing is rewritten, and nothing needs to be.** A
claim written before today keeps `schemaVersion: 7` and `CAPACITY_BLOCKED`,
and is read for as long as it exists. Every reader asks ONE function whether a
claim is blocked - `Test-VmfClaimBlocked` in the engine, `VmfHelp.claimBlocked`
in the browser - and both accept either spelling. Nothing else in either
codebase may name the old value: `BlockedState.Tests.ps1` and
`tests/js/blocked-state.test.js` each census their side and fail on a second
copy, and each also fails if the compatibility is deleted, so the census
cannot start passing for the wrong reason.

**Reports normalise for READING only.** `Get-VmfClaimStateName` returns
`BLOCKED` for either spelling, so a report built today never shows an operator
a word the product no longer uses. It changes nothing on disk.

**The dashboard reads the store directly from the browser**, which is why the
browser needed its own copy of the rule rather than asking the engine.

**Why the folder and the event step did NOT move.** Renaming `capacity/` to
`quota/` means a dual read in two pages plus the engine, a migration and
version bumps, **for a name no operator ever sees**. The project's usual test
applies: what does this add to the product? The names that carry meaning are
the state and the activity-log label, and those are what changed - the label
in the first half of this item, the state here.

**Tests:** the enum on both sides, the version derived rather than pinned, the
one function in each language, the two censuses, and the migration exercised
rather than asserted - an old claim drives the wave refusal and a real quota
increase request.

---

## plan-entry v12 -> v13 (2026-09-19, PATH-C-1)

**Change:** `path` no longer accepts `"C"`. The enum is `A`, `B`, `MANUAL`,
`EXCLUDED`.

**Why:** `C` meant a redeploy from a fresh image. No planner ever produced it
and no engine step ever handled it - `Invoke-VmfStepConverting` has a branch
for A, a branch for B, and a guard that parks anything else as
`pathNotExecutable`, saying "A/B only". So the contract named a behaviour the
product does not have, and it named the one behaviour this product
deliberately does NOT do: both real paths keep the machine's own OS disk.

**Migrating older documents:** nothing to rewrite. No stored plan can carry
`C`, because nothing ever wrote one. `Test-VmfPlanReadable` refuses only plans
NEWER than the reader's own version, so every plan at v12 or below still reads.

**The quota record keeps `demand.overlapWithSource`, at version 7.** It
existed for `C` - the target had to be reserved while the source kept running -
and was written `false` every time, from a parameter no caller ever passed.
`demand` sets `additionalProperties: false`, so REMOVING the property would
make every claim written before today fail to validate. It stays optional and
accepted; its description now says it is always false and why; nothing writes
it.

**Tests:** `PathC.Tests.ps1` - the enum, the version on both sides, an older
plan still reading, the three dashboard word maps, and the rule that matters:
every executable path the schema offers must have a branch in the state
machine, counted rather than listed, so the enum and the engine cannot drift
apart again.
## assessment v1, first written down (2026-09-14, CONTRACT-1)

**Change:** none to the document. `assessment.schema.json` describes what
`Invoke-VmfAssessment` and `Get-VmfAssessmentRecord` already write. It is the
last significant document to get a schema; eleven others had one, including the
APPROVAL of an assessment.

**Why:** hard rule 1 - everything crossing a component boundary has a schema -
and this one crosses more boundaries than any of them: `New-VmfPlan` builds the
plan from it, five dashboard pages draw from it, and the support bundle carries
it. The gap's consequence is recorded in `ci.yml`: *"the function deciding
whether any assessment appears in the app had no tests at all, which is how 'I
see no assessments in the portal' happened."*

**The version stays 1, deliberately.** Fields were added to this document
without bumping it - `acceptedImages`, `notRead`, `nicCount` - and nothing
gates on the version. Bumping it now would claim a change that did not happen.
Closing the schema is what makes the NEXT addition deliberate.

**Migrating older documents:** nothing to rewrite. Only the fields that existed
from the beginning are required, so an assessment written before NIC-1, IMAGE-1
or IDENTITY-UX-1 still validates - and the store keeps that history for the
support bundle to read. A test drives exactly that case.

**Tests:** `AssessmentContract.Tests.ps1` - the sample, a record generated by
the writer itself, the closed-schema guard, an undeclared field at both levels,
a verdict nothing else knows about, an old assessment, and the four fields
allowed to be null.

## run-status v1 -> v2, plan-entry v12 range (2026-09-05, SCALE-2)

**Change:** `throttle.containers` (integer, >= 1) on the run status: how
many engine containers work the wave; `throttle.limit` is now the wave's
TOTAL "at once", not one container's share. The plan entry's `policy.throttle`
range widens from 1-20 to 1-60 (no version bump: a widening, every v12
document is still valid).

**Why:** SCALE-2 (2026-09-05) - scale out, not up. A wave above 15
at once is split over up to four containers of 15 (7 on a legacy
environment), each running the same orchestrator against the same store.
The resume watchdog restarts a stalled wave with the recorded total, so it
must be the total.

**Migrating v1 documents:** nothing to rewrite; absent `containers` reads as
1. The page reads `throttle.limit` as before.

**Tests:** `FacadeCore.Tests.ps1` (the split and the starts), `ScaleOut.Tests.ps1`
(the orchestrator's exit when other containers are working, the worker ids,
the record), the contract sample.

## vm-state v7 -> v8 (2026-09-05, SAFETY-3)

**Change:** three optional booleans in `safety`: `pristineSnapshotLocked`,
`snapshotLocked`, and `locksAllowed` (PRECHECK's answer to whether the
identity may place locks - Contributor may not, and the copies are then taken
unlocked with a warning on the run page rather than the migration refused).

**Why:** the safety copies are the restore chain, and nothing protected them.
The engine now places a `CanNotDelete` lock named `vmf-safety-copy` on each
copy the moment it is taken, and retention removes the lock before it
deletes. The document records that the lock was placed, so the run page and
the safety-copies card can say "locked" from the record rather than by
asking Azure, and so a resumed machine knows the step already ran.

**Migrating v7 documents:** nothing to rewrite. Absent reads as "not
recorded" (the copy was taken before this version and carries no lock); the
reader accepts 1 through 8. Documents written before this bump keep their
recorded version.

**Tests:** `SafetyLock.Tests.ps1` (the lock after each copy, the check before
the machine is changed, the unlock before the delete, the words on the run
page); the sample and the contract test carry the new fields.

## plan-entry v11 -> v12 (2026-09-04, SCALE-UX-1)

**What:** adds an optional `policy.throttle` (integer, 1-20): how many machines
the engine works on at the same time in this wave. A lever of the wave,
accepted with it, and the default for every start.

**Why:** since 2026-09-04, the number is set in the wave editor. The number
was typed at the last second by whoever pressed Start, defaulted to 3 for
everyone, and nothing recorded why. It is a decision of the wave, made by the
person who knows what the wave holds, so it belongs with the other levers.

**Reading old plans:** absent means 3, which is what every wave had. The wave
editor's save treats "absent" as 3 for the change comparison, so the first
save after this version does not strip approvals or acceptances from waves
nobody edited. The facade sizes the engine container from the number
(1-3 / 4-7 / 8-15 workers, re-based 2026-09-04 on the scale drill's
measurement) and refuses above 15; the schema's range of 1-20 is unchanged,
the running ceiling is the facade's.

## capacity-claim v6 -> v7 (2026-09-02, ODCR-VERIFY-1)

**What:** adds `RESERVING` to the claim `state` enum, plus an additive
`reservingSinceUtc`. `New-VmfWaveReservation` now writes the claim as
`RESERVING` and persists it BEFORE calling Azure, then moves it to `RESERVED`
or `CAPACITY_BLOCKED`.

**Why:** an ODCR can complete or fail depending on Azure. A review of the new
Reserve capacity button asked how it could report success so quickly, before
the capacity reservation group was built, and whether the pill showed pending
while Azure created it. It assumed the reservation worked.

Two real defects behind that finding.

1. `New-VmfCapacityReservation` treated the ARM create returning as the
   guarantee - its own docstring said so. It now waits for a terminal
   `provisioningState` and throws unless `Succeeded`, which lands the claim in
   `CAPACITY_BLOCKED` where it belongs.

   **CORRECTED 2026-09-02, after the drill.** This note first said the run
   "wrote RESERVED for a reservation that may never have existed". Measured
   against Azure, that is wrong: `New-AzCapacityReservation` blocks until the
   state is terminal, returning `Succeeded` after ~34s. The wait is insurance,
   not a repair, and the old code was very likely correct on this path. Kept
   because it makes the guarantee explicit and would catch an Az version or a
   size that returned early - not because it fixed a live defect.
   Evidence: `docs/evidence/odcr-verify-drill.json`.
2. There was no in-flight state at all. Creating a reservation takes minutes,
   and for that whole window the claim sat at its previous value with nothing
   saying a job was running - so a page reload brought the Reserve button back
   and a second press would have paid twice for one guarantee.

**Compatibility:** additive. A v6 reader sees a state it does not know rather
than a missing field; every existing state keeps its meaning. Nothing persists
`RESERVING` permanently - it is replaced by the terminal state in the same run.

**Tests:** `ReserveCapacity.Tests.ps1`, `CapacityContract.Tests.ps1`.

## wave-approval v1 — NEW schema (2026-08-25, APPR-1)

**What:** `approvals/<wave>.json` — an identity-bound, plan-hash-bound
authorization for one wave to execute. Written by `Approve-VmfWave` (identity
from the approver's Azure login, never typed); enforced by `Start-VmfWave`
for `requireApproval` waves (prod ring default); a changed plan invalidates
the approval via the hash. Also adds the additive plan-entry policy key
`requireApproval` (no plan-entry version bump: policy is open-shaped).
This document is deliberately the Stage 3 approval API resource.

**Tests:** `WaveApproval.Tests.ps1` (9).

Contract-first rule: every schema change bumps `schemaVersion` and lands here
with a migration note and a test (CLAUDE.md rule 1).

## capacity-claim v1 -> v2 (2026-08-25, CAP-2 / REH-1)

**Change:** `demand.reservableInstances` added (required, integer >= 0).

**Why:** Azure cannot associate availability-set members to capacity
reservations. Reserving slots for them double-counts the quota family: the
unusable reserved cores AND the general-capacity cores the AvSet VM actually
consumes. The REH-1 wave rehearsal jammed a 10-core Dsv6 family exactly this
way (reservation held 8, one AvSet conversion took 2, the second AvSet VM
got QuotaExceeded). `demand.instances` still drives quota verification
(total cores needed is the same either way); `reservableInstances` drives
ODCR quantity in `New-VmfWaveReservation`.

**Migrating v1 documents:** treat `reservableInstances` as equal to
`instances` (the v1 assumption). `New-VmfWaveReservation` applies exactly
this fallback when the field is absent. Claims are per-run artifacts, so no
stored documents need rewriting.

**Tests:** `AssessAndPlan.Tests.ps1` ("forecast splits AvSet members out of
reservable demand"), `Odcr.Tests.ps1` ("runway reserves only
reservableInstances", "runway SKIPS a cell whose demand is entirely AvSet
members").

## vm-state v3 -> v4 (2026-08-27, RETRY-1)

**Change:** `history[].reasonCode` added (optional string).

**Why:** every stop in the engine was free text. The dashboard could show an
operator the sentence the engine happened to write, and nothing else - no
statement of whether the machine had been touched, and no guidance on what to
correct before trying again. A retry button on top of that is a shrug.

The code resolves against `src/VmMigrationFactory/data/stop-reasons.json`,
which carries, per code: what stopped it, what it means, what to do, where it
left the machine (`untouched` / `restored` / `changed`), and whether retrying
actually helps. Counted from the
stop sites, ten of the roughly fourteen stops happen BEFORE the machine is
touched and are genuinely fixable by an operator (permissions, capacity, a
target size too small for the machine's interfaces or disks, a kernel below the
driver floor, data on the temporary drive, a hibernated machine, a resource
lock). Those retries are free. The post-conversion failures are the short list,
and their guidance says plainly that retrying alone will usually not help.

**Migrating v3 documents:** nothing to rewrite. `reasonCode` is additive and
optional - a v3 document is a v4 document with no stop recorded, and
`Read-VmfStateDoc` still accepts versions 1 through 4. The dashboard renders
the raw detail when a history entry has no code, and when a code has no
guidance entry, rather than inventing an explanation for it.

**Also in this change (no schema bump):** `Resolve-VmfDecision` accepts
`FAILED_ROLLED_BACK`. A machine that failed and was automatically put back is
the best retry candidate in the system, and it was the one state with no
control at all. `-ReturnTo` is now derived by `Get-VmfRetryEntryState` instead
of asked: only a failed VALIDATING pass re-validates, everything else restarts
at PRECHECK, which cannot skip a check.

**Defect found while rendering it:** the machine-state field started as a
boolean `touched`, which conflated "was it changed" with "is it back" - and the
page printed the reassuring half. A machine HELD on its new hardware after a
failed health check rendered as "This machine was put back as it was", which is
false about the single fact an operator most needs to be right. It is now a
three-value field, and only an actual rollback may claim `restored`. Found by
opening the page, not by a test; a test now holds it.

**Tests:** `StopReasons.Tests.ps1` (36), `ResolveDecision.Tests.ps1` (refusal
wording), `DriverReadiness.Tests.ps1` (asserts the code and its guidance rather
than reassurance text inside the engine's detail string).

## vm-state v4 -> v5, plan-entry v3 -> v4 (2026-08-27, FAIL-1)

**Change:** `vm-state.history[].machineState` added (optional, one of
`untouched` / `restored` / `changed`). `plan-entry.policy.bootFailure` and
`policy.validationFailure` removed.

**Why:** a product decision. Any failure after the machine was touched returns it
to the pristine copy and its original size and controller - not a policy, not a
per-wave lever, not conditional on which step failed. The two removed keys chose
between putting a failed machine back and leaving it on hardware it never
booted on, and there is nothing left for them to choose.

The reasoning is a product position rather than a technical default: migrations
run in a change window, so there are no writes to preserve, and a tool that
sometimes leaves a machine in an in-between state needs a support organisation
behind it. One sentence a customer can hold us to beats a matrix of conditional
behaviours.

`machineState` exists because where a stop left the machine is **independent of
why it stopped**. The same `capacityUnavailable` code means "untouched" at
precheck and "restored" when allocation fails mid-conversion, so the branch that
knows records it rather than the dashboard inferring it from the code. The
guidance table's `machine` field survives as the fallback for documents written
before this field existed.

**Migrating v4 state documents:** nothing to rewrite. `machineState` is additive
and optional; `Read-VmfStateDoc` accepts versions 1 through 5, and the dashboard
falls back to the guidance table when a history entry has none.

**Migrating v3 plan entries:** a plan still carrying `bootFailure` or
`validationFailure` no longer validates against the closed policy object, so
those keys must be dropped when a stored plan is re-validated. The ENGINE
ignores them regardless - a stale plan asking for the old hold still rolls back,
which `StateMachine.Tests.ps1` asserts directly.

**Also in this change (no bump):** `onDDataFound` and `onDriverBelowFloor
deliberately SURVIVE. They are not failure handling - they ask whether the
customer accepts a known risk before anything starts, which is a real per-wave
choice and belongs to WAVE-2. An earlier draft of the architecture revision said
all four levers disappeared; that was wrong and is corrected.

**Tests:** `StateMachine.Tests.ps1` (rollback restores the pristine disk;
evidence captured before the swap; a stale plan asking for the removed hold
still rolls back; a failure that cannot collect evidence still rolls back),
`StopReasons.Tests.ps1`, `StateContract.Tests.ps1`.

## plan-entry v4 -> v5, new wave-options-acceptance/1 (2026-08-28, WAVE-2)

**Change:** `ring` removed from the plan entry - the property, the enum, and
the required-list slot. Waves carry customer-typed names; the planner generates
neutral starting names (`wave-1..n`) only. New document:
`acceptances/wave-options-<wave>.json` (schema
`wave-options-acceptance.schema.json`), recording who accepted a wave's policy
levers, when, the levers themselves, and a SHA256 `optionsHash` over the wave's
sorted (vmId, policy) pairs.

**Why:** lab, canary, prod and non-prod are invented terms, and not all
customers use them. Every decision belongs to the customer during migration
planning: each wave takes any name the customer types, not a fixed set, and
each of these is a lever set per wave. And with it: a user must select the
options for every wave created. The product can set defaults, but a person
must click and accept them.

`Get-VmfRingPolicy` and its four-way table are gone; `Get-VmfDefaultWavePolicy`
is the ONE safe default set (pristine copy always - not a lever; park on
temp-drive data; BestEffort capacity; approval key explicit). Defaults are
PROVISIONAL pending a per-lever review; the acceptance gate is not:
`Start-VmfWave` refuses an unaccepted wave, engine-side, between the IaC
acknowledgement and the approval gate. Editing a lever or the membership after
acceptance changes the hash and voids it - accepting one thing must not
authorise a different thing (the same binding approvals have to the plan hash).

**Migrating v4 plans:** drop `ring` from every entry when re-validating; the
engine never reads it. Existing waves keep their names (`prod-1` remains a
valid NAME - it is just no longer a vocabulary). Every wave needs a first
acceptance before its next start.

**Tests:** `WaveOptions.Tests.ps1` (10), reworked `AssessAndPlan`/`SafetyCopy`/
`WaveApproval`/`WavePlan`/`StateContract`/`Dashboard` ring tests.

## plan-entry v5 -> v6 (2026-08-28, WAVE-2 follow-through)

**Change:** the policy value `park` is renamed `stop` in `onDDataFound` and
`onDriverBelowFloor`. No shape change.

**Why:** "park" was removed from the product vocabulary - the customer-
facing words are "stops" / "Needs a decision" / "See what to do" - and a
later check asked whether the term was really gone. It was gone from every
surface a person reads, but the machine-readable value inside the plan JSON
still said `park`: a rejected word riding inside a customer's own plan file,
and the reason the word kept leaking back into conversation. Now the contract
says what the product says: the machine STOPS for a person.

**Migrating v5 plans:** replace the value `park` with `stop` in those two
policy keys; nothing else changes. Any wave acceptance hash covering an edited
plan is voided by the edit (by design) - re-accept after migrating.

## vm-state v5 -> v6 (2026-08-28, WAVE-2 lever 7)

**Change:** new optional `retention` object on the machine's state document:
`deletedUtc`, `keepDays`, `deletedSnapshotIds[]`, `deletedBy`. Written only by
`Remove-VmfExpiredSafetyCopies`.

**Why:** `keepSnapshotDays` sat in the plan contract unread for weeks. It now
defaults to 7 days and is enforced - because the acceptance screen tells
a customer their safety copies are kept for N days, and until now the truth was
"forever, until somebody noticed the storage bill". A setting nothing enforces
is worse than no setting.

Deletion has to leave a mark, or the next person to need a copy gets Azure's
"snapshot not found" and no way to tell whether one was ever taken.
`Restore-VmfVm` now reads this block and says who deleted the copies, when, and
under what retention.

**Migrating v5 documents:** nothing to do - the property is optional and its
absence means the copies were never cleaned up. Documents at 1..6 still read.

## plan-entry v6 -> v7 (2026-08-28, WAVE-2 lever 8)

**Change:** new `policy.targetGeneration` (`v6` | `v7`), and `New-VmfPlan`
gains `-TargetGeneration` (default `v6`). The size transform no longer
hard-codes `_v6`, and it now accepts a v6 source (a v6 machine moving to v7 is
a real migration, not a no-op).

**Why:** the ruling - default to v6, with an option for v7 per wave -
which closes V7-1. The generation was hard-coded inside the transform, so a
customer whose region has v7 had no way to ask for it, and the plan never
admitted the tool had chosen for them.

**The refusal matters more than the feature:** a wave that asks for v7 in a
region with no v7 equivalent gets an unmapped machine and a reason naming the
v6 size that WOULD work - it is never quietly given v6. Silent substitution of
something the customer did not choose is the failure this tool argues against
everywhere else.

**Migrating v6 plans:** add `"targetGeneration": "v6"` to each entry's policy,
which is what those plans already meant. Any wave acceptance is voided by the
edit (by design) - re-accept after migrating.

## plan-entry v7 -> v8 (2026-08-28, WAVE-2 lever 6)

**Change:** `policy.workloadProbe` is REMOVED from the contract, and
`Test-VmfWorkloadProbe` is deleted with it. VALIDATING no longer runs any
application check.

**Why:** a scope ruling. The probe let a wave name an https:// or
tcp://host:port check that had to pass before a machine counted as migrated.
Two things were wrong with it. First, scope: this tool validates the MACHINE
it changed - booted, disks present, boot path on the planned controller,
accelerated adapter bound, security posture intact - and Microsoft's own
validate page assigns "app starts and is reachable" to the person who owns the
app. Second, and worse, consequence: a failed check inside VALIDATING is a
post-touch failure, so under FAIL-1 it ROLLS A HEALTHY MACHINE BACK. Apps fail
a reachability check for entirely ordinary reasons - slow warm-up, the load
balancer not having re-added the machine, DNS - and each one would have undone
a successful migration and cost an operator an hour.

**Migrating v7 plans:** delete `workloadProbe` from every entry's policy. A
plan that still carries it fails contract validation rather than being
silently ignored, which is deliberate: a probe nobody notices is gone reads as
an app check that is still running.

**Consequence carried:** the FAIL-1 lab drill used a deliberately-failing probe
as its trigger. It now sets a REAL lever to a value a healthy machine cannot
satisfy - accelerated networking off against a Boost target - so the drill
still proves automatic rollback on a machine nobody sabotaged.

## vm-state v6 -> v7 (2026-08-29, EVAL-L2)

**Change:** `SAFETY_PRISTINE` added to the `state` enum.

**Why:** it was missing. The engine has had a `SAFETY_PRISTINE` handler since
SAFETY-2 - it is the default safety copy, taken before guest prep rewrites the
boot path - so every machine that took a pristine copy wrote a state document
its own contract rejected, for as long as it sat in that state. Nothing caught
it because the only thing validated against this schema was a hand-written
sample, and the sample never used the state. The enum is now derived from the
engine's own declaration (`Get-VmfEngineStates`), so a state added to the
machine and missing from the contract fails a test instead of shipping.

**Migrating v6 documents:** nothing to rewrite. This is a widening - every v6
document is valid v7 - and the reader accepts 1 through 7. Documents written
before this bump keep their recorded version.

**Tests:** `EngineStates.Tests.ps1` (the schema enum, the handler table and the
lifecycle guards all read one declaration).

## capacity-claim v2 -> v3 (2026-08-29, EVAL-M8 / M9)

**Change:** `quota.checkedUtc` declared; `vmFamily`, `quota.limit` and
`quota.used` widened to nullable; `reservation-failed` added to the
`blockReason` enum.

**Why:** every claim this tool has ever written was invalid against its own
schema, in three ways at once, and nothing noticed - because the only document
ever validated against `capacity-claim.schema.json` was a hand-written sample
in `schemas/samples/`. The sample conformed; the code emitted something else.

1. `quota.checkedUtc` was added so the dashboard could stop implying the
   headroom reading was live. `quota` is a closed object and the field was
   never declared, so EVERY claim failed - unconditionally, from the moment
   that improvement shipped.
2. `quota.limit` and `quota.used` are written as null on the path CLAUDE.md
   documents as a known Azure bug: the s-suffix v6 families that do not appear
   in the usage listing. That is a primary fleet shape, and the fields were
   typed integer.
3. `vmFamily` is written as null whenever the size is not offered in the
   region - which is exactly when a claim is blocked and most worth reading -
   and was typed string.

`reservation-failed` is separate but the same shape of error:
`New-VmfWaveReservation` has always written it when an on-demand capacity
reservation cannot be created, and it was never in the enum. The dashboard
compounded it by testing for the single string `quota-shortfall` to decide
whether to warn, so a CAPACITY_BLOCKED claim whose reservation had failed
rendered with a green "Headroom verified" pill. That pill now reads the claim's
STATE, and an unreadable headroom figure renders as "Headroom not known"
rather than as verified.

**Migrating v2 documents:** nothing to rewrite. Every widening; a v2 claim is
valid v3. Claims are per-run artifacts in any case.

**What stops it recurring:** the claim is now built by `New-VmfCapacityClaim`,
a pure function with no Azure in it, and `CapacityContract.Tests.ps1` validates
WHAT THAT EMITS against the schema - including the null-quota and
null-family paths - rather than validating a sample no code produces.

## plan-entry v8 -> v9 (2026-08-29, EVAL-L3)

**Change:** `assessment.gen` widened to allow `null`.

**Why:** the assessment already produces it. Azure reports Hyper-V generation
at `properties.extended.instanceView.hyperVGeneration`, which is absent for a
machine that was **deallocated when discovery ran** - and `Rules.ps1` handles
that case explicitly, adding the prep item `verify-generation` and the note
"generation unknown (VM likely deallocated during discovery)". The contract
then declared the field required and typed `enum: ["V1","V2"]`, so every plan
containing such a machine was invalid against its own schema.

The fix is to widen rather than to invent a value. Gen1 is a hard blocker
(`gen1-requires-redeploy`), so reading unknown as V2 would plan a migration for
a machine that cannot be migrated - the exact mistake CLAUDE.md's standing rule
forbids: unknown must never be read as either a yes or a no. `null` now means
"Azure did not report it", the prep item says a person must check, and the
wizard already renders that in words.

**Migrating v8 plans:** nothing to rewrite - a widening, so every v8 entry is
valid v9, and `ConvertTo-VmfSupportedPlan` needs no value migration for it. The
version gate accepts anything at or below the build's declared version.

**Also:** `New-VmfPlan` wrote the entry version as a literal while the gate
read `Get-VmfPlanSchemaVersion`. Two copies of a number that must never
disagree; the writer now reads the declaration.

## wave-options-acceptance v1 -> v2 (2026-08-29, EVAL-L4)

**Change:** `runId` is now required and must be a non-empty string.

**Why:** `Confirm-VmfWaveOptions` read `$plan.runId`, a property no writer
creates - the field on a plan is `assessmentRunId`, which the two sibling
artifact writers a few files away read correctly. So every acceptance ever
written recorded `"runId": ""`. The schema permitted it: `runId` was the one
optional, unconstrained field while every neighbour carried `minLength` or a
pattern, and the test fixture hid it by fabricating a plan shape that had the
missing property.

Nothing reads the field today, which is why it caused no visible failure. But
this document is the record that a named person chose a named wave's settings,
and it is handed out over the API; one that cannot say which run it belongs to
is not that record. So the contract now refuses a blank identity, and the
writer refuses to produce one - a plan with no `assessmentRunId` throws rather
than writing something that looks like an acceptance and is not.

**Migrating v1 documents:** an acceptance written before this fix carries an
empty `runId` and is genuinely invalid - it does not identify its run and
nothing can recover which one it was, beyond the folder it sits in. They are
per-run artifacts inside their own run directory, so the run is knowable from
the path; no rewrite is attempted, and re-accepting the wave produces a
complete record. A wave edited since is void anyway (the options hash changes),
which is the ordinary case.

## capacity-claim v3 -> v4 (2026-08-29, ODCR-SUB-1)

**Change:** `subscriptionId` added, required and non-empty.

**Why:** subscription was absent from the capacity model entirely. The demand
matrix keyed on `wave | region | zone | size`, so machines from different
subscriptions were summed into ONE cell; `New-VmfWaveReservation` took a single
`-CapacityResourceGroup` and therefore created the reservation in ONE
subscription; and `Request-VmfQuota` read `(Get-AzContext).Subscription.Id` -
whichever subscription the operator happened to be signed in to.

A capacity reservation group is subscription-scoped: a VM can only associate
with one in its own subscription, region and zone. So for a wave spanning
subscriptions A and B, one over-sized reservation was created in whichever
subscription held the capacity resource group; every machine in the other one
silently fell back to unreserved general capacity - the exact failure the
Reserved gate exists to prevent - the customer paid for slots nothing could
consume, and the quota check that said it would all fit had been run against a
third thing entirely.

The claim now carries the subscription, the cell key includes it (so demand is
never merged across subscriptions), the claim FILE name includes it (two cells
differing only by subscription used to write to the same path, and the second
silently overwrote the first), quota is read in the cell's own subscription via
`Get-VmfVmUsage`, and the reservation group name includes it so two cells of one
wave cannot collide on a name.

**Migrating v3 claims:** they cannot be migrated - a v3 claim does not record
which subscription it applies to and there is no way to recover it from the
document. `New-VmfWaveReservation` refuses one by name and asks for
`Test-VmfQuota` to be re-run, which is cheap and read-only. Release
(`Remove-VmfCapacityReservations`) does better: it falls back to the
subscription embedded in the reservation's own resource id, so a reservation
made before this change can still be released rather than stranded and billing.

**Tests:** `Odcr.Tests.ps1` (reserves in the claim's subscription; group names
differ per subscription; a pre-v4 claim is refused), `CapacityContract.Tests.ps1`.

## plan-entry v9 -> v10 (2026-08-29, IDENTITY-2)

**Change:** `policy.onSystemAssignedIdentity` added (`stop` | `proceed`,
default `stop`).

**Why:** EVAL-C1 made the Path B rebuild reapply managed identity, and fixed
only the half that is fixable. A **user-assigned** identity is a standalone
resource with a stable object id, so reattaching the same resource id gives back
the same principal and every role assignment survives. A **system-assigned**
identity is destroyed with the machine; setting the flag again on the rebuilt VM
mints a brand new principal with a different object id.

So the machine came back "with an identity", the fidelity check compared TYPE
only - `SystemAssigned` equals `SystemAssigned` - and reported **MATCH**, while
every role assignment, Key Vault access policy and AAD SQL user bound to the old
object id was orphaned, with nothing on any screen saying so. Validation was
asserting something false about the one loss in that comparison which cannot be
undone afterwards.

The ruling: refuse by default, and record both ids on override. So the
capture now records `identity.principalId`, the live read returns
`identityPrincipalId`, the fidelity check compares the principals rather than
the types, and PRECHECK stops a system-assigned Path B machine with the reason
`systemIdentityCannotSurvive` before anything is touched. An operator who
accepts the consequence sets this lever to `proceed`, and the old principal id
is written to the run's events before it is destroyed - after the rebuild it
exists nowhere else.

**Migrating v9 plans:** nothing to rewrite. The lever is additive and its
default is the safe direction, so a v9 plan behaves as though it said `stop` -
which is the intended behaviour. A wave that genuinely wants to
proceed must say so explicitly, which is the point.

**Tests:** `RebuildFidelity.Tests.ps1` (the verdict, the MISMATCH, the unknown,
the user-assigned case that must still pass, the lever and its guidance).

## capacity-claim v4 -> v5 (2026-08-30, CAPRG-1)

Adds `resourceGroup` (required): the resource group a reservation for this cell
is created in.

**Why it exists.** REACH-1 shipped reserving from the app with a single
installation-wide setting, `VMF_CAPACITY_RG`, naming one resource group that had
to exist - under that same name - in every subscription a wave touched. That
suits one environment only: in another installation, it did not say how
reservations are handled across different subscriptions and resource groups.
It could not answer. No estate can promise one resource group name across twenty
subscriptions, nothing in the app helped anybody create them, and the tool only
said which were missing at the moment somebody pressed Reserve.

It was a question that did not need asking. A VM attaches to a reservation by
the reservation group's **full resource id**, so the reservation only has to
share the machines' SUBSCRIPTION and REGION - which resource group holds it
changes nothing about whether they can use it. And the plan already stores every
machine as a full ARM resource id, so the tool already knew a resource group
that exists, that the operator can see, and that they already have rights to.

So the claim now records the resource group its own machines are in, derived at
forecast time from the same plan entries the subscription comes from. When a
cell's machines span several groups the one holding the most of them wins, ties
broken by name so two runs over one plan always choose the same group. Any of
them would work; this is about being predictable.

**What went away with it:** the `VMF_CAPACITY_RG` setting, the
`capacityResourceGroup` template parameter, the `-CapacityResourceGroup`
parameter on `New-VmfWaveReservation`, `Remove-VmfCapacityReservations` and
`Invoke-VmfWaveCloseOut`, the pre-flight that checked the group existed in every
subscription, the `Test-VmfResourceGroupExists` operation, and its
`Microsoft.Resources/subscriptions/resourceGroups/read` entry in the RBAC map.
The close-out `unconfigured` outcome went too - there is nothing left to
misconfigure.

**Migrating v4 claims:** they cannot be reserved from, and say so
(`re-run Test-VmfQuota before reserving`). Guessing a resource group
would put a reservation somewhere nobody would think to look for it while it is
billing. Release still works on a v4 claim: it recovers the resource group from
the reservation's own id, which carries it.

**Tests:** `WaveCloseOut.Tests.ps1` (the id parsing, the ordinary single-group
case, the multi-group winner, the tie-break determinism, the null case, the
recorded field, the v4 refusal, and a guard that nothing anywhere asks where
reservations should go).

## run manifest v7 -> v8 (2026-08-31, ASSESS-PAGE-1)

The object manifest (`run.json`) becomes a real contract, with `kind`
(`assessment` | `migration`), `fromAssessment`, `scope` and `createdBy`.
Previously it was an informal file carrying a schemaVersion, a runId and a
timestamp, and no schema described it.

**Why.** An assessment needs its own page: it should not go into the run list
and sit there. Everything in the store was a run, so
scanning an estate created one that then sat in the run list looking like an
abandoned migration. An assessment is not a failed run: it answers a question on
its own, it gets re-run and compared, it is the thing that gets reviewed and
signed off, and it is READ-ONLY and deliberately broad where a migration writes
and should be as narrow as the estate allows. The manifest is what tells the two
apart, so it stopped being informal.

`fromAssessment` is the traceability the product has never had - a migration
could not say what it was planned from, or whether that assessment had been
reviewed.

**Two rules the schema enforces**, because each has a wrong answer that would
look reasonable: an assessment cannot claim to come FROM an assessment, and a
migration carries no scan scope of its own - it inherits the one its assessment
recorded.

**`kind` is required rather than defaulted.** A default would silently place
every existing object on one of the two pages, and being on the wrong page is
worse than being absent. The WRITER defaults to `migration`, which is what every
existing caller has always created; assessment is opt-in and explicit.

**Migrating v7 manifests:** an object written before this has no `kind` and
cannot be listed on either page. There is nothing to rewrite in the lab (the run
store is empty, verified 2026-08-31); for a store with real objects, treat a
missing `kind` as `migration` at read time - which is what they all are, since
assessments could not exist separately before this. That read-time rule is `Get-VmfRunKind` in the
engine and `runKind` in `help.js`, both held to `tests/fixtures/run-kinds.json`;
the daily check skipped such a run until RETAIN-KIND-1 (2026-10-05).

**Idempotence matters here more than usual.** Every operation calls
`Initialize-VmfRun`, so a call that overwrote `kind` would turn an assessment
into a migration the moment somebody planned from it. The manifest is written
once and never rewritten, and there is a test for exactly that.

**Tests:** `RunManifest.Tests.ps1` - the contract (both kinds, the two rules, a
missing kind, an invented kind, a closed object) and what the store actually
writes, including the idempotence.

## assessment-approval v1 (new, 2026-08-31, ASSESS-PAGE-1)

A new contract: a person's recorded decision that an assessment has been read
and a migration may be planned from it. Written at `approval.json` inside the
assessment.

**Why it is a gate rather than a record.** As in Azure Migrate, an assessment
(a report) is required before any migration: only after the report is reviewed,
approved and validated does a run start.
`New-VmfPlan` refuses an assessment without one, and the refusal lives in the
ENGINE rather than the wizard - a wizard-only gate is bypassed by the API path,
which is how the hosted engine actually runs.

Deliberately the same shape and discipline as `wave-approval`:

  - the identity comes from the approver's own sign-in and is never a parameter
    somebody can type. The facade approves ON BEHALF OF the validated browser
    user, because its own identity is a managed identity and stamping that would
    be a lie about who decided;
  - a reason is required;
  - `assessmentHash` binds the decision to the exact document that was read. An
    assessment cannot be overwritten, so this is evidence rather than change
    detection: it is what proves WHICH findings were signed off, months later.

`blockedAtApproval` records how many machines could not migrate at the moment of
approval. Approving an assessment with blocked machines is a legitimate
decision - move the eighty that can and deal with the twenty later - and the
record should say that was known rather than leaving it to be inferred from
timestamps.

**Nothing to migrate:** the contract is new. Assessments that predate it have no
approval and cannot be planned from until somebody reviews them, which is the
intended behaviour rather than a compatibility problem.

**Tests:** `AssessmentApproval.Tests.ps1` - the gate (refused, then allowed, and
that it lives in the engine), what the record contains, and that it is reachable
from the app on the same role as wave approval.

## capacity-claim v5 -> v6 (2026-08-31, ODCR-UX-1)

Adds `estimatedHourly` - what reserving this cell would cost per hour.

**Why.** The reservation dialog did not match how an ODCR is made. It warned
that reserving costs money, asked for a note,
and showed none of what was being decided. "It costs money" is a warning, not
information, and an operator was being asked to approve a spend they could not
see the size of. Which sizes, which region, which zone and how many were all
already on the claim; the cost was the one missing fact.

**It is the RETAIL list price, and the data says so.** Public price details are
fine to use, with a note that the price is retail and does not reflect a
customer's MACC discount. So `basis` is a required field pinned to `retail-list-price`
rather than a caveat each surface is trusted to remember - a price with no basis
is a number somebody eventually quotes at a customer. A customer with a
commitment or an enterprise agreement pays less. It is an order of magnitude for
a decision, not an invoice.

**Unknown is null, never zero.** The price list is a public API that can fail or
not know a size, and zero is the one wrong answer that looks like an answer.

The lookup lives behind the azureops boundary (`Get-VmfRetailPrice`) even though
it is not ARM and needs no authentication, so it can be mocked: a test that
reaches the real internet fails when somebody else's service is down. The
forecast caches per size+region+os, because the same cell repeats across waves
and the price list does not change between them.

**Migrating v5 claims:** nothing to rewrite. A claim without `estimatedHourly`
reads as unknown, which is what it is - the price was never looked up. Re-run
the forecast to get one.

**Tests:** the contract tests build a claim and validate it; the version
assertion is derived from `Get-VmfCapacityClaimSchemaVersion` rather than
pinned, which two tests were doing and which turns a bump into a chore.

---

## plan-entry v10 -> v11: how many temporary drives the target actually has (TEMPPOOL-1)

`target.tempDisks` - the number of LOCAL TEMPORARY disks the target size has.
Paired with `sourceTempDisks` on the assessment record, which is the same count
for the machine as it stands today.

**Why it is on the plan and not only the assessment.** The count for the SOURCE
is a fact about the machine, so it goes with the machine's other facts. The count
for the TARGET follows from the target SIZE, and the target size is chosen at
plan time - the assessment does not know it. Both are visible before anybody runs
anything, which was the point.

**What it answers.** A review of the guest script asked why it uses a pool
only for the NVMe temporary disks: it does not have to be a pool, and many
customers do not use one. Pooling stayed - the disks arrive RAW on every start
and a boot task rebuilds the pool, so there is nothing for a customer to manage.
What was missing was the information. Measured in centralus, three transitions
matter and they are not the same:

| transition | temp disks | what an operator sees |
| --- | --- | --- |
| v3 non-`d` -> v6 non-`d` | 1 -> 0 | the temporary drive DISAPPEARS |
| `d` -> `d`, small | 1 -> 1 | nothing changes |
| `d` -> `d`, D16ds and up | 1 -> 2, 4 or 6 | the machine gains drives |

**Unknown is null, never zero.** A size missing from the SKU catalog, or an NVMe
size whose per-disk capability is absent, gives `null` - "cannot tell". Zero says
"this machine has no temporary drive", which for a `d` size is a claim the data
does not support, and it is exactly the claim that would send an operator into a
migration believing nothing changes. The same rule as NIC-1's `MaxNetworkInterfaces`
and the retail price's `estimatedHourly`.

**The count is arithmetic on published capabilities, not the size name** (SKU-1):
`MaxResourceVolumeMB > 0` is the single SCSI temp drive of v3/v4/v5;
`NvmeDiskSizeInMiB / NvmeSizePerDiskInMiB` is the v6/v7 local NVMe count. The
name is consulted for one thing only - telling a genuinely diskless size from one
whose capabilities are missing - and even that asks `Get-VmfDiskArchitecture`
rather than carrying a second `d`-suffix regex, because two rules for one
question is how they drift (and a fresh regex gets `Standard_E8-4ds_v5` wrong).

**Migrating v10 plans:** nothing to rewrite. An entry without `target.tempDisks`
reads as unknown, which is what it is. Re-plan to get the count.

---

## run-manifest v8 -> v9: which project a run belongs to (PROJECT-1)

`project` - the id of the project this assessment or migration lives in, or
`null` for a run outside any project.

**Why a project exists at all.** With assessments and migrations split, the
product needs something larger that holds an assessment and the migrations in
it: a project. Before this, an assessment and the migrations
planned from it were one piece of work with nothing saying so except
`fromAssessment` pointing backwards. There was no name for the engagement, and
nowhere to see "this estate, assessed three times over two months, with two
migrations run from it". It is also Azure Migrate's shape, which matters because
that is the model operators already know.

**A project is a PREFIX, not an index.** Its runs live under it:

    <project>/project.json
    <project>/<assessmentId>/assessment.json
    <project>/<migrationId>/plan.json

That is what makes run names unique WITHIN a project rather than globally, so a
second scan of the same estate can be called "september" instead of having to
invent a name. `Get-VmfStorePrefixes` derives the list of projects from what is
actually in the store rather than from an index, because an index of projects is
a second source of truth that can disagree with the projects - a shape this
codebase has already paid for twice (the blocker wording, the storage check
names).

**The NAME is stored once, in `project.json`, and deliberately NOT repeated on
member runs.** A name copied onto every member is a name that can disagree with
itself. The manifest carries only the id.

**`project` is DERIVED, never passed.** `Resolve-VmfRunProject` reads it from the
run's parent prefix. Asking the caller to state it as well as create the run
there invites the two to disagree, and the disagreement would be silent. Same
reasoning as reading the run id from the path.

**Migrating v8 manifests:** nothing to rewrite. A manifest without `project` reads
as `null`, which is what it is - it belonged to no project, because there were
none. Such runs continue to work; they simply appear outside every project.

**Tests:** the manifest version is now DERIVED from the contract in
`RunManifest.Tests.ps1` rather than pinned in eight fixtures. The bump that
prompted this produced "expected 8, got 9" from tests that said nothing about
what had actually changed.

## plan-approval v1 (new, 2026-09-24, PLANRUN-1)

One signature for EVERY wave in a plan, at `plan-approval.json` in the run's
top level. The wizard's last step used to approve only the FIRST wave while the
person believed they had signed off the plan, and every later wave then sat
waiting for a signature nobody knew was missing.

**Where it lives, and why not in `approvals/`.** A wave approval is
`approvals/<wave>.json`, and a wave may be called anything - including
whatever name a plan approval would have been given in that folder. At the top
level it cannot collide.

**What reads it.** `Test-VmfWaveApproval` passes a wave when either its own
approval or the plan approval matches the CURRENT plan version (`planHash`,
the same `Get-VmfDocumentVersion` a wave approval uses). A changed plan drops
it, exactly as it drops a wave approval. The facade timer reads it as consent
to start the next wave when the previous one finishes.

**Migrating:** nothing to rewrite. A run without the document has no plan
sign-off, which is true of every run made before it existed; per-wave
approvals go on working unchanged.

## target-advice v2 -> v3 (2026-09-29, SIZE-FIT-1)

Two reasons a size series can be closed to a machine, from the planner's size
choice:

- `smaller-than-source` - every candidate target has fewer vCPUs or less
  memory than the machine's own size. The planner no longer picks a smaller
  size by name (Standard_D4_v2, 8 vCPUs, had mapped to Standard_D4_v5, 4).
- `shape-unknown` - the machine is on a size whose number is not its vCPU
  count (D v1, DS v1, Dv2, DSv2 and their constrained sizes, Av2 memory sizes),
  and the catalog does not give the vCPUs and memory to compare.

**Migrating:** nothing is converted. A version-2 file is refused by name
(`Set-VmfTargetChoice` and the targets step), and the target options are made
again, the path every earlier version already used. `target-choices.json`
binds the options by document version, not schema version, so it needs
nothing.

## vm-state v10 -> v11 (2026-09-29, SAFETY-ALL-1)

**Change.** `safety.pristineDataCopies` and `safety.dataCopies`: one record
per data disk (`lun`, `diskId`, `snapshotId`, `locked`), taken at the same
stopped moment as the OS disk's pristine and prepared copies. An
`earlierCopies` item gains the same two lists, so an earlier attempt's data copies keep their lock state.
The capture (`captured.vmConfig.dataDisks[]`) gains `skuName`; `captured` is
open, so that part is not a schema change.

**Why.** Every screen said "Snapshot of every disk"; the engine copied the OS
disk only. A put-back returned the OS disk to its copy while the data disks
kept what was written after it, and nothing could bring back a data disk the
move damaged. Since 2026-09-29, the product copies every disk and puts every
disk back.

**Migrating.** Nothing to rewrite: both are additions, so every v10 document
is a valid v11 document. A machine whose copies were taken before this change
has no data-disk copies on record; its put-back restores the OS disk and says,
for each data disk, that no copy of it is on record.

## target-advice v3 -> v4 (2026-09-29, V5-ADE-1)

**Change.** One reason added to the list an option may be refused for:
`disk-encryption-rebuild` - the move to that series is a rebuild, and the
machine uses Azure Disk Encryption. Only v5 can carry it: v6 and v7 are already
closed to such a machine by `disk-encryption-present`.

**Why.** A v5 move keeps Azure Disk Encryption only in place. The targets step
offered v5 to an encrypted Windows machine whose v5 move is a rebuild (one
with a temporary disk, in a region with no v5 d size), and the engine stopped
it at Checking, in the change window.

**Migrating.** Nothing is converted, the path every earlier version used: a
v3 file is refused by name (`Set-VmfTargetChoice`, the targets step) and the
target options are made again; then the targets step shows v5 as not offered,
with the reason. A target a person saved before this - v5 for such a machine -
is not moved by a plan built from it: the plan records the machine as not
moved (`MANUAL`), with the reason in its notes.

## target-advice v4 -> v5, and target-choices v1 -> v2 (2026-09-29, OLD-SKU-1B)

**Change.** Every option gains `sizeChoices`: the v5 sizes a Generation 1
machine, or one on a D v1, DS v1, Dv2, DSv2 or Av2 size, can take - for the D
and E families, the smallest size with at least the machine's vCPUs and
memory, and E's constrained sizes of that size. Each gives its vCPUs, active
vCPUs and memory, and one is marked best. Empty on every other option. A
choice in `target-choices.json` may name a `size` from that list; none, or the
option's own `targetSize`, is stored as `null`.

**Why.** An old size's number is not its vCPU count (D4_v2 has 8 vCPUs, D4_v5
has 4), so these machines got no v5 target at all after SIZE-FIT-1. Since
2026-09-29, the advice offers a choice of family and constrained vCPU size.

**Migrating.** Nothing is converted. A version-4 target-advice file is refused
by name (`Set-VmfTargetChoice`, the targets step) and made again, the path
every earlier version used. A version-1 target-choices file is read as it is:
it names no size, and each machine is planned on its option's own size. The
plan entry does not change: the chosen size is its `target.size`, and the wave
editor passes that size back when it checks the plan against the rules
(`Test-VmfPlannedTargetAgrees`). A size the rules no longer offer plans the
machine as not moved (`MANUAL`, `chosen-size-gone`), with the reason.

## target-advice v5 -> v6 (2026-09-29, OLD-SKU-V6-1)

**Change.** No field changes. `sizeChoices` is now given on the v6 and v7
options too, for a Generation 2 machine on a D v1, DS v1, Dv2, DSv2 or Av2
size. One reason added: `no-shape-fit` - the region has no D or E size on the
series with the machine's vCPUs and memory that the machine can take.

**Why.** Those sizes have no v6 or v7 size of their own name, so a Generation 2
machine on DS2_v2 could move to v5 only. The version changes so that options
made before this are made again, and those machines get their v6 and v7 choices.

**Migrating.** Nothing is converted: a version-5 file is refused by name
(`Set-VmfTargetChoice`, the targets step) and made again, the path every
earlier version used. A saved `size` in `target-choices.json` is checked against
the new options as before.

## target-advice v6 -> v7, target-choices v2 -> v3, plan-entry v15 -> v16, vm-state v11 -> v12 (2026-09-29, OLD-SKU-1C)

**Change.** One choice, carried through four documents:

- target-advice v7: `premiumDisks` on every option and every size choice -
  whether the size takes Premium SSD disks (the catalog's `PremiumIO`), null
  when the catalog does not say.
- target-choices v3: a choice may carry `disks` - `os` or `all` for Premium
  SSD during the move; null or absent keeps the disk types. The save refuses
  it on a size whose `premiumDisks` is not true.
- plan-entry v16: `policy.diskUpgrade` (`os` or `all`), copied from the
  choice for a machine the plan moves.
- vm-state v12: `diskTypeChanges`, every disk type change the product made,
  recorded before it is made and kept across attempts.

**Why.** The design for machines on old sizes: keep the disk types by
default, or upgrade them to Premium SSD during the move, picked per machine.
Azure allows two type changes per disk a day, so the changes must be counted.

**Migrating.** Nothing is converted. A version-6 target-advice file is refused
by name and made again. Every earlier target-choices file and plan is read as
it is: no `disks` and no `diskUpgrade` mean the disk types are kept. A state
document before v12 has no record, which means no change was made; the first
record raises it to v12.

## vm-state v14 -> v15 (2026-09-30, RESTORE-PB-1)

**Change.** `restore.rebuilt`: true when **Restore this machine** rebuilt the
machine on its original size.

**Why.** A machine the move rebuilt cannot go back to its original size in
place - Azure refuses that resize (measured in the lab on 2026-09-30). A
restore from the first copy now rebuilds it, as the move and the automatic
rollback do. A rebuild deletes the machine's definition and makes it again,
without its extensions, so the record must say it happened.

**Migrating.** Nothing to rewrite: an addition. A restore recorded before v15
has no field, and it did not rebuild the machine.

## vm-state v13 -> v14 (2026-09-30, RESTORE-ALL-1)

**Change.** `restore.dataDisks`: every data disk **Restore this machine**
replaced from the chosen copy (LUN, the disk before, the disk after), and
`restore.dataDisksKept`: every data disk it left as it was, with the reason.

**Why.** The restore put back the OS disk only, so a restored machine ran on
an OS disk of one moment and data disks of another. It now restores every
disk, and the record - which the machine's page and the IaC report read -
must say which disks changed and which did not.

**Migrating.** Nothing to rewrite: an addition. A restore recorded before v14
has neither field, and it replaced the OS disk only.

## vm-state v12 -> v13 (2026-09-29, IAC-REPORT-1)

**Change.** `rollback`: the last automatic rollback, when it happened, the path
it took, and the disks it made from the first safety copies - `osDisk` (null
when no copy was on record) and `dataDisks` (the LUNs it swapped; a disk left
as it was is not listed). Written after the retry state is cleared, and kept
across attempts: the machine runs on those disks until something replaces them.

**Why.** The customer's report lists, for every machine the product changed,
what a definition in code must match - new disks by name among them. The
rollback wrote its disk names only to events, so the report could only guess.

**Migrating.** Nothing to rewrite: an addition. A document from before v13 has
no record; the report then says no new disk for a rollback it cannot see.
## target-advice v7 -> v8 (2026-09-29, OLD-FAM-1)

**Change.** A size choice's `family` may be `Dl` (2 GiB for each vCPU) as well
as D and E. Machines on B v1, F, Fs and Fsv2 sizes now get size choices, as
Generation 1 machines and the other old sizes already did.

**Why.** Every one of those families is End of Life, and none has a size of
its own name on v5, v6 or v7, so they got no target. Microsoft's "Retired VM sizes
modernization guide" (2026-09-25) names Dl sizes for B v1 and for F, Fs and
Fsv2; without Dl a machine with little memory paid for twice the memory.

**Migrating.** Nothing is converted: a version-7 file is refused by name and
made again. A saved size still has to be one of the machine's choices; a
machine whose best choice is now a Dl size keeps a saved D size if it is still
offered.

## target-advice v8 -> v9 (2026-09-29, OLD-FAM-3)

**Change.** Three reasons an option can be refused for, from the assessment's
new blockers: `hpc-or-fpga-size` (the H family and NP), `local-nvme-storage-size`
(the L family) and `l-series-replacement` (G and GS).

**Why.** These families are kept out of the tool's scope. Each
is now named on the assessment, as outside the scope, with Microsoft's own
route - not left to read "no size in this family".

**Migrating.** Nothing is converted: a version-8 file is refused by name and
made again. An assessment made before this has no such blocker; scanning again
names them.

## migration-record v2 -> v3 (2026-10-02, REPORT-AUTO-1)

**Change.** Four new reasons a record is written: `putBack` and `rebuilt` - a
machine of the migration was restored or rebuilt; `stopped` - somebody stopped
the migration; `dailyCheck` - the daily timer found the report missing, failed
or out of date. Each time the engine keeps the record and writes the report
together. New fields, always written:

- `assessment` {machines, byClassification, notInMigration} - the fleet
  assessment the migration was planned from, or null when the run holds none.
  `notInMigration` (MACHINE-PICK-1) counts the scanned machines the plan holds
  no entry for, not Excluded and not platform-managed, once the plan holds
  machines - the rule the report's appendix used to mark one "Not in this
  migration";
- `quotaRecords[]` {wave, region, zone, size, family, vcpus, quotaUsed,
  quotaLimit, state, notes} - the live quota records;
- per machine: `assessment` {classification, generation, diskArchitecture,
  issues} judged for the series its entry moves to, `sizeAlternates`,
  `planNotes` and `pathCheckpoint`.

**Why.** Since 2026-10-02, the report is one kind, written by the engine. The Operator report's engineering appendix went with the second
kind, and every fact only it held had to land somewhere a person can still
read: the record, which administrators download from the Reports page.

**Migrating.** Nothing is converted. A kept v1 or v2 record stays what it is
until the next write replaces it; the Reports page draws a record of any
version and leaves out what an older one does not hold. The test is
`tests/unit/ReportAuto.Tests.ps1` ("every fact the appendix held is in the
record") and `tests/js/report-auto.test.js` (a record written before v3).

## migration-record v3 -> v4 (2026-10-20, RECORD-UNMOVED-1)

**Change.** A new outcome, `notMoved`, in `machines[].outcome` and in
`summary`. It is the outcome of a machine whose plan entry is MANUAL or
EXCLUDED and which has not started (`Get-VmfRecordOutcome`). Every other
machine keeps the outcome `Get-VmfMachineOutcome` gives it. The summary is now
counted from the machines of the record, so the two never disagree.

**Why.** The run page has said "Not moved" for such a machine since
MANUAL-WHY-1, and the service's run summary leaves it out of its counts
(LAB-UX-1). The record still called it `notStarted`, so a finished migration
read "Not started" in the record's summary, in its machine headings, and in the
report drawn from it, for machines nothing was ever going to move.

**Migrating.** Nothing is converted. A kept v3 record stays what it is until
the next write replaces it; the Reports page draws it as before. The tests are
`tests/unit/ReportAuto.Tests.ps1` ("RECORD-UNMOVED-1") and
`tests/js/report-auto.test.js`.
