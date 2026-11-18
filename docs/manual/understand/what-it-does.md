# What this product does

## What the product moves

| | Size series |
|---|---|
| From | The A v2, B v1, D, Dl, E and F families, v1 to v5, Intel and AMD, Generation 1 and Generation 2. |
| To | D, Dl and E on v5, v6 and v7. Bsv2 for a B v1 machine. A machine keeps its processor maker. A machine on an F, Fs or Fsv2 size gets an Intel D, Dl or E size. |
| Outside the scope of this tool | Machines that a platform manages (AKS, AVD and scale set members), machines on an Azure Dedicated Host or with hibernation enabled, confidential VMs, Arm, GPU, HPC, FPGA, storage optimized, G and GS sizes, and machines with more than 32 data disks. |

A move to v6 or v7 changes the disk controller from SCSI to NVMe, and needs Generation 2. A move to v5 or Bsv2 is a resize on SCSI. The [support matrix](../reference/support-matrix.md) lists every source size and target series.

## What the v6 and v7 sizes give you

Azure sells virtual machines in size series, such as v4, v5 and v6. Each series runs on a newer set of hardware. The v6 and v7 series run on the newest hardware Microsoft offers.

| Size series | Processors | Also |
|---|---|---|
| v6 | Intel Emerald Rapids, AMD Genoa | Azure Boost |
| v7 | Intel Xeon 6, AMD Turin | Azure Boost |

Azure Boost moves the work of storage and networking off the machine's own processors onto hardware built for that purpose.

What changes for a machine that moves to v6 or v7:

- **Disks.** Disks connect over NVMe instead of SCSI.
- **Network.** Accelerated networking can use the Microsoft Azure Network Adapter (MANA) in place of the Mellanox adapter.
- **Lifecycle.** Microsoft puts v6 and v7 in its Current lifecycle stage. It retires older size series on dates that it announces.

## Why a resize is not enough

Microsoft's own guidance is to treat a move to v6 or v7 as a planned upgrade, not as a blind resize from an older family. Four things change at the platform level, and each one needs a preparation step inside or around the machine:

| What changes | What it needs |
|---|---|
| Disks connect over NVMe | The operating system inside the machine must have its NVMe driver ready before the move. A machine without it starts and cannot find its own disks. |
| The temporary disk is different | On the v6 and v7 sizes it arrives empty at every start, or it is not there at all. Anything that depends on it must be moved or prepared. |
| A Windows machine on a size with a SCSI temporary disk cannot be resized to v6 or v7 without a preview feature | Azure refuses the request unless the subscription has the preview feature VMTempDiskResizePreview registered. With it, the machine is resized in place, as the same machine. |
| v6 and v7 need Generation 2 | A Generation 1 machine can move to v5, or to Bsv2 from B v1. Both take Generation 1 with a resize. When no such size fits it, the machine is outside the scope of this tool. |

Every v3 size, and every Dav4, Dasv4, Eav4 and Easv4 size, has a SCSI temporary disk, but no d in its name.

A move to v5 is a resize on SCSI, so the NVMe row does not apply to it. For a machine with a temporary disk, the product looks first for a v5 size that has one too. Then the next two rows do not apply either.

A move to v5 changes the least from every starting series, because nothing inside the machine changes for NVMe.

## When to choose v5

v5 is the size series that changes the least. A move to v5 is a resize that keeps the SCSI disk controller. The product does not prepare the operating system for NVMe, and it does not change the disk controller.

Choose v5 for a machine when one of these is true:

- **The machine is Generation 1.** v5 takes Generation 1 and Generation 2 machines. v6 and v7 take Generation 2 only. A machine gets no target when no size fits it.
- **The machine runs Windows Server 2016.** v5 takes it. v6 and v7 need Windows Server 2019 or later, because older versions cannot use NVMe disks. The product reads the version that the machine reports it runs, so an in-place upgrade of Windows counts. When the machine does not report a version, for example when it is stopped, it reads the version from the image.
- **The image does not support NVMe, or the machine has Azure Disk Encryption.** v5 keeps the SCSI disk controller. A v5 in-place upgrade keeps Azure Disk Encryption. When the move to v5 changes the kind of temporary disk, v5 is not offered for an encrypted machine.
- **You want the least change now.** A later move from v5 to v6 or v7 stays possible for a machine that v6 and v7 take. Assess the machine again when you are ready.

Windows older than Windows Server 2016 gets no target. It has PowerShell 4.0 or older, and the steps the product runs inside a machine have run only on PowerShell 5.1.

Know what v5 does not give you:

