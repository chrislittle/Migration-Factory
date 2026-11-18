# Dldsv5 size series - Azure Virtual Machines | Microsoft Learn

Dldsv5-series virtual machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor reaching an all core turbo clock speed of up to 3.5 GHz. These virtual machines offer up to 96 vCPU and 192 GiB of RAM and fast, local SSD storage up to 3,600 GiB. These VM sizes can reduce cost when not running memory intensive applications.

Dldsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. See pricing for disks.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | 1 Disk | 75 - 3,600 9,000 - 450,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 4,000 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_D2lds\_v5 | 2 | 4 |
| Standard\_D4lds\_v5 | 4 | 8 |
| Standard\_D8lds\_v5 | 8 | 16 |
| Standard\_D16lds\_v5 | 16 | 32 |
| Standard\_D32lds\_v5 | 32 | 64 |
| Standard\_D48lds\_v5 | 48 | 96 |
| Standard\_D64lds\_v5 | 64 | 128 |
| Standard\_D96lds\_v5 | 96 | 192 |

#### VM Basics resources

- [What are vCPUs (Qty.)](../../managed-disks-overview)
- [Check vCPU quotas](../../quotas)

# [Local Storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Max Temp Storage (Qty.) | Temp Storage Size (GiB) | Temp ReadWrite Storage IOPS | Temp ReadWrite Storage Speed (MBps) |
| --- | --- | --- | --- | --- |
| Standard\_D2lds\_v5 | 1 | 75 | 9,000 | 125 |
| Standard\_D4lds\_v5 | 1 | 150 | 19,000 | 250 |
| Standard\_D8lds\_v5 | 1 | 300 | 38,000 | 500 |
| Standard\_D16lds\_v5 | 1 | 600 | 75,000 | 1,000 |
| Standard\_D32lds\_v5 | 1 | 1,200 | 150,000 | 2,000 |
| Standard\_D48lds\_v5 | 1 | 1,800 | 225,000 | 3,000 |
| Standard\_D64lds\_v5 | 1 | 2,400 | 300,000 | 4,000 |
| Standard\_D96lds\_v5 | 1 | 3,600 | 450,000 | 4,000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- Storage capacity is shown in units of GiB or 1,024^3 bytes. When you compare disks measured in GB (1,000^3 bytes) to disks measured in GiB (1,024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1,023 GiB = 1,098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly (R-O) or ReadWrite (R-W). For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Remote Storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage (Qty.) | Uncached Storage IOPS | Uncached Storage Speed (MBps) | Uncached Storage Burst IOPS | Uncached Storage Burst Speed (MBps) |
| --- | --- | --- | --- | --- | --- |
| Standard\_D2lds\_v5 | 4 | 3,750 | 85 | 10,000 | 1,200 |
| Standard\_D4lds\_v5 | 8 | 6,400 | 145 | 20,000 | 1,200 |
| Standard\_D8lds\_v5 | 16 | 12,800 | 290 | 20,000 | 1,200 |
| Standard\_D16lds\_v5 | 32 | 25,600 | 600 | 40,000 | 1,200 |
| Standard\_D32lds\_v5 | 32 | 51,200 | 865 | 80,000 | 2,000 |
| Standard\_D48lds\_v5 | 32 | 76,800 | 1,315 | 80,000 | 3,000 |
| Standard\_D64lds\_v5 | 32 | 80,000 | 1,735 | 80,000 | 3,000 |
| Standard\_D96lds\_v5 | 32 | 80,000 | 2,600 | 80,000 | 4,000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- These sizes support [bursting](../../disk-bursting) to temporarily increase disk performance. Burst speeds can be maintained for up to 30 minutes at a time.
- Storage capacity is shown in units of GiB or 1,024^3 bytes. When you compare disks measured in GB (1,000^3 bytes) to disks measured in GiB (1,024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1,023 GiB = 1,098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly or ReadWrite. For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Network](#tab/sizenetwork)
Network interface info for each size

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mbps) |
| --- | --- | --- |
| Standard\_D2lds\_v5 | 2 | 12,500 |
| Standard\_D4lds\_v5 | 2 | 12,500 |
| Standard\_D8lds\_v5 | 4 | 12,500 |
| Standard\_D16lds\_v5 | 8 | 12,500 |
| Standard\_D32lds\_v5 | 8 | 16,000 |
| Standard\_D48lds\_v5 | 8 | 24,000 |
| Standard\_D64lds\_v5 | 8 | 30,000 |
| Standard\_D96lds\_v5 | 8 | 35,000 |

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
| [Live Migration](../../maintenance-and-updates#live-migration) | Supported |
| [Memory Preserving Updates](../../maintenance-and-updates) | Supported |
| [VM Generation Support](../../generation-2) | Generation 1 and 2 |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Required |
| [Ephemeral OS Disks](../../ephemeral-os-disks) | Supported |
| [Local temporary storage](../../overview#local-temporary-storage) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
