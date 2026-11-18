# The run store

The run store is one storage account with four containers. `vmf-runs` holds every record the product writes, each as a small document. `vmf-deploy` holds one file: the service's program code, which the service reads with its own identity when it starts. `azure-webjobs-hosts` and `azure-webjobs-secrets` hold the data of the Azure Functions host that runs the service. The dashboard reads the records through the service. The service and the engine write the records with their own identities.

## Layout

```
vmf-runs/
  retention-status.json        the daily cleanup: its last pass, and the migration where the next pass starts
  schedule-status.json         the 5-minute check: its last pass, its last check of every migration, and where that check continues
  schedule-due.json            the migrations the 5-minute check examines: each has a wave, a restore or a schedule to watch
  vmf-claims/                  which run holds each machine, beside the runs
    <machine>.claim            the run that holds the machine
    deletions.jsonl            who deleted each migration, when, and the reason. It stays after the delete
  vmf-records/                 the record of each migration, beside the runs
    <project>--<run>.json      kept 90 days, also after you delete the migration
  <project>/
    project.json               the project's name and description
    <run>/
      run.json                 the manifest: what kind of run, when, by whom
      assessment.json          what the assessment found, machine by machine
      approval.json            who accepted the assessment, and their note
      machine-choices.json     the machines a person chose for a migration (beside an assessment)
      target-advice.json       the size series that each machine can move to
      target-choices.json      the target that a person saved for each machine
      plan.json                every machine that moves: target, path, wave, settings
      plan-run.json            what the signed-off plan does next
      catalog/
        <region>.json          the sizes that Azure offered in the region when the plan was made
      plan-approval.json       who signed off the plan, its waves, and the plan version they signed
      run-status.json          each wave's machines, what the next wave waits for, and the running wave's progress
      halt.flag                present while the wave's safety brake is on
      stopped.json             after Stop this migration: who stopped it, when, the note, and what the stop ended
      pacing.json              for a short time after Azure limits the engine's calls, when the workers wait
      acknowledgements/
        infrastructure-as-code.json  the confirmation about machines defined in code
      approvals/
        <wave>.json            who approved the wave, and the wave version they approved
      acceptances/
        wave-options-<wave>-<code>.json  who accepted its settings, and a hash of them
      decision-carry/
        <machine>.json         a decision for the machine that the product did not completely save
      schedules/
        <wave>.json            when it is to start, and the start that the service made
      state/
        <machine>.json         the machine's state, history and safety copies
      capacity/
        <claim>.json           a quota check or an on-demand capacity reservation for a wave
      capacity-history/
        <claim>.json           a released on-demand capacity reservation, kept for the report
      evidence/                the output of each guest script, and the boot diagnostics of a machine that did not start
      leases/
        <machine>.lease        a worker's hold on a machine, with a heartbeat
      logs/
        events.jsonl           every event, one per line, appended
        events-2.jsonl         the next part, when the part before it is full
      customer-report.html     the report, which the engine writes when a wave
                               finishes and when a machine is restored
```

In the name of an acceptance, `<wave>` is the wave name in lower case. Each character that is not a letter, a number or a dash becomes a dash. `<code>` is 12 characters that the product calculates from the wave name. Thus waves `wave_1` and `wave-1` have different files.

## The approval of each wave

Each wave has its own approval, in `approvals/<wave>.json`. `<wave>` is the wave name. An approver writes the file with **Approve** on the wave. The sign-off of the plan writes one file for each wave of the plan. Each file holds the run, the wave and these fields:

| Field | What it holds |
|---|---|
| `approvedBy` | The signed-in identity of the approver, and their tenant. The product takes them from the sign-in, never from typed text |
| `approvedUtc` | The time of the approval |
| `planHash` | The version of the plan that the approver saw |
| `waveVersion` | The version of the wave that the approver approved |
| `note` | The note of the approver |
| `amendments` | Each decision for one machine that an approver accepted after the approval. Only this kind of decision keeps the approval |

### The wave version

The product calculates the wave version from the stored plan. The version is a SHA-256 hash of these parts:

- The format version of the plan (`schemaVersion`), and the assessment that the plan comes from (`assessmentRunId`).
- The wave name.
- Each entry of the wave, complete: its target, path, settings and decisions.

The order of the waves is not a part of the version. Thus a change to when a wave runs does not ask for a new approval.

### When an approval is no longer valid

An approval is valid while its `waveVersion` is the same as the wave version of the plan now. These changes make it not valid:

- A change to an entry of the wave: a new machine, a removed machine, a new target, or a changed setting or decision. A machine that moves to another wave changes both waves.
- A change to the format version of the plan, or a plan that the engine makes again from another assessment.

A change to another wave does not change this wave's version, so this approval stays valid.

When the service saves a change to the plan, it removes each approval that no longer agrees with its wave. The engine compares the versions again before it starts a wave. It refuses a wave that needs an approval and has no valid approval. The wave then needs a new approval.

### The sign-off of the plan

The sign-off writes `plan-approval.json` after the approval of each wave. The file holds the approver, the waves, the note and the version of the complete plan (`planHash`). While the plan does not change, this file approves every wave of the plan.

The file also lets the run continue by itself. When a wave finishes, the service starts the next wave, unless that wave has a start time or a machine waits for a person. After a change to the plan, the service starts the next wave only if that wave's own approval is still valid. If it is not valid, the next wave waits for a person to approve it or start it.

