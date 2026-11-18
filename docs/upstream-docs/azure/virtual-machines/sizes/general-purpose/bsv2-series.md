# Bsv2-series sizes - Azure Virtual Machines | Microsoft Learn

Bsv2-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), or Intel® Xeon® Platinum 8370C (Ice Lake) processor in a hyper threaded configuration, providing low-cost CPU burstable general purpose virtual machines. Bsv2-series virtual machines utilize a CPU credit model to track how much CPU is consumed. The virtual machine accumulates CPU credits when a workload is operating below the base CPU performance threshold and, uses credits when running above the base CPU performance threshold until all of its credits are consumed. Upon consuming all the CPU credits, a Bsv2-series virtual machine is throttled back to its base CPU performance until it accumulates the credits to CPU burst again.

Bsv2-series virtual machines offer a balance of compute, memory, and network resources and are a cost-effective way to run a broad spectrum of general-purpose workloads. These include large-scale micro-services, small and medium databases, virtual desktops, and business-critical applications; and are also an affordable option to run your code repositories and dev/test environments. Bsv2-series offers virtual machines of up to 32 vCPU and 128 GiB of RAM, with max network bandwidth of up to 6,250 Mbps and max uncached disk throughput of 600 Mbps. Bsv2-series virtual machines also support attachments of Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

Read more about the [B-series CPU credit model](../../b-series-cpu-credit-model/b-series-cpu-credit-model).

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 32 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 1 - 128 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 51,000 IOPS 85 - 600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 4 NICs | 6,250 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_B2ts\_v2 | 2 | 1 |
| Standard\_B2ls\_v2 | 2 | 4 |
| Standard\_B2s\_v2 | 2 | 8 |
| Standard\_B4ls\_v2 | 4 | 8 |
| Standard\_B4s\_v2 | 4 | 16 |
| Standard\_B8ls\_v2 | 8 | 16 |
| Standard\_B8s\_v2 | 8 | 32 |
| Standard\_B16ls\_v2 | 16 | 32 |
| Standard\_B16s\_v2 | 16 | 64 |
| Standard\_B32ls\_v2 | 32 | 64 |
| Standard\_B32s\_v2 | 32 | 128 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [CPU Burst](#tab/sizeburstdata)
Base CPU performance, Credits, and other CPU bursting related info

| Size Name | Base CPU Performance of VM (%) | Initial Credits (Qty.) | Credits banked/hour (Qty.) | Max Banked Credits (Qty.) |
| --- | --- | --- | --- | --- |
| Standard\_B2ts\_v2 | 20% | 60 | 24 | 576 |
| Standard\_B2ls\_v2 | 30% | 60 | 36 | 864 |
| Standard\_B2s\_v2 | 40% | 60 | 48 | 1,152 |
| Standard\_B4ls\_v2 | 30% | 120 | 72 | 1,728 |
| Standard\_B4s\_v2 | 40% | 120 | 96 | 2,304 |
| Standard\_B8ls\_v2 | 30% | 240 | 144 | 3,456 |
| Standard\_B8s\_v2 | 40% | 240 | 192 | 4,608 |
| Standard\_B16ls\_v2 | 30% | 480 | 288 | 6,912 |
| Standard\_B16s\_v2 | 40% | 480 | 384 | 9,216 |
| Standard\_B32ls\_v2 | 30% | 960 | 576 | 13,824 |
| Standard\_B32s\_v2 | 40% | 960 | 768 | 18,432 |

#### CPU Burst resources

- The base CPU performance metric hasn't changed. The updated (2024) numbers were normalized using a `0 - 100%` scale. Previously, the scale was `0 - (vCPU x 100%)`.
- Bsv2-series virtual machines can burst their disk performance and get up to their bursting max for up to 30 minutes at a time.
- Learn more about [CPU bursting](../../b-series-cpu-credit-model/b-series-cpu-credit-model)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

Note

No local storage present in this series.

For frequently asked questions, see [Azure VM sizes with no local temp disk](../../azure-vms-no-temp-disk).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) |
| --- | --- | --- | --- | --- | --- |
| Standard\_B2ts\_v2 | 4 | 3,750 | 85 | 10,000 | 960 |
| Standard\_B2ls\_v2 | 4 | 3,750 | 85 | 10,000 | 960 |
| Standard\_B2s\_v2 | 4 | 3,750 | 85 | 10,000 | 960 |
| Standard\_B4ls\_v2 | 8 | 6,400 | 145 | 20,000 | 960 |
| Standard\_B4s\_v2 | 8 | 6,400 | 145 | 20,000 | 960 |
| Standard\_B8ls\_v2 | 16 | 12,800 | 290 | 20,000 | 960 |
| Standard\_B8s\_v2 | 16 | 12,800 | 290 | 20,000 | 960 |
| Standard\_B16ls\_v2 | 32 | 25,600 | 600 | 40,000 | 960 |
| Standard\_B16s\_v2 | 32 | 25,600 | 600 | 40,000 | 960 |
| Standard\_B32ls\_v2 | 32 | 51,200 | 600 | 80,000 | 960 |
| Standard\_B32s\_v2 | 32 | 51,200 | 600 | 80,000 | 960 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- Some sizes support [bursting](../../disk-bursting) to temporarily increase disk performance. Burst speeds can be maintained for up to 30 minutes at a time.
- Storage capacity is shown in units of GiB or 1,024^3 bytes. When you compare disks measured in GB (1,000^3 bytes) to disks measured in GiB (1,024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1,023 GiB = 1,098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly or ReadWrite. For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Network](#tab/sizenetwork)
Network interface info for each size

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mbps) |
| --- | --- | --- |
| Standard\_B2ts\_v2 | 2 | 6,250 |
| Standard\_B2ls\_v2 | 2 | 6,250 |
| Standard\_B2s\_v2 | 2 | 6,250 |
| Standard\_B4ls\_v2 | 2 | 6,250 |
| Standard\_B4s\_v2 | 2 | 6,250 |
| Standard\_B8ls\_v2 | 2 | 6,250 |
| Standard\_B8s\_v2 | 2 | 6,250 |
| Standard\_B16ls\_v2 | 4 | 6,250 |
| Standard\_B16s\_v2 | 4 | 6,250 |
| Standard\_B32ls\_v2 | 4 | 6,250 |
| Standard\_B32s\_v2 | 4 | 6,250 |

