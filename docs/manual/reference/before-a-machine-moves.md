# Checks before a machine moves

Microsoft's migration guide lists eleven checks to make before a machine moves to a v6 or v7 size. This page says which checks the product makes for you, and which stay yours.

Of the eleven, the product makes six in full, two in part, and three not at all.

## What the product checks

Six checks in full, and two in part.

| Check | Where you see it |
|---|---|
| The machine is Generation 2, for v6 and v7 | No v6 or v7 size accepts Generation 1, and the assessment says so. The **Choose each target** step shows v5 for a Generation 1 machine when a v5 size fits it. |
| The target size fits the machine | The plan compares the network interface count and the data disk count with the target size, and refuses a size that holds fewer. Azure allows accelerated networking on one network interface of a size with 2 vCPUs. So the plan refuses a 2-vCPU size when more than one network interface has accelerated networking after the move. It does not offer a larger size. A Linux machine whose Azure Linux Agent reports a release that Microsoft does not list for MANA gets no v6, v7, Intel v5 or Bsv2 size. An AMD machine on such a release gets AMD v5. Checking asks Azure again before the machine changes. A machine with more than 32 data disks is outside the scope of this tool, and gets no target. |
| The quota allows it, and the region has capacity | Before a wave starts, the product checks the quota of the wave again, because a quota record can be old. A wave with too little quota does not start. Only an on-demand capacity reservation guarantees capacity. |
| The image supports NVMe | The assessment asks Azure what the image version can boot from, then checks the image against the supported list. |
| Hard-coded disk paths are rewritten | On Linux, guest preparation rewrites `/etc/fstab` to use disk identifiers that survive the change of controller. LVM can use a devices file. That file names each disk by its device ID. If LVM uses that file, the product installs a task. The task runs at the first start after the move. It writes the new device ID of each physical volume in the devices file. The product also installs this task for a move to v5 or Bsv2. |
| The temporary disk is handled | The assessment reads the disk architecture of both sizes. On Windows, guest preparation moves the page file off the temporary disk before the machine moves. |
| A copy exists to roll back to | The product takes its own copies before it touches the machine. See [Safety copies and rollback](../understand/safety-copies.md). |
| Rollback is planned and approved | Rollback is automatic. Any failure after the product touches a machine rolls the machine back to its original size from the first safety copy. |

## What stays yours

Three checks stay yours in full, and two in part. The product takes its own copies, but it does not read your backup product. The product checks the quota, but only an on-demand capacity reservation guarantees capacity.

| Check | Why the product does not make it | What to do |
|---|---|---|
| Low-level agents are current and signed | The product reads what Azure knows about a machine. Of the drivers inside the guest, it reads only the NVMe and network drivers that the move needs. It does not read the drivers of other products. Antivirus, backup and monitoring products install low-level drivers, and an old driver can stop a machine from starting on a new size. | Ask each vendor which version supports v6 and v7 hardware. Update the agents before the wave, and prove it on the pilot wave first. |
| The software vendor supports the target size | The product refuses the vendor appliances it can find: network virtual appliances, storage and backup appliances, and machines in an Azure managed application. It cannot know that your database or your business application is supported on a v6 size. | Ask the vendor. Record the answer before you plan the wave. |
| Your backup product completed a backup | The product takes its own copies, and those copies are what it rolls a machine back from. It does not read your backup product, and it cannot confirm that product supports Generation 2. | Run and confirm your own backup on your own schedule. The product's copies are for the migration, not for your retention rules. |
| The region has capacity | The product checks the quota. A quota does not reserve or guarantee capacity. With **On-demand capacity reservation for this wave** set to **No**, Azure can refuse the size when the wave runs. | For a wave that needs a guarantee, set **On-demand capacity reservation for this wave** to **Yes**. See [Capacity and quota](../use/capacity.md). |
| Azure Reservations and savings plans are replanned | Commercial planning is a decision, not a check. An Azure Reservation covers only the sizes of its own instance size flexibility group, so a reservation for the old size does not cover the new size. An Azure savings plan for compute covers the new size too. | Review your Azure Reservations and savings plans against the target sizes before a large wave. See [Costs](costs.md). |

The table holds the checks from Microsoft's guide. More things stay yours too. This list puts all of them in the order you meet them.

### Before the move

