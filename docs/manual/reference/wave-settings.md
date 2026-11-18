# Wave settings

Every wave carries these settings. A person accepts them before the wave runs, and again after any change. The dashboard shows them under **How this wave runs** in the wave editor, and reads them back at **Review & accept options**.

| Setting | Choices | Default | What it does |
|---|---|---|---|
| Someone must sign off before this wave runs | Yes, No | Yes | With Yes, an approver must approve the wave before it can start. An operator can set it to Yes. Only an Approver or an Administrator can set it to No. |
| On-demand capacity reservation for this wave | No, Yes | No | An on-demand capacity reservation holds capacity for the wave before it starts. It bills until every machine of the wave has ended and the product releases it, or until you select Release. Machines in an availability set cannot use one. It holds no place for a machine in its own capacity reservation group. |
| If files are found on the temporary disk | Stop and ask, Continue - the files are deleted | Stop and ask | Files on the temporary disk do not survive the move. Stop and ask parks the machine with a decision. Continue deletes the files. Only an Approver or an Administrator can set Continue. |
| How long the snapshot is kept | 0 to 90 days | 7 | Days after the machine is migrated, after which the daily cleanup deletes its safety copies. A machine that is not migrated keeps its copies. |
| How many machines at once | Pilot (5), Standard (15), Large (30), Maximum (60) | Standard (15) | How many machines the product works on at the same time. Each container works on up to 15, so Large runs two containers and Maximum four. Every start of the wave uses this number. |
| Snapshot of every disk before anything is changed | Always taken | Always | Shown for information. Not a choice. |

The kernel choice for MANA is not a wave setting. Each Linux machine has its own kernel choice, on the **Choose each target** step.

## What a change does

Saving a change to a wave clears its accepted settings, its approval and its quota check. Each of them described the wave as it was. The dashboard says so when you save, and names the waves. Accept and approve the wave again before it can start. A wave you did not change keeps all three.

## Where each setting lives

Each setting is stored on the wave's entry in the plan, inside the run store. The report shows the settings each wave ran with, so a question about a wave can always be answered afterwards.

<!-- next:begin -->

---

**Next:** [Limits](limits.md)

<!-- next:end -->