#### Networking resources

- [Virtual networks and virtual machines in Azure](/en-us/azure/virtual-network/network-overview)
- [Virtual machine network bandwidth](/en-us/azure/virtual-network/virtual-machine-network-throughput)

#### Table definitions

- Expected network bandwidth is the maximum aggregated bandwidth allocated per VM type across all NICs, for all destinations. For more information, see [Virtual machine network bandwidth](/en-us/azure/virtual-network/virtual-machine-network-throughput)
- Upper limits aren't guaranteed. Limits offer guidance for selecting the right VM type for the intended application. Actual network performance will depend on several factors including network congestion, application loads, and network settings. For information on optimizing network throughput, see [Optimize network throughput for Azure virtual machines](/en-us/azure/virtual-network/virtual-network-optimize-network-bandwidth).
- To achieve the expected network performance on Linux or Windows, you may need to select a specific version or optimize your VM. For more information, see [Bandwidth/Throughput testing (NTTTCP)](/en-us/azure/virtual-network/virtual-network-bandwidth-testing).

# [Accelerators](#tab/sizeaccelerators)
Accelerator (GPUs, FPGAs, etc.) info for each size

Note

No accelerators are present in this series.

---

## Feature support

| Feature name | Support status |
| --- | --- |
| [Premium Storage](../../premium-storage-performance) | Supported |
| [Premium Storage caching](../../premium-storage-performance) | Supported |
| [Live Migration](../../maintenance-and-updates) | Supported |
| [Memory Preserving Updates](../../maintenance-and-updates) | Supported |
| [Generation 2 VMs](../../generation-2) | Supported |
| [Generation 1 VMs](../../generation-2) | Supported |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Not Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Not Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
