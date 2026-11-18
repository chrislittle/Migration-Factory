# Words used in this manual

The dashboard and the product's records use each of these words for one thing.

| Word | Meaning |
|---|---|
| Estate | A set of machines you look after together, for example a datacentre you are leaving. |
| Project | A folder in the dashboard for one estate. It holds the assessments of that estate and the migrations planned from them. |
| Assessment | A look at your machines that changes nothing. It records every machine found and says whether each one can move. |
| Finding | One reason an assessment gives about a machine. A finding holds a machine back, or says what the product will prepare. |
| Accept an assessment | A person reads what an assessment found and agrees with it. A migration can only be planned from an accepted assessment. |
| Migration | The work of moving machines. One migration has one plan and several waves. |
| Plan | The list of machines that will move, the target size of each, the way each moves, and the waves. |
| Choose the machines | The first step of planning. You select the machines that a migration moves. Only these machines get a target and a wave. The other machines stay in the assessment. |
| Wave | A group of machines that move together, in the order you choose. |
| Wave settings | The choices for one wave, for example how many machines move at once, and what to do when files are on the temporary disk. |
| Accept the settings | A person reads a wave's settings and agrees with them. The wave cannot start until then. If the wave is edited, the settings must be accepted again. If the engine finds that the settings changed, the wave shows **Settings changed since they were accepted** and offers the acceptance again. |
| Approve a wave | A person signs off a wave so it can run. The default is that every wave needs this. The approval is for the machines and settings of that wave. A change to the wave clears it, and a change to another wave does not. |
| Start a wave | A person tells the product to begin moving the machines in a wave, now or at a time they choose. |
| Size series | A set of Azure sizes of one version, such as v5, v6 or v7. The dashboard says **Series and kind of change**, and each option names its series and its kind of change. You choose one for each machine. |
| Target | The size series and the size a machine moves to. You choose the series in the **Choose each target** step, and the product chooses the size in it. You also choose the family and the size of a Generation 1 machine or an older size. |
| Some targets only | An assessment group. A finding holds the machine back from some size series, and at least one other series stays open to it. |
| In-place upgrade | The way every machine moves. Azure changes the machine's size, and for v6 and v7 its disk controller. The machine keeps everything else. Microsoft uses this name for the same operation. |
| In-place upgrade (Preview) | An in-place upgrade from a SCSI temporary disk to another kind of temporary disk. Azure allows it only when the subscription has the preview feature VMTempDiskResizePreview registered. The product reads the feature and never registers it. |
| Safety copy | A snapshot of a machine's disks, taken so the machine can be rolled back. |
| Rollback | Return a machine to how it was: every disk from the first safety copy, and its source size and disk controller when the move changed them. The product does this on its own when a step fails after a change. Microsoft uses this word for it. |
| Restore | Make a new managed disk from each snapshot of a safety copy, and swap it onto the machine. The current disks stay, detached, unless you delete them. The copy **Before the migration** also returns the machine to its source size. |
| Needs a decision | A machine stopped before anything was changed, because something needs a person. |
| Needs attention | The machine stopped. Open the machine to see why and what to do. |
| Rolled back | A step failed after the machine was changed, and the product rolled the machine back to how it was, from the first safety copy. |
| Restored | A person restored the machine from a safety copy. |
| Migrated | The machine is on the new size and passed its checks. |
| Capacity | The infrastructure that Azure has in a region or zone. |
| Quota | The permission of the subscription to deploy vCPUs of a size family in a region. You request a quota increase in Azure. A quota does not reserve or guarantee capacity. |
| On-demand capacity reservation | A promise from Azure to hold capacity for a wave, with a service-level agreement (SLA). It bills from the moment it is held until every machine of the wave has ended and the product releases it, or until you select Release. |
| Temporary disk | A local disk some sizes have. Nothing on it survives a restart. The v6 and v7 sizes have an NVMe one, or none. A v5 size with a d in its name has a SCSI one. Every v3 size, and every Dav4, Dasv4, Eav4 and Easv4 size, has a SCSI one with no d in its name. |
| NVMe | The disk controller the v6 and v7 sizes use, in place of SCSI. The operating system needs its NVMe driver ready before the move. The v5 sizes keep SCSI. |
| Accelerated networking | A setting on a network interface. It gives the machine a direct path to the network hardware of the host. Microsoft requires it on every v6 size and on the Intel D-family and E-family v5 sizes. |
| MANA | The Microsoft Azure Network Adapter. It carries accelerated networking on the v6 and v7 sizes and on some Intel v5 and Bsv2 hosts. An AMD v5 size never gives it. |
| Mellanox | The adapter that carries accelerated networking on the older sizes and on some Intel v5 hosts. The product accepts it after a move as it accepts MANA. |
| Lifecycle stage | Microsoft's name for where a size series is in its life: Current, Extended, End of Life or Retired. Microsoft puts v6 and v7 in Current, v4 and v5 in Extended, and v1 to v3 in End of Life. Microsoft does not name the stage of Bsv2, the burstable series, and the product treats it as Current. A series in End of Life has a retirement date. |
| Generation 1 | The older kind of Azure machine. It can move to v5 when a v5 size fits it. v6 and v7 take Generation 2 machines only. |
| Generation 2 | The kind of machine the v6 and v7 sizes require. A Generation 1 machine cannot move to v6 or v7. The v5 sizes take Generation 1 and Generation 2 machines. |
| System-assigned identity | An identity Azure gives a machine, so the machine can reach a key vault or a storage account without a password. A move keeps it, because every move is in place. |
| Run store | The storage account that holds every record the product writes. |
| Dashboard | The web page you use the product from. |
| Service | The part of the product behind the dashboard. It records your decisions and starts the engine. |
| Engine | The part of the product that does the work on the machines. It runs only when the service starts it for a job, for example an assessment, a wave or a restore. The manual says "the product" for it outside the technical chapter. |
| Sign-in rule | A person needs a role in the product to sign in at all. The install turns this on. |
| Role | What a person may do in the product: viewer, approver, operator or administrator. |
| Scope | A place in Azure where the product may work: a resource group, a subscription or a management group. |

<!-- next:begin -->

---

**Next:** [Before you install](../install/before-you-install.md)

<!-- next:end -->