- **No NVMe disks.** The disks stay on SCSI, so the disk gains of v6 and v7 do not apply.
- **A lifecycle stage that may not change.** Microsoft puts v6 and v7 in its Current stage and v5 in its Extended stage. A move from v4 to v5 stays in Extended. A move from v3 or older leaves End of Life. Microsoft retires D, Ds, Dv2 and Dsv2 on 1 May 2028. Av2, Amv2, B v1, F, Fs and Fsv2 retire on 15 November 2028. Dv3, Dsv3, Ev3 and Esv3 retire on 15 November 2029. From one day before the retirement date, the product does not move a machine on such a size. Resize it yourself to a size that Microsoft supports, then assess it again.
- **No move back from v6 or v7.** A machine on v6 or v7 cannot move to v5.

On the network, the Intel D-family and E-family v5 sizes require accelerated networking. An Intel v5 host gives MANA or the Mellanox adapter, and this differs by region and by host. An AMD v5 size never gives MANA.

## What the product does

The product does that work for you, at the scale of an estate. It follows the four phases Microsoft recommends and adds what an operations team needs around them.

1. **Assess.** It finds every virtual machine in the places you allow it to look. For each machine it gives one group: Current, Can migrate, Some targets only, Cannot yet, or Not eligible. A machine that can migrate after preparation counts under Can migrate. It says which size series each machine can move to. It says why, in words, with a link to the Microsoft page that explains the reason.
2. **Plan.** You choose the machines that move, and the size series for each machine. The product chooses the size in that series, and the way the machine moves. It groups the machines into waves, which are groups that move together. You arrange the waves and choose how each one runs. It verifies the quota for every machine, and names any size the region restricts. A wave does not start until its machines pass.
3. **Migrate.** It moves one wave at a time. For each machine it takes a safety copy and prepares the operating system where the target needs it. Then it shuts the machine down, moves it, starts it, and checks it. Several machines move at the same time. Every step is recorded.
4. **Validate.** After the move it checks the machine on its new size:
   - Every disk is attached, and every storage volume is there again.
   - The Instance Metadata Service answers on the primary network interface and reports the target size. A machine that the service did not answer before the move does not fail this check.
   - The security type and the secure boot setting are as before.
   - Every network interface is there again, in the same order, with the same primary.
   - The system-assigned identity has the same object ID.
   - Accelerated networking runs on the Microsoft Azure Network Adapter (MANA) or on Mellanox, when it is on. A move to v5, v6, v7 or Bsv2 turns it on.
   - A script inside the machine confirms it starts from the disk controller the plan names. That is an NVMe disk for v6 and v7, and a SCSI disk for v5 and Bsv2.

   A machine that fails a check is rolled back to its original size.
5. **Report.** It writes a report of what moved, what did not, and the evidence behind each answer.

Two rules shape everything. Nothing changes a machine until a person approves it. The product can roll back every machine, from a safety copy taken before anything was touched.

## What it does not do

The [support matrix](../reference/support-matrix.md) names each machine that the product does not migrate, and why. Other things the product does not do:

- It does not move a machine with Azure Disk Encryption to v6 or v7, or by the in-place upgrade (Preview). A v5 in-place upgrade keeps Azure Disk Encryption. The Choose each target step does not offer v5 to an encrypted Windows machine whose move to v5 changes the kind of temporary disk.
- Of the drivers inside the guest, it reads only the NVMe and network drivers that the move needs. On Windows, it adds the MANA driver when the driver store has none. On Linux, it updates the kernel only when a person chose **Update the kernel** for that machine. Then only a kernel with no MANA driver, or older than the minimum Microsoft lists, is updated. It does not read the drivers of other products. Antivirus, backup and monitoring products install low-level drivers, and the product cannot tell you whether yours are current.
- It does not know whether your software vendor supports the target size.
- It does not read your backup product. It takes its own copies, and those are what it rolls a machine back from.
- It does not replan Azure Reservations or savings plans. An Azure Reservation bought for a v4 size does not follow the machine.
- It does not change your infrastructure code. If Terraform, Bicep or another tool defines a machine, that definition will not know about the move. You reconcile it afterwards, and the product asks you to confirm that you know this before a migration starts.
- It never acts on its own. A person approves every wave.

## Where it runs

Everything runs inside your own Azure subscription:

- **The dashboard** is a web page you sign in to with your normal work account.
- **The service** behind the dashboard records your decisions and starts the work.
- **The engine** does the work on the machines. It runs only when the service starts it, for work such as an assessment or a wave, and it stops when that work is done. The rest of this manual says "the product" for it.
- **The run store** is a storage account that holds every record: what was found, what was planned, what happened to each machine, and the log.

The product sends no record outside your subscription. The product has no account of its own on the internet. Three things reach outside it:

- **Something on this screen is wrong** on the **Get help** menu opens a report in the product's repository, in a new tab. The page name, the version and the migration are already filled in. You read the report before you send it.
- On Windows, a move downloads the MANA driver from download.microsoft.com when the machine has none.
- On Linux, **Update the kernel** uses the package repositories that the machine uses.

<!-- next:begin -->

---

**Next:** [Disclaimer](disclaimer.md)

<!-- next:end -->