### Each worker checks the wave version

When a wave starts, the engine reads the plan one time. It checks the acceptance, the approval and the quota of the wave against that read, and it calculates the wave version from it. The engine gives each worker this wave version.

Before a worker takes a machine, it reads the plan again and calculates the wave version. If the result is different, the worker takes no machine. The activity of the migration then says that the plan changed after the wave passed its start checks. Accept and approve the wave again, then start it.

When the service starts a wave by itself, it also gives the engine the wave version that its checks passed. The engine does not start the wave if its own read gives a different version.

## The activity log can be in more than one part

Azure accepts a maximum of 50,000 appends to one document. The engine writes
one append for each event, so a large run writes more events than one document
holds. When a part is full, the engine continues in the next part:
`events-2.jsonl`, then `events-3.jsonl`. The first part keeps its name.

The dashboard, the reports and the support bundle read all the parts, in order.

## The names of quota records

A quota record is named after its wave, subscription, region, zone and size. A short code follows these parts. The code keeps the names of two waves apart when the names differ only in a dot, a dash or an underscore.

## The documents

Most records have a schema and a format version inside them. The table below names the main ones. The flags, the claims, the log parts and the report have none.

| Document | Schema | Written by |
|---|---|---|
| An assessment | `assessment.schema.json` | The engine, at assessment |
| The target advice | `target-advice.schema.json` | The engine, when a person approves the review of an assessment |
| The target choices | `target-choices.schema.json` | The service, when a person saves the targets |
| A plan entry | `plan-entry.schema.json` | The engine, at planning; the service, when waves are arranged |
| A machine's state | `vm-state.schema.json` | The engine |
| The run status | `run-status.schema.json` | The engine |
| A quota record | `capacity-claim.schema.json` | The engine and the service |
| A guest script's output | `guest-output.schema.json` | A script inside a machine |
| The run manifest | `run-manifest.schema.json` | The service |
| A project | `project.schema.json` | The service |
| A wave's schedule | `wave-schedule.schema.json` | The service, when you schedule a wave and when it starts the wave |
| The 5-minute check's record | `schedule-status.schema.json` | The service, at each check |
| The migrations the 5-minute check examines | `schedule-due.schema.json` | The service and the engine, when a wave, a restore or a finish starts, when you schedule a wave, sign off a plan, make a decision about a machine or select **Resume**, and at each check |
| A worker's hold on a machine | `lease.schema.json` | The engine |
| Approvals and acceptances | `assessment-approval`, `wave-approval`, `plan-approval`, `wave-options-acceptance`, `run-acknowledgement` | The service |

## Writes that cannot race

Two kinds of write matter for safety. A lease is created with a write that fails if the document already exists, so two workers cannot lease one machine. A machine's state is written with a version check, so a stale worker cannot overwrite a newer state. The service writes a scheduled start into the schedule with a version check before it starts the wave. Thus a wave starts one time at its scheduled time, also when the service stops after the start. If Azure refuses the start, the service starts the wave again on its first check that is 10 minutes or more after the refused start. Every event is appended to the log, never rewritten.

## Who may read and write

| Identity | Access |
|---|---|
| A person with a role | No access. The service reads the records for them |
| The service | Storage Blob Data Contributor on `vmf-runs`. Storage Blob Data Reader on `vmf-deploy`. Storage Blob Data Owner on `azure-webjobs-hosts` and `azure-webjobs-secrets`. Storage Queue Data Contributor and Storage Table Data Contributor on the account. All granted by the install |
| The product's identity, for the engine | Storage Blob Data Contributor on `vmf-runs` only, granted by the install |
| The publish job, which publishes the program code of the service | Storage Blob Data Contributor on `vmf-deploy` only, granted by the install |

Each role for the containers stops at one container. No identity can read or write all the containers of the storage account.

Only the publish job can write the program code of the service. The service can read its program code and cannot change it. The engine cannot read or write it. Thus a write to the records cannot change the code that the service runs.

A publish writes the program code and reads no record, so its access stops at the `vmf-deploy` container. The publish job cannot read one plan, approval, machine state or safety copy record.

No key of the storage account is used by anything, and the account refuses keys outright. Every access is an identity signing in.

## Logs of the run store

This version keeps no request log of the run store. Azure does not record each read, write and delete of the records.

The product keeps these records:

| Record | Where | What it holds |
|---|---|---|
| The activity log of each migration | The run store | Each step and each Azure call for each machine, with the result |
| The records of each migration | The run store | The plan, the state of each machine, and each approval with the name of the person |
| Application Insights | The Log Analytics workspace of the product | Each call to the service, and its `VMF-CALLS` line with the times |
| The logs of the engine | The Log Analytics workspace of the product | What the engine writes while it runs |

The Log Analytics workspace keeps the logs of the engine 30 days. It keeps the tables of Application Insights 90 days. Microsoft sets 90 days on these tables by default. The install also sets 90 days on the Application Insights resource.

## Retention

The product never deletes the records of a run by itself. They stay until a person deletes a migration or an assessment from the dashboard, or removes the product. The daily cleanup deletes safety copies, which are snapshots in your resource groups, not records in the store. It also deletes each record in `vmf-records` after its 90 days.

<!-- next:begin -->

---

**Next:** [The perimeter around the run store](the-perimeter.md)

<!-- next:end -->
