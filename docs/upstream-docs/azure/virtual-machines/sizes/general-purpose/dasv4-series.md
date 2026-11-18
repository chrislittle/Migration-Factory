# Dasv4 size series - Azure Virtual Machines | Microsoft Learn

The Dasv4-series run on 2nd Generation AMD EPYC™ 7452 (up to 3.35GHz) or 3rd Generation EPYC™ 7763v processors (up to 3.5GHz) and use Premium SSD. The Dasv4-series sizes offer a combination of vCPU, memory and temporary storage for most production workloads.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7452 (Rome) [x86-64] AMD EPYC 7763v (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 4 - 32 Disks | 16 - 768 GiB 4,000 - 192,000 IOPS 32 - 1,020 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 2,000 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2as\_v4 | 2 | 8 |
| Standard\_D4as\_v4 | 4 | 16 |
| Standard\_D8as\_v4 | 8 | 32 |
| Standard\_D16as\_v4 | 16 | 64 |
| Standard\_D32as\_v4 | 32 | 128 |
| Standard\_D48as\_v4 | 48 | 192 |
| Standard\_D64as\_v4 | 64 | 256 |
| Standard\_D96as\_v4 | 96 | 384 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read IOPS | Temp Disk Sequential Read Throughput (MBps) | Temp Disk Random Write IOPS | Temp Disk Sequential Write Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- |
| Standard\_D2as\_v4 | 4 | 16 | 4,000 | 32 | 4,000 | 100 |
| Standard\_D4as\_v4 | 8 | 32 | 8,000 | 64 | 8,000 | 200 |
| Standard\_D8as\_v4 | 16 | 64 | 16,000 | 128 | 16,000 | 400 |
| Standard\_D16as\_v4 | 32 | 128 | 32,000 | 255 | 32,000 | 800 |
| Standard\_D32as\_v4 | 32 | 256 | 64,000 | 510 | 64,000 | 1,600 |
| Standard\_D48as\_v4 | 32 | 384 | 96,000 | 1,020 | 96,000 | 2,000 |
| Standard\_D64as\_v4 | 32 | 512 | 128,000 | 1,020 | 128,000 | 2,000 |
| Standard\_D96as\_v4 | 32 | 768 | 192,000 | 1,020 | 192,000 | 2,000 |

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
| Standard\_D2as\_v4 | 4 | 3,200 | 48 | 4,000 | 200 |
| Standard\_D4as\_v4 | 8 | 6,400 | 96 | 8,000 | 200 |
| Standard\_D8as\_v4 | 16 | 12,800 | 192 | 16,000 | 400 |
| Standard\_D16as\_v4 | 32 | 25,600 | 384 | 32,000 | 800 |
| Standard\_D32as\_v4 | 32 | 51,200 | 768 | 64,000 | 1,600 |
| Standard\_D48as\_v4 | 32 | 76,800 | 1,148 | 80,000 | 2,000 |
| Standard\_D64as\_v4 | 32 | 80,000 | 1,200 | 80,000 | 2,000 |
| Standard\_D96as\_v4 | 32 | 80,000 | 1,200 | 80,000 | 2,000 |

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
| Standard\_D2as\_v4 | 2 | 2,000 |
| Standard\_D4as\_v4 | 2 | 4,000 |
| Standard\_D8as\_v4 | 4 | 8,000 |
| Standard\_D16as\_v4 | 8 | 10,000 |
| Standard\_D32as\_v4 | 8 | 16,000 |
| Standard\_D48as\_v4 | 8 | 24,000 |
| Standard\_D64as\_v4 | 8 | 32,000 |
| Standard\_D96as\_v4 | 8 | 40,000 |

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
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Not Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
