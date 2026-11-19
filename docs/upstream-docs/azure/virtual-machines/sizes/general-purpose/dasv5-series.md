# Dasv5 size series - Azure Virtual Machines | Microsoft Learn

Dasv5-series VMs utilize AMD's 3rd Generation EPYC™ 7763v and AMD's 4th Generation EPYC™ 9004 processors. The Dasv5-series sizes offer a combination of vCPU and memory for most production workloads. The new VMs with no local disk provide a better value proposition for workloads that do not require local temp disk.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7763v (Milan) [x86-64] AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 82 - 1,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2as\_v5 | 2 | 8 |
| Standard\_D4as\_v5 | 4 | 16 |
| Standard\_D8as\_v5 | 8 | 32 |
| Standard\_D16as\_v5 | 16 | 64 |
| Standard\_D32as\_v5 | 32 | 128 |
| Standard\_D48as\_v5 | 48 | 192 |
| Standard\_D64as\_v5 | 64 | 256 |
| Standard\_D96as\_v5 | 96 | 384 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

Note

No local storage present in this series.

For frequently asked questions, see [Azure VM sizes with no local temp disk](../../azure-vms-no-temp-disk).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) |
| --- | --- | --- | --- | --- | --- |
| Standard\_D2as\_v5 | 4 | 3,750 | 82 | 10,000 | 600 |
| Standard\_D4as\_v5 | 8 | 6,400 | 144 | 20,000 | 600 |
| Standard\_D8as\_v5 | 16 | 12,800 | 200 | 20,000 | 600 |
| Standard\_D16as\_v5 | 32 | 25,600 | 384 | 40,000 | 800 |
| Standard\_D32as\_v5 | 32 | 51,200 | 768 | 80,000 | 1,600 |
| Standard\_D48as\_v5 | 32 | 76,800 | 1,152 | 80,000 | 2,000 |
| Standard\_D64as\_v5 | 32 | 80,000 | 1,200 | 80,000 | 2,000 |
| Standard\_D96as\_v5 | 32 | 80,000 | 1,600 | 80,000 | 2,000 |

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
| Standard\_D2as\_v5 | 2 | 12,500 |
| Standard\_D4as\_v5 | 2 | 12,500 |
| Standard\_D8as\_v5 | 4 | 12,500 |
| Standard\_D16as\_v5 | 8 | 12,500 |
| Standard\_D32as\_v5 | 8 | 16,000 |
| Standard\_D48as\_v5 | 8 | 24,000 |
| Standard\_D64as\_v5 | 8 | 32,000 |
| Standard\_D96as\_v5 | 8 | 40,000 |

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
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
