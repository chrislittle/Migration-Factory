# Limits

What this version does and does not do, with numbers. The [support matrix](support-matrix.md) says which machines the product can migrate, and which machines are outside the scope of this tool.

## Machines

| Limit | Value |
|---|---|
| Network interfaces | The target size must hold every network interface of the machine. Azure allows accelerated networking on one network interface of a size with 2 vCPUs. The move turns it on for the primary network interface, so the product counts the primary network interface as on. A machine with it on more than one network interface after the move does not get a 2-vCPU size, and the product does not offer a larger size instead. To move it, turn off accelerated networking on the other network interfaces. Then assess the machines again. |
| Disks | Azure allows two type changes for each disk in 24 hours. A move that changes a disk to Standard SSD or Premium SSD, then a restore that sets it back, uses both. A retry inside those 24 hours stops before it changes the machine, and says when it can run. Azure Disk Encryption stops a move to v6 or v7, and an in-place upgrade (Preview), before the machine changes. A v5 in-place upgrade that keeps the kind of temporary disk also keeps Azure Disk Encryption. |
| Source sizes | A size that has a size in the same family on the target series moves to that size. An End of Life size whose number does not give its vCPUs gets a size in the Dl, D or E family: the smallest with at least its vCPUs and memory. These are B v1, D v1, DS v1, Dv2, DSv2, Av2, Amv2, F, Fs and Fsv2. A machine with one vCPU gets two, because no Dl, D or E size has one. A B v1 size uses CPU credits. It starts on a Bsv2 size, which uses CPU credits too, when the region has one that fits it. Its other choice is a size in the Dl, D or E family, which has full CPU performance all the time. **Details** says which. The machine keeps its processor maker, Intel or AMD. A v6 or v7 source cannot move to v5. The support matrix gives each source size, its lifecycle stage and its retirement date. |
| Target sizes | v5: the same family at v5. A Generation 1 machine, or a machine on one of those End of Life sizes, gets a v5 size in the Dl, D or E family with at least its vCPUs and memory. If the region has a constrained vCPU size with the same active vCPUs, a machine on a constrained vCPU size gets that size first. You choose the family and the size. A machine on a B v1 size gets the smallest Bsv2 size with at least its vCPUs and memory first. Bsv2 is Intel, as B v1 is. Basv2, which is AMD, is not offered. The size keeps the processor of the machine: AMD stays AMD, and Intel stays Intel. One exception: an Intel machine that keeps accelerated networking only on an AMD v5 size is also offered that size, and you choose. An AMD machine has no Dl size on v5. A Generation 2 machine on one of those sizes gets its v6 and v7 sizes in the same way. A machine whose size has a temporary disk gets a v5 size with one, when the region has it. The product does not offer the E104i v5 sizes. v6: the same family at v6. Where the region has v7, the same family at v7. Every Intel D and E size on v6 and v7 has an s after its number. A Ddv4, Ddv5, Edv4 or Edv5 machine gets the size with a temporary disk, such as D4ds_v6. A Dv4, Dv5, Ev4 or Ev5 machine gets the size without one, such as D4s_v6. A machine on a v3 size gets the v6 or v7 size with a temporary disk, or you choose the size without one. A Generation 2 machine on a Dav4, Dasv4, Eav4 or Easv4 size gets the AMD v5, v6 or v7 size with a temporary disk, when the region has it, or you choose the AMD size without one. Microsoft lists Dasv7, Easv7 and Fasv7 as the AMD v7 families. Some sizes have no size of the same name on v6 or v7: Ebsv5 and Ebdsv5 on v7, the isolated E104i and E112ib v5 sizes, the Intel E constrained vCPU sizes on v7, and the AMD E constrained vCPU sizes on v6. The isolated E80is_v4 and E80ids_v4 sizes have no size of the same name on v5, v6 or v7. These machines get no target. For a D, Dl or E size, **Details** say whether Microsoft has no size of that name, or this region does not have it. A person chooses the size of an isolated machine. |

## Size series

You choose the size series for each machine in the **Choose each target** step. The [support matrix](support-matrix.md) gives the disk controller, the machine generation, Windows, accelerated networking, MANA and the lifecycle stage of each series. The series also differ in these ways.

| | v5 | v6 | v7 | Bsv2 (B v1 only) |
|---|---|---|---|---|
| Temporary disk | SCSI, on a size with a d in its name | NVMe, on a size with a d in its name. It arrives empty at every start. | NVMe, on a size with a d in its name. It arrives empty at every start. | None. A Windows machine with a SCSI temporary disk moves by the in-place upgrade (Preview). |
| CPU performance | Full, all the time | Full, all the time | Full, all the time | Burstable, with CPU credits |
| Azure Disk Encryption | Kept by an in-place upgrade that keeps the kind of temporary disk. The Choose each target step does not offer the in-place upgrade (Preview) when the scan finds encryption, and Checking stops one. | Not available | Not available | As on v5. The step does not offer Bsv2 when the move to it changes the kind of temporary disk. |

A move to v5 changes the least. See **When to choose v5** in [What this product does](../understand/what-it-does.md).

## A wave

| Limit | Value |
|---|---|
| Machines in a wave | No limit, and no limit on the number of waves. The wave works on its machines at once value until every machine is done. |
| Machines at once | 5, 15, 30 or 60, the four choices of a wave. The limit is 60. Each container works on up to 15. Above 15 the product runs more containers, one per 15 machines. |
| Longest wave | One run lasts at most 24 hours. A wave that needs longer is resumed by the product from where it stopped. |
| Machines in one availability set | Always in the same wave. |

## Capacity

| Limit | Value |
|---|---|
| On-demand capacity reservation | One capacity reservation group for each wave, region and availability zone, with one capacity reservation for each size. Not for machines in an availability set, or in their own capacity reservation group. |
| The product's own quota | The Container Apps environment's core quota. The wave editor says whether a wave fits. |

## The product

| Limit | Value |
|---|---|
| Installs per subscription | Any number, each in its own resource group with its own environment name. Every install in the subscription shares the two custom roles. In Azure, each role name ends with a code made from the subscription. |
| Installs per directory | Any number. Each has its own application registrations, named after the environment. |
| People | Any number. Roles can be given to groups. |
| Regions | Any region that offers Azure Container Apps with workload profiles. The install checks. |

## What the product will not do

- Move a machine with Azure Disk Encryption to v6 or v7, or by the in-place upgrade (Preview).
- Move a machine that is already on v6 or v7 to v5.
- Change your infrastructure code.
- Start anything on its own. A person approves and starts every wave.

<!-- next:begin -->

---

**Next:** [What the product may do in Azure](permissions.md)

<!-- next:end -->
