# Ddv4 size series - Azure Virtual Machines | Microsoft Learn

The Ddv4 and Ddsv4-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) or the Intel® Xeon® Platinum 8272CL (Cascade Lake) processors in a hyper-threaded configuration, providing a better value proposition for most general-purpose workloads. It features an all core Turbo clock speed of 3.4 GHz, [Intel® Turbo Boost Technology 2.0](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Hyper-Threading Technology](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) and [Intel® Advanced Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html). They also support [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These new VM sizes will have 50% larger local storage, as well as better local disk IOPS for both read and write compared to the [Dv3/Dsv3](../../dv3-dsv3-series) sizes with [Gen2 VMs](../../generation-2). D-series use cases include enterprise-grade applications, relational databases, in-memory caching, and analytics.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | 1 Disk | 75 - 2,400 GiB 9,000 - 300,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 5,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2d\_v4 | 2 | 8 |
| Standard\_D4d\_v4 | 4 | 16 |
| Standard\_D8d\_v4 | 8 | 32 |
| Standard\_D16d\_v4 | 16 | 64 |
| Standard\_D32d\_v4 | 32 | 128 |
| Standard\_D48d\_v4 | 48 | 192 |
| Standard\_D64d\_v4 | 64 | 256 |

#### VM Basics resources

- [What are vCPUs](../../managed-disks-overview)
- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read IOPS | Temp Disk Sequential Read Throughput (MBps) |
| --- | --- | --- | --- | --- |
| Standard\_D2d\_v4 | 1 | 75 | 9,000 | 125 |
| Standard\_D4d\_v4 | 1 | 150 | 19,000 | 250 |
| Standard\_D8d\_v4 | 1 | 300 | 38,000 | 500 |
| Standard\_D16d\_v4 | 1 | 600 | 75,000 | 1,000 |
| Standard\_D32d\_v4 | 1 | 1,200 | 150,000 | 2,000 |
| Standard\_D48d\_v4 | 1 | 1,800 | 225,000 | 3,000 |
| Standard\_D64d\_v4 | 1 | 2,400 | 300,000 | 4,000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- Temp disk performance depends on many factors including block size, workload patterns of read/writes, queue depth (QD), and others. Temp disk performance specifications should be viewed as best case performance numbers, assuming 4k block sizes and QD=256 for IOPS, and 256k block sizes with QD=64 for throughput. Additionally, temp disk performance often differs between read and write operations. During steady state operations, write performance is expected to be lower than read performance.
- Storage capacity is shown in units of GiB or 1,024^3 bytes. When you compare disks measured in GB (1,000^3 bytes) to disks measured in GiB (1,024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1,023 GiB = 1,098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) |
| --- | --- | --- | --- | --- | --- |
| Standard\_D2d\_v4 | 4 | 3,200 | 48 | 4,000 | 200 |
| Standard\_D4d\_v4 | 8 | 6,400 | 96 | 8,000 | 200 |
| Standard\_D8d\_v4 | 16 | 12,800 | 192 | 16,000 | 400 |
| Standard\_D16d\_v4 | 32 | 25,600 | 384 | 32,000 | 800 |
| Standard\_D32d\_v4 | 32 | 51,200 | 768 | 64,000 | 1,600 |
| Standard\_D48d\_v4 | 32 | 76,800 | 1,152 | 80,000 | 2,000 |
| Standard\_D64d\_v4 | 32 | 80,000 | 1,200 | 80,000 | 2,000 |

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
| Standard\_D2d\_v4 | 2 | 5,000 |
| Standard\_D4d\_v4 | 2 | 10,000 |
| Standard\_D8d\_v4 | 4 | 12,500 |
| Standard\_D16d\_v4 | 8 | 12,500 |
| Standard\_D32d\_v4 | 8 | 16,000 |
| Standard\_D48d\_v4 | 8 | 24,000 |
| Standard\_D64d\_v4 | 8 | 30,000 |

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
| [Premium Storage](../../premium-storage-performance) | Not Supported |
| [Premium Storage caching](../../premium-storage-performance) | Not Supported |
| [Live Migration](../../maintenance-and-updates#live-migration) | Supported |
| [Memory Preserving Updates](../../maintenance-and-updates) | Supported |
| [VM Generation Support](../../generation-2) | Generation 1 and 2 |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Ephemeral OS Disks](../../ephemeral-os-disks) | Supported |
| [Local temporary storage](../../overview#local-temporary-storage) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
