# Daldsv7 size series - Azure Virtual Machines | Microsoft Learn

Daldsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPUs, 320 GiB of RAM. The Daldsv7-series sizes offer a combination of vCPU, memory and fast local NVMe temporary storage for most production workloads. These VM sizes can reduce cost when running non-memory intensive applications. Daldsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 4 - 320 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 2,200 GiB 38,000 - 3,000,000 IOPS 280 - 22,400 MBps |
| Remote Storage | 10 - 64 Disks | 4,000 - 310,000 IOPS 118 - 10,356 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2alds\_v7 | 2 | 4 |
| Standard\_D4alds\_v7 | 4 | 8 |
| Standard\_D8alds\_v7 | 8 | 16 |
| Standard\_D16alds\_v7 | 16 | 32 |
| Standard\_D32alds\_v7 | 32 | 64 |
| Standard\_D48alds\_v7 | 48 | 96 |
| Standard\_D64alds\_v7 | 64 | 128 |
| Standard\_D96alds\_v7 | 96 | 192 |
| Standard\_D128alds\_v7 | 128 | 256 |
| Standard\_D160alds\_v7 | 160 | 320 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read IOPS | Temp Disk Sequential Read Throughput (MBps) | Temp Disk Random Write IOPS | Temp Disk Sequential Write Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- |
| Standard\_D2alds\_v7 | 1 | 110 | 50,000 | 280 | 25,000 | 140 |
| Standard\_D4alds\_v7 | 1 | 220 | 100,000 | 560 | 50,000 | 280 |
| Standard\_D8alds\_v7 | 1 | 440 | 200,000 | 1,120 | 100,000 | 560 |
| Standard\_D16alds\_v7 | 2 | 440 | 400,000 | 2,240 | 200,000 | 1,120 |
| Standard\_D32alds\_v7 | 4 | 440 | 800,000 | 4,480 | 400,000 | 2,240 |
| Standard\_D48alds\_v7 | 6 | 440 | 1,200,000 | 6,720 | 600,000 | 3,360 |
| Standard\_D64alds\_v7 | 4 | 880 | 1,600,000 | 8,960 | 800,000 | 4,480 |
| Standard\_D96alds\_v7 | 6 | 880 | 2,400,000 | 13,440 | 1,200,000 | 6,720 |
| Standard\_D128alds\_v7 | 4 | 1,760 | 3,200,000 | 17,920 | 1,600,000 | 8,960 |
| Standard\_D160alds\_v7 | 4 | 2,200 | 4,000,000 | 22,400 | 2,000,000 | 11,200 |

#### Storage resources

- [NVMe Overview](/en-us/azure/virtual-machines/nvme-overview)
- [FAQ for temp NVMe disks](/en-us/azure/virtual-machines/enable-nvme-temp-faqs)

#### Table definitions

- Temp disk performance depends on many factors including block size, workload patterns of read/writes, queue depth (QD), and others. Temp disk performance specifications should be viewed as best case performance numbers, assuming 4k block sizes and QD=256 for IOPS, and 256k block sizes with QD=64 for throughput. Read performance specs assume 100% reads, and write performance specs assume 100% writes. Additionally, write performance is heavily impacted by how many blocks in use on a device. Temp disk write performance specs assume a device has a clean slate to enable the best performance. During steady state operations, write performance is expected to be lower than the published specs.
- NVMe temp disks are presented as raw NVMe devices that need to be initialized and formatted before use. For more details on how to format and initialize drives, refer to the [NVMe Temp Disk FAQ](/en-us/azure/virtual-machines/enable-nvme-temp-faqs).
- Storage capacity is shown in units of GiB or 1,024^3 bytes. When you compare disks measured in GB (1,000^3 bytes) to disks measured in GiB (1,024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1,023 GiB = 1,098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) | Uncached Ultra Disk and Premium SSD v2 IOPS | Uncached Ultra Disk and Premium SSD v2 Throughput (MBps) | Uncached Burst Ultra Disk and Premium SSD v2 IOPS | Uncached Burst Ultra Disk and Premium SSD v2 Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard\_D2alds\_v7 | 10 | 4,000 | 118 | 44,000 | 1,412 | 4,400 | 136 | 48,400 | 1,653 |
| Standard\_D4alds\_v7 | 12 | 8,000 | 234 | 47,200 | 1,412 | 8,800 | 273 | 52,083 | 1,653 |
| Standard\_D8alds\_v7 | 26 | 16,000 | 468 | 47,200 | 1,412 | 17,600 | 547 | 52,083 | 1,653 |
| Standard\_D16alds\_v7 | 48 | 32,000 | 936 | 72,700 | 1,412 | 35,200 | 1,095 | 80,000 | 1,653 |
| Standard\_D32alds\_v7 | 64 | 64,000 | 1,872 | 94,400 | 1,916 | 70,400 | 2,191 | 104,167 | 2,241 |
| Standard\_D48alds\_v7 | 64 | 96,000 | 2,808 | 99,000 | 2,874 | 105,600 | 3,291 | 108,900 | 3,362 |
| Standard\_D64alds\_v7 | 64 | 128,000 | 3,744 | 132,000 | 3,832 | 140,800 | 4,382 | 145,200 | 4,484 |
| Standard\_D96alds\_v7 | 64 | 192,000 | 5,663 | 192,500 | 5,749 | 211,200 | 6,573 | 211,750 | 6,669 |
| Standard\_D128alds\_v7 | 64 | 204,800 | 7,488 | 225,280 | 7,663 | 281,600 | 8,764 | 310,886 | 8,966 |
| Standard\_D160alds\_v7 | 64 | 212,000 | 10,344 | 242,640 | 11,410 | 310,000 | 10,356 | 355,443 | 11,450 |

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
| Standard\_D2alds\_v7 | 2 | 16,000 |
| Standard\_D4alds\_v7 | 2 | 16,000 |
| Standard\_D8alds\_v7 | 4 | 25,000 |
| Standard\_D16alds\_v7 | 8 | 25,000 |
| Standard\_D32alds\_v7 | 8 | 25,000 |
| Standard\_D48alds\_v7 | 8 | 35,000 |
| Standard\_D64alds\_v7 | 8 | 45,000 |
| Standard\_D96alds\_v7 | 8 | 70,000 |
| Standard\_D128alds\_v7 | 15 | 75,000 |
| Standard\_D160alds\_v7 | 15 | 80,000 |

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
| [Generation 1 VMs](../../generation-2) | Not Supported |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Supported |
| [Temporary local NVMe disks](../../enable-nvme-temp-faqs) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

Note

This VM series will only work on OS images that support NVMe. If your current OS image doesn't have NVMe support, you'll see an error message. [NVMe](../../enable-nvme-interface) support is available on the most popular OS images, and we're continuously improving OS image compatibility.

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