- The five checks in the table above.
- A Basic public IP address with the allocation method Dynamic. Set it to Static before the move. See [A dynamic public IP address](#a-dynamic-public-ip-address).
- Third-party software that changes boot behavior, storage drivers, filter drivers or disk enumeration, on a move to NVMe. See [Software that changes boot or storage](#software-that-changes-boot-or-storage-on-a-move-to-nvme).
- On Linux, application settings that name a disk by a device path. The product checks only the mounted volumes and `/etc/fstab`. Use a UUID in these settings.
- Where SQL Server keeps tempdb, on a move off a SCSI temporary disk. See [SQL Server and the temporary disk](#sql-server-and-the-temporary-disk).

### After the move

- Infrastructure code that defines a machine: Terraform, Bicep, Pulumi, ARM templates or Ansible. Update each definition, or the next apply can undo the migration. See [Finish a migration](../use/finish.md).

### What Azure decides

- A quota increase request. The product files it, and Azure approves or refuses it. See [Request a quota increase](../use/capacity.md#request-a-quota-increase).
- Capacity for the new size, when the wave has no on-demand capacity reservation. See the row **The region has capacity** above.
- Capacity for the original size, when a rollback needs it. See [Capacity for the original size](#capacity-for-the-original-size).

## A dynamic public IP address

A Basic public IP address with the allocation method Dynamic can change when the move stops the machine. The product does not read the public IP addresses of a machine. Before the move, set the allocation method of each such public IP address to Static. Microsoft retired Basic public IP addresses on 30 September 2025. Microsoft recommends an upgrade to a Standard public IP address. See [Microsoft: public IP addresses](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses).

## A move to v5

The eleven checks are for a move to v6 or v7. A move to v5 is a resize on SCSI, so some of them change:

- **Generation.** v5 takes Generation 1 and Generation 2 machines, so this check does not apply.
- **The image and the disk paths.** The disk controller does not change, so the NVMe part of the image check does not apply. The product does not rewrite the disk paths. The image must still be on the supported list.
- **The temporary disk.** For a machine whose size has a temporary disk, the product looks first for a v5 size that has one too. On Windows, the product moves the page file only when the target size has no temporary disk.
- **Accelerated networking.** Microsoft requires it on the Intel D-family and E-family v5 sizes, as on every v6 size, and says to turn it on before the resize. The product turns it on during the move, before the resize. On the other v5 sizes and the Bsv2 sizes too, a move turns it on for the primary network interface. The wave settings name each machine that gets it turned on, for any of these reasons. On a size that can give the MANA adapter, the product never keeps it off: v6, v7, Intel v5 and Bsv2. A Linux release with no MANA driver gets no such size. A kernel below the minimum stops before any change, unless you choose **Update the kernel**.
- **The checks that stay yours.** The checks in the table above stay yours for v5 too.

## Software that changes boot or storage, on a move to NVMe

A move to a v6 or v7 size changes the disk controller from SCSI to NVMe. Microsoft says: "Customized VMs that run third-party software capable of modifying boot-time behavior, storage drivers, filter drivers, or disk enumeration aren't currently a supported migration scenario." Microsoft gives examples: some backup, security, endpoint protection and storage management products. The product does not identify these products in a machine.

If such a machine moves to NVMe, the move can fail. Then the product rolls the machine back. To keep SCSI, choose v5 for that machine on the **Choose each target** step.

On NVMe, Linux gives new device names to the disks. For example, `/dev/sdc` becomes `/dev/nvme0n2`, as Microsoft's page on the move from SCSI to NVMe shows. On Linux, the product checks the mounted volumes and `/etc/fstab`. The product does not check application settings that name a disk by a device path. Examples are `/dev/sdc` and a link under `/dev/disk/azure/scsi1`. Before the move, check these settings, and use a UUID in them. Microsoft's guide to the in-place move to NVMe tells you to use stable identifiers. NVMe device numbers can change at each restart.

If a wave moves a machine to NVMe, **Run it** in the wizard and **Review & accept options** show Microsoft's sentence and these instructions.

## SQL Server and the temporary disk

SQL Server can keep tempdb on the temporary disk. On a size with an NVMe temporary disk, the disk is raw at each start, so the folder for tempdb is not there. On a size with no temporary disk, drive D: is not there. Then SQL Server can fail to start after the move. Microsoft's [page about SQL Server startup failures](https://learn.microsoft.com/en-us/troubleshoot/sql/azure-sql/sql-deployment-fails-drive-not-ready) tells you more.

The product does not look inside the machine for tempdb. It uses what the scan found. The product does these things for a machine where the scan found SQL Server. They apply only when that machine moves from a SCSI temporary disk to an NVMe temporary disk or none:

- The step **Choose each target** shows **Check where SQL Server keeps tempdb** under the size.
- **Run it** names the machine in the settings of its wave, and **Review & accept options** names it too.
- **Run it** lists the machine under **Before you sign off: SQL Server and the temporary disk**. The plan is not signed off until an approver ticks **I checked where tempdb is on each of these machines.**

Before the move, check where tempdb is on each of these machines. If it is on the temporary disk, put tempdb on another disk before the migration. Or choose a v5 size with a temporary disk for that machine. A v5 size keeps a SCSI temporary disk. A machine where the scan did not find SQL Server gets none of this.

## Capacity for the original size

Microsoft restricts capacity growth for older size series. A rollback returns a machine to its original size. A rollback can find no capacity for that size. The product does not guarantee capacity. See [Capacity and quota](../use/capacity.md).

## The pilot wave is where these are proved

Run one small wave first. A low-level driver that stops a machine from starting shows itself there, on machines you chose, at a time you chose.

See [Plan a migration](../use/plan.md) for how to arrange a pilot wave.

<!-- next:begin -->

---

**Next:** [Why a machine stopped](stop-reasons.md)

<!-- next:end -->
