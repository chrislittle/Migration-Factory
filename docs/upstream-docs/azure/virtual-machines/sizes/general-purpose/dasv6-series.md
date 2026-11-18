# Dasv6-series size - Azure Virtual Machines | Microsoft Learn

Dasv6-series VMs utilize AMD's 4th Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7GHz. These virtual machines offer up to 96 vCPU and 384 GiB of RAM. The Dasv6-series sizes offer a combination of vCPU and memory for most production workloads. The new VMs with no local disk provide a better value proposition for workloads that do not require local temporary storage.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 175,000 IOPS 90 - 4,320 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in the Dasv6-series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size in the Dasv6-series.

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2as\_v6 | 2 | 8 |
| Standard\_D4as\_v6 | 4 | 16 |
| Standard\_D8as\_v6 | 8 | 32 |
| Standard\_D16as\_v6 | 16 | 64 |
| Standard\_D32as\_v6 | 32 | 128 |
| Standard\_D48as\_v6 | 48 | 192 |
| Standard\_D64as\_v6 | 64 | 256 |
| Standard\_D96as\_v6 | 96 | 384 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size in the Dasv6-series.

Note

No local storage present in this series.

For frequently asked questions, see [Azure VM sizes with no local temp disk](../../azure-vms-no-temp-disk).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size in the Dasv6-series.

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst IOPS | Uncached Premium SSD Burst Throughput (MBps) | Uncached Ultra Disk and Premium SSD v2 IOPS | Uncached Ultra Disk and Premium SSD v2 Throughput (MBps) | Uncached Burst Ultra Disk and Premium SSD v2 IOPS | Uncached Burst Ultra Disk and Premium SSD v2 Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard\_D2as\_v6 | 4 | 4,000 | 90 | 20,000 | 1,250 | 4,000 | 90 | 20,000 | 1,250 |
| Standard\_D4as\_v6 | 8 | 7,600 | 180 | 20,000 | 1,250 | 7,600 | 180 | 20,000 | 1,250 |
| Standard\_D8as\_v6 | 16 | 15,200 | 360 | 20,000 | 1,250 | 15,200 | 360 | 20,000 | 1,250 |
| Standard\_D16as\_v6 | 32 | 30,400 | 720 | 40,000 | 1,250 | 30,400 | 720 | 40,000 | 1,250 |
| Standard\_D32as\_v6 | 32 | 57,600 | 1,440 | 80,000 | 1,700 | 57,600 | 1,440 | 80,000 | 1,700 |
| Standard\_D48as\_v6 | 32 | 86,400 | 2,160 | 90,000 | 2,550 | 86,400 | 2,160 | 90,000 | 2,550 |
| Standard\_D64as\_v6 | 32 | 115,200 | 2,880 | 120,000 | 3,400 | 115,200 | 2,880 | 120,000 | 3,400 |
| Standard\_D96as\_v6 | 32 | 175,000 | 4,320 | 175,000 | 5,090 | 175,000 | 4,320 | 175,000 | 5,090 |

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
Network interface info for each size in the Dasv6-series.

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mbps) |
| --- | --- | --- |
| Standard\_D2as\_v6 | 2 | 12,500 |
| Standard\_D4as\_v6 | 2 | 12,500 |
| Standard\_D8as\_v6 | 4 | 12,500 |
| Standard\_D16as\_v6 | 8 | 16,000 |
| Standard\_D32as\_v6 | 8 | 20,000 |
| Standard\_D48as\_v6 | 8 | 28,000 |
| Standard\_D64as\_v6 | 8 | 36,000 |
| Standard\_D96as\_v6 | 8 | 40,000 |

#### Networking resources

- [Virtual networks and virtual machines in Azure](/en-us/azure/virtual-network/network-overview)
- [Virtual machine network bandwidth](/en-us/azure/virtual-network/virtual-machine-network-throughput)

#### Table definitions

- Expected network bandwidth is the maximum aggregated bandwidth allocated per VM type across all NICs, for all destinations. For more information, see [Virtual machine network bandwidth](/en-us/azure/virtual-network/virtual-machine-network-throughput)
- Upper limits aren't guaranteed. Limits offer guidance for selecting the right VM type for the intended application. Actual network performance will depend on several factors including network congestion, application loads, and network settings. For information on optimizing network throughput, see [Optimize network throughput for Azure virtual machines](/en-us/azure/virtual-network/virtual-network-optimize-network-bandwidth).
- To achieve the expected network performance on Linux or Windows, you may need to select a specific version or optimize your VM. For more information, see [Bandwidth/Throughput testing (NTTTCP)](/en-us/azure/virtual-network/virtual-network-bandwidth-testing).

# [Accelerators](#tab/sizeaccelerators)
Accelerator (GPUs, FPGAs, etc.) info for each size in the Dasv6-series.

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
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Required |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Not Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

Note

This VM series will only work on OS images that support NVMe. If your current OS image doesn't have NVMe support, you'll see an error message. [NVMe](../../enable-nvme-interface) support is available on the most popular OS images, and we're continuously improving OS image compatibility.

Some Azure services might refer to this VM series as **Dav6** rather than **Dasv6**. This is a known naming inconsistency and doesn't affect VM capabilities, including Premium Storage support.

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
