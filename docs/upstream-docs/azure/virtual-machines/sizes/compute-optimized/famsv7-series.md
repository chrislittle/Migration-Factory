# Famsv7 size series - Azure Virtual Machines | Microsoft Learn

The Famsv7-series utilizes AMD's 5th Generation EPYC™ 9005 processor that can achieve a boosted maximum frequency of up to 4.5 GHz. The Famsv7-series VM comes without Simultaneous Multithreading (SMT), meaning a vCPU is now mapped to a full physical core, allowing software processes to run on dedicated and uncontested resources. These new full core VMs suit workloads demanding the highest CPU performance. Famsv7-series offers up to 80 full core vCPUs and 640 GiB of RAM. These VMs offer a combination of core and memory that is ideal for memory-intensive enterprise applications. The new VMs with no local disk provide a better value proposition for workloads that do not require local temporary storage. This series is optimized for scientific simulations, financial and risk analysis, gaming, rendering and other workloads able to take advantage of the exceptional performance.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 80 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 8 - 640 GiB |  |
| Local Storage | None |  |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4,000 - 212,000 IOPS 118 - 10,344 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 4,400 - 310,000 IOPS 136 - 10,356 MBps |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_F1ams\_v7 | 1 | 8 |
| Standard\_F2ams\_v7 | 2 | 16 |
| Standard\_F4ams\_v7 | 4 | 32 |
| Standard\_F8ams\_v7 | 8 | 64 |
| Standard\_F16ams\_v7 | 16 | 128 |
| Standard\_F32ams\_v7 | 32 | 256 |
| Standard\_F48ams\_v7 | 48 | 384 |
| Standard\_F64ams\_v7 | 64 | 512 |
| Standard\_F80ams\_v7 | 80 | 640 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

Note

No local storage present in this series.

For frequently asked questions, see [Azure VM sizes with no local temp disk](../../azure-vms-no-temp-disk).

# [Remote storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) | Uncached Ultra Disk and Premium SSD v2 IOPS | Uncached Ultra Disk and Premium SSD v2 Throughput (MBps) | Uncached Burst Ultra Disk and Premium SSD v2 IOPS | Uncached Burst Ultra Disk and Premium SSD v2 Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard\_F1ams\_v7 | 10 | 4,000 | 118 | 44,000 | 1,412 | 4,400 | 136 | 48,400 | 1,653 |
| Standard\_F2ams\_v7 | 12 | 8,000 | 234 | 47,200 | 1,412 | 8,800 | 273 | 52,083 | 1,653 |
| Standard\_F4ams\_v7 | 26 | 16,000 | 468 | 47,200 | 1,412 | 17,600 | 547 | 52,083 | 1,653 |
| Standard\_F8ams\_v7 | 48 | 32,000 | 936 | 72,700 | 1,412 | 35,200 | 1,095 | 80,000 | 1,653 |
| Standard\_F16ams\_v7 | 64 | 64,000 | 1,872 | 94,400 | 1,916 | 70,400 | 2,191 | 104,167 | 2,241 |
| Standard\_F32ams\_v7 | 64 | 128,000 | 3,744 | 132,000 | 3,832 | 140,800 | 4,382 | 145,200 | 4,484 |
| Standard\_F48ams\_v7 | 64 | 192,000 | 5,663 | 192,500 | 5,749 | 211,200 | 6,573 | 211,750 | 6,669 |
| Standard\_F64ams\_v7 | 64 | 204,800 | 7,488 | 225,280 | 7,663 | 281,600 | 8,764 | 310,886 | 8,966 |
| Standard\_F80ams\_v7 | 64 | 212,000 | 10,344 | 242,640 | 11,410 | 310,000 | 10,356 | 355,443 | 11,450 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- Some sizes support [bursting](../../disk-bursting) to temporarily increase disk performance. Burst speeds can be maintained for up to 30 minutes at a time.
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly or ReadWrite. For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Network](#tab/sizenetwork)
Network interface info for each size

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mbps) |
| --- | --- | --- |
| Standard\_F1ams\_v7 | 2 | 16,000 |
| Standard\_F2ams\_v7 | 3 | 16,000 |
| Standard\_F4ams\_v7 | 4 | 25,000 |
| Standard\_F8ams\_v7 | 8 | 25,000 |
| Standard\_F16ams\_v7 | 8 | 25,000 |
| Standard\_F32ams\_v7 | 8 | 45,000 |
| Standard\_F48ams\_v7 | 8 | 70,000 |
| Standard\_F64ams\_v7 | 15 | 75,000 |
| Standard\_F80ams\_v7 | 15 | 80,000 |

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
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Not Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

Note

This VM series will only work on OS images that support NVMe. If your current OS image doesn't have NVMe support, you’ll see an error message. [NVMe](../../enable-nvme-interface) support is available on the most popular OS images, and we're continuously improving OS image compatibility.

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
